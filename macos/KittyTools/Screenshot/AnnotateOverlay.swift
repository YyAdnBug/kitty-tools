// 标注遮罩（2026-10-26；原来是一扇正经窗口，用户手测说「我要的是截图后出现工具栏的那种效果」，当天改成遮罩）：
// 长截图拼完按 A、截图历史里双击一条，都用它——整屏盖一层暗底，图摆在中间，工具栏贴在图下方，
// 和截图框选确定之后那一套看齐；标完拷贝 / 存储 / 另存为 / 识字。
// 窗口形态是无边框的 NSPanel 子类（要当 key 收按键、收文字输入；mac-overlay-panel §1 的例外之一），
// 状态栏层级、盖住鼠标所在的那块屏、**不激活本 App**（同截图遮罩，前台 App 不变）。
// 图比遮罩里那块地方大时（长截图）在框里滚动、能缩放，所以长图照样标得了。
// 画布不把长图整张贴给图层（长图上限 30000 像素高，超过约 16384 会撞 GPU 纹理上限）：draw 里按脏区裁出看得见的那一段
// 画（CGImage.cropping 是零拷贝的视图）。缩放交给 NSScrollView 的 magnification（拍板 A3：默认按宽适配、最大 1:1，
// ⌘0 适配宽度、⌘1 原始大小、⌘+ / ⌘-），标注坐标一律存图的点坐标，所以缩放不影响画好的标注。
// 画布和标注交互在 ScrollCanvas.swift；这里管窗口、滚动、缩放、工具栏和样式托盘、出图。

import AppKit
import Carbon.HIToolbox

@MainActor final class AnnotateOverlay: NSObject {
  /// 出图：动作、合成好的图、像素 / 点、画了哪些标注（AppDelegate 接到截图那条路上，顺手把标注回写进历史）
  typealias Output = @MainActor (RegionSelector.Action, CGImage, CGFloat, [Annotation]) -> Void

  /// 缩放的上下限和一档（⌘+ / ⌘-）
  private static let zoomRange: ClosedRange<CGFloat> = 0.1...4
  private static let zoomStep: CGFloat = 1.25

  private let image: CGImage
  /// 像素 / 点
  private let scale: CGFloat
  /// 单测直接摆状态、发按键用
  let panel: AnnotatePanel
  /// 整屏的暗底（图那一块挖空）
  private let shade = CALayer()
  /// 图在遮罩里占的那一块（点，面板坐标）
  private var box = CGRect.zero
  /// Esc 第一下是「再按一次放弃」（画过标注时；遮罩里不弹系统框，同录屏放弃两下）
  private var armedEscape = false
  private let scrollView = NSScrollView()
  private let canvas: ScrollCanvas
  private let bar = EditorToolbar(mode: .longShot)
  private let styleBar = StyleBar()
  private let output: Output
  /// 关掉了（AppDelegate 放掉这个会话）
  var onClose: () -> Void = {}

  var isVisible: Bool { panel.isVisible }

  /// screen：盖哪块屏（默认鼠标所在的那块）。annotations：打开时就画上的标注（历史里「改标注」给的，
  /// 坐标是这张图的点坐标）
  init(
    image: CGImage, scale: CGFloat, annotations: [Annotation] = [], screen: NSScreen? = nil,
    output: @escaping Output
  ) {
    self.image = image
    self.scale = scale
    self.output = output
    canvas = ScrollCanvas(image: image, scale: scale)
    let target =
      screen
      ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main ?? NSScreen.screens[0]
    panel = AnnotatePanel(
      contentRect: target.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    super.init()

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.allowsMagnification = true
    scrollView.minMagnification = Self.zoomRange.lowerBound
    scrollView.maxMagnification = Self.zoomRange.upperBound
    scrollView.drawsBackground = false
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentView = CenteringClipView()  // 图比框窄 / 矮时居中，不贴着左下角
    scrollView.documentView = canvas
    scrollView.wantsLayer = true
    scrollView.layer?.cornerRadius = Style.Radius.card
    scrollView.layer?.cornerCurve = .continuous
    scrollView.layer?.masksToBounds = true
    bar.onClick = { [unowned self] item in clicked(item) }
    styleBar.onColor = { [unowned self] color in canvas.restyle { $0.color = color } }
    styleBar.onWeight = { [unowned self] weight in canvas.restyle { $0.weight = weight } }
    styleBar.onOption = { [unowned self] option in canvas.restyle { $0.option = option } }
    canvas.onState = { [unowned self] in syncBars() }

    let content = AnnotateOverlayView()
    content.frame = CGRect(origin: .zero, size: target.frame.size)
    content.onKey = { [unowned self] key in self.key(key) }
    content.wantsLayer = true
    // 整屏压暗（同截图遮罩的 shade）：图那一块由 scrollView 盖住，所以直接铺一层就行
    shade.frame = content.bounds
    shade.backgroundColor = Style.HUD.scrim.cgColor
    content.layer?.addSublayer(shade)
    box = Self.imageBox(pointSize: pointSize, in: target.visibleFrame, origin: target.frame.origin)
    scrollView.frame = box
    content.addSubview(scrollView)
    // 先藏起来再加进去（同遮罩里的两条栏）：PopView 的 isShown 一开始就是 false，
    // setShown(false) 会直接返回、不动 isHidden——不这么做的话没选工具时托盘就停在窗口左下角露着
    // （2026-10-26 手测报的）
    for view in [styleBar, bar] as [NSView] {
      view.isHidden = true
      content.addSubview(view)
    }
    panel.contentView = content
    NotificationCenter.default.addObserver(
      self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification,
      object: scrollView)
    panel.level = .statusBar  // 同截图遮罩：盖住菜单栏和程序坞
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.allowsToolTipsWhenApplicationIsInactive = true  // 本 App 不激活，按钮的提示照样出
    canvas.annotations = annotations
    panel.initialFirstResponder = canvas
    placeBar()
    bar.grow(true, from: box.minY >= bar.frame.height + 2 * Self.barMargin ? .top : .bottom)
    syncBars()
    zoomToFit()
    scrollToTop()
  }

  /// 图在遮罩里占哪一块（点，面板坐标）：按可见区的 80% 适配、最大 1:1，居中；
  /// 下面给工具栏留出 56。纯函数，配单测
  static func imageBox(pointSize: CGSize, in visible: CGRect, origin: CGPoint) -> CGRect {
    let room = CGSize(width: visible.width * 0.84, height: visible.height * 0.78)
    guard pointSize.width > 0, pointSize.height > 0 else {
      return CGRect(origin: .zero, size: room)
    }
    let ratio = min(min(room.width / pointSize.width, room.height / pointSize.height), 1)
    let size = CGSize(
      width: max((pointSize.width * ratio).rounded(), 240),
      height: max((pointSize.height * ratio).rounded(), 160))
    // 面板盖的是整块屏，可见区（去掉菜单栏）要换成面板里的坐标
    let area = CGRect(
      x: visible.minX - origin.x, y: visible.minY - origin.y, width: visible.width,
      height: visible.height)
    return CGRect(
      x: (area.midX - size.width / 2).rounded(),
      y: (area.midY - size.height / 2 + 28).rounded(), width: size.width, height: size.height)
  }

  /// 图的点尺寸（标注的坐标系；长图的像素 / scale）
  private var pointSize: CGSize { canvas.bounds.size }

  /// 工具栏离窗口左右和底边多远（窄窗口里也要留出这么多）
  static let barMargin: CGFloat = 16

  /// 按宽适配的缩放（拍板 A3）：窄的长图不放大，最大 1:1。纯函数，配单测
  static func fitMagnification(pointWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
    guard pointWidth > 0, viewportWidth > 0 else { return 1 }
    return min(1, max(zoomRange.lowerBound, viewportWidth / pointWidth))
  }

  /// 显示：同截图遮罩——不激活本 App（前台 App 不变），面板自己当 key 收按键
  func show() {
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.makeFirstResponder(canvas)
  }

  func close() {
    NotificationCenter.default.removeObserver(self)
    panel.orderOut(nil)
    onClose()
  }

  // MARK: 缩放与位置

  private func zoomToFit() {
    setMagnification(
      Self.fitMagnification(
        pointWidth: pointSize.width, viewportWidth: scrollView.contentSize.width))
  }

  private func setMagnification(_ value: CGFloat) {
    scrollView.magnification = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    canvas.zoom = scrollView.magnification  // 选中框和手柄的线宽按它补偿
  }

  /// 捏合缩放完（没经 setMagnification）：手柄的粗细跟上
  @objc private func magnified() { canvas.zoom = scrollView.magnification }

  /// 长图从上往下看：一打开停在最上面（画布原点在左下，顶边是最大的 y）
  private func scrollToTop() {
    panel.layoutIfNeeded()
    let clip = scrollView.contentView
    canvas.scroll(NSPoint(x: 0, y: max(canvas.bounds.height - clip.documentVisibleRect.height, 0)))
  }

  /// 工具栏浮在内容底部居中（离底 16，同截图工具栏离选区 10 的那条边）
  /// 工具栏和样式托盘跟着画布的状态走：托盘在工具栏上方 6 pt、x 对着当前工具那颗钮（夹在窗口里 10 pt）
  private func syncBars() {
    bar.update(tool: canvas.tool, canUndo: canvas.canUndo, canRedo: canvas.canRedo)
    guard let owner = canvas.styleOwner, let content = panel.contentView else {
      return styleBar.setShown(false)
    }
    styleBar.update(tool: owner, style: canvas.shownStyle)
    let button = bar.toolButtonFrame(owner).offsetBy(dx: bar.frame.minX, dy: bar.frame.minY)
    let size = styleBar.preferredSize
    let x = max(
      10, min(button.midX - size.width / 2, content.bounds.maxX - size.width - 10)
    ).rounded()
    // 栏在图下面时托盘再往下叠，栏在图上面时往上叠（同遮罩里的做法）
    let below = bar.frame.minY < box.minY
    let y = below ? bar.frame.minY - 6 - size.height : bar.frame.maxY + 6
    styleBar.move(
      to: CGRect(x: x, y: y, width: size.width, height: size.height), animated: styleBar.isShown)
    styleBar.setShown(true, anchorX: button.midX - x, growingFrom: .bottom)
  }

  /// 工具栏贴在图下方 10 pt、水平以图为中心（同截图工具栏贴着选区）；下面放不下就放上方，
  /// 都放不下贴在图里底部。纯函数那一半在 SelectionView.toolbarPlacement，这里直接用它
  private func placeBar() {
    guard let content = panel.contentView else { return }
    let (origin, _) = SelectionView.toolbarPlacement(
      size: bar.frame.size, selection: box, in: content.bounds)
    bar.frame.origin = origin
  }

  // MARK: 出图

  /// 合成好的长图（有标注才重渲，拍板 C2）
  private func composed() -> CGImage { canvas.composed() }

  private func clicked(_ item: EditorToolbar.Item) {
    switch item {
    case .output(let action): emit(action)
    case .cancel: dismiss()
    case .saveMenu: emit(.saveAs)  // 第 3 批换成 HUD 菜单（存储到… / 另存为…）
    case .tool(let tool): canvas.choose(tool)
    case .undo: canvas.undo()
    case .redo: canvas.redo()
    case .scroll, .record: break  // 长图的工具栏里没有这两颗
    }
  }

  /// 拷贝 / 存储 / 另存为完就收起遮罩（这一次到此结束）；识字只是把文字拿走，遮罩留着
  private func emit(_ action: RegionSelector.Action) {
    armedEscape = false
    output(action, composed(), scale, canvas.annotations)
    if action != .recognize { close() }
  }

  /// 取消：画过标注的要按两下（遮罩里不弹系统框，同录屏的放弃；第一下提示音 + 顶部提示）
  private func dismiss() {
    guard canvas.hasAnnotations, !armedEscape else { return close() }
    armedEscape = true
    NSSound.beep()
    Island.announce("再按一次 Esc 放弃这些标注")
  }

  /// 窗口里的按键（内容视图收，第 2 批标注的键也走这里）
  private func key(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    switch (Int(event.keyCode), flags) {
    case (kVK_Escape, []): dismiss()
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
    if Int(event.keyCode) != kVK_Escape { armedEscape = false }  // 按了别的键就不再上膛
    return true
  }

}

/// 遮罩面板：无边框窗口默认当不了 key（收不到 Esc、↩、打字），所以要子类化（同截图遮罩、长截图面板；
/// mac-overlay-panel §1 的例外之一）
final class AnnotatePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// 遮罩的内容视图：暗底、图框和工具栏的壳，按键在这里收（画布当第一响应者画标注，没处理的键冒泡到这里）
final class AnnotateOverlayView: NSView {
  var onKey: (NSEvent) -> Bool = { _ in false }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if !onKey(event) { super.keyDown(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    onKey(event) || super.performKeyEquivalent(with: event)
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
