// 便签的数据保险（Notes/NotesBackup.swift）单测。
// 备份：文件夹名和日期互转；每天一个文件夹（库 + 图片目录），留最近 7 份；同一天不重复备、不改已有的；空表不备；
// 库坏了不备、也不动已有的备份；没备成不留半成品；有图片拷不成不让这份备份作废；备份里的库读得回来、旁边没有
// -wal / -shm。
// 打不开时：三个选择各挪了什么、没挪什么——用备份（坏库连 -wal、-shm 挪开，图片留在原地另留一份，备份里有、原地没有的
// 图片补回来）、重新开始（库、图片、备份一起挪开）、这次先不用（什么都不动）；只问一次；库文件不见了 / 成了空文件而备份
// 文件夹还在（哪怕都读不出来）也要问；好好的库和还没用过便签的不问；更新版本写的库不问也不动；每日 JSON 备份里带着便签
// 文字时弹框多一段；弹框和说明的文字。
// 两头各锁一个：便签的流程不碰剪贴板的文件，剪贴板的「重新开始」不挪便签的三样。
// 只用临时目录，不碰真实数据目录；日期都是传进去的固定值，不看墙上时钟。

import Foundation
import Testing

@testable import KittyTools

struct NotesBackupTests {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "kitty-notes-backup-tests-\(UUID().uuidString)")
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    return calendar
  }()
  let manager = FileManager.default
  var database: URL { directory.appending(path: NotesBackup.databaseName) }
  var images: URL { directory.appending(path: NotesBackup.imagesName) }

  // MARK: 小工具

  /// 2026 年的某一刻（上面那个时区）
  private func at(
    _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0
  ) -> Date {
    calendar.date(
      from: DateComponents(
        year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))
      ?? .distantPast
  }

  /// 那天的备份文件夹
  private func backup(_ month: Int, _ day: Int) -> URL {
    NotesBackup.folder(in: directory).appending(
      path: NotesBackup.name(for: at(month, day), calendar: calendar))
  }

  private func run(_ month: Int, _ day: Int, _ hour: Int = 12) async -> NotesBackup.Outcome {
    await NotesBackup.run(in: directory, now: at(month, day, hour), calendar: calendar)
  }

  /// 开便签库（走真的仓库：开库、认版本、建表、读表）
  private func openStore() throws -> NoteStore {
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return try NoteStore(db: Database(path: database.path))
  }

  /// 库文件（或备份里的库）里的便签正文
  private func bodies(in url: URL) throws -> Set<String> {
    Set(
      try Database(path: url.path, readOnly: true).query("SELECT body FROM notes") { $0.text(0) }
        .compactMap { $0 })
  }

  private func put(_ path: String, _ content: String) throws {
    let url = directory.appending(path: path)
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  /// 目录里所有文件的相对路径和内容：比「一个字节都没动」用
  private func snapshot(of folder: URL) -> [String: Data] {
    var files: [String: Data] = [:]
    let enumerator = manager.enumerator(
      at: folder, includingPropertiesForKeys: [.isRegularFileKey],
      options: [.producesRelativePathURLs])
    while let url = enumerator?.nextObject() as? URL {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        continue
      }
      files[url.relativePath] = try? Data(contentsOf: url)
    }
    return files
  }

  /// 把库文件头写成垃圾（连接都关了之后；-wal、-shm 一起删，不然 sqlite 会拿 -wal 把它修好）
  private func damage() throws {
    for suffix in ["-wal", "-shm"] { try? manager.removeItem(atPath: database.path + suffix) }
    let handle = try FileHandle(forUpdating: database)
    defer { try? handle.close() }
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(repeating: 0xA5, count: 4096))
  }

  /// 造一套便签：「买菜」「周报」，10 月 1 日备份一次，之后再记一条「备份后」；图片目录里一张图。
  /// 仓库不接就是关掉了（连接跟着放掉）
  @discardableResult private func seed(backedUp: Bool = true) async throws -> NoteStore {
    let store = try openStore()
    store.create(body: "买菜")
    store.create(body: "周报")
    try put("notes-images/a.png", "图 A")
    if backedUp {
      #expect(await run(10, 1) == .made(backup(10, 1)))
      store.create(body: "备份后")
    }
    return store
  }

  /// 剪贴板那边的三样（假的内容：便签的流程不该碰它们）
  private func seedClipboardFiles() throws -> [String: Data] {
    try put("kitty.sqlite3", "剪贴板的库")
    try put("kitty.sqlite3-wal", "剪贴板的日志")
    try put("images/clip.png", "剪贴板的图")
    try put("backups/kitty-2026-10-01.sqlite3", "剪贴板的备份")
    try put("backups/Kitty Tools 自动备份 2026-10-01.json", "设置的备份")
    return snapshot(of: directory).filter {
      $0.key.hasPrefix("kitty.") || $0.key.hasPrefix("images/") || $0.key.hasPrefix("backups/")
    }
  }

  private func clipboardFiles() -> [String: Data] {
    snapshot(of: directory).filter {
      $0.key.hasPrefix("kitty.") || $0.key.hasPrefix("images/") || $0.key.hasPrefix("backups/")
    }
  }

  /// 走一遍打开流程，用户选 choice。返回打开的仓库（或者为什么不可用）和问了什么
  private func recover(
    _ choice: NotesRecovery.Choice, at now: Date? = nil,
    open: (() throws -> NoteStore)? = nil
  ) -> (result: Result<NoteStore, NotesRecovery.Failure>, asked: [NotesRecovery.Problem]) {
    var asked: [NotesRecovery.Problem] = []
    do {
      let store = try NotesRecovery.open(
        in: directory, now: now ?? at(10, 3, 9, 5, 7), calendar: calendar,
        open: open ?? { try NoteStore(db: Database(path: database.path)) },
        ask: { problem in
          asked.append(problem)
          return choice
        })
      return (.success(store), asked)
    } catch {
      return (.failure(error), asked)
    }
  }

  // MARK: 备份

  @Test func namesAndDaysRoundTrip() {
    let moment = at(10, 2, 23, 59, 59)
    #expect(NotesBackup.name(for: moment, calendar: calendar) == "notes-2026-10-02")
    #expect(
      NotesBackup.day(of: "notes-2026-10-02", calendar: calendar)
        == calendar.startOfDay(for: moment))
    for other in [
      "notes.sqlite3", "notes.partial", "notes-2026-10-2", "notes-2026-10-02.zip",
      "kitty-2026-10-02.sqlite3", "notes-images",
    ] {
      #expect(NotesBackup.day(of: other, calendar: calendar) == nil)
    }
    #expect(NotesBackup.folder(in: directory).lastPathComponent == "notes-backups")
  }

  /// 备一份：文件夹里是整库（连「最近删除」里的，刚写的还在 WAL 里也带得上）和图片目录；同一天再跑不重复备、
  /// 不改已有的；备份里的库读得回来、版本号跟着、旁边没有 -wal / -shm；上次留下的半成品先清掉
  @Test func backsUpTheDatabaseAndImages() async throws {
    defer { try? manager.removeItem(at: directory) }
    // 还没有库：没什么可备的，也不建备份目录
    #expect(await run(10, 1) == .damaged)
    #expect(!manager.fileExists(atPath: directory.path))

    let store = try openStore()
    let kept = store.create(body: "买菜")
    let trashed = store.create(body: "删掉的")
    store.delete(trashed.id)
    try put("notes-images/a.png", "图 A")
    try put("notes-images/b.png", "图 B")
    try put("notes-backups/notes.partial/notes.sqlite3", "上次留下的")
    #expect(NotesBackup.isDue(in: directory, now: at(10, 1), calendar: calendar))
    #expect(await run(10, 1) == .made(backup(10, 1)))
    #expect(!NotesBackup.isDue(in: directory, now: at(10, 1, 23), calendar: calendar))
    #expect(
      snapshot(of: NotesBackup.folder(in: directory)).keys.sorted() == [
        "notes-2026-10-01/images/a.png", "notes-2026-10-01/images/b.png",
        "notes-2026-10-01/notes.sqlite3",
      ])
    let copy = NotesBackup.Copy(url: backup(10, 1), day: calendar.startOfDay(for: at(10, 1)))
    #expect(NotesBackup.list(in: directory, calendar: calendar) == [copy])
    #expect(try bodies(in: copy.database) == ["买菜", "删掉的"])
    #expect(try Data(contentsOf: copy.images.appending(path: "a.png")) == Data("图 A".utf8))
    #expect(
      try Database(path: copy.database.path, readOnly: true).query("PRAGMA user_version") {
        $0.int(0)
      } == [Int64(NoteStore.schemaVersion)])
    #expect(NotesBackup.latestUsable(in: directory, calendar: calendar) == copy)
    #expect(snapshot(of: NotesBackup.folder(in: directory)).count == 3)

    // 同一天再来：不备，已有的一个字节都不动（看过它能不能用之后旁边也没多出 -wal / -shm）
    store.setBody("买菜，还有牛奶", of: kept.id)
    #expect(store.flush())
    let before = snapshot(of: NotesBackup.folder(in: directory))
    #expect(await run(10, 1, 18) == .notDue)
    #expect(snapshot(of: NotesBackup.folder(in: directory)) == before)
    // 第二天：新的一份里是改过的
    #expect(await run(10, 2) == .made(backup(10, 2)))
    #expect(try bodies(in: backup(10, 2).appending(path: "notes.sqlite3")).contains("买菜，还有牛奶"))
    #expect(try bodies(in: copy.database) == ["买菜", "删掉的"])
  }

  /// 一条便签都没有：不备（没用过便签的人不该每天多一个空文件夹）；图片目录没有东西时备份里没有 images
  @Test func emptyStoreIsNotBackedUp() async throws {
    defer { try? manager.removeItem(at: directory) }
    let store = try openStore()
    #expect(await run(10, 1) == .empty)
    #expect(!manager.fileExists(atPath: NotesBackup.folder(in: directory).path))
    #expect(NotesBackup.isDue(in: directory, now: at(10, 1), calendar: calendar))

    store.create(body: "第一条")
    try manager.createDirectory(at: images, withIntermediateDirectories: true)
    #expect(await run(10, 1) == .made(backup(10, 1)))
    #expect(
      snapshot(of: NotesBackup.folder(in: directory)).keys.sorted()
        == ["notes-2026-10-01/notes.sqlite3"])
    #expect(try manager.contentsOfDirectory(atPath: backup(10, 1).path) == ["notes.sqlite3"])
  }

  /// 每天一份、留最近 7 份；时钟调到过未来时备的那几份先被轮换掉，今天这份不会被顶掉
  @Test func keepsSevenNewest() async throws {
    defer { try? manager.removeItem(at: directory) }
    let store = try openStore()
    for day in 1...9 {
      store.create(body: "第 \(day) 天")
      #expect(await run(10, day) == .made(backup(10, day)))
      #expect(NotesBackup.list(in: directory, calendar: calendar).count == min(day, 7))
    }
    #expect(
      NotesBackup.list(in: directory, calendar: calendar).map(\.url.lastPathComponent)
        == (3...9).reversed().map { String(format: "notes-2026-10-%02d", $0) })
    #expect(try bodies(in: backup(10, 3).appending(path: "notes.sqlite3")).count == 3)
    #expect(NotesBackup.keep == 7)

    // 钟拨回 9 月 30 日：10 月的七份都比「现在」晚。今天这份照样留下，被删的是那些里最早的
    #expect(await run(9, 30) == .made(backup(9, 30)))
    let names = NotesBackup.list(in: directory, calendar: calendar).map(\.url.lastPathComponent)
    #expect(names.count == 7 && names.contains("notes-2026-09-30"))
    #expect(!names.contains("notes-2026-10-03") && names.contains("notes-2026-10-09"))
  }

  /// 库坏了：不备，已有的备份一个字节都不动，也不留半成品
  @Test func damagedDatabaseIsNotBackedUp() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    try damage()
    let before = snapshot(of: NotesBackup.folder(in: directory))
    #expect(await run(10, 2) == .damaged)
    #expect(snapshot(of: NotesBackup.folder(in: directory)) == before)
    #expect(NotesBackup.isDue(in: directory, now: at(10, 2), calendar: calendar))
    // 没有 notes 表的库（别的东西占了这个名字）同样不备
    try manager.removeItem(at: database)
    try Database(path: database.path).execute("CREATE TABLE other(id INTEGER)")
    #expect(await run(10, 2) == .damaged)
    #expect(snapshot(of: NotesBackup.folder(in: directory)) == before)
  }

  /// 图片尽力而为：有一张读不了的图，备份照样算备好——库在里面，拷得成的图也在，只缺那一张
  @Test func unreadableImageDoesNotVoidTheBackup() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    let locked = images.appending(path: "c.png")
    try put("notes-images/b.png", "图 B")
    try put("notes-images/c.png", "图 C")
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

    #expect(await run(10, 2) == .made(backup(10, 2)))

    #expect(
      Set(try manager.contentsOfDirectory(atPath: backup(10, 2).appending(path: "images").path))
        == ["a.png", "b.png"])
    #expect(
      try bodies(in: backup(10, 2).appending(path: "notes.sqlite3")) == ["买菜", "周报", "备份后"])
    #expect(!NotesBackup.isDue(in: directory, now: at(10, 2), calendar: calendar))
    #expect(
      Set(try manager.contentsOfDirectory(atPath: NotesBackup.folder(in: directory).path))
        == ["notes-2026-10-01", "notes-2026-10-02"])
  }

  /// 没备成（这里是备份目录写不进去）：算失败，半成品不留在磁盘上，已有的备份不动，下次还会再试
  @Test func failedBackupLeavesNothingBehind() async throws {
    defer { try? manager.removeItem(at: directory) }
    let store = try await seed()
    let folder = NotesBackup.folder(in: directory)
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    let before = snapshot(of: folder)

    let outcome = await run(10, 2)

    guard case .failed = outcome else {
      Issue.record("应该没备成：\(outcome)")
      return
    }
    #expect(snapshot(of: folder) == before)
    #expect(try manager.contentsOfDirectory(atPath: folder.path) == ["notes-2026-10-01"])
    #expect(NotesBackup.isDue(in: directory, now: at(10, 2), calendar: calendar))
    // 修好之后同一天再来就成了
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    #expect(await run(10, 2, 18) == .made(backup(10, 2)))
    #expect(store.notes.count == 3)
  }

  /// 挑备份：最新的那份坏了、或者是更新版本的 Kitty Tools 写的，就往前找；挑的时候只读，什么都不改
  @Test func latestUsableSkipsBrokenAndNewerCopies() async throws {
    defer { try? manager.removeItem(at: directory) }
    let store = try await seed()
    #expect(await run(10, 2) == .made(backup(10, 2)))
    #expect(await run(10, 3) == .made(backup(10, 3)))
    #expect(store.notes.count == 3)
    try Data("不是数据库".utf8).write(to: backup(10, 3).appending(path: "notes.sqlite3"))
    try Database(path: backup(10, 2).appending(path: "notes.sqlite3").path, wal: false).execute(
      "PRAGMA user_version = \(NoteStore.schemaVersion + 1)")
    let before = snapshot(of: NotesBackup.folder(in: directory))
    #expect(NotesBackup.latestUsable(in: directory, calendar: calendar)?.url == backup(10, 1))
    #expect(snapshot(of: NotesBackup.folder(in: directory)) == before)
    #expect(NotesBackup.list(in: directory, calendar: calendar).count == 3)
  }

  // MARK: 打不开时

  /// 好好的库、还没用过便签（没有库也没有备份）：不问，照常打开；什么都不挪
  @Test func healthyAndFirstRunAreNotAsked() async throws {
    defer { try? manager.removeItem(at: directory) }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var (result, asked) = recover(.startFresh)
    #expect(try result.get().notes.isEmpty && asked.isEmpty)
    try await seed()
    (result, asked) = recover(.startFresh)
    #expect(try result.get().notes.count == 3 && asked.isEmpty)
    #expect(
      try manager.contentsOfDirectory(atPath: directory.path).allSatisfy {
        !$0.hasPrefix("damaged")
      })
  }

  /// 用备份：坏库原样挪进 damaged-…/，图片留在原地、另留一份进去，备份留在 notes-backups/；再打开读到的是备份那天的
  /// 便签，照常能写；只问一次；剪贴板的文件一个字节都没动。（-wal、-shm 一起挪走在 notesSetAsideMovesOnlyNotesFiles 里
  /// 核对：真的库旁边放假的 -wal，sqlite 第一次打开时自己就会动它，没法在这里比内容）
  @Test func restoreBringsBackTheBackup() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    let clipboard = try seedClipboardFiles()
    try damage()
    let damaged = try Data(contentsOf: database)
    let backups = snapshot(of: NotesBackup.folder(in: directory))

    let (result, asked) = recover(.restore)

    let store = try result.get()
    #expect(asked.count == 1)
    #expect(
      asked.first?.backup
        == NotesBackup.Copy(url: backup(10, 1), day: calendar.startOfDay(for: at(10, 1))))
    #expect(asked.first?.reason.isEmpty == false && asked.first?.lost == false)
    #expect(Set(store.notes.map(\.body)) == ["买菜", "周报"])
    store.create(body: "恢复后")
    #expect(try bodies(in: database) == ["买菜", "周报", "恢复后"])

    let aside = snapshot(of: directory.appending(path: "damaged-20261003-090507"))
    #expect(aside == ["notes.sqlite3": damaged, "notes-images/a.png": Data("图 A".utf8)])
    #expect(snapshot(of: images) == ["a.png": Data("图 A".utf8)])
    #expect(snapshot(of: NotesBackup.folder(in: directory)) == backups)
    #expect(!manager.fileExists(atPath: database.path + ".restoring"))
    #expect(clipboardFiles() == clipboard)
  }

  /// 用备份时：备份里有、图片目录里没有的图片补回来；原地已有的不覆盖
  @Test func restoreFillsInMissingImages() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    try put("notes-images/b.png", "图 B")
    #expect(await run(10, 2) == .made(backup(10, 2)))
    // 备份之后：a 被改了、b 没了、多了一张 c
    try put("notes-images/a.png", "改过的图 A")
    try manager.removeItem(at: images.appending(path: "b.png"))
    try put("notes-images/c.png", "图 C")
    try damage()

    let (result, _) = recover(.restore)

    #expect(try result.get().notes.count == 3)
    #expect(
      snapshot(of: images) == [
        "a.png": Data("改过的图 A".utf8), "b.png": Data("图 B".utf8), "c.png": Data("图 C".utf8),
      ])
  }

  /// 用备份时图片目录整个不见了：照备份里的建回来
  @Test func restoreRebuildsALostImagesFolder() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: database.path + suffix) }
    try manager.removeItem(at: images)

    let (result, asked) = recover(.restore)

    #expect(asked.first?.lost == true)
    #expect(Set(try result.get().notes.map(\.body)) == ["买菜", "周报"])
    #expect(snapshot(of: images) == ["a.png": Data("图 A".utf8)])
    // 没有东西可挪开：不建 damaged 文件夹
    #expect(
      try manager.contentsOfDirectory(atPath: directory.path).allSatisfy {
        !$0.hasPrefix("damaged")
      })
  }

  /// 重新开始：库、图片目录、备份目录一起挪进 damaged-…/（内容不变、不删），便签从空的开始；剪贴板的文件不动
  @Test func startFreshMovesTheThreeAside() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    let clipboard = try seedClipboardFiles()
    try damage()
    let damaged = try Data(contentsOf: database)
    let backups = snapshot(of: NotesBackup.folder(in: directory))

    let (result, asked) = recover(.startFresh)

    let store = try result.get()
    #expect(asked.count == 1 && store.notes.isEmpty)
    let aside = directory.appending(path: "damaged-20261003-090507")
    #expect(try Data(contentsOf: aside.appending(path: "notes.sqlite3")) == damaged)
    #expect(snapshot(of: aside.appending(path: "notes-images")) == ["a.png": Data("图 A".utf8)])
    #expect(snapshot(of: aside.appending(path: "notes-backups")) == backups)
    #expect(!manager.fileExists(atPath: images.path))
    #expect(!manager.fileExists(atPath: NotesBackup.folder(in: directory).path))
    #expect(NotesBackup.list(in: directory, calendar: calendar).isEmpty)
    #expect(clipboardFiles() == clipboard)
    // 新的空库照常能用
    store.create(body: "从头再来")
    #expect(try bodies(in: database) == ["从头再来"])
  }

  /// 这次先不用：什么都不动；没有备份时选「用备份」同样什么都不动
  @Test func skippingTouchesNothing() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    _ = try seedClipboardFiles()
    try damage()
    let before = snapshot(of: directory)
    let (result, asked) = recover(.skip)
    #expect(result.failure == .skipped && asked.count == 1)
    #expect(snapshot(of: directory) == before)

    try manager.removeItem(at: NotesBackup.folder(in: directory))
    let bare = snapshot(of: directory)
    let (again, problems) = recover(.restore)
    #expect(again.failure == .skipped && problems.first?.backup == nil)
    #expect(snapshot(of: directory) == bare)
  }

  /// 用备份 / 重新开始之后还是打不开：只问一次，当成这次先不用（带原因），不循环
  @Test func stillBrokenAfterRecoveryIsNotAskedAgain() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    try damage()
    var opened = 0
    let (result, asked) = recover(.startFresh) {
      opened += 1
      throw Database.Failure(description: "磁盘坏了")
    }
    #expect(opened == 2 && asked.count == 1)
    #expect(result.failure == .stillBroken("磁盘坏了"))
    // 出问题的文件已经挪开留着了
    #expect(
      manager.fileExists(atPath: directory.appending(path: "damaged-20261003-090507").path))
  }

  /// 库文件不见了 / 成了空文件，而备份还在：不能悄悄建一个空库，要问（没打开过就问）；一个备份文件夹都没有时照常新建
  @Test(arguments: [true, false]) func lostDatabaseAsksWhenBackupsExist(_ empties: Bool)
    async throws
  {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: database.path + suffix) }
    if empties { try Data().write(to: database) }
    var opened = 0
    do {
      let (result, asked) = recover(.restore) {
        opened += 1
        return try NoteStore(db: Database(path: database.path))
      }
      #expect(opened == 1 && asked.count == 1)
      #expect(asked.first?.lost == true)
      #expect(asked.first?.reason == (empties ? "便签的数据库文件是空的" : "便签的数据库文件不见了"))
      #expect(Set(try result.get().notes.map(\.body)) == ["买菜", "周报"])
    }

    // 没有备份：是还没用过便签，不问
    for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: database.path + suffix) }
    try manager.removeItem(at: NotesBackup.folder(in: directory))
    let (result, asked) = recover(.skip)
    #expect(try result.get().notes.isEmpty && asked.isEmpty)
  }

  /// 库是更新版本的 Kitty Tools 写的：不问、什么都不动，这次不可用，说法里有原因
  @Test func newerDatabaseIsLeftAlone() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    try Database(path: database.path).execute(
      "PRAGMA user_version = \(NoteStore.schemaVersion + 1)")
    // sqlite 自己的 -wal / -shm 开关连接时会变，不算
    let files = {
      snapshot(of: directory).filter { !$0.key.hasSuffix("-wal") && !$0.key.hasSuffix("-shm") }
    }
    let before = files()
    let (result, asked) = recover(.startFresh)
    #expect(asked.isEmpty)
    guard case .newer(let reason)? = result.failure else {
      Issue.record("应该是更新版本写的：\(result)")
      return
    }
    #expect(reason.contains("更新版本的 Kitty Tools"))
    #expect(files() == before)
    #expect(try bodies(in: database) == ["买菜", "周报", "备份后"])
    // 这种不弹框，用刘海岛说：一行放得下的话，完整的原因留在错误里（进日志）
    let notice = try #require(NotesRecovery.notice(for: .newer(reason), directory: directory))
    #expect(notice.title == "便签这次用不了" && notice.text == "数据是更新版本写的，更新后照常可用")
    #expect(notice.text.count <= 22)
    #expect("\(NotesRecovery.Failure.newer(reason))" == reason)
  }

  /// 库文件不见了 / 成了空文件，备份文件夹还在但都读不出来（更新版本写的、坏了的）：同样是「用过便签、库没了」，
  /// 要问，不能当成全新安装悄悄建空库；这时没有「用备份」可选
  @Test(arguments: [true, false]) func lostDatabaseAsksEvenWhenNoBackupIsReadable(_ newer: Bool)
    async throws
  {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    let copy = backup(10, 1).appending(path: "notes.sqlite3")
    if newer {
      try Database(path: copy.path, wal: false).execute(
        "PRAGMA user_version = \(NoteStore.schemaVersion + 1)")
    } else {
      try Data("不是数据库".utf8).write(to: copy)
    }
    for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: database.path + suffix) }
    #expect(NotesBackup.latestUsable(in: directory, calendar: calendar) == nil)
    let before = snapshot(of: directory)

    // 先不用：什么都不动，没有悄悄建出一个空库
    var opened = 0
    let (skipped, asked) = recover(.skip) {
      opened += 1
      return try NoteStore(db: Database(path: database.path))
    }
    #expect(skipped.failure == .skipped && opened == 0)
    #expect(asked.count == 1 && asked.first?.lost == true && asked.first?.backup == nil)
    #expect(snapshot(of: directory) == before)
    #expect(!manager.fileExists(atPath: database.path))
    let problem = try #require(asked.first)
    #expect(
      NotesRecovery.wording(for: problem, directory: directory, calendar: calendar).choices
        == [.startFresh, .skip])

    // 重新开始：读不出来的备份跟着挪开留着，便签从空的开始
    let (fresh, again) = recover(.startFresh)
    #expect(try fresh.get().notes.isEmpty && again.count == 1)
    let aside = directory.appending(path: "damaged-20261003-090507")
    #expect(
      manager.fileExists(atPath: aside.appending(path: "notes-backups/notes-2026-10-01").path))
    #expect(NotesBackup.list(in: directory, calendar: calendar).isEmpty)
  }

  // MARK: 每日 JSON 备份里的便签

  /// backups/ 里的每日 JSON 备份（设置与数据的自动备份）带着便签文字时，打不开的弹框多一段：重新开始之后怎么从那一份
  /// 导回来。挑的是最近一份里面真有便签的（最新那份没有便签——那天便签用不了——就往前找）；读不出来的、别的文件不算；
  /// 只读，不动那个文件夹
  @Test func problemPointsAtNotesInTheDailySettingsBackup() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    try damage()
    let folder = Backup.folder(in: directory)
    #expect(NotesRecovery.exportedNotes(in: directory, calendar: calendar) == nil)

    func store(_ day: Int, notes: [String]?) throws {
      var archive = SettingsArchive(version: "9.9.9", exportedAt: at(10, day))
      archive.hotkeys = [:]
      archive.notes = notes.map { bodies in
        bodies.enumerated().map { index, body in
          SettingsArchive.NoteEntry(
            id: String(format: "%08X-0000-4000-8000-000000000000", day * 100 + index), title: "",
            body: body, color: 0, createdAt: 0, modifiedAt: 0, revision: 0, archived: false,
            pinned: false, order: 0)
        }
      }
      try SettingsBackup.store(
        archive.encoded(), kind: .daily, in: folder, creates: true, now: at(10, day),
        calendar: calendar)
    }
    try store(1, notes: ["买菜", "周报"])
    try store(2, notes: ["买菜", "周报", "后来的"])
    try store(3, notes: nil)  // 那天便签用不了：没有这一类
    try store(4, notes: [])  // 一条都没有
    try put("backups/Kitty Tools 自动备份 2026-10-05.json", "不是 JSON")
    try put("backups/Kitty Tools 导入前 2026-10-05 090000.json", "也不算")
    let before = snapshot(of: folder)

    let exported = NotesRecovery.Problem.Exported(
      day: calendar.startOfDay(for: at(10, 2)), count: 3)
    #expect(NotesRecovery.exportedNotes(in: directory, calendar: calendar) == exported)
    let (result, asked) = recover(.skip, at: at(10, 6, 9))
    #expect(result.failure == .skipped && asked.first?.exported == exported)
    #expect(snapshot(of: folder) == before)

    let problem = try #require(asked.first)
    let wording = NotesRecovery.wording(
      for: problem, directory: directory, now: at(10, 6, 9), calendar: calendar)
    #expect(
      wording.text.contains(
        "选了重新开始，便签的文字之后还能导回来：到 设置 › 通用 点「从备份恢复」，选 10 月 2 日（4 天前）那份，"
          + "只勾「便签」（3 条；图片和「最近删除」里的不在里面）。"))
    // 这一段在「挪开的文件在哪」和「原因」之间
    let parts = wording.text.components(separatedBy: "\n\n")
    #expect(parts.count == 5 && parts[2].hasPrefix("挪开的文件不会删"))
    #expect(parts[3].hasPrefix("选了重新开始") && parts[4].hasPrefix("原因："))
    // 重新开始之后那些 JSON 还在原处（便签的三个选择都不挪它们）
    let (fresh, _) = recover(.startFresh, at: at(10, 6, 9))
    #expect(try fresh.get().notes.isEmpty)
    #expect(snapshot(of: folder) == before)
  }

  // MARK: 两边互不相干

  /// 剪贴板的「重新开始」（Recovery.setAside(everything: true)）不挪便签的三样
  @Test func clipboardStartFreshLeavesNotesAlone() async throws {
    defer { try? manager.removeItem(at: directory) }
    try await seed()
    _ = try seedClipboardFiles()
    let notes = snapshot(of: directory).filter { $0.key.hasPrefix("notes") }
    #expect(notes.keys.contains("notes.sqlite3") && notes.keys.contains("notes-images/a.png"))
    #expect(notes.keys.contains("notes-backups/notes-2026-10-01/notes.sqlite3"))

    let aside = try #require(
      try Recovery.setAside(
        in: directory, everything: true, now: at(10, 3, 9, 5, 7), calendar: calendar))

    #expect(snapshot(of: directory).filter { $0.key.hasPrefix("notes") } == notes)
    #expect(snapshot(of: aside).keys.allSatisfy { !$0.contains("notes") })
    #expect(
      Set(try manager.contentsOfDirectory(atPath: aside.path))
        == ["kitty.sqlite3", "kitty.sqlite3-wal", "images", "backups"])
    // 挪完便签照常打得开
    #expect(try recover(.skip).result.get().notes.count == 3)
  }

  /// 便签的「重新开始」和「用备份」只挪便签自己的三样；没有东西可挪就不建文件夹；同一秒再来一次不覆盖前一次
  @Test func notesSetAsideMovesOnlyNotesFiles() async throws {
    defer { try? manager.removeItem(at: directory) }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = at(10, 2, 21, 30, 45)
    #expect(
      try NotesRecovery.setAside(in: directory, everything: true, now: now, calendar: calendar)
        == nil)
    let clipboard = try seedClipboardFiles()
    #expect(
      try NotesRecovery.setAside(in: directory, everything: true, now: now, calendar: calendar)
        == nil)
    #expect(try manager.contentsOfDirectory(atPath: directory.path).count == 4)

    try put("notes.sqlite3", "库")
    try put("notes.sqlite3-wal", "日志")
    try put("notes-images/a.png", "图 A")
    try put("notes-backups/notes-2026-10-01/notes.sqlite3", "备份")
    let first = try NotesRecovery.setAside(
      in: directory, everything: false, now: now, calendar: calendar)
    #expect(first?.lastPathComponent == "damaged-20261002-213045")
    #expect(
      snapshot(of: try #require(first)) == [
        "notes.sqlite3": Data("库".utf8), "notes.sqlite3-wal": Data("日志".utf8),
        "notes-images/a.png": Data("图 A".utf8),
      ])
    #expect(manager.fileExists(atPath: images.appending(path: "a.png").path))
    #expect(manager.fileExists(atPath: backup(10, 1).path))

    try put("notes.sqlite3", "第二个库")
    let second = try NotesRecovery.setAside(
      in: directory, everything: true, now: now, calendar: calendar)
    #expect(second?.lastPathComponent == "damaged-20261002-213045-2")
    #expect(
      snapshot(of: try #require(second)) == [
        "notes.sqlite3": Data("第二个库".utf8), "notes-images/a.png": Data("图 A".utf8),
        "notes-backups/notes-2026-10-01/notes.sqlite3": Data("备份".utf8),
      ])
    #expect(snapshot(of: try #require(first))["notes.sqlite3"] == Data("库".utf8))
    #expect(clipboardFiles() == clipboard)
  }

  // MARK: 文字

  /// 弹框的文字和按钮：有备份三个按钮（默认用备份），没有备份两个；最后一个总是「这次先不用便签」；
  /// 说清别的功能不受影响、挪开的文件在哪、原因；库文件不见了时不说「出问题的数据留在…」
  @Test func wordingMatchesTheChoices() {
    let home = URL(filePath: NSHomeDirectory()).appending(path: "Library/数据")
    let now = at(10, 3, 9)
    let copy = NotesBackup.Copy(url: backup(10, 2), day: calendar.startOfDay(for: at(10, 2)))
    var wording = NotesRecovery.wording(
      for: .init(reason: "file is not a database", backup: copy), directory: home, now: now,
      calendar: calendar)
    #expect(wording.title == "便签打不开了")
    #expect(wording.buttons == ["用 10 月 2 日（昨天）的备份", "重新开始", "这次先不用便签"])
    #expect(wording.choices == [.restore, .startFresh, .skip])
    #expect(wording.text.contains("剪贴板、翻译和别的功能不受影响"))
    #expect(wording.text.contains("便签回到 10 月 2 日（昨天）备份时的样子"))
    #expect(wording.text.contains("出问题的便签数据留在「damaged-日期-时间」文件夹里"))
    #expect(wording.text.contains("数据目录（~/Library/数据）"))
    #expect(wording.text.hasSuffix("原因：file is not a database"))

    wording = NotesRecovery.wording(
      for: .init(reason: "便签的数据库文件不见了", backup: copy, lost: true), directory: home,
      now: now, calendar: calendar)
    #expect(wording.buttons.count == 3 && !wording.text.contains("出问题的便签数据留在"))
    #expect(wording.text.hasSuffix("原因：便签的数据库文件不见了"))

    wording = NotesRecovery.wording(
      for: .init(reason: "磁盘坏了", backup: nil), directory: home, now: now, calendar: calendar)
    #expect(wording.buttons == ["重新开始", "这次先不用便签"])
    #expect(wording.choices == [.startFresh, .skip])
    #expect(wording.text.contains("也没有可用的备份") && !wording.text.contains("用备份："))
    #expect(wording.text.contains("这次先不用便签：什么都不动，便签这次用不了，下次打开 Kitty Tools 时再试。"))
    // 没有带着便签的每日 JSON 备份：不多那一段
    #expect(!wording.text.contains("从备份恢复"))
    #expect(!wording.text.contains("再问") && !wording.text.contains("这次运行里"))

    // 问过之后还是开不了：说一声；自己选的「这次先不用」不用再说
    #expect(NotesRecovery.notice(for: .skipped, directory: home) == nil)
    let notice = NotesRecovery.notice(for: .stillBroken("磁盘坏了"), directory: home)
    #expect(notice?.title == "便签还是打不开")
    #expect(notice?.text.hasPrefix("便签这次用不了，下次打开 Kitty Tools 时再试。") == true)
    #expect("\(NotesRecovery.Failure.stillBroken("磁盘坏了"))" == "磁盘坏了")
    #expect("\(NotesRecovery.Failure.skipped)" == "用户选了这次先不用便签")
    #expect(notice?.text.contains("别的功能不受影响") == true)
    #expect(notice?.text.contains("~/Library/数据") == true)
    #expect(notice?.text.hasSuffix("原因：磁盘坏了") == true)
    // 界面文字里不出现别的产品的名字
    for text in [wording.text, notice?.text ?? ""] { #expect(!text.contains("Noty")) }
  }
}

extension Result {
  /// 失败时的那个错（成功是 nil）
  fileprivate var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
