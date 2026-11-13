// 刘海岛的「正在播放」（2026-11-13 刘海岛扩展第 2 期，拍板 E1 E2；归属：刘海岛插件里一组、默认关）。
// 读系统的正在播放要 bundle id 以 com.apple. 开头（macOS 15.4 起），App 自己读不到：读和发命令都在包里的 XPC 服务
// KittyToolsNowPlaying（bundle id com.apple.kittytools.nowplaying，mac-native §2），这里只连它、收它推来的快照、替按钮发命令。
// 打开（刘海岛插件添加着 + 设置 › 刘海岛「正在播放」开着）才连；关掉就断开，launchd 把服务收掉。服务崩了（连接中断）过一秒
// 再订一次（发消息就会被重新拉起）。
// 快照 → 刘海岛上的一个活动（Island.Activity，类别 .media 最低）：在播时上耳朵（封面 + 跳动条）；从在播变成暂停后耳朵上
// 再留 pausedLinger，之后只在那一张里列着；没有在播的了（App 退了）活动结束。读到的歌名不进日志、不进提示的记录。
// 退路（服务读不到时 Music / Spotify 用 AppleScript）是第 2-3 批。

import AppKit
import OSLog

@MainActor final class NowPlaying: NSObject, NowPlayingListening {
  static let serviceName = "com.apple.kittytools.nowplaying"
  static let activityID = "nowPlaying"
  /// 从在播变成暂停后耳朵上还留多久（暂停接个电话再接着放，耳朵不来回跳）
  static let pausedLinger = Duration.seconds(30)

  private weak var island: Island?
  private let defaults: UserDefaults
  private var connection: NSXPCConnection?
  private var snapshot: NowPlayingSnapshot?
  /// 解好的封面（按编号）：同一首不重复解
  private var artwork: (id: String, image: NSImage)?
  /// 放歌那个 App 的图标（按 bundle id 记一份）：没有封面时顶上
  private var appIcon: (bundleID: String, image: NSImage?)?
  /// 从在播变成暂停的那一刻（一直没在播过的是 nil：一打开就是暂停着的不上耳朵）
  private var pausedSince: ContinuousClock.Instant?
  private var linger: Task<Void, Never>?

  init(island: Island, defaults: UserDefaults = .standard) {
    self.island = island
    self.defaults = defaults
  }

  /// 照偏好连 / 断（启动时、偏好变了时 AppDelegate 调）：没变不动
  func apply() {
    let added =
      defaults.object(forKey: Feature.island.prefsKey) as? Bool ?? Feature.island.defaultOn
    let wanted = added && defaults.bool(forKey: Prefs.islandNowPlaying)
    if wanted, connection == nil {
      connect()
    } else if !wanted, connection != nil {
      disconnect()
    }
  }

  // MARK: 连接

  private func connect() {
    let connection = NSXPCConnection(serviceName: Self.serviceName)
    connection.remoteObjectInterface = NSXPCInterface(with: NowPlayingServing.self)
    connection.exportedInterface = NSXPCInterface(with: NowPlayingListening.self)
    connection.exportedObject = self
    // 只认这一条连接的回调：断开又马上连上时，旧连接晚到的「断了」不能把新的清掉（评审 2）
    let id = ObjectIdentifier(connection)
    // 服务崩了：连接还在，先清掉崩之前那一份（连着崩时不一直挂着旧的），过一秒再订一次（发消息会把它重新拉起来）
    connection.interruptionHandler = { [weak self] in
      Task { @MainActor in
        guard let self, self.isCurrent(id) else { return }
        self.clear()
        try? await Task.sleep(for: .seconds(1))
        if self.isCurrent(id) { self.subscribe() }
      }
    }
    // 断了（自己断的、服务找不到）：清掉，偏好下次变时 apply 再连
    connection.invalidationHandler = { [weak self] in
      Task { @MainActor in
        guard let self, self.isCurrent(id) else { return }
        self.connection = nil
        self.clear()
      }
    }
    connection.resume()
    self.connection = connection
    subscribe()
  }

  private func subscribe() {
    guard let proxy = proxy() else { return }
    proxy.subscribe { available in
      if !available { Log.nowPlaying.error("服务里取不到 MediaRemote 的函数") }
    }
  }

  private func proxy() -> NowPlayingServing? {
    connection?.remoteObjectProxyWithErrorHandler { error in
      Log.nowPlaying.error("正在播放服务：\(error.localizedDescription, privacy: .public)")
    } as? NowPlayingServing
  }

  private func isCurrent(_ id: ObjectIdentifier) -> Bool {
    connection.map { ObjectIdentifier($0) == id } ?? false
  }

  private func disconnect() {
    connection?.invalidate()
    connection = nil
    clear()
  }

  private func clear() {
    snapshot = nil
    pausedSince = nil
    linger?.cancel()
    island?.endActivity(Self.activityID)
  }

  // MARK: 收快照

  nonisolated func update(_ data: Data) {
    // XPC 在自己的队列上调过来：解好再回主线程
    let snapshot = data.isEmpty ? nil : Self.decode(data)
    guard data.isEmpty || snapshot != nil else { return }
    Task { @MainActor in self.received(snapshot) }
  }

  private func received(_ next: NowPlayingSnapshot?) {
    // 断开之后才到的不算
    guard connection != nil else { return }
    let wasPlaying = snapshot?.isPlaying ?? false
    snapshot = next
    if let next, !next.isPlaying, wasPlaying {
      pausedSince = .now
      lingerLater()
    } else if next?.isPlaying ?? true {
      // 在播了，或者 App 退了（之后换上一个一直暂停着的 App 不借这次的暂停时刻，评审 4）
      pausedSince = nil
      linger?.cancel()
    }
    render()
  }

  /// 暂停满 pausedLinger 时再画一次（耳朵收回去）
  private func lingerLater() {
    linger?.cancel()
    linger = Task { [weak self] in
      try? await Task.sleep(for: Self.pausedLinger)
      if !Task.isCancelled { self?.render() }
    }
  }

  private func render() {
    guard let island else { return }
    guard let snapshot else { return island.endActivity(Self.activityID) }
    if let id = snapshot.artworkID, let data = snapshot.artwork, artwork?.id != id,
      let image = NSImage(data: data)
    {
      artwork = (id, image)
    }
    let image =
      snapshot.artworkID != nil && snapshot.artworkID == artwork?.id ? artwork?.image : nil
    island.setActivity(
      Island.Activity(
        id: Self.activityID, kind: .media, title: snapshot.title, detail: snapshot.artist,
        symbol: "music.note", tone: .info,
        media: Island.Media(
          snapshot: snapshot, artwork: image, appIcon: icon(for: snapshot),
          send: { [weak self] in self?.send($0) }, open: { [weak self] in self?.openApp() }),
        onWings: Self.showsOnWings(
          isPlaying: snapshot.isPlaying, pausedFor: pausedSince.map { .now - $0 })))
  }

  /// 放歌那个 App 的图标（Safari 的报的是 WebKit 的进程，按上级 App 找）；找不到是 nil
  private func icon(for snapshot: NowPlayingSnapshot) -> NSImage? {
    let bundleID = snapshot.parentBundleID ?? snapshot.bundleID
    if let appIcon, appIcon.bundleID == bundleID { return appIcon.image }
    let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
      NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false))
    }
    appIcon = (bundleID, image)
    return image
  }

  // MARK: 按钮

  private func send(_ command: NowPlayingCommand) {
    proxy()?.send(command.rawValue)
  }

  /// 切到放歌的那个 App（Safari 的报的是 WebKit 的进程，按上级 App 找）。岛是不激活本 App 的面板：后台调
  /// NSRunningApplication.activate 系统可以不理、窗口关着时也叫不回窗口，所以同程序坞那几处走「打开这个 App」
  private func openApp() {
    guard let snapshot,
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: snapshot.parentBundleID ?? snapshot.bundleID)
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }

  // MARK: 纯函数（单测锁住）

  /// 上不上耳朵：在播；或者从在播变成暂停还不到 pausedLinger。一打开就是暂停着的（pausedFor 是 nil）不上
  static func showsOnWings(isPlaying: Bool, pausedFor: Duration?) -> Bool {
    if isPlaying { return true }
    guard let pausedFor else { return false }
    return pausedFor < pausedLinger
  }

  /// 此刻播到哪（秒）：timestamp 那一刻在 elapsed，在播且速率大于 0 才往前走（缓冲时播放器报在播、速率 0）；
  /// 不超过时长、不小于 0。没有进度的是 nil
  static func position(_ snapshot: NowPlayingSnapshot, at now: Date) -> Double? {
    guard var position = snapshot.elapsed else { return nil }
    if snapshot.isPlaying, snapshot.rate > 0, let timestamp = snapshot.timestamp {
      position += now.timeIntervalSince(timestamp) * snapshot.rate
    }
    if let duration = snapshot.duration, duration > 0 { position = min(position, duration) }
    return max(position, 0)
  }

  /// 时长、进度最多信这么多秒（约 116 天；网页能用 Media Session 报 1e20 这种，换成整数就闪退）、速率最多这么快
  nonisolated static let maxSeconds: Double = 10_000_000
  nonisolated static let maxRate: Double = 100

  /// 解服务推来的 JSON：解不开的丢掉；字截短（标题、艺人最多 200 个字）、封面超过 1 MB 不要、时长进度不是
  /// 0…maxSeconds 里的有限数不要、速率夹到 0…maxRate
  nonisolated static func decode(_ data: Data) -> NowPlayingSnapshot? {
    guard var snapshot = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data),
      !snapshot.title.isEmpty, !snapshot.bundleID.isEmpty
    else { return nil }
    snapshot.title = String(snapshot.title.prefix(200))
    snapshot.artist = snapshot.artist.map { String($0.prefix(200)) }
    snapshot.album = snapshot.album.map { String($0.prefix(200)) }
    if (snapshot.artwork?.count ?? 0) > 1 << 20 { snapshot.artwork = nil }
    let valid = { (value: Double?) in
      value.flatMap { $0.isFinite && $0 >= 0 && $0 <= maxSeconds ? $0 : nil }
    }
    snapshot.duration = valid(snapshot.duration)
    snapshot.elapsed = valid(snapshot.elapsed)
    snapshot.rate = snapshot.rate.isFinite ? min(max(snapshot.rate, 0), maxRate) : 0
    return snapshot
  }
}
