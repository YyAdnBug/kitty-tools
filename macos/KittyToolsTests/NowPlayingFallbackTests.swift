// 正在播放的退路（刘海岛扩展第 2 期第 2-3 批）：音乐 / Spotify 的分布式通知怎么变成快照，按钮在 AppleScript 里怎么说。

import Foundation
import Testing

@testable import KittyTools

struct NowPlayingFallbackTests {
  private let now = Date(timeIntervalSince1970: 5000)

  /// 音乐：带总长（毫秒）、不带播到哪；Spotify：时长叫 Duration、带播到哪（秒）
  @Test func noticesBecomeSnapshots() throws {
    let music = try #require(
      NowPlayingFallback.snapshot(
        bundleID: "com.apple.Music", appName: "音乐",
        info: [
          "Player State": "Playing", "Name": "歌", "Artist": "人", "Album": "", "Total Time": 240_500,
        ], now: now))
    #expect(music.title == "歌")
    #expect(music.artist == "人")
    #expect(music.album == nil)
    #expect(music.duration == 240.5)
    #expect(music.elapsed == nil)
    #expect(music.isPlaying && music.rate == 1)
    let spotify = try #require(
      NowPlayingFallback.snapshot(
        bundleID: "com.spotify.client", appName: "Spotify",
        info: [
          "Player State": "Paused", "Name": "曲", "Duration": 180_000, "Playback Position": 42.5,
        ], now: now))
    #expect(spotify.duration == 180)
    #expect(spotify.elapsed == 42.5)
    #expect(spotify.timestamp == now)
    #expect(!spotify.isPlaying && spotify.rate == 0)
  }

  /// 停了、没有歌名的不算；位置不是非负有限数的不要
  @Test func stoppedOrNamelessIsNothing() {
    let snapshot = { (info: [AnyHashable: Any]) in
      NowPlayingFallback.snapshot(bundleID: "b", appName: "a", info: info, now: self.now)
    }
    #expect(snapshot(["Player State": "Stopped", "Name": "歌"]) == nil)
    #expect(snapshot(["Player State": "Playing"]) == nil)
    #expect(snapshot(["Player State": "Playing", "Name": ""]) == nil)
    #expect(
      snapshot(["Player State": "Playing", "Name": "歌", "Playback Position": -1])?.elapsed == nil)
  }

  private func notice(_ title: String, playing: Bool) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
      bundleID: "b", parentBundleID: nil, appName: nil, title: title, artist: nil, album: nil,
      duration: nil, elapsed: nil, timestamp: nil, rate: playing ? 1 : 0, isPlaying: playing,
      canPrevious: true, canNext: true, canSeek: true, artworkID: nil, artwork: nil)
  }

  /// 几个播放器里挑：在播的先，同样在不在播的取后来的
  @Test func picksPlayingThenLatest() {
    let early = Date(timeIntervalSince1970: 1)
    let late = Date(timeIntervalSince1970: 2)
    #expect(NowPlayingFallback.pick([]) == nil)
    #expect(
      NowPlayingFallback.pick([
        (notice("早·在播", playing: true), early), (notice("晚·暂停", playing: false), late),
      ])?.title == "早·在播")
    #expect(
      NowPlayingFallback.pick([
        (notice("早", playing: false), early), (notice("晚", playing: false), late),
      ])?.title == "晚")
  }

  /// 岛上用哪一份：服务报得出来就用服务的；报不出来、在用退路时才从通知里挑
  @Test @MainActor func effectivePrefersService() {
    let served = notice("服务的", playing: true)
    let notices = [(notice("通知的", playing: true), Date(timeIntervalSince1970: 1))]
    #expect(
      NowPlaying.effective(served: served, usesFallback: true, notices: notices)?.title == "服务的")
    #expect(NowPlaying.effective(served: nil, usesFallback: false, notices: notices) == nil)
    #expect(
      NowPlaying.effective(served: nil, usesFallback: true, notices: notices)?.title == "通知的")
  }

  @Test func scripts() {
    #expect(
      NowPlayingFallback.script(.toggle, bundleID: "com.apple.Music")
        == "if application id \"com.apple.Music\" is running then tell application id \"com.apple.Music\" to playpause"
    )
    #expect(
      NowPlayingFallback.script(.next, bundleID: "com.spotify.client")
        == "if application id \"com.spotify.client\" is running then tell application id \"com.spotify.client\" to next track"
    )
    // 跳到某一秒：整秒（83.6 → 84），离谱的数夹住
    #expect(
      NowPlayingFallback.seekScript(83.6, bundleID: "com.apple.Music")
        == "if application id \"com.apple.Music\" is running then tell application id \"com.apple.Music\" to set player position to 84"
    )
    #expect(NowPlayingFallback.seekScript(-.infinity, bundleID: "x").hasSuffix("to 0"))
  }

  /// 连不上服务（名字不存在 = 包里的服务找不到、拉不起来）→ 用退路：Spotify 说在播的那一首挂到岛上。
  /// 通知直接喂给 NowPlaying，不往全系统发假的播放器通知（别的 App 会当真）；用 Spotify 的编号，不去读「音乐」的进度
  @Test @MainActor func missingServiceFallsBackToPlayers() async throws {
    let suite = "now-playing-fallback-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: Feature.island.prefsKey)
    defaults.set(true, forKey: Prefs.islandNowPlaying)
    let island = Island(showing: nil, geometry: .notch(width: 212, height: 37.5))
    let nowPlaying = NowPlaying(
      island: island, defaults: defaults, serviceName: "com.apple.kittytools.missing-\(UUID())")
    nowPlaying.apply()
    defer {
      defaults.set(false, forKey: Prefs.islandNowPlaying)
      nowPlaying.apply()
    }
    var spotify = notice("退路的歌", playing: true)
    spotify.bundleID = "com.spotify.client"
    nowPlaying.noticed("com.spotify.client", spotify)
    func title() -> String? {
      island.activities.first { $0.id == NowPlaying.activityID }?.media?.snapshot.title
    }
    for _ in 0..<50 where title() == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(title() == "退路的歌")
    #expect(island.isShowingWings)
    // 播放器说停了 → 活动结束
    nowPlaying.noticed("com.spotify.client", nil)
    #expect(title() == nil)
  }
}
