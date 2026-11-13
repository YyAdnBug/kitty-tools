// 刘海岛的「正在播放」（2026-11-13 刘海岛扩展第 2 期，拍板 E1 E2；归属：刘海岛插件里一组、默认关）。
// 读系统的正在播放要 bundle id 以 com.apple. 开头（macOS 15.4 起），App 自己读不到：读和发命令都在包里的 XPC 服务
// KittyToolsNowPlaying（bundle id com.apple.kittytools.nowplaying，mac-native §2），这里只连它、收它推来的快照、替按钮发命令。
// 打开（刘海岛插件添加着 + 设置 › 刘海岛「正在播放」开着）才连；关掉就断开，launchd 把服务收掉。服务崩了（连接中断）过一秒
// 再订一次（发消息就会被重新拉起）。
// 快照 → 刘海岛上的一个活动（Island.Activity，类别 .media 最低）：在播时上耳朵（封面 + 跳动条）；从在播变成暂停后耳朵上
// 再留 pausedLinger，之后只在那一张里列着；没有在播的了（App 退了）活动结束。读到的歌名不进日志、不进提示的记录。
// 退路（第 2-3 批，NowPlayingFallback.swift）：开着时一直听音乐 / Spotify 的分布式通知（不要授权）；服务说取不到 MediaRemote、
// 连不上服务（找不到、拉不起来）、或者它们说在播而服务 2 秒都报不出正在播放，就改用它们的通知（服务又报出来了就换回去）。
// 按钮照旧交给服务发（发命令不设门槛）；服务整个不能用时走 AppleScript。
// 进度条能拖（2026-11-13）：跳到某一秒也交给服务发；发完岛上当场当它已经在那儿（Hold），播放器报回新进度或者过了
// holdTime 就撤——不然松手那一下进度条闪回旧位置。

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
  /// 打开着（插件添加着、开关开着）。和连没连着分开：服务找不到时连接断了，退路照样要用
  private var isOn = false
  /// 岛上用的那一份：服务推来的，或者退路里挑的
  private var snapshot: NowPlayingSnapshot?
  /// 服务推来的最近一份（nil = 它说没有在播的）
  private var served: NowPlayingSnapshot?
  /// 服务里取不取得到 MediaRemote（订阅的回话；还没回是 nil）
  private var available: Bool?
  /// 退路：音乐 / Spotify 的分布式通知各留最近一份；用没用退路；「2 秒后再看」；读音乐进度的那一次
  private var notices: [String: (snapshot: NowPlayingSnapshot, at: Date)] = [:]
  private var listensToPlayers = false
  /// 播放器退出（崩了、强制退出时它不会发「停了」）的监听
  private var quitObserver: NSObjectProtocol?
  private var usesFallback = false
  private var fallbackCheck: Task<Void, Never>?
  private var positionRead: Task<Void, Never>?
  /// 解好的封面（按编号）和它的主色：同一首不重复解、不重复算
  private var artwork: (id: String, image: NSImage, tint: NSColor?)?
  /// 放歌那个 App 的图标（按 bundle id 记一份）：没有封面时顶上
  private var appIcon: (bundleID: String, image: NSImage?)?
  /// 从在播变成暂停的那一刻（一直没在播过的是 nil：一打开就是暂停着的不上耳朵）
  private var pausedSince: ContinuousClock.Instant?
  private var linger: Task<Void, Never>?
  /// 刚跳过、播放器还没报回新进度：岛上先顶着的那个位置；到点撤掉
  private var hold: Hold?
  private var holdExpiry: Task<Void, Never>?

  /// 连哪个服务（单测给一个不存在的名字，走「连不上 → 退路」）
  private let serviceName: String

  init(
    island: Island, defaults: UserDefaults = .standard, serviceName: String = NowPlaying.serviceName
  ) {
    self.island = island
    self.defaults = defaults
    self.serviceName = serviceName
  }

  /// 照偏好连 / 断（启动时、偏好变了时 AppDelegate 调）：没变不动
  func apply() {
    let added =
      defaults.object(forKey: Feature.island.prefsKey) as? Bool ?? Feature.island.defaultOn
    let wanted = added && defaults.bool(forKey: Prefs.islandNowPlaying)
    if wanted, !isOn {
      isOn = true
      connect()
      listenToPlayers()
    } else if !wanted, isOn {
      isOn = false
      disconnect()
    }
  }

  // MARK: 连接

  private func connect() {
    let connection = NSXPCConnection(serviceName: serviceName)
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
        // 已经在用退路的：照样挂着播放器那一份（不等下一条通知，评审 4）
        self.refresh()
        try? await Task.sleep(for: .seconds(1))
        if self.isCurrent(id) { self.subscribe() }
      }
    }
    // 断了、又不是自己断的（服务找不到、拉不起来）：当它取不到 MediaRemote，改用退路；不重连（关掉再打开时重连）
    connection.invalidationHandler = { [weak self] in
      Task { @MainActor in
        guard let self, self.isCurrent(id) else { return }
        Log.nowPlaying.error("连不上正在播放服务，改用音乐 / Spotify 自己的通知")
        self.connection = nil
        self.clear()
        self.serviceAnswered(false)
        self.refresh()
      }
    }
    connection.resume()
    self.connection = connection
    subscribe()
  }

  private func subscribe() {
    guard let proxy = proxy() else { return }
    proxy.subscribe { [weak self] available in
      if !available { Log.nowPlaying.error("服务里取不到 MediaRemote 的函数") }
      Task { @MainActor in self?.serviceAnswered(available) }
    }
  }

  /// 服务回了话（或者连不上）：取不到 MediaRemote 就直接用退路
  private func serviceAnswered(_ available: Bool) {
    guard isOn else { return }
    self.available = available
    if !available, !usesFallback {
      usesFallback = true
      refresh()
    }
  }

  private func proxy() -> NowPlayingServing? {
    // 出错的回调在 XPC 自己的队列上调：SDK 里它的类型没标 Sendable，不写 @Sendable 就继承主线程隔离，
    // 一来就触发执行器断言闪退（2026-11-13 单测 missingServiceFallsBackToPlayers 抓到的：服务找不到时必来）
    connection?.remoteObjectProxyWithErrorHandler { @Sendable error in
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
    if listensToPlayers {
      for player in NowPlayingFallback.notices {
        DistributedNotificationCenter.default().removeObserver(
          self, name: Notification.Name(player.name), object: nil)
      }
      listensToPlayers = false
    }
    if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
    quitObserver = nil
    notices = [:]
    usesFallback = false
    available = nil
  }

  /// 清掉服务那一份和岛上的（断开、服务崩了）；退路的通知留着（播放器那边没变）
  private func clear() {
    snapshot = nil
    served = nil
    pausedSince = nil
    linger?.cancel()
    fallbackCheck?.cancel()
    positionRead?.cancel()
    positionRead = nil
    holdExpiry?.cancel()
    hold = nil
    island?.endActivity(Self.activityID)
  }

  // MARK: 退路

  /// 听音乐 / Spotify 状态一变就发的分布式通知（不要授权）。**要 .deliverImmediately**：默认的写法在本 App 不在前台时
  /// 被系统压着、等下次激活才送到（SDK 头文件写明，评审 1 本机实测）——本 App 几乎从不在前台，退路就等于没有。
  /// 播放器崩了、被强制退出时不会发「停了」：另听 App 退出，清掉它那一份
  private func listenToPlayers() {
    guard !listensToPlayers else { return }
    listensToPlayers = true
    for player in NowPlayingFallback.notices {
      DistributedNotificationCenter.default().addObserver(
        self, selector: #selector(playerChanged(_:)), name: Notification.Name(player.name),
        object: nil, suspensionBehavior: .deliverImmediately)
    }
    quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      guard let bundleID = app?.bundleIdentifier else { return }
      MainActor.assumeIsolated {
        guard let self, self.notices[bundleID] != nil else { return }
        self.noticed(bundleID, nil)
      }
    }
  }

  /// 分布式通知在注册它的线程（主线程）的 run loop 上送到：就地解成快照（Sendable 的）再交给主线程那边
  @objc nonisolated private func playerChanged(_ note: Notification) {
    guard let player = NowPlayingFallback.notices.first(where: { $0.name == note.name.rawValue })
    else { return }
    let snapshot = NowPlayingFallback.snapshot(
      bundleID: player.bundleID, appName: player.appName, info: note.userInfo ?? [:], now: .now)
    MainActor.assumeIsolated { self.noticed(player.bundleID, snapshot) }
  }

  /// 播放器的通知解出来了（不是 private：单测直接喂，不往全系统发假的「音乐」通知）
  func noticed(_ bundleID: String, _ snapshot: NowPlayingSnapshot?) {
    guard isOn else { return }
    notices[bundleID] = snapshot.map { ($0, .now) }
    if usesFallback {
      refresh()
    } else if snapshot?.isPlaying ?? false, served == nil {
      // 播放器说在播、服务没报出来：等一会儿还是这样就算服务读不到了（服务的通知 15–32 ms 就到）
      fallbackCheck?.cancel()
      fallbackCheck = Task { [weak self] in
        try? await Task.sleep(for: NowPlayingFallback.grace)
        guard let self, !Task.isCancelled, self.served == nil,
          self.notices.values.contains(where: \.snapshot.isPlaying)
        else { return }
        Log.nowPlaying.error("正在播放服务读不到，改用音乐 / Spotify 自己的通知")
        self.usesFallback = true
        self.refresh()
      }
    }
  }

  /// 退路里的音乐没有进度：已经允许过控制「音乐」时读一次（同一首读过就不读）。again：刚跳过，过一会儿再读一遍盖上去——
  /// 音乐跳了不发通知，岛上那个位置是自己猜的（命令到没到、授权框停了多久都不知道）
  private func readMusicPosition(again: Bool = false) {
    guard usesFallback, let current = snapshot, current.bundleID == "com.apple.Music",
      again || (current.elapsed == nil && positionRead == nil)
    else { return }
    positionRead?.cancel()
    positionRead = Task { [weak self] in
      if again { try? await Task.sleep(for: .milliseconds(300)) }
      guard !Task.isCancelled else { return }
      let seconds = await NowPlayingFallback.musicPosition()
      guard let self, !Task.isCancelled else { return }
      self.positionRead = nil
      // 读不到（没允许过、它没在运行）就算了，不再读
      guard let seconds else { return }
      // 读的时候换了歌：给新的那首再读一次（评审 5）
      guard var notice = self.notices["com.apple.Music"], notice.snapshot.title == current.title
      else { return self.readMusicPosition() }
      notice.snapshot.elapsed = seconds
      notice.snapshot.timestamp = .now
      self.notices["com.apple.Music"] = notice
      self.refresh()
    }
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
    guard isOn, connection != nil else { return }
    served = next
    // 服务又报得出来了：不用退路
    if next != nil {
      usesFallback = false
      fallbackCheck?.cancel()
    }
    refresh()
  }

  /// 岛上该用哪一份（服务的，或者退路里挑的）换上去
  private func refresh() {
    show(
      Self.holding(
        hold,
        over: Self.effective(
          served: served, usesFallback: usesFallback, notices: Array(notices.values)),
        now: .now))
    readMusicPosition()
  }

  private func show(_ next: NowPlayingSnapshot?) {
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
      artwork = (id, image, ArtworkTint.color(of: image))
    }
    let current = snapshot.artworkID != nil && snapshot.artworkID == artwork?.id ? artwork : nil
    island.setActivity(
      Island.Activity(
        id: Self.activityID, kind: .media, title: snapshot.title, detail: snapshot.artist,
        symbol: "music.note", tone: .info,
        media: Island.Media(
          snapshot: snapshot, artwork: current?.image, tint: current?.tint,
          appIcon: icon(for: snapshot),
          send: { [weak self] in self?.send($0) }, seek: { [weak self] in self?.seek(to: $0) },
          open: { [weak self] in self?.openApp() }),
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

  /// 服务能用就交给它发（读不到时发命令多半还行）；整个不能用时，退路的音乐 / Spotify 走 AppleScript
  private func send(_ command: NowPlayingCommand) {
    if available != false, let proxy = proxy() { return proxy.send(command.rawValue) }
    guard let player = scriptable(snapshot) else { return }
    let island = island
    Task {
      await NowPlayingFallback.run(
        NowPlayingFallback.script(command, bundleID: player.bundleID), appName: player.appName,
        island: island)
    }
  }

  /// AppleScript 只对退路认识的那两个播放器跑：脚本里拼的是这里的常量，不是快照里的字
  private func scriptable(_ snapshot: NowPlayingSnapshot?) -> (bundleID: String, appName: String)? {
    NowPlayingFallback.notices.first { $0.bundleID == snapshot?.bundleID }.map {
      ($0.bundleID, $0.appName)
    }
  }

  /// 跳到这一首的第几秒（进度条拖完、点了一下、读屏调）：同按钮，服务能用就交给它发，整个不能用时音乐 / Spotify 走
  /// AppleScript。岛上当它已经在那儿：
  /// - 服务报的那一份：先顶着（Hold），播放器报回跳到的位置附近、换了歌或者到点就撤
  /// - 退路里的那一份（播放器自己的通知）：直接改——音乐跳了不发通知，没有别的来源会来纠正。走 AppleScript 的等脚本
  ///   跑成了才改（没授权、点了「不允许」就不改）；音乐另外过一会儿读一遍真的位置盖上去
  private func seek(to seconds: Double) {
    guard let current = snapshot, let target = Self.seekTarget(seconds, in: current) else { return }
    if available != false, let proxy = proxy() {
      proxy.seek(to: target)
      if let served {
        hold = Hold(position: target, at: .now, title: served.title)
        holdExpiry?.cancel()
        holdExpiry = Task { [weak self] in
          try? await Task.sleep(for: .seconds(Self.holdTime))
          guard let self, !Task.isCancelled else { return }
          self.hold = nil
          self.refresh()
        }
        refresh()
      } else {
        sought(target, in: current)
      }
      return
    }
    guard let player = scriptable(current) else { return }
    let island = island
    Task { [weak self] in
      let done = await NowPlayingFallback.run(
        NowPlayingFallback.seekScript(target, bundleID: player.bundleID),
        appName: player.appName, island: island)
      if done { self?.sought(target, in: current) }
    }
  }

  /// 退路里的那一份跳到了 target：还是那一首就把它的进度改成「此刻在 target」
  private func sought(_ target: Double, in current: NowPlayingSnapshot) {
    guard isOn, var notice = notices[current.bundleID], notice.snapshot.title == current.title
    else { return }
    notice.snapshot.elapsed = target
    notice.snapshot.timestamp = .now
    notices[current.bundleID] = notice
    refresh()
    readMusicPosition(again: true)
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

  /// 岛上用哪一份：服务报得出来就用服务的；报不出来、又在用退路时，从播放器自己的通知里挑
  static func effective(
    served: NowPlayingSnapshot?, usesFallback: Bool,
    notices: [(snapshot: NowPlayingSnapshot, at: Date)]
  ) -> NowPlayingSnapshot? {
    if let served { return served }
    return usesFallback ? NowPlayingFallback.pick(notices) : nil
  }

  /// 进度条上要跳到的秒数夹进这一首里；跳不了（这个 App 不支持、没有时长、不是有限数）是 nil
  static func seekTarget(_ seconds: Double, in snapshot: NowPlayingSnapshot) -> Double? {
    guard snapshot.canSeek, let duration = snapshot.duration, duration > 0, seconds.isFinite
    else { return nil }
    return min(max(seconds, 0), duration)
  }

  /// 读屏调进度条一下挪多少秒：时长的 5%，至少 5 秒
  static func seekStep(duration: Double) -> Double { max(duration * 0.05, 5) }

  /// 刚跳过的那一下：at 那一刻把 title 这一首跳到了 position
  struct Hold: Equatable {
    var position: Double
    var at: Date
    var title: String
  }

  /// 跳过之后最多顶多久（服务的通知 7–141 ms 就到；到点还没报到跳到的位置 = 播放器没理这条命令，照它报的画）
  static let holdTime: TimeInterval = 2
  /// 播放器报的位置离跳到的位置这么近就算报回来了（网页视频会吸到关键帧上，差一点）
  static let holdTolerance: Double = 1.5

  /// 刚跳过、还没过 holdTime、还是那一首，而播放器报的位置还不在跳到的位置附近：当它已经在跳到的位置（之后照常
  /// 按速率往前走）。「附近」而不是「进度变了就撤」：一次操作来好几条通知，先到的可能是旧位置配新的时间戳（评审 2），
  /// 照它画就闪回去了。播放器报到了附近、换了歌、到点了，都照原样
  static func holding(_ hold: Hold?, over snapshot: NowPlayingSnapshot?, now: Date)
    -> NowPlayingSnapshot?
  {
    guard let hold, let reported = snapshot, now.timeIntervalSince(hold.at) < holdTime,
      reported.title == hold.title
    else { return snapshot }
    var held = reported
    held.elapsed = hold.position
    held.timestamp = hold.at
    if let real = position(reported, at: now), let expected = position(held, at: now),
      abs(real - expected) <= holdTolerance
    {
      return reported
    }
    return held
  }

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
