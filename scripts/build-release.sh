#!/bin/bash
# WindowsSwitcher 自动化打包脚本
# 生成 ZIP 压缩包和 DMG 磁盘镜像
#
# 用法：
#   bash build-release.sh [修复项目数]
#   例如：bash build-release.sh 2  # 修复了2个项目，版本号递增0.0.2

set -euo pipefail

# 获取修复项目数（默认为1）
FIX_COUNT=${1:-1}

# 配置
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/release"
BUILD_DIR="$PROJECT_DIR/build"
INFO_PLIST="$PROJECT_DIR/WindowsSwitcher/Sources/Info.plist"
SIGNING_IDENTITY="${WINDOWSSWITCHER_SIGN_IDENTITY:-WindowsSwitcher Local Signing}"
SIGNING_KEYCHAIN="${WINDOWSSWITCHER_SIGN_KEYCHAIN:-$(security default-keychain -d user | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/')}"
ENTITLEMENTS="$PROJECT_DIR/WindowsSwitcher/Sources/WindowsSwitcher.entitlements"
INSTALL_PATH="/Applications/WindowsSwitcher.app"

# 在修改版本号前确认签名环境，避免预检失败仍然递增版本。
if ! security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | grep -Fq "$SIGNING_IDENTITY"; then
    echo "❌ 找不到本地签名身份：$SIGNING_IDENTITY"
    echo "   请先在登录钥匙串中配置该身份，或设置 WINDOWSSWITCHER_SIGN_IDENTITY。"
    exit 1
fi

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

# 先使用无签名构建，再用本机固定身份签名，避免 Xcode 自动签名受团队配置影响。
XCODE_SIGNING_ARGS=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    DEVELOPMENT_TEAM=""
)

# Release 构建
echo ""
echo "🏗️  开始 Release 构建..."
cd "$PROJECT_DIR"
xcodebuild -project WindowsSwitcher.xcodeproj \
  -scheme WindowsSwitcher \
  -configuration Release \
  -derivedDataPath build \
  "${XCODE_SIGNING_ARGS[@]}" \
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

# 使用稳定的本地身份签名，确保 macOS 权限和应用身份可持续匹配。
echo ""
echo "🔐 使用本地签名身份：$SIGNING_IDENTITY"
codesign --force \
  --deep \
  --options runtime \
  --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  --keychain "$SIGNING_KEYCHAIN" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "✅ 应用签名校验通过"

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

# 使用 create-dmg 创建带自定义样式的 DMG；失败时回退到基础 hdiutil
if ! create-dmg \
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
then
  echo "⚠️  create-dmg 失败，改用 hdiutil 直接创建 DMG..."
  STAGE_DIR="$BUILD_DIR/dmg-stage"
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"
  cp -R "$APP_PATH" "$STAGE_DIR/"
  hdiutil create \
    -volname "Windows Switcher" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_FINAL"
fi

# 清理临时 DMG 文件和 staging 目录
rm -f "$OUTPUT_DIR"/rw.*.dmg 2>/dev/null
rm -rf "$BUILD_DIR/dmg-stage" 2>/dev/null

[[ -f "$DMG_FINAL" ]] || { echo "❌ DMG 创建失败：找不到 $DMG_FINAL"; exit 1; }
echo "✅ DMG 创建成功：$DMG_FINAL"

# 产物校验通过后自动安装到 /Applications。
echo ""
echo "📥 安装应用到 $INSTALL_PATH ..."
mkdir -p "$INSTALL_PATH"
rsync -aE --delete --checksum "$APP_PATH/" "$INSTALL_PATH/"
codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
echo "✅ 安装完成：$INSTALL_PATH"

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
