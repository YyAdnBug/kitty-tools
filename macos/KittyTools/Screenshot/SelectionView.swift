// 框选遮罩里一块屏幕的画面与交互（会话见 RegionSelector）。从下到上：冻结帧（本视图图层的内容）→ 标注层
// （AnnotationCanvas，只重画变了的那块）→ 暗色蒙层、选区边框、手柄、尺寸、放大镜（CALayer，拖动时只改路径和位置，
// 不重画整屏）→ 文字输入框 → 工具栏与样式栏（EditorToolbar）。
// 截图翻译 / 识字：拖动框选、松手即确认。截图：悬停高亮窗口、单击截整窗，拖出或单击后进入调整：整条边和四角都能拖、拖动平移、
// 方向键微调（⇧ 10 点）、拖动框选时按住空格平移；放大镜显示中心像素的色值（C 复制），按住 ⌘ 出整屏十字准线；S 长截图；
// 标注 1–0（矩形、椭圆、箭头、直线、画笔、荧光笔、文字、序号、马赛克、聚光灯，⇧ 画正方形 / 45° 线），
// 点中标注可拖动、改颜色粗细、⌫ 删除、双击文字重新编辑，⌘Z 撤销、⇧⌘Z 重做。

import AppKit
import Carbon.HIToolbox

final class SelectionView: NSView, NSTextViewDelegate {
  enum Mode {
    /// 截图翻译、识字：松手即确认
    case quick
    case capture
  }

  let image: CGImage
  /// 冻结那一刻的窗口（本屏视图坐标，从前到后）
  let windows: [CGRect]
  private let session: SelectionSession
  private var mode: SelectionView.Mode { session.mode }

  /// 当前选区（点，视图坐标）；截图自检直接设它摆出各种状态
  var selection: CGRect? {
    didSet {
      annotationCanvas?.selection = selection
      refresh()
    }
  }
  /// 截图：选区已确定，可以调整、标注、选输出方式
  var isAdjusting = false { didSet { refresh() } }
  /// 截图：鼠标位置（悬停窗口、放大镜）；nil = 鼠标不在这块屏上
  var mouse: CGPoint? { didSet { refresh() } }
  private var drag: Drag? { didSet { refresh() } }
  /// 截图：按住空格时拖动框选变成整块平移（系统截屏的习惯）
  private var isSpaceDown = false
  /// 按住 ⌘：出十字准线。按键和鼠标事件都带着修饰键，鼠标从别的屏移过来时也是准的
  private var isCommandDown = false {
    didSet { if isCommandDown != oldValue { refresh() } }
  }

  // 标注（截图模式）。截图自检直接设它们摆出各种状态
  var annotations: [Annotation] = [] { didSet { syncAnnotations() } }
  var tool: Annotation.Tool? { didSet { refresh() } }
  var selectedAnnotation: UUID? { didSet { refresh() } }
  /// 新标注用的颜色和粗细
  var style = Annotation.Style()
  /// 正在拖出来的标注
  private var draft: Annotation? { didSet { syncAnnotations() } }
  private var undoStack: [[Annotation]] = []
  private var redoStack: [[Annotation]] = []
  /// 正在输入的文字：输入框、改的是哪条标注（nil = 新建）、左上角、样式
  private var editor: Editor?

  private struct Editor {
    let field: NSTextView
    /// 每个输入框自己的撤销记录（共用窗口的会串到已经收掉的输入框上）
    let undo = UndoManager()
    let id: UUID?
    let origin: CGPoint
    var style: Annotation.Style
  }

  private enum Drag {
    /// 截图：按下还没拖开，松手算单击（截窗口 / 整屏）
    case pending(CGPoint)
    /// restore：调整时在选区外拖出新框之前的选区（新框太小算误触，恢复它）
    case draw(anchor: CGPoint, last: CGPoint, restore: CGRect? = nil)
    case move(start: CGPoint, original: CGRect)
    case resize(RegionSelector.Handle, original: CGRect)
    /// 用当前工具拖出新标注
    case annotate(start: CGPoint)
    /// 拖动已有的标注；before 是拖之前的全部标注（松手时记一步撤销）
    case moveAnnotation(UUID, start: CGPoint, before: [Annotation])
  }

  private var annotationCanvas: AnnotationCanvas?
  private let canvas = Canvas()
  private let shade = CAShapeLayer()
  private let outline = CAShapeLayer()
  private let highlight = CAShapeLayer()
  private let handles = CAShapeLayer()
  private let annotationOutline = CAShapeLayer()
  /// 选区双描边的外圈（内圈 white 0.9 是 outline）
  private let outlineOuter = CAShapeLayer()
  /// 按住 ⌘ 时穿过光标的十字准线：1 pt white 0.6 贴 1 pt black 0.25，亮底暗底都看得见
  private let crossLight = CAShapeLayer()
  private let crossDark = CAShapeLayer()
  private let sizeLabel = Pill(fontSize: 12, weight: .semibold, radius: Style.Radius.control)
  private let hint = Pill(
    fontSize: 13, padding: CGSize(width: 14, height: 7), digits: false, weight: .regular)
  private let magnifier = CALayer()
  private let loupe = CALayer()
  private let loupeShadow = CALayer()
  private let loupeGrid = CAShapeLayer()
  private let loupeBands = CAShapeLayer()
  private let loupeCenter = CAShapeLayer()
  private let infoCard = CALayer()
  private let infoSwatch = CALayer()
  private let infoText = CATextLayer()
  private let infoKey = CATextLayer()
  private var toolbar: EditorToolbar?
  private var styleBar: StyleBar?
  /// 放大镜上次取样的像素和色值（像素没变就不重取）
  private var sampled: (x: Int, y: Int, hex: String)?
  /// 上次画的悬停窗口：换到别的窗口时，洞和高亮框磁吸变形过去（S5）
  private var shownHover: CGRect?
  /// 上次有没有洞：有无变化时蒙层深浅过渡
  private var hadHole = false
  /// 放大镜上次在光标哪一侧（翻边时滑过去）
  private var magnifierSide: (left: Bool, above: Bool)?
  private var hintDismissed = false

  /// 放大镜取样边长（像素，奇数才有中心）、每个像素放大后的边长（点）、下方信息卡高度
  private static let loupePixels = 15
  private static let loupeCell: CGFloat = 9
  private static let infoHeight: CGFloat = 40

  init(image: CGImage, windows: [CGRect] = [], session: SelectionSession) {
    self.image = image
    self.windows = windows
    self.session = session
    super.init(frame: .zero)
    wantsLayer = true
    if session.mode == .capture {
      let view = AnnotationCanvas(image: image)
      view.autoresizingMask = [.width, .height]
      addSubview(view)
      annotationCanvas = view
    }
    canvas.autoresizingMask = [.width, .height]
    addSubview(canvas)
    let root = canvas.layer!
    shade.fillRule = .evenOdd
    shade.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
    outline.fillColor = nil
    outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
    outline.lineWidth = 1
    outlineOuter.fillColor = nil
    outlineOuter.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
    outlineOuter.lineWidth = 1
    highlight.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    highlight.strokeColor = NSColor.controlAccentColor.cgColor
    highlight.lineWidth = 2
    handles.fillColor = NSColor.white.cgColor
    handles.strokeColor = NSColor.black.withAlphaComponent(0.25).cgColor
    handles.lineWidth = 0.5
    handles.shadowColor = NSColor.black.cgColor
    handles.shadowOpacity = 0.35
    handles.shadowRadius = 1.5
    handles.shadowOffset = CGSize(width: 0, height: -0.5)
    annotationOutline.fillColor = nil
    annotationOutline.strokeColor = NSColor.controlAccentColor.cgColor
    annotationOutline.lineWidth = 1
    annotationOutline.lineDashPattern = [4, 3]
    for (layer, color) in [
      (crossLight, NSColor.white.withAlphaComponent(0.6)),
      (crossDark, .black.withAlphaComponent(0.25)),
    ] {
      layer.fillColor = nil
      layer.strokeColor = color.cgColor
      layer.lineWidth = 1
    }
    setUpMagnifier()
    for layer in [
      shade, highlight, outlineOuter, outline, crossDark, crossLight, handles, annotationOutline,
      sizeLabel.layer, hint.layer, magnifier,
    ] {
      root.addSublayer(layer)
    }
    hint.text =
      mode == .quick
      ? session.hint
      : "拖动框选，单击截取窗口" + (session.lastRegion == nil ? "" : "　D 上次区域") + "　Esc 取消"
    if mode == .capture { makeBars() }
    updateScale()
  }

  /// 放大镜：15 × 15 像素、每格 9 pt（135 pt，圆角 10，2 pt 白环 + 阴影），0.5 pt 像素网格，中心行列强调色十字条带，
  /// 中心格按亮度描黑或白；下贴一张 40 pt 的 HUD 信息卡（色块 + HEX + 坐标 +「C」键帽）
  private func setUpMagnifier() {
    let side = CGFloat(Self.loupePixels) * Self.loupeCell
    let cell = Self.loupeCell
    let middle = CGFloat(Self.loupePixels / 2) * cell
    let loupeFrame = CGRect(x: 0, y: Self.infoHeight + 6, width: side, height: side)
    loupe.frame = loupeFrame
    loupe.magnificationFilter = .nearest
    loupe.cornerRadius = Style.Radius.card
    loupe.cornerCurve = .continuous
    loupe.masksToBounds = true
    loupe.backgroundColor = NSColor.black.cgColor
    loupe.borderColor = NSColor.white.cgColor
    loupe.borderWidth = 2
    loupeShadow.frame = loupeFrame
    loupeShadow.shadowPath = CGPath(
      roundedRect: loupeShadow.bounds, cornerWidth: Style.Radius.card,
      cornerHeight: Style.Radius.card, transform: nil)
    loupeShadow.shadowColor = NSColor.black.cgColor
    loupeShadow.shadowOpacity = 0.45
    loupeShadow.shadowRadius = 6
    loupeShadow.shadowOffset = CGSize(width: 0, height: -2)
    let grid = CGMutablePath()
    for index in 1..<Self.loupePixels {
      let offset = CGFloat(index) * cell
      grid.move(to: CGPoint(x: offset, y: 0))
      grid.addLine(to: CGPoint(x: offset, y: side))
      grid.move(to: CGPoint(x: 0, y: offset))
      grid.addLine(to: CGPoint(x: side, y: offset))
    }
    loupeGrid.frame = loupe.bounds
    loupeGrid.path = grid
    loupeGrid.strokeColor = NSColor.black.withAlphaComponent(0.14).cgColor
    loupeGrid.lineWidth = 0.5
    let bands = CGMutablePath()
    bands.addRect(CGRect(x: 0, y: middle, width: side, height: cell))
    bands.addRect(CGRect(x: middle, y: 0, width: cell, height: side))
    loupeBands.frame = loupe.bounds
    loupeBands.path = bands
    loupeBands.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    loupeCenter.frame = loupe.bounds
    loupeCenter.path = CGPath(
      rect: CGRect(x: middle, y: middle, width: cell, height: cell), transform: nil)
    loupeCenter.fillColor = nil
    loupeCenter.strokeColor = NSColor.white.cgColor
    loupeCenter.lineWidth = 1
    for layer in [loupeBands, loupeGrid, loupeCenter] { loupe.addSublayer(layer) }
    infoCard.frame = CGRect(x: 0, y: 0, width: side, height: Self.infoHeight)
    infoCard.backgroundColor = NSColor(white: 0.11, alpha: 0.86).cgColor
    infoCard.cornerRadius = 8
    infoCard.cornerCurve = .continuous
    infoCard.borderWidth = 0.5
    infoCard.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    infoSwatch.frame = CGRect(x: 10, y: 12, width: 16, height: 16)
    infoSwatch.cornerRadius = 4
    infoSwatch.borderWidth = 0.5
    infoSwatch.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
    infoText.frame = CGRect(x: 34, y: 5, width: side - 34 - 34, height: 30)
    infoText.isWrapped = false
    infoKey.frame = CGRect(x: side - 30, y: 11, width: 20, height: 18)
    infoKey.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    infoKey.cornerRadius = 4
    infoKey.alignmentMode = .center
    infoKey.string = NSAttributedString(
      string: "C",
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        .baselineOffset: -2,
      ])
    for layer in [infoSwatch, infoText, infoKey] { infoCard.addSublayer(layer) }
    magnifier.bounds = CGRect(x: 0, y: 0, width: side, height: loupeFrame.maxY)
    magnifier.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    for layer in [loupeShadow, loupe, infoCard] { magnifier.addSublayer(layer) }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() { layer?.contents = image }

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
    draft = nil
    selection = rect
    isAdjusting = true
    refreshCursor()
  }

  /// 回到待选（别的屏开始操作、右键重新框时）：标注一起清掉
  func reset() {
    endEditing()
    drag = nil
    draft = nil
    selection = nil
    isAdjusting = false
    mouse = nil
    isSpaceDown = false
    tool = nil
    selectedAnnotation = nil
    undoStack = []
    redoStack = []
    annotations = []
  }

  // MARK: 画面

  /// 图层的像素密度跟着屏幕走，不然 Retina 上线条和文字是糊的
  private func updateScale() {
    let scale = window?.backingScaleFactor ?? 2
    for layer in [
      shade, outline, outlineOuter, crossLight, crossDark, highlight, handles, annotationOutline,
      loupeGrid, loupeBands, loupeCenter, infoText, infoKey,
    ] as [CALayer] {
      layer.contentsScale = scale
    }
    for pill in [sizeLabel, hint] { pill.scale = scale }
  }

  /// 出场：蒙层 0.15 s 淡入；提示从下方 8 pt 浮上来，3 s 后淡出
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    updateScale()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.15
    shade.add(fade, forKey: "enter")
    let rise = CABasicAnimation(keyPath: "transform.translation.y")
    rise.fromValue = Style.reduceMotion ? 0 : -8
    rise.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [fade, rise]
    group.duration = 0.3
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    hint.layer.add(group, forKey: "enter")
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      self?.dismissHint()
    }
  }

  private func dismissHint() {
    guard !hintDismissed else { return }
    hintDismissed = true
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = hint.layer.presentation()?.opacity ?? 1
    fade.toValue = 0
    fade.duration = 0.3
    hint.layer.opacity = 0
    hint.layer.add(fade, forKey: "leave")
  }

  /// 按状态摆好全部图层（关掉隐式动画，拖动时跟手；只有换悬停窗口、蒙层深浅切换、放大镜出现 / 翻边时才加动画）
  private func refresh() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let hovered = selection == nil ? mouse.flatMap(windowRect(at:)) : nil
    let hole = selection ?? hovered
    let path = CGMutablePath()
    path.addRect(bounds)
    if let selection {
      path.addRect(selection)
    } else if let hovered {
      path.addPath(Self.rounded(hovered))
    }
    // S5 窗口磁吸：换到另一个窗口时，洞和高亮框从当前（可能还在动的）形状弹簧变形过去。路径元素数恒定（矩形 + 圆角矩形）
    let morphs =
      selection == nil && drag == nil && hovered != nil && shownHover != nil
      && hovered != shownHover
    let oldShade = shade.presentation()?.path ?? shade.path
    let oldHighlight = highlight.presentation()?.path ?? highlight.path
    shade.path = path
    highlight.path = hovered.map { Self.rounded($0.insetBy(dx: 1, dy: 1)) }
    if morphs, let morph = Style.Motion.glide.caAnimation(keyPath: "path") as? CABasicAnimation {
      morph.fromValue = oldShade
      shade.add(morph, forKey: "morph")
      if let copy = morph.copy() as? CABasicAnimation {
        copy.fromValue = oldHighlight
        highlight.add(copy, forKey: "morph")
      }
    } else if hovered != shownHover || selection != nil {
      // 路径结构变了（选中了、移到桌面）：还在跑的变形动画插值会乱，去掉
      shade.removeAnimation(forKey: "morph")
      highlight.removeAnimation(forKey: "morph")
    }
    shownHover = hovered
    // 待选时整屏轻暗 0.18；有选区（或悬停的窗口）时洞外 0.45，切换时过渡 0.12 s
    let fill = NSColor.black.withAlphaComponent(hole == nil ? 0.18 : 0.45).cgColor
    if (hole != nil) != hadHole {
      let fade = CABasicAnimation(keyPath: "fillColor")
      fade.fromValue = shade.presentation()?.fillColor ?? shade.fillColor
      fade.toValue = fill
      fade.duration = 0.12
      shade.add(fade, forKey: "fill")
    }
    shade.fillColor = fill
    hadHole = hole != nil
    // 选区双描边：内 1 pt white 0.9 + 外 1 pt black 0.28（亮底暗底都看得清）
    outline.path = selection.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
    outlineOuter.path = selection.map {
      CGPath(rect: $0.insetBy(dx: -1.5, dy: -1.5), transform: nil)
    }
    hint.layer.isHidden = selection != nil || hintDismissed
    if selection == nil {
      hint.place(
        at: CGPoint(x: bounds.midX - hint.size.width / 2, y: bounds.maxY - 64 - hint.size.height))
    }

    let adjusting = mode == .capture && isAdjusting
    let wasShowingHandles = handles.path != nil
    handles.path = adjusting ? selection.map(Self.handlesPath) : nil
    handles.shadowPath = handles.path
    if adjusting, !wasShowingHandles {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = 0.18
      handles.add(fade, forKey: "appear")
    }
    // 输入文字时输入框自己有边框，不再画选中框（大小会跟着输入变）
    annotationOutline.path =
      editor == nil
      ? selected.map { CGPath(rect: $0.bounds.insetBy(dx: -4, dy: -4), transform: nil) } : nil
    placeBars(showing: adjusting && drag == nil)
    sizeLabel.layer.isHidden = mode == .quick || selection == nil
    if mode == .capture, let selection {
      let pixels = RegionSelector.pixelRect(
        selection, viewSize: bounds.size,
        imageSize: CGSize(width: image.width, height: image.height))
      sizeLabel.setSize(width: Int(pixels.width), height: Int(pixels.height))
      // 选区左上角外面；放不下、或被翻到上方的工具栏挡住时放进选区里
      let size = sizeLabel.size
      let x = min(selection.minX, bounds.maxX - size.width)
      var y = selection.maxY + 6
      if y + size.height > bounds.maxY
        || isOverBars(CGRect(x: x, y: y, width: size.width, height: size.height))
      {
        y = selection.maxY - 6 - size.height
      }
      sizeLabel.place(at: CGPoint(x: x, y: y))
    }
    updateMagnifier()
    updateCrosshair()
  }

  /// 十字准线跟放大镜同时出现（待选、拖动框选、拖手柄），只在按住 ⌘ 时；对齐到整点，白线盖住光标所在的那一点
  private func updateCrosshair() {
    guard let mouse, isCommandDown, showsMagnifier else {
      crossLight.path = nil
      crossDark.path = nil
      return
    }
    let x = mouse.x.rounded(.down)
    let y = mouse.y.rounded(.down)
    for (layer, dx, dy) in [(crossLight, 0.5, 0.5), (crossDark, 1.5, -0.5)]
      as [(CAShapeLayer, CGFloat, CGFloat)]
    {
      let path = CGMutablePath()
      path.move(to: CGPoint(x: x + dx, y: bounds.minY))
      path.addLine(to: CGPoint(x: x + dx, y: bounds.maxY))
      path.move(to: CGPoint(x: bounds.minX, y: y + dy))
      path.addLine(to: CGPoint(x: bounds.maxX, y: y + dy))
      layer.path = path
    }
  }

  /// 点中哪条边 / 哪个角：边外 8 pt、边内也是 8 pt；选区很小时边内按比例缩（不然整块都是边，没法拖着平移）
  private static func handle(at point: CGPoint, in selection: CGRect) -> RegionSelector.Handle? {
    RegionSelector.handle(
      at: point, in: selection, tolerance: 8,
      inner: min(8, max(3, min(selection.width, selection.height) / 4)))
  }

  /// 悬停窗口的洞 / 高亮：圆角 10（窗口本身就是圆角的）
  private static func rounded(_ rect: CGRect) -> CGPath {
    let radius = min(Style.Radius.card, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
  }

  private func updateMagnifier() {
    guard let mouse, showsMagnifier else {
      magnifier.isHidden = true
      magnifierSide = nil
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
      let color = Self.color(hex: sample.hex)
      infoSwatch.backgroundColor = color.cgColor
      // 中心格描边按亮度选黑或白
      let luminance =
        0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
      loupeCenter.strokeColor = (luminance > 0.6 ? NSColor.black : NSColor.white).cgColor
      let info = NSMutableAttributedString(
        string: sample.hex,
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
          .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ])
      info.append(
        NSAttributedString(
          string: "\n\(x), \(y)",
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
          ]))
      infoText.string = info
    }
    // 放在光标右下，靠边时翻到另一侧；平时死贴光标，只有翻边那一下滑过去（glide）
    let size = magnifier.bounds.size
    let left = mouse.x + 20 + size.width > bounds.maxX
    let above = mouse.y - 20 - size.height < bounds.minY
    let origin = CGPoint(
      x: left ? mouse.x - 20 - size.width : mouse.x + 20,
      y: above ? mouse.y + 20 : mouse.y - 20 - size.height)
    let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    let appearing = magnifier.isHidden
    let flipped = magnifierSide.map { $0.left != left || $0.above != above } ?? false
    let previous = magnifier.presentation()?.position ?? magnifier.position
    magnifier.position = center
    magnifier.isHidden = false
    magnifierSide = (left, above)
    // 减弱动态效果时退成的基本动画只许改透明度
    let reduced = Style.reduceMotion
    if appearing,
      let pop = Style.Motion.pop.caAnimation(
        keyPath: reduced ? "opacity" : "transform.scale", reduced: reduced) as? CABasicAnimation
    {
      pop.fromValue = reduced ? 0 : 0.7
      pop.toValue = 1
      magnifier.add(pop, forKey: "pop")
    } else if flipped,
      let slide = Style.Motion.glide.caAnimation(keyPath: "position") as? CABasicAnimation
    {
      // 叠加动画：位移差从 previous − center 回到 0，期间光标继续动也不拖尾
      slide.isAdditive = true
      slide.fromValue = NSValue(point: CGPoint(x: previous.x - center.x, y: previous.y - center.y))
      slide.toValue = NSValue(point: .zero)
      magnifier.add(slide, forKey: "flip")
    }
  }

  /// "#RRGGBB" → sRGB 颜色
  private static func color(hex: String) -> NSColor {
    let value = Int(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(
      srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  /// 截图：待选、拖动框选、拖手柄时显示放大镜；平移、标注、鼠标在工具栏上时不显示
  private var showsMagnifier: Bool {
    guard mode == .capture, let mouse, !isOverBars(mouse) else { return false }
    switch drag {
    case .move?, .annotate?, .moveAnnotation?: return false
    case .pending?, .draw?, .resize?: return true
    case nil: return !isAdjusting
    }
  }

  /// 手柄：四角 9 pt 白圆点，四边中点 16 × 5 白胶囊（左右边竖着）
  private static func handlesPath(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    for handle in RegionSelector.Handle.allCases {
      let point = handle.point(in: rect)
      switch handle {
      case .bottomLeft, .bottomRight, .topRight, .topLeft:
        path.addEllipse(in: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
      case .top, .bottom:
        path.addRoundedRect(
          in: CGRect(x: point.x - 8, y: point.y - 2.5, width: 16, height: 5), cornerWidth: 2.5,
          cornerHeight: 2.5)
      case .left, .right:
        path.addRoundedRect(
          in: CGRect(x: point.x - 2.5, y: point.y - 8, width: 5, height: 16), cornerWidth: 2.5,
          cornerHeight: 2.5)
      }
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

  private func makeBars() {
    let toolbar = EditorToolbar()
    toolbar.onClick = { [unowned self] item in
      switch item {
      case .tool(let tool): choose(tool)
      case .undo: undo()
      case .output(let action): output(action)
      case .scroll: startScroll()
      case .cancel: session.finish(nil)
      }
    }
    let styleBar = StyleBar()
    styleBar.onColor = { [unowned self] color in restyle { $0.color = color } }
    styleBar.onWeight = { [unowned self] weight in restyle { $0.weight = weight } }
    for bar in [toolbar, styleBar] as [NSView] {
      bar.isHidden = true
      addSubview(bar)
    }
    self.toolbar = toolbar
    self.styleBar = styleBar
  }

  /// 主栏在选区右下角下方 10 pt（下面放不下放上面，都放不下放进选区里）；样式托盘贴在主栏外侧 6 pt，
  /// 选了工具、选中标注或正在输入文字时才出现。出现 / 收起都带动画（HUDBar.setShown）
  private func placeBars(showing: Bool) {
    guard let toolbar, let styleBar else { return }
    let showsToolbar = showing && selection != nil
    let showsStyle = showsToolbar && (tool != nil || selected != nil || editor != nil)
    toolbar.setShown(showsToolbar)
    styleBar.setShown(showsStyle)
    guard showsToolbar, let selection else { return }
    toolbar.update(tool: tool, canUndo: !undoStack.isEmpty)
    let gap: CGFloat = 10
    let size = toolbar.frame.size
    var y = selection.minY - gap - size.height
    if y < bounds.minY + gap { y = selection.maxY + gap }
    if y + size.height > bounds.maxY - gap { y = selection.minY + gap }
    let x = min(max(selection.maxX - size.width, bounds.minX + gap), bounds.maxX - size.width - gap)
    toolbar.frame.origin = CGPoint(x: x, y: y)
    guard showsStyle else { return }
    let hasColor = editor != nil || ((selected?.tool ?? tool)?.hasColor ?? true)
    styleBar.update(shownStyle, showsColors: hasColor)
    // 主栏在选区下方就往下叠，在上方就往上叠；叠不下换另一边
    let height = styleBar.frame.height
    let below = toolbar.frame.minY - 6 - height
    let above = toolbar.frame.maxY + 6
    let outward = toolbar.frame.midY < selection.midY ? below : above
    let fits = outward >= bounds.minY && outward + height <= bounds.maxY
    styleBar.frame.origin = CGPoint(
      x: min(x, bounds.maxX - styleBar.frame.width - gap),
      y: fits ? outward : (outward == below ? above : below))
  }

  private func isOverBars(_ point: CGPoint) -> Bool {
    [toolbar, styleBar].contains { $0.map { !$0.isHidden && $0.frame.contains(point) } ?? false }
  }

  private func isOverBars(_ rect: CGRect) -> Bool {
    [toolbar, styleBar].contains { $0.map { !$0.isHidden && $0.frame.intersects(rect) } ?? false }
  }

  // MARK: 标注

  private var selected: Annotation? {
    selectedAnnotation.flatMap { id in annotations.first { $0.id == id } }
  }

  /// 样式栏显示的样式：输入中的文字 > 选中的标注 > 新标注用的
  private var shownStyle: Annotation.Style { editor?.style ?? selected?.style ?? style }

  /// 标注层显示的：已有的（正在编辑的那条文字由输入框显示）+ 正在拖出来的
  private func syncAnnotations() {
    let editing = editor?.id
    var shown = annotations.filter { $0.id != editing }
    if let draft { shown.append(draft) }
    annotationCanvas?.annotations = shown
    refresh()
  }

  /// 最上面那条被点中的标注（按画的层次，见 Annotation.topmost）
  private func annotation(at point: CGPoint) -> Annotation? {
    Annotation.topmost(in: annotations, at: point)
  }

  /// 再按一次同一个工具就收起（回到拖动平移选区）
  private func choose(_ next: Annotation.Tool) {
    endEditing()
    tool = tool == next ? nil : next
    selectedAnnotation = nil
    refreshCursor()
  }

  /// 改了标注就记一步撤销（没变不记）
  private func commit(_ next: [Annotation]) {
    guard next != annotations else { return }
    undoStack.append(annotations)
    redoStack = []
    annotations = next
  }

  private func undo() {
    endEditing()
    guard let previous = undoStack.popLast() else { return NSSound.beep() }
    redoStack.append(annotations)
    annotations = previous
    if selected == nil { selectedAnnotation = nil }
  }

  private func redo() {
    guard let next = redoStack.popLast() else { return NSSound.beep() }
    undoStack.append(annotations)
    annotations = next
    if selected == nil { selectedAnnotation = nil }
  }

  /// 改颜色 / 粗细：新标注以后都用它；同时作用于正在输入的文字或选中的标注（修旧版改样式不作用于选中项，#47）
  private func restyle(_ change: (inout Annotation.Style) -> Void) {
    change(&style)
    if var editor {
      change(&editor.style)
      self.editor = editor
      apply(editor.style, to: editor.field)
      layoutEditor()
    } else if let id = selectedAnnotation,
      let index = annotations.firstIndex(where: { $0.id == id })
    {
      var next = annotations
      change(&next[index].style)
      commit(next)
    }
    refresh()
  }

  private func deleteSelected() {
    guard let id = selectedAnnotation else { return }
    selectedAnnotation = nil
    commit(annotations.filter { $0.id != id })
  }

  // MARK: 文字

  /// 在 origin（文字左上角）开始输入；existing 是双击的已有文字标注
  func beginEditing(at origin: CGPoint, existing: Annotation? = nil) {
    endEditing()
    let field = EditorField(frame: .zero)
    field.isRichText = false
    field.drawsBackground = false
    field.allowsUndo = true
    field.textContainerInset = .zero
    field.textContainer?.lineFragmentPadding = 0
    field.isHorizontallyResizable = true
    field.isVerticallyResizable = true
    field.textContainer?.widthTracksTextView = false
    field.textContainer?.heightTracksTextView = false
    field.textContainer?.containerSize = CGSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    field.wantsLayer = true
    field.layer?.borderWidth = 1
    field.layer?.borderColor = NSColor.controlAccentColor.cgColor
    field.delegate = self
    let style = existing?.style ?? style
    apply(style, to: field)
    if case .text(let string, _)? = existing?.shape { field.string = string }
    editor = Editor(field: field, id: existing?.id, origin: origin, style: style)
    addSubview(field, positioned: .below, relativeTo: toolbar)
    layoutEditor()
    window?.makeFirstResponder(field)
    if existing != nil { field.selectAll(nil) }
    selectedAnnotation = existing?.id
    syncAnnotations()
  }

  /// 收下输入的文字（空的就不要 / 删掉原来那条），记一步撤销
  private func endEditing() {
    guard let editor else { return }
    self.editor = nil
    let text = editor.field.string
    // 先把键盘还给自己再拿掉输入框：拿掉之后第一响应者会落到窗口上，单键快捷键就都失灵了
    if window?.firstResponder === editor.field { window?.makeFirstResponder(self) }
    editor.field.removeFromSuperview()
    var next = annotations
    let index = editor.id.flatMap { id in next.firstIndex { $0.id == id } }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if let index { next.remove(at: index) }
    } else if let index {
      next[index].shape = .text(text, origin: editor.origin)
      next[index].style = editor.style
    } else {
      next.append(Annotation(shape: .text(text, origin: editor.origin), style: editor.style))
    }
    commit(next)
    if selected == nil { selectedAnnotation = nil }  // 文字清空后那条已经删了
    syncAnnotations()  // 没改动时 commit 不触发，也要把编辑时藏起来的那条显示回来
  }

  /// 输入框里的文字和收下后画出来的一样：同字体、同颜色、同阴影
  private func apply(_ style: Annotation.Style, to field: NSTextView) {
    field.font = Annotation.font(style.weight)
    field.textColor = style.color.color
    field.insertionPointColor = style.color.color
    field.typingAttributes[.shadow] = Annotation.textShadow
    field.textStorage?.addAttribute(
      .shadow, value: Annotation.textShadow,
      range: NSRange(location: 0, length: field.textStorage?.length ?? 0))
  }

  /// 输入框和最后画出来的文字一样大、左上角不动（往下长）
  private func layoutEditor() {
    guard let editor else { return }
    let frame = Annotation.textFrame(
      editor.field.string, origin: editor.origin, weight: editor.style.weight)
    editor.field.frame = CGRect(
      x: frame.minX, y: frame.minY, width: frame.width + 2, height: frame.height)
  }

  func textDidChange(_ notification: Notification) { layoutEditor() }

  /// 输入法组字（marked text）不走 textDidChange，但每次都会动选区：跟着改大小
  func textViewDidChangeSelection(_ notification: Notification) { layoutEditor() }

  func undoManager(for view: NSTextView) -> UndoManager? { editor?.undo }

  /// Esc 收下文字（输入法组字时 Esc 先给输入法，不会走到这里）；↩ 换行
  func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    endEditing()
    return true
  }

  // MARK: 输出

  private func output(_ action: RegionSelector.Action) {
    endEditing()
    guard let selection, let window else { return }
    let pixels = RegionSelector.pixelRect(
      selection, viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height))
    let result =
      mode == .capture
      ? Annotation.render(annotations, over: image, pixelRect: pixels, viewSize: bounds.size)
      : image.cropping(to: pixels)
    guard let result else { return session.finish(nil) }
    session.finish(
      .capture(
        .init(
          image: result, frame: selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY),
          action: action)))
  }

  /// 长截图：只交出选区位置，边滚边截的是实时画面（标注不带过去）；太矮的选区两帧之间没几行可比
  private func startScroll() {
    endEditing()
    guard let selection, let window else { return }
    guard selection.height >= ScrollCapture.minimumHeight else { return NSSound.beep() }
    session.finish(.scroll(selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY)))
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
      isCommandDown = event.modifierFlags.contains(.command)
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
    // 两条栏的按钮间隙、边距、分隔线不接事件，会顺着响应链落到这里：当作点在栏上，什么也不做
    if isOverBars(point) { return }
    // 在输入文字时点了输入框外面：先把文字收下，这一下不做别的
    if editor != nil { return endEditing() }
    if isAdjusting, let selection {
      let hit = annotation(at: point)
      if event.clickCount == 2, let hit, case .text(_, let origin) = hit.shape {
        return beginEditing(at: origin, existing: hit)
      }
      if event.clickCount == 2, tool == nil, hit == nil, selection.contains(point) {
        return output(.copy)
      }
      if let handle = Self.handle(at: point, in: selection) {
        drag = .resize(handle, original: selection)
        return
      }
      if let hit {
        selectedAnnotation = hit.id
        NSCursor.closedHand.set()
        drag = .moveAnnotation(hit.id, start: point, before: annotations)
        return
      }
      selectedAnnotation = nil
      if let tool, selection.contains(point) {
        if tool == .text { return beginEditing(at: point) }
        drag = .annotate(start: point)
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
    if mode == .capture, !session.hasSelection(besides: self) {
      isCommandDown = event.modifierFlags.contains(.command)
      mouse = point
    }
    switch drag {
    case .pending(let start)?:
      guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
      window?.makeKey()
      session.activate(self)
      let restore = isAdjusting ? selection : nil
      isAdjusting = false
      drag = .draw(anchor: start, last: start, restore: restore)
      extend(to: point)
    case .draw?:
      extend(to: point)
    case .move(let start, let original)?:
      NSCursor.closedHand.set()
      selection = RegionSelector.moved(
        original, by: CGSize(width: point.x - start.x, height: point.y - start.y), within: bounds)
    case .resize(let handle, let original)?:
      selection = RegionSelector.resized(original, handle, to: point, within: bounds)
    case .annotate(let start)?:
      guard let tool,
        let shape = Annotation.shape(
          for: tool, from: start, to: point, constrained: event.modifierFlags.contains(.shift))
      else { return }
      draft = Annotation(id: draft?.id ?? UUID(), shape: shape, style: style)
    case .moveAnnotation(let id, let start, let before)?:
      guard let original = before.first(where: { $0.id == id }),
        let index = annotations.firstIndex(where: { $0.id == id })
      else { return }
      NSCursor.closedHand.set()
      annotations[index] = original.offset(
        by: CGSize(width: point.x - start.x, height: point.y - start.y))
    case nil:
      break
    }
  }

  /// 拖动框选：从锚点拉到当前点；截图时按住空格整块平移，锚点跟着走
  private func extend(to point: CGPoint) {
    guard case .draw(var anchor, let last, let restore)? = drag else { return }
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
    drag = .draw(anchor: anchor, last: point, restore: restore)
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
    case .draw(_, _, let restore)?:
      guard let selection, min(selection.width, selection.height) >= RegionSelector.minimumSide
      else {
        // 太小算误触：调整时恢复原来的选区（想拖边差了几点不该把选区弄丢），否则回到待选
        if let restore { select(restore) } else { self.selection = nil }
        return
      }
      if mode == .quick { output(.copy) } else { isAdjusting = true }
    case .annotate?:
      let drawn = draft
      draft = nil
      if let drawn, drawn.isMeaningful { commit(annotations + [drawn]) }
    case .moveAnnotation(_, _, let before)?:
      if annotations != before {
        undoStack.append(before)
        redoStack = []
        refresh()
      }
    case .move?, .resize?, nil:
      break
    }
    if mode == .capture { refreshCursor() }
  }

  override func rightMouseDown(with event: NSEvent) {
    // 截图：有选区时（不管在哪块屏）右键回到待选、重新框，没有才取消；截图翻译 / 识字直接取消
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
    if isOverBars(point) { return NSCursor.arrow.set() }
    if let editor {  // 输入框里是文字光标；外面点一下只是收下文字
      return (editor.field.frame.contains(point) ? NSCursor.iBeam : NSCursor.arrow).set()
    }
    if let handle = Self.handle(at: point, in: selection) {
      return NSCursor.frameResize(position: Self.position(of: handle), directions: .all).set()
    }
    if annotation(at: point) != nil { return NSCursor.openHand.set() }
    if let tool, selection.contains(point) {
      return (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
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

  // MARK: 键盘（输入文字时按键都归输入框，不到这里）

  /// 数字键 1–9、0 依次对应 10 个工具（Tool.rawValue 1–10）
  private static let toolKeys: [Int: Annotation.Tool] = Dictionary(
    uniqueKeysWithValues: zip(
      [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
        kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
      ], Annotation.Tool.allCases))

  override func keyDown(with event: NSEvent) {
    let code = Int(event.keyCode)
    // Esc：先取消选中的标注，再收起工具，最后才取消截图（免得一下把画好的标注全丢了）
    if code == kVK_Escape {
      if selectedAnnotation != nil {
        selectedAnnotation = nil
      } else if tool != nil {
        tool = nil
        refreshCursor()
      } else {
        session.finish(nil)
      }
      return
    }
    // 单字母键不带 ⌘ ⌃ ⌥（⌘C 之类走 performKeyEquivalent）。ponytail: 按物理键位，Dvorak 等布局下位置不同
    guard mode == .capture, event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    else { return super.keyDown(with: event) }
    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
    switch code {
    case kVK_Return, kVK_ANSI_KeypadEnter:
      if isAdjusting { output(.copy) }
    case kVK_ANSI_T:
      if isAdjusting { output(.pin) }
    case kVK_ANSI_S:
      if isAdjusting { startScroll() }
    case kVK_ANSI_D:
      session.selectLastRegion()
    case kVK_ANSI_C:
      if showsMagnifier, let sampled { session.finish(.color(sampled.hex)) }
    case _ where Self.toolKeys[code] != nil:
      if isAdjusting, let tool = Self.toolKeys[code] { choose(tool) }
    case kVK_Delete, kVK_ForwardDelete:
      deleteSelected()
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

  /// ⌘ 按下 / 松开：十字准线跟着出现 / 消失
  override func flagsChanged(with event: NSEvent) {
    isCommandDown = event.modifierFlags.contains(.command)
    super.flagsChanged(with: event)
  }

  override func keyUp(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Space { isSpaceDown = false } else { super.keyUp(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard mode == .capture, window?.isKeyWindow == true else {
      return super.performKeyEquivalent(with: event)
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    // 输入文字时：⌘C / ⌘V / ⌘Z 等发给输入框（本 App 不激活，主菜单收不到）
    if editor != nil {
      let action =
        flags == [.command, .shift] && key == "z"
        ? Selector(("redo:")) : flags == .command ? OverlayPanel.editActions[key] : nil
      guard let action else { return super.performKeyEquivalent(with: event) }
      return NSApp.sendAction(action, to: nil, from: self)
    }
    guard isAdjusting else { return super.performKeyEquivalent(with: event) }
    switch (Int(event.keyCode), flags == .command, flags == [.command, .shift]) {
    case (kVK_ANSI_C, true, _): output(.copy)
    case (kVK_ANSI_S, true, _): output(.save)
    case (kVK_ANSI_S, _, true): output(.saveAs)
    case (kVK_ANSI_Z, true, _): undo()
    case (kVK_ANSI_Z, _, true): redo()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  /// 方向键：选中了标注就挪标注（每下记一步撤销），否则微调选区
  private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
    guard isAdjusting, let selection else { return }
    if let id = selectedAnnotation, let index = annotations.firstIndex(where: { $0.id == id }) {
      var next = annotations
      next[index] = next[index].offset(by: CGSize(width: dx, height: dy))
      return commit(next)
    }
    self.selection = RegionSelector.moved(
      selection, by: CGSize(width: dx, height: dy), within: bounds)
    refreshCursor()
  }
}

/// 文字标注的输入框。右键不出文本菜单（菜单层级比遮罩低，会被压在下面看不见），交给遮罩（回到待选）
private final class EditorField: NSTextView {
  override func menu(for event: NSEvent) -> NSMenu? { nil }
  override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
}

/// 标注层：只重画变了的标注所在的那块（整屏重画在 5K 屏上太慢；聚光灯压暗的档变了才整块重画）。不接事件
private final class AnnotationCanvas: NSView {
  let image: CGImage
  var annotations: [Annotation] = [] { didSet { invalidate(from: oldValue) } }
  /// 选区：聚光灯只压暗选区里面。有聚光灯时选区一变，只重画新旧选区不重合的那几条（拖边、平移时每次几点宽）
  var selection: CGRect? {
    didSet {
      guard selection != oldValue, Annotation.dimLevel(of: annotations) != nil else { return }
      guard let old = oldValue, let selection else {
        needsDisplay = true
        return
      }
      for strip in Annotation.dimChange(from: old, to: selection) {
        setNeedsDisplay(strip.insetBy(dx: -2, dy: -2))
      }
    }
  }

  init(image: CGImage) {
    self.image = image
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    Annotation.drawAll(
      annotations, in: context, image: image, viewSize: bounds.size, shadowScale: 1,
      dirty: dirtyRect, spotlightBounds: selection ?? .zero)
  }

  private func invalidate(from old: [Annotation]) {
    guard Annotation.dimLevel(of: annotations) == Annotation.dimLevel(of: old) else {
      needsDisplay = true
      return
    }
    let before = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
    let now = Set(annotations.map(\.id))
    for annotation in annotations where before[annotation.id] != annotation {
      setNeedsDisplay(annotation.drawBounds.insetBy(dx: -2, dy: -2))
      if let previous = before[annotation.id] {
        setNeedsDisplay(previous.drawBounds.insetBy(dx: -2, dy: -2))
      }
    }
    for annotation in old where !now.contains(annotation.id) {
      setNeedsDisplay(annotation.drawBounds.insetBy(dx: -2, dy: -2))
    }
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

/// HUD 胶囊 / 圆角块里一行白字（rgba(28,28,30) 底 + 0.5 pt white 0.14 描边）：顶部提示、尺寸标签共用
private struct Pill {
  let layer = CALayer()
  private let textLayer = CATextLayer()
  private let font: NSFont
  private let padding: CGSize
  /// nil = 胶囊（半高圆角）
  private let radius: CGFloat?

  /// digits：数字等宽（尺寸跟着鼠标变时不抖）
  init(
    fontSize: CGFloat, padding: CGSize = CGSize(width: 8, height: 5), digits: Bool = true,
    weight: NSFont.Weight = .medium, radius: CGFloat? = nil
  ) {
    font =
      digits
      ? .monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
      : .systemFont(ofSize: fontSize, weight: weight)
    self.padding = padding
    self.radius = radius
    layer.backgroundColor = NSColor(white: 0.11, alpha: 0.78).cgColor
    layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    layer.borderWidth = 0.5
    layer.cornerCurve = .continuous
    layer.anchorPoint = .zero
    textLayer.foregroundColor = NSColor.white.cgColor
    layer.addSublayer(textLayer)
  }

  var text: String {
    get { (textLayer.string as? NSAttributedString)?.string ?? "" }
    nonmutating set {
      set(
        NSAttributedString(
          string: newValue, attributes: [.font: font, .foregroundColor: NSColor.white]))
    }
  }

  /// 尺寸标签：「600 × 300」，乘号 white 0.5
  func setSize(width: Int, height: Int) {
    let string = NSMutableAttributedString(
      string: "\(width)", attributes: [.font: font, .foregroundColor: NSColor.white])
    string.append(
      NSAttributedString(
        string: " × ",
        attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.5)]))
    string.append(
      NSAttributedString(
        string: "\(height)", attributes: [.font: font, .foregroundColor: NSColor.white]))
    set(string)
  }

  private func set(_ string: NSAttributedString) {
    let textSize = string.size()
    textLayer.string = string
    textLayer.frame = CGRect(
      x: padding.width, y: padding.height, width: ceil(textSize.width),
      height: ceil(textSize.height))
    layer.bounds.size = CGSize(
      width: ceil(textSize.width) + padding.width * 2,
      height: ceil(textSize.height) + padding.height * 2)
    layer.cornerRadius = radius ?? layer.bounds.height / 2
  }

  var size: CGSize { layer.bounds.size }

  var scale: CGFloat {
    get { textLayer.contentsScale }
    nonmutating set { textLayer.contentsScale = newValue }
  }

  /// 左下角放在 origin
  func place(at origin: CGPoint) { layer.position = origin }
}
