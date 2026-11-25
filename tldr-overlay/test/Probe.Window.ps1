# TL;DR Overlay - Probe.Window.ps1
# "Can it read THIS app?" - points the screen reader at a running window and reports
# what UI Automation exposes there and what OCR can see.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/Probe.Window.ps1 -ProcessId 11384
#   ... -List                       just list readable top-level windows
#   ... -Samples 9 -TreeDump 40     more sample points / a longer tree dump

param(
    [int]$ProcessId = 0,
    [string]$Title = '',
    [int]$Samples = 6,
    [int]$TreeDump = 25,
    [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Win32.ps1')
. (Join-Path $root 'lib\ScreenReader.ps1')
Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

function Get-TopWindows {
    return @([System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition))
}

function Format-Rect {
    param($Rect)
    return ("" + [Math]::Round($Rect.Left) + "," + [Math]::Round($Rect.Top) + " " +
        [Math]::Round($Rect.Width) + "x" + [Math]::Round($Rect.Height))
}

function Get-WindowLabel {
    param($Window)
    try {
        $procId = $Window.Current.ProcessId
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $pname = if ($proc) { $proc.ProcessName } else { '?' }
        return ("pid=" + $procId + " [" + $pname + "] '" + $Window.Current.Name + "'")
    } catch {
        return 'pid=? [?]'
    }
}

Write-Host "`n1. top-level windows"
$all = @(Get-TopWindows)
if ($List -or ($ProcessId -le 0 -and [string]::IsNullOrEmpty($Title))) {
    foreach ($w in $all) {
        try {
            $r = $w.Current.BoundingRectangle
            if ($r.Width -lt 40 -or $r.Height -lt 40) { continue }
            Write-Host ("  " + (Get-WindowLabel -Window $w) + "  " + (Format-Rect -Rect $r))
        } catch { }
    }
    if ($List) { exit 0 }
}

$windows = @()
foreach ($w in $all) {
    try {
        if ($ProcessId -gt 0) {
            if ($w.Current.ProcessId -eq $ProcessId) { $windows += $w }
        } elseif (-not [string]::IsNullOrEmpty($Title)) {
            $nm = $w.Current.Name
            if ($nm -like "*$Title*") { $windows += $w }
        }
    } catch { }
}

if ($windows.Count -eq 0) {
    Write-Host '  no matching window among:'
    foreach ($w in $all) { Write-Host ("    " + (Get-WindowLabel -Window $w)) }
    exit 1
}

foreach ($w in $windows) {
    Write-Host ("  " + (Get-WindowLabel -Window $w) + "  " + (Format-Rect -Rect $w.Current.BoundingRectangle))
}

$target = $windows[0]
$rect = $target.Current.BoundingRectangle
$targetPid = $target.Current.ProcessId

Write-Host "`n2. what UI Automation exposes inside it"
$uiaTextCount = 0
try {
    $nodes = $target.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    Write-Host ("  descendants: " + $nodes.Count)
    $named = 0
    $textPattern = 0
    foreach ($el in $nodes) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($el.Current.Name)) { $named++ }
            $p = $null
            if ($el.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$p)) { $textPattern++ }
        } catch { }
    }
    $uiaTextCount = $named
    Write-Host ("  elements with a Name: " + $named)
    Write-Host ("  elements with TextPattern: " + $textPattern)
    Write-Host '  first elements:'
    $i = 0
    foreach ($el in $nodes) {
        if ($i++ -ge $TreeDump) { break }
        $pats = @()
        try { foreach ($p in $el.GetSupportedPatterns()) { $pats += $p.ProgrammaticName.Replace('PatternIdentifiers.Pattern', '') } } catch { }
        $nm = [string]$el.Current.Name
        if ($nm.Length -gt 44) { $nm = $nm.Substring(0, 44) + '…' }
        Write-Host ("    [" + $el.Current.ControlType.ProgrammaticName + "] class=" + $el.Current.ClassName + " name='" + $nm + "' patterns=" + ($pats -join ','))
    }
} catch {
    Write-Host ("  tree walk failed: " + $_.Exception.Message)
}

Write-Host "`n3. reading points inside the window"
$cols = 3
$rows = [Math]::Max(1, [int][Math]::Ceiling($Samples / 3.0))
$uiaHits = 0
$ocrHits = 0
$tested = 0
for ($row = 1; $row -le $rows; $row++) {
    for ($col = 1; $col -le $cols; $col++) {
        $x = [int]($rect.Left + $rect.Width * $col / ($cols + 1))
        $y = [int]($rect.Top + $rect.Height * $row / ($rows + 1))
        $topPid = Get-WindowAtPoint -X $x -Y $y
        $visible = ($topPid -eq $targetPid)
        $tested++
        Write-Host ("  " + $x + "," + $y + " topmost=" + $(if ($visible) { 'this window' } else { 'pid ' + $topPid + ' (covered)' }))

        $uia = $null
        try { $uia = Get-UiaLineAtPoint -X $x -Y $y } catch { }
        if ($null -ne $uia) {
            $uiaHits++
            $t = [string]$uia.Text
            if ($t.Length -gt 46) { $t = $t.Substring(0, 46) + '…' }
            Write-Host ("      UIA: '" + $t + "'  rects=" + @($uia.Rects).Count)
        } else {
            Write-Host '      UIA: nothing'
        }

        if (-not $visible) {
            Write-Host '      OCR: skipped (another window is on top there)'
        } else {
            $ocr = $null
            try { $ocr = Get-OcrLineAtPoint -X $x -Y $y } catch { }
            if ($null -ne $ocr) {
                $ocrHits++
                $t = [string]$ocr.Text
                if ($t.Length -gt 46) { $t = $t.Substring(0, 46) + '…' }
                Write-Host ("      OCR: '" + $t + "'  rects=" + @($ocr.Rects).Count)
            } else {
                Write-Host '      OCR: nothing'
            }
        }
    }
}

Write-Host ''
Write-Host ("  sampled " + $tested + " points: UIA gave text at " + $uiaHits + ", OCR gave text at " + $ocrHits)
if ($uiaHits -eq 0 -and $ocrHits -eq 0) {
    Write-Host '  -> the spider has nothing to read there right now'
} elseif ($uiaHits -eq 0) {
    Write-Host '  -> no UI Automation text: the spider falls back to OCR in this app'
} else {
    Write-Host '  -> UI Automation text available: exact text and exact highlight boxes'
}
exit 0
