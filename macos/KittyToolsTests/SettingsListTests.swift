// 设置里有序列表（N12）的单测：网页搜索一条的问题提示（名称、网址、保留 / 重复关键词（只算搜索之间）、用不上）、
// 列表 JSON 读写（关键词去空白）、预置判断（删自定义的要确认）、翻译服务状态副标题（开着才标橙）；
// 另有通用页的外观偏好 → NSAppearance 名字、设置窗侧栏不画原生选中高亮（自绘那块才是选中）、工具栏的「‹ 返回」和主菜单「显示 › 返回」。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct SettingsListTests {
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
    let navigation = SettingsNavigation()
    let saved = navigation.page
    defer { navigation.page = saved }  // 别把测试摆的页写进偏好
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
    let navigation = SettingsNavigation()
    let saved = navigation.page
    defer { navigation.page = saved }
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
    let navigation = SettingsNavigation()
    let saved = navigation.page
    defer { navigation.page = saved }
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
