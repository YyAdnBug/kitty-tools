// 设置 › 睡眠关蓝牙（插件，2026-11-17，PLAN §10「睡眠关蓝牙」）。页头由 SettingsRoot 画（家族色午夜蓝）。三组（缺蓝牙授权时「权限」在最上面）：
// 「睡眠关蓝牙」——两个开关（对标 Vorssaint「睡眠时的蓝牙」：添加插件就是它的「睡眠时关闭蓝牙」）：只在合上盖子时关（默认开）、
//   醒来时重新打开蓝牙（默认开，只打开睡前自己关掉的），和上次关、开的时刻；页脚说接着外接显示器时不关；
// 「权限」——蓝牙（PluginPermissionSection；没授权时这个插件什么都不做，缺的时候排到最上面）；
// 最后「关于这个插件」（后台、同步、移除）。行为在 BluetoothSnooze/BluetoothSnooze.swift。

import SwiftUI

struct BluetoothSnoozeTab: View {
  /// 「去授权」：没问过弹系统框，问过了开系统设置（BluetoothSnooze.requestAccess）
  let requestAccess: () -> Void
  /// 截图自检传固定的；正常是 nil = 现问
  var authorized: Bool?
  /// 设置窗重新当 key 时 +1：「权限」组重查（从系统设置授权回来，同程序坞预览）
  @State private var accessChecks = 0
  @AppStorage(Prefs.bluetoothSnoozeLidOnly) private var lidOnly = true
  @AppStorage(Prefs.bluetoothSnoozeReopen) private var reopen = true
  @AppStorage(Prefs.bluetoothSnoozeHeld) private var held = false
  @AppStorage(Prefs.bluetoothSnoozeOffAt) private var offAt = 0.0
  @AppStorage(Prefs.bluetoothSnoozeOnAt) private var onAt = 0.0

  var body: some View {
    // 从系统设置授权回来，设置窗重新当 key 时刷新（同程序坞预览）
    form.onSettingsBecameKey { accessChecks += 1 }
  }

  private var form: some View {
    Form {
      permissions(at: .top)
      Section {
        Toggle(isOn: $lidOnly) {
          Text("只在合上盖子时关")
          Text(lidOnly ? "开着盖子睡着时不关，蓝牙键盘鼠标照样能叫醒电脑" : "每次睡眠都关：开着盖子时只能用电脑自己的键盘、触控板叫醒它")
        }
        .gated(by: .bluetoothSnooze)
        Toggle(isOn: $reopen) {
          Text("醒来时重新打开蓝牙")
          Text("只打开睡前由 Kitty Tools 关掉的；本来就关着的不会被打开")
        }
        .gated(by: .bluetoothSnooze)
        LabeledContent(
          "上次", value: Self.history(held: held, reopen: reopen, offAt: offAt, onAt: onAt))
      } header: {
        Text("睡眠关蓝牙")
      } footer: {
        SectionFootnote(
          lidOnly
            ? "电脑睡下去时关掉蓝牙：放进包里不会被蓝牙鼠标、键盘弄醒，睡着的 Mac 也不会抢走手机连着的耳机。接着外接显示器时不关；关机不管。开着盖子先睡着、之后才合上的那一次不关。"
            : "电脑睡下去时关掉蓝牙：放进包里不会被蓝牙鼠标、键盘弄醒，睡着的 Mac 也不会抢走手机连着的耳机。接着外接显示器时不关；关机不管。")
      }
      permissions(at: .bottom)
      PluginAboutSection(plugin: .bluetoothSnooze)
    }
    .formStyle(.grouped)
  }

  /// 「权限」组（蓝牙）；没给时画在最上面（插件页改版 C2）。「去授权」：没问过弹系统框，问过了开系统设置
  private func permissions(at placement: PluginPermissionPlacement) -> some View {
    PluginPermissionSection(
      plugin: .bluetoothSnooze, at: placement, checks: accessChecks,
      granted: authorized.map { value in { (_: Permissions.Kind) -> Bool? in value } },
      grant: { _ in requestAccess() },
      footer: {
        SectionFootnote(
          "醒来后蓝牙键盘鼠标、耳机要几秒到几十秒才重新连上。睡着时蓝牙关着，用手表解锁这台 Mac、靠蓝牙的「查找」都用不了。")
      })
  }

  /// 「上次」那一行：还关着 / 关、开的时刻 / 还没关过（纯函数）
  static func history(held: Bool, reopen: Bool, offAt: Double, onAt: Double) -> String {
    guard offAt > 0 else { return String(localized: "还没关过") }
    let off = Date(timeIntervalSince1970: offAt).formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened))
    if held {
      return reopen
        ? String(localized: "\(off) 关掉，醒来会打开") : String(localized: "\(off) 关掉，醒来不会自动打开")
    }
    guard onAt >= offAt else { return String(localized: "\(off) 关掉") }
    let onDate = Date(timeIntervalSince1970: onAt)
    let sameDay = Calendar.current.isDate(Date(timeIntervalSince1970: offAt), inSameDayAs: onDate)
    let on = onDate.formatted(
      sameDay ? .dateTime.hour().minute() : Date.FormatStyle(date: .abbreviated, time: .shortened))
    return String(localized: "\(off) 关掉，\(on) 打开")
  }
}
