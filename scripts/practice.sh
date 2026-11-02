#!/usr/bin/env bash
# Macのcolima上でprivate-isu（Go実装）を動かす練習用の操作をまとめる。
#
#   scripts/practice.sh up            Colimaと全サービスを起動する
#   scripts/practice.sh build         アプリを再ビルドして入れ替える（遅延は外れる）
#   scripts/practice.sh down          サービスとColimaを停止する（データは残る）
#   scripts/practice.sh bench [回数]  ベンチを実行する（既定は1回）
#   scripts/practice.sh delay <ms>    appからDBとmemcachedへの通信に遅延を入れる
#   scripts/practice.sh delay off     遅延を外す
#   scripts/practice.sh delay status  遅延の設定とRTTを表示する
#   scripts/practice.sh snapshot      今のDBを基準データとして保存する（初回だけ）
#   scripts/practice.sh reset         DBを基準データに戻し、webapp/sql-changes/*.sql を適用する
#   scripts/practice.sh measure <名前> [遅延ms] [回数]  今のブランチを計測してresults/に記録する
#   scripts/practice.sh compare       計測結果の一覧を表示する
#
# 遅延はappの送信側だけに入れるので、指定値がそのままRTTの増加分になる。
# nginxとappの間の通信には遅延を入れない。
set -euo pipefail

# 計測中にMacがスリープすると結果が壊れるので、スリープを防いで実行し直す
if [[ "${1:-}" == measure && -z "${PRACTICE_NO_SLEEP:-}" ]] && command -v caffeinate >/dev/null; then
  PRACTICE_NO_SLEEP=1 exec caffeinate -ims "${BASH_SOURCE[0]}" "$@"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT=private-isu
NETWORK="${PROJECT}_my_network"
COLIMA_CPU=6
COLIMA_MEMORY=5
MYSQL_VOLUME="${PROJECT}_mysql"
BASE_VOLUME="${PROJECT}_mysql_base"
RESULTS_DIR="$ROOT/results"
SQL_CHANGES_DIR="$ROOT/webapp/sql-changes"

compose() {
  docker compose \
    --project-directory "$ROOT/webapp" \
    -f "$ROOT/webapp/compose.yml" \
    -f "$ROOT/webapp/compose.kokeshi.yml" \
    "$@"
}

container_id() {
  compose ps -q "$1"
}

container_ip() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "$(container_id "$1")"
}

# appコンテナのネットワーク名前空間で、VM側のコマンドを実行する
in_app_netns() {
  local pid
  pid="$(docker inspect -f '{{.State.Pid}}' "$(container_id app)")"
  colima ssh -- sudo nsenter -t "$pid" -n "$@"
}

wait_for_mysql() {
  echo "MySQLの起動を待っている"
  local i
  for i in $(seq 1 60); do
    if compose exec -T mysql mysqladmin ping -uroot -proot --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "MySQLが起動しなかった" >&2
  return 1
}

cmd_up() {
  colima start --cpu "$COLIMA_CPU" --memory "$COLIMA_MEMORY"
  compose up -d --build
  wait_for_mysql
  compose ps
}

cmd_build() {
  compose up -d --build app nginx
}

cmd_down() {
  compose down
  colima stop
}

cmd_bench() {
  local count="${1:-1}" i
  for i in $(seq 1 "$count"); do
    docker run --rm --network "$NETWORK" private-isu-benchmarker \
      /bin/benchmarker -t http://nginx -u /opt/userdata || true # pass:falseでも次の回へ進む
  done
}

delay_off() {
  in_app_netns tc qdisc del dev eth0 root 2>/dev/null || true
}

delay_status() {
  in_app_netns tc qdisc show dev eth0
  # VMにはpingがないので、appのネットワークを共有するコンテナから測る
  docker run --rm --network "container:$(container_id app)" alpine:3.20 \
    ping -c 3 -q "$(container_ip mysql)" | tail -1
}

delay_on() {
  local ms="$1" mysql_ip memcached_ip ip
  mysql_ip="$(container_ip mysql)"
  memcached_ip="$(container_ip memcached)"

  delay_off
  in_app_netns tc qdisc add dev eth0 root handle 1: prio
  in_app_netns tc qdisc add dev eth0 parent 1:3 handle 30: netem delay "${ms}ms" limit 100000
  for ip in "$mysql_ip" "$memcached_ip"; do
    in_app_netns tc filter add dev eth0 protocol ip parent 1: prio 1 u32 \
      match ip dst "$ip/32" flowid 1:3
  done
}

cmd_delay() {
  case "${1:-status}" in
    off) delay_off ;;
    status) ;;
    *[!0-9]*)
      echo "遅延はミリ秒の数字、off、statusのどれかで指定する" >&2
      exit 2
      ;;
    *) delay_on "$1" ;;
  esac
  delay_status
}

copy_volume() {
  docker run --rm -v "$1:/from:ro" -v "$2:/to" alpine:3.20 \
    sh -c 'find /to -mindepth 1 -delete && cp -a /from/. /to/'
}

cmd_snapshot() {
  if docker volume inspect "$BASE_VOLUME" >/dev/null 2>&1; then
    echo "基準データはすでにある。作り直す場合は先に消す: docker volume rm $BASE_VOLUME" >&2
    exit 1
  fi
  compose stop mysql
  docker volume create "$BASE_VOLUME" >/dev/null
  copy_volume "$MYSQL_VOLUME" "$BASE_VOLUME"
  compose start mysql
  wait_for_mysql
  echo "基準データを保存した: $BASE_VOLUME"
}

cmd_reset() {
  if ! docker volume inspect "$BASE_VOLUME" >/dev/null 2>&1; then
    echo "基準データがない。先に実行する: $0 snapshot" >&2
    exit 1
  fi
  compose stop mysql
  copy_volume "$BASE_VOLUME" "$MYSQL_VOLUME"
  # 復元で消した領域をVMからMacへ返す。返さないとMacのディスクが減り続ける
  colima ssh -- sudo fstrim -a
  compose start mysql
  wait_for_mysql

  # 改善なしの状態を測り直すときだけ SKIP_SQL_CHANGES=1 を付ける
  if [[ "${SKIP_SQL_CHANGES:-}" == 1 ]]; then
    return 0
  fi

  local file
  for file in "$SQL_CHANGES_DIR"/*.sql; do
    [[ -e "$file" ]] || continue
    echo "適用: ${file#"$ROOT"/}"
    compose exec -T mysql mysql -uroot -proot isuconp <"$file" 2>/dev/null
  done
}

cmd_measure() {
  local label="${1:-}" ms="${2:-0}" count="${3:-3}"
  if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ || ! "$ms" =~ ^[0-9]+$ || ! "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "使い方: $0 measure <名前> [遅延ms] [回数]（名前は英数字と . _ -）" >&2
    exit 2
  fi

  # 前の計測の状態を引き継がないよう、アプリとDBを入れ替えてから測る
  compose up -d --build --force-recreate
  cmd_reset
  delay_off
  if [[ "$ms" -gt 0 ]]; then
    delay_on "$ms"
  fi

  local stamp branch commit dirty file median scores successes fails
  stamp="$(date +%Y%m%d-%H%M%S)"
  branch="$(git -C "$ROOT" branch --show-current)"
  commit="$(git -C "$ROOT" rev-parse --short HEAD)"
  dirty=clean
  if [[ -n "$(git -C "$ROOT" status --porcelain -- webapp scripts)" ]]; then
    dirty=dirty
  fi
  mkdir -p "$RESULTS_DIR"
  file="$RESULTS_DIR/$stamp-$label-${ms}ms.jsonl"

  cmd_bench "$count" | tee "$file"
  delay_off

  scores="$(sed -E 's/.*"score":(-?[0-9]+).*/\1/' "$file" | paste -sd, -)"
  median="$(sed -E 's/.*"score":(-?[0-9]+).*/\1/' "$file" | sort -n | sed -n "$(((count + 1) / 2))p")"
  # スコアが0の間は、成功と失敗の回数で比べる
  successes="$(sed -E 's/.*"success":([0-9]+).*/\1/' "$file" | paste -sd, -)"
  fails="$(sed -E 's/.*"fail":([0-9]+).*/\1/' "$file" | paste -sd, -)"
  if [[ ! -e "$RESULTS_DIR/summary.tsv" ]]; then
    printf 'time\tlabel\tbranch\tcommit\tstate\tdelay_ms\tmedian\tscores\tsuccesses\tfails\n' \
      >"$RESULTS_DIR/summary.tsv"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$stamp" "$label" "$branch" "$commit" "$dirty" "$ms" "$median" "$scores" "$successes" "$fails" \
    >>"$RESULTS_DIR/summary.tsv"
  echo "記録した: ${file#"$ROOT"/}"
}

cmd_compare() {
  column -t -s "$(printf '\t')" "$RESULTS_DIR/summary.tsv"
}

case "${1:-}" in
  snapshot) cmd_snapshot ;;
  reset) cmd_reset ;;
  measure) cmd_measure "${2:-}" "${3:-0}" "${4:-3}" ;;
  compare) cmd_compare ;;
  up) cmd_up ;;
  build) cmd_build ;;
  down) cmd_down ;;
  bench) cmd_bench "${2:-1}" ;;
  delay) cmd_delay "${2:-status}" ;;
  *)
    sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
