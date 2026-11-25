# TL;DR Overlay - Watch.ps1
# 盯盘模式 (watch mode): lock the reader onto one screen rectangle - typically the
# 短线精灵 alert list in 同花顺 - OCR it on a timer, and report what is new.
#
# Dot-sourced by TldrOverlay.ps1: functions here share the app's script scope and
# use $script:S for state.
#
#   Ctrl+Alt+R   pick the region: cursor to the top-left corner, press, then to the
#                bottom-right corner, press again. The rectangle is saved to config.
#   Ctrl+Alt+W   toggle watch mode / cursor mode.

function Get-RegionOwner {
    <#  Who owns the window sitting at the middle of the watch region right now. #>
    $r = $script:S.WatchRect
    if ($null -eq $r) { return $null }
    $x = $r.X + [int]($r.W / 2)
    $y = $r.Y + [int]($r.H / 2)
    $pidAt = Get-WindowAtPoint -X $x -Y $y
    if ($pidAt -le 0 -or $pidAt -eq $PID) { return $null }
    return @{ Pid = $pidAt; Name = (Get-ProcessNameSafe -ProcessId $pidAt) }
}

function Test-WatchTargetVisible {
    <#  Is the app we picked this region from still the one showing there? That is
        the whole "感应到同花顺" test: no foreground guessing, no process list -
        we just look at what is actually drawn in the watched rectangle. #>
    $owner = Get-RegionOwner
    if ($null -eq $owner) { return $false }
    if ($script:S.WatchPid -gt 0 -and $owner.Pid -eq $script:S.WatchPid) { return $true }
    $want = [string]$script:S.Config.watchProcess
    if ([string]::IsNullOrWhiteSpace($want)) { return $true }
    foreach ($name in ($want -split ',')) {
        $n = $name.Trim()
        if ($n.Length -eq 0) { continue }
        if ($owner.Name -like "$n*") { return $true }
    }
    return $false
}

function Update-WatchProcessMemory {
    <#  First run: remember which app the region belongs to, then persist it. #>
    if (-not [string]::IsNullOrWhiteSpace([string]$script:S.Config.watchProcess)) { return }
    $owner = Get-RegionOwner
    if ($null -eq $owner) { return }
    $script:S.Config['watchProcess'] = $owner.Name
    $script:S.WatchPid = $owner.Pid
    Write-Log ("watch target learned: " + $owner.Name + " (pid " + $owner.Pid + ")")
    Save-WatchRegion
}

function Invoke-AutoWatch {
    <#  Crawl whatever is on screen; the moment the watched app shows up under the
        region, start watching it; when it goes away, hand back to cursor mode. #>
    if (-not [bool]$script:S.Config.autoWatch) { return }
    if ($script:S.AutoWatchPaused) { return }
    $now = [Environment]::TickCount
    if (($now - $script:S.LastAutoCheck) -lt 1200) { return }
    $script:S.LastAutoCheck = $now
    if ($null -eq $script:S.WatchRect -or $script:S.WatchRect.W -lt 40) { return }

    Update-WatchProcessMemory
    $visible = Test-WatchTargetVisible

    if ($visible -and -not $script:S.Watch) {
        $script:S.Watch = $true
        $script:S.AutoWatched = $true
        $script:S.AlertSeen.Clear()
        $script:S.AlertRecent.Clear()
        $script:S.AlertPending = @()
        $script:S.Surface.Wandering = $false
        Write-Log 'auto watch ON (watched window is on screen)'
        Set-Status '感应到盯盘窗口，自动盯盘中…（Ctrl+Alt+W 暂停自动切换）'
        Update-PanelList
    } elseif (-not $visible -and $script:S.Watch -and $script:S.AutoWatched) {
        $script:S.Watch = $false
        $script:S.AutoWatched = $false
        $script:S.Surface.Highlights = @()
        $script:S.Surface.Wandering = $true
        Write-Log 'auto watch OFF (watched window left the screen)'
        Set-Status '盯盘窗口不在了，回到跟光标模式'
        Update-PanelList
    }
}

function Find-AlertPanelRegion {
    <#  Auto-locate a 短线精灵 style panel inside an app window: OCR the window,
        keep the words that are known alert types, and take the column they stack
        in. Used when nothing has been picked yet, and by -DiscoverRegion. #>
    param([string]$ProcessName = 'happ', [int]$LeftPad = 110, [int]$Scale = 2)

    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($null -eq $proc) { return $null }
    $rect = Get-WindowRect -Handle $proc.MainWindowHandle
    if ($null -eq $rect -or $rect.W -lt 200 -or $rect.H -lt 200) { return $null }

    $words = Get-WordsFromRegion -X $rect.X -Y $rect.Y -W $rect.W -H $rect.H -Scale $Scale
    # Windows OCR hands CJK back one character per word, so the alert types only
    # become matchable once the words are clustered and merged
    $found = Select-AlertColumn -Words $words -Bounds $rect -LeftPad $LeftPad
    if ($null -ne $found) {
        Write-Log ("alert panel found: " + $found.W + "x" + $found.H + " at " + $found.X + "," + $found.Y + " (" + $found.Hits + " alert rows)")
    }
    return $found
}

function Get-WordClusters {
    <#  Split OCR words into panel columns: group by vertical position, then cut
        each row wherever the horizontal gap is wider than GapX. One cluster is one
        cell of the UI (name / alert type / percentage). #>
    [CmdletBinding()]
    param($Words, [int]$RowTolerance = 7, [int]$GapX = 20)

    $rows = New-Object System.Collections.ArrayList
    foreach ($w in @($Words | Sort-Object { $_.Y }, { $_.X })) {
        $placed = $false
        foreach ($row in $rows) {
            if ([Math]::Abs([int]$row.Y - [int]$w.Y) -le $RowTolerance) { [void]$row.Words.Add($w); $placed = $true; break }
        }
        if (-not $placed) {
            $bucket = New-Object System.Collections.ArrayList
            [void]$bucket.Add($w)
            [void]$rows.Add(@{ Y = [int]$w.Y; Words = $bucket })
        }
    }

    $out = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        $ordered = @($row.Words | Sort-Object { $_.X })
        $segment = New-Object System.Collections.ArrayList
        $prevEnd = $null
        foreach ($w in $ordered) {
            if ($null -ne $prevEnd -and ([int]$w.X - $prevEnd) -gt $GapX) {
                Add-Cluster -Out $out -Words $segment.ToArray()
                $segment = New-Object System.Collections.ArrayList
            }
            [void]$segment.Add($w)
            $prevEnd = [int]$w.X + [int]$w.W
        }
        Add-Cluster -Out $out -Words $segment.ToArray()
    }
    return $out.ToArray()
}

function Add-Cluster {
    param($Out, $Words)
    if (@($Words).Count -eq 0) { return }
    $pieces = @(Group-WordsIntoRows -Words $Words)
    foreach ($p in $pieces) { [void]$Out.Add($p) }
}

function Select-AlertColumn {
    <#  Pure geometry: given OCR words, find the column of known alert types and
        return the rectangle worth watching (widened left for the stock-name
        column). Returns { X; Y; W; H; Hits } or $null. #>
    [CmdletBinding()]
    param($Words, $Bounds, [int]$LeftPad = 110)

    $clusters = @(Get-WordClusters -Words $Words)
    $hits = @()
    foreach ($r in $clusters) {
        $text = [string]$r.Text
        if ($text.Length -lt 2) { continue }
        if ((Find-AlertType -Text $text).Length -eq 0) { continue }
        $hits += $r
    }
    if ($hits.Count -lt 3) { return $null }

    # the densest x-band is the column the alert types sit in
    $band = $null
    $bandCount = 0
    foreach ($anchor in $hits) {
        $candidate = @($hits | Where-Object { [Math]::Abs([int]$_.X - [int]$anchor.X) -le 60 })
        if ($candidate.Count -gt $bandCount) { $bandCount = $candidate.Count; $band = $candidate }
    }
    if ($null -eq $band -or $band.Count -lt 3) { return $null }
    $hits = @($band)

    # it must be a stacked list, not one wide line
    $distinctY = @{}
    foreach ($h in $hits) { $distinctY[[int]$h.Y] = $true }
    if ($distinctY.Count -lt 3) { return $null }

    $x0 = [int]::MaxValue; $y0 = [int]::MaxValue; $x1 = [int]::MinValue; $y1 = [int]::MinValue
    foreach ($h in $hits) {
        if ([int]$h.X -lt $x0) { $x0 = [int]$h.X }
        if ([int]$h.Y -lt $y0) { $y0 = [int]$h.Y }
        if (([int]$h.X + [int]$h.W) -gt $x1) { $x1 = [int]$h.X + [int]$h.W }
        if (([int]$h.Y + [int]$h.H) -gt $y1) { $y1 = [int]$h.Y + [int]$h.H }
    }
    $left = [Math]::Max([int]$Bounds.X, $x0 - $LeftPad)
    $top = [Math]::Max([int]$Bounds.Y, $y0 - 14)
    $right = [Math]::Min([int]$Bounds.X + [int]$Bounds.W, $x1 + 40)
    $bottom = [Math]::Min([int]$Bounds.Y + [int]$Bounds.H, $y1 + 24)
    if (($right - $left) -lt 60 -or ($bottom - $top) -lt 40) { return $null }
    return @{ X = $left; Y = $top; W = $right - $left; H = $bottom - $top; Hits = $hits.Count }
}
function Save-WatchRegion {
    $path = [string]$script:S.ConfigPath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $env:APPDATA 'TLDROverlay\config.json' }
    try {
        $out = @{}
        foreach ($k in @($script:S.Config.Keys)) { $out[$k] = $script:S.Config[$k] }
        $out['watchX'] = [int]$script:S.WatchRect.X
        $out['watchY'] = [int]$script:S.WatchRect.Y
        $out['watchW'] = [int]$script:S.WatchRect.W
        $out['watchH'] = [int]$script:S.WatchRect.H
        $out['watchProcess'] = [string]$script:S.Config.watchProcess
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $out | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
        foreach ($k in @($out.Keys)) { $script:S.Config[$k] = $out[$k] }
        Write-Log ("watch region saved to " + $path)
    } catch {
        Write-Log ("could not save watch region: " + $_.Exception.Message)
    }
}

function Set-WatchRect {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $script:S.WatchRect = @{ X = $X; Y = $Y; W = $W; H = $H }
}

function Start-PickRegion {
    $cursor = Get-CursorPosition
    if ($script:S.PickStage -eq 0) {
        $script:S.PickStage = 1
        $script:S.PickStart = @{ X = $cursor.X; Y = $cursor.Y }
        Set-Status '① 鼠标移到异动列表左上角 → Ctrl+Alt+R；② 再移到右下角 → Ctrl+Alt+R'
        Write-Log ("pick stage 1 at " + $cursor.X + "," + $cursor.Y)
        return
    }
    $script:S.PickStage = 0
    $x = [Math]::Min($script:S.PickStart.X, $cursor.X)
    $y = [Math]::Min($script:S.PickStart.Y, $cursor.Y)
    $w = [Math]::Abs($cursor.X - $script:S.PickStart.X)
    $h = [Math]::Abs($cursor.Y - $script:S.PickStart.Y)
    if ($w -lt 40 -or $h -lt 30) {
        Set-Status '区域太小，重新按 Ctrl+Alt+R 框一次'
        return
    }
    Set-WatchRect -X $x -Y $y -W $w -H $h
    $owner = Get-RegionOwner
    if ($null -ne $owner) {
        $script:S.Config['watchProcess'] = $owner.Name
        $script:S.WatchPid = $owner.Pid
        Write-Log ("region owner: " + $owner.Name + " (pid " + $owner.Pid + ")")
    }
    Save-WatchRegion
    $script:S.Watch = $true
    $script:S.AlertSeen.Clear()
    $script:S.AlertRecent.Clear()
    $script:S.AlertPending = @()
    Set-Status ("盯盘区域已保存 " + $w + "x" + $h + "（Ctrl+Alt+W 切换盯盘/跟光标）")
    Write-Log ("watch region set: " + $x + "," + $y + " " + $w + "x" + $h)
}

function Toggle-Watch {
    if ($null -eq $script:S.WatchRect -or $script:S.WatchRect.W -lt 40) {
        Set-Status '还没有盯盘区域：鼠标到左上角按 Ctrl+Alt+R，再到右下角按一次'
        Start-PickRegion
        return
    }
    if ([bool]$script:S.Config.autoWatch) {
        # with auto switching on, this key only pauses / resumes it
        $script:S.AutoWatchPaused = -not $script:S.AutoWatchPaused
        if ($script:S.AutoWatchPaused) {
            if ($script:S.Watch -and $script:S.AutoWatched) {
                $script:S.Watch = $false
                $script:S.AutoWatched = $false
                $script:S.Surface.Highlights = @()
                $script:S.Surface.Wandering = $true
            }
            Set-Status '自动盯盘已暂停，现在跟光标爬（Ctrl+Alt+W 恢复）'
            Write-Log 'auto watch paused by user'
        } else {
            $script:S.LastAutoCheck = 0
            Set-Status '自动盯盘已恢复：感应到盯盘窗口就切过去'
            Write-Log 'auto watch resumed by user'
        }
        Update-PanelList
        return
    }
    $script:S.Watch = -not $script:S.Watch
    if ($script:S.Watch) {
        $script:S.AlertSeen.Clear()
        $script:S.Surface.Wandering = $false
        Set-Status '盯盘中…（Ctrl+Alt+W 切回跟光标）'
        Write-Log 'watch mode ON'
    } else {
        $script:S.Surface.Highlights = @()
        $script:S.Surface.Wandering = $true
        Set-Status '跟光标模式（Ctrl+Alt+W 切回盯盘）'
        Write-Log 'watch mode OFF'
    }
}

function Add-Alert {
    param([string]$Text, [int]$Y, [int]$H, $Rects)

    $type = Find-AlertType -Text $Text
    $alert = @{ Text = $Text; Type = $type; At = (Get-Date); Y = $Y; H = $H; Rects = @($Rects) }
    $script:S.Alerts.Insert(0, $alert)          # newest first
    while ($script:S.Alerts.Count -gt 80) { $script:S.Alerts.RemoveAt($script:S.Alerts.Count - 1) }
    return $alert
}

function Test-AlertWanted {
    param($Alert)
    $filter = [string]$script:S.Config.alertFilter
    if ([string]::IsNullOrWhiteSpace($filter)) { return $true }
    try { return [bool]($Alert.Text -match $filter) } catch { return $true }
}

function Invoke-WatchTick {
    $now = [Environment]::TickCount
    if (($now - $script:S.LastWatchAt) -lt [int]$script:S.Config.watchIntervalMs) { return }
    $script:S.LastWatchAt = $now

    $r = $script:S.WatchRect
    $words = Get-WordsFromRegion -X $r.X -Y $r.Y -W $r.W -H $r.H -Scale ([int]$script:S.Config.watchScale)
    if (@($words).Count -eq 0) {
        Invoke-WatchPatrol -Now $now
        return
    }

    $requireType = $true
    if ($null -ne $script:S.Config.alertRequireType) { $requireType = [bool]$script:S.Config.alertRequireType }

    $candidates = @()
    foreach ($row in (Group-WordsIntoRows -Words $words)) {
        if (-not (Test-AlertRow -Text $row.Text)) { continue }
        $text = Format-AlertRow -Text $row.Text
        if ($requireType -and (Find-AlertType -Text $text).Length -eq 0) { continue }
        $candidates += @{ Text = $text; Y = [int]$row.Y; H = [int]$row.H; Rects = @($row.Rects) }
    }

    # A row only counts once it is still there on the next pass: one-off OCR garbage
    # never survives two reads, a real alert line does. On startup AlertPending is
    # empty, so the backlog already on screen is not dumped into the panel.
    $confirmed = @()
    foreach ($cand in $candidates) {
        $ok = $false
        foreach ($prev in $script:S.AlertPending) {
            if (Test-SimilarText -A $cand.Text -B $prev.Text -Threshold 0.6) { $ok = $true; break }
            if ([Math]::Abs($cand.Y - $prev.Y) -le 4) { $ok = $true; break }
        }
        if ($ok) { $confirmed += $cand }
    }
    $script:S.AlertPending = @($candidates)

    $texts = @()
    foreach ($cand in $confirmed) { $texts += $cand.Text }
    $recent = New-Object System.Collections.ArrayList
    foreach ($t in @($script:S.AlertRecent.ToArray())) { [void]$recent.Add($t) }
    $fresh = @(Get-NewAlert -Current $texts -Seen $script:S.AlertSeen.ToArray() -Recent $recent.ToArray())
    foreach ($t in $texts) {
        $script:S.AlertRecent.Add($t)
    }
    while ($script:S.AlertRecent.Count -gt 80) { $script:S.AlertRecent.RemoveAt(0) }
    foreach ($t in $texts) {
        $script:S.AlertSeen.Add((Get-NormalizedAlertKey -Text $t))
    }
    # rolling window: a panel that scrolls must not re-report what is still on screen
    while ($script:S.AlertSeen.Count -gt 200) { $script:S.AlertSeen.RemoveAt(0) }

    if ($fresh.Count -eq 0) {
        Invoke-WatchPatrol -Now $now
        return
    }

    $beep = $false
    foreach ($t in $fresh) {
        $row = $null
        foreach ($candidate in $confirmed) {
            if (Test-SimilarText -A $t -B $candidate.Text) { $row = $candidate; break }
        }
        $y = 0; $h = 12; $rects = @()
        if ($null -ne $row) { $y = [int]$row.Y; $h = [int]$row.H; $rects = @($row.Rects) }
        $alert = Add-Alert -Text $t -Y $y -H $h -Rects $rects
        if ((Test-AlertWanted -Alert $alert) -and $script:S.Config.alertBeep) { $beep = $true }
        Write-Log ("异动: " + $t)
    }
    if ($beep) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }

    $script:S.LastAlertAt = $now
    Update-PanelList

    # the spider walks onto the newest line so the eye lands there too
    $newest = $script:S.Alerts[0]
    if ($newest.Y -gt 0) {
        $script:S.Surface.TargetX = [double]($r.X - 34)
        $script:S.Surface.TargetY = [double]($newest.Y + [int]($newest.H / 2))
        $script:S.Surface.Highlights = @(
            [double]($r.X - 4), [double]($newest.Y - 3),
            [double]($r.W + 8), [double]($newest.H + 6)
        )
    }
}

function Invoke-WatchPatrol {
    <#  Nothing new for a while: keep the spider wandering slowly up and down the
        watched list so it still reads as alive and "on station". #>
    param([int]$Now)
    if ($script:S.Alerts.Count -eq 0) { return }
    if (($Now - $script:S.LastAlertAt) -lt 4000) { return }
    if ($Now -lt $script:S.NextPatrolAt) { return }
    $script:S.NextPatrolAt = $Now + 3200
    $r = $script:S.WatchRect
    $count = [Math]::Min(6, $script:S.Alerts.Count)
    $index = Get-Random -Minimum 0 -Maximum $count
    $alert = $script:S.Alerts[$index]
    if ($alert.Y -gt 0) {
        $script:S.Surface.TargetX = [double]($r.X - 34)
        $script:S.Surface.TargetY = [double]($alert.Y + [int]($alert.H / 2))
    }
}

function Update-WatchPanel {
    if ($null -eq $script:S.Ui) { return }
    $list = $script:S.Ui.List
    $list.Children.Clear()
    $shown = 0
    foreach ($alert in $script:S.Alerts) {
        if ($shown -ge 40) { break }
        $shown++
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $time = New-Object System.Windows.Controls.TextBlock
        $time.Text = $alert.At.ToString('HH:mm:ss')
        $time.Foreground = [System.Windows.Media.Brushes]::LightSkyBlue
        $time.FontSize = 12
        $time.MinWidth = 62
        $time.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = $alert.Text
        $text.FontSize = 12
        $text.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $text.MaxWidth = 250
        if ($shown -eq 1) {
            $text.Foreground = [System.Windows.Media.Brushes]::Gold
            $text.FontWeight = [System.Windows.FontWeights]::Bold
        } else {
            $text.Foreground = [System.Windows.Media.Brushes]::WhiteSmoke
        }
        $row.Children.Add($time) | Out-Null
        $row.Children.Add($text) | Out-Null
        $list.Children.Add($row) | Out-Null
    }
    $script:S.Ui.Count.Text = ("盯盘中 · " + $script:S.Alerts.Count + " 条")
    $script:S.Ui.Bar.Value = 100
}
