# WindowsSwitcher 真实全局热键 E2E 输入工具

该目录提供真实热键输入工具及只读性能采样工具，用于检查已安装应用的交互与常驻开销。工具不会启动或关闭 WindowsSwitcher，也不会修改应用配置。

## 安全约束

- 无参数运行和 `status` 仅调用 `CGPreflightPostEventAccess()`，不会弹出授权请求，也不会发送任何键鼠事件。
- 只有显式执行 `global-reverse`、`global-layout` 或 `app-reverse` 才会注入事件。
- 每次只发送一组受控序列：反向命令按“基础修饰键、Shift、目标键”发送；布局命令按“基础修饰键、Tab、等待、L”发送；最后逆序释放仍按下的键。
- 事件构造异常时会尽力释放本次可能按下的 Shift 和基础修饰键，降低修饰键滞留风险。
- 输入工具未指定参数时发送全局反向 Command+Shift+Tab，这是工具兼容既有验证环境的默认值。应用全新安装默认为 Option，因此验证全新安装应指定 `--modifier option`；升级保留自定义配置，应先核对设置页，工具不会读取或猜测 UserDefaults。

## 构建

```bash
cd /Users/sampou/mac_workspace/WindowsSwitcher
bash tools/user-e2e/build.sh
```

产物位于 `tools/user-e2e/.build/hotkey-injector`，`.build/` 不进入版本控制。

## 权限预检（不会发送事件）

```bash
tools/user-e2e/.build/hotkey-injector
tools/user-e2e/.build/hotkey-injector status
```

输出 `post-event-access=granted` 且退出码为 `0` 表示当前终端具备事件合成权限；输出 `post-event-access=denied` 且退出码为 `3` 表示未授权。该权限通常由 macOS“隐私与安全性 → 辅助功能”控制，工具不会主动请求或弹出授权。

## 显式执行

先确认 WindowsSwitcher 正在运行、应用仍使用默认热键，并从应用自身日志记下验证起始时间，再执行以下命令之一：

```bash
# 全局反向：默认 Command+Shift+Tab（当前安装态）
tools/user-e2e/.build/hotkey-injector global-reverse

# 全局反向：显式匹配仍使用 Option 的配置
tools/user-e2e/.build/hotkey-injector global-reverse --modifier option

# 同应用反向：Option+Shift+`
tools/user-e2e/.build/hotkey-injector app-reverse

# 让修饰键保持 300ms，以覆盖显示面板后的完整反向链路
tools/user-e2e/.build/hotkey-injector global-reverse --hold-ms 300

# 打开全局切换面板并发送 L，默认等待 350ms 后打开 Action Panel
tools/user-e2e/.build/hotkey-injector global-layout

# 自定义面板出现前的等待时间
tools/user-e2e/.build/hotkey-injector global-layout --hold-ms 500

# 保持修饰键并额外前进 3 个窗口后再发送 L，便于指定真实应用目标
tools/user-e2e/.build/hotkey-injector global-layout --steps 3 --hold-ms 500
```

## 证据判定

一次有效 E2E 结果必须同时满足：

1. 注入器先输出 `post-event-access=granted`，随后输出对应的 `sent=global-reverse ...`、`sent=global-layout ...` 或 `sent=app-reverse ...`，退出码为 `0`。
2. WindowsSwitcher 自身日志在本次验证时间窗内记录了对应的反向热键处理链路，而不是仅记录正向切换或测试进程通知。
3. 日志显示反向初始选择或 `selectPrevious` 路径，并最终正常激活目标窗口、关闭面板；不能出现修饰键未释放、重复激活或崩溃。
4. 人工观察到实际选中结果符合反向环绕规则；仅有注入器的 `sent=` 输出不能单独证明应用行为正确。

Action Panel 入口验证还必须确认：切换面板先打开，`L` 后出现独立 Action Panel，释放全局修饰键不会激活原选中窗口，且应用日志包含 Action Panel 显示记录。

若权限被拒绝、应用热键已自定义、目标应用不足两个窗口，或应用日志缺少反向路径证据，本次结果应记为“未验证”，不能记为通过。

## 只读性能采样

已安装应用运行时，可采样 CPU、常驻内存（RSS）和采样期间新增日志中的面板创建耗时：

```bash
python3 tools/user-e2e/profile.py --duration 120 --scenario observed
python3 tools/user-e2e/profile.py --duration 28800 --interval 30 --scenario soak
```

有多个同名进程时用 `--pid` 指定目标。工具不会发送输入、改变配置或退出应用；权限不足或进程退出会明确返回不可采样。

面板创建耗时不包含热键等待、动画或屏幕呈现，不能当作按键到显示的延迟；短期 RSS 变化也不能单独证明有无内存泄漏。记录测试窗口数量、显示器布局、系统版本和操作场景后再比较不同版本。

## 首次使用与升级验收

- 全新安装核对 Option 默认快捷键；升级核对原配置与语言偏好仍保留。
- 在通用设置检查两项权限的真实状态与系统设置入口；授权变更后点击“重新检查权限”，观察切换和预览恢复。
- 自动检查开启时仍可手动检查更新；进行中按钮禁用，无更新时显示“已是最新版本”，失败时可重试。
- 反向切换、快速连按、窗口消失、最小化/隐藏、全屏、多桌面及多显示器场景均检查最终实际激活目标。模拟坐标或单元测试不替代多显示器实机结果。
