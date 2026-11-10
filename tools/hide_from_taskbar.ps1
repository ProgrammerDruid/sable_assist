# Hide a window from the taskbar and Alt-Tab by making it a tool window.
# Godot has no flag for this, so Sable runs this on herself at startup:
#   powershell -File hide_from_taskbar.ps1 -ProcessId <pid> [-Title Sable]
param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [string]$Title = "Sable"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SableWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000;

    public static int Hide(uint pid, string title) {
        int n = 0;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            string t = sb.ToString();
            if (t != title && t != title + " (DEBUG)") return true;
            long ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
            ex = (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
            // The taskbar only re-reads styles when the window is re-shown.
            ShowWindow(h, 0);
            SetWindowLongPtr(h, GWL_EXSTYLE, new IntPtr(ex));
            ShowWindow(h, 8); // SW_SHOWNA: show without activating
            n++;
            return true;
        }, IntPtr.Zero);
        return n;
    }
}
"@

# The window may not exist yet right after launch; retry for a few seconds.
for ($i = 0; $i -lt 20; $i++) {
    if ([SableWin]::Hide([uint32]$ProcessId, $Title) -gt 0) { exit 0 }
    Start-Sleep -Milliseconds 250
}
exit 1
