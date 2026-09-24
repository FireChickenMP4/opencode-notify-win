# Install opencode-notify-win into the global opencode config.
#
# Copies the plugin + sender into ~/.config/opencode/plugins/, registers the
# AUMID, and turns off opencode's built-in attention (which does not render in
# Windows Terminal and would otherwise compete with this plugin).
#
# Idempotent: safe to re-run.

param(
    [string]$AppId = "FireChickenMP4.opencode.workflow",
    [switch]$SkipAttentionConfig
)

$ErrorActionPreference = "Stop"

# Resolve the repo root. $PSScriptRoot is normally set for -File invocation, but
# fall back to $MyInvocation so the script also works when dot-sourced.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
$repo = $scriptDir
$src = Join-Path $repo "src"
$configDir = Join-Path $env:USERPROFILE ".config\opencode"
$pluginsDir = Join-Path $configDir "plugins"
$notifyDir = Join-Path $pluginsDir "notify"

if (-not (Test-Path (Join-Path $src "notify-windows.ts"))) {
    throw "cannot find src/notify-windows.ts under '$repo'. Run this script from the repo root."
}

Write-Output "installing from: $repo"
Write-Output "target:          $pluginsDir"

New-Item -ItemType Directory -Force -Path $notifyDir | Out-Null

Copy-Item (Join-Path $src "notify-windows.ts") (Join-Path $pluginsDir "notify-windows.ts") -Force

# All sender/protocol scripts live under src/notify/.
$scripts = @(
    "notify.ps1",
    "flash-window.ps1",
    "activate-window.ps1",
    "handle-protocol.ps1",
    "register-protocol.ps1"
)
foreach ($s in $scripts) {
    Copy-Item (Join-Path $src "notify\$s") (Join-Path $notifyDir $s) -Force
}

# Ensure each .ps1 keeps its UTF-8 BOM; PS 5.1 reads BOM-less files as ANSI
# and would mangle every non-ASCII literal.
foreach ($s in $scripts) {
    $ps1 = Join-Path $notifyDir $s
    $bytes = [System.IO.File]::ReadAllBytes($ps1)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        $text = [System.IO.File]::ReadAllText($ps1, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($ps1, $text, (New-Object System.Text.UTF8Encoding($true)))
        Write-Output "added UTF-8 BOM to $s"
    }
}

# Register the AUMID so CreateToastNotifier accepts our appId.
& (Join-Path $src "register-aumid.ps1") -AppId $AppId

# Register the opencode-notify:// protocol used by click-to-activate.
& (Join-Path $notifyDir "register-protocol.ps1")

# Turn off the built-in attention (OSC 9/777) to avoid duplicate/invisible notifications.
if (-not $SkipAttentionConfig) {
    $cliJson = Join-Path $configDir "cli.json"
    $config = if (Test-Path $cliJson) {
        Get-Content $cliJson -Raw | ConvertFrom-Json
    } else {
        [pscustomobject]@{ '$schema' = 'https://opencode.ai/v2/cli.json' }
    }
    $config.attention = [pscustomobject]@{ notifications = $false; sound = $false }
    # Write without a BOM: a BOM in JSON is tolerated by most parsers but is
    # still noise, and this file may be parsed by tools that dislike it.
    $json = $config | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($cliJson, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "disabled built-in attention in $cliJson"
}

Write-Output ""
Write-Output "done. Test it with:"
Write-Output "  `$env:NOTIFY_TITLE='标题'; `$env:NOTIFY_MSG='内容'; `$env:NOTIFY_SCENARIO='urgent'; `$env:NOTIFY_FLASH_PID=`$PID"
Write-Output "  & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File '$ps1'"
