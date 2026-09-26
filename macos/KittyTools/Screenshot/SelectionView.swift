// 框选遮罩里一块屏幕的画面与交互（会话见 RegionSelector）。从下到上：冻结帧（本视图图层的内容）→ 标注层
// （AnnotationCanvas，只重画变了的那块）→ 暗色蒙层、选区边框、吸附参考线、手柄、放大镜（CALayer，拖动时只改路径和位置，
// 不重画整屏）→ 尺寸胶囊（SizeField）→ 文字输入框 → 工具栏、样式托盘、HUD 菜单（EditorToolbar.swift）。外观是 Whisker §6
// 截图的品牌粉。框选、拖边：⇧ 锁比例（新框正方形，或按锁着的比例）、⌥ 从中心、空格平移、⌃ 暂停吸附（6 pt 内吸到冻结时的
// 窗口边和屏幕边，吸上时画粉色虚线参考线），拖动中按下 / 松开修饰键立刻重算。
// 截图翻译 / 识字：拖动框选、松手即确认（同样的放大镜、修饰键和吸附）。截图：悬停窗口（洞和粉框磁吸变形、显示窗口尺寸）、
// 单击选中窗口，拖出或单击后进入调整：整条边和四角都能拖（悬停的边加粗、手柄放大）、拖动平移、方向键微调（⇧ 10 点）、
// ⌘ / ⌥ + 方向键推 / 收那条边；尺寸胶囊点数字输入像素宽高、比例菜单锁比例；右键没有标注时回到待选，有标注时只提示；
// 放大镜显示中心像素的色值（C 复制），按住 ⌘ 出整屏十字准线；S 长截图、T 钉图、O 识字；
// 标注 1–0（矩形、椭圆、箭头、直线、画笔、荧光笔、文字、序号、马赛克、聚光灯，⇧ 画正方形 / 45° 线，再按一次收起），
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
      // 选区一动（方向键、拖边）开着的 HUD 菜单就收起：它锚着的栏 / 胶囊跟着挪了
      if selection != oldValue { hudMenu?.dismiss() }
      refresh()
    }
  }
  /// 截图：选区已确定，可以调整、标注、选输出方式
  var isAdjusting = false { didSet { refresh() } }
  /// 鼠标位置（悬停窗口、放大镜）；nil = 鼠标不在这块屏上
  var mouse: CGPoint? { didSet { refresh() } }
  private var drag: Drag? { didSet { refresh() } }
  /// 按住空格时拖动框选变成整块平移（系统截屏的习惯）
  private var isSpaceDown = false
  /// 当前的修饰键（取自事件：flagsChanged、鼠标事件都带着，鼠标从别的屏移过来时也是准的）：⌘ 十字准线，
  /// ⇧ 锁比例、⌥ 从中心、⌃ 暂停吸附
  private var modifiers: NSEvent.ModifierFlags = [] {
    didSet { if modifiers.contains(.command) != oldValue.contains(.command) { refresh() } }
  }
  /// 拖动中上一次的鼠标位置：按下 / 松开修饰键时按它重算
  private var dragPoint: CGPoint?
  /// 吸上的边（x 竖线、y 横线），拖动时整屏画粉色虚线参考线；交互测试读它
  private(set) var guides: (x: CGFloat?, y: CGFloat?) = (nil, nil)

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
  /// 8 个手柄各一层（依次弹出、悬停的那个放大）；按住的边 / 角加粗的粉线
  private let handleLayers = Dictionary(
    uniqueKeysWithValues: RegionSelector.Handle.allCases.map { ($0, CAShapeLayer()) })
  private let edgeHighlight = CAShapeLayer()
  private let annotationOutline = CAShapeLayer()
  /// 选区双描边的外圈（内圈 1.5 pt 粉是 outline）
  private let outlineOuter = CAShapeLayer()
  /// 按住 ⌘ 时穿过光标的十字准线：1 pt white 0.6 贴 1 pt black 0.25，亮底暗底都看得见
  private let crossLight = CAShapeLayer()
  private let crossDark = CAShapeLayer()
  /// 吸附参考线：1 pt 粉色虚线 [4, 3] 横穿整屏
  private let guideLayer = CAShapeLayer()
  /// 选区（或悬停窗口）的像素尺寸；调整时可输入、可锁比例
  private let sizeField = SizeField()
  private let hint = Pill(font: .systemFont(ofSize: 13), padding: CGSize(width: 14, height: 7))
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
  /// 开着的 HUD 菜单（同时最多一个）：Esc、点外面先收它
  private var hudMenu: HUDMenu?
  /// 放大镜上次取样的像素和色值（像素没变就不重取）
  private var sampled: (x: Int, y: Int, hex: String)?
  /// 上次画的悬停窗口：换到别的窗口 / 桌面时，洞和高亮框磁吸变形过去（S5）
  private var shownHover: CGRect?
  /// 没悬停窗口时洞缩成光标处的零尺寸占位（路径元素数恒定，桌面 ↔ 窗口也能变形）
  private var placeholder = CGPoint.zero
  /// 上次的洞是不是选区（单击窗口选中时洞圆角 10 → 0 用 pop）
  private var holeIsSelection = false
  /// 上次有没有洞：有无变化时蒙层深浅过渡
  private var hadHole = false
  /// 悬停（或正在拖）的选区边 / 角：那条边加粗、对应手柄放大 1.3。截图自检、交互测试读它
  private(set) var hotHandle: RegionSelector.Handle?
  /// 手柄上次是否显示（进入调整时依次弹出）
  private var handlesShown = false
  /// 放大镜上次在光标哪一侧（翻边时滑过去）
  private var magnifierSide: (left: Bool, above: Bool)?
  /// 顶部提示临时换了一句（右键不清空）：有选区时也显示
  private var hintFlashing = false
  /// 每次显示提示加一：旧的淡出计时作废
  private var hintGeneration = 0

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
    let pink = Style.Shot.accent
    outline.fillColor = nil
    outline.strokeColor = pink.cgColor
    outline.lineWidth = 1.5
    outlineOuter.fillColor = nil
    outlineOuter.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
    outlineOuter.lineWidth = 1
    edgeHighlight.fillColor = nil
    edgeHighlight.strokeColor = pink.cgColor
    edgeHighlight.lineWidth = 2.5
    edgeHighlight.lineCap = .round
    highlight.fillColor = pink.withAlphaComponent(0.12).cgColor
    highlight.strokeColor = pink.cgColor
    highlight.lineWidth = 2
    for (handle, layer) in handleLayers {
      layer.path = Self.handleShape(handle)
      layer.fillColor = NSColor.white.cgColor
      layer.strokeColor = pink.cgColor
      layer.lineWidth = 1.5
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = 0.3
      layer.shadowRadius = 1.5
      layer.shadowOffset = CGSize(width: 0, height: -0.5)
      layer.shadowPath = layer.path
      layer.isHidden = true
    }
    annotationOutline.fillColor = nil
    annotationOutline.strokeColor = pink.cgColor
    annotationOutline.lineWidth = 1
    annotationOutline.lineDashPattern = [4, 3]
    guideLayer.fillColor = nil
    guideLayer.strokeColor = pink.cgColor
    guideLayer.lineWidth = 1
    guideLayer.lineDashPattern = [4, 3]
    for (layer, color) in [
      (crossLight, NSColor.white.withAlphaComponent(0.6)),
      (crossDark, .black.withAlphaComponent(0.25)),
    ] {
      layer.fillColor = nil
      layer.strokeColor = color.cgColor
      layer.lineWidth = 1
    }
    setUpMagnifier()
    infoKey.isHidden = mode == .quick  // 截图翻译 / 识字不能按 C 复制色值
    for layer in [
      shade, highlight, outlineOuter, outline, guideLayer, edgeHighlight, crossDark, crossLight,
    ]
      + Self.handleOrder.compactMap({ handleLayers[$0] })
      + [annotationOutline, hint.layer, magnifier]
    {
      root.addSublayer(layer)
    }
    sizeField.isHidden = true
    sizeField.onEdit = { [unowned self] which in beginSizeEditing(which) }
    sizeField.onCommit = { [unowned self] in finishSizeEditing(commit: true) }
    sizeField.onCancel = { [unowned self] in escape() }
    sizeField.onRatio = { [unowned self] in toggleRatioMenu() }
    addSubview(sizeField)
    if mode == .quick {
      hint.setParts(session.hint.components(separatedBy: " · "))
    } else {
      hint.setParts(
        ["拖动框选", "单击选中窗口", "双击直接拷贝"] + (session.lastRegion == nil ? [] : ["D 上次区域"])
          + ["Esc 取消"])
    }
    if mode == .capture { makeBars() }
    updateScale()
  }

  /// 放大镜：15 × 15 像素、每格 9 pt（135 pt，圆角 10，2 pt 白环 + 阴影），0.5 pt 像素网格，中心行列粉色十字条带，
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
    loupeBands.fillColor = Style.Shot.accent.withAlphaComponent(0.18).cgColor
    loupeCenter.frame = loupe.bounds
    loupeCenter.path = CGPath(
      rect: CGRect(x: middle, y: middle, width: cell, height: cell), transform: nil)
    loupeCenter.fillColor = nil
    loupeCenter.strokeColor = NSColor.white.cgColor
    loupeCenter.lineWidth = 1
    for layer in [loupeBands, loupeGrid, loupeCenter] { loupe.addSublayer(layer) }
    infoCard.frame = CGRect(x: 0, y: 0, width: side, height: Self.infoHeight)
    Style.HUD.applySkin(to: infoCard, radius: Style.Radius.card)
    Style.HUD.applyShadow(
      to: infoCard,
      path: CGPath(
        roundedRect: infoCard.bounds, cornerWidth: Style.Radius.card,
        cornerHeight: Style.Radius.card, transform: nil))
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
    hudMenu?.dismiss()
    finishSizeEditing(commit: false)
    endEditing()
    guides = (nil, nil)
    dragPoint = nil
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
      shade, outline, outlineOuter, edgeHighlight, crossLight, crossDark, highlight, guideLayer,
      annotationOutline, loupeGrid, loupeBands, loupeCenter, infoText, infoKey,
    ] + Array(handleLayers.values) as [CALayer] {
      layer.contentsScale = scale
    }
    hint.scale = scale
  }

  /// 出场：蒙层 0.15 s 淡入；提示浮上来，3 s 后淡出
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    updateScale()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.15
    shade.add(fade, forKey: "enter")
    showHint(for: 3)
  }

  /// 提示从下方 8 pt 浮上来，seconds 秒后淡出（再显示一次时旧的计时作废）
  private func showHint(for seconds: Double) {
    hintGeneration += 1
    let generation = hintGeneration
    hint.layer.removeAnimation(forKey: "leave")
    hint.layer.opacity = 1
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    let rise = CABasicAnimation(keyPath: "transform.translation.y")
    rise.fromValue = Style.reduceMotion ? 0 : -8
    rise.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [fade, rise]
    group.duration = 0.3
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    hint.layer.add(group, forKey: "enter")
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, self.hintGeneration == generation else { return }
      self.dismissHint()
    }
  }

  /// 淡出后停在透明（不设 isHidden：下一次 refresh 会把淡出截断）
  private func dismissHint() {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = hint.layer.presentation()?.opacity ?? 1
    fade.toValue = 0
    fade.duration = 0.3
    hint.layer.opacity = 0
    hint.layer.add(fade, forKey: "leave")
  }

  /// 顶部提示临时换一句（右键不清空）：有选区时也显示，1.5 s 后淡出
  private func flashHint(_ parts: [String]) {
    // 换字时胶囊的宽、圆角、阴影不做隐式动画（它挂在 layer-hosting 的图层树上，默认会补 0.25 s）
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hint.setParts(parts)
    CATransaction.commit()
    hintFlashing = true
    refresh()
    showHint(for: 1.5)
  }

  /// 按状态摆好全部图层（关掉隐式动画，拖动时跟手；只有换悬停窗口、单击选中窗口、蒙层深浅切换、手柄出现 / 悬停放大、
  /// 放大镜出现 / 翻边、两条栏长出 / 淡出时才加动画）
  private func refresh() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let hovered = selection == nil ? mouse.flatMap(windowRect(at:)) : nil
    if let mouse { placeholder = mouse }
    updateHole(hovered: hovered)
    // 选区双描边：内 1.5 pt 粉 + 外 1 pt black 0.28（亮底暗底都看得清）
    outline.path = selection.map { CGPath(rect: $0.insetBy(dx: -0.75, dy: -0.75), transform: nil) }
    outlineOuter.path = selection.map { CGPath(rect: $0.insetBy(dx: -2, dy: -2), transform: nil) }
    hint.layer.isHidden = selection != nil && !hintFlashing
    if !hint.layer.isHidden {
      hint.place(
        at: CGPoint(x: bounds.midX - hint.size.width / 2, y: bounds.maxY - 64 - hint.size.height))
    }
    updateGuides()

    let adjusting = mode == .capture && isAdjusting
    updateHandles(adjusting ? selection : nil)
    // 输入文字时输入框自己有边框，不再画选中框（大小会跟着输入变）
    annotationOutline.path =
      editor == nil
      ? selected.map { CGPath(rect: $0.bounds.insetBy(dx: -4, dy: -4), transform: nil) } : nil
    placeBars(showing: adjusting && !movesSelection)
    // 尺寸：选区（或悬停的窗口）左上角外 8 pt；放不下、或挡到工具栏 / 顶部提示时放进里面。调整时可输入
    let measured = selection ?? hovered
    sizeField.isHidden = measured == nil
    if let measured {
      let pixels = RegionSelector.pixelRect(
        measured, viewSize: bounds.size,
        imageSize: CGSize(width: image.width, height: image.height))
      sizeField.show(
        width: Int(pixels.width), height: Int(pixels.height), interactive: adjusting,
        ratio: RegionSelector.ratioTitle(session.lockedRatio), locked: session.lockedRatio != nil)
      let size = sizeField.frame.size
      let x = max(bounds.minX, min(measured.minX, bounds.maxX - size.width))
      var y = measured.maxY + 8
      let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
      if frame.maxY > bounds.maxY || isOverBars(frame)
        || (!hint.layer.isHidden && hint.layer.opacity > 0 && hint.frame.intersects(frame))
      {
        y = measured.maxY - 8 - size.height
      }
      // 取整到整点：选区给的是小数点，文字落在半像素上会糊
      let origin = CGPoint(x: x.rounded(), y: y.rounded())
      if sizeField.frame.origin != origin { sizeField.setFrameOrigin(origin) }
    }
    updateMagnifier()
    updateCrosshair()
  }

  /// S5 窗口磁吸：洞（蒙层里的圆角矩形）和粉色高亮框。路径元素数恒定（外框 + 一个圆角矩形，没悬停窗口时是光标处的
  /// 零尺寸占位），窗口之间、桌面 ↔ 窗口用 glide 从当前（可能还在动的）形状变形过去；单击窗口选中时洞圆角 10 → 0 用 pop；
  /// 拖动、微调一律跟手
  private func updateHole(hovered: CGRect?) {
    let spot = CGRect(origin: placeholder, size: .zero)
    let hole = selection ?? hovered ?? spot
    let path = CGMutablePath()
    path.addRect(bounds)
    path.addPath(Self.roundedPath(hole, radius: selection == nil ? Style.Radius.card : 0))
    let frame: CGPath? =
      selection == nil
      ? Self.roundedPath(hovered?.insetBy(dx: 1, dy: 1) ?? spot, radius: Style.Radius.card - 1)
      : nil
    var oldShade = shade.presentation()?.path ?? shade.path
    var oldHighlight = highlight.presentation()?.path ?? highlight.path
    var morph: CABasicAnimation?
    if selection == nil {
      // 同一状态下占位跟着光标走，只改模型值：正在跑的变形会追着新终点
      if hovered != shownHover, shade.path != nil, !holeIsSelection {
        morph = Style.Motion.glide.caAnimation(keyPath: "path") as? CABasicAnimation
      }
    } else if !holeIsSelection, shownHover != nil, selection == shownHover, !Style.reduceMotion {
      morph = Style.Motion.pop.caAnimation(keyPath: "path", reduced: false) as? CABasicAnimation
    } else if shade.path != path {
      shade.removeAnimation(forKey: "morph")
    }
    // 没变就不设：整屏的蒙层重新光栅化一次不便宜（调整时鼠标每动一下都会走到这里）
    if shade.path != path { shade.path = path }
    if highlight.path != frame { highlight.path = frame }
    if let morph {
      // 从桌面占位出发（没在变形）时从光标现在的位置长出来：图层里的占位可能还停在进场前的 (0, 0)
      // 或上次移出本屏的地方，直接用会从屏幕角落飞过来
      if shownHover == nil, shade.animation(forKey: "morph") == nil {
        let start = CGMutablePath()
        start.addRect(bounds)
        start.addPath(Self.roundedPath(spot, radius: Style.Radius.card))
        oldShade = start
        oldHighlight = Self.roundedPath(spot, radius: Style.Radius.card - 1)
      }
      morph.fromValue = oldShade
      shade.add(morph, forKey: "morph")
      if frame != nil, let copy = morph.copy() as? CABasicAnimation {
        copy.fromValue = oldHighlight
        highlight.add(copy, forKey: "morph")
      }
    }
    if frame == nil { highlight.removeAnimation(forKey: "morph") }
    shownHover = hovered
    holeIsSelection = selection != nil
    // 待选时整屏轻暗 0.18；有选区（或悬停的窗口）时洞外 0.45，切换时过渡 0.12 s
    let hasHole = selection != nil || hovered != nil
    let fill = NSColor.black.withAlphaComponent(hasHole ? 0.45 : 0.18).cgColor
    if hasHole != hadHole {
      let fade = CABasicAnimation(keyPath: "fillColor")
      fade.fromValue = shade.presentation()?.fillColor ?? shade.fillColor
      fade.toValue = fill
      fade.duration = 0.12
      shade.add(fade, forKey: "fill")
    }
    shade.fillColor = fill
    hadHole = hasHole
  }

  /// 手柄：角 10 pt 白圆 + 1.5 pt 粉环，边中点 16 × 5 白胶囊 + 粉环（短边 < 40 不画边中点）；进入调整时从左上角顺时针
  /// 依次弹出（错开 15 ms）；悬停 / 正在拖的边加 2.5 pt 粉线、对应手柄放大 1.3（pop）
  private func updateHandles(_ rect: CGRect?) {
    let appearing = rect != nil && !handlesShown
    handlesShown = rect != nil
    let reduced = Style.reduceMotion
    for (index, handle) in Self.handleOrder.enumerated() {
      guard let layer = handleLayers[handle] else { continue }
      guard let rect else {
        layer.isHidden = true
        continue
      }
      let isEdge = [.top, .bottom, .left, .right].contains(handle)
      layer.isHidden = isEdge && min(rect.width, rect.height) < 40
      layer.position = handle.point(in: rect)
      guard appearing else { continue }
      if reduced {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        layer.add(fade, forKey: "appear")
      } else if let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
        as? CABasicAnimation
      {
        pop.fromValue = 0
        pop.beginTime = CACurrentMediaTime() + Double(index) * 0.015
        pop.fillMode = .backwards
        layer.add(pop, forKey: "appear")
      }
    }
    let hot = rect.flatMap(hotHandle(in:))
    if hot != hotHandle {
      for (handle, scale) in [(hotHandle, 1), (hot, 1.3)] as [(RegionSelector.Handle?, CGFloat)] {
        guard let handle, let layer = handleLayers[handle] else { continue }
        let from = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        guard !reduced,
          let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
            as? CABasicAnimation
        else { continue }
        pop.fromValue = from
        layer.add(pop, forKey: "hot")
      }
      hotHandle = hot
    }
    if let hot, let rect {
      edgeHighlight.path = Self.edgePath(hot, of: rect)
    } else {
      edgeHighlight.path = nil
    }
  }

  /// 悬停（或正在拖）的边 / 角：拖手柄时就是那个手柄；其余拖动、输入文字 / 尺寸、开着菜单、鼠标在栏上时没有
  private func hotHandle(in rect: CGRect) -> RegionSelector.Handle? {
    if case .resize(let handle, _)? = drag { return handle }
    guard drag == nil, editor == nil, !sizeField.isEditing, hudMenu == nil, let mouse,
      !isOverControls(mouse)
    else { return nil }
    return Self.handle(at: mouse, in: rect)
  }

  /// 吸附参考线：吸上的边各一条 1 pt 粉色虚线横穿整屏
  private func updateGuides() {
    let path = CGMutablePath()
    if let x = guides.x {
      path.move(to: CGPoint(x: x, y: bounds.minY))
      path.addLine(to: CGPoint(x: x, y: bounds.maxY))
    }
    if let y = guides.y {
      path.move(to: CGPoint(x: bounds.minX, y: y))
      path.addLine(to: CGPoint(x: bounds.maxX, y: y))
    }
    guideLayer.path = path.isEmpty ? nil : path
  }

  /// 正在拖动 / 缩放 / 平移选区：两条栏只在这时让位淡出（画标注、拖标注时不动）。按在选区里 / 边上还没拖开不算，
  /// 不然单击一下（取消选中标注）栏就闪一下
  private var movesSelection: Bool {
    switch drag {
    case .move(_, let original)?, .resize(_, let original)?: selection != original
    case .draw?: true
    default: false
    }
  }

  /// 十字准线跟放大镜同时出现（待选、拖动框选、拖手柄），只在按住 ⌘ 时；对齐到整点，白线盖住光标所在的那一点
  private func updateCrosshair() {
    guard let mouse, modifiers.contains(.command), showsMagnifier else {
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

  /// 圆角矩形，元素恒为 move + 4 ×（line + curve）+ close：半径 0、零尺寸时也一样，洞和高亮框才能在窗口、
  /// 桌面占位、选区之间做路径插值（S5）。半径夹在短边一半以内
  static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = max(0, min(radius, rect.width / 2, rect.height / 2))
    let k = r * 0.4477  // 四分之一圆的三次贝塞尔：控制点离角 r × (1 − 0.5523)
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addLine(to: CGPoint(x: maxX - r, y: minY))
    path.addCurve(
      to: CGPoint(x: maxX, y: minY + r), control1: CGPoint(x: maxX - k, y: minY),
      control2: CGPoint(x: maxX, y: minY + k))
    path.addLine(to: CGPoint(x: maxX, y: maxY - r))
    path.addCurve(
      to: CGPoint(x: maxX - r, y: maxY), control1: CGPoint(x: maxX, y: maxY - k),
      control2: CGPoint(x: maxX - k, y: maxY))
    path.addLine(to: CGPoint(x: minX + r, y: maxY))
    path.addCurve(
      to: CGPoint(x: minX, y: maxY - r), control1: CGPoint(x: minX + k, y: maxY),
      control2: CGPoint(x: minX, y: maxY - k))
    path.addLine(to: CGPoint(x: minX, y: minY + r))
    path.addCurve(
      to: CGPoint(x: minX + r, y: minY), control1: CGPoint(x: minX, y: minY + k),
      control2: CGPoint(x: minX + k, y: minY))
    path.closeSubpath()
    return path
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

  /// 待选、拖动框选、拖手柄时显示放大镜（截图翻译 / 识字也是）；平移、标注、鼠标在工具栏上时不显示。交互测试读它
  var showsMagnifier: Bool {
    guard let mouse, !isOverBars(mouse) else { return false }
    switch drag {
    case .move?, .annotate?, .moveAnnotation?: return false
    case .pending?, .draw?, .resize?: return true
    case nil: return !isAdjusting
    }
  }

  /// 以原点为中心的手柄形状：角 10 pt 圆，边中点 16 × 5 胶囊（左右边竖着）
  private static func handleShape(_ handle: RegionSelector.Handle) -> CGPath {
    switch handle {
    case .bottomLeft, .bottomRight, .topRight, .topLeft:
      CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
    case .top, .bottom:
      CGPath(
        roundedRect: CGRect(x: -8, y: -2.5, width: 16, height: 5), cornerWidth: 2.5,
        cornerHeight: 2.5, transform: nil)
    case .left, .right:
      CGPath(
        roundedRect: CGRect(x: -2.5, y: -8, width: 5, height: 16), cornerWidth: 2.5,
        cornerHeight: 2.5, transform: nil)
    }
  }

  /// 手柄依次弹出的顺序：从左上角顺时针
  private static let handleOrder: [RegionSelector.Handle] = [
    .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left,
  ]

  /// 悬停的边（角 = 两条边），画在内描边的中线上
  private static func edgePath(_ handle: RegionSelector.Handle, of rect: CGRect) -> CGPath {
    let edge = rect.insetBy(dx: -0.75, dy: -0.75)
    let path = CGMutablePath()
    if handle.movesMinX || handle.movesMaxX {
      let x = handle.movesMinX ? edge.minX : edge.maxX
      path.move(to: CGPoint(x: x, y: edge.minY))
      path.addLine(to: CGPoint(x: x, y: edge.maxY))
    }
    if handle.movesMinY || handle.movesMaxY {
      let y = handle.movesMinY ? edge.minY : edge.maxY
      path.move(to: CGPoint(x: edge.minX, y: y))
      path.addLine(to: CGPoint(x: edge.maxX, y: y))
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
      finishSizeEditing(commit: true)  // 输入着尺寸点了栏：先按输入的改选区再出图
      if item != .saveMenu { hudMenu?.dismiss() }
      switch item {
      case .tool(let tool): choose(tool)
      case .undo: undo()
      case .redo: redo()
      case .output(let action): output(action)
      case .scroll: startScroll()
      case .saveMenu: toggleSaveMenu()
      case .cancel: session.finish(nil)
      }
    }
    let styleBar = StyleBar()
    styleBar.onColor = { [unowned self] color in restyle { $0.color = color } }
    styleBar.onWeight = { [unowned self] weight in restyle { $0.weight = weight } }
    styleBar.onOption = { [unowned self] option in restyle { $0.option = option } }
    for bar in [toolbar, styleBar] as [NSView] {
      bar.isHidden = true
      addSubview(bar)
    }
    self.toolbar = toolbar
    self.styleBar = styleBar
  }

  /// 工具栏在选区下方 10 pt、水平居中；样式托盘锚在当前工具（或选中标注的工具、输入中的文字）按钮外侧 6 pt，
  /// 水平以按钮为中心（夹在屏内 10 pt），换工具时 settle 滑过去。出现 / 收起都带动画（PopView.setShown）
  private func placeBars(showing: Bool) {
    guard let toolbar, let styleBar else { return }
    guard showing, let selection else {
      toolbar.setShown(false)
      styleBar.setShown(false)
      hudMenu?.dismiss()
      return
    }
    toolbar.update(tool: tool, canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty)
    let (origin, edge) = Self.toolbarPlacement(
      size: toolbar.frame.size, selection: selection, in: bounds)
    let moved = toolbar.frame.origin != origin
    if moved { toolbar.setFrameOrigin(origin) }
    toolbar.setShown(true, growingFrom: edge)
    let owner: Annotation.Tool? = editor != nil ? .text : selected?.tool ?? tool
    guard let owner else { return styleBar.setShown(false) }
    styleBar.update(tool: owner, style: shownStyle)
    let button = toolbar.toolButtonFrame(owner).offsetBy(dx: origin.x, dy: origin.y)
    let size = styleBar.preferredSize
    let x = max(bounds.minX + 10, min(button.midX - size.width / 2, bounds.maxX - size.width - 10))
      .rounded()
    // 栏在选区下方就往下叠，在上方 / 选区里就往上叠；叠不下换另一边
    let below = origin.y - 6 - size.height
    let above = origin.y + toolbar.frame.height + 6
    var y = edge == .top ? below : above
    if y < bounds.minY || y + size.height > bounds.maxY { y = edge == .top ? above : below }
    styleBar.move(
      to: CGRect(x: x, y: y, width: size.width, height: size.height),
      animated: styleBar.isShown && !moved)
    styleBar.setShown(true, anchorX: button.midX - x, growingFrom: y < origin.y ? .top : .bottom)
  }

  /// 工具栏放哪、从哪条边长出来：选区下方 10 pt（从顶边长出），放不下放上方，都放不下放进选区底部（这两种从底边长出）；
  /// 水平以选区为中心、夹在屏内 10 pt。选区是鼠标给的小数点，取整到整点，栏里的图标和描边才不发糊
  static func toolbarPlacement(size: CGSize, selection: CGRect, in bounds: CGRect)
    -> (origin: CGPoint, edge: PopView.Edge)
  {
    let margin: CGFloat = 10
    let x = max(
      bounds.minX + margin, min(selection.midX - size.width / 2, bounds.maxX - size.width - margin)
    ).rounded()
    let below = (selection.minY - margin - size.height).rounded()
    if below >= bounds.minY + margin { return (CGPoint(x: x, y: below), .top) }
    let above = (selection.maxY + margin).rounded()
    if above + size.height <= bounds.maxY - margin { return (CGPoint(x: x, y: above), .bottom) }
    return (CGPoint(x: x, y: (selection.minY + margin).rounded()), .bottom)
  }

  /// 保存 ▾：HUD 菜单锚在保存按钮下方；开着时再点一下收起
  private func toggleSaveMenu() {
    if let hudMenu { return hudMenu.dismiss() }
    guard let toolbar, let body = toolbar.button(for: .output(.save)),
      let caret = toolbar.button(for: .saveMenu)
    else { return }
    let directory = FileManager.default.displayName(atPath: ScreenshotOutput.saveDirectory.path)
    present(
      HUDMenu([
        .init(title: "存储到「\(directory)」", key: "⌘S") { [weak self] in self?.output(.save) },
        .init(title: "另存为…", key: "⇧⌘S") { [weak self] in self?.output(.saveAs) },
      ]),
      anchor: body.convert(body.bounds, to: self).union(caret.convert(caret.bounds, to: self)))
  }

  /// 尺寸胶囊的比例按钮：HUD 菜单（自由 / 1:1 / 4:3 / 3:2 / 16:9 / 9:16，勾着锁住的那个）；开着时再点一下收起
  private func toggleRatioMenu() {
    if let hudMenu { return hudMenu.dismiss() }
    endEditing()
    let locked = session.lockedRatio
    present(
      HUDMenu(
        RegionSelector.ratios.map { preset in
          HUDMenu.Entry(title: preset.title, checked: preset.value == locked) { [weak self] in
            self?.lockRatio(preset.value)
          }
        }),
      anchor: sizeField.convert(sizeField.ratioFrame, to: self))
  }

  /// 选了比例：立刻套到选区上（顶边和水平中心不动）并锁住，之后框选、拖边都按它；nil（自由）解锁
  private func lockRatio(_ ratio: CGFloat?) {
    session.lockedRatio = ratio
    if let ratio, let selection {
      self.selection = RegionSelector.applying(ratio, to: selection, within: bounds)
    }
    refresh()
    refreshCursor()
  }

  /// 点了尺寸胶囊的数字：收掉菜单和输入中的文字，两个数变成输入框
  private func beginSizeEditing(_ which: SizeField.Dimension) {
    hudMenu?.dismiss()
    endEditing()
    sizeField.beginEditing(which)
    refresh()
  }

  /// 收下尺寸输入：先把键盘要回来再把输入框变回数字（反过来第一响应者落到窗口上，单键快捷键全失灵）；
  /// commit 时按输入的像素改选区（左上角不动）
  private func finishSizeEditing(commit: Bool) {
    guard sizeField.isEditing else { return }
    window?.makeFirstResponder(self)
    let pixels = sizeField.typedPixels
    sizeField.endEditing()
    if commit, let pixels, let selection {
      self.selection = RegionSelector.sized(
        selection, pixels: pixels,
        scale: CGSize(
          width: CGFloat(image.width) / bounds.width, height: CGFloat(image.height) / bounds.height),
        within: bounds)
    }
    refresh()
  }

  /// Esc 依次：HUD 菜单 → 尺寸输入 → 输入中的文字 → 选中的标注 → 工具 → 取消截图（免得一下把画好的标注全丢了）
  private func escape() {
    if let hudMenu {
      hudMenu.dismiss()
    } else if sizeField.isEditing {
      finishSizeEditing(commit: false)
    } else if editor != nil {
      endEditing()
    } else if selectedAnnotation != nil {
      selectedAnnotation = nil
    } else if tool != nil {
      tool = nil
      refreshCursor()
    } else {
      session.finish(nil)
    }
  }

  /// 同时最多开一个 HUD 菜单
  private func present(_ next: HUDMenu, anchor: CGRect) {
    hudMenu?.dismiss()
    hudMenu = next
    next.onDismiss = { [weak self, weak next] in
      guard let self, self.hudMenu === next else { return }
      self.hudMenu = nil
      self.refreshCursor()
    }
    next.present(in: self, anchor: anchor)
    refresh()
  }

  /// 两条栏和开着的菜单（按钮间隙、边距会顺着响应链落到遮罩上）
  private var bars: [NSView] { [toolbar as NSView?, styleBar, hudMenu].compactMap { $0 } }

  private func isOverBars(_ point: CGPoint) -> Bool {
    bars.contains { !$0.isHidden && $0.frame.contains(point) }
  }

  /// 栏、菜单或能点的尺寸胶囊上：光标是箭头、边不热
  private func isOverControls(_ point: CGPoint) -> Bool {
    isOverBars(point)
      || (sizeField.isInteractive && !sizeField.isHidden && sizeField.frame.contains(point))
  }

  private func isOverBars(_ rect: CGRect) -> Bool {
    bars.contains { !$0.isHidden && $0.frame.intersects(rect) }
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

  /// 再按一次同一个工具就收起（回到拖动平移选区）；选上时读这个工具上次的样式
  private func choose(_ next: Annotation.Tool) {
    endEditing()
    let chosen = tool == next ? nil : next
    // 先换样式再换工具：托盘换工具那一下拿到的就是这个工具的样式（反过来色点先显示旧样式、再弹一下）
    if let chosen { style = Annotation.Style.remembered(for: chosen) }
    tool = chosen
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
    endEditing()
    guard let next = redoStack.popLast() else { return NSSound.beep() }
    undoStack.append(annotations)
    annotations = next
    if selected == nil { selectedAnnotation = nil }
  }

  /// 改颜色 / 粗细 / 选项：作用于正在输入的文字、选中的标注（修旧版改样式不作用于选中项，#47）或当前工具的新标注，
  /// 并记成那个工具的样式（Prefs.screenshotToolStyles）
  private func restyle(_ change: (inout Annotation.Style) -> Void) {
    finishSizeEditing(commit: true)  // 输入着尺寸点了托盘：点别处提交
    if var editor {
      change(&editor.style)
      self.editor = editor
      apply(editor.style, to: editor.field)
      layoutEditor()
      remember(editor.style, for: .text)
    } else if let id = selectedAnnotation,
      let index = annotations.firstIndex(where: { $0.id == id })
    {
      var next = annotations
      change(&next[index].style)
      commit(next)
      remember(next[index].style, for: next[index].tool)
    } else if let tool {
      var changed = style
      change(&changed)
      remember(changed, for: tool)
    }
    refresh()
  }

  /// 记住这个工具的样式；是当前工具的话新标注也用它
  private func remember(_ changed: Annotation.Style, for owner: Annotation.Tool) {
    Annotation.Style.remember(changed, for: owner)
    if owner == tool { style = changed }
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
    field.layer?.borderColor = Style.Shot.accent.cgColor
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

  /// Esc 收下文字（开着 HUD 菜单时先收菜单；输入法组字时 Esc 先给输入法，不会走到这里）；↩ 换行
  func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    escape()
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
    // 别的屏上有选区时这块屏不悬停、不出放大镜（单击不会抢走那边的选区，拖动才开新选区）；
    // 否则鼠标到哪块屏，哪块屏收按键（C 复制的是眼前放大镜的色值、Esc 取消）。不激活本 App
    if session.hasSelection(besides: self) {
      mouse = nil
    } else {
      if window?.isKeyWindow == false { window?.makeKey() }
      modifiers = event.modifierFlags
      mouse = point(event)
    }
    if mode == .capture { refreshCursor() } else { NSCursor.crosshair.set() }
  }

  override func mouseExited(with event: NSEvent) {
    mouse = nil
  }

  override func mouseDown(with event: NSEvent) {
    let point = point(event)
    modifiers = event.modifierFlags
    guard mode == .capture else {
      window?.makeKey()  // 按键跟着最后操作的那块屏幕走
      session.activate(self)
      mouse = point
      selection = nil
      drag = .draw(anchor: point, last: point)
      return
    }
    // 开着 HUD 菜单时点外面：只收菜单；输入着尺寸时点别处：按输入的改选区，这一下不做别的
    if let hudMenu { return hudMenu.dismiss() }
    if sizeField.isEditing { return finishSizeEditing(commit: true) }
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
    modifiers = event.modifierFlags
    dragPoint = point
    if !session.hasSelection(besides: self) { mouse = point }
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
      resize(handle, from: original, to: point)
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

  /// 拖动框选：从锚点拉到当前点（锁着比例时按它，否则 ⇧ 正方形；⌥ 从中心、吸附）；按住空格整块平移，锚点跟着走
  private func extend(to point: CGPoint) {
    guard case .draw(var anchor, let last, let restore)? = drag else { return }
    NSCursor.crosshair.set()
    if isSpaceDown, let current = selection {
      let moved = RegionSelector.moved(
        current, by: CGSize(width: point.x - last.x, height: point.y - last.y), within: bounds)
      anchor.x += moved.minX - current.minX
      anchor.y += moved.minY - current.minY
      guides = (nil, nil)
      selection = moved
    } else {
      let target = snap(point, x: true, y: true)
      let rect = RegionSelector.drawn(
        from: anchor, to: target.point,
        ratio: session.lockedRatio ?? (modifiers.contains(.shift) ? 1 : nil),
        fromCenter: modifiers.contains(.option), within: bounds)
      showGuides(target, on: rect)
      selection = rect
    }
    drag = .draw(anchor: anchor, last: point, restore: restore)
  }

  /// 拖边 / 角：锁着比例时按它，否则 ⇧ 保持原选区的比例；⌥ 从中心、吸附在动的那条边
  private func resize(_ handle: RegionSelector.Handle, from original: CGRect, to point: CGPoint) {
    let target = snap(
      point, x: handle.movesMinX || handle.movesMaxX, y: handle.movesMinY || handle.movesMaxY)
    let rect = RegionSelector.resized(
      original, handle, to: target.point, within: bounds,
      ratio: session.lockedRatio
        ?? (modifiers.contains(.shift) ? original.width / original.height : nil),
      fromCenter: modifiers.contains(.option))
    showGuides(target, on: rect)
    selection = rect
  }

  /// 吸附（⌃ 暂停）：在动的轴上 6 pt 内吸到冻结时本屏窗口的边和屏幕边
  private func snap(_ point: CGPoint, x: Bool, y: Bool) -> (
    point: CGPoint, x: CGFloat?, y: CGFloat?
  ) {
    guard !modifiers.contains(.control) else { return (point, nil, nil) }
    let (snappedX, edgeX) =
      x
      ? RegionSelector.snapped(
        point.x, to: windows.flatMap { [$0.minX, $0.maxX] } + [bounds.minX, bounds.maxX])
      : (point.x, nil)
    let (snappedY, edgeY) =
      y
      ? RegionSelector.snapped(
        point.y, to: windows.flatMap { [$0.minY, $0.maxY] } + [bounds.minY, bounds.maxY])
      : (point.y, nil)
    return (CGPoint(x: snappedX, y: snappedY), edgeX, edgeY)
  }

  /// 参考线只画真落在选区边上的（锁比例时由另一边定大小的那条边不算）；先设它再设选区，refresh 一次画对
  private func showGuides(_ target: (point: CGPoint, x: CGFloat?, y: CGFloat?), on rect: CGRect) {
    func lands(_ edge: CGFloat?, _ low: CGFloat, _ high: CGFloat) -> CGFloat? {
      guard let edge, abs(edge - low) < 0.01 || abs(edge - high) < 0.01 else { return nil }
      return edge
    }
    guides = (lands(target.x, rect.minX, rect.maxX), lands(target.y, rect.minY, rect.maxY))
  }

  override func mouseUp(with event: NSEvent) {
    let finished = drag
    guides = (nil, nil)
    dragPoint = nil
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
    guard mode == .capture, selection != nil || session.hasSelection(besides: self) else {
      return session.finish(nil)
    }
    // 画了标注（含正在输入、还没收下的文字）就不清空（一下丢掉太亏）：提示音 + 顶部提示怎么退出
    let typing = editor.map { !$0.field.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if !annotations.isEmpty || typing == true || session.hasAnnotations(besides: self) {
      NSSound.beep()
      return flashHint(["有标注时右键不清空", "Esc 退出"])
    }
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
    if isOverControls(point) { return NSCursor.arrow.set() }
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

  /// 方向键对应的选区边（AppKit 坐标 y 朝上：↑ 是上边 maxY）
  private static let arrowEdges: [Int: RegionSelector.Handle] = [
    kVK_LeftArrow: .left, kVK_RightArrow: .right, kVK_UpArrow: .top, kVK_DownArrow: .bottom,
  ]

  override func keyDown(with event: NSEvent) {
    let code = Int(event.keyCode)
    if code == kVK_Escape { return escape() }
    // 空格：拖动框选时整块平移（截图翻译 / 识字也是）
    if code == kVK_Space {
      isSpaceDown = true
      return
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option])
    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
    // ⌥ + 方向键：那条边往里收（⌘ + 方向键走 performKeyEquivalent）
    if mode == .capture, flags == .option, let edge = Self.arrowEdges[code] {
      return push(edge, by: -step)
    }
    // 单字母键不带 ⌘ ⌃ ⌥（⌘C 之类走 performKeyEquivalent）。ponytail: 按物理键位，Dvorak 等布局下位置不同
    guard mode == .capture, flags.isEmpty else { return super.keyDown(with: event) }
    switch code {
    case kVK_Return, kVK_ANSI_KeypadEnter:
      if isAdjusting { output(.copy) }
    case kVK_ANSI_T:
      if isAdjusting { output(.pin) }
    case kVK_ANSI_S:
      if isAdjusting { startScroll() }
    case kVK_ANSI_O:
      if isAdjusting { output(.recognize) }
    case kVK_ANSI_D:
      session.selectLastRegion()
    case kVK_ANSI_C:
      if showsMagnifier, let sampled { session.finish(.color(sampled.hex)) }
    case _ where Self.toolKeys[code] != nil:
      if isAdjusting, let tool = Self.toolKeys[code] { choose(tool) }
    case kVK_Delete, kVK_ForwardDelete:
      deleteSelected()
    case kVK_LeftArrow: nudge(-step, 0)
    case kVK_RightArrow: nudge(step, 0)
    case kVK_UpArrow: nudge(0, step)
    case kVK_DownArrow: nudge(0, -step)
    default:
      super.keyDown(with: event)
    }
  }

  /// 修饰键按下 / 松开：⌘ 十字准线跟着出现 / 消失；框选、拖边途中按上次的鼠标位置重算（⇧ ⌥ ⌃ 立刻生效）
  override func flagsChanged(with event: NSEvent) {
    modifiers = event.modifierFlags
    if let dragPoint {
      switch drag {
      case .draw(_, let last, _)?: extend(to: last)
      case .resize(let handle, let original)?: resize(handle, from: original, to: dragPoint)
      default: break
      }
    }
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
    // 输入文字 / 尺寸时：⌘C / ⌘V / ⌘Z 等发给输入框（本 App 不激活，主菜单收不到）
    if editor != nil || sizeField.isEditing {
      let action =
        flags == [.command, .shift] && key == "z"
        ? Selector(("redo:")) : flags == .command ? OverlayPanel.editActions[key] : nil
      guard let action else { return super.performKeyEquivalent(with: event) }
      return NSApp.sendAction(action, to: nil, from: self)
    }
    guard isAdjusting else { return super.performKeyEquivalent(with: event) }
    // ⌘ + 方向键：那条边往外推（⇧ 10 点）
    if flags.subtracting(.shift) == .command, let edge = Self.arrowEdges[Int(event.keyCode)] {
      push(edge, by: flags.contains(.shift) ? 10 : 1)
      return true
    }
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

  /// ⌘ / ⌥ + 方向键：选区那条边往外推（delta > 0）/ 往里收，短边不小于 8
  private func push(_ edge: RegionSelector.Handle, by delta: CGFloat) {
    guard isAdjusting, let selection else { return }
    self.selection = RegionSelector.pushed(selection, edge, by: delta, within: bounds)
    refreshCursor()
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

/// HUD 胶囊里一行白字（Style.HUD 皮肤 + 阴影）：顶部提示
private struct Pill {
  let layer = CALayer()
  private let textLayer = CATextLayer()
  private let font: NSFont
  private let padding: CGSize

  init(font: NSFont, padding: CGSize) {
    self.font = font
    self.padding = padding
    Style.HUD.applySkin(to: layer, radius: 0)
    layer.anchorPoint = .zero
    textLayer.foregroundColor = Style.HUD.text.cgColor
    layer.addSublayer(textLayer)
  }

  /// 几段之间用「 · 」隔开，点是次要文字色
  func setParts(_ parts: [String]) {
    let string = NSMutableAttributedString()
    for (index, part) in parts.enumerated() {
      if index > 0 {
        string.append(
          NSAttributedString(
            string: " · ", attributes: [.font: font, .foregroundColor: Style.HUD.tertiaryText]))
      }
      string.append(
        NSAttributedString(
          string: part, attributes: [.font: font, .foregroundColor: Style.HUD.text]))
    }
    set(string)
  }

  /// 文字没变就不动
  private func set(_ string: NSAttributedString) {
    guard (textLayer.string as? NSAttributedString) != string else { return }
    let textSize = string.size()
    textLayer.string = string
    textLayer.frame = CGRect(
      x: padding.width, y: padding.height, width: ceil(textSize.width),
      height: ceil(textSize.height))
    layer.bounds.size = CGSize(
      width: ceil(textSize.width) + padding.width * 2,
      height: ceil(textSize.height) + padding.height * 2)
    layer.cornerRadius = layer.bounds.height / 2
    Style.HUD.applyShadow(
      to: layer,
      path: CGPath(
        roundedRect: layer.bounds, cornerWidth: layer.cornerRadius,
        cornerHeight: layer.cornerRadius, transform: nil))
  }

  var size: CGSize { layer.bounds.size }
  var frame: CGRect { CGRect(origin: layer.position, size: size) }

  var scale: CGFloat {
    get { textLayer.contentsScale }
    nonmutating set { textLayer.contentsScale = newValue }
  }

  /// 左下角放在 origin（取整到整点：选区给的是小数点，文字落在半像素上会糊）
  func place(at origin: CGPoint) {
    layer.position = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
  }
}
