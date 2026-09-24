// 启动器单测：匹配分档（含缩写 vsc、拼音）、使用分衰减与加成、排序、旧版使用记录导入映射。

import Foundation
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
    #expect(Calculator.item(for: "1+2")?.payload == "3")
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
        id: "b", name: "Bing", keyword: "", urlTemplate: "https://b.com/?q=", enabled: true),
      SearchEngine(
        id: "x", name: "Off", keyword: "", urlTemplate: "https://x.com/?q={query}", enabled: false),
    ]
    let keyword = try #require(WebSearch.keywordItem(for: "g c++ 教程", engines: engines))
    #expect(
      keyword.kind == .search && keyword.target == "https://g.com/?q=c%2B%2B%20%E6%95%99%E7%A8%8B")
    #expect(WebSearch.keywordItem(for: "g", engines: engines) == nil)  // 关键词后面要有内容
    let fallback = WebSearch.fallbackItems(for: "swift", engines: engines)
    // 第二个引擎漏写 {query}：搜索词追加到末尾
    #expect(fallback.map(\.target) == ["https://g.com/?q=swift", "https://b.com/?q=swift"])
    #expect(WebSearch.fallbackItems(for: "s", engines: engines).isEmpty)
    #expect(!LauncherItem.Kind.search.isRecorded)  // 搜索页不记使用
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
