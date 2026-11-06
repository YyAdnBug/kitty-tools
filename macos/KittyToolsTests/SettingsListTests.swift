// 设置里有序列表（N12）的单测：网页搜索一条的问题提示（名称、网址、保留 / 重复关键词（只算搜索之间）、用不上）、
// 列表 JSON 读写（关键词去空白）、预置判断（删自定义的要确认）、翻译服务状态副标题（开着才标橙）、
// 列表有几行就多高（不封顶，每一行都在外框里）；
// 另有通用页的外观偏好 → NSAppearance 名字、设置窗侧栏不画原生选中高亮（自绘那块才是选中）、工具栏的「‹ 返回」和主菜单「显示 › 返回」；
// 欢迎引导没走完时下次从哪一屏接着开、什么时候算走完（第四轮体检 E1）。

import AppKit
import ServiceManagement
import SwiftUI
import Testing

@testable import KittyTools

struct SettingsListTests {
  /// 侧栏顺序和菜单栏、快捷键页、引导同序：翻译在截图前面（体检 B51），录制紧跟截图（2026-10-03 拆出来），
  /// 便签、状态屏排在录制后面（状态屏 Z11，便签 2026-10-12；两页的先后同快捷键页的分节）；
  /// 启动台（第八族，2026-10-18）排在便签后面、状态屏前面（F38；和菜单栏、快捷键页同序）；
  /// 程序坞预览（第九族，2026-10-22）排在状态屏后面（它没有快捷键、菜单栏里没有它，拍板 D1）
  @Test func sidebarOrderMatchesMenu() {
    let pages = SettingsPage.allCases
    #expect(
      pages == [
        .general, .clipboard, .launcher, .translate, .screenshot, .record, .notes, .launchpad,
        .statusScreen, .dockPreview, .hotkeys, .about,
      ])
    let sections = HotKeyAction.sections.map(\.title)
    #expect(sections.firstIndex(of: "翻译")! < sections.firstIndex(of: "截图与录制")!)
    // 侧栏分组（0.7.2 从功能管理搬来）：盖住每一页、不重复
    let grouped = SettingsPage.groups.flatMap { $0 }
    #expect(grouped.count == pages.count && Set(grouped) == Set(pages))
    // 没有启动台（macOS 15）时那一组只剩程序坞预览；搜索只剩一组里的页时别的组不画
    #expect(
      SettingsPage.sidebar(SettingsPage.visible(launchpad: false), off: []).map(\.pages)
        == [
          [.general], [.clipboard, .launcher, .translate], [.screenshot, .record],
          [.notes, .statusScreen], [.dockPreview], [.hotkeys, .about],
        ])
    #expect(
      SettingsPage.sidebar([.statusScreen, .about], off: []).map(\.pages) == [
        [.statusScreen], [.about],
      ])
    // 关着的功能挪进最底下「已关闭（N）」那组（照侧栏顺序）；整组都关了的组不画；组的标题不因为头一页挪走而丢
    let closed = SettingsPage.sidebar(
      SettingsPage.allCases, off: [.notes, .dockPreview, .launchpad, .record])
    #expect(
      closed.map(\.pages) == [
        [.general], [.clipboard, .launcher, .translate], [.screenshot], [.statusScreen],
        [.hotkeys, .about], [.record, .notes, .launchpad, .dockPreview],
      ])
    #expect(closed.map(\.title) == [nil, "文字与搜索", "截图与录制", "便签与状态屏", nil, "已关闭（4）"])
    #expect(closed.map(\.isOff) == [false, false, false, false, false, true])
    #expect(Set(closed.map(\.id)).count == closed.count)
    // 搜索时只剩对上的：关着的那页照样在「已关闭」里
    #expect(SettingsPage.sidebar([.notes], off: [.notes]).map(\.title) == ["已关闭（1）"])
    // 组标题：一组里的页同一个标题；功能那四组有，一头一尾两组没有
    for group in SettingsPage.groups {
      #expect(Set(group.map(\.groupTitle)).count == 1, "\(group)")
    }
    #expect(
      SettingsPage.groups.map(\.first?.groupTitle) == [
        nil, "文字与搜索", "截图与录制", "便签与状态屏", "桌面", nil,
      ])
    // 功能页对得上功能，通用 / 快捷键 / 关于不是功能
    #expect(Set(pages.compactMap(\.feature)) == Set(Feature.allCases))
    #expect(SettingsPage.general.feature == nil && SettingsPage.hotkeys.feature == nil)
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
    // 「文件夹」：通用页（同步文件夹、数据目录，第四轮体检 U13）和截图页的保存文件夹都有（启动台页改叫「App 文件夹」，
    // F38），按侧栏顺序停在通用；当前页是截图时不动
    #expect(SettingsPage.page(for: "文件夹", current: .about) == .general)
    #expect(SettingsPage.page(for: "文件夹", current: .screenshot) == .screenshot)
    #expect(SettingsPage.page(for: "数据目录", current: .about) == .general)
    #expect(SettingsPage.page(for: "App 文件夹", current: .about) == .launchpad)
    // 「状态」也是通用页「状态栏」里的字：搜它停在状态屏；状态屏页里各项的叫法搜得到
    #expect(SettingsPage.page(for: "状态", current: .general) == .statusScreen)
    for word in ["清洁", "请勿触碰", "告示", "退出", "屏幕常亮"] {
      #expect(SettingsPage.statusScreen.matches(word), "\(word)")
    }
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

  /// 智谱写模型，自建 AI 缺地址 / Key / 模型；关着的服务缺配置不标橙。只读钥匙串（新建的服务没有 Key）
  @Test func serviceStatus() {
    var ai = TranslateService.newAI()
    #expect(ai.settingsStatus.text == "未填服务地址" && !ai.settingsStatus.isProblem)
    ai.isEnabled = true
    #expect(ai.settingsStatus == ("未填服务地址", true))
    ai.aiProtocol = .anthropic
    // 空地址 = 官方接口，没填 Key（第四轮体检 E20）；本机地址不要 Key，接着才是缺模型
    #expect(ai.settingsStatus == ("未填 API Key", true))
    ai.baseURL = "http://127.0.0.1:8080"
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

  /// 引导没走完就退出、下次接着开（E1）：做到第三屏的回第三屏；停在授权那一屏的，两项都授权了直接第三屏、还缺的回第二屏；
  /// 只看过第一屏 / 没记录的从头来
  @Test func onboardingResumesWhereItStopped() {
    typealias Screen = OnboardingView.Screen
    #expect(OnboardingView.resume(reached: nil, granted: true) == .welcome)
    #expect(OnboardingView.resume(reached: .welcome, granted: true) == .welcome)
    #expect(OnboardingView.resume(reached: .permissions, granted: true) == .tryIt)
    #expect(OnboardingView.resume(reached: .permissions, granted: false) == .permissions)
    #expect(OnboardingView.resume(reached: .tryIt, granted: false) == .tryIt)
    #expect(Screen.welcome < .permissions && Screen.permissions < .tryIt)
    // 偏好里存的就是 rawValue：认得出来
    #expect(Screen(rawValue: Screen.tryIt.rawValue) == .tryIt && Screen(rawValue: 9) == nil)
  }

  /// 点「开始使用」时登录项怎么改（E1）：动过勾选框才照它来（重看时状态是「要批准」、勾选框显示没勾，没动它不取消注册）；
  /// 没动过的只有首次安装勾着、还没注册的再注册一次
  @Test func onboardingOnlyChangesLoginItemWhenTouched() {
    func change(_ touched: Bool, _ checked: Bool, _ firstRun: Bool, _ status: SMAppService.Status)
      -> Bool?
    {
      OnboardingView.loginChange(
        touched: touched, checked: checked, firstRun: firstRun, status: status)
    }
    #expect(change(false, false, false, .requiresApproval) == nil)
    #expect(change(false, true, false, .enabled) == nil)
    #expect(change(false, true, true, .enabled) == nil)
    #expect(change(false, true, true, .notRegistered) == true)
    #expect(change(false, true, false, .notRegistered) == nil)
    #expect(change(true, false, true, .enabled) == false)
    #expect(change(true, false, false, .requiresApproval) == false)
    #expect(change(true, false, false, .notRegistered) == nil)
    #expect(change(true, true, false, .requiresApproval) == true)
    #expect(change(true, true, false, .enabled) == nil)
  }

  /// 从 0.7.1 之前升上来的：「请求过」的标记补成 true（系统框多半早弹过，不补的话第一次点「去授权」什么都不出，U10）；
  /// 写过的不动；新装的（上次看过的已经是有标记的版本）不补——它们第一次点该弹系统框
  @Test func upgradesAdoptPermissionRequestFlags() throws {
    let suite = "kitty-permission-flags-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    Permissions.adoptRequestFlags(upgradingFrom: "0.7.1", defaults: defaults)
    #expect(defaults.object(forKey: Prefs.accessibilityRequested) == nil)
    defaults.set(false, forKey: Prefs.screenRecordingRequested)
    Permissions.adoptRequestFlags(upgradingFrom: "0.7.0", defaults: defaults)
    #expect(defaults.bool(forKey: Prefs.accessibilityRequested))
    #expect(defaults.object(forKey: Prefs.screenRecordingRequested) as? Bool == false)
  }

  /// 引导关掉（开始使用、Esc 都是把 showsOnboarding 置回 false）才报「走完了」，只报一次；打开不算（E1）
  @MainActor @Test func onboardingClosedFiresOnceOnDismiss() {
    let navigation = SettingsNavigation(defaults: nil)
    var closed = 0
    navigation.onboardingClosed = { closed += 1 }
    navigation.showsOnboarding = true
    #expect(closed == 0)
    navigation.showsOnboarding = false
    #expect(closed == 1)
    navigation.showsOnboarding = false
    #expect(closed == 1)
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
    let window = OffscreenWindow(
      contentViewController: .windowContent(
        SettingsRoot(navigation: navigation) { page in
          AnyView(DetailStack(page: page, services: services).defaultAppStorage(defaults))
        } onboarding: {
          AnyView(EmptyView())
        }))
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

  /// 详情页的页头和列表页的页头在同一个位置（视觉对齐 E2）：推进详情页时图标和标题原地换、不跳。两种页各画一张，
  /// 量页头色块的外接框——都是左 20、上 14、边长 40（原来详情页的页头放在 Section 的 header 里，是左 30、上 20）。
  /// 详情页用一条路径快捷链接：没有网站图标，色块和通用页的一样是灰的。屏外无边框窗口，临时偏好域
  @Test func detailHeaderSitsWherePageHeaderDoes() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      SearchEngineDetail.encode([
        SearchEngine(
          id: "downloads", name: "下载", keyword: "", urlTemplate: "~/Downloads", enabled: false)
      ]), forKey: Prefs.launcherWebSearchEngines)
    /// 左上角 64 × 56 pt 里（页头的文字从 72 起、第一组卡片从 76 起）和背景不一样的像素的外接框
    func tile(of view: some View) throws -> CGRect {
      let size = NSSize(width: 590, height: 400)
      let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: .aqua)
      window.contentView = host
      window.orderFront(nil)
      defer { window.orderOut(nil) }
      for _ in 0..<3 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) }
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let scale = CGFloat(bitmap.pixelsWide) / size.width
      let components = { (x: Int, y: Int) -> [CGFloat] in
        let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        return color.map {
          [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent]
        }
          ?? [0, 0, 0, 0]
      }
      let base = components(1, 1)
      var box = CGRect.null
      for y in 0..<Int(56 * scale) {
        for x in 0..<Int(64 * scale)
        where zip(components(x, y), base).map({ abs($0 - $1) }).reduce(0, +) > 0.25 {
          box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
      return box.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
    }
    let list = try tile(
      of: VStack(spacing: 0) {
        PageHeader(page: .general)
        Form { Text(verbatim: "list") }.formStyle(.grouped)
      })
    let detail = try tile(of: SearchEngineDetail(id: "downloads").defaultAppStorage(defaults))
    #expect(list == CGRect(x: 20, y: 14, width: 40, height: 40))
    #expect(detail == list)
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
