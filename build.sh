#!/bin/bash
# 构建 DockPin.app（本地 ad-hoc 签名，不需要开发者证书）
set -euo pipefail
cd "$(dirname "$0")"

APP="DockPin.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/DockPin" main.swift \
  -framework Cocoa -framework ApplicationServices

codesign --force --sign - "$APP" >/dev/null 2>&1 || {
  echo "codesign failed" >&2
  exit 1
}

echo "built: $(pwd)/$APP"
