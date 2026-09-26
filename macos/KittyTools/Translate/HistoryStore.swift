// 翻译历史（translations 表，与剪贴板共用一个库）：一次翻译记一条（列表里第一个启用服务的结果），
// 同原文 + 同目标语言只留最新一条（收藏状态保留）；超出条数上限时从最旧的非收藏开始删。
// 收藏就是生词本（Bob 也是收藏夹代替）：可只看收藏，导出 CSV / Anki 能导入的 TSV（设置 › 翻译）。

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

  /// 存进库里的原文：去首尾空白、最多 1 万字（add、收藏按同一个规则找同一条）
  private static func stored(_ source: String) -> String {
    String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
  }

  func add(source: String, target: Lang, result: String, service: String, limit: Int) {
    let source = Self.stored(source)
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

  /// 原文或译文包含关键词（不区分大小写），新→旧，最多 limit 条（0 = 不限，导出用）；favoritesOnly 只看收藏
  func search(_ query: String, favoritesOnly: Bool = false, limit: Int = 200) -> [Entry] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let pattern =
      "%"
      + trimmed.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing(
        "_", with: "\\_")
      + "%"
    var conditions: [String] = []
    if !trimmed.isEmpty {
      conditions.append("(source LIKE ?1 ESCAPE '\\' OR result LIKE ?1 ESCAPE '\\')")
    }
    if favoritesOnly { conditions.append("favorite = 1") }
    var sql = "SELECT id, source, target, result, service, created_at, favorite FROM translations "
    if !conditions.isEmpty { sql += "WHERE " + conditions.joined(separator: " AND ") + " " }
    sql += "ORDER BY created_at DESC"
    if limit > 0 { sql += " LIMIT \(limit)" }
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

  /// 这次翻译（原文 + 实际目标语言）收藏了没有：浮窗的星标、⌘S
  func isFavorite(source: String, target: Lang) -> Bool {
    let rows = try? db.query(
      "SELECT favorite FROM translations WHERE source = ? AND target = ?",
      [Self.stored(source), target.rawValue]
    ) { $0.int(0) == 1 }
    return rows?.first ?? false
  }

  /// 浮窗里收藏 / 取消：没有这条（关了历史、还没写进去）就连译文一起记一条
  func setFavorite(
    source: String, target: Lang, result: String, service: String, _ favorite: Bool
  ) {
    let source = Self.stored(source)
    guard !source.isEmpty, !result.isEmpty else { return }
    write {
      try db.execute(
        """
        INSERT INTO translations(id, source, target, result, service, created_at, favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source, target) DO UPDATE SET favorite = excluded.favorite
        """,
        [
          UUID().uuidString, source, target.rawValue, result, service,
          Date.now.timeIntervalSinceReferenceDate, favorite,
        ])
    }
  }

  /// 按「原文 + 目标语言」删一条（关着历史时取消收藏）
  func remove(source: String, target: Lang) {
    write {
      try db.execute(
        "DELETE FROM translations WHERE source = ? AND target = ?",
        [Self.stored(source), target.rawValue])
    }
  }

  func delete(_ id: UUID) {
    write { try db.execute("DELETE FROM translations WHERE id = ?", [id.uuidString]) }
  }

  /// 清空非收藏的历史
  func clearNonFavorites() {
    write { try db.execute("DELETE FROM translations WHERE favorite = 0") }
  }

  // MARK: 导出（纯函数，配单测）

  /// CSV（Excel / Numbers 打开）：RFC 4180，带表头；时间写本地时间。字段含逗号、引号、换行时加引号、
  /// 引号双写；以 = + - @ 开头的前面加 '，免得 Excel 当成公式（「-ing」会变成 #NAME?、「+1」变成 1）
  static func csv(_ entries: [Entry], timeZone: TimeZone = .current) -> String {
    let time = Date.VerbatimFormatStyle(
      format:
        "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
      timeZone: timeZone, calendar: Calendar(identifier: .gregorian))
    let header = ["原文", "译文", "目标语言", "服务", "时间", "收藏"]
    let rows: [[String]] = entries.map { entry in
      [
        entry.source, entry.result, entry.target.title, entry.service,
        entry.createdAt.formatted(time), entry.favorite ? "是" : "",
      ]
    }
    let lines: [String] = ([header] + rows).map { row in
      row.map(csvField).joined(separator: ",")
    }
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  private static func csvField(_ field: String) -> String {
    var field = field
    if let first = field.unicodeScalars.first, "=+-@".unicodeScalars.contains(first) {
      field = "'" + field
    }
    // 按 Unicode 标量查：Swift 把 \r\n 当成一个字符，按字符查不出来
    guard field.unicodeScalars.contains(where: { ",\"\n\r".unicodeScalars.contains($0) }) else {
      return field
    }
    return "\"" + field.replacing("\"", with: "\"\"") + "\""
  }

  /// TSV（Anki 导入：正面原文、背面译文）。带 #separator / #html 头，按 Anki 的解析规则转义：
  /// 字段按 HTML 写（& < > 转实体、各种换行写成 <br>、Tab 换空格）；以 " 或 # 开头、含 " 的字段加引号、引号双写
  /// （Anki 把 # 开头的行当注释丢掉，不成对的引号会把后面几条吞成一张卡）
  static func tsv(_ entries: [Entry]) -> String {
    let rows = entries.map { entry in
      [entry.source, entry.result].map(ankiField).joined(separator: "\t")
    }
    return (["#separator:tab", "#html:true"] + rows).joined(separator: "\n") + "\n"
  }

  private static func ankiField(_ text: String) -> String {
    var html = text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(
      ">", with: "&gt;")
    html = html.replacing("\t", with: " ")
    html = html.replacing(/\r\n|\r|\n|\u{2028}|\u{2029}/, with: "<br>")
    guard html.hasPrefix("\"") || html.hasPrefix("#") || html.contains("\"") else { return html }
    return "\"" + html.replacing("\"", with: "\"\"") + "\""
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
