// 保持唤醒（第一个插件，2026-11-12）的纯函数：定时的时段（工作日、跨午夜、全天、关着）、下一次要变的时刻、偏好里读写，
// 启动器「awake …」的解析和那几行，剩多久的说法；插件没添加时启动器里「添加…插件」那一行。执行层（断言、到点、醒来）不测。

import Foundation
import Testing

@testable import KittyTools

struct KeepAwakeTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }()

  /// 2026-11-16 是周一
  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  @Test func workdaysWindow() {
    let plan = KeepAwakePlan.Schedule(isOn: true)
    #expect(plan.contains(date(16, 10), calendar: calendar))
    #expect(!plan.contains(date(16, 8, 59), calendar: calendar))
    #expect(!plan.contains(date(16, 18), calendar: calendar))  // 结束那一刻已经出了时段
    #expect(!plan.contains(date(21, 10), calendar: calendar))  // 周六
    #expect(plan.nextChange(after: date(16, 8), calendar: calendar) == date(16, 9))
    #expect(plan.nextChange(after: date(16, 10), calendar: calendar) == date(16, 18))
    // 周五下班之后：下一次是下周一 9 点
    #expect(plan.nextChange(after: date(20, 19), calendar: calendar) == date(23, 9))
    #expect(plan.summary == "工作日 9:00–18:00")
  }

  /// 结束早于开始 = 跨午夜，算在开始那天：周五 22:00 管到周六 2:00，周四晚上不算
  @Test func overnightWindow() {
    let plan = KeepAwakePlan.Schedule(isOn: true, weekdays: [6], start: 22 * 60, end: 2 * 60)
    #expect(plan.contains(date(20, 23), calendar: calendar))
    #expect(plan.contains(date(21, 1), calendar: calendar))
    #expect(!plan.contains(date(21, 3), calendar: calendar))
    #expect(!plan.contains(date(19, 23), calendar: calendar))
    #expect(plan.nextChange(after: date(21, 1), calendar: calendar) == date(21, 2))
    #expect(plan.summary == "周五 22:00–次日 2:00")
  }

  /// 开始等于结束 = 那天整整 24 小时；定时关着的什么都不算
  @Test func allDayAndOff() {
    let allDay = KeepAwakePlan.Schedule(isOn: true, weekdays: Set(1...7), allDay: true)
    #expect(allDay.contains(date(22, 12), calendar: calendar))
    #expect(allDay.summary == "每天 全天")
    // 每天全天：一直在时段里，没有「下一次要变」（半夜的接缝不算）
    #expect(allDay.nextChange(after: date(22, 12), calendar: calendar) == nil)
    let sunday = KeepAwakePlan.Schedule(isOn: true, weekdays: [1], allDay: true)
    #expect(sunday.contains(date(22, 23, 59), calendar: calendar))
    #expect(!sunday.contains(date(23, 0, 30), calendar: calendar))
    // 工作日全天：周一到周五连成一段，下一次变是周六 0 点（不是每个半夜）
    let workdays = KeepAwakePlan.Schedule(isOn: true, allDay: true)
    #expect(workdays.nextChange(after: date(17, 12), calendar: calendar) == date(21, 0))
    // 开始等于结束（拨时间时两边短暂相等）不当全天：那天没有时段
    let blank = KeepAwakePlan.Schedule(isOn: true, start: 9 * 60, end: 9 * 60)
    #expect(!blank.contains(date(16, 9), calendar: calendar))
    let off = KeepAwakePlan.Schedule()
    #expect(!off.contains(date(16, 10), calendar: calendar))
    #expect(off.nextChange(after: date(16, 8), calendar: calendar) == nil)
    let noDays = KeepAwakePlan.Schedule(isOn: true, weekdays: [])
    #expect(noDays.nextChange(after: date(16, 8), calendar: calendar) == nil)
  }

  /// 偏好里读写：往返不变；读不出的回到默认；越界的夹回来
  @Test func scheduleStorage() {
    let plan = KeepAwakePlan.Schedule(isOn: true, weekdays: [1, 7], start: 60, end: 120)
    #expect(KeepAwakePlan.Schedule.decode(plan.encoded) == plan)
    #expect(KeepAwakePlan.Schedule.decode("") == KeepAwakePlan.Schedule())
    #expect(KeepAwakePlan.Schedule.decode("不是 JSON") == KeepAwakePlan.Schedule())
    let wild = KeepAwakePlan.Schedule.decode(
      #"{"isOn":true,"weekdays":[0,2,9],"start":-5,"end":99999}"#)
    #expect(wild.weekdays == [2] && wild.start == 0 && wild.end == 24 * 60 - 1)
    #expect(plan.summary == "周末 1:00–2:00")
  }

  /// 启动器「awake」后面那截：多久之后、到几点、无限期；时间以外只许剩连接词
  @Test func parsePhrases() {
    let now = date(16, 10)
    #expect(KeepAwakePlan.parse("", now: now, calendar: calendar) == .empty)
    #expect(KeepAwakePlan.parse("无限期", now: now, calendar: calendar) == .indefinitely)
    #expect(
      KeepAwakePlan.parse("2小时", now: now, calendar: calendar)
        == .until(now.addingTimeInterval(7200), label: "2 小时"))
    #expect(
      KeepAwakePlan.parse("90m", now: now, calendar: calendar)
        == .until(now.addingTimeInterval(5400), label: "1 小时 30 分钟"))
    #expect(
      KeepAwakePlan.parse("到18点", now: now, calendar: calendar)
        == .until(date(16, 18), label: "到 18:00"))
    #expect(
      KeepAwakePlan.parse("until 18:30", now: now, calendar: calendar)
        == .until(date(16, 18, 30), label: "到 18:30"))
    #expect(KeepAwakePlan.parse("喝水", now: now, calendar: calendar) == .invalid)
    #expect(KeepAwakePlan.parse("2小时 下载", now: now, calendar: calendar) == .invalid)
  }

  @Test func wording() {
    let now = date(16, 10)
    #expect(KeepAwakePlan.remaining(until: nil, now: now) == "无限期")
    #expect(
      KeepAwakePlan.remaining(until: now.addingTimeInterval(72 * 60), now: now) == "还剩 1 小时 12 分")
    #expect(KeepAwakePlan.remaining(until: now.addingTimeInterval(7200), now: now) == "还剩 2 小时")
    #expect(KeepAwakePlan.remaining(until: now.addingTimeInterval(42 * 60), now: now) == "还剩 42 分")
    #expect(KeepAwakePlan.remaining(until: now.addingTimeInterval(30), now: now) == "还剩不到 1 分钟")
    #expect(KeepAwakePlan.moment(date(16, 18, 5), now: now, calendar: calendar) == "18:05")
    #expect(KeepAwakePlan.moment(date(17, 8), now: now, calendar: calendar) == "明天 8:00")
    #expect(KeepAwakePlan.query("awake 2h") == "2h")
    #expect(KeepAwakePlan.query("Awake 到18点") == "到18点")
    #expect(KeepAwakePlan.query("awake") == nil && KeepAwakePlan.query("awakening") == nil)
    // 中文关键词后面不打空格也认；只打关键词本身不算
    #expect(KeepAwakePlan.query("保持唤醒2小时") == "2小时" && KeepAwakePlan.query("保持唤醒") == nil)
  }

  /// 「awake …」那几行：什么都没写列五档（编号各不相同）；开着时第一行是停止；认不出给提示
  @Test func launcherRows() {
    let now = date(16, 10)
    let presets = LauncherModel.keepAwakeItems("", status: nil, now: now, calendar: calendar)
    #expect(
      presets.map(\.title) == ["保持唤醒 30 分钟", "保持唤醒 1 小时", "保持唤醒 2 小时", "保持唤醒 5 小时", "保持唤醒 无限期"])
    #expect(Set(presets.map(\.id)).count == presets.count)
    #expect(presets[1].subtitle == "到 11:00" && presets[4].subtitle == "直到你停止")
    let running = LauncherModel.keepAwakeItems(
      "2小时", status: "还剩 42 分", now: now, calendar: calendar)
    #expect(running.map(\.title) == ["停止保持唤醒", "保持唤醒 2 小时"])
    #expect(running[0].subtitle == "保持唤醒中 · 还剩 42 分" && running[1].payload == "2小时")
    let bad = LauncherModel.keepAwakeItems("喝水", status: nil, now: now, calendar: calendar)
    #expect(bad.map(\.target) == [LauncherModel.awakePrefix + "hint"])
  }

  /// 没添加的插件：打全了名字或关键词（后面还能接别的）、英文打了 4 个字母以上、中文 2 个字以上才出那一行；添加了就不出
  @Test func pluginOffers() {
    func offered(_ typed: String, added: Set<Feature> = []) -> [String] {
      LauncherModel.pluginOffers(for: typed, added: added).map(\.title)
    }
    #expect(offered("awake") == ["添加「保持唤醒」插件"])
    #expect(offered("awake 2小时") == ["添加「保持唤醒」插件"])
    #expect(offered("awak") == ["添加「保持唤醒」插件"])
    #expect(offered("保持") == ["添加「保持唤醒」插件"])
    #expect(offered("保持唤醒2小时") == ["添加「保持唤醒」插件"])
    #expect(offered("ca").isEmpty && offered("aw").isEmpty && offered("safari").isEmpty)
    #expect(offered("awake", added: [.keepAwake]).isEmpty)
    let row = LauncherModel.pluginOffers(for: "防息屏", added: [])
    #expect(row.first?.target == LauncherModel.pluginPrefix + Feature.keepAwake.rawValue)
  }
}
