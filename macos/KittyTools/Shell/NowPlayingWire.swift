// App 和正在播放服务（KittyToolsNowPlaying，XPC）之间的约定：协议、命令、快照（刘海岛扩展第 2 期）。
// 两边各抄一份（服务那份在 KittyToolsNowPlaying/NowPlayingWire.swift），BEGIN / END 之间逐字一样（NowPlayingTests.wireMatches 比对）。

import Foundation

// BEGIN NowPlayingWire
/// App → 服务。nonisolated：XPC 在自己的队列上调过来
@objc nonisolated protocol NowPlayingServing {
  /// 开始听；之后有变化就推 NowPlayingListening.update（连上时先推一次眼下的）。回 MediaRemote 能不能用（取不到函数是 false）
  func subscribe(reply: @escaping @Sendable (Bool) -> Void)
  /// 发命令（NowPlayingCommand 的 rawValue）
  func send(_ command: Int)
  /// 跳到这一首的第几秒（快照里 canSeek 才有用；不是 0…一千万秒里的有限数服务不发）
  func seek(to seconds: Double)
  /// 换随机 / 循环的模式（快照里 shuffle / repeatMode 不是 nil 才有用；1…3 以外的不发）
  func setShuffle(_ mode: Int)
  func setRepeat(_ mode: Int)
}

/// 服务 → App
@objc nonisolated protocol NowPlayingListening {
  /// 正在播放变了（服务那边合并过、和上一次不一样才推）：NowPlayingSnapshot 的 JSON；空的 Data = 没有在播的
  func update(_ snapshot: Data)
}

/// MediaRemote 的命令号（MRMediaRemoteSendCommand）
nonisolated enum NowPlayingCommand: Int, Sendable {
  case play = 0
  case pause = 1
  case toggle = 2
  case next = 4
  case previous = 5
}

/// 一次读到的正在播放（服务合并过的）
nonisolated struct NowPlayingSnapshot: Codable, Equatable, Sendable {
  /// 报上来的是哪个进程（Safari 的是 com.apple.WebKit.GPU）、它的上级 App（Safari）、显示名
  var bundleID: String
  var parentBundleID: String?
  var appName: String?
  var title: String
  var artist: String?
  var album: String?
  /// 秒；网页直播之类的没有
  var duration: Double?
  /// 进度：timestamp 那一刻在 elapsed 秒，之后按 rate 往前走（rate 0 = 停着：暂停、缓冲）
  var elapsed: Double?
  var timestamp: Date?
  var rate: Double
  /// 播放器说自己在不在播（按钮看它；缓冲时它是 true、rate 是 0）
  var isPlaying: Bool
  /// 这个 App 此刻支不支持上一首 / 下一首（Chrome 里单个视频就没有）
  var canPrevious: Bool
  var canNext: Bool
  /// 这个 App 此刻支不支持跳到某一秒（进度条能不能拖；直播、有的网页视频没有）
  var canSeek: Bool
  /// 随机、循环现在是哪一档（MediaRemote 的数）；nil = 这个 App 此刻不支持（浏览器里的视频）。
  /// 随机：1 关、2 按专辑、3 按歌曲；循环：1 关、2 单曲、3 列表
  var shuffle: Int?
  var repeatMode: Int?
  /// 封面：换了才变的编号、缩到最长边 256 的 JPEG；网页视频刚换片的头两秒没有
  var artworkID: String?
  var artwork: Data?
}
// END NowPlayingWire
