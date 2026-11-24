// 列表行的悬停（Whisker §3 状态：fill.hover 0.10 s 淡入）：本 App 从不激活，SwiftUI 的 onHover 在非激活浮层里不可靠
// （剪贴板面板是 key 时也收不到，和是不是 key 无关；常驻缩略图 ShotShelf 同理自建追踪区），所以用 activeAlways 的
// NSTrackingArea 自己报。启动器、翻译历史的行和别处要悬停的小块各挂一个；剪贴板的行多、会滚，用下面的 ListHoverTracker（整块列表一块）。
// 用法：`.background { HoverTracker { inside in withAnimation(.easeOut(duration: 0.10)) { hovered = inside } } }`。
// 不接点击（hitTest 为 nil）；行被回收（离开窗口）时补一个「移出」。

import AppKit
import SwiftUI

struct HoverTracker: NSViewRepresentable {
  let onChange: (Bool) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    view.addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: view))
    return view
  }

  func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

  final class TrackingView: NSView {
    var onChange: (Bool) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
    override func viewDidMoveToWindow() { if window == nil { onChange(false) } }
  }
}

/// 整块列表一块追踪区（剪贴板列表，美化与提速 P2）：每行各挂一个 HoverTracker 时每行一个 NSView，滚动跨段、行一进一出
/// 都要建、拆一个平台视图、进出视图层级，还都是 SwiftUI 焦点链要过一遍的候选。它垫在滚动视图后面（追踪区看几何、不看点击，
/// 不挡滚动和点按），报鼠标在这块视图里的位置（y 朝下）；离开、窗口收走、在左右各 inset 的边距或常显的滚动条那一列上时报 nil。
/// 窗口再当 key、重新露出来时按鼠标现在在哪重报一次（orderOut 不发「移出」，不重报的话再呼出时悬停底画在上次鼠标停的那一行）。
/// 行在鼠标底下挪了（滚动、透镜开合）它不知道：调用方自己拿上一次的位置按新的几何再算
struct ListHoverTracker: NSViewRepresentable {
  /// 列表左右的边距：鼠标在边距里不算在哪一行上
  var inset: CGFloat = 0
  let onMove: (CGPoint?) -> Void

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    view.addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
        owner: view))
    return view
  }

  func updateNSView(_ view: TrackingView, context: Context) {
    view.onMove = onMove
    view.inset = inset
  }

  final class TrackingView: NSView {
    var onMove: (CGPoint?) -> Void = { _ in }
    var inset: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { report(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { report(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onMove(nil) }

    override func viewDidMoveToWindow() {
      NotificationCenter.default.removeObserver(self)
      guard let window else { return onMove(nil) }
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification]
      {
        NotificationCenter.default.addObserver(
          self, selector: #selector(refresh), name: name, object: window)
      }
    }

    /// 窗口当 key、露出来 / 收走了：按鼠标现在在哪重报，收走了报 nil
    @objc private func refresh() {
      guard let window, window.occlusionState.contains(.visible) else { return onMove(nil) }
      report(window.mouseLocationOutsideOfEventStream)
    }

    private func report(_ location: NSPoint) {
      let point = convert(location, from: nil)
      // 常显的滚动条那一列不算（悬停时才出的滚动条盖在行上，照旧算）
      let scroller =
        NSScroller.preferredScrollerStyle == .legacy
        ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
      let inside =
        bounds.contains(point) && point.x >= inset && point.x <= bounds.width - inset - scroller
      onMove(inside ? point : nil)
    }
  }
}
