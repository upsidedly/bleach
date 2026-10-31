#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
# The Command Line Tools SDK is sufficient. Do not change the global Xcode
# selection or accept licenses as a side effect of building this utility.
xcrun swift build -c release
BLEACH_BIN_DIR=$(xcrun swift build -c release --show-bin-path)
APP_DIR="$PROJECT_DIR/build/Bleach.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PROJECT_DIR/docs/assets"
cp "$BLEACH_BIN_DIR/BleachApp" "$APP_DIR/Contents/MacOS/BleachApp"
cp "$BLEACH_BIN_DIR/bleach" "$APP_DIR/Contents/MacOS/bleach"
cp "$BLEACH_BIN_DIR/bleach" "$PROJECT_DIR/build/bleach"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp docs/THIRD-PARTY-NOTICES.md "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt"
for BLEACH_RESOURCE_BUNDLE in "$BLEACH_BIN_DIR"/*.bundle(N); do
    ditto "$BLEACH_RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/${BLEACH_RESOURCE_BUNDLE:t}"
    ditto "$BLEACH_RESOURCE_BUNDLE" "$PROJECT_DIR/build/${BLEACH_RESOURCE_BUNDLE:t}"
done
xcrun swiftc Sources/BleachApp/BleachIcon.swift scripts/make-icon.swift -o build/make-icon
build/make-icon "$PROJECT_DIR/build"
cp build/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp build/AppIcon.iconset/icon_256x256@2x.png docs/assets/bleach-icon.png
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --options runtime "$APP_DIR/Contents/MacOS/bleach"
codesign --force --sign - --options runtime "$APP_DIR"
codesign --verify --strict "$APP_DIR"
print "Built $APP_DIR"
print "CLI: $PROJECT_DIR/build/bleach"
