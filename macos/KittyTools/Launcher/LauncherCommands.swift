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
    /// 显示的名字（这次运行的语言）和中文原文（「命令」表里中英都能搜）
    let title: String
    let chinese: String
    /// 原来的关键词（折叠过的）
    let keyword: String
    let symbol: String
  }

  static let builtIns: [BuiltIn] = [
    builtIn("builtin:open", "搜索文件并打开", "open", "doc.text.magnifyingglass"),
    builtIn("builtin:find", "搜索文件并在访达中显示", "find", "doc.text.magnifyingglass"),
    builtIn("builtin:quit", "退出 App", "quit", "xmark.circle"),
    builtIn("builtin:hide", "隐藏 App", "hide", "eye.slash"),
    builtIn("builtin:forcequit", "强制退出 App", "forcequit", "xmark.octagon"),
    builtIn("builtin:eject", "推出磁盘", "eject", "eject"),
    builtIn("builtin:kill", "结束进程", "kill", "stop.circle"),
    builtIn("builtin:port", "查看端口占用", "port", "network"),
    builtIn("builtin:ip", "IP 地址", "ip", "network"),
    builtIn("builtin:cb", "在剪贴板历史里搜索", "cb", "doc.on.clipboard.fill"),
    builtIn("builtin:fy", "翻译", "fy", "character.bubble.fill"),
    // 默认别名一律英文（不用切输入法；2026-11-08 用户「为什么这两个是中文，不应该统一英文吗」）。中文的「提醒」「汇率」和
    // tx、huilv 这些照旧认（ReminderPhrase.keywords、ExchangeRates.keywords）
    builtIn("builtin:reminder", "新建提醒", "remind", "alarm.fill"),
    builtIn("builtin:currency", "汇率换算", "currency", "banknote"),
  ]

  private static func builtIn(
    _ id: String, _ title: LocalizedStringResource, _ keyword: String, _ symbol: String
  ) -> BuiltIn {
    BuiltIn(
      id: id, title: String(localized: title), chinese: title.chinese, keyword: keyword,
      symbol: symbol)
  }

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
    // 补全的是「关键词 空格」的才换（汇率补的是一句示例，不动）
    guard item.completion?.hasPrefix(command.keyword + " ") == true else { return item }
    item.completion = alias + " "
    // 副标题照同一句模板换上别名（「kill 空格 进程名」、例子「remind 10分钟 喝水」）：不在译好的句子里找字替换
    if let subtitle = promptSubtitle(item.target, keyword: alias) { item.subtitle = subtitle }
    return item
  }

  /// 关键词提示行的副标题（模板 + 关键词）：各提示行和 relabel 都从这里取，换语言、换别名都是同一句。不是这几种提示行给 nil
  static func promptSubtitle(_ target: String, keyword: String) -> String? {
    func hint(_ noun: String) -> String {
      String(localized: "输入「\(keyword) 空格 \(noun)」，↩ 或 Tab 补全关键词")
    }
    if target.hasPrefix("system-") {
      return SystemCommands.Verb(rawValue: String(target.dropFirst("system-".count))).map {
        hint($0.noun)
      }
    }
    if target.hasPrefix("file-") { return hint(String(localized: "文件名")) }
    if target == "translate-fy" { return hint(String(localized: "文字")) }
    if target.hasPrefix("reminder-") {
      return String(
        localized: "输入「\(keyword) 空格 时间 内容」，如「\(keyword) 10分钟 喝水」；↩ 或 Tab 补全关键词")
    }
    return nil
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

  /// 一个别名被几条用了（连网页搜索的关键词、应用别名一起算，T3）：重复的那几条的编号。entries 是（编号，此刻的别名）
  static func conflicts(
    _ entries: [(id: String, alias: String?)], engineKeywords: [String],
    appAliases: Set<String> = []
  ) -> Set<String> {
    var owners: [String: [String]] = [:]
    for entry in entries {
      guard let alias = entry.alias, !alias.isEmpty else { continue }
      owners[alias, default: []].append(entry.id)
    }
    let taken = Set(engineKeywords.map(LauncherMatch.fold)).union(appAliases)
    return Set(
      owners.filter { $0.value.count > 1 || taken.contains(LauncherMatch.fold($0.key)) }
        .flatMap(\.value))
  }
}
