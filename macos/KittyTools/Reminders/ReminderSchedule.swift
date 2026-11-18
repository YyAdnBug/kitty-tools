// 提醒什么时候响（PLAN §10「提醒」B1–B5），全是纯函数，单测锁住（ReminderTests）：
// - 一次 / 每周 / 每月：严格晚于某一刻的下一次（按当地钟表时间算，B2：换了时区还是当地的 9 点；夏令时跳过的那个钟点
//   取它后面最近的有效时刻）。
// - 间隔：从「锚点」起数 every 分钟，那一刻落在勾了的那天的时段里才算；落在时段外就是下一个时段开始再数 every 分钟。
//   结束早于开始的时段跨过半夜（22:00–6:00，第五轮体检 U10）：算到第二天，归开始的那一天（周五勾了 = 周五 22:00 到周六 6:00）。
//   锚点由 ReminderCenter 管：启动、醒来、解锁、离开电脑回来（B3）、暂停结束（E6）、点了「知道了」时设成那一刻。
// - check：此刻哪几条该响、哪几条算错过（晚了超过 lateLimit，B4）、下一次最早什么时候要再看。
//   间隔类晚了也不补（醒来时锚点已经重设），推过的也一样；正在岛上挂着的不重复响；锁着屏、在状态屏里、暂停着（held）时一条都不响，
//   等回来再看（暂停着的间隔类同离开电脑，不攒，暂停结束从那一刻重新数，E6）。一次 / 每周 / 每月都只算「上次处理到的那一刻」之后的：刚打开、刚改过时间的从那一刻算起，所以把一次性的
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

  /// date 落在哪个时段里（间隔类）：那天勾了、而且在 time…until 之间；跨过半夜的时段，前一天开始的那段也算
  func window(containing date: Date, calendar: Calendar) -> Range<Date>? {
    let day = calendar.startOfDay(for: date)
    for start in [calendar.date(byAdding: .day, value: -1, to: day), day].compactMap({ $0 }) {
      if let window = window(on: start, calendar: calendar), window.contains(date) { return window }
    }
    return nil
  }

  /// 某一天开始的时段；那天没勾给 nil。结束早于开始的跨过半夜、结束在第二天（U10）
  private func window(on day: Date, calendar: Calendar) -> Range<Date>? {
    guard days.contains(calendar.component(.weekday, from: day)),
      let start = Self.moment(time, on: day, calendar: calendar),
      let end = Self.moment(until > time ? until : until + 1440, on: day, calendar: calendar),
      start < end
    else { return nil }
    return start..<end
  }

  /// 间隔类的时段有多长（分钟）：跨过半夜的算到第二天（22:00–6:00 = 480）
  var windowMinutes: Int { until > time ? until - time : until + 1440 - time }

  /// 某一天的第几分钟（按钟表时间：夏令时那天也是墙上的 9 点）；1440 = 第二天零点，再往后是第二天的第几分钟
  fileprivate static func moment(_ minutes: Int, on day: Date, calendar: Calendar) -> Date? {
    guard minutes < 1440 else {
      guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
      else { return nil }
      return minutes == 1440 ? next : moment(minutes - 1440, on: next, calendar: calendar)
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
  /// 菜单栏「暂停全部提醒」到几点（D6）：这之前一条都不响，之后照「错过的」规矩补
  var pausedUntil: Date?

  /// 系统时间变了（NSSystemClockDidChange：手动改、开关「自动设置时间」、对时）：只收明显往回调过的（纯函数，第五轮体检 E5）——
  /// 记在「将来」超过 clockSlack 的处理时刻收回到现在（不然要等真实时间追上才响；差几秒的对时不动，免得刚响过的又响一次）；
  /// 推到的时刻超过 maxSnooze（实际能推到的最远）才截回那么远：正常推后的一律不动（原来截到 30 分钟，推后 1 小时的
  /// 一对时就提前到 30 分钟后响）；暂停超过 maxPause 才截回
  func pulledBack(now: Date, maxSnooze: TimeInterval) -> ReminderState {
    var next = self
    for (id, mark) in marks where mark.at > now + Self.clockSlack { next.marks[id]?.at = now }
    for (id, date) in snoozed where date > now + maxSnooze { next.snoozed[id] = now + maxSnooze }
    if let paused = pausedUntil, paused > now + Self.maxPause {
      next.pausedUntil = now + Self.maxPause
    }
    return next
  }

  /// 时钟往回调多少以内不算（对时的几秒、几十秒）
  static let clockSlack: TimeInterval = 60
  /// 暂停最远到哪：「暂停到明天」到明天第一个时段开始，不会超过后天零点；调回去之后不会一停好几天
  static let maxPause: TimeInterval = 2 * 86_400

  /// 暂停到点了（纯函数，E6）：清掉记着的时刻、返回 true——间隔提醒从这一刻重新数（暂停期间它们不攒，同离开电脑）
  mutating func endPause(now: Date) -> Bool {
    guard let paused = pausedUntil, paused <= now else { return false }
    pausedUntil = nil
    return true
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
    /// 过了点、此刻又不在它的时段里的间隔类（第五轮体检）：不响，执行层从现在重新数、交给下一个时段
    var rested: [String] = []
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
  /// away（5 分钟没碰键盘鼠标）时间隔类（没推过的）不响也不等，回来重设锚点再数（B3）；间隔类晚了不算错过（推过的也是），
  /// 但过了点、此刻已经不在它的时段里的（从状态屏出来、时钟往前跳、醒得晚：17:45 该响的 18:30 才看到，时段到 18:00）
  /// 不在时段外补响，记进 rested、从现在数（推过的照响：那是自己要的时刻）。
  /// focus（专注模式滤镜让提醒安静着，2026-11-17 拍板 B6）：没开「专注模式时也照常提醒」的间隔类同 away，不攒，结束后重新数
  static func check(
    _ list: [Reminder], state: ReminderState, anchors: [String: Date], showing: Set<String>,
    now: Date, held: Bool = false, away: Bool = false, focus: Bool = false, calendar: Calendar
  ) -> Result {
    var result = Result()
    for reminder in list where reminder.isOn && !showing.contains(reminder.id) {
      let isInterval = reminder.schedule.kind == .interval
      let resting = away || (focus && !reminder.duringFocus)
      if isInterval, resting, state.snoozed[reminder.id] == nil { continue }
      guard let due = due(reminder, state: state, anchors: anchors, calendar: calendar) else {
        continue
      }
      if due > now {
        result.next = min(result.next ?? due, due)
      } else if held {
        continue
      } else if isInterval, state.snoozed[reminder.id] == nil,
        reminder.schedule.window(containing: now, calendar: calendar) == nil
      {
        result.rested.append(reminder.id)
        if let next = reminder.schedule.next(fromAnchor: now, calendar: calendar) {
          result.next = min(result.next ?? next, next)
        }
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
    next.pausedUntil = state.pausedUntil
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

  /// 没设时段的「暂停到明天」到几点
  static let morning = 8 * 60

  /// 「暂停到明天」暂停到哪一刻（纯函数，第五轮体检 E6）：明天第一个时段开始；半夜 0:00 之后、今天第一个时段还没到时
  /// 点的，是今天的那一刻（凌晨 1 点说「到明天」是到早上）。某一天的第一个时段：开着的、那天勾了的、设了时段（不是全天）的
  /// 间隔提醒里最早的开始；一条都没有（没有间隔提醒、都是全天的、那天都不响）就是 8:00。
  /// 只有一部分设了时段时也取设了的里最早的那个：全天的那几条本来什么时候都响，跟着晚一点恢复无妨；而先恢复到 8:00 的话，
  /// 时段 9:00 起的那条照样要等到 9:00，「暂停到明天 8:00」说的就和设了时段的对不上。跨过半夜的时段按它开始的钟点算
  /// （明天 22:00–6:00 = 到明天 22:00）；每周 / 每月的钟点不算时段（它们是一个时刻，暂停时到点的照「错过的」合成一条）
  static func pauseUntilTomorrow(_ list: [Reminder], now: Date, calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
    for day in [today, tomorrow] {
      let weekday = calendar.component(.weekday, from: day)
      let starts = list.filter {
        $0.isOn && $0.schedule.kind == .interval && $0.schedule.windowMinutes < 1440
          && $0.schedule.days.contains(weekday)
      }
      .map(\.schedule.time)
      if let at = Reminder.Schedule.moment(starts.min() ?? morning, on: day, calendar: calendar),
        at > now
      {
        return at
      }
    }
    return tomorrow
  }

  /// 专注模式滤镜让提醒安静着（focus）时，到点的这几条里先压着、不弹出的（纯函数，拍板 B2 B4）：没开「专注模式时也照常提醒」的
  static func heldBack(_ ids: [String], list: [Reminder], focus: Bool) -> [String] {
    guard focus else { return [] }
    return ids.filter { id in list.first { $0.id == id }?.duringFocus != true }
  }

  /// 时间规则变了的（新旧列表里同一个 id、规则不一样）：正挂着的要撤下来（纯函数）
  static func rescheduled(from old: [Reminder], to new: [Reminder]) -> Set<String> {
    let before = Dictionary(old.map { ($0.id, $0.schedule) }) { first, _ in first }
    return Set(
      new.filter { reminder in before[reminder.id].map { $0 != reminder.schedule } ?? false }
        .map(\.id))
  }
}
