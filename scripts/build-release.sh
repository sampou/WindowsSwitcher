#!/bin/bash
# WindowsSwitcher 自动化打包脚本
# 生成 ZIP 压缩包和 DMG 磁盘镜像

set -e

# 配置
VERSION="1.0.0"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/release"
BUILD_DIR="$PROJECT_DIR/build"

echo "=========================================="
echo "WindowsSwitcher 打包脚本 v$VERSION"
echo "=========================================="
echo ""

# 清理旧的构建
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
