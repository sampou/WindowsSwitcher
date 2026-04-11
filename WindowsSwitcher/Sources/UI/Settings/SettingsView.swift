import SwiftUI
import Carbon
import AppKit

/// F07 设置面板：外观 / 行为 / 快捷键，含保存失败提示和重置功能
struct SettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // 保存失败横幅
            if let error = config.saveError {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        config.saveError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(Color.yellow.opacity(0.15))
            }

            TabView {
                AppearanceSettingsView()
                    .tabItem { Label("外观", systemImage: "paintbrush") }

                BehaviorSettingsView()
                    .tabItem { Label("行为", systemImage: "gearshape") }

                HotKeySettingsView()
                    .tabItem { Label("快捷键", systemImage: "keyboard") }
            }

            // 底部重置按钮
            Divider()
            HStack {
                Spacer()
                Button("恢复默认设置") {
                    showResetConfirm = true
                }
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
        }
        .frame(width: 520, height: 520)
        .confirmationDialog("确认恢复默认设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { config.reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有设置将恢复为出厂默认值，此操作不可撤销。")
        }
    }
}

// MARK: - 外观

struct AppearanceSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        Form {
            Section("主题") {
                Picker("主题模式", selection: $config.config.appearance.theme) {
                    Text("浅色").tag(AppTheme.light)
                    Text("深色").tag(AppTheme.dark)
                    Text("跟随系统").tag(AppTheme.auto)
                }
                .pickerStyle(.segmented)
            }

            Section("预览窗口") {
                Picker("预览大小", selection: $config.config.appearance.previewSize) {
                    Text("小").tag(PreviewSize.small)
                    Text("中").tag(PreviewSize.medium)
                    Text("大").tag(PreviewSize.large)
                }
                .pickerStyle(.segmented)

                Picker("每行列数", selection: $config.config.appearance.switcherColumns) {
                    Text("自动").tag(0)
                    Text("3列").tag(3)
                    Text("4列").tag(4)
                    Text("5列").tag(5)
                    Text("6列").tag(6)
                    Text("8列").tag(8)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

// MARK: - 行为

struct BehaviorSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

    var body: some View {
        Form {
            Section("启动") {
                Toggle("开机自动启动", isOn: $launchAtLogin.isEnabled)
            }

            Section("窗口显示") {
                Toggle("显示最小化窗口", isOn: $config.config.behavior.showMinimizedWindows)
                Toggle("显示隐藏窗口", isOn: $config.config.behavior.showHiddenWindows)
                Toggle("默认选中第二个窗口", isOn: $config.config.behavior.defaultSelectSecond)
            }

            Section("切换器背景预览") {
                Toggle("显示背景预览", isOn: $config.config.behavior.showBackgroundPreview)
            }

            Section("程序坞预览") {
                Toggle("启用程序坞预览", isOn: $config.config.dockPreview.enabled)

                if config.config.dockPreview.enabled {
                    // 悬停延迟
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text("悬停延迟")
                            Spacer()
                            Text(String(format: "%.0f ms", config.config.dockPreview.hoverDelay * 1000))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $config.config.dockPreview.hoverDelay, in: 0.05...0.5, step: 0.05)
                            .tint(DesignTokens.Colors.accent)
                    }

                    // 隐藏延迟
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text("隐藏延迟")
                            Spacer()
                            Text(String(format: "%.0f ms", config.config.dockPreview.hideDelay * 1000))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $config.config.dockPreview.hideDelay, in: 0.05...0.5, step: 0.05)
                            .tint(DesignTokens.Colors.accent)
                    }

                    // 最大预览数量
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text("最大预览数量")
                            Spacer()
                            Text("\(config.config.dockPreview.maxPreviewCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(config.config.dockPreview.maxPreviewCount) },
                            set: { config.config.dockPreview.maxPreviewCount = Int($0) }
                        ), in: 2...16, step: 1)
                        .tint(DesignTokens.Colors.accent)
                    }

                    // 显示动画
                    Toggle("显示动画效果", isOn: $config.config.dockPreview.showAnimation)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

// MARK: - 快捷键

struct HotKeySettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @State private var conflictWarning: String?
    @State private var showResetConfirm = false
    @State private var showConflictAlert = false
    @State private var currentConflict: HotKeyConflictInfo?
    @State private var pendingHotKeyType: String?  // "switch" or "appSwitch"
    // 保存冲突前的值，用于取消时恢复
    @State private var previousKeyCode: UInt32?
    @State private var previousModifiers: UInt32?

    var body: some View {
        Form {
            Section("窗口切换快捷键") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("显示切换器")
                        .font(.system(size: 12, weight: .medium))
                    HotKeyRecorder(
                        keyCode: $config.config.hotKeys.switchKeyCode,
                        modifiers: $config.config.hotKeys.switchModifiers,
                        placeholder: "⌥ Tab",
                        onReset: {
                            config.config.hotKeys.switchKeyCode = 48  // Tab
                            config.config.hotKeys.switchModifiers = 2048  // Option
                        },
                        onConflict: { conflict in
                            currentConflict = conflict
                            pendingHotKeyType = "switch"
                            showConflictAlert = true
                        },
                        onBeforeChange: {
                            // 保存变更前的值
                            previousKeyCode = config.config.hotKeys.switchKeyCode
                            previousModifiers = config.config.hotKeys.switchModifiers
                        }
                    )
                }

                Text("反向切换：按住 Shift 即可反向切换，无需单独设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("应用内切换快捷键") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("同应用窗口切换")
                        .font(.system(size: 12, weight: .medium))
                    HotKeyRecorder(
                        keyCode: $config.config.hotKeys.appSwitchKeyCode,
                        modifiers: $config.config.hotKeys.appSwitchModifiers,
                        placeholder: "⌥ `",
                        onReset: {
                            config.config.hotKeys.appSwitchKeyCode = 50  // `
                            config.config.hotKeys.appSwitchModifiers = 2048  // Option
                        },
                        onConflict: { conflict in
                            currentConflict = conflict
                            pendingHotKeyType = "appSwitch"
                            showConflictAlert = true
                        },
                        onBeforeChange: {
                            // 保存变更前的值
                            previousKeyCode = config.config.hotKeys.appSwitchKeyCode
                            previousModifiers = config.config.hotKeys.appSwitchModifiers
                        }
                    )
                }
            }

            if let warning = conflictWarning {
                Section {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Label("使用说明", systemImage: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text("1. 点击修饰键按钮选择需要的修饰键（可多选）")
                    Text("2. 从下拉菜单选择主键")
                    Text("3. 修改后立即生效，无需重启")
                    Text("4. 至少需要一个修饰键")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Button("恢复所有快捷键默认设置") {
                    showResetConfirm = true
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .confirmationDialog("确认恢复默认快捷键？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                resetAllHotKeys()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有快捷键将恢复为默认值，此操作不可撤销。")
        }
        .alert(
            currentConflict?.isUnoverridable == true ? "快捷键无法使用" : "快捷键冲突",
            isPresented: $showConflictAlert
        ) {
            Button("打开系统设置") {
                openSystemKeyboardSettings()
                cancelPendingHotKey()
            }
            // 只有可覆盖的快捷键才显示"确定"按钮
            if currentConflict?.isUnoverridable != true {
                Button("确定", role: .destructive) {
                    // 强制应用设置
                    currentConflict = nil
                    pendingHotKeyType = nil
                    previousKeyCode = nil
                    previousModifiers = nil
                }
            }
            Button("取消", role: .cancel) {
                cancelPendingHotKey()
            }
        } message: {
            if let conflict = currentConflict {
                if conflict.isUnoverridable {
                    Text("「\(conflict.hotKeyDisplay)」是 macOS 系统级快捷键，应用程序无法覆盖。\n\n请选择其他快捷键组合。")
                } else {
                    Text("当前设置的组合键「\(conflict.hotKeyDisplay)」与系统快捷键冲突：\(conflict.description)\n\n确定要覆盖系统快捷键吗？")
                }
            } else {
                Text("当前设置的组合键与系统快捷键冲突")
            }
        }
        .onChange(of: config.config.hotKeys.switchKeyCode) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.switchModifiers) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.appSwitchKeyCode) { _ in checkConflicts() }
        .onChange(of: config.config.hotKeys.appSwitchModifiers) { _ in checkConflicts() }
    }

    private func checkConflicts() {
        // 检查切换器快捷键冲突
        if let conflict = HotKeyConflictChecker.checkSystemConflict(
            keyCode: config.config.hotKeys.switchKeyCode,
            modifiers: config.config.hotKeys.switchModifiers
        ) {
            conflictWarning = conflict.description
            return
        }

        // 检查应用内切换快捷键冲突
        if let conflict = HotKeyConflictChecker.checkSystemConflict(
            keyCode: config.config.hotKeys.appSwitchKeyCode,
            modifiers: config.config.hotKeys.appSwitchModifiers
        ) {
            conflictWarning = conflict.description
            return
        }

        conflictWarning = nil
    }

    private func resetAllHotKeys() {
        config.config.hotKeys = HotKeyConfig()
    }

    private func openSystemKeyboardSettings() {
        // 打开系统设置的键盘快捷键界面
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
            NSWorkspace.shared.open(url)
        } else {
            // 降级：打开键盘设置
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func cancelPendingHotKey() {
        // 恢复之前保存的值
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

// MARK: - 快捷键冲突信息
struct HotKeyConflictInfo {
    let hotKeyDisplay: String
    let description: String
    var isUnoverridable: Bool = false  // 是否无法覆盖（系统级限制）
}

// MARK: - 快捷键录制器（分步设置：修饰键 + 主键）
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
                Text("主键:")
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
                        Text("重置")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.plain)
                .help("恢复默认")

                // 显示当前快捷键
                Text(HotKeyFormatter.format(keyCode: keyCode, modifiers: modifiers))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
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

// MARK: - 修饰键开关
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
        .help(label)
    }
}

// MARK: - 主键选择器
struct KeyPicker: View {
    @Binding var keyCode: UInt32
    var onSelectionChange: (() -> Void)? = nil

    // 常用按键列表
    private let keyOptions: [(String, UInt32)] = [
        ("Tab", UInt32(kVK_Tab)),
        ("Space", UInt32(kVK_Space)),
        ("Return", UInt32(kVK_Return)),
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

// MARK: - 快捷键格式化器
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

// MARK: - 快捷键冲突检测
struct HotKeyConflictChecker {
    /// 无法覆盖的系统快捷键（系统级，应用无法拦截）
    /// 注：Command+Tab 现在可以通过私有 API 覆盖，已移除
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
