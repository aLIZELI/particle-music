#!/bin/bash
#
# 构建 ParticleBar.app（菜单栏小工具，不需要 Xcode 工程）
#
#   ./build.sh              # 只构建当前架构，快
#   ./build.sh --universal  # Apple Silicon + Intel 通用包，发 Release 用
#
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0
if [ "${1:-}" = "--universal" ]; then
  UNIVERSAL=1
fi

# 缓存放进项目目录，避免污染系统目录、也方便在受限环境里编译
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFT_MODULE_CACHE_PATH="$PWD/.cache/swift"

if [ "$UNIVERSAL" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64 \
    --disable-sandbox \
    --cache-path "$PWD/.cache/spm" \
    --manifest-cache local
  BIN=".build/apple/Products/Release/ParticleBar"
else
  swift build -c release \
    --disable-sandbox \
    --cache-path "$PWD/.cache/spm" \
    --manifest-cache local
  BIN=".build/release/ParticleBar"
fi

APP="build/ParticleBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ParticleBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# 本地 ad-hoc 签名，让 TCC 能把权限和 App 关联起来
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "已生成：$APP"
if [ "$UNIVERSAL" = "1" ]; then
  echo "架构：$(lipo -archs "$APP/Contents/MacOS/ParticleBar")"
fi
echo "运行：  open \"$APP\""
