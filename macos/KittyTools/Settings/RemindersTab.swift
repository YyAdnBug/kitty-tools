// 设置 › 提醒（PLAN §10「提醒」D1，排在「状态屏」后面）：启用开关、提醒列表（行 = 表情的静止画面 / 标题 / 一行摘要 / 开关，
// 拖动排序，「+ −」增删，单击一行推进到 ReminderDetail 编辑——和状态屏的状态同一套 OrderedList 交互）、「稍后」推多久。
// 下面一节「专注模式」：开着任何专注模式时到点的提醒怎么出、现在生没生效、按模式另选的滤镜在系统设置哪里（2026-11-17，
// ReminderFocus / SystemFocus）。
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
      "删除「\(reminders.first { $0.id == removing }?.displayTitle ?? "")」？",
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
          InfoHeader("提醒", info: "点一行编辑，右边的开关暂停或打开那一条。一次性的提醒点了「知道了」就从列表里拿掉。")
            .settingsAnchor(.remindersList)
        } footer: {
          // 满了是状态，照旧写在页脚
          if isFull { SectionFootnote("最多 \(Reminder.maxCount) 条，已经满了，删掉一条才能再加。") }
        }
        Section {
          EmojiPackToggle()
        } header: {
          Text("图标")
        }
        Section {
          Picker(selection: $snooze) {
            ForEach(Reminder.snoozeChoices, id: \.self) { Text("\($0) 分钟").tag($0) }
          } label: {
            Text("「稍后」推多久")
            Text("提醒到点后点「稍后」，过这么久再提醒一次")
          }
          .settingsAnchor(.remindersSnooze)
        } header: {
          InfoHeader(
            "到点之后",
            info:
              "电脑睡着、锁着屏或者没打开 Kitty 时到点的提醒，晚 5 分钟以内的照常提醒，更晚的回来后合成一条告诉你。每隔一阵的提醒碰上锁屏、睡眠，或者 5 分钟没碰键盘鼠标，算休息过了，回来重新数。"
          )
        }
        // 截图自检（fixed）不读这台 Mac 记着的专注模式，固定画「照常」、读得到日志
        FocusSection(fixed: fixed != nil)
      }
      .gated(by: .reminders)
      PluginAboutSection(plugin: .reminders)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
  }

  /// 单击一行推进详情页，↑↓ 选中（给「−」和 ⌫ 用）、↩ 推进，拖动排序（同状态屏的状态列表）
  private func reminderList(_ list: [Reminder], statuses: [StatusPreset]) -> some View {
    List(selection: OrderedList.selection($selection) { open($0) }) {
      ForEach(list) { reminder in
        ReminderListRow(
          reminder: reminder,
          summary: reminder.summary(
            now: now ?? .now,
            statusTitle: ReminderDetail.status(for: reminder, in: statuses)?.displayTitle
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
        Text(reminder.displayTitle).font(.system(size: 13))
        Text(summary)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Toggle("打开「\(reminder.displayTitle)」", isOn: $isOn)
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

/// 专注模式那一节（2026-11-17 拍板 B8，晚上改成任何专注模式都认，B2）：开着专注模式时怎么出、现在生没生效（滤镜加在哪几个模式上
/// 读不到）；按钮打开系统设置里专注模式那一页，按模式另选
private struct FocusSection: View {
  /// 截图自检：不读这台 Mac 现在的专注模式（画「照常」、读得到日志）
  var fixed = false
  @AppStorage(Prefs.remindersDuringFocus) private var during = ReminderFocusStyle.light.rawValue

  var body: some View {
    let style = fixed ? ReminderFocusStyle.normal : ReminderFocus.shared.style
    let mode = fixed ? nil : ReminderFocus.shared.mode
    Section {
      Picker(selection: $during) {
        Text("只在刘海上挂图标").tag(ReminderFocusStyle.light.rawValue)
        Text("先不提醒，结束后再响").tag(ReminderFocusStyle.hold.rawValue)
        Text("照常提醒").tag(ReminderFocusStyle.normal.rawValue)
      } label: {
        Text("专注模式开着时，到点的提醒")
        Text(Self.status(style, mode: mode?.displayName))
      }
      .settingsAnchor(.remindersFocus)
      // 读不到系统日志：只剩滤镜（不是管理员账户、系统改了日志的写法）
      if !fixed, SystemFocus.shared.isRunning, !SystemFocus.shared.isReadable {
        Text("读不到系统的专注模式：只认加了「提醒」滤镜的模式").foregroundStyle(.orange)
      }
      LabeledContent {
        Button("打开专注模式设置…") {
          if let url = URL(string: Self.settingsURL) { NSWorkspace.shared.open(url) }
        }
      } label: {
        Text("按模式另选")
        Text("在某个模式的「专注模式滤镜」里添加 Kitty Tools 的「提醒」")
      }
    } header: {
      InfoHeader(
        "专注模式",
        info:
          "开着任何专注模式（勿扰、睡眠、工作、自己建的）都算。滤镜里另选了的模式以滤镜为准：比如这里选「照常提醒」，只给「工作」加滤镜选「只在刘海上挂图标」。挂在刘海上的提醒，专注模式结束后一起弹一次。要紧的提醒在它的详情里打开「专注模式时也照常提醒」。"
      )
    }
  }

  /// 系统设置里专注模式那一页
  static let settingsURL = "x-apple.systempreferences:com.apple.Focus-Settings.extension"

  /// 「现在」那一行（纯函数）：认得出是哪个模式时带上名字
  static func status(_ style: ReminderFocusStyle, mode: String?) -> LocalizedStringResource {
    switch (style, mode) {
    case (.light, let name?): "现在：「\(name)」开着，到点的提醒只挂在刘海上"
    case (.hold, let name?): "现在：「\(name)」开着，到点的提醒等它结束再响"
    case (.light, nil): "现在：专注模式开着，到点的提醒只挂在刘海上"
    case (.hold, nil): "现在：专注模式开着，到点的提醒等它结束再响"
    case (_, let name?): "现在：「\(name)」开着，照常提醒"
    default: "现在照常提醒"
    }
  }
}
