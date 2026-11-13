// 正在播放的退路（2026-11-13 刘海岛扩展第 2 期第 2-3 批，拍板 E1「读不到时 Music、Spotify 退回 AppleScript」）。
// 正在播放服务靠借 com.apple. 前缀读系统的正在播放；Apple 哪天收紧了，服务会静默读到空的。那时只剩音乐和 Spotify：
// - 歌名、艺人、专辑、在不在播、时长：它们状态一变就发分布式通知（com.apple.Music.playerInfo、
//   com.spotify.client.PlaybackStateChanged），**不要任何授权**——退路先用它；Spotify 的还带播到哪
// - 音乐播到哪：通知里没有，要 AppleScript（player position）。只在已经允许过控制「音乐」时读，从不自己弹授权框
// - 按钮：先照旧交给服务发（发命令不设门槛，服务读不到时多半还发得出去）；服务整个不能用时用 AppleScript，
//   这时授权框是用户点按钮弹的
// 什么时候算服务坏了（NowPlaying 判断）：服务说取不到 MediaRemote 的函数；或者音乐 / Spotify 说在播、服务 2 秒都报不出
// 正在播放。这里是纯函数和执行层的几样小东西，NowPlaying 接线。
// ponytail: 退路里音乐只有已经允许过控制「音乐」时才有进度（点过一次播放控制、在系统框里点了允许就有了）；没有封面
// （AppleScript 能取但要把整张图从 osascript 的输出里解出来），放那个 App 的图标。真有人用到退路再加

import AppKit

/// nonisolated：分布式通知的回调里就地把通知解成快照（Sendable 的）再回主线程
nonisolated enum NowPlayingFallback {
  /// 听哪几个分布式通知、各是哪个 App 发的
  static let notices: [(name: String, bundleID: String, appName: String)] = [
    ("com.apple.Music.playerInfo", "com.apple.Music", "音乐"),
    ("com.spotify.client.PlaybackStateChanged", "com.spotify.client", "Spotify"),
  ]

  /// 服务多久报不出正在播放、而播放器说在播，就算服务读不到了
  static let grace = Duration.seconds(2)

  /// 播放器的分布式通知 → 快照（纯函数）：停了（Stopped）、没有歌名是 nil。
  /// 两家都写「Player State」（Playing / Paused / Stopped）、「Name」「Artist」「Album」；时长音乐是「Total Time」、
  /// Spotify 是「Duration」（都是毫秒）；Spotify 另有「Playback Position」（秒），音乐没有
  static func snapshot(bundleID: String, appName: String, info: [AnyHashable: Any], now: Date)
    -> NowPlayingSnapshot?
  {
    let state = info["Player State"] as? String
    guard state != "Stopped", let title = text(info["Name"]) else { return nil }
    let playing = state == "Playing"
    let milliseconds = (info["Total Time"] ?? info["Duration"]) as? NSNumber
    let duration = milliseconds.map { $0.doubleValue / 1000 }.flatMap { $0 > 0 ? $0 : nil }
    let position = (info["Playback Position"] as? NSNumber)?.doubleValue
    return NowPlayingSnapshot(
      bundleID: bundleID, parentBundleID: nil, appName: appName, title: title,
      artist: text(info["Artist"]), album: text(info["Album"]), duration: duration,
      elapsed: position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
      timestamp: position == nil ? nil : now, rate: playing ? 1 : 0, isPlaying: playing,
      canPrevious: true, canNext: true, artworkID: nil, artwork: nil)
  }

  private static func text(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return String(text.prefix(200))
  }

  /// 几个播放器各自最近的一份里挑一个：在播的先，同样在不在播的取后来的
  static func pick(_ notices: [(snapshot: NowPlayingSnapshot, at: Date)]) -> NowPlayingSnapshot? {
    notices.max { ($0.snapshot.isPlaying ? 1 : 0, $0.at) < ($1.snapshot.isPlaying ? 1 : 0, $1.at) }?
      .snapshot
  }

  /// 按钮在 AppleScript 里怎么说（服务整个不能用时）
  static func script(_ command: NowPlayingCommand, bundleID: String) -> String {
    let verb =
      switch command {
      case .play: "play"
      case .pause: "pause"
      case .toggle: "playpause"
      case .next: "next track"
      case .previous: "previous track"
      }
    // 先看它在不在运行：`tell application` 会把没开的 App 开起来（点按钮那一刻它可能刚退出，评审 6）
    return
      "if application id \"\(bundleID)\" is running then tell application id \"\(bundleID)\" to \(verb)"
  }
}

extension NowPlayingFallback {
  /// 服务整个不能用时按钮走 AppleScript（osascript，进程外；本 App 是它的「负责的进程」，授权框写的是本 App）。
  /// 没问过时 osascript 会弹授权框——这是用户点了按钮才弹的；拒绝过（−1743 / −1744）刘海岛说一声、带「打开系统设置」
  @MainActor static func run(
    _ command: NowPlayingCommand, bundleID: String, appName: String, island: Island?
  )
    async
  {
    guard
      let result = try? await Subprocess.run(
        "/usr/bin/osascript", ["-e", script(command, bundleID: bundleID)], captures: true,
        timeout: .seconds(30))
    else { return }
    guard result.status != 0 else { return }
    if result.error.contains("-1743") || result.error.contains("-1744") {
      island?.show(
        "没有权限控制「\(appName)」",
        detail: "在 系统设置 › \(Permissions.privacyPane) › 自动化 里打开", tone: .warning,
        actions: [.settings(for: .automation)])
    }
  }

  /// 「音乐」此刻播到哪（秒）：只在已经允许过控制「音乐」时读（Permissions.canAutomate，不弹框）；读不到是 nil。
  /// 让 AppleScript 回毫秒的整数（小数的写法跟着系统的数字格式走，有的地区是逗号）
  @MainActor static func musicPosition() async -> Double? {
    guard Permissions.canAutomate("com.apple.Music"),
      let result = try? await Subprocess.run(
        "/usr/bin/osascript",
        [
          "-e",
          "if application id \"com.apple.Music\" is running then tell application id \"com.apple.Music\" to return (player position * 1000) as integer",
        ],
        captures: true, timeout: .seconds(3)),
      result.status == 0,
      let milliseconds = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return milliseconds >= 0 ? milliseconds / 1000 : nil
  }
}
