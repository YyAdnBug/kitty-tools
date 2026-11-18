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

  /// 刘海岛上的倒数（刘海岛扩展 C2）挂哪条：开着、没挂着、还没到的一次性提醒里最近的；推过的按推到的时刻；别的种类不算
  @Test func nextOnceForCountdown() {
    var state = ReminderState()
    let soon = Reminder(
      id: "s", title: "喝水", schedule: Schedule(kind: .once, date: Self.at(2, 9, 40)))
    let later = Reminder(
      id: "l", title: "开会", schedule: Schedule(kind: .once, date: Self.at(2, 9, 50)))
    let off = Reminder(
      id: "x", title: "关着", isOn: false, schedule: Schedule(kind: .once, date: Self.at(2, 9, 20)))
    let weekly = Self.weekly("w")
    for reminder in [soon, later, off, weekly] {
      state.marks[reminder.id] = .init(at: Self.at(1, 0), schedule: reminder.schedule)
    }
    let list = [later, soon, off, weekly]
    let now = Self.at(2, 9, 10)
    let next = {
      ReminderCenter.nextOnce(
        list, state: state, anchors: [:], showing: $0, now: now, calendar: Self.calendar)
    }
    #expect(next([])?.reminder.id == "s" && next([])?.at == Self.at(2, 9, 40))
    #expect(next(["s"])?.reminder.id == "l")
    // 推后 5 分钟后还是它，时刻跟着推
    state.snoozed["s"] = Self.at(2, 9, 45)
    #expect(next([])?.at == Self.at(2, 9, 45))
    // 已经过了的不算（那是 check 的事：响或算错过）
    #expect(
      ReminderCenter.nextOnce(
        list, state: state, anchors: [:], showing: [], now: Self.at(2, 10), calendar: Self.calendar)
        == nil)
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

  /// 专注模式滤镜让提醒安静着（2026-11-17 拍板 B4 B6）：没开「专注模式时也照常提醒」的间隔类不攒（同离开电脑），开了的照响；
  /// 推过的间隔类照样到点（交给执行层压着）；别的种类照常算出来，再由 heldBack 分出哪些先压着
  @Test func focusRestsIntervalsAndHoldsBack() {
    let anchors = ["i": Self.at(2, 8, 30), "u": Self.at(2, 8, 30), "z": Self.at(2, 8, 30)]
    let every = Schedule(kind: .interval, time: 0, until: 1440, every: 20)
    let quiet = Reminder(id: "i", title: "i", schedule: every)
    let urgent = Reminder(id: "u", title: "u", schedule: every, duringFocus: true)
    let snoozed = Reminder(id: "z", title: "z", schedule: every)
    let weekly = Self.weekly("w")
    let list = [quiet, urgent, snoozed, weekly]
    var state = ReminderState()
    state.marks["w"] = .init(at: Self.at(2, 8), schedule: weekly.schedule)
    state.snoozed["z"] = Self.at(2, 9, 1)
    let check = { (focus: Bool) in
      ReminderCheck.check(
        list, state: state, anchors: anchors, showing: [], now: Self.at(2, 9, 3), focus: focus,
        calendar: Self.calendar)
    }
    #expect(check(false).fire == ["i", "u", "z", "w"])
    #expect(check(true).fire == ["u", "z", "w"])
    // 先压着的：没开「照常」的；滤镜照常时一条都不压
    #expect(ReminderCheck.heldBack(["u", "z", "w"], list: list, focus: true) == ["z", "w"])
    #expect(ReminderCheck.heldBack(["u", "z", "w"], list: list, focus: false).isEmpty)
    // 不在列表里的（刚删掉）也压着：不会照常弹出来
    #expect(ReminderCheck.heldBack(["gone"], list: list, focus: true) == ["gone"])
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
    // 结束早于开始的是跨过半夜（U10），留着
    #expect(clean.schedule.time == 1439 && clean.schedule.until == 10)
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
    // 2026-11-17 加的「专注模式时也照常提醒」：旧数据没有这个键 = 关；编出去再读回来留着
    #expect(!list[0].duringFocus)
    var urgent = list[0]
    urgent.duringFocus = true
    #expect(Reminder.decode(Reminder.encoded([urgent])).first?.duringFocus == true)
    #expect(Reminder.decode(nil) == Reminder.examples)
    #expect(Reminder.decode(Data("[]".utf8)).isEmpty)
    #expect(Reminder.decode(Data("not json".utf8)) == Reminder.examples)
    // 编出去再读回来一样
    #expect(Reminder.decode(Reminder.encoded(Reminder.examples)) == Reminder.examples)
  }

  /// 示例存的是中文原文（0.9.0 存下来的照样认），显示时翻；标题是示例的中文或英文写法都算没改过（拍板 D6）
  @Test func examplesShownInInterfaceLanguage() throws {
    let water = Reminder.examples[0]
    let english = try #require(Reminder.exampleTitle("water")?.english)
    #expect(english == "Drink Water" && water.title == "喝水")
    #expect(
      Reminder.exampleDetail("eyes")?.english == "Look at something 20 feet away for 20 seconds")
    // 中文界面（单测宿主）照存的显示
    #expect(water.displayTitle == "喝水" && Reminder.examples[1].displayDetail == "看看 6 米外的地方，20 秒")
    // 0.9.0 存下来的列表：中文原文，读回来认得出、算没改过、恢复示例不重复加
    let stored =
      #"[{"id":"water","title":"喝水","symbol":"hot-beverage","isOn":true,"schedule":{"kind":"interval","time":540,"until":1080,"days":[2,3,4,5,6],"every":60}}]"#
    let old = Reminder.decode(Data(stored.utf8))
    #expect(old[0].isPristine && old[0].exampleTitle != nil && old[0].displayTitle == "喝水")
    #expect(Reminder.restoringExamples(in: old).map(\.id) == ["water", "eyes", "walk"])
    // 英文界面里把标题框改成英文写法：还是原样；别的字、别的 id 用了同一个标题都不算
    var renamed = water
    renamed.title = english
    #expect(renamed.isPristine && renamed.exampleTitle != nil && renamed.displayTitle == "喝水")
    renamed.title = "Drink water!"
    #expect(
      !renamed.isPristine && renamed.exampleTitle == nil && renamed.displayTitle == "Drink water!")
    var mine = Reminder(id: "mine", title: "喝水", schedule: water.schedule)
    mine.isOn = false
    #expect(!mine.isPristine && mine.exampleTitle == nil && mine.displayTitle == "喝水")
    // 恢复示例补回来的还是中文原文
    #expect(Reminder.restoringExamples(in: []).map(\.title) == ["喝水", "休息眼睛", "起来走走"])
    // 提示音的叫法：英文就是系统里的名字；不认识的照写名字
    #expect(Reminder.chimeNames.allSatisfy { Reminder.chimeTitle($0)?.english ?? $0 == $0 })
    #expect(
      ReminderSound.title(of: "Glass") == "玻璃" && ReminderSound.title(of: "Sosumi") == "Sosumi")
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

  /// 详情页的「日期和时间」存整分（2026-11-17 反馈：「现在 + 1 分钟」的倒数从 58 秒起——选得比下限早时系统的选择器
  /// 把值夹成下限本身，原来下限是带秒的「现在」）：下限是下一个整分、选到的值去掉秒，刘海上的倒数照它数
  @Test func pickedTimeIsWholeMinute() {
    let picked = { Reminder.picked($0, calendar: Self.calendar) }
    let earliest = { Reminder.earliestPick(after: $0, calendar: Self.calendar) }
    // 耳朵上的读数（卡片、菜单栏那一项是精确倒数）
    let reading = { (at: Date, now: Date) in
      Island.Activity.wingReading(.countdown(to: at), now: now)
    }
    // + 1 分钟：17:46:05.267 选「17:47」，被夹住的（下限）、带着秒改出来的都存成 17:47:00，倒数 0:55
    let now = Self.at(2, 17, 46).addingTimeInterval(5.267)
    #expect(earliest(now) == Self.at(2, 17, 47))
    #expect(picked(earliest(now)) == Self.at(2, 17, 47))
    #expect(picked(now + 60) == Self.at(2, 17, 47))
    #expect(reading(Self.at(2, 17, 47), now) == "0:55")
    // + 1 小时：存 18:46:00；离响不到一小时，倒数已经挂上，只到分钟（拍板 C1）
    let hour = picked(now + 3600)
    #expect(hour == Self.at(2, 18, 46))
    #expect(hour - ReminderCenter.countdownWindow <= now)
    #expect(reading(hour, now) == "60分")
    // 跨午夜：23:59:30.5 最早能选第二天 0:00，选到的 0:00:30.5 存成 0:00:00，倒数 0:30
    let late = Self.at(2, 23, 59).addingTimeInterval(30.5)
    #expect(earliest(late) == Self.at(3, 0))
    #expect(picked(late + 60) == Self.at(3, 0))
    #expect(reading(Self.at(3, 0), late) == "0:30")
    // 正好在整分上：这一分钟已经到了，最早是下一分钟；整分的值原样；倒数从 1:00 起
    let exact = Self.at(2, 9, 0)
    #expect(earliest(exact) == Self.at(2, 9, 1))
    #expect(picked(exact) == exact)
    #expect(reading(Self.at(2, 9, 1), exact) == "1:00")
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

  /// 英文（多语言第 8 批）：只补「多久之后」，英文界面的启动器预填的是「remind 」
  @Test func phraseEnglish() {
    let now = Self.at(2, 10)
    func parse(_ text: String) -> ReminderPhrase.Parsed? {
      ReminderPhrase.parse(text, now: now, calendar: Self.calendar)
    }
    func after(_ minutes: Double, _ title: String) -> ReminderPhrase.Parsed {
      .init(date: now.addingTimeInterval(minutes * 60), title: title)
    }
    // 启动器提示行里举的两个例子
    #expect(parse("10 min stretch") == after(10, "stretch"))
    #expect(parse("2 h check the oven") == after(120, "check the oven"))
    #expect(parse("in 10 minutes stretch") == after(10, "stretch"))
    #expect(parse("stretch in 15 mins") == after(15, "stretch"))
    #expect(parse("1.5 hours call mom") == after(90, "call mom"))
    #expect(parse("tea 20 min later") == after(20, "tea"))
    #expect(parse("half an hour from now tea") == after(30, "tea"))
    #expect(parse("in an hour Lunch") == after(60, "Lunch"))
    #expect(parse("1 hour 20 min leave") == after(80, "leave"))
    // remind me … to …
    #expect(ReminderPhrase.query("remind me in 10 min to stretch") == "in 10 min to stretch")
    #expect(ReminderPhrase.query("Remind me 5m") == "5m")
    #expect(ReminderPhrase.query("remind meeting 9:30") == "meeting 9:30")
    #expect(parse("in 10 min to stretch") == after(10, "stretch"))
    // 重复的去设置里建；单词里带着 every、in 的不误认
    #expect(
      ReminderPhrase.isRepeating("every day 9:00 pills") && parse("every 30 min stretch") == nil)
    #expect(ReminderPhrase.isRepeating("daily standup"))
    #expect(!ReminderPhrase.isRepeating("check everything 10 min"))
    #expect(parse("begin 10 min") == after(10, "begin"))
    // 英文的「哪天几点」这一版不认（ponytail，ReminderPhrase 文件头）
    #expect(parse("tomorrow stretch") == nil)
    // 没写内容：标题是建的那一刻的语言（单测宿主是中文）
    #expect(parse("10 min")?.title == "时间到了")
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

  /// 暂停到几点跟着状态走：列表变了不丢；时间往回调过时最多收到两天（「暂停到明天」最远到后天零点之前，E6）
  @Test func pauseSurvivesReconcileAndClockBack() {
    var state = ReminderState()
    state.pausedUntil = Self.at(2, 11)
    #expect(
      ReminderCheck.reconciled(state, with: [], now: Self.at(2, 10)).pausedUntil == Self.at(2, 11))
    state.pausedUntil = Self.at(9, 10)
    #expect(state.pulledBack(now: Self.at(2, 10), maxSnooze: 1800).pausedUntil == Self.at(4, 10))
    state.pausedUntil = Self.at(3, 22)
    #expect(state.pulledBack(now: Self.at(2, 10), maxSnooze: 1800).pausedUntil == Self.at(3, 22))
  }

  /// 第五轮体检 E6：暂停期间间隔类不攒（执行层传 held + away），暂停到点从那一刻重新数——17:30 暂停 1 小时，
  /// 时段到 18:00 的「喝水」原来 18:30 补响一次，现在下一次是明天时段里
  @Test func pauseRestsIntervalsAndRestartsAfter() {
    let water = Reminder(
      id: "w", title: "w",
      schedule: Schedule(
        kind: .interval, time: 9 * 60, until: 18 * 60, days: Schedule.workdays, every: 60))
    var state = ReminderCheck.reconciled(ReminderState(), with: [water], now: Self.at(2, 9))
    state.pausedUntil = Self.at(2, 18, 30)
    var anchors = ["w": Self.at(2, 16, 45)]  // 17:45 该响
    let during = ReminderCheck.check(
      [water], state: state, anchors: anchors, showing: [], now: Self.at(2, 17, 50), held: true,
      away: true, calendar: Self.calendar)
    #expect(during == .init())
    let early = state.endPause(now: Self.at(2, 18, 29))
    #expect(!early && state.pausedUntil == Self.at(2, 18, 30))
    let ended = state.endPause(now: Self.at(2, 18, 30))
    #expect(ended && state.pausedUntil == nil)
    anchors["w"] = Self.at(2, 18, 30)
    let after = ReminderCheck.check(
      [water], state: state, anchors: anchors, showing: [], now: Self.at(2, 18, 30),
      calendar: Self.calendar)
    #expect(after.fire.isEmpty && after.next == Self.at(3, 10))
  }

  /// 「暂停到明天」到明天第一个时段开始（E6）：没设时段的 8:00；只看开着的、明天勾了的间隔提醒；全天的不算时段；
  /// 只有一部分设了时段时取设了的里最早的；跨过半夜的按开始的钟点；每周的钟点不算时段
  @Test func pauseUntilTomorrowWaitsForFirstWindow() {
    let thursday = Self.at(5, 15)
    func until(_ list: [Reminder], at now: Date = thursday) -> Date {
      ReminderCheck.pauseUntilTomorrow(list, now: now, calendar: Self.calendar)
    }
    #expect(until([]) == Self.at(6, 8))
    let water = Reminder(
      id: "w", title: "w",
      schedule: Schedule(kind: .interval, time: 9 * 60, until: 18 * 60, days: Schedule.workdays))
    #expect(until([water]) == Self.at(6, 9))
    // 周五点：明天周六不在工作日里
    #expect(until([water], at: Self.at(6, 17)) == Self.at(7, 8))
    var off = water
    off.isOn = false
    #expect(until([off]) == Self.at(6, 8))
    let eyes = Reminder(
      id: "e", title: "e", schedule: Schedule(kind: .interval, time: 0, until: 1440, every: 20))
    #expect(until([eyes]) == Self.at(6, 8))
    #expect(until([eyes, water]) == Self.at(6, 9))
    let early = Reminder(
      id: "x", title: "x", schedule: Schedule(kind: .interval, time: 7 * 60 + 30, until: 12 * 60))
    #expect(until([water, early]) == Self.at(6, 7, 30))
    let night = Reminder(
      id: "n", title: "n", schedule: Schedule(kind: .interval, time: 22 * 60, until: 6 * 60))
    #expect(until([night], at: Self.at(5, 23)) == Self.at(6, 22))
    #expect(until([Self.weekly("a", time: 6 * 60)]) == Self.at(6, 8))
    // 半夜 0:00 前后（评审 4）：23:59 点是明天的；0:01 点、今天的还没到，是今天的；今天的过了就是明天的
    #expect(until([water], at: Self.at(5, 23, 59)) == Self.at(6, 9))
    #expect(until([water], at: Self.at(6, 0, 1)) == Self.at(6, 9))
    #expect(until([], at: Self.at(6, 7)) == Self.at(6, 8))
    #expect(until([], at: Self.at(6, 8)) == Self.at(7, 8))
    #expect(until([water], at: Self.at(6, 9, 30)) == Self.at(7, 8))
    // 跨过半夜的那条今天 22:00 还没到：今天 22:00
    #expect(until([night], at: Self.at(5, 15)) == Self.at(5, 22))
  }

  /// 全屏倒数完自己收起（E7）：出来之后有人碰过键盘鼠标才算知道了；一直没人碰、会话不在用户手里时，不是间隔类的挂到岛上；
  /// 间隔类照旧算知道了、重新数（评审 1：「休息眼睛」照做的人正好 20 秒不碰键鼠，挂到岛上的话之后不再数）
  @Test func fullScreenExpiryNeedsSomeoneThere() {
    let once = Reminder(id: "o", title: "o", schedule: Schedule(kind: .once, date: Self.at(2, 9)))
    let eyes = Reminder(
      id: "e", title: "e", schedule: Schedule(kind: .interval, time: 0, until: 1440, every: 20))
    let list = [once, Self.weekly("d"), eyes]
    let ids = ["o", "d", "e"]
    func pending(_ ids: [String], idle: TimeInterval, away: Bool = false) -> [String] {
      ReminderCenter.unattended(ids, list: list, idle: idle, shown: 20, away: away)
    }
    #expect(pending(ids, idle: 3).isEmpty)
    #expect(pending(ids, idle: 25) == ["o", "d"])
    #expect(pending(ids, idle: 20) == ["o", "d"])
    #expect(pending(ids, idle: 3, away: true) == ["o", "d"])
    #expect(pending(["e"], idle: 25).isEmpty)
    #expect(pending(["e"], idle: 3, away: true).isEmpty)
  }

  /// 过了点、此刻已经出了时段的间隔类不补响（评审 3：从状态屏出来、时钟往前跳、醒得晚），从现在数、交给下一个时段；
  /// 时段里的照响；推过的照响（那是自己要的时刻）
  @Test func lateIntervalOutsideWindowWaitsForNextWindow() {
    let water = Reminder(
      id: "w", title: "w",
      schedule: Schedule(
        kind: .interval, time: 9 * 60, until: 18 * 60, days: Schedule.workdays, every: 60))
    var state = ReminderCheck.reconciled(ReminderState(), with: [water], now: Self.at(2, 9))
    let anchors = ["w": Self.at(2, 16, 45)]  // 17:45 该响
    func check(_ now: Date) -> ReminderCheck.Result {
      ReminderCheck.check(
        [water], state: state, anchors: anchors, showing: [], now: now, calendar: Self.calendar)
    }
    #expect(check(Self.at(2, 17, 50)).fire == ["w"])
    let late = check(Self.at(2, 18, 30))
    #expect(late.fire.isEmpty && late.rested == ["w"] && late.next == Self.at(3, 10))
    state.snoozed["w"] = Self.at(2, 18, 5)
    #expect(check(Self.at(2, 18, 30)).fire == ["w"])
  }

  /// 跨过半夜的时段（U10，评审 2）编码多一个 overnight：自己往返一致；别的编出来的字节和以前自动生成的一样；
  /// 旧版本（不认识这个键）解了再编对不上，同步时整类停下，不会把它收拾成到半夜再推回来
  @Test func overnightEncodingStopsOldVersions() throws {
    let encoder = SyncRecords.encoder
    let plain = [
      Schedule(kind: .interval, days: Schedule.workdays), Schedule(kind: .weekly, time: 20 * 60),
      Schedule(kind: .once, date: Self.at(5, 9)), Schedule(kind: .monthly, day: 31),
      Schedule(kind: .interval, time: 0, until: 1440, every: 20),
    ]
    for schedule in plain.map(\.sanitized) {
      let old = OldSchedule(
        kind: schedule.kind.rawValue, date: schedule.date, time: schedule.time,
        until: schedule.until, days: schedule.days, day: schedule.day, every: schedule.every)
      #expect(try encoder.encode(schedule) == encoder.encode(old))
    }
    // 不是间隔类的没有时段：结束早于开始照旧收拾成到半夜（和以前一样）
    #expect(Schedule(kind: .weekly, time: 20 * 60).sanitized.until == 1440)
    let night = Schedule(kind: .interval, time: 22 * 60, until: 6 * 60, days: Schedule.workdays)
      .sanitized
    let json = String(decoding: try encoder.encode(night), as: UTF8.self)
    #expect(json.contains(#""overnight":true"#))
    #expect(SyncRecords.decodeExact(Schedule.self, from: json) == night)
    #expect(SyncRecords.decodeExact(OldSchedule.self, from: json) == nil)
    let reminder = Reminder(id: "n", title: "夜班", schedule: night)
    let value = String(decoding: try encoder.encode(reminder), as: UTF8.self)
    #expect(SyncRecords.decodeExact(Reminder.self, from: value) == reminder)
  }

  /// 跨过半夜的时段（U10）：22:00–6:00 存得下、算到第二天、归开始的那一天；页头不误报「比间隔还短」
  @Test func windowCrossesMidnight() {
    let night = Schedule(
      kind: .interval, time: 22 * 60, until: 6 * 60, days: Schedule.workdays, every: 60)
    #expect(night.sanitized == night)
    #expect(night.windowMinutes == 480)
    let next = { (anchor: Date) in night.next(fromAnchor: anchor, calendar: Self.calendar) }
    // 周一 22:30 → 23:30；半夜接着数（周一开始的那段）；6:00 出了时段 → 当天 22:00 + 60
    #expect(next(Self.at(2, 22, 30)) == Self.at(2, 23, 30))
    #expect(next(Self.at(3, 0, 30)) == Self.at(3, 1, 30))
    #expect(next(Self.at(3, 5, 30)) == Self.at(3, 23))
    #expect(next(Self.at(3, 12)) == Self.at(3, 23))
    // 周五晚上开始的那段到周六早上照响；周六晚上不响（周六没勾）：下一段是周一 22:00
    #expect(next(Self.at(7, 2)) == Self.at(7, 3))
    #expect(next(Self.at(7, 5, 30)) == Self.at(9, 23))
    #expect(
      night.window(containing: Self.at(7, 3), calendar: Self.calendar)
        == Self.at(6, 22)..<Self.at(7, 6))
    // 周一 0:00–6:00 是周日开始的那段（周日没勾）
    #expect(night.window(containing: Self.at(9, 3), calendar: Self.calendar) == nil)
    // 页头：8 小时、每 60 分钟不算「比间隔还短」；真的短的照报
    var reminder = Reminder(id: "n", title: "夜班", schedule: night)
    #expect(reminder.problem(now: Self.at(2, 8)) == nil)
    reminder.schedule = Schedule(kind: .interval, time: 23 * 60 + 30, until: 30, every: 90)
    #expect(reminder.problem(now: Self.at(2, 8)) == "这段时间比间隔还短，可能一次都不提醒")
    // 收拾：结束和开始一样、0:00 都当到半夜
    #expect(Schedule(kind: .interval, time: 9 * 60, until: 9 * 60).sanitized.until == 1440)
    #expect(Schedule(kind: .interval, time: 9 * 60, until: 0).sanitized.until == 1440)
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

  /// 评审 5 + 第五轮体检 E5：系统时间明显往回调过（超过 1 分钟），记在将来的处理时刻收回来，差几十秒的对时不动；
  /// 推到的时刻只截掉实际推不到的（最远 65 分钟：倒数一小时以内 + 推后 5 分钟）——14:00 推后到 15:05 的一对时照旧 15:05
  @Test func clockMovedBackPullsStateIn() {
    let a = Self.weekly("a")
    let b = Self.weekly("b")
    let now = Self.at(2, 8)
    var state = Self.state(["a": Self.at(5, 9), "b": now.addingTimeInterval(30)], list: [a, b])
    state.snoozed["a"] = Self.at(5, 9, 10)
    state.snoozed["b"] = Self.at(2, 9, 5)
    state.snoozed["c"] = Self.at(2, 8, 10)
    #expect(ReminderCenter.farthestSnooze == 65 * 60)
    let pulled = state.pulledBack(now: now, maxSnooze: ReminderCenter.farthestSnooze)
    #expect(pulled.marks["a"]?.at == now)
    #expect(pulled.marks["b"]?.at == now.addingTimeInterval(30))
    #expect(pulled.snoozed["a"] == Self.at(2, 9, 5))
    #expect(pulled.snoozed["b"] == Self.at(2, 9, 5))
    #expect(pulled.snoozed["c"] == Self.at(2, 8, 10))
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

/// 0.10.0 的提醒时间规则：自动生成的编解码、同样的字段顺序（overnightEncodingStopsOldVersions 拿它比字节、模拟旧版本往返）
private nonisolated struct OldSchedule: Codable {
  var kind: String
  var date: Date
  var time: Int
  var until: Int
  var days: [Int]
  var day: Int
  var every: Int
}
