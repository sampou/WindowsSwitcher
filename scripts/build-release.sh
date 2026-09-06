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
RELEASE_MODE="${WINDOWSSWITCHER_RELEASE_MODE:-local}"
RELEASE_ARCHS="${WINDOWSSWITCHER_ARCHS:-arm64 x86_64}"
DEPLOYMENT_TARGET="${WINDOWSSWITCHER_DEPLOYMENT_TARGET:-13.0}"
REQUESTED_VERSION="${WINDOWSSWITCHER_VERSION:-}"
REQUESTED_BUILD="${WINDOWSSWITCHER_BUILD_NUMBER:-}"
EXPECTED_BUNDLE_ID="${WINDOWSSWITCHER_BUNDLE_ID:-com.moeasy.windowsswitcher}"
NOTARY_PROFILE="${WINDOWSSWITCHER_NOTARY_PROFILE:-}"
NOTARY_TIMEOUT="${WINDOWSSWITCHER_NOTARY_TIMEOUT:-3600}"
NOTARY_PREFLIGHT_TIMEOUT="${WINDOWSSWITCHER_NOTARY_PREFLIGHT_TIMEOUT:-60}"
ALLOW_DIRTY="${WINDOWSSWITCHER_ALLOW_DIRTY:-0}"
DMG_BACKEND="${WINDOWSSWITCHER_DMG_BACKEND:-hdiutil}"
CREATE_DMG_TIMEOUT="${WINDOWSSWITCHER_CREATE_DMG_TIMEOUT:-90}"
HDIUTIL_TIMEOUT="${WINDOWSSWITCHER_HDIUTIL_TIMEOUT:-120}"
HDIUTIL_INFO_TIMEOUT="${WINDOWSSWITCHER_HDIUTIL_INFO_TIMEOUT:-15}"
HDIUTIL_PREFLIGHT_TIMEOUT="${WINDOWSSWITCHER_HDIUTIL_PREFLIGHT_TIMEOUT:-20}"
LOCK_DIR="$PROJECT_DIR/.build-release.lock"
FORCE_UNLOCK="${WINDOWSSWITCHER_FORCE_UNLOCK:-0}"
LOCK_OWNED=0
RELEASE_SUCCEEDED=0
ORIGINAL_VERSION=""
ORIGINAL_BUILD=""
ATTACH_DEVICE=""
DMG_MOUNT_DIR=""
DMG_WORK=""
MOUNT_SNAPSHOT=""
INSTALL_STAGE=""
INSTALL_BACKUP=""
PUBLISH_BACKUP_DIR=""
PUBLISH_STARTED=0
PUBLISH_COMMITTED=0
DMG_FINAL=""
ZIP_FINAL=""
MANIFEST_FINAL=""
CHECKSUM_FINAL=""
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_DIR="$PROJECT_DIR/.release-logs/$RUN_ID"
CODESIGN_TIMESTAMP_ARGS=(--timestamp=none)

if ! [[ "$FIX_COUNT" =~ ^[0-9]+$ ]]; then
    echo "❌ 修复项目数必须是非负整数：$FIX_COUNT"
    exit 1
fi
if [ "$RELEASE_MODE" != "local" ] && [ "$RELEASE_MODE" != "distribution" ]; then
    echo "❌ 不支持的发布模式：$RELEASE_MODE（可选：local、distribution）"
    exit 1
fi
if [ -n "$REQUESTED_VERSION" ] && ! [[ "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ WINDOWSSWITCHER_VERSION 必须是 major.minor.patch：$REQUESTED_VERSION"
    exit 1
fi
if [ -n "$REQUESTED_BUILD" ] && ! [[ "$REQUESTED_BUILD" =~ ^[0-9]+$ ]]; then
    echo "❌ WINDOWSSWITCHER_BUILD_NUMBER 必须是非负整数：$REQUESTED_BUILD"
    exit 1
fi
if ! [[ "$DEPLOYMENT_TARGET" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "❌ WINDOWSSWITCHER_DEPLOYMENT_TARGET 无效：$DEPLOYMENT_TARGET"
    exit 1
fi
if [ -z "${RELEASE_ARCHS//[[:space:]]/}" ]; then
    echo "❌ WINDOWSSWITCHER_ARCHS 不能为空。"
    exit 1
fi
for release_arch in $RELEASE_ARCHS; do
    case "$release_arch" in
        arm64|x86_64) ;;
        *)
            echo "❌ 不支持的发布架构：$release_arch（可选：arm64、x86_64）"
            exit 1
            ;;
    esac
done
for timeout_value in \
    "$NOTARY_TIMEOUT" \
    "$NOTARY_PREFLIGHT_TIMEOUT" \
    "$CREATE_DMG_TIMEOUT" \
    "$HDIUTIL_TIMEOUT" \
    "$HDIUTIL_INFO_TIMEOUT" \
    "$HDIUTIL_PREFLIGHT_TIMEOUT"; do
    if ! [[ "$timeout_value" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ 所有超时参数必须是正整数秒：$timeout_value"
        exit 1
    fi
done

acquire_release_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        LOCK_OWNED=1
        return
    fi

    local existing_pid=""
    existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ "$FORCE_UNLOCK" != "1" ]; then
        echo "❌ 发布锁已存在（记录 PID：${existing_pid:-unknown}），为避免并发打包已停止。"
        echo "   确认没有其他 build-release.sh 进程后，可设置 WINDOWSSWITCHER_FORCE_UNLOCK=1 清理失效锁。"
        exit 1
    fi

    echo "🧹 按显式授权清理已失效的发布锁。"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    LOCK_OWNED=1
}

find_project_dmg_sessions() {
    awk -F ' : ' '/^image-path/ { print $2 }' \
        | while IFS= read -r image_path; do
            case "$image_path" in
                "$PROJECT_DIR"/release/WindowsSwitcher-*|\
                "$PROJECT_DIR"/build/*WindowsSwitcher-*|\
                /private/tmp/WindowsSwitcher-*)
                    printf '%s\n' "$image_path"
                    ;;
            esac
        done
}

cleanup_current_dmg_session() {
    [ -n "$DMG_WORK" ] || return 0
    local session_info="" session_info_log
    session_info_log="/private/tmp/WindowsSwitcher-session-info.$$.log"
    if ! run_with_timeout "$HDIUTIL_INFO_TIMEOUT" "$session_info_log" hdiutil info; then
        rm -f "$session_info_log"
        echo "⚠️  清理阶段无法读取 DiskImages 会话，请在再次打包前重启 macOS。"
        return 0
    fi
    session_info=$(awk -v target="$DMG_WORK" '
            BEGIN { RS="================================================" }
            index($0, "image-path      : " target) { print }
        ' "$session_info_log" || true)
    rm -f "$session_info_log"
    [ -n "$session_info" ] || return 0

    local device
    while IFS= read -r device; do
        [ -n "$device" ] && umount -f "$device" 2>/dev/null || true
    done < <(printf '%s\n' "$session_info" \
        | awk '/^\/dev\/disk/ { device=$1; sub(/s[0-9]+$/, "", device); print device }' \
        | sort -u)

    local session_pid session_uid
    session_pid=$(printf '%s\n' "$session_info" | awk -F ' : ' '/^process ID/ { print $2; exit }')
    if [[ "$session_pid" =~ ^[0-9]+$ ]]; then
        session_uid=$(ps -p "$session_pid" -o uid= 2>/dev/null | tr -d ' ' || true)
        if [ "$session_uid" = "$(id -u)" ]; then
            kill "$session_pid" 2>/dev/null || true
            sleep 1
            kill -9 "$session_pid" 2>/dev/null || true
        fi
    fi
}

restore_release_metadata_on_failure() {
    if [ "$RELEASE_SUCCEEDED" -eq 0 ] && [ -n "$ORIGINAL_VERSION" ] && [ -n "$ORIGINAL_BUILD" ]; then
        if /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ORIGINAL_VERSION" "$INFO_PLIST" \
            && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ORIGINAL_BUILD" "$INFO_PLIST"; then
            echo "🧹 打包失败，已恢复版本号和构建号。"
        else
            echo "⚠️  打包失败，但版本元数据自动恢复失败，请检查 $INFO_PLIST。" >&2
        fi
    fi
    if [ -n "$DMG_MOUNT_DIR" ] && mount | grep -Fq " on $DMG_MOUNT_DIR "; then
        umount -f "$DMG_MOUNT_DIR" 2>/dev/null || true
    fi
    if [ "$RELEASE_SUCCEEDED" -eq 0 ]; then
        cleanup_current_dmg_session
    fi
    if [ -n "$INSTALL_BACKUP" ] && [ -d "$INSTALL_BACKUP" ] && [ ! -d "$INSTALL_PATH" ]; then
        mv "$INSTALL_BACKUP" "$INSTALL_PATH" 2>/dev/null || true
    fi
    if [ -n "$INSTALL_STAGE" ] && [ -d "$INSTALL_STAGE" ]; then
        rm -rf "$INSTALL_STAGE"
    fi
    if [ "$PUBLISH_STARTED" -eq 1 ] && [ "$PUBLISH_COMMITTED" -eq 0 ]; then
        local published_path backup_path
        for published_path in "$DMG_FINAL" "$ZIP_FINAL" "$MANIFEST_FINAL" "$CHECKSUM_FINAL"; do
            [ -n "$published_path" ] || continue
            rm -f "$published_path"
            backup_path="$PUBLISH_BACKUP_DIR/$(basename "$published_path")"
            if [ -f "$backup_path" ]; then
                mv "$backup_path" "$published_path" 2>/dev/null || true
            fi
        done
        echo "🧹 产物发布未完成，已恢复上一组同版本发布文件。"
    fi
    if [ -n "$PUBLISH_BACKUP_DIR" ] && [ -d "$PUBLISH_BACKUP_DIR" ]; then
        rm -rf "$PUBLISH_BACKUP_DIR"
    fi
    if [ "$LOCK_OWNED" -eq 1 ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
        rm -rf "$LOCK_DIR"
    fi
}

trap restore_release_metadata_on_failure EXIT
trap 'exit 130' INT TERM HUP

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

submit_for_notarization() {
    local artifact_path="$1"
    local artifact_label="$2"
    local submission_log="$LOG_DIR/notary-${artifact_label}-submission.json"
    local detail_log="$LOG_DIR/notary-${artifact_label}-detail.json"
    local submission_status submission_id

    if ! run_with_timeout "$NOTARY_TIMEOUT" "$submission_log" xcrun notarytool submit \
        "$artifact_path" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json; then
        tail -40 "$submission_log" >&2 || true
        echo "❌ ${artifact_label} 公证提交失败，日志：$submission_log"
        return 1
    fi

    submission_status=$(plutil -extract status raw -o - "$submission_log" 2>/dev/null || true)
    submission_id=$(plutil -extract id raw -o - "$submission_log" 2>/dev/null || true)
    if [ "$submission_status" != "Accepted" ]; then
        if [ -n "$submission_id" ]; then
            xcrun notarytool log "$submission_id" \
                --keychain-profile "$NOTARY_PROFILE" \
                "$detail_log" >/dev/null 2>&1 || true
            tail -80 "$detail_log" >&2 || true
        fi
        echo "❌ ${artifact_label} 公证未通过：${submission_status:-unknown}（ID：${submission_id:-unknown}）"
        return 1
    fi

    echo "✅ ${artifact_label} 公证通过（ID：$submission_id）"
}

staple_and_validate() {
    local artifact_path="$1"
    local artifact_label="$2"
    local staple_log="$LOG_DIR/stapler-${artifact_label}.log"
    xcrun stapler staple "$artifact_path" >"$staple_log" 2>&1
    xcrun stapler validate "$artifact_path" >>"$staple_log" 2>&1
    echo "✅ ${artifact_label} 公证票据已附加并验证"
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
    auto|create-dmg|hdiutil) ;;
    *)
        echo "❌ 不支持的 DMG 后端：$DMG_BACKEND"
        echo "   可选值：auto、create-dmg、hdiutil"
        exit 1
        ;;
esac

if [ "$RELEASE_MODE" = "distribution" ]; then
    if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
        echo "❌ distribution 模式必须使用 Developer ID Application 签名身份。"
        echo "   请通过 WINDOWSSWITCHER_SIGN_IDENTITY 传入完整身份名称。"
        exit 1
    fi
    if [ -z "$NOTARY_PROFILE" ]; then
        echo "❌ distribution 模式缺少 WINDOWSSWITCHER_NOTARY_PROFILE。"
        echo "   请先用 xcrun notarytool store-credentials 将凭据存入钥匙串。"
        exit 1
    fi
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS" 2>/dev/null || true)" = "true" ]; then
        echo "❌ distribution 模式不允许 com.apple.security.get-task-allow=true。"
        exit 1
    fi
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
        echo "❌ distribution 模式默认要求干净工作树。"
        echo "   请先提交发布内容；只有已审查的特殊发布才可设置 WINDOWSSWITCHER_ALLOW_DIRTY=1。"
        exit 1
    fi
    CODESIGN_TIMESTAMP_ARGS=(--timestamp)
fi

acquire_release_lock
mkdir -p "$LOG_DIR"
echo "📝 发布日志：$LOG_DIR"

if [ "$RELEASE_MODE" = "distribution" ]; then
    NOTARY_PREFLIGHT_LOG="$LOG_DIR/notary-history-preflight.json"
    if ! run_with_timeout "$NOTARY_PREFLIGHT_TIMEOUT" "$NOTARY_PREFLIGHT_LOG" xcrun notarytool history \
        --keychain-profile "$NOTARY_PROFILE" \
        --output-format json; then
        tail -40 "$NOTARY_PREFLIGHT_LOG" >&2 || true
        echo "❌ 公证凭据或网络预检失败，已在构建前停止。"
        exit 1
    fi
    echo "✅ Apple 公证凭据与网络预检通过"
fi

# 旧的本项目映像会话会让 DiskImages 卡死；在修改版本号前提前失败。
HDIUTIL_INFO_LOG="$LOG_DIR/diskimages-info.log"
if ! run_with_timeout "$HDIUTIL_INFO_TIMEOUT" "$HDIUTIL_INFO_LOG" hdiutil info; then
    echo "❌ DiskImages 预检超时，在构建和修改版本号之前停止。"
    echo "   请先重启 macOS，不要在当前异常会话中继续创建 DMG。"
    exit 1
fi
STALE_DMG_IMAGES=$(find_project_dmg_sessions <"$HDIUTIL_INFO_LOG" || true)
if [ -n "$STALE_DMG_IMAGES" ]; then
    echo "❌ 检测到 WindowsSwitcher 遗留的磁盘映像会话："
    echo "$STALE_DMG_IMAGES"
    echo "   请先在 Finder 侧边栏弹出对应卷；如仍无法弹出，重启 macOS 后重试。"
    exit 1
fi

# 在编译前创建一个小型可写 UDIF，确认 DiskImages 不仅能查询，也能实际创建映像。
PREFLIGHT_DMG="/private/tmp/WindowsSwitcher-preflight.$$.dmg"
PREFLIGHT_CREATE_LOG="$LOG_DIR/diskimages-create-preflight.log"
DMG_WORK="$PREFLIGHT_DMG"
if run_with_timeout "$HDIUTIL_PREFLIGHT_TIMEOUT" "$PREFLIGHT_CREATE_LOG" hdiutil create \
    -size 8m \
    -fs HFS+ \
    -volname "WindowsSwitcher Preflight" \
    "$PREFLIGHT_DMG"; then
    :
else
    PREFLIGHT_STATUS=$?
    cleanup_current_dmg_session
    tail -20 "$PREFLIGHT_CREATE_LOG" 2>/dev/null || true
    rm -f "$PREFLIGHT_DMG"
    echo "❌ DiskImages 创建能力预检失败（状态：${PREFLIGHT_STATUS}），已在编译前停止。"
    echo "   请恢复 DiskImages 服务或重启 macOS 后重试。"
    exit 1
fi
rm -f "$PREFLIGHT_DMG"
DMG_WORK=""
echo "✅ DiskImages 创建能力预检通过"

# 在修改版本号前确认签名环境，避免预检失败仍然递增版本。
if ! security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | grep -Fq "$SIGNING_IDENTITY"; then
    echo "❌ 找不到本地签名身份：$SIGNING_IDENTITY"
    echo "   请先在登录钥匙串中配置该身份，或设置 WINDOWSSWITCHER_SIGN_IDENTITY。"
    exit 1
fi

# 从 Info.plist 精确读取当前版本号和构建号。
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true)
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || true)
if ! [[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Info.plist 中的 CFBundleShortVersionString 无效：${CURRENT_VERSION:-<empty>}"
    exit 1
fi
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "❌ Info.plist 中的 CFBundleVersion 无效：${CURRENT_BUILD:-<empty>}"
    exit 1
fi
ORIGINAL_VERSION="$CURRENT_VERSION"
ORIGINAL_BUILD="$CURRENT_BUILD"

# 解析版本号 (major.minor.patch)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# CI/正式发布可显式指定版本号；本地开发继续兼容修复项目数递增方式。
if [ -n "$REQUESTED_VERSION" ]; then
    NEW_VERSION="$REQUESTED_VERSION"
else
    NEW_PATCH=$((PATCH + FIX_COUNT))
    NEW_VERSION="$MAJOR.$MINOR.$NEW_PATCH"
fi

# 精确更新 Info.plist 中的版本号
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"

echo "=========================================="
echo "WindowsSwitcher 打包脚本"
echo "=========================================="
echo ""
echo "📝 版本号更新："
echo "   修复项目数: $FIX_COUNT"
echo "   版本号: $CURRENT_VERSION -> $NEW_VERSION"
echo "   发布模式: $RELEASE_MODE"
echo "   目标架构: $RELEASE_ARCHS"
echo ""

# 自动增加 CFBundleVersion
echo "📝 自动增加 CFBundleVersion..."
if [ -n "$REQUESTED_BUILD" ]; then
    NEW_BUILD="$REQUESTED_BUILD"
else
    NEW_BUILD=$((CURRENT_BUILD + 1))
fi
if [ "$RELEASE_MODE" = "distribution" ] && [ "$NEW_BUILD" -le "$CURRENT_BUILD" ]; then
    echo "❌ distribution 模式的构建号必须大于当前构建号 $CURRENT_BUILD。"
    exit 1
fi
# 精确替换构建号
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
echo "   构建号: $CURRENT_BUILD -> $NEW_BUILD"

# 清理旧的构建
echo ""
echo "🔧 清理旧的构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

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
BUILD_LOG="$LOG_DIR/xcodebuild.log"
if ! xcodebuild -project WindowsSwitcher.xcodeproj \
    -scheme WindowsSwitcher \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath build \
    ARCHS="$RELEASE_ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    "${XCODE_SIGNING_ARGS[@]}" \
    clean build \
    >"$BUILD_LOG" 2>&1; then
    tail -80 "$BUILD_LOG" >&2
    echo "❌ Release 构建失败，完整日志：$BUILD_LOG"
    exit 1
fi
tail -20 "$BUILD_LOG"

# 检查构建是否成功
APP_PATH="$BUILD_DIR/Build/Products/Release/WindowsSwitcher.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 构建失败：找不到 $APP_PATH"
    exit 1
fi

echo ""
echo "✅ 构建成功！"

APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_INFO_PLIST")
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_INFO_PLIST")
APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_INFO_PLIST")
if [ "$APP_VERSION" != "$NEW_VERSION" ] || [ "$APP_BUILD" != "$NEW_BUILD" ] || [ "$APP_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "❌ 构建产物元数据不一致："
    echo "   version=$APP_VERSION（期望 $NEW_VERSION）"
    echo "   build=$APP_BUILD（期望 $NEW_BUILD）"
    echo "   bundle-id=$APP_BUNDLE_ID（期望 $EXPECTED_BUNDLE_ID）"
    exit 1
fi

ACTUAL_ARCHS=$(lipo -archs "$APP_EXECUTABLE")
for release_arch in $RELEASE_ARCHS; do
    if [[ " $ACTUAL_ARCHS " != *" $release_arch "* ]]; then
        echo "❌ 构建产物缺少架构 $release_arch，实际架构：$ACTUAL_ARCHS"
        exit 1
    fi
done
echo "✅ 元数据与架构校验通过：$APP_BUNDLE_ID $APP_VERSION ($APP_BUILD), $ACTUAL_ARCHS"

# 使用稳定的本地身份签名，确保 macOS 权限和应用身份可持续匹配。
echo ""
echo "🔐 使用本地签名身份：$SIGNING_IDENTITY"
xattr -cr "$APP_PATH"
codesign --force \
  --options runtime \
  "${CODESIGN_TIMESTAMP_ARGS[@]}" \
  --entitlements "$ENTITLEMENTS" \
  --keychain "$SIGNING_KEYCHAIN" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH" >"$LOG_DIR/codesign-app.log" 2>&1
echo "✅ 应用签名校验通过"

if [ "$RELEASE_MODE" = "distribution" ]; then
    APP_NOTARY_DIR="$BUILD_DIR/notary"
    APP_NOTARY_ZIP="$APP_NOTARY_DIR/WindowsSwitcher-$NEW_VERSION-app.zip"
    mkdir -p "$APP_NOTARY_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_NOTARY_ZIP"
    submit_for_notarization "$APP_NOTARY_ZIP" "app"
    staple_and_validate "$APP_PATH" "app"
    spctl --assess --type execute --verbose=4 "$APP_PATH" >"$LOG_DIR/spctl-app.log" 2>&1
    echo "✅ Gatekeeper 应用评估通过"
fi

# 创建 ZIP 压缩包
echo ""
echo "📦 创建 ZIP 压缩包..."
ZIP_FINAL="$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.zip"
ARTIFACT_STAGE="$BUILD_DIR/package-artifacts"
ZIP_WORK="$ARTIFACT_STAGE/WindowsSwitcher-$NEW_VERSION.zip"
mkdir -p "$ARTIFACT_STAGE"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_WORK"
echo "✅ ZIP 候选产物创建成功，将在 DMG 验证通过后发布。"

# 创建 DMG 磁盘镜像（带自定义样式）
echo ""
echo "💿 创建 DMG 磁盘镜像..."

# DMG 配置
DMG_FINAL="$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.dmg"
DMG_WORK="$ARTIFACT_STAGE/WindowsSwitcher-$NEW_VERSION.dmg"
DMG_ICON="$BUILD_DIR/Build/Products/Release/WindowsSwitcher.app/Contents/Resources/AppIcon.icns"
DMG_BACKGROUND="$PROJECT_DIR/scripts/dmg-background.png"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DMG_LOG="$LOG_DIR/dmg-create.log"
MOUNT_SNAPSHOT="$BUILD_DIR/dmg-mounts-before.txt"
DMG_MOUNT_DIR="$BUILD_DIR/dmg-mounted"
DMG_GENERATOR=""

# create-dmg 的 source 必须是包含应用的目录，不能直接传 .app bundle。
rm -rf "$STAGE_DIR" "$DMG_MOUNT_DIR"
mkdir -p "$STAGE_DIR"
ditto "$APP_PATH" "$STAGE_DIR/WindowsSwitcher.app"
capture_window_switcher_devices >"$MOUNT_SNAPSHOT"
rm -f "$DMG_WORK" "$DMG_LOG"

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
      "$DMG_WORK" \
      "$STAGE_DIR"
}

create_hdiutil_dmg() {
    ln -sfn /Applications "$STAGE_DIR/Applications"
    run_with_timeout "$HDIUTIL_TIMEOUT" "$DMG_LOG" hdiutil create \
      -volname "Windows Switcher" \
      -srcfolder "$STAGE_DIR" \
      -ov \
      -format UDZO \
      "$DMG_WORK"
}

try_create_dmg() {
    local backend="$1"
    rm -f "$DMG_WORK" "$ARTIFACT_STAGE"/rw.*.dmg
    case "$backend" in
        create-dmg) create_styled_dmg ;;
        hdiutil) create_hdiutil_dmg ;;
    esac
}

if [ "$DMG_BACKEND" = "auto" ]; then
    DMG_BACKEND="hdiutil"
fi

if [ "$DMG_BACKEND" = "create-dmg" ]; then
    echo "⚠️  create-dmg 会进行 Finder 样式自动化，只在显式指定时使用。"
fi

if try_create_dmg "$DMG_BACKEND"; then
    DMG_GENERATOR="$DMG_BACKEND"
else
    DMG_STATUS=$?
    cleanup_new_window_switcher_devices "$MOUNT_SNAPSHOT"
    cleanup_current_dmg_session
    tail -20 "$DMG_LOG" 2>/dev/null || true
    if [ "$DMG_STATUS" -eq 124 ]; then
        echo "❌ DiskImages 创建超时，已停止后续打包，不会在同一次任务中重试 hdiutil。"
    else
        echo "❌ 无法创建原生 macOS DMG（退出码：$DMG_STATUS）。"
    fi
    echo "   候选 ZIP 仅保留在 build 目录，未发布到 release。"
    echo "   不会使用 ISO 伪装 DMG，也不会覆盖上一个有效发布包。"
    exit 1
fi

cleanup_new_window_switcher_devices "$MOUNT_SNAPSHOT"
rm -f "$ARTIFACT_STAGE"/rw.*.dmg 2>/dev/null

[[ -s "$DMG_WORK" ]] || { echo "❌ DMG 创建失败：找不到有效候选产物 $DMG_WORK"; exit 1; }
DMG_SIZE=$(stat -f%z "$DMG_WORK")
if [ "$DMG_SIZE" -lt 1048576 ]; then
    echo "❌ DMG 创建失败：产物仅 ${DMG_SIZE} 字节，疑似中断文件"
    exit 1
fi

UDIF_SIGNATURE=$(dd if="$DMG_WORK" bs=1 skip=$((DMG_SIZE - 512)) count=4 2>/dev/null | xxd -p)
if [ "$UDIF_SIGNATURE" != "6b6f6c79" ]; then
    echo "❌ 候选产物缺少 UDIF koly 尾标，拒绝将非原生映像发布为 DMG。"
    exit 1
fi

if [ "$RELEASE_MODE" = "distribution" ]; then
    codesign --force \
        "${CODESIGN_TIMESTAMP_ARGS[@]}" \
        --keychain "$SIGNING_KEYCHAIN" \
        --sign "$SIGNING_IDENTITY" \
        "$DMG_WORK"
    codesign --verify --verbose=2 "$DMG_WORK"
    submit_for_notarization "$DMG_WORK" "dmg"
    staple_and_validate "$DMG_WORK" "dmg"
    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$DMG_WORK" \
        >"$LOG_DIR/spctl-dmg.log" 2>&1
    echo "✅ Gatekeeper DMG 评估通过"
fi

# 只发布由 macOS DiskImages 服务创建、校验且能够真实挂载的 UDIF 映像。
run_with_timeout "$HDIUTIL_TIMEOUT" "$LOG_DIR/dmg-verify.log" hdiutil verify "$DMG_WORK"
DMG_ATTACH_LOG="$LOG_DIR/dmg-attach.log"
mkdir -p "$DMG_MOUNT_DIR"
if ! run_with_timeout "$HDIUTIL_TIMEOUT" "$DMG_ATTACH_LOG" hdiutil attach \
    -nobrowse \
    -readonly \
    -mountpoint "$DMG_MOUNT_DIR" \
    "$DMG_WORK"; then
    cat "$DMG_ATTACH_LOG" >&2
    echo "❌ DMG 无法由 macOS 挂载，拒绝发布。"
    exit 1
fi
ATTACH_DEVICE=$(awk '/^\/dev\/disk[0-9]+[[:space:]]/ { print $1; exit }' "$DMG_ATTACH_LOG")
if [ -z "$ATTACH_DEVICE" ] || [ ! -d "$DMG_MOUNT_DIR/WindowsSwitcher.app" ]; then
    echo "❌ DMG 挂载内容不完整，拒绝发布。"
    umount -f "$DMG_MOUNT_DIR" 2>/dev/null || true
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$DMG_MOUNT_DIR/WindowsSwitcher.app"
run_with_timeout "$HDIUTIL_TIMEOUT" "$LOG_DIR/dmg-detach.log" hdiutil detach "$ATTACH_DEVICE"
ATTACH_DEVICE=""

# ZIP 也必须能够解包并通过签名校验，两个候选产物均成功后才发布。
PACKAGE_INSTALL_DIR="$BUILD_DIR/package-install"
rm -rf "$PACKAGE_INSTALL_DIR"
mkdir -p "$PACKAGE_INSTALL_DIR"
ditto -x -k "$ZIP_WORK" "$PACKAGE_INSTALL_DIR"
codesign --verify --deep --strict --verbose=2 "$PACKAGE_INSTALL_DIR/WindowsSwitcher.app"

DMG_SHA256=$(shasum -a 256 "$DMG_WORK" | awk '{print $1}')
ZIP_SHA256=$(shasum -a 256 "$ZIP_WORK" | awk '{print $1}')
SOURCE_COMMIT=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null || true)" ]; then
    SOURCE_STATE="dirty"
else
    SOURCE_STATE="clean"
fi
MANIFEST_FINAL="$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.manifest.txt"
CHECKSUM_FINAL="$OUTPUT_DIR/WindowsSwitcher-$NEW_VERSION.sha256"
MANIFEST_WORK="$ARTIFACT_STAGE/WindowsSwitcher-$NEW_VERSION.manifest.txt"
CHECKSUM_WORK="$ARTIFACT_STAGE/WindowsSwitcher-$NEW_VERSION.sha256"
{
    echo "product=WindowsSwitcher"
    echo "version=$NEW_VERSION"
    echo "build=$NEW_BUILD"
    echo "bundle_id=$APP_BUNDLE_ID"
    echo "release_mode=$RELEASE_MODE"
    echo "architectures=$ACTUAL_ARCHS"
    echo "macos_deployment_target=$DEPLOYMENT_TARGET"
    echo "dmg_backend=$DMG_GENERATOR"
    echo "dmg_sha256=$DMG_SHA256"
    echo "zip_sha256=$ZIP_SHA256"
    echo "source_commit=$SOURCE_COMMIT"
    echo "source_state=$SOURCE_STATE"
    echo "xcode_version=$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$MANIFEST_WORK"
{
    echo "$DMG_SHA256  $(basename "$DMG_FINAL")"
    echo "$ZIP_SHA256  $(basename "$ZIP_FINAL")"
} >"$CHECKSUM_WORK"

PUBLISH_BACKUP_DIR="$BUILD_DIR/publish-backup-$RUN_ID"
mkdir -p "$PUBLISH_BACKUP_DIR"
PUBLISH_STARTED=1
for published_path in "$DMG_FINAL" "$ZIP_FINAL" "$MANIFEST_FINAL" "$CHECKSUM_FINAL"; do
    if [ -f "$published_path" ]; then
        mv "$published_path" "$PUBLISH_BACKUP_DIR/$(basename "$published_path")"
    fi
done
mv -f "$DMG_WORK" "$DMG_FINAL"
mv -f "$ZIP_WORK" "$ZIP_FINAL"
mv -f "$MANIFEST_WORK" "$MANIFEST_FINAL"
mv -f "$CHECKSUM_WORK" "$CHECKSUM_FINAL"
(cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$CHECKSUM_FINAL")") >"$LOG_DIR/checksum-verify.log"
PUBLISH_COMMITTED=1
rm -rf "$PUBLISH_BACKUP_DIR"
PUBLISH_BACKUP_DIR=""
RELEASE_SUCCEEDED=1
echo "✅ DMG 创建并校验成功：${DMG_FINAL}（后端：${DMG_GENERATOR}）"
echo "✅ ZIP 解包与签名校验成功：${ZIP_FINAL}"
echo "✅ SHA-256 校验清单：${CHECKSUM_FINAL}"

# 产物校验通过后，从 ZIP 安装包解包并安装到 /Applications。
echo ""
echo "📥 安装应用到 $INSTALL_PATH ..."
killall WindowsSwitcher 2>/dev/null || true
INSTALL_STAGE="/Applications/.WindowsSwitcher.install.$$"
INSTALL_BACKUP="/Applications/.WindowsSwitcher.backup.$$"
rm -rf "$INSTALL_STAGE" "$INSTALL_BACKUP"
ditto "$PACKAGE_INSTALL_DIR/WindowsSwitcher.app" "$INSTALL_STAGE"
codesign --verify --deep --strict --verbose=2 "$INSTALL_STAGE"
if [ -d "$INSTALL_PATH" ]; then
    mv "$INSTALL_PATH" "$INSTALL_BACKUP"
fi
if ! mv "$INSTALL_STAGE" "$INSTALL_PATH"; then
    [ -d "$INSTALL_BACKUP" ] && mv "$INSTALL_BACKUP" "$INSTALL_PATH" || true
    echo "❌ 新版本原子替换失败，已恢复旧版应用。"
    exit 1
fi
rm -rf "$INSTALL_BACKUP"
INSTALL_STAGE=""
INSTALL_BACKUP=""
codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
echo "✅ 安装完成：$INSTALL_PATH"
if open "$INSTALL_PATH"; then
    echo "✅ 应用已启动"
else
    echo "⚠️  应用已安装，但自动启动失败，请从“应用程序”手动打开。"
fi

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
