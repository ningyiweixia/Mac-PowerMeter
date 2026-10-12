#!/bin/bash
# ============================================================
#  PowerMeter 构建脚本
#  swiftc 编译 → 组装 .app bundle → 安装到 /Applications
# ============================================================
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PowerMeter"
INSTALL=false
case "${1:-}" in
    "") ;;
    --install) INSTALL=true ;;
    *) echo "用法: $0 [--install]" >&2; exit 2 ;;
esac
BUILD="$(mktemp -d "$SRC/.build-XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
BUNDLE="$BUILD/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

echo "▶ 准备构建目录"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "▶ 编译 Swift 源码"
swiftc \
    -O \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -framework Cocoa \
    -framework SwiftUI \
    -framework IOKit \
    "$SRC/main.swift" "$SRC/Views.swift" "$SRC/SMC.swift" "$SRC/Regression.swift" \
    -o "$BUNDLE/Contents/MacOS/$APP_NAME"

echo "▶ 写入 Info.plist"
cp "$SRC/Info.plist" "$BUNDLE/Contents/Info.plist"

echo "▶ 生成应用图标"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC_ICON="$SRC/AppIcon_1024.png"
if [ -f "$SRC_ICON" ]; then
    for sz in 16 32 64 128 256 512; do
        sips -z $sz $sz "$SRC_ICON" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1
        dbl=$((sz * 2))
        sips -z $dbl $dbl "$SRC_ICON" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    [ -f "$BUNDLE/Contents/Resources/AppIcon.icns" ] && echo "  ✓ 图标已嵌入"
fi

echo "▶ 签名（ad-hoc）"
codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"

echo "▶ 保存构建产物"
mkdir -p "$SRC/build"
rm -rf "$SRC/build/$APP_NAME.app"
mv "$BUNDLE" "$SRC/build/$APP_NAME.app"
BUNDLE="$SRC/build/$APP_NAME.app"

if $INSTALL; then
    echo "▶ 安装到 /Applications"
    STAGED="$(mktemp -d /Applications/.PowerMeter-XXXXXX)"
    trap 'rm -rf "$BUILD" "${STAGED:-}"' EXIT
    cp -R "$BUNDLE" "$STAGED/$APP_NAME.app"
    codesign --verify --strict "$STAGED/$APP_NAME.app"
    if [ -e "$DEST" ]; then
        # 压缩备份放在构建目录，避免旧 .app 出现在应用列表中。
        BACKUP="$SRC/build/$APP_NAME-previous.zip"
        ditto -c -k --keepParent "$DEST" "$BACKUP"
        rm -rf "$DEST"
    fi
    mv "$STAGED/$APP_NAME.app" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DEST" 2>/dev/null || true
    echo "✅ 已安装：$DEST"
else
    echo "✅ 构建完成：$BUNDLE"
fi
