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

  /// 封面的主色：鲜艳的那一块赢（不是整张图的平均），收拾成黑底上看得清的；黑白封面没有主色
  @Test func artworkTint() throws {
    func pixels(_ colors: [(UInt8, UInt8, UInt8, Int)]) -> [UInt8] {
      colors.flatMap { color in
        (0..<color.3).flatMap { _ in [color.0, color.1, color.2, 255] }
      }
    }
    // 纯红：色相 0，饱和度夹到 0.8、亮度 1
    let red = try #require(ArtworkTint.dominant(rgba: pixels([(255, 0, 0, 16)])))
    #expect(red.hue == 0 && red.saturation == 0.8 && red.brightness == 1)
    // 暗蓝：色相在蓝那一段，本身就暗——饱和度压到 0.55、亮度提满
    let navy = try #require(ArtworkTint.dominant(rgba: pixels([(20, 30, 110, 16)])))
    #expect(abs(navy.hue - 0.648) < 0.01 && navy.saturation == 0.55 && navy.brightness == 1)
    // 暗绿：亮度提到 0.9
    let green = try #require(ArtworkTint.dominant(rgba: pixels([(10, 90, 30, 16)])))
    #expect(green.brightness == 0.9)
    // 红在 0° 两边（偏品红的红、偏橙的红）算一桶：加起来比蓝多就是红
    let reds = try #require(
      ArtworkTint.dominant(
        rgba: pixels([(255, 0, 20, 20), (255, 20, 0, 20), (0, 0, 255, 30)])))
    #expect(reds.hue < 0.02 || reds.hue > 0.98)
    // 大片灰 + 一小块橙：橙赢；两种颜色不搅成一团（红 + 蓝不出紫）
    let orange = try #require(
      ArtworkTint.dominant(rgba: pixels([(128, 128, 128, 80), (255, 140, 0, 20)])))
    #expect(abs(orange.hue - 0.0915) < 0.01)
    let mixed = try #require(
      ArtworkTint.dominant(rgba: pixels([(255, 0, 0, 30), (0, 0, 255, 20)])))
    #expect(mixed.hue == 0)
    // 黑白、全黑、空的：没有主色
    #expect(ArtworkTint.dominant(rgba: pixels([(200, 200, 200, 8), (30, 30, 30, 8)])) == nil)
    #expect(ArtworkTint.dominant(rgba: pixels([(0, 0, 0, 16)])) == nil)
    #expect(ArtworkTint.dominant(rgba: []) == nil)
    // 很淡的颜色：饱和度提到 0.5
    let pale = try #require(ArtworkTint.dominant(rgba: pixels([(255, 190, 190, 16)])))
    #expect(pale.saturation == 0.5)
  }

  /// 上一首 / 下一首都没有、又能跳的源：换成后退 / 前进 15 秒；有一个能用、不能跳、没有进度的照旧
  @Test func jumpsReplaceMissingSkips() {
    var video = snapshot()
    video.canPrevious = false
    video.canNext = false
    #expect(IslandTransport.usesJumps(video))
    #expect(!IslandTransport.usesJumps(snapshot()))
    var half = video
    half.canNext = true
    #expect(!IslandTransport.usesJumps(half))
    var live = video
    live.canSeek = false
    #expect(!IslandTransport.usesJumps(live))
    var unknown = video
    unknown.elapsed = nil
    #expect(!IslandTransport.usesJumps(unknown))
  }

  /// 双指左右滑：横着走够 36 pt、而且比竖着走得多才算；手指往左是下一首。只在正在播放露着（耳朵、它的卡片、那一张）
  /// 时切，这个源不支持的那个方向不动
  @Test func swipeSkipsTrack() {
    #expect(Island.sideways(slide: 40, swipe: 5) == true)
    #expect(Island.sideways(slide: -40, swipe: 5) == false)
    #expect(Island.sideways(slide: 30, swipe: 0) == nil)
    #expect(Island.sideways(slide: 40, swipe: -60) == nil)
    // 上下滑：竖着够 24、而且不比横着少；斜着往左右滑、竖向先到 24 的不算
    #expect(Island.upDown(slide: 0, swipe: 24) == true)
    #expect(Island.upDown(slide: 5, swipe: -30) == false)
    #expect(Island.upDown(slide: 35, swipe: 24) == nil)
    #expect(Island.upDown(slide: 0, swipe: 20) == nil)
    var sent: [NowPlayingCommand] = []
    var playing = snapshot()
    playing.canPrevious = false
    let media = Island.Activity(
      id: NowPlaying.activityID, kind: .media, title: "歌", symbol: "music.note",
      media: Island.Media(
        snapshot: playing, artwork: nil, tint: nil, appIcon: nil, send: { sent.append($0) },
        seek: { _ in }, open: {}))
    let notch = Island.Geometry.notch(width: 212, height: 37.5)
    let island = Island(showing: nil, geometry: notch, activities: [media])
    #expect(island.swipeTrack(forward: true))
    #expect(sent == [.next] && island.skip == Island.Skip(forward: true, count: 1))
    // 不支持上一首：不发、不闪、不占这一次手势
    #expect(!island.swipeTrack(forward: false))
    #expect(sent == [.next] && island.skip?.count == 1)
    // 卡片开着照样认
    island.tapped()
    island.swipeTrack(forward: true)
    #expect(sent == [.next, .next])
    // 那一张开着照样认（它最上面列着正在播放那一行）
    let board = Island(showing: nil, geometry: notch, board: [], activities: [media])
    #expect(board.swipeTrack(forward: true))
    #expect(sent == [.next, .next, .next])
    sent = [.next, .next]
    // 岛上是别的提示：不认
    let toast = Island(
      showing: .init(title: "已复制", detail: nil, tone: .success, symbol: "checkmark", leading: .tone),
      geometry: notch, activities: [media])
    toast.swipeTrack(forward: true)
    #expect(sent == [.next, .next])
    // 耳朵让给了更要紧的活动（录屏）：不认
    let recording = Island.Activity(
      id: "rec", kind: .record, title: "录屏中", symbol: "record.circle.fill")
    Island(showing: nil, geometry: notch, activities: [media, recording]).swipeTrack(forward: true)
    #expect(sent == [.next, .next])
  }

  /// 换歌的一瞥：原来有一首、现在在播、歌名或艺人变了才算；岛上只在它露在耳朵上、没别的东西时出，不进最近的提示，
  /// 点它展开成播放卡片
  @Test func glanceOnTrackChange() {
    var next = snapshot()
    next.title = "下一首"
    #expect(NowPlaying.changedTrack(from: snapshot(), to: next))
    #expect(!NowPlaying.changedTrack(from: nil, to: next))
    #expect(!NowPlaying.changedTrack(from: snapshot(), to: nil))
    #expect(!NowPlaying.changedTrack(from: snapshot(), to: snapshot(elapsed: 99)))
    var paused = next
    paused.isPlaying = false
    #expect(!NowPlaying.changedTrack(from: snapshot(), to: paused))
    var cover = snapshot()
    cover.artist = "另一个人"
    #expect(NowPlaying.changedTrack(from: snapshot(), to: cover))

    let media = Island.Activity(
      id: NowPlaying.activityID, kind: .media, title: "歌", symbol: "music.note",
      media: Island.Media(
        snapshot: snapshot(), artwork: nil, tint: nil, appIcon: nil, send: { _ in },
        seek: { _ in }, open: {}))
    let notch = Island.Geometry.notch(width: 212, height: 37.5)
    func glance(_ island: Island) {
      island.glance(
        NowPlaying.activityID, title: "下一首", detail: "人", symbol: "music.note", leading: .tone)
    }
    let island = Island(showing: nil, geometry: notch, activities: [media])
    glance(island)
    #expect(island.content?.title == "下一首" && island.history.isEmpty)
    #expect(island.cardActivity == nil)
    #expect(island.isGlancing(NowPlaying.activityID))
    // 一瞥还出着又换了一首：原地换
    island.glance(
      NowPlaying.activityID, title: "再下一首", detail: "人", symbol: "music.note", leading: .tone)
    #expect(island.content?.title == "再下一首")
    // 点一瞥：展开成播放卡片
    island.tapped()
    #expect(island.cardActivity?.id == NowPlaying.activityID && island.isExpanded)
    #expect(!island.isGlancing(NowPlaying.activityID))
    // 岛上有别的提示、那一张开着、耳朵让给了别的活动、暂停久了不上耳朵：都不出
    let busy = Island(
      showing: .init(
        title: "已复制", detail: nil, tone: .success, symbol: "checkmark", leading: .tone),
      geometry: notch, activities: [media])
    glance(busy)
    #expect(busy.content?.title == "已复制")
    let board = Island(showing: nil, geometry: notch, board: [], activities: [media])
    glance(board)
    #expect(board.content == nil && board.isBoardOpen)
    let recording = Island.Activity(
      id: "rec", kind: .record, title: "录屏中", symbol: "record.circle.fill")
    let taken = Island(showing: nil, geometry: notch, activities: [media, recording])
    glance(taken)
    #expect(taken.content == nil)
    var hidden = media
    hidden.onWings = false
    let lingering = Island(showing: nil, geometry: notch, activities: [hidden])
    glance(lingering)
    #expect(lingering.content == nil)
    // 没有刘海的屏：不出
    let capsule = Island(showing: nil, activities: [media])
    glance(capsule)
    #expect(capsule.content == nil)
  }

  /// 停在耳朵上自动展开：正在播放时右耳那一截是播放 / 暂停钮，停在它上面不展开；别的活动整只耳朵都算。
  /// 进度条拖到头 / 尾给一下触感：刚到那一头才给，停在那一头继续拖不重复给；长歌名多出不到 1 pt 不滚
  @Test func hoverExpandAndFeel() {
    // 形体 700…1000，耳朵宽 36（另加鼓起的 8）：744 往左是左耳、956 往右是右耳，中间是刘海
    let shape = CGRect(x: 700, y: 0, width: 300, height: 40)
    #expect(Island.hoverExpands(pointerX: 720, shape: shape, onMedia: true))
    #expect(!Island.hoverExpands(pointerX: 850, shape: shape, onMedia: true))
    #expect(!Island.hoverExpands(pointerX: 850, shape: shape, onMedia: false))
    #expect(!Island.hoverExpands(pointerX: 980, shape: shape, onMedia: true))
    #expect(Island.hoverExpands(pointerX: 980, shape: shape, onMedia: false))
    #expect(IslandScrubber.hitEnd(from: 10, to: 0, duration: 240))
    #expect(IslandScrubber.hitEnd(from: 200, to: 240, duration: 240))
    #expect(!IslandScrubber.hitEnd(from: 0, to: 0, duration: 240))
    #expect(!IslandScrubber.hitEnd(from: 240, to: 240, duration: 240))
    #expect(!IslandScrubber.hitEnd(from: 10, to: 20, duration: 240))
    #expect(!IslandScrubber.hitEnd(from: 10, to: nil, duration: 240))
    #expect(IslandScrubber.hitEnd(from: nil, to: 0, duration: 240))
    #expect(!IslandScrubber.hitEnd(from: 10, to: 0, duration: 0))
    #expect(IslandMarquee.overflow(text: 300, box: 200) == 100)
    #expect(IslandMarquee.overflow(text: 200.4, box: 200) == 0)
    #expect(IslandMarquee.overflow(text: 100, box: 200) == 0)
    #expect(IslandMarquee.overflow(text: 300, box: 0) == 0)
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
