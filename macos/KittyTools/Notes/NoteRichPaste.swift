// 往便签里粘网页、文稿（第四轮体检 X4，2026-11-17）：剪贴板里带格式的字（RTF 优先，没有再看 HTML）转成便签正文认的 Markdown，
// 链接、粗体、斜体、删除线、行内代码、标题、列表、代码块留着。只在设置里的 Markdown 开着、光标不在代码块里时这么粘
// （NoteTextView.paste）；转出来和纯文本一样（没有任何格式）就照旧粘纯文本。⌥⇧⌘V「粘贴为纯文本」总是粘纯文本。
// 转换是纯函数（markdown(from:)，配单测）：按段落走，标题看整段字号比正文大多少（HTML 的 h1–h3 进来是放大的粗体），
// 列表看段落样式里的 NSTextList（系统把列表符号「\t•\t」写进了字里，去掉、换成「- 」/「1. 」，嵌套的每层缩两格），
// 整段都是等宽字体的连着几段包成代码块，行内按「粗 / 斜 / 删除线 / 等宽 / 链接」把一样的连成一段再包标记（标记里不夹首尾空白）。
// 评审之后（2026-11-18）：只有一行的等宽字是行内代码（不出围栏）、几行等宽字中间的空行留在块里；不间断空格、全角空格不吞；
// <br> 进来的 U+2028 / U+2029 换成换行；一个标记都没转出来就当没有格式（照常粘纯文本，不悄悄改空行）；HTML 先去掉
// img / link / script / style / iframe 这类会去外面取东西的标签再交给系统解析；链接地址里的括号、空格转义。
// ponytail: 字里本来就有的 * _ ` [ 不转义（便签的 Markdown 不认反斜杠转义以外的写法，转了反而多出反斜杠）——碰巧凑成标记的会变样；
// 表格、引用、图片不转（表格按系统给的制表符原样，图片的占位字符去掉）；整段放大的引言（pull quote）会被当成标题；一个链接里一半粗体
// 会拆成两个链接。HTML 用系统的解析（WebKit，主线程，第一次约 0.3 秒），剪贴板里 RTF、HTML 都有时先用 RTF（便宜、不碰 WebKit）。

import AppKit

enum NoteRichPaste {
  /// 剪贴板里带格式的字转成 Markdown；没有带格式的字、转出来和纯文本一样时是 nil
  static func markdown(from pasteboard: NSPasteboard) -> String? {
    let text: NSAttributedString?
    if let rtf = pasteboard.data(forType: .rtf) {
      text = NSAttributedString(rtf: rtf, documentAttributes: nil)
    } else if let html = pasteboard.data(forType: .html) {
      text = NSAttributedString(
        html: Data(withoutRemoteResources(String(decoding: html, as: UTF8.self)).utf8),
        options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    } else {
      text = nil
    }
    guard let text, text.length > 0 else { return nil }
    let converted = convert(text)
    guard converted.marked, !converted.text.isEmpty else { return nil }
    return converted.text
  }

  /// HTML 里会去外面取东西的标签去掉（评审 A10：系统的解析遇到外面的图片会等它）：img、link、script、style（连内容）、
  /// iframe、video、audio、source、object、embed
  static func withoutRemoteResources(_ html: String) -> String {
    html
      .replacing(/(?is)<(script|style)\b.*?<\/\1\s*>/, with: "")
      .replacing(/(?i)<(img|link|iframe|video|audio|source|object|embed)\b[^>]*>/, with: "")
  }

  /// 粘进去的地方前后（X4 评审）：围栏得独占一行，前面不是行首就先换行、后面不是行尾就补换行（纯函数）
  static func fitting(_ markdown: String, after previous: Character?, before next: Character?)
    -> String
  {
    var text = markdown
    if text.hasPrefix("```"), let previous, !previous.isNewline { text = "\n" + text }
    if text.hasSuffix("```"), let next, !next.isNewline { text += "\n" }
    return text
  }

  /// 富文本 → Markdown（纯函数）
  static func markdown(from text: NSAttributedString) -> String { convert(text).text }

  /// 一行转出来的东西：代码行、普通行（带没带标记）、空行
  private enum Line {
    case code(String)
    case text(String, marked: Bool)
    case blank
  }

  /// 富文本 → Markdown，和转出来的字里有没有标记（一个都没有就照常粘纯文本）
  static func convert(_ text: NSAttributedString) -> (text: String, marked: Bool) {
    let string = text.string as NSString
    let body = bodySize(of: text)
    var lines: [Line] = []
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
      guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
        lines.append(.blank)
        continue
      }
      // 整段等宽：代码（原样，不加行内标记；一行的是行内代码、几行连着的是代码块，见下面）
      if range.length > 0, isMonospaced(text, in: range) {
        lines.append(.code(raw))
        continue
      }
      if let lists = style?.textLists, let list = lists.last {
        let marker = list.markerFormat.rawValue.contains("decimal") ? "1. " : "- "
        let indent = String(repeating: "  ", count: max(0, lists.count - 1))
        let content = inline(text, in: dropListMarker(range, in: string), heading: false)
        lines.append(.text(indent + marker + content.text, marked: true))
        continue
      }
      let level = headingLevel(text, in: range, body: body)
      let content = inline(text, in: range, heading: level > 0)
      lines.append(
        level > 0
          ? .text(String(repeating: "#", count: level) + " " + content.text, marked: true)
          : .text(content.text, marked: content.marked))
    }
    return assemble(lines)
  }

  /// 把行拼起来：连着的代码行（中间的空行算在块里）两行以上包围栏、一行的写成行内代码；空行最多留一行、去掉首尾的
  private static func assemble(_ lines: [Line]) -> (text: String, marked: Bool) {
    var out: [String] = []
    var marked = false
    var index = 0
    func blank() { if out.last?.isEmpty == false { out.append("") } }
    while index < lines.count {
      switch lines[index] {
      case .blank:
        blank()
        index += 1
      case .text(let line, let hasMarkup):
        out.append(line)
        marked = marked || hasMarkup
        index += 1
      case .code:
        // 这一串代码：到最后一行代码为止（中间的空行留在块里）
        var end = index
        var codeLines = 0
        var cursor = index
        while cursor < lines.count {
          if case .code = lines[cursor] {
            end = cursor
            codeLines += 1
          } else if case .text = lines[cursor] {
            break
          }
          cursor += 1
        }
        let block = lines[index...end].map { line -> String in
          if case .code(let code) = line { code } else { "" }
        }
        marked = true
        if codeLines == 1 {
          out.append(inlineCode(block[0]))
        } else {
          out.append("```")
          out.append(contentsOf: block)
          out.append("```")
        }
        index = end + 1
      }
    }
    while out.last?.isEmpty == true { out.removeLast() }
    while out.first?.isEmpty == true { out.removeFirst() }
    let text = out.joined(separator: "\n")
      .replacingOccurrences(of: "\u{2028}", with: "\n")
      .replacingOccurrences(of: "\u{2029}", with: "\n")
    return (text, marked)
  }

  /// 行内代码：字里有反引号就用两个包、两头留空格
  private static func inlineCode(_ code: String) -> String {
    code.contains("`") ? "`` " + code + " ``" : "`" + code + "`"
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
    -> (text: String, marked: Bool)
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
    var marked = false
    let text = runs.map { run in
      // 标记包住中间的字，首尾的空白留在外面（`** 粗 **` 不算粗体）；不间断空格、全角空格同样留着（评审 B4）
      let isSpace: (Character) -> Bool = { $0.isWhitespace && !$0.isNewline }
      let lead = String(run.text.prefix(while: isSpace))
      let rest = run.text.dropFirst(lead.count)
      let trail = String(rest.reversed().prefix(while: isSpace).reversed())
      let core = String(rest.dropLast(trail.count))
      guard !core.isEmpty else { return run.text }
      var wrapped = core
      if run.look.code {
        wrapped = inlineCode(wrapped)
      } else {
        if run.look.strike { wrapped = "~~" + wrapped + "~~" }
        if run.look.italic { wrapped = "*" + wrapped + "*" }
        if run.look.bold { wrapped = "**" + wrapped + "**" }
      }
      if let link = run.look.link, let url = URL(string: link), url.scheme != nil {
        // 地址里的括号、空白转义：不然 `)` 把链接截断
        let address = link.replacingOccurrences(of: "(", with: "%28")
          .replacingOccurrences(of: ")", with: "%29")
          .replacingOccurrences(of: " ", with: "%20")
        wrapped = "[" + wrapped + "](" + address + ")"
      }
      if wrapped != core { marked = true }
      return lead + wrapped + trail
    }.joined()
    return (text, marked)
  }
}
