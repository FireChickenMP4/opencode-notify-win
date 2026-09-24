# Windows native toast for opencode (PS 5.1 + WinRT).
#
# Parameters arrive via environment variables to avoid PowerShell arg encoding
# issues with non-ASCII text. This file MUST stay UTF-8 with BOM, otherwise
# PS 5.1 parses it as GBK and every Chinese literal becomes mojibake.
#
#   NOTIFY_TITLE     - heading
#   NOTIFY_MSG       - body
#   NOTIFY_SCENARIO  - default | urgent | alarm | reminder  (default: urgent)
#   NOTIFY_APPID     - AUMID to send as (default: FireChickenMP4.opencode.workflow)
#   NOTIFY_SOUND     - 1 to attach a sound (default: 1)
#   NOTIFY_ACTIVATE_PID - if set, clicking the toast activates that process's
#                         window (walks up to the hosting terminal/editor)
#   NOTIFY_FLASH_PID    - if set, flash that process's taskbar button so the
#                         window draws attention even if the toast is missed

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

# Clicking activates the originating window via the registered
# opencode-notify:// protocol. Without a pid, the toast is inert (as before).
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

# Flash the taskbar button. Done in the same process as the toast so a single
# notification costs one PowerShell start, not two.
if ($flashPid) {
    $flashScript = Join-Path $PSScriptRoot "flash-window.ps1"
    if (Test-Path $flashScript) {
        & $flashScript -TargetPid $flashPid | Out-Null
    }
}
