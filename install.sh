#!/bin/bash
# Installs MunbynBT: the menu bar app and the "MUNBYN ITPP130B" printer in
# Printers & Scanners. Usage: ./install.sh   (or ./install.sh --build-only)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MunbynBT.app"
APP="$HOME/Applications/$APP_NAME"
AGENT_ID="com.valeriodon.munbyn-bt"
PLIST="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
LOG="$HOME/Library/Logs/munbyn-bt.log"
QUEUE="MUNBYN_ITPP130B"

build() {
  if ! command -v swiftc >/dev/null; then
    echo "The Swift compiler is missing: run  xcode-select --install  and then ./install.sh again"
    exit 1
  fi
  echo "Building MunbynBT…"
  rm -rf "build/$APP_NAME"
  mkdir -p "build/$APP_NAME/Contents/MacOS"
  cp support/Info.plist "build/$APP_NAME/Contents/Info.plist"
  swiftc -O -swift-version 5 -o "build/$APP_NAME/Contents/MacOS/munbyn-bt" src/*.swift
  codesign --force --sign - "build/$APP_NAME"
  "build/$APP_NAME/Contents/MacOS/munbyn-bt" ppd > build/munbyn.ppd
}

build
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi

echo "Installing the app in $APP…"
launchctl bootout "gui/$(id -u)/$AGENT_ID" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
cp -R "build/$APP_NAME" "$APP"
BIN="$APP/Contents/MacOS/munbyn-bt"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_ID</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Adding the printer to Printers & Scanners (your Mac password is needed)…"
sudo lpadmin -x "$QUEUE" 2>/dev/null || true
sudo lpadmin -p "$QUEUE" -E \
  -D "MUNBYN ITPP130B (Bluetooth)" -L "Bluetooth" \
  -v socket://127.0.0.1:9100 -P build/munbyn.ppd \
  -o printer-is-shared=false
sudo mkdir -p /usr/local/bin
sudo ln -sf "$BIN" /usr/local/bin/munbyn-bt

cat <<'EOF'

Done.
 1. If macOS asks whether "MunbynBT" may use Bluetooth, click Allow.
 2. The printer icon in the menu bar is the control panel.
 3. From any app: Print › "MUNBYN ITPP130B (Bluetooth)".
    For a PDF on an A4 sheet (a carrier or marketplace shipping label) pick the
    A4 paper size: the driver crops the white margins and fits it to the label.

EOF
read -r -p "Turn the printer on and press Return to print a test label (or Ctrl+C): " _
"$BIN" make-test-pdf build/test.pdf
lp -d "$QUEUE" -o media=w283h425 build/test.pdf >/dev/null
echo "Sent. The status is in the menu bar panel; the log is in $LOG"
