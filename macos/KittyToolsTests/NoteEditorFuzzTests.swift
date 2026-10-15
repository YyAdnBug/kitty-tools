// 便签正文编辑器（Notes/NoteTextView.swift）的随机操作探针，按需跑（PLAN §10「便签」手测反馈第 4 批评审后那一轮：
// 原来是 macos/build/ 下的小程序，build 不进仓库，改成按环境变量开的单测）。屏外窗口里一个真的 NoteTextView，
// 随机做：放光标、选一段、多段选区、拖选（stillSelecting）、打字（带标记、围栏、软换行、\r\n、表情）、删、回车 / ⌃↩、
// Tab / ⇧Tab、⌘T、四个加标记的键（按键事件交给窗口 / 直接调 format）、粘贴（网址成链接、照常粘贴）、围栏行的增删改、
// 撤销 / 重做、输入法组字后确认 / 撤掉 / unmarkText（组字期间换纸色、换 key、按加标记的键）、换纸色 / 字号 / 行距 /
// Markdown 开关、拿 / 丢焦点、窗口当上 / 不再是 key、外面换了正文（setText）、直接改文本存储（在选区上换字、不走
// didChangeText，靠选区变化排的那次兜底收尾）。每一步之后：编辑器里的属性和「同一份正文整篇重排一遍」逐字比（字号 / 粗细 / 等宽、藏露、
// 链接、引用、划线、下划线、斜、底、段落样式的行高 / 段前段后 / 缩进 / Tab、代码块的角色、主字体、基线偏移、按浅色外观
// 解析出来的字色），藏着的字的字形真的是零宽的控制字符，交出去的全文（onChange；外面换进来的算外面那份）和看得见的一样。
// 用法（没设就跳过，不算进默认的全量；步数按每段 250 步分给几个固定的种子，同样的步数每次跑的一样；2 万步 Debug 约 25 s）：
//   TEST_RUNNER_KITTY_NOTES_FUZZ=20000 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools test \
//     -only-testing:'KittyToolsTests/NoteEditorFuzzTests/randomEditsMatchWholeText()'
// 另可设 TEST_RUNNER_KITTY_NOTES_FUZZ_SEED=<起始种子>（默认 1）换一批种子。改了排法（NoteStyles.apply、
// NoteTextView.restyleEdited / syncMarkers、roleChanges、neighborLines，或加跨行的语法）先跑它：报差异的话前几处
// 写在失败信息里（种子、第几步、做了什么、哪个字、两边的签名、全文）。
// 窗口摆在离所有屏幕很远的地方、不当 key（「窗口是 key」直接告诉编辑器：keyChanged）；不发任何合成的鼠标键盘事件
// （按键事件对象直接交给窗口的 performKeyEquivalent）；剪贴板是自己建的、用完放掉；偏好、便签库都不碰。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

nonisolated private let fuzzSteps = ProcessInfo.processInfo.environment["KITTY_NOTES_FUZZ"]
  .flatMap { Int($0) }
nonisolated private let fuzzSeed =
  ProcessInfo.processInfo.environment["KITTY_NOTES_FUZZ_SEED"].flatMap { Int($0) } ?? 1

struct NoteEditorFuzzTests {
  /// 撤销栈由窗口给（同 NoteTextViewTests）；按步分组
  private final class Host: NSWindow {
    let notes = UndoManager()
    override var undoManager: UndoManager? { notes }
  }

  /// 种子定下来的伪随机数（不用系统的：同一个种子每次一样）
  private struct LCG {
    var state: UInt64
    mutating func next() -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(state >> 33)
    }
    mutating func pick<T>(_ items: [T]) -> T { items[next() % items.count] }
    mutating func chance(_ one: Int) -> Bool { next() % one == 0 }
  }

  /// 每段打字的随机片段：标记、围栏、换行（连软换行、\r\n）、表情、Tab
  private static let snippets = [
    "a", "字", "*", "**", "_", "__", "`", "[", "]", "](u)", "](https://a.b)", "#", "# ", "> ", ">",
    "- ", "☐ ", "☑ ", " ", " ", "\n", "\n", "~~", "\\", "!", "\u{2028}", "\r\n", "1. ", "🙂", "(",
    ")", "x_y", "\t", "```", "```", "```js", "~~~", "````", "\n```\n", "\n```", "```\n", "``", "~",
    "\n> ", "2*3*4", "\n```\n块里 **不粗**\n```\n", "\n~~~py\n# 注释\n☐ 不是任务\n~~~\n", "\n```\n```\n",
  ]
  private static let pastes = [
    "https://example.com/a", " https://a.b \n", "https://a.b https://c.d", "mailto:x@y.z", "纯文字",
    "file:///etc", "https://a.b/(x)", "https://a.b/)", "多行\n粘贴",
  ]
  private static let start =
    "# 标题 **粗**\n普通 *斜* `码`\n> 引用 [链](https://a.b)\n> 第二行\n- 列表 ~~删~~\n```swift\nlet a = **1**\n# 不是标题\n```\n☐ 任务 **粗**\n☑ 做完 _斜_\n~~~\n☐ 块里\n"

  /// 一段字的属性写成一串（颜色是动态色、不同的对象不相等：按浅色外观解析出来比）
  private static func signature(_ attributes: [NSAttributedString.Key: Any]) -> String {
    let font = attributes[.font] as? NSFont
    let traits = font?.fontDescriptor.symbolicTraits ?? []
    let style = attributes[.paragraphStyle] as? NSParagraphStyle
    let line = attributes[NoteStyles.lineFontKey] as? NSFont
    let lineTraits = line?.fontDescriptor.symbolicTraits ?? []
    var color = "-"
    if let ink = attributes[.foregroundColor] as? NSColor, let aqua = NSAppearance(named: .aqua) {
      aqua.performAsCurrentDrawingAppearance {
        color =
          ink.usingColorSpace(.sRGB).map {
            String(
              format: "%.3f,%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent,
              $0.alphaComponent)
          } ?? "?"
      }
    }
    let flags: [(NSAttributedString.Key, String)] = [
      (NoteStyles.hiddenKey, "H"), (NoteStyles.shownKey, "S"), (NoteStyles.quoteKey, "Q"),
      (.strikethroughStyle, "x"), (.underlineStyle, "u"), (.obliqueness, "i"),
      (.backgroundColor, "bg"),
    ]
    return [
      "f\(font?.pointSize ?? 0)\(traits.contains(.bold) ? "b" : "")\(traits.contains(.monoSpace) ? "m" : "")\(font?.fontName == "AppleSymbols" ? "sym" : "")",
      flags.map { attributes[$0.0] != nil ? $0.1 : "" }.joined(),
      (attributes[NoteStyles.linkKey] as? URL)?.absoluteString ?? "",
      "p\(style?.minimumLineHeight ?? -1)/\(style?.maximumLineHeight ?? -1)/\(style?.paragraphSpacingBefore ?? -1)/\(style?.paragraphSpacing ?? -1)/\(style?.headIndent ?? -1)/\(style?.firstLineHeadIndent ?? -1)/\(style?.tailIndent ?? -1)/\(style?.defaultTabInterval ?? -1)",
      "r\((attributes[NoteStyles.roleKey] as? Int) ?? 0)",
      "L\(line?.pointSize ?? 0)\(lineTraits.contains(.bold) ? "b" : "")\(lineTraits.contains(.monoSpace) ? "m" : "")",
      "o\((attributes[.baselineOffset] as? CGFloat) ?? 0)", "c" + color,
    ].joined(separator: "|")
  }

  /// 一份文本存储写成一段段「签名 × 几个字」（挨着的签名一样的并成一段）：逐字比，但每段属性只算一次签名
  private static func runs(_ storage: NSAttributedString) -> [(signature: String, length: Int)] {
    var runs: [(signature: String, length: Int)] = []
    var location = 0
    while location < storage.length {
      var range = NSRange()
      let signature = Self.signature(storage.attributes(at: location, effectiveRange: &range))
      if runs.last?.signature == signature {
        runs[runs.count - 1].length += range.length
      } else {
        runs.append((signature, range.length))
      }
      location = NSMaxRange(range)
    }
    return runs
  }

  /// 屏外窗口里的一个编辑器，连它往外报的东西和「现在的设置」
  private final class Rig {
    let window: Host
    let scroll = NSScrollView()
    let editor = NoteTextView.make()
    /// 外面那份正文：交出去的（onChange）或外面换进来的（setText）
    var stored: String
    var paper = 0
    var fontSize: CGFloat = 15
    var markdown = true
    var spacing = NoteStyles.Spacing.standard
    var key = false

    init(_ body: String, pasteboard: NSPasteboard) throws {
      let frame = CGRect(x: -30000, y: -30000, width: 420, height: 320)
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
      window = Host(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      // 一步一组（测试是同步跑的：不关的话所有改动都落在同一个事件的组里）
      window.notes.groupsByEvent = false
      stored = body
      editor.identifier = NSUserInterfaceItemIdentifier("便签甲")
      editor.textContainerInset = NSSize(width: 9, height: 6)
      editor.onChange = { [unowned self] in stored = $0 }
      editor.onOpenLink = { _ in }
      editor.pasteboard = pasteboard
      scroll.hasVerticalScroller = true
      scroll.documentView = editor
      window.contentView = scroll
      applyPaper()
      editor.setText(body)
      window.makeFirstResponder(editor)
    }

    func applyPaper() {
      editor.setPaper(
        NotePaper.all[paper], fontSize: fontSize, markdown: markdown, spacing: spacing)
    }

    var storage: NSTextStorage { editor.textStorage ?? NSTextStorage() }
    var length: Int { storage.length }

    func compose(_ text: String) {
      editor.setMarkedText(
        text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func type(_ text: String) {
      editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 四个加标记的键之一的按键事件（只是事件对象，直接交给窗口；不发出去）
    func formatKey(_ wrap: NoteMarkdown.Wrap) -> NSEvent? {
      let codes: [NoteMarkdown.Wrap: Int] = [
        .bold: kVK_ANSI_B, .italic: kVK_ANSI_I, .strike: kVK_ANSI_X, .code: kVK_ANSI_E,
      ]
      return NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: wrap.modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: wrap.key,
        charactersIgnoringModifiers: wrap == .strike ? wrap.key.uppercased() : wrap.key,
        isARepeat: false, keyCode: UInt16(codes[wrap] ?? 0))
    }

    /// 转一轮事件循环（晚一拍的排标记、兜底的那次收尾在这时跑）
    func spin() { RunLoop.main.run(mode: .default, before: Date()) }

    /// 编辑器现在和「同一份正文整篇重排一遍」差在哪（逐字比属性、比字形藏没藏、比交出去的全文）；一样给 nil
    func mismatch() -> String? {
      guard !editor.hasMarkedText() else { return nil }
      let text = storage.mutableString
      let focused = window.firstResponder === editor
      let shown =
        markdown && focused && key && editor.isEditable
        ? editor.selectedRanges.map { text.lineRange(for: $0.rangeValue) } : []
      let expected = NSTextStorage(string: editor.string)
      NoteStyles.apply(
        to: expected, lines: NSRange(location: 0, length: expected.length),
        theme: NoteStyles.Theme(
          paper: NotePaper.all[paper], fontSize: fontSize, markdown: markdown, spacing: spacing),
        shown: shown, blocks: markdown ? NoteMarkdown.codeBlocks(in: expected.mutableString) : [])
      let (got, want) = (NoteEditorFuzzTests.runs(storage), NoteEditorFuzzTests.runs(expected))
      if got.map(\.signature) != want.map(\.signature) || got.map(\.length) != want.map(\.length) {
        // 第一处不一样的字
        var index = 0
        for (a, b) in zip(got, want) {
          if a.signature != b.signature {
            return describe(index, a.signature, b.signature)
          }
          if a.length != b.length {
            index += min(a.length, b.length)
            let after = { (runs: [(signature: String, length: Int)]) in
              Self.signature(at: index, in: runs)
            }
            return describe(index, after(got), after(want))
          }
          index += a.length
        }
        return "长度不一样：\(storage.length) ≠ \(expected.length)"
      }
      // 藏着的字的字形真的是零宽的控制字符（换行、Tab 这些真的控制字符不看）
      guard let manager = editor.layoutManager, let container = editor.textContainer else {
        return "没有布局管理器"
      }
      manager.ensureLayout(for: container)
      for index in 0..<storage.length {
        let unit = text.character(at: index)
        guard unit >= 0x20, unit != 0x2028, unit != 0x85, unit != 0x7F, unit != 0x2029 else {
          continue
        }
        let glyph = manager.glyphIndexForCharacter(at: index)
        guard manager.characterIndexForGlyph(at: glyph) == index else { continue }
        let isControl = manager.propertyForGlyph(at: glyph).contains(.controlCharacter)
        let isHidden =
          storage.attribute(NoteStyles.hiddenKey, at: index, effectiveRange: nil) != nil
        if isControl != isHidden {
          return
            "第 \(index) 个字的字形：藏着 \(isHidden)、控制字符 \(isControl)；全文 \(editor.string.debugDescription)"
        }
      }
      if stored != editor.string {
        return
          "交出去的全文和看得见的不一样：\(stored.debugDescription) ≠ \(editor.string.debugDescription)；"
          + "选区 \(editor.selectedRanges.map(\.rangeValue)) 焦点 \(window.firstResponder === editor) key \(key)"
      }
      return nil
    }

    private static func signature(
      at index: Int, in runs: [(signature: String, length: Int)]
    ) -> String {
      var location = 0
      for run in runs {
        if index < location + run.length { return run.signature }
        location += run.length
      }
      return "（没有）"
    }

    private func describe(_ index: Int, _ got: String, _ want: String) -> String {
      let text = storage.mutableString
      let line = text.lineRange(for: NSRange(location: index, length: 0))
      return """
        第 \(index) 个字 \(text.substring(with: NSRange(location: index, length: 1)).debugDescription) \
        在 \(text.substring(with: line).debugDescription) 里
            编辑器 \(got)
            整篇排 \(want)
            选区 \(editor.selectedRanges.map(\.rangeValue)) markdown \(markdown) 纸 \(paper) 字号 \(fontSize) \
        行距 \(spacing) 焦点 \(window.firstResponder === editor) key \(key)
            全文 \(editor.string.debugDescription)
        """
    }
  }

  /// 每个种子跑这么多步
  private static let stepsPerSeed = 250

  @Test(.enabled(if: fuzzSteps != nil)) func randomEditsMatchWholeText() throws {
    let total = max(fuzzSteps ?? 0, 1)
    let board = NSPasteboard(name: NSPasteboard.Name("kitty-notes-fuzz-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    var failures: [String] = []
    var (steps, withBlocks, formatted, linked, settledLeftovers) = (0, 0, 0, 0, 0)
    var seed = fuzzSeed
    while steps < total {
      var random = LCG(state: UInt64(seed) &* 7919)
      let rig = try Rig(Self.start, pasteboard: board)
      for step in 0..<min(Self.stepsPerSeed, total - steps) {
        let what = try Self.act(on: rig, &random, formatted: &formatted, linked: &linked)
        var done = what
        if random.chance(9), rig.window.notes.canUndo, !rig.editor.hasMarkedText() {
          done += " + 撤销"
          rig.window.notes.undo()
        } else if random.chance(15), rig.window.notes.canRedo, !rig.editor.hasMarkedText() {
          done += " + 重做"
          rig.window.notes.redo()
        }
        if random.chance(2) { rig.spin() }
        // 直接改了文本存储：等兜底的那次收尾（下一轮）跑完再比
        if what.hasPrefix("直接改存储") {
          for _ in 0..<100 where rig.stored != rig.editor.string {
            RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
          }
          settledLeftovers += 1
        }
        steps += 1
        if rig.markdown, !NoteMarkdown.codeBlocks(in: rig.storage.mutableString).isEmpty {
          withBlocks += 1
        }
        if let problem = rig.mismatch() {
          failures.append("种子 \(seed) 第 \(step) 步，\(done) 之后：\(problem)")
          // 这个种子后面的步都踩在错的状态上：换下一个种子
          break
        }
      }
      rig.editor.removeFromSuperview()
      seed += 1
    }
    print(
      "便签正文随机探针：\(steps) 步、\(seed - fuzzSeed) 个种子，差异 \(failures.count) 处；有代码块的步 \(withBlocks)、"
        + "改了字的加标记 \(formatted)、粘成链接 \(linked)、直接改存储 \(settledLeftovers)")
    #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n\n"))")
  }

  /// 随机做一件事，返回做了什么（写进失败信息）
  private static func act(
    on rig: Rig, _ random: inout LCG, formatted: inout Int, linked: inout Int
  ) throws -> String {
    let editor = rig.editor
    let length = rig.length
    let position = { (random: inout LCG) in length == 0 ? 0 : random.next() % (length + 1) }
    rig.window.notes.beginUndoGrouping()
    defer { rig.window.notes.endUndoGrouping() }
    switch random.next() % 32 {
    case 0, 1, 2:
      let at = position(&random)
      editor.setSelectedRange(NSRange(location: at, length: 0))
      return "光标 \(at)"
    case 3:
      let (a, b) = (position(&random), position(&random))
      editor.setSelectedRange(NSRange(location: min(a, b), length: abs(a - b)))
      return "选 \(min(a, b))..<\(max(a, b))"
    case 4:
      // 多段选区（⌘ 拖出来的那种）：从前到后、不相交
      let cuts = (0..<4).map { _ in position(&random) }.sorted()
      let ranges = [
        NSRange(location: cuts[0], length: cuts[1] - cuts[0]),
        NSRange(location: cuts[2], length: cuts[3] - cuts[2]),
      ]
      editor.setSelectedRanges(
        ranges.map(NSValue.init(range:)), affinity: .downstream, stillSelecting: false)
      return "多段选区 \(editor.selectedRanges.map(\.rangeValue))"
    case 5:
      // 拖选：拖的过程中（stillSelecting）不排标记，松手那一次才排
      let (a, b) = (position(&random), position(&random))
      let range = NSRange(location: min(a, b), length: abs(a - b))
      editor.setSelectedRanges(
        [NSValue(range: NSRange(location: range.location, length: 0))], affinity: .downstream,
        stillSelecting: true)
      editor.setSelectedRanges(
        [NSValue(range: range)], affinity: .downstream, stillSelecting: true)
      editor.setSelectedRanges(
        [NSValue(range: range)], affinity: .downstream, stillSelecting: false)
      return "拖选 \(range)"
    case 6, 7, 8, 9, 10, 11:
      let snippet = random.pick(snippets)
      rig.type(snippet)
      return "打 \(snippet.debugDescription)"
    case 12, 13:
      editor.deleteBackward(nil)
      return "⌫"
    case 14:
      editor.deleteForward(nil)
      return "⌦"
    case 15:
      let soft = random.chance(4)
      editor.doCommand(
        by: soft
          ? #selector(NSResponder.insertLineBreak(_:)) : #selector(NSResponder.insertNewline(_:)))
      return soft ? "⌃↩" : "↩"
    case 16:
      let back = random.chance(3)
      editor.doCommand(
        by: back ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:)))
      return back ? "⇧Tab" : "Tab"
    case 17:
      rig.key.toggle()
      editor.keyChanged(rig.key)
      return "key \(rig.key)"
    case 18:
      let focus = rig.window.firstResponder !== editor
      _ = rig.window.makeFirstResponder(focus ? editor : nil)
      return "焦点 \(focus)"
    case 19, 20:
      // 输入法：组字（中途可能换纸色 / 字号、换 key、按加标记的键——都不许动属性、不许改字），再确认 / 撤掉 / unmarkText
      rig.compose(random.pick(["pin", "y", "zhong"]))
      if random.chance(2) { rig.compose("pinyin") }
      if random.chance(3) {
        editor.keyChanged(!rig.key)
        editor.keyChanged(rig.key)
      }
      if random.chance(4) {
        rig.fontSize = random.pick([13, 15, 17, 20])
        rig.spacing = random.pick(NoteStyles.Spacing.allCases)
        rig.applyPaper()
      }
      if random.chance(4) {
        let wrap = random.pick(NoteMarkdown.Wrap.allCases)
        if let event = rig.formatKey(wrap) { _ = rig.window.performKeyEquivalent(with: event) }
        editor.format(wrap)
      }
      switch random.next() % 3 {
      case 0:
        let commit = random.pick(["拼", "**", "中文\n", "`", "```", "# "])
        rig.type(commit)
        return "组字后确认 \(commit.debugDescription)"
      case 1:
        editor.unmarkText()
        return "组字后 unmarkText"
      default:
        rig.compose("")
        return "组字后撤掉"
      }
    case 21:
      editor.toggleTask()
      return "⌘T"
    case 22, 23:
      let wrap = random.pick(NoteMarkdown.Wrap.allCases)
      let before = editor.string
      if random.chance(2), let event = rig.formatKey(wrap) {
        _ = rig.window.performKeyEquivalent(with: event)
      } else {
        editor.format(wrap)
      }
      if editor.string != before { formatted += 1 }
      return "加标记 \(wrap)"
    case 24:
      let content = random.pick(pastes)
      if !random.chance(3) {
        // 先在光标那一行里选一段
        let line = rig.storage.mutableString.lineRange(
          for: NSRange(location: min(editor.selectedRange().location, length), length: 0))
        let a = line.location + random.next() % max(line.length, 1)
        let b = line.location + random.next() % max(line.length, 1)
        editor.setSelectedRange(NSRange(location: min(a, b), length: abs(a - b)))
      }
      editor.pasteboard.clearContents()
      editor.pasteboard.setString(content, forType: .string)
      let before = editor.string
      editor.paste(nil)
      if editor.string.contains("](" + content), !before.contains("](" + content) { linked += 1 }
      return "粘贴 \(content.debugDescription)"
    case 25:
      // 换纸色 / 字号 / 行距 / Markdown 开关（整篇重排）
      switch random.next() % 4 {
      case 0: rig.paper = random.next() % NotePaper.all.count
      case 1: rig.fontSize = random.pick([13, 15, 17, 20])
      case 2: rig.spacing = random.pick(NoteStyles.Spacing.allCases)
      default: rig.markdown.toggle()
      }
      rig.applyPaper()
      return "设置 纸 \(rig.paper) 字号 \(rig.fontSize) 行距 \(rig.spacing) markdown \(rig.markdown)"
    case 26:
      if random.chance(2) {
        editor.selectAll(nil)
        return "全选"
      }
      if random.chance(2) { editor.moveDown(nil) } else { editor.moveUp(nil) }
      return "↑↓"
    case 27:
      // 外面换了正文（别处改了这条便签）：随机插一段、删一段
      let text = NSMutableString(string: editor.string)
      // 整个字（不把表情的代理对拆开）
      let at = position(&random)
      let character = at < text.length ? text.rangeOfComposedCharacterSequence(at: at) : nil
      if random.chance(2), let character {
        text.deleteCharacters(in: character)
      } else {
        text.insert(random.pick(snippets), at: character?.location ?? at)
      }
      let replaced = text as String
      outsideUndoGroup(rig) { editor.setText(replaced) }
      if editor.string == replaced { rig.stored = replaced }
      return "外面换了正文"
    case 28:
      // 直接改文本存储（不走 shouldChangeText / didChangeText）：兜底要接的那种路——真输入法改了光标处的字却不报
      // didChangeText——在选区上换字，系统随后报一次选区变化，兜底排的那次收尾（下一轮）收掉。改在光标后面的话系统
      // 不一定报选区（实测），兜底不管那种，这里不做
      let selection = editor.selectedRange()
      // 空的只在有选区时用（就是删掉选中的字）：没选区时换成空的什么都没改
      let snippet = random.pick(["`码`", "**", "x", "```\n", "> ", selection.length > 0 ? "" : "y"])
      rig.storage.replaceCharacters(in: selection, with: snippet)
      // 撤销栈里记的位置对不上了（这一下没登记）：清掉，免得之后的撤销按旧位置改字
      outsideUndoGroup(rig) { rig.window.notes.removeAllActions() }
      return "直接改存储 把 \(selection) 换成 \(snippet.debugDescription)"
    case 29, 30:
      // 围栏行：在某一行的行首加一行围栏，或者改 / 删一行现有的
      let text = rig.storage.mutableString
      var fences: [NSRange] = []
      var location = 0
      while location < text.length {
        var (start, end, contentsEnd) = (0, 0, 0)
        text.getLineStart(
          &start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        if NoteMarkdown.fence(count: contentsEnd - start, at: { text.character(at: start + $0) })
          != nil
        {
          fences.append(NSRange(location: start, length: end - start))
        }
        location = max(end, location + 1)
      }
      if let fence = fences.isEmpty || random.chance(2) ? nil : random.pick(fences) {
        switch random.next() % 3 {
        case 0:
          editor.setSelectedRange(fence)
          editor.deleteBackward(nil)
          return "删一行围栏 \(fence)"
        case 1:
          editor.setSelectedRange(NSRange(location: fence.location, length: 0))
          rig.type(random.pick(["`", "~", " "]))
          return "改围栏（行首加一个字） \(fence)"
        default:
          editor.setSelectedRange(NSRange(location: fence.location, length: 1))
          editor.deleteBackward(nil)
          return "改围栏（删行首一个字） \(fence)"
        }
      }
      let start = text.lineRange(for: NSRange(location: position(&random), length: 0)).location
      let fence = random.pick(["```\n", "```swift\n", "~~~\n", "````\n", "~~~py\n"])
      editor.setSelectedRange(NSRange(location: start, length: 0))
      rig.type(fence)
      return "加一行围栏 \(fence.debugDescription) 在 \(start)"
    default:
      return "什么都不做"
    }
  }

  /// 不在撤销分组里做 body（换正文会清撤销栈：在开着的分组里清，之后那次 endUndoGrouping 就对不上了）
  private static func outsideUndoGroup(_ rig: Rig, _ body: () -> Void) {
    rig.window.notes.endUndoGrouping()
    defer { rig.window.notes.beginUndoGrouping() }
    body()
  }
}
