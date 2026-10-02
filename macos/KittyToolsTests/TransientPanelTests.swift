// 用时再建、收起后放掉的浮层（TransientPanel，第二轮体检 M3）：两张 ⌘Y 大卡靠它在收起后把窗口放掉。
// 面板都不显示（「收起」直接调它的 onHide），留多久用几十毫秒；窗口对象真的释放了没有由内存探针量。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

@MainActor struct TransientPanelTests {
  private final class Counter {
    var built = 0
    var hidden = 0
    var released = 0
  }

  private func makePanel(_ counter: Counter, lingering: Duration) -> TransientPanel {
    TransientPanel(
      lingering: lingering, onRelease: { counter.released += 1 },
      make: {
        counter.built += 1
        let panel = OverlayPanel(
          size: NSSize(width: 200, height: 100), autoHide: .clickOutside, isPinned: { false },
          content: Color.clear)
        panel.onHide = { counter.hidden += 1 }
        return panel
      })
  }

  /// 等到放掉（最多 5 秒）
  private func released(_ transient: TransientPanel) async -> Bool {
    for _ in 0..<250 where transient.panel != nil {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return transient.panel == nil
  }

  /// 没用过不建；开了再开是同一块；收起后面板自己的 onHide 照常调，过了 lingering 放掉、调 onRelease；再开是新建的一块
  @Test func buildsOnDemandAndReleasesAfterHide() async {
    let counter = Counter()
    let transient = makePanel(counter, lingering: .milliseconds(20))
    #expect(transient.panel == nil && counter.built == 0)
    let first = ObjectIdentifier(transient.open())
    #expect(ObjectIdentifier(transient.open()) == first && counter.built == 1)
    transient.panel?.onHide?()
    #expect(counter.hidden == 1 && transient.panel != nil && counter.released == 0)
    #expect(await released(transient))
    #expect(counter.released == 1)
    _ = transient.open()
    #expect(counter.built == 2 && transient.panel != nil)
  }

  /// 收起后还没放掉就又打开：不放，接着用同一块（收起动画刚放完又按 ⌘Y）；之后再收起，照常放、只放一次
  @Test func reopeningKeepsThePanel() async {
    let counter = Counter()
    let transient = makePanel(counter, lingering: .milliseconds(100))
    let first = ObjectIdentifier(transient.open())
    transient.panel?.onHide?()
    #expect(ObjectIdentifier(transient.open()) == first)
    try? await Task.sleep(for: .milliseconds(400))
    #expect(transient.panel.map(ObjectIdentifier.init) == first)
    #expect(counter.built == 1 && counter.released == 0)
    // 连着收起两次（缩回放完 + 跟着主面板收起）也只放一次
    transient.panel?.onHide?()
    transient.panel?.onHide?()
    #expect(await released(transient))
    try? await Task.sleep(for: .milliseconds(300))
    #expect(counter.released == 1 && counter.hidden == 3)
  }
}
