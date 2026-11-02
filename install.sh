#!/bin/bash
# Builds MunbynBT from source, installs it in /Applications and opens it.
# The app itself adds the printer and the login item on first launch.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST=/Applications
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Versions before the DMG used a LaunchAgent: remove it.
launchctl bootout "gui/$(id -u)/com.valeriodon.munbyn-bt" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.valeriodon.munbyn-bt.plist"

pkill -x munbyn-bt 2>/dev/null && sleep 1 || true
rm -rf "$DEST/MunbynBT.app"
cp -R build/MunbynBT.app "$DEST/"
echo "Installed in $DEST/MunbynBT.app"

if [[ -w /usr/local/bin ]]; then
  ln -sf "$DEST/MunbynBT.app/Contents/MacOS/munbyn-bt" /usr/local/bin/munbyn-bt
  echo "Command line tool: munbyn-bt"
fi

open "$DEST/MunbynBT.app"
cat <<'EOF'

MunbynBT is starting:
 1. Click "Add Printer" and enter your Mac password.
 2. If macOS asks whether MunbynBT may use Bluetooth, click Allow.
 3. Print from any app to "MUNBYN ITPP130B (Bluetooth)".
    Settings and status live in the printer icon in the menu bar.
EOF
