// 设置页页底的「高级…」和它打开的表单（设置改版 S1 S9，2026-11-18，规格 SPEC §1.4）：一页里零散的、一年改一次的几项收在这里，
// 同系统设置 › 鼠标 右下角的「高级…」。按钮在页面最后（按键行之后、「关于这个插件」之前）一个空分组的页脚里靠右；表单开着
// 是 navigation.advanced == 这一页（不存偏好），每页自己挂 sheet（表单要页里的 store、services）。表单 = 页头（40 pt 页的色块 +
// 「<页名> · 高级」+ 一句话）+ 分组表单 + 底栏（左「恢复默认」、右「完成」，↩ / Esc 都关）。宽 480，高 480、窗口矮时
// 跟着矮（页面高 − 60），里面的表单滚。

import SwiftUI

/// 页底的「高级…」：表单里有新功能时左边挂「新」
struct AdvancedButton: View {
  let page: SettingsPage
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

  var body: some View {
    HStack(spacing: 6) {
      Spacer()
      if let navigation, SettingsItem.advancedIsNew(on: page, fresh: navigation.fresh) { NewTag() }
      Button("高级…") { navigation?.advanced = page }
        .accessibilityLabel("高级设置")
    }
  }
}

extension View {
  /// 这一页的「高级…」表单（navigation.advanced == page 时出来）。inline：截图自检直接画表单本身（sheet 画不进屏外截图）
  func advancedSheet<Content: View>(
    _ page: SettingsPage, summary: LocalizedStringResource, inline: Bool = false,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(AdvancedSheetModifier(page: page, summary: summary, inline: inline, sheet: content))
  }
}

private struct AdvancedSheetModifier<Sheet: View>: ViewModifier {
  let page: SettingsPage
  let summary: LocalizedStringResource
  let inline: Bool
  let sheet: () -> Sheet
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 页面有多高（表单最高 = 它 − 60）
  @State private var pageHeight: CGFloat = 600

  @ViewBuilder func body(content: Content) -> some View {
    if inline {
      AdvancedSheet(
        page: page, summary: summary, height: AdvancedSheet<Sheet>.height, content: sheet)
    } else {
      presenting(content)
    }
  }

  private func presenting(_ content: Content) -> some View {
    content.onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      pageHeight = $0
    }
    .sheet(
      isPresented: Binding {
        navigation?.advanced == page
      } set: {
        if !$0, navigation?.advanced == page { navigation?.advanced = nil }
      }
    ) {
      AdvancedSheet(
        page: page, summary: summary,
        height: max(300, min(AdvancedSheet<Sheet>.height, pageHeight - 60)), content: sheet
      )
      .environment(navigation)
      .symbolEffectsRemoved(reduceMotion)
      .appAccent()
    }
  }
}

/// 「高级…」表单本身
private struct AdvancedSheet<Content: View>: View {
  let page: SettingsPage
  let summary: LocalizedStringResource
  /// 多高：分组表单在表单里量不出自己有多高，高给定、里面的表单滚
  let height: CGFloat
  @ViewBuilder let content: () -> Content
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

  static var width: CGFloat { 480 }
  static var height: CGFloat { 480 }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        KindTile(symbol: page.symbol, color: page.color, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(page.advancedTitle).font(.title2.weight(.semibold))
          Text(plain: summary).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .padding(.horizontal, 20)
      .padding(.top, 18)
      .padding(.bottom, 10)
      Form { content() }
        .formStyle(.grouped)
        .settingsScrollTarget()
        .overlay(alignment: .top) { Hairline() }
      HStack(spacing: 10) {
        ResetDefaultsButton(
          keys: SettingsReset.keys(
            of: SettingsItem.allCases.filter { $0.page == page && $0.place == .advanced }),
          place: page.advancedTitle)
        Spacer()
        Button("完成", action: close)
          .buttonStyle(BrandButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 20)
      .frame(height: 52)
      .overlay(alignment: .top) { Hairline() }
    }
    .frame(width: Self.width, height: height)
    // Esc：sheet 里没有 cancelAction 的按钮就不认 Esc（同速查表），开关、选单又不拿焦点，onExitCommand 收不到
    .background {
      Button("关闭", action: close)
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }

  private func close() { navigation?.advanced = nil }
}

extension SettingsPage {
  /// 「截图 · 高级」：表单的标题、搜索结果里写的位置、恢复默认时岛上说的位置
  var advancedTitle: String {
    String(localized: "\(title) · 高级", comment: "设置页「高级…」表单的标题，%@ 是页名")
  }
}
