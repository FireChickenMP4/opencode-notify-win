# Windows native toast for opencode (PS 5.1 + WinRT).
#
# Parameters arrive via environment variables to avoid PowerShell arg encoding
# issues with non-ASCII text. This file MUST stay UTF-8 with BOM, otherwise
# PS 5.1 parses it as GBK and every Chinese literal becomes mojibake.
#
#   NOTIFY_TITLE        - heading
#   NOTIFY_MSG          - body
#   NOTIFY_SCENARIO     - default | urgent | alarm | reminder  (default: urgent)
#   NOTIFY_APPID        - AUMID to send as (default: FireChickenMP4.opencode.workflow)
#   NOTIFY_SOUND        - 1 to attach a sound (default: 1)
#   NOTIFY_ACTIVATE_PID - if set, clicking the toast activates that process's
#                         window (walks up to the hosting terminal/editor)
#   NOTIFY_FLASH_PID    - if set, flash that process's taskbar button so the
#                         window draws attention even if the toast is missed
#
# Flash is inlined rather than calling flash-window.ps1: a separate process would
# pay another PowerShell start (~200ms) and another Add-Type compile (~90ms).

$ErrorActionPreference = "Stop"

$title = if ($env:NOTIFY_TITLE) { $env:NOTIFY_TITLE } else { "opencode" }
$msg = if ($env:NOTIFY_MSG) { $env:NOTIFY_MSG } else { "task complete" }
$scenario = if ($env:NOTIFY_SCENARIO) { $env:NOTIFY_SCENARIO } else { "urgent" }
$appId = if ($env:NOTIFY_APPID) { $env:NOTIFY_APPID } else { "FireChickenMP4.opencode.workflow" }
$sound = if ($env:NOTIFY_SOUND) { $env:NOTIFY_SOUND } else { "1" }
$activatePid = $env:NOTIFY_ACTIVATE_PID
$flashPid = $env:NOTIFY_FLASH_PID

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

function Escape-Xml([string]$s) {
    $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

$safeTitle = Escape-Xml $title
$safeMsg = Escape-Xml $msg
$scenarioAttr = if ($scenario -and $scenario -ne "default") { " scenario=`"$scenario`"" } else { "" }
$audio = if ($sound -eq "1") { '<audio src="ms-winsoundevent:Notification.Default" />' } else { "" }

$activation = ""
if ($activatePid) {
    $activation = " activationType=`"protocol`" launch=`"opencode-notify://activate?pid=$activatePid`""
}

$template = @"
<toast$scenarioAttr$activation>
  <visual>
    <binding template="ToastText02">
      <text id="1">$safeTitle</text>
      <text id="2">$safeMsg</text>
    </binding>
  </visual>
  $audio
</toast>
"@

$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($template)
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
$toast.Priority = [Windows.UI.Notifications.ToastNotificationPriority]::High

[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)

if ($flashPid) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class ToastFlash {
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }

    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    public static bool Flash(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return false;
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        info.hwnd = hwnd;
        info.dwFlags = 3 | 12;   // FLASHW_ALL | FLASHW_TIMERNOFG
        info.uCount = uint.MaxValue;
        info.dwTimeout = 0;
        return FlashWindowEx(ref info);
    }

    public static IntPtr HandleOf(int pid) {
        try { return System.Diagnostics.Process.GetProcessById(pid).MainWindowHandle; }
        catch { return IntPtr.Zero; }
    }
}
"@

    # One process snapshot, not one CIM call per hop: per-hop was ~1.3s for 8
    # hops, a single snapshot is ~145ms for the whole process table.
    $snapshot = @{}
    foreach ($p in (Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name)) {
        $snapshot[[int]$p.ProcessId] = $p
    }
    $hosts = @("WindowsTerminal", "WindowsTerminalPreview", "Code", "code", "powershell", "pwsh", "cmd", "conhost", "wezterm-gui")

    function Find-Window {
        param([int]$Start, [bool]$RequireHost)
        $cur = $Start
        for ($i = 0; $i -lt 11 -and $cur -gt 0) {
            $p = $snapshot[$cur]
            if (-not $p) { break }
            $name = [System.IO.Path]::GetFileNameWithoutExtension($p.Name)
            if ((-not $RequireHost) -or ($hosts -contains $name)) {
                $h = [ToastFlash]::HandleOf($cur)
                if ($h -ne [IntPtr]::Zero) { return $h }
            }
            $cur = [int]$p.ParentProcessId
            $i++
        }
        return [IntPtr]::Zero
    }

    $hwnd = Find-Window -Start ([int]$flashPid) -RequireHost $true
    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = Find-Window -Start ([int]$flashPid) -RequireHost $false }
    if ($hwnd -ne [IntPtr]::Zero) { [ToastFlash]::Flash($hwnd) | Out-Null }
}
