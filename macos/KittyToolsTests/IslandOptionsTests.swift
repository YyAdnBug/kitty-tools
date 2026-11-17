// 刘海岛照 Alcove 能调的几样（2026-11-17 第 4 批）：提示停多久的三档、正在用放歌的 App 时不上耳朵、电量低时写还能用多久

import Foundation
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
}
