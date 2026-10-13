// 便签专用的正文编辑器（Notes/NoteTextView.swift，PLAN §10「便签」第 5 批）在屏外窗口里的行为：
// TextKit 1 的栈、点方框换字且进撤销栈、样式只改属性（不进撤销栈、不动选区、只重排受影响的行）、输入法组字期间
// 不重排不往外写而确认后补上（setMarkedText 模拟）、超上限拦下、按编号认和拿焦点、撤销栈是窗口给的那一个、
// 回车续行 / Tab 缩进 / 打「- [ ]」自动转换 / ⌘T、Esc 先关查找条、查找条不当 key 也出得来、右键菜单的「任务」。
// 窗口都摆在离所有屏幕很远的地方（先确认不和任何屏相交）、**不当 key**；不发任何合成的鼠标键盘事件——事件对象只是
// 直接交给视图的方法。不碰偏好和便签库。

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
      editor.setPaper(NotePaper.all[0], fontSize: 15)
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

    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
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
    rig.editor.setPaper(NotePaper.all[3], fontSize: 17)
    #expect(rig.attribute(.toolTip, at: 12) == nil)
    #expect((rig.attribute(.font, at: 2) as? NSFont)?.pointSize == 17)
    #expect(rig.isStruck(7) && rig.fontName(at: 0) == "AppleSymbols")
    #expect(!rig.window.notes.canUndo && rig.window.notes.canRedo)
    #expect(rig.editor.selectedRange() == caret(3) && rig.changes.count == changes)
    // 同样的纸色字号再给一遍：不动
    storage.addAttribute(.toolTip, value: "记号", range: NSRange(location: 12, length: 2))
    rig.editor.setPaper(NotePaper.all[3], fontSize: 17)
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
}
