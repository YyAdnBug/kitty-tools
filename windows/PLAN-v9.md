# Kitty Tools Windows 版：第九版方案（补齐和 mac 的功能差距）——拍板页

2026-10-27。用户：「功能缺口写成 PLAN-v9 拍板页（每项带推荐，先改默认值和 mac 反着的那几条）」。

**状态：等用户拍板。** 用户说「全部按推荐」或者逐项改完之前，Windows 的 agent 别动这份方案；REVIEW 里的待修（R41–R52、R24）照常做。

- **怎么来的**：审查方在 Mac 上把 mac 的 `Settings/*Tab.swift`、`Storage/Prefs.swift` 的默认值表、剪贴板 / 启动器的 ⌘K 菜单、截图工具栏和钉图菜单、录制设置，逐项对着 Windows 的 `App/Settings.cs` 和对应文件比了一遍（对着 `e82715d2`）。下面每一项都写了 mac 的出处，路径相对 `macos/KittyTools/`。
- **规矩**：`AGENTS.md` 的红线和「和 mac 版统一什么」两张单子照旧：功能、行为、默认值、文案跟 mac，窗口外壳、字体、图标、快捷键写法跟 Windows（⌘ → Ctrl，⌥ → Alt，⇧ → Shift）。mac 的源码只当规格读，只照抄行为和数值。
- **默认值不用迁移**：Windows 版一个 release 都还没发过（`gh release list` 里只有 `macos-v*`），改默认值只影响开发机。唯一要处理的是 V3：存着 `RecordFps = 15` 的读成 30（15 不再是选项）。
- **新设置字段**：名字进了 `settings.json`、跟着设置导出，以后别改；和 mac 互通的那几类数据（PLAN-v3 §1.5、PLAN-v5）格式不动。
- **不在这一版**（已经定过，不再拍）：启动台、程序坞预览（Windows 有开始菜单和任务栏缩略图）、晾衣绳、刘海岛里跟刘海有关的交互和「快捷键叫出那一张」、Liquid Glass、同步扩到设置 / 快捷键 / 启动器收藏（PLAN-v8 §1 G6）。便签和状态屏见 §8。

## 0. 谁做（D0）

| 选项 | 说明 |
|---|---|
| **推荐：Windows 的 agent 做，审查方每批复查** | 这一版大半是界面和交互，要编译、截图、手测，在 Windows 上一边写一边验最省返工；照 `AGENTS.md`「每一批的流程」，复查意见照常写进 REVIEW |
| 审查方在 Mac 上写、不编译（同 v8） | v8 那几批编过去都有编译错和行为问题要那边修；这一版量大，来回更多 |

## 1. 第 1 批：默认值和 mac 反着的（先做）

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| V1 | 启动器读浏览器书签 / 历史 | 设置 › 启动器「浏览器书签与历史」：只列装了的浏览器，每家两个开关（书签、浏览历史；历史要书签开着才能开）。**默认书签只开 Chrome，历史全关**（`Storage/Prefs.swift:19–23,301–302`、`Launcher/Browsers.swift`、`Settings/LauncherTab.swift:107`） | 没有开关：Chrome / Edge / Brave / Vivaldi 的书签和**浏览历史一直在读**，Firefox 只读书签（`Launcher/LookupServices.cs:425` 起） | 照 mac 加每家两个开关、只列装了的；Firefox 的浏览历史也接上（同一个 `places.sqlite`）。**默认书签开 Edge 和 Chrome**（Edge 是 Windows 自带的浏览器，读书签不用额外授权，理由和 mac 只开 Chrome 一样），**浏览历史全关**。和 REVIEW R42 一起做 |
| V2 | 识字后把同一段里的换行接起来 | 设置 › 截图的开关，**默认关**；截图翻译总是接（`Settings/ScreenshotTab.swift:14,94–98`、`Prefs.swift:157,338`）。接法：同一段的行接起来，段和段之间留换行，中日文直接接、其它加空格 | 没有开关，**一直接**（`Screenshot/OcrService.cs:51` 默认 `joined = true`，四处调用都没传） | 加开关，默认关；识字（遮罩、钉图、历史）看开关，截图翻译照旧总是接。设置里配一个接 / 不接的小预览（mac 的 `JoinLinesPreview`） |
| V3 | 录屏帧率 | 30 / 60，**默认 30**（`Settings/RecordTab.swift:31`、`Prefs.swift:344`） | 15 / 30，默认 15（`App/Settings.cs:112`、`Settings/SettingsWindow.cs:1189`） | 改成 30 / 60、默认 30；存着 15 的读成 30。60 fps 时的 CPU 和文件大小按 PLAN-v6 §0 量一次（测试窗口），写进报告 |
| V4 | 按录音快捷键后立即开始录 | **默认关**：先在屏幕底部出录音控制条、不录，点 ● 或再按一次才开始（`Settings/RecordTab.swift:71`、`Prefs.swift:152–154,355`） | 默认开（`App/Settings.cs:134 RecordInstantStart = true`） | 默认改成关 |
| V5 | 录音录什么 | 设置 › 录制「录音」单独一项：**麦克风（默认）/ 系统声音 / 两者**；选了麦克风被拒授权时弹回「系统声音」并提示（`Settings/RecordTab.swift:65`、`Prefs.swift:151,354`） | 没有单独的设置，借录屏那两个开关（`Recording/AudioHost.cs:92–94`），按默认值实际只录系统声音 | 照 mac 加单独一项，默认麦克风；录音控制条上的来源切换改它，不再改录屏的两个开关。麦克风权限被拒（设置 › 隐私和安全性 › 麦克风）时退回系统声音，轻提示带「打开设置」 |

## 2. 第 2 批：剪贴板

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| C1 | 设置补五个开关 | `Settings/ClipboardTab.swift:58–84`：显示透镜（默认开）、单击条目直接粘贴（默认关）、默认粘贴为纯文本（默认关，开了 ↩ 和 ⌥↩ 对调）、识别图片中的文字（默认开）、退出时 / 锁屏时清空普通历史（都默认关，收藏 / 片段 / 收藏夹里的不清） | 都没有：透镜一直显示、识字一直开、只能双击粘贴，没有清空 | 都做，默认值照 mac。默认纯文本开着时 Enter 和 Shift+Enter 对调，底栏的「粘贴 ↩」和按住 Shift 时的说明跟着换；锁屏走现有的会话通知（`ShellRuntime.cs:938` 那一处） |
| C2 | 图片最多占用的档位 | 512 MB / 1 GB / 2 GB / 5 GB / 不限，默认 512 MB（`ClipboardTab.swift:36–42`） | 128 MB / 256 MB / 512 MB / 1 GB / 不限（`SettingsWindow.cs:824`） | 档位换成 mac 那五个，默认不变；存着 128 / 256 的照旧按原值算，下拉框里多显示一项原值，换了就没了 |
| C3 | Ctrl+K 操作补齐 | `Clipboard/ClipboardPanelModel.swift:1177–1208`：打开文件 / 打开链接 ⌘O、在访达中显示 ⌘R、复制路径 ⌥⌘C、美化 JSON、放大预览 ⌘Y、复制为纯文本 | 只有文件的「在资源管理器中显示」，没有快捷键（`Clipboard/ClipboardPanel.xaml.cs:1888–1931`） | 都做，键照 Windows 的换算：Ctrl+O、Ctrl+R、Ctrl+Shift+C、Ctrl+Y，和面板里现有的键撞了就照 mac 的意思另取、写进速查表。「在资源管理器中显示」叫这个名字（mac 叫「在访达中显示」）。多选时的 Ctrl+K（一次钉多张、批量收藏）照 mac 看一遍，缺的一起补 |

## 3. 第 3 批：翻译和三个快捷动作

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| T1 | 译文字号 | 设置项（滑块）+ 浮窗里 ⌘+ / ⌘− / ⌘0，0.8–1.6 倍、一步 0.1，默认 1.0（`Settings/TranslateTab.swift:101`、`Translate/TranslateCoordinator.swift:437,468–472`） | 没有 | 做：Ctrl + = / Ctrl + − / Ctrl + 0，和设置里同一个值 |
| T2 | 翻译前把段落里的换行接起来 | 开关，默认关（`TranslateTab.swift:147`） | 没有 | 做，接法和 V2 同一个纯函数 |
| T3 | 截图翻译时把识别出的原文也复制 | 开关，默认关（`TranslateTab.swift:154`） | 没有，只有识字模式复制（`Screenshot/ScreenshotSession.cs:236`） | 做 |
| T4 | 结果卡折叠，重启后还记得 | 点卡头折叠，记在 `translateCollapsedServices`（`Translate/TranslatePanelView.swift:27`） | 没有 | 做：记服务 id 列表 |
| T5 | 浮窗里重新翻译、收藏、打开设置 | ⌘R 重新翻译、⌘D 收藏当前这次、⌘, 打开设置（`TranslateCoordinator.swift:455–463`） | 重译和收藏只能在历史列表里做 | 做：Ctrl+R、Ctrl+D、Ctrl+,，卡头加对应按钮的悬停提示 |
| F1 | 快捷动作「划词翻译并替换」 | 不设默认键（`Shell/HotKeyCenter.swift`） | 没有；`App/Settings.cs:81 TranslateReplaceHotKeySeen` 是第三版 §3.2 留下的字段，没人用 | 做：取词 → 翻译 → 用第一张卡的译文替换回去（现有的 `ReplaceWith`），不弹浮窗；失败时轻提示。加在默认表最后 |
| F2 | 快捷动作「录音」 | 不设默认键 | 只能从托盘开 | 做，加在默认表最后；录音中按是停止（同录屏） |
| F3 | 快捷动作「钉住剪贴板里的图」 | 不设默认键 | 没有 | 做：剪贴板里是图就钉到鼠标所在的屏，不是图就轻提示，加在默认表最后 |

三个新动作都进快捷键页、速查表、启动器的内置动作（L8）。

## 4. 第 4 批：启动器

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| L1 | 呼出时切到英文输入法 | 开关，默认关（`Settings/LauncherTab.swift:77`、`Prefs.swift:304`） | 没有 | 做，默认关。做法：开着时给启动器的输入框设一个英文的 `InputScope`，输入法在这个框里默认英文，不动系统的输入法设置；不灵再试 `ImmSetConversionStatus`，都不灵写进「没做成」 |
| L2 | 浏览器书签 / 历史 | 见 V1 | | 第 1 批已做 |
| L3 | 自定义网页搜索和快捷链接 | 能新建、编辑名称 / 关键词 / 网址（`LauncherTab.swift:195`、`Settings/SearchEngineDetail.swift:40–45`） | 只能加内置预设，不能新建、不能编辑（`SettingsWindow.cs:1062–1084`） | 做。网页搜索是同步的四类之一，mac 那边新建的条目同步过来，Windows 也要能改；字段照现有的 `SearchEngine` |
| L4 | 有本地结果时也显示兜底搜索 | 开关，默认关（`LauncherTab.swift:121`） | 没有 | 做 |
| L5 | 系统命令补齐 | 关闭显示器、屏保、打开废纸篓、全部退出、推出全部磁盘、音量加 / 减 / 静音（`Launcher/SystemCommands.swift:12–13,108`） | 只有锁定 / 睡眠 / 注销 / 重启 / 关机 / 清空回收站，加 kill、port | 做：关闭显示器、屏保、打开回收站、音量加 / 减 / 静音。**不做**「全部退出」「推出全部磁盘」：Windows 上没有对应的一键操作，硬做容易误伤正在用的程序和磁盘 |
| L6 | 计算器补齐 | mod、函数（sqrt / sin / log 这类）、pi / e、0x / 0b 字面量、单位换算、进制换算；⌘K 里复制原始数字、复制成别的进制（`Launcher/Calculator.swift:1–8`） | 只有四则、括号、乘方、百分号（`KittyTools.Core/Calculator.cs`） | 做：照 mac 的 `Calculator.swift` 把语法、函数表、单位表、进制原样移植到 Core，mac 的单测期望值一起搬过来 |
| L7 | Ctrl+K 操作补齐 | 快速查看 ⌘Y、用别的 App 打开、复制为 Markdown 链接 ⇧⌘C、复制标题、⌥↩ 在访达里搜、⌃↩ 网页搜索、从常用中移除 ⌘⌫（可撤销）、移到废纸篓（`Launcher/LauncherModel.swift:1452–1516`） | 只有打开、打开位置、以管理员身份运行、复制、补全、收藏（`Launcher/LauncherPanel.xaml.cs:778–829`） | 做：「打开方式…」（系统的打开方式对话框）、复制为 Markdown 链接、复制标题、在资源管理器里搜、网页搜索、从常用中移除（可撤销）、移到回收站。**不做**快速查看：Windows 没有系统自带的那一套 |
| L8 | 内置动作补齐 | 全部快捷动作 + 菜单栏菜单里的项（截取上次区域、录音、暂停记录剪贴板、复制即译开关、钉图隐藏 / 关闭、速查表、检查更新、关于）（`Launcher/LauncherItem.swift:82–105`） | 9 项（`Launcher/LauncherActions.cs:15–25`） | 做：内置动作表 = 快捷动作表 + 托盘菜单那几项，一处定义，以后加动作不用改两处 |

## 5. 第 5 批：截图的标注和选区

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| S1 | 标注工具补五种 | 10 种：多了椭圆、直线、荧光笔、序号、聚光灯（`Screenshot/Annotation.swift:15–17`） | 5 种（`Screenshot/Annotation.cs:11–19`） | 做；数字键照 mac 往后排，工具栏、速查表跟着改。截图历史的标注 JSON（PLAN-v8 H4）加新的 tool 名，旧的名字一个字都不动 |
| S2 | 标注画完还能改 | 拖手柄改大小、箭头 / 直线拖弯、⌥ 拖复制、⌘D 复制、双击文字重新编辑（`Screenshot/SelectionView.swift:9–12`） | 只能选中后拖着挪（`SelectionOverlayWindow.cs:1049–1060`） | 做：Alt 拖复制、Ctrl+D 复制，其余照 mac |
| S3 | 每个工具记住上次的样式 | 颜色、线宽按工具记（`Storage/Prefs.swift:108`） | 不记 | 做 |
| S4 | 选区调整 | 方向键挪 1 px / Shift 10 px、⌥ / ⌘ + 方向键收 / 推边、尺寸胶囊里直接输宽高、比例锁、空格按住平移整个选区、按住 ⌘ 出十字准线（`SelectionView.swift:6–8,2203–2206`） | 只有 Shift 锁正方形、Alt 从中心拉、吸附；R39 建议的方向键也还没做 | 做；⌘ 换成 Ctrl，按键和遮罩里现有的撞了就照 mac 的意思另取、写进速查表 |
| S5 | 遮罩里切模式、工具栏补按钮 | 遮罩里按 D 跳到上次区域、按 R / 点工具栏切到录屏；工具栏有「长截图」「录屏」按钮和「存储 ▾」（含另存为）（`SelectionView.swift:2193–2195`、`Screenshot/EditorToolbar.swift:2–3`） | 「截取上次区域」只有全局热键；长截图只能按 S / A；工具栏没有另存为（`SelectionOverlayWindow.cs:555–569`） | 做 |

## 6. 第 6 批：截完之后（角落卡、钉图、录制的卡、托盘）

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| S6 | 快门声 | 开关，**默认开**（`Settings/ScreenshotTab.swift:36`、`Prefs.swift:339`） | 没有声音 | 做，默认开（默认值跟 mac）。声音用 `C:\Windows\Media` 里系统自带的一个短音，不随包带素材；静音 / 专注模式时不响 |
| S7 | 截完放哪 | 角落缩略图 / 晾衣绳 / 都不要（都不要 = 右下角闪一下，仍进历史）（`ScreenshotTab.swift:77`） | 每次都出角落卡（`ScreenshotSession.cs:277,321`） | 做「角落缩略图 / 都不要」两档（晾衣绳不做） |
| S8 | 截图历史的保留设置 | 保留 7 / 30 / 90 天 / 一直留着；最多占用 1 / 2 / 5 GB / 不限；「打开截图历史…」「现在清空…」（`ScreenshotTab.swift:50–69`） | 写死 30 天 / 2 GB，设置里不能清空（`SettingsWindow.cs:1171–1182`） | 做，默认 30 天 / 2 GB 不变；`ShotHistoryRules.Stale` 改成吃这两个参数，单测补上 |
| S9 | 角落缩略图 | 最多叠 3 张，双击打开，存过以后能「在访达中显示」，右键菜单（含「在历史里看」）（`Screenshot/ShotShelf.swift:2–4`） | 只留一张，没有右键菜单（`Screenshot/ScreenshotCard.cs:172–176,227–239`） | 做（PLAN-v8 里没做的「在历史里看」在这里补上） |
| S10 | 钉图 | 透明度滑块 10–100%，右键菜单里有「翻译」「存储」（`Screenshot/PinPanel.swift:502–519,536`）；菜单栏菜单里「显示 / 隐藏全部钉图」「关闭全部钉图」 | 透明度 4 档循环，菜单里没有翻译和快速保存；没有全部隐藏 / 关闭的入口（`Screenshot/PinWindow.cs:147–150,293–301`，`CloseAll` 只有内存探针在调） | 做；透明度在右键菜单里放一个滑块。全部隐藏 / 关闭进托盘和启动器 |
| S13 | 截图历史记来源程序 | 记截图时前台的程序（`Screenshot/ShotHistory*.swift`） | 不记（PLAN-v8 第 3 批「和方案不一样」） | 做：进遮罩那一刻的前台窗口所属的程序名；`shots` 表加一列（迁移加一步） |
| R1 | 录完的角落卡 | 录屏 / 录音 / GIF 录完在角落出一张卡：拷贝文件、拖出、打开、移到废纸篓、转 GIF、压缩（`ShotShelf.swift:9–19`） | 只弹轻提示；压缩、转 GIF 只能在托盘里对最近那一段做（`Recording/RecordingHost.cs:182`、`Shell/TrayMenu.cs:270–280`） | 做，和 S9 同一个角落、同一叠；托盘里那两项留着 |
| R2 | 开始前倒数 | 0 / 3 / 5 秒，默认 3（`Settings/RecordTab.swift:46`） | 写死 3 秒（`Recording/RecordingCountdown.cs:29`） | 做 |
| R3 | 显示光标 | 开关，默认开（`RecordTab.swift:51`） | 一直录光标（`Recording/WgcRecorder.cs:361`） | 做（WGC 的 `IsCursorCaptureEnabled`） |
| R4 | 显示按键的范围 | 全部按键 / 只显示快捷键，**默认全部**（`RecordTab.swift:52`、`Prefs.swift:349`） | 只有「只显示快捷键」一种（`SettingsWindow.cs:1204`） | 做，默认值跟 mac；设置里的说明写清楚「全部按键会把打的字录进去」 |
| R5 | 清晰度和编码 | 清晰度：原始 / 标准；编码：H.264 / HEVC（`RecordTab.swift:36–41`） | 都没有 | 做清晰度（标准 = 长边封顶 1920、码率按 mac 的比例）。**不做 HEVC**：Windows 上播 HEVC 要另装扩展，录出来发给别人常常打不开 |
| G1 | 托盘菜单补项 | 菜单栏菜单里有划词翻译、截取上次区域、显示 / 隐藏全部钉图、关闭全部钉图、关于（`App/AppDelegate.swift:2440–2490`、`Shell/StatusItem.swift:267–268`） | 都没有（`Shell/TrayMenu.cs:195–335`） | 做截取上次区域、钉图那两项、关于。**不做**划词翻译：一点托盘，原来的程序就不在前台了，取不到选中的字 |

## 7. 第 7 批：长截图

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| S11 | 拍的时候有预览，能往回看 | 一块预览面板：拼好的那一头跟着长，鼠标在上面滚就往回看，右边一条指示条说在整张图的哪里，双击回到最新（`Screenshot/ScrollCapture.swift`、`ScrollStitcher.swift` 的 `previewRange`，mac `948cf9e2`） | 没有预览，只在轻提示里报进度 | 做。先做完 REVIEW R43（拼接改成条带），预览直接读条带，不另外拷整张图 |
| S12 | 拼完能标注（PLAN-v8 第 3 批下） | 长图标注窗口：只画看得见的那一段，能滚、能缩，工具栏同截图那套（`Screenshot/AnnotateOverlay.swift`、`ScrollCanvas.swift`） | 没有；历史里的长截图点「改标注」提示不支持 | 做。v8 当时按 mac 用户数据「长截图 0 次」推后了，但那是开发机一个人的数据，方案按一般用户定。Win2D `CanvasVirtualControl` 避开 16384 的纹理上限（PLAN-v8 H7） |

## 8. 第 8 批：备份、导入、关于

| # | 项 | mac（出处） | Windows 现在 | 推荐 |
|---|---|---|---|---|
| G2 | 每日自动备份看得见、管得了 | 设置 › 通用：开关（默认开）、「已有的备份」列表和「从备份恢复…」、「另存一份到」别的文件夹，没备成的原因用橙字写出来（`Settings/SettingsTransfer.swift:118–142,608`、`Prefs.swift:276–288`） | 后台一直在备份（`Storage/ArchiveService.cs:246–259`），界面上看不到、关不掉、恢复不了 | 做，和 mac 一样这几个是本机状态，不跟着导出导入走。先修 REVIEW R47（备份跨线程读数据） |
| G3 | 导入前确认 | 选完文件先列出里面有哪几类，按类勾选；会让保留期变短、隐私变弱、把文字发到别的地址（翻译服务）的，逐条提醒（`SettingsTransfer.swift:413–475`） | 选完文件直接整份合并（`SettingsWindow.cs:420–495`） | 做 |
| G4 | 关于页 | 「重看欢迎引导」「未来计划」（`Settings/AboutTab.swift:72,105`） | 都没有；欢迎引导是有的（`ShowPage(welcome: true)`） | 做「重看欢迎引导」。**不做**「未来计划」：mac 那份 `roadmap.json` 写的是 mac 的计划，Windows 的计划在这些 PLAN 里 |

## 9. 要不要做的两整族

| # | 项 | 推荐 | 备选 |
|---|---|---|---|
| X1 | 便签（mac 第七族：屏幕边缘那叠、快速记一条、便签墙、浮动便签、Markdown、行内图片、和 mac 同步） | **这一版不做**。mac 做了十批、39 个文件，单独立项才排得开；真要做，先出它自己的拍板页 | 单独立项，排在这一版之后 |
| X2 | 状态屏（mac 0.4.0：所有屏幕盖上告示、拦住键盘鼠标） | **这一版不做**。Windows 技术上做得了（每块屏一个置顶全屏窗口 + 低级键盘 / 鼠标钩子；Ctrl+Alt+Del 拦不住，这是系统的规矩），但拦输入那部分要单独想清楚怎么防锁死、怎么测 | 单独立项 |

## 10. 分批和验收

每批照 `AGENTS.md`「每一批的流程」和自查清单；批次之间先修 REVIEW 的待修。

| 批 | 内容 | 验收（除了自查清单） |
|---|---|---|
| 1 | V1–V5 | 新装（`.Dev` 那一套的空数据目录）：启动器搜不到浏览历史、书签只出 Edge / Chrome 的；识字不接行、截图翻译接；录屏 30 fps；按录音热键先出控制条；录音默认录麦克风，拒了权限退回系统声音并提示 |
| 2 | C1–C3 | 五个开关各走一遍；默认纯文本开着时底栏和 Shift 的说明跟着换；锁屏后普通历史清空、收藏还在；Ctrl+K 每一项走一遍 |
| 3 | T1–T5、F1–F3 | 字号三个键和设置联动；三个新快捷动作在快捷键页、速查表、启动器里都有，没设键时写「未设置」 |
| 4 | L1、L3–L8 | 计算器搬过来的 mac 单测全过；自定义的搜索在两台机器之间同步过去还能改（假的同步文件夹） |
| 5 | S1–S5 | 十种工具都能画、能改、能撤销；改过的标注从历史里再打开还在；方向键、输宽高、空格平移都走一遍 |
| 6 | S6–S10、S13、R1–R5、G1 | 角落叠三张；录完出卡、卡上转 GIF / 压缩；倒数 0 秒直接开录；关了显示光标的录屏里没有光标 |
| 7 | S11、S12 | 30000 px 的长图能往回看、能标注、能导出；拍的过程中内存峰值和 R43 报的数一致 |
| 8 | G2–G4 | 从备份恢复走一遍（临时数据目录）；导入一份把保留期改短的设置，提醒出来了 |

最后一批：版本号 0.2.0（2026-10-27 起 Windows 从 0.1.0 重新算），`changelog.json` 写这一版（type 用 feat / fix / ui），更新 `STATUS.md`，`HANDTEST.md` 加这一版的手测；照旧**不发布**。
