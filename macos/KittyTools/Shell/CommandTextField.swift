// 单行输入框（包一层 NSTextField）：方向键 / 回车 / Tab / ⇧Tab / ← → / ⌫ / Esc 走 doCommandBy（全部转给 onCommand，
// 返回 false 就交还字段编辑器照常处理）。输入法组字期间这些键由输入法消费、不会回调过来，所以不需要吞键 hack。
// 挂进窗口时把自己设为 initialFirstResponder，浮层显示时自动聚焦；拿到焦点时插入点和选中底色设成品牌粉。
// onFocusChange：焦点进出时回调（外面的输入框底据此画 Whisker 焦点环）。
// romanOnly：聚焦时只允许英文类输入法（系统自动切过去，离开后恢复）。

import AppKit
import SwiftUI

struct CommandTextField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  /// 面板里的对话框输入框：出现时抢焦点，消失时把焦点还给面板的主输入框（搜索框）
  var isDialogField = false
  var fontSize: CGFloat = 14
  /// 只用英文类输入法（启动器的「呼出时切英文输入法」）
  var romanOnly = false
  /// 返回 true 表示已处理（moveUp: / moveDown: / insertNewline: / cancelOperation: …）。
  /// 没处理的 cancelOperation: 交给窗口（浮层据此关闭）
  var onCommand: (Selector) -> Bool = { _ in false }
  /// 焦点进出（画焦点环用）
  var onFocusChange: ((Bool) -> Void)?

  func makeNSView(context: Context) -> FocusField {
    let field = FocusField()
    field.isDialogField = isDialogField
    field.placeholderString = placeholder
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: fontSize)
    field.cell?.usesSingleLineMode = true
    field.cell?.lineBreakMode = .byTruncatingTail
    field.delegate = context.coordinator
    field.onFocusChange = onFocusChange
    return field
  }

  func updateNSView(_ field: FocusField, context: Context) {
    context.coordinator.parent = self
    field.onFocusChange = onFocusChange
    if field.placeholderString != placeholder { field.placeholderString = placeholder }
    if field.romanOnly != romanOnly {
      field.romanOnly = romanOnly
      field.applyInputSources()
    }
    guard field.stringValue != text else { return }
    field.stringValue = text
    // 程序改的文字（Tab 补全、清空）：光标放到末尾，接着打字
    if let editor = field.currentEditor() {
      editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: CommandTextField
    init(parent: CommandTextField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      if parent.onCommand(selector) { return true }
      if selector == #selector(NSResponder.cancelOperation(_:)) {
        control.window?.cancelOperation(nil)
        return true
      }
      return false
    }
  }

  final class FocusField: NSTextField {
    var isDialogField = false
    var romanOnly = false
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
      guard super.becomeFirstResponder() else { return false }
      applyInputSources()
      applyBrandColors()
      reportFocus()
      return true
    }

    /// 字段编辑器交出焦点（焦点去了别处）
    override func textDidEndEditing(_ notification: Notification) {
      super.textDidEndEditing(notification)
      reportFocus()
    }

    /// 晚一拍（下一轮 run loop）、按那时的第一响应者报：焦点常在 SwiftUI 插入 / 移除视图的更新中途变，当场改状态
    /// 会出警告；字段编辑器接手时 NSTextField 自己会先 resign，所以只认字段编辑器
    private func reportFocus() {
      if onFocusChange != nil { perform(#selector(reportFocusNow), with: nil, afterDelay: 0) }
    }

    @objc private func reportFocusNow() {
      let editor = currentEditor()
      onFocusChange?(editor != nil && window?.firstResponder === editor)
    }

    /// 插入点和选中文字底色用品牌粉（mac-overlay-panel §3）。字段编辑器是窗口共用的，别处可能改过，
    /// 所以每次拿到焦点都设一遍，不露系统蓝
    private func applyBrandColors() {
      guard let editor = currentEditor() as? NSTextView else { return }
      editor.insertionPointColor = NSColor(Style.brand)
      editor.selectedTextAttributes = [
        .backgroundColor: Style.Shot.accent.withAlphaComponent(0.28)
      ]
    }

    /// 输入法限制挂在正在编辑的字段编辑器上（它是这个窗口共用的，所以关掉时要显式还原成不限制）
    func applyInputSources() {
      currentEditor()?.inputContext?.allowedInputSourceLocales =
        romanOnly ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if isDialogField {
        window?.makeFirstResponder(self)
      } else {
        window?.initialFirstResponder = self
      }
    }

    /// 消失时还焦点，但焦点已经在别的输入框里（刚打开的新框、已经还给主输入框）就不抢回来
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if isDialogField, newWindow == nil, let window,
        !(window.firstResponder is NSText) || window.firstResponder === currentEditor()
      {
        window.makeFirstResponder(window.initialFirstResponder)
      }
      super.viewWillMove(toWindow: newWindow)
    }
  }
}
