// 截图翻译的框选：每块屏幕盖一个全屏遮罩，画冻结帧；拖动框选（选区外变暗），松手确认，Esc / 右键取消。
// 遮罩是不激活前台的 NSPanel（和 OverlayPanel 一样不抢前台 App），会话结束立即 orderOut 释放，不常驻
// （全屏窗口的 backing store 是内存大头）。不做旧版的窗口吸附、放大镜、比例条、延时、Enter 全屏（PLAN §11）。

import AppKit
import Carbon.HIToolbox

enum RegionSelector {
  /// 选区短边小于这个（点）当作误触：回到待选状态，不确认
  static let minimumSide: CGFloat = 8

  /// 在冻结帧上框选，返回裁好的图；取消返回 nil
  static func select(_ shots: [ScreenCapture.Shot]) async -> CGImage? {
    await withCheckedContinuation { continuation in
      var overlays: [SelectionOverlay] = []
      var finished = false
      let finish = { (image: CGImage?) in
        guard !finished else { return }
        finished = true
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = []
        NSCursor.arrow.set()
        continuation.resume(returning: image)
      }
      overlays = shots.map { SelectionOverlay(shot: $0, onFinish: finish) }
      guard !overlays.isEmpty else { return finish(nil) }
      for overlay in overlays { overlay.orderFrontRegardless() }
      // 鼠标不动时收不到 mouseMoved：先设一次十字光标
      NSCursor.crosshair.set()
      // 鼠标所在屏的遮罩接收 Esc；其它屏的遮罩靠 acceptsFirstMouse 直接响应拖动
      let mouse = NSEvent.mouseLocation
      let key = overlays.first { $0.frame.contains(mouse) } ?? overlays[0]
      key.makeKey()
    }
  }

  /// 视图里的选区（点，原点左下）→ 图里的像素矩形（原点左上），取整并夹在图内。纯函数，配单测
  static func pixelRect(_ selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
    let scaleX = imageSize.width / viewSize.width
    let scaleY = imageSize.height / viewSize.height
    let rect = CGRect(
      x: selection.minX * scaleX, y: (viewSize.height - selection.maxY) * scaleY,
      width: selection.width * scaleX, height: selection.height * scaleY
    ).integral
    return rect.intersection(CGRect(origin: .zero, size: imageSize))
  }
}

/// 一块屏幕的遮罩。无边框窗口默认当不了 key（收不到 Esc），所以要子类化
final class SelectionOverlay: NSPanel {
  init(shot: ScreenCapture.Shot, onFinish: @escaping (CGImage?) -> Void) {
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    // 盖住菜单栏、程序坞和其它 App 开着的弹出菜单
    level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    hasShadow = false
    acceptsMouseMovedEvents = true
    let view = SelectionView(image: shot.image, onFinish: onFinish)
    contentView = view
    initialFirstResponder = view
    setFrame(shot.screen.frame, display: false)
  }

  override var canBecomeKey: Bool { true }

  /// 无边框窗口也别被挪到菜单栏下面
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// 冻结帧 + 选区。选区限定在按下时所在的这块屏幕
final class SelectionView: NSView {
  let image: CGImage
  /// 当前选区（点，视图坐标）；截图自检直接设它摆出「拖动中」
  var selection: CGRect? { didSet { needsDisplay = true } }
  private let onFinish: (CGImage?) -> Void
  private var anchor: CGPoint?

  init(image: CGImage, onFinish: @escaping (CGImage?) -> Void) {
    self.image = image
    self.onFinish = onFinish
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
    // 待选时整屏轻微变暗提示「在截图模式」；拖动时选区外更暗、选区保持原样
    let dim = NSBezierPath(rect: bounds)
    if let selection {
      dim.append(NSBezierPath(rect: selection))
      dim.windingRule = .evenOdd
    }
    NSColor.black.withAlphaComponent(selection == nil ? 0.15 : 0.4).setFill()
    dim.fill()
    if let selection {
      NSColor.white.setStroke()
      NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5)).stroke()
    } else {
      drawHint()
    }
  }

  /// 屏幕上方居中的提示胶囊
  private func drawHint() {
    let text = NSAttributedString(
      string: "拖动框选要翻译的文字　Esc 取消",
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
      ])
    let size = text.size()
    let pill = NSRect(
      x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 80, width: size.width + 28,
      height: size.height + 12)
    NSColor.black.withAlphaComponent(0.6).setFill()
    NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    text.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 6))
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    // 本 App 从不激活：.activeAlways 才收得到移动事件（.cursorUpdate 不支持 .activeAlways，光标只能手动设）
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved], owner: self))
  }

  override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

  override func mouseDown(with event: NSEvent) {
    window?.makeKey()  // Esc 跟着最后操作的那块屏幕走
    anchor = point(event)
    selection = nil
  }

  override func mouseDragged(with event: NSEvent) {
    NSCursor.crosshair.set()
    guard let anchor else { return }
    let current = point(event)
    selection = CGRect(
      x: min(anchor.x, current.x), y: min(anchor.y, current.y), width: abs(current.x - anchor.x),
      height: abs(current.y - anchor.y))
  }

  override func mouseUp(with event: NSEvent) {
    anchor = nil
    guard let selection, min(selection.width, selection.height) >= RegionSelector.minimumSide
    else {
      self.selection = nil  // 单击或太小：回到待选，可以重新拖
      return
    }
    let rect = RegionSelector.pixelRect(
      selection, viewSize: bounds.size,
      imageSize: CGSize(width: image.width, height: image.height))
    onFinish(image.cropping(to: rect))
  }

  override func rightMouseDown(with event: NSEvent) { onFinish(nil) }

  override func keyDown(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Escape { onFinish(nil) } else { super.keyDown(with: event) }
  }

  /// 事件位置（视图坐标），夹在本屏范围内
  private func point(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    return CGPoint(
      x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY)
    )
  }
}
