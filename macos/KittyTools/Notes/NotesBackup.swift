// 便签的数据保险（PLAN §10「便签」D④；做法照剪贴板库的 Storage/Backup.swift，两边各管各的文件）：
// - NotesBackup：便签库（数据目录的 notes.sqlite3）每天备份一份到 notes-backups/，一天一个文件夹（notes-2026-10-12/）：
//   里面 notes.sqlite3 是整库的一致快照，images/ 是当时的图片目录 notes-images/（APFS 上是克隆，不占空间），留最近 7 份。
//   和剪贴板的备份不同，**便签整库都备**（都是用户自己写下留着的，「最近删除」里的也在）。另开一个只读连接在主线程外做：
//   库是坏的不备、也不动已有的备份；表是空的不备（没用过便签的人不该每天多一个空文件夹）；先写进半成品文件夹，拷出来的库
//   查过才改成正式的名字、才轮换。**图片尽力而为**：一张张带上，拷不成的记日志，不让这份备份作废（库比图要紧）。
//   什么时候做由 AppDelegate 定（跟着剪贴板库的备份：启动、换日、锁屏），失败只记日志。
// - NotesRecovery：便签库打不开（或者库文件不见了 / 成了空文件，而备份文件夹还在——哪怕都读不出来）时问用户：用最近的
//   备份 / 重新开始 / 这次先不用便签。前两种先把出问题的文件挪进数据目录里带时间的文件夹（damaged-…/，和剪贴板那边是
//   同一种，只挪不删），再开一次；还开不了就当「这次先不用」，不循环。库是更新版本的 Kitty Tools 写的不算坏：不问、不动，
//   这次不可用。弹框在 AppDelegate，这里不碰界面：用户选了什么是传进来的（单测直接给答案）。
// 两条死规矩：便签的问题不让 App 退出（最坏是这次运行里便签不可用，别的功能照常）；这里的任何流程不碰剪贴板的文件
// （kitty.sqlite3、images/、backups/），反过来剪贴板的「重新开始」也不挪便签的三样（NotesBackupTests 两头各锁一个）。
// 已知取舍：永久删除的便签在备份里留到被后面的顶掉为止（7 份；不是每天都开就更久）；便签全删光之后不再备份，
// 已有的那几份一直留着。和 sqlite 的 C 接口打交道的只有 Database。
// ponytail: 起名、列出、挑最近可用的、挪开出问题的文件、问一次再开一次，这些和 Storage/Backup.swift 是平行的两份
// （约 110 行；两边的文件名、备份的形状、三个选择都不一样，而且那边不许动）。第三处要用同一套时，把 setAside 和
// lostDatabase 按文件名参数化、两边共用。

import Foundation
import OSLog

nonisolated enum NotesBackup {
  /// 留最近几份
  static let keep = 7
  /// 库文件名（数据目录里、每个备份文件夹里都叫这个）
  static let databaseName = "notes.sqlite3"
  /// 图片目录在数据目录里的名字（第 7 批行内图片起才有内容）、在备份文件夹里的名字
  static let imagesName = "notes-images"
  static let copiedImagesName = "images"

  /// 一份备份：那个文件夹和它是哪一天的（当地那天的零点）
  struct Copy: Equatable, Sendable {
    let url: URL
    let day: Date

    var database: URL { url.appending(path: NotesBackup.databaseName) }
    var images: URL { url.appending(path: NotesBackup.copiedImagesName) }
  }

  enum Outcome: Equatable, Sendable {
    /// 备好了
    case made(URL)
    /// 今天已经备过
    case notDue
    /// 一条便签都没有：不备
    case empty
    /// 库有问题（读不了、不见了，或者没通过检查）：没备份，已有的备份没动
    case damaged
    /// 别的原因没备成（磁盘满、没权限……）
    case failed(String)
  }

  static func folder(in directory: URL) -> URL { directory.appending(path: "notes-backups") }

  /// 备份文件夹的名字：notes-2026-10-12（当地日期）
  static func name(for day: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: day)
    return String(
      format: "notes-%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// 从名字读回是哪一天；不是备份的名字给 nil
  static func day(of name: String, calendar: Calendar = .current) -> Date? {
    guard let match = name.wholeMatch(of: /notes-(\d{4})-(\d{2})-(\d{2})/) else { return nil }
    return calendar.date(
      from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3)))
  }

  /// 已有的备份，新的在前（只认名字里的日期，别的文件不算；同 Backup.list 的取舍）
  static func list(in directory: URL, calendar: Calendar = .current) -> [Copy] {
    let folder = folder(in: directory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.compactMap { name in
      day(of: name, calendar: calendar).map { Copy(url: folder.appending(path: name), day: $0) }
    }
    .sorted { $0.day > $1.day }
  }

  /// 今天还没备过
  static func isDue(in directory: URL, now: Date = .now, calendar: Calendar = .current) -> Bool {
    !FileManager.default.fileExists(
      atPath: folder(in: directory).appending(path: name(for: now, calendar: calendar)).path)
  }

  /// 最近的、这个版本读得出来的那份备份（最新的那份坏了、或者是更新版本写的，就往前找）
  static func latestUsable(in directory: URL, calendar: Calendar = .current) -> Copy? {
    list(in: directory, calendar: calendar).first { isUsable($0.database) }
  }

  /// 库文件读得出来：页结构是好的，表结构的版本这个版本认识
  static func isUsable(_ file: URL) -> Bool {
    guard let database = try? Database(path: file.path, readOnly: true), database.isIntact(),
      let version = try? database.query("PRAGMA user_version", row: { $0.int(0) }).first
    else { return false }
    return (version ?? 0) <= Int64(NoteStore.schemaVersion)
  }

  /// 今天还没备过就备一份。先写进半成品文件夹（notes.partial/）：整库拷一份、查一遍拷出来的，成了才改成正式的名字、
  /// 再把超过 keep 份的旧备份删掉——哪一步不成，半成品删掉，已有的备份都原样留着。图片目录有东西就带上，尽力而为
  /// （copyImages）：有图拷不成也照样算备好了。
  /// ponytail: 图片靠 APFS 克隆（FileManager.copyItem，不占空间，实测见 Recovery.setAside）；数据目录在别的文件系统上
  /// 就是真拷贝，七份备份 = 图片占七倍。真有人这么用再改成只带新增的图
  @concurrent static func run(
    in directory: URL, now: Date = .now, calendar: Calendar = .current
  ) async -> Outcome {
    let manager = FileManager.default
    let folder = folder(in: directory)
    let target = folder.appending(path: name(for: now, calendar: calendar))
    let partial = folder.appending(path: "notes.partial")
    // 上次做到一半留下的、这次没做成的，都不留在磁盘上
    let discard = { _ = try? manager.removeItem(at: partial) }
    discard()
    guard isDue(in: directory, now: now, calendar: calendar) else { return .notDue }
    guard
      let database = try? Database(
        path: directory.appending(path: databaseName).path, readOnly: true), database.isIntact(),
      let count = try? database.query("SELECT COUNT(*) FROM notes", row: { $0.int(0) }).first
    else { return .damaged }
    guard (count ?? 0) > 0 else { return .empty }
    do {
      try manager.createDirectory(at: partial, withIntermediateDirectories: true)
      let copy = partial.appending(path: databaseName)
      try database.copy(to: copy.path)
      guard isUsable(copy) else { throw Database.Failure(description: "备份出来的文件不完整") }
      copyImages(
        from: directory.appending(path: imagesName), to: partial.appending(path: copiedImagesName))
      try manager.moveItem(at: partial, to: target)
      let copies = list(in: directory, calendar: calendar).map { (url: $0.url, date: $0.day) }
      for old in Backup.expired(copies, keep: keep, written: target, now: now) {
        try? manager.removeItem(at: old)
      }
      return .made(target)
    } catch {
      discard()
      return .failed("\(error)")
    }
  }

  /// 把图片目录里的东西一样样拷进备份（目录是空的、不在就什么都不做）。拷不成的跳过、记一条日志：
  /// 一张读不了的图不该让当天的便签没有备份（同 NotesRecovery.setAside 里「拷不成不算失败」）
  private static func copyImages(from images: URL, to copied: URL) {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: images.path), !names.isEmpty else {
      return
    }
    var failed = names.count
    if (try? manager.createDirectory(at: copied, withIntermediateDirectories: true)) != nil {
      failed = names.count {
        (try? manager.copyItem(at: images.appending(path: $0), to: copied.appending(path: $0)))
          == nil
      }
    }
    if failed > 0 { Log.storage.error("备份便签时有 \(failed) 张图片没拷成（共 \(names.count) 张）") }
  }
}

nonisolated enum NotesRecovery {
  enum Choice: Equatable {
    /// 用最近的备份（Problem.backup）
    case restore
    /// 便签从空的开始
    case startFresh
    /// 这次先不用便签：什么都不动
    case skip
  }

  /// 出了什么事
  struct Problem: Equatable {
    /// 原因（系统的原话，或者「便签的数据库文件不见了」这类）
    let reason: String
    /// 最近一份读得出来的备份；没有就只能重新开始或者先不用
    let backup: NotesBackup.Copy?
    /// 库文件不见了 / 是空的（没有东西可挪开留着，弹框里不说「出问题的数据留在…」）
    var lost = false
    /// 每天的自动备份（backups/ 里的 JSON，SettingsBackup）里最近一份带着便签文字的：弹框里说怎么从它导回来
    var exported: Exported?

    /// 一份带着便签文字的每日 JSON 备份：哪天的、里面几条
    struct Exported: Equatable {
      let day: Date
      let count: Int
    }
  }

  /// 便签这次用不了（带为什么）
  enum Failure: Error, Equatable, CustomStringConvertible {
    /// 用户选了这次先不用便签：什么都没动
    case skipped
    /// 库是更新版本的 Kitty Tools 写的（带说法）：没问，什么都没动
    case newer(String)
    /// 用备份 / 重新开始之后还是打不开（带原因）
    case stillBroken(String)

    var description: String {
      switch self {
      case .skipped: "用户选了这次先不用便签"
      case .newer(let reason), .stillBroken(let reason): reason
      }
    }
  }

  /// 打开便签（open：开库、认版本、建表、读进内存，哪一步抛错都算打不开）。打不开，或者库文件不见了 / 成了空文件而备份
  /// 文件夹还在（lostDatabase；这时直接打开会得到一个空库，用户照着空的接着记，七天后旧备份就被轮换光了）：问 ask，
  /// 照它选的做——
  /// - 用备份：先把备份里的库拷一份到库旁边（拷不成——磁盘满——就什么都还没动），出问题的库连 -wal、-shm 挪进 damaged-…/，
  ///   图片目录留在原地、另拷一份进去，拷好的那份改名成库（备份自己留在 notes-backups/），备份里有、原地没有的图片补回来，
  ///   再开一次；
  /// - 重新开始：库、图片目录、备份目录一起挪进 damaged-…/，再开一次；
  /// - 这次先不用：什么都不动，抛 Failure.skipped。
  /// 库是更新版本写的（NoteStore.Failure.newer）不问：抛 Failure.newer，什么都不动。
  /// 只问一次：再开还失败抛 Failure.stillBroken，不循环。调用方接到 Failure 就是便签这次用不了，App 照常跑。
  /// 在主线程上（问之前要读一下每日 JSON 备份里有没有便签，读导出文件的那一套在主线程）
  @MainActor static func open<T>(
    in directory: URL, now: Date = .now, calendar: Calendar = .current, open: () throws -> T,
    ask: (Problem) -> Choice
  ) throws(Failure) -> T {
    var problem: Problem
    if let lost = lostDatabase(in: directory, calendar: calendar) {
      problem = lost
    } else {
      do {
        return try open()
      } catch let failure as NoteStore.Failure {
        throw Failure.newer("\(failure)")
      } catch {
        problem = Problem(
          reason: "\(error)", backup: NotesBackup.latestUsable(in: directory, calendar: calendar))
      }
    }
    problem.exported = exportedNotes(in: directory, calendar: calendar)
    let choice = ask(problem)
    guard choice != .skip, choice != .restore || problem.backup != nil else {
      throw Failure.skipped
    }
    do {
      let manager = FileManager.default
      let database = directory.appending(path: NotesBackup.databaseName)
      let staged = directory.appending(path: NotesBackup.databaseName + ".restoring")
      try? manager.removeItem(at: staged)
      if choice == .restore, let backup = problem.backup {
        try manager.copyItem(at: backup.database, to: staged)
        // 备份里的库是旧的：换一个电脑编号再用（版本钟的计数退回去了，NoteStore.forgetDevice）
        NoteStore.forgetDevice(inDatabaseAt: staged)
      }
      try setAside(in: directory, everything: choice == .startFresh, now: now, calendar: calendar)
      if choice == .restore, let backup = problem.backup {
        try manager.moveItem(at: staged, to: database)
        restoreImages(from: backup, in: directory)
      }
      return try open()
    } catch {
      throw Failure.stillBroken("\(error)")
    }
  }

  /// 库文件不见了、或者成了空文件，而 notes-backups/ 里还有备份文件夹：当成出了问题。备份读不读得出来都算（都是更新
  /// 版本写的、都坏了也一样是「用过便签、库没了」，不能当成全新安装悄悄建一个空库）；一个备份文件夹都没有才是还没用过
  /// 便签，照常新建。backup 是其中最近一份读得出来的（没有就是 nil，弹框里不给「用备份」）
  static func lostDatabase(in directory: URL, calendar: Calendar = .current) -> Problem? {
    let path = directory.appending(path: NotesBackup.databaseName).path
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    guard size == nil || size == 0, !NotesBackup.list(in: directory, calendar: calendar).isEmpty
    else { return nil }
    return Problem(
      reason: size == nil ? "便签的数据库文件不见了" : "便签的数据库文件是空的",
      backup: NotesBackup.latestUsable(in: directory, calendar: calendar), lost: true)
  }

  /// 每天的自动备份（backups/ 里的「Kitty Tools 自动备份 日期.json」，SettingsBackup）里，最近一份带着便签文字的。
  /// 没有那种备份、读不出来、里面没有便签都是 nil。只读：那个文件夹是剪贴板那边的，这里不动它
  @MainActor static func exportedNotes(in directory: URL, calendar: Calendar = .current)
    -> Problem.Exported?
  {
    let copies = SettingsBackup.list(in: Backup.folder(in: directory), calendar: calendar)
    for copy in copies where copy.kind == .daily {
      if let count = (try? SettingsArchive.read(contentsOf: copy.url))?.notes?.count, count > 0 {
        return Problem.Exported(day: copy.date, count: count)
      }
    }
    return nil
  }

  /// 把出问题的便签库（连 -wal、-shm）挪进 damaged-…/（Recovery.asideFolder：和剪贴板那边同一种文件夹，各建各的），
  /// 名字不变。everything（重新开始）时图片目录和备份目录整个挪进去；不是（用备份）时图片留在原地——恢复出来的便签还要用
  /// ——另拷一份进去（APFS 上是克隆），拷不成不算失败（记日志）。只挪不删；没有东西可留就不建文件夹。返回放到了哪。
  /// 先挪 -shm、-wal 再挪库：挪到一半出错时，留在原地的不能是「没有库、只剩 -wal」。
  /// **只动便签自己的三样**（notes.sqlite3、notes-images/、notes-backups/），剪贴板的文件一个都不碰
  @discardableResult static func setAside(
    in directory: URL, everything: Bool, now: Date = .now, calendar: Calendar = .current
  ) throws -> URL? {
    let manager = FileManager.default
    let images = directory.appending(path: NotesBackup.imagesName)
    let names =
      ["-shm", "-wal", ""].map { NotesBackup.databaseName + $0 }
      + (everything
        ? [NotesBackup.imagesName, NotesBackup.folder(in: directory).lastPathComponent] : [])
    let present = names.filter { manager.fileExists(atPath: directory.appending(path: $0).path) }
    let copiesImages =
      !everything && (try? manager.contentsOfDirectory(atPath: images.path))?.isEmpty == false
    guard !present.isEmpty || copiesImages else { return nil }
    let folder = Recovery.asideFolder(in: directory, now: now, calendar: calendar)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in present {
      try manager.moveItem(at: directory.appending(path: name), to: folder.appending(path: name))
    }
    if copiesImages {
      do {
        try manager.copyItem(at: images, to: folder.appending(path: NotesBackup.imagesName))
      } catch {
        Log.storage.error("用便签的备份时没能把图片留一份：\(error)")
      }
    }
    return folder
  }

  /// 用备份之后：备份里有、图片目录里没有的图片补回来（原地已有的不动、不覆盖）。补不成只记日志——便签的文字已经回来了
  private static func restoreImages(from backup: NotesBackup.Copy, in directory: URL) {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: backup.images.path), !names.isEmpty
    else { return }
    let images = directory.appending(path: NotesBackup.imagesName)
    do {
      try manager.createDirectory(at: images, withIntermediateDirectories: true)
      for name in names where !manager.fileExists(atPath: images.appending(path: name).path) {
        try manager.copyItem(
          at: backup.images.appending(path: name), to: images.appending(path: name))
      }
    } catch {
      Log.storage.error("用便签的备份时没能把图片补回来：\(error)")
    }
  }

  /// 弹框的文字和按钮（纯函数，配单测）；按钮和 choices 一一对应，第一个是默认，最后一个总是「这次先不用便签」（Esc）。
  /// 每日 JSON 备份里带着便签文字时（problem.exported）多一段：重新开始之后怎么从那一份把文字导回来
  /// （那些 JSON 在 backups/ 里，便签的三个选择都不挪它们，设置里「从备份恢复」列得出来）
  static func wording(
    for problem: Problem, directory: URL, now: Date = .now, calendar: Calendar = .current
  ) -> (title: String, text: String, buttons: [String], choices: [Choice]) {
    let place = (directory.path as NSString).abbreviatingWithTildeInPath
    let title = "便签打不开了"
    let head = "便签的数据读不出来了。剪贴板、翻译和别的功能不受影响。"
    let fresh = "重新开始：便签从空的开始；现在的便签数据、图片和备份一起挪开留着。"
    let skip = "这次先不用便签：什么都不动，便签这次用不了，下次打开 Kitty Tools 时再试。"
    let kept = "挪开的文件不会删，在数据目录（\(place)）里一个「damaged-日期-时间」的文件夹里。"
    let reason = "原因：\(problem.reason)"
    let tail =
      [kept]
      + (problem.exported.map { saved in
        let day = Recovery.describe(saved.day, now: now, calendar: calendar)
        return [
          "选了重新开始，便签的文字之后还能导回来：到 设置 › 通用 点「从备份恢复」，选 \(day)那份，只勾「便签」"
            + "（\(saved.count) 条；图片和「最近删除」里的不在里面）。"
        ]
      } ?? []) + [reason]
    guard let backup = problem.backup else {
      return (
        title, ([head + "也没有可用的备份。", fresh + "\n" + skip] + tail).joined(separator: "\n\n"),
        ["重新开始", "这次先不用便签"], [.startFresh, .skip]
      )
    }
    let day = Recovery.describe(backup.day, now: now, calendar: calendar)
    let restore =
      "用备份：便签回到 \(day)备份时的样子，那之后写的、改的不在里面。"
      + (problem.lost ? "" : "出问题的便签数据留在「damaged-日期-时间」文件夹里。")
    return (
      title,
      ([head, [restore, fresh, skip].joined(separator: "\n")] + tail).joined(separator: "\n\n"),
      ["用 \(day)的备份", "重新开始", "这次先不用便签"], [.restore, .startFresh, .skip]
    )
  }

  /// 没问就用不了（更新版本写的）、问过之后还是开不了：说一声的标题和正文。用户自己选的「这次先不用」不用再说，给 nil。
  /// 更新版本写的那种用刘海岛说（不拦着启动；正文是岛上放得下的一行，完整的原因在日志里），还是开不了的用弹框
  /// （只有一个「好」）——怎么出在 AppDelegate.openNotes
  static func notice(for failure: Failure, directory: URL) -> (title: String, text: String)? {
    switch failure {
    case .skipped: return nil
    case .newer: return ("便签这次用不了", "数据是更新版本写的，更新后照常可用")
    case .stillBroken(let reason):
      let place = (directory.path as NSString).abbreviatingWithTildeInPath
      return (
        "便签还是打不开",
        "便签这次用不了，下次打开 Kitty Tools 时再试。剪贴板、翻译和别的功能不受影响。\n\n"
          + "已经挪开的文件没有删，在数据目录（\(place)）里的「damaged-日期-时间」文件夹里。\n\n原因：\(reason)"
      )
    }
  }
}
