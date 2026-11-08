// 启动器的「命令」表（2026-11-07 拍板 C3 C4，PLAN §10「脚本命令」；纯函数，配单测）：内置的关键词命令（open / find /
// quit / hide / forcequit / eject / kill / port / ip / cb / fy / 提醒 / 汇率）、14 个系统命令、脚本命令，每条一个别名、一个开关。
// 汇率换算（真机反馈，用户要在表里看到它）：别名是出用法提示的那个词，关掉 = 计算器不再换算货币、不取汇率表。
// 别名就是要打的那个词：改了以后旧词不再认（名字和拼音照样搜得到），清空 = 只能按名字搜；关掉 = 不出现在搜索、常用、收藏里，
// 关键词也不认（收藏不删，打开就回来）。只存改过的（Prefs.launcherCommandAliases / launcherCommandsOff，跟着设置导出、同步）：
// 没改过的跟着新版的默认走。
// 内置命令的解析各有各的（SystemCommands.request、FileSearch.request…），不为别名改它们：搜索一开头把「别名 …」换回
// 「原关键词 …」交给原来那一套（canonical），原关键词已经改掉 / 关掉的那几条记在 blocked 里，各解析处按它挡掉。

import Foundation

nonisolated enum LauncherCommands {
  /// 表里「内置」那一组的一行：关键词命令
  struct BuiltIn: Hashable, Sendable {
    /// 偏好里的编号（builtin: + 关键词的英文名）
    let id: String
    let title: String
    /// 原来的关键词（折叠过的）
    let keyword: String
    let symbol: String
  }

  static let builtIns: [BuiltIn] = [
    BuiltIn(
      id: "builtin:open", title: "搜索文件并打开", keyword: "open", symbol: "doc.text.magnifyingglass"),
    BuiltIn(
      id: "builtin:find", title: "搜索文件并在访达中显示", keyword: "find", symbol: "doc.text.magnifyingglass"),
    BuiltIn(id: "builtin:quit", title: "退出 App", keyword: "quit", symbol: "xmark.circle"),
    BuiltIn(id: "builtin:hide", title: "隐藏 App", keyword: "hide", symbol: "eye.slash"),
    BuiltIn(
      id: "builtin:forcequit", title: "强制退出 App", keyword: "forcequit", symbol: "xmark.octagon"),
    BuiltIn(id: "builtin:eject", title: "推出磁盘", keyword: "eject", symbol: "eject"),
    BuiltIn(id: "builtin:kill", title: "结束进程", keyword: "kill", symbol: "stop.circle"),
    BuiltIn(id: "builtin:port", title: "查看端口占用", keyword: "port", symbol: "network"),
    BuiltIn(id: "builtin:ip", title: "IP 地址", keyword: "ip", symbol: "network"),
    BuiltIn(id: "builtin:cb", title: "在剪贴板历史里搜索", keyword: "cb", symbol: "doc.on.clipboard.fill"),
    BuiltIn(id: "builtin:fy", title: "翻译", keyword: "fy", symbol: "character.bubble.fill"),
    // 默认别名一律英文（不用切输入法；2026-11-08 用户「为什么这两个是中文，不应该统一英文吗」）。中文的「提醒」「汇率」和
    // tx、huilv 这些照旧认（ReminderPhrase.keywords、ExchangeRates.keywords）
    BuiltIn(id: "builtin:reminder", title: "新建提醒", keyword: "remind", symbol: "alarm.fill"),
    BuiltIn(id: "builtin:currency", title: "汇率换算", keyword: "currency", symbol: "banknote"),
  ]

  static func systemID(_ keyword: String) -> String { "system:" + keyword }

  /// 脚本的编号：按路径（家目录缩成 ~，几台 Mac 上同一个位置的脚本对得上）；自带的按文件名（App 装在哪都一样）
  static func scriptID(_ script: ScriptCommand) -> String {
    script.isBundled
      ? "bundled:" + script.fileName
      : "script:" + (script.path as NSString).abbreviatingWithTildeInPath
  }

  /// 用户改过的：别名（"" = 不要别名）和关掉的
  struct Settings: Equatable, Sendable {
    var aliases: [String: String] = [:]
    var off: Set<String> = []

    /// 这一条此刻的别名（折叠过、去掉空白，拿来比的）：改过的用改过的（空的是 nil），没改过的是原来的
    func alias(_ id: String, default fallback: String?) -> String? {
      guard let custom = aliases[id] else { return fallback }
      let alias = LauncherCommands.normalized(custom)
      return alias.isEmpty ? nil : alias
    }

    func isOn(_ id: String) -> Bool { !off.contains(id) }

    /// 改一条的别名：存打的原样（输入框里光标不跳、组字不断；比的时候再折叠），和原来的一样就不存（跟着新版的默认走）
    mutating func setAlias(_ text: String, for id: String, default fallback: String?) {
      let raw = String(text.prefix(LauncherCommands.aliasLimit))
      aliases[id] = LauncherCommands.normalized(raw) == (fallback ?? "") ? nil : raw
    }

    mutating func set(_ on: Bool, for id: String) {
      if on { off.remove(id) } else { off.insert(id) }
    }

    // 偏好里存成两段文字（注册了默认值 ""，跟着设置导出、同步）：别名是 JSON，关掉的一行一个
    init(aliases: [String: String] = [:], off: Set<String> = []) {
      self.aliases = aliases
      self.off = off
    }

    init(aliasesText: String, offText: String) {
      if let data = aliasesText.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String: String].self, from: data)
      {
        aliases = decoded.compactMapValues { $0.count <= LauncherCommands.aliasLimit ? $0 : nil }
      }
      off = Set(offText.split(whereSeparator: \.isNewline).map(String.init))
    }

    var aliasesText: String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard !aliases.isEmpty, let data = try? encoder.encode(aliases) else { return "" }
      return String(decoding: data, as: UTF8.self)
    }

    var offText: String { off.sorted().joined(separator: "\n") }
  }

  /// 别名最长这么多字
  static let aliasLimit = 32

  /// 别名的写法：去掉空白、折叠大小写，最多 aliasLimit 个字
  static func normalized(_ text: String) -> String {
    String(LauncherMatch.fold(text.filter { !$0.isWhitespace }).prefix(aliasLimit))
  }

  /// 输入开头是改过的别名：换成原来的关键词（交给原来那一套解析）；原来的关键词已经改掉、或者这条关掉了：记进 blocked，
  /// 这一句不当那条命令认
  static func canonical(_ query: String, settings: Settings) -> (
    query: String, blocked: Set<String>
  ) {
    guard !settings.aliases.isEmpty || !settings.off.isEmpty else { return (query, []) }
    let token = query.prefix { !$0.isWhitespace }
    let folded = LauncherMatch.fold(String(token))
    let rest = query.dropFirst(token.count)
    var blocked = Set<String>()
    var rewritten: String?
    // 打的正好是另一条开着、没改名的命令自己的关键词：它优先（同「撞了用排在前面的」），不改写成别名的那条
    let own = builtIns.filter {
      settings.isOn($0.id) && settings.alias($0.id, default: $0.keyword) == $0.keyword
    }
    .map(\.keyword)
    if own.contains(folded) { rewritten = query }
    for command in builtIns {
      guard settings.isOn(command.id) else {
        blocked.insert(command.id)
        continue
      }
      let alias = settings.alias(command.id, default: command.keyword)
      guard alias != command.keyword else { continue }
      if folded == command.keyword { blocked.insert(command.id) }
      if let alias, folded == alias, !folded.isEmpty, rewritten == nil {
        rewritten = command.keyword + rest
      }
    }
    return (rewritten ?? query, blocked)
  }

  /// 提示行（「输入「kill 空格 进程名」」）里的关键词换成别名；那条关掉了、或者别名清空了返回 nil（不出这一行）
  static func relabel(_ item: LauncherItem, settings: Settings) -> LauncherItem? {
    guard let command = builtIn(forPrompt: item.target) else { return item }
    guard settings.isOn(command.id) else { return nil }
    let alias = settings.alias(command.id, default: command.keyword)
    guard alias != command.keyword else { return item }
    guard let alias else { return nil }
    var item = item
    // 「kill 空格 进程名」和例子「remind 10分钟 喝水」里的关键词都换
    item.subtitle = item.subtitle.replacing("「\(command.keyword) ", with: "「\(alias) ")
    // 补全的是「关键词 空格」的才换（汇率补的是一句示例，不动）
    if item.completion?.hasPrefix(command.keyword + " ") == true { item.completion = alias + " " }
    return item
  }

  /// 提示行是哪条内置命令的
  static func builtIn(forPrompt target: String) -> BuiltIn? {
    let keyword =
      switch target {
      case _ where target.hasPrefix("system-"): String(target.dropFirst("system-".count))
      case _ where target.hasPrefix("file-"): String(target.dropFirst("file-".count))
      case "translate-fy": "fy"
      case _ where target.hasPrefix("reminder-"): "remind"
      case ExchangeRates.promptTarget: "currency"
      default: ""
      }
    return builtIns.first { $0.keyword == keyword }
  }

  /// 一个别名被几条用了（连网页搜索的关键词一起算）：重复的那几条的编号。entries 是（编号，此刻的别名）
  static func conflicts(_ entries: [(id: String, alias: String?)], engineKeywords: [String]) -> Set<
    String
  > {
    var owners: [String: [String]] = [:]
    for entry in entries {
      guard let alias = entry.alias, !alias.isEmpty else { continue }
      owners[alias, default: []].append(entry.id)
    }
    let engines = Set(engineKeywords.map(LauncherMatch.fold))
    return Set(owners.filter { $0.value.count > 1 || engines.contains($0.key) }.flatMap(\.value))
  }
}
