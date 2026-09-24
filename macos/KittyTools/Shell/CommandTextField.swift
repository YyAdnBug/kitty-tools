// 单行输入框（包一层 NSTextField）：方向键 / 回车 / Tab / Esc 走 doCommandBy。输入法组字期间这些键由
// 输入法消费、不会回调过来，所以不需要吞键 hack。挂进窗口时把自己设为 initialFirstResponder，
// 浮层显示时自动聚焦。romanOnly：聚焦时只允许英文类输入法（系统自动切过去，离开后恢复）。

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
    return field
  }

  func updateNSView(_ field: FocusField, context: Context) {
    context.coordinator.parent = self
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

    override func becomeFirstResponder() -> Bool {
      guard super.becomeFirstResponder() else { return false }
      applyInputSources()
      return true
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if isDialogField, newWindow == nil, let window {
        window.makeFirstResponder(window.initialFirstResponder)
      }
      super.viewWillMove(toWindow: newWindow)
    }
  }
}
