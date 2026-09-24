// 启动器使用记录（launcher_usage 表，和剪贴板共用一个库）：每行 = (查询, 类型, 目标)。
// 查询为空的行是全局使用分（时间常数 14 天，给「最近使用」和排序加成）；非空的是「这个查询选过它」
// （时间常数 3 天）。每用一次：分 = 衰减到现在的分 + 1（修旧版次数永不衰减，§11 #31）。
// 内存里一份字典，改动直接写库（修旧版另起线程整份覆盖写 JSON、可能乱序，§11 #29）。

import Foundation
import OSLog

final class LauncherUsage {
  struct Entry: Equatable {
    var query: String
    var kind: LauncherItem.Kind
    var target: String
    /// 「最近使用」里显示的标题（网址、文件不在任何目录里，靠它还原）
    var title: String
    var score: Double
    var usedAt: Date
  }

  static let globalTimeConstant: TimeInterval = 14 * 86_400
  static let queryTimeConstant: TimeInterval = 3 * 86_400
  /// 超过就删掉分最低的（全局 / 查询各自计）
  static let globalLimit = 1024
  static let queryLimit = 512

  private(set) var entries: [String: Entry] = [:]
  private let db: Database

  init(db: Database) throws {
    self.db = db
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS launcher_usage(
        query TEXT NOT NULL, kind TEXT NOT NULL, target TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
        score REAL NOT NULL, used_at REAL NOT NULL, PRIMARY KEY(query, kind, target))
      """)
    let rows = try db.query("SELECT query, kind, target, title, score, used_at FROM launcher_usage")
    {
      row -> Entry? in
      guard let query = row.text(0), let kind = row.text(1).flatMap(LauncherItem.Kind.init),
        let target = row.text(2), let score = row.double(4), let usedAt = row.double(5)
      else { return nil }
      return Entry(
        query: query, kind: kind, target: target, title: row.text(3) ?? "", score: score,
        usedAt: Date(timeIntervalSinceReferenceDate: usedAt))
    }
    for entry in rows.compactMap({ $0 }) { entries[Self.key(entry)] = entry }
  }

  static func normalize(_ query: String) -> String {
    LauncherMatch.fold(query).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  static func decayed(_ score: Double, from usedAt: Date, to now: Date, timeConstant: TimeInterval)
    -> Double
  {
    score * exp(-max(0, now.timeIntervalSince(usedAt)) / timeConstant)
  }

  /// 执行成功后记一次：全局一行，有查询再记一行
  func record(_ item: LauncherItem, query: String, now: Date = .now) {
    let normalized = Self.normalize(query)
    for (query, timeConstant) in [
      ("", Self.globalTimeConstant), (normalized, Self.queryTimeConstant),
    ]
    where query == "" || !normalized.isEmpty {
      let key = Self.key(query, item.kind, item.target)
      let previous = entries[key].map {
        Self.decayed($0.score, from: $0.usedAt, to: now, timeConstant: timeConstant)
      }
      let entry = Entry(
        query: query, kind: item.kind, target: item.target, title: item.title,
        score: (previous ?? 0) + 1, usedAt: now)
      entries[key] = entry
      write(entry)
    }
    prune(now: now)
  }

  /// (全局使用分, 这个查询的使用分)，都已衰减到现在
  func boost(for item: LauncherItem, query: String, now: Date = .now) -> (
    global: Double, query: Double
  ) {
    let global = entries[Self.key("", item.kind, item.target)].map {
      Self.decayed($0.score, from: $0.usedAt, to: now, timeConstant: Self.globalTimeConstant)
    }
    let normalized = Self.normalize(query)
    let affinity =
      normalized.isEmpty
      ? nil
      : entries[Self.key(normalized, item.kind, item.target)].map {
        Self.decayed($0.score, from: $0.usedAt, to: now, timeConstant: Self.queryTimeConstant)
      }
    return (global ?? 0, affinity ?? 0)
  }

  /// 全局使用分最高的若干条（新→旧的「最近使用」由调用方再按能否还原过滤）
  func top(_ limit: Int, now: Date = .now) -> [Entry] {
    entries.values.filter { $0.query.isEmpty }
      .sorted {
        Self.decayed($0.score, from: $0.usedAt, to: now, timeConstant: Self.globalTimeConstant)
          > Self.decayed($1.score, from: $1.usedAt, to: now, timeConstant: Self.globalTimeConstant)
      }
      .prefix(limit).map { $0 }
  }

  /// 旧版导入：已有的行不动（重复导入不叠加），一个事务写完再改内存；返回新增条数
  func importLegacy(_ imported: [Entry]) throws -> Int {
    var fresh: [String: Entry] = [:]
    for entry in imported where entries[Self.key(entry)] == nil {
      // 旧版两条记录落到同一行（mac_open 与 open_path 的同一个 App、折叠后相同的查询）：分数合并
      fresh[Self.key(entry)] = fresh[Self.key(entry)].map { Self.merge($0, entry) } ?? entry
    }
    try db.transaction { for entry in fresh.values { try insert(entry) } }
    entries.merge(fresh) { old, _ in old }
    return fresh.count
  }

  /// 两次记录合成一行：各自衰减到较晚的那次再相加
  static func merge(_ a: Entry, _ b: Entry) -> Entry {
    let (older, newer) = a.usedAt <= b.usedAt ? (a, b) : (b, a)
    let timeConstant = a.query.isEmpty ? globalTimeConstant : queryTimeConstant
    var merged = newer
    merged.score =
      newer.score
      + decayed(older.score, from: older.usedAt, to: newer.usedAt, timeConstant: timeConstant)
    return merged
  }

  private func prune(now: Date) {
    for (isGlobal, limit, timeConstant) in [
      (true, Self.globalLimit, Self.globalTimeConstant),
      (false, Self.queryLimit, Self.queryTimeConstant),
    ] {
      let group = entries.values.filter { $0.query.isEmpty == isGlobal }
      guard group.count > limit + 32 else { continue }  // 攒一些再删，不每次都排序
      let doomed = group.sorted {
        Self.decayed($0.score, from: $0.usedAt, to: now, timeConstant: timeConstant)
          < Self.decayed($1.score, from: $1.usedAt, to: now, timeConstant: timeConstant)
      }
      .prefix(group.count - limit)
      for entry in doomed {
        entries[Self.key(entry)] = nil
        catchingErrors {
          try db.execute(
            "DELETE FROM launcher_usage WHERE query = ? AND kind = ? AND target = ?",
            [entry.query, entry.kind.rawValue, entry.target])
        }
      }
    }
  }

  private func write(_ entry: Entry) {
    catchingErrors { try insert(entry, replacing: true) }
  }

  private func insert(_ entry: Entry, replacing: Bool = false) throws {
    try db.execute(
      """
      INSERT OR \(replacing ? "REPLACE" : "IGNORE") INTO launcher_usage(query, kind, target, title, score, used_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        entry.query, entry.kind.rawValue, entry.target, entry.title, entry.score,
        entry.usedAt.timeIntervalSinceReferenceDate,
      ])
  }

  /// 写库失败只记日志：内存里的记录仍可用，下次启动以库为准
  private func catchingErrors(_ body: () throws -> Void) {
    do { try body() } catch { Log.storage.error("启动器使用记录写库失败：\(error)") }
  }

  private static func key(_ entry: Entry) -> String { key(entry.query, entry.kind, entry.target) }
  private static func key(_ query: String, _ kind: LauncherItem.Kind, _ target: String) -> String {
    query + "\n" + kind.rawValue + "\n" + target
  }
}
