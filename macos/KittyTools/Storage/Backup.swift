// 数据保险（第二轮体检 S2）：片段、收藏、收藏夹、生词本、启动器收藏都只在一个库文件里
// （Application Support/<bundle id>/kitty.sqlite3），坏了就全没了。两件事：
// - Backup：每天自动备份一份到数据目录的 backups/（kitty-2026-10-02.sqlite3），留最近 3 份。**备份里只有用户明确留下的**：
//   收藏 / 片段 / 收藏夹里的剪贴板条目、收藏夹、生词本（收藏的翻译）、启动器收藏。普通剪贴板历史（连富文本、识别出的文字）、
//   没收藏的翻译历史、启动器的使用记录不进备份——它们有保留天数、退出 / 锁屏清空、单条删除、清空这些控制，备份不能让删掉的
//   内容在磁盘上多留几天。做法：另开一个只读连接在主线程外做（不碰主线程上那个连接），先查库是不是好的，坏的不备份、也不动
//   已有的备份；整库拷出一份半成品，在它上面删掉不留的行、再整理一遍（删掉的内容不留在空闲页里），查过是好的才改成正式的
//   名字、才把最旧的轮换掉。什么时候做由 AppDelegate 定（启动时、系统换日时、锁屏时看一眼今天备过没有）。失败只记日志。
// - Recovery：库打不开（或者库文件不见了 / 成了空文件，而备份还在）时不直接退出，问用户用最近的备份、重新开始还是退出。
//   前两种都先把出问题的文件挪进数据目录里一个带时间的文件夹（damaged-20261002-213045/，不删），再恢复 / 新建、再开一次；
//   还开不了就报错，不循环。弹框在 AppDelegate，这里不碰界面：用户选了什么是传进来的（单测直接给答案）。
// 图片（images/）不备份：用了备份之后，留下的图片条目文件还在就照常、不在的显示占位；普通图片的条目不在备份里，它们的文件
// 会被启动时的孤儿清理删掉——所以用备份时把当时的 images/ 也拷一份进 damaged-…/（挪开的坏库里那些图片条目才不是空壳；
// APFS 上是克隆，不占空间）。钥匙串和偏好不在这里管。和 sqlite 的 C API 打交道的只有 Database。

import Foundation
import OSLog

nonisolated enum Backup {
  /// 留最近几份
  static let keep = 3
  /// 库文件名（数据目录里）
  static let databaseName = "kitty.sqlite3"
  /// 备份里不留的行（留下的见文件头）。条件都用各自仓库里现成的那一份，不另写一套：剪贴板的「留下的条目」在
  /// ClipItem.isRetained 旁边，翻译历史和启动器用的是它们各自「清空」的那一句
  static let dropped = [
    "DELETE FROM clips WHERE NOT (\(ClipItem.retainedSQL))", HistoryStore.dropNonFavorites,
    LauncherUsage.dropUsage,
  ]

  /// 一份备份：文件和它是哪一天的（当地那天的零点）
  struct Copy: Equatable {
    let url: URL
    let day: Date
  }

  enum Outcome: Equatable {
    /// 备好了
    case made(URL)
    /// 今天已经备过
    case notDue
    /// 库有问题（读不了、不见了，或者没通过检查）：没备份，已有的备份没动
    case damaged
    /// 别的原因没备成（磁盘满、没权限……）
    case failed(String)
  }

  static func folder(in directory: URL) -> URL { directory.appending(path: "backups") }

  /// 备份的文件名：kitty-2026-10-02.sqlite3（当地日期）
  static func name(for day: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: day)
    return String(
      format: "kitty-%04d-%02d-%02d.sqlite3", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// 从文件名读回是哪一天；不是备份的名字给 nil
  static func day(of name: String, calendar: Calendar = .current) -> Date? {
    guard let match = name.wholeMatch(of: /kitty-(\d{4})-(\d{2})-(\d{2})\.sqlite3/) else {
      return nil
    }
    return calendar.date(
      from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3)))
  }

  /// 已有的备份，新的在前（按文件名里的日期；别的文件不算）。
  /// ponytail: 只认文件名里的日期。系统时钟调到过未来时写下的那几份，轮换时先删（expired）；份数还没满时会留着，
  /// 真到了那天会被当成「今天备过了」（内容是调时钟那天的）。要管就改成看文件的修改时间
  static func list(in directory: URL, calendar: Calendar = .current) -> [Copy] {
    let folder = folder(in: directory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.compactMap { name in
      day(of: name, calendar: calendar).map { Copy(url: folder.appending(path: name), day: $0) }
    }
    .sorted { $0.day > $1.day }
  }

  /// 轮换时该删哪几份（纯函数；设置与数据的每日备份 SettingsBackup 也用它）：连刚写的那份一共留 keep 份。
  /// **刚写的那份（written）不删**——只按日期留最新的几份的话，系统时钟调到过未来时写下的那几份会一直排在最前面，
  /// 刚写的反而当场被删掉，之后每次都白备；多出来的先删日期比现在还晚的（旧的先删），再删最旧的
  static func expired(
    _ copies: [(url: URL, date: Date)], keep: Int, written: URL, now: Date
  ) -> [URL] {
    let others = copies.filter { $0.url.path != written.path }.sorted { $0.date < $1.date }
    let ahead = others.filter { $0.date > now }
    let order = ahead + others.filter { $0.date <= now }
    return order.prefix(max(others.count - max(keep - 1, 0), 0)).map(\.url)
  }

  /// 今天还没备过
  static func isDue(in directory: URL, now: Date = .now, calendar: Calendar = .current) -> Bool {
    !FileManager.default.fileExists(
      atPath: folder(in: directory).appending(path: name(for: now, calendar: calendar)).path)
  }

  /// 最近的、读得出来的那份备份（最新的那份坏了就往前找）
  static func latestUsable(in directory: URL, calendar: Calendar = .current) -> Copy? {
    list(in: directory, calendar: calendar).first {
      (try? Database(path: $0.url.path, readOnly: true))?.isIntact() == true
    }
  }

  /// 今天还没备过就备一份。先整库拷成半成品（kitty.partial），在它上面删掉不留的行、整理、检查，都成了才改成正式的名字、
  /// 再把超过 keep 份的旧备份删掉——哪一步不成，半成品删掉，已有的备份都原样留着
  @concurrent static func run(
    in directory: URL, now: Date = .now, calendar: Calendar = .current
  ) async -> Outcome {
    let manager = FileManager.default
    let folder = folder(in: directory)
    let target = folder.appending(path: name(for: now, calendar: calendar))
    let partial = folder.appending(path: "kitty.partial")
    // 半成品在删行之前是整库（带普通历史）：上次做到一半留下的、这次没做成的，连它的回滚日志一起删，不留在磁盘上
    let discard = {
      for suffix in ["", "-journal"] { try? manager.removeItem(atPath: partial.path + suffix) }
    }
    discard()
    guard isDue(in: directory, now: now, calendar: calendar) else { return .notDue }
    guard
      let database = try? Database(
        path: directory.appending(path: databaseName).path, readOnly: true), database.isIntact()
    else { return .damaged }
    do {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      try database.copy(to: partial.path)
      try strip(partial)
      try manager.moveItem(at: partial, to: target)
      let copies = list(in: directory, calendar: calendar).map { (url: $0.url, date: $0.day) }
      for old in expired(copies, keep: keep, written: target, now: now) {
        try? manager.removeItem(at: old)
      }
      return .made(target)
    } catch {
      discard()
      return .failed("\(error)")
    }
  }

  /// 在拷出来的那份上删掉不留的行，再 VACUUM 一遍（只删行的话，内容还留在文件的空闲页里），最后查一遍是不是好的。
  /// 不用 WAL：备份是单个文件。返回时连接已经关了，外面才能给文件改名
  private static func strip(_ copy: URL) throws {
    let database = try Database(path: copy.path, wal: false)
    for statement in dropped { try database.execute(statement) }
    try database.execute("VACUUM")
    guard database.isIntact() else { throw Database.Failure(description: "备份出来的文件不完整") }
  }
}

nonisolated enum Recovery {
  enum Choice: Equatable {
    /// 用最近的备份（Problem.backup）
    case restore
    /// 从空的开始
    case startFresh
    case quit
  }

  /// 出了什么事
  struct Problem: Equatable {
    /// 原因（系统的原话或者「数据库文件不见了」这类）
    let reason: String
    /// 最近一份读得出来的备份；没有就只能重新开始
    let backup: Backup.Copy?
    /// 库文件不见了 / 是空的（没有东西可挪开留着，弹框里不说「数据还在里面」）
    var lost = false
    /// backups/ 里有设置与数据的自动备份（SettingsBackup 每天那份 JSON）：片段、文字收藏和生词本在里面还有一份。
    /// 选了重新开始它们跟着 backups/ 一起挪开、设置里「从备份恢复」是空的，弹框里说怎么用「导入…」导回来
    var hasSettingsBackup = false
  }

  enum Failure: Error, Equatable, CustomStringConvertible {
    /// 用户选了退出：什么都没动
    case quit
    /// 恢复 / 重新开始之后还是打不开（带原因）
    case stillBroken(String)

    var description: String {
      switch self {
      case .quit: "用户选了退出"
      case .stillBroken(let reason): reason
      }
    }
  }

  /// 打开数据（open：开库、建表、读进内存，哪一步抛错都算打不开）。打不开，或者库文件不见了 / 成了空文件而备份还在
  /// （这时直接打开会得到一个空库，三天后好备份就被空的轮换光了）：问 ask，照它选的做——
  /// - 用备份：先把备份拷一份到库旁边（拷不成——磁盘满——就什么都还没动），出问题的库挪进 damaged-…/、当时的图片也拷一份
  ///   进去，拷好的那份备份改名成库文件（备份自己留在 backups/），再开一次；
  /// - 重新开始：库、图片目录、备份目录一起挪进 damaged-…/（旧的一整套都留着，新备份不会把旧备份轮换掉），再开一次；
  /// - 退出：什么都不动，抛 Failure.quit。
  /// 只问一次：再开还失败抛 Failure.stillBroken，不循环
  static func open<T>(
    in directory: URL, now: Date = .now, calendar: Calendar = .current, open: () throws -> T,
    ask: (Problem) -> Choice
  ) throws -> T {
    var problem: Problem
    if let lost = lostDatabase(in: directory, calendar: calendar) {
      problem = lost
    } else {
      do {
        return try open()
      } catch {
        problem = Problem(
          reason: "\(error)", backup: Backup.latestUsable(in: directory, calendar: calendar))
      }
    }
    problem.hasSettingsBackup = SettingsBackup.list(
      in: Backup.folder(in: directory), calendar: calendar
    ).contains { $0.kind == .daily }
    let choice = ask(problem)
    guard choice != .quit, choice != .restore || problem.backup != nil else { throw Failure.quit }
    do {
      let manager = FileManager.default
      let staged = directory.appending(path: Backup.databaseName + ".restoring")
      try? manager.removeItem(at: staged)
      if choice == .restore, let backup = problem.backup {
        try manager.copyItem(at: backup.url, to: staged)
      }
      try setAside(in: directory, everything: choice == .startFresh, now: now, calendar: calendar)
      if choice == .restore {
        try manager.moveItem(at: staged, to: directory.appending(path: Backup.databaseName))
      }
      return try open()
    } catch {
      throw Failure.stillBroken("\(error)")
    }
  }

  /// 库文件不见了、或者成了空文件，而读得出来的备份还在：当成出了问题（没有备份时是全新安装，照常新建）
  static func lostDatabase(in directory: URL, calendar: Calendar = .current) -> Problem? {
    let path = directory.appending(path: Backup.databaseName).path
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    guard size == nil || size == 0,
      let backup = Backup.latestUsable(in: directory, calendar: calendar)
    else { return nil }
    return Problem(
      reason: size == nil ? "数据库文件不见了" : "数据库文件是空的", backup: backup, lost: true)
  }

  /// 挪开的文件放在数据目录里的这个文件夹：damaged-20261002-213045（当地时间；重名加序号）
  static func asideFolder(in directory: URL, now: Date, calendar: Calendar = .current) -> URL {
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: now)
    let base = String(
      format: "damaged-%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0,
      parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    var url = directory.appending(path: base)
    var index = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = directory.appending(path: "\(base)-\(index)")
      index += 1
    }
    return url
  }

  /// 把出问题的库（连 -wal、-shm）挪进 damaged-…/，名字不变。图片：everything（重新开始）时图片目录和备份目录整个挪进去；
  /// 不是（用备份）时图片留在原地——恢复出来的收藏 / 片段还要用——另拷一份进去：恢复之后启动时的孤儿清理会把普通图片的文件
  /// 删掉，挪开的坏库里那些条目不能成空壳。拷不成不算失败（记日志）。
  /// 只挪不删；没有东西可留就不建文件夹。返回放到了哪（没有是 nil）。
  /// 先挪 -shm、-wal 再挪库：挪到一半出错时，留在原地的不能是「没有库、只剩 -wal」（sqlite 新建空库时会把旁边的 -wal 删掉）。
  /// ponytail: 拷图片靠 APFS 克隆（FileManager.copyItem 实测 300 个文件 600 MB 用 24 ms、多占 0.1 MB）；
  /// 数据目录在别的文件系统上就是真拷贝，慢、占一倍空间，真有人这么用再改成只挪普通图片
  @discardableResult static func setAside(
    in directory: URL, everything: Bool, now: Date = .now, calendar: Calendar = .current
  ) throws -> URL? {
    let manager = FileManager.default
    let images = directory.appending(path: "images")
    let names =
      ["-shm", "-wal", ""].map { Backup.databaseName + $0 }
      + (everything
        ? [images.lastPathComponent, Backup.folder(in: directory).lastPathComponent] : [])
    let present = names.filter { manager.fileExists(atPath: directory.appending(path: $0).path) }
    let copiesImages =
      !everything && (try? manager.contentsOfDirectory(atPath: images.path))?.isEmpty == false
    guard !present.isEmpty || copiesImages else { return nil }
    let folder = asideFolder(in: directory, now: now, calendar: calendar)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in present {
      try manager.moveItem(at: directory.appending(path: name), to: folder.appending(path: name))
    }
    if copiesImages {
      do {
        try manager.copyItem(at: images, to: folder.appending(path: images.lastPathComponent))
      } catch {
        Log.storage.error("用备份时没能把图片留一份：\(error)")
      }
    }
    return folder
  }

  /// 弹框里怎么称呼那份备份：「10 月 1 日（昨天）」「9 月 28 日（4 天前）」「今天」
  static func describe(_ day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.month, .day], from: day)
    let date = "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    let days =
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)
      ).day ?? 0
    switch days {
    case ...0: return date + "（今天）"
    case 1: return date + "（昨天）"
    default: return date + "（\(days) 天前）"
    }
  }

  /// 弹框的文字和按钮（纯函数，配单测）；按钮和 choices 一一对应，第一个是默认。
  /// 备份里只有留下的东西（Backup.dropped），所以说清楚哪些回得来、哪些从空的开始。
  /// 有设置与数据的自动备份时（problem.hasSettingsBackup）多一段：选了重新开始，片段、文字收藏和生词本怎么导回来
  /// （2026-10-08 用户同意加：那些 JSON 跟着 backups/ 挪开了，设置里「从备份恢复」是空的，不说没人知道还有一份）
  static func wording(
    for problem: Problem, directory: URL, now: Date = .now, calendar: Calendar = .current
  ) -> (title: String, text: String, buttons: [String], choices: [Choice]) {
    let place = (directory.path as NSString).abbreviatingWithTildeInPath
    let head = "Kitty Tools 的数据库读不出来了。"
    let fresh = "重新开始：全部从空的开始；现在的数据库文件、图片和备份一起挪开留着。"
    let kept = "挪开的文件不会删，在数据目录（\(place)）里一个「damaged-日期-时间」的文件夹里。设置和钥匙串里的密钥不受影响。"
    let reason = "原因：\(problem.reason)"
    let note =
      "选了重新开始，片段、文字收藏和生词本之后还能导回来：到 设置 › 通用 点「导入…」，选上面那个文件夹的 backups 里最新的「Kitty Tools 自动备份 日期.json」。"
    // 说明文件留在哪的那一段后面接这一段（没有那种备份就没有这一段）
    let tail = (problem.hasSettingsBackup ? [kept, note] : [kept]) + [reason]
    guard let backup = problem.backup else {
      // 有那种备份时把话说准：没有的是数据库的备份
      let none = problem.hasSettingsBackup ? "也没有可用的数据库备份。" : "也没有可用的备份。"
      return (
        "数据打不开了", ([head + none, fresh] + tail).joined(separator: "\n\n"),
        ["重新开始", "退出"], [.startFresh, .quit]
      )
    }
    let day = describe(backup.day, now: now, calendar: calendar)
    let restore =
      "用备份：片段、收藏、收藏夹、生词本和启动器的收藏回到 \(day)备份时的样子；普通剪贴板历史、翻译历史和启动器的使用记录不在备份里，"
      + "会从空的开始。"
      + (problem.lost ? "" : "出问题的数据库和当时的图片都留在「damaged-日期-时间」文件夹里（全部数据还在里面）。")
    return (
      "数据打不开了", ([head, restore + "\n" + fresh] + tail).joined(separator: "\n\n"),
      ["用 \(day)的备份", "重新开始", "退出"], [.restore, .startFresh, .quit]
    )
  }
}
