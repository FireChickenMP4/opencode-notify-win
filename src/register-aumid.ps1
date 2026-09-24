# Register an AppUserModelID (AUMID) for opencode toast notifications.
#
# Windows refuses CreateToastNotifier(appId) unless the appId belongs to a
# registered app. Registration has two parts:
#   1. a Start Menu shortcut (gives the app an identity)
#   2. PKEY_AppUserModel_ID written onto that shortcut via IPropertyStore
#
# Idempotent: safe to run repeatedly.

param(
    [string]$AppId = "FireChickenMP4.opencode.workflow",
    [string]$DisplayName = "opencode workflow"
)

$ErrorActionPreference = "Stop"

$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$lnkPath = Join-Path $startMenu "$DisplayName.lnk"
$ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

# 1. Shortcut
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($lnkPath)
$lnk.TargetPath = $ps
$lnk.Arguments = "-NoProfile"
$lnk.Save()

# 2. AUMID via IPropertyStore (PKEY_AppUserModel_ID)
if (-not ("AumidSetter" -as [type])) {
    $code = @"
using System;
using System.Runtime.InteropServices;

public static class AumidSetter {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint c);
        void GetAt(uint i, out PropertyKey k);
        void GetValue(ref PropertyKey k, out PropVariant v);
        void SetValue(ref PropertyKey k, ref PropVariant v);
        void Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHGetPropertyStoreFromParsingName(
        string path, IntPtr b, int flags, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    public static void Set(string path, string aumid) {
        Guid guid = new Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");
        IPropertyStore store;
        SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref guid, out store);

        PropertyKey key = new PropertyKey();
        key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        key.pid = 5; // PKEY_AppUserModel_ID

        PropVariant val = new PropVariant();
        val.vt = 31; // VT_LPWSTR
        val.p = Marshal.StringToCoTaskMemUni(aumid);

        store.SetValue(ref key, ref val);
        store.Commit();
        Marshal.FreeCoTaskMem(val.p);
    }
}
"@
    Add-Type -TypeDefinition $code -Language CSharp
}

[AumidSetter]::Set($lnkPath, $AppId)

Write-Output "registered AUMID '$AppId' on '$lnkPath'"
