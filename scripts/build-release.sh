#!/bin/bash
# WindowsSwitcher 自动化打包脚本
# 生成 ZIP 压缩包和 DMG 磁盘镜像

set -e

# 配置
VERSION="0.0.34"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/release"
BUILD_DIR="$PROJECT_DIR/build"
INFO_PLIST="$PROJECT_DIR/WindowsSwitcher/Sources/Info.plist"

echo "=========================================="
echo "WindowsSwitcher 打包脚本 v$VERSION"
echo "=========================================="
echo ""

# 自动增加 CFBundleVersion
echo "📝 自动增加 CFBundleVersion..."
CURRENT_BUILD=$(grep -A1 "CFBundleVersion" "$INFO_PLIST" | grep "<string>" | head -1 | sed 's/.*<string>\([0-9]*\)<\/string>.*/\1/')
if [ -z "$CURRENT_BUILD" ]; then
    CURRENT_BUILD=1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))
# 替换版本号
sed -i '' "s/<string>$CURRENT_BUILD<\/string>/<string>$NEW_BUILD<\/string>/" "$INFO_PLIST"
echo "   版本号: $CURRENT_BUILD -> $NEW_BUILD"

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
zip -r "$OUTPUT_DIR/WindowsSwitcher-$VERSION.zip" WindowsSwitcher.app
echo "✅ ZIP 创建成功：$OUTPUT_DIR/WindowsSwitcher-$VERSION.zip"

# 创建 DMG 磁盘镜像
echo ""
echo "💿 创建 DMG 磁盘镜像..."
cd "$PROJECT_DIR"

# 创建临时文件夹
rm -rf dmg_temp
mkdir -p dmg_temp

# 复制应用
cp -r "$APP_PATH" dmg_temp/

# 创建 Applications 快捷方式（引导用户拖拽安装）
ln -s /Applications dmg_temp/Applications

# 创建 DMG
hdiutil create -volname "Windows Switcher" \
  -srcfolder dmg_temp \
  -ov -format UDZO \
  "$OUTPUT_DIR/WindowsSwitcher-$VERSION.dmg"

# 清理临时文件
rm -rf dmg_temp

echo "✅ DMG 创建成功：$OUTPUT_DIR/WindowsSwitcher-$VERSION.dmg"

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