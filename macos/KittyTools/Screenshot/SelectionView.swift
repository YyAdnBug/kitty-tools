// 框选遮罩里一块屏幕的画面与交互（会话见 RegionSelector）。从下到上：冻结帧（本视图图层的内容）→ 标注层
// （AnnotationCanvas，只重画变了的那块）→ 暗色蒙层、选区边框、手柄、尺寸、放大镜（CALayer，拖动时只改路径和位置，
// 不重画整屏）→ 文字输入框 → 工具栏与样式栏（EditorToolbar）。
// 截图翻译 / 识字：拖动框选、松手即确认。截图：悬停高亮窗口、单击截整窗，拖出或单击后进入调整：8 个手柄、拖动平移、
// 方向键微调（⇧ 10 点）、拖动框选时按住空格平移；放大镜显示中心像素的色值（C 复制）；标注 1–4（矩形、箭头、文字、
// 马赛克，⇧ 画正方形 / 45° 箭头），点中标注可拖动、改颜色粗细、⌫ 删除、双击文字重新编辑，⌘Z 撤销、⇧⌘Z 重做。

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
  var selection: CGRect? { didSet { refresh() } }
  /// 截图：选区已确定，可以调整、标注、选输出方式
  var isAdjusting = false { didSet { refresh() } }
  /// 截图：鼠标位置（悬停窗口、放大镜）；nil = 鼠标不在这块屏上
  var mouse: CGPoint? { didSet { refresh() } }
  private var drag: Drag? { didSet { refresh() } }
  /// 截图：按住空格时拖动框选变成整块平移（系统截屏的习惯）
  private var isSpaceDown = false

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
    case draw(anchor: CGPoint, last: CGPoint)
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
  private let sizeLabel = Pill(fontSize: 12)
  private let hint = Pill(fontSize: 13, padding: CGSize(width: 14, height: 6), digits: false)
  private let magnifier = CALayer()
  private let loupe = CALayer()
  private let loupeCenter = CAShapeLayer()
  private let colorLabel = Pill(fontSize: 11)
  private var toolbar: EditorToolbar?
  private var styleBar: StyleBar?
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
    annotationOutline.fillColor = nil
    annotationOutline.strokeColor = NSColor.controlAccentColor.cgColor
    annotationOutline.lineWidth = 1
    annotationOutline.lineDashPattern = [4, 3]
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
    for layer in [
      shade, highlight, outline, handles, annotationOutline, sizeLabel.layer, hint.layer, magnifier,
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
    for layer in [shade, outline, highlight, handles, annotationOutline, loupeCenter] {
      layer.contentsScale = scale
    }
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
      sizeLabel.text = "\(Int(pixels.width)) × \(Int(pixels.height))"
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

  /// 截图：待选、拖动框选、拖手柄时显示放大镜；平移、标注、鼠标在工具栏上时不显示
  private var showsMagnifier: Bool {
    guard mode == .capture, let mouse, !isOverBars(mouse) else { return false }
    switch drag {
    case .move?, .annotate?, .moveAnnotation?: return false
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

  private func makeBars() {
    let toolbar = EditorToolbar()
    toolbar.onClick = { [unowned self] item in
      switch item {
      case .tool(let tool): choose(tool)
      case .undo: undo()
      case .output(let action): output(action)
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

  /// 主栏在选区右下角的下方（下面放不下放上面，都放不下放进选区里）；样式栏贴在主栏外侧，
  /// 选了工具、选中标注或正在输入文字时才出现
  private func placeBars(showing: Bool) {
    guard let toolbar, let styleBar else { return }
    toolbar.isHidden = !(showing && selection != nil)
    styleBar.isHidden = toolbar.isHidden || (tool == nil && selected == nil && editor == nil)
    guard !toolbar.isHidden, let selection else { return }
    toolbar.update(tool: tool, canUndo: !undoStack.isEmpty)
    let gap: CGFloat = 8
    let size = toolbar.frame.size
    var y = selection.minY - gap - size.height
    if y < bounds.minY + gap { y = selection.maxY + gap }
    if y + size.height > bounds.maxY - gap { y = selection.minY + gap }
    let x = min(max(selection.maxX - size.width, bounds.minX + gap), bounds.maxX - size.width - gap)
    toolbar.frame.origin = CGPoint(x: x, y: y)
    guard !styleBar.isHidden else { return }
    let isMosaic = editor == nil && (selected?.isMosaic ?? (tool == .mosaic))
    styleBar.update(shownStyle, showsColors: !isMosaic)
    // 主栏在选区下方就往下叠，在上方就往上叠；叠不下换另一边
    let height = styleBar.frame.height
    let below = toolbar.frame.minY - 4 - height
    let above = toolbar.frame.maxY + 4
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

  /// 最上面那条被点中的标注
  private func annotation(at point: CGPoint) -> Annotation? {
    annotations.last { $0.contains(point) }
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

  private func apply(_ style: Annotation.Style, to field: NSTextView) {
    field.font = Annotation.font(style.weight)
    field.textColor = style.color.color
    field.insertionPointColor = style.color.color
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
      if let handle = RegionSelector.handle(at: point, in: selection) {
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
    if let handle = RegionSelector.handle(at: point, in: selection) {
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

  private static let toolKeys: [Int: Annotation.Tool] = [
    kVK_ANSI_1: .rectangle, kVK_ANSI_2: .arrow, kVK_ANSI_3: .text, kVK_ANSI_4: .mosaic,
  ]

  override func keyDown(with event: NSEvent) {
    let code = Int(event.keyCode)
    // Esc：先取消选中的标注，再取消截图
    if code == kVK_Escape {
      if selectedAnnotation != nil { selectedAnnotation = nil } else { session.finish(nil) }
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

/// 标注层：只重画变了的标注所在的那块（整屏重画在 5K 屏上太慢）。不接事件
private final class AnnotationCanvas: NSView {
  let image: CGImage
  var annotations: [Annotation] = [] { didSet { invalidate(from: oldValue) } }

  init(image: CGImage) {
    self.image = image
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    for annotation in annotations where annotation.bounds.intersects(dirtyRect) {
      annotation.draw(in: context, image: image, viewSize: bounds.size)
    }
  }

  private func invalidate(from old: [Annotation]) {
    let before = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
    let now = Set(annotations.map(\.id))
    for annotation in annotations where before[annotation.id] != annotation {
      setNeedsDisplay(annotation.bounds.insetBy(dx: -2, dy: -2))
      if let previous = before[annotation.id] {
        setNeedsDisplay(previous.bounds.insetBy(dx: -2, dy: -2))
      }
    }
    for annotation in old where !now.contains(annotation.id) {
      setNeedsDisplay(annotation.bounds.insetBy(dx: -2, dy: -2))
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
