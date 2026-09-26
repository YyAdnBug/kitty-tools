// 设置里的有序列表（翻译服务、网页搜索，N12；对标 Bob 服务页 / 系统设置「互联网账户」「登录项」）共用的零件：
// 列表下面系统样式的「+ −」小按钮条、列表高度、选中绑定（单击推进、键盘选中）、详情页的页头（40 pt 图标 + 名称 + 状态）。
// 列表本身（List + .onMove 拖动排序、右键菜单与无障碍动作里的上移 / 下移）在各自的 Tab 里。

import SwiftUI

enum OrderedList {
  /// 一行的高度（24 pt 图标、名称 13 + 状态 11 两行，上下各留 4）
  static let rowHeight: CGFloat = 36
  /// 超过这么多行才在列表里滚动（翻译服务 8 个内置 + 1 个自建刚好不滚）
  static let visibleRows = 10

  /// 列表区的高度：按行数定高，不滚动时整块跟着表单一起滚
  static func height(rows: Int) -> CGFloat {
    CGFloat(min(max(rows, 1), visibleRows)) * rowHeight
  }

  /// 列表的选中绑定：鼠标单击一行 = 推进详情页（N12），↑↓ 只选中（给「−」和 ⌫ 用），↩ 走 primaryAction。
  /// List 在松开鼠标时才改选中（拖动排序、点行里的开关都不改），所以按当前事件是不是 leftMouseUp 区分点击和键盘。
  /// 点击不留选中：留着的话从详情页回来再点同一行，选中没变、setter 不来，就推不进去了
  static func selection(_ selection: Binding<String?>, open: @escaping (String) -> Void)
    -> Binding<String?>
  {
    Binding {
      selection.wrappedValue
    } set: { id in
      if let id, id != selection.wrappedValue, NSApp.currentEvent?.type == .leftMouseUp {
        selection.wrappedValue = nil
        open(id)
      } else {
        selection.wrappedValue = id
      }
    }
  }

  /// 分组下面的说明：caption secondary、靠左（分组表单的页脚默认靠右排）
  static func footnote(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 状态副标题的颜色：缺配置时橙色（Whisker §3 配置 / 密钥问题的语义色），否则 secondary
  static func statusStyle(isProblem: Bool) -> Color {
    isProblem ? Color(nsColor: .systemOrange) : Color(nsColor: .secondaryLabelColor)
  }
}

/// 列表下面的「+ −」小按钮条（add 是按钮或菜单，只放图标）
struct ListEditBar<Add: View>: View {
  let removeTitle: String
  let canRemove: Bool
  let remove: () -> Void
  @ViewBuilder let add: Add

  var body: some View {
    HStack(spacing: 0) {
      add
        .frame(width: 24, height: 20)
      Divider().frame(height: 14)
      Button(removeTitle, systemImage: "minus", action: remove)
        .labelStyle(.iconOnly)
        .frame(width: 24, height: 20)
        .disabled(!canRemove)
        .help(removeTitle)
      Spacer(minLength: 0)
    }
    .buttonStyle(.borderless)
    .font(.system(size: 13, weight: .medium))
  }
}

/// 详情页的页头：40 pt 图标 + 名称（title2）+ 状态（callout；缺配置时橙色），和设置页头同一套排版
struct DetailHeader<Icon: View>: View {
  let title: String
  let status: String
  var isProblem = false
  @ViewBuilder let icon: Icon

  var body: some View {
    HStack(spacing: 12) {
      icon
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(status)
          .font(.callout)
          .foregroundStyle(OrderedList.statusStyle(isProblem: isProblem))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
    }
    .textCase(nil)
    .padding(.bottom, 6)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}
