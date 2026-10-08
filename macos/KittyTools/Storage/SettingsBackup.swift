// 设置与数据的每日自动备份（2026-10-08，用户提议「导出功能加一个本地自动定时备份，防止数据丢失」；对标 Raycast 的定时导出：
// 付费版功能，每天 / 每周 / 每月导出到用户选的文件夹、留最近几份）。备份的就是导出文件（Storage/SettingsArchive.swift：设置、
// 快捷键、翻译服务、网页搜索、片段与文字收藏、生词本；**不带密钥**——密钥只在钥匙串里，带出来要用户自己设密码，自动的没法问），
// 所以恢复就是导入：设置 › 通用「从备份恢复」列出有哪几份，选一份走导入表单。导入的规矩照旧——设置、快捷键整类换回那天的样子；
// 两张列表和数据是合并：没有的加回来、同一条改回去，**不删**后来多出来的。补的是数据库每日备份（Backup.swift）管不到的：
// 设置、快捷键、两张列表原来没有任何自动备份；数据库的备份只在库打不开时用得上，误删的片段没法从里面找回来。
//
// 两种文件，都在数据目录的 backups/（和数据库的备份在一起）：
// - 每天一份「Kitty Tools 自动备份 2026-10-08.json」，留最近 keepDaily 份。什么时候做跟数据库的备份走
//   （AppDelegate.backupIfDue：启动、换日、锁屏时看一眼今天存过没有，不加定时器）；
// - 导入前一份「Kitty Tools 导入前 2026-10-08 153012.json」，留最近 keepBeforeImport 份、最多 beforeImportDays 天：
//   导入改掉的设置和快捷键照它换得回去（导入加进来的服务、链接、片段、生词不会因此删掉）。从备份恢复本身也是导入，同样先存一份。
// 用户还可以另选一个文件夹（云盘、移动硬盘，Prefs.settingsBackupFolder），每天那份也存一份过去：本机那份防不住硬盘坏、
// 换电脑、卸载工具把数据目录清掉。那边的文件名多带这台电脑的编号（「… 2026-10-08 3F9A.json」）：几台电脑、正式版和 Dev 版
// 可以共用一个文件夹，各认各的——不带的话，先写的那台让别的都以为「今天备过了」，新电脑的空备份几天就把旧电脑的全顶掉。
// 那个文件夹里只动这台电脑自己写的文件，文件夹不在了不替用户建。
// 开关（Prefs.settingsBackupEnabled，默认开）、另存的文件夹和它的名字、电脑编号、没备成的原因都是这台电脑自己的状态：
// 不注册默认值，不跟着导出 / 导入走（别人给的文件不该能关掉备份、改备份存到哪）。
// 留意：备份是明文（服务地址里自己写进去的令牌、片段和收藏的正文都在里面），另选了云盘文件夹就会同步上去；删掉的片段在备份里
// 留到被后面的顶掉为止（7 份不等于 7 天：不是每天都开的话更久；关掉开关后已有的备份不删、也不再轮换）。
// 这里管文件（起名、认名、列出、写、轮换）、「写什么」（payload）和每一份的整条路（backUpLocal / mirror / snapshot：
// 该不该写、写、把没写成的原因记进偏好）；什么时候调、别叠着调在 AppDelegate，界面在 Settings/SettingsTransfer.swift。
// 另选的文件夹可能在卡住的网络盘上：碰它的（看在不在、写）都在主线程外；本机的 backups/ 是本机磁盘，看一眼、列一下当场做。

import Foundation
import OSLog

nonisolated enum SettingsBackup {
  /// 每天那份留最近几份（用户定的 7：每天都用的话，一周内误删的片段、改乱的设置找得回来）
  static let keepDaily = 7
  /// 导入前那份留最近几份、最多留几天（一周前的退路已经没用了，每天那份管着；不清的话只导入过一次的人那份会一直留着）
  static let keepBeforeImport = 3
  static let beforeImportDays = 7
  /// 备份有变化（写了一份、轮换了）：设置页那几行重新列。在主线程上发
  static let changed = Notification.Name("SettingsBackup.changed")

  enum Kind: Equatable, Sendable {
    /// 每天一份
    case daily
    /// 导入前先存的一份
    case beforeImport
  }

  /// 一份备份：文件、哪一种、哪天的（每天那份是当地那天的零点，导入前那份是存的那一刻）
  struct Copy: Equatable, Identifiable, Sendable {
    let url: URL
    let kind: Kind
    let date: Date
    var id: URL { url }
  }

  enum Failure: Error, Equatable {
    /// 要写的文件夹找不到（或者那个路径不是文件夹）
    case missingFolder
  }

  /// 另选的文件夹现在什么样（mirrorState）
  enum Mirror: Equatable, Sendable {
    /// 这台电脑今天那份已经在了
    case done
    /// 文件夹在，今天那份还没有
    case due
    /// 文件夹找不到（移动硬盘没插、云盘没登录……）
    case missing
  }

  // MARK: 开关、文件夹、编号（不注册默认值，见文件头）

  /// 每天自动备份开着（没存过 = 开）
  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: Prefs.settingsBackupEnabled) as? Bool ?? true
  }

  /// 用户另选的文件夹；没选是 nil
  static func extraFolder(_ defaults: UserDefaults = .standard) -> URL? {
    guard let path = defaults.string(forKey: Prefs.settingsBackupFolder), !path.isEmpty else {
      return nil
    }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  /// 这台电脑的编号（4 位十六进制；第一次要用时生成、存下）：另存的文件夹里用它分清是谁写的
  static func installID(_ defaults: UserDefaults = .standard) -> String {
    if let id = defaults.string(forKey: Prefs.settingsBackupID),
      id.wholeMatch(of: /[0-9A-F]{4}/) != nil
    {
      return id
    }
    let id = String(UUID().uuidString.prefix(4))
    defaults.set(id, forKey: Prefs.settingsBackupID)
    return id
  }

  // MARK: 文件名

  /// 「Kitty Tools 自动备份 2026-10-08.json」/「Kitty Tools 导入前 2026-10-08 153012.json」（当地时间）；
  /// owner：另存的文件夹里每天那份多带电脑编号——「Kitty Tools 自动备份 2026-10-08 3F9A.json」（导入前那份只在本机，不带）
  static func name(
    for kind: Kind, at date: Date, owner: String? = nil, calendar: Calendar = .current
  ) -> String {
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    let day = String(
      format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    switch kind {
    case .daily: return "Kitty Tools 自动备份 \(day)\(owner.map { " " + $0 } ?? "").json"
    case .beforeImport:
      let time = String(
        format: "%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
      return "Kitty Tools 导入前 \(day) \(time).json"
    }
  }

  /// 从文件名认出是哪一种、什么时候的、谁写的；别的文件（数据库的备份、用户自己导出的「Kitty Tools 设置 ….json」、
  /// 云盘同步冲突留下的「… 2.json」）给 nil
  static func parse(_ name: String, calendar: Calendar = .current) -> (
    kind: Kind, date: Date, owner: String?
  )? {
    if let match = name.wholeMatch(
      of: /Kitty Tools 自动备份 (\d{4})-(\d{2})-(\d{2})(?: ([0-9A-F]{4}))?\.json/)
    {
      let day = DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))
      return calendar.date(from: day).map { (.daily, $0, match.4.map { String($0) }) }
    }
    if let match = name.wholeMatch(
      of: /Kitty Tools 导入前 (\d{4})-(\d{2})-(\d{2}) (\d{2})(\d{2})(\d{2})\.json/)
    {
      let moment = DateComponents(
        year: Int(match.1), month: Int(match.2), day: Int(match.3), hour: Int(match.4),
        minute: Int(match.5), second: Int(match.6))
      return calendar.date(from: moment).map { (.beforeImport, $0, nil) }
    }
    return nil
  }

  // MARK: 列出

  /// 这个文件夹里的备份，新的在前（只认文件名）。owner：本机的 backups/ 给 nil（那里的不带编号）；另存的文件夹给这台
  /// 电脑的编号，只列自己写的。
  /// ponytail: 同 Backup.list，只认文件名里的日期：系统时钟调到过未来时写下的那几份，轮换时先删（Backup.expired）；
  /// 份数还没满时会留着，真到了那天会被当成「今天备过了」。要管就改成看文件的修改时间
  static func list(in folder: URL, owner: String? = nil, calendar: Calendar = .current) -> [Copy] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.compactMap { name -> Copy? in
      guard let parsed = parse(name, calendar: calendar), parsed.owner == owner else { return nil }
      return Copy(url: folder.appending(path: name), kind: parsed.kind, date: parsed.date)
    }
    .sorted { $0.date > $1.date }
  }

  /// 今天那份还没有
  static func isDue(
    in folder: URL, owner: String? = nil, now: Date = .now, calendar: Calendar = .current
  ) -> Bool {
    let name = name(for: .daily, at: now, owner: owner, calendar: calendar)
    return !FileManager.default.fileExists(atPath: folder.appending(path: name).path)
  }

  /// 另选的文件夹现在什么样：找不到 / 这台电脑今天那份有了 / 该存了。在主线程外看（它可能在卡住的网络盘上）；
  /// 先看这个再去读设置、编内容：硬盘没插的那些天不用每次白编一遍
  @concurrent static func mirrorState(
    of folder: URL, owner: String, now: Date = .now, calendar: Calendar = .current
  ) async -> Mirror {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return .missing }
    return isDue(in: folder, owner: owner, now: now, calendar: calendar) ? .due : .done
  }

  // MARK: 写

  /// 写一份进这个文件夹（原子写），再轮换：同一种、同一台电脑的只留最近几份（Backup.expired：刚写的这份不删，
  /// 日期比现在还晚的先删）；往本机写每天那份时，顺手把过了 beforeImportDays 天的「导入前」清掉。只删自己认得的名字。
  /// creates：文件夹不在时建不建——本机的 backups/ 建；用户另选的不建（不在了多半是移动硬盘没插、云盘没登录，
  /// 建一个同名的空文件夹只会把备份存到别处）。同一秒里第二份「导入前」不写：先存的那份是更早的样子，留它
  @discardableResult static func store(
    _ data: Data, kind: Kind, in folder: URL, owner: String? = nil, creates: Bool,
    now: Date = .now, calendar: Calendar = .current
  ) throws -> URL {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw Failure.missingFolder }
    } else {
      guard creates else { throw Failure.missingFolder }
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let owner = kind == .daily ? owner : nil
    let target = folder.appending(path: name(for: kind, at: now, owner: owner, calendar: calendar))
    if kind == .beforeImport, manager.fileExists(atPath: target.path) { return target }
    try data.write(to: target, options: .atomic)
    let mine = list(in: folder, owner: owner, calendar: calendar)
    let stale = Backup.expired(
      mine.filter { $0.kind == kind }.map { (url: $0.url, date: $0.date) },
      keep: kind == .daily ? keepDaily : keepBeforeImport, written: target, now: now)
    for url in stale { try? manager.removeItem(at: url) }
    if kind == .daily, owner == nil,
      let cutoff = calendar.date(byAdding: .day, value: -beforeImportDays, to: now)
    {
      for old in mine where old.kind == .beforeImport && old.date < cutoff {
        try? manager.removeItem(at: old.url)
      }
    }
    return target
  }

  /// 每天那份写进一个文件夹，在主线程外做（另选的文件夹可能在网络盘上；本机那份也走这里，不占主线程）
  @concurrent static func write(
    _ data: Data, to folder: URL, owner: String? = nil, creates: Bool, now: Date = .now,
    calendar: Calendar = .current
  ) async throws -> URL {
    try store(
      data, kind: .daily, in: folder, owner: owner, creates: creates, now: now, calendar: calendar)
  }

  /// 没写成的原因，说给用户的：文件夹找不到、没权限（给出去哪开），其余用系统的原话
  static func describe(_ error: Error) -> String {
    if error as? Failure == .missingFolder { return "找不到文件夹（没连上、被移走，或者没有访问权限）" }
    let cocoa = error as NSError
    let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError
    let denied =
      underlying?.domain == NSPOSIXErrorDomain
      && [EPERM, EACCES].contains(Int32(underlying?.code ?? 0))
    if denied || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileWriteNoPermissionError)
    {
      return "没有权限写这个文件夹（到 系统设置 › 隐私与安全性 › 文件和文件夹 里允许 Kitty Tools，或者换一个文件夹）"
    }
    return error.localizedDescription
  }

  // MARK: 写什么

  /// 要写的内容：整份导出文件。片段与收藏、生词本哪一类多到导入时不肯收（条数超了，要有几千条收藏才到得了）就不带哪一类，
  /// 别的照备，并给一句说明（note）；条数都没超、只是整个文件太大时先不带片段与收藏（大的多半是它），还大再不带生词本；
  /// 连设置都编不出来给 nil
  @MainActor static func payload(of archive: SettingsArchive) -> (data: Data, note: String?)? {
    var kept = Set(SettingsArchive.Section.allCases)
    if (archive.clips?.count ?? 0) > SettingsArchive.maxClips
      || (archive.clipGroups?.count ?? 0) > SettingsArchive.maxGroups
    {
      kept.remove(.clips)
    }
    if (archive.vocabulary?.count ?? 0) > SettingsArchive.maxWords { kept.remove(.vocabulary) }
    let droppable = [SettingsArchive.Section.clips, .vocabulary]
    while true {
      let candidate = archive.keeping(kept)
      guard let data = try? candidate.encoded() else { return nil }
      guard candidate.exportProblem(encodedSize: data.count) != nil else {
        let names = droppable.filter { !kept.contains($0) }.map(\.title).joined(separator: "、")
        return (data, names.isEmpty ? nil : "\(names)太多，自动备份里没带，可以手动导出")
      }
      guard let next = droppable.first(where: kept.contains) else { return nil }
      kept.remove(next)
    }
  }

  // MARK: 每一份的整条路

  /// 现在的设置与数据编好的样子（payload 的结果）；AppDelegate 给的闭包现读现编，一次备份里两份共用一份
  typealias Payload = (data: Data, note: String?)

  /// 本机那份：今天还没有就存一份（已有的不重写，也不去读设置）。结果记进 Prefs.settingsBackupProblem——
  /// 没备成的原因，或者备成了但哪一类太多没带；都好就删掉这个键。写了就发 changed
  @MainActor static func backUpLocal(
    in folder: URL, defaults: UserDefaults = .standard, now: Date = .now,
    calendar: Calendar = .current, payload: () -> Payload?
  ) async {
    guard isDue(in: folder, now: now, calendar: calendar) else { return }
    let content = payload()
    var problem = content == nil ? "没能备份：内容编不出来" : content?.note
    if let content {
      do {
        let url = try await write(
          content.data, to: folder, creates: true, now: now, calendar: calendar)
        Log.storage.notice("已备份设置与数据：\(url.lastPathComponent, privacy: .public)")
      } catch {
        Log.storage.error("设置与数据的自动备份没写成：\(error)")
        problem = "没能备份：\(describe(error))"
      }
    }
    record(problem, forKey: Prefs.settingsBackupProblem, in: defaults)
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// 另存到用户选的文件夹的那份：先在主线程外看文件夹（找不到就只记原因，不去读设置——硬盘没插的那些天不白编一遍），
  /// 这台电脑今天那份还没有就存一份。结果记进 Prefs.settingsBackupFolderProblem（存成了、本来就有就删掉这个键）；
  /// 等的这一会儿用户换了文件夹、不再另存了，这个结果说的已经不是现在的文件夹，不记
  @MainActor static func mirror(
    to folder: URL, defaults: UserDefaults = .standard, now: Date = .now,
    calendar: Calendar = .current, payload: () -> Payload?
  ) async {
    let owner = installID(defaults)
    var problem: String?
    switch await mirrorState(of: folder, owner: owner, now: now, calendar: calendar) {
    case .done: break
    case .missing: problem = describe(Failure.missingFolder)
    case .due:
      if let content = payload() {
        do {
          _ = try await write(
            content.data, to: folder, owner: owner, creates: false, now: now, calendar: calendar)
          Log.storage.notice("设置与数据另存了一份到用户选的文件夹")
        } catch {
          problem = describe(error)
        }
      } else {
        problem = "内容编不出来"
      }
    }
    guard extraFolder(defaults)?.path == folder.path else { return }
    // 原因里可能带着用户文件夹的路径，不进日志
    if problem != nil { Log.storage.error("设置与数据另存的那份没存成") }
    record(problem, forKey: Prefs.settingsBackupFolderProblem, in: defaults)
  }

  /// 导入（和从备份恢复）动手之前，把现在的存一份在本机 backups/（开着自动备份时；关着什么都不做）：导入改掉的设置和
  /// 快捷键照它换得回去。只写本机磁盘上一个小文件，当场写；存不成就抛 backupFailed（带原因），导入不做
  @MainActor static func snapshot(
    in folder: URL, defaults: UserDefaults = .standard, now: Date = .now,
    calendar: Calendar = .current, payload: () -> Payload?
  ) throws {
    guard isEnabled(defaults) else { return }
    guard let content = payload() else {
      throw SettingsArchive.Failure.backupFailed("内容编不出来")
    }
    do {
      try store(
        content.data, kind: .beforeImport, in: folder, creates: true, now: now, calendar: calendar)
    } catch {
      throw SettingsArchive.Failure.backupFailed(describe(error))
    }
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// 有话就记下，没有就删掉那个键
  private static func record(_ problem: String?, forKey key: String, in defaults: UserDefaults) {
    if let problem {
      defaults.set(problem, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: 说法

  /// 菜单里怎么称呼一份备份：「10 月 7 日（昨天）」「导入前 · 10 月 8 日（今天） 15:30」
  static func title(of copy: Copy, now: Date = .now, calendar: Calendar = .current) -> String {
    let day = Recovery.describe(copy.date, now: now, calendar: calendar)
    guard copy.kind == .beforeImport else { return day }
    return "导入前 · \(day) \(time(copy.date, calendar: calendar))"
  }

  /// 恢复表单页头里怎么说这份备份：「10 月 7 日（昨天）的自动备份」「10 月 8 日（今天） 15:30 导入前存的备份」
  static func source(of copy: Copy, now: Date = .now, calendar: Calendar = .current) -> String {
    let day = Recovery.describe(copy.date, now: now, calendar: calendar)
    guard copy.kind == .beforeImport else { return "\(day)的自动备份" }
    return "\(day) \(time(copy.date, calendar: calendar)) 导入前存的备份"
  }

  /// 设置 › 通用那一行的说明：「最近一份：今天 09:12，共 5 份」；一份都没有时「还没有备份」。
  /// 时间取文件的修改时间（每天那份的名字里只有日期）
  static func summary(of copies: [Copy], now: Date = .now, calendar: Calendar = .current) -> String
  {
    guard let latest = copies.first else { return "还没有备份" }
    let written =
      (try? latest.url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? latest.date
    return "最近一份：\(when(written, now: now, calendar: calendar))，共 \(copies.count) 份"
  }

  /// 「今天 09:12」「昨天 22:40」，更早「10 月 3 日（5 天前）」
  static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let days =
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
      ).day ?? 0
    switch days {
    case ...0: return "今天 \(time(date, calendar: calendar))"
    case 1: return "昨天 \(time(date, calendar: calendar))"
    default: return Recovery.describe(date, now: now, calendar: calendar)
    }
  }

  /// 时:分，都写两位、24 小时制（同翻译历史行右侧的时间）
  private static func time(_ date: Date, calendar: Calendar) -> String {
    date.formatted(
      Date.FormatStyle(
        locale: Locale(identifier: "zh-Hans"), calendar: calendar, timeZone: calendar.timeZone
      )
      .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
  }
}
