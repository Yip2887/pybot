# TL;DR Overlay - Core.Tests.ps1
# Plain asserts, no framework:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/Core.Tests.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Core.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Watch.ps1')   # pure geometry helper

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

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    Assert-True $Name ($Expected -eq $Actual) ("expected '" + $Expected + "' got '" + $Actual + "'")
}

Write-Host "`n1. sentence splitting keeps source offsets"
$text = 'OpenAI shipped a new model. It costs $20 per month, up 40%. 研究人员发现该系统的速度提高了 3 倍！Trailing fragment without a stop'
$parts = @(Split-Sentences -Text $text)
Assert-True 'found several sentences' ($parts.Count -ge 4) ("count=" + $parts.Count)
$roundTrip = $true
foreach ($p in $parts) {
    if ($text.Substring($p.Start, $p.End - $p.Start) -ne $p.Text) { $roundTrip = $false }
    if ($p.Text.Trim() -ne $p.Text) { $roundTrip = $false }
}
Assert-True 'offsets round-trip and text is trimmed' $roundTrip
Assert-True 'dollar sentence kept intact' ([bool](@($parts | Where-Object { $_.Text -like '*$20*' }).Count))
Assert-True 'CJK sentence kept intact' ([bool](@($parts | Where-Object { $_.Text -like '*提高*' }).Count))
Assert-True 'empty input returns nothing' (@(Split-Sentences -Text '').Count -eq 0)

Write-Host "`n2. scoring rewards numbers, money and key words"
$plain = Get-SentenceScore -Text 'The team met on Tuesday to talk about things and stuff for a while.'
$rich = Get-SentenceScore -Text 'The company announced a record $2 billion increase, up 40%.'
Assert-True 'money + keywords outrank plain prose' ($rich -gt $plain) ("rich=$rich plain=$plain")
Assert-True 'very short sentences are penalised' ((Get-SentenceScore -Text 'Short.') -lt 0)
$long = Get-SentenceScore -Text (('x' * 300) + ' 5')
$mid = Get-SentenceScore -Text 'A 5 number inside a reasonably sized sentence that is long enough to pass.'
Assert-True 'over-long sentences are penalised' ($long -lt $mid) ("long=$long mid=$mid")

Write-Host "`n3. key sentence selection: quota, spread, order"
$scores = New-Object System.Collections.ArrayList
$paras = New-Object System.Collections.ArrayList
for ($p = 0; $p -lt 10; $p++) {
    for ($i = 0; $i -lt 4; $i++) {
        [void]$scores.Add([double]($p * 4 + $i))
        [void]$paras.Add($p)
    }
}
$picked = @(Select-KeySentences -Scores $scores.ToArray() -Paras $paras.ToArray() -Ratio 0.25 -Min 5 -Max 80)
Assert-Equal 'quota = round(40 * 0.25)' 10 $picked.Count
$sorted = @($picked | Sort-Object)
Assert-True 'returned in document order' (($picked -join ',') -eq ($sorted -join ',')) ($picked -join ',')
$distinctParas = @($picked | ForEach-Object { $paras[$_] } | Sort-Object -Unique).Count
Assert-Equal 'every paragraph gets a representative' 10 $distinctParas

$few = @(Select-KeySentences -Scores @(1, 2) -Paras @(0, 0) -Min 5 -Max 80)
Assert-Equal 'never more than available' 2 $few.Count

$manyScores = @(0..399 | ForEach-Object { [double]$_ })
$manyParas = @(0..399)
Assert-Equal 'capped at 80' 80 (@(Select-KeySentences -Scores $manyScores -Paras $manyParas).Count)
Assert-Equal 'empty input' 0 (@(Select-KeySentences -Scores @() -Paras @()).Count)

Write-Host "`n4. fallback summary: filler stripped, numbers kept, word capped"
$s = Get-FallbackSummary -Text 'However, according to the report, the company earned $4.2 million in the first quarter of the year.' -MaxWords 9
Assert-True 'leading filler removed' (-not ($s -match '^(however|according)')) $s
Assert-True 'numbers preserved' ([bool]($s -match '\$4\.2')) $s
$words = @(($s -replace '…$', '').Trim() -split '\s+')
Assert-True 'at most 9 words' ($words.Count -le 9) ("words=" + $words.Count + " -> " + $s)
Assert-Equal 'short sentence passes through' 'Revenue rose 12%' (Get-FallbackSummary -Text 'Revenue rose 12%.' -MaxWords 9)
$cjkSummary = Limit-Words -Text '研究人员发现新系统的运行速度比上一代提高了三倍以上，这是一个非常重要的结论。' -MaxWords 9
Assert-True 'CJK summary is actually short' ($cjkSummary.Length -le 24) ("len=" + $cjkSummary.Length + " -> " + $cjkSummary)
Assert-Equal 'blank input yields blank' '' (Get-FallbackSummary -Text '   ' -MaxWords 9)

Write-Host "`n5. word under the caret"
$w = Get-WordAt -Data 'The quick brown fox' -Offset 5
Assert-Equal 'word at offset 5' 'quick' $w.Word
Assert-Equal 'word at the tail of a word' 'quick' (Get-WordAt -Data 'The quick brown fox' -Offset 9).Word
Assert-Equal 'word after the space' 'brown' (Get-WordAt -Data 'The quick brown fox' -Offset 11).Word
Assert-Equal 'first word' 'The' (Get-WordAt -Data 'The quick brown fox' -Offset 0).Word
$uni = '每只蜘蛛爬过 3 个段落'
Assert-Equal 'CJK digit' '3' (Get-WordAt -Data $uni -Offset 7).Word
Assert-Equal 'CJK one character at a time' '只' (Get-WordAt -Data $uni -Offset 2).Word
Assert-Equal 'cursor in the gap picks the word before' '过' (Get-WordAt -Data $uni -Offset 6).Word
Assert-True 'CJK detection' (Test-CjkWord -Word '蜘')
Assert-True 'latin is not CJK' (-not (Test-CjkWord -Word 'quick'))
Assert-True 'blank text yields null' ($null -eq (Get-WordAt -Data '   ' -Offset 1))

Write-Host "`n6b. OCR spacing normalisation"
Assert-Equal 'CJK spaced out by OCR is glued back' '固态电池概念' (Remove-CjkSpacing -Text '固 态 电 池 概 念')
Assert-Equal 'latin words keep their spaces' 'CRO concept PCB' (Remove-CjkSpacing -Text 'CRO concept PCB')
Assert-Equal 'numbers keep their spaces' '600352 12.5' (Remove-CjkSpacing -Text '600352 12.5')
Assert-Equal 'mixed line keeps the latin/CJK boundary' 'XD 海螺水泥 CRO 12.5' (Remove-CjkSpacing -Text 'XD 海 螺 水 泥 CRO 12.5')
Assert-Equal 'blank input' '' (Remove-CjkSpacing -Text '')
Assert-Equal 'no spaces is unchanged' '净资产收益率' (Remove-CjkSpacing -Text '净资产收益率')
Write-Host "`n5b. watch mode: rows, junk filter, new-alert detection"
$words = @(
    @{ X = 168; Y = 479; W = 60; H = 11; Text = '打开跌停板' },
    @{ X = 102; Y = 479; W = 48; H = 11; Text = '强达电路' },
    @{ X = 256; Y = 479; W = 40; H = 11; Text = '5.21%' },
    @{ X = 102; Y = 496; W = 48; H = 11; Text = '华茂股份' },
    @{ X = 168; Y = 496; W = 60; H = 11; Text = '涨速突破' },
    @{ X = 102; Y = 513; W = 48; H = 11; Text = '世联行' }
)
$rows = @(Group-WordsIntoRows -Words $words)
Assert-Equal 'words on the same line become one row' 3 $rows.Count
Assert-Equal 'row text is ordered left to right' '强达电路 打开跌停板 5.21%' $rows[0].Text
Assert-Equal 'row carries the bounding box' 102 $rows[0].X
Assert-True 'row box spans the whole line' ($rows[0].W -ge 190) ("w=" + $rows[0].W)

Assert-True 'a real alert row passes the filter' (Test-AlertRow -Text '华茂股份 涨速突破')
Assert-True 'a stock code row passes the filter' (Test-AlertRow -Text '600663 打开跌停板')
Assert-True 'pure numbers are dropped' (-not (Test-AlertRow -Text '5 . 21 %'))
Assert-True 'too-short rows are dropped' (-not (Test-AlertRow -Text '5%'))
Assert-True 'blank rows are dropped' (-not (Test-AlertRow -Text '   '))

$frame1 = @('强达电路 打开跌停板 5.21%', '华茂股份 涨速突破', '世联行 急速拉升')
$frame2 = @('华茂股份 涨速突破', '世联行 急速拉升', '迅安科技 猛烈打压')
$new = @(Get-NewAlert -Current $frame2 -Seen $frame1)
Assert-Equal 'a scrolled panel reports only the new line' 1 $new.Count
Assert-Equal 'and it is the right one' '迅安科技 猛烈打压' $new[0]
Assert-Equal 'a repeated frame reports nothing' 0 (@(Get-NewAlert -Current $frame1 -Seen $frame1)).Count
Assert-Equal 'duplicates inside one frame collapse' 1 (@(Get-NewAlert -Current @('世联行 急速拉升', '世联行 急速拉升') -Seen @())).Count
Assert-Equal 'normalisation ignores spacing and punctuation' '华茂股份涨速突破' (Get-NormalizedAlertKey -Text '华茂股份 涨速突破。')
Assert-Equal 'alert type is recognised in a glued row' '打开跌停板' (Find-AlertType -Text '华茂股份打开跌停板 4 17')
Assert-Equal 'alert type for a rise' '涨速突破' (Find-AlertType -Text '誉衡药业涨速突破 5 21 %')
Assert-Equal 'unknown rows have no type' '' (Find-AlertType -Text '600663 陆家嘴 12.5')
Assert-Equal 'a space is inserted before the type' '华茂股份 打开跌停板 4 17' (Format-AlertRow -Text '华茂股份打开跌停板 4 17')
Assert-Equal 'rows without a type are untouched' '600663陆家嘴' (Format-AlertRow -Text '600663陆家嘴')
Assert-True 'OCR jitter on the same row counts as the same alert' (Test-SimilarText -A '华茂股份 打开跌停板 4 17' -B '华茂份 打开跌停板')
Assert-True 'mild jitter matches' (Test-SimilarText -A '世联行跌幅跌破5.92%' -B '世联行跌幅跌破5 92 ％')
Assert-True 'heavy jitter (3 wrong chars) is a known miss, not a wrong match' (-not (Test-SimilarText -A '世联行跌幅跌破5.92%' -B '世朕行跌幅跌破巧 92 ％'))
Assert-True 'two different stocks are not the same row' (-not (Test-SimilarText -A '强达电路跌破5.32%' -B '世联行跌幅跌破5.92%'))
Assert-True 'same alert type on another stock stays distinct' (-not (Test-SimilarText -A '迅安科技急速拉升' -B '科马材料急速拉升'))
Assert-True 'short rows never fuzzy-match' (-not (Test-SimilarText -A '5 21 %' -B '5 92 %'))

$recent = @('华茂股份 打开跌停板 4 17', '世联行跌幅跌破5.92%')
$frame = @('华茂份 打开跌停板', '世朕行跌幅跌破巧 92 ％', '迅安科技 急速拉升')
$fresh = @(Get-NewAlert -Current $frame -Seen @() -Recent $recent)
Assert-True 'fuzzy history suppresses the jittered repeat' ($fresh -notcontains '华茂份 打开跌停板')
Assert-True 'the genuinely new row is reported' ($fresh -contains '迅安科技 急速拉升')
Write-Host "`n5c. auto-locating the alert panel"
# realistic input: OCR hands CJK back one character per word
$panel = @()
$types = @('急速拉升', '打开跌停板', '涨速突破', '猛烈打压', '急速拉升', '打开跌停板')
$names = @('华茂股份', '世联行', '誉衡药业', '驰诚股份', '迅安科技', '科马材料')
for ($i = 0; $i -lt $types.Count; $i++) {
    $y = 462 + ($i * 17)
    $x = 102
    foreach ($ch in $names[$i].ToCharArray()) { $panel += @{ X = $x; Y = $y; W = 12; H = 11; Text = [string]$ch }; $x += 12 }
    $x = 168
    foreach ($ch in $types[$i].ToCharArray()) { $panel += @{ X = $x; Y = $y; W = 12; H = 11; Text = [string]$ch }; $x += 12 }
    $panel += @{ X = 256; Y = $y; W = 40; H = 11; Text = '5.21%' }
}
$bounds = @{ X = 0; Y = 0; W = 1920; H = 1080 }
$panelRows = @(Group-WordsIntoRows -Words $panel)
Assert-Equal 'rows are rebuilt from per-character OCR words' 6 $panelRows.Count
Assert-Equal 'a rebuilt row keeps the value column apart' '华茂股份急速拉升 5.21%' $panelRows[0].Text
Assert-Equal 'and the alert type adds the missing space' '华茂股份 急速拉升 5.21%' (Format-AlertRow -Text $panelRows[0].Text)
$found = Select-AlertColumn -Words $panel -Bounds $bounds
Assert-True 'the alert panel is located' ($null -ne $found)
Assert-True 'region starts left of the name column (padded)' ($found.X -le 102) ("x=" + $found.X)
Assert-True 'region covers the type column' (($found.X + $found.W) -ge 228) ("right=" + ($found.X + $found.W))
Assert-True 'region covers the whole stack' ($found.Y -le 462 -and ($found.Y + $found.H) -ge 547) ("y=" + $found.Y + " h=" + $found.H)
Assert-True 'region stays inside the window' (($found.X + $found.W) -le 1920 -and ($found.Y + $found.H) -le 1080)

$tooFew = @(
    @{ Text = '华茂股份 急速拉升'; X = 100; Y = 100; W = 200; H = 11 },
    @{ Text = '世联行 涨速突破'; X = 100; Y = 220; W = 200; H = 11 }
)
Assert-True 'two rows are not a panel' ($null -eq (Select-AlertColumn -Words $tooFew -Bounds $bounds))

$oneLine = @(
    @{ Text = '华茂股份 急速拉升 涨速突破 猛烈打压'; X = 100; Y = 300; W = 400; H = 11 }
)
Assert-True 'a single row is not a stacked panel' ($null -eq (Select-AlertColumn -Words $oneLine -Bounds $bounds))
Write-Host "`n6. leg inverse kinematics"
$right = Solve-IK -HipX 10 -HipY 0 -FootX 60 -FootY 40 -L1 30 -L2 34 -OutX 0 -OutY 0
$left = Solve-IK -HipX 10 -HipY 0 -FootX 60 -FootY -40 -L1 30 -L2 34 -OutX 0 -OutY 0
Assert-True 'right leg knee bows outward' ($right.KneeY -gt 0) ("kneeY=" + $right.KneeY)
Assert-True 'left leg knee bows outward' ($left.KneeY -lt 0) ("kneeY=" + $left.KneeY)
$far = Solve-IK -HipX 0 -HipY 0 -FootX 1000 -FootY 0 -L1 30 -L2 34 -OutX 0 -OutY 0
$reach = [Math]::Sqrt($far.FootX * $far.FootX + $far.FootY * $far.FootY)
Assert-True 'foot clamped to bone reach' ($reach -le 64.001 -and $reach -gt 60) ("reach=" + $reach)
$near = Solve-IK -HipX 0 -HipY 0 -FootX 50 -FootY 0 -L1 30 -L2 34 -OutX 0 -OutY 0
$femur = [Math]::Sqrt($near.KneeX * $near.KneeX + $near.KneeY * $near.KneeY)
$tibia = [Math]::Sqrt([Math]::Pow(50 - $near.KneeX, 2) + [Math]::Pow($near.KneeY, 2))
Assert-True 'knee sits at femur length' ([Math]::Abs($femur - 30) -lt 0.01) ("femur=" + $femur)
Assert-True 'tibia still reaches the foot' ([Math]::Abs($tibia - 34) -lt 0.01) ("tibia=" + $tibia)

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host ("CORE TESTS FAILED: {0} of {1} checks" -f $script:Failures, $script:Checks)
    exit 1
}
Write-Host ("Core.ps1 self-check: all {0} assertions passed" -f $script:Checks)
exit 0
