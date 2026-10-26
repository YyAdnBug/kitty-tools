// 长截图的标注窗口（2026-10-26 拍板，macos/build/research/scroll-annotate-2026-10-26/decisions.html）：长图拼完之后
// 按 A（第 3 批在面板上加「标注」钮）打开这扇窗口，在长图上标注，标完拷贝 / 存储 / 另存为 / 识字。
// 为什么是正经窗口、不是浮层（拍板 A2）：长图比屏幕高得多，缩进一屏既看不清也标不准，得能滚动；标注要打字、要 ⌘Z，
// 窗口得拿得住键盘——长截图这时已经结束，不用再护着前台 App，所以打开时激活本 App（同设置窗、全部便签窗口，
// 关掉时 leaveDockIfNoWindows）。
// 画布不把长图整张贴给图层（长图上限 30000 像素高，超过约 16384 会撞 GPU 纹理上限）：draw 里按脏区裁出看得见的那一段
// 画（CGImage.cropping 是零拷贝的视图）。缩放交给 NSScrollView 的 magnification（拍板 A3：默认按宽适配、最大 1:1，
// ⌘0 适配宽度、⌘1 原始大小、⌘+ / ⌘-），标注坐标一律存图的点坐标，所以缩放不影响画好的标注。
// 标注本身（十种工具、选中和手柄、文字、撤销重做）是第 2 批，这一批只有画布、滚动、缩放和出图。

import AppKit
import Carbon.HIToolbox

@MainActor final class ScrollEditor: NSObject, NSWindowDelegate {
  /// 出图：动作、合成好的图、像素 / 点（AppDelegate 接到截图那条路上，同钉图 PinBoard.output）
  typealias Output = @MainActor (RegionSelector.Action, CGImage, CGFloat) -> Void

  /// 缩放的上下限和一档（⌘+ / ⌘-）
  private static let zoomRange: ClosedRange<CGFloat> = 0.1...4
  private static let zoomStep: CGFloat = 1.25

  private let image: CGImage
  /// 像素 / 点
  private let scale: CGFloat
  /// 单测直接摆状态、发按键用
  let window: NSWindow
  private let scrollView = NSScrollView()
  private let canvas: ScrollCanvas
  private let bar = EditorToolbar(mode: .longShot)
  private let output: Output
  /// 关掉了（AppDelegate 放掉这个会话）
  var onClose: () -> Void = {}

  var isVisible: Bool { window.isVisible }

  /// frameName：记住窗口位置和大小用的名字（单测传 nil：不写偏好）
  init(
    image: CGImage, scale: CGFloat, frameName: String? = "ScrollEditor", output: @escaping Output
  ) {
    self.image = image
    self.scale = scale
    self.output = output
    canvas = ScrollCanvas(image: image, scale: scale)
    window = NSWindow(
      contentRect: CGRect(origin: .zero, size: CGSize(width: 900, height: 640)),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    super.init()

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.allowsMagnification = true
    scrollView.minMagnification = Self.zoomRange.lowerBound
    scrollView.maxMagnification = Self.zoomRange.upperBound
    scrollView.backgroundColor = .underPageBackgroundColor
    scrollView.contentView = CenteringClipView()  // 图比视口窄 / 矮时居中，不贴着左下角
    scrollView.documentView = canvas
    scrollView.autoresizingMask = [.width, .height]
    bar.onClick = { [unowned self] item in clicked(item) }

    let content = ScrollEditorView()
    content.frame = CGRect(origin: .zero, size: window.contentLayoutRect.size)
    content.onKey = { [unowned self] key in self.key(key) }
    scrollView.frame = content.bounds
    content.addSubview(scrollView)
    content.addSubview(bar)
    window.contentView = content
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.contentMinSize = CGSize(width: 480, height: 360)
    window.setContentSize(Self.contentSize(for: pointSize, on: window.screen ?? NSScreen.main))
    if let frameName {
      if !window.setFrameUsingName(frameName) { window.center() }
      window.setFrameAutosaveName(frameName)
    } else {
      window.center()
    }
    window.initialFirstResponder = content
    placeBar()
    bar.grow(true, from: .bottom)  // 同截图工具栏：从靠边的那条边长出来
    zoomToFit()
    scrollToTop()
    updateTitle()
  }

  /// 图的点尺寸（标注的坐标系；长图的像素 / scale）
  private var pointSize: CGSize { canvas.bounds.size }

  /// 窗口默认多大（拍板 A2）：宽按长图的点宽、上限可见区的 90%，高是可见区的 85%。纯函数，配单测
  static func contentSize(for pointSize: CGSize, on screen: NSScreen?) -> CGSize {
    let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    return CGSize(
      width: min(max(pointSize.width, 480), visible.width * 0.9),
      height: min(max(pointSize.height, 360), visible.height * 0.85))
  }

  /// 按宽适配的缩放（拍板 A3）：窄的长图不放大，最大 1:1。纯函数，配单测
  static func fitMagnification(pointWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
    guard pointWidth > 0, viewportWidth > 0 else { return 1 }
    return min(1, max(zoomRange.lowerBound, viewportWidth / pointWidth))
  }

  /// 显示并激活（同设置窗、全部便签窗口：浮层已经在长截图结束时收了）
  func show() {
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    // macOS 14 起 activate() 是协作式的，前台 App 不让出时可能到不了最前：退回旧 API（同设置窗）
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
  }

  func close() { window.close() }

  // MARK: 缩放与位置

  private func zoomToFit() {
    setMagnification(
      Self.fitMagnification(
        pointWidth: pointSize.width, viewportWidth: scrollView.contentSize.width))
  }

  private func setMagnification(_ value: CGFloat) {
    scrollView.magnification = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    updateTitle()
  }

  /// 长图从上往下看：一打开停在最上面（画布原点在左下，顶边是最大的 y）
  private func scrollToTop() {
    window.layoutIfNeeded()
    let clip = scrollView.contentView
    canvas.scroll(NSPoint(x: 0, y: max(canvas.bounds.height - clip.documentVisibleRect.height, 0)))
  }

  /// 工具栏浮在内容底部居中（离底 16，同截图工具栏离选区 10 的那条边）
  private func placeBar() {
    guard let content = window.contentView else { return }
    bar.frame.origin = CGPoint(
      x: ((content.bounds.width - bar.frame.width) / 2).rounded(), y: 16)
    bar.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
  }

  private func updateTitle() {
    let percent = Int((scrollView.magnification * 100).rounded())
    window.title = "长截图 · \(image.width) × \(image.height) · \(percent)%"
  }

  // MARK: 出图

  /// 合成好的长图（第 2 批起带标注：有标注才重渲，拍板 C2）
  private func composed() -> CGImage { image }

  private func clicked(_ item: EditorToolbar.Item) {
    switch item {
    case .output(let action): emit(action)
    case .cancel: close()
    case .saveMenu: emit(.saveAs)  // 第 3 批换成 HUD 菜单（存储到… / 另存为…）
    case .tool, .undo, .redo, .scroll, .record: break  // 标注是第 2 批
    }
  }

  /// 拷贝 / 存储 / 另存为完就关掉窗口（这次长截图到此结束）；识字只是把文字拿走，窗口留着
  private func emit(_ action: RegionSelector.Action) {
    output(action, composed(), scale)
    if action != .recognize { close() }
  }

  /// 窗口里的按键（内容视图收，第 2 批标注的键也走这里）
  private func key(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    switch (Int(event.keyCode), flags) {
    case (kVK_Escape, []): close()
    case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): emit(.copy)
    case (kVK_ANSI_O, []): emit(.recognize)
    case (kVK_ANSI_C, .command): emit(.copy)
    case (kVK_ANSI_S, .command): emit(.save)
    case (kVK_ANSI_S, [.command, .shift]): emit(.saveAs)
    case (kVK_ANSI_0, .command): zoomToFit()
    case (kVK_ANSI_1, .command): setMagnification(1)
    case (kVK_ANSI_Equal, .command), (kVK_ANSI_Equal, [.command, .shift]),
      (kVK_ANSI_KeypadPlus, .command):
      setMagnification(scrollView.magnification * Self.zoomStep)
    case (kVK_ANSI_Minus, .command), (kVK_ANSI_KeypadMinus, .command):
      setMagnification(scrollView.magnification / Self.zoomStep)
    default: return false
    }
    return true
  }

  // MARK: 窗口

  func windowDidResize(_ notification: Notification) { placeBar() }

  func windowWillClose(_ notification: Notification) {
    NSApp.leaveDockIfNoWindows(closing: window)
    onClose()
  }
}

/// 窗口的内容视图：工具栏和画布的壳，按键在这里收（画布第 2 批要当第一响应者画标注，键照旧经这里）
final class ScrollEditorView: NSView {
  var onKey: (NSEvent) -> Bool = { _ in false }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if !onKey(event) { super.keyDown(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    onKey(event) || super.performKeyEquivalent(with: event)
  }
}

/// 长图画布：一张很高的图，只画看得见的那一段。坐标系同截图标注——点、原点在左下（Annotation 的约定），
/// 所以不 flipped；标注层第 2 批加在这里
final class ScrollCanvas: NSView {
  let image: CGImage
  /// 像素 / 点
  let scale: CGFloat

  init(image: CGImage, scale: CGFloat) {
    self.image = image
    self.scale = scale
    super.init(
      frame: CGRect(
        x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isOpaque: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let pixels = Self.pixelRect(
      of: dirtyRect, in: bounds.size, pixels: CGSize(width: image.width, height: image.height))
    guard pixels.width >= 1, pixels.height >= 1, let crop = image.cropping(to: pixels) else {
      return
    }
    context.interpolationQuality = .medium
    context.draw(
      crop,
      in: Self.pointRect(
        of: pixels, in: bounds.size, pixels: CGSize(width: image.width, height: image.height)))
  }

  /// 脏区（点，原点在左下）→ 图里的像素矩形（原点在左上）：取整往外扩一像素，夹进图里。纯函数，配单测
  static func pixelRect(of dirty: CGRect, in size: CGSize, pixels: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let sx = pixels.width / size.width
    let sy = pixels.height / size.height
    let rect = CGRect(
      x: dirty.minX * sx, y: (size.height - dirty.maxY) * sy, width: dirty.width * sx,
      height: dirty.height * sy
    ).insetBy(dx: -1, dy: -1).integral
    return rect.intersection(CGRect(origin: .zero, size: pixels))
  }

  /// 像素矩形（原点在左上）→ 画在画布的哪儿（点，原点在左下）。纯函数，配单测
  static func pointRect(of pixels: CGRect, in size: CGSize, pixels total: CGSize) -> CGRect {
    guard total.width > 0, total.height > 0 else { return .zero }
    let sx = size.width / total.width
    let sy = size.height / total.height
    return CGRect(
      x: pixels.minX * sx, y: (total.height - pixels.maxY) * sy, width: pixels.width * sx,
      height: pixels.height * sy)
  }
}

/// 内容比视口小时居中（AppKit 默认贴着左下角）
final class CenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    guard let document = documentView else { return rect }
    let frame = document.frame
    if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
    if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
    return rect
  }
}
