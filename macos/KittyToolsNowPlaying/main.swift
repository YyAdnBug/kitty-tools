// 正在播放服务（KittyToolsNowPlaying，XPC 服务，2026-11-13 刘海岛扩展第 2 期）：嵌在 App 的 Contents/XPCServices/ 里，
// bundle id 是 com.apple.kittytools.nowplaying——macOS 15.4 起 mediaremoted 只把别的 App 的播放信息给 bundle id 以
// com.apple. 开头的进程（XPC 服务认 Info.plist 的 bundle id），App 自己（com.yy.…）读不到（mac-native §2）。
// App 打开刘海岛的「正在播放」时连上来（Shell/NowPlaying.swift），launchd 按需拉起它；App 断开（关掉开关、移除插件、退出、崩了）
// 它就自己退出（detach），不指望 launchd 收。
// 它做的事：听 MediaRemote 的通知、合并 100 ms 再读一遍、和上一次不一样才推给 App；替 App 发播放 / 暂停 / 上一首 / 下一首 / 跳到某一秒 / 换随机和循环的档。
// 一次只服务一个 App（自己的那个）：新连接来了就换成它。不开沙盒、不要任何权利；没有界面，全在主线程上做。

import Foundation

@MainActor final class NowPlayingService: NSObject, NowPlayingServing {
  private let remote = MediaRemote()
  private var client: NSXPCConnection?
  /// 上一次推出去的（nil = 推过「没有在播的」）；还没推过时是 .none
  private var sent: NowPlayingSnapshot??
  private var pending: Task<Void, Never>?
  /// 这一轮补读了几次（超时、封面没要到）
  private var retries = 0

  nonisolated func subscribe(reply: @escaping @Sendable (Bool) -> Void) {
    // 调过来的那个连接（XPC 在自己的队列上调；连接只在这里拿，不从 listener 的回调里传）
    let connection = NSXPCConnection.current()
    Task { @MainActor in
      attach(connection)
      reply(remote.isAvailable)
      guard remote.isAvailable else { return }
      remote.observe { self.changed() }
      sent = .none
      changed(after: .zero)
    }
  }

  nonisolated func send(_ command: Int) {
    guard let command = NowPlayingCommand(rawValue: command) else { return }
    Task { @MainActor in remote.send(command) }
  }

  nonisolated func seek(to seconds: Double) {
    Task { @MainActor in remote.seek(to: seconds) }
  }

  /// 换档之后过一会儿再读一遍：播放器接了命令却不发「支持的命令变了」时，按钮也跟得上
  nonisolated func setShuffle(_ mode: Int) {
    Task { @MainActor in
      remote.setShuffle(mode)
      changed(after: .milliseconds(300))
    }
  }

  nonisolated func setRepeat(_ mode: Int) {
    Task { @MainActor in
      remote.setRepeat(mode)
      changed(after: .milliseconds(300))
    }
  }

  /// App 订阅了：推给它（换了连接就把旧的断掉）
  private func attach(_ connection: NSXPCConnection?) {
    guard let connection, connection !== client else { return }
    client?.invalidate()
    client = connection
  }

  /// 连接断了：是当前那个就不听了，**然后自己退出**（2026-11-14：App 里关掉「正在播放」、移除刘海岛插件后，这个进程
  /// 还一直挂着——实测 launchd 不收它，空转 0% CPU、占 15 MB、挂了几个小时）。App 再打开时连上来，launchd 按需重新拉起。
  /// 被新连接换掉的旧连接走不到这里（guard：它已经不是当前那个）
  func detach(_ id: ObjectIdentifier) {
    guard let client, ObjectIdentifier(client) == id else { return }
    self.client = nil
    pending?.cancel()
    remote.stopObserving()
    exit(0)
  }

  /// 有通知来了：合并一阵再读（一次操作 1–9 条）。读得信不过（有一样超时）就不推；它、或者有封面编号却没要到字节，
  /// 过一秒再读，一轮最多补两次——稳定播放时不会再来通知，不补就一直错着（评审 1）
  private func changed(after delay: Duration = .milliseconds(100), retry: Bool = false) {
    pending?.cancel()
    if !retry { retries = 0 }
    pending = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      let reading = await self.remote.read()
      guard !Task.isCancelled else { return }
      if reading.sure { self.push(reading.snapshot) }
      if !reading.sure || reading.artworkPending, self.retries < 2 {
        self.retries += 1
        self.changed(after: .seconds(1), retry: true)
      }
    }
  }

  /// 和上一次推的不一样才推
  private func push(_ snapshot: NowPlayingSnapshot?) {
    guard sent != .some(snapshot) else { return }
    sent = .some(snapshot)
    let data = snapshot.flatMap { try? JSONEncoder().encode($0) } ?? Data()
    (client?.remoteObjectProxy as? NowPlayingListening)?.update(data)
  }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
  let service: NowPlayingService

  init(service: NowPlayingService) {
    self.service = service
  }

  nonisolated func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: NowPlayingServing.self)
    connection.exportedObject = service
    connection.remoteObjectInterface = NSXPCInterface(with: NowPlayingListening.self)
    let service = service
    let id = ObjectIdentifier(connection)
    connection.invalidationHandler = { Task { @MainActor in service.detach(id) } }
    connection.interruptionHandler = { Task { @MainActor in service.detach(id) } }
    connection.resume()
    return true
  }
}

let delegate = ServiceDelegate(service: NowPlayingService())
let listener = NSXPCListener.service()
listener.delegate = delegate
// 不返回：系统的 xpc_main 接管，主队列照常转
listener.resume()
