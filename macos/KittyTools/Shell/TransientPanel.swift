// 用时再建、收起后放掉的浮层（第二轮体检 M3）：两张 ⌘Y 大卡（剪贴板放大预览、启动器快速查看）由它拿着。
// 收起的面板只是 orderOut，窗口还按收起那一刻的尺寸留着图层（内存探针实测：剪贴板大卡看整屏截图时直接收起留 27 MB，
// 启动器那张 9.5 MB），放掉窗口对象才还。
// 三块主面板和设置窗不这么做：放掉省不到 10 MB，每次呼出却要多建一次。
// 收起后先留 lingering 再放：刚关又开（连按 ⌘Y）接着用同一块、不反复建；留着的这段时间里又打开了就不放。

import AppKit

final class TransientPanel {
  /// 现在这块；没建过、已经放掉时是 nil。只想对开着的那块做点什么时读它（open 会建）
  private(set) var panel: OverlayPanel?
  private let make: () -> OverlayPanel
  private let lingering: Duration
  private let onRelease: () -> Void
  private var release: Task<Void, Never>?

  /// - Parameters:
  ///   - lingering: 收起后留多久再放
  ///   - onRelease: 放掉之后做的事（这时窗口对象已经放手）
  ///   - make: 建面板。它的 onHide 照常设，这里在后面接上「过一会儿放掉」
  init(
    lingering: Duration = .seconds(2), onRelease: @escaping () -> Void = {},
    make: @escaping () -> OverlayPanel
  ) {
    self.lingering = lingering
    self.onRelease = onRelease
    self.make = make
  }

  /// 要显示了：还在就接着用（等着放掉的那一下作废），不在就建
  func open() -> OverlayPanel {
    release?.cancel()
    release = nil
    if let panel { return panel }
    let panel = make()
    let hidden = panel.onHide
    panel.onHide = { [weak self] in
      hidden?()
      self?.releaseSoon()
    }
    self.panel = panel
    return panel
  }

  private func releaseSoon() {
    release?.cancel()
    release = Task { [weak self, lingering] in
      try? await Task.sleep(for: lingering)
      // 留着的时候又打开了（open 作废了这一下）就不放；不知怎么又在屏幕上的也不放
      guard !Task.isCancelled, let self, panel?.isVisible == false else { return }
      panel = nil
      onRelease()
    }
  }
}
