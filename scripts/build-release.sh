#!/bin/bash
# WindowsSwitcher 自动化打包脚本
# 生成 ZIP 压缩包和 DMG 磁盘镜像
#
# 用法：
#   bash build-release.sh [修复项目数]
#   例如：bash build-release.sh 2  # 修复了2个项目，版本号递增0.0.2

set -e

# 获取修复项目数（默认为1）
FIX_COUNT=${1:-1}

# 配置
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/release"
BUILD_DIR="$PROJECT_DIR/build"
INFO_PLIST="$PROJECT_DIR/WindowsSwitcher/Sources/Info.plist"

# 从 Info.plist 读取当前版本号
CURRENT_VERSION=$(grep -A1 "CFBundleShortVersionString" "$INFO_PLIST" | grep "<string>" | sed 's/.*<string>\([0-9.]*\)<\/string>.*/\1/')
if [ -z "$CURRENT_VERSION" ]; then
    CURRENT_VERSION="0.0.0"
fi

# 解析版本号 (major.minor.patch)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# 根据修复项目数递增 patch 版本号
NEW_PATCH=$((PATCH + FIX_COUNT))
NEW_VERSION="$MAJOR.$MINOR.$NEW_PATCH"

# 更新 Info.plist 中的版本号
sed -i '' "s/<string>$CURRENT_VERSION<\/string>/<string>$NEW_VERSION<\/string>/" "$INFO_PLIST"

echo "=========================================="
echo "WindowsSwitcher 打包脚本"
echo "=========================================="
echo ""
echo "📝 版本号更新："
echo "   修复项目数: $FIX_COUNT"
echo "   版本号: $CURRENT_VERSION -> $NEW_VERSION"
echo ""

# 自动增加 CFBundleVersion
echo "📝 自动增加 CFBundleVersion..."
CURRENT_BUILD=$(grep -A1 "CFBundleVersion" "$INFO_PLIST" | grep "<string>" | head -1 | sed 's/.*<string>\([0-9]*\)<\/string>.*/\1/')
if [ -z "$CURRENT_BUILD" ]; then
    CURRENT_BUILD=1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))
# 替换构建号
sed -i '' "s/<string>$CURRENT_BUILD<\/string>/<string>$NEW_BUILD<\/string>/" "$INFO_PLIST"
echo "   构建号: $CURRENT_BUILD -> $NEW_BUILD"

# 清理旧的构建
echo ""
echo "🔧 清理旧的构建..."
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Release 构建
echo ""
echo "🏗️  开始 Release 构建..."
cd "$PROJECT_DIR"
xcodebuild -project WindowsSwitcher.xcodeproj \
  -scheme WindowsSwitcher \
  -configuration Release \
  -derivedDataPath build \
  clean build \
  | tail -20

# 检查构建是否成功
APP_PATH="$BUILD_DIR/Build/Products/Release/WindowsSwitcher.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 构建失败：找不到 $APP_PATH"
    exit 1
fi

echo ""
echo "✅ 构建成功！"

# 创建 ZIP 压缩包
echo ""
echo "📦 创建 ZIP 压缩包..."
cd "$BUILD_DIR/Build/Products/Release"
zip -r "$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.zip" WindowsSwitcher.app
echo "✅ ZIP 创建成功：$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.zip"

# 创建 DMG 磁盘镜像（带自定义样式）
echo ""
echo "💿 创建 DMG 磁盘镜像..."

# DMG 配置
DMG_FINAL="$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.dmg"
DMG_ICON="$BUILD_DIR/Build/Products/Release/WindowsSwitcher.app/Contents/Resources/AppIcon.icns"
DMG_BACKGROUND="$PROJECT_DIR/scripts/dmg-background.png"

# 删除旧的 DMG（如果存在）
rm -f "$DMG_FINAL"

# 使用 create-dmg 创建带自定义样式的 DMG
create-dmg \
  --volname "Windows Switcher" \
  --volicon "$DMG_ICON" \
  --background "$DMG_BACKGROUND" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --text-size 12 \
  --icon-size 128 \
  --icon "WindowsSwitcher.app" 160 200 \
  --hide-extension "WindowsSwitcher.app" \
  --app-drop-link 500 200 \
  "$DMG_FINAL" \
  "$APP_PATH" 2>&1 | grep -v "^ "

# 清理临时 DMG 文件
rm -f "$OUTPUT_DIR"/rw.*.dmg 2>/dev/null

echo "✅ DMG 创建成功：$DMG_FINAL"

# 显示结果
echo ""
echo "=========================================="
echo "🎉 打包完成！"
echo "=========================================="
echo ""
echo "输出文件："
ls -lh "$OUTPUT_DIR"
echo ""
echo "文件位置：$OUTPUT_DIR"