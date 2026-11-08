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

  /// 头部写的图标：emoji、SF 符号名、同文件夹里的 / 绝对路径的图片、https 网址（第二轮 B1：下载一次存本机，ScriptIcons）
  enum Icon: Hashable, Sendable {
    case emoji(String)
    case symbol(String)
    case image(String)
    case remote(String)
  }

  struct Argument: Hashable, Sendable {
    var placeholder: String
    var isOptional = false
    /// 交给脚本之前先做网址编码（社区写法 percentEncoded：直接拼进网址查询的那种，有空格、& 也不坏）
    var isPercentEncoded = false
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
        result.append(
          Argument(
            placeholder: placeholder, isOptional: object["optional"] as? Bool ?? false,
            isPercentEncoded: object["percentEncoded"] as? Bool ?? false))
      } else {
        result.append(Argument(placeholder: value))
      }
    }
    return result
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

  /// 「别名 空格 文字」/「标题 空格 文字」：后面的字交给这条脚本
  struct Invocation: Equatable, Sendable {
    let script: ScriptCommand
    /// 打的是哪个词（别名或标题，原样）：补全、提示里用
    let keyword: String
    let arguments: [String]

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
    let rest = query[typed.endIndex...].drop(while: \.isWhitespace)
    return Invocation(
      script: best.script, keyword: String(typed),
      arguments: split(String(rest), into: best.script.arguments.count))
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

  /// 真交给脚本的参数：声明了 percentEncoded 的先做网址编码（第三轮对标：社区脚本里有一百多个这么写，原来没认，
  /// 带空格的参数拼出来的网址是坏的）
  func passed(_ values: [String]) -> [String] {
    values.enumerated().map { index, value in
      guard index < arguments.count, arguments[index].isPercentEncoded else { return value }
      return value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? value
    }
  }

  /// 按空白切成最多 count 段，最后一段拿剩下的全部（同社区写法）；没声明参数的列表脚本整段当一个；空的不算
  static func split(_ text: String, into count: Int) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }
    guard count > 1 else { return [trimmed] }
    return trimmed.split(maxSplits: count - 1, whereSeparator: \.isWhitespace).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  // MARK: 列表（C2）

  /// 列表脚本的一条结果：title 显示、arg 是 ↩ 粘贴 / ⌘C 复制的（没写就是 title）；valid = false 的按了只响提示音
  struct Line: Equatable, Sendable {
    var title: String
    var subtitle = ""
    var arg: String?
    var isValid = true

    var value: String { arg ?? title }
  }

  /// 最多列这么多条
  static let lineLimit = 200

  /// 列表脚本的输出 → 一条条结果：开头是 { 的按 Script Filter 的 JSON 读（items 的 title、subtitle、arg、valid，别的忽略），
  /// 否则一行一条「标题⇥副标题」（⇥ 和后面可以省）。纯函数，配单测
  static func lines(_ output: String) -> [Line] {
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
        return Line(
          title: title, subtitle: item["subtitle"] as? String ?? "", arg: arg,
          isValid: item["valid"] as? Bool ?? true)
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

  /// 回车同终端：\r\n 是换行；单独的 \r 回到行首，后面再写字就盖掉这一行（进度条一帧帧地重画，只留最后一帧；第三轮 A1），
  /// 行尾的 \r 不算
  static func carriageReturns(_ text: String) -> String {
    guard text.utf8.contains(0x0D) else { return text }
    return
      text
      .replacing("\r\n", with: "\n")
      .replacing(/[^\n\r]*\r+(?=[^\n\r])/, with: "")
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
