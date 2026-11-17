// 定时提醒的一条（PLAN §10「提醒」，2026-11-04 拍板页 https://claude.ai/artifact/Wgahjd1V2kbhN8BriU5fCm 全部按推荐）：
// 标题、说明、图标（状态屏那套动画表情，C13）、开没开、什么时候响（Schedule，B1）、怎么提醒（Alert，C1）、全屏多久自己收（C5）、
// 声音（C9）、催促（C10），加一个不变的 id。
// 整张列表存在一个偏好键里（Prefs.reminders，JSON，不注册默认值）：没存过时是三条示例，默认都关着（F1）。读出来和导入的都过
// sanitized：偏好、导入文件里的值按不可信输入对待。解码逐个字段兜底（不认识的种类、缺的字段换成默认值），以后加了字段或种类，
// 旧版本读到也不会整张读不出来、退回示例。
// 设置 › 提醒改列表的纯函数（加、删、挪、恢复示例、详情页改一条）和列表行的摘要也在这里；什么时候响在 ReminderSchedule.swift。
// nonisolated：设置导出文件里的值（SettingsArchive.Value，不绑主线程）要编解码它。

import Foundation

nonisolated struct Reminder: Codable, Hashable, Identifiable {
  /// 什么时候响（B1）。几种共用一个扁平的结构：JSON 简单，详情页换种类时别的字段留着，换回来还是原来的
  struct Schedule: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
      /// 一次：date 那一刻
      case once
      /// 每周勾了的那几天的 time（每天 = 七天都勾，工作日 = 周一到周五）
      case weekly
      /// 每月 day 号的 time；没有这一天的月份在最后一天响
      case monthly
      /// 间隔：勾了的那几天，time…until 这一段里每隔 every 分钟（B3：离开电脑回来重新数）
      case interval
    }

    var kind: Kind
    /// 一次：哪一刻
    var date: Date
    /// 一天里的第几分钟：每周 / 每月的时刻、间隔的时段开始
    var time: Int
    /// 间隔的时段结束（一天里的第几分钟，不含；1440 = 到半夜）
    var until: Int
    /// 星期几（Calendar 的 weekday：1 = 周日 … 7 = 周六）
    var days: [Int]
    /// 每月几号（1…31）
    var day: Int
    /// 间隔几分钟
    var every: Int

    static let allDays = Array(1...7)
    /// 工作日 = 周一到周五，不认调休（拍板 B1）
    static let workdays = Array(2...6)
    static let everyChoices = [15, 20, 30, 45, 60, 90, 120]

    init(
      kind: Kind, date: Date = .distantPast, time: Int = 9 * 60, until: Int = 18 * 60,
      days: [Int] = allDays, day: Int = 1, every: Int = 60
    ) {
      self.kind = kind
      self.date = date
      self.time = time
      self.until = until
      self.days = days
      self.day = day
      self.every = every
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let fallback = Schedule(kind: .weekly)
      // 不认识的种类（更新的版本加的）当成很久以前的一次：不会响，也不会被当成「每天」响个不停（2026-11-04 评审）
      if let kind = try? c.decode(Kind.self, forKey: .kind) {
        self.kind = kind
        date = (try? c.decode(Date.self, forKey: .date)) ?? fallback.date
      } else {
        kind = .once
        date = .distantPast
      }
      time = (try? c.decode(Int.self, forKey: .time)) ?? fallback.time
      until = (try? c.decode(Int.self, forKey: .until)) ?? fallback.until
      days = (try? c.decode([Int].self, forKey: .days)) ?? fallback.days
      day = (try? c.decode(Int.self, forKey: .day)) ?? fallback.day
      every = (try? c.decode(Int.self, forKey: .every)) ?? fallback.every
    }

    /// 收拾成能用的：时刻夹进一天里，时段的结束不早于开始（否则到半夜），星期去重排序、一天都没勾当七天都勾，
    /// 几号夹进 1…31，间隔夹进 5 分钟…12 小时，时刻不是有限数的换成很久以前（一次的提醒就是错过了）
    var sanitized: Schedule {
      var next = self
      next.time = min(max(time, 0), 1439)
      next.until = until > next.time && until <= 1440 ? until : 1440
      let days = Set(days.filter { (1...7).contains($0) }).sorted()
      next.days = days.isEmpty ? Self.allDays : days
      next.day = min(max(day, 1), 31)
      next.every = min(max(every, 5), 720)
      if !date.timeIntervalSinceReferenceDate.isFinite { next.date = .distantPast }
      return next
    }
  }

  /// 怎么提醒（C1，从轻到重）
  enum Alert: String, Codable, CaseIterable {
    /// 刘海岛上挂着，直到点「知道了」「稍后」（C2）
    case light
    /// 所有屏幕四边一圈强调色的光 + 刘海岛（C3）
    case glow
    /// 盖住所有屏的告示 + 按钮，不拦键盘鼠标（C4）
    case full
    /// 进入状态屏的某个状态（C1 的强制版，C12：进不去时退成全屏）
    case status

    var titleResource: LocalizedStringResource {
      switch self {
      case .light: "轻提醒"
      case .glow:
        LocalizedStringResource("reminders.glow", defaultValue: "边框", comment: "提醒方式：屏幕四边一圈光")
      case .full:
        LocalizedStringResource("reminders.full", defaultValue: "全屏", comment: "提醒方式：盖住所有屏幕")
      case .status:
        LocalizedStringResource(
          "reminders.statusAlert", defaultValue: "进入状态屏",
          comment: "短说法：提醒方式的第四种（分段控件里，英文写 Status Screen 放得下）")
      }
    }
    var title: String { String(localized: titleResource) }

    /// 详情页选中这一种时下面的一句话
    var explanation: String {
      switch self {
      case .light: String(localized: "刘海岛上挂着，点了「知道了」或「稍后」才收")
      case .glow: String(localized: "屏幕四边一圈光，鼠标点得穿，刘海岛上同时挂着")
      case .full: String(localized: "盖住所有屏幕，键盘鼠标照常能用")
      case .status: String(localized: "到点进入一个状态，拦住键盘鼠标；要辅助功能授权")
      }
    }
  }

  /// 声音（C9）：只响一声
  enum Sound: String, Codable, CaseIterable {
    case none, chime, speak

    var titleResource: LocalizedStringResource {
      switch self {
      case .none:
        LocalizedStringResource("reminders.noSound", defaultValue: "无", comment: "提醒的声音：不出声")
      case .chime: "提示音"
      case .speak: "朗读标题"
      }
    }
    var title: String { String(localized: titleResource) }
  }

  var id: String
  var title: String
  var detail: String?
  /// 表情 id（StatusEmoji.ids 里的一个）或自己挑的系统表情（那个字）；空 = 不要图标
  var symbol: String
  var isOn: Bool
  var schedule: Schedule
  var alert: Alert
  /// 进入哪个状态（alert 是 status 时；状态屏的状态 id，找不到时用排在最前面的那个）
  var statusID: String
  /// 全屏多久自己收（秒，fullChoices 里的一个；0 = 点了才收，C5）
  var fullSeconds: Int
  var sound: Sound
  /// 提示音的编号（ReminderSound：系统 / 个人「声音」文件夹里的声音名，或「file:文件名」= 自己选的文件）
  var chime: String
  /// 没理会时每隔几分钟再催一次（0 = 不催，C10；1–120，菜单里是 nagChoices，别的是「自定义…」填的）
  var nagMinutes: Int
  /// 专注模式时也照常提醒（2026-11-17 拍板 B4，默认关）：加了「提醒」滤镜的专注模式开着时这一条不压着，照上面的方式出
  var duringFocus: Bool

  static let maxCount = 50
  static let maxTitle = 30
  static let maxDetail = 60
  /// id 的长度上限
  static let maxID = 64
  static let fullChoices = [0, 20, 60, 300]
  /// 2026-11-04 用户要 1 分钟：菜单里照 Due 的那一排（1 / 5 / 10 / 15 / 30 / 60），另有「自定义…」填 1–120（用户定）
  static let nagChoices = [0, 1, 5, 10, 15, 30, 60]
  static let nagRange = 1...120
  /// 「稍后」推多久（设置 › 提醒，Prefs.remindersSnoozeMinutes，C8）
  static let snoozeChoices = [5, 10, 15, 30]
  /// 系统自带的提示音（/System/Library/Sounds 里的文件名）和界面上的叫法；个人文件夹里的、自己选的见 ReminderSound
  static var chimes: [(name: String, title: String)] {
    chimeNames.map { ($0, chimeTitle($0).map { String(localized: $0) } ?? $0) }
  }
  static let chimeNames = [
    "Glass", "Ping", "Tink", "Pop", "Purr", "Hero", "Submarine", "Bottle", "Funk", "Frog", "Morse",
    "Blow", "Basso", "Sosumi",
  ]

  /// 系统提示音的叫法（英文就是系统里的名字）；Sosumi 不翻（函数直接 return switch：元组里的字只有第一个抽得进目录）
  static func chimeTitle(_ name: String) -> LocalizedStringResource? {
    switch name {
    case "Glass": "玻璃"
    case "Ping": "叮"
    case "Tink": "叮当"
    case "Pop": "啵"
    case "Purr": "呼噜"
    case "Hero": "号角"
    case "Submarine": "潜艇"
    case "Bottle": "瓶子"
    case "Funk": "放克"
    case "Frog": "青蛙"
    case "Morse": "摩斯"
    case "Blow": "吹气"
    case "Basso": "低音"
    default: nil
    }
  }
  static let defaultChime = "Glass"

  init(
    id: String, title: String, detail: String? = nil, symbol: String = "", isOn: Bool = true,
    schedule: Schedule, alert: Alert = .light, statusID: String = "", fullSeconds: Int = 0,
    sound: Sound = .chime, chime: String = defaultChime, nagMinutes: Int = 0,
    duringFocus: Bool = false
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.symbol = symbol
    self.isOn = isOn
    self.schedule = schedule
    self.alert = alert
    self.statusID = statusID
    self.fullSeconds = fullSeconds
    self.sound = sound
    self.chime = chime
    self.nagMinutes = nagMinutes
    self.duringFocus = duringFocus
  }

  /// 逐个字段兜底：只有 id 和标题是必须的，别的缺了、不认识就用默认值（sanitized 再收拾一遍）
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    detail = try? c.decode(String.self, forKey: .detail)
    symbol = (try? c.decode(String.self, forKey: .symbol)) ?? ""
    isOn = (try? c.decode(Bool.self, forKey: .isOn)) ?? false
    schedule =
      (try? c.decode(Schedule.self, forKey: .schedule)) ?? Schedule(kind: .once, date: .distantPast)
    alert = (try? c.decode(Alert.self, forKey: .alert)) ?? .light
    statusID = (try? c.decode(String.self, forKey: .statusID)) ?? ""
    fullSeconds = (try? c.decode(Int.self, forKey: .fullSeconds)) ?? 0
    sound = (try? c.decode(Sound.self, forKey: .sound)) ?? .chime
    chime = (try? c.decode(String.self, forKey: .chime)) ?? Self.defaultChime
    nagMinutes = (try? c.decode(Int.self, forKey: .nagMinutes)) ?? 0
    duringFocus = (try? c.decode(Bool.self, forKey: .duringFocus)) ?? false
  }

  /// 示例（F1）：默认都关着，打开才响。id 固定，「恢复示例提醒」按它认。存的照旧是这份中文原文（拍板 D6），
  /// 显示用 displayTitle / displayDetail：按 id + 标题是不是示例标题的某种语言写法认出没改过的
  static let examples = [
    Reminder(
      id: "water", title: "喝水", symbol: "hot-beverage", isOn: false,
      schedule: Schedule(kind: .interval, days: Schedule.workdays, every: 60)),
    Reminder(
      id: "eyes", title: "休息眼睛", detail: "看看 6 米外的地方，20 秒", symbol: "sleeping-face",
      isOn: false,
      schedule: Schedule(kind: .interval, time: 0, until: 1440, every: 20), alert: .full,
      fullSeconds: 20),
    Reminder(
      id: "walk", title: "起来走走", symbol: "waving-hand", isOn: false,
      schedule: Schedule(kind: .interval, days: Schedule.workdays, every: 45), alert: .glow),
  ]

  /// 把一张列表收拾成能用的（纯函数）：标题去首尾空白、换行当空格，空的整条丢掉、超过 30 字截断；说明同样收拾、
  /// 最多 60 字、空了就是没有；图标不在表情清单里的置空；时间规则收拾一遍；几个选项不是可选值的换成默认；
  /// id 为空、太长、重复的丢掉（留先出现的）；最多 50 条。结果可以是空的（用户删光了）
  static func sanitized(_ reminders: [Reminder]) -> [Reminder] {
    var seen: Set<String> = []
    var result: [Reminder] = []
    for var reminder in reminders {
      reminder.title = String(oneLine(reminder.title).prefix(maxTitle))
      guard !reminder.title.isEmpty, !reminder.id.isEmpty, reminder.id.count <= maxID,
        seen.insert(reminder.id).inserted
      else { continue }
      let detail = String(oneLine(reminder.detail ?? "").prefix(maxDetail))
      reminder.detail = detail.isEmpty ? nil : detail
      reminder.symbol =
        StatusEmoji.isValid(reminder.symbol) ? StatusEmoji.canonical(reminder.symbol) : ""
      reminder.schedule = reminder.schedule.sanitized
      if reminder.statusID.count > maxID { reminder.statusID = "" }
      if !fullChoices.contains(reminder.fullSeconds) { reminder.fullSeconds = 0 }
      // 别的 Mac 上的声音这台没有也留着（到点响默认的）：只丢编号本身不合规的
      if !ReminderSound.isValid(reminder.chime) { reminder.chime = defaultChime }
      if reminder.nagMinutes != 0, !nagRange.contains(reminder.nagMinutes) {
        reminder.nagMinutes = 0
      }
      result.append(reminder)
      if result.count == maxCount { break }
    }
    return result
  }

  static func oneLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  /// 偏好里存的数据 → 列表：没存过是示例；存过但解不出整张（不是 JSON 数组）也用示例，能解出的照收拾过的用（可以是空的）
  static func decode(_ data: Data?) -> [Reminder] {
    guard let data, let stored = try? JSONDecoder().decode([Lenient].self, from: data) else {
      return examples
    }
    return sanitized(stored.compactMap(\.reminder))
  }

  /// 一条解不出（缺 id、标题）只丢这一条，不连累整张
  private struct Lenient: Decodable {
    let reminder: Reminder?
    init(from decoder: Decoder) throws { reminder = try? Reminder(from: decoder) }
  }

  static func load(_ defaults: UserDefaults = .standard) -> [Reminder] {
    decode(defaults.data(forKey: Prefs.reminders))
  }

  /// 存进偏好的数据：收拾过的列表的 JSON
  static func encoded(_ reminders: [Reminder]) -> Data? {
    try? JSONEncoder().encode(sanitized(reminders))
  }

  static func save(_ reminders: [Reminder], to defaults: UserDefaults = .standard) {
    defaults.set(encoded(reminders), forKey: Prefs.reminders)
  }

  /// 导入时并进本机的列表：按 id 更新和添加、顺序先照文件里的，本机独有的接在后面（不删：同状态屏的状态）。
  /// 超过上限时少加文件里新的，不挤掉本机的；文件里本机没有、时间已经过了的一次性提醒不加（旧备份里早就点过「知道了」的）
  static func merged(_ incoming: [Reminder], into local: [Reminder], now: Date = .now) -> [Reminder]
  {
    let localIDs = Set(local.map(\.id))
    let fresh = incoming.filter {
      !localIDs.contains($0.id) && !($0.schedule.kind == .once && $0.schedule.date <= now)
    }
    let room = max(0, maxCount - sanitized(local).count)
    let added = Set(sanitized(fresh).prefix(room).map(\.id))
    let kept = incoming.filter { localIDs.contains($0.id) || added.contains($0.id) }
    return sanitized(kept + local.filter { mine in !incoming.contains { $0.id == mine.id } })
  }

  // MARK: 设置 › 提醒（纯函数；存之前 encoded 再收拾一遍）

  /// 新加的一条：标题「新提醒」（存进去就是用户的，按加的那一刻的语言写）、一次、下一个整点（离现在不到 10 分钟就再下一个）、
  /// 轻提醒、提示音、开着。「+」›「新提醒」先不存，详情页里第一次改动时才加进列表（saving）
  static func new(id: String = UUID().uuidString, now: Date = .now, calendar: Calendar = .current)
    -> Reminder
  {
    let hour = calendar.dateInterval(of: .hour, for: now.addingTimeInterval(600))?.end ?? now
    return Reminder(
      id: id, title: String(localized: "新提醒"), schedule: Schedule(kind: .once, date: hour))
  }

  /// 详情页「日期和时间」选到的那一刻：秒数归零（选择器只到分钟）。选得比下限早时系统的选择器把值夹成下限本身、
  /// 连秒带毫秒，原来下限是「现在」，存进去的就是「17:47:05.267」，倒数看着从 58 秒起（2026-11-17 反馈）
  static func picked(_ date: Date, calendar: Calendar = .current) -> Date {
    calendar.dateInterval(of: .minute, for: date)?.start ?? date
  }

  /// 详情页最早能选到哪一刻：现在之后的下一个整分（正好在整分上也是下一分钟：这一分钟已经到了）
  static func earliestPick(after now: Date, calendar: Calendar = .current) -> Date {
    calendar.dateInterval(of: .minute, for: now)?.end ?? now
  }

  /// 加到末尾；已经有 maxCount 条就不加
  static func adding(_ reminder: Reminder, to list: [Reminder]) -> [Reminder] {
    list.count < maxCount ? list + [reminder] : list
  }

  static func removing(_ id: String, from list: [Reminder]) -> [Reminder] {
    list.filter { $0.id != id }
  }

  /// 上移（-1）/ 下移（+1）一格；到头了、找不到都原样返回
  static func moving(_ id: String, by offset: Int, in list: [Reminder]) -> [Reminder] {
    guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + offset)
    else { return list }
    var list = list
    list.swapAt(index, index + offset)
    return list
  }

  /// 列表里缺的示例（按 id 认）
  static func missingExamples(in list: [Reminder]) -> [Reminder] {
    examples.filter { example in !list.contains { $0.id == example.id } }
  }

  /// 恢复示例提醒：缺的补到末尾（关着），已有的不动；补到 maxCount 为止
  static func restoringExamples(in list: [Reminder]) -> [Reminder] {
    Array((list + missingExamples(in: list)).prefix(maxCount))
  }

  /// 删之前要不要确认：和示例一模一样的不用（能从「+」原样加回来；开没开不算），自己加的、改过的要。
  /// 标题、说明是示例那段话的中文或英文写法都算没改过
  var isPristine: Bool {
    guard let original = Self.examples.first(where: { $0.id == id }) else { return false }
    var normalized = self
    normalized.isOn = false
    if Self.exampleTitle(id).map(StatusPreset.spellings)?.contains(title) == true {
      normalized.title = original.title
    }
    if let detail, Self.exampleDetail(id).map(StatusPreset.spellings)?.contains(detail) == true {
      normalized.detail = original.detail
    }
    return normalized == original
  }

  // MARK: 示例显示时翻（存的照旧是中文）

  /// 示例的标题（中文原文就是 examples 里存的）
  static func exampleTitle(_ id: String) -> LocalizedStringResource? {
    switch id {
    case "water": "喝水"
    case "eyes": "休息眼睛"
    case "walk": "起来走走"
    default: nil
    }
  }

  static func exampleDetail(_ id: String) -> LocalizedStringResource? {
    switch id {
    case "eyes": "看看 6 米外的地方，20 秒"
    default: nil
    }
  }

  /// 没改过的示例标题：按界面语言显示；改过的、自己加的是 nil
  var exampleTitle: LocalizedStringResource? {
    Self.exampleTitle(id).flatMap { StatusPreset.spellings($0).contains(title) ? $0 : nil }
  }

  /// 显示的标题：没改过的示例按界面语言翻（「喝水」在英文界面是 Drink Water），别的照存的写
  var displayTitle: String { exampleTitle.map { String(localized: $0) } ?? title }

  /// 显示的说明（同 displayTitle）
  var displayDetail: String? {
    guard let detail, let text = Self.exampleDetail(id),
      StatusPreset.spellings(text).contains(detail)
    else { return detail }
    return String(localized: text)
  }

  /// 详情页存一下：列表里有的按 id 换掉（updating）；还没存过的新提醒（fresh：「+」›「新提醒」推进来的那一条）
  /// 第一次改动时才加到末尾，满了不加。没改就离开（退回、换页、关窗）的什么都不留——同系统提醒事项里点了「+」又点别处，
  /// 空着的那行不留；原来一点「+」就存进去、开着，看一眼就退回的那条下一个整点平白响一次，点了「知道了」又自己删掉、
  /// 列表里找不到是谁（2026-11-05 用户报「没开任何提醒，刘海却提示新提醒」）
  static func saving(_ draft: Reminder, to list: [Reminder], fresh: Reminder?) -> [Reminder] {
    if list.contains(where: { $0.id == draft.id }) { return updating(list, with: draft) }
    guard let fresh, fresh.id == draft.id else { return list }
    return adding(updating([fresh], with: draft)[0], to: list)
  }

  /// 详情页改了一条：按 id 换掉。标题只有空白时留着原来的标题（空标题存不下，输入框里删光了重打是常事）
  static func updating(_ list: [Reminder], with draft: Reminder) -> [Reminder] {
    list.map { stored in
      guard stored.id == draft.id else { return stored }
      var next = draft
      if oneLine(draft.title).isEmpty { next.title = stored.title }
      return next
    }
  }

  /// 详情页里正在改的这一条有什么问题（页头的橙字；nil = 没问题）。不拦着改：存进去的是收拾过的
  func problem(now: Date = .now) -> String? {
    let title = Self.oneLine(title)
    if title.isEmpty { return String(localized: "还没填标题") }
    if title.count > Self.maxTitle {
      return String(localized: "标题最多 \(Self.maxTitle) 个字，后面的不会保存")
    }
    if Self.oneLine(detail ?? "").count > Self.maxDetail {
      return String(localized: "说明最多 \(Self.maxDetail) 个字，后面的不会保存")
    }
    if schedule.kind == .once, schedule.date <= now {
      return String(localized: "这个时间已经过了，不会再提醒")
    }
    if schedule.kind == .interval, schedule.until - schedule.time < schedule.every {
      return String(localized: "这段时间比间隔还短，可能一次都不提醒")
    }
    return nil
  }

  // MARK: 摘要

  /// 列表行的一行小字：什么时候 · 怎么提醒（「工作日 9:00–18:00 每 60 分钟 · 轻提醒」「明天 9:00 · 全屏 20 秒」）
  func summary(now: Date = .now, calendar: Calendar = .current, statusTitle: String? = nil)
    -> String
  {
    let how: String =
      switch alert {
      case .full:
        fullSeconds == 0
          ? alert.title : String(localized: "全屏 \(Self.durationTitle(fullSeconds))")
      case .status: statusTitle.map { String(localized: "进入「\($0)」") } ?? alert.title
      default: alert.title
      }
    return schedule.summary(now: now, calendar: calendar) + " · " + how
  }

  /// 「20 秒」「1 分钟」「5 分钟」
  static func durationTitle(_ seconds: Int) -> String {
    seconds < 60 ? String(localized: "\(seconds) 秒") : String(localized: "\(seconds / 60) 分钟")
  }

  /// 一天里的第几分钟 → 「9:00」「18:30」「24:00」：跟界面语言和系统的 12 / 24 小时（Locale.current，中文 24 小时制下
  /// 和以前手拼的一样）；1440（时段到半夜）中文写「24:00」、英文 midnight
  static func clock(_ minutes: Int) -> String {
    guard minutes < 1440 else {
      return String(
        localized: "reminders.midnight", defaultValue: "24:00",
        comment: "时段的结束是半夜（9:00–24:00 的 24:00）")
    }
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.timeZone = .gmt
    return Date(timeIntervalSinceReferenceDate: TimeInterval(max(minutes, 0) * 60)).formatted(style)
  }

  /// 星期几的名字（Calendar 的 weekday：1 = 周日 … 7 = 周六），跟界面语言：中文「日」「一」…，英文「Sun」「Mon」…
  /// （摘要里「每周一、三、五」/「Every Mon, Wed, Fri」）
  static var weekdayNames: [String] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = .current
    return Locale.current.language.languageCode == .chinese
      ? calendar.veryShortStandaloneWeekdaySymbols : calendar.shortStandaloneWeekdaySymbols
  }
}

nonisolated extension Reminder.Schedule {
  /// 「每天」「工作日」「周末」「每周一、三、五」
  var daysTitle: String {
    switch days {
    case Self.allDays: return String(localized: "每天")
    case Self.workdays: return String(localized: "工作日")
    case [1, 7]: return String(localized: "周末")
    default:
      let names = Reminder.weekdayNames
      // 周一排在前面、周日排最后（中文的习惯）
      let ordered = days.filter { $0 != 1 } + (days.contains(1) ? [1] : [])
      let list = ordered.map { names[$0 - 1] }.joinedAsList()
      return String(
        localized: "reminders.everyWeekdays", defaultValue: "每周\(list)",
        comment: "每周勾了的那几天：「每周一、三、五」（%@ 是星期几连成的一串）")
    }
  }

  /// 摘要里「什么时候」那一段
  func summary(now: Date, calendar: Calendar) -> String {
    switch kind {
    case .once:
      var style = Date.FormatStyle(date: .omitted, time: .shortened)
      style.calendar = calendar
      style.timeZone = calendar.timeZone
      let time = date.formatted(style)
      if calendar.isDate(date, inSameDayAs: now) {
        return String(
          localized: "reminders.today", defaultValue: "今天 \(time)", comment: "提醒的时间：今天 14:30")
      }
      if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
        calendar.isDate(date, inSameDayAs: tomorrow)
      {
        return String(
          localized: "reminders.tomorrow", defaultValue: "明天 \(time)", comment: "提醒的时间：明天 9:00")
      }
      var day = Date.FormatStyle().month(.defaultDigits).day()
      if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
      day.calendar = calendar
      day.timeZone = calendar.timeZone
      return String(
        localized: "reminders.dateTime", defaultValue: "\(date.formatted(day)) \(time)",
        comment: "提醒的时间：11月3日 9:00（日期、钟点）")
    case .weekly:
      return String(
        localized: "reminders.weeklyAt", defaultValue: "\(daysTitle) \(Reminder.clock(time))",
        comment: "每周的提醒：「工作日 9:00」「每周一、三 9:00」（哪几天、钟点）")
    case .monthly:
      return String(localized: "每月 \(day) 号 \(Reminder.clock(time))")
    case .interval:
      let span =
        time == 0 && until == 1440
        ? nil : Reminder.clock(time) + "–" + Reminder.clock(until)
      let when = days == Self.allDays ? nil : daysTitle
      let prefix = [when, span].compactMap { $0 }.joined(separator: " ")
      return prefix.isEmpty
        ? String(localized: "每 \(every) 分钟")
        : String(
          localized: "reminders.intervalWithin", defaultValue: "\(prefix) 每 \(every) 分钟",
          comment: "间隔提醒：「工作日 9:00–18:00 每 60 分钟」（%1$@ 是哪几天、哪一段时间）")
    }
  }
}
