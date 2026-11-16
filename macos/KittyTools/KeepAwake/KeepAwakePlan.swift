// 保持唤醒（第一个插件，2026-11-12 拍板 B2，PLAN §10「保持唤醒」）的纯函数，单测锁住（KeepAwakeTests）：
// - 定时（Schedule）：一条，勾星期几 + 一天里的时段；时段在里面就保持唤醒、出了就停。结束早于开始 = 跨午夜，算在开始那天
//   （周五 22:00–02:00 管到周六凌晨两点）；「全天」单独一个开关（allDay）：开始等于结束不当全天（拨时间选择器时两边会
//   短暂相等），只是那天没有时段。几点用日历按当天的钟点算（夏令时那天不差一小时）。下一次要变的时刻只算真的进 / 出的那一刻
//   （连着的两天全天之间的半夜不算）。
// - 启动器「awake 2小时」「保持唤醒 到18点」「awake 30m」「awake 无限期」：多久之后、几点都借提醒的解析（ReminderPhrase），
//   时间以外只许剩下「到 / 直到 / 至 / until」这类连接词，别的字认不出就给 .invalid（不猜）。
//   英文（2026-11-16 多语言第 10 批）：多久之后提醒那边本来就认（2h、2 hours、30 min、half an hour），18:00 也认；另补
//   for / until / till、indefinitely，和这里自己认的 6pm、6:30 pm、tomorrow 8:00（englishMoment；提醒那边不认，不动它）。
// - 剩多久的说法（菜单栏、启动器、设置页、岛上同一句）：跟界面语言，钟点用 FormatStyle（中文 24 小时制下和以前手拼的一样）。

import Foundation

nonisolated enum KeepAwakePlan {
  /// 设置 › 保持唤醒「定时」（存成 JSON 文字，Prefs.keepAwakeSchedule；跟着这台 Mac，不同步）
  struct Schedule: Codable, Equatable, Sendable {
    var isOn = false
    /// 日历的星期（1 = 周日 … 7 = 周六）；默认工作日
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// 一天里的第几分钟（0…1439）；默认 9:00–18:00
    var start = 9 * 60
    var end = 18 * 60
    /// 那天整整 24 小时（勾了全天时 start / end 留着，关掉全天回到原来的时段）
    var allDay = false

    /// 偏好里读出来：读不出、字段越界的回到默认（设置导入、同步不带它，但偏好可能被手改）
    static func decode(_ text: String) -> Schedule {
      guard let data = text.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(Schedule.self, from: data)
      else { return Schedule() }
      var schedule = decoded
      schedule.weekdays = schedule.weekdays.filter { (1...7).contains($0) }
      schedule.start = min(max(schedule.start, 0), 24 * 60 - 1)
      schedule.end = min(max(schedule.end, 0), 24 * 60 - 1)
      return schedule
    }

    var encoded: String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// 从 day 那天开始的那一段（day 是哪天的哪一刻都行，只看日期）；那天没勾的给 nil
    func window(startingOn day: Date, calendar: Calendar) -> DateInterval? {
      let midnight = calendar.startOfDay(for: day)
      guard weekdays.contains(calendar.component(.weekday, from: midnight)) else { return nil }
      if allDay {
        return calendar.date(byAdding: .day, value: 1, to: midnight).map {
          DateInterval(start: midnight, end: $0)
        }
      }
      guard start != end,
        let from = calendar.date(
          bySettingHour: start / 60, minute: start % 60, second: 0, of: midnight),
        let next = calendar.date(byAdding: .day, value: end > start ? 0 : 1, to: midnight),
        let to = calendar.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: next),
        to > from
      else { return nil }
      return DateInterval(start: from, end: to)
    }

    /// 这一刻在不在时段里（定时开着才算）
    func contains(_ date: Date, calendar: Calendar) -> Bool {
      isOn
        && windows(around: date, calendar: calendar).contains { $0.start <= date && date < $0.end }
    }

    /// 这一刻之后下一次真的进 / 出时段的时刻（到时候重新算一遍）；连着的两段之间的接缝不算。定时关着、一天都没勾、
    /// 一直在时段里（每天全天）的给 nil
    func nextChange(after date: Date, calendar: Calendar) -> Date? {
      guard isOn else { return nil }
      let now = contains(date, calendar: calendar)
      return windows(around: date, calendar: calendar).flatMap { [$0.start, $0.end] }
        .filter { $0 > date }.sorted().first { contains($0, calendar: calendar) != now }
    }

    /// 前一天起往后一周多的每一段（跨午夜的前一天那段管到今天凌晨）
    private func windows(around date: Date, calendar: Calendar) -> [DateInterval] {
      (-1...8).compactMap { offset in
        calendar.date(byAdding: .day, value: offset, to: date).flatMap {
          window(startingOn: $0, calendar: calendar)
        }
      }
    }

    /// 「工作日 9:00–18:00」「周二、周六 22:00–次日 2:00」「每天 全天」：岛上的说法（跟界面语言：Weekdays 9:00–18:00）
    var summary: String {
      let days: String =
        switch weekdays {
        case [2, 3, 4, 5, 6]: String(localized: "工作日")
        case Set(1...7): String(localized: "每天")
        case [1, 7]: String(localized: "周末")
        case []: String(localized: "没选哪天")
        default: Self.order.filter(weekdays.contains).map { Self.names[$0 - 1] }.joinedAsList()
        }
      if allDay {
        return String(
          localized: "keepAwake.allDay", defaultValue: "\(days) 全天", comment: "定时：「每天 全天」（%@ 是哪几天）")
      }
      let from = Reminder.clock(start)
      let to = Reminder.clock(end)
      return end < start
        ? String(
          localized: "keepAwake.overnight", defaultValue: "\(days) \(from)–次日 \(to)",
          comment: "定时跨过半夜：「周五 22:00–次日 2:00」（哪几天、开始、结束）")
        : String(
          localized: "keepAwake.span", defaultValue: "\(days) \(from)–\(to)",
          comment: "定时：「工作日 9:00–18:00」（哪几天、开始、结束）")
    }

    /// 周一排在最前（设置页的那一排也是这个顺序）
    static let order = [2, 3, 4, 5, 6, 7, 1]
    /// 「周日」「周一」…，英文「Sun」「Mon」…（跟界面语言）
    static var names: [String] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.locale = .current
      return calendar.shortStandaloneWeekdaySymbols
    }
  }

  // MARK: 一段要多久

  /// 菜单栏子菜单、设置页「开始」的几档（nil = 无限期）；title 是「30 分钟」「无限期」（跟界面语言）
  static var presets: [(title: String, minutes: Int?)] {
    [30, 60, 120, 300, nil].map { (title(minutes: $0), $0) }
  }

  /// 一档的说法：「2 小时」，nil 是「无限期」
  static func title(minutes: Int?) -> String {
    minutes.map(length) ?? String(localized: "无限期")
  }

  /// 启动器里「awake」后面那截解析出来的样子
  enum Parsed: Equatable {
    /// 什么都没写（列几档让你挑）
    case empty
    case indefinitely
    /// 到这一刻；label 是行上写的「2 小时」「到 18:00」
    case until(Date, label: String)
    /// 写了认不出的
    case invalid
  }

  /// 无限期的几种写法
  private static let forever = [
    "无限期", "无限", "一直", "永久", "不限", "forever", "indefinitely", "indefinite", "always", "∞",
  ]
  /// 「到 18 点」里的连接词：去掉之后什么都不剩才算认出来了（for：「awake for 2 hours」）
  private static let joiners = [
    "直到", "一直到", "到", "至", "until", "till", "to", "for", "后", "以后", "之后",
  ]

  static func parse(_ raw: String, now: Date, calendar: Calendar) -> Parsed {
    let text = ReminderPhrase.halfWidth(raw).trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return .empty }
    if forever.contains(text.lowercased()) { return .indefinitely }
    // 两样都有时按先出现的（同提醒）
    let span = ReminderPhrase.duration(in: text)
    let point =
      englishMoment(in: text, now: now, calendar: calendar)
      ?? ReminderPhrase.moment(in: text, now: now, calendar: calendar)
    if let span, point == nil || span.1.lowerBound <= point!.1.lowerBound {
      guard leftover(text, removing: span.1) else { return .invalid }
      return .until(now.addingTimeInterval(span.0 * 60), label: length(minutes: Int(span.0)))
    }
    if let point, point.0 > now {
      guard leftover(text, removing: point.1) else { return .invalid }
      return .until(point.0, label: until(point.0, now: now, calendar: calendar))
    }
    return .invalid
  }

  /// 英文的几点（提醒的解析只认中文和「18:00」）：6pm、6:30 pm（13pm、18:00 pm 不认）；前面可带 tomorrow（「tomorrow 8:00」
  /// 「tomorrow 9am」）。没说 tomorrow 的过了就是明天；tomorrow 8:00 这种不带 am / pm 的照 24 小时制。只写「18:00」的
  /// 不在这里认（交给提醒的解析：「到 6:00」取最近的那个将来时刻，同中文）
  static func englishMoment(in text: String, now: Date, calendar: Calendar) -> (
    Date, Range<String.Index>
  )? {
    guard
      let match = text.firstMatch(
        of: /(?i)(?:\b(tomorrow)\s+(?:at\s+)?)?\b([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)?\b/),
      match.output.4 != nil || (match.output.1 != nil && match.output.3 != nil),
      var hour = Int(match.output.2), let minute = Int(match.output.3 ?? "0"), minute < 60
    else { return nil }
    if let half = match.output.4?.lowercased() {
      guard (1...12).contains(hour) else { return nil }
      hour = hour % 12 + (half == "pm" ? 12 : 0)
    }
    let today = calendar.startOfDay(for: now)
    guard hour < 24,
      var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today)
    else { return nil }
    if match.output.1 != nil || date <= now {
      guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
      date = next
    }
    return (date, match.range)
  }

  /// 时间那一段去掉之后，剩下的只有连接词
  private static func leftover(_ text: String, removing range: Range<String.Index>) -> Bool {
    var rest = (text[..<range.lowerBound] + text[range.upperBound...]).lowercased()
      .replacingOccurrences(of: " ", with: "")
    for word in joiners.sorted(by: { $0.count > $1.count }) {
      rest = rest.replacingOccurrences(of: word, with: "")
    }
    return rest.isEmpty
  }

  /// 「2 小时」「1 小时 30 分钟」「45 分钟」（英文 2 hours、1 hour 30 minutes）
  static func length(minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return String(localized: "\(rest) 分钟") }
    // 小时、分钟两段各自的单复数，中间一个空格（中英都这么写）
    return rest == 0
      ? String(localized: "\(hours) 小时")
      : String(localized: "\(hours) 小时") + " " + String(localized: "\(rest) 分钟")
  }

  /// 「到 18:00」「到 明天 8:00」：一段管到哪（行上的说法）
  static func until(_ date: Date, now: Date, calendar: Calendar) -> String {
    let when = moment(date, now: now, calendar: calendar)
    return String(
      localized: "keepAwake.until", defaultValue: "到 \(when)",
      comment: "保持唤醒管到哪一刻：「到 18:00」「到 明天 8:00」")
  }

  /// 「18:00」「明天 8:00」「11月20日 9:00」：到哪一刻（跟界面语言和系统的 12 / 24 小时）
  static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    let time = date.formatted(style)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
      calendar.isDate(date, inSameDayAs: tomorrow)
    {
      return String(
        localized: "keepAwake.tomorrow", defaultValue: "明天 \(time)",
        comment: "保持唤醒管到明天的几点：「明天 8:00」")
    }
    var day = Date.FormatStyle().month(.defaultDigits).day()
    day.calendar = calendar
    day.timeZone = calendar.timeZone
    return String(
      localized: "keepAwake.dateTime", defaultValue: "\(date.formatted(day)) \(time)",
      comment: "保持唤醒管到哪天的几点：「11月20日 9:00」（日期、钟点）")
  }

  /// 「还剩 1 小时 12 分」「还剩 42 分」「还剩不到 1 分钟」；nil（无限期）是「无限期」
  static func remaining(until end: Date?, now: Date) -> String {
    guard let end else { return String(localized: "无限期") }
    let minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up))
    if minutes <= 1 { return String(localized: "还剩不到 1 分钟") }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return String(localized: "还剩 \(rest) 分") }
    return rest == 0
      ? String(localized: "还剩 \(hours) 小时") : String(localized: "还剩 \(hours) 小时 \(rest) 分")
  }

  // MARK: 启动器的关键词

  /// 「awake 2小时」「保持唤醒 到18点」「防息屏 30m」：关键词后面要有空格（只打关键词的走内置动作那一行，同提醒）
  static let keywords = ["awake", "保持唤醒", "防息屏"]

  /// 关键词后面的那截；不是这几个关键词加空格开头的给 nil。中文的关键词后面不打空格也认（「保持唤醒2小时」「防息屏到18点」），
  /// 只打关键词本身的照旧给 nil
  static func query(_ text: String) -> String? {
    let lower = text.lowercased()
    for keyword in keywords {
      let joined = !keyword.allSatisfy(\.isASCII) && lower.count > keyword.count
      guard lower.hasPrefix(keyword + " ") || (joined && lower.hasPrefix(keyword)) else { continue }
      return String(text.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
}

nonisolated extension KeepAwakePlan.Schedule {
  /// 缺哪个字段用默认值（手改过的偏好、以后加了字段的旧写法不至于整条读丢）；写在扩展里，留着成员初始化方法
  init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = Self()
    self.init(
      isOn: try fields.decodeIfPresent(Bool.self, forKey: .isOn) ?? fallback.isOn,
      weekdays: try fields.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? fallback.weekdays,
      start: try fields.decodeIfPresent(Int.self, forKey: .start) ?? fallback.start,
      end: try fields.decodeIfPresent(Int.self, forKey: .end) ?? fallback.end,
      allDay: try fields.decodeIfPresent(Bool.self, forKey: .allDay) ?? fallback.allDay)
  }
}
