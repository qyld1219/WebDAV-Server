#!/bin/bash
# 构建 WebDAV 服务器.app（原生 arm64）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WebDAV服务器"
BUILD="$ROOT/build"
APP="$ROOT/../$APP_NAME.app"

echo "==> 清理"
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> 编译 Swift 源码"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework Cocoa -framework SwiftUI -framework Security -framework CoreImage \
  -o "$BUILD/WebDAVServer" \
  "$ROOT"/*.swift

echo "==> 生成图标"
swiftc -O -o "$BUILD/makeicon" "$ROOT/tools/IconMaker/main.swift" -framework Cocoa -framework CoreImage
"$BUILD/makeicon" "$BUILD/icon-1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$BUILD/icon-1024.png" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"

echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/WebDAVServer" "$APP/Contents/MacOS/WebDAVServer"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/webdav" "$APP/Contents/Resources/webdav"
cp "$ROOT/Resources/cloudflared" "$APP/Contents/Resources/cloudflared"
chmod +x "$APP/Contents/MacOS/WebDAVServer" "$APP/Contents/Resources/webdav" "$APP/Contents/Resources/cloudflared"

echo "==> 签名（本地 ad-hoc）"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Resources/webdav" >/dev/null 2>&1 || true
codesign --force --sign - "$APP/Contents/Resources/cloudflared" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "==> 校验"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2
echo "产物：$APP"
du -sh "$APP"
