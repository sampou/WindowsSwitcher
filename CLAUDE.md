# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Windows Switcher** is a macOS menu bar application that brings Windows-style window switching experience to Mac. It provides:
- Quick window switching (Option+Tab)
- Same-app window switching (Option+`)
- Dock preview windows (hover over Dock icons)
- Customizable shortcuts and themes

## Build Commands

```bash
# Debug build
xcodebuild -project WindowsSwitcher.xcodeproj -scheme WindowsSwitcher -configuration Debug build

# Release build
xcodebuild -project WindowsSwitcher.xcodeproj -scheme WindowsSwitcher -configuration Release build

# Build and package (ZIP + DMG)
./scripts/build-release.sh
```

## Version Convention

- **CFBundleShortVersionString**: Format `0.0.X` (主版本和次版本不超过1，修订号根据功能增加)
- **CFBundleVersion**: Auto-incremented by build script
- Update version in both `Info.plist` and `scripts/build-release.sh`

## Required Permissions

- **Accessibility**: Required for window management and global hotkeys
- **Screen Recording**: Required for window preview screenshots

## Architecture Overview

### Core Components

- **AppDelegate.swift** - Main app delegate, handles hotkey registration, panel management
- **WindowManager** - Core window management using CGWindowListCopyWindowInfo and AXUIElement
- **HotKeyManager** - Global hotkey registration using Carbon API
- **PreviewGenerator** - Window screenshot capture using ScreenCaptureKit

### UI Components

- **SwitchPanelView** - Main window switcher panel (Option+Tab)
- **DockPreviewPanelView** - Dock preview windows (hover preview)
- **SettingsView** - Application settings UI

### Configuration

- **ConfigModel** - All configuration data structures
- **ConfigManager** - Singleton for managing user preferences (UserDefaults)

### Key Patterns

- **MVVM Architecture**: ViewModels (SwitchPanelViewModel, DockPreviewManager) manage state
- **Singleton Pattern**: ConfigManager.shared, WindowManager.shared, ThemeManager.shared
- **ObservableObject**: State management via @Published properties
- **NSPanel**: Floating panels for window switcher and dock preview

### Important Implementation Details

1. **Window Tracking**: Uses CGWindowListCopyWindowInfo for window enumeration, CGWindowID as unique identifier
2. **Global Hotkeys**: Carbon API (RegisterEventHotKey) for system-wide shortcuts
3. **Window Preview**: ScreenCaptureKit for window screenshots
4. **Accessibility**: AXUIElement for window activation and state management
5. **Floating Panels**: NSPanel with .popUpMenu level for proper window layering

### Entry Points

- `WindowsSwitcherApp.swift` - SwiftUI App entry point
- `AppDelegate.swift` - NSApplicationDelegate, main app lifecycle

## Key Files

| File | Purpose |
|------|---------|
| Sources/AppDelegate.swift | Main app delegate, hotkeys, panel management |
| Sources/Core/WindowManager/WindowManager.swift | Window enumeration and management |
| Sources/Core/HotKeyManager/HotKeyManager.swift | Global hotkey registration |
| Sources/UI/SwitchPanel/SwitchPanelView.swift | Main switcher UI |
| Sources/UI/DockPreview/DockPreviewPanelView.swift | Dock preview panel |
| Sources/Config/ConfigManager.swift | User preferences (UserDefaults) |