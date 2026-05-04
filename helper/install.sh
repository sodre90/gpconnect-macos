#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_SRC="$SCRIPT_DIR/openconnect_helper"
HELPER_DST="/Library/PrivilegedHelperTools/openconnect-helper"
PLIST_SRC="$SCRIPT_DIR/com.openconnect.helper.plist"
PLIST_DST="/Library/LaunchDaemons/com.openconnect.helper.plist"

echo "Installing openconnect privileged helper (requires sudo)..."

sudo install -m 755 -o root -g wheel "$HELPER_SRC" "$HELPER_DST"
sudo install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

# Unload first if already loaded, then bootstrap
sudo launchctl bootout system "$PLIST_DST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST_DST"

echo "Done. Helper installed and running as root."
echo "Log: /var/log/openconnect-helper.log"
