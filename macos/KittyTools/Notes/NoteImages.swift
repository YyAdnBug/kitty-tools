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
  static func containsToken(_ text: String) -> Bool { text.contains("![image") }

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

  // MARK: 插图插在哪（纯函数）

  /// 插一段图片时正文怎么改：lead = 前面先加一个换行、trail = 后面再加一个换行、caret = 插完光标落在哪
  /// （相对替换区间的开头）。每张图独占一行：落点所在行前面有字就先换行，后面有字就在图后换行
  struct Insertion: Equatable, Sendable {
    var lead = false
    var trail = false
    /// 插完光标相对替换区间开头的位置（正好在最后一张图后面）
    var caret = 0
  }

  /// 在 text 的 range 那一段插 count 张图（range 是选区：有选区就是换掉选中的那一段）
  static func insertion(in text: NSString, replacing range: NSRange, count: Int) -> Insertion {
    let start = min(max(range.location, 0), text.length)
    let end = min(max(NSMaxRange(range), start), text.length)
    var lineStart = 0
    var contentsEnd = 0
    text.getLineStart(
      &lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
    var tailEnd = 0
    text.getLineStart(
      nil, end: nil, contentsEnd: &tailEnd, for: NSRange(location: end, length: 0))
    let head = text.substring(with: NSRange(location: lineStart, length: start - lineStart))
    let tail = text.substring(with: NSRange(location: end, length: tailEnd - end))
    var plan = Insertion()
    plan.lead = head.contains { !$0.isWhitespace }
    plan.trail = tail.contains { !$0.isWhitespace }
    plan.caret = (plan.lead ? 1 : 0) + count + max(0, count - 1)
    return plan
  }
}
