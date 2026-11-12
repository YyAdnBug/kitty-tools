// 设置 › 刘海岛（2026-11-12，PR #17 SeyoZhou 提的，收进来时改成本 App 的写法）：点刘海、快捷键「打开刘海岛」叫出来的
// 那一张上，快捷动作开哪几个、什么先后（拖动排序；右键和读屏有上移 / 下移，同翻译服务的列表），列不列最近的提示。
// 岛本身是全 App 的轻提示，没有总开关（mac-native §1）。功能关着的动作照样列、开关变灰（那一张上本来就不出），
// 重新打开功能后照原来的选择回来。不归哪个功能，在侧栏第一组、通用下面。

import SwiftUI

struct IslandTab: View {
  @AppStorage(Prefs.islandActionOrder) private var order = ""
  @AppStorage(Prefs.islandActionsOff) private var offText = ""
  @AppStorage(Prefs.islandShowsHistory) private var showsHistory = true

  var body: some View {
    let actions = HotKeyAction.islandOrder(order)
    Form {
      Section {
        List {
          ForEach(actions, id: \.self) { action in
            ActionRow(
              action: action, isOn: shows(action), isFirst: action == actions.first,
              isLast: action == actions.last
            ) { move(action, by: $0) }
          }
          .onMove { from, to in
            var list = actions
            list.move(fromOffsets: from, toOffset: to)
            save(list)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .orderedListFrame(rows: actions.count)
      } header: {
        Text("快捷动作")
      } footer: {
        SectionFootnote(
          "点刘海或者按「打开刘海岛」的快捷键（到 设置 › 快捷键 里设），叫出来的那一张最上面是这一排。拖动调整先后。")
      }
      Section {
        Toggle(isOn: $showsHistory) {
          Text("列出最近的提示")
          Text("本次启动以来最近 10 条，新的在前；不列也不影响提示照常弹出")
        }
      }
    }
    .formStyle(.grouped)
  }

  /// 那一张上出不出这一个：关掉的存成一行一个，按 islandShortcuts 的先后写（同步按字节比，别每次换个排法）
  private func shows(_ action: HotKeyAction) -> Binding<Bool> {
    Binding {
      !HotKeyAction.islandOff(offText).contains(action)
    } set: { isOn in
      var off = HotKeyAction.islandOff(offText)
      if isOn { off.remove(action) } else { off.insert(action) }
      offText = HotKeyAction.islandShortcuts.filter(off.contains).map(\.rawValue)
        .joined(separator: "\n")
    }
  }

  /// 右键菜单和读屏的上移（-1）/ 下移（+1）；到头了什么都不做
  private func move(_ action: HotKeyAction, by offset: Int) {
    var list = HotKeyAction.islandOrder(order)
    guard let index = list.firstIndex(of: action), list.indices.contains(index + offset) else {
      return
    }
    list.swapAt(index, index + offset)
    save(list)
  }

  private func save(_ list: [HotKeyAction]) {
    order = list.map(\.rawValue).joined(separator: "\n")
  }
}

/// 一行：家族色块、名字（功能关着时下面一行说明）、开关；右键和读屏能上移 / 下移
private struct ActionRow: View {
  let action: HotKeyAction
  @Binding var isOn: Bool
  let isFirst: Bool
  let isLast: Bool
  /// 上移（-1）/ 下移（+1）
  let move: (Int) -> Void

  var body: some View {
    let active = action.isActive
    HStack(spacing: 10) {
      KindTile(symbol: action.symbol, color: action.color)
        .opacity(active ? 1 : Style.disabledOpacity)
      VStack(alignment: .leading, spacing: 1) {
        Text(action.title).font(.system(size: 13))
        if !active, let feature = action.feature {
          Text("「\(feature.title)」功能关着，那一张上不出现")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Toggle("显示「\(action.title)」", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!active)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .contextMenu {
      Button("上移") { move(-1) }.disabled(isFirst)
      Button("下移") { move(1) }.disabled(isLast)
    }
    .accessibilityAction(named: "上移") { move(-1) }
    .accessibilityAction(named: "下移") { move(1) }
  }
}
