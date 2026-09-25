// 不激活前台的浮层（NSPanel）：剪贴板面板、翻译浮窗、启动器共用这一个类，各建一个实例（PLAN §4）。
// 显示只 orderFrontRegardless + makeKey，永远不调 NSApp.activate：前台 App 保持不变，
// 粘贴时发的 ⌘V、划词时发的 ⌘C 才会落到它身上。
// 外观是 Whisker 的 Panel 皮肤（mac-whisker §2）：无边框、16 pt 连续圆角（maskImage 裁，系统阴影跟着走）+ 描边；
// 出现时淡入 + 内容下落 6 pt，用户关掉时系统淡出（窗口逻辑上立刻移走，键盘马上回到原 App），高度可带动画伸缩。

import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
  enum AutoHide {
    /// 点本 App 浮层以外的地方就关（剪贴板面板）；Esc 固定时也关
    case clickOutside
    /// 失去 key 就关（翻译浮窗）；固定时 Esc 也不关
    case resignKey
  }

  var onHide: (() -> Void)?
  /// 这次显示前处于 key 的自家浮层：收起时把 key 还给它（翻译浮窗用）
  private(set) weak var previousKeyPanel: OverlayPanel?
  /// ⌘ 组合键先给它处理，返回 true 表示已处理
  var keyEquivalentHandler: ((NSEvent) -> Bool)?
  private let autoHide: AutoHide
  private let isPinned: () -> Bool
  private let centersOnEveryShow: Bool
  /// 启动器：每次都放在鼠标所在屏、顶边在可见区 20% 处，高度随内容往下伸缩
  private let topAnchored: Bool
  private var mouseMonitors: [Any] = []
  /// SwiftUI 内容：入场时它下落，材质本身不动
  private let host: NSView

  /// - Parameters:
  ///   - minSize: 传了就允许拖左右边改宽度（无边框窗口没有系统的拖边，用两条 ResizeEdge）
  ///   - autosaveName: 传了就记住位置和大小（首次居中）；不传则每次显示都居中到鼠标所在屏幕
  ///   - topAnchored: 放在屏幕上部（启动器），配合 setContentHeight 伸缩
  init<Content: View>(
    size: NSSize, minSize: NSSize? = nil, autosaveName: String? = nil, topAnchored: Bool = false,
    autoHide: AutoHide, isPinned: @escaping () -> Bool, content: Content
  ) {
    self.autoHide = autoHide
    self.isPinned = isPinned
    centersOnEveryShow = autosaveName == nil
    self.topAnchored = topAnchored
    let hosting = NSHostingView(rootView: content.ignoresSafeArea().overlay(PanelRim()))
    hosting.sizingOptions = []  // 窗口大小由这里定，不让 SwiftUI 的理想尺寸反推窗口
    hosting.wantsLayer = true
    host = hosting
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isMovableByWindowBackground = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .none
    if let minSize { contentMinSize = minSize }
    // 系统毛玻璃底：state 必须 .active，本 App 从不激活，跟随窗口状态会一直是灰的非激活外观
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.maskImage = Self.cornerMask(radius: Style.Radius.panel)
    hosting.frame = background.bounds
    hosting.autoresizingMask = [.width, .height]
    background.addSubview(hosting)
    if minSize != nil {
      for edge in [ResizeEdge.Side.left, .right] { background.addSubview(ResizeEdge(side: edge)) }
    }
    contentView = background
    if let autosaveName, !setFrameUsingName(autosaveName) { center() }
    if let autosaveName { setFrameAutosaveName(autosaveName) }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// makingKey = false：只露出来、不抢键盘（复制即译），此时靠点外关闭
  func present(makingKey: Bool = true) {
    let appearing = !isVisible
    if appearing {
      placeForShow()
      animationBehavior = .none
      alphaValue = 0
    }
    orderFrontRegardless()
    if makingKey {
      // 每次都重新记：key 不是别的自家浮层时清掉旧值，免得收起时把 key 还给早就不相干的面板
      let current = NSApp.keyWindow as? OverlayPanel
      if current !== self { previousKeyPanel = current }
      makeKey()
      // 首次显示时 SwiftUI 还没建出输入框，先把布局跑完再聚焦
      contentView?.layoutSubtreeIfNeeded()
      if let field = initialFirstResponder { makeFirstResponder(field) }
    }
    if autoHide == .clickOutside || !makingKey, mouseMonitors.isEmpty { installMouseMonitors() }
    if appearing { animateIn() }
  }

  /// 入场：窗口淡入（fadeIn），内容从上方 6 pt 落下（弹簧）；减弱动态效果时只淡入
  private func animateIn() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
    guard !Style.reduceMotion, let layer = host.layer else { return }
    let drop = CASpringAnimation(perceptualDuration: 0.24, bounce: 0.12)
    drop.keyPath = "transform.translation.y"
    drop.fromValue = 6  // AppKit 图层 y 向上：正值 = 在上方
    drop.toValue = 0
    drop.duration = drop.settlingDuration
    layer.add(drop, forKey: "enter")
  }

  /// 立刻收起（粘贴前、打开设置、程序切换）：没有退场动画，⌘V 发出时面板已经不在
  func hide() {
    guard isVisible else { return }
    animationBehavior = .none
    orderOut(nil)
    alphaValue = 1
    removeMouseMonitors()
    onHide?()
  }

  /// 用户关掉（Esc、点外面、再按热键、失焦）：系统淡出。窗口逻辑上立刻移走，键盘马上回到原 App
  func dismiss() {
    guard isVisible else { return }
    animationBehavior = Style.reduceMotion ? .none : .utilityWindow
    orderOut(nil)
    animationBehavior = .none
    alphaValue = 1
    removeMouseMonitors()
    onHide?()
  }

  func toggle() {
    if isVisible && isKeyWindow { dismiss() } else { present() }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event) {
      return true
    }
    // 浮层不激活本 App，主菜单的 ⌘C / ⌘V 等不一定收得到：直接发给当前输入框
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      let action = Self.editActions[event.charactersIgnoringModifiers?.lowercased() ?? ""]
    else { return false }
    return NSApp.sendAction(action, to: nil, from: self)
  }

  /// 截图里输入文字时也用它（同样不激活本 App）
  static let editActions: [String: Selector] = [
    "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
    "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
    "z": Selector(("undo:")),
  ]

  override func cancelOperation(_ sender: Any?) {
    if autoHide == .resignKey && isPinned() { return }
    dismiss()
  }

  override func resignKey() {
    super.resignKey()
    // key 让给自己的 sheet（确认框等）时不算失焦
    if autoHide == .resignKey, isVisible, attachedSheet == nil, !isPinned() { dismiss() }
  }

  /// 改高度时顶边不动，只往下伸缩（启动器随结果条数、翻译浮窗随内容变化）；往下出了屏幕可见区就整体往上挪。
  /// animated：变高 0.18 s、变矮 0.14 s（首次显示和减弱动态效果时不动画）
  func setContentHeight(_ height: CGFloat, animated: Bool = false) {
    guard abs(frame.height - height) > 0.5 else { return }
    var target = frame
    target.origin.y = target.maxY - height
    target.size.height = height
    if let visible = screen?.visibleFrame, target.minY < visible.minY {
      target.origin.y = min(visible.minY, visible.maxY - height)
    }
    guard animated, isVisible, alphaValue == 1, !Style.reduceMotion else {
      return setFrame(target, display: true)
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = height > frame.height ? 0.18 : 0.14
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
      animator().setFrame(target, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { self.invalidateShadow() }
    }
  }

  private func placeForShow() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    if topAnchored {
      let top = visible.maxY - visible.height * 0.2
      setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: top - frame.height))
      return
    }
    // 记住的位置落在某块屏幕里就沿用（拔掉外接屏后才重新居中）
    if !centersOnEveryShow, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) })
    {
      return
    }
    setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
  }

  /// 点外即关：global 监听管别的 App，local 监听管自家窗口。点中任一自家浮层不关（兄弟窗口豁免），
  /// 点击时实时判断；显示时装、隐藏时卸，成对出现
  private func installMouseMonitors() {
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.clickedOutside() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        if !(event.window is OverlayPanel) { self?.clickedOutside() }
      }
      return event
    }
    mouseMonitors = [global, local].compactMap { $0 }
  }

  private func removeMouseMonitors() {
    mouseMonitors.forEach(NSEvent.removeMonitor)
    mouseMonitors = []
  }

  private func clickedOutside() {
    if !isPinned() { dismiss() }
  }

  /// 可拉伸的圆角蒙版：连续曲线的过渡比圆角半径长，拉伸区留 1.6 倍
  private static func cornerMask(radius: CGFloat) -> NSImage {
    let cap = ceil(radius * 1.6)
    let side = cap * 2 + 1
    let scale: CGFloat = 2
    let pixels = Int(side * scale)
    let path = RoundedRectangle(cornerRadius: radius * scale, style: .continuous)
      .path(in: CGRect(x: 0, y: 0, width: pixels, height: pixels)).cgPath
    let context = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
    context?.addPath(path)
    context?.fillPath()
    let image =
      context?.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }
      ?? NSImage(size: NSSize(width: side, height: side))
    image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    image.resizingMode = .stretch
    return image
  }
}

/// 无边框窗口的左右拖边（改宽度，夹在 minSize / maxSize 之间，另一边不动）。
/// 本 App 不激活，光标矩形不生效：用 activeAlways 的追踪区手动设光标
private final class ResizeEdge: NSView {
  enum Side { case left, right }

  private let side: Side
  private var start: (mouse: CGFloat, frame: NSRect)?
  private static let width: CGFloat = 6

  init(side: Side) {
    self.side = side
    super.init(frame: .zero)
    autoresizingMask = side == .left ? [.height, .maxXMargin] : [.height, .minXMargin]
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard let bounds = superview?.bounds else { return }
    frame = NSRect(
      x: side == .left ? 0 : bounds.maxX - Self.width, y: 0, width: Self.width,
      height: bounds.height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
  override func mouseExited(with event: NSEvent) { if start == nil { NSCursor.arrow.set() } }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    start = (NSEvent.mouseLocation.x, window.frame)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let window, let start else { return }
    let delta = NSEvent.mouseLocation.x - start.mouse
    let minWidth = max(window.minSize.width, window.contentMinSize.width)
    let maxWidth = min(
      window.maxSize.width, window.screen?.visibleFrame.width ?? .greatestFiniteMagnitude)
    var frame = start.frame
    frame.size.width = min(
      max(start.frame.width + (side == .left ? -delta : delta), minWidth), maxWidth)
    if side == .left { frame.origin.x = start.frame.maxX - frame.width }
    window.setFrame(frame, display: true)
  }

  override func mouseUp(with event: NSEvent) {
    start = nil
    NSCursor.arrow.set()
  }
}
