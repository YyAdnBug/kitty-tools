// 多行输入框（包一层 NSTextView）：翻译原文、剪贴板备注 / 编辑 / 片段都用它。回车走 doCommandBy，
// 输入法组字期间由输入法消费、不会误提交。主输入框挂进窗口时设为 initialFirstResponder；
// 对话框里的输入框出现时抢焦点、消失时把焦点还给主输入框。

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SourceTextView: NSViewRepresentable {
  @Binding var text: String
  /// true：Enter 提交、Shift+Enter / ⌘Enter 换行；false：Enter 换行（编辑正文）
  var submitsOnEnter = true
  var fontSize: CGFloat = 14
  var isDialogField = false
  var onCancel: (() -> Void)?
  var onSubmit: () -> Void = {}

  func makeNSView(context: Context) -> FocusScrollView {
    let textView = NSTextView(frame: .zero)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: fontSize)
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 2, height: 6)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.delegate = context.coordinator
    let scroll = FocusScrollView()
    scroll.isDialogField = isDialogField
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = textView
    return scroll
  }

  func updateNSView(_ scroll: FocusScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scroll.documentView as? NSTextView else { return }
    if textView.string != text { textView.string = text }
    if textView.font?.pointSize != fontSize { textView.font = .systemFont(ofSize: fontSize) }
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SourceTextView
    init(parent: SourceTextView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard parent.submitsOnEnter, !flags.contains(.shift), !flags.contains(.command) else {
          return false
        }
        parent.onSubmit()
        return true
      // ⌘↩ 系统发的是 noop:（不是 insertNewline:）：提交模式下当换行用
      case Selector(("noop:")):
        guard parent.submitsOnEnter, let event = NSApp.currentEvent,
          [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)),
          event.modifierFlags.contains(.command)
        else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        if let onCancel = parent.onCancel {
          onCancel()
        } else {
          textView.window?.cancelOperation(nil)
        }
        return true
      default:
        return false
      }
    }
  }

  final class FocusScrollView: NSScrollView {
    var isDialogField = false

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if isDialogField {
        window?.makeFirstResponder(documentView)
      } else {
        window?.initialFirstResponder = documentView
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
