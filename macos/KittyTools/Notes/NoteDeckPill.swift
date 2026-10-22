// 屏幕边缘的药丸（PLAN §10「便签」拍板 B；规矩在 mac-overlay-panel §12，长相在 mac-whisker-notes.mdc）：平时贴在屏幕边上的
// 一小条，一条便签一道色条，鼠标靠过来就扇出那叠（Notes/NoteDeck.swift）。
// 它是装饰：普通 NSPanel 实例（不子类化；无边框、nonactivating、永不当 key、无阴影），层级状态栏——截图的冻结帧
// （ScreenCapture.keptOwnWindows）和录屏的白名单（recordedOwnWindows）按层级都不收它。所有桌面上都在；别的 App
// 全屏时默认不在，设置里开了「盖在全屏 App 上」才加 fullScreenAuxiliary。
// 内容只用 CALayer 画（layer-hosting 视图，不建 SwiftUI 宿主：常驻的东西越轻越好，实测约 +0 MB）。静置时没有定时器、
// 没有轮询，只挂一块 activeAlways 的进出追踪区：贴边的那一条，宽 = 感应范围。窗口自己不设 ignoresMouseEvents——
// 透明的地方系统本来就点穿，药丸本身接鼠标：按住 ⌥ 拖 = 换边、换高度，右键 = 小菜单。
// 「不显示药丸」时窗口和追踪区照旧在，只是什么都不画（整块透明，所以点不到、拖不了，靠过来照样扇出）。
// 皮肤（Style.HUD：降低透明度时更实、增强对比度时描边加粗）在每次重摆时取；系统的这两个开关中途变了，
// NoteEdge 听着通知重摆一次（它是常驻的，不能等下一次便签变动才跟上）。

import AppKit

final class NoteDeckPill {
  let panel: NSPanel
  private let view = PillView()
  /// 那叠展开着：药丸先淡掉（标签就在同一处）
  private var isShown = true
  private var hidesPill = false

  /// 鼠标进了感应区（按没按着 ⌥）、出去了
  var onEnter: (_ optionDown: Bool) -> Void {
    get { view.onEnter }
    set { view.onEnter = newValue }
  }
  var onExit: () -> Void {
    get { view.onExit }
    set { view.onExit = newValue }
  }
  /// 旁白里「按下」了药丸（鼠标并不在这儿：扇出后不能按「鼠标离开了」收回）
  var onPress: () -> Void {
    get { view.onPress }
    set { view.onPress = newValue }
  }
  /// 按住 ⌥ 拖：拖到哪了（全局坐标）、松手在哪
  var onDrag: (CGPoint) -> Void {
    get { view.onDrag }
    set { view.onDrag = newValue }
  }
  var onDrop: (CGPoint) -> Void {
    get { view.onDrop }
    set { view.onDrop = newValue }
  }
  /// 右键菜单
  var menu: () -> NSMenu? {
    get { view.menuProvider }
    set { view.menuProvider = newValue }
  }

  init() {
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.contentView = view
  }

  /// 摆位置、画色条。colors：没归档的便签各自的纸色下标，按顺序（多于 maxDashes 条的后面合成一道灰的）
  func update(
    frame: CGRect, edge: NoteDeckOptions.Edge, colors: [Int], options: NoteDeckOptions
  ) {
    var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    if options.overFullScreen { behavior.insert(.fullScreenAuxiliary) }
    panel.collectionBehavior = behavior
    panel.setFrame(frame, display: false)
    hidesPill = options.hidesPill
    view.draw(
      edge: edge, colors: colors, metrics: NoteDeckMetrics(scale: options.size.scale),
      sense: options.sense)
    view.setBodyShown(isShown && !hidesPill, animated: false)
  }

  /// 那叠展开时淡掉，收回后再出来
  func setShown(_ shown: Bool) {
    guard shown != isShown else { return }
    isShown = shown
    view.setBodyShown(shown && !hidesPill, animated: !Style.reduceMotion)
  }
}

/// 药丸的内容：一层 HUD 皮肤的圆角底 + 一道道色条，都是 CALayer
private final class PillView: NSView {
  var onEnter: (Bool) -> Void = { _ in }
  var onExit: () -> Void = {}
  var onPress: () -> Void = {}
  var onDrag: (CGPoint) -> Void = { _ in }
  var onDrop: (CGPoint) -> Void = { _ in }
  var menuProvider: () -> NSMenu? = { nil }

  private let body = CALayer()
  private var edge = NoteDeckOptions.Edge.right
  private var sense: CGFloat = 14
  /// 正按着 ⌥ 拖
  private var isDragging = false

  init() {
    super.init(frame: .zero)
    layer = CALayer()
    wantsLayer = true
    layer?.addSublayer(body)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityHelp("鼠标靠过来展开便签；按住 Option 拖动可以换边、换高度")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// 贴边 1 pt 画药丸；色条从上往下就是便签的顺序
  func draw(edge: NoteDeckOptions.Edge, colors: [Int], metrics: NoteDeckMetrics, sense: CGFloat) {
    self.edge = edge
    self.sense = sense
    setAccessibilityLabel("便签，\(colors.count) 条")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let width = metrics.pillWidth
    body.frame = CGRect(
      x: edge == .right ? bounds.width - width - 1 : 1, y: 0, width: width, height: bounds.height)
    for dash in body.sublayers ?? [] where dash.name == Self.dashName {
      dash.removeFromSuperlayer()
    }
    Style.HUD.applySkin(to: body, radius: width / 2)
    var dashes = colors.prefix(NoteDeckLayout.maxDashes).map {
      NotePaper.of(color: $0).brightStrip
    }
    if colors.count > NoteDeckLayout.maxDashes { dashes.append(Style.HUD.tertiaryText) }
    let pitch = metrics.dashHeight + metrics.dashGap
    let total = CGFloat(dashes.count) * pitch - metrics.dashGap
    for (index, color) in dashes.enumerated() {
      let dash = CALayer()
      dash.name = Self.dashName
      dash.backgroundColor = color.cgColor
      dash.cornerRadius = min(metrics.dashWidth, metrics.dashHeight) / 2
      dash.cornerCurve = .continuous
      dash.frame = CGRect(
        x: (width - metrics.dashWidth) / 2,
        y: ((bounds.height + total) / 2 - CGFloat(index) * pitch - metrics.dashHeight).rounded(),
        width: metrics.dashWidth, height: metrics.dashHeight)
      body.addSublayer(dash)
    }
    CATransaction.commit()
    updateTrackingAreas()
  }

  private static let dashName = "dash"

  /// 淡入 fadeIn（0.12 s easeOut）、淡出 fadeOut（0.10 s easeIn）：mac-whisker §4 的那一对
  func setBodyShown(_ shown: Bool, animated: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(shown ? Style.fadeIn : Style.fadeOut)
    CATransaction.setAnimationTimingFunction(
      CAMediaTimingFunction(name: shown ? .easeOut : .easeIn))
    body.opacity = shown ? 1 : 0
    CATransaction.commit()
  }

  // MARK: 鼠标

  /// 只感应贴边的那一条（宽 = 感应范围）。本 App 从不激活，所以 activeAlways
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    let width = min(sense, bounds.width)
    let strip = CGRect(
      x: edge == .right ? bounds.maxX - width : 0, y: 0, width: width, height: bounds.height)
    addTrackingArea(
      NSTrackingArea(rect: strip, options: [.activeAlways, .mouseEnteredAndExited], owner: self))
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseEntered(with event: NSEvent) {
    if !isDragging { onEnter(NSEvent.modifierFlags.contains(.option)) }
  }

  override func mouseExited(with event: NSEvent) {
    if !isDragging { onExit() }
  }

  /// 按住 ⌥ 按下 = 开始拖；直接点一下 = 扇出（鼠标本来就停在上面、进来那一下没扇出时）
  override func mouseDown(with event: NSEvent) {
    isDragging = event.modifierFlags.contains(.option)
    if !isDragging { onEnter(false) }
  }

  override func mouseDragged(with event: NSEvent) {
    if isDragging { onDrag(NSEvent.mouseLocation) }
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    isDragging = false
    onDrop(NSEvent.mouseLocation)
  }

  override func rightMouseDown(with event: NSEvent) {
    if let menu = menuProvider() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
  }

  // MARK: 旁白

  /// 旁白里「按下」= 扇出（键盘用户另有全局动作「新建便签」「全部便签」）。和鼠标进来分开报：这时鼠标不在药丸上
  override func accessibilityPerformPress() -> Bool {
    onPress()
    return true
  }
}
