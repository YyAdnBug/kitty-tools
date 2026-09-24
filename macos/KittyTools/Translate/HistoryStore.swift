// 翻译历史（translations 表，与剪贴板共用一个库）：一次翻译记一条（列表里第一个启用服务的结果），
// 同原文 + 同目标语言只留最新一条（收藏状态保留）；超出条数上限时从最旧的非收藏开始删。

import Foundation
import OSLog
import Observation

@Observable final class HistoryStore {
  struct Entry: Identifiable, Hashable {
    let id: UUID
    var source: String
    var target: Lang
    var result: String
    var service: String
    var createdAt: Date
    var favorite: Bool
  }

  /// 每次改动 +1：视图读它来刷新查询结果
  private(set) var revision = 0
  @ObservationIgnored private let db: Database

  init(db: Database) throws {
    self.db = db
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS translations(
        id TEXT PRIMARY KEY, source TEXT NOT NULL, target TEXT NOT NULL, result TEXT NOT NULL,
        service TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
        favorite INTEGER NOT NULL DEFAULT 0, UNIQUE(source, target))
      """)
    try db.execute(
      "CREATE INDEX IF NOT EXISTS translations_created_at ON translations(created_at DESC)")
  }

  func add(source: String, target: Lang, result: String, service: String, limit: Int) {
    let source = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
    guard !source.isEmpty, !result.isEmpty else { return }
    write {
      try db.transaction {
        try db.execute(
          """
          INSERT INTO translations(id, source, target, result, service, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(source, target) DO UPDATE SET
            result = excluded.result, service = excluded.service, created_at = excluded.created_at
          """,
          [
            UUID().uuidString, source, target.rawValue, result, service,
            Date.now.timeIntervalSinceReferenceDate,
          ])
        if limit > 0 {
          try db.execute(
            """
            DELETE FROM translations WHERE favorite = 0 AND id NOT IN (
              SELECT id FROM translations WHERE favorite = 0 ORDER BY created_at DESC LIMIT ?)
            """, [limit])
        }
      }
    }
  }

  /// 旧版导入（LegacyImport 在它的事务里调用，抛错整体回滚）。entries 按新→旧传入：
  /// 同 id 或同「原文 + 目标语言」已有的算合并（内容以已有的为准，只把收藏取或），否则插入。返回 (新增, 合并)
  func importLegacy(_ entries: [Entry]) throws -> (added: Int, merged: Int) {
    var added = 0
    for entry in entries {
      try db.execute(
        """
        INSERT OR IGNORE INTO translations(id, source, target, result, service, created_at, favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          entry.id.uuidString, entry.source, entry.target.rawValue, entry.result, entry.service,
          entry.createdAt.timeIntervalSinceReferenceDate, entry.favorite,
        ])
      if db.changes > 0 {
        added += 1
      } else if entry.favorite {
        try db.execute(
          "UPDATE translations SET favorite = 1 WHERE id = ? OR (source = ? AND target = ?)",
          [entry.id.uuidString, entry.source, entry.target.rawValue])
      }
    }
    revision += 1
    return (added, entries.count - added)
  }

  /// 原文或译文包含关键词（不区分大小写），新→旧，最多 limit 条
  func search(_ query: String, limit: Int = 200) -> [Entry] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let pattern =
      "%"
      + trimmed.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing(
        "_", with: "\\_")
      + "%"
    let sql =
      "SELECT id, source, target, result, service, created_at, favorite FROM translations "
      + (trimmed.isEmpty ? "" : "WHERE source LIKE ?1 ESCAPE '\\' OR result LIKE ?1 ESCAPE '\\' ")
      + "ORDER BY created_at DESC LIMIT \(limit)"
    let rows = try? db.query(sql, trimmed.isEmpty ? [] : [pattern]) { row -> Entry? in
      guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let source = row.text(1),
        let target = row.text(2).flatMap(Lang.init(rawValue:)), let result = row.text(3),
        let created = row.double(5)
      else { return nil }
      return Entry(
        id: id, source: source, target: target, result: result, service: row.text(4) ?? "",
        createdAt: Date(timeIntervalSinceReferenceDate: created), favorite: row.int(6) == 1)
    }
    return (rows ?? []).compactMap { $0 }
  }

  var counts: (total: Int, favorites: Int) {
    let row = try? db.query("SELECT count(*), coalesce(sum(favorite), 0) FROM translations") {
      (Int($0.int(0) ?? 0), Int($0.int(1) ?? 0))
    }
    return row?.first ?? (0, 0)
  }

  func setFavorite(_ id: UUID, _ favorite: Bool) {
    write {
      try db.execute(
        "UPDATE translations SET favorite = ? WHERE id = ?", [favorite, id.uuidString])
    }
  }

  func delete(_ id: UUID) {
    write { try db.execute("DELETE FROM translations WHERE id = ?", [id.uuidString]) }
  }

  /// 清空非收藏的历史
  func clearNonFavorites() {
    write { try db.execute("DELETE FROM translations WHERE favorite = 0") }
  }

  private func write(_ body: () throws -> Void) {
    do {
      try body()
      revision += 1
    } catch {
      Log.storage.error("翻译历史写库失败：\(error)")
    }
  }
}
