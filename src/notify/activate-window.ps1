# Activate the terminal (or editor) window that hosts a given process.
#
# Called by the notification click handler, or manually:
#   powershell -File activate-window.ps1 -Pid 12345
#
# Why a separate process: SetForegroundWindow only succeeds reliably when the
# caller is allowed to take focus. When invoked from a toast click, Windows
# grants that; a background process usually cannot.
#
# Strategy:
#   1. walk up from the pid to find a hostable window (terminal / code / etc.)
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

    public static bool HasWindow(int pid) {
        try { return System.Diagnostics.Process.GetProcessById(pid).MainWindowHandle != IntPtr.Zero; }
        catch { return false; }
    }
}
"@

# Walk up the parent chain: the notification carries a shell/opencode pid, but
# the window belongs to the terminal or editor hosting it.
# Note: Win32_Process.Name includes the ".exe" suffix, so compare basenames.
$hosts = @("WindowsTerminal", "WindowsTerminalPreview", "Code", "code", "powershell", "pwsh", "cmd", "conhost", "wezterm-gui")

$current = $TargetPid
for ($i = 0; $i -lt 11 -and $current -gt 0; $i++) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
    if (-not $proc) { break }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($proc.Name)

    if ($env:NOTIFY_ACTIVATE_DEBUG -eq "1") {
        Write-Output ("  chain: " + $proc.ProcessId + " " + $proc.Name + " (base=" + $name + ")")
    }

    if ($hosts -contains $name) {
        $r = [WinActivate]::Activate($current)
        if ($r -eq "ok") {
            Write-Output ("activated " + $proc.Name + " pid=" + $current)
            exit 0
        }
        Write-Output ("found " + $proc.Name + " pid=" + $current + " but activation returned: " + $r)
    }
    $current = $proc.ParentProcessId
}

# Fallback: any window-having ancestor.
$current = $TargetPid
for ($i = 0; $i -lt 11 -and $current -gt 0; $i++) {
    if ([WinActivate]::HasWindow($current)) {
        $r = [WinActivate]::Activate($current)
        if ($r -eq "ok") { Write-Output ("activated pid=" + $current); exit 0 }
    }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    $current = $proc.ParentProcessId
}

Write-Output "no activatable window found"
exit 1
