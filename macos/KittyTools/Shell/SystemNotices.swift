// 刘海岛上的系统一瞬提示（2026-11-13，刘海岛扩展 D1）：接上 / 拔掉电源（带电量）、电量低到 20% 和 10%、耳机或 AirPods 连上
// （2026-11-14 起贴在刘海两边、带电量：Headphones.swift）、断网 / 网络恢复。弹一下就走，同别的提示；每种一个开关（设置 › 刘海岛「系统提示」，默认都关），**不开就不监听**。
// 全是公开接口、有变化才通知，空闲 0 CPU、不要授权：电源走 IOKit 的电源通知（IOPSNotificationCreateRunLoopSource，主线程的
// run loop 上回调），耳机走 CoreAudio 的默认输出设备变化（回调投在主队列），网络走 Network 的 NWPathMonitor（主队列）。
// 不做的（拍板 D1）：Wi-Fi 的名字（macOS 14 起要定位授权）、摄像头 / 麦克风在用（菜单栏本来就有
// 橙点绿点）、大写锁定（系统在输入框旁提示）。和 C 接口打交道的只在这个文件（mac-native §3）。

import AppKit
import CoreAudio
import IOKit.ps
import Network

@MainActor final class SystemNotices {
  private weak var island: Island?
  private let defaults: UserDefaults
  private var powerSource: CFRunLoopSource?
  /// 上一次读到的电源：接没接电源、电量（%）；第一次读到时只记下，不弹
  private var lastPower: (plugged: Bool, percent: Int)?
  /// 这一轮放电里已经提醒过的门槛（接上电源清掉）
  private var warned: Set<Int> = []
  private var audioListener: AudioObjectPropertyListenerBlock?
  private var lastOutput: AudioObjectID?
  /// 正在读刚连上的那副耳机的电量
  private var batteryRead: Task<Void, Never>?
  private var pathMonitor: NWPathMonitor?
  /// 网络通不通（最后一次稳住的）；第一次读到时只记下
  private var online: Bool?
  private var networkSettle: Task<Void, Never>?

  init(island: Island, defaults: UserDefaults = .standard) {
    self.island = island
    self.defaults = defaults
  }

  /// 照偏好起停（启动时、偏好变了时 AppDelegate 调）：开着的才监听，没变不动
  func apply() {
    // 归刘海岛插件（2026-11-13 插件化 P1b）：没添加时一样都不听，开关照旧记着
    let added =
      defaults.object(forKey: Feature.island.prefsKey) as? Bool ?? Feature.island.defaultOn
    let power =
      added
      && (defaults.bool(forKey: Prefs.islandNoticePower)
        || defaults.bool(forKey: Prefs.islandNoticeBattery))
    if power, powerSource == nil { startPower() } else if !power, powerSource != nil { stopPower() }
    let headphones = added && defaults.bool(forKey: Prefs.islandNoticeHeadphones)
    if headphones, audioListener == nil {
      startAudio()
    } else if !headphones, audioListener != nil {
      stopAudio()
    }
    let network = added && defaults.bool(forKey: Prefs.islandNoticeNetwork)
    if network, pathMonitor == nil {
      startNetwork()
    } else if !network, pathMonitor != nil {
      stopNetwork()
    }
  }

  // MARK: 电源

  private func startPower() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard
      let source = IOPSNotificationCreateRunLoopSource(
        { context in
          // 加在主线程的 run loop 上：回调就在主线程
          guard let context else { return }
          MainActor.assumeIsolated {
            Unmanaged<SystemNotices>.fromOpaque(context).takeUnretainedValue().powerChanged()
          }
        }, context)?.takeRetainedValue()
    else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    powerSource = source
    lastPower = Self.readPower()
  }

  private func stopPower() {
    if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    powerSource = nil
    lastPower = nil
    warned = []
  }

  private func powerChanged() {
    guard let now = Self.readPower() else { return }
    defer { lastPower = now }
    if now.plugged { warned = [] }
    if let last = lastPower, last.plugged != now.plugged,
      defaults.bool(forKey: Prefs.islandNoticePower)
    {
      let level = Self.powerLevel(plugged: now.plugged, percent: now.percent, low: false)
      let spoken = now.plugged ? "已接上电源" : "已拔掉电源"
      island?.showNotice(level, fallback: "\(spoken) \(now.percent)%")
      Island.announce("\(spoken)，电量 \(now.percent)%")
    }
    if defaults.bool(forKey: Prefs.islandNoticeBattery),
      let threshold = Self.lowBattery(
        percent: now.percent, plugged: now.plugged, warned: warned)
    {
      warned.insert(threshold)
      island?.showNotice(
        Self.powerLevel(plugged: false, percent: now.percent, low: true),
        fallback: "电量还剩 \(now.percent)%")
      Island.announce("电量低，还剩 \(now.percent)%")
    }
  }

  /// 电源的提示怎么画（纯函数；2026-11-14 照 Alcove：贴在刘海两边，左边一句话、右边百分比 + 电池）：接着电源是
  /// 绿的「充电中」（满了是「已充满」），拔掉是白的「电池供电」，电量低是红的「电量低」。多出一会儿（5 秒，同它）
  static func powerLevel(plugged: Bool, percent: Int, low: Bool) -> Island.Level {
    Island.Level(
      kind: .device, fraction: Double(min(max(percent, 0), 100)) / 100,
      caption: low ? "电量低" : plugged ? (percent >= 100 ? "已充满" : "充电中") : "电池供电",
      tone: low ? .low : plugged ? .good : .plain, stay: .seconds(5))
  }

  /// 该提醒低电量的门槛（纯函数）：没接电源、电量到了 20 / 10 以下、这一轮放电里还没提醒过；两个都到了只说低的那个
  static func lowBattery(percent: Int, plugged: Bool, warned: Set<Int>) -> Int? {
    guard !plugged else { return nil }
    return [10, 20].first { percent <= $0 && !warned.contains($0) }
  }

  /// 内建电池（没有电池的 Mac 是 nil）：接没接电源、电量百分比
  private static func readPower() -> (plugged: Bool, percent: Int)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in list {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = description[kIOPSCurrentCapacityKey] as? Int,
        let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
      else { continue }
      let plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
      return (plugged, Int((Double(current) / Double(max) * 100).rounded()))
    }
    return nil
  }

  // MARK: 耳机

  private static let defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  private func startAudio() {
    lastOutput = Self.defaultOutput()
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      // 投在主队列上：回调就在主线程
      MainActor.assumeIsolated { self?.outputChanged() }
    }
    var address = Self.defaultOutputAddress
    guard
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr
    else { return }
    audioListener = listener
  }

  private func stopAudio() {
    if let audioListener {
      var address = Self.defaultOutputAddress
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, audioListener)
    }
    audioListener = nil
    lastOutput = nil
    batteryRead?.cancel()
    batteryRead = nil
  }

  private func outputChanged() {
    guard let device = Self.defaultOutput(), device != lastOutput else { return }
    lastOutput = device
    let transport = Self.transport(of: device)
    guard Self.isHeadphones(transport: transport) else { return }
    // 贴在刘海两边（同音量提示）：左边耳机的图标 + 「已连接」，右边电量。先出、电量读到了原地补上
    let name = Self.name(of: device)
    let address = Self.uid(of: device).flatMap(Headphones.address(fromUID:))
    var level = Island.Level(
      kind: .device, fraction: -1, label: name, glyph: Headphones.symbol(named: name),
      stay: .seconds(3))
    island?.showNotice(level, fallback: "已连上\(name ?? "耳机")")
    Island.announce("已连上\(name ?? "耳机")")
    batteryRead?.cancel()
    // 电量只有蓝牙耳机有（USB 的没有地址，按名字去找会认成同名的别的蓝牙设备）
    guard transport != kAudioDeviceTransportTypeUSB else { return }
    batteryRead = Task { [weak self] in
      // 刚连上的那一下系统多半还没拿到电量：读不到就过一会儿再读一次
      for wait in [Duration.zero, .milliseconds(1200)] {
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled, let self, self.lastOutput == device else { return }
        guard let battery = await Headphones.battery(address: address, name: name)?.level
        else { continue }
        guard !Task.isCancelled, self.lastOutput == device else { return }
        level.fraction = battery
        level.tone = battery <= 0.2 ? .low : .good
        // 提示还出着（或者正等着出）就原地补上；已经收了、换成别的了就不再弹一遍
        self.island?.updateLevel(level)
        return
      }
    }
  }

  /// 算不算耳机（纯函数）：蓝牙（AirPods 这类）、USB 的输出设备。内建的（扬声器、耳机孔）、显示器、隔空播放不算
  // ponytail: 插在内建耳机孔上的有线耳机不说（要另读数据源 'hdpn'）；真有人要再加
  static func isHeadphones(transport: UInt32?) -> Bool {
    guard let transport else { return false }
    return [
      kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
      kAudioDeviceTransportTypeUSB,
    ].contains(transport)
  }

  private static func defaultOutput() -> AudioObjectID? {
    var address = defaultOutputAddress
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != 0 ? device : nil
  }

  private static func transport(of device: AudioObjectID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var transport = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
      ? transport : nil
  }

  private static func name(of device: AudioObjectID) -> String? {
    string(of: device, kAudioObjectPropertyName)
  }

  /// 音频设备的编号（蓝牙耳机的里面带着蓝牙地址，Headphones.address(fromUID:)）
  private static func uid(of device: AudioObjectID) -> String? {
    string(of: device, kAudioDevicePropertyDeviceUID)
  }

  private static func string(
    of device: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &name) {
      AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { return nil }
    return name?.takeRetainedValue() as String?
  }

  // MARK: 网络

  /// 网络状态要稳住这么久才算（醒来、换 Wi-Fi 时会断一下又好）
  static let networkSettleTime = Duration.seconds(3)

  private func startNetwork() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      // 投在主队列上：回调就在主线程
      MainActor.assumeIsolated { self?.networkChanged(satisfied) }
    }
    monitor.start(queue: .main)
    pathMonitor = monitor
  }

  private func stopNetwork() {
    pathMonitor?.cancel()
    pathMonitor = nil
    networkSettle?.cancel()
    online = nil
  }

  private func networkChanged(_ satisfied: Bool) {
    networkSettle?.cancel()
    // 第一次读到：只记下
    guard let online else {
      self.online = satisfied
      return
    }
    guard satisfied != online else { return }
    networkSettle = Task { [weak self] in
      try? await Task.sleep(for: Self.networkSettleTime)
      guard let self, !Task.isCancelled else { return }
      self.online = satisfied
      if satisfied {
        self.island?.show("网络已恢复", tone: .success, symbol: "wifi")
      } else {
        self.island?.show("网络断开了", tone: .warning, symbol: "wifi.slash")
      }
    }
  }
}
