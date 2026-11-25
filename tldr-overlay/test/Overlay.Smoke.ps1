# TL;DR Overlay - Overlay.Smoke.ps1
# Starts the real app and checks it from the outside:
#   * both windows come up, the overlay is click-through and never foreground
#   * the spider really paints, and it moves, on the desktop
#   * it reads real text off the screen and the panel counts it
#   * Ctrl+Alt+S toggles it off and back on, Ctrl+Alt+Q exits
#   * quitting leaves no window, no process and nothing painted behind
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/Overlay.Smoke.ps1

param([int]$RunSeconds = 60)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Win32.ps1')
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$script:Failures = 0
$script:Checks = 0
$script:LogPath = Join-Path $env:TEMP 'tldr-overlay.log'

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:Checks++
    if ($Condition) {
        Write-Host ("  ok   {0}{1}" -f $Name, $(if ($Detail) { "  ($Detail)" } else { '' }))
    } else {
        $script:Failures++
        Write-Host ("  FAIL {0}{1}" -f $Name, $(if ($Detail) { "  ($Detail)" } else { '' }))
    }
}

function Get-LogLines {
    if (-not (Test-Path -LiteralPath $script:LogPath)) { return @() }
    return @(Get-Content -LiteralPath $script:LogPath)
}

if (-not ('TldrTest.Pixels' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Drawing') -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace TldrTest {
    public static class Pixels {
        // [count, centroidX, centroidY] of pixels close to the spider colour #5ab8ff
        public static double[] BlueStats(Bitmap bmp, int tol, int step) {
            Rectangle rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
            BitmapData data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            double count = 0, sx = 0, sy = 0;
            try {
                byte[] buf = new byte[data.Stride * bmp.Height];
                Marshal.Copy(data.Scan0, buf, 0, buf.Length);
                for (int y = 0; y < bmp.Height; y += step) {
                    int row = y * data.Stride;
                    for (int x = 0; x < bmp.Width; x += step) {
                        int i = row + x * 4;
                        int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                        if (Math.Abs(r - 0x5a) < tol && Math.Abs(g - 0xb8) < tol && Math.Abs(b - 0xff) < tol) {
                            count++; sx += x; sy += y;
                        }
                    }
                }
            } finally { bmp.UnlockBits(data); }
            if (count == 0) return new double[] { 0, 0, 0 };
            return new double[] { count, sx / count, sy / count };
        }
    }
}
'@ -ErrorAction Stop
}

function Get-WindowsOfProcess {
    param([int]$ProcessId)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    return @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond))
}

function Get-AppWindows {
    param([int]$ProcessId)
    $overlay = $null
    $panel = $null
    foreach ($win in @(Get-WindowsOfProcess -ProcessId $ProcessId)) {
        $r = $win.Current.BoundingRectangle
        if ($r.Width -gt 600) { $overlay = $win } elseif ($r.Width -gt 100) { $panel = $win }
    }
    return @{ Overlay = $overlay; Panel = $panel }
}

function Get-DescendantText {
    param($Window)
    $texts = @()
    try {
        $all = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($el in $all) {
            if ($el.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and -not [string]::IsNullOrWhiteSpace($el.Current.Name)) {
                $texts += $el.Current.Name
            }
        }
    } catch { }
    return $texts
}

function Get-ScreenStats {
    $vs = Get-VirtualScreenRect
    $w = [Math]::Min($vs.W, 1920)
    $h = [Math]::Min($vs.H, 1080)
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, (New-Object System.Drawing.Size($w, $h))) } finally { $g.Dispose() }
    try { return [TldrTest.Pixels]::BlueStats($bmp, 45, 2) } finally { $bmp.Dispose() }
}

function Send-Hotkey {
    param([int]$VirtualKey)
    if (-not ('TldrTest.Hotkey' -as [type])) {
        Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
public static void Chord(byte vk) {
    keybd_event(0x11, 0, 0, System.UIntPtr.Zero);
    keybd_event(0x12, 0, 0, System.UIntPtr.Zero);
    keybd_event(vk, 0, 0, System.UIntPtr.Zero);
    keybd_event(vk, 0, 2, System.UIntPtr.Zero);
    keybd_event(0x12, 0, 2, System.UIntPtr.Zero);
    keybd_event(0x11, 0, 2, System.UIntPtr.Zero);
}
'@ -Name Hotkey -Namespace TldrTest
    }
    [TldrTest.Hotkey]::Chord([byte]$VirtualKey)
}

Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue

# this suite tests cursor mode, so give the app its own config with NO watch region
$cfgPath = Join-Path $env:TEMP 'tldr-smoke-config.json'
@{
    apiKey = ''; model = 'claude-3-5-haiku-latest'; speedCap = 420; stepMs = 130; glitch = 0.25
    maxWords = 9; minChars = 8
    watchX = 0; watchY = 0; watchW = 0; watchH = 0; watchScale = 3; watchIntervalMs = 900
    alertFilter = ''; alertBeep = $false; alertRequireType = $true
} | ConvertTo-Json | Set-Content -LiteralPath $cfgPath -Encoding UTF8

$cursor = Get-CursorPosition
$baseline = Get-ScreenStats
$baselinePid = Get-WindowAtPoint -X $cursor.X -Y $cursor.Y

Write-Host "`n1. start the app"
$app = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList (
    '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'TldrOverlay.ps1') + '" -ConfigPath "' + $cfgPath + '" -RunSeconds ' + $RunSeconds
)
Start-Sleep -Milliseconds 6000
Assert-True 'app process is running' (-not $app.HasExited) ("pid=" + $app.Id)
Assert-True 'overlay does not capture clicks at the cursor' ((Get-WindowAtPoint -X $cursor.X -Y $cursor.Y) -ne $app.Id) (
    "cursor window pid " + (Get-WindowAtPoint -X $cursor.X -Y $cursor.Y) + " vs baseline " + $baselinePid)
Assert-True 'overlay never becomes the foreground window' ((Get-ForegroundProcessId) -ne $app.Id)

Write-Host "`n2. windows and styles"
$w = Get-AppWindows -ProcessId $app.Id
Assert-True 'the full-screen overlay window exists' ($null -ne $w.Overlay)
Assert-True 'the floating panel window exists' ($null -ne $w.Panel)

if ($null -ne $w.Overlay) {
    $styles = Test-OverlayWindowStyles -Handle ([IntPtr]$w.Overlay.Current.NativeWindowHandle)
    Assert-True 'overlay is click-through (WS_EX_TRANSPARENT)' ($styles.ClickThrough)
    Assert-True 'overlay is layered' ($styles.Layered)
    Assert-True 'overlay is out of Alt-Tab (WS_EX_TOOLWINDOW)' ($styles.ToolWindow)
    Assert-True 'overlay cannot be activated (WS_EX_NOACTIVATE)' ($styles.NoActivate)
    $r = $w.Overlay.Current.BoundingRectangle
    $vs = Get-VirtualScreenRect
    $scale = Get-DpiScale
    Assert-True 'overlay covers the whole desktop' (
        [Math]::Abs($r.Width - $vs.W / $scale) -lt 8 -and [Math]::Abs($r.Height - $vs.H / $scale) -lt 8
    ) ("window=" + [int]$r.Width + "x" + [int]$r.Height + " desktop=" + [int]($vs.W / $scale) + "x" + [int]($vs.H / $scale))
}

if ($null -ne $w.Panel) {
    $styles = Test-OverlayWindowStyles -Handle ([IntPtr]$w.Panel.Current.NativeWindowHandle)
    Assert-True 'panel is NOT click-through (its buttons must work)' (-not $styles.ClickThrough)
    Assert-True 'panel cannot steal focus either' ($styles.NoActivate)
}

Write-Host "`n3. the spider paints and moves"
$samples = @()
for ($i = 0; $i -lt 8; $i++) {
    $samples += , (Get-ScreenStats)
    Start-Sleep -Milliseconds 900
}
$painted = ($samples | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum
Assert-True 'spider blue pixels appear on screen' ($painted -gt ($baseline[0] + 150)) (
    "baseline=" + $baseline[0] + " peak=" + $painted)
$moved = 0.0
for ($i = 1; $i -lt $samples.Count; $i++) {
    $dx = $samples[$i][1] - $samples[$i - 1][1]
    $dy = $samples[$i][2] - $samples[$i - 1][2]
    $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
    if ($d -gt $moved) { $moved = $d }
}
Assert-True 'the spider is animated (blue centroid moves)' ($moved -gt 8) ("max centroid shift=" + [int]$moved + "px")

Write-Host "`n4. it reads text off the screen and the panel counts it"
$counterText = ''
for ($i = 0; $i -lt 20 -and $counterText -notmatch '^[1-9]'; $i++) {
    Start-Sleep -Milliseconds 1200
    $frames = Get-AppWindows -ProcessId $app.Id
    if ($null -ne $frames.Panel) {
        $texts = Get-DescendantText -Window $frames.Panel
        $found = @($texts | Where-Object { $_ -match '^\d+ / \d+$' })
        if ($found.Count -ge 1) { $counterText = $found[0] }
    }
}
$panelTexts = Get-DescendantText -Window (Get-AppWindows -ProcessId $app.Id).Panel
Write-Host ("     panel text: " + ($panelTexts -join ' | '))
Assert-True 'panel shows its title' ([bool](@($panelTexts | Where-Object { $_ -eq 'TL;DR' }).Count))
Assert-True 'panel shows a found / total counter' ($counterText -match '^\d+ / \d+$') $counterText
Assert-True 'the spider found at least one key sentence on screen' ($counterText -match '^[1-9]') $counterText
Assert-True 'panel has the copy / restart / close buttons' (
    [bool](@($panelTexts | Where-Object { $_ -eq '复制 TL;DR' }).Count) -and
    [bool](@($panelTexts | Where-Object { $_ -eq '重新启动' }).Count) -and
    [bool](@($panelTexts | Where-Object { $_ -eq '关闭' }).Count))

Write-Host "`n5. hotkey toggle"
Send-Hotkey -VirtualKey 0x53   # Ctrl+Alt+S
Start-Sleep -Milliseconds 1800
Assert-True 'Ctrl+Alt+S reaches the app' ([bool](@(Get-LogLines | Where-Object { $_ -match 'hotkey: crawler OFF' }).Count))
$frames = Get-AppWindows -ProcessId $app.Id
Assert-True 'overlay window is hidden' ($null -eq $frames.Overlay -or -not (Test-WindowVisible -Handle ([IntPtr]$frames.Overlay.Current.NativeWindowHandle)))
$off = Get-ScreenStats
Assert-True 'nothing is painted once it is off' ($off[0] -le ($baseline[0] + 150)) ("baseline=" + $baseline[0] + " off=" + $off[0])

Send-Hotkey -VirtualKey 0x53
Start-Sleep -Milliseconds 1800
Assert-True 'Ctrl+Alt+S turns it back on' ([bool](@(Get-LogLines | Where-Object { $_ -match 'hotkey: crawler ON' }).Count))
$frames = Get-AppWindows -ProcessId $app.Id
Assert-True 'overlay window is visible again' ($null -ne $frames.Overlay -and (Test-WindowVisible -Handle ([IntPtr]$frames.Overlay.Current.NativeWindowHandle)))

Write-Host "`n6. clean shutdown"
Send-Hotkey -VirtualKey 0x51   # Ctrl+Alt+Q
Start-Sleep -Milliseconds 1500
Assert-True 'Ctrl+Alt+Q reaches the app' ([bool](@(Get-LogLines | Where-Object { $_ -match 'quit requested' }).Count))
$exited = $app.WaitForExit(20000)
Assert-True 'the process exits' $exited
Start-Sleep -Milliseconds 1500
Assert-True 'no window of the app is left' ((@(Get-WindowsOfProcess -ProcessId $app.Id)).Count -eq 0)
Assert-True 'click-through intact after shutdown' ((Get-WindowAtPoint -X $cursor.X -Y $cursor.Y) -ne $app.Id)
$after = Get-ScreenStats
Assert-True 'nothing of the spider is left on screen' ($after[0] -le ($baseline[0] + 150)) (
    "baseline=" + $baseline[0] + " after=" + $after[0])

$log = @(Get-LogLines)
Assert-True 'log shows the overlay came up' ([bool](@($log | Where-Object { $_ -match 'overlay up' }).Count))
Assert-True 'log shows the hotkeys registered' ([bool](@($log | Where-Object { $_ -match 'hotkeys: Ctrl\+Alt\+S=True' }).Count))
Assert-True 'log shows a clean stop' ([bool](@($log | Where-Object { $_ -match 'stopped' }).Count))
Assert-True 'no fatal error in the log' (-not (@($log | Where-Object { $_ -match 'fatal' }).Count))
$errors = @($log | Where-Object { $_ -match 'failed' })
Assert-True 'no runtime errors in the log' ($errors.Count -eq 0) ($errors -join ' / ')

Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host ("OVERLAY SMOKE FAILED: {0} of {1} checks" -f $script:Failures, $script:Checks)
    exit 1
}
Write-Host ("Overlay smoke test: all {0} assertions passed" -f $script:Checks)
exit 0
