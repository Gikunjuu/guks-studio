#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build_dir="$root/build"
app="$build_dir/Guks Studio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Resources/Info.plist" "$app/Contents/"
cp "$root/Resources/"*.{icns,ttf} "$app/Contents/Resources/"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun swiftc -parse-as-library -O -sdk "$sdk" -target "$arch-apple-macos13.0" \
        "$root/Sources/GuksStudio.swift" "$root/Sources/Render.swift" \
        -o "$build_dir/GuksStudio-$arch"
done

xcrun lipo -create "$build_dir/GuksStudio-arm64" "$build_dir/GuksStudio-x86_64" \
    -output "$app/Contents/MacOS/GuksStudio"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $app"
