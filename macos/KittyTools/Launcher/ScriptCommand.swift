// 启动器的脚本命令（2026-11-07 拍板 A3 B1–B4，PLAN §10「脚本命令」；纯函数，配单测）：一个文件就是一条命令。
// 开头几行注释写元数据：@kitty.title（不写就用文件名）、keyword、icon、mode、description、package、argument1–3、confirm、
// timeout；也认 @raycast. 开头的同名字段（对标 Raycast Script Commands：packageName、needsConfirmation、argument1–3 的 JSON；
// mode 照意思对上——fullOutput 是全文，compact / silent / inline 都当岛上一行，inline 不定时刷新）。注释可以是 #、// 或 --
// （AppleScript）。第一行 #! 决定用什么跑：Kitty 自己调解释器，所以不要可执行权限。文件名带 .template. 的不列（社区惯例：
// 要先填值的脚本）；开头不是 #! 的普通文件（图标、说明）不理，但扩展名像脚本的记一条原因，给设置页列。
// 输出的收拾（去终端颜色码、取最后一行）、给脚本的环境变量、PATH 怎么拼也在这里。

import Foundation

nonisolated struct ScriptCommand: Hashable, Sendable {
  /// 输出交给谁（B1）
  enum Mode: String, Sendable, CaseIterable {
    /// 岛上显示最后一行（默认）
    case island
    /// 粘贴到前台 App
    case paste
    /// 复制，岛上说一声
    case copy
    /// 启动器里原地显示全部输出
    case full
    /// 每行一条结果（C2）
    case list
    /// 什么都不显示
    case none
  }

  /// 头部写的图标：emoji、SF 符号名、同文件夹里的 / 绝对路径的图片、https 网址（第二轮 B1：下载一次存本机，ScriptIcons）；
  /// 列表结果另有某个文件在访达里的图标（第三轮 B1 B2：结果写了 path、或 icon 写 {"type": "fileicon"}）
  enum Icon: Hashable, Sendable {
    case emoji(String)
    case symbol(String)
    case image(String)
    case remote(String)
    case file(String)
  }

  struct Argument: Hashable, Sendable {
    var placeholder: String
    var isOptional = false
    /// 交给脚本之前先做网址编码（社区写法 percentEncoded：直接拼进网址查询的那种，有空格、& 也不坏）
    var isPercentEncoded = false
    /// 下拉参数的选项（社区写法 type: dropdown 的 data，第三轮 C1）：打到这个参数时列出来挑；交给脚本的是 value
    var options: [Option] = []
    /// 密码参数（type: password，第三轮 C3）：行上不回显、跑完清空搜索框、不记使用
    var isSecret = false

    struct Option: Hashable, Sendable {
      var title: String
      var value: String
    }

    /// 打的这个值对应的选项：标题一字不差的先认，再是不分大小写的标题，最后是 value（第 3 批评审：一个的标题正好是另一个的
    /// value 时，不能按 value 认错）
    func option(for value: String) -> Option? {
      let folded = LauncherMatch.fold(value)
      return options.first { $0.title == value }
        ?? options.first { LauncherMatch.fold($0.title) == folded }
        ?? options.first { $0.value == value }
    }
  }

  /// 读不成一条命令的原因（设置页列出来）
  enum Problem: Error, Hashable, Sendable {
    case noShebang
    case unreadable
    /// 列表脚本打字时就会跑，确认不了（第三轮评审：写了 confirm 也照跑，说明里「按两次回车才运行」就不成立了）
    case confirmInList

    var text: String {
      switch self {
      case .noShebang: "第一行没有 #!，不知道用什么跑"
      case .unreadable: "读不出来"
      case .confirmInList: "列表脚本打字时就会运行，不能写 confirm"
      }
    }
  }

  /// 脚本文件的路径：使用记录、收藏、别名都按它认
  let path: String
  var title: String
  /// 头部写的关键词（「命令」表里的默认别名）：折叠过、不带空白
  var keyword: String?
  var icon: Icon?
  /// 深色主题用的图标（@kitty.iconDark / @raycast.iconDark，第二轮 B2）
  var iconDark: Icon?
  var mode = Mode.island
  var summary: String?
  var package: String?
  var arguments: [Argument] = []
  /// 要先上膛：副标题换成的那句；nil = 直接跑
  var confirmation: String?
  /// 秒；0 = 不限，nil = 默认（defaultTimeout）
  var timeout: Int?
  /// #! 那一行：解释器和它的参数（脚本路径接在后面）
  var interpreter: [String]
  /// 带着下载来的隔离标记（ScriptLibrary 读的时候看）：第一次跑之前先给用户看一眼（B5）
  var isDownloaded = false
  /// 随 App 带的自带脚本（D2，只读、跟着更新）
  var isBundled = false
  /// 列表脚本只跑一次、打的字由启动器过滤（第三轮 B3，@kitty.filter）：不收参数
  var filters = false

  static let defaultTimeout = 60
  /// 只读开头这么多字节找元数据（几家的头部都在前几十行）
  static let headerBytes = 8192
  /// 扩展名像脚本、开头却没有 #! 的，记一条原因（别的文件不理：图标、说明、配置）
  static let scriptExtensions: Set<String> = [
    "sh", "zsh", "bash", "py", "js", "mjs", "ts", "rb", "pl", "php", "swift", "applescript", "scpt",
    "lua", "fish",
  ]

  var folder: String { (path as NSString).deletingLastPathComponent }

  /// 下载来、还没看过的脚本（第二轮评审）：网址图标（能当信标，知道你什么时候列出了它）和脚本文件夹外面的图片（会弹文件夹
  /// 授权框）不用；emoji、符号、就放在脚本旁边的图照常。看过、去掉下载标记后重读就有了。第三轮评审：子文件夹里的、
  /// 本身是符号链接的图也不用（zip 里能带一个指到桌面的链接）；isLink 在扫描时（主线程外）问文件系统，单测换成假的
  mutating func dropUntrustedIcons(
    isLink: (String) -> Bool = {
      (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType)
        == .typeSymbolicLink
    }
  ) {
    let folder = (folder as NSString).standardizingPath
    func keep(_ icon: Icon?) -> Icon? {
      switch icon {
      case .remote: return nil
      case .image(let path):
        let beside = (path as NSString).deletingLastPathComponent == folder
        return beside && !isLink(path) ? icon : nil
      default: return icon
      }
    }
    icon = keep(icon)
    iconDark = keep(iconDark)
  }
  var fileName: String { (path as NSString).lastPathComponent }
  /// 真正用的超时（秒，0 = 不限）
  var limit: Int { timeout ?? Self.defaultTimeout }

  // MARK: 解析

  /// 读到的开头（最多 headerBytes）→ 一条命令；nil = 不是脚本、或者是 .template. 的（不列也不报）
  static func parse(_ head: String, path: String) -> Result<ScriptCommand, Problem>? {
    let name = (path as NSString).lastPathComponent
    guard !name.hasPrefix("."), !name.contains(".template.") else { return nil }
    let lines = head.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let first = lines.first, first.hasPrefix("#!") else {
      let ext = (name as NSString).pathExtension.lowercased()
      return scriptExtensions.contains(ext) ? .failure(.noShebang) : nil
    }
    let interpreter = first.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !interpreter.isEmpty else { return .failure(.noShebang) }
    var kitty: [String: String] = [:]
    var raycast: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let (prefix, key, value) = field(line) else { continue }
      if prefix == "kitty" {
        if kitty[key] == nil { kitty[key] = value }
      } else if raycast[key] == nil {
        raycast[key] = value
      }
    }
    let fields = merged(kitty: kitty, raycast: raycast)
    let fileTitle = (name as NSString).deletingPathExtension
    let title = fields["title"].flatMap { $0.isEmpty ? nil : $0 } ?? fileTitle
    var script = ScriptCommand(path: path, title: title, interpreter: interpreter)
    script.keyword = fields["keyword"].flatMap(keyword)
    let folder = (path as NSString).deletingLastPathComponent
    script.icon = fields["icon"].flatMap { icon($0, folder: folder) }
    script.iconDark = fields["iconDark"].flatMap { icon($0, folder: folder) }
    script.mode = fields["mode"].flatMap(mode) ?? .island
    script.summary = fields["description"].flatMap { $0.isEmpty ? nil : $0 }
    script.package = fields["package"].flatMap { $0.isEmpty ? nil : $0 }
    script.arguments = arguments(fields)
    script.confirmation = fields["confirm"].flatMap { confirmation($0, title: title) }
    script.timeout = fields["timeout"].flatMap { Int($0) }.map { min(max($0, 0), 3600) }
    if script.mode == .list, script.confirmation != nil { return .failure(.confirmInList) }
    // 只有列表脚本能写；写了就不收参数（打的字是拿来过滤的）
    if script.mode == .list, let value = fields["filter"], isYes(value) {
      script.filters = true
      script.arguments = []
    }
    return .success(script)
  }

  /// 一行注释里的「@kitty.key 值」/「@raycast.key 值」；注释符号可以是 #、// 或 --
  static func field(_ line: Substring) -> (prefix: String, key: String, value: String)? {
    var text = line.trimmingCharacters(in: .whitespaces)[...]
    guard let marker = ["#", "//", "--"].first(where: text.hasPrefix) else { return nil }
    text = text.dropFirst(marker.count).drop(while: \.isWhitespace)
    for prefix in ["kitty", "raycast"] where text.hasPrefix("@\(prefix).") {
      let rest = text.dropFirst(prefix.count + 2)
      let key = String(rest.prefix { !$0.isWhitespace })
      guard !key.isEmpty else { return nil }
      let value = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
      return (prefix, key, value)
    }
    return nil
  }

  /// 两种写法并成一份：自家的优先；社区写法的字段名换成自家的
  static func merged(kitty: [String: String], raycast: [String: String]) -> [String: String] {
    var fields: [String: String] = [:]
    for (key, value) in raycast {
      switch key {
      case "packageName": fields["package"] = value
      case "needsConfirmation": fields["confirm"] = value
      case "mode":
        fields["mode"] =
          switch value {
          case "fullOutput": Mode.full.rawValue
          // 最后一行弹提示 / 关掉窗口后 HUD / 显示在条目上定时刷新：都当岛上一行
          default: Mode.island.rawValue
          }
      case "title", "icon", "iconDark", "description", "argument1", "argument2", "argument3":
        fields[key] = value
      default: break
      }
    }
    fields.merge(kitty) { _, own in own }
    return fields
  }

  static func keyword(_ value: String) -> String? {
    let first = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    return first.isEmpty ? nil : LauncherMatch.fold(first)
  }

  static func mode(_ value: String) -> Mode? { Mode(rawValue: value.lowercased()) }

  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "pdf", "icns", "webp",
  ]

  static func icon(_ value: String, folder: String) -> Icon? {
    let text = value.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    // https 网址下载一次存本机（ScriptIcons）；http 不认
    let lower = text.lowercased()
    if lower.hasPrefix("https://") { return URL(string: text) == nil ? nil : .remote(text) }
    if lower.hasPrefix("http:") { return nil }
    let ext = (text as NSString).pathExtension.lowercased()
    if imageExtensions.contains(ext) || text.contains("/") {
      let expanded = (text as NSString).expandingTildeInPath
      let path =
        expanded.hasPrefix("/") ? expanded : (folder as NSString).appendingPathComponent(expanded)
      return .image((path as NSString).standardizingPath)
    }
    // 第一个字是 emoji（⏱ 这类默认不是彩色的也算；数字、# 这些 isEmoji 也是 true，按码位排除）
    if let first = text.first, let scalar = first.unicodeScalars.first,
      scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value >= 0x2100)
    {
      // 默认是文字样式的（⏱）补上 U+FE0F，画成彩色的
      let emoji = String(first)
      return .emoji(
        scalar.properties.isEmojiPresentation || emoji.unicodeScalars.count > 1
          ? emoji : emoji + "\u{FE0F}")
    }
    return .symbol(text)
  }

  /// argument1–3：按顺序，缺一个就停。值是 JSON（社区写法：placeholder、optional）或者直接是占位文字（必填）
  static func arguments(_ fields: [String: String]) -> [Argument] {
    var result: [Argument] = []
    for index in 1...3 {
      guard let value = fields["argument\(index)"], !value.isEmpty else { break }
      if value.hasPrefix("{"),
        let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
      {
        let placeholder = (object["placeholder"] as? String) ?? "参数\(index)"
        let type = object["type"] as? String
        // 下拉的选项：title 给人看（没写就用 value），value 交给脚本；一个都没有的当普通文字
        let options = (type == "dropdown" ? object["data"] as? [[String: Any]] : nil)?.compactMap {
          item -> Argument.Option? in
          guard let value = item["value"] as? String ?? (item["title"] as? String) else {
            return nil
          }
          let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
          return Argument.Option(title: title, value: value)
        }
        result.append(
          Argument(
            placeholder: placeholder, isOptional: object["optional"] as? Bool ?? false,
            isPercentEncoded: object["percentEncoded"] as? Bool ?? false,
            options: options ?? [], isSecret: type == "password"))
      } else {
        result.append(Argument(placeholder: value))
      }
    }
    return result
  }

  /// 开关类的字段（@kitty.filter）：空或 true / yes / 1 算开
  static func isYes(_ value: String) -> Bool {
    ["", "true", "yes", "1"].contains(value.lowercased())
  }

  /// confirm / needsConfirmation：空或 true = 默认那句，false = 不确认，别的就是自己写的那句
  static func confirmation(_ value: String, title: String) -> String? {
    switch value.lowercased() {
    case "false", "no", "0": nil
    case "", "true", "yes", "1": "再按 ↩ 运行「\(title)」"
    default: value
    }
  }

  // MARK: 参数（B2）

  /// 这条脚本要不要参数：声明了参数的、列表的（打字时重跑），打了关键词之后先补「关键词 空格」，不直接跑
  var takesInput: Bool { !arguments.isEmpty || mode == .list }

  /// 必填的参数有几个（排在可选的前面那几个）
  var requiredCount: Int { arguments.prefix { !$0.isOptional }.count }

  /// 有密码参数（第三轮 C3）
  var hasSecret: Bool { arguments.contains { $0.isSecret } }

  /// 第一个填了、却不是可选值之一的下拉参数（第三轮 C1）；nil = 都对得上
  func invalidChoice(_ values: [String]) -> Int? {
    values.indices.first { index in
      index < arguments.count && !arguments[index].options.isEmpty
        && arguments[index].option(for: values[index]) == nil
    }
  }

  /// 「别名 空格 文字」/「标题 空格 文字」：后面的字交给这条脚本
  struct Invocation: Equatable, Sendable {
    let script: ScriptCommand
    /// 打的是哪个词（别名或标题，原样）：补全、提示里用
    let keyword: String
    let arguments: [String]
    /// 正在打第几个参数（下拉参数这时列出选项，第三轮 C1）：最后一个字是空白的算下一个
    var typing = 0

    /// 必填的没填够
    var isMissing: Bool { arguments.count < script.requiredCount }
  }

  /// 输入是不是在给某条脚本传参数：要参数的脚本里，别名或标题（不分大小写）后面跟着空白的；几条都对得上时取词长的。
  /// alias：这条脚本此刻的别名（「命令」表里改过的，没有就是 nil）。纯函数，配单测
  static func invocation(
    for query: String, in scripts: [ScriptCommand], alias: (ScriptCommand) -> String?
  ) -> Invocation? {
    let folded = LauncherMatch.fold(query)
    var best: (script: ScriptCommand, length: Int)?
    for script in scripts where script.takesInput {
      for key in [alias(script), LauncherMatch.fold(script.title)].compactMap({ $0 })
      where !key.isEmpty && key.count > (best?.length ?? 0) && folded.hasPrefix(key) {
        let next = folded.dropFirst(key.count).first
        if next?.isWhitespace == true { best = (script, key.count) }
      }
    }
    guard let best else { return nil }
    let typed = prefix(of: query, foldedLength: best.length)
    let rest = String(query[typed.endIndex...].drop(while: \.isWhitespace))
    let count = best.script.arguments.count
    let (arguments, open) = tokens(rest, into: count)
    // 正在打第几个：最后一个字是空白、又不在没配上的引号里，算下一个；最后一个参数拿剩下的全部，打到它就一直是它
    let next = !rest.isEmpty && (rest.last?.isWhitespace != true || open)
    return Invocation(
      script: best.script, keyword: String(typed), arguments: arguments,
      typing: min(next ? arguments.count - 1 : arguments.count, max(count - 1, 0)))
  }

  /// 原样的输入里对上「折叠后 length 个字」的那一截：折叠会把 ß 变成 ss、ﬁ 变成 fi，不能拿折叠后的长度直接切原样的
  /// （第三轮评审：「Fußgängerstraße Berlin」切出来的参数是「erlin」）
  static func prefix(of query: String, foldedLength: Int) -> Substring {
    var end = query.startIndex
    while end < query.endIndex, LauncherMatch.fold(String(query[..<end])).count < foldedLength {
      end = query.index(after: end)
    }
    return query[..<end]
  }

  /// 网址编码时原样留下的字（RFC 3986 的 unreserved）
  static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// 真交给脚本的参数：下拉的换成选项的 value（第三轮 C1）；声明了 percentEncoded 的先做网址编码（第三轮对标：社区脚本里
  /// 有一百多个这么写，原来没认，带空格的参数拼出来的网址是坏的）
  func passed(_ values: [String]) -> [String] {
    values.enumerated().map { index, value in
      guard index < arguments.count else { return value }
      let argument = arguments[index]
      let value = argument.option(for: value)?.value ?? value
      guard argument.isPercentEncoded else { return value }
      return value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? value
    }
  }

  /// 引号：英文的 "…"、中文的 “…”
  static let quotes: [Character: Character] = ["\"": "\"", "“": "”"]

  /// 按空白切成最多 count 段，最后一段拿剩下的全部（同社区写法）；没声明参数的列表脚本整段当一个；空的不算。
  /// 不止一个参数时，引号括起来的算一段（第三轮 C2：「航班 "New York" London」），最后一段整个括着的去掉引号
  static func split(_ text: String, into count: Int) -> [String] { tokens(text, into: count).parts }

  /// 同 split；open：最后一段是没配上的引号开头的（还在打引号里的字：它拿走剩下的全部，算一段）
  static func tokens(_ text: String, into count: Int) -> (parts: [String], open: Bool) {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return ([], false) }
    guard count > 1 else { return ([trimmed], false) }
    var parts: [String] = []
    var rest = trimmed[...]
    while parts.count < count - 1, !rest.isEmpty {
      if let open = rest.first, let close = quotes[open] {
        guard let end = rest.dropFirst().firstIndex(of: close) else {
          // 没配上的引号：后面的都算这一段（第 3 批评审：打着「"New 」时还在这一个参数里）
          return (parts + [String(rest.dropFirst())], true)
        }
        parts.append(String(rest[rest.index(after: rest.startIndex)..<end]))
        rest = rest[rest.index(after: end)...]
      } else {
        let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        parts.append(String(rest[..<end]))
        rest = rest[end...]
      }
      rest = rest.drop(while: \.isWhitespace)
    }
    if !rest.isEmpty { parts.append(unquoted(String(rest))) }
    return (parts, false)
  }

  /// 整个括在一对引号里的去掉引号（里面没有别的同样的引号）
  static func unquoted(_ text: String) -> String {
    guard text.count >= 2, let first = text.first, let close = quotes[first], text.last == close,
      !text.dropFirst().dropLast().contains(close)
    else { return text }
    return String(text.dropFirst().dropLast())
  }

  /// 填进搜索框时：带空白的（或者开头是引号的）括上引号
  static func quoted(_ text: String) -> String {
    guard !text.isEmpty else { return "\"\"" }
    guard text.contains(where: \.isWhitespace) || text.first.map({ quotes[$0] != nil }) == true
    else { return text }
    return text.contains("\"") ? "“\(text)”" : "\"\(text)\""
  }

  // MARK: 列表（C2）

  /// 列表脚本的一条结果：title 显示、arg 是 ↩ 粘贴 / ⌘C 复制的（没写就是 title）；valid = false 的按了只响提示音。
  /// 第三轮 B1 B2：写了 url / path 的 ↩ 打开它；icon 是这一条自己的图标，autocomplete 是 ⇥ 填进搜索框的（接在关键词后面），
  /// text.copy 是 ⌘C 复制的
  struct Line: Equatable, Sendable {
    var title: String
    var subtitle = ""
    var arg: String?
    var isValid = true
    var opens: Opens?
    var icon: Icon?
    var autocomplete: String?
    var copyText: String?

    var value: String { arg ?? title }

    /// ↩ 打开的：网址用浏览器（任何协议都交给系统，同在访达里点链接），文件同启动器里的文件行
    enum Opens: Hashable, Sendable {
      case url(URL)
      case file(String)

      /// ⌘C 默认复制的（网址、路径）
      var text: String {
        switch self {
        case .url(let url): url.absoluteString
        case .file(let path): path
        }
      }
    }
  }

  /// 最多列这么多条
  static let lineLimit = 200

  /// 列表脚本的输出 → 一条条结果：开头是 { 的按 Script Filter 的 JSON 读（items 的 title、subtitle、arg、valid，
  /// 第三轮加 url、path、icon、autocomplete、text.copy，社区写法 type: file 的 arg 当路径；别的忽略），
  /// 否则一行一条「标题⇥副标题」（⇥ 和后面可以省）。folder：脚本所在的文件夹（图标、路径写相对的时按它算）。纯函数，配单测
  static func lines(_ output: String, folder: String = "/") -> [Line] {
    let text = clean(output).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("{"),
      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let items = object["items"] as? [[String: Any]]
    {
      return items.prefix(lineLimit).compactMap { item in
        guard let title = item["title"] as? String, !title.isEmpty else { return nil }
        let arg: String? =
          switch item["arg"] {
          case let text as String: text
          case let texts as [String]: texts.joined(separator: "\n")
          case let number as NSNumber: number.stringValue
          default: nil
          }
        var line = Line(
          title: title, subtitle: item["subtitle"] as? String ?? "", arg: arg,
          isValid: item["valid"] as? Bool ?? true)
        line.opens = opens(item, arg: arg, folder: folder)
        line.icon = rowIcon(item["icon"], folder: folder)
        line.autocomplete = (item["autocomplete"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        line.copyText = ((item["text"] as? [String: Any])?["copy"] as? String).flatMap {
          $0.isEmpty ? nil : $0
        }
        return line
      }
    }
    return text.split(whereSeparator: \.isNewline).prefix(lineLimit).compactMap { line in
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      let title = parts[0].trimmingCharacters(in: .whitespaces)
      guard !title.isEmpty else { return nil }
      let subtitle = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
      return Line(title: title, subtitle: subtitle)
    }
  }

  /// 一条结果打开什么：url（有协议的；file: 和写成 / 或 ~ 开头的当文件）> path > 社区写法 type 是 file 的 arg。
  /// 什么协议都交给系统（同 Alfred 的打开网址：raycast://、obsidian:// 这类也要能开），要 ↩ 才打开
  static func opens(_ item: [String: Any], arg: String?, folder: String) -> Line.Opens? {
    if let text = (item["url"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
      if text.hasPrefix("/") || text.hasPrefix("~") { return .file(absolute(text, folder: folder)) }
      if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty {
        return url.isFileURL ? .file(absolute(url.path, folder: folder)) : .url(url)
      }
    }
    let type = item["type"] as? String
    let path =
      (item["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (type?.hasPrefix("file") == true ? arg : nil)
    guard let path, !path.isEmpty else { return nil }
    return .file(absolute(path, folder: folder))
  }

  /// ~ 展开；相对路径按脚本所在的文件夹算
  static func absolute(_ path: String, folder: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return expanded.hasPrefix("/")
      ? (expanded as NSString).standardizingPath
      : ((folder as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
  }

  /// 一条结果自己的图标：字符串同 @kitty.icon（emoji、SF 符号、图片；网址不认——一列几十条各下载一次，还能当信标）；
  /// 对象是社区写法：{"type": "fileicon", "path": …} 取那个文件在访达里的图标，{"path": …} 是图片
  static func rowIcon(_ value: Any?, folder: String) -> Icon? {
    let found: Icon? =
      switch value {
      case let text as String: icon(text, folder: folder)
      case let object as [String: Any]:
        (object["path"] as? String).flatMap { path in
          object["type"] as? String == "fileicon"
            ? .file(absolute(path, folder: folder)) : icon(path, folder: folder)
        }
      default: nil
      }
    if case .remote = found { return nil }
    return found
  }

  // MARK: 输出

  /// 去掉终端颜色码（CSI、OSC）和回车：岛上、粘贴、复制、列表行都是纯文字（全文那一页另认颜色，ScriptTerminal）
  static func clean(_ output: String) -> String {
    // 绝大多数输出既没有颜色码也没有回车：不过正则（1 MB 过一遍要 0.1–0.4 s，在主线程上；第三轮评审）
    guard output.utf8.contains(where: { $0 == 0x1B || $0 == 0x0D }) else { return output }
    return
      carriageReturns(output)
      .replacing(/\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)?/, with: "")
      .replacing(/\u{1B}\[[0-9;:?]*[ -\/]*[@-~]/, with: "")
      .replacing(/\u{1B}[@-_]/, with: "")
  }

  /// 回车：\r\n 是换行。只有 \r 当换行、没有别的换行（末尾的不算）的是老式 Mac 的换行（AppleScript 的 return、
  /// 列表 JSON 也可能这么分行），当换行；否则同终端：单独的 \r 回到行首，后面再写出字来就盖掉这一行（进度条一帧帧地重画，
  /// 只留最后一帧；第三轮 A1），后面只跟着颜色码、或者在行尾的 \r 不算
  static func carriageReturns(_ text: String) -> String {
    guard text.utf8.contains(0x0D) else { return text }
    let unified = text.replacing("\r\n", with: "\n")
    var body = unified[...]
    while body.last == "\n" { body = body.dropLast() }
    guard body.contains("\n") else { return unified.replacing("\r", with: "\n") }
    return
      unified
      .replacing(/[^\n\r]*\r+(?=(?:\u{1B}\[[0-9;:?]*[ -\/]*[@-~])*[^\n\r\u{1B}])/, with: "")
      .replacing("\r", with: "")
  }

  /// 看全文时要标出来的字：显示出来看不见、或者让看到的和真会跑的不一样（第三轮评审 + 复查）。block 的有就不放行：
  /// 双向控制符能把一段命令显示成注释；零宽字、单独的回车、换行类字符放在 # 前面，# 就不在词首、不算注释，显示出来
  /// 却像一行注释。mark 的只标出来照放：不换行空格、全角空格这类，标出来就看得出 # 前面不是普通空格
  enum Hidden { case block, mark }

  /// previous：前一个字（emoji 后面的 ZWJ、变体选择符是 emoji 的一部分，不算）；next：后一个字（\r\n 是正常的换行）
  static func hidden(_ scalar: Unicode.Scalar, previous: Unicode.Scalar?, next: Unicode.Scalar?)
    -> Hidden?
  {
    switch scalar.value {
    case 0x09, 0x0A, 0x20: return nil
    case 0x0D: return next?.value == 0x0A ? nil : .block
    // ZWJ、变体选择符：跟在 emoji（或它的修饰、另一个 ZWJ / 变体选择符）后面的是 emoji 的一部分（⚠️、👨‍👩‍👧）
    case 0x200D, 0xFE00...0xFE0F:
      guard let previous else { return .block }
      let joins = previous.value == 0x200D || (0xFE00...0xFE0F).contains(previous.value)
      return previous.properties.isEmoji || joins ? nil : .block
    default: break
    }
    let properties = scalar.properties
    if properties.isDefaultIgnorableCodePoint { return .block }
    switch properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator: return .block
    case .spaceSeparator: return .mark
    default: return nil
    }
  }

  /// 给人看一眼的脚本：那些字换成看得见的「⟦U+200B⟧」，显示出来的就是存着的样子。hasHidden：有 block 的（看全文那一页、
  /// 导入表单都不放行）
  static func revealed(_ text: String) -> (text: String, hasHidden: Bool) {
    let scalars = Array(text.unicodeScalars)
    var shown = String.UnicodeScalarView()
    var blocked = false
    var changed = false
    for (index, scalar) in scalars.enumerated() {
      let kind = hidden(
        scalar, previous: index > 0 ? scalars[index - 1] : nil,
        next: index + 1 < scalars.count ? scalars[index + 1] : nil)
      guard let kind else {
        shown.append(scalar)
        continue
      }
      changed = true
      if kind == .block { blocked = true }
      shown.append(contentsOf: String(format: "⟦U+%04X⟧", scalar.value).unicodeScalars)
    }
    return (changed ? String(shown) : text, blocked)
  }

  /// 最后一行有字的（岛上一行、出错时的原因）
  static func lastLine(_ output: String) -> String? {
    clean(output).split(whereSeparator: \.isNewline)
      .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// 粘贴、复制的内容：去掉颜色码和末尾的换行（echo 多出来的那个），中间的照旧
  static func payload(_ output: String) -> String {
    var text = clean(output)
    while text.last?.isNewline == true { text.removeLast() }
    return text
  }

  // MARK: 环境

  /// 没读到登录 shell 的 PATH 时用的，也补在读到的后面（同 Alfred 5：Homebrew 两处 + 系统目录）
  static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  /// 读到的（终端里的）PATH 在前，固定目录里没出现的补在后面
  static func searchPath(login: String?) -> String {
    var parts = (login ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    for part in fallbackPath.split(separator: ":").map(String.init) where !parts.contains(part) {
      parts.append(part)
    }
    return parts.joined(separator: ":")
  }

  /// 读 PATH 时打在前面的记号：.zshrc 里 echo 的东西不会被当成 PATH
  static let pathMarker = "__KITTY_PATH__"

  static func shellPath(fromOutput output: String) -> String? {
    guard let range = output.range(of: pathMarker, options: .backwards) else { return nil }
    let path = output[range.upperBound...].prefix { !$0.isNewline }
      .trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return nil }
    // fish 的 "$PATH" 是空格分开的
    return path.contains(":") ? path : path.replacing(" ", with: ":")
  }

  /// 给脚本的环境（B3）：只从本进程的环境里挑这几样，不把 Kitty 自己的整个传下去（测试宿主里还有注入的库）；
  /// 再加 PATH 和几个 KITTY_ 开头的
  static let inheritedKeys = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"]

  static func environment(
    inherited: [String: String], path: String, script: ScriptCommand, dataDirectory: String,
    version: String, language: String
  ) -> [String: String] {
    var environment = inherited.filter { inheritedKeys.contains($0.key) }
    environment["PATH"] = path
    environment["LANG"] = language
    environment["KITTY_SCRIPT_DIR"] = script.folder
    environment["KITTY_DATA_DIR"] = dataDirectory
    environment["KITTY_VERSION"] = version
    return environment
  }

  /// LANG：跟系统的语言和地区（zh_CN.UTF-8）；系统里没有这个组合（en_CN、zh_US 这类，评审实测会退回 C、中文按字节算）
  /// 时用 en_US.UTF-8——要紧的是 UTF-8。exists 问 /usr/share/locale 里有没有（单测换成假的）
  static func language(
    _ locale: Locale,
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: "/usr/share/locale/" + $0) }
  ) -> String {
    guard let code = locale.language.languageCode?.identifier,
      let region = locale.region?.identifier
    else { return "en_US.UTF-8" }
    let name = "\(code)_\(region).UTF-8"
    return exists(name) ? name : "en_US.UTF-8"
  }
}
