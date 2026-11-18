// 浮层里的撤销 / 重做（2026-10-13：原来没有任何地方接 ⇧⌘Z）：⌘Z / ⇧⌘Z 的事件交给面板的 performKeyEquivalent，
// 焦点所在输入框里打的字回去、再回来——多行的（SourceTextView：翻译原文框、剪贴板的编辑对话框）和单行的
// （CommandTextField：字段编辑器自己的栈）。面板只建不显示、不当 key；事件对象直接交给面板，不往系统里发。
// 另有 macOS 27 的「排版里改高度，contentView 和窗口差一截」（2026-10-17）。
// 另有输入法组字的回报（issue #16）：组着的字确认前不进绑定，两种输入框都要报「在组字」，外面自己画的占位据此藏起来；
// 报了之后那次重画不能拿绑定盖掉组到一半的拼音（issue #30：打 zhe 只剩 he）。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

struct OverlayPanelTests {
  /// 内容要的高度：变了就让面板改高（同启动器的 model.resize）
  @Observable fileprivate final class Resizing {
    var height: CGFloat = 260
    @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }
  }

  private struct ResizingView: View {
    let model: Resizing
    var body: some View {
      Color.clear.frame(height: model.height)
        .onChange(of: model.height, initial: true) { model.resize(model.height) }
    }
  }

  private final class Draft {
    var text = "原文"
    var name = ""
  }

  @Observable fileprivate final class ComposingDraft {
    var text = ""
    var composing = false
  }

  private struct ComposingView: View {
    @Bindable var draft: ComposingDraft

    var body: some View {
      // 用字号确认 updateNSView 真跑过，不能只查回调（普通的日志数组不会触发 SwiftUI 刷新）。
      SourceTextView(
        text: $draft.text, submitsOnEnter: false, fontSize: draft.composing ? 15 : 14,
        onComposingChange: { draft.composing = $0 })
    }
  }

  private func undoKey(redo: Bool = false, in window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: redo ? [.command, .shift] : .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "z",
        charactersIgnoringModifiers: redo ? "Z" : "z", isARepeat: false,
        keyCode: UInt16(kVK_ANSI_Z)))
  }

  private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    return (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
  }

  /// macOS 27：窗口自己排版的半路内容要改高度（启动器、翻译浮窗的 setContentHeight），要排完再改。没修时排完
  /// contentView 多出 / 少了一次改动量（变高 100 → 260 得 420，变矮 260 → 150 得 40：内容上下被裁），order 时玻璃底的
  /// 约束还会把窗口改成过时的高度（412 收起、变 172 再 order，窗口停在 250）。排版直接调 layoutIfNeeded（order 里也是它）；
  /// order 那段放在屏外、全透明、不当 key
  @Test func resizeDuringLayoutWaitsUntilLaidOut() {
    let content = Resizing()
    let panel = OverlayPanel(
      size: NSSize(width: 320, height: 100), autoHide: .clickOutside, isPinned: { false },
      content: ResizingView(model: content))
    content.resize = { [unowned panel] in panel.setContentHeight($0) }
    func fits(_ height: CGFloat) -> Bool {
      panel.frame.height == height && panel.contentView?.frame.size == panel.frame.size
    }
    for height: CGFloat in [260, 150, 330] {
      content.height = height
      panel.layoutIfNeeded()
      #expect(fits(height), "排版里改成 \(height)")
    }
    panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    panel.alphaValue = 0
    for height: CGFloat in [412, 172] {
      content.height = height
      panel.orderFrontRegardless()
      #expect(fits(height), "order 里改成 \(height)")
      panel.orderOut(nil)
    }
    #expect(!panel.isVisible && !panel.isKeyWindow)
  }

  @Test func undoAndRedoKeysReachTheFocusedInput() throws {
    let draft = Draft()
    let panel = OverlayPanel(
      size: NSSize(width: 400, height: 260), autoHide: .clickOutside, isPinned: { false },
      content: VStack {
        CommandTextField(
          text: Binding {
            draft.name
          } set: {
            draft.name = $0
          }, placeholder: "名称")
        SourceTextView(
          text: Binding {
            draft.text
          } set: {
            draft.text = $0
          }, submitsOnEnter: false)
      })
    panel.contentView?.layoutSubtreeIfNeeded()
    #expect(!panel.isVisible && !panel.isKeyWindow)
    func press(redo: Bool = false) throws -> Bool {
      panel.performKeyEquivalent(with: try undoKey(redo: redo, in: panel))
    }
    func insert(_ text: String, into view: NSTextView) {
      view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    // 多行输入框
    let editor = try #require(find(SourceTextView.FocusTextView.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(editor) && editor.string == "原文")
    #expect(panel.focusedTextUndo === editor.undoManager)
    #expect(try !press() && !press(redo: true))  // 没有可撤销 / 重做的：不算处理了
    insert("加的字", into: editor)
    #expect(draft.text == "原文加的字")
    #expect(try press() && draft.text == "原文" && editor.string == "原文")
    #expect(try press(redo: true) && draft.text == "原文加的字")
    #expect(try !press(redo: true))
    // 单行输入框：字段编辑器自己的栈，多行框里打的字不动
    let field = try #require(find(CommandTextField.FocusField.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(field))
    let fieldEditor = try #require(field.currentEditor() as? NSTextView)
    insert("片段名", into: fieldEditor)
    #expect(draft.name == "片段名")
    #expect(try press() && draft.name == "" && draft.text == "原文加的字")
    #expect(try press(redo: true) && draft.name == "片段名")
    // 焦点不在输入框里：不归这条路（照原来的走）；别的键也不归它
    panel.makeFirstResponder(nil)
    #expect(OverlayPanel.undoRedo(try undoKey(in: panel), in: panel) == nil)
    #expect(panel.makeFirstResponder(editor))
    let other = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: "c",
        charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)))
    #expect(OverlayPanel.undoRedo(other, in: panel) == nil)
    let optioned = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: "z",
        charactersIgnoringModifiers: "z", isARepeat: false, keyCode: UInt16(kVK_ANSI_Z)))
    #expect(OverlayPanel.undoRedo(optioned, in: panel) == nil)
  }

  /// 组字开始、确认、撤掉（给空的）、焦点走了：每次变了才报；组着的拼音不进绑定（不然一撤掉，绑定里留着拼音）
  @Test func composingIsReportedWhileTextStaysUncommitted() throws {
    final class Log {
      var multi: [Bool] = []
      var single: [Bool] = []
    }
    let log = Log()
    let draft = Draft()
    draft.text = ""
    let panel = OverlayPanel(
      size: NSSize(width: 400, height: 260), autoHide: .clickOutside, isPinned: { false },
      content: VStack {
        CommandTextField(
          text: Binding {
            draft.name
          } set: {
            draft.name = $0
          }, placeholder: "", onComposingChange: { log.single.append($0) })
        SourceTextView(
          text: Binding {
            draft.text
          } set: {
            draft.text = $0
          }, submitsOnEnter: false, onComposingChange: { log.multi.append($0) })
      })
    panel.contentView?.layoutSubtreeIfNeeded()
    let none = NSRange(location: NSNotFound, length: 0)
    func mark(_ text: String, in view: NSTextView) {
      view.setMarkedText(
        text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
        replacementRange: none)
    }
    func spin() {
      for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01)) }
    }
    // 多行输入框：在 NSTextView 子类里当场报
    let editor = try #require(find(SourceTextView.FocusTextView.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(editor))
    mark("n", in: editor)
    mark("ni", in: editor)
    #expect(log.multi == [true] && editor.string == "ni" && draft.text == "")
    editor.insertText("你", replacementRange: none)
    #expect(log.multi == [true, false] && draft.text == "你")
    mark("h", in: editor)
    mark("", in: editor)
    #expect(log.multi == [true, false, true, false] && draft.text == "你")
    // 单行输入框：组字改的是窗口共用的字段编辑器，听它的选区变化
    let field = try #require(find(CommandTextField.FocusField.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(field))
    let fieldEditor = try #require(field.currentEditor() as? NSTextView)
    mark("n", in: fieldEditor)
    #expect(log.single == [true] && draft.name == "")
    mark("", in: fieldEditor)
    spin()
    #expect(log.single == [true, false] && draft.name == "")
    mark("h", in: fieldEditor)
    fieldEditor.insertText("好", replacementRange: none)
    spin()
    #expect(log.single == [true, false, true, false] && draft.name == "好")
    // 组字中焦点走了：不再算在组字
    mark("a", in: fieldEditor)
    #expect(log.single.last == true)
    #expect(panel.makeFirstResponder(editor))
    spin()
    #expect(log.single.last == false)
    #expect(log.multi == [true, false, true, false])
  }

  /// issue #30：组字一开始就报「在组字」，外面藏占位的 @State 跟着变、SwiftUI 重画一轮——这一轮里输入框不能拿绑定里的
  /// 旧字（组着的字确认前不进绑定）把框里的盖掉，不然输入法组到一半的拼音被冲掉：打 zhe 只剩 he，每个字的第一个字母都丢。
  /// 便签的标题框（CommandTextField）也一样：组字中写 stringValue 会先把拼音当字母确认掉，打成「z和」。
  /// 用真的面板和视图：快速记一条的正文（SourceTextView）、便签的标题（CommandTextField）和正文（NoteTextView，
  /// 本来就认 reported、没坏，一起锁住），空着时开始组字、已经有字时再组一次
  @Test func composingSurvivesTheRedrawItTriggers() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let capture = NoteCaptureModel(store: store)
    let id = store.create(now: .now).id
    let panel = OverlayPanel(
      size: NSSize(width: Style.listPanelWidth, height: 520), autoHide: .clickOutside,
      isPinned: { false },
      content: VStack {
        NoteCaptureView(model: capture)
        NoteEditing(store: store, id: id)
      })
    panel.contentView?.layoutSubtreeIfNeeded()
    let none = NSRange(location: NSNotFound, length: 0)
    func mark(_ text: String, in view: NSTextView) {
      view.setMarkedText(
        text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
        replacementRange: none)
    }
    func spin() {
      for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.01)) }
      panel.contentView?.layoutSubtreeIfNeeded()
    }
    /// 空着时组 zhe、确认成「这」，再组 s：每一步重画之后拼音都还在框里
    func typePinyin(in view: NSTextView, _ name: Comment) {
      for pinyin in ["z", "zh", "zhe"] {
        mark(pinyin, in: view)
        spin()
        #expect(view.hasMarkedText() && view.string == pinyin, name)
      }
      view.insertText("这", replacementRange: none)
      spin()
      #expect(!view.hasMarkedText() && view.string == "这", name)
      mark("s", in: view)
      spin()
      #expect(view.hasMarkedText() && view.string == "这s", name)
      view.insertText("是", replacementRange: none)
      spin()
      #expect(view.string == "这是", name)
    }
    let captureEditor = try #require(find(SourceTextView.FocusTextView.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(captureEditor))
    typePinyin(in: captureEditor, "快速记一条的正文")
    #expect(capture.draft == "这是")
    // 外面真改了的照样换（组字中点了「记下」：草稿清空），拼音不留在框里
    mark("x", in: captureEditor)
    capture.draft = ""
    spin()
    #expect(!captureEditor.hasMarkedText() && captureEditor.string == "")
    // 第一个是快速记一条自己的标题框（没接 onComposingChange），要的是便签的那个
    func fields(in view: NSView) -> [CommandTextField.FocusField] {
      [view as? CommandTextField.FocusField].compactMap { $0 } + view.subviews.flatMap(fields)
    }
    let content = try #require(panel.contentView)
    let title = try #require(fields(in: content).last)
    #expect(panel.makeFirstResponder(title))
    let titleEditor = try #require(title.currentEditor() as? NSTextView)
    typePinyin(in: titleEditor, "便签的标题")
    #expect(store.note(id)?.title == "这是")
    let body = try #require(find(NoteTextView.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(body))
    typePinyin(in: body, "便签的正文")
    store.flush()
    #expect(store.note(id)?.body == "这是")
  }

  /// 便签的标题框和正文框，写进仓库、按仓库里的这条重画（同全部便签窗口、屏幕边缘那叠）
  private struct NoteEditing: View {
    let store: NoteStore
    let id: String
    var body: some View {
      if let note = store.note(id) {
        NoteTitleField(
          note: note, setTitle: { store.setTitle($0, of: id) }, onCommand: { _ in false })
        NoteBodyField(
          note: note, fontSize: 15, margin: 18, setBody: { store.setBody($0, of: id) },
          onOverflow: {}
        )
        .frame(height: 120)
      }
    }
  }

  /// 每个字的首个拼音、后续拼音、确认 / 取消后再组字，都要经得住 SwiftUI 更新；选中文字重输也一样。
  @Test func swiftUIUpdatesPreserveMarkedText() throws {
    let draft = ComposingDraft()
    let panel = OverlayPanel(
      size: NSSize(width: 400, height: 260), autoHide: .clickOutside, isPinned: { false },
      content: ComposingView(draft: draft))
    panel.contentView?.layoutSubtreeIfNeeded()
    let editor = try #require(find(SourceTextView.FocusTextView.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(editor))
    let none = NSRange(location: NSNotFound, length: 0)
    func refresh() {
      panel.layoutIfNeeded()
      #expect(editor.font?.pointSize == (draft.composing ? 15 : 14))
      #expect(!panel.isVisible && !panel.isKeyWindow)
    }
    func mark(_ pinyin: String, after prefix: String) {
      editor.setMarkedText(
        pinyin, selectedRange: NSRange(location: pinyin.utf16.count, length: 0),
        replacementRange: none)
      refresh()
      #expect(draft.composing && editor.hasMarkedText())
      #expect(draft.text == prefix && editor.string == prefix + pinyin)
      #expect(
        editor.markedRange() == NSRange(location: prefix.utf16.count, length: pinyin.utf16.count))
      #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
    }
    for (pinyin, character) in [("zhe", "这"), ("shi", "是"), ("shen", "什"), ("me", "么")] {
      let prefix = draft.text
      for count in 1...pinyin.count { mark(String(pinyin.prefix(count)), after: prefix) }
      editor.insertText(character, replacementRange: none)
      refresh()
      #expect(!draft.composing && !editor.hasMarkedText())
      #expect(draft.text == prefix + character && editor.string == draft.text)
    }
    #expect(draft.text == "这是什么")
    mark("qu", after: "这是什么")
    editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
    refresh()
    #expect(!draft.composing && !editor.hasMarkedText())
    #expect(draft.text == "这是什么" && editor.string == draft.text)
    // 从绑定换成非空文字照常生效；选中末字后组字，不让旧文把候选盖回去。
    draft.text = "重输字"
    refresh()
    #expect(editor.string == "重输字")
    editor.setSelectedRange(NSRange(location: 2, length: 1))
    editor.setMarkedText(
      "z", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
    refresh()
    #expect(draft.text == "重输字" && editor.string == "重输z" && editor.hasMarkedText())
    editor.insertText("中", replacementRange: none)
    refresh()
    #expect(draft.text == "重输中" && editor.string == draft.text && !draft.composing)
    draft.text = ""
    refresh()
    #expect(editor.string.isEmpty)
  }
}
