#!/bin/bash
# Builds build/MunbynBT.app and build/munbyn.ppd.
# Usage: ./build.sh [--universal] [--sign "Developer ID Application: …"]
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0
IDENTITY="-"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --sign) IDENTITY="$2"; shift ;;
    *) echo "Unknown option $1"; exit 2 ;;
  esac
  shift
done

if ! command -v swiftc >/dev/null; then
  echo "The Swift compiler is missing: run  xcode-select --install  and try again"
  exit 1
fi

APP=build/MunbynBT.app
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' src/main.swift)
echo "Building MunbynBT $VERSION…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp support/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

if [[ $UNIVERSAL == 1 ]]; then
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13" -o "build/munbyn-bt-$arch" src/*.swift
  done
  lipo -create build/munbyn-bt-arm64 build/munbyn-bt-x86_64 -output "$APP/Contents/MacOS/munbyn-bt"
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" -o "$APP/Contents/MacOS/munbyn-bt" src/*.swift
fi

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
"$APP/Contents/MacOS/munbyn-bt" ppd > build/munbyn.ppd
echo "Built $APP"
