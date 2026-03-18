#!/bin/bash
# 构建并运行 WindowsSwitcher
set -e
cd "$(dirname "$0")"

pkill WindowsSwitcher 2>/dev/null || true
sleep 0.3

# 优先用 Xcode 构建（有完整 .app bundle）
XCODE_APP=$(find ~/Library/Developer/Xcode/DerivedData -name "WindowsSwitcher.app" -path "*/Debug/*" 2>/dev/null | head -1)

if [ -n "$XCODE_APP" ]; then
    echo "🚀 使用 Xcode 构建: $XCODE_APP"
    "$XCODE_APP/Contents/MacOS/WindowsSwitcher" &
else
    echo "🔨 SPM 构建..."
    cd WindowsSwitcher
    swift build
    mkdir -p WindowsSwitcher.app/Contents/MacOS
    cp .build/debug/WindowsSwitcher WindowsSwitcher.app/Contents/MacOS/
    cp Sources/Info.plist WindowsSwitcher.app/Contents/
    ./WindowsSwitcher.app/Contents/MacOS/WindowsSwitcher &
fi

echo "✅ 启动完成 — 右上角菜单栏找 ⊞ 图标"
echo "   左键 → 切换面板  |  右键 → 菜单"
