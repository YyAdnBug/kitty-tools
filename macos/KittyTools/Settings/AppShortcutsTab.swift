// 设置 › App 快捷键（插件，2026-11-17 拍板 G1，PLAN §10「App 快捷键」）。页头由 SettingsRoot 画（家族色键盘橙）。三组（缺辅助功能时
// 「权限」在最上面，插件页改版 C2）：
// 「App 快捷键」——按住 ⌘ 叫出来（开关）、按住多久（0.6 / 1 / 2 秒），页脚说怎么用、只列菜单里的；
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

  var body: some View {
    form.onSettingsBecameKey { accessChecks += 1 }
  }

  private var form: some View {
    Form {
      permissions(at: .top)
      Section {
        Toggle(isOn: $hold) {
          Text("按住 ⌘ 叫出来")
          Text("只按着 ⌘、不按别的键；按着时按了别的键、点了鼠标就不弹")
        }
        .gated(by: .appShortcuts)
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
      } header: {
        Text("App 快捷键")
      } footer: {
        SectionFootnote(
          "弹出前台 App 菜单栏里的全部快捷键，按菜单分组。按着 ⌘ 再按别的键，就是那个快捷键；松开 ⌘ 就收起。只列 App 菜单里的快捷键，网页和编辑器里自己定义的看不到。")
      }
      permissions(at: .bottom)
      PluginAboutSection(plugin: .appShortcuts)
    }
    .formStyle(.grouped)
  }

  /// 「权限」组（辅助功能）；没给时画在最上面
  private func permissions(at placement: PluginPermissionPlacement) -> some View {
    PluginPermissionSection(
      plugin: .appShortcuts, at: placement, checks: accessChecks,
      granted: trusted.map { value in { (_: Permissions.Kind) -> Bool? in value } })
  }
}
