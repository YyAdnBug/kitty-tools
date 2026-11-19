// 设置 › App 快捷键（插件，2026-11-17 拍板 G1，PLAN §10「App 快捷键」）。页头由 SettingsRoot 画（家族色键盘橙）。三组（缺辅助功能时
// 「权限」在最上面，插件页改版 C2）：
// 「App 快捷键」——按住一个键叫出来（开关）、按哪个键（⌘ ⌥ ⌃ ⇧，默认 ⌘；2026-11-18 用户要能换）、按住多久（0.6 / 1 / 2 秒），
//   页脚说怎么用、只列菜单里的；
// 「权限」——辅助功能（PluginPermissionSection；没有它按住 ⌘ 听不到、菜单也读不了）；
// 最后「关于这个插件」（后台、同步、移除）。行为在 AppShortcuts/。

import SwiftUI

struct AppShortcutsTab: View {
  /// 截图自检传固定的；正常是 nil = 现问
  var trusted: Bool?
  /// 设置窗重新当 key 时 +1：「权限」组重查（从系统设置授权回来，同程序坞预览）
  @State private var accessChecks = 0
  @AppStorage(Prefs.appShortcutsHold) private var hold = true
  @AppStorage(Prefs.appShortcutsDelay) private var delay = 1000
  @AppStorage(Prefs.appShortcutsHoldKey) private var holdKey = ModifierTaps.Key.command.rawValue

  var body: some View {
    form.onSettingsBecameKey { accessChecks += 1 }
  }

  private var form: some View {
    Form {
      permissions(at: .top)
      Section {
        Toggle(isOn: $hold) {
          Text("按住一个键叫出来")
          Text("只按着这一个键、不按别的键；按着时按了别的键、点了鼠标就不弹")
        }
        .gated(by: .appShortcuts)
        .settingsAnchor(.appShortcutsHold)
        // 导入的文件写了别的值时选择器显示成 ⌘（同读的地方）
        Picker(
          selection: Binding {
            AppShortcuts.holdKey(holdKey)
          } set: {
            holdKey = $0.rawValue
          }
        ) {
          ForEach(ModifierTaps.Key.allCases, id: \.self) { key in
            Text(verbatim: "\(key.symbol) \(Self.keyName(key))").tag(key)
          }
        } label: {
          Text("按哪个键")
          if AppShortcuts.holdKey(holdKey) == .shift {
            Text("中文输入法里单按 ⇧ 会切中英文，按住松开时可能也切")
          }
        }
        .gated(by: .appShortcuts)
        .disabled(!hold)
        .settingsAnchor(.appShortcutsKey)
        // 导入的文件写了别的数时选择器显示成 1 秒（同读的地方）
        Picker(
          "按住多久",
          selection: Binding {
            AppShortcuts.delay(delay)
          } set: {
            delay = $0
          }
        ) {
          ForEach(AppShortcuts.delayChoices, id: \.self) { milliseconds in
            Text(DockPreviewTab.title(milliseconds)).tag(milliseconds)
          }
        }
        .gated(by: .appShortcuts)
        .disabled(!hold)
        .settingsAnchor(.appShortcutsDelay)
      } header: {
        InfoHeader(
          "App 快捷键",
          info:
            "弹出前台 App 菜单栏里的全部快捷键，按菜单分组。按着那个键再按别的键，这一下照常给 App、面板收起；松开就收起。只列 App 菜单里的快捷键，网页和编辑器里自己定义的看不到。"
        )
      }
      permissions(at: .bottom)
      PluginAboutSection(plugin: .appShortcuts)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
  }

  /// 键的名字（键盘上印的那个，中英一样，不翻）
  static func keyName(_ key: ModifierTaps.Key) -> String {
    switch key {
    case .command: "Command"
    case .option: "Option"
    case .control: "Control"
    case .shift: "Shift"
    }
  }

  /// 「权限」组（辅助功能）；没给时画在最上面
  private func permissions(at placement: PluginPermissionPlacement) -> some View {
    PluginPermissionSection(
      plugin: .appShortcuts, at: placement, checks: accessChecks,
      granted: trusted.map { value in { (_: Permissions.Kind) -> Bool? in value } })
  }
}
