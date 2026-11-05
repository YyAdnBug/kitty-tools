// 设置窗（Whisker §6 设置）：普通 NSWindow 里放 SwiftUI 的 NavigationSplitView。左边侧栏 = 家族色块 + 页名，
// 顶上的搜索框按每页的关键词筛页；右边每页一个页头（40 pt 家族色块 + 标题 + 一句说明）+ 分组表单。
// 记住上次看的页，窗口标题跟着页走；首次安装时盖一层欢迎引导（OnboardingView）。
// 工具栏常驻「‹ 返回」（SettingsBackButton，同系统设置）：翻译服务、网页搜索、状态屏的状态的详情页里点它或 ⌘[ 回列表，别处置灰；
// 主菜单「显示 › 返回 ⌘[」同效（SettingsCommands，HIG：工具栏上的操作菜单栏里也要有）。
// 不用 SwiftUI Settings scene：LSUIElement 应用里它会被压到别的 App 后面，浮层上的齿轮也调不到 openSettings。
// 打开：先收起浮层 → 切成 .regular（出现 Dock 图标）并激活；关闭时切回 .accessory。
// 侧栏选中自己画（SidebarRow）：AppKit 画侧栏选中时会把 App 的强调色大幅压深（品牌粉变成暗红，截图实测约 #9C2F3E），
// 选了 8 色时也仍是系统强调色，没有公开 API 改。保留 List(selection:)（点选、↑↓、VoiceOver「已选中」、
// 跟着 navigation.page 走都还是系统的），只把外面那个 NSTableView 的 selectionHighlightStyle 设成 .none
// 让它不画（NativeHighlightOff），再用 listRowBackground 按系统同样的几何画一块。不自己写行 + 键盘导航：
// 那样焦点、↑↓、无障碍都要重做，代码多、手感还不如系统的。

import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
  // 和菜单栏、快捷键页、引导、速查表同序（记住的上次页存的是 rawValue，调顺序不受影响）。2026-11-04 功能管理拍板 M3：
  // 便签、提醒、状态屏一组，启动台、程序坞预览一组（启动台原来在便签后面）
  case general, clipboard, launcher, translate, screenshot, record, notes, reminders, statusScreen,
    launchpad, dockPreview, hotkeys, about

  var id: String { rawValue }

  /// 侧栏和搜索里列的页：macOS 15 上没有启动台（`Launchpad.isAvailable`）
  static let visible = visible(launchpad: Launchpad.isAvailable)

  /// 侧栏的分组（功能管理拍板 M2 M3）：通用 ｜ 文字与搜索 ｜ 截图与录制 ｜ 便签与提醒 ｜ 桌面 ｜ 快捷键、关于。和 allCases 同序，
  /// 单测锁住。功能那四组带标题、能折叠（groupTitle）
  static let groups: [[SettingsPage]] = [
    [.general], [.clipboard, .launcher, .translate], [.screenshot, .record],
    [.notes, .reminders, .statusScreen], [.launchpad, .dockPreview], [.hotkeys, .about],
  ]

  /// 侧栏的一组：标题（没有就不画）、组里的页；isOff 是最底下「已关闭」那组
  struct SidebarGroup: Equatable, Identifiable {
    let title: String?
    let pages: [SettingsPage]
    var isOff = false
    var id: String { isOff ? "off" : title ?? pages.first?.rawValue ?? "" }
  }

  /// 侧栏这一刻怎么分组（纯函数）：只留 pages 里有的（搜索匹配、这台系统有），空了的组不画；关着的功能（off）不在原来的组里，
  /// 照侧栏顺序挪进最底下的「已关闭（N）」组（2026-11-05 用户提议，对标 VS Code 扩展栏底下折叠着的「已停用」）
  static func sidebar(_ pages: [SettingsPage], off: Set<SettingsPage>) -> [SidebarGroup] {
    let shown = groups.compactMap { group -> SidebarGroup? in
      let kept = group.filter { pages.contains($0) && !off.contains($0) }
      return kept.isEmpty ? nil : SidebarGroup(title: group.first?.groupTitle, pages: kept)
    }
    let closed = allCases.filter { pages.contains($0) && off.contains($0) }
    return closed.isEmpty
      ? shown : shown + [SidebarGroup(title: "已关闭（\(closed.count)）", pages: closed, isOff: true)]
  }

  /// 侧栏组标题（2026-11-04 真机反馈「间距那里有个提示」：同访达、邮件侧栏的小标题，点一下收起 / 展开，对标 PowerToys 导航的分组）。
  /// 通用、快捷键与关于两组不写：一头一尾，收起来也省不了地方
  var groupTitle: String? {
    switch self {
    case .clipboard, .launcher, .translate: "文字与搜索"
    case .screenshot, .record: "截图与录制"
    case .notes, .reminders, .statusScreen: "便签与提醒"
    case .launchpad, .dockPreview: "桌面"
    case .general, .hotkeys, .about: nil
    }
  }

  /// 这一页是哪个功能的设置（通用、快捷键、关于不是）：功能关着时侧栏里这一行变淡、标「已关闭」（M1）
  var feature: Feature? { Feature(rawValue: rawValue) }

  /// 单测喂 false 看 macOS 15 上的样子
  static func visible(launchpad: Bool) -> [SettingsPage] {
    allCases.filter { launchpad || $0 != .launchpad }
  }

  var title: String {
    switch self {
    case .general: "通用"
    case .clipboard: "剪贴板"
    case .launcher: "启动器"
    case .launchpad: "启动台"
    case .screenshot: "截图"
    case .record: "录制"
    case .notes: "便签"
    case .statusScreen: "状态屏"
    case .reminders: "提醒"
    case .dockPreview: "程序坞预览"
    case .translate: "翻译"
    case .hotkeys: "快捷键"
    case .about: "关于"
    }
  }

  var symbol: String {
    switch self {
    case .general: "kitty.general"
    case .clipboard: HotKeyAction.clipboard.symbol
    case .launcher: HotKeyAction.launcher.symbol
    case .launchpad: HotKeyAction.launchpad.symbol
    case .screenshot: HotKeyAction.screenshot.symbol
    case .record: HotKeyAction.screenRecord.symbol
    case .notes: HotKeyAction.noteAll.symbol
    case .statusScreen: HotKeyAction.statusScreen.symbol
    // 自己画的闹钟（拍板 F2；icons/feature/kitty.reminders.svg）
    case .reminders: "kitty.reminders"
    case .dockPreview: "kitty.dock.preview"
    case .translate: "kitty.translate"
    case .hotkeys: "kitty.hotkeys"
    case .about: "kitty.about"  // 品牌页：猫头
    }
  }

  /// 功能家族色（mac-whisker §3）
  var color: Color {
    switch self {
    case .general: Style.Family.general
    case .clipboard: Style.Family.clipboard
    case .launcher: Style.Family.command
    case .launchpad: Style.Family.launchpad
    case .screenshot, .record: Style.Family.screenshot
    case .notes: Style.Family.notes
    case .statusScreen: Style.Family.statusScreen
    case .reminders: Style.Family.reminders
    case .dockPreview: Style.Family.dockPreview
    case .translate: Style.Family.translate
    case .hotkeys: Style.Family.keyboard
    case .about: Color(nsColor: AccentPalette.brandPink)  // 关于是品牌页，不随强调色变
    }
  }

  /// 页头下面的一句说明
  var summary: String {
    switch self {
    case .general: "功能、外观、菜单栏、登录时打开、权限、同步、导出与导入、数据目录"
    case .clipboard: "历史上限、面板、内容格式和隐私"
    case .launcher: "搜索 App、文件、书签与历史、网页搜索与快捷链接"
    case .launchpad: "全屏的图标网格：排法、翻页、搜索、文件夹、捏合"
    case .screenshot: "快速保存、工具栏位置、快门声、缩略图和识字"
    case .record: "录屏的画质、倒数和按键，录音的来源"
    case .notes: "留着看、接着改的东西：屏幕边缘的那一叠、字号和行距，存在哪、怎么备份"
    case .statusScreen: "拦住键盘鼠标的全屏告示：有哪些状态、各是什么样子、怎么退出"
    case .reminders: "到点提醒你：什么时候响、用什么方式、点了「稍后」推多久"
    case .dockPreview: "停在程序坞图标上时弹出的窗口缩略图：开关和要给的授权"
    case .translate: "语言、翻译服务与密钥、历史"
    case .hotkeys: "所有全局快捷键"
    case .about: "版本与更新内容"
    }
  }

  /// 侧栏搜索按这些词筛页（页里各项设置的叫法）
  var keywords: [String] {
    switch self {
    case .general:
      [
        "外观", "浅色", "深色", "暗黑", "主题", "跟随系统", "强调色", "主题色", "颜色", "开机", "登录", "自启", "权限", "辅助功能",
        "屏幕录制", "麦克风",
        "剪贴板访问", "隐私", "菜单栏", "状态栏", "图标", "隐藏", "彩色", "单色", "挤压", "弹开", "动画", "动效",
        "导出", "导入", "备份", "恢复", "迁移", "换电脑", "配置",
        "功能", "模块", "关闭", "停用", "启用", "不用",
        "同步", "iCloud", "云盘", "多台", "几台", "另一台",
        "数据", "数据目录", "访达", "文件夹",
      ]
    case .clipboard:
      [
        "历史", "天数", "保留", "永久", "图片", "占用", "预览", "链接", "网页", "格式", "纯文本",
        "识别", "文字", "OCR", "隐私", "密钥", "银行卡", "清空", "退出", "锁屏", "排除", "App",
        "收藏", "收藏夹", "片段", "密码", "敏感", "网站", "标题", "透镜", "单击", "双击", "点击", "粘贴",
        "位置", "面板位置", "鼠标", "跟随鼠标", "上次位置",
      ]
    case .launcher:
      [
        "英文", "输入法", "书签", "浏览历史", "历史", "浏览器", "Safari", "Chrome", "Edge", "Arc", "Brave",
        "Firefox",
        "完全磁盘访问", "搜索", "引擎", "快捷链接", "关键词",
        "兜底", "使用记录", "常用", "最近", "收藏", "文件", "open", "find", "Spotlight",
        "位置", "面板位置", "鼠标", "跟随鼠标", "上次位置",
      ]
    case .launchpad:
      [
        "启动台", "图标", "网格", "全屏", "应用", "App", "排法", "排列", "列", "行", "翻页", "页",
        "搜索", "App 文件夹", "拖动", "抖动", "删除", "卸载", "App Store", "捏合", "触控板", "四指", "五指",
        "触发角", "导入", "系统启动台", "Launchpad", "快捷键",
      ]
    case .screenshot:
      [
        "保存", "存储", "目录", "文件夹", "快门", "声音", "缩略图", "识字", "换行", "二维码", "标注", "长截图", "钉图",
        "按键", "速查", "工具栏", "位置", "靠右", "居中", "录制条",
      ]
    case .record:
      [
        "录屏", "录音", "视频", "保存", "文件夹", "系统声音", "麦克风", "来源", "立即开始", "控制条", "倒数", "帧率", "光标",
        "按键", "速查", "清晰度", "分辨率", "画质", "编码", "H.264", "HEVC", "文件大小", "体积", "压缩", "只显示快捷键",
      ]
    case .notes:
      [
        "笔记", "备忘", "便利贴", "快速记", "记一条", "字号", "字体大小", "最近删除", "归档", "备份", "导出", "导入",
        "屏幕边缘", "边缘", "药丸", "标签", "色块", "感应范围", "一直展开", "悬停", "预览", "全屏", "显示器", "便签大小",
        "Markdown", "粗体", "斜体", "链接", "引用", "行距", "行高", "间距", "代码块",
      ]
    case .statusScreen:
      [
        "清洁", "擦屏幕", "请勿触碰", "马上回来", "告示", "防误触", "退出", "Esc", "提示", "熄屏", "透出", "样式", "图标",
        "电源", "不睡眠", "屏幕常亮", "自动结束", "键盘", "鼠标", "拦截", "预览卡片", "直接进入", "选择状态",
        "动画", "表情", "出场",
      ]
    case .reminders:
      [
        "提醒", "定时", "闹钟", "倒计时", "喝水", "休息", "护眼", "久坐", "走走", "稍后", "推迟", "间隔", "每天", "工作日",
        "每周", "每月", "一次", "刘海岛", "边框", "全屏", "声音", "提示音", "朗读", "催促", "错过",
      ]
    case .dockPreview:
      [
        "程序坞", "Dock", "预览", "缩略图", "窗口", "切换", "悬停", "最小化", "桌面", "全屏", "辅助功能", "屏幕录制",
      ]
    case .translate:
      [
        "语言", "第一语言", "第二语言", "字号", "换行", "自动复制", "复制即译", "历史", "导出", "CSV", "Anki",
        "位置", "浮窗位置", "鼠标", "清空",
        "服务", "密钥", "查词", "词典", "单词", "音标", "例句", "生词本", "收藏",
        "智谱", "OpenAI", "Anthropic", "DeepL", "Google", "百度", "有道", "微软", "火山", "腾讯", "AI", "模型",
      ]
    case .hotkeys:
      // 「钉图」：动作名是「钉住剪贴板里的图」，搜「钉图」也要找得到这一页
      ["快捷键", "热键", "冲突", "录制", "恢复默认", "速查", "按键", "钉图"]
        + HotKeyAction.allCases.filter(\.isActive).map(\.title)
    case .about: ["版本", "更新", "日志", "发布", "欢迎", "引导"]
    }
  }

  func matches(_ query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    return ([title] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
  }

  /// 搜索时停在哪页：页名对上的优先（「录制」也是通用页的「屏幕录制」、快捷键页的「录制」，「快捷键」也是录制页的
  /// 「只显示快捷键」，按侧栏顺序会先停在别处）；否则当前页还在结果里就不动，不在就去第一个，一页都没有也不动
  static func page(for query: String, current: SettingsPage) -> SettingsPage {
    let query = query.trimmingCharacters(in: .whitespaces)
    let matches = visible.filter { $0.matches(query) }
    if !query.isEmpty,
      let named = matches.first(where: { $0.title.localizedCaseInsensitiveContains(query) })
    {
      return named
    }
    return matches.contains(current) ? current : matches.first ?? current
  }
}

/// 设置窗的导航状态：当前页（记住）、页里推进的详情页、欢迎引导开没开、窗口是不是 key
@Observable final class SettingsNavigation {
  var page: SettingsPage {
    didSet {
      defaults?.set(page.rawValue, forKey: Prefs.settingsPage)
      if page != oldValue { path = [] }
    }
  }
  /// 记住上次的页写在哪；单测 / 截图自检传 nil（从通用页开始、换页不写用户的偏好）
  private let defaults: UserDefaults?
  /// 当前页推进的详情页（翻译服务 / 网页搜索 / 状态屏的状态的 id；TranslateTab、LauncherTab、StatusScreenTab 的
  /// NavigationStack 用它），换页时清空
  var path: [String] = []
  var showsOnboarding = false {
    didSet { if oldValue, !showsOnboarding { onboardingClosed() } }
  }
  /// 欢迎引导关掉了（「开始使用」、Esc、关掉设置窗都算走完）：AppDelegate 这时才记「看过这一版」（第四轮体检 E1）
  @ObservationIgnored var onboardingClosed: () -> Void = {}
  /// 快捷键速查表（启动器里的「快捷键速查表」打开设置窗时盖上；页面里的「查看全部快捷键…」按钮自己管）
  var showsShortcuts = false
  /// 设置窗是 key（SettingsWindow 的窗口代理写）。开着 sheet（确认框、速查表、引导）或别的面板在前时不是
  var isKey = false
  /// 新功能标记（Shell/WhatsNew.swift）：设置窗里此刻要标的那几个（WhatsNew.Entry.id）——侧栏那一行、收起的组、页里那一节。
  /// 换页时 visit 现算（看着的那页留着，换页才没）；截图自检直接摆
  var fresh: Set<String> = []
  /// 换到一页了（打开设置窗也算）：记下碰过、重算 fresh（AppDelegate 接上；单测、截图自检不接，不写偏好）
  @ObservationIgnored var visit: (SettingsPage) -> Void = { _ in }

  /// 主菜单「返回」能不能用：只在设置窗自己在前、推进了详情页时
  var canGoBack: Bool { isKey && !path.isEmpty }

  /// 主菜单「返回」：菜单项的可用状态要到打开菜单时才同步（SwiftUI 在 menuNeedsUpdate 里刷，实测），
  /// 过期的可用状态可能还在，所以这里再判断一次（空路径 removeLast 会崩）
  func goBack() {
    if canGoBack { path.removeLast() }
  }

  init(defaults: UserDefaults? = .standard) {
    self.defaults = defaults
    // 记住的是这台系统上没有的页（导入了 26 上的设置）就回通用页
    let saved = defaults?.string(forKey: Prefs.settingsPage).flatMap(SettingsPage.init)
    page = saved.flatMap { SettingsPage.visible.contains($0) ? $0 : nil } ?? .general
  }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
  /// 最小的内容尺寸（各页 SwiftUI 自己算的最小只有 294–490 × 150–160，2026-10-18 量）
  static let minSize = NSSize(width: 700, height: 460)

  /// 只读：单测看窗口的内容和最小尺寸
  let window: NSWindow
  let navigation: SettingsNavigation

  /// - Parameters:
  ///   - navigation: 导航状态（AppDelegate 持有，主菜单的「返回」也读它；窗口是懒建的）
  ///   - page: 每页的表单
  ///   - onboarding: 欢迎引导（sheet 里，关掉用 dismiss）
  ///   - frameName: 记住窗口位置和大小用的名字（单测传 nil：不写偏好）
  init(
    navigation: SettingsNavigation, page: @escaping (SettingsPage) -> AnyView,
    onboarding: @escaping () -> AnyView, frameName: String? = "Settings"
  ) {
    self.navigation = navigation
    // 内容包在普通容器里：宿主视图当窗口的 contentView 会闪退（见 windowContent）
    window = NSWindow(
      contentViewController: .windowContent(
        SettingsRoot(navigation: navigation, page: page, onboarding: onboarding)))
    // 标题桥接要等 SwiftUI 那边第一次变化才写进窗口，刚建出来是「未命名」（实测，换一次页才对）：先按当前页填上
    window.title = navigation.page.title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.setContentSize(NSSize(width: 780, height: 600))
    window.contentMinSize = Self.minSize
    super.init()
    window.delegate = self
    guard let frameName else { return }
    if !window.setFrameUsingName(frameName) { window.center() }
    window.setFrameAutosaveName(frameName)
  }

  /// page：要切到的页；nil 保持上次的页。onboarding：盖上欢迎引导（首次安装、关于页里重看）
  func show(page: SettingsPage? = nil, onboarding: Bool = false) {
    // 页面上开着 sheet（快捷键速查表、确认框等）时不换页：换页会把那一页连同 sheet 和没保存的输入一起拆掉
    if let page, window.attachedSheet == nil { navigation.page = page }
    // 新功能标记：打开设置窗也算打开了那一页（换了页时 SettingsRoot 的 onChange 也会来一次，重复的不写偏好）
    navigation.visit(navigation.page)
    if onboarding { navigation.showsOnboarding = true }
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    // macOS 14 起 activate() 是协作式的，前台 App 不让出时可能到不了最前：退回旧 API
    // （M3 验收实测三个入口，结论记进 mac-overlay-panel 技能）
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
  }

  func windowDidBecomeKey(_ notification: Notification) { navigation.isKey = true }
  func windowDidResignKey(_ notification: Notification) { navigation.isKey = false }

  func windowWillClose(_ notification: Notification) {
    // 引导开着时关掉设置窗也算关掉了引导（E1）
    if navigation.showsOnboarding { navigation.showsOnboarding = false }
    NSApp.leaveDockIfNoWindows(closing: window)
  }
}

extension NSViewController {
  /// 普通窗口（设置窗、全部便签窗口）的内容：SwiftUI 的宿主控制器包在一个普通容器里，宿主视图不当窗口的 contentView、
  /// 也不按内容定大小（sizingOptions = []，同 OverlayPanel），窗口的大小和最小尺寸只由窗口这边定。
  /// 宿主视图当了 contentView 时，SwiftUI 会按内容改窗口的最小 / 最大尺寸（手写的被它覆盖成每个视图自己算的，小得多）、
  /// 在动画里跟着改窗口大小，和约束更新互相触发，轮数超了 AppKit 抛异常直接闪退（2026-10-18 0.5.0 正式版的一次闪退；
  /// 只设 sizingOptions = [] 不够——它照样在动画里改窗口大小、还把最小尺寸清成 0；屏外复现和回归见 NotesWindowTests）。
  /// 标题和工具栏照常桥接
  static func windowContent(_ rootView: some View) -> NSViewController {
    let hosting = NSHostingController(rootView: rootView)
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.title, .toolbars]
    let container = NSViewController()
    container.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    container.addChild(hosting)
    hosting.view.frame = container.view.bounds
    hosting.view.autoresizingMask = [.width, .height]
    container.view.addSubview(hosting.view)
    return container
  }
}

extension NSApplication {
  /// 普通窗口（设置窗、全部便签窗口）关掉时调：别的普通窗口都不开着了才切回 .accessory（收起程序坞图标）——
  /// 两个窗口都开着时关掉一个，另一个还要留在程序坞和 ⌘⇥ 里
  func leaveDockIfNoWindows(closing: NSWindow) {
    if !Self.hasOrdinaryWindow(in: windows, besides: closing) { setActivationPolicy(.accessory) }
  }

  /// 除了正在关的那个，还有没有开着的普通窗口（纯函数）：看得见、能当主窗口的（带标题栏的）；浮层、岛、遮罩、钉图都是
  /// 面板或无边框窗口，当不了主窗口；挂着的表单（sheet）不算
  static func hasOrdinaryWindow(in windows: [NSWindow], besides closing: NSWindow) -> Bool {
    windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain && !$0.isSheet }
  }
}

/// 主菜单「显示 › 返回 ⌘[」：设置窗不是 key（开着 sheet、别的面板在前）或没推进详情页时置灰。
/// 工具栏按钮上也挂着 ⌘[：SwiftUI 到打开菜单时才把状态同步到菜单项（实测），只靠菜单的话推进后没打开过菜单
/// 就按不动；两边做的是同一件事（这边经 goBack 再判断一次），谁接住都一样。这里主要是让菜单栏里看得到、点得到
struct SettingsCommands: Commands {
  let navigation: SettingsNavigation

  var body: some Commands {
    CommandGroup(before: .toolbar) {
      Button("返回", action: navigation.goBack)
        .keyboardShortcut("[")
        .disabled(!navigation.canGoBack)
    }
  }
}

/// 侧栏 + 页面。搜索时侧栏只留匹配的页，搜的是页名就跳到那页，当前页不在结果里就跳到第一个匹配的
struct SettingsRoot: View {
  @Bindable var navigation: SettingsNavigation
  let page: (SettingsPage) -> AnyView
  let onboarding: () -> AnyView
  @State private var query = ""
  /// 收起了的组（组标题，换行隔开；这台电脑自己的）
  @AppStorage(Prefs.settingsCollapsedGroups) private var collapsedGroups = ""
  /// 底下「已关闭」那组展开着没有（默认收起）
  @AppStorage(Prefs.settingsShowsOffFeatures) private var showsOff = false
  /// 关着的功能的页：开关一变（偏好变化的通知）跟着挪组
  @State private var off = Self.offPages()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static func offPages() -> Set<SettingsPage> {
    Set(Feature.allCases.filter { $0.isAvailable && !$0.isOn }.map(\.page))
  }

  /// 「已关闭」那组：搜索时、当前页就在里面时一直展开（不然对上的、正看着的那页藏在收起的组里）
  private var offExpanded: Binding<Bool> {
    Binding {
      !query.isEmpty || showsOff || off.contains(navigation.page)
    } set: {
      showsOff = $0
    }
  }

  private var matches: [SettingsPage] { SettingsPage.visible.filter { $0.matches(query) } }

  /// 一组展开没有：搜索时都展开（不然对上的页藏在收起的组里）
  private func expanded(_ title: String) -> Binding<Bool> {
    Binding {
      !query.isEmpty || !collapsed.contains(title)
    } set: { open in
      var titles = collapsed
      if open { titles.remove(title) } else { titles.insert(title) }
      collapsedGroups = titles.sorted().joined(separator: "\n")
    }
  }

  private var collapsed: Set<String> {
    Set(collapsedGroups.split(separator: "\n").map(String.init))
  }

  private func rows(_ group: [SettingsPage]) -> some View {
    ForEach(group) { page in
      SidebarRow(
        page: page, isSelected: page == navigation.page,
        isNew: WhatsNew.marks(page, in: navigation.fresh)
      )
      .tag(page)
    }
  }

  /// 功能组的小标题；收起着、里面有新功能时后面一个小圆点（拍板 A4：标记藏在收起的组里等于没标）
  private func header(_ title: String, _ pages: [SettingsPage]) -> some View {
    HStack(spacing: 5) {
      Text(title)
      if !expanded(title).wrappedValue,
        pages.contains(where: { WhatsNew.marks($0, in: navigation.fresh) })
      {
        NewDot()
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        // 分组：功能那四组带小标题、点标题收起 / 展开（同访达的侧栏）；通用、快捷键与关于不写标题；关着的功能在最底下
        // 「已关闭」那组（默认收起）
        ForEach(SettingsPage.sidebar(matches, off: off)) { group in
          if group.isOff, let title = group.title {
            Section(isExpanded: offExpanded) {
              rows(group.pages)
            } header: {
              Text(title)
            }
          } else if let title = group.title {
            Section(isExpanded: expanded(title)) {
              rows(group.pages)
            } header: {
              header(title, group.pages)
            }
          } else {
            Section { rows(group.pages) }
          }
        }
      }
      .overlay {
        if matches.isEmpty {
          Text("没有匹配的设置").font(.callout).foregroundStyle(.secondary)
        }
      }
      .searchable(text: $query, placement: .sidebar, prompt: "搜索设置")
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    } detail: {
      VStack(spacing: 0) {
        // 关于是品牌页、没有页头；翻译、启动器、启动台、状态屏、提醒把页头画在自己的 NavigationStack 里，推进详情页时一起换掉（N12）
        if ![.about, .translate, .launcher, .launchpad, .statusScreen, .reminders].contains(
          navigation.page)
        {
          PageHeader(page: navigation.page)
        }
        page(navigation.page)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle(navigation.page.title)
      .toolbar { SettingsBackButton() }
    }
    .toolbar(removing: .sidebarToggle)
    .environment(navigation)
    .onChange(of: query) {
      let page = SettingsPage.page(for: query, current: navigation.page)
      if page != navigation.page { navigation.page = page }
    }
    // 从菜单栏等处直接跳到一页，而旧搜索词把它筛掉了：清掉搜索词（侧栏不留一个没选中的残局）；那一页在收起的组里就展开
    .onChange(of: navigation.page) {
      navigation.visit(navigation.page)
      if !matches.contains(navigation.page) { query = "" }
      if let title = navigation.page.groupTitle, collapsed.contains(title) {
        expanded(title).wrappedValue = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      let now = Self.offPages()
      if now != off {
        off = now
        // 开关变了：关着的功能不标（拍板 B5），重算一遍
        navigation.visit(navigation.page)
      }
    }
    .sheet(isPresented: $navigation.showsOnboarding) {
      onboarding().symbolEffectsRemoved(reduceMotion).appAccent()
    }
    .sheet(isPresented: $navigation.showsShortcuts) {
      ShortcutsButton.sheet().symbolEffectsRemoved(reduceMotion).appAccent()
    }
    .symbolEffectsRemoved(reduceMotion)
    .appAccent()
  }

  /// List 的单选要可选值；点空白处（nil）时保持当前页
  private var selection: Binding<SettingsPage?> {
    Binding {
      navigation.page
    } set: {
      if let page = $0 { navigation.page = page }
    }
  }
}

/// 侧栏一行 + 选中高亮（为什么自己画见文件头）：窗口是 key 时 = 强调色填充 + onBrand 字（系统侧栏的样子，
/// 颜色取 Style.brand，增强对比度时它自己换压深的填充）；不是 key 时退成中性 selectedFill + 普通字，像系统那样
/// 在后台不喊人。换页是瞬时的，和系统侧栏一样不滑（不用管减弱动态效果）
private struct SidebarRow: View {
  let page: SettingsPage
  let isSelected: Bool
  /// 新功能标记：行尾系统的徽标「新」（拍板 C1）
  var isNew = false
  @Environment(\.controlActiveState) private var activeState

  /// 系统侧栏选中块的几何（macOS 15.7 屏外实测，和原生高亮逐像素对过）：左右各内缩 10、整行高、圆角 5
  private static let inset: CGFloat = 10
  private static let radius: CGFloat = 5

  var body: some View {
    let emphasized = isSelected && activeState == .key
    Group {
      // 只在强调色上设字色：显式设了前景（哪怕是 .foreground）会盖掉侧栏自己的字色（后台窗口变灰那套）
      if emphasized { label.foregroundStyle(Style.onBrand) } else { label }
    }
    // 徽标在外面那层字色之外：强调色的选中行上跟着页名换成 onBrand，别处不设（系统徽标自己的颜色）
    .badge(
      isNew
        ? emphasized ? Text(WhatsNew.label).foregroundStyle(Style.onBrand) : Text(WhatsNew.label)
        : nil
    )
    .background(NativeHighlightOff())
    .listRowBackground(isSelected ? highlight(emphasized: emphasized) : nil)
  }

  @ViewBuilder private var label: some View {
    if let feature = page.feature {
      FeatureSidebarLabel(
        page: page, feature: feature)
    } else {
      Label {
        Text(page.title)
      } icon: {
        if page == .about {
          Image(nsImage: Self.aboutIcon)
        } else {
          KindTile(symbol: page.symbol, color: page.color, size: 20)
        }
      }
    }
  }

  /// 「关于」那一行的图标：App 图标裁掉四周的留白、只留主体（同菜单栏的彩色图标），画成和别的色块一样大的 20 pt。
  /// 直接把 App 图标缩到 20 的话，主体只有 16（1024 的画布四边各留 100），比上面那一列色块小一圈
  private static let aboutIcon = StatusItem.menuBarImage(
    from: NSApp.applicationIconImage, points: 20)

  private func highlight(emphasized: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    return shape.fill(emphasized ? Style.brand : Style.selectedFill)
      .overlay { if !emphasized { shape.contrastSelectionBorder() } }
      .padding(.horizontal, Self.inset)
  }
}

/// 功能页那一行：看着它的开关（@AppStorage，开关一变就跟上）。关着时色块变淡（功能管理拍板 M1：页面照样留在侧栏里、点进去
/// 第一行就是开关，对标 PowerToys / Raycast 的自带功能）；关着的都在最底下「已关闭」那组里（2026-11-05），行尾不再另写
/// 「已关闭」。名字不另设字色：选中时的 onBrand、后台窗口变灰都由外面那层管
private struct FeatureSidebarLabel: View {
  let page: SettingsPage
  @AppStorage private var isOn: Bool

  init(page: SettingsPage, feature: Feature) {
    self.page = page
    _isOn = AppStorage(wrappedValue: feature.defaultOn, feature.prefsKey)
  }

  var body: some View {
    Label {
      Text(page.title).lineLimit(1).truncationMode(.tail)
    } icon: {
      KindTile(symbol: page.symbol, color: page.color, size: 20)
        .opacity(isOn ? 1 : Style.disabledOpacity)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isOn ? page.title : page.title + "，已关闭")
  }
}

/// 关掉外面那个 NSTableView（SwiftUI 的侧栏 List 在 macOS 上就是它）的原生选中高亮。每行挂一个，行建出来时设一次。
/// ponytail: 依赖 List 由 NSTableView 实现（macOS 15 实测是 NSOutlineView 子类）；哪天不是了就找不到，原生高亮
/// 回来垫在自绘那块下面（key 时被不透明的强调色盖住、后台时灰得深一点），那时改成自己画行 + onKeyPress 导航。
/// 全部便签窗口的列表（Notes/NotesWindowView.swift）也用它：那边的选中是中性高亮
struct NativeHighlightOff: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) { view.apply() }

  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    /// 不接鼠标：点选照旧交给表格
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply() {
      let table = sequence(first: self as NSView, next: \.superview).lazy
        .compactMap { $0 as? NSTableView }.first
      table?.selectionHighlightStyle = .none
    }
  }
}

/// 工具栏的「‹ 返回」：各页上置灰占位，推进的详情页（TranslateServiceDetail、SearchEngineDetail、StatusPresetDetail）自己再声明一个
/// 能点的（action = dismiss），⌘[ 同效。要自己放、还得两处都放（macOS 15 实测）：NavigationStack 自带的返回按钮
/// 桥接不进 NSHostingController 的窗口工具栏；外层声明的工具栏项在内层 NavigationStack 推进后整个丢掉。常驻是因为
/// 工具栏一出一没，标题栏高度（28 ↔ 52）和整页内容都会跳
struct SettingsBackButton: ToolbarContent {
  var action: (() -> Void)?

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button("返回", systemImage: "chevron.backward") { action?() }
        .disabled(action == nil)
        .keyboardShortcut("[")
        .help("返回")
    }
  }
}

/// 页头：40 pt 家族色块 + 标题（title2）+ 一句说明（callout）
struct PageHeader: View {
  let page: SettingsPage

  var body: some View {
    HStack(spacing: 12) {
      KindTile(symbol: page.symbol, color: page.color, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(page.title).font(.title2.weight(.semibold))
        Text(page.summary).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .pageHeaderInsets()
    .accessibilityElement(children: .combine)
  }
}

extension View {
  /// 页头在页里的位置：左右 20（设置窗边距）、上 14、下 2。列表页的 PageHeader 和三种详情页的 DetailHeader 共用——
  /// 推进详情页时页头的图标和标题原地换，不跳（2026-10-12 视觉对齐前详情页的页头放在分组表单的 Section header 里，
  /// 比列表页的右移 10、下移 6）
  func pageHeaderInsets() -> some View {
    padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
  }
}

/// 分组页脚：解释整组的说明小字，所有设置页和详情页共用（2026-10-12 视觉对齐前有五种写法，有的靠右、折行后参差）。
/// caption secondary；一律靠左、折行也靠左（分组表单的页脚默认靠右排，折到第二行的字也是：两样都要写）；
/// 左右各缩 10，和分组标题、卡片里的行文字同一条左边线（卡片的内边距是 10）。
/// 解释某一行的不用它，写成那一行的副标题（Toggle / LabeledContent 标签里的第二个 Text，系统画成 11 pt）
struct SectionFootnote: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
  }
}

extension View {
  /// 设置窗自己成为 key 时跑一下（从系统设置授权回来、关掉表单回到页面时刷新授权、登录项这些；第四轮体检 F3）。
  /// 原来听的是全局的 didBecomeKeyNotification：剪贴板面板、启动器、启动台、截图遮罩……任何窗口成为 key 都把每页的
  /// 检查跑一遍（读授权、读系统手势、读浏览器历史）。没有设置窗的地方（截图自检）不跑
  func onSettingsBecameKey(perform action: @escaping () -> Void) -> some View {
    modifier(SettingsBecameKey(action: action))
  }
}

private struct SettingsBecameKey: ViewModifier {
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  let action: () -> Void

  func body(content: Content) -> some View {
    content.onChange(of: navigation?.isKey == true) { _, isKey in
      if isKey { action() }
    }
  }
}
