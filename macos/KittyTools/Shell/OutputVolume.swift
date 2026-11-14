// 系统输出音量（刘海岛播放卡片上的音量滑杆，2026-11-13 以 Alcove 为准的那一轮 B3）：默认输出设备的音量读写、它是哪类
// 设备（卡片右上角那个图标）。公开的 CoreAudio，不要授权、不拦按键——按音量键照旧是系统自己的提示。
// 不挂监听：只在滑杆开着时每秒读一次（跟上音量键），平时一行都不跑。调不了音量的设备（有的显示器、HDMI）读不到，
// 卡片上就不出那个图标。
// 音量键换成刘海岛上的提示时（MediaKeys，2026-11-14）也用它，而且是在拦截的那条线程上调：所以整个类型 nonisolated
// （只是几个 CoreAudio 的 C 调用，哪条线程都能调），另有静音的读写。
// ponytail: 静音着时拖卡片上的滑杆不解除静音（音量变了、还是没声）；按音量 + 键会解除（同系统）

import AudioToolbox
import CoreAudio

nonisolated enum OutputVolume {
  /// 现在的音量 0…1；没有输出设备、这个设备调不了音量是 nil
  static func read() -> Double? {
    guard let device = device() else { return nil }
    var address = volumeAddress
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var level = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr,
      level.isFinite
    else { return nil }
    return Double(min(max(level, 0), 1))
  }

  /// 设音量（夹进 0…1）；这个设备不让设就什么都不做。返回写进去了没有（设备正在切换时会失败）
  @discardableResult static func set(_ value: Double) -> Bool {
    guard value.isFinite, let device = device() else { return false }
    var address = volumeAddress
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
    else { return false }
    var level = Float32(min(max(value, 0), 1))
    return AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level) == noErr
  }

  /// 这个设备的音量设不设得了（设不了的——有的显示器、HDMI——音量键照旧交给系统）
  static var isSettable: Bool {
    guard let device = device() else { return false }
    var address = volumeAddress
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
  }

  /// 静音着没有；这个设备没有静音这一样是 nil
  static var isMuted: Bool? {
    guard let device = device() else { return nil }
    var address = muteAddress
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var muted = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
      ? muted != 0 : nil
  }

  /// 返回写进去了没有
  @discardableResult static func setMuted(_ muted: Bool) -> Bool {
    guard let device = device() else { return false }
    var address = muteAddress
    var value = UInt32(muted ? 1 : 0)
    return AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
  }

  private static var muteAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  /// 现在这个输出设备的图标
  static func symbol() -> String { symbol(transport: device().flatMap(transport(of:))) }

  /// 设备怎么连的 → 图标（纯函数）：蓝牙是耳机，隔空播放、显示器（HDMI / DisplayPort / 雷雳）、USB 各一个，
  /// 其余（内建的、认不出的）是扬声器
  static func symbol(transport: UInt32?) -> String {
    switch transport {
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
    case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
      kAudioDeviceTransportTypeThunderbolt:
      "display"
    case kAudioDeviceTransportTypeUSB: "hifispeaker.fill"
    default: "speaker.wave.2.fill"
    }
  }

  /// 「虚拟主音量」：系统音量条调的就是它（有的设备只有左右声道各一个音量，它替你合成一个）
  private static var volumeAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
  }

  private static func device() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
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
}
