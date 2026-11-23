// 设置 › 插件（2026-11-17 插件页改版，拍板页 https://claude.ai/artifact/FddFbxDbUETWmu2x7asZQv「全部按推荐」，
// PLAN §10「插件页改版」；2026-11-23 插件侧栏改版，拍板页 https://claude.ai/artifact/Rq4GQz9jMdPrVK18HmxLAY「全部按推荐」）：
// 侧栏里插件只有这一行（L1，原来叫「全部插件」、下面再列添加了的插件）。添加了的一节「已添加」在最上面，按原来侧栏的先后（L3）；
// 没添加的按用途分组在下面（A2，Feature.PluginGroup，空组不画）。一行一个（A3）：28 pt 色块、名字（后面可挂「新」、橙色「要授权」）、
// 一句话；没添加的右边「添加」；整行能点——没添加的推进介绍页（PluginIntroPage），添加了的换到它的设置页（navigation.page，
// 侧栏仍亮「插件」，‹ / ⌘[ 回这一页）。
// 「添加」：能当场弹系统框的授权由 AppDelegate.applyFeatures 去问，只能去系统设置打开的（辅助功能、屏幕录制、访达扩展）
// 跳到它自己的设置页（C3，PluginsPage.add）。侧栏搜索搜到没添加的插件、启动器「添加…插件」带过来时描一圈强调色两秒（A4）。
// 页底两行链到 通用 › 功能（核心五个的开关，D1）和 启动器 › 脚本命令（D2）。页头画在自己的 NavigationStack 里，推进介绍页时一起换掉。

import SwiftUI

struct PluginsPage: View {
  /// 截图自检给定的：哪些添加着、哪些缺授权（nil = 现读偏好、现查授权）
  struct Fixed {
    var added: Set<Feature>
    var lacking: Set<Feature>
  }
  var fixed: Fixed?
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  /// 此刻添加着的（偏好变了跟着重算）
  @State private var enabled = Feature.enabled
  /// 添加着、缺授权的：页面出现、设置窗重新当 key、偏好变了时重查（查授权要跨进程问系统，别放在初始值里——
  /// 父视图每画一次都会再算一遍初始值）
  @State private var missing: Set<Feature> = []
  /// 分节按页面出现时添加着哪些来排（L3，评审 2）：开着这一页时点「添加」，那一行留在原处、只是「添加」换成 ›——挪到最上面
  /// 「已添加」的话它从鼠标底下跑掉、下一行的「添加」滑过来，连点两下会加上没挑的那个。换页、从介绍页退回来时再排
  @State private var arranged: Set<Feature>?

  var body: some View {
    // 截图自检单独画这一页时没有导航状态：给一个自己的栈
    if let navigation {
      NavigationStack(path: Bindable(navigation).path) { page }
    } else {
      NavigationStack { page }
    }
  }

  /// 推进介绍页的路由（navigation.path 里的一项）
  static func route(_ plugin: Feature) -> String { "plugin:" + plugin.rawValue }

  static func plugin(route: String) -> Feature? {
    route.hasPrefix("plugin:") ? Feature(rawValue: String(route.dropFirst("plugin:".count))) : nil
  }

  /// 添加着、缺授权的插件
  static func missingNow() -> Set<Feature> {
    Set(Feature.plugins.filter { $0.isOn && !$0.missingPermissions().isEmpty })
  }

  /// 添加（拍板 C3）：打开开关（AppDelegate 看着偏好起停，能弹框的授权它去问）；缺只能去系统设置打开的授权时，
  /// 跳到它自己的设置页（「权限」那一组在最上面）
  static func add(_ plugin: Feature, navigation: SettingsNavigation?) {
    UserDefaults.standard.set(true, forKey: plugin.prefsKey)
    // 0.9.0 的「新」（插件）现在标在通用页「插件 ›」那一行：添加 / 移除过一个插件就算看过
    WhatsNew.touch(section: "插件", of: .general)
    if plugin.missingPermissions().contains(where: \.kind.grantsInSettings) {
      navigation?.page = plugin.page
    }
  }

  private var plugins: [Feature] { Feature.plugins.filter(\.isAvailable) }
  private var added: Set<Feature> { fixed?.added ?? enabled }

  /// 页里的一节：标题、这一节的插件
  struct Group {
    let title: LocalizedStringResource
    let plugins: [Feature]
  }

  /// 页里怎么分节（纯函数，L3）：添加了的一节「已添加」在最上面，按 Feature 的先后（= 原来侧栏的先后，原来在侧栏点哪一行，
  /// 现在点这一节的同一行）；没添加的按用途分组（A2）。空的节不画；这台用不了的插件不列
  static func groups(added: Set<Feature>) -> [Group] {
    let mine = Feature.allCases.filter { $0.isPlugin && $0.isAvailable && added.contains($0) }
    let rest = Feature.PluginGroup.allCases.map { group in
      Group(title: group.title, plugins: group.plugins.filter { !added.contains($0) })
    }
    return ([Group(title: "已添加", plugins: mine)] + rest).filter { !$0.plugins.isEmpty }
  }

  private var page: some View {
    VStack(spacing: 0) {
      DetailHeader(
        title: SettingsPage.plugins.titleResource,
        status: "添加了 \(plugins.filter(added.contains).count) 个，共 \(plugins.count) 个"
      ) {
        KindTile(symbol: SettingsPage.plugins.symbol, color: SettingsPage.plugins.color, size: 40)
      }
      ScrollViewReader { proxy in
        Form {
          ForEach(Self.groups(added: arranged ?? added), id: \.title.key) { group in
            Section {
              ForEach(group.plugins, id: \.self) { plugin in
                row(plugin).id(plugin)
              }
            } header: {
              Text(plain: group.title)
            }
          }
          Section {
            SettingsPushRow(title: "功能", detail: "剪贴板、启动器、翻译、截图、录制的开关") {
              navigation?.page = .general
              navigation?.path = [FeaturesPage.route]
            }
            SettingsPushRow(title: "脚本命令", detail: "想自己写个小命令，在启动器里跑") {
              navigation?.page = .launcher
            }
          } footer: {
            SectionFootnote("新装时插件都没添加。添加了才出现在菜单栏、主界面、快捷键和启动器里，设置在这一页点进去；移除了设置和数据都留着，再添加就回来。")
          }
        }
        .formStyle(.grouped)
        .onChange(of: navigation?.focusedPlugin, initial: true) {
          guard let plugin = navigation?.focusedPlugin else { return }
          // 晚一拍再滚：页面刚换过来时表单的行还没排好，当场滚不动；描边留一会儿就收
          Task {
            try? await Task.sleep(for: .milliseconds(150))
            proxy.scrollTo(plugin, anchor: .center)
            try? await Task.sleep(for: .seconds(2))
            if navigation?.focusedPlugin == plugin { navigation?.focusedPlugin = nil }
          }
        }
      }
    }
    .navigationTitle(SettingsPage.plugins.title)
    .navigationDestination(for: String.self) { route in
      if let plugin = Self.plugin(route: route) { PluginIntroPage(plugin: plugin) }
    }
    // 偏好随时在变（别的设置、窗口位置）：只有添加的插件变了才重查授权
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      let now = Feature.enabled
      if now != enabled {
        enabled = now
        recheck()
      }
    }
    .onSettingsBecameKey { recheck() }
    .onAppear {
      enabled = Feature.enabled
      arranged = added
      recheck()
    }
  }

  private func recheck() {
    let lacks = Self.missingNow()
    if lacks != missing { missing = lacks }
  }

  private func row(_ plugin: Feature) -> some View {
    PluginRow(
      plugin: plugin, isAdded: added.contains(plugin),
      lacksAccess: (fixed?.lacking ?? missing).contains(plugin),
      isNew: WhatsNew.marks(plugin: plugin, in: navigation?.fresh ?? []),
      isFocused: navigation?.focusedPlugin == plugin
    ) {
      if added.contains(plugin) {
        navigation?.page = plugin.page
      } else {
        navigation?.path = [Self.route(plugin)]
      }
    } add: {
      Self.add(plugin, navigation: navigation)
    }
  }
}

/// 插件页的一行：色块、名字（新 / 要授权）、一句话，整块是一个 plain 按钮（open：键盘、读屏都能用，同 SettingsPushRow）；
/// 没添加时旁边一个「添加」按钮（兄弟视图，不并进行里）；最后一个 ›。添加了的在「已添加」那一节里，行尾不再写「已添加」（L3）
private struct PluginRow: View {
  let plugin: Feature
  let isAdded: Bool
  let lacksAccess: Bool
  let isNew: Bool
  let isFocused: Bool
  let open: () -> Void
  let add: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: open) {
        HStack(spacing: 10) {
          KindTile(symbol: plugin.page.symbol, color: plugin.page.color, size: 28)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
              Text(plugin.title)
              if isNew { NewTag() }
              if lacksAccess {
                Text("要授权").font(.subheadline).foregroundStyle(.orange)
              }
            }
            Text(plain: plugin.blurbResource)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer(minLength: 8)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHint(isAdded ? "打开它的设置" : "看看它能做什么、要什么授权")
      if !isAdded {
        Button("添加", action: add).buttonStyle(BrandButtonStyle())
          .accessibilityLabel("添加「\(plugin.title)」")
      }
      Image(systemName: "chevron.forward")
        .foregroundStyle(.tertiary)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .accessibilityHidden(true)
    }
    .settingsHighlight(isFocused)
  }
}
