#!/bin/bash
# Removes MunbynBT, its printer queue, login item and settings.
set -uo pipefail
for dir in /Applications "$HOME/Applications"; do
  APP="$dir/MunbynBT.app"
  if [[ -d "$APP" ]]; then
    "$APP/Contents/MacOS/munbyn-bt" login-item off 2>/dev/null
    pkill -x munbyn-bt 2>/dev/null
    rm -rf "$APP"
  fi
done
launchctl bootout "gui/$(id -u)/com.valeriodon.munbyn-bt" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/com.valeriodon.munbyn-bt.plist"
echo "Removing the printer (your Mac password may be needed)…"
sudo lpadmin -x MUNBYN_ITPP130B 2>/dev/null
[[ -L /usr/local/bin/munbyn-bt ]] && rm -f /usr/local/bin/munbyn-bt
rm -rf "$HOME/Library/Application Support/MunbynBT"
defaults delete com.valeriodon.munbyn-bt.settings 2>/dev/null
echo "MunbynBT removed."
