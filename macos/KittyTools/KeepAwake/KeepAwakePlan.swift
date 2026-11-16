// 保持唤醒（第一个插件，2026-11-12 拍板 B2，PLAN §10「保持唤醒」）的纯函数，单测锁住（KeepAwakeTests）：
// - 定时（Schedule）：一条，勾星期几 + 一天里的时段；时段在里面就保持唤醒、出了就停。结束早于开始 = 跨午夜，算在开始那天
//   （周五 22:00–02:00 管到周六凌晨两点）；「全天」单独一个开关（allDay）：开始等于结束不当全天（拨时间选择器时两边会
//   短暂相等），只是那天没有时段。几点用日历按当天的钟点算（夏令时那天不差一小时）。下一次要变的时刻只算真的进 / 出的那一刻
//   （连着的两天全天之间的半夜不算）。
// - 启动器「awake 2小时」「保持唤醒 到18点」「awake 30m」「awake 无限期」：多久之后、几点都借提醒的解析（ReminderPhrase），
//   时间以外只许剩下「到 / 直到 / 至 / until」这类连接词，别的字认不出就给 .invalid（不猜）。
// - 剩多久的说法（菜单栏、启动器、设置页、岛上同一句）。

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

    /// 「工作日 9:00–18:00」「周六、周日 22:00–次日 2:00」「每天 全天」：设置页、岛上的说法
    var summary: String {
      let days: String =
        switch weekdays {
        case [2, 3, 4, 5, 6]: "工作日"
        case Set(1...7): "每天"
        case [1, 7]: "周末"
        case []: "没选哪天"
        default:
          Self.order.filter(weekdays.contains).map { "周" + Self.names[$0 - 1] }
            .joined(separator: "、")
        }
      if allDay { return days + " 全天" }
      return days + " \(Self.clock(start))–" + (end < start ? "次日 " : "") + Self.clock(end)
    }

    /// 周一排在最前（设置页的那一排也是这个顺序）
    static let order = [2, 3, 4, 5, 6, 7, 1]
    static let names = ["日", "一", "二", "三", "四", "五", "六"]

    static func clock(_ minutes: Int) -> String { "\(minutes / 60):" + pad(minutes % 60) }
  }

  // MARK: 一段要多久

  /// 菜单栏子菜单、设置页「开始」的几档（nil = 无限期）
  static let presets: [(title: String, minutes: Int?)] = [
    ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("5 小时", 300), ("无限期", nil),
  ]

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
  private static let forever = ["无限期", "无限", "一直", "永久", "不限", "forever", "∞"]
  /// 「到 18 点」里的连接词：去掉之后什么都不剩才算认出来了
  private static let joiners = ["直到", "一直到", "到", "至", "until", "till", "to", "后", "以后", "之后"]

  static func parse(_ raw: String, now: Date, calendar: Calendar) -> Parsed {
    let text = ReminderPhrase.halfWidth(raw).trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return .empty }
    if forever.contains(text.lowercased()) { return .indefinitely }
    // 两样都有时按先出现的（同提醒）
    let span = ReminderPhrase.duration(in: text)
    let point = ReminderPhrase.moment(in: text, now: now, calendar: calendar)
    if let span, point == nil || span.1.lowerBound <= point!.1.lowerBound {
      guard leftover(text, removing: span.1) else { return .invalid }
      return .until(now.addingTimeInterval(span.0 * 60), label: length(minutes: Int(span.0)))
    }
    if let point, point.0 > now {
      guard leftover(text, removing: point.1) else { return .invalid }
      return .until(point.0, label: "到 " + moment(point.0, now: now, calendar: calendar))
    }
    return .invalid
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

  /// 「2 小时」「1 小时 30 分钟」「45 分钟」
  static func length(minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) 分钟" }
    return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
  }

  /// 「18:00」「明天 8:00」「11月20日 9:00」：到哪一刻
  static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    let time = "\(parts.hour ?? 0):" + pad(parts.minute ?? 0)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
      calendar.isDate(date, inSameDayAs: tomorrow)
    {
      return "明天 " + time
    }
    let day = calendar.dateComponents([.month, .day], from: date)
    return "\(day.month ?? 0)月\(day.day ?? 0)日 " + time
  }

  /// 「还剩 1 小时 12 分」「还剩 42 分」「还剩不到 1 分钟」；nil（无限期）是「无限期」
  static func remaining(until end: Date?, now: Date) -> String {
    guard let end else { return "无限期" }
    let minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up))
    if minutes <= 1 { return "还剩不到 1 分钟" }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "还剩 \(rest) 分" }
    return rest == 0 ? "还剩 \(hours) 小时" : "还剩 \(hours) 小时 \(rest) 分"
  }

  static func pad(_ number: Int) -> String { number < 10 ? "0\(number)" : "\(number)" }

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
