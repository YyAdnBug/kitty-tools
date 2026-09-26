// 启动器单测：匹配分档（含缩写 vsc、拼音）、使用分衰减与加成、排序、旧版使用记录导入映射。

import AppKit
import Testing

@testable import KittyTools

struct LauncherTests {
  private func app(_ title: String, chinese: String? = nil) -> LauncherItem {
    let pinyin = chinese.flatMap(AppCatalog.pinyin)
    return LauncherItem(
      kind: .app, target: "/Applications/\(title).app", title: chinese ?? title, subtitle: "应用程序",
      names: [chinese, title, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) },
      initials: [LauncherMatch.initials(title), pinyin?.initials].compactMap { $0 })
  }

  @Test func pinyinAndInitials() throws {
    let pinyin = try #require(AppCatalog.pinyin("活动监视器"))
    #expect(pinyin.full == "huodongjianshiqi" && pinyin.initials == "hdjsq")
    #expect(AppCatalog.pinyin("Safari") == nil)  // 没有汉字不转
    #expect(LauncherMatch.initials("Visual Studio Code") == "vsc")
    #expect(LauncherMatch.initials("AppCleaner") == "ac")
    #expect(LauncherMatch.initials("WPS Office") == "wo")
  }

  @Test func matchTiers() {
    let code = app("Visual Studio Code")
    let score = { LauncherMatch.score($0, item: code) }
    #expect(score("visual studio code") == 100)
    #expect(score("vis") == 80)  // 名字开头
    #expect(score("stu") == 60)  // 词首
    #expect(score("vsc") == 50)  // 跨词首字母（旧版搜不到）
    #expect(score("dio") == 40)  // 子串
    #expect(score("visual code") == 60)  // 每个词都要命中，取最差的一词
    #expect(score("xyz") == 0)
    #expect(score("visual xyz") == 0)
    let monitor = app("Activity Monitor", chinese: "活动监视器")
    #expect(LauncherMatch.score("活动", item: monitor) == 80)
    #expect(LauncherMatch.score("huodong", item: monitor) == 80)
    #expect(LauncherMatch.score("hdjsq", item: monitor) == 50)
    #expect(LauncherMatch.score("monitor", item: monitor) == 60)
  }

  @Test func systemAppsMatchChineseAndEnglish() {
    // 真实系统 App：显示名是中文，英文缩写要从文件名来（am），中文名 / 拼音也能搜
    let monitor = AppCatalog.item(path: "/System/Applications/Utilities/Activity Monitor.app")
    #expect(monitor.title == "活动监视器" && monitor.subtitle == "Activity Monitor")
    for query in ["am", "activity", "活动", "hdjsq"] {
      #expect(LauncherMatch.score(query, item: monitor) > 0, "\(query)")
    }
  }

  @Test func realScanHasNoDuplicates() {
    // 本机实测过：/Applications/Safari.app 是指向 Cryptexes 的链接，两处都在扫描目录里
    let apps = AppCatalog.scan()
    let resolved = apps.map { URL(filePath: $0.target).resolvingSymlinksInPath().path }
    #expect(Set(resolved).count == resolved.count)
    #expect(apps.contains { $0.target.hasSuffix("/Finder.app") })
  }

  @Test func usageDecaysAndBoosts() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let item = app("iTerm")
    let start = Date(timeIntervalSinceReferenceDate: 0)
    usage.record(item, query: "it", now: start)
    usage.record(
      item, query: " IT ", now: start.addingTimeInterval(LauncherUsage.globalTimeConstant))
    let boost = usage.boost(
      for: item, query: "it", now: start.addingTimeInterval(LauncherUsage.globalTimeConstant))
    // 全局：1 衰减一个时间常数（×1/e）后 +1；查询：3 天常数下 14 天前的那次几乎衰减光
    #expect(abs(boost.global - (1 / M_E + 1)) < 1e-9)
    #expect(abs(boost.query - (1 + exp(-14.0 / 3))) < 1e-9)
    #expect(usage.boost(for: item, query: "other").query == 0)
    // 落库往返
    #expect(usage.entries.count == 2)
  }

  @Test func usageBreaksTiesInRanking() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let chrome = app("Google Chrome")
    let chess = app("Chess")
    usage.record(chess, query: "ch")
    let ranked = LauncherMatch.rank([chrome, chess], query: "ch") {
      usage.boost(for: $0, query: "ch")
    }
    #expect(ranked.map(\.title) == ["Chess", "Google Chrome"])
    // 没用过：同分时标题短的在前
    #expect(
      LauncherMatch.rank([chrome, app("Chroma")], query: "chrom") { _ in (0, 0) }.map(\.title) == [
        "Chroma", "Google Chrome",
      ])
  }

  @Test func legacyUsageMapping() throws {
    let frecency = Data(
      """
      {"items": {
        "open_url::https://linux.do/latest": {"count": 12, "last_ms": 1790000000000},
        "open_url::https://www.google.com/search?q=swift": {"count": 3, "last_ms": 1790000000000},
        "mac_open::Calculator": {"count": 2, "last_ms": 1790000000000},
        "action::clipboard": {"count": 2, "last_ms": 1790000000000},
        "action::dev-tools": {"count": 3, "last_ms": 1790000000000},
        "kill_process::1234": {"count": 1, "last_ms": 1790000000000},
        "open_path::/tmp/a.md": {"count": 1, "last_ms": 1790000000000},
        "open_url::http://10.10.33.176:8089/app/": {"count": 1, "last_ms": 1790000000000},
        "open_url::https://zh.wikipedia.org/wiki/%E8%8B%B9%E6%9E%9C": {"count": 1, "last_ms": 1790000000000},
        "open_path::/System/Applications/Calculator.app": {"count": 3, "last_ms": 1790086400000}
      }}
      """.utf8)
    let affinity = Data(
      """
      {"items": {"li::open_url::https://linux.do/latest": {"count": 4, "last_ms": 1790000000000}}}
      """.utf8)
    let entries = try LegacyImport.launcherEntries(frecency: frecency, affinity: affinity)
    let byTarget = Dictionary(entries.map { ($0.query + "|" + $0.target, $0) }) { a, _ in a }
    #expect(entries.count == 8)  // 丢掉搜索结果页、dev-tools（原生还没有）、结束进程
    #expect(byTarget["|https://linux.do/latest"]?.title == "linux.do/latest")
    #expect(byTarget["|https://linux.do/latest"]?.score == 12)
    #expect(byTarget["li|https://linux.do/latest"]?.kind == .url)
    #expect(entries.contains { $0.kind == .app && $0.target.hasSuffix("/Calculator.app") })
    #expect(entries.contains { $0.kind == .action && $0.target == "clipboard" })
    #expect(entries.contains { $0.kind == .path && $0.title == "a.md" })
    #expect(entries.contains { $0.title == "10.10.33.176:8089/app/" })  // 保留端口
    #expect(entries.contains { $0.title == "zh.wikipedia.org/wiki/苹果" })  // 不显示百分号编码

    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    // mac_open::Calculator 与 open_path 的计算器落到同一行：分数合并（2 衰减一天后 + 3），不随机丢一条
    #expect(try usage.importLegacy(entries) == 7)
    let calculator = try #require(
      usage.entries.values.first { $0.target.hasSuffix("/Calculator.app") })
    #expect(abs(calculator.score - (3 + 2 * exp(-1.0 / 14))) < 1e-9)
    #expect(try usage.importLegacy(entries) == 0)  // 重复导入不叠加
  }

  @Test func directURLsAndPaths() {
    let url = { DirectItems.url(from: $0)?.absoluteString }
    #expect(url("https://a.com/x") == "https://a.com/x")
    #expect(url("linux.do") == "https://linux.do")
    #expect(url("ui.shadcn.com/docs") == "https://ui.shadcn.com/docs")
    #expect(url("localhost:3000") == "http://localhost:3000")  // 旧版不认
    #expect(url("10.10.33.176:8089/app") == "http://10.10.33.176:8089/app")
    #expect(url("www.example.app") == "https://www.example.app")
    #expect(url("Safari.app") == nil)  // 旧版当成网址
    #expect(url("file.txt") == nil)
    #expect(url("install.sh") == nil)  // 常见文件扩展名不当域名后缀
    #expect(url("hello world.com") == nil)
    #expect(url("1.2.3") == nil)
    #expect(DirectItems.existingPath(from: "~") == NSHomeDirectory())
    #expect(DirectItems.existingPath(from: "/tmp") == "/tmp")
    #expect(DirectItems.existingPath(from: "./tmp") == nil)  // 不认相对路径
    #expect(DirectItems.existingPath(from: "/no/such/path") == nil)
  }

  @Test func calculator() {
    let value = { Calculator.evaluate($0) }
    #expect(value("1+2*3") == 7)
    #expect(value("(1+2)*3") == 9)
    #expect(value("2^3^2") == 512)  // 幂右结合
    #expect(value("2**10") == 1024)
    #expect(value("-2^2") == -4)
    #expect(value("10%3") == 1)
    #expect(value("sqrt(16)+abs(-1)") == 5)
    #expect(value("0x10+0b11") == 19)
    #expect(value("1/0") == nil)
    #expect(value("1+") == nil)
    #expect(value("sqrt(") == nil)  // 半截表达式不能崩
    #expect(Calculator.format(0.1 + 0.2) == "0.3")
    #expect(Calculator.format(2 * .pi) == "6.28318530718")
    #expect(Calculator.format(pow(2, 53)) == "9007199254740992")  // 能精确表示的整数原样
    #expect(Calculator.format(pow(2, 60)).contains("E"))  // 更大的用科学计数，不显示成补 0 的「精确」整数
    #expect(Calculator.item(for: "1+2")?.payload == "3")
    // Tab 写回的科学计数要能接着算；单独的 e 仍是常数
    #expect(Calculator.evaluate("1.15292150461e18*2") == 2.30584300922e18)
    #expect(Calculator.evaluate("9e-3+1") == 1.009)
    #expect(Calculator.evaluate("2*e") == 2 * M_E)
    #expect(Calculator.item(for: "2024-01-01") == nil)  // 日期不当算式
    #expect(Calculator.item(for: "abc") == nil)
    #expect(Calculator.item(for: "12") == nil)
  }

  @Test func webSearch() throws {
    let engines = [
      SearchEngine(
        id: "g", name: "Google", keyword: "g", urlTemplate: "https://g.com/?q={query}",
        enabled: true),
      SearchEngine(
        id: "b", name: "Bing", keyword: "", urlTemplate: "https://b.com/?q={query}", enabled: true),
      SearchEngine(
        id: "x", name: "Off", keyword: "", urlTemplate: "https://x.com/?q={query}", enabled: false),
    ]
    let keyword = try #require(WebSearch.keywordItem(for: "g c++ 教程", engines: engines))
    #expect(
      keyword.kind == .search && keyword.target == "https://g.com/?q=c%2B%2B%20%E6%95%99%E7%A8%8B")
    #expect(WebSearch.keywordItem(for: "g", engines: engines) == nil)  // 关键词后面要有内容
    // 关键词直达不看「兜底」开关
    let keywordOnly = [
      SearchEngine(
        id: "gh", name: "GitHub", keyword: "gh", urlTemplate: "https://github.com/search?q={query}",
        enabled: false)
    ]
    #expect(WebSearch.keywordItem(for: "gh swift", engines: keywordOnly) != nil)
    #expect(WebSearch.fallbackItems(for: "swift", engines: keywordOnly).isEmpty)
    let fallback = WebSearch.fallbackItems(for: "swift", engines: engines)
    #expect(fallback.map(\.target) == ["https://g.com/?q=swift", "https://b.com/?q=swift"])
    #expect(fallback.first?.completion == "g swift")  // Tab 补成「关键词 内容」，没关键词的不补
    #expect(fallback.last?.completion == nil)
    #expect(WebSearch.primary(in: engines)?.id == "g")
    #expect(WebSearch.fallbackItems(for: "s", engines: engines).isEmpty)
    #expect(!LauncherItem.Kind.search.isRecorded)  // 搜索页不记使用
  }

  @Test func quicklinksAndPrompts() throws {
    let engines = [
      SearchEngine(
        id: "docs", name: "苹果文档", keyword: "ad",
        urlTemplate: "https://developer.apple.com/documentation",
        enabled: true),
      SearchEngine(id: "notes", name: "笔记", keyword: "", urlTemplate: "~/Notes", enabled: false),
      SearchEngine(
        id: "gh", name: "GitHub", keyword: "gh", urlTemplate: "https://github.com/search?q={query}",
        enabled: false),
      SearchEngine(
        id: "nokw", name: "无关键词", keyword: "", urlTemplate: "https://x.com/?q={query}",
        enabled: true),
    ]
    let items = WebSearch.quicklinkItems(engines: engines)
    // 没有 {query} 的是快捷链接：网址记成 .url（记使用、进「最近使用」），路径展开 ~
    #expect(items.count == 2)
    #expect(items[0].kind == .url && items[0].target == "https://developer.apple.com/documentation")
    #expect(items[0].names.contains("pingguowendang") && items[0].names.contains("ad"))
    #expect(
      items[1].kind == .path && items[1].target.hasSuffix("/Notes")
        && !items[1].target.hasPrefix("~"))
    // 有关键词的搜索出一条提示，↩ / Tab 补「关键词 」：正好是关键词时排最前，名字开头时排本地结果后面
    let exact = WebSearch.promptItems(for: "gh", engines: engines)
    #expect(exact.exact.map(\.completion) == ["gh "] && exact.partial.isEmpty)
    let partial = WebSearch.promptItems(for: "git", engines: engines)
    #expect(partial.exact.isEmpty && partial.partial.first?.kind == .prompt)
    #expect(WebSearch.promptItems(for: "x", engines: engines).partial.isEmpty)  // 一个字不出
    #expect(!LauncherItem.Kind.prompt.isRecorded)
    // 快捷链接不参与关键词直达和兜底，勾了「兜底」也不算
    #expect(WebSearch.keywordItem(for: "ad swift", engines: engines) == nil)
    #expect(
      WebSearch.fallbackItems(for: "swift", engines: engines).map(\.title) == ["用 无关键词 搜索「swift」"])
    #expect(WebSearch.primary(in: engines)?.id == "nokw")
    // 预置里的关键词互不重复，网址都是搜索
    #expect(Set(WebSearch.presets.map(\.keyword)).count == WebSearch.presets.count)
    #expect(WebSearch.presets.allSatisfy { !$0.isQuicklink })
  }

  @Test func tabCompletionAndAlternates() throws {
    let calculation = try #require(Calculator.item(for: "12*3+1"))
    #expect(LauncherModel.completion(for: calculation) == "37")  // 结果写回输入框接着算
    let directory = LauncherItem(
      kind: .path, target: "/System/Library", title: "Library", subtitle: "")
    #expect(LauncherModel.completion(for: directory) == "/System/Library/")
    let file = LauncherItem(
      kind: .path, target: "/System/Library/CoreServices/SystemVersion.plist", title: "",
      subtitle: "")
    #expect(
      LauncherModel.completion(for: file) == "/System/Library/CoreServices/SystemVersion.plist")
    let app = AppCatalog.item(path: "/System/Applications/Calculator.app")
    #expect(LauncherModel.completion(for: app) == app.title)
    // 输入的网址 Tab 保留原样（显示名去掉了协议和查询串）
    let typed = try #require(DirectItems.items(for: "localhost:3000/api?x=1").first)
    #expect(LauncherModel.completion(for: typed) == "localhost:3000/api?x=1")
    #expect(
      LauncherModel.completion(
        for: LauncherItem(kind: .clip, target: "x", title: "t", subtitle: ""))
        == nil)
    // 按住修饰键时选中行的副标题
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [app])
    model.query = "swift ui"
    model.alternate = .option
    #expect(model.alternateSubtitle(for: app) == "⌥↩ 在访达里搜索「swift ui」")
    model.alternate = .command
    #expect(model.alternateSubtitle(for: app) == "⌘↩ 在访达中显示")
    #expect(model.alternateSubtitle(for: calculation) == "⌘↩ 只复制，不粘贴")
    model.alternate = .none
    #expect(model.alternateSubtitle(for: app) == nil)
  }

  @Test func moveOutsideKeyEventDoesNotThrow() throws {
    // 回归：当前事件不是按键（鼠标悬停、KitDefined）时问 isARepeat 会抛异常，整个测试进程卡死
    let event = try #require(
      NSEvent.otherEvent(
        with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
    NSApp.postEvent(event, atStart: true)
    _ = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
    #expect(NSApp.currentEvent?.type == .applicationDefined)
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")),
      apps: [app("Safari"), app("Slack")])
    model.query = "s"
    #expect(model.handleCommand(#selector(NSResponder.moveDown(_:))))
    #expect(model.selection == 1 && model.selectionMotion == .snap)
  }

  @Test func forgetAndClearUsage() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let app = LauncherItem(kind: .app, target: "/Applications/A.app", title: "A", subtitle: "")
    let other = LauncherItem(kind: .url, target: "https://b.com", title: "B", subtitle: "")
    usage.record(app, query: "a")
    usage.record(other, query: "")
    #expect(usage.entries.count == 3)  // A 的全局 + 查询「a」，B 的全局
    usage.forget(app)
    #expect(usage.entries.values.map(\.target) == ["https://b.com"])
    usage.clearAll()
    #expect(usage.entries.isEmpty && usage.top(10).isEmpty)
  }

  /// 新版 Chrome 登录账号后书签存在 AccountBookmarks，本机的 Bookmarks 是空的：两个都要读（锁住「搜不到书签」）
  @Test func readsAccountBookmarks() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ file: String, _ urls: [String]) throws {
      let children = urls.map { "{\"type\": \"url\", \"name\": \"x\", \"url\": \"\($0)\"}" }
      let json =
        "{\"roots\": {\"bookmark_bar\": {\"type\": \"folder\", \"children\": [\(children.joined(separator: ","))]}}}"
      let url = root.appending(path: file)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(json.utf8).write(to: url)
    }
    try write("Default/Bookmarks", [])
    try write("Default/AccountBookmarks", ["https://github.com/"])
    try write("Profile 1/AccountBookmarks", ["https://developer.apple.com/"])
    try write("System Profile/AccountBookmarks", ["https://ignored.example/"])
    let urls = Bookmarks.profileFiles(in: root).compactMap { try? Data(contentsOf: $0) }
      .flatMap(Bookmarks.parse).map(\.url)
    #expect(urls == ["https://github.com/", "https://developer.apple.com/"])
  }

  @Test func bookmarksAndClipCommand() {
    let json = Data(
      """
      {"roots": {
        "bookmark_bar": {"type": "folder", "children": [
          {"type": "url", "name": "shadcn/ui", "url": "https://ui.shadcn.com/Docs"},
          {"type": "folder", "children": [{"type": "url", "name": "内网", "url": "http://10.0.0.1/"}]},
          {"type": "url", "name": "js", "url": "javascript:alert(1)"}
        ]},
        "other": {"type": "folder", "children": []}
      }}
      """.utf8)
    #expect(Bookmarks.parse(json).map(\.url) == ["https://ui.shadcn.com/Docs", "http://10.0.0.1/"])
    #expect(LauncherModel.clipQuery("cb") == "")
    #expect(LauncherModel.clipQuery("cb  token") == "token")
    #expect(LauncherModel.clipQuery("cbx") == nil)
    // 旧版把网址转成了小写：书签里有原样的就还原
    let frecency = Data(
      #"{"items": {"open_url::https://ui.shadcn.com/docs": {"count": 2, "last_ms": 1790000000000}}}"#
        .utf8)
    let entries = try? LegacyImport.launcherEntries(
      frecency: frecency, affinity: nil, bookmarkURLs: ["https://ui.shadcn.com/Docs"])
    #expect(entries?.first?.target == "https://ui.shadcn.com/Docs")
  }
}
