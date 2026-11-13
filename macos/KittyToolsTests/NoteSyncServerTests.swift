// 连 WebDAV 服务器同步（Notes/NoteSyncServer.swift + NoteSyncer 里连服务器那几处，issue #18）：一个假服务器（FakeDAV：
// 拦下发往 *.kitty-fake.test 的请求，一个临时文件夹当服务器上的 /dav/，真读真写），两台「电脑」（真的 NoteStore、临时
// 偏好域、各自的镜像目录；密码存在内存里，不碰钥匙串）——连上（没有的文件夹建好、有库的接着用、不往放着别的东西的文件夹里
// 撒子文件夹、密码不对说清楚）、便签和片段来回传、一台连服务器一台直接用那个文件夹也能合、图片上传下载（不留临时文件）、
// 没变的文件不再拿、一轮的请求数用完了下一轮接着传 / 接着拿、服务器说请求太多就退避、连不上停在这一轮、停止同步清掉密码和镜像。
// 都在临时目录、临时偏好域里，用完删；不碰真实的数据目录、偏好、钥匙串。

import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

@MainActor
struct NoteSyncServerTests {
  private let root = FileManager.default.temporaryDirectory.appending(
    path: "kitty-webdav-\(UUID().uuidString)", directoryHint: .isDirectory)
  /// 假服务器上 /dav/ 底下的东西
  private var served: URL { root.appending(path: "服务器", directoryHint: .isDirectory) }
  /// 同步的那个文件夹（服务器上的 /dav/同步/）
  private var shared: URL { served.appending(path: "同步", directoryHint: .isDirectory) }

  /// 一台电脑：便签、片段（同一个内存库）、偏好域、同步（镜像在它自己的临时目录里）
  private final class Mac {
    let store: NoteStore
    let syncer: NoteSyncer
    let suite: String
    let defaults: UserDefaults
    let clipboard: ClipboardStore
    /// 「钥匙串」里的密码
    var password: String?

    init(host: String, root: URL, session: URLSession) throws {
      let db = try Database(path: ":memory:", wal: false)
      store = try NoteStore(db: db, wait: { _ in }, host: host)
      store.images = NoteImageStore(directory: root.appending(path: "图片-\(host)"))
      suite = "kitty-webdav-tests-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suite)!
      syncer = NoteSyncer(
        store: store, defaults: defaults, mirrors: root.appending(path: "镜像-\(host)"))
      clipboard = try ClipboardStore(
        db: try Database(path: ":memory:"),
        images: ImageStore(directory: root.appending(path: "剪贴板图片-\(host)")))
      syncer.session = session
      syncer.sources = [clipboard]
      syncer.computerName = { host }
      syncer.editing = { [] }
      syncer.loadPassword = { [unowned self] in password }
      syncer.savePassword = { [unowned self] in password = $0 }
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
  }

  private func makeServer() throws -> String {
    try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
    return FakeDAV.add(root: served)
  }

  private func account(_ host: String, password: String = FakeDAV.password) -> WebDAV.Account {
    WebDAV.Account(
      folder: WebDAV.folder(address: "http://\(host)/dav", path: "同步")!, user: FakeDAV.user,
      password: password)
  }

  private func cleanUp(_ host: String) {
    FakeDAV.remove(host)
    try? FileManager.default.removeItem(at: root)
  }

  private func settle(_ macs: [Mac], times: Int = 2) async {
    for _ in 0..<times {
      for mac in macs { await mac.syncer.round() }
    }
  }

  private func bodies(_ mac: Mac) -> Set<String> { Set(mac.store.notes.map(\.body)) }

  private func snippets(_ mac: Mac) -> Set<String> {
    Set(mac.clipboard.items.filter(\.isSnippet).compactMap(\.text))
  }

  // MARK: 连上、来回传

  /// 服务器上没有那个文件夹：建好、写标记；另一台接着同一个库；便签、片段、改动来回传；镜像在各自的目录里，密码只进「钥匙串」
  @Test func notesTravelThroughServer() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let session = FakeDAV.session()
    let a = try Mac(host: "a", root: root, session: session)
    let b = try Mac(host: "b", root: root, session: session)
    let note = a.store.create(body: "A 写的", now: .now)
    a.clipboard.saveSnippet("A 的片段")
    #expect(await a.syncer.enable(server: account(host)) == nil)
    #expect(a.password == FakeDAV.password)
    #expect(a.defaults.string(forKey: Prefs.syncServer) == account(host).folder.absoluteString)
    #expect(a.syncer.server == account(host).folder && a.syncer.serverUser == FakeDAV.user)
    await a.syncer.round()
    #expect(a.syncer.status == .idle && a.syncer.uploading == 0)
    #expect(
      FileManager.default.fileExists(atPath: shared.appending(path: NoteSyncFolder.markerName).path)
    )
    #expect(
      FileManager.default.fileExists(
        atPath: shared.appending(path: "devices/\(a.store.deviceID)/device.json").path))
    let mirror = try #require(a.syncer.folder)
    #expect(mirror.path.hasPrefix(root.appending(path: "镜像-a").path))

    #expect(await b.syncer.enable(server: account(host)) == nil)
    #expect(b.syncer.library == a.syncer.library)
    b.store.create(body: "B 写的", now: .now)
    await settle([b, a])
    #expect(bodies(a) == ["A 写的", "B 写的"] && bodies(b) == bodies(a))
    #expect(snippets(b) == ["A 的片段"])
    #expect(b.syncer.peers.map(\.name) == ["a"])

    a.store.setBody("A 改过", of: note.id, now: .now.addingTimeInterval(5))
    await settle([a, b])
    #expect(bodies(b) == ["A 改过", "B 写的"])
    #expect(a.syncer.status == .idle && b.syncer.status == .idle)
  }

  /// 一台连服务器、一台直接用服务器上的那个文件夹（同步盘那样）：写法一样，合得到一起
  @Test func serverAndFolderMix() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let session = FakeDAV.session()
    let a = try Mac(host: "a", root: root, session: session)
    let b = try Mac(host: "b", root: root, session: session)
    a.store.create(body: "连服务器的", now: .now)
    #expect(await a.syncer.enable(server: account(host)) == nil)
    await a.syncer.round()
    b.store.create(body: "用文件夹的", now: .now)
    #expect(await b.syncer.enable(folder: shared) == nil)
    #expect(b.syncer.library == a.syncer.library)
    await settle([b, a])
    #expect(bodies(a) == ["连服务器的", "用文件夹的"] && bodies(b) == bodies(a))
  }

  /// 图片：本机的传上去（先传临时名再改名，不留临时文件）、对面拿下来；对面已经有的同名图不再下载
  @Test func imagesTravelThroughServer() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let session = FakeDAV.session()
    let a = try Mac(host: "a", root: root, session: session)
    let b = try Mac(host: "b", root: root, session: session)
    let stored = try await NoteImageStore.store(
      data: NoteImageFixture.data(type: .png, width: 40, height: 30),
      in: try #require(a.store.images).directory
    ).get()
    a.store.create(body: "图 \(NoteImages.token(stored.image))", now: .now)
    for mac in [a, b] { #expect(await mac.syncer.enable(server: account(host)) == nil) }
    await settle([a, b])
    let name = "\(stored.image.id.uuidString).png"
    let images = try FileManager.default.contentsOfDirectory(
      atPath: shared.appending(path: "images").path)
    #expect(images == [name])
    #expect(b.store.images?.fileNames() == [name])
    // 只有 b 拿过一次：a 本机有这张，镜像里是克隆的
    #expect(FakeDAV.log(host).filter { $0 == "GET /同步/images/\(name)" }.count == 1)
  }

  /// 永久删掉的：服务器上自己子文件夹里那个文件也删掉，另一台跟着删
  @Test func erasedNotesLeaveTheServer() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let session = FakeDAV.session()
    let a = try Mac(host: "a", root: root, session: session)
    let b = try Mac(host: "b", root: root, session: session)
    let note = a.store.create(body: "要删的", now: .now)
    for mac in [a, b] { #expect(await mac.syncer.enable(server: account(host)) == nil) }
    await settle([a, b])
    #expect(bodies(b) == ["要删的"])
    a.store.erase(note.id, now: .now.addingTimeInterval(5))
    await settle([a, b])
    #expect(
      !FileManager.default.fileExists(
        atPath: shared.appending(
          path: "devices/\(a.store.deviceID)/notes/\(NoteSyncFolder.fileName(of: note.id))"
        ).path))
    #expect(b.store.note(note.id) == nil)
  }

  // MARK: 请求数

  /// 什么都没变的一轮：只列目录，不 GET、不 PUT
  @Test func unchangedFilesAreNotFetchedAgain() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let session = FakeDAV.session()
    let a = try Mac(host: "a", root: root, session: session)
    let b = try Mac(host: "b", root: root, session: session)
    for index in 0..<5 { a.store.create(body: "第 \(index) 条", now: .now) }
    for mac in [a, b] { #expect(await mac.syncer.enable(server: account(host)) == nil) }
    await settle([a, b], times: 3)
    FakeDAV.clearLog(host)
    await settle([a, b])
    let log = FakeDAV.log(host)
    #expect(!log.isEmpty && log.allSatisfy { $0.hasPrefix("PROPFIND") })
    #expect(a.syncer.status == .idle && b.syncer.status == .idle)
  }

  /// 一轮的请求数用完了：没传上去的下一轮接着传（device.json 最后），没拿下来的下一轮接着拿；中间状态行有数
  @Test func budgetSpreadsOverRounds() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let session = FakeDAV.session()
    let a = try Mac(host: "a", root: root, session: session)
    let b = try Mac(host: "b", root: root, session: session)
    let count = NoteSyncServer.budget + 15
    for index in 0..<count { a.store.create(body: "第 \(index) 条", now: .now) }
    #expect(await a.syncer.enable(server: account(host)) == nil)
    await a.syncer.round()
    #expect(a.syncer.uploading > 0)
    let info = shared.appending(path: "devices/\(a.store.deviceID)/device.json")
    #expect(!FileManager.default.fileExists(atPath: info.path))
    for _ in 0..<3 where a.syncer.uploading > 0 { await a.syncer.round() }
    #expect(a.syncer.uploading == 0 && FileManager.default.fileExists(atPath: info.path))

    #expect(await b.syncer.enable(server: account(host)) == nil)
    await b.syncer.round()
    #expect(b.syncer.downloading > 0 && b.store.notes.count < count)
    for _ in 0..<6 where b.syncer.downloading > 0 || b.syncer.uploading > 0 {
      await b.syncer.round()
    }
    #expect(b.store.notes.count == count && b.syncer.downloading == 0)
    #expect(b.syncer.status == .idle)
  }

  // MARK: 出错

  /// 服务器说请求太多：停在「请求太多」，到点之前一轮都不发请求；过了时间、服务器好了接着同步
  @Test func busyServerBacksOff() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let a = try Mac(host: "a", root: root, session: FakeDAV.session())
    a.store.create(body: "一", now: .now)
    #expect(await a.syncer.enable(server: account(host)) == nil)
    await a.syncer.round()
    let now = Date.now
    a.syncer.clock = { now }
    FakeDAV.set(host) { $0.busy = true }
    await a.syncer.round()
    guard case .stopped(.busy(let until)) = a.syncer.status else {
      Issue.record("没停在请求太多：\(a.syncer.status)")
      return
    }
    // Retry-After 120 秒，退避第一回 5 分钟：取大的
    #expect(abs(until.timeIntervalSince(now) - 300) < 1)
    FakeDAV.clearLog(host)
    await a.syncer.round()
    #expect(FakeDAV.log(host).isEmpty)
    FakeDAV.set(host) { $0.busy = false }
    a.syncer.clock = { now.addingTimeInterval(301) }
    await a.syncer.round()
    #expect(a.syncer.status == .idle)
  }

  /// 密码不对：连不上，说清楚；连上之后服务器连不上了：停在这一轮，好了接着同步，本机这期间写的照样传上去
  @Test func wrongPasswordAndOffline() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let a = try Mac(host: "a", root: root, session: FakeDAV.session())
    #expect(
      await a.syncer.enable(server: account(host, password: "错的"))
        == WebDAV.Failure.unauthorized.message)
    #expect(a.password == nil && a.syncer.isEnabled == false)
    #expect(await a.syncer.enable(server: account(host)) == nil)
    await a.syncer.round()
    FakeDAV.set(host) { $0.down = true }
    let note = a.store.create(body: "断网时写的", now: .now)
    await a.syncer.round()
    guard case .stopped(.failed(let reason)) = a.syncer.status else {
      Issue.record("没停下：\(a.syncer.status)")
      return
    }
    #expect(reason.hasPrefix("连不上服务器"))
    FakeDAV.set(host) { $0.down = false }
    await a.syncer.round()
    #expect(a.syncer.status == .idle)
    #expect(
      FileManager.default.fileExists(
        atPath: shared.appending(
          path: "devices/\(a.store.deviceID)/notes/\(NoteSyncFolder.fileName(of: note.id))"
        ).path))
  }

  /// 服务器上的那个文件夹里放着别的东西、又没有同步记录：不往里撒子文件夹
  @Test func refusesFolderWithOtherThings() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try Data("别的".utf8).write(to: shared.appending(path: "文稿.txt"))
    let a = try Mac(host: "a", root: root, session: FakeDAV.session())
    #expect(await a.syncer.enable(server: account(host)) == "这个文件夹里已经有别的东西了，换一个空文件夹来同步")
    #expect(!a.syncer.isEnabled && a.password == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: shared.appending(path: NoteSyncFolder.markerName).path)
    )
  }

  /// 测试连接：文件夹在 = 能读能写（写的小文件删掉了）；不在 = 连上了、连接时建；密码不对说清楚
  @Test func testConnection() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let session = FakeDAV.session()
    #expect(try await NoteSyncServer.test(account(host), session: session).get() == .missing)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    #expect(try await NoteSyncServer.test(account(host), session: session).get() == .ready)
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
    let wrong = await NoteSyncServer.test(account(host, password: "错的"), session: session)
    #expect(wrong == .failure(.unauthorized))
  }

  // MARK: 真服务器

  /// 真服务器上走一遍（按需：TEST_RUNNER_KITTY_WEBDAV="地址|用户名|密码"，比如本机 Apache 的 mod_dav，或者一个网盘的
  /// WebDAV 测试账号；在地址底下建一个随机名字、带中文和空格的文件夹，用完删掉）：两台连上、便签（带一张图）和片段来回传、
  /// 改了的过去、标记不覆盖、空闲一轮状态还是好的。请求数看服务器的访问日志
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_WEBDAV"] != nil))
  func liveServer() async throws {
    let parts = try #require(ProcessInfo.processInfo.environment["KITTY_WEBDAV"]).split(
      separator: "|", maxSplits: 2
    ).map(String.init)
    try #require(parts.count == 3)
    let name = "kitty-live-\(UUID().uuidString.prefix(8).lowercased()) 同步"
    let live = WebDAV.Account(
      folder: try #require(WebDAV.folder(address: parts[0], path: name)), user: parts[1],
      password: parts[2])
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try Mac(host: "a", root: root, session: WebDAV.session)
    let b = try Mac(host: "b", root: root, session: WebDAV.session)
    #expect(try await NoteSyncServer.test(live, session: WebDAV.session).get() == .missing)
    let stored = try await NoteImageStore.store(
      data: NoteImageFixture.data(type: .png, width: 40, height: 30),
      in: try #require(a.store.images).directory
    ).get()
    let note = a.store.create(body: "图 \(NoteImages.token(stored.image))", now: .now)
    a.clipboard.saveSnippet("真服务器上的片段")
    #expect(await a.syncer.enable(server: live) == nil)
    await a.syncer.round()
    #expect(a.syncer.status == .idle && a.syncer.uploading == 0)
    // 标记不覆盖：别处已经写了就不写
    #expect(
      await NoteSyncServer.createMarker(live, session: WebDAV.session, library: "另一个") == .exists)
    #expect(await b.syncer.enable(server: live) == nil)
    #expect(b.syncer.library == a.syncer.library)
    b.store.create(body: "B 写的", now: .now)
    await settle([b, a, b])
    #expect(bodies(b).count == 2 && bodies(a) == bodies(b))
    #expect(snippets(b) == ["真服务器上的片段"])
    #expect(b.store.images?.fileNames() == ["\(stored.image.id.uuidString).png"])
    a.store.setBody(
      "改过 \(NoteImages.token(stored.image))", of: note.id, now: .now.addingTimeInterval(5))
    await settle([a, b])
    #expect(b.store.note(note.id)?.body.hasPrefix("改过") == true)
    await settle([a, b])
    #expect(a.syncer.status == .idle && b.syncer.status == .idle)
    #expect(a.syncer.downloading == 0 && b.syncer.uploading == 0)
    // 删掉这次建的文件夹
    var request = URLRequest(url: live.folder)
    request.httpMethod = "DELETE"
    request.setValue(
      "Basic " + Data("\(live.user):\(live.password)".utf8).base64EncodedString(),
      forHTTPHeaderField: "Authorization")
    _ = try? await WebDAV.session.data(for: request)
  }

  /// 停止同步：偏好、密码清掉，镜像删掉（主线程外）；服务器上的东西留着
  @Test func disableForgetsServer() async throws {
    let host = try makeServer()
    defer { cleanUp(host) }
    let a = try Mac(host: "a", root: root, session: FakeDAV.session())
    a.store.create(body: "一", now: .now)
    #expect(await a.syncer.enable(server: account(host)) == nil)
    await a.syncer.round()
    let mirror = try #require(a.syncer.folder)
    a.syncer.disable()
    #expect(a.password == nil && a.syncer.server == nil && a.syncer.folder == nil)
    #expect(a.defaults.string(forKey: Prefs.syncServer) == nil)
    #expect(a.defaults.string(forKey: Prefs.syncServerUser) == nil)
    for _ in 0..<200 where FileManager.default.fileExists(atPath: mirror.path) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!FileManager.default.fileExists(atPath: mirror.path))
    #expect(
      FileManager.default.fileExists(atPath: shared.appending(path: NoteSyncFolder.markerName).path)
    )
  }
}

// MARK: 假服务器

/// 假的 WebDAV 服务器：拦下发往 `*.kitty-fake.test` 的请求，`/dav/` 底下对应一个临时文件夹，按请求真读真写（PROPFIND
/// Depth 0 / 1、GET、PUT（If-None-Match: *）、DELETE、MKCOL、MOVE（Overwrite: F））。每个主机一份：根目录、记下的请求
/// （「方法 /dav/ 之后的路径」），故障开关（busy：回 503 + Retry-After 120；down：连不上）
nonisolated final class FakeDAV: URLProtocol {
  static let user = "kitty"
  static let password = "密码 pw"

  struct Host: Sendable {
    var root: URL
    var log: [String] = []
    var busy = false
    var down = false
  }

  private static let hosts = Mutex<[String: Host]>([:])

  static func add(root: URL) -> String {
    let name = "h\(UUID().uuidString.prefix(8).lowercased()).kitty-fake.test"
    hosts.withLock { $0[name] = Host(root: root) }
    return name
  }

  static func remove(_ name: String) { hosts.withLock { $0[name] = nil } }
  static func set(_ name: String, _ change: (inout Host) -> Void) {
    hosts.withLock {
      if var host = $0[name] {
        change(&host)
        $0[name] = host
      }
    }
  }
  static func log(_ name: String) -> [String] { hosts.withLock { $0[name]?.log ?? [] } }
  static func clearLog(_ name: String) { set(name) { $0.log = [] } }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeDAV.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host()?.hasSuffix(".kitty-fake.test") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func stopLoading() {}

  override func startLoading() {
    guard let url = request.url, let name = url.host(),
      let host = Self.hosts.withLock({ $0[name] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    if host.down {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let method = request.httpMethod ?? "GET"
    let path = Self.relative(url)
    Self.set(name) { $0.log.append("\(method) \(path ?? "?")") }
    let (status, headers, body) =
      host.busy
      ? (503, ["Retry-After": "120"], Data())
      : respond(method, path: path, root: host.root, url: url)
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  /// /dav/ 之后的路径（解码的，前面带 /；不在 /dav/ 底下是 nil）
  private static func relative(_ url: URL) -> String? {
    let path = url.path(percentEncoded: false)
    guard path.hasPrefix("/dav") else { return nil }
    let rest = String(path.dropFirst(4))
    return rest.isEmpty ? "/" : rest
  }

  private func respond(_ method: String, path: String?, root: URL, url: URL)
    -> (Int, [String: String], Data)
  {
    let expected =
      "Basic " + Data("\(Self.user):\(Self.password)".utf8).base64EncodedString()
    guard request.value(forHTTPHeaderField: "Authorization") == expected else {
      return (401, ["WWW-Authenticate": "Basic realm=\"fake\""], Data())
    }
    guard let path else { return (404, [:], Data()) }
    let target = root.appending(path: String(path.dropFirst()))
    let files = FileManager.default
    var isFolder: ObjCBool = false
    let exists = files.fileExists(atPath: target.path, isDirectory: &isFolder)
    let parentExists = files.fileExists(atPath: target.deletingLastPathComponent().path)
    switch method {
    case "PROPFIND":
      guard exists else { return (404, [:], Data()) }
      var entries = [target]
      if isFolder.boolValue, request.value(forHTTPHeaderField: "Depth") != "0" {
        entries += ((try? files.contentsOfDirectory(atPath: target.path)) ?? []).sorted().map {
          target.appending(path: $0)
        }
      }
      return (207, ["Content-Type": "application/xml"], Self.multistatus(entries, root: root))
    case "GET":
      guard exists, !isFolder.boolValue, let data = try? Data(contentsOf: target) else {
        return (404, [:], Data())
      }
      return (200, ["ETag": Self.etag(target)], data)
    case "PUT":
      guard parentExists else { return (409, [:], Data()) }
      if exists, request.value(forHTTPHeaderField: "If-None-Match") == "*" {
        return (412, [:], Data())
      }
      do { try body.write(to: target, options: .atomic) } catch { return (500, [:], Data()) }
      return (201, ["ETag": Self.etag(target)], Data())
    case "DELETE":
      guard exists else { return (404, [:], Data()) }
      try? files.removeItem(at: target)
      return (204, [:], Data())
    case "MKCOL":
      if exists { return (405, [:], Data()) }
      guard parentExists else { return (409, [:], Data()) }
      try? files.createDirectory(at: target, withIntermediateDirectories: false)
      return (201, [:], Data())
    case "MOVE":
      guard exists, let destination = request.value(forHTTPHeaderField: "Destination"),
        let to = URL(string: destination).flatMap(Self.relative)
      else { return (404, [:], Data()) }
      let goal = root.appending(path: String(to.dropFirst()))
      if files.fileExists(atPath: goal.path) { return (412, [:], Data()) }
      do { try files.moveItem(at: target, to: goal) } catch { return (500, [:], Data()) }
      return (201, [:], Data())
    default:
      return (405, [:], Data())
    }
  }

  /// 请求体：data(for:) 带的、upload 给的流都认
  private var body: Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }

  private static func etag(_ url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .fileIdentifierKey,
    ])
    let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    return "\"\(values?.fileSize ?? 0)-\(modified)-\(values?.fileIdentifier ?? 0)\""
  }

  private static func multistatus(_ entries: [URL], root: URL) -> Data {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    var xml = #"<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">"#
    let base = root.standardizedFileURL.path
    for url in entries {
      let values = try? url.resourceValues(forKeys: [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
      ])
      let folder = values?.isDirectory == true
      let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
      let href =
        "/dav"
        + relative.split(separator: "/").map {
          "/" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }.joined() + (folder ? "/" : "")
      xml += "<D:response><D:href>\(href)</D:href><D:propstat><D:prop>"
      xml += folder ? "<D:resourcetype><D:collection/></D:resourcetype>" : "<D:resourcetype/>"
      if !folder {
        xml += "<D:getcontentlength>\(values?.fileSize ?? 0)</D:getcontentlength>"
        xml += "<D:getetag>\(etag(url))</D:getetag>"
      }
      if let modified = values?.contentModificationDate {
        xml += "<D:getlastmodified>\(formatter.string(from: modified))</D:getlastmodified>"
      }
      xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }
    xml += "</D:multistatus>"
    return Data(xml.utf8)
  }
}
