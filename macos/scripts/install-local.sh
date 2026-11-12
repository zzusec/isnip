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

new_team=$(codesign -dv "$built" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
reset_tcc=0

if [ -e "$target" ]; then
  old=$(plutil -extract CFBundleShortVersionString raw "$target/Contents/Info.plist" 2>/dev/null || echo old)
  old_team=$(codesign -dv "$target" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
  if [ "$old_team" != "$new_team" ] || [ "$new_team" = "not set" ] || [ -z "$new_team" ]; then
    reset_tcc=1
  fi
  trash="$HOME/.Trash/AirSnip-$old-$(date +%Y%m%d%H%M%S).app"
  mv "$target" "$trash"
  echo "旧版 ${old} 已移到废纸篓：${trash}"
fi

ditto "$built" "$target"
if [ "$reset_tcc" = 1 ]; then
  echo "检测到应用签名标识变更（${old_team:-none} -> ${new_team:-none}），正在清理失效的旧版录屏权限缓存…"
  /usr/bin/tccutil reset ScreenCapture "$bundle_id" >/dev/null 2>&1 || true
fi
echo "已安装 v${version}（build ${build}）到 ${target}"
if [ "$reset_tcc" = 1 ]; then
  open "$target" --args --request-screen-capture
else
  open "$target"
fi
