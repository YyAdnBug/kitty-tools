// 刘海岛上的系统一瞬提示（2026-11-13，刘海岛扩展 D1）：接上 / 拔掉电源（带电量）、电量低到 20% 和 10%、耳机或 AirPods 连上
// （只写名字）、断网 / 网络恢复。弹一下就走，同别的提示；每种一个开关（设置 › 刘海岛「系统提示」，默认都关），**不开就不监听**。
// 全是公开接口、有变化才通知，空闲 0 CPU、不要授权：电源走 IOKit 的电源通知（IOPSNotificationCreateRunLoopSource，主线程的
// run loop 上回调），耳机走 CoreAudio 的默认输出设备变化（回调投在主队列），网络走 Network 的 NWPathMonitor（主队列）。
// 不做的（拍板 D1）：耳机电量（要蓝牙授权和私有键）、Wi-Fi 的名字（macOS 14 起要定位授权）、摄像头 / 麦克风在用（菜单栏本来就有
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
    let power =
      defaults.bool(forKey: Prefs.islandNoticePower)
      || defaults.bool(forKey: Prefs.islandNoticeBattery)
    if power, powerSource == nil { startPower() } else if !power, powerSource != nil { stopPower() }
    let headphones = defaults.bool(forKey: Prefs.islandNoticeHeadphones)
    if headphones, audioListener == nil {
      startAudio()
    } else if !headphones, audioListener != nil {
      stopAudio()
    }
    let network = defaults.bool(forKey: Prefs.islandNoticeNetwork)
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
      if now.plugged {
        island?.show(
          "已接上电源", detail: "\(now.percent)%", tone: .success, symbol: "bolt.circle.fill")
      } else {
        island?.show("已拔掉电源", detail: "\(now.percent)%", tone: .info, symbol: "powerplug.fill")
      }
    }
    if defaults.bool(forKey: Prefs.islandNoticeBattery),
      let threshold = Self.lowBattery(
        percent: now.percent, plugged: now.plugged, warned: warned)
    {
      warned.insert(threshold)
      island?.show(
        "电量还剩 \(now.percent)%", detail: "接上电源吧", tone: .warning,
        symbol: "battery.25percent")
    }
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
  }

  private func outputChanged() {
    guard let device = Self.defaultOutput(), device != lastOutput else { return }
    lastOutput = device
    guard Self.isHeadphones(transport: Self.transport(of: device)) else { return }
    island?.show("已连上\(Self.name(of: device) ?? "耳机")", tone: .info, symbol: "headphones")
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
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
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
