# Flash the taskbar button of the window hosting a process.
#
# Called alongside a toast so the right window draws attention even if the toast
# is missed. Pure Win32 (FlashWindowEx); no COM, no UWP app identity needed -
# unlike toast click activation, this works from a plain script.
#
#   powershell -File flash-window.ps1 -TargetPid 12345

param(
    [Parameter(Mandatory = $true)][int]$TargetPid
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class WinFlash {
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [DllImport("user32.dll")]
    static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    // Flash continuously until the window comes to the foreground.
    const uint FLASHW_ALL = 3;
    const uint FLASHW_TIMERNOFG = 12;

    public static bool Flash(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return false;
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        info.hwnd = hwnd;
        info.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
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

# Same walk as activate-window.ps1: the toast carries a shell/opencode pid, but
# the taskbar button belongs to the hosting terminal or editor.
$hosts = @("WindowsTerminal", "WindowsTerminalPreview", "Code", "code", "powershell", "pwsh", "cmd", "conhost", "wezterm-gui")

$current = $TargetPid
for ($i = 0; $i -lt 11 -and $current -gt 0; $i++) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($proc.Name)

    if ($hosts -contains $name) {
        $h = [WinFlash]::HandleOf($current)
        if ($h -ne [IntPtr]::Zero) {
            if ([WinFlash]::Flash($h)) { Write-Output ("flashed " + $proc.Name + " pid=" + $current); exit 0 }
        }
    }
    $current = $proc.ParentProcessId
}

# Fallback: any ancestor with a window.
$current = $TargetPid
for ($i = 0; $i -lt 11 -and $current -gt 0; $i++) {
    $h = [WinFlash]::HandleOf($current)
    if ($h -ne [IntPtr]::Zero -and [WinFlash]::Flash($h)) {
        Write-Output ("flashed pid=" + $current); exit 0
    }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    $current = $proc.ParentProcessId
}

Write-Output "no flasheable window found"
exit 1
