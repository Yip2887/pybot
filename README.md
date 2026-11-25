# pybot

Two implementations of one idea: a line-art spider crawls over text with your cursor, reads what it
steps on, and builds a live TL;DR.

| Path | What |
|---|---|
| `tldr-overlay/` | Windows desktop overlay — PowerShell 5.1 + WPF, reads any app with UI Automation / built-in OCR |
| `tldr-crawler/` | Chrome extension — Manifest V3, vanilla JS, zero dependencies |
| `pybot.txt` | the original Chinese spec both were built from |

---

## 中文

### 桌面浮层版 `tldr-overlay`

零安装，只用 Windows 10/11 自带的 PowerShell 5.1 + WPF + UI Automation + 系统 OCR。
双击 `tldr-overlay\启动蜘蛛.cmd`（或仓库外的 `TLDR-Crawler.bat`）。

| 操作 | 快捷键 |
|---|---|
| 开关蜘蛛 | `Ctrl+Alt+S` |
| 框选盯盘区域 | `Ctrl+Alt+R`（鼠标到左上角按一次，再到右下角按一次） |
| 暂停 / 恢复自动切换 | `Ctrl+Alt+W` |
| 退出 | `Ctrl+Alt+Q` |

平时跟着鼠标爬任意程序；感应到目标窗口（默认同花顺进程 `happ`）出现在盯盘区域里，自动切成盯盘模式，
只报新出现的异动；窗口切走或最小化，自动交回跟光标模式。

- 读字顺序：UI Automation（精确文字+包围盒）→ 系统 OCR（放大 3 倍再识别，自绘界面靠这条）
- 配置：`%APPDATA%\TLDROverlay\config.json`（首次运行自动生成；可填 Anthropic API Key 让 Claude 压缩摘要）
- 自动定位短线精灵面板：`powershell -NoProfile -ExecutionPolicy Bypass -File tldr-overlay\TldrOverlay.ps1 -DiscoverRegion`

自检（共 143 项断言）：

```powershell
cd tldr-overlay
powershell -NoProfile -ExecutionPolicy Bypass -File test\Core.Tests.ps1     # 78 纯逻辑：分句/打分/摘要/去重/面板定位
powershell -NoProfile -ExecutionPolicy Bypass -File test\Screen.Probe.ps1   # 18 真实窗口阅读（UIA + OCR）
powershell -NoProfile -ExecutionPolicy Bypass -File test\Overlay.Smoke.ps1  # 33 真机：穿透/置顶/蜘蛛在动/退出无残留
powershell -NoProfile -ExecutionPolicy Bypass -File test\Watch.Smoke.ps1    # 14 盯盘管道（合成文本，不证明识别质量）
powershell -NoProfile -ExecutionPolicy Bypass -File test\Probe.Watch.ps1    # 打印真实 OCR 结果，准不准自己判断
```

已知限制：高亮和 glitch 都画在自己的浮层上，不改动其他程序；OCR 对中文小字不稳（异动类型基本能认，
股票名约七成准，时间列读不出）；多显示器不同缩放时按主屏比例绘制。

### Chrome 扩展版 `tldr-crawler`

`chrome://extensions` → 打开开发者模式 → 加载已解压的扩展程序 → 选 `tldr-crawler` →
在扩展选项里填 Anthropic API Key（可选，不填用本地兜底摘要）。点工具栏图标开始 / 停止。

---

## English

### Desktop overlay `tldr-overlay`

No installs: it uses the PowerShell 5.1 + WPF + UI Automation + OCR that ship with Windows 10/11.
Double-click `tldr-overlay\启动蜘蛛.cmd` (or `TLDR-Crawler.bat`).

| Action | Hotkey |
|---|---|
| spider on / off | `Ctrl+Alt+S` |
| pick the watch rectangle | `Ctrl+Alt+R` (once at the top-left corner, once at the bottom-right) |
| pause / resume auto-switch | `Ctrl+Alt+W` |
| quit | `Ctrl+Alt+Q` |

It crawls whatever is under the cursor. When the watched window (default: the 同花顺 process `happ`)
appears inside the watched rectangle, it switches to watch mode and only reports newly appeared alert
lines; when that window leaves the screen it hands back to cursor crawling.

- Reading order: UI Automation (exact text + bounding boxes) → Windows OCR (upscaled 3x before
  recognition; this is what makes self-drawn UIs readable)
- Config: `%APPDATA%\TLDROverlay\config.json` (created on first run; an Anthropic API key there makes
  Claude compress the summaries)
- Auto-locate the alert panel: `powershell -NoProfile -ExecutionPolicy Bypass -File tldr-overlay\TldrOverlay.ps1 -DiscoverRegion`

Tests (143 assertions total):

```powershell
cd tldr-overlay
powershell -NoProfile -ExecutionPolicy Bypass -File test\Core.Tests.ps1     # 78 pure logic
powershell -NoProfile -ExecutionPolicy Bypass -File test\Screen.Probe.ps1   # 18 real-window reading
powershell -NoProfile -ExecutionPolicy Bypass -File test\Overlay.Smoke.ps1  # 33 real run: click-through, topmost, spider moves, clean exit
powershell -NoProfile -ExecutionPolicy Bypass -File test\Watch.Smoke.ps1    # 14 watch pipeline (synthetic text; does NOT prove OCR quality)
powershell -NoProfile -ExecutionPolicy Bypass -File test\Probe.Watch.ps1    # dumps real OCR so you can judge accuracy yourself
```

Limits: highlights and glitch effects are drawn on our own overlay — other apps' text is never modified.
OCR on small Chinese text is imperfect (alert types mostly readable, stock names roughly 70%, the time
column is unreadable). Multiple monitors with different scale factors use the primary screen's scale.

### Chrome extension `tldr-crawler`

`chrome://extensions` → enable Developer mode → Load unpacked → pick `tldr-crawler` → set the Anthropic
API key in the extension options (optional; local fallback summaries work without it). Click the toolbar
icon to start / stop.

---

## Layout

```
tldr-overlay/
  TldrOverlay.ps1        main app: overlay, panel, crawl loop, hotkeys, cleanup
  lib/SpiderSurface.cs   spider physics + rendering (C#, 60fps hot path)
  lib/ScreenReader.ps1   UI Automation + Windows OCR
  lib/Core.ps1           pure logic: sentences, scoring, summaries, IK, alert rows
  lib/Watch.ps1          watch mode: region picking, auto-switch, panel discovery
  lib/Win32.ps1          DPI awareness, cursor, window styles, global hotkeys
  test/                  five test scripts (see above)
tldr-crawler/
  manifest.json          MV3
  content.js             spider, scanning, highlight, glitch, panel, teardown
  core.js                pure helpers shared with the desktop version
  background.js          toolbar toggle + the only place that calls the Anthropic API
  options.html/js        API key + model
```
