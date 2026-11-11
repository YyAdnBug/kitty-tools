// 设置 › 灵动岛：总开关、快捷动作 / 最近提示开关，以及快捷动作的启用与排序。
// 快捷动作的全局 Feature 关闭时仍保留本页选择，但行置灰；重新打开对应功能后会恢复到用户原来的选择。

import SwiftUI

struct IslandTab: View {
  @AppStorage(Prefs.islandEnabled) private var enabled = true
  @AppStorage(Prefs.islandShowsActions) private var showsActions = true
  @AppStorage(Prefs.islandShowsHistory) private var showsHistory = true
  @AppStorage(Prefs.islandActionOrder) private var storedOrder = Prefs.islandActionIDs.joined(
    separator: "\n")
  @AppStorage(Prefs.islandActionOff) private var storedOff = ""
  @State private var featureGeneration = 0

  private var actions: [HotKeyAction] {
    Prefs.islandActionsOrder(stored: storedOrder).compactMap(HotKeyAction.init(rawValue:))
  }

  private var off: Set<String> {
    Prefs.islandActionsOff(stored: storedOff)
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $enabled) {
          Text("显示灵动岛")
          Text("关闭后不显示刘海岛，但不会删除最近提示")
        }
        Toggle(isOn: $showsActions) {
          Text("快捷动作")
          Text("展开灵动岛时显示截图、识字、录屏等常用动作")
        }
        .disabled(!enabled)
        Toggle(isOn: $showsHistory) {
          Text("最近提示")
          Text("展开灵动岛时显示本次启动以来最近的消息记录")
        }
        .disabled(!enabled)
      } header: {
        Text("灵动岛")
      } footer: {
        SectionFootnote("快捷动作和最近提示只在展开灵动岛时显示；动作仍受对应功能开关控制。")
      }

      Section {
        ForEach(actions, id: \.rawValue) { action in
          actionRow(action)
        }
        .onMove(perform: move)
      } header: {
        Text("快捷动作")
      } footer: {
        SectionFootnote("打开或关闭单个动作，拖动调整显示顺序。动作仍受 设置 › 通用 › 功能 中对应功能开关控制。")
      }
      .disabled(!enabled)
    }
    .formStyle(.grouped)
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      featureGeneration &+= 1
    }
  }

  @ViewBuilder private func actionRow(_ action: HotKeyAction) -> some View {
    let globalOn = action.feature?.isOn ?? true
    Toggle(isOn: actionBinding(action)) {
      HStack(spacing: 10) {
        KindTile(symbol: action.symbol, color: action.color, size: 22)
          .opacity(globalOn ? 1 : Style.disabledOpacity)
        VStack(alignment: .leading, spacing: 2) {
          Text(action.title)
          if let feature = action.feature, !globalOn {
            Text("「功能」里的\(feature.title)已关闭")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .disabled(!globalOn)
    .id("\(action.rawValue)-\(featureGeneration)")
  }

  private func actionBinding(_ action: HotKeyAction) -> Binding<Bool> {
    Binding {
      !off.contains(action.rawValue)
    } set: { isOn in
      var next = off
      if isOn { next.remove(action.rawValue) } else { next.insert(action.rawValue) }
      storedOff = next.sorted {
        Prefs.islandActionIDs.firstIndex(of: $0)! < Prefs.islandActionIDs.firstIndex(of: $1)!
      }
      .joined(separator: "\n")
    }
  }

  private func move(from source: IndexSet, to destination: Int) {
    var next = Prefs.islandActionsOrder(stored: storedOrder)
    next.move(fromOffsets: source, toOffset: destination)
    storedOrder = next.joined(separator: "\n")
  }
}
