#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

PRETTYPRINT_ARCHS="arm64 x86_64" PRETTYPRINT_CODESIGN_IDENTITY=- bash build.sh

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R PrettyPrint.app "$staging/"
ln -s /Applications "$staging/Applications"
rm -f PrettyPrint.dmg
hdiutil create -volname PrettyPrint -srcfolder "$staging" -ov -format UDZO PrettyPrint.dmg >/dev/null

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
echo "Built PrettyPrint.dmg ($version). Publish it with:"
echo "  gh release create v$version PrettyPrint.dmg --title \"PrettyPrint $version\" --generate-notes"
