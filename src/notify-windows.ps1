# Read or change the Windows toast switch from the shell.
#
#   notify-windows              -> show status
#   notify-windows on           -> enable toasts
#   notify-windows off          -> disable toasts
#   notify-windows toggle       -> flip
#
# The plugin re-reads the switch before every toast, so a change takes effect
# immediately - no opencode restart. `OPENCODE_NOTIFY=0` in the environment is a
# separate hard kill switch and is left alone (it needs a service restart).

param(
    [Parameter(Position = 0)][string]$Action = "status"
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $env:USERPROFILE ".config\opencode\notify-windows.json"

function Get-Switch {
    if (-not (Test-Path $configPath)) { return $true }
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        return -not ($cfg.enabled -eq $false)
    } catch {
        Write-Output "invalid JSON in $configPath; treated as ON"
        return $true
    }
}

function Save-Switch([bool]$On) {
    $cfg = $null
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    }
    if ($null -eq $cfg) { $cfg = [pscustomobject]@{} }
    $cfg | Add-Member -NotePropertyName enabled -NotePropertyValue $On -Force
    $json = $cfg | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

$state = Get-Switch

switch ($Action.ToLower()) {
    "on" {
        Save-Switch $true
        Write-Output "toasts: ON (takes effect immediately)"
    }
    "off" {
        Save-Switch $false
        Write-Output "toasts: OFF (takes effect immediately)"
    }
    "toggle" {
        Save-Switch (-not $state)
        Write-Output ("toasts: " + $(if ($state) { "OFF" } else { "ON" }))
    }
    "status" {
        Write-Output ("toasts: " + $(if ($state) { "ON" } else { "OFF" }))
        Write-Output "config: $configPath"
        if ($env:OPENCODE_NOTIFY -eq "0") {
            Write-Output "note: OPENCODE_NOTIFY=0 is set in this shell, which disables toasts regardless"
        }
    }
    default {
        Write-Output "usage: notify-windows [on|off|status|toggle]"
        exit 2
    }
}
