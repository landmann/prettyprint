#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app=build/PrettyPrint.app
resources="$app/Contents/Resources"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$resources/AppIcon.iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$resources/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" Resources/AppIcon.png --out "$resources/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$resources/AppIcon.iconset" -o "$resources/AppIcon.icns"
rm -rf "$resources/AppIcon.iconset"

sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find Sources -name '*.swift' | sort)

slices_dir="$(mktemp -d)"
trap 'rm -rf "$slices_dir"' EXIT
slices=()
for arch in ${PRETTYPRINT_ARCHS:-arm64}; do
    swiftc -O -parse-as-library -target "$arch-apple-macosx14.0" -o "$slices_dir/$arch" "${sources[@]}"
    slices+=("$slices_dir/$arch")
done
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/PrettyPrint"
cp Resources/Info.plist "$app/Contents/Info.plist"

if [[ -z "${PRETTYPRINT_CODESIGN_IDENTITY:-}" ]]; then
    PRETTYPRINT_CODESIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F '"' '/Apple Development:/{print $2; exit}'
    )"
fi

codesign --force --deep --sign "${PRETTYPRINT_CODESIGN_IDENTITY:--}" "$app"
