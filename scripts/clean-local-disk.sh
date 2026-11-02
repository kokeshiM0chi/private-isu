#!/usr/bin/env bash
# Macのキャッシュを定期的に掃除する。
#
#   scripts/clean-local-disk.sh                  サイズを表示するだけで、何も削除しない
#   scripts/clean-local-disk.sh go homebrew      指定した対象を削除する
#   scripts/clean-local-disk.sh all              すべての対象を削除する
#
# 対象（使っているもの / 消した場合の影響）:
#   npm           npmのダウンロードキャッシュ / 次のnpm installで再取得する
#   docker        Dockerのビルドキャッシュと未使用イメージ / 次のビルドが遅くなる
#                 コンテナとボリュームは消さない
#   codex-update  Codexアプリの更新ファイル / 次の更新で再取得する
#   vscode-update VS Codeの更新ファイル / 次の更新で再取得する
#   go            Goのビルドキャッシュ / 次のビルドが遅くなる
#   homebrew      Homebrewのダウンロード済みファイル / 再インストール時に再取得する
#   uv            Pythonのパッケージ管理ツールuvのキャッシュ / 次のインストールで再取得する
#   huggingface   Pythonの機械学習モデル / 次の実行で再取得する
#                 オフラインでは再取得できない。ログイン情報を消さないようにhubだけ消す
#   chrome        Chromeのサイトキャッシュ / ページの表示が一時的に遅くなる
#                 Chromeの起動中は壊さないように削除を飛ばす
#
# 動かなくなる可能性があるため、消さないもの:
#   ~/.cache/codex-runtimes  Codexの実行環境。消すとCodexが動かなくなる可能性がある
#   ~/.cache/puppeteer       ブラウザ自動操作用のChrome。消すとPuppeteerを使う
#                            プロジェクトが動かなくなることがある
set -euo pipefail

ALL_TARGETS=(npm docker codex-update vscode-update go homebrew uv huggingface chrome)

CODEX_UPDATE_DIR="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle"
VSCODE_UPDATE_DIR="$HOME/Library/Caches/com.microsoft.VSCode.ShipIt"
GO_BUILD_DIR="$HOME/Library/Caches/go-build"
HOMEBREW_CACHE_DIR="$HOME/Library/Caches/Homebrew"
UV_CACHE_DIR_PATH="$HOME/.cache/uv"
HUGGINGFACE_HUB_DIR="$HOME/.cache/huggingface/hub"
CHROME_CACHE_DIR="$HOME/Library/Caches/Google/Chrome"

free_space() {
  df -h "$HOME" | awk 'NR == 2 { print $4 }'
}

show_size() {
  if [[ -e "$1" ]]; then
    du -sh "$1" 2>/dev/null || true
  else
    echo "なし	$1"
  fi
}

show_sizes() {
  show_size "$HOME/.npm"
  show_size "$HOME/.colima"
  show_size "$CODEX_UPDATE_DIR"
  show_size "$VSCODE_UPDATE_DIR"
  show_size "$GO_BUILD_DIR"
  show_size "$HOMEBREW_CACHE_DIR"
  show_size "$UV_CACHE_DIR_PATH"
  show_size "$HUGGINGFACE_HUB_DIR"
  show_size "$CHROME_CACHE_DIR"
  if docker info >/dev/null 2>&1; then
    docker system df
  else
    echo "Dockerは停止中のため、内訳は表示しない"
  fi
  echo "空き容量: $(free_space)"
}

clean_npm() {
  echo "== npm =="
  # root所有のファイルが残っていると失敗するが、他の対象の掃除は続ける
  if ! npm cache clean --force; then
    echo "npmのキャッシュを一部削除できなかった。次を実行してからやり直す:" >&2
    echo "  sudo chown -R $(id -u):$(id -g) \"$HOME/.npm\"" >&2
  fi
}

clean_docker() {
  echo "== docker =="
  local started_here=false
  if ! docker info >/dev/null 2>&1; then
    colima start
    started_here=true
  fi

  docker builder prune --all --force
  docker image prune --all --force
  # 削除した領域をVMからMacへ返す
  colima ssh -- sudo fstrim -a

  if [[ "$started_here" == true ]]; then
    colima stop
  fi
}

clean_codex_update() {
  echo "== codex-update =="
  rm -rf "$CODEX_UPDATE_DIR"
}

clean_vscode_update() {
  echo "== vscode-update =="
  rm -rf "$VSCODE_UPDATE_DIR"
}

clean_go() {
  echo "== go =="
  go clean -cache
}

clean_homebrew() {
  echo "== homebrew =="
  # brew cleanupは古いバージョンの本体も消すため、ダウンロード済みファイルだけを消す
  rm -rf "$HOMEBREW_CACHE_DIR"
}

clean_uv() {
  echo "== uv =="
  rm -rf "$UV_CACHE_DIR_PATH"
}

clean_huggingface() {
  echo "== huggingface =="
  rm -rf "$HUGGINGFACE_HUB_DIR"
}

clean_chrome() {
  echo "== chrome =="
  if pgrep -x "Google Chrome" >/dev/null; then
    echo "Chromeが起動中のため飛ばす。終了してから再実行する: $0 chrome"
    return 0
  fi
  rm -rf "$CHROME_CACHE_DIR"
}

if [[ $# -eq 0 ]]; then
  show_sizes
  echo "削除するには対象を指定する: $0 ${ALL_TARGETS[*]} | all"
  exit 0
fi

targets=("$@")
if [[ "$1" == "all" ]]; then
  targets=("${ALL_TARGETS[@]}")
fi

# 途中まで削除してから止まらないように、先に対象名を検証する
for target in "${targets[@]}"; do
  case "$target" in
    npm | docker | codex-update | vscode-update | go | homebrew | uv | huggingface | chrome) ;;
    *)
      echo "不明な対象: ${target}（指定できるのは ${ALL_TARGETS[*]} | all）" >&2
      exit 2
      ;;
  esac
done

echo "実行前の空き容量: $(free_space)"
for target in "${targets[@]}"; do
  "clean_${target//-/_}"
done
echo "実行後の空き容量: $(free_space)"
