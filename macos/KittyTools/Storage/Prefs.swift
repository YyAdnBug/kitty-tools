// 偏好键名与默认值的唯一出处（PLAN §4）。键名一经发布不改（改名会丢用户设置），新键一律 camelCase。
// 设置的导出 / 导入（SettingsArchive）按 defaults 这张表知道有哪些设置、各是什么类型：注册了默认值的键都会跟着文件走；
// 窗口位置、上次区域、「进行中」、授权状态这类每台机器各自的状态不要注册默认值。

import Foundation

enum Prefs {
  /// 外观（AppAppearance.rawValue）：system 跟随系统 / light 浅色 / dark 深色
  static let appearance = "appearance"
  /// 强调色（AccentChoice.rawValue）：system 跟随系统（默认）/ blue / purple / pink（品牌粉）/ red / orange / yellow / green / graphite
  static let accent = "accent"
  /// 在菜单栏显示图标（第 9 批 M1，默认开）；关掉后再打开一次本 App（访达 / 启动器）打开主界面，快捷键照常
  static let statusItemVisible = "statusItemVisible"
  /// macOS 26 上程序坞 / ⌘⇥ 里一直留着图标（PR #1，2026-11-12；只在 26 上有这一项，见 NSApplication.keepsDockIcon）
  static let dockIconOnTahoe = "dockIconOnTahoe"
  /// 菜单栏图标样式（StatusItem.IconStyle.rawValue）：template 单色剪影（默认）/ color 彩色 App 图标（第 9 批 M2）
  static let statusItemStyle = "statusItemStyle"
  /// 剪贴板面板点外即关；底栏图钉 / ⌘P = 把它关掉（固定）。设置页不再有这个开关（体检 A9），只存图钉状态
  static let clipboardHideOnUnfocus = "clipboardHideOnUnfocus"
  /// 启动器搜哪些浏览器的书签：开着的浏览器 id（Browsers.all 里的，换行分隔；第 12 批起一个键管全部）
  static let launcherBrowserBookmarks = "launcherBrowserBookmarks"
  /// 书签开着的浏览器里，哪些也搜浏览历史（同上，默认都关；书签开关关着的不算，体检 D8）
  static let launcherBrowserHistory = "launcherBrowserHistory"
  /// 书签默认只开 Chrome（Chromium 系的书签不要额外授权，网址是启动器里用得最多的）；Safari 要完全磁盘访问权限，默认关
  static let defaultBookmarkIDs = "chrome"
  /// 旧键（第 12 批前每家一个开关，id、键名、当时的默认值）：migrate 里搬到上面两个列表
  static let launcherBookmarksLegacy = [
    ("chrome", "launcherBookmarksChrome", true), ("edge", "launcherBookmarksEdge", false),
    ("brave", "launcherBookmarksBrave", false),
  ]
  static let launcherHistoryChromeLegacy = "launcherHistoryChrome"
  /// 网页搜索与快捷链接列表（JSON，见 WebSearch）
  static let launcherWebSearchEngines = "launcherWebSearchEngines"
  /// 兜底搜索在有本地结果时也附在最后（默认只在没有结果时出现）
  static let launcherFallbackAlways = "launcherFallbackAlways"
  /// 空搜索框里在收藏后面列「常用」（默认开；issue #2：想要只有搜索框的关掉，有收藏时只列收藏）
  static let launcherShowsFrequent = "launcherShowsFrequent"
  /// 启动器出现在哪（设置 › 启动器，2026-11-04）：同剪贴板面板的 clipboardPanelPosition（top / mouse / last）
  static let launcherPanelPosition = "launcherPanelPosition"
  /// 呼出启动器时搜索框只用英文输入法（Alfred 的 Force Keyboard；离开启动器后恢复）
  static let launcherRomanInput = "launcherRomanInput"
  /// 计算器汇率换算用的那一天的汇率表（ExchangeRates.Table 的 JSON）：取来的缓存，**不注册默认值**（不导出、不同步）
  static let launcherExchangeRates = "launcherExchangeRates"
  /// 计算器汇率换算用过的货币（代码，最近的在前，最多 8 种）：货币候选排前面；这台电脑自己的，**不注册默认值**
  static let launcherRecentCurrencies = "launcherRecentCurrencies"
  /// 启动器的脚本命令（2026-11-07 拍板 E2，默认开）：关掉后自带的和自己的脚本都不出现，内置命令不受影响
  static let launcherScripts = "launcherScripts"
  /// 脚本命令另外添加的文件夹（换行分隔的路径，ScriptLibrary）：这台电脑自己的路径，**不注册默认值**（不导出、不同步）
  static let scriptFolders = "scriptFolders"
  /// 跑脚本用的 PATH：从用户的登录 shell 读到的那一份（ScriptRunner）；这台电脑自己的，**不注册默认值**
  static let scriptShellPath = "scriptShellPath"
  /// 启动器「命令」表里改过的别名（JSON：编号 → 别名，"" = 不要别名；LauncherCommands.Settings）：注册默认值 ""，跟着设置
  /// 导出、同步（拍板 E1：只是设置；别的 Mac 上没有那个脚本就先留着不用）
  static let launcherCommandAliases = "launcherCommandAliases"
  /// 应用别名（AppAliases，JSON：bundle id / 路径 → 逗号分隔的别名）；跟着设置导出、同步。
  static let launcherAppAliases = "launcherAppAliases"
  /// 启动器「命令」表里关掉的（一行一个编号）：同上
  static let launcherCommandsOff = "launcherCommandsOff"
  /// 启动器「命令」表里每条命令的快捷键（JSON：编号 → 组合；脚本命令第三轮 D1，LauncherModel.commandHotKeys）：同上，
  /// 读的时候按录制框的规矩过一遍（文件、同步来的是不可信输入）；别的 Mac 上没有那条脚本就不注册
  static let launcherCommandHotKeys = "launcherCommandHotKeys"
  /// 在这些 App 里停用快捷键（一条一个 App：「bundle id」或「bundle id|动作,动作」，HotKeyBlock；2026-11-10）：注册默认值 []，
  /// 跟着设置导出、备份、同步走（同剪贴板「不记录」的 App）
  static let hotKeyBlockedApps = "hotKeyBlockedApps"
  /// 剪贴板、启动器、翻译浮窗呼出时用挤压入场（设置 › 通用「动效」，默认关；2026-09-29 用户要求三块面板统一，设置从启动器页
  /// 挪到通用页；2026-10-03 转正，去掉「实验」）
  static let panelSqueezeEntrance = "panelSqueezeEntrance"
  /// 旧键：只管启动器时的开关，migrate 里搬到 panelSqueezeEntrance
  static let launcherSqueezeEntranceLegacy = "launcherSqueezeEntrance"
  /// 便签屏幕边缘的「标签倾斜」开关（2026-10-13 加、2026-10-15 去掉：标签一律斜着）：0.5.0 测试包里存过的删掉
  static let notesDeckTiltLegacy = "notesDeckTilt"
  /// 文件搜索已经请求过桌面 / 文稿 / 下载 / iCloud 云盘的访问授权（之后才能读目录判断授权状态，读之前会弹框）
  static let folderAccessRequested = "folderAccessRequested"
  /// 翻译浮窗固定：失焦不隐藏（Esc、⌘W 照样关，体检 A9）
  static let floatingPinned = "floatingPinned"

  /// 普通历史（非收藏 / 片段）保留天数：1 / 7 / 30 / 90 / 365，0 = 永久（体检 A4：只剩这一个旋钮，条数上限的旧键不再读）
  static let clipboardRetentionDays = "clipboardHistoryRetentionDays"
  /// 「保留普通历史」的档位（天，0 = 永久）
  static let clipboardRetentionChoices = [1, 7, 30, 90, 365, 0]
  /// 普通图片总占用上限（MB），0 = 不限；超出时从最旧的普通图片开始删（收藏 / 片段的不算，体检 B2）
  static let clipboardImageBudgetMB = "clipboardImageCacheMaxMb"
  /// 来源 App 的 bundle ID 在这里就不记录（精确匹配，体检 A11）
  static let clipboardExcludedBundleIDs = "clipboardExcludedBundleIDs"
  /// 旧版排除列表（名称或 bundle ID 关键词，子串匹配）：只在 migrate() 里读一次，换成上面的 bundle ID 列表
  static let clipboardExcludedAppsLegacy = "clipboardExcludedApps"
  static let clipboardBlockSensitive = "clipboardBlockSensitive"
  /// 默认粘贴为纯文本：↩ / 双击 / ⌘1–9 走纯文本，⌥↩ 变「保留格式粘贴」（体检 A5；格式总是记下来，旧的采集开关不再读）
  static let clipboardPastePlain = "clipboardPastePlainByDefault"
  static let clipboardImageOCR = "clipboardImageOcr"
  static let clipboardClearOnQuit = "clipboardClearOnExit"
  static let clipboardClearOnLock = "clipboardClearOnLock"
  static let clipboardShowPreview = "clipboardShowPreview"
  /// 检查器的链接卡联网取网页标题、头图和图标（LinkPreview）
  static let clipboardLinkPreview = "clipboardLinkPreview"
  /// 单击条目直接粘贴（设置 › 剪贴板「面板」，默认关 = 单击选中、双击粘贴）；⌘ 单击、⇧ 单击不看它，照常多选
  static let clipboardPasteOnClick = "clipboardPasteOnClick"
  /// 剪贴板面板出现在哪（设置 › 剪贴板「面板」，2026-11-04 用户要求和翻译浮窗一致）：top 鼠标所在屏的上方正中（默认）/
  /// mouse 光标右下（放不下翻到另一侧）/ last 上次拖到的地方（没拖过 = 屏幕上方）。启动器同一套（launcherPanelPosition）
  static let clipboardPanelPosition = "clipboardPanelPosition"

  /// 源语言：没设 = 自动检测。只在翻译浮窗顶部切换，全局记住
  static let translateSource = "translateSourceLang"
  /// 目标语言：没设 = 自动（第一 ⇄ 第二语言）。只在翻译浮窗顶部切换，全局记住
  static let translateTarget = "translateTargetLang"
  /// 第一 / 第二语言（键名是 M4 起的旧名，改名会丢设置）；读取统一走 Lang.preferredPair
  static let translateFirst = "translateNativeLang"
  static let translateSecond = "translateForeignLang"
  static let translateRemoveNewlines = "translateDeleteNewline"
  /// 自动复制译文（主结果：按列表顺序第一个翻成功的服务）
  static let translateAutoCopy = "autoCopy"
  /// 截图翻译时把识别出的原文也写进剪贴板（2026-10-23 用户要的，⌘V 就能贴原文）；默认关：照旧只记进剪贴板历史、
  /// 不换掉剪贴板里原来的东西
  static let translateCopyRecognized = "translateCopyRecognized"
  /// 截图翻译（⌥S）和截图工具栏的「翻译」把译文直接盖回截图上、留在截图页里（2026-11-05，PR #5 + 用户要的开关）；
  /// 默认关：照旧在翻译浮窗里看（多服务对比、能复制译文）
  static let translateScreenshotOverlay = "translateScreenshotOverlay"
  static let translateHistoryEnabled = "translateHistoryEnabled"
  /// 翻译历史保留条数（收藏不算、永不淘汰），0 = 不限（体检 A18：1000 / 5000 / 不限，默认 5000）
  static let translateHistoryLimit = "translateHistoryLimit"
  /// 「保留条数」的档位（0 = 不限）；旧档位（100–2000）在 migrate 里挪到下一档
  static let translateHistoryLimitChoices = [1000, 5000, 0]
  /// 翻译浮窗出现的位置（体检 A13；2026-10-29 加 top 并改成默认）：top 屏幕上方（鼠标所在屏的上方正中，同启动器）/
  /// mouse 跟随鼠标（划词 / 截图翻译 / 复制即译 / 剪贴板「翻译」在光标右下）/ last 上次位置（用户拖到哪就在哪）。
  /// 输入翻译总是上次拖到的位置（top 时没拖过就在上方）。旧版本读到 top 当跟随鼠标（只认 last）
  static let translatePanelPosition = "translatePanelPosition"
  /// 翻译浮窗字号倍数（⌘+ / ⌘- / ⌘0）
  static let translateFontScale = "translateFontScale"
  /// 折叠着的服务 id（换行分隔），跨重启记住
  static let translateCollapsedServices = "translateCollapsedServices"
  /// 复制即译：复制文本后自动弹出翻译浮窗（不抢键盘）
  static let translateCopyToTranslate = "translateClipboardMonitor"
  /// 查单个词时在结果区最上面出系统词典的释义（D4）
  static let translateSystemDictionary = "translateSystemDictionary"
  /// 查单个词时大模型按词典格式回答：读音、词性释义、例句（D4）
  static let translateWordMode = "translateWordMode"
  /// 三块主面板拖出来的大小（2026-11-05 拍板 W1 W2）：宽度（pt）、启动器 / 剪贴板最多露几行（x.5）、翻译浮窗最高多高（pt）。
  /// 都是这台电脑自己的状态（屏幕不一样大），**不注册默认值**、不跟导出走；0 / 没写过 = 默认
  static let launcherPanelWidth = "launcherPanelWidth"
  static let clipboardPanelWidth = "clipboardPanelWidth"
  static let translatePanelWidth = "translatePanelWidth"
  static let launcherPanelRows = "launcherPanelRows"
  static let clipboardPanelRows = "clipboardPanelRows"
  static let translatePanelMaxHeight = "translatePanelMaxHeight"
  /// 英文单词用真人发音（有道词典的录音；关掉或取不到时用系统声音，2026-11-05 拍板 R3）
  static let translateWordRecording = "translateWordRecording"
  /// 英文单词的发音：us（美音，默认）/ uk（英音）
  static let translateWordAccent = "translateWordAccent"

  /// 截图 ⌘S 快速保存的目录（设置 › 截图「快速保存到」选的；「另存为」不改它，体检 A28）；没设 = 系统截屏的存储位置
  nonisolated static let screenshotSaveDirectory = "screenshotSaveDirectory"
  /// 上次截图的区域（NSStringFromRect，全局坐标）：框选时按 D、或用「截取上次区域」热键
  static let screenshotLastRegion = "screenshotLastRegion"
  /// 每个标注工具上次用的样式（JSON 字典，键是 Annotation.Tool 的 rawValue 字符串）；没存过的工具
  /// 由 Annotation.Style.remembered 给默认（红色中号、荧光笔黄色），不进 registerDefaults
  static let screenshotToolStyles = "screenshotToolStyles"
  /// 截图（复制、保存、钉图）时放快门声；还要系统「播放用户界面音效」开着
  static let screenshotShutterSound = "screenshotShutterSound"
  /// 截完图放哪（2026-10-26 晾衣绳拍板 B1，ShotPlacement 的 rawValue）：corner 右下角的常驻缩略图（默认，
  /// 体检 D18 原来那样）/ clothesline 挂到屏幕顶上的晾衣绳上 / none 都不要（只进历史，飞行卡片落地停 0.9 s 就滑走）
  static let screenshotPlacement = "screenshotPlacement"
  /// 截图工具栏（和录屏的录制条、开录后的录制 HUD）贴选区哪边（2026-11-05 拍板，设置 › 截图「工具栏位置」）：
  /// right 栏的右边线对齐选区右边线（默认：从左上往右下拖完，✓ 就在鼠标旁边）/ center 选区下方居中（0.7.1 及之前）。
  /// 读它用 toolbarAlignsRight
  static let screenshotToolbarAlign = "screenshotToolbarAlign"
  /// 截图拷贝为（2026-11-06 拍板，设置 › 截图「截图拷贝为」）：image 剪贴板里放图像（默认）/ file 放一个 PNG 文件，
  /// 同在访达里拷贝一个文件——只搬文字和文件的跨电脑剪贴板（USB 对拷线的配套软件、有的远程工具）也传得过去。
  /// 读它用 copiesShotAsFile
  static let screenshotCopyAs = "screenshotCopyAs"
  /// 长截图自动滚动的速度（长截图面板按钮行上面那一行，记住上次；2026-11-04 用户反馈太快；ScrollSpeed 的 rawValue）：
  /// 每秒滚出 0.3 / 0.6 / 1.2 个选区高，normal 是默认
  static let scrollCaptureSpeed = "scrollCaptureSpeed"
  /// 框选时保持屏幕原色（2026-11-06 用户：截图时像蒙了一层粉色滤镜，取色不友好）：打开后不压暗、悬停的窗口只描边不染色、
  /// 放大镜的十字带只描边。默认关（照 Whisker 压暗 + 粉色高亮）；截图、截图翻译 / 识字、录屏的框选都管
  static let screenshotKeepsColors = "screenshotKeepsColors"
  /// 截图 / 录屏框选时悬停识别窗口里的元素（侧栏、列表、按钮，2026-11-08；拍板 D1 是默认开，同日用户改成默认关）：要辅助功能授权，
  /// 没授权时照旧只认窗口。关掉 = 只认窗口（原来的样子）。截图翻译 / 识字没有悬停，不管它
  static let screenshotFindsElements = "screenshotFindsElements"
  /// 旧键（0.7.0 之前是「留不留常驻缩略图」一个布尔）：migrate 里升成上面那个三选一，关过它的人升级后是「都不要」
  static let screenshotShelfLegacy = "screenshotShelf"
  /// 保留截图历史（2026-10-26 拍板 B3，默认开）：关掉之后不再往历史里记，已经记下的留着（设置里另有「现在清空」）
  static let shotHistory = "shotHistory"
  /// 截图历史留多少天（拍板 A3，默认 30；0 = 不按天清）
  static let shotHistoryDays = "shotHistoryDays"
  /// 截图历史总共最多占多少 MB（拍板 A3，默认 2 GB；超了先删最旧的。0 = 不限）
  static let shotHistoryMegabytes = "shotHistoryMegabytes"
  /// 「最多占用」的档位（MB，0 = 不限）
  static let shotHistoryMegabyteChoices = [1024, 2 * 1024, 5 * 1024, 0]
  /// 旧键（0.7.0 测试版按字节存）：字节数超出设置导出 / 同步收的整数范围（0…100 万），导入、同步、恢复会把 1 / 5 GB 丢回
  /// 默认，所以换成上面按 MB 存的新键（第三轮体检 R9）——不沿用旧键名：更早的测试版收到 MB 的数会当字节用，把历史删到只剩
  /// 一条。migrate 换算一次、删掉旧键；开着同步的旧测试版那台收到旧键的墓碑，回到默认 2 GB（可以接受）
  static let shotHistoryBytesLegacy = "shotHistoryBytes"

  /// 正在录的屏的文件路径（ScreenRecorder.workFile，开录时写、收尾时删）：启动时还在 = 上次闪退了，
  /// ScreenRecorder.recover 把能播的挪进快速保存目录（录屏第 1 批，C7）
  static let screenRecordingInProgress = "screenRecordingInProgress"
  /// 正在录的音的文件路径（录音第 5 批，AudioRecorder 开录时写、收尾时删；闪退后同样由 ScreenRecorder.recover 接手）
  static let audioRecordingInProgress = "audioRecordingInProgress"
  /// 正在压缩的录屏的隐藏临时文件路径（数组；VideoExport.compress 开始时记、做完 / 失败 / 取消时划掉）：启动时还在 =
  /// 上次压到一半退出了，VideoExport.removePartials 删掉那几个文件（第四轮体检 E24）。没有默认值，不进设置导出和同步
  static let compressingFiles = "compressingFiles"
  /// 录屏帧率：30（默认）/ 60（设置 › 录制「录屏」，录屏第 2 批；大屏上 60 不保证满帧，PLAN §10 第 0 批实测）
  static let screenRecordFrameRate = "screenRecordFrameRate"
  /// 开录前倒数几秒：0 不倒数 / 3（默认）/ 5（拍板 R9-a；倒数不进文件）
  static let screenRecordCountdown = "screenRecordCountdown"
  nonisolated static let screenRecordCountdownChoices = [0, 3, 5]
  /// 录屏里画光标（默认开）
  static let screenRecordShowsCursor = "screenRecordShowsCursor"
  /// 录屏的清晰度和编码（第二轮体检 R1，设置 › 录制「录屏」）：ScreenRecorder.Sharpness / Codec 的 rawValue——
  /// 原始（默认，按屏幕像素）/ 标准（按 1x 点尺寸）；H.264（默认）/ HEVC
  static let screenRecordSharpness = "screenRecordSharpness"
  static let screenRecordCodec = "screenRecordCodec"
  /// 显示按键时只显示快捷键（R2，默认关 = 全部按键）：带 ⌘ / ⌃ / ⌥ 的组合、Esc、F 键才进画面，打字不显示
  nonisolated static let screenRecordKeysShortcutsOnly = "screenRecordKeysShortcutsOnly"
  /// 录制条的四个开关，记住上次（录屏第 4 批；设置页不重复，拍板 C4-a）：录系统声音（默认开）、录麦克风（默认关；
  /// 没问过授权时打开只记偏好，按开始、遮罩收起后才问）、显示点按（默认关；点按处画圈，自己画的 InputOverlay）、
  /// 显示按键（手测反馈第 2 批，默认关；按下的键显示在画面底部的胶囊里，同一个 InputOverlay。全局键盘监听要辅助功能授权：
  /// 没授权时打开只记偏好，开录时发现没授权这次不显示、写回关）
  nonisolated static let screenRecordSystemAudio = "screenRecordSystemAudio"
  nonisolated static let screenRecordMicrophone = "screenRecordMicrophone"
  nonisolated static let screenRecordShowsClicks = "screenRecordShowsClicks"
  nonisolated static let screenRecordShowsKeys = "screenRecordShowsKeys"
  /// 录音的来源（录音第 6 批，设置 › 录制「录音」）：AudioRecorder.Source 的 rawValue——麦克风（默认）/ 系统声音 / 两者；
  /// 「两者」被拒麦克风授权时弹回「系统声音」（同录制条的麦克风开关）
  nonisolated static let audioRecordSource = "audioRecordSource"
  /// 按录音快捷键（或点菜单栏、启动器里的「录音」）后立即开始录（手测反馈第 3 批，设置 › 录制「录音」，默认关）：关着时先在
  /// 屏幕底部出录音控制条、不录，点 ● 或再按一次才开始
  static let audioRecordStartsImmediately = "audioRecordStartsImmediately"

  /// 识字后把同一段的换行合成一行（中日文直接连、其它加空格）
  static let ocrJoinLines = "ocrJoinLines"
  /// 识字模型已经为哪个系统版本编好了（OCR.prepare；存系统版本字符串）。这台电脑自己的状态：不注册默认值、不跟着导出
  nonisolated static let ocrPreparedSystem = "ocrPreparedSystem"

  /// 状态屏的状态列表（StatusPreset 数组的 JSON）。**不注册默认值**：没存过 / 解不出 / 为空时用自带的三个
  /// （StatusPreset.load）。照样跟着设置的导出 / 导入和每日备份走——SettingsArchive.kinds 里单独登记（文件里写成一组状态，
  /// 导入时过 StatusPreset.sanitized 再编回 JSON）。键名都带 statusScreen：单说 status 指的是菜单栏图标（StatusItem）
  nonisolated static let statusScreenPresets = "statusScreenPresets"
  /// 状态屏里有人碰了键盘鼠标时浮出退出提示（默认开；关了只剩按住 esc 两秒）
  static let statusScreenExitHint = "statusScreenExitHint"
  /// 按状态屏的全局快捷键时直接进入排在最前面的状态（默认关：先出一排预览卡片，选一个再进，StatusScreen/StatusPicker.swift）
  static let statusScreenHotKeyEntersFirst = "statusScreenHotKeyEntersFirst"
  /// 告示上的动画（Z18a，默认开）：表情动、进入时的出场、有人碰时表情甩一下、屏幕边上探出来的眼睛（有人碰时、隔一阵自己冒）。关着（或系统开着
  /// 「减弱动态效果」）时表情只显示静止画面
  static let statusScreenAnimations = "statusScreenAnimations"
  /// 上次进入的状态的 id（StatusScreen.enter 进入成功时写；选状态的面板默认选中它）。这台电脑自己的状态，
  /// **不注册默认值**：不跟着导出 / 导入走
  static let statusScreenLastPreset = "statusScreenLastPreset"

  /// 提醒列表（Reminder 数组的 JSON，PLAN §10「提醒」）。**不注册默认值**：没存过时是三条示例（都关着，Reminder.load）。
  /// 跟着设置的导出 / 导入和每日备份走——SettingsArchive.kinds 里单独登记（文件里写成一组提醒，导入时按 id 合并）
  nonisolated static let reminders = "reminders"
  /// 每条提醒处理到哪一刻、「稍后」推到几点（ReminderState 的 JSON）。这台电脑自己的状态：不注册默认值、不导出
  nonisolated static let remindersState = "remindersState"
  /// 点「稍后」推几分钟（设置 › 提醒，默认 5，C8）
  static let remindersSnoozeMinutes = "remindersSnoozeMinutes"
  /// 挑的系统表情有动画版时自动下载（EmojiPack，2026-11-05，默认开；设置 › 状态屏 / 提醒两页各一行）
  nonisolated static let emojiPackDownloads = "emojiPackDownloads"
  /// 发表情包之前在本机试：从这台 Mac 上的临时服务器下（只认 http://127.0.0.1 / localhost，EmojiPack.remoteURL）。没有界面，
  /// defaults write 设、用完删；不注册默认值（不导出、不同步）
  nonisolated static let emojiPackTestServer = "emojiPackTestServer"
  /// 「动画表情」气泡里最近挑过的（编号，新的在前，最多 18 个 = 三行；顶上「常用」那一段）。这台电脑自己的：不注册默认值、不导出不同步
  static let emojiPackRecent = "emojiPackRecent"

  /// 全部便签窗口里正文的字号（设置 › 便签，pt；档位见 notesFontSizeChoices，默认 15）。读它走 Prefs.notesFontSize(_:)：
  /// 存了不在档位里的值（导入的文件、手改的偏好）按默认算
  static let notesFontSize = "notesFontSize"
  nonisolated static let notesFontSizeChoices = [13, 15, 17, 20]

  /// 存着的字号 → 真用的字号（纯函数）：不在档位里的回到默认 15
  nonisolated static func notesFontSize(_ stored: Int) -> CGFloat {
    CGFloat(notesFontSizeChoices.contains(stored) ? stored : 15)
  }

  /// 便签正文里的 Markdown 样式（设置 › 便签，默认开；便签第 6 批）：开着时 # 标题、**粗体**、`代码`、[链接](地址)
  /// 这些写法显示成样式，标记只在光标所在的行露出来；关掉后正文照原样显示（任务不归它管）
  static let notesMarkdown = "notesMarkdown"

  /// 便签正文的行距（设置 › 便签，NoteStyles.Spacing 的 rawValue：compact 1.2 / standard 1.45（默认）/ relaxed 1.7；
  /// 手测反馈第 4 批）：全部便签窗口、屏幕边缘的便签、浮动便签都是它。存了不认识的值按默认算（@AppStorage 的初值）
  static let notesLineSpacing = "notesLineSpacing"

  /// 屏幕边缘那叠（设置 › 便签「屏幕边缘」，便签第 3 批）。读它们一律走 NoteDeckOptions(defaults)：不认识的值按默认算。
  /// 总开关（默认开；关掉一个窗口都不建）、哪条边（right 默认 / left；按住 ⌥ 拖药丸也写它）、显示器（main 默认 /
  /// all / chosen = 指定的那一块，是哪块在 notesDeckChosenDisplay）、样式（tabs 带标题的标签，默认 / chips 只有色块）、
  /// 大小（small 0.85 / standard / large 1.25）、感应范围（点：8 / 14 默认 / 28 / 44）、一直展开、不显示药丸、
  /// 悬停预览（默认开）、悬停即打开、盖在全屏 App 上、打开的便签多大（small / medium 默认 / large / extraLarge）、
  /// 标签倾斜（默认关：正着放；开着时那一列标签每张斜 3°，2026-10-13 用户要的）
  nonisolated static let notesDeckEnabled = "notesDeckEnabled"
  nonisolated static let notesDeckEdge = "notesDeckEdge"
  nonisolated static let notesDeckDisplay = "notesDeckDisplay"
  nonisolated static let notesDeckStyle = "notesDeckStyle"
  nonisolated static let notesDeckSize = "notesDeckSize"
  nonisolated static let notesDeckSense = "notesDeckSense"
  nonisolated static let notesDeckAlwaysFanned = "notesDeckAlwaysFanned"
  nonisolated static let notesDeckHidesPill = "notesDeckHidesPill"
  nonisolated static let notesDeckPreview = "notesDeckPreview"
  nonisolated static let notesDeckOpensOnHover = "notesDeckOpensOnHover"
  nonisolated static let notesDeckOverFullScreen = "notesDeckOverFullScreen"
  nonisolated static let notesDeckNoteSize = "notesDeckNoteSize"
  /// 下面四个是这台电脑自己的状态，**不注册默认值**（不跟着导出 / 导入走）：药丸的纵向位置（0 = 可见区最上，1 = 最下；
  /// 没存过 = 0.5 正中，⌥ 拖药丸时写）、「指定某一块」指的是哪块显示器（它的名字；不在时退回主显示器）、
  /// 「便签在屏幕右边缘」那句提示说过了没有（每台电脑只说一次）、示例便签放过了没有（Notes/NoteSample.swift：
  /// 从没有过便签的人第一次给一条，只放一次）
  nonisolated static let notesDeckPosition = "notesDeckPosition"
  nonisolated static let notesDeckChosenDisplay = "notesDeckChosenDisplay"
  nonisolated static let notesDeckHintShown = "notesDeckHintShown"
  nonisolated static let notesSampleAdded = "notesSampleAdded"
  /// 浮动便签（便签第 4 批，Notes/NoteFloat.swift）记着的两样，同样是这台电脑自己的状态、**不注册默认值**：
  /// 拉过的大小（NSStringFromSize 的字符串；下次浮出来还是这么大）、固定着浮在屏幕上的那一张（字典：便签的编号 +
  /// NSStringFromRect 的位置；只有固定着的才记，重启后回到原处——NoteFloatLayout.Place）
  nonisolated static let notesFloatSize = "notesFloatSize"
  /// 0.6.0 之前只记一张的那个键：NoteFloats.restore 读成一条、删掉（同时浮几张之后记在 notesFloatPlaces）
  nonisolated static let notesFloatPlace = "notesFloatPlace"
  /// 固定着浮在屏幕上的**每一张**在哪（便签未来计划 C4，2026-10-22；一组同上的字典，NoteFloats），同样不注册默认值
  nonisolated static let notesFloatPlaces = "notesFloatPlaces"
  /// 便签纸色「最近用过」的自定义颜色（便签未来计划 B4，2026-10-22；一组 "#RRGGBB"，最近的在前、最多 8 个，
  /// NoteColorPicker）：这台电脑自己的状态、**不注册默认值**——别人给的导出文件不该换掉你的最近用过
  nonisolated static let notesRecentColors = "notesRecentColors"
  /// 便签同步（便签未来计划 A，2026-10-22；NoteSyncer）：同步的文件夹（路径字符串）和它的库编号（文件夹根上标记里的那个）。
  /// 这台电脑自己的状态、**不注册默认值**——别人给的导出文件不该改你同步到哪；没有 = 没开同步（A2 默认关）
  nonisolated static let notesSyncFolder = "notesSyncFolder"
  nonisolated static let notesSyncLibrary = "notesSyncLibrary"
  /// 这台电脑上不同步的几部分（全局同步 A3：设置页每类一个勾；"notes" 和 SyncRecords.Kind 的名字），同样是这台电脑自己的
  /// 状态、不注册默认值（没有 = 都同步）
  nonisolated static let syncSkipped = "syncSkipped"
  /// 设置页「同步」那一节要不要说「现在也能同步别的几类」（从只同步便签的版本升上来时存下，勾上哪一类、看过那一节就删；NoteSyncer），
  /// 同样是这台电脑自己的状态、不注册默认值
  nonisolated static let syncNewKindsHint = "syncNewKindsHint"
  /// 全部便签窗口上次用的显示方式（NotesWindowModel.Layout 的 rawValue：wall 便签墙 / list 列表；没存过 = 便签墙，
  /// 2026-10-15 手测反馈）。同窗口位置一样是这台电脑自己的状态、**不注册默认值**：不跟着导出 / 导入走
  nonisolated static let notesWindowLayout = "notesWindowLayout"

  /// 功能开关（2026-10-21，Shell/Feature.swift）：九个功能各一个键「feature.<Feature.rawValue>」（Feature.prefsKey 拼），
  /// 注册的默认值是 Feature.defaultOn（程序坞预览关、别的开；跟着导出 / 导入的「设置」一类走）。读用 Feature.isOn
  nonisolated static let featurePrefix = "feature."
  /// 启动台原来的总开关（启动台没发布过；2026-10-21 并进功能开关 feature.launchpad，migrate 挪一次）
  static let launchpadEnabledLegacy = "launchpadEnabled"

  /// 启动台（第八族，2026-10-18，SPEC §3）：开没开是功能开关 feature.launchpad（Feature）；
  /// 一页几列几行（默认 7 × 5，范围见 choices；改了之后按新容量重新分页，SPEC R10）；布局本身（JSON 字符串，
  /// LaunchpadLayout；**注册空串默认值**，这样 SettingsArchive 的「设置」一类知道它是字符串、用户存过才跟着导出走；
  /// 空串 = 还没存过，第一次打开按系统旧启动台导入或默认排法）。捏合、触发角三个键在第 3 批加在这里
  nonisolated static let launchpadColumns = "launchpadColumns"
  nonisolated static let launchpadRows = "launchpadRows"
  nonisolated static let launchpadLayout = "launchpadLayout"
  /// 存过但读不出来的布局的原文（另存一份，出问题时还能捞回来；不注册默认值、不跟着导出）
  nonisolated static let launchpadLayoutUnreadable = "launchpadLayoutUnreadable"
  /// 上一次导入 / 恢复默认 / 改行列数之前的布局（设置页和岛上的「撤销」用；不注册默认值、不跟着导出）
  nonisolated static let launchpadUndoLayout = "launchpadUndoLayout"
  /// 撤销点是改行列数留的时候，改之前的 [列, 行]（第四轮体检 E12；撤销时一起换回去）。不注册默认值
  nonisolated static let launchpadUndoGrid = "launchpadUndoGrid"
  /// 认到捏合、却因为系统的捏合手势开着让给了系统的那一下，刘海岛说过没有（第四轮体检 U5，只说一次）。不注册默认值
  nonisolated static let launchpadPinchYieldTold = "launchpadPinchYieldTold"
  nonisolated static let launchpadColumnChoices = 5...10
  nonisolated static let launchpadRowChoices = 4...8
  /// 触控板手势（PinchFingers 的 rawValue：off / four / five，默认四指；系统的捏合还开着时我们认到也不打开，
  /// 见 mac-launchpad §6）和灵敏度（PinchRecognizer.Sensitivity 的 rawValue：tight / standard / loose）
  nonisolated static let launchpadPinchGesture = "launchpadPinchGesture"
  nonisolated static let launchpadPinchSense = "launchpadPinchSense"
  /// 触发角（LaunchpadCornerOption 的 rawValue：off / topLeft / topRight / bottomLeft / bottomRight，默认关）
  nonisolated static let launchpadCorner = "launchpadCorner"
  /// 程序坞预览：鼠标停在 App 图标上多久才弹出（毫秒；2026-11-06 用户「悬停一下再出预览」，设置 › 程序坞预览）。
  /// 只管收着时第一次弹，弹着时换图标照旧停稳 80 毫秒就换；读它用 DockPreview.showDelay（认不出的值按 400）
  nonisolated static let dockPreviewDelay = "dockPreviewDelay"
  nonisolated static let dockPreviewDelayChoices = [200, 400, 700, 1000]
  /// 程序坞预览：按 ⌘Tab 切换时也在切换器上方弹窗口预览（2026-11-06 拍板 C2，默认开；程序坞预览关着时不生效）
  nonisolated static let dockPreviewCmdTab = "dockPreviewCmdTab"

  /// 访达右键（第十一族，2026-11-08，FinderLink）：扩展把动作交过来时带的凭证（App 第一次启动时生成，FinderLink.ensureKey；
  /// 扩展从 App 的偏好里读）。这台电脑自己的、**不注册默认值**：不跟着导出 / 导入、同步走
  nonisolated static let finderMenuKey = "finderMenuKey"
  /// 访达右键「用 X 打开」列哪几个 App（bundle id 的数组，默认只有终端；设置 › 访达右键）。扩展读同一个键，
  /// 键名和默认值在 KittyToolsFinder/FinderMenu 里抄了一份
  nonisolated static let finderOpenWithApps = "finderOpenWithApps"
  nonisolated static let finderOpenWithDefault = ["com.apple.Terminal"]
  /// 访达右键把我们的项都收进一个「Kitty Tools ▸」子菜单（默认关、平铺在第一层；设置 › 访达右键，2026-11-08 用户同意的建议）。
  /// 扩展读同一个键，键名和默认值在 KittyToolsFinder/FinderMenu 里抄了一份
  nonisolated static let finderMenuGrouped = "finderMenuGrouped"
  /// 访达右键里每一项显示不显示：键是「finderMenu<名字>」，见 FinderMenu/FinderMenuItem（默认值按项，下面 defaults 里一起注册）。
  /// 访达右键「移动到」「复制到」的常用文件夹（~ 开头的写法；设置 › 访达右键，没存过是桌面、文稿、下载）。这台电脑自己的、
  /// **不注册默认值**（同截图的存储文件夹：别人给的设置文件不该能往右键菜单里加一个文件夹）。扩展读同一个键（键名和默认值
  /// 在 KittyToolsFinder/FinderMenu 里抄了一份）
  nonisolated static let finderTransferFolders = "finderTransferFolders"
  /// 最近用「移动到 / 复制到 ▸ 选择文件夹…」选过的（~ 开头的写法，最近的在前，存 5 个、子菜单里列 3 个；FileMoves.remember）。
  /// 这台电脑自己的、不注册默认值（同常用文件夹）；扩展读同一个键
  nonisolated static let finderRecentFolders = "finderRecentFolders"
  nonisolated static let finderTransferDefault = ["~/Desktop", "~/Documents", "~/Downloads"]
  /// 访达右键「剪切」了几样、那一刻剪贴板的 changeCount（FileMoves.cut）：扩展看到剪贴板没换过才列「粘贴 N 项」。剪切的清单
  /// 本身只在 App 内存里（别的程序改偏好塞不进要搬的东西）。这台电脑自己的、**不注册默认值**，App 启动时清掉
  nonisolated static let finderCutCount = "finderCutCount"
  nonisolated static let finderCutChange = "finderCutChange"
  /// 访达右键移动、复制、压缩、解压用着的隐藏临时名（路径；FileMoves.temporary）：App 退出时没收尾的，下次启动删掉。
  /// 这台电脑自己的状态、不注册默认值
  nonisolated static let finderTemporaries = "finderTemporaries"
  /// 访达右键「新建文件 ▸ 自定义后缀…」上次填的后缀（框里先填好它）。这台电脑自己的、不注册默认值
  nonisolated static let finderLastSuffix = "finderLastSuffix"

  /// 看过的版本号：没有 = 首次安装（打开欢迎引导），和当前不同 = 刚更新（刘海岛「已更新到 x」+ 本版摘要，不开设置窗，体检 A29）。
  /// 首次安装时**引导走完才记**（点「开始使用」或关掉引导；第四轮体检 E1）：中途退出（授权屏幕录制后系统要求重开）下次接着开
  nonisolated static let lastSeenVersion = "lastSeenVersion"
  /// 欢迎引导做到了第几屏（OnboardingView.Screen 的 rawValue）：没走完就退出、下次接着开时从哪一屏起（E1）；走完删掉。
  /// 这台电脑自己的状态，不注册默认值
  nonisolated static let onboardingScreen = "onboardingScreen"
  /// 「去授权」请求过辅助功能 / 屏幕录制的系统授权框没有（第四轮体检 U10：系统只弹一次，请求过了再点就直接打开系统设置那一页，
  /// 不再两个窗一起出来）。这台电脑自己的状态，不注册默认值
  static let accessibilityRequested = "accessibilityRequested"
  static let screenRecordingRequested = "screenRecordingRequested"
  /// 自动检查更新（启动后一次、之后每天一次）
  static let updateAutoCheck = "updateAutoCheck"
  /// 已经用刘海岛提示过的新版本号（后台检查每个版本只提示一次）
  static let updateNotifiedVersion = "updateNotifiedVersion"
  /// 设置窗上次看的页（SettingsPage.rawValue）
  static let settingsPage = "settingsPage"
  /// 设置侧栏收起了哪几组（组标题，换行隔开；SettingsRoot）。这台电脑自己的界面状态：不注册默认值、不导出不同步
  static let settingsCollapsedGroups = "settingsCollapsedGroups"
  /// 设置侧栏底下「已关闭」那组展开着没有（默认收起；SettingsRoot）。这台电脑自己的界面状态：不注册默认值、不导出不同步
  static let settingsShowsOffFeatures = "settingsShowsOffFeatures"
  /// 刘海岛那一张（点刘海、快捷键「打开刘海岛」叫出来的）上快捷动作的先后、关掉的几个（设置 › 刘海岛，2026-11-12 PR #17）：
  /// 一行一个 HotKeyAction 的 rawValue，读的时候过 HotKeyAction.islandOrder / islandOff；空着 = 照原来的先后、全开。
  /// 跟着设置导出、同步
  static let islandActionOrder = "islandActionOrder"
  static let islandActionsOff = "islandActionsOff"
  /// 那一张上列不列最近的提示（默认列）
  static let islandShowsHistory = "islandShowsHistory"
  /// 点刘海、停在刘海上、两指往下滑叫出那一张（默认开；刘海岛扩展 G2：装了别的刘海 App 的人关掉）
  static let islandNotchClicks = "islandNotchClicks"
  /// 刘海岛上的系统一瞬提示（刘海岛扩展 D1，Shell/SystemNotices.swift）：接上 / 拔掉电源、低电量、耳机连上、断网 / 恢复，
  /// 每种一个开关，默认都关（不开就不监听）
  static let islandNoticePower = "islandNoticePower"
  static let islandNoticeBattery = "islandNoticeBattery"
  static let islandNoticeHeadphones = "islandNoticeHeadphones"
  static let islandNoticeNetwork = "islandNoticeNetwork"
  /// 新功能标记（Shell/WhatsNew.swift，2026-11-05）的账：各版本在这台 Mac 上第一次打开的时刻（版本号 → Date，从这一刻起挂 30 天）、
  /// 碰过哪几个（WhatsNew.Entry.id 的数组）。这台电脑自己的状态：不注册默认值、不导出不同步
  static let whatsNewStarted = "whatsNewStarted"
  static let whatsNewTouched = "whatsNewTouched"
  /// 设置与数据的每日自动备份（Storage/SettingsBackup.swift，2026-10-08）。下面六个都是这台电脑自己的状态，**不注册默认值**：
  /// 不跟着导出 / 导入走（别人给的文件不该能关掉备份、改备份存到哪）。
  /// 开关：没存过 = 开——读它用 SettingsBackup.isEnabled 或 @AppStorage 的初值 true，别用 bool(forKey:)
  nonisolated static let settingsBackupEnabled = "settingsBackupEnabled"
  /// 每天那份另存一份到哪（用户选的文件夹的路径）；没选 = 只存在本机的数据目录里
  nonisolated static let settingsBackupFolder = "settingsBackupFolder"
  /// 那个文件夹在访达里的名字：选的那一刻取了存下。设置页显示它，不每次去问文件夹（它可能在卡住的网络盘上）
  nonisolated static let settingsBackupFolderName = "settingsBackupFolderName"
  /// 这台电脑的编号（4 位十六进制，SettingsBackup.installID 第一次要用时生成）：另存的文件夹里文件名带它
  nonisolated static let settingsBackupID = "settingsBackupID"
  /// 本机那份上次没备成的原因、哪一类太多没带（设置 › 通用「已有的备份」下面的橙字）；都成了就删掉这个键
  nonisolated static let settingsBackupProblem = "settingsBackupProblem"
  /// 另存的那份上次没存成的原因（「另存一份到」下面的橙字）；存成了、换了文件夹就删掉这个键
  nonisolated static let settingsBackupFolderProblem = "settingsBackupFolderProblem"

  static func registerDefaults() { UserDefaults.standard.register(defaults: defaults) }

  /// 各项设置的默认值（registerDefaults 注册的就是它）
  static var defaults: [String: Any] {
    [
      appearance: AppAppearance.system.rawValue,
      accent: AccentChoice.system.rawValue,
      statusItemVisible: true,
      dockIconOnTahoe: true,
      statusItemStyle: StatusItem.IconStyle.template.rawValue,
      clipboardHideOnUnfocus: true,
      launcherBrowserBookmarks: defaultBookmarkIDs,
      launcherBrowserHistory: "",
      launcherFallbackAlways: false,
      launcherShowsFrequent: true,
      launcherRomanInput: false,
      launcherScripts: true,
      launcherCommandAliases: "",
      launcherAppAliases: "",
      launcherCommandsOff: "",
      launcherCommandHotKeys: "",
      hotKeyBlockedApps: [String](),
      launchpadColumns: 7,
      launchpadRows: 5,
      launchpadLayout: "",
      launchpadPinchGesture: PinchFingers.four.rawValue,
      launchpadPinchSense: PinchRecognizer.Sensitivity.standard.rawValue,
      launchpadCorner: LaunchpadCornerOption.off.rawValue,
      dockPreviewDelay: 400,
      dockPreviewCmdTab: true,
      finderOpenWithApps: finderOpenWithDefault,
      panelSqueezeEntrance: false,
      floatingPinned: false,
      updateAutoCheck: true,
      clipboardRetentionDays: 7,
      clipboardImageBudgetMB: 512,
      clipboardExcludedBundleIDs: ClipboardFilter.defaultExcluded,
      clipboardBlockSensitive: true,
      clipboardPastePlain: false,
      clipboardImageOCR: true,
      clipboardClearOnQuit: false,
      clipboardClearOnLock: false,
      clipboardShowPreview: true,
      clipboardLinkPreview: true,
      clipboardPasteOnClick: false,
      clipboardPanelPosition: "top",
      launcherPanelPosition: "top",
      translateFirst: Lang.zhHans.rawValue,
      translateSecond: Lang.en.rawValue,
      translateRemoveNewlines: false,
      translateAutoCopy: false,
      translateCopyRecognized: false,
      translateScreenshotOverlay: false,
      translateHistoryEnabled: true,
      translateHistoryLimit: 5000,
      translatePanelPosition: "top",
      translateCopyToTranslate: false,
      translateSystemDictionary: true,
      translateWordMode: true,
      translateWordRecording: true,
      translateWordAccent: "us",
      translateFontScale: 1.0,
      translateCollapsedServices: "",
      ocrJoinLines: false,
      screenshotShutterSound: true,
      screenshotPlacement: ShotPlacement.corner.rawValue,
      screenshotToolbarAlign: "right",
      screenshotCopyAs: "image",
      scrollCaptureSpeed: ScrollSpeed.normal.rawValue,
      screenshotKeepsColors: false,
      screenshotFindsElements: false,
      shotHistory: true,
      shotHistoryDays: 30,
      shotHistoryMegabytes: 2 * 1024,
      screenRecordFrameRate: 30,
      screenRecordCountdown: 3,
      screenRecordShowsCursor: true,
      screenRecordSharpness: ScreenRecorder.Sharpness.original.rawValue,
      screenRecordCodec: ScreenRecorder.Codec.h264.rawValue,
      screenRecordKeysShortcutsOnly: false,
      screenRecordSystemAudio: true,
      screenRecordMicrophone: false,
      screenRecordShowsClicks: false,
      screenRecordShowsKeys: false,
      audioRecordSource: AudioRecorder.Source.microphone.rawValue,
      audioRecordStartsImmediately: false,
      statusScreenExitHint: true,
      statusScreenHotKeyEntersFirst: false,
      statusScreenAnimations: true,
      remindersSnoozeMinutes: 5,
      emojiPackDownloads: true,
      notesFontSize: 15,
      notesMarkdown: true,
      notesLineSpacing: NoteStyles.Spacing.standard.rawValue,
      notesDeckEnabled: true,
      notesDeckEdge: NoteDeckOptions.Edge.right.rawValue,
      notesDeckDisplay: NoteDeckOptions.DisplayMode.main.rawValue,
      notesDeckStyle: NoteDeckOptions.TabStyle.tabs.rawValue,
      notesDeckSize: NoteDeckOptions.Size.standard.rawValue,
      notesDeckSense: 14,
      notesDeckAlwaysFanned: false,
      notesDeckHidesPill: false,
      notesDeckPreview: true,
      notesDeckOpensOnHover: false,
      notesDeckOverFullScreen: false,
      notesDeckNoteSize: NoteDeckOptions.NoteSize.medium.rawValue,
      finderMenuGrouped: false,
      islandActionOrder: "",
      islandActionsOff: "",
      islandShowsHistory: true,
      islandNotchClicks: true,
      islandNoticePower: false,
      islandNoticeBattery: false,
      islandNoticeHeadphones: false,
      islandNoticeNetwork: false,
    ].merging(Feature.allCases.map { ($0.prefsKey, $0.defaultOn as Any) }) { current, _ in current }
      .merging(FinderMenuItem.allCases.map { ($0.prefsKey, $0.defaultOn as Any) }) { current, _ in
        current
      }
  }

  /// 截图工具栏贴选区右边（screenshotToolbarAlign 不是 center 都算靠右：没存过、认不出来按默认）
  static func toolbarAlignsRight(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.string(forKey: screenshotToolbarAlign) != "center"
  }

  /// 截图拷贝成 PNG 文件（screenshotCopyAs 是 file；没存过、认不出来按默认的图像）
  static func copiesShotAsFile(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.string(forKey: screenshotCopyAs) == "file"
  }

  /// 截完图放哪（2026-10-26 晾衣绳拍板 B1）：右下角的常驻缩略图 / 挂到晾衣绳上 / 都不要（只进历史）。
  /// 两处放图二选一：挂到绳子上就不飞角落了
  enum ShotPlacement: String, CaseIterable {
    case corner, clothesline, none

    var title: String {
      switch self {
      case .corner: "角落的缩略图"
      case .clothesline: "挂到晾衣绳上"
      case .none: "都不要"
      }
    }

    /// 偏好里存的（认不出来按默认的角落）
    static func current(_ defaults: UserDefaults = .standard) -> ShotPlacement {
      defaults.string(forKey: Prefs.screenshotPlacement).flatMap(ShotPlacement.init(rawValue:))
        ?? .corner
    }
  }

  /// 长截图自动滚动的速度（scrollCaptureSpeed）：每秒想滚出几个选区高，实际发多少滚轮由 ScrollCapture 按量出来的位移校准
  enum ScrollSpeed: String, CaseIterable {
    case slow, normal, fast

    var title: String {
      switch self {
      case .slow: "慢"
      case .normal: "标准"
      case .fast: "快"
      }
    }

    /// 每秒滚出几个选区高（自动滚动是匀速的，2026-11-05；以前一步一跳、平均每秒一个半到两个选区高）
    var heightsPerSecond: CGFloat {
      switch self {
      case .slow: 0.3
      case .normal: 0.6
      case .fast: 1.2
      }
    }

    /// 偏好里存的（认不出来按标准）
    static func current(_ defaults: UserDefaults = .standard) -> ScrollSpeed {
      defaults.string(forKey: Prefs.scrollCaptureSpeed).flatMap(ScrollSpeed.init(rawValue:))
        ?? .normal
    }
  }

  /// 旧偏好升级（启动时在 registerDefaults 之后跑，幂等）：
  /// 排除 App 从关键词换成 bundle ID 列表（只在新键没存过、旧键改过时跑一次，体检 A11）；
  /// 保留天数不在新档位里的（旧的 3 / 14 天）挪到下一档，免得弹出菜单显示空白（体检 A4）；
  /// 翻译历史保留条数同理（旧的 100–2000 挪到 1000 / 5000，体检 A18）；
  /// 浏览器书签 / 历史的每家一个开关搬进两个 id 列表（第 12 批，只在新键没存过、旧键改过时，删掉旧键）；
  /// 去掉了的「标签倾斜」开关（notesDeckTiltLegacy）存过的值删掉；
  /// 启动台原来的总开关 launchpadEnabled 挪进功能开关 feature.launchpad（只在新键没存过时，删掉旧键）；
  /// 常驻缩略图的布尔开关 screenshotShelf 升成「截完图放哪」三选一（晾衣绳拍板 B1，只在新键没存过、旧键关着时）；
  /// 截图历史的上限从旧键（字节）换进新键（MB，只在新键没存过时；0 照旧是不限），删掉旧键
  static func migrate(
    _ defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier
  ) {
    // 只看用户自己存过的值（registerDefaults 给的默认不在持久域里）
    let domain = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    if domain[clipboardExcludedBundleIDs] == nil,
      let old = domain[clipboardExcludedAppsLegacy] as? [String]
    {
      defaults.set(ClipboardFilter.migratedExcluded(old), forKey: clipboardExcludedBundleIDs)
      defaults.removeObject(forKey: clipboardExcludedAppsLegacy)
    }
    if domain[panelSqueezeEntrance] == nil, let old = domain[launcherSqueezeEntranceLegacy] as? Bool
    {
      defaults.set(old, forKey: panelSqueezeEntrance)
    }
    defaults.removeObject(forKey: launcherSqueezeEntranceLegacy)
    // 常驻缩略图的布尔开关升成「截完图放哪」三选一（晾衣绳拍板 B1）：关过它的人是「都不要」，
    // 没存过（= 开着）照常是角落的缩略图。旧键留着不删：退回旧版本还能用
    if domain[screenshotPlacement] == nil, domain[screenshotShelfLegacy] as? Bool == false {
      defaults.set(ShotPlacement.none.rawValue, forKey: screenshotPlacement)
    }
    if domain[shotHistoryMegabytes] == nil, let bytes = domain[shotHistoryBytesLegacy] as? Int {
      // 不到 1 MB 的正数算 1 MB（换成 0 就成了不限）
      defaults.set(bytes > 0 ? max(1, bytes / (1024 * 1024)) : 0, forKey: shotHistoryMegabytes)
    }
    defaults.removeObject(forKey: shotHistoryBytesLegacy)
    defaults.removeObject(forKey: notesDeckTiltLegacy)
    let launchpad = Feature.launchpad.prefsKey
    if domain[launchpad] == nil, let old = domain[launchpadEnabledLegacy] as? Bool {
      defaults.set(old, forKey: launchpad)
    }
    defaults.removeObject(forKey: launchpadEnabledLegacy)
    if domain[launcherBrowserBookmarks] == nil,
      launcherBookmarksLegacy.contains(where: { domain[$0.1] != nil })
    {
      let on = launcherBookmarksLegacy.filter { domain[$0.1] as? Bool ?? $0.2 }.map { $0.0 }
      defaults.set(on.joined(separator: "\n"), forKey: launcherBrowserBookmarks)
    }
    if domain[launcherBrowserHistory] == nil, domain[launcherHistoryChromeLegacy] as? Bool == true {
      defaults.set("chrome", forKey: launcherBrowserHistory)
    }
    for key in launcherBookmarksLegacy.map({ $0.1 }) + [launcherHistoryChromeLegacy] {
      defaults.removeObject(forKey: key)
    }
    let days = defaults.integer(forKey: clipboardRetentionDays)
    if !clipboardRetentionChoices.contains(days) {
      defaults.set(
        clipboardRetentionChoices.first { $0 >= days } ?? 0, forKey: clipboardRetentionDays)
    }
    let limit = defaults.integer(forKey: translateHistoryLimit)
    if !translateHistoryLimitChoices.contains(limit) {
      defaults.set(
        translateHistoryLimitChoices.first { $0 >= limit } ?? 0, forKey: translateHistoryLimit)
    }
  }
}
