// 便签的两块能当 key 的面板——屏幕边缘那叠（NoteDeckPanel）和浮动便签（NoteFloatPanel）——共用的按键入口
// （规矩在 mac-overlay-panel §3 §12）。它不是又一种浮层、不单独用：只为那两块不各抄一份。
// - 无边框的面板默认当不了 key（收不到按键）：这里放开；永远不当 main、不激活本 App。
// - 按键照 mac-overlay-panel §3：⌘ 组合先给 keyEquivalentHandler（⌘W ⌘P ⌘K ⌘. ⌘T ⌘F ⇧⌘A），剩下的编辑键
//   （⌘C ⌘V ⌘X ⌘A）直接发给输入框（本 App 不激活，主菜单收不到）；Esc 是 cancelOperation（输入框里的经 doCommandBy
//   转过来——输入法组字时 Esc 归输入法，到不了这里），**不装本地按键监听去抢**；操作菜单开着时焦点在面板自己身上，
//   方向键和回车走 keyDown → keyDownHandler。
// - 撤销：⌘Z / ⇧⌘Z 直接动焦点所在输入框的撤销栈（OverlayPanel.undoRedo → NSWindow.undoFocusedText）——正文是这条
//   便签自己的（NoteTextView.noteUndo = NoteSheetModel.textUndo，换一条换一个），标题框是它的字段编辑器的。
//   **面板不重写 undoManager**：那叠的面板原来重写过，文本视图登记在重写的那个上，而 ⌘Z 发出去的 undo: 到头是
//   NSWindow 接、它动的是窗口内部的另一个栈——正文里的撤销因此一直不灵（2026-10-13 用户报，实测确认）。
// - 失去 key（切到别的 App、点了别的窗口）：报一声，攒着的改动落盘。

import AppKit
import Carbon.HIToolbox

class NotePanel: NSPanel {
  /// ⌘ 组合键先给它，返回 true = 处理了
  var keyEquivalentHandler: ((NSEvent) -> Bool)?
  /// 焦点不在输入框里时的按键（操作菜单开着时的 ↑↓ ↩ ← →）
  var keyDownHandler: ((NSEvent) -> Bool)?
  var onCancel: () -> Void = {}
  var onResignKey: () -> Void = {}

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event) {
      return true
    }
    // ⌘Z / ⇧⌘Z：焦点所在的输入框自己的撤销栈（正文是这条便签的那一个）
    if let done = OverlayPanel.undoRedo(event, in: self) { return done }
    // 不看 Caps Lock（同 OverlayPanel）
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
      let action = OverlayPanel.editActions[event.charactersIgnoringModifiers?.lowercased() ?? ""]
    else { return false }
    return OverlayPanel.sendEditAction(action, from: self)
  }

  override func cancelOperation(_ sender: Any?) { onCancel() }

  override func keyDown(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Escape { return cancelOperation(nil) }
    if keyDownHandler?(event) != true { super.keyDown(with: event) }
  }

  override func resignKey() {
    super.resignKey()
    onResignKey()
  }
}
