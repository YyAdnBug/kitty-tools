// 偏好键名与默认值的唯一出处（PLAN §4）。键名一经发布不改（改名会丢用户设置），新键一律 camelCase。

import Foundation

enum Prefs {
  /// 外观（AppAppearance.rawValue）：system 跟随系统 / light 浅色 / dark 深色
  static let appearance = "appearance"
  /// 强调色（AccentChoice.rawValue）：system 跟随系统（默认）/ blue / purple / pink（品牌粉）/ red / orange / yellow / green / graphite
  static let accent = "accent"
  /// 剪贴板面板点外即关；面板上的图钉 = 把它关掉
  static let clipboardHideOnUnfocus = "clipboardHideOnUnfocus"
  /// 启动器搜哪些浏览器的书签
  static let launcherBookmarksChrome = "launcherBookmarksChrome"
  static let launcherBookmarksEdge = "launcherBookmarksEdge"
  static let launcherBookmarksBrave = "launcherBookmarksBrave"
  /// 网页搜索与快捷链接列表（JSON，见 WebSearch）
  static let launcherWebSearchEngines = "launcherWebSearchEngines"
  /// 兜底搜索在有本地结果时也附在最后（默认只在没有结果时出现）
  static let launcherFallbackAlways = "launcherFallbackAlways"
  /// 呼出启动器时搜索框只用英文输入法（Alfred 的 Force Keyboard；离开启动器后恢复）
  static let launcherRomanInput = "launcherRomanInput"
  /// 启动器呼出时用挤压入场（实验，像 macOS 26 的 Spotlight）
  static let launcherSqueezeEntrance = "launcherSqueezeEntrance"
  /// 文件搜索已经请求过桌面 / 文稿 / 下载 / iCloud 云盘的访问授权（之后才能读目录判断授权状态，读之前会弹框）
  static let folderAccessRequested = "folderAccessRequested"
  /// 翻译浮窗固定：失焦不隐藏、Esc 不关闭
  static let floatingPinned = "floatingPinned"

  /// 普通历史（非收藏 / 片段 / 分组）最多保留几条，0 = 不限
  static let clipboardHistoryMax = "clipboardHistoryMax"
  /// 普通历史保留天数，0 = 永久
  static let clipboardRetentionDays = "clipboardHistoryRetentionDays"
  /// 图片总占用上限（MB），0 = 不限；超出时从最旧的普通图片开始删
  static let clipboardImageBudgetMB = "clipboardImageCacheMaxMb"
  /// 来源 App 名称或 bundle ID 包含这些关键词就不记录
  static let clipboardExcludedApps = "clipboardExcludedApps"
  static let clipboardBlockSensitive = "clipboardBlockSensitive"
  static let clipboardKeepRichText = "clipboardKeepRichText"
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
  static let translateHistoryLimit = "translateHistoryLimit"
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

  /// 截图 ⌘S 快速保存的目录（上次「另存为」选的目录）；没设 = 系统截屏的存储位置
  static let screenshotSaveDirectory = "screenshotSaveDirectory"
  /// 上次截图的区域（NSStringFromRect，全局坐标）：框选时按 D、或用「截取上次区域」热键
  static let screenshotLastRegion = "screenshotLastRegion"
  /// 每个标注工具上次用的样式（JSON 字典，键是 Annotation.Tool 的 rawValue 字符串）；没存过的工具
  /// 由 Annotation.Style.remembered 给默认（红色中号、荧光笔黄色），不进 registerDefaults
  static let screenshotToolStyles = "screenshotToolStyles"
  /// 截图（复制、保存、钉图）时放快门声；还要系统「播放用户界面音效」开着
  static let screenshotShutterSound = "screenshotShutterSound"

  /// 识字后把同一段的换行合成一行（中日文直接连、其它加空格）
  static let ocrJoinLines = "ocrJoinLines"

  /// 上次启动的版本号：没有 = 首次安装（打开欢迎引导），和当前不同 = 刚更新（打开关于页看更新内容）
  static let lastSeenVersion = "lastSeenVersion"
  /// 设置窗上次看的页（SettingsPage.rawValue）
  static let settingsPage = "settingsPage"

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      appearance: AppAppearance.system.rawValue,
      accent: AccentChoice.system.rawValue,
      clipboardHideOnUnfocus: true,
      // Chrome 书签不需要额外授权，默认开（网址是启动器里用得最多的）
      launcherBookmarksChrome: true,
      launcherBookmarksEdge: false,
      launcherBookmarksBrave: false,
      launcherFallbackAlways: false,
      launcherRomanInput: false,
      launcherSqueezeEntrance: false,
      floatingPinned: false,
      clipboardHistoryMax: 0,  // 不限条数，只按天数裁剪
      clipboardRetentionDays: 7,
      clipboardImageBudgetMB: 512,
      // 密码管理器大多会打 ConcealedType 标记，这里兜底；「密码」是 macOS 15 自带的 Passwords
      clipboardExcludedApps: [
        "1Password", "Bitwarden", "KeePass", "Keychain", "钥匙串", "com.apple.Passwords",
      ],
      clipboardBlockSensitive: true,
      clipboardKeepRichText: true,
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
      translateHistoryLimit: 500,
      translateCopyToTranslate: false,
      translateSystemDictionary: true,
      translateWordMode: true,
      translateFontScale: 1.0,
      translateCollapsedServices: "",
      ocrJoinLines: false,
      screenshotShutterSound: true,
    ])
  }
}
