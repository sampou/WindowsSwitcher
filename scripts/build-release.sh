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
DMG_BACKEND="${WINDOWSSWITCHER_DMG_BACKEND:-auto}"
CREATE_DMG_TIMEOUT="${WINDOWSSWITCHER_CREATE_DMG_TIMEOUT:-90}"
HDIUTIL_TIMEOUT="${WINDOWSSWITCHER_HDIUTIL_TIMEOUT:-60}"

# 递归结束超时命令及其子进程，避免 create-dmg/hdiutil 留下孤儿 helper。
terminate_process_tree() {
    local parent_pid="$1"
    local child_pid
    for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
        terminate_process_tree "$child_pid"
    done
    kill "$parent_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$parent_pid" 2>/dev/null || true
}

# macOS 不内置 timeout；这里提供可控超时并把完整输出写入日志。
run_with_timeout() {
    local timeout_seconds="$1"
    local log_file="$2"
    shift 2
    "$@" >"$log_file" 2>&1 &
    local command_pid=$!
    local elapsed=0
    while kill -0 "$command_pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            echo "⚠️  命令执行超过 ${timeout_seconds}s，正在清理进程树：$1"
            terminate_process_tree "$command_pid"
            wait "$command_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$command_pid"
}

# 记录执行前已挂载的同名卷，仅清理本次打包新增的临时卷。
capture_window_switcher_devices() {
    mount | awk '/ on \/Volumes\/Windows Switcher/ {print $1}' | sort -u
}

cleanup_new_window_switcher_devices() {
    local before_file="$1"
    local device
    for device in $(capture_window_switcher_devices); do
        if ! grep -Fqx "$device" "$before_file" 2>/dev/null; then
            echo "🧹 卸载本次打包遗留的临时卷：$device"
            umount -f "$device" 2>/dev/null || true
        fi
    done
}

case "$DMG_BACKEND" in
    auto|create-dmg|hdiutil|xorriso) ;;
    *)
        echo "❌ 不支持的 DMG 后端：$DMG_BACKEND"
        echo "   可选值：auto、create-dmg、hdiutil、xorriso"
        exit 1
        ;;
esac

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
ZIP_FINAL="$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_FINAL"
echo "✅ ZIP 创建成功：$ZIP_FINAL"

# 创建 DMG 磁盘镜像（带自定义样式）
echo ""
echo "💿 创建 DMG 磁盘镜像..."

# DMG 配置
DMG_FINAL="$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.dmg"
DMG_ICON="$BUILD_DIR/Build/Products/Release/WindowsSwitcher.app/Contents/Resources/AppIcon.icns"
DMG_BACKGROUND="$PROJECT_DIR/scripts/dmg-background.png"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DMG_LOG="$BUILD_DIR/dmg-create.log"
MOUNT_SNAPSHOT="$BUILD_DIR/dmg-mounts-before.txt"
DMG_VERIFY_DIR="$BUILD_DIR/dmg-verify"
DMG_GENERATOR=""

# create-dmg 的 source 必须是包含应用的目录，不能直接传 .app bundle。
rm -rf "$STAGE_DIR" "$DMG_VERIFY_DIR"
mkdir -p "$STAGE_DIR"
ditto "$APP_PATH" "$STAGE_DIR/WindowsSwitcher.app"
capture_window_switcher_devices >"$MOUNT_SNAPSHOT"
rm -f "$DMG_FINAL" "$DMG_LOG"

create_styled_dmg() {
    command -v create-dmg >/dev/null 2>&1 || return 127
    run_with_timeout "$CREATE_DMG_TIMEOUT" "$DMG_LOG" create-dmg \
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
      "$STAGE_DIR"
}

create_hdiutil_dmg() {
    ln -sfn /Applications "$STAGE_DIR/Applications"
    run_with_timeout "$HDIUTIL_TIMEOUT" "$DMG_LOG" hdiutil create \
      -volname "Windows Switcher" \
      -srcfolder "$STAGE_DIR" \
      -ov \
      -format UDZO \
      "$DMG_FINAL"
}

create_xorriso_dmg() {
    command -v xorriso >/dev/null 2>&1 || {
        echo "❌ xorriso 未安装。请执行：brew install xorriso"
        return 127
    }
    ln -sfn /Applications "$STAGE_DIR/Applications"
    xorriso -as mkisofs \
      -R \
      -J \
      -hfsplus \
      -V "Windows Switcher" \
      -o "$DMG_FINAL" \
      "$STAGE_DIR" >"$DMG_LOG" 2>&1
}

try_create_dmg() {
    local backend="$1"
    rm -f "$DMG_FINAL" "$OUTPUT_DIR"/rw.*.dmg
    case "$backend" in
        create-dmg) create_styled_dmg ;;
        hdiutil) create_hdiutil_dmg ;;
        xorriso) create_xorriso_dmg ;;
    esac
}

if [ "$DMG_BACKEND" = "auto" ]; then
    if try_create_dmg create-dmg; then
        DMG_GENERATOR="create-dmg"
    else
        CREATE_DMG_STATUS=$?
        cleanup_new_window_switcher_devices "$MOUNT_SNAPSHOT"
        tail -20 "$DMG_LOG" 2>/dev/null || true
        if [ "$CREATE_DMG_STATUS" -eq 124 ]; then
            echo "⚠️  create-dmg 内部的 hdiutil 超时，跳过同源 hdiutil 回退。"
        elif try_create_dmg hdiutil; then
            DMG_GENERATOR="hdiutil"
        else
            cleanup_new_window_switcher_devices "$MOUNT_SNAPSHOT"
            tail -20 "$DMG_LOG" 2>/dev/null || true
        fi
        if [ -z "$DMG_GENERATOR" ]; then
            echo "⚠️  改用不依赖 DiskImages 服务的 xorriso 后端..."
            try_create_dmg xorriso
            DMG_GENERATOR="xorriso"
        fi
    fi
else
    try_create_dmg "$DMG_BACKEND"
    DMG_GENERATOR="$DMG_BACKEND"
fi

cleanup_new_window_switcher_devices "$MOUNT_SNAPSHOT"
rm -f "$OUTPUT_DIR"/rw.*.dmg 2>/dev/null

[[ -s "$DMG_FINAL" ]] || { echo "❌ DMG 创建失败：找不到有效产物 $DMG_FINAL"; exit 1; }
DMG_SIZE=$(stat -f%z "$DMG_FINAL")
if [ "$DMG_SIZE" -lt 1048576 ]; then
    echo "❌ DMG 创建失败：产物仅 ${DMG_SIZE} 字节，疑似中断文件"
    exit 1
fi

# xorriso 产物通过真实解包和签名校验；原生 UDIF 产物交给 hdiutil 校验。
if [ "$DMG_GENERATOR" = "xorriso" ]; then
    mkdir -p "$DMG_VERIFY_DIR"
    xorriso -osirrox on \
      -indev "$DMG_FINAL" \
      -extract /WindowsSwitcher.app "$DMG_VERIFY_DIR/WindowsSwitcher.app" \
      >"$BUILD_DIR/dmg-verify.log" 2>&1
    codesign --verify --deep --strict --verbose=2 "$DMG_VERIFY_DIR/WindowsSwitcher.app"
    xorriso -indev "$DMG_FINAL" \
      -find /Applications -maxdepth 0 -exec lsdl -- \
      >"$BUILD_DIR/dmg-link-verify.log" 2>&1
    grep -Fq "'/Applications' -> '/Applications'" "$BUILD_DIR/dmg-link-verify.log" || {
        echo "❌ DMG 缺少 Applications 链接"
        exit 1
    }
    xorriso -indev "$DMG_FINAL" \
      -report_system_area plain \
      >"$BUILD_DIR/dmg-system-area.log" 2>&1
    grep -Fq "Apple_HFS" "$BUILD_DIR/dmg-system-area.log" || {
        echo "❌ DMG 缺少 HFS+ 混合分区"
        exit 1
    }
else
    run_with_timeout "$HDIUTIL_TIMEOUT" "$BUILD_DIR/dmg-verify.log" hdiutil verify "$DMG_FINAL"
fi
echo "✅ DMG 创建并校验成功：${DMG_FINAL}（后端：${DMG_GENERATOR}）"

# 产物校验通过后，从 ZIP 安装包解包并安装到 /Applications。
echo ""
echo "📥 安装应用到 $INSTALL_PATH ..."
PACKAGE_INSTALL_DIR="$BUILD_DIR/package-install"
rm -rf "$PACKAGE_INSTALL_DIR"
mkdir -p "$PACKAGE_INSTALL_DIR"
ditto -x -k "$ZIP_FINAL" "$PACKAGE_INSTALL_DIR"
codesign --verify --deep --strict --verbose=2 "$PACKAGE_INSTALL_DIR/WindowsSwitcher.app"
killall WindowsSwitcher 2>/dev/null || true
mkdir -p "$INSTALL_PATH"
rsync -aE --delete --checksum "$PACKAGE_INSTALL_DIR/WindowsSwitcher.app/" "$INSTALL_PATH/"
codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
echo "✅ 安装完成：$INSTALL_PATH"
open "$INSTALL_PATH"
echo "✅ 应用已启动"

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
