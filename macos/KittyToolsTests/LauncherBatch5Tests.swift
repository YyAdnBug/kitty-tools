// 体检第 5 批（启动器·改造与缺陷）单测：收藏与常用（A22 D13）、移除常用可撤销（B38）、收起后保留查询（A27）、
// 目录签名重扫（B31）、App 副标题（A25）、内置动作和菜单栏同一份（A26）、网址 / 文件的动作（D7 C7）、fy 翻译（D10）、
// 兜底只看显式网址（B35）、单输 cb（B33）、右键菜单的动作对着被点的那一项（C8）。
// 全部用内存库、注入的浏览器 / 打开方式 / 废纸篓 / 词典，不读写用户偏好、不真删文件、不真打开 App。

import AppKit
import Carbon.HIToolbox
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

struct LauncherBatch5Tests {
  private func app(_ title: String) -> LauncherItem {
    LauncherItem(
      kind: .app, target: "/Applications/\(title).app", title: title, subtitle: "",
      names: [LauncherMatch.fold(title)])
  }

  private func key(_ code: Int, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: UInt16(code)))
  }

  /// A22 D13：空查询先「收藏」（按加入顺序，⌥⌘↑↓ 调），再用「常用」补足到 8 行；收藏最多 8 个、存进库
  @Test func favoritesLeadTheHome() throws {
    let db = try Database(path: ":memory:")
    let usage = try LauncherUsage(db: db)
    let apps = (1...10).map { app("App\($0)") }
    let model = LauncherModel(usage: usage, apps: apps)
    usage.record(apps[0], query: "")
    usage.record(apps[0], query: "")
    usage.record(apps[1], query: "")
    model.query = ""
    #expect(model.results == [apps[0], apps[1]] && model.groups.map(\.title) == ["常用"])
    // ⌘D 收藏选中的第二行：它挪到「收藏」、选中跟着它
    model.selection = 1
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_D, .command)))
    #expect(model.results == [apps[1], apps[0]] && model.favoriteCount == 1)
    #expect(model.groups == [.init(row: 0, title: "收藏"), .init(row: 1, title: "常用")])
    #expect(model.selectedItem == apps[1] && model.notice == .message("已加入收藏"))
    #expect(model.actions.contains { $0.title == "取消收藏" && $0.shortcut == "⌘D" })
    // 收藏的行不在「常用」里：没有 ⌘⌫ 移除
    #expect(!model.isCommon(apps[1]) && model.isCommon(apps[0]))
    // 再收藏一个，⌥⌘↑ 把它调到第一个
    model.toggleFavorite(apps[5])
    #expect(model.results.prefix(2) == [apps[1], apps[5]])
    model.selection = 1
    #expect(
      model.handleKeyEquivalent(try key(kVK_UpArrow, [.command, .option, .numericPad, .function])))
    #expect(model.results.prefix(2) == [apps[5], apps[1]] && model.selection == 0)
    // 不是收藏的行上 ⌥⌘↓ 不接
    model.selection = 2
    #expect(!model.handleKeyEquivalent(try key(kVK_DownArrow, [.command, .option])))
    // 顺序存进库：换一个 LauncherUsage 读回来一样
    #expect(try LauncherUsage(db: db).favorites.map(\.target) == [apps[5].target, apps[1].target])
    // 满 8 个：第 9 个加不进去，底栏说一声
    for item in apps[2..<9] where !usage.isFavorite(item) { model.toggleFavorite(item) }
    #expect(usage.favorites.count == 8)
    model.toggleFavorite(apps[9])
    #expect(!usage.isFavorite(apps[9]) && model.notice == .warning("收藏最多 8 个，先取消一个"))
    #expect(model.results.count == 8 && model.groups.map(\.title) == ["收藏"])
    // 清空使用记录不动收藏
    usage.clearAll()
    #expect(usage.favorites.count == 8)
    // 带对象模式里的 App 不能收藏
    model.commandTargets = { _ in [apps[9]] }
    model.query = "quit "
    #expect(!model.canFavorite(apps[9]))
  }

  /// B38：「常用」里 ⌘⌫ 移除后底栏「已从常用中移除 · 撤销 ⌘Z」，⌘Z 原样放回并选中它；打字后 ⌘Z 交还输入框
  @Test func forgetCanBeUndone() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let apps = [app("Alpha"), app("Beta")]
    for _ in 0..<3 { usage.record(apps[0], query: "") }
    usage.record(apps[1], query: "be")
    let model = LauncherModel(usage: usage, apps: apps)
    model.query = ""
    #expect(model.results == apps)
    model.selection = 1
    let before = usage.entries
    #expect(model.handleKeyEquivalent(try key(kVK_Delete, .command)))
    #expect(model.results == [apps[0]] && model.notice == .undo("已从常用中移除"))
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_Z, .command)))
    #expect(model.results == apps && model.selectedItem == apps[1] && model.notice == nil)
    #expect(usage.entries == before)  // 全局和「be」两行、分和时间都原样
    // ⌘K 过滤框里有字时 ⌘Z 撤的是过滤框里的字，不撤移除；过滤框空了才撤移除
    let undo = try key(kVK_ANSI_Z, .command)
    model.forget(apps[1])
    model.toggleActions()
    model.actionQuery = "复制"
    #expect(!model.handleKeyEquivalent(undo) && model.results == [apps[0]] && model.showsActions)
    model.actionQuery = ""
    #expect(model.handleKeyEquivalent(undo) && model.results == apps && !model.showsActions)
    // 再移除一次，移动选中后就不能撤了：⌘Z 交还输入框
    model.forget(apps[1])
    #expect(model.handleCommand(#selector(NSResponder.moveDown(_:))))
    #expect(model.notice == nil && !model.handleKeyEquivalent(undo))
  }

  /// A27：没执行就收起，60 秒内再呼出保留查询和选中项（搜索框全选）；执行过、超过 60 秒的清空
  @Test func keepsQueryAfterDismissWithoutRunning() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let apps = [app("Safari"), app("Slack"), app("Sketch")]
    let model = LauncherModel(usage: usage, apps: apps)
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    model.query = "s"
    model.selection = 2
    let selected = try #require(model.selectedItem)
    model.didHide(now: start)
    model.prepareForShow(now: start.addingTimeInterval(30))
    #expect(model.query == "s" && model.selectedItem == selected && model.resumesQuery)
    // 超过 60 秒：照旧清空
    model.didHide(now: start)
    model.prepareForShow(now: start.addingTimeInterval(61))
    #expect(model.query.isEmpty && !model.resumesQuery)
    // quit 空格的列表再呼出时重列：收起期间退出了的 App 不在、新开的在
    var running = [apps[0], apps[1]]
    model.commandTargets = { _ in running }
    model.query = "quit "
    #expect(model.results == [apps[0], apps[1]])
    model.didHide(now: start)
    running = [apps[1], apps[2]]
    model.prepareForShow(now: start.addingTimeInterval(5))
    #expect(model.query == "quit " && model.results == [apps[1], apps[2]])
    // 执行过（打开、运行、⌘C 这类收起面板的）不留（运行内置动作：runAction 是空的，不碰剪贴板）
    model.hidePanel = { model.didHide(now: start) }
    model.query = "设置"
    model.execute(try #require(model.results.first { $0.kind == .action }))
    model.prepareForShow(now: start.addingTimeInterval(1))
    #expect(model.query.isEmpty)
  }

  /// B31：应用程序目录里放进一个 .app，目录的修改时间就变了（呼出前据此重扫）
  @Test func appDirectorySignatureChanges() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let before = AppCatalog.signature(of: [root.path, "/no/such/dir"])
    #expect(before[0] != nil && before[1] == nil)
    Thread.sleep(forTimeInterval: 0.01)
    try FileManager.default.createDirectory(
      at: root.appending(path: "New.app"), withIntermediateDirectories: true)
    let after = AppCatalog.signature(of: [root.path, "/no/such/dir"])
    #expect(after != before)
    #expect(AppCatalog.signature() == AppCatalog.signature())
    // 要不要重扫：没扫过要；签名变了要；没变不要
    #expect(LauncherModel.needsRescan(scannedAt: nil, scanned: before, now: before))
    #expect(LauncherModel.needsRescan(scannedAt: .now, scanned: before, now: after))
    #expect(!LauncherModel.needsRescan(scannedAt: .now, scanned: after, now: after))
  }

  /// D13（评审）：还原不出来的收藏（文件已删）直接删掉，不占 8 个名额、不挡 ⌥⌘↑↓；钉图两项不能收藏
  @Test func missingFavoritesAreDropped() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let apps = (1...8).map { app("App\($0)") }
    let model = LauncherModel(usage: usage, apps: apps)
    let files = (0..<2).map {
      FileManager.default.temporaryDirectory.appending(path: "kitty-fav-\(UUID().uuidString)-\($0)")
    }
    defer { for file in files { try? FileManager.default.removeItem(at: file) } }
    for file in files { try Data().write(to: file) }
    let docs = files.map {
      LauncherModel.item(kind: .path, target: $0.path, title: $0.lastPathComponent)
    }
    // 空查询：夹在两个收藏中间的文件删掉后，⌥⌘↑ 换的是看得见的邻居
    for item in [apps[0], docs[0], apps[1]] { model.toggleFavorite(item) }
    model.query = ""
    #expect(model.results.prefix(3) == [apps[0], docs[0], apps[1]])
    try FileManager.default.removeItem(at: files[0])
    model.query = "a"
    model.query = ""
    #expect(model.favoriteCount == 2 && usage.favorites.count == 2)
    model.selection = 1
    #expect(model.handleKeyEquivalent(try key(kVK_UpArrow, [.command, .option])))
    #expect(model.results.prefix(2) == [apps[1], apps[0]] && model.selection == 0)
    // 有查询时（空查询没刷新过）收藏满 8 个、其中一个文件删了：⌘D 照样加得进去
    for item in [docs[1]] + apps[2..<7] { model.toggleFavorite(item) }
    #expect(usage.favorites.count == 8)
    try FileManager.default.removeItem(at: files[1])
    model.query = "App8"
    model.toggleFavorite(apps[7])
    #expect(usage.isFavorite(apps[7]) && !usage.isFavorite(docs[1]) && usage.favorites.count == 8)
    // 只在有钉图时才有的动作不能收藏
    let pins = LauncherItem.actions(.init(pinsHidden: false)).filter {
      $0.target.hasPrefix("pins-")
    }
    #expect(pins.count == 2 && pins.allSatisfy { !model.canFavorite($0) })
  }

  /// A25：标准目录（及一层子文件夹、访达）里的 App 副标题留空，别处的写所在位置；中文名 App 仍写英文文件名
  @Test func appSubtitleShowsLocationOutsideStandardFolders() {
    #expect(AppCatalog.location(of: "/Applications/Safari.app").isEmpty)
    #expect(AppCatalog.location(of: "/Applications/Microsoft Office/Word.app").isEmpty)
    #expect(AppCatalog.location(of: "/System/Applications/Utilities/Terminal.app").isEmpty)
    #expect(AppCatalog.location(of: SystemCommands.finderPath).isEmpty)
    #expect(AppCatalog.location(of: NSHomeDirectory() + "/Downloads/Foo.app") == "~/Downloads")
    #expect(AppCatalog.location(of: "/Volumes/Xcode/Xcode.app") == "/Volumes/Xcode")
    #expect(AppCatalog.item(path: "/System/Applications/Calculator.app").subtitle == "Calculator")
    let chess = AppCatalog.item(path: "/System/Applications/Chess.app")
    #expect(chess.subtitle == (chess.title == "Chess" ? "" : "Chess"))
  }

  /// A26：内置动作和菜单栏同名同序（启动器自己除外），老的 6 个 id 不变；复制即译写开没开，有钉图才有钉图两项，
  /// 正式版才有检查更新
  @Test func builtInActionsFollowTheMenu() {
    let plain = LauncherItem.actions()
    #expect(
      plain.map(\.target) == [
        "clipboard", "pause-clipboard", "selectionTranslate", "translate-input", "translateReplace",
        "translate-screenshot", "copyToTranslate", "screenshot", "screenshotLastRegion", "ocr",
        "settings", "shortcuts", "about",
      ])
    for action in HotKeyAction.allCases where action != .launcher {
      let item = plain.first { $0.hotKeyAction == action }
      #expect(item?.title == action.title && item?.symbol == action.symbol, "\(action)")
    }
    #expect(plain.first { $0.target == "copyToTranslate" }?.subtitle == "已关闭")
    #expect(plain.first { $0.target == "pause-clipboard" }?.subtitle == "正在记录")
    let busy = LauncherItem.actions(
      .init(recordingPaused: true, copyToTranslate: true, pinsHidden: true, checksUpdates: true))
    #expect(busy.first { $0.target == "copyToTranslate" }?.subtitle == "已开启")
    #expect(busy.first { $0.target == "pause-clipboard" }?.subtitle == "已暂停")
    #expect(busy.map(\.title).contains("显示全部钉图") && busy.last?.target == "updates")
    #expect(
      Array(busy.map(\.target)[9...11]) == ["ocr", "pins-toggle", "pins-close"])
    #expect(LauncherItem.actions(.init(pinsHidden: false)).contains { $0.title == "隐藏全部钉图" })
    // 英文别名、拼音都能搜到
    let replace = plain.first { $0.target == "translateReplace" }!
    #expect(LauncherMatch.score("replace", item: replace) > 0)
    #expect(
      LauncherMatch.score("hcfy", item: plain.first { $0.target == "selectionTranslate" }!) > 0)
  }

  /// D7：网址 ⌘K 有「用 X 打开」（默认浏览器以外的每一个，第一个是 ⌘↩）、Markdown 链接 ⇧⌘C、复制标题；
  /// 没有第二个浏览器时 ⌘↩ 不写、按了只响提示音
  @Test func webLinkActions() throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.browsers = {
      [URL(filePath: "/Applications/TestFox.app"), URL(filePath: "/Applications/Other.app")]
    }
    model.query = "linux.do"
    let link = try #require(model.selectedItem)
    #expect(link.kind == .url && model.isWebLink(link))
    #expect(model.commandReturnAction(for: link)?.title == "用「TestFox」打开")
    model.alternate = .command
    #expect(model.alternateSubtitle(for: link) == "⌘↩ 用「TestFox」打开")
    let actions = model.actions
    #expect(
      actions.filter { $0.title.hasPrefix("用「") && $0.title.hasSuffix("」打开") }.map(\.shortcut) == [
        "⌘↩", nil,
      ])
    #expect(actions.contains { $0.title == "复制为 Markdown 链接" && $0.shortcut == "⇧⌘C" })
    #expect(actions.contains { $0.title == "复制标题" } && actions.contains { $0.title == "加入收藏" })
    #expect(
      LauncherModel.markdownLink(title: "a [b]", url: "https://x.com/a b)")
        == "[a \\[b\\]](https://x.com/a%20b%29)")
    // 没有第二个浏览器：⌘↩ 没有，副标题不写
    model.browsers = { [] }
    model.prepareForShow()
    model.query = "linux.do"
    #expect(
      model.commandReturnAction(for: link) == nil && model.alternateSubtitle(for: link) == nil)
    #expect(!model.actions.contains { $0.shortcut == "⌘↩" })
    // mailto / 快捷链接里的 maps:// 不算网页
    #expect(
      !model.isWebLink(LauncherItem(kind: .url, target: "maps://?q=x", title: "", subtitle: "")))
  }

  /// C7：文件搜索的文件 ⌘K 有快速查看 ⌘Y、打开方式（默认的标「默认」）、移到废纸篓（行原地删掉）；→ 打开动作菜单
  @Test func fileActions() async throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    var opened = 0
    var trashed: [URL] = []
    model.applications = { _ in
      [
        (URL(filePath: "/Applications/Editor.app"), true),
        (URL(filePath: "/Applications/Other.app"), false),
      ]
    }
    model.openQuickLook = { opened += 1 }
    model.recycle = { trashed.append($0) }
    model.query = "open 报告"
    let request = try #require(model.fileRequest)
    let home = NSHomeDirectory()
    model.showFiles(
      [
        FileSearch.Hit(
          path: home + "/Documents/报告.txt", name: "报告.txt", contentType: "public.plain-text",
          date: .now),
        FileSearch.Hit(
          path: home + "/Documents/报告2.txt", name: "报告2.txt", contentType: "public.plain-text",
          date: .distantPast),
      ], for: request)
    let file = try #require(model.selectedItem)
    #expect(model.isFile(file))
    let actions = model.actions
    #expect(actions.contains { $0.title == "快速查看" && $0.shortcut == "⌘Y" })
    let openers = actions.filter { $0.title.hasPrefix("用「") && $0.title.hasSuffix("」打开") }
    #expect(
      openers.map(\.title) == ["用「Editor」打开", "用「Other」打开"] && openers.map(\.detail) == ["默认", nil])
    let trash = try #require(actions.first { $0.title == "移到废纸篓" })
    #expect(trash.isDestructive && trash.shortcut == nil)
    // ⌘Y 打开预览；不是文件的行 ⌘Y 只响提示音
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_Y, .command)))
    #expect(
      model.isQuickLooking && model.showsQuickLookContent && opened == 1
        && model.quickLookURL?.lastPathComponent == "报告.txt")
    #expect(
      model.handleCommand(#selector(NSResponder.cancelOperation(_:))) && !model.isQuickLooking)
    // 缩回动画放完（onHide）才拆掉预览；拆掉后看不见的浮层不再跟着选中项生成预览
    #expect(model.showsQuickLookContent)
    model.quickLookDidHide()
    #expect(!model.showsQuickLookContent)
    // 预览开着时 ⌘K：先缩回预览再开菜单（菜单画在被预览盖住的启动器里，不然看不见）
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_Y, .command)) && model.isQuickLooking)
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_K, .command)))
    #expect(!model.isQuickLooking && model.showsActions)
    model.showsActions = false
    model.quickLookDidHide()
    // 移到废纸篓：行原地删掉，选中留在原位置
    trash.run()
    for _ in 0..<50 where model.results.count == 2 { await Task.yield() }
    #expect(
      trashed.map(\.lastPathComponent) == ["报告.txt"] && model.results.map(\.title) == ["报告2.txt"])
    // → 在空搜索框（没有字段编辑器时按「光标在末尾」算）有选中项时打开动作菜单
    model.query = ""
    model.query = "open 报告"
    model.showFiles(
      [
        FileSearch.Hit(
          path: home + "/Documents/a.txt", name: "a.txt", contentType: "public.plain-text",
          date: .now)
      ],
      for: try #require(model.fileRequest))
    #expect(!model.handleCommand(#selector(NSResponder.moveRight(_:))))  // 有字：照常移光标
  }

  /// → 打开动作菜单（光标在末尾、有选中项时），菜单开着过滤词为空时 ← 关掉
  @Test func rightArrowOpensActions() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let safari = app("Safari")
    usage.record(safari, query: "")
    let model = LauncherModel(usage: usage, apps: [safari])
    model.query = ""
    #expect(model.handleCommand(#selector(NSResponder.moveRight(_:))) && model.showsActions)
    #expect(model.handleCommand(#selector(NSResponder.moveLeft(_:))) && !model.showsActions)
  }

  /// C8：右键菜单是和 ⌘K 同一份动作，但对着被点的那一项（不是选中项）
  @Test func contextMenuActsOnClickedRow() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let apps = [app("Alpha"), app("Beta")]
    for item in apps { usage.record(item, query: "") }
    let model = LauncherModel(usage: usage, apps: apps)
    model.query = ""
    let other = model.results[1]
    #expect(model.selection == 0)
    let complete = try #require(model.actions(for: other).first { $0.shortcut == "⇥" })
    complete.run()
    #expect(model.query == other.title)
  }

  /// D10：「fy 文本」只有一行，↩ 收起启动器、交给翻译浮窗；单个英文词副标题换成词典释义；只输 fy 出补全提示
  @Test func translateKeyword() async throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    var translated: [String] = []
    var hides = 0
    model.translate = { translated.append($0) }
    model.hidePanel = { hides += 1 }
    model.lookUp = { $0 == "hello" ? "used as a greeting" : nil }
    model.query = "FY hello"
    let row = try #require(model.results.first)
    #expect(model.results.count == 1 && row.kind == .translate && row.title == "翻译「hello」")
    #expect(row.hotKeyAction == .inputTranslate && model.primaryAction(for: row).title == "翻译")
    await model.definitionLookup()
    #expect(model.results.first?.subtitle == "used as a greeting")
    model.execute(try #require(model.results.first))
    #expect(translated == ["hello"] && hides == 1)
    // 不是单个英文词：不查词典
    model.query = "fy 你好 世界"
    await model.definitionLookup()
    #expect(model.results.map(\.subtitle) == [""])
    model.query = "fy"
    #expect(model.results.first?.completion == "fy ")
    #expect(!LauncherItem.Kind.translate.isRecorded)
  }

  /// B35：「http 缓存」没有本地结果时照样有兜底；明写 https:// 的、直达网址不再兜底
  @Test func fallbackSkipsOnlyExplicitURLs() throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.query = "http 缓存"
    #expect(model.results.contains { $0.kind == .search })
    model.query = "https 证书"
    #expect(model.results.contains { $0.kind == .search })
    model.query = "https://a.com"
    #expect(model.results.first?.kind == .url && !model.results.contains { $0.kind == .search })
    model.query = "linux.do"
    #expect(!model.results.contains { $0.kind == .search })
  }

  /// B33：单输 cb 时 cb 那一行排第一，以 cb 开头的 App 照常列在后面；不分大小写
  @Test func clipKeywordLeadsLocalResults() throws {
    let reader = app("CBZ Reader")
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [reader])
    model.query = "cb"
    #expect(model.results.first?.kind == .clip && model.results.contains(reader))
    model.query = "Cb"
    #expect(model.results.first?.kind == .clip)
    model.query = "cb 会议"
    #expect(model.results.map(\.kind) == [.clip])
  }
}
