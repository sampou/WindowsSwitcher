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
sleep 0.3

# 直接运行可执行文件（绕过 Gatekeeper 未签名限制）
./WindowsSwitcher.app/Contents/MacOS/WindowsSwitcher &

echo "✅ 完成！查看右上角菜单栏图标 (⊞)"
echo "   左键点击 → 显示切换面板"
echo "   右键点击 → 设置/退出菜单"
