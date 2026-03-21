# WindowsSwitcher v1.0 发布检查清单

## T-066 App 签名配置

### 签名要求
- [ ] 开发者账号：Apple Developer Program 已注册
- [ ] 证书：Developer ID Application 证书已创建并安装
- [ ] Provisioning Profile：Developer ID 类型
- [ ] Bundle ID：`com.windowsswitcher.app`

### 签名命令
```bash
# 签名
codesign --deep --force --verify --verbose \
  --sign "Developer ID Application: YOUR_NAME (TEAM_ID)" \
  --entitlements Sources/WindowsSwitcher.entitlements \
  .build/release/WindowsSwitcher

# 验证签名
codesign --verify --deep --strict --verbose=2 .build/release/WindowsSwitcher

# 检查 Gatekeeper
spctl --assess --type exec --verbose .build/release/WindowsSwitcher
```

### 公证（Notarization）
```bash
# 打包为 zip
ditto -c -k --keepParent .build/release/WindowsSwitcher WindowsSwitcher.zip

# 提交公证
xcrun notarytool submit WindowsSwitcher.zip \
  --apple-id "your@email.com" \
  --team-id "TEAM_ID" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# 附加公证票据
xcrun stapler staple .build/release/WindowsSwitcher
```

---

## T-067 权限配置验证

### Entitlements 检查
| 权限 | 值 | 说明 |
|------|-----|------|
| `com.apple.security.app-sandbox` | false | 需要 AX API 和屏幕录制 |
| `com.apple.security.automation.apple-events` | true | Apple Events 支持 |

### 运行时权限（用户授权）
| 权限 | 触发时机 | 说明 |
|------|---------|------|
| 辅助功能 | 首次启动 | 窗口切换核心功能 |
| 屏幕录制 | 首次生成预览 | 窗口缩略图生成 |

### 权限检查代码验证
- [x] `AXIsProcessTrusted()` 无权限时优雅降级
- [x] `CGPreflightScreenCaptureAccess()` 无权限时返回 nil 预览
- [x] 权限描述字符串已在 Info.plist 中配置

---

## T-068 应用元数据

### Bundle 信息
| 字段 | 值 |
|------|-----|
| Bundle ID | `com.windowsswitcher.app` |
| 版本号 | 1.0.0 |
| Build 号 | 1 |
| 最低系统版本 | macOS 13.0 |
| 显示名称 | Windows Switcher |
| 类型 | 菜单栏应用（LSUIElement = true）|

### 发布前检查
- [x] Info.plist 版本号正确（1.0.0 / build 1）
- [x] LSMinimumSystemVersion = 13.0
- [x] NSHighResolutionCapable = true（Retina 支持）
- [x] NSSupportsAutomaticGraphicsSwitching = true（省电）
- [x] 权限描述字符串（中文）
- [x] 支持语言：zh-Hans, en
- [ ] AppIcon.icns 已生成（1024×1024 基础图）
- [ ] 代码签名完成
- [ ] 公证完成

### 构建发布版本
```bash
cd /Users/sampou/mac_workspace/WindowsSwitcher/WindowsSwitcher
swift build -c release 2>&1

# 验证二进制
file .build/release/WindowsSwitcher
otool -L .build/release/WindowsSwitcher
```

### DMG 打包（可选）
```bash
# 创建 DMG
hdiutil create -volname "Windows Switcher" \
  -srcfolder .build/release/WindowsSwitcher \
  -ov -format UDZO \
  WindowsSwitcher-1.0.0.dmg
```

---

## 发布前最终验证

- [x] 176/176 测试通过
- [x] 0 编译警告，0 编译错误
- [x] 性能：FilterEngine <100ms，搜索 <50ms，窗口操作 <50ms
- [x] 兼容性：macOS 13/14/15，深色/浅色模式
- [x] 安全：无敏感数据泄露，权限最小化
- [x] 可访问性：颜色对比度 ≥4.5:1，键盘导航完整
- [ ] 真机测试：macOS 13 / 14 / 15
- [ ] 代码签名 + 公证
- [ ] 发布说明（Release Notes）撰写完成
