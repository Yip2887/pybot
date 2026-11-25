# TL;DR Overlay - TextWindow.ps1 (test helper)
# Opens a plain WPF window full of known text so the screen reader can be tested
# against real, deterministic UI Automation content.
#   powershell -NoProfile -File test/TextWindow.ps1

param(
    [string]$Text = 'Orbital Labs announced a $450 million launch. The rocket carries 24 satellites into low orbit. Price per kilogram dropped 38% compared with the previous model.',
    [int]$Left = 80,
    [int]$Top = 80,
    [int]$Width = 900,
    [int]$Height = 320,
    [string]$RefreshFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Win32.ps1')
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop

$window = New-Object System.Windows.Window
$window.Left = $Left
$window.Top = $Top
$window.Width = $Width
$window.Height = $Height
$window.Title = 'TL;DR test text'
$window.Topmost = $true
$window.Background = [System.Windows.Media.Brushes]::White
$window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual

$box = New-Object System.Windows.Controls.TextBox
$box.Text = $Text
$box.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
$box.FontSize = 20
$box.TextWrapping = [System.Windows.TextWrapping]::Wrap
$box.AcceptsReturn = $true
$box.IsReadOnly = $true
$box.BorderThickness = New-Object System.Windows.Thickness(0)
$box.Padding = New-Object System.Windows.Thickness(12)
$window.Content = $box

if ($RefreshFile) {
    # a live-updating window, so watch mode can be tested without a trading client
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({
        try {
            if (Test-Path -LiteralPath $RefreshFile) {
                $new = [IO.File]::ReadAllText($RefreshFile, [Text.Encoding]::UTF8)
                if ($new -ne $box.Text) { $box.Text = $new }
            }
        } catch { }
    })
    $timer.Start()
    $window.Add_Closed({ $timer.Stop() })
}

$window.Show()
[Console]::Out.WriteLine('READY ' + $PID)
[Console]::Out.Flush()
[System.Windows.Threading.Dispatcher]::Run()
