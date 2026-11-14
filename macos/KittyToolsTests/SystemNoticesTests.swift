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

  /// 电源的提示：接着电源是绿的「充电中」（满了「已充满」），拔掉是白的「电池供电」，电量低是红的；都出 5 秒
  @Test func powerNoticeLevels() {
    let charging = SystemNotices.powerLevel(plugged: true, percent: 99, low: false)
    #expect(charging.kind == .device && charging.title == "充电中" && charging.tone == .good)
    #expect(charging.battery == 0.99 && charging.glyph == nil && charging.stay == .seconds(5))
    #expect(SystemNotices.powerLevel(plugged: true, percent: 100, low: false).title == "已充满")
    let unplugged = SystemNotices.powerLevel(plugged: false, percent: 64, low: false)
    #expect(unplugged.title == "电池供电" && unplugged.tone == .plain && unplugged.battery == 0.64)
    let low = SystemNotices.powerLevel(plugged: false, percent: 9, low: true)
    #expect(low.title == "电量低" && low.tone == .low)
    // 百分比夹在 0…100
    #expect(SystemNotices.powerLevel(plugged: true, percent: 140, low: false).battery == 1)
    // 不是同一条：换的时候糊着进出，晚到的耳机电量不会补到电源的提示上
    #expect(charging.identity != unplugged.identity)
    // 电池的符号分五档
    #expect(IslandBattery.symbol(0.05) == "battery.0percent")
    #expect(IslandBattery.symbol(0.3) == "battery.25percent")
    #expect(IslandBattery.symbol(0.5) == "battery.50percent")
    #expect(IslandBattery.symbol(0.8) == "battery.75percent")
    #expect(IslandBattery.symbol(0.99) == "battery.100percent")
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
