// 设置里有序列表（N12）的单测：网页搜索一条的问题提示（名称、网址、保留 / 重复关键词（只算搜索之间）、用不上）、
// 列表 JSON 读写（关键词去空白）、预置判断（删自定义的要确认）、翻译服务状态副标题（开着才标橙）、
// 列表有几行就多高（不封顶，每一行都在外框里）；
// 另有通用页的外观偏好 → NSAppearance 名字、设置窗侧栏不画原生选中高亮（自绘那块才是选中）、工具栏的「‹ 返回」和主菜单「显示 › 返回」。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct SettingsListTests {
  /// 侧栏顺序和菜单栏、快捷键页、引导同序：翻译在截图前面（体检 B51），录制紧跟截图（2026-10-03 拆出来）
  @Test func sidebarOrderMatchesMenu() {
    let pages = SettingsPage.allCases
    #expect(
      pages == [
        .general, .clipboard, .launcher, .translate, .screenshot, .record, .hotkeys, .about,
      ])
    let sections = HotKeyAction.sections.map(\.title)
    #expect(sections.firstIndex(of: "翻译")! < sections.firstIndex(of: "截图与录制")!)
  }

  /// 侧栏搜索按改名后的叫法也找得到：启动器的「常用」「收藏」，翻译的「浮窗位置」「清空」
  @Test func sidebarSearchFindsNewNames() {
    #expect(SettingsPage.launcher.matches("常用") && SettingsPage.launcher.matches("收藏"))
    #expect(SettingsPage.translate.matches("浮窗位置") && SettingsPage.translate.matches("清空"))
  }

  /// 搜页名停在那一页：「录制」也是通用页（屏幕录制）、快捷键页里的说法，「快捷键」也是录制页里的（只显示快捷键）；
  /// 录屏的设置只在录制页；当前页还在结果里不动，没有结果也不动
  @Test func sidebarSearchPrefersPageTitle() {
    #expect(SettingsPage.page(for: "录制", current: .clipboard) == .record)
    #expect(SettingsPage.page(for: " 快捷键", current: .general) == .hotkeys)
    #expect(SettingsPage.page(for: "帧率", current: .screenshot) == .record)
    #expect(!SettingsPage.screenshot.matches("录屏") && !SettingsPage.screenshot.matches("麦克风"))
    #expect(SettingsPage.page(for: "文件夹", current: .record) == .record)
    #expect(SettingsPage.page(for: "文件夹", current: .about) == .screenshot)
    #expect(SettingsPage.page(for: "没有这一项", current: .about) == .about)
    #expect(SettingsPage.page(for: "", current: .about) == .about)
  }

  private func engine(
    _ id: String, name: String = "Name", keyword: String = "", url: String, fallback: Bool = false
  ) -> SearchEngine {
    SearchEngine(id: id, name: name, keyword: keyword, urlTemplate: url, enabled: fallback)
  }

  @Test func searchEngineProblems() {
    let problem = { (engine: SearchEngine, list: [SearchEngine]) in
      SearchEngineDetail.problem(of: engine, in: list)
    }
    let google = engine("g", keyword: "g", url: "https://www.google.com/search?q={query}")
    #expect(problem(google, [google]) == nil)
    // 没名称 / 默认的「https://」/ 没协议
    #expect(problem(engine("a", name: "  ", url: "https://a.com"), []) == "还没填名称")
    #expect(problem(engine("a", url: "https://"), []) == "网址不完整")
    #expect(problem(engine("a", keyword: "x", url: "example.com/?q={query}"), []) == "网址不完整")
    // 快捷链接可以是路径和自定义协议；搜索不收路径
    #expect(problem(engine("a", url: "~/Downloads"), []) == nil)
    #expect(problem(engine("a", url: "maps://?q=home"), []) == nil)
    #expect(problem(engine("a", keyword: "d", url: "/tmp/{query}"), []) == "网址不完整")
    // 保留关键词、和前面的重复（排在前面的那条没问题）
    #expect(
      problem(engine("a", keyword: "CB", url: "https://a.com/?q={query}"), [])
        == "关键词「cb」留给剪贴板指令")
    let copy = engine("b", name: "Google 2", keyword: "G", url: "https://b.com/?q={query}")
    #expect(problem(copy, [google, copy]) == "关键词和「Name」重复，用的是靠前的那个")
    #expect(problem(google, [google, copy]) == nil)
    // 快捷链接的关键词只参与名称匹配：和搜索同关键词、谁在前都不算重复
    let docLink = engine("l", keyword: "doc", url: "https://developer.apple.com")
    let docSearch = engine("s", keyword: "doc", url: "https://d.com/?q={query}")
    #expect(problem(docSearch, [docLink, docSearch]) == nil)
    let gLink = engine("l", keyword: "g", url: "https://g.com")
    #expect(problem(gLink, [google, gLink]) == nil)
    // 搜索没关键词也不兜底就用不上；勾了兜底就行
    #expect(problem(engine("a", url: "https://a.com/?q={query}"), []) == "没有关键词也不兜底，用不上")
    #expect(problem(engine("a", url: "https://a.com/?q={query}", fallback: true), []) == nil)
  }

  @Test func engineListCoding() throws {
    #expect(SearchEngineDetail.decode(nil) == WebSearch.defaults)
    #expect(SearchEngineDetail.decode(Data("garbage".utf8)) == WebSearch.defaults)
    let data = try #require(
      SearchEngineDetail.encode([engine("a", keyword: " g h ", url: "https://a.com/?q={query}")]))
    #expect(SearchEngineDetail.decode(data).first?.keyword == "gh")
  }

  @Test func engineTitles() {
    #expect(SearchEngineDetail.title(engine("a", name: " ", url: "https://a.com")) == "未命名")
    #expect(SearchEngineDetail.kindTitle(engine("a", url: "https://a.com")) == "快捷链接")
    #expect(
      SearchEngineDetail.kindTitle(engine("a", url: "https://a.com/?q={query}", fallback: true))
        == "搜索 · 没有本地结果时兜底")
    #expect(
      SearchEngineDetail.isPreset("google") && !SearchEngineDetail.isPreset("custom-1a2b3c4d"))
  }

  /// 不碰钥匙串的几种：智谱写模型，自建 AI 缺地址 / 模型；关着的服务缺配置不标橙
  @Test func serviceStatus() {
    var ai = TranslateService.newAI()
    #expect(ai.settingsStatus.text == "未填服务地址" && !ai.settingsStatus.isProblem)
    ai.isEnabled = true
    #expect(ai.settingsStatus == ("未填服务地址", true))
    ai.aiProtocol = .anthropic
    #expect(ai.settingsStatus == ("未填模型", true))
    ai.model = "claude-haiku"
    #expect(ai.settingsStatus == ("Anthropic · claude-haiku", false))
    #expect(TranslateService.zhipu.settingsStatus == ("glm-4-flash", false))
  }

  /// 有序列表有几行就多高、不封顶（2026-10-03）：分组表单里嵌的 List 系统不让滚，封顶之后的行看不到也够不着。
  /// 真的翻译页放 14 个自建 AI 服务（本机地址：行的状态不读钥匙串、不取官网图标），滚到底让行真的排出来：
  /// 列表的表格和它的外框一样高、最后一行正好到底——行高和 OrderedList.rowHeight 对不上时最后几行会被外框裁掉。
  /// 屏外无边框窗口，不抢键盘
  @Test func orderedListShowsEveryRow() throws {
    #expect(OrderedList.height(rows: 0) == OrderedList.rowHeight)
    #expect(OrderedList.height(rows: 14) == 14 * OrderedList.rowHeight)
    let navigation = SettingsNavigation(defaults: nil)
    navigation.page = .translate
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let services = TranslateServiceStore(
      services: (1...14).map { index in
        var service = TranslateService.newAI()
        service.name = "服务 \(index)"
        service.baseURL = "http://127.0.0.1:\(8000 + index)/v1"
        service.model = "model-\(index)"
        return service
      })
    let history = try HistoryStore(db: Database(path: ":memory:"))
    let host = NSHostingView(
      rootView: TranslateTab(services: services, history: history, speaker: Speaker())
        .environment(navigation).defaultAppStorage(defaults))
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 590, height: 548), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let settle = { for _ in 0..<5 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    settle()
    func tables(in view: NSView) -> [NSTableView] {
      ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables(in:))
    }
    let table = try #require(tables(in: host).first { $0.numberOfRows == 14 })
    let list = try #require(table.enclosingScrollView)
    let page = try #require(list.enclosingScrollView?.documentView)
    page.scroll(NSPoint(x: 0, y: page.frame.height))
    settle()
    #expect(list.frame.height == 14 * OrderedList.rowHeight)
    #expect(table.frame.height == list.frame.height)
    #expect(table.rect(ofRow: 13).maxY == list.frame.height)
  }

  /// 没存过、存了认不得的值都跟随系统（nil = NSApp.appearance 不设）
  @Test func appearanceName() {
    #expect(AppAppearance.name(for: "system") == nil)
    #expect(AppAppearance.name(for: "light") == .aqua)
    #expect(AppAppearance.name(for: "dark") == .darkAqua)
    #expect(AppAppearance.name(for: nil) == nil)
    #expect(AppAppearance.name(for: "sepia") == nil)
  }

  /// 设置窗侧栏的选中自绘：外面那个表格不画原生高亮（换页后也不会被改回来），原生选中照旧跟着当前页走
  /// （↑↓、VoiceOver 靠它）。屏外无边框窗口，不抢键盘
  @Test func sidebarNativeHighlightIsOff() throws {
    let navigation = SettingsNavigation(defaults: nil)  // 换页不写用户的偏好
    navigation.page = .clipboard
    let host = NSHostingView(
      rootView: SettingsRoot(navigation: navigation, page: { _ in AnyView(EmptyView()) }) {
        AnyView(EmptyView())
      })
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 780, height: 600), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let settle = { for _ in 0..<3 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    settle()
    func table(in view: NSView) -> NSTableView? {
      view as? NSTableView ?? view.subviews.lazy.compactMap(table(in:)).first
    }
    let sidebar = try #require(table(in: host))
    #expect(sidebar.selectionHighlightStyle == .none)
    let before = sidebar.selectedRow
    navigation.page = .about
    settle()
    #expect(sidebar.selectionHighlightStyle == .none)
    #expect(sidebar.selectedRow != before && sidebar.selectedRow >= 0)
  }

  /// 工具栏的「‹ 返回」（SettingsBackButton）：各页上都有（置灰，⌘[ 不响应），推进详情页后还在、标题栏不变高，
  /// ⌘[ 回列表。翻译服务、网页搜索两种真的详情页各推一次（推进走 navigation.path，和点一行一样）；按 SettingsWindow
  /// 的配法建有标题栏的窗口（工具栏桥接要它），放在屏外（OffscreenWindow）、不激活
  @Test(arguments: [SettingsPage.translate, .launcher])
  func backButtonInToolbar(page: SettingsPage) throws {
    let navigation = SettingsNavigation(defaults: nil)
    navigation.page = page
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // 新建的自建 AI 服务：钥匙串里不会有它的条目（详情页读密钥查不到，不会弹钥匙串确认），也不碰用户的服务偏好
    let ai = TranslateService.newAI()
    let services = TranslateServiceStore(services: [ai])
    let (id, title) = page == .translate ? (ai.id, ai.name) : ("google", "Google")
    let hosting = NSHostingController(
      rootView: SettingsRoot(navigation: navigation) { page in
        AnyView(DetailStack(page: page, services: services).defaultAppStorage(defaults))
      } onboarding: {
        AnyView(EmptyView())
      })
    hosting.sceneBridgingOptions = [.title, .toolbars]
    let window = OffscreenWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 780, height: 600))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    #expect(window.screen == nil)  // 没被挪进屏幕里（跑测试时不闪窗口）
    let settle = { for _ in 0..<5 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    let back = {
      window.performKeyEquivalent(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "[",
            charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33)))
    }
    settle()
    #expect(window.toolbar?.items.count == 1)
    let height = window.contentLayoutRect.height
    #expect(try !back())
    navigation.path = [id]
    settle()
    #expect(window.title == title)
    #expect(window.toolbar?.items.count == 1)
    #expect(window.contentLayoutRect.height == height)
    #expect(try back())
    settle()
    #expect(navigation.path.isEmpty)
    #expect(window.title == page.title)
    #expect(window.toolbar?.items.count == 1)
  }

  /// 主菜单「显示 › 返回 ⌘[」（SettingsCommands）：菜单里有；只在设置窗是 key、推进了详情页时能退，
  /// 状态过期时再按也不崩；换页清空推进的详情页
  @Test func backMenuCommand() throws {
    let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
    let item = try #require(items.first { $0.title == "返回" })
    #expect(item.keyEquivalent == "[" && item.keyEquivalentModifierMask == .command)
    let navigation = SettingsNavigation(defaults: nil)
    navigation.page = .translate
    navigation.path = ["zhipu"]
    #expect(!navigation.canGoBack)  // 设置窗不是 key（开着 sheet、别的面板在前）
    navigation.goBack()
    #expect(navigation.path == ["zhipu"])
    navigation.isKey = true
    #expect(navigation.canGoBack)
    navigation.goBack()
    #expect(navigation.path.isEmpty && !navigation.canGoBack)
    navigation.goBack()  // 过期的可用状态：空路径再退一次不崩
    navigation.path = ["google"]
    navigation.page = .launcher
    #expect(navigation.path.isEmpty)
  }
}

/// 有标题栏的窗口 orderFront 时 AppKit 会把它挪回屏幕里（无边框的不会）：测试里不让挪，留在屏外
private final class OffscreenWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// 和 TranslateTab / LauncherTab 同样的结构：页头 + 表单包在 NavigationStack(path: navigation.path) 里，推进真的
/// TranslateServiceDetail / SearchEngineDetail。不用真页面：启动器页一出现就按用户的真实偏好读受保护的文件夹，
/// 翻译页的服务行读钥匙串，重置过授权、换过签名时会弹系统框把测试卡住（这个单测每次都跑）
private struct DetailStack: View {
  let page: SettingsPage
  let services: TranslateServiceStore
  @Environment(SettingsNavigation.self) private var navigation

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: page)
        Form { Text(verbatim: "list") }.formStyle(.grouped)
      }
      .navigationTitle(page.title)
      .navigationDestination(for: String.self) { id in
        if page == .translate {
          TranslateServiceDetail(store: services, id: id)
        } else {
          SearchEngineDetail(id: id)
        }
      }
    }
  }
}
