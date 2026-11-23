// 设置 › 通用 › 功能（2026-11-07 用户「通用的功能现在直接占用了右侧整个详情」，从通用页挪进推进去的这一页，同「命令和别名」）：
// 页头 40 pt 通用灰色块 + 一句说明；每个功能一行开关（FeatureToggle：家族色块 + 名字 + 说明，和各功能页第一行「启用 x」绑同一个
// 偏好）。通用页只留一行「功能 ›」写开着几个、关着哪几个（summary），0.8.0 的「新」标在那一行。
// 2026-11-13 起功能只剩核心五个（拍板 P1）。插件原来是这一页下面的一组大卡，2026-11-17 插件页改版（D1）挪进侧栏的「全部插件」
// （Settings/PluginsPage.swift），这一页底下一行链过去；插件自己的页最后一组是「关于这个插件」（PluginAboutSection）。

import SwiftUI

struct FeaturesPage: View {
  static let route = "page:features"
  @Environment(\.dismiss) private var dismiss
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

  var body: some View {
    VStack(spacing: 0) {
      DetailHeader(title: "功能", status: "不用的整个关掉，用的时候再打开") {
        KindTile(symbol: "square.grid.2x2.fill", color: Style.Family.general, size: 40)
      }
      Form {
        Section {
          ForEach(Feature.listed, id: \.self) { FeatureToggle(feature: $0) }
        } footer: {
          SectionFootnote("关掉的功能不出现在快捷键、菜单栏和启动器里，也不在后台运行；它的数据和设置都留着，打开就回来。")
        }
        Section {
          SettingsPushRow(title: "插件", detail: "便签、提醒、刘海岛这些在「插件」里添加") {
            navigation?.page = .plugins
          }
        }
      }
      .formStyle(.grouped)
    }
    .navigationTitle("功能")
    .toolbar { SettingsBackButton { dismiss() } }
  }

  /// 通用页那一行的小字：开着的少就列开着的，关着的少就列关着的（纯函数，配单测）
  static func summary(on: Set<Feature>, available: [Feature]) -> String {
    let opened = available.filter(on.contains)
    let closed = available.filter { !on.contains($0) }
    if closed.isEmpty { return String(localized: "\(available.count) 个功能都开着") }
    if opened.isEmpty { return String(localized: "\(available.count) 个功能都关着") }
    if closed.count <= opened.count {
      return String(localized: "开着 \(opened.count) 个；关着：\(closed.map(\.title).joinedAsList())")
    }
    return String(localized: "开着：\(opened.map(\.title).joinedAsList())；另外 \(closed.count) 个关着")
  }
}
