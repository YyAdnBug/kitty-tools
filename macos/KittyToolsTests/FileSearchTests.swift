// 启动器文件搜索单测：open / find / 空格开头的解析、Spotlight 查询串（转义、系统能解析）、路径排除、排序、
// 右侧种类、find 模式的 ↩ / ⌘↩、「find my」仍能打开「查找」（§11 #38）、文件夹授权提示。
// 真查 Spotlight 的本机冒烟要 TEST_RUNNER_KITTY_LIVE_FILES=1（只打印数量和所在目录，不打印文件名）。

import AppKit
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

struct FileSearchTests {
  private let home = NSHomeDirectory()
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func hit(_ path: String, type: String? = "public.plain-text", daysAgo: Double = 1)
    -> FileSearch.Hit
  {
    FileSearch.Hit(
      path: home + path, name: (path as NSString).lastPathComponent, contentType: type,
      date: now.addingTimeInterval(-daysAgo * 86_400))
  }

  @Test func parsesKeywords() {
    #expect(FileSearch.request(for: "open foo bar") == .init(mode: .open, terms: ["foo", "bar"]))
    #expect(FileSearch.request(for: "Find  季度") == .init(mode: .find, terms: ["季度"]))
    #expect(FileSearch.request(for: " readme") == .init(mode: .open, terms: ["readme"]))
    #expect(FileSearch.request(for: "open ") == .init(mode: .open, terms: []))
    #expect(FileSearch.request(for: " ") == .init(mode: .open, terms: []))
    // 只输关键词、关键词开头的别的词、中间有 open 的都不算
    for query in ["open", "find", "opener x", "findmy", "reopen x", ""] {
      #expect(FileSearch.request(for: query) == nil, "\(query)")
    }
    #expect(FileSearch.request(for: "open a")?.isTooShort == true)
    #expect(FileSearch.request(for: "open a b")?.isTooShort == true)
    #expect(FileSearch.request(for: "open ab")?.isTooShort == false)
    #expect(FileSearch.request(for: "open 报")?.isTooShort == false)  // 1 个汉字照查
    #expect(FileSearch.request(for: "open ")?.isTooShort == false)  // 最近的文件
    // 标点不算字：Spotlight 按词首比，「.x」和「x」一样宽（2026-11-24 本机 6000 多条，主线程卡 0.7 s）
    for query in [" .x", "open .x", "find -a", " c++", " .x ."] {
      #expect(FileSearch.request(for: query)?.isTooShort == true, "\(query)")
    }
    for query in [" .xl", " x.y", " .x report", " 1.5"] {
      #expect(FileSearch.request(for: query)?.isTooShort == false, "\(query)")
    }
  }

  /// 队列上先挑一遍（shortlist）再交给 rank，和全部交给 rank 排出来的一样：随机（带种子，失败时信息里有轮次）的名字、
  /// 时间、深浅、用过的文件和加成；同一次查询分几批交（names 缓存跨批复用）也一样
  @Test func shortlistKeepsRanking() {
    var random = SplitMix(seed: 20_261_124)
    let words = ["report", "rep", "Repo", "季度报告", "readme", "x", "notes", "reply", "2024"]
    for round in 0..<200 {
      let hits = (0..<random.next(below: 161)).map { index in
        let name = (0...random.next(below: 3)).map { _ in words[random.next(below: words.count)] }
          .joined(separator: ["-", " ", ""][random.next(below: 3)])
        let depth = String(repeating: "/d", count: random.next(below: 4))
        return hit("\(depth)/\(index)/\(name).md", daysAgo: Double(random.next(below: 6)))
      }
      let used = Set(hits.filter { _ in random.next(below: 8) == 0 }.map(\.path))
      let boost = { (item: LauncherItem) -> (global: Double, query: Double) in
        used.contains(item.target)
          ? (Double(item.target.count % 7), Double(item.target.count % 3)) : (0, 0)
      }
      let terms = [[], ["rep"], ["re", "no"], ["jidu"], ["x"], ["2024"], ["季度"]][round % 7]
      let expected = FileSearch.rank(hits, terms: terms, boost: boost)
      // 分两批：先交前一半，再交全部（每批都是到目前为止的全部），缓存接着用
      var names: [String: FileSearch.MatchNames] = [:]
      _ = FileSearch.shortlist(
        Array(hits.prefix(hits.count / 2)), terms: terms, used: used, names: &names)
      let picked = FileSearch.shortlist(hits, terms: terms, used: used, names: &names)
      #expect(
        FileSearch.rank(picked, terms: terms, boost: boost) == expected, "round \(round) \(terms)")
    }
  }

  /// 单测用的带种子随机数（SplitMix64）
  private struct SplitMix {
    var seed: UInt64
    mutating func next(below bound: Int) -> Int {
      seed &+= 0x9E37_79B9_7F4A_7C15
      var z = seed
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((z ^ (z >> 31)) % UInt64(bound))
    }
  }

  @Test func queryStringEscapesAndParses() throws {
    let text = FileSearch.queryString(["kitty", #"a"b*c?d\e"#])
    #expect(
      text
        == #"kMDItemFSName == "kitty*"cdw && kMDItemFSName == "a\"b\*c\?d\\e*"cdw && "#
        + FileSearch.notSystem)
    // 系统能解析（转义错了会返回 nil，查询就起不来）
    #expect(NSPredicate(fromMetadataQueryString: text) != nil)
    #expect(NSPredicate(fromMetadataQueryString: FileSearch.recentQuery) != nil)
  }

  @Test func excludesJunkPaths() {
    let excluded = [
      "/Applications/Safari.app", home + "/Library/Caches/x.db",
      home + "/Code/app/node_modules/pkg/README.md", home + "/Code/app/build/out.o",
      home + "/Library/Developer/Xcode/DerivedData/x/y.swift",
    ]
    for path in excluded { #expect(FileSearch.isExcluded(path), "\(path)") }
    let kept = [
      home + "/Downloads/a.dmg", home + "/Library/Mobile Documents/com~apple~CloudDocs/b.md",
      home + "/Library/CloudStorage/Dropbox/c.pdf", home + "/Desktop/build",  // 叫 build 的文件夹本身留着
    ]
    for path in kept { #expect(!FileSearch.isExcluded(path), "\(path)") }
  }

  @Test func kindTitleAndItem() {
    #expect(
      FileSearch.kindTitle(path: "/x/a.dmg", contentType: "com.apple.disk-image-udif") == "DMG")
    #expect(FileSearch.kindTitle(path: "/x/Docs", contentType: "public.folder") == "文件夹")
    #expect(FileSearch.kindTitle(path: "/x/Makefile", contentType: nil) == "文件")
    // .app 是包：算文件，↩ 打开
    #expect(!FileSearch.isFolder("com.apple.application-bundle"))
    let folder = FileSearch.item(hit("/Documents/季度报告", type: "public.folder"))
    #expect(folder.subtitle == "~/Documents" && folder.completion == "~/Documents/季度报告/")
    let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
    #expect(FileSearch.location(of: iCloud + "/周报/09") == "iCloud 云盘/周报/09")
    #expect(FileSearch.location(of: iCloud) == "iCloud 云盘")
    #expect(
      FileSearch.location(of: iCloud + "x") == "~/Library/Mobile Documents/com~apple~CloudDocsx")
    #expect(folder.names.contains("jidubaogao"))  // 拼音也参与匹配
    let file = FileSearch.item(hit("/Downloads/Kitty.dmg"))
    #expect(file.completion == "~/Downloads/Kitty.dmg" && file.contentType != nil)
  }

  /// P3：命中按路径缓存（每批结果都是到目前为止的全部，只转新到的）；查询词里没有拉丁字母时不转拼音，排序不受影响
  @Test func cachesItemsByPathAndSkipsPinyinForChineseQueries() {
    #expect(!FileSearch.needsPinyin(["季度"]) && !FileSearch.needsPinyin(["2024", "报告"]))
    #expect(FileSearch.needsPinyin(["jidu"]) && FileSearch.needsPinyin(["季度", "q3"]))
    let search = FileSearch()
    let report = hit("/Documents/季度报告.pdf")
    #expect(!search.item(report, pinyin: false).names.contains("jidubaogao"))
    #expect(search.item(report, pinyin: true).names.contains("jidubaogao"))  // 要拼音时补转
    // 同一路径再来用缓存（转过拼音的，不要拼音时照用）；清掉之后重新做
    var renamed = report
    renamed.name = "别的.pdf"
    #expect(search.item(renamed, pinyin: false).title == "季度报告.pdf")
    search.forgetItems()
    #expect(search.item(renamed, pinyin: false).title == "别的.pdf")
    let hits = [hit("/Documents/季度报告.pdf"), hit("/Documents/年度季度总结.md", daysAgo: 0)]
    let noBoost: (LauncherItem) -> (global: Double, query: Double) = { _ in (0, 0) }
    #expect(
      FileSearch.rank(
        hits, terms: ["季度"], item: { FileSearch.item($0, pinyin: false) }, boost: noBoost
      ).map(\.title) == FileSearch.rank(hits, terms: ["季度"], boost: noBoost).map(\.title))
  }

  @Test func ranksByMatchUsageAndDate() throws {
    let hits = [
      hit("/Documents/old-report.pdf", daysAgo: 1),
      hit("/Documents/report.pdf", daysAgo: 300),  // 名字（去掉扩展名）完全相同：排最前
      hit("/Desktop/a/b/report-draft.md", daysAgo: 2),
      hit("/Desktop/report-final.md", daysAgo: 2),  // 同分同时间：路径浅的在前
      hit("/Desktop/reportcard.md", daysAgo: 0),
    ]
    let noBoost: (LauncherItem) -> (global: Double, query: Double) = { _ in (0, 0) }
    let ranked = FileSearch.rank(hits, terms: ["report"], boost: noBoost).map(\.title)
    #expect(
      ranked == [
        "report.pdf", "reportcard.md", "report-final.md", "report-draft.md", "old-report.pdf",
      ])
    // 这个查询下用过的（使用记录）排到前面
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let used = FileSearch.item(hits[0])
    for _ in 0..<3 { usage.record(used, query: "report") }
    let boosted = FileSearch.rank(hits, terms: ["report"]) { usage.boost(for: $0, query: "report") }
    #expect(boosted.first?.title == "old-report.pdf")
    // 只输关键词：按时间，从新到旧
    #expect(FileSearch.rank(hits, terms: [], boost: noBoost).first?.title == "reportcard.md")
  }

  /// 拍板 1A 2B：文件结果执行过收起，90 秒内再呼出回到原来的搜索（字全选、选中照旧）；重查到的文件没多出来就不换
  /// （刚开过的那个有了使用加成也不往前挪），多出新文件才换；超过 90 秒、执行的不是文件的照旧清空
  @Test func resumesFileSearchAfterRunning() throws {
    let findMy = AppCatalog.item(path: "/System/Applications/FindMy.app")
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let model = LauncherModel(usage: usage, apps: [findMy])
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let hits = [
      hit("/Desktop/report-a.md"), hit("/Desktop/report-b.md", daysAgo: 2),
      hit("/Desktop/report-c.md", daysAgo: 3),
    ]
    model.query = " report"
    let request = try #require(model.fileRequest)
    model.showFiles(hits, for: request)
    model.selection = 1
    let opened = try #require(model.selectedItem)
    // ↩ 打开第 2 个：execute 会真的打开文件，这里只摆出它留下的样子
    model.lastRun = opened
    model.executed = true
    model.didHide(now: start)
    model.prepareForShow(now: start.addingTimeInterval(80))
    #expect(model.query == " report" && model.resumesQuery && model.selectedItem == opened)
    let shown = model.results
    for _ in 0..<3 { usage.record(opened, query: model.query) }
    model.showFiles(hits, for: request)
    #expect(model.results == shown && model.selectedItem == opened)
    // 多出新文件：换上新排的，选中还在开过的那一个上
    model.showFiles(hits + [hit("/Desktop/report-d.md")], for: request)
    #expect(model.results.count == shown.count + 1 && model.selectedItem == opened)
    // 打了字就照常：新结果换上
    model.query = " repo"
    model.showFiles(hits, for: try #require(model.fileRequest))
    #expect(model.results.count == hits.count)
    // 超过 90 秒：清空
    model.lastRun = model.selectedItem
    model.executed = true
    model.didHide(now: start)
    model.prepareForShow(now: start.addingTimeInterval(91))
    #expect(model.query.isEmpty && !model.resumesQuery)
    // 对着文件以外做的事（⌥↩ 在访达里搜、⌃↩ 网页搜索、⌘, 这些不记 lastRun）：选中的是文件也照旧清空
    model.query = " report"
    model.showFiles(hits, for: try #require(model.fileRequest))
    #expect(model.selectedItem?.kind == .path)
    model.executed = true
    model.didHide(now: start)
    model.prepareForShow(now: start.addingTimeInterval(1))
    #expect(model.query.isEmpty)
    // 收起时 Spotlight 还没回来（列表里还是打字前的那些）：回来后结果到了照常换上
    model.query = " report"
    model.didHide(now: start)
    model.prepareForShow(now: start.addingTimeInterval(1))
    #expect(model.query == " report" && model.results.map(\.target) != hits.map(\.path))
    model.showFiles(hits, for: try #require(model.fileRequest))
    #expect(model.results.count == hits.count)
    // 文件搜索里执行的是整句匹配到的 App（不是文件）：照旧清空
    model.query = "find my"
    model.showFiles(hits, for: try #require(model.fileRequest))
    model.lastRun = try #require(model.results.first { $0.kind == .app })
    model.executed = true
    model.didHide(now: start)
    model.prepareForShow(now: start.addingTimeInterval(1))
    #expect(model.query.isEmpty)
  }

  /// 拍板 3A：文件行多选——⇧↓ 从选中行扩选（不能勾的 App 行跳过）、⌘K 勾了两个以上只给批量动作（find 模式第一项是
  /// 「在访达中显示 N 个」）、Esc 先取消多选（查询还在）、⌘ 点按加减（没在多选时连选中的一起勾）、⇧ 点按选一段、
  /// 不按 ⇧ 移动取消、结果换了看不见的勾去掉
  @Test func multiSelectsFileRows() throws {
    let findMy = AppCatalog.item(path: "/System/Applications/FindMy.app")
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [findMy])
    model.query = "find my"
    let hits = [
      hit("/Desktop/my-a.md"), hit("/Desktop/my-b.md", daysAgo: 2),
      hit("/Desktop/my-c.md", daysAgo: 3),
    ]
    model.showFiles(hits, for: try #require(model.fileRequest))
    let rows = model.results
    #expect(rows.count == 4 && !model.isCheckable(rows[0]) && model.isCheckable(rows[1]))
    let extend = #selector(NSResponder.moveDownAndModifySelection(_:))
    #expect(model.handleCommand(extend))
    #expect(model.checked == [rows[1].id] && model.selection == 1)
    #expect(model.handleCommand(extend))
    #expect(model.checkedItems == [rows[1], rows[2]] && model.selection == 2)
    #expect(String(localized: model.checkedPrimaryTitle) == "在访达中显示 2 个")
    let actions = model.actions.map(\.title)
    #expect(actions.prefix(2) == ["在访达中显示 2 个", "打开 2 个"] && actions.contains("拷贝文件"))
    // 右键一行：勾着的那行给批量动作，没勾的那行对着它自己
    #expect(model.contextActions(for: rows[1]).count == model.actions.count)
    #expect(model.contextActions(for: rows[3]).count != model.actions.count)
    // Esc：先取消多选，查询还在
    #expect(model.handleCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(model.checked.isEmpty && model.query == "find my")
    // ⌘ 点按：没在多选时连选中的一起勾上，再点一下去掉
    model.selection = 1
    model.check(rows[3], range: false)
    #expect(model.checked == [rows[1].id, rows[3].id] && model.selection == 3)
    model.check(rows[3], range: false)
    #expect(model.checked == [rows[1].id])
    // 只勾一个、选中的是别的行：⌘K 也是批量菜单（键位都对着勾的那一个）
    #expect(model.selection == 3 && model.actions.first?.title == "在访达中显示 1 个")
    // ⇧ 点按：从锚点（刚点的第 4 行）到这里能勾的都勾上（App 行跳过）
    model.check(rows[0], range: true)
    #expect(model.checked == [rows[1].id, rows[2].id, rows[3].id])
    // 不按 ⇧ 移动：取消
    #expect(model.handleCommand(#selector(NSResponder.moveUp(_:))))
    #expect(model.checked.isEmpty)
    // 结果换了：看不见的勾去掉，看得见的留着
    model.check(rows[1], range: false)
    model.check(rows[2], range: false)
    model.showFiles([hits[1]], for: try #require(model.fileRequest))
    #expect(model.checkedItems.map(\.target) == [hits[1].path])
    // 收起：勾全清（回到原来的搜索时也不带）
    model.didHide()
    #expect(model.checked.isEmpty)
  }

  @Test func findModeKeysAndWholeQueryApps() throws {
    let findMy = AppCatalog.item(path: "/System/Applications/FindMy.app")
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let model = LauncherModel(usage: usage, apps: [findMy])
    model.query = "find my"
    let request = try #require(model.fileRequest)
    model.showFiles([hit("/Documents/my-notes.md")], for: request)
    // 整句匹配到的 App（「查找」）排最前，↩ 照常打开；文件 ↩ 在访达中显示、⌘↩ 打开
    #expect(model.results.map(\.kind) == [.app, .path])
    #expect(!model.revealsOnReturn(model.results[0]) && model.revealsOnReturn(model.results[1]))
    model.selection = 1
    model.alternate = .command
    #expect(model.alternateSubtitle(for: model.results[1]) == "⌘↩ 打开")
    // 过时的查询结果不覆盖新的（新查询的结果到之前留着上一次的）
    model.query = "open notes"
    model.showFiles([hit("/Documents/stale.md")], for: request)
    #expect(!model.results.contains { $0.title == "stale.md" })
    // 空格开头只要文件
    model.query = " find my"
    model.showFiles([hit("/Documents/my-notes.md")], for: try #require(model.fileRequest))
    #expect(model.results.map(\.kind) == [.path])
    #expect(model.groupTitle == nil && !model.isShowingRecent)
    model.query = " "
    #expect(model.groupTitle == "最近打开和下载的文件" && !model.isShowingRecent)
    model.query = "open x"
    #expect(model.results.isEmpty && model.emptyText == "再输入一个字母")
    // 单输关键词：出补全提示
    model.query = "open"
    #expect(model.fileRequest == nil && model.results.first?.completion == "open ")
  }

  @Test func laterBatchesKeepBestMatchUnlessUserMoved() throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.query = "open report"
    let request = try #require(model.fileRequest)
    // 第一批只有部分结果；第二批来了名字完全相同的：没动过选中就回到第一行（最佳匹配）
    model.showFiles([hit("/Desktop/old-report.md"), hit("/Desktop/reports.md")], for: request)
    model.showFiles(
      [hit("/Desktop/old-report.md"), hit("/Desktop/reports.md"), hit("/Desktop/report.md")],
      for: request)
    #expect(model.selection == 0 && model.results[0].title == "report.md")
    // 按过 ↓：后面的批次按 id 保持选中项
    _ = model.handleCommand(#selector(NSResponder.moveDown(_:)))
    let chosen = model.results[model.selection].id
    model.showFiles(
      [
        hit("/Desktop/report-a.md"), hit("/Desktop/old-report.md"), hit("/Desktop/reports.md"),
        hit("/Desktop/report.md"),
      ], for: request)
    #expect(model.results[model.selection].id == chosen)
  }

  @Test func undeclaredTypesStillCountAsFileResults() {
    // 声明类型的 App 卸载后 Spotlight 还留着 UTI、系统不认：按扩展名兜底，find 的 ↩ 和图标照样按类型走
    let item = FileSearch.item(hit("/Downloads/rules.conf", type: "com.example.undeclared"))
    #expect(item.contentType != nil)
    #expect(FileSearch.item(hit("/Downloads/LICENSE", type: nil)).contentType == .data)
  }

  @Test func folderAccessHint() throws {
    #expect(FileSearch.accessHint(denied: []) == nil)  // 都允许了：不出提示
    #expect(FileSearch.accessHint(denied: nil)?.title == "搜不到桌面、文稿、下载、iCloud 云盘里的文件？")
    #expect(FileSearch.accessHint(denied: ["下载", "文稿"])?.title == "没有权限搜「下载」「文稿」里的文件")
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    var requested = 0
    var hidden = 0
    model.requestFolderAccess = { requested += 1 }
    model.hidePanel = { hidden += 1 }
    model.folderHint = FileSearch.accessHint(denied: nil)
    model.query = "open report"
    model.showFiles([hit("/Desktop/report.md")], for: try #require(model.fileRequest))
    // 提示排在文件后面；没有文件时只剩它（不显示「没有匹配」）
    #expect(model.results.map(\.target).last == FileSearch.accessTarget)
    model.showFiles([], for: try #require(model.fileRequest))
    #expect(model.results.map(\.target) == [FileSearch.accessTarget])
    model.execute(model.results[0])
    #expect(requested == 1 && hidden == 1)
    // 普通搜索不出提示
    model.query = "report"
    #expect(!model.results.contains { $0.target == FileSearch.accessTarget })
  }

  /// 本机冒烟：宿主是本 App，能看到本 App 的身份下 Spotlight 给不给桌面 / 文稿 / 下载里的结果、弹不弹授权框
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_FILES"] != nil))
  func liveSpotlight() async throws {
    let search = FileSearch()
    for request in [
      FileSearch.Request(mode: .open, terms: ["readme"]), .init(mode: .open, terms: []),
    ] {
      let started = Date.now
      let hits = await withCheckedContinuation { continuation in
        var resumed = false
        search.start(request) { hits in  // 结果分批到：只要第一批
          guard !resumed else { return }
          resumed = true
          search.stop()
          continuation.resume(returning: hits)
        }
      }
      let folders = Dictionary(grouping: hits) {
        $0.path.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? "?"
      }.mapValues(\.count)
      print(
        "live \(request.terms): \(hits.count) hits in \(Int(-started.timeIntervalSinceNow * 1000)) ms",
        folders.sorted { $0.value > $1.value })
      #expect(hits.allSatisfy { !FileSearch.isExcluded($0.path) })
    }
  }
}
