// 启动器状态与操作：查询 → 结果。空查询先列「收藏」（⌘D 加，按加入顺序、⌥⌘↑↓ 调），再用「常用」（全局使用分）补足到
// 8 行（体检 A22 D13）。结果顺序：直达网址 / 路径、计算结果（含单位换算、进制，体检 D11）、关键词搜索，然后 App 目录
// （含系统设置面板，体检 D9）+ 内置动作 + 快捷链接 / 搜索提示 + 书签 + 用过的网址 / 文件按匹配分排序（同分系统命令最后，
// 体检 B36），再是浏览历史（各家开了「也搜浏览历史」才有，排在书签后、不和书签 / 用过的重复，最多 5 行，体检 D8），网页搜索兜底；
// 「cb 关键词」只有一行，↩ 收起启动器、呼出剪贴板面板并把关键词填进它的搜索框（N9；单输 cb 时它排第一、后面照常接本地结果）；
// 「fy 文本」只有一行，↩ 收起启动器、翻译浮窗直接翻译（体检 D10）；「open / find 词」、空格开头搜文件（FileSearch，
// 结果异步到，先留着上一次的结果，后面仍接整句匹配到的 App）。
// 系统命令（SystemCommands，对标 Alfred）：锁定屏幕、清倒废纸篓这类固定命令一行一个，按中文名 / 拼音 / Alfred 关键词
// 搜到；「quit / hide / forcequit / eject 空格」列正在运行的 App / 可推出的宗卷，「kill 空格」列后台进程（异步，
// 体检 D12：↩ 结束、⌘↩ 强制结束），「port 空格」是同一份进程的端口视图（一个在监听的端口一行；程序坞里的 App 也列，
// 它们 ↩ 走正常退出，rowVerb）；清倒废纸篓、全部退出、强制退出 / 强制结束不可撤销，第一下只上膛（选中行的副标题
// 换成确认提示），同一个键再按一次才执行（SystemControl，面板先收起）。
// 键盘（对标 Alfred / Raycast）：↑↓ 循环、↩ 执行（计算结果是粘贴，find 的文件是在访达中显示）、⌘↩ 在访达中显示
// （计算结果只复制，find 的文件是打开，网址用第二个浏览器打开）、⌥↩ 在访达里搜索、⌃↩ 网页搜索（按住修饰键时选中行的
// 副标题换成替代动作）、Tab 补全、⌘C 复制路径 / 网址、⇧⌘C 网址复制为 Markdown 链接、⌘D 收藏、⌘Y 快速查看文件、
// ⌘1–9 执行第 N 项、「常用」里 ⌘⌫ 移除一项（⌘Z 撤销，体检 B38）、Esc 先关预览 / 动作菜单再清空再关闭；
// ⌘K / →（光标在末尾时）动作菜单（N8，共用 ActionMenu）：列出选中项的全部动作连同键位，开着时搜索框用来过滤动作，
// ↑↓ ↩ 选择执行、Esc 关掉，菜单里标着的其余键位（⇥ ⌥↩ ⌃↩ ⌘ 键）照常可用、先关菜单。行上右键是同一份动作（体检 C8）。
// 单击选中、双击执行（和剪贴板面板一致）。打开 App / 文件 / 网址 / 搜索页：↩ 当下就收起，系统在后台打开，不等 App
// 启动完（2026-09-27 用户要求）；打开成功才记使用，打不开用刘海岛说。其余先执行、成功才收起（失败在面板里显示，§11 #33）。
// 启动器没有固定：点外面就收起（N8）；没执行就收起的，60 秒内再呼出保留查询和选中项（体检 A27）。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class LauncherModel {
  var query = "" {
    didSet {
      forgotten = nil  // 打字就不能再撤销移除
      search()
    }
  }
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
  /// 系统命令的带对象模式（quit / hide / forcequit / eject / kill / port 空格）；nil = 不在这个模式
  private(set) var commandRequest: SystemCommands.Request?
  /// 上膛的那一行：不可撤销的命令第一下按下后，等同一个键再按一次（打字、移动选中、Esc、收起都撤掉）
  private(set) var armed: Armed?
  /// 没有结果时显示的话。和结果一起换：文件搜索还在查时留着上一句，不闪「没有匹配」
  private(set) var emptyText = "没有匹配的结果"
  /// 空查询时前几行是收藏（其余是常用）
  private(set) var favoriteCount = 0
  /// 底栏左边的就地提示（换掉种类色块和种类名）：收藏、移除常用（带撤销「已从常用中移除 · 撤销 ⌘Z」）
  private(set) var notice: BarNotice?
  /// ⌘Y 快速查看开着（体检 C7）：预览浮层跟着选中项走
  private(set) var isQuickLooking = false
  /// 预览浮层上画不画预览：打开前设上，浮层真正收走（缩回动画放完）才清掉。收走的浮层里别再画：SwiftUI 在看不见的
  /// 窗口里照样跟着选中项重建 Quick Look 视图（大 PDF、视频也会生成预览），同剪贴板 ⌘Y
  private(set) var showsQuickLookContent = false
  /// ⌘K 动作菜单开着：搜索框改成过滤动作
  var showsActions = false {
    didSet {
      actionQuery = ""
      actionSelection = 0
    }
  }
  var actionQuery = "" { didSet { actionSelection = 0 } }
  var actionSelection = 0

  enum Alternate {
    case none, command, option, control
  }

  struct Armed: Equatable {
    let id: String
    /// 是 ⌘↩ 上的膛（quit / hide 里的强制退出），要再按 ⌘↩
    let commandKey: Bool
    /// 选中行副标题换成的确认提示
    let text: String
  }

  /// 列表里的一个分组标题：排在第 row 行前面
  struct Group: Equatable {
    let row: Int
    let title: String
  }

  @ObservationIgnored let usage: LauncherUsage
  @ObservationIgnored private var apps: [LauncherItem] = []
  @ObservationIgnored private var appsScannedAt: Date?
  /// 上次扫描时各应用程序目录的修改时间：呼出时变了就先重扫（体检 B31）
  @ObservationIgnored private var appsSignature: [Date?] = []
  /// 单测 / 截图自检：传入固定的 App 列表，不扫本机、不查 Spotlight、不读书签（文件结果由 showFiles 直接给）
  @ObservationIgnored private let isFixture: Bool
  @ObservationIgnored private let files = FileSearch()
  /// 这次文件搜索已经显示过一批：后面的批次到了保持选中项，不跳回第一行
  @ObservationIgnored private var shownFileRequest: FileSearch.Request?
  // 以下由 AppDelegate 接上
  @ObservationIgnored var hidePanel: () -> Void = {}
  @ObservationIgnored var runAction: (String) -> Void = { _ in }
  /// 内置动作此刻的状态（复制即译开没开、有没有钉图、能不能检查更新）
  @ObservationIgnored var actionState: () -> LauncherItem.ActionState = { .init() }
  /// ⌘,：直达 设置 › 启动器（启动器已收起）。搜「设置」那个内置动作仍走 runAction，打开上次看的页
  @ObservationIgnored var openSettings: () -> Void = {}
  /// 面板按内容伸缩高度（顶边不动）
  @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }
  /// cb 那一行 ↩（启动器已收起）：呼出剪贴板面板，把关键词填进它的搜索框
  @ObservationIgnored var openClipboard: (String) -> Void = { _ in }
  /// fy 那一行 ↩（启动器已收起）：翻译浮窗直接翻译这段
  @ObservationIgnored var translate: (String) -> Void = { _ in }
  /// 全局热键动作当前生效的组合（选中的内置动作右侧显示键帽）；AppDelegate 接 HotKeyCenter 注册上的那份
  @ObservationIgnored var boundHotKey: (HotKeyAction) -> HotKey? = { $0.hotKey }
  /// 文件搜索的授权提示 ↩：没问过就逐个弹系统框，问过就打开系统设置
  @ObservationIgnored var requestFolderAccess: () -> Void = {}
  /// 刘海岛（单测里是 nil）：只复制不粘贴时面板同时收起，结果看不见，用它说
  @ObservationIgnored var island: Island?
  /// 文件结果最后一行的授权提示：每次呼出后第一次进文件搜索时算一次（要读受保护目录，问过之前不读）。
  /// ponytail: 授权被重置（tccutil reset、撤掉完全磁盘访问）后，第一次进文件搜索时系统会弹框
  @ObservationIgnored var folderHint: LauncherItem?
  @ObservationIgnored private var checksFolderAccess = false
  /// 用户按过 ↑↓ / 点选过：文件结果后续批次到了才按 id 保持选中项，否则回到第一行（最佳匹配）
  @ObservationIgnored private var userMovedSelection = false
  /// 执行系统命令（启动器已收起）：AppDelegate 接 SystemControl；单测、截图自检里什么都不做，不会真锁屏、关机
  @ObservationIgnored var perform: (SystemControl.Action) -> Void = { _ in }
  /// 带对象模式列哪些（正在运行的 App / 可推出的宗卷）；单测、截图自检换成固定的
  @ObservationIgnored var commandTargets: @MainActor (SystemCommands.Verb) -> [LauncherItem] =
    SystemCommands.targets(for:)
  /// 这次带对象模式列出来的：进模式时列一次，之后打字只过滤，列表不跟着重排
  @ObservationIgnored private var commandItems: (verb: SystemCommands.Verb, items: [LauncherItem])?
  /// kill / port 空格列哪些进程（ps、lsof 在进程外跑，异步到）；单测、截图自检换成固定的，不跑命令
  @ObservationIgnored var processTargets: (SystemCommands.Verb) async -> [LauncherItem] = {
    await $0 == .port ? Processes.portTargets() : Processes.targets()
  }
  /// 正在列的那一次，记着是给哪个关键词列的（kill 改成 port 时上一次的不要了）
  @ObservationIgnored private var processTask: (verb: SystemCommands.Verb, task: Task<Void, Never>)?
  /// 浏览历史的行（开着「也搜浏览历史」的各家合起来；开关一关 refresh 就扔掉）；单测、截图自检换成固定的
  @ObservationIgnored var historyItems: () -> [LauncherItem] = { BrowserHistory.shared.items }
  /// 呼出时读 / 重读浏览历史和 Firefox 书签（进程外，读完才返回；返回换没换上新的）；单测、截图自检里什么都不做
  @ObservationIgnored var refreshHistory: () async -> Bool = {
    await BrowserHistory.shared.refresh()
  }
  @ObservationIgnored private var historyTask: Task<Void, Never>?
  /// 网页搜索与快捷链接的列表（偏好里的）；单测、截图自检用预置的
  @ObservationIgnored var engines: () -> [SearchEngine] = { WebSearch.engines }
  /// 默认浏览器以外能开网页的 App（「用 X 打开」、⌘↩）；单测、截图自检换成固定的
  @ObservationIgnored var browsers: () -> [URL] = { LauncherModel.otherBrowsers() }
  /// 能打开这种类型文件的 App（默认的排第一，最多 5 个）；单测、截图自检换成固定的
  @ObservationIgnored var applications: (UTType) -> [(url: URL, isDefault: Bool)] = {
    LauncherModel.applications(toOpen: $0)
  }
  /// 移到废纸篓（能从废纸篓放回，不二次确认）；单测里换成记一笔，不真删
  @ObservationIgnored var recycle: (URL) async throws -> Void = {
    _ = try await NSWorkspace.shared.recycle([$0])
  }
  /// 「fy 单词」副标题的释义（系统词典第一条）；单测、截图自检换成固定的
  @ObservationIgnored var lookUp: (String) async -> String? = { word in
    await WordLookup.systemDictionary(word)?.groups.first?.senses.first?.definition
  }
  @ObservationIgnored private var definitionTask: Task<Void, Never>?
  /// 这次呼出里查过的浏览器 / 打开方式（⌘K 每打一个字都要重算动作表，LaunchServices 别每次都问）
  @ObservationIgnored private var browserCache: [URL]?
  @ObservationIgnored private var applicationCache: [String: [(url: URL, isDefault: Bool)]] = [:]
  /// ⌘Y 预览浮层（AppDelegate 接）：从选中行长出来 / 缩回去（animated = false 时直接收起）
  @ObservationIgnored var openQuickLook: () -> Void = {}
  @ObservationIgnored var closeQuickLook: (_ animated: Bool) -> Void = { _ in }
  /// 选中行在窗口里的位置（视图报上来，⌘Y 从它长出来）；滚出可见区时是 nil
  @ObservationIgnored var rowFrame: (id: String, rect: CGRect)?
  /// 刚从常用里移除的一项和它的使用记录：⌘Z 放回（只留最近一次；打字、移动、Esc、收起都清掉）
  @ObservationIgnored private var forgotten: (item: LauncherItem, entries: [LauncherUsage.Entry])? {
    didSet {
      if forgotten == nil, case .undo = notice { notice = nil }
    }
  }
  @ObservationIgnored private var noticeTask: Task<Void, Never>?
  /// 这次呼出里执行过会收起面板的动作（↩、⌘1–9、双击、⌘C 这些）：收起时不留查询
  @ObservationIgnored private var executed = false
  /// 没执行就收起的时间：60 秒内再呼出保留查询和选中项
  @ObservationIgnored private var keptAt: Date?
  /// 这次呼出接着上次的查询（AppDelegate 据此把搜索框的字全选：直接打字就替换）
  @ObservationIgnored private(set) var resumesQuery = false

  static let recentLimit = 8
  /// 浏览历史最多列几行：排在书签后面，别把兜底搜索、补全提示挤出可见区
  static let historyLimit = 5
  static let rescanInterval: TimeInterval = 300
  /// 没执行就收起后，多久内再呼出保留查询
  static let keepQueryInterval: TimeInterval = 60

  init(usage: LauncherUsage, apps: [LauncherItem]? = nil) {
    self.usage = usage
    isFixture = apps != nil
    if let apps {
      self.apps = apps
      appsScannedAt = .now
      engines = { WebSearch.defaults }
      processTargets = { _ in [] }
      historyItems = { [] }
      refreshHistory = { false }
    }
  }

  /// 空查询：「收藏」+「常用」（一个空格是文件搜索，不算）
  var isShowingRecent: Bool {
    fileRequest == nil && query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// 列表里的分组标题：空查询「收藏」「常用」，文件搜索只输了关键词时「最近打开和下载的文件」，
  /// 系统命令只输了关键词时「正在运行的 App」/「可推出的磁盘」
  var groups: [Group] {
    if isShowingRecent {
      var groups: [Group] = []
      if favoriteCount > 0 { groups.append(Group(row: 0, title: "收藏")) }
      if favoriteCount == 0 || results.count > favoriteCount {
        groups.append(Group(row: favoriteCount, title: "常用"))
      }
      return groups
    }
    if let commandRequest, commandRequest.terms.isEmpty {
      return [Group(row: 0, title: commandRequest.verb.groupTitle)]
    }
    return fileRequest?.terms.isEmpty == true ? [Group(row: 0, title: "最近打开和下载的文件")] : []
  }

  /// 第一个分组标题
  var groupTitle: String? { groups.first?.title }

  /// 内置动作（按此刻的状态）
  private var builtIns: [LauncherItem] { LauncherItem.actions(actionState()) }

  /// 启动时、呼出前应用程序目录变了时扫 App 目录
  func rescanApps() {
    guard !isFixture else { return }
    appsSignature = AppCatalog.signature()
    apps = AppCatalog.scan()
    appsScannedAt = .now
  }

  /// 呼出前：应用程序目录变了就重扫（刚装的 App 马上搜得到）；60 秒内没执行就收起的，接着上次的查询和选中项
  func prepareForShow(now: Date = .now) {
    if !isFixture,
      Self.needsRescan(
        scannedAt: appsScannedAt, scanned: appsSignature, now: AppCatalog.signature())
    {
      rescanApps()
    }
    browserCache = nil
    applicationCache = [:]
    checksFolderAccess = !isFixture
    let keeps = keptAt.map { now.timeIntervalSince($0) <= Self.keepQueryInterval } ?? false
    keptAt = nil
    let kept = keeps ? selectedItem?.id : nil
    if keeps || query.isEmpty { search() } else { query = "" }
    if let kept { reselect(kept) }
    resumesQuery = keeps && !query.isEmpty
    loadHistory()
  }

  /// 浏览历史、Firefox 书签该重读就在进程外读（开关关着时清掉）；换上了新读的、正在搜、用户还没挑过选中项，就按新的历史重搜一次
  private func loadHistory() {
    guard historyTask == nil else { return }
    historyTask = Task {
      let reloaded = await refreshHistory()
      historyTask = nil
      if reloaded, !userMovedSelection, armed == nil, fileRequest == nil, commandRequest == nil,
        query.trimmingCharacters(in: .whitespaces).count >= 2
      {
        search()
      }
    }
  }

  /// 呼出前要不要重扫 App 目录：没扫过，或者各应用程序目录的修改时间（放进 / 删掉 .app 都会变）和上次扫描时不一样
  static func needsRescan(scannedAt: Date?, scanned: [Date?], now: [Date?]) -> Bool {
    scannedAt == nil || scanned != now
  }

  /// 收起：执行过、或者查询是空的，清空；没执行就收起的（点外面、再按热键、切到别的 App）留着查询和选中项，
  /// 60 秒内再呼出接着用（体检 A27）。App 目录超过 5 分钟就趁没人看时重扫（接住子文件夹里的升级、改名）
  func didHide(now: Date = .now) {
    showsActions = false
    error = nil
    armed = nil
    forgotten = nil
    notice = nil
    definitionTask?.cancel()
    if isQuickLooking {
      closeQuickLook(false)
      quickLookDidHide()
    }
    // 还在列的进程不要了（再呼出重列）
    processTask?.task.cancel()
    processTask = nil
    if executed || query.isEmpty {
      keptAt = nil
      if !query.isEmpty { query = "" }
    } else {
      keptAt = now
      files.stop()
      // 带对象模式（quit / eject / kill / port 空格）的列表再呼出时重列：这期间可能退出了 App、推出了磁盘、进程结束了
      commandItems = nil
    }
    executed = false
    if let scannedAt = appsScannedAt, now.timeIntervalSince(scannedAt) > Self.rescanInterval {
      rescanApps()
    }
  }

  private func search() {
    error = nil
    armed = nil
    selectionMotion = .instant
    selection = 0
    userMovedSelection = false
    shownFileRequest = nil
    favoriteCount = 0
    definitionTask?.cancel()
    fileRequest = FileSearch.request(for: query)
    commandRequest = fileRequest == nil ? SystemCommands.request(for: query) : nil
    if commandRequest == nil { commandItems = nil }
    if let fileRequest {
      searchFiles(fileRequest)
      return
    }
    files.stop()
    if let commandRequest {
      showTargets(commandRequest)
      return
    }
    emptyText = "没有匹配的结果"
    if let text = Self.translateQuery(query) {
      results = [Self.translateItem(text)]
      lookUpDefinition(text)
      return
    }
    // 「cb 词」（带空格）只有这一行（N9）；单输 cb 时它排第一，后面照常接本地结果（体检 B33）
    if let keyword = Self.clipQuery(query), query.count > 2 {
      results = [Self.clipItem(keyword)]
      return
    }
    let query = query.trimmingCharacters(in: .whitespaces)
    if query.isEmpty {
      results = home()
      return
    }
    let engines = engines()
    let direct = DirectItems.items(for: query)
    let keyword = WebSearch.keywordItem(for: query, engines: engines)
    let prompts = WebSearch.promptItems(for: query, engines: engines)
    let filePrompts = FileSearch.promptItems(for: query)
    let systemPrompts = SystemCommands.promptItems(for: query)
    let clip = Self.clipQuery(query) != nil ? [Self.clipItem("")] : []
    let top =
      clip + Self.translatePrompts(for: query) + direct
      + [Calculator.item(for: query), keyword].compactMap { $0 } + prompts.exact
      + filePrompts.exact + systemPrompts.exact
    // 书签、浏览历史至少 2 个字才搜（1 个字母命中太多）
    let bookmarks = query.count >= 2 && !isFixture ? Bookmarks.items() : []
    let used = usedLocations(excluding: bookmarks)
    let local = LauncherMatch.rank(
      apps + builtIns + SystemCommands.items + WebSearch.quicklinkItems(engines: engines)
        + bookmarks + used, query: query
    ) { usage.boost(for: $0, query: query) }
    let history = query.count >= 2 ? visited(query, excluding: bookmarks + used) : []
    // 兜底默认只在没有本地结果时出现（和 Alfred 一样；以前带空格的查询把兜底排到匹配的 App 前面），
    // 设置里可改成总是附在最后。已经有网址 / 路径直达项、或明写了 http(s):// 的就不再兜底（体检 B35：
    // 以前只看开头是不是 http，「http 缓存」「https 证书」没有本地结果时什么都不剩）
    let explicit =
      direct.contains { $0.kind == .path || $0.kind == .url }
      || ["http://", "https://"].contains(where: query.lowercased().hasPrefix)
    let wantsFallback =
      local.isEmpty || UserDefaults.standard.bool(forKey: Prefs.launcherFallbackAlways)
    let fallback =
      keyword == nil && wantsFallback && !explicit
      ? WebSearch.fallbackItems(for: query, engines: engines) : []
    // 直达项和书签 / 用过的网址可能是同一项：按 id 去重，保留靠前的
    var seen = Set<String>()
    results =
      (top + local + history + prompts.partial + filePrompts.partial + systemPrompts.partial
      + fallback)
      .filter { seen.insert($0.id).inserted }
  }

  /// 浏览历史里匹配上的（体检 D8）：去掉已经是书签 / 用过的网址（不分大小写），只比标题和去协议的网址、不加使用分，
  /// 最多 5 行；副标题按这一刻拼上「3 天前」。不算「本地结果」：只有历史匹配上时照样出兜底搜索
  private func visited(_ query: String, excluding known: [LauncherItem]) -> [LauncherItem] {
    let pages = historyItems()
    guard !pages.isEmpty else { return [] }
    let seen = Set(known.map { $0.target.lowercased() })
    // 先粗筛：每个词都得是某个名字的子串（匹配分档的必要条件）。3000 条直接排序要逐条切词，
    // Debug 构建实测本机 3000 条一次按键约 45 ms，粗筛后 10–15 ms。
    // ponytail: 还嫌慢就在 BrowserHistory 里存好拼接的小写名字，只做一次 contains
    let tokens = LauncherMatch.fold(query).split(whereSeparator: \.isWhitespace)
    let candidates = pages.filter { page in
      tokens.allSatisfy { token in page.names.contains { $0.contains(token) } }
        && !seen.contains(page.target.lowercased())
    }
    let now = Date.now
    return LauncherMatch.rank(candidates, query: query) { _ in (0, 0) }
      .prefix(Self.historyLimit).map { item in
        var item = item
        item.subtitle = BrowserHistory.subtitle(item, now: now)
        return item
      }
  }

  /// quit / hide / forcequit / eject / kill / port 模式：进模式时列一次，之后按输入的词过滤（不加使用分，全按名字；
  /// kill 的「:3000」「:」只按进程监听的端口筛，port 只输数字时按端口号的开头筛）。kill、port 的进程在进程外列，
  /// 到之前写「正在读取进程…」/「正在读取端口…」
  private func showTargets(_ request: SystemCommands.Request) {
    let verb = request.verb
    if commandItems?.verb != verb {
      guard verb.listsProcesses else {
        commandItems = (verb, commandTargets(verb))
        return showTargets(request)
      }
      results = []
      emptyText = verb == .port ? "正在读取端口…" : "正在读取进程…"
      // 同一个关键词还在列就等它（打字不重列）；换了关键词，上一次的不要了
      if processTask?.verb != verb {
        processTask?.task.cancel()
        let task = Task {
          let items = await processTargets(verb)
          guard !Task.isCancelled else { return }
          processTask = nil
          guard let request = commandRequest, request.verb == verb else { return }
          commandItems = (verb, items)
          showTargets(request)
        }
        processTask = (verb, task)
      }
      return
    }
    let targets = commandItems?.items ?? []
    let terms = request.terms.joined(separator: " ")
    // port 只输了数字（前面带不带冒号都行）：要找的是端口
    let port = verb == .port ? terms.wholeMatch(of: /:?(\d*)/)?.1 : nil
    results =
      if terms.isEmpty {
        targets
      } else if verb == .kill, terms.hasPrefix(":") {
        // 只按监听的端口筛、保持原顺序（「postgres: walwriter」这类进程名里也有冒号）
        targets.filter { Processes.listens($0, on: terms) }
      } else if let port {
        // 按端口号的开头筛、保持端口顺序（按匹配排的话「80」会带出 5180、18080）
        targets.filter { $0.title.hasPrefix(":" + port) }
      } else {
        LauncherMatch.rank(targets, query: terms) { _ in (0, 0) }
      }
    // port 写「没有找到」：别的用户、系统的进程在监听时这里看不到，不能说「没有」
    emptyText =
      switch (verb, terms.isEmpty) {
      case (.eject, true): "没有可推出的磁盘"
      case (.eject, false): "没有匹配的磁盘"
      case (.kill, true): "没有后台进程"
      case (.kill, false) where terms.hasPrefix(":"): "没有进程在监听这个端口"
      case (.port, true): "没有找到在监听端口的进程"
      case (.port, false) where port != nil: "没有找到监听这个端口的进程"
      case (.kill, false), (.port, false): "没有匹配的进程"
      case (_, true): "没有正在运行的 App"
      case (_, false): "没有匹配的 App"
      }
  }

  /// 等 kill / port 的进程列完（单测、截图自检用）
  func processLookup() async { await processTask?.task.value }

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
      : LauncherMatch.rank(apps + builtIns, query: whole) {
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

  /// 「cb」或「cb 关键词」（不分大小写：「CB 会议」也算）
  static func clipQuery(_ query: String) -> String? {
    let lower = query.lowercased()
    guard lower == "cb" || lower.hasPrefix("cb ") else { return nil }
    return String(query.dropFirst(2)).trimmingCharacters(in: .whitespaces)
  }

  /// cb 那一行：启动器里不再列剪贴板条目，↩ 交给剪贴板面板去搜（类型图标、透镜、⌘K、多选都在那边）
  static func clipItem(_ keyword: String) -> LauncherItem {
    LauncherItem(
      kind: .clip, target: keyword,
      title: keyword.isEmpty ? "打开剪贴板历史" : "在剪贴板历史里搜索「\(keyword)」", subtitle: "")
  }

  /// 「fy 文本」的文本（不分大小写；只输 fy 不算，出补全提示）
  static func translateQuery(_ query: String) -> String? {
    guard query.lowercased().hasPrefix("fy ") else { return nil }
    let text = query.dropFirst(3).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  /// fy 那一行（副标题是单个英文词的词典释义，查到了再换上）
  static func translateItem(_ text: String, definition: String = "") -> LauncherItem {
    LauncherItem(kind: .translate, target: text, title: "翻译「\(text)」", subtitle: definition)
  }

  /// 单输 fy：↩ / Tab 补全关键词的提示（同 open / find）
  static func translatePrompts(for query: String) -> [LauncherItem] {
    guard LauncherMatch.fold(query) == "fy" else { return [] }
    return [
      LauncherItem(
        kind: .prompt, target: "translate-fy", title: "翻译…",
        subtitle: "输入「fy 空格 文字」，↩ 或 Tab 补全关键词", completion: "fy ")
    ]
  }

  /// 「fy 单词」：系统词典的第一条释义，到了再换副标题，不改行高（体检 D10；首查约 0.3 s）
  private func lookUpDefinition(_ text: String) {
    guard text.wholeMatch(of: /[A-Za-z][A-Za-z'’\-]*/) != nil else { return }
    let item = Self.translateItem(text)
    definitionTask = Task {
      guard let definition = await lookUp(text), !Task.isCancelled,
        let index = results.firstIndex(of: item)
      else { return }
      results[index] = Self.translateItem(text, definition: definition)
    }
  }

  /// 等副标题的释义查完（截图自检、单测用）
  func definitionLookup() async { await definitionTask?.value }

  /// 用过的网址 / 文件：不在任何目录里，靠使用记录找回来；和书签同一网址（不分大小写）时只留书签。
  /// 系统设置面板在 App 目录里，不另列
  private func usedLocations(excluding bookmarks: [LauncherItem]) -> [LauncherItem] {
    let bookmarked = Set(bookmarks.map { $0.target.lowercased() })
    return usage.entries.values
      .filter {
        $0.query.isEmpty && ($0.kind == .url || $0.kind == .path)
          && !bookmarked.contains($0.target.lowercased()) && !AppCatalog.isSettingsPane($0.target)
      }
      .map(Self.item(for:))
  }

  static func item(for entry: LauncherUsage.Entry) -> LauncherItem {
    item(kind: entry.kind, target: entry.target, title: entry.title)
  }

  /// 网址 / 文件：不在任何目录里，按记下的标题还原
  static func item(kind: LauncherItem.Kind, target: String, title: String) -> LauncherItem {
    LauncherItem(
      kind: kind, target: target, title: title,
      subtitle: kind == .url ? target : (target as NSString).abbreviatingWithTildeInPath,
      names: [title, target].map(LauncherMatch.fold))
  }

  /// 空查询（体检 A22 D13）：先「收藏」（按加入顺序），再按全局使用分（14 天衰减）用「常用」补足到 8 行；
  /// 都只留还能还原的（App 还在、文件还在）
  private func home() -> [LauncherItem] {
    let actions = builtIns
    var items = favorites(actions)
    favoriteCount = items.count
    // 全部按分排好再往下找：前面几条失效（App 已卸载、文件已删）时后面的补上
    for entry in usage.top(Int.max) where items.count < Self.recentLimit {
      guard let item = restore(entry.kind, entry.target, entry.title, actions),
        !items.contains(where: { $0.id == item.id })
      else { continue }
      items.append(item)
    }
    return items
  }

  /// 还原得出来的收藏；还原不出来的（App 已卸载、文件已删）顺手删掉：看不见的收藏会占着 8 个名额（⌘D 说满了却
  /// 找不到可取消的）、夹在中间让 ⌥⌘↑↓ 换了位置却看不出变化。有时有、有时没有的内置动作（钉图）不让收藏（canFavorite）。
  /// ponytail: 外接磁盘上的 App / 文件拔掉磁盘时也会被删，真碰到再按宗卷是否挂着区分
  private func favorites(_ actions: [LauncherItem]) -> [LauncherItem] {
    var items: [LauncherItem] = []
    var missing: [LauncherUsage.Favorite] = []
    for favorite in usage.favorites {
      if let item = restore(favorite.kind, favorite.target, favorite.title, actions) {
        items.append(item)
      } else {
        missing.append(favorite)
      }
    }
    if !missing.isEmpty { usage.removeFavorites(missing) }
    return items
  }

  private func restore(
    _ kind: LauncherItem.Kind, _ target: String, _ title: String, _ actions: [LauncherItem]
  ) -> LauncherItem? {
    switch kind {
    case .app:
      if let app = apps.first(where: { $0.target == target }) { return app }
      // 应用程序目录以外的 App
      return FileManager.default.fileExists(atPath: target) ? AppCatalog.item(path: target) : nil
    case .action: return actions.first { $0.target == target }
    case .system: return SystemCommands.items.first { $0.target == target }
    // 系统设置面板从目录里取（副标题「系统设置」、图标）；目录里没有的（系统更新后没了、自己建的这类链接）退回普通网址，
    // 不删收藏
    case .url:
      return apps.first { $0.target == target }
        ?? Self.item(kind: .url, target: target, title: title)
    case .path:
      return FileManager.default.fileExists(atPath: target)
        ? Self.item(kind: .path, target: target, title: title) : nil
    case .search, .calculation, .clip, .prompt, .translate, .process: return nil  // 不记使用，不会出现
    }
  }

  /// 列表变了（收藏、移除、调顺序）之后重算，选中留在那一项上；它不在了就留在原来的位置
  private func refresh(keeping id: String?) {
    let index = selection
    search()
    if let id, reselect(id) { return }
    selection = min(index, max(results.count - 1, 0))
  }

  @discardableResult private func reselect(_ id: String) -> Bool {
    guard let index = results.firstIndex(where: { $0.id == id }) else { return false }
    selection = index
    // 文件搜索的后续批次到了也留在这一项上
    userMovedSelection = true
    shownFileRequest = fileRequest
    return true
  }

  // MARK: 执行

  func execute(_ item: LauncherItem) {
    if let request = commandRequest, [.app, .path, .process].contains(item.kind) {
      return runTarget(item, rowVerb(item, in: request))
    }
    switch item.kind {
    case .calculation:
      paste { Paster.write(string: item.payload ?? "", record: true) }
    case .clip:
      close()
      openClipboard(item.target)
    case .translate:
      close()
      translate(item.target)
    case .prompt where item.target == FileSearch.accessTarget:
      close()
      requestFolderAccess()
    case .prompt:
      if let completion = item.completion { query = completion }
    case .search:
      guard let url = URL(string: item.target) else {
        error = "打不开搜索页"
        return
      }
      open(url, nil)
    case .action:
      // 退出本 App 不记使用：不进「常用」，也不会越用越排到别的前缀查询前面（↩ 不确认）
      if item.target != MenuExtra.quit.rawValue { usage.record(item, query: query) }
      close()
      runAction(item.target)
    case .system:
      guard let command = SystemCommand(rawValue: item.target) else { return }
      if let text = command.confirmation, !confirm(item, commandKey: false, text: text) { return }
      usage.record(item, query: query)
      close()
      perform(.command(command))
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
    case .process: break  // 只在 kill / port 模式里出现，上面已经处理
    }
  }

  /// 执行了东西、面板跟着收起：这次的查询不留
  private func close() {
    executed = true
    hidePanel()
  }

  /// 带对象模式里这一行按哪个命令办：port 列的是进程，后台进程同 kill（↩ 结束、⌘↩ 强制结束），程序坞里的 App 同 quit
  /// （↩ 正常退出——有没存的内容它会先问，⌘↩ 强制退出）；别的模式就是当前的命令
  private func rowVerb(_ item: LauncherItem, in request: SystemCommands.Request)
    -> SystemCommands.Verb
  {
    guard request.verb == .port else { return request.verb }
    return item.process?.app == nil ? .kill : .quit
  }

  /// 带对象模式的行：↩ 退出 / 隐藏 / 强制退出 / 推出 / 结束进程（verb 是 rowVerb 给的）。不记使用（退出过的 App
  /// 不该因此在普通搜索里排前面）。强制退出（forcequit 的 ↩、quit / hide 的 ⌘↩）、强制结束（kill 的 ⌘↩）不可撤销：先上膛
  private func runTarget(
    _ item: LauncherItem, _ verb: SystemCommands.Verb, commandKey: Bool = false
  ) {
    let force = verb == .forcequit || commandKey
    if force {
      // port 的行标题是端口号：提示里写上是谁
      let name = commandRequest?.verb == .port ? item.process?.label : nil
      let text =
        verb == .kill
        ? SystemCommands.killConfirmation(name: name)
        : SystemCommands.forceQuitConfirmation(key: commandKey ? "⌘↩" : "↩", name: name)
      guard confirm(item, commandKey: commandKey, text: text) else { return }
    }
    // port 列的程序坞 App：目标是「PID:端口」，包路径在 process 里
    let path = item.process?.app?.path ?? item.target
    let action: SystemControl.Action
    if verb == .kill {
      guard let process = item.process else { return }
      action = .signal(pid: process.pid, name: process.name, force: force)
    } else if force {
      action = .forceQuit(path)
    } else {
      action =
        switch verb {
        case .eject: .eject(item.target)
        case .hide: .hide(item.target)
        default: .quit(path)
        }
    }
    close()
    perform(action)
  }

  /// 不可撤销的：第一下只上膛（选中这一行、副标题换成确认提示、播报），同一行同一个键再按一次才放行
  private func confirm(_ item: LauncherItem, commandKey: Bool, text: String) -> Bool {
    let armed = Armed(id: item.id, commandKey: commandKey, text: text)
    if self.armed == armed {
      // 按住不放的自动连发、三击的第三下都不算「再按一次」：确认必须是新的一下
      guard !Self.isContinuation else { return false }
      self.armed = nil
      return true
    }
    // ⌘1–9 执行的不一定是选中那行：先选中它，提示才看得见
    if let index = results.firstIndex(of: item), index != selection {
      selectionMotion = .snap
      selection = index
    }
    self.armed = armed
    Island.announce(text)
    return false
  }

  func isArmed(_ item: LauncherItem) -> Bool { armed?.id == item.id }

  /// 这一行的 ↩（commandKey = false）/ ⌘↩（true）现在是不是危险操作（mac-whisker §3「危险色」）：等着再按一次确认的，
  /// 和强制退出 / 强制结束本身（没存的内容会丢）。⌘K 里那一行、底栏主动作的字和 ↩ 键帽据此换危险色；
  /// 哪个键是强制的照 primaryAction / commandReturnAction 的分法
  func isDangerous(_ item: LauncherItem, commandKey: Bool) -> Bool {
    if armed?.id == item.id, armed?.commandKey == commandKey { return true }
    guard let request = commandRequest, [.app, .process].contains(item.kind) else { return false }
    let verb = rowVerb(item, in: request)
    guard commandKey else { return verb == .forcequit }
    return verb == .kill || (verb != .forcequit && item.target != SystemCommands.finderPath)
  }

  /// 这次按键 / 点击是不是上一下的延续：键盘自动连发，或连击的第三下以后
  private static var isContinuation: Bool {
    if Style.isKeyRepeat { return true }
    guard let event = NSApp.currentEvent,
      event.type == .leftMouseDown || event.type == .leftMouseUp
    else { return false }
    return event.clickCount > 2
  }

  /// find 搜到的文件：↩ 在访达中显示、⌘↩ 打开（和 open 反过来）
  func revealsOnReturn(_ item: LauncherItem) -> Bool {
    fileRequest?.mode == .find && item.contentType != nil
  }

  /// 文件搜索搜到的文件 / 文件夹（有 Spotlight 类型，不是宗卷）：才有快速查看、打开方式、移到废纸篓（体检 C7）
  func isFile(_ item: LauncherItem) -> Bool {
    item.kind == .path && commandRequest == nil && item.contentType != nil
      && item.contentType?.conforms(to: .volume) == false
  }

  /// http(s) 网址（直达、书签、用过的、搜索页）：才有「用 X 打开」、Markdown 链接、复制标题（体检 D7）
  func isWebLink(_ item: LauncherItem) -> Bool {
    (item.kind == .url || item.kind == .search)
      && ["http://", "https://"].contains(where: item.target.lowercased().hasPrefix)
  }

  /// 在访达里选中（find 的 ↩ 记使用，和打开一样）；先收起再叫访达
  private func reveal(_ item: LauncherItem) {
    usage.record(item, query: query)
    close()
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
  }

  /// ⌥↩ / ⌃↩ 搜的文字：文件搜索时去掉关键词、fy 时是要翻译的那段；cb、系统命令是指令，没有可搜的
  private var searchText: String {
    if let text = Self.translateQuery(query) { return text }
    let query = query.trimmingCharacters(in: .whitespaces)
    guard Self.clipQuery(query) == nil, commandRequest == nil else { return "" }
    return fileRequest.map { $0.terms.joined(separator: " ") } ?? query
  }

  /// 计算结果：收起后写剪贴板、发 ⌘V 粘贴回原 App（和剪贴板面板一样不激活本 App、不等待）。
  /// 没有辅助功能授权时只复制，刘海岛警告去授权（授权框一点启动器就收了，面板里的提示会丢）
  private func paste(_ copy: () -> Void) {
    executed = true
    guard Permissions.isAccessibilityTrusted else {
      copy()
      // 系统授权框一点，启动器就收了，面板里的提示会跟着丢
      island?.show("已复制到剪贴板", detail: "授权辅助功能后才能直接粘贴", tone: .warning)
      return Permissions.requestAccessibility()
    }
    hidePanel()
    copy()
    _ = Paster.pasteToFrontmost()
  }

  /// ⌥↩：在访达里用 Spotlight 搜当前查询（不需要额外授权）
  private func searchInFinder() {
    let text = searchText
    guard !text.isEmpty, NSWorkspace.shared.showSearchResults(forQueryString: text) else {
      return NSSound.beep()
    }
    close()
  }

  /// ⌃↩：不管有没有本地结果，用第一个兜底搜索搜当前查询
  private func searchWeb() {
    let text = searchText
    guard !text.isEmpty, let engine = WebSearch.primary(in: engines()),
      let url = URL(string: WebSearch.url(engine, text))
    else { return NSSound.beep() }
    open(url, nil)
  }

  /// Tab：把选中项（右键菜单里是被点的那一项）补进输入框（计算结果接着算、目录接着往下找、「关键词 」接着输搜索词）
  func complete(_ item: LauncherItem? = nil) {
    guard let item = item ?? selectedItem, let text = Self.completion(for: item) else { return }
    query = text
  }

  static func completion(for item: LauncherItem) -> String? {
    if let completion = item.completion { return completion }
    switch item.kind {
    case .app, .action, .url, .system: return item.title
    case .path:
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: item.target, isDirectory: &isDirectory)
      let path = (item.target as NSString).abbreviatingWithTildeInPath
      return exists && isDirectory.boolValue && !path.hasSuffix("/") ? path + "/" : path
    case .search, .calculation, .clip, .prompt, .translate, .process: return nil
    }
  }

  /// 按住修饰键时选中行的副标题：说明松手前按 ↩ 会做什么；上了膛的换成确认提示
  func alternateSubtitle(for item: LauncherItem) -> String? {
    if let armed, armed.id == item.id { return armed.text }
    return switch alternate {
    case .none: nil
    case .command: commandReturnAction(for: item).map { "⌘↩ " + $0.title }
    case .option: finderSearchTitle.map { "⌥↩ " + $0 }
    case .control: webSearchTitle.map { "⌃↩ " + $0 }
    }
  }

  /// ↩ 做什么：底栏右侧的主动作和 ⌘K 菜单的第一行（名字随种类）
  func primaryAction(for item: LauncherItem) -> (title: String, symbol: String) {
    let confirming = armed?.id == item.id && armed?.commandKey == false
    if let request = commandRequest, [.app, .path, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      return ((confirming ? "确认" : "") + verb.title, verb.symbol)
    }
    return switch item.kind {
    case .app, .path:
      revealsOnReturn(item) ? ("在访达中显示", "folder") : ("打开", "arrow.up.forward.app")
    case .action: ("运行", "command")
    case .system:
      confirming
        ? ("确认" + item.title, "exclamationmark.triangle")
        : ("运行", SystemCommand(rawValue: item.target)?.symbol ?? "power")
    case .url where AppCatalog.isSettingsPane(item.target): ("打开", "gearshape")
    case .url: ("打开网址", "safari")
    case .search: ("搜索", "magnifyingglass")
    case .prompt:
      item.target == FileSearch.accessTarget ? ("授权", "lock.open") : ("补全关键词", "text.cursor")
    case .calculation: ("粘贴", "arrow.turn.down.left")
    case .clip: (item.target.isEmpty ? "打开" : "搜索", "doc.on.clipboard")
    case .translate: ("翻译", "character.bubble")
    case .process: ("结束", "stop.circle")
    }
  }

  /// ⌘↩ 做什么；没有就是 nil（网址没有第二个浏览器时也是 nil：副标题不写，按了只响提示音）
  func commandReturnAction(for item: LauncherItem) -> (title: String, symbol: String)? {
    let confirming = armed?.id == item.id && armed?.commandKey == true
    if let request = commandRequest, [.app, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      if verb == .kill { return (confirming ? "确认强制结束" : "强制结束", "xmark.octagon") }
      // 访达只能隐藏（hide 里列着它），不给强制退出
      guard verb != .forcequit, item.target != SystemCommands.finderPath else { return nil }
      return (confirming ? "确认强制退出" : "强制退出", "xmark.octagon")
    }
    if isWebLink(item) {
      return otherBrowsers.first.map { ("用「\(Self.appName($0))」打开", "safari") }
    }
    return switch item.kind {
    case .app, .path:
      revealsOnReturn(item) ? ("打开", "arrow.up.forward.app") : ("在访达中显示", "folder")
    case .calculation: ("只复制，不粘贴", "doc.on.doc")
    default: nil
    }
  }

  /// ⌘C 复制什么；内置动作、提示、cb / fy 那一行、进程、系统设置面板没有，⌘C 交给输入框
  func copyTitle(for item: LauncherItem) -> String? {
    switch item.kind {
    case .app, .path: "复制路径"
    case .url where AppCatalog.isSettingsPane(item.target): nil
    case .url, .search: "复制网址"
    case .calculation: "复制结果"
    case .action, .system, .prompt, .clip, .translate, .process: nil
    }
  }

  /// ⌥↩ / ⌃↩ 做什么：没有查询（或没有兜底搜索）时 nil
  private var finderSearchTitle: String? {
    let text = searchText
    return text.isEmpty ? nil : "在访达里搜索「\(text)」"
  }

  private var webSearchTitle: String? {
    let text = searchText
    guard !text.isEmpty, let engine = WebSearch.primary(in: engines()) else { return nil }
    return "用 \(engine.name) 搜索「\(text)」"
  }

  /// 打开 App / 文件 / 网址 / 搜索页（app：用指定的 App 打开）：先收起，再交给系统在后台打开（NSWorkspace 同步的 open
  /// 要等 App 启动完才返回，面板会一直挂着）；打开成功才记使用（item 为 nil 的搜索页不记），打不开时面板已经收起，用刘海岛说
  private func open(_ url: URL, _ item: LauncherItem?, with app: URL? = nil) {
    let query = query  // 收起时查询会被清空
    close()
    let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [weak self] _, error in
      Task { @MainActor in
        guard let self else { return }
        if error == nil {
          if let item { self.usage.record(item, query: query) }
        } else {
          self.island?.show(
            "打不开「\(item?.title ?? url.absoluteString)」", detail: error?.localizedDescription,
            tone: .error)
        }
      }
    }
    if let app {
      NSWorkspace.shared.open(
        [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
        completionHandler: done)
    } else {
      NSWorkspace.shared.open(
        url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: done)
    }
  }

  func click(_ item: LauncherItem) {
    showsActions = false
    if Style.isDoubleClick {
      execute(item)
    } else if let index = results.firstIndex(of: item) {
      if armed?.id != item.id { armed = nil }
      forgotten = nil
      selectionMotion = .glide
      selection = index
      userMovedSelection = true
    }
  }

  var selectedItem: LauncherItem? {
    results.indices.contains(selection) ? results[selection] : nil
  }

  // MARK: 收藏与常用（体检 A22 D13 B38）

  /// 能收藏的：记使用的那几类（App、内置动作、网址、文件、系统命令），带对象模式里的 App / 宗卷不算，
  /// 只在有钉图时才有的两个内置动作也不算（没钉图时还原不出来，收藏会自己消失）
  func canFavorite(_ item: LauncherItem) -> Bool {
    item.kind.isRecorded && commandRequest == nil
      && item.contentType?.conforms(to: .volume) != true
      && !(item.kind == .action && item.target.hasPrefix("pins-"))
  }

  func isFavorite(_ item: LauncherItem) -> Bool { usage.isFavorite(item) }

  /// 空查询里「常用」那一组的（收藏的不算）：⌘⌫ 能移除
  func isCommon(_ item: LauncherItem) -> Bool {
    guard isShowingRecent, item.kind.isRecorded, let index = results.firstIndex(of: item) else {
      return false
    }
    return index >= favoriteCount
  }

  /// ⌘D：加入 / 取消收藏；满 8 个时提示音 + 底栏说一声。空查询时列表跟着变，选中留在这一项上
  func toggleFavorite(_ item: LauncherItem) {
    guard canFavorite(item) else { return NSSound.beep() }
    let adding = !usage.isFavorite(item)
    if adding { _ = favorites(builtIns) }  // 先清掉还原不出来的，别让它们占名额
    guard usage.toggleFavorite(item) else {
      NSSound.beep()
      return show(.warning("收藏最多 \(LauncherUsage.favoriteLimit) 个，先取消一个"))
    }
    show(.message(adding ? "已加入收藏" : "已取消收藏"))
    if isShowingRecent { refresh(keeping: item.id) }
  }

  /// ⌥⌘↑↓：空查询里选中的收藏和上一个 / 下一个换位置（⌘1–N 跟着固定下来）；不是收藏时不接这个键
  private func moveFavorite(by offset: Int) -> Bool {
    guard isShowingRecent, let item = selectedItem, selection < favoriteCount else { return false }
    if usage.moveFavorite(item, by: offset) { refresh(keeping: item.id) } else { NSSound.beep() }
    return true
  }

  /// 「常用」里 ⌘⌫：忘掉这一项的使用记录，底栏「已从常用中移除 · 撤销 ⌘Z」，⌘Z 原样放回（体检 B38）
  func forget(_ item: LauncherItem) {
    let entries = usage.forget(item)
    refresh(keeping: nil)
    forgotten = (item, entries)
    show(.undo("已从常用中移除"), spoken: "已从常用中移除，按 Command-Z 撤销")
  }

  func undoForget() {
    guard let forgotten else { return }
    usage.restore(forgotten.entries)
    self.forgotten = nil
    refresh(keeping: forgotten.item.id)
    Island.announce("已撤销移除")
  }

  /// 底栏就地提示（剪贴板底栏同一种，BarNotice），同时播报。⌘Y 预览开着时底栏被它盖住：另走刘海岛
  /// （岛自己会播报，同剪贴板；底栏照样设上，缩回预览后还看得到）
  private func show(_ notice: BarNotice, spoken: String? = nil) {
    noticeTask?.cancel()
    self.notice = notice
    if isQuickLooking, let island {
      switch notice {
      case .message(let text): island.show(text)
      case .warning(let text): island.show(text, tone: .warning)
      case .undo(let text): island.show(text, detail: "⌘Z 撤销", tone: .info, symbol: "minus.circle")
      }
    } else {
      Island.announce(spoken ?? notice.text)
    }
    noticeTask = Task {
      try? await Task.sleep(for: .seconds(notice.seconds))
      guard !Task.isCancelled else { return }
      self.notice = nil
    }
  }

  // MARK: 快速查看、打开方式、废纸篓（体检 C7）

  /// ⌘Y：打开 / 缩回快速查看（选中的不是文件时只有提示音）
  func toggleQuickLook() {
    if isQuickLooking {
      isQuickLooking = false
      closeQuickLook(true)
    } else if let item = selectedItem, isFile(item) {
      isQuickLooking = true
      showsQuickLookContent = true
      openQuickLook()
    } else {
      NSSound.beep()
    }
  }

  /// 预览浮层收走了（缩回放完、点了外面、跟着启动器收起）：同步状态、拆掉预览
  func quickLookDidHide() {
    isQuickLooking = false
    showsQuickLookContent = false
  }

  /// 预览的文件：选中的不是文件时 nil（浮层里写「没有可预览的文件」）
  var quickLookURL: URL? {
    guard let item = selectedItem, isFile(item) else { return nil }
    return URL(filePath: item.target)
  }

  /// 右键菜单里的「快速查看」：先选中被点的那一行
  private func quickLook(_ item: LauncherItem) {
    if let index = results.firstIndex(of: item) { selection = index }
    if !isQuickLooking { toggleQuickLook() }
  }

  /// 移到废纸篓（能放回，按 D2「只确认不可撤销的」不二次确认）：刘海岛说一声，结果行原地删掉（settle）
  private func moveToTrash(_ item: LauncherItem) {
    Task {
      do {
        try await recycle(URL(filePath: item.target))
      } catch {
        island?.show("没能移到废纸篓", detail: error.localizedDescription, tone: .error)
        return
      }
      island?.show("已移到废纸篓「\(item.title)」", symbol: "trash")
      let index = selection
      withAnimation(Style.Motion.settle.animation(reduced: Style.reduceMotion)) {
        if isShowingRecent {
          search()
        } else {
          results.removeAll { $0.id == item.id }
        }
      }
      selection = min(index, max(results.count - 1, 0))
    }
  }

  /// 默认浏览器以外能开网页的 App（按 https 问 LaunchServices，不读网页）。
  /// ponytail: 登记了 https 的非浏览器 App 也会列出来，真碰到再按 bundle id 滤
  static func otherBrowsers() -> [URL] {
    guard let https = URL(string: "https:") else { return [] }
    let workspace = NSWorkspace.shared
    let resolved = { (url: URL) in url.resolvingSymlinksInPath().path }
    var seen = Set([workspace.urlForApplication(toOpen: https).map(resolved)].compactMap { $0 })
    return workspace.urlsForApplications(toOpen: https).filter {
      seen.insert(resolved($0)).inserted
    }
  }

  /// 能打开这种类型的 App：默认的排第一（标「默认」），最多 5 个；按类型问，不读文件本身
  static func applications(toOpen type: UTType) -> [(url: URL, isDefault: Bool)] {
    let workspace = NSWorkspace.shared
    let preferred = workspace.urlForApplication(toOpen: type)
    var seen = Set<String>()
    return ([preferred].compactMap { $0 } + workspace.urlsForApplications(toOpen: type))
      .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
      .prefix(5)
      .map { ($0, $0 == preferred) }
  }

  /// App 的显示名（访达开着「显示所有扩展名」时去掉 .app）
  static func appName(_ url: URL) -> String {
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  private var otherBrowsers: [URL] {
    if let browserCache { return browserCache }
    let found = browsers()
    browserCache = found
    return found
  }

  /// 「用 X 打开」的 App：网址是默认浏览器以外的浏览器，文件是能开这种类型的 App
  private func openers(for item: LauncherItem) -> [(url: URL, isDefault: Bool)] {
    if isWebLink(item) { return otherBrowsers.map { ($0, false) } }
    guard isFile(item), let type = item.contentType else { return [] }
    if let cached = applicationCache[type.identifier] { return cached }
    let found = applications(type)
    applicationCache[type.identifier] = found
    return found
  }

  // MARK: 键盘

  func handleCommand(_ selector: Selector) -> Bool {
    if showsActions { return handleMenuCommand(selector) }
    switch selector {
    case #selector(NSResponder.moveUp(_:)): move(by: -1)
    case #selector(NSResponder.moveDown(_:)): move(by: 1)
    // ⌥↩ 来的是 insertNewlineIgnoringFieldEditor:、⌃↩ 是 insertLineBreak:；⌃O 这类别的键绑定也会发这两个，
    // 所以要确认真是回车键，再按当时按住的修饰键分（别的键绑定吞掉，不做事）
    case #selector(NSResponder.insertNewline(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      guard Style.isReturnKey, let event = NSApp.currentEvent else { return true }
      if event.modifierFlags.contains(.option) {
        searchInFinder()
      } else if event.modifierFlags.contains(.control) {
        searchWeb()
      } else if let selectedItem {
        execute(selectedItem)
      }
    case #selector(NSResponder.insertTab(_:)):
      complete()  // 没得补也吞掉，不让焦点跳到别的控件
    // →：光标在搜索词末尾、有选中项时打开动作菜单（同剪贴板），否则照常往右移光标
    case #selector(NSResponder.moveRight(_:))
    where selectedItem != nil && Self.caretAtEnd(of: query):
      toggleActions()
    case #selector(NSResponder.cancelOperation(_:)):
      forgotten = nil
      if isQuickLooking {
        toggleQuickLook()  // 先缩回预览
      } else if armed != nil {
        armed = nil  // 先撤掉上膛，再清空搜索
      } else {
        guard !query.isEmpty else { return false }  // 没有查询：交给窗口关闭
        query = ""
      }
    default: return false
    }
    return true
  }

  /// 搜索框的光标在最后（没有选中文字）；拿不到字段编辑器时（单测）看有没有字（同剪贴板）
  private static func caretAtEnd(of text: String) -> Bool {
    guard let editor = NSApp.currentEvent?.window?.firstResponder as? NSTextView,
      editor.isFieldEditor
    else { return text.isEmpty }
    let selection = editor.selectedRange()
    return selection.length == 0 && selection.location == (editor.string as NSString).length
  }

  /// 动作菜单开着（和剪贴板一致）：↑↓ 选、↩ 执行、Esc 只关菜单；菜单里标着的 ⇥ ⌥↩ ⌃↩ 和 ⌘ 键一样先关菜单再照常做，
  /// ⌃O 这类也发换行命令的别的键吞掉（不往过滤框里插换行），其余（左右移光标、删字）交还输入框
  private func handleMenuCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)): moveAction(by: -1)
    case #selector(NSResponder.moveDown(_:)): moveAction(by: 1)
    case #selector(NSResponder.insertNewline(_:)): runSelectedAction()
    case #selector(NSResponder.cancelOperation(_:)): showsActions = false
    case #selector(NSResponder.moveLeft(_:)) where actionQuery.isEmpty: showsActions = false
    case #selector(NSResponder.insertTab(_:)):
      showsActions = false
      complete()
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      guard Style.isReturnKey else { break }
      showsActions = false
      return handleCommand(selector)
    default: return false
    }
    return true
  }

  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    // 不看大写锁定、fn 和数字键盘标志（方向键带着后两个），和 OverlayPanel 的 ⌘W 同一套判断
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = Int(event.keyCode)
    let handled: Bool
    switch modifiers {
    case .command where key == kVK_ANSI_K:
      toggleActions()
      return true
    case .command: handled = handleCommandKey(event)
    case [.command, .option] where key == kVK_UpArrow || key == kVK_DownArrow:
      handled = moveFavorite(by: key == kVK_UpArrow ? -1 : 1)
    case [.command, .shift] where key == kVK_ANSI_C:
      guard let item = selectedItem, isWebLink(item), !Self.fieldHasSelection(event) else {
        return false
      }
      copy(item, .markdown)
      handled = true
    default: return false
    }
    // 做了就收起动作菜单；没做的（过滤框里的复制、粘贴）菜单留着
    if handled { showsActions = false }
    return handled
  }

  private static func fieldHasSelection(_ event: NSEvent) -> Bool {
    ((event.window?.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
  }

  private func handleCommandKey(_ event: NSEvent) -> Bool {
    switch Int(event.keyCode) {
    case kVK_Return:
      if let item = selectedItem { commandReturn(item) }
    // 「常用」里 ⌘⌫：忘掉这一项（有查询、或 ⌘K 过滤框里有字时 ⌘⌫ 照常删到行首）；收藏上没有这个动作，响提示音
    case kVK_Delete where isShowingRecent && (!showsActions || actionQuery.isEmpty):
      if let item = selectedItem, isCommon(item) { forget(item) } else { NSSound.beep() }
    // ⌘Z：撤销刚才的移除；没有可撤的、或 ⌘K 过滤框里有字时交还输入框自己的撤销
    case kVK_ANSI_Z
    where query.isEmpty && forgotten != nil && (!showsActions || actionQuery.isEmpty):
      undoForget()
    case kVK_ANSI_C where !Self.fieldHasSelection(event):
      guard let item = selectedItem, copyTitle(for: item) != nil else { return false }
      copy(item)
    case kVK_ANSI_D:
      guard let item = selectedItem, canFavorite(item) else { return false }
      toggleFavorite(item)
    case kVK_ANSI_Y:
      toggleQuickLook()
    case kVK_ANSI_Comma:
      close()
      openSettings()
    default:
      guard let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      if digit < results.count { execute(results[digit]) }
    }
    return true
  }

  /// ⌘↩：App / 文件在访达中显示（find 搜到的文件反过来是打开），计算结果只复制，网址用第二个浏览器打开
  /// （没有就提示音，体检 D7）
  func commandReturn(_ item: LauncherItem) {
    if let request = commandRequest, [.app, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      if verb == .kill || (verb != .forcequit && item.target != SystemCommands.finderPath) {
        runTarget(item, verb, commandKey: true)
      }
      return
    }
    if isWebLink(item) {
      guard let browser = otherBrowsers.first, let url = URL(string: item.target) else {
        return NSSound.beep()
      }
      return open(url, item.kind == .url ? item : nil, with: browser)
    }
    switch item.kind {
    case .app, .path:
      if revealsOnReturn(item) { return open(URL(filePath: item.target), item) }
      close()
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
    case .calculation:
      copy(item)
    default:
      NSSound.beep()  // 以前吞掉这个键、什么都不响
    }
  }

  enum CopyFormat {
    /// 路径 / 网址 / 计算结果（⌘C）
    case value
    /// [标题](网址)（⇧⌘C）
    case markdown
    case title
    /// 计算结果 ⌘K 里的「复制原始数字」「复制十六进制」…（体检 D11）
    case calculation(Calculator.Copy)
  }

  /// ⌘C：复制路径 / 网址 / 计算结果（⌘↩ 的计算结果也走这里）；网址另有 Markdown 链接、标题。面板同时收起，用刘海说
  /// 复制了什么；这些是本 App 给出的新文字，同时记进剪贴板历史（mac-native §5）
  func copy(_ item: LauncherItem, _ format: CopyFormat = .value) {
    let text: String
    let title: String?
    switch format {
    case .value: (text, title) = (item.payload ?? item.target, copyTitle(for: item))
    case .markdown:
      (text, title) = (Self.markdownLink(title: item.title, url: item.target), "复制为 Markdown 链接")
    case .title: (text, title) = (item.title, "复制标题")
    case .calculation(let copy): (text, title) = (copy.text, copy.title)
    }
    Paster.write(string: text, record: true)
    close()
    guard let title else { return }
    let isPath = (item.kind == .app || item.kind == .path) && copyTitle(for: item) == title
    island?.show(
      "已" + title,
      detail: isPath ? (text as NSString).abbreviatingWithTildeInPath : Island.excerpt(text))
  }

  /// [标题](网址)：标题里的方括号、网址里的空格和右括号转义，粘进 Markdown 不断链
  static func markdownLink(title: String, url: String) -> String {
    let title = title.replacing("[", with: "\\[").replacing("]", with: "\\]")
    let url = url.replacing(" ", with: "%20").replacing(")", with: "%29")
    return "[\(title)](\(url))"
  }

  private func move(by offset: Int) {
    guard !results.isEmpty else { return }
    armed = nil
    forgotten = nil
    selectionMotion = Style.isKeyRepeat ? .instant : .snap
    selection = (selection + offset + results.count) % results.count
    userMovedSelection = true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]

  // MARK: ⌘K 动作菜单 / 右键菜单

  /// 选中项的动作（⌘K）
  var actions: [ActionMenu.Item] { selectedItem.map(actions(for:)) ?? [] }

  /// 一项能做的全部动作（N8；右键菜单同一份，体检 C8）：主动作 ↩ 在最前，每行写上键位，执行的和按键是同一段代码。
  /// 分节：打开 ｜ 用别的 App 打开 ｜ 复制 ｜ 搜索框（补全、⌥↩、⌃↩）｜ 收藏、移除、废纸篓
  func actions(for item: LauncherItem) -> [ActionMenu.Item] {
    var actions: [ActionMenu.Item] = []
    func add(
      _ title: String, _ symbol: String?, _ shortcut: String? = nil, image: NSImage? = nil,
      detail: String? = nil, section: Int, destructive: Bool = false,
      _ run: @escaping () -> Void
    ) {
      actions.append(
        ActionMenu.Item(
          title: title, symbol: symbol, image: image, detail: detail, shortcut: shortcut,
          id: "\(actions.count)", section: section, isDestructive: destructive, run: run))
    }
    // 0 打开
    let primary = primaryAction(for: item)
    add(
      primary.title, primary.symbol, "↩", section: 0,
      destructive: isDangerous(item, commandKey: false)
    ) { [unowned self] in execute(item) }
    // 网址的 ⌘↩ 就是下面浏览器里的第一个
    if !isWebLink(item), let secondary = commandReturnAction(for: item) {
      add(
        secondary.title, secondary.symbol, "⌘↩", section: 0,
        destructive: isDangerous(item, commandKey: true)
      ) { [unowned self] in commandReturn(item) }
    }
    if isFile(item) {
      add("快速查看", "eye", "⌘Y", section: 0) { [unowned self] in quickLook(item) }
    }
    // 1 用别的 App 打开：网址是默认浏览器以外的浏览器（第一个是 ⌘↩），文件是能开这种类型的 App（默认的排第一）
    let web = isWebLink(item)
    for (index, app) in openers(for: item).enumerated() {
      add(
        "用「\(Self.appName(app.url))」打开", nil, web && index == 0 ? "⌘↩" : nil,
        image: LauncherIcons.icon(for: app.url.path), detail: app.isDefault ? "默认" : nil,
        section: 1
      ) { [unowned self] in
        if web {
          if let url = URL(string: item.target) {
            open(url, item.kind == .url ? item : nil, with: app.url)
          }
        } else {
          open(URL(filePath: item.target), item, with: app.url)
        }
      }
    }
    // 2 复制（计算结果的 ⌘C 和 ⌘↩ 一样，不重复列）；复制路径和剪贴板 ⌘K 的「复制路径」同一个符号 link（mac-whisker §3）
    if item.kind != .calculation, let title = copyTitle(for: item) {
      let symbol = item.kind == .app || item.kind == .path ? "link" : "doc.on.doc"
      add(title, symbol, "⌘C", section: 2) { [unowned self] in copy(item) }
    }
    if web {
      add("复制为 Markdown 链接", "text.badge.plus", "⇧⌘C", section: 2) { [unowned self] in
        copy(item, .markdown)
      }
      add("复制标题", "text.quote", section: 2) { [unowned self] in copy(item, .title) }
    }
    // 计算结果：原始数字（不分组、不带单位）、别的进制（体检 D11）
    if item.kind == .calculation {
      for extra in Calculator.result(for: item.target)?.copies ?? [] {
        add(extra.title, "doc.on.doc", detail: extra.text, section: 2) { [unowned self] in
          copy(item, .calculation(extra))
        }
      }
    }
    // 3 搜索框：提示行的主动作就是补全
    if item.kind != .prompt, Self.completion(for: item) != nil {
      add("补全到搜索框", "arrow.right.to.line", "⇥", section: 3) { [unowned self] in
        complete(item)
      }
    }
    if let title = finderSearchTitle {
      add(title, "doc.text.magnifyingglass", "⌥↩", section: 3) { [unowned self] in
        searchInFinder()
      }
    }
    if let title = webSearchTitle {
      add(title, "globe", "⌃↩", section: 3) { [unowned self] in searchWeb() }
    }
    // 4 收藏、移除、废纸篓
    if canFavorite(item) {
      let favorite = isFavorite(item)
      add(favorite ? "取消收藏" : "加入收藏", favorite ? "star.slash" : "star", "⌘D", section: 4) {
        [unowned self] in toggleFavorite(item)
      }
    }
    if isCommon(item) {
      add("从常用中移除", "clock.badge.xmark", "⌘⌫", section: 4) { [unowned self] in forget(item) }
    }
    if isFile(item) {
      add("移到废纸篓", "trash", section: 4, destructive: true) { [unowned self] in
        moveToTrash(item)
      }
    }
    return actions
  }

  /// 按 actionQuery 过滤（和剪贴板的两个菜单同一个 ActionMenu.filter：子串 + 中文标题的拼音前缀）
  var filteredActions: [ActionMenu.Item] { ActionMenu.filter(actions, query: actionQuery) }

  /// ⌘K / 底栏「动作」：没有选中项时不打开。⌘Y 预览开着时先缩回它：菜单画在被预览盖住的启动器里，
  /// 不然搜索框悄悄变成过滤动作、↑↓ 改的是看不见的菜单
  func toggleActions() {
    guard showsActions || selectedItem != nil else { return }
    if isQuickLooking { toggleQuickLook() }
    showsActions.toggle()
  }

  private func moveAction(by offset: Int) {
    let count = filteredActions.count
    guard count > 0 else { return }
    actionSelection = (actionSelection + offset + count) % count
  }

  private func runSelectedAction() {
    let actions = filteredActions
    guard actions.indices.contains(actionSelection) else { return NSSound.beep() }
    run(actions[actionSelection])
  }

  /// 先关菜单再执行：执行里要改查询（补全）、收起面板
  func run(_ action: ActionMenu.Item) {
    showsActions = false
    action.run()
  }
}
