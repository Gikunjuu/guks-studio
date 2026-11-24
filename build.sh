#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build_dir="$root/build"
staging="$(mktemp -d /tmp/guks-studio-build.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
app="$staging/Guks Studio.app"
destination="$build_dir/Guks Studio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X "$root/Resources/Info.plist" "$app/Contents/"
cp -X "$root/Resources/"*.{icns,ttf} "$app/Contents/Resources/"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun swiftc -parse-as-library -O -sdk "$sdk" -target "$arch-apple-macos13.0" \
        -module-cache-path "$build_dir/module-cache-$arch" \
        "$root/Sources/GuksStudio.swift" "$root/Sources/Render.swift" \
        -o "$build_dir/GuksStudio-$arch"
done

xcrun lipo -create "$build_dir/GuksStudio-arm64" "$build_dir/GuksStudio-x86_64" \
    -output "$app/Contents/MacOS/GuksStudio"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto --noextattr --norsrc "$app" "$destination"
if xattr -p com.apple.FinderInfo "$destination" >/dev/null 2>&1; then
    xattr -d com.apple.FinderInfo "$destination"
fi
codesign --verify --strict "$destination"
echo "Built $destination"
