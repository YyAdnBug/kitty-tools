// 启动器里一句话建提醒（PLAN §10「提醒」D2、D3）：「提醒 10分钟 喝水」「tx 明天9点 交周报」「提醒 下午3点半 开会」。
// 纯函数，单测锁住（ReminderTests）。关键词「提醒」「tx」「remind」后面要有空格（「提醒事项」这类 App 名照常搜得到；
// 这三个词也不能再当网页搜索的关键词，WebSearch.reservedKeywords）。
// 认的写法：
// - 多久之后：10分钟 / 10分 / 10m / 半小时 / 一刻钟 / 1小时 / 1.5小时 / 1个半小时 / 1小时20分 / 2h，后面可带「后 / 以后 / 之后」；
// - 哪天：今天 / 明天 / 后天 / 大后天、今晚 / 明晚 / 今早 / 明早、周五 / 星期五 / 礼拜五（今天就是周五而时间还没过就是今天，
//   否则下一个）、下周一、12月25日（过了就是明年）；
// - 几点：9点 / 9点半 / 9点15 / 9点5分 / 9:30，前面可带 早上 / 上午 / 中午 / 下午 / 傍晚 / 晚上 / 凌晨；「点」和分钟之间不许
//   有空格、不带「分」时分钟要两位（「明天9点 3号会议室」是 9:00，不是 9:03）；
//   只写「9点」没说上午下午时取最近的那个将来时刻（现在 10:00 输「9点」= 今晚 21:00，拍板 D3；只有 1–11 点两可，0 点、12 点不）；
//   只写哪天没写几点 = 那天 9:00，写了「中午 / 下午 / 晚上」没写几点 = 12 / 15 / 20 点。
// - 一句话里既有「多久之后」又有「哪天几点」时，按先出现的那个（「周五下午3点 开会1小时」是周五 15:00）。
// 不认：重复（「每天…」：去设置里建，isRepeating 给提示）、年份、农历、汉字数字（「十分钟」）。全角数字和冒号先换成半角。
// 时间去掉之后剩下的就是标题，没剩下就是「时间到了」。

import Foundation

nonisolated enum ReminderPhrase {
  /// 启动器的关键词（不分大小写；后面要有空格）
  static let keywords = ["提醒", "tx", "remind"]

  /// 「提醒 …」后面的部分；只输关键词（没空格）、不是这几个关键词开头的给 nil
  static func query(_ text: String) -> String? {
    let lower = text.lowercased()
    for keyword in keywords where lower.hasPrefix(keyword + " ") {
      return String(text.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  /// 只输了关键词（「提醒」「tx」「remind」）：出补全提示
  static func isKeyword(_ text: String) -> Bool {
    keywords.contains(text.trimmingCharacters(in: .whitespaces).lowercased())
  }

  /// 写的是重复的提醒（「每天9点 吃药」「每隔一小时」）：启动器只建一次性的，提示去设置里建
  static func isRepeating(_ text: String) -> Bool {
    ["每天", "每周", "每月", "每隔", "每小时", "每个", "每晚", "每早", "工作日"].contains { text.contains($0) }
  }

  struct Parsed: Equatable {
    var date: Date
    var title: String
  }

  /// 没写内容时的标题
  static let defaultTitle = "时间到了"

  /// 解析一句话（关键词后面的部分）：认不出时间、写的是重复的给 nil。算出来的时刻可能已经过了（「今天上午8点」在 10 点说），
  /// 调用方自己看
  static func parse(_ raw: String, now: Date = .now, calendar: Calendar = .current) -> Parsed? {
    let text = halfWidth(raw)
    guard !isRepeating(text) else { return nil }
    let span = duration(in: text)
    let point = moment(in: text, now: now, calendar: calendar)
    // 两样都有时按先出现的那个
    if let span, point == nil || span.1.lowerBound < point!.1.lowerBound {
      return Parsed(date: now.addingTimeInterval(span.0 * 60), title: title(text, removing: span.1))
    }
    if let point {
      return Parsed(date: point.0, title: title(text, removing: point.1))
    }
    return nil
  }

  /// 全角数字和冒号换成半角（别的全角标点不动：标题里的「，」照旧）
  static func halfWidth(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.map { scalar in
          switch scalar.value {
          case 0xFF10...0xFF19: Unicode.Scalar(scalar.value - 0xFF10 + 0x30) ?? scalar
          case 0xFF1A: ":"
          default: scalar
          }
        }))
  }

  // MARK: 多久之后

  /// 汉字写的几个常用的；「一个半小时」排在「半小时」前面（不然先认成 30 分钟）
  private static let fixedSpans: [(String, Double)] = [
    ("一个半小时", 90), ("一个半钟头", 90), ("半个小时", 30), ("半小时", 30), ("一刻钟", 15), ("一个小时", 60),
    ("一小时", 60),
  ]

  /// 「1个半小时」：数字后面的「半」算半小时
  private static let hoursPattern = try! NSRegularExpression(
    pattern:
      #"([0-9]+(?:\.[0-9]+)?)\s*(?:个\s*)?(半\s*)?(?:小时|钟头|(?:hours?|hrs?|h)(?![a-z]))(?:\s*([0-9]+)\s*(?:分钟|分|minutes?|mins?|m)(?![a-z]))?(?:\s*(?:以后|之后|后))?"#,
    options: [.caseInsensitive])
  /// 前面紧挨着「点」的不算（「3点15分」是钟点，不是 15 分钟后）
  private static let minutesPattern = try! NSRegularExpression(
    pattern:
      #"(?<![0-9.点])(?<!点\s)([0-9]+)\s*(?:分钟|分|minutes?|mins?|m)(?![a-z])(?:\s*(?:以后|之后|后))?"#,
    options: [.caseInsensitive])

  /// 「多久之后」有几分钟、在原文的哪一段（夹在 1 分钟…7 天）
  static func duration(in text: String) -> (Double, Range<String.Index>)? {
    let ns = text as NSString
    let all = NSRange(location: 0, length: ns.length)
    var found: [(Double, Range<String.Index>)] = []
    if let match = hoursPattern.firstMatch(in: text, range: all),
      let hours = Double(ns.substring(with: match.range(at: 1))),
      let range = Range(match.range, in: text)
    {
      let half = match.range(at: 2).location == NSNotFound ? 0 : 30.0
      let extra =
        match.range(at: 3).location == NSNotFound
        ? 0 : Double(ns.substring(with: match.range(at: 3))) ?? 0
      if let minutes = clamp(hours * 60 + half + extra) { found.append((minutes, range)) }
    }
    for (word, minutes) in fixedSpans {
      if let range = text.range(of: word) {
        found.append((minutes, range.lowerBound..<suffix(after: range.upperBound, in: text)))
        break
      }
    }
    if let match = minutesPattern.firstMatch(in: text, range: all),
      let minutes = Double(ns.substring(with: match.range(at: 1))),
      let range = Range(match.range, in: text), let clamped = clamp(minutes)
    {
      found.append((clamped, range))
    }
    // 几样都认出来时（「1个半小时」里也有「半小时」）：最先出现的、同一处的取最长的
    return found.min {
      $0.1.lowerBound != $1.1.lowerBound
        ? $0.1.lowerBound < $1.1.lowerBound : $0.1.upperBound > $1.1.upperBound
    }
  }

  /// 「半小时后」的「后」也算进时间那一段
  private static func suffix(after index: String.Index, in text: String) -> String.Index {
    for word in ["以后", "之后", "后"] where text[index...].hasPrefix(word) {
      return text.index(index, offsetBy: word.count)
    }
    return index
  }

  private static func clamp(_ minutes: Double) -> Double? {
    minutes >= 1 && minutes <= 7 * 24 * 60 ? minutes : nil
  }

  // MARK: 哪天几点

  // 组：1 今天…明早  2 下  3 星期几  4 月  5 日  6 早上…凌晨  7–8 时:分  9 点  10 半  11 N分  12 两位分钟
  private static let momentPattern = try! NSRegularExpression(
    pattern:
      #"(?:(大后天|后天|明天|今天|今晚|明晚|今早|明早)|(下\s*)?(?:周|星期|礼拜)([一二三四五六日天1-7])|([0-9]{1,2})\s*月\s*([0-9]{1,2})\s*[日号])?\s*(早上|上午|中午|下午|傍晚|晚上|凌晨)?\s*(?:([0-9]{1,2})\s*:\s*([0-9]{2})|([0-9]{1,2})\s*点(?:(半)|([0-9]{1,2})分|([0-9]{2})(?![0-9]))?)?"#
  )

  private static let weekdays: [Character: Int] = [
    "日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7,
    "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 1,
  ]

  /// 今天 / 明天 / 今晚 / 明早…：差几天、自带哪段时间
  private static let relativeDays: [String: (days: Int, period: String?)] = [
    "今天": (0, nil), "明天": (1, nil), "后天": (2, nil), "大后天": (3, nil),
    "今晚": (0, "晚上"), "明晚": (1, "晚上"), "今早": (0, "早上"), "明早": (1, "早上"),
  ]

  /// 写了哪段时间、没写几点：几点
  private static let periodHours = [
    "早上": 8, "上午": 9, "中午": 12, "下午": 15, "傍晚": 18, "晚上": 20, "凌晨": 1,
  ]

  /// 「哪天几点」是哪一刻、在原文的哪一段；没写哪天也没写几点、写错了（25 点、2 月 30 号）给 nil
  static func moment(in text: String, now: Date, calendar: Calendar) -> (Date, Range<String.Index>)?
  {
    let ns = text as NSString
    var location = 0
    while location < ns.length {
      guard
        let match = momentPattern.firstMatch(
          in: text, range: NSRange(location: location, length: ns.length - location))
      else { return nil }
      // 空匹配（这个位置什么都没有）：往后挪一个字再找
      guard match.range.length > 0 else {
        location = match.range.location + 1
        continue
      }
      let group = { (index: Int) -> String? in
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : ns.substring(with: range)
      }
      let relative = group(1).flatMap { relativeDays[$0] }
      let hasDay = relative != nil || group(3) != nil || group(4) != nil
      let hasTime = group(7) != nil || group(9) != nil
      // 只有「下午」这类词、没有日期也没有钟点：不算
      guard hasDay || hasTime, let range = Range(match.range, in: text) else {
        location = match.range.location + match.range.length
        continue
      }
      let period = group(6) ?? relative?.period
      var hour = period.flatMap { periodHours[$0] } ?? 9
      var minute = 0
      if let h = group(7), let m = group(8) {
        (hour, minute) = (Int(h) ?? -1, Int(m) ?? -1)
      } else if let h = group(9) {
        hour = Int(h) ?? -1
        minute = group(10) != nil ? 30 : (group(11) ?? group(12)).flatMap { Int($0) } ?? 0
      }
      if hasTime { hour = adjusted(hour, period: period) }
      guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
      // 没说上午下午的 1–11 点两可（0 点、12 点不）
      let ambiguous = hasTime && period == nil && (1...11).contains(hour)
      let day = resolveDay(
        offset: relative?.days, nextWeek: group(2) != nil, weekday: group(3).flatMap { $0.first },
        month: group(4).flatMap { Int($0) }, dayOfMonth: group(5).flatMap { Int($0) },
        hour: hour, minute: minute, ambiguous: ambiguous, now: now, calendar: calendar)
      return day.map { ($0, range) }
    }
    return nil
  }

  /// 按「下午 / 晚上」改成 24 小时制：下午 3 点 = 15 点；中午 1 点 = 13 点；晚上 / 凌晨 / 早上 12 点 = 0 点
  private static func adjusted(_ hour: Int, period: String?) -> Int {
    switch period {
    case "下午", "傍晚": hour < 12 ? hour + 12 : hour
    case "晚上": hour == 12 ? 0 : hour < 12 ? hour + 12 : hour
    case "中午": hour < 11 ? hour + 12 : hour
    case "凌晨", "早上", "上午": hour == 12 ? 0 : hour
    default: hour
    }
  }

  private static func resolveDay(
    offset: Int?, nextWeek: Bool, weekday: Character?, month: Int?, dayOfMonth: Int?,
    hour: Int, minute: Int, ambiguous: Bool, now: Date, calendar: Calendar
  ) -> Date? {
    let today = calendar.startOfDay(for: now)
    func at(_ day: Date, _ hour: Int) -> Date? {
      calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
    func plus(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }
    if let offset {
      return plus(offset).flatMap { at($0, hour) }
    }
    if let weekday, let target = weekdays[weekday] {
      let current = calendar.component(.weekday, from: today)
      if nextWeek {
        // 下周 = 从下周一起的那一周（周一算一周的开始）
        let toMonday = (9 - current) % 7 == 0 ? 7 : (9 - current) % 7
        let fromMonday = (target + 5) % 7
        return plus(toMonday + fromMonday).flatMap { at($0, hour) }
      }
      var offset = (target - current + 7) % 7
      if offset == 0, let todayAt = at(today, hour), todayAt <= now { offset = 7 }
      return plus(offset).flatMap { at($0, hour) }
    }
    if let month, let dayOfMonth {
      let year = calendar.component(.year, from: now)
      for candidate in [year, year + 1] {
        var parts = DateComponents(year: candidate, month: month, day: dayOfMonth)
        parts.hour = hour
        parts.minute = minute
        guard let date = calendar.date(from: parts),
          calendar.component(.day, from: date) == dayOfMonth,
          calendar.component(.month, from: date) == month
        else { return nil }
        if date > now { return date }
      }
      return nil
    }
    // 没写哪天：今天里最近的那个将来时刻（只写「9点」时 9 点、21 点都算），都过了就是明天
    let hours = ambiguous ? [hour, hour + 12] : [hour]
    if let soonest = hours.compactMap({ at(today, $0) }).filter({ $0 > now }).min() {
      return soonest
    }
    return plus(1).flatMap { at($0, hour) }
  }

  // MARK: 标题

  /// 去掉时间那一段，剩下的收拾一下当标题；没剩下就是「时间到了」
  private static func title(_ text: String, removing range: Range<String.Index>) -> String {
    var rest = text
    rest.removeSubrange(range)
    let trimmed = rest.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.init(charactersIn: "，,、。:：")))
    let title = Reminder.oneLine(trimmed)
    return title.isEmpty ? defaultTitle : String(title.prefix(Reminder.maxTitle))
  }
}
