# WindowsSwitcher 真实全局热键 E2E 输入工具

该工具通过独立 Swift 进程和 `CGEvent` 注入一次受控热键序列，用于补齐 Carbon 全局热键注册链路与 Action Panel 入口的真实 E2E 验证。它不会启动或关闭 WindowsSwitcher，也不会修改应用配置。

## 安全约束

- 无参数运行和 `status` 仅调用 `CGPreflightPostEventAccess()`，不会弹出授权请求，也不会发送任何键鼠事件。
- 只有显式执行 `global-reverse`、`global-layout` 或 `app-reverse` 才会注入事件。
- 每次只发送一组受控序列：反向命令按“基础修饰键、Shift、目标键”发送；布局命令按“基础修饰键、Tab、等待、L”发送；最后逆序释放仍按下的键。
- 事件构造异常时会尽力释放本次可能按下的 Shift 和基础修饰键，降低修饰键滞留风险。
- 工具按当前安装态默认配置发送全局反向 Command+Shift+Tab；同应用反向固定为 Option+Shift+反引号键。源码 `ConfigModel` 的全局修饰键默认值仍为 Option，因此工具允许显式指定 `--modifier option`，但不会读取或猜测 UserDefaults。

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
