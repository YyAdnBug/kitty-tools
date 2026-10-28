// 便签正文里的行内图片（第 7 批；规矩在 mac-overlay-panel §3「行内图片」、mac-whisker-notes.mdc「正文里的图片」）：
// **令牌**是存的正文里图片的样子——`![image](kitty-note-image://<UUID>.<ext>)`，记了宽度时
// `![image|240](kitty-note-image://<UUID>.<ext>)`（宽度是整数点）。载入编辑器时令牌换成附件字符 U+FFFC、
// 存盘时换回来（互转在 NoteTextView.replaceAll / NoteImageAttachment.stored(from:)）。
// 这里全是纯函数：认令牌、拼令牌、摘要里换「[图片]」、找一条正文引用了哪些编号、插图要换哪一段。
// **一行里认出几张、编辑器、标题摘要、墙卡片、30 天清理用的是同一份**（别在别处再拼一遍令牌）。
// 别的写法一律不是令牌，当普通文字——正文是用户能随便打的字，**绝不拿它去碰文件系统**。
// 文件怎么存、宽高怎么读、缩略图、清理的记账在 NoteImageStore.swift。

import Foundation

nonisolated enum NoteImages {
  /// 一张图的令牌里记着的东西
  struct Image: Equatable, Hashable, Sendable {
    /// 图片文件的编号（文件名 `<UUID>.<ext>` 的那一半）
    var id: UUID
    /// 小写字母数字，1–10 位
    var ext: String
    /// 令牌里记的宽度（整数点）；nil = 没记，显示时跟着正文可用宽走。写坏了（< 40 或 > 4000）当没写
    var width: Int?
  }

  /// 令牌里的地址前缀（`![image|240](` 后面这一段）
  static let scheme = "kitty-note-image://"
  /// 宽度合理的范围（写在这个范围外的当没写宽度）
  static let minWidth = 40
  static let maxWidth = 4000
  /// 标题、摘要、墙卡片上图片写成什么
  static let placeholder = "[图片]"
  /// 扩展名最长几位
  static let maxExtension = 10

  private static let bang: UInt16 = 0x21  // !
  private static let openBracket: UInt16 = 0x5B  // [
  private static let closeBracket: UInt16 = 0x5D  // ]
  private static let openParen: UInt16 = 0x28  // (
  private static let closeParen: UInt16 = 0x29  // )
  private static let pipe: UInt16 = 0x7C  // |
  private static let dot: UInt16 = 0x2E  // .
  private static let zero: UInt16 = 0x30
  private static let nine: UInt16 = 0x39
  private static let upperA: UInt16 = 0x41
  private static let upperF: UInt16 = 0x46
  private static let upperZ: UInt16 = 0x5A
  private static let lowerA: UInt16 = 0x61
  private static let lowerZ: UInt16 = 0x7A

  // MARK: 拼

  /// 一张图的令牌：`![image|240](kitty-note-image://<UUID>.<ext>)`（没记宽度时中间那段没有）
  static func token(_ image: Image) -> String {
    let size = image.width.map { "|\($0)" } ?? ""
    return "![image\(size)](\(scheme)\(image.id.uuidString).\(image.ext))"
  }

  /// 记了宽度时把宽度夹进合理范围；不在范围里当没写
  static func width(_ raw: Int?) -> Int? {
    guard let raw, (minWidth...maxWidth).contains(raw) else { return nil }
    return raw
  }

  /// 宽度的五档（右键图片的小菜单，便签未来计划 D3）。**只能存成点数**：令牌里写百分比 0.5.0 认不出来。
  /// 铺满 = 存上限 4000（显示时缩到这一行的可用宽、小图也拉满——0.5.0 读到也这样显示）；
  /// 原始大小 = 不记宽度（显示 min（原图点宽，可用宽），同新插的图）
  enum WidthPreset: CaseIterable, Sendable {
    case small, medium, large, fill, original

    var title: String {
      switch self {
      case .small: "小"
      case .medium: "中"
      case .large: "大"
      case .fill: "铺满"
      case .original: "原始大小"
      }
    }

    /// 存进令牌的宽度（原始大小不记）
    var width: Int? {
      switch self {
      case .small: 120
      case .medium: 240
      case .large: 360
      case .fill: NoteImages.maxWidth
      case .original: nil
      }
    }

    /// 令牌里记着的宽度是哪一档；拖把手拖出来的、不在这几个数上的不是任何一档（菜单里不打勾）
    init?(width: Int?) {
      guard let found = Self.allCases.first(where: { $0.width == width }) else { return nil }
      self = found
    }
  }

  /// 裁完之后令牌里的宽度（便签未来计划 D1）：记了宽度 W 的，按裁下来的占原图多宽换算——round(W × 裁下的宽 / 原宽)，
  /// 夹进 40–4000（裁完屏上的比例尺不变、不跳）；没记宽度的照旧不记（跟着原图点宽走），「铺满」照旧铺满
  static func croppedWidth(_ width: Int?, from fullWidth: Int, to croppedWidth: Int) -> Int? {
    guard let width, fullWidth > 0 else { return nil }
    if width == maxWidth { return width }
    let scaled = (Double(width) * Double(croppedWidth) / Double(fullWidth)).rounded()
    return min(max(Int(scaled), minWidth), maxWidth)
  }

  // MARK: 认

  /// 从 index 开始是不是一段令牌：是就给它的区间和内容（区间是 UTF-16 的）
  static func match(in text: NSString, at index: Int) -> (range: NSRange, image: Image)? {
    let length = text.length
    func unit(_ offset: Int) -> UInt16? {
      let position = index + offset
      return position >= 0 && position < length ? text.character(at: position) : nil
    }
    func literal(_ word: String, at offset: Int) -> Bool {
      let units = Array(word.utf16)
      for (position, expected) in units.enumerated() where unit(offset + position) != expected {
        return false
      }
      return true
    }
    guard unit(0) == bang, unit(1) == openBracket, literal("image", at: 2) else { return nil }
    var offset = 7
    var stored: Int?
    if unit(offset) == pipe {
      offset += 1
      var digits = 0
      var value = 0
      while let current = unit(offset), current >= zero, current <= nine, digits < 9 {
        value = value * 10 + Int(current - zero)
        digits += 1
        offset += 1
      }
      guard digits > 0 else { return nil }
      stored = NoteImages.width(value)
    }
    guard unit(offset) == closeBracket, unit(offset + 1) == openParen else { return nil }
    offset += 2
    guard literal(scheme, at: offset) else { return nil }
    offset += scheme.utf16.count
    // UUID：8-4-4-4-12 个大写十六进制
    var identifier: [UInt16] = []
    for position in 0..<36 {
      guard let current = unit(offset + position) else { return nil }
      if position == 8 || position == 13 || position == 18 || position == 23 {
        guard current == 0x2D else { return nil }  // -
      } else {
        guard (zero...nine).contains(current) || (upperA...upperF).contains(current) else {
          return nil
        }
      }
      identifier.append(current)
    }
    offset += 36
    guard let id = UUID(uuidString: String(decoding: identifier, as: UTF16.self)) else {
      return nil
    }
    guard unit(offset) == dot else { return nil }
    offset += 1
    var extensionUnits: [UInt16] = []
    while let current = unit(offset), extensionUnits.count < maxExtension,
      (zero...nine).contains(current) || (lowerA...lowerZ).contains(current)
    {
      extensionUnits.append(current)
      offset += 1
    }
    guard !extensionUnits.isEmpty, unit(offset) == closeParen else { return nil }
    offset += 1
    let image = Image(
      id: id, ext: String(decoding: extensionUnits, as: UTF16.self), width: stored)
    return (NSRange(location: index, length: offset), image)
  }

  /// 正文里所有的令牌（从前到后，互不相交）
  static func matches(in text: NSString) -> [(range: NSRange, image: Image)] {
    var found: [(range: NSRange, image: Image)] = []
    var index = 0
    while index < text.length {
      if text.character(at: index) == bang, let match = match(in: text, at: index) {
        found.append(match)
        index = NSMaxRange(match.range)
        continue
      }
      index += 1
    }
    return found
  }

  /// 正文（存的字）里有没有令牌：先做一个便宜的判断，绝大多数没有图片的便签就此打住
  /// 按字节找（Foundation 的 contains 每次都把正文桥成 NSString 再找：几千条便签过一遍要几十毫秒，同步一轮每条都问）
  static func containsToken(_ text: String) -> Bool {
    var text = text
    return text.withUTF8 { bytes in
      tokenPrefix.withUnsafeBufferPointer { needle in
        memmem(bytes.baseAddress, bytes.count, needle.baseAddress, needle.count) != nil
      }
    }
  }

  private static let tokenPrefix = Array("![image".utf8)

  /// 第一条令牌（标题摘要、墙卡片要用第一张图）
  static func first(in text: String) -> Image? {
    let string = text as NSString
    guard containsToken(text) else { return nil }
    return matches(in: string).first?.image
  }

  /// 正文里引用到的图片编号（清理时算「谁还被引用着」；归档的、「最近删除」里的便签都算）
  static func ids(in text: String) -> Set<UUID> {
    guard containsToken(text) else { return [] }
    return Set(matches(in: text as NSString).map(\.image.id))
  }

  /// index 那个字在哪张图上（令牌的中间也算）：找包含它的那一段令牌
  static func image(in text: NSString, covering index: Int) -> Image? {
    matches(in: text).first {
      index >= $0.range.location && index < NSMaxRange($0.range)
    }?.image
  }

  /// 这一行（不含行尾的换行）是不是「只有图片」：去掉令牌和空白之后什么都不剩（标题取正文第一行时跳过这种行，
  /// 墙卡片上也不要）
  static func isImageOnly(_ line: String) -> Bool {
    let string = line as NSString
    guard containsToken(line) else { return false }
    var rest = ""
    var last = 0
    for match in matches(in: string) {
      rest += string.substring(with: NSRange(location: last, length: match.range.location - last))
      last = NSMaxRange(match.range)
    }
    rest += string.substring(from: last)
    return rest.trimmingCharacters(in: .whitespaces).isEmpty
  }

  // MARK: 显示用

  /// 正文里的令牌换成「[图片]」（标题、摘要、墙卡片上那段字用）
  static func display(_ text: String) -> String {
    guard containsToken(text) else { return text }
    let string = text as NSString
    var parts: [String] = []
    var last = 0
    for match in matches(in: string) {
      parts.append(
        string.substring(with: NSRange(location: last, length: match.range.location - last)))
      parts.append(placeholder)
      last = NSMaxRange(match.range)
    }
    parts.append(string.substring(from: last))
    return parts.joined()
  }

  /// 正文里的令牌整段去掉（底下的字数、搜索用：一张图不算字，搜「image」「png」也不该命中带图的便签）
  static func stripping(_ text: String) -> String {
    guard containsToken(text) else { return text }
    let string = text as NSString
    var parts: [String] = []
    var last = 0
    for match in matches(in: string) {
      parts.append(
        string.substring(with: NSRange(location: last, length: match.range.location - last)))
      last = NSMaxRange(match.range)
    }
    parts.append(string.substring(from: last))
    return parts.joined()
  }

  /// 正文的显示形式（墙卡片上那段字用）：只有图片的行整行去掉（连行尾的换行），行内的令牌换成「[图片]」。
  /// **要在截取之前做**：不然在 1200 个字处把令牌截成两半会露出原文，只有图片的行也白占掉行数和字数（F11）
  static func displayLines(_ text: String) -> String {
    guard containsToken(text) else { return text }
    let string = text as NSString
    var parts: [String] = []
    var location = 0
    while location < string.length {
      var (start, end, contentsEnd) = (0, 0, 0)
      string.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      location = max(end, location + 1)
      let line = string.substring(with: NSRange(location: start, length: contentsEnd - start))
      if isImageOnly(line) { continue }
      parts.append(display(line))
      if end > contentsEnd {
        parts.append(
          string.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)))
      }
    }
    return parts.joined()
  }

  // MARK: 插图插在哪（纯函数）

  /// 插一段图片时正文怎么改：lead = 前面先加一个换行、trail = 后面再加一个换行、caret = 插完光标落在哪
  /// （相对替换区间的开头）。每张图独占一行：落点所在行前面有字就先换行；图后面**总要**有一个换行，
  /// 插完光标落到图下一行的行首（图后面那一行已经有字就是那一行的行首，没有就补一个空行——正文末尾插图也补）。
  /// 原来光标停在图后面（同一行），接着打的字排在图右边、还会把整段的行高撑成图高，评审后改成现在这样（PLAN §10）
  struct Insertion: Equatable, Sendable {
    var lead = false
    var trail = false
    /// 插完光标相对替换区间开头的位置（落在图下面那一行的行首）
    var caret = 0
  }

  /// 在 text 的 range 那一段插 count 张图（range 是选区：有选区就是换掉选中的那一段）
  static func insertion(in text: NSString, replacing range: NSRange, count: Int) -> Insertion {
    /// 光标夹在 `\r\n` 两个字中间时挪到 `\n` 之后（下一行的行首）：不把这对行尾拆开，
    /// 不然前面那段会多出一个空行（getLineStart 把 \r\n 当一个行尾，contentsEnd 在光标前，F1）
    func snapped(_ value: Int) -> Int {
      guard value > 0, value < text.length else { return value }
      return text.character(at: value - 1) == 0x0D && text.character(at: value) == 0x0A
        ? value + 1 : value
    }
    let start = snapped(min(max(range.location, 0), text.length))
    var lineStart = 0
    text.getLineStart(
      &lineStart, end: nil, contentsEnd: nil, for: NSRange(location: start, length: 0))
    lineStart = min(max(lineStart, 0), start)
    let head = text.substring(with: NSRange(location: lineStart, length: start - lineStart))
    var plan = Insertion()
    // 「前面有没有字」不算行首的列表标记（☐ / ☑ / - / 1. …）：任务行里方框后面可以直接贴图（R5、F15）
    plan.lead = hasContent(head)
    // 图后面总要有换行：光标落到下一行的行首（图后面已经有字时那一行就是它，没有就补一个空行）。
    // **以前这里还要取插入点后面到行尾的那一截**（`tailEnd`），光标夹在 \r\n 中间时那样算出来是负长度、substring 抛
    // NSRangeException（随机编辑测试种子 2001 跑出来的，F1）；现在那一截不用了，而光标在 \r\n 中间时上面已经挪到 \n 之后
    plan.trail = true
    plan.caret = (plan.lead ? 1 : 0) + count + max(0, count - 1) + 1
    return plan
  }

  /// 这一段（一行里插入点前面那截）有没有正文内容：行首的列表标记（`NoteTasks.prefix` 认的缩进 + 符号 + 空格）不算
  static func hasContent(_ head: String) -> Bool {
    let units = Array(head.utf16)
    let start = min(NoteTasks.prefix(of: units)?.contentStart ?? 0, units.count)
    return String(decoding: units[start...], as: UTF16.self).contains { !$0.isWhitespace }
  }
}
