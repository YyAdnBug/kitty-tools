// 设置 › 状态屏（PLAN §10「状态屏」Z11，排在「录制」后面）：状态列表（行 = 家族色块里的图标 / 标题 / 一行摘要，
// 拖动排序，「+ −」增删，单击一行推进到 StatusPresetDetail 编辑——和翻译服务、网页搜索同一套 OrderedList 交互）、
// 「按快捷键直接进入排在最前面的状态」开关（默认关：按快捷键先出一排预览卡片，StatusPicker.swift）、
// 「有人碰键盘或鼠标时显示怎么退出」开关、怎么退出和「它不是安全措施」的说明。页头画在自己的 NavigationStack 里，
// 推进时一起换掉。列表直接读写偏好里的 JSON（Prefs.statusScreenPresets）：菜单栏、启动器每次现读，改了就跟上。
// 这一页没有「进入」「试一下」这类按钮：进入会拦住键盘鼠标，只从菜单栏、启动器、全局快捷键进。
// 界面里不写「锁」字（定位是告示加防误触，mac-overlay-panel §11）。

import SwiftUI

struct StatusScreenTab: View {
  /// 截图自检传一份固定的列表：只画，不读不写偏好。正常使用是 nil = 偏好里那份
  var fixed: [StatusPreset]?
  /// 直接读写偏好里的 JSON，不留一份拷贝（同 LauncherTab：设置窗常驻，别处改了偏好——比如导入——拷贝会过期）
  @AppStorage(Prefs.statusScreenPresets) private var data: Data?
  @AppStorage(Prefs.statusScreenExitHint) private var exitHint = true
  @AppStorage(Prefs.statusScreenHotKeyEntersFirst) private var entersFirst = false
  /// 推进的详情页在 navigation.path（主菜单「返回」也要读写它）
  @Environment(SettingsNavigation.self) private var navigation
  /// 列表里用键盘选中的一条（「−」和 ⌫ 删它；鼠标单击直接推进，不留选中）
  @State private var selection: String?
  /// 等确认删除的状态（自己加的、改过的）
  @State private var removing: String?

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .statusScreen)
        form
      }
      .navigationTitle(SettingsPage.statusScreen.title)
      .navigationDestination(for: String.self) { id in StatusPresetDetail(id: id, fixed: fixed) }
    }
    .confirmationDialog(
      "删除「\(presets.first { $0.id == removing }?.title ?? "")」？",
      isPresented: Binding {
        removing != nil
      } set: {
        if !$0 { removing = nil }
      }
    ) {
      Button("删除", role: .destructive) {
        if let removing { delete(removing) }
      }
    } message: {
      Text(StatusPresetDetail.deleteMessage)
    }
  }

  private var form: some View {
    let list = presets
    let isFull = list.count >= StatusPreset.maxCount
    return Form {
      Section {
        presetList(list)
        ListEditBar(
          removeTitle: "删除所选的状态", canRemove: selection != nil && list.count > 1,
          remove: removeSelected
        ) {
          addMenu(list, isFull: isFull)
        }
      } header: {
        Text("状态")
      } footer: {
        OrderedList.footnote(
          "拖动调整顺序，点一行编辑。"
            + (entersFirst ? "排在最前面的状态就是全局快捷键进入的那个。" : "按全局快捷键选状态时，卡片也按这个顺序排。")
            + "至少留一个；删掉的自带状态可以从「+」里恢复。"
            + (isFull ? "最多 \(StatusPreset.maxCount) 个，已经满了，删掉一个才能再加。" : ""))
      }
      Section {
        Toggle(isOn: $entersFirst) {
          Text("按快捷键直接进入排在最前面的状态")
          Text("关着时，按快捷键先出一排预览卡片，选一个再进。")
        }
      } header: {
        Text("进入")
      } footer: {
        OrderedList.footnote("快捷键在「快捷键」页设置，默认没有。在菜单栏、启动器里选一个状态，都是直接进入。")
      }
      Section {
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("怎么退出")
          Text("按住 Esc 两秒；或者动一下鼠标，再用鼠标按住屏幕底部出现的提示两秒。到了自动结束的时间、解锁电脑回来时，也会结束。")
        }
        Toggle(isOn: $exitHint) {
          Text("有人碰键盘或鼠标时显示怎么退出")
          Text("关掉后屏幕上不再提示，只能按住 Esc 两秒退出；键盘上没有 Esc 键的别关。")
        }
      } header: {
        Text("退出")
      } footer: {
        OrderedList.footnote(
          "状态屏是告示加防误触，不是安全措施：照着提示谁都能退出。要防别人动电脑，进入之后再锁定屏幕（按一下触控 ID 键）：电脑照样不睡，回来解锁就结束。")
      }
    }
    .formStyle(.grouped)
  }

  // MARK: 状态列表

  /// 单击一行推进详情页，↑↓ 选中（给「−」和 ⌫ 用）、↩ 推进，拖动排序（和翻译服务、网页搜索列表同一套）
  private func presetList(_ list: [StatusPreset]) -> some View {
    List(selection: OrderedList.selection($selection, open: open)) {
      ForEach(list) { preset in
        PresetListRow(
          preset: preset, open: { open(preset.id) },
          move: { presets = StatusPreset.moving(preset.id, by: $0, in: presets) }
        )
        .tag(preset.id)
      }
      .onMove { from, to in
        var list = presets
        list.move(fromOffsets: from, toOffset: to)
        presets = list
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: list.count)
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let preset = list.first(where: { $0.id == id }) {
        Button("编辑…") { open(id) }
        Divider()
        Button("上移") { presets = StatusPreset.moving(id, by: -1, in: presets) }
          .disabled(id == list.first?.id)
        Button("下移") { presets = StatusPreset.moving(id, by: 1, in: presets) }
          .disabled(id == list.last?.id)
        Divider()
        Button(preset.isPristine ? "删除" : "删除…", role: .destructive) { remove(id) }
          .disabled(list.count <= 1)
      }
    } primaryAction: { ids in
      if let id = ids.first { open(id) }
    }
    .onDeleteCommand(perform: removeSelected)
  }

  /// 「+」：新建一个（加到末尾、直接推进详情页改），或把删掉的自带状态补回来；满 20 个时整个置灰（原因写在列表下面）
  private func addMenu(_ list: [StatusPreset], isFull: Bool) -> some View {
    Menu {
      Button("新状态") {
        let preset = StatusPreset.new()
        presets = StatusPreset.adding(preset, to: presets)
        open(preset.id)
      }
      Divider()
      Button("恢复自带的状态") { presets = StatusPreset.restoringBuiltIns(in: presets) }
        .disabled(StatusPreset.missingBuiltIns(in: list).isEmpty)
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .disabled(isFull)
    .accessibilityLabel("添加状态")
    .help(isFull ? "最多 \(StatusPreset.maxCount) 个状态" : "添加状态")
  }

  private var presets: [StatusPreset] {
    get { fixed ?? StatusPreset.decode(data) }
    nonmutating set { if fixed == nil { data = StatusPreset.encoded(newValue) } }
  }

  /// 推进详情页并清掉选中（同 LauncherTab.open）
  private func open(_ id: String) {
    selection = nil
    navigation.path = [id]
  }

  /// 「−」、⌫、右键「删除」：只剩一个时不删；和自带的一模一样的直接删（「+」里能恢复），自己加的、改过的先确认
  private func remove(_ id: String) {
    let list = presets
    guard list.count > 1, let preset = list.first(where: { $0.id == id }) else { return }
    if preset.isPristine { delete(id) } else { removing = id }
  }

  private func delete(_ id: String) {
    presets = StatusPreset.removing(id, from: presets)
    if selection == id { selection = nil }
  }

  private func removeSelected() {
    if let selection { remove(selection) }
  }
}

/// 一个状态：家族色块里的图标（没选图标的用「只有字」的符号垫着）、标题 + 摘要（样式 · 电源 · 自动结束）、
/// ›（只是提示能推进，点整行都推进）
private struct PresetListRow: View {
  let preset: StatusPreset
  let open: () -> Void
  /// 上移（-1）/ 下移（+1）
  let move: (Int) -> Void

  var body: some View {
    HStack(spacing: 10) {
      KindTile(symbol: preset.rowSymbol, color: Style.Family.statusScreen, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(preset.title).font(.system(size: 13))
        Text(preset.summary)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Image(systemName: "chevron.forward")
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .accessibilityAction(named: "编辑", open)
    .accessibilityAction(named: "上移") { move(-1) }
    .accessibilityAction(named: "下移") { move(1) }
  }
}
