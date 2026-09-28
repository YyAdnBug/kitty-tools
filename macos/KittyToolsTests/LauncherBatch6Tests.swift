// 体检第 6 批（启动器·新功能）单测：计算器的单位换算 / 进制 / 千分位（D11）、kill 进程与端口（D12）、系统设置面板（D9）、
// 网站图标（D6：Chrome Favicons 库的查法）、浏览历史（D8：sqlite3 导出、解析、排在书签后）。
// 全部用内存库、临时目录里的假库、注入的进程列表 / 历史 / perform，不读写用户偏好和剪贴板、不读真 Chrome 数据、
// 不结束任何进程。

import AppKit
import Testing

@testable import KittyTools

struct LauncherBatch6Tests {
  private func model(apps: [LauncherItem] = []) throws -> (LauncherModel, LauncherUsage) {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    return (LauncherModel(usage: usage, apps: apps), usage)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "kitty-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: D11 计算器

  @Test func unitConversions() {
    let result = { Calculator.result(for: $0) }
    let km = result("10 km to mi")
    #expect(km?.display == "6.2137 mi" && km?.payload == "6.2137 mi")
    #expect(km?.copies == [.init(title: "复制原始数字", text: "6.2137")])
    #expect(result("30 摄氏度 转 华氏度")?.display == "86 °F")
    #expect(result("30摄氏度转华氏度")?.display == "86 °F")  // 中文不带空格
    #expect(result("100°F in C")?.display == "37.7778 °C")
    #expect(result("1.5GB in MB")?.display == "1,500 MB")
    #expect(result("1.5GB in MB")?.payload == "1500 MB")  // 粘贴 / 写回的不分组
    #expect(result("1 斤 = g")?.display == "500 g")
    #expect(result("2 hours to min")?.display == "120 min")
    #expect(result("1 亩 to m2")?.display == "666.6667 m²")
    #expect(result("60 km/h to m/s")?.display == "16.6667 m/s")
    #expect(result("1 lb to kg")?.display == "0.453592 kg")  // 小于 1 的留 6 位有效数字
    #expect(result("8 fl oz to ml")?.display == "236.588 mL")  // 系统的液盎司取 29.5735 mL
    #expect(result("10 in to cm")?.display == "25.4 cm")  // in 既是英寸又是分隔词
    #expect(result("5 min to s")?.display == "300 s")
    // 不同类的量、不认识的单位、不是换算的：都不算
    #expect(result("10 km to kg") == nil)
    #expect(result("10 foo to bar") == nil)
    #expect(Calculator.item(for: "3 to 5") == nil)
    // 卡片：算式那一栏是原文，大字是结果
    let item = Calculator.item(for: "10 km to mi")
    #expect(item?.target == "10 km to mi" && item?.title == "6.2137 mi")
    #expect(LauncherModel.completion(for: item!) == "6.2137 mi")
  }

  @Test func radixAndGrouping() {
    let result = { Calculator.result(for: $0) }
    let hex = result("255 in hex")
    #expect(hex?.display == "0xFF" && hex?.payload == "0xFF")
    #expect(
      hex?.copies == [
        .init(title: "复制十进制", text: "255"), .init(title: "复制二进制", text: "0b11111111"),
      ])
    #expect(result("0xff in dec")?.display == "255")
    #expect(result("255 转 二进制")?.payload == "0b11111111")
    #expect(result("8 in oct")?.payload == "0o10")
    #expect(result("-255 in hex")?.payload == "-0xFF")
    #expect(result("0x10+1 in bin")?.payload == "0b10001")  // 左边可以是算式
    #expect(result("2.5 in hex") == nil)  // 不是整数
    // 写回输入框的还能接着算
    #expect(Calculator.evaluate("0xFF") == 255)
    #expect(Calculator.evaluate("0o17") == 15)
    #expect(Calculator.evaluate("-0b101") == -5)
    // 输入里有 0x / 0b：⌘K 多「复制十六进制 / 二进制」；单独一个字面量也出十进制
    let sum = result("0xff+1")
    #expect(sum?.display == "256")
    #expect(sum?.copies.map(\.text) == ["0x100", "0b100000000"])
    #expect(Calculator.item(for: "0xff")?.title == "255")
    // 千分位：大字分组，粘贴的不分组，⌘K「复制原始数字」
    let big = Calculator.item(for: "1234567*3")
    #expect(big?.title == "3,703,701" && big?.payload == "3703701")
    #expect(result("1234567*3")?.copies == [.init(title: "复制原始数字", text: "3703701")])
    #expect(result("1+2")?.copies == [])  // 分不分组一样时不多这一行
    #expect(Calculator.format(1234.5, grouped: true) == "1,234.5")
    #expect(Calculator.format(pow(2, 60), grouped: true).contains("E"))
  }

  @Test func calculationActionsListExtraCopies() throws {
    let (model, _) = try model()
    model.query = "10 km to mi"
    #expect(model.selectedItem?.kind == .calculation)
    #expect(model.actions.contains { $0.title == "复制原始数字" && $0.detail == "6.2137" })
    model.query = "255 in hex"
    #expect(model.actions.map(\.title).contains("复制二进制"))
  }

  // MARK: D12 kill

  @Test func parsesPsAndLsof() {
    let own = ProcessInfo.processInfo.processIdentifier
    let ps = """
        412     1  10240 /usr/libexec/remindd
       4321  4300 319488 /opt/homebrew/Cellar/node/22.1.0/bin/node
       5000  4999   2048 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
       6001 \(own)   1600 ps
        160     1  40000 /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow
      garbage line
      """
    let entries = Processes.parse(ps: ps)
    #expect(entries.map(\.pid) == [412, 4321, 5000, 6001, 160])
    #expect(entries[1].memory == 319_488 * 1024 && entries[1].name == "node")
    #expect(entries[1].ppid == 4300)
    #expect(entries[2].name == "Google Chrome Helper (Renderer)")  // 路径里有空格
    #expect(entries[0].isSystem && !entries[1].isSystem)
    let lsof = """
      p4321
      f23
      n*:3000
      f24
      n[::1]:3000
      f25
      n127.0.0.1:9229
      p77
      f5
      n*:5432
      """
    #expect(Processes.parse(lsof: lsof) == [4321: [3000, 9229], 77: [5432]])
    // 行：监听端口的排前面，再是不在系统目录里的，再按内存；普通 App、本 App、本 App 起的 ps、loginwindow 不列
    let items = Processes.items(entries, ports: Processes.parse(lsof: lsof), excluding: [5000])
    #expect(items.map(\.target) == ["4321", "412"])
    #expect(items[0].title == "node" && items[0].kind == .process)
    #expect(
      items[0].subtitle.hasPrefix("PID 4321 · ") && items[0].subtitle.hasSuffix(" · 监听 :3000、:9229")
    )
    #expect(items[0].names.contains(":3000") && items[0].names.contains("4321"))
    #expect(items[1].subtitle.components(separatedBy: " · ").count == 2)  // 不监听的没有端口那一段
  }

  @Test func killListsProcessesAndSignals() async throws {
    let (model, usage) = try model()
    let entries = [
      Processes.Entry(pid: 4321, memory: 300 << 20, path: "/opt/homebrew/bin/node"),
      Processes.Entry(pid: 88, memory: 20 << 20, path: "/usr/local/bin/python3"),
      // 进程名里带冒号、没在监听：「kill :」不列它
      Processes.Entry(pid: 1500, memory: 1 << 20, path: "postgres: walwriter"),
    ]
    var listed = 0
    var performed: [SystemControl.Action] = []
    var hides = 0
    model.processTargets = {
      listed += 1
      return Processes.items(entries, ports: [4321: [3000]], excluding: [])
    }
    model.perform = { performed.append($0) }
    model.hidePanel = { hides += 1 }
    // 只输 kill：补全提示；kill 是保留关键词
    model.query = "kill"
    #expect(model.results.first?.target == "system-kill")
    #expect(WebSearch.reservedKeywords["kill"] != nil)
    // kill 空格：先写「正在读取进程…」，列完换上；分组标题「后台进程」
    model.query = "kill "
    #expect(model.results.isEmpty && model.emptyText == "正在读取进程…")
    await model.processLookup()
    #expect(
      model.results.map(\.title) == ["node", "python3", "postgres: walwriter"]
        && model.groupTitle == "后台进程")
    // 打字只过滤、不重列；:端口、PID 都能搜
    model.query = "kill :3000"
    #expect(model.results.map(\.title) == ["node"])
    model.query = "kill :"
    #expect(model.results.map(\.title) == ["node"])
    model.query = "kill 88"
    #expect(model.results.map(\.title) == ["python3"])
    model.query = "kill :8080"
    #expect(model.results.isEmpty && model.emptyText == "没有进程在监听这个端口")
    #expect(listed == 1)
    // ↩ 结束（SIGTERM，不确认）
    model.query = "kill no"
    let node = try #require(model.selectedItem)
    #expect(model.primaryAction(for: node).title == "结束")
    #expect(model.commandReturnAction(for: node)?.title == "强制结束")
    #expect(model.copyTitle(for: node) == nil && !model.canFavorite(node))
    model.execute(node)
    #expect(performed == [.signal(pid: 4321, name: "node", force: false)] && hides == 1)
    #expect(usage.entries.isEmpty)  // 不记使用
    // ⌘↩ 强制结束（SIGKILL）：先上膛，再按一次才发
    model.query = "kill py"
    await model.processLookup()
    let python = try #require(model.selectedItem)
    model.commandReturn(python)
    #expect(performed.count == 1 && model.isArmed(python))
    #expect(model.alternateSubtitle(for: python) == SystemCommands.killConfirmation)
    #expect(model.commandReturnAction(for: python)?.title == "确认强制结束")
    model.commandReturn(python)
    #expect(performed.last == .signal(pid: 88, name: "python3", force: true) && hides == 2)
  }

  /// 收起时还没列完的丢掉：再呼出重列（这期间进程可能结束了）
  @Test func killListIsRedoneAfterHiding() async throws {
    let (model, _) = try model()
    var listed = 0
    model.processTargets = {
      listed += 1
      return []
    }
    model.query = "kill "
    await model.processLookup()
    #expect(listed == 1 && model.emptyText == "没有后台进程")
    model.didHide()  // 没执行就收起：留着查询
    model.prepareForShow()
    await model.processLookup()
    #expect(model.query == "kill " && listed == 2)
  }

  // MARK: D9 系统设置面板

  @Test func systemSettingsPanes() throws {
    let panes = AppCatalog.settingsPanes()
    let bluetooth = try #require(panes.first { $0.title == "蓝牙" })
    #expect(bluetooth.target == "x-apple.systempreferences:com.apple.BluetoothSettings")
    #expect(bluetooth.kind == .url && bluetooth.subtitle == "系统设置")
    for query in ["蓝牙", "lanya", "bluetooth", "ly"] {
      #expect(LauncherMatch.score(query, item: bluetooth) > 0, "\(query)")
    }
    let wifi = try #require(
      panes.first { $0.target.hasSuffix("com.apple.wifi-settings-extension") })
    #expect(LauncherMatch.score("wifi", item: wifi) > 0)
    #expect(panes.contains { $0.title == "隐私与安全性" } && panes.contains { $0.title == "显示器" })
    // 电池：没有中文显示名，按机型叫法不同的两个都写
    #expect(panes.contains { $0.title.contains("电池") && $0.title.contains("能耗") })
    // 只在特定情况出现的不列；每个都能用网址打开、有中文名
    #expect(!panes.contains { $0.target.hasSuffix("HeadphoneSettings") })
    #expect(panes.count >= 40 && Set(panes.map(\.id)).count == panes.count)
    // Info.plist 没说能用网址打开的、不是系统设置扩展的：不算
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    func appex(_ name: String, allows: Bool, point: String = "com.apple.Settings.extension.ui")
      throws
    {
      let contents = root.appending(path: "\(name).appex/Contents")
      try FileManager.default.createDirectory(
        at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
      let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.\(name)", "CFBundleDisplayName": name,
        "EXAppExtensionAttributes": [
          "EXExtensionPointIdentifier": point,
          "SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": allows],
        ],
      ]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appending(path: "Info.plist"))
      let strings = [
        "zh_CN": ["CFBundleDisplayName": "示例\(name)"], "en": ["CFBundleDisplayName": name],
      ]
      try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
        .write(to: contents.appending(path: "Resources/InfoPlist.loctable"))
    }
    try appex("Good", allows: true)
    try appex("NoURL", allows: false)
    try appex("Widget", allows: true, point: "com.apple.widgetkit-extension")
    #expect(AppCatalog.settingsPanes(in: root.path).map(\.title) == ["示例Good"])
  }

  @Test func settingsPaneRowsOpenAndComeBack() throws {
    let pane = try #require(AppCatalog.panes().first { $0.title == "蓝牙" })
    let (model, usage) = try model(apps: [pane])
    model.query = "蓝牙"
    let row = try #require(model.selectedItem)
    #expect(row == pane)
    #expect(model.primaryAction(for: row).title == "打开")
    #expect(model.copyTitle(for: row) == nil && model.commandReturnAction(for: row) == nil)
    #expect(!model.actions.contains { $0.title.hasPrefix("用「") })  // 不是网页，没有「用 X 打开」
    // 用过的进「常用」、从目录里还原（副标题仍是「系统设置」），搜索时不另出一行
    usage.record(pane, query: "")
    model.query = ""
    #expect(model.results.first == pane)
    model.query = "lanya"
    #expect(model.results.filter { $0.target == pane.target }.count == 1)
  }

  /// 目录里没有的 x-apple.systempreferences: 网址（自己建的快捷链接、直接输入打开过的）仍是普通网址：收藏不被删、
  /// 用过的照样列、能复制网址
  @Test func unknownSettingsURLStaysPlainURL() throws {
    let pane = try #require(AppCatalog.panes().first { $0.title == "蓝牙" })
    let (model, usage) = try model(apps: [pane])
    let custom = LauncherItem(
      kind: .url,
      target: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
      title: "辅助功能授权", subtitle: "")
    #expect(!AppCatalog.isSettingsPane(custom.target) && AppCatalog.isSettingsPane(pane.target))
    usage.toggleFavorite(custom)
    usage.record(custom, query: "")
    model.query = ""
    #expect(usage.favorites.map(\.target) == [custom.target])
    let row = try #require(model.results.first { $0.target == custom.target })
    #expect(model.copyTitle(for: row) == "复制网址")
    model.query = "辅助功能授权"
    #expect(model.results.contains { $0.target == custom.target })
  }

  // MARK: D6 网站图标

  /// 按 Chrome 的表结构造一个假库：每个主机取最大的一张；没有时试加 / 去掉 www.；http 也算
  @Test func faviconLookup() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "Favicons").path
    let database = try Database(path: path)
    try database.execute(
      "CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER, page_url_type INTEGER DEFAULT 0)"
    )
    try database.execute(
      "CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0, image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0, last_requested INTEGER DEFAULT 0)"
    )
    try database.execute("CREATE INDEX icon_mapping_page_url_idx ON icon_mapping(page_url)")
    for (page, icon) in [
      ("https://github.com/", 1), ("https://github.com/apple/swift", 1),
      ("https://www.example.org/docs", 2), ("http://intranet.test/", 3),
      ("https://github.community/", 4),
    ] {
      try database.execute(
        "INSERT INTO icon_mapping(page_url, icon_id) VALUES (?, ?)", [page, icon])
    }
    for (icon, width, data) in [(1, 16, "gh16"), (1, 32, "gh32"), (2, 16, "ex"), (3, 16, "in")] {
      try database.execute(
        "INSERT INTO favicon_bitmaps(icon_id, width, image_data) VALUES (?, ?, ?)",
        [icon, width, Data(data.utf8)])
    }
    let reader = try Database(path: path, readOnly: true)
    let found = SiteIcons.lookup(
      ["github.com", "example.org", "intranet.test", "missing.dev"], in: reader)
    #expect(found["github.com"] == Data("gh32".utf8))  // 最大的一张
    #expect(found["example.org"] == Data("ex".utf8))  // 加上 www. 找到
    #expect(found["intranet.test"] == Data("in".utf8))  // http
    #expect(found["missing.dev"] == nil)
    #expect(throws: (any Error).self) { try reader.execute("DELETE FROM icon_mapping") }  // 只读
    #expect(SiteIcons.host(of: "https://GitHub.com/apple") == "github.com")
    #expect(SiteIcons.host(of: "x-apple.systempreferences:com.apple.BluetoothSettings") == nil)
    #expect(SiteIcons.host(of: "maps://?q=a") == nil)
  }

  // MARK: D8 浏览历史

  @Test func historyParsingAndRows() throws {
    #expect(
      BrowserHistory.Page.date(chrome: 11_644_473_600 * 1_000_000) == Date(timeIntervalSince1970: 0)
    )
    let json = Data(
      """
      [{"u":"https://github.com/apple/swift?tab=readme","t":"apple/swift","v":13435070583509023},
      {"u":"https://linux.do/latest","t":null,"v":13435000000000000},
      {"u":"chrome://settings/","t":"设置","v":13435000000000001}]
      """.utf8)
    let pages = BrowserHistory.parse(json)
    #expect(pages.map(\.url).count == 3 && pages[1].title == "")
    #expect(BrowserHistory.parse(Data()).isEmpty)  // 没有行时 sqlite3 什么都不输出
    let items = BrowserHistory.items(pages)
    #expect(
      items.map(\.target) == [
        "https://github.com/apple/swift?tab=readme", "https://linux.do/latest",
      ])
    #expect(items[0].subtitle == "历史 · github.com" && items[1].title == "linux.do")
    #expect(items[0].names == ["apple/swift", "github.com/apple/swift"])  // 去掉协议和参数、不转拼音
    // 几个配置合起来：同一网址留最近的，最近的在前
    let old = BrowserHistory.Page(url: "https://a.com/", title: "A", visitedAt: .distantPast)
    let new = BrowserHistory.Page(url: "https://a.com/", title: "A", visitedAt: .now)
    let other = BrowserHistory.Page(url: "https://b.com/", title: "B", visitedAt: .now - 60)
    #expect(BrowserHistory.merge([old, other, new]) == [new, other])
    // 副标题按搜的那一刻算「多久前」
    var item = items[0]
    item.visitedAt = Date(timeIntervalSinceReferenceDate: 0)
    let subtitle = BrowserHistory.subtitle(
      item, now: Date(timeIntervalSinceReferenceDate: 3 * 86_400))
    #expect(subtitle == "历史 · github.com · 3天前")
    // 重读：没读过要读；变了但不到 60 秒不读；变了且满 60 秒才读
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let (a, b) = ([Date?](arrayLiteral: t0), [Date?](arrayLiteral: t0 + 1))
    #expect(BrowserHistory.needsReread(signature: nil, readAt: nil, now: a, at: t0))
    #expect(!BrowserHistory.needsReread(signature: a, readAt: t0, now: b, at: t0 + 30))
    #expect(!BrowserHistory.needsReread(signature: a, readAt: t0, now: a, at: t0 + 600))
    #expect(BrowserHistory.needsReread(signature: a, readAt: t0, now: b, at: t0 + 60))
  }

  /// 读法端到端：按 Chrome 的 urls 表造假库，/usr/bin/sqlite3 只读导出 JSON（3000 条、约 300 KB，
  /// 超过管道缓冲也不卡），只要常去的（没隐藏，访问 ≥ 2 次或手输过），最近的在前
  @Test func historyQueryThroughSqlite3() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "History").path
    let database = try Database(path: path)
    try database.execute(
      "CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL)"
    )
    try database.transaction {
      for index in 0..<3100 {
        try database.execute(
          "INSERT INTO urls(url, title, visit_count, typed_count, last_visit_time, hidden) VALUES (?, ?, 2, 0, ?, 0)",
          [
            "https://example.com/page/\(index)", String(repeating: "标题", count: 20) + "\(index)",
            13_435_000_000_000_000 + index,
          ])
      }
      for (url, visits, typed, hidden) in [
        ("https://once.com/", 1, 0, 0), ("https://typed.com/", 1, 1, 0),
        ("https://hidden.com/", 5, 0, 1),
      ] {
        try database.execute(
          "INSERT INTO urls(url, title, visit_count, typed_count, last_visit_time, hidden) VALUES (?, '', ?, ?, 13436000000000000, ?)",
          [url, visits, typed, hidden])
      }
    }
    let result = try await Subprocess.run(
      "/usr/bin/sqlite3", BrowserHistory.arguments(path), captures: true)
    #expect(result.status == 0 && result.output.utf8.count > 65_536)
    let pages = BrowserHistory.parse(Data(result.output.utf8))
    #expect(pages.count == BrowserHistory.limit)
    #expect(pages.first?.url == "https://typed.com/")  // 手输过的算，最近的在前
    #expect(!pages.contains { $0.url == "https://once.com/" || $0.url == "https://hidden.com/" })
    #expect(pages[1].url == "https://example.com/page/3099")
  }

  /// 搜的时候：历史排在书签 / 本地结果后面，和用过的网址不重复，最多 5 行，副标题带「多久前」；
  /// 只有历史匹配上时照样出兜底搜索（历史不算本地结果）
  @Test func historyRanksAfterLocalResults() throws {
    let github = LauncherItem(
      kind: .app, target: "/Applications/GitHub Desktop.app", title: "GitHub Desktop",
      subtitle: "", names: ["github desktop"])
    let (model, usage) = try model(apps: [github])
    let pages = (0..<8).map {
      BrowserHistory.Page(
        url: "https://github.com/repo\($0)", title: "github repo \($0)", visitedAt: .now - 3600)
    }
    model.historyItems = { BrowserHistory.items(pages) }
    let used = LauncherItem(
      kind: .url, target: "https://github.com/repo0", title: "repo0", subtitle: "")
    usage.record(used, query: "")
    model.query = "github"
    let kinds = model.results.map { $0.subtitle.hasPrefix("历史") ? "history" : $0.target }
    #expect(kinds.first == github.target)
    #expect(kinds.filter { $0 == "history" }.count == LauncherModel.historyLimit)
    #expect(model.results.filter { $0.target == "https://github.com/repo0" }.count == 1)
    let row = try #require(model.results.first { $0.subtitle.hasPrefix("历史") })
    #expect(row.subtitle.hasPrefix("历史 · github.com · "))
    // 1 个字不搜历史
    model.query = "g"
    #expect(!model.results.contains { $0.subtitle.hasPrefix("历史") })
    // 只有历史匹配上：兜底搜索照样在最后
    model.query = "repo 7"
    #expect(model.results.first?.subtitle.hasPrefix("历史") == true)
    #expect(model.results.last?.kind == .search)
  }
}
