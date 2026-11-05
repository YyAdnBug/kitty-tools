// 设置 › 提醒（PLAN §10「提醒」D1，排在「状态屏」后面）：启用开关、提醒列表（行 = 表情的静止画面 / 标题 / 一行摘要 / 开关，
// 拖动排序，「+ −」增删，单击一行推进到 ReminderDetail 编辑——和状态屏的状态同一套 OrderedList 交互）、「稍后」推多久。
// 页头画在自己的 NavigationStack 里，推进时一起换掉。列表直接读写偏好里的 JSON（Prefs.reminders）：ReminderCenter 看着偏好变化跟上，
// 它删掉响过的一次性提醒时这一页也跟着变。「+」›「新提醒」先不存：推进详情页，第一次改动时才加进列表（Reminder.saving）。

import SwiftUI

struct RemindersTab: View {
  /// 截图自检传一份固定的列表：只画，不读不写偏好。正常使用是 nil = 偏好里那份
  var fixed: [Reminder]?
  /// 截图自检固定「现在」（摘要里的今天 / 明天）
  var now: Date?
  @AppStorage(Prefs.reminders) private var data: Data?
  @AppStorage(Prefs.remindersSnoozeMinutes) private var snooze = 5
  @Environment(SettingsNavigation.self) private var navigation
  /// 列表里用键盘选中的一条（「−」和 ⌫ 删它；鼠标单击直接推进，不留选中）
  @State private var selection: String?
  /// 等确认删除的（自己加的、改过的）
  @State private var removing: String?
  /// 「+」›「新提醒」推进去、还没存的那一条（详情页第一次改动时才加进列表）
  @State private var fresh: Reminder?

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .reminders)
        form
      }
      .navigationTitle(SettingsPage.reminders.title)
      .navigationDestination(for: String.self) { id in
        ReminderDetail(id: id, fixed: fixed, now: now, fresh: fresh?.id == id ? fresh : nil)
      }
    }
    .task { await StatusEmoji.warmStills() }
    .confirmationDialog(
      "删除「\(reminders.first { $0.id == removing }?.title ?? "")」？",
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
      Text(ReminderDetail.deleteMessage)
    }
  }

  private var form: some View {
    let list = reminders
    let isFull = list.count >= Reminder.maxCount
    let statuses = StatusPreset.load()
    return Form {
      Section { FeatureToggle(feature: .reminders, inPage: true) }
      Group {
        Section {
          if list.isEmpty {
            Text("还没有提醒，点下面的「+」加一条")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            reminderList(list, statuses: statuses)
          }
          ListEditBar(
            removeTitle: "删除所选的提醒", canRemove: selection != nil, remove: removeSelected
          ) {
            addMenu(list, isFull: isFull)
          }
        } header: {
          Text("提醒")
        } footer: {
          SectionFootnote(
            "点一行编辑，右边的开关暂停或打开那一条。一次性的提醒点了「知道了」就从列表里拿掉。"
              + (isFull ? "最多 \(Reminder.maxCount) 条，已经满了，删掉一条才能再加。" : ""))
        }
        Section {
          EmojiPackToggle()
        } header: {
          Text("图标")
        } footer: {
          SectionFootnote(EmojiPackToggle.footnote)
        }
        Section {
          Picker(selection: $snooze) {
            ForEach(Reminder.snoozeChoices, id: \.self) { Text("\($0) 分钟").tag($0) }
          } label: {
            Text("「稍后」推多久")
            Text("提醒到点后点「稍后」，过这么久再提醒一次")
          }
        } header: {
          Text("到点之后")
        } footer: {
          SectionFootnote(
            "电脑睡着、锁着屏或者没打开 Kitty 时到点的提醒，晚 5 分钟以内的照常提醒，更晚的回来后合成一条告诉你。"
              + "每隔一阵的提醒碰上锁屏、睡眠，或者 5 分钟没碰键盘鼠标，算休息过了，回来重新数。")
        }
      }
      .gated(by: .reminders)
    }
    .formStyle(.grouped)
  }

  /// 单击一行推进详情页，↑↓ 选中（给「−」和 ⌫ 用）、↩ 推进，拖动排序（同状态屏的状态列表）
  private func reminderList(_ list: [Reminder], statuses: [StatusPreset]) -> some View {
    List(selection: OrderedList.selection($selection) { open($0) }) {
      ForEach(list) { reminder in
        ReminderListRow(
          reminder: reminder,
          summary: reminder.summary(
            now: now ?? .now, statusTitle: ReminderDetail.status(for: reminder, in: statuses)?.title
          ),
          isOn: Binding {
            reminder.isOn
          } set: { on in
            var next = reminder
            next.isOn = on
            reminders = Reminder.updating(reminders, with: next)
          },
          open: { open(reminder.id) },
          move: { reminders = Reminder.moving(reminder.id, by: $0, in: reminders) }
        )
        .tag(reminder.id)
      }
      .onMove { from, to in
        var list = reminders
        list.move(fromOffsets: from, toOffset: to)
        reminders = list
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: list.count)
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let reminder = list.first(where: { $0.id == id }) {
        Button("编辑…") { open(id) }
        Divider()
        Button("上移") { reminders = Reminder.moving(id, by: -1, in: reminders) }
          .disabled(id == list.first?.id)
        Button("下移") { reminders = Reminder.moving(id, by: 1, in: reminders) }
          .disabled(id == list.last?.id)
        Divider()
        Button(reminder.isPristine ? "删除" : "删除…", role: .destructive) { remove(id) }
      }
    } primaryAction: { ids in
      if let id = ids.first { open(id) }
    }
    .onDeleteCommand(perform: removeSelected)
  }

  /// 「+」：新建一条（推进详情页改，第一次改动时才加到末尾），或把删掉的示例补回来；满 50 条时整个置灰
  private func addMenu(_ list: [Reminder], isFull: Bool) -> some View {
    Menu {
      Button("新提醒") {
        let reminder = Reminder.new(now: now ?? .now)
        open(reminder.id, fresh: reminder)
      }
      Divider()
      Button("恢复示例提醒") { reminders = Reminder.restoringExamples(in: reminders) }
        .disabled(Reminder.missingExamples(in: list).isEmpty)
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .disabled(isFull)
    .accessibilityLabel("添加提醒")
    .help(isFull ? "最多 \(Reminder.maxCount) 条提醒" : "添加提醒")
  }

  private var reminders: [Reminder] {
    get { fixed ?? Reminder.decode(data) }
    nonmutating set { if fixed == nil { data = Reminder.encoded(newValue) } }
  }

  private func open(_ id: String, fresh: Reminder? = nil) {
    selection = nil
    self.fresh = fresh
    navigation.path = [id]
  }

  /// 「−」、⌫、右键「删除」：和示例一模一样的直接删（「+」里能恢复），自己加的、改过的先确认
  private func remove(_ id: String) {
    guard let reminder = reminders.first(where: { $0.id == id }) else { return }
    if reminder.isPristine { delete(id) } else { removing = id }
  }

  private func delete(_ id: String) {
    reminders = Reminder.removing(id, from: reminders)
    if selection == id { selection = nil }
  }

  private func removeSelected() {
    if let selection { remove(selection) }
  }
}

/// 一条提醒：图标、标题 + 摘要（什么时候 · 怎么提醒）、开关、›（只是提示能推进，点整行都推进）
private struct ReminderListRow: View {
  let reminder: Reminder
  let summary: String
  @Binding var isOn: Bool
  let open: () -> Void
  /// 上移（-1）/ 下移（+1）
  let move: (Int) -> Void

  var body: some View {
    HStack(spacing: 10) {
      ReminderIcon(symbol: reminder.symbol)
      VStack(alignment: .leading, spacing: 1) {
        Text(reminder.title).font(.system(size: 13))
        Text(summary)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Toggle("打开「\(reminder.title)」", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
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

/// 一条提醒的小图标：选了表情的是表情的静止画面，没选的是提醒家族色块里的闹钟
struct ReminderIcon: View {
  let symbol: String
  var size: CGFloat = 24

  var body: some View {
    StatusPresetIcon(
      symbol: symbol, size: size, plainSymbol: SettingsPage.reminders.symbol,
      plainColor: Style.Family.reminders)
  }
}
