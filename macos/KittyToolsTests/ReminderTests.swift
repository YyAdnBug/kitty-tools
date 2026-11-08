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
    bad.nagMinutes = 121
    bad.chime = "../Nope"
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

  /// 提示音编号（2026-11-04 用户反馈）：系统 / 个人「声音」文件夹里的声音名、自己选的文件「file:名字.扩展名」；别的 Mac 上的
  /// 声音这台没有也留着；路径、隐藏文件、不认识的扩展名不认（导入的文件、同步文件夹里来的是不可信输入）
  @Test func chimeIDs() {
    #expect(ReminderSound.isValid("Glass") && ReminderSound.isValid("我的铃声"))
    #expect(ReminderSound.isValid("file:下课铃.mp3") && ReminderSound.isValid("file:a.M4A"))
    for bad in [
      "", "../x", "a/b", ".hidden", "file:", "file:../x.mp3", "file:x.exe", "file:.x.mp3",
      "file:a/b.mp3", "file:x", "a:b", String(repeating: "长", count: 101),
    ] {
      #expect(!ReminderSound.isValid(bad), "\(bad)")
    }
    #expect(ReminderSound.title(of: "Glass") == "玻璃")
    #expect(ReminderSound.title(of: "file:下课铃.mp3") == "下课铃")
    var other = Self.weekly("x")
    other.chime = "file:别的 Mac 上的.m4a"
    #expect(Reminder.sanitized([other]).first?.chime == "file:别的 Mac 上的.m4a")
    // 没理会时再催：菜单照 Due 的一排，有 1 分钟；自定义的 1–120 留着，别的当不催
    #expect(Reminder.nagChoices == [0, 1, 5, 10, 15, 30, 60])
    for (minutes, kept) in [(7, 7), (120, 120), (121, 0), (-1, 0)] {
      var nag = Self.weekly("n")
      nag.nagMinutes = minutes
      #expect(Reminder.sanitized([nag]).first?.nagMinutes == kept, "\(minutes)")
    }
  }

  /// 选文件：拷进目录、编号用原名；同一个文件再选用已有的，同名不同内容的加数字；放不了的不收；没人用的清掉
  @Test func importsAndPurgesChimeFiles() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: "kitty-sounds-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    let dir = root.appending(path: "sounds")
    let glass = URL(filePath: "/System/Library/Sounds/Glass.aiff")
    let id = try ReminderSound.importFile(glass, into: dir)
    #expect(id == "file:Glass.aiff")
    #expect(try ReminderSound.importFile(glass, into: dir) == id)

    let elsewhere = root.appending(path: "elsewhere")
    try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let lookalike = elsewhere.appending(path: "Glass.aiff")
    try manager.copyItem(at: URL(filePath: "/System/Library/Sounds/Ping.aiff"), to: lookalike)
    let second = try ReminderSound.importFile(lookalike, into: dir)
    #expect(second == "file:Glass 2.aiff")
    // 盘不分大小写：同内容的 glass.aiff 用盘上那个 Glass.aiff 的名字（不然清理会把在用的当成没人用）
    let lowerDir = root.appending(path: "lower")
    try manager.createDirectory(at: lowerDir, withIntermediateDirectories: true)
    let lower = lowerDir.appending(path: "glass.aiff")
    try manager.copyItem(at: glass, to: lower)
    #expect(try ReminderSound.importFile(lower, into: dir) == id)

    let fake = elsewhere.appending(path: "不是声音.mp3")
    try Data("hello".utf8).write(to: fake)
    #expect(throws: ReminderSound.ImportError.unreadable) {
      try ReminderSound.importFile(fake, into: dir)
    }

    ReminderSound.purge(keeping: [id, "Glass"], in: dir)
    #expect(try manager.contentsOfDirectory(atPath: dir.path) == ["Glass.aiff"])
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

  /// 「+」›「新提醒」先不存：详情页第一次改动时才加到末尾（开着），之后按 id 换；别的 id、满了都不加；
  /// 列表里有的照旧按 id 换（2026-11-05 用户报「没开任何提醒，刘海却提示新提醒」：点开看了一眼就退回的那条
  /// 原来已经存进去、开着，整点响了）
  @Test func newReminderIsSavedOnFirstEdit() {
    let fresh = Reminder.new(id: "n", now: Self.at(2, 9, 23), calendar: Self.calendar)
    #expect(fresh.isOn)
    let list = Reminder.examples
    var titled = fresh
    titled.title = "交周报"
    let saved = Reminder.saving(titled, to: list, fresh: fresh)
    #expect(saved == list + [titled])
    // 第一下就把标题删光了：先用「新提醒」存上，接着打的字按 id 换
    var blank = fresh
    blank.title = " "
    #expect(Reminder.saving(blank, to: list, fresh: fresh) == list + [fresh])
    var moved = titled
    moved.schedule.date = Self.at(2, 14, 30)
    #expect(Reminder.saving(moved, to: saved, fresh: fresh) == list + [moved])
    // 不是这一条的新提醒、没有新提醒（从列表点进来，那条已经被删掉 / 响过拿掉了）、满了：都不加
    var other = titled
    other.id = "x"
    #expect(Reminder.saving(other, to: list, fresh: fresh) == list)
    #expect(Reminder.saving(titled, to: list, fresh: nil) == list)
    let full = (0..<Reminder.maxCount).map { index in
      Reminder(id: "r\(index)", title: "第 \(index) 条", schedule: .init(kind: .weekly))
    }
    #expect(Reminder.saving(titled, to: full, fresh: fresh) == full)
    var renamed = list[0]
    renamed.title = "多喝水"
    #expect(Reminder.saving(renamed, to: list, fresh: fresh)[0].title == "多喝水")
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

  // MARK: 第 3 批：一句话建提醒

  @Test func phraseKeyword() {
    #expect(ReminderPhrase.query("提醒 10分钟 喝水") == "10分钟 喝水")
    #expect(ReminderPhrase.query("TX 明天") == "明天")
    #expect(ReminderPhrase.query("remind  9点") == "9点")
    #expect(ReminderPhrase.query("提醒") == nil && ReminderPhrase.query("提醒事项") == nil)
    #expect(ReminderPhrase.query("txt") == nil)
    #expect(
      ReminderPhrase.isKeyword("tx") && ReminderPhrase.isKeyword("提醒 ")
        && !ReminderPhrase.isKeyword("t"))
  }

  @Test func phraseDurations() {
    let now = Self.at(2, 10)
    func parse(_ text: String) -> ReminderPhrase.Parsed? {
      ReminderPhrase.parse(text, now: now, calendar: Self.calendar)
    }
    func after(_ minutes: Double, _ title: String) -> ReminderPhrase.Parsed {
      .init(date: now.addingTimeInterval(minutes * 60), title: title)
    }
    #expect(parse("10分钟 喝水") == after(10, "喝水"))
    #expect(parse("喝水 10分钟后") == after(10, "喝水"))
    #expect(parse("半小时后 开会") == after(30, "开会"))
    #expect(parse("一刻钟后") == after(15, ReminderPhrase.defaultTitle))
    #expect(parse("1小时20分 出门") == after(80, "出门"))
    #expect(parse("1.5小时") == after(90, ReminderPhrase.defaultTitle))
    #expect(parse("2h 休息") == after(120, "休息"))
    #expect(parse("5m 泡面") == after(5, "泡面"))
    // 「hello」不是小时，「10mg」不是分钟
    #expect(parse("10 hello") == nil)
    #expect(parse("吃药 10mg") == nil)
    #expect(parse("0分钟") == nil)
  }

  @Test func phraseMoments() {
    let now = Self.at(2, 10)  // 周一 10:00
    func parse(_ text: String, at time: Date = Self.at(2, 10)) -> ReminderPhrase.Parsed? {
      ReminderPhrase.parse(text, now: time, calendar: Self.calendar)
    }
    // 只写「9点」：最近的将来时刻（D3）
    #expect(parse("9点 开会") == .init(date: Self.at(2, 21), title: "开会"))
    #expect(parse("9点 开会", at: Self.at(2, 22)) == .init(date: Self.at(3, 9), title: "开会"))
    #expect(parse("9:30 站会")?.date == Self.at(2, 21, 30))
    #expect(parse("下午3点半 开会") == .init(date: Self.at(2, 15, 30), title: "开会"))
    #expect(parse("晚上8点半 跑步")?.date == Self.at(2, 20, 30))
    #expect(parse("中午12点 吃饭")?.date == Self.at(2, 12))
    #expect(parse("3点15分")?.date == Self.at(2, 15, 15))
    // 哪天：没写几点就是 9:00
    #expect(parse("明天9点 交周报") == .init(date: Self.at(3, 9), title: "交周报"))
    #expect(parse("明天 交周报")?.date == Self.at(3, 9))
    #expect(parse("后天下午2点")?.date == Self.at(4, 14))
    #expect(parse("周五 交周报")?.date == Self.at(6, 9))
    #expect(parse("星期一 9点")?.date == Self.at(9, 9))  // 今天周一、9 点已经过了：下周一
    #expect(parse("周一 11点")?.date == Self.at(2, 11))  // 今天周一、11 点还没到：今天
    #expect(parse("下周一 开会")?.date == Self.at(9, 9))
    #expect(parse("下周日")?.date == Self.at(15, 9))
    #expect(parse("12月25日 买礼物")?.date == Self.at(25, 9, month: 12))
    #expect(parse("1月1日")?.date == Self.at(1, 9, month: 1, year: 2027))
    // 评审：写了哪段时间没写几点；两样都有按先出现的；「点」后面隔着空格的数字不是分钟；1 个半小时；0 点、晚上 12 点
    #expect(parse("明天中午 吃饭") == .init(date: Self.at(3, 12), title: "吃饭"))
    #expect(parse("明天下午")?.date == Self.at(3, 15))
    #expect(parse("周五晚上 聚餐")?.date == Self.at(6, 20))
    #expect(parse("今晚 看球")?.date == Self.at(2, 20))
    #expect(parse("明晚8点 跑步") == .init(date: Self.at(3, 20), title: "跑步"))
    #expect(parse("明早7点半")?.date == Self.at(3, 7, 30))
    #expect(parse("周五下午3点 开会1小时") == .init(date: Self.at(6, 15), title: "开会1小时"))
    #expect(parse("明天9点 跑步30分钟")?.date == Self.at(3, 9))
    #expect(parse("跑步30分钟 明天9点")?.date == now.addingTimeInterval(30 * 60))
    #expect(parse("明天9点 3号会议室") == .init(date: Self.at(3, 9), title: "3号会议室"))
    #expect(parse("下午3点 2楼")?.date == Self.at(2, 15))
    #expect(parse("9点5分")?.date == Self.at(2, 21, 5))
    #expect(parse("1个半小时 出发")?.date == now.addingTimeInterval(90 * 60))
    #expect(parse("一个半小时")?.date == now.addingTimeInterval(90 * 60))
    #expect(parse("晚上12点")?.date == Self.at(3, 0))
    #expect(parse("0:30")?.date == Self.at(3, 0, 30))
    #expect(parse("１２月２５日 买礼物") == .init(date: Self.at(25, 9, month: 12), title: "买礼物"))
    #expect(parse("每天9点 吃药") == nil && ReminderPhrase.isRepeating("每天9点 吃药"))
    // 认不出 / 写错
    #expect(parse("喝水") == nil)
    #expect(parse("25点") == nil)
    #expect(parse("2月30日") == nil)
    #expect(parse("下午") == nil)
    _ = now
  }

  /// 启动器「提醒 …」那几行：认出时间的先是「建一条」，认不出 / 已经过了是一行提示，后面是已有的（写了字的只列标题里带着的）
  @Test func launcherRows() throws {
    let now = Self.at(2, 10)
    var water = Reminder.examples[0]
    water.isOn = true
    let list = [water, Reminder.examples[1]]
    let rows = LauncherModel.reminderItems("10分钟 喝水", list: list, now: now, calendar: Self.calendar)
    #expect(
      rows.first?.kind == .reminder && rows.first?.target == "" && rows.first?.title == "提醒我：喝水")
    #expect(rows.first?.payload == "10分钟 喝水")
    let all = LauncherModel.reminderItems("", list: list, now: now, calendar: Self.calendar)
    #expect(all.map(\.target) == ["water", "eyes"])
    #expect(all[1].subtitle.hasSuffix("已暂停") && all[0].presetEmoji == "hot-beverage")
    // 写的是标题里的字：已有的那条排第一，「认不出时间」的提示排在后面（↩ 落在那一条上）
    let filtered = LauncherModel.reminderItems("眼睛", list: list, now: now, calendar: Self.calendar)
    #expect(filtered.map(\.target) == ["eyes", LauncherModel.reminderHint])
    #expect(filtered.last?.title == "认不出时间")
    let repeating = LauncherModel.reminderItems(
      "每天9点 吃药", list: [], now: now, calendar: Self.calendar)
    #expect(repeating.map(\.title) == ["重复的提醒到设置里建"])
    let past = LauncherModel.reminderItems("今天上午8点", list: [], now: now, calendar: Self.calendar)
    #expect(past.map(\.title) == ["这个时间已经过了"])
    #expect(LauncherModel.reminderPrompts(for: "tx").first?.completion == "tx ")
    // 用法里写打的那个词；默认别名 remind，表里改了别名时提示跟着换（例子里的也换）
    #expect(LauncherModel.reminderPrompts(for: "提醒").first?.subtitle.hasPrefix("输入「提醒 空格") == true)
    let relabeled = LauncherCommands.relabel(
      try #require(LauncherModel.reminderPrompts(for: "remind").first),
      settings: .init(aliases: ["builtin:reminder": "rm"]))
    #expect(relabeled?.subtitle == "输入「rm 空格 时间 内容」，如「rm 10分钟 喝水」；↩ 或 Tab 补全关键词")
    #expect(relabeled?.completion == "rm ")
    #expect(LauncherModel.reminderPrompts(for: "txt").isEmpty)
    // 这三个词不能再当网页搜索的关键词（不然「tx 关键词」被提醒拿走）
    #expect(ReminderPhrase.keywords.allSatisfy { WebSearch.reservedKeywords[$0] == "提醒" })
  }

  /// 暂停到几点跟着状态走：列表变了不丢；时间往回调过时最多收到一天
  @Test func pauseSurvivesReconcileAndClockBack() {
    var state = ReminderState()
    state.pausedUntil = Self.at(2, 11)
    #expect(
      ReminderCheck.reconciled(state, with: [], now: Self.at(2, 10)).pausedUntil == Self.at(2, 11))
    state.pausedUntil = Self.at(9, 10)
    #expect(state.pulledBack(now: Self.at(2, 10), maxSnooze: 1800).pausedUntil == Self.at(3, 10))
  }

  /// 同步（E3）：交出去的一条一条、顺序一条，落到另一台（空的偏好域）一个字不差；更新版本写的（多了字段）整个不落
  @Test func syncRoundTrip() throws {
    let (from, fromName) = try Self.temporaryDefaults()
    let (to, toName) = try Self.temporaryDefaults()
    defer {
      UserDefaults().removePersistentDomain(forName: fromName)
      UserDefaults().removePersistentDomain(forName: toName)
    }
    var water = Reminder.examples[0]
    water.isOn = true
    let mine = Reminder(
      id: "mine", title: "交周报", schedule: .init(kind: .weekly, time: 600, days: [6]))
    Reminder.save([mine, water], to: from)
    Reminder.save([], to: to)  // 另一台把示例删光了（没存过时是三条示例，会和合进来的排在一起）
    let values = ReminderSync(defaults: from).syncValues()
    #expect(Set(values.keys) == [SyncRecords.orderID, "mine", "water"])
    let applied = ReminderSync(defaults: to).applySync(
      values.mapValues { Optional($0) }, ledger: .init(), library: "lib")
    #expect(applied == .saved)
    #expect(Reminder.load(to) == [mine, water])
    #expect(ReminderSync(defaults: to).syncValues() == values)
    // 没碰过提醒的那台（偏好里没存过、界面上是示例）：不把示例当成自己的交出去
    let (fresh, freshName) = try Self.temporaryDefaults()
    defer { UserDefaults().removePersistentDomain(forName: freshName) }
    #expect(
      ReminderSync(defaults: fresh).syncValues() == [
        SyncRecords.orderID: SyncRecords.orderValue([])
      ])
    // 多了不认识的字段：整个不落，本机的不动
    let newer = try #require(values["mine"]).replacingOccurrences(of: "{", with: #"{"future":1,"#)
    #expect(
      ReminderSync(defaults: to).applySync(["mine": newer], ledger: .init(), library: "lib")
        == .newer)
    #expect(Reminder.load(to) == [mine, water])
  }

  private static func temporaryDefaults() throws -> (UserDefaults, String) {
    let name = "reminder-tests-" + UUID().uuidString
    return (try #require(UserDefaults(suiteName: name)), name)
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
