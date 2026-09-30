// 录制 HUD（录屏第 2 批，mac-whisker §6 截图「录屏」；会话在 ScreenRecorder）：开录后贴在录制条原来的位置（选区外，
// 同 SelectionView.toolbarPlacement、不给样式托盘留地方），整屏录制时在那块屏可见区底部居中、离底 24 pt；拖过的位置按屏
// 记在内存里（这次运行有效，不存偏好）。
// - 倒数：[3 秒后开始] ｜ [✕ 取消]，数字 22 pt 圆体、每跳一个数 pop（0.85 → 1），点数字马上开始；
// - 录制中：[● 0:12] ｜ [✕ 放弃][■ 停止]：红点 8 pt systemRed（语义色「录制中」）呼吸 1 ↔ 0.45（同一表面唯一的 ambient，
//   只在录制态挂、HUD 一收就摘；放在 CALayer 上由渲染服务跑，不占主线程）；计时和菜单栏停止项同一个时钟
//   （ScreenRecorder.clock，numericText，按 h:mm:ss 留宽度不跳）；放弃要点两下（第一下「上膛」变红，2 s 内再点才放弃）；
//   停止是 28 pt 强调色实心圆 + ■（画法同录制条的 ●）。
// 皮肤是 HUDBar（15 毛玻璃 behindWindow，26 液态玻璃）。窗口是普通 NSPanel 实例（mac-overlay-panel §1 不子类化）：
// 状态栏层级（截图冻结帧、录制的白名单都不收它）、不激活本 App、永不当 key（无边框窗口本来就当不了）、按钮 acceptsFirstMouse、
// 能拖；所有桌面、全屏 App 上都显示。出现：settle 淡入（录制条随遮罩收起，HUD 在同一位置接上，不再「长出」一次）；
// 消失：停止 / 放弃 / 取消那一刻立刻收。减弱动态效果时数字直接换、红点不弹不呼吸。

import AppKit
import SwiftUI

final class RecordingHUD: HUDBar, NSWindowDelegate {
  enum State: Equatable {
    /// 倒数：还剩几秒
    case countdown(Int)
    /// 录制中：已录几秒
    case recording(Int)
  }

  enum Item { case startNow, cancel, discard, stop }

  /// 放弃要点两下（纯状态，配单测）：第一下「上膛」，window 之内再点才算放弃；过了时间恢复，下一下重新上膛
  struct Discard {
    static let window: Duration = .seconds(2)
    private(set) var armedAt: ContinuousClock.Instant?

    /// 点了一下：true = 放弃（上膛后 window 之内的第二下）
    mutating func press(at now: ContinuousClock.Instant) -> Bool {
      if isArmed(at: now) {
        armedAt = nil
        return true
      }
      armedAt = now
      return false
    }

    func isArmed(at now: ContinuousClock.Instant) -> Bool {
      armedAt.map { now - $0 < Self.window } ?? false
    }
  }

  /// 计时 / 倒数的读数（SwiftUI 读它：数字滚动、pop）
  @Observable final class Reading {
    var countdown = 0
    var seconds = 0
  }

  var onClick: (Item) -> Void = { _ in }
  let panel: NSPanel
  private(set) var state: State
  private var discard = Discard()
  private let reading = Reading()
  private let stopTip: String
  /// 倒数的 Esc 注册上了：✕ 的提示才写「（Esc）」
  private let escapes: Bool
  /// 倒数的读数是个按钮（点了马上开始），录制中的读数（红点 + 计时）只是显示
  private lazy var countdownButton = makeCountdownButton()
  private lazy var clock = makeClock()
  private let dot = Dot()
  private lazy var separator = barSeparator()
  /// 倒数时是「取消」，录制中是「放弃」
  private lazy var closeButton = barButton(
    NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消")!, tip: "取消",
    label: "取消", action: #selector(closeClicked(_:)), size: CGSize(width: 32, height: 32))
  private lazy var stopButton = makeStopButton()
  /// 在哪块屏（拖过的位置按屏记）、那块屏的可见区（换状态变宽时夹回来）
  private var display: CGDirectDisplayID?
  private var visible: CGRect?
  /// 程序自己摆位置时不算拖
  private var isPlacing = false
  /// 这次运行里各屏拖到的位置（底边中点，全局坐标）
  private static var dragged: [CGDirectDisplayID: CGPoint] = [:]

  /// stopKey：录屏快捷键（停止钮的提示里写它；没绑定 nil）；escapes：倒数的 Esc 注册上了
  init(state: State, stopKey: String?, escapes: Bool = false) {
    self.state = state
    stopTip = stopKey.map { "停止并保存（\($0)）" } ?? "停止并保存"
    self.escapes = escapes
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    super.init(radius: Style.Radius.panel, height: 40, blending: .behindWindow)
    // 状态栏层级：截图冻结帧（keptOwnWindows）、录制（recordedOwnWindows）都不收它；也不会被挪到菜单栏下面
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true  // 独立窗口用系统阴影（HUDBar 自绘的阴影出不了窗口）
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.isMovableByWindowBackground = true
    // 本 App 从不激活：不设的话按钮的提示（快捷键）永远不出来
    panel.allowsToolTipsWhenApplicationIsInactive = true
    panel.contentView = self
    panel.delegate = self
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("录屏控制")
    show(state, rebuilding: true)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: 出现 / 消失

  /// 摆好位置、settle 淡入（录制条随遮罩收起了，HUD 在它原来的位置接上）
  func present(region: CGRect, on screen: NSScreen, isFullScreen: Bool) {
    display = screen.displayID
    visible = screen.visibleFrame
    let origin = Self.origin(
      size: frame.size, region: region, screen: screen.frame, visible: screen.visibleFrame,
      isFullScreen: isFullScreen, dragged: display.flatMap { Self.dragged[$0] })
    place(CGRect(origin: origin, size: frame.size))
    panel.orderFrontRegardless()
    guard let layer,
      let fade = Style.Motion.settle.caAnimation(keyPath: "opacity") as? CABasicAnimation
    else { return }
    fade.fromValue = 0
    fade.toValue = 1
    layer.add(fade, forKey: "appear")
  }

  /// 立刻收（停止 / 放弃 / 取消那一刻，同边框和停止项）；红点的循环动画一起摘掉。拿掉 contentView 断开 HUD ↔ 窗口的
  /// 互相持有（panel 是 let、窗口持有内容视图），不然每录一次漏一个窗口
  func close() {
    dot.stop()
    panel.orderOut(nil)
    panel.contentView = nil
  }

  // MARK: 状态

  /// 换状态：倒数 ↔ 录制换内容（宽度变了按原来的水平中心摆、夹回可见区），同一种只换读数
  func update(_ next: State) {
    show(next, rebuilding: Self.isCountdown(next) != Self.isCountdown(state))
  }

  private static func isCountdown(_ state: State) -> Bool {
    if case .countdown = state { return true }
    return false
  }

  private func show(_ next: State, rebuilding: Bool) {
    state = next
    switch next {
    case .countdown(let seconds):
      reading.countdown = seconds
      setAccessibilityValue("\(seconds) 秒后开始")
    case .recording(let seconds):
      reading.seconds = seconds
      // 计时是值，不逐秒播报
      setAccessibilityValue("已录 " + ScreenRecorder.spoken(seconds))
    }
    guard rebuilding else { return }
    for view in stack.arrangedSubviews { view.removeFromSuperview() }
    let recording = !Self.isCountdown(next)
    let views =
      recording
      ? [clock, separator, closeButton, stopButton] : [countdownButton, separator, closeButton]
    views.forEach(stack.addArrangedSubview)
    stack.edgeInsets.right = recording ? 6 : 4
    if recording { stack.setCustomSpacing(4, after: closeButton) }
    discard = Discard()
    applyClose()
    let old = panel.frame
    fit()
    if panel.isVisible, let visible {
      place(
        CGRect(
          x: Self.x(width: frame.width, midX: old.midX, in: visible), y: old.minY,
          width: frame.width, height: frame.height))
    }
    // 红点：录制态出现时 pop，之后呼吸
    if recording { dot.start() } else { dot.stop() }
  }

  /// ✕ 的样子：倒数时「取消」，录制中「放弃录制」，上膛后变红「再点一次放弃」
  private func applyClose() {
    let armed = discard.isArmed(at: .now)
    let (label, tip): (String, String) =
      switch state {
      case .countdown: ("取消", escapes ? "取消（Esc）" : "取消")
      case .recording: armed ? ("再点一次放弃", "再点一次放弃，不会保存") : ("放弃录制", "放弃录制（不保存）")
      }
    closeButton.setAccessibilityLabel(label)
    closeButton.toolTip = tip
    closeButton.contentTintColor = armed ? .systemRed : Style.HUD.text
  }

  // MARK: 点击

  func button(for item: Item) -> NSButton? {
    switch item {
    case .startNow: countdownButton
    case .cancel, .discard: closeButton
    case .stop: stopButton
    }
  }

  @objc private func startClicked(_ sender: NSButton) { onClick(.startNow) }
  @objc private func stopClicked(_ sender: NSButton) { onClick(.stop) }

  /// 倒数时取消；录制中第一下上膛（变红、提示、播报），2 s 内再点才放弃，过时恢复
  @objc private func closeClicked(_ sender: NSButton) {
    guard case .recording = state else { return onClick(.cancel) }
    if discard.press(at: .now) { return onClick(.discard) }
    applyClose()
    Island.announce("再点一次放弃，不会保存")
    Task { [weak self] in
      try? await Task.sleep(for: Discard.window)
      guard let self, !self.discard.isArmed(at: .now) else { return }
      self.applyClose()
    }
  }

  // MARK: 拖动

  /// 按钮以外（读数、间隙、材质）都是拖的地方：点在它们上面算点在 HUD 本身（背景能拖、第一下就响应）
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit == nil || hit is NSButton ? hit : self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

  private func place(_ rect: CGRect) {
    isPlacing = true
    panel.setFrame(rect, display: true)
    isPlacing = false
  }

  /// 用户拖过：记下这块屏上的位置（底边中点），这次运行里下次录这块屏就放这里
  func windowDidMove(_ notification: Notification) {
    guard !isPlacing, let display else { return }
    Self.dragged[display] = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
  }

  // MARK: 摆位（纯函数，配单测）

  /// HUD 左下角放哪（全局坐标，取整）：这块屏这次运行里拖过就按拖到的地方（记的是底边中点，夹进可见区）；整屏录制在可见区
  /// 底部居中、离底 24；选区录制在录制条原来的位置（SelectionView.toolbarPlacement：选区下方 10，放不下放上方，再放不下放进
  /// 选区底部；录制 HUD 没有样式托盘，tray 传 0）
  static func origin(
    size: CGSize, region: CGRect, screen: CGRect, visible: CGRect, isFullScreen: Bool,
    dragged: CGPoint?
  ) -> CGPoint {
    let origin: CGPoint
    if let dragged {
      origin = CGPoint(
        x: x(width: size.width, midX: dragged.x, in: visible),
        y: min(max(dragged.y, visible.minY), visible.maxY - size.height))
    } else if isFullScreen {
      origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
    } else {
      let placed = SelectionView.toolbarPlacement(
        size: size, selection: region.offsetBy(dx: -screen.minX, dy: -screen.minY),
        in: CGRect(origin: .zero, size: screen.size), tray: 0
      ).origin
      origin = CGPoint(x: placed.x + screen.minX, y: placed.y + screen.minY)
    }
    return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
  }

  /// 水平居中在 midX、左右夹进可见区的左边 x（取整）：拖过的位置、倒数换录制态变宽后重摆共用
  static func x(width: CGFloat, midX: CGFloat, in visible: CGRect) -> CGFloat {
    min(max(midX - width / 2, visible.minX), visible.maxX - width).rounded()
  }

  // MARK: 零件

  /// 倒数的读数：数字 + 「秒后开始」，整块是按钮（悬停出底、点了马上开始）
  private func makeCountdownButton() -> BarButton {
    let button = BarButton(frame: .zero)
    button.title = ""
    button.imagePosition = .noImage
    button.isBordered = false
    button.refusesFirstResponder = true
    button.target = self
    button.action = #selector(startClicked(_:))
    button.toolTip = "马上开始"
    button.setAccessibilityLabel("马上开始")
    let host = PassiveHost(rootView: CountdownText(reading: reading))
    host.sizingOptions = [.intrinsicContentSize]
    host.translatesAutoresizingMaskIntoConstraints = false
    // 按钮自己没有内容尺寸（0，抗拉伸 250）：宿主不压扁，按钮跟着它的宽度走
    host.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.addSubview(host)
    NSLayoutConstraint.activate([
      host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      button.widthAnchor.constraint(equalTo: host.widthAnchor, constant: 16),
      button.heightAnchor.constraint(equalToConstant: 32),
    ])
    return button
  }

  /// 录制中的读数：红点 + 计时
  private func makeClock() -> NSView {
    let host = PassiveHost(rootView: ClockText(reading: reading))
    host.sizingOptions = [.intrinsicContentSize]
    let row = NSStackView(views: [dot, host])
    row.spacing = 6
    row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
    return row
  }

  /// 停止：28 pt 强调色实心圆 + ■（画法同录制条的 ●、截图工具栏的拷贝钮），不出悬停底
  private func makeStopButton() -> BarButton {
    let button = barButton(
      NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止并保存")!, tip: stopTip,
      label: "停止并保存", action: #selector(stopClicked(_:)), size: CGSize(width: 28, height: 28))
    button.showsHover = false
    button.layer?.backgroundColor = Style.Shot.accent.cgColor
    button.layer?.cornerRadius = 14
    button.contentTintColor = Style.Shot.onAccent
    button.symbolConfiguration = .init(pointSize: 10, weight: .bold)
    return button
  }
}

/// 录制中的红点（8 pt systemRed）：录制态出现时 pop，之后 opacity 1 ↔ 0.45 呼吸（1.2 s 往返，同菜单栏图标的呼吸）。
/// 动画在 CALayer 上（渲染服务跑，录几十分钟也不占主线程）；减弱动态效果时静止
private final class Dot: NSView {
  private let dot = CALayer()

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
    wantsLayer = true
    dot.frame = bounds
    dot.cornerRadius = 4
    layer?.addSublayer(dot)
    widthAnchor.constraint(equalToConstant: 8).isActive = true
    heightAnchor.constraint(equalToConstant: 8).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var wantsUpdateLayer: Bool { true }

  /// 在这里取色：系统红按视图自己的外观（HUD 永远深色）解析
  override func updateLayer() { dot.backgroundColor = NSColor.systemRed.cgColor }

  func start() {
    stop()
    guard !Style.reduceMotion,
      let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
        as? CABasicAnimation
    else { return }
    pop.fromValue = 0.3
    dot.add(pop, forKey: "pop")
    let breathe = CABasicAnimation(keyPath: "opacity")
    breathe.fromValue = 1
    breathe.toValue = 0.45
    breathe.duration = 0.6  // autoreverses：一个来回 1.2 s
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    breathe.beginTime = CACurrentMediaTime() + pop.duration
    dot.add(breathe, forKey: "breathe")
  }

  func stop() { dot.removeAllAnimations() }
}

/// 只显示、不接鼠标的 SwiftUI 宿主：点击落到外面的按钮 / HUD 上（读数上也能拖、点倒数数字是按钮）
private final class PassiveHost<Content: View>: NSHostingView<Content> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 倒数：22 pt 圆体数字（每跳一个数 pop 0.85 → 1）+ 12 pt「秒后开始」。减弱动态效果时数字直接换
private struct CountdownText: View {
  let reading: RecordingHUD.Reading
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// pop 曲线（Style.Motion.pop 的参数）
  private static let pop = Style.Motion.pop.parameters.map {
    Spring(duration: $0.duration, bounce: $0.bounce)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      let number = Text(String(reading.countdown))
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Color(nsColor: Style.HUD.text))
      if reduceMotion {
        number
      } else {
        number.keyframeAnimator(initialValue: 1.0, trigger: reading.countdown) { content, scale in
          content.scaleEffect(scale)
        } keyframes: { _ in
          KeyframeTrack {
            MoveKeyframe(0.85)
            SpringKeyframe(1, spring: Self.pop ?? Spring())
          }
        }
      }
      Text("秒后开始")
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: Style.HUD.secondaryText))
    }
    .accessibilityHidden(true)  // 读数在 HUD 的值里
  }
}

/// 计时：13 pt 圆体 semibold + 等宽数字，每秒 numericText；按 h:mm:ss 留宽度（一小时起变长也不跳）
private struct ClockText: View {
  let reading: RecordingHUD.Reading
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .leading) {
      Text(ScreenRecorder.clock(3600)).hidden()
      Text(ScreenRecorder.clock(reading.seconds))
        .contentTransition(.numericText(value: Double(reading.seconds)))
    }
    .font(.system(size: 13, weight: .semibold, design: .rounded))
    .monospacedDigit()
    .foregroundStyle(Color(nsColor: Style.HUD.text))
    .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: reading.seconds)
    .accessibilityHidden(true)
  }
}
