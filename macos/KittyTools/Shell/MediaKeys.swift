// 音量 / 亮度键换成刘海岛上的提示（2026-11-14，刘海岛完善 D2，以 Alcove 为准；用户「全部按推荐」+ 探针后确认。
// 归刘海岛插件里一组、默认关，设置 › 刘海岛「音量和亮度」）。
// 做法（各家都一样，探针在 macOS 27.0.1 上验过，macos/build/research/island-polish-2026-11-13/hud-probe/README.md）：
// 建一个只收「系统定义事件」（媒体键走它）的事件拦截，把音量 +、音量 −、静音、亮度 +、亮度 − 这五个键吞掉，自己调
// 音量（OutputVolume，公开的 CoreAudio）和亮度（DisplayBrightness，私有的 DisplayServices），在岛上画一行；键被吞掉后
// 系统自己的提示不出（用户看着屏幕确认过）。
// **这是全仓库第二处事件拦截**（另三处是状态屏的 InputBlock、平滑滚动的 SmoothScroll/ScrollTap、访达里 ⌘X / ⌘V 的 FinderMenu/FinderKeys；mac-overlay-panel §11）。它吞的是用户天天按的键，红线：
// - 只收系统定义事件、只吞这五个键；别的事件、别的媒体键（播放、键盘背光）原样放行
// - 拦截在**单独的线程**上，音量和亮度**就在那条线程上改**：主线程卡住时这几个键照样管用，只是岛上不画
// - 拦截线程上**不碰 AppKit**：不转 NSEvent（中英文切换的事件转换时进 HIToolbox、断言主队列闪退，PR #22），subtype / data1
//   直接读 CGEvent 的字段（decode(event:)），开拦截前 fieldsReadable 现场核对字段编号
// - 这几种时候不吞、原样交回系统：按着 ⌥ ⇧ ⌃ 任一个（系统原来的打开设置、细调、反转提示音、调外接屏）；锁屏着 / 切到
//   别的用户（岛看不见）；这个输出设备调不了音量、没有内建屏；读不到现在的值；**写不进去**（设备正在切换）
// - 按下和抬起成对：按下时吞了的，它的连发和抬起也吞；按下时放行的，连发和抬起也放行（不把半截交给系统）
// - 被系统停掉（回调慢了）就重新打开；醒来、本 App 回到前台时整条重建（停用的通知可能没到）。**状态屏开着时不重建**：
//   新建的拦截是头插、排在状态屏那一处的前面，音量键、亮度键会穿过状态屏；记下「欠一次」，状态屏退出时补（resume，第五轮体检 E11）
// - 要「辅助功能」授权（只查不弹框）；没有、核对字段没过、建不起来就什么都不做，设置页照 status 说一句（第五轮体检 U6）
// 按住连发：按下 0.25 秒后约每 33 ms 一条（实测），每条都走一格半秒就到头——两格之间至少隔 stepGap。
// 到头了再按（100% 再按 +、0 再按 −）照样算走了一格、岛上照样出，细条往那一头顶出去一下再弹回（Level.pushed，第五轮体检 U13；
// 按住连发时只有第一下弹）。
// 跟系统「调节音量时播放反馈」（第五轮体检 U14；全局偏好 com.apple.sound.beep.feedback，没存过 = 关——10.12 起系统的默认，
// 开发机 macOS 27.0.1 上 `defaults read -g` 读不到这个键）：开着就在调完音量之后放系统那一声（BezelServices 的 volume.aiff，
// 调完再放 = 新音量的响度）；只在音量 ± 时放，静音、亮度不放；连按、按住时等按键停下 feedbackDelay 再放一声、放之前停掉上一声，
// 不叠成一串。NSSound 是 AppKit，在主线程放。设置页不另加开关（跟系统的）。按着 ⇧ 时整个交回系统，系统照它的规矩放。
// ponytail: 耳机柄、系统设置里调音量不经按键，岛上不出；只管内建屏的亮度

import AppKit
import QuartzCore
import Synchronization

@MainActor @Observable final class MediaKeys: NSObject {
  /// 这五个键（IOKit 的 NX_KEYTYPE_*）
  nonisolated enum Key: Int, Sendable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
  }

  /// 一条事件怎么办
  nonisolated enum Verdict: Sendable {
    /// 原样交回系统
    case pass
    /// 吞掉、什么都不做（按下时吞了的键的抬起）
    case swallow
    /// 吞掉、照着调
    case act
  }

  /// 拦截现在怎样（设置 › 刘海岛「音量和亮度」照它说一句，第五轮体检 U6；照平滑滚动的 SmoothScroll.Status）
  enum Status: Equatable {
    /// 开关关着、插件没添加
    case off
    /// 没有「辅助功能」授权
    case needsPermission
    /// 开拦截前核对那两个没公开的字段没过（这一版系统换了编号）：不建，几个键照旧交给系统
    case unreadable
    /// 授权显示有，拦截却建不起来（或者自己失效了）
    case failed
    case running
  }

  /// 连发时两格之间至少隔多久（全程 16 格约 1 秒）
  nonisolated static let stepGap: CFTimeInterval = 0.06
  /// 调音量的那一声：按键停下多久之后放（连按、按住时只在停下后放一声）
  static let feedbackDelay = Duration.milliseconds(150)

  /// 拦截线程和主线程共用的：锁屏着没有（主线程写、拦截线程读）；画一行的回调（投回主线程；chimes = 这一下是音量 ±，
  /// 跟着系统设置放一声）
  nonisolated private final class Shared: Sendable {
    let locked = Atomic<Bool>(false)
    let report: @Sendable (Island.Level, _ chimes: Bool) -> Void

    init(report: @escaping @Sendable (Island.Level, _ chimes: Bool) -> Void) {
      self.report = report
    }
  }

  /// 只在拦截线程上用的：拦截的端口（被系统停掉时要拿它重新打开）、上一格的时刻、按下时吞掉了还没抬起的键
  nonisolated private final class Box {
    let shared: Shared
    var port: CFMachPort?
    var lastStep: CFTimeInterval = 0
    var held: Set<Int> = []

    init(shared: Shared) { self.shared = shared }
  }

  private(set) var status = Status.off
  private let defaults: UserDefaults
  nonisolated private let shared: Shared
  @ObservationIgnored private var thread: Thread?
  /// 起过第几条线程：建不起来的回调晚到时（这期间已经重建过）认得出不是现在这条
  @ObservationIgnored private var generation = 0
  /// 授权有、拦截却没建起来过：不每次偏好变化都重试（回到前台、开关重新打开时再试）
  @ObservationIgnored private var gaveUp = false
  /// 状态屏开着（AppDelegate 给，看 StatusScreen.isActive）：这时不建、不重建拦截（E11）
  @ObservationIgnored var isHeldBack: () -> Bool = { false }
  /// 状态屏开着时该建 / 该重建没做：退出时补（resume）
  @ObservationIgnored private var owed = false

  init(island: Island, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    shared = Shared { [weak island] level, chimes in
      Task { @MainActor in
        island?.showLevel(level)
        if chimes { MediaKeys.chime() }
      }
    }
    super.init()
    // 「辅助功能」授权可能刚变、拦截可能在睡着时被系统停了而通知没到：回到前台、醒来时整条重建
    let centers = [
      (NotificationCenter.default, NSApplication.didBecomeActiveNotification),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
    ]
    for (center, name) in centers {
      center.addObserver(self, selector: #selector(refresh), name: name, object: nil)
    }
    // 锁屏着不吞：岛看不见，交给系统自己的提示。分布式通知要 deliverImmediately（本 App 几乎从不在前台，默认的
    // 会被系统压着等下次激活）；启动时可能已经锁着，先看一眼
    shared.locked.store(InputBlock.isSessionAway, ordering: .relaxed)
    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(
      self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"),
      object: nil, suspensionBehavior: .deliverImmediately)
    distributed.addObserver(
      self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"),
      object: nil, suspensionBehavior: .deliverImmediately)
  }

  @objc nonisolated private func screenLocked() { shared.locked.store(true, ordering: .relaxed) }
  @objc nonisolated private func screenUnlocked() { shared.locked.store(false, ordering: .relaxed) }

  /// 回到前台 / 醒来：照现在的授权重建一遍。状态屏开着时不拆不建，记下欠一次（E11）
  @objc private func refresh() {
    // 锁没锁也重看一眼：漏过一次解锁的通知的话，不能一直交给系统
    shared.locked.store(InputBlock.isSessionAway, ordering: .relaxed)
    // 现有的这条建在状态屏之前、排在它后面，留着没事；拆了重建的那条会排到它前面
    if isHeldBack() {
      owed = true
      return
    }
    gaveUp = false
    stop()
    apply()
  }

  /// 状态屏退出了（AppDelegate 接 StatusScreen.onExit）：开着时欠下的重建补上（E11）
  func resume() {
    guard owed else { return }
    owed = false
    refresh()
  }

  /// 拦截建着没有
  var isRunning: Bool { thread.map { !$0.isFinished } ?? false }

  /// 照偏好和授权起 / 停（启动时、偏好变了时 AppDelegate 调）：没变不动
  func apply() {
    let added =
      defaults.object(forKey: Feature.island.prefsKey) as? Bool ?? Feature.island.defaultOn
    let on = added && defaults.bool(forKey: Prefs.islandKeyLevels)
    if !on { gaveUp = false }
    // 开关开着才去查授权、核对字段（核对要造一条事件）
    let trusted = on && Permissions.isAccessibilityTrusted
    let next = Self.status(
      on: on, trusted: trusted, readable: trusted && Self.fieldsReadable, gaveUp: gaveUp)
    guard next == .running else {
      stop()
      // 偏好一变就调一次：没变不写（写了设置页就重画一遍）
      if status != next { status = next }
      return
    }
    if thread == nil {
      // 状态屏开着：先不建（建出来会排在它的拦截前面），退出时补
      if isHeldBack() {
        owed = true
        return
      }
      start()
    }
    if status != .running { status = .running }
  }

  /// 照这几样定状态（纯函数，配单测）：先看开没开，再看授权、字段核对，最后看建没建起来过
  static func status(on: Bool, trusted: Bool, readable: Bool, gaveUp: Bool) -> Status {
    if !on { return .off }
    if !trusted { return .needsPermission }
    if !readable { return .unreadable }
    return gaveUp ? .failed : .running
  }

  /// 拦截线程自己退了（没建起来：授权显示有、系统却不给；或者端口失效了）：记成失败，不每次偏好变化都重起，等下一次
  /// 回到前台、醒来、开关重新打开
  private func tapFailed(_ generation: Int) {
    guard generation == self.generation, thread != nil else { return }
    thread = nil
    gaveUp = true
    status = .failed
  }

  private func stop() {
    guard let thread else { return }
    // 让那条线程自己停下、撤掉拦截
    thread.cancel()
    perform(#selector(wake), on: thread, with: nil, waitUntilDone: false)
    self.thread = nil
  }

  private func start() {
    let shared = shared
    generation += 1
    let current = generation
    let failed: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in self?.tapFailed(current) }
    }
    let thread = Thread {
      let box = Box(shared: shared)
      // NX_SYSDEFINED = 14：只收系统定义事件
      guard
        let port = CGEvent.tapCreate(
          tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
          eventsOfInterest: 1 << 14,
          callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            // 每次鼠标点击也有系统定义事件：这条线程只转 CFRunLoop，自动释放的东西要自己清
            let swallow = autoreleasepool { MediaKeys.handle(box, type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
          }, userInfo: Unmanaged.passUnretained(box).toOpaque())
      else { return failed() }
      box.port = port
      CFRunLoopAddSource(
        CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
      CGEvent.tapEnable(tap: port, enable: true)
      // 一直转到 stop()（cancel + 往这条线程上排一个 wake 把这一轮转停）。端口失效了（.finished：没有源了）就退出，
      // 不空转
      while !Thread.current.isCancelled {
        if CFRunLoopRunInMode(.defaultMode, 3600, false) == .finished { break }
      }
      let stopped = Thread.current.isCancelled
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
      withExtendedLifetime(box) {}
      // 不是 stop() 叫停的 = 端口自己失效了
      if !stopped { failed() }
    }
    thread.name = "kitty.media-keys"
    thread.qualityOfService = .userInteractive
    thread.start()
    self.thread = thread
  }

  /// 在拦截线程上跑：把它这一轮 run loop 转停（线程已经 cancel，随后退出）
  @objc nonisolated private func wake() {
    CFRunLoopStop(CFRunLoopGetCurrent())
  }

  // MARK: 拦截线程上

  /// 一条事件来了：吞不吞（true = 吞掉）。只在拦截线程上调
  nonisolated private static func handle(_ box: Box, _ type: CGEventType, _ event: CGEvent) -> Bool
  {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port = box.port { CGEvent.tapEnable(tap: port, enable: true) }
      return false
    }
    guard type.rawValue == 14, let press = decode(event: event) else { return false }
    let code = press.key.rawValue
    let verdict = verdict(
      down: press.down, isRepeat: press.isRepeat, held: box.held.contains(code),
      takes: takes(flags: event.flags, locked: box.shared.locked.load(ordering: .relaxed)))
    switch verdict {
    case .pass:
      // 放行的第一下：清掉旧账（上一次的抬起丢过的话，别把这一次的抬起吞了）
      if press.down, !press.isRepeat { box.held.remove(code) }
      return false
    case .swallow:
      box.held.remove(code)
      return true
    case .act:
      guard let level = perform(press.key, isRepeat: press.isRepeat, box: box) else {
        // 调不了：第一下交回系统（顺手清掉旧账：这一串的连发、抬起都归系统）；连发时第一下已经吞了，这一条也只能吞
        // （不给系统一条没头的连发）
        if !press.isRepeat { box.held.remove(code) }
        return press.isRepeat
      }
      box.held.insert(code)
      if let level { box.shared.report(level, press.key == .volumeUp || press.key == .volumeDown) }
      return true
    }
  }

  /// 照这个键调一下。外层 nil = 调不了（第一下交回系统）；里层 nil = 吞掉但这一下不动（连发太密、静音键的连发）
  nonisolated private static func perform(_ key: Key, isRepeat: Bool, box: Box) -> Island.Level?? {
    // 先限速再碰 CoreAudio / 亮度（设备卡住时别让每条连发都等一次）；用单调的钟（系统时间会被改）
    let now = CACurrentMediaTime()
    if isRepeat, key == .mute || now - box.lastStep < stepGap { return .some(nil) }
    switch key {
    case .volumeUp, .volumeDown:
      let up = key == .volumeUp
      guard OutputVolume.isSettable, let volume = OutputVolume.read() else { return nil }
      box.lastStep = now
      // 写完读回来：档比 1/16 粗的设备会把它量化回原来那一档。没往该去的方向动就再多走一格试一次（不然按住时
      // 走到某一档就卡住）；还不动、又没到头，才算调不了
      var target = stepped(volume, up: up)
      var after = volume
      for _ in 0..<2 {
        guard OutputVolume.set(target) else { return nil }
        // 写成功、读回失败：当它到了要去的地方（别算成没动、再交给系统多走一格）
        after = OutputVolume.read() ?? target
        if moved(from: volume, to: after, up: up) { break }
        target = stepped(target, up: up)
      }
      guard moved(from: volume, to: after, up: up) else { return nil }
      // 按音量 + 解除静音（同系统）
      if up, OutputVolume.isMuted == true { OutputVolume.setMuted(false) }
      // 到头了再按：细条顶出去一下（按住连发时只有第一下）
      return Island.Level(
        kind: .volume, fraction: after, muted: OutputVolume.isMuted ?? false,
        pushed: !isRepeat && atEnd(volume, up: up))
    case .mute:
      guard let muted = OutputVolume.isMuted, OutputVolume.setMuted(!muted) else { return nil }
      return Island.Level(kind: .volume, fraction: OutputVolume.read() ?? 0, muted: !muted)
    case .brightnessUp, .brightnessDown:
      guard let brightness = DisplayBrightness.read() else { return nil }
      box.lastStep = now
      let up = key == .brightnessUp
      let next = stepped(brightness, up: up)
      guard DisplayBrightness.set(next) else { return nil }
      return Island.Level(
        kind: .brightness, fraction: next, pushed: !isRepeat && atEnd(brightness, up: up))
    }
  }

  // MARK: 纯函数（单测锁住）

  /// 直接读系统事件的 subtype / data1，不转 NSEvent：中英文切换（Caps Lock）的事件在转换时会进入
  /// HIToolbox 的输入法处理，后台线程触发主队列断言（2026-11-16，0.9.0 真机崩溃）。这两个未公开的字段
  /// 0x53 / 0x95 在 macOS 27 探针与 NSEvent 对照过；先认 subtype 8，其他子类型没有 compound data，不能读 data1
  /// （读了 SkyLight 直接断言退出：子类型 6、9 实测）。别的系统版本上对不对，开拦截前由 fieldsReadable 现场对一遍。
  nonisolated static func decode(event: CGEvent) -> (key: Key, down: Bool, isRepeat: Bool)? {
    guard event.type.rawValue == 14,
      let subtype = CGEventField(rawValue: 0x53), event.getIntegerValueField(subtype) == 8,
      let data1 = CGEventField(rawValue: 0x95)
    else { return nil }
    return decode(data1: Int(event.getIntegerValueField(data1)))
  }

  /// 那两个没公开的字段在这台的系统上读得对：主线程上用 AppKit 造一条「亮度 + 按下、连发」对一下。对不上（哪个系统版本
  /// 换了编号）就不建拦截、几个键照旧交给系统，不拿读错的字段去吞键
  static let fieldsReadable: Bool = {
    guard
      let event = NSEvent.otherEvent(
        with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, subtype: 8, data1: Key.brightnessUp.rawValue << 16 | 0xA01, data2: -1)?
        .cgEvent,
      let press = decode(event: event)
    else { return false }
    return press.key == .brightnessUp && press.down && press.isRepeat
  }()

  /// 系统定义事件（子类型 8）的 data1 → 哪个键、按下还是抬起、是不是连发。高 16 位是键；低 16 位里第 8–15 位
  /// 0xA = 按下、0xB = 抬起，最低位 = 连发。不是这五个键、不是按下 / 抬起的是 nil
  nonisolated static func decode(data1: Int) -> (key: Key, down: Bool, isRepeat: Bool)? {
    guard let key = Key(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return nil }
    let state = (data1 & 0xFF00) >> 8
    guard state == 0xA || state == 0xB else { return nil }
    return (key, state == 0xA, data1 & 1 == 1)
  }

  /// 这一下（第一下按下）接不接：锁屏着（岛看不见）、按着 ⌥ ⇧ ⌃ 任一个交回系统——⌥ 是打开设置、⌥⇧ 是细调、
  /// ⇧ 是反转调音量的提示音、⌃ 加亮度键是调外接屏，都是系统自己的活
  nonisolated static func takes(flags: CGEventFlags, locked: Bool) -> Bool {
    !locked && flags.intersection([.maskAlternate, .maskShift, .maskControl]).isEmpty
  }

  /// 一条事件怎么办。held = 这个键按下时被我们吞了、还没抬起；takes = 按现在的修饰键和锁屏状态接不接。
  /// 按下和抬起成对：第一下看 takes；连发和抬起跟第一下走（按住中途按 / 松修饰键、锁屏都不改主意）
  nonisolated static func verdict(down: Bool, isRepeat: Bool, held: Bool, takes: Bool) -> Verdict {
    if !down { return held ? .swallow : .pass }
    if isRepeat { return held ? .act : .pass }
    return takes ? .act : .pass
  }

  /// 走一格（同系统：全程 16 格，先吸到最近的格上再走），夹在 0…1
  nonisolated static func stepped(_ value: Double, up: Bool) -> Double {
    let steps = (min(max(value, 0), 1) * 16).rounded() + (up ? 1 : -1)
    return min(max(steps / 16, 0), 1)
  }

  /// 写完读回来算不算「走了」：往该去的方向动了，或者本来就在那一头（到头了再按：照样算，岛上显示 100% / 0%）
  nonisolated static func moved(from before: Double, to after: Double, up: Bool) -> Bool {
    if up { return after > before + 0.001 || atEnd(before, up: true) }
    return after < before - 0.001 || atEnd(before, up: false)
  }

  /// 已经在按的这一头了（100% 再按 +、0 再按 −）
  nonisolated static func atEnd(_ value: Double, up: Bool) -> Bool {
    up ? value >= 0.999 : value <= 0.001
  }

  // MARK: 调音量的那一声（主线程）

  /// 系统调音量时的那一声
  private static let feedbackURL = URL(
    fileURLWithPath:
      "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff")
  private static var feedback: NSSound?
  private static var feedbackTask: Task<Void, Never>?

  /// 刚调了音量：系统那个开关开着就放一声。等按键停下 feedbackDelay 再放（连按、按住时只放最后那一声），放之前停掉上一声；
  /// 那时才读开关（在系统设置里刚改过的当场跟上）。声音文件在系统私有路径，找不到就不响
  private static func chime() {
    feedbackTask?.cancel()
    feedbackTask = Task {
      try? await Task.sleep(for: feedbackDelay)
      // 系统「调节音量时播放反馈」：全局偏好，按系统的读法（1 / YES / true 都算开）；没存过是 false，同 10.12 起的默认
      guard !Task.isCancelled,
        CFPreferencesGetAppBooleanValue(
          "com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication, nil)
      else { return }
      if feedback == nil, FileManager.default.fileExists(atPath: feedbackURL.path) {
        feedback = NSSound(contentsOf: feedbackURL, byReference: true)
      }
      feedback?.stop()
      feedback?.play()
    }
  }
}

extension Island {
  /// 音量 / 亮度的那一行画什么；带电量的提示也是它（device：耳机连上、接上 / 拔掉电源、电量低——左边一句话
  /// （耳机的前面带它的图标），右边电量百分比 + 电池）；toggle：开 / 关这一类（2026-11-17：系统专注模式 SystemFocus、
  /// 低电量模式 SystemNotices）——左边图标（它的颜色）+ 名字，右边「开 / 关」；fraction 1 是开、0 是关
  nonisolated struct Level: Equatable, Sendable {
    nonisolated enum Kind: Sendable { case volume, brightness, device, toggle }
    /// device：电量那一截的颜色——好着（绿）、低了（红）、平常（白）
    nonisolated enum Tone: Sendable { case plain, good, low }
    var kind: Kind
    /// 0…1；device：电量，还不知道是负数
    var fraction: Double
    var muted = false
    /// 音量 / 亮度到头了还在按（100% 再按 +、0 再按 −）：细条往那一头顶出去一下再弹回（U13；Island.levelBumps）
    var pushed = false
    /// device：耳机的名字（读屏、没有刘海的屏上那一行用）
    var label: String?
    /// device：左边的图标（耳机有；电源的提示没有，只有一句话）
    var glyph: String?
    /// device：左边那句话（不给是「已连接」）
    var caption: String?
    var tone = Tone.good
    /// 出多久（不给是 Island.levelDwell）
    var stay: Duration?
    /// toggle：图标和「开」的颜色（系统的颜色名，SystemFocus.color）
    var tint: String?
    /// 刘海两边各伸出多宽（toggle 的名字长短不一，量好给：SystemFocus.wing；别的都是 Island.levelWing）
    var wing = Island.levelWing

    /// 是不是「同一条」（不看数）：同一条原地换数，不是同一条的两个 device 提示换的时候糊着进出
    var identity: String { "\(kind)|\(caption ?? "")|\(glyph ?? "")|\(label ?? "")" }

    /// device：电量（0…1），还没读到是 nil
    var battery: Double? { kind == .device && fraction >= 0 ? min(fraction, 1) : nil }

    /// 静音、0 是划掉的喇叭；音量分三档波纹；亮度是太阳
    var symbol: String {
      switch kind {
      case .brightness: "sun.max.fill"
      case .device: glyph ?? "bolt.fill"
      case .toggle: glyph ?? "moon.fill"
      case .volume:
        if muted || fraction <= 0 {
          "speaker.slash.fill"
        } else if fraction < 0.34 {
          "speaker.wave.1.fill"
        } else if fraction < 0.67 {
          "speaker.wave.2.fill"
        } else {
          "speaker.wave.3.fill"
        }
      }
    }

    /// 读屏、占位用的名字
    var title: String {
      switch kind {
      case .volume: muted ? String(localized: "静音") : String(localized: "音量")
      case .brightness: String(localized: "亮度")
      case .device: caption ?? String(localized: "已连接")
      case .toggle: caption ?? String(localized: "专注模式")
      }
    }

    /// 条上填到几成、右边写百分之几（静音时是 0）
    var shown: Double { muted ? 0 : min(max(fraction, 0), 1) }
  }
}
