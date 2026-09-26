// 设置窗（Whisker §6 设置）：普通 NSWindow 里放 SwiftUI 的 NavigationSplitView。左边侧栏 = 家族色块 + 页名，
// 顶上的搜索框按每页的关键词筛页；右边每页一个页头（40 pt 家族色块 + 标题 + 一句说明）+ 分组表单。
// 记住上次看的页，窗口标题跟着页走；首次安装时盖一层欢迎引导（OnboardingView）。
// 不用 SwiftUI Settings scene：LSUIElement 应用里它会被压到别的 App 后面，浮层上的齿轮也调不到 openSettings。
// 打开：先收起浮层 → 切成 .regular（出现 Dock 图标）并激活；关闭时切回 .accessory。

import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
  case general, clipboard, launcher, screenshot, translate, hotkeys, about

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
    case .about: Style.brand
    }
  }

  /// 页头下面的一句说明
  var summary: String {
    switch self {
    case .general: "开机自启和权限"
    case .clipboard: "历史上限、面板、内容格式和隐私"
    case .launcher: "搜索 App、文件、书签、网页搜索与快捷链接"
    case .screenshot: "快速保存、快门声和识字"
    case .translate: "语言、翻译服务与密钥、历史"
    case .hotkeys: "所有全局快捷键"
    case .about: "版本与更新内容"
    }
  }

  /// 侧栏搜索按这些词筛页（页里各项设置的叫法）
  var keywords: [String] {
    switch self {
    case .general:
      ["开机", "登录", "自启", "权限", "辅助功能", "屏幕录制", "剪贴板访问", "隐私"]
    case .clipboard:
      [
        "历史", "条数", "天数", "保留", "图片", "占用", "预览", "链接", "网页", "点外", "关闭", "格式", "RTF",
        "HTML", "识别", "文字", "OCR", "隐私", "密钥", "银行卡", "清空", "退出", "锁屏", "排除", "App",
        "收藏", "片段", "分组", "密码", "敏感", "网站", "标题",
      ]
    case .launcher:
      [
        "英文", "输入法", "书签", "Chrome", "Edge", "Brave", "搜索", "引擎", "快捷链接", "关键词",
        "兜底", "使用记录", "最近", "挤压", "弹开", "动画", "实验", "文件", "open", "find", "Spotlight",
      ]
    case .screenshot:
      ["保存", "目录", "文件夹", "快门", "声音", "识字", "换行", "二维码", "标注", "长截图", "钉图", "按键", "速查"]
    case .translate:
      [
        "语言", "第一语言", "第二语言", "字号", "换行", "自动复制", "历史", "导出", "CSV", "Anki", "服务", "密钥",
        "查词", "词典", "单词", "音标", "例句", "生词本", "收藏",
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

/// 设置窗的导航状态：当前页（记住）、欢迎引导开没开
@Observable final class SettingsNavigation {
  var page: SettingsPage {
    didSet { UserDefaults.standard.set(page.rawValue, forKey: Prefs.settingsPage) }
  }
  var showsOnboarding = false

  init() {
    page =
      UserDefaults.standard.string(forKey: Prefs.settingsPage).flatMap(SettingsPage.init)
      ?? .general
  }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
  private let window: NSWindow
  let navigation = SettingsNavigation()

  /// - Parameters:
  ///   - page: 每页的表单
  ///   - onboarding: 欢迎引导（sheet 里，关掉用 dismiss）
  init(page: @escaping (SettingsPage) -> AnyView, onboarding: @escaping () -> AnyView) {
    let hosting = NSHostingController(
      rootView: SettingsRoot(navigation: navigation, page: page, onboarding: onboarding))
    hosting.sceneBridgingOptions = [.title, .toolbars]
    window = NSWindow(contentViewController: hosting)
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

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
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
          Label {
            Text(page.title)
          } icon: {
            if page == .about {
              Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
            } else {
              KindTile(symbol: page.symbol, color: page.color, size: 20)
            }
          }
          .tag(page)
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
        if navigation.page != .about { PageHeader(page: navigation.page) }
        page(navigation.page)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle(navigation.page.title)
    }
    .toolbar(removing: .sidebarToggle)
    .onChange(of: query) {
      if let first = matches.first, !matches.contains(navigation.page) { navigation.page = first }
    }
    // 从菜单栏等处直接跳到一页，而旧搜索词把它筛掉了：清掉搜索词（侧栏不留一个没选中的残局）
    .onChange(of: navigation.page) {
      if !matches.contains(navigation.page) { query = "" }
    }
    .sheet(isPresented: $navigation.showsOnboarding) {
      onboarding().symbolEffectsRemoved(reduceMotion)
    }
    .symbolEffectsRemoved(reduceMotion)
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
