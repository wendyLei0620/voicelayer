#!/bin/bash
# 构建 VoiceLayer.app（不依赖 Xcode，只需要 Command Line Tools）
set -euo pipefail

cd "$(dirname "$0")"
APP="build/VoiceLayer.app"

# 可选：设置 SIGN_IDENTITY 为本机固定的自签名证书名称，可避免每次构建后权限失效
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 模块缓存放在项目内，避免依赖系统临时目录的写权限
CACHE="$(pwd)/build/ModuleCache"
mkdir -p "$CACHE"
export CLANG_MODULE_CACHE_PATH="$CACHE"

echo "==> 编译"
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$CACHE" \
  -o "$APP/Contents/MacOS/VoiceLayer" \
  Sources/*.swift \
  -framework AppKit -framework AVFoundation -framework CoreGraphics -framework ApplicationServices

echo "==> 打包"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> 签名（身份: ${SIGN_IDENTITY})"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> 完成: $(pwd)/$APP"
