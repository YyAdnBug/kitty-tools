// 搜索线（mac-whisker-clipboard「搜索线」）：剪贴板面板和启动器顶上那一行共用的排法，两块面板逐像素一样——
// 左右内边距 18；线头是 17 pt medium 的符号（tertiary），定宽 22 + 右边 4，和后面的东西间距 6。
// 符号定宽：筛选面板 / ⌘K 开着时线头换符号（放大镜 → 筛选 → ⌘），各符号宽度不一样，不定宽的话输入框会跟着左右挪。
// 线头后面放什么（剪贴板的筛选标签 + 输入框、启动器的输入框）和这一行多高（56）由用的地方给。

import SwiftUI

struct SearchLine<Content: View>: View {
  /// 线头的 SF Symbol
  let symbol: String
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 22)
        .padding(.trailing, 4)
        .accessibilityHidden(true)
      content
    }
    .padding(.horizontal, 18)
  }
}
