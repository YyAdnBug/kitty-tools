// 设置 › 快捷键 最下面一节「在这些 App 里停用」（2026-11-10，HotKeyBlock）：名单里的 App 在前台时本 App 的快捷键交给它。
// 列表同剪贴板「不记录」的 App（AppListRow、「＋ −」、⌫ 删除）；每行右边一个弹出菜单选停哪些：「全部快捷键」（默认，
// 含启动器命令的快捷键和连按两下）或勾几个全局动作。改了先写偏好、再让热键中心对此刻的前台重算（blocksChanged）；
// 同步、导入落下了新的名单，页面跟上。fixed：截图自检直接摆一份名单，不读不写偏好。

import SwiftUI

struct HotKeyBlockSection: View {
  let center: HotKeyCenter
  let fixed: [String]?
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  @State private var blocks: [HotKeyBlock]
  @State private var selection: String?

  init(center: HotKeyCenter, fixed: [String]? = nil) {
    self.center = center
    self.fixed = fixed
    _blocks = State(initialValue: HotKeyBlock.list(fixed ?? HotKeyBlock.stored))
  }

  var body: some View {
    Section {
      List(selection: $selection) {
        if blocks.isEmpty {
          Text("没有停用快捷键的 App").foregroundStyle(.secondary)
        }
        ForEach(blocks, id: \.bundleID) { block in
          HStack(spacing: 8) {
            AppListRow(bundleID: block.bundleID)
            scopeMenu(block)
          }
          .tag(block.bundleID)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .orderedListFrame(rows: blocks.count)
      .onDeleteCommand(perform: removeSelected)
      ListEditBar(
        removeTitle: "移除所选的 App", canRemove: selection != nil, remove: removeSelected
      ) {
        Menu {
          Menu("正在运行的 App") {
            ForEach(AppListRow.runningApps, id: \.bundleID) { app in
              Button(app.name) { add(app.bundleID) }
                .disabled(blocks.contains { $0.bundleID == app.bundleID })
            }
          }
          Button("选择 App…") {
            AppListRow.chooseApps(prompt: "停用快捷键", message: "选择的 App 在前台时，快捷键交给它")
              .forEach(add)
          }
        } label: {
          Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("添加 App")
      }
    } header: {
      NewTitle("在这些 App 里停用", page: .hotkeys, fresh: navigation?.fresh ?? [])
    } footer: {
      SectionFootnote("名单里的 App 在前台时，上面的快捷键不响应，按键交给那个 App。也可以在那个 App 里右键点菜单栏图标，从菜单里停用。")
    }
    // 同步、导入落下了新的名单：页面跟上（同剪贴板页的排除列表）
    .task {
      guard fixed == nil else { return }
      for await _ in NotificationCenter.default.notifications(
        named: UserDefaults.didChangeNotification)
      {
        let stored = HotKeyBlock.list(HotKeyBlock.stored)
        if stored != blocks { blocks = stored }
      }
    }
  }

  /// 右边的弹出菜单：「全部快捷键」或勾几个（列开着的功能的动作，分节同快捷键页）
  private func scopeMenu(_ block: HotKeyBlock) -> some View {
    let shown = HotKeyAction.sections.flatMap(\.actions)
    return Menu(Self.scope(block)) {
      Toggle(
        "全部快捷键",
        isOn: Binding(
          get: { block.actions == nil },
          set: { if $0 { update(HotKeyBlock(bundleID: block.bundleID)) } }))
      ForEach(HotKeyAction.sections, id: \.title) { section in
        Section(section.title) {
          ForEach(section.actions, id: \.self) { action in
            Toggle(
              action.title,
              isOn: Binding(
                get: { block.blocks(action) },
                set: { update(block.setting(action, blocked: $0, shown: shown)) }))
          }
        }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .foregroundStyle(.secondary)
  }

  /// 弹出菜单上的字
  static func scope(_ block: HotKeyBlock) -> String {
    guard block.actions != nil else { return "全部快捷键" }
    let count = block.knownActions.count
    return count == 0 ? "没有停用的" : "\(count) 个快捷键"
  }

  private func add(_ bundleID: String) {
    change { list in
      if !list.contains(where: { $0.bundleID == bundleID }) {
        list.append(HotKeyBlock(bundleID: bundleID))
      }
    }
  }

  private func update(_ block: HotKeyBlock) {
    change { list in
      if let index = list.firstIndex(where: { $0.bundleID == block.bundleID }) {
        list[index] = block
      }
    }
  }

  private func removeSelected() {
    guard let id = selection else { return }
    change { $0.removeAll { $0.bundleID == id } }
    selection = nil
  }

  private func change(_ edit: (inout [HotKeyBlock]) -> Void) {
    guard fixed == nil else { return }
    HotKeyBlock.change(edit)
    blocks = HotKeyBlock.list(HotKeyBlock.stored)
    center.blocksChanged()
    // 加过、改过、移除过一个 App，「新」就算看过了（光点进这一页不算；WhatsNew）
    WhatsNew.touch(section: "在这些 App 里停用", of: .hotkeys)
  }
}
