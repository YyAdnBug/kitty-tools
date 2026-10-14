// 便签专用的正文编辑器（Notes/NoteTextView.swift，PLAN §10「便签」第 5 批）在屏外窗口里的行为：
// TextKit 1 的栈、点方框换字且进撤销栈、样式只改属性（不进撤销栈、不动选区、只重排受影响的行）、输入法组字期间
// 不重排不往外写而确认后补上（setMarkedText 模拟）、超上限拦下、按编号认和拿焦点、撤销栈是窗口给的那一个、
// 回车续行 / Tab 缩进 / 打「- [ ]」自动转换 / ⌘T、Esc 先关查找条、查找条不当 key 也出得来、右键菜单的「任务」。
// 第 6 批 Markdown：藏着的标记不画、不占宽度（零宽的控制字符），留在自己的行里；标记只在「选区碰到的行 + 拿着焦点 + 窗口是 key + 能编辑」时露出来；
// 编辑在别处、光标被带走之后旧行收回去；输入法组字期间属性一点不动、确认后补上，刚打的字从不带隐藏属性；
// ⌘ 点才打开链接（打开的动作换成记账的闭包，不真的开浏览器）；开关关掉没有 Markdown、任务照常。
// 第 6 批评审后的一轮：撤掉组字之后自己收尾、改了字却没有 didChangeText 时下一轮兜底、⌃↩ 当普通换行、
// 已经超上限的正文删得动、右键菜单的「打开链接」。
// 「窗口是 key」是直接告诉编辑器的（keyChanged）——屏外的窗口不许真的当 key。
// 窗口都摆在离所有屏幕很远的地方（先确认不和任何屏相交）、**不当 key**；不发任何合成的鼠标键盘事件——事件对象只是
// 直接交给视图的方法。偏好只用临时域，不碰用户的和便签库。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct NoteTextViewTests {
  /// 撤销栈由它给的窗口（同 NoteDeckPanel / NotesWindow：一条便签一个）
  private final class Host: NSWindow {
    let notes = UndoManager()
    override var undoManager: UndoManager? { notes }
  }

  /// 屏外窗口里的一个编辑器，连它往外报的东西
  private final class Rig {
    let window: Host
    let scroll = NSScrollView()
    let editor = NoteTextView.make()
    var changes: [String] = []
    var overflows = 0
    var cancels = 0

    /// steps：撤销按「一步一组」来（groupsByEvent 关掉，每一步包在 step 里）——测试是同步跑的，不关的话所有改动
    /// 都落在同一个事件的组里，一次撤销全没了
    init(_ body: String, maxBytes: Int? = nil, steps: Bool = false) throws {
      let frame = CGRect(x: -30000, y: -30000, width: 420, height: 320)
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
      window = Host(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.notes.groupsByEvent = !steps
      editor.identifier = NSUserInterfaceItemIdentifier("便签甲")
      editor.maxBytes = maxBytes
      editor.textContainerInset = NSSize(width: 9, height: 6)
      editor.onChange = { [unowned self] in changes.append($0) }
      editor.onOverflow = { [unowned self] in overflows += 1 }
      editor.onCancel = { [unowned self] in cancels += 1 }
      scroll.hasVerticalScroller = true
      scroll.documentView = editor
      window.contentView = scroll
      editor.setPaper(NotePaper.all[0], fontSize: 15, markdown: true)
      editor.setText(body)
      window.makeFirstResponder(editor)
      layout()
    }

    func layout() {
      scroll.layoutSubtreeIfNeeded()
      if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
    }

    /// 一步（一个事件）里做的改动：撤销时是一步
    func step(_ body: () throws -> Void) rethrows {
      window.notes.beginUndoGrouping()
      defer { window.notes.endUndoGrouping() }
      try body()
    }

    /// 第 index 个字的正中（窗口坐标）
    func center(of index: Int) throws -> NSPoint {
      layout()
      let manager = try #require(editor.layoutManager)
      let container = try #require(editor.textContainer)
      let glyphs = manager.glyphRange(
        forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
      let origin = editor.textContainerOrigin
      return editor.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), to: nil)
    }

    func mouse(
      _ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: flags, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }

    /// 摆成「窗口是 key、焦点在正文」的样子。屏外的窗口不真的当 key：直接告诉编辑器
    func activate() {
      window.makeFirstResponder(editor)
      editor.keyChanged(true)
    }

    func isHidden(_ index: Int) -> Bool { attribute(NoteStyles.hiddenKey, at: index) != nil }
    func isShown(_ index: Int) -> Bool { attribute(NoteStyles.shownKey, at: index) != nil }

    /// 第 index 个字是不是藏着：不是换行、Tab 这些真的控制字符，字形却当成了控制字符（不画），而且不占宽度
    func isGone(_ index: Int) -> Bool {
      layout()
      guard let manager = editor.layoutManager, let container = editor.textContainer,
        let unit = editor.textStorage?.mutableString.character(at: index), unit >= 0x20
      else { return false }
      let glyph = manager.glyphIndexForCharacter(at: index)
      return manager.propertyForGlyph(at: glyph).contains(.controlCharacter)
        && manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
          .width == 0
    }

    /// 第 index 个字排在第几行（从上往下数的行片段的纵向位置）
    func lineTop(of index: Int) -> CGFloat {
      layout()
      guard let manager = editor.layoutManager else { return -1 }
      return manager.lineFragmentRect(
        forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil
      ).minY
    }

    /// 第 index 个字排在这一行的哪（横向）
    func offset(of index: Int) -> CGFloat {
      layout()
      guard let manager = editor.layoutManager else { return 0 }
      return manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: index)).x
    }

    /// 每一行的标记是什么状态，连成一串：S 露着、H 藏着、- 这一行没有标记、X 又露又藏（不该有）
    var markers: String {
      guard let storage = editor.textStorage else { return "" }
      var result = ""
      var location = 0
      repeat {
        let line = storage.mutableString.lineRange(for: NSRange(location: location, length: 0))
        var (shown, hidden) = (false, false)
        storage.enumerateAttribute(NoteStyles.shownKey, in: line) { value, _, _ in
          shown = shown || value != nil
        }
        storage.enumerateAttribute(NoteStyles.hiddenKey, in: line) { value, _, _ in
          hidden = hidden || value != nil
        }
        result += shown && hidden ? "X" : shown ? "S" : hidden ? "H" : "-"
        location = NSMaxRange(line)
      } while location < storage.length
      return result
    }

    /// 这一段字连属性拍一份（比「属性一点没动」用）
    func copy(_ range: NSRange) -> NSAttributedString {
      editor.textStorage?.attributedSubstring(from: range) ?? NSAttributedString()
    }

    /// 模拟输入法：组字、确认
    func compose(_ text: String) {
      editor.setMarkedText(
        text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func type(_ text: String) {
      editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
      editor.textStorage?.attribute(key, at: index, effectiveRange: nil)
    }

    var isStruck: (Int) -> Bool {
      { [unowned self] in attribute(.strikethroughStyle, at: $0) != nil }
    }
    func fontName(at index: Int) -> String? { (attribute(.font, at: index) as? NSFont)?.fontName }
  }

  private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

  /// 显式搭的 TextKit 1：有 NSLayoutManager、没有 NSTextLayoutManager（下一批藏 Markdown 标记要它）；纯文本、
  /// 系统的查找条；只拿着视图，存储跟着活
  @Test func stackIsTextKitOne() throws {
    let rig = try Rig("正文")
    #expect(rig.editor.textLayoutManager == nil && rig.editor.layoutManager != nil)
    #expect(rig.editor.textStorage?.layoutManagers.count == 1)
    #expect(rig.editor.textStorage?.delegate === rig.editor)
    #expect(!rig.editor.isRichText && rig.editor.allowsUndo)
    #expect(rig.editor.usesFindBar && rig.editor.isIncrementalSearchingEnabled)
    #expect(rig.editor.string == "正文" && !rig.window.isKeyWindow && !rig.window.isVisible)
    // 刚放进去的正文不算「改了」，也没有可撤销的
    #expect(rig.changes.isEmpty && !rig.window.notes.canUndo)
    // 打进去的字永远是基础样式（不跟光标前面那个字走）
    #expect((rig.editor.typingAttributes[.font] as? NSFont)?.pointSize == 15)
    // 和滚动区一样宽、至少和可见区一样高：点正文下面的空白也是点它（光标到末尾）
    #expect(rig.editor.frame.width == rig.scroll.contentSize.width)
    #expect(rig.editor.frame.height >= rig.scroll.contentSize.height)
  }

  /// 点方框：☐ ↔ ☑，进撤销栈、往外报、光标不动；点的范围比那个字四周宽几点；不是 key 的窗口里第一下就算
  @Test func clickingABoxFlipsItAndIsUndoable() throws {
    let rig = try Rig("周五前\n  ☐ 周报\n☑ 订会议室\n普通的一行", steps: true)
    rig.editor.setSelectedRange(caret(2))
    let box = try rig.center(of: 6)
    let local = rig.editor.convert(box, from: nil)
    #expect(rig.editor.box(at: local) == 6)
    // 四周放宽：左边 3 pt 还算，远了不算；别的字、普通行、行尾都不算
    let width = NoteTextView.boxSlop.width
    #expect(rig.editor.box(at: NSPoint(x: local.x - 6 - width + 1, y: local.y)) == 6)
    #expect(rig.editor.box(at: NSPoint(x: local.x - 40, y: local.y)) == nil)
    #expect(try rig.editor.box(at: rig.editor.convert(rig.center(of: 8), from: nil)) == nil)
    #expect(try rig.editor.box(at: rig.editor.convert(rig.center(of: 1), from: nil)) == nil)
    #expect(try rig.editor.box(at: rig.editor.convert(rig.center(of: 19), from: nil)) == nil)
    #expect(try rig.editor.box(at: rig.editor.convert(rig.center(of: 11), from: nil)) == 11)
    // 第一下点击就给（窗口不是 key）
    #expect(!rig.window.isKeyWindow)
    #expect(try rig.editor.acceptsFirstMouse(for: rig.mouse(.leftMouseDown, at: box)))

    try rig.step { rig.editor.mouseDown(with: try rig.mouse(.leftMouseDown, at: box)) }
    #expect(rig.editor.string == "周五前\n  ☑ 周报\n☑ 订会议室\n普通的一行")
    #expect(rig.changes == [rig.editor.string] && rig.editor.selectedRange() == caret(2))
    // 做完的样式跟上了：内容划线，方框不划
    #expect(rig.isStruck(8) && rig.isStruck(9) && !rig.isStruck(6) && !rig.isStruck(0))
    // 再点一下换回来；两步撤销各退一步
    try rig.step { rig.editor.mouseDown(with: try rig.mouse(.leftMouseDown, at: box)) }
    #expect(rig.editor.string.contains("☐ 周报") && !rig.isStruck(8))
    rig.window.notes.undo()
    #expect(rig.editor.string.contains("☑ 周报") && rig.isStruck(8))
    rig.window.notes.undo()
    #expect(rig.editor.string.contains("☐ 周报") && !rig.isStruck(8))
    #expect(!rig.window.notes.canUndo && rig.window.notes.canRedo)
    rig.window.notes.redo()
    #expect(rig.editor.string.contains("☑ 周报") && rig.isStruck(8))
    #expect(rig.changes.count == 5 && rig.changes.last == rig.editor.string)
  }

  /// 样式只改属性：不进撤销栈、不动选区、不往外报；方框两个字形同一种字体；换纸色整篇重排、照样不进撤销栈
  @Test func stylesTouchOnlyAttributes() throws {
    let rig = try Rig("☐ 周报\n☑ 订会议室\n普通的一行")
    let storage = try #require(rig.editor.textStorage)
    // 方框：两个状态同一种字体（系统字体里没有 ☐，各走各的后备字体会一大一小）
    #expect(rig.fontName(at: 0) == "AppleSymbols" && rig.fontName(at: 5) == "AppleSymbols")
    #expect(rig.fontName(at: 2) != "AppleSymbols" && rig.fontName(at: 14) != "AppleSymbols")
    // 做完的那行：内容划线、墨色变淡；方框和别的行不变
    #expect(rig.isStruck(7) && rig.isStruck(10) && !rig.isStruck(5) && !rig.isStruck(2))
    #expect(!rig.isStruck(14))
    let ink = rig.attribute(.foregroundColor, at: 2) as? NSColor
    let faded = rig.attribute(.foregroundColor, at: 7) as? NSColor
    #expect(ink != nil && faded != nil && ink != faded)
    #expect(!rig.window.notes.canUndo && rig.changes.isEmpty)

    // 只重排受影响的行：给第三行挂一个记号，改第一行，记号还在
    storage.addAttribute(.toolTip, value: "记号", range: NSRange(location: 12, length: 2))
    rig.editor.setSelectedRange(caret(4))
    rig.type("和月报")
    #expect(rig.editor.string.hasPrefix("☐ 周报和月报\n"))
    #expect(rig.attribute(.toolTip, at: 15) as? String == "记号")
    // 选区是打字留下的那个，样式没动它
    #expect(rig.editor.selectedRange() == caret(7))
    // 换纸色、换字号：整篇重排（记号没了），撤销栈里还是只有刚才打的字
    rig.window.notes.undo()
    #expect(rig.editor.string.hasPrefix("☐ 周报\n") && !rig.window.notes.canUndo)
    let changes = rig.changes.count
    rig.editor.setSelectedRange(caret(3))
    rig.editor.setPaper(NotePaper.all[3], fontSize: 17, markdown: true)
    #expect(rig.attribute(.toolTip, at: 12) == nil)
    #expect((rig.attribute(.font, at: 2) as? NSFont)?.pointSize == 17)
    #expect(rig.isStruck(7) && rig.fontName(at: 0) == "AppleSymbols")
    #expect(!rig.window.notes.canUndo && rig.window.notes.canRedo)
    #expect(rig.editor.selectedRange() == caret(3) && rig.changes.count == changes)
    // 同样的纸色字号再给一遍：不动
    storage.addAttribute(.toolTip, value: "记号", range: NSRange(location: 12, length: 2))
    rig.editor.setPaper(NotePaper.all[3], fontSize: 17, markdown: true)
    #expect(rig.attribute(.toolTip, at: 12) as? String == "记号")
  }

  /// 输入法组字期间不重排、不往外写（拼音字母不进仓库），外面那份旧正文也盖不掉正在组的字；确认之后一次补上
  @Test func composingDefersStylesAndWrites() throws {
    let rig = try Rig("☑ 完成\n第二行")
    rig.editor.setSelectedRange(caret(4))
    rig.compose("pin")
    #expect(rig.editor.hasMarkedText() && rig.editor.string == "☑ 完成pin\n第二行")
    // 没往外写、没重排（组着的字还没有做完任务的划线）
    #expect(rig.changes.isEmpty && rig.isStruck(3) && !rig.isStruck(5))
    // SwiftUI 这时来同步：给的还是仓库里那份旧的——不许拿它盖掉正在组的字
    rig.editor.setText("☑ 完成\n第二行")
    #expect(rig.editor.hasMarkedText() && rig.editor.string == "☑ 完成pin\n第二行")
    // 组字期间外面真换了正文也先不收
    rig.editor.setText("别处改的")
    #expect(rig.editor.string == "☑ 完成pin\n第二行")
    rig.compose("ping")
    #expect(rig.changes.isEmpty && !rig.isStruck(5))
    // 确认：往外写一次（确认过的全文），划线补到新打的字上
    rig.type("拼")
    #expect(!rig.editor.hasMarkedText() && rig.editor.string == "☑ 完成拼\n第二行")
    #expect(rig.changes == ["☑ 完成拼\n第二行"] && rig.isStruck(4) && !rig.isStruck(6))
    // 撤掉组字（输入法里按 Esc）：字回到原样，不多写一次
    rig.compose("yi")
    rig.compose("")
    #expect(rig.editor.string == "☑ 完成拼\n第二行" && rig.changes.count == 1)
    // 组到一半直接作数（输入法收尾时的另一条路）：留下的字也要写出去、补上样式
    rig.compose("er")
    rig.editor.unmarkText()
    #expect(rig.editor.string == "☑ 完成拼er\n第二行" && rig.changes.last == rig.editor.string)
    #expect(rig.changes.count == 2 && rig.isStruck(6))
    // 之后外面换了正文：照收（整段替换，样式整篇重排）
    rig.editor.setText("☐ 新的")
    #expect(rig.editor.string == "☐ 新的" && rig.changes.count == 2 && !rig.isStruck(2))
  }

  /// 组字到一半焦点走了、输入法又没收尾：晚一拍替它确认掉——看得见的字和交出去的字要一样
  @Test func strayCompositionIsCommittedAfterLosingFocus() async throws {
    let rig = try Rig("第一行")
    rig.editor.setSelectedRange(caret(3))
    rig.compose("er")
    #expect(rig.changes.isEmpty)
    #expect(rig.window.makeFirstResponder(nil))
    for _ in 0..<150 where rig.editor.hasMarkedText() {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!rig.editor.hasMarkedText() && rig.editor.string == "第一行er")
    #expect(rig.changes == ["第一行er"])
  }

  /// 上限：会超的那一次输入不进（不截断），删得动；输入法确认之后超了退回组字之前
  @Test func overflowIsRefused() throws {
    let rig = try Rig("你好吗", maxBytes: 12)
    rig.editor.setSelectedRange(caret(3))
    rig.type("abc")
    #expect(rig.editor.string == "你好吗abc" && rig.overflows == 0)
    rig.type("d")
    #expect(rig.editor.string == "你好吗abc" && rig.overflows == 1 && rig.changes.count == 1)
    // 换成更短的、删除：放行
    rig.editor.insertText("x", replacementRange: NSRange(location: 3, length: 3))
    #expect(rig.editor.string == "你好吗x" && rig.overflows == 1)
    // 组字期间不判断；确认时超了：退回组字之前的全文
    rig.compose("nihao")
    #expect(rig.editor.string == "你好吗xnihao" && rig.overflows == 1)
    rig.type("你好")
    #expect(rig.editor.string == "你好吗x" && rig.overflows == 2)
    #expect(rig.changes.last == "你好吗x" && !rig.editor.hasMarkedText())
    // ⌘T 要加的「☐ 」放不下：同样拦下
    rig.editor.setText("你好吗啊")
    rig.editor.toggleTask()
    #expect(rig.editor.string == "你好吗啊" && rig.overflows == 3)
    // 纯函数：几段一起算
    let overflows = NoteTextView.overflows
    let one = NSRange(location: 0, length: 0)
    #expect(!overflows("ab", [one, NSRange(location: 2, length: 0)], ["☐", "x"], 6))
    #expect(overflows("ab", [one, NSRange(location: 2, length: 0)], ["☐", "xy"], 6))
    #expect(!overflows("你好吗", [NSRange(location: 0, length: 3)], ["abc"], 1))
  }

  /// 正文不知怎么已经超了上限：删得动、照常交出去，不会整段退回去；再往里加还是拦下
  @Test func overLimitBodyCanStillShrink() throws {
    let rig = try Rig("abcdefghijklmnopqrst", maxBytes: 12)
    rig.editor.setSelectedRange(caret(20))
    rig.editor.deleteBackward(nil)
    #expect(rig.editor.string == "abcdefghijklmnopqrs" && rig.overflows == 0)
    #expect(rig.changes == ["abcdefghijklmnopqrs"])
    rig.type("x")
    #expect(rig.editor.string == "abcdefghijklmnopqrs" && rig.overflows == 1)
    // 输入法确认之后变长了、还超着：退回组字之前
    rig.compose("ni")
    rig.type("你")
    #expect(rig.editor.string == "abcdefghijklmnopqrs" && rig.overflows == 2)
    #expect(rig.changes == ["abcdefghijklmnopqrs"] && !rig.editor.hasMarkedText())
  }

  /// ⌃↩（insertLineBreak:）当普通换行：不插软换行 U+2028（NSString 把它算新的一行、段落样式却按段算，后面的引用
  /// 缩进不对）；任务行里照样续行
  @Test func softLineBreakIsAPlainNewline() throws {
    let rig = try Rig("> 引用", steps: true)
    let lineBreak = #selector(NSResponder.insertLineBreak(_:))
    rig.editor.setSelectedRange(caret(4))
    rig.step { rig.editor.doCommand(by: lineBreak) }
    #expect(rig.editor.string == "> 引用\n" && rig.changes == ["> 引用\n"])
    rig.editor.setText("☐ 周报")
    rig.editor.setSelectedRange(caret(4))
    rig.step { rig.editor.doCommand(by: lineBreak) }
    #expect(rig.editor.string == "☐ 周报\n☐ " && rig.editor.selectedRange() == caret(7))
  }

  /// 回车续行和空项退出、Tab 缩进、打「- [ ]」加空格自动转换，都是一步撤销；别的行这些键照常
  @Test func listKeys() throws {
    let rig = try Rig("☐ 周报", steps: true)
    let newline = #selector(NSResponder.insertNewline(_:))
    rig.editor.setSelectedRange(caret(4))
    rig.step { rig.editor.doCommand(by: newline) }
    #expect(rig.editor.string == "☐ 周报\n☐ " && rig.editor.selectedRange() == caret(7))
    // 空任务上再回车：去掉标记、退出列表
    rig.step { rig.editor.doCommand(by: newline) }
    #expect(rig.editor.string == "☐ 周报\n" && rig.editor.selectedRange() == caret(5))
    // 普通行：照常换行
    rig.step { rig.editor.doCommand(by: newline) }
    #expect(rig.editor.string == "☐ 周报\n\n")
    rig.window.notes.undo()
    rig.window.notes.undo()
    #expect(rig.editor.string == "☐ 周报\n☐ ")
    rig.window.notes.undo()
    #expect(rig.editor.string == "☐ 周报" && !rig.window.notes.canUndo)

    // Tab / ⇧Tab：任务行缩进、退回；普通行的 Tab 是制表符
    rig.editor.setSelectedRange(caret(4))
    rig.step { rig.editor.doCommand(by: #selector(NSResponder.insertTab(_:))) }
    #expect(rig.editor.string == "  ☐ 周报" && rig.editor.selectedRange() == caret(6))
    rig.step { rig.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
    #expect(rig.editor.string == "☐ 周报" && rig.editor.selectedRange() == caret(4))
    // 没有缩进可退：吞掉，不改字、不多一步撤销
    let steps = rig.changes.count
    rig.step { rig.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
    #expect(rig.editor.string == "☐ 周报" && rig.changes.count == steps)
    rig.editor.setText("普通")
    rig.editor.setSelectedRange(caret(2))
    rig.step { rig.editor.doCommand(by: #selector(NSResponder.insertTab(_:))) }
    #expect(rig.editor.string == "普通\t")

    // 自动转换：行首打出「- [ ]」再按空格 → 「☐ 」；⌘Z 退回「- [ ]」
    rig.editor.setText("")
    for character in "- [ ]" { rig.step { rig.type(String(character)) } }
    #expect(rig.editor.string == "- [ ]")
    rig.step { rig.type(" ") }
    #expect(rig.editor.string == "☐ " && rig.editor.selectedRange() == caret(2))
    #expect(rig.fontName(at: 0) == "AppleSymbols")
    rig.window.notes.undo()
    #expect(rig.editor.string == "- [ ]")
    rig.editor.setSelectedRange(caret(5))
    rig.editor.setText("  - [x]")
    rig.editor.setSelectedRange(caret(7))
    rig.step { rig.type(" ") }
    #expect(rig.editor.string == "  ☑ ")
    // 别的时候空格就是空格
    rig.editor.setText("- [ ] 已经有了")
    rig.editor.setSelectedRange(caret(9))
    rig.step { rig.type(" ") }
    #expect(rig.editor.string == "- [ ] 已经有 了")
  }

  /// ⌘T：光标所在行、选区碰到的每一行；一步撤销；选区跟着挪
  @Test func toggleTaskCommand() throws {
    let rig = try Rig("周报\n- 报销单\n\n普通", steps: true)
    rig.editor.setSelectedRange(caret(1))
    rig.step { rig.editor.toggleTask() }
    #expect(rig.editor.string == "☐ 周报\n- 报销单\n\n普通" && rig.editor.selectedRange() == caret(3))
    rig.step { rig.editor.toggleTask() }
    #expect(rig.editor.string == "周报\n- 报销单\n\n普通" && rig.editor.selectedRange() == caret(1))
    // 选了全部四行：还不是任务的都变成任务（空行不动）
    rig.editor.selectAll(nil)
    rig.step { rig.editor.toggleTask() }
    #expect(rig.editor.string == "☐ 周报\n☐ 报销单\n\n☐ 普通")
    #expect(rig.editor.selectedRange() == NSRange(location: 0, length: 16))
    // 再按一次：都去掉
    rig.step { rig.editor.toggleTask() }
    #expect(rig.editor.string == "周报\n报销单\n\n普通")
    rig.window.notes.undo()
    #expect(rig.editor.string == "☐ 周报\n☐ 报销单\n\n☐ 普通")
    rig.window.notes.undo()
    #expect(rig.editor.string == "周报\n- 报销单\n\n普通")
    // 选区正好停在下一行行首（选了整行连换行）：下一行不算碰到
    rig.editor.setSelectedRange(NSRange(location: 0, length: 3))
    rig.step { rig.editor.toggleTask() }
    #expect(rig.editor.string == "☐ 周报\n- 报销单\n\n普通")
    // 组字时不动
    rig.editor.setSelectedRange(caret(15))
    rig.step {
      rig.compose("pu")
      rig.editor.toggleTask()
    }
    #expect(rig.editor.string.hasSuffix("普通pu") && rig.editor.hasMarkedText())
  }

  /// 按编号认、挂进窗口的那一刻拿焦点（窗口不必是 key）；撤销栈是窗口给的那一个；Esc 先关查找条再给 onCancel；
  /// 查找条在不是 key 的屏外窗口里也出得来，关了焦点回正文
  @Test func focusFindBarAndEscape() throws {
    let rig = try Rig("第一行\n第二行")
    #expect(rig.editor.identifier?.rawValue == "便签甲")
    #expect(rig.editor.undoManager === rig.window.notes)
    // 另一个编辑器：标了要拿焦点，放进窗口的那一刻就是第一响应者
    let other = NoteTextView.make()
    other.takesFocusOnAppear = true
    other.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
    rig.scroll.addSubview(other)
    #expect(rig.window.firstResponder === other && !rig.window.isKeyWindow)
    other.removeFromSuperview()
    rig.window.makeFirstResponder(rig.editor)

    let cancel = #selector(NSResponder.cancelOperation(_:))
    rig.editor.doCommand(by: cancel)
    #expect(rig.cancels == 1)
    #expect(!rig.editor.dismissFindBar() && !rig.scroll.isFindBarVisible)
    rig.editor.showFindBar()
    #expect(rig.scroll.isFindBarVisible && !rig.window.isKeyWindow)
    #expect(rig.window.firstResponder !== rig.editor)
    // 查找条里的输入不算改正文
    #expect(rig.changes.isEmpty && rig.editor.string == "第一行\n第二行")
    // Esc：先关查找条（不到 onCancel），再按才是 onCancel
    rig.editor.doCommand(by: cancel)
    #expect(!rig.scroll.isFindBarVisible && rig.cancels == 1)
    #expect(rig.window.firstResponder === rig.editor)
    rig.editor.doCommand(by: cancel)
    #expect(rig.cancels == 2)
    // 没给 onCancel 的：交给窗口
    rig.editor.onCancel = nil
    rig.editor.doCommand(by: cancel)
    #expect(rig.cancels == 2)
  }

  /// 右键菜单最前面是「任务」，点了就是 ⌘T
  @Test func contextMenuHasTheTaskItem() throws {
    let rig = try Rig("周报")
    let event = try rig.mouse(.rightMouseDown, at: rig.center(of: 0))
    let menu = try #require(rig.editor.menu(for: event))
    let item = try #require(menu.items.first)
    #expect(item.title == NotesWindowModel.taskTitle && item.keyEquivalent.isEmpty)
    #expect(menu.items.count > 2 && menu.items[1].isSeparatorItem)
    #expect(rig.editor.validateUserInterfaceItem(item))
    rig.editor.setSelectedRange(caret(0))
    _ = item.target?.perform(item.action, with: item)
    #expect(rig.editor.string == "☐ 周报")
  }

  /// 右键点在能打开的链接上：菜单最前面多一项「打开链接」（不靠 ⌘ 点的那条路：键盘、旁白用户），不写键位；
  /// 普通的字、打不开的地址上没有。点的那一行标记藏着、光标在别的行时照样认得出点的是链接
  @Test func contextMenuOpensLinks() throws {
    // ** 0-1 粗 2 ** 3-4 空格 5 [ 6 字 7 ] 8 …
    let text = "**粗** [字](https://example.com/a) 和 [本地](file:///etc/hosts)\n第二行"
    let rig = try Rig(text)
    var opened: [URL] = []
    rig.editor.onOpenLink = { opened.append($0) }
    rig.activate()
    rig.editor.setSelectedRange(caret(text.utf16.count))
    #expect(rig.markers == "H-")
    let menu = try #require(
      rig.editor.menu(for: rig.mouse(.rightMouseDown, at: rig.center(of: 7))))
    let item = try #require(menu.items.first)
    #expect(item.title == NoteTextView.openLinkTitle && item.keyEquivalent.isEmpty)
    #expect(menu.items.count > 3 && menu.items[1].title == NotesWindowModel.taskTitle)
    #expect(menu.items[2].isSeparatorItem && rig.editor.validateUserInterfaceItem(item))
    #expect(opened.isEmpty)
    _ = item.target?.perform(item.action, with: item)
    #expect(opened == [URL(string: "https://example.com/a")] && rig.changes.isEmpty)
    // 普通的字、打不开的地址（只有下划线）：没有这一项，最前面还是「任务」
    let local = (text as NSString).range(of: "本地").location
    for index in [2, local, text.utf16.count - 1] {
      let other = try #require(
        rig.editor.menu(for: rig.mouse(.rightMouseDown, at: rig.center(of: index))))
      #expect(other.items.first?.title == NotesWindowModel.taskTitle, "\(index)")
      #expect(!other.items.contains { $0.title == NoteTextView.openLinkTitle }, "\(index)")
    }
    #expect(opened.count == 1 && rig.editor.string == text)
    // 键盘出的菜单（事件里没有点的位置）：看光标——在链接的字里、紧跟在它后面有这一项，在别处没有
    let key = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: 36))
    for (index, expected) in [(7, true), (8, true), (2, false), (local, false)] {
      rig.editor.setSelectedRange(caret(index))
      let byKey = try #require(rig.editor.menu(for: key))
      #expect((byKey.items.first?.title == NoteTextView.openLinkTitle) == expected, "\(index)")
    }
  }

  /// 共用的正文框（NoteBodyField）里就是这个编辑器：标着便签的编号、墨色的字和插入点、打字写回去；几百行的便签
  /// 改一个字只重排那一行（别的行上挂的记号还在）
  @Test func bodyFieldHostsTheEditor() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let lines = (1...400).map { $0 % 3 == 0 ? "☑ 第 \($0) 行" : "☐ 第 \($0) 行" }
    let note = store.create(body: lines.joined(separator: "\n"))
    var written: [String] = []
    let window = NSWindow(
      contentRect: CGRect(x: -30000, y: -30000, width: 460, height: 380),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: NoteBodyField(
        note: note, fontSize: 15, margin: 14, setBody: { written.append($0) }, onOverflow: {}))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let editor = try #require(NoteDeck.editor(for: note.id, in: host))
    #expect(NotesWindow.editor(in: host) === editor && editor.maxBytes == Note.maxBodyBytes)
    #expect(editor.string == note.body && written.isEmpty)
    #expect(editor.textContainerInset == NSSize(width: 9, height: 6))
    let storage = try #require(editor.textStorage)
    let far = (note.body as NSString).range(of: "第 300 行")
    storage.addAttribute(.toolTip, value: "记号", range: far)
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    editor.insertText("改", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(written.count == 1 && written.last?.hasPrefix("☐ 改第 1 行\n") == true)
    #expect(storage.attribute(.toolTip, at: far.location + 1, effectiveRange: nil) != nil)
    // 第一响应者在不在正文里（⌘F 去哪）：正文框自己、它的滚动区里的东西算，别的不算
    #expect(NotesWindow.isInBody(editor, editor: editor))
    #expect(
      !NotesWindow.isInBody(host, editor: editor) && !NotesWindow.isInBody(nil, editor: editor))
    #expect(!NotesWindow.isInBody(editor, editor: nil))
    editor.showFindBar()
    #expect(NotesWindow.isInBody(window.firstResponder, editor: editor))
    #expect(window.firstResponder !== editor && !window.isKeyWindow)
    editor.dismissFindBar()
  }

  // MARK: Markdown（第 6 批）

  /// 藏着的标记：字形是空的、不占宽度，这一行排出来变窄；露出来就占回去。只动属性：不进撤销栈、不往外报
  @Test func hiddenMarkersTakeNoSpace() throws {
    // ** 0-1 粗 2 体 3 ** 4-5 空格 6 后 7 面 8 换行 9 | * 10 第 11 二 12 行 13 * 14 空格 15 的 16 字 17
    let rig = try Rig("**粗体** 后面\n*第二行* 的字")
    rig.editor.setSelectedRange(caret(3))
    // 焦点在正文、窗口不是 key：都藏着
    #expect(rig.markers == "HH")
    #expect(rig.isHidden(0) && rig.isHidden(1) && rig.isHidden(4) && rig.isHidden(5))
    #expect(!rig.isHidden(2) && !rig.isHidden(6) && rig.isHidden(10) && rig.isHidden(14))
    #expect(rig.isGone(0) && rig.isGone(1) && rig.isGone(4) && rig.isGone(5) && rig.isGone(10))
    #expect(!rig.isGone(2) && !rig.isGone(3) && !rig.isGone(6) && !rig.isGone(11))
    // 藏着的字不占宽度：「粗」就排在行首，和它前面那两个星号同一个位置
    #expect(rig.offset(of: 2) == rig.offset(of: 0) && rig.offset(of: 6) == rig.offset(of: 4))
    let (hiddenEnd, secondEnd) = (rig.offset(of: 8), rig.offset(of: 17))
    // 当上 key：光标所在的第一行露出来，变宽；第二行没动
    rig.editor.keyChanged(true)
    #expect(rig.markers == "SH" && rig.isShown(0) && rig.isShown(4) && !rig.isHidden(0))
    #expect(!rig.isGone(0) && !rig.isGone(1) && !rig.isGone(4) && !rig.isGone(5) && rig.isGone(10))
    #expect(rig.offset(of: 2) > rig.offset(of: 0) + 8)
    #expect(rig.offset(of: 8) > hiddenEnd + 16 && rig.offset(of: 17) == secondEnd)
    // 露着的标记是淡的墨，里面的字还是粗体
    let marker = rig.attribute(.foregroundColor, at: 0) as? NSColor
    #expect(marker != nil && marker != rig.attribute(.foregroundColor, at: 6) as? NSColor)
    #expect((rig.attribute(.font, at: 0) as? NSFont)?.pointSize == 15)
    // 不是 key 了：收回去，和一开始一样窄
    rig.editor.keyChanged(false)
    #expect(rig.markers == "HH" && rig.isGone(0) && rig.offset(of: 8) == hiddenEnd)
    // 全程只动了属性
    #expect(rig.changes.isEmpty && !rig.window.notes.canUndo)
    #expect(rig.editor.selectedRange() == caret(3) && rig.editor.string == "**粗体** 后面\n*第二行* 的字")
  }

  /// 藏着的标记留在自己的行里（空字形 .null 会被排进上一行的行尾，所以用的是零宽的控制字符）：按那个字问「在哪一行」
  /// 是对的；↑↓ 从长的一行到短的一行，落在短的那一行的行尾，不会跳到再下一行；点一行的开头落在这一行
  @Test func hiddenMarkersStayOnTheirOwnLine() throws {
    // 很长的第一行 0–5 换行 6 | 短 7 换行 8 | # 9 空格 10 标题 11-12 换行 13 | > 14 空格 15 引用 16-17 换行 18 |
    // ** 19-20 粗 21 ** 22-23
    let rig = try Rig("很长的第一行\n短\n# 标题\n> 引用\n**粗**")
    rig.activate()
    rig.editor.setSelectedRange(caret(6))
    #expect(rig.markers == "--HHH" && rig.isGone(9) && rig.isGone(10) && rig.isGone(14))
    #expect(rig.isGone(15) && rig.isGone(19) && rig.isGone(20) && !rig.isGone(11))
    // 行首藏着的标记和这一行的字在同一行，不在上一行
    #expect(rig.lineTop(of: 9) == rig.lineTop(of: 11) && rig.lineTop(of: 9) > rig.lineTop(of: 7))
    #expect(
      rig.lineTop(of: 14) == rig.lineTop(of: 16) && rig.lineTop(of: 19) == rig.lineTop(of: 21))
    #expect(rig.lineTop(of: 14) > rig.lineTop(of: 11) && rig.lineTop(of: 19) > rig.lineTop(of: 16))
    // ↓：第一行行尾 → 「短」的行尾（不是标题那一行的行首）→ 标题那一行（这时它露出标记）
    rig.editor.moveDown(nil)
    #expect(rig.editor.selectedRange() == caret(8) && rig.markers == "--HHH")
    rig.editor.moveDown(nil)
    #expect((9...13).contains(rig.editor.selectedRange().location) && rig.markers == "--SHH")
    // ↑ 回去：还是「短」那一行
    rig.editor.moveUp(nil)
    #expect((7...8).contains(rig.editor.selectedRange().location) && rig.markers == "--HHH")
    // → 从「短」的行尾走一步：到标题那一行的行首（标记前面），再走就是一个字一个字地过露出来的标记
    rig.editor.setSelectedRange(caret(8))
    rig.editor.moveRight(nil)
    #expect(rig.editor.selectedRange() == caret(9) && rig.markers == "--SHH")
    rig.editor.moveRight(nil)
    #expect(rig.editor.selectedRange() == caret(10))
    // 行首 / 行尾：就是这一行的头和尾
    rig.editor.setSelectedRange(caret(17))
    rig.editor.moveToBeginningOfLine(nil)
    #expect(rig.editor.selectedRange() == caret(14))
    rig.editor.moveToEndOfLine(nil)
    #expect(rig.editor.selectedRange() == caret(18) && rig.markers == "--HSH")
    // 标记藏着时点「引用」那一行开头：光标落在这一行，不在上一行；点标题那一行行尾的空白：是它的行尾
    rig.editor.setSelectedRange(caret(0))
    #expect(rig.markers == "--HHH")
    let quote = try rig.editor.convert(rig.center(of: 16), from: nil)
    #expect(
      (14...16).contains(rig.editor.characterIndexForInsertion(at: NSPoint(x: 2, y: quote.y))))
    let heading = try rig.editor.convert(rig.center(of: 12), from: nil)
    #expect(
      rig.editor.characterIndexForInsertion(at: NSPoint(x: heading.x + 200, y: heading.y)) == 13)
    #expect(rig.changes.isEmpty && !rig.window.notes.canUndo)
  }

  /// 标记只在「选区碰到的行」露出来，而且得是：正文框拿着焦点、窗口是 key、能编辑。鼠标拖选的过程中不重排
  @Test func markersShowOnlyOnSelectedLines() throws {
    // # 0 空格 1 标 2 题 3 换行 4 | ** 5-6 粗 7 ** 8-9 空格 10 一 11 换行 12 | 没有标记 13–16 换行 17 |
    // ` 18 码 19 ` 20 空格 21 三 22
    let rig = try Rig("# 标题\n**粗** 一\n没有标记\n`码` 三")
    rig.editor.setSelectedRange(caret(2))
    #expect(rig.markers == "HH-H")
    rig.editor.keyChanged(true)
    #expect(rig.markers == "SH-H")
    // 光标换行：旧行收、新行露
    rig.editor.setSelectedRange(caret(7))
    #expect(rig.markers == "HS-H")
    rig.editor.setSelectedRange(caret(14))
    #expect(rig.markers == "HH-H")
    rig.editor.setSelectedRange(caret(22))
    #expect(rig.markers == "HH-S")
    // 多行选区：碰到的每一行都露
    rig.editor.setSelectedRange(NSRange(location: 2, length: 8))
    #expect(rig.markers == "SS-H")
    rig.editor.selectAll(nil)
    #expect(rig.markers == "SS-S")
    // 选区正好停在下一行行首（选了整行连换行）：下一行不算碰到
    rig.editor.setSelectedRange(NSRange(location: 0, length: 5))
    #expect(rig.markers == "SH-H")
    // 鼠标拖选的过程中不重排，松手才排
    rig.editor.setSelectedRanges(
      [NSValue(range: caret(19))], affinity: .downstream, stillSelecting: true)
    #expect(rig.markers == "SH-H" && rig.editor.selectedRange() == caret(19))
    rig.editor.setSelectedRanges(
      [NSValue(range: caret(19))], affinity: .downstream, stillSelecting: false)
    #expect(rig.markers == "HH-S")
    // 失去焦点全藏，拿回来再露
    #expect(rig.window.makeFirstResponder(nil) && rig.markers == "HH-H")
    #expect(rig.window.makeFirstResponder(rig.editor) && rig.markers == "HH-S")
    // 窗口不是 key 全藏：直接说的，和通知进来的（接线）
    rig.editor.keyChanged(false)
    #expect(rig.markers == "HH-H")
    rig.editor.keyChanged(true)
    #expect(rig.markers == "HH-S")
    let center = NotificationCenter.default
    center.post(name: NSWindow.didResignKeyNotification, object: rig.window)
    #expect(rig.markers == "HH-H")
    center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)
    #expect(rig.markers == "HH-S")
    // 别的窗口的通知不算
    center.post(name: NSWindow.didResignKeyNotification, object: NSObject())
    #expect(rig.markers == "HH-S")
    // 只读的不露
    rig.editor.isEditable = false
    rig.editor.setSelectedRange(caret(7))
    #expect(rig.markers == "HH-H")
    rig.editor.isEditable = true
    rig.editor.setSelectedRange(caret(8))
    #expect(rig.markers == "HS-H")
    // 「是不是鼠标在正文上按下的那一下」（点进来的那一刻先不排，等点完）：这个窗口里、落在正文上的左键按下才算
    let inside = try rig.center(of: 7)
    #expect(try rig.editor.isClick(rig.mouse(.leftMouseDown, at: inside)))
    #expect(try !rig.editor.isClick(rig.mouse(.leftMouseUp, at: inside)))
    #expect(try !rig.editor.isClick(rig.mouse(.rightMouseDown, at: inside)))
    #expect(try !rig.editor.isClick(rig.mouse(.leftMouseDown, at: NSPoint(x: -40, y: -40))))
    #expect(!rig.editor.isClick(nil))
    let elsewhere = NSEvent.mouseEvent(
      with: .leftMouseDown, location: inside, modifierFlags: [], timestamp: 0,
      windowNumber: rig.window.windowNumber + 7, context: nil, eventNumber: 0, clickCount: 1,
      pressure: 1)
    #expect(!rig.editor.isClick(elsewhere))
    // 从窗口里拿走：不再露；全程只动了属性
    rig.editor.removeFromSuperview()
    #expect(rig.markers == "HH-H")
    #expect(rig.changes.isEmpty && !rig.window.notes.canUndo)
  }

  /// 编辑在别处、光标被带走（指明位置的输入、撤销、粘贴几行、拆行、并行）：原来露着的那一行收回去，光标现在
  /// 所在的行露出来。光标没动的编辑（点别处的方框）不改变哪一行露着
  @Test func editsElsewhereMoveTheShownLine() throws {
    // ** 0-1 粗 2 ** 3-4 空格 5 一 6 换行 7 | 没有标记 8–11 换行 12 | * 13 斜 14 * 15 空格 16 三 17 换行 18 |
    // ☐ 19 空格 20 ** 21-22 任务 23-24 ** 25-26
    let text = "**粗** 一\n没有标记\n*斜* 三\n☐ **任务**"
    let rig = try Rig(text, steps: true)
    rig.activate()
    rig.editor.setSelectedRange(caret(2))
    #expect(rig.markers == "S-HH")
    // 指明位置的输入（输入法的重新转换、听写走这条路）改的是第三行，光标没被带走：露着的还是第一行
    rig.step { rig.editor.insertText("x", replacementRange: NSRange(location: 17, length: 0)) }
    #expect(rig.editor.string == "**粗** 一\n没有标记\n*斜* x三\n☐ **任务**")
    #expect(rig.editor.selectedRange() == caret(2) && rig.markers == "S-HH")
    // 撤销：改的是第三行，光标被带过去——第一行收起来，第三行露出来
    rig.window.notes.undo()
    #expect(rig.editor.string == text && rig.markers == "H-SH")
    #expect(
      NSLocationInRange(rig.editor.selectedRange().location, NSRange(location: 13, length: 6)))
    rig.window.notes.redo()
    #expect(rig.editor.string.contains("x三") && rig.markers == "H-SH")
    rig.window.notes.undo()
    // 贴进去几行：光标落在贴进去的最后一行，第一行和贴进去的带标记的行都藏着
    rig.editor.setSelectedRange(caret(6))
    #expect(rig.markers == "S-HH")
    rig.step { rig.type("甲\n`乙`\n丙") }
    #expect(rig.editor.string.hasPrefix("**粗** 甲\n`乙`\n丙一\n没有标记"))
    #expect(rig.markers == "HH--HH" && rig.isGone(0) && rig.isGone(8) && !rig.isGone(9))
    rig.window.notes.undo()
    #expect(rig.editor.string == text && rig.markers == "S-HH")
    // 把露着的那一行从中间拆开（回车）：光标在后半行，前半行收起来
    rig.editor.setSelectedRange(caret(5))
    rig.step { rig.editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    #expect(rig.editor.string.hasPrefix("**粗**\n 一\n") && rig.markers == "H--HH")
    rig.window.notes.undo()
    #expect(rig.editor.string == text && rig.markers == "S-HH")
    // 把两行并成一行（在第三行行首按退格）：并出来的这一行露着
    rig.editor.setSelectedRange(caret(13))
    #expect(rig.markers == "H-SH")
    rig.step { rig.editor.deleteBackward(nil) }
    #expect(rig.editor.string == "**粗** 一\n没有标记*斜* 三\n☐ **任务**" && rig.markers == "HSH")
    #expect(rig.editor.selectedRange() == caret(12))
    rig.window.notes.undo()
    #expect(rig.editor.string == text)
    // 点别处的方框：光标不动，露着的还是光标那一行；方框那一行的标记照样藏着
    rig.editor.setSelectedRange(caret(2))
    let box = try rig.center(of: 19)
    try rig.step { rig.editor.mouseDown(with: try rig.mouse(.leftMouseDown, at: box)) }
    #expect(rig.editor.string.hasSuffix("☑ **任务**") && rig.editor.selectedRange() == caret(2))
    #expect(rig.markers == "S-HH" && rig.isStruck(23) && rig.isGone(21))
    // 光标挪到任务行：方框后面的标记露出来，方框还是那个字体
    rig.editor.setSelectedRange(caret(24))
    #expect(rig.markers == "H-HS" && !rig.isGone(21) && rig.fontName(at: 19) == "AppleSymbols")
    #expect(rig.isStruck(21) && rig.isStruck(23))
  }

  /// 输入法组字期间属性一点不动（带标记的行上组字、组字时选区在组着的字里挪、窗口不再是 key、换了纸色），
  /// 确认之后一次补上；组着的字、刚确认的字都不带隐藏属性
  @Test func composingNeverTouchesMarkdownAttributes() throws {
    // ** 0-1 粗 2 ** 3-4 空格 5 一 6 换行 7 | * 8 斜 9 * 10 空格 11 二 12
    let rig = try Rig("**粗** 一\n*斜* 二")
    rig.activate()
    rig.editor.setSelectedRange(caret(7))
    #expect(rig.markers == "SH")
    let (first, second) = (
      rig.copy(NSRange(location: 0, length: 7)), rig.copy(NSRange(location: 7, length: 6))
    )
    func untouched(shift: Int) -> Bool {
      rig.copy(NSRange(location: 0, length: 7)).isEqual(to: first)
        && rig.copy(NSRange(location: 7 + shift, length: 6)).isEqual(to: second)
    }
    rig.compose("pin")
    #expect(rig.editor.hasMarkedText() && rig.editor.string == "**粗** 一pin\n*斜* 二")
    #expect(untouched(shift: 3) && rig.markers == "SH")
    #expect((7..<10).allSatisfy { !rig.isHidden($0) && !rig.isGone($0) })
    // 选区在组着的字里挪（输入法自己的光标）
    rig.editor.setMarkedText(
      "ping", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(rig.editor.hasMarkedText() && untouched(shift: 4) && rig.markers == "SH")
    // 窗口不再是 key、又当上：这时不收也不露，等确认
    rig.editor.keyChanged(false)
    #expect(untouched(shift: 4) && rig.markers == "SH")
    rig.editor.keyChanged(true)
    // 换了纸色（⌘. 这种）：整篇重排先欠着
    let oldInk = rig.attribute(.foregroundColor, at: 2) as? NSColor
    rig.editor.setPaper(NotePaper.all[2], fontSize: 15, markdown: true)
    #expect(untouched(shift: 4) && rig.attribute(.foregroundColor, at: 2) as? NSColor == oldInk)
    #expect(rig.changes.isEmpty)
    // 确认：欠着的整篇重排补上（新的墨色），标记照样只露光标那一行；刚确认的字看得见
    rig.type("拼")
    #expect(!rig.editor.hasMarkedText() && rig.editor.string == "**粗** 一拼\n*斜* 二")
    #expect(rig.markers == "SH" && rig.changes == ["**粗** 一拼\n*斜* 二"])
    let newInk = rig.attribute(.foregroundColor, at: 2) as? NSColor
    #expect(newInk != nil && newInk != oldInk && newInk == rig.editor.insertionPointColor)
    #expect(!rig.isHidden(7) && !rig.isGone(7) && rig.isGone(9) && !rig.isGone(0))
    // 组到一半窗口不再是 key，然后才确认：确认之后都藏着，刚确认的字照样看得见
    rig.compose("yi")
    rig.editor.keyChanged(false)
    #expect(rig.markers == "SH")
    rig.type("一")
    #expect(rig.editor.string == "**粗** 一拼一\n*斜* 二" && rig.markers == "HH")
    #expect(!rig.isHidden(8) && !rig.isGone(8) && rig.isGone(0))
    // 撤掉组字（输入法里按 Esc）：什么都没变
    rig.editor.keyChanged(true)
    let before = rig.copy(NSRange(location: 0, length: 15))
    rig.compose("er")
    rig.compose("")
    #expect(
      rig.copy(NSRange(location: 0, length: 15)).isEqual(to: before) && rig.changes.count == 2)
  }

  /// 撤掉组字（输入法里按 Esc、把拼音退格删光：setMarkedText 给空的）之后要自己收尾——系统最后那次 didChangeText
  /// 那一刻还算在组字，之后不再有。收了尾：挪光标标记跟着走；先选中一段再组字、然后撤掉（选中的字没了），
  /// 交出去的全文和看得见的一样
  @Test func cancelledCompositionIsSettled() throws {
    // ** 0-1 粗 2 ** 3-4 空格 5 一 6 换行 7 | * 8 斜 9 * 10 空格 11 二 12
    let rig = try Rig("**粗** 一\n*斜* 二")
    rig.activate()
    rig.editor.setSelectedRange(caret(7))
    #expect(rig.markers == "SH")
    rig.compose("er")
    rig.compose("")
    #expect(!rig.editor.hasMarkedText() && rig.editor.string == "**粗** 一\n*斜* 二")
    #expect(rig.changes.isEmpty && rig.markers == "SH")
    // 挪光标：旧行收、新行露（没收尾的话有「没处理完的编辑」挡着，标记冻在原地）
    rig.editor.setSelectedRange(caret(10))
    #expect(rig.markers == "HS" && rig.isGone(0) && !rig.isGone(8))
    rig.editor.setSelectedRange(caret(2))
    #expect(rig.markers == "SH")
    // 之后的编辑照常重排、照常往外写
    rig.editor.setSelectedRange(caret(10))
    rig.type("体")
    #expect(rig.editor.string == "**粗** 一\n*斜体* 二" && rig.changes == [rig.editor.string])
    #expect(rig.attribute(.obliqueness, at: 10) != nil && rig.markers == "HS")
    // 选中「粗」→ 组字（盖掉选中的字）→ 撤掉：选中的字没了——要往外写，那一行要重排（四个星号不再是标记）
    rig.editor.setSelectedRange(NSRange(location: 2, length: 1))
    rig.compose("cu")
    #expect(rig.editor.string == "**cu** 一\n*斜体* 二" && rig.changes.count == 1)
    rig.compose("")
    #expect(!rig.editor.hasMarkedText() && rig.editor.string == "**** 一\n*斜体* 二")
    #expect(rig.changes.count == 2 && rig.changes.last == rig.editor.string)
    #expect(rig.markers == "-H" && !rig.isGone(0) && !rig.isGone(3))
    // 把拼音一个个退格删光是同一条路：组着的字越来越短，最后给的是空的
    rig.editor.setSelectedRange(caret(12))
    rig.compose("xi")
    rig.compose("x")
    rig.compose("")
    rig.editor.setSelectedRange(caret(0))
    #expect(rig.markers == "-H" && rig.changes.count == 2)
    rig.editor.setSelectedRange(caret(9))
    #expect(rig.markers == "-S")
  }

  /// 兜底：改了字却没有 didChangeText 的路（真输入法可能有没模拟到的）——选区一变，发现有没收尾的编辑就排一次
  /// 下一轮的收尾（文本存储一改，系统自己就会报一次选区：实测 macOS 15.7）；转一轮之后样式、标记、交出去的全文
  /// 都跟上。正常的编辑排的那一次是空转，不多写一遍；正文框离开窗口，没跑的那一次不跑了
  @Test func leftoverEditsSettleOnTheNextTurn() throws {
    // ** 0-1 粗 2 ** 3-4 空格 5 一 6 换行 7 | * 8 斜 9 * 10 空格 11 二 12
    let rig = try Rig("**粗** 一\n*斜* 二")
    rig.activate()
    rig.editor.setSelectedRange(caret(7))
    #expect(rig.markers == "SH")
    func spin(until done: () -> Bool) {
      for _ in 0..<200 where !done() {
        RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
      }
    }
    // 不经 shouldChangeText / didChangeText，直接改文本存储：「二」换成一段行内代码
    let storage = try #require(rig.editor.textStorage)
    storage.replaceCharacters(in: NSRange(location: 12, length: 1), with: "`码`")
    #expect(rig.editor.string == "**粗** 一\n*斜* `码`")
    // 当场不动：没有 didChangeText，新的字还是基础样式、没往外写
    #expect(rig.changes.isEmpty && rig.attribute(.backgroundColor, at: 13) == nil)
    #expect(!rig.isHidden(12) && !rig.isHidden(14))
    // 转一轮：收尾了——改过的行重排了（光标不在那一行，反引号藏起来）、全文交出去了
    spin { !rig.changes.isEmpty }
    #expect(rig.changes == ["**粗** 一\n*斜* `码`"] && rig.markers == "SH")
    #expect(rig.attribute(.backgroundColor, at: 13) != nil && rig.isGone(12) && rig.isGone(14))
    // 之后挪光标，标记跟着走
    rig.editor.setSelectedRange(caret(13))
    #expect(rig.markers == "HS" && rig.isShown(12) && rig.isShown(14))
    // 正常的编辑中途的选区变化也排了一次：到它跑的时候早收过尾了，是空转——不多写、不动属性
    rig.type("x")
    #expect(rig.changes.count == 2)
    let before = rig.copy(NSRange(location: 0, length: storage.length))
    var turns = 0
    spin {
      turns += 1
      return turns > 5
    }
    #expect(rig.changes.count == 2)
    #expect(rig.copy(NSRange(location: 0, length: storage.length)).isEqual(to: before))
    // 从窗口里拿走：没跑的那一次不跑了
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "甲")
    rig.editor.removeFromSuperview()
    turns = 0
    spin {
      turns += 1
      return turns > 5
    }
    #expect(rig.changes.count == 2 && rig.editor.string.hasPrefix("甲**粗**"))
  }

  /// 一个字一个字打出几行带标记的字（中间回车换行），再用输入法一行一行上屏：每一下之后，刚打进去的字都不带
  /// 隐藏属性、字形不是空的（Noty 踩过：连打几行，新打的字看不见）；光标所在的行不藏，离开的行收起来
  @Test func typedTextIsNeverHidden() throws {
    let lines = [
      "# 标题", "**粗** 和 `码`", "[字](https://a.b) *斜*", "> 引用 ~~删~~", "**任务** 之后", "普通的字",
    ]
    for composes in [false, true] {
      let rig = try Rig("")
      rig.activate()
      for line in lines {
        let pieces = composes ? [line] : line.map(String.init)
        for piece in pieces {
          if composes {
            rig.compose("pinyin")
            #expect(rig.changes.last?.contains("pinyin") != true)
          }
          rig.type(piece)
          let caret = rig.editor.selectedRange().location
          let length = (piece as NSString).length
          #expect(
            ((caret - length)..<caret).allSatisfy { !rig.isHidden($0) && !rig.isGone($0) },
            "\(line) · \(piece)")
          // 光标所在的行（最后一行）不藏；前面的行没有露着的
          #expect(rig.markers.last != "H" && rig.markers.last != "X", "\(line) · \(piece)")
          #expect(!rig.markers.dropLast().contains("S") && !rig.markers.contains("X"))
        }
        // 这一行打完：有标记的行露着
        #expect(rig.markers.last == (line == "普通的字" ? "-" : "S"), "\(line)")
        rig.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        // 回车之后光标在新的空行上：上面的都收起来了
        #expect(!rig.markers.contains("S") && !rig.markers.contains("X"), "\(line)")
      }
      #expect(rig.editor.string == lines.joined(separator: "\n") + "\n")
      #expect(rig.markers == "HHHHH-" && rig.changes.last == rig.editor.string)
    }
  }

  /// 链接：这一点上有没有能打开的链接；⌘ 点才打开（普通点击照常放光标），不是 key 的面板里 ⌘ 点第一下就算
  @Test func commandClickOpensLinks() throws {
    // 看 0 空格 1 [ 2 这里 3-4 ] 5 …
    let text = "看 [这里](https://example.com/a) 和 [本地](file:///etc/hosts) 的字"
    let rig = try Rig(text)
    var opened: [URL] = []
    rig.editor.onOpenLink = { opened.append($0) }
    let target = try #require(URL(string: "https://example.com/a"))
    let local = (text as NSString).range(of: "本地").location
    func point(_ index: Int) throws -> NSPoint {
      rig.editor.convert(try rig.center(of: index), from: nil)
    }
    // 标记藏着的时候（平时）和露着的时候都点得中
    #expect(try rig.isGone(2) && rig.editor.link(at: point(3)) == target)
    #expect(try rig.editor.link(at: point(4)) == target)
    // 不是链接的字、打不开的地址（只有下划线）、行尾的空白、正文下面的空白：都没有
    #expect(try rig.editor.link(at: point(0)) == nil && rig.editor.link(at: point(local)) == nil)
    #expect(rig.attribute(.underlineStyle, at: local) != nil)
    let end = try point(text.utf16.count - 1)
    #expect(rig.editor.link(at: NSPoint(x: end.x + 60, y: end.y)) == nil)
    #expect(try rig.editor.link(at: NSPoint(x: point(3).x, y: end.y + 120)) == nil)

    let on = try rig.center(of: 3)
    let plain = try rig.mouse(.leftMouseDown, at: on)
    let command = try rig.mouse(.leftMouseDown, at: on, flags: .command)
    // 普通点击、带别的修饰键的：不开（交给文本视图放光标 / 扩选）
    #expect(rig.editor.linkToOpen(by: plain) == nil)
    #expect(
      try rig.editor.linkToOpen(by: rig.mouse(.leftMouseDown, at: on, flags: [.command, .shift]))
        == nil)
    #expect(try rig.editor.linkToOpen(by: rig.mouse(.leftMouseDown, at: on, flags: .option)) == nil)
    #expect(rig.editor.linkToOpen(by: command) == target)
    // ⌘ 点在打不开的地址、普通的字上：不开
    #expect(
      try rig.editor.linkToOpen(
        by: rig.mouse(.leftMouseDown, at: rig.center(of: local), flags: .command)) == nil)
    #expect(
      try rig.editor.linkToOpen(
        by: rig.mouse(.leftMouseDown, at: rig.center(of: 0), flags: .command))
        == nil)
    // 不是 key 的窗口里第一下就算；普通点击照文本视图自己的规矩
    #expect(!rig.window.isKeyWindow && rig.editor.acceptsFirstMouse(for: command))
    #expect(opened.isEmpty)
    rig.editor.setSelectedRange(caret(0))
    rig.editor.mouseDown(with: command)
    #expect(opened == [target] && rig.editor.selectedRange() == caret(0) && rig.changes.isEmpty)
    // 光标在这一行、标记露着（字往右挪了）：照样点得中
    rig.editor.keyChanged(true)
    rig.editor.setSelectedRange(caret(1))
    #expect(try !rig.isGone(2) && rig.editor.link(at: point(3)) == target)
    rig.editor.mouseDown(
      with: try rig.mouse(.leftMouseDown, at: try rig.center(of: 4), flags: .command))
    #expect(opened == [target, target])
    // 把链接删坏（去掉「]」）：这一段的下划线、记着的地址都清干净，点不开了；同一行后面那个链接还在
    rig.editor.insertText("", replacementRange: NSRange(location: 5, length: 1))
    #expect(rig.editor.string.hasPrefix("看 [这里(https://example.com/a) 和 [本地]("))
    #expect(rig.attribute(.underlineStyle, at: 3) == nil)
    #expect(rig.attribute(NoteStyles.linkKey, at: 3) == nil && rig.attribute(.link, at: 3) == nil)
    #expect(try rig.editor.link(at: point(3)) == nil)
    #expect(
      try rig.editor.linkToOpen(
        by: rig.mouse(.leftMouseDown, at: rig.center(of: 3), flags: .command)) == nil)
    #expect(rig.attribute(.underlineStyle, at: local - 1) != nil && opened.count == 2)
  }

  /// 设置里的开关：关掉后正文照原样显示（没有任何 Markdown 的属性、字形都在），任务照常；再打开整篇补回来。
  /// 来回切只动属性
  @Test func theSwitchTurnsMarkdownOffAndKeepsTasks() throws {
    // # 0 空格 1 标题 2-3 换行 4 | ** 5-6 粗 7 ** 8-9 空格 10 [ 11 字 12 ] 13 (https://a.b) 14–26 换行 27 |
    // ☑ 28 空格 29 做完 30-31 空格 32 ** 33-34 粗 35 ** 36-37 换行 38 | > 39 空格 40 引用 41-42
    let text = "# 标题\n**粗** [字](https://a.b)\n☑ 做完 **粗**\n> 引用"
    let rig = try Rig(text)
    rig.activate()
    rig.editor.setSelectedRange(caret(2))
    #expect(rig.markers == "SHHH" && rig.isGone(5) && rig.isGone(33))
    #expect((rig.attribute(.font, at: 2) as? NSFont)?.pointSize == 24)
    let keys: [NSAttributedString.Key] = [
      NoteStyles.hiddenKey, NoteStyles.shownKey, NoteStyles.linkKey, NoteStyles.quoteKey,
      .underlineStyle, .obliqueness, .backgroundColor, .paragraphStyle,
    ]
    func markdownAttributes() -> [String] {
      guard let storage = rig.editor.textStorage else { return [] }
      return keys.filter { key in
        var found = false
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) {
          value, _, _ in
          found = found || value != nil
        }
        return found
      }.map(\.rawValue)
    }
    #expect(markdownAttributes().count >= 5)
    rig.editor.setPaper(NotePaper.all[0], fontSize: 15, markdown: false)
    #expect(markdownAttributes().isEmpty && rig.markers == "----")
    #expect((0..<text.utf16.count).allSatisfy { !rig.isGone($0) })
    #expect((rig.attribute(.font, at: 2) as? NSFont)?.pointSize == 15)
    #expect(
      (rig.attribute(.font, at: 7) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold)
        == false)
    // 任务照常：方框的字体、做完的划线
    #expect(rig.fontName(at: 28) == "AppleSymbols" && rig.isStruck(30) && rig.isStruck(35))
    // 关着的时候打字、换行、挪光标：都不出 Markdown 的样式
    rig.editor.setSelectedRange(caret(43))
    rig.type("\n*斜* `码`")
    rig.editor.setSelectedRange(caret(0))
    #expect(markdownAttributes().isEmpty && rig.changes.count == 1)
    // 再打开：整篇补回来，光标所在的行露着
    rig.editor.setPaper(NotePaper.all[0], fontSize: 15, markdown: true)
    #expect(rig.markers == "SHHHH" && rig.isGone(5) && rig.isGone(33) && rig.isGone(44))
    #expect((rig.attribute(.font, at: 2) as? NSFont)?.pointSize == 24)
    #expect(rig.attribute(NoteStyles.linkKey, at: 12) as? URL == URL(string: "https://a.b"))
    #expect(rig.changes.count == 1 && rig.editor.selectedRange() == caret(0))
    // 撤销栈里只有那一次打字
    rig.window.notes.undo()
    #expect(rig.editor.string == text && !rig.window.notes.canUndo)
  }

  /// 共用的正文框跟着设置里的开关走（偏好一变，开着的编辑器整篇重排）。用临时的偏好域，不碰用户的
  @Test func bodyFieldFollowsTheMarkdownPreference() throws {
    let suite = "kitty-note-markdown-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let note = Note(id: "便签乙", body: "# 标题 **粗**", createdAt: .now, modifiedAt: .now)
    let frame = CGRect(x: -30000, y: -30000, width: 460, height: 380)
    try #require(
      !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: NoteBodyField(
        note: note, fontSize: 15, margin: 14, setBody: { _ in }, onOverflow: {}
      )
      .defaultAppStorage(defaults))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let editor = try #require(NoteDeck.editor(for: note.id, in: host))
    func isHidden() -> Bool {
      editor.textStorage?.attribute(NoteStyles.hiddenKey, at: 0, effectiveRange: nil) != nil
    }
    // 没存过 = 默认开
    #expect(isHidden() && !window.isKeyWindow)
    defaults.set(false, forKey: Prefs.notesMarkdown)
    for _ in 0..<200 where isHidden() {
      RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
      host.layoutSubtreeIfNeeded()
    }
    #expect(!isHidden())
    #expect(
      (editor.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize == 15
    )
    defaults.set(true, forKey: Prefs.notesMarkdown)
    for _ in 0..<200 where !isHidden() {
      RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01))
      host.layoutSubtreeIfNeeded()
    }
    #expect(isHidden() && editor.string == note.body)
  }
}
