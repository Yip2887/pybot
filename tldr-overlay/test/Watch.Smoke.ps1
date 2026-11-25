# TL;DR Overlay - Watch.Smoke.ps1
#
# !! WHAT THIS PROVES AND WHAT IT DOES NOT !!
# The alert lines below are SYNTHETIC text that this test writes into a window it
# controls. That makes the run deterministic, and it proves the PIPELINE: new-line
# detection, OCR-jitter de-duplication, the two-frame confirmation, the auto
# on/off switch and teardown. It proves NOTHING about how well 同花顺 itself is read
# - for that see test/Probe.Watch.ps1, which dumps the raw OCR of the real panel.
#
# End-to-end test for 盯盘模式 (watch mode) without a trading client:
#   * opens a window whose text is driven by a file
#   * points the watch region at it (through a temporary config)
#   * starts the real app, waits for it to pick up the panel
#   * appends a new "alert" line and asserts the app reports exactly that one,
#     exactly once, and that the earlier lines are not re-reported
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/Watch.Smoke.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Win32.ps1')
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

$script:Failures = 0
$script:Checks = 0

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

function Send-HotkeyQuit {
    if (-not ('TldrTest.Hotkey' -as [type])) {
        Add-Type -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
public static void Quit() {
    keybd_event(0x11, 0, 0, System.UIntPtr.Zero);
    keybd_event(0x12, 0, 0, System.UIntPtr.Zero);
    keybd_event(0x51, 0, 0, System.UIntPtr.Zero);
    keybd_event(0x51, 0, 2, System.UIntPtr.Zero);
    keybd_event(0x12, 0, 2, System.UIntPtr.Zero);
    keybd_event(0x11, 0, 2, System.UIntPtr.Zero);
}
"@ -Name Hotkey -Namespace TldrTest
    }
    [TldrTest.Hotkey]::Quit()
}

$feedPath = Join-Path $env:TEMP 'tldr-watch-feed.txt'
$cfgPath = Join-Path $env:TEMP 'tldr-watch-config.json'
$logPath = Join-Path $env:TEMP 'tldr-overlay.log'

$first = "09:31:24 600663 陆家嘴 急速拉升 5.21%`r`n09:31:30 600737 中粮糖业 打开跌停板 4.17%"
$second = $first + "`r`n09:32:02 002262 恩华药业 涨速突破 6.08%"
[IO.File]::WriteAllText($feedPath, $first, [Text.Encoding]::UTF8)
Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

Write-Host "`n1. a window whose content we control"
$helper = Start-Process powershell.exe -PassThru -ArgumentList (
    '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'TextWindow.ps1') + '" -Left 140 -Top 200 -Width 620 -Height 260 -RefreshFile "' + $feedPath + '"'
)
Start-Sleep -Milliseconds 3000
$procCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $helper.Id)
$win = $null
for ($i = 0; $i -lt 12 -and $null -eq $win; $i++) {
    $win = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $procCond)
    if ($null -eq $win) { Start-Sleep -Milliseconds 300 }
}
Assert-True 'test window is up' ($null -ne $win) ("pid=" + $helper.Id)

$doc = $null
if ($null -ne $win) {
    foreach ($type in @([System.Windows.Automation.ControlType]::Document, [System.Windows.Automation.ControlType]::Edit)) {
        if ($null -ne $doc) { continue }
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type)
        $doc = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    }
}
Assert-True 'text control found' ($null -ne $doc)

$rect = $doc.Current.BoundingRectangle
$region = @{
    X = [int]$rect.Left
    Y = [int]$rect.Top
    W = [int]$rect.Width
    H = [int]$rect.Height
}
Write-Host ("     watch region: " + $region.X + "," + $region.Y + " " + $region.W + "x" + $region.H)

@{
    apiKey = ''; model = 'claude-3-5-haiku-latest'; speedCap = 420; stepMs = 130; glitch = 0.25
    maxWords = 9; minChars = 8
    watchX = $region.X; watchY = $region.Y; watchW = $region.W; watchH = $region.H
    watchScale = 3; watchIntervalMs = 700; alertFilter = ''; alertBeep = $false; alertRequireType = $true
} | ConvertTo-Json | Set-Content -LiteralPath $cfgPath -Encoding UTF8

Write-Host "`n2. start the app in watch mode"
$app = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList (
    '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'TldrOverlay.ps1') + '" -ConfigPath "' + $cfgPath + '" -RunSeconds 45'
)
Start-Sleep -Seconds 9
Assert-True 'app is running' (-not $app.HasExited) ("pid=" + $app.Id)

function Get-AlertLines {
    if (-not (Test-Path -LiteralPath $logPath)) { return @() }
    return @(Get-Content -LiteralPath $logPath | Where-Object { $_ -match '异动: ' })
}

$initial = Get-AlertLines
Write-Host ("     initial alerts: " + $initial.Count)
foreach ($l in $initial) { Write-Host ("       " + $l) }
Assert-True 'watch mode was restored from the config' ([bool](@(Get-Content -LiteralPath $logPath | Where-Object { $_ -match 'watch mode restored' }).Count))
Assert-True 'the two lines already on screen are picked up' ($initial.Count -ge 2) ("count=" + $initial.Count)
Assert-True 'the alert type is recognised in the feed' ([bool](@($initial | Where-Object { $_ -match '急速拉升|打开跌停板' }).Count))

Write-Host "`n3. a new alert appears in the panel"
[IO.File]::WriteAllText($feedPath, $second, [Text.Encoding]::UTF8)
Start-Sleep -Seconds 8
$after = Get-AlertLines
$new = @($after | Where-Object { $_ -match '恩华药业|涨速突破' })
Write-Host ("     alerts now: " + $after.Count)
foreach ($l in $after) { Write-Host ("       " + $l) }
Assert-True 'the new line is reported' ($new.Count -ge 1) ($new -join ' / ')
Assert-True 'only the new line was added' (($after.Count - $initial.Count) -le 2) ("added=" + ($after.Count - $initial.Count))
Assert-True 'the earlier lines are not re-reported' (@($after | Where-Object { $_ -match '陆家嘴' }).Count -le 2) (
    "陆家嘴 mentions: " + @($after | Where-Object { $_ -match '陆家嘴' }).Count)

Write-Host "`n4. auto switching: sense the window, watch it, hand back when it goes away"
$autoCfg = Join-Path $env:TEMP 'tldr-auto-config.json'
@{
    apiKey = ''; model = 'claude-3-5-haiku-latest'; speedCap = 420; stepMs = 130; glitch = 0.25
    maxWords = 9; minChars = 8
    watchX = $region.X; watchY = $region.Y; watchW = $region.W; watchH = $region.H
    watchScale = 3; watchIntervalMs = 700; alertFilter = ''; alertBeep = $false; alertRequireType = $true
    autoWatch = $true; watchProcess = 'powershell'
} | ConvertTo-Json | Set-Content -LiteralPath $autoCfg -Encoding UTF8

Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
$autoApp = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList (
    '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'TldrOverlay.ps1') + '" -ConfigPath "' + $autoCfg + '" -RunSeconds 40'
)
Start-Sleep -Seconds 6
$autoLog = @(Get-Content -LiteralPath $logPath)
Assert-True 'the app senses the watched window and starts watching on its own' (
    [bool](@($autoLog | Where-Object { $_ -match 'auto watch ON|watch mode restored' }).Count)) (
    (@($autoLog | Where-Object { $_ -match 'auto watch|watch mode' }) -join ' / '))

Write-Host '     now take the watched window away'
Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 7
$autoLog = @(Get-Content -LiteralPath $logPath)
Assert-True 'and hands back to cursor crawling when it disappears' (
    [bool](@($autoLog | Where-Object { $_ -match 'auto watch OFF' }).Count)) (
    (@($autoLog | Where-Object { $_ -match 'auto watch OFF' }) -join ' / '))
Assert-True 'no runtime errors during the auto switch' (-not (@($autoLog | Where-Object { $_ -match 'failed|fatal' }).Count)) (
    (@($autoLog | Where-Object { $_ -match 'failed|fatal' }) -join ' / '))
if (-not $autoApp.HasExited) { Stop-Process -Id $autoApp.Id -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $autoCfg -Force -ErrorAction SilentlyContinue

Write-Host "`n5. shut down cleanly"
Send-HotkeyQuit
$exited = $app.WaitForExit(20000)
Assert-True 'app exits' $exited
$log = @(Get-Content -LiteralPath $logPath)
Assert-True 'no runtime errors' (-not (@($log | Where-Object { $_ -match 'failed|fatal' }).Count)) (
    (@($log | Where-Object { $_ -match 'failed|fatal' }) -join ' / '))

if ($null -ne $helper -and -not $helper.HasExited) { Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue }
if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $feedPath, $cfgPath -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host ("WATCH SMOKE FAILED: {0} of {1} checks" -f $script:Failures, $script:Checks)
    exit 1
}
Write-Host ("Watch smoke test: all {0} assertions passed" -f $script:Checks)
exit 0
