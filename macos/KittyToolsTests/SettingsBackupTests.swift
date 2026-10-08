import AppKit
import Foundation
import Testing

@testable import KittyTools

/// 设置与数据的每日自动备份（Storage/SettingsBackup.swift）：文件名往返、只认自己的文件；今天备没备过；写和轮换
/// （每天 7 份、导入前 3 份且最多 7 天，别的文件不动；时钟调到过未来时写下的不把今天这份顶掉；同一秒的「导入前」不盖）；
/// 另选的文件夹（不在了不建、文件名带电脑编号、几台电脑共用时各认各的）；写的内容就是导出文件（读得回来、没有密钥），
/// 哪一类太多就不带哪一类；开关、文件夹、编号不跟着导出 / 导入走；导入前的钩子（密码不对不存、存不成就不导入、
/// 存的是导入之前的样子）；每一份的整条路（该不该写、写、把结果记进偏好：AppDelegate 只管什么时候调）；
/// 菜单和设置页里的说法、没写成的原因怎么说。
/// 全在临时目录、临时偏好域和内存库里，不碰用户的数据目录、偏好和钥匙串
struct SettingsBackupTests {
  /// 固定的日历：文件名按当地日期起，测试不跟着跑它的机器的时区走
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }()

  /// 2026-10-08 那一天里的某一刻（当地时间）
  private static func moment(day: Int = 8, hour: Int = 9, minute: Int = 12, second: Int = 0) -> Date
  {
    calendar.date(
      from: DateComponents(
        year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
  }

  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "kitty-backup-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func suite() throws -> (defaults: UserDefaults, name: String) {
    let name = "kitty-test-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
  }

  private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  private var ai: TranslateService {
    var service = TranslateService.newAI()
    service.id = "ai:1a2b3c4d"
    service.name = "DeepSeek"
    service.baseURL = "https://api.deepseek.com/v1"
    service.model = "deepseek-chat"
    return service
  }

  // MARK: 文件名

  /// 两种文件名写出去、认回来是同一个时刻；另存的文件夹里每天那份多带电脑编号；数据库的备份、用户自己导出的文件、
  /// 写到一半的临时文件、云盘同步冲突留下的副本都不认
  @Test func namesRoundTrip() throws {
    let calendar = Self.calendar
    let morning = Self.moment()
    let daily = SettingsBackup.name(for: .daily, at: morning, calendar: calendar)
    #expect(daily == "Kitty Tools 自动备份 2026-10-08.json")
    let parsedDaily = try #require(SettingsBackup.parse(daily, calendar: calendar))
    #expect(parsedDaily.kind == .daily && parsedDaily.owner == nil)
    #expect(parsedDaily.date == calendar.startOfDay(for: morning))

    let mirrored = SettingsBackup.name(for: .daily, at: morning, owner: "3F9A", calendar: calendar)
    #expect(mirrored == "Kitty Tools 自动备份 2026-10-08 3F9A.json")
    let parsedMirrored = try #require(SettingsBackup.parse(mirrored, calendar: calendar))
    #expect(parsedMirrored.kind == .daily && parsedMirrored.owner == "3F9A")
    #expect(parsedMirrored.date == calendar.startOfDay(for: morning))

    // 导入前那份只在本机，不带编号
    let afternoon = Self.moment(hour: 15, minute: 30, second: 12)
    let before = SettingsBackup.name(
      for: .beforeImport, at: afternoon, owner: "3F9A", calendar: calendar)
    #expect(before == "Kitty Tools 导入前 2026-10-08 153012.json")
    let parsedBefore = try #require(SettingsBackup.parse(before, calendar: calendar))
    #expect(parsedBefore.kind == .beforeImport && parsedBefore.date == afternoon)
    #expect(parsedBefore.owner == nil)

    for other in [
      "kitty-2026-10-08.sqlite3", "Kitty Tools 设置 2026-10-08.json",
      "Kitty Tools 自动备份 2026-10-08.json.tmp", "Kitty Tools 自动备份 2026-10-08 (1).json",
      "Kitty Tools 自动备份 2026-10-08 2.json", "Kitty Tools 自动备份 2026-10-08 3F9A 2.json",
      "Kitty Tools 自动备份 2026-10-08 3f9a.json", "Kitty Tools 自动备份 2026-10-08 3F9.json",
      "kitty tools 自动备份 2026-10-08.json", ".DS_Store",
    ] {
      #expect(SettingsBackup.parse(other, calendar: calendar) == nil, "\(other)")
    }
  }

  // MARK: 写和轮换

  /// 每天一份留最近 7 份、导入前留最近 3 份，各管各的；文件夹里别的文件（数据库的备份、用户自己放的）一个都不动
  @Test func storeWritesAndRotates() throws {
    let calendar = Self.calendar
    let folder = try folder().appending(path: "backups")  // 还不在：本机的 backups/ 自己建
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let payload = Data("{}".utf8)
    #expect(SettingsBackup.isDue(in: folder, now: Self.moment(day: 1), calendar: calendar))
    try SettingsBackup.store(
      payload, kind: .daily, in: folder, creates: true, now: Self.moment(day: 1),
      calendar: calendar)
    // 同一天再看：备过了；换一天又该备了
    #expect(
      !SettingsBackup.isDue(in: folder, now: Self.moment(day: 1, hour: 23), calendar: calendar))
    #expect(SettingsBackup.isDue(in: folder, now: Self.moment(day: 2, hour: 0), calendar: calendar))
    let others = ["kitty-2026-10-01.sqlite3", "Kitty Tools 设置 2026-10-01.json", "随手放的.txt"]
    for name in others { try Data("x".utf8).write(to: folder.appending(path: name)) }

    for day in 2...9 {
      try SettingsBackup.store(
        payload, kind: .daily, in: folder, creates: true, now: Self.moment(day: day),
        calendar: calendar)
    }
    for second in 0..<5 {
      try SettingsBackup.store(
        payload, kind: .beforeImport, in: folder, creates: true,
        now: Self.moment(day: 9, hour: 15, second: second), calendar: calendar)
    }
    let copies = SettingsBackup.list(in: folder, calendar: calendar)
    let daily = copies.filter { $0.kind == .daily }
    let before = copies.filter { $0.kind == .beforeImport }
    #expect(
      daily.count == SettingsBackup.keepDaily && before.count == SettingsBackup.keepBeforeImport)
    // 留下的是最近的：3–9 日那七天、最后三次导入前；新的在前（导入前那几份是 9 日下午的，排在 9 日那份前面）
    #expect(
      daily.map { calendar.component(.day, from: $0.date) } == [9, 8, 7, 6, 5, 4, 3])
    #expect(before.map { calendar.component(.second, from: $0.date) } == [4, 3, 2])
    #expect(copies.prefix(3).allSatisfy { $0.kind == .beforeImport })
    #expect(Set(names(in: folder)).isSuperset(of: others))
    #expect(names(in: folder).count == 7 + 3 + others.count)

    // 同一秒里第二份「导入前」不写：先存的那份是更早的样子，留它
    let again = try SettingsBackup.store(
      Data("后来的".utf8), kind: .beforeImport, in: folder, creates: true,
      now: Self.moment(day: 9, hour: 15, second: 4), calendar: calendar)
    #expect(try Data(contentsOf: again) == payload)

    // 「导入前」最多留 7 天：往本机写每天那份时顺手清。一周后那天还在（15:00 存的，09:12 还没满 7 天），再过一天清掉
    try SettingsBackup.store(
      payload, kind: .daily, in: folder, creates: true, now: Self.moment(day: 16),
      calendar: calendar)
    #expect(
      SettingsBackup.list(in: folder, calendar: calendar).count { $0.kind == .beforeImport } == 3)
    try SettingsBackup.store(
      payload, kind: .daily, in: folder, creates: true, now: Self.moment(day: 17),
      calendar: calendar)
    let left = SettingsBackup.list(in: folder, calendar: calendar)
    #expect(left.allSatisfy { $0.kind == .daily })
    #expect(left.map { calendar.component(.day, from: $0.date) } == [17, 16, 9, 8, 7, 6, 5])
    #expect(Set(names(in: folder)).isSuperset(of: others))
  }

  /// 系统时钟调到过未来时写下的那几份（日期比今天还晚）不能把今天这份顶掉：只按日期留最新 7 份的话，今天这份刚写完
  /// 就被删，之后每次都白备、也一直显示「今天还没备」。刚写的不删，多出来的先删未来的（旧的先删）
  @Test func copiesFromAClockAheadGoFirst() throws {
    let calendar = Self.calendar
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let payload = Data("{}".utf8)
    // 时钟在 20–26 日那七天各备了一份，再调回 8 日
    for day in 20...26 {
      try SettingsBackup.store(
        payload, kind: .daily, in: folder, creates: false, now: Self.moment(day: day),
        calendar: calendar)
    }
    let today = Self.moment()
    let written = try SettingsBackup.store(
      Data("今天的".utf8), kind: .daily, in: folder, creates: false, now: today, calendar: calendar)
    #expect(try Data(contentsOf: written) == Data("今天的".utf8))
    #expect(!SettingsBackup.isDue(in: folder, now: today, calendar: calendar))
    let days = {
      SettingsBackup.list(in: folder, calendar: calendar).map {
        calendar.component(.day, from: $0.date)
      }
    }
    #expect(days() == [26, 25, 24, 23, 22, 21, 8])
    // 之后每天顶掉一份未来的，正常的那几份不动
    try SettingsBackup.store(
      payload, kind: .daily, in: folder, creates: false, now: Self.moment(day: 9),
      calendar: calendar)
    #expect(days() == [26, 25, 24, 23, 22, 9, 8])

    // 纯函数：没超不删；超了先删未来的，再删最旧的；刚写的那份怎么都不删
    let file = { (name: String) in folder.appending(path: name) }
    let copies = [
      (url: file("a"), date: Self.moment(day: 5)), (url: file("b"), date: Self.moment(day: 6)),
      (url: file("c"), date: Self.moment(day: 8)), (url: file("z"), date: Self.moment(day: 30)),
    ]
    #expect(Backup.expired(copies, keep: 4, written: file("c"), now: today).isEmpty)
    #expect(Backup.expired(copies, keep: 3, written: file("c"), now: today) == [file("z")])
    #expect(
      Backup.expired(copies, keep: 2, written: file("c"), now: today) == [file("z"), file("a")])
    #expect(
      Backup.expired(copies, keep: 1, written: file("c"), now: today)
        == [file("z"), file("a"), file("b")])
    #expect(
      Backup.expired(copies, keep: 1, written: file("a"), now: today)
        == [file("z"), file("b"), file("c")])
  }

  /// 另选的文件夹：找不到了不替用户建（移动硬盘没插、云盘没登录），也不用去读设置；在的话存一份带这台电脑编号的；
  /// 当天再看是「有了」。几台电脑共用一个文件夹时各认各的：别人今天存过不算我存过，轮换也只动自己的；
  /// 用户自己的文件一个都不动；选的路径其实是个文件也算找不到
  @Test func extraFolderIsPerMac() async throws {
    let calendar = Self.calendar
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data(#"{"app": "Kitty Tools"}"#.utf8)
    let today = Self.moment()
    let missing = root.appending(path: "没插的硬盘/Kitty")
    #expect(
      await SettingsBackup.mirrorState(of: missing, owner: "3F9A", now: today, calendar: calendar)
        == .missing)
    await #expect(throws: SettingsBackup.Failure.missingFolder) {
      try await SettingsBackup.write(
        payload, to: missing, owner: "3F9A", creates: false, now: today, calendar: calendar)
    }
    #expect(!FileManager.default.fileExists(atPath: missing.path))

    let cloud = root.appending(path: "云盘")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    try Data("自己的文件".utf8).write(to: cloud.appending(path: "笔记.txt"))
    let state = { (owner: String, now: Date) in
      await SettingsBackup.mirrorState(of: cloud, owner: owner, now: now, calendar: calendar)
    }
    #expect(await state("3F9A", today) == .due)
    let mine = try await SettingsBackup.write(
      payload, to: cloud, owner: "3F9A", creates: false, now: today, calendar: calendar)
    #expect(mine.lastPathComponent == "Kitty Tools 自动备份 2026-10-08 3F9A.json")
    #expect(await state("3F9A", today) == .done)
    #expect(await state("3F9A", Self.moment(day: 9)) == .due)

    // 另一台电脑（或 Dev 版）也选了这个文件夹：它今天还没存；存了也不盖我的
    #expect(await state("B00C", today) == .due)
    try await SettingsBackup.write(
      Data("另一台的".utf8), to: cloud, owner: "B00C", creates: false, now: today,
      calendar: calendar)
    #expect(try Data(contentsOf: mine) == payload)
    // 它连着存 8 天，只轮换它自己的；我那一份、用户自己的文件都还在
    for day in 9...16 {
      try await SettingsBackup.write(
        payload, to: cloud, owner: "B00C", creates: false, now: Self.moment(day: day),
        calendar: calendar)
    }
    let theirs = SettingsBackup.list(in: cloud, owner: "B00C", calendar: calendar)
    #expect(theirs.count == SettingsBackup.keepDaily)
    #expect(
      SettingsBackup.list(in: cloud, owner: "3F9A", calendar: calendar).map(\.url) == [mine])
    #expect(names(in: cloud).count == 7 + 1 + 1 && names(in: cloud).contains("笔记.txt"))
    // 本机那种（不带编号）的列表不认带编号的：就算把本机的 backups/ 选成了另存的文件夹，两边也不串
    #expect(SettingsBackup.list(in: cloud, calendar: calendar).isEmpty)
    #expect(SettingsBackup.isDue(in: cloud, now: today, calendar: calendar))

    // 选的路径是个文件
    let file = cloud.appending(path: "笔记.txt")
    #expect(
      await SettingsBackup.mirrorState(of: file, owner: "3F9A", now: today, calendar: calendar)
        == .missing)
    #expect(throws: SettingsBackup.Failure.missingFolder) {
      try SettingsBackup.store(
        payload, kind: .daily, in: file, creates: false, now: today, calendar: calendar)
    }
  }

  // MARK: 写什么

  /// 写的就是一份导出文件：导入那边读得回来、和现在的设置一样，里面没有密钥
  @Test func payloadIsAnExportFile() throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: Prefs.clipboardPastePlain)
    var snippet = ClipItem(kind: .text, copiedAt: Self.moment())
    snippet.text = "您好 {cursor}，"
    snippet.isSnippet = true
    let archive = SettingsArchive.capture(
      from: defaults, domainName: name, services: [.zhipu, ai], clips: [snippet],
      version: "9.9.9", now: Self.moment())
    let payload = try #require(SettingsBackup.payload(of: archive))
    #expect(payload.note == nil)
    let read = try SettingsArchive.read(payload.data)
    #expect(read == archive)
    #expect(read.secrets == nil && read.clips?.map(\.text) == ["您好 {cursor}，"])
    #expect(Set(read.sections) == Set(SettingsArchive.Section.allCases))
  }

  /// 哪一类多到导入时不肯收，自动备份就不带哪一类（别的照备），并留一句话：只有生词本超了，片段与收藏照带；
  /// 只有片段超了，生词本照带；都超了两类都不带
  @Test func payloadLeavesOutOversizedData() throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let base = SettingsArchive.capture(
      from: defaults, domainName: name, services: [ai], version: "9.9.9", now: Self.moment())
    let clips = { (count: Int) in
      (0..<count).map {
        SettingsArchive.Clip(
          text: "片段 \($0)", note: nil, favorite: false, snippet: true, group: nil,
          copiedAt: Self.moment())
      }
    }
    let words = { (count: Int) in
      (0..<count).map {
        SettingsArchive.Word(
          source: "w\($0)", target: "zh-Hans", result: "词", service: "", createdAt: Self.moment())
      }
    }

    var archive = base
    archive.clips = clips(2)
    archive.vocabulary = words(SettingsArchive.maxWords + 1)
    var payload = try #require(SettingsBackup.payload(of: archive))
    #expect(payload.note == "生词本太多，自动备份里没带，可以手动导出")
    var read = try SettingsArchive.read(payload.data)
    #expect(read.clips?.count == 2 && read.vocabulary == nil)

    archive.clips = clips(SettingsArchive.maxClips + 1)
    archive.vocabulary = words(1)
    payload = try #require(SettingsBackup.payload(of: archive))
    #expect(payload.note == "片段与收藏太多，自动备份里没带，可以手动导出")
    read = try SettingsArchive.read(payload.data)
    #expect(read.clips == nil && read.clipGroups == nil)
    #expect(read.vocabulary?.count == 1 && read.translateServices?.count == 1)

    archive.vocabulary = words(SettingsArchive.maxWords + 1)
    payload = try #require(SettingsBackup.payload(of: archive))
    #expect(payload.note == "片段与收藏、生词本太多，自动备份里没带，可以手动导出")
    read = try SettingsArchive.read(payload.data)
    #expect(Set(read.sections) == [.preferences, .hotkeys, .services, .engines])
  }

  // MARK: 开关和文件夹只属于这台电脑

  /// 开关默认开；六个键都不注册默认值：不进导出文件，导入「设置」（整类换成文件里的样子）也不会动它们。
  /// 电脑编号第一次要用时生成、存下，之后一直是它；存的值不像编号就重新生成
  @Test func backupPrefsStayOnThisMac() throws {
    let keys = [
      Prefs.settingsBackupEnabled, Prefs.settingsBackupFolder, Prefs.settingsBackupFolderName,
      Prefs.settingsBackupID, Prefs.settingsBackupProblem, Prefs.settingsBackupFolderProblem,
    ]
    #expect(keys.allSatisfy { SettingsArchive.kinds[$0] == nil && Prefs.defaults[$0] == nil })

    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(SettingsBackup.isEnabled(defaults) && SettingsBackup.extraFolder(defaults) == nil)
    defaults.set(false, forKey: Prefs.settingsBackupEnabled)
    defaults.set("/Volumes/备份/Kitty", forKey: Prefs.settingsBackupFolder)
    defaults.set("Kitty", forKey: Prefs.settingsBackupFolderName)
    defaults.set("没能备份", forKey: Prefs.settingsBackupProblem)
    defaults.set("找不到文件夹", forKey: Prefs.settingsBackupFolderProblem)
    #expect(!SettingsBackup.isEnabled(defaults))
    #expect(SettingsBackup.extraFolder(defaults)?.path == "/Volumes/备份/Kitty")
    defaults.set("", forKey: Prefs.settingsBackupFolder)
    #expect(SettingsBackup.extraFolder(defaults) == nil)
    defaults.set("/Volumes/备份/Kitty", forKey: Prefs.settingsBackupFolder)

    #expect(defaults.string(forKey: Prefs.settingsBackupID) == nil)
    let id = SettingsBackup.installID(defaults)
    #expect(id.wholeMatch(of: /[0-9A-F]{4}/) != nil)
    #expect(defaults.string(forKey: Prefs.settingsBackupID) == id)
    #expect(SettingsBackup.installID(defaults) == id)
    defaults.set("不像编号", forKey: Prefs.settingsBackupID)
    let fresh = SettingsBackup.installID(defaults)
    #expect(fresh.wholeMatch(of: /[0-9A-F]{4}/) != nil)
    #expect(defaults.string(forKey: Prefs.settingsBackupID) == fresh)
    let before = keys.map { defaults.object(forKey: $0) as? NSObject }

    let archive = SettingsArchive.capture(
      from: defaults, domainName: name, services: [], now: Self.moment())
    #expect(keys.allSatisfy { archive.preferences?[$0] == nil })
    // 别人给的文件里就算写了这几个键，读的时候也被丢掉；导入「设置」之后本机的六个值原样还在
    let foreign = try SettingsArchive.read(
      Data(
        (#"{"app": "Kitty Tools", "format": 1, "version": "0.3.2", "#
          + #""exportedAt": "2026-10-08T01:00:00Z", "preferences": {"settingsBackupEnabled": true, "#
          + #""settingsBackupFolder": "/tmp/别处", "settingsBackupID": "0000", "#
          + #""\#(Prefs.clipboardPastePlain)": true}}"#).utf8))
    #expect(foreign.preferences?.keys.sorted() == [Prefs.clipboardPastePlain])
    foreign.apply([.preferences], to: defaults, domainName: name)
    #expect(defaults.bool(forKey: Prefs.clipboardPastePlain))
    #expect(keys.map { defaults.object(forKey: $0) as? NSObject } == before)
    #expect(!SettingsBackup.isEnabled(defaults))
  }

  // MARK: 导入前先存一份

  /// 导入的钩子在「密码对了、还什么都没写」的那一刻调一次：密码不对不调（不白存一份）；钩子抛错就不导入、什么都不写；
  /// 正常时钩子里看到的还是导入之前的设置
  @Test func snapshotHookRunsJustBeforeWriting() throws {
    let (source, sourceName) = try suite()
    defer { source.removePersistentDomain(forName: sourceName) }
    source.set(true, forKey: Prefs.clipboardPastePlain)
    var archive = SettingsArchive.capture(
      from: source, domainName: sourceName, services: [.zhipu, ai], now: Self.moment())
    try archive.seal(["zhipu.apiKey": "sk-zhipu"], password: "correct horse 电池")
    archive = try SettingsArchive.read(archive.encoded())

    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    let services = TranslateServiceStore(services: [])
    var keychain: [String: String] = [:]
    var calls = 0
    let all = Set(SettingsArchive.Section.allCases)
    #expect(throws: SettingsArchive.Failure.wrongPassword) {
      try archive.install(
        all, password: "不对的密码", services: services, to: target, domainName: name,
        store: { keychain[$0] = $1 }, beforeWriting: { calls += 1 })
    }
    #expect(calls == 0)

    #expect(throws: SettingsArchive.Failure.backupFailed("盘满了")) {
      try archive.install(
        all, password: "correct horse 电池", services: services, to: target, domainName: name,
        store: { keychain[$0] = $1 },
        beforeWriting: { throw SettingsArchive.Failure.backupFailed("盘满了") })
    }
    #expect(target.persistentDomain(forName: name)?.isEmpty != false)
    #expect(services.services.isEmpty && keychain.isEmpty)
    #expect(
      SettingsArchive.Failure.backupFailed("盘满了").message == "没能先备份现在的设置和数据（盘满了），所以没有导入")

    var seenBefore: Bool?
    try archive.install(
      all, password: "correct horse 电池", services: services, to: target, domainName: name,
      store: { keychain[$0] = $1 },
      beforeWriting: {
        calls += 1
        seenBefore = target.bool(forKey: Prefs.clipboardPastePlain)
      })
    #expect(calls == 1 && seenBefore == false)
    #expect(
      target.bool(forKey: Prefs.clipboardPastePlain) && keychain == ["zhipu.apiKey": "sk-zhipu"])
  }

  // MARK: 每一份的整条路

  /// 本机那份：今天没有就存、当天再来不读设置也不重写；哪一类太多没带记一句、下次都好了收掉；写不成记原因、
  /// 连内容都编不出来也记
  @Test func localBackupRecordsWhatHappened() async throws {
    let calendar = Self.calendar
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appending(path: "backups")
    var captured = 0
    var note: String?
    let payload = { () -> SettingsBackup.Payload? in
      captured += 1
      return (Data("{}".utf8), note)
    }
    let run = { (day: Int, folder: URL) in
      await SettingsBackup.backUpLocal(
        in: folder, defaults: defaults, now: Self.moment(day: day), calendar: calendar,
        payload: payload)
    }
    let problem = { defaults.string(forKey: Prefs.settingsBackupProblem) }

    defaults.set("上次留下的话", forKey: Prefs.settingsBackupProblem)
    await run(8, local)
    #expect(names(in: local) == ["Kitty Tools 自动备份 2026-10-08.json"])
    #expect(captured == 1 && problem() == nil)
    // 当天再来：已有的不重写，设置也不去读
    await run(8, local)
    #expect(captured == 1 && names(in: local).count == 1)

    note = "片段与收藏太多，自动备份里没带，可以手动导出"
    await run(9, local)
    #expect(captured == 2 && problem() == note && names(in: local).count == 2)
    note = nil
    await run(10, local)
    #expect(problem() == nil && names(in: local).count == 3)

    // 写不成（那个位置是个文件）
    let blocked = root.appending(path: "不是文件夹")
    try Data("x".utf8).write(to: blocked)
    await run(11, blocked)
    #expect(problem() == "没能备份：找不到文件夹（没连上、被移走，或者没有访问权限）")
    // 内容编不出来
    await SettingsBackup.backUpLocal(
      in: local, defaults: defaults, now: Self.moment(day: 11), calendar: calendar,
      payload: { nil })
    #expect(problem() == "没能备份：内容编不出来" && names(in: local).count == 3)
  }

  /// 另存的那份：文件夹找不到只记原因，不去读设置（硬盘没插的那些天不白编一遍）、也不替用户建；在的话存一份带这台
  /// 电脑编号的、原因收掉，当天再来什么都不做；等结果的那会儿用户换了文件夹，旧文件夹的结果不记
  @Test func mirrorRecordsWhatHappened() async throws {
    let calendar = Self.calendar
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    var captured = 0
    let payload = { () -> SettingsBackup.Payload? in
      captured += 1
      return (Data("{}".utf8), nil)
    }
    let run = { (folder: URL) in
      await SettingsBackup.mirror(
        to: folder, defaults: defaults, now: Self.moment(), calendar: calendar, payload: payload)
    }
    let problem = { defaults.string(forKey: Prefs.settingsBackupFolderProblem) }

    let missing = root.appending(path: "没插的硬盘")
    defaults.set(missing.path, forKey: Prefs.settingsBackupFolder)
    await run(missing)
    #expect(problem() == "找不到文件夹（没连上、被移走，或者没有访问权限）")
    #expect(captured == 0 && !FileManager.default.fileExists(atPath: missing.path))

    // 插上了：存一份带编号的，原因收掉
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    await run(missing)
    let id = try #require(defaults.string(forKey: Prefs.settingsBackupID))
    #expect(names(in: missing) == ["Kitty Tools 自动备份 2026-10-08 \(id).json"])
    #expect(captured == 1 && problem() == nil)
    await run(missing)
    #expect(captured == 1 && names(in: missing).count == 1)

    // 结果回来时文件夹已经换了（或者不再另存了）：不记到现在这个文件夹头上
    let other = root.appending(path: "换的新文件夹")
    defaults.set(other.path, forKey: Prefs.settingsBackupFolder)
    await run(root.appending(path: "原来那个，已经不在了"))
    #expect(problem() == nil)
    defaults.removeObject(forKey: Prefs.settingsBackupFolder)
    await run(root.appending(path: "原来那个，已经不在了"))
    #expect(problem() == nil)
    // 内容编不出来
    defaults.set(other.path, forKey: Prefs.settingsBackupFolder)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    await SettingsBackup.mirror(
      to: other, defaults: defaults, now: Self.moment(), calendar: calendar, payload: { nil })
    #expect(problem() == "内容编不出来" && names(in: other).isEmpty)
  }

  /// 导入前那一份：开着自动备份才存；存不成（或内容编不出来）抛 backupFailed、带原因——导入那边接到就不动手
  @Test func snapshotBeforeImport() throws {
    let calendar = Self.calendar
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appending(path: "backups")
    let now = Self.moment(hour: 15, minute: 30, second: 12)
    let payload = { () -> SettingsBackup.Payload? in (Data("之前的样子".utf8), nil) }

    defaults.set(false, forKey: Prefs.settingsBackupEnabled)
    try SettingsBackup.snapshot(
      in: local, defaults: defaults, now: now, calendar: calendar, payload: payload)
    #expect(names(in: local).isEmpty)

    defaults.removeObject(forKey: Prefs.settingsBackupEnabled)
    try SettingsBackup.snapshot(
      in: local, defaults: defaults, now: now, calendar: calendar, payload: payload)
    #expect(names(in: local) == ["Kitty Tools 导入前 2026-10-08 153012.json"])
    #expect(
      try Data(contentsOf: local.appending(path: names(in: local)[0])) == Data("之前的样子".utf8))

    #expect(throws: SettingsArchive.Failure.backupFailed("内容编不出来")) {
      try SettingsBackup.snapshot(
        in: local, defaults: defaults, now: now, calendar: calendar, payload: { nil })
    }
    let blocked = root.appending(path: "不是文件夹")
    try Data("x".utf8).write(to: blocked)
    #expect(
      throws: SettingsArchive.Failure.backupFailed("找不到文件夹（没连上、被移走，或者没有访问权限）")
    ) {
      try SettingsBackup.snapshot(
        in: blocked, defaults: defaults, now: now, calendar: calendar, payload: payload)
    }
  }

  // MARK: 说法

  /// 菜单里怎么叫一份备份、设置页那一行怎么说
  @Test func wording() throws {
    let calendar = Self.calendar
    let now = Self.moment(hour: 16)
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let yesterday = SettingsBackup.Copy(
      url: root.appending(path: "a.json"), kind: .daily,
      date: calendar.startOfDay(for: Self.moment(day: 7)))
    #expect(SettingsBackup.title(of: yesterday, now: now, calendar: calendar) == "10 月 7 日（昨天）")
    let before = SettingsBackup.Copy(
      url: root.appending(path: "b.json"), kind: .beforeImport,
      date: Self.moment(hour: 15, minute: 30))
    #expect(
      SettingsBackup.title(of: before, now: now, calendar: calendar) == "导入前 · 10 月 8 日（今天） 15:30")
    // 恢复表单页头里的说法
    #expect(
      SettingsBackup.source(of: yesterday, now: now, calendar: calendar) == "10 月 7 日（昨天）的自动备份")
    #expect(
      SettingsBackup.source(of: before, now: now, calendar: calendar)
        == "10 月 8 日（今天） 15:30 导入前存的备份")

    // 时、分都两位，24 小时制，不跟系统的 12 / 24 小时制走
    #expect(SettingsBackup.when(Self.moment(), now: now, calendar: calendar) == "今天 09:12")
    #expect(
      SettingsBackup.when(Self.moment(hour: 0, minute: 5), now: now, calendar: calendar)
        == "今天 00:05")
    #expect(
      SettingsBackup.when(Self.moment(day: 7, hour: 22, minute: 40), now: now, calendar: calendar)
        == "昨天 22:40")
    #expect(
      SettingsBackup.when(Self.moment(day: 3), now: now, calendar: calendar) == "10 月 3 日（5 天前）")

    #expect(SettingsBackup.summary(of: [], now: now, calendar: calendar) == "还没有备份")
    // 时间取文件的修改时间（每天那份的名字里只有日期）
    let url = try SettingsBackup.store(
      Data("{}".utf8), kind: .daily, in: root, creates: false, now: Self.moment(),
      calendar: calendar)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.moment(hour: 9, minute: 12)], ofItemAtPath: url.path)
    let copies = SettingsBackup.list(in: root, calendar: calendar)
    #expect(
      SettingsBackup.summary(of: copies, now: now, calendar: calendar) == "最近一份：今天 09:12，共 1 份")
  }

  /// 没写成的原因怎么说给用户：文件夹找不到；没权限时说去哪开（真往一个只读文件夹里写一次，认得出系统给的那种错）；
  /// 别的用系统的原话
  @Test func failuresAreExplained() throws {
    #expect(
      SettingsBackup.describe(SettingsBackup.Failure.missingFolder) == "找不到文件夹（没连上、被移走，或者没有访问权限）")
    let denied = "没有权限写这个文件夹（到 系统设置 › 隐私与安全性 › 文件和文件夹 里允许 Kitty Tools，或者换一个文件夹）"
    #expect(SettingsBackup.describe(CocoaError(.fileWriteNoPermission)) == denied)
    for code in [EPERM, EACCES] {
      let wrapped = NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
      #expect(SettingsBackup.describe(wrapped) == denied)
    }
    let full = CocoaError(.fileWriteOutOfSpace)
    #expect(SettingsBackup.describe(full) == full.localizedDescription)

    let locked = try folder()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
      try? FileManager.default.removeItem(at: locked)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    do {
      try SettingsBackup.store(
        Data("{}".utf8), kind: .daily, in: locked, creates: false, now: Self.moment(),
        calendar: Self.calendar)
      Issue.record("只读的文件夹里不该写得进去")
    } catch {
      #expect(SettingsBackup.describe(error) == denied, "\(error)")
    }
    #expect(names(in: locked).isEmpty)
  }

}
