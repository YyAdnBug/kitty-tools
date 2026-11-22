// 插件要的一项授权画成一行（2026-11-17 插件页改版 C1 C2，PLAN §10「插件页改版」）：24 pt 色块 + 授权的名字 + 这个插件
// 为什么要它（Shell/Plugin.swift 的 PluginPermission），右边是状态。和通用 › 权限的 PermissionRow 同一个样子；
// 介绍页（还没添加）只写状态，给了 grant 的（插件自己页的「权限」组）没给时带「去授权」。每种授权的名字和色块也在这里。

import SwiftUI

struct PluginPermissionRow: View {
  let permission: PluginPermission
  /// 这台给没给；nil = 查不了（自动化按 App 各问各的）
  let granted: Bool?
  /// 「去授权」；nil = 只写状态（介绍页）
  var grant: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      KindTile(symbol: permission.kind.symbol, color: permission.kind.color, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(plain: permission.kind.name)
        // 11 pt：和系统画的行副标题同一个字号
        Text(plain: permission.reason).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let granted, granted || grant != nil {
        PermissionStatus(granted: granted, button: permission.kind.grantTitle) { grant?() }
      } else if granted == false {
        Text(permission.kind == .finderExtension ? "还没打开" : "还没允许").foregroundStyle(.secondary)
      } else {
        Text("用到时系统会问").foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

extension Permissions.Kind {
  /// 授权的名字（系统设置里那一项的叫法）
  var name: LocalizedStringResource {
    switch self {
    case .accessibility: "辅助功能"
    case .screenRecording: "屏幕录制"
    case .filesAndFolders: "文件和文件夹"
    case .automation: "自动化"
    case .fullDiskAccess: "完全磁盘访问权限"
    case .microphone: "麦克风"
    case .calendar: "日历"
    case .bluetooth: "蓝牙"
    case .finderExtension: "访达扩展"
    case .inputMonitoring: "输入监听"
    }
  }

  /// 只能去系统设置里打开的（系统不给本 App 弹框问）：添加插件时缺这几样就跳到它自己的设置页（插件页改版 C3）
  var grantsInSettings: Bool {
    [.accessibility, .screenRecording, .finderExtension, .inputMonitoring].contains(self)
  }

  /// 没给时那个按钮上的字（同通用 › 权限；访达扩展是去系统设置里自己打开）
  var grantTitle: LocalizedStringResource { self == .finderExtension ? "去打开…" : "去授权" }

  var symbol: String {
    switch self {
    case .accessibility: "hand.raised.fill"
    case .screenRecording: HotKeyAction.screenRecord.symbol
    case .filesAndFolders: "folder.fill"
    case .automation: "gearshape.2.fill"
    case .fullDiskAccess: "internaldrive.fill"
    case .microphone: "mic.fill"
    case .calendar: "calendar"
    case .bluetooth: SettingsPage.bluetoothSnooze.symbol
    case .finderExtension: "puzzlepiece.extension.fill"
    case .inputMonitoring: "keyboard"
    }
  }

  var color: Color {
    switch self {
    case .accessibility: Style.Family.command
    case .screenRecording, .microphone: Style.Family.screenshot
    case .filesAndFolders: Style.Family.clipboard
    case .automation, .fullDiskAccess: Style.Family.general
    case .calendar: Style.Family.reminders
    case .bluetooth: Style.Family.bluetoothSnooze
    case .finderExtension: Style.Family.finderMenu
    case .inputMonitoring: Style.Family.keyboard
    }
  }
}
