# Kitty Tools Windows 原生版方案（第一版）

2026-10-23 立项。选型和范围用户已拍板（「都按照你的建议来」）：C# + WinUI 3，第一版只做剪贴板、翻译、启动器、截图四样。
实现由用户的 agent 按本文分批做，每批做完停下，交给 Claude（在 Mac 上）审查。本文就是规格；和 mac 版的规则冲突时以本文为准。

## 0. 怎么用这份文档

- **一批一停**：构建通过、单测通过、自己手测过 → 提交 → 推到 `windows-wip` → 停下等审查。审查意见改完再开下一批。
- **提交正文就是这批的报告**：做了什么、怎么验的、量到的数（第 0、1、5 批必须有）、和本文不一样的地方及原因、没解决的问题（「待定」）。界面截图（浅色 + 深色）放 `windows/build/shots/<批次>/`，不入库，报告里列出文件名。
- **规格的来源，按先后**：本文 → 本文点名的 mac 规则章节和源码（**只当行为规格读**，实现照 Windows 的做法；里面的 AppKit / Carbon / 钥匙串细节一律不搬）→ 对标产品。
- **拿不准的系统行为**：先查微软文档（learn.microsoft.com），或看 PowerToys 源码怎么做（MIT，github.com/microsoft/PowerToys：启动器、识字、取色、剪贴板都有现成写法）；查不到写进报告的「待定」，不自己发明。
- 写着「第 0 批验证」的地方以实测为准；实测推翻了就在报告里写清楚，审查时一起改本文。

## 1. 范围

### 第一版做

| 模块 | 内容 |
|---|---|
| 壳 | 托盘图标和菜单、全局热键、浮层窗口、粘贴回原窗口、轻提示、设置窗、首次运行欢迎、单实例、开机启动、检查更新、日志 |
| 剪贴板 | 记录文本（带格式）/ 图片 / 文件，隐私过滤，搜索，收藏，粘贴回原窗口，删除和撤销，保留天数和图片占用上限，暂停记录 |
| 翻译 | 划词、输入、截图、复制即译四个入口；智谱（内置免费）、AI 服务（OpenAI 兼容 / Anthropic / Azure，带厂商预设）、微软（免 key）、DeepL、Google；流式输出 |
| 启动器 | 应用（含商店应用）、系统设置页、系统命令、计算、网址和路径直达、网页搜索、`cb` / `fy` 两个关键词、本 App 自己的动作；按使用频率排序 |
| 截图 | 冻结帧框选、窗口吸附、放大镜取色、5 种标注、复制 / 快速保存 / 另存为、钉图、识字、截图翻译 |

### 第一版不做

录屏录音、状态屏、便签、启动台、程序坞预览、同步、设置导出导入、自动备份；剪贴板的收藏夹 / 片段 / 备注 / 多选 / 拖出 / 链接预览 / 图片识字搜索 / 固定面板；翻译历史、查词、朗读、替换原文，百度 / 有道 / 火山 / 腾讯四家；启动器的文件搜索、浏览器书签和历史、进程和端口、收藏；长截图、截取上次区域、截图飞入动画、截图后的常驻缩略图。

不为这些预留接口、空文件或设置项。

## 2. 技术栈与约束

- **.NET 10（LTS）+ C# 14 + WinUI 3**（Windows App SDK 2.x 当前稳定版，写本文时是 2.5.1）。**Native AOT 从第一天就开**，不要最后再补。
- **不打 MSIX**：`WindowsPackageType=None` + `WindowsAppSDKSelfContained=true`。发布物是一个 zip，解压就能用。
- **只支持 Windows 11 22H2（10.0.22621）及以上**，出 x64 和 ARM64 两个包。
- **依赖只用微软自家的包**：Windows App SDK、`Microsoft.Windows.CsWin32`（生成 Win32 / COM 声明）、`Microsoft.Graphics.Win2D`（截图画布）、`MSTest.Sdk`（单测）。托盘图标、SQLite、JSON、HTTP 都自己写或用 .NET 自带的。要加别的包，先在报告里说明理由，审查同意再加。
  - Windows App SDK 先用聚合包 `Microsoft.WindowsAppSDK` 跑通。第 0 批对比「只引组件包」（WinUI、Foundation、InteractiveExperiences、Runtime 这类）的发布目录：聚合包会带进用不到的 AI / ML 原生库（onnxruntime、DirectML）的话，改成只引组件包，几个组件包的版本保持配套。
- **AOT 规矩**：应用工程开 `PublishAot`，Core 开 `IsAotCompatible`（两样都会打开 trim / AOT 分析），**发布构建零 trim / AOT 警告**。
  - JSON 一律用 `System.Text.Json` 源生成（`JsonSerializerContext`）。
  - 不用反射、`dynamic`、运行时 COM 互操作（`[ComImport]` 那套）。COM 走 CsWin32 生成的、AOT 能用的写法，具体配置第 0 批定。
  - 窗口过程用 `[UnmanagedCallersOnly]` 静态方法 + 函数指针，不用委托封送。
  - XAML 绑定只用 `x:Bind`，不用 `{Binding}`。
- **SQLite 用系统自带的 `winsqlite3.dll`**：自己写 `[LibraryImport]` 的十来个函数（open_v2、prepare_v2、bind_*、step、column_*、finalize、exec、errmsg、busy_timeout、close），一个文件。库开 WAL；连接只在 UI 线程用（同 mac 版）。
- **线程**：界面、数据库、剪贴板读写在 UI 线程（DispatcherQueue）。网络、图片编解码、识字、扫描应用目录放后台，结果用 `DispatcherQueue.TryEnqueue` 回 UI 线程。UI Automation 取词放在专门的 MTA 线程上（UIA 客户端不要在 UI 的 STA 线程上调）。

### 2.1 开发环境

- Windows 11（真机，或 Mac 上 Parallels 里的 Windows 11 ARM：能编 x64 和 ARM64，x64 靠模拟跑）。热键、多屏、缩放比例、截图这些最后要在真机上过一遍。
- Visual Studio 2026（或 2022 17.14 以上）：勾「.NET 桌面开发」「WinUI 应用开发」，**另勾「使用 C++ 的桌面开发」（含 x64 和 ARM64 生成工具）**：Native AOT 要用 MSVC 链接器，不装发布会失败。
- .NET 10 SDK、Git。Windows App SDK 走 NuGet，不用另装运行时。

## 3. 和 mac 版的关系

- 同一仓库的 `windows/` 目录。**不共享代码，共享规格**。数据、设置、凭据和 mac 版互不相通，不做导入。
- 界面文案不提其他产品（不写「像 xx 一样」）。
- **能直接照搬的纯函数**：连单测一起移植，Swift 测试里的期望值原样搬过来。

| 内容 | mac 源码（`macos/KittyTools/` 下） | mac 单测（`macos/KittyToolsTests/` 下） |
|---|---|---|
| 搜索（分词、折叠、只过滤不排序） | `Clipboard/Search.swift` | `SearchTests.swift` |
| 敏感文本过滤 | `Clipboard/ClipboardFilter.swift` | `ClipboardFilterTests.swift` |
| 识字分段、接行 | `Clipboard/OCR.swift` 的 `paragraphs`、`joiningLines` | grep `paragraphs` |
| 语言解析 | `Translate/Language.swift` 的 `Lang.resolve`（检测见 §7.1） | `TranslateTests.swift` |
| 流式文本、SSE | `Translate/SSE.swift`、`Translate/HTTP.swift`（`StreamingText`） | `TranslateTests.swift` |
| AI 地址补全、max_tokens、关思考分档 | `Translate/Providers/AIService.swift`、`Zhipu.swift` | `TranslateTests.swift` |
| 微软免 key、DeepL、Google | `Translate/Providers/RESTProviders.swift`、`CloudProviders.swift` | `TranslateTests.swift` |
| 启动器匹配和排序 | `Launcher/LauncherMatch.swift` | `LauncherTests.swift` |
| 网址 / 路径直达 | `Launcher/DirectItems.swift`（路径规则换成 Windows 的） | `LauncherTests.swift` |
| 计算 | `Launcher/Calculator.swift`（第一版只要四则、括号、乘方、百分号） | `LauncherTests.swift` |
| 选区几何（比例、中心、吸附、像素换算） | `Screenshot/RegionSelector.swift` | `SelectionGeometryTests.swift` |
| 版本号和发布筛选 | `App/Updater.swift` | `UpdaterTests.swift` |

- **只读行为的规则章节**（在 `.cursor/rules/` 下）：mac-clipboard §1–§3（数据、采集顺序、搜索），mac-translate §1–§5（语言、服务、接口约束、流式和取消、入口），mac-overlay-panel §2（自动隐藏和 Esc）、§6（划词时序）、§8（截图框选）。讲 AppKit 的部分跳过。

## 4. 架构与文件

```
windows/
├── AGENTS.md  CLAUDE.md  PLAN.md
├── HANDTEST.md                 # 手测条目（第 1 批建，每批追加）
├── KittyTools.slnx
├── Directory.Build.props       # 版本号、Nullable、警告即错误、AOT 分析
├── Secrets.props.example       # 内置智谱 key 的模板；真的 Secrets.props 不入库
├── build-release.ps1           # AOT 发布 x64 + ARM64 → zip → 发布说明
├── tools/                      # （已有）在 Mac 上跑的两个生成脚本：pinyin-table.swift（拼音表）、app-icon.swift（应用图标）
├── KittyTools/                 # WinUI 3 应用
│   ├── App/         App.xaml、Program.cs（入口、单实例）、Paths.cs、Log.cs、Tray.cs、Updater.cs
│   ├── Shell/       MessageWindow.cs（隐藏窗口：热键、剪贴板监听、托盘回调）、HotKeys.cs、OverlayWindow.cs（浮层基类）、
│   │                Foreground.cs（记前台、还前台、判断管理员窗口）、Paster.cs（写剪贴板、发 Ctrl+V / Ctrl+C）、
│   │                Notice.cs（轻提示）、Theme.xaml（颜色和字号）、Motion.cs（弹簧）
│   ├── Storage/     Sqlite.cs、Database.cs（建表和迁移）、Settings.cs（JSON 偏好）、Credentials.cs（凭据管理器）
│   ├── Clipboard/   ClipboardWatcher.cs、ClipboardFormats.cs（各格式读写）、ClipboardStore.cs、ImageStore.cs、ClipboardPanel.xaml
│   ├── Translate/   TranslateService.cs、Providers/（Zhipu、AIService、Microsoft、DeepL、Google）、SelectionReader.cs、
│   │                TranslateCoordinator.cs、TranslatePanel.xaml
│   ├── Launcher/    AppCatalog.cs、SystemCommands.cs、SettingsPages.cs、WebSearch.cs、LauncherUsage.cs、LauncherPanel.xaml
│   ├── Screenshot/  ScreenCapture.cs（冻结帧）、WindowList.cs（吸附目标）、SelectionOverlay.xaml、Annotation.cs、
│   │                PinWindow.cs、Ocr.cs、ScreenshotOutput.cs
│   ├── Settings/    SettingsWindow.xaml + 各页
│   ├── Resources/   changelog.json、AppIcon.ico（已有）
│   └── NativeMethods.txt、app.manifest
├── KittyTools.Core/            # 纯逻辑：net10.0，不引 WinUI 和 Windows API，全部能单测
│   ├── Search、SensitiveText、OcrText、Lang、StreamingText、Sse、AIEndpoint、LauncherMatch、Pinyin、Calculator、
│   │   DirectItems、RegionMath、HotKeyRules、ReleaseInfo …
│   └── Resources/pinyin.txt    # （已有）拼音表，嵌入资源
└── KittyTools.Tests/           # MSTest，只测 Core
```

文件名是建议，一个概念一个文件；没用到的不预建。

## 5. 壳（第 1 批）

### 5.1 进程和数据

- **单实例**：命名互斥量 `Local\KittyTools`（Debug 版 `Local\KittyTools.Dev`）。第二个实例把「打开设置」转给第一个，然后自己退出。
- **数据目录**：`%LOCALAPPDATA%\KittyTools\`，Debug 版 `%LOCALAPPDATA%\KittyTools.Dev\`。两版的数据、设置、凭据前缀全部分开，可以同时装；同时运行时热键会互相占用（后启动的那个标红）。目录里有 `kitty.sqlite3`、`images\`、`settings.json`、`logs\`。
- **设置**：`settings.json`，带 `"version"` 字段，源生成序列化。写入走「写临时文件 → `File.Replace`」；读不出来时把原文件改名成 `settings.broken-<时间>.json`，然后用默认值启动，不崩。
- **日志**：`logs\kitty-YYYYMMDD.log`，留 7 天。**不写剪贴板内容、原文、译文、URL、请求头、密钥**（同 mac 版）。
- **开机启动**：写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值是当前 exe 的完整路径（带引号）；设置 › 通用里有开关。
- **首次运行**（同 mac 版的首次引导）：没有设置文件时直接打开设置窗，通用页顶上一块欢迎：Kitty Tools 在托盘里运行（Windows 11 默认把新图标收进「^」溢出区，告诉用户可以拖出来）、几个主要快捷键、「登录时自动打开」勾选框（默认勾上，点「开始使用」时生效）。默认勾的理由同 mac 版：不开机自启的话，重启后快捷键全都没反应。

### 5.2 隐藏窗口和托盘

- 建一个**隐藏的顶层窗口**，收热键 `WM_HOTKEY`、剪贴板 `WM_CLIPBOARDUPDATE` 和托盘回调。在 UI 线程上建，WinUI 的消息循环会把消息派发给它。不要用 `HWND_MESSAGE`：消息专用窗口收不到 `TaskbarCreated` 广播。
- **托盘**：`Shell_NotifyIcon`（`NOTIFYICON_VERSION_4`），图标就是应用图标（Windows 托盘的习惯是彩色应用图标，不分深浅色），按当前 DPI 用 `LoadIconWithScaleDown` 取合适的那一档。资源管理器重启时（`RegisterWindowMessage("TaskbarCreated")`）重新加。
  - 左键、右键都弹同一个菜单（`TrackPopupMenuEx`）。弹之前先 `SetForegroundWindow(隐藏窗口)`，不然点菜单外面菜单不消失。
  - 菜单项：剪贴板历史、启动器、输入翻译、截图、截图翻译、识字 ｜ 复制即译 ✓、暂停记录剪贴板 ✓ ｜ 设置…、检查更新、退出。菜单项右边写当前快捷键（文字里用 `\t` 分隔）。
  - ponytail：Win32 菜单没有公开的深色模式接口，第一版接受浅色菜单，不调 uxtheme 的未公开序号。
- 图标已经做好：`KittyTools/Resources/AppIcon.ico`（16–256 八档，从 mac 版的应用图标打包，脚本 `windows/tools/app-icon.swift`，在 Mac 上跑）。exe 图标、托盘、设置窗标题栏都用它。

### 5.3 全局热键

- 用 `RegisterHotKey`，带 `MOD_NOREPEAT`。注册失败 = 被别的程序占了：设置 › 快捷键里那一行标红「被占用」，托盘菜单里不写这个键。Windows 能查出跨进程冲突（mac 查不出），要用上。
- **录制规则**写成纯函数 `HotKeyRules`，配单测：
  - 至少带一个 Ctrl 或 Alt，或者单独一个 F1–F24；
  - 不收 Win 键组合（系统保留；ponytail：真要支持再换低级键盘钩子）；
  - 拒绝通用键：Ctrl+C / V / X / Z / Y / A / S / F / W / T / N / P、Alt+F4、Alt+Tab、Alt+Esc、Ctrl+Esc。被拒时说明原因。
- **默认键**（都能改）：

| 动作 | Windows 默认 | mac | 为什么不一样 |
|---|---|---|---|
| 剪贴板历史 | Alt+C | ⌥C | |
| 启动器 | Alt+Space | ⌥Space | 主流启动器的习惯；代价是盖掉窗口左上角的系统菜单 |
| 划词翻译 | Alt+E | ⌥D | Alt+D 是浏览器和资源管理器「跳到地址栏」，不能占 |
| 输入翻译 | Alt+T | ⌥T | |
| 截图翻译 | Alt+S | ⌥S | |
| 截图 | Alt+X | ⌥A | Alt+A 是微信截图的默认键，国内用户大多开着微信，抢不到也不该抢 |
| 识字 | Alt+O | ⌥O | |

- 截图框选期间暂停全部热键，结束后恢复（同 mac §8）。

### 5.4 浮层窗口 OverlayWindow

剪贴板面板、启动器、翻译浮窗共用一个基类（同 mac「浮层只有一种」）。截图遮罩和钉图另写。

- **窗口**：WinUI `Window` + `OverlappedPresenter`：没有标题栏、**保留边框**、不能改大小 / 最大化 / 最小化、置顶；`ExtendsContentIntoTitleBar`；`AppWindow.IsShownInSwitchers = false`（不进任务栏和 Alt+Tab）。保留边框是为了拿到系统给的圆角、阴影和细描边（Windows 11 浮出层的样子）。第 0 批确认没有多出来的标题栏条。
- **材质**：亚克力。写一个 `SystemBackdrop` 子类，里面用 `DesktopAcrylicController` 并自己给 `SystemBackdropConfiguration`，`IsInputActive` 一直设 true、`Theme` 跟着当前深浅色。不用 XAML 自带的 `DesktopAcrylicBackdrop`：它跟着窗口激活状态走，窗口不在前台时亚克力变成纯色，复制即译「只露出、不激活」时就是这样。
- **位置**：剪贴板面板和启动器在鼠标所在屏、工作区顶边往下 20% 处，宽 720（DIP），高度随内容（最高 520），伸缩时顶边不动。两块在同一位置，只开一个（打开一个就收起另一个，同 mac §2）。翻译浮窗见 §7.5。
- **显示**：先记下前台窗口（不是自己的才记）→ 显示 → `SetForegroundWindow` → `Activate`。拿不到前台（返回 false）时用「先发一次 Alt 按下抬起再试」的老办法。第 0 批验证从热键回调里能不能直接拿到。
- **入场**：透明度 0→1（0.12 s）+ 内容下落 6 px（弹簧 0.24 s / bounce 0.12）。系统关了动画效果时只淡入。
- **关闭**：
  - Esc、再按一次热键、Ctrl+W：收起，并把前台还给记下的窗口（窗口还在、看得见才还）。
  - 点到别处（窗口失去激活）：收起，不还前台（用户已经点到别处了）。
  - 程序收起（粘贴前、打开设置、两块面板互斥）：立刻隐藏，没有动画。
- **收起后的窗口**留着复用。收起后占多少内存第 0 批量：超过 15 MB 的改成收起两分钟后销毁、下次再建。
- **翻译浮窗**：失去激活时收起；固定后（图钉或 Ctrl+P）点别处不收；固定着按 Esc 照样收（mac §2）。
- **只露出不激活**（复制即译）：用 `ShowWindow(SW_SHOWNOACTIVATE)`。这时窗口收不到「失去激活」，所以露出期间装一个 `WH_MOUSE_LL` 钩子判断点在了外面，收起就卸。钩子回调里只做判断，别做耗时的事（系统对低级钩子有超时）。

### 5.5 粘贴回原窗口 Paster

顺序：收起面板 → `SetForegroundWindow(记下的窗口)`，等到 `GetForegroundWindow()` 就是它（最多 100 ms）→ 写剪贴板 → 等修饰键松开 → `SendInput` 发 Ctrl+V。

- **自家写入不记**：写完记下 `GetClipboardSequenceNumber`，剪贴板监听收到同一个序号就跳过（同 mac 的 `ownChangeCount`）。本 App 自己生成、要进历史的内容（截图、译文、识出的字、计算结果）显式调 `ClipboardStore.Record`。
- **修饰键**：热键里的 Alt / Shift 可能还按着（划词时尤其），这时直接发 Ctrl+V 会变成 Ctrl+Alt+V。
  - 先轮询 `GetAsyncKeyState`，等 Ctrl / Alt / Shift / Win 都松开，最多等 300 ms；还按着就先补发它们的抬起。
  - 补发 Alt 抬起之前，先发一次未分配虚拟键 vkE8 的按下和抬起，免得目标窗口把单独一个 Alt 当成「激活菜单栏」。
- **管理员窗口**：目标进程是以管理员身份运行的、本 App 不是时，`SendInput` 会被系统悄悄拦掉，返回值和错误码都看不出来。
  - 所以先判断（`OpenProcess` + `GetTokenInformation(TokenElevation)`）：是的话只写剪贴板，轻提示「已复制 · 目标窗口以管理员身份运行，请手动粘贴」。
  - 取词时发 Ctrl+C 之前也一样先判断。
- 某个应用实测粘不进去，才为它单独加延迟，用 `ponytail:` 注释写明是哪个应用。

### 5.6 轻提示 Notice

mac 的「刘海岛」在 Windows 上的样子。

- 位置：鼠标所在屏、工作区顶部居中、往下 12 px。
- 样子：一条深色圆角条（系统圆角），图标 + 标题 + 一行详情，停 2 s 自己收起。新的一条原地替换旧的。
- 不抢焦点、不接鼠标（`WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW`，`SW_SHOWNOACTIVATE`）。
- 三种语气：普通、警告（橙）、错误（红）。
- 全 App 的结果提示（已复制、已保存、出错、缺识字组件）都走它。

### 5.7 设置窗

- 普通窗口（有标题栏、任务栏有图标），`MicaBackdrop`，左侧 `NavigationView`：通用、快捷键、剪贴板、翻译、启动器、截图、关于。
- **通用**：首次运行欢迎（§5.1）、开机启动、外观（跟随系统 / 浅色 / 深色）、强调色（品牌粉 / 跟随系统）、自动检查更新。
- **快捷键**：全部动作一张表，点一下开始录制（§5.3 的规则），可以清空，被占用的标红。
- **关于**：版本、更新日志（读 `changelog.json`）、检查更新、打开数据目录。
- 其它页在各模块那批里补。
- 再运行一次 exe（单实例转发过来）= 打开设置。

### 5.8 外观：Whisker 在 Windows 上

品牌留下，皮肤换成 Fluent。

- **强调色**：默认品牌粉 `#FF4D7E`；浅色背景上的强调文字用深一档的 `#D12A5F`（同 mac 版）。设置里可以换成「跟随系统强调色」。
  - 做法：启动时覆盖 `SystemAccentColor` 和 Light1–3 / Dark1–3 这几个资源，WinUI 控件会自动跟着变。
  - 理由：mac 版默认「跟随系统」，而 macOS 默认的「多色」就是品牌粉，所以大多数 mac 用户看到的是粉色；Windows 的系统强调色默认是蓝色，照搬「跟随系统」就把品牌丢了。
- **表面**：浮层用亚克力、设置窗用 Mica；浮层里的卡片、选中、输入框只用主题里的填充色（`CardBackgroundFillColorDefaultBrush`、`SubtleFillColorSecondaryBrush` 这类），不再叠一层亚克力。
- **圆角、字号、图标**：一律用 WinUI 主题资源（`ControlCornerRadius`、`OverlayCornerRadius`、Segoe UI Variable 的字号梯度、Segoe Fluent Icons），不写死数字。例外：剪贴板和启动器的搜索框字号 20、高 56（同 mac 版）。
- **颜色只标「现在该操作的东西」**（mac-whisker §1 原则 2）：列表选中用中性填充；功能家族色只用在图标块上——剪贴板蓝、启动器紫、截图粉、翻译绿。
- **动效**：mac 的七条弹簧（`macos/KittyTools/Shell/Style.swift` 的 `Motion`）换成 Composition 的 `SpringScalarNaturalMotionAnimation` / `SpringVector3NaturalMotionAnimation`，`DampingRatio = 1 − bounce`、`Period = duration`（近似换算，做出来肉眼对一下）。和精度有关的（拖选区、放大镜跟随、按键连发、结果刷新）一律不做动画。`UISettings.AnimationsEnabled` 为 false 时只留淡入淡出。
- **第一版保留的招牌时刻**：面板入场；截图悬停时洞和高亮框在窗口之间滑过去（mac S5）。不做：截图飞入、彗星边框、扫光、按住 Ctrl 时键帽依次出现。
- **无障碍**：只有图标的按钮都设 `AutomationProperties.Name`；全键盘可用；颜色走主题资源，高对比度主题下自动换成系统色（别写死颜色）。

## 6. 剪贴板（第 2 批）

### 6.1 采集

收到 `WM_CLIPBOARDUPDATE`（隐藏窗口上 `AddClipboardFormatListener`）后按顺序：

1. 序号是自家写入的 → 跳过。
2. **隐私格式**：有 `ExcludeClipboardContentFromMonitorProcessing`、`Clipboard Viewer Ignore`，或 `CanIncludeInClipboardHistory` 的值是 0 → 跳过。密码管理器用这些标记。
3. **来源**：`GetClipboardOwner` → 所属进程的 exe；拿不到时用当时的前台窗口（推测值）。在本 App 自己的窗口里复制的没有来源，也不触发复制即译。
4. **排除应用**：按 exe 名，不分大小写；默认 `KeePass.exe`、`KeePassXC.exe`、`1Password.exe`、`Bitwarden.exe` → 跳过。
5. **内容**：文件（`CF_HDROP`）→ 文本（`CF_UNICODETEXT`，另存 `HTML Format` 和 `Rich Text Format`，各不超过 2 MB，超了只留纯文本）→ 图片（优先 `PNG` 格式，没有就读 `CF_DIBV5` / `CF_DIB` 转成 PNG）。

- `OpenClipboard` 失败（别的程序占着）就隔 30 ms 重试，最多 5 次。读格式可能触发对方的延迟渲染，所以只读要用的那几种。
- 敏感文本过滤照搬 mac（`SensitiveText`，默认开）。
- 启动时不记剪贴板里原有的内容。
- 暂停记录（托盘菜单）：不存盘，重启后恢复记录。

### 6.2 存储

- 表 `clips`：id、kind（text / image / files）、text（纯文本；文件类是路径用换行拼起来）、html、rtf（这两列只在粘贴时读）、image_hash、width、height、source_exe、source_name、copied_at（Unix 毫秒，INTEGER）、favorite。
  - 列表按 `copied_at DESC, rowid DESC` 读。
  - 版本记在 `PRAGMA user_version`；迁移只在 `Database.Migrate` 里加，幂等，配单测。
- 图片存 `images\<id>.png`，按 PNG 字节的 SHA-256 去重；编码放后台。
- 同样的内容再复制一次 = 原条目挪到最前（保留 id 和收藏），格式以最近这次为准（mac §1）。
- **保留**：保留天数 1 / 7 / 30 / 90 / 365 / 永久（默认 7）；图片占用上限默认 512 MB，从最旧的普通图片删起，最新的一张这一轮不删；收藏的不受这两条影响。启动时和每次收起面板时清理；`images\` 里库中已经没有的图片顺手删掉。
- **搜索**照搬 mac §3：空白分词、全部命中（AND），不分大小写 / 全半角 / 变音符号，搜正文和来源；**只过滤不排序**，结果保持时间从新到旧。每条的折叠文本缓存在内存里，5000 条搜一次应该在 10 ms 量级。

### 6.3 面板

- **布局**（宽 720）：顶上 56 高的搜索框，左边两枚范围胶囊「全部 / 收藏」；下面左边是列表（按天分组：今天 / 昨天 / 日期），右边是预览（文本全文可以滚动、图片等比缩放并标尺寸、文件列表）；底栏 36 高：条数或提示 ｜ 粘贴 Enter · 更多 右键 ｜ 齿轮（打开设置 › 剪贴板）。
  - 和 mac 不一样：mac 是单列 + 选中行下面展开的「透镜」。WinUI 的 ListView 做变高展开行代价大，第一版用左右两栏。
- 焦点一直在搜索框，方向键由搜索框转给列表。
- **按键**：

| 键 | 行为 |
|---|---|
| Enter / 双击 | 粘贴（保留格式） |
| Shift+Enter | 粘贴为纯文本 |
| Ctrl+1–9 | 粘贴第 N 条 |
| Ctrl+C | 只复制；搜索框里选中了字时交还给搜索框 |
| Ctrl+D | 收藏 / 取消收藏 |
| Delete | 光标在搜索词末尾（往后没字可删）时删除选中的条目，不确认；否则照常删字 |
| Ctrl+Z | 撤销删除。收起面板之前可以连着撤，收起时才真的删 |
| Ctrl+T | 翻译这条（文本） |
| Tab / Shift+Tab | 范围在 全部 ↔ 收藏 之间切换 |
| Esc | 先清空搜索词，再按关闭面板 |

- **右键菜单**：粘贴、粘贴为纯文本、复制、收藏、翻译（文本）、钉到屏幕（图片）、在资源管理器中显示（文件）、删除。名字、顺序和按键一一对应。
- **每次收起都复位**：搜索词、范围、选中回到第一条，提交删除（mac §4 最后一条）。
- **粘贴前先查条目还能不能用**：图片文件丢了、文件全都被移走了，就不写剪贴板、不粘，轻提示「没能粘贴」。
- **写剪贴板**：文本写 `CF_UNICODETEXT`（保留格式时再加 HTML / RTF）；图片同时写 `PNG` 和 `CF_DIBV5`；文件写 `CF_HDROP` + `Preferred DropEffect`（复制）。

## 7. 翻译（第 3 批；截图翻译在第 5 批）

### 7.1 语言

- 第一语言默认简体中文、第二语言默认英语（设置 › 翻译可改）。浮窗顶上「源 → 目标」两枚胶囊：源 = 自动 / 固定，目标 = 自动 / 固定，中间是交换按钮。解析规则照搬 mac-translate §1 的 `Lang.resolve`。
- **检测**（Windows 没有 NaturalLanguage），按书写系统数字符：
  - 有假名 → 日文；有谚文 → 韩文；汉字 → 中文（简繁不细分，按第一 / 第二语言里那一种）；西里尔字母 → 俄文；
  - 中日韩文夹英文词时照 mac 那条：CJK 字数 ≥ 拉丁词数就只看 CJK 部分；
  - 拉丁字母一律当英文；纯数字 / 符号返回空。
  - 源是自动时请求里不传 `from`，让服务自己识别。
  - ponytail：拉丁字母的语言不细分。第一、第二语言都是拉丁字母语言时，再接系统的 ELS 语言识别（`MappingRecognizeText`）。

### 7.2 服务

- **列表** = 卡片顺序，默认只有智谱（启用）。「添加」菜单：还没加的内置服务 ｜ AI 服务（厂商预设：OpenAI、DeepSeek、通义千问、Kimi、硅基流动、OpenRouter、Gemini、Anthropic、Ollama，外加自定义 OpenAI 兼容、Azure OpenAI）。新建的 AI 服务默认关，详情页里「测试连接」成功就自动启用；即改即存，没有「保存」按钮（mac §2）。
- **分发只有一个 `switch`**（mac §2）：加服务 = 一个 Provider 文件 + 一个 case，不建 registry、factory、接口。
- **接口约束**全部照 mac-translate §3：
  - 智谱 `max_tokens` 不超过 1024，必须传 `thinking: {type: "disabled"}`，模型两档 glm-4-flash / glm-4.7-flash；
  - 截断检测；AI 地址补全；max_tokens 分档；关思考分档（只有 400 / 422 才降一档）；
  - OpenCode 的两个请求头；本机 / 局域网地址超时 180 s，其余 30 s；
  - 微软免 key 走 `translatetext`；DeepL 的语言码和 `:fx`。
- **错误**给中文，分两种（mac §3「错误种类」）：设置问题（橙卡，按钮「打开设置」直达这个服务）、网络或服务问题（红卡，按钮「重试」）。日志和错误信息里不出现 URL、请求头、密钥。
- **密钥**只进凭据管理器（`CredWrite` / `CredRead`，`CRED_TYPE_GENERIC`，`CRED_PERSIST_LOCAL_MACHINE`）。目标名 `KittyTools/<服务 id>.<字段>`（Debug 版 `KittyTools.Dev/…`），字段名同 mac：`zhipu.apiKey`、`ai:<id>.apiKey`、`google.apiKey`、`deepl.authKey`、`microsoft.subscriptionKey`。删 AI 服务时连它的密钥一起删。
- **内置智谱 key**：`windows/Secrets.props`（不入库，模板是 `Secrets.props.example`）里的 `KittyBuiltinZhipuKey`，构建时写进程序集元数据（`AssemblyMetadata`），运行时读出来；没有就当没有内置 key，智谱卡片提示去填 API Key。可以和 mac 版用同一个 key（`macos/Config/Secrets.xcconfig`）。
- **HTTP**：全 App 共用一个 `HttpClient`；流式用 `HttpCompletionOption.ResponseHeadersRead`，按行读 SSE；`User-Agent: KittyTools/<版本>`。

### 7.3 流式与取消

照搬 mac-translate §4：

- 每次给出到目前为止的整段译文；空串表示「思考中」；
- 剥掉开头的 `<think>…</think>`；完成后去掉整段外层的引号；结果为空报错；
- 取消用 `CancellationToken`，**取消不算完成**：不复制、不写任何地方，半截译文丢掉；
- 新的一次翻译取消旧的全部请求；浮窗收起也取消（省额度）。

### 7.4 入口

- **划词翻译**（Alt+E），照 mac §6 划词时序：
  - **取到词之前不显示浮窗**（先显示会抢走原窗口的焦点，选区没了）。自家浮层在前台就先收起。
  - 先用 UI Automation：焦点元素的 TextPattern → `GetSelection` → 文本，500 ms 超时，在 MTA 线程上做。
  - 拿不到再走兜底：备份剪贴板 → 发 Ctrl+C → 等剪贴板序号变化（最多 500 ms）→ 读出来 → 还原。期间暂停剪贴板记录；还原时给写回去的内容加上 `CanIncludeInClipboardHistory = 0`，免得系统的 Win+V 历史里多出一份重复的。
  - 修饰键和管理员窗口照 §5.5。
  - 都没取到就当输入翻译打开，输入框占位文字写「没取到选中的文字，可以直接输入或粘贴」。
  - ponytail：剪贴板备份第一版只备份文本、HTML、RTF、图片、文件这几种，别的私有格式会丢；要全量备份时，枚举全部格式、拷贝各自的 HGLOBAL。
- **输入翻译**（Alt+T）：是开关。再打开时保留上次的原文和结果，原文全选（打字就替换）。
- **复制即译**（默认关；托盘菜单、浮窗顶栏、设置三处是同一个开关）：剪贴板记到新文本后，照 mac 的 `worthTranslating` 过滤（网址、单行路径、纯数字或符号、超过 32 KB、目标自动时原文本来就是第一语言、和上一次原文相同，都静默跳过），浮窗只露出不抢焦点（§5.4）。
- **剪贴板里的「翻译」**（Ctrl+T）：剪贴板面板留着，翻译浮窗露出来。
- **启动器 `fy 文本`**：收起启动器，直接翻译。

### 7.5 浮窗

- **尺寸**：宽 460（可以拖左右边改宽，记住）；高度随内容，最矮 220，最高到工作区的 85%。材质同 §5.4。
- **位置**：设置「浮窗位置」= 跟随鼠标（默认）/ 上次位置。
  - 跟随鼠标时，划词、截图翻译、复制即译出现在鼠标右下 12 px，放不下就翻到左边 / 上边，再夹进工作区；
  - 输入翻译总是在上次的位置；
  - 拖顶栏移动（用 `InputNonClientPointerSource` 把顶栏标成标题区）。
- **内容**：
  - 顶栏：语言胶囊、图钉、⋯ 菜单（复制即译开关、设置）；
  - 原文框：Enter 翻译、Shift+Enter 换行；原文改过之后右下角才出现品牌粉的「翻译 ↵」胶囊；
  - 每个启用的服务一张卡：服务图标 + 名字；状态有等待（骨架）/ 思考中 / 流式正文（末尾一根光标）/ 完成 / 错误；复制按钮；正文最多 8 行，超出的在卡片里滚动。
- **按键**：Enter 翻译、Ctrl+1–9 复制第 N 张卡、Ctrl+P 固定、Esc / Ctrl+W 关闭。
- **自动复制**第一个服务的结果（设置，默认关）。复制即译带来的原文不自动复制，免得盖掉用户刚复制的内容（mac §2）。复制出去的译文记进剪贴板历史（自家生成的新文字）。

## 8. 启动器（第 4 批）

- **面板**：宽 720，和剪贴板面板同一个位置；搜索框 56 高；单列结果，行高 48：图标 32 + 名字 + 副标题（路径或说明）+ 右边 Ctrl+数字的键帽（按住 Ctrl 才出现）；最多同时看到 8 行；底栏同剪贴板。
- **结果来源和顺序**（mac `Launcher/LauncherModel.swift` 文件头注释的简化版）：直达网址 / 路径 → 计算结果 → 关键词（`cb`、`fy`、搜索引擎关键词）→ 应用、设置页、系统命令、本 App 动作，按匹配分排序 → 网页搜索兜底。空查询时列「常用」8 行（按使用分）。
- **应用目录**：
  - 枚举 `shell:AppsFolder`（桌面应用的快捷方式和商店应用都在里面；`SHGetKnownFolderIDList(FOLDERID_AppsFolder)` + `IShellItem` 枚举），取名字、解析名、图标（`IShellItemImageFactory`，32 / 64 px，内存里按解析名缓存）。
  - 在后台 STA 线程上扫：启动时扫一次；打开面板时距上次超过 5 分钟再扫一次。扫的过程中先用上一次的结果。
  - 打开：`ShellExecuteEx("shell:AppsFolder\<解析名>")`。Ctrl+Shift+Enter 以管理员身份运行（verb `runas`，商店应用不给）；Ctrl+Enter 打开文件所在位置（有目标路径的才给）。
- **匹配**：照搬 mac `LauncherMatch`（完全相同 100 > 名字开头 80 > 词首 60 > 首字母缩写 50 > 子串 40；多个词全部命中，取最差那个词的分；使用加成公式照搬）。中文名另配拼音全拼和首字母，查 `KittyTools.Core/Resources/pinyin.txt`（已经生成好，嵌入资源；格式见 `windows/tools/pinyin-table.swift` 文件头）。
- **系统设置页**：一张静态表，`ms-settings:` 链接 + 中文名 + 英文名（约 25 个：显示、声音、蓝牙、网络、WLAN、电池、存储、默认应用、已安装的应用、通知、个性化、背景、颜色、任务栏、鼠标、键盘、日期和时间、语言和区域、Windows 更新、隐私和安全性、电源、夜间模式、投影…）。
- **系统命令**（中文名、英文名、拼音都能搜到）：锁定（`LockWorkStation`）、睡眠（`SetSuspendState`）、注销、重启、关机、清空回收站（`SHEmptyRecycleBin`）。重启、关机、注销、清空回收站不能撤销：第一下只「上膛」（副标题换成「再按一次 Enter 确认」），同一个键再按一次才执行（mac `SystemControl`）。
- **计算**：四则、括号、乘方、百分号、小数（纯函数，单测）。Enter 粘贴结果，Ctrl+Enter 只复制。
- **直达**：
  - 网址照 mac `DirectItems` 的规则（带协议 / IPv4 / localhost:端口 / 常见后缀白名单里的裸域名）→ 用默认浏览器打开；
  - 路径（`C:\…`、`\\服务器\共享`、`%环境变量%`、`~\` 开头展开成用户目录），存在才算 → 打开。
- **网页搜索**：预设同 mac `WebSearch.presets`；默认启用前 8 个，只有一个兜底，其余走关键词（`g 词`、`bd 词`）。兜底用 Bing（和 mac 不一样：Windows 自带浏览器默认就是 Bing，国内也能直接打开；mac 版兜底是 Google）。设置 › 启动器里可以排序、开关、改兜底。
- **关键词**：`cb 词` → 收起启动器，打开剪贴板面板并把词填进搜索框；`fy 文本` → 翻译。
- **本 App 的动作**：剪贴板历史、输入翻译、截图、截图翻译、识字、设置、退出 Kitty Tools（名字和拼音都能搜到）。
- **使用记录**：表 `launcher_usage`（item_key、query、count、last_used），算全局分和同一查询的分（mac 公式）；打开成功才记。
- **按键**：↑↓（到头循环）、Enter、Ctrl+Enter、Ctrl+Shift+Enter、Ctrl+1–9、Tab 补全（选中项的名字填进搜索框）、Ctrl+C 复制路径 / 网址、Esc 先清空再关闭；单击选中、双击执行；右键菜单列出同样的动作。
- 打开应用和网址时 Enter 当下就收起面板，系统在后台打开，打不开用轻提示说。没执行就收起的，60 秒内再打开保留上次的查询（全选）和选中项。

## 9. 截图（第 5 批）

### 9.1 冻结和遮罩

- **先截后选**（mac §8）：按下热键先把每块显示器截成冻结帧，再盖上遮罩；之后的框选、裁剪只读这一帧，不许改成「框完再截」（别的程序靠失焦关闭的菜单会先消失）。
  - 截屏用 GDI `BitBlt`，每块屏一张，物理像素。进程是 Per-Monitor V2（WinUI 默认），坐标都按物理像素算。
  - ponytail：受保护的内容截出来是黑的，HDR 屏的颜色按 SDR；要处理时换 Windows.Graphics.Capture。
- **遮罩**：每块屏一个 WinUI 窗口：
  - 无边框、无标题栏、置顶、不进任务栏和 Alt+Tab，尺寸就是这块屏的物理像素；
  - **设 `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_DONOTROUND`**，不然四个角是圆的，会露出活的桌面；
  - 内容是 Win2D `CanvasControl`：冻结帧按 1 物理像素对 1 像素画（DIP 尺寸 = 像素 ÷ 这块屏的缩放比例），上面压暗 45%，选区挖洞，2 px 强调色边框、8 个手柄、尺寸胶囊、放大镜；
  - 鼠标所在那块屏的遮罩拿焦点收键盘。
  - 第 0 批量「按下热键到遮罩出现」的时间：超过 150 ms（4K 单屏）就改用 Win32 窗口 + Direct2D，报告里写数。
- **窗口吸附**：
  - 冻结那一刻 `EnumWindows`（Z 序从上到下），只要看得见、没最小化、没被隐藏（`DWMWA_CLOAKED` 为 0）、尺寸不为零的顶层窗口；
  - 边界取 `DWMWA_EXTENDED_FRAME_BOUNDS`（不含看不见的拉伸边）；
  - 本 App 的浮层和钉图算，遮罩自己不算；
  - 悬停时第一个包含鼠标的窗口高亮（洞和边框用弹簧滑过去），单击选中它。
- **框选**：拖出选区；Shift 保持比例、Alt 从中心拉；整条边都能拖（边外 8 px、边内 min(8, 短边 ÷ 4)）；调整时在选区外拖出来的新框太小（误触）就恢复原选区。这些几何全部写成 `RegionMath` 纯函数配单测（照 mac `RegionSelector`）。选区只在一块屏上。
- **放大镜**：在鼠标右下，8 倍、11 × 11 像素格、中心格描边，下面一行写坐标和颜色 HEX；按 C 复制颜色 HEX（记进剪贴板历史）。拖动、跟随不做动画。
- **退出**：Esc 或右键，有选区时先取消选区，再按一次退出截图。

### 9.2 标注和输出

- 选区定下来后，选区下方出现工具栏（下方放不下就放上方，再不行放选区里面）：矩形、箭头、画笔、文字、马赛克 ｜ 颜色（红、黄、绿、蓝、品牌粉、白、黑）、粗细三档 ｜ 撤销、重做 ｜ 钉图、识字、翻译、保存、复制、取消。
- **标注**是值类型（存选区坐标）。屏幕上和导出用同一份画法（mac §8「两边共用 drawAll」）：导出时用 Win2D `CanvasRenderTarget` 按物理像素画「冻结帧裁出的选区 + 全部标注」，编码成 PNG。
- **文字标注**：在画布上叠一个 `TextBox` 收字（输入法要能用），收下后画成 `CanvasTextLayout`。**马赛克** = 把那块缩小，再用最近邻放大回去（块大小 12 px）。
- **按键**：Enter / 双击选区 / Ctrl+C 复制并退出；Ctrl+S 快速保存；Ctrl+Shift+S 另存为；P 钉图；O 识字；T 翻译；Ctrl+Z / Ctrl+Y 撤销 / 重做；1–5 切换工具（矩形、箭头、画笔、文字、马赛克）；Esc 取消。
- **输出**：遮罩先收起，再做下面的事。
  - 复制 = PNG + `CF_DIBV5` 写进剪贴板，并记进剪贴板历史；
  - 快速保存默认存到系统的「屏幕截图」文件夹（`FOLDERID_Screenshots`，和 Win+PrtScn 同一个地方；设置 › 截图可改），文件名 `截图 2026-10-23 13.05.12.png`；
  - 另存为用 Windows App SDK 的 `Microsoft.Windows.Storage.Pickers.FileSavePicker`（传窗口的 `AppWindow.Id`，无包应用能直接用）；
  - 结果走轻提示（带文件名）。

### 9.3 钉图

- 无边框置顶窗口，在原位置出现（选区的屏幕坐标），系统圆角 + 阴影（同浮层「保留边框」的做法）。出现时不抢焦点，点了才拿焦点。
- 拖动移动；滚轮以鼠标为中心缩放（保持比例，10%–500%）；双击或 Esc 关闭；Ctrl+C 复制、O 识字并复制、Ctrl+S 快速保存、Ctrl+0 原始大小。
- 右键菜单：复制、识字并复制、翻译、保存、另存为 ｜ 透明度（100 / 80 / 60 / 40%）、原始大小 ｜ 关闭。
- 剪贴板里图片条目右键「钉到屏幕」：放在鼠标所在屏的中央，超过工作区 80% 就等比缩小，钉多张时往右下错开 24 px。

### 9.4 识字和截图翻译

- **识字**用 `Windows.Media.Ocr`（`OcrEngine.TryCreateFromUserProfileLanguages()`；图片超过 `OcrEngine.MaxImageDimension` 先等比缩小）。
  - **中日韩文字之间去掉空格**：Windows 的识字把每个汉字当成一个词，拼成行时两边都是 CJK 就不加空格。
  - 分段、接行照搬 mac 的 `OCR.paragraphs` / `joiningLines`；行框用 `OcrLine` 里各个词框的并集。
  - 用户的语言里没有可用的识字引擎（比如没装中文的「光学字符识别」）：轻提示「没装中文识字组件」，详情写「设置 › 时间和语言 › 语言和区域 › 中文 › 语言选项 › 光学字符识别」，同时打开 `ms-settings:regionlanguage`。
  - 识出的字写进剪贴板（记进历史），轻提示「已复制识别的文字」+ 前 30 个字。
- **截图翻译**（Alt+S）：冻结 → 框选（松手即确认，没有标注阶段，同 mac）→ 识字 → 段与段之间空一行 → 原文记进剪贴板历史（不写剪贴板）→ 翻译浮窗出现在选区旁边。识字失败或没有文字走轻提示，不开浮窗。

## 10. 检查更新与发布（第 6 批）

- **发布红线：Windows 的 release 一律不标 latest**（`gh release create windows-v<版本> --latest=false`）。mac 版的更新检查读 GitHub 的 `releases/latest`，而且只认 `macos-v*` 的 tag；GitHub 默认把新建的 release 标成 latest，Windows 版一旦成了 latest，mac 用户就收不到更新了。
- **检查更新**：启动后一次，之后每天一次（设置里可以关）。
  - 读 `https://api.github.com/repos/YyAdnBug/kitty-tools/releases?per_page=20`，取第一个不是草稿、不是预发布、tag 是 `windows-v*` 的，比较版本号；
  - 有新版就轻提示一次（每个版本只提示一次），托盘菜单的「检查更新」变成「下载新版本 x.y.z」，点了打开发布页。
  - ponytail：第一版不自动替换。要做时用「改名正在运行的 exe → 解压新文件 → 重启」。
- **`build-release.ps1`**：
  1. 读 `Directory.Build.props` 里的版本；
  2. 检查 `KittyTools/Resources/changelog.json` 有这个版本的条目，没有就中止（同 mac）；
  3. `dotnet publish -c Release`，分别用 `-r win-x64` 和 `-r win-arm64`（AOT）；
  4. 各打一个 zip：`KittyTools-<版本>-windows-x64.zip`、`KittyTools-<版本>-windows-arm64.zip`，里面是一个「Kitty Tools」文件夹；
  5. 生成发布说明（更新日志 + 第一次运行的步骤）。
  - 上传由用户确认后再手动跑 `gh release create`。
- **发布说明固定附上**：解压到任意位置（建议 `%LOCALAPPDATA%\Programs\Kitty Tools`）→ 双击 `KittyTools.exe` → 第一次会出现「Windows 已保护你的电脑」→ 点「更多信息」→「仍要运行」（因为没有代码签名证书）。
- **`changelog.json`** 的格式同 mac 版（version、date、summary、条目的 type 只用 feat / fix / perf / ui）。

## 11. 测试与验收

- `KittyTools.Tests`（MSTest）只测 Core 的纯函数；从 mac 移植过来的单测，期望值原样保留。`dotnet test` 全部通过才能提交。
- 每批在 `windows/HANDTEST.md` 追加这批的手测条目（编号接着往下排，写「怎么做 → 应该看到什么」），自己先走一遍。
- **必测环境**：缩放 100% 和 150% 各一次；有条件就测双屏、两块屏缩放不同；浅色和深色；记事本、Edge、VS Code、Word（有的话）、以管理员身份运行的记事本。
- **量内存**：口径是任务管理器「详细信息」页的「内存(专用工作集)」，代码里用 `GetProcessMemoryInfo` 取 `PROCESS_MEMORY_COUNTERS_EX2.PrivateWorkingSetSize`。用 Release AOT 构建，空闲 30 秒后再读。
- **联网冒烟**（真的请求内置智谱）默认不跑，设环境变量 `KITTY_LIVE_TRANSLATE=1` 才跑。

## 12. 分批

每批的「验收」是审查时逐条核对的清单。

### 第 0 批：验证样机

目的：写正式代码之前，先把 WinUI 这条路上最没把握的几件事实测掉。代码可以扔掉重写，也可以留作第 1 批的起点。

1. 空 WinUI 3 工程，AOT 发布跑通（x64、ARM64 至少真跑起来一种）；对比聚合包和组件包的发布目录大小。
2. 托盘图标 + 右键菜单。
3. 热键弹出 §5.4 那样的浮层（Alt+C 和 Alt+Space 各试一次）：确认有系统圆角和阴影、没有多出来的标题栏条；打开后马上能往输入框里打字；量「按下热键到窗口出现」的时间。
4. 粘贴回原窗口：浮层里按 Enter，把一行字粘进记事本、Edge、VS Code；对以管理员身份运行的记事本，确认能判断出来、只复制不粘。
5. 截图遮罩：BitBlt 冻结 + 全屏 WinUI 窗口 + Win2D 画冻结帧（四角不圆）。量「按下热键到遮罩出现」的时间（用 4K 或手头最大的屏）；抽查遮罩上的像素和真实屏幕逐像素一致（缩放 100% 和 150%）；确认 Win2D 在 AOT 发布下能用。
6. CsWin32 在 AOT 下调通一个 COM 接口：用 UI Automation 读出记事本里选中的字。
7. 内存（Release AOT、专用工作集、空闲 30 s 后）：只有托盘时；浮层打开再收起后；浮层窗口销毁后；遮罩打开再关掉后。

报告：每一项的结果和数字，以及给第 1 批的建议（浮层收起后留着还是销毁、遮罩用 WinUI 还是 Win32）。**内存数出来后，由用户决定这条路继续不继续。**

验收：7 项都有结论；数字可以复现（写清楚怎么量的）。

### 第 1 批：壳

§2、§4、§5 全部 + Core 和 Tests 两个工程 + `build-release.ps1` 能出 zip（这批不发布）。

验收：单实例；托盘菜单全部菜单项（还没做的模块先灰着）；热键注册、冲突标红、录制规则单测；浮层基类的显示、四种关闭方式、前台归还；Paster 的修饰键和管理员判断；轻提示三种语气；设置窗的通用、快捷键、关于三页和首次运行欢迎；深浅色和品牌粉；Debug / Release 数据目录分开；日志里没有内容；发布构建零 AOT 警告。

### 第 2 批：剪贴板（§6）

验收：§6 每一条；隐私格式用 KeePass 或自己写个小程序打标记来测；5000 条的搜索耗时写进报告；图片去重；保留天数和图片上限的清理有单测；面板按键表逐个过一遍。

### 第 3 批：翻译（§7，不含截图翻译）

验收：服务分发和接口约束有单测（地址补全、max_tokens、关思考分档、截断、think 标签、取消不算完成）；内置智谱联网冒烟跑过一次；划词在记事本 / Edge / VS Code / Word / 管理员窗口里各试一次；复制即译的过滤；凭据管理器里能看到 `KittyTools/…` 的条目，日志里没有密钥。

### 第 4 批：启动器（§8）

验收：应用目录里既有商店应用（计算器、设置）也有桌面应用，都带图标；拼音全拼和首字母能搜到中文名的应用（比如「微信」用 wx、weixin）；匹配排序和计算有单测；危险的系统命令要按两次；以管理员身份运行；60 秒内保留查询；扫描耗时和应用数写进报告。

### 第 5 批：截图（§9）

验收：先截后选；多屏、不同缩放下选区的像素准确（导出的图和冻结帧逐像素比）；吸附准确（包括最大化的窗口、带阴影的窗口）；5 种标注 + 撤销重做；复制、快速保存、另存为；钉图的全部操作；识字（中文、英文、中英混排，CJK 之间没有多余空格）；截图翻译；遮罩出现的耗时、截一次图之后的内存写进报告。

### 第 6 批：收尾

§10 + 设置各页补齐 + `HANDTEST.md` 冒烟清单 + 更新日志 0.1.0。发不发布由用户决定。

验收：更新检查只认 `windows-v*`，单测覆盖「latest 是 mac 的 release」的情况；zip 在一台没装 .NET 和 Windows App SDK 的干净 Windows 11 上解压就能跑。

## 13. 风险

- **WinUI 3 的内存基线**：第 0 批的数决定继续不继续。参照：微软自己的 Command Palette（同样是常驻启动器，WinUI 3 + C#）开 AOT 后启动内存峰值约 161 MB。
- **前台拿不到、粘贴被拦**：第 0 批验证，已知的坑写在 §5.5。
- **有些程序里选中的文字 UI Automation 读不到**（老式 Win32 控件、部分 Electron 场景）：有 Ctrl+C 兜底。
- **没有代码签名**：SmartScreen 对每个新版本都可能拦一次；杀毒软件可能误报没签名的程序。
- **Windows 识字的中文质量不如 mac 的 Vision**，而且要装语言组件：第一版接受。
