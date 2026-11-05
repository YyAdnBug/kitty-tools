// 钉图在 1x 屏上的布局（issue #6：1x 外接屏上点「钉到屏幕」必闪退）。AppKit 布局时把带 autoresizing 约束的子视图吸到像素格上
// （2x 是半点、1x 是整点）；钉图原来在 layout() 里把缩放百分比摆到正中，窗口宽或高是奇数时正中落在半点上——1x 上被吸到整点、
// layout() 又摆回半点、约束又失效，显示周期反复「更新约束 → 布局」超过窗口里的视图数，AppKit 抛异常退出。
// 本机只有 2x 屏：把钉图的内容视图挪进一个 backingScaleFactor 报 1 的窗口（实测吸附跟着它走，修之前这里抛的就是崩溃报告里那个
// NSGenericException，测试宿主直接退出）。钉图摆在屏外、从不 makeKey，不读写偏好。

import AppKit
import Testing

@testable import KittyTools

/// 假装在 1x 屏上
private final class OneXWindow: NSWindow {
  override var backingScaleFactor: CGFloat { 1 }
}

@MainActor @Suite(.serialized)
struct PinLayoutTests {
  private static let image: CGImage = {
    let context = CGContext(
      data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
  }()

  // 回弹、滚轮缩放、原始大小都不卡在布局里，圆钮一直贴右上角、百分比居中（1x 上差不过半个点）
  @Test func pinLaysOutOnOneXScreens() throws {
    let board = PinBoard()
    // 报告里那种带小数的选区：窗口取整成 605 × 285，宽高都是奇数
    board.pin(
      Self.image,
      frame: CGRect(x: -20000.11, y: -20000.17, width: 604.80859375, height: 285.21875))
    defer { board.closeAll() }
    let panel = try #require(board.panels.first)
    panel.finishPopIn()  // 屏外的窗口 display link 不走，直接落到原位
    let view = try #require(panel.contentView)
    panel.contentView = NSView()
    let window = OneXWindow(
      contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let hud = try #require(view.subviews.first { $0 is HUDBar })
    let controls = try #require(view.subviews.first { !($0 is HUDBar) })

    /// 转一下 run loop：崩溃是显示周期（NSDisplayCycleFlush → 窗口 layoutIfNeeded）里抛的，光 layoutSubtreeIfNeeded 走不到
    func settle() {
      view.needsLayout = true
      RunLoop.main.run(until: .now + 0.05)
    }

    func expectPlaced(_ step: String, hudShown: Bool = false) {
      settle()
      let bounds = view.bounds
      #expect(abs(bounds.maxX - controls.frame.maxX - 6) <= 0.5, "\(step)：圆钮离右边 6")
      #expect(abs(bounds.maxY - controls.frame.maxY - 6) <= 0.5, "\(step)：圆钮离顶边 6")
      guard hudShown else { return }
      #expect(!hud.isHidden, "\(step)：百分比出来了")
      #expect(abs(hud.frame.midX - bounds.midX) <= 0.5, "\(step)：百分比横向居中")
      #expect(abs(hud.frame.midY - bounds.midY) <= 0.5, "\(step)：百分比竖向居中")
    }

    expectPlaced("钉上")
    // 回弹：窗口从 1.04 倍逐帧缩回原位
    let target = window.frame
    for scale in [1.04, 1.027, 1.013, 1.0] {
      window.setFrame(
        target.insetBy(dx: target.width * (1 - scale) / 2, dy: target.height * (1 - scale) / 2),
        display: true)
      expectPlaced("回弹 \(scale)")
    }

    let scroll = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0,
        wheel3: 0))
    scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
    #expect(window.frame.size != target.size, "滚轮缩放了")
    expectPlaced("滚轮缩放", hudShown: true)

    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let actual = try #require(view.menu(for: event)?.items.first { $0.title == "原始大小" })
    NSApp.sendAction(try #require(actual.action), to: actual.target, from: actual)
    #expect(window.frame.size == target.size, "回到原始大小")
    expectPlaced("原始大小", hudShown: true)
  }
}
