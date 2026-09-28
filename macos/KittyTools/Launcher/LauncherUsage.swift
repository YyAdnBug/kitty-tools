// 启动器使用记录（launcher_usage 表，和剪贴板共用一个库）：每行 = (查询, 类型, 目标)。
// 查询为空的行是全局使用分（时间常数 14 天，给空查询的「常用」和排序加成）；非空的是「这个查询选过它」
// （时间常数 3 天）。每用一次：分 = 衰减到现在的分 + 1（修旧版次数永不衰减，§11 #31）。
// 内存里一份字典，改动直接写库（修旧版另起线程整份覆盖写 JSON、可能乱序，§11 #29）。
// 收藏（体检 D13，launcher_favorites 表）：用户自己挑的，空查询排在「常用」上面，按加入顺序、⌥⌘↑↓ 调，最多 8 个；
// 清空使用记录不动它。

import Foundation
import OSLog

final class LauncherUsage {
  struct Entry: Equatable {
    var query: String
    var kind: LauncherItem.Kind
    var target: String
    /// 「常用」里显示的标题（网址、文件不在任何目录里，靠它还原）
    var title: String
    var score: Double
    var usedAt: Date
  }

  static let globalTimeConstant: TimeInterval = 14 * 86_400
  static let queryTimeConstant: TimeInterval = 3 * 86_400
  /// 超过就删掉分最低的（全局 / 查询各自计）
  static let globalLimit = 1024
  static let queryLimit = 512

  /// 收藏的一项（按 kind + target 认，标题给网址 / 文件还原用）
  struct Favorite: Equatable {
    var kind: LauncherItem.Kind
    var target: String
    var title: String
  }

  /// 收藏最多几个：和空查询的行数一样，收藏满了就没有「常用」
  static let favoriteLimit = 8

  private(set) var entries: [String: Entry] = [:]
  /// 按顺序（加入先后，⌥⌘↑↓ 调过的按调过的）
  private(set) var favorites: [Favorite] = []
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
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS launcher_favorites(
        kind TEXT NOT NULL, target TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
        position INTEGER NOT NULL, PRIMARY KEY(kind, target))
      """)
    favorites = try db.query(
      "SELECT kind, target, title FROM launcher_favorites ORDER BY position"
    ) { row -> Favorite? in
      guard let kind = row.text(0).flatMap(LauncherItem.Kind.init), let target = row.text(1)
      else { return nil }
      return Favorite(kind: kind, target: target, title: row.text(2) ?? "")
    }.compactMap { $0 }
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

  /// 全局使用分最高的若干条（「常用」由调用方再按能否还原过滤）
  func top(_ limit: Int, now: Date = .now) -> [Entry] {
    entries.values.filter { $0.query.isEmpty }
      .sorted {
        Self.decayed($0.score, from: $0.usedAt, to: now, timeConstant: Self.globalTimeConstant)
          > Self.decayed($1.score, from: $1.usedAt, to: now, timeConstant: Self.globalTimeConstant)
      }
      .prefix(limit).map { $0 }
  }

  /// 忘掉一项的全部使用记录（全局和各个查询）：「常用」里 ⌘⌫。返回删掉的，⌘Z 用 restore 放回（体检 B38）
  @discardableResult func forget(_ item: LauncherItem) -> [Entry] {
    let forgotten = entries.filter { $0.value.kind == item.kind && $0.value.target == item.target }
    for key in forgotten.keys { entries[key] = nil }
    catchingErrors {
      try db.execute(
        "DELETE FROM launcher_usage WHERE kind = ? AND target = ?",
        [item.kind.rawValue, item.target])
    }
    return Array(forgotten.values)
  }

  /// 撤销 forget：原样写回（分和时间都是删之前的）
  func restore(_ forgotten: [Entry]) {
    for entry in forgotten {
      entries[Self.key(entry)] = entry
      write(entry)
    }
  }

  /// 设置 › 启动器「清空使用记录」：排序和「常用」从头学（收藏不动）
  func clearAll() {
    entries = [:]
    catchingErrors { try db.execute("DELETE FROM launcher_usage") }
  }

  // MARK: 收藏

  func isFavorite(_ item: LauncherItem) -> Bool {
    favorites.contains { $0.kind == item.kind && $0.target == item.target }
  }

  /// 加入（排到最后）/ 取消收藏；满了不加，返回 false
  @discardableResult func toggleFavorite(_ item: LauncherItem) -> Bool {
    if isFavorite(item) {
      favorites.removeAll { $0.kind == item.kind && $0.target == item.target }
    } else {
      guard favorites.count < Self.favoriteLimit else { return false }
      favorites.append(Favorite(kind: item.kind, target: item.target, title: item.title))
    }
    saveFavorites()
    return true
  }

  /// 删掉还原不出来的收藏（App 已卸载、文件已删）
  func removeFavorites(_ removed: [Favorite]) {
    favorites.removeAll(where: removed.contains)
    saveFavorites()
  }

  /// ⌥⌘↑↓：和上一个 / 下一个换位置；到头了返回 false
  @discardableResult func moveFavorite(_ item: LauncherItem, by offset: Int) -> Bool {
    guard
      let index = favorites.firstIndex(where: { $0.kind == item.kind && $0.target == item.target }),
      favorites.indices.contains(index + offset)
    else { return false }
    favorites.swapAt(index, index + offset)
    saveFavorites()
    return true
  }

  /// 最多 8 行，整张重写（一个事务）
  private func saveFavorites() {
    catchingErrors {
      try db.transaction {
        try db.execute("DELETE FROM launcher_favorites")
        for (position, favorite) in favorites.enumerated() {
          try db.execute(
            "INSERT INTO launcher_favorites(kind, target, title, position) VALUES (?, ?, ?, ?)",
            [favorite.kind.rawValue, favorite.target, favorite.title, position])
        }
      }
    }
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
    catchingErrors {
      try db.execute(
        """
        INSERT OR REPLACE INTO launcher_usage(query, kind, target, title, score, used_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          entry.query, entry.kind.rawValue, entry.target, entry.title, entry.score,
          entry.usedAt.timeIntervalSinceReferenceDate,
        ])
    }
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
