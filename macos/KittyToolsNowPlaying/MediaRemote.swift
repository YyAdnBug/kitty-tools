// 读系统的「正在播放」（私有框架 MediaRemote，dlopen / dlsym；全仓库只有这个文件碰它，mac-native §2 §3）。
// macOS 15.4 起 mediaremoted 只把别的 App 的播放信息给 bundle id 以 com.apple. 开头的进程，所以它在这个 XPC 服务里、不在 App 里。
// 2026-11-13 macOS 27.0.1 实测（macos/build/research/now-playing-2026-11-13/report.md）：
// - 信息里不再带封面字节（只有尺寸、MIME、ArtworkIdentifier），封面要另外用私有类 MRNowPlayingRequest 去要；15 / 26 上信息里
//   可能还直接带着（没在这台机器上测），两种都认：有字节就用，没有再要
// - 一次操作来 1–9 条通知、0.4 s 以内，暂停时第一条读到的 isPlaying 还是旧的：合并 100 ms 再读
// - 稳定播放时不来通知；读一遍 ≤ 30 ms
// - Safari 报的是 com.apple.WebKit.GPU（上级 com.apple.Safari）；Chrome 单个视频不支持上一首 / 下一首，发了照样返回成功
// 这个进程没有界面：回调都投在主队列上，在主线程上做（含缩封面，几十毫秒）。取不到的函数 / 类一律当「没有」：读到空的、不崩。

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor final class MediaRemote {
  private typealias GetInfo =
    @convention(c) (
      DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void
  private typealias GetClient =
    @convention(c) (
      DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void
    ) -> Void
  private typealias GetBool =
    @convention(c) (
      DispatchQueue, @escaping @convention(block) (Bool) -> Void
    ) -> Void
  private typealias Register = @convention(c) (DispatchQueue) -> Void
  private typealias Unregister = @convention(c) () -> Void
  private typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
  private typealias ClientString = @convention(c) (AnyObject) -> Unmanaged<CFString>?
  private typealias InfoCommand = @convention(c) (AnyObject) -> UInt32
  private typealias InfoEnabled = @convention(c) (AnyObject) -> Bool
  private typealias InfoOptions = @convention(c) (AnyObject) -> Unmanaged<CFDictionary>?
  private typealias SetMode = @convention(c) (Int32) -> Void
  private typealias SetWants = @convention(c) (Bool) -> Void
  /// -[MRNowPlayingRequest requestNowPlayingItemArtworkOnQueue:completion:] / requestSupportedCommandsOnQueue:completion:
  private typealias Request =
    @convention(c) (
      AnyObject, Selector, DispatchQueue,
      @escaping @convention(block) (AnyObject?, AnyObject?) -> Void
    ) -> Void

  private let handle = dlopen(
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

  /// 读的那几个函数都取得到
  var isAvailable: Bool {
    getInfo != nil && getClient != nil && getPlaying != nil && register != nil
  }

  private lazy var getInfo: GetInfo? = function("MRMediaRemoteGetNowPlayingInfo")
  private lazy var getClient: GetClient? = function("MRMediaRemoteGetNowPlayingClient")
  private lazy var getPlaying: GetBool? = function("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
  private lazy var register: Register? = function("MRMediaRemoteRegisterForNowPlayingNotifications")
  private lazy var unregister: Unregister? = function(
    "MRMediaRemoteUnregisterForNowPlayingNotifications")
  private lazy var sendCommand: Send? = function("MRMediaRemoteSendCommand")
  private lazy var bundleIdentifier: ClientString? = function(
    "MRNowPlayingClientGetBundleIdentifier")
  private lazy var parentIdentifier: ClientString? = function(
    "MRNowPlayingClientGetParentAppBundleIdentifier")
  private lazy var displayName: ClientString? = function("MRNowPlayingClientGetDisplayName")
  private lazy var commandOf: InfoCommand? = function("MRMediaRemoteCommandInfoGetCommand")
  private lazy var enabledOf: InfoEnabled? = function("MRMediaRemoteCommandInfoGetEnabled")
  private lazy var optionsOf: InfoOptions? = function("MRMediaRemoteCommandInfoCopyOptions")
  private lazy var setShuffleMode: SetMode? = function("MRMediaRemoteSetShuffleMode")
  private lazy var setRepeatMode: SetMode? = function("MRMediaRemoteSetRepeatMode")
  private lazy var wantsCommandChanges: SetWants? = function(
    "MRMediaRemoteSetWantsSupportedCommandsChangedNotifications")

  private func function<T>(_ name: String) -> T? {
    guard let handle, let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
  }

  /// 框架里的一个 CFString 常量（通知名）
  private func constant(_ name: String) -> String? {
    guard let handle, let symbol = dlsym(handle, name) else { return nil }
    return symbol.assumingMemoryBound(to: CFString.self).pointee as String
  }

  // MARK: 通知

  private var observers: [NSObjectProtocol] = []

  /// 开始听三个通知（信息、在不在播、换了 App），有一个来了就调 changed；已经在听就不重复挂
  func observe(_ changed: @escaping @MainActor () -> Void) {
    guard observers.isEmpty, let register else { return }
    // 注册要传别的队列：它会在给的队列上同步等一下，在主线程上传 .main 就死锁（2026-11-13 实测，读不回来、超时也不走）。
    // 通知从那条队列发出来，下面的观察者用 queue: .main 投回主线程
    register(.global(qos: .utility))
    // 随机 / 循环换了档不动播放信息，只动「支持的命令」：要另外说一声想收它的通知
    wantsCommandChanges?(true)
    for name in [
      "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
      "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
      "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
      "kMRMediaRemoteSupportedCommandsDidChangeNotification",
    ] {
      guard let value = constant(name) else { continue }
      observers.append(
        NotificationCenter.default.addObserver(
          forName: Notification.Name(value), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { changed() } })
    }
  }

  /// 不听了（App 断开时）：观察者摘掉、MediaRemote 那边的注册也撤（私有的 Unregister，取不到就算了：没人连时 launchd 会把进程收掉）
  func stopObserving() {
    guard !observers.isEmpty else { return }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    wantsCommandChanges?(false)
    unregister?()
  }

  // MARK: 读

  /// 上一次要到的封面（按编号）：同一首不重复要、不重复缩
  private var artworkCache: (id: String, data: Data?)?

  /// 报上来的是哪个进程（从 MRNowPlayingClient 里当场取出来的字）
  private struct Client: Sendable {
    var bundleID: String
    var parentBundleID: String?
    var name: String?
  }

  /// 一份信息里用得上的几样（当场从字典里取出来）
  private struct Info: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    var timestamp: Date?
    var rate: Double?
    var artworkID: String?
    var artworkData: Data?

    init(_ info: [String: Any]) {
      title = Info.text(info["kMRMediaRemoteNowPlayingInfoTitle"])
      artist = Info.text(info["kMRMediaRemoteNowPlayingInfoArtist"])
      album = Info.text(info["kMRMediaRemoteNowPlayingInfoAlbum"])
      duration = Info.seconds(info["kMRMediaRemoteNowPlayingInfoDuration"])
      elapsed = Info.seconds(info["kMRMediaRemoteNowPlayingInfoElapsedTime"])
      timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
      rate = Info.seconds(info["kMRMediaRemoteNowPlayingInfoPlaybackRate"])
      artworkID = Info.text(info["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"])
      artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
    }

    /// 空串当没有（网页视频的专辑是空的）
    private static func text(_ value: Any?) -> String? {
      guard let text = value as? String, !text.isEmpty else { return nil }
      return text
    }

    /// 有限的非负数才算
    private static func seconds(_ value: Any?) -> Double? {
      guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number >= 0 else {
        return nil
      }
      return number
    }
  }

  /// 读一遍的结果：snapshot 是 nil = 没有在播的（或者被拦了）。sure 是 false = 有一样 1 秒没回（mediaremoted 慢了一下），
  /// 这一份信不过、别推；artworkPending = 有封面编号却没要到字节。这两种调用方过一会儿再读（稳定播放时不会再来通知）
  struct Reading {
    var snapshot: NowPlayingSnapshot?
    var sure = true
    var artworkPending = false
  }

  /// 读一遍眼下的正在播放
  func read() async -> Reading {
    guard let getInfo, let getClient, let getPlaying else { return Reading() }
    guard
      let client: Client? = await callback({ done in
        getClient(.main) { object in done(object.flatMap { self.client(from: $0) }) }
      })
    else { return Reading(sure: false) }
    guard let client else { return Reading() }
    guard let playing: Bool? = await callback({ done in getPlaying(.main) { done($0) } }),
      let info: Info? = await callback({ done in
        getInfo(.main) { done(Info($0 as? [String: Any] ?? [:])) }
      })
    else { return Reading(sure: false) }
    guard let info, let title = info.title else { return Reading() }
    let commands = await supportedCommands()
    // 15 / 26 上信息里可能只带字节、不带编号：拿字节的哈希当编号（没在这台机器上见过，宽着点）
    let artworkID =
      info.artworkID
      ?? info.artworkData.flatMap { $0.isEmpty ? nil : Self.digest($0) }
    let artwork = await artwork(id: artworkID, inline: info.artworkData)
    let snapshot = NowPlayingSnapshot(
      bundleID: client.bundleID, parentBundleID: client.parentBundleID, appName: client.name,
      title: title, artist: info.artist, album: info.album, duration: info.duration,
      elapsed: info.elapsed, timestamp: info.timestamp, rate: info.rate ?? 0,
      isPlaying: playing ?? false,
      canPrevious: commands.map { $0.enabled.contains(NowPlayingCommand.previous.rawValue) }
        ?? true,
      canNext: commands.map { $0.enabled.contains(NowPlayingCommand.next.rawValue) } ?? true,
      canSeek: commands.map { $0.enabled.contains(Self.seekCommand) } ?? true,
      shuffle: commands?.shuffle, repeatMode: commands?.repeatMode,
      artworkID: artworkID, artwork: artwork)
    return Reading(snapshot: snapshot, artworkPending: artworkID != nil && artwork == nil)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private func client(from object: AnyObject) -> Client? {
    guard let bundleID = string(bundleIdentifier, object) else { return nil }
    return Client(
      bundleID: bundleID, parentBundleID: string(parentIdentifier, object),
      name: string(displayName, object))
  }

  private func string(_ function: ClientString?, _ client: AnyObject) -> String? {
    guard let value = function?(client)?.takeUnretainedValue() as String?, !value.isEmpty else {
      return nil
    }
    return value
  }

  /// 封面：信息里带着字节就用它，没带就向 MRNowPlayingRequest 要；缩到最长边 256 的 JPEG。没有编号（网页视频刚换片）不要，
  /// 要到空的不记账（下一条通知来了再要）
  private func artwork(id: String?, inline: Data?) async -> Data? {
    guard let id else { return nil }
    if let cache = artworkCache, cache.id == id { return cache.data }
    var bytes = inline
    if bytes?.isEmpty ?? true {
      bytes =
        await request("requestNowPlayingItemArtworkOnQueue:completion:") {
          $0?.value(forKey: "imageData") as? Data
        } ?? nil
    }
    guard let bytes, !bytes.isEmpty else { return nil }
    let small = Self.shrink(bytes)
    artworkCache = (id, small)
    return small
  }

  /// 这个 App 此刻支持的命令（只算开着的），和随机 / 循环现在的档（命令 26 / 25 开着、信息里带着档才有；没有是 nil =
  /// 不显示那个按钮）
  private struct Commands: Sendable {
    var enabled: Set<Int> = []
    var shuffle: Int?
    var repeatMode: Int?
  }

  /// MRMediaRemoteCommandChangeRepeatMode / ChangeShuffleMode
  private static let repeatCommand = 25
  private static let shuffleCommand = 26

  /// 这个 App 此刻支持的命令；要不到（类、方法不在、超时）或者给了个空的是 nil = 上下首、跳都当支持
  /// （15 / 26 上它给什么没验过：宁可按钮亮着发了没反应，也不全灰掉），随机 / 循环当不支持
  private func supportedCommands() async -> Commands? {
    guard let commandOf, let enabledOf else { return nil }
    let optionsOf = optionsOf
    let shuffleKey = constant("kMRMediaRemoteCommandInfoShuffleMode")
    let repeatKey = constant("kMRMediaRemoteCommandInfoRepeatMode")
    let commands = await request("requestSupportedCommandsOnQueue:completion:") { value in
      (value as? [AnyObject]).map { list in
        var commands = Commands()
        for info in list where enabledOf(info) {
          let command = Int(commandOf(info))
          commands.enabled.insert(command)
          guard command == Self.shuffleCommand || command == Self.repeatCommand,
            let options = optionsOf?(info)?.takeRetainedValue() as? [String: Any]
          else { continue }
          if command == Self.shuffleCommand {
            commands.shuffle = Self.mode(shuffleKey.flatMap { options[$0] })
          } else {
            commands.repeatMode = Self.mode(repeatKey.flatMap { options[$0] })
          }
        }
        return commands
      }
    }
    guard let commands = commands ?? nil, !commands.enabled.isEmpty else { return nil }
    return commands
  }

  /// 随机 / 循环的档：1…3 的整数才认
  private static func mode(_ value: Any?) -> Int? {
    guard let mode = (value as? NSNumber)?.intValue, (1...3).contains(mode) else { return nil }
    return mode
  }

  /// 调 MRNowPlayingRequest 的一个「…OnQueue:completion:」方法，当场把回调的第一个值取成 Sendable 的；
  /// 外层 nil = 类、方法不在或者超时
  private func request<T: Sendable>(_ name: String, _ take: @escaping (AnyObject?) -> T?) async
    -> T??
  {
    let selector = NSSelectorFromString(name)
    guard let type = NSClassFromString("MRNowPlayingRequest") as? NSObject.Type,
      type.instancesRespond(to: selector)
    else { return nil }
    let request = type.init()
    let call = unsafeBitCast(request.method(for: selector), to: Request.self)
    return await callback { done in call(request, selector, .main) { value, _ in done(take(value)) }
    }
  }

  /// 缩到最长边 256 的 JPEG（Safari 给的是 256 KB 的 TIFF，Music 600 × 600）；解不开的丢掉
  static func shrink(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 256,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }

  // MARK: 命令

  /// 发命令（不设门槛：哪个进程都发得出去）；App 不支持的命令也返回成功，所以按钮要看快照里的 canNext / canPrevious
  func send(_ command: NowPlayingCommand) {
    _ = sendCommand?(UInt32(command.rawValue), nil)
  }

  /// MRMediaRemoteCommandSeekToPlaybackPosition：带位置（kMRMediaRemoteOptionPlaybackPosition，秒）
  private static let seekCommand = 24

  /// 跳到这一首的第几秒（同别的命令：不支持的 App 也返回成功，进度条要看快照里的 canSeek）。不是 0…上限里的有限数不发
  func seek(to seconds: Double) {
    guard seconds.isFinite, seconds >= 0, seconds <= 10_000_000,
      let key = constant("kMRMediaRemoteOptionPlaybackPosition")
    else { return }
    _ = sendCommand?(UInt32(Self.seekCommand), [key: seconds] as CFDictionary)
  }

  /// 换随机 / 循环的档（1…3）。按了之后以播放器报回来的为准（「支持的命令变了」的通知 → 再读一遍），这里不猜
  func setShuffle(_ mode: Int) {
    guard (1...3).contains(mode) else { return }
    setShuffleMode?(Int32(mode))
  }

  func setRepeat(_ mode: Int) {
    guard (1...3).contains(mode) else { return }
    setRepeatMode?(Int32(mode))
  }

  // MARK: 回调转 async

  /// 等一个带回调的调用（回调投在主队列）。外层 nil = 1 秒没回（mediaremoted 卡住时不让整个服务停在这里），和回调给的
  /// nil（真的没有）分开：超时的那一份信不过
  private func callback<T: Sendable>(_ start: (@escaping (T?) -> Void) -> Void) async -> T?? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T??, Never>) in
      let once = Once()
      start { value in
        guard once.claim() else { return }
        continuation.resume(returning: .some(value))
      }
      Task {
        try? await Task.sleep(for: .seconds(1))
        guard once.claim() else { return }
        continuation.resume(returning: .none)
      }
    }
  }
}

/// 回调和超时只认先到的那一个（都在主线程上）
@MainActor private final class Once {
  private var done = false

  func claim() -> Bool {
    defer { done = true }
    return !done
  }
}
