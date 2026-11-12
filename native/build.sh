#!/bin/bash
#
# 构建 ParticleBar.app（菜单栏小工具，不需要 Xcode 工程）
#
set -euo pipefail
cd "$(dirname "$0")"

# 缓存放进项目目录，避免污染系统目录、也方便在受限环境里编译
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFT_MODULE_CACHE_PATH="$PWD/.cache/swift"

swift build -c release \
  --disable-sandbox \
  --cache-path "$PWD/.cache/spm" \
  --manifest-cache local

APP="build/ParticleBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ParticleBar "$APP/Contents/MacOS/ParticleBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 本地 ad-hoc 签名，让 TCC 能把权限和 App 关联起来
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "已生成：$APP"
echo "运行：  open \"$APP\""
