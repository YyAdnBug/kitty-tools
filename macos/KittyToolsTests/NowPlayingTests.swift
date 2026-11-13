// 刘海岛的正在播放（2026-11-13，刘海岛扩展第 2 期）：两边抄的约定一样、快照怎么收拾、进度怎么外推、什么时候上耳朵，
// 和它作为活动的先后（最低、不进菜单栏）。
// 另有一个按需跑的实机自检 liveRoundTrip（TEST_RUNNER_KITTY_LIVE_NOW_PLAYING=1）：测试宿主（Dev 版）用公开的
// MPNowPlayingInfoCenter 把自己挂成「正在播放」（不出声），经包里真的 XPC 服务读回来、发「切换」命令收得到。
// 不碰用户偏好：偏好用临时域，岛是摆出来的（不建窗口）。

import AppKit
import Foundation
import MediaPlayer
import Synchronization
import Testing

@testable import KittyTools

@MainActor
struct NowPlayingTests {
  private func snapshot(
    elapsed: Double? = 10, timestamp: Date? = Date(timeIntervalSince1970: 1000), rate: Double = 1,
    playing: Bool = true, duration: Double? = 240
  ) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
      bundleID: "com.apple.Music", parentBundleID: nil, appName: "Music", title: "歌", artist: "人",
      album: nil, duration: duration, elapsed: elapsed, timestamp: timestamp, rate: rate,
      isPlaying: playing, canPrevious: true, canNext: true, artworkID: nil, artwork: nil)
  }

  /// App 和服务各抄的一份约定，BEGIN / END 之间逐字一样（改了一边忘了另一边，XPC 两头对不上）
  @Test func wireMatches() throws {
    let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    func block(_ path: String) throws -> Substring {
      let text = try String(contentsOf: macos.appending(path: path), encoding: .utf8)
      let start = try #require(text.range(of: "// BEGIN NowPlayingWire"))
      let end = try #require(text.range(of: "// END NowPlayingWire"))
      return text[start.lowerBound..<end.upperBound]
    }
    let app = try block("KittyTools/Shell/NowPlayingWire.swift")
    #expect(app == (try block("KittyToolsNowPlaying/NowPlayingWire.swift")))
    #expect(app.contains("struct NowPlayingSnapshot"))
  }

  /// 进度：在播且速率 > 0 才往前走（缓冲时播放器报在播、速率 0；暂停时速率 0），夹在 0…时长
  @Test func position() {
    let at = Date(timeIntervalSince1970: 1030)
    #expect(NowPlaying.position(snapshot(), at: at) == 40)
    #expect(NowPlaying.position(snapshot(rate: 2), at: at) == 70)
    #expect(NowPlaying.position(snapshot(playing: false), at: at) == 10)
    #expect(NowPlaying.position(snapshot(rate: 0), at: at) == 10)
    #expect(NowPlaying.position(snapshot(duration: 20), at: at) == 20)
    #expect(NowPlaying.position(snapshot(duration: nil), at: at) == 40)
    #expect(NowPlaying.position(snapshot(timestamp: nil), at: at) == 10)
    #expect(NowPlaying.position(snapshot(elapsed: nil), at: at) == nil)
  }

  /// 上耳朵：在播；从在播变成暂停还不到 30 秒；一打开就是暂停着的不上
  @Test func wings() {
    #expect(NowPlaying.showsOnWings(isPlaying: true, pausedFor: nil))
    #expect(!NowPlaying.showsOnWings(isPlaying: false, pausedFor: nil))
    #expect(NowPlaying.showsOnWings(isPlaying: false, pausedFor: .seconds(10)))
    #expect(!NowPlaying.showsOnWings(isPlaying: false, pausedFor: NowPlaying.pausedLinger))
  }

  /// 服务推来的 JSON：解不开、没标题的丢掉；字截短、封面太大不要、负数和非有限数不要
  @Test func decode() throws {
    #expect(NowPlaying.decode(Data("{".utf8)) == nil)
    var long = snapshot()
    long.title = String(repeating: "长", count: 500)
    long.artwork = Data(count: (1 << 20) + 1)
    long.elapsed = -3
    let decoded = try #require(NowPlaying.decode(try JSONEncoder().encode(long)))
    #expect(decoded.title.count == 200)
    #expect(decoded.artwork == nil)
    #expect(decoded.elapsed == nil)
    #expect(decoded.duration == 240)
    var empty = snapshot()
    empty.title = ""
    #expect(NowPlaying.decode(try JSONEncoder().encode(empty)) == nil)
    #expect(NowPlaying.decode(try JSONEncoder().encode(snapshot())) == snapshot())
  }

  private func activity(_ kind: Island.Activity.Kind, onWings: Bool = true) -> Island.Activity {
    Island.Activity(
      id: "\(kind)", kind: kind, title: "\(kind)", symbol: "circle.fill", onWings: onWings)
  }

  /// 正在播放最低：有别的活动时耳朵让给别的；暂停一阵后不上耳朵；菜单栏那一项不挂它
  @Test func mediaIsLowestAndStaysOffMenuBar() {
    #expect(Island.Activity.top([activity(.media), activity(.reminder)])?.kind == .reminder)
    #expect(Island.Activity.top([activity(.media)])?.kind == .media)
    #expect(Island.Activity.top([activity(.media, onWings: false)]) == nil)
    #expect(IslandMenuItem.pick([activity(.media)], wings: false) == nil)
    #expect(
      IslandMenuItem.pick([activity(.media), activity(.awake)], wings: false)?.kind == .awake)
    // 摆出来的岛同真的岛：只有不上耳朵的活动时不露耳朵
    let notch = Island.Geometry.notch(width: 212, height: 37.5)
    #expect(
      !Island(showing: nil, geometry: notch, activities: [activity(.media, onWings: false)])
        .isShowingWings)
    #expect(Island(showing: nil, geometry: notch, activities: [activity(.media)]).isShowingWings)
  }

  // MARK: 实机自检（按需）

  /// 测试宿主把自己挂成正在播放（不出声）→ 包里的服务读到、推回来 → 岛上有这个活动；发「切换」宿主收得到。
  /// 要的是 Dev 版的包里有 KittyToolsNowPlaying.xpc（scheme 构建会带上）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_NOW_PLAYING"] == "1"))
  func liveRoundTrip() async throws {
    let center = MPNowPlayingInfoCenter.default()
    // 封面和命令的回调在 MediaPlayer 自己的队列上：写成 @Sendable（主线程隔离的闭包会在那里触发执行器断言）
    let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 300, height: 300)) {
      @Sendable size in
      NSImage(size: size, flipped: false) { rect in
        NSColor.systemPink.setFill()
        rect.fill()
        return true
      }
    }
    center.nowPlayingInfo = [
      MPMediaItemPropertyTitle: "Kitty 探针曲目", MPMediaItemPropertyArtist: "Kitty",
      MPMediaItemPropertyPlaybackDuration: 240, MPNowPlayingInfoPropertyElapsedPlaybackTime: 10,
      MPNowPlayingInfoPropertyPlaybackRate: 1,
      MPMediaItemPropertyArtwork: artwork,
    ]
    center.playbackState = .playing
    let toggled = Mutex(0)
    let target = MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget {
      @Sendable _ in
      toggled.withLock { $0 += 1 }
      return .success
    }
    defer {
      MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(target)
      center.playbackState = .stopped
      center.nowPlayingInfo = nil
    }

    let suite = "now-playing-live-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: Feature.island.prefsKey)
    defaults.set(true, forKey: Prefs.islandNowPlaying)
    let island = Island(showing: nil, geometry: .notch(width: 212, height: 37.5))
    let nowPlaying = NowPlaying(island: island, defaults: defaults)
    nowPlaying.apply()
    defer {
      defaults.set(false, forKey: Prefs.islandNowPlaying)
      nowPlaying.apply()
    }

    func media() -> Island.Media? {
      island.activities.first { $0.id == NowPlaying.activityID }?.media
    }
    for _ in 0..<50 where media()?.snapshot.title != "Kitty 探针曲目" {
      try await Task.sleep(for: .milliseconds(100))
    }
    let first = try #require(media())
    #expect(first.snapshot.title == "Kitty 探针曲目")
    #expect(first.snapshot.isPlaying)
    #expect(first.snapshot.bundleID == Bundle.main.bundleIdentifier)
    for _ in 0..<30 where media()?.artwork == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(media()?.artwork != nil)
    #expect(island.isShowingWings)

    first.send(.toggle)
    for _ in 0..<30 where toggled.withLock({ $0 }) == 0 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(toggled.withLock { $0 } == 1)

    center.playbackState = .paused
    for _ in 0..<30 where media()?.snapshot.isPlaying ?? true {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(media()?.snapshot.isPlaying == false)
    // 刚暂停：耳朵还留着
    #expect(island.isShowingWings)
  }
}
