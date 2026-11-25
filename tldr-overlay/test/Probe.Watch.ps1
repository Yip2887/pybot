# TL;DR Overlay - Probe.Watch.ps1
# Shows EXACTLY what the watcher sees on the real screen: captures the watched
# rectangle and prints every row it would report, at several upscale factors, with
# the raw OCR text kept side by side with what the panel would display.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test/Probe.Watch.ps1
#   ... -X 92 -Y 450 -W 230 -H 260 -Scales 1,2,3,4

param(
    [int]$X = -1,
    [int]$Y = -1,
    [int]$W = 0,
    [int]$H = 0,
    [string]$Scales = '1,2,3,4',
    [string]$ConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Win32.ps1')
. (Join-Path $root 'lib\Core.ps1')
. (Join-Path $root 'lib\ScreenReader.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $env:APPDATA 'TLDROverlay\config.json' }
if ($X -lt 0 -and (Test-Path -LiteralPath $ConfigPath)) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $X = [int]$cfg.watchX; $Y = [int]$cfg.watchY; $W = [int]$cfg.watchW; $H = [int]$cfg.watchH
    Write-Host ("region from config: " + $X + "," + $Y + " " + $W + "x" + $H + "  (target: " + $cfg.watchProcess + ")")
}
if ($W -lt 40 -or $H -lt 30) { Write-Host 'no region: pass -X -Y -W -H'; exit 1 }

$cx = $X + [int]($W / 2); $cy = $Y + [int]($H / 2)
$pidAt = Get-WindowAtPoint -X $cx -Y $cy
$name = '?'
try { $name = (Get-Process -Id $pidAt -ErrorAction Stop).ProcessName } catch { }
Write-Host ("what is actually on screen at the region centre right now: pid " + $pidAt + " [" + $name + "]")
Write-Host ("captured at " + (Get-Date -Format 'HH:mm:ss'))
Write-Host ''

foreach ($scale in ($Scales -split ',')) {
    $s = [int]$scale.Trim()
    if ($s -lt 1) { continue }
    $words = Get-WordsFromRegion -X $X -Y $Y -W $W -H $H -Scale $s
    $rows = @(Group-WordsIntoRows -Words $words)
    $shown = @($rows | Where-Object { Test-AlertRow -Text $_.Text })
    Write-Host ("=== upscale x" + $s + "  (" + @($words).Count + " words -> " + $shown.Count + " rows) ===")
    foreach ($row in ($shown | Sort-Object Y)) {
        $type = Find-AlertType -Text $row.Text
        $nice = Format-AlertRow -Text $row.Text
        $flag = if ($type.Length -gt 0) { 'ALERT:' + $type } else { '(not an alert row)' }
        Write-Host ("  y" + ([int]$row.Y).ToString().PadLeft(4) + "  raw='" + $row.Text + "'")
        Write-Host ("         panel shows: '" + $nice + "'   " + $flag)
    }
    Write-Host ''
}
