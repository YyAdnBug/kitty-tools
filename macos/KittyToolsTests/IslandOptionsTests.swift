// 刘海岛照 Alcove 能调的几样（2026-11-17 第 4 批）：提示停多久的三档、正在用放歌的 App 时不上耳朵、电量低时写还能用多久；
// 第 5 批日历：月历上有日程的日子、拒绝的也算、日历的颜色

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import KittyTools

@MainActor struct IslandOptionsTests {
  @Test func dwellLengthScales() {
    #expect(Island.DwellLength.standard.scale == 1)
    #expect(Island.DwellLength.short.scale < 1 && Island.DwellLength.long.scale > 1)
    // 偏好里存的是 rawValue
    #expect(Island.DwellLength(rawValue: "long") == .long)
  }

  @Test func sourceAppIsRecognizedByParent() {
    let music = NowPlayingSnapshot(
      bundleID: "com.apple.Music", parentBundleID: nil, appName: "音乐", title: "t", artist: nil,
      album: nil, duration: nil, elapsed: nil, timestamp: nil, rate: 1, isPlaying: true,
      canPrevious: true, canNext: true, canSeek: true, shuffle: nil, repeatMode: nil,
      artworkID: nil, artwork: nil)
    #expect(NowPlaying.isSource("com.apple.Music", of: music))
    #expect(!NowPlaying.isSource("com.apple.Safari", of: music))
    #expect(!NowPlaying.isSource(nil, of: music))
    // 浏览器里的视频：报的是 WebKit 的进程，按上级 App 认
    var video = music
    video.bundleID = "com.apple.WebKit.GPU"
    video.parentBundleID = "com.apple.Safari"
    #expect(NowPlaying.isSource("com.apple.Safari", of: video))
  }

  @Test func lowBatteryShowsMinutesLeft() {
    let known = SystemNotices.powerLevel(plugged: false, percent: 9, low: true, minutes: 25)
    #expect(known.title == "还能用约 25 分钟")
    #expect(known.wing > Island.levelWing)
    #expect(SystemNotices.powerLevel(plugged: false, percent: 9, low: true).title == "电量低")
    // 别的电源提示宽度照旧
    #expect(
      SystemNotices.powerLevel(plugged: true, percent: 50, low: false).wing == Island.levelWing)
  }

  static let tokyo: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
  }()

  static func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

  @Test func busyDaysCoverMultiDayEventsWithinMonth() throws {
    let month = try #require(
      Self.tokyo.dateInterval(of: .month, for: Self.date("2026-11-17T12:00:00+09:00")))
    let entries = [
      // 普通的一条
      NextEvent.Entry(
        id: "a", title: "周会", start: Self.date("2026-11-03T10:00:00+09:00"),
        end: Self.date("2026-11-03T11:00:00+09:00")),
      // 全天两天（结束在零点整：不算到第三天）
      NextEvent.Entry(
        id: "b", title: "出差", start: Self.date("2026-11-20T00:00:00+09:00"),
        end: Self.date("2026-11-22T00:00:00+09:00"), isAllDay: true),
      // 从上个月跨进来
      NextEvent.Entry(
        id: "c", title: "假期", start: Self.date("2026-10-30T09:00:00+09:00"),
        end: Self.date("2026-11-01T18:00:00+09:00")),
      // 拒绝了的
      NextEvent.Entry(
        id: "d", title: "拒了", start: Self.date("2026-11-25T10:00:00+09:00"),
        end: Self.date("2026-11-25T11:00:00+09:00"), declined: true),
    ]
    #expect(NextEvent.busyDays(entries, month: month, calendar: Self.tokyo) == [1, 3, 20, 21])
    #expect(
      NextEvent.busyDays(entries, month: month, declined: true, calendar: Self.tokyo)
        == [1, 3, 20, 21, 25])
  }

  @Test func declinedAndColorsFollowSettings() {
    let now = Self.date("2026-11-17T09:00:00+09:00")
    let declined = NextEvent.Entry(
      id: "d", title: "拒了", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200),
      declined: true, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(NextEvent.pick([declined], now: now) == nil)
    #expect(NextEvent.pick([declined], now: now, declined: true) == declined)
    #expect(NextEvent.today([declined], now: now).items.isEmpty)
    let shown = NextEvent.today([declined], now: now, declined: true, colored: true)
    #expect(shown.items.first?.color == declined.color)
    #expect(NextEvent.today([declined], now: now, declined: true).items.first?.color == nil)
    // 耳朵上的日历符号用日历的颜色
    let activity = NextEvent.activity(declined, join: { _ in }, openCalendar: {}, colored: true)
    #expect(activity.color != nil)
    #expect(NextEvent.activity(declined, join: { _ in }, openCalendar: {}).color == nil)
  }
}

/// 最后一批（2026-11-18）：全屏时藏起的认法（数是用户在场把 Safari 全屏时探针记的）、正在播放的颜色样式
@MainActor struct IslandFullScreenTests {
  // 1710 × 1112 的刘海屏，刘海那一条 38
  static let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)
  static let dock = IslandFullScreen.Window(pid: 1, layer: 20, frame: screen, isDock: true)
  static let menu = IslandFullScreen.Window(
    pid: 2, layer: 24, frame: CGRect(x: 0, y: 0, width: 1710, height: 38), isDock: false)

  static func window(_ frame: CGRect, pid: pid_t = 99) -> IslandFullScreen.Window {
    IslandFullScreen.Window(pid: pid, layer: 0, frame: frame, isDock: false)
  }

  @Test func fullScreenWindowWithoutDock() {
    // 全屏：从刘海下沿到底、和屏一样宽，程序坞不在（菜单栏那一层照样在）
    let full = Self.window(CGRect(x: 0, y: 38, width: 1710, height: 1074))
    #expect(
      IslandFullScreen.isFullScreen([Self.menu, full], screen: Self.screen, top: 38, front: 99))
    // 别的 App 全屏、前台不是它：不算
    #expect(
      !IslandFullScreen.isFullScreen([Self.menu, full], screen: Self.screen, top: 38, front: 7))
  }

  @Test func maximizedOrNormalWindowIsNotFullScreen() {
    // 放大：一样宽、到程序坞上沿为止，程序坞在
    let zoomed = Self.window(CGRect(x: 0, y: 38, width: 1710, height: 991))
    #expect(
      !IslandFullScreen.isFullScreen(
        [Self.menu, Self.dock, zoomed], screen: Self.screen, top: 38, front: 99))
    // 普通窗口
    let normal = Self.window(CGRect(x: 150, y: 102, width: 1468, height: 815))
    #expect(
      !IslandFullScreen.isFullScreen([Self.menu, normal], screen: Self.screen, top: 38, front: 99))
    // 程序坞在、窗口却到底（退出全屏那一帧）：不算
    let exiting = Self.window(Self.screen)
    #expect(
      !IslandFullScreen.isFullScreen(
        [Self.menu, Self.dock, exiting], screen: Self.screen, top: 38, front: 99))
  }

  @Test func dockOnAnotherScreenMeansUnknown() {
    // 外接屏是主屏、程序坞在它上面：刘海屏上铺满的窗口和全屏一个样子，一律不算（评审）
    let elsewhere = IslandFullScreen.Window(
      pid: 1, layer: 20, frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440), isDock: true)
    let filled = Self.window(CGRect(x: 0, y: 38, width: 1710, height: 1074))
    #expect(
      !IslandFullScreen.isFullScreen(
        [Self.menu, elsewhere, filled], screen: Self.screen, top: 38, front: 99))
  }

  @Test func lightPlatesGetDarkInk() {
    #expect(IslandLeading.ink(on: NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)) != .white)
    #expect(
      IslandLeading.ink(on: NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)) == .white)
  }

  @Test func mediaColorStyles() {
    let art = NSColor.systemTeal
    #expect(NowPlaying.tint(artwork: art, style: .artwork) == art)
    #expect(NowPlaying.tint(artwork: art, style: .accent) == nil)
    #expect(NowPlaying.tint(artwork: art, style: .white) == .white)
  }
}
