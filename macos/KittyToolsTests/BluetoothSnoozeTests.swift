// 睡眠关蓝牙（插件，2026-11-17）：什么时候关的判断、设置页「上次」那一行、插件的登记。
// 不调私有接口、不弹授权框、不碰蓝牙（真的开关蓝牙只在真机手测，HANDTEST「睡眠关蓝牙手测」）。

import Foundation
import Testing

@testable import KittyTools

struct BluetoothSnoozeTests {
  /// 只在合盖时关（默认）：只有合上盖子、没接外接显示器、蓝牙开着才关；关掉它：开着盖子也关；外接显示器一律不关；本来关着的不碰
  @Test func whenToTurnOff() {
    let check = BluetoothSnooze.shouldTurnOff
    #expect(check(true, true, false, true))
    #expect(!check(true, false, false, true))
    #expect(!check(true, true, true, true))
    #expect(!check(true, true, false, false))
    #expect(check(false, false, false, true))
    #expect(check(false, true, false, true))
    #expect(!check(false, false, true, true))
    #expect(!check(false, true, false, false))
  }

  /// 「上次」那一行：没关过 / 还关着 / 关了没记到开 / 同一天只写开的时刻
  @Test func history() {
    let off = Date(timeIntervalSince1970: 1_800_000_000)
    let on = off.addingTimeInterval(1800)
    let history = BluetoothSnoozeTab.history
    #expect(history(false, true, 0, 0) == "还没关过")
    let offText = off.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
    #expect(history(true, true, off.timeIntervalSince1970, 0) == "\(offText) 关掉，醒来会打开")
    #expect(history(true, false, off.timeIntervalSince1970, 0) == "\(offText) 关掉，醒来不会自动打开")
    #expect(history(false, true, off.timeIntervalSince1970, 0) == "\(offText) 关掉")
    #expect(
      history(false, true, off.timeIntervalSince1970, on.timeIntervalSince1970)
        == "\(offText) 关掉，\(on.formatted(.dateTime.hour().minute())) 打开")
  }

  /// 插件、默认不添加、开关不同步（要这台的蓝牙授权）；有没有跟着这台 Mac；Info.plist 写了蓝牙的用途说明
  /// （macOS 26 起没写的 App 一碰蓝牙就被系统杀掉）
  @Test func registration() {
    let plugin = Feature.bluetoothSnooze
    #expect(plugin.isPlugin && !plugin.defaultOn)
    #expect(plugin.pluginBackground != nil && plugin.pluginWords.contains("蓝牙"))
    #expect(plugin.isAvailable == BluetoothSnooze.isSupported)
    #expect(SettingsSync.localKeys.contains(plugin.prefsKey))
    #expect(Prefs.defaults[Prefs.bluetoothSnoozeHeld] == nil)
    #expect(Prefs.defaults[Prefs.bluetoothSnoozeLidOnly] as? Bool == true)
    #expect(Prefs.defaults[Prefs.bluetoothSnoozeReopen] as? Bool == true)
    let usage = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription")
    #expect((usage as? String)?.isEmpty == false)
  }
}
