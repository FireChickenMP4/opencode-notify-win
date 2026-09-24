# Register the opencode-notify:// protocol so a toast click can activate the
# right window.
#
# Toast XML: <toast activationType="protocol" launch="opencode-notify://activate?pid=123">
# Windows then runs the registered command with the URI appended.

param(
    [string]$Scheme = "opencode-notify"
)

$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$script = Join-Path $PSScriptRoot "activate-window.ps1"
$ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path $script)) { throw "activate-window.ps1 not found next to this script" }

# A tiny launcher that extracts pid= from the URI and calls activate-window.ps1.
$launcher = Join-Path $PSScriptRoot "handle-protocol.ps1"
@'
# Called by Windows when an opencode-notify:// URI is clicked.
param([Parameter(Position=0)][string]$Uri)

$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$target = Join-Path $here "activate-window.ps1"

if ($Uri -match "pid=(\d+)") {
    $pidValue = $Matches[1]
    & "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $target -TargetPid $pidValue
}
'@ | Set-Content -Path $launcher -Encoding UTF8

$root = "HKCU:\SOFTWARE\Classes\$Scheme"
New-Item -Path $root -Force | Out-Null
Set-ItemProperty -Path $root -Name "(Default)" -Value "URL:opencode notify protocol"
Set-ItemProperty -Path $root -Name "URL Protocol" -Value ""

$cmdKey = "$root\shell\open\command"
New-Item -Path $cmdKey -Force | Out-Null
$cmd = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" `"%1`""
Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value $cmd

Write-Output "registered ${Scheme}://"
Write-Output "  launcher: $launcher"
Write-Output "  command:  $cmd"
