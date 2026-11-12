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

sign_identity=${AIRSNIP_SIGN_IDENTITY:-}
if [ -z "$sign_identity" ]; then
  sign_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Developer ID Application: /{print $2; exit}')
fi
if [ -z "$sign_identity" ]; then
  sign_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development: /{id=$2} END{if (id) print id}')
fi
if [ -z "$sign_identity" ]; then
  sign_identity=-
fi

echo "Signing AirSnip.app with identity: $sign_identity" >&2
codesign --force --deep --sign "$sign_identity" "$app"
printf '%s\n' "$app"
