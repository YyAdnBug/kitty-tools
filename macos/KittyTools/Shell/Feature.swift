// 能单独关掉的功能（2026-10-21 用户要求「不用的功能模块可以关掉」；PLAN §10「功能开关」；2026-10-22 加了第九族程序坞预览，2026-11-08 加了访达右键）：设置 › 通用 › 功能一节、
// 每个功能自己设置页第一节的「启用」，两处是同一个偏好。和设置侧栏的页一一对应、同名（名字、符号、家族色都取 SettingsPage 的）。
// 关掉 = 入口全藏（快捷键不注册、菜单栏 / 启动器 / 快捷键页 / 速查表 / 引导「按一下试试」里都没有它（引导第一屏照列、不勾：那一屏就是挑功能的，M6），别的功能里指向它的按钮也藏）、后台活停掉；
// 数据层照常（库照开、每日备份、保留天数和「最近删除」到期照删），设置和快捷键原样留着，打开立即回来、不用重启。
// 新装默认只开剪贴板、启动器、截图、翻译（2026-11-04 功能管理拍板 M4，对标 PowerToys 新装默认关小众工具），其余用的人自己打开；
// 从旧版升级上来的照旧（M5：不然一升级就少了六样）。做法是新装第一次启动把开关明写进偏好（seedNewInstall），默认值本身不变。
// 起停在 AppDelegate.applyFeatures。代码不拆插件：没执行过的代码页本来就不进内存，省的是运行时的东西（热键、定时器、监听、
// 常驻窗口、缓存）不建、不起、不注册。以后加的全局动作、菜单项、启动器内置动作、跨功能的按钮都要归到一个 Feature（mac-native §1）。
// 插件（2026-11-12 拍板「全部按推荐」，PLAN §10「插件」）：以后新的大模块做成插件——同样编进 App、同样一个开关（「添加」=
// 打开、「移除」= 关掉，设置和数据留着），区别只在露不露面：新装、升级都默认不添加；没添加的不进设置侧栏（也不进「已关闭」那组）、
// 欢迎引导、「功能」列表和主界面的「N 个功能关着」，只在 设置 › 通用 › 功能 下面的「插件」卡片里，和启动器里打它的名字时
// 最后那一行「添加…插件」（LauncherModel.pluginOffers）。
// 2026-11-13（拍板页 https://claude.ai/artifact/DEKeRvQeZR3VxkVA9Bx2Fr「全部按推荐」）：便签、提醒、状态屏、启动台、程序坞预览、
// 访达右键也改成插件，另加刘海岛（只管点刘海那一张、两边的活动、系统提示；岛上的提示是全 App 的，不归它）。功能剩剪贴板、
// 启动器、翻译、截图、录制。转过来的照旧用原来的偏好键和默认值：开着的就是添加着，升级上来什么都不变（P2）。

import Foundation

/// nonisolated：便签那叠的设置（NoteDeckOptions，不绑主线程）也要读开没开
nonisolated enum Feature: String, CaseIterable {
  // 顺序 = 设置侧栏、通用页「功能」、菜单栏、快捷键页、速查表的顺序（2026-11-04 功能管理拍板 M3：便签、提醒、状态屏一组，
  // 启动台、程序坞预览一组）。rawValue 是偏好键，不能改
  case clipboard, launcher, translate, screenshot, record, notes, reminders, statusScreen
  case launchpad, dockPreview, finderMenu
  // 2026-11-13 起便签之后这几个都是插件（isPlugin），保持唤醒、刘海岛新加在最后（刘海岛那一节一直排在菜单栏、快捷键页最后）
  case keepAwake, island

  /// 同名的设置页（名字、符号、家族色从它取）
  @MainActor var page: SettingsPage { SettingsPage(rawValue: rawValue) ?? .general }
  @MainActor var title: String { page.title }

  /// 偏好里的键（注册了默认值 defaultOn：跟着导出 / 导入的「设置」一类走）
  var prefsKey: String { Prefs.featurePrefix + rawValue }

  /// 「功能」列表、每页「启用」那一行的说明
  var blurb: String {
    switch self {
    case .clipboard: "记下复制过的文字、图片和文件，随时找回来粘贴"
    case .launcher: "一个搜索框：打开 App、文件和网页，顺手算算式"
    case .translate: "划词、输入、截图翻译，复制即译"
    case .screenshot: "框选截图、识别图中文字、钉在屏幕上"
    case .record: "录屏和录音"
    case .notes: "快速记一条，屏幕边缘的便签"
    case .launchpad: "全屏的 App 图标网格"
    case .statusScreen: "盖住屏幕、拦住键盘鼠标的告示"
    case .reminders: "到点提醒你：一次、每天、每周或每隔一阵"
    case .dockPreview: "鼠标停在程序坞的 App 图标上，看它所有窗口的缩略图"
    case .finderMenu: "在访达里右键：新建文件、拷贝路径、移动复制、压缩解压"
    case .keepAwake: "不让电脑睡、不让屏幕熄：手动开一段，或按时段自动开"
    case .island: "点刘海叫出快捷动作和最近的提示，录屏计时、提醒倒数、正在播放挂在刘海两边"
    }
  }

  /// 插件（2026-11-12 起新的大模块；2026-11-13 起除了核心五个都是）
  static let plugins: Set<Feature> = [
    .notes, .reminders, .statusScreen, .launchpad, .dockPreview, .finderMenu, .keepAwake, .island,
  ]
  var isPlugin: Bool { Self.plugins.contains(self) }

  /// 插件卡片上那两行：要什么授权、在后台做什么（拍板 A2：添加之前就看得清）；不是插件的 nil
  var pluginFacts: (permission: String, background: String)? {
    switch self {
    case .notes: ("不要", "屏幕边缘一条细药丸；开着同步时跟着合")
    case .reminders: ("不要", "等着下一条提醒；一条都没有时什么都不跑")
    case .statusScreen: ("进入时要「辅助功能」（拦住键盘鼠标）", "没进入时什么都不跑")
    case .launchpad: ("不要", "看着触控板捏合和触发角，装卸 App 时重扫一遍")
    case .dockPreview: ("辅助功能、屏幕录制", "看着程序坞；鼠标停在图标上才截缩略图")
    case .finderMenu: ("要在系统设置里打开访达扩展", "只在你右键时动")
    case .keepAwake: ("不要", "开着时让系统别睡；没开时什么都不跑")
    case .island:
      (
        "不要（正在播放读不到时，「音乐」「Spotify」的播放控制要「自动化」）",
        "看着指针有没有停在刘海上；打开了系统提示才听电源、耳机、网络，打开了正在播放才起一个读播放信息的小进程。不添加时提示照常弹"
      )
    default: nil
    }
  }

  /// 启动器里打这些词（插件没添加时）出「添加…插件」那一行；名字本身也算
  var pluginWords: [String] {
    switch self {
    case .notes: ["便签", "笔记", "note", "notes", "记一条"]
    case .reminders: ["提醒", "闹钟", "remind", "reminder"]
    case .statusScreen: ["状态屏", "请勿触碰", "status"]
    case .launchpad: ["启动台", "launchpad"]
    case .dockPreview: ["程序坞", "窗口预览", "dock"]
    case .finderMenu: ["访达右键", "右键菜单", "finder"]
    case .keepAwake: ["awake", "保持唤醒", "防息屏", "防止睡眠", "不睡眠", "唤醒", "咖啡因", "caffeinate"]
    case .island: ["刘海岛", "刘海", "灵动岛", "island", "notch"]
    default: []
    }
  }

  /// 没存过时开不开。程序坞预览默认关（拍板 A3：改的是系统程序坞的行为、还要屏幕录制授权，由用户自己打开）；
  /// 访达右键也默认关（2026-11-08 拍板 D2：改的是访达的菜单，还要去系统设置里打开扩展，默认开着也不生效）。
  /// 全 App 只有这一套：新装只开四个不是靠改它，是第一次启动时把开关明写进偏好（seedNewInstall）——导出、同步里「没有这一项
  /// = 默认值」，各台默认值不一样的话，导入老电脑的文件、加入同步时没动过的开关会被悄悄换成这台的默认
  /// 新做的插件默认不添加（拍板 A1：新装、升级都不添加）。2026-11-13 从功能转过来的插件照旧用原来的默认值（P2：导出文件、
  /// 同步里「没有这一项 = 默认值」，改了的话 0.8.x 的文件、电脑会把没拨过的便签悄悄关掉）；刘海岛也算开着——0.7.0 起就有
  /// 点刘海，升级上来照旧能用。新装照样一个插件都没添加：seedNewInstall 把核心以外的都明写成关
  var defaultOn: Bool { ![.dockPreview, .finderMenu, .keepAwake].contains(self) }

  /// 新装默认开着的四个（功能管理拍板 M4）
  static let core: Set<Feature> = [.clipboard, .launcher, .translate, .screenshot]

  /// 启动时最先做（在 Prefs.registerDefaults 之前，持久域之外还没有别的值）：新装把每个功能的开关明写进偏好，core 那四个开、
  /// 别的关（M5）。新装 = 还没看过任何一版（Prefs.lastSeenVersion 空）、引导也没开过（Prefs.onboardingScreen 空：0.7.1 起
  /// 引导走完才记看过哪一版，装了 0.7.1 没关引导就用了几天的人升级上来不能算新装；本版第一次启动时它还没写，这一步在开引导之前）。
  /// 只补没存过的；升级上来的不碰（没动过的照旧按 defaultOn）
  /// 只看持久域（同 Prefs.migrate：按套件名开的 UserDefaults 也会读到宿主 App 自己的域）
  static func seedNewInstall(
    _ defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier
  ) {
    let stored = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    guard stored[Prefs.lastSeenVersion] == nil, stored[Prefs.onboardingScreen] == nil else {
      return
    }
    for feature in allCases where stored[feature.prefsKey] == nil {
      defaults.set(core.contains(feature), forKey: feature.prefsKey)
    }
  }

  /// 这台系统上有没有（启动台只在 macOS 26 起）：没有的哪里都不出现，「功能」列表里也没有它那一行
  var isAvailable: Bool { self != .launchpad || Launchpad.isAvailable }

  /// 开着：这台系统有、用户也没关。没存过 = defaultOn（不靠注册的默认值：单测宿主不一定注册过）
  var isOn: Bool {
    isAvailable && (UserDefaults.standard.object(forKey: prefsKey) as? Bool ?? defaultOn)
  }

  /// 此刻开着的功能（快捷键、菜单栏、启动器、速查表按它现算；添加了的插件也在里面）
  static var enabled: Set<Feature> { Set(allCases.filter(\.isOn)) }

  /// 「功能」列表、欢迎引导、主界面「N 个功能关着」列的：这台系统上有的功能，不含插件
  static var listed: [Feature] { allCases.filter { $0.isAvailable && !$0.isPlugin } }
}
