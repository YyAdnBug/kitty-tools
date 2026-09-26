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
