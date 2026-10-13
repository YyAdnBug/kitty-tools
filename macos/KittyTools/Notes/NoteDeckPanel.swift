// 屏幕边缘那叠的面板（PLAN §10「便签」拍板 B⑤；规矩在 mac-overlay-panel §12）：扇出的一列标签和打开的那条便签都画在
// 这一块里。它是「浮层只有 OverlayPanel 一种」的第五个例外——无边框、nonactivating、要当 key 收按键才子类化，
// 和 OverlayPanel 的行为没有交集（不居中、不自己点外关闭、没有材质底：窗口全透明，纸和标签是内容自己画的）。
// - 贴着屏幕的那条边，宽 = 便签宽 + 标签列 + 余量、高 = 可见区高，大小不随状态变（不像 Noty 把同一个窗口放大再扇出）；
//   空白处是透明的、系统自己点穿，所以**不设 ignoresMouseEvents**（设过一次，透明处就不再点穿）。
// - 层级 floating、所有桌面和别的 App 的全屏里都能出（呼出来的东西）；截图的冻结帧按层级留着它、能悬停选中
//   （只算里面真有东西的那一块，contentFrame），录屏的白名单（ScreenCapture.recordedOwnWindows）按类名列着它——
//   它是内容，同钉图。
// - 永远不调 NSApp.activate。扇出时不当 key（becomesKeyOnlyIfNeeded：点标签、按钮不抢键盘），点开便签时
//   NoteDeck 才 makeKey；点正文、标题也会当 key（输入框要键盘）。
// - 按键照 mac-overlay-panel §3：⌘ 组合先给 keyEquivalentHandler（⌘W ⌘P ⌘K ⌘. ⇧⌘A），剩下的编辑键（⌘C ⌘V ⌘Z…）
//   直接发给输入框（本 App 不激活，主菜单收不到）；Esc 是 cancelOperation（输入框里的经 doCommandBy 转过来——
//   输入法组字时 Esc 归输入法，到不了这里），**不装本地按键监听去抢**；操作菜单开着时焦点在面板自己身上，
//   方向键和回车走 keyDown → keyDownHandler。
// - 撤销：⌘Z / ⇧⌘Z 直接动焦点所在输入框的撤销栈（OverlayPanel.undoRedo）——正文是打开着的那条便签自己的
//   （NoteTextView.noteUndo = NoteDeckModel.textUndo，换一条换一个，A 里打的字不会在 B 里被 ⌘Z 撤到），标题框是它的
//   字段编辑器的。**面板不重写 undoManager**：原来重写过（给 textUndo），文本视图登记在重写的那个上，而 ⌘Z 发出去的
//   undo: 到头是 NSWindow 接、它动的是窗口内部的另一个栈——正文里的撤销因此一直不灵（2026-10-13 用户报，实测确认）。
// 用时再建、收起后放掉（NoteDeck 拿着）。

import AppKit
import Carbon.HIToolbox
import SwiftUI

final class NoteDeckPanel: NSPanel {
  /// ⌘ 组合键先给它，返回 true = 处理了
  var keyEquivalentHandler: ((NSEvent) -> Bool)?
  /// 焦点不在输入框里时的按键（操作菜单开着时的 ↑↓ ↩ ← →）
  var keyDownHandler: ((NSEvent) -> Bool)?
  var onCancel: () -> Void = {}
  var onResignKey: () -> Void = {}
  /// 面板里真有东西的那一块（全局坐标）：截图时悬停、单击选中的是它，不是整块透明的面板。**没有东西是 .zero**
  /// （这扇窗口就不进悬停列表）——ScreenCapture.OwnWindow.content 的 nil 是另一个意思：「整个窗口」
  var contentFrame: () -> CGRect = { .zero }

  private let host: NoteDeckHost

  /// onPointer：鼠标在热区里动了、进出了热区（NoteDeck 拿它判断离没离开）
  init(frame: NSRect, model: NoteDeckModel, onPointer: @escaping () -> Void) {
    host = NoteDeckHost(rootView: NoteDeckView(model: model))
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    // 阴影由内容自己画（一张张标签、便签）：透明窗口的系统阴影是按整块内容算的
    hasShadow = false
    isMovable = false
    animationBehavior = .none
    host.sizingOptions = []  // 窗口大小由 NoteDeck 定，不让 SwiftUI 的理想尺寸反推
    host.onPointer = onPointer
    contentView = host
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// 跟鼠标的追踪区只挂在这一块上（全局坐标的热区；.zero = 不挂）
  func track(_ zone: CGRect) {
    host.hotRect = zone.isEmpty ? .zero : host.convert(convertFromScreen(zone), from: nil)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event) {
      return true
    }
    // ⌘Z / ⇧⌘Z：焦点所在的输入框自己的撤销栈（正文是这条便签的那一个）
    if let done = OverlayPanel.undoRedo(event, in: self) { return done }
    // 不看 Caps Lock（同 OverlayPanel）
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
      let action = OverlayPanel.editActions[event.charactersIgnoringModifiers?.lowercased() ?? ""]
    else { return false }
    return OverlayPanel.sendEditAction(action, from: self)
  }

  override func cancelOperation(_ sender: Any?) { onCancel() }

  override func keyDown(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Escape { return cancelOperation(nil) }
    if keyDownHandler?(event) != true { super.keyDown(with: event) }
  }

  override func resignKey() {
    super.resignKey()
    onResignKey()
  }
}

/// 那叠的 SwiftUI 宿主：第一下点击就给内容（点标签时面板不是 key、本 App 也不在前台）；鼠标在热区里动、进出热区
/// 都报给 NoteDeck。追踪区**只挂热区那一块**（hotRect，没有就不挂）：整块面板都挂 mouseMoved 的话，便签开着时鼠标在
/// 它上面来回动会一下下唤醒本进程。不写成泛型子类（Release 优化时编译器会崩，见 RecordingHUD 的 PassiveHost）
private final class NoteDeckHost: NSHostingView<NoteDeckView> {
  var onPointer: () -> Void = {}
  /// 热区（这块视图自己的坐标）；空 = 不追踪
  var hotRect = CGRect.zero {
    didSet { if hotRect != oldValue { updateTrackingAreas() } }
  }
  /// 自己加的那块追踪区（SwiftUI 自己的那些不碰）
  private var pointerArea: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    pointerArea.map(removeTrackingArea)
    pointerArea = nil
    guard !hotRect.isEmpty else { return }
    var options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .mouseMoved]
    // 那一列是在鼠标底下冒出来的：鼠标已经在里面时说一声，离开时才有「出去了」
    if let window, hotRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
      options.insert(.assumeInside)
    }
    let area = NSTrackingArea(rect: hotRect, options: options, owner: self)
    addTrackingArea(area)
    pointerArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    onPointer()
    super.mouseEntered(with: event)
  }

  override func mouseMoved(with event: NSEvent) {
    onPointer()
    super.mouseMoved(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    onPointer()
    super.mouseExited(with: event)
  }
}
