// 音量 / 亮度键换成刘海岛上的提示（2026-11-14，刘海岛完善 D2，以 Alcove 为准；用户「全部按推荐」+ 探针后确认。
// 归刘海岛插件里一组、默认关，设置 › 刘海岛「音量和亮度」）。
// 做法（各家都一样，探针在 macOS 27.0.1 上验过，macos/build/research/island-polish-2026-11-13/hud-probe/README.md）：
// 建一个只收「系统定义事件」（媒体键走它）的事件拦截，把音量 +、音量 −、静音、亮度 +、亮度 − 这五个键吞掉，自己调
// 音量（OutputVolume，公开的 CoreAudio）和亮度（DisplayBrightness，私有的 DisplayServices），在岛上画一行；键被吞掉后
// 系统自己的提示不出（用户看着屏幕确认过）。
// **这是全仓库第二处事件拦截**（另一处是状态屏的 InputBlock；mac-overlay-panel §11）。它吞的是用户天天按的键，红线：
// - 只收系统定义事件、只吞这五个键；别的事件、别的媒体键（播放、键盘背光）原样放行
// - 拦截在**单独的线程**上，音量和亮度**就在那条线程上改**：主线程卡住时这几个键照样管用，只是岛上不画
// - 这几种时候不吞、原样交回系统：按着 ⌥ ⇧ ⌃ 任一个（系统原来的打开设置、细调、反转提示音、调外接屏）；锁屏着 / 切到
//   别的用户（岛看不见）；这个输出设备调不了音量、没有内建屏；读不到现在的值；**写不进去**（设备正在切换）
// - 按下和抬起成对：按下时吞了的，它的连发和抬起也吞；按下时放行的，连发和抬起也放行（不把半截交给系统）
// - 被系统停掉（回调慢了）就重新打开；醒来、本 App 回到前台时整条重建（停用的通知可能没到）
// - 要「辅助功能」授权（只查不弹框）；没有、建不起来就什么都不做
// 按住连发：按下 0.25 秒后约每 33 ms 一条（实测），每条都走一格半秒就到头——两格之间至少隔 stepGap。
// ponytail: 耳机柄、系统设置里调音量不经按键，岛上不出；调节音量时的提示音没放；到头再按没有回弹；只管内建屏的亮度

import AppKit
import QuartzCore
import Synchronization

@MainActor final class MediaKeys: NSObject {
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

  /// 连发时两格之间至少隔多久（全程 16 格约 1 秒）
  nonisolated static let stepGap: CFTimeInterval = 0.06

  /// 拦截线程和主线程共用的：锁屏着没有（主线程写、拦截线程读）；画一行的回调（投回主线程）
  nonisolated private final class Shared: Sendable {
    let locked = Atomic<Bool>(false)
    let report: @Sendable (Island.Level) -> Void

    init(report: @escaping @Sendable (Island.Level) -> Void) { self.report = report }
  }

  /// 只在拦截线程上用的：拦截的端口（被系统停掉时要拿它重新打开）、上一格的时刻、按下时吞掉了还没抬起的键
  nonisolated private final class Box {
    let shared: Shared
    var port: CFMachPort?
    var lastStep: CFTimeInterval = 0
    var held: Set<Int> = []

    init(shared: Shared) { self.shared = shared }
  }

  private let defaults: UserDefaults
  nonisolated private let shared: Shared
  private var thread: Thread?
  /// 授权有、拦截却没建起来过：不每次偏好变化都重试（回到前台、开关重新打开时再试）
  private var gaveUp = false

  init(island: Island, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    shared = Shared { [weak island] level in
      Task { @MainActor in island?.showLevel(level) }
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

  /// 回到前台 / 醒来：照现在的授权重建一遍
  @objc private func refresh() {
    gaveUp = false
    // 锁没锁也重看一眼：漏过一次解锁的通知的话，不能一直交给系统
    shared.locked.store(InputBlock.isSessionAway, ordering: .relaxed)
    stop()
    apply()
  }

  /// 拦截建着没有
  var isRunning: Bool { thread.map { !$0.isFinished } ?? false }

  /// 照偏好和授权起 / 停（启动时、偏好变了时 AppDelegate 调）：没变不动
  func apply() {
    if let thread, thread.isFinished {
      // 线程自己退了 = 拦截没建起来（授权显示有、系统却不给）或者端口失效了：记下，不每次偏好变化都重起
      self.thread = nil
      gaveUp = true
    }
    let added =
      defaults.object(forKey: Feature.island.prefsKey) as? Bool ?? Feature.island.defaultOn
    let on = added && defaults.bool(forKey: Prefs.islandKeyLevels)
    if !on { gaveUp = false }
    let wanted = on && !gaveUp && Permissions.isAccessibilityTrusted
    if wanted, thread == nil {
      start()
    } else if !wanted {
      stop()
    }
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
            // 每次鼠标点击也有系统定义事件：这条线程只转 CFRunLoop，自动释放的东西（NSEvent）要自己清
            let swallow = autoreleasepool { MediaKeys.handle(box, type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
          }, userInfo: Unmanaged.passUnretained(box).toOpaque())
      else { return }
      box.port = port
      CFRunLoopAddSource(
        CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
      CGEvent.tapEnable(tap: port, enable: true)
      // 一直转到 stop()（cancel + 往这条线程上排一个 wake 把这一轮转停）。端口失效了（.finished：没有源了）就退出，
      // 不空转
      while !Thread.current.isCancelled {
        if CFRunLoopRunInMode(.defaultMode, 3600, false) == .finished { break }
      }
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
      withExtendedLifetime(box) {}
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
    guard type.rawValue == 14, let system = NSEvent(cgEvent: event), system.subtype.rawValue == 8,
      let press = decode(data1: system.data1)
    else { return false }
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
      if let level { box.shared.report(level) }
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
      return Island.Level(kind: .volume, fraction: after, muted: OutputVolume.isMuted ?? false)
    case .mute:
      guard let muted = OutputVolume.isMuted, OutputVolume.setMuted(!muted) else { return nil }
      return Island.Level(kind: .volume, fraction: OutputVolume.read() ?? 0, muted: !muted)
    case .brightnessUp, .brightnessDown:
      guard let brightness = DisplayBrightness.read() else { return nil }
      box.lastStep = now
      let next = stepped(brightness, up: key == .brightnessUp)
      guard DisplayBrightness.set(next) else { return nil }
      return Island.Level(kind: .brightness, fraction: next)
    }
  }

  // MARK: 纯函数（单测锁住）

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
    if up { return after > before + 0.001 || before >= 0.999 }
    return after < before - 0.001 || before <= 0.001
  }
}

extension Island {
  /// 音量 / 亮度的那一行画什么；带电量的提示也是它（device：耳机连上、接上 / 拔掉电源、电量低——左边一句话
  /// （耳机的前面带它的图标），右边电量百分比 + 电池）
  nonisolated struct Level: Equatable, Sendable {
    nonisolated enum Kind: Sendable { case volume, brightness, device }
    /// device：电量那一截的颜色——好着（绿）、低了（红）、平常（白）
    nonisolated enum Tone: Sendable { case plain, good, low }
    var kind: Kind
    /// 0…1；device：电量，还不知道是负数
    var fraction: Double
    var muted = false
    /// device：耳机的名字（读屏、没有刘海的屏上那一行用）
    var label: String?
    /// device：左边的图标（耳机有；电源的提示没有，只有一句话）
    var glyph: String?
    /// device：左边那句话（不给是「已连接」）
    var caption: String?
    var tone = Tone.good
    /// 出多久（不给是 Island.levelDwell）
    var stay: Duration?

    /// 是不是「同一条」（不看数）：同一条原地换数，不是同一条的两个 device 提示换的时候糊着进出
    var identity: String { "\(kind)|\(caption ?? "")|\(glyph ?? "")|\(label ?? "")" }

    /// device：电量（0…1），还没读到是 nil
    var battery: Double? { kind == .device && fraction >= 0 ? min(fraction, 1) : nil }

    /// 静音、0 是划掉的喇叭；音量分三档波纹；亮度是太阳
    var symbol: String {
      switch kind {
      case .brightness: "sun.max.fill"
      case .device: glyph ?? "bolt.fill"
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
      case .volume: muted ? "静音" : "音量"
      case .brightness: "亮度"
      case .device: caption ?? "已连接"
      }
    }

    /// 条上填到几成、右边写百分之几（静音时是 0）
    var shown: Double { muted ? 0 : min(max(fraction, 0), 1) }
  }
}
