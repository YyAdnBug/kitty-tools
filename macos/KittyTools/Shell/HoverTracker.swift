// 列表行的悬停（Whisker §3 状态：fill.hover 0.10 s 淡入）：本 App 从不激活，SwiftUI 的 onHover 在非激活浮层里不可靠
// （剪贴板面板是 key 时也收不到，和是不是 key 无关；常驻缩略图 ShotShelf 同理自建追踪区），所以用 activeAlways 的
// NSTrackingArea 自己报。剪贴板行、翻译历史行共用；以后启动器行要悬停也用它。
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
