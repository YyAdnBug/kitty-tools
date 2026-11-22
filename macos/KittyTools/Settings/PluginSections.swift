// 插件自己设置页里统一的两组（2026-11-17 插件页改版第 3 批，PLAN §10「插件页改版」）：
// - 「权限」（C1 C2）：按 Shell/Plugin.swift 的声明一项一行（PluginPermissionRow，没给时带「去授权」），设置窗重新当 key 时重查。
//   一页里放两个（at: .top 和 .bottom）：缺授权时上面那个画、下面那个不画，给了以后反过来——缺的时候排到最上面。重查靠页面：
//   页面在设置窗重新当 key 时把 checks +1 传进来（两个位置一起重算）。
//   只有「添加了就要」的授权才进这一组；刘海岛那几项挂在各自的开关下面（打开开关才要），不在这里重复。
// - 「关于这个插件」（B1）：后台做什么、添加状态跟不跟同步，和「移除」（原来页底只有移除那一组，PluginRemoveSection）。

import SwiftUI

/// 「权限」组画在页里的哪个位置（缺授权时用上面那个）
enum PluginPermissionPlacement { case top, bottom }

struct PluginPermissionSection<Footer: View>: View {
  let plugin: Feature
  let placement: PluginPermissionPlacement
  /// 页面在设置窗重新当 key 时 +1（从系统设置回来重查）
  let checks: Int
  /// 截图自检给定的：各项给没给（nil = 现查）
  let granted: ((Permissions.Kind) -> Bool?)?
  /// 「去授权」时本 App 要做的；nil = Permissions.grant（辅助功能、屏幕录制没问过先弹系统框，别的打开系统设置那一页）
  let grant: ((Permissions.Kind) -> Void)?
  let footer: () -> Footer

  init(
    plugin: Feature, at placement: PluginPermissionPlacement, checks: Int,
    granted: ((Permissions.Kind) -> Bool?)? = nil, grant: ((Permissions.Kind) -> Void)? = nil,
    @ViewBuilder footer: @escaping () -> Footer
  ) {
    self.plugin = plugin
    self.placement = placement
    self.checks = checks
    self.granted = granted
    self.grant = grant
    self.footer = footer
  }

  private var permissions: [PluginPermission] {
    plugin.pluginPermissions.filter { $0.option == nil }
  }

  /// 现查（几项，跨进程问系统；这一页的父视图只在设置窗当 key、页里的开关变了时重画）
  private func isGranted(_ kind: Permissions.Kind) -> Bool? {
    (granted ?? { $0.isGranted })(kind)
  }

  /// 这一组此刻缺不缺（缺的时候画在上面那个位置）
  private var lacking: Bool { permissions.contains { isGranted($0.kind) == false } }

  var body: some View {
    if !permissions.isEmpty, lacking == (placement == .top) {
      Section {
        ForEach(Array(permissions.enumerated()), id: \.offset) { _, permission in
          PluginPermissionRow(permission: permission, granted: isGranted(permission.kind)) {
            (grant ?? Permissions.grant)(permission.kind)
          }
        }
      } header: {
        Text("权限")
      } footer: {
        footer()
      }
    }
  }
}

extension PluginPermissionSection where Footer == EmptyView {
  init(
    plugin: Feature, at placement: PluginPermissionPlacement, checks: Int,
    granted: ((Permissions.Kind) -> Bool?)? = nil
  ) {
    self.init(plugin: plugin, at: placement, checks: checks, granted: granted) { EmptyView() }
  }
}

/// 插件页最后一组「关于这个插件」：后台、同步，最后一行「移除」
struct PluginAboutSection: View {
  let plugin: Feature
  @AppStorage private var isAdded: Bool

  init(plugin: Feature) {
    self.plugin = plugin
    _isAdded = AppStorage(wrappedValue: plugin.defaultOn, plugin.prefsKey)
  }

  /// 「移除」那一行的说明：刘海岛的提示不归它，睡眠关蓝牙、平滑滚动没有菜单、快捷键这些入口
  private var detail: LocalizedStringResource {
    switch plugin {
    case .island: "移除后点刘海没反应、刘海两边不挂计时；岛上的提示照常弹。设置留着，再添加就回来"
    case .bluetoothSnooze: "移除后睡眠时不再关蓝牙（关着的先打开）；设置留着，再添加就回来"
    case .smoothScroll: "移除后鼠标滚轮回到系统原样（也不反向）；设置留着，再添加就回来"
    case .appShortcuts: "移除后按住那个键不再弹出，快捷键页里也没有它；设置留着，再添加就回来"
    case .keyRemapping: "移除后撤掉这个插件写进系统的映射；规则留着，再添加就回来"
    case .snippetExpand: "移除后打关键词不再展开，也不再听键盘；片段和它们的关键词都留着，再添加就回来"
    default: "移除后菜单栏、主界面、启动器、快捷键里都没有它，设置和数据留着，再添加就回来"
    }
  }

  var body: some View {
    Section("关于这个插件") {
      // 长句写成那一行的副标题（同介绍页「关于」）
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
        Text(plugin.syncsAddition ? "在一台 Mac 上添加，同步的几台都添加" : "只在这台 Mac 上添加，不跟着同步")
      }
      LabeledContent {
        Button("移除") {
          isAdded = false
          // 0.9.0 的「新」（插件）标在通用页「插件 ›」那一行：添加 / 移除过一个插件就算看过
          WhatsNew.touch(section: "插件", of: .general)
        }
      } label: {
        Text("\(plugin.title)插件")
        Text(detail)
      }
    }
  }
}
