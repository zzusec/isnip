#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

version=${AIRSNIP_VERSION:-}

swift build -c release

app="$root/dist/AirSnip.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/AirSnip" "$app/Contents/MacOS/AirSnip"
cp "$root/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Info.plist" "$app/Contents/Info.plist"

if [ -n "$version" ]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
fi

find "$app" -name .DS_Store -delete
find "$app" -name '._*' -delete
xattr -cr "$app"

codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
