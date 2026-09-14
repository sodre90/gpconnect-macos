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

# SDK selection. macOS 27's SDK redeclares SwiftUI's @State (and friends) as macros
# backed by libSwiftUIMacros.dylib, a plugin that ships only inside Xcode. This project
# builds with Command Line Tools only (see CLAUDE.md), where that plugin is absent and
# every @State fails to expand. When that is the case, fall back to the newest installed
# SDK that still declares them as plain property wrappers.
swiftui_state_is_macro() {
    local iface="$1/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
    [ -f "$iface" ] && grep -q 'public macro State()' "$iface"
}

SDK_PATH="$(xcrun --show-sdk-path)"
PLUGIN_DIR="$(dirname "$(dirname "$(xcrun -f swiftc)")")/lib/swift/host/plugins"
if swiftui_state_is_macro "$SDK_PATH" && [ ! -f "$PLUGIN_DIR/libSwiftUIMacros.dylib" ]; then
    for candidate in $(ls -d "$(dirname "$SDK_PATH")"/MacOSX*.sdk 2>/dev/null | sort -rV); do
        if ! swiftui_state_is_macro "$candidate"; then
            echo "==> $(basename "$SDK_PATH") needs the Xcode-only libSwiftUIMacros.dylib; building against $(basename "$candidate")"
            SDK_PATH="$candidate"
            break
        fi
    done
fi

# Gather all swift sources for the app
SOURCES=$(find GPConnect -name '*.swift' -type f)

# Clean and create bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

# Compile
swiftc \
    -O \
    -target arm64-apple-macosx14.0 \
    -sdk "$SDK_PATH" \
    -framework SwiftUI \
    -framework WebKit \
    -framework AppKit \
    -framework Foundation \
    -framework AuthenticationServices \
    -parse-as-library \
    -o "$MACOS/$APP_NAME" \
    $SOURCES

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

# Sign the whole bundle LAST, so Resources/helper/* is covered by the seal. Signing
# earlier (or signing just the executable) leaves install.sh unsealed, and the app runs
# it as root via osascript -- an unsealed copy would be tampering the signature misses.
# The --entitlements flag enables WebAuthn/Touch ID in WKWebView.
echo "==> Signing bundle..."
codesign --force --sign - --entitlements GPConnect/GPConnect.entitlements "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Built: $APP_BUNDLE"
echo ""
echo "To run:     open $APP_BUNDLE"
echo "To install: cp -R $APP_BUNDLE /Applications/"
echo ""
echo "The companion gpconnect CLI is a separate package — see cli/README.md"
