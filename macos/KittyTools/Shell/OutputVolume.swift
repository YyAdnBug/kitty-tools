// 系统输出音量（刘海岛播放卡片上的音量滑杆，2026-11-13 以 Alcove 为准的那一轮 B3）：默认输出设备的音量读写、它是哪类
// 设备（卡片右上角那个图标）。公开的 CoreAudio，不要授权、不拦按键——按音量键照旧是系统自己的提示。
// 不挂监听：只在滑杆开着时每秒读一次（跟上音量键），平时一行都不跑。调不了音量的设备（有的显示器、HDMI）读不到，
// 卡片上就不出那个图标。
// ponytail: 静音着时拖滑杆不解除静音（音量变了、还是没声）；真有人碰到再读写 kAudioDevicePropertyMute

import AudioToolbox
import CoreAudio

enum OutputVolume {
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

  /// 设音量（夹进 0…1）；这个设备不让设就什么都不做
  static func set(_ value: Double) {
    guard value.isFinite, let device = device() else { return }
    var address = volumeAddress
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
    else { return }
    var level = Float32(min(max(value, 0), 1))
    _ = AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
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
