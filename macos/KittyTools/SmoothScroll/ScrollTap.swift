// 平滑滚动的事件拦截（拍板 C2：放在 Kitty 里单独的一条线程上；全仓库第三处事件拦截，mac-overlay-panel §11）。
// 会话层加了注解的那一点、头插、会吞事件的拦截，只收滚轮和鼠标按下（2026-11-24 issue #50 从会话层挪过来：这一点上的滚轮带着
// 系统定好的目标进程，帧要照它投）。
// 为什么不在主线程（同状态屏的 InputBlock 那样）：会吞事件的拦截在回调返回之前，这一下滚动谁都收不到；挂在主线程上，Kitty 一忙
// （同步一轮、导入设置、排一篇长便签）全系统的滚轮都会顿，超时系统还会停掉拦截。这里一条专门的线程（Thread + 它自己的运行环，
// 照刘海岛 MediaKeys 的写法）：拦截的回调、出帧的定时器都在它上面。红线：
// - 线程上的东西（拦截、定时器、正在滑的那一段）只在这条线程上碰，回调里**不碰主线程的任何东西、不碰 AppKit**（不转 NSEvent）；
//   主线程只经 ScrollShared 写设置、前台 App 停没停用，用 Mutex 护着
// - 归不归它管、怎么滑都是纯函数（ScrollSmoothing）。自己发出去的合成滚动带一个记号（eventSourceUserData），回到这里原样放过；
//   Dev 版和正式版用同一个记号，两个都开着也不会平滑两遍
// - 合成的滚动是像素单位、标成连续的（App 照触控板那样按像素滚，不再自己加一层滚轮动画），修饰键清空（滑到一半按下 ⌘ 不会
//   变成缩放，NonCoalesced 那一位照新建时的留着）；按屏幕刷新一帧帧发，滑完就停掉定时器，没在滑时这条线程只是在等事件。
// - 帧投到最近那一格滚轮去的地方，不跟着鼠标走（issue #50：原来发到会话层、系统按发出那一刻的光标重新找窗口，滑着时鼠标挪到
//   别的窗口，剩下那截就滚到了那边）：帧是那一格（注解过的）的拷贝，改成像素距离——位置和系统给它记的都是它的（进程里 AppKit
//   按位置找窗口和视图；光标下的窗口那两个字段在这一点上的滚轮也是 0、新建的事件写不进去，都实测过），postToPid 直接投给它的
//   目标进程，不再经会话层重新找。同触控板的惯性：甩出去之后鼠标挪走，惯性还在原来的窗口里滑完。再拨一格换了地方（别的进程、
//   离上一格远过 40 点）时原来没滚完的扔掉（Motion.add）。认不出目标进程的（是 0）、探针的帧照旧发到会话层
// - 拷贝带着原滚轮的事件源：发出去时 eventSourceUserData 按事件源上的算（真滚轮的 0、探针的探针记号），写在字段上的不算
//   （liveProbe 实测；setSource(nil) 也不行）。帧换上这条线程自己的私有事件源、记号写在它上面——不然帧回到拦截里认不出是自己的，
//   当成触控板把这一段停掉
// - 帧上照抄原滚轮「方向已经按自然滚动翻过」的标记（没公开的字段 137，NSEvent.isDirectionInvertedFromDevice；
//   反向开关反过的再翻一次）：按物理方向算的地方（截图框选里滚轮换层）才不会反
// - 鼠标按下、触控板来了（连续的滚动）、按着修饰键拨了一格（缩放，issue #37）时把正在滑的那一段停掉（同触控板上手指一碰，
//   惯性就停；ScrollSmoothing.halts）
// - 妙控鼠标和触控板发的滚动一模一样（连续、带开始 / 变化 / 结束和惯性阶段，2026-11-18 只听的探针实测）：按发送设备分——没公开的
//   字段 87 是 IORegistry 里那台设备（AppleMultitouchDevice）的编号，惯性阶段的也带着；它挂在妙控鼠标的驱动
//   （AppleMultitouchMouseHIDEventDriver）下就是妙控鼠标（触控板挂 …TrackpadHIDEventDriver）。查一次 IOKit、按编号记下
// - 只就地改的（按着修饰键时的反向、妙控鼠标的反向）三种距离要先全读出来再按 行 → 像素 → 定点 写：写行数时系统会按新的行数重算后两个
// - 拦截被系统停用（回调超时、用户输入）就当场重新打开；醒来、本 App 回到前台时 SmoothScroll 整条重建
// - 停：主线程 cancel 线程、往它上面排一个 wake 把运行环转停，这边撤定时器、停用并作废拦截，线程退出
// - 探针（SmoothScrollTests/liveProbe，按需）：probe 开着时真的滚轮一概原样放过，只认带探针记号的事件（也不看前台 App 停没停用）；
//   放出去的帧换一个探针帧的记号、回到这里记下时刻和距离再吞掉——一个都到不了别的 App，同时开着的另一个 Kitty 的帧照常放过
// ponytail: 出帧用运行环的定时器（间隔 = 最快那块屏的一帧），没跟屏幕的刷新对齐；手测看出顿挫再换成加在这条线程运行环上的
// CADisplayLink。

import AppKit
import IOKit
import Synchronization

/// 主线程和滚动线程共用的：主线程写、滚动线程读
nonisolated final class ScrollShared: NSObject, Sendable {
  struct State: Sendable {
    var settings = ScrollSmoothing.Settings()
    /// 前台 App 停用了平滑滚动（ScrollSmoothing.isExcluded，主线程在前台 App 换了、设置变了时算好）
    var excluded = false
    /// 一帧多久（秒）：最快那块屏的一帧
    var frameInterval = 1.0 / 60
    /// 探针模式（只给 SmoothScrollProbeTests）：真的滚轮放过，只认探针的；放出去的帧记下来、吞掉
    var probe = false
    var probeFrames: [ProbeFrame] = []
  }

  struct ProbeFrame: Sendable {
    let time: TimeInterval
    let dx: Int
    let dy: Int
    /// 帧的位置、回到拦截里时系统注解的目标进程（issue #50：帧照那一格投）
    let location: CGPoint
    let targetPID: Int64
  }

  let state = Mutex(State())
  /// 建成了、正在听的拦截有几个（滚动线程写；重建时新的建好了、旧的还没撤完那一下会是 2）
  let listening = Atomic<Int>(0)
  var isListening: Bool { listening.load(ordering: .relaxed) > 0 }

  /// 排到滚动线程上：把这一轮运行环转停（线程已经 cancel，随后退出）
  @objc func wake() { CFRunLoopStop(CFRunLoopGetCurrent()) }
}

/// 只在滚动线程上用：拦截的端口、出帧的定时器、正在滑的那一段
nonisolated final class ScrollTap: NSObject {
  /// 自己发出去的合成滚动的记号（'KTSC'）
  static let ownMarker: Int64 = 0x4B54_5343
  /// 探针打进来的「滚轮」的记号（'KTSP'）、探针模式下放出去的帧的记号（'KTSF'）
  static let probeMarker: Int64 = 0x4B54_5350
  static let probeFrameMarker: Int64 = 0x4B54_5346
  /// 「方向已经按自然滚动翻过」（没公开的字段 137：NSEvent.isDirectionInvertedFromDevice 读的就是它，2026-11-17 只建不发的
  /// 小程序逐个字段试出来的）。只在滚轮事件之间照抄、翻转，不拿它判断别的
  static let invertedField = CGEventField(rawValue: 137)
  /// 发这个事件的设备在 IORegistry 里的编号（没公开的字段 87，2026-11-18 只听的探针实测：触控板、妙控鼠标的滚动和惯性都带着）
  static let senderField = CGEventField(rawValue: 87)

  private let shared: ScrollShared
  /// 发送设备的编号 → 是不是妙控鼠标（只记连续滚动的；重连换编号，多一条）
  private var magicMice: [Int64: Bool] = [:]
  private var port: CFMachPort?
  private var timer: Timer?
  private var motion = ScrollSmoothing.Motion()
  private var bounce = ScrollSmoothing.Bounce()
  private var lastTick: TimeInterval = 0
  /// 正在滑的那一段的帧上写的「方向已经翻过」（最近一格的）
  private var inverted: Int64 = 0
  /// 最近那一格滚轮的拷贝：帧从它改出来（frame(from:…)）
  private var template: CGEvent?
  /// 帧的事件源（记号写在它上面，见文件头）
  private let source = CGEventSource(stateID: .privateState)

  private init(shared: ScrollShared) { self.shared = shared }

  /// 起一条滚动线程：建拦截、转运行环，直到 stop。拦截建不起来、端口自己失效了（不是 stop 停的）时线程退出、调 failed
  /// （在那条线程上调）
  static func start(shared: ScrollShared, failed: @escaping @Sendable () -> Void) -> Thread {
    let thread = Thread {
      if !run(shared: shared) { failed() }
    }
    thread.name = "kitty.smooth-scroll"
    thread.qualityOfService = .userInteractive
    thread.start()
    return thread
  }

  /// 让那条线程自己停下、撤掉拦截（主线程上调）
  static func stop(_ thread: Thread, shared: ScrollShared) {
    thread.cancel()
    shared.perform(#selector(ScrollShared.wake), on: thread, with: nil, waitUntilDone: false)
  }

  /// 线程的全部；返回 false = 拦截没建起来，或者没让它停它自己停了
  private static func run(shared: ScrollShared) -> Bool {
    let tap = ScrollTap(shared: shared)
    let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }
    guard
      let port = CGEvent.tapCreate(
        tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, refcon in
          guard let refcon else { return Unmanaged.passUnretained(event) }
          let tap = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
          // 这条线程只转 CFRunLoop：每下点击、每格滚轮自动释放的东西要自己清
          let swallow = autoreleasepool { tap.handle(type, event) }
          return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(tap).toOpaque())
    else { return false }
    tap.port = port
    CFRunLoopAddSource(
      CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    shared.listening.add(1, ordering: .relaxed)
    // 一直转到 stop（cancel + 排一个 wake 把这一轮转停）。端口失效了（.finished：没有源了）就退出，不空转
    while !Thread.current.isCancelled {
      if CFRunLoopRunInMode(.defaultMode, 3600, false) == .finished { break }
    }
    tap.timer?.invalidate()
    CGEvent.tapEnable(tap: port, enable: false)
    CFMachPortInvalidate(port)
    shared.listening.subtract(1, ordering: .relaxed)
    withExtendedLifetime(tap) {}
    return Thread.current.isCancelled
  }

  /// 一条事件来了：吞不吞（true = 吞掉）
  private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      // 先判这个（这时 event 里是什么没有保证），当场重新打开
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
      return false
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      halt()
      return false
    case .scrollWheel:
      break
    default:
      return false
    }
    let marker = event.getIntegerValueField(.eventSourceUserData)
    if marker == Self.ownMarker { return false }
    let (settings, excluded, probe) = shared.state.withLock { ($0.settings, $0.excluded, $0.probe) }
    if marker == Self.probeFrameMarker {
      guard probe else { return false }
      let frame = ScrollShared.ProbeFrame(event)
      shared.state.withLock { $0.probeFrames.append(frame) }
      return true
    }
    // 探针开着时只认探针的：真的滚轮原样放过
    if probe, marker != Self.probeMarker { return false }
    let wheel = Self.wheel(event, isMagicMouse: isMagicMouse(_:))
    let decision = ScrollSmoothing.decide(wheel, settings: settings, excluded: excluded && !probe)
    if ScrollSmoothing.halts(wheel, decision: decision) { halt() }
    switch decision {
    case .pass:
      return false
    case .flip(let vertical, let horizontal):
      if vertical { Self.negate(event, axis: 1) }
      if horizontal { Self.negate(event, axis: 2) }
      Self.toggleInverted(event)
      return false
    case .smooth(let dx, let dy, let flipped):
      // 抖的那一格也吞掉：交给系统的话它会按原样反着滚一下
      let time = Double(event.timestamp) / 1e9
      guard bounce.accept(dx: dx, dy: dy, time: time) else { return true }
      let device = Self.invertedField.map { event.getIntegerValueField($0) != 0 } ?? false
      inverted = device != flipped ? 1 : 0
      motion.add(dx: dx, dy: dy, to: Self.target(event))
      template = event.copy()
      if timer == nil { begin() }
      return true
    }
  }

  /// 这一格要去的地方：目标进程（会话层加了注解的那一点才有）和位置
  static func target(_ event: CGEvent) -> ScrollSmoothing.Target {
    ScrollSmoothing.Target(
      pid: Int32(clamping: event.getIntegerValueField(.eventTargetUnixProcessID)),
      location: event.location)
  }

  /// 从滚轮事件里取出 decide 要看的几样（单测锁住修饰键：⌘、⌃ 都算交给 App 缩放的那一类，issue #37）；
  /// isMagicMouse 只在连续 / 带阶段的事件上问
  static func wheel(_ event: CGEvent, isMagicMouse: (CGEvent) -> Bool) -> ScrollSmoothing.Wheel {
    let flags = event.flags
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    let phased =
      event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
      || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
    return ScrollSmoothing.Wheel(
      continuous: continuous, phased: phased,
      magicMouse: (continuous || phased) && isMagicMouse(event),
      dy: lines(
        event, fixed: .scrollWheelEventFixedPtDeltaAxis1, whole: .scrollWheelEventDeltaAxis1),
      dx: lines(
        event, fixed: .scrollWheelEventFixedPtDeltaAxis2, whole: .scrollWheelEventDeltaAxis2),
      option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift),
      command: !flags.isDisjoint(with: [.maskCommand, .maskControl]))
  }

  /// 这个连续的滚动是不是妙控鼠标发的（按发送设备的编号记下，同一台只查一次 IOKit）
  private func isMagicMouse(_ event: CGEvent) -> Bool {
    guard let field = Self.senderField else { return false }
    let sender = event.getIntegerValueField(field)
    if let known = magicMice[sender] { return known }
    let found = Self.isMagicMouse(sender: sender)
    magicMice[sender] = found
    return found
  }

  /// IORegistry 里这个编号的设备挂在妙控鼠标的驱动下（合成的事件、拿不到设备的：false）
  static func isMagicMouse(sender: Int64) -> Bool {
    guard sender > 0 else { return false }
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IORegistryEntryIDMatching(UInt64(sender)))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else {
      return false
    }
    defer { IOObjectRelease(parent) }
    return IOObjectConformsTo(parent, "AppleMultitouchMouseHIDEventDriver") != 0
  }

  /// 系统给的行数：定点的那个有小数（带加速）；万一是 0 退回整数的那个
  private static func lines(_ event: CGEvent, fixed: CGEventField, whole: CGEventField) -> Double {
    let value = event.getDoubleValueField(fixed)
    return value != 0 ? value : Double(event.getIntegerValueField(whole))
  }

  /// 把一个轴的三种距离（行、像素、定点）都反过来：先全读出来，再按 行 → 像素 → 定点 写（写行数时系统会按新的行数重算
  /// 后两个，边读边写会把它们反两遍；单测 SmoothScrollTests.negateFlipsAllThree 锁住）
  static func negate(_ event: CGEvent, axis: Int) {
    let (line, point, fixed): (CGEventField, CGEventField, CGEventField) =
      axis == 1
      ? (
        .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1,
        .scrollWheelEventFixedPtDeltaAxis1
      )
      : (
        .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis2
      )
    let values = (
      event.getIntegerValueField(line), event.getIntegerValueField(point),
      event.getDoubleValueField(fixed)
    )
    event.setIntegerValueField(line, value: -values.0)
    event.setIntegerValueField(point, value: -values.1)
    event.setDoubleValueField(fixed, value: -values.2)
  }

  /// 就地反过向的事件：「方向已经翻过」的标记跟着翻
  static func toggleInverted(_ event: CGEvent) {
    guard let field = invertedField else { return }
    event.setIntegerValueField(field, value: event.getIntegerValueField(field) == 0 ? 1 : 0)
  }

  /// 从停着开始滑：当场先放一帧（不等下一个定时器，拨下去马上动），再按一帧的间隔接着放
  private func begin() {
    let interval = shared.state.withLock(\.frameInterval)
    lastTick = ProcessInfo.processInfo.systemUptime - interval
    let timer = Timer(
      timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil,
      repeats: true)
    timer.tolerance = 0
    RunLoop.current.add(timer, forMode: .common)
    self.timer = timer
    tick()
  }

  /// 停掉正在滑的那一段
  private func halt() {
    timer?.invalidate()
    timer = nil
    motion = .init()
    template = nil
  }

  /// 放一帧：发一个像素单位的合成滚动（带记号）；滑完了停掉定时器
  @objc private func tick() {
    autoreleasepool {
      let now = ProcessInfo.processInfo.systemUptime
      let (tau, probe) = shared.state.withLock { ($0.settings.tau, $0.probe) }
      let step = motion.step(dt: now - lastTick, tau: tau)
      lastTick = now
      if step.dx != 0 || step.dy != 0,
        let frame = Self.frame(
          from: template, dx: step.dx, dy: step.dy, inverted: inverted,
          marker: probe ? Self.probeFrameMarker : Self.ownMarker, source: source)
      {
        // 探针的帧要回到拦截里吞掉：照旧发到会话层
        let pid = motion.target.pid
        if pid > 0, !probe { frame.postToPid(pid) } else { frame.post(tap: .cgSessionEventTap) }
      }
      if motion.isIdle { halt() }
    }
  }

  /// 一帧：最近那一格滚轮（template）的拷贝，换上 source（记号写在它上面，见文件头），距离照新建的像素滚动写（行 → 像素 →
  /// 定点：写行数时系统重算另外两个，同 negate），时刻换成现在、滚动次数清零（新建的是 0）；没有那一格或 source 时就是新建的
  /// 那个。单测锁住和新建的一样、位置跟着那一格、事件源上是记号
  static func frame(
    from template: CGEvent?, dx: Int, dy: Int, inverted: Int64, marker: Int64,
    source: CGEventSource?
  ) -> CGEvent? {
    guard
      let fresh = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0)
    else { return nil }
    fresh.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    var event = fresh
    if let source, let copy = template?.copy() {
      source.userData = marker
      copy.setSource(source)
      event = copy
      // 先标成连续再写距离（行数按连续的算，和新建的一样）
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      for (line, point, fixed) in [
        (
          CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1,
          CGEventField.scrollWheelEventFixedPtDeltaAxis1
        ),
        (
          .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2,
          .scrollWheelEventFixedPtDeltaAxis2
        ),
      ] {
        event.setIntegerValueField(line, value: fresh.getIntegerValueField(line))
        event.setIntegerValueField(point, value: fresh.getIntegerValueField(point))
        event.setDoubleValueField(fixed, value: fresh.getDoubleValueField(fixed))
      }
      event.setIntegerValueField(.scrollWheelEventScrollCount, value: 0)
      event.timestamp = DispatchTime.now().uptimeNanoseconds
    }
    event.flags = fresh.flags.intersection(.maskNonCoalesced)
    if let field = invertedField { event.setIntegerValueField(field, value: inverted) }
    event.setIntegerValueField(.eventSourceUserData, value: marker)
    return event
  }
}

extension ScrollShared.ProbeFrame {
  nonisolated fileprivate init(_ event: CGEvent) {
    self.init(
      time: ProcessInfo.processInfo.systemUptime,
      dx: Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
      dy: Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
      location: event.location, targetPID: event.getIntegerValueField(.eventTargetUnixProcessID))
  }
}
