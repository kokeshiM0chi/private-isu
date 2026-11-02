#!/usr/bin/env bash
# 全段階を、同じ電源状態と同じ環境で順に計測する。
#
#   scripts/measure-all.sh [回数]
#
# 各段階のコミットを一時ディレクトリに取り出して計測する。結果はこのリポジトリの
# results/ に final- で始まる名前で記録される。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COUNT="${1:-3}"

# 名前 コミット SQLを適用するか
STAGES=(
  "final-01-baseline 3f0eb60 no"
  "final-02-db-index 3f0eb60 yes"
  "final-03-db-query 902e253 yes"
  "final-04-app-connection 9817c01 yes"
  "final-05-static 18dbd50 yes"
  "final-06-cache 24f452e yes"
  "final-07-infra $(git -C "$ROOT" rev-parse --short HEAD) yes"
)

if ! pmset -g batt | grep -q "AC Power"; then
  echo "電源アダプタをつないでから実行する" >&2
  exit 1
fi
if pmset -g | grep -Eq 'lowpowermode[[:space:]]+1'; then
  echo "低電力モードをオフにしてから実行する" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'git -C "$ROOT" worktree prune; rm -rf "$WORK"' EXIT

for stage in "${STAGES[@]}"; do
  read -r label commit apply_sql <<<"$stage"
  git -C "$ROOT" worktree add -q --detach "$WORK/$label" "$commit"

  skip=""
  if [[ "$apply_sql" == no ]]; then
    skip=1
  fi
  for ms in 0 100; do
    echo "=== $label ${ms}ms ($commit)"
    PRACTICE_ROOT="$WORK/$label" SKIP_SQL_CHANGES="$skip" \
      "$ROOT/scripts/practice.sh" measure "$label" "$ms" "$COUNT"
  done

  git -C "$ROOT" worktree remove --force "$WORK/$label"
done

"$ROOT/scripts/practice.sh" compare
