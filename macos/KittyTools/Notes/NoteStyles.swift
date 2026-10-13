// 便签正文的样式（PLAN §10「便签」第 5 批；下一批的 Markdown 往这里加种类）：存的是纯文本，样式是显示时加的属性——
// 只改属性、不改字、不进撤销栈、不动选区。分三块：
// - spans(in:)：纯函数，一行文字 → 若干「区间 + 样式种类」。现在只有任务的两种：方框那个字、做完的任务的内容。
// - Pending / lines(covering:)：纯函数，编辑过的区间 → 要重排的那几行（前后各扩一个字符、扩到整行；输入法组字期间
//   攒着，确认后一次补上）。
// - apply：薄的一层，把种类换成属性写进文本存储（先把这几行铺回基础样式，再按 spans 加）。
// 方框「☐」「☑」用同一种字体（Apple Symbols）：系统字体里只有「☑」没有「☐」，各走各的后备字体的话两个一大一小、
// 打勾时后面的字还会左右挪。
// ponytail: 方框就是那两个字形，没有自己画；Apple Symbols 的行高比系统字体略大，任务行因此比普通行高 1 pt 左右
// （各字号不同，13 / 17 号字是 0）。要圆角的、做完是实心的方框，或者行高分毫不差：把方框那个字藏起来（透明 + 小字号）
// 在 NoteTextView.draw 里自己画。

import AppKit

nonisolated enum NoteStyles {
  /// 样式的种类
  enum Kind: Equatable, Sendable {
    /// 任务的方框（☐ / ☑ 那一个字）
    case box
    /// 做完的任务的内容：划线、墨色变淡
    case done
  }

  /// 一段样式：区间是 UTF-16 的、相对这一行的开头
  struct Span: Equatable, Sendable {
    var range: NSRange
    var kind: Kind
  }

  /// 这一行（不含行尾的换行）要加哪些样式
  static func spans(in line: String) -> [Span] {
    guard let prefix = NoteTasks.prefix(of: line), case .task(let isDone) = prefix.lead else {
      return []
    }
    var spans = [Span(range: NSRange(location: prefix.indent, length: 1), kind: .box)]
    let length = (line as NSString).length
    if isDone, length > prefix.contentStart {
      spans.append(
        Span(
          range: NSRange(location: prefix.contentStart, length: length - prefix.contentStart),
          kind: .done))
    }
    return spans
  }

  /// 攒着的「编辑过的区间」（文本存储每处理完一次改字报一次）：合成一段，后来的编辑让前面记下的位置跟着挪。
  /// 输入法组字期间只攒不用，确认后一次拿走
  struct Pending: Equatable, Sendable {
    private(set) var range: NSRange?

    /// 记一次编辑：edited 是改完之后那一段的位置，delta 是长度变了多少
    mutating func record(_ edited: NSRange, delta: Int) {
      guard let old = range else {
        range = edited
        return
      }
      // 改之前那一段到哪为止：在它后面的位置都挪了 delta
      let oldEnd = NSMaxRange(edited) - delta
      var (start, end) = (old.location, NSMaxRange(old))
      if start >= oldEnd { start += delta }
      if end >= oldEnd { end += delta }
      start = max(min(start, edited.location), 0)
      end = max(end, NSMaxRange(edited))
      range = NSRange(location: start, length: end - start)
    }

    /// 拿走攒着的那一段
    mutating func take() -> NSRange? {
      defer { range = nil }
      return range
    }
  }

  /// 编辑过的区间 → 要重排的那几行（整行，连行尾的换行）：前后各扩一个字符再扩到整行——插入、删除换行时
  /// 两头的行都要重排。区间夹进正文的长度里（攒着的时候正文又变短了也不越界）
  static func lines(covering edited: NSRange, in text: NSString) -> NSRange {
    let start = min(max(edited.location - 1, 0), text.length)
    let end = min(max(NSMaxRange(edited) + 1, start), text.length)
    return text.lineRange(for: NSRange(location: start, length: end - start))
  }

  /// 方框比正文的字大多少
  static let boxScale: CGFloat = 1.1

  /// 把 range 那几行（整行）的样式重排一遍：铺回基础样式，再按 spans 加。只动属性
  @MainActor
  static func apply(
    to storage: NSTextStorage, lines range: NSRange, font: NSFont, ink: NSColor, faded: NSColor
  ) {
    guard range.length > 0 else { return }
    let text = storage.mutableString
    let box = NSFont(name: "AppleSymbols", size: (font.pointSize * boxScale).rounded())
    // 方框往上抬一点：Apple Symbols 的字形坐在基线上，抬到和字的中线差不多齐
    let lift = box.map { max(0, font.descender - $0.descender) } ?? 0
    storage.beginEditing()
    storage.setAttributes([.font: font, .foregroundColor: ink], range: range)
    var location = range.location
    while location < NSMaxRange(range) {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
      for span in spans(in: line) {
        let target = NSRange(location: start + span.range.location, length: span.range.length)
        switch span.kind {
        case .box:
          if let box {
            storage.addAttributes([.font: box, .baselineOffset: lift], range: target)
          }
        case .done:
          storage.addAttributes(
            [
              .foregroundColor: faded, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ], range: target)
        }
      }
      location = max(end, location + 1)
    }
    storage.endEditing()
  }
}
