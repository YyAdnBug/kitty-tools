// 剪贴板历史：内存列表（按复制时间新→旧）+ clips 表持久化。所有改动都走这里：先改数组，再写库。
// 同内容再次复制 = 把原条目挪到最前（保留 id、收藏、备注、分组、OCR），不另起一条。

import AppKit
import OSLog
import Observation

@Observable final class ClipboardStore {
  /// 条数 / 天数 / 图片占用上限；0 或 nil 表示不限
  struct Limits {
    var maxCount = 0
    var maxAge: TimeInterval?
    var imageBytes = 0

    static var current: Limits {
      let defaults = UserDefaults.standard
      let days = defaults.integer(forKey: Prefs.clipboardRetentionDays)
      return Limits(
        maxCount: defaults.integer(forKey: Prefs.clipboardHistoryMax),
        maxAge: days > 0 ? TimeInterval(days) * 86_400 : nil,
        imageBytes: defaults.integer(forKey: Prefs.clipboardImageBudgetMB) * 1_048_576)
    }
  }

  private(set) var items: [ClipItem] = []
  /// 按创建时间升序
  private(set) var groups: [ClipGroup] = []
  /// 已从列表拿掉、等撤销窗口结束才真正删的条目
  private(set) var pendingDeletion: [ClipItem] = []
  @ObservationIgnored let images: ImageStore
  @ObservationIgnored private let db: Database
  @ObservationIgnored private var isRecognizing = false
  /// 本次运行里识别失败的图片不再重试，下次启动再试
  @ObservationIgnored private var ocrFailed: Set<UUID> = []
  /// 搜索用的折叠文本缓存。改动条目内容（正文、备注、图片文字、来源）的地方都要清掉对应的键
  @ObservationIgnored private var searchKeys: [UUID: Search.Key] = [:]

  private static let columns = """
    id, kind, text, file_paths, image_width, image_height, image_bytes, image_sha256, ocr_text,
    rich_type, source_name, source_bundle_id, copied_at, favorite, snippet, note, group_id
    """

  init(db: Database, images: ImageStore) throws {
    self.db = db
    self.images = images
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS clips(
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT, file_paths TEXT,
        image_width INTEGER, image_height INTEGER, image_bytes INTEGER, image_sha256 TEXT,
        ocr_text TEXT, rich_type TEXT, rich_data BLOB, source_name TEXT, source_bundle_id TEXT,
        copied_at REAL NOT NULL, -- Date.timeIntervalSinceReferenceDate，读写无精度损失
        favorite INTEGER NOT NULL DEFAULT 0,
        snippet INTEGER NOT NULL DEFAULT 0, note TEXT, group_id TEXT)
      """)
    try db.execute("CREATE INDEX IF NOT EXISTS clips_copied_at ON clips(copied_at DESC)")
    try db.execute(
      "CREATE TABLE IF NOT EXISTS clip_groups(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL)"
    )
    try reload()
  }

  /// 从库里读分组和条目（启动时；旧版导入提交或回滚后再读一次）
  func reload() throws {
    searchKeys = [:]
    groups = try db.query("SELECT id, name, created_at FROM clip_groups ORDER BY created_at") {
      row in
      guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let name = row.text(1),
        let created = row.double(2)
      else { return nil }
      return ClipGroup(id: id, name: name, createdAt: Date(timeIntervalSinceReferenceDate: created))
    }.compactMap { $0 }
    items = try db.query("SELECT \(Self.columns) FROM clips ORDER BY copied_at DESC, rowid DESC") {
      row in
      Self.decode(row)
    }.compactMap { $0 }
  }

  /// 新采集到的内容入库（rich 是带格式文本的原始数据）。之后执行各项上限
  func record(_ new: ClipItem, rich: Data? = nil) {
    if let index = items.firstIndex(where: { $0.hasSameContent(as: new) }) {
      var existing = items.remove(at: index)
      searchKeys[existing.id] = nil
      if existing.kind == .image, existing.id != new.id { images.delete(new.id) }
      existing.copiedAt = new.copiedAt
      existing.sourceName = new.sourceName
      existing.sourceBundleID = new.sourceBundleID
      // 带格式与否以最近一次复制为准
      existing.richType = new.richType
      items.insert(existing, at: 0)
      write {
        try db.execute(
          """
          UPDATE clips SET copied_at = ?, source_name = ?, source_bundle_id = ?, rich_type = ?,
            rich_data = ? WHERE id = ?
          """,
          [
            existing.copiedAt.timeIntervalSinceReferenceDate, existing.sourceName,
            existing.sourceBundleID,
            existing.richType?.rawValue, rich, existing.id.uuidString,
          ])
      }
    } else {
      items.insert(new, at: 0)
      write {
        let values = Self.encode(new) + [rich]
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        try db.execute(
          "INSERT INTO clips(\(Self.columns), rich_data) VALUES (\(placeholders))", values)
      }
    }
    enforceLimits()
    if new.kind == .image { recognizePendingImages() }
  }

  /// 粘贴过的条目挪到最前
  func bump(_ id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    var item = items.remove(at: index)
    item.copiedAt = .now
    items.insert(item, at: 0)
    write {
      try db.execute(
        "UPDATE clips SET copied_at = ? WHERE id = ?",
        [item.copiedAt.timeIntervalSinceReferenceDate, id.uuidString])
    }
  }

  func delete(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    purge(items.filter { ids.contains($0.id) })
    items.removeAll { ids.contains($0.id) }
  }

  /// 可撤销的删除：先从列表拿掉，commitDeletion 时才真正删库删图片。上一批没提交的先提交
  func deleteWithUndo(_ ids: Set<UUID>) {
    commitDeletion()
    pendingDeletion = items.filter { ids.contains($0.id) }
    items.removeAll { ids.contains($0.id) }
  }

  /// 撤销：按复制时间插回原位
  func undoDeletion() {
    for item in pendingDeletion {
      items.insert(item, at: items.firstIndex { $0.copiedAt < item.copiedAt } ?? items.endIndex)
    }
    pendingDeletion = []
  }

  func commitDeletion() {
    purge(pendingDeletion)
    pendingDeletion = []
  }

  /// 改条目的可编辑字段并落库（正文、收藏、备注、片段、分组）。正文改了就丢掉格式
  func update(_ ids: Set<UUID>, _ change: (inout ClipItem) -> Void) {
    for index in items.indices where ids.contains(items[index].id) {
      var item = items[index]
      change(&item)
      if item.text != items[index].text { item.richType = nil }
      items[index] = item
      searchKeys[item.id] = nil
      write {
        try db.execute(
          """
          UPDATE clips SET text = ?, favorite = ?, note = ?, snippet = ?, group_id = ?, rich_type = ?,
            rich_data = CASE WHEN ? IS NULL THEN NULL ELSE rich_data END WHERE id = ?
          """,
          [
            item.text, item.favorite, item.note, item.isSnippet, item.groupID?.uuidString,
            item.richType?.rawValue, item.richType?.rawValue, item.id.uuidString,
          ])
      }
    }
  }

  /// 全部已收藏 → 全部取消，否则全部收藏。取消收藏时普通历史连带清掉备注（片段的备注保留）
  func toggleFavorite(_ ids: Set<UUID>) {
    let favorite = !items.filter { ids.contains($0.id) }.allSatisfy(\.favorite)
    update(ids) { item in
      item.favorite = favorite
      if !favorite && !item.isSnippet { item.note = nil }
    }
  }

  /// 存成片段：已有同样正文的条目就把它标成片段并置顶，否则新建
  func saveSnippet(_ text: String) {
    if let existing = items.first(where: { $0.kind == .text && $0.text == text }) {
      update([existing.id]) { $0.isSnippet = true }
      bump(existing.id)
    } else {
      var item = ClipItem(kind: .text)
      item.text = text
      item.isSnippet = true
      record(item)
    }
  }

  /// 新建分组：名称去空白后截到 24 字，空名或与已有分组重名返回 nil
  @discardableResult
  func createGroup(named rawName: String) -> ClipGroup? {
    guard let name = validGroupName(rawName) else { return nil }
    let group = ClipGroup(id: UUID(), name: name, createdAt: .now)
    groups.append(group)
    write {
      try db.execute(
        "INSERT INTO clip_groups(id, name, created_at) VALUES (?, ?, ?)",
        [group.id.uuidString, name, group.createdAt.timeIntervalSinceReferenceDate])
    }
    return group
  }

  func renameGroup(_ id: UUID, to rawName: String) -> Bool {
    guard let index = groups.firstIndex(where: { $0.id == id }),
      let name = validGroupName(rawName, excluding: id)
    else { return false }
    groups[index].name = name
    write { try db.execute("UPDATE clip_groups SET name = ? WHERE id = ?", [name, id.uuidString]) }
    return true
  }

  /// 删除分组只解除条目的归属，不删条目
  func deleteGroup(_ id: UUID) {
    update(Set(items.filter { $0.groupID == id }.map(\.id))) { $0.groupID = nil }
    groups.removeAll { $0.id == id }
    write { try db.execute("DELETE FROM clip_groups WHERE id = ?", [id.uuidString]) }
  }

  private func validGroupName(_ rawName: String, excluding id: UUID? = nil) -> String? {
    let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
    guard !name.isEmpty, !groups.contains(where: { $0.name == name && $0.id != id }) else {
      return nil
    }
    return name
  }

  /// 旧版导入：只写库、不动内存，LegacyImport 在它的事务里调用（抛错整体回滚），之后调 reload()。
  /// 分组按 id、再按名称并入已有分组；条目按 id、再按内容并入已有条目（收藏 / 片段取或，备注、分组、
  /// 图片文字取已有的非空值，时间取较新），否则按原 id、原时间插入。返回 (新增, 合并)
  func importLegacy(_ imported: [(item: ClipItem, rich: Data?)], groups oldGroups: [ClipGroup])
    throws -> (added: Int, merged: Int)
  {
    var knownGroups = groups
    var groupIDs: [UUID: UUID] = [:]
    for group in oldGroups {
      if let same = knownGroups.first(where: { $0.id == group.id })
        ?? knownGroups.first(where: { $0.name == group.name })
      {
        groupIDs[group.id] = same.id
        continue
      }
      try db.execute(
        "INSERT INTO clip_groups(id, name, created_at) VALUES (?, ?, ?)",
        [group.id.uuidString, group.name, group.createdAt.timeIntervalSinceReferenceDate])
      knownGroups.append(group)
      groupIDs[group.id] = group.id
    }
    var current = items
    var added = 0
    for (var item, rich) in imported {
      item.groupID = item.groupID.flatMap { groupIDs[$0] }
      guard
        let index = current.firstIndex(where: { $0.id == item.id })
          ?? current.firstIndex(where: { $0.hasSameContent(as: item) })
      else {
        current.append(item)
        let values = Self.encode(item) + [rich]
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        try db.execute(
          "INSERT INTO clips(\(Self.columns), rich_data) VALUES (\(placeholders))", values)
        added += 1
        continue
      }
      var existing = current[index]
      existing.favorite = existing.favorite || item.favorite
      existing.isSnippet = existing.isSnippet || item.isSnippet
      if existing.note?.isEmpty ?? true { existing.note = item.note }
      existing.groupID = existing.groupID ?? item.groupID
      existing.ocrText = existing.ocrText ?? item.ocrText
      existing.copiedAt = max(existing.copiedAt, item.copiedAt)
      current[index] = existing
      try db.execute(
        """
        UPDATE clips SET favorite = ?, snippet = ?, note = ?, group_id = ?, ocr_text = ?,
          copied_at = ? WHERE id = ?
        """,
        [
          existing.favorite, existing.isSnippet, existing.note, existing.groupID?.uuidString,
          existing.ocrText, existing.copiedAt.timeIntervalSinceReferenceDate,
          existing.id.uuidString,
        ])
    }
    return (added, imported.count - added)
  }

  /// 删库删图片（条目本身已经不在 items 里，或调用方随后移除）
  private func purge(_ doomed: [ClipItem]) {
    guard !doomed.isEmpty else { return }
    for item in doomed where item.kind == .image { images.delete(item.id) }
    for item in doomed { searchKeys[item.id] = nil }
    write {
      try db.transaction {
        for item in doomed {
          try db.execute("DELETE FROM clips WHERE id = ?", [item.id.uuidString])
        }
      }
    }
  }

  /// 按关键词搜索（Search.rank + 折叠文本缓存）；空查询原样返回
  func search(_ query: String) -> [ClipItem] {
    Search.rank(items, query: query) { item in
      if let key = searchKeys[item.id] { return key }
      let key = Search.key(for: item)
      searchKeys[item.id] = key
      return key
    }
  }

  /// 把一条历史还原成剪贴板内容：文本（有格式就一起写）、图片（PNG）、文件（每个文件一个 item）
  func pasteboardItems(for item: ClipItem) -> [NSPasteboardItem] {
    switch item.kind {
    case .text:
      let pasteboardItem = NSPasteboardItem()
      pasteboardItem.setString(item.text ?? "", forType: .string)
      if let richType = item.richType, let rich = richData(for: item.id) {
        pasteboardItem.setData(rich, forType: richType == .rtf ? .rtf : .html)
      }
      return [pasteboardItem]
    case .image:
      guard let png = try? Data(contentsOf: images.url(for: item.id)) else { return [] }
      let pasteboardItem = NSPasteboardItem()
      pasteboardItem.setData(png, forType: .png)
      return [pasteboardItem]
    case .file:
      return (item.filePaths ?? []).map { path in
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(URL(filePath: path).absoluteString, forType: .fileURL)
        return pasteboardItem
      }
    }
  }

  /// 带格式文本的原始数据（只在粘贴时读）
  private func richData(for id: UUID) -> Data? {
    let rows = try? db.query("SELECT rich_data FROM clips WHERE id = ?", [id.uuidString]) {
      $0.blob(0)
    }
    return rows?.first ?? nil
  }

  /// 按条数 / 天数 / 图片总占用清理普通历史（收藏、片段、已归组的不动）
  func enforceLimits(_ limits: Limits = .current, now: Date = .now) {
    let ordinary = items.filter { !$0.isRetained }
    var doomed = Set<UUID>()
    if limits.maxCount > 0 { doomed.formUnion(ordinary.dropFirst(limits.maxCount).map(\.id)) }
    if let maxAge = limits.maxAge {
      doomed.formUnion(ordinary.filter { now.timeIntervalSince($0.copiedAt) > maxAge }.map(\.id))
    }
    if limits.imageBytes > 0 {
      var total = items.reduce(0) { sum, item in
        doomed.contains(item.id) ? sum : sum + (item.image?.byteCount ?? 0)
      }
      for item in ordinary.reversed() where total > limits.imageBytes {
        guard let image = item.image, !doomed.contains(item.id) else { continue }
        doomed.insert(item.id)
        total -= image.byteCount
      }
    }
    delete(doomed)
  }

  /// 退出 / 锁屏时清空普通历史
  func clearOrdinary() {
    delete(Set(items.filter { !$0.isRetained }.map(\.id)))
  }

  /// 串行识别还没有文字的图片；设置关掉时不做
  func recognizePendingImages() {
    guard !isRecognizing, UserDefaults.standard.bool(forKey: Prefs.clipboardImageOCR),
      let next = items.first(where: {
        $0.kind == .image && $0.ocrText == nil && !ocrFailed.contains($0.id)
      })
    else { return }
    isRecognizing = true
    Task {
      let text = await OCR.recognizeText(in: images.url(for: next.id))
      isRecognizing = false
      if let text, let index = items.firstIndex(where: { $0.id == next.id }) {
        items[index].ocrText = text
        searchKeys[next.id] = nil
        write {
          try db.execute(
            "UPDATE clips SET ocr_text = ? WHERE id = ?", [text, next.id.uuidString])
        }
      } else {
        ocrFailed.insert(next.id)
      }
      recognizePendingImages()
    }
  }

  /// 写库失败只记日志：内存里的列表仍是对的，下次启动以库为准
  private func write(_ body: () throws -> Void) {
    do { try body() } catch { Log.storage.error("剪贴板写库失败：\(error)") }
  }

  private static func encode(_ item: ClipItem) -> [Any?] {
    [
      item.id.uuidString, item.kind.rawValue, item.text,
      item.filePaths.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) },
      item.image?.width, item.image?.height, item.image?.byteCount, item.image?.sha256,
      item.ocrText, item.richType?.rawValue, item.sourceName, item.sourceBundleID,
      item.copiedAt.timeIntervalSinceReferenceDate, item.favorite, item.isSnippet, item.note,
      item.groupID?.uuidString,
    ]
  }

  private static func decode(_ row: Database.Row) -> ClipItem? {
    guard let id = row.text(0).flatMap(UUID.init(uuidString:)),
      let kind = row.text(1).flatMap(ClipItem.Kind.init(rawValue:)),
      let copiedAt = row.double(12)
    else { return nil }
    var item = ClipItem(
      id: id, kind: kind, copiedAt: Date(timeIntervalSinceReferenceDate: copiedAt))
    item.text = row.text(2)
    item.filePaths = row.text(3).flatMap {
      try? JSONDecoder().decode([String].self, from: Data($0.utf8))
    }
    if let width = row.int(4), let height = row.int(5), let bytes = row.int(6),
      let sha256 = row.text(7)
    {
      item.image = .init(
        width: Int(width), height: Int(height), byteCount: Int(bytes), sha256: sha256)
    }
    item.ocrText = row.text(8)
    item.richType = row.text(9).flatMap(ClipItem.RichType.init(rawValue:))
    item.sourceName = row.text(10)
    item.sourceBundleID = row.text(11)
    item.favorite = row.int(13) == 1
    item.isSnippet = row.int(14) == 1
    item.note = row.text(15)
    item.groupID = row.text(16).flatMap(UUID.init(uuidString:))
    return item
  }
}
