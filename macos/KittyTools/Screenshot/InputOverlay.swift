// 录屏里显示用户的输入（手测反馈第 1 批，2026-10-01，PLAN §10「录屏与录音」的「手测反馈」；会话在 ScreenRecorder）：
// 录制条「显示点按」开着时，录屏期间盖在被录区域上的一块透明、不接鼠标的窗口，鼠标按下处画一个强调色的圈——系统的
// SCStreamConfiguration.showMouseClicks 画的圈又小又淡（用户手测：「鼠标点按效果明显一点」），还要求 BGRA、文件不带色彩标记，
// 所以自己画。按键提示（第 2 批，录制条「显示按键」）也在这块窗口里，见下面「按键」；两个开关任一开着就建窗口，各装各的监听。
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
// 按键（手测反馈第 2 批，用户：「按了哪些按键的话能提示出来，跟显示点按一样加个开关」）：被录区域底部居中的一颗深色胶囊
// （HUD 的颜色，底不透明：它要进视频，不靠窗口后模糊；高 46、SF Rounded semibold 24 pt），每按一个键往右追加一个记号：
// - 键名和快捷键页同一套（HotKey.display：修饰键 ⌃⌥⇧⌘ 在前，↩ ⇥ ⌫ ⎋ 方向键、F 键、按 ASCII 布局取的大写字母），⇧ 加字母是 ⇧A；
// - 按住不放的重复不追加，在最后一个记号后面写 ×n；放不下时从左边丢；
// - 停手 1.6 s 淡出并清空（Keys 是纯状态、时刻注入），再按键重新 pop 出来（减弱动态效果只淡入）；
// - 位置：离被录区域底边 32 pt；录制 HUD 落在被录区域里时（整屏录制：可见区底部居中）放在 HUD 上方 24 pt，不和它叠着。
// 按键来源：global 监听收别的 App 的 keyDown（要辅助功能授权，ScreenRecorder 开录前看过；系统的安全输入开着时收不到，
// 系统行为）；local 监听收本 App 的面板 / 截图遮罩当 key 时的，本 App 自己的密码框拿着键盘时不显示；本 App 的全局快捷键
// 被 Carbon 热键吃掉、两个监听都收不到，由 AppDelegate 在热键触发时直接调 showKey（停止录屏那一下不显示）；
// 本进程自己发的合成按键（粘贴回原 App 的 ⌘V、片段 {cursor} 的一串 ←、划词兜底的 ⌘C）global 监听收得到，但不是用户按的，
// 按事件源的进程号认出来、不显示（isSynthesized）。后两条按需实测 HotKeyMenuTests/keyMonitorsMissHotKeysAndSkipOwnKeys()。

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

  /// 按键提示的内容（纯状态，配单测；时刻是注入的）：一次按键一个记号，停手满 idle 就清空
  struct Keys: Equatable {
    struct Token: Equatable {
      /// 键名（⌘C、⇧A、↩）
      var name: String
      /// 连着按了几次（按住不放的重复算进来），大于 1 时后面写 ×n
      var count = 1
    }

    /// 停手这么久胶囊淡出、内容清空
    static let idle: Duration = .milliseconds(1600)
    private(set) var tokens: [Token] = []
    private var pressedAt: ContinuousClock.Instant?

    /// 按了一个键：停手满 idle 之后的第一下从头开始；按住不放的重复（isRepeat）不追加，记在最后一个记号的次数上
    mutating func press(_ name: String, isRepeat: Bool = false, at now: ContinuousClock.Instant) {
      if isIdle(at: now) { tokens = [] }
      pressedAt = now
      if isRepeat, let last = tokens.indices.last, tokens[last].name == name {
        tokens[last].count += 1
      } else {
        tokens.append(Token(name: name))
      }
    }

    func isIdle(at now: ContinuousClock.Instant) -> Bool {
      pressedAt.map { now - $0 >= Self.idle } ?? true
    }

    /// 停手满 idle 了就清空，返回 true（胶囊该淡出了）；这期间又按过键、或本来就空着返回 false
    mutating func expire(at now: ContinuousClock.Instant) -> Bool {
      guard !tokens.isEmpty, isIdle(at: now) else { return false }
      tokens = []
      return true
    }

    /// 放不下（width 量出来超过 limit）时从左边丢，至少留最后一个
    mutating func trim(to limit: CGFloat, width: ([Token]) -> CGFloat) {
      while tokens.count > 1, width(tokens) > limit { tokens.removeFirst() }
    }
  }

  /// 按键胶囊：高、文字左右的内边距、字号；离被录区域左右至少 keysMargin、最宽 keysMaxWidth
  nonisolated static let keysHeight: CGFloat = 46
  nonisolated static let keysPadding: CGFloat = 18
  private static let keysFontSize: CGFloat = 24
  nonisolated static let keysMargin: CGFloat = 16
  nonisolated static let keysMaxWidth: CGFloat = 640
  /// 胶囊图层的名字（和圈分开数；淡出中的旧胶囊也带着它）
  private static let keysName = "keys"

  let panel: NSPanel
  /// layer-hosting 视图的根图层：圈和按键胶囊都是它的子图层，空着时没有内容
  private let canvas = CALayer()
  /// 还按着的键 → 它的圈和按下的时刻
  private var pressed: [Int: (mark: CALayer, at: CFTimeInterval)] = [:]
  private var monitors: [Any] = []
  /// 画不画点按圈（显示点按）
  private let showsClicks: Bool
  /// 按键胶囊底边的 y（全局坐标，keysBottom 算的）；nil = 不显示按键
  private let keysBottom: CGFloat?
  private(set) var keys = Keys()
  /// 显示着的按键胶囊（正在淡出的不算：那时再按键是新的一颗）和里面的字
  private var keysBar: CALayer?
  private let keysLabel = CATextLayer()
  /// 等停手：每按一个键重新等 Keys.idle
  private var keysIdle: Task<Void, Never>?

  /// frame：被录的区域（点，AppKit 全局坐标；整屏录制就是那块屏）；clicks：画不画点按圈；keysBottom：给了就显示按键
  /// （胶囊底边的 y，全局坐标）。只建窗口，present 才露出来、装监听
  init(frame: CGRect, clicks: Bool = true, keysBottom: CGFloat? = nil) {
    showsClicks = clicks
    self.keysBottom = keysBottom
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

  /// 圈的个数（单测看图层有没有移除；按键胶囊不算）
  var markCount: Int { canvas.sublayers?.count { $0.name != Self.keysName } ?? 0 }

  /// 显示着的按键胶囊在窗口里的位置（没显示、正在淡出是 nil；单测和实录自检看）
  var keysBarFrame: CGRect? { keysBar?.frame }

  // MARK: 出现 / 消失

  /// 露出来、开始听鼠标 / 键盘（监听和 close 成对）
  func present() {
    panel.orderFrontRegardless()
    guard monitors.isEmpty else { return }
    if showsClicks { monitorClicks() }
    if keysBottom != nil { monitorKeys() }
  }

  private func monitorClicks() {
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
    monitors += [global, local].compactMap { $0 }
  }

  /// 键盘：global 监听收别的 App 的按键（要辅助功能授权，没授权时装了也收不到；别的 App 的密码框开着系统的安全输入时
  /// 同样收不到），local 监听收本 App 的窗口当 key 时的（面板、设置窗、截图遮罩；原样返回事件）——本 App 自己的密码框
  /// （设置里的密钥）拿着键盘时不显示。
  /// ponytail: 只按修饰键（flagsChanged）不显示：单按 ⌘ / ⇧ 没有内容，按住修饰键等另一个键的中间态也不用画；要做
  /// 「只按修饰键也提示」就再听 .flagsChanged、按前后两次的差找出按下的那个
  /// ponytail: 注册成全局快捷键的组合在派发前就被系统吃掉、NSEvent 监听收不到（本 App 的实测如此，由 AppDelegate 补；
  /// 系统的和别的 App 的——⌘空格、⌘⇥、别的启动器的热键——同一个机制，胶囊里没有）；要显示它们得换 CGEventTap
  /// （要另一项「输入监控」授权）
  private func monitorKeys() {
    let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated { self?.keyDown(event) }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        if !Self.isSecureInput(event.window?.firstResponder) { self?.keyDown(event) }
      }
      return event
    }
    monitors += [global, local].compactMap { $0 }
  }

  private func keyDown(_ event: NSEvent) {
    guard !Self.isSynthesized(event) else { return }
    showKey(
      HotKey(keyCode: event.keyCode, flags: event.modifierFlags).display, isRepeat: event.isARepeat)
  }

  /// 立刻收（停止 / 放弃 / 取消那一刻，同边框和 HUD）：卸监听、收窗口、清掉还在的圈和按键胶囊
  func close() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    panel.orderOut(nil)
    pressed = [:]
    keysIdle?.cancel()
    keysIdle = nil
    keysBar = nil
    keys = Keys()
    for layer in canvas.sublayers ?? [] { layer.removeFromSuperlayer() }
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

  // MARK: 按键

  /// 显示一个按下的键（name 如 ⌘C、⇧A、↩；监听和 AppDelegate 的热键路径都走这里，实录自检直接调）：追加到胶囊里
  /// （isRepeat：按住不放的重复，只加次数），放不下从左边丢；胶囊没显示着就 pop 出来（淡入 + 从 0.9 弹到 1，减弱动态效果
  /// 只淡入；animated false 直接摆到终态，截图自检），显示着的直接换字、改宽度（Whisker instant）。之后停手 Keys.idle
  /// 淡出并清空。没开显示按键时不做事
  func showKey(_ name: String, isRepeat: Bool = false, animated: Bool = true) {
    guard let keysBottom else { return }
    keys.press(name, isRepeat: isRepeat, at: .now)
    let region = panel.frame
    keys.trim(to: Self.keysWidthLimit(region) - 2 * Self.keysPadding) {
      Self.keysText($0).size().width
    }
    let text = Self.keysText(keys.tokens)
    let size = text.size()
    let frame = Self.keysFrame(
      width: ceil(size.width) + 2 * Self.keysPadding, bottom: keysBottom, in: region)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let appears = keysBar == nil
    let bar = keysBar ?? makeKeysBar()
    keysBar = bar
    bar.bounds.size = frame.size
    bar.position = Self.local(CGPoint(x: frame.midX, y: frame.midY), in: region)
    Self.applyKeysSkin(to: bar)
    keysLabel.string = text
    // 一行字在胶囊里居中（原点取整）。很窄的选区里一个记号就比胶囊放得下的宽（trim 至少留最后一个）：等比缩小到放得下，
    // 不画到胶囊和选区外面。带着变换不能设 frame，所以设 bounds + position
    let label = CGSize(width: ceil(size.width), height: ceil(size.height))
    let fit = Self.keysTextScale(textWidth: label.width, barWidth: frame.width)
    keysLabel.bounds = CGRect(origin: .zero, size: label)
    keysLabel.position = CGPoint(
      x: ((frame.width - label.width) / 2).rounded() + label.width / 2,
      y: ((frame.height - label.height) / 2).rounded() + label.height / 2)
    keysLabel.setAffineTransform(CGAffineTransform(scaleX: fit, y: fit))
    CATransaction.commit()
    if appears, animated {
      let reduced = Style.reduceMotion
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.duration = reduced ? 0.2 : Style.fadeIn
      fade.timingFunction = CAMediaTimingFunction(name: reduced ? .easeInEaseOut : .easeOut)
      bar.add(fade, forKey: "appear")
      if !reduced,
        let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
          as? CABasicAnimation
      {
        pop.fromValue = 0.9
        bar.add(pop, forKey: "pop")
      }
    }
    keysIdle?.cancel()
    keysIdle = Task { [weak self] in
      try? await Task.sleep(for: Keys.idle)
      guard let self, !Task.isCancelled, self.keys.expire(at: .now) else { return }
      self.hideKeys()
    }
  }

  /// 停手了：胶囊淡出（retract；减弱动态效果 0.2 s），放完移除图层。淡出中再按键是新的一颗（showKey 里先把旧的拿掉）
  private func hideKeys() {
    guard let bar = keysBar else { return }
    keysBar = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated { bar.removeFromSuperlayer() }
    }
    Self.fadeOut(
      bar, from: canvas.convertTime(CACurrentMediaTime(), from: nil), reduced: Style.reduceMotion,
      shownUntilThen: false)
    CATransaction.commit()
  }

  /// 新的一颗胶囊（字在里面）：先拿掉还在淡出的旧胶囊（字图层只有一个，跟着新的走），压在圈上面
  private func makeKeysBar() -> CALayer {
    for layer in canvas.sublayers ?? [] where layer.name == Self.keysName {
      layer.removeFromSuperlayer()
    }
    let bar = CALayer()
    bar.name = Self.keysName
    bar.zPosition = 1
    keysLabel.contentsScale = panel.backingScaleFactor
    bar.addSublayer(keysLabel)
    canvas.addSublayer(bar)
    return bar
  }

  /// 胶囊的皮肤（尺寸变了再调一次）：HUD 的描边和阴影，底换成不透明的——它要录进视频，下面没有模糊，半透明会透出
  /// 画面里的字。两端是半圆（circular：continuous 的圆角到了高的一半会被夹住，同顶部提示 Pill）
  private static func applyKeysSkin(to bar: CALayer) {
    Style.HUD.applySkin(to: bar, radius: bar.bounds.height / 2, curve: .circular)
    bar.backgroundColor = Style.HUD.solidFill.cgColor
    Style.HUD.applyShadow(
      to: bar,
      path: CGPath(
        roundedRect: bar.bounds, cornerWidth: bar.cornerRadius, cornerHeight: bar.cornerRadius,
        transform: nil))
  }

  /// 胶囊里的那行字（SF Rounded semibold，HUD 主文字色）：记号之间空一格；连着按了 n 次的后面跟「×n」（小一号、次要文字色）
  static func keysText(_ tokens: [Keys.Token]) -> NSAttributedString {
    let font = Annotation.rounded(size: keysFontSize, weight: .semibold)
    let name: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Style.HUD.text]
    let count: [NSAttributedString.Key: Any] = [
      .font: Annotation.rounded(size: keysFontSize - 6, weight: .semibold),
      .foregroundColor: Style.HUD.secondaryText,
    ]
    let string = NSMutableAttributedString()
    for (index, token) in tokens.enumerated() {
      if index > 0 { string.append(NSAttributedString(string: " ", attributes: name)) }
      string.append(NSAttributedString(string: token.name, attributes: name))
      if token.count > 1 {
        string.append(NSAttributedString(string: "×\(token.count)", attributes: count))
      }
    }
    return string
  }

  // MARK: 判断与换算（配单测）

  /// 按键胶囊最宽多少：被录区域左右各留 keysMargin，也不超过 keysMaxWidth（整屏时不拉成一长条）；再窄也有一个圆那么宽
  nonisolated static func keysWidthLimit(_ region: CGRect) -> CGFloat {
    max(keysHeight, min(region.width - 2 * keysMargin, keysMaxWidth))
  }

  /// 胶囊里的字缩到几倍（配单测）：放得下是 1；放不下就缩到两边各留 8 pt 刚好放下（缩小了的字在半圆端里放得下，
  /// 不用留足 keysPadding）。
  /// ponytail: 选区宽不到约 100 pt 时「⌘C」这样的记号就开始缩，64 pt（录屏的下限）时两个字符的记号缩到约 0.75 倍还认得出，
  /// 「⌃⌥⇧⌘F12」这样的长记号已经认不出；要认得出得让胶囊超出选区（录不进画面）或换行，真有人在这么窄的选区里录按键再做
  nonisolated static func keysTextScale(textWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
    min(1, max(0, barWidth - 2 * 8) / max(textWidth, 1))
  }

  /// 按键胶囊底边的 y（全局坐标）：离被录区域底边 32 pt；录制 HUD 落在被录区域里时——整屏录制（HUD 在可见区底部
  /// 居中、离底 24：胶囊在可见区底边上方 88 pt，也就让开了程序坞）、选区上下都放不下 HUD 时（HUD 放进选区底部）——
  /// 放在 HUD 上方 24 pt：HUD 不进画面，但在屏幕上会和胶囊叠在一起（胶囊的窗口层级更高，会盖住它）。
  /// ponytail: 只看 HUD 的默认位置（RecordingHUD.origin，宽按 200 估：只影响水平位置），用户把 HUD 拖到胶囊这里时照样
  /// 叠着；要让开就让 ScreenRecorder 在 HUD 挪动时把它的 frame 传过来
  static func keysBottom(region: CGRect, screen: CGRect, visible: CGRect, isFullScreen: Bool)
    -> CGFloat
  {
    let size = CGSize(width: 200, height: 40)
    let hud = CGRect(
      origin: RecordingHUD.origin(
        size: size, region: region, screen: screen, visible: visible, isFullScreen: isFullScreen,
        dragged: nil), size: size)
    return hud.intersects(region) ? hud.maxY + 24 : region.minY + 32
  }

  /// 按键胶囊的 frame（全局坐标，取整）：在被录区域里水平居中，宽不超过 keysWidthLimit；底边在 bottom，区域太矮时
  /// 往下夹进区域里（离顶至少 8 pt），连这也放不下就竖直居中
  nonisolated static func keysFrame(width: CGFloat, bottom: CGFloat, in region: CGRect) -> CGRect {
    let width = min(width, keysWidthLimit(region)).rounded(.up)
    let inset: CGFloat = 8
    let top = region.maxY - keysHeight - inset
    let y = top < region.minY + inset ? region.midY - keysHeight / 2 : min(bottom, top)
    return CGRect(
      x: (region.midX - width / 2).rounded(), y: y.rounded(), width: width, height: keysHeight)
  }

  /// 本进程自己发的按键（粘贴回原 App 的 ⌘V、片段 {cursor} 的一串 ←、划词兜底的 ⌘C：Paster / SelectionReader 经 CGEvent
  /// 发给前台 App，global 监听照样收得到）不是用户按的，不显示：事件带着发它的进程号，真键盘的是 0
  static func isSynthesized(_ event: NSEvent) -> Bool {
    event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
      == Int64(ProcessInfo.processInfo.processIdentifier)
  }

  /// 本 App 自己的密码框拿着键盘（设置里填密钥的 SecureField：第一响应者是它的字段编辑器，委托是那个 NSSecureTextField）：
  /// 这时的按键不显示。别的 App 的密码框由系统的安全输入挡住（global 监听收不到）
  static func isSecureInput(_ responder: NSResponder?) -> Bool {
    responder is NSSecureTextField || (responder as? NSTextView)?.delegate is NSSecureTextField
  }

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
