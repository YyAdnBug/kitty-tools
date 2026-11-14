// 耳机电量的纯函数（Headphones.swift）：从系统报告里找电量、认蓝牙地址、挑图标。不起子进程、不碰本机的蓝牙。

import Foundation
import Testing

@testable import KittyTools

struct HeadphonesTests {
  /// 系统报告的样子（键名照 macOS 上实际的输出；名字、地址是编的）
  private let report = Data(
    """
    {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
     "device_connected":[
       {"编的 AirPods Pro":{"device_address":"AA:BB:CC:DD:EE:01","device_batteryLevelCase":"40%",
         "device_batteryLevelLeft":"85%","device_batteryLevelRight":"62%","device_minorType":"Headphones"}},
       {"编的头戴耳机":{"device_address":"AA:BB:CC:DD:EE:02","device_batteryLevelMain":"100%"}},
       {"没电量的键盘":{"device_address":"AA:BB:CC:DD:EE:03"}},
       {"电量写坏了的":{"device_address":"AA:BB:CC:DD:EE:04","device_batteryLevelMain":"180%"}}],
     "device_not_connected":[
       {"没连着的耳机":{"device_address":"AA:BB:CC:DD:EE:05","device_batteryLevelMain":"50%"}}]}]}
    """.utf8)

  @Test func findsBatteryByAddressThenName() {
    // 按地址找（分隔符、大小写不一样也认）：两只耳朵取低的那只，充电盒不算
    let pods = Headphones.battery(in: report, address: "aa-bb-cc-dd-ee-01", name: nil)
    #expect(pods == Headphones.Battery(left: 0.85, right: 0.62, main: nil) && pods?.level == 0.62)
    // 地址对不上就按名字
    #expect(
      Headphones.battery(in: report, address: "00:00:00:00:00:00", name: "编的头戴耳机")?.level == 1)
    // 地址优先于名字
    #expect(
      Headphones.battery(in: report, address: "AA:BB:CC:DD:EE:02", name: "编的 AirPods Pro")?.level
        == 1)
    // 没有电量的、电量写坏了的、没连着的、找不到的、不是 JSON 的：nil
    #expect(Headphones.battery(in: report, address: "AA:BB:CC:DD:EE:03", name: nil) == nil)
    #expect(Headphones.battery(in: report, address: "AA:BB:CC:DD:EE:04", name: nil) == nil)
    #expect(Headphones.battery(in: report, address: "AA:BB:CC:DD:EE:05", name: "没连着的耳机") == nil)
    #expect(Headphones.battery(in: report, address: nil, name: nil) == nil)
    #expect(Headphones.battery(in: Data("不是 JSON".utf8), address: nil, name: "x") == nil)
  }

  @Test func batteryLevelPicksTheWeakerBud() {
    #expect(Headphones.Battery(left: 0.3, right: nil, main: nil).level == 0.3)
    #expect(Headphones.Battery(left: nil, right: 0.9, main: 0.1).level == 0.9)
    #expect(Headphones.Battery(left: nil, right: nil, main: nil).level == nil)
    #expect(Headphones.percent("0%") == 0 && Headphones.percent("100%") == 1)
    #expect(Headphones.percent("85") == nil && Headphones.percent(85) == nil)
    #expect(Headphones.percent("-5%") == nil && Headphones.percent("abc%") == nil)
  }

  @Test func addressFromAudioDeviceUID() {
    #expect(Headphones.address(fromUID: "aa-bb-cc-dd-ee-01:output") == "AA:BB:CC:DD:EE:01")
    #expect(Headphones.address(fromUID: "AA-BB-CC-DD-EE-01") == "AA:BB:CC:DD:EE:01")
    // 内建扬声器、USB 设备的编号不是这个样子
    #expect(Headphones.address(fromUID: "BuiltInSpeakerDevice") == nil)
    #expect(Headphones.address(fromUID: "AppleUSBAudioEngine:Vendor:Product:1234:1") == nil)
    #expect(Headphones.address(fromUID: "ZZ-BB-CC-DD-EE-01:output") == nil)
  }

  @Test func symbolsAndReading() {
    #expect(Headphones.symbol(named: "yy 的 AirPods Pro") == "airpodspro")
    #expect(Headphones.symbol(named: "AirPods Max") == "airpodsmax")
    #expect(Headphones.symbol(named: "AirPods") == "airpods")
    #expect(Headphones.symbol(named: "Beats Studio") == "beats.headphones")
    #expect(Headphones.symbol(named: "WH-1000XM5") == "headphones")
    #expect(Headphones.symbol(named: nil) == "headphones")
    // 岛上那一条：还没读到电量时是 nil，读到了是 0…1；读屏里念名字和电量
    var level = Island.Level(kind: .device, fraction: -1, label: "AirPods Pro", glyph: "airpodspro")
    #expect(level.battery == nil && level.symbol == "airpodspro" && level.title == "已连接")
    #expect(level.reading.label == "已连接，AirPods Pro" && level.reading.value.isEmpty)
    level.fraction = 0.62
    #expect(level.battery == 0.62 && level.reading.value == "电量 62%")
    #expect(Island.Level(kind: .volume, fraction: 0.5).battery == nil)
    #expect(Island.Level(kind: .volume, fraction: 0.5).reading.value == "50%")
  }

  /// 晚到的电量只补在耳机提示上：出着就原地换，换成音量提示了、收起了就不动；那一张开着时退回成普通的提示排着
  @MainActor @Test func lateBatteryOnlyUpdatesTheDeviceNotice() {
    let notch = Island.Geometry.notch(width: 212, height: 37.5)
    var pods = Island.Level(kind: .device, fraction: -1, label: "AirPods Pro", glyph: "airpodspro")
    let island = Island(showing: nil, geometry: notch)
    island.showNotice(pods, fallback: "已连上AirPods Pro")
    #expect(island.level?.kind == .device && island.level?.battery == nil)
    pods.fraction = 0.85
    island.updateLevel(pods)
    #expect(island.level?.battery == 0.85)
    // 换成了音量提示：晚到的电量不顶掉它
    island.showLevel(Island.Level(kind: .volume, fraction: 0.5))
    island.updateLevel(pods)
    #expect(island.level?.kind == .volume)
    // 收起了：不再弹一遍
    island.dismiss()
    island.updateLevel(pods)
    #expect(island.level == nil && island.content == nil)
    // 耳机的提示出着时来了电源的提示（都是 device，但不是同一条）：晚到的耳机电量不补到电源那一条上
    island.showNotice(pods, fallback: "已连上AirPods Pro")
    island.showLevel(SystemNotices.powerLevel(plugged: true, percent: 40, low: false))
    pods.fraction = 0.5
    island.updateLevel(pods)
    #expect(island.level?.title == "充电中" && island.level?.battery == 0.4)
    island.dismiss()
    // 那一张开着：不顶掉它，排成一条普通的提示
    island.toggleBoard()
    island.showNotice(pods, fallback: "已连上AirPods Pro")
    #expect(island.isBoardOpen && island.level == nil)
  }
}
