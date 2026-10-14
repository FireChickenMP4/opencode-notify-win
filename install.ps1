# Install opencode-notify-win into the global opencode config.
#
# Copies the plugin + sender into ~/.config/opencode/plugins/, registers the
# AUMID, and turns off opencode's built-in attention (which does not render in
# Windows Terminal and would otherwise compete with this plugin).
#
# Idempotent: safe to re-run.

param(
    [string]$AppId = "FireChickenMP4.opencode.workflow",
    [string]$DisplayName = "opencode",
    [switch]$SkipAttentionConfig,
    [switch]$SkipShellFunction
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

# The app icon shown on the toast; not a .ps1, so it must not get a BOM.
Copy-Item (Join-Path $src "notify\opencode.ico") (Join-Path $notifyDir "opencode.ico") -Force

# Shell switch: `notify-windows on|off|status|toggle` (ASCII only, so no BOM).
Copy-Item (Join-Path $src "notify-windows.ps1") (Join-Path $notifyDir "notify-windows.ps1") -Force

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
# The previous shortcut name would otherwise linger as a stale app identity.
$legacy = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\opencode workflow.lnk"
if (Test-Path $legacy) {
    Remove-Item $legacy -Force
    Write-Output "removed legacy shortcut: $legacy"
}
& (Join-Path $src "register-aumid.ps1") -AppId $AppId -DisplayName $DisplayName -IconPath (Join-Path $notifyDir "opencode.ico")

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

# Shell function so `notify-windows on|off|status|toggle` works in any terminal.
#
# Written into BOTH the Windows PowerShell 5.1 and PowerShell 7 profiles: the
# installer may run under either, but the user's interactive shell is usually
# pwsh 7, so installing only into the caller's profile would silently miss it.
if (-not $SkipShellFunction) {
    $cliScript = Join-Path $notifyDir "notify-windows.ps1"
    $begin = "# >>> opencode-notify-windows >>>"
    $end = "# <<< opencode-notify-windows <<<"
    $block = @"
$begin
function notify-windows {
    param([Parameter(Position = 0)][string]`$Action = 'status')
    & "$cliScript" `$Action
}
$end
"@

    $docs = [Environment]::GetFolderPath("MyDocuments")
    $profiles = @(
        (Join-Path $docs "WindowsPowerShell\profile.ps1"),  # PS 5.1
        (Join-Path $docs "PowerShell\profile.ps1")          # pwsh 7
    )

    foreach ($profilePath in $profiles) {
        $profileDir = Split-Path $profilePath -Parent
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
        if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }

        $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $existing) { $existing = "" }

        $pattern = "(?s)" + [regex]::Escape($begin) + ".*?" + [regex]::Escape($end)
        if ($existing -match $pattern) {
            $updated = [regex]::Replace($existing, $pattern, $block)
        } else {
            $sep = if ($existing.TrimEnd().Length -gt 0) { "`r`n`r`n" } else { "" }
            $updated = $existing.TrimEnd() + $sep + $block + "`r`n"
        }
        [System.IO.File]::WriteAllText($profilePath, $updated, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "shell function installed in: $profilePath"
    }
    Write-Output "  (open a new terminal, then: notify-windows status|on|off|toggle)"
}

Write-Output ""
Write-Output "done. Test it with:"
Write-Output "  `$env:NOTIFY_TITLE='标题'; `$env:NOTIFY_MSG='内容'; `$env:NOTIFY_SCENARIO='urgent'; `$env:NOTIFY_FLASH_PID=`$PID"
Write-Output "  & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File '$ps1'"
