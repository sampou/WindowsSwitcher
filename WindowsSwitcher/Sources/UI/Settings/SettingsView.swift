import SwiftUI
import Carbon
import AppKit

// ============================================
// F07 设置面板 - 响应式设计，统一交互规范
// ============================================

struct SettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showResetConfirm = false
    @State private var selectedGroup: SettingsGroup = .general

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // 左侧导航栏
                settingsSidebar(width: sidebarWidth(for: geometry.size.width))
                    .frame(width: sidebarWidth(for: geometry.size.width))
                    .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // 右侧内容区
                ScrollView {
                    settingsContent()
                        .padding(.horizontal, DesignTokens.Spacing.xl)
                        .padding(.vertical, DesignTokens.Spacing.lg)
                }
            }
        }
        .frame(
            minWidth: ResponsiveSize.minWindowSize.width,
            minHeight: ResponsiveSize.minWindowSize.height
        )
        .preferredColorScheme(themeManager.effectiveColorScheme)
        .environment(\.locale, L10n.locale)
        // 保存失败横幅
        .overlay(alignment: .top) {
            if let error = config.saveError {
                saveErrorBanner(error: error)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            "确认恢复默认设置？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.text("恢复默认"), role: .destructive) { config.reset() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("所有设置将恢复为出厂默认值，此操作不可撤销。"))
        }
    }

    // MARK: - 响应式侧边栏宽度

    private func sidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        max(140, min(180, containerWidth * 0.25))
    }

    // MARK: - 侧边栏

    @ViewBuilder
    private func settingsSidebar(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 应用标题
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("Windows Switcher")
                    .font(FontSystem.titleSmall)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.xl)

            Divider()
                .padding(.vertical, DesignTokens.Spacing.sm)

            // 导航列表
            ForEach(SettingsGroup.allCases, id: \.self) { group in
                sidebarItem(for: group)
            }

            Spacer()

            // 版本信息
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("版本 %@", appVersion))
                    .font(FontSystem.captionSmall)
                    .foregroundStyle(DesignTokens.Colors.tertiaryLabel)
                Text("Build \(buildNumber)")
                    .font(FontSystem.captionSmall)
                    .foregroundStyle(DesignTokens.Colors.tertiaryLabel)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.lg)
        }
    }

    @ViewBuilder
    private func sidebarItem(for group: SettingsGroup) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedGroup = group
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: group.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)

                Text(group.displayName)
                    .font(FontSystem.bodyMedium)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background {
                if selectedGroup == group {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.button)
                        .fill(Color.accentColor.opacity(0.15))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedGroup == group ? .primary : DesignTokens.Colors.secondaryLabel)
        .focusable(false)  // 禁用焦点环
    }

    // MARK: - 内容区

    @ViewBuilder
    private func settingsContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 页面标题
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedGroup.displayName)
                        .font(FontSystem.titleLarge)
                    Text(selectedGroup.description)
                        .font(FontSystem.captionMedium)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                }
                Spacer()

                // 重置按钮
                Button {
                    showResetConfirm = true
                } label: {
                    Label(L10n.text("恢复默认"), systemImage: "arrow.counterclockwise")
                        .font(FontSystem.buttonSmall)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .focusable(false)
            }
            .padding(.bottom, DesignTokens.Spacing.lg)

            Divider()
                .padding(.bottom, DesignTokens.Spacing.lg)

            // 具体设置内容
            switch selectedGroup {
            case .general:
                GeneralSettingsView()
            case .switcher:
                SwitcherSettingsView()
            case .preview:
                PreviewSettingsView()
            case .dock:
                DockSettingsView()
            case .hotkey:
                HotKeySettingsView()
            case .about:
                AboutSettingsView()
            }
        }
    }

    // MARK: - 错误提示横幅

    @ViewBuilder
    private func saveErrorBanner(error: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(error)
                .font(FontSystem.bodySmall)
            Spacer()
            Button {
                config.saveError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(Color.yellow.opacity(0.15))
    }

    // MARK: - 版本信息

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// ============================================
// 通用设置
// ============================================

struct GeneralSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var updateService = UpdateService.shared
    @State private var updateNotificationController: UpdateNotificationWindowController?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            // 启动设置
            SettingsSection(title: "启动", icon: "power") {
                SettingsToggle(
                    title: "开机自动启动",
                    description: "登录后自动在后台运行",
                    isOn: $launchAtLogin.isEnabled
                )
            }

            // 更新设置
            SettingsSection(title: "软件更新", icon: "arrow.clockwise") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    HStack {
                        SettingsToggle(
                            title: "自动检查更新",
                            description: "定期检查是否有新版本",
                            isOn: $config.config.update.autoCheckEnabled
                        )
                        .onChange(of: config.config.update.autoCheckEnabled) { newValue in
                            if newValue {
                                updateService.startAutoCheck()
                            } else {
                                updateService.stopAutoCheck()
                            }
                        }

                        Spacer()

                        // 手动检查按钮（仅当自动检查关闭时显示）
                        if !config.config.update.autoCheckEnabled {
                            Button {
                                Task {
                                    await updateService.checkForUpdate()
                                    if updateService.updateAvailable {
                                        await MainActor.run {
                                            showUpdateNotification()
                                        }
                                    }
                                }
                            } label: {
                                if updateService.isChecking {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 14))
                                }
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .help(L10n.text("检查更新"))
                        }
                    }

                    // 自动下载选项（仅当自动检查打开时显示）
                    if config.config.update.autoCheckEnabled {
                        SettingsToggle(
                            title: "自动下载安装",
                            description: "发现新版本时自动下载并提示安装",
                            isOn: $config.config.update.autoDownloadEnabled
                        )
                    }

                    // 静默安装选项
                    SettingsToggle(
                        title: "静默安装",
                        description: "自动完成安装，无需手动拖拽应用",
                        isOn: $config.config.update.silentInstallEnabled
                    )

                    // 错误提示
                    if let error = updateService.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(FontSystem.captionMedium)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 当前版本信息
                    HStack {
                        Text(L10n.format("当前版本: v%@ (%@)", updateService.currentVersion, String(updateService.currentBuildNumber)))
                            .font(FontSystem.captionMedium)
                            .foregroundStyle(DesignTokens.Colors.secondaryLabel)

                        if let latest = updateService.latestVersion, updateService.updateAvailable {
                            Text(L10n.format("• 最新版本: v%@", latest.version))
                                .font(FontSystem.captionMedium)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            // 主题设置
            SettingsSection(title: "主题", icon: "paintbrush") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(L10n.text("外观模式"))
                        .font(FontSystem.bodyMedium)

                    Picker("", selection: $config.config.appearance.theme) {
                        Text(L10n.text("浅色")).tag(AppTheme.light)
                        Text(L10n.text("深色")).tag(AppTheme.dark)
                        Text(L10n.text("跟随系统")).tag(AppTheme.auto)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Spacer()
        }
    }

    /// 显示版本更新提示窗口
    private func showUpdateNotification() {
        updateNotificationController = UpdateNotificationWindowController {
            updateNotificationController?.close()
            updateNotificationController = nil
        }
        updateNotificationController?.show()
    }
}

// ============================================
// 切换器设置
// ============================================

struct SwitcherSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            // 窗口显示
            SettingsSection(title: "窗口显示", icon: "rectangle.on.rectangle") {
                SettingsToggle(
                    title: "显示最小化/隐藏的窗口",
                    description: "在切换器中显示已最小化或隐藏的窗口",
                    isOn: $config.config.behavior.showOffScreenWindows
                )

                SettingsToggle(
                    title: "默认选中第二个窗口",
                    description: "打开切换器时自动选中第二近使用的窗口",
                    isOn: $config.config.behavior.defaultSelectSecond
                )
            }

            // 切换器背景预览
            SettingsSection(title: "背景预览", icon: "rectangle.dashed") {
                SettingsToggle(
                    title: "显示背景预览",
                    description: "切换窗口时在背景显示目标窗口的大预览",
                    isOn: $config.config.behavior.showBackgroundPreview
                )
            }

            Spacer()
        }
    }
}

// ============================================
// 预览设置
// ============================================

struct PreviewSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            // 预览大小
            SettingsSection(title: "预览大小", icon: "rectangle.expand.vertical") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(L10n.text("预览窗口大小"))
                        .font(FontSystem.bodyMedium)

                    Picker("", selection: $config.config.appearance.previewSize) {
                        Text(L10n.text("小")).tag(PreviewSize.small)
                        Text(L10n.text("中")).tag(PreviewSize.medium)
                        Text(L10n.text("大")).tag(PreviewSize.large)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // 每行列数
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(L10n.text("每行列数"))
                        .font(FontSystem.bodyMedium)

                    Picker("", selection: $config.config.appearance.switcherColumns) {
                        Text(L10n.text("自动")).tag(0)
                        Text(L10n.text("3列")).tag(3)
                        Text(L10n.text("4列")).tag(4)
                        Text(L10n.text("5列")).tag(5)
                        Text(L10n.text("6列")).tag(6)
                        Text(L10n.text("8列")).tag(8)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Spacer()
        }
    }
}

// ============================================
// 程序坞设置
// ============================================

struct DockSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            // 启用开关
            SettingsSection(title: "程序坞预览", icon: "dock.rectangle") {
                SettingsToggle(
                    title: "启用程序坞预览",
                    description: "鼠标悬停在 Dock 图标上时显示窗口预览",
                    isOn: $config.config.dockPreview.enabled
                )
            }

            if config.config.dockPreview.enabled {
                // 延迟设置
                SettingsSection(title: "延迟设置", icon: "clock") {
                    SettingsSlider(
                        title: "悬停延迟",
                        value: $config.config.dockPreview.hoverDelay,
                        range: 0.05...0.5,
                        step: 0.05,
                        unit: "ms",
                        multiplier: 1000
                    )

                    SettingsSlider(
                        title: "隐藏延迟",
                        value: $config.config.dockPreview.hideDelay,
                        range: 0.05...0.5,
                        step: 0.05,
                        unit: "ms",
                        multiplier: 1000
                    )
                }

                // 显示设置
                SettingsSection(title: "显示设置", icon: "slider.horizontal.3") {
                    SettingsSlider(
                        title: "最大预览数量",
                        value: Binding(
                            get: { Double(config.config.dockPreview.maxPreviewCount) },
                            set: { config.config.dockPreview.maxPreviewCount = Int($0) }
                        ),
                        range: 2...16,
                        step: 1,
                        unit: "个"
                    )

                    SettingsToggle(
                        title: "显示动画效果",
                        description: "预览窗口显示/隐藏时的渐变动画",
                        isOn: Binding(
                            get: { config.config.dockPreview.showAnimation },
                            set: { config.config.dockPreview.showAnimation = $0 }
                        )
                    )

                    SettingsToggle(
                        title: "显示应用图标",
                        description: "在预览窗口中显示对应的软件图标",
                        isOn: Binding(
                            get: { config.config.dockPreview.showAppIcon },
                            set: { config.config.dockPreview.showAppIcon = $0 }
                        )
                    )
                }

                // 间距设置
                SettingsSection(title: "间距设置", icon: "arrow.up.and.down") {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        HStack {
                            Text(L10n.text("垂直间距"))
                                .font(FontSystem.bodyMedium)
                            Spacer()
                            if config.config.dockPreview.verticalSpacing > 0 {
                                Text("\(Int(config.config.dockPreview.verticalSpacing)) 像素")
                                    .font(FontSystem.bodySmall)
                                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            } else {
                                Text(L10n.text("自动"))
                                    .font(FontSystem.bodySmall)
                                    .foregroundStyle(DesignTokens.Colors.accent)
                            }
                        }

                        Slider(
                            value: Binding(
                                get: { config.config.dockPreview.verticalSpacing },
                                set: { config.config.dockPreview.verticalSpacing = $0 }
                            ),
                            in: 0...32,
                            step: 2
                        )
                        .tint(DesignTokens.Colors.accent)

                        Text(L10n.text("设置为 0 时自动根据屏幕分辨率计算最佳间距"))
                            .font(FontSystem.captionSmall)
                            .foregroundStyle(DesignTokens.Colors.tertiaryLabel)
                    }

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        HStack {
                            Text(L10n.text("水平间距"))
                                .font(FontSystem.bodyMedium)
                            Spacer()
                            if config.config.dockPreview.horizontalSpacing > 0 {
                                Text("\(Int(config.config.dockPreview.horizontalSpacing)) 像素")
                                    .font(FontSystem.bodySmall)
                                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            } else {
                                Text(L10n.text("自动"))
                                    .font(FontSystem.bodySmall)
                                    .foregroundStyle(DesignTokens.Colors.accent)
                            }
                        }

                        Slider(
                            value: Binding(
                                get: { config.config.dockPreview.horizontalSpacing },
                                set: { config.config.dockPreview.horizontalSpacing = $0 }
                            ),
                            in: 0...32,
                            step: 2
                        )
                        .tint(DesignTokens.Colors.accent)

                        Text(L10n.text("用于 Dock 位于左侧或右侧时的间距"))
                            .font(FontSystem.captionSmall)
                            .foregroundStyle(DesignTokens.Colors.tertiaryLabel)
                    }
                }
            }

            Spacer()
        }
    }
}

// ============================================
// 快捷键设置
// ============================================

struct HotKeySettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @State private var conflictWarning: String?
    @State private var showResetConfirm = false
    @State private var showConflictAlert = false
    @State private var currentConflict: HotKeyConflictInfo?
    @State private var pendingHotKeyType: String?
    @State private var previousKeyCode: UInt32?
    @State private var previousModifiers: UInt32?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            // 窗口切换快捷键
            SettingsSection(title: "窗口切换", icon: "rectangle.on.rectangle") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text(L10n.text("显示切换器"))
                        .font(FontSystem.bodyMedium)

                    HotKeyRecorder(
                        keyCode: $config.config.hotKeys.switchKeyCode,
                        modifiers: $config.config.hotKeys.switchModifiers,
                        placeholder: "⌥ Tab",
                        onReset: {
                            config.config.hotKeys.switchKeyCode = 48
                            config.config.hotKeys.switchModifiers = 2048
                        },
                        onConflict: { conflict in
                            currentConflict = conflict
                            pendingHotKeyType = "switch"
                            showConflictAlert = true
                        },
                        onBeforeChange: {
                            previousKeyCode = config.config.hotKeys.switchKeyCode
                            previousModifiers = config.config.hotKeys.switchModifiers
                        }
                    )
                }

                Text(L10n.text("反向切换：按住 Shift 即可反向切换，无需单独设置"))
                    .font(FontSystem.captionMedium)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            }

            // 应用内切换快捷键
            SettingsSection(title: "应用内切换", icon: "app.badge") {
                SettingsToggle(
                    title: "启用同应用窗口切换",
                    description: "使用快捷键在当前应用的窗口之间切换",
                    isOn: $config.config.hotKeys.appSwitchEnabled
                )

                if config.config.hotKeys.appSwitchEnabled {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        Text(L10n.text("同应用窗口切换快捷键"))
                            .font(FontSystem.bodyMedium)

                        HotKeyRecorder(
                            keyCode: $config.config.hotKeys.appSwitchKeyCode,
                            modifiers: $config.config.hotKeys.appSwitchModifiers,
                            placeholder: "⌥ `",
                            onReset: {
                                config.config.hotKeys.appSwitchKeyCode = 50
                                config.config.hotKeys.appSwitchModifiers = 2048
                            },
                            onConflict: { conflict in
                                currentConflict = conflict
                                pendingHotKeyType = "appSwitch"
                                showConflictAlert = true
                            },
                            onBeforeChange: {
                                previousKeyCode = config.config.hotKeys.appSwitchKeyCode
                                previousModifiers = config.config.hotKeys.appSwitchModifiers
                            }
                        )
                    }

                    Text(L10n.text("按下快捷键后，切换面板将只显示当前应用的窗口"))
                        .font(FontSystem.captionMedium)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                }
            }

            SettingsSection(title: "语言", icon: "globe") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(L10n.text("应用语言"))
                        .font(FontSystem.bodyMedium)

                    Picker("", selection: $config.config.appearance.language) {
                        Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                        Text(L10n.text("简体中文")).tag(AppLanguage.zhHans)
                        Text(L10n.text("English")).tag(AppLanguage.en)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(L10n.text("切换后立即应用；已经打开的独立面板请关闭后重新打开。"))
                        .font(FontSystem.captionMedium)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                }
            }

            SettingsSection(title: "窗口布局", icon: "rectangle.split.1x2") {
                SettingsToggle(
                    title: "启用窗口布局全局快捷键",
                    description: "关闭后保留所有组合键设置，但不再全局注册",
                    isOn: $config.config.hotKeys.windowLayout.isEnabled
                )

                VStack(spacing: 0) {
                    LayoutHotKeyEditor(
                        title: "打开布局面板",
                        symbolName: "rectangle.on.rectangle",
                        chord: Binding(
                            get: { config.config.hotKeys.windowLayout.openPanel },
                            set: { config.config.hotKeys.windowLayout.openPanel = $0 }
                        ),
                        defaultChord: WindowLayoutHotKeyDefaults.openPanel
                    )

                    ForEach(WindowLayoutActionCatalog.actions) { action in
                        Divider()

                        LayoutHotKeyEditor(
                            title: action.title,
                            symbolName: action.symbolName,
                            chord: Binding(
                                get: { config.config.hotKeys.windowLayout.chord(for: action.id) },
                                set: { config.config.hotKeys.windowLayout.setChord($0, for: action.id) }
                            ),
                            defaultChord: WindowLayoutHotKeyDefaults.commands[action.id.rawValue]
                                ?? KeyChord(keyCode: 0, modifiers: WindowLayoutHotKeyDefaults.controlOption)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let message = layoutConflictMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(FontSystem.captionMedium)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button(L10n.text("全部恢复默认")) {
                        config.config.hotKeys.windowLayout.resetToDefaults()
                    }
                }
            }

            // 使用说明
            SettingsSection(title: "使用说明", icon: "info.circle") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    InstructionRow(number: 1, text: "点击修饰键按钮选择需要的修饰键（可多选）")
                    InstructionRow(number: 2, text: "从下拉菜单选择主键")
                    InstructionRow(number: 3, text: "修改后立即生效，无需重启")
                    InstructionRow(number: 4, text: "至少需要一个修饰键")
                }
            }

            Spacer()
        }
        .alert(
            currentConflict?.isUnoverridable == true ? "快捷键无法使用" : "快捷键冲突",
            isPresented: $showConflictAlert
        ) {
            Button(L10n.text("打开系统设置")) {
                openSystemKeyboardSettings()
                cancelPendingHotKey()
            }
            if currentConflict?.isUnoverridable != true {
                Button(L10n.text("确定"), role: .destructive) {
                    currentConflict = nil
                    pendingHotKeyType = nil
                    previousKeyCode = nil
                    previousModifiers = nil
                }
            }
            Button(L10n.text("取消"), role: .cancel) {
                cancelPendingHotKey()
            }
        } message: {
            if let conflict = currentConflict {
                if conflict.isUnoverridable {
                    Text("「\(conflict.hotKeyDisplay)」是 macOS 系统级快捷键，应用程序无法覆盖。\n\n请选择其他快捷键组合。")
                } else {
                    Text(L10n.format("当前设置的组合键「%@」与系统快捷键冲突：%@\n\n确定要覆盖系统快捷键吗？", conflict.hotKeyDisplay, conflict.description))
                }
            } else {
                Text(L10n.text("当前设置的组合键与系统快捷键冲突"))
            }
        }
        .onChange(of: config.config.hotKeys.switchKeyCode) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.switchModifiers) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.appSwitchKeyCode) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.appSwitchModifiers) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.appSwitchReverseKeyCode) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.appSwitchReverseModifiers) { _ in checkConflicts() }
    }

    private func checkConflicts() {
        if let conflict = HotKeyConflictChecker.checkSystemConflict(
            keyCode: config.config.hotKeys.switchKeyCode,
            modifiers: config.config.hotKeys.switchModifiers
        ) {
            conflictWarning = conflict.description
            return
        }

        if let conflict = HotKeyConflictChecker.checkSystemConflict(
            keyCode: config.config.hotKeys.appSwitchKeyCode,
            modifiers: config.config.hotKeys.appSwitchModifiers
        ) {
            conflictWarning = conflict.description
            return
        }

        if let conflict = HotKeyConflictChecker.checkSystemConflict(
            keyCode: config.config.hotKeys.appSwitchReverseKeyCode,
            modifiers: config.config.hotKeys.appSwitchReverseModifiers
        ) {
            conflictWarning = conflict.description
            return
        }

        conflictWarning = nil
    }

    private var layoutConflictMessage: String? {
        var owners: [KeyChord: String] = [:]
        let existing: [(String, KeyChord)] = [
            ("显示切换器", .init(keyCode: config.config.hotKeys.switchKeyCode, modifiers: config.config.hotKeys.switchModifiers)),
            ("同应用窗口切换", .init(keyCode: config.config.hotKeys.appSwitchKeyCode, modifiers: config.config.hotKeys.appSwitchModifiers))
        ]
        for (name, chord) in existing { owners[chord] = name }

        var entries: [(String, KeyChord)] = []
        if let chord = config.config.hotKeys.windowLayout.openPanel {
            entries.append(("打开布局面板", chord))
        }
        entries += WindowLayoutActionCatalog.actions.compactMap { action in
            config.config.hotKeys.windowLayout.chord(for: action.id).map { (action.title, $0) }
        }
        for (name, chord) in entries {
            if let owner = owners[chord] {
                return "“\(name)”与“\(owner)”使用了同一快捷键 \(chord.displayText)"
            }
            owners[chord] = name
        }
        return nil
    }

    private func openSystemKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }

    private func cancelPendingHotKey() {
        if let keyCode = previousKeyCode, let modifiers = previousModifiers {
            if pendingHotKeyType == "switch" {
                config.config.hotKeys.switchKeyCode = keyCode
                config.config.hotKeys.switchModifiers = modifiers
            } else if pendingHotKeyType == "appSwitch" {
                config.config.hotKeys.appSwitchKeyCode = keyCode
                config.config.hotKeys.appSwitchModifiers = modifiers
            }
        }
        currentConflict = nil
        pendingHotKeyType = nil
        previousKeyCode = nil
        previousModifiers = nil
    }
}

/// 设置页中的单个窗口布局快捷键编辑器。
private struct LayoutHotKeyEditor: View {
    let title: String
    let symbolName: String
    @Binding var chord: KeyChord?
    let defaultChord: KeyChord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if chord != nil {
                    HotKeyRecorder(
                        keyCode: Binding(
                            get: { chord?.keyCode ?? defaultChord.keyCode },
                            set: { chord = KeyChord(keyCode: $0, modifiers: chord?.modifiers ?? defaultChord.modifiers) }
                        ),
                        modifiers: Binding(
                            get: { chord?.modifiers ?? defaultChord.modifiers },
                            set: { chord = KeyChord(keyCode: chord?.keyCode ?? defaultChord.keyCode, modifiers: $0) }
                        ),
                        placeholder: defaultChord.displayText,
                        onReset: { chord = defaultChord }
                    )
                    HStack {
                        Spacer()
                        Button(L10n.text("清除快捷键"), role: .destructive) { chord = nil }
                            .buttonStyle(.plain)
                    }
                } else {
                    Button(L10n.format("设置为默认快捷键 %@", defaultChord.displayText)) { chord = defaultChord }
                }
            }
            .padding(.leading, 30)
            .padding(.top, 6)
            .padding(.bottom, 8)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .frame(width: 20, alignment: .center)

                Text(L10n.text(title))
                    .font(FontSystem.bodyMedium)
                    .lineLimit(1)

                Spacer(minLength: DesignTokens.Spacing.lg)

                WindowLayoutShortcutBadge(chord: chord)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ============================================
// 关于页面
// ============================================

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            // 应用信息
            SettingsSection(title: "应用信息", icon: "app.fill") {
                HStack(spacing: DesignTokens.Spacing.lg) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                        .resizable()
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Windows Switcher")
                            .font(FontSystem.titleMedium)
                        Text(L10n.format("版本 %@ (%@)", appVersion, buildNumber))
                            .font(FontSystem.bodyMedium)
                            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                        Text(L10n.text("仿 Windows Alt+Tab 窗口切换器"))
                            .font(FontSystem.captionMedium)
                            .foregroundStyle(DesignTokens.Colors.tertiaryLabel)
                    }

                    Spacer()
                }
            }

            // 系统要求
            SettingsSection(title: "系统要求", icon: "desktopcomputer") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    RequirementRow(icon: "checkmark.circle.fill", text: "macOS 13.0 或更高版本")
                    RequirementRow(icon: "checkmark.circle.fill", text: "辅助功能权限（用于窗口切换）")
                    RequirementRow(icon: "checkmark.circle.fill", text: "屏幕录制权限（用于窗口预览）")
                }
            }

            // 功能特性
            SettingsSection(title: "功能特性", icon: "star.fill") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    FeatureRow(icon: "rectangle.on.rectangle", text: "类 Windows Alt+Tab 窗口切换体验")
                    FeatureRow(icon: "dock.rectangle", text: "Dock 图标悬停预览窗口")
                    FeatureRow(icon: "keyboard", text: "自定义快捷键支持")
                    FeatureRow(icon: "paintbrush", text: "浅色/深色主题自适应")
                }
            }

            Spacer()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// ============================================
// 组件：设置分组
// ============================================

struct SettingsSection<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // 分组标题
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(L10n.text(title))
                    .font(FontSystem.titleSmall)
            }

            // 内容区域
            content
                .padding(DesignTokens.Spacing.lg)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
        }
    }
}

// ============================================
// 组件：开关设置项
// ============================================

struct SettingsToggle: View {
    let title: String
    var description: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FontSystem.bodyMedium)
                if let description = description {
                    Text(L10n.text(description))
                        .font(FontSystem.captionMedium)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

// ============================================
// 组件：滑块设置项
// ============================================

struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var multiplier: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(L10n.text(title))
                    .font(FontSystem.bodyMedium)
                Spacer()
                Text(String(format: "%.0f \(unit)", value * multiplier))
                    .font(FontSystem.bodySmall)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                    .monospacedDigit()
            }

            Slider(value: $value, in: range, step: step)
                .tint(DesignTokens.Colors.accent)
        }
    }
}

// ============================================
// 组件：说明行
// ============================================

struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text("\(number).")
                .font(FontSystem.captionMedium)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                .frame(width: 16, alignment: .leading)

            Text(L10n.text(text))
                .font(FontSystem.captionMedium)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
        }
    }
}

// ============================================
// 组件：需求行
// ============================================

struct RequirementRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Text(L10n.text(text))
                .font(FontSystem.captionMedium)
        }
    }
}

// ============================================
// 组件：功能行
// ============================================

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.accent)
            Text(L10n.text(text))
                .font(FontSystem.captionMedium)
        }
    }
}

// ============================================
// 快捷键冲突信息
// ============================================

struct HotKeyConflictInfo {
    let hotKeyDisplay: String
    let description: String
    var isUnoverridable: Bool = false
}

// ============================================
// 快捷键录制器（分步设置：修饰键 + 主键）
// ============================================

struct HotKeyRecorder: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    let placeholder: String
    let onReset: () -> Void
    var onConflict: ((HotKeyConflictInfo) -> Void)? = nil
    var onBeforeChange: (() -> Void)? = nil

    // 修饰键状态
    private var hasCommand: Bool {
        get { modifiers & UInt32(cmdKey) != 0 }
        nonmutating set {
            let oldValue = modifiers
            if newValue { modifiers |= UInt32(cmdKey) }
            else { modifiers &= ~UInt32(cmdKey) }
            if oldValue != modifiers {
                onBeforeChange?()
                checkAndNotifyConflict()
            }
        }
    }

    private var hasOption: Bool {
        get { modifiers & UInt32(optionKey) != 0 }
        nonmutating set {
            let oldValue = modifiers
            if newValue { modifiers |= UInt32(optionKey) }
            else { modifiers &= ~UInt32(optionKey) }
            if oldValue != modifiers {
                onBeforeChange?()
                checkAndNotifyConflict()
            }
        }
    }

    private var hasControl: Bool {
        get { modifiers & UInt32(controlKey) != 0 }
        nonmutating set {
            let oldValue = modifiers
            if newValue { modifiers |= UInt32(controlKey) }
            else { modifiers &= ~UInt32(controlKey) }
            if oldValue != modifiers {
                onBeforeChange?()
                checkAndNotifyConflict()
            }
        }
    }

    private var hasShift: Bool {
        get { modifiers & UInt32(shiftKey) != 0 }
        nonmutating set {
            let oldValue = modifiers
            if newValue { modifiers |= UInt32(shiftKey) }
            else { modifiers &= ~UInt32(shiftKey) }
            if oldValue != modifiers {
                onBeforeChange?()
                checkAndNotifyConflict()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 修饰键选择
            HStack(spacing: 12) {
                ModifierKeyToggle(symbol: "⌘", label: "Command", isOn: Binding(
                    get: { hasCommand },
                    set: { hasCommand = $0 }
                ))
                ModifierKeyToggle(symbol: "⌥", label: "Option", isOn: Binding(
                    get: { hasOption },
                    set: { hasOption = $0 }
                ))
                ModifierKeyToggle(symbol: "⌃", label: "Control", isOn: Binding(
                    get: { hasControl },
                    set: { hasControl = $0 }
                ))
                ModifierKeyToggle(symbol: "⇧", label: "Shift", isOn: Binding(
                    get: { hasShift },
                    set: { hasShift = $0 }
                ))
            }

            // 主键选择
            HStack(spacing: 8) {
                Text(L10n.text("主键:"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                KeyPicker(keyCode: $keyCode, onSelectionChange: {
                    onBeforeChange?()
                    checkAndNotifyConflict()
                })

                Spacer()

                // 重置按钮
                Button(action: onReset) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                        Text(L10n.text("重置"))
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.text("恢复默认"))

                // 显示当前快捷键
                WindowLayoutShortcutBadge(keyCode: keyCode, modifiers: modifiers)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // 检测冲突并通知
    private func checkAndNotifyConflict() {
        guard let onConflict = onConflict else { return }

        if let conflict = HotKeyConflictChecker.checkSystemConflict(
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            onConflict(conflict)
        }
    }
}

// ============================================
// 修饰键开关
// ============================================

struct ModifierKeyToggle: View {
    let symbol: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            VStack(spacing: 2) {
                Text(symbol)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 36)
            .background(isOn ? Color.accentColor : Color.secondary.opacity(0.1))
            .foregroundStyle(isOn ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(label)
    }
}

// ============================================
// 主键选择器
// ============================================

struct KeyPicker: View {
    @Binding var keyCode: UInt32
    var onSelectionChange: (() -> Void)? = nil

    // 常用按键列表
    private let keyOptions: [(String, UInt32)] = [
        ("Tab", UInt32(kVK_Tab)),
        ("Space", UInt32(kVK_Space)),
        ("Return", UInt32(kVK_Return)),
        ("←", UInt32(kVK_LeftArrow)),
        ("→", UInt32(kVK_RightArrow)),
        ("↑", UInt32(kVK_UpArrow)),
        ("↓", UInt32(kVK_DownArrow)),
        ("` (Grave)", UInt32(kVK_ANSI_Grave)),
        ("A", UInt32(kVK_ANSI_A)),
        ("B", UInt32(kVK_ANSI_B)),
        ("C", UInt32(kVK_ANSI_C)),
        ("D", UInt32(kVK_ANSI_D)),
        ("E", UInt32(kVK_ANSI_E)),
        ("F", UInt32(kVK_ANSI_F)),
        ("G", UInt32(kVK_ANSI_G)),
        ("H", UInt32(kVK_ANSI_H)),
        ("I", UInt32(kVK_ANSI_I)),
        ("J", UInt32(kVK_ANSI_J)),
        ("K", UInt32(kVK_ANSI_K)),
        ("L", UInt32(kVK_ANSI_L)),
        ("M", UInt32(kVK_ANSI_M)),
        ("N", UInt32(kVK_ANSI_N)),
        ("O", UInt32(kVK_ANSI_O)),
        ("P", UInt32(kVK_ANSI_P)),
        ("Q", UInt32(kVK_ANSI_Q)),
        ("R", UInt32(kVK_ANSI_R)),
        ("S", UInt32(kVK_ANSI_S)),
        ("T", UInt32(kVK_ANSI_T)),
        ("U", UInt32(kVK_ANSI_U)),
        ("V", UInt32(kVK_ANSI_V)),
        ("W", UInt32(kVK_ANSI_W)),
        ("X", UInt32(kVK_ANSI_X)),
        ("Y", UInt32(kVK_ANSI_Y)),
        ("Z", UInt32(kVK_ANSI_Z)),
        ("0", UInt32(kVK_ANSI_0)),
        ("1", UInt32(kVK_ANSI_1)),
        ("2", UInt32(kVK_ANSI_2)),
        ("3", UInt32(kVK_ANSI_3)),
        ("4", UInt32(kVK_ANSI_4)),
        ("5", UInt32(kVK_ANSI_5)),
        ("6", UInt32(kVK_ANSI_6)),
        ("7", UInt32(kVK_ANSI_7)),
        ("8", UInt32(kVK_ANSI_8)),
        ("9", UInt32(kVK_ANSI_9)),
        ("F1", UInt32(kVK_F1)),
        ("F2", UInt32(kVK_F2)),
        ("F3", UInt32(kVK_F3)),
        ("F4", UInt32(kVK_F4)),
        ("F5", UInt32(kVK_F5)),
        ("F6", UInt32(kVK_F6)),
        ("F7", UInt32(kVK_F7)),
        ("F8", UInt32(kVK_F8)),
        ("F9", UInt32(kVK_F9)),
        ("F10", UInt32(kVK_F10)),
        ("F11", UInt32(kVK_F11)),
        ("F12", UInt32(kVK_F12)),
        ("Delete", UInt32(kVK_Delete)),
        ("Escape", UInt32(kVK_Escape)),
    ]

    var body: some View {
        Menu {
            ForEach(keyOptions, id: \.1) { name, code in
                Button(name) {
                    keyCode = code
                    onSelectionChange?()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(HotKeyFormatter.keyCodeToString(keyCode))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 80)
    }
}

// ============================================
// 快捷键格式化器
// ============================================

struct HotKeyFormatter {
    /// 将 NSEvent.ModifierFlags 转换为 Carbon 修饰键值
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0

        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }

        return carbonFlags
    }

    /// 格式化快捷键显示文本
    static func format(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []

        // 修饰键
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        // 主键
        parts.append(keyCodeToString(keyCode))

        return parts.joined()
    }

    /// 将 keyCode 转换为可读字符串
    static func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "Esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Period: return "."
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return "?"
        }
    }
}

// ============================================
// 快捷键冲突检测
// ============================================

struct HotKeyConflictChecker {
    /// 无法覆盖的系统快捷键（系统级，应用无法拦截）
    static let unoverridableSystemKeys: [(UInt32, UInt32, String)] = [
        // 目前没有无法覆盖的快捷键
    ]

    /// 系统保留快捷键（可覆盖但会冲突）
    static let systemReserved: [(UInt32, UInt32, String)] = [
        // 窗口管理
        (UInt32(kVK_F11), 0, "显示桌面"),
        (UInt32(kVK_F12), 0, "打开程序坞"),
        // 应用切换器（现在可以覆盖）
        (UInt32(kVK_Tab), UInt32(cmdKey), "系统应用切换器"),
        (UInt32(kVK_Tab), UInt32(cmdKey | shiftKey), "系统应用切换器（反向）"),
        // 截图
        (UInt32(kVK_ANSI_3), UInt32(cmdKey | shiftKey), "截图"),
        (UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey), "截图选区"),
        (UInt32(kVK_ANSI_5), UInt32(cmdKey | shiftKey), "截图窗口"),
        (UInt32(kVK_ANSI_6), UInt32(cmdKey | shiftKey), "截图触摸栏"),
        // Spotlight
        (UInt32(kVK_Space), UInt32(cmdKey), "Spotlight"),
        // 输入法
        (UInt32(kVK_Space), UInt32(controlKey), "输入法切换"),
        // 其他常用系统快捷键
        (UInt32(kVK_ANSI_Q), UInt32(cmdKey), "退出应用"),
        (UInt32(kVK_ANSI_W), UInt32(cmdKey), "关闭窗口"),
        (UInt32(kVK_ANSI_E), UInt32(cmdKey), "编辑"),
        (UInt32(kVK_ANSI_R), UInt32(cmdKey), "刷新"),
        (UInt32(kVK_ANSI_T), UInt32(cmdKey), "新标签页"),
        (UInt32(kVK_ANSI_P), UInt32(cmdKey), "打印"),
        (UInt32(kVK_ANSI_S), UInt32(cmdKey), "保存"),
        (UInt32(kVK_ANSI_F), UInt32(cmdKey), "查找"),
        (UInt32(kVK_ANSI_G), UInt32(cmdKey), "查找下一个"),
        (UInt32(kVK_ANSI_H), UInt32(cmdKey), "隐藏应用"),
        (UInt32(kVK_ANSI_M), UInt32(cmdKey), "最小化窗口"),
        (UInt32(kVK_ANSI_N), UInt32(cmdKey), "新建窗口"),
        (UInt32(kVK_ANSI_O), UInt32(cmdKey), "打开"),
        (UInt32(kVK_ANSI_Z), UInt32(cmdKey), "撤销"),
        (UInt32(kVK_ANSI_X), UInt32(cmdKey), "剪切"),
        (UInt32(kVK_ANSI_C), UInt32(cmdKey), "复制"),
        (UInt32(kVK_ANSI_V), UInt32(cmdKey), "粘贴"),
        (UInt32(kVK_ANSI_A), UInt32(cmdKey), "全选"),
        (UInt32(kVK_ANSI_F), UInt32(cmdKey | optionKey), "高级查找"),
        (UInt32(kVK_Tab), UInt32(controlKey), "Control+Tab 切换标签"),
        (UInt32(kVK_Tab), UInt32(controlKey | shiftKey), "Control+Shift+Tab 反向切换标签"),
    ]

    /// 检查快捷键是否无法覆盖（系统级限制）
    static func checkUnoverridable(keyCode: UInt32, modifiers: UInt32) -> HotKeyConflictInfo? {
        for (sysKeyCode, sysModifiers, description) in unoverridableSystemKeys {
            if keyCode == sysKeyCode && modifiers == sysModifiers {
                let hotKeyDisplay = HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers)
                return HotKeyConflictInfo(
                    hotKeyDisplay: hotKeyDisplay,
                    description: description,
                    isUnoverridable: true
                )
            }
        }
        return nil
    }

    /// 检查快捷键是否与系统冲突
    static func checkSystemConflict(keyCode: UInt32, modifiers: UInt32) -> HotKeyConflictInfo? {
        // 先检查无法覆盖的快捷键
        if let conflict = checkUnoverridable(keyCode: keyCode, modifiers: modifiers) {
            return conflict
        }

        // 再检查可覆盖的系统快捷键
        for (sysKeyCode, sysModifiers, description) in systemReserved {
            if keyCode == sysKeyCode && modifiers == sysModifiers {
                let hotKeyDisplay = HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers)
                return HotKeyConflictInfo(
                    hotKeyDisplay: hotKeyDisplay,
                    description: description,
                    isUnoverridable: false
                )
            }
        }
        return nil
    }

    /// 检查快捷键是否有效
    static func isValidHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        // 必须至少有一个修饰键
        guard modifiers != 0 else { return false }

        // 不能只有 Shift 修饰键（Shift+字母 用于输入大写字母）
        if modifiers == UInt32(shiftKey) { return false }

        return true
    }
}
