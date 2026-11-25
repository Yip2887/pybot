# TL;DR Overlay - Core.ps1
# Pure logic, no Win32 / WPF. Safe to unit test on its own:
#   powershell -NoProfile -File test/Core.Tests.ps1
#
# Ported from the Chrome extension's core.js so the desktop version scores and
# summarises identically.

Set-StrictMode -Version Latest

$script:CjkChar = '[\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]'
$script:CjkOnly = '^[\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]+$'
$script:WordPattern = '(?:[\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF])|[\p{L}\p{N}][\p{L}\p{N}''\u2019\-]*'
$script:SentencePattern = @'
[^.!?…。！？\r\n]+[.!?…。！？]+["'”’)\]]*|\S[^.!?…。！？\r\n]*$
'@
$script:CjkTerms = @('第一', '记录', '启动', '宣布', '新的', '唯一', '最大的', '最快的', '警告', '提高', '削减')
$script:EnTerms = @('first', 'record', 'launch', 'announce', 'new', 'only', 'largest', 'fastest', 'warn', 'warning', 'increase', 'cut')
$script:FillerPattern = @'
^(?:and|but|however|also|so|then|yet|moreover|furthermore|in addition|additionally|meanwhile|therefore|thus|hence|according to|as a result|in fact|of course|well|now)\b[\s,:;—–-]*
'@
$script:TrimLeadPattern = '^[\s"''“”‘’\(\[\-–—]+'

function Split-Sentences {
    <#  Split a text blob into sentences, with offsets into the original string
        so callers can map them back onto a text node / UIA range. #>
    [CmdletBinding()]
    param([string]$Text)

    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($Text)) { return @() }

    foreach ($m in [regex]::Matches($Text, $script:SentencePattern)) {
        if ($m.Value.Length -eq 0) { continue }
        $raw = $m.Value
        $start = $m.Index
        $lead = $raw.Length - ($raw -replace '^\s+', '').Length
        $start += $lead
        $raw = $raw.Substring($lead)
        $body = $raw -replace '\s+$', ''
        if ($body.Length -eq 0) { continue }
        # drop punctuation-only fragments
        $letters = [regex]::Matches($body, '[\p{L}\p{N}]').Count
        if ($letters -lt 2) { continue }
        [void]$out.Add(@{ Text = $body; Start = $start; End = $start + $body.Length })
    }
    return $out.ToArray()
}

function Get-SentenceScore {
    <#  Importance score. Numbers/money/keywords up, too short or too long down. #>
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0.0 }
    $score = 0.0
    if ($Text -match '\d') { $score += 2 }
    if ($Text -match '%') { $score += 2 }
    if ($Text -match '\$') { $score += 2 }
    if ($Text -match '€') { $score += 2 }
    if ($Text -match '百万|million') { $score += 2 }
    if ($Text -match '十亿|billion') { $score += 2 }

    foreach ($term in $script:CjkTerms) {
        $at = 0
        while (($at = $Text.IndexOf($term, $at, [System.StringComparison]::Ordinal)) -ge 0) {
            $score += 1.5
            $at += $term.Length
        }
    }
    foreach ($term in $script:EnTerms) {
        $hits = [regex]::Matches($Text, '\b' + $term + '\b', 'IgnoreCase').Count
        $score += $hits * 1.5
    }

    $caps = [regex]::Matches($Text, '[A-Z]').Count
    $score += [Math]::Min(2.0, $caps * 0.3)

    $len = $Text.Trim().Length
    if ($len -lt 40) { $score -= 2 }
    if ($len -gt 260) { $score -= 2 }
    return $score
}

function Select-KeySentences {
    <#  Which sentences are "key": rank by score, but keep one representative per
        paragraph first so the picks stay spread over the whole document.
        Returns indices (into the parallel arrays) in document order. #>
    [CmdletBinding()]
    param(
        [double[]]$Scores,
        [int[]]$Paras,
        [double]$Ratio = 0.25,
        [int]$Min = 5,
        [int]$Max = 80
    )

    $n = $Scores.Count
    if ($n -eq 0) { return @() }
    $quota = [Math]::Max($Min, [Math]::Min($Max, [int][Math]::Round($n * $Ratio)))
    $quota = [Math]::Min($quota, $n)

    $order = 0..($n - 1) | Sort-Object -Property @{ Expression = { $Scores[$_] } ; Descending = $true }, @{ Expression = { $_ } ; Descending = $false }

    $bestByPara = @{}
    foreach ($i in $order) {
        $p = $Paras[$i]
        if (-not $bestByPara.ContainsKey($p)) { $bestByPara[$p] = $i }
    }
    $reps = @($bestByPara.Values) | Sort-Object -Property @{ Expression = { $Scores[$_] } ; Descending = $true }, @{ Expression = { $_ } ; Descending = $false }

    $chosen = New-Object System.Collections.Generic.HashSet[int]
    foreach ($i in $reps) {
        if ($chosen.Count -ge $quota) { break }
        if ($Scores[$i] -gt 0) { [void]$chosen.Add($i) }
    }
    foreach ($i in $order) {
        if ($chosen.Count -ge $quota) { break }
        [void]$chosen.Add($i)
    }
    return @($chosen | Sort-Object)
}

function Limit-Words {
    <#  Hard word cap, used for every TL;DR fragment (default 9 words). #>
    [CmdletBinding()]
    param([string]$Text, [int]$MaxWords = 9)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = ($Text -replace $script:TrimLeadPattern, '') -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -eq 0) { return '' }

    $cjk = [regex]::Matches($t, $script:CjkChar).Count
    if ($cjk -gt ($t.Length * 0.4)) {
        # ponytail: no segmenter on this stack, so a CJK "word" is approximated as
        # two characters; swap in a dictionary if fragment quality matters.
        if ($t.Length -le ($MaxWords * 2)) { return ($t -replace '[.!?。！？…]+$', '') }
        return $t.Substring(0, $MaxWords * 2) + '…'
    }

    $parts = @($t -split '\s+')
    if ($parts.Count -le $MaxWords) { return ($t -replace '[.!?。！？…]+$', '') }
    return (($parts[0..($MaxWords - 1)] -join ' ') + '…')
}

function Get-FallbackSummary {
    <#  Offline summary: strip filler words, then truncate at a word boundary. #>
    [CmdletBinding()]
    param([string]$Text, [int]$MaxWords = 9)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text.Trim()
    $guard = 0
    do {
        $before = $t
        $t = ($t -replace $script:FillerPattern, '')
        $guard++
    } while ($t -ne $before -and $t.Length -gt 0 -and $guard -lt 12)
    return (Limit-Words -Text $t -MaxWords $MaxWords)
}

function Remove-CjkSpacing {
    <#  Windows OCR returns CJK one "word" per character, so a screen line comes
        back as "固 态 电 池 概 念". Glue CJK back together (and only CJK: spaces
        between latin words or between numbers carry meaning). #>
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ($Text -replace '(?<=[\u3400-\u9FFF\uF900-\uFAFF\u3000-\u303F\uFF00-\uFFEF])\s+(?=[\u3400-\u9FFF\uF900-\uFAFF\u3000-\u303F\uFF00-\uFFEF])', '')
}

$script:AlertKeywords = @(
    '跌停', '涨停', '拉升', '打压', '突破', '跳水', '买入', '卖出', '异动',
    '高开', '低开', '放量', '巨量', '新高', '新低', '连板', '首板', '净流',
    '反弹', '回落', '加速', '封板', '开板', '竞价', '尾盘', '资金',
    # OCR often cuts the type short ("打开跌停板" -> "跌破"), so keep the tails
    '跌破', '涨突', '跌板', '停板', '大减', '大增', '急拉', '急跌', '打板',
    '净买', '净卖', '流入', '流出', '冲高', '走低'
)
$script:AlertTypes = @(
    '打开跌停板', '封涨停板', '打开涨停板', '封跌停板', '涨停板', '跌停板',
    '急速拉升', '猛烈打压', '涨速突破', '高台跳水', '火箭发射', '加速下跌',
    '大笔买入', '大笔卖出', '主力买入', '主力卖出', '机构买入', '机构卖出',
    '竞价异动', '尾盘拉升', '尾盘跳水', '资金流入', '资金流出',
    '连续上涨', '连续下跌', '创新高', '创新低', '大幅高开', '大幅低开',
    '巨量成交', '放量突破', '跌破支撑', '突破压力', '均线突破', '量价齐升',
    '快速反弹', '快速回落', '异常波动', '打开涨停', '打开跌停'
)

function Find-AlertType {
    <#  Which 短线精灵 alert this row is. Used to make the feed readable (insert a
        space before it) and to filter/beep on the ones that matter. #>
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = Remove-CjkSpacing -Text $Text
    foreach ($type in $script:AlertTypes) {
        if ($t.Contains($type)) { return $type }
    }
    # OCR drops the odd stroke ("涨速突破" -> "涨突破"), so fall back to a keyword
    foreach ($kw in $script:AlertKeywords) {
        if ($t.Contains($kw)) { return $kw }
    }
    return ''
}

function Format-AlertRow {
    <#  "华茂股份打开跌停板 4 17" -> "华茂股份 打开跌停板 4 17" #>
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = (Remove-CjkSpacing -Text $Text).Trim()
    $type = Find-AlertType -Text $t
    if ($type.Length -eq 0) { return $t }
    $at = $t.IndexOf($type, [System.StringComparison]::Ordinal)
    if ($at -le 0) { return $t }
    return ($t.Substring(0, $at).TrimEnd() + ' ' + $t.Substring($at)).Trim()
}

function Group-WordsIntoRows {
    <#  Turn OCR words into screen rows: cluster by vertical position, order by x.
        In watch mode one "alert" is one row of the watched panel. #>
    [CmdletBinding()]
    param($Words, [int]$Tolerance = 7)

    $rows = New-Object System.Collections.ArrayList
    foreach ($w in @($Words | Sort-Object { $_.Y }, { $_.X })) {
        $placed = $false
        foreach ($row in $rows) {
            if ([Math]::Abs($row.Y - $w.Y) -le $Tolerance) {
                [void]$row.Words.Add($w)
                $placed = $true
                break
            }
        }
        if (-not $placed) {
            $bucket = New-Object System.Collections.ArrayList
            [void]$bucket.Add($w)
            [void]$rows.Add(@{ Y = $w.Y; Words = $bucket })
        }
    }

    $out = New-Object System.Collections.ArrayList
    foreach ($row in ($rows | Sort-Object { $_.Y })) {
        $ordered = @($row.Words | Sort-Object { $_.X })
        # Windows OCR hands CJK back one character per word: glue those, but keep
        # the space between real words ("强达电路 打开跌停板", not "强达电路打开跌停板")
        $text = ''
        foreach ($w in $ordered) {
            $piece = ([string]$w.Text).Trim()
            if ($piece.Length -eq 0) { continue }
            if ($text.Length -gt 0) {
                $prev = $text.Substring($text.Length - 1, 1)
                $charSplit = ($piece.Length -eq 1 -and (Test-CjkWord -Word $prev) -and (Test-CjkWord -Word $piece))
                if (-not $charSplit) { $text += ' ' }
            }
            $text += $piece
        }
        $text = $text -replace '\s{2,}', ' '
        # hashtable keys are not properties: Measure-Object cannot read them
        $x0 = [int]::MaxValue; $y0 = [int]::MaxValue; $x1 = [int]::MinValue; $y1 = [int]::MinValue
        foreach ($w in $ordered) {
            if ($w.X -lt $x0) { $x0 = [int]$w.X }
            if ($w.Y -lt $y0) { $y0 = [int]$w.Y }
            if (($w.X + $w.W) -gt $x1) { $x1 = [int]($w.X + $w.W) }
            if (($w.Y + $w.H) -gt $y1) { $y1 = [int]($w.Y + $w.H) }
        }
        [void]$out.Add(@{
                Y = $y0; X = $x0; W = $x1 - $x0; H = $y1 - $y0
                Text = $text.Trim()
                Rects = @(@{ X = $x0; Y = $y0; W = $x1 - $x0; H = $y1 - $y0 })
            })
    }
    return $out.ToArray()
}

function Get-NormalizedAlertKey {
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = Remove-CjkSpacing -Text $Text
    # OCR varies punctuation and spacing between frames ("5.21%" / "5 21 ％"), so
    # the comparison key keeps letters and digits only
    $t = $t -replace '[^\p{L}\p{N}]', ''
    return $t.ToLowerInvariant()
}

function Test-AlertRow {
    <#  Worth reporting? Drops the pure number/percent junk an OCR pass over a
        data panel produces. #>
    [CmdletBinding()]
    param([string]$Text, [int]$MinChars = 4)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = $Text.Trim()
    if ($t.Length -lt $MinChars) { return $false }
    $letters = [regex]::Matches($t, '[\u3400-\u9FFF\uF900-\uFAFF\p{L}]').Count
    $digits = [regex]::Matches($t, '\d').Count
    if ($letters -lt 2 -and $digits -lt 6) { return $false }
    return $true
}

function Get-BigramSet {
    [CmdletBinding()]
    param([string]$Text)
    $t = Get-NormalizedAlertKey -Text $Text
    $set = New-Object System.Collections.Generic.HashSet[string]
    if ($t.Length -eq 0) { return $set }
    if ($t.Length -eq 1) { [void]$set.Add($t); return $set }
    for ($i = 0; $i -lt $t.Length - 1; $i++) { [void]$set.Add($t.Substring($i, 2)) }
    return $set
}

function Test-SimilarText {
    <#  OCR reads the same on-screen line slightly differently every frame
        ("华茂股份打开跌停板" / "华茂亻/打开笊板"). Exact matching would report it as
        new every time, so rows are compared by character-bigram overlap. #>
    [CmdletBinding()]
    param([string]$A, [string]$B, [double]$Threshold = 0.6)

    $ka = Get-NormalizedAlertKey -Text $A
    $kb = Get-NormalizedAlertKey -Text $B
    if ($ka.Length -eq 0 -or $kb.Length -eq 0) { return $false }
    if ($ka -eq $kb) { return $true }
    $la = $ka.Length; $lb = $kb.Length
    $short = [Math]::Min($la, $lb); $long = [Math]::Max($la, $lb)
    if ($short -lt 3 -or ($short / [double]$long) -lt 0.55) { return $false }   # cheap length gate
    $sa = Get-BigramSet -Text $ka
    $sb = Get-BigramSet -Text $kb
    $inter = 0
    foreach ($g in $sa) { if ($sb.Contains($g)) { $inter++ } }
    $shorter = [Math]::Min($sa.Count, $sb.Count)
    if ($shorter -le 0) { return $false }
    # containment, not Jaccard: OCR jitter mostly DROPS characters, so the shorter
    # reading is usually a subset of the longer one
    return (($inter / [double]$shorter) -ge $Threshold)
}

function Get-NewAlert {
    <#  Rows not present in the previous frames. -Seen is an exact-key history,
        -Recent is the last few frames matched fuzzily against OCR jitter. #>
    [CmdletBinding()]
    param([string[]]$Current, [string[]]$Seen, [string[]]$Recent)

    $known = @{}
    foreach ($s in @($Seen)) { $known[(Get-NormalizedAlertKey -Text $s)] = $true }
    $recentKeys = New-Object System.Collections.ArrayList
    foreach ($s in @($Recent)) { [void]$recentKeys.Add((Get-NormalizedAlertKey -Text $s)) }

    $out = New-Object System.Collections.ArrayList
    $inFrame = @{}
    foreach ($c in @($Current)) {
        $key = Get-NormalizedAlertKey -Text $c
        if ($key.Length -eq 0) { continue }
        if ($inFrame.ContainsKey($key)) { continue }
        $inFrame[$key] = $true
        if ($known.ContainsKey($key)) { continue }
        $dupe = $false
        foreach ($rk in $recentKeys) {
            if (Test-SimilarText -A $key -B $rk) { $dupe = $true; break }
        }
        if ($dupe) { continue }
        [void]$out.Add($c)
    }
    return $out.ToArray()
}

function Get-WordAt {
    <#  The word under a caret offset (or the word just before it).
        CJK is matched one character at a time: those scripts have no spaces. #>
    [CmdletBinding()]
    param([string]$Data, [int]$Offset)

    if ([string]::IsNullOrEmpty($Data)) { return $null }
    $last = $null
    foreach ($m in [regex]::Matches($Data, $script:WordPattern)) {
        $s = $m.Index
        $e = $m.Index + $m.Value.Length
        if ($Offset -ge $s -and $Offset -le $e) {
            return @{ Start = $s; End = $e; Word = $m.Value }
        }
        if ($e -le $Offset) { $last = @{ Start = $s; End = $e; Word = $m.Value } }
        if ($s -gt $Offset) { break }
    }
    return $last
}

function Test-CjkWord {
    [CmdletBinding()]
    param([string]$Word)
    if ([string]::IsNullOrEmpty($Word)) { return $false }
    return [bool]($Word -match $script:CjkOnly)
}

function Solve-IK {
    <#  Two-bone inverse kinematics for one leg. The knee bends away from the
        body centre (OutX, OutY), which is what makes the legs read as a spider. #>
    [CmdletBinding()]
    param(
        [double]$HipX, [double]$HipY,
        [double]$FootX, [double]$FootY,
        [double]$L1, [double]$L2,
        [double]$OutX, [double]$OutY
    )

    $dx = $FootX - $HipX
    $dy = $FootY - $HipY
    $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
    $reach = ($L1 + $L2) * 0.999
    if ($d -le 0.0001) { $d = 0.0001; $dx = 0.0001; $dy = 0 }
    if ($d -gt $reach) {
        $k = $reach / $d
        $dx *= $k; $dy *= $k; $d = $reach
    }
    $ux = $dx / $d
    $uy = $dy / $d
    $a = ($L1 * $L1 - $L2 * $L2 + $d * $d) / (2 * $d)
    $h = [Math]::Sqrt([Math]::Max(0, $L1 * $L1 - $a * $a))
    $bx = $HipX + $ux * $a
    $by = $HipY + $uy * $a
    $k1x = $bx - $uy * $h; $k1y = $by + $ux * $h
    $k2x = $bx + $uy * $h; $k2y = $by - $ux * $h
    $d1 = ($k1x - $OutX) * ($k1x - $OutX) + ($k1y - $OutY) * ($k1y - $OutY)
    $d2 = ($k2x - $OutX) * ($k2x - $OutX) + ($k2y - $OutY) * ($k2y - $OutY)
    if ($d1 -ge $d2) { $kx = $k1x; $ky = $k1y } else { $kx = $k2x; $ky = $k2y }
    return @{
        KneeX = $kx; KneeY = $ky
        FootX = $HipX + $dx; FootY = $HipY + $dy
    }
}
