// 刘海岛的正在播放（2026-11-13，刘海岛扩展第 2 期）：两边抄的约定一样、快照怎么收拾、进度怎么外推、什么时候上耳朵，
// 和它作为活动的先后（最低、不进菜单栏）。
// 另有一个按需跑的实机自检 liveRoundTrip（TEST_RUNNER_KITTY_LIVE_NOW_PLAYING=1）：测试宿主（Dev 版）用公开的
// MPNowPlayingInfoCenter 把自己挂成「正在播放」（不出声），经包里真的 XPC 服务读回来、发「切换」「跳到某一秒」命令收得到。
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
    playing: Bool = true, duration: Double? = 240, canSeek: Bool = true
  ) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
      bundleID: "com.apple.Music", parentBundleID: nil, appName: "Music", title: "歌", artist: "人",
      album: nil, duration: duration, elapsed: elapsed, timestamp: timestamp, rate: rate,
      isPlaying: playing, canPrevious: true, canNext: true, canSeek: canSeek, artworkID: nil,
      artwork: nil)
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

  /// 进度条：要跳到的秒数夹进这一首里，这个 App 不支持跳、没有时长（直播）就跳不了；细条上的一点换成秒，拖过头是头 / 尾；
  /// 读屏一步是时长的 5%、至少 5 秒
  @Test func seeking() {
    #expect(NowPlaying.seekTarget(100, in: snapshot()) == 100)
    #expect(NowPlaying.seekTarget(-5, in: snapshot()) == 0)
    #expect(NowPlaying.seekTarget(999, in: snapshot()) == 240)
    #expect(NowPlaying.seekTarget(100, in: snapshot(canSeek: false)) == nil)
    #expect(NowPlaying.seekTarget(100, in: snapshot(duration: nil)) == nil)
    #expect(NowPlaying.seekTarget(100, in: snapshot(duration: 0)) == nil)
    #expect(NowPlaying.seekTarget(.nan, in: snapshot()) == nil)
    #expect(IslandScrubber.seconds(at: 50, width: 200, duration: 240) == 60)
    #expect(IslandScrubber.seconds(at: -30, width: 200, duration: 240) == 0)
    #expect(IslandScrubber.seconds(at: 260, width: 200, duration: 240) == 240)
    #expect(IslandScrubber.seconds(at: 50, width: 0, duration: 240) == 0)
    #expect(IslandScrubber.seconds(at: 50, width: 200, duration: .infinity) == 0)
    #expect(IslandScrubber.fraction(60, of: 240) == 0.25)
    #expect(IslandScrubber.fraction(999, of: 240) == 1)
    #expect(IslandScrubber.fraction(-1, of: 240) == 0)
    #expect(IslandScrubber.fraction(10, of: 0) == 0)
    #expect(NowPlaying.seekStep(duration: 240) == 12)
    #expect(NowPlaying.seekStep(duration: 30) == 5)
  }

  /// 刚跳过、播放器还没报到跳到的位置附近：岛上当它已经在那儿（之后照常往前走）；报到了附近、换了歌、过了 holdTime
  /// 都照播放器报的——松手那一下不闪回旧位置，播放器不理这条命令时也不会一直骗人
  @Test func holdAfterSeek() throws {
    let at = Date(timeIntervalSince1970: 1030)
    // 跳之前：1000 那一刻在 10 秒、在播（1030 时在 40 秒）；跳到 200
    let served = snapshot()
    let hold = NowPlaying.Hold(position: 200, at: at, title: served.title)
    let later = at.addingTimeInterval(1)
    let held = try #require(NowPlaying.holding(hold, over: served, now: later))
    #expect(held.elapsed == 200 && held.timestamp == at)
    #expect(NowPlaying.position(held, at: later) == 201)
    // 封面晚到这类不带新进度的推送：照旧顶着
    var late = served
    late.artworkID = "a"
    #expect(NowPlaying.holding(hold, over: late, now: later)?.elapsed == 200)
    // 先到的一条是旧位置配新时间戳（一次操作好几条通知）：还顶着，不闪回去
    let stale = snapshot(elapsed: 40, timestamp: at.addingTimeInterval(0.1))
    #expect(NowPlaying.holding(hold, over: stale, now: later)?.elapsed == 200)
    // 播放器报到了跳到的位置附近（吸到关键帧上差一点）：照它的
    let reported = snapshot(elapsed: 199, timestamp: at.addingTimeInterval(0.2))
    #expect(NowPlaying.holding(hold, over: reported, now: later) == reported)
    // 暂停着跳：位置停在跳到的地方，不往前走
    let paused = snapshot(rate: 0, playing: false)
    let heldPaused = try #require(NowPlaying.holding(hold, over: paused, now: later))
    #expect(NowPlaying.position(heldPaused, at: later) == 200)
    // 换了歌、到点了、没有在播的了、没跳过
    var other = served
    other.title = "另一首"
    #expect(NowPlaying.holding(hold, over: other, now: later) == other)
    #expect(
      NowPlaying.holding(hold, over: served, now: at.addingTimeInterval(NowPlaying.holdTime))
        == served)
    #expect(NowPlaying.holding(hold, over: nil, now: at) == nil)
    #expect(NowPlaying.holding(nil, over: served, now: at) == served)
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
    // 网页能报离谱的时长和速率：时长、进度超过上限不要，速率夹住；显示的时间再兜一层（Int(Double) 越界会闪退）
    var huge = snapshot()
    huge.duration = 1e20
    huge.elapsed = 1e19
    huge.rate = 1e9
    let clamped = try #require(NowPlaying.decode(try JSONEncoder().encode(huge)))
    #expect(clamped.duration == nil && clamped.elapsed == nil)
    #expect(clamped.rate == NowPlaying.maxRate)
    #expect(IslandMediaCard.clock(1e20) == "99:59:59")
    #expect(IslandMediaCard.clock(.infinity) == "0:00")
    #expect(IslandMediaCard.clock(-5) == "0:00")
    #expect(IslandMediaCard.clock(84) == "1:24")
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
    // 跳到某一秒：宿主收到的位置（没收到是 nil）
    let sought = Mutex<Double?>(nil)
    let seekTarget = MPRemoteCommandCenter.shared().changePlaybackPositionCommand.addTarget {
      @Sendable event in
      sought.withLock { $0 = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime }
      return .success
    }
    let target = MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget {
      @Sendable _ in
      toggled.withLock { $0 += 1 }
      return .success
    }
    defer {
      MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(target)
      MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(seekTarget)
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

    // 跳到 2:00：宿主收到这个位置；岛上当场就在那儿（播放器还没报回来，顶着的）；宿主报回新进度后照它的
    #expect(first.snapshot.canSeek)
    first.seek(120)
    let optimistic = try #require(media()).snapshot
    #expect(abs((NowPlaying.position(optimistic, at: .now) ?? 0) - 120) < 1)
    for _ in 0..<30 where sought.withLock({ $0 }) == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(sought.withLock { $0 } == 120)
    var info = center.nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 121
    center.nowPlayingInfo = info
    for _ in 0..<30 where media()?.snapshot.elapsed != 121 {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(media()?.snapshot.elapsed == 121)

    center.playbackState = .paused
    for _ in 0..<30 where media()?.snapshot.isPlaying ?? true {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(media()?.snapshot.isPlaying == false)
    // 刚暂停：耳朵还留着
    #expect(island.isShowingWings)
  }
}
