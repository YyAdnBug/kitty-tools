// 翻译原文输入框（包一层 NSTextView）：Enter 提交、Shift+Enter 换行。回车走 doCommandBy，
// 输入法组字期间由输入法消费、不会误提交。挂进窗口时设为 initialFirstResponder。

import AppKit
import SwiftUI

struct SourceTextView: NSViewRepresentable {
  @Binding var text: String
  var onSubmit: () -> Void

  func makeNSView(context: Context) -> FocusScrollView {
    let textView = NSTextView(frame: .zero)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: 14)
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 2, height: 6)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.delegate = context.coordinator
    let scroll = FocusScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = textView
    return scroll
  }

  func updateNSView(_ scroll: FocusScrollView, context: Context) {
    context.coordinator.parent = self
    if let textView = scroll.documentView as? NSTextView, textView.string != text {
      textView.string = text
    }
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
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        textView.window?.cancelOperation(nil)
        return true
      default:
        return false
      }
    }
  }

  final class FocusScrollView: NSScrollView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.initialFirstResponder = documentView
    }
  }
}
