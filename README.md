# Windows Switcher

<p align="center">
  <img src="Resources/AppIcon.png" alt="Windows Switcher Logo" width="128" />
</p>

<p align="center">
  <a href="https://github.com/jnMetaCode/agency-agents-zh/releases">
    <img src="https://img.shields.io/github/v/release/moeasy/WindowsSwitcher?color=blue&label=Version" alt="Version">
  </a>
  <a href="https://github.com/moeasy/WindowsSwitcher/stargazers">
    <img src="https://img.shields.io/github/stars/moeasy/WindowsSwitcher?color=orange" alt="Stars">
  </a>
  <a href="https://github.com/moeasy/WindowsSwitcher/issues">
    <img src="https://img.shields.io/github/issues/moeasy/WindowsSwitcher?color=red" alt="Issues">
  </a>
  <a href="https://github.com/moeasy/WindowsSwitcher/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/moeasy/WindowsSwitcher?color=green" alt="License">
  </a>
</p>

macOS 窗口切换增强工具，让你在 Mac 上也能体验 Windows 风格的窗口切换体验。

## ✨ 功能特性

### 🔄 窗口快速切换
- 使用 `Option + Tab` 快捷键呼出窗口切换面板
- 显示所有打开窗口的实时预览缩略图
- 支持按最近使用时间排序，快速找到目标窗口

### 🔂 同应用窗口切换
- 使用 `Option + `` ` (反引号) 快速切换同一应用的多个窗口
- 支持反向切换 `Option + Shift + `` `

### 🖼️ 程序坞窗口预览
- 悬停程序坞图标时自动显示该应用的窗口预览
- 悬停预览项时显示大尺寸实时预览
- 无需点击即可快速预览窗口内容

### ⚡ 快捷键自定义
- 所有快捷键均可自定义配置
- 支持修改窗口切换、同应用切换的快捷键
- 实时预览快捷键设置效果

### 🎨 主题定制
- 支持浅色、深色、自动跟随系统主题
- 多种界面主题可选
- 完美适配 macOS 系统外观

### 📐 智能布局
- 面板尺寸根据窗口数量自适应
- 预览窗口尺寸与实际窗口一致
- 支持多屏幕和不同分辨率

## 📋 系统要求

| 要求 | 最低版本 |
|------|----------|
| macOS | 13.0 (Ventura) |

## 🚀 安装说明

### 方法一：直接安装

1. 下载最新版本的 DMG 或 ZIP 文件：
   - [GitHub Releases](https://github.com/moeasy/WindowsSwitcher/releases)

2. 打开 DMG 文件，将应用拖拽到「应用程序」文件夹

3. 首次运行需要授权权限（见下文）

### 方法二：Homebrew（即将支持）

```bash
brew install windows-switcher
```

## 🔐 权限说明

首次运行应用时，系统会提示需要以下权限：

| 权限 | 用途 |
|------|------|
| **辅助功能权限** | 捕获窗口信息、监听快捷键、管理窗口切换 |
| **屏幕录制权限** | 生成窗口预览缩略图、实时窗口内容 |

### 授权步骤

1. 打开「系统设置」>「隐私与安全性」>「辅助功能」
2. 点击左下角 🔒 解锁
3. 将「Windows Switcher」添加到辅助功能列表
4. 同理在「屏幕录制」中添加应用

> ⚠️ **注意**：这些权限是应用核心功能所必需的，授权后才能正常使用。

## ⌨️ 默认快捷键

| 操作 | 快捷键 |
|------|---------|
| 打开窗口切换器 | `Option + Tab` |
| 切换上一个 | `Option + Shift + Tab` |
| 同应用窗口切换 | `Option + `` ` |
| 同应用窗口反向切换 | `Option + Shift + `` ` |
| 确认选择 | `Enter` |
| 取消 | `Escape` |

## 📖 使用指南

### 基本使用

1. 按住 `Option` 键不放
2. 按 `Tab` 键在窗口间切换
3. 释放 `Option` 键切换到目标窗口

### 同应用切换

1. 在目标应用中，按住 `Option` 键
2. 按 `` ` (反引号) 切换同一应用的其他窗口

### 程序坞预览

1. 将鼠标悬停在程序坞的应用图标上
2. 自动显示该应用的窗口列表
3. 继续悬停在某个窗口上查看大图预览
4. 点击直接切换到该窗口

## ⚙️ 设置

点击菜单栏图标或使用 `Command + ,` 打开设置界面：

- **通用**：启动行为、主题选择
- **切换器**：预览大小、列数、排序规则
- **预览**：背景预览开关
- **程序坞**：预览数量、动画效果、间距
- **快捷键**：自定义所有快捷键
- **关于**：版本信息、反馈链接

## 🛠️ 开发技术

- **UI 框架**: SwiftUI + AppKit
- **语言**: Swift 5.9+
- **架构**: MVVM
- **依赖管理**: Swift Package Manager

### 核心技术点

- Carbon API 用于全局热键注册
- Accessibility API 用于窗口管理
- ScreenCaptureKit 用于窗口预览生成
- NSPanel 实现悬浮面板

## 📝 更新日志

See [CHANGELOG.md](./CHANGELOG.md)

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

## 📄 开源协议

MIT License - See [LICENSE](./LICENSE)

---

<p align="center">
  Made with ❤️ by <a href="https://github.com/moeasy">moeasy</a>
</p>