#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

version=${ISNIP_VERSION:-${AIRSNIP_VERSION:-}}

swift build -c release >&2

app="$root/dist/iSnip.app"
rm -rf "$app" "$root/dist/AirSnip.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers" "$app/Contents/Frameworks"

cp "$root/.build/release/iSnip" "$app/Contents/MacOS/iSnip"
cp "$root/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Info.plist" "$app/Contents/Info.plist"

if [ -d "$root/Vendor/Helpers" ]; then
  for helper in "$root/Vendor/Helpers"/*; do
    [ -f "$helper" ] || continue
    cp "$helper" "$app/Contents/Helpers/$(basename "$helper")"
    chmod 755 "$app/Contents/Helpers/$(basename "$helper")"
  done
fi

if [ -d "$root/Vendor/Frameworks" ]; then
  for dylib in "$root/Vendor/Frameworks"/*.dylib; do
    [ -f "$dylib" ] || continue
    cp "$dylib" "$app/Contents/Frameworks/$(basename "$dylib")"
    chmod 755 "$app/Contents/Frameworks/$(basename "$dylib")"
  done
fi

if [ -n "$version" ]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
fi

find "$app" -name .DS_Store -delete
find "$app" -name '._*' -delete
xattr -cr "$app"

sign_identity=${ISNIP_SIGN_IDENTITY:-${AIRSNIP_SIGN_IDENTITY:-}}
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

echo "Signing iSnip.app (inside-out) with identity: $sign_identity" >&2
for dylib in "$app/Contents/Frameworks"/*.dylib; do
  [ -f "$dylib" ] || continue
  codesign --force --sign "$sign_identity" "$dylib"
done
for helper in "$app/Contents/Helpers"/*; do
  [ -f "$helper" ] || continue
  codesign --force --sign "$sign_identity" "$helper"
done
codesign --force --sign "$sign_identity" "$app"
printf '%s\n' "$app"
