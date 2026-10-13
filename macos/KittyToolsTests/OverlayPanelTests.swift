// 浮层里的撤销 / 重做（2026-10-13：原来没有任何地方接 ⇧⌘Z）：⌘Z / ⇧⌘Z 的事件交给面板的 performKeyEquivalent，
// 焦点所在输入框里打的字回去、再回来——多行的（SourceTextView：翻译原文框、剪贴板的编辑对话框）和单行的
// （CommandTextField：字段编辑器自己的栈）。面板只建不显示、不当 key；事件对象直接交给面板，不往系统里发。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

struct OverlayPanelTests {
  private final class Draft {
    var text = "原文"
    var name = ""
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
}
