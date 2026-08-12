#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="GPConnect"
BUILD_DIR=".build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building $APP_NAME.app..."

# Gather all swift sources for the app
SOURCES=$(find GPConnect -name '*.swift' -type f)

# Clean and create bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

# Compile
swiftc \
    -O \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework WebKit \
    -framework AppKit \
    -framework Foundation \
    -framework AuthenticationServices \
    -parse-as-library \
    -o "$MACOS/$APP_NAME" \
    $SOURCES

# Sign with entitlements (enables WebAuthn/Touch ID in WKWebView)
codesign --force --sign - --entitlements GPConnect/GPConnect.entitlements "$MACOS/$APP_NAME"

echo "==> Creating app bundle..."

# Copy Info.plist, stamping the version from the repo-root VERSION file
cp GPConnect/Info.plist "$CONTENTS/Info.plist"
VERSION="$(tr -d '[:space:]' < ../VERSION)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"

# Copy default config to Resources
cp GPConnect/Resources/default-config.json "$RESOURCES/default-config.json"

# Bundle the privileged helper daemon so the app can offer to install it
mkdir -p "$RESOURCES/helper"
cp ../helper/install.sh ../helper/uninstall.sh ../helper/openconnect_helper ../helper/com.openconnect.helper.plist "$RESOURCES/helper/"
chmod +x "$RESOURCES/helper/install.sh" "$RESOURCES/helper/uninstall.sh" "$RESOURCES/helper/openconnect_helper"

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS/PkgInfo"

echo "==> Built: $APP_BUNDLE"
echo ""
echo "To run:     open $APP_BUNDLE"
echo "To install: cp -R $APP_BUNDLE /Applications/"
echo ""
echo "The companion gpconnect CLI is a separate package — see cli/README.md"
