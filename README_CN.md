# Windows Switcher

<p align="center">
  <img src="WindowsSwitcher/Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" alt="Windows Switcher 图标" width="128">
</p>

<p align="center">
  <a href="https://github.com/sampou/WindowsSwitcher/releases"><img src="https://img.shields.io/github/v/release/sampou/WindowsSwitcher?color=blue&label=Version" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13 或更高版本">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift" alt="Swift 5.9 或更高版本">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

Windows Switcher 是一款原生 macOS 窗口切换增强工具，提供接近 Windows Alt+Tab 的操作体验，并集成完整窗口缩略图、模糊搜索、可配置排序、同应用切换、程序坞预览和键盘驱动的窗口布局。

## 功能特性

### 窗口切换

- 按 **Option+Tab** 打开切换器，并显示当前发现的全部窗口缩略图。
- 按 Tab 正向选择、按 Shift+Tab 反向选择，释放 Option 后激活选中窗口。
- 支持按应用名称、窗口标题或 Bundle Identifier 模糊搜索。
- 支持最近使用、应用名称、窗口标题和应用分组四种排序方式。
- 可调整缩略图尺寸和每行列数，并可选择是否显示最小化或隐藏窗口。
- 支持键盘和鼠标导航，选中项会自动保持在可见区域内。

### 同应用窗口切换

- 按 **Option+`** 在当前应用的多个窗口间切换。
- 按住 Shift 可反向切换。
- 可在设置中启用、关闭或重新配置快捷键。

### 程序坞窗口预览

- 鼠标悬停程序坞应用图标时显示该应用的窗口列表。
- 悬停列表项可查看大图预览，点击后激活对应窗口。
- 可配置显示延迟、预览数量、尺寸、间距、应用图标和动画。

### 窗口布局

- 支持左/右/上/下半屏、四个角、最大化、居中、上一显示器和下一显示器。
- 默认使用 **Control+Option+L** 打开独立窗口布局面板。
- 使用 Tab 或方向键选择，Enter 或空格执行，Escape 关闭面板。
- 点击布局行任意位置即可执行；布局操作只改变位置和尺寸，不激活目标窗口。
- 右键点击状态栏图标可使用同一组窗口布局操作，并查看对应快捷键。
- 每个布局操作都可注册和重设全局快捷键；布局面板、设置页和状态栏菜单使用统一的快捷键符号。

### 原生 macOS 体验

- 支持浅色、深色和跟随系统三种外观模式。
- 使用 SwiftUI 与 AppKit 构建界面，通过 Carbon 注册全局快捷键，通过辅助功能 API 管理窗口，通过 ScreenCaptureKit 生成预览。
- 支持配置持久化、窗口活动顺序持久化、登录时启动和版本更新检查。

## 系统要求

| 要求 | 最低版本 |
| --- | --- |
| macOS | 13.0 Ventura |
| 构建工具 | 包含 Swift 5.9 或更高版本的 Xcode |

安装后的应用需要以下 macOS 权限：

| 权限 | 用途 |
| --- | --- |
| 辅助功能 | 发现、激活、移动、缩放和关闭窗口，并支持全局交互 |
| 屏幕录制 | 获取实时窗口缩略图和预览 |

请在 **系统设置 → 隐私与安全性** 中完成授权。授权后如果预览或窗口操作没有立即生效，请完全退出并重新打开 Windows Switcher。

## 安装

推荐通过打包后的应用安装运行，因为 macOS 权限与已签名的应用包身份关联。

1. 从 [GitHub Releases](https://github.com/sampou/WindowsSwitcher/releases) 下载最新 DMG。
2. 打开 DMG，将 **WindowsSwitcher.app** 拖入“应用程序”。
3. 启动应用并授予辅助功能与屏幕录制权限。

无法挂载 DMG 时，也可以使用发布页面提供的 ZIP 安装包。

## 默认快捷键

所有快捷键均可在 **设置 → 快捷键** 中修改。

| 操作 | 默认快捷键 |
| --- | --- |
| 打开窗口切换器 | Option+Tab |
| 反向窗口切换 | Option+Shift+Tab |
| 同应用窗口切换 | Option+` |
| 同应用窗口反向切换 | Option+Shift+` |
| 打开布局面板 | Control+Option+L |
| 左/右半屏 | Control+Option+← / → |
| 上/下半屏 | Control+Option+↑ / ↓ |
| 左上/右上角 | Control+Option+U / I |
| 左下/右下角 | Control+Option+J / K |
| 最大化/居中 | Control+Option+Return / C |
| 上一/下一显示器 | Control+Option+Command+← / → |

## 状态栏

- **左键点击：**打开窗口切换器。
- **右键点击：**打开包含切换器、窗口布局、设置和退出的菜单。
- 窗口布局子菜单优先使用当前最前方的可操作窗口，并在菜单打开期间固定该目标。

## 设置

- **通用：**登录时启动、更新选项和外观模式。
- **切换器：**最小化/隐藏窗口、初始选择和背景预览。
- **预览：**缩略图尺寸和每行列数。
- **程序坞：**程序坞预览的行为与显示效果。
- **快捷键：**切换器、同应用切换、布局总开关以及每个布局组合键。
- **关于：**版本和应用信息。

## 构建与测试

克隆仓库并运行完整测试：

```bash
git clone https://github.com/sampou/WindowsSwitcher.git
cd WindowsSwitcher
swift test --package-path WindowsSwitcher
```

仅进行开发期命令行构建时可执行：

```bash
swift build --package-path WindowsSwitcher
```

涉及 macOS 权限的验收应使用项目发布脚本生成已签名应用和 DMG，不建议直接运行 SwiftPM 裸可执行文件：

```bash
WINDOWSSWITCHER_DMG_BACKEND=xorriso bash scripts/build-release.sh 0
```

该脚本会：

- 自动增加 `CFBundleVersion`；传入的数字同时表示补丁版本递增量；
- 默认使用 `WindowsSwitcher Local Signing` 本地身份签名 Release 应用；
- 在 `release/` 生成并校验 ZIP 与 DMG；
- 将校验通过的应用安装到 `/Applications/WindowsSwitcher.app` 并启动。

如需使用其他本地签名身份，可设置 `WINDOWSSWITCHER_SIGN_IDENTITY`。DMG 后端支持 `auto`、`create-dmg`、`hdiutil` 和 `xorriso`；使用 xorriso 前可执行 `brew install xorriso`。

> 发布脚本会修改构建号，并替换“应用程序”目录内已经安装的版本。

## 项目结构

```text
WindowsSwitcher/
├── WindowsSwitcher/
│   ├── Sources/                 # 应用源码
│   ├── Resources/               # 资源目录
│   └── Tests/                   # SwiftPM 测试
├── scripts/build-release.sh     # 签名、ZIP/DMG 打包与安装
├── tools/user-e2e/              # 用户级冒烟测试
└── docs/CHANGELOG.md            # 版本更新记录
```

## 文档与链接

- [版本更新记录](docs/CHANGELOG.md)
- [用户级冒烟测试](tools/user-e2e/README.md)
- [GitHub Releases](https://github.com/sampou/WindowsSwitcher/releases)
- [GitHub Issues](https://github.com/sampou/WindowsSwitcher/issues)
- [Gitee 镜像](https://gitee.com/sampou/WindowsSwitcher)
- [MIT License](LICENSE)

## 参与贡献

欢迎提交 Issue 和 Pull Request。提交代码前请运行 `swift test --package-path WindowsSwitcher`。
