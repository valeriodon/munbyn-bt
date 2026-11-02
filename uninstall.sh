#!/bin/bash
# Removes MunbynBT, its printer queue and the login item.
set -uo pipefail
AGENT_ID="com.valeriodon.munbyn-bt"
launchctl bootout "gui/$(id -u)/$AGENT_ID" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$AGENT_ID.plist"
rm -rf "$HOME/Applications/MunbynBT.app"
sudo lpadmin -x MUNBYN_ITPP130B 2>/dev/null
sudo rm -f /usr/local/bin/munbyn-bt
defaults delete com.valeriodon.munbyn-bt.settings 2>/dev/null
echo "MunbynBT removed."
