# opencode-notify-win

> 我顺手 vibe 的

Windows 原生 Toast 通知，给 [opencode](https://opencode.ai) 用。

## 为什么需要它

opencode 内置的 `attention` 只发 **OSC 9 / OSC 777 终端转义序列**，而 **Windows Terminal 不把它们渲染成通知** —— 实测下来一个弹窗都没有。这个插件改用 **Windows PowerShell 5.1 + WinRT** 发真正的系统 Toast。

## 特性

- 真正的 Windows Toast（走系统通知中心，不是终端转义）
- 可穿透「勿扰 / 专注助手」：默认 `urgent` 档，实测可穿透「仅优先」
- 全局插件：装一次，所有 opencode 会话生效
- 纯 fire-and-forget：通知失败绝不影响会话

## 要求

### 必需

| 依赖 | 版本 / 路径 | 说明 |
|---|---|---|
| Windows | 10 / 11 | WinRT Toast API 仅 Windows 提供 |
| Windows PowerShell | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` | **必须是 5.1**，见下 |
| opencode | 任意近期版本 | 插件宿主 |

> **为什么必须是 PowerShell 5.1？** PS 7 是基于 .NET Core 的跨平台版本，**不暴露 WinRT 的 `Windows.UI.Notifications` API**。这是硬约束，不是偏好。脚本里写死了 5.1 的绝对路径。

### 可选

无。不依赖外部 npm 包（`@opencode-ai/plugin` 仅用于类型检查，运行时由 opencode 提供）。

### 平台限制

- **仅 Windows**。macOS / Linux 有系统原生通知（`osascript` / `notify-send`），不需要这个插件。
- **仅 Windows Terminal 之外的场景有意义**：如果你用 WezTerm，它支持 OSC 777，opencode 原生通知可能就够了。
- **勿扰穿透有限制**：见下方 scenario 表。用户设为「仅闹钟」时只有 `alarm` 能进；没有任何 API 能绕过「仅闹钟 + 非闹钟通知」。


## 安装

```powershell
git clone git@github.com:FireChickenMP4/opencode-notify-win.git
cd opencode-notify-win
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

安装脚本会：

1. 把 `notify-windows.ts` 和 `notify/notify.ps1` 复制到 `~/.config/opencode/plugins/`
2. 确保 `.ps1` 带 UTF-8 BOM（否则 PS 5.1 会按 ANSI 解析，中文全乱码）
3. 注册 AUMID（Start Menu 快捷方式 + `IPropertyStore`）
4. 关闭 opencode 内置 `attention`（避免重复且它在 WT 无效）

重新运行安装脚本是安全的（幂等）。

## 触发时机

| 事件 | 通知 |
|---|---|
| 会话空闲（`session.idle`，或 `session.status` 且 `status.type === "idle"`） | `opencode · 完成 [工作区路径]` |
| 权限请求（`permission.asked`） | `opencode · 需要授权 [工作区路径]` |
| agent 提问（`question.asked`） | `opencode · 需要你回答 [工作区路径]` |
| 会话出错（`session.error`） | `opencode · 出错 [工作区路径]` |

> **标题带完整工作区路径**（主目录缩写为 `~`）。两个 opencode 开在不同项目时，
> 一眼看出是哪条。早期只显示目录名，同名目录无法区分。

> **子代理不通知（默认）**：事件带 `sessionID`，插件据此查会话记录，
> 若 `parentID` 非空说明是子代理——它结束时**主会话仍在跑**，报"完成"是误导。
> 默认跳过，`OPENCODE_NOTIFY_SUBAGENT=1` 可开启，标题为
> `opencode · 子代理完成 [<会话标题>]`（去掉 `(@general subagent)` 尾巴）。

**任务栏闪烁**：通知到达时同时让对应窗口的任务栏按钮闪烁（`FlashWindowEx`）。
即使错过弹窗也能注意到。可用 `OPENCODE_NOTIFY_FLASH=0` 关闭。

> **去抖**：一次"回合结束"可能连发多个空闲信号（`session.status` idle 与
> `session.idle`，ESC 打断时甚至一秒内数条）。同类通知在 `OPENCODE_NOTIFY_DEDUP_MS`
> （默认 3000ms）内只发一次，避免刷屏。

> **注意**：空闲信号可能来自 `session.status`（携带 `status.type === "idle"`）
> **或**独立的 `session.idle` 事件——实测后者才是主要来源。两条路径都要做
> 子代理判断，否则子代理结束会被误报成"任务完成"。

### 发送方式

Toast 用**异步 spawn 并 await 退出**发送（不 detached），且**串行排队 + 失败重试一次**。

踩过的三种失败：
- `detached: true` + `stdio: "ignore"` + `unref()`：子进程在 PowerShell 执行前被回收，
  日志显示已发送但屏幕无反应。
- `Bun.spawnSync`：偶发返回 `exitCode=null`（约 3ms 内被中断）。
- **并发**：opencode 不 await 事件处理器，多个事件同时触发会让两个 PowerShell 同时启动，
  同样产生 `exit=null`。改为串行队列后消除。

### ESC 打断

ESC 中断会发 `session.error`，但 `error.name === "MessageAbortedError"`。
这是用户主动打断，不是故障，插件会跳过，不报"出错"。

### 点击跳转（部分可用）

通知的 XML 带 `activationType="protocol" launch="opencode-notify://activate?pid=<pid>"`，
协议注册后，点击会把承载该会话的终端/编辑器窗口拉到前台。

**但实测：从通知点击不触发回调**——非 UWP 应用需要实现 COM
`INotificationActivationCallback` 才行，纯 PowerShell 发的 Toast 做不到。
手动调用 `Start-Process opencode-notify://activate?pid=...` 是有效的。

**已知限制**：Windows Terminal 没有"按标签身份聚焦"的接口，所以两个 opencode
在**同一窗口不同标签**时，最多把窗口拉到前台，**不会切标签**。

详见 [TODO.md](./TODO.md)（含 BurntToast 方案评估）。

## 配置

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `OPENCODE_NOTIFY` | `1` | 设 `0` 完全关闭 |
| `OPENCODE_NOTIFY_SCENARIO` | `urgent` | `default` / `urgent` / `alarm` / `reminder` |
| `OPENCODE_NOTIFY_SOUND` | `1` | 设 `0` 静音 |
| `OPENCODE_NOTIFY_ON_IDLE` | `1` | 设 `0` 只在需授权/出错时通知 |
| `OPENCODE_NOTIFY_FLASH` | `1` | 设 `0` 关闭任务栏闪烁 |
| `OPENCODE_NOTIFY_SUBAGENT` | `0` | 设 `1` 也通知子代理结束 |
| `OPENCODE_NOTIFY_LOG` | `1` | 设 `0` 关闭诊断事件日志 |
| `OPENCODE_NOTIFY_LOG_MAX` | `5242880` | 诊断日志超过此字节数即轮转到 `.1` |
| `OPENCODE_NOTIFY_CLICK_ACTIVATE` | `0` | 设 `1` 尝试点击跳转（见上） |
| `OPENCODE_NOTIFY_APPID` | 安装时的 AUMID | 发送者身份 |

### scenario 与勿扰穿透

| scenario | 勿扰「仅优先」 | 勿扰「仅闹钟」 |
|---|---|---|
| `default` | 挡 | 挡 |
| `urgent` | **可见** | 挡 |
| `alarm` | **可见** | **可见** |
| `reminder` | 可见 | 挡 |

默认 `urgent`：够用且不吵。若你的勿扰是「仅闹钟」，改 `OPENCODE_NOTIFY_SCENARIO=alarm`。

### 延迟

一次通知（弹窗 + 闪烁）约 **600ms**。构成：

| 步骤 | 耗时 | 备注 |
|---|---|---|
| PowerShell 5.1 冷启动 | ~120ms | 改不掉（除非不用 pwsh） |
| WinRT 类型加载 | ~40ms | |
| Toast 显示 | ~70ms | |
| `Add-Type` 编译（闪烁用） | ~90ms | 每次调用重编译 |
| 进程快照 | ~145ms | |

优化过的两点（原先 1178ms → 现在 600ms）：

1. **闪烁内联进 `notify.ps1`**：不再另起子进程跑 `flash-window.ps1`，省一次
   pwsh 启动 + 一次 Add-Type 编译。
2. **进程链用一次快照，不逐跳查询**：`Get-CimInstance` 逐跳调用 8 次要 ~1.3s，
   一次拿全表只要 ~145ms。

> 想再快可用 `NtQueryInformationProcess` 把快照压到 ~30ms，但代码复杂度上升，
> 收益有限，暂未做。

## 手动测试

```powershell
$env:NOTIFY_TITLE = "opencode"; $env:NOTIFY_MSG = "测试中文"
$env:NOTIFY_SCENARIO = "urgent"
$env:NOTIFY_FLASH_PID = $PID        # 同时闪当前窗口
& "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\.config\opencode\plugins\notify\notify.ps1"
```

## 卸载

```powershell
Remove-Item "$env:USERPROFILE\.config\opencode\plugins\notify-windows.ts" -Force
Remove-Item "$env:USERPROFILE\.config\opencode\plugins\notify" -Recurse -Force
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\opencode workflow.lnk" -Force
Remove-Item "HKCU:\SOFTWARE\Classes\opencode-notify" -Recurse -Force
```

## 踩过的坑（实现要点）

1. **必须 PS 5.1**：PS 7 不暴露 `Windows.UI.Notifications` WinRT API
2. **`.ps1` 必须 UTF-8 with BOM**：否则 PS 5.1 按 GBK 解析，中文乱码
3. **参数用环境变量传**：PowerShell 命令行参数对非 ASCII 编码不可靠
4. **AUMID 必须先注册**：没有 Start Menu 快捷方式 + `PKEY_AppUserModel_ID`，`CreateToastNotifier` 会报 `applicationId` 错误
5. **`scenario` 决定勿扰行为**：见上表
6. **点击回调需要 COM**：见"点击跳转"一节
7. **PS 5.1 的 C# 编译器不支持 `out _` 与字符串插值**：`Add-Type` 内联 C# 时要用具名变量、字符串拼接

## 文件

```text
src/
  notify-windows.ts      # opencode plugin（挂 session 事件）
  notify/
    notify.ps1           # 发送器（弹窗 + 闪烁，环境变量传参，UTF-8 BOM）
    flash-window.ps1     # 任务栏闪烁（FlashWindowEx）
    activate-window.ps1  # 激活窗口（沿进程链找宿主）
    handle-protocol.ps1  # 协议回调入口
    register-protocol.ps1# 注册 opencode-notify:// 协议
  register-aumid.ps1     # 注册 AUMID（幂等）
install.ps1              # 一键安装
TODO.md                  # 未完成项（点击跳转方案评估等）
```

## License

MIT
