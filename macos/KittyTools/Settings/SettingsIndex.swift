// 设置项登记表（设置改版 S7 S8，2026-11-18，规格 macos/build/research/settings-redesign-2026-11-18/SPEC.md §1.7–1.9）：
// 设置里的每一行登记一项——在哪一页、标题（和页面上同一个字面量，目录里是同一个 key）、额外的搜索词、读写哪些偏好键。
// 侧栏搜索时最上面一组「设置项」列对上的行，选一项就打开那一页、滚到那一行、描一圈强调色两秒（SettingsNavigation.open）；
// 剪贴板面板、翻译浮窗这些地方的「设置…」也经它直达那一行（AppDelegate.showSettings(_:)）。
// 视图上每一行挂 `.settingsAnchor(.x)`，每张分组表单外面挂 `.settingsScrollTarget()`；单测（SettingsIndexTests）读源码查每一项
// 都挂了、只挂了一次。新加一行设置就在这里加一项、在那一行挂上锚。

import SwiftUI

enum SettingsItem: String, CaseIterable, Identifiable {
  // 通用
  case generalFeatures = "general.features"
  case generalPlugins = "general.plugins"
  case generalLanguage = "general.language"
  case generalAppearance = "general.appearance"
  case generalAccent = "general.accent"
  case generalSqueeze = "general.squeeze"
  case generalMenuBarIcon = "general.menuBarIcon"
  case generalIconStyle = "general.iconStyle"
  case generalDockIcon = "general.dockIcon"
  case generalLogin = "general.login"
  case generalAccessibility = "general.accessibility"
  case generalScreenRecording = "general.screenRecording"
  case generalMicrophone = "general.microphone"
  case generalClipboardAccess = "general.clipboardAccess"
  case generalSync = "general.sync"
  case generalSyncPeers = "general.syncPeers"
  case generalTransfer = "general.transfer"
  case generalBackup = "general.backup"
  case generalRestore = "general.restore"
  case generalMirror = "general.mirror"
  case generalDataFolder = "general.dataFolder"
  // 剪贴板
  case clipboardRetention = "clipboard.retention"
  case clipboardImageBudget = "clipboard.imageBudget"
  case clipboardImageUsage = "clipboard.imageUsage"
  case clipboardLens = "clipboard.lens"
  case clipboardImageRows = "clipboard.imageRows"
  case clipboardLinkPreview = "clipboard.linkPreview"
  case clipboardPasteOnClick = "clipboard.pasteOnClick"
  case clipboardPanelPosition = "clipboard.panelPosition"
  case clipboardPanelSize = "clipboard.panelSize"
  case clipboardPastePlain = "clipboard.pastePlain"
  case clipboardOCR = "clipboard.ocr"
  case clipboardBlockSensitive = "clipboard.blockSensitive"
  case clipboardAutoClear = "clipboard.autoClear"
  case clipboardClearNow = "clipboard.clearNow"
  case clipboardExcludedApps = "clipboard.excludedApps"
  // 启动器
  case launcherRomanInput = "launcher.romanInput"
  case launcherPanelPosition = "launcher.panelPosition"
  case launcherPanelSize = "launcher.panelSize"
  case launcherKeys = "launcher.keys"
  case launcherAppAliases = "launcher.appAliases"
  case launcherFileSearch = "launcher.fileSearch"
  case launcherBrowsers = "launcher.browsers"
  case launcherWebSearch = "launcher.webSearch"
  case launcherScripts = "launcher.scripts"
  case launcherScriptsEnabled = "launcher.scriptsEnabled"
  case launcherScriptsGuide = "launcher.scriptsGuide"
  case launcherScriptsAI = "launcher.scriptsAI"
  case launcherScriptsFolder = "launcher.scriptsFolder"
  case launcherScriptsOtherFolders = "launcher.scriptsOtherFolders"
  case launcherScriptsImport = "launcher.scriptsImport"
  case launcherCommands = "launcher.commands"
  case launcherShortcuts = "launcher.shortcuts"
  case launcherFrequent = "launcher.frequent"
  case launcherClearUsage = "launcher.clearUsage"
  // 翻译
  case translateFirst = "translate.first"
  case translateSecond = "translate.second"
  case translateFontScale = "translate.fontScale"
  case translateSystemDictionary = "translate.systemDictionary"
  case translateWordMode = "translate.wordMode"
  case translateDictionaryApp = "translate.dictionaryApp"
  case translatePronunciation = "translate.pronunciation"
  case translateSpeechSpeed = "translate.speechSpeed"
  case translatePanelPosition = "translate.panelPosition"
  case translatePanelSize = "translate.panelSize"
  case translateRemoveNewlines = "translate.removeNewlines"
  case translateCopyToTranslate = "translate.copyToTranslate"
  case translateAutoCopy = "translate.autoCopy"
  case translateOverlay = "translate.overlay"
  case translateCopyRecognized = "translate.copyRecognized"
  case translateHistory = "translate.history"
  case translateHistoryLimit = "translate.historyLimit"
  case translateHistoryExport = "translate.historyExport"
  case translateKeys = "translate.keys"
  case translateServices = "translate.services"
  // 截图
  case screenshotSaveFolder = "screenshot.saveFolder"
  case screenshotCopyAs = "screenshot.copyAs"
  case screenshotCorners = "screenshot.corners"
  case screenshotShutter = "screenshot.shutter"
  case screenshotCursor = "screenshot.cursor"
  case screenshotHideDesktop = "screenshot.hideDesktop"
  case screenshotWindowShadow = "screenshot.windowShadow"
  case screenshotDelay = "screenshot.delay"
  case screenshotHistory = "screenshot.history"
  case screenshotHistoryDays = "screenshot.historyDays"
  case screenshotHistorySize = "screenshot.historySize"
  case screenshotHistoryOpen = "screenshot.historyOpen"
  case screenshotHistoryClear = "screenshot.historyClear"
  case screenshotHint = "screenshot.hint"
  case screenshotLoupe = "screenshot.loupe"
  case screenshotToolbar = "screenshot.toolbar"
  case screenshotKeepsColors = "screenshot.keepsColors"
  case screenshotElements = "screenshot.elements"
  case screenshotPlacement = "screenshot.placement"
  case screenshotPinText = "screenshot.pinText"
  case screenshotJoinLines = "screenshot.joinLines"
  case screenshotReleaseOCR = "screenshot.releaseOCR"
  case screenshotKeys = "screenshot.keys"
  case screenshotEditKeys = "screenshot.editKeys"
  // 录制
  case recordSaveFolder = "record.saveFolder"
  case recordFrameRate = "record.frameRate"
  case recordSharpness = "record.sharpness"
  case recordCodec = "record.codec"
  case recordCountdown = "record.countdown"
  case recordCursor = "record.cursor"
  case recordMicrophone = "record.microphone"
  case recordKeysShown = "record.keysShown"
  case recordAudioSource = "record.audioSource"
  case recordStartsImmediately = "record.startsImmediately"
  case recordKeys = "record.keys"
  // 便签
  case notesFontSize = "notes.fontSize"
  case notesLineSpacing = "notes.lineSpacing"
  case notesMarkdown = "notes.markdown"
  case notesDeck = "notes.deck"
  case notesDeckEdge = "notes.deckEdge"
  case notesDeckDisplay = "notes.deckDisplay"
  case notesDeckStyle = "notes.deckStyle"
  case notesDeckSize = "notes.deckSize"
  case notesDeckSense = "notes.deckSense"
  case notesDeckAlwaysFanned = "notes.deckAlwaysFanned"
  case notesDeckHidesPill = "notes.deckHidesPill"
  case notesDeckPreview = "notes.deckPreview"
  case notesDeckOpensOnHover = "notes.deckOpensOnHover"
  case notesDeckOverFullScreen = "notes.deckOverFullScreen"
  case notesDeckNoteSize = "notes.deckNoteSize"
  case notesOpenAll = "notes.openAll"
  case notesKeys = "notes.keys"
  case notesExport = "notes.export"
  case notesImport = "notes.import"
  // 提醒
  case remindersList = "reminders.list"
  case remindersSnooze = "reminders.snooze"
  case remindersFocus = "reminders.focus"
  // 状态屏
  case statusList = "statusScreen.list"
  case statusEntersFirst = "statusScreen.entersFirst"
  case statusAnimations = "statusScreen.animations"
  case statusExit = "statusScreen.exit"
  case statusExitHint = "statusScreen.exitHint"
  // 启动台
  case launchpadKeys = "launchpad.keys"
  case launchpadColumns = "launchpad.columns"
  case launchpadRows = "launchpad.rows"
  case launchpadFrequent = "launchpad.frequent"
  case launchpadHidden = "launchpad.hidden"
  case launchpadCorner = "launchpad.corner"
  case launchpadImport = "launchpad.import"
  case launchpadReset = "launchpad.reset"
  case launchpadPinch = "launchpad.pinch"
  // 程序坞预览
  case dockPreviewDelay = "dockPreview.delay"
  case dockPreviewCmdTab = "dockPreview.cmdTab"
  // 访达右键：一组登记一项（每一项的开关是 FinderMenuItem 排出来的）
  case finderMenu = "finderMenu.menu"
  case finderNewFile = "finderMenu.newFile"
  case finderCopy = "finderMenu.copy"
  case finderOrganize = "finderMenu.organize"
  case finderArchive = "finderMenu.archive"
  case finderHidden = "finderMenu.hidden"
  case finderFolders = "finderMenu.folders"
  case finderOpenWith = "finderMenu.openWith"
  // 保持唤醒
  case keepAwakeNow = "keepAwake.now"
  case keepAwakeDisplay = "keepAwake.display"
  case keepAwakeSchedule = "keepAwake.schedule"
  // 睡眠关蓝牙
  case bluetoothLidOnly = "bluetoothSnooze.lidOnly"
  case bluetoothReopen = "bluetoothSnooze.reopen"
  // 平滑滚动
  case smoothStrength = "smoothScroll.strength"
  case smoothDistance = "smoothScroll.distance"
  case smoothReverseVertical = "smoothScroll.reverseVertical"
  case smoothReverseHorizontal = "smoothScroll.reverseHorizontal"
  case smoothExcluded = "smoothScroll.excluded"
  // App 快捷键
  case appShortcutsHold = "appShortcuts.hold"
  case appShortcutsKey = "appShortcuts.key"
  case appShortcutsDelay = "appShortcuts.delay"
  case keyRemappingKeyboard = "keyRemapping.keyboard"
  // 片段展开
  case snippetExpandExcluded = "snippetExpand.excluded"
  // 刘海岛
  case islandNowPlaying = "island.nowPlaying"
  case islandTrackPeek = "island.trackPeek"
  case islandMediaColor = "island.mediaColor"
  case islandMusicFavorite = "island.musicFavorite"
  case islandHidesWhenActive = "island.hidesWhenActive"
  case islandNextEvent = "island.nextEvent"
  case islandEventChime = "island.eventChime"
  case islandHourlyChime = "island.hourlyChime"
  case islandCalendar = "island.calendar"
  case islandCalendarDots = "island.calendarDots"
  case islandCalendarColors = "island.calendarColors"
  case islandShowDeclined = "island.showDeclined"
  case islandKeyLevels = "island.keyLevels"
  case islandLevelStay = "island.levelStay"
  case islandLevelAccent = "island.levelAccent"
  case islandLevelPercent = "island.levelPercent"
  case islandFocus = "island.focus"
  case islandFocusPinned = "island.focusPinned"
  case islandFocusSleepSound = "island.focusSleepSound"
  case islandFocusWaveform = "island.focusWaveform"
  case islandFocusQuiet = "island.focusQuiet"
  case islandActions = "island.actions"
  case islandShowsHistory = "island.showsHistory"
  case islandNotchClicks = "island.notchClicks"
  case islandHoverExpands = "island.hoverExpands"
  case islandHoverDelay = "island.hoverDelay"
  case islandNoticeLength = "island.noticeLength"
  case islandHaptics = "island.haptics"
  case islandBlur = "island.blur"
  case islandOutlined = "island.outlined"
  case islandHidesInFullScreen = "island.hidesInFullScreen"
  case islandHidesFromCapture = "island.hidesFromCapture"
  case islandNoticePower = "island.noticePower"
  case islandNoticeBattery = "island.noticeBattery"
  case islandNoticeHeadphones = "island.noticeHeadphones"
  case islandNoticeNetwork = "island.noticeNetwork"
  case islandNoticeLowPower = "island.noticeLowPower"
  // 快捷键、关于
  case hotkeysShotTools = "hotkeys.shotTools"
  case hotkeysShotOutput = "hotkeys.shotOutput"
  case hotkeysPanels = "hotkeys.panels"
  case hotkeysBlocked = "hotkeys.blocked"
  case aboutAutoCheck = "about.autoCheck"
  case aboutInstallOnQuit = "about.installOnQuit"

  var id: String { rawValue }

  /// 一项登记了什么
  struct Info {
    let page: SettingsPage
    /// 和页面上那一行同一个字面量（目录里同一个 key：英文现成）
    let title: LocalizedStringResource
    /// 标题之外还认的词（逗号隔开；英文给英文界面里的叫法）
    let keywords: LocalizedStringResource?
    /// 这一行读写的偏好键（恢复默认用；按钮、状态行、用户自己攒的列表空着）
    let keys: [String]
    /// 在页里哪儿：外面、哪个子页、「高级…」表单
    let place: Place
  }

  /// 一行在页里的位置（设置改版 S1）
  enum Place: Hashable {
    case page
    case subpage(SettingsSubpage)
    case advanced
  }

  /// 有搜索词的一项。title、keywords 经参数传进来：switch 的每个分支都抽得进目录（TRANSLATION.md 二）
  private static func row(
    _ page: SettingsPage, _ title: LocalizedStringResource, _ keywords: LocalizedStringResource,
    keys: [String] = [], place: Place = .page
  ) -> Info {
    Info(page: page, title: title, keywords: keywords, keys: keys, place: place)
  }

  /// 只靠标题就找得到的一项
  private static func row(
    _ page: SettingsPage, _ title: LocalizedStringResource, keys: [String] = [],
    place: Place = .page
  ) -> Info {
    Info(page: page, title: title, keywords: nil, keys: keys, place: place)
  }

  // swift-format-ignore: 一项一行，排成表好对着页面看
  var info: Info {
    switch self {
    case .generalFeatures:
      Self.row(
        .general, "功能",
        LocalizedStringResource("search.general.features", defaultValue: "模块,关闭,停用,启用"))
    case .generalPlugins:
      Self.row(
        .general, "插件", LocalizedStringResource("search.general.plugins", defaultValue: "扩展,添加"))
    case .generalLanguage:
      Self.row(
        .general, GeneralTab.languageLabel,
        LocalizedStringResource("search.general.language", defaultValue: "英文,中文,English,界面语言"))
    case .generalAppearance:
      Self.row(
        .general, "外观",
        LocalizedStringResource("search.general.appearance", defaultValue: "浅色,深色,暗黑,主题"),
        keys: [Prefs.appearance])
    case .generalAccent:
      Self.row(
        .general, "强调色", LocalizedStringResource("search.general.accent", defaultValue: "主题色,颜色"),
        keys: [Prefs.accent])
    case .generalSqueeze:
      Self.row(
        .general, "呼出面板时挤压弹开",
        LocalizedStringResource("search.general.squeeze", defaultValue: "挤压,弹开,动画,动效"),
        keys: [Prefs.panelSqueezeEntrance], place: .advanced)
    case .generalMenuBarIcon:
      Self.row(
        .general, "在菜单栏显示图标",
        LocalizedStringResource("search.general.menuBarIcon", defaultValue: "菜单栏,状态栏,隐藏图标"),
        keys: [Prefs.statusItemVisible], place: .advanced)
    case .generalIconStyle:
      Self.row(
        .general, "图标样式",
        LocalizedStringResource("search.general.iconStyle", defaultValue: "彩色,单色"),
        keys: [Prefs.statusItemStyle], place: .advanced)
    case .generalDockIcon:
      Self.row(
        .general, "在程序坞显示图标",
        LocalizedStringResource("search.general.dockIcon", defaultValue: "程序坞,Dock"),
        keys: [Prefs.dockIconOnTahoe], place: .advanced)
    case .generalLogin:
      Self.row(
        .general, "登录时自动打开",
        LocalizedStringResource("search.general.login", defaultValue: "开机,登录,自启,登录项"))
    case .generalAccessibility:
      Self.row(
        .general, "辅助功能",
        LocalizedStringResource("search.general.accessibility", defaultValue: "权限,授权"),
        place: .subpage(.generalPermissions))
    case .generalScreenRecording:
      Self.row(
        .general, "屏幕录制",
        LocalizedStringResource("search.general.screenRecording", defaultValue: "权限,授权"),
        place: .subpage(.generalPermissions))
    case .generalMicrophone:
      Self.row(
        .general, "麦克风",
        LocalizedStringResource("search.general.microphone", defaultValue: "权限,授权"),
        place: .subpage(.generalPermissions))
    case .generalClipboardAccess:
      Self.row(
        .general, "剪贴板访问",
        LocalizedStringResource("search.general.clipboardAccess", defaultValue: "权限,隐私,从其他 App 粘贴"),
        place: .subpage(.generalPermissions))
    case .generalSync:
      Self.row(
        .general, "同步",
        LocalizedStringResource("search.general.sync", defaultValue: "iCloud,云盘,WebDAV,服务器,多台,另一台"),
        place: .subpage(.generalSync))
    case .generalSyncPeers:
      Self.row(
        .general, "其他电脑",
        LocalizedStringResource("search.general.syncPeers", defaultValue: "同步,另一台,Mac,电脑"),
        place: .subpage(.generalSync))
    case .generalTransfer:
      Self.row(
        .general, "设置与数据",
        LocalizedStringResource("search.general.transfer", defaultValue: "导出,导入,迁移,换电脑,配置"),
        place: .subpage(.generalBackup))
    case .generalBackup:
      Self.row(
        .general, "每天自动备份", LocalizedStringResource("search.general.backup", defaultValue: "备份"),
        place: .subpage(.generalBackup))
    case .generalRestore:
      Self.row(
        .general, "已有的备份",
        LocalizedStringResource("search.general.restore", defaultValue: "从备份恢复,恢复"),
        place: .subpage(.generalBackup))
    case .generalMirror:
      Self.row(
        .general, "另存一份到",
        LocalizedStringResource("search.general.mirror", defaultValue: "备份,文件夹,云盘"),
        place: .subpage(.generalBackup))
    case .generalDataFolder:
      Self.row(
        .general, "数据目录",
        LocalizedStringResource("search.general.dataFolder", defaultValue: "数据,访达,文件夹"),
        place: .advanced)
    case .clipboardRetention:
      Self.row(
        .clipboard, "保留普通历史",
        LocalizedStringResource("search.clipboard.retention", defaultValue: "历史,天数,保留,永久"),
        keys: [Prefs.clipboardRetentionDays])
    case .clipboardImageBudget:
      Self.row(
        .clipboard, "图片最多占用",
        LocalizedStringResource("search.clipboard.imageBudget", defaultValue: "图片,占用,空间"),
        keys: [Prefs.clipboardImageBudgetMB])
    case .clipboardImageUsage: Self.row(.clipboard, "图片当前占用")
    case .clipboardLens:
      Self.row(
        .clipboard, "显示透镜", LocalizedStringResource("search.clipboard.lens", defaultValue: "透镜,预览"),
        keys: [Prefs.clipboardShowPreview], place: .advanced)
    case .clipboardImageRows:
      Self.row(
        .clipboard, "列表里直接显示图片",
        LocalizedStringResource("search.clipboard.imageRows", defaultValue: "图片,缩略图,预览,大图"),
        keys: [Prefs.clipboardImageRows], place: .advanced)
    case .clipboardLinkPreview:
      Self.row(
        .clipboard, "链接显示网页标题和图片",
        LocalizedStringResource("search.clipboard.linkPreview", defaultValue: "链接,网页,标题"),
        keys: [Prefs.clipboardLinkPreview], place: .advanced)
    case .clipboardPasteOnClick:
      Self.row(
        .clipboard, "单击条目直接粘贴",
        LocalizedStringResource("search.clipboard.pasteOnClick", defaultValue: "单击,双击,点击"),
        keys: [Prefs.clipboardPasteOnClick])
    case .clipboardPanelPosition:
      Self.row(
        .clipboard, "面板位置",
        LocalizedStringResource(
          "search.clipboard.panelPosition", defaultValue: "位置,跟随鼠标,上次位置,屏幕上方"),
        keys: [Prefs.clipboardPanelPosition], place: .advanced)
    case .clipboardPanelSize:
      Self.row(
        .clipboard, "面板大小",
        LocalizedStringResource("search.clipboard.panelSize", defaultValue: "宽度,行数"),
        place: .advanced)
    case .clipboardPastePlain:
      Self.row(
        .clipboard, "默认粘贴为纯文本",
        LocalizedStringResource("search.clipboard.pastePlain", defaultValue: "纯文本,格式"),
        keys: [Prefs.clipboardPastePlain])
    case .clipboardOCR:
      Self.row(
        .clipboard, "识别图片中的文字，用于搜索",
        LocalizedStringResource("search.clipboard.ocr", defaultValue: "识别,文字,OCR"),
        keys: [Prefs.clipboardImageOCR], place: .advanced)
    case .clipboardBlockSensitive:
      Self.row(
        .clipboard, "不记录疑似密钥和银行卡号",
        LocalizedStringResource("search.clipboard.blockSensitive", defaultValue: "密钥,银行卡,密码,敏感"),
        keys: [Prefs.clipboardBlockSensitive])
    case .clipboardAutoClear:
      Self.row(
        .clipboard, "自动清空普通历史",
        LocalizedStringResource("search.clipboard.autoClear", defaultValue: "清空,退出,锁屏"),
        keys: [Prefs.clipboardClearOnQuit, Prefs.clipboardClearOnLock])
    case .clipboardClearNow:
      Self.row(
        .clipboard, "立即清空普通历史…",
        LocalizedStringResource("search.clipboard.clearNow", defaultValue: "清空"))
    case .clipboardExcludedApps:
      Self.row(
        .clipboard, "不记录这些 App 里的复制",
        LocalizedStringResource("search.clipboard.excludedApps", defaultValue: "排除,不记录"))
    case .launcherRomanInput:
      Self.row(
        .launcher, "呼出时切到英文输入法",
        LocalizedStringResource("search.launcher.romanInput", defaultValue: "英文,输入法"),
        keys: [Prefs.launcherRomanInput], place: .advanced)
    case .launcherPanelPosition:
      Self.row(
        .launcher, "面板位置",
        LocalizedStringResource("search.launcher.panelPosition", defaultValue: "位置,跟随鼠标,上次位置,屏幕上方"),
        keys: [Prefs.launcherPanelPosition], place: .advanced)
    case .launcherPanelSize:
      Self.row(
        .launcher, "面板大小",
        LocalizedStringResource("search.launcher.panelSize", defaultValue: "宽度,行数"),
        place: .advanced)
    case .launcherKeys:
      Self.row(
        .launcher, "启动器里的按键", LocalizedStringResource("search.launcher.keys", defaultValue: "按键,速查")
      )
    case .launcherAppAliases:
      Self.row(
        .launcher, "应用别名", LocalizedStringResource("search.launcher.appAliases", defaultValue: "别名")
      )
    case .launcherFileSearch:
      Self.row(
        .launcher, "桌面、文稿、下载、iCloud 云盘",
        LocalizedStringResource(
          "search.launcher.fileSearch", defaultValue: "文件,文件搜索,open,find,文件夹授权"))
    case .launcherBrowsers:
      Self.row(
        .launcher, "浏览器书签与历史",
        LocalizedStringResource(
          "search.launcher.browsers",
          defaultValue: "书签,浏览历史,浏览器,Safari,Chrome,Edge,Arc,Brave,Firefox,完全磁盘访问"),
        keys: [Prefs.launcherBrowserBookmarks, Prefs.launcherBrowserHistory])
    case .launcherWebSearch:
      Self.row(
        .launcher, "网页搜索与快捷链接",
        LocalizedStringResource("search.launcher.webSearch", defaultValue: "搜索引擎,快捷链接,关键词,兜底"))
    case .launcherScripts:
      Self.row(
        .launcher, "脚本命令",
        LocalizedStringResource("search.launcher.scripts", defaultValue: "脚本,AI,新建脚本"))
    case .launcherScriptsEnabled:
      Self.row(
        .launcher, "启用脚本命令",
        LocalizedStringResource("search.launcher.scriptsEnabled", defaultValue: "脚本,脚本命令"),
        keys: [Prefs.launcherScripts], place: .subpage(.launcherScripts))
    case .launcherScriptsGuide:
      Self.row(
        .launcher, "怎么写脚本",
        LocalizedStringResource("search.launcher.scriptsGuide", defaultValue: "脚本,写法,例子"),
        place: .subpage(.launcherScripts))
    case .launcherScriptsAI:
      Self.row(
        .launcher, "让 AI 来写",
        LocalizedStringResource("search.launcher.scriptsAI", defaultValue: "AI,脚本,剪贴板"),
        place: .subpage(.launcherScripts))
    case .launcherScriptsFolder:
      Self.row(
        .launcher, "脚本文件夹",
        LocalizedStringResource("search.launcher.scriptsFolder", defaultValue: "脚本,新建脚本,文件夹"),
        place: .subpage(.launcherScripts))
    case .launcherScriptsOtherFolders:
      Self.row(
        .launcher, "其他文件夹",
        LocalizedStringResource(
          "search.launcher.scriptsOtherFolders", defaultValue: "脚本,iCloud,文件夹"),
        place: .subpage(.launcherScripts))
    case .launcherScriptsImport:
      Self.row(
        .launcher, "把脚本文件拖到这里导入",
        LocalizedStringResource("search.launcher.scriptsImport", defaultValue: "脚本,导入,拖"),
        place: .subpage(.launcherScripts))
    case .launcherCommands:
      Self.row(
        .launcher, "命令和别名",
        LocalizedStringResource("search.launcher.commands", defaultValue: "命令,别名,系统命令"))
    case .launcherShortcuts:
      Self.row(
        .launcher, "搜索快捷指令",
        LocalizedStringResource("search.launcher.shortcuts", defaultValue: "快捷指令,Shortcuts"),
        keys: [Prefs.launcherShortcuts])
    case .launcherFrequent:
      Self.row(
        .launcher, "空搜索框里列出常用",
        LocalizedStringResource("search.launcher.frequent", defaultValue: "常用,最近,使用记录,收藏"),
        keys: [Prefs.launcherShowsFrequent])
    case .launcherClearUsage:
      Self.row(
        .launcher, "清空使用记录…",
        LocalizedStringResource("search.launcher.clearUsage", defaultValue: "使用记录,清空"),
        place: .advanced)
    case .translateFirst: Self.row(.translate, "第一语言", keys: [Prefs.translateFirst])
    case .translateSecond: Self.row(.translate, "第二语言", keys: [Prefs.translateSecond])
    case .translateFontScale:
      Self.row(
        .translate, "译文字号",
        LocalizedStringResource("search.translate.fontScale", defaultValue: "字号,大小"),
        keys: [Prefs.translateFontScale], place: .advanced)
    case .translateSystemDictionary:
      Self.row(
        .translate, "查单个词时显示系统词典的释义",
        LocalizedStringResource("search.translate.systemDictionary", defaultValue: "词典,释义,查词"),
        keys: [Prefs.translateSystemDictionary], place: .subpage(.translateLookup))
    case .translateWordMode:
      Self.row(
        .translate, "查单个词时大模型按词典回答（读音、词性、例句）",
        LocalizedStringResource("search.translate.wordMode", defaultValue: "查词,音标,例句"),
        keys: [Prefs.translateWordMode], place: .subpage(.translateLookup))
    case .translateDictionaryApp:
      Self.row(
        .translate, "系统词典的中文释义",
        LocalizedStringResource("search.translate.dictionaryApp", defaultValue: "词典,牛津"),
        place: .subpage(.translateLookup))
    case .translatePronunciation:
      Self.row(
        .translate, "英文单词发音",
        LocalizedStringResource(
          "search.translate.pronunciation", defaultValue: "发音,真人,有道,美音,英音,系统声音"),
        keys: [Prefs.translateWordRecording, Prefs.translateWordAccent],
        place: .subpage(.translateLookup))
    case .translateSpeechSpeed:
      Self.row(
        .translate, "朗读速度",
        LocalizedStringResource("search.translate.speechSpeed", defaultValue: "朗读,语速,慢速"),
        keys: [Prefs.translateSpeechSpeed], place: .subpage(.translateLookup))
    case .translatePanelPosition:
      Self.row(
        .translate, "浮窗位置",
        LocalizedStringResource("search.translate.panelPosition", defaultValue: "位置,跟随鼠标"),
        keys: [Prefs.translatePanelPosition])
    case .translatePanelSize:
      Self.row(
        .translate, "面板大小",
        LocalizedStringResource("search.translate.panelSize", defaultValue: "宽度,高度"),
        place: .advanced)
    case .translateRemoveNewlines:
      Self.row(
        .translate, "翻译前把同一段里的换行接起来（适合 PDF 复制的文字）",
        LocalizedStringResource("search.translate.removeNewlines", defaultValue: "换行,PDF"),
        keys: [Prefs.translateRemoveNewlines], place: .advanced)
    case .translateCopyToTranslate:
      Self.row(.translate, "复制即译", keys: [Prefs.translateCopyToTranslate])
    case .translateAutoCopy: Self.row(.translate, "自动复制译文", keys: [Prefs.translateAutoCopy])
    case .translateOverlay:
      Self.row(
        .translate, "截图翻译时把译文直接盖回截图上",
        LocalizedStringResource("search.translate.overlay", defaultValue: "截图翻译,盖回"),
        keys: [Prefs.translateScreenshotOverlay], place: .advanced)
    case .translateCopyRecognized:
      Self.row(
        .translate, "截图翻译时复制识别出的原文",
        LocalizedStringResource("search.translate.copyRecognized", defaultValue: "截图翻译,原文"),
        keys: [Prefs.translateCopyRecognized], place: .advanced)
    case .translateHistory:
      Self.row(
        .translate, "记录翻译历史",
        LocalizedStringResource("search.translate.history", defaultValue: "历史"),
        keys: [Prefs.translateHistoryEnabled], place: .subpage(.translateHistory))
    case .translateHistoryLimit:
      Self.row(
        .translate, "历史最多保留",
        LocalizedStringResource("search.translate.historyLimit", defaultValue: "历史,条数"),
        keys: [Prefs.translateHistoryLimit], place: .subpage(.translateHistory))
    case .translateHistoryExport:
      Self.row(
        .translate, "导出和清空",
        LocalizedStringResource(
          "search.translate.historyExport", defaultValue: "导出,CSV,Anki,清空,历史"),
        place: .subpage(.translateHistory))
    case .translateKeys:
      Self.row(
        .translate, "翻译浮窗里的按键",
        LocalizedStringResource("search.translate.keys", defaultValue: "按键,速查"))
    case .translateServices:
      Self.row(
        .translate, "翻译服务",
        LocalizedStringResource(
          "search.translate.services",
          defaultValue: "服务,密钥,智谱,OpenAI,Anthropic,DeepL,Google,百度,有道,微软,AI,模型"))
    case .screenshotSaveFolder:
      Self.row(
        .screenshot, "快速保存到",
        LocalizedStringResource("search.screenshot.saveFolder", defaultValue: "保存,存储,目录,文件夹"))
    case .screenshotCopyAs:
      Self.row(
        .screenshot, "截图拷贝为",
        LocalizedStringResource("search.screenshot.copyAs", defaultValue: "拷贝,复制,文件,PNG,对拷线"),
        keys: [Prefs.screenshotCopyAs])
    case .screenshotCorners:
      Self.row(
        .screenshot, "截图圆角",
        LocalizedStringResource(
          "search.screenshot.corners", defaultValue: "圆角,直角,四角,透明,半径"),
        keys: [Prefs.screenshotCornerRadius])
    case .screenshotShutter:
      Self.row(
        .screenshot, "截图时播放快门声",
        LocalizedStringResource("search.screenshot.shutter", defaultValue: "快门,声音"),
        keys: [Prefs.screenshotShutterSound])
    case .screenshotCursor:
      Self.row(
        .screenshot, "截图带上鼠标指针",
        LocalizedStringResource("search.screenshot.cursor", defaultValue: "指针,鼠标指针"),
        keys: [Prefs.screenshotCursor], place: .advanced)
    case .screenshotHideDesktop:
      Self.row(
        .screenshot, "截图、录屏时隐藏桌面图标",
        LocalizedStringResource("search.screenshot.hideDesktop", defaultValue: "桌面图标,隐藏"),
        keys: [Prefs.captureHideDesktopIcons], place: .advanced)
    case .screenshotWindowShadow:
      Self.row(
        .screenshot, "窗口截图带阴影",
        LocalizedStringResource("search.screenshot.windowShadow", defaultValue: "阴影,窗口,圆角,透明"),
        keys: [Prefs.screenshotWindowShadow], place: .advanced)
    case .screenshotDelay:
      Self.row(
        .screenshot, "延时截图倒数",
        LocalizedStringResource("search.screenshot.delay", defaultValue: "延时,定时,倒数,计时器"),
        keys: [Prefs.screenshotDelay], place: .advanced)
    case .screenshotHistory:
      Self.row(
        .screenshot, "保留截图历史",
        LocalizedStringResource("search.screenshot.history", defaultValue: "历史,截图历史"),
        keys: [Prefs.shotHistory], place: .subpage(.screenshotHistory))
    case .screenshotHistoryDays:
      Self.row(
        .screenshot, "保留",
        LocalizedStringResource("search.screenshot.historyDays", defaultValue: "截图历史,天数"),
        keys: [Prefs.shotHistoryDays], place: .subpage(.screenshotHistory))
    case .screenshotHistorySize:
      Self.row(
        .screenshot, "最多占用",
        LocalizedStringResource("search.screenshot.historySize", defaultValue: "截图历史,空间"),
        keys: [Prefs.shotHistoryMegabytes], place: .subpage(.screenshotHistory))
    case .screenshotHistoryOpen:
      Self.row(
        .screenshot, "打开截图历史…",
        LocalizedStringResource("search.screenshot.historyOpen", defaultValue: "截图历史,窗口"),
        place: .subpage(.screenshotHistory))
    case .screenshotHistoryClear:
      Self.row(
        .screenshot, "现在清空…",
        LocalizedStringResource("search.screenshot.historyClear", defaultValue: "清空,删除,截图历史"),
        place: .subpage(.screenshotHistory))
    case .screenshotHint:
      Self.row(
        .screenshot, "框选时显示操作提示",
        LocalizedStringResource("search.screenshot.hint", defaultValue: "提示"),
        keys: [Prefs.screenshotShowsHint], place: .advanced)
    case .screenshotLoupe:
      Self.row(
        .screenshot, "框选时的放大镜",
        LocalizedStringResource("search.screenshot.loupe", defaultValue: "放大镜,取色,色值"),
        keys: [Prefs.screenshotLoupe], place: .advanced)
    case .screenshotToolbar:
      Self.row(
        .screenshot, "工具栏位置",
        LocalizedStringResource("search.screenshot.toolbar", defaultValue: "工具栏,靠右,居中,录制条"),
        keys: [Prefs.screenshotToolbarAlign], place: .advanced)
    case .screenshotKeepsColors:
      Self.row(
        .screenshot, "框选时保持屏幕原色",
        LocalizedStringResource("search.screenshot.keepsColors", defaultValue: "原色,压暗,遮罩"),
        keys: [Prefs.screenshotKeepsColors], place: .advanced)
    case .screenshotElements:
      Self.row(
        .screenshot, "悬停时识别",
        LocalizedStringResource("search.screenshot.elements", defaultValue: "元素,识别,悬停,窗口,网页,浏览器"),
        keys: [Prefs.screenshotFindsElements, Prefs.screenshotFindsWebElements], place: .advanced)
    case .screenshotPlacement:
      Self.row(
        .screenshot, "截完图放哪",
        LocalizedStringResource("search.screenshot.placement", defaultValue: "缩略图,晾衣绳,角落"),
        keys: [Prefs.screenshotPlacement])
    case .screenshotPinText:
      Self.row(
        .screenshot, "钉图上的字可以直接选",
        LocalizedStringResource("search.screenshot.pinText", defaultValue: "钉图,选字"),
        keys: [Prefs.pinSelectsText], place: .advanced)
    case .screenshotJoinLines:
      Self.row(
        .screenshot, "识字后把同一段里的换行接起来",
        LocalizedStringResource("search.screenshot.joinLines", defaultValue: "识字,换行,二维码"),
        keys: [Prefs.ocrJoinLines], place: .advanced)
    case .screenshotReleaseOCR:
      Self.row(
        .screenshot, "空闲时释放识字模型",
        LocalizedStringResource("search.screenshot.releaseOCR", defaultValue: "识字,OCR,模型,空闲,释放,内存"),
        keys: [Prefs.ocrReleaseWhenIdle], place: .advanced)
    case .screenshotKeys:
      Self.row(
        .screenshot, "框选、标注、长截图和录屏的按键",
        LocalizedStringResource("search.screenshot.keys", defaultValue: "按键,速查"))
    case .screenshotEditKeys:
      Self.row(
        .screenshot, "改按键",
        LocalizedStringResource("search.screenshot.editKeys", defaultValue: "快捷键,改键"))
    case .recordSaveFolder:
      Self.row(
        .record, "保存到", LocalizedStringResource("search.record.saveFolder", defaultValue: "保存,文件夹"))
    case .recordFrameRate:
      Self.row(
        .record, "帧率", LocalizedStringResource("search.record.frameRate", defaultValue: "fps"),
        keys: [Prefs.screenRecordFrameRate], place: .advanced)
    case .recordSharpness:
      Self.row(
        .record, "清晰度",
        LocalizedStringResource("search.record.sharpness", defaultValue: "分辨率,画质,文件大小"),
        keys: [Prefs.screenRecordSharpness])
    case .recordCodec:
      Self.row(
        .record, "编码",
        LocalizedStringResource("search.record.codec", defaultValue: "H.264,HEVC,体积"),
        keys: [Prefs.screenRecordCodec], place: .advanced)
    case .recordCountdown:
      Self.row(
        .record, "开始前倒数", LocalizedStringResource("search.record.countdown", defaultValue: "倒数"),
        keys: [Prefs.screenRecordCountdown])
    case .recordCursor:
      Self.row(
        .record, "显示光标", LocalizedStringResource("search.record.cursor", defaultValue: "光标"),
        keys: [Prefs.screenRecordShowsCursor])
    case .recordMicrophone:
      Self.row(
        .record, "麦克风", LocalizedStringResource("search.record.microphone", defaultValue: "输入,话筒"))
    case .recordKeysShown:
      Self.row(
        .record, "显示按键时",
        LocalizedStringResource("search.record.keysShown", defaultValue: "按键,只显示快捷键"),
        keys: [Prefs.screenRecordKeysShortcutsOnly], place: .advanced)
    case .recordAudioSource:
      Self.row(
        .record, "来源",
        LocalizedStringResource("search.record.audioSource", defaultValue: "录音,系统声音,麦克风"),
        keys: [Prefs.audioRecordSource])
    case .recordStartsImmediately:
      Self.row(
        .record, "按快捷键后立即开始录音",
        LocalizedStringResource("search.record.startsImmediately", defaultValue: "立即开始,控制条"),
        keys: [Prefs.audioRecordStartsImmediately], place: .advanced)
    case .recordKeys:
      Self.row(
        .record, "录屏和录音的按键", LocalizedStringResource("search.record.keys", defaultValue: "按键,速查"))
    case .notesFontSize:
      Self.row(
        .notes, "正文字号", LocalizedStringResource("search.notes.fontSize", defaultValue: "字号,字体大小"),
        keys: [Prefs.notesFontSize])
    case .notesLineSpacing:
      Self.row(
        .notes, "行距", LocalizedStringResource("search.notes.lineSpacing", defaultValue: "行高,间距"),
        keys: [Prefs.notesLineSpacing])
    case .notesMarkdown:
      Self.row(
        .notes, "Markdown 样式",
        LocalizedStringResource("search.notes.markdown", defaultValue: "粗体,斜体,链接,代码块"),
        keys: [Prefs.notesMarkdown])
    case .notesDeck:
      Self.row(
        .notes, "在屏幕边缘显示便签",
        LocalizedStringResource("search.notes.deck", defaultValue: "屏幕边缘,边缘,药丸,标签"),
        keys: [Prefs.notesDeckEnabled], place: .subpage(.notesDeck))
    case .notesDeckEdge:
      Self.row(
        .notes, "位置", LocalizedStringResource("search.notes.deckEdge", defaultValue: "屏幕边缘,左边,右边"),
        keys: [Prefs.notesDeckEdge], place: .subpage(.notesDeck))
    case .notesDeckDisplay:
      Self.row(
        .notes, "显示器",
        LocalizedStringResource("search.notes.deckDisplay", defaultValue: "屏幕边缘,主显示器"),
        keys: [Prefs.notesDeckDisplay], place: .subpage(.notesDeck))
    case .notesDeckStyle:
      Self.row(
        .notes, "样式", LocalizedStringResource("search.notes.deckStyle", defaultValue: "标签,色块"),
        keys: [Prefs.notesDeckStyle], place: .subpage(.notesDeck))
    case .notesDeckSize:
      Self.row(
        .notes, "大小", LocalizedStringResource("search.notes.deckSize", defaultValue: "屏幕边缘,标签"),
        keys: [Prefs.notesDeckSize], place: .subpage(.notesDeck))
    case .notesDeckSense:
      Self.row(.notes, "感应范围", keys: [Prefs.notesDeckSense], place: .subpage(.notesDeck))
    case .notesDeckAlwaysFanned:
      Self.row(.notes, "一直展开", keys: [Prefs.notesDeckAlwaysFanned], place: .subpage(.notesDeck))
    case .notesDeckHidesPill:
      Self.row(
        .notes, "不显示药丸", LocalizedStringResource("search.notes.deckHidesPill", defaultValue: "药丸"),
        keys: [Prefs.notesDeckHidesPill], place: .subpage(.notesDeck))
    case .notesDeckPreview:
      Self.row(.notes, "悬停预览", keys: [Prefs.notesDeckPreview], place: .subpage(.notesDeck))
    case .notesDeckOpensOnHover:
      Self.row(.notes, "悬停即打开", keys: [Prefs.notesDeckOpensOnHover], place: .subpage(.notesDeck))
    case .notesDeckOverFullScreen:
      Self.row(
        .notes, "盖在全屏 App 上",
        LocalizedStringResource("search.notes.deckOverFullScreen", defaultValue: "全屏"),
        keys: [Prefs.notesDeckOverFullScreen], place: .subpage(.notesDeck))
    case .notesDeckNoteSize:
      Self.row(.notes, "便签大小", keys: [Prefs.notesDeckNoteSize], place: .subpage(.notesDeck))
    case .notesOpenAll:
      Self.row(
        .notes, HotKeyAction.noteAll.titleResource,
        LocalizedStringResource("search.notes.openAll", defaultValue: "归档,最近删除"))
    case .notesKeys:
      Self.row(.notes, "便签的按键", LocalizedStringResource("search.notes.keys", defaultValue: "按键,速查"))
    case .notesExport:
      Self.row(
        .notes, "导出为 Markdown",
        LocalizedStringResource("search.notes.export", defaultValue: "导出,备份"))
    case .notesImport:
      Self.row(
        .notes, "从 Markdown 导入", LocalizedStringResource("search.notes.import", defaultValue: "导入"))
    case .remindersList:
      Self.row(
        .reminders, "提醒",
        LocalizedStringResource("search.reminders.list", defaultValue: "定时,闹钟,倒计时"))
    case .remindersSnooze:
      Self.row(
        .reminders, "「稍后」推多久",
        LocalizedStringResource("search.reminders.snooze", defaultValue: "稍后,推迟"),
        keys: [Prefs.remindersSnoozeMinutes])
    case .remindersFocus:
      Self.row(
        .reminders, "专注模式开着时，到点的提醒",
        LocalizedStringResource("search.reminders.focus", defaultValue: "专注模式,勿扰"),
        keys: [Prefs.remindersDuringFocus])
    case .statusList:
      Self.row(
        .statusScreen, "状态",
        LocalizedStringResource("search.statusScreen.list", defaultValue: "告示,样式"))
    case .statusEntersFirst:
      Self.row(
        .statusScreen, "按快捷键直接进入排在最前面的状态",
        LocalizedStringResource("search.statusScreen.entersFirst", defaultValue: "直接进入,预览卡片"),
        keys: [Prefs.statusScreenHotKeyEntersFirst])
    case .statusAnimations:
      Self.row(
        .statusScreen, "告示上的动画",
        LocalizedStringResource("search.statusScreen.animations", defaultValue: "动画,表情,出场"),
        keys: [Prefs.statusScreenAnimations])
    case .statusExit:
      Self.row(
        .statusScreen, "怎么退出",
        LocalizedStringResource("search.statusScreen.exit", defaultValue: "退出,Esc"))
    case .statusExitHint:
      Self.row(
        .statusScreen, "有人碰键盘或鼠标时显示怎么退出",
        LocalizedStringResource("search.statusScreen.exitHint", defaultValue: "退出,提示"),
        keys: [Prefs.statusScreenExitHint])
    case .launchpadKeys:
      Self.row(
        .launchpad, "启动台的按键",
        LocalizedStringResource("search.launchpad.keys", defaultValue: "按键,速查"))
    case .launchpadColumns:
      Self.row(
        .launchpad, "一页几列",
        LocalizedStringResource("search.launchpad.columns", defaultValue: "列,排列"),
        keys: [Prefs.launchpadColumns])
    case .launchpadRows:
      Self.row(
        .launchpad, "一页几行", LocalizedStringResource("search.launchpad.rows", defaultValue: "行,排列"),
        keys: [Prefs.launchpadRows])
    case .launchpadFrequent:
      Self.row(
        .launchpad, "顶上一排常用的 App",
        LocalizedStringResource("search.launchpad.frequent", defaultValue: "常用,最近,经常,使用次数"),
        keys: [Prefs.launchpadFrequentRow])
    case .launchpadHidden:
      Self.row(
        .launchpad, "隐藏的 App",
        LocalizedStringResource("search.launchpad.hidden", defaultValue: "隐藏,显示,不显示,去掉"),
        keys: [Prefs.launchpadHiddenApps])
    case .launchpadCorner:
      Self.row(
        .launchpad, "屏幕角", LocalizedStringResource("search.launchpad.corner", defaultValue: "触发角"),
        keys: [Prefs.launchpadCorner])
    case .launchpadImport:
      Self.row(
        .launchpad, "从系统启动台导入",
        LocalizedStringResource("search.launchpad.import", defaultValue: "导入"))
    case .launchpadReset:
      Self.row(
        .launchpad, "恢复默认排列",
        LocalizedStringResource("search.launchpad.reset", defaultValue: "恢复默认,排列"))
    case .launchpadPinch:
      Self.row(
        .launchpad, "触控板手势",
        LocalizedStringResource("search.launchpad.pinch", defaultValue: "捏合,四指,五指"),
        keys: [Prefs.launchpadPinchGesture, Prefs.launchpadPinchSense])
    case .dockPreviewDelay:
      Self.row(
        .dockPreview, "停多久再弹出",
        LocalizedStringResource("search.dockPreview.delay", defaultValue: "延迟,多久"),
        keys: [Prefs.dockPreviewDelay])
    case .dockPreviewCmdTab:
      Self.row(
        .dockPreview, "按 ⌘Tab 时也显示",
        LocalizedStringResource("search.dockPreview.cmdTab", defaultValue: "Command Tab,切换器"),
        keys: [Prefs.dockPreviewCmdTab])
    case .finderMenu:
      Self.row(
        .finderMenu, "访达右键",
        LocalizedStringResource("search.finderMenu.menu", defaultValue: "右键菜单,子菜单,扩展"),
        keys: [Prefs.finderMenuGrouped])
    case .finderNewFile:
      Self.row(
        .finderMenu, "新建文件",
        LocalizedStringResource("search.finderMenu.newFile", defaultValue: "模板,后缀"))
    case .finderCopy:
      Self.row(
        .finderMenu, "拷贝",
        LocalizedStringResource("search.finderMenu.copy", defaultValue: "拷贝路径,复制路径,名称"))
    case .finderOrganize:
      Self.row(
        .finderMenu, "整理文件",
        LocalizedStringResource("search.finderMenu.organize", defaultValue: "移动,复制,剪切,粘贴,替身"))
    case .finderArchive:
      Self.row(
        .finderMenu, "压缩和解压",
        LocalizedStringResource("search.finderMenu.archive", defaultValue: "压缩,解压,zip,7z,乱码"),
        keys: [Prefs.finderTrashAfterExtract])
    case .finderHidden:
      Self.row(
        .finderMenu, "隐藏、哈希、删除",
        LocalizedStringResource("search.finderMenu.hidden", defaultValue: "隐藏,哈希,彻底删除"))
    case .finderFolders:
      Self.row(
        .finderMenu, "「移动到」「复制到」的常用文件夹",
        LocalizedStringResource("search.finderMenu.folders", defaultValue: "常用文件夹"))
    case .finderOpenWith:
      Self.row(
        .finderMenu, "在 App 中打开",
        LocalizedStringResource("search.finderMenu.openWith", defaultValue: "终端,编辑器,打开方式"))
    case .keepAwakeNow:
      Self.row(
        .keepAwake, "现在", LocalizedStringResource("search.keepAwake.now", defaultValue: "时长,停止"))
    case .keepAwakeDisplay:
      Self.row(
        .keepAwake, "屏幕也不熄",
        LocalizedStringResource("search.keepAwake.display", defaultValue: "屏幕,熄屏"),
        keys: [Prefs.keepAwakeDisplay])
    case .keepAwakeSchedule:
      Self.row(
        .keepAwake, "按时段自动保持唤醒",
        LocalizedStringResource("search.keepAwake.schedule", defaultValue: "定时,时段,工作日"),
        keys: [Prefs.keepAwakeSchedule])
    case .bluetoothLidOnly:
      Self.row(
        .bluetoothSnooze, "只在合上盖子时关",
        LocalizedStringResource("search.bluetoothSnooze.lidOnly", defaultValue: "合盖,盖子"),
        keys: [Prefs.bluetoothSnoozeLidOnly])
    case .bluetoothReopen:
      Self.row(
        .bluetoothSnooze, "醒来时重新打开蓝牙",
        LocalizedStringResource("search.bluetoothSnooze.reopen", defaultValue: "唤醒"),
        keys: [Prefs.bluetoothSnoozeReopen])
    case .smoothStrength:
      Self.row(
        .smoothScroll, "平滑程度",
        LocalizedStringResource("search.smoothScroll.strength", defaultValue: "平滑,惯性"),
        keys: [Prefs.smoothScrollStrength])
    case .smoothDistance:
      Self.row(
        .smoothScroll, "滚动距离",
        LocalizedStringResource("search.smoothScroll.distance", defaultValue: "速度,距离"),
        keys: [Prefs.smoothScrollSpeed])
    case .smoothReverseVertical:
      Self.row(
        .smoothScroll, "鼠标上下反向",
        LocalizedStringResource("search.smoothScroll.reverseVertical", defaultValue: "反向,自然滚动"),
        keys: [Prefs.smoothScrollReverseVertical])
    case .smoothReverseHorizontal:
      Self.row(
        .smoothScroll, "鼠标左右反向",
        LocalizedStringResource("search.smoothScroll.reverseHorizontal", defaultValue: "反向,横向"),
        keys: [Prefs.smoothScrollReverseHorizontal])
    case .smoothExcluded:
      Self.row(
        .smoothScroll, "在这些 App 里停用",
        LocalizedStringResource("search.smoothScroll.excluded", defaultValue: "停用,游戏,虚拟机,远程桌面"))
    case .keyRemappingKeyboard:
      Self.row(
        .keyRemapping, "键盘",
        LocalizedStringResource("search.keyRemapping.keyboard", defaultValue: "改键,映射,源键,目标键"))
    case .appShortcutsHold:
      Self.row(
        .appShortcuts, "按住一个键叫出来",
        LocalizedStringResource("search.appShortcuts.hold", defaultValue: "按住,长按"),
        keys: [Prefs.appShortcutsHold])
    case .appShortcutsKey:
      Self.row(
        .appShortcuts, "按哪个键",
        LocalizedStringResource("search.appShortcuts.key", defaultValue: "⌘,Command"),
        keys: [Prefs.appShortcutsHoldKey])
    case .appShortcutsDelay:
      Self.row(
        .appShortcuts, "按住多久",
        LocalizedStringResource("search.appShortcuts.delay", defaultValue: "多久"),
        keys: [Prefs.appShortcutsDelay])
    case .snippetExpandExcluded:
      Self.row(
        .snippetExpand, "在这些 App 里不展开",
        LocalizedStringResource("search.snippetExpand.excluded", defaultValue: "不展开,停用,密码管理器,终端"))
    case .islandNowPlaying:
      Self.row(
        .island, "在刘海上显示正在播放",
        LocalizedStringResource("search.island.nowPlaying", defaultValue: "正在播放,音乐,封面,切歌"),
        keys: [Prefs.islandNowPlaying], place: .subpage(.islandMedia))
    case .islandTrackPeek:
      Self.row(
        .island, "换歌时显示歌名", LocalizedStringResource("search.island.trackPeek", defaultValue: "歌名"),
        keys: [Prefs.islandTrackPeek], place: .subpage(.islandMedia))
    case .islandMediaColor:
      Self.row(
        .island, "跳动条和进度条的颜色",
        LocalizedStringResource("search.island.mediaColor", defaultValue: "封面,颜色"),
        keys: [Prefs.islandMediaColor], place: .subpage(.islandMedia))
    case .islandMusicFavorite:
      Self.row(
        .island, "播放卡片上显示收藏按钮",
        LocalizedStringResource("search.island.musicFavorite", defaultValue: "收藏,音乐"),
        keys: [Prefs.islandMusicFavorite], place: .subpage(.islandMedia))
    case .islandHidesWhenActive:
      Self.row(
        .island, "正在用放歌的 App 时不显示", keys: [Prefs.islandNowPlayingHidesWhenActive],
        place: .subpage(.islandMedia))
    case .islandNextEvent:
      Self.row(
        .island, "在刘海上显示下一个日程",
        LocalizedStringResource("search.island.nextEvent", defaultValue: "日程,日历,会议"),
        place: .subpage(.islandCalendar))
    case .islandEventChime:
      Self.row(
        .island, "日程开始时响一声",
        LocalizedStringResource("search.island.eventChime", defaultValue: "日程"),
        keys: [Prefs.islandEventChime], place: .subpage(.islandCalendar))
    case .islandHourlyChime:
      Self.row(
        .island, "整点报时", LocalizedStringResource("search.island.hourlyChime", defaultValue: "报时"),
        keys: [Prefs.islandHourlyChime], place: .subpage(.islandCalendar))
    case .islandCalendar:
      Self.row(
        .island, "点刘海打开时显示月历",
        LocalizedStringResource("search.island.calendar", defaultValue: "月历,日历"),
        keys: [Prefs.islandCalendar], place: .subpage(.islandCalendar))
    case .islandCalendarDots:
      Self.row(
        .island, "月历上标出有日程的日子",
        LocalizedStringResource("search.island.calendarDots", defaultValue: "月历"),
        keys: [Prefs.islandCalendarDots], place: .subpage(.islandCalendar))
    case .islandCalendarColors:
      Self.row(
        .island, "用日历的颜色",
        LocalizedStringResource("search.island.calendarColors", defaultValue: "日历,颜色"),
        keys: [Prefs.islandCalendarColors], place: .subpage(.islandCalendar))
    case .islandShowDeclined:
      Self.row(
        .island, "显示已拒绝的日程",
        LocalizedStringResource("search.island.showDeclined", defaultValue: "日程,拒绝"),
        keys: [Prefs.islandShowDeclined], place: .subpage(.islandCalendar))
    case .islandKeyLevels:
      Self.row(
        .island, "按音量键、亮度键时显示在刘海上",
        LocalizedStringResource("search.island.keyLevels", defaultValue: "音量,亮度,静音"),
        place: .subpage(.islandLevels))
    case .islandLevelStay:
      Self.row(
        .island, "停多久", LocalizedStringResource("search.island.levelStay", defaultValue: "音量,亮度"),
        keys: [Prefs.islandLevelStay], place: .subpage(.islandLevels))
    case .islandLevelAccent:
      Self.row(
        .island, "细条用强调色",
        LocalizedStringResource("search.island.levelAccent", defaultValue: "音量,亮度"),
        keys: [Prefs.islandLevelAccent], place: .subpage(.islandLevels))
    case .islandLevelPercent:
      Self.row(
        .island, "细条旁边显示百分比",
        LocalizedStringResource("search.island.levelPercent", defaultValue: "音量,亮度,百分比"),
        keys: [Prefs.islandLevelPercent], place: .subpage(.islandLevels))
    case .islandFocus:
      Self.row(
        .island, "在刘海上显示专注模式",
        LocalizedStringResource("search.island.focus", defaultValue: "专注模式,勿扰,睡眠"),
        keys: [Prefs.islandFocus], place: .subpage(.islandFocus))
    case .islandFocusPinned:
      Self.row(
        .island, "开着时一直挂在刘海上",
        LocalizedStringResource("search.island.focusPinned", defaultValue: "专注模式"),
        keys: [Prefs.islandFocusPinned], place: .subpage(.islandFocus))
    case .islandFocusSleepSound:
      Self.row(
        .island, "睡眠模式打开时响一声",
        LocalizedStringResource("search.island.focusSleepSound", defaultValue: "专注模式,睡眠"),
        keys: [Prefs.islandFocusSleepSound], place: .subpage(.islandFocus))
    case .islandFocusWaveform:
      Self.row(
        .island, "跳动条换成专注模式的图标",
        LocalizedStringResource("search.island.focusWaveform", defaultValue: "专注模式"),
        keys: [Prefs.islandFocusWaveform], place: .subpage(.islandFocus))
    case .islandFocusQuiet:
      Self.row(
        .island, "专注模式时不弹系统提示",
        LocalizedStringResource("search.island.focusQuiet", defaultValue: "专注模式"),
        keys: [Prefs.islandFocusQuiet], place: .subpage(.islandFocus))
    case .islandActions:
      Self.row(
        .island, "快捷动作", LocalizedStringResource("search.island.actions", defaultValue: "那一张,排序"),
        keys: [Prefs.islandActionOrder, Prefs.islandActionsOff], place: .subpage(.islandActions))
    case .islandShowsHistory:
      Self.row(
        .island, "列出最近的提示",
        LocalizedStringResource("search.island.showsHistory", defaultValue: "通知"),
        keys: [Prefs.islandShowsHistory])
    case .islandNotchClicks:
      Self.row(
        .island, "点刘海打开",
        LocalizedStringResource("search.island.notchClicks", defaultValue: "那一张,点刘海"),
        keys: [Prefs.islandNotchClicks])
    case .islandHoverExpands:
      Self.row(
        .island, "停在刘海上自动展开",
        LocalizedStringResource("search.island.hoverExpands", defaultValue: "悬停,自动展开"),
        keys: [Prefs.islandHoverExpands])
    case .islandHoverDelay: Self.row(.island, "停多久展开", keys: [Prefs.islandHoverDelay])
    case .islandNoticeLength:
      Self.row(
        .island, "提示停多久", LocalizedStringResource("search.island.noticeLength", defaultValue: "提示"),
        keys: [Prefs.islandNoticeLength], place: .advanced)
    case .islandHaptics:
      Self.row(
        .island, "触感反馈", LocalizedStringResource("search.island.haptics", defaultValue: "触感,震动"),
        keys: [Prefs.islandHaptics], place: .advanced)
    case .islandBlur:
      Self.row(
        .island, "展开时模糊四周", LocalizedStringResource("search.island.blur", defaultValue: "模糊"),
        keys: [Prefs.islandBlur], place: .advanced)
    case .islandOutlined:
      Self.row(
        .island, "描一圈细边", LocalizedStringResource("search.island.outlined", defaultValue: "细边,轮廓"),
        keys: [Prefs.islandOutlined], place: .advanced)
    case .islandHidesInFullScreen:
      Self.row(
        .island, "全屏时藏起来",
        LocalizedStringResource("search.island.hidesInFullScreen", defaultValue: "全屏"),
        keys: [Prefs.islandHidesInFullScreen], place: .advanced)
    case .islandHidesFromCapture:
      Self.row(
        .island, "截图、录屏时不显示刘海岛",
        LocalizedStringResource("search.island.hidesFromCapture", defaultValue: "截图,录屏"),
        keys: [Prefs.islandHidesFromCapture], place: .advanced)
    case .islandNoticePower:
      Self.row(
        .island, "接上、拔掉电源",
        LocalizedStringResource("search.island.noticePower", defaultValue: "电源,充电"),
        keys: [Prefs.islandNoticePower], place: .subpage(.islandNotices))
    case .islandNoticeBattery:
      Self.row(
        .island, "电量低", LocalizedStringResource("search.island.noticeBattery", defaultValue: "电池"),
        keys: [Prefs.islandNoticeBattery], place: .subpage(.islandNotices))
    case .islandNoticeHeadphones:
      Self.row(
        .island, "耳机连上",
        LocalizedStringResource("search.island.noticeHeadphones", defaultValue: "耳机,AirPods"),
        keys: [Prefs.islandNoticeHeadphones], place: .subpage(.islandNotices))
    case .islandNoticeNetwork:
      Self.row(
        .island, "断网、网络恢复",
        LocalizedStringResource("search.island.noticeNetwork", defaultValue: "网络,Wi-Fi"),
        keys: [Prefs.islandNoticeNetwork], place: .subpage(.islandNotices))
    case .islandNoticeLowPower:
      Self.row(
        .island, "低电量模式打开、关掉",
        LocalizedStringResource("search.island.noticeLowPower", defaultValue: "低电量模式"),
        keys: [Prefs.islandNoticeLowPower], place: .subpage(.islandNotices))
    case .hotkeysShotTools:
      Self.row(
        .hotkeys, "截图时：标注工具",
        LocalizedStringResource("search.hotkeys.shotTools", defaultValue: "截图,标注"))
    case .hotkeysShotOutput:
      Self.row(
        .hotkeys, "截图时：出图和操作",
        LocalizedStringResource("search.hotkeys.shotOutput", defaultValue: "截图,钉图,长截图,识字"))
    case .hotkeysPanels:
      Self.row(
        .hotkeys, "面板里的按键", LocalizedStringResource("search.hotkeys.panels", defaultValue: "速查"))
    case .hotkeysBlocked:
      Self.row(
        .hotkeys, "在这些 App 里停用",
        LocalizedStringResource("search.hotkeys.blocked", defaultValue: "停用,屏蔽,不响应"))
    case .aboutAutoCheck:
      Self.row(
        .about, "自动检查更新", LocalizedStringResource("search.about.autoCheck", defaultValue: "更新"),
        keys: [Prefs.updateAutoCheck])
    case .aboutInstallOnQuit:
      Self.row(
        .about, "在后台下载新版本，退出时安装",
        LocalizedStringResource("search.about.installOnQuit", defaultValue: "更新,下载"),
        keys: [Prefs.updateInstallOnQuit])
    }
  }

  var page: SettingsPage { info.page }

  var place: Place { info.place }

  /// 侧栏结果那一行下面写的位置：页名，挪进子页、「高级…」的写成「截图 › 截图历史」「截图 · 高级」
  var location: String {
    switch place {
    case .page: page.title
    case .subpage(let subpage): subpage.location
    case .advanced: page.advancedTitle
    }
  }

  /// 这一页的「高级…」表单里有没有新功能（WhatsNew 按行的标题认）：按钮左边挂「新」
  static func advancedIsNew(on page: SettingsPage, fresh: Set<String>) -> Bool {
    allCases.contains {
      $0.page == page && $0.place == .advanced
        && WhatsNew.marks(section: $0.info.title, of: page, in: fresh)
    }
  }

  /// 这个子页里有没有新功能：推进行标题后挂「新」（新功能标在子页名上的也算，如 0.9.0 的「正在播放」）
  static func subpageIsNew(_ subpage: SettingsSubpage, fresh: Set<String>) -> Bool {
    WhatsNew.marks(section: subpage.title, of: subpage.page, in: fresh)
      || allCases.contains {
        $0.place == .subpage(subpage)
          && WhatsNew.marks(section: $0.info.title, of: subpage.page, in: fresh)
      }
  }

  /// 这台 Mac 上、这会儿页面上有没有这一行（只在 macOS 26 上的、15.4 起才有的、多块屏才有的、截图功能开着才有的）：
  /// 没有的不列进搜索结果——点了只会换到一页、找不到那一行。跟着一个开关才露出来的另见 landing
  var isShown: Bool {
    switch self {
    case .generalDockIcon: ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
    case .generalClipboardAccess:
      if #available(macOS 15.4, *) { true } else { false }
    case .notesDeckDisplay: NSScreen.screens.count > 1
    case .hotkeysShotTools, .hotkeysShotOutput: Feature.screenshot.isOn
    default: true
    }
  }

  /// 选了这一项落到哪一行：跟着一个开关才露出来、这会儿藏着的，落到那个开关上（开了它才看得到）。defaults：单测给临时的
  func landing(_ defaults: UserDefaults = .standard) -> SettingsItem {
    switch self {
    case .screenshotHistoryDays, .screenshotHistorySize:
      defaults.bool(forKey: Prefs.shotHistory) ? self : .screenshotHistory
    case .generalMirror: SettingsBackup.isEnabled(defaults) ? self : .generalBackup
    // 「其他电脑」只在同步开着时有
    case .generalSyncPeers:
      defaults.string(forKey: Prefs.notesSyncFolder) != nil ? self : .generalSync
    default: self
    }
  }

  /// 标题的几种说法：当前语言的、中文原文（英文界面里打中文也找得到，同 SettingsPage.titles）
  var titles: [String] { Self.words[self]?.titles ?? [] }

  /// 界面语言要重新打开才换：每项的词算一次就够（每打一个字都要扫一遍全部）
  private static let words: [SettingsItem: (titles: [String], keywords: [String])] =
    Dictionary(
      uniqueKeysWithValues: allCases.map { item in
        let info = item.info
        let lists = info.keywords.map { [String(localized: $0), $0.chinese] } ?? []
        var keywords = lists.flatMap {
          $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        // 子页的名字（「音量与亮度」「查词与朗读」）算在这个子页第一行的搜索词里：搜它落进那个子页
        if case .subpage(let subpage) = info.place,
          allCases.first(where: { $0.place == .subpage(subpage) }) == item
        {
          keywords += [String(localized: subpage.title), subpage.title.chinese]
        }
        return (item, ([String(localized: info.title), info.title.chinese], keywords))
      })

  /// 对上了哪一档（越小越靠前）：0 标题以它开头、1 标题里有、2 只有搜索词里有；nil 没对上
  func rank(_ query: String) -> Int? {
    guard let words = Self.words[self] else { return nil }
    if words.titles.contains(where: {
      $0.range(of: query, options: [.caseInsensitive, .anchored]) != nil
    }) {
      return 0
    }
    if words.titles.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return 1 }
    if words.keywords.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return 2 }
    return nil
  }

  /// 侧栏「设置项」那一组列多少条
  static let resultLimit = 12

  /// 搜索对上的行（侧栏最上面那一组）：标题打头的 > 标题里有的 > 只有搜索词里有的，同一档按侧栏的页序、页里按登记的
  /// 先后；侧栏里没有的页（没添加的插件、这台系统上没有的启动台）的行不列
  /// limit：侧栏那一组列多少条；算侧栏该列哪几页时不截（第 12 条以后那几行所在的页也要在）
  static func matching(
    _ query: String, hidden: Set<SettingsPage>, limit: Int = resultLimit
  ) -> [SettingsItem] {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return [] }
    let pages = SettingsPage.visible.filter { !hidden.contains($0) }
    let hits = allCases.enumerated().compactMap { index, item -> (Int, Int, Int, SettingsItem)? in
      guard item.isShown, let page = pages.firstIndex(of: item.page), let rank = item.rank(query)
      else { return nil }
      return (rank, page, index, item)
    }
    return hits.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }.prefix(limit).map(\.3)
  }
}

extension View {
  /// 设置里的一行（S7）：搜索、别处直达时滚到这里、描一圈强调色（SettingsNavigation.highlighted）
  func settingsAnchor(_ item: SettingsItem) -> some View { modifier(SettingsAnchor(item: item)) }

  /// 外面描一圈 2 pt 强调色（圆角 card、往外 6），淡入淡出；设置项锚点和「全部插件」那一行共用
  func settingsHighlight(_ isOn: Bool) -> some View { modifier(SettingsHighlight(isOn: isOn)) }

  /// 分组表单外面挂一个：要描的那一行在这张表单里时滚过去（不在的话 scrollTo 什么都不做）
  func settingsScrollTarget() -> some View { modifier(SettingsScrollTarget()) }
}

private struct SettingsAnchor: ViewModifier {
  let item: SettingsItem
  /// 截图自检单独画一页时没有导航状态
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

  func body(content: Content) -> some View {
    content.id(item).settingsHighlight(navigation?.highlighted == item)
  }
}

private struct SettingsHighlight: ViewModifier {
  let isOn: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .strokeBorder(Style.brand, lineWidth: 2)
        .padding(-6)
        .opacity(isOn ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isOn)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

private struct SettingsScrollTarget: ViewModifier {
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      // 按次数认（highlightRound）：两秒内再选同一项，highlighted 没变，照样要再滚一次
      content.onChange(of: navigation?.highlightRound, initial: true) {
        guard let item = navigation?.highlighted else { return }
        // 晚一拍再滚（同全部插件页）：页面刚换过来时表单的行还没排好，当场滚不动
        Task {
          try? await Task.sleep(for: .milliseconds(150))
          proxy.scrollTo(item, anchor: .center)
        }
      }
    }
  }
}
