# TL;DR Overlay - ScreenReader.ps1
# Reads the text under an arbitrary screen point.
#
#   1. UI Automation TextPattern  -> exact text + exact bounding boxes, no OCR error
#   2. Windows built-in OCR       -> fallback for canvas / game / image-only windows
#
# Everything is in physical screen pixels (the process is DPI aware, see Win32.ps1).

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Win32.ps1')

Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

$script:UiaStart = [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start
$script:UiaEnd = [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End
$script:UiaLine = [System.Windows.Automation.Text.TextUnit]::Line
$script:UiaChar = [System.Windows.Automation.Text.TextUnit]::Character
$script:TextPatternPattern = [System.Windows.Automation.TextPattern]::Pattern

# ---------------------------------------------------------------- helpers

function ConvertTo-RectList {
    <#  Providers hand back bounding boxes in two shapes: PowerShell projects
        GetBoundingRectangles() into System.Windows.Rect[] on this build, while the
        raw API contract is a flat double[] of (x, y, w, h) quads. Handle both. #>
    param($Doubles)

    $out = @()
    if ($null -eq $Doubles) { return , $out }
    $items = @($Doubles)
    if ($items.Count -eq 0) { return , $out }

    if ($items[0] -is [System.Windows.Rect]) {
        foreach ($r in $items) {
            if ($r.Width -lt 2 -or $r.Height -lt 2) { continue }
            $out += @{
                X = [int][Math]::Round($r.X); Y = [int][Math]::Round($r.Y)
                W = [int][Math]::Round($r.Width); H = [int][Math]::Round($r.Height)
            }
        }
        return , $out
    }

    $n = [int]($items.Count / 4)
    for ($i = 0; $i -lt $n; $i++) {
        $x = [double]$items[$i * 4]
        $y = [double]$items[$i * 4 + 1]
        $w = [double]$items[$i * 4 + 2]
        $h = [double]$items[$i * 4 + 3]
        if ($w -lt 2 -or $h -lt 2) { continue } # providers hand back 1x1 artefacts
        $out += @{ X = [int][Math]::Round($x); Y = [int][Math]::Round($y); W = [int][Math]::Round($w); H = [int][Math]::Round($h) }
    }
    return , $out
}

function Get-RectBounds {
    <#  Bounding box around a list of rects (Measure-Object cannot read hashtable keys). #>
    param($Rects)
    $x0 = [int]::MaxValue; $y0 = [int]::MaxValue; $x1 = [int]::MinValue; $y1 = [int]::MinValue
    foreach ($r in $Rects) {
        if ($r.X -lt $x0) { $x0 = $r.X }
        if ($r.Y -lt $y0) { $y0 = $r.Y }
        if (($r.X + $r.W) -gt $x1) { $x1 = $r.X + $r.W }
        if (($r.Y + $r.H) -gt $y1) { $y1 = $r.Y + $r.H }
    }
    if ($x1 -eq [int]::MinValue) { return $null }
    return @{ X0 = $x0; Y0 = $y0; X1 = $x1; Y1 = $y1 }
}

function Test-RectContains {
    param($Rect, [int]$X, [int]$Y)
    if ($null -eq $Rect) { return $false }
    return ($X -ge $Rect.X -and $X -le ($Rect.X + $Rect.W) -and $Y -ge $Rect.Y -and $Y -le ($Rect.Y + $Rect.H))
}

function Test-RectListContains {
    param($Rects, [int]$X, [int]$Y)
    foreach ($r in $Rects) { if (Test-RectContains -Rect $r -X $X -Y $Y) { return $true } }
    return $false
}

function Get-ProcessNameSafe {
    param([int]$ProcessId)
    try { return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName } catch { return ('pid' + $ProcessId) }
}

# ---------------------------------------------------------------- UI Automation

function Find-TextProvider {
    <#  Depth-first search for the deepest element at the point that supports
        TextPattern. Chrome/Edge only expose text on the document node, so the
        walk down is what makes browsers work. #>
    param($Element, [System.Windows.Point]$Point, [int]$Depth)

    if ($null -eq $Element) { return $null }
    try {
        # never read our own panel / overlay
        if ($Element.Current.ProcessId -eq $PID) { return $null }
    } catch { return $null }

    $pattern = $null
    $has = $false
    try { $has = $Element.TryGetCurrentPattern($script:TextPatternPattern, [ref]$pattern) } catch { $has = $false }
    if ($has -and $null -ne $pattern) { return @{ Element = $Element; Pattern = $pattern } }
    if ($Depth -le 0) { return $null }

    $children = $null
    try { $children = $Element.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition) } catch { return $null }
    if ($null -eq $children -or $children.Count -eq 0) { return $null }

    $candidates = @()
    foreach ($child in $children) {
        try {
            $r = $child.Current.BoundingRectangle
            if ($r.Width -le 0 -or $r.Height -le 0) { continue }
            if ($Point.X -ge $r.Left -and $Point.X -le $r.Right -and $Point.Y -ge $r.Top -and $Point.Y -le $r.Bottom) {
                $candidates += @{ Element = $child; Area = ($r.Width * $r.Height) }
            }
        } catch { }
    }
    foreach ($cand in ($candidates | Sort-Object -Property Area)) {
        $hit = Find-TextProvider -Element $cand.Element -Point $Point -Depth ($Depth - 1)
        if ($null -ne $hit) { return $hit }
    }
    return $null
}

function Get-UiaLineAtPoint {
    <#  Returns the line of text under the point, the caret offset inside that
        line, and the live range so a sentence can be measured later. #>
    param([int]$X, [int]$Y)

    $pt = New-Object System.Windows.Point($X, $Y)
    $hit = Find-TextProvider -Element ([System.Windows.Automation.AutomationElement]::FromPoint($pt)) -Point $pt -Depth 6
    if ($null -eq $hit) { return $null }

    $caret = $null
    try { $caret = $hit.Pattern.RangeFromPoint($pt) } catch { $caret = $null }
    if ($null -eq $caret) { return $null }

    $line = $caret.Clone()
    try { $line.ExpandToEnclosingUnit($script:UiaLine) } catch { return $null }

    $text = ''
    try { $text = $line.GetText(-1) } catch { $text = '' }
    # providers hand back U+FFFC for embedded objects / images: no readable text
    $visible = ($text -replace [string][char]0xFFFC, '').Trim()
    if ($visible.Length -eq 0) { return $null }

    $offset = 0
    try { $offset = [int]$caret.CompareEndpoints($script:UiaStart, $line, $script:UiaStart) } catch { $offset = 0 }
    $offset = [Math]::Max(0, [Math]::Min($offset, $text.Length))

    $rects = @()
    try { $rects = ConvertTo-RectList -Doubles $line.GetBoundingRectangles() } catch { $rects = @() }

    $procId = 0
    try { $procId = $hit.Element.Current.ProcessId } catch { $procId = 0 }

    return @{
        Source    = 'uia'
        Text      = $text
        Offset    = $offset
        Rects     = $rects
        Range     = $line
        Pattern   = $hit.Pattern
        ProcessId = $procId
        App       = (Get-ProcessNameSafe -ProcessId $procId)
    }
}

function Get-RangeRects {
    <#  Bounding boxes of [Start, Start+Length) characters of a line range:
        this is what gets painted as the yellow highlight. #>
    param($LineRange, [int]$Start, [int]$Length)

    if ($null -eq $LineRange -or $Length -le 0) { return , @() }
    try {
        $sub = $LineRange.Clone()
        $sub.MoveEndpointByRange($script:UiaStart, $LineRange, $script:UiaStart)
        $sub.MoveEndpointByRange($script:UiaEnd, $LineRange, $script:UiaStart)
        if ($Start -gt 0) {
            [void]$sub.MoveEndpointByUnit($script:UiaStart, $script:UiaChar, $Start)
            [void]$sub.MoveEndpointByUnit($script:UiaEnd, $script:UiaChar, $Start)
        }
        [void]$sub.MoveEndpointByUnit($script:UiaEnd, $script:UiaChar, $Length)
        return (ConvertTo-RectList -Doubles $sub.GetBoundingRectangles())
    } catch {
        return , @()
    }
}

function Get-HighlightGeometry {
    <#  Where to paint a found sentence. Not every provider gives text geometry
        (WPF's TextBox returns none at all), so fall back to OCR word boxes around
        the foot: the highlight is then approximate but still lands on the words. #>
    param($Hit, [int]$Start, [int]$Length, [int]$FootX, [int]$FootY)

    if ($null -eq $Hit) { return @{ Rects = @(); Source = 'none' } }

    if ($null -ne $Hit.Range -and $Length -gt 0) {
        $sub = @(Get-RangeRects -LineRange $Hit.Range -Start $Start -Length $Length)
        if ($sub.Count -gt 0) { return @{ Rects = $sub; Source = 'uia' } }
    }

    $line = @($Hit.Rects)
    if ($line.Count -gt 0) { return @{ Rects = $line; Source = 'uia-line' } }

    $ocr = Get-OcrLineAtPoint -X $FootX -Y $FootY
    if ($null -ne $ocr) {
        $boxes = @($ocr.Rects)
        if ($boxes.Count -gt 0) { return @{ Rects = $boxes; Source = 'ocr' } }
    }
    return @{ Rects = @(); Source = 'none' }
}

# ---------------------------------------------------------------- Windows OCR

$script:WinRtReady = $false
$script:OcrEngine = $null
$script:AsTaskGeneric = $null

function Initialize-WinRt {
    if ($script:WinRtReady) { return $true }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            })[0]
        if ($null -eq $script:AsTaskGeneric) { return $false }
        $script:WinRtReady = $true
        return $true
    } catch {
        return $false
    }
}

function Await-WinRt {
    param($Operation, [Type]$ResultType)
    $asTask = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task = $asTask.Invoke($null, @($Operation))
    if (-not $task.Wait(15000)) { throw 'WinRT operation timed out' }
    return $task.Result
}

function Get-OcrEngine {
    if (-not (Initialize-WinRt)) { return $null }
    if ($null -ne $script:OcrEngine) { return $script:OcrEngine }
    try {
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -ne $engine) { $script:OcrEngine = $engine }
        return $engine
    } catch {
        return $null
    }
}

function Get-OcrLanguages {
    try {
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        return @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
    } catch {
        return @()
    }
}

function Get-OcrLinesFromBitmap {
    <#  OCR a Bitmap. Returns @{ Lines = @(@{ Text; Rects }) } with rects in bitmap
        pixel coordinates. #>
    param([System.Drawing.Bitmap]$Bitmap)

    if ($null -eq $Bitmap) { return $null }
    $engine = Get-OcrEngine
    if ($null -eq $engine) { return $null }

    $stream = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $stream.Position = 0
        $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($stream)
        $decoderType = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
        $decoder = Await-WinRt ($decoderType::CreateAsync($ras)) $decoderType
        $softType = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
        $soft = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) $softType
        $resultType = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
        $result = Await-WinRt ($engine.RecognizeAsync($soft)) $resultType

        $lines = @()
        foreach ($ln in $result.Lines) {
            $rects = @()
            foreach ($word in $ln.Words) {
                $r = $word.BoundingRect
                if ($r.Width -le 0 -or $r.Height -le 0) { continue }
                $rects += @{
                    X = [int][Math]::Round($r.X); Y = [int][Math]::Round($r.Y)
                    W = [int][Math]::Round($r.Width); H = [int][Math]::Round($r.Height)
                }
            }
            $words = @()
            foreach ($word in $ln.Words) {
                $r = $word.BoundingRect
                if ($r.Width -le 0 -or $r.Height -le 0) { continue }
                $words += @{
                    Text = [string]$word.Text
                    X = [int][Math]::Round($r.X); Y = [int][Math]::Round($r.Y)
                    W = [int][Math]::Round($r.Width); H = [int][Math]::Round($r.Height)
                }
            }
            $lines += @{ Text = [string]$ln.Text; Rects = $rects; Words = $words }
        }
        return @{ Lines = $lines }
    } catch {
        return $null
    } finally {
        $stream.Dispose()
    }
}

function Get-ScreenBitmap {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size($W, $H)))
    } catch {
        $g.Dispose(); $bmp.Dispose()
        return $null
    }
    $g.Dispose()
    return $bmp
}

function Resize-Bitmap {
    <#  Upscaling before OCR is the single biggest accuracy win on small UI text:
        at 1x the same panel reads "涨嘔突踬", at 3x it reads "涨速突破". #>
    param([System.Drawing.Bitmap]$Source, [int]$Factor = 3)
    if ($Factor -le 1) { return $Source }
    $w = $Source.Width * $Factor
    $h = $Source.Height * $Factor
    $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($Source, 0, 0, $w, $h)
    } finally {
        $g.Dispose()
    }
    return $dst
}

function Get-WordsFromRegion {
    <#  OCR a fixed screen rectangle and return word rects in SCREEN coordinates.
        This is what watch mode uses; UI Automation is useless for panels drawn by
        the app itself. #>
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Scale = 3)

    $words = @()
    if ($W -lt 20 -or $H -lt 12) { return , $words }
    $bmp = Get-ScreenBitmap -X $X -Y $Y -W $W -H $H
    if ($null -eq $bmp) { return , $words }
    $img = $bmp
    try {
        if ($Scale -gt 1) { $img = Resize-Bitmap -Source $bmp -Factor $Scale }
        $ocr = Get-OcrLinesFromBitmap -Bitmap $img
        if ($null -ne $ocr) {
            foreach ($line in $ocr.Lines) {
                foreach ($word in @($line.Words)) {
                    if ([string]::IsNullOrWhiteSpace([string]$word.Text)) { continue }
                    $words += @{
                        Text = [string]$word.Text
                        X = $X + [int][Math]::Round($word.X / $Scale)
                        Y = $Y + [int][Math]::Round($word.Y / $Scale)
                        W = [int][Math]::Max(1, [Math]::Round($word.W / $Scale))
                        H = [int][Math]::Max(1, [Math]::Round($word.H / $Scale))
                    }
                }
            }
        }
    } catch {
        $words = @()
    } finally {
        if ($img -ne $bmp) { $img.Dispose() }
        $bmp.Dispose()
    }
    return , $words
}
function Get-OcrLineAtPoint {
    <#  Crop around the point, OCR it, return the line that covers the point.
        Rectangles come back in screen coordinates. #>
    param([int]$X, [int]$Y, [int]$Width = 900, [int]$Height = 180)

    $screen = Get-VirtualScreenRect
    $left = [Math]::Max($screen.X, $X - [int]($Width / 2))
    $top = [Math]::Max($screen.Y, $Y - [int]($Height / 2))
    $w = [Math]::Min($Width, ($screen.X + $screen.W) - $left)
    $h = [Math]::Min($Height, ($screen.Y + $screen.H) - $top)
    if ($w -lt 20 -or $h -lt 12) { return $null }

    $bmp = Get-ScreenBitmap -X $left -Y $top -W $w -H $h
    if ($null -eq $bmp) { return $null }
    try {
        $ocr = Get-OcrLinesFromBitmap -Bitmap $bmp
    } finally {
        $bmp.Dispose()
    }
    if ($null -eq $ocr -or $ocr.Lines.Count -eq 0) { return $null }

    $localX = $X - $left
    $localY = $Y - $top
    $best = $null
    $bestDist = [double]::MaxValue
    foreach ($line in $ocr.Lines) {
        if ($line.Rects.Count -eq 0) { continue }
        $bounds = Get-RectBounds -Rects $line.Rects
        if ($null -eq $bounds) { continue }
        $x0 = $bounds.X0; $x1 = $bounds.X1; $y0 = $bounds.Y0; $y1 = $bounds.Y1
        $dy = 0.0
        if ($localY -lt $y0) { $dy = $y0 - $localY } elseif ($localY -gt $y1) { $dy = $localY - $y1 }
        $dx = 0.0
        if ($localX -lt $x0) { $dx = $x0 - $localX } elseif ($localX -gt $x1) { $dx = $localX - $x1 }
        $d = ($dy * 4) + $dx
        if ($d -lt $bestDist) {
            $bestDist = $d
            $best = @{ Line = $line; X0 = $x0; X1 = $x1 }
        }
    }
    if ($null -eq $best) { return $null }

    $screenRects = @()
    foreach ($r in $best.Line.Rects) {
        $screenRects += @{ X = $r.X + $left; Y = $r.Y + $top; W = $r.W; H = $r.H }
    }
    # ponytail: no caret API in an OCR image, so the offset is estimated from x
    $frac = 0.0
    if ($best.X1 -gt $best.X0) { $frac = [Math]::Max(0.0, [Math]::Min(1.0, ($localX - $best.X0) / ($best.X1 - $best.X0))) }
    $text = [string]$best.Line.Text
    $offset = [int][Math]::Round($frac * $text.Length)

    # Windows OCR splits CJK into one "word" per character; glue it back and keep
    # the caret offset pointing at the same character.
    if (Get-Command Remove-CjkSpacing -ErrorAction SilentlyContinue) {
        $head = $text.Substring(0, [Math]::Max(0, [Math]::Min($offset, $text.Length)))
        $text = Remove-CjkSpacing -Text $text
        $offset = [Math]::Min((Remove-CjkSpacing -Text $head).Length, $text.Length)
    }

    return @{
        Source    = 'ocr'
        Text      = $text
        Offset    = $offset
        Rects     = $screenRects
        Range     = $null
        Pattern   = $null
        ProcessId = 0
        App       = 'screen'
    }
}

function Get-ScreenPointText {
    <#  The one entry point the crawler uses: UI Automation first, OCR after. #>
    param([int]$X, [int]$Y, [bool]$AllowOcr = $true)

    $hit = $null
    try { $hit = Get-UiaLineAtPoint -X $X -Y $Y } catch { $hit = $null }
    if ($null -ne $hit) { return $hit }
    if (-not $AllowOcr) { return $null }
    try { return (Get-OcrLineAtPoint -X $X -Y $Y) } catch { return $null }
}
