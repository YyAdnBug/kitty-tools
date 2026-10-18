// 便签第 8 批（2026-10-17）的纯函数单测：
// - 任务的五种状态（认法、点方框、改状态、⌘T、回车、自动转换、进度、和 Markdown 互转跳过代码块）；
// - 文字颜色的扫描（六种名字、大小写、空白、嵌套、链接、图片方括号）、上色（选段、跨粗体 / 链接、代码块、图片、
//   默认颜色去色、表情）、plain、颜色 ⇄ `<span>`；
// - 六种颜色的对比度（对 8 张纸、两种外观）和彼此区分；
// - 五种方框缩齐之后的前进宽一样、字形高差 < 0.5 pt，紧急是红的；
// - R12「粘到哪」的小函数、R13 读便签选区的小函数。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct NoteBatch8Tests {
  private func range(_ location: Int, _ length: Int = 0) -> NSRange {
    NSRange(location: location, length: length)
  }

  private func applied(_ change: NoteTasks.Change?, to text: String) -> String? {
    guard let change else { return nil }
    let result = NSMutableString(string: text)
    for replacement in change.replacements.reversed() {
      result.replaceCharacters(in: replacement.range, with: replacement.text)
    }
    return result as String
  }

  // MARK: 任务的五种状态

  @Test func fiveTaskStates() {
    for state in NoteTasks.State.allCases {
      let line = "  \(state.character) 周报"
      let prefix = NoteTasks.prefix(of: line)
      #expect(prefix?.lead == .task(state) && prefix?.indent == 2 && prefix?.contentStart == 4)
      #expect(NoteTasks.box(in: line) == 2 && NoteTasks.state(of: line) == state)
    }
    // 后面跟空格或行尾才算；后面直接跟字、行中间的不算
    #expect(NoteTasks.prefix(of: "◧abc") == nil && NoteTasks.prefix(of: "▣\t周报") == nil)
    #expect(NoteTasks.prefix(of: "记得 ☐ 周报") == nil)
    // 点方框：待办 / 进行中 / 紧急 → 完成；完成 / 取消 → 待办
    #expect(NoteTasks.flipped("☐") == "☑")
    #expect(NoteTasks.flipped("◧") == "☑")
    #expect(NoteTasks.flipped("▣") == "☑")
    #expect(NoteTasks.flipped("☑") == "☐")
    #expect(NoteTasks.flipped("☒") == "☐")
    #expect(NoteTasks.State.todo.isClosed == false && NoteTasks.State.done.isClosed)
    #expect(
      NoteTasks.State.cancelled.isClosed && NoteTasks.State.cancelled.countsAsProgress == false)
  }

  @Test func setStateTouchesEveryLineButLeavesBlankLines() {
    let body = "a\n- b\n  ☐ c\n\n☒ d\n🎉 e"
    let change = NoteTasks.setState(
      .urgent, in: body, selection: range(0, (body as NSString).length))
    #expect(applied(change, to: body) == "▣ a\n▣ b\n  ▣ c\n\n▣ d\n▣ 🎉 e")
    // 只有一行时空行也变成任务；已经是这种状态的返回 nil
    #expect(applied(NoteTasks.setState(.doing, in: "", selection: range(0)), to: "") == "◧ ")
    #expect(NoteTasks.setState(.urgent, in: "▣ a", selection: range(1)) == nil)
    // ⌘T：五种状态都算任务；全去掉标记
    let tasks = "☐ a\n◧ b\n▣ c\n☑ d\n☒ e"
    #expect(applied(NoteTasks.toggle(tasks, selection: range(0, 19)), to: tasks) == "a\nb\nc\nd\ne")
    let mixed = "☐ a\nb\n- c"
    #expect(applied(NoteTasks.toggle(mixed, selection: range(0, 11)), to: mixed) == "☐ a\n☐ b\n☐ c")
    // 选区碰到的行都是同一种状态时给那种
    #expect(NoteTasks.state(in: "a\n▣ b\n▣ c", selection: range(0, 8)) == .urgent)
    #expect(NoteTasks.state(in: "▣ b\n☐ c", selection: range(0, 6)) == nil)
  }

  @Test func newlineAndShorthandUnderstandEveryState() {
    // 任何状态的任务按回车，下一行都是待办
    for state in NoteTasks.State.allCases {
      let line = "\(state.character) 周报"
      let change = NoteTasks.newline(in: line, caret: 4)
      #expect(applied(change, to: line) == "\(line)\n☐ ")
    }
    for (typed, character) in [
      ("- [ ]", "☐"), ("- [/]", "◧"), ("- [!]", "▣"), ("- [x]", "☑"), ("- [-] ", "☒"),
    ] {
      let caret = (typed as NSString).length
      let line = typed.hasSuffix(" ") ? String(typed.dropLast()) : typed
      let change = NoteTasks.shorthand(in: line, caret: (line as NSString).length)
      #expect(applied(change, to: line) == "\(character) ", "\(typed)")
      _ = caret
    }
  }

  @Test func markdownRoundTripsTheFiveStatesAndSkipsCode() {
    let body = "☐ 一\n◧ 二\n  ▣ 三\n☑ 四\n☒ 五\n```swift\n☑ 块里\n```\n☐ 末"
    let markdown = NoteTasks.markdown(from: body)
    #expect(
      markdown
        == "- [ ] 一\n- [/] 二\n  - [!] 三\n- [x] 四\n- [-] 五\n```swift\n☑ 块里\n```\n- [ ] 末")
    #expect(NoteTasks.body(fromMarkdown: markdown) == body)
    // Markdown 的五种写法都认；代码块里的不换
    let foreign = "- [ ] 一\n- [/] 二\n- [!] 三\n- [x] 四\n- [-] 五\n```\n- [x] 块里\n```"
    #expect(
      NoteTasks.body(fromMarkdown: foreign)
        == "☐ 一\n◧ 二\n▣ 三\n☑ 四\n☒ 五\n```\n- [x] 块里\n```")
  }

  @Test func progressIgnoresCancelledAndCodeBlocks() {
    let body = "☐ 一\n◧ 二\n▣ 三\n☑ 四\n☒ 五\n```\n☑ 块里\n```"
    let progress = NoteTasks.progress(in: body)
    #expect(progress?.done == 1 && progress?.total == 4)
    // 只有取消的没有进度
    #expect(NoteTasks.progress(in: "☒ 一\n☒ 二") == nil)
  }

  // MARK: 文字颜色：扫描

  /// 一行里认出来的颜色和它的标记（按位置排好）
  private func colors(_ line: String) -> [String] {
    NoteMarkdown.inline(Array(line.utf16), in: 0..<(line as NSString).length).compactMap { span in
      switch span.kind {
      case .color(let color):
        "\(color.name)@\(span.range.location):\((line as NSString).substring(with: span.range))"
      default: nil
      }
    }
  }

  @Test func colorScanning() {
    for color in NoteColor.allCases {
      #expect(
        colors("[\(color.name)的字]{\(color.name)}") == [
          "\(color.name)@1:\(color.name)的字"
        ])
    }
    // 名字只认全小写的这六个；空白、没配上、空的、跨行都不算
    #expect(colors("[字]{Red}").isEmpty && colors("[字]{RED}").isEmpty)
    #expect(colors("[字]{ red}").isEmpty && colors("[字]{red }").isEmpty)
    #expect(colors("[ ]{red}").isEmpty && colors("[] {red}").isEmpty)
    #expect(colors("[字]{red").isEmpty)
    // 反斜杠、行内代码、图片的方括号不是颜色
    #expect(colors("\\[字]{red}").isEmpty)
    #expect(colors("`[字]{red}`").isEmpty)
    #expect(colors("![图]{red}").isEmpty)
    // 颜色里不套颜色：里面那个算，外面那一对原样
    #expect(colors("[[a]{red}]{blue}") == ["red@2:a"])
    // 颜色里有粗体 / 链接；链接的字里可以有颜色
    #expect(colors("[**粗**]{red}") == ["red@1:**粗**"])
    #expect(colors("[[字]{red}](https://a.b)") == ["red@2:字"])
    // 代码块里的行（外面那层）不算
    #expect(colors("[`码`]{red}") == ["red@1:`码`"])
  }

  // MARK: 文字颜色：上色

  @Test func colorToggle() {
    let red = NoteColor.red
    // 整段、半段、跨粗体边界、跨链接
    #expect(
      applied(NoteMarkdown.color(red, in: "字", selection: range(0, 1)), to: "字") == "[字]{red}")
    #expect(
      applied(NoteMarkdown.color(red, in: "a**b**c", selection: range(0, 6)), to: "a**b**c")
        == "[a]{red}**[b]{red}**c")
    #expect(
      applied(NoteMarkdown.color(red, in: "a**b**c", selection: range(0, 8)), to: "a**b**c")
        == "[a]{red}**[b]{red}**[c]{red}")
    #expect(
      applied(
        NoteMarkdown.color(red, in: "[字](https://a.b)", selection: range(1, 1)),
        to: "[字](https://a.b)") == "[[字]{red}](https://a.b)")
    // 一半改色、默认颜色去色
    #expect(
      applied(NoteMarkdown.color(red, in: "abc", selection: range(0, 2)), to: "abc")
        == "[ab]{red}c")
    #expect(
      applied(NoteMarkdown.color(nil, in: "[a]{red}bc", selection: range(1, 1)), to: "[a]{red}bc")
        == "abc")
    #expect(NoteMarkdown.color(nil, in: "abc", selection: range(0, 2)) == nil)
    // 代码、图片不能上色；图片旁边的字可以，图片自己不被包进去
    #expect(NoteMarkdown.color(red, in: "`a` b", selection: range(0, 3)) == nil)
    #expect(
      applied(NoteMarkdown.color(red, in: "a\u{FFFC}b", selection: range(0, 3)), to: "a\u{FFFC}b")
        == "[a]{red}\u{FFFC}[b]{red}")
    // 标题跳过行首的 #
    #expect(
      applied(NoteMarkdown.color(red, in: "# a b", selection: range(0, 5)), to: "# a b")
        == "# [a b]{red}")
    // 上完色的结果过一遍扫描器：除了颜色以外没变
    let body = "**粗** *斜* ~~删~~ `码` [链](https://a.b)"
    let change = NoteMarkdown.color(.purple, in: body, selection: range(0))
    #expect(change == nil || applied(change, to: body) != nil)
  }

  /// 一行两万字全选上色：结果对，而且时间是线性的。修之前每个看得见的字都把整行重新扫一遍（25 秒级），
  /// 这里 0.5 秒的上限是在防平方回来，不是卡性能
  @Test func coloringAVeryLongLineStaysLinear() {
    let unit = "abc **粗体** def `x`"
    let coloredUnit = "[abc ]{red}**[粗体]{red}**[ def ]{red}`x`"
    let repeats = 1112
    let line = String(repeating: unit, count: repeats)
    #expect((line as NSString).length == 20016)
    let selection = NSRange(location: 0, length: (line as NSString).length)
    let clock = ContinuousClock()
    var change: NoteTasks.Change?
    let elapsed = clock.measure {
      change = NoteMarkdown.color(.red, in: line, selection: selection)
    }
    #expect(change != nil)
    #expect(applied(change, to: line) == String(repeating: coloredUnit, count: repeats))
    #expect(elapsed < .milliseconds(500), "一行两万字全选上色用了 \(elapsed)")
  }

  @Test func plainAndStrippingRemoveColorMarkers() {
    #expect(NoteMarkdown.plain("[字]{red} 和 **粗**", blocks: false) == "字 和 粗")
    #expect(NoteMarkdown.strippingColors(from: "[字]{red} **粗**") == "字 **粗**")
    #expect(NoteMarkdown.strippingColors(from: "```\n[字]{red}\n```") == "```\n[字]{red}\n```")
    #expect(NoteMarkdown.colorOnlySpans(in: "[字]{red} **粗**").count == 3)
    #expect(NoteMarkdown.colorOnlySpans(in: "**粗**").isEmpty)
  }

  // MARK: 文字颜色：⇄ <span>

  @Test func colorHTMLRoundTrip() {
    #expect(
      NoteMarkdown.html(from: "[字]{red}") == "<span style=\"color: #A11A14\">字</span>")
    #expect(
      NoteMarkdown.html(from: "[[链](https://a.b)]{blue}")
        == "<span style=\"color: #1D4FB8\">[链](https://a.b)</span>")
    #expect(NoteMarkdown.html(from: "```\n[字]{red}\n```") == "```\n[字]{red}\n```")
    for raw in [
      "<span style=\"color: #a11a14\">字</span>",
      "<span style=\"color:#A11A14;\">字</span>",
      "<span style=\"color: #FF9C94\">字</span>",
    ] {
      #expect(NoteMarkdown.body(fromHTML: raw) == "[字]{red}", "\(raw)")
    }
    // 别的 HTML、别的色值、行内代码和代码块里的都原样
    for raw in [
      "<span style=\"color: #123456\">字</span>",
      "<span class=\"x\">字</span>",
      "<b>字</b>",
      "`<span style=\"color: #A11A14\">字</span>`",
      "```\n<span style=\"color: #A11A14\">字</span>\n```",
      "<span style=\"color: #A11A14\">a<span>b</span>",
    ] {
      #expect(NoteMarkdown.body(fromHTML: raw) == raw, "\(raw)")
    }
    let body = "普通 [红]{red} **粗**\n```\n[代码]{red}\n```\n[蓝]{blue} 末"
    #expect(NoteMarkdown.body(fromHTML: NoteMarkdown.html(from: body)) == body)
  }

  // MARK: 六种颜色

  @Test func colorsAreReadableOnEveryPaper() {
    for paper in NotePaper.all {
      for color in NoteColor.allCases {
        for (hex, tone) in [
          (color.light, paper.light), (color.dark, paper.dark),
        ] {
          let contrast = AccentPalette.contrast(srgb(hex), srgb(tone.paper))
          #expect(contrast >= 4.5, "\(paper.name) \(color.name) \(hex) = \(contrast)")
        }
      }
    }
    // 同一外观下六种彼此看得出来：归一化 RGB 距离 ≥ 0.15（红和橙最近，浅色 0.19）
    for index in 0..<2 {
      let values = NoteColor.allCases.map { index == 0 ? $0.light : $0.dark }
      for i in 0..<values.count {
        for j in (i + 1)..<values.count {
          let distance = rgbDistance(values[i], values[j])
          #expect(distance >= 0.15, "第 \(i) 和 \(j) 种：\(distance)")
        }
      }
    }
  }

  private func rgbDistance(_ a: Int, _ b: Int) -> Double {
    let parts = { (hex: Int) in
      (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }
    let (ar, ag, ab) = parts(a)
    let (br, bg, bb) = parts(b)
    return ((ar - br) * (ar - br) + (ag - bg) * (ag - bg) + (ab - bb) * (ab - bb)).squareRoot()
      / 255
  }

  // MARK: 五种方框

  @Test func boxGlyphsLineUpAndUrgentIsRed() {
    // 五个字一样宽（字形不画、方框是自己画的，只要占的宽一样：换状态后面的字不挪）
    for size in [13, 15, 17, 20] as [CGFloat] {
      let advances = NoteTasks.State.allCases.map { state in
        let metrics = NoteStyles.boxMetrics(size: size, state: state)
        return NSAttributedString(
          string: String(state.character), attributes: [.font: metrics.font, .kern: metrics.kern]
        ).size().width
      }
      #expect(advances.max()! - advances.min()! < 0.01, "\(size) 前进宽 \(advances)")
    }
    // 字上记着状态；紧急的颜色（方框的底）是红的，别的方框不是
    let storage = NSTextStorage(string: "▣ 急\n☐ 办")
    let theme = NoteStyles.Theme(
      paper: NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard)
    NoteStyles.apply(
      to: storage, lines: range(0, storage.length), theme: theme, shown: [], blocks: [])
    #expect(storage.attribute(NoteStyles.taskBoxKey, at: 0, effectiveRange: nil) as? Int == 2)
    #expect(storage.attribute(NoteStyles.taskBoxKey, at: 4, effectiveRange: nil) as? Int == 0)
    #expect(storage.attribute(NoteStyles.taskBoxKey, at: 2, effectiveRange: nil) == nil)
    #expect(storage.attribute(NoteStyles.taskMarkKey, at: 0, effectiveRange: nil) != nil)
    #expect(storage.attribute(NoteStyles.taskMarkKey, at: 4, effectiveRange: nil) == nil)
    func red(at index: Int) -> Int {
      let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
      var red = 0
      NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        if let rgb = color?.usingColorSpace(.sRGB) {
          red = Int((rgb.redComponent * 255).rounded())
        }
      }
      return red
    }
    #expect(red(at: 0) == 0xA1)
    #expect(red(at: 4) != 0xA1)
  }

  // MARK: R12 / R13 的小函数

  @Test func pasteTargetOnlyWhenEditableAndOnScreen() {
    let window = NSWindow(
      contentRect: CGRect(x: -30000, y: -30000, width: 200, height: 120),
      styleMask: [.borderless], backing: .buffered, defer: true)
    let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
    window.contentView = view
    #expect(Paster.pasteTarget(isOnScreen: true, firstResponder: view) === view)
    #expect(Paster.pasteTarget(isOnScreen: false, firstResponder: view) == nil)
    #expect(Paster.pasteTarget(isOnScreen: true, firstResponder: NSView()) == nil)
    view.isEditable = false
    #expect(Paster.pasteTarget(isOnScreen: true, firstResponder: view) == nil)
  }

  @Test func storeSearchIgnoresColorNames() {
    let notes = [
      Note(id: "a", body: "只是上了色 [字]{red}", createdAt: .now, modifiedAt: .now),
      Note(id: "b", body: "真的写了 red", createdAt: .now, modifiedAt: .now),
    ]
    #expect(NoteStore.search("red", in: notes).map(\.id) == ["b"])
    #expect(NoteStore.search("字", in: notes).map(\.id) == ["a"])
  }
}
