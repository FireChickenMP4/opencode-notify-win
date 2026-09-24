# TODO

## 点击跳转（当前不通，两条待选路径）

**现状**：Toast XML 正确地写入了
`activationType="protocol" launch="opencode-notify://activate?pid=<pid>"`，
协议也注册成功——手动 `Start-Process opencode-notify://...` 能触发激活。
**但点击通知本身不触发回调**：日志里没有新记录。

**根因**：非 UWP 应用要让 Toast 点击回调生效，必须实现 COM 接口
`INotificationActivationCallback` 并注册 CLSID。纯 PowerShell 脚本发的 Toast
做不到这一点——这是 Win32 Toast 的已知限制。

### 方案 A：改用 BurntToast

`Install-Module BurntToast`。它的 CHANGES 明确写了：

> v1.0.0: Enable "Activation" events on all supported versions of PowerShell,
> including Windows PowerShell.

所以它实现了 COM 激活，点击能回调。

**注意点**：
- v1.0.0 移除了自定义 AppId（"AppId Customization Removed"），可能与现在的
  AUMID 注册方式冲突，需要重做
- 引入 PowerShell Gallery 模块依赖（需要网络）
- 改写 `notify.ps1` 为 `New-BTContent` + `Submit-BTNotification`
- 激活后的动作仍需自己写（BurntToast 只负责把事件送回来）

**评估**：中等复杂度，收益是"点击跳转"，但在"同窗口不同标签无法定位"的限制下
收益有限（见下）。

### 方案 B：自己写 COM 激活服务器

实现 `INotificationActivationCallback`，注册 CLSID + 快捷方式。
工程量大，不推荐。

### 已知限制（无论哪个方案）

Windows Terminal 没有"按窗格/标签身份聚焦"的接口：
- `wt focus-tab -t <n>` 只认**序号**，标签开关后序号会变
- `WT_SESSION`（窗格 GUID）只能读，**不能用来跳转**

所以两个 opencode 若在**同一个 WT 窗口的不同标签**里，点击最多把窗口拉到前台，
**不会切到对应标签**。不同窗口才能精准跳。

---

## 闪烁（已实现，待你在失焦状态下验证）

`flash-window.ps1`（`FlashWindowEx`）已接入 `notify.ps1`，通知到达时闪对应窗口的
任务栏按钮。纯 Win32，实测可用。

**未验证**：只在焦点已在 WT 上时测过（那种情况下闪烁不明显）。
需要在**焦点在别的窗口**时确认效果。

---

## 其他

- [ ] VS Code 内嵌终端场景未验证（激活/闪烁的 `$hosts` 里已含 `Code`，但没实测）
