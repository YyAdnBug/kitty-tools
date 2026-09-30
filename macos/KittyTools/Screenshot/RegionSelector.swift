// 框选会话：每块屏幕盖一个全屏遮罩（SelectionOverlay）画冻结帧，选区只在一块屏上。两种用法：
// - 截图翻译 / 识字 select：拖动框选（⇧ 正方形、⌥ 从中心、空格平移、吸附窗口边），松手确认，Esc / 右键取消；
// - 截图 capture：悬停高亮窗口 / 单击截整窗、确认后可调整选区和标注，↩ 复制、⌘S 保存、⇧⌘S 另存为、T 钉图、
//   S 长截图、工具栏识字 / 翻译，C 复制放大镜中心的色值，D 选中上次的区域；
// - 录屏 record：框选同截图（悬停、单击窗口 / 整屏、调整、尺寸胶囊、D），没有标注和出图键，↩ / 双击 / 录制条的 ● 交回选区；
//   截图调整时按 R / 工具栏「录屏」也会切到它（选区不变，录屏第 2 批）。
// 遮罩是不激活前台的 NSPanel（和 OverlayPanel 一样不抢前台 App），会话结束立即 orderOut 释放，不常驻
// （全屏窗口的 backing store 是内存大头）。画面与交互在 SelectionView。

import AppKit

enum RegionSelector {
  /// 选区短边小于这个（点）当作误触：回到待选状态，不确认
  static let minimumSide: CGFloat = 8

  enum Action {
    case copy, save, saveAs, pin
    /// 识字并复制（识别的是打码后的合成图）
    case recognize
    case translate
  }

  struct Capture {
    /// 选区的像素图（截图模式下是画上标注的合成图，不再引用整屏冻结帧）
    let image: CGImage
    /// 选区（点，AppKit 全局坐标）
    let frame: CGRect
    /// 截图翻译 / 识字只取图，不看它
    let action: Action

    /// 像素 / 点
    var scale: CGFloat { frame.width > 0 ? CGFloat(image.width) / frame.width : 1 }
  }

  enum Outcome {
    case capture(Capture)
    /// 放大镜中心像素的色值（#RRGGBB，sRGB）
    case color(String)
    /// 长截图：只带选区（点，AppKit 全局坐标），不裁图（裁出的图会拖住整屏冻结帧直到长截图结束）
    case scroll(CGRect)
    /// 录屏：只带选区（点，AppKit 全局坐标，同 scroll）；整屏 = 那块屏的 frame
    case record(CGRect)
  }

  /// 截图翻译 / 识字：在冻结帧上框选，松手返回裁好的图；取消返回 nil。hint 是屏幕上方的提示
  static func select(_ shots: [ScreenCapture.Shot], hint: String) async -> CGImage? {
    guard
      case .capture(let capture)? = await run(shots, SelectionSession(mode: .quick, hint: hint))
    else { return nil }
    return capture.image
  }

  /// 截图：lastRegion 是上次截图的区域（全局坐标，D 键选中）；preselect 时一开始就选中它（⌥X 截上次区域）
  static func capture(_ shots: [ScreenCapture.Shot], lastRegion: CGRect?, preselect: Bool) async
    -> Outcome?
  {
    let session = SelectionSession(mode: .capture, lastRegion: lastRegion)
    session.preselectsLastRegion = preselect
    return await run(shots, session)
  }

  /// 录屏：框选同截图（lastRegion 同截图共用，D 键选中），交回 .record(选区)；C 复制色值时交回 .color，取消 nil
  static func record(_ shots: [ScreenCapture.Shot], lastRegion: CGRect?) async -> Outcome? {
    await run(shots, SelectionSession(mode: .record, lastRegion: lastRegion))
  }

  private static func run(_ shots: [ScreenCapture.Shot], _ session: SelectionSession) async
    -> Outcome?
  {
    await withCheckedContinuation { session.start(shots, continuation: $0) }
  }

  // MARK: 几何（纯函数，配单测）

  /// 视图里的选区（点，原点左下）→ 图里的像素矩形（原点左上），取整并夹在图内
  static func pixelRect(_ selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
    let scaleX = imageSize.width / viewSize.width
    let scaleY = imageSize.height / viewSize.height
    let rect = CGRect(
      x: selection.minX * scaleX, y: (viewSize.height - selection.maxY) * scaleY,
      width: selection.width * scaleX, height: selection.height * scaleY
    ).integral
    return rect.intersection(CGRect(origin: .zero, size: imageSize))
  }

  /// 选区的 8 个调整手柄（四个角在前：选区很小时点中的优先算角）
  enum Handle: CaseIterable {
    case bottomLeft, bottomRight, topRight, topLeft, bottom, right, top, left

    /// 这个手柄拖动的是哪几条边
    var movesMinX: Bool { [.bottomLeft, .topLeft, .left].contains(self) }
    var movesMaxX: Bool { [.bottomRight, .topRight, .right].contains(self) }
    var movesMinY: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    var movesMaxY: Bool { [.topLeft, .top, .topRight].contains(self) }

    func point(in rect: CGRect) -> CGPoint {
      CGPoint(
        x: movesMinX ? rect.minX : movesMaxX ? rect.maxX : rect.midX,
        y: movesMinY ? rect.minY : movesMaxY ? rect.maxY : rect.midY)
    }

    /// 横、竖各靠哪一侧（-1 小的那条边、1 大的那条边、0 都不靠）；两个都是 0 时没有手柄
    init?(x: Int, y: Int) {
      switch (x, y) {
      case (-1, -1): self = .bottomLeft
      case (1, -1): self = .bottomRight
      case (1, 1): self = .topRight
      case (-1, 1): self = .topLeft
      case (0, -1): self = .bottom
      case (0, 1): self = .top
      case (-1, 0): self = .left
      case (1, 0): self = .right
      default: return nil
      }
    }

    /// 拖动中实际在动的边 / 角：拖过对边后选区翻了过去，动的是另一侧（加粗的边、放大的手柄跟着走）。
    /// 只看这个手柄管的方向，按拖动点在选区中线的哪一侧定
    func facing(_ point: CGPoint, in rect: CGRect) -> Handle {
      let x = movesMinX || movesMaxX ? (point.x < rect.midX ? -1 : 1) : 0
      let y = movesMinY || movesMaxY ? (point.y < rect.midY ? -1 : 1) : 0
      return Handle(x: x, y: y) ?? self
    }
  }

  /// 点中的手柄：整条边都能拖（系统截屏、CleanShot 的习惯），不只是 8 个手柄点。每条边一条带：边外 tolerance、
  /// 边内 inner（默认同 tolerance；选区很小时调用方缩小它，中间还能拖着平移），横竖两条带交叠处是角
  static func handle(
    at point: CGPoint, in rect: CGRect, tolerance: CGFloat = 8, inner: CGFloat? = nil
  ) -> Handle? {
    let inner = inner ?? tolerance
    /// 靠近哪一侧：-1 小的那条边、1 大的那条边、0 都不靠近、nil 在带外（两侧都靠近时取近的）
    func side(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Int? {
      guard value >= low - tolerance, value <= high + tolerance else { return nil }
      let nearLow = value <= low + inner
      let nearHigh = value >= high - inner
      if nearLow, nearHigh { return value - low <= high - value ? -1 : 1 }
      return nearLow ? -1 : nearHigh ? 1 : 0
    }
    guard let x = side(point.x, rect.minX, rect.maxX), let y = side(point.y, rect.minY, rect.maxY)
    else { return nil }
    return Handle(x: x, y: y)
  }

  /// 拖手柄：从按下时的选区 original 出发，把手柄管的边移到 point（先夹进 bounds）；越过对边就翻过去。宽高至少 1 点。
  /// ratio（宽 / 高：⇧ 时是原选区的比例，或锁着的预设）：拖角按拖得更远的那边定大小，拖边时另一边跟着变、以原中心对齐；
  /// fromCenter（⌥）：对边反向一起动，中心不动
  static func resized(
    _ original: CGRect, _ handle: Handle, to point: CGPoint, within bounds: CGRect,
    ratio: CGFloat? = nil, fromCenter: Bool = false
  ) -> CGRect {
    let x = min(max(point.x, bounds.minX), bounds.maxX)
    let y = min(max(point.y, bounds.minY), bounds.maxY)
    let movesX = handle.movesMinX || handle.movesMaxX
    let movesY = handle.movesMinY || handle.movesMaxY
    // 不动的是对边，⌥ 时是中心；锁比例拖边时另一个方向也以中心对齐
    let centerX = fromCenter || (!movesX && ratio != nil)
    let centerY = fromCenter || (!movesY && ratio != nil)
    let fixed = CGPoint(
      x: centerX ? original.midX : handle.movesMinX ? original.maxX : original.minX,
      y: centerY ? original.midY : handle.movesMinY ? original.maxY : original.minY)
    var width = movesX ? abs(x - fixed.x) * (centerX ? 2 : 1) : original.width
    var height = movesY ? abs(y - fixed.y) * (centerY ? 2 : 1) : original.height
    if let ratio {
      if movesX, movesY {
        if width >= height * ratio { height = width / ratio } else { width = height * ratio }
      } else if movesX {
        height = width / ratio
      } else {
        width = height * ratio
      }
    }
    /// 固定点在框里的位置：往哪侧拖就往哪侧长（正好压在对边上时按手柄那一侧）
    func side(_ moves: Bool, _ center: Bool, _ value: CGFloat, _ fixed: CGFloat, _ low: Bool)
      -> CGFloat
    {
      if center { return 0.5 }
      guard moves else { return 0 }
      return value > fixed ? 0 : value < fixed ? 1 : low ? 1 : 0
    }
    return fitted(
      fixed: fixed, size: CGSize(width: width, height: height),
      anchor: CGPoint(
        x: side(movesX, centerX, x, fixed.x, handle.movesMinX),
        y: side(movesY, centerY, y, fixed.y, handle.movesMinY)),
      keepsRatio: ratio != nil, within: bounds)
  }

  /// 拖出新框：从锚点拉到 point。ratio（宽 / 高：⇧ 时 1，或锁着的预设）按拖得更远的那边定大小；fromCenter（⌥）时锚点是中心。
  /// 超出 bounds 就缩小（锁比例时等比缩），锚点不动
  static func drawn(
    from anchor: CGPoint, to point: CGPoint, ratio: CGFloat? = nil, fromCenter: Bool = false,
    within bounds: CGRect
  ) -> CGRect {
    var width = abs(point.x - anchor.x)
    var height = abs(point.y - anchor.y)
    if let ratio {
      width = max(width, height * ratio)
      height = width / ratio
    }
    let scale: CGFloat = fromCenter ? 2 : 1
    return fitted(
      fixed: anchor, size: CGSize(width: width * scale, height: height * scale),
      anchor: CGPoint(
        x: fromCenter ? 0.5 : point.x >= anchor.x ? 0 : 1,
        y: fromCenter ? 0.5 : point.y >= anchor.y ? 0 : 1),
      keepsRatio: ratio != nil, within: bounds)
  }

  /// 固定点 fixed 在框里的相对位置是 anchor（0 左 / 下边、0.5 中心、1 右 / 上边）：超出 bounds 就缩小（keepsRatio 时等比缩），
  /// 宽高至少 1 点，补出来的那点也别越过 bounds（越界的选区裁不出图）
  private static func fitted(
    fixed: CGPoint, size: CGSize, anchor: CGPoint, keepsRatio: Bool, within bounds: CGRect
  ) -> CGRect {
    /// 固定点往两侧各还有多少地方，折成这个方向最多多长
    func room(_ value: CGFloat, _ k: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
      max(
        0, min(k < 1 ? (high - value) / (1 - k) : .infinity, k > 0 ? (value - low) / k : .infinity))
    }
    let maxWidth = room(fixed.x, anchor.x, bounds.minX, bounds.maxX)
    let maxHeight = room(fixed.y, anchor.y, bounds.minY, bounds.maxY)
    var width = size.width
    var height = size.height
    if keepsRatio {
      let shrink = min(
        1, width > maxWidth ? maxWidth / width : 1, height > maxHeight ? maxHeight / height : 1)
      width *= shrink
      height *= shrink
    } else {
      width = min(width, maxWidth)
      height = min(height, maxHeight)
    }
    width = max(width, 1)
    height = max(height, 1)
    return CGRect(
      x: min(max(fixed.x - width * anchor.x, bounds.minX), bounds.maxX - width),
      y: min(max(fixed.y - height * anchor.y, bounds.minY), bounds.maxY - height),
      width: width, height: height)
  }

  /// 吸附：threshold 内离 value 最近的候选边；没有就原值，edge 为 nil（吸上了才画参考线）
  static func snapped(_ value: CGFloat, to edges: [CGFloat], threshold: CGFloat = 6)
    -> (value: CGFloat, edge: CGFloat?)
  {
    guard let nearest = edges.min(by: { abs($0 - value) < abs($1 - value) }),
      abs(nearest - value) <= threshold
    else { return (value, nil) }
    return (nearest, nearest)
  }

  /// ⌘ / ⌥ + 方向键：把 edge 那条边往外推 delta（负数往里收）；短边不小于 minimumSide（本来就更小的不再收），夹在 bounds 里
  static func pushed(_ rect: CGRect, _ edge: Handle, by delta: CGFloat, within bounds: CGRect)
    -> CGRect
  {
    var (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let minWidth = min(rect.width, minimumSide)
    let minHeight = min(rect.height, minimumSide)
    switch edge {
    case .left: minX = min(max(minX - delta, bounds.minX), maxX - minWidth)
    case .right: maxX = max(min(maxX + delta, bounds.maxX), minX + minWidth)
    case .bottom: minY = min(max(minY - delta, bounds.minY), maxY - minHeight)
    case .top: maxY = max(min(maxY + delta, bounds.maxY), minY + minHeight)
    default: return rect
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// 尺寸胶囊输入的像素宽高 → 选区：左上角 (minX, maxY) 不动（先对齐到像素格，和 pixelRect 往外取整的一样：左边向下、
  /// 上边向上，不然小数点的选区一输入左上角就挪一像素），按每点几像素 scale 换成点，往右下长、夹进 bounds（至少 1 点）
  static func sized(_ rect: CGRect, pixels: CGSize, scale: CGSize, within bounds: CGRect) -> CGRect
  {
    let left = (rect.minX * scale.width).rounded(.down) / scale.width
    let top = (rect.maxY * scale.height).rounded(.up) / scale.height
    let width = min(max(pixels.width / scale.width, 1), bounds.maxX - left)
    let height = min(max(pixels.height / scale.height, 1), top - bounds.minY)
    return CGRect(x: left, y: top - height, width: width, height: height)
  }

  /// 比例预设（尺寸胶囊的菜单）：宽 / 高，nil = 自由
  static let ratios: [(title: String, value: CGFloat?)] = [
    ("自由", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
  ]

  static func ratioTitle(_ ratio: CGFloat?) -> String {
    ratios.first { $0.value == ratio }?.title ?? "自由"
  }

  /// 套用比例预设：宽不变、高按比例，顶边和水平中心不动；下面放不下就按剩下的高反推宽（只会变窄，不会出屏）
  static func applying(_ ratio: CGFloat, to rect: CGRect, within bounds: CGRect) -> CGRect {
    var width = rect.width
    var height = width / ratio
    if rect.maxY - height < bounds.minY {
      height = rect.maxY - bounds.minY
      width = height * ratio
    }
    return CGRect(x: rect.midX - width / 2, y: rect.maxY - height, width: width, height: height)
  }

  /// 平移选区，整块留在 bounds 里（大小不变）
  static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
    var moved = rect.offsetBy(dx: delta.width, dy: delta.height)
    moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - rect.width)
    moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - rect.height)
    return moved
  }

  /// 实时画面上截 / 录一块选区（长截图、录屏共用）：选区（点，AppKit 全局坐标）夹进这块屏（frame，全局）、四边对齐到像素
  /// （scale = 每点几像素），返回对齐后的选区（全局）和 ScreenCaptureKit 的 sourceRect（屏内、点、原点左上）
  static func captureRect(_ region: CGRect, in screen: CGRect, scale: CGFloat) -> (
    region: CGRect, source: CGRect
  ) {
    let local = region.intersection(screen).offsetBy(dx: -screen.minX, dy: -screen.minY)
    let snapped = CGRect(
      x: (local.minX * scale).rounded() / scale, y: (local.minY * scale).rounded() / scale,
      width: (local.width * scale).rounded() / scale,
      height: (local.height * scale).rounded() / scale)
    return (
      snapped.offsetBy(dx: screen.minX, dy: screen.minY),
      CGRect(
        x: snapped.minX, y: screen.height - snapped.maxY, width: snapped.width,
        height: snapped.height)
    )
  }

  /// 上次的区域（全局坐标）放到哪块屏上：相交面积最大的那块，夹进该屏，返回屏的下标和屏内坐标。
  /// 屏幕变了（外接屏拔掉）、完全落在屏外时返回 nil
  static func placement(of region: CGRect, in screens: [CGRect]) -> (index: Int, rect: CGRect)? {
    let areas = screens.map { screen -> CGFloat in
      let overlap = screen.intersection(region)
      return overlap.isNull ? 0 : overlap.width * overlap.height
    }
    guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else {
      return nil
    }
    let screen = screens[best]
    let rect = screen.intersection(region).offsetBy(dx: -screen.minX, dy: -screen.minY)
    return (best, rect)
  }
}

/// 一次框选会话：管各屏遮罩、选区只留一块屏、D 键上次区域、锁着的比例、结束时收起遮罩并交回结果
final class SelectionSession {
  /// 截图调整时按 R 切成录屏（SelectionView.switchToRecording），其余一直不变
  var mode: SelectionView.Mode
  /// 松手即确认时屏幕上方的提示，几段之间用「 · 」隔开（截图、录屏模式自己拼）
  let hint: String
  /// 上次截图的区域（全局坐标）
  let lastRegion: CGRect?
  /// 一开始就选中上次的区域
  var preselectsLastRegion = false
  /// 尺寸胶囊里锁着的比例（宽 / 高，RegionSelector.ratios 里的一个）：之后框选、拖边都按它，选「自由」解锁。整个会话共用
  var lockedRatio: CGFloat?
  private var overlays: [SelectionOverlay] = []
  /// 各屏的画面（start 时填上；单测直接放几个屏外窗口里的视图进来，不弹遮罩）
  var views: [SelectionView] = []
  /// 交回结果（单测直接接上它，不走 start 弹遮罩）
  var continuation: CheckedContinuation<RegionSelector.Outcome?, Never>?

  init(mode: SelectionView.Mode, hint: String = "", lastRegion: CGRect? = nil) {
    self.mode = mode
    self.hint = hint
    self.lastRegion = lastRegion
  }

  func start(
    _ shots: [ScreenCapture.Shot],
    continuation: CheckedContinuation<RegionSelector.Outcome?, Never>
  ) {
    self.continuation = continuation
    overlays = shots.map { SelectionOverlay(shot: $0, session: self) }
    views = overlays.map(\.selectionView)
    guard !overlays.isEmpty else { return finish(nil) }
    for overlay in overlays { overlay.orderFrontRegardless() }
    // 鼠标不动时收不到 mouseMoved：先设一次十字光标
    NSCursor.crosshair.set()
    // 鼠标所在屏的遮罩接收按键；其它屏的遮罩靠 acceptsFirstMouse 直接响应拖动。
    // 含上边（NSMouseInRect）：光标在屏幕最上一行时 y 正好等于 frame.maxY
    let mouse = NSEvent.mouseLocation
    let key = overlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? overlays[0]
    key.makeKey()
    // 放大镜一出来就在光标处
    let view = key.selectionView
    view.mouse = view.clamped(view.convert(key.convertPoint(fromScreen: mouse), from: nil))
    if preselectsLastRegion { selectLastRegion() }
  }

  /// 除 view 以外有没有屏上有选区（view 为 nil 时看全部屏）
  func hasSelection(besides view: SelectionView?) -> Bool {
    views.contains { $0 !== view && $0.selection != nil }
  }

  /// 除 view 以外有没有屏上画了标注（含正在输入、还没收下的文字）：会清掉那块屏的操作（右键、换屏框选、D）不做
  func hasAnnotations(besides view: SelectionView) -> Bool {
    views.contains { $0 !== view && $0.hasAnnotations }
  }

  /// 这块屏开始操作：别的屏清掉选区、悬停和放大镜（选区只在一块屏上）
  func activate(_ view: SelectionView) {
    for other in views where other !== view { other.reset() }
  }

  /// D 键 / ⌥X：选中上次的区域（落在哪块屏就在哪块屏上）；没有或已不在任何屏上时提示音。
  /// 返回 false = 上次的区域在别的屏上、跳过去会清掉这边画的标注，没跳（调用方提示，同右键）
  @discardableResult
  func selectLastRegion() -> Bool {
    guard let lastRegion,
      let (index, rect) = RegionSelector.placement(
        of: lastRegion, in: views.map { $0.window?.frame ?? .zero })
    else {
      NSSound.beep()
      return true
    }
    let view = views[index]
    guard !hasAnnotations(besides: view) else { return false }
    activate(view)
    view.window?.makeKey()
    view.select(rect)
    return true
  }

  /// 结果立刻交回、遮罩立刻收起，键盘马上回到原 App（淡出期间还当着 key 的话，接着打的字全被吞掉）。
  /// 取消时由系统淡出（临时 .utilityWindow 再 orderOut，同 OverlayPanel.dismiss；减弱动态效果时直接消失），
  /// 出图时没有退场动画（S1 飞行卡片接手）
  func finish(_ outcome: RegionSelector.Outcome?) {
    guard let continuation else { return }
    self.continuation = nil
    let closing = overlays
    overlays = []
    views = []
    NSCursor.arrow.set()
    for overlay in closing {
      overlay.animationBehavior = outcome == nil && !Style.reduceMotion ? .utilityWindow : .none
      overlay.orderOut(nil)
      overlay.animationBehavior = .none
    }
    continuation.resume(returning: outcome)
  }
}

/// 一块屏幕的遮罩。无边框窗口默认当不了 key（收不到 Esc），所以要子类化
final class SelectionOverlay: NSPanel {
  let selectionView: SelectionView

  init(shot: ScreenCapture.Shot, session: SelectionSession) {
    selectionView = SelectionView(image: shot.image, windows: shot.windows, session: session)
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
    animationBehavior = .none
    acceptsMouseMovedEvents = true
    // 本 App 从不激活：不设的话工具栏按钮的提示（快捷键、保存位置）永远不出来
    allowsToolTipsWhenApplicationIsInactive = true
    contentView = selectionView
    initialFirstResponder = selectionView
    setFrame(shot.screen.frame, display: false)
  }

  override var canBecomeKey: Bool { true }

  /// 无边框窗口也别被挪到菜单栏下面
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
