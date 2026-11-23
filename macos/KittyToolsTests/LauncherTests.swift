// 启动器单测：匹配分档（含缩写 vsc、拼音）、使用分衰减与加成、排序；⌘K 动作菜单、cb 转剪贴板、内置动作的
// 副标题与快捷键键帽（N8–N10）。体检第 5 批（启动器）的在 LauncherBatch5Tests。

import AppKit
import Carbon.HIToolbox
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

  /// 把事件变成 `NSApp.currentEvent`：投进队列再取出来。取到的不一定是刚投的那个——系统自己的事件会插队，取事件时
  /// 顺带跑起来的别的测试转 run loop 也可能先把它取走——所以取到自己投的为止（别人的照常派发），被取走了就再投。
  /// 取出来的是另一个 NSEvent 对象，认不认得出是自己的由调用方说
  private func makeCurrent(_ event: NSEvent, isMine: (NSEvent) -> Bool) throws {
    for _ in 0..<20 {
      NSApp.postEvent(event, atStart: true)
      while let next = NSApp.nextEvent(
        matching: .any, until: .distantPast, inMode: .default, dequeue: true)
      {
        if isMine(next) { return }
        NSApp.sendEvent(next)
      }
    }
    throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "投的事件一直没取到"])
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
    #expect(score("vsc") == 50)  // 跨词首字母
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
    // 真实系统 App（系统语言是简体中文）：标题是中文，英文缩写要从文件名来（am），中文名 / 拼音也能搜
    let monitor = AppCatalog.item(
      path: "/System/Applications/Utilities/Activity Monitor.app", languages: ["zh-Hans"])
    #expect(monitor.title == "活动监视器" && monitor.subtitle == "Activity Monitor")
    for query in ["am", "activity", "活动", "hdjsq"] {
      #expect(LauncherMatch.score(query, item: monitor) > 0, "\(query)")
    }
  }

  /// 中文名直接写在主 Info.plist 里的（没有 zh-Hans.lproj，显示名就是中文：企业微信；第三轮体检 B2）：拼音、首字母也搜得到。
  /// 假路径：不存在的包显示名就是文件名
  @Test func chineseDisplayNameGetsPinyin() {
    let app = AppCatalog.item(path: "/no/such/企业微信.app")
    #expect(app.title == "企业微信")
    for query in ["qiye", "weixin", "qywx", "企业"] {
      #expect(LauncherMatch.score(query, item: app) > 0, "\(query)")
    }
  }

  /// 在 Mac 上装的 iPhone / iPad App（美区小红书叫 rednote，2026-11-10）：中文名在里面那层包的 zh-Hans.lproj，
  /// 或者直接写在里面那层的主 Info.plist；没有 WrappedBundle 链接时找 Wrapper 里的 .app
  @Test func wrappedIOSAppGetsChineseName() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "wrapped-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func make(_ name: String, linked: Bool, info: [String: String], strings: [String: String]?)
      throws -> String
    {
      let outer = root.appending(path: "\(name).app")
      let inner = outer.appending(path: "Wrapper/discover.app")
      try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        .write(to: inner.appending(path: "Info.plist"))
      if let strings {
        let lproj = inner.appending(path: "zh-Hans.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        #expect(
          (strings as NSDictionary).write(
            to: lproj.appending(path: "InfoPlist.strings"), atomically: true))
      }
      if linked {
        try FileManager.default.createSymbolicLink(
          atPath: outer.appending(path: "WrappedBundle").path,
          withDestinationPath: "Wrapper/discover.app")
      }
      return outer.path
    }
    let lprojPath = try make(
      "rednote", linked: true, info: ["CFBundleDisplayName": "rednote"],
      strings: ["CFBundleDisplayName": "小红书"])
    let plainPath = try make(
      "rednote2", linked: false, info: ["CFBundleDisplayName": "小红书"], strings: nil)
    let lproj = AppCatalog.item(path: lprojPath, languages: ["zh-Hans"])
    let plain = AppCatalog.item(path: plainPath, languages: ["zh-Hans"])
    // 系统是英文：中文名只写在里面那层主 Info.plist 的，标题是外面那层的名字，中文名照样搜得到
    let english = AppCatalog.item(path: plainPath, languages: ["en"])
    #expect(english.title == "rednote2")
    for query in ["xhs", "小红", "rednote"] {
      #expect(LauncherMatch.score(query, item: english) > 0, "\(query)")
    }
    for app in [lproj, plain] {
      #expect(app.title == "小红书")
      for query in ["xhs", "xiaohongshu", "小红", "rednote"] {
        #expect(LauncherMatch.score(query, item: app) > 0, "\(query)")
      }
    }
    #expect(lproj.subtitle == "rednote")
    // 普通的 Mac App 不当成这种
    #expect(AppCatalog.wrappedBundle(URL(filePath: "/System/Applications/Calculator.app")) == nil)
  }

  /// 粗筛（P3，书签和浏览历史先过一遍）：完整打分不是 0 的一定过得去，只靠首字母缩写命中的（vsc、hdjsq）也过
  @Test func prefilterNeverDropsAMatch() {
    let items = [
      app("Visual Studio Code"), app("Activity Monitor", chinese: "活动监视器"), app("Safari"),
      app("WPS Office"),
    ]
    let queries = [
      "vsc", "vis", "studio code", "code visual", "hdjsq", "活动", "am", "s", "sa fa", "wo", "zzz",
      "visual xyz", "o",
    ]
    for item in items {
      for query in queries where LauncherMatch.score(query, item: item) > 0 {
        #expect(
          LauncherMatch.mayMatch(LauncherMatch.tokens(query), item), "\(query) \(item.title)")
      }
    }
    #expect(LauncherMatch.mayMatch(LauncherMatch.tokens("vsc"), items[0]))
    #expect(!LauncherMatch.mayMatch(LauncherMatch.tokens("zzz"), items[2]))
    #expect(!LauncherMatch.mayMatch(LauncherMatch.tokens("visual xyz"), items[0]))
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
    // 全局：1 衰减一个时间常数（×1/e）后 +1；查询：28 天常数下 14 天前的那次还剩 e^(-1/2)
    #expect(abs(boost.global - (1 / M_E + 1)) < 1e-9)
    #expect(abs(boost.query - (1 + exp(-14.0 / 28))) < 1e-9)
    #expect(usage.boost(for: item, query: "other").query == 0)
    // 落库往返
    #expect(usage.entries.count == 2)
  }

  /// 2026-11-10 论坛反馈「输 s 回车开了 Safari」：同一输入选过一次就压过平时用得多的；输入的开头按一半算；
  /// 没有记录时按系统记的使用排
  @Test func usageLearnsChoiceForQuery() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let safari = app("Safari")
    let shadow = app("Shadowrocket")
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    for _ in 0..<30 { usage.record(safari, query: "", now: now) }
    let rank = { (query: String) in
      LauncherMatch.rank([safari, shadow], query: query) {
        usage.boost(for: $0, query: query, now: now)
      }.map(\.title)
    }
    #expect(rank("s") == ["Safari", "Shadowrocket"])
    usage.record(shadow, query: "s", now: now)
    #expect(rank("s") == ["Shadowrocket", "Safari"])
    // 一周后还记得（原来 3 天的常数，一周后只剩十分之一）
    let week = now.addingTimeInterval(7 * 86_400)
    #expect(
      LauncherMatch.rank([safari, shadow], query: "s") {
        usage.boost(for: $0, query: "s", now: week)
      }.first == shadow)

    // 在「sha」下选过：「s」「sh」按一半算，一字不差的才算「这个输入选过」（E8 的提到固定行前面只看它）
    let fresh = try LauncherUsage(db: Database(path: ":memory:"))
    fresh.record(shadow, query: "sha", now: now)
    #expect(fresh.boost(for: shadow, query: "s", now: now).query == 0.5)
    #expect(fresh.boost(for: shadow, query: "SH ", now: now).query == 0.5)
    #expect(fresh.boost(for: shadow, query: "sha", now: now).query == 1)
    #expect(fresh.boost(for: shadow, query: "shad", now: now).query == 0)
    #expect(fresh.boost(for: safari, query: "s", now: now).query == 0)
    #expect(!fresh.chose(shadow, query: "s") && fresh.chose(shadow, query: "sha"))
    // 记录变了，挑出来的那批跟着变
    fresh.record(shadow, query: "shadow", now: now)
    #expect(fresh.boost(for: shadow, query: "s", now: now).query == 1)
    fresh.forget(shadow)
    #expect(fresh.boost(for: shadow, query: "s", now: now).query == 0)

    // 都没在这里用过：系统记的使用多的在前，一样多才标题短的在前
    var used = shadow
    used.systemUse = 3
    var less = safari
    less.systemUse = 1
    #expect(
      LauncherMatch.rank([less, used], query: "s") { _ in (0, 0) }.map(\.title) == [
        "Shadowrocket", "Safari",
      ])
    #expect(
      LauncherMatch.rank([shadow, safari], query: "s") { _ in (0, 0) }.map(\.title) == [
        "Safari", "Shadowrocket",
      ])
    // 系统记的使用：每天按 28 天衰减求和；没有日子时按最后使用那天算
    let days = [now, now.addingTimeInterval(-28 * 86_400)]
    #expect(
      abs(AppCatalog.systemUse(usedDates: days, lastUsed: nil, now: now) - (1 + 1 / M_E)) < 1e-9)
    #expect(AppCatalog.systemUse(usedDates: [], lastUsed: now, now: now) == 1)
    #expect(AppCatalog.systemUse(usedDates: [], lastUsed: nil, now: now) == 0)
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
    // 同分时系统命令排在 App 后面（体检 B36）：没用过的 Slack 不再被「睡眠」挤到第二、↩ 下去电脑就睡了
    let slack = app("Slack")
    let rank = { LauncherMatch.rank([slack] + SystemCommands.items, query: $0) { _ in (0, 0) } }
    #expect(rank("sl").first == slack)
    let logseq = app("Logseq")
    #expect(
      LauncherMatch.rank([logseq] + SystemCommands.items, query: "lo") { _ in (0, 0) }.first
        == logseq)
    for query in ["sleep", "睡眠", "shuimian"] {
      #expect(rank(query).first?.target == "sleep", "\(query)")
    }
    // 没用过：同分时标题短的在前
    #expect(
      LauncherMatch.rank([chrome, app("Chroma")], query: "chrom") { _ in (0, 0) }.map(\.title) == [
        "Chroma", "Google Chrome",
      ])
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
    // 后面跟着路径或端口时不看后缀白名单（体检 B34）；裸的还是按白名单，文件名不当网址
    #expect(url("docs.rs/serde") == "https://docs.rs/serde")
    #expect(url("bun.sh/docs") == "https://bun.sh/docs")
    #expect(url("deno.land/x") == "https://deno.land/x")
    #expect(url("notion.so/abc") == "https://notion.so/abc")
    #expect(url("example.test:8080") == "https://example.test:8080")
    #expect(url("Package.swift") == nil && url("libfoo.so") == nil)
    #expect(url("README.md:x") == nil)  // 冒号后面不是端口
    // 标题：去掉协议，保留端口，路径不显示百分号编码
    let title = { DirectItems.displayName(of: URL(string: $0)!) }
    #expect(title("https://linux.do/latest") == "linux.do/latest")
    #expect(title("http://10.10.33.176:8089/app/") == "10.10.33.176:8089/app/")
    #expect(title("https://zh.wikipedia.org/wiki/%E8%8B%B9%E6%9E%9C") == "zh.wikipedia.org/wiki/苹果")
    // 路径归路径模式（PathBrowser），直达项不再出路径
    #expect(DirectItems.items(for: "/tmp").isEmpty && DirectItems.items(for: "~").isEmpty)
  }

  @Test func calculator() {
    let value = { Calculator.evaluate($0) }
    #expect(value("1+2*3") == 7)
    #expect(value("(1+2)*3") == 9)
    #expect(value("2^3^2") == 512)  // 幂右结合
    #expect(value("2**10") == 1024)
    #expect(value("-2^2") == -4)
    // % 是百分号（体检 A23），取模改用 mod
    #expect(value("200*15%") == 30)
    #expect(value("100+10%") == 110)
    #expect(value("100-10%") == 90)
    #expect(value("50%") == 0.5)
    #expect(value("80/50%") == 160)
    #expect(value("(1+1)%") == 0.02)
    #expect(value("10 mod 3") == 1)
    #expect(value("pi mod 3") == .pi.truncatingRemainder(dividingBy: 3))
    #expect(value("10%3") == nil)
    #expect(Calculator.item(for: "200*15%")?.payload == "30")
    #expect(Calculator.item(for: "10 mod 3")?.payload == "1")
    // 中文输入法打出来的（体检 B32）：全角括号 / 数字、× ÷、千分位逗号；算式那一栏照常是原文
    #expect(value("（1+2）×3") == 9)
    #expect(value("1,299*3") == 3897)
    #expect(value("１＋２") == 3)
    #expect(value("9÷3") == 3)
    #expect(Calculator.item(for: "（1+2）×3")?.target == "（1+2）×3")
    #expect(Calculator.item(for: "１＋２")?.payload == "3")
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
    // 新装默认只让 Google 兜底，Bing、百度只走关键词（体检 A24；地区是中国大陆时换成百度，见 Checkup4LauncherTests）；
    // fy 是保留关键词（体检 D10）
    #expect(WebSearch.defaults(region: .unitedStates).filter(\.enabled).map(\.id) == ["google"])
    #expect(
      WebSearch.defaults.contains { $0.keyword == "bing" }
        && WebSearch.reservedKeywords["fy"] != nil)
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
    // 没有 {query} 的是快捷链接：网址记成 .url（记使用、进「常用」），路径展开 ~
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
    // 没带补全的路径（收藏、常用还原出来的）补出路径本身、不 stat：是文件夹的话路径模式直接列它里面
    let directory = LauncherItem(
      kind: .path, target: "/System/Library", title: "Library", subtitle: "")
    #expect(LauncherModel.completion(for: directory) == "/System/Library")
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
        windowNumber: 0, context: nil, subtype: 0, data1: 0x4B54, data2: 0))
    try makeCurrent(event) { $0.type == .applicationDefined && $0.data1 == 0x4B54 }
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
    let forgotten = usage.forget(app)
    #expect(usage.entries.values.map(\.target) == ["https://b.com"] && forgotten.count == 2)
    // ⌘Z 原样放回（体检 B38）
    usage.restore(forgotten)
    #expect(usage.entries.count == 3 && usage.boost(for: app, query: "a").query > 0)
    usage.forget(app)
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
    try write("Bookmarks", ["https://opera.example/"])  // Opera：配置就是数据目录本身（第 12 批）
    let urls = Browsers.profileFiles(named: ["Bookmarks", "AccountBookmarks"], in: root)
      .compactMap { try? Data(contentsOf: $0) }
      .flatMap(Bookmarks.parse).map(\.url)
    #expect(
      urls == ["https://opera.example/", "https://github.com/", "https://developer.apple.com/"])
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
    #expect(LauncherModel.clipQuery("CB 会议") == "会议")  // 不分大小写（体检 B33）
  }

  /// N9：cb 不再列剪贴板条目，只有一行，↩ 收起启动器、把关键词交给剪贴板面板
  @Test func clipCommandHandsOffToClipboardPanel() throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    var opened: [String] = []
    var hidden = 0
    model.openClipboard = { opened.append($0) }
    model.hidePanel = { hidden += 1 }
    model.query = "cb  发票 抬头"
    #expect(model.results.map(\.title) == ["在剪贴板历史里搜索「发票 抬头」"])
    model.execute(model.results[0])
    #expect(opened == ["发票 抬头"] && hidden == 1)
    // 单输 cb：这一行排第一，后面照常接本地结果（体检 B33）；「cb 」带空格还是只有这一行
    model.query = "cb"
    let row = try #require(model.results.first)
    #expect(row.kind == .clip && row.title == "打开剪贴板历史")
    model.query = "CB "
    #expect(model.results.map(\.title) == ["打开剪贴板历史"])
    #expect(
      String(localized: model.primaryAction(for: row).title) == "打开"
        && row.hotKeyAction == .clipboard)
    // 没有可复制、可补全的东西：⌘C 交给输入框，菜单里只有主动作
    #expect(
      model.copyTitle(for: row).map { String(localized: $0) } == nil
        && LauncherModel.completion(for: row) == nil)
    model.toggleActions()
    #expect(model.actions.map(\.shortcut) == ["↩"])
  }

  /// N8：⌘K 列出主动作和全部替代动作（连同键位），搜索框过滤，Esc 只关菜单；没有选中项时不打开
  @Test func actionMenuListsPrimaryAndAlternates() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let calculator = AppCatalog.item(path: "/System/Applications/Calculator.app")
    usage.record(calculator, query: "")
    let model = LauncherModel(usage: usage, apps: [calculator])
    model.query = ""
    #expect(model.results.first == calculator)
    model.toggleActions()
    #expect(model.showsActions)
    #expect(model.actions.map(\.shortcut) == ["↩", "⌘↩", "⌘C", "⇥", "⌘D", "⌘⌫"])
    #expect(model.actions.prefix(3).map(\.title) == ["打开", "在访达中显示", "复制路径"])
    #expect(model.handleCommand(#selector(NSResponder.moveDown(_:))) && model.actionSelection == 1)
    model.actionQuery = "访达"
    #expect(model.filteredActions.map(\.shortcut) == ["⌘↩"] && model.actionSelection == 0)
    #expect(model.handleCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(!model.showsActions && model.actionQuery.isEmpty && model.results.first == calculator)
    // 有查询时多出 ⌥↩；计算结果的 ⌘C 和 ⌘↩ 一样，不重复列；不是「常用」没有 ⌘⌫
    model.query = "12*3"
    model.toggleActions()
    #expect(model.actions.prefix(3).map(\.shortcut) == ["↩", "⌘↩", "⇥"])
    #expect(model.actions.contains { $0.shortcut == "⌥↩" && $0.title == "在访达里搜索「12*3」" })
    #expect(!model.actions.contains { $0.shortcut == "⌘C" || $0.shortcut == "⌘⌫" })
    model.toggleActions()
    model.query = "open a"  // 只输 1 个字母的文件搜索：没有结果
    model.toggleActions()
    #expect(model.results.isEmpty && !model.showsActions)
    // 菜单和底栏用到的符号都在系统里（名字拼错时 Image 什么都不画）
    let symbols =
      [model.primaryAction(for: calculator).symbol, "doc.on.doc", "arrow.right.to.line"]
      + [
        "doc.text.magnifyingglass", "globe", "clock.badge.xmark", "square.grid.2x2.fill",
        "folder.fill", "doc.fill", "command", "folder", "safari", "lock.open", "text.cursor",
        "arrow.turn.down.left", "doc.on.clipboard", "star", "star.slash", "eye", "trash",
        "text.badge.plus", "text.quote", "character.bubble", "character.bubble.fill", "link",
        "keyboard", "info.circle", "pin", "pin.slash", "arrow.triangle.2.circlepath", "gearshape",
      ]
    for symbol in symbols {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  /// 回归：菜单开着时标着的 ⇥ 照常补全（以前吞掉），⌃O 这类别的换行键只吞掉；⌘K 过滤框里有字时 ⌘⌫ 交还输入框
  /// 删过滤词，不把「常用」的条目删掉，过滤框空着才执行菜单里的「从常用中移除 ⌘⌫」
  @Test func actionMenuKeysMatchTheirLabels() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let calculator = AppCatalog.item(path: "/System/Applications/Calculator.app")
    usage.record(calculator, query: "")
    let model = LauncherModel(usage: usage, apps: [calculator])
    model.query = ""
    func key(_ code: Int, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
          keyCode: UInt16(code)))
    }
    model.toggleActions()
    try makeCurrent(try key(kVK_ANSI_O, .control)) {
      $0.type == .keyDown && Int($0.keyCode) == kVK_ANSI_O && $0.modifierFlags.contains(.control)
    }
    #expect(model.handleCommand(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
    #expect(model.showsActions)
    let commandDelete = try key(kVK_Delete, .command)
    model.actionQuery = "移除"
    #expect(!model.handleKeyEquivalent(commandDelete))
    #expect(model.showsActions && model.results == [calculator])
    #expect(model.handleCommand(#selector(NSResponder.insertTab(_:))))
    #expect(!model.showsActions && model.query == LauncherModel.completion(for: calculator))
    model.query = ""
    model.toggleActions()
    #expect(model.handleKeyEquivalent(commandDelete))
    #expect(!model.showsActions && model.results.isEmpty)
  }

  /// N10：内置动作副标题只写「Kitty Tools」（复制即译、暂停记录写开没开），英文别名照样能搜；选中时显示的全局快捷键拆成一组键帽
  @Test func builtInActionsAndHotKeyCaps() throws {
    let actions = LauncherItem.actions()
    #expect(
      actions.filter { !["copyToTranslate", "pause-clipboard"].contains($0.target) }
        .allSatisfy { $0.subtitle == "Kitty Tools" })
    let screenshot = try #require(actions.first { $0.target == "screenshot" })
    #expect(LauncherMatch.score("capture", item: screenshot) > 0)
    #expect(screenshot.hotKeyAction == .screenshot)
    #expect(actions.first { $0.target == "settings" }?.hotKeyAction == nil)
    #expect(KeyCombo.caps("⌥C") == ["⌥", "C"])
    #expect(KeyCombo.caps("⌃⌥⇧⌘I") == ["⌃", "⌥", "⇧", "⌘", "I"])
    #expect(KeyCombo.caps("⌥空格") == ["⌥", "空格"])
    #expect(KeyCombo.caps("F5") == ["F5"])
  }
}

/// 第四轮体检第 3 批（启动器）：这个查询选过的本地结果排到固定行前面（E8）；扫 CoreServices/Applications、启动台不列（E9）；
/// 中国大陆默认百度兜底、含中文时 1 个字就搜书签 / 历史 / 兜底（U8）
struct Checkup4LauncherTests {
  private func app(_ title: String, chinese: String? = nil) -> LauncherItem {
    let pinyin = chinese.flatMap(AppCatalog.pinyin)
    return LauncherItem(
      kind: .app, target: "/Applications/\(title).app", title: chinese ?? title, subtitle: "",
      names: [chinese, title, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) },
      initials: [LauncherMatch.initials(title), pinyin?.initials].compactMap { $0 })
  }

  @Test func promotingKeepsOrder() {
    let (a, b, c, fixed) = (app("A"), app("B"), app("C"), app("Fixed"))
    let chosen: Set = [a.id, c.id]
    #expect(
      LauncherModel.promoting([a, b, c], over: [fixed]) { chosen.contains($0.id) }.map(\.id)
        == [a.id, c.id, fixed.id, b.id])
    #expect(
      LauncherModel.promoting([a, b], over: [fixed]) { _ in false }.map(\.id) == [
        fixed.id, a.id, b.id,
      ])
  }

  /// gh / bd / ip：没选过时固定行（搜索提示、ip 地址）在最前；在完全相同的输入下选过的 App 排到它们前面
  @Test func chosenLocalResultsGoBeforeFixedRows() throws {
    let ghostty = app("Ghostty")
    let netdisk = app("BaiduNetdisk", chinese: "百度网盘")
    let mirroring = app("iPhone Mirroring")
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let model = LauncherModel(usage: usage, apps: [ghostty, netdisk, mirroring])
    model.localAddresses = {
      IPAddresses.localItems(
        [.init(interface: "en0", address: "192.168.1.23")], primary: "en0", names: ["en0": "Wi-Fi"])
    }
    model.publicAddress = { _ in nil }
    for (query, item, fixed) in [
      ("gh", ghostty, "用 GitHub 搜索…"), ("bd", netdisk, "用 百度 搜索…"),
      ("ip", mirroring, "192.168.1.23"),
    ] {
      model.query = query
      #expect(model.results.first?.title == fixed, "\(query)")
      #expect(model.results.contains { $0.id == item.id }, "\(query)")
      // 别的输入下选过的不算
      usage.record(item, query: query + "x")
      model.query = query
      #expect(model.results.first?.title == fixed, "\(query)")
      usage.record(item, query: query)
      model.query = query
      #expect(model.results.first?.id == item.id, "\(query)")
      #expect(model.results.dropFirst().first?.title == fixed, "\(query)")
    }
  }

  @Test func coreServicesAppsInLauncherNotLaunchpad() {
    let keychain = "/System/Library/CoreServices/Applications/Keychain Access.app"
    #expect(
      AppCatalog.scan().contains {
        $0.target.hasPrefix("/System/Library/CoreServices/Applications/")
      })
    #expect(AppCatalog.location(of: keychain) == "")  // 标准目录：副标题不写位置
    func item(_ path: String, kind: LauncherItem.Kind = .app) -> LauncherItem {
      LauncherItem(kind: kind, target: path, title: "x", subtitle: "")
    }
    #expect(!LaunchpadCatalog.shows(item(keychain)))
    #expect(!LaunchpadCatalog.shows(item("/System/Library/CoreServices/Finder.app")))
    #expect(LaunchpadCatalog.shows(item("/System/Applications/Calculator.app")))
    #expect(LaunchpadCatalog.shows(item("/Applications/Ghostty.app")))
    #expect(
      !LaunchpadCatalog.shows(item("x-apple.systempreferences:com.apple.Displays", kind: .url)))
    #expect(
      !LaunchpadCatalog.load().contains { $0.path.hasPrefix("/System/Library/CoreServices/") })
  }

  @Test func regionalFallbackAndShortChineseQueries() throws {
    let china = WebSearch.defaults(region: .chinaMainland)
    #expect(china.filter(\.enabled).map(\.id) == ["baidu"])
    #expect(WebSearch.defaults(region: .unitedStates).filter(\.enabled).map(\.id) == ["google"])
    #expect(WebSearch.defaults(region: nil).filter(\.enabled).map(\.id) == ["google"])
    #expect(china.map(\.id) == WebSearch.defaults(region: .japan).map(\.id))  // 只换兜底，列表一样
    #expect(WebSearch.primary(in: china)?.id == "baidu")
    #expect(LauncherMatch.isLongEnough("ab") && LauncherMatch.isLongEnough("龘"))
    #expect(!LauncherMatch.isLongEnough("a") && !LauncherMatch.isLongEnough(" a "))
    #expect(
      WebSearch.fallbackItems(for: "龘", engines: china).map(\.target)
        == ["https://www.baidu.com/s?wd=%E9%BE%98"])
    #expect(WebSearch.fallbackItems(for: "a", engines: china).isEmpty)
    // 启动器里：一个汉字没有本地结果时照样出兜底
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.query = "龘"
    #expect(model.results.contains { $0.kind == .search })
    model.query = "q"
    #expect(!model.results.contains { $0.kind == .search })
  }
}

/// 多语言第 6 批（启动器，TRANSLATION.md「搜索中英都认」D7）：中文界面打英文、英文界面打中文 / 拼音都搜得到；英文界面的
/// 计算器单位、汇率示例、脚本头部的英文写法、自带脚本复制出去只留一种语言、网页搜索预设只翻显示。单测宿主是中文界面：
/// 英文界面的那一半用「标题是英文」的条目（和英文界面里建出来的一样）来验
struct LauncherLanguageTests {
  private func matches(_ query: String, _ item: LauncherItem) -> Bool {
    LauncherMatch.score(query, item: item) > 0
  }

  @Test func actionsMatchBothLanguages() throws {
    // 中文界面：没写英文别名的「截图历史」，打它的英文标题也找得到（英文来自目录）
    let history = try #require(
      LauncherItem.actions().first { $0.target == HotKeyAction.shotHistory.rawValue })
    #expect(history.title == "截图历史")
    #expect(matches("screenshot history", history) && matches("jietu", history))
    // 英文界面：标题是英文，中文原文、全拼、首字母照样进搜索名
    let resource = HotKeyAction.shotHistory.titleResource
    let english = LauncherItem.searchTerms(resource.english, resource)
    let item = LauncherItem(
      kind: .action, target: "x", title: resource.english, subtitle: "", names: english.names,
      initials: english.initials)
    #expect(item.title == "Screenshot History")
    #expect(matches("截图历史", item) && matches("jietulishi", item) && matches("jtls", item))
    #expect(matches("screenshot", item))
  }

  @Test func systemCommandsMatchBothLanguages() throws {
    let lock = try #require(SystemCommands.items.first { $0.target == "lock" })
    for query in ["锁定屏幕", "suoding", "锁屏", "lock screen", "lock"] {
      #expect(matches(query, lock), "\(query)")
    }
    // 显示的名字在英文里照系统的叫法，确认框带「…」
    #expect(SystemCommand.lock.titleResource.english == "Lock Screen")
    #expect(SystemCommand.logout.titleResource.english == "Log Out…")
  }

  /// 2026-11-16 手测反馈「我的应用都是英文，为什么启动器的别名展示成了中文」：标题是访达里的名字，跟系统的语言、
  /// 不跟本 App 的界面语言（单测宿主钉在中文，英文系统照样是英文名）；中文名、拼音、英文名、缩写两种系统上都能搜
  @Test func appTitleFollowsSystemLanguageAndSearchKeepsBoth() {
    let path = "/System/Applications/Utilities/Disk Utility.app"
    let english = AppCatalog.item(path: path, languages: ["en-CN", "zh-Hans-CN"])
    let chinese = AppCatalog.item(path: path, languages: ["zh-Hans-CN", "en-CN"])
    #expect(english.title == "Disk Utility" && chinese.title == "磁盘工具")
    #expect(english.subtitle.isEmpty && chinese.subtitle == "Disk Utility")
    for app in [english, chinese] {
      for query in ["disk utility", "du", "磁盘", "cipan", "cpgj"] {
        #expect(LauncherMatch.score(query, item: app) > 0, "\(query)")
      }
    }
    // 英文名和文件名不一样的（FindMy.app 叫 Find My）、别的语言（德文系统叫 Notizen）都照包里的本地化名
    let findMy = AppCatalog.item(path: "/System/Applications/FindMy.app", languages: ["en"])
    #expect(findMy.title == "Find My" && LauncherMatch.score("查找", item: findMy) > 0)
    #expect(
      AppCatalog.systemName(path: "/System/Applications/Notes.app", languages: ["de"]) == "Notizen")
    // 应用别名页、「用 X 打开」、剪贴板来源用的 systemName 和标题同一套
    #expect(AppCatalog.systemName(path: path, languages: ["en"]) == "Disk Utility")
    // 中文名优先只看系统的第一语言是不是简体中文
    #expect(AppCatalog.prefersChinese(["zh-Hans-CN"]) && AppCatalog.prefersChinese(["zh-CN"]))
    #expect(!AppCatalog.prefersChinese(["en-CN", "zh-Hans-CN"]))
    #expect(
      !AppCatalog.prefersChinese(["zh-Hant-TW"]) && !AppCatalog.prefersChinese(["ja", "zh-Hans"]))
  }

  @Test func scriptHeaderLanguageVariants() throws {
    let head = """
      #!/bin/zsh
      # @kitty.title 防止睡眠
      # @kitty.title.en Keep Awake
      # @kitty.description 一小时不睡
      # @kitty.description.en Stay awake for an hour
      # @kitty.argument1 城市
      # @kitty.argument1.en City
      """
    let zh = try #require(ScriptCommand.parse(head, path: "/s/a.sh", english: false)).get()
    let en = try #require(ScriptCommand.parse(head, path: "/s/a.sh", english: true)).get()
    #expect(zh.title == "防止睡眠" && zh.otherTitle == "Keep Awake" && zh.summary == "一小时不睡")
    #expect(zh.arguments.map(\.placeholder) == ["城市"])
    #expect(en.title == "Keep Awake" && en.otherTitle == "防止睡眠")
    #expect(en.summary == "Stay awake for an hour" && en.arguments.map(\.placeholder) == ["City"])
    // 两种界面里打另一种语言的标题、拼音都找得到
    #expect(matches("keep awake", LauncherItem.script(zh, alias: nil)))
    let enRow = LauncherItem.script(en, alias: nil)
    #expect(matches("防止睡眠", enRow) && matches("fangzhi", enRow))
    // 没写英文的：照旧用原来的，没有 otherTitle
    let plain = try #require(
      ScriptCommand.parse("#!/bin/zsh\n# @kitty.title 查天气\n", path: "/s/b.sh", english: true)
    ).get()
    #expect(plain.title == "查天气" && plain.otherTitle == nil)
  }

  @Test func bundledScriptsHaveEnglishHeaders() async throws {
    let scan = await ScriptLibrary.scan([], bundled: ScriptLibrary.bundledFiles)
    #expect(scan.scripts.count == 8)  // awake 2026-11-16 换成了保持唤醒插件
    for script in scan.scripts {
      let text = try String(contentsOfFile: script.path, encoding: .utf8)
      let english = try #require(ScriptCommand.parse(text, path: script.path, english: true)).get()
      #expect(english.title.wholeMatch(of: /[\x20-\x7E]+/) != nil, "\(script.fileName)")
      #expect(english.otherTitle == script.title, "\(script.fileName)")
      #expect(
        english.summary.map { !$0.contains(/\p{Han}/) } == true, "\(script.fileName) 的 description")
      #expect(
        english.arguments.allSatisfy { !$0.placeholder.contains(/\p{Han}/) },
        "\(script.fileName) 的参数")
    }
  }

  @Test func bundledCopyKeepsOneLanguage() {
    let text = """
      #!/bin/zsh
      # @kitty.title 防止睡眠
      # @kitty.title.en Keep Awake
      # @kitty.keyword awake
      # @kitty.argument1 {"placeholder": "时长", "optional": true}
      # @kitty.argument1.en {"placeholder": "Duration", "optional": true}
      print "$KITTY_LANGUAGE"
      """
    let chinese = ScriptLibrary.localizedCopy(text, english: false)
    #expect(!chinese.contains(".en ") && chinese.contains("# @kitty.title 防止睡眠"))
    #expect(
      chinese.contains("# @kitty.keyword awake") && chinese.hasSuffix("print \"$KITTY_LANGUAGE\""))
    let english = ScriptLibrary.localizedCopy(text, english: true)
    #expect(!english.contains(".en ") && !english.contains("防止睡眠"))
    #expect(english.contains("# @kitty.title Keep Awake"))
    #expect(english.contains(#"# @kitty.argument1 {"placeholder": "Duration", "optional": true}"#))
  }

  @Test func englishScriptTemplatesAndGuide() throws {
    let text = ScriptLibrary.template(
      title: "Hello", keyword: "hi", mode: .list, language: .zsh, english: true)
    #expect(!text.contains(/\p{Han}/))
    let script = try #require(ScriptCommand.parse(text, path: "/s/hi.sh", english: true)).get()
    #expect(script.title == "Hello" && script.mode == .list && script.summary != nil)
    // 写法说明的英文那份：例子本身能用
    let guide = ScriptAIGuide.english
    let start = try #require(guide.range(of: "```zsh\n"))
    let end = try #require(guide.range(of: "\n```", range: start.upperBound..<guide.endIndex))
    let example = try #require(
      ScriptCommand.parse(String(guide[start.upperBound..<end.lowerBound]), path: "/s/w.sh")
    ).get()
    #expect(example.title == "Weather" && example.keyword == "weather")
    for field in [
      "title", "keyword", "mode", "argument1", "description", "icon", "confirm", "filter",
    ] {
      #expect(guide.contains("@kitty.\(field)"))
    }
  }

  @Test func calculatorUnitsInEnglish() {
    #expect(Calculator.result(for: "48 h to 天", english: false)?.display == "2 天")
    #expect(Calculator.result(for: "48 h to 天", english: true)?.display == "2 d")
    #expect(Calculator.result(for: "2 斤 to g", english: true)?.display == "1,000 g")
    #expect(Calculator.result(for: "1 kg to 斤", english: true)?.payload == "2 jin")
    // 英文写的市制单位也认（英文界面 Tab 写回去的能接着换算）
    #expect(Calculator.result(for: "2 jin to g")?.display == "1,000 g")
    #expect(Calculator.result(for: "1 mu to m2")?.payload == "666.6667 m²")
  }

  /// 连着打字时面板高度直接到位（P4）：这一下离上一下、离现在都不到 typingGap 才算连着打；停了一会儿再打的第一个字、
  /// 停下来以后后到的结果照常动画
  @Test func typingBurstSkipsHeightAnimation() throws {
    let gap = LauncherModel.typingGap
    #expect(!LauncherModel.isTyping((last: 100, previous: 0), now: 100))
    #expect(LauncherModel.isTyping((last: 100, previous: 100 - gap / 2), now: 100.01))
    #expect(!LauncherModel.isTyping((last: 100, previous: 100 - gap / 2), now: 100 + gap))
    #expect(!LauncherModel.isTyping((last: 100, previous: 100 - gap * 2), now: 100.01))
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    #expect(!model.isTyping)
    model.query = "s"
    #expect(!model.isTyping)  // 第一个字
    model.query = "sa"
    #expect(model.isTyping)
  }

  /// 单位换算、进制先看有没有数字 / 进制的字，没有就不跑正则（P4）：全角的、大写的照样认，没写的照旧不算
  @Test func calculatorSkipsWithoutDigitsOrRadix() {
    #expect(Calculator.result(for: "１０ km to mi") == Calculator.result(for: "10 km to mi"))
    #expect(Calculator.result(for: "10 km to mi")?.display == "6.2137 mi")
    #expect(Calculator.result(for: "255 in ＨＥＸ") == Calculator.result(for: "255 in hex"))
    #expect(Calculator.result(for: "255 IN HEX") == Calculator.result(for: "255 in hex"))
    #expect(Calculator.result(for: "255 转 十六进制") == Calculator.result(for: "255 in hex"))
    #expect(Calculator.result(for: "255 in hex") != nil)
    for query in ["safari", "km to mi", "系统设置", "hex"] {
      #expect(Calculator.convert(query) == nil && Calculator.convertRadix(query) == nil, "\(query)")
    }
  }

  @Test func currencyExampleWorksInBothLanguages() {
    let resource = LocalizedStringResource(
      "launcher.currencyExample", defaultValue: "100 美元 转 日元", comment: "汇率换算的示例，要能算出来")
    #expect(resource.english == "100 USD to JPY")
    for example in [resource.chinese, resource.english] {
      #expect(
        ExchangeRates.request(for: example)
          == ExchangeRates.Request(amount: 100, from: "USD", to: "JPY"), "\(example)")
    }
    // 货币名按界面语言：中文界面是中文名；英文名一直认得
    #expect(ExchangeRates.name("CNY", locale: Locale(identifier: "en_US")) == "Chinese Yuan")
    #expect(ExchangeRates.chineseName("CNY") == "人民币")
    #expect(ExchangeRates.currency("chinese yuan") == "CNY")
  }

  @Test func webSearchPresetsTranslateOnlyWhenUntouched() {
    let baidu = SearchEngine(
      id: "baidu", name: "百度", keyword: "bd", urlTemplate: "https://www.baidu.com/s?wd={query}",
      enabled: false)
    #expect(WebSearch.presetTitle(id: "baidu", name: "百度")?.english == "Baidu")
    #expect(baidu.searchNames.contains("百度") && baidu.searchNames.contains("baidu"))
    // 改过名字的、自己加的照存的写
    var renamed = baidu
    renamed.name = "我的百度"
    #expect(WebSearch.presetTitle(id: "baidu", name: "我的百度") == nil)
    #expect(renamed.displayName == "我的百度")
    #expect(WebSearch.presetTitle(id: "google", name: "Google") == nil)
    // 默认列表全 App 一套：存的名字不跟着语言变
    #expect(WebSearch.defaults(region: nil).map(\.name).contains("百度"))
  }

  @Test func commandsTableFiltersByChineseInEnglish() {
    let row = LauncherCommandsSection.Row(
      id: "system:lock", title: "Lock Screen", original: "锁定屏幕", symbol: "lock.fill",
      keyword: "lock", group: .system)
    let settings = LauncherCommands.Settings()
    #expect(LauncherCommandsSection.filter([row], by: "锁定", settings: settings).count == 1)
    #expect(LauncherCommandsSection.filter([row], by: "screen", settings: settings).count == 1)
    // 中文界面：内置命令和系统命令的行都带着中文原文
    let rows = LauncherCommandsSection.rows(scripts: [])
    #expect(rows.allSatisfy { $0.original != nil })
  }

  @Test func reminderPrefillMatchesParser() {
    // 菜单栏「新建提醒」在英文界面预填「remind 」：提醒的解析认它
    #expect(ReminderPhrase.query("remind 10 min stretch") == "10 min stretch")
    #expect(ReminderPhrase.isKeyword("remind"))
  }
}
