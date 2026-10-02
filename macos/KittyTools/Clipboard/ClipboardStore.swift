// 剪贴板历史：内存列表（按复制时间新→旧）+ clips 表持久化。所有改动都走这里：先改数组，再写库。
// 同内容再次复制 = 把原条目挪到最前（保留 id、收藏、备注、收藏夹、OCR），不另起一条；删掉还没提交的也拿回来。
// 收藏夹（体检 A1）：收藏 = 默认收藏夹，clip_groups 是命名收藏夹（按 position 排，可拖动），归进收藏夹就是收藏。
// ⌘Z 撤销栈（体检 A2）：删除、删收藏夹、取消收藏后超期的条目一批一批压栈，面板收起或退出 App 时才提交。

import AppKit
import OSLog
import Observation

@Observable final class ClipboardStore {
  /// 普通历史的保留天数 / 图片占用上限；nil 或 0 表示不限（条数上限已去掉，体检 A4）
  struct Limits {
    var maxAge: TimeInterval?
    var imageBytes = 0

    /// 设置里的「保留普通历史」天数，0 = 永久
    static var days: Int { UserDefaults.standard.integer(forKey: Prefs.clipboardRetentionDays) }

    static var current: Limits {
      Limits(
        maxAge: days > 0 ? TimeInterval(days) * 86_400 : nil,
        imageBytes: UserDefaults.standard.integer(forKey: Prefs.clipboardImageBudgetMB) * 1_048_576)
    }
  }

  /// ⌘Z 撤销栈的一批（体检 A2）
  enum Undo {
    /// 删掉的条目：已从列表拿掉，commitDeletion 时才删库删图片
    case deleted([ClipItem])
    /// 删掉的收藏夹（已删库）、它原来的位置和里面的条目（条目还是收藏，只解除了归属）
    case group(ClipGroup, index: Int, members: [UUID])
    /// 取消收藏 / 移出片段后已经超过保留天数的条目（改动前的样子）：提交前不被清理，撤销时改回来
    case unretained([ClipItem])
  }

  private(set) var items: [ClipItem] = []
  /// 命名收藏夹，按 position（拖动排的顺序）
  private(set) var groups: [ClipGroup] = []
  /// 撤销栈：面板收起前 ⌘Z 一批一批连着撤；面板收起、退出 App 时 commitDeletion 清空
  private(set) var undoStack: [Undo] = []
  var canUndo: Bool { !undoStack.isEmpty }
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
      """
      CREATE TABLE IF NOT EXISTS clip_groups(id TEXT PRIMARY KEY, name TEXT NOT NULL,
        created_at REAL NOT NULL, position INTEGER NOT NULL DEFAULT 0)
      """)
    try Self.migrate(db)
    try reload()
  }

  /// 旧库升级（幂等，每次启动都跑）：clip_groups 补 position 列（按创建时间排好）；
  /// 分组并进收藏（体检 A1）：已归组的条目都是收藏
  static func migrate(_ db: Database) throws {
    let columns = try db.query("PRAGMA table_info(clip_groups)") { $0.text(1) }
    if !columns.contains("position") {
      try db.transaction {
        try db.execute("ALTER TABLE clip_groups ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
        try db.execute(
          """
          UPDATE clip_groups SET position =
            (SELECT COUNT(*) FROM clip_groups AS g WHERE g.created_at < clip_groups.created_at)
          """)
      }
    }
    try db.execute("UPDATE clips SET favorite = 1 WHERE group_id IS NOT NULL AND favorite = 0")
  }

  /// 从库里读收藏夹和条目（启动时）
  func reload() throws {
    searchKeys = [:]
    groups = try db.query(
      "SELECT id, name, created_at FROM clip_groups ORDER BY position, created_at"
    ) {
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

  /// 新采集到的内容入库（rich 是带格式文本的原始数据）。之后执行各项上限。
  /// 同内容的条目（列表里的，或删了还没提交的）挪到最前，不另起一条
  func record(_ new: ClipItem, rich: Data? = nil) {
    let index = items.firstIndex { $0.hasSameContent(as: new) }
    if var existing = index.map({ items.remove(at: $0) }) ?? reclaim(sameContentAs: new) {
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

  /// 本 App 自己写进剪贴板的一段文字（取色、截图翻译、识字、复制图中文字：Paster.write 让 watcher 跳过了）记进历史：
  /// 照样过「屏蔽敏感文本」；已有同样正文的条目只挪到最前（保留它的格式、来源），没有才新记一条
  func recordOwnText(_ text: String) {
    guard
      !(UserDefaults.standard.bool(forKey: Prefs.clipboardBlockSensitive)
        && ClipboardFilter.looksSensitive(text))
    else { return }
    if let existing = items.first(where: { $0.kind == .text && $0.text == text }) {
      bump(existing.id)
    } else {
      var item = ClipItem(kind: .text)
      item.text = text
      record(item)
    }
  }

  /// 本 App 自己写进剪贴板的文件（录屏卡点「拷贝」，C8-a）记进历史：没有来源；同样的文件已有就只挪到最前（record 按路径去重）
  func recordFiles(_ urls: [URL]) {
    var item = ClipItem(kind: .file)
    item.filePaths = urls.map(\.path)
    record(item)
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

  /// 可撤销的删除：先从列表拿掉、压进撤销栈（不提交上一批），commitDeletion 时才真正删库删图片
  func deleteWithUndo(_ ids: Set<UUID>) {
    let batch = items.filter { ids.contains($0.id) }
    guard !batch.isEmpty else { return }
    undoStack.append(.deleted(batch))
    items.removeAll { ids.contains($0.id) }
  }

  /// ⌘Z：撤最近一批（删掉的按复制时间插回原位、删掉的收藏夹连归属一起回来、取消收藏的改回去），返回撤的是哪一批
  @discardableResult
  func undo() -> Undo? {
    guard let last = undoStack.popLast() else { return nil }
    switch last {
    case .deleted(let batch):
      for item in batch {
        items.insert(item, at: items.firstIndex { $0.copiedAt < item.copiedAt } ?? items.endIndex)
      }
    case .group(let group, let index, let members):
      groups.insert(group, at: min(index, groups.count))
      write {
        try db.execute(
          "INSERT INTO clip_groups(id, name, created_at) VALUES (?, ?, ?)",
          [group.id.uuidString, group.name, group.createdAt.timeIntervalSinceReferenceDate])
      }
      savePositions()
      assign(Set(members), to: group.id)
    case .unretained(let before):
      let groupIDs = Set(groups.map(\.id))
      for old in before {
        update([old.id]) { item in
          item.favorite = old.favorite
          item.isSnippet = old.isSnippet
          // 期间收藏夹被删掉（没撤销）就留在默认收藏
          item.groupID = old.groupID.flatMap { groupIDs.contains($0) ? $0 : nil }
        }
      }
    }
    return last
  }

  /// 面板收起、退出 App 时：删掉的真正删库删文件，撤销栈清空（取消收藏后超期的条目下次清理时删）
  func commitDeletion() {
    for case .deleted(let batch) in undoStack { purge(batch) }
    undoStack = []
  }

  /// 删了还没提交的同内容条目：从撤销栈里拿回来（再复制一次等于自动撤销，不新建一条）
  private func reclaim(sameContentAs new: ClipItem) -> ClipItem? {
    for (index, entry) in undoStack.enumerated() {
      guard case .deleted(var batch) = entry,
        let hit = batch.firstIndex(where: { $0.hasSameContent(as: new) })
      else { continue }
      let item = batch.remove(at: hit)
      if batch.isEmpty { undoStack.remove(at: index) } else { undoStack[index] = .deleted(batch) }
      return item
    }
    return nil
  }

  /// 改条目的可编辑字段并落库（正文、收藏、备注、片段、收藏夹）。正文改了就丢掉格式
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

  /// 全部已收藏 → 全部取消（同时移出收藏夹，备注不动），否则全部收藏。返回取消后超期的条数（见 changeRetention）
  @discardableResult
  func toggleFavorite(_ ids: Set<UUID>) -> Int {
    let favorite = !items.filter { ids.contains($0.id) }.allSatisfy(\.favorite)
    return changeRetention(ids) { item in
      item.favorite = favorite
      if !favorite { item.groupID = nil }
    }
  }

  /// 移出片段（体检 C1）：收藏、收藏夹、备注都不动。返回移出后超期的条数
  @discardableResult
  func removeFromSnippets(_ ids: Set<UUID>) -> Int {
    changeRetention(ids) { $0.isSnippet = false }
  }

  /// 改收藏 / 片段这类决定保留的字段。改完不再留下、又已超过保留天数的条目压进撤销栈：面板收起前不清理、⌘Z 能改回来。
  /// 返回这样的条数（界面据此提示「超过 N 天，收起面板后会被清理」）
  @discardableResult
  func changeRetention(
    _ ids: Set<UUID>, limits: Limits = .current, now: Date = .now,
    _ change: (inout ClipItem) -> Void
  ) -> Int {
    let before = items.filter { ids.contains($0.id) }
    update(ids, change)
    guard let maxAge = limits.maxAge else { return 0 }
    let expired = before.filter { old in
      old.isRetained && now.timeIntervalSince(old.copiedAt) > maxAge
        && items.first { $0.id == old.id }?.isRetained == false
    }
    if !expired.isEmpty { undoStack.append(.unretained(expired)) }
    return expired.count
  }

  /// 归进收藏夹就是收藏（不变式：有 groupID 的一定 favorite）；group 为 nil = 移出收藏夹，留在默认收藏
  func assign(_ ids: Set<UUID>, to group: UUID?) {
    update(ids) { item in
      item.groupID = group
      if group != nil { item.favorite = true }
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
      // 删了还没提交的同一段被 record 拿回来了：它原来不是片段
      if let first = items.first, !first.isSnippet { update([first.id]) { $0.isSnippet = true } }
    }
  }

  /// 新建收藏夹（排在最后）：名称去空白，空名、超过 24 字或与已有的重名返回 nil
  @discardableResult
  func createGroup(named rawName: String) -> ClipGroup? {
    guard let name = validGroupName(rawName) else { return nil }
    let group = ClipGroup(id: UUID(), name: name, createdAt: .now)
    groups.append(group)
    write {
      try db.execute(
        "INSERT INTO clip_groups(id, name, created_at, position) VALUES (?, ?, ?, ?)",
        [
          group.id.uuidString, name, group.createdAt.timeIntervalSinceReferenceDate,
          groups.count - 1,
        ])
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

  /// 删除收藏夹：里面的条目留在默认收藏（只解除归属），不确认；压进撤销栈，⌘Z 连归属一起回来
  func deleteGroup(_ id: UUID) {
    guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
    let members = items.filter { $0.groupID == id }.map(\.id)
    update(Set(members)) { $0.groupID = nil }
    undoStack.append(.group(groups.remove(at: index), index: index, members: members))
    write { try db.execute("DELETE FROM clip_groups WHERE id = ?", [id.uuidString]) }
    savePositions()  // 压实成 0…n-1：留着空洞的话，新建的排序号会和后面的撞上，重启后顺序变
  }

  /// 拖动排序：把收藏夹挪到 index（按挪之前的下标算，越界就放两头）
  func moveGroup(_ id: UUID, to index: Int) {
    guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
    let group = groups.remove(at: from)
    groups.insert(group, at: min(max(index, 0), groups.count))
    savePositions()
  }

  private func savePositions() {
    write {
      try db.transaction {
        for (position, group) in groups.enumerated() {
          try db.execute(
            "UPDATE clip_groups SET position = ? WHERE id = ?", [position, group.id.uuidString])
        }
      }
    }
  }

  /// 空名、超过 24 字（输入框已经拦住，不截断）或重名返回 nil
  private func validGroupName(_ rawName: String, excluding id: UUID? = nil) -> String? {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= ClipGroup.maxName,
      !groups.contains(where: { $0.name == name && $0.id != id })
    else { return nil }
    return name
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

  /// 按关键词过滤（Search.filter + 折叠文本缓存），顺序不变（新→旧）；空查询原样返回
  func search(_ query: String) -> [ClipItem] {
    Search.filter(items, query: query) { item in
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
      return Paster.items(files: (item.filePaths ?? []).map { URL(filePath: $0) })
    }
  }

  /// 带格式文本的原始数据（只在粘贴时读）
  private func richData(for id: UUID) -> Data? {
    let rows = try? db.query("SELECT rich_data FROM clips WHERE id = ?", [id.uuidString]) {
      $0.blob(0)
    }
    return rows?.first ?? nil
  }

  /// 按保留天数 / 普通图片总占用清理普通历史（收藏、片段不动；取消收藏后超期、还能 ⌘Z 的也先不动）。
  /// 图片只算普通图片（收藏 / 片段的不占额度，体检 B2），从最旧的删起，最新的一张普通图片（刚复制的）这一轮不删。
  /// 返回删了几条（设置页改小上限时用刘海说一声）
  @discardableResult
  func enforceLimits(_ limits: Limits = .current, now: Date = .now) -> Int {
    var undoable = Set<UUID>()
    for case .unretained(let before) in undoStack { undoable.formUnion(before.map(\.id)) }
    let ordinary = items.filter { !$0.isRetained && !undoable.contains($0.id) }
    var doomed = Set<UUID>()
    if let maxAge = limits.maxAge {
      doomed.formUnion(ordinary.filter { now.timeIntervalSince($0.copiedAt) > maxAge }.map(\.id))
    }
    if limits.imageBytes > 0 {
      let images = ordinary.filter { $0.image != nil && !doomed.contains($0.id) }
      var total = images.reduce(0) { $0 + ($1.image?.byteCount ?? 0) }
      for item in images.dropFirst().reversed() where total > limits.imageBytes {
        doomed.insert(item.id)
        total -= item.image?.byteCount ?? 0
      }
    }
    delete(doomed)
    return doomed.count
  }

  /// 图片占用：普通历史的（算进「图片最多占用」）和留下的（收藏 / 片段）分开算
  var imageUsage: (ordinary: Int, retained: Int) {
    items.reduce(into: (0, 0)) { sum, item in
      guard let bytes = item.image?.byteCount else { return }
      if item.isRetained { sum.1 += bytes } else { sum.0 += bytes }
    }
  }

  /// 退出 / 锁屏、设置里「立即清空」时清空普通历史；返回删了几条。
  /// 先提交撤销栈：删掉的普通条目不能在清空后再 ⌘Z 回来，取消收藏后等清理的也一并清掉
  @discardableResult
  func clearOrdinary() -> Int {
    commitDeletion()
    let doomed = Set(items.filter { !$0.isRetained }.map(\.id))
    delete(doomed)
    return doomed.count
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
      // 在子进程里识（识字模型不留在 App 里）；它不成会自己退回进程内识
      let text = await OCR.recognizeTextInHelper(in: images.url(for: next.id))
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
