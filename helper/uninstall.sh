#!/bin/bash
set -euo pipefail

PLIST_DST="/Library/LaunchDaemons/com.openconnect.helper.plist"
HELPER_DST="/Library/PrivilegedHelperTools/openconnect-helper"

sudo launchctl bootout system "$PLIST_DST" 2>/dev/null || true
sudo rm -f "$PLIST_DST" "$HELPER_DST"
sudo rm -f /var/run/openconnect-helper.sock

echo "Helper uninstalled."
