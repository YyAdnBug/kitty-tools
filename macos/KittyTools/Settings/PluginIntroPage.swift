// 设置 › 全部插件 › 一个插件的介绍（2026-11-17 插件页改版 A5，PLAN §10「插件页改版」）：没添加的插件点进来看到的那一页，
// 启动器「添加…插件」也带到这里（G1）。页头（色块、名字、一句话）下面：「添加」那一行、能做什么（两三条）、怎么用（一句 +
// 它的全局动作和现在的键，自动列）、要的授权（一项一行，现查这台给没给）、关于（后台、同步）。不放截图（拍板 A5）。
// 添加了以后这一页留着，那一行换成「已添加」+「打开设置」。声明都在 Shell/Plugin.swift。

import SwiftUI

struct PluginIntroPage: View {
  let plugin: Feature
  /// 截图自检给定的：各项授权给没给（nil = 现查）
  var granted: ((Permissions.Kind) -> Bool?)?
  @AppStorage private var isAdded: Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  /// 设置窗重新当 key 时重查授权（从系统设置回来）
  @State private var checks = 0

  init(plugin: Feature, granted: ((Permissions.Kind) -> Bool?)? = nil) {
    self.plugin = plugin
    self.granted = granted
    _isAdded = AppStorage(wrappedValue: plugin.defaultOn, plugin.prefsKey)
  }

  /// 它的全局动作（快捷键页里归它的那几个）
  private var actions: [HotKeyAction] { HotKeyAction.allCases.filter { $0.feature == plugin } }

  var body: some View {
    VStack(spacing: 0) {
      DetailHeader(title: plugin.page.titleResource, status: plugin.blurbResource) {
        KindTile(symbol: plugin.page.symbol, color: plugin.page.color, size: 40)
      }
      Form {
        Section {
          LabeledContent {
            if isAdded {
              Button("打开设置") { navigation?.page = plugin.page }
            } else {
              Button("添加") { PluginsPage.add(plugin, navigation: navigation) }
                .buttonStyle(BrandButtonStyle())
            }
          } label: {
            Text(isAdded ? "已添加" : "这个插件还没添加")
            Text(
              isAdded
                ? "移除在它自己那一页的最下面；移除了设置和数据都留着"
                : "添加了才出现在菜单栏、主界面、快捷键和启动器里")
          }
        }
        Section("能做什么") {
          ForEach(Array(plugin.pluginPoints.enumerated()), id: \.offset) { _, point in
            Text(plain: point)
          }
        }
        Section("怎么用") {
          if let howTo = plugin.pluginHowTo { Text(plain: howTo) }
          ForEach(actions, id: \.self) { action in
            LabeledContent(action.title) {
              if let hotKey = action.hotKey {
                KeyCombo(hotKey.display)
              } else {
                Text("未设置").foregroundStyle(.tertiary)
              }
            }
          }
        }
        if !plugin.pluginPermissions.isEmpty {
          Section("要的授权") {
            ForEach(Array(plugin.pluginPermissions.enumerated()), id: \.offset) { _, permission in
              PluginPermissionRow(
                permission: permission, granted: (granted ?? { $0.isGranted })(permission.kind))
            }
          }
          .id(checks)
        }
        Section("关于") {
          // 长句写成那一行的副标题（同设置页的说明文字），不挤在右边
          if let background = plugin.pluginBackground {
            LabeledContent {
            } label: {
              Text("后台")
              Text(plain: background)
            }
          }
          LabeledContent {
          } label: {
            Text("同步")
            Text(
              plugin.syncsAddition ? "在一台 Mac 上添加，同步的几台都添加" : "只在这台 Mac 上添加，不跟着同步")
          }
        }
      }
      .formStyle(.grouped)
    }
    .navigationTitle(plugin.title)
    .toolbar { SettingsBackButton { dismiss() } }
    .onSettingsBecameKey { checks += 1 }
  }
}
