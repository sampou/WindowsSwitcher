#!/bin/bash
# 构建并运行 WindowsSwitcher.app
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 构建..."
swift build

echo "📦 打包 .app bundle..."
rm -rf WindowsSwitcher.app
mkdir -p WindowsSwitcher.app/Contents/MacOS
cp .build/debug/WindowsSwitcher WindowsSwitcher.app/Contents/MacOS/
cp Sources/Info.plist WindowsSwitcher.app/Contents/

echo "🚀 启动..."
pkill -f "WindowsSwitcher.app/Contents/MacOS/WindowsSwitcher" 2>/dev/null || true
sleep 0.5
open WindowsSwitcher.app

echo "✅ 完成！菜单栏应查看右上角图标 (⊞)"
