# TL;DR Overlay — 桌面级爬蜘蛛

一只线条蜘蛛盖在整个桌面上，跟着鼠标爬过**任意程序**（浏览器、Word、PDF 阅读器、记事本…），
踩到哪段文字就读哪段，找出关键句、在屏幕上画黄色高亮，右上角浮动面板实时生成 TL;DR。

不需要装任何东西：Windows 10/11 自带的 PowerShell 5.1 + WPF + UI Automation + 系统 OCR。

## 跑起来

双击 `启动蜘蛛.cmd`。想边跑边看日志就双击 `启动蜘蛛-带日志.cmd`。

| 操作 | 快捷键 |
|---|---|
| 开关蜘蛛（关闭时屏幕完全恢复） | `Ctrl+Alt+S` |
| 退出 | `Ctrl+Alt+Q` |
| 框选盯盘区域（按两次：左上角、右下角） | `Ctrl+Alt+R` |
| 切换「盯盘 / 跟光标」 | `Ctrl+Alt+W` |

面板也可以拖动（拖标题栏），按钮：`复制 TL;DR` / `重新启动` / `关闭`。

## 盯短线精灵（盯盘模式）

把蜘蛛钉在一个固定屏幕区域上，每 ~0.9 秒把那块区域放大 3 倍 OCR 一次，**只报告新出现的行**。

**默认全自动**：平时跟光标爬任何东西；一旦被盯的那个窗口出现在那块区域里，自动切进盯盘；
切走 / 最小化 / 关掉，又自动交回跟光标模式。不用点任何开关。

自动识别位置（不用手动框）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File TldrOverlay.ps1 -DiscoverRegion
```
它 OCR 一遍同花顺窗口，找出「急速拉升 / 打开跌停板 / 涨速突破 …」这些异动类型所在的**那一列**，
把矩形写进配置。（你机器上已经识别好了：11 行异动，x=-8 y=74 276x526）

手动框也可以：
1. 鼠标移到短线精灵列表的**左上角**，按 `Ctrl+Alt+R`
2. 移到列表**右下角**，再按一次 `Ctrl+Alt+R` → 区域存进配置，自动进入盯盘
3. 之后新出现的异动会进面板（最新在最上面，金色加粗），蜘蛛会走过去踩在那一条上，画黄框

行为细节：

- 启动时会把**当前屏幕上已有的行**先收进面板（当作底稿），之后只报新增的
- 一行要被连续两次读到才算数：OCR 偶发的错字行不会进面板
- 同一行 OCR 抖一两个字（`华茂股份` / `华茂份`）按相似度去重，不会重复报
- 只有能匹配到**异动类型**的行才算异动（急速拉升 / 打开跌停板 / 涨速突破 / 猛烈打压 / 大笔买入 …），
  关掉这个限制就把 `alertRequireType` 设成 `false`
- `alertFilter` 是个正则，配合 `alertBeep: true` 可以只对关心的异动响一声，
  例如 `"alertFilter": "涨停|跌停|大笔买入"`

**实测**（你机器上的同花顺远航版，进程 `happ`）：50 秒里读到 5 条真实异动，
`华茂股份 打开跌停板 4 17`、`科马材料 急速拉升`、`中科美菱 急速拉升 1 65` …
名字偶尔会错一个字（`驰诚股份` → `驼份`），代码和数字基本准。

自检：`powershell -NoProfile -ExecutionPolicy Bypass -File test\Watch.Smoke.ps1`
（开一个内容由文件驱动的窗口当假面板，改文件后验证它**只**报新增的那一条）


## 它怎么读字

1. **UI Automation**（首选）：直接问窗口要它脚下那行的真实文字和真实包围盒——所以高亮框
   是精确的，Chrome/Edge/Word/大多数编辑器都能读。
2. **系统 OCR**（兜底）：UI Automation 给不出文字时（游戏、纯图片、画布渲染的界面），
   截取脚下区域交给 `Windows.Media.Ocr`，用 OCR 的词框画高亮。

高亮和 glitch **都是画在我们自己浮层上的**，不改动、不注入任何其他程序：关掉蜘蛛，屏幕立刻原样。

## 配置

首次运行会自动生成 `%APPDATA%\TLDROverlay\config.json`：

```json
{
  "apiKey": "",
  "model": "claude-3-5-haiku-latest",
  "speedCap": 420,
  "stepMs": 130,
  "glitch": 0.25,
  "maxWords": 9
}
```

- `apiKey` 留空 → 只用本地兜底摘要（去填充词 + 9 词截断），面板不显示 Claude 按钮。
- 填了 → 面板多出「Claude TL;DR」按钮；新发现的关键句会**批量增量**发给 Claude 生成 9 词以内的
  摘要，请求失败时保留兜底摘要并提示「AI 不可用」，蜘蛛和页面都不受影响。
- `speedCap` / `stepMs` / `glitch` 是手感旋钮：跑太快看不清就调小 `speedCap`。
- `minChars`（默认 8）：一段文字至少这么长才算「一句话」。同花顺那种满是数字格子的界面可以调到
  12~16，只留成句的内容。

## 同花顺 / 自绘界面

同花顺远航版（进程 `happ`）**能爬**，但走的是 OCR：它整个界面是一个自绘窗口，UI Automation
只暴露 1 个没有名字的节点、0 个 TextPattern，所以只能截屏识别。

实测（`test\Probe.Window.ps1 -ProcessId 11384`）：

- 6/6 采样点 OCR 都读出了文字，行情数字和代码基本准（`600663`、`XD 海螺水泥`、
  `固态电池概念`、`归属于母公司所有者的净利…`）
- 中文小字会认错（`滨江集团` → `陆滨氵工隼团`），数字、金额、百分比明显更稳

想先看某个软件能不能读：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\Probe.Window.ps1 -List        # 列出窗口和 pid
powershell -NoProfile -ExecutionPolicy Bypass -File test\Probe.Window.ps1 -ProcessId 11384
```

## 上限（说清楚，免得踩坑）

- 高亮是画上去的矩形，不是真的改别人程序的文字颜色；glitch 同理，只存在于浮层。
- 多显示器**不同缩放比例**时会用主屏比例（系统 DPI 感知）；要完美支持得换 PerMonitorV2。
- 有些软件自己就是「总在最前」（部分行情软件、播放器）：它一被激活就会盖住浮层。程序在前台窗口
  变化时会重新把自己置顶（`Set-WindowTopmost`），但那种每秒都在抢 Z 序的程序可能仍然闪。
- 页面在内部 div 里滚动时，文字跟着滚，高亮会在下一次重测时跟上（每 ~1 秒重测一次）。
- OCR 是通用识别，`l` 和 `I` 偶尔会认错；数字、金额、年份基本稳。

## 自检能证明什么（别被"全过"骗了）

| 测试 | 用真数据吗 | 证明什么 |
|---|---|---|
| `Core.Tests.ps1` | 合成数据 | 分句/打分/摘要/IK/去重/面板定位等**纯逻辑** |
| `Screen.Probe.ps1` | 真窗口、真 OCR | 读屏引擎能读真窗口（自带一个已知文字的窗口做对照） |
| `Overlay.Smoke.ps1` | 真机真屏幕 | 程序真能起来：穿透、置顶、蜘蛛在动、能读到屏幕上的字、退出无残留 |
| `Watch.Smoke.ps1` | **假文本**（自己填的涨跌文案） | 只证明**盯盘管道**：只报新增、抖动去重、两帧确认、自动开关、退出清理。**不能**证明同花顺读得准 |
| `Probe.Watch.ps1` | 真机真同花顺 | **把真实识别结果原样打出来给你自己判断** |

想看真实水平，随时跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\Probe.Watch.ps1
```
它会打印当前盯盘区域在 1x/2x/3x/4x 下的**原始 OCR 行**和面板最终会显示的文字，好坏都列。
## 自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\Core.Tests.ps1     # 35 项：分句/打分/摘要/IK
powershell -NoProfile -ExecutionPolicy Bypass -File test\Screen.Probe.ps1   # 18 项：UIA/OCR 读真实窗口
powershell -NoProfile -ExecutionPolicy Bypass -File test\Overlay.Smoke.ps1  # 33 项：起真程序从外部验
```

`Overlay.Smoke.ps1` 会真的启动蜘蛛、截屏数像素确认蜘蛛在画且在动、用 UI Automation 读面板文字、
按 `Ctrl+Alt+S`/`Ctrl+Alt+Q` 验证开关和退出，最后确认屏幕上没留东西。跑的时候桌面会被占几秒。

## 文件

```
TldrOverlay.ps1          主程序：浮层、面板、爬行循环、清理
lib\SpiderSurface.cs     蜘蛛物理 + 绘制（C#，60fps 热路径）
lib\ScreenReader.ps1     UI Automation + Windows OCR 读字
lib\Core.ps1             纯逻辑：分句/打分/选关键句/摘要/腿部 IK
lib\Win32.ps1            DPI 感知、鼠标位置、窗口样式、全局热键
```

想开机自启：`Win+R` → `shell:startup` → 把 `启动蜘蛛.cmd` 的快捷方式丢进去。
