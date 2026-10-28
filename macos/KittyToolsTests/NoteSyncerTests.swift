// 便签同步的执行层（Notes/NoteSyncer.swift + NoteSyncDisk.swift，便签未来计划 A）：两台「电脑」（两个真的 NoteStore、
// 两个临时的偏好域）用同一个临时文件夹真读真写——开同步（新文件夹写标记、已有的接着用）、新建 / 改 / 冲突另存 / 永久删
// 传过去、刹车停下来等确认、正在编辑的那条先不换也先不写出去、文件夹不在 / 不是那个文件夹时停、图片两头补齐、认出库被
// 退回去了换编号且不丢字、写到一半停了不算退回去、关掉同步、开同步时不盖掉别人的标记。读写那一层另测：没变的文件不再读
// （换了文件号的照读）、占位文件和太大的文件算读不出来、写、删、墓碑、电脑名。
// 都在临时目录和临时偏好域里，用完删；不碰真实的数据目录、偏好和剪贴板。

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

@MainActor
struct NoteSyncerTests {
  private let root = FileManager.default.temporaryDirectory.appending(
    path: "kitty-notes-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
  private var shared: URL { root.appending(path: "同步", directoryHint: .isDirectory) }

  /// 一台电脑：仓库（内存库或者临时文件库）、图片目录、偏好域、同步
  private final class Mac {
    let store: NoteStore
    private(set) var syncer: NoteSyncer
    let host: String
    let suite: String
    let defaults: UserDefaults
    /// 剪贴板库（片段、收藏）和翻译历史（生词本）：同一个内存库，同 App 里的 kitty.sqlite3
    let kitty: Database
    let clipboard: ClipboardStore
    let history: HistoryStore
    /// 启动器收藏（同一个内存库）、网页搜索与快捷链接（临时偏好域）、翻译服务（不读写偏好的一份）
    let launcher: LauncherUsage
    let services: TranslateServiceStore
    /// 设置、快捷键、功能开关（同一个临时偏好域）
    let settings: SettingsSync
    var editing: Set<String> = []
    var featuresOff: Set<String> = []

    init(host: String, root: URL, file: URL? = nil) throws {
      self.host = host
      let db = try Database(path: file?.path ?? ":memory:", wal: file == nil)
      store = try NoteStore(db: db, wait: { _ in }, host: host)
      store.images = NoteImageStore(directory: root.appending(path: "图片-\(host)"))
      suite = "kitty-notes-sync-tests-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suite)!
      syncer = NoteSyncer(store: store, defaults: defaults)
      kitty = try Database(path: ":memory:")
      clipboard = try ClipboardStore(
        db: kitty, images: ImageStore(directory: root.appending(path: "剪贴板图片-\(host)")))
      history = try HistoryStore(db: kitty)
      launcher = try LauncherUsage(db: kitty)
      services = TranslateServiceStore(services: [.zhipu])
      settings = SettingsSync(defaults: defaults, domainName: suite)
      history.defaults = defaults
      wire(syncer)
    }

    /// 接上几类、电脑名、正在编辑、功能开关
    private func wire(_ syncer: NoteSyncer) {
      syncer.sources = [
        clipboard, history, WebSearchSync(defaults: defaults),
        TranslateServiceSync(store: services, defaults: defaults), launcher,
        StatusPresetSync(defaults: defaults), settings,
      ]
      let host = self.host
      syncer.computerName = { host }
      syncer.editing = { [unowned self] in editing }
      syncer.featureOn = { [unowned self] in !featuresOff.contains($0) }
    }

    /// 重开一次 App：新的同步按偏好里记着的起来（升级判定在这时做）
    func relaunch() {
      syncer.stop()
      syncer = NoteSyncer(store: store, defaults: defaults)
      wire(syncer)
    }

    /// 留下来的文字条目（收藏、片段）：正文 → (收藏、片段、收藏夹的名字、备注)
    var retained: [String: (Bool, Bool, String?, String?)] {
      var result: [String: (Bool, Bool, String?, String?)] = [:]
      for item in clipboard.items where item.isRetained {
        let group = item.groupID.flatMap { id in clipboard.groups.first { $0.id == id }?.name }
        result[item.text ?? ""] = (item.favorite, item.isSnippet, group, item.note)
      }
      return result
    }

    var words: [String] { history.search("", favoritesOnly: true, limit: 0).map(\.source).sorted() }

    /// 偏好里存着的（持久域里的；object(forKey:) 会落到注册的默认值上——注册域整个进程共用，别的测试注册过）
    func stored(_ key: String) -> Any? { defaults.persistentDomain(forName: suite)?[key] }

    var engines: [SearchEngine] {
      get { WebSearch.engines(in: defaults) }
      set { WebSearch.setEngines(newValue, in: defaults) }
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
  }

  private func makeShared() throws {
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
  }

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  /// 几台轮流合几遍
  private func settle(_ macs: [Mac], times: Int = 2) async {
    for _ in 0..<times {
      for mac in macs { await mac.syncer.round() }
    }
  }

  private func bodies(_ mac: Mac) -> Set<String> { Set(mac.store.notes.map(\.body)) }

  // MARK: 开同步、来回传

  /// 新文件夹：写标记、记下文件夹和库编号；另一台看得到有一台电脑、几条便签，开了之后接着同一个库；便签来回传
  @Test func notesTravelBetweenMacs() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.store.create(body: "A 写的", now: .now)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    #expect(a.syncer.status == .idle && a.syncer.lastSync != nil)
    let marker = try JSONDecoder().decode(
      NoteSyncFolder.Marker.self,
      from: Data(contentsOf: shared.appending(path: NoteSyncFolder.markerName)))
    #expect(
      marker.library == a.syncer.library
        && a.defaults.string(forKey: Prefs.notesSyncFolder) == shared.path)
    let seen = await NoteSyncDisk.inspect(folder: shared, device: b.store.deviceID)
    #expect(seen.devices == 1 && seen.notes == 1 && seen.marker == marker)
    #expect(await b.syncer.enable(folder: shared) == nil)
    #expect(b.syncer.library == a.syncer.library)
    await b.syncer.round()
    #expect(bodies(b) == ["A 写的"])
    #expect(b.syncer.peers.map(\.name) == ["a"])
    let note = try #require(b.store.notes.first)
    b.store.setBody("B 改的", of: note.id, now: .now.addingTimeInterval(5))
    await settle([b, a])
    #expect(bodies(a) == ["B 改的"] && a.store.notes.count == 1)
  }

  /// 两边各改同一条：后改的赢，输的那版在两边的「最近删除」里各一条（同一条）
  @Test func conflictsKeepTheLoserOnBothSides() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let note = a.store.create(body: "原来的", now: .now)
    for mac in [a, b] {
      #expect(await mac.syncer.enable(folder: shared) == nil)
    }
    await settle([a, b])
    a.store.setBody("A 改的", of: note.id, now: .now.addingTimeInterval(10))
    b.store.setBody("B 后改的", of: note.id, now: .now.addingTimeInterval(20))
    await settle([a, b, a])
    for mac in [a, b] {
      #expect(mac.store.note(note.id)?.body == "B 后改的")
      #expect(mac.store.trashed.map(\.body) == ["A 改的"])
    }
  }

  /// 永久删除传过去：对面在最近删除里的那条跟着真删；本机在用（没删）的那条不动
  @Test func erasingTravels() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let gone = a.store.create(body: "要删的", now: .now)
    a.store.create(body: "留着的", now: .now)
    for mac in [a, b] {
      #expect(await mac.syncer.enable(folder: shared) == nil)
    }
    await settle([a, b])
    a.store.delete(gone.id, now: .now.addingTimeInterval(5))
    await settle([a, b])
    #expect(b.store.note(gone.id)?.deletedAt != nil)
    a.store.erase(gone.id, now: .now.addingTimeInterval(10))
    await settle([a, b])
    #expect(b.store.note(gone.id) == nil && bodies(b) == ["留着的"])
    #expect(b.store.erased[gone.id] != nil)
  }

  // MARK: 刹车、正在编辑

  /// 一轮要放进最近删除的太多：停下来等确认，什么都不改；确认之后照常合
  @Test func brakeWaitsForConfirmation() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let notes = (0..<10).map { a.store.create(body: "第 \($0) 条", now: .now) }
    for mac in [a, b] {
      #expect(await mac.syncer.enable(folder: shared) == nil)
    }
    await settle([a, b])
    for note in notes.prefix(8) { a.store.delete(note.id, now: .now.addingTimeInterval(5)) }
    await a.syncer.round()
    await b.syncer.round()
    #expect(b.syncer.status == .waiting(trashing: 8))
    #expect(b.store.trashed.isEmpty, "等确认：一条都没动")
    b.syncer.allowTrashing()
    await b.syncer.round()
    #expect(b.syncer.status == .idle && b.store.trashed.count == 8)
  }

  /// 正在编辑的那条这一轮先不换、也先不写出去（不然对面每轮多一条另存的半截）；焦点离开之后再合，各改各的另存一条；别的照换
  @Test func notesBeingEditedWait() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let busy = a.store.create(body: "B 正在写", now: .now)
    let other = a.store.create(body: "别的", now: .now)
    for mac in [a, b] {
      #expect(await mac.syncer.enable(folder: shared) == nil)
    }
    await settle([a, b])
    a.store.setBody("A 改了", of: busy.id, now: .now.addingTimeInterval(5))
    a.store.setBody("A 也改了这条", of: other.id, now: .now.addingTimeInterval(5))
    await a.syncer.round()
    b.editing = [busy.id]
    b.store.setBody("B 正在写，又打了几个字", of: busy.id, now: .now.addingTimeInterval(7))
    await b.syncer.round()
    #expect(
      b.store.note(busy.id)?.body == "B 正在写，又打了几个字"
        && b.store.note(other.id)?.body == "A 也改了这条")
    await a.syncer.round()
    #expect(a.store.trashed.isEmpty && a.store.note(busy.id)?.body == "A 改了", "B 那条没写出去")
    b.editing = []
    await settle([b, a])
    for mac in [a, b] {
      #expect(mac.store.note(busy.id)?.body == "B 正在写，又打了几个字")
      #expect(mac.store.trashed.map(\.body) == ["A 改了"])
    }
  }

  // MARK: 停

  /// 文件夹不在了、标记换了（不是那个文件夹）：停，说为什么；本机的便签不动
  @Test func stopsOnMissingOrForeignFolder() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    a.store.create(body: "本机的", now: .now)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    let marker = try JSONEncoder().encode(NoteSyncFolder.Marker(library: "别的库"))
    try marker.write(to: shared.appending(path: NoteSyncFolder.markerName))
    await a.syncer.round()
    #expect(a.syncer.status == .stopped(.notTheFolder))
    try FileManager.default.removeItem(at: shared)
    await a.syncer.round()
    #expect(a.syncer.status == .stopped(.missingFolder) && bodies(a) == ["本机的"])
    #expect(await a.syncer.enable(folder: shared) == "这个文件夹不在了")
  }

  /// 开同步时不盖掉别人的库：标记还没下载完（旧式占位文件）、没标记却有别的电脑的子文件夹，都不开；没同步过的文件夹放着
  /// 别的东西也不开（点开头的不算）；标记不覆盖着写
  @Test func enablingNeverReplacesAMarker() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let placeholder = shared.appending(path: ".\(NoteSyncFolder.markerName).icloud")
    try Data().write(to: placeholder)
    #expect(await a.syncer.enable(folder: shared) != nil && !a.syncer.isEnabled)
    try FileManager.default.removeItem(at: placeholder)
    let other = shared.appending(path: "devices/B/notes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    #expect(await a.syncer.enable(folder: shared) != nil && !a.syncer.isEnabled)
    try FileManager.default.removeItem(at: shared.appending(path: "devices"))
    try Data().write(to: shared.appending(path: "别的.txt"))
    #expect(await a.syncer.enable(folder: shared) != nil && !a.syncer.isEnabled)
    try FileManager.default.removeItem(at: shared.appending(path: "别的.txt"))
    try Data().write(to: shared.appending(path: ".DS_Store"))
    #expect(await a.syncer.enable(folder: shared) == nil, "只有点开头的算空")
    let library = try #require(a.syncer.library)
    #expect(await NoteSyncDisk.createMarker(in: shared, library: "第二个") != nil, "不覆盖")
    a.syncer.disable()
    #expect(await a.syncer.enable(folder: shared) == nil && a.syncer.library == library)
  }

  /// 关掉同步：偏好清掉、状态关着；文件夹里的东西留着
  @Test func disablingKeepsTheFolder() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    a.store.create(body: "本机的", now: .now)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    a.syncer.disable()
    #expect(!a.syncer.isEnabled && a.syncer.status == .off)
    #expect(a.defaults.object(forKey: Prefs.notesSyncFolder) == nil)
    #expect(
      FileManager.default.fileExists(atPath: shared.appending(path: NoteSyncFolder.markerName).path)
    )
  }

  // MARK: 图片

  /// 正文里的图：本机有、文件夹没有的传上去；对面没有的拿下来
  @Test func imagesTravel() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let images = try #require(a.store.images)
    let stored = try await NoteImageStore.store(
      data: NoteImageFixture.data(type: .png, width: 40, height: 30), in: images.directory
    ).get()
    a.store.create(body: "图 \(NoteImages.token(stored.image))", now: .now)
    for mac in [a, b] {
      #expect(await mac.syncer.enable(folder: shared) == nil)
    }
    await settle([a, b])
    let name = "\(stored.image.id.uuidString).png"
    #expect(FileManager.default.fileExists(atPath: shared.appending(path: "images/\(name)").path))
    #expect(b.store.images?.fileNames() == [name])
    // 拿下来的报给仓库（第三轮体检 B7：按「没图」建过的墙卡片、编辑器里的占位框换上它）；只传上去的不报
    #expect(b.store.imageArrivals > 0)
    #expect(a.store.imageArrivals == 0)
  }

  // MARK: 库被退回去了

  /// 时间机器把 A 的库退回到旧的样子：认出来、换编号；退回去之后打的字和之前发出去的那版都在（一版是另存的那条）。
  /// typed：恢复之后打了几次字——打得多、计数追上甚至超过发出去的那版时，光看钟认不出来，靠 device.json 里记的第几轮；
  /// noInfo：自己的 device.json 不在了（只剩钟那条路认）
  @Test(arguments: [(0, true), (1, false), (3, false)])
  func regressedLibrarySwitchesDeviceWithoutLosingText(typed: Int, noInfo: Bool) async throws {
    try makeShared()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { cleanUp() }
    let file = root.appending(path: "a.sqlite3")
    let old = root.appending(path: "a-旧.sqlite3")
    let note: Note
    do {
      let a = try Mac(host: "a", root: root, file: file)
      note = a.store.create(body: "一", now: .now)
      try FileManager.default.copyItem(at: file, to: old)
      a.store.setBody("一二三", of: note.id, now: .now.addingTimeInterval(5))
      #expect(await a.syncer.enable(folder: shared) == nil)
      await a.syncer.round()
    }
    // 恢复成旧的那份库（同一台电脑：编号没变、计数退回去了），接着打字
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: old, to: file)
    let restored = try Mac(host: "a", root: root, file: file)
    let before = restored.store.deviceID
    for count in 0..<typed {
      restored.store.setBody(
        "一（恢复后打的 \(count + 1)）", of: note.id, now: .now.addingTimeInterval(10 + Double(count)))
    }
    if noInfo {
      try FileManager.default.removeItem(
        at: shared.appending(path: "devices/\(before)/\(NoteSyncFolder.deviceInfoName)"))
    }
    #expect(await restored.syncer.enable(folder: shared) == nil)
    await restored.syncer.round()
    #expect(restored.store.deviceID != before)
    #expect(bodies(restored) == [typed == 0 ? "一" : "一（恢复后打的 \(typed)）", "一二三"])
    // 再合一轮：不再换编号
    let after = restored.store.deviceID
    await restored.syncer.round()
    #expect(restored.store.deviceID == after && restored.syncer.status == .idle)
  }

  /// 写到一半停了（自己的 notes/ 写不进去）：device.json 不写；好了之后下一轮不当成库被退回去了，不换编号
  @Test func failedWriteIsNotARollback() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let note = a.store.create(body: "一", now: .now)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    let device = a.store.deviceID
    let notes = shared.appending(path: "devices/\(device)/notes", directoryHint: .isDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: notes.path)
    a.store.setBody("一二", of: note.id, now: .now.addingTimeInterval(5))
    await a.syncer.round()
    if case .stopped(.failed) = a.syncer.status {} else { Issue.record("没停：\(a.syncer.status)") }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path)
    await a.syncer.round()
    #expect(a.store.deviceID == device && a.syncer.status == .idle && a.store.trashed.isEmpty)
  }

  // MARK: 读写那一层

  /// 没变的文件不再读（按路径 + 文件号 + 改动时间 + 大小认）、换了一个文件（时刻、大小一样）照读；`.名字.icloud` 的
  /// 占位文件和太大的文件算读不出来
  @Test func diskReadUsesTheCacheAndSkipsPlaceholders() async throws {
    try makeShared()
    defer { cleanUp() }
    let notes = shared.appending(path: "devices/B/notes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let real = Note(
      id: UUID().uuidString, body: "真的", createdAt: .now, modifiedAt: .now, clock: ["B": 1])
    let url = notes.appending(path: NoteSyncFolder.fileName(of: real.id))
    try NoteSyncFolder.text(of: real).write(to: url, atomically: true, encoding: .utf8)
    // 刚改过的不记进缓存（时刻精度只到秒的盘）：拨回一分钟前
    let past = Date.now.addingTimeInterval(-60)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    let waiting = UUID().uuidString
    try Data().write(to: notes.appending(path: ".\(waiting).md.icloud"))
    let huge = UUID().uuidString
    try Data(count: NoteSyncFolder.maxNoteFileBytes + 1).write(
      to: notes.appending(path: "\(huge).md"))
    let first = await NoteSyncDisk.read(folder: shared, cache: .init())
    let device = try #require(first.folder.devices["B"])
    #expect(device.notes[real.id]?.body == "真的" && device.unreadable == [waiting, huge])
    // 有读不出来的：便签这部分这一轮不能跳过
    #expect(first.unsettled.contains(NoteSyncer.notesPart))
    // 缓存里那一项换成别的：文件没变，就用缓存里的（证明没再读）
    var cache = first.cache
    var marked = real
    marked.body = "缓存里的"
    cache.files[url.path]?.note = marked
    let second = await NoteSyncDisk.read(folder: shared, cache: cache)
    #expect(second.folder.devices["B"]?.notes[real.id]?.body == "缓存里的")
    // 别处换进来一版（原子写：文件号变了），时刻、大小都一样：照读
    var swapped = real
    swapped.body = "换的"
    try NoteSyncFolder.text(of: swapped).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    let third = await NoteSyncDisk.read(folder: shared, cache: second.cache)
    #expect(third.folder.devices["B"]?.notes[real.id]?.body == "换的")
    #expect(await NoteSyncDisk.read(folder: root.appending(path: "没有"), cache: .init()).missing)
  }

  /// 写：便签文件、要删的、墓碑文件、device.json（名字、第几轮变了才写）
  @Test func diskWriteFollowsThePlan() async throws {
    try makeShared()
    defer { cleanUp() }
    let keep = Note(
      id: UUID().uuidString, body: "写进去", createdAt: .now, modifiedAt: .now, clock: ["A": 1])
    let goneID = UUID().uuidString
    let mine = shared.appending(path: "devices/A/notes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    try Data("旧的".utf8).write(to: mine.appending(path: NoteSyncFolder.fileName(of: goneID)))
    let tombstones = [goneID: NoteSync.Tombstone(clock: ["A": 1], state: .now)]
    var plan = NoteSyncFolder.Publish()
    plan.writes = [keep]
    plan.deletes = [goneID]
    plan.erased = tombstones
    let written = await NoteSyncDisk.write(
      plan, folder: shared, device: "A", name: "我的 Mac", epoch: 1, images: nil)
    #expect(written.problem == nil && written.wrote == [keep.id] && written.deleted == [goneID])
    let back = await NoteSyncDisk.read(folder: shared, cache: .init())
    let device = try #require(back.folder.devices["A"])
    #expect(device.notes[keep.id]?.body == "写进去" && device.notes[goneID] == nil)
    #expect(device.name == "我的 Mac" && device.epoch == 1)
    let info = shared.appending(path: "devices/A/\(NoteSyncFolder.deviceInfoName)")
    let past = Date.now.addingTimeInterval(-60)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: info.path)
    _ = await NoteSyncDisk.write(
      .init(), folder: shared, device: "A", name: "我的 Mac", epoch: 1, images: nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: info.path)
    #expect(attributes[.modificationDate] as? Date == past, "没变就不重写")
    if case .read(let read) = device.erased {
      #expect(read.keys.sorted() == [goneID])
    } else {
      Issue.record("墓碑文件读不出来")
    }
  }

  // MARK: 片段、收藏、生词本（全局同步第 3 批）

  /// 片段、收藏和收藏夹、生词本来回传；对面改了正文、备注跟着变；对面删了的这台只是不再收藏（还在历史里）
  @Test func clipsAndWordsTravel() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.clipboard.saveSnippet("此致敬礼")
    a.clipboard.recordOwnText("收藏的一段")
    let favorite = try #require(a.clipboard.items.first { $0.text == "收藏的一段" })
    a.clipboard.toggleFavorite([favorite.id])
    let group = try #require(a.clipboard.createGroup(named: "工作"))
    a.clipboard.assign([favorite.id], to: group.id)
    a.clipboard.recordOwnText("普通历史不同步")
    a.history.setFavorite(
      source: "serendipity", target: .zhHans, result: "意外之喜", service: "s", true)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    #expect(b.retained["此致敬礼"].map { !$0.0 && $0.1 } == true)
    #expect(b.retained["收藏的一段"].map { $0.0 && $0.2 == "工作" } == true)
    #expect(b.retained["普通历史不同步"] == nil && b.words == ["serendipity"])
    // B 改正文和备注，A 跟着变
    let snippet = try #require(b.clipboard.items.first { $0.text == "此致敬礼" })
    b.clipboard.update([snippet.id]) {
      $0.text = "此致\n敬礼"
      $0.note = "落款"
    }
    await settle([b, a])
    #expect(a.retained["此致\n敬礼"]?.3 == "落款" && a.retained["此致敬礼"] == nil)
    // B 取消收藏：A 那条不再收藏，但还在历史里
    b.clipboard.toggleFavorite([favorite.id])
    b.history.setFavorite(
      source: "serendipity", target: .zhHans, result: "意外之喜", service: "s", false)
    await settle([b, a])
    #expect(a.retained["收藏的一段"] == nil)
    #expect(a.clipboard.items.contains { $0.text == "收藏的一段" } && a.words.isEmpty)
    // 账本和数据在同一个库里
    let ledger = try SyncLedger.load(.clips, library: try #require(a.syncer.library), in: a.kitty)
    #expect(ledger != nil)
  }

  /// 第一次合：两台都有同样正文的收藏，合完各只有一条
  @Test func joiningDoesNotDuplicateClips() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    for mac in [a, b] { mac.clipboard.saveSnippet("同样的片段") }
    // 两台各有一个「工作」收藏夹，B 那条收藏在里面、带备注；A 那条同正文、没备注
    for mac in [a, b] { mac.clipboard.recordOwnText("同样的收藏") }
    let ga = try #require(a.clipboard.createGroup(named: "工作"))
    let gb = try #require(b.clipboard.createGroup(named: "工作"))
    for (mac, group) in [(a, ga), (b, gb)] {
      let item = try #require(mac.clipboard.items.first { $0.text == "同样的收藏" })
      mac.clipboard.toggleFavorite([item.id])
      mac.clipboard.assign([item.id], to: group.id)
    }
    let mine = try #require(b.clipboard.items.first { $0.text == "同样的收藏" })
    b.clipboard.update([mine.id]) { $0.note = "B 的备注" }
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b], times: 3)
    for mac in [a, b] {
      #expect(mac.clipboard.items.count { $0.text == "同样的片段" } == 1)
      // 本机的备注、收藏夹没丢；同名收藏夹只剩一个
      #expect(mac.retained["同样的收藏"].map { $0.2 == "工作" && $0.3 == "B 的备注" } == true)
      #expect(mac.clipboard.groups.map(\.name) == ["工作"])
      // 库里和内存一样（重开一次不多出一条）
      let reopened = try ClipboardStore(
        db: mac.kitty, images: ImageStore(directory: root.appending(path: "重开")))
      #expect(reopened.items.count { $0.text == "同样的片段" } == 1)
      #expect(reopened.items.count { $0.text == "同样的收藏" } == 1)
    }
  }

  /// 两台都开着同步、合之前各自收藏同一句、存同样一段片段：合完各只剩一条，还是收藏 / 片段
  @Test func concurrentSameTextConverges() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    for mac in [a, b] {
      mac.clipboard.saveSnippet("同时存的片段")
      mac.history.setFavorite(source: "both", target: .zhHans, result: "两边", service: "s", true)
    }
    await settle([a, b], times: 4)
    for mac in [a, b] {
      #expect(mac.clipboard.items.count { $0.text == "同时存的片段" } == 1)
      #expect(mac.retained["同时存的片段"]?.1 == true && mac.words == ["both"])
    }
  }

  /// 合完再合一轮：自己那份不重写、账本不变（编 → 落 → 再编字节一样）
  @Test func settledRoundsWriteNothing() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.clipboard.saveSnippet("片段")
    let group = try #require(a.clipboard.createGroup(named: "收藏夹"))
    a.clipboard.recordOwnText("收藏")
    let item = try #require(a.clipboard.items.first { $0.text == "收藏" })
    a.clipboard.toggleFavorite([item.id])
    a.clipboard.assign([item.id], to: group.id)
    a.history.setFavorite(source: "word", target: .zhHans, result: "词", service: "s", true)
    var ai = TranslateService.newAI()
    ai.baseURL = "https://ai.example/v1"
    a.services.services.append(ai)
    a.launcher.toggleFavorite(
      LauncherItem(kind: .url, target: "https://example.com", title: "示例", subtitle: ""))
    // 设置：小数、整数值的小数、字符串数组、清除了的快捷键；状态屏：加一个自己写的状态
    a.defaults.set(1.1, forKey: Prefs.translateFontScale)
    a.defaults.set(["com.example.app"], forKey: Prefs.clipboardExcludedBundleIDs)
    a.defaults.set(HotKeyAction.stored(nil), forKey: HotKeyAction.clipboard.prefsKey)
    var presets = StatusPreset.builtIn
    presets.append(
      StatusPreset(
        id: "mine", title: "开会中", detail: nil, symbol: "", style: .dim, power: .normal,
        autoEndMinutes: 0))
    StatusPreset.save(presets, to: a.defaults)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b], times: 3)
    func stamps(_ mac: Mac) throws -> [Date?] {
      try SyncRecords.Kind.allCases.map(\.rawValue).map { kind in
        let url = shared.appending(path: "devices/\(mac.store.deviceID)/\(kind).json")
        return try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
          as? Date
      }
    }
    let library = try #require(a.syncer.library)
    let before = try [a, b].map { try stamps($0) }
    let ledgers = try [a, b].map { try SyncLedger.load(.clips, library: library, in: $0.kitty) }
    await settle([a, b])
    let after = try [a, b].map { try stamps($0) }
    let ledgersAfter = try [a, b].map {
      try SyncLedger.load(.clips, library: library, in: $0.kitty)
    }
    #expect(after == before && ledgersAfter == ledgers)
  }

  /// 便签这部分不合时，device.json 里的「第几轮」不往小里写
  @Test func skippingNotesKeepsTheEpoch() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let note = a.store.create(body: "一", now: .now)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    a.store.setBody("一二", of: note.id, now: .now.addingTimeInterval(5))
    await a.syncer.round()
    let epoch = await NoteSyncDisk.read(folder: shared, cache: .init()).folder.devices[
      a.store.deviceID]?.epoch
    #expect((epoch ?? 0) >= 2)
    // 库里记的那一轮被退回去（时间机器），这时候便签不合、只合片段
    try a.store.setMeta(NoteSyncer.epochKey, "1")
    a.featuresOff = [NoteSyncer.notesPart]
    a.clipboard.saveSnippet("片段")
    await a.syncer.round()
    let after = await NoteSyncDisk.read(folder: shared, cache: .init()).folder.devices[
      a.store.deviceID]?.epoch
    #expect(after == epoch)
  }

  /// 刹车的「继续」每部分各算：便签那边点了继续，片段一下删很多照样停下来问
  @Test func brakeAllowanceIsPerPart() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let notes = (0..<10).map { a.store.create(body: "第 \($0) 条", now: .now) }
    for index in 0..<10 { a.clipboard.saveSnippet("片段 \(index)") }
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    for note in notes.prefix(8) { a.store.delete(note.id, now: .now.addingTimeInterval(5)) }
    let doomed = Set(a.clipboard.items.filter { $0.isSnippet }.prefix(8).map(\.id))
    a.clipboard.removeFromSnippets(doomed)
    // A 自己一下删了 8 条片段：先停下来问
    await a.syncer.round()
    #expect(a.syncer.status == .waiting(trashing: 8))
    a.syncer.allowTrashing()
    await a.syncer.round()
    #expect(a.syncer.status == .idle)
    // B：便签先停（8 条进最近删除），点继续之后片段还要再问一次
    await b.syncer.round()
    #expect(b.syncer.status == .waiting(trashing: 8) && b.store.trashed.isEmpty)
    b.syncer.allowTrashing()
    await b.syncer.round()
    #expect(b.store.trashed.count == 8 && b.syncer.status == .waiting(trashing: 8))
    #expect(b.clipboard.items.count(where: \.isSnippet) == 10)
    b.syncer.allowTrashing()
    await b.syncer.round()
    #expect(b.syncer.status == .idle && b.clipboard.items.count(where: \.isSnippet) == 2)
  }

  /// 剪贴板面板里有还能撤销的删除时这一类先不合；没勾上的、功能关着的那类不合
  @Test func busySkippedAndOffPartsWait() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.clipboard.saveSnippet("一")
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    b.clipboard.recordOwnText("会被撤销删除的")
    let pending = try #require(b.clipboard.items.first { $0.text == "会被撤销删除的" })
    b.clipboard.deleteWithUndo([pending.id])
    a.clipboard.saveSnippet("二")
    await settle([a, b])
    #expect(b.retained["二"] == nil, "面板里有能撤销的删除：先不合")
    b.clipboard.commitDeletion()
    await settle([a, b])
    #expect(b.retained["二"] != nil)
    // B 不同步片段：A 新加的不过来
    b.syncer.setSyncs(SyncRecords.Kind.clips.rawValue, false)
    a.clipboard.saveSnippet("三")
    await settle([a, b])
    #expect(b.retained["三"] == nil)
    b.syncer.setSyncs(SyncRecords.Kind.clips.rawValue, true)
    // 翻译关着：生词本不合
    b.featuresOff = [SyncRecords.Kind.vocabulary.rawValue]
    a.history.setFavorite(source: "hello", target: .zhHans, result: "你好", service: "s", true)
    await settle([a, b])
    #expect(b.retained["三"] != nil && b.words.isEmpty)
  }

  // MARK: 网页搜索与快捷链接、翻译服务、启动器收藏（全局同步第 4 批）

  /// 三类来回传：加、改、挪、删都过去；翻译服务只传配置（密钥在钥匙串里，不碰）
  @Test func enginesServicesAndLauncherFavoritesTravel() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    var engines = a.engines
    engines.insert(
      SearchEngine(
        id: "custom-1", name: "公司内网", keyword: "wiki", urlTemplate: "https://wiki.example/{query}",
        enabled: false), at: 0)
    a.engines = engines
    var ai = TranslateService.newAI()
    ai.name = "自建"
    ai.baseURL = "https://ai.example/v1"
    ai.model = "m1"
    a.services.services.append(ai)
    a.launcher.toggleFavorite(
      LauncherItem(kind: .url, target: "https://example.com", title: "示例", subtitle: ""))
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    #expect(b.engines.first?.id == "custom-1" && b.engines.map(\.id) == a.engines.map(\.id))
    #expect(b.services.services.map(\.id) == ["zhipu", ai.id])
    #expect(b.services.services.last?.baseURL == "https://ai.example/v1")
    #expect(b.launcher.favorites.map(\.target) == ["https://example.com"])
    // B 删掉那条搜索、改 AI 服务的模型、取消收藏 → A 跟着变
    b.engines = b.engines.filter { $0.id != "custom-1" }
    b.services.services[1].model = "m2"
    b.launcher.toggleFavorite(
      LauncherItem(kind: .url, target: "https://example.com", title: "示例", subtitle: ""))
    await settle([b, a])
    #expect(!a.engines.contains { $0.id == "custom-1" })
    #expect(a.services.services.last?.model == "m2" && a.launcher.favorites.isEmpty)
  }

  /// 启动器收藏两台同时各加满：都留着（不卡 8 个）
  @Test func launcherFavoritesFromBothMacsAreKept() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    for (mac, name) in [(a, "a"), (b, "b")] {
      for index in 0..<LauncherUsage.favoriteLimit {
        mac.launcher.toggleFavorite(
          LauncherItem(
            kind: .url, target: "https://\(name).example/\(index)", title: "\(index)", subtitle: "")
        )
      }
    }
    await settle([a, b], times: 3)
    for mac in [a, b] { #expect(mac.launcher.favorites.count == LauncherUsage.favoriteLimit * 2) }
    #expect(a.launcher.favorites == b.launcher.favorites)
  }

  /// 两台同时在列表末尾各加一条（搜索、收藏夹）、一台挪顺序一台改名：几轮内两台一样，改名和挪顺序都留下
  @Test func listOrderConvergesAndKeepsBothEdits() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    for (mac, name) in [(a, "a"), (b, "b")] {
      mac.engines.append(
        SearchEngine(
          id: "custom-\(name)", name: name, keyword: name, urlTemplate: "https://\(name)/{query}",
          enabled: false))
      _ = mac.clipboard.createGroup(named: "收藏夹 \(name)")
    }
    await settle([a, b], times: 3)
    #expect(
      a.engines.map(\.id) == b.engines.map(\.id) && a.engines.count == WebSearch.defaults.count + 2)
    #expect(a.clipboard.groups.map(\.name) == b.clipboard.groups.map(\.name))
    // A 把最后一条挪到最前，B 同时给第一条改名
    var reordered = a.engines
    reordered.insert(reordered.removeLast(), at: 0)
    a.engines = reordered
    var renamed = b.engines
    renamed[0].name = "改过名的"
    b.engines = renamed
    await settle([a, b], times: 3)
    #expect(a.engines.map(\.id) == b.engines.map(\.id) && a.engines.first?.id == reordered[0].id)
    #expect(a.engines.contains { $0.name == "改过名的" } && b.engines.contains { $0.name == "改过名的" })
  }

  // MARK: 设置、快捷键、功能开关（全局同步第 5 批）

  /// 设置、快捷键、功能开关传过去；新加入的那台跟着已有的（它改过、对面没有的回到默认）；跟着这台 Mac 的那几项不传；
  /// 一边改回默认，另一边也回到默认
  @Test func settingsFollowTheExistingMacs() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let combo = try JSONDecoder().decode(
      HotKey.self, from: Data(#"{"keyCode":0,"modifiers":2048}"#.utf8))
    a.defaults.set(17, forKey: Prefs.notesFontSize)
    a.defaults.set(false, forKey: Feature.launcher.prefsKey)
    a.defaults.set(HotKeyAction.stored(combo), forKey: HotKeyAction.noteAll.prefsKey)
    a.defaults.set(HotKeyAction.stored(nil), forKey: HotKeyAction.clipboard.prefsKey)
    a.defaults.set(9, forKey: Prefs.launchpadColumns)
    // B 加入之前自己改过：字号跟着 A，Markdown（A 没改过）回到默认
    b.defaults.set(13, forKey: Prefs.notesFontSize)
    b.defaults.set(false, forKey: Prefs.notesMarkdown)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    #expect(await b.syncer.enable(folder: shared) == nil)
    await settle([b, a])
    #expect(b.defaults.integer(forKey: Prefs.notesFontSize) == 17)
    #expect(b.stored(Prefs.notesMarkdown) == nil)
    #expect(b.stored(Feature.launcher.prefsKey) as? Bool == false)
    let received = try b.defaults.data(forKey: HotKeyAction.noteAll.prefsKey).map {
      try JSONDecoder().decode(HotKey.self, from: $0)
    }
    #expect(received == combo)
    #expect(b.defaults.data(forKey: HotKeyAction.clipboard.prefsKey) == Data(), "清除了的也传过去")
    #expect(b.stored(Prefs.launchpadColumns) == nil, "启动台跟着这台 Mac")
    // B 把字号改回默认（删掉这一项）→ A 也回到默认
    b.defaults.removeObject(forKey: Prefs.notesFontSize)
    await settle([b, a])
    #expect(a.stored(Prefs.notesFontSize) == nil)
  }

  /// 一项一项后改的赢，按真正改的时刻：A 先改（记下了改的时刻，之后才合到）、B 后改 → 两边都是 B 的；
  /// 两台各改不同的项，两项都留下
  @Test func settingsLaterChangeWinsPerKey() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    a.defaults.set(20, forKey: Prefs.notesFontSize)
    a.settings.recordChanges()
    try await Task.sleep(for: .milliseconds(30))
    b.defaults.set(13, forKey: Prefs.notesFontSize)
    b.defaults.set(false, forKey: Prefs.notesMarkdown)
    b.settings.recordChanges()
    await b.syncer.round()
    await a.syncer.round()
    await b.syncer.round()
    for mac in [a, b] {
      #expect(mac.defaults.integer(forKey: Prefs.notesFontSize) == 13)
      #expect(mac.stored(Prefs.notesMarkdown) as? Bool == false)
    }
  }

  /// 状态屏的状态一个一条：第一次合两台各自写的都留下；之后两台同时各加一个，两个都留下
  @Test func statusPresetsMerge() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    func add(_ id: String, _ title: String, to mac: Mac) {
      var presets = StatusPreset.load(mac.defaults)
      presets.append(
        StatusPreset(
          id: id, title: title, detail: nil, symbol: "", style: .dim, power: .normal,
          autoEndMinutes: 0))
      StatusPreset.save(presets, to: mac.defaults)
    }
    add("a1", "A 写的", to: a)
    add("b1", "B 写的", to: b)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    #expect(await b.syncer.enable(folder: shared) == nil)
    await settle([b, a])
    add("a2", "A 又加的", to: a)
    add("b2", "B 又加的", to: b)
    await settle([a, b], times: 3)
    for mac in [a, b] {
      let ids = Set(StatusPreset.load(mac.defaults).map(\.id))
      #expect(ids.isSuperset(of: ["clean", "busy", "back", "a1", "b1", "a2", "b2"]))
    }
    #expect(StatusPreset.load(a.defaults) == StatusPreset.load(b.defaults))
  }

  /// 新旧版本混用：这一版不认识的设置原样透传（不落进设置、下一轮原样交回去），这一类照常合；忙着时设置先不合
  @Test func unknownSettingsPassThroughAndBusyWaits() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    // 模拟更新版本：A 交出去一项这一版不认识的（透传），B 收到后也透传、不落进偏好、不停
    let future = "pref:新版本才有的设置"
    a.defaults.set([future: "{\"bool\":{\"_0\":true}}"], forKey: SettingsSync.passthroughKey)
    await settle([a, b])
    #expect(b.settings.syncValues()[future] != nil && b.stored("新版本才有的设置") == nil)
    #expect(b.syncer.status == .idle)
    // 认得的键、这一版落不下的值（新版本放宽了范围）：B 透传着、交出去的也是它，不拿本机的旧值翻回去；B 自己再改才换成 B 的
    let size = "pref:" + Prefs.notesFontSize
    b.defaults.set(15, forKey: Prefs.notesFontSize)
    await settle([b, a])
    a.defaults.set([size: "5000000"], forKey: SettingsSync.passthroughKey)
    await settle([a, b], times: 3)
    #expect(b.settings.syncValues()[size] == "5000000")
    #expect(b.stored(Prefs.notesFontSize) as? Int == 15)
    #expect(a.settings.syncValues()[size] == "5000000")
    b.defaults.set(16, forKey: Prefs.notesFontSize)
    await settle([b, a])
    #expect(a.stored(Prefs.notesFontSize) as? Int == 16 && a.settings.syncValues()[size] == "16")
    #expect(b.settings.syncValues()[size] == "16")
    // B 忙着（正在录屏之类）：设置先不合；不忙了照常合
    b.settings.isBusy = { true }
    a.defaults.set(19, forKey: Prefs.notesFontSize)
    await settle([a, b])
    #expect(b.stored(Prefs.notesFontSize) as? Int == 16)
    b.settings.isBusy = { false }
    await settle([a, b])
    #expect(b.stored(Prefs.notesFontSize) as? Int == 19)
  }

  // MARK: 第三轮体检

  /// 升级判定（R1）：开着同步、设置没合过（没账本）、勾从没存过 = 从只同步便签的版本升上来的——便签之外的几类先不勾、
  /// 存下来、设置页说一句（停止同步不清，看过才清）；少一样都不算
  @Test func detectsMacsUpgradedFromNotesOnlySync() throws {
    let store = try NoteStore(db: Database(path: ":memory:"), wait: { _ in }, host: "a")
    /// 在一个临时偏好域里按 prepare 摆好，起一个同步；交回它和偏好里存下的勾
    func launch(_ prepare: (UserDefaults) -> Void) throws -> (NoteSyncer, [String]?) {
      let name = "kitty-notes-sync-tests-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      defer { defaults.removePersistentDomain(forName: name) }
      prepare(defaults)
      let syncer = NoteSyncer(store: store, defaults: defaults)
      return (syncer, defaults.persistentDomain(forName: name)?[Prefs.syncSkipped] as? [String])
    }
    func syncing(_ defaults: UserDefaults) {
      defaults.set("/tmp/同步", forKey: Prefs.notesSyncFolder)
      defaults.set("库", forKey: Prefs.notesSyncLibrary)
    }
    let kinds = Set(SyncRecords.Kind.allCases.map(\.rawValue))
    let (upgraded, stored) = try launch(syncing)
    #expect(upgraded.upgraded && upgraded.newKindsHint)
    #expect(upgraded.skipped == kinds && upgraded.syncs(NoteSyncer.notesPart))
    #expect(stored.map(Set.init) == kinds)
    // 停止同步不清那句（再开时那几类照旧没勾）；设置页那一节看过了才清
    upgraded.disable()
    #expect(upgraded.newKindsHint)
    upgraded.dismissHint()
    #expect(!upgraded.newKindsHint)
    let others: [(String, (UserDefaults) -> Void, Set<String>)] = [
      ("没开同步", { _ in }, []),
      (
        "设置合过",
        {
          syncing($0)
          $0.set(Data("{}".utf8), forKey: SyncLedger.key(.settings))
        }, []
      ),
      (
        "勾存过（这一版里开的同步）",
        {
          syncing($0)
          $0.set([String](), forKey: Prefs.syncSkipped)
        }, []
      ),
      (
        "勾存过、取消了一类",
        {
          syncing($0)
          $0.set(["clips"], forKey: Prefs.syncSkipped)
        }, ["clips"]
      ),
    ]
    for (label, prepare, skipped) in others {
      let (syncer, _) = try launch(prepare)
      #expect(!syncer.upgraded && !syncer.newKindsHint && syncer.skipped == skipped, "\(label)")
    }
  }

  /// 升级上来的那台（R1）：A 已经在同步设置和片段；B 从只同步便签的版本升上来——第一轮便签照常合，设置不换成 A 的
  /// （不 adopt）、片段也不合；勾上「设置」前要先问（joins），勾上之后才跟着 A；再重开不再当成升级上来的
  @Test func upgradedMacKeepsItsSettingsUntilAsked() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.defaults.set(17, forKey: Prefs.notesFontSize)
    a.clipboard.saveSnippet("A 的片段")
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    // B：0.6.0 时开的同步（文件夹、库编号记着；勾从没存过、设置没有账本），升级后重开
    b.defaults.set(13, forKey: Prefs.notesFontSize)
    b.store.create(body: "B 的便签", now: .now)
    #expect(await b.syncer.enable(folder: shared) == nil)
    b.defaults.removeObject(forKey: Prefs.syncSkipped)
    b.relaunch()
    #expect(b.syncer.upgraded && b.syncer.newKindsHint)
    await settle([b, a])
    #expect(bodies(a) == ["B 的便签"] && b.syncer.status == .idle)
    #expect(b.defaults.integer(forKey: Prefs.notesFontSize) == 13, "设置没被换成 A 的")
    #expect(b.retained["A 的片段"] == nil)
    #expect(a.defaults.integer(forKey: Prefs.notesFontSize) == 17)
    // 勾上「设置」要先问（便签那部分不问）；勾上之后才跟着已经在同步的 A，合过了不再问
    let settings = SyncRecords.Kind.settings.rawValue
    #expect(b.syncer.joins(settings) && !b.syncer.joins(NoteSyncer.notesPart))
    b.syncer.setSyncs(settings, true)
    #expect(!b.syncer.newKindsHint)
    await settle([b, a])
    #expect(b.defaults.integer(forKey: Prefs.notesFontSize) == 17)
    #expect(!b.syncer.joins(settings))
    // 重开：不再当成升级上来的，没勾的照旧没勾；这一版里开的同步（A）重开也不算
    b.relaunch()
    #expect(!b.syncer.upgraded && !b.syncer.syncs(SyncRecords.Kind.clips.rawValue))
    a.relaunch()
    #expect(!a.syncer.upgraded && a.syncer.syncs(settings))
  }

  /// 第一次合不丢本机那条的标记（R8）：A 上只是收藏，B 上同一句是片段、在收藏夹里、带备注——B 第一次合（本机那条被
  /// 去重掉，留文件夹里 A 的那条）后标记都在，再传回 A
  @Test func joiningKeepsTheLocalSnippetAndGroup() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.clipboard.recordOwnText("同一句")
    let favorite = try #require(a.clipboard.items.first { $0.text == "同一句" })
    a.clipboard.toggleFavorite([favorite.id])
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    b.clipboard.saveSnippet("同一句")
    let group = try #require(b.clipboard.createGroup(named: "工作"))
    let snippet = try #require(b.clipboard.items.first { $0.text == "同一句" })
    b.clipboard.assign([snippet.id], to: group.id)
    b.clipboard.update([snippet.id]) { $0.note = "B 的备注" }
    #expect(await b.syncer.enable(folder: shared) == nil)
    await b.syncer.round()
    let all: ((Bool, Bool, String?, String?)?) -> Bool = {
      $0.map { $0.0 && $0.1 && $0.2 == "工作" && $0.3 == "B 的备注" } == true
    }
    #expect(all(b.retained["同一句"]) && b.clipboard.items.count { $0.text == "同一句" } == 1)
    await settle([b, a])
    #expect(all(a.retained["同一句"]))
  }

  /// 别处取消收藏一条生词（B9）：本机开着翻译历史时留成普通历史；关着时整条删（同本机取消收藏）
  @Test func unfavoritedWordIsErasedWhenHistoryIsOff() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    for word in ["kept", "gone"] {
      a.history.setFavorite(source: word, target: .zhHans, result: word, service: "s", true)
    }
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    #expect(b.words == ["gone", "kept"])
    func rows(_ mac: Mac) -> [String] { mac.history.search("", limit: 0).map(\.source).sorted() }
    b.defaults.set(true, forKey: Prefs.translateHistoryEnabled)
    a.history.setFavorite(source: "kept", target: .zhHans, result: "kept", service: "s", false)
    await settle([a, b])
    #expect(b.words == ["gone"] && rows(b) == ["gone", "kept"])
    b.defaults.set(false, forKey: Prefs.translateHistoryEnabled)
    a.history.setFavorite(source: "gone", target: .zhHans, result: "gone", service: "s", false)
    await settle([a, b])
    #expect(b.words.isEmpty && rows(b) == ["kept"])
  }

  /// 一类里有一条是更新版本写的（多了这一版不认识的字段，decodeExact 解不出，B9）：这一类不落，状态说先更新，不说「没存上」
  @Test func newerValueAsksForAnUpdate() async throws {
    try makeShared()
    defer { cleanUp() }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.history.setFavorite(source: "future", target: .zhHans, result: "未来", service: "s", true)
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await a.syncer.round()
    // A 那份生词本里的这条改成更新版本的样子：多一个字段
    let url = shared.appending(path: NoteSyncFolder.devicesName).appending(path: a.store.deviceID)
      .appending(path: SyncRecords.Kind.vocabulary.fileName)
    let data = try Data(contentsOf: url)
    guard case .read(var file) = SyncRecords.file(from: data, kind: .vocabulary),
      let (id, record) = file.records.first,
      var object = try JSONSerialization.jsonObject(with: Data(record.value.utf8)) as? [String: Any]
    else {
      Issue.record("A 那份生词本读不出来")
      return
    }
    object["新版本才有的字段"] = 1
    file.records[id]?.value = String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
    try SyncRecords.data(of: file, kind: .vocabulary).write(to: url)
    await b.syncer.round()
    #expect(b.syncer.status == .stopped(.newerFormat) && b.words.isEmpty)
  }

  // MARK: 没变的部分跳过（第三轮体检第 6 批）

  /// 文件夹里的文件都拨到同一个旧时刻（刚写的文件不算数：离读的时候不到 2 秒）；同一个时刻拨两遍，没变的文件属性一样
  private func age(to past: Date) throws {
    let files = FileManager.default.enumerator(at: shared, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    }
  }

  /// 两台都合好了、文件都旧了：再合一轮每一部分都跳过；对面改了文件、本机改了便签 / 片段 / 设置，那一部分照常合、照常写出去
  @Test func unchangedPartsAreSkippedButChangesStillTravel() async throws {
    try makeShared()
    defer { cleanUp() }
    let past = Date.now.addingTimeInterval(-3600)
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let note = a.store.create(body: "一", now: .now)
    a.clipboard.saveSnippet("片段")
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    try age(to: past)
    await settle([a, b])
    let all = Set([NoteSyncer.notesPart] + SyncRecords.Kind.allCases.map(\.rawValue))
    #expect(a.syncer.skippedParts == all && b.syncer.skippedParts == all)
    #expect(a.syncer.status == .idle)
    // 对面改了一条便签（换了一个文件；拨到同一个旧时刻，只有它的文件号、大小变了）
    b.store.setBody("一二", of: note.id, now: .now.addingTimeInterval(5))
    await b.syncer.round()
    try age(to: past)
    await a.syncer.round()
    #expect(!a.syncer.skippedParts.contains(NoteSyncer.notesPart))
    #expect(a.syncer.skippedParts.contains(SyncRecords.Kind.clips.rawValue))
    #expect(a.store.note(note.id)?.body == "一二")
    await settle([a, b])
    try age(to: past)
    await settle([a, b])
    #expect(a.syncer.skippedParts == all)
    // 本机改了：便签、片段、设置各自不跳过，传到对面
    a.store.setBody("一二三", of: note.id, now: .now.addingTimeInterval(10))
    a.clipboard.saveSnippet("新片段")
    a.defaults.set(19, forKey: Prefs.notesFontSize)
    await a.syncer.round()
    #expect(a.syncer.skippedParts.isDisjoint(with: ["notes", "clips", "settings"]))
    await b.syncer.round()
    #expect(b.store.note(note.id)?.body == "一二三" && b.retained["新片段"] != nil)
    #expect(b.defaults.integer(forKey: Prefs.notesFontSize) == 19)
  }

  /// 时间机器把账本 / 库里记的第几轮退回去了（本机的值、文件夹都没变）：那一部分不跳过——片段的账本追上，便签认出退回去了
  @Test func rolledBackLedgerOrEpochIsNotSkipped() async throws {
    try makeShared()
    defer { cleanUp() }
    let past = Date.now.addingTimeInterval(-3600)
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let note = a.store.create(body: "一", now: .now)
    a.clipboard.saveSnippet("片段")
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    let library = try #require(a.syncer.library)
    let old = try #require(try SyncLedger.load(.clips, library: library, in: a.kitty))
    a.clipboard.saveSnippet("后加的片段")
    a.store.setBody("一二", of: note.id, now: .now.addingTimeInterval(5))
    await settle([a, b])
    let epoch = try #require(try a.store.meta(NoteSyncer.epochKey))
    try age(to: past)
    await settle([a, b])
    #expect(a.syncer.skippedParts.contains(SyncRecords.Kind.clips.rawValue))
    let current = try SyncLedger.load(.clips, library: library, in: a.kitty)
    #expect(current != old)
    // 账本退回去：本机的值、文件夹都没变，只有账本是旧的
    try a.kitty.transaction {
      try SyncLedger.save(old, kind: .clips, library: library, in: a.kitty)
    }
    await a.syncer.round()
    #expect(!a.syncer.skippedParts.contains(SyncRecords.Kind.clips.rawValue))
    #expect(try SyncLedger.load(.clips, library: library, in: a.kitty) != old)
    #expect(a.syncer.status == .idle && b.retained["后加的片段"] != nil)
    // 库里记的第几轮退回去：便签不跳过，认出库被退回去了、换编号
    try age(to: past)
    await settle([a, b])
    #expect(a.syncer.skippedParts.contains(NoteSyncer.notesPart))
    let device = a.store.deviceID
    try a.store.setMeta(NoteSyncer.epochKey, String((Int(epoch) ?? 1) - 1))
    await a.syncer.round()
    #expect(!a.syncer.skippedParts.contains(NoteSyncer.notesPart) && a.store.deviceID != device)
    // 换了编号：别的几类也不跳过，这一轮就写进新编号的子文件夹
    #expect(a.syncer.skippedParts.isEmpty)
    let mine = shared.appending(path: NoteSyncFolder.devicesName).appending(path: a.store.deviceID)
    #expect(
      FileManager.default.fileExists(
        atPath: mine.appending(path: SyncRecords.Kind.clips.fileName).path))
  }

  /// 没开同步时改设置：从没合过（没有设置的账本）的不记；合过、停了同步的照记改的那一刻，重启（新的一份 SettingsSync）、
  /// 过一会儿再开同步后还是那一刻——不当成刚改的，翻不掉别的 Mac 后来改的
  @Test func settingsChangedWhileOffKeepTheirTime() async throws {
    try makeShared()
    defer { cleanUp() }
    let fresh = try Mac(host: "b", root: root)
    fresh.defaults.set(21, forKey: Prefs.notesFontSize)
    for _ in 0..<3 { await Task.yield() }
    #expect(fresh.defaults.dictionary(forKey: SettingsSync.timesKey) == nil)
    let a = try Mac(host: "a", root: root)
    #expect(await a.syncer.enable(folder: shared) == nil)
    await a.syncer.round()
    #expect(a.defaults.object(forKey: SyncLedger.key(.settings)) != nil)
    a.syncer.disable()
    let key = "pref:" + Prefs.notesFontSize
    func stamp() -> Int64? {
      (a.defaults.dictionary(forKey: SettingsSync.timesKey)?[key] as? NSNumber)?.int64Value
    }
    let before = Note.milliseconds(.now)
    a.defaults.set(21, forKey: Prefs.notesFontSize)
    for _ in 0..<3 { await Task.yield() }
    let after = Note.milliseconds(.now)
    let changed = try #require(stamp())
    #expect(changed >= before && changed <= after)
    try await Task.sleep(for: .milliseconds(200))
    let restarted = SettingsSync(defaults: a.defaults, domainName: a.suite)
    a.relaunch()
    #expect(await a.syncer.enable(folder: shared) == nil)
    for _ in 0..<3 { await Task.yield() }
    #expect(stamp() == changed && restarted.syncChanged()[key] == changed)
  }

  /// 只换了写法的改动（合成的 é → e + 组合重音）：没变的几轮跳过之后照样认出来、发出去（按字节比，不按 String 的 ==）
  @Test func normalizationOnlyEditsStillTravel() async throws {
    try makeShared()
    defer { cleanUp() }
    let past = Date.now.addingTimeInterval(-3600)
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    a.clipboard.saveSnippet("caf\u{E9}")
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b])
    try age(to: past)
    await settle([a, b])
    #expect(a.syncer.skippedParts.contains(SyncRecords.Kind.clips.rawValue))
    let id = try #require(a.clipboard.items.first { $0.isSnippet }?.id)
    a.clipboard.update([id]) { $0.text = "cafe\u{301}" }
    await a.syncer.round()
    #expect(!a.syncer.skippedParts.contains(SyncRecords.Kind.clips.rawValue))
    await b.syncer.round()
    let text = try #require(b.clipboard.items.first { $0.isSnippet }?.text)
    #expect(Array(text.utf8) == Array("cafe\u{301}".utf8))
  }
}
