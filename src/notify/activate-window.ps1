# Activate the terminal (or editor) window that hosts a given process.
#
# Called by the notification click handler, or manually:
#   powershell -File activate-window.ps1 -TargetPid 12345
#
# Why a separate process: SetForegroundWindow only succeeds reliably when the
# caller is allowed to take focus. When invoked from a toast click, Windows
# grants that; a background process usually cannot.
#
# Strategy:
#   1. walk up from the pid to find a hostable window (terminal / editor / etc.)
#   2. restore it if minimized, then force it to the foreground

param(
    [Parameter(Mandatory = $true)][int]$TargetPid
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class WinActivate {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    const int SW_RESTORE = 9;

    public static string Activate(int pid) {
        try {
            var p = System.Diagnostics.Process.GetProcessById(pid);
            IntPtr h = p.MainWindowHandle;
            if (h == IntPtr.Zero) return "no-window";

            if (IsIconic(h)) ShowWindow(h, SW_RESTORE);

            bool direct = SetForegroundWindow(h);
            if (direct && GetForegroundWindow() == h) return "ok";

            // Foreground lock workaround: attach to the target's input queue.
            uint dummy;
            uint targetThread = GetWindowThreadProcessId(h, out dummy);
            uint myThread = GetCurrentThreadId();
            AttachThreadInput(myThread, targetThread, true);
            ShowWindow(h, SW_RESTORE);
            bool ok = SetForegroundWindow(h);
            AttachThreadInput(myThread, targetThread, false);

            return (ok && GetForegroundWindow() == h) ? "ok" : "blocked";
        } catch (Exception e) {
            return "error:" + e.Message;
        }
    }

    public static IntPtr HandleOf(int pid) {
        try { return System.Diagnostics.Process.GetProcessById(pid).MainWindowHandle; }
        catch { return IntPtr.Zero; }
    }
}
"@

# One process snapshot, not one CIM call per hop (per-hop was ~1.3s for 8 hops).
$snapshot = @{}
foreach ($p in (Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name)) {
    $snapshot[[int]$p.ProcessId] = $p
}

$hosts = @("WindowsTerminal", "WindowsTerminalPreview", "Code", "code", "powershell", "pwsh", "cmd", "conhost", "wezterm-gui")

function Walk-Chain {
    param([int]$Start, [bool]$RequireHost)
    $cur = $Start
    for ($i = 0; $i -lt 11 -and $cur -gt 0) {
        $p = $snapshot[$cur]
        if (-not $p) { break }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($p.Name)

        if ((-not $RequireHost) -or ($hosts -contains $name)) {
            if ([WinActivate]::HandleOf($cur) -ne [IntPtr]::Zero) {
                return @{ Pid = $cur; Name = $p.Name }
            }
        }
        $cur = [int]$p.ParentProcessId
        $i++
    }
    return $null
}

$hit = Walk-Chain -Start $TargetPid -RequireHost $true
if (-not $hit) { $hit = Walk-Chain -Start $TargetPid -RequireHost $false }

if ($hit) {
    $r = [WinActivate]::Activate($hit.Pid)
    if ($r -eq "ok") {
        Write-Output ("activated " + $hit.Name + " pid=" + $hit.Pid)
        exit 0
    }
    Write-Output ("found " + $hit.Name + " pid=" + $hit.Pid + " but activation returned: " + $r)
    exit 1
}

Write-Output "no activatable window found"
exit 1
