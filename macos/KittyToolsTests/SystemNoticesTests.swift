// 刘海岛上的系统一瞬提示（2026-11-13，刘海岛扩展 D1）：低电量提醒哪个门槛、哪些输出设备算耳机。不起任何监听。

import CoreAudio
import Testing

@testable import KittyTools

@MainActor
struct SystemNoticesTests {
  /// 没接电源、降到 20 / 10 以下、这一轮还没说过才说；一下掉到 10 以下只说 10；接着电源不说
  @Test func lowBatteryThresholds() {
    #expect(SystemNotices.lowBattery(percent: 35, plugged: false, warned: []) == nil)
    #expect(SystemNotices.lowBattery(percent: 20, plugged: false, warned: []) == 20)
    #expect(SystemNotices.lowBattery(percent: 18, plugged: false, warned: [20]) == nil)
    #expect(SystemNotices.lowBattery(percent: 9, plugged: false, warned: [20]) == 10)
    #expect(SystemNotices.lowBattery(percent: 8, plugged: false, warned: []) == 10)
    #expect(SystemNotices.lowBattery(percent: 8, plugged: false, warned: [10, 20]) == nil)
    #expect(SystemNotices.lowBattery(percent: 5, plugged: true, warned: []) == nil)
  }

  /// 蓝牙、USB 的输出设备算耳机；内建的、显示器、隔空播放、读不出来的不算
  @Test func headphoneTransports() {
    #expect(SystemNotices.isHeadphones(transport: kAudioDeviceTransportTypeBluetooth))
    #expect(SystemNotices.isHeadphones(transport: kAudioDeviceTransportTypeBluetoothLE))
    #expect(SystemNotices.isHeadphones(transport: kAudioDeviceTransportTypeUSB))
    #expect(!SystemNotices.isHeadphones(transport: kAudioDeviceTransportTypeBuiltIn))
    #expect(!SystemNotices.isHeadphones(transport: kAudioDeviceTransportTypeDisplayPort))
    #expect(!SystemNotices.isHeadphones(transport: kAudioDeviceTransportTypeAirPlay))
    #expect(!SystemNotices.isHeadphones(transport: nil))
  }
}
