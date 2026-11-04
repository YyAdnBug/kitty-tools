// 提醒（PLAN §10「提醒」第 1 批）：什么时候响（每周 / 每月 / 一次 / 间隔）、此刻哪几条响 / 算错过、状态跟上列表、
// 收拾不可信的列表、逐个字段兜底的解码、摘要和岛上的字、导出导入的合并。全是纯函数：不读也不写用户的偏好。

import CoreGraphics
import Foundation
import Testing

@testable import KittyTools

@MainActor
struct ReminderTests {
  /// 固定日历：东八区、没有夏令时
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }()

  /// 2026-11-02 是周一
  private static func at(
    _ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11, year: Int = 2026
  )
    -> Date
  {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private typealias Schedule = Reminder.Schedule

  // MARK: 什么时候响

  @Test func weeklyNext() {
    let workdays = Schedule(kind: .weekly, time: 9 * 60, days: Schedule.workdays)
    // 周五 10:00 之后 → 下周一 9:00；周一 8:00 → 当天 9:00
    #expect(workdays.next(after: Self.at(6, 10), calendar: Self.calendar) == Self.at(9, 9))
    #expect(workdays.next(after: Self.at(2, 8), calendar: Self.calendar) == Self.at(2, 9))
    // 严格晚于：正好 9:00 时算下一天
    let daily = Schedule(kind: .weekly, time: 9 * 60)
    #expect(daily.next(after: Self.at(2, 9), calendar: Self.calendar) == Self.at(3, 9))
    // 只勾周一：周一 10:00 之后是下周一
    let monday = Schedule(kind: .weekly, time: 9 * 60, days: [2])
    #expect(monday.next(after: Self.at(2, 10), calendar: Self.calendar) == Self.at(9, 9))
  }

  /// 夏令时那天也是墙上的 9 点
  @Test func weeklyKeepsWallClockAcrossDST() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
    let next = Schedule(kind: .weekly, time: 9 * 60).next(after: start, calendar: calendar)!
    #expect(calendar.component(.hour, from: next) == 9)
    #expect(calendar.component(.day, from: next) == 8)
  }

  @Test func monthlyClampsToLastDay() {
    let schedule = Schedule(kind: .monthly, time: 9 * 60, day: 31)
    #expect(
      schedule.next(after: Self.at(1, 0, month: 2), calendar: Self.calendar)
        == Self.at(28, 9, month: 2))
    #expect(
      schedule.next(after: Self.at(31, 9, month: 1), calendar: Self.calendar)
        == Self.at(28, 9, month: 2))
    #expect(
      Schedule(kind: .monthly, time: 9 * 60, day: 15).next(
        after: Self.at(15, 10), calendar: Self.calendar)
        == Self.at(15, 9, month: 12))
  }

  @Test func onceAndIntervalViaNextAfter() {
    let once = Schedule(kind: .once, date: Self.at(5, 14))
    #expect(once.next(after: Self.at(5, 13), calendar: Self.calendar) == Self.at(5, 14))
    #expect(once.next(after: Self.at(5, 14), calendar: Self.calendar) == nil)
    #expect(Schedule(kind: .interval).next(after: Self.at(5, 14), calendar: Self.calendar) == nil)
  }

  @Test func intervalNext() {
    let work = Schedule(
      kind: .interval, time: 9 * 60, until: 18 * 60, days: Schedule.workdays, every: 60)
    let next = { (anchor: Date) in work.next(fromAnchor: anchor, calendar: Self.calendar) }
    #expect(next(Self.at(2, 9, 30)) == Self.at(2, 10, 30))
    // 8:30 开始用电脑：9:30 已经在时段里
    #expect(next(Self.at(2, 8, 30)) == Self.at(2, 9, 30))
    // 7:00 起数到 8:00 还没开始：时段开始 + 60
    #expect(next(Self.at(2, 7)) == Self.at(2, 10))
    // 数过了尾巴：第二天
    #expect(next(Self.at(2, 17, 30)) == Self.at(3, 10))
    // 周五数过了尾巴：下周一
    #expect(next(Self.at(6, 17, 30)) == Self.at(9, 10))
    // 全天的接着数，跨过半夜不断
    let allDay = Schedule(kind: .interval, time: 0, until: 1440, every: 20)
    #expect(
      allDay.next(fromAnchor: Self.at(2, 23, 50), calendar: Self.calendar) == Self.at(3, 0, 10))
    // 时段比间隔还短：数到的那一刻正好在时段里照响；落在外面时，时段开始 + 60 一次都够不着，给 nil
    let tiny = Schedule(kind: .interval, time: 9 * 60, until: 9 * 60 + 30, every: 60)
    #expect(tiny.next(fromAnchor: Self.at(2, 8, 10), calendar: Self.calendar) == Self.at(2, 9, 10))
    #expect(tiny.next(fromAnchor: Self.at(2, 8, 40), calendar: Self.calendar) == nil)
  }

  // MARK: 此刻的检查

  private static func weekly(_ id: String, time: Int = 9 * 60, on: Bool = true) -> Reminder {
    Reminder(id: id, title: id, isOn: on, schedule: Schedule(kind: .weekly, time: time))
  }

  private static func state(_ marks: [String: Date], list: [Reminder]) -> ReminderState {
    var state = ReminderState()
    for reminder in list {
      if let at = marks[reminder.id] {
        state.marks[reminder.id] = .init(at: at, schedule: reminder.schedule)
      }
    }
    return state
  }

  @Test func checkFiresMissesAndWaits() {
    let a = Self.weekly("a")
    let list = [a]
    let state = Self.state(["a": Self.at(2, 8)], list: list)
    func check(_ now: Date, held: Bool = false, showing: Set<String> = []) -> ReminderCheck.Result {
      ReminderCheck.check(
        list, state: state, anchors: [:], showing: showing, now: now, held: held,
        calendar: Self.calendar)
    }
    #expect(check(Self.at(2, 8, 59)) == .init(next: Self.at(2, 9)))
    #expect(check(Self.at(2, 9, 4)).fire == ["a"])
    #expect(check(Self.at(2, 9, 6)).missed == ["a"])
    // 锁着屏：不响也不算错过、也不等它
    #expect(check(Self.at(2, 9, 30), held: true) == .init())
    // 正挂着的、关着的不算
    #expect(check(Self.at(2, 9, 1), showing: ["a"]) == .init())
    let off = ReminderCheck.check(
      [Self.weekly("a", on: false)], state: state, anchors: [:], showing: [], now: Self.at(2, 9, 1),
      calendar: Self.calendar)
    #expect(off == .init())
  }

  @Test func checkSnoozeOnceAndInterval() {
    var state = ReminderState()
    let a = Self.weekly("a")
    state.marks["a"] = .init(at: Self.at(2, 9), schedule: a.schedule)
    state.snoozed["a"] = Self.at(2, 9, 10)
    let once = Reminder(id: "o", title: "o", schedule: Schedule(kind: .once, date: Self.at(2, 8)))
    let soon = Reminder(id: "s", title: "s", schedule: Schedule(kind: .once, date: Self.at(2, 12)))
    let interval = Reminder(
      id: "i", title: "i", schedule: Schedule(kind: .interval, time: 0, until: 1440, every: 20))
    let list = [a, once, soon, interval]
    // 一次性的从「上次处理到的那一刻」之后才算：两条都是昨天就在列表里的
    for reminder in [once, soon] {
      state.marks[reminder.id] = .init(at: Self.at(1, 0), schedule: reminder.schedule)
    }
    let anchors = ["i": Self.at(2, 8, 30)]
    let result = ReminderCheck.check(
      list, state: state, anchors: anchors, showing: [], now: Self.at(2, 9, 10),
      calendar: Self.calendar)
    // 推到 9:10 的到点响；一次的晚了一个多钟头算错过；间隔的晚了也照响不补；12:00 那条在等
    #expect(result.fire == ["a", "i"])
    #expect(result.missed == ["o"])
    #expect(result.next == Self.at(2, 12))
    // 离开电脑：间隔的不响也不等，别的照常
    let away = ReminderCheck.check(
      list, state: state, anchors: anchors, showing: [], now: Self.at(2, 9, 10), away: true,
      calendar: Self.calendar)
    #expect(away.fire == ["a"])
  }

  @Test func reconciledFollowsList() {
    let a = Self.weekly("a")
    var state = Self.state(["a": Self.at(1, 9)], list: [a])
    state.snoozed["gone"] = Self.at(2, 10)
    state.snoozed["a"] = Self.at(2, 10)
    let now = Self.at(2, 12)
    // 规则没变：记录留着；新开的每周提醒从现在算；删掉的去掉推到的时刻；间隔类没有记录
    let b = Self.weekly("b")
    let interval = Reminder(id: "i", title: "i", schedule: Schedule(kind: .interval))
    let next = ReminderCheck.reconciled(state, with: [a, b, interval], now: now)
    #expect(next.marks["a"]?.at == Self.at(1, 9))
    #expect(next.marks["b"]?.at == now)
    #expect(next.marks["i"]?.at == now)
    #expect(next.snoozed == ["a": Self.at(2, 10)])
    // 改了时间：从改的那一刻重新算（不把今天早上的 9 点当成刚错过）
    let moved = Self.weekly("a", time: 8 * 60)
    #expect(ReminderCheck.reconciled(state, with: [moved], now: now).marks["a"]?.at == now)
    // 关掉：记录和推到的时刻都去掉
    #expect(ReminderCheck.reconciled(state, with: [moved], now: now).snoozed.isEmpty)
    let off = ReminderCheck.reconciled(state, with: [Self.weekly("a", on: false)], now: now)
    #expect(off == ReminderState())
  }

  // MARK: 收拾、解码

  @Test func sanitizedCleansUntrustedList() {
    var bad = Self.weekly("x")
    bad.title = "  有\n换行  "
    bad.symbol = "not-an-emoji"
    bad.fullSeconds = 7
    bad.nagMinutes = 3
    bad.chime = "Nope"
    bad.schedule = Schedule(kind: .interval, time: 2000, until: 10, days: [], day: 40, every: 1)
    var dup = Self.weekly("x")
    dup.title = "重复的 id"
    var empty = Self.weekly("y")
    empty.title = "   "
    let result = Reminder.sanitized([bad, dup, empty])
    #expect(result.count == 1)
    let clean = result[0]
    #expect(clean.title == "有 换行")
    #expect(clean.symbol == "" && clean.fullSeconds == 0 && clean.nagMinutes == 0)
    #expect(clean.chime == Reminder.defaultChime)
    #expect(clean.schedule.time == 1439 && clean.schedule.until == 1440)
    #expect(clean.schedule.days == Schedule.allDays && clean.schedule.day == 31)
    #expect(clean.schedule.every == 5)
    let many = (0..<60).map { Self.weekly("r\($0)") }
    #expect(Reminder.sanitized(many).count == Reminder.maxCount)
  }

  /// 逐个字段兜底：不认识的种类换成默认、缺的字段补上；一条缺标题只丢它；没存过是示例，存过空的就是空的
  @Test func decodeIsLenient() {
    let json = """
      [{"id":"a","title":"喝水","alert":"beep","sound":"bell","isOn":true,"future":1},
       {"id":"b"},
       {"id":"c","title":"开会","schedule":{"kind":"weekly","time":600,"days":[2]}}]
      """
    let list = Reminder.decode(Data(json.utf8))
    #expect(list.map(\.id) == ["a", "c"])
    #expect(list[0].alert == .light && list[0].sound == .chime && list[0].isOn)
    #expect(list[1].schedule.time == 600 && list[1].schedule.days == [2] && !list[1].isOn)
    #expect(Reminder.decode(nil) == Reminder.examples)
    #expect(Reminder.decode(Data("[]".utf8)).isEmpty)
    #expect(Reminder.decode(Data("not json".utf8)) == Reminder.examples)
    // 编出去再读回来一样
    #expect(Reminder.decode(Reminder.encoded(Reminder.examples)) == Reminder.examples)
  }

  @Test func examplesAreOffAndPristine() {
    #expect(Reminder.examples.allSatisfy { !$0.isOn && $0.isPristine })
    var on = Reminder.examples[0]
    on.isOn = true
    #expect(on.isPristine)
    on.title = "多喝水"
    #expect(!on.isPristine)
    #expect(Reminder.missingExamples(in: [on]).map(\.id) == ["eyes", "walk"])
    #expect(Reminder.restoringExamples(in: [on]).map(\.id) == ["water", "eyes", "walk"])
  }

  @Test func newReminderIsNextHourAtLeastTenMinutesAway() {
    #expect(
      Reminder.new(now: Self.at(2, 9, 20), calendar: Self.calendar).schedule.date == Self.at(2, 10))
    #expect(
      Reminder.new(now: Self.at(2, 9, 55), calendar: Self.calendar).schedule.date == Self.at(2, 11))
  }

  // MARK: 字

  @Test func summaries() {
    let now = Self.at(2, 8)
    let summary = { (reminder: Reminder) in reminder.summary(now: now, calendar: Self.calendar) }
    #expect(summary(Reminder.examples[0]) == "工作日 9:00–18:00 每 60 分钟 · 轻提醒")
    #expect(summary(Reminder.examples[1]) == "每 20 分钟 · 全屏 20 秒")
    #expect(summary(Reminder.examples[2]) == "工作日 9:00–18:00 每 45 分钟 · 边框")
    var monthly = Self.weekly("m")
    monthly.schedule = Schedule(kind: .monthly, time: 9 * 60 + 5, day: 15)
    monthly.alert = .status
    #expect(
      monthly.summary(now: now, calendar: Self.calendar, statusTitle: "午休")
        == "每月 15 号 9:05 · 进入「午休」")
    #expect(Schedule(kind: .weekly, days: [2, 4, 6]).daysTitle == "每周一、三、五")
    #expect(Schedule(kind: .weekly, days: [1, 2]).daysTitle == "每周一、日")
    #expect(Schedule(kind: .weekly, days: [1, 7]).daysTitle == "周末")
    let today = Reminder(id: "t", title: "t", schedule: Schedule(kind: .once, date: Self.at(2, 14)))
    let tomorrow = Reminder(
      id: "t", title: "t", schedule: Schedule(kind: .once, date: Self.at(3, 9)))
    #expect(summary(today).hasPrefix("今天 "))
    #expect(summary(tomorrow).hasPrefix("明天 "))
    #expect(
      Reminder.clock(0) == "0:00" && Reminder.clock(1440) == "24:00"
        && Reminder.clock(545) == "9:05")
  }

  @Test func islandNotice() {
    var water = Self.weekly("喝水")
    water.detail = "一杯"
    let walk = Self.weekly("走走")
    #expect(ReminderCenter.notice(fired: [], missed: []) == nil)
    #expect(ReminderCenter.notice(fired: [water], missed: [])! == ("喝水", "一杯"))
    #expect(ReminderCenter.notice(fired: [water, walk], missed: [])! == ("喝水 · 走走", nil))
    #expect(ReminderCenter.notice(fired: [], missed: [walk])! == ("错过了提醒：走走", nil))
    #expect(ReminderCenter.notice(fired: [], missed: [water, walk])! == ("错过了 2 个提醒", "喝水、走走"))
    #expect(ReminderCenter.notice(fired: [water], missed: [walk])! == ("喝水", "一杯；还错过了：走走"))
  }

  @Test func repeatPicker() {
    let daily = Schedule(kind: .weekly)
    #expect(daily.repeats == .daily)
    // 2026-11-02 是周一（weekday 2）
    #expect(daily.repeating(.weekly, now: Self.at(2, 8), calendar: Self.calendar).days == [2])
    #expect(
      daily.repeating(.workdays, now: Self.at(2, 8), calendar: Self.calendar).repeats == .workdays)
    let past = Schedule(kind: .weekly, date: Self.at(1, 8))
    #expect(
      past.repeating(.once, now: Self.at(2, 8, 20), calendar: Self.calendar).date == Self.at(2, 9))
  }

  // MARK: 导出导入

  /// 评审 1：把一次性的时间改到已经过了（日期选择器夹到上一次画的那一刻）、打开一条过了时间的，都不当场响、不算错过；
  /// 改了时间的正挂着的要撤下来，推到的时刻作废
  @Test func editedOrReenabledOnceStaysQuiet() {
    let now = Self.at(2, 10)
    var call = Reminder(id: "c", title: "c", schedule: Schedule(kind: .once, date: Self.at(3, 15)))
    var state = ReminderCheck.reconciled(ReminderState(), with: [call], now: Self.at(2, 9))
    state.snoozed["c"] = Self.at(2, 10, 30)
    call.schedule.date = Self.at(2, 9, 59)
    state = ReminderCheck.reconciled(state, with: [call], now: now)
    #expect(state.snoozed.isEmpty)
    let quiet = ReminderCheck.check(
      [call], state: state, anchors: [:], showing: [], now: now.addingTimeInterval(1),
      calendar: Self.calendar)
    #expect(quiet == .init())
    // 关着时过了时间，再打开
    let past = Reminder(id: "p", title: "p", schedule: Schedule(kind: .once, date: Self.at(1, 9)))
    let reopened = ReminderCheck.reconciled(ReminderState(), with: [past], now: now)
    #expect(
      ReminderCheck.check(
        [past], state: reopened, anchors: [:], showing: [], now: now, calendar: Self.calendar)
        == .init())
    // 改了时间的、新旧都在的才算「改了」
    let moved = Reminder(id: "c", title: "c", schedule: Schedule(kind: .once, date: Self.at(4, 9)))
    #expect(ReminderCheck.rescheduled(from: [call, past], to: [moved, past]) == ["c"])
    #expect(ReminderCheck.rescheduled(from: [call], to: [past]).isEmpty)
  }

  /// 评审 3：推过的间隔提醒锁屏错过了也照响，不算错过
  @Test func snoozedIntervalIsNeverMissed() {
    let water = Reminder(
      id: "w", title: "w", schedule: Schedule(kind: .interval, time: 0, until: 1440))
    var state = ReminderCheck.reconciled(ReminderState(), with: [water], now: Self.at(2, 9))
    state.snoozed["w"] = Self.at(2, 10, 5)
    let result = ReminderCheck.check(
      [water], state: state, anchors: [:], showing: [], now: Self.at(2, 10, 30),
      calendar: Self.calendar)
    #expect(result.fire == ["w"] && result.missed.isEmpty)
  }

  /// 评审 5：系统时间往回调过，记在将来的时刻收回来
  @Test func clockMovedBackPullsStateIn() {
    let a = Self.weekly("a")
    var state = Self.state(["a": Self.at(5, 9)], list: [a])
    state.snoozed["a"] = Self.at(5, 9, 10)
    state.snoozed["b"] = Self.at(2, 8, 10)
    let now = Self.at(2, 8)
    let pulled = state.pulledBack(now: now, maxSnooze: 30 * 60)
    #expect(pulled.marks["a"]?.at == now)
    #expect(pulled.snoozed["a"] == Self.at(2, 8, 30))
    #expect(pulled.snoozed["b"] == Self.at(2, 8, 10))
  }

  /// 评审 4、6：时段比间隔还短的有橙字；不认识的时间种类不会变成「每天」
  @Test func shortWindowWarnsAndUnknownKindIsInert() {
    var short = Self.weekly("s")
    short.schedule = Schedule(kind: .interval, time: 9 * 60, until: 10 * 60, every: 90)
    #expect(short.problem(now: Self.at(2, 8)) == "这段时间比间隔还短，可能一次都不提醒")
    let json =
      #"[{"id":"y","title":"每年","isOn":true,"schedule":{"kind":"yearly","date":800000000}}]"#
    let list = Reminder.decode(Data(json.utf8))
    #expect(list[0].schedule.kind == .once && list[0].schedule.date == .distantPast)
  }

  /// 评审 2：导入超过上限时少加文件里新的、不挤掉本机的；文件里本机没有的、过了时间的一次性提醒不加
  @Test func mergeKeepsLocalAndSkipsStaleOnce() {
    let local = (0..<45).map { Self.weekly("l\($0)") }
    let incoming = (0..<10).map { Self.weekly("f\($0)") }
    let merged = Reminder.merged(incoming, into: local, now: Self.at(2, 8))
    #expect(merged.count == Reminder.maxCount)
    #expect(Set(local.map(\.id)).isSubset(of: merged.map(\.id)))
    #expect(merged.filter { $0.id.hasPrefix("f") }.map(\.id) == ["f0", "f1", "f2", "f3", "f4"])
    let stale = Reminder(
      id: "old", title: "old", schedule: Schedule(kind: .once, date: Self.at(1, 9)))
    let soon = Reminder(
      id: "new", title: "new", schedule: Schedule(kind: .once, date: Self.at(3, 9)))
    #expect(Reminder.merged([stale, soon], into: [], now: Self.at(2, 8)).map(\.id) == ["new"])
    // 本机已经有的照样更新（哪怕过了时间）
    #expect(Reminder.merged([stale], into: [stale], now: Self.at(2, 8)).map(\.id) == ["old"])
  }

  // MARK: 第 2 批：方式

  /// 几条一起到点按最显眼的那条；录屏录音时一律轻提醒（C11）
  @Test func alertPicksMostProminent() {
    func reminder(_ alert: Reminder.Alert, seconds: Int = 0) -> Reminder {
      var reminder = Self.weekly("\(alert)\(seconds)")
      reminder.alert = alert
      reminder.fullSeconds = seconds
      return reminder
    }
    let light = reminder(.light)
    let glow = reminder(.glow)
    let full = reminder(.full, seconds: 20)
    let status = reminder(.status)
    #expect(ReminderCenter.alert(for: [light, glow], recording: false) == .glow)
    #expect(ReminderCenter.alert(for: [glow, full, light], recording: false) == .full)
    #expect(ReminderCenter.alert(for: [full, status], recording: false) == .status)
    #expect(ReminderCenter.alert(for: [full, status], recording: true) == .light)
    #expect(ReminderCenter.alert(for: [], recording: false) == .light)
    // 全屏多久：有一条点了才收就点了才收；只算全屏 / 状态屏的那几条
    #expect(ReminderCenter.fullSeconds(for: [full, light]) == 20)
    #expect(ReminderCenter.fullSeconds(for: [full, reminder(.full, seconds: 60)]) == 60)
    #expect(ReminderCenter.fullSeconds(for: [full, reminder(.full)]) == 0)
    #expect(ReminderCenter.fullSeconds(for: [light]) == 0)
    // 稍后的选项：设置里的那个 + 15 分钟 + 1 小时，去重
    #expect(ReminderCenter.snoozeChoices(default: 5) == [5, 15, 60])
    #expect(ReminderCenter.snoozeChoices(default: 15) == [15, 60])
    #expect(ReminderCenter.snoozeChoices(default: 30) == [15, 30, 60])
  }

  /// 边框的四条：贴着屏幕的四边、亮的那头朝外
  @Test func glowStripsHugTheEdges() {
    let screen = CGRect(x: 100, y: 50, width: 1000, height: 600)
    let depth = ReminderGlow.depth
    #expect(
      ReminderGlow.Edge.top.frame(in: screen, depth: depth)
        == CGRect(x: 100, y: 650 - depth, width: 1000, height: depth))
    #expect(
      ReminderGlow.Edge.bottom.frame(in: screen, depth: depth)
        == CGRect(x: 100, y: 50, width: 1000, height: depth))
    #expect(
      ReminderGlow.Edge.left.frame(in: screen, depth: depth)
        == CGRect(x: 100, y: 50, width: depth, height: 600))
    #expect(
      ReminderGlow.Edge.right.frame(in: screen, depth: depth)
        == CGRect(x: 1100 - depth, y: 50, width: depth, height: 600))
    #expect(
      ReminderGlow.Edge.top.points.start.y == 1 && ReminderGlow.Edge.right.points.start.x == 1)
  }

  @Test func archiveRoundTripAndMerge() throws {
    let local = [Self.weekly("a"), Self.weekly("mine")]
    var incoming = Self.weekly("a")
    incoming.title = "文件里的 a"
    let merged = Reminder.merged([incoming, Self.weekly("b")], into: local)
    #expect(merged.map(\.id) == ["a", "b", "mine"])
    #expect(merged[0].title == "文件里的 a")
    // 文件里写成一组提醒，读回来还是提醒（不会被认成状态屏的状态）
    let value = SettingsArchive.Value.reminders(Reminder.examples)
    let decoded = try JSONDecoder().decode(
      SettingsArchive.Value.self, from: JSONEncoder().encode(value))
    #expect(decoded == value)
    #expect(SettingsArchive.kinds[Prefs.reminders] == .reminders)
    let data = try #require(SettingsArchive.Kind.reminders.plist(value) as? Data)
    #expect(Reminder.decode(data) == Reminder.examples)
    // 状态屏的状态仍然认成状态
    let statuses = SettingsArchive.Value.statuses(StatusPreset.builtIn)
    #expect(
      try JSONDecoder().decode(SettingsArchive.Value.self, from: JSONEncoder().encode(statuses))
        == statuses)
  }
}
