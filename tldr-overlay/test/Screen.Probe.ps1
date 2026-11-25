# TL;DR Overlay - Screen.Probe.ps1
# Verifies the reading engine against real text:
#   1. Windows OCR on a bitmap we draw ourselves       (deterministic, no screen)
#   2. UI Automation against a real window with known text (deterministic, own process)
#   3. Diagnostics for whatever sits under the cursor right now
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/Screen.Probe.ps1
#   powershell ... -File test/Screen.Probe.ps1 -AtX 800 -AtY 400     # probe a point

param([int]$AtX = -1, [int]$AtY = -1)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\ScreenReader.ps1')

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

Write-Host "`n1. Windows OCR engine"
$langs = @(Get-OcrLanguages)
Write-Host ("     recognizer languages: " + $(if ($langs.Count) { $langs -join ', ' } else { 'none installed' }))
$engine = Get-OcrEngine
Assert-True 'an OCR engine is available' ($null -ne $engine) ($(if ($engine) { $engine.RecognizerLanguage.LanguageTag } else { 'none' }))

if ($null -ne $engine) {
    $bmp = New-Object System.Drawing.Bitmap(900, 130, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $font = New-Object System.Drawing.Font('Segoe UI', 22)
    $g.DrawString('Orbital Labs announced a $450 million launch in March 2027.', $font, [System.Drawing.Brushes]::Black, 12, 36)
    $g.Dispose()

    $ocr = Get-OcrLinesFromBitmap -Bitmap $bmp
    $bmp.Dispose()
    $joined = ''
    if ($null -ne $ocr) { $joined = (($ocr.Lines | ForEach-Object { $_.Text }) -join ' ') }
    Write-Host ("     OCR read back: '" + $joined + "'")
    # OCR confuses l/I in some fonts, so assert on the stable parts
    Assert-True 'OCR read the company name' ([bool]($joined -match 'Orbita.?\s*Labs')) $joined
    Assert-True 'OCR kept the number 450' ([bool]($joined -match '450'))
    Assert-True 'OCR kept the year 2027' ([bool]($joined -match '2027'))
    Assert-True 'OCR returned word boxes' ($null -ne $ocr -and $ocr.Lines.Count -gt 0 -and $ocr.Lines[0].Rects.Count -ge 3) ("rects=" + $(if ($ocr -and $ocr.Lines.Count) { $ocr.Lines[0].Rects.Count } else { 0 }))
}

Write-Host "`n2. UI Automation against a real window with known text"
$helper = $null
try {
    $textWindow = Join-Path $PSScriptRoot 'TextWindow.ps1'
    $expected = 'Orbital Labs announced a $450 million launch.'
    # one pre-quoted argument string: PowerShell 5.1 does not quote array elements
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $textWindow + '" -Text "' + $expected + '" -Left 120 -Top 120'
    $helper = Start-Process powershell.exe -PassThru -ArgumentList $argLine
    Start-Sleep -Milliseconds 2500
    Assert-True 'test helper process is still running' (-not $helper.HasExited) ("pid=" + $helper.Id)

    $procCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $helper.Id)
    $titleCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'TL;DR test text')
    $win = $null
    for ($try = 0; $try -lt 12 -and $null -eq $win; $try++) {
        $win = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $procCond)
        if ($null -eq $win) { $win = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $titleCond) }
        if ($null -eq $win) { Start-Sleep -Milliseconds 300 }
    }
    Assert-True 'test window found through UIA' ($null -ne $win) ("pid=" + $helper.Id)

    if ($null -ne $win) {
        $doc = $null
        foreach ($type in @([System.Windows.Automation.ControlType]::Document, [System.Windows.Automation.ControlType]::Edit)) {
            if ($null -ne $doc) { continue }
            $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type)
            $doc = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        }
        Assert-True 'text control found' ($null -ne $doc) ("class=" + $(if ($doc) { $doc.Current.ClassName } else { '-' }))

        if ($null -ne $doc) {
            $rect = $doc.Current.BoundingRectangle
            $probeX = [int]($rect.Left + 60)
            $probeY = [int]($rect.Top + 20)
            Write-Host ("     probing physical point " + $probeX + "," + $probeY)

            $hit = Get-UiaLineAtPoint -X $probeX -Y $probeY
            Assert-True 'TextPattern read the line under the point' ($null -ne $hit)
            if ($null -ne $hit) {
                Write-Host ("     read: '" + $hit.Text + "'  offset=" + $hit.Offset + "  uia-line-rects=" + @($hit.Rects).Count)
                Assert-True 'read text matches what we put in the window' ([bool]($hit.Text -match 'Orbital Labs')) $hit.Text
                Assert-True 'caret offset is inside the line' ($hit.Offset -ge 0 -and $hit.Offset -le $hit.Text.Length) ("offset=" + $hit.Offset)
                Assert-True 'reports the owning app' ($hit.App -eq 'powershell') $hit.App
                Assert-True 'reports a foreign process id' ($hit.ProcessId -ne $PID) ("pid=" + $hit.ProcessId)

                # Geometry is what the yellow highlight needs. Providers vary wildly
                # (a WPF TextBox returns no boxes at all), so the chain must resolve
                # one way or another.
                $geometry = Get-HighlightGeometry -Hit $hit -Start 0 -Length 15 -FootX $probeX -FootY $probeY
                $geoRects = @($geometry.Rects)
                Assert-True 'highlight geometry resolved' ($geoRects.Count -ge 1) ("source=" + $geometry.Source + " rects=" + $geoRects.Count)
                if ($geoRects.Count -ge 1) {
                    $box = $geoRects[0]
                    Assert-True 'highlight box is near the probe point' (
                        ($probeX -ge ($box.X - 120)) -and ($probeX -le ($box.X + $box.W + 120)) -and
                        ($probeY -ge ($box.Y - 60)) -and ($probeY -le ($box.Y + $box.H + 60))
                    ) ("box=" + $box.X + "," + $box.Y + " " + $box.W + "x" + $box.H)
                }

                $noOcr = Get-ScreenPointText -X $probeX -Y $probeY -AllowOcr $false
                Assert-True 'UIA path works without OCR' ($null -ne $noOcr -and $noOcr.Source -eq 'uia') ($(if ($noOcr) { $noOcr.Source } else { 'null' }))
            }
        }
    }
} finally {
    if ($null -ne $helper) { Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n3. OCR fallback on a live screen region"
$corner = Get-CursorPosition
$ocrHit = Get-OcrLineAtPoint -X $corner.X -Y $corner.Y
if ($null -eq $ocrHit) {
    Write-Host '     (nothing legible under the cursor right now - not a failure)'
} else {
    Write-Host ("     ocr read: '" + $ocrHit.Text + "'  rects=" + $ocrHit.Rects.Count + " offset=" + $ocrHit.Offset)
    Assert-True 'OCR returns screen-space word boxes' ($ocrHit.Rects.Count -ge 1) ("rects=" + $ocrHit.Rects.Count)
    Assert-True 'OCR offset is inside the text' ($ocrHit.Offset -ge 0 -and $ocrHit.Offset -le $ocrHit.Text.Length)
}

if ($AtX -ge 0 -and $AtY -ge 0) {
    Write-Host ("`n4. diagnostics at " + $AtX + "," + $AtY)
    $hit = Get-ScreenPointText -X $AtX -Y $AtY
    if ($null -eq $hit) {
        Write-Host '     nothing readable there'
    } else {
        Write-Host ("     source=" + $hit.Source + " app=" + $hit.App + " offset=" + $hit.Offset + " rects=" + $hit.Rects.Count)
        Write-Host ("     text: '" + $hit.Text + "'")
    }
} else {
    Write-Host "`n4. diagnostics at the current cursor position"
    $hit = Get-ScreenPointText -X $corner.X -Y $corner.Y
    if ($null -eq $hit) {
        Write-Host ("     nothing readable under the cursor at " + $corner.X + "," + $corner.Y)
    } else {
        Write-Host ("     source=" + $hit.Source + " app=" + $hit.App + " offset=" + $hit.Offset + " rects=" + $hit.Rects.Count)
        Write-Host ("     text: '" + $hit.Text + "'")
    }
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host ("SCREEN PROBE FAILED: {0} of {1} checks" -f $script:Failures, $script:Checks)
    exit 1
}
Write-Host ("Screen reader probe: all {0} assertions passed" -f $script:Checks)
exit 0
