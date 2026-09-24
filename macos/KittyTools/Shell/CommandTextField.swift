// 单行输入框（包一层 NSTextField）：方向键 / 回车 / Esc 走 doCommandBy。输入法组字期间这些键由
// 输入法消费、不会回调过来，所以不需要吞键 hack。挂进窗口时把自己设为 initialFirstResponder，
// 浮层显示时自动聚焦。

import AppKit
import SwiftUI

struct CommandTextField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  /// 返回 true 表示已处理（moveUp: / moveDown: / insertNewline: / cancelOperation: …）。
  /// 没处理的 cancelOperation: 交给窗口（浮层据此关闭）
  var onCommand: (Selector) -> Bool = { _ in false }

  func makeNSView(context: Context) -> FocusField {
    let field = FocusField()
    field.placeholderString = placeholder
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 15)
    field.cell?.usesSingleLineMode = true
    field.cell?.lineBreakMode = .byTruncatingTail
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: FocusField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
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
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.initialFirstResponder = self
    }
  }
}
