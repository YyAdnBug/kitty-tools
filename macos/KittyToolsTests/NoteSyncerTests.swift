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
    let syncer: NoteSyncer
    let suite: String
    let defaults: UserDefaults
    /// 剪贴板库（片段、收藏）和翻译历史（生词本）：同一个内存库，同 App 里的 kitty.sqlite3
    let kitty: Database
    let clipboard: ClipboardStore
    let history: HistoryStore
    var editing: Set<String> = []
    var featuresOff: Set<String> = []

    init(host: String, root: URL, file: URL? = nil) throws {
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
      syncer.sources = [clipboard, history]
      syncer.computerName = { host }
      syncer.editing = { [unowned self] in editing }
      syncer.featureOn = { [unowned self] in !featuresOff.contains($0) }
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
    for mac in [a, b] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    await settle([a, b], times: 3)
    func stamps(_ mac: Mac) throws -> [Date?] {
      try ["clips", "vocabulary"].map { kind in
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
}
