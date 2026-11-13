// 设置 › 通用 › 功能（2026-11-07 用户「通用的功能现在直接占用了右侧整个详情」，从通用页挪进推进去的这一页，同「命令和别名」）：
// 页头 40 pt 通用灰色块 + 一句说明；每个功能一行开关（FeatureToggle：家族色块 + 名字 + 说明，和各功能页第一行「启用 x」绑同一个
// 偏好）。通用页只留一行「功能 ›」写开着几个、关着哪几个（summary），0.8.0 的「新」标在那一行。
// 下面一组「插件」（2026-11-12 拍板 A2）：每个插件一张卡（色块、名字、一句话、要的授权、后台做什么）+「添加」/「移除」，
// 绑的还是那个功能开关的偏好。启动器里「添加…插件」那一行带过来时（SettingsNavigation.focusedPlugin）滚到那张卡、描一圈强调色。

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
      ScrollViewReader { proxy in
        Form {
          Section {
            ForEach(Feature.listed, id: \.self) { FeatureToggle(feature: $0) }
          } footer: {
            SectionFootnote("关掉的功能不出现在快捷键、菜单栏和启动器里，也不在后台运行；它的数据和设置都留着，打开就回来。")
          }
          Section {
            ForEach(Feature.allCases.filter(\.isPlugin), id: \.self) { plugin in
              PluginCard(plugin: plugin, isFocused: navigation?.focusedPlugin == plugin)
                .id(plugin)
            }
          } header: {
            Text("插件")
          } footer: {
            SectionFootnote(
              "插件新装、升级都默认不添加。添加了才出现在侧栏、菜单栏、主界面、快捷键和启动器里；移除就是关掉，设置留着，再添加就回来。")
          }
        }
        .formStyle(.grouped)
        .onChange(of: navigation?.focusedPlugin, initial: true) {
          guard let plugin = navigation?.focusedPlugin else { return }
          // 晚一拍再滚：页面刚推进来时表单的行还没排好，当场滚不动（卡在十来行开关下面，常在屏外）；描边留一会儿就收
          Task {
            try? await Task.sleep(for: .milliseconds(150))
            proxy.scrollTo(plugin, anchor: .center)
            try? await Task.sleep(for: .seconds(2))
            if navigation?.focusedPlugin == plugin { navigation?.focusedPlugin = nil }
          }
        }
      }
    }
    .navigationTitle("功能")
    .toolbar { SettingsBackButton { dismiss() } }
  }

  /// 通用页那一行的小字：开着的少就列开着的，关着的少就列关着的（纯函数，配单测）
  static func summary(on: Set<Feature>, available: [Feature]) -> String {
    let opened = available.filter(on.contains)
    let closed = available.filter { !on.contains($0) }
    if closed.isEmpty { return "\(available.count) 个功能都开着" }
    if opened.isEmpty { return "\(available.count) 个功能都关着" }
    if closed.count <= opened.count {
      return "开着 \(opened.count) 个；关着：" + closed.map(\.title).joined(separator: "、")
    }
    return "开着：" + opened.map(\.title).joined(separator: "、") + "；另外 \(closed.count) 个关着"
  }
}

/// 一个插件的卡（表单里的一行）：40 pt 色块、名字 + 一句话、要的授权和后台做什么，右边「添加」/「移除」。
/// 添加 = 打开它的功能开关（AppDelegate 看着偏好起停），移除 = 关掉（设置和数据留着）
private struct PluginCard: View {
  let plugin: Feature
  let isFocused: Bool
  @AppStorage private var isAdded: Bool

  init(plugin: Feature, isFocused: Bool) {
    self.plugin = plugin
    self.isFocused = isFocused
    _isAdded = AppStorage(wrappedValue: plugin.defaultOn, plugin.prefsKey)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      KindTile(symbol: plugin.page.symbol, color: plugin.page.color, size: 40)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(plugin.title).font(.headline)
          if isAdded {
            Text("已添加").font(.caption).foregroundStyle(Style.brandInk)
          }
        }
        Text(plugin.blurb).foregroundStyle(.secondary)
        if let facts = plugin.pluginFacts {
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
              Text("授权").foregroundStyle(.tertiary)
              Text(facts.permission).foregroundStyle(.secondary)
            }
            GridRow {
              Text("后台").foregroundStyle(.tertiary)
              Text(facts.background).foregroundStyle(.secondary)
            }
          }
          .font(.subheadline)
          .padding(.top, 2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if isAdded {
        Button("移除") { isAdded = false }
      } else {
        Button("添加") { isAdded = true }
          .buttonStyle(BrandButtonStyle())
      }
    }
    .padding(.vertical, 4)
    .overlay {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .strokeBorder(Style.brand, lineWidth: 2)
        .padding(-6)
        .opacity(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: isFocused)
    }
    // 合起来读：名字、已添加、一句话、授权、后台都在（拍板 A2：添加之前就听得到要什么授权）；按钮并进来后用命名动作
    .accessibilityElement(children: .combine)
    .accessibilityAction(named: isAdded ? "移除" : "添加") { isAdded.toggle() }
  }
}
