# Called by Windows when an opencode-notify:// URI is clicked.
# Extracts pid= from the URI and activates that process's hosting window.
#
# Logs every invocation so click-through can be debugged: a toast click that
# does nothing is otherwise invisible.

param([Parameter(Position = 0)][string]$Uri)

$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$log = Join-Path $here "activate.log"
$target = Join-Path $here "activate-window.ps1"

function Write-Log([string]$m) {
    try { Add-Content -Path $log -Value ((Get-Date).ToString("s") + " " + $m) -Encoding UTF8 } catch {}
}

Write-Log ("invoked uri='" + $Uri + "'")

if ($Uri -match "pid=(\d+)") {
    $thePid = $Matches[1]
    Write-Log ("extracted pid=" + $thePid)
    $out = & "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $target -TargetPid $thePid 2>&1
    Write-Log ("result: " + ($out -join " | "))
} else {
    Write-Log "no pid in uri"
}
