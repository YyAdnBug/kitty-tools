// 偏好键名与默认值的唯一出处（PLAN §4）。键名一经发布不改（改名会丢用户设置），新键一律 camelCase。

import Foundation

enum Prefs {
  /// 外观（AppAppearance.rawValue）：system 跟随系统 / light 浅色 / dark 深色
  static let appearance = "appearance"
  /// 强调色（AccentChoice.rawValue）：system 跟随系统（默认）/ blue / purple / pink（品牌粉）/ red / orange / yellow / green / graphite
  static let accent = "accent"
  /// 在菜单栏显示图标（第 9 批 M1，默认开）；关掉后再打开一次本 App（访达 / 启动器）回到设置，快捷键照常
  static let statusItemVisible = "statusItemVisible"
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
  /// 呼出启动器时搜索框只用英文输入法（Alfred 的 Force Keyboard；离开启动器后恢复）
  static let launcherRomanInput = "launcherRomanInput"
  /// 剪贴板、启动器、翻译浮窗呼出时用挤压入场（实验，默认关；2026-09-29 用户要求三块面板统一，设置从启动器页挪到通用页）
  static let panelSqueezeEntrance = "panelSqueezeEntrance"
  /// 旧键：只管启动器时的开关，migrate 里搬到 panelSqueezeEntrance
  static let launcherSqueezeEntranceLegacy = "launcherSqueezeEntrance"
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

  /// 源语言：没设 = 自动检测。只在翻译浮窗顶部切换，全局记住
  static let translateSource = "translateSourceLang"
  /// 目标语言：没设 = 自动（第一 ⇄ 第二语言）。只在翻译浮窗顶部切换，全局记住
  static let translateTarget = "translateTargetLang"
  /// 第一 / 第二语言（键名是 M4 起的旧名，改名会丢设置）；读取统一走 Lang.preferredPair
  static let translateFirst = "translateNativeLang"
  static let translateSecond = "translateForeignLang"
  static let translateRemoveNewlines = "translateDeleteNewline"
  /// 自动复制第一个服务的译文
  static let translateAutoCopy = "autoCopy"
  static let translateHistoryEnabled = "translateHistoryEnabled"
  /// 翻译历史保留条数（收藏不算、永不淘汰），0 = 不限（体检 A18：1000 / 5000 / 不限，默认 5000）
  static let translateHistoryLimit = "translateHistoryLimit"
  /// 「保留条数」的档位（0 = 不限）；旧档位（100–2000）在 migrate 里挪到下一档
  static let translateHistoryLimitChoices = [1000, 5000, 0]
  /// 翻译浮窗出现的位置（体检 A13）：mouse 跟随鼠标（默认，划词 / 截图翻译 / 复制即译 / 剪贴板「翻译」在光标右下）/
  /// last 上次位置（用户拖到哪就在哪）。输入翻译总是上次位置
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

  /// 截图 ⌘S 快速保存的目录（设置 › 截图「快速保存到」选的；「另存为」不改它，体检 A28）；没设 = 系统截屏的存储位置
  static let screenshotSaveDirectory = "screenshotSaveDirectory"
  /// 上次截图的区域（NSStringFromRect，全局坐标）：框选时按 D、或用「截取上次区域」热键
  static let screenshotLastRegion = "screenshotLastRegion"
  /// 每个标注工具上次用的样式（JSON 字典，键是 Annotation.Tool 的 rawValue 字符串）；没存过的工具
  /// 由 Annotation.Style.remembered 给默认（红色中号、荧光笔黄色），不进 registerDefaults
  static let screenshotToolStyles = "screenshotToolStyles"
  /// 截图（复制、保存、钉图）时放快门声；还要系统「播放用户界面音效」开着
  static let screenshotShutterSound = "screenshotShutterSound"
  /// 拷贝 / 快速保存后在屏幕右下角留常驻缩略图（ShotShelf）；关掉后飞行卡片落地停 0.9 s 就滑走（体检 D18）
  static let screenshotShelf = "screenshotShelf"

  /// 正在录的屏的文件路径（ScreenRecorder.workFile，开录时写、收尾时删）：启动时还在 = 上次闪退了，
  /// ScreenRecorder.recover 把能播的挪进快速保存目录（录屏第 1 批，C7）
  static let screenRecordingInProgress = "screenRecordingInProgress"
  /// 正在录的音的文件路径（录音第 5 批，AudioRecorder 开录时写、收尾时删；闪退后同样由 ScreenRecorder.recover 接手）
  static let audioRecordingInProgress = "audioRecordingInProgress"
  /// 录屏帧率：30（默认）/ 60（设置 › 截图「录屏」，录屏第 2 批；大屏上 60 不保证满帧，PLAN §10 第 0 批实测）
  static let screenRecordFrameRate = "screenRecordFrameRate"
  /// 开录前倒数几秒：0 不倒数 / 3（默认）/ 5（拍板 R9-a；倒数不进文件）
  static let screenRecordCountdown = "screenRecordCountdown"
  nonisolated static let screenRecordCountdownChoices = [0, 3, 5]
  /// 录屏里画光标（默认开）
  static let screenRecordShowsCursor = "screenRecordShowsCursor"
  /// 录屏的清晰度和编码（第二轮体检 R1，设置 › 截图「录屏」）：ScreenRecorder.Sharpness / Codec 的 rawValue——
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
  /// 录音的来源（录音第 6 批，设置 › 截图「录音」）：AudioRecorder.Source 的 rawValue——麦克风（默认）/ 系统声音 / 两者；
  /// 「两者」被拒麦克风授权时弹回「系统声音」（同录制条的麦克风开关）
  nonisolated static let audioRecordSource = "audioRecordSource"
  /// 按录音快捷键（或点菜单栏、启动器里的「录音」）后立即开始录（手测反馈第 3 批，设置 › 截图「录音」，默认关）：关着时先在
  /// 屏幕底部出录音控制条、不录，点 ● 或再按一次才开始
  static let audioRecordStartsImmediately = "audioRecordStartsImmediately"

  /// 识字后把同一段的换行合成一行（中日文直接连、其它加空格）
  static let ocrJoinLines = "ocrJoinLines"

  /// 上次启动的版本号：没有 = 首次安装（打开欢迎引导），和当前不同 = 刚更新（刘海岛「已更新到 x」+ 本版摘要，不开设置窗，体检 A29）
  static let lastSeenVersion = "lastSeenVersion"
  /// 自动检查更新（启动后一次、之后每天一次）
  static let updateAutoCheck = "updateAutoCheck"
  /// 已经用刘海岛提示过的新版本号（后台检查每个版本只提示一次）
  static let updateNotifiedVersion = "updateNotifiedVersion"
  /// 设置窗上次看的页（SettingsPage.rawValue）
  static let settingsPage = "settingsPage"

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      appearance: AppAppearance.system.rawValue,
      accent: AccentChoice.system.rawValue,
      statusItemVisible: true,
      statusItemStyle: StatusItem.IconStyle.template.rawValue,
      clipboardHideOnUnfocus: true,
      launcherBrowserBookmarks: defaultBookmarkIDs,
      launcherBrowserHistory: "",
      launcherFallbackAlways: false,
      launcherRomanInput: false,
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
      translateFirst: Lang.zhHans.rawValue,
      translateSecond: Lang.en.rawValue,
      translateRemoveNewlines: false,
      translateAutoCopy: false,
      translateHistoryEnabled: true,
      translateHistoryLimit: 5000,
      translatePanelPosition: "mouse",
      translateCopyToTranslate: false,
      translateSystemDictionary: true,
      translateWordMode: true,
      translateFontScale: 1.0,
      translateCollapsedServices: "",
      ocrJoinLines: false,
      screenshotShutterSound: true,
      screenshotShelf: true,
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
    ])
  }

  /// 旧偏好升级（启动时在 registerDefaults 之后跑，幂等）：
  /// 排除 App 从关键词换成 bundle ID 列表（只在新键没存过、旧键改过时跑一次，体检 A11）；
  /// 保留天数不在新档位里的（旧的 3 / 14 天）挪到下一档，免得弹出菜单显示空白（体检 A4）；
  /// 翻译历史保留条数同理（旧的 100–2000 挪到 1000 / 5000，体检 A18）；
  /// 浏览器书签 / 历史的每家一个开关搬进两个 id 列表（第 12 批，只在新键没存过、旧键改过时，删掉旧键）
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
