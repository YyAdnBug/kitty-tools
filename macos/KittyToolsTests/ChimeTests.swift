// 刘海岛的几声提示音（Shell/Chime.swift）、日程开始那一刻（NextEvent.isStarting）、低电量模式的提示（SystemNotices）

import Foundation
import Testing

@testable import KittyTools

struct ChimeTests {
  static let tokyo: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
  }()

  static func date(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
  }

  @Test func nextHourIsTheComingTopOfHour() {
    #expect(
      HourlyChime.nextHour(after: Self.date("2026-11-17T13:20:05+09:00"), calendar: Self.tokyo)
        == Self.date("2026-11-17T14:00:00+09:00"))
    // 正好整点：下一个，不是这一个（刚响过）
    #expect(
      HourlyChime.nextHour(after: Self.date("2026-11-17T14:00:00+09:00"), calendar: Self.tokyo)
        == Self.date("2026-11-17T15:00:00+09:00"))
    // 跨零点
    #expect(
      HourlyChime.nextHour(after: Self.date("2026-11-17T23:59:30+09:00"), calendar: Self.tokyo)
        == Self.date("2026-11-18T00:00:00+09:00"))
  }

  @Test func lateAfterWakeIsSkipped() {
    let hour = Self.date("2026-11-17T14:00:00+09:00")
    #expect(HourlyChime.isOnTime(hour, now: hour.addingTimeInterval(0.05)))
    #expect(HourlyChime.isOnTime(hour, now: hour.addingTimeInterval(-0.5)))
    // 合盖睡过了整点、醒来才到
    #expect(!HourlyChime.isOnTime(hour, now: hour.addingTimeInterval(20 * 60)))
  }

  @Test func eventStartingWindow() {
    let start = Self.date("2026-11-17T14:30:00+09:00")
    let entry = NextEvent.Entry(
      id: "e", title: "周会", start: start, end: start.addingTimeInterval(1800))
    #expect(NextEvent.isStarting(entry, now: start.addingTimeInterval(0.05)))
    #expect(!NextEvent.isStarting(entry, now: start.addingTimeInterval(-1)))
    #expect(!NextEvent.isStarting(entry, now: start.addingTimeInterval(5 * 60)))
  }

  @MainActor @Test func lowPowerNoticeIsAToggle() {
    let on = SystemNotices.lowPowerLevel(on: true)
    #expect(on.kind == .toggle && on.fraction == 1 && on.tint == "systemYellowColor")
    #expect(on.title == "低电量模式")
    #expect(SystemNotices.lowPowerLevel(on: false).fraction == 0)
  }
}
