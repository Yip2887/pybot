# TL;DR Overlay - TldrOverlay.ps1
# Desktop-level TL;DR Crawler: a line-art spider lives on a click-through overlay
# above the whole desktop, follows the cursor and reads whatever text it steps on
# (UI Automation, Windows OCR as fallback), highlights the key sentences and
# builds a live TL;DR in a floating panel.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File TldrOverlay.ps1
#   ... -Console            keep the console open for logs
#   ... -RunSeconds 10      auto-quit (used by the smoke test)
#
# Nothing is installed and nothing is modified: the overlay is our own window, the
# highlights are drawn on top of other apps, and closing it leaves nothing behind.

param(
    [switch]$Console,
    [int]$RunSeconds = 0,
    [string]$ConfigPath = '',
    [switch]$DiscoverRegion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Console = [bool]$Console

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:Root 'lib\Win32.ps1')
. (Join-Path $script:Root 'lib\Core.ps1')
. (Join-Path $script:Root 'lib\ScreenReader.ps1')
. (Join-Path $script:Root 'lib\Watch.ps1')

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

if (-not ('Tldr.SpiderSurface' -as [type])) {
    Add-Type -Path (Join-Path $script:Root 'lib\SpiderSurface.cs') -ReferencedAssemblies @(
        'PresentationCore', 'PresentationFramework', 'WindowsBase', 'System.Xaml'
    ) -ErrorAction Stop
}

$script:HasWpf = $true

# ------------------------------------------------------------------ logging

$script:LogPath = Join-Path $env:TEMP 'tldr-overlay.log'

function Write-Log {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    if ($script:Console) { Write-Host $line }
    try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

# ------------------------------------------------------------------ config

function Get-Config {
    param([string]$Path)
    $defaults = @{
        apiKey   = ''
        model    = 'claude-3-5-haiku-latest'
        speedCap = 420
        stepMs   = 130
        glitch   = 0.25
        maxWords = 9
        minChars = 8
        watchX = 0
        watchY = 0
        watchW = 0
        watchH = 0
        watchScale = 3
        watchIntervalMs = 900
        alertFilter = ''
        alertBeep = $false
        alertRequireType = $true
        autoWatch = $true
        watchProcess = ''
    }
    if (-not $Path) { $Path = Join-Path $env:APPDATA 'TLDROverlay\config.json' }
    $script:S.ConfigPath = $Path   # every write goes back to the same file
    if (-not (Test-Path -LiteralPath $Path)) {
        # first run: drop a config file where the user can find it
        try {
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $defaults | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
            Write-Log ("created default config at " + $Path)
        } catch {
            Write-Log ("could not write default config: " + $_.Exception.Message)
        }
        return $defaults
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
        foreach ($key in @($defaults.Keys)) {
            if ($null -ne $json.PSObject.Properties[$key] -and $null -ne $json.$key -and "$($json.$key)" -ne '') {
                $defaults[$key] = $json.$key
            }
        }
    } catch {
        Write-Log "config unreadable ($Path): $($_.Exception.Message)"
    }
    return $defaults
}

# ------------------------------------------------------------------ state

$script:S = [ordered]@{
    Config        = $null
    Surface       = $null
    Overlay       = $null
    Panel         = $null
    Ui            = $null
    Active        = $true
    Stopped       = $false
    Sentences     = @{}                    # normalized text -> sentence
    Order         = New-Object System.Collections.Generic.List[object]
    Found         = New-Object System.Collections.Generic.List[object]
    Keys          = @()
    Total         = 0
    LineSeq       = 0
    LastFound     = $null
    PendingLegs   = @()
    StepSeen      = New-Object 'int[]' 8
    Tick          = 0
    LastCursor    = @{ X = -1; Y = -1 }
    LastMoveAt    = 0
    PrevBodyX     = 0
    PrevBodyY     = 0
    LastOcrAt     = 0
    Watch         = $false
    WatchRect     = $null
    Alerts        = New-Object System.Collections.Generic.List[object]
    AlertSeen     = New-Object System.Collections.Generic.List[string]
    AlertRecent   = New-Object System.Collections.Generic.List[string]
    AlertPending  = @()
    LastWatchAt   = 0
    LastAlertAt   = 0
    NextPatrolAt  = 0
    PickStage     = 0
    PickStart     = @{ X = 0; Y = 0 }
    ConfigPath    = ''
    AutoWatched   = $false
    AutoWatchPaused = $false
    LastAutoCheck = 0
    WatchPid      = 0
    Glitches      = New-Object System.Collections.Generic.List[object]
    Highlights    = @()
    AiPending     = New-Object System.Collections.Generic.List[object]
    AiTimer       = $null
    CrawlTimer    = $null
    UiTimer       = $null
    QuitTimer     = $null
    Hwnd          = [IntPtr]::Zero
    PanelHwnd     = [IntPtr]::Zero
    LastForegroundPid = -1
    HwndSource    = $null
    Hook          = $null
    HotkeyId      = 0x5154
    QuitHotkeyId  = 0x5155
    PickHotkeyId  = 0x5156
    WatchHotkeyId = 0x5157
}

# ------------------------------------------------------------------ spider surface

function Start-Spider {
    $vs = Get-VirtualScreenRect
    $scale = Get-DpiScale
    if ($scale -le 0) { $scale = 1 }

    $overlay = New-Object System.Windows.Window
    $overlay.WindowStyle = [System.Windows.WindowStyle]::None
    $overlay.AllowsTransparency = $true
    $overlay.Background = [System.Windows.Media.Brushes]::Transparent
    $overlay.Topmost = $true
    $overlay.ShowInTaskbar = $false
    $overlay.ShowActivated = $false
    $overlay.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $overlay.Left = $vs.X / $scale
    $overlay.Top = $vs.Y / $scale
    $overlay.Width = $vs.W / $scale
    $overlay.Height = $vs.H / $scale

    $surface = New-Object Tldr.SpiderSurface
    $surface.Scale = 1.0 / $scale
    $surface.OriginX = $vs.X
    $surface.OriginY = $vs.Y
    $surface.ScreenX = $vs.X
    $surface.ScreenY = $vs.Y
    $surface.ScreenW = $vs.W
    $surface.ScreenH = $vs.H
    $surface.SpeedCap = [double]$script:S.Config.speedCap
    $surface.StepDuration = ([double]$script:S.Config.stepMs) / 1000.0
    $surface.BodyX = $vs.X + $vs.W * 0.5
    $surface.BodyY = $vs.Y + $vs.H * 0.45
    $surface.Heading = 0
    $surface.TargetX = $surface.BodyX
    $surface.TargetY = $surface.BodyY
    $overlay.Content = $surface
    $overlay.Show()

    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($overlay)).Handle
    Set-OverlayWindowStyles -Handle $hwnd

    $script:S.Overlay = $overlay
    $script:S.Surface = $surface
    $script:S.Hwnd = $hwnd
    Write-Log ("overlay up: " + $vs.W + "x" + $vs.H + " at " + $vs.X + "," + $vs.Y + " scale=" + $scale)
}

function Stop-Spider {
    if ($null -ne $script:S.Surface) { $script:S.Surface.Running = $false; $script:S.Surface.Active = $false }
    if ($null -ne $script:S.Overlay) { $script:S.Overlay.Hide(); $script:S.Overlay.Close() }
    $script:S.Surface = $null
    $script:S.Overlay = $null
}

# ------------------------------------------------------------------ panel

$script:PanelXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="12" Background="#16181c" BorderBrush="#665ab8ff" BorderThickness="1" Width="340">
  <Border.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#cfe8ff"/>
      <Setter Property="Background" Value="#225ab8ff"/>
      <Setter Property="BorderBrush" Value="#805ab8ff"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Border.Resources>
  <StackPanel>
    <Grid Name="Head" Height="36" Background="#1b1e24">
      <Ellipse Width="8" Height="8" Fill="#5ab8ff" HorizontalAlignment="Left" Margin="12,0,0,0"/>
      <TextBlock Text="TL;DR" Foreground="#ffd166" FontWeight="Bold" FontSize="13" Margin="28,0,0,0" VerticalAlignment="Center"/>
      <TextBlock Name="Count" Text="0 / 0" Foreground="#9aa4b2" FontSize="12" HorizontalAlignment="Right" Margin="0,0,12,0" VerticalAlignment="Center"/>
    </Grid>
    <ProgressBar Name="Bar" Height="4" Minimum="0" Maximum="100" Value="0" Foreground="#ff7ab8" Background="#2a2d33" BorderThickness="0"/>
    <ScrollViewer MaxHeight="300" VerticalScrollBarVisibility="Auto">
      <StackPanel Name="List" Margin="10,8,10,4"/>
    </ScrollViewer>
    <TextBlock Name="AiOut" Foreground="#ffd166" FontSize="12" TextWrapping="Wrap" Margin="12,4,12,4" Visibility="Collapsed"/>
    <TextBlock Name="Status" Foreground="#ff7ab8" FontSize="12" TextWrapping="Wrap" Margin="12,4,12,0"/>
    <WrapPanel Margin="10,8,4,4">
      <Button Name="BtnCopy" Content="复制 TL;DR"/>
      <Button Name="BtnRestart" Content="重新启动"/>
      <Button Name="BtnAi" Content="Claude TL;DR" Visibility="Collapsed"/>
      <Button Name="BtnClose" Content="关闭"/>
    </WrapPanel>
  </StackPanel>
</Border>
'@

function Start-Panel {
    $panel = New-Object System.Windows.Window
    $panel.WindowStyle = [System.Windows.WindowStyle]::None
    $panel.AllowsTransparency = $true
    $panel.Background = [System.Windows.Media.Brushes]::Transparent
    $panel.Topmost = $true
    $panel.ShowInTaskbar = $false
    $panel.ShowActivated = $false
    $panel.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $panel.ResizeMode = [System.Windows.ResizeMode]::NoResize

    $root = [System.Windows.Markup.XamlReader]::Parse($script:PanelXaml)
    $panel.Content = $root
    $panel.Show()

    $ui = @{
        Root  = $root
        Count = $root.FindName('Count')
        Bar   = $root.FindName('Bar')
        List  = $root.FindName('List')
        AiOut = $root.FindName('AiOut')
        Status = $root.FindName('Status')
        Head  = $root.FindName('Head')
        BtnCopy = $root.FindName('BtnCopy')
        BtnRestart = $root.FindName('BtnRestart')
        BtnAi = $root.FindName('BtnAi')
        BtnClose = $root.FindName('BtnClose')
    }

    $scale = Get-DpiScale
    if ($scale -le 0) { $scale = 1 }
    $vs = Get-VirtualScreenRect
    $panel.Left = ($vs.X + $vs.W) / $scale - 340 - 16
    $panel.Top = ($vs.Y / $scale) + 16

    $ui.Head.Add_MouseLeftButtonDown({ try { $script:S.Panel.DragMove() } catch { } })
    $ui.BtnCopy.Add_Click({ Copy-Tldr })
    $ui.BtnRestart.Add_Click({ Restart-Crawler })
    $ui.BtnClose.Add_Click({ Request-Quit })
    $ui.BtnAi.Add_Click({ Request-FinalSummary })

    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($panel)).Handle
    Set-PanelWindowStyles -Handle $hwnd

    if ($script:S.Config.apiKey) { $ui.BtnAi.Visibility = [System.Windows.Visibility]::Visible }

    $script:S.Panel = $panel
    $script:S.PanelHwnd = $hwnd
    $script:S.Ui = $ui
    Write-Log 'panel up'
}

function Stop-Panel {
    if ($null -ne $script:S.Panel) { $script:S.Panel.Hide(); $script:S.Panel.Close() }
    $script:S.Panel = $null
    $script:S.Ui = $null
}

function Set-Status {
    param([string]$Text)
    if ($null -eq $script:S.Ui) { return }
    $script:S.Ui.Status.Text = $Text
}

function Update-PanelList {
    if ($null -eq $script:S.Ui) { return }
    if ($script:S.Watch) { Update-WatchPanel; return }
    $list = $script:S.Ui.List
    $list.Children.Clear()
    $items = @($script:S.Found | Sort-Object { $_.Art })
    $i = 1
    foreach ($s in $items) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $num = New-Object System.Windows.Controls.TextBlock
        $num.Text = "$i."
        $num.Foreground = [System.Windows.Media.Brushes]::LightSkyBlue
        $num.MinWidth = 18
        $num.FontSize = 12
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = $(if ($s.Summary) { $s.Summary } else { $s.Text })
        $txt.Foreground = [System.Windows.Media.Brushes]::WhiteSmoke
        $txt.FontSize = 12
        $txt.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $txt.MaxWidth = 270
        if ($s -eq $script:S.LastFound) {
            $txt.FontWeight = [System.Windows.FontWeights]::Bold
            $txt.Foreground = [System.Windows.Media.Brushes]::Gold
        }
        $row.Children.Add($num) | Out-Null
        $row.Children.Add($txt) | Out-Null
        $list.Children.Add($row) | Out-Null
        $i++
    }
    $script:S.Ui.Count.Text = ("{0} / {1}" -f $script:S.Found.Count, $script:S.Total)
    $bar = $script:S.Ui.Bar
    if ($script:S.Total -gt 0) {
        $bar.Value = [Math]::Round(100.0 * $script:S.Found.Count / $script:S.Total)
    } else {
        $bar.Value = 0
    }
}

# ------------------------------------------------------------------ sentences

function Get-TextKey {
    param([string]$Text)
    return (($Text -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Add-LineToPool {
    <#  Split a screen line into sentences and remember any new ones.
        Returns the sentence that the caret offset falls into. #>
    param([string]$Text, [int]$Offset)

    $hit = $null
    foreach ($part in @(Split-Sentences -Text $Text)) {
        $key = Get-TextKey -Text $part.Text
        if ($key.Length -lt [int]$script:S.Config.minChars) { continue }
        $sentence = $null
        if ($script:S.Sentences.ContainsKey($key)) {
            $sentence = $script:S.Sentences[$key]
        } else {
            $script:S.LineSeq++
            $sentence = @{
                Key           = $key
                Text          = $part.Text
                Score         = (Get-SentenceScore -Text $part.Text)
                Para          = $script:S.LineSeq
                Art           = $script:S.Order.Count
                Key2          = $false
                Found         = $false
                Summary       = ''
                Rects         = @()
                Range         = $null
                StartInLine   = 0
                LengthInLine  = $part.End - $part.Start
            }
            $script:S.Sentences[$key] = $sentence
            $script:S.Order.Add($sentence)
        }
        if ($Offset -ge $part.Start -and $Offset -le $part.End) { $hit = $sentence }
    }
    return $hit
}

function Update-KeySentences {
    $all = @($script:S.Order.ToArray())
    if ($all.Count -eq 0) { $script:S.Total = 0; return }
    $scores = @($all | ForEach-Object { [double]$_.Score })
    $paras = @($all | ForEach-Object { [int]$_.Para })
    $picked = @(Select-KeySentences -Scores $scores -Paras $paras -Ratio 0.25 -Min 5 -Max 80)
    $isKey = @{}
    foreach ($i in $picked) { $isKey[$all[$i].Key] = $true }
    $keys = New-Object System.Collections.Generic.List[object]
    foreach ($s in $all) {
        # a sentence the spider already found stays key, otherwise the progress bar
        # would move backwards when the pool grows
        $s.Key2 = $isKey.ContainsKey($s.Key) -or $s.Found
        if ($s.Key2) { $keys.Add($s) }
    }
    $script:S.Keys = @($keys.ToArray())
    $script:S.Total = [Math]::Max($script:S.Keys.Count, $script:S.Found.Count)
}

function Test-IsKeySentence {
    param($Sentence)
    if ($null -eq $Sentence) { return $false }
    foreach ($k in $script:S.Keys) { if ($k.Key -eq $Sentence.Key) { return $true } }
    return $false
}

function Add-Glitch {
    <#  A glitch is our own overlay art, never a change to the other app's text. #>
    param($Hit, [string]$Word, [int]$X, [int]$Y, [int]$Start, [int]$Length)

    if (-not $Hit.Range) { return }
    $boxes = @(Get-RangeRects -LineRange $Hit.Range -Start $Start -Length $Length)
    if ($boxes.Count -eq 0) { return }
    $kinds = @(0, 1, 2, 3, 4, 5)
    $picked = @()
    for ($i = 0; $i -lt 2; $i++) {
        $idx = Get-Random -Minimum 0 -Maximum $kinds.Count
        $picked += $kinds[$idx]
        $kinds = @($kinds | Where-Object { $_ -ne $kinds[$idx] })
    }
    $rot = (Get-Random -Minimum -60 -Maximum 60) / 10.0
    foreach ($box in $boxes) {
        $script:S.Glitches.Add(@{
            X = $box.X; Y = $box.Y; W = $box.W; H = $box.H
            Kind = $picked[0]; Rotation = $rot; Until = (Get-Date).AddMilliseconds(1400)
            Word = $Word
        })
    }
    if ($script:S.Glitches.Count -gt 60) {
        for ($i = 0; $i -lt 20; $i++) { $script:S.Glitches.RemoveAt(0) }
    }
}

function Update-Glitches {
    $now = Get-Date
    $live = @($script:S.Glitches | Where-Object { $_.Until -gt $now })
    if ($live.Count -ne $script:S.Glitches.Count) {
        $script:S.Glitches.Clear()
        foreach ($g in $live) { $script:S.Glitches.Add($g) }
    }
    $arr = New-Object System.Collections.Generic.List[double]
    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($g in $script:S.Glitches) {
        [void]$arr.Add([double]$g.X); [void]$arr.Add([double]$g.Y); [void]$arr.Add([double]$g.W); [void]$arr.Add([double]$g.H)
        [void]$arr.Add([double]$g.Kind); [void]$arr.Add([double]$g.Rotation)
        [void]$texts.Add([string]$g.Word)
    }
    $script:S.Surface.Glitches = $arr.ToArray()
    $script:S.Surface.GlitchText = $texts.ToArray()
}

function Update-Highlights {
    $arr = New-Object System.Collections.Generic.List[double]
    foreach ($s in $script:S.Found) {
        foreach ($r in @($s.Rects)) {
            [void]$arr.Add([double]$r.X); [void]$arr.Add([double]$r.Y); [void]$arr.Add([double]$r.W); [void]$arr.Add([double]$r.H)
        }
    }
    $script:S.Surface.Highlights = $arr.ToArray()
}

function Restart-Crawler {
    Write-Log 'restart: clearing the pool, highlights and glitches'
    $script:S.Sentences = @{}
    $script:S.Order.Clear()
    $script:S.Found.Clear()
    $script:S.Keys = @()
    $script:S.Total = 0
    $script:S.LineSeq = 0
    $script:S.LastFound = $null
    $script:S.Glitches.Clear()
    $script:S.AiPending.Clear()
    $script:S.Alerts.Clear()
    $script:S.AlertSeen.Clear()
    $script:S.AlertRecent.Clear()
    $script:S.AlertPending = @()
    if ($null -ne $script:S.Ui) { $script:S.Ui.AiOut.Text = ''; $script:S.Ui.AiOut.Visibility = [System.Windows.Visibility]::Collapsed }
    Set-Status ''
    $script:S.StepSeen = New-Object 'int[]' 8
    $script:S.PendingLegs = @()
    Update-Highlights
    Update-Glitches
    Update-PanelList
}

function Copy-Tldr {
    if ($script:S.Found.Count -eq 0) { Set-Status '还没有发现内容'; return }
    $lines = @()
    $i = 1
    foreach ($s in @($script:S.Found | Sort-Object { $_.Art })) {
        $lines += ("{0}. {1}" -f $i, $(if ($s.Summary) { $s.Summary } else { $s.Text }))
        $i++
    }
    try {
        Set-Clipboard -Value ($lines -join "`r`n")
        Set-Status '已复制 TL;DR'
    } catch {
        Write-Log ("clipboard failed: " + $_.Exception.Message)
        Set-Status '复制失败'
    }
}

function Mark-Found {
    param($Sentence, $Hit, [int]$FootX, [int]$FootY)

    $Sentence.Found = $true
    $Sentence.Summary = Get-FallbackSummary -Text $Sentence.Text -MaxWords ([int]$script:S.Config.maxWords)
    $Sentence.Range = $Hit.Range
    $geo = Get-HighlightGeometry -Hit $Hit -Start $Sentence.StartInLine -Length $Sentence.LengthInLine -FootX $FootX -FootY $FootY
    $Sentence.Rects = @($geo.Rects)
    $script:S.Found.Add($Sentence)
    $script:S.LastFound = $Sentence
    Update-Highlights
    Update-PanelList
    if ($script:S.Config.apiKey) {
        $script:S.AiPending.Add($Sentence)
        if ($null -ne $script:S.AiTimer) { $script:S.AiTimer.Stop(); $script:S.AiTimer.Start() }
    }
    Write-Log ("found: " + $Sentence.Text + "  (" + $script:S.Found.Count + "/" + $script:S.Total + ", geometry=" + $geo.Source + ")")
}

function Refresh-FoundGeometry {
    <#  Screen content moves when the app underneath scrolls: re-measure the
        highlights so they stay glued to their text. #>
    $vs = Get-VirtualScreenRect
    $budget = 25
    foreach ($s in $script:S.Found.ToArray()) {
        if ($budget -le 0) { break }
        if ($null -eq $s.Range) { continue }
        $onScreen = $false
        foreach ($r in @($s.Rects)) {
            if ($r.Y + $r.H -ge $vs.Y -and $r.Y -le ($vs.Y + $vs.H) -and $r.X + $r.W -ge $vs.X -and $r.X -le ($vs.X + $vs.W)) { $onScreen = $true; break }
        }
        if (-not $onScreen -and $s.Rects.Count -gt 0) { continue }
        $budget--
        try {
            $geo = Get-HighlightGeometry -Hit @{ Range = $s.Range; Rects = @() } -Start $s.StartInLine -Length $s.LengthInLine -FootX 0 -FootY 0
            if (@($geo.Rects).Count -gt 0) { $s.Rects = @($geo.Rects) }
        } catch { }
    }
    Update-Highlights
}

# ------------------------------------------------------------------ Claude

function Invoke-Claude {
    param([string]$Prompt, [int]$MaxTokens = 1024)

    if (-not $script:S.Config.apiKey) { return @{ ok = $false; error = 'no-key' } }
    $body = @{
        model      = $script:S.Config.model
        max_tokens = $MaxTokens
        messages   = @(@{ role = 'user'; content = $Prompt })
    } | ConvertTo-Json -Depth 8 -Compress

    try {
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -TimeoutSec 30 `
            -Headers @{
            'x-api-key'         = [string]$script:S.Config.apiKey
            'anthropic-version' = '2023-06-01'
            'content-type'      = 'application/json'
        } -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
        $text = (@($resp.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return @{ ok = $false; error = 'empty' } }
        return @{ ok = $true; text = $text }
    } catch {
        Write-Log ("claude failed: " + $_.Exception.Message)
        return @{ ok = $false; error = 'request'; detail = $_.Exception.Message }
    }
}

function ConvertFrom-JsonArray {
    param([string]$Text)
    $a = $Text.IndexOf('[')
    $b = $Text.LastIndexOf(']')
    if ($a -lt 0 -or $b -le $a) { return $null }
    try { return @(($Text.Substring($a, $b - $a + 1)) | ConvertFrom-Json) } catch { return $null }
}

function Invoke-AiBatch {
    if ($script:S.AiPending.Count -eq 0) { return }
    $batch = @($script:S.AiPending | Select-Object -First 20)
    $script:S.AiPending.Clear()
    $list = @($batch | ForEach-Object { $_.Text })
    $prompt = @(
        'Compress each sentence below into an extremely short TL;DR fragment.',
        'Rules:',
        '- Reply with ONLY a JSON array of strings, one per input sentence, in the same order.',
        '- Each fragment: at most 9 words.',
        '- Keep every number, percentage, currency value and date EXACTLY as written.',
        '- Keep person names, company names and product names.',
        '- Never add facts that are not in that sentence. Never exaggerate.',
        '',
        'Input sentences:',
        ($list | ConvertTo-Json -Compress)
    ) -join "`n"

    $result = Invoke-Claude -Prompt $prompt -MaxTokens 1024
    if (-not $result.ok) {
        if ($result.error -ne 'no-key') { Set-Status 'AI 不可用' }
        return
    }
    $arr = ConvertFrom-JsonArray -Text $result.text
    if ($null -eq $arr) { Set-Status 'AI 不可用'; return }
    for ($i = 0; $i -lt $batch.Count; $i++) {
        if ($i -lt $arr.Count -and -not [string]::IsNullOrWhiteSpace([string]$arr[$i])) {
            $batch[$i].Summary = Limit-Words -Text ([string]$arr[$i]) -MaxWords ([int]$script:S.Config.maxWords)
        }
    }
    Update-PanelList
}

function Request-FinalSummary {
    if ($script:S.Found.Count -eq 0) { Set-Status '还没有发现关键句'; return }
    $ui = $script:S.Ui
    $ui.AiOut.Visibility = [System.Windows.Visibility]::Visible
    $ui.AiOut.Text = '思考中…'
    $list = @($script:S.Found | Sort-Object { $_.Art } | ForEach-Object { $_.Text })
    $prompt = @(
        'Write a TL;DR of the text excerpts below.',
        'Rules:',
        '- Reply with ONLY a JSON array of exactly 3 short strings.',
        '- Each string is one short sentence: what happened, the key numbers, the impact.',
        '- Use ONLY facts present in the input. Add no new facts. Do not exaggerate.',
        '- Every number must be copied exactly as written.',
        '',
        'Excerpts:',
        ($list | ConvertTo-Json -Compress)
    ) -join "`n"

    $result = Invoke-Claude -Prompt $prompt -MaxTokens 1024
    if (-not $result.ok) {
        $ui.AiOut.Visibility = [System.Windows.Visibility]::Collapsed
        Set-Status 'AI 不可用'      # fallback summaries stay exactly as they are
        return
    }
    $arr = ConvertFrom-JsonArray -Text $result.text
    if ($null -eq $arr) { $ui.AiOut.Visibility = [System.Windows.Visibility]::Collapsed; Set-Status 'AI 不可用'; return }
    $ui.AiOut.Text = (@($arr | Select-Object -First 3 | ForEach-Object { '• ' + [string]$_ }) -join "`n")
    Set-Status ''
}

# ------------------------------------------------------------------ reading

function Sample-At {
    param([int]$X, [int]$Y, [bool]$AllowOcr)

    $vs = Get-VirtualScreenRect
    if ($X -lt $vs.X -or $Y -lt $vs.Y -or $X -gt ($vs.X + $vs.W) -or $Y -gt ($vs.Y + $vs.H)) { return }
    # never read our own panel or overlay (the UIA path already skips our process)
    if ((Get-WindowAtPoint -X $X -Y $Y) -eq $PID) { return }

    $hit = Get-ScreenPointText -X $X -Y $Y -AllowOcr $AllowOcr
    if ($null -eq $hit) { return }
    if ([string]::IsNullOrWhiteSpace($hit.Text)) { return }

    $before = $script:S.Order.Count
    $sentence = Add-LineToPool -Text $hit.Text -Offset ([int]$hit.Offset)
    if ($script:S.Order.Count -ne $before) {
        Update-KeySentences      # the pool grew: re-pick key sentences
        Update-PanelList
    }
    if ($null -eq $sentence) { return }

    $idx = -1
    $i = 0
    foreach ($part in @(Split-Sentences -Text $hit.Text)) {
        if ((Get-TextKey -Text $part.Text) -eq $sentence.Key) { $idx = $i; $sentence.StartInLine = $part.Start; $sentence.LengthInLine = $part.End - $part.Start; break }
        $i++
    }

    if ($sentence.Found) { return }
    if (Test-IsKeySentence -Sentence $sentence) {
        if ($idx -lt 0) { $sentence.StartInLine = 0; $sentence.LengthInLine = [Math]::Max(1, $hit.Text.Length) }
        Mark-Found -Sentence $sentence -Hit $hit -FootX $X -FootY $Y
        return
    }

    # plain word under the foot: maybe a glitch (never touches the other app's text)
    if ((Get-Random -Minimum 0 -Maximum 100) -ge ([double]$script:S.Config.glitch * 100)) { return }
    $word = Get-WordAt -Data $hit.Text -Offset ([int]$hit.Offset)
    if ($null -eq $word) { return }
    if (-not (Test-CjkWord -Word $word.Word) -and $word.Word.Length -lt 3) { return }
    Add-Glitch -Hit $hit -Word $word.Word -X $X -Y $Y -Start $word.Start -Length ($word.End - $word.Start)
}

function Invoke-CrawlTick {
    if ($script:S.Stopped -or -not $script:S.Active) { return }
    try {
        $cursor = Get-CursorPosition
        if ($cursor.X -ne $script:S.LastCursor.X -or $cursor.Y -ne $script:S.LastCursor.Y) {
            $script:S.LastCursor = $cursor
            $script:S.LastMoveAt = [Environment]::TickCount
        }
        $idle = ([Environment]::TickCount - $script:S.LastMoveAt) -gt 8000
        $script:S.Surface.Wandering = $idle
        if (-not $idle) {
            $script:S.Surface.TargetX = [double]$cursor.X
            $script:S.Surface.TargetY = [double]$cursor.Y
        }

        Invoke-AutoWatch

        if ($script:S.Watch) {
            Invoke-WatchTick
            Update-Glitches
            return
        }

        # OCR costs ~45ms on the UI thread, so spend it mostly when the spider is
        # at rest: apps that expose no UI Automation text (games, 同花顺, canvas
        # dashboards) still get read the moment the cursor pauses, and crawling
        # stays smooth. A slow cadence keeps it alive even while moving.
        $bodyX = [int]$script:S.Surface.BodyX
        $bodyY = [int]$script:S.Surface.BodyY
        $movedBy = [Math]::Abs($bodyX - $script:S.PrevBodyX) + [Math]::Abs($bodyY - $script:S.PrevBodyY)
        $script:S.PrevBodyX = $bodyX
        $script:S.PrevBodyY = $bodyY
        $nowTicks = [Environment]::TickCount
        $sinceOcr = $nowTicks - $script:S.LastOcrAt
        $resting = ($movedBy -lt 4)
        $ocrAllowed = ($resting -and $sinceOcr -gt 400) -or ($sinceOcr -gt 1400)
        if ($ocrAllowed) { $script:S.LastOcrAt = $nowTicks }

        # text is read on every foot landing (the gait is already rate limited)
        foreach ($leg in $script:S.PendingLegs) {
            $b = $leg * 8
            Sample-At -X ([int]$script:S.Surface.Legs[$b + 4]) -Y ([int]$script:S.Surface.Legs[$b + 5]) -AllowOcr $ocrAllowed
        }
        $script:S.PendingLegs = @()

        # apps that are topmost themselves (trading clients, players) rise above us
        # when they get activated: put the overlay back on top without stealing focus
        $fg = Get-ForegroundProcessId
        if ($fg -ne $script:S.LastForegroundPid -or ($script:S.Tick % 60) -eq 0) {
            $script:S.LastForegroundPid = $fg
            if ($script:S.Active) {
                Set-WindowTopmost -Handle $script:S.Hwnd
                Set-WindowTopmost -Handle $script:S.PanelHwnd
            }
        }
        $script:S.Tick++
        if (($script:S.Tick % 8) -eq 0) {
            Sample-At -X $bodyX -Y $bodyY -AllowOcr $ocrAllowed
        }
        if (($script:S.Tick % 12) -eq 0) { Refresh-FoundGeometry }
        Update-Glitches
    } catch {
        Write-Log ("crawl tick failed: " + $_.Exception.Message + " @ " + $_.InvocationInfo.PositionMessage.Trim())
    }
}

function Update-Landings {
    for ($leg = 0; $leg -lt 8; $leg++) {
        $count = $script:S.Surface.StepCounters[$leg]
        if ($count -ne $script:S.StepSeen[$leg]) {
            $script:S.StepSeen[$leg] = $count
            $script:S.PendingLegs += $leg
        }
    }
}

# ------------------------------------------------------------------ hotkeys

function Register-OverlayHotkeys {
    if ($script:S.Hwnd -eq [IntPtr]::Zero) { return }
    $mods = 0x0001 -bor 0x0002   # ALT | CONTROL
    $okToggle = [Tldr.Win32]::RegisterHotKey($script:S.Hwnd, $script:S.HotkeyId, $mods, 0x53)  # Ctrl+Alt+S
    $okQuit = [Tldr.Win32]::RegisterHotKey($script:S.Hwnd, $script:S.QuitHotkeyId, $mods, 0x51) # Ctrl+Alt+Q
    $okPick = [Tldr.Win32]::RegisterHotKey($script:S.Hwnd, $script:S.PickHotkeyId, $mods, 0x52)  # Ctrl+Alt+R
    $okWatch = [Tldr.Win32]::RegisterHotKey($script:S.Hwnd, $script:S.WatchHotkeyId, $mods, 0x57) # Ctrl+Alt+W
    Write-Log ("hotkeys: Ctrl+Alt+S=$okToggle  Ctrl+Alt+Q=$okQuit")

    $source = [System.Windows.Interop.HwndSource]::FromHwnd($script:S.Hwnd)
    if ($null -eq $source) { return }
    $script:S.Hook = [System.Windows.Interop.HwndSourceHook] {
        param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
        # an exception escaping a native callback kills the whole process without
        # running any cleanup, so nothing may leave this block unwrapped
        try {
            if ($msg -eq 0x0312) {
                $id = $wParam.ToInt32()
                if ($id -eq $script:S.HotkeyId) { Toggle-Crawler; $handled.Value = $true }
                elseif ($id -eq $script:S.QuitHotkeyId) { Request-Quit; $handled.Value = $true }
                elseif ($id -eq $script:S.PickHotkeyId) { Start-PickRegion; $handled.Value = $true }
                elseif ($id -eq $script:S.WatchHotkeyId) { Toggle-Watch; $handled.Value = $true }
            }
        } catch {
            Write-Log ('hotkey handler failed: ' + $_.Exception.Message)
        }
        return [IntPtr]::Zero
    }
    $source.AddHook($script:S.Hook)
    $script:S.HwndSource = $source
}

function Unregister-OverlayHotkeys {
    if ($script:S.Hwnd -eq [IntPtr]::Zero) { return }
    try { [void][Tldr.Win32]::UnregisterHotKey($script:S.Hwnd, $script:S.HotkeyId) } catch { }
    try { [void][Tldr.Win32]::UnregisterHotKey($script:S.Hwnd, $script:S.QuitHotkeyId) } catch { }
    try { [void][Tldr.Win32]::UnregisterHotKey($script:S.Hwnd, $script:S.PickHotkeyId) } catch { }
    try { [void][Tldr.Win32]::UnregisterHotKey($script:S.Hwnd, $script:S.WatchHotkeyId) } catch { }
    if ($null -ne $script:S.HwndSource -and $null -ne $script:S.Hook) {
        try { $script:S.HwndSource.RemoveHook($script:S.Hook) } catch { }
    }
    $script:S.HwndSource = $null
}

function Toggle-Crawler {
    $script:S.Active = -not $script:S.Active
    if ($script:S.Active) {
        $script:S.Surface.Active = $true
        $script:S.Surface.Running = $true
        $script:S.Overlay.Visibility = [System.Windows.Visibility]::Visible
        $script:S.Panel.Visibility = [System.Windows.Visibility]::Visible
        Write-Log 'hotkey: crawler ON'
    } else {
        $script:S.Surface.Active = $false
        $script:S.Glitches.Clear()
        Update-Glitches
        Update-Highlights
        $script:S.Overlay.Visibility = [System.Windows.Visibility]::Hidden
        $script:S.Panel.Visibility = [System.Windows.Visibility]::Hidden
        Write-Log 'hotkey: crawler OFF (screen restored)'
    }
}

# ------------------------------------------------------------------ lifecycle

function Request-Quit {
    Write-Log 'quit requested'
    $script:S.Stopped = $true
    try { Unregister-OverlayHotkeys } catch { }
    try { if ($null -ne $script:S.CrawlTimer) { $script:S.CrawlTimer.Stop() } } catch { }
    try { if ($null -ne $script:S.UiTimer) { $script:S.UiTimer.Stop() } } catch { }
    try { Stop-Panel } catch { }
    try { Stop-Spider } catch { }
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
}

function Start-Crawler {
    Write-Log 'starting'
    Start-Spider
    Start-Panel
    Register-OverlayHotkeys

    $script:S.CrawlTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:S.CrawlTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $script:S.CrawlTimer.Add_Tick({
        try { Update-Landings; Invoke-CrawlTick } catch { Write-Log ("tick failed: " + $_.Exception.Message) }
    })
    $script:S.CrawlTimer.Start()

    $script:S.AiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:S.AiTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
    $script:S.AiTimer.Add_Tick({ $script:S.AiTimer.Stop(); Invoke-AiBatch })
    $script:S.AiTimer.Start()

    if ($RunSeconds -gt 0) {
        $script:S.QuitTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:S.QuitTimer.Interval = [TimeSpan]::FromSeconds($RunSeconds)
        $script:S.QuitTimer.Add_Tick({ $script:S.QuitTimer.Stop(); Request-Quit })
        $script:S.QuitTimer.Start()
        Write-Log ("auto-quit after " + $RunSeconds + "s")
    }

    if ([int]$script:S.Config.watchW -ge 40 -and [int]$script:S.Config.watchH -ge 30) {
        Set-WatchRect -X ([int]$script:S.Config.watchX) -Y ([int]$script:S.Config.watchY) -W ([int]$script:S.Config.watchW) -H ([int]$script:S.Config.watchH)
        Write-Log ('watch region loaded: ' + $script:S.Config.watchW + 'x' + $script:S.Config.watchH)
        if (Test-WatchTargetVisible) {
            $script:S.Watch = $true
            $script:S.AutoWatched = $true
            $script:S.Surface.Wandering = $false
            Set-Status '感应到盯盘窗口，自动盯盘中…（Ctrl+Alt+W 暂停）'
            Write-Log 'watch mode restored (target on screen)'
        } else {
            Set-Status '跟光标模式：感应到盯盘窗口会自动切过去（Ctrl+Alt+R 重新框选）'
            Write-Log 'watch region loaded but the target window is not on screen yet'
        }
    } else {
        Set-Status '把光标移到文字上，蜘蛛会开始阅读 (Ctrl+Alt+S 开关, Ctrl+Alt+Q 退出, Ctrl+Alt+R 框选盯盘区域)'
    }
    Update-PanelList
}

try {
    $script:Console = [bool]$Console
    $script:S.Config = Get-Config -Path $ConfigPath
    if ($DiscoverRegion) {
        $name = [string]$script:S.Config.watchProcess
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'happ' }
        Write-Host ('looking for a 短线精灵 style panel inside "' + $name + '" ...')
        $found = $null
        foreach ($candidate in ($name -split ',')) {
            $found = Find-AlertPanelRegion -ProcessName $candidate.Trim()
            if ($null -ne $found) { break }
        }
        if ($null -eq $found) {
            Write-Host 'not found (is the window open and visible?)'
        } else {
            Write-Host ('region: x=' + $found.X + ' y=' + $found.Y + ' w=' + $found.W + ' h=' + $found.H + '  (' + $found.Hits + ' alert rows)')
            $script:S.WatchRect = @{ X = $found.X; Y = $found.Y; W = $found.W; H = $found.H }
            $script:S.Config['watchProcess'] = $name
            Save-WatchRegion
            Write-Host 'saved to config.'
        }
        exit 0
    }
    Write-Log ('config: model=' + $script:S.Config.model + ' key=' + $(if ($script:S.Config.apiKey) { 'set' } else { 'none' }))
    Start-Crawler
    [System.Windows.Threading.Dispatcher]::Run()
} catch {
    Write-Log ('fatal: ' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace)
} finally {
    try { Unregister-OverlayHotkeys } catch { }
    Write-Log 'stopped'
}
