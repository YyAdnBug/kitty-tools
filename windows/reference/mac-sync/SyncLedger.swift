// 全局同步（PLAN §10「全局同步」）的两件共用的东西：一类数据怎么接进同步（SyncSource：片段和收藏、生词本……各自的仓库
// 实现它），和账本存在哪（sync_ledger 表）。
// **账本和数据在同一个库、同一个事务里**（SyncRecords 文件头「执行层必须守住的」）：片段、收藏、生词本都在 kitty.sqlite3，
// 账本表也建在那里，落合并结果和存账本是一个事务——从每日备份恢复这个库时账本跟着一起退回去（引擎会追上），「重新开始」
// 时一起清空（等于第一次合）。账本记着是哪个库（文件夹的库编号）的：换了文件夹就当第一次合。不升 user_version：旧版本
// 不认识这张表，碰不到它。存在偏好里的几类（网页搜索与快捷链接、翻译服务、设置）账本也放在偏好里（同一个偏好域，键
// `syncLedger.<类别>`，这台电脑自己的、不注册默认值、不跟着导出），写数据和写账本挨着做（偏好没有事务）。

import Foundation

/// 一类接进同步的数据（仓库实现它；全在主线程）
@MainActor protocol SyncSource: AnyObject {
  var syncKind: SyncRecords.Kind { get }
  /// 第一次合时本机原有的怎么办（片段这类：同样内容不重复；设置：整个跟着别的电脑）
  var syncJoin: SyncRecords.Join { get }
  /// 这一轮先别合（剪贴板面板里有还能撤销的删除、改动：还没落库，落下去之前合会把它们算成删了又加回来）
  var syncBusy: Bool { get }
  /// 本机该同步的那份：编号 → 内容（JSON，键排好序；编 → 落 → 再编得到一样的字节）
  func syncValues() -> [String: String]
  /// 每条真正改的时刻（毫秒；仓库记着的才给，没给的引擎用「现在」）
  func syncChanged() -> [String: Int64]
  /// 账本（library 是文件夹的库编号；没有、是别的库的 = nil，第一次合）。读不出来抛错（当成第一次合的话，本机上一轮之后改的
  /// 会被盖回去、删的被救回来）
  func syncLedger(library: String) throws -> SyncRecords.Ledger?
  /// 落合并出来的改动（编号 → 新内容，nil = 不再留着）并在**同一个事务**里存账本；没成返回 false（什么都没改，账本也没存）
  func applySync(_ changes: [String: String?], ledger: SyncRecords.Ledger, library: String) -> Bool
}

extension SyncSource {
  func syncChanged() -> [String: Int64] { [:] }
}

/// 账本表：一类一行，整本账存成一段 JSON（几百条也就几十 KB，有变化才写）
nonisolated enum SyncLedger {
  static func prepare(_ db: Database) throws {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS sync_ledger(
        kind TEXT PRIMARY KEY, library TEXT NOT NULL, ledger TEXT NOT NULL)
      """)
  }

  /// 读账本：没有这一行、是别的库的给 nil（第一次合）；读库出错、解不出来（写坏了、更新的版本写的）抛错——执行层这一类先不合
  static func load(_ kind: SyncRecords.Kind, library: String, in db: Database) throws
    -> SyncRecords.Ledger?
  {
    let rows = try db.query(
      "SELECT library, ledger FROM sync_ledger WHERE kind = ?", [kind.rawValue]
    ) { ($0.text(0), $0.text(1)) }
    guard let (owner, text) = rows.first, owner == library, let text else { return nil }
    return try JSONDecoder().decode(SyncRecords.Ledger.self, from: Data(text.utf8))
  }

  /// 存账本（调用方开着事务）
  static func save(
    _ ledger: SyncRecords.Ledger, kind: SyncRecords.Kind, library: String, in db: Database
  ) throws {
    let text = String(decoding: try SyncRecords.encoder.encode(ledger), as: UTF8.self)
    try db.execute(
      "INSERT OR REPLACE INTO sync_ledger(kind, library, ledger) VALUES (?, ?, ?)",
      [kind.rawValue, library, text])
  }

  // MARK: 存在偏好里的几类

  private struct Stored: Codable {
    var library: String
    var ledger: SyncRecords.Ledger
  }

  static func key(_ kind: SyncRecords.Kind) -> String { "syncLedger.\(kind.rawValue)" }

  /// 读偏好里的账本：没有、是别的库的给 nil；解不出来抛错
  static func load(_ kind: SyncRecords.Kind, library: String, in defaults: UserDefaults) throws
    -> SyncRecords.Ledger?
  {
    guard let data = defaults.data(forKey: key(kind)) else { return nil }
    let stored = try JSONDecoder().decode(Stored.self, from: data)
    return stored.library == library ? stored.ledger : nil
  }

  static func save(
    _ ledger: SyncRecords.Ledger, kind: SyncRecords.Kind, library: String, in defaults: UserDefaults
  ) throws {
    defaults.set(
      try SyncRecords.encoder.encode(Stored(library: library, ledger: ledger)), forKey: key(kind))
  }
}
