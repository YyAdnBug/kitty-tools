// 刘海岛上的「下一个日程」（2026-11-14）：挑哪一个、什么时候挂、会议链接认哪些、挂在岛上什么样。
// 只测纯函数：不碰 EventKit（碰了会弹「日历」授权框、读到用户真的日程）。

import Foundation
import Testing

@testable import KittyTools

@MainActor
struct NextEventTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func entry(
    _ title: String, in minutes: Double, allDay: Bool = false, declined: Bool = false,
    location: String? = nil, url: URL? = nil, notes: String? = nil
  ) -> NextEvent.Entry {
    let start = now.addingTimeInterval(minutes * 60)
    return NextEvent.Entry(
      id: title, title: title, start: start, end: start.addingTimeInterval(1800),
      isAllDay: allDay, declined: declined, location: location, url: url, notes: notes)
  }

  /// 还没开始的里面最早的；全天的、拒绝 / 取消的、已经开始的不算
  @Test func picksEarliestUpcoming() {
    let picked = NextEvent.pick(
      [
        entry("下午的", in: 240), entry("周会", in: 25), entry("全天", in: 5, allDay: true),
        entry("拒绝了的", in: 10, declined: true), entry("正在开的", in: -5),
      ], now: now)
    #expect(picked?.title == "周会")
    #expect(NextEvent.pick([entry("正在开的", in: -5)], now: now) == nil)
    #expect(NextEvent.pick([], now: now) == nil)
    // 同一刻开始的按标题排（哪个在前都行，要的是每次挑出来同一个）
    #expect(NextEvent.pick([entry("b", in: 30), entry("a", in: 30)], now: now)?.title == "a")
    #expect(NextEvent.pick([entry("a", in: 30), entry("b", in: 30)], now: now)?.title == "a")
  }

  /// 开始前 10 分钟才挂；挂着时等到开始那一刻再看；还早就等到该挂的那一刻，最远 6 小时后再看一遍
  @Test func planShowsTenMinutesBefore() {
    let soon = entry("周会", in: 8)
    let shown = NextEvent.plan(soon, now: now)
    #expect(shown.shows && shown.next == soon.start)
    let edge = NextEvent.plan(entry("周会", in: 10), now: now)
    #expect(edge.shows)
    let later = entry("周会", in: 25)
    let waiting = NextEvent.plan(later, now: now)
    #expect(!waiting.shows && waiting.next == later.start.addingTimeInterval(-NextEvent.lead))
    let far = NextEvent.plan(entry("明天的", in: 20 * 60), now: now)
    #expect(!far.shows && far.next == now.addingTimeInterval(NextEvent.recheck))
    let none = NextEvent.plan(nil, now: now)
    #expect(!none.shows && none.next == now.addingTimeInterval(NextEvent.recheck))
  }

  /// 会议链接：只认 https、主机是认得的那几家（含子域名）；先看日程自己的网址，再从地点、备注里找
  @Test func meetingLinks() throws {
    let zoom = try #require(URL(string: "https://us02web.zoom.us/j/123456?pwd=abc"))
    #expect(NextEvent.meetingURL(entry("会", in: 5, url: zoom)) == zoom)
    #expect(
      NextEvent.meetingURL(entry("会", in: 5, location: "https://meet.google.com/abc-defg-hij"))?
        .host() == "meet.google.com")
    #expect(
      NextEvent.meetingURL(
        entry("会", in: 5, notes: "议程见附件\n入会：https://meeting.tencent.com/dm/AbCd 密码 1234"))?
        .host() == "meeting.tencent.com")
    // 不带协议的、http 的：主机认得就换成 https 再开
    #expect(
      NextEvent.meetingURL(entry("会", in: 5, notes: "入会 zoom.us/j/123456"))?.absoluteString
        == "https://zoom.us/j/123456")
    #expect(
      NextEvent.meetingURL(entry("会", in: 5, location: "http://zoom.us/j/1"))?.scheme == "https")
    // 很长的邀请信：入会的那一段在信尾也找得到
    let letter = String(repeating: "客套话。", count: 3000) + "\nhttps://teams.microsoft.com/l/x"
    #expect(NextEvent.meetingURL(entry("会", in: 5, notes: letter))?.host() == "teams.microsoft.com")
    // 不认得的主机、长得像的主机、带用户名骗人的、别的协议：不给「加入会议」
    for text in [
      "https://example.com/meeting", "https://notzoom.us/j/1", "https://zoom.us.evil.example/j/1",
      "https://zoom.us@evil.example/j/1", "zoommtg://zoom.us/join?confno=1", "三楼会议室",
    ] {
      #expect(NextEvent.meetingURL(entry("会", in: 5, location: text, notes: text)) == nil)
    }
    // 日程自己的网址不认得时，接着从地点里找
    let docs = try #require(URL(string: "https://docs.example.com/agenda"))
    #expect(
      NextEvent.meetingURL(
        entry("会", in: 5, location: "https://teams.microsoft.com/l/meetup-join/x", url: docs))?
        .host() == "teams.microsoft.com")
  }

  /// 挂在岛上：类别同提醒的倒数、倒数到开始；有会议链接时第一个按钮是「加入会议」（点岛本身也是它），没有就只有「打开日历」；
  /// 第二行是时间和地点（地点是网址的不写）；空标题、超长标题收拾过
  @Test func activityOnIsland() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    var joined: URL?
    var opened = 0
    let meeting = entry(
      "周会", in: 8, location: "会议室 A\n三楼", url: URL(string: "https://zoom.us/j/1"))
    let activity = NextEvent.activity(meeting, join: { joined = $0 }, openCalendar: { opened += 1 })
    #expect(activity.id == NextEvent.activityID && activity.kind == .event)
    // 比保持唤醒、提醒的倒数要紧（它们一挂几个小时），让给录制
    #expect(Island.Activity.Kind.event > .awake && Island.Activity.Kind.event > .reminder)
    #expect(Island.Activity.Kind.event < .progress)
    #expect(activity.trailing == .countdown(to: meeting.start) && activity.symbol == "calendar")
    #expect(activity.actions.map(\.title) == ["加入会议", "打开日历"])
    #expect(activity.actions.map(\.opens) == [true, false])
    activity.actions[0].run()
    activity.actions[1].run()
    #expect(joined?.host() == "zoom.us" && opened == 1)
    // 1_000_000 秒 = 1970-01-12 13:46:40 UTC，8 分钟后 13:54 开始、开半小时
    let detail = NextEvent.detail(meeting, timeZone: utc)
    #expect(detail.hasSuffix(" · 会议室 A") && detail.contains("–"))
    let plain = NextEvent.activity(entry("  ", in: 8), join: { _ in }, openCalendar: {})
    #expect(plain.title == "日程" && plain.actions.map(\.title) == ["打开日历"])
    #expect(plain.actions[0].opens)
    #expect(!NextEvent.detail(entry("会", in: 8, location: "https://zoom.us/j/1")).contains("·"))
    let long = NextEvent.activity(
      entry(String(repeating: "长", count: 500), in: 8), join: { _ in }, openCalendar: {})
    #expect(long.title.count == 200)
  }
}
