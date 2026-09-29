// 设置窗（Whisker §6 设置）：普通 NSWindow 里放 SwiftUI 的 NavigationSplitView。左边侧栏 = 家族色块 + 页名，
// 顶上的搜索框按每页的关键词筛页；右边每页一个页头（40 pt 家族色块 + 标题 + 一句说明）+ 分组表单。
// 记住上次看的页，窗口标题跟着页走；首次安装时盖一层欢迎引导（OnboardingView）。
// 工具栏常驻「‹ 返回」（SettingsBackButton，同系统设置）：翻译服务、网页搜索的详情页里点它或 ⌘[ 回列表，别处置灰；
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
  // 翻译在截图前面：和菜单栏、快捷键页、引导、速查表同序（记住的上次页存的是 rawValue，调顺序不受影响）
  case general, clipboard, launcher, translate, screenshot, hotkeys, about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "通用"
    case .clipboard: "剪贴板"
    case .launcher: "启动器"
    case .screenshot: "截图"
    case .translate: "翻译"
    case .hotkeys: "快捷键"
    case .about: "关于"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape.fill"
    case .clipboard: "doc.on.clipboard.fill"
    case .launcher: "command"
    case .screenshot: "camera.viewfinder"
    case .translate: "character.bubble.fill"
    case .hotkeys: "keyboard.fill"
    case .about: "info.circle.fill"
    }
  }

  /// 功能家族色（mac-whisker §3）
  var color: Color {
    switch self {
    case .general: Style.Family.general
    case .clipboard: Style.Family.clipboard
    case .launcher: Style.Family.command
    case .screenshot: Style.Family.screenshot
    case .translate: Style.Family.translate
    case .hotkeys: Style.Family.keyboard
    case .about: Color(nsColor: AccentPalette.brandPink)  // 关于是品牌页，不随强调色变
    }
  }

  /// 页头下面的一句说明
  var summary: String {
    switch self {
    case .general: "外观、菜单栏图标、登录时打开和权限"
    case .clipboard: "历史上限、面板、内容格式和隐私"
    case .launcher: "搜索 App、文件、书签与历史、网页搜索与快捷链接"
    case .screenshot: "快速保存、快门声、缩略图和识字"
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
        "屏幕录制",
        "剪贴板访问", "隐私", "菜单栏", "状态栏", "图标", "隐藏", "彩色", "单色",
      ]
    case .clipboard:
      [
        "历史", "天数", "保留", "永久", "图片", "占用", "预览", "链接", "网页", "格式", "纯文本",
        "识别", "文字", "OCR", "隐私", "密钥", "银行卡", "清空", "退出", "锁屏", "排除", "App",
        "收藏", "收藏夹", "片段", "密码", "敏感", "网站", "标题", "透镜",
      ]
    case .launcher:
      [
        "英文", "输入法", "书签", "浏览历史", "历史", "Chrome", "Edge", "Brave", "搜索", "引擎", "快捷链接", "关键词",
        "兜底", "使用记录", "常用", "最近", "收藏", "挤压", "弹开", "动画", "实验", "文件", "open", "find", "Spotlight",
      ]
    case .screenshot:
      [
        "保存", "存储", "目录", "文件夹", "快门", "声音", "缩略图", "识字", "换行", "二维码", "标注", "长截图", "钉图",
        "按键", "速查",
      ]
    case .translate:
      [
        "语言", "第一语言", "第二语言", "字号", "换行", "自动复制", "复制即译", "历史", "导出", "CSV", "Anki",
        "位置", "浮窗位置", "鼠标", "清空",
        "服务", "密钥", "查词", "词典", "单词", "音标", "例句", "生词本", "收藏",
        "智谱", "OpenAI", "Anthropic", "DeepL", "Google", "百度", "有道", "微软", "火山", "腾讯", "AI", "模型",
      ]
    case .hotkeys:
      ["快捷键", "热键", "冲突", "录制", "恢复默认", "速查", "按键"] + HotKeyAction.allCases.map(\.title)
    case .about: ["版本", "更新", "日志", "发布", "欢迎", "引导"]
    }
  }

  func matches(_ query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    return ([title] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
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
  /// 当前页推进的详情页（翻译服务 / 网页搜索的 id；TranslateTab、LauncherTab 的 NavigationStack 用它），换页时清空
  var path: [String] = []
  var showsOnboarding = false
  /// 快捷键速查表（启动器里的「快捷键速查表」打开设置窗时盖上；页面里的「查看全部快捷键…」按钮自己管）
  var showsShortcuts = false
  /// 设置窗是 key（SettingsWindow 的窗口代理写）。开着 sheet（确认框、速查表、引导）或别的面板在前时不是
  var isKey = false

  /// 主菜单「返回」能不能用：只在设置窗自己在前、推进了详情页时
  var canGoBack: Bool { isKey && !path.isEmpty }

  /// 主菜单「返回」：菜单项的可用状态要到打开菜单时才同步（SwiftUI 在 menuNeedsUpdate 里刷，实测），
  /// 过期的可用状态可能还在，所以这里再判断一次（空路径 removeLast 会崩）
  func goBack() {
    if canGoBack { path.removeLast() }
  }

  init(defaults: UserDefaults? = .standard) {
    self.defaults = defaults
    page = defaults?.string(forKey: Prefs.settingsPage).flatMap(SettingsPage.init) ?? .general
  }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
  private let window: NSWindow
  let navigation: SettingsNavigation

  /// - Parameters:
  ///   - navigation: 导航状态（AppDelegate 持有，主菜单的「返回」也读它；窗口是懒建的）
  ///   - page: 每页的表单
  ///   - onboarding: 欢迎引导（sheet 里，关掉用 dismiss）
  init(
    navigation: SettingsNavigation, page: @escaping (SettingsPage) -> AnyView,
    onboarding: @escaping () -> AnyView
  ) {
    self.navigation = navigation
    let hosting = NSHostingController(
      rootView: SettingsRoot(navigation: navigation, page: page, onboarding: onboarding))
    hosting.sceneBridgingOptions = [.title, .toolbars]
    window = NSWindow(contentViewController: hosting)
    // 标题桥接要等 SwiftUI 那边第一次变化才写进窗口，刚建出来是「未命名」（实测，换一次页才对）：先按当前页填上
    window.title = navigation.page.title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.setContentSize(NSSize(width: 780, height: 600))
    window.contentMinSize = NSSize(width: 700, height: 460)
    super.init()
    window.delegate = self
    if !window.setFrameUsingName("Settings") { window.center() }
    window.setFrameAutosaveName("Settings")
  }

  /// page：要切到的页；nil 保持上次的页。onboarding：盖上欢迎引导（首次安装、关于页里重看）
  func show(page: SettingsPage? = nil, onboarding: Bool = false) {
    // 页面上开着 sheet（快捷键速查表、确认框等）时不换页：换页会把那一页连同 sheet 和没保存的输入一起拆掉
    if let page, window.attachedSheet == nil { navigation.page = page }
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
    NSApp.setActivationPolicy(.accessory)
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

/// 侧栏 + 页面。搜索时侧栏只留匹配的页，当前页不在里面就跳到第一个匹配的
struct SettingsRoot: View {
  @Bindable var navigation: SettingsNavigation
  let page: (SettingsPage) -> AnyView
  let onboarding: () -> AnyView
  @State private var query = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var matches: [SettingsPage] { SettingsPage.allCases.filter { $0.matches(query) } }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        ForEach(matches) { page in
          SidebarRow(page: page, isSelected: page == navigation.page).tag(page)
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
        // 关于是品牌页、没有页头；翻译、启动器把页头画在自己的 NavigationStack 里，推进详情页时一起换掉（N12）
        if ![.about, .translate, .launcher].contains(navigation.page) {
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
      if let first = matches.first, !matches.contains(navigation.page) { navigation.page = first }
    }
    // 从菜单栏等处直接跳到一页，而旧搜索词把它筛掉了：清掉搜索词（侧栏不留一个没选中的残局）
    .onChange(of: navigation.page) {
      if !matches.contains(navigation.page) { query = "" }
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
    .background(NativeHighlightOff())
    .listRowBackground(isSelected ? highlight(emphasized: emphasized) : nil)
  }

  private var label: some View {
    Label {
      Text(page.title)
    } icon: {
      if page == .about {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
      } else {
        KindTile(symbol: page.symbol, color: page.color, size: 20)
      }
    }
  }

  private func highlight(emphasized: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    return shape.fill(emphasized ? Style.brand : Style.selectedFill)
      .overlay { if !emphasized { shape.contrastSelectionBorder() } }
      .padding(.horizontal, Self.inset)
  }
}

/// 关掉外面那个 NSTableView（SwiftUI 的侧栏 List 在 macOS 上就是它）的原生选中高亮。每行挂一个，行建出来时设一次。
/// ponytail: 依赖 List 由 NSTableView 实现（macOS 15 实测是 NSOutlineView 子类）；哪天不是了就找不到，原生高亮
/// 回来垫在自绘那块下面（key 时被不透明的强调色盖住、后台时灰得深一点），那时改成自己画行 + onKeyPress 导航
private struct NativeHighlightOff: NSViewRepresentable {
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

/// 工具栏的「‹ 返回」：各页上置灰占位，推进的详情页（TranslateServiceDetail、SearchEngineDetail）自己再声明一个
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
    .padding(.horizontal, 20)
    .padding(.top, 14)
    .padding(.bottom, 2)
    .accessibilityElement(children: .combine)
  }
}
