// 触控板手势插件（issue #59 第 2 批，拍板页 https://claude.ai/artifact/YZGddAG3tNeKwEHBQwaLhg「全部按推荐」，
// PLAN §10「触控板手势」）：三到五根手指轻点、双击、长按，单指在四个角轻点、双击（2026-11-28），做设置里给它们绑的全局动作或启动器命令。
// `Shell/Touchpad` 的一个订阅者（和启动台的捏合共用一路触点，macOS 15 上也能用）：插件添加着、至少有一种绑了此刻用得上的东西
// 才订，不然退订（apply：启动时、偏好变了时 AppDelegate 调，没变不动）。
// 框架线程上每帧交给 Mutex 里的识别器（GestureTracker：每个设备一个 FingerGesture），认出一下、而且这种手指数（这个角）绑了东西才
// DispatchQueue.main.async 回主线程——收帧和派回去的闭包都在 nonisolated 的静态函数里建（G1：工程默认 MainActor 隔离，在主线程
// 上下文里建的闭包到了框架线程上一执行就 trap），框架线程上不碰主线程状态（mac-native §3）。
// 主线程上轻点过一遍 TapDispatch（这种手指数没绑双击就当场算轻点，拍板 B1；绑了就等 0.29 s 看有没有第二下）。真的去做（快捷键页
// 「在这些 App 里停用」、状态屏、正在录快捷键）由 AppDelegate 的 perform 管。Touchpad 重新枚举设备之后（醒来、插拔）换一个新的
// 识别器、丢掉在等的那一下。
// 角落的一下**让给系统的点按**（2026-11-28 角落拍板）：开着「轻点来点按」时系统可能把它当成一次点按，拇指在下面两个角快快按下去一下
// 也像轻点；那次点按我们吞不掉（不建事件拦截、不要辅助功能），所以这一下不做。绑了角落时挂着鼠标按下的全局 + 本地监听（只记时刻，
// 本地的原样放过），主线程收到角落的一下后等 ClickYield.after 再看前后有没有鼠标按下（ClickYield.coincides），有就扔掉、连这个角
// 在等的第一下一起作废，没有才过 TapDispatch。

import AppKit
import Foundation
import Synchronization

/// 框架线程上的那一半：每个设备一个识别器（Mutex 里），认出一下、这种手指数（这个角）要听才交给 `onEvent`。
/// **必须 `nonisolated`**（G1，同 PinchTracker）
nonisolated final class GestureTracker: Sendable {
  private let gestures = Mutex<[UInt: FingerGesture]>([:])
  /// 哪几种手指数绑了轻点或双击、绑了长按
  private let taps: Set<Int>
  private let holds: Set<Int>
  /// 哪几个角绑了轻点或双击
  private let corners: Set<FingerGesture.Corner>
  /// 设备、认出的那一下、那一帧的时间
  let onEvent: @Sendable (UInt, FingerGesture.Event, Double) -> Void

  init(
    taps: Set<Int>, holds: Set<Int>, corners: Set<FingerGesture.Corner>,
    onEvent: @escaping @Sendable (UInt, FingerGesture.Event, Double) -> Void
  ) {
    self.taps = taps
    self.holds = holds
    self.corners = corners
    self.onEvent = onEvent
  }

  func feed(device: UInt, frame: TouchFrame) {
    let event = gestures.withLock { table -> FingerGesture.Event? in
      var gesture = table[device] ?? FingerGesture()
      let event = gesture.update(frame.touches, at: frame.time)
      table[device] = gesture.idle ? nil : gesture
      return event
    }
    guard let event else { return }
    let wanted =
      switch event {
      case .tap(let fingers): taps.contains(fingers)
      case .hold(let fingers): holds.contains(fingers)
      case .corner(let corner): corners.contains(corner)
      }
    if wanted { onEvent(device, event, frame.time) }
  }
}

/// 主线程上一下轻点怎么办（他的 handleTap；纯的，时间从外面给）
struct TapDispatch {
  enum Step: Equatable {
    case fire(TrackpadGesture)
    /// 绑了双击：等 TapSequence.interval 再 expire
    case wait(TapSequence.Pending)
    case none
  }

  private var sequence = TapSequence()

  mutating func tap(
    device: UInt, source: TrackpadGesture.Source, at time: Double,
    bound: (TrackpadGesture) -> Bool
  ) -> Step {
    let single = TrackpadGesture(source, .tap)
    let double = TrackpadGesture(source, .doubleTap)
    guard bound(double) else { return bound(single) ? .fire(single) : .none }
    guard let pending = sequence.tap(.init(device: device, source: source), at: time) else {
      return .fire(double)
    }
    return .wait(pending)
  }

  /// 等够了：第一下没凑成双击就当轻点（轻点没绑就什么都不做）
  mutating func expire(_ pending: TapSequence.Pending, bound: (TrackpadGesture) -> Bool)
    -> TrackpadGesture?
  {
    guard sequence.takeSingle(pending) else { return nil }
    let single = TrackpadGesture(pending.key.source, .tap)
    return bound(single) ? single : nil
  }

  /// 这个设备上这一种在等的第一下作废（角落的一下让给了点按：前后两下里有一下是点按，就都不算）
  mutating func cancel(device: UInt, source: TrackpadGesture.Source) {
    sequence.cancel(.init(device: device, source: source))
  }
}

/// 角落的一下让给系统的点按（纯的，时间都是开机以来的秒数：NSEvent.timestamp 和 systemUptime 同一个钟；MultitouchSupport 给的帧时间
/// 是另一个钟，别拿来比）
enum ClickYield {
  /// 主线程收到那一下之前这么久里按下过鼠标就算：真按下去的那一下，按下在抬起之前（轻点最长 0.34 s，再加上派回主线程的那一点）
  static let before = 0.5
  /// 之后这么久里：「轻点来点按」的那次点按是系统认出轻点之后才发的，送到全局监听也要一会儿；也是收到之后等多久再定
  static let after = 0.15

  /// 主线程在 `time` 收到的那一下，前后有没有鼠标按下
  static func coincides(tapAt time: Double, mouseDowns: [Double]) -> Bool {
    mouseDowns.contains { $0 >= time - before && $0 <= time + after }
  }
}

/// 触控板手势的监听（AppDelegate 拿着）
@MainActor
final class TrackpadGestures {
  /// 在 Touchpad 上订的那一份
  static let key = "trackpadGestures"

  /// 订着时听哪几种（纯的，单测喂）
  struct Listening: Equatable {
    var taps: Set<Int>
    var holds: Set<Int>
    var corners: Set<FingerGesture.Corner> = []
  }

  /// 真的去做（AppDelegate 接：动作走 run、命令走启动器；停用的 App、状态屏、录快捷键时不做）
  var perform: (TrackpadGestureTarget) -> Void = { _ in }

  private var bindings = TrackpadGestureBindings(text: "")
  /// 订着时的那一份；nil = 没在听
  private var listening: Listening?
  private var tracker: GestureTracker?
  private var dispatch = TapDispatch()
  /// 每次订 / 退订换一代：派回主线程的旧手势、旧的「等第二下」看到代号变了就不做（同 TouchpadWatcher）
  private var generation = 0
  /// 绑了角落时挂着的鼠标按下监听（全局 + 本地），和最近的几次按下（开机以来的秒数）
  private var clickMonitors: [Any] = []
  private var mouseDowns: [Double] = []

  /// 绑了这几种时听什么：轻点、双击都要认轻点；一种都没有 = 不听
  static func listening(for gestures: [TrackpadGesture]) -> Listening? {
    var listening = Listening(taps: [], holds: [], corners: [])
    for gesture in gestures {
      switch (gesture.source, gesture.kind) {
      case (.fingers(let fingers), .hold): listening.holds.insert(fingers)
      case (.fingers(let fingers), _): listening.taps.insert(fingers)
      case (.corner(let corner), _): listening.corners.insert(corner)
      }
    }
    return listening == Listening(taps: [], holds: []) ? nil : listening
  }

  /// 照插件添没添加、绑了什么订 / 退订（启动时、偏好变了时）：要听的没变不动（G8：别把正在按着的那一下清掉）
  func apply() {
    bindings = TrackpadGestureBindings(
      text: UserDefaults.standard.string(forKey: Prefs.trackpadGestureBindings) ?? "")
    let wanted = Feature.trackpadGestures.isOn ? Self.listening(for: bindings.active) : nil
    guard wanted != listening else { return }
    listening = wanted
    if wanted == nil { stop() } else { subscribe() }
  }

  /// 换一个新的识别器订上（同一个 key：Touchpad 只换快照，设备不动）
  private func subscribe() {
    guard let listening else { return }
    generation += 1
    dispatch = TapDispatch()
    let tracker = GestureTracker(
      taps: listening.taps, holds: listening.holds, corners: listening.corners,
      onEvent: Self.forwarder(to: self, generation: generation))
    watchClicks(!listening.corners.isEmpty)
    self.tracker = tracker
    Touchpad.shared.subscribe(
      Self.key, consumer: Self.consumer(feeding: tracker),
      onReset: { [weak self] in
        // 重新枚举过设备：旧的设备编号和做到一半的手势都作废
        guard let self, self.tracker != nil else { return }
        self.subscribe()
      })
  }

  private func stop() {
    generation += 1
    dispatch = TapDispatch()
    watchClicks(false)
    guard tracker != nil else { return }
    tracker = nil
    Touchpad.shared.unsubscribe(Self.key)
  }

  /// 框架线程上收帧的那一下：在 nonisolated 的上下文里建，闭包不会被推成 MainActor（G1）
  nonisolated static func consumer(feeding tracker: GestureTracker) -> TouchConsumer {
    { device, frame in tracker.feed(device: device, frame: frame) }
  }

  /// 认出的那一下派回主线程：同上，在 nonisolated 的上下文里建（它是在框架线程上被调的，G1）
  nonisolated static func forwarder(
    to owner: TrackpadGestures, generation: Int
  ) -> @Sendable (UInt, FingerGesture.Event, Double) -> Void {
    { [weak owner] device, event, time in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let owner, owner.generation == generation else { return }
          owner.received(event, device: device, at: time)
        }
      }
    }
  }

  /// 最近这么多秒里按过键就不认长按
  static let typingQuiet = 1.0

  /// 正在打字：两手掌搭在触控板边上打字时会被认成四指长按（2026-11-28 真机探针），手掌又不抬起来、不算轻点。
  /// 只挡长按：复制完马上四指轻点开剪贴板是常见用法，轻点不挡
  static func isTyping(secondsSinceKey: Double) -> Bool { secondsSinceKey < typingQuiet }

  private func received(_ event: FingerGesture.Event, device: UInt, at time: Double) {
    switch event {
    case .hold(let fingers):
      let sinceKey = CGEventSource.secondsSinceLastEventType(
        .combinedSessionState, eventType: .keyDown)
      guard !Self.isTyping(secondsSinceKey: sinceKey) else { return }
      fire(TrackpadGesture(fingers: fingers, kind: .hold))
    case .tap(let fingers): tap(.fingers(fingers), device: device)
    case .corner(let corner):
      // 先等系统的点按送到（ClickYield.after）：前后有鼠标按下就让给它，这个角在等的第一下一起作废；之后照手指的轻点走，
      // 两下都晚同样的一截，双击的间隔不变
      let received = ProcessInfo.processInfo.systemUptime
      let current = generation
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(ClickYield.after))
        guard let self, self.generation == current else { return }
        guard !ClickYield.coincides(tapAt: received, mouseDowns: self.mouseDowns) else {
          self.dispatch.cancel(device: device, source: .corner(corner))
          return
        }
        self.tap(.corner(corner), device: device)
      }
    }
  }

  /// 一下轻点过 TapDispatch。双击按主线程收到的时刻算（同他的 handleTap），不按框架给的帧时间：等第二下的 0.29 s 也是从主线程
  /// 收到时起算，主线程卡一下时两边才对得上（不然第一下先被当成轻点做掉、第二下又开一轮，评审）
  private func tap(_ source: TrackpadGesture.Source, device: UInt) {
    let now = ProcessInfo.processInfo.systemUptime
    switch dispatch.tap(device: device, source: source, at: now, bound: isBound) {
    case .fire(let gesture): fire(gesture)
    case .wait(let pending):
      let current = generation
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(TapSequence.interval))
        guard let self, self.generation == current,
          let gesture = self.dispatch.expire(pending, bound: self.isBound)
        else { return }
        self.fire(gesture)
      }
    case .none: break
    }
  }

  /// 挂上 / 摘掉鼠标按下的监听（绑了角落才挂；不要授权）。只记时刻，本地的原样放过
  private func watchClicks(_ on: Bool) {
    guard on != !clickMonitors.isEmpty else { return }
    mouseDowns = []
    guard on else {
      clickMonitors.forEach(NSEvent.removeMonitor)
      clickMonitors = []
      return
    }
    let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(matching: downs) { [weak self] event in
      MainActor.assumeIsolated { self?.mouseDown(at: event.timestamp) }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: downs) { [weak self] event in
      MainActor.assumeIsolated { self?.mouseDown(at: event.timestamp) }
      return event
    }
    clickMonitors = [global, local].compactMap { $0 }
  }

  /// 记一次鼠标按下；只留最近一秒的（够 ClickYield 看）
  private func mouseDown(at time: Double) {
    mouseDowns.removeAll { $0 < time - 1 }
    mouseDowns.append(time)
  }

  private func isBound(_ gesture: TrackpadGesture) -> Bool {
    bindings[gesture]?.isActive == true
  }

  private func fire(_ gesture: TrackpadGesture) {
    guard let target = bindings[gesture], target.isActive else { return }
    perform(target)
  }
}
