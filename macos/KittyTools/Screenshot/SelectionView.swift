// 框选遮罩里一块屏幕的画面与交互（会话见 RegionSelector）。冻结帧放在图层上，暗色蒙层、选区边框、手柄、尺寸、
// 放大镜都是 CALayer：拖动时只改路径和位置，不重画整屏（5K 屏每次重画几千万像素）；工具栏是 AppKit 按钮。
// 截图翻译：拖动框选、松手即确认（行为不变）。截图：悬停高亮窗口、单击截整窗，拖出或单击后进入调整：
// 8 个手柄、拖动平移、方向键微调（⇧ 10 点）、拖动框选时按住空格平移；放大镜显示中心像素的色值（C 复制）。

import AppKit
import Carbon.HIToolbox

final class SelectionView: NSView {
  enum Mode {
    case translate, capture
  }

  let image: CGImage
  /// 冻结那一刻的窗口（本屏视图坐标，从前到后）
  let windows: [CGRect]
  private let session: SelectionSession
  private var mode: SelectionView.Mode { session.mode }

  /// 当前选区（点，视图坐标）；截图自检直接设它摆出各种状态
  var selection: CGRect? { didSet { refresh() } }
  /// 截图：选区已确定，可以调整、选输出方式
  var isAdjusting = false { didSet { refresh() } }
  /// 截图：鼠标位置（悬停窗口、放大镜）；nil = 鼠标不在这块屏上
  var mouse: CGPoint? { didSet { refresh() } }
  private var drag: Drag? { didSet { refresh() } }
  /// 截图：按住空格时拖动框选变成整块平移（系统截屏的习惯）
  private var isSpaceDown = false

  private enum Drag {
    /// 截图：按下还没拖开，松手算单击（截窗口 / 整屏）
    case pending(CGPoint)
    case draw(anchor: CGPoint, last: CGPoint)
    case move(start: CGPoint, original: CGRect)
    case resize(RegionSelector.Handle, original: CGRect)
  }

  private let canvas = Canvas()
  private let shade = CAShapeLayer()
  private let outline = CAShapeLayer()
  private let highlight = CAShapeLayer()
  private let handles = CAShapeLayer()
  private let sizeLabel = Pill(fontSize: 12)
  private let hint = Pill(fontSize: 13, padding: CGSize(width: 14, height: 6), digits: false)
  private let magnifier = CALayer()
  private let loupe = CALayer()
  private let loupeCenter = CAShapeLayer()
  private let colorLabel = Pill(fontSize: 11)
  private var toolbar: NSView?
  private var toolbarActions: [RegionSelector.Action?] = []
  /// 放大镜上次取样的像素和色值（像素没变就不重取）
  private var sampled: (x: Int, y: Int, hex: String)?

  /// 放大镜取样边长（像素，奇数才有中心）与每个像素放大后的边长（点）
  private static let loupePixels = 15
  private static let loupeCell: CGFloat = 8

  init(image: CGImage, windows: [CGRect] = [], session: SelectionSession) {
    self.image = image
    self.windows = windows
    self.session = session
    super.init(frame: .zero)
    canvas.frame = bounds
    canvas.autoresizingMask = [.width, .height]
    addSubview(canvas)
    let root = canvas.layer!
    root.contents = image
    shade.fillRule = .evenOdd
    for line in [outline, highlight] {
      line.fillColor = nil
      line.strokeColor = NSColor.white.cgColor
      line.lineWidth = 1
    }
    highlight.strokeColor = NSColor.controlAccentColor.cgColor
    highlight.lineWidth = 2
    handles.fillColor = NSColor.white.cgColor
    handles.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
    handles.lineWidth = 1
    let side = CGFloat(Self.loupePixels) * Self.loupeCell
    loupe.frame = CGRect(x: 0, y: 26, width: side, height: side)
    loupe.magnificationFilter = .nearest
    loupe.borderColor = NSColor.white.cgColor
    loupe.borderWidth = 1
    loupe.cornerRadius = 6
    loupe.masksToBounds = true
    loupe.backgroundColor = NSColor.black.cgColor
    loupeCenter.frame = loupe.bounds
    loupeCenter.path = CGPath(
      rect: CGRect(
        x: CGFloat(Self.loupePixels / 2) * Self.loupeCell,
        y: CGFloat(Self.loupePixels / 2) * Self.loupeCell, width: Self.loupeCell,
        height: Self.loupeCell), transform: nil)
    loupeCenter.fillColor = nil
    loupeCenter.strokeColor = NSColor.white.cgColor
    loupe.addSublayer(loupeCenter)
    magnifier.bounds = CGRect(x: 0, y: 0, width: side, height: loupe.frame.maxY)
    magnifier.anchorPoint = .zero
    // 白框在白底上也看得见
    for layer in [magnifier, loupeCenter] {
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = 0.6
      layer.shadowRadius = 1
      layer.shadowOffset = .zero
    }
    magnifier.addSublayer(loupe)
    magnifier.addSublayer(colorLabel.layer)
    for layer in [shade, highlight, outline, handles, sizeLabel.layer, hint.layer, magnifier] {
      root.addSublayer(layer)
    }
    hint.text =
      mode == .translate
      ? "拖动框选要翻译的文字　Esc 取消"
      : "拖动框选，单击截取窗口" + (session.lastRegion == nil ? "" : "　D 上次区域") + "　Esc 取消"
    if mode == .capture { toolbar = makeToolbar() }
    updateScale()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    canvas.layer?.frame = CGRect(origin: .zero, size: newSize)
    refresh()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
  }

  /// 外部选中一块区域并进入调整（D 键上次区域）
  func select(_ rect: CGRect) {
    drag = nil
    selection = rect
    isAdjusting = true
    refreshCursor()
  }

  /// 回到待选（别的屏开始操作时）
  func reset() {
    drag = nil
    selection = nil
    isAdjusting = false
    mouse = nil
    isSpaceDown = false
  }

  // MARK: 画面

  /// 图层的像素密度跟着屏幕走，不然 Retina 上线条和文字是糊的
  private func updateScale() {
    let scale = window?.backingScaleFactor ?? 2
    for layer in [shade, outline, highlight, handles, loupeCenter] { layer.contentsScale = scale }
    for pill in [sizeLabel, hint, colorLabel] { pill.scale = scale }
  }

  /// 按状态摆好全部图层（关掉隐式动画，拖动时跟手）
  private func refresh() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let hovered = selection == nil ? mouse.flatMap(windowRect(at:)) : nil
    let hole = selection ?? hovered
    let path = CGMutablePath()
    path.addRect(bounds)
    if let hole { path.addRect(hole) }
    shade.path = path
    // 待选时整屏轻微变暗提示「在截图模式」；有选区（或悬停的窗口）时选区外更暗、选区保持原样
    shade.fillColor = NSColor.black.withAlphaComponent(hole == nil ? 0.15 : 0.4).cgColor
    outline.path = selection.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
    highlight.path = hovered.map { CGPath(rect: $0.insetBy(dx: 1, dy: 1), transform: nil) }
    hint.layer.isHidden = selection != nil
    if selection == nil {
      hint.place(at: CGPoint(x: bounds.midX - hint.size.width / 2, y: bounds.maxY - 80))
    }

    let adjusting = mode == .capture && isAdjusting
    handles.path = adjusting ? selection.map(Self.handlesPath) : nil
    if let toolbar {
      toolbar.isHidden = !(adjusting && drag == nil && selection != nil)
      if !toolbar.isHidden, let selection { placeToolbar(toolbar, near: selection) }
    }
    sizeLabel.layer.isHidden = mode == .translate || selection == nil
    if mode == .capture, let selection {
      let pixels = RegionSelector.pixelRect(
        selection, viewSize: bounds.size,
        imageSize: CGSize(width: image.width, height: image.height))
      sizeLabel.text = "\(Int(pixels.width)) × \(Int(pixels.height))"
      // 选区左上角外面；放不下、或被翻到上方的工具栏挡住时放进选区里
      let size = sizeLabel.size
      let x = min(selection.minX, bounds.maxX - size.width)
      var y = selection.maxY + 6
      if y + size.height > bounds.maxY
        || isOverToolbar(CGRect(x: x, y: y, width: size.width, height: size.height))
      {
        y = selection.maxY - 6 - size.height
      }
      sizeLabel.place(at: CGPoint(x: x, y: y))
    }
    updateMagnifier()
  }

  private func updateMagnifier() {
    guard let mouse, showsMagnifier else {
      magnifier.isHidden = true
      return
    }
    let scaleX = CGFloat(image.width) / max(bounds.width, 1)
    let scaleY = CGFloat(image.height) / max(bounds.height, 1)
    let x = min(max(Int(mouse.x * scaleX), 0), image.width - 1)
    let y = min(max(Int((bounds.height - mouse.y) * scaleY), 0), image.height - 1)
    if sampled?.x != x || sampled?.y != y,
      let sample = Self.sample(image, x: x, y: y, size: Self.loupePixels)
    {
      loupe.contents = sample.image
      sampled = (x, y, sample.hex)
      colorLabel.text = "\(sample.hex)　C 复制"
    }
    colorLabel.place(at: CGPoint(x: (magnifier.bounds.width - colorLabel.size.width) / 2, y: 0))
    // 放在光标右下，靠边时翻到另一侧
    let size = magnifier.bounds.size
    var origin = CGPoint(x: mouse.x + 20, y: mouse.y - 20 - size.height)
    if origin.x + size.width > bounds.maxX { origin.x = mouse.x - 20 - size.width }
    if origin.y < bounds.minY { origin.y = mouse.y + 20 }
    magnifier.position = origin
    magnifier.isHidden = false
  }

  /// 截图：待选、拖动框选、拖手柄时显示放大镜；平移选区、鼠标在工具栏上时不显示
  private var showsMagnifier: Bool {
    guard mode == .capture, let mouse, !isOverToolbar(mouse) else { return false }
    switch drag {
    case .move?: return false
    case .pending?, .draw?, .resize?: return true
    case nil: return !isAdjusting
    }
  }

  private static func handlesPath(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    for handle in RegionSelector.Handle.allCases {
      let point = handle.point(in: rect)
      path.addEllipse(in: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
    }
    return path
  }

  /// 以像素 (x, y)（原点左上）为中心取 size×size 像素，转成 sRGB（放大镜显示用），中心像素的色值写成 #RRGGBB。
  /// 超出图的部分是黑色。纯函数，配单测
  static func sample(_ image: CGImage, x: Int, y: Int, size: Int) -> (image: CGImage, hex: String)?
  {
    let half = size / 2
    let region = CGRect(x: x - half, y: y - half, width: size, height: size)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let visible = region.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    if !visible.isNull, let crop = image.cropping(to: visible) {
      // 上下文原点在左下，图的行从上往下：按 y 翻转放到对应位置
      context.draw(
        crop,
        in: CGRect(
          x: visible.minX - region.minX, y: region.maxY - visible.maxY, width: visible.width,
          height: visible.height))
    }
    guard let data = context.data, let zoomed = context.makeImage() else { return nil }
    // 内存里第 0 行是图的顶行
    let pixel = data.assumingMemoryBound(to: UInt8.self) + half * size * 4 + half * 4
    return (zoomed, String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2]))
  }

  // MARK: 工具栏

  private func makeToolbar() -> NSView {
    let items: [(symbol: String, tip: String, action: RegionSelector.Action?)] = [
      ("pin", "钉图（T）", .pin),
      ("square.and.arrow.down.on.square", "另存为…（⇧⌘S）", .saveAs),
      (
        "square.and.arrow.down", "保存到「\(ScreenshotOutput.saveDirectory.lastPathComponent)」（⌘S）",
        .save
      ),
      ("xmark", "取消（Esc）", nil),
      ("checkmark", "复制（↩）", .copy),
    ]
    toolbarActions = items.map(\.action)
    let buttons = items.enumerated().map { index, item in
      let button = ToolbarButton(
        image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tip)!,
        target: self, action: #selector(toolbarClicked(_:)))
      button.tag = index
      button.toolTip = item.tip
      button.isBordered = false
      button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
      button.contentTintColor = item.action == .copy ? .controlAccentColor : .labelColor
      button.widthAnchor.constraint(equalToConstant: 32).isActive = true
      button.heightAnchor.constraint(equalToConstant: 28).isActive = true
      return button
    }
    let stack = NSStackView(views: buttons)
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
    stack.translatesAutoresizingMaskIntoConstraints = false
    // 模糊的是窗口里的冻结帧（withinWindow），不是窗口背后真实的桌面
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .withinWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 8
    background.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      stack.topAnchor.constraint(equalTo: background.topAnchor),
      stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    background.frame.size = stack.fittingSize
    background.isHidden = true
    addSubview(background)
    return background
  }

  /// 选区右下角的下方；下面放不下放上面，都放不下放进选区里
  private func placeToolbar(_ toolbar: NSView, near rect: CGRect) {
    let size = toolbar.frame.size
    let gap: CGFloat = 8
    var y = rect.minY - gap - size.height
    if y < bounds.minY + gap { y = rect.maxY + gap }
    if y + size.height > bounds.maxY - gap { y = rect.minY + gap }
    let x = min(max(rect.maxX - size.width, bounds.minX + gap), bounds.maxX - size.width - gap)
    toolbar.frame.origin = CGPoint(x: x, y: y)
  }

  private func isOverToolbar(_ point: CGPoint) -> Bool {
    guard let toolbar, !toolbar.isHidden else { return false }
    return toolbar.frame.contains(point)
  }

  private func isOverToolbar(_ rect: CGRect) -> Bool {
    guard let toolbar, !toolbar.isHidden else { return false }
    return toolbar.frame.intersects(rect)
  }

  @objc private func toolbarClicked(_ sender: NSButton) {
    if let action = toolbarActions[sender.tag] { output(action) } else { session.finish(nil) }
  }

  // MARK: 输出

  private func output(_ action: RegionSelector.Action) {
    guard let selection, let window else { return }
    let rect = RegionSelector.pixelRect(
      selection, viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height))
    guard let crop = image.cropping(to: rect) else { return session.finish(nil) }
    session.finish(
      .capture(
        .init(
          image: mode == .capture ? RegionSelector.detached(crop) : crop,
          frame: selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY), action: action)))
  }

  /// 本屏在 point 下最前面的窗口（夹在本屏内）
  private func windowRect(at point: CGPoint) -> CGRect? {
    guard mode == .capture else { return nil }
    return windows.first { $0.contains(point) }?.intersection(bounds)
  }

  // MARK: 鼠标

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    // 本 App 从不激活：.activeAlways 才收得到移动事件（.cursorUpdate 不支持 .activeAlways，光标只能手动设）
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
        owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    guard mode == .capture else { return NSCursor.crosshair.set() }
    // 别的屏上有选区时这块屏不悬停、不出放大镜（单击不会抢走那边的选区，拖动才开新选区）；
    // 否则鼠标到哪块屏，哪块屏收按键（C 复制的是眼前放大镜的色值）。不激活本 App
    if session.hasSelection(besides: self) {
      mouse = nil
    } else {
      if window?.isKeyWindow == false { window?.makeKey() }
      mouse = point(event)
    }
    refreshCursor()
  }

  override func mouseExited(with event: NSEvent) {
    if mode == .capture { mouse = nil }
  }

  override func mouseDown(with event: NSEvent) {
    let point = point(event)
    guard mode == .capture else {
      window?.makeKey()  // 按键跟着最后操作的那块屏幕走
      session.activate(self)
      selection = nil
      drag = .draw(anchor: point, last: point)
      return
    }
    // 别的屏上有选区：先记下按下的点，拖开了才算在这块屏开始（见 mouseDragged）
    if !session.hasSelection(besides: self) {
      window?.makeKey()
      session.activate(self)
      mouse = point
    }
    if isAdjusting, let selection {
      if event.clickCount == 2, selection.contains(point) { return output(.copy) }
      if let handle = RegionSelector.handle(at: point, in: selection) {
        drag = .resize(handle, original: selection)
        return
      }
      if selection.contains(point) {
        NSCursor.closedHand.set()
        drag = .move(start: point, original: selection)
        return
      }
    }
    drag = .pending(point)
  }

  override func mouseDragged(with event: NSEvent) {
    let point = point(event)
    if mode == .capture, !session.hasSelection(besides: self) { mouse = point }
    switch drag {
    case .pending(let start)?:
      guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
      window?.makeKey()
      session.activate(self)
      isAdjusting = false
      drag = .draw(anchor: start, last: start)
      extend(to: point)
    case .draw?:
      extend(to: point)
    case .move(let start, let original)?:
      NSCursor.closedHand.set()
      selection = RegionSelector.moved(
        original, by: CGSize(width: point.x - start.x, height: point.y - start.y), within: bounds)
    case .resize(let handle, let original)?:
      selection = RegionSelector.resized(original, handle, to: point, within: bounds)
    case nil:
      break
    }
  }

  /// 拖动框选：从锚点拉到当前点；截图时按住空格整块平移，锚点跟着走
  private func extend(to point: CGPoint) {
    guard case .draw(var anchor, let last)? = drag else { return }
    NSCursor.crosshair.set()
    if mode == .capture, isSpaceDown, let current = selection {
      let moved = RegionSelector.moved(
        current, by: CGSize(width: point.x - last.x, height: point.y - last.y), within: bounds)
      anchor.x += moved.minX - current.minX
      anchor.y += moved.minY - current.minY
      selection = moved
    } else {
      selection = CGRect(
        x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x),
        height: abs(point.y - anchor.y))
    }
    drag = .draw(anchor: anchor, last: point)
  }

  override func mouseUp(with event: NSEvent) {
    let finished = drag
    drag = nil
    switch finished {
    case .pending(let point)?:
      // 单击：截鼠标下最前面的窗口，没有窗口就截整屏；已有选区（本屏或别的屏）时点选区外什么也不做，
      // 免得误点丢掉选区
      if !isAdjusting, !session.hasSelection(besides: self) {
        select(windowRect(at: point) ?? bounds)
      }
    case .draw?:
      guard let selection, min(selection.width, selection.height) >= RegionSelector.minimumSide
      else {
        self.selection = nil  // 单击或太小：回到待选，可以重新拖
        return
      }
      if mode == .translate { output(.copy) } else { isAdjusting = true }
    case .move?, .resize?, nil:
      break
    }
    if mode == .capture { refreshCursor() }
  }

  override func rightMouseDown(with event: NSEvent) {
    // 截图：有选区时（不管在哪块屏）右键回到待选、重新框，没有才取消；截图翻译直接取消
    guard mode == .capture, session.hasSelection(besides: nil) else { return session.finish(nil) }
    session.activate(self)
    reset()
    window?.makeKey()
    mouse = point(event)
    refreshCursor()
  }

  /// 光标只能手动设（见 updateTrackingAreas）：状态一变就按鼠标当前位置重设
  private func refreshCursor() {
    guard mode == .capture else { return }
    guard isAdjusting, let selection, let point = mouse else { return NSCursor.crosshair.set() }
    if isOverToolbar(point) { return NSCursor.arrow.set() }
    if let handle = RegionSelector.handle(at: point, in: selection) {
      return NSCursor.frameResize(position: Self.position(of: handle), directions: .all).set()
    }
    (selection.contains(point) ? NSCursor.openHand : NSCursor.crosshair).set()
  }

  private static func position(of handle: RegionSelector.Handle) -> NSCursor.FrameResizePosition {
    switch handle {
    case .bottomLeft: .bottomLeft
    case .bottom: .bottom
    case .bottomRight: .bottomRight
    case .right: .right
    case .topRight: .topRight
    case .top: .top
    case .topLeft: .topLeft
    case .left: .left
    }
  }

  /// 事件位置（视图坐标），夹在本屏范围内
  private func point(_ event: NSEvent) -> CGPoint {
    clamped(convert(event.locationInWindow, from: nil))
  }

  func clamped(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY)
    )
  }

  // MARK: 键盘

  override func keyDown(with event: NSEvent) {
    let code = Int(event.keyCode)
    if code == kVK_Escape { return session.finish(nil) }
    // 单字母键不带 ⌘ ⌃ ⌥（⌘C 之类走 performKeyEquivalent）。ponytail: 按物理键位，Dvorak 等布局下位置不同
    guard mode == .capture, event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    else { return super.keyDown(with: event) }
    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
    switch code {
    case kVK_Return, kVK_ANSI_KeypadEnter:
      if isAdjusting { output(.copy) }
    case kVK_ANSI_T:
      if isAdjusting { output(.pin) }
    case kVK_ANSI_D:
      session.selectLastRegion()
    case kVK_ANSI_C:
      if showsMagnifier, let sampled { session.finish(.color(sampled.hex)) }
    case kVK_Space:
      isSpaceDown = true
    case kVK_LeftArrow: nudge(-step, 0)
    case kVK_RightArrow: nudge(step, 0)
    case kVK_UpArrow: nudge(0, step)
    case kVK_DownArrow: nudge(0, -step)
    default:
      super.keyDown(with: event)
    }
  }

  override func keyUp(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Space { isSpaceDown = false } else { super.keyUp(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard mode == .capture, isAdjusting, window?.isKeyWindow == true,
      Int(event.keyCode) == kVK_ANSI_C || Int(event.keyCode) == kVK_ANSI_S
    else { return super.performKeyEquivalent(with: event) }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if flags == .command {
      output(Int(event.keyCode) == kVK_ANSI_C ? .copy : .save)
    } else if flags == [.command, .shift], Int(event.keyCode) == kVK_ANSI_S {
      output(.saveAs)
    } else {
      return super.performKeyEquivalent(with: event)
    }
    return true
  }

  /// 方向键微调选区（调整时）
  private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
    guard isAdjusting, let selection else { return }
    self.selection = RegionSelector.moved(
      selection, by: CGSize(width: dx, height: dy), within: bounds)
    refreshCursor()
  }
}

/// 只放图层、不接事件（事件都给 SelectionView）。先设 layer 再 wantsLayer：layer-hosting，可以随意加子图层
private final class Canvas: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    layer = CALayer()
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 遮罩不是 key 的那块屏上也要一点就响应
private final class ToolbarButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 半透明黑底圆角胶囊里一行白字：提示、尺寸、色值共用
private struct Pill {
  let layer = CALayer()
  private let textLayer = CATextLayer()
  private let font: NSFont
  private let padding: CGSize

  /// digits：数字等宽（尺寸、色值跟着鼠标变时不抖）
  init(fontSize: CGFloat, padding: CGSize = CGSize(width: 10, height: 4), digits: Bool = true) {
    font =
      digits
      ? .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
      : .systemFont(ofSize: fontSize, weight: .medium)
    self.padding = padding
    layer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
    layer.anchorPoint = .zero
    textLayer.foregroundColor = NSColor.white.cgColor
    layer.addSublayer(textLayer)
  }

  var text: String {
    get { (textLayer.string as? NSAttributedString)?.string ?? "" }
    nonmutating set {
      let string = NSAttributedString(
        string: newValue, attributes: [.font: font, .foregroundColor: NSColor.white])
      let textSize = string.size()
      textLayer.string = string
      textLayer.frame = CGRect(
        x: padding.width, y: padding.height, width: ceil(textSize.width),
        height: ceil(textSize.height))
      layer.bounds.size = CGSize(
        width: ceil(textSize.width) + padding.width * 2,
        height: ceil(textSize.height) + padding.height * 2)
      layer.cornerRadius = layer.bounds.height / 2
    }
  }

  var size: CGSize { layer.bounds.size }

  var scale: CGFloat {
    get { textLayer.contentsScale }
    nonmutating set { textLayer.contentsScale = newValue }
  }

  /// 左下角放在 origin
  func place(at origin: CGPoint) { layer.position = origin }
}
