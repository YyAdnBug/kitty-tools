# windows/REVIEW.md：审查意见

审查方（Claude，在 Mac 上）看完代码或报告后，把要改的写在这里。agent **每一批开始前先看这里**：

- 「待修」的条目先修完，再做那一批；
- 修完把条目挪到「已修」，写上提交号和一句怎么验的；
- 不同意的，在条目下面写理由，挪到「有异议」，照常做下一批，审查方回头再看。

条目编号不复用。行号按条目里写的那个提交。

## 待修

2026-10-25 审查方看了第二版第 3–5 批（`58e62c2d`、`60ef1540`）的代码，以及 `windows-shots` 里 `0.2.0-batch-3/`、`0.2.0-batch-4-5/` 的截图。按优先级排；行号按 `60ef1540`，路径相对 `windows/KittyTools/`。

### R4（P1）设置里选的外观和系统不一样时，代码里设的颜色全是错的那一套

- **看到的**：`settings-*-dark.png` 里设置卡、下拉框、按钮都是浅灰底配白字，几乎看不清；`translate-dark.png` 的结果卡、`launcher-calc-dark.png` 计算结果的说明文字也是同一个问题。
- **根因**：`Shell/Theme.cs:101` 的 `Theme.Brush()` 用 `Application.Current.Resources.TryGetValue` 取画刷，拿到的是**应用级主题**（跟系统走）那一套，而窗口用 `RequestedTheme` 设成了另一种。截图时系统是浅色、设置里选了深色，于是取到浅色的 `CardBackgroundFillColorDefaultBrush`（70% 白），文字却是深色主题的白色。运行中切换外观时，这些在代码里设上去的画刷也不会跟着变。
- **改成**：
  - 代码里不再从 `Application.Current.Resources` 取任何**跟深浅色有关**的画刷。
  - 做法二选一：
    1. （推荐）在 `App.xaml` 里定义几个样式（设置卡、次要文字、卡片底、危险色文字……），setter 里用 `{ThemeResource …}`，代码里只设 `Style`；`ThemeResource` 会按元素自己的深浅色取值，切换时自动更新。
    2. 按元素的 `ActualTheme` 去 `XamlControlsResources` 的 `ThemeDictionaries["Light" / "Dark"]` 里取，并且在 `ActualThemeChanged` 里重新设一遍。
  - `Theme.Brush` 只留给不跟深浅色变的常量（截图 HUD、胶囊、家族色）。
  - 设置窗的标题栏也要跟着深浅色走（`AppWindow.TitleBar.PreferredTheme`，或者把内容扩进标题栏）。
- **验收**：四种组合（系统浅 / 深 × 设置里选浅 / 深）各截一套图：设置窗三页、翻译浮窗的结果卡和错误卡、启动器的计算结果、剪贴板面板；设置窗开着时切换外观，不用重开就全部变过来。

### R5（P1）轻提示和托盘菜单的宿主窗口不是透明的

- **看到的**：`notice-light.png`、`notice-dark.png`、`notice-error-light.png` 里，胶囊外面都围着一圈白色方框（深色下也是白的）。
- **根因**：`Shell/Notice.cs:144` 和 `Shell/TrayMenu.cs:154` 只调了 `DwmExtendFrameIntoClientArea`。DWM 边框扩到客户区以后，透明的地方露出的是系统的窗口底色，不是背后的桌面。
- **改成**：
  - 写一个透明的 `SystemBackdrop`：在 `OnTargetConnected` 里给 `connectedTarget.SystemBackdrop` 设一个全透明的颜色画刷。注意这个画刷要用 `Windows.UI.Composition.Compositor` 建，所以线程上要先有 `Windows.System.DispatcherQueue`（`CreateDispatcherQueueController`）。做法照 WinUIEx 的 `TransparentTintBackdrop`（MIT，只看源码，不引包），几十行。
  - 轻提示和托盘菜单的宿主窗口都用它；`XamlRoot` 的根元素背景保持透明。
  - 加了 `WS_EX_LAYERED` 之后还能不能正常画、点不点得穿，要重新实测一遍。
- **验收**：
  - 整屏截图（不裁）：浅色、深色下胶囊外面什么都没有；
  - 托盘菜单开着时，菜单外面看不到 360×480 那块宿主窗口；
  - 轻提示显示的两秒里，点它正下方照样点得到底下的窗口。

### R6（P1）剪贴板列表的标题被挤成三个字，来源显示成 WebView2

- **看到的**：`clipboard-*.png` 里，列表行右边「Microsoft Edge WebView2 · 1 小时前」占掉大半宽度，标题只剩「ZNC…」「小强-日…」。
- **改成**：
  - 左右两栏时列表窄（约 300 DIP），**标题优先**：右边只放短的时间（「1 小时前」「昨天」「10-23」），来源只在右边预览卡的卡头显示；标题至少占行宽的六成。
  - 来源：剪贴板拥有者是 `msedgewebview2.exe` 这类内嵌网页的子进程时，顺着父进程往上找第一个不是它的进程，用那个程序的名字和图标（`CreateToolhelp32Snapshot` 的 `th32ParentProcessID`；判断写成纯函数，配单测）。
- **验收**：中文、英文、数字三种长标题都能显示到行宽的六成以上；从一个用 WebView2 的程序（比如新版 Teams、Outlook、Clipchamp）复制时，来源显示的是那个程序。

### R7（P1）启动器的计算结果那一行溢出了

- **看到的**：`launcher-calc-dark.png` 里结果数字是 28 号字，行高还是 48，下面那行说明掉到了行外面（而且是 R4 的颜色问题，深色下看不清）。
- **改成**：计算结果行单独一个行高（比如 64），`PanelMetrics` 算面板高度、选中高亮的位置和高度都按每行的实际高度来；说明文字用次要文字的主题色。
- **验收**：浅色、深色各截一张计算结果；选中高亮正好盖住这一行；结果行和普通行混在一起时，上下键移动高亮的位置都对。

### R8（P1）翻译浮窗的高度没算对，最后一张卡被底栏盖住

- **看到的**：`translate-light.png`、`translate-dark.png` 里，智谱那张错误卡只露出上半截，「没有可用的智谱 API Key」被底栏挡住。
- **改成**：浮窗高度 = 顶栏 + 原文框 + 所有卡片 + 底栏，用实际排好版之后的尺寸算（卡片内容变了、错误信息换行了都要重新量）。另外按 PLAN §7.2，**设置类错误（缺密钥、401 / 403 / 404）只给「打开设置」**，不给「重试」；网络和服务类错误才给「重试」。
- **验收**：一张卡、三张卡、错误信息很长要换两行，三种情况各截一张，都完整显示、没被盖住。

### R9（P2）界面文字里不该出现给开发者看的话

- 设置 › 通用「自动检查更新」的说明写着「Windows 版的更新不标 latest」；关于页身份卡写着「剪贴板、翻译、启动器和截图都已接上；Windows 版的 release 不标 latest」。这些是给开发者看的，改成用户能懂的话（比如「每天检查一次，有新版本时提示」「剪贴板历史、翻译、启动器、截图」）。
- 0.1.0 还没发布过，它的更新日志里不要写「修：检查更新不再让全部热键失效」这类只在开发过程中出现过的问题。第一个公开版只列功能。
- 占位文字里的「...」统一换成「…」。

### R10（P2）设置窗的几处细节

- 每张设置卡左边的图标都是同一个「⇄」，没有意义。给每项换一个有含义的 Segoe Fluent Icons 图标（登录时打开 → 电源，外观 → 调色板，强调色 → 颜色，自动检查更新 → 同步 / 刷新，保留天数 → 日历，图片上限 → 图片……）；想不出合适的就去掉图标块，不要统一放同一个。
- 通用页的「打开数据目录」是飘在卡片下面的一个按钮，改成和关于页一样的卡片。
- 关于页的身份卡加上应用图标。
- 设置窗打开时，左栏第一项有一圈键盘焦点框；托盘菜单打开时第一项也有。用鼠标打开时不该出现（焦点用 `FocusState.Programmatic` 给，只有用键盘操作时才显示焦点框）。

### R11（P3）截图卡片和更新下载的小问题

- `Screenshot/ScreenshotCard.cs:303` 拖出时，在 UI 线程上 `GetFileFromPathAsync(...).GetAwaiter().GetResult()` 同步等异步调用（第二版第 1 批就在 UI 线程上这样卡死过一次）。改成 `args.GetDeferral()` + `await`。
- `%TEMP%\kitty-shots` 里拖出用的临时 PNG 从来不清理：启动时清空这个目录（同 mac：「启动时清空，用时不删」）。
- 自动更新下载时，托盘上的百分比实际出不来：`App/UpdateHttp.cs` 的 `ResponseStream.CanSeek` 是 false，`UpdateDownload.WriteAsync` 因此拿不到总大小，只会显示「正在下载…」。把 `Content-Length` 直接传进去。

### R12（P2）第 4、5 批欠的验证

报告里写了，这里列出来免得漏。系统自带的截图工具就能录屏（Win+Shift+R），不需要额外装工具。

- **剪贴板面板、启动器的高度动画**：窗口每 16 ms 改一次尺寸，Windows 上这样做常见的问题是边缘闪黑或闪白。录一段 3–5 秒的视频看；有闪就改成不做动画，直接设到新高度。
- **截图**：选区贴着屏幕下边时，工具栏要放到上方或选区里面，不能出屏；中文输入法下的原位文字；飞入卡片拖到资源管理器。
- **数字**：翻译等待动画期间的 CPU、截一次图之后的内存（按 D8）。
- **截图**：截图翻译的浮窗贴着选区出现；飞入卡片的深色版。


## 已修

### R1（第二版第 2 批，`da8cc1a9`）自动更新只认 GitHub 的 https 地址 → 已修（`58e62c2`）

- `Core/UpdateTrust.cs`：发布列表 / 下载地址的白名单纯函数；`App/UpdateHttp.cs` 自己逐跳处理跳转、
  每一跳都过白名单。`KITTY_UPDATE_FEED`、`file://`、本地路径、`http://` 只在 Debug 或 `--update-test` 下认。
- 怎么验的：`UpdateTrustTests` 8 种地址（含大小写、端口、账号密码、`github.com.evil.com`、别的仓库）全过；
  Release AOT 正常启动设 `KITTY_UPDATE_FEED` → 日志 `update.feed-ignored` + `localFeed=False`；
  带 `--update-test` → `newer=True localFeed=True` 并下载成功。

### R2（同上）更新完退出要走正常的退出流程 → 已修（`58e62c2`）

- `AutoUpdater.ExitApplication()` 调 `ShellRuntime.Instance.Exit()`（提交剪贴板删除、注销热键、删托盘图标），
  没有壳时才退回 `Application.Exit()`。
- 怎么验的：自动更新成功路径（同 `HANDTEST.md` §135）看托盘只剩一个图标；`ShellRuntime.Exit` 的
  `clipboard.ready` / `tray.added` / 热键注册在更新前后一致。

### R3（同上）下载直接写文件，不整个读进内存 → 已修（`58e62c2`）

- `Core/UpdateDownload.cs`：80 KB 一块流式写 `updates\<文件名>.partial`，写完才改名；失败 / 取消删半成品。
  托盘那一项在下载中显示「正在下载 37%」。
- 怎么验的：`UpdateDownloadTests`（成功改名、失败不留半成品、取消不留半成品、旧 .partial 被替换）；
  400 MB 假 zip 实测私有提交 91.9 → 100.6 MB（+8.7 MB，不随文件大小涨），校验失败后 `updates\` 里没有残留。

## 有异议

（还没有）
