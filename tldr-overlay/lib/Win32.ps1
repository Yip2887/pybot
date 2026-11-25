# TL;DR Overlay - Win32.ps1
# Process DPI awareness + the handful of P/Invokes the overlay needs.
# Dot-sourced by ScreenReader.ps1 and TldrOverlay.ps1.

if (-not ('Tldr.Win32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Tldr {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static class Win32 {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int max);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern int SetWindowLong(IntPtr hWnd, int index, int value);

        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        public const int GWL_EXSTYLE = -20;
        public const int WS_EX_TRANSPARENT = 0x00000020;
        public const int WS_EX_LAYERED = 0x00080000;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const int WS_EX_NOACTIVATE = 0x08000000;
        public const int WS_EX_TOPMOST = 0x00000008;

        public const int SM_XVIRTUALSCREEN = 76;
        public const int SM_YVIRTUALSCREEN = 77;
        public const int SM_CXVIRTUALSCREEN = 78;
        public const int SM_CYVIRTUALSCREEN = 79;

        public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOACTIVATE = 0x0010;
    }
}
'@ -ErrorAction Stop
}

# Everything downstream works in physical pixels: UIA bounding rectangles,
# GetCursorPos and screen capture all agree once the process is DPI aware.
[Tldr.Win32]::SetProcessDPIAware() | Out-Null

function Get-DpiScale {
    <#  ponytail: system DPI awareness (one scale for the whole desktop). A mixed
        multi-monitor setup with different scale factors needs PerMonitorV2. #>
    $dc = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try {
        return [double]($dc.DpiX / 96.0)
    } finally {
        $dc.Dispose()
    }
}

function Get-VirtualScreenRect {
    <#  Physical-pixel bounds of the whole virtual desktop (all monitors). #>
    return @{
        X = [Tldr.Win32]::GetSystemMetrics([Tldr.Win32]::SM_XVIRTUALSCREEN)
        Y = [Tldr.Win32]::GetSystemMetrics([Tldr.Win32]::SM_YVIRTUALSCREEN)
        W = [Tldr.Win32]::GetSystemMetrics([Tldr.Win32]::SM_CXVIRTUALSCREEN)
        H = [Tldr.Win32]::GetSystemMetrics([Tldr.Win32]::SM_CYVIRTUALSCREEN)
    }
}

function Get-WindowRect {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return $null }
    $r = New-Object Tldr.RECT
    if (-not [Tldr.Win32]::GetWindowRect($Handle, [ref]$r)) { return $null }
    return @{ X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top }
}

function Get-CursorPosition {
    $p = New-Object Tldr.POINT
    if ([Tldr.Win32]::GetCursorPos([ref]$p)) { return @{ X = $p.X; Y = $p.Y } }
    return @{ X = 0; Y = 0 }
}

function Get-ForegroundProcessId {
    $pid32 = [uint32]0
    [void][Tldr.Win32]::GetWindowThreadProcessId([Tldr.Win32]::GetForegroundWindow(), [ref]$pid32)
    return [int]$pid32
}

function Get-WindowAtPoint {
    <#  Which window would receive a click here. Honours WS_EX_TRANSPARENT, so
        this is how the smoke test proves the overlay is really click-through. #>
    param([int]$X, [int]$Y)
    $p = New-Object Tldr.POINT
    $p.X = $X
    $p.Y = $Y
    $h = [Tldr.Win32]::WindowFromPoint($p)
    if ($h -eq [IntPtr]::Zero) { return 0 }
    $pid32 = [uint32]0
    [void][Tldr.Win32]::GetWindowThreadProcessId($h, [ref]$pid32)
    return [int]$pid32
}

function Set-WindowTopmost {
    <#  Some apps (trading clients, players) are topmost themselves and raise above
        us when they get activated. Re-asserting costs one call and keeps the spider
        on top without stealing focus or changing size/position. #>
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return }
    [void][Tldr.Win32]::SetWindowPos($Handle, [Tldr.Win32]::HWND_TOPMOST, 0, 0, 0, 0,
        [Tldr.Win32]::SWP_NOMOVE -bor [Tldr.Win32]::SWP_NOSIZE -bor [Tldr.Win32]::SWP_NOACTIVATE)
}
function Set-OverlayWindowStyles {
    <#  Click-through, no activation, out of Alt-Tab: the overlay must never
        steal a click, a keystroke or a selection from the app underneath. #>
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return }
    $ex = [Tldr.Win32]::GetWindowLong($Handle, [Tldr.Win32]::GWL_EXSTYLE)
    $ex = $ex -bor [Tldr.Win32]::WS_EX_TRANSPARENT -bor [Tldr.Win32]::WS_EX_LAYERED -bor [Tldr.Win32]::WS_EX_TOOLWINDOW -bor [Tldr.Win32]::WS_EX_NOACTIVATE
    [void][Tldr.Win32]::SetWindowLong($Handle, [Tldr.Win32]::GWL_EXSTYLE, $ex)
}

function Get-OverlayWindowStyles {
    param([IntPtr]$Handle)
    return [Tldr.Win32]::GetWindowLong($Handle, [Tldr.Win32]::GWL_EXSTYLE)
}

function Test-OverlayWindowStyles {
    param([IntPtr]$Handle)
    $ex = Get-OverlayWindowStyles -Handle $Handle
    return @{
        ClickThrough = [bool]($ex -band [Tldr.Win32]::WS_EX_TRANSPARENT)
        Layered      = [bool]($ex -band [Tldr.Win32]::WS_EX_LAYERED)
        ToolWindow   = [bool]($ex -band [Tldr.Win32]::WS_EX_TOOLWINDOW)
        NoActivate   = [bool]($ex -band [Tldr.Win32]::WS_EX_NOACTIVATE)
    }
}

function Set-PanelWindowStyles {
    <#  The panel must stay clickable, so deliberately NOT click-through: keep it
        out of Alt-Tab and stop it taking focus off the app being read. #>
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return }
    $ex = [Tldr.Win32]::GetWindowLong($Handle, [Tldr.Win32]::GWL_EXSTYLE)
    $ex = $ex -band (-bnot [Tldr.Win32]::WS_EX_TRANSPARENT)
    $ex = $ex -bor [Tldr.Win32]::WS_EX_LAYERED -bor [Tldr.Win32]::WS_EX_TOOLWINDOW -bor [Tldr.Win32]::WS_EX_NOACTIVATE
    [void][Tldr.Win32]::SetWindowLong($Handle, [Tldr.Win32]::GWL_EXSTYLE, $ex)
}

function Test-WindowVisible {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    return [Tldr.Win32]::IsWindowVisible($Handle)
}