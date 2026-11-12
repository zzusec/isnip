#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

echo "== 构建 AirSnip.app =="
app=$(sh "$root/scripts/build-app.sh" | tail -n 1)

[ -d "$app" ] || { echo "缺少构建产物：$app" >&2; exit 1; }
[ -x "$app/Contents/MacOS/AirSnip" ] || { echo "缺少可执行文件：$app/Contents/MacOS/AirSnip" >&2; exit 1; }
[ -s "$app/Contents/Resources/AppIcon.icns" ] || { echo "缺少图标资源：AppIcon.icns" >&2; exit 1; }

echo "== 校验代码签名与 Info.plist =="
codesign --verify --deep --strict "$app"
bundle_id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
[ "$bundle_id" = "io.zzusec.airsnip" ] || { echo "Bundle ID 不匹配：$bundle_id" >&2; exit 1; }

echo "== 执行应用端到端冒烟自检 =="
"$app/Contents/MacOS/AirSnip" --smoke-test
