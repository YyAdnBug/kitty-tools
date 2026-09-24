// 轻提示：鼠标所在屏中间出现一行字，1.5 秒后自己消失（识字静默复制、⌘S 快速保存、复制色值的反馈）。
// 就是一个不抢键盘的 OverlayPanel（present(makingKey: false)），点外面也会关；不另写窗口类。

import AppKit
import Observation
import SwiftUI

@Observable final class Toast {
  var message = ""
  var symbol = "checkmark.circle.fill"
  @ObservationIgnored private lazy var panel = OverlayPanel(
    size: NSSize(width: 240, height: 44), autoHide: .clickOutside, isPinned: { false },
    content: ToastView(toast: self))
  @ObservationIgnored private var hideTask: Task<Void, Never>?

  func show(_ message: String, symbol: String = "checkmark.circle.fill") {
    self.message = message
    self.symbol = symbol
    // 宽度随文字：图标 + 间距 + 文字 + 两边留白
    let width = NSAttributedString(
      string: message, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
    ).size().width
    panel.setContentSize(NSSize(width: min(ceil(width) + 64, 520), height: 44))
    panel.hide()  // 重新居中到鼠标所在屏
    panel.present(makingKey: false)
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      if !Task.isCancelled { panel.hide() }
    }
  }
}

struct ToastView: View {
  let toast: Toast

  var body: some View {
    Label(toast.message, systemImage: toast.symbol)
      .font(.system(size: 13, weight: .medium))
      .lineLimit(1)
      .truncationMode(.tail)
      .symbolRenderingMode(.multicolor)
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
