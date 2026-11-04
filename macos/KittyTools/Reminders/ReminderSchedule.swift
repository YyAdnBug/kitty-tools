// 提醒什么时候响（PLAN §10「提醒」B1–B5），全是纯函数，单测锁住（ReminderTests）：
// - 一次 / 每周 / 每月：严格晚于某一刻的下一次（按当地钟表时间算，B2：换了时区还是当地的 9 点；夏令时跳过的那个钟点
//   取它后面最近的有效时刻）。
// - 间隔：从「锚点」起数 every 分钟，那一刻落在勾了的那天的时段里才算；落在时段外就是下一个时段开始再数 every 分钟。
//   锚点由 ReminderCenter 管：启动、醒来、解锁、离开电脑回来（B3）、点了「知道了」时设成那一刻。
// - check：此刻哪几条该响、哪几条算错过（晚了超过 lateLimit，B4）、下一次最早什么时候要再看。
//   间隔类晚了也不补（醒来时锚点已经重设），推过的也一样；正在岛上挂着的不重复响；锁着屏、在状态屏里（held）时一条都不响，
//   等回来再看。一次 / 每周 / 每月都只算「上次处理到的那一刻」之后的：刚打开、刚改过时间的从那一刻算起，所以把一次性的
//   时间改到已经过了、打开一条过了时间的，都不会当场响或算错过（2026-11-04 评审）。

import Foundation

nonisolated extension Reminder.Schedule {
  /// 严格晚于 date 的下一次（一次 / 每周 / 每月）；间隔类走 next(fromAnchor:)，这里给 nil
  func next(after date: Date, calendar: Calendar) -> Date? {
    switch kind {
    case .once:
      return self.date > date ? self.date : nil
    case .weekly:
      let start = calendar.startOfDay(for: date)
      // 今天 + 后面 7 天：今天的时刻已经过了时，下周的同一天也在里面
      for offset in 0...7 {
        guard let day = calendar.date(byAdding: .day, value: offset, to: start),
          days.contains(calendar.component(.weekday, from: day)),
          let at = Self.moment(time, on: day, calendar: calendar), at > date
        else { continue }
        return at
      }
      return nil
    case .monthly:
      guard let month = calendar.dateInterval(of: .month, for: date)?.start else { return nil }
      for offset in 0...12 {
        guard let first = calendar.date(byAdding: .month, value: offset, to: month),
          let count = calendar.range(of: .day, in: .month, for: first)?.count,
          let day = calendar.date(byAdding: .day, value: min(self.day, count) - 1, to: first),
          let at = Self.moment(time, on: day, calendar: calendar), at > date
        else { continue }
        return at
      }
      return nil
    case .interval:
      return nil
    }
  }

  /// 间隔：从锚点数 every 分钟，那一刻落在某个时段里就是它（8:30 开始用电脑、时段 9:00 起、每 60 分钟 = 9:30；
  /// 全天的时段跨过半夜接着数）；落在时段外，就是那之后第一个时段的开始 + every（时段比 every 还短、一次都响不了的跳过）。
  /// 没勾任何一天（收拾过不会）给 nil
  func next(fromAnchor anchor: Date, calendar: Calendar) -> Date? {
    guard kind == .interval else { return nil }
    let step = TimeInterval(every * 60)
    let candidate = anchor.addingTimeInterval(step)
    if window(containing: candidate, calendar: calendar) != nil { return candidate }
    let start = calendar.startOfDay(for: candidate)
    for offset in 0...8 {
      guard let day = calendar.date(byAdding: .day, value: offset, to: start),
        let window = window(on: day, calendar: calendar), window.lowerBound > candidate
      else { continue }
      let at = window.lowerBound.addingTimeInterval(step)
      if at < window.upperBound { return at }
    }
    return nil
  }

  /// date 落在哪个时段里（间隔类）：当天勾了、而且在 time…until 之间
  func window(containing date: Date, calendar: Calendar) -> Range<Date>? {
    guard let window = window(on: calendar.startOfDay(for: date), calendar: calendar),
      window.contains(date)
    else { return nil }
    return window
  }

  /// 某一天的时段；那天没勾给 nil
  private func window(on day: Date, calendar: Calendar) -> Range<Date>? {
    guard days.contains(calendar.component(.weekday, from: day)),
      let start = Self.moment(time, on: day, calendar: calendar),
      let end = Self.moment(until, on: day, calendar: calendar), start < end
    else { return nil }
    return start..<end
  }

  /// 某一天的第几分钟（按钟表时间：夏令时那天也是墙上的 9 点）；1440 = 第二天零点
  private static func moment(_ minutes: Int, on day: Date, calendar: Calendar) -> Date? {
    if minutes >= 1440 {
      return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
    }
    return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
  }
}

/// 这台电脑自己的提醒状态（Prefs.remindersState，不注册默认值、不导出）：每条上一次看到哪一刻、推到了几点
nonisolated struct ReminderState: Codable, Equatable {
  /// 每条开着的提醒：已经处理到哪一刻（每周 / 每月响过、算过错过；任何一种刚打开、刚改过时间），下一次从这之后算；
  /// 连着记下当时的时间规则——改了时间就从改的那一刻重新算，不把「今天早上的 9 点」当成刚错过的。
  /// 一次性的响过时不往前挪（没点「知道了」就退出了，下次打开还要告诉你错过了）；间隔的只用它认规则变没变
  struct Mark: Codable, Equatable {
    var at: Date
    var schedule: Reminder.Schedule
  }

  var marks: [String: Mark] = [:]
  /// 点了「稍后」的：推到几点（到点照常响，C8）
  var snoozed: [String: Date] = [:]

  /// 系统时间往回调过（NSSystemClockDidChange）：记在「将来」的处理时刻收回到现在、推到的时刻最多再推 maxSnooze，
  /// 不然要等真实时间追上才响（纯函数）
  func pulledBack(now: Date, maxSnooze: TimeInterval) -> ReminderState {
    var next = self
    for (id, mark) in marks where mark.at > now { next.marks[id]?.at = now }
    for (id, date) in snoozed where date > now + maxSnooze { next.snoozed[id] = now + maxSnooze }
    return next
  }

  static func decode(_ data: Data?) -> ReminderState {
    data.flatMap { try? JSONDecoder().decode(ReminderState.self, from: $0) } ?? ReminderState()
  }

  var encoded: Data? { try? JSONEncoder().encode(self) }
}

nonisolated enum ReminderCheck {
  /// 晚了多久以内照常响；再晚算错过、合成一条告诉你（B4）
  static let lateLimit: TimeInterval = 5 * 60

  struct Result: Equatable {
    /// 现在该响的（按列表顺序）
    var fire: [String] = []
    /// 错过的（晚了超过 lateLimit）
    var missed: [String] = []
    /// 下一次最早什么时候要再看（nil = 没有要等的）
    var next: Date?
  }

  /// 每条该什么时候响：推过的按推到的时刻；间隔按锚点；一次 / 每周 / 每月按上一次处理到的那一刻往后算（一次的时间早于
  /// 那一刻就不响了）
  static func due(
    _ reminder: Reminder, state: ReminderState, anchors: [String: Date], calendar: Calendar
  ) -> Date? {
    if let snoozed = state.snoozed[reminder.id] { return snoozed }
    switch reminder.schedule.kind {
    case .interval:
      return anchors[reminder.id].flatMap {
        reminder.schedule.next(fromAnchor: $0, calendar: calendar)
      }
    case .once, .weekly, .monthly:
      return state.marks[reminder.id].flatMap {
        reminder.schedule.next(after: $0.at, calendar: calendar)
      }
    }
  }

  /// 此刻的检查（纯函数）。关着的、正挂着的不算；held（锁着屏、在状态屏里）时一条都不响也不算错过，等回来再看；
  /// away（5 分钟没碰键盘鼠标）时间隔类（没推过的）不响也不等，回来重设锚点再数（B3）；间隔类晚了不算错过（推过的也是）
  static func check(
    _ list: [Reminder], state: ReminderState, anchors: [String: Date], showing: Set<String>,
    now: Date, held: Bool = false, away: Bool = false, calendar: Calendar
  ) -> Result {
    var result = Result()
    for reminder in list where reminder.isOn && !showing.contains(reminder.id) {
      let isInterval = reminder.schedule.kind == .interval
      if isInterval, away, state.snoozed[reminder.id] == nil { continue }
      guard let due = due(reminder, state: state, anchors: anchors, calendar: calendar) else {
        continue
      }
      if due > now {
        result.next = min(result.next ?? due, due)
      } else if held {
        continue
      } else if now.timeIntervalSince(due) <= lateLimit || isInterval {
        result.fire.append(reminder.id)
      } else {
        result.missed.append(reminder.id)
      }
    }
    return result
  }

  /// 列表变了之后把状态跟上（纯函数）：开着的提醒没有记录（新加的、刚打开的）或者时间规则改了的，从 now 重新算、
  /// 推到的时刻作废（改了时间就按新的时间）；关掉的、删掉的连记录带推到的时刻一起去掉
  static func reconciled(_ state: ReminderState, with list: [Reminder], now: Date) -> ReminderState
  {
    var next = ReminderState()
    for reminder in list where reminder.isOn {
      if let mark = state.marks[reminder.id], mark.schedule == reminder.schedule {
        next.marks[reminder.id] = mark
        if let snoozed = state.snoozed[reminder.id] { next.snoozed[reminder.id] = snoozed }
      } else {
        next.marks[reminder.id] = .init(at: now, schedule: reminder.schedule)
      }
    }
    return next
  }

  /// 时间规则变了的（新旧列表里同一个 id、规则不一样）：正挂着的要撤下来（纯函数）
  static func rescheduled(from old: [Reminder], to new: [Reminder]) -> Set<String> {
    let before = Dictionary(old.map { ($0.id, $0.schedule) }) { first, _ in first }
    return Set(
      new.filter { reminder in before[reminder.id].map { $0 != reminder.schedule } ?? false }
        .map(\.id))
  }
}
