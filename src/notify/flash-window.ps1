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

# Build the parent map ONCE. Calling Get-CimInstance per hop took ~1.3s for 8
# hops; a single snapshot is ~145ms for the whole process table.
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
            $h = [WinFlash]::HandleOf($cur)
            if ($h -ne [IntPtr]::Zero) {
                return @{ Pid = $cur; Name = $p.Name; Handle = $h }
            }
        }
        $cur = [int]$p.ParentProcessId
        $i++
    }
    return $null
}

# Prefer a known host process, then fall back to any ancestor with a window.
$hit = Walk-Chain -Start $TargetPid -RequireHost $true
if (-not $hit) { $hit = Walk-Chain -Start $TargetPid -RequireHost $false }

if ($hit) {
    if ([WinFlash]::Flash([IntPtr]$hit.Handle)) {
        Write-Output ("flashed " + $hit.Name + " pid=" + $hit.Pid)
        exit 0
    }
    Write-Output ("found " + $hit.Name + " pid=" + $hit.Pid + " but FlashWindowEx failed")
    exit 1
}

Write-Output "no flasheable window found"
exit 1
