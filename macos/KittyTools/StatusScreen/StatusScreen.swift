// 状态屏的一次会话 + 给画面读的状态（PLAN §10「状态屏」）：进入（授权、拦截、每屏一张面板、保持唤醒、自动结束）、
// 退出判断（按住 esc 或按住退出提示两秒，ExitHold.swift）、挡下的触碰（计数、标题晃一下、退出提示浮出 3 秒）、
// 锁屏时让开（面板收掉、拦截暂停、屏幕常亮降成只防睡眠）、解锁 / 到时间 / 按住满了时退出。
// 定位是告示加防误触，不是安全措施：没有退出验证。
// 两层一起用：拦截（InputBlock）吞掉键盘鼠标；面板当 key 是为了安全输入开着时（拦截看不到按键）按键落在自己的面板上——
// 两边喂给同一个 handle(_:)。退出之后拦截留到按着的键松开才作废（最多 2 秒），不然按住的 esc 连发会落进前台 App。

import AppKit
import Observation

@Observable final class StatusScreen {
  enum ExitReason: Equatable { case held, autoEnd, unlocked, quit }

  // MARK: 给画面读的

  /// 正在显示（或刚结束、还在淡出）的状态；nil = 没进过
  private(set) var preset: StatusPreset?
  private(set) var startedAt = Date.now
  /// 进入后过了几秒（按分钟更新）
  private(set) var elapsed = 0
  /// 防残影：告示那一列此刻挪开了多少（每分钟换一次，drift(minute:)）
  private(set) var drift = CGSize.zero
  /// 每挡下一次触碰 +1：标题据此晃一下
  private(set) var shakes = 0
  /// 退出提示浮着
  private(set) var showsHint = false
  /// 正在按住退出：进度环 2 秒走满；取消就缩回
  private(set) var isHolding = false
  /// 截图自检摆「按住到一半」的进度环；正常使用是 0，环由画面自己做动画
  @ObservationIgnored let heldProgress: Double

  // MARK: AppDelegate 接上的

  @ObservationIgnored var island: Island?
  @ObservationIgnored var hotKeys: HotKeyCenter?
  /// 收起三块浮层
  @ObservationIgnored var hidePanels: () -> Void = {}
  /// 现在进不了的原因（正在录屏 / 录音：岛的标题和说明）；nil = 能进
  @ObservationIgnored var blocker: () -> (title: String, detail: String)? = { nil }
  /// 正在做一会儿就完的事（截图框选、读选中的文字）：不进、不提示
  @ObservationIgnored var isBusy: () -> Bool = { false }

  /// 在状态屏里（退出的那一刻就不算了，面板可能还在淡出、拦截可能还在等按着的键松开）
  @ObservationIgnored private(set) var isActive = false
  @ObservationIgnored private var block: InputBlock?
  @ObservationIgnored private var panels: [StatusScreenPanel] = []
  @ObservationIgnored private var hold = ExitHold()
  @ObservationIgnored private var touches = 0
  @ObservationIgnored private var isLocked = false
  /// 锁屏之后确实看到过「会话不在用户手里」（轮询兜底只在看到过之后才认「回来了」）
  @ObservationIgnored private var sawAway = false
  /// 进入时全局热键是不是开着（设置里正在录快捷键时本来就停着）：退出时原来开着才恢复
  @ObservationIgnored private var hotKeysWereActive = false
  @ObservationIgnored private var activity: NSObjectProtocol?
  @ObservationIgnored private var minuteTimer: Timer?
  @ObservationIgnored private var autoEndTimer: Timer?
  @ObservationIgnored private var holdTimer: Timer?
  @ObservationIgnored private var hintTimer: Timer?
  @ObservationIgnored private var lingerTimer: Timer?
  @ObservationIgnored private var keyTimer: Timer?
  @ObservationIgnored private var awayTimer: Timer?
  @ObservationIgnored private lazy var watcher = Watcher(screen: self)
  /// 鼠标上一次在哪、什么时候，和这一阵累计挪了多远
  @ObservationIgnored private var lastMouse: (point: CGPoint, at: ContinuousClock.Instant)?
  @ObservationIgnored private var travelled: CGFloat = 0

  /// 退出提示浮出来留多久
  static let hintDwell: TimeInterval = 3
  /// 鼠标一阵里累计挪过这么远就浮出退出提示
  static let mouseTravel: CGFloat = 40
  /// 退出之后拦截最多再留多久
  static let lingerLimit: TimeInterval = 2
  /// 退出提示胶囊的大小、离屏幕底边多远（画面按它摆，鼠标按住的命中也按它算）
  static let hintSize = CGSize(width: 148, height: 40)
  static let hintBottom: CGFloat = 56

  init() { heldProgress = 0 }

  /// 截图自检直接摆出某个样子（不建窗口、不拦输入）；正常使用就是 `StatusScreen()`
  init(
    showing preset: StatusPreset, startedAt: Date, elapsed: Int, showsHint: Bool = false,
    held: Double = 0
  ) {
    self.preset = preset
    self.startedAt = startedAt
    self.elapsed = elapsed
    self.showsHint = showsHint
    heldProgress = held
  }

  // MARK: 纯函数

  /// 时长：「不到 1 分钟」「5 分钟」「1 小时」「1 小时 23 分」
  static func span(_ seconds: Int) -> String {
    let minutes = seconds / 60
    if minutes < 1 { return "不到 1 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
  }

  /// 画面上那行小字：「14:02 开始 · 已 1 小时 23 分」（started 是格式化好的时间）
  static func footer(started: String, seconds: Int) -> String {
    "\(started) 开始 · " + (seconds < 60 ? "" : "已 ") + span(seconds)
  }

  /// 结束时刘海岛的详情：「持续 1 小时 23 分 · 挡下 12 次触碰」；自动结束的写「到 5 分钟自动结束」；没有触碰就不写后半句
  static func summary(_ reason: ExitReason, seconds: Int, touches: Int, autoEndMinutes: Int)
    -> String
  {
    let lasted =
      reason == .autoEnd
      ? "到 \(span(autoEndMinutes * 60))自动结束"
      : "持续" + (seconds < 60 ? "" : " ") + span(seconds)
    return touches > 0 ? "\(lasted) · 挡下 \(touches) 次触碰" : lasted
  }

  /// 防残影（纯函数）：第几分钟 → 告示那一列挪开多少。液晶屏长时间显示静止画面会留残影（Apple 的支持文档建议别让
  /// 静止画面一直停着），「屏幕常亮」的状态一挂就是几小时：每分钟挪几个点，横向 ±12、纵向 ±8 以内，
  /// 两个方向的周期不一样、轨迹不很快重复；第 0 分钟在正中。退出提示只出现 3 秒，不用挪
  static func drift(minute: Int) -> CGSize {
    CGSize(
      width: (12 * sin(Double(minute) * 0.9)).rounded(),
      height: (8 * sin(Double(minute) * 0.55)).rounded())
  }

  /// 退出提示在一块屏上的范围（全局坐标，原点左下）：底部居中
  static func hintFrame(in screen: CGRect) -> CGRect {
    CGRect(
      x: screen.midX - hintSize.width / 2, y: screen.minY + hintBottom, width: hintSize.width,
      height: hintSize.height)
  }

  /// 哪块屏的面板当 key：鼠标所在的那块，都不在就第一块
  static func keyIndex(mouse: CGPoint, screens: [CGRect]) -> Int {
    screens.firstIndex { NSMouseInRect(mouse, $0, false) } ?? 0
  }

  var footer: String {
    Self.footer(
      started: startedAt.formatted(date: .omitted, time: .shortened), seconds: elapsed)
  }

  // MARK: 进入

  /// 进入一个状态。没有辅助功能授权、已经在状态屏里、正在截图框选或录快捷键、正在录屏 / 录音、拦截建不起来时不进入
  func enter(_ preset: StatusPreset) {
    guard !isActive else { return }
    guard Permissions.isAccessibilityTrusted else {
      Permissions.requestAccessibility()
      island?.show("状态屏需要「辅助功能」授权", tone: .warning)
      return
    }
    // 框选遮罩要键盘；设置里正在录快捷键时热键停着、录制框等着按键：都不进（一会儿就完，不出提示）
    guard !isBusy(), !OverlayPanel.isSelectingRegion(in: NSApp.windows), hotKeys?.recording == nil
    else { return NSSound.beep() }
    // 录屏 / 录音中：控制条和停止项会被盖住、热键停着，退出前停不了；长截图的自动滚动还会被拦截吞掉（同录屏录音互斥的提示）
    if let blocker = blocker() {
      island?.show(blocker.title, detail: blocker.detail, tone: .warning)
      return
    }
    // 上一次退出后还在等按键松开的拦截：先作废，不叠两个
    endLinger()
    guard let block = InputBlock(onEvent: { [weak self] in self?.handle($0) }) else {
      island?.show("没能进入状态屏", detail: "键盘鼠标的拦截没建起来", tone: .error)
      return
    }
    self.block = block
    // 先把状态摆好再动别的：isActive 还是 false 时进来的事件走「已退出、等按键松开」那条路，会把刚建的拦截作废
    isActive = true
    isLocked = false
    sawAway = false
    hold = ExitHold()
    touches = 0
    lastMouse = nil
    travelled = 0
    showsHint = false
    isHolding = false
    startedAt = .now
    elapsed = 0
    drift = .zero
    self.preset = preset
    hidePanels()
    hotKeysWereActive = hotKeys.map { !$0.bindings.isEmpty } ?? false
    hotKeys?.suspend()
    arrangePanels()
    setActivity(preset.power)
    hideCursor()
    // 菜单跟踪、模态期间也要走：定时器都挂 common 模式
    minuteTimer = schedule(
      Timer(fire: startedAt + 60, interval: 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      })
    if preset.autoEndMinutes > 0 {
      let end = startedAt + TimeInterval(preset.autoEndMinutes * 60)
      autoEndTimer = schedule(
        Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.exit(.autoEnd) }
        })
    }
    watcher.start()
    Island.announce("状态屏：\(preset.title)。按住 Esc 两秒退出")
  }

  /// 保持唤醒换成 power 那一档（先起新的再还旧的，中间不留空档）
  private func setActivity(_ power: StatusPreset.Power) {
    let next = Self.activityOptions(power).map {
      ProcessInfo.processInfo.beginActivity(options: $0, reason: "状态屏")
    }
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = next
  }

  /// 鼠标指针藏到下一次挪动（进入时、退出提示收起时）。本 App 不在前台，系统不一定理会：藏不掉也不碍事
  private func hideCursor() { NSCursor.setHiddenUntilMouseMoves(true) }

  /// 电源：照常不拦；不睡眠只防系统闲置睡眠；屏幕常亮连显示器闲置熄灭一起防（同录屏）
  static func activityOptions(_ power: StatusPreset.Power) -> ProcessInfo.ActivityOptions? {
    switch power {
    case .normal: nil
    case .awake: [.idleSystemSleepDisabled, .userInitiated]
    case .displayOn: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated]
    }
  }

  /// 每块屏一张面板，按现在的屏幕摆（进入时、屏幕参数变了时）；没有哪张是 key 就让鼠标所在屏的那张当
  fileprivate func arrangePanels() {
    // 锁着屏时面板收着，不重排：解锁就结束了
    guard isActive, !isLocked else { return }
    let screens = NSScreen.screens.map(\.frame)
    while panels.count > screens.count { panels.removeLast().dismiss(fading: false) }
    for (index, frame) in screens.enumerated() {
      if index < panels.count {
        panels[index].setFrame(frame, display: true)
      } else {
        let panel = StatusScreenPanel(frame: frame, session: self)
        panel.onKey = { [weak self] in self?.handle($0) }
        panel.onMouseMoved = { [weak self] in self?.mouseMoved() }
        panel.onResignKey = { [weak self] in self?.panelResignedKey() }
        panels.append(panel)
        panel.present(fading: !Style.reduceMotion)
      }
    }
    takeKey()
  }

  /// 安全输入开着时按键靠 key 面板接：key 被别的窗口拿走了就拿回来（只 makeKey，永远不激活本 App）
  private func takeKey() {
    guard isActive, !isLocked, !panels.contains(where: \.isKeyWindow) else { return }
    let index = Self.keyIndex(mouse: NSEvent.mouseLocation, screens: panels.map(\.frame))
    if panels.indices.contains(index) { panels[index].makeKey() }
  }

  /// key 面板丢了 key（前台 App 弹了窗、别的窗口抢走）：稍后拿回来。安全输入开着时拦截看不到键盘，不能等「下一次触碰」。
  /// 隔 0.3 秒、一次只排一个：碰上一直抢 key 的窗口也不会转圈
  private func panelResignedKey() {
    guard isActive, !isLocked, keyTimer == nil else { return }
    keyTimer = schedule(
      Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.keyTimer = nil
          self?.takeKey()
        }
      })
  }

  // MARK: 事件

  /// 拦截和 key 面板的按键都喂到这里
  func handle(_ event: InputBlock.Event) {
    let now = ContinuousClock.now
    guard isActive else {
      // 已经退出、拦截还留着：只等按着的键松开
      _ = hold.handle(event, at: now)
      if !hold.isAnythingDown(at: now) { endLinger() }
      return
    }
    // 锁着屏：拦截暂停、面板收着，不该有事件；有也不理
    guard !isLocked else { return }
    let hints = showsHint ? panels.map { Self.hintFrame(in: $0.frame).insetBy(dx: -8, dy: -8) } : []
    let touched = hold.handle(event, at: now, hints: hints)
    syncHold()
    guard touched else { return }
    touches += 1
    shakes += 1
    revealHint()
    takeKey()
  }

  /// 面板报鼠标挪了：一阵里（中间停不超过 1 秒）累计超过 mouseTravel 就浮出退出提示。按位置算距离，同一下挪动报两次不重复算
  private func mouseMoved() {
    guard isActive, !isLocked else { return }
    let (point, now) = (NSEvent.mouseLocation, ContinuousClock.now)
    if let lastMouse, now - lastMouse.at < .seconds(1) {
      travelled += hypot(point.x - lastMouse.point.x, point.y - lastMouse.point.y)
    } else {
      travelled = 0
    }
    lastMouse = (point, now)
    guard travelled > Self.mouseTravel else { return }
    travelled = 0
    revealHint()
    takeKey()
  }

  /// 退出判断变了（开始按住 / 取消）：进度环跟上，起 / 撤到点的定时器
  private func syncHold() {
    let holding = hold.holding != nil
    guard holding != isHolding else { return }
    isHolding = holding
    holdTimer?.invalidate()
    holdTimer = nil
    if holding { scheduleHoldEnd(after: ExitHold.duration) }
    // 开始：提示（开着的话）连同进度环一起出来；取消：再留一会儿，看得见环缩回去
    revealHint()
  }

  private func scheduleHoldEnd(after rest: Duration) {
    let seconds = Double(rest.components.seconds) + Double(rest.components.attoseconds) / 1e18
    holdTimer = schedule(
      Timer(timeInterval: max(0, seconds), repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.isActive, let rest = self.hold.remaining(at: .now) else { return }
          if rest <= .zero { self.exit(.held) } else { self.scheduleHoldEnd(after: rest) }
        }
      })
  }

  /// 退出提示浮出 hintDwell 秒（设置里关了就永远不出现，只剩按住 esc）；按住期间到点不收
  private func revealHint() {
    guard UserDefaults.standard.bool(forKey: Prefs.statusScreenExitHint) else { return }
    showsHint = true
    hintTimer?.invalidate()
    hintTimer = schedule(
      Timer(timeInterval: Self.hintDwell, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, !self.isHolding else { return }
          self.showsHint = false
          self.hideCursor()
        }
      })
  }

  /// 每分钟：更新「已经多久」、告示挪个位置（防残影），顺手确认拦截还开着（系统停用它的通知万一没来）
  private func tick() {
    elapsed = Int(Date.now.timeIntervalSince(startedAt))
    drift = Self.drift(minute: elapsed / 60)
    block?.ensureEnabled()
  }

  private func schedule(_ timer: Timer) -> Timer {
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  // MARK: 锁屏

  /// 锁屏、会话切走：不拦输入（登录窗口要能用），正在进行的按住取消，面板收掉（层级很高，别盖住锁屏界面；锁着屏告示
  /// 本来也看不到）。保持唤醒照旧，只是「屏幕常亮」降成只防睡眠：不然锁屏界面会一直亮着
  fileprivate func locked() {
    guard isActive, !isLocked else { return }
    isLocked = true
    block?.pause()
    hold.reset()
    syncHold()
    hintTimer?.invalidate()
    showsHint = false
    lastMouse = nil
    travelled = 0
    for panel in panels { panel.orderOut(nil) }
    if preset?.power == .displayOn { setActivity(.awake) }
    // 解锁的通知万一没到（面板收着，没有别的路能退出）：每 2 秒看一眼会话状态。只在确实看到过「不在用户手里」之后
    // 才认「回来了」——读不到状态的系统上就只靠通知
    sawAway = InputBlock.isSessionAway
    awayTimer?.invalidate()
    awayTimer = schedule(
      Timer(timeInterval: 2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.isActive, self.isLocked else { return }
          if InputBlock.isSessionAway {
            self.sawAway = true
          } else if self.sawAway {
            self.exit(.unlocked)
          }
        }
      })
  }

  /// 解锁回来：自动结束（Z9）
  fileprivate func unlocked() { exit(.unlocked) }

  // MARK: 退出

  func exit(_ reason: ExitReason) {
    guard isActive, let preset else { return }
    isActive = false
    let seconds = Int(Date.now.timeIntervalSince(startedAt))
    for timer in [minuteTimer, autoEndTimer, holdTimer, hintTimer, keyTimer, awayTimer] {
      timer?.invalidate()
    }
    (minuteTimer, autoEndTimer, holdTimer, hintTimer, keyTimer, awayTimer) =
      (nil, nil, nil, nil, nil, nil)
    watcher.stop()
    setActivity(.normal)
    for panel in panels { panel.dismiss(fading: reason != .quit && !Style.reduceMotion) }
    panels = []
    if hotKeysWereActive { hotKeys?.reload() }
    // 按着的键（按住退出的 esc / 左键）还没松：拦截留到松开，最多 lingerLimit 秒；App 要退出、没有键按着就当场作废
    if reason == .quit || !hold.isAnythingDown(at: .now) {
      endLinger()
    } else {
      lingerTimer = schedule(
        Timer(timeInterval: Self.lingerLimit, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.endLinger() }
        })
    }
    guard reason != .quit else { return }
    island?.show(
      "状态屏已结束",
      detail: Self.summary(
        reason, seconds: seconds, touches: touches, autoEndMinutes: preset.autoEndMinutes),
      tone: .info, symbol: HotKeyAction.statusScreen.symbol)
  }

  /// 作废拦截（退出后等到按键松开、等满了、App 退出、又要进入时）
  private func endLinger() {
    lingerTimer?.invalidate()
    lingerTimer = nil
    block?.invalidate()
    block = nil
  }
}

/// 锁屏 / 解锁 / 屏幕参数变化的通知接收者（selector 形式，同 HotKeyCenter 的 MenuTracking：@objc 方法按默认的 MainActor 隔离）。
/// 锁屏那两条是分布式通知：本 App 从不激活，AppKit 会把不要求立即送达的分布式通知攒着，所以注册成 deliverImmediately
private final class Watcher: NSObject {
  weak var screen: StatusScreen?

  init(screen: StatusScreen) { self.screen = screen }

  func start() {
    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(
      self, selector: #selector(locked), name: .init("com.apple.screenIsLocked"), object: nil,
      suspensionBehavior: .deliverImmediately)
    distributed.addObserver(
      self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"), object: nil,
      suspensionBehavior: .deliverImmediately)
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(
      self, selector: #selector(locked), name: NSWorkspace.sessionDidResignActiveNotification,
      object: nil)
    workspace.addObserver(
      self, selector: #selector(unlocked), name: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
  }

  func stop() {
    DistributedNotificationCenter.default().removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func locked(_ note: Notification) { screen?.locked() }
  @objc private func unlocked(_ note: Notification) { screen?.unlocked() }
  @objc private func screensChanged(_ note: Notification) { screen?.arrangePanels() }
}
