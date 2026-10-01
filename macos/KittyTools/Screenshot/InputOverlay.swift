// 录屏里显示用户的输入（手测反馈第 1 批，2026-10-01，PLAN §10「录屏与录音」的「手测反馈」；会话在 ScreenRecorder）：
// 录制条「显示点按」开着时，录屏期间盖在被录区域上的一块透明、不接鼠标的窗口，鼠标按下处画一个强调色的圈——系统的
// SCStreamConfiguration.showMouseClicks 画的圈又小又淡（用户手测：「鼠标点按效果明显一点」），还要求 BGRA、文件不带色彩标记，
// 所以自己画。第 2 批的按键提示也放这里。
// - 按下：光标处弹出直径 44 pt 的圆盘（填掺了 30% 白的强调色、0.5 不透明 + 2 pt 强调色描边，外面一圈 1.5 pt 白描边带
//   软阴影：和强调色相近、很亮、很暗的底上都分得出来），pop 从 0.5 倍弹到 1；右键 / 其它键是不填充的空心环（3 pt 描边），
//   形状就和左键分得开；
// - 按住拖动：圆盘跟着光标走（直接设位置，不带动画拖尾）；在被录区域外面按下的圈也照建（被窗口裁掉、看不见），
//   按住拖进区域里时跟着进来；
// - 松开：一圈涟漪从 44 扩到 72 pt 同时淡出、圆盘淡出（retract）；按下不到 0.2 s 就松开的（轻点）等满 0.2 s 再收，
//   免得刚弹出来就没了（涟漪到那时才出现）；快速连点每次按下都是新的一圈，互不吞；
// - 减弱动态效果：不弹不扩，按下直接显示、松开 0.2 s 淡出。
// 动画都加在 CALayer 上由渲染服务跑（没有 display link、没有定时器），放完图层就移除；空着时根图层没有内容，不占 backing store。
// 鼠标事件：别的 App 的走 global 监听（按下 / 拖动 / 松开都收得到，鼠标事件不需要辅助功能授权）；点在本 App 自己窗口上的走
// local 监听，只收按下、当成一次轻点（press 紧跟 release）——控件的跟踪循环会吞掉松开，local 监听收不到，圈会留在屏幕上；
// 而且只在会录进画面的自家窗口（录屏的白名单）上画，录不进去的（录制 HUD、常驻缩略图、长截图面板…）上不画。
// 窗口是普通 NSPanel 实例（mac-overlay-panel §1 不子类化）：无边框、不激活本 App、不接鼠标、永不当 key、无阴影、不进旁白，
// 所有桌面和全屏 App 上都在；层级 popUpMenu + 2：高过菜单和本 App 的截图遮罩（popUpMenu + 1），点菜单项时圈也在上面。
// 层级在状态栏以上，所以截图冻结帧（ScreenCapture.keptOwnWindows）按层级自动不收它，录屏的白名单
// （recordedOwnWindows）也不列它——它的窗口号由 ScreenRecorder 自己并进过滤器的例外（exceptedOwnWindows）才录得进画面。

import AppKit

final class InputOverlay {
  /// 圈的样子：左键实心圆盘，右键 / 其它键空心环（形状分开，不只靠颜色）
  enum Look: Equatable {
    case disc, ring

    var isFilled: Bool { self == .disc }
    var lineWidth: CGFloat { self == .disc ? 2 : 3 }
  }

  /// 圆盘直径、涟漪扩到的直径
  nonisolated static let diameter: CGFloat = 44
  nonisolated static let rippleDiameter: CGFloat = 72
  /// 圈外面那圈白描边的宽度
  private static let haloWidth: CGFloat = 1.5
  /// 圈至少显示这么久才收（轻点的按下和松开只隔十几毫秒）
  static let minimumHold: CFTimeInterval = 0.2

  let panel: NSPanel
  /// layer-hosting 视图的根图层：圈都是它的子图层，空着时没有内容
  private let canvas = CALayer()
  /// 还按着的键 → 它的圈和按下的时刻
  private var pressed: [Int: (mark: CALayer, at: CFTimeInterval)] = [:]
  private var monitors: [Any] = []

  /// frame：被录的区域（点，AppKit 全局坐标；整屏录制就是那块屏）。只建窗口，present 才露出来、装监听
  init(frame: CGRect) {
    panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.setAccessibilityElement(false)
    let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
    view.layer = canvas
    view.wantsLayer = true
    panel.contentView = view
  }

  /// 窗口号（ScreenRecorder 把它列进过滤器的例外）
  var windowID: CGWindowID? {
    panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
  }

  /// 圈的个数（单测看图层有没有移除）
  var markCount: Int { canvas.sublayers?.count ?? 0 }

  // MARK: 出现 / 消失

  /// 露出来、开始听鼠标（监听和 close 成对）
  func present() {
    panel.orderFrontRegardless()
    guard monitors.isEmpty else { return }
    let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(
      matching: downs.union([
        .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
        .otherMouseDragged,
      ])
    ) { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) }
    }
    // ponytail: 点在本 App 自己窗口上只画一次轻点，按住拖动（拖钉图、在翻译浮窗里拖选文字）圈不跟着走：控件 / 窗口拖动的
    // 跟踪循环自己取事件，local 监听收不到之后的拖动和松开。要跟就在按着期间轮询 NSEvent.pressedMouseButtons 和
    // mouseLocation（定时器），或换 CGEventTap（要另一项授权）
    let local = NSEvent.addLocalMonitorForEvents(matching: downs) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, Self.showsClick(onOwnWindow: event.windowNumber) else { return }
        self.press(event.buttonNumber, at: NSEvent.mouseLocation)
        self.release(event.buttonNumber)
      }
      return event
    }
    monitors = [global, local].compactMap { $0 }
  }

  /// 立刻收（停止 / 放弃 / 取消那一刻，同边框和 HUD）：卸监听、收窗口、清掉还在的圈
  func close() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    panel.orderOut(nil)
    pressed = [:]
    for mark in canvas.sublayers ?? [] { mark.removeFromSuperlayer() }
  }

  private func handle(_ event: NSEvent) {
    let button = event.buttonNumber
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      press(button, at: NSEvent.mouseLocation)
    case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      move(button, to: NSEvent.mouseLocation)
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      release(button)
    default:
      break
    }
  }

  // MARK: 圈

  /// 在 point（全局坐标）按下了 button（0 左键、1 右键、其余其它键）：弹出一个圈。窗口（被录区域）外面的按下也照建、
  /// 照记——圈被窗口裁掉、看不见，按住拖进区域里时才有圈跟着进来（从选区外拖一个文件进来），松开时照常移除。
  /// animated false：直接摆到终态（截图自检）
  func press(_ button: Int, at point: CGPoint, animated: Bool = true) {
    // 这个键上一次的松开没收到：先收掉，不让旧的圈留在屏幕上
    release(button, animated: animated)
    let mark = Self.mark(Self.look(button: button), scale: panel.backingScaleFactor)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mark.position = Self.local(point, in: panel.frame)
    canvas.addSublayer(mark)
    CATransaction.commit()
    pressed[button] = (mark, CACurrentMediaTime())
    guard animated, !Style.reduceMotion,
      let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
        as? CABasicAnimation
    else { return }
    pop.fromValue = 0.5
    mark.add(pop, forKey: "press")
  }

  /// 按着拖动：圈跟着光标走，不带动画（Whisker instant）
  func move(_ button: Int, to point: CGPoint) {
    guard let mark = pressed[button]?.mark else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mark.position = Self.local(point, in: panel.frame)
    CATransaction.commit()
  }

  /// 松开：涟漪扩出去同时淡出、圆盘淡出（按下还不到 minimumHold 的等满了再收：这段时间圆盘照旧显示，涟漪到点才出现），
  /// 放完移除图层。animated false：直接移除
  func release(_ button: Int, animated: Bool = true) {
    guard let (mark, pressedAt) = pressed.removeValue(forKey: button) else { return }
    guard animated else { return mark.removeFromSuperlayer() }
    let reduced = Style.reduceMotion
    // beginTime 按图层自己的时间算（圈和涟漪都是 canvas 的子图层）
    let now = CACurrentMediaTime()
    let begin = canvas.convertTime(now, from: nil) + max(0, pressedAt + Self.minimumHold - now)
    let ripple = reduced ? nil : Self.mark(.ring, lineWidth: 2, scale: mark.contentsScale)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated {
        mark.removeFromSuperlayer()
        ripple?.removeFromSuperlayer()
      }
    }
    Self.fadeOut(mark, from: begin, reduced: reduced, shownUntilThen: true)
    if let ripple {
      let grown = Self.rippleDiameter / Self.diameter
      ripple.position = mark.position
      ripple.transform = CATransform3DMakeScale(grown, grown, 1)
      canvas.insertSublayer(ripple, below: mark)
      // 涟漪在 begin 之前不露面（模型值透明、不往回填）：轻点时圆盘还在弹出来，外面不该先多一圈静止的环
      Self.fadeOut(ripple, from: begin, reduced: false, shownUntilThen: false)
      if let grow = Style.Motion.retract.caAnimation(keyPath: "transform.scale", reduced: false)
        as? CABasicAnimation
      {
        grow.fromValue = 1
        grow.beginTime = begin
        ripple.add(grow, forKey: "grow")
      }
    }
    CATransaction.commit()
  }

  /// begin 起从不透明淡出（retract；减弱动态效果 0.2 s）。begin 之前：shownUntilThen 保持不透明（往回填），否则看不见
  private static func fadeOut(
    _ layer: CALayer, from begin: CFTimeInterval, reduced: Bool, shownUntilThen: Bool
  ) {
    layer.opacity = 0
    guard
      let fade = Style.Motion.retract.caAnimation(keyPath: "opacity", reduced: reduced)
        as? CABasicAnimation
    else { return }
    fade.fromValue = 1
    fade.beginTime = begin
    if shownUntilThen { fade.fillMode = .backwards }
    layer.add(fade, forKey: "fade")
  }

  /// 一个圈（中心是光标，直径 diameter）：底下一圈 1.5 pt 白描边带软阴影，上面强调色的圈；实心的填掺了 30% 白的强调色、
  /// 0.5 不透明（掺白：深色底、和强调色一样的底上圆盘也比周围亮，和空心环分得开；白底上等于强调色 0.35）。颜色在创建时取
  /// （Shot.accent 固定不随深浅色）。lineWidth 不给就按样子（涟漪用 2 pt 的空心环）
  static func mark(_ look: Look, lineWidth: CGFloat? = nil, scale: CGFloat) -> CALayer {
    let width = lineWidth ?? look.lineWidth
    let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    let accent = Style.Shot.accent
    let mark = CALayer()
    mark.bounds = bounds
    let halo = CAShapeLayer()
    halo.path = CGPath(
      ellipseIn: bounds.insetBy(dx: -haloWidth / 2, dy: -haloWidth / 2), transform: nil)
    halo.fillColor = nil
    halo.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
    halo.lineWidth = haloWidth
    halo.shadowColor = NSColor.black.cgColor
    halo.shadowOpacity = 0.45
    halo.shadowRadius = 4
    halo.shadowOffset = CGSize(width: 0, height: -1)
    // 阴影只跟着圈走：shadowPath 给成圈那一环的轮廓（渲染服务不用离屏算），这一层自己也不带填充——圆盘的填充放在上面
    // 那层，不然阴影会从填充里透出来、把圆盘蒙上一层灰（layer.render(in:) 不认 shadowPath、按内容的透明度算阴影，实测）
    let band = width + haloWidth
    halo.shadowPath = CGPath(
      ellipseIn: bounds.insetBy(dx: (width - haloWidth) / 2, dy: (width - haloWidth) / 2),
      transform: nil
    ).copy(strokingWithWidth: band, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    let ring = CAShapeLayer()
    ring.path = CGPath(ellipseIn: bounds.insetBy(dx: width / 2, dy: width / 2), transform: nil)
    ring.fillColor =
      look.isFilled
      ? (accent.blended(withFraction: 0.3, of: .white) ?? accent).withAlphaComponent(0.5).cgColor
      : nil
    ring.strokeColor = accent.cgColor
    ring.lineWidth = width
    for layer in [halo, ring] {
      layer.frame = bounds
      layer.contentsScale = scale
      mark.addSublayer(layer)
    }
    mark.contentsScale = scale
    return mark
  }

  // MARK: 判断与换算（配单测）

  /// 哪个键画哪种圈：左键（0）圆盘，右键（1）和其它键空心环
  nonisolated static func look(button: Int) -> Look {
    button == 0 ? .disc : .ring
  }

  /// 全局坐标 → 窗口内坐标（原点左下；窗口外面的照算，圈被窗口裁掉）
  nonisolated static func local(_ point: CGPoint, in frame: CGRect) -> CGPoint {
    CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
  }

  /// 点在本 App 自己的窗口（窗口号 number）上画不画：只在会录进画面的窗口上画——问录屏用的同一份白名单
  /// （ScreenCapture.recordedOwnWindows：面板、设置窗、钉图和挂在它们上面的子窗口）。录不进去的（录制 HUD、菜单栏停止项、
  /// 常驻缩略图、截图遮罩、长截图面板、不挂在白名单窗口上的确认框）画面里那个位置没有它们，在那儿画圈只会凭空多一个圈
  /// （点 HUD 的停止时还会留在最后一帧里）
  static func showsClick(onOwnWindow number: Int) -> Bool {
    number > 0
      && ScreenCapture.recordedOwnWindows(ScreenCapture.ownWindows()).contains(CGWindowID(number))
  }
}
