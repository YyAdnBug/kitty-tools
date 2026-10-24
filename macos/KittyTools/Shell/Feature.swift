// 能单独关掉的功能（2026-10-21 用户要求「不用的功能模块可以关掉」；PLAN §10「功能开关」；2026-10-22 加了第九族程序坞预览）：设置 › 通用 › 功能一节、
// 每个功能自己设置页第一节的「启用」，两处是同一个偏好。和设置侧栏的页一一对应、同名（名字、符号、家族色都取 SettingsPage 的）。
// 关掉 = 入口全藏（快捷键不注册、菜单栏 / 启动器 / 快捷键页 / 速查表 / 引导里都没有它，别的功能里指向它的按钮也藏）、后台活停掉；
// 数据层照常（库照开、每日备份、保留天数和「最近删除」到期照删），设置和快捷键原样留着，打开立即回来、不用重启。
// 起停在 AppDelegate.applyFeatures。代码不拆插件：没执行过的代码页本来就不进内存，省的是运行时的东西（热键、定时器、监听、
// 常驻窗口、缓存）不建、不起、不注册。以后加的全局动作、菜单项、启动器内置动作、跨功能的按钮都要归到一个 Feature（mac-native §1）。

import Foundation

/// nonisolated：便签那叠的设置（NoteDeckOptions，不绑主线程）也要读开没开
nonisolated enum Feature: String, CaseIterable {
  case clipboard, launcher, translate, screenshot, record, notes, launchpad, statusScreen,
    dockPreview

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
    case .dockPreview: "鼠标停在程序坞的 App 图标上，看它所有窗口的缩略图"
    }
  }

  /// 没存过时开不开。程序坞预览默认关（拍板 A3：改的是系统程序坞的行为、还要屏幕录制授权，由用户自己打开）
  var defaultOn: Bool { self != .dockPreview }

  /// 这台系统上有没有（启动台只在 macOS 26 起）：没有的哪里都不出现，「功能」列表里也没有它那一行
  var isAvailable: Bool { self != .launchpad || Launchpad.isAvailable }

  /// 开着：这台系统有、用户也没关。没存过 = defaultOn（不靠注册的默认值：单测宿主不一定注册过）
  var isOn: Bool {
    isAvailable && (UserDefaults.standard.object(forKey: prefsKey) as? Bool ?? defaultOn)
  }

  /// 此刻开着的功能（快捷键、菜单栏、启动器、速查表按它现算）
  static var enabled: Set<Feature> { Set(allCases.filter(\.isOn)) }
}
