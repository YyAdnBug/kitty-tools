// 睡眠关蓝牙（插件，2026-11-17；用户转来的请求「对标 Bluesnooze」，PLAN §10「睡眠关蓝牙」）：电脑睡下去时关掉蓝牙，醒来
// 再打开——放在包里时蓝牙鼠标 / 键盘不会把它弄醒，睡着的 Mac 也不会去抢手机连着的耳机。
// 对标（只看行为，不拷代码）：Bluesnooze 原版（每次睡眠都关、醒来一律打开）、它最常用的 fork（醒来只恢复睡前的状态）、
// 原版没合的 PR #62（接着外接显示器时不关，不然合盖模式下蓝牙键鼠叫不醒电脑）、Vorssaint 的「睡眠时的蓝牙」（两个开关：
// 睡眠时关、醒来时重新打开，后者只管它自己关掉的）。我们的取舍：
// - 什么时候关：「只在合上盖子时关」（Prefs.bluetoothSnoozeLidOnly，默认开）；关掉它就每次睡眠都关。都是接着外接显示器时不关。
//   ponytail: 开着盖子先睡着、之后才合上的，那一次没有睡前通知，不关（要每次都关就关掉「只在合上盖子时」）
// - 「醒来时重新打开蓝牙」（Prefs.bluetoothSnoozeReopen，默认开；关掉 = 醒来后蓝牙一直关着，等你自己开）。只打开**我们关掉的**：关掉前在偏好里记一笔（held，先记再关），醒来、插件启动（睡着时闪退 / 重启过）、插件移除时
//   看这一笔；用户本来就关着的蓝牙不碰。关机不管（原版关机也关：下次开机登录界面上蓝牙键盘就打不了字）。
// - 醒来打开后 5 秒还没开就再试一次，再 5 秒还没开，刘海岛说一声（原版 #42 #52：新系统上偶尔醒来不开）。
// - 开关蓝牙用私有的 IOBluetoothPreferenceGet/SetControllerPowerState（Bluesnooze、blueutil 都用它；2026-11-16 在 27.0.1 上
//   查过还在），同锁屏的写法按名字找（dlopen / dlsym），找不到 = 这台系统上没有这个插件（isSupported）。台式机没有盖子，也没有。
// - 要「蓝牙」授权（macOS 26 起没写用途说明的 App 一调就被系统杀掉，Bluesnooze PR #61）：Info.plist 写了
//   NSBluetoothAlwaysUsageDescription；没授权时一个私有接口都不调，授权框用公开的 CBCentralManager 弹。
// ponytail: 睡前用的是 NSWorkspace 的通知，系统不等我们；实测关不及时再换 IOKit 的 IORegisterForSystemPower（能拖住休眠）

import AppKit
import CoreBluetooth
import IOKit

@MainActor final class BluetoothSnooze {
  /// 这台 Mac 能不能用：有盖子、私有接口在（启动时算一次；Feature.isAvailable 在别的线程也读）
  nonisolated static let isSupported = Machine.hasLid && Bluetooth.isAvailable

  /// 有没有「蓝牙」授权（只看、不弹框）
  static var isAuthorized: Bool { CBManager.authorization == .allowedAlways }

  /// 睡下去的那一刻该不该关（纯函数，单测锁住）
  nonisolated static func shouldTurnOff(
    lidOnly: Bool, lidClosed: Bool, externalDisplay: Bool, bluetoothOn: Bool
  ) -> Bool {
    bluetoothOn && !externalDisplay && (!lidOnly || lidClosed)
  }

  /// 岛上说一声（AppDelegate 接刘海岛）
  var announce: (LocalizedStringResource) -> Void = { _ in }
  private var observers: [NSObjectProtocol] = []
  /// 醒来后的核对（5 秒后看开没开），再睡下去时取消
  private var check: Task<Void, Never>?
  /// 只为弹授权框：系统在建它的时候问，问完之前得留着
  private var central: CBCentralManager?

  /// 插件添加时、启动时（AppDelegate.applyFeatures）
  func start() {
    guard observers.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    observers = [
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.willSleep() }
      },
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.restore() }
      },
    ]
    restore()  // 上次关了还没打开（睡着时闪退、睡着时没电重启）
  }

  /// 插件移除时：不再听，我们关掉的先打开（开着「醒来时重新打开」时）
  func stop() {
    observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    observers = []
    restore()
  }

  /// 没问过时弹系统的蓝牙授权框（运行中添加插件时、设置页「去授权」）；问过了打开系统设置那一页
  func requestAccess() {
    if CBManager.authorization == .notDetermined {
      central = CBCentralManager(
        delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    } else {
      Permissions.Kind.bluetooth.openSettings()
    }
  }

  private func willSleep() {
    check?.cancel()
    guard Self.isAuthorized, let isOn = Bluetooth.isOn,
      Self.shouldTurnOff(
        lidOnly: UserDefaults.standard.bool(forKey: Prefs.bluetoothSnoozeLidOnly),
        lidClosed: Machine.lidClosed,
        externalDisplay: Machine.hasExternalDisplay, bluetoothOn: isOn)
    else { return }
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: Prefs.bluetoothSnoozeHeld)  // 先记再关：关了没记上 = 醒来不开
    defaults.set(Date.now.timeIntervalSince1970, forKey: Prefs.bluetoothSnoozeOffAt)
    Bluetooth.setOn(false)
  }

  private func restore() {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: Prefs.bluetoothSnoozeHeld), Self.isAuthorized else { return }
    defaults.removeObject(forKey: Prefs.bluetoothSnoozeHeld)
    // 关了「醒来时重新打开」：这一笔清掉就完了，蓝牙一直关着等你自己开
    guard defaults.bool(forKey: Prefs.bluetoothSnoozeReopen) else { return }
    defaults.set(Date.now.timeIntervalSince1970, forKey: Prefs.bluetoothSnoozeOnAt)
    // 用户在这之前自己打开了就什么都不用做
    guard Bluetooth.isOn == false else { return }
    Bluetooth.setOn(true)
    check?.cancel()
    check = Task { [weak self] in
      for attempt in 0..<2 {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, Bluetooth.isOn == false else { return }
        if attempt == 0 {
          Bluetooth.setOn(true)
        } else {
          self?.announce("蓝牙没能重新打开，请在控制中心里打开")
        }
      }
    }
  }
}

/// 私有接口：同 SystemControl 的锁屏，按名字找，找不到就当这台系统用不了（mac-native §3 的 C 接口名单）
nonisolated enum Bluetooth {
  private typealias Getter = @convention(c) () -> Int32
  private typealias Setter = @convention(c) (Int32) -> Void

  /// 每次现找（同锁屏；dlopen 同一个库只是加一次引用计数），不存指针：C 指针不是 Sendable，静态存着过不了并发检查
  private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
    dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
      .flatMap { dlsym($0, name) }
  }

  static var isAvailable: Bool {
    symbol("IOBluetoothPreferenceGetControllerPowerState") != nil
      && symbol("IOBluetoothPreferenceSetControllerPowerState") != nil
  }

  /// 蓝牙开着没有；nil = 接口不在。要先有蓝牙授权才能调（没写用途说明会被系统杀掉）
  @MainActor static var isOn: Bool? {
    symbol("IOBluetoothPreferenceGetControllerPowerState").map {
      unsafeBitCast($0, to: Getter.self)() != 0
    }
  }

  @MainActor static func setOn(_ on: Bool) {
    guard let pointer = symbol("IOBluetoothPreferenceSetControllerPowerState") else { return }
    unsafeBitCast(pointer, to: Setter.self)(on ? 1 : 0)
  }
}

/// 这台 Mac 的盖子和显示器：公开的 IOKit / CoreGraphics，不要授权
nonisolated enum Machine {
  /// 有没有盖子（台式机的电源管理里没有这一项）
  static var hasLid: Bool { clamshell != nil }
  static var lidClosed: Bool { clamshell == true }

  private static var clamshell: Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }
    let value = IORegistryEntryCreateCFProperty(
      root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return value?.takeRetainedValue() as? Bool
  }

  /// 接着外接显示器（含合盖模式下唯一亮着的那块）
  static var hasExternalDisplay: Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
  }
}
