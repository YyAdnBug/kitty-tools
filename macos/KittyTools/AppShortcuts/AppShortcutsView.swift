// App 快捷键的面板内容（拍板 C1–C3，mac-whisker/app-shortcuts.md）：Panel 皮肤（OverlayPanel），顶上一行 App 图标、
// 名字、多少个快捷键；下面一个顶层菜单一张卡（.cardSurface()），卡片按菜单顺序一列列往下排，列底放不下的卡拆到下一列
// 接着排（标题写「续」），放得下几列就几列，一屏放不下整块竖着滚。每行：子菜单的路径灰字 + 标题（一行截断），右边 Whisker 键帽（KeyCombo；两段式的两组）。
// 灰着的不画灰（AXEnabled 靠不住，MenuShortcuts 文件头）。读不到、一条都没有、没读完各有一句话（拍板 E1）。
// 排版（AppShortcutsLayout）是纯函数，配单测：列宽、行高定死，卡片高度按条数算，不量 SwiftUI。

import AppKit
import SwiftUI

@Observable final class AppShortcutsModel {
  /// 一个顶层菜单的一组
  struct Group: Identifiable, Equatable {
    /// 菜单栏里第几个（两个同名的菜单也分得开）
    let id: Int
    let title: String
    let items: [MenuShortcut]
  }

  var appName = ""
  var icon: NSImage?
  var groups: [Group] = []
  var finished = true
  var unreadable = false
  var layout = AppShortcutsLayout.make(rows: [], available: NSSize(width: 1440, height: 900))

  var count: Int { groups.reduce(0) { $0 + $1.items.count } }

  /// 换上新读的（available：鼠标所在屏的可见区大小）
  func load(_ reading: MenuReading, name: String, icon: NSImage?, available: NSSize) {
    appName = name
    self.icon = icon
    groups = Self.groups(reading.shortcuts)
    finished = reading.finished
    unreadable = reading.unreadable
    layout = AppShortcutsLayout.make(rows: groups.map(\.items.count), available: available)
  }

  /// 按顶层菜单分组，保持菜单里的先后（纯函数）
  static func groups(_ shortcuts: [MenuShortcut]) -> [Group] {
    var result: [Group] = []
    for shortcut in shortcuts {
      let bar = shortcut.location.first ?? 0
      if let last = result.last, last.id == bar {
        result[result.count - 1] = Group(id: bar, title: last.title, items: last.items + [shortcut])
      } else {
        result.append(Group(id: bar, title: shortcut.menu, items: [shortcut]))
      }
    }
    return result
  }
}

/// 面板的尺寸和卡片怎么分列（纯函数，单测）
struct AppShortcutsLayout: Equatable {
  /// 一列里的一段：哪一组的哪几行；continued = 接着上一列那一段往下（卡片标题写「续」）
  struct Segment: Hashable {
    let group: Int
    let rows: Range<Int>
    var continued: Bool { rows.lowerBound > 0 }
  }

  static let columnWidth: CGFloat = 248
  static let gap: CGFloat = 10
  static let padding: CGFloat = 14
  /// 顶上那一行连同它下面的间距
  static let header: CGFloat = 40
  static let rowHeight: CGFloat = 22
  /// 卡片除了行以外的高：组名 18 + 上下内边距各 8
  static let cardChrome: CGFloat = 34
  /// 一张卡拆到下一列时，前一段至少留几行（不在列底留一个标题加一两行）
  static let minSplit = 3
  /// 一条都没有 / 读不到时的大小
  static let emptySize = NSSize(width: 380, height: 210)

  let columns: [[Segment]]
  /// 最高那一列的高
  let contentHeight: CGFloat
  let size: NSSize

  /// 放不下、要竖着滚
  var scrolls: Bool { contentHeight > size.height - Self.header - Self.padding * 2 + 0.5 }

  static func cardHeight(rows: Int) -> CGFloat { cardChrome + CGFloat(rows) * rowHeight }

  /// rows：各组几条；available：屏幕可见区。最宽占 90%、最高 80%（拍板 C1）；列数取放得下的最少列，都放不下就最多列、竖着滚
  static func make(rows: [Int], available: NSSize) -> AppShortcutsLayout {
    guard !rows.isEmpty else {
      return AppShortcutsLayout(columns: [], contentHeight: 0, size: emptySize)
    }
    let maxColumns = max(
      1, Int((available.width * 0.9 - padding * 2 + gap) / (columnWidth + gap)))
    let maxBody = max(cardHeight(rows: minSplit * 2), available.height * 0.8 - header - padding * 2)
    var best = flow(rows, into: maxColumns)
    for count in 1..<maxColumns {
      let tried = flow(rows, into: count)
      if tried.height <= maxBody {
        best = tried
        break
      }
    }
    let count = best.columns.count
    let width = padding * 2 + CGFloat(count) * columnWidth + CGFloat(count - 1) * gap
    let height = padding * 2 + header + min(best.height, maxBody)
    return AppShortcutsLayout(
      columns: best.columns, contentHeight: best.height, size: NSSize(width: width, height: height))
  }

  /// 按先后一列列往下排，排进最多 count 列里最矮的样子（二分找每列的上限）。一组在列底放不下时，前面至少能放
  /// minSplit 行就拆到下一列接着排，不然整组挪到下一列
  static func flow(_ rows: [Int], into count: Int) -> (columns: [[Segment]], height: CGFloat) {
    func fill(limit: CGFloat) -> [[Segment]] {
      var columns: [[Segment]] = [[]]
      var used: CGFloat = 0
      for (group, total) in rows.enumerated() {
        var start = 0
        while start < total {
          let fresh = columns[columns.count - 1].isEmpty
          let room = limit - (fresh ? 0 : used + gap) - cardChrome
          let fits = max(0, Int((room + 0.001) / rowHeight))
          let left = total - start
          let take: Int
          if fits >= left {
            take = left
          } else if fits >= minSplit || (fresh && fits >= 1) {
            take = fits
          } else if fresh {
            take = left  // 上限比一张卡还矮：只能整张放
          } else {
            columns.append([])
            used = 0
            continue
          }
          columns[columns.count - 1].append(Segment(group: group, rows: start..<start + take))
          used += (fresh ? 0 : gap) + cardHeight(rows: take)
          start += take
          if start < total {
            columns.append([])
            used = 0
          }
        }
      }
      return columns.filter { !$0.isEmpty }
    }
    func height(_ columns: [[Segment]]) -> CGFloat {
      columns.map { column in
        column.map { cardHeight(rows: $0.rows.count) }.reduce(0, +)
          + CGFloat(max(column.count - 1, 0)) * gap
      }.max() ?? 0
    }
    var low = cardHeight(rows: minSplit)
    var high = rows.map(cardHeight).reduce(0, +) + CGFloat(rows.count) * gap
    for _ in 0..<24 where high - low > 0.5 {
      let middle = (low + high) / 2
      if fill(limit: middle).count <= count { high = middle } else { low = middle }
    }
    let columns = fill(limit: high)
    return (columns, height(columns))
  }
}

struct AppShortcutsView: View {
  let model: AppShortcutsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .frame(height: AppShortcutsLayout.header, alignment: .top)
      if model.groups.isEmpty {
        empty.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView(.vertical) {
          HStack(alignment: .top, spacing: AppShortcutsLayout.gap) {
            ForEach(model.layout.columns, id: \.self) { column in
              VStack(spacing: AppShortcutsLayout.gap) {
                ForEach(column, id: \.self) { segment in
                  if model.groups.indices.contains(segment.group) {
                    GroupCard(group: model.groups[segment.group], segment: segment)
                  }
                }
              }
              .frame(width: AppShortcutsLayout.columnWidth)
            }
          }
        }
        .scrollDisabled(!model.layout.scrolls)
        .scrollIndicators(model.layout.scrolls ? .automatic : .never)
      }
    }
    .padding(AppShortcutsLayout.padding)
  }

  private var header: some View {
    HStack(spacing: 8) {
      if let icon = model.icon {
        Image(nsImage: icon).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
      }
      Text(model.appName)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
      if !model.groups.isEmpty {
        Text("\(model.count) 个快捷键").font(.system(size: 13)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if !model.finished, !model.groups.isEmpty {
        Text("没读完：这个 App 没响应")
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: .systemOrange))
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .frame(height: 24)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var empty: some View {
    if !model.finished {
      EmptyState(symbol: "hourglass", title: "这个 App 没响应") {
        Text("过一会儿再按住 ⌘ 试试").foregroundStyle(.secondary)
      }
    } else if model.unreadable {
      EmptyState(symbol: "menubar.rectangle", title: "读不到这个 App 的菜单") {
        Text("有的 App 没有菜单栏").foregroundStyle(.secondary)
      }
    } else {
      EmptyState(symbol: "keyboard", title: "这个 App 的菜单里没有快捷键") {
        Text("有的 App 只在窗口里响应快捷键，菜单里看不到").foregroundStyle(.secondary)
      }
    }
  }
}

/// 一个顶层菜单一张卡（拆到下一列的那一段标题写「续」）
private struct GroupCard: View {
  let group: AppShortcutsModel.Group
  let segment: AppShortcutsLayout.Segment

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 菜单名是那个 App 的，原样显示；「续」跟着界面语言
      (segment.continued ? Text("\(group.title)（续）") : Text(verbatim: group.title))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(height: 18, alignment: .top)
        .accessibilityAddTraits(.isHeader)
      ForEach(group.items[segment.rows.clamped(to: group.items.indices)]) { item in
        HStack(spacing: 8) {
          // 放不下时先截子菜单的路径，标题留着
          HStack(spacing: 0) {
            if !item.path.isEmpty {
              Text(item.path.joined(separator: " › ") + " › ")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Text(item.title)
              .lineLimit(1)
              .truncationMode(.tail)
              .layoutPriority(1)
          }
          .font(.system(size: 13))
          Spacer(minLength: 8)
          HStack(spacing: 4) {
            // 两段式的两组可能一样（⌘K ⌘K），按位置认
            let parts = item.keys.split(separator: " ").map(String.init)
            ForEach(parts.indices, id: \.self) { KeyCombo(parts[$0]) }
          }
          .fixedSize()
        }
        .frame(height: AppShortcutsLayout.rowHeight)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
  }
}
