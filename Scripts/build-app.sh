#!/usr/bin/env bash
# Builds "OpenVox TTS Buddy.app" into ./build.
#   Scripts/build-app.sh             Apple Silicon only
#   UNIVERSAL=1 Scripts/build-app.sh Apple Silicon + Intel
# CI sets BUILD_NUMBER and BUILD_COMMIT to stamp the bundle for the updater.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=(--arch arm64)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/OpenVox TTS Buddy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OpenVoxTTSBuddy" "$APP/Contents/MacOS/OpenVoxTTSBuddy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_COMMIT:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :OpenVoxBuildCommit string $BUILD_COMMIT" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature so macOS will launch it and remember the Local Network permission.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
