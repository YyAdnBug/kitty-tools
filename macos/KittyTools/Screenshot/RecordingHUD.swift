// 录制 HUD（录屏第 2 批，mac-whisker §6 截图「录屏」；会话在 ScreenRecorder）：开录后接在录制条原来的位置（选区外，
// 同 SelectionView.toolbarPlacement、不给样式托盘留地方），**右边线对着录制条的右边线**（2026-10-12 视觉对齐：倒数、录制态
// 都比录制条窄，按中线摆的话 ✕ 和主圆钮三态来回漂；倒数没有圆钮，它的位置空着），整屏录制时在那块屏可见区底部居中、离底
// 24 pt；拖过的位置按屏记在内存里（这次运行有效，不存偏好）。摆好之后宽度再变（换状态、计时多一位、出橙字）一律右边线不动。
// - 倒数：[3 秒后开始] ｜ [✕ 取消]，数字 22 pt 圆体、每跳一个数 pop（0.85 → 1），点数字马上开始；
// - 录制中：[● 0:12] ｜ [✕ 放弃][■ 停止]：红点 8 pt systemRed（语义色「录制中」）呼吸 1 ↔ 0.45（同一表面唯一的 ambient，
//   只在录制态挂、HUD 一收就摘；放在 CALayer 上由渲染服务跑，不占主线程）；计时和菜单栏停止项同一个时钟
//   （ScreenRecorder.clock；按当前读数的位数留宽，到 10 分钟、1 小时各变宽一次、HUD 往左长），每秒变了的那几位数字滚过去
//   ——图层自己排（Shell/Ticker.swift），
//   **不用 numericText**：它每秒逐帧重画带模糊的字，独立小程序实测 13 pt 的这一行占 8–11% CPU（图层版 0.2%），
//   录多久占多久（2026-10-11 换的）；放弃要点两下（第一下「上膛」变红，2 s 内再点才放弃）；
//   停止是 28 pt 强调色实心圆 + ■（画法同录制条的 ●）。
//   计时和 ✕ 之间是只读的声音状态 [系统声音][麦克风]（录屏第 4 批：录制中改不了配置；开 = 强调色、关 = 再次文字色 + 斜杠，
//   两个都关不显示这段）；开录时的麦克风断开了，麦克风变 systemOrange + 斜杠。
// 录音（第 5 批，拍板 A1-a）是它的另一种形态（medium = .audio，会话在 AudioRecorder）：鼠标所在屏可见区底部居中、离底 24，
// 从底边长出来（pop bounce 0.18，同录制条的长出；窗口四周留 24 pt 透明边、用 HUDBar 自绘的阴影，长出时不被窗口边切掉），[● 0:42][电平] ｜ [⏸] ｜ [✕][■]：电平是最近 3 s 的竖条（每帧直接设值），
// 超过 −1 dB 的那根 systemOrange；开头 5 s 没听到声音时计时旁边出橙色「没听到声音」；暂停时红点换成暂停符号、计时和电平变灰。
// 录系统声音（第 6 批，来源是系统声音 / 两者，走录屏管线）不能暂停：⏸ 留在原位置灰（0.35），提示「录系统声音时不能暂停」；
// 「两者」录着时麦克风断开，「没听到声音」那个位置换成橙字「麦克风断开了」。
// 录音的待录态（手测反馈第 3 批，State.ready：按录音快捷键先出控制条、还没录）：[系统声音][麦克风] ｜ [✕ 关闭][● 开始]，
// 两个来源开关是录制条的 ToggleButton（同样的符号、配色、.replace 过渡和提示），读写录音来源的偏好（至少留一个），和
// 设置 › 录制「录音」的「来源」是同一个偏好；● 画法同录制条的开始钮；点了开始到真正录起来之间开关和 ● 置灰、✕ 还能点；
// 开始后同一个 HUD 原地换成录制态（右边线不动、往左长出计时和电平，红点 pop；■ 正好落在刚才 ● 的位置，换完的头一小段
// 不认 ■，免得双击 ● 刚开始就停了）。
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
    /// 待录（只有录音，手测反馈第 3 批）：控制条出来了、还没开始录
    case ready
    /// 录制中：已录几秒
    case recording(Int)
  }

  /// start：待录时的 ●；cancel：倒数时的取消、待录时的关闭；systemAudio / microphone：待录时的来源开关（HUD 自己写偏好，
  /// 不经 onClick，这两项只给 button(for:) 取按钮用）
  enum Item { case startNow, cancel, discard, stop, pause, start, systemAudio, microphone }

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

  /// 倒数的读数（SwiftUI 读它：数字 pop）
  @Observable final class Reading {
    var countdown = 0
  }

  var onClick: (Item) -> Void = { _ in }
  let panel: NSPanel
  /// 录屏还是录音的 HUD（录音第 5 批：没有倒数，多电平和暂停）
  let medium: ScreenRecorder.Medium
  private(set) var state: State
  /// 录音暂停着
  private(set) var isPaused = false
  private var discard = Discard()
  private let reading = Reading()
  private let stopTip: String
  private let startTip: String
  /// 倒数的 Esc 注册上了：✕ 的提示才写「（Esc）」
  private let escapes: Bool
  /// 倒数的读数是个按钮（点了马上开始），录制中的读数（红点 + 计时）只是显示
  private lazy var countdownButton = makeCountdownButton()
  private lazy var clock = makeClock()
  /// 计时：13 pt 圆体 semibold + 等宽数字，图层自己排（每秒只滚变了的那几位，文件头）
  private let clockText = TickerView()
  /// 计时留的宽度：跟着当前读数的位数走（applyClock）
  private lazy var clockWidth = clockText.widthAnchor.constraint(equalToConstant: 0)
  private static let clockFont: NSFont = {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 13) }
      ?? font
  }()
  /// 录制中的声音状态（只读）：这次录不录系统声音、麦克风（麦克风是开关开着且有授权）；两个都关时不显示
  private let systemAudio: Bool
  private let microphone: Bool
  private let systemIcon = SoundIcon()
  private let microphoneIcon = SoundIcon()
  private lazy var sound = makeSound()
  private let dot = Dot()
  /// 录音：电平、暂停钮、暂停时顶替红点的暂停符号、「没听到声音」
  private lazy var meter = LevelMeter()
  private lazy var pauseButton = barButton(
    NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停录音")!, tip: "暂停录音",
    label: "暂停录音", action: #selector(pauseClicked(_:)), size: CGSize(width: 32, height: 32))
  private lazy var pauseSeparator = barSeparator()
  private lazy var pauseMark = makePauseMark()
  private lazy var silence = makeSilence()
  private lazy var separator = barSeparator()
  /// 倒数时是「取消」，录制中是「放弃」
  private lazy var closeButton = barButton(
    NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消")!, tip: "取消",
    label: "取消", action: #selector(closeClicked(_:)), size: CGSize(width: 32, height: 32))
  private lazy var stopButton = makeRoundButton(
    "stop.fill", tip: stopTip, label: "停止并保存", action: #selector(stopClicked(_:)))
  /// 录音待录：来源开关（读写 defaults 里的 Prefs.audioRecordSource）和开始钮
  private let defaults: UserDefaults
  private lazy var systemButton = makeSourceButton { [unowned self] in
    "系统声音：\(AudioRecorder.Source(defaults).recordsSystem ? "开" : "关")"
  }
  /// 输入设备（名字、是不是蓝牙）每次现查、不记：控制条没有超时、能一直开着，这期间戴上蓝牙耳机换了系统输入，提示还写旧
  /// 设备、少了蓝牙那一句的话，开录前就不知道会录成通话音质（录制条的缓存只活一次框选）。只有进程里第一次查约 70 ms，
  /// 而且只在提示要弹出 / 读屏时才查，不在点击路径上
  private lazy var microphoneButton = makeSourceButton { [unowned self] in
    let input = RecordBar.currentInput()
    return RecordBar.microphoneTip(
      on: AudioRecorder.Source(defaults).recordsMicrophone, device: input?.name,
      bluetooth: input?.bluetooth ?? false)
  }
  private lazy var startButton = makeRoundButton(
    "circle.fill", tip: startTip, label: "开始录音", action: #selector(startRecordingClicked(_:)))
  /// 开关上画着的来源（别处改了偏好——设置 › 录制的「来源」——跟着重画；和偏好一样就不动，免得把点击的 .replace 过渡截断）
  private var shownSource: AudioRecorder.Source?
  private var sourceObserver: NSObjectProtocol?
  /// ■ 换到刚点过的 ● 那个位置上的时刻（待录原地换成录制态；录屏不倒数时 HUD 直接以录制态接在录制条的位置）：
  /// 之后的一小段不认 ■（ignoresStop）
  private var swappedAt: ContinuousClock.Instant?
  /// 右端主圆钮（● / ■）占的宽：和 ✕ 隔 4 + 圆钮 28。倒数没有圆钮，这一段空着（✕ 的位置三态不变）
  private static let roundSlot: CGFloat = 4 + 28
  /// 窗口比 HUD 四周大这么多（透明）。录音 24：从底边长出来时往下偏的 8 pt、弹簧过冲和 HUDBar 自绘的阴影都落在窗口里、
  /// 不被窗口边切掉（同常驻缩略图的留边）；录屏 0：只淡入不变形，窗口就是 HUD 那么大、用系统阴影
  private let margin: CGFloat
  /// 在哪块屏（拖过的位置按屏记）、那块屏的可见区（换状态变宽时夹回来）
  private var display: CGDirectDisplayID?
  private var visible: CGRect?
  /// 程序自己摆位置时不算拖
  private var isPlacing = false
  /// 这次运行里各屏拖到的位置（HUD 的右下角，全局坐标：各种宽度的形态都按右边线摆）：录屏、录音的 HUD 各记各的
  private static var dragged: [Spot: CGPoint] = [:]
  private struct Spot: Hashable {
    let display: CGDirectDisplayID
    let medium: ScreenRecorder.Medium
  }

  /// stopKey：录屏 / 录音快捷键（停止钮、录音待录时开始钮的提示里写它；没绑定 nil）；escapes：倒数的 Esc 注册上了；
  /// systemAudio / microphone：这次录不录（录屏录制中的声音状态）；medium：录屏还是录音（录音没有倒数，有待录）；
  /// pausable：录音能不能暂停（录系统声音时不能，⏸ 置灰；从待录开始的到时再 setPausable）；defaults：录音待录时的来源开关
  /// 读写哪个偏好域（单测 / 截图自检换成临时域）
  init(
    state: State, stopKey: String?, escapes: Bool = false, systemAudio: Bool = false,
    microphone: Bool = false, medium: ScreenRecorder.Medium = .screen, pausable: Bool = true,
    defaults: UserDefaults = .standard
  ) {
    self.state = state
    self.medium = medium
    stopTip = stopKey.map { "停止并保存（\($0)）" } ?? "停止并保存"
    startTip = stopKey.map { "开始录音（\($0)）" } ?? "开始录音"
    self.defaults = defaults
    self.escapes = escapes
    self.systemAudio = systemAudio
    self.microphone = microphone
    margin = medium == .audio ? 24 : 0
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
    // 没留边（录屏）用系统阴影（HUDBar 自绘的阴影出不了窗口）；留了边（录音）用 HUDBar 自己的，跟着长出动画一起缩放、淡入
    panel.hasShadow = margin == 0
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.isMovableByWindowBackground = true
    // 本 App 从不激活：不设的话按钮的提示（快捷键）永远不出来
    panel.allowsToolTipsWhenApplicationIsInactive = true
    let container = NSView()
    frame.origin = CGPoint(x: margin, y: margin)
    container.addSubview(self)
    panel.contentView = container
    panel.delegate = self
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(medium == .audio ? "录音控制" : "录屏控制")
    show(state, rebuilding: true)
    // 录屏不倒数：HUD 一建出来就是录制态、马上接在录制条的位置，■ 落在录制条上刚点过的 ● 那里（同录音的
    // 待录 → 录制，ignoresStop）
    if medium == .screen, case .recording = state { swappedAt = .now }
    if !pausable { setPausable(false) }
    // 待录时别处改了来源（设置 › 录制）：开关跟着重画，不然画的和按开始时读到的对不上
    if state == .ready {
      sourceObserver = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.showSource(AudioRecorder.Source(self.defaults), animated: false)
        }
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: 出现 / 消失

  /// 摆好位置、settle 淡入（录制条随遮罩收起了，HUD 在它原来的位置接上）；录音（整屏的摆法：底部居中）从底边长出来
  func present(region: CGRect, on screen: NSScreen, isFullScreen: Bool) {
    arrange(
      region: region, screen: screen.frame, visible: screen.visibleFrame,
      display: screen.displayID, isFullScreen: isFullScreen)
    panel.orderFrontRegardless()
    // 录音没有录制条可接：同录制条的长出（pop bounce 0.18、rise −8、scale 0.94），减弱动态效果时只淡入
    if medium == .audio { return grow(true, from: .bottom) }
    guard let layer,
      let fade = Style.Motion.settle.caAnimation(keyPath: "opacity") as? CABasicAnimation
    else { return }
    fade.fromValue = 0
    fade.toValue = 1
    layer.add(fade, forKey: "appear")
  }

  /// 只摆位置、不显示（present 的前半；单测直接调它：HUD 的窗口只建不显示）
  func arrange(
    region: CGRect, screen: CGRect, visible: CGRect, display: CGDirectDisplayID?,
    isFullScreen: Bool
  ) {
    self.display = display
    self.visible = visible
    let origin = Self.origin(
      size: frame.size, region: region, screen: screen, visible: visible,
      isFullScreen: isFullScreen,
      dragged: display.flatMap { Self.dragged[Spot(display: $0, medium: medium)] })
    place(CGRect(origin: origin, size: frame.size))
  }

  /// 立刻收（停止 / 放弃 / 取消那一刻，同边框和停止项）；红点的循环动画一起摘掉。从窗口里摘下来断开 HUD ↔ 窗口的
  /// 互相持有（panel 是 let、窗口经内容视图持有 HUD），不然每录一次漏一个窗口
  func close() {
    dot.stop()
    if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
    sourceObserver = nil
    panel.orderOut(nil)
    removeFromSuperview()
    panel.contentView = nil
  }

  /// HUD 在屏幕上的位置（全局坐标）：窗口去掉四周留的边
  var screenFrame: CGRect { panel.frame.insetBy(dx: margin, dy: margin) }

  // MARK: 状态

  /// 换状态：倒数 / 待录 → 录制换内容（宽度变了右边线不动、夹回可见区），同一种只换读数
  func update(_ next: State) {
    show(next, rebuilding: !Self.sameForm(next, state))
  }

  /// 同一种形态（倒数 / 待录 / 录制中，不看读数）：形态变了才重排内容
  private static func sameForm(_ one: State, _ other: State) -> Bool {
    switch (one, other) {
    case (.countdown, .countdown), (.ready, .ready), (.recording, .recording): true
    default: false
    }
  }

  private func show(_ next: State, rebuilding: Bool) {
    let wasReady = state == .ready
    state = next
    var widened = false
    switch next {
    case .countdown(let seconds):
      reading.countdown = seconds
      setAccessibilityValue("\(seconds) 秒后开始")
    case .ready:
      setAccessibilityValue("还没开始录")
    case .recording:
      // 计时是值，不逐秒播报
      widened = applyClock()
    }
    guard rebuilding else {
      // 计时多了一位（10:00、1:00:00）：HUD 变宽，右边线不动
      if widened { refit() }
      return
    }
    for view in stack.arrangedSubviews { view.removeFromSuperview() }
    let views: [NSView] =
      switch (next, medium) {
      case (.countdown, _): [countdownButton, separator, closeButton]
      case (.ready, _): [systemButton, microphoneButton, separator, closeButton, startButton]
      case (.recording, .audio):
        [clock, meter, separator, pauseButton, pauseSeparator, closeButton, stopButton]
      case (.recording, .screen):
        [clock] + (systemAudio || microphone ? [sound] : []) + [separator, closeButton, stopButton]
      }
    views.forEach(stack.addArrangedSubview)
    // 右端是强调色圆钮（● / ■）：多留一点边、和 ✕ 隔开一点（同录制条）。倒数没有圆钮，把它的位置空出来——
    // 右边线对齐之后，✕ 就和录制条、录制态的 ✕ 在同一个位置
    let round = !Self.sameForm(next, .countdown(0))
    stack.edgeInsets.right = round ? 6 : 6 + Self.roundSlot
    if round { stack.setCustomSpacing(4, after: closeButton) }
    discard = Discard()
    applyClose()
    if next == .ready { showSource(AudioRecorder.Source(defaults), animated: false) }
    refit()
    // 红点：录制态出现时 pop，之后呼吸
    if case .recording = next {
      dot.start()
      if wasReady { swappedAt = .now }
    } else {
      dot.stop()
    }
  }

  /// 量宽度；宽度变了**右边线不动**（✕ 和主圆钮留在原地，HUD 往左长 / 缩）、夹回可见区：换状态、计时多一位、
  /// 出「没听到声音」。还没摆过（init 里）只量
  private func refit() {
    let old = screenFrame
    fit()
    guard let visible else { return }
    place(
      CGRect(
        x: Self.x(width: frame.width, maxX: old.maxX, in: visible), y: old.minY,
        width: frame.width, height: frame.height))
  }

  /// 计时那一行，和旁白读的值（「已录 12 秒」，录音暂停着是「已暂停，已录 12 秒」）。数字往上滚（减弱动态效果时直接换）；
  /// 录音暂停时变灰——换颜色是整行重排、不滚。计时按当前读数的位数留宽（数字等宽：「0:00」「10:00」「1:00:00」各一档，
  /// 不按最长的「1:00:00」留——那样「0:12」右边空一大块）；返回留的宽度变没变（变了调用方 refit）
  @discardableResult private func applyClock() -> Bool {
    guard case .recording(let seconds) = state else { return false }
    let text = ScreenRecorder.clock(seconds)
    clockText.show(
      text, font: Self.clockFont, color: isPaused ? Style.HUD.secondaryText : Style.HUD.text,
      direction: Style.reduceMotion ? 0 : 1)
    setAccessibilityValue((isPaused ? "已暂停，" : "") + "已录 " + ScreenRecorder.spoken(seconds))
    let width = TickerView.measure(text, font: Self.clockFont).size.width
    guard clockWidth.constant != width else { return false }
    clockWidth.constant = width
    return true
  }

  // MARK: 录音

  /// 待录时的来源开关：按来源画（符号开 / 关形状不同，开 = 强调色，同录制条的开关）。只重画状态真变了的那个（第一次
  /// 两个都画）：ToggleButton.show 带动画时不看符号变没变，没变的那个也会缩下去再弹回来，看着像两个开关都动了；
  /// 关掉唯一开着的那个时两个都变，两个都放过渡
  private func showSource(_ source: AudioRecorder.Source, animated: Bool) {
    let shown = shownSource
    shownSource = source
    if shown?.recordsSystem != source.recordsSystem {
      systemButton.show(
        source.recordsSystem ? "speaker.wave.2.fill" : "speaker.slash.fill",
        on: source.recordsSystem, animated: animated)
    }
    if shown?.recordsMicrophone != source.recordsMicrophone {
      microphoneButton.show(
        source.recordsMicrophone ? "mic.fill" : "mic.slash.fill", on: source.recordsMicrophone,
        animated: animated)
    }
  }

  /// 点了来源开关：换图、写偏好（至少留一个，Source.toggling）、播报两个开关的新状态（不带设备名，不在点击路径上查设备）。
  /// 先换图再写偏好：写偏好会触发上面的观察者，它先到的话直接换图、.replace 过渡就没了
  @objc private func sourceClicked(_ sender: NSButton) {
    let next = AudioRecorder.Source(defaults).toggling(system: sender === systemButton)
    showSource(next, animated: true)
    defaults.set(next.rawValue, forKey: Prefs.audioRecordSource)
    Island.announce(
      "系统声音：\(next.recordsSystem ? "开" : "关")，麦克风：\(next.recordsMicrophone ? "开" : "关")")
  }

  /// 按了开始、还没真正录起来（等授权框、流还在开）：来源开关和 ● 置灰，✕ 还能点（会话当取消）
  func setStarting() {
    for button in [systemButton, microphoneButton, startButton] as [NSButton] {
      button.isEnabled = false
    }
  }

  /// 录音能不能暂停。录屏管线（录系统声音，SCRecordingOutput）没有暂停：⏸ 位置不变、置灰，提示为什么（隐藏的话 HUD 宽度
  /// 随来源变，也看不出为什么没有）
  func setPausable(_ pausable: Bool) {
    guard medium == .audio else { return }
    pauseButton.isEnabled = pausable
    pauseButton.toolTip = pausable ? "暂停录音" : "录系统声音时不能暂停"
  }

  /// 电平（最近 3 s，旧 → 新，dB）：每帧直接换（instant），减弱动态效果时照样更新
  func updateMeter(_ levels: [Float]) { meter.levels = levels }

  /// 暂停 / 继续：红点换成暂停符号（再次文字色）、红点不呼吸，计时变灰、电平冻结变灰；暂停钮换成 ▶「继续录音」
  func setPaused(_ paused: Bool) {
    guard medium == .audio, paused != isPaused else { return }
    isPaused = paused
    dot.isHidden = paused
    pauseMark.isHidden = !paused
    if paused { dot.stop() } else { dot.start() }
    meter.isPaused = paused
    let name = paused ? "继续录音" : "暂停录音"
    pauseButton.image = NSImage(
      systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: name)
    pauseButton.toolTip = name
    pauseButton.setAccessibilityLabel(name)
    applyClock()
  }

  /// 开头 5 s 没听到声音：计时旁边出橙色「没听到声音」（播报由 AudioRecorder 发一次），有声音了收起
  func setSilent(_ silent: Bool) {
    guard medium == .audio, silence.isHidden == silent else { return }
    silence.isHidden = !silent
    refit()
  }

  /// 开录时的麦克风断开了（录屏不停）：麦克风图标换成斜杠、变 systemOrange（.replace 过渡），提示和旁白说后面没有麦克风声音
  /// animated：截图自检传 false（不拍到过渡的半截）。录音 HUD（录音第 6 批「两者」）没有声音图标：计时后面「没听到声音」那个
  /// 位置换成橙字「麦克风断开了」，HUD 变宽（右边线不动；会话之后不再叫 setSilent）
  func microphoneLost(animated: Bool = true) {
    if medium == .audio {
      silence.stringValue = "麦克风断开了"
      silence.toolTip = "麦克风断开了，后面没有麦克风声音"
      silence.isHidden = false
      return refit()
    }
    guard microphone else { return }
    microphoneIcon.show(
      "mic.slash.fill", tint: .systemOrange, flat: true, label: "麦克风断开了，后面没有麦克风声音",
      animated: animated)
    microphoneIcon.toolTip = "麦克风断开了，后面没有麦克风声音"
  }

  /// ✕ 的样子：倒数时「取消」，待录时「关闭」（点一下就关，没有东西可放弃），录制中「放弃录制」（录音「放弃录音」），
  /// 上膛后变红「再点一次放弃」
  private func applyClose() {
    let armed = discard.isArmed(at: .now)
    let discardName = medium == .audio ? "放弃录音" : "放弃录制"
    let (label, tip): (String, String) =
      switch state {
      case .countdown: ("取消", escapes ? "取消（Esc）" : "取消")
      case .ready: ("关闭", "关闭")
      case .recording:
        armed ? ("再点一次放弃", "再点一次放弃，不会保存") : (discardName, discardName + "（不保存）")
      }
    closeButton.setAccessibilityLabel(label)
    closeButton.toolTip = tip
    closeButton.contentTintColor = armed ? Style.HUD.danger : Style.HUD.text
  }

  // MARK: 点击

  func button(for item: Item) -> NSButton? {
    switch item {
    case .startNow: countdownButton
    case .cancel, .discard: closeButton
    case .stop: stopButton
    case .pause: medium == .audio ? pauseButton : nil
    case .start: medium == .audio ? startButton : nil
    case .systemAudio: medium == .audio ? systemButton : nil
    case .microphone: medium == .audio ? microphoneButton : nil
    }
  }

  @objc private func startClicked(_ sender: NSButton) { onClick(.startNow) }
  @objc private func stopClicked(_ sender: NSButton) {
    guard !ignoresStop(at: .now) else { return }
    onClick(.stop)
  }
  @objc private func pauseClicked(_ sender: NSButton) { onClick(.pause) }

  /// 这一下点 ■ 不算（刚换上来的那一小段）。只挡 HUD 上的 ■：再按快捷键、菜单栏停止项照常停
  func ignoresStop(at now: ContinuousClock.Instant) -> Bool {
    Self.ignoresStop(at: now, swappedAt: swappedAt, doubleClick: NSEvent.doubleClickInterval)
  }

  /// ■ 换到了刚点过的 ● 的位置上（2026-10-12 视觉对齐起右边线不动：待录 → 录制原地换内容，● 的位置换上来的是 ■；
  /// 录屏不倒数时 HUD 接在录制条的位置，■ 落在录制条的 ● 上）：双击 ●、手快多点了一下，后一下会落在 ■ 上，刚开始录就
  /// 停了、存下一段零点几秒的文件。换上来后的这一小段不认 ■：系统的双击间隔（默认 0.5 s），最多 1 s——把双击调得很慢的人
  /// 也不至于好几秒停不了。没有 ● 可点的（按快捷键直接开始的录音、倒数完的录屏：swappedAt 是 nil）不挡。纯函数，配单测。
  /// 原来挡的是 ⏸（按中线摆时落在 ● 上的是它），现在它前面换上来的是电平，不用挡了
  nonisolated static func ignoresStop(
    at now: ContinuousClock.Instant, swappedAt: ContinuousClock.Instant?, doubleClick: TimeInterval
  ) -> Bool {
    swappedAt.map { now - $0 < .seconds(min(doubleClick, 1)) } ?? false
  }
  @objc private func startRecordingClicked(_ sender: NSButton) { onClick(.start) }

  /// 倒数时取消、待录时关闭；录制中第一下上膛（变红、提示、播报），2 s 内再点才放弃，过时恢复
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

  /// 把 HUD 摆到 rect（全局坐标），窗口四周再留 margin
  private func place(_ rect: CGRect) {
    isPlacing = true
    panel.setFrame(rect.insetBy(dx: -margin, dy: -margin), display: true)
    isPlacing = false
  }

  /// 用户拖过：记下这块屏上的位置（HUD 的右下角），这次运行里下次录这块屏就放这里（录屏、录音各记各的）
  func windowDidMove(_ notification: Notification) {
    guard !isPlacing, let display else { return }
    Self.dragged[Spot(display: display, medium: medium)] = CGPoint(
      x: screenFrame.maxX, y: screenFrame.minY)
  }

  // MARK: 摆位（纯函数，配单测）

  /// HUD 左下角放哪（全局坐标，取整）：这块屏这次运行里拖过就按拖到的地方（记的是右下角，夹进可见区）；整屏录制在可见区
  /// 底部居中、离底 24；选区录制接在录制条原来的位置——按录制条的宽 bar 走 SelectionView.toolbarPlacement（选区下方 10，
  /// 放不下放上方，再放不下放进选区底部；没有样式托盘，tray 传 0），HUD 的右边线对着录制条的右边线：HUD 比录制条窄，
  /// ✕ 和主圆钮就留在录制条上它们原来的位置
  static func origin(
    size: CGSize, region: CGRect, screen: CGRect, visible: CGRect, isFullScreen: Bool,
    dragged: CGPoint?, bar: CGFloat = RecordBar.width
  ) -> CGPoint {
    let origin: CGPoint
    if let dragged {
      origin = CGPoint(
        x: x(width: size.width, maxX: dragged.x, in: visible),
        y: min(max(dragged.y, visible.minY), visible.maxY - size.height))
    } else if isFullScreen {
      origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
    } else {
      let placed = SelectionView.toolbarPlacement(
        size: CGSize(width: bar, height: size.height),
        selection: region.offsetBy(dx: -screen.minX, dy: -screen.minY),
        in: CGRect(origin: .zero, size: screen.size), tray: 0
      ).origin
      origin = CGPoint(x: placed.x + bar - size.width + screen.minX, y: placed.y + screen.minY)
    }
    return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
  }

  /// 右边线在 maxX、左右夹进可见区时的左边 x（取整）：拖过的位置、宽度变了重摆共用（右边线不动）
  static func x(width: CGFloat, maxX: CGFloat, in visible: CGRect) -> CGFloat {
    min(max(maxX - width, visible.minX), visible.maxX - width).rounded()
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
    let host = PassiveHost(rootView: AnyView(CountdownText(reading: reading)))
    host.sizingOptions = [.intrinsicContentSize]
    host.translatesAutoresizingMaskIntoConstraints = false
    // 按钮自己没有内容尺寸（0，抗拉伸 250）：宿主不压扁，按钮跟着它的宽度走
    host.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.addSubview(host)
    // 宿主的宽取到整点：SwiftUI 排出来的读数不是整点宽，栏宽往上取整后多出来的零点几点会落在栏的右端——✕ 离右边线
    // 就比录制条、录制态的远一点（右边线对齐后三态的 ✕ 要在同一个位置）。
    // ponytail: 宽度按建的时候的读数定：倒数最多 5 秒、数字等宽，位数不会变；要支持两位数的倒数就在位数变了时重量
    let width = host.fittingSize.width.rounded(.up)
    NSLayoutConstraint.activate([
      host.widthAnchor.constraint(equalToConstant: width),
      host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      button.widthAnchor.constraint(equalTo: host.widthAnchor, constant: 16),
      button.heightAnchor.constraint(equalToConstant: 32),
    ])
    return button
  }

  /// 录制中的读数：红点 + 计时（录音另有暂停时顶替红点的暂停符号、计时后面的「没听到声音」，平时藏着、不占宽度）
  private func makeClock() -> NSView {
    // 宽度跟着当前读数的位数走（applyClock 设），高是一行
    clockWidth.isActive = true
    clockText.heightAnchor.constraint(
      equalToConstant: TickerView.measure("0:00", font: Self.clockFont).size.height
    ).isActive = true
    clockText.setAccessibilityElement(false)  // 读数在 HUD 的值里
    let row = NSStackView(
      views: medium == .audio ? [dot, pauseMark, clockText, silence] : [dot, clockText])
    row.spacing = 6
    row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
    row.detachesHiddenViews = true
    return row
  }

  /// 暂停时顶替红点的暂停符号（HUD 再次文字色，和红点同宽）
  private func makePauseMark() -> NSImageView {
    let mark = NSImageView(
      image: NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)!)
    mark.symbolConfiguration = .init(pointSize: 9, weight: .bold)
    mark.imageScaling = .scaleNone
    mark.contentTintColor = Style.HUD.secondaryText
    mark.isHidden = true
    mark.setAccessibilityElement(false)
    mark.widthAnchor.constraint(equalToConstant: 8).isActive = true
    mark.heightAnchor.constraint(equalToConstant: 12).isActive = true
    return mark
  }

  /// 「没听到声音」：11 pt systemOrange（配置 / 授权问题的语义色）
  private func makeSilence() -> NSTextField {
    let label = NSTextField(labelWithString: "没听到声音")
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .systemOrange
    label.isHidden = true
    return label
  }

  /// 声音状态：两个 13 pt 图标（开 = 强调色、关 = 再次文字色 + 斜杠），只读、提示「录制中不能开关声音」
  private func makeSound() -> NSView {
    let icons: [(SoundIcon, Bool, String, String, String)] = [
      (systemIcon, systemAudio, "speaker.wave.2.fill", "speaker.slash.fill", "系统声音"),
      (microphoneIcon, microphone, "mic.fill", "mic.slash.fill", "麦克风"),
    ]
    for (icon, on, symbol, off, name) in icons {
      icon.show(
        on ? symbol : off, tint: on ? Style.Shot.accent : Style.HUD.tertiaryText, flat: !on,
        label: "\(name)：\(on ? "开" : "关")", animated: false)
      icon.toolTip = "录制中不能开关声音"
    }
    let row = NSStackView(views: [systemIcon, microphoneIcon])
    row.spacing = 2
    row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
    return row
  }

  /// 待录时的一个来源开关（录制条的 ToggleButton：提示和旁白名字要显示时才问 describe）
  private func makeSourceButton(_ describe: @escaping () -> String) -> ToggleButton {
    let button = ToggleButton()
    button.target = self
    button.action = #selector(sourceClicked(_:))
    button.describe = describe
    return button
  }

  /// 停止 ■、待录时的开始 ●：28 pt 强调色实心圆 + 符号（画法同录制条的 ●、截图工具栏的拷贝钮），不出悬停底
  private func makeRoundButton(_ symbol: String, tip: String, label: String, action: Selector)
    -> BarButton
  {
    let button = barButton(
      NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, tip: tip,
      label: label, action: action, size: CGSize(width: 28, height: 28))
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

/// 录制中的一个声音状态图标（只读，不接鼠标：点在上面算拖 HUD）：13 pt 符号，换图走 .replace（减弱动态效果时直接换）。
/// 开着的分层画；带斜杠的（关着的、断开的）单色画（flat）——分层画时斜杠是主色、图标本身成了次级的灰，再乘上再次文字色
/// 就快看不见了（mac-whisker §3「图标」的例外，同录制条关着的开关）
private final class SoundIcon: NSImageView {
  private static let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 20, height: 32))
    imageScaling = .scaleNone
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    widthAnchor.constraint(equalToConstant: 20).isActive = true
    heightAnchor.constraint(equalToConstant: 32).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  /// 符号图自带的对齐内缩会让排版把它摆得偏离中线（同 BarButton）：frame 就是布局尺寸，图在里面居中
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

  func show(_ symbol: String, tint: NSColor, flat: Bool, label: String, animated: Bool) {
    guard let next = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else {
      return
    }
    symbolConfiguration = Self.base.applying(
      flat ? .preferringMonochrome() : .preferringHierarchical())
    if animated, !Style.reduceMotion, image != nil {
      setSymbolImage(next, contentTransition: .replace)
    } else {
      image = next
    }
    contentTintColor = tint
    setAccessibilityLabel(label)
  }
}

/// 录音的电平（mac-whisker §6 录音 HUD）：最近 3 s 的竖条（AudioRecorder.Levels 的 24 根，每根 2 pt、间隔 2，宽 96 × 高 20，
/// 竖直居中、右边最新），高度按 AudioRecorder.meterHeight（−50 dB 2 pt → 0 dB 20 pt）；最新一根 HUD 主文字色，往左渐到
/// 再次文字色，超过 −1 dB 的那根 systemOrange（快削波了）；暂停时冻结、整排再次文字色。每帧直接重画（instant），
/// 减弱动态效果时照样更新；不接鼠标（点在上面算拖 HUD），不进旁白
private final class LevelMeter: NSView {
  var levels: [Float] = [] { didSet { needsDisplay = true } }
  var isPaused = false { didSet { needsDisplay = true } }

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 96, height: 20))
    widthAnchor.constraint(equalToConstant: 96).isActive = true
    heightAnchor.constraint(equalToConstant: 20).isActive = true
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let count = AudioRecorder.Levels.bars
    // 刚开始不满 3 s：左边补最矮的
    let shown =
      Array(repeating: Float(-120), count: max(0, count - levels.count)) + levels.suffix(count)
    let (faint, strong) = (Style.HUD.tertiaryText.alphaComponent, Style.HUD.text.alphaComponent)
    for (index, level) in shown.enumerated() {
      let height = AudioRecorder.meterHeight(level, tallest: bounds.height)
      let rect = CGRect(
        x: bounds.maxX - 2 - CGFloat(count - 1 - index) * 4, y: (bounds.height - height) / 2,
        width: 2, height: height)
      let color =
        isPaused
        ? Style.HUD.tertiaryText
        : level > -1
          ? NSColor.systemOrange
          : Style.HUD.text.withAlphaComponent(
            faint + (strong - faint) * CGFloat(index) / CGFloat(count - 1))
      color.setFill()
      NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
  }
}

/// 只显示、不接鼠标的 SwiftUI 宿主（倒数的读数）：点击落到外面的按钮上（点倒数数字是按钮）。
/// 用 AnyView、不写成泛型子类：泛型的 NSHostingView 子类在 Release 优化时（EarlyPerfInliner 处理它的 deinit）让
/// Swift 6.2.4 编译器崩溃（2026-09-30 打 0.3.0 包时实测，Debug 不优化所以没事）；非泛型子类（ShelfHostingView）没问题
private final class PassiveHost: NSHostingView<AnyView> {
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
