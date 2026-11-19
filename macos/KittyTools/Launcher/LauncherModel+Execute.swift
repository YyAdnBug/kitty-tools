// 启动器的执行（第五轮体检 H1 从 LauncherModel.swift 拆出）：↩ 执行一行、列表脚本的行、带对象的系统命令、上膛确认、粘贴 / 打开 / 补全，各行的主动作和替代动作的说法。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension LauncherModel {
  // MARK: 执行

  func execute(_ item: LauncherItem) {
    if pathPending { return NSSound.beep() }
    if let request = commandRequest, [.app, .path, .process].contains(item.kind) {
      return runTarget(item, rowVerb(item, in: request))
    }
    switch item.kind {
    case .calculation:
      // 汇率还没取到的占位行没有 payload（同 ip）
      guard let payload = item.payload else { return NSSound.beep() }
      rememberCurrencies(item)
      paste { Paster.write(string: payload, record: true) }
    case .ip:
      guard let address = item.payload else { return NSSound.beep() }
      paste { Paster.write(string: address, record: true) }
    case .clip:
      close()
      openClipboard(item.target)
    case .translate:
      close()
      translate(item.target)
    case .reminder where item.target.isEmpty:
      // 「建一条」：按 ↩ 的这一刻再解析一遍（行列出来之后过了一会儿，「10分钟」要从现在算）
      guard let text = item.payload, let parsed = ReminderPhrase.parse(text), parsed.date > .now
      else { return NSSound.beep() }
      close()
      createReminder(
        Reminder(
          id: UUID().uuidString, title: parsed.title,
          schedule: .init(kind: .once, date: parsed.date)))
    case .reminder:
      // 打开 / 暂停：启动器不收，摘要里的「已暂停」当场跟上，选中留在这一行
      toggleReminder(item.target)
      let kept = selection
      search()
      selection = min(kept, max(results.count - 1, 0))
    case .prompt where item.target == FileSearch.accessTarget:
      close()
      requestFolderAccess()
    case .prompt where item.target == Self.reminderHint:
      NSSound.beep()
    case .prompt where item.target.hasPrefix(Self.pluginPrefix):
      guard let plugin = Feature(rawValue: String(item.target.dropFirst(Self.pluginPrefix.count)))
      else { return NSSound.beep() }
      close()
      offerPlugin(plugin)
    case .prompt where item.target.hasPrefix(Self.awakePrefix):
      runKeepAwake(item)
    case .prompt where item.target == Self.pathVolumes:
      UserDefaults.standard.set(true, forKey: Prefs.launcherVolumesAllowed)
      pathListings = [:]
      search()
    case .prompt where item.target.hasPrefix(Self.pathOpenPrefix):
      close()
      NSWorkspace.shared.open(
        URL(filePath: String(item.target.dropFirst(Self.pathOpenPrefix.count))))
    case .prompt:
      if let completion = item.completion { query = completion }
    case .search:
      guard let url = URL(string: item.target) else {
        error = String(localized: "打不开搜索页")
        return
      }
      open(url, nil)
    case .action:
      // 退出本 App、进入状态屏不记使用：不进「常用」，也不会越用越排到别的前缀查询前面（↩ 不确认）
      if item.target != MenuExtra.quit.rawValue, !item.isStatusPreset {
        usage.record(item, query: query)
      }
      close()
      runAction(item.target)
    case .system:
      // 快捷指令（X10）：记使用、收起、在进程外跑
      if let name = SystemShortcuts.name(fromTarget: item.target) {
        usage.record(item, query: query)
        close()
        return SystemShortcuts.run(name, island: island)
      }
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
        error = String(localized: "打不开「\(item.title)」")
        return
      }
      open(url, item)
    case .process: break  // 只在 kill / port 模式里出现，上面已经处理
    case .menuItem:
      // 前台 App 的菜单项（N3）：收起启动器、切回那个 App 再按它（不记使用：菜单每次现读）
      guard let entry = item.menuItem else { return NSSound.beep() }
      close()
      pressMenu(entry)
    case .script:
      guard let script = activeScripts.first(where: { $0.path == item.target }) else {
        return NSSound.beep()
      }
      // 从网上下载、还没看过的：先给用户看一眼（B5）；列表脚本也是（看过之前不会打一个字跑一次）
      if script.isDownloaded, !approvedScripts.contains(script.path) {
        return showReview(script, arguments: item.arguments)
      }
      // 要参数的普通那一行：先补「关键词 空格」；参数没填够的只响提示音（副标题写着要填什么）
      guard let arguments = item.arguments ?? (script.takesInput ? nil : []) else {
        query = (scriptAlias(script) ?? script.title) + " "
        return
      }
      // 参数没填够、下拉参数填的不是选项（第三轮 C1）：只响提示音，副标题写着
      guard arguments.count >= script.requiredCount, script.invalidChoice(arguments) == nil else {
        return NSSound.beep()
      }
      if let text = script.confirmation, !confirm(item, commandKey: false, text: text) { return }
      record(script, item)
      start(script, arguments: arguments)
    case .scriptResult:
      // 这一次还在跑（显示的是上一次的、或者「正在运行…」）：等结果到了执行第一条
      if isPending(item) {
        runsWhenListed = true
        return
      }
      guard let payload = item.payload else { return NSSound.beep() }
      // 写了 url / path 的打开它（第三轮 B1；不记使用：结果每次由脚本重新列）
      switch item.opens {
      case .url(let url): open(url, nil)
      case .file(let path): open(URL(filePath: path), nil)
      case nil: paste { Paster.write(string: payload, record: true) }
      }
    }
  }

  /// 「关键词 空格 文字」那几行（B2），排在普通结果前面（不吞掉普通结果：「time machine」照样搜得到时间机器）：参数没填够时
  /// 副标题写「输入「tq 空格 城市」」；列表脚本是它的结果行——跑完之前留着这条脚本上一次的结果（不闪），第一次是一行
  /// 「正在运行…」（↩ 按在它上面等结果到了再执行，不落到下面的网页搜索上）
  func invocationRows(_ invocation: ScriptCommand.Invocation) -> [LauncherItem] {
    let script = invocation.script
    var row = LauncherItem.script(script, alias: scriptAlias(script))
    row.arguments = invocation.arguments
    // 已经在传参数了：Tab 不补全（第三轮评审：补成「tq 」把打好的「北京」清掉了）
    row.completion = nil
    // 正在打的是下拉参数、还没对上一个选项：选项排在前面，↩ / ⇥ 填进去（第三轮 C1）
    let choices = choiceRows(invocation)
    if !choices.isEmpty {
      row.subtitle = String(
        localized: "从下面选一个「\(script.arguments[invocation.typing].placeholder)」")
      return choices + [row]
    }
    if invocation.isMissing {
      let missing = script.arguments[invocation.arguments.count..<script.requiredCount]
      let placeholders = missing.map(\.placeholder).joined(separator: " ")
      row.subtitle = String(localized: "输入「\(invocation.keyword) 空格 \(placeholders)」")
      return [row]
    }
    if let bad = script.invalidChoice(invocation.arguments) {
      let argument = script.arguments[bad]
      let options = argument.options.map(\.title).joined(separator: " / ")
      row.subtitle = String(
        localized: "「\(invocation.arguments[bad])」不是「\(argument.placeholder)」能选的：\(options)")
      return [row]
    }
    let downloaded = script.isDownloaded && !approvedScripts.contains(script.path)
    guard script.mode == .list, !downloaded else {
      if downloaded {
        row.subtitle = String(localized: "从网上下载的脚本，↩ 先看一眼")
      } else if !invocation.arguments.isEmpty {
        // 密码参数不回显（第三轮 C3）
        row.subtitle = invocation.arguments.enumerated().map { index, value in
          index < script.arguments.count && script.arguments[index].isSecret ? "•••" : "「\(value)」"
        }.joined(separator: " ")
      }
      return [row]
    }
    // 自己过滤的：跑过了就按关键词后面的字过滤这一次的结果，不再跑（第三轮 B3）
    if script.filters, let cached = filterRows[script.path] {
      return cached.failed
        ? cached.rows : Self.filtered(cached.rows, by: invocation.arguments.first ?? "")
    }
    let kept = results.filter { $0.isResult(of: script) && $0.payload != nil }
    guard kept.isEmpty else { return kept }
    var pending = LauncherItem(
      kind: .scriptResult, target: script.path + "\n…",
      title: String(localized: "正在运行「\(script.title)」…"),
      subtitle: "")
    pending.scriptIcon = script.icon
    pending.scriptIconDark = script.iconDark
    return [pending]
  }

  /// 下拉参数的选项（第三轮 C1）：正在打的那个参数有选项、打的还没对上某一个时，按打的字过滤（认拼音）；↩ / ⇥ 把它填进
  /// 搜索框（带空白的括上引号，后面还有参数的接一个空格）。交给脚本的是选项的 value（ScriptCommand.passed）
  private func choiceRows(_ invocation: ScriptCommand.Invocation) -> [LauncherItem] {
    let script = invocation.script
    let index = invocation.typing
    guard index < script.arguments.count else { return [] }
    let argument = script.arguments[index]
    let typed = index < invocation.arguments.count ? invocation.arguments[index] : ""
    guard !argument.options.isEmpty, argument.option(for: typed) == nil || typed.isEmpty else {
      return []
    }
    // 只有一个参数的脚本整段就是它，不括引号（第 3 批评审：括了的话「"New York"」连引号交给脚本、也对不上选项）
    let quotes = script.arguments.count > 1
    func quote(_ text: String) -> String { quotes ? ScriptCommand.quoted(text) : text }
    let before = invocation.arguments.prefix(index).map(quote)
    let rows = argument.options.enumerated().map { number, option in
      var row = Self.searchable(
        LauncherItem(
          kind: .prompt, target: Self.choicePrefix + script.path + "\n\(index)\n\(number)",
          title: option.title, subtitle: ""))
      row.subtitle = argument.placeholder
      row.completion =
        ([invocation.keyword] + before + [quote(option.title)])
        .joined(separator: " ") + (index + 1 < script.arguments.count ? " " : "")
      row.scriptIcon = script.icon
      row.scriptIconDark = script.iconDark
      return row
    }
    return Self.filtered(rows, by: typed)
  }

  /// 列表脚本（C2）：停手 0.15 s 跑一遍，新的一跑就撤掉上一次；结果换掉这条脚本的那几行，下面的普通结果不动。
  /// 跑失败了、下面又有别的结果：不留那行错误（「time machine」不是在给时间戳传参数）
  func startList(_ invocation: ScriptCommand.Invocation) {
    let script = invocation.script
    // 下拉参数还没对上选项时不跑（第 3 批评审：打一个字跑一次，结果还挤在选项前面）
    guard script.mode == .list, !invocation.isMissing,
      script.invalidChoice(invocation.arguments) == nil,
      !script.isDownloaded || approvedScripts.contains(script.path)
    else { return }
    if script.filters { return startFilter(invocation) }
    let key = query
    listPath = script.path
    listTask = Task { [weak self] in
      try? await Task.sleep(for: Self.listDelay)
      guard let self, !Task.isCancelled else { return }
      var quick = script
      quick.timeout = min(script.limit == 0 ? Self.listTimeout : script.limit, Self.listTimeout)
      let outcome = await runScript(quick, invocation.arguments, nil)
      guard !Task.isCancelled, query == key else { return }
      listTask = nil
      let selected = userMovedSelection ? selectedItem?.id : nil
      let rest = results.filter { !$0.isResult(of: script) }
      // 传 quick：超时说的秒数是这次真用的（列表最多 10 秒）
      let rows = Self.resultRows(outcome, of: quick, keyword: invocation.keyword)
      // 只有网页搜索、提示这些兜底的行不算：那时留着错误那行，让人知道脚本为什么没给结果
      let failed = Self.failure(outcome, of: quick) != nil
      let found = rest.contains { ![.search, .prompt].contains($0.kind) }
      results = (failed && found ? [] : rows) + rest
      selection = selected.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
      emptyText = String(localized: "「\(script.title)」没有给出结果")
      // 结果到之前按了 ↩：执行这次的第一条
      if runsWhenListed {
        runsWhenListed = false
        if let first = results.first, first.isResult(of: script) { execute(first) }
      }
    }
  }

  /// 自己过滤的列表脚本（第三轮 B3）：这次呼出里第一次打到「关键词 空格」时跑一次（不带参数），之后打字不撤它、也不再跑；
  /// 结果到了重搜一次（按那时打的字过滤），结果到之前按了 ↩ 的执行第一条
  private func startFilter(_ invocation: ScriptCommand.Invocation) {
    let script = invocation.script
    guard filterRows[script.path] == nil, filterTask?.path != script.path else { return }
    filterTask?.task.cancel()
    let task = Task { [weak self] in
      guard let self else { return }
      var quick = script
      quick.timeout = min(script.limit == 0 ? Self.listTimeout : script.limit, Self.listTimeout)
      let outcome = await runScript(quick, [], nil)
      guard !Task.isCancelled else { return }
      filterTask = nil
      let rows = Self.resultRows(outcome, of: quick, keyword: invocation.keyword)
      let failed = Self.failure(outcome, of: quick) != nil
      filterRows[script.path] = (failed ? rows : rows.map(Self.searchable), failed)
      // 现在打的已经不是在用这条脚本了：结果先记着，不动眼前的列表（第 2 批评审：选中跳回第一行、上膛被撤、
      // 别的列表脚本被重跑）
      guard
        ScriptCommand.invocation(for: query, in: activeScripts, alias: scriptAlias)?.script.path
          == script.path
      else { return }
      let runs = runsWhenListed
      let selected = userMovedSelection ? selectedItem?.id : nil
      search()
      if let selected, let index = results.firstIndex(where: { $0.id == selected }) {
        selection = index
        userMovedSelection = true
      }
      emptyText = String(localized: "「\(script.title)」没有给出结果")
      if runs, let first = results.first, first.isResult(of: script) { execute(first) }
    }
    filterTask = (script.path, task)
  }

  /// 过滤用的名字：标题、说明，中文标题的全拼和首字母（同搜 App）
  static func searchable(_ row: LauncherItem) -> LauncherItem {
    var row = row
    let pinyin = AppCatalog.pinyin(row.title)
    row.names = [row.title, row.subtitle, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) }
    row.initials = [LauncherMatch.initials(row.title), pinyin?.initials].compactMap { $0 }
    return row
  }

  /// 按打的字过滤：对得上的按匹配分排，同分按脚本给的顺序；没打字就是全部。纯函数，配单测
  static func filtered(_ rows: [LauncherItem], by text: String) -> [LauncherItem] {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
    return rows.enumerated()
      .compactMap { index, row -> (LauncherItem, Double, Int)? in
        let score = LauncherMatch.score(text, item: row)
        return score > 0 ? (row, score, index) : nil
      }
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
      .map(\.0)
  }

  /// 等列表脚本这一次跑完（单测）
  func listRun() async {
    await listTask?.value
    await filterTask?.task.value
  }

  /// 列表脚本跑完 → 一条条结果；出错的是一行写原因（↩ 只响提示音）。keyword：打的关键词（结果的 autocomplete 接在它后面
  /// 填进搜索框）。纯函数，配单测
  static func resultRows(
    _ outcome: ScriptRunner.Outcome, of script: ScriptCommand, keyword: String = ""
  ) -> [LauncherItem] {
    func row(_ index: Int, _ title: String, _ subtitle: String, _ payload: String?) -> LauncherItem
    {
      var item = LauncherItem(
        kind: .scriptResult, target: script.path + "\n\(index)", title: title, subtitle: subtitle,
        payload: payload)
      item.scriptIcon = script.icon
      item.scriptIconDark = script.iconDark
      return item
    }
    if let failure = failure(outcome, of: script) {
      return [row(0, failure.title, failure.detail, nil)]
    }
    return ScriptCommand.lines(outcome.output, folder: script.folder).enumerated().map {
      index, line in
      var item = row(index, line.title, line.subtitle, line.isValid ? line.value : nil)
      // 不能选的不写「网址」「文件」、不当能打开的（↩ 只响提示音）
      item.opens = line.isValid ? line.opens : nil
      item.copyText = line.copyText
      // 这一条自己的图标；没写、是文件的用它在访达里的图标（同启动器里的文件行）
      if let icon = line.icon
        ?? line.opens.flatMap({
          if case .file(let path) = $0 { .file(path) } else { nil }
        })
      {
        item.scriptIcon = icon
        item.scriptIconDark = nil
      }
      if let text = line.autocomplete {
        item.completion = keyword.isEmpty ? text : keyword + " " + text
      }
      return item
    }
  }

  /// 没跑成的那一句（岛上、全文页、列表里同一套说法）；跑成了是 nil
  static func failure(_ outcome: ScriptRunner.Outcome, of script: ScriptCommand) -> (
    title: String, detail: String
  )? {
    let name = script.title
    switch outcome.end {
    case .stopped: return (String(localized: "已停止「\(name)」"), "")
    case .timedOut:
      // 秒数是脚本写的上限（不是数量：不加千分位）
      let seconds = String(script.limit)
      return (
        String(localized: "「\(name)」超时，已停止"),
        String(localized: "跑了 \(seconds) 秒还没完；脚本里写 @kitty.timeout 能改")
      )
    case .failedToStart(let reason): return (String(localized: "运行不了「\(name)」"), reason)
    case .tooMuchOutput:
      let megabytes = String(ScriptRunner.outputLimit * 4 / 1_048_576)
      return (
        String(localized: "「\(name)」输出太多，已停止"), String(localized: "输出超过 \(megabytes) MB")
      )
    case .finished(let status) where status != 0:
      let reason =
        ScriptCommand.lastLine(outcome.error) ?? ScriptCommand.lastLine(outcome.output)
        ?? String(localized: "退出码 \(String(status))")
      return (String(localized: "「\(name)」出错了"), reason)
    case .finished: return nil
    }
  }

  /// 执行了东西、面板跟着收起：这次的查询不留
  func close() {
    executed = true
    hidePanel()
  }

  /// 带对象模式里这一行按哪个命令办：port 列的是进程，后台进程同 kill（↩ 结束、⌘↩ 强制结束），程序坞里的 App 同 quit
  /// （↩ 正常退出——有没存的内容它会先问，⌘↩ 强制退出）；别的模式就是当前的命令
  func rowVerb(_ item: LauncherItem, in request: SystemCommands.Request)
    -> SystemCommands.Verb
  {
    guard request.verb == .port else { return request.verb }
    return item.process?.app == nil ? .kill : .quit
  }

  /// 带对象模式的行：↩ 退出 / 隐藏 / 强制退出 / 推出 / 结束进程（verb 是 rowVerb 给的）。不记使用（退出过的 App
  /// 不该因此在普通搜索里排前面）。强制退出（forcequit 的 ↩、quit / hide 的 ⌘↩）、强制结束（kill 的 ⌘↩）不可撤销：先上膛
  func runTarget(
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
    Island.announce("\(text)")
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
    let features = features
    if features.contains(.translate), let text = Self.translateQuery(query) { return text }
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !features.contains(.clipboard) || Self.clipQuery(query) == nil, commandRequest == nil
    else { return "" }
    return fileRequest.map { $0.terms.joined(separator: " ") } ?? query
  }

  /// 计算结果：收起后写剪贴板、发 ⌘V 粘贴回原 App（和剪贴板面板一样不激活本 App、不等待）。
  /// 没有辅助功能授权时只复制，刘海岛警告去授权（授权框一点启动器就收了，面板里的提示会丢）
  func paste(_ copy: () -> Void) {
    executed = true
    // 第 8 批：焦点原本在自家便签里 → 收起启动器、把 key 还给它、直接调它的 paste(_:)（不发合成按键、不要授权）
    if let target = pasteTargetView() {
      hidePanel()
      Paster.paste(into: target, write: copy)
      return
    }
    guard Permissions.isAccessibilityTrusted else {
      copy()
      // 系统授权框一点，启动器就收了，面板里的提示会跟着丢
      island?.show(
        "已复制到剪贴板", detail: "授权辅助功能后才能直接粘贴", tone: .warning,
        actions: [.settings(for: .accessibility)])
      return Permissions.requestAccessibility()
    }
    hidePanel()
    copy()
    _ = Paster.pasteToFrontmost()
  }

  /// ⌥↩：在访达里用 Spotlight 搜当前查询（不需要额外授权）
  func searchInFinder() {
    let text = searchText
    guard !text.isEmpty, !holdsSecret, NSWorkspace.shared.showSearchResults(forQueryString: text)
    else {
      return NSSound.beep()
    }
    close()
  }

  /// ⌃↩：不管有没有本地结果，用第一个兜底搜索搜当前查询
  func searchWeb() {
    let text = searchText
    guard !text.isEmpty, !holdsSecret, let engine = WebSearch.primary(in: engines()),
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
    // 不 stat（路径可能在卡住的盘上）：补出路径本身，是文件夹的话路径模式会直接列它里面
    case .path: return (item.target as NSString).abbreviatingWithTildeInPath
    case .script: return item.arguments == nil ? item.title : nil
    case .search, .calculation, .clip, .prompt, .translate, .process, .ip, .reminder,
      .scriptResult, .menuItem:
      return nil
    }
  }

  /// 按住修饰键时选中行的副标题：说明松手前按 ↩ 会做什么；上了膛的换成确认提示
  func alternateSubtitle(for item: LauncherItem) -> String? {
    if let armed, armed.id == item.id { return armed.text }
    return switch alternate {
    case .none: nil
    case .command: commandReturnAction(for: item).map { "⌘↩ " + String(localized: $0.title) }
    case .option: finderSearchTitle.map { "⌥↩ " + $0 }
    case .control: webSearchTitle.map { "⌃↩ " + $0 }
    }
  }

  /// 主动作、⌘↩ 的一项（名字、符号）。别在 switch / 三目里直接写元组字面量：编得过，但元组里的字只有第一个分支被抽进
  /// 目录（第 6 批实测），英文界面会露中文；经这个函数传进去的每一个都抽得到
  private static func act(_ title: LocalizedStringResource, _ symbol: String) -> (
    title: LocalizedStringResource, symbol: String
  ) { (title, symbol) }

  /// ↩ 做什么：底栏右侧的主动作和 ⌘K 菜单的第一行（名字随种类）
  func primaryAction(for item: LauncherItem) -> (title: LocalizedStringResource, symbol: String) {
    let confirming = armed?.id == item.id && armed?.commandKey == false
    if let request = commandRequest, [.app, .path, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      return Self.act(confirming ? "确认\(verb.title)" : verb.titleResource, verb.symbol)
    }
    return switch item.kind {
    case .app, .path:
      revealsOnReturn(item)
        ? Self.act("在访达中显示", "folder")
        : Self.act("打开", "arrow.up.forward.app")
    case .action:
      item.isStatusPreset
        ? Self.act("进入状态屏", HotKeyAction.statusScreen.symbol)
        : Self.act("运行", "command")
    case .system:
      confirming
        ? Self.act("确认\(item.title)", "exclamationmark.triangle")
        : Self.act("运行", SystemCommand(rawValue: item.target)?.symbol ?? item.symbol)
    case .url where AppCatalog.isSettingsPane(item.target):
      Self.act("打开", "gearshape")
    case .url: Self.act("打开网址", "safari")
    case .search: Self.act("搜索", "magnifyingglass")
    case .prompt where item.target == Self.reminderHint:
      Self.act("改一下再建", "pencil")
    case .prompt where item.target.hasPrefix(Self.pluginPrefix):
      Self.act("去设置里添加", "puzzlepiece.extension")
    case .prompt where item.target == Self.awakePrefix + "stop": Self.act("停止", "stop.circle")
    case .prompt where item.target == Self.awakePrefix + "hint": Self.act("改一下", "pencil")
    case .prompt where item.target.hasPrefix(Self.awakePrefix): Self.act("开始", "cup.and.saucer")
    case .prompt where item.target.hasPrefix(Self.choicePrefix):
      Self.act("选这个", "text.cursor")
    case .prompt where item.target == Self.pathVolumes: Self.act("允许读取", "externaldrive")
    case .prompt where item.target.hasPrefix(Self.pathOpenPrefix):
      Self.act("在访达中打开", "folder")
    case .prompt:
      item.target == FileSearch.accessTarget
        ? Self.act(
          LocalizedStringResource(
            "launcher.grantAccess", defaultValue: "授权", comment: "动作：允许访问文件夹"), "lock.open")
        : item.target == ExchangeRates.promptTarget
          ? Self.act("填进示例", "text.cursor")
          : item.target.hasPrefix(ExchangeRates.suggestionPrefix)
            ? Self.act("补全货币", "text.cursor")
            : Self.act("补全关键词", "text.cursor")
    case .calculation, .ip: Self.act("粘贴", "arrow.turn.down.left")
    case .clip:
      (
        item.target.isEmpty ? LocalizedStringResource("打开") : LocalizedStringResource("搜索"),
        "doc.on.clipboard"
      )
    case .translate: Self.act("翻译", "character.bubble")
    case .process: Self.act(SystemCommands.Verb.kill.titleResource, "stop.circle")
    case .reminder where item.target.isEmpty: Self.act("建好提醒", "alarm")
    case .reminder:
      reminders().first { $0.id == item.target }?.isOn == true
        ? Self.act("暂停", "pause.circle")
        : Self.act("打开", "play.circle")
    case .script where item.arguments == nil && item.completion != nil:
      Self.act("补全关键词", "text.cursor")
    // 参数没填够：↩ 只响提示音，副标题写着要填什么
    case .script where isMissingArguments(item): Self.act("先填参数", "text.cursor")
    case .script:
      Self.act(confirming ? "确认运行" : "运行", "play")
    case .scriptResult:
      switch item.opens {
      case .url: Self.act("打开", "safari")
      case .file: Self.act("打开", "arrow.up.forward.app")
      case nil: Self.act("粘贴", "arrow.turn.down.left")
      }
    case .menuItem:
      Self.act(
        LocalizedStringResource(
          "launcher.menuItem.press", defaultValue: "执行", comment: "动作：执行前台 App 的一个菜单项"),
        "filemenu.and.selection")
    }
  }

  /// ⌘↩ 做什么；没有就是 nil（网址没有第二个浏览器时也是 nil：副标题不写，按了只响提示音）
  /// 「关键词 空格」后参数没填够的那一行：↩ 只响提示音（底栏的 ↩ 不画成能按的主按钮）
  func isMissingArguments(_ item: LauncherItem) -> Bool {
    guard item.kind == .script, let arguments = item.arguments,
      let script = activeScripts.first(where: { $0.path == item.target })
    else { return false }
    return arguments.count < script.requiredCount || script.invalidChoice(arguments) != nil
  }

  func commandReturnAction(for item: LauncherItem) -> (
    title: LocalizedStringResource, symbol: String
  )? {
    let confirming = armed?.id == item.id && armed?.commandKey == true
    if let request = commandRequest, [.app, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      if verb == .kill {
        return Self.act(confirming ? "确认强制结束" : "强制结束", "xmark.octagon")
      }
      // 访达只能隐藏（hide 里列着它），不给强制退出
      guard verb != .forcequit, item.target != SystemCommands.finderPath else { return nil }
      return Self.act(confirming ? "确认强制退出" : "强制退出", "xmark.octagon")
    }
    if isWebLink(item) {
      return otherBrowsers.first.map {
        Self.act("用「\(Self.appName($0))」打开", "safari")
      }
    }
    return switch item.kind {
    case .app, .path:
      revealsOnReturn(item)
        ? Self.act("打开", "arrow.up.forward.app")
        : Self.act("在访达中显示", "folder")
    case .scriptResult where item.payload != nil:
      switch item.opens {
      case .url: Self.act("复制网址", "doc.on.doc")
      case .file: Self.act("在访达中显示", "folder")
      case nil: Self.act("只复制，不粘贴", "doc.on.doc")
      }
    case .calculation where item.payload != nil, .ip where item.payload != nil:
      Self.act("只复制，不粘贴", "doc.on.doc")
    case .reminder where !item.target.isEmpty: Self.act("在设置里编辑", "gearshape")
    case .script: Self.act("在访达中显示", "folder")
    default: nil
    }
  }

  /// ⌘C 复制什么；内置动作、提示、cb / fy 那一行、进程、系统设置面板没有，⌘C 交给输入框
  func copyTitle(for item: LauncherItem) -> LocalizedStringResource? {
    switch item.kind {
    case .app, .path, .script: "复制路径"
    case .url where AppCatalog.isSettingsPane(item.target): nil
    case .url, .search: "复制网址"
    case .calculation: item.payload == nil ? nil : "复制结果"
    case .ip: item.payload == nil ? nil : "复制地址"
    case .scriptResult where item.payload == nil: nil
    case .scriptResult where item.copyText == nil && item.opens != nil:
      if case .url = item.opens { "复制网址" } else { "复制路径" }
    case .scriptResult: "复制结果"
    case .action, .system, .prompt, .clip, .translate, .process, .reminder, .menuItem: nil
    }
  }

  /// ⌥↩ / ⌃↩ 做什么：没有查询（或没有兜底搜索）时 nil
  var finderSearchTitle: String? {
    let text = searchText
    return text.isEmpty || holdsSecret ? nil : String(localized: "在访达里搜索「\(text)」")
  }

  var webSearchTitle: String? {
    let text = searchText
    guard !text.isEmpty, !holdsSecret, let engine = WebSearch.primary(in: engines()) else {
      return nil
    }
    return String(localized: "用 \(engine.displayName) 搜索「\(text)」")
  }

  /// 打开 App / 文件 / 网址 / 搜索页（app：用指定的 App 打开）：先收起，再交给系统在后台打开（NSWorkspace 同步的 open
  /// 要等 App 启动完才返回，面板会一直挂着）；打开成功才记使用（item 为 nil 的搜索页不记），打不开时面板已经收起，用刘海岛说
  func open(_ url: URL, _ item: LauncherItem?, with app: URL? = nil) {
    let query = query  // 收起时查询会被清空
    close()
    let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [weak self] _, error in
      Task { @MainActor in
        guard let self else { return }
        if error == nil {
          if let item { self.usage.record(item, query: query) }
        } else {
          self.island?.show(
            "打不开「\(item?.title ?? url.absoluteString)」",
            detail: error.map { "\($0.localizedDescription)" },
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
}
