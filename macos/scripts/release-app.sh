#!/bin/sh
set -eu

version=${1:-}
if [ -z "$version" ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi
version=${version#v}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AIRSNIP_VERSION="$version" sh "$root/scripts/build-app.sh"

archive="$root/dist/airsnip-macos-arm64-v${version}.zip"
dmg="$root/dist/airsnip-macos-arm64-v${version}.dmg"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/airsnip-dmg.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

rm -f "$archive" "$archive.sha256" "$dmg" "$dmg.sha256"
ditto -c -k --sequesterRsrc --keepParent "$root/dist/AirSnip.app" "$archive"
ditto "$root/dist/AirSnip.app" "$scratch/AirSnip.app"
ln -s /Applications "$scratch/Applications"
hdiutil create -ov -volname "AirSnip $version" -srcfolder "$scratch" -format UDZO "$dmg" >/dev/null
(
  cd "$root/dist"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
  shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256"
)

printf '%s\n' "$archive" "$dmg"
cat "$archive.sha256"
cat "$dmg.sha256"
