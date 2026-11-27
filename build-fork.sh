#!/bin/bash
# Fork addition. Builds a release AeroSpace.app + aerospace CLI with nothing but the Xcode Command Line Tools.
#
# The upstream build-release.sh needs full Xcode (xcodebuild, actool) and the author's code signing certificate.
# This script assembles the app bundle by hand and signs it ad hoc.
#
# Output: .fork-release/AeroSpace.app and .fork-release/aerospace
set -euo pipefail
cd "$(dirname "$0")"

build_version="${1:-0.21.3-fork}"
out_dir="$PWD/.fork-release"
app="$out_dir/AeroSpace.app"

# Swift Testing and SwiftUI macros plugins only ship with Xcode. Nothing in the release build needs them
build_info_file="$PWD/.build-info.txt"
printf '%s\n%s\n%s\n' "$build_version" "$(git rev-parse HEAD)" "$(git rev-parse --short HEAD)" > "$build_info_file"

swift_build() {
    swift build -c release --product "$1" \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __aero_build -Xlinker "$build_info_file" "${@:2}"
}
swift_build AeroSpaceApp
swift_build aerospace
bin_path="$(swift_build AeroSpaceApp --show-bin-path)"

rm -rf "$out_dir"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/AeroSpaceApp" "$app/Contents/MacOS/AeroSpace"
cp "$bin_path/aerospace" "$out_dir/aerospace"
cp docs/config-examples/default-config.toml "$app/Contents/Resources/default-config.toml"
printf 'APPL????' > "$app/Contents/PkgInfo"

# App icon. iconutil is a part of macOS, unlike actool
iconset="$out_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size resources/Assets.xcassets/AppIcon.appiconset/icon.png --out "$iconset/icon_${size}x${size}.png" > /dev/null
    sips -z $((size * 2)) $((size * 2)) resources/Assets.xcassets/AppIcon.appiconset/icon.png --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

min_macos="$(sw_vers -productVersion | cut -d. -f1).0" # Package.swift targets the major version of the build machine
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>AeroSpace</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>bobko.aerospace</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AeroSpace</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$build_version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$min_macos</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$out_dir/aerospace"
codesign --force --sign - --entitlements resources/AeroSpace.entitlements "$app"
codesign --verify --strict "$app"

echo
echo "$app"
echo "$out_dir/aerospace"
