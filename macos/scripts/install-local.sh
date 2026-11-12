#!/bin/sh
# 用法：sh macos/scripts/install-local.sh [--no-pull | --built <已打包的 .app>]
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=io.zzusec.airsnip

built=
case ${1:-} in
  --built)
    built=${2:-}
    [ -d "$built" ] || { echo "--built 需要一个已打包的 .app：$built" >&2; exit 1; }
    ;;
  --no-pull) ;;
  *)
    git -C "$root/.." pull --ff-only
    exec sh "$root/scripts/install-local.sh" --no-pull
    ;;
esac

if [ -z "$built" ]; then
  sh "$root/scripts/build-app.sh"
  built="$root/dist/AirSnip.app"
fi

version=$(plutil -extract CFBundleShortVersionString raw "$built/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$built/Contents/Info.plist")

target=/Applications/AirSnip.app
echo "安装位置：$target"

if pgrep -f "$target/Contents/MacOS/AirSnip" >/dev/null 2>&1; then
  echo "正在退出正在运行的旧版…"
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  i=0
  while pgrep -f "$target/Contents/MacOS/AirSnip" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 10 ]; then
      pkill -f "$target/Contents/MacOS/AirSnip" >/dev/null 2>&1 || true
      sleep 0.5
      break
    fi
    sleep 0.5
  done
fi

if [ -e "$target" ]; then
  old=$(plutil -extract CFBundleShortVersionString raw "$target/Contents/Info.plist" 2>/dev/null || echo old)
  trash="$HOME/.Trash/AirSnip-$old-$(date +%Y%m%d%H%M%S).app"
  mv "$target" "$trash"
  echo "旧版 ${old} 已移到废纸篓：${trash}"
fi

ditto "$built" "$target"
echo "已安装 v${version}（build ${build}）到 ${target}"
open "$target"
