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
| 会话完成（`session.idle`） | `{项目名} · 完成` |
| 权限请求（`permission.asked`） | `{项目名} · 需要授权` |
| 会话出错（`session.error`） | `{项目名} · 出错` |

## 配置

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `OPENCODE_NOTIFY` | `1` | 设 `0` 完全关闭 |
| `OPENCODE_NOTIFY_SCENARIO` | `urgent` | `default` / `urgent` / `alarm` / `reminder` |
| `OPENCODE_NOTIFY_SOUND` | `1` | 设 `0` 静音 |
| `OPENCODE_NOTIFY_ON_IDLE` | `1` | 设 `0` 只在需授权/出错时通知 |
| `OPENCODE_NOTIFY_APPID` | 安装时的 AUMID | 发送者身份 |

### scenario 与勿扰穿透

| scenario | 勿扰「仅优先」 | 勿扰「仅闹钟」 |
|---|---|---|
| `default` | 挡 | 挡 |
| `urgent` | **可见** | 挡 |
| `alarm` | **可见** | **可见** |
| `reminder` | 可见 | 挡 |

默认 `urgent`：够用且不吵。若你的勿扰是「仅闹钟」，改 `OPENCODE_NOTIFY_SCENARIO=alarm`。

## 手动测试

```powershell
$env:NOTIFY_TITLE = "opencode"; $env:NOTIFY_MSG = "测试中文"
$env:NOTIFY_SCENARIO = "urgent"
& "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\.config\opencode\plugins\notify\notify.ps1"
```

## 卸载

```powershell
Remove-Item "$env:USERPROFILE\.config\opencode\plugins\notify-windows.ts" -Force
Remove-Item "$env:USERPROFILE\.config\opencode\plugins\notify" -Recurse -Force
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\opencode workflow.lnk" -Force
```

## 踩过的坑（实现要点）

1. **必须 PS 5.1**：PS 7 不暴露 `Windows.UI.Notifications` WinRT API
2. **`.ps1` 必须 UTF-8 with BOM**：否则 PS 5.1 按 GBK 解析，中文乱码
3. **参数用环境变量传**：PowerShell 命令行参数对非 ASCII 编码不可靠
4. **AUMID 必须先注册**：没有 Start Menu 快捷方式 + `PKEY_AppUserModel_ID`，`CreateToastNotifier` 会报 `applicationId` 错误
5. **`scenario` 决定勿扰行为**：见上表

## 文件

```text
src/
  notify.ps1           # PS 5.1 发送器（环境变量传参，UTF-8 BOM）
  notify-windows.ts    # opencode plugin（挂 session 事件）
  register-aumid.ps1   # 注册 AUMID（幂等）
install.ps1            # 一键安装
```

## License

MIT
