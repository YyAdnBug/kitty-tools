// 长图标注窗口里的画布（标注第 2 批）：下面是长图本身，上面是标注层，鼠标和键盘的标注交互都在这里。
// 手感和截图框选里的标注一条条对齐（拍板 B2）：十种工具（数字键 1–0，再按一次收起）、画完自动选中、拖手柄改大小
// （⇧ 约束）、拖本体移动（⇧ 锁轴）、⌥ 拖复制、⌘D 复制、方向键微调（⇧ 10 点）、双击文字重新编辑、双击弯曲手柄拉直、
// ⌫ 删除、⌘Z / ⇧⌘Z 撤销重做；长图这边多两条：空格 + 拖动平移画布，画到窗口边自动滚（B3）。
// 画面只画看得见的那一段（长图上限 30000 像素高，整张贴给图层会撞 GPU 纹理上限，第 1 批的注释）；
// 标注层是和遮罩共用的 AnnotationCanvas（只重画变了的那块，选中框和手柄也画在它里面）。
// 坐标系同截图标注：点、原点左下，所以 Annotation 的画法、命中、手柄、导出一字不改地用。

import AppKit
import Carbon.HIToolbox

final class ScrollCanvas: NSView, NSTextViewDelegate {
  let image: CGImage
  /// 像素 / 点
  let scale: CGFloat

  // 标注（同遮罩里的那套；单测直接设它们摆状态）
  var annotations: [Annotation] = [] { didSet { syncAnnotations() } }
  var tool: Annotation.Tool? {
    didSet {
      refreshCursor()
      onState()
    }
  }
  var selectedAnnotation: UUID? {
    didSet {
      updateChrome()
      onState()
    }
  }
  /// 新标注用的颜色和粗细
  var style = Annotation.Style()
  var styleDefaults = UserDefaults.standard
  /// 画布缩放：选中框和手柄的线宽按它补偿
  var zoom: CGFloat = 1 { didSet { updateChrome() } }
  /// 工具、选中、撤销栈、样式变了：窗口更新工具栏和样式托盘
  var onState: () -> Void = {}

  /// 样式托盘显示的样式：输入中的文字 > 选中的标注 > 新标注用的
  var shownStyle: Annotation.Style { editor?.style ?? selected?.style ?? style }
  /// 样式托盘跟着谁：同上的优先级（都没有就不出托盘）
  var styleOwner: Annotation.Tool? { editor != nil ? .text : selected?.tool ?? tool }
  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }
  var hasAnnotations: Bool { !annotations.isEmpty || editor != nil }

  private let overlay: AnnotationCanvas
  private var draft: Annotation? { didSet { syncAnnotations() } }
  private var undoStack: [[Annotation]] = []
  private var redoStack: [[Annotation]] = []
  private var editor: Editor?
  private var drag: Drag?
  private var modifiers: NSEvent.ModifierFlags = []
  private var dragPoint: CGPoint?
  /// 鼠标位置（光标按它重设）
  private var mouse: CGPoint?
  /// 按下鼠标前就按着的空格不算平移（同框选）
  private var isSpaceDown = false
  /// 按下时压在弯曲手柄上的那条：双击拉直要两下都按在它上面
  private var bendPressed: UUID?

  private struct Editor {
    let field: EditorField
    /// 每个输入框自己的撤销记录（共用窗口的会串到已经收掉的输入框上）
    let undo = UndoManager()
    let id: UUID?
    let origin: CGPoint
    var style: Annotation.Style
  }

  private enum Drag {
    /// 用当前工具拖出新标注（画笔一路累点）
    case annotate(start: CGPoint)
    /// 拖动标注：original 是按下时的样子；before 是按下前的全部标注（松手记一步撤销）；copyOf 是 ⌥ 复制的原件
    case moveAnnotation(Annotation, start: CGPoint, before: [Annotation], copyOf: UUID?)
    case resizeAnnotation(Annotation, Annotation.Handle, before: [Annotation], offset: CGVector)
    /// 空格 + 拖动：平移画布（start 是按下时的点，窗口坐标）
    case pan(start: CGPoint)
  }

  init(image: CGImage, scale: CGFloat) {
    self.image = image
    self.scale = scale
    overlay = AnnotationCanvas(image: image)
    super.init(
      frame: CGRect(
        x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    overlay.frame = bounds
    overlay.autoresizingMask = [.width, .height]
    addSubview(overlay)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: 画面

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

  /// 标注层显示的：已有的（正在编辑的那条文字由输入框显示）+ 正在拖出来的
  private func syncAnnotations() {
    let editing = editor?.id
    var shown = annotations.filter { $0.id != editing }
    if let draft { shown.append(draft) }
    overlay.annotations = shown
    updateChrome()
    onState()
  }

  private func updateChrome() {
    overlay.chrome = (editor == nil ? selected : nil).map { ($0, zoom) }
  }

  // MARK: 标注

  private var selected: Annotation? {
    selectedAnnotation.flatMap { id in annotations.first { $0.id == id } }
  }

  private func annotation(at point: CGPoint) -> Annotation? {
    Annotation.topmost(in: annotations, at: point)
  }

  /// 按在选中标注的哪个手柄上（半径 7 内最近的；缩小看时按屏幕上的距离算，不然缩到一半手柄就点不中了）
  private func annotationHandle(at point: CGPoint) -> (
    annotation: Annotation, handle: Annotation.Handle, point: CGPoint
  )? {
    guard editor == nil, let selected else { return nil }
    let reach = 7 / max(zoom, 0.01)
    let distance = { (grip: (Annotation.Handle, CGPoint)) in
      hypot(grip.1.x - point.x, grip.1.y - point.y)
    }
    return selected.handles.filter { distance($0) <= reach }.min { distance($0) < distance($1) }
      .map { (selected, $0.0, $0.1) }
  }

  private func replace(_ annotation: Annotation) {
    guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
    annotations[index] = annotation
  }

  /// 复制一份（新 id，序号换成下一个号）
  private func duplicate(_ original: Annotation, offset: CGSize) -> Annotation {
    var copy = original.duplicated(offset: offset)
    if case .counter(_, let center) = copy.shape {
      copy.shape = .counter(Annotation.nextCounter(in: annotations), center: center)
    }
    return copy
  }

  /// 正拖着标注：撤销 / 重做 / 删除 / 复制 / 方向键都不响应（松手时按按下前的样子记一步撤销，中途改列表就对不上了）
  private var isDraggingAnnotation: Bool {
    switch drag {
    case .annotate?, .moveAnnotation?, .resizeAnnotation?: true
    default: false
    }
  }

  /// 改了标注就记一步撤销（没变不记）
  private func commit(_ next: [Annotation]) {
    guard next != annotations else { return }
    undoStack.append(annotations)
    redoStack = []
    annotations = next
  }

  /// 一次拖动松手时记一步撤销；没变不记
  private func recordUndo(from before: [Annotation]) {
    guard annotations != before else { return }
    undoStack.append(before)
    redoStack = []
    onState()
  }

  func undo() {
    guard !isDraggingAnnotation else { return }
    endEditing()
    guard let previous = undoStack.popLast() else { return NSSound.beep() }
    redoStack.append(annotations)
    annotations = previous
    if selected == nil { selectedAnnotation = nil }
  }

  func redo() {
    guard !isDraggingAnnotation else { return }
    endEditing()
    guard let next = redoStack.popLast() else { return NSSound.beep() }
    undoStack.append(annotations)
    annotations = next
    if selected == nil { selectedAnnotation = nil }
  }

  /// 再按一次同一个工具就收起；选上时读这个工具上次的样式
  func choose(_ next: Annotation.Tool?) {
    endEditing()
    let chosen = tool == next ? nil : next
    if let chosen { style = Annotation.Style.remembered(for: chosen, in: styleDefaults) }
    tool = chosen
    selectedAnnotation = nil
    refreshCursor()
    Island.announce(chosen.map { "\($0.title)工具" } ?? "已收起工具")
  }

  /// 改颜色 / 粗细 / 选项：作用于正在输入的文字、选中的标注或当前工具的新标注，并记成那个工具的样式
  func restyle(_ change: (inout Annotation.Style) -> Void) {
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
    onState()
  }

  private func remember(_ changed: Annotation.Style, for owner: Annotation.Tool) {
    Annotation.Style.remember(changed, for: owner, in: styleDefaults)
    if owner == tool { style = changed }
  }

  func deleteSelected() {
    guard !isDraggingAnnotation, let id = selectedAnnotation else { return }
    selectedAnnotation = nil
    commit(annotations.filter { $0.id != id })
  }

  /// ⌘D：选中的标注复制一份，往右下偏 12（原点左下，y 是 −12），选中副本
  private func duplicateSelected() {
    guard !isDraggingAnnotation, let selected else { return }
    let copy = duplicate(selected, offset: CGSize(width: 12, height: -12))
    commit(annotations + [copy])
    selectedAnnotation = copy.id
  }

  /// 方向键微调选中的标注
  private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
    guard !isDraggingAnnotation, let selected else { return NSSound.beep() }
    let before = annotations
    replace(selected.offset(by: CGSize(width: dx, height: dy)))
    recordUndo(from: before)
  }

  /// 合成好的长图：没画标注就是原图（拍板 C2，很长的图重渲一张峰值内存翻倍）
  func composed() -> CGImage {
    endEditing()
    guard !annotations.isEmpty else { return image }
    let pixels = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    return Annotation.render(annotations, over: image, pixelRect: pixels, viewSize: bounds.size)
      ?? image
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
    field.selectedTextAttributes = [.backgroundColor: Style.Shot.accent.withAlphaComponent(0.4)]
    field.delegate = self
    let style = existing?.style ?? self.style
    apply(style, to: field)
    if case .text(let string, _)? = existing?.shape { field.string = string }
    editor = Editor(field: field, id: existing?.id, origin: origin, style: style)
    addSubview(field)
    layoutEditor()
    window?.makeFirstResponder(field)
    if existing != nil { field.selectAll(nil) }
    selectedAnnotation = existing?.id
    syncAnnotations()
  }

  /// 收下输入的文字（空的就不要 / 删掉原来那条），记一步撤销
  @discardableResult func endEditing() -> Bool {
    guard let editor else { return false }
    self.editor = nil
    let text = editor.field.string
    // 先把键盘还给自己再拿掉输入框：拿掉之后第一响应者会落到窗口上，单键快捷键就都失灵了
    if window?.firstResponder === editor.field { window?.makeFirstResponder(self) }
    editor.field.removeFromSuperview()
    var next = annotations
    var chosen = editor.id
    let index = editor.id.flatMap { id in next.firstIndex { $0.id == id } }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if let index { next.remove(at: index) }
    } else if let index {
      next[index].shape = .text(text, origin: editor.origin)
      next[index].style = editor.style
    } else {
      let added = Annotation(shape: .text(text, origin: editor.origin), style: editor.style)
      next.append(added)
      chosen = added.id
    }
    commit(next)
    selectedAnnotation = next.contains { $0.id == chosen } ? chosen : nil
    syncAnnotations()
    return true
  }

  /// 输入框里的文字和收下后画出来的一样（同遮罩里的 apply）
  private func apply(_ style: Annotation.Style, to field: EditorField) {
    let plate = style.option == 2
    let ink = plate ? style.color.ink : style.color.color
    field.font = Annotation.font(style.weight)
    field.textColor = ink
    field.insertionPointColor = Style.Shot.accent
    field.ringRadius = plate ? 6 : 3
    let shadow = style.option == 0 ? Annotation.textShadow : nil
    let all = NSRange(location: 0, length: field.textStorage?.length ?? 0)
    field.typingAttributes[.shadow] = shadow
    if let shadow {
      field.textStorage?.addAttribute(.shadow, value: shadow, range: all)
    } else {
      field.textStorage?.removeAttribute(.shadow, range: all)
    }
    field.outline = style.option == 1 ? Annotation.outlineAttributes(style) : nil
    guard let layer = field.layer else { return }
    layer.backgroundColor = plate ? style.color.color.cgColor : nil
    layer.cornerRadius = plate ? 6 : 0
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOffset = .zero
    layer.shadowRadius = 1.5
    layer.shadowOpacity = plate ? 0.28 : 0
  }

  private func layoutEditor() {
    guard let editor else { return }
    let frame = Annotation.textFrame(
      editor.field.string, origin: editor.origin, weight: editor.style.weight)
    let pad = editor.style.option == 2 ? Annotation.platePadding : CGSize(width: 3, height: 3)
    if editor.field.textContainerInset != pad { editor.field.textContainerInset = pad }
    editor.field.frame = frame.insetBy(dx: -pad.width, dy: -pad.height)
    if editor.field.outline != nil { editor.field.needsDisplay = true }
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

  // MARK: 鼠标

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    mouse = convert(event.locationInWindow, from: nil)
    modifiers = event.modifierFlags
    refreshCursor()
  }

  override func mouseExited(with event: NSEvent) {
    mouse = nil
    NSCursor.arrow.set()
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    mouse = point
    modifiers = event.modifierFlags
    window?.makeFirstResponder(self)
    let pressedBend = bendPressed
    bendPressed = nil
    // 空格 + 拖动：平移画布（同框选里按空格平移选区）
    if isSpaceDown {
      NSCursor.closedHand.set()
      drag = .pan(start: event.locationInWindow)
      return
    }
    // 在输入文字时点了输入框外面：先把文字收下，这一下不做别的
    if endEditing() { return }
    // 双击箭头 / 直线的弯曲手柄：拉直（第一下也得按在它上面）
    let grip = annotationHandle(at: point)
    if event.clickCount == 2, let grip, grip.handle == .bend, grip.annotation.id == pressedBend {
      let straight = grip.annotation.straightened
      return commit(annotations.map { $0.id == straight.id ? straight : $0 })
    }
    let hit = annotation(at: point)
    if event.clickCount == 2, let hit, case .text(_, let origin) = hit.shape {
      return beginEditing(at: origin, existing: hit)
    }
    // 优先级：选中标注的手柄 → 标注本体 → 工具作画 → 空白（取消选中）
    if let grip {
      if grip.handle == .bend { bendPressed = grip.annotation.id }
      let segment = [Annotation.Handle.start, .end, .bend].contains(grip.handle)
      drag = .resizeAnnotation(
        grip.annotation, grip.handle, before: annotations,
        offset: segment
          ? CGVector(dx: grip.point.x - point.x, dy: grip.point.y - point.y) : .zero)
      return
    }
    if let hit {
      // ⌥：先复制一份（序号换下一个号）放在最上面，拖的是副本，光标带 +
      let before = annotations
      let target = modifiers.contains(.option) ? duplicate(hit, offset: .zero) : hit
      if target.id != hit.id { annotations.append(target) }
      selectedAnnotation = target.id
      (target.id == hit.id ? NSCursor.closedHand : .dragCopy).set()
      drag = .moveAnnotation(
        target, start: point, before: before, copyOf: target.id == hit.id ? nil : hit.id)
      return
    }
    selectedAnnotation = nil
    guard let tool else { return }
    switch tool {
    case .text:
      beginEditing(at: point)
    case .counter:
      // 单击放一个序号（编号自动 +1）并选中；按着拖就是挪它，松手一共记一步撤销
      let before = annotations
      let counter = Annotation(
        shape: .counter(Annotation.nextCounter(in: annotations), center: point), style: style)
      annotations.append(counter)
      selectedAnnotation = counter.id
      drag = .moveAnnotation(counter, start: point, before: before, copyOf: nil)
    default:
      drag = .annotate(start: point)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    mouse = point
    modifiers = event.modifierFlags
    dragPoint = point
    if case .pan(let start)? = drag {
      guard let clip = enclosingScrollView?.contentView else { return }
      let delta = CGPoint(
        x: start.x - event.locationInWindow.x, y: start.y - event.locationInWindow.y)
      clip.scroll(
        to: CGPoint(
          x: clip.bounds.origin.x + delta.x / max(zoom, 0.01),
          y: clip.bounds.origin.y + delta.y / max(zoom, 0.01)))
      enclosingScrollView?.reflectScrolledClipView(clip)
      drag = .pan(start: event.locationInWindow)
      return
    }
    guard isDraggingAnnotation else { return }
    // 画到窗口边上时跟着滚（拍板 B3）。ponytail: 用系统的自动滚动（拖出可见区才滚），没有自己做提前量
    autoscroll(with: event)
    dragAnnotation(to: point)
  }

  /// 画标注、拖标注、拖手柄跟到 point。⇧：正方形 / 正圆 / 45° 线，拖本体时锁轴
  private func dragAnnotation(to point: CGPoint) {
    let constrained = modifiers.contains(.shift)
    switch drag {
    case .annotate(let start)?:
      guard let tool else { return }
      guard tool == .pen else {
        guard
          let shape = Annotation.shape(for: tool, from: start, to: point, constrained: constrained)
        else { return }
        draft = Annotation(id: draft?.id ?? UUID(), shape: shape, style: style)
        return
      }
      // 画笔：一路累点，离上一个点不到 1.5 点的不要
      var points = [start]
      if case .pen(let drawn)? = draft?.shape { points = drawn }
      if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
      draft = Annotation(id: draft?.id ?? UUID(), shape: .pen(points + [point]), style: style)
    case .moveAnnotation(let original, let start, _, let copyOf)?:
      (copyOf == nil ? NSCursor.closedHand : .dragCopy).set()
      var delta = CGSize(width: point.x - start.x, height: point.y - start.y)
      if constrained {
        if abs(delta.width) > abs(delta.height) { delta.height = 0 } else { delta.width = 0 }
      }
      replace(original.offset(by: delta))
    case .resizeAnnotation(let original, let handle, _, let offset)?:
      let target = CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
      replace(original.resized(handle, to: target, constrained: constrained))
    default:
      break
    }
  }

  override func mouseUp(with event: NSEvent) {
    let finished = drag
    dragPoint = nil
    drag = nil
    switch finished {
    case .annotate?:
      let drawn = draft
      draft = nil
      // 画完自动选中（工具保持）：接着就能改样式、拖手柄
      if let drawn, drawn.isMeaningful {
        commit(annotations + [drawn])
        selectedAnnotation = drawn.id
      }
    case .moveAnnotation(let moved, _, let before, let source)?:
      // ⌥ 单击没拖开：不留一份叠在原处、看不出来的副本
      if let source, annotations.contains(moved) {
        annotations = before
        selectedAnnotation = source
      } else {
        recordUndo(from: before)
      }
    case .resizeAnnotation(let original, _, let before, _)?:
      // 两端拖到叠在一起、看不出来了：算误操作，恢复原样
      if annotations.first(where: { $0.id == original.id })?.isMeaningful == false {
        replace(original)
      }
      recordUndo(from: before)
    case .pan?, nil:
      break
    }
    refreshCursor()
  }

  /// 光标只能手动设：状态一变就按鼠标当前位置重设
  private func refreshCursor() {
    guard let point = mouse else { return }
    if isSpaceDown { return NSCursor.openHand.set() }
    if let editor {
      return (editor.field.frame.contains(point) ? NSCursor.iBeam : NSCursor.arrow).set()
    }
    if let grip = annotationHandle(at: point) { return Self.cursor(for: grip.handle).set() }
    if annotation(at: point) != nil { return NSCursor.openHand.set() }
    (tool == .text ? NSCursor.iBeam : tool == nil ? .arrow : .crosshair).set()
  }

  /// 标注手柄上的光标：矩形类的角是斜向缩放，线类两端和弯曲手柄是手指
  private static func cursor(for handle: Annotation.Handle) -> NSCursor {
    switch handle {
    case .start, .end, .bend: .pointingHand
    default: .crosshair
    }
  }

  // MARK: 键盘

  override func keyDown(with event: NSEvent) {
    let code = Int(event.keyCode)
    if code == kVK_Space {
      if !event.isARepeat {
        isSpaceDown = true
        refreshCursor()
      }
      return
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option])
    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
    guard flags.isEmpty else { return super.keyDown(with: event) }
    switch code {
    case kVK_Escape:
      // 收下输入中的文字 → 收起工具 → 取消选中；都没有就交给窗口（关掉）
      if endEditing() { return }
      if tool != nil { return choose(nil) }
      if selectedAnnotation != nil {
        selectedAnnotation = nil
        return
      }
      super.keyDown(with: event)
    case _ where SelectionView.toolKeys[code] != nil:
      if let next = SelectionView.toolKeys[code] { choose(next) }
    case kVK_Delete, kVK_ForwardDelete: deleteSelected()
    case kVK_LeftArrow: nudge(-step, 0)
    case kVK_RightArrow: nudge(step, 0)
    case kVK_UpArrow: nudge(0, step)
    case kVK_DownArrow: nudge(0, -step)
    default: super.keyDown(with: event)
    }
  }

  override func keyUp(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Space {
      isSpaceDown = false
      refreshCursor()
    } else {
      super.keyUp(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    switch (Int(event.keyCode), flags) {
    case (kVK_ANSI_Z, .command): undo()
    case (kVK_ANSI_Z, [.command, .shift]): redo()
    case (kVK_ANSI_D, .command): duplicateSelected()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  /// 修饰键按下 / 松开：画 / 拖标注途中按上次的鼠标位置重算（⇧ 立刻生效）
  override func flagsChanged(with event: NSEvent) {
    modifiers = event.modifierFlags
    if let dragPoint, isDraggingAnnotation { dragAnnotation(to: dragPoint) }
    super.flagsChanged(with: event)
  }
}
