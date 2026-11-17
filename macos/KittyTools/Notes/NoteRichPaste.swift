// 往便签里粘网页、文稿（第四轮体检 X4，2026-11-17）：剪贴板里带格式的字（RTF 优先，没有再看 HTML）转成便签正文认的 Markdown，
// 链接、粗体、斜体、删除线、行内代码、标题、列表、代码块留着。只在设置里的 Markdown 开着、光标不在代码块里时这么粘
// （NoteTextView.paste）；转出来和纯文本一样（没有任何格式）就照旧粘纯文本。⌥⇧⌘V「粘贴为纯文本」总是粘纯文本。
// 转换是纯函数（markdown(from:)，配单测）：按段落走，标题看整段字号比正文大多少（HTML 的 h1–h3 进来是放大的粗体），
// 列表看段落样式里的 NSTextList（系统把列表符号「\t•\t」写进了字里，去掉、换成「- 」/「1. 」，嵌套的每层缩两格），
// 整段都是等宽字体的连着几段包成代码块，行内按「粗 / 斜 / 删除线 / 等宽 / 链接」把一样的连成一段再包标记（标记里不夹首尾空白）。
// ponytail: 字里本来就有的 * _ ` [ 不转义（便签的 Markdown 不认反斜杠转义以外的写法，转了反而多出反斜杠）——碰巧凑成标记的会变样；
// 表格、引用、图片不转（表格按系统给的制表符原样，图片的占位字符去掉）。HTML 用系统的解析（WebKit，主线程、几十毫秒），
// 剪贴板里 RTF、HTML 都有时先用 RTF（便宜、不碰 WebKit）。

import AppKit

enum NoteRichPaste {
  /// 剪贴板里带格式的字转成 Markdown；没有带格式的字、转出来和纯文本一样时是 nil
  static func markdown(from pasteboard: NSPasteboard) -> String? {
    let text: NSAttributedString?
    if let rtf = pasteboard.data(forType: .rtf) {
      text = NSAttributedString(rtf: rtf, documentAttributes: nil)
    } else if let html = pasteboard.data(forType: .html) {
      text = NSAttributedString(
        html: html, options: [.characterEncoding: String.Encoding.utf8.rawValue],
        documentAttributes: nil)
    } else {
      text = nil
    }
    guard let text, text.length > 0 else { return nil }
    let markdown = markdown(from: text)
    let plain = text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    guard !markdown.isEmpty, markdown != plain.trimmingCharacters(in: .newlines) else { return nil }
    return markdown
  }

  /// 富文本 → Markdown（纯函数）
  static func markdown(from text: NSAttributedString) -> String {
    let string = text.string as NSString
    let body = bodySize(of: text)
    var lines: [String] = []
    var inCode = false
    var location = 0
    while location < string.length {
      var end = 0
      var contentsEnd = 0
      string.getParagraphStart(
        nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let range = NSRange(location: location, length: contentsEnd - location)
      location = end
      let style =
        range.length > 0
        ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
          as? NSParagraphStyle : nil
      let raw = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
      // 整段等宽：代码块（原样，不加行内标记）
      if range.length > 0, !raw.trimmingCharacters(in: .whitespaces).isEmpty,
        isMonospaced(text, in: range)
      {
        if !inCode {
          lines.append("```")
          inCode = true
        }
        lines.append(raw)
        continue
      }
      if inCode {
        lines.append("```")
        inCode = false
      }
      guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
        // 空段：最多留一行空行
        if lines.last?.isEmpty == false { lines.append("") }
        continue
      }
      if let lists = style?.textLists, let list = lists.last {
        let marker = list.markerFormat.rawValue.contains("decimal") ? "1. " : "- "
        let indent = String(repeating: "  ", count: max(0, lists.count - 1))
        let content = inline(text, in: dropListMarker(range, in: string), heading: false)
        lines.append(indent + marker + content)
        continue
      }
      let level = headingLevel(text, in: range, body: body)
      let content = inline(text, in: range, heading: level > 0)
      lines.append(level > 0 ? String(repeating: "#", count: level) + " " + content : content)
    }
    if inCode { lines.append("```") }
    while lines.last?.isEmpty == true { lines.removeLast() }
    while lines.first?.isEmpty == true { lines.removeFirst() }
    return lines.joined(separator: "\n")
  }

  /// 正文字号：字数最多的那个字号
  private static func bodySize(of text: NSAttributedString) -> CGFloat {
    var counts: [CGFloat: Int] = [:]
    text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) {
      value, range, _ in
      if let font = value as? NSFont { counts[font.pointSize, default: 0] += range.length }
    }
    return counts.max { $0.value < $1.value }?.key ?? NSFont.systemFontSize
  }

  /// 整段比正文大多少算几级标题（只认短段落、整段一个字号）：1.6 倍以上一级、1.3 倍以上二级、1.1 倍以上又是粗体三级
  private static func headingLevel(_ text: NSAttributedString, in range: NSRange, body: CGFloat)
    -> Int
  {
    guard range.length <= 200, body > 0 else { return 0 }
    var size: CGFloat?
    var bold = true
    var uniform = true
    text.enumerateAttribute(.font, in: range) { value, run, stop in
      guard let font = value as? NSFont else { return }
      let visible = (text.string as NSString).substring(with: run)
        .trimmingCharacters(in: .whitespaces)
      guard !visible.isEmpty else { return }
      if let size, abs(size - font.pointSize) > 0.5 {
        uniform = false
        stop.pointee = true
      }
      size = size ?? font.pointSize
      if !font.fontDescriptor.symbolicTraits.contains(.bold) { bold = false }
    }
    guard uniform, let size else { return 0 }
    let ratio = size / body
    if ratio >= 1.6 { return 1 }
    if ratio >= 1.3 { return 2 }
    if ratio >= 1.1, bold { return 3 }
    return 0
  }

  /// 这段字是不是整段等宽字体（空白不算）
  private static func isMonospaced(_ text: NSAttributedString, in range: NSRange) -> Bool {
    var mono = true
    text.enumerateAttribute(.font, in: range) { value, run, stop in
      let visible = (text.string as NSString).substring(with: run)
        .trimmingCharacters(in: .whitespaces)
      guard !visible.isEmpty else { return }
      if !((value as? NSFont)?.isFixedPitch ?? false) {
        mono = false
        stop.pointee = true
      }
    }
    return mono
  }

  /// 列表段落开头系统写进去的「\t•\t」「\t1.\t」：去掉
  private static func dropListMarker(_ range: NSRange, in string: NSString) -> NSRange {
    let line = string.substring(with: range)
    guard let match = line.firstMatch(of: /^\t*[^\t]{0,8}\t/) else { return range }
    let skipped = (String(line[match.range]) as NSString).length
    return NSRange(location: range.location + skipped, length: range.length - skipped)
  }

  /// 行内：粗体、斜体、删除线、等宽、链接一样的连成一段再包标记（标题里不加粗：标题本来就粗）
  private static func inline(_ text: NSAttributedString, in range: NSRange, heading: Bool)
    -> String
  {
    struct Look: Equatable {
      var bold = false
      var italic = false
      var strike = false
      var code = false
      var link: String?
    }
    var runs: [(look: Look, text: String)] = []
    text.enumerateAttributes(in: range) { attributes, run, _ in
      let piece = (text.string as NSString).substring(with: run)
        .replacingOccurrences(of: "\u{FFFC}", with: "")
      guard !piece.isEmpty else { return }
      var look = Look()
      if let font = attributes[.font] as? NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        look.bold = traits.contains(.bold) && !heading
        look.italic = traits.contains(.italic)
        look.code = font.isFixedPitch
      }
      look.strike = ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0
      switch attributes[.link] {
      case let url as URL: look.link = url.absoluteString
      case let string as String: look.link = string
      default: break
      }
      if let last = runs.last, last.look == look {
        runs[runs.count - 1].text += piece
      } else {
        runs.append((look, piece))
      }
    }
    return runs.map { run in
      // 标记包住中间的字，首尾的空白留在外面（`** 粗 **` 不算粗体）
      let core = run.text.trimmingCharacters(in: .whitespaces)
      guard !core.isEmpty else { return run.text }
      let lead = String(run.text.prefix { $0 == " " || $0 == "\t" })
      let trail = String(run.text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
      var wrapped = core
      if run.look.code {
        wrapped = "`" + wrapped + "`"
      } else {
        if run.look.strike { wrapped = "~~" + wrapped + "~~" }
        if run.look.italic { wrapped = "*" + wrapped + "*" }
        if run.look.bold { wrapped = "**" + wrapped + "**" }
      }
      if let link = run.look.link, let url = URL(string: link), url.scheme != nil,
        !link.contains(where: \.isWhitespace)
      {
        wrapped = "[" + wrapped + "](" + link + ")"
      }
      return lead + wrapped + trail
    }.joined()
  }
}
