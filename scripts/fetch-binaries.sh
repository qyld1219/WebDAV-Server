#!/bin/bash
# 拉取三平台构建所需的上游内核二进制（仓库里不存放这些大文件）
# 用法：./scripts/fetch-binaries.sh macos|windows|android|all
set -euo pipefail

WEBDAV_VER="5.17.3"
CFD_VER="2026.10.7"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_webdav() { # $1=asset 前缀  $2=输出文件
  local asset="$1" out="$2"
  echo "==> webdav $WEBDAV_VER  $asset"
  curl -fL --retry 3 -o "$TMP/w.tar.gz" \
    "https://github.com/hacdias/webdav/releases/download/v${WEBDAV_VER}/${asset}-webdav.tar.gz"
  tar -xzf "$TMP/w.tar.gz" -C "$TMP"
  mv "$TMP/webdav" "$out"
  chmod +x "$out"
}

fetch_cloudflared() { # $1=平台后缀  $2=输出文件
  local suffix="$1" out="$2"
  echo "==> cloudflared $CFD_VER  $suffix"
  curl -fL --retry 3 -o "$TMP/cfd" \
    "https://github.com/cloudflare/cloudflared/releases/download/${CFD_VER}/cloudflared-${suffix}"
  mv "$TMP/cfd" "$out"
  chmod +x "$out"
}

do_macos() {
  mkdir -p "$ROOT/macos/Resources"
  fetch_webdav darwin-arm64 "$ROOT/macos/Resources/webdav"
  fetch_cloudflared darwin-arm64 "$ROOT/macos/Resources/cloudflared"
}

do_windows() {
  mkdir -p "$ROOT/windows/resources"
  echo "==> webdav $WEBDAV_VER  windows-amd64"
  curl -fL --retry 3 -o "$TMP/w.zip" \
    "https://github.com/hacdias/webdav/releases/download/v${WEBDAV_VER}/windows-amd64-webdav.zip"
  unzip -o -q "$TMP/w.zip" -d "$TMP/win"
  find "$TMP/win" -name 'webdav.exe' -exec mv {} "$ROOT/windows/resources/webdav.exe" \;
  echo "==> cloudflared $CFD_VER  windows-amd64"
  curl -fL --retry 3 -o "$ROOT/windows/resources/cloudflared.exe" \
    "https://github.com/cloudflare/cloudflared/releases/download/${CFD_VER}/cloudflared-windows-amd64.exe"
}

do_android() {
  mkdir -p "$ROOT/android/app/src/main/jniLibs/arm64-v8a"
  fetch_webdav linux-arm64 "$ROOT/android/app/src/main/jniLibs/arm64-v8a/libwebdav.so"
  fetch_cloudflared linux-arm64 "$ROOT/android/app/src/main/jniLibs/arm64-v8a/libcloudflared.so"
}

case "${1:-all}" in
  macos)   do_macos ;;
  windows) do_windows ;;
  android) do_android ;;
  all)     do_macos; do_windows; do_android ;;
  *) echo "用法: $0 macos|windows|android|all" >&2; exit 1 ;;
esac

echo "==> 完成"
