// 设置 › 提醒 › 某一条（详情页，从列表推进来；同 StatusPresetDetail 的形式）：页头 40 pt 图标 + 标题 + 摘要，下面分组表单：
// 标题、说明、图标（一格「无」+ 16 个表情）；时间（一次 / 每天 / 工作日 / 每周 / 每月 / 间隔，各自的时刻、星期、几号、时段）；
// 提醒方式（四种，全屏多久自己收、进入哪个状态）；声音（无 / 提示音 / 朗读标题，选提示音时试听一声；提示音列系统的、个人「声音」
// 文件夹里的、自己选过的文件，最后一项「选择文件…」，ReminderSound）；催促；最后是删除
// （和示例一模一样的直接删，自己加的、改过的先确认）。
// 改动即时写回偏好里的 JSON 列表（和 RemindersTab 读写同一个键），存之前过 Reminder.sanitized。输入框绑的是一份草稿
// （同 StatusPresetDetail：边打边收拾会吃掉正在打的空格）。有问题（没标题、超长、时间已经过了）时页头的摘要换成橙色说明。
// 「+」›「新提醒」推进来的（fresh）还没存：画的是它，第一次改动时才加进列表（Reminder.saving），没改就离开的不留。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReminderDetail: View {
  let id: String
  /// 截图自检传一份固定的列表：只画，不读不写偏好。正常使用是 nil = 偏好里那份
  var fixed: [Reminder]?
  var now: Date?
  /// 「+」›「新提醒」推进来、还没存的那一条；从列表点进来的是 nil
  var fresh: Reminder?
  @AppStorage(Prefs.reminders) private var data: Data?
  @Environment(\.dismiss) private var dismiss
  /// 正在改的这一份（输入框里的原样）；nil = 还没改过，用存着的
  @State private var draft: Reminder?
  @State private var confirmsDelete = false
  /// 个人「声音」文件夹里的、自己选过的提示音（打开页面时读一次，选了文件再读）
  /// nil = 还没读（第一帧不把个人文件夹里的、自己选的说成「这台 Mac 上没有」）
  @State private var sounds: (library: [ReminderSound.Choice], files: [ReminderSound.Choice])?
  /// 选了「选择文件…」之后让菜单重建一次，显示回存着的那个（取消、选了同一个文件时选中项不变，不重建的话停在「选择文件…」上）
  @State private var pickerReset = 0
  /// 「没理会时再催」选了「自定义…」（填的正好是菜单里有的数也留在自定义；存着的不是菜单里的数时自然是自定义）
  @State private var customNag = false
  /// 「没理会时再催」菜单里「自定义…」那一项的标记
  private static let customNagTag = -1
  /// 选的文件存不下的原因（橙字写在提示音那一行）
  @State private var importProblem: String?
  /// 提示音菜单里「选择文件…」那一项的标记（不是声音）
  private static let chooseFile = "\u{0}choose"

  static let deleteMessage = "自己加的、改过的提醒删掉就找不回来了。"

  var body: some View {
    let list = fixed ?? Reminder.decode(data)
    // 删掉之后、退回列表之前的这一帧（或者响过、点了「知道了」被拿掉了）没有这一条：什么都不画。
    // 还没存的新提醒画 fresh（改过一处就存进去了：之后不在列表里就是被删掉 / 拿掉了，不再画它）
    if let stored = list.first(where: { $0.id == id }) ?? (draft == nil ? fresh : nil) {
      form(editing: draft ?? stored, stored: stored)
        .navigationTitle(stored.title)
        .toolbar { SettingsBackButton { dismiss() } }
    }
  }

  /// 进入状态屏的提醒进的是哪个状态：存的那个不在了就是排在最前面的
  static func status(for reminder: Reminder, in statuses: [StatusPreset]) -> StatusPreset? {
    guard reminder.alert == .status else { return nil }
    return statuses.first { $0.id == reminder.statusID } ?? statuses.first
  }

  private func form(editing: Reminder, stored: Reminder) -> some View {
    let binding = Binding {
      editing
    } set: {
      draft = $0
      save($0)
    }
    let statuses = StatusPreset.load()
    let problem = editing.problem(now: now ?? .now)
    return VStack(spacing: 0) {
      DetailHeader(
        title: stored.title,
        status: problem
          ?? stored.summary(
            now: now ?? .now, statusTitle: Self.status(for: stored, in: statuses)?.title),
        isProblem: problem != nil
      ) {
        ReminderIcon(symbol: stored.symbol, size: 40)
      }
      Form {
        Section {
          TextField("标题", text: binding.title, prompt: Text("如 喝水"))
          TextField(
            "说明",
            text: Binding {
              editing.detail ?? ""
            } set: {
              binding.wrappedValue.detail = $0
            }, prompt: Text("可不填"))
          SymbolGrid(selection: binding.symbol)
        } footer: {
          SectionFootnote("标题最多 \(Reminder.maxTitle) 个字，说明最多 \(Reminder.maxDetail) 个字。")
        }
        ScheduleSection(schedule: binding.schedule, now: now ?? .now)
        alertSection(binding, editing: editing, statuses: statuses)
        soundSection(binding, editing: editing)
        Section {
          DangerButton(stored.isPristine ? "删除" : "删除…") {
            if stored.isPristine { delete() } else { confirmsDelete = true }
          }
        }
      }
      .formStyle(.grouped)
    }
    .confirmationDialog("删除「\(stored.title)」？", isPresented: $confirmsDelete) {
      Button("删除", role: .destructive, action: delete)
    } message: {
      Text(Self.deleteMessage)
    }
  }

  private func alertSection(
    _ binding: Binding<Reminder>, editing: Reminder, statuses: [StatusPreset]
  ) -> some View {
    Section {
      Picker(
        selection: Binding {
          editing.alert
        } set: { alert in
          var next = binding.wrappedValue
          next.alert = alert
          // 换成进入状态屏时先选上排在最前面的状态（不然存的是空的）
          if alert == .status, !statuses.contains(where: { $0.id == next.statusID }) {
            next.statusID = statuses.first?.id ?? ""
          }
          binding.wrappedValue = next
        }
      ) {
        // 状态屏这个功能关着时不给「进入状态屏」（指向别的功能的东西跟着它的开关，mac-native §1）；已经选了的照旧显示
        ForEach(
          Reminder.Alert.allCases.filter {
            $0 != .status || Feature.statusScreen.isOn || editing.alert == .status
          }, id: \.self
        ) { Text($0.title).tag($0) }
      } label: {
        Text("提醒方式")
        Text(editing.alert.explanation)
      }
      .pickerStyle(.segmented)
      if editing.alert == .full {
        Picker("多久自己收起", selection: binding.fullSeconds) {
          ForEach(Reminder.fullChoices, id: \.self) {
            Text($0 == 0 ? "点了才收" : Reminder.durationTitle($0)).tag($0)
          }
        }
      }
      if editing.alert == .status {
        Picker(
          "进入哪个状态",
          selection: Binding {
            Self.status(for: editing, in: statuses)?.id ?? ""
          } set: {
            binding.wrappedValue.statusID = $0
          }
        ) {
          ForEach(statuses) { Text($0.title).tag($0.id) }
        }
      }
    } header: {
      Text("提醒方式")
    } footer: {
      SectionFootnote(
        editing.alert == .status
          ? "状态屏会拦住键盘鼠标，按住 Esc 或者到了状态的自动结束时间才退出。没给辅助功能授权、正在录屏时进不去，改成全屏提醒。"
          : "正在录屏、录音时，边框和全屏改成刘海岛上的提醒，免得录进去。")
    }
  }

  private func soundSection(_ binding: Binding<Reminder>, editing: Reminder) -> some View {
    Section {
      Picker("声音", selection: binding.sound) {
        ForEach(Reminder.Sound.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      if editing.sound == .chime {
        chimePicker(binding, editing: editing)
      }
      nagRows(binding, editing: editing)
    } header: {
      Text("声音和催促")
    }
  }

  /// 提示音：系统的 ｜ 个人「声音」文件夹里的、自己选过的 ｜（这台 Mac 上没有的那个）｜ 选择文件…（同 Mac 上弹出菜单末尾的「其他…」）
  private func chimePicker(_ binding: Binding<Reminder>, editing: Reminder) -> some View {
    let mine = (sounds?.library ?? []) + (sounds?.files ?? [])
    let known = Set(Reminder.chimes.map(\.name) + mine.map(\.id))
    let missing = sounds != nil && !known.contains(editing.chime)
    let note: String? =
      if missing {
        "这台 Mac 上没有这个声音，到点响「\(ReminderSound.title(of: Reminder.defaultChime))」"
      } else if editing.chime.hasPrefix(ReminderSound.filePrefix) {
        "自己选的文件只存在这台 Mac 上，最多响 \(ReminderSound.maxSeconds) 秒"
      } else {
        nil
      }
    return Picker(
      selection: Binding {
        editing.chime
      } set: { id in
        if id == Self.chooseFile {
          pickerReset += 1
          chooseChime()
        } else {
          binding.wrappedValue.chime = id
          importProblem = nil
          ReminderSound.play(id, preview: true)  // 选了就试听一声
        }
      }
    ) {
      ForEach(Reminder.chimes, id: \.name) { Text($0.title).tag($0.name) }
      if !mine.isEmpty || missing { Divider() }
      ForEach(mine, id: \.id) { Text($0.title).tag($0.id) }
      if missing {
        Text("\(ReminderSound.title(of: editing.chime))（这台 Mac 上没有）").tag(editing.chime)
      }
      Divider()
      Text("选择文件…").tag(Self.chooseFile)
      if sounds == nil, !Reminder.chimes.contains(where: { $0.name == editing.chime }) {
        Text(ReminderSound.title(of: editing.chime)).tag(editing.chime)  // 还没读文件夹的这一帧
      }
    } label: {
      Text("提示音")
      if let importProblem {
        Text(importProblem).foregroundStyle(Color(nsColor: .systemOrange))
      } else if let note {
        Text(note)
      }
    }
    .id(pickerReset)
    .task { sounds = ReminderSound.choices() }
    .onDisappear { ReminderSound.stopPreview() }
  }

  /// 没理会时再催：不催 / 每 1–60 分钟几档 /「自定义…」，自定义时下面一行「每隔 [N] 分钟」（输入框 + 步进器，1–120）
  @ViewBuilder
  private func nagRows(_ binding: Binding<Reminder>, editing: Reminder) -> some View {
    let isCustom = customNag || !Reminder.nagChoices.contains(editing.nagMinutes)
    Picker(
      selection: Binding {
        isCustom ? Self.customNagTag : editing.nagMinutes
      } set: { value in
        if value == Self.customNagTag {
          customNag = true
          if editing.nagMinutes == 0 { binding.wrappedValue.nagMinutes = 2 }
        } else {
          customNag = false
          binding.wrappedValue.nagMinutes = value
        }
      }
    ) {
      ForEach(Reminder.nagChoices, id: \.self) { Text($0 == 0 ? "不催" : "每 \($0) 分钟").tag($0) }
      Divider()
      Text("自定义…").tag(Self.customNagTag)
    } label: {
      Text("没理会时再催")
      Text("没点「知道了」或「稍后」就再响一次，第 3 次换成全屏，之后不再催")
    }
    if isCustom {
      let minutes = Binding {
        editing.nagMinutes
      } set: {
        binding.wrappedValue.nagMinutes = min(
          max($0, Reminder.nagRange.lowerBound), Reminder.nagRange.upperBound)
      }
      LabeledContent {
        HStack(spacing: 6) {
          TextField("分钟", value: minutes, format: .number)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)  // 分组表单里输入框默认没边，看着像一段字
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 48)
          Stepper("分钟", value: minutes, in: Reminder.nagRange).labelsHidden()
          Text("分钟").foregroundStyle(.secondary)
        }
      } label: {
        Text("每隔")
        Text("1–120 分钟")
      }
    }
  }

  /// 「选择文件…」：选一个音频，拷进数据目录，这条提醒就用它。面板挂成设置窗上的表单（开着时改不了别的）；
  /// 选好时从现在的那一份改（不用点菜单那一刻的快照：同步可能在这期间落下来）
  private func chooseChime() {
    guard fixed == nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = ReminderSound.contentTypes
    panel.prompt = "选择"
    panel.message = "选一个短音频（20 MB 以内），到点最多放 \(ReminderSound.maxSeconds) 秒"
    let chosen: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      do throws(ReminderSound.ImportError) {
        let id = try ReminderSound.importFile(url)
        // 还没存的新提醒第一下就选文件：拿 fresh 存进去（同 save 里的 Reminder.saving）
        guard
          var next = draft ?? Reminder.decode(data).first(where: { $0.id == self.id }) ?? fresh
        else { return }
        next.chime = id
        draft = next
        save(next)
        importProblem = nil
        sounds = ReminderSound.choices()
        ReminderSound.play(id, preview: true)
      } catch {
        importProblem = error.message
      }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: chosen)
    } else {
      panel.begin(completionHandler: chosen)
    }
  }

  private func delete() {
    dismiss()
    guard fixed == nil else { return }
    data = Reminder.encoded(Reminder.removing(id, from: Reminder.decode(data)))
  }

  private func save(_ draft: Reminder) {
    guard fixed == nil else { return }
    data = Reminder.encoded(Reminder.saving(draft, to: Reminder.decode(data), fresh: fresh))
  }
}

/// 时间那一组：先选重复的方式，下面是那一种要填的
private struct ScheduleSection: View {
  @Binding var schedule: Reminder.Schedule
  let now: Date

  var body: some View {
    let repeats = schedule.repeats
    Section {
      Picker(
        "重复",
        selection: Binding {
          repeats
        } set: {
          schedule = schedule.repeating($0, now: now)
        }
      ) {
        ForEach(Reminder.Schedule.Repeat.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      switch schedule.kind {
      case .once:
        DatePicker(
          "日期和时间", selection: $schedule.date, in: now...,
          displayedComponents: [.date, .hourAndMinute])
      case .weekly:
        if repeats == .weekly { WeekdayRow(days: $schedule.days) }
        DatePicker("时间", selection: clock($schedule.time), displayedComponents: .hourAndMinute)
      case .monthly:
        Picker("每月几号", selection: $schedule.day) {
          ForEach(1...31, id: \.self) { Text("\($0) 号").tag($0) }
        }
        DatePicker("时间", selection: clock($schedule.time), displayedComponents: .hourAndMinute)
      case .interval:
        Picker("每隔", selection: $schedule.every) {
          ForEach(Reminder.Schedule.everyChoices, id: \.self) {
            Text(Reminder.Schedule.everyTitle($0)).tag($0)
          }
        }
        WeekdayRow(days: $schedule.days)
        Toggle(
          "全天",
          isOn: Binding {
            schedule.time == 0 && schedule.until == 1440
          } set: { allDay in
            (schedule.time, schedule.until) = allDay ? (0, 1440) : (9 * 60, 18 * 60)
          })
        if !(schedule.time == 0 && schedule.until == 1440) {
          DatePicker("从", selection: clock($schedule.time), displayedComponents: .hourAndMinute)
          DatePicker(
            "到", selection: clock($schedule.until, endOfDay: true),
            displayedComponents: .hourAndMinute)
        }
      }
    } header: {
      Text("时间")
    } footer: {
      SectionFootnote(Self.footnote(schedule.kind))
    }
  }

  static func footnote(_ kind: Reminder.Schedule.Kind) -> String {
    switch kind {
    case .once: "响过、点了「知道了」之后从列表里拿掉。"
    case .weekly: "工作日按周一到周五算，不管调休；要别的日子选「每周」自己勾。"
    case .monthly: "没有这一天的月份（比如 2 月 30 号），在当月最后一天提醒。"
    case .interval: "只在勾了的日子、这一段时间里提醒。锁屏、睡眠，或者 5 分钟没碰键盘鼠标，算休息过了，回来重新数。"
    }
  }

  /// 一天里的第几分钟 ↔ 今天那个时刻（给时间选择器用）；endOfDay：0:00 当成半夜 24:00（时段的结束）
  private func clock(_ minutes: Binding<Int>, endOfDay: Bool = false) -> Binding<Date> {
    Binding {
      let value = minutes.wrappedValue % 1440
      return Calendar.current.date(
        bySettingHour: value / 60, minute: value % 60, second: 0, of: now) ?? now
    } set: {
      let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
      let value = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
      minutes.wrappedValue = endOfDay && value == 0 ? 1440 : value
    }
  }
}

/// 一排星期（一 … 日）：按下的是勾了的；至少留一天（提醒的详情页、保持唤醒的定时共用）
struct WeekdayRow: View {
  @Binding var days: [Int]
  private static let order = [2, 3, 4, 5, 6, 7, 1]
  private static let names = ["日", "一", "二", "三", "四", "五", "六"]

  var body: some View {
    LabeledContent("星期") {
      HStack(spacing: 4) {
        ForEach(Self.order, id: \.self) { day in
          Toggle(
            Self.names[day - 1],
            isOn: Binding {
              days.contains(day)
            } set: { on in
              if on {
                days = (days + [day]).sorted()
              } else if days.count > 1 {
                days.removeAll { $0 == day }
              }
            }
          )
          .toggleStyle(.button)
          .accessibilityLabel("周" + Self.names[day - 1])
        }
      }
    }
  }
}

extension Reminder.Schedule {
  /// 详情页「重复」那一栏的选项：每天、工作日、每周都是 weekly，按勾了哪几天分
  enum Repeat: CaseIterable {
    case once, daily, workdays, weekly, monthly, interval

    var title: String {
      switch self {
      case .once: "一次"
      case .daily: "每天"
      case .workdays: "工作日"
      case .weekly: "每周"
      case .monthly: "每月"
      case .interval: "每隔一阵"
      }
    }
  }

  var repeats: Repeat {
    switch kind {
    case .once: .once
    case .monthly: .monthly
    case .interval: .interval
    case .weekly: days == Self.allDays ? .daily : days == Self.workdays ? .workdays : .weekly
    }
  }

  /// 换一种重复方式（纯函数）：别的字段留着；换成一次而时间已经过了的给下一个整点，换成每周而原来是每天 / 工作日的
  /// 只勾今天（不然选了「每周」又显示回「每天」）
  func repeating(_ repeats: Repeat, now: Date, calendar: Calendar = .current) -> Self {
    var next = self
    switch repeats {
    case .once:
      next.kind = .once
      if date <= now { next.date = Reminder.new(now: now, calendar: calendar).schedule.date }
    case .daily:
      next.kind = .weekly
      next.days = Self.allDays
    case .workdays:
      next.kind = .weekly
      next.days = Self.workdays
    case .weekly:
      next.kind = .weekly
      if days == Self.allDays || days == Self.workdays {
        next.days = [calendar.component(.weekday, from: now)]
      }
    case .monthly:
      next.kind = .monthly
    case .interval:
      next.kind = .interval
    }
    return next
  }

  /// 「15 分钟」「1 小时」「1.5 小时」
  static func everyTitle(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) 分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(Double(minutes) / 60) 小时"
  }
}
