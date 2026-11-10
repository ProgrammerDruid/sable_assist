# Reports how long you've been idle (no keyboard/mouse input) to Sable.
# Sable starts this hidden at launch; it sends {"src":"system","idle":<seconds>}
# to her UDP port every few seconds and exits when her process exits.
#   powershell -File idle_watch.ps1 -ProcessId <sable pid> [-Port 47800] [-Interval 20]
param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [int]$Port = 47800,
    [int]$Interval = 20
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SableIdle {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    public static uint IdleSeconds() {
        var info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) return 0;
        return unchecked((uint)Environment.TickCount - info.dwTime) / 1000;
    }
}
"@

$udp = New-Object System.Net.Sockets.UdpClient
try {
    while (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        $msg = '{"src":"system","idle":' + [SableIdle]::IdleSeconds() + '}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        [void]$udp.Send($bytes, $bytes.Length, "127.0.0.1", $Port)
        Start-Sleep -Seconds $Interval
    }
} finally {
    $udp.Close()
}
