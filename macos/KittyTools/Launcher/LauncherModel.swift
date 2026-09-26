// 启动器状态与操作：查询 → 结果，空查询显示「最近使用」。结果顺序：直达网址 / 路径、计算结果、关键词搜索，
// 然后 App 目录 + 内置动作 + 快捷链接 / 搜索提示 + 书签 + 用过的网址 / 文件按匹配分排序，网页搜索兜底；
// 「cb [关键词]」只列剪贴板文本；「open / find 词」、空格开头搜文件（FileSearch，结果异步到，先留着上一次的结果，
// 后面仍接整句匹配到的 App）。键盘（对标 Alfred）：↑↓ 循环、↩ 执行（计算结果、cb 是粘贴，find 的文件是在访达中
// 显示）、⌘↩ 在访达中显示（计算结果、cb 只复制，find 的文件是打开）、⌥↩ 在访达里搜索、⌃↩ 网页搜索（按住修饰键时
// 选中行的副标题换成替代动作）、Tab 补全、
// ⌘C 复制路径 / 网址、⌘1–9 执行第 N 项、「最近使用」里 ⌘⌫ 移除一项、Esc 先清空再关闭；
// 单击选中、双击执行（和剪贴板面板一致）。执行成功才收起并记使用（修旧版先收起、失败提示看不见，§11 #33）。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class LauncherModel {
  var query = "" { didSet { search() } }
  private(set) var results: [LauncherItem] = []
  var selection = 0
  /// 选中高亮这次怎么移动（Whisker §4）：键盘单按 snap，连发和结果刷新不动画，鼠标点选 glide
  private(set) var selectionMotion = Style.Motion.instant
  /// 执行失败的提示（面板不收起）
  private(set) var error: String?
  /// 按住的修饰键：选中行的副标题换成它对应的替代动作（面板的 onModifierKeysChanged 推过来）
  var alternate = Alternate.none
  /// 文件搜索模式（open / find / 空格开头）；nil = 普通搜索
  private(set) var fileRequest: FileSearch.Request?
  /// 没有结果时显示的话。和结果一起换：文件搜索还在查时留着上一句，不闪「没有匹配」
  private(set) var emptyText = "没有匹配的结果"

  enum Alternate {
    case none, command, option, control
  }

  @ObservationIgnored let usage: LauncherUsage
  @ObservationIgnored private var apps: [LauncherItem] = []
  @ObservationIgnored private var appsScannedAt: Date?
  /// 单测 / 截图自检：传入固定的 App 列表，不扫本机、不查 Spotlight（文件结果由 showFiles 直接给）
  @ObservationIgnored private let isFixture: Bool
  @ObservationIgnored private let files = FileSearch()
  /// 这次文件搜索已经显示过一批：后面的批次到了保持选中项，不跳回第一行
  @ObservationIgnored private var shownFileRequest: FileSearch.Request?
  // 以下由 AppDelegate 接上
  @ObservationIgnored var hidePanel: () -> Void = {}
  @ObservationIgnored var runAction: (String) -> Void = { _ in }
  /// 面板按内容伸缩高度（顶边不动）
  @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }
  /// cb 指令：按关键词搜剪贴板历史（ClipboardStore.search）；复制走剪贴板面板的逻辑（展开片段、保留格式）
  @ObservationIgnored var searchClipboard: (String) -> [ClipItem] = { _ in [] }
  @ObservationIgnored var copyClip: (UUID) -> Void = { _ in }
  /// cb 粘贴过的那条挪到剪贴板历史最前（和面板里粘贴一样）
  @ObservationIgnored var bumpClip: (UUID) -> Void = { _ in }
  /// 文件搜索的授权提示 ↩：没问过就逐个弹系统框，问过就打开系统设置
  @ObservationIgnored var requestFolderAccess: () -> Void = {}
  /// 文件结果最后一行的授权提示：每次呼出后第一次进文件搜索时算一次（要读受保护目录，问过之前不读）。
  /// ponytail: 授权被重置（tccutil reset、撤掉完全磁盘访问）后，第一次进文件搜索时系统会弹框
  @ObservationIgnored var folderHint: LauncherItem?
  @ObservationIgnored private var checksFolderAccess = false
  /// 用户按过 ↑↓ / 点选过：文件结果后续批次到了才按 id 保持选中项，否则回到第一行（最佳匹配）
  @ObservationIgnored private var userMovedSelection = false

  static let recentLimit = 8
  static let rescanInterval: TimeInterval = 300

  init(usage: LauncherUsage, apps: [LauncherItem]? = nil) {
    self.usage = usage
    isFixture = apps != nil
    if let apps {
      self.apps = apps
      appsScannedAt = .now
    }
  }

  /// 空查询的「最近使用」（一个空格是文件搜索，不算）
  var isShowingRecent: Bool {
    fileRequest == nil && query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// 列表上方的分组标题：空查询「最近使用」，文件搜索只输了关键词时「最近的文件」
  var groupTitle: String? {
    if isShowingRecent { return "最近使用" }
    return fileRequest?.terms.isEmpty == true ? "最近打开和下载的文件" : nil
  }

  /// 启动时和第一次呼出前扫 App 目录
  func rescanApps() {
    guard !isFixture else { return }
    apps = AppCatalog.scan()
    appsScannedAt = .now
  }

  func prepareForShow() {
    if appsScannedAt == nil { rescanApps() }
    checksFolderAccess = !isFixture
    search()
  }

  /// 收起后清空查询；App 目录超过 5 分钟就趁没人看时重扫。
  /// ponytail: 刚装的 App 最迟在下一次收起面板后出现；嫌慢再改成监听应用程序目录
  func didHide() {
    query = ""
    error = nil
    if let scannedAt = appsScannedAt, Date.now.timeIntervalSince(scannedAt) > Self.rescanInterval {
      rescanApps()
    }
  }

  private func search() {
    error = nil
    selectionMotion = .instant
    selection = 0
    userMovedSelection = false
    shownFileRequest = nil
    fileRequest = FileSearch.request(for: query)
    if let fileRequest {
      searchFiles(fileRequest)
      return
    }
    files.stop()
    emptyText = "没有匹配的结果"
    let query = query.trimmingCharacters(in: .whitespaces)
    if query.isEmpty {
      results = recent()
      return
    }
    if let clipQuery = Self.clipQuery(query) {
      results = clipItems(clipQuery)
      return
    }
    let direct = DirectItems.items(for: query)
    let keyword = WebSearch.keywordItem(for: query)
    let prompts = WebSearch.promptItems(for: query)
    let filePrompts = FileSearch.promptItems(for: query)
    let top =
      direct + [Calculator.item(for: query), keyword].compactMap { $0 } + prompts.exact
      + filePrompts.exact
    // 书签至少 2 个字才搜（1 个字母命中太多）
    let bookmarks = query.count >= 2 ? Bookmarks.items() : []
    let local = LauncherMatch.rank(
      apps + LauncherItem.actions + WebSearch.quicklinkItems() + bookmarks
        + usedLocations(excluding: bookmarks), query: query
    ) { usage.boost(for: $0, query: query) }
    // 兜底默认只在没有本地结果时出现（和 Alfred 一样；以前带空格的查询把兜底排到匹配的 App 前面），
    // 设置里可改成总是附在最后。显式的 http(s) 网址、存在的路径就不再兜底
    let explicit = direct.contains { $0.kind == .path } || query.lowercased().hasPrefix("http")
    let wantsFallback =
      local.isEmpty || UserDefaults.standard.bool(forKey: Prefs.launcherFallbackAlways)
    let fallback =
      keyword == nil && wantsFallback && !explicit ? WebSearch.fallbackItems(for: query) : []
    // 直达项和书签 / 用过的网址可能是同一项：按 id 去重，保留靠前的
    var seen = Set<String>()
    results = (top + local + prompts.partial + filePrompts.partial + fallback).filter {
      seen.insert($0.id).inserted
    }
  }

  /// 文件搜索：查询还在跑时留着上一次的结果（约 40 ms 后换掉，免得列表先空再长）；1 个字母不查
  private func searchFiles(_ request: FileSearch.Request) {
    guard !request.isTooShort else {
      files.stop()
      results = []
      emptyText = "再输入一个字母"
      return
    }
    guard !isFixture else { return }
    if checksFolderAccess {
      checksFolderAccess = false
      folderHint = FileSearch.accessHint(denied: Permissions.deniedFolders())
    }
    files.start(request) { [weak self] hits in self?.showFiles(hits, for: request) }
  }

  /// 文件结果到了（分批，每批都是到目前为止的全部）：排好序，前面放整句（连关键词）匹配到的 App / 内置动作
  /// （「find my」照样能打开「查找」，修旧版被文件搜索截走，§11 #38；关键词也得匹配上，所以很少见）。
  /// 空格开头是明确要搜文件，不放
  func showFiles(_ hits: [FileSearch.Hit], for request: FileSearch.Request) {
    guard request == fileRequest else { return }  // 已经换了查询
    let found = FileSearch.rank(hits, terms: request.terms) { usage.boost(for: $0, query: query) }
    let whole = query.trimmingCharacters(in: .whitespaces)
    let named =
      request.terms.isEmpty || query.first?.isWhitespace == true
      ? []
      : LauncherMatch.rank(apps + LauncherItem.actions, query: whole) {
        usage.boost(for: $0, query: whole)
      }
    let selected = results.indices.contains(selection) ? results[selection].id : nil
    var seen = Set<String>()
    results = (named + found + [folderHint].compactMap { $0 }).filter {
      seen.insert($0.id).inserted
    }
    emptyText = request.terms.isEmpty ? "最近没有打开或下载的文件" : "没有匹配的文件"
    selectionMotion = .instant
    selection =
      request == shownFileRequest && userMovedSelection
      ? selected.flatMap { id in results.firstIndex { $0.id == id } } ?? 0 : 0
    shownFileRequest = request
  }

  /// 「cb」或「cb 关键词」
  static func clipQuery(_ query: String) -> String? {
    guard query == "cb" || query.hasPrefix("cb ") else { return nil }
    return String(query.dropFirst(2)).trimmingCharacters(in: .whitespaces)
  }

  /// cb：最近的文本条目，最多 30 条；↩ 粘贴全文
  private func clipItems(_ query: String) -> [LauncherItem] {
    searchClipboard(query).lazy.filter { $0.kind == .text }.prefix(30).map { clip in
      let ago = clip.copiedAt.formatted(
        .relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))
      return LauncherItem(
        kind: .clip, target: clip.id.uuidString, title: clip.title,
        subtitle: [clip.sourceName, ago, "↩ 粘贴"].compactMap { $0 }.joined(separator: " · "),
        payload: clip.text)
    }
  }

  /// 用过的网址 / 文件：不在任何目录里，靠使用记录找回来；和书签同一网址（不分大小写）时只留书签
  private func usedLocations(excluding bookmarks: [LauncherItem]) -> [LauncherItem] {
    let bookmarked = Set(bookmarks.map { $0.target.lowercased() })
    return usage.entries.values
      .filter {
        $0.query.isEmpty && ($0.kind == .url || $0.kind == .path)
          && !bookmarked.contains($0.target.lowercased())
      }
      .map(Self.item(for:))
  }

  static func item(for entry: LauncherUsage.Entry) -> LauncherItem {
    LauncherItem(
      kind: entry.kind, target: entry.target, title: entry.title,
      subtitle: entry.kind == .url
        ? entry.target : (entry.target as NSString).abbreviatingWithTildeInPath,
      names: [entry.title, entry.target].map(LauncherMatch.fold))
  }

  /// 按全局使用分取前几条，只留还能还原的（App 还在、文件还在）
  private func recent() -> [LauncherItem] {
    var items: [LauncherItem] = []
    // 全部按分排好再往下找：前面几条失效（App 已卸载、文件已删）时后面的补上
    for entry in usage.top(Int.max) where items.count < Self.recentLimit {
      switch entry.kind {
      case .app:
        if let app = apps.first(where: { $0.target == entry.target }) {
          items.append(app)
        } else if FileManager.default.fileExists(atPath: entry.target) {
          items.append(AppCatalog.item(path: entry.target))  // 应用程序目录以外的 App
        }
      case .action:
        if let action = LauncherItem.actions.first(where: { $0.target == entry.target }) {
          items.append(action)
        }
      case .url:
        items.append(Self.item(for: entry))
      case .path:
        if FileManager.default.fileExists(atPath: entry.target) {
          items.append(Self.item(for: entry))
        }
      case .search, .calculation, .clip, .prompt:
        break  // 不记使用，不会出现
      }
    }
    return items
  }

  // MARK: 执行

  func execute(_ item: LauncherItem) {
    switch item.kind {
    case .calculation:
      paste { Paster.write(string: item.payload ?? "") }
    case .clip:
      // 不借剪贴板面板的 paste：它会连带收起钉住的剪贴板面板、提交还能撤销的删除
      guard let id = UUID(uuidString: item.target) else { return }
      if paste({ copyClip(id) }) { bumpClip(id) }
    case .prompt where item.target == FileSearch.accessTarget:
      hidePanel()
      requestFolderAccess()
    case .prompt:
      if let completion = item.completion { query = completion }
    case .search:
      guard let url = URL(string: item.target), NSWorkspace.shared.open(url) else {
        error = "打不开搜索页"
        return
      }
      hidePanel()
    case .action:
      usage.record(item, query: query)
      hidePanel()
      runAction(item.target)
    case .app, .path:
      if revealsOnReturn(item) {
        reveal(item)
      } else {
        open(URL(filePath: item.target), item)
      }
    case .url:
      guard let url = URL(string: item.target) else {
        error = "打不开「\(item.title)」"
        return
      }
      open(url, item)
    }
  }

  /// find 搜到的文件：↩ 在访达中显示、⌘↩ 打开（和 open 反过来）
  func revealsOnReturn(_ item: LauncherItem) -> Bool {
    fileRequest?.mode == .find && item.contentType != nil
  }

  /// 在访达里选中（find 的 ↩ 记使用，和打开一样）
  private func reveal(_ item: LauncherItem) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
    usage.record(item, query: query)
    hidePanel()
  }

  /// ⌥↩ / ⌃↩ 搜的文字：文件搜索时去掉关键词
  private var searchText: String {
    fileRequest.map { $0.terms.joined(separator: " ") }
      ?? query.trimmingCharacters(in: .whitespaces)
  }

  /// 计算结果、cb：收起后写剪贴板、发 ⌘V 粘贴回原 App（和剪贴板面板一样不激活本 App、不等待）。
  /// 没有辅助功能授权时只复制，面板留着提示去授权。返回是否粘贴了
  @discardableResult
  private func paste(_ copy: () -> Void) -> Bool {
    guard Permissions.isAccessibilityTrusted else {
      copy()
      error = "已复制到剪贴板。授权辅助功能后才能直接粘贴"
      Permissions.requestAccessibility()
      return false
    }
    hidePanel()
    copy()
    _ = Paster.pasteToFrontmost()
    return true
  }

  /// ⌥↩：在访达里用 Spotlight 搜当前查询（不需要额外授权）
  private func searchInFinder() {
    let text = searchText
    guard !text.isEmpty, NSWorkspace.shared.showSearchResults(forQueryString: text) else {
      return NSSound.beep()
    }
    hidePanel()
  }

  /// ⌃↩：不管有没有本地结果，用第一个兜底搜索搜当前查询
  private func searchWeb() {
    let text = searchText
    guard !text.isEmpty, let engine = WebSearch.primary(),
      let url = URL(string: WebSearch.url(engine, text))
    else { return NSSound.beep() }
    guard NSWorkspace.shared.open(url) else {
      error = "打不开搜索页"
      return
    }
    hidePanel()
  }

  /// Tab：把选中项补进输入框（计算结果接着算、目录接着往下找、「关键词 」接着输搜索词）
  func complete() {
    guard let item = selectedItem, let text = Self.completion(for: item) else { return }
    query = text
  }

  static func completion(for item: LauncherItem) -> String? {
    if let completion = item.completion { return completion }
    switch item.kind {
    case .app, .action, .url: return item.title
    case .path:
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: item.target, isDirectory: &isDirectory)
      let path = (item.target as NSString).abbreviatingWithTildeInPath
      return exists && isDirectory.boolValue && !path.hasSuffix("/") ? path + "/" : path
    case .search, .calculation, .clip, .prompt: return nil
    }
  }

  /// 按住修饰键时选中行的副标题：说明松手前按 ↩ 会做什么
  func alternateSubtitle(for item: LauncherItem) -> String? {
    let text = searchText
    switch alternate {
    case .none:
      return nil
    case .command:
      switch item.kind {
      case .app, .path: return revealsOnReturn(item) ? "⌘↩ 打开" : "⌘↩ 在访达中显示"
      case .calculation, .clip: return "⌘↩ 只复制，不粘贴"
      default: return nil
      }
    case .option:
      return text.isEmpty ? nil : "⌥↩ 在访达里搜索「\(text)」"
    case .control:
      guard !text.isEmpty, let engine = WebSearch.primary() else { return nil }
      return "⌃↩ 用 \(engine.name) 搜索「\(text)」"
    }
  }

  private func open(_ url: URL, _ item: LauncherItem) {
    guard NSWorkspace.shared.open(url) else {
      error = "打不开「\(item.title)」"
      return
    }
    usage.record(item, query: query)
    hidePanel()
  }

  func click(_ item: LauncherItem) {
    if NSApp.currentEvent?.clickCount == 2 {
      execute(item)
    } else if let index = results.firstIndex(of: item) {
      selectionMotion = .glide
      selection = index
      userMovedSelection = true
    }
  }

  private var selectedItem: LauncherItem? {
    results.indices.contains(selection) ? results[selection] : nil
  }

  // MARK: 键盘

  func handleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)): move(by: -1)
    case #selector(NSResponder.moveDown(_:)): move(by: 1)
    // ⌥↩ 来的是 insertNewlineIgnoringFieldEditor:、⌃↩ 是 insertLineBreak:；⌃O 这类别的键绑定也会发这两个，
    // 所以要确认真是回车键，再按当时按住的修饰键分（别的键绑定吞掉，不做事）
    case #selector(NSResponder.insertNewline(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      guard let event = NSApp.currentEvent,
        [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
      else { return true }
      if event.modifierFlags.contains(.option) {
        searchInFinder()
      } else if event.modifierFlags.contains(.control) {
        searchWeb()
      } else if let selectedItem {
        execute(selectedItem)
      }
    case #selector(NSResponder.insertTab(_:)):
      complete()  // 没得补也吞掉，不让焦点跳到别的控件
    case #selector(NSResponder.cancelOperation(_:)):
      guard !query.isEmpty else { return false }  // 没有查询：交给窗口关闭
      query = ""
    default: return false
    }
    return true
  }

  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
      return false
    }
    let fieldHasSelection =
      ((event.window?.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
    switch Int(event.keyCode) {
    case kVK_Return:
      guard let item = selectedItem else { return true }
      switch item.kind {
      case .app, .path:
        if revealsOnReturn(item) {
          open(URL(filePath: item.target), item)  // find 搜到的文件反过来：⌘↩ 打开（成功才收起）
          return true
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
      case .calculation:
        Paster.write(string: item.payload ?? "")
      case .clip:
        guard let id = UUID(uuidString: item.target) else { return true }
        copyClip(id)
      default:
        return true
      }
      hidePanel()
    // 「最近使用」里 ⌘⌫：忘掉这一项（有查询时 ⌘⌫ 照常删到行首）
    case kVK_Delete where isShowingRecent:
      guard let item = selectedItem, item.kind.isRecorded else { return true }
      usage.forget(item)
      search()
    case kVK_ANSI_C where !fieldHasSelection:
      // 内置动作、搜索提示没有可复制的东西：交给输入框
      guard let item = selectedItem, item.kind != .action, item.kind != .prompt else {
        return false
      }
      Paster.write(string: item.payload ?? item.target)
      hidePanel()
    case kVK_ANSI_Comma:
      hidePanel()
      runAction("settings")
    default:
      guard let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      if digit < results.count { execute(results[digit]) }
    }
    return true
  }

  private func move(by offset: Int) {
    guard !results.isEmpty else { return }
    selectionMotion = NSApp.currentEvent?.isARepeat == true ? .instant : .snap
    selection = (selection + offset + results.count) % results.count
    userMovedSelection = true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]
}
