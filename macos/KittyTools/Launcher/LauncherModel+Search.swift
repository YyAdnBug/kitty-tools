// 启动器的搜索（第五轮体检 H1 从 LauncherModel.swift 拆出）：呼出 / 收起时的准备（扫 App、浏览历史），按查询排结果（search），文件 / 系统命令 / 计算 / 汇率 / ip / 提醒 / 保持唤醒 / 插件这些候选行，路径模式（以 / 或 ~/ 开头，PathBrowser）列目录，空查询的收藏和常用，重搜后保住选中。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension LauncherModel {
  /// 空查询：「收藏」+「常用」（一个空格是文件搜索，不算）
  var isShowingRecent: Bool {
    fileRequest == nil && query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// 列表里的分组标题：空查询「收藏」「常用」，文件搜索只输了关键词时「最近打开和下载的文件」，
  /// 系统命令只输了关键词时「正在运行的 App」/「可推出的磁盘」
  var groups: [Group] {
    if isShowingRecent {
      var groups: [Group] = []
      if favoriteCount > 0 {
        groups.append(
          Group(
            row: 0,
            title: String(
              localized: "launcher.group.favorites", defaultValue: "收藏", comment: "空搜索框里收藏那一组的标题")))
      }
      if favoriteCount == 0 || results.count > favoriteCount {
        groups.append(Group(row: favoriteCount, title: String(localized: "常用")))
      }
      return groups
    }
    if let commandRequest, commandRequest.terms.isEmpty {
      return [Group(row: 0, title: commandRequest.verb.groupTitle)]
    }
    return fileRequest?.terms.isEmpty == true
      ? [Group(row: 0, title: String(localized: "最近打开和下载的文件"))] : []
  }

  /// 第一个分组标题
  var groupTitle: String? { groups.first?.title }

  /// 内置动作（按此刻的状态）
  var builtIns: [LauncherItem] { LauncherItem.actions(actionState()) }

  /// 脚本命令的行（按此刻的脚本库）
  private var scriptItems: [LauncherItem] {
    let scripts = activeScripts
    let settings = commandSettings()
    if let scriptCache, scriptCache.scripts == scripts, scriptCache.settings == settings {
      return scriptCache.items
    }
    let items = scripts.map { LauncherItem.script($0, alias: scriptAlias($0)) }
    scriptCache = (scripts, settings, items)
    return items
  }

  /// 脚本库重读完、换上了新的：开着、用户还没挑过选中项时按新的重搜（同后台扫完 App 目录）
  func scriptsChanged() {
    // 去掉了下载标记的不再记着：同一个位置以后又放进一个新下载的，照样先看一眼
    let downloaded = Set(scripts().filter(\.isDownloaded).map(\.path))
    approvedScripts.formIntersection(downloaded)
    if isShown, !userMovedSelection, armed == nil, review == nil, fileRequest == nil,
      commandRequest == nil
    {
      search()
    }
  }
  /// 开着的功能（Feature）：cb 那一行要剪贴板开着、fy 那一行要翻译开着
  var features: Set<Feature> { actionState().features }

  /// 启动时、呼出时应用程序目录变了时扫 App 目录。在后台扫（约 65 ms，原来在主线程：装完 App 马上按 ⌥Space 要卡这么久，
  /// 第三轮体检 P3）：面板先用旧列表出来，扫完换上——开着、正在搜的按新目录重搜（用户还没挪过选中时）。
  /// App 路径的图标缓存跟着清掉：升级换了图标的下次按新的读（B3）
  func rescanApps() {
    guard !isFixture, scanTask == nil else { return }
    // 扫之前取：扫的时候又装了 App，下次呼出照样看得出目录变了
    let signature = AppCatalog.signature()
    scanTask = Task {
      let scanned = await AppCatalog.scanInBackground()
      scanTask = nil
      LauncherIcons.forget((apps + scanned).filter { $0.kind == .app }.map(\.target))
      apps = scanned
      appsSignature = signature
      appsScannedAt = .now
      if isShown, !userMovedSelection, armed == nil, fileRequest == nil, commandRequest == nil,
        !query.trimmingCharacters(in: .whitespaces).isEmpty
      {
        search()
      }
    }
  }

  /// 呼出前：应用程序目录变了就重扫（后台扫，扫完刚装的 App 就搜得到）；60 秒内没执行就收起的，接着上次的查询和选中项
  func prepareForShow(now: Date = .now) {
    isShown = true
    // 搜菜单项的那个 App（N3）：这一刻的前台（启动器不激活本 App，前台还是底下那个）
    menuTarget = menuApp()
    menuExpiry?.cancel()
    menuExpiry = nil
    refreshShortcuts(now: now)
    if !isFixture,
      Self.needsRescan(
        scannedAt: appsScannedAt, scanned: appsSignature, now: AppCatalog.signature())
    {
      rescanApps()
    }
    browserCache = nil
    applicationCache = [:]
    checksFolderAccess = !isFixture
    if !isFixture { checkPresence() }
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
        LauncherMatch.isLongEnough(query)
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
    isShown = false
    menuTarget = nil
    // 读到的菜单只留半分钟（插件说明里这么写的）：这期间再呼出同一个 App 不用重读
    menuExpiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(MenuSearch.staleAfter))
      guard !Task.isCancelled, let self, !isShown else { return }
      menuRows = nil
    }
    files.forgetItems()
    // 路径模式读过的目录不留（再呼出重读：这期间可能有变化）；还在读的不要了
    for read in pathReads.values { read.cancel() }
    pathReads = [:]
    pathListings = [:]
    pathWait?.cancel()
    pathWait = nil
    showsActions = false
    error = nil
    armed = nil
    review = nil
    if let output {
      self.output = nil
      if output.isRunning { detach(output.script) }
    }
    listTask?.cancel()
    listTask = nil
    filterTask?.task.cancel()
    filterTask = nil
    filterRows = [:]
    runsWhenListed = false
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
    // ip 再呼出时重读重查：这期间可能换了网络
    cancelIPLookups()
    ipLookups = [:]
    ipLocal = nil
    ratesTask?.cancel()
    ratesTask = nil
    ratesFailed = false
    // 打着密码参数没跑就收起的也不留（第三轮 C3：60 秒内再呼出时还看得见）
    if executed || query.isEmpty || holdsSecret {
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

  func search() {
    error = nil
    // 路径模式在下面认；先清掉，别让上一次的读完、0.15 秒到点时动到别的模式的结果
    pathRequest = nil
    pathPending = false
    pathWait?.cancel()
    pathWait = nil
    armed = nil
    listTask?.cancel()
    listTask = nil
    runsWhenListed = false
    selectionMotion = .instant
    selection = 0
    userMovedSelection = false
    shownFileRequest = nil
    favoriteCount = 0
    definitionTask?.cancel()
    // 「命令」表（拍板 C3 C4）：开头是改过的别名的换回原关键词交给原来那一套；原关键词改掉了 / 关掉的挡掉
    let settings = commandSettings()
    let (command, blocked) = LauncherCommands.canonical(query, settings: settings)
    func allowed(_ id: String) -> Bool { settings.isOn(id) && !blocked.contains(id) }
    // 打字路过 ip（「iphone」）时还没查完的不要了
    if !(allowed("builtin:ip") && IPAddresses.matches(command)) { cancelIPLookups() }
    // 汇率同样：还在等那 0.3 s 的撤掉（「命令」表里关掉了汇率换算也撤掉）
    let currencyOn = settings.isOn("builtin:currency")
    if !currencyOn || ExchangeRates.request(for: query) == nil {
      ratesTask?.cancel()
      ratesTask = nil
    }
    fileRequest = FileSearch.request(for: command).flatMap {
      allowed($0.mode == .open ? "builtin:open" : "builtin:find") ? $0 : nil
    }
    commandRequest =
      fileRequest == nil
      ? SystemCommands.request(for: command).flatMap {
        allowed("builtin:" + $0.verb.rawValue) ? $0 : nil
      } : nil
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
    // 以 / 或 ~/ 开头：路径模式，只出路径的行（2026-11-18，PathBrowser）
    pathRequest = PathBrowser.request(for: query)
    if let pathRequest {
      showPath(pathRequest)
      return
    }
    emptyText = String(localized: "没有匹配的结果")
    let features = features
    if features.contains(.translate), allowed("builtin:fy"), let text = Self.translateQuery(command)
    {
      results = [Self.translateItem(text)]
      lookUpDefinition(text)
      return
    }
    // 「cb 词」（带空格）只有这一行（N9）；单输 cb 时它排第一，后面照常接本地结果（体检 B33）
    if features.contains(.clipboard), allowed("builtin:cb"), let keyword = Self.clipQuery(command),
      command.count > 2
    {
      results = [Self.clipItem(keyword)]
      return
    }
    // 「提醒 …」（带空格）只列提醒：能认出时间的先是「建一条」，再是已有的提醒（D2 D4）；单输「提醒」出补全提示
    if features.contains(.reminders), allowed("builtin:reminder"),
      let rest = ReminderPhrase.query(command)
    {
      emptyText = String(localized: "还没有提醒：在「提醒 」后面接着写时间和内容，如「10分钟 喝水」")
      results = Self.reminderItems(rest, list: reminders(), now: .now)
      return
    }
    // 「awake …」「保持唤醒 …」（带空格）只列保持唤醒的几行：开着时第一行是停止，再是认出来的那一段或几档时长（插件 B2）
    if features.contains(.keepAwake), let rest = KeepAwakePlan.query(command) {
      results = Self.keepAwakeItems(rest, status: keepAwakeStatus(), now: .now)
      return
    }
    // 「别名 空格 文字」：交给那条脚本（B2），它的那几行排在普通结果前面
    let invocation = ScriptCommand.invocation(for: query, in: activeScripts, alias: scriptAlias)
    let invocationRows = invocation.map(invocationRows) ?? []
    // 下载来、还没看过的：那一行（↩ 先看全文）不排在最前，接在普通结果后面（复查：同别名一字不差的那一处）
    let trusted = invocation.map {
      !$0.script.isDownloaded || approvedScripts.contains($0.script.path)
    }
    // 自己过滤的没跑成、下面又有别的结果：不留那行错误（同普通列表）；不再打这条脚本时忘掉没跑成的，再打到它重跑一次
    let filterFailed = invocation.map { filterRows[$0.script.path]?.failed == true } ?? false
    for (path, cached) in filterRows where cached.failed && path != invocation?.script.path {
      filterRows[path] = nil
    }
    var leading = trusted == false ? [] : invocationRows
    let trailing = trusted == false ? invocationRows : []
    let query = query.trimmingCharacters(in: .whitespaces)
    let typed = command.trimmingCharacters(in: .whitespaces)
    let ip = allowed("builtin:ip") && IPAddresses.matches(typed) ? ipItems() : []
    // 内置命令的提示行：关掉的、原关键词改掉了的不出，改了别名的把「kill 空格」换成别名
    func labeled(_ items: [LauncherItem]) -> [LauncherItem] {
      items.compactMap { item in
        if let id = LauncherCommands.builtIn(forPrompt: item.target)?.id, blocked.contains(id) {
          return nil
        }
        return LauncherCommands.relabel(item, settings: settings)
      }
    }
    if query.isEmpty {
      results = home()
      return
    }
    let engines = engines()
    let direct = DirectItems.items(for: query)
    let keyword = WebSearch.keywordItem(for: query, engines: engines)
    let prompts = WebSearch.promptItems(for: query, engines: engines)
    let filePrompts = FileSearch.promptItems(for: typed)
    let systemPrompts = SystemCommands.promptItems(for: typed)
    let clip =
      features.contains(.clipboard) && allowed("builtin:cb") && Self.clipQuery(typed) != nil
      ? [Self.clipItem("")] : []
    let fy = Self.translatePrompts(for: features.contains(.translate) ? typed : "")
    let currency = ExchangeRates.promptItems(for: typed)
    // 「新建提醒…」提示排在本地结果后面：输「提醒」想打开系统「提醒事项」的，↩ 照旧打开它
    let tx = features.contains(.reminders) ? labeled(Self.reminderPrompts(for: typed)) : []
    // 没添加的插件：打到它的名字或关键词时，本地结果后面、兜底前面一行「添加…插件」（A4）
    let offers = Self.pluginOffers(for: typed, added: features)
    let exactPrompts: [LauncherItem] =
      prompts.exact + labeled(filePrompts.exact + systemPrompts.exact)
    let partialPrompts: [LauncherItem] =
      prompts.partial
      + labeled(filePrompts.partial + systemPrompts.partial + fy.partial + currency.partial)
    let calculation = calculationItem(query, currency: currencyOn)
    // 货币打到一半（「100 美元 转 英」）：紧跟在计算结果的位置列候选；有计算结果时不列（单位换算、打全了的汇率）
    let currencyHints =
      calculation == nil && currencyOn
      ? ExchangeRates.suggestions(for: query, recents: recentCurrencies) : []
    let top: [LauncherItem] =
      clip + labeled(fy.exact + currency.exact) + ip + direct + [calculation].compactMap { $0 }
      + currencyHints + [keyword].compactMap { $0 } + exactPrompts
    // 书签、浏览历史至少 2 个字才搜（1 个字母命中太多；含中文时 1 个字就搜，U8）
    let longEnough = LauncherMatch.isLongEnough(query)
    let bookmarks = longEnough ? bookmarkItems() : []
    let used = usedLocations(excluding: bookmarks)
    // 书签先粗筛（几千个每敲一个字都完整打分太慢，P3；同 visited）
    let tokens = LauncherMatch.tokens(query)
    let scriptItems = scriptItems
    let searchable = searchableApps
    let local = LauncherMatch.rank(
      searchable.items + builtIns + (scriptsOn() ? LauncherItem.scriptActions : []) + systemItems
        + scriptItems
        + WebSearch.quicklinkItems(engines: engines)
        + bookmarks.filter { LauncherMatch.mayMatch(tokens, $0) } + used, query: query
    ) { usage.boost(for: $0, query: query) }
    // 脚本的别名一字不差：排第一（拍板 C1）。下载来、还没看过的不算（第三轮评审：头部写个 safari、ip 就能抢走第一行）
    let aliased = Self.aliased(
      scriptItems,
      scripts: activeScripts.filter { !$0.isDownloaded || approvedScripts.contains($0.path) },
      query: query, alias: scriptAlias)
    // 用户给 App 设的完整别名优先于普通结果和无参数脚本；同别名的 App 保留使用排序，最后统一按 id 去重。
    let aliasedApps = local.filter { searchable.aliases.exactlyMatches($0, query: query) }
    let history = longEnough ? visited(query, excluding: bookmarks + used) : []
    // 前台 App 的菜单项（N3）：同书签至少 2 个字才搜，排在本地结果后面、浏览历史前面
    let menus = longEnough ? menuMatches(query) : []
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
    let ordered = Self.promoting(local, over: top) { usage.chose($0, query: query) }
    if filterFailed, (aliased + ordered).contains(where: { ![.search, .prompt].contains($0.kind) })
    {
      leading = []
    }
    // 菜单项不当默认选中的第一行（↩ 不会误按下菜单里的命令）：前面一条本地结果都没有时排到兜底搜索后面
    let head = leading + aliasedApps + aliased + ordered + trailing
    let tail = tx + history + partialPrompts + offers + fallback
    results =
      (head.isEmpty ? tail + menus : head + menus + tail).filter { seen.insert($0.id).inserted }
    if let invocation { startList(invocation) }
  }

  /// 前台 App 的菜单项里对上 query 的（N3，MenuSearch）：读过、没过期的直接过滤；没读过、过期了在后台读一次（读完开着就
  /// 重搜），这期间先用同一个 App 上一回读到的
  private func menuMatches(_ query: String) -> [LauncherItem] {
    guard let app = menuTarget, !app.isTerminated else { return [] }
    let cached = menuRows?.pid == app.processIdentifier ? menuRows : nil
    if cached.map({ Date.now.timeIntervalSince($0.readAt) > MenuSearch.staleAfter }) ?? true {
      loadMenu(app)
    }
    return cached.map { MenuSearch.matched($0.items, query: query) } ?? []
  }

  /// 在后台读 app 的菜单、建好行（同一时刻只读一次）。读到的（没读完、一项都没有也记下，staleAfter 以内不重读：不然没有
  /// 菜单栏的 App 每打一个字都读一遍）换上；还开着、还是这个 App 就按新的重搜，**选中留在原来那一项**（没动过选中时也
  /// 不让它从第一行跳走）
  private func loadMenu(_ app: NSRunningApplication) {
    guard menuTask == nil else { return }
    let pid = app.processIdentifier
    let name = app.localizedName ?? ""
    let path = app.bundleURL?.path
    menuTask = Task {
      let rows = await readMenu(pid, name, path)
      menuTask = nil
      menuRows = (pid, .now, rows)
      guard isShown, menuTarget?.processIdentifier == pid, armed == nil, fileRequest == nil,
        commandRequest == nil, pathRequest == nil, review == nil, output == nil,
        LauncherMatch.isLongEnough(query)
      else { return }
      let kept = selectedItem?.id
      let moved = userMovedSelection
      search()
      if let kept { reselect(kept) }
      userMovedSelection = moved
    }
  }

  /// 测试等读菜单那一次读完
  func menuLookup() async { await menuTask?.value }

  /// 别名（关键词）和输入一字不差的脚本行（不分大小写、去掉两头空白）。纯函数，配单测
  static func aliased(
    _ items: [LauncherItem], scripts: [ScriptCommand], query: String,
    alias: (ScriptCommand) -> String? = { $0.keyword }
  ) -> [LauncherItem] {
    let text = LauncherMatch.fold(query.trimmingCharacters(in: .whitespaces))
    guard !text.isEmpty else { return [] }
    let paths = Set(scripts.filter { alias($0) == text }.map(\.path))
    return items.filter { paths.contains($0.target) }
  }

  /// 本地结果里在完全相同的输入下选过的（使用记录里这个查询的分 > 0）排到固定行（剪贴板、翻译、ip、直达、计算、
  /// 关键词提示）前面，彼此顺序不变；其余本地结果照旧跟在固定行后面（第四轮体检 E8：输 gh 选过 Ghostty 的，
  /// 下次 gh 第一行还是「用 GitHub 搜索…」）。纯函数，配单测
  static func promoting(
    _ local: [LauncherItem], over top: [LauncherItem], chosen: (LauncherItem) -> Bool
  ) -> [LauncherItem] {
    let picked = local.filter(chosen)
    return picked + top + local.filter { !chosen($0) }
  }

  /// 浏览历史里匹配上的（体检 D8）：去掉已经是书签 / 用过的网址（不分大小写），只比标题和去协议的网址、不加使用分，
  /// 最多 5 行；副标题按这一刻拼上「3 天前」。不算「本地结果」：只有历史匹配上时照样出兜底搜索
  private func visited(_ query: String, excluding known: [LauncherItem]) -> [LauncherItem] {
    let pages = historyItems()
    guard !pages.isEmpty else { return [] }
    let seen = Set(known.map { $0.target.lowercased() })
    // 先粗筛（LauncherMatch.mayMatch：匹配分档的必要条件）。3000 条直接排序要逐条切词，
    // Debug 构建实测本机 3000 条一次按键约 45 ms，粗筛后 10–15 ms。
    // ponytail: 还嫌慢就在 BrowserHistory 里存好拼接的小写名字，只做一次 contains
    let tokens = LauncherMatch.tokens(query)
    let candidates = pages.filter { page in
      LauncherMatch.mayMatch(tokens, page) && !seen.contains(page.target.lowercased())
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
      emptyText = verb == .port ? String(localized: "正在读取端口…") : String(localized: "正在读取进程…")
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
      case (.eject, true): String(localized: "没有可推出的磁盘")
      case (.eject, false): String(localized: "没有匹配的磁盘")
      case (.kill, true): String(localized: "没有后台进程")
      case (.kill, false) where terms.hasPrefix(":"): String(localized: "没有进程在监听这个端口")
      case (.port, true): String(localized: "没有找到在监听端口的进程")
      case (.port, false) where port != nil: String(localized: "没有找到监听这个端口的进程")
      case (.kill, false), (.port, false): String(localized: "没有匹配的进程")
      case (_, true): String(localized: "没有正在运行的 App")
      case (_, false): String(localized: "没有匹配的 App")
      }
  }

  /// 等 kill / port 的进程列完（单测、截图自检用）
  func processLookup() async { await processTask?.task.value }

  // MARK: 路径模式（PathBrowser）

  /// 路径模式的行：输入正好是一个文件夹就列它里面（第一行是它本身），不然在上一级里按最后一段筛。
  /// 要的目录还没读到：先留着上一次的结果，过 0.15 秒还没到才清空、写「正在读取…」
  private func showPath(_ request: PathBrowser.Request) {
    guard let parent = pathListing(request.directory) else { return waitForPath() }
    var directory = request.directory
    var typed = request.typedDirectory
    var filter = request.name
    var listing = parent
    if let folder = PathBrowser.folder(named: request.name, in: parent.entries) {
      directory = PathBrowser.child(folder.name, of: request.directory)
      typed += folder.name + "/"
      filter = ""
      guard let inside = pathListing(directory) else { return waitForPath() }
      listing = inside
    }
    pathWait?.cancel()
    pathWait = nil
    pathPending = false
    // 不在了的文件夹不出「这个文件夹」那一行
    var rows: [LauncherItem] =
      filter.isEmpty && listing.problem != .missing ? [pathFolderRow(directory, typed: typed)] : []
    if let problem = listing.problem {
      rows += pathProblemRows(problem, directory: directory)
      emptyText =
        problem == .missing
        ? String(localized: "找不到「\((typed as NSString).abbreviatingWithTildeInPath)」")
        : String(localized: "没有匹配的结果")
    } else {
      let picked = PathBrowser.pick(listing.entries, filter: filter, in: directory)
      rows += picked.entries.map { pathRow($0, in: directory, typed: typed) }
      let more = picked.total - picked.entries.count
      if more > 0 {
        rows.append(
          LauncherItem(
            kind: .prompt, target: Self.pathOpenPrefix + directory,
            title: String(localized: "还有 \(more) 项"),
            subtitle: String(localized: "接着输入名字筛选；↩ 在访达中打开")))
      }
      emptyText = String(localized: "没有名字里有「\(filter)」的项")
    }
    results = rows
  }

  /// 这个目录读到的东西；没读过就在主线程外读（读到了重搜），先交回 nil
  private func pathListing(_ directory: String) -> PathBrowser.Listing? {
    if let cached = pathListings[directory] { return cached }
    guard pathReads[directory] == nil else { return nil }
    let access = UserDefaults.standard.bool(forKey: Prefs.folderAccessRequested)
    let volumes = UserDefaults.standard.bool(forKey: Prefs.launcherVolumesAllowed)
    pathReads[directory] = Task {
      let listing = await PathBrowser.read(directory, folderAccess: access, volumes: volumes)
      guard !Task.isCancelled else { return }
      pathReads[directory] = nil
      pathListings[directory] = listing
      if pathRequest != nil { search() }
    }
    return nil
  }

  private func waitForPath() {
    pathPending = true
    guard pathWait == nil else { return }
    pathWait = Task {
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, pathRequest != nil else { return }
      results = []
      emptyText = String(localized: "正在读取…")
    }
  }

  /// 等路径模式要的目录都读完（单测用）
  func pathLookup() async {
    while let task = pathReads.values.first { await task.value }
  }

  /// 第一行：输入的这个文件夹本身（↩ 打开它，和以前输完路径直接 ↩ 一样）
  private func pathFolderRow(_ directory: String, typed: String) -> LauncherItem {
    let root = directory == "/"
    let location =
      root ? "" : FileSearch.location(of: (directory as NSString).deletingLastPathComponent)
    return LauncherItem(
      kind: .path, target: directory,
      title: root
        ? FileManager.default.displayName(atPath: "/") : (directory as NSString).lastPathComponent,
      subtitle: location.isEmpty
        ? String(localized: "这个文件夹") : String(localized: "\(location) · 这个文件夹"),
      completion: typed, contentType: .folder)
  }

  /// 目录里的一项：类型按扩展名（不读文件），Tab 补成「输入的目录 + 名字」（文件夹再加 /）
  private func pathRow(_ entry: PathBrowser.Entry, in directory: String, typed: String)
    -> LauncherItem
  {
    LauncherItem(
      kind: .path, target: PathBrowser.child(entry.name, of: directory), title: entry.name,
      subtitle: FileSearch.location(of: directory), names: [entry.key],
      completion: typed + entry.name + (entry.isFolder ? "/" : ""),
      contentType: PathBrowser.contentType(of: entry))
  }

  /// 没读的原因那一行
  private func pathProblemRows(_ problem: PathBrowser.Problem, directory: String) -> [LauncherItem]
  {
    // 不读磁盘取名字（受保护的位置读一下属性也会弹框）
    let name = directory == "/" ? "/" : (directory as NSString).lastPathComponent
    let finder = String(localized: "↩ 在访达中打开")
    switch problem {
    case .needsFolderAccess(let folder):
      return [
        LauncherItem(
          kind: .prompt, target: FileSearch.accessTarget,
          title: String(localized: "要先允许访问「\(folder)」才能列出里面的东西"),
          subtitle: String(localized: "↩ 允许访问（系统会逐个询问，只要一次）"))
      ]
    case .needsVolumeConsent(let volume):
      return [
        LauncherItem(
          kind: .prompt, target: Self.pathVolumes,
          title: String(localized: "读取「\(volume)」上的内容前先确认一次"),
          subtitle: String(localized: "↩ 允许读取外接盘和网络盘（系统可能会再问一次）"))
      ]
    case .otherAppsData:
      return [
        LauncherItem(
          kind: .prompt, target: Self.pathOpenPrefix + directory,
          title: String(localized: "「\(name)」是别的 App 的数据，这里不列"), subtitle: finder)
      ]
    case .denied:
      // 桌面、文稿这类问过授权被拒的：去系统设置改；别的（系统保护的）在访达里看
      if case .needsFolderAccess = PathBrowser.problem(
        at: directory, folderAccess: false, volumes: true)
      {
        return [
          LauncherItem(
            kind: .prompt, target: FileSearch.accessTarget,
            title: String(localized: "没有权限查看「\(name)」里的东西"),
            subtitle: String(localized: "↩ 打开系统设置 › \(Permissions.privacyPane) › 文件和文件夹"))
        ]
      }
      return [
        LauncherItem(
          kind: .prompt, target: Self.pathOpenPrefix + directory,
          title: String(localized: "没有权限查看「\(name)」里的东西"), subtitle: finder)
      ]
    case .missing: return []
    }
  }

  /// 路径模式里「在访达中打开」的行（目标是这个前缀 + 目录）、「允许读取外接盘」那一行
  static let pathOpenPrefix = "path-open:"
  static let pathVolumes = "path-volumes"

  /// ⇧Tab：路径模式里回到上一级
  func goUpPath() {
    guard pathRequest != nil, let up = PathBrowser.parentQuery(of: query) else {
      return NSSound.beep()
    }
    query = up
  }

  /// 收藏、常用里的文件、应用程序目录以外的 App 还在不在：在主线程外查（卡住的盘不能冻住 App），查完有变化就重列
  private func checkPresence() {
    guard presenceTask == nil else { return }
    let catalog = Set(apps.map(\.target))
    var candidates: [(kind: LauncherItem.Kind, target: String)] = usage.favorites.map {
      ($0.kind, $0.target)
    }
    for entry in usage.entries.values where entry.query.isEmpty {
      candidates.append((entry.kind, entry.target))
    }
    let paths = Set(
      candidates.filter { $0.kind == .path || ($0.kind == .app && !catalog.contains($0.target)) }
        .map(\.target))
    guard !paths.isEmpty else { return }
    presenceTask = Task {
      let missing = await PathBrowser.missing(Array(paths))
      presenceTask = nil
      guard missing != missingPaths else { return }
      missingPaths = missing
      if isShown, query.isEmpty, !userMovedSelection { search() }
    }
  }

  /// 查一遍在不在、等它查完（单测用：截图自检、单测里的面板不呼出，checkPresence 不会自己跑）
  func presenceCheck() async {
    checkPresence()
    await presenceTask?.value
  }

  /// 文件搜索：查询还在跑时留着上一次的结果（约 40 ms 后换掉，免得列表先空再长）；1 个字母不查
  private func searchFiles(_ request: FileSearch.Request) {
    guard !request.isTooShort else {
      files.stop()
      results = []
      emptyText = String(localized: "再输入一个字母")
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
    // 按路径缓存的条目（每批只转新到的）；查询词里没有拉丁字母时不转拼音（P3）
    let pinyin = FileSearch.needsPinyin(request.terms)
    let found = FileSearch.rank(
      hits, terms: request.terms, item: { files.item($0, pinyin: pinyin) },
      boost: { usage.boost(for: $0, query: query) })
    let whole = query.trimmingCharacters(in: .whitespaces)
    let searchable = searchableApps
    let named =
      request.terms.isEmpty || query.first?.isWhitespace == true
      ? []
      : LauncherMatch.rank(searchable.items + builtIns, query: whole) {
        usage.boost(for: $0, query: whole)
      }
    let selected = results.indices.contains(selection) ? results[selection].id : nil
    var seen = Set<String>()
    let aliased = named.filter { searchable.aliases.exactlyMatches($0, query: whole) }
    results = (aliased + named + found + [folderHint].compactMap { $0 }).filter {
      seen.insert($0.id).inserted
    }
    emptyText =
      request.terms.isEmpty ? String(localized: "最近没有打开或下载的文件") : String(localized: "没有匹配的文件")
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
      title: keyword.isEmpty
        ? String(localized: "打开剪贴板历史") : String(localized: "在剪贴板历史里搜索「\(keyword)」"),
      // 只输 cb 时说一下还能带关键词（2026-11-04：每个提示行都写怎么用）
      subtitle: keyword.isEmpty ? String(localized: "↩ 打开剪贴板面板；输入「cb 空格 关键词」直接搜") : "")
  }

  /// 「fy 文本」的文本（不分大小写；只输 fy 不算，出补全提示）
  static func translateQuery(_ query: String) -> String? {
    guard query.lowercased().hasPrefix("fy ") else { return nil }
    let text = query.dropFirst(3).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  /// fy 那一行（副标题是单个英文词的词典释义，查到了再换上）
  static func translateItem(_ text: String, definition: String = "") -> LauncherItem {
    LauncherItem(
      kind: .translate, target: text, title: String(localized: "翻译「\(text)」"), subtitle: definition)
  }

  /// 单输 fy：↩ / Tab 补全关键词的提示（同 open / find）；打「翻译」「fanyi」时排在本地结果（输入翻译）后面
  static func translatePrompts(for query: String) -> (
    exact: [LauncherItem], partial: [LauncherItem]
  ) {
    let item = LauncherItem(
      kind: .prompt, target: "translate-fy", title: String(localized: "翻译…"),
      subtitle: LauncherCommands.promptSubtitle("translate-fy", keyword: "fy") ?? "",
      completion: "fy ")
    // 英文界面打「translate」也算打了一半（D7：中英都认）
    switch LauncherMatch.promptMatch(
      query, keywords: ["fy"], aliases: ["翻译", "fanyi", "translate"])
    {
    case .exact: return ([item], [])
    case .partial: return ([], [item])
    case nil: return ([], [])
    }
  }

  /// 单输「提醒」「tx」「remind」：↩ / Tab 补全关键词的提示（同 fy）
  static func reminderPrompts(for query: String) -> [LauncherItem] {
    guard ReminderPhrase.isKeyword(query) else { return [] }
    // 用法里写打的那个词（「提醒」「tx」「remind」都认）
    let typed = query.trimmingCharacters(in: .whitespaces)
    return [
      LauncherItem(
        kind: .prompt, target: "reminder-new", title: String(localized: "新建提醒…"),
        subtitle: LauncherCommands.promptSubtitle("reminder-new", keyword: typed) ?? "",
        completion: typed + " ")
    ]
  }

  /// 「提醒 …」那几行（纯函数）：认出了时间的先是「建一条」，再是已有的提醒——没写别的时全列，写了的只列标题里带着这些字的；
  /// 认不出、已经过了、写的是重复的给一行提示，排在已有的后面（「提醒 眼睛」是在找那一条，↩ 落在它上面）
  static func reminderItems(
    _ rest: String, list: [Reminder], now: Date, calendar: Calendar = .current
  ) -> [LauncherItem] {
    var create: [LauncherItem] = []
    var hint: [LauncherItem] = []
    if !rest.isEmpty {
      let parsed = ReminderPhrase.parse(rest, now: now, calendar: calendar)
      if let parsed, parsed.date > now {
        let when = Reminder.Schedule(kind: .once, date: parsed.date).summary(
          now: now, calendar: calendar)
        create.append(
          LauncherItem(
            kind: .reminder, target: "", title: String(localized: "提醒我：\(parsed.title)"),
            subtitle: when,
            payload: rest))
      } else {
        let repeating = ReminderPhrase.isRepeating(ReminderPhrase.halfWidth(rest))
        hint.append(
          LauncherItem(
            kind: .prompt, target: Self.reminderHint,
            title: repeating
              ? String(localized: "重复的提醒到设置里建")
              : parsed == nil ? String(localized: "认不出时间") : String(localized: "这个时间已经过了"),
            subtitle: repeating
              ? String(localized: "这里只建一次的；每天、每周、每隔一阵的到 设置 › 提醒 里加")
              : String(localized: "试试「10分钟 喝水」「明天9点 交周报」「下午3点半 开会」")))
      }
    }
    let folded = LauncherMatch.fold(rest)
    // 显示的、存的、没改过的示例的英文写法都认（打「喝水」「drink」都找得到这条示例）
    let existing = list.filter { reminder in
      rest.isEmpty
        || [reminder.displayTitle, reminder.title, reminder.exampleTitle?.english].contains {
          $0.map { LauncherMatch.fold($0).contains(folded) } ?? false
        }
    }
    .map { reminder in
      let summary = reminder.summary(now: now, calendar: calendar)
      var item = LauncherItem(
        kind: .reminder, target: reminder.id, title: reminder.displayTitle,
        subtitle: reminder.isOn ? summary : String(localized: "\(summary) · 已暂停"))
      item.presetEmoji = reminder.symbol.isEmpty ? nil : reminder.symbol
      return item
    }
    return create + existing + hint
  }

  /// 「提醒 …」认不出时那一行提示的目标（↩ 什么都不做，只响提示音）
  static let reminderHint = "reminder-hint"

  /// 「添加…插件」那一行的目标前缀（后面是 Feature.rawValue）
  static let pluginPrefix = "plugin-"

  /// 「awake …」那几行的目标前缀：awake-stop、awake-for:<分钟>（空的是无限期）、awake-until（payload 是打的那截，↩ 时再算一遍）、
  /// awake-hint（认不出，↩ 只响提示音）
  static let awakePrefix = "awake-"

  /// 「awake …」那几行（纯函数）：手动开着时先是「停止保持唤醒」；后面什么都没写列几档时长，写了认得出的就那一行，认不出给提示
  static func keepAwakeItems(
    _ rest: String, status: String?, now: Date, calendar: Calendar = .current
  ) -> [LauncherItem] {
    var items: [LauncherItem] = []
    if let status {
      items.append(
        LauncherItem(
          kind: .prompt, target: awakePrefix + "stop", title: String(localized: "停止保持唤醒"),
          subtitle: String(localized: "保持唤醒中 · \(status)")))
    }
    func start(_ title: String, minutes: Int?) -> LauncherItem {
      let end = minutes.map { now.addingTimeInterval(Double($0 * 60)) }
      return LauncherItem(
        kind: .prompt, target: awakePrefix + "for:" + (minutes.map(String.init) ?? ""),
        title: String(localized: "保持唤醒 \(title)"),
        subtitle: end.map { KeepAwakePlan.until($0, now: now, calendar: calendar) }
          ?? String(localized: "直到你停止"))
    }
    switch KeepAwakePlan.parse(rest, now: now, calendar: calendar) {
    case .empty:
      items += KeepAwakePlan.presets.map { start($0.title, minutes: $0.minutes) }
    case .indefinitely:
      items.append(start(KeepAwakePlan.title(minutes: nil), minutes: nil))
    case .until(let end, let label):
      items.append(
        LauncherItem(
          kind: .prompt, target: awakePrefix + "until", title: String(localized: "保持唤醒 \(label)"),
          subtitle: KeepAwakePlan.until(end, now: now, calendar: calendar), payload: rest))
    case .invalid:
      items.append(
        LauncherItem(
          kind: .prompt, target: awakePrefix + "hint", title: String(localized: "认不出要多久"),
          subtitle: String(localized: "试试「2小时」「30分钟」「到18点」「无限期」")))
    }
    return items
  }

  /// ↩ 那几行：「到…」的按这一刻再算一遍（行列出来之后过了一会儿，「2小时」要从现在算，「到18点」可能已经过了）
  func runKeepAwake(_ item: LauncherItem) {
    let command = String(item.target.dropFirst(Self.awakePrefix.count))
    switch command {
    case "stop":
      close()
      keepAwakeEnd()
    case "until":
      guard
        case .until(let end, let label) = KeepAwakePlan.parse(
          item.payload ?? "", now: .now, calendar: .current)
      else { return NSSound.beep() }
      close()
      keepAwakeBegin(end, label)
    case _ where command.hasPrefix("for:"):
      let minutes = Int(command.dropFirst("for:".count))
      close()
      keepAwakeBegin(
        minutes.map { Date.now.addingTimeInterval(Double($0 * 60)) },
        KeepAwakePlan.title(minutes: minutes))
    default:
      NSSound.beep()
    }
  }

  /// 没添加的插件里，打的字对得上名字或关键词的（纯函数）：整个词打全了（后面还可以接别的，「awake 2小时」），
  /// 或者打了一个词的开头——英文至少 4 个字母、中文至少 2 个字（「ca」不该冒出「添加保持唤醒插件」）
  static func pluginOffers(for typed: String, added: Set<Feature>) -> [LauncherItem] {
    let text = LauncherMatch.fold(typed.trimmingCharacters(in: .whitespaces))
    let head = String(text.prefix { !$0.isWhitespace })
    let least = head.allSatisfy(\.isASCII) ? 4 : 2
    guard head.count >= 2 else { return [] }
    return Feature.allCases.filter { $0.isPlugin && $0.isAvailable && !added.contains($0) }
      .compactMap { plugin in
        let words = ([plugin.page.title] + plugin.pluginWords).map(LauncherMatch.fold)
        // 中文常不打空格（「保持唤醒2小时」）：打的字以这个词开头也算。英文的词后面不能紧跟着字母、数字
        // （评审 6：dock、note 这些短词，打 docker、notebook 不该冒出「添加…插件」）
        guard
          words.contains(where: { word in
            (head.hasPrefix(word)
              && (!word.allSatisfy(\.isASCII)
                || head.dropFirst(word.count).first.map {
                  !($0.isASCII && ($0.isLetter || $0.isNumber))
                }
                  ?? true))
              || (word.hasPrefix(head) && head.count >= least)
          })
        else { return nil }
        return LauncherItem(
          kind: .prompt, target: pluginPrefix + plugin.rawValue,
          title: String(localized: "添加「\(plugin.page.title)」插件"),
          subtitle: plugin.blurb)
      }
  }
  /// 下拉参数的一个选项那一行（第三轮 C1）：目标是「前缀 脚本路径⏎第几个参数⏎第几个选项」
  static let choicePrefix = "script-choice\n"

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

  /// 「ip」那几行：本机地址，再是外网地址。外网这次呼出里没查过、上次没查到的，等 0.3 s 再问（还在打字就撤掉）；
  /// 查到一家换一次行，行数可能多一行（两家看到的不一样），选中留在原来那一项上
  private func ipItems() -> [LauncherItem] {
    let local = ipLocal ?? localAddresses()
    ipLocal = local
    for service in IPAddresses.Service.allCases where ipTasks[service] == nil {
      if case .found = ipLookups[service] { continue }
      ipLookups[service] = .pending
      ipTasks[service] = Task {
        try? await Task.sleep(for: IPAddresses.lookupDelay)
        guard !Task.isCancelled else { return }
        let address = await publicAddress(service)
        guard !Task.isCancelled else { return }
        ipTasks[service] = nil
        ipLookups[service] = address.map { .found($0) } ?? .failed
        guard let start = results.firstIndex(where: { $0.kind == .ip }) else { return }
        let kept = selectedItem?.id
        results.removeAll { $0.kind == .ip }
        results.insert(contentsOf: local + IPAddresses.publicItems(ipLookups), at: start)
        selection = kept.flatMap { id in results.firstIndex { $0.id == id } } ?? selection
      }
    }
    return local + IPAddresses.publicItems(ipLookups)
  }

  /// 计算结果那一行。是汇率换算时顺带看要不要取汇率表：一份都没有、或者存着的过了 6 小时，停 0.3 s 再取（打字路过不发请求），
  /// 取到了原地换掉那一行（id 不变，选中不跳）；一份都没有时先是占位行（正在取 / 没取到），存着旧的就先用旧的
  /// currency：「命令」表里汇率换算开着（关着时只算算式、单位、进制，不换算货币、不取汇率表）
  private func calculationItem(_ query: String, currency: Bool = true) -> LauncherItem? {
    guard currency else { return Calculator.item(for: query, rates: nil) }
    if ExchangeRates.request(for: query) != nil,
      ratesTask == nil, rates.map({ ExchangeRates.isStale($0, now: .now) }) ?? true
    {
      ratesFailed = false
      ratesTask = Task {
        try? await Task.sleep(for: ExchangeRates.fetchDelay)
        guard !Task.isCancelled else { return }
        let table = await fetchRates()
        guard !Task.isCancelled else { return }
        ratesTask = nil
        if let table {
          rates = table
          if !isFixture { ExchangeRates.save(table) }
        } else {
          ratesFailed = true
        }
        let query = self.query.trimmingCharacters(in: .whitespaces)
        guard let index = results.firstIndex(where: { $0.kind == .calculation }) else { return }
        results[index] =
          calculationRow(query) ?? ExchangeRates.placeholder(for: query, failed: true)
      }
    }
    return calculationRow(query)
  }

  /// 算出来的那一行；汇率换算还没有表时是占位行（不取表，取表在 calculationItem）
  private func calculationRow(_ query: String) -> LauncherItem? {
    if let item = Calculator.item(for: query, rates: rates) { return item }
    guard rates == nil, ExchangeRates.request(for: query) != nil else { return nil }
    return ExchangeRates.placeholder(for: query, failed: ratesFailed)
  }

  /// 等汇率表取完（截图自检、单测用）
  func ratesFetch() async { await ratesTask?.value }

  /// 用了一次汇率换算（↩ 粘贴、⌘↩ / ⌘C / ⌘K 复制）：记下它的两种货币，下次候选里排前面（不是汇率换算的不动）
  func rememberCurrencies(_ item: LauncherItem) {
    guard item.kind == .calculation, item.payload != nil else { return }
    let updated = ExchangeRates.remembering(item.target, in: recentCurrencies)
    guard updated != recentCurrencies else { return }
    recentCurrencies = updated
    if !isFixture { ExchangeRates.saveRecents(updated) }
  }

  /// 撤掉还在等 / 在查的外网查询（查到的、没查到的留着）
  private func cancelIPLookups() {
    for (service, task) in ipTasks {
      task.cancel()
      ipLookups[service] = nil
    }
    ipTasks = [:]
  }

  /// 等外网地址查完（截图自检、单测用）
  func ipLookup() async {
    for task in ipTasks.values { await task.value }
  }

  /// 用过的网址 / 文件：不在任何目录里，靠使用记录找回来；和书签同一网址（不分大小写）时只留书签。
  /// 系统设置面板在 App 目录里，不另列；从书签 / 快捷链接打开的（listed）不在这里找回——还在的那份列表自己会列，
  /// 浏览器里删了就该搜不到（issue #10）
  private func usedLocations(excluding bookmarks: [LauncherItem]) -> [LauncherItem] {
    let bookmarked = Set(bookmarks.map { $0.target.lowercased() })
    return usage.entries.values
      .filter {
        $0.query.isEmpty && ($0.kind == .url || $0.kind == .path) && !$0.listed
          && !bookmarked.contains($0.target.lowercased()) && !AppCatalog.isSettingsPane($0.target)
          && !missingPaths.contains($0.target)
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
  /// 都只留还能还原的（App 还在、文件还在）。设置里关掉「列出常用」时只有收藏（issue #2；使用记录照记、照样给排序加成）
  private func home() -> [LauncherItem] {
    let actions = builtIns
    var items = favorites(actions)
    favoriteCount = items.count
    guard showsFrequent() else { return items }
    // 从书签 / 快捷链接打开的只从它们现在的列表里找（issue #10）：源头删了就不列，记录留着、加回来照旧
    lazy var listed = bookmarkItems() + WebSearch.quicklinkItems(engines: engines())
    // 全部按分排好再往下找：前面几条失效（App 已卸载、文件已删、书签删了）时后面的补上
    for entry in usage.top(Int.max) where items.count < Self.recentLimit {
      let restored =
        entry.listed
        ? listed.first { $0.kind == entry.kind && $0.target == entry.target }
        : restore(entry.kind, entry.target, entry.title, actions)
      guard let item = restored, !items.contains(where: { $0.id == item.id }) else { continue }
      items.append(item)
    }
    return items
  }

  /// 还原得出来的收藏。还原不出来的（App 没装 / 已卸载、文件已删）**只藏起来、不删**（全局同步：别的 Mac 收藏了这台没装的
  /// App，装上就回来——删了的话会同步删掉每一台的），也不占 8 个名额（⌘D 按看得见的数，LauncherUsage.toggleFavorite）。
  /// 有时有、有时没有的内置动作（钉图）不让收藏（canFavorite）。
  /// ⌥⌘↑↓ 只和看得见的邻居换（moveFavorite）。
  /// 归关着的功能（Feature）的内置动作：不显示，收藏也**不删**（打开功能就回来）——按全部功能都开着时的列表认
  func favorites(_ actions: [LauncherItem]) -> [LauncherItem] {
    usage.favorites.compactMap { restore($0.kind, $0.target, $0.title, actions) }
  }

  private func restore(
    _ kind: LauncherItem.Kind, _ target: String, _ title: String, _ actions: [LauncherItem]
  ) -> LauncherItem? {
    switch kind {
    case .app:
      if let app = apps.first(where: { $0.target == target }) { return app }
      // 应用程序目录以外的 App（在不在由 checkPresence 在主线程外查）
      return missingPaths.contains(target) ? nil : AppCatalog.item(path: target)
    case .action:
      return actions.first { $0.target == target }
        ?? (scriptsOn() ? LauncherItem.scriptActions.first { $0.target == target } : nil)
    case .system: return systemItems.first { $0.target == target }
    // 文件删了、脚本命令关了：藏起来，收藏不删（同 App）
    case .script: return scriptItems.first { $0.target == target }
    // 系统设置面板从目录里取（副标题「系统设置」、图标）；目录里没有的（系统更新后没了、自己建的这类链接）退回普通网址，
    // 不删收藏
    case .url:
      return apps.first { $0.target == target }
        ?? Self.item(kind: .url, target: target, title: title)
    case .path:
      return missingPaths.contains(target)
        ? nil : Self.item(kind: .path, target: target, title: title)
    // 不记使用，不会出现
    case .search, .calculation, .clip, .prompt, .translate, .process, .ip, .reminder,
      .scriptResult, .menuItem:
      return nil
    }
  }

  /// 列表变了（收藏、移除、调顺序）之后重算，选中留在那一项上；它不在了就留在原来的位置
  func refresh(keeping id: String?) {
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
}
