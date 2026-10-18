// 便签正文编辑器（Notes/NoteTextView.swift）的随机操作探针，按需跑（PLAN §10「便签」手测反馈第 4 批评审后那一轮：
// 原来是 macos/build/ 下的小程序，build 不进仓库，改成按环境变量开的单测）。屏外窗口里一个真的 NoteTextView，
// 随机做：放光标、选一段、多段选区、拖选（stillSelecting）、打字（带标记、围栏、软换行、\r\n、表情）、删、回车 / ⌃↩、
// Tab / ⇧Tab、⌘T、四个加标记的键（按键事件交给窗口 / 直接调 format）、粘贴（网址成链接、照常粘贴）、围栏行的增删改、
// 撤销 / 重做、输入法组字后确认 / 撤掉 / unmarkText（组字期间换纸色、换 key、按加标记的键）、换纸色 / 字号 / 行距 /
// Markdown 开关、拿 / 丢焦点、窗口当上 / 不再是 key、外面换了正文（setText）、直接改文本存储（在选区上换字、不走
// didChangeText，靠选区变化排的那次兜底收尾）。
// 第 7 批行内图片：插图（自己的插入入口）、贴一段带令牌的字（自家类型）、复制一段再贴回来、选中图 / 图前面 / 图后面
// 打字、⌫ / ⌦、改宽度、图片前后组字、外面换进来的正文里带令牌。图片是测试现画的（临时目录里一个真文件），
// 比对时除了属性和字形，还比附件的编号和宽度、图片行的高（imageLineKey），附件字符上不许有 hiddenKey。单数的种子把「整段换字时当场排多少」改得很小（手测反馈第 6 批：整段换字
// 只当场排开头一屏、其余的在后面几轮补，NoteTextView.styleRest）：外面换了正文之后一大半是没排过的行，接着打字、
// 撤销、组字都踩在「还没补完」上；这时只比排过的行（没排过的得是整行都没排），每个种子跑完把剩下的补完再整篇比一次。每一步之后：编辑器里的属性和「同一份正文整篇重排一遍」逐字比（字号 / 粗细 / 等宽、藏露、
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
import UniformTypeIdentifiers

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
    "[x]{red}", "[字]{blue}", "]{orange}", "[", "[a]{purple}", "◧ ", "▣ ", "☒ ",
  ]
  private static let pastes = [
    "https://example.com/a", " https://a.b \n", "https://a.b https://c.d", "mailto:x@y.z", "纯文字",
    "file:///etc", "https://a.b/(x)", "https://a.b/)", "多行\n粘贴",
  ]
  private static let start =
    "# 标题 **粗**\n普通 *斜* `码`\n{图}\n> 引用 [链](https://a.b)\n> 第二行\n- 列表 ~~删~~\n```swift\nlet a = **1**\n# 不是标题\n```\n☐ 任务 **粗**\n◧ 进行中\n▣ 紧急\n☑ 做完 _斜_\n☒ 取消\n[红]{red} 普通\n~~~\n☐ 块里\n"
    + "前面{图}后面\n末行"

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
      "o\((attributes[.baselineOffset] as? CGFloat) ?? 0)",
      "k\((attributes[.kern] as? CGFloat) ?? 0)",
      "i\((attributes[NoteStyles.colorKey] as? Int) ?? -1)", "c" + color,
      "a"
        + ((attributes[.attachment] as? NoteImageAttachment).map {
          "\($0.picture.id.uuidString.prefix(4)).\($0.picture.width.map(String.init) ?? "-")"
        } ?? "-"),
      "M\((attributes[NoteStyles.imageLineKey] as? CGFloat) ?? -1)",
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
    /// 图片目录（临时目录里几个真文件）和可以插的几张图
    let directory: URL
    let store: NoteImageStore
    let images: [NoteImages.Image]
    var paper = 0
    var fontSize: CGFloat = 15
    var markdown = true
    var spacing = NoteStyles.Spacing.standard
    var key = false

    init(_ rawBody: String, pasteboard: NSPasteboard, eager: Int? = nil) throws {
      directory = FileManager.default.temporaryDirectory.appending(
        path: "kitty-notes-fuzz-images-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      store = NoteImageStore(directory: directory)
      var created: [NoteImages.Image] = []
      for (index, side) in [(140, 70), (240, 180), (90, 120), (600, 300)].enumerated() {
        let id = UUID()
        let ext = index % 2 == 0 ? "png" : "jpg"
        let type: UTType = ext == "png" ? .png : .jpeg
        let data = NoteImageFixture.data(type: type, width: side.0, height: side.1)
        let url = directory.appending(path: "\(id.uuidString).\(ext)")
        try data.write(to: url)
        let size = try #require(NoteImageStore.readSize(at: url))
        let image = NoteImages.Image(id: id, ext: ext, width: nil)
        store.remember(NoteImageStore.Stored(image: image, size: size))
        created.append(image)
      }
      images = created
      // 正文里的 {图} 换成第一张图的令牌（每段种子都从「正文里有图」开始）
      let body = rawBody.replacingOccurrences(
        of: "{图}", with: NoteImages.token(created[0]))
      let frame = CGRect(x: -30000, y: -30000, width: 420, height: 320)
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
      window = Host(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      // 一步一组（测试是同步跑的：不关的话所有改动都落在同一个事件的组里）
      window.notes.groupsByEvent = false
      stored = body
      editor.identifier = NSUserInterfaceItemIdentifier("便签甲")
      editor.imageStore = store
      editor.textContainerInset = NSSize(width: 9, height: 6)
      editor.onChange = { [unowned self] in stored = $0 }
      editor.onOpenLink = { _ in }
      editor.pasteboard = pasteboard
      if let eager {
        editor.eagerStyleLength = eager
        editor.restChunk = eager + 9
      }
      scroll.hasVerticalScroller = true
      scroll.documentView = editor
      window.contentView = scroll
      applyPaper()
      editor.setText(body)
      window.makeFirstResponder(editor)
    }

    func applyPaper() {
      editor.setPaper(
        NotePaper.all[paper], fontSize: fontSize, markdown: markdown, spacing: spacing,
        paperIndex: paper)
    }

    /// 编辑器里那份转回存的形式（图片是令牌）
    var editorStored: String { NoteImageAttachment.stored(from: storage) }

    /// 正文里图片的位置（换宽度、选中要按它）
    var imageIndexes: [Int] {
      var found: [Int] = []
      storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
        value, range, _ in
        if value is NoteImageAttachment { found.append(range.location) }
      }
      return found
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

    /// 第 index 个字的正中（窗口坐标）
    func center(of index: Int) throws -> NSPoint {
      scroll.layoutSubtreeIfNeeded()
      if let container = editor.textContainer {
        editor.layoutManager?.ensureLayout(for: container)
      }
      let manager = try #require(editor.layoutManager)
      let container = try #require(editor.textContainer)
      let glyphs = manager.glyphRange(
        forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
      let origin = editor.textContainerOrigin
      return editor.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), to: nil)
    }

    /// 编辑器现在和「同一份正文整篇重排一遍」差在哪（逐字比属性、比字形藏没藏、比交出去的全文）；一样给 nil
    func mismatch() -> String? {
      guard !editor.hasMarkedText() else { return nil }
      let text = storage.mutableString
      let focused = window.firstResponder === editor
      // 颜色不看 Markdown 开关（第 8 批）：关着时这一行的颜色标记也要露出来，参照那边同样
      let shown =
        focused && key && editor.isEditable
        ? editor.selectedRanges.map { text.lineRange(for: $0.rangeValue) } : []
      // 「同一份正文整篇重排一遍」的参照：**照编辑器里现在这一份**（同样的字、同样的附件）copy 一份，再整篇 apply。
      // 不按存的形式重新认一遍令牌：编辑器里可能本来就有**字面上的令牌**（粘贴的纯文字、或者编辑把一段令牌
      // 改成了合法的写法），那不是附件，参照里也不该把它变成图（apply 会把样式属性整行铺回去，只有 .attachment 留着）
      let expected = NSTextStorage(attributedString: storage)
      NoteStyles.apply(
        to: expected, lines: NSRange(location: 0, length: expected.length),
        theme: NoteStyles.Theme(
          paper: NotePaper.all[paper], fontSize: fontSize, markdown: markdown, spacing: spacing),
        shown: shown, blocks: markdown ? NoteMarkdown.codeBlocks(in: expected.mutableString) : [],
        availableWidth: editor.availableWidth)
      // 整段换字之后还没补完样式的行（没记主字体的）：只比排过的行——没排过的那几行拿整篇排出来的顶上去比；
      // 没排过的得是整行都没排（不许排了半行）
      let compared = NSMutableAttributedString(attributedString: storage)
      if editor.isStylingRest {
        var location = 0
        while location < text.length {
          let line = text.lineRange(for: NSRange(location: location, length: 0))
          var styled = 0
          storage.enumerateAttribute(NoteStyles.lineFontKey, in: line) { value, range, _ in
            if value != nil { styled += range.length }
          }
          if styled == 0 {
            expected.enumerateAttributes(in: line) { attributes, range, _ in
              compared.setAttributes(attributes, range: range)
            }
          } else if styled != line.length {
            return "第 \(line.location) 个字起的那一行只排了一半；全文 \(editor.string.debugDescription)"
          }
          location = NSMaxRange(line)
        }
      }
      let (got, want) = (NoteEditorFuzzTests.runs(compared), NoteEditorFuzzTests.runs(expected))
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
        // 附件字符：不许藏着（藏着就变成零宽的、图看不见）。没挂附件的 U+FFFC（外面换进来的裸占位）不是我们
        // 产生的，字形这一遍跳过——挂没挂附件由签名里的 a 那一段比出来
        if unit == 0xFFFC {
          if isHidden {
            return "第 \(index) 个字是附件字符却带着 hiddenKey；全文 \(editor.string.debugDescription)"
          }
          continue
        }
        if isControl != isHidden {
          return
            "第 \(index) 个字的字形：藏着 \(isHidden)、控制字符 \(isControl)；全文 \(editor.string.debugDescription)"
        }
      }
      // 交出去的（存的形式）和编辑器里现在这份（转回存的形式）要一样（图片是令牌对令牌，不是 U+FFFC 对令牌）
      let now = editorStored
      if stored != now {
        return
          "交出去的全文和编辑器里那份不一样：\(stored.debugDescription) ≠ \(now.debugDescription)；"
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
            附件 \(imageIndexes.count) 个、编辑器文本里认得出的令牌 \(NoteImages.matches(in: editor.string as NSString).count) 段，\
        交出去的里 \(NoteImages.matches(in: stored as NSString).count) 段
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
    var (partial, drained) = (0, 0)
    var seed = fuzzSeed
    // 每一步、每个种子各包一层 autoreleasepool：测试函数是一口气同步跑完的，中间没有事件循环替它清自动释放池，
    // 每一步整篇重排的参照（文本存储、排版）、组字和粘贴留下的对象都攒着——起始种子 3001 跑 4 万步涨到 6 GB 多、
    // 在换页里爬（第 7 批评审后那一轮记的）。真的 App 里每个事件之后系统都会清，不是编辑器的泄漏
    while steps < total {
      try autoreleasepool {
        var random = LCG(state: UInt64(seed) &* 7919)
        let began = Date.now
        let rig = try Rig(Self.start, pasteboard: board, eager: seed % 2 == 1 ? 24 : nil)
        for step in 0..<min(Self.stepsPerSeed, total - steps) {
          let (done, problem) = try autoreleasepool { () throws -> (String, String?) in
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
              for _ in 0..<100 where rig.stored != rig.editorStored {
                RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
              }
              settledLeftovers += 1
            }
            steps += 1
            if rig.markdown, !NoteMarkdown.codeBlocks(in: rig.storage.mutableString).isEmpty {
              withBlocks += 1
            }
            if rig.editor.isStylingRest { partial += 1 }
            return (done, rig.mismatch())
          }
          if let problem {
            failures.append("种子 \(seed) 第 \(step) 步，\(done) 之后：\(problem)")
            // 这个种子后面的步都踩在错的状态上：换下一个种子
            break
          }
        }
        // 没补完的样式补完（组字中的先确认掉），再整篇比一次
        if rig.editor.hasMarkedText() { rig.editor.unmarkText() }
        for _ in 0..<400 where rig.editor.isStylingRest {
          RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
        }
        if rig.editor.isStylingRest {
          failures.append("种子 \(seed)：跑完之后还有没补上的样式")
        } else if let problem = rig.mismatch() {
          failures.append("种子 \(seed) 补完样式之后：\(problem)")
        }
        drained += 1
        // 慢的种子说一声（哪一段、正文多长）：一段跑到几分钟多半是正文被复制粘贴翻倍翻得太长了
        let spent = Date.now.timeIntervalSince(began)
        if spent > 5 {
          print("便签正文随机探针：种子 \(seed) 用了 \(Int(spent)) s，正文 \(rig.storage.length) 个字")
        }
        rig.editor.removeFromSuperview()
        seed += 1
      }
    }
    print(
      "便签正文随机探针：\(steps) 步、\(seed - fuzzSeed) 个种子，差异 \(failures.count) 处；有代码块的步 \(withBlocks)、"
        + "改了字的加标记 \(formatted)、粘成链接 \(linked)、直接改存储 \(settledLeftovers)、"
        + "还有没补完样式的步 \(partial)、补完再比的种子 \(drained)")
    #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n\n"))")
  }

  /// 随机做一件事，返回做了什么（写进失败信息）
  private static func act(
    on rig: Rig, _ random: inout LCG, formatted: inout Int, linked: inout Int
  ) throws -> String {
    let editor = rig.editor
    let length = rig.length
    let text = rig.storage.mutableString
    // 位置只落在整字的边上（同真的界面：点击、方向键都不会把光标停在一个表情的两半中间）。停在中间的话 ⌫ 会删掉
    // 半个表情、留下落单的代理项——而 TextKit 1 排「要折到下一行的附件 + 后面落单的低位代理项」时死循环（复查时
    // 起始种子 3001 那一批卡死在种子 3037 第 51 步，独立小程序复现：macos/build/research/notes-images-proto/
    // lone-surrogate-loop.swift，系统自带的附件 cell 也一样）。存的正文是 Swift 的 String，读进来不会有落单的代理项
    let position = { (random: inout LCG) -> Int in
      guard length > 0 else { return 0 }
      let raw = random.next() % (length + 1)
      return raw < text.length ? text.rangeOfComposedCharacterSequence(at: raw).location : raw
    }
    rig.window.notes.beginUndoGrouping()
    defer { rig.window.notes.endUndoGrouping() }
    switch random.next() % 41 {
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
      let indexes = rig.imageIndexes
      if !indexes.isEmpty, random.chance(2) {
        let index = random.pick(indexes)
        editor.setSelectedRange(NSRange(location: index + (random.chance(2) ? 0 : 1), length: 0))
      }
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
      // 外面换了正文（别处改了这条便签）：随机插一段、删一段。**从存的形式起**（外面那份正文里图片是令牌，
      // 不是编辑器里的附件字符）
      let text = NSMutableString(string: rig.editorStored)
      // 整个字（不把表情的代理对拆开）
      let at = position(&random)
      let character = at < text.length ? text.rangeOfComposedCharacterSequence(at: at) : nil
      if random.chance(2), let character {
        text.deleteCharacters(in: character)
      } else {
        let piece =
          random.chance(4)
          ? NoteImages.token(
            NoteImages.Image(id: random.pick(rig.images).id, ext: "png", width: nil))
          : random.pick(snippets)
        text.insert(piece, at: character?.location ?? at)
      }
      let replaced = text as String
      outsideUndoGroup(rig) { editor.setText(replaced) }
      // setText 不往外报（外面那份就是刚换进来的）：记下来接着比
      rig.stored = rig.editorStored
      return "外面换了正文"
    case 28:
      // 直接改文本存储（不走 shouldChangeText / didChangeText）：兜底要接的那种路——真输入法改了光标处的字却不报
      // didChangeText——在选区上换字，系统随后报一次选区变化，兜底排的那次收尾（下一轮）收掉。改在光标后面的话系统
      // 不一定报选区（实测），兜底不管那种，这里不做
      let selection = editor.selectedRange()
      // 空的只在有选区时用（就是删掉选中的字）：没选区时换成空的什么都没改
      let snippet = random.pick(["`码`", "**", "x", "```\n", "> ", selection.length > 0 ? "" : "y"])
      rig.storage.replaceCharacters(
        in: selection, with: NSAttributedString(string: snippet, attributes: editor.baseAttributes))
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
    case 31:
      // 插图（自己的插入入口）：每张独占一行、一步撤销
      let image = random.pick(rig.images)
      let before = rig.editorStored
      editor.insert(images: [image])
      return "插图 \(image.id.uuidString.prefix(4))（\(before.count) → \(rig.editorStored.count) 字）"
    case 32:
      // 贴一段「自家类型」的字（带令牌）：图片跟着走、引用同一个文件
      let image = random.pick(rig.images)
      let width = random.chance(2) ? nil : random.next() % 4000 + 40
      var stored = ""
      if random.chance(2) { stored += random.pick(["文字", "**粗**", "\n", ""]) }
      stored += NoteImages.token(
        NoteImages.Image(id: image.id, ext: image.ext, width: NoteImages.width(width)))
      if random.chance(2) { stored += random.pick(["后面", "\n末尾", ""]) }
      editor.pasteboard.clearContents()
      editor.pasteboard.setString(stored, forType: NoteTextView.noteTextType)
      editor.paste(nil)
      return "贴自家类型 \(stored.debugDescription)"
    case 33:
      // 复制选中的一段再贴回（自家类型 + 纯文本两条都要在）
      let (a, b) = (position(&random), position(&random))
      editor.setSelectedRange(NSRange(location: min(a, b), length: abs(a - b)))
      editor.pasteboard.clearContents()
      _ = editor.writeSelection(
        to: editor.pasteboard, types: editor.writablePasteboardTypes)
      let copied = editor.pasteboard.string(forType: NoteTextView.noteTextType) ?? ""
      // 贴到别处（光标放到末尾之外的一个随机位置）
      editor.setSelectedRange(NSRange(location: position(&random), length: 0))
      editor.paste(nil)
      return "复制再贴回（复制到 \(copied.count) 个字）"
    case 34:
      // 选中一张图（或者它旁边）再删
      let indexes = rig.imageIndexes
      guard let index = indexes.isEmpty ? nil : random.pick(indexes) else {
        return "没有图可选中"
      }
      let offset = random.pick([-1, 0, 1])
      editor.setSelectedRange(
        NSRange(location: max(0, index + offset), length: random.chance(2) ? 1 : 0))
      if random.chance(2) {
        editor.deleteBackward(nil)
        return "选中图附近（\(index)\(offset >= 0 ? "+" : "")\(offset)）再 ⌫"
      }
      editor.deleteForward(nil)
      return "选中图附近（\(index)\(offset >= 0 ? "+" : "")\(offset)）再 ⌦"
    case 35:
      // 改宽度（拖把手的松手那一下：写进正文，一步撤销）
      let indexes = rig.imageIndexes
      guard let index = indexes.isEmpty ? nil : random.pick(indexes) else {
        return "没有图可改宽度"
      }
      let width = random.pick([40, 120, 240, 4000, 0, 9999, random.next() % 5000])
      _ = editor.replaceImageWidth(at: index, width: width)
      return "改宽度 \(width)（第 \(index) 个字）"
    case 36:
      // 图片行上的样式那一遍：换纸色 / 字号 / 行距 / Markdown 开关（附件不许被抹掉、行高要重算）
      switch random.next() % 4 {
      case 0: rig.paper = random.next() % NotePaper.all.count
      case 1: rig.fontSize = random.pick([13, 15, 17, 20])
      case 2: rig.spacing = random.pick(NoteStyles.Spacing.allCases)
      default: rig.markdown.toggle()
      }
      rig.applyPaper()
      return "图片行重排 纸 \(rig.paper) 字号 \(rig.fontSize) 行距 \(rig.spacing) markdown \(rig.markdown)"
    case 37:
      // 随机选区上随机颜色（含默认颜色去色）：一步撤销，结果过扫描器（单测 NoteBatch8Tests 锁着）
      let (a, b) = (position(&random), position(&random))
      editor.setSelectedRange(NSRange(location: min(a, b), length: abs(a - b)))
      let color = random.chance(3) ? nil : random.pick(NoteColor.allCases)
      editor.setTextColor(color)
      return "上色 \(color?.name ?? "默认") \(min(a, b))..<\(max(a, b))"
    case 38:
      // 随机行改随机状态（选区碰到的每一行）
      let (a, b) = (position(&random), position(&random))
      editor.setSelectedRange(NSRange(location: min(a, b), length: abs(a - b)))
      let state = random.pick(NoteTasks.State.allCases)
      editor.setTaskState(state)
      return "任务状态 \(state) \(min(a, b))..<\(max(a, b))"
    case 39:
      // 点方框（直接调改字那一支；不走 mouseDown：探针自己造出来的坏正文 + 图片令牌会让 TextKit 1 排版死循环，
      // 单测 NoteTextViewTests / NoteBatch8Tests 里已经真的点过方框和右键）
      let text = rig.storage.mutableString
      var boxes: [Int] = []
      var location = 0
      while location < text.length {
        var (start, end, contentsEnd) = (0, 0, 0)
        text.getLineStart(
          &start, end: &end, contentsEnd: &contentsEnd,
          for: NSRange(location: location, length: 0))
        let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
        // 断掉 / 半个的图片令牌旁边点方框会把 TextKit 1 排进死循环（探针自己造出来的怪正文）：只点干净的行
        if !line.contains("\u{FFFC}"), !line.contains("kitty-note-image://"),
          let offset = NoteTasks.box(in: line)
        {
          boxes.append(start + offset)
        }
        location = max(end, location + 1)
      }
      guard let index = boxes.isEmpty ? nil : random.pick(boxes) else {
        return "没有方框可点"
      }
      rig.editor.flipBox(at: index)
      return "点方框 \(index)"
    case 40:
      // 在颜色标记中间打字 / 删（标记露出来的时候）
      let units = Array((text as String).utf16)
      let colorRanges = NoteMarkdown.colorRuns(
        in: NoteMarkdown.inline(units, in: 0..<units.count))
      if let run = colorRanges.isEmpty ? nil : random.pick(colorRanges) {
        let at = run.open.location + random.next() % max(run.close.location - run.open.location, 1)
        editor.setSelectedRange(NSRange(location: at, length: random.chance(2) ? 1 : 0))
        if random.chance(2) {
          rig.type(random.pick(["[", "]", "{", "}", "x", "字", "]*{red}", " "]))
          return "颜色标记中间打字 \(at)"
        }
        editor.deleteBackward(nil)
        return "颜色标记中间删 \(at)"
      }
      rig.type(random.pick(["", "[a]{red}"]))
      return "没有颜色可动"
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
