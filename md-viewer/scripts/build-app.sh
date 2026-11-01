#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: build-app.sh <handler-binary> <version> <output-dir>" >&2
  exit 64
fi

binary=$1
version=$2
output=$3
root=$(cd "$(dirname "$0")/.." && pwd)
app="$output/MD Viewer.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/MDViewerHandler"
sed "s/__VERSION__/$version/g" "$root/Support/Info.plist" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$app"
codesign --verify --strict "$app"
