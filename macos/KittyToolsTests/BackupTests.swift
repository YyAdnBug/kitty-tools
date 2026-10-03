// 数据保险（Storage/Backup.swift，第二轮体检第 6 批）单测。
// 备份：文件名和日期互转、每天一份留最近 3 份、同一天不重复备也不改已有的那份、库坏了（文件头写坏 / 截断 / 中间写坏）
// 不备份也不动已有的备份、挑最近一份读得出来的；备份里只有用户留下的（收藏 / 片段 / 收藏夹里的条目、收藏夹、生词本、
// 启动器收藏），普通历史一个字节都不在备份文件里，留哪些和 ClipItem.isRetained 是同一批；删行不成就不留半成品。
// 打不开时：出问题的库连 -wal、-shm 挪进带时间的文件夹（不删、不覆盖）；用备份后留下的那些读得到、普通历史是空的；
// 没有备份时重新开始；重新开始把图片和旧备份一起挪开；选退出什么都不动；再开还失败只问一次、不循环；
// 库文件不见了 / 成了空文件而备份还在也要问；好好的库和全新安装不问。
// 用了备份之后：图片文件不在的条目不崩（缩略图 nil、粘贴内容为空），孤儿清理只删 images 里没人要的图。
// 弹框的文字和按钮（纯函数）。
// 只用临时目录，不碰真实数据目录；日期都是传进去的固定值，不看墙上时钟。

import AppKit
import Foundation
import Testing

@testable import KittyTools

/// 把库弄坏的三种办法
nonisolated enum Damage: CaseIterable, Sendable {
  /// 文件头写成垃圾
  case header
  /// 截掉后一半
  case truncated
  /// 第一页留着，后面全写成垃圾（打得开，一读就错）
  case middle
}

struct BackupTests {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "kitty-backup-tests-\(UUID().uuidString)")
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    return calendar
  }()
  var database: URL { directory.appending(path: Backup.databaseName) }

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

  /// 那天的备份文件
  private func backup(_ month: Int, _ day: Int) -> URL {
    Backup.folder(in: directory).appending(
      path: Backup.name(for: at(month, day), calendar: calendar))
  }

  private func run(_ month: Int, _ day: Int, _ hour: Int = 12) async -> Backup.Outcome {
    await Backup.run(in: directory, now: at(month, day, hour), calendar: calendar)
  }

  private func text(_ text: String) -> ClipItem {
    var item = ClipItem(kind: .text)
    item.text = text
    return item
  }

  /// 目录里所有文件的相对路径和内容：比「一个字节都没动」用
  private func snapshot(of folder: URL) -> [String: Data] {
    var files: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(
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

  /// 库文件（或备份）里的剪贴板文字
  private func clips(in url: URL) throws -> Set<String> {
    let rows = try Database(path: url.path, readOnly: true).query(
      "SELECT text FROM clips WHERE kind = 'text'"
    ) { $0.text(0) }
    return Set(rows.compactMap { $0 })
  }

  private func damage(_ url: URL, _ kind: Damage) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let garbage = { (count: UInt64) in Data(repeating: 0xA5, count: Int(count)) }
    switch kind {
    case .header:
      try handle.seek(toOffset: 0)
      try handle.write(contentsOf: garbage(4096))
    case .truncated:
      try handle.truncate(atOffset: size / 2)
    case .middle:
      try #require(size > 8192)
      try handle.seek(toOffset: 4096)
      try handle.write(contentsOf: garbage(size - 4096))
    }
  }

  /// 造一套数据。留下的：片段、收藏、收藏夹「收藏夹」里的一条「夹里的」、生词本一条（dog → 狗）、启动器收藏一个（备忘录）。
  /// 普通的：「备份前」、fill 条把库撑到很多页的历史、一条没收藏的翻译（cat → 猫）、启动器用过一次计算器。
  /// backedUpOn 那天备份一次，备份之后再记一条普通的「备份后」。返回值不接就是关掉了（连接跟着放掉）
  @discardableResult private func seed(backedUpOn day: Int? = 1, fill: Int = 0) async throws
    -> AppDelegate.Stores
  {
    let stores = try AppDelegate.Stores(in: directory)
    var snippet = text("片段")
    snippet.isSnippet = true
    var favorite = text("收藏")
    favorite.favorite = true
    let grouped = text("夹里的")
    for item in [snippet, favorite, grouped, text("备份前")] { stores.clipboard.record(item) }
    let group = try #require(stores.clipboard.createGroup(named: "收藏夹"))
    stores.clipboard.assign([grouped.id], to: group.id)
    for index in 0..<fill {
      stores.clipboard.record(text("第 \(index) 条：" + String(repeating: "喵", count: 300)))
    }
    stores.history.add(source: "cat", target: .zhHans, result: "猫", service: "测试", limit: 100)
    stores.history.setFavorite(source: "dog", target: .zhHans, result: "狗", service: "测试", true)
    stores.launcher.record(
      LauncherItem(kind: .app, target: "/Applications/Calculator.app", title: "计算器", subtitle: ""),
      query: "计算")
    stores.launcher.toggleFavorite(
      LauncherItem(kind: .app, target: "/Applications/Notes.app", title: "备忘录", subtitle: ""))
    if let day {
      #expect(await run(10, day) == .made(backup(10, day)))
      stores.clipboard.record(text("备份后"))
    }
    return stores
  }

  /// 用了 seed 那份备份之后的样子：留下的都读得到，普通的（剪贴板历史、没收藏的翻译、启动器使用记录）是空的
  private func expectOnlyKept(_ stores: AppDelegate.Stores) {
    let items = stores.clipboard.items
    #expect(Set(items.compactMap(\.text)) == ["片段", "收藏", "夹里的"])
    #expect(items.count == 3)
    #expect(items.first { $0.text == "片段" }?.isSnippet == true)
    #expect(items.first { $0.text == "收藏" }?.favorite == true)
    #expect(stores.clipboard.groups.map(\.name) == ["收藏夹"])
    #expect(items.first { $0.text == "夹里的" }?.groupID == stores.clipboard.groups.first?.id)
    #expect(stores.history.search("").map(\.source) == ["dog"])
    #expect(stores.history.search("").first?.favorite == true)
    #expect(stores.launcher.entries.isEmpty)
    #expect(stores.launcher.favorites.map(\.title) == ["备忘录"])
  }

  // MARK: 备份

  @Test func namesAndDaysRoundTrip() {
    let moment = at(10, 2, 23, 59, 59)
    #expect(Backup.name(for: moment, calendar: calendar) == "kitty-2026-10-02.sqlite3")
    #expect(
      Backup.day(of: "kitty-2026-10-02.sqlite3", calendar: calendar)
        == calendar.startOfDay(for: moment))
    for other in [
      "kitty.sqlite3", "kitty-2026-10-02.sqlite3.partial", "kitty-2026-10-2.sqlite3",
      "kitty-2026-10-02.sqlite3-wal", "notes.txt",
    ] {
      #expect(Backup.day(of: other, calendar: calendar) == nil)
    }
  }

  /// 每天一份、留最近 3 份；库开着（刚写的还在 WAL 里）备份也带得上；同一天再跑不重复备，也不改已有的那份；
  /// 上次做到一半留下的半成品（里面可能是没删过的整库）和它的回滚日志，下一次先清掉
  @Test func keepsThreeNewestAndOnePerDay() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    // 还没有库：没什么可备的，也不建备份目录
    #expect(await run(10, 1) == .damaged)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    let stores = try AppDelegate.Stores(in: directory)
    for day in 1...5 {
      var kept = text("第 \(day) 天")
      kept.favorite = true
      stores.clipboard.record(kept)
      stores.clipboard.record(text("第 \(day) 天的普通历史"))
      if day == 2 {
        for name in ["kitty.partial", "kitty.partial-journal"] {
          try Data("上次留下的".utf8).write(to: Backup.folder(in: directory).appending(path: name))
        }
      }
      #expect(Backup.isDue(in: directory, now: at(10, day), calendar: calendar))
      #expect(await run(10, day) == .made(backup(10, day)))
      #expect(!Backup.isDue(in: directory, now: at(10, day, 23), calendar: calendar))
      #expect(Backup.list(in: directory, calendar: calendar).count == min(day, Backup.keep))
    }
    #expect(
      Backup.list(in: directory, calendar: calendar).map(\.url.lastPathComponent) == [
        "kitty-2026-10-05.sqlite3", "kitty-2026-10-04.sqlite3", "kitty-2026-10-03.sqlite3",
      ])
    #expect(try clips(in: backup(10, 3)) == ["第 1 天", "第 2 天", "第 3 天"])
    #expect(try clips(in: backup(10, 5)) == ["第 1 天", "第 2 天", "第 3 天", "第 4 天", "第 5 天"])
    // 备份目录里只有这三份：没有半成品，也没有 -wal / -shm / -journal
    let before = snapshot(of: Backup.folder(in: directory))
    #expect(before.count == 3)

    var later = text("同一天后来收藏的")
    later.favorite = true
    stores.clipboard.record(later)
    #expect(await run(10, 5, 23) == .notDue)
    #expect(snapshot(of: Backup.folder(in: directory)) == before)
  }

  /// 备份里只有用户留下的。普通剪贴板条目（正文、富文本、识别出的文字、备注、来源、文件路径）、没收藏的翻译、启动器的
  /// 使用记录，一个字节都不在备份文件里（删行之后整理过，空闲页里也没有）；收藏 / 片段 / 收藏夹里的条目（连富文本）、
  /// 收藏夹、生词本、启动器收藏都在。留哪些剪贴板条目，和 ClipItem.isRetained 挑出来的是同一批
  @Test func backupKeepsOnlyWhatTheUserKept() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let stores = try await seed(backedUpOn: nil)
    var rich = text("留下的带格式文字")
    rich.favorite = true
    rich.richType = .html
    stores.clipboard.record(rich, rich: Data("<b>留下的格式</b>".utf8))
    var picture = ClipItem(kind: .image)
    picture.image = .init(width: 1, height: 1, byteCount: 1, sha256: "留下的图")
    picture.ocrText = "留下的图里的字"
    picture.isSnippet = true
    stores.clipboard.record(picture)

    // 普通的：每个能存字的地方放一段特征文字，正文那段重复两百条（删掉后整页整页地空出来）
    for index in 0..<200 {
      stores.clipboard.record(text("zz正文zz 第 \(index) 条" + String(repeating: "喵", count: 300)))
    }
    var formatted = text("zz带格式的正文zz")
    formatted.richType = .html
    formatted.note = "zz备注zz"
    formatted.sourceName = "zz来源zz"
    stores.clipboard.record(formatted, rich: Data("<i>zz富文本zz</i>".utf8))
    var screenshot = ClipItem(kind: .image)
    screenshot.image = .init(width: 1, height: 1, byteCount: 1, sha256: "zz图的哈希zz")
    screenshot.ocrText = "zz图里的字zz"
    stores.clipboard.record(screenshot)
    var file = ClipItem(kind: .file)
    file.filePaths = ["/tmp/zz文件zz.txt"]
    stores.clipboard.record(file)
    stores.history.add(
      source: "zzsourcezz", target: .en, result: "zz译文zz", service: "测试", limit: 100)
    stores.launcher.record(
      LauncherItem(kind: .path, target: "/tmp/zztargetzz.txt", title: "zz标题zz", subtitle: ""),
      query: "zzqueryzz")
    let markers = [
      "zz正文zz", "zz带格式的正文zz", "zz备注zz", "zz来源zz", "zz富文本zz", "zz图的哈希zz", "zz图里的字zz",
      "zz文件zz", "zzsourcezz", "zz译文zz", "zztargetzz", "zz标题zz", "zzqueryzz", "备份前", "猫", "计算器",
    ]

    #expect(await run(10, 1) == .made(backup(10, 1)))
    // 这种搜法是有效的：没删过的整库拷贝里每一段都搜得到
    let whole = directory.appending(path: "whole.sqlite3")
    try Database(path: database.path, readOnly: true).copy(to: whole.path)
    let unstripped = try Data(contentsOf: whole)
    let stripped = try Data(contentsOf: backup(10, 1))
    for marker in markers {
      #expect(unstripped.range(of: Data(marker.utf8)) != nil, "整库里应该有「\(marker)」")
      #expect(stripped.range(of: Data(marker.utf8)) == nil, "备份里不该有「\(marker)」")
    }
    #expect(stripped.count < unstripped.count / 2)

    let copy = try Database(path: backup(10, 1).path, readOnly: true)
    // 库里现在就这五张表。加了新表这里会报错：先想清楚它进不进备份（Backup.dropped），再改这一行
    #expect(
      Set(
        try copy.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) ?? "" })
        == ["clips", "clip_groups", "translations", "launcher_usage", "launcher_favorites"])
    let kept = try copy.query("SELECT id FROM clips") { $0.text(0).flatMap(UUID.init(uuidString:)) }
    let retained = stores.clipboard.items.filter(\.isRetained)
    #expect(Set(kept.compactMap { $0 }) == Set(retained.map(\.id)))
    #expect(
      Set(retained.compactMap { $0.text ?? $0.ocrText })
        == ["片段", "收藏", "夹里的", "留下的带格式文字", "留下的图里的字"])
    #expect(
      try copy.query("SELECT rich_data FROM clips WHERE id = ?", [rich.id.uuidString]) {
        $0.blob(0)
      } == [Data("<b>留下的格式</b>".utf8)])
    #expect(try copy.query("SELECT name FROM clip_groups") { $0.text(0) } == ["收藏夹"])
    #expect(
      try copy.query("SELECT source, favorite FROM translations") {
        "\($0.text(0) ?? "") \($0.int(1) ?? -1)"
      }
        == ["dog 1"])
    #expect(try copy.query("SELECT COUNT(*) FROM launcher_usage") { $0.int(0) } == [0])
    #expect(try copy.query("SELECT title FROM launcher_favorites") { $0.text(0) } == ["备忘录"])
  }

  /// 删行那一步不成（这里是库里少了一张表）：这次备份算失败，半成品（还是整库）不留在磁盘上，已有的备份不动
  @Test func failedStrippingLeavesNoHalfBackup() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed()
    let before = snapshot(of: Backup.folder(in: directory))
    try Database(path: database.path).execute("DROP TABLE launcher_usage")

    let outcome = await run(10, 2)
    guard case .failed = outcome else {
      Issue.record("应该是没备成，结果是 \(outcome)")
      return
    }
    #expect(snapshot(of: Backup.folder(in: directory)) == before)
    #expect(before.count == 1)
  }

  /// 库坏了：不备份，已有的备份一个字节都不动，不留半截文件；当天已经备过的那份也不会被坏库盖掉
  @Test(arguments: Damage.allCases) func damagedDatabaseIsNotBackedUp(_ kind: Damage) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(fill: 200)
    let before = snapshot(of: Backup.folder(in: directory))
    #expect(before.count == 1)
    try damage(database, kind)

    #expect(await run(10, 2) == .damaged)
    #expect(snapshot(of: Backup.folder(in: directory)) == before)
    #expect(await run(10, 1, 23) == .notDue)
    #expect(snapshot(of: Backup.folder(in: directory)) == before)
  }

  /// 还没有备份目录时库就坏了：什么都不建
  @Test func damagedDatabaseWithoutBackupsCreatesNothing() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(backedUpOn: nil, fill: 50)
    try damage(database, .header)
    #expect(await run(10, 2) == .damaged)
    #expect(!FileManager.default.fileExists(atPath: Backup.folder(in: directory).path))
  }

  /// 挑最近一份读得出来的：最新的坏了往前找，都坏了就是没有；不是备份名字的文件不算
  @Test func picksTheLatestUsableBackup() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let stores = try AppDelegate.Stores(in: directory)
    for index in 0..<50 {
      stores.clipboard.record(text("第 \(index) 条" + String(repeating: "喵", count: 300)))
    }
    for day in 1...3 { #expect(await run(10, day) == .made(backup(10, day))) }
    try Data("不是备份".utf8).write(to: Backup.folder(in: directory).appending(path: "notes.txt"))
    try Data("半截".utf8).write(
      to: Backup.folder(in: directory).appending(path: "kitty-2026-10-09.sqlite3.partial"))

    let latest = try #require(Backup.latestUsable(in: directory, calendar: calendar))
    #expect(latest.url == backup(10, 3))
    #expect(latest.day == calendar.startOfDay(for: at(10, 3)))

    try damage(backup(10, 3), .header)
    #expect(Backup.latestUsable(in: directory, calendar: calendar)?.url == backup(10, 2))
    try damage(backup(10, 2), .truncated)
    #expect(Backup.latestUsable(in: directory, calendar: calendar)?.url == backup(10, 1))
    try damage(backup(10, 1), .middle)
    let before = snapshot(of: Backup.folder(in: directory))
    #expect(Backup.latestUsable(in: directory, calendar: calendar) == nil)
    // 坏的备份也算一份（轮换按名字）：列表还是三份；挑的时候只读，备份目录里什么都没变（也没多出 -wal / -shm）
    #expect(Backup.list(in: directory, calendar: calendar).count == 3)
    #expect(snapshot(of: Backup.folder(in: directory)) == before)
    #expect(before.count == 5)
  }

  // MARK: 打不开时

  /// 出问题的库连 -wal、-shm 挪进带时间的文件夹：内容不变、不删；同一秒再来一次不覆盖前一次；
  /// 用备份（everything = false）时图片拷一份进去、原地的不动；重新开始（everything）时图片和备份整个挪走；
  /// 没东西可留就不建文件夹
  @Test func setAsideMovesAndNeverDeletes() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = FileManager.default
    let put = { (path: String, content: String) in
      let url = directory.appending(path: path)
      try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    try put("kitty.sqlite3", "库")
    try put("kitty.sqlite3-wal", "日志")
    try put("kitty.sqlite3-shm", "索引")
    try put("images/a.png", "图")
    try put("backups/kitty-2026-10-01.sqlite3", "备份")
    let now = at(10, 2, 21, 30, 45)

    let first = try #require(
      try Recovery.setAside(in: directory, everything: false, now: now, calendar: calendar))
    #expect(first.lastPathComponent == "damaged-20261002-213045")
    #expect(
      snapshot(of: directory) == [
        "damaged-20261002-213045/kitty.sqlite3": Data("库".utf8),
        "damaged-20261002-213045/kitty.sqlite3-wal": Data("日志".utf8),
        "damaged-20261002-213045/kitty.sqlite3-shm": Data("索引".utf8),
        "damaged-20261002-213045/images/a.png": Data("图".utf8),
        "images/a.png": Data("图".utf8),
        "backups/kitty-2026-10-01.sqlite3": Data("备份".utf8),
      ])

    try put("kitty.sqlite3", "第二个库")
    let second = try #require(
      try Recovery.setAside(in: directory, everything: true, now: now, calendar: calendar))
    #expect(second.lastPathComponent == "damaged-20261002-213045-2")
    let all = snapshot(of: directory)
    #expect(
      all == [
        "damaged-20261002-213045/kitty.sqlite3": Data("库".utf8),
        "damaged-20261002-213045/kitty.sqlite3-wal": Data("日志".utf8),
        "damaged-20261002-213045/kitty.sqlite3-shm": Data("索引".utf8),
        "damaged-20261002-213045/images/a.png": Data("图".utf8),
        "damaged-20261002-213045-2/kitty.sqlite3": Data("第二个库".utf8),
        "damaged-20261002-213045-2/images/a.png": Data("图".utf8),
        "damaged-20261002-213045-2/backups/kitty-2026-10-01.sqlite3": Data("备份".utf8),
      ])

    #expect(
      try Recovery.setAside(in: directory, everything: true, now: now, calendar: calendar) == nil)
    #expect(snapshot(of: directory) == all)
    #expect(try manager.contentsOfDirectory(atPath: directory.path).count == 2)
  }

  /// 用备份：坏库原样留在 damaged-…/，备份留在 backups/，再打开读得到备份那天的片段 / 收藏 / 收藏夹 / 生词本 /
  /// 启动器收藏，普通历史（备份前后的都算）是空的；只问一次。（-wal、-shm 一起挪走在 setAsideMovesAndNeverDeletes 里核对：真的库旁边放假的
  /// -wal，sqlite 第一次打开时自己就会重建 / 删掉它，没法在这里比内容）
  @Test(arguments: Damage.allCases) func restoreBringsBackTheBackup(_ kind: Damage) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(fill: 200)
    try damage(database, kind)
    let damaged = try Data(contentsOf: database)
    let backups = snapshot(of: Backup.folder(in: directory))

    var asked: [Recovery.Problem] = []
    let stores = try Recovery.open(
      in: directory, now: at(10, 3, 9, 5, 7), calendar: calendar,
      open: { try AppDelegate.Stores(in: directory) },
      ask: { problem in
        asked.append(problem)
        return .restore
      })

    #expect(asked.count == 1)
    #expect(
      asked.first?.backup
        == Backup.Copy(url: backup(10, 1), day: calendar.startOfDay(for: at(10, 1))))
    #expect(asked.first?.reason.isEmpty == false)
    expectOnlyKept(stores)
    // 恢复后的库能照常写
    stores.clipboard.record(text("恢复后"))
    #expect(try clips(in: database).contains("恢复后"))

    let aside = directory.appending(path: "damaged-20261003-090507")
    #expect(try Data(contentsOf: aside.appending(path: "kitty.sqlite3")) == damaged)
    #expect(snapshot(of: Backup.folder(in: directory)) == backups)
    #expect(!FileManager.default.fileExists(atPath: database.path + ".restoring"))
  }

  /// App 被强行结束时库旁边留着没合并的 -wal（「备份后」那条只在它里面）：用备份时它得跟着坏库一起挪走——
  /// 留在原地的话 sqlite 会把它重放到刚恢复的库上
  @Test func staleWalIsNotReplayedOntoTheRestoredBackup() async throws {
    let killed = directory.appendingPathExtension("killed")
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: killed)
    }
    // 连接开着时把整个目录拷走 = 强行结束那一刻的样子
    let live = try await seed()
    try FileManager.default.copyItem(at: directory, to: killed)
    let wal = try Data(contentsOf: killed.appending(path: "kitty.sqlite3-wal"))
    #expect(!wal.isEmpty)
    #expect(try clips(in: killed.appending(path: Backup.databaseName)).contains("备份后"))
    #expect(live.clipboard.items.count == 5)

    struct Broken: Error {}
    var opened = 0
    let stores = try Recovery.open(
      in: killed, now: at(10, 2, 21, 30, 45), calendar: calendar,
      open: {
        opened += 1
        // 第一次当它打不开（真坏了的库 sqlite 第一次打开时自己会动 -wal，这里要它原样留着）
        if opened == 1 { throw Broken() }
        return try AppDelegate.Stores(in: killed)
      }, ask: { _ in .restore })

    expectOnlyKept(stores)
    #expect(
      try Data(contentsOf: killed.appending(path: "damaged-20261002-213045/kitty.sqlite3-wal"))
        == wal)
  }

  /// 没有备份：只能重新开始——坏库和图片一起挪开留着，新的是空的
  @Test func startFreshWithoutBackups() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(backedUpOn: nil, fill: 50)
    try Data("图".utf8).write(to: directory.appending(path: "images/\(UUID().uuidString).png"))
    try damage(database, .header)
    let before = snapshot(of: directory)

    var asked: [Recovery.Problem] = []
    let stores = try Recovery.open(
      in: directory, now: at(10, 2, 21, 30, 45), calendar: calendar,
      open: { try AppDelegate.Stores(in: directory) },
      ask: { problem in
        asked.append(problem)
        return .startFresh
      })

    #expect(asked.count == 1 && asked.first?.backup == nil)
    #expect(stores.clipboard.items.isEmpty)
    #expect(stores.history.search("").isEmpty)
    #expect(stores.launcher.entries.isEmpty)
    // 原来的每个文件都原样在 damaged-…/ 里
    let after = snapshot(of: directory.appending(path: "damaged-20261002-213045"))
    #expect(after == before)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "images").path)
        .isEmpty)
  }

  /// 有备份却选了重新开始：旧备份跟着一起挪开（不会被新库的备份轮换掉），新的是空的
  @Test func startFreshSetsBackupsAsideToo() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(fill: 50)
    try damage(database, .header)
    let before = snapshot(of: directory)

    let stores = try Recovery.open(
      in: directory, now: at(10, 2, 21, 30, 45), calendar: calendar,
      open: { try AppDelegate.Stores(in: directory) }, ask: { _ in .startFresh })

    #expect(stores.clipboard.items.isEmpty)
    #expect(Backup.list(in: directory, calendar: calendar).isEmpty)
    #expect(snapshot(of: directory.appending(path: "damaged-20261002-213045")) == before)
    #expect(await run(10, 2) == .made(backup(10, 2)))
    #expect(Backup.list(in: directory, calendar: calendar).count == 1)
  }

  /// 选退出：什么都不动，也不再试
  @Test func quitTouchesNothing() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(fill: 50)
    try damage(database, .header)
    let before = snapshot(of: directory)
    var opened = 0

    #expect(throws: Recovery.Failure.quit) {
      try Recovery.open(
        in: directory, now: at(10, 2), calendar: calendar,
        open: {
          opened += 1
          return try AppDelegate.Stores(in: directory)
        }, ask: { _ in .quit })
    }
    #expect(opened == 1)
    #expect(snapshot(of: directory) == before)
  }

  /// 恢复 / 重新开始之后还是打不开：报错，只问过一次、只再试一次，不循环；出问题的文件照样留着
  @Test(arguments: [Recovery.Choice.restore, .startFresh])
  func secondFailureDoesNotLoop(_ choice: Recovery.Choice) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(fill: 50)
    try damage(database, .header)
    let damaged = try Data(contentsOf: database)
    var opened = 0
    var asked = 0
    struct Broken: Error {}

    #expect(throws: Recovery.Failure.stillBroken("\(Broken())")) {
      try Recovery.open(
        in: directory, now: at(10, 2, 21, 30, 45), calendar: calendar,
        open: { () -> AppDelegate.Stores in
          opened += 1
          throw Broken()
        },
        ask: { _ in
          asked += 1
          return choice
        })
    }
    #expect(opened == 2 && asked == 1)
    #expect(
      try Data(contentsOf: directory.appending(path: "damaged-20261002-213045/kitty.sqlite3"))
        == damaged)
  }

  /// 好好的库、全新安装（还没有库也没有备份）：不问，直接打开
  @Test func healthyOrBrandNewNeverAsks() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    var asked = 0
    let ask = { (_: Recovery.Problem) -> Recovery.Choice in
      asked += 1
      return .startFresh
    }
    // 全新安装：目录都还没有
    var stores: AppDelegate.Stores? = try Recovery.open(
      in: directory, calendar: calendar, open: { try AppDelegate.Stores(in: directory) }, ask: ask)
    #expect(stores?.clipboard.items.isEmpty == true)
    stores = nil
    try await seed()
    stores = try Recovery.open(
      in: directory, calendar: calendar, open: { try AppDelegate.Stores(in: directory) }, ask: ask)
    #expect(stores?.clipboard.items.contains { $0.text == "备份后" } == true)
    #expect(asked == 0)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
        !$0.hasPrefix("damaged")
      })
  }

  /// 库文件不见了 / 成了空文件，而备份还在：不能悄悄建一个空库（三天后好备份就被空的顶光了），要问；没打开过就问
  @Test(arguments: [true, false]) func lostDatabaseAsksWhenBackupsExist(_ empties: Bool)
    async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed()
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(
        at: directory.appending(path: Backup.databaseName + suffix))
    }
    if empties { try Data().write(to: database) }
    var opened = 0
    var asked: [Recovery.Problem] = []

    let stores = try Recovery.open(
      in: directory, now: at(10, 2, 21, 30, 45), calendar: calendar,
      open: {
        opened += 1
        return try AppDelegate.Stores(in: directory)
      },
      ask: { problem in
        #expect(opened == 0)
        asked.append(problem)
        return .restore
      })

    #expect(opened == 1 && asked.count == 1)
    #expect(asked.first?.reason == (empties ? "数据库文件是空的" : "数据库文件不见了"))
    #expect(asked.first?.lost == true)
    #expect(asked.first?.backup?.url == backup(10, 1))
    expectOnlyKept(stores)
  }

  /// 用了备份之后的图片：留下的图片条目，文件还在的照常、文件已经不在的不崩（缩略图 nil、粘贴内容为空）；普通图片和
  /// 备份之后才存的图不在备份里，它们的文件被孤儿清理删掉；孤儿清理只动 images 里名字是条目 id 的图，
  /// 别的（备份、挪开的坏库、images 里别的文件）都不碰
  @Test func imagesAfterRestore() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    var seeded: AppDelegate.Stores? = try AppDelegate.Stores(in: directory)
    var ids: [UUID] = []
    // 四张图：0 收藏的、1 收藏的（之后文件被删掉）、2 普通的，这三张在备份之前；3 备份之后才收藏的
    for index in 0..<4 {
      if index == 3 { #expect(await run(10, 1) == .made(backup(10, 1))) }
      var item = ClipItem(kind: .image)
      item.favorite = index != 2
      // 当成识过字的：不然 record 会起后台识字（「识别图片文字」开着时），那个任务拿着仓库不放，下面关不掉连接
      item.ocrText = ""
      // 每张的哈希不一样（按哈希去重）
      item.image = try #require(await seeded?.clipboard.images.save(png, isPNG: true, id: item.id))
      item.image?.sha256 += "-\(index)"
      seeded?.clipboard.record(item)
      ids.append(item.id)
    }
    let images = ImageStore(directory: directory.appending(path: "images"))
    seeded = nil
    try FileManager.default.removeItem(at: images.url(for: ids[1]))
    try Data("别的".utf8).write(to: images.directory.appending(path: "notes.txt"))
    try damage(database, .header)

    var asked = 0
    let stores = try Recovery.open(
      in: directory, now: at(10, 2, 21, 30, 45), calendar: calendar,
      open: { try AppDelegate.Stores(in: directory) },
      ask: { _ in
        asked += 1
        return .restore
      })
    #expect(asked == 1)
    #expect(Set(stores.clipboard.items.map(\.id)) == Set(ids.prefix(2)))
    let gone = try #require(stores.clipboard.items.first { $0.id == ids[1] })
    #expect(await stores.clipboard.images.thumbnail(for: gone.id, maxPixel: 64) == nil)
    #expect(stores.clipboard.pasteboardItems(for: gone).isEmpty)
    let kept = try #require(stores.clipboard.items.first { $0.id == ids[0] })
    #expect(await stores.clipboard.images.thumbnail(for: kept.id, maxPixel: 64) != nil)
    #expect(stores.clipboard.pasteboardItems(for: kept).count == 1)

    // 启动时的孤儿清理（AppDelegate 里就是这一句）
    let before = snapshot(of: directory)
    stores.clipboard.images.removeOrphans(
      keeping: Set(stores.clipboard.items.map(\.id)), createdBefore: .distantFuture)
    var expected = before
    for orphan in ids.suffix(2) {
      #expect(before["images/\(orphan.uuidString).png"] != nil)
      expected["images/\(orphan.uuidString).png"] = nil
    }
    #expect(snapshot(of: directory) == expected)
    #expect(expected["images/\(ids[0].uuidString).png"] != nil)
  }

  // MARK: 弹框的文字

  @Test func describesHowOldTheBackupIs() {
    let now = at(10, 2, 0, 0, 1)
    #expect(Recovery.describe(at(10, 2), now: now, calendar: calendar) == "10 月 2 日（今天）")
    #expect(
      Recovery.describe(at(10, 1, 23, 59, 59), now: now, calendar: calendar) == "10 月 1 日（昨天）")
    #expect(Recovery.describe(at(9, 28), now: now, calendar: calendar) == "9 月 28 日（4 天前）")
    // 时钟往回调过：备份比现在还「新」
    #expect(Recovery.describe(at(10, 5), now: now, calendar: calendar) == "10 月 5 日（今天）")
  }

  @Test func wordingSaysWhatEachChoiceDoes() {
    let home = URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support/示例")
    let copy = Backup.Copy(url: backup(10, 1), day: calendar.startOfDay(for: at(10, 1)))
    let with = Recovery.wording(
      for: .init(reason: "database disk image is malformed", backup: copy), directory: home,
      now: at(10, 2), calendar: calendar)
    #expect(with.buttons == ["用 10 月 1 日（昨天）的备份", "重新开始", "退出"])
    #expect(with.choices == [.restore, .startFresh, .quit])
    for part in [
      "片段、收藏、收藏夹、生词本和启动器的收藏回到 10 月 1 日（昨天）备份时的样子",
      "普通剪贴板历史、翻译历史和启动器的使用记录不在备份里，会从空的开始", "出问题的数据库和当时的图片都留在", "重新开始：全部从空的开始", "不会删",
      "~/Library/Application Support/示例", "damaged-", "钥匙串", "原因：database disk image is malformed",
    ] {
      #expect(with.text.contains(part), "少了「\(part)」")
    }

    // 库文件不见了：没有坏库可留，不说「数据还在里面」
    let lost = Recovery.wording(
      for: .init(reason: "数据库文件不见了", backup: copy, lost: true), directory: home, now: at(10, 2),
      calendar: calendar)
    #expect(with.text.contains("全部数据还在里面") && !lost.text.contains("全部数据还在里面"))
    #expect(lost.buttons == with.buttons && lost.text.contains("会从空的开始。\n重新开始"))

    let without = Recovery.wording(
      for: .init(reason: "file is not a database", backup: nil), directory: home, now: at(10, 2),
      calendar: calendar)
    #expect(without.buttons == ["重新开始", "退出"])
    #expect(without.choices == [.startFresh, .quit])
    #expect(without.text.contains("没有可用的备份"))
    #expect(!without.text.contains("用备份"))
    #expect(without.text.contains("原因：file is not a database"))
  }
}
