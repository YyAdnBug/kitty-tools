// 便签仓库：数据目录里单独的库 notes.sqlite3（WAL，PRAGMA user_version 记表结构的版本），全部便签——连归档的和「最近删除」
// 里的——读进内存，改动都走这里：先改内存，再落盘。和剪贴板的库（kitty.sqlite3）、图片、备份互不相干：剪贴板的清理、
// 保留天数、锁屏清空、「重新开始」都碰不到便签（PLAN §10「便签」D①）。
// - 落盘：正文和标题是一个字一个字改的，先改内存、记成「没落盘」，停手 250 ms 落一次、连着改满 2 s 必落一次（saveDelay）；
//   别的改动（新建、换色、归档、固定、挪顺序、删除、放回、导入…）当场落，攒着的一起带下去。flush() = 现在就落：便签收起、
//   退出、锁屏、睡眠前由调用方调。写不成的不丢：留在「没落盘」的集合里，原因记在 saveProblem（界面读它），过一会儿自己
//   再试（retryDelay：5 秒起、每次翻倍、封顶 60 秒），下一次改动、下一次 flush 也会带上；退出前还落不下去要问用户
//   （flushBeforeQuit）。
// - 写进来的文字都先收拾一遍（Note.sanitized：去掉 NUL，标题截到上限）；修订号每次改动 +1（到顶为止），「改于」只在
//   标题 / 正文 / 颜色变时更新。要用到「现在」的改动都带一个 now 参数（默认 .now，单测传固定的；同剪贴板、翻译历史的仓库）。
// - 删除是软删（deletedAt），进「最近删除」留 trashDays 天，到期由 purgeExpired 真删。
// - 导出文件的第七类「便签」（SettingsArchive）：exportable 是没删的全部，adopt 按编号合并——本机被换掉的那一版不丢，
//   另存一条进「最近删除」。
// 搜索在内存里做（标题 + 正文，口径同剪贴板搜索）。和 sqlite 的 C 接口打交道的只有 Database。
// 列表行、标签、预览卡上显示的推导结果（标题、摘要、任务进度）按便签缓存在这里（summary(of:)）：标题、正文没变就不重算。
// 便签墙上的卡片（字和量好的高，wallCard(of:markdown:)）同样缓存在这里：关掉全部便签窗口再开、换视图再换回来都不重建。

import Foundation
import OSLog
import Observation

@Observable final class NoteStore {
  nonisolated enum Failure: Error, Equatable, CustomStringConvertible {
    /// 库是更新版本的 Kitty Tools 写的（带读到的版本号）：不认识的表结构不能当成旧版去读写
    case newer(Int)

    var description: String {
      switch self {
      case .newer(let version):
        "便签的数据是更新版本的 Kitty Tools 写的（数据版本 \(version)，这个版本只认到 \(NoteStore.schemaVersion)）"
      }
    }
  }

  /// 导入（adopt）做了什么
  struct Adoption: Equatable {
    /// 加进来的、换成文件里那一版的
    var added = 0
    var updated = 0
    /// 落没落下去：没落下去的还在内存里、留着重试（saveProblem），但这时不能说「导入好了」
    var saved = true
  }

  /// 等一段时间：落盘的两种等待（停手、失败后重试）都用它。默认是 Task.sleep；单测换成自己掌握的，不等真实时间
  typealias Wait = (TimeInterval) async throws -> Void

  /// 表结构的版本（PRAGMA user_version）：新库建好表就设成它。以后改表结构时 +1，在 prepare 里按读到的旧版本升级
  nonisolated static let schemaVersion = 1
  /// 「最近删除」里留几天
  nonisolated static let trashDays = 30
  /// 改正文 / 标题后停手多久落盘、连着改最多拖多久
  nonisolated static let quietDelay: TimeInterval = 0.25
  nonisolated static let maxDelay: TimeInterval = 2

  /// 全部便签，连归档的和「最近删除」里的（顺序不作数，要顺序用下面几个视图）
  private(set) var notes: [Note] = [] {
    didSet { generation &+= 1 }
  }
  /// notes 变一次加一（不看着它变，界面看 notes）：用它算出来的东西拿它判断还能不能接着用（NotesWindowModel.notes）
  @ObservationIgnored private(set) var generation = 0
  /// 上次落盘没成的原因；都落下去了是 nil
  private(set) var saveProblem: String?
  /// 图片目录（第 7 批行内图片，notes-images/）：AppDelegate 开完便签后设；nil = 图都画占位框、粘进来的存不了。
  /// 编辑器（NoteTextView.imageStore）和便签墙卡片（wallCard 的缩略图）都从这里拿——不另设一个进程里的单例
  /// （单测各给各的临时目录，互不打扰）
  @ObservationIgnored var images: NoteImageStore?
  @ObservationIgnored private let db: Database
  @ObservationIgnored private let wait: Wait
  /// 推导结果的缓存（summary(of:)）：编号 → 算的时候的标题、正文和结果
  @ObservationIgnored private var summaries:
    [String: (title: String, body: String, summary: Summary)] =
      [:]
  /// 便签墙卡片的缓存（wallCard(of:markdown:)）：编号 → 建的时候看的那几样和卡片
  @ObservationIgnored private var wallCards: [String: (key: WallCardKey, card: NoteWallCard)] = [:]
  /// 改了还没落盘的便签的编号：打字攒着的、上次没写成的；内存里已经没有的那些 = 要从库里删掉的
  @ObservationIgnored private var unsaved: Set<String> = []
  /// 这一串没落盘的打字改动里最早那次是什么时候（算「连着改满 maxDelay」用）
  @ObservationIgnored private var unsavedSince: Date?
  /// 停手后的那次落盘、失败后的那次重试（都只弱引用仓库：仓库放手时连接跟着关，不被它们拖住）
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  /// 连着失败了几次（定下一次重试隔多久）
  @ObservationIgnored private var failures = 0

  private static let columns = """
    id, title, body, color, created_at, modified_at, revision, archived, pinned, sort_order,
    deleted_at
    """
  /// 有就更新、没有就插入（不用 INSERT OR REPLACE：那是删了再插，rowid 会变）
  private static let upsert = """
    INSERT INTO notes(\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET title = excluded.title, body = excluded.body,
      color = excluded.color, created_at = excluded.created_at,
      modified_at = excluded.modified_at, revision = excluded.revision,
      archived = excluded.archived, pinned = excluded.pinned, sort_order = excluded.sort_order,
      deleted_at = excluded.deleted_at
    """

  /// 建表、认版本、读表哪一步抛错都算打不开（NotesRecovery.open 接手）
  init(
    db: Database, wait: @escaping Wait = { try await Task.sleep(for: .seconds($0)) }
  ) throws {
    self.db = db
    self.wait = wait
    try Self.prepare(db)
    notes = try db.query("SELECT \(Self.columns) FROM notes ORDER BY rowid") { Self.decode($0) }
      .compactMap { $0 }
  }

  /// 认版本、建表。读到的版本比认识的大就抛 Failure.newer，什么都不写；时间存整数毫秒（1970 年起）
  static func prepare(_ db: Database) throws {
    let found = try db.query("PRAGMA user_version") { $0.int(0) }.first.flatMap { $0 } ?? 0
    guard found <= schemaVersion else { throw Failure.newer(Int(found)) }
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS notes(
        id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
        color INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
        sort_order REAL NOT NULL DEFAULT 0, deleted_at INTEGER)
      """)
    if found < schemaVersion { try db.execute("PRAGMA user_version = \(schemaVersion)") }
  }

  // MARK: 视图

  /// 没归档、没删的，按顺序
  var active: [Note] {
    notes.filter(\.isActive).sorted(by: Self.precedes)
  }

  /// 归档的，最近改过的在前
  var archived: [Note] {
    notes.filter { $0.isArchived && $0.deletedAt == nil }
      .sorted { ($0.modifiedAt, $0.id) > ($1.modifiedAt, $1.id) }
  }

  /// 「最近删除」里的，刚删的在前
  var trashed: [Note] {
    notes.filter { $0.deletedAt != nil }
      .sorted { ($0.deletedAt ?? .distantPast, $0.id) > ($1.deletedAt ?? .distantPast, $1.id) }
  }

  /// 导出文件里带的：没删的全部（含归档），按顺序
  var exportable: [Note] { notes.filter { $0.deletedAt == nil }.sorted(by: Self.precedes) }

  /// 正文里引用到的图片编号（含归档的、「最近删除」里的：它们都算「还被引用着」）。清理孤儿时用
  /// （NoteImageStore.purge）：一个文件没被任何便签引用满 30 天才删
  var referencedImages: Set<UUID> {
    var ids: Set<UUID> = []
    for note in notes where NoteImages.containsToken(note.body) {
      ids.formUnion(NoteImages.ids(in: note.body))
    }
    return ids
  }

  func note(_ id: String) -> Note? { notes.first { $0.id == id } }

  /// 一条便签显示用的推导结果（Note.displayTitle / preview / taskProgress：都要逐行扫正文、过 Markdown 的扫描器）
  struct Summary {
    let title: String
    let preview: String
    let progress: (done: Int, total: Int)?
  }

  /// 这条便签的推导结果，按便签缓存：列表的每一行、那叠的每张标签每次重画都要它们（300 条、正文 1–5 KB 现算一遍
  /// 约 40 ms，Debug；手测反馈第 3 批量的），标题和正文没变就不重算。比的是标题、正文本身（不是修订号：导入能带来
  /// 同一个修订号、不一样的字）——没变时两边是同一块存储，比较当场返回
  func summary(of note: Note) -> Summary {
    if let cached = summaries[note.id], cached.title == note.title, cached.body == note.body {
      return cached.summary
    }
    let summary = Summary(
      title: note.displayTitle, preview: note.preview, progress: note.taskProgress)
    summaries[note.id] = (note.title, note.body, summary)
    return summary
  }

  /// 建一张卡片时看的几样（都没变就还是那张）：标题、正文、颜色、固定（标题给图钉让出一截）、Markdown 开关
  private struct WallCardKey: Equatable {
    let title: String
    let body: String
    let color: Int
    let isPinned: Bool
    let markdown: Bool

    init(_ note: Note, markdown: Bool) {
      (title, body, color, isPinned) = (note.title, note.body, note.color, note.isPinned)
      self.markdown = markdown
    }
  }

  /// 这条便签在便签墙上的卡片（NoteWallCard：卡片上的字和量好的高；建一张要排一遍字，Debug 约 1.5 ms——300 条全建
  /// 约 0.45 s，手测反馈第 6 批评审量的）。按便签缓存（同 summary：比的是字本身，没变时两边是同一块存储、当场返回）：
  /// 标题、正文、颜色、固定、Markdown 开关都没变就是上次建的。卡片顶上那张缩略图的高按**元数据**算（文件头，
  /// 主线程上读、按编号缓存）：墙的排法只看量出来的高，不等解码完
  func wallCard(of note: Note, markdown: Bool) -> NoteWallCard {
    if let card = cachedWallCard(of: note, markdown: markdown) { return card }
    let card = NoteWallCard.make(
      for: note, title: summary(of: note).title, markdown: markdown,
      sizes: { images?.pointSize(of: $0.id, ext: $0.ext) },
      url: { images?.url(for: $0.id, ext: $0.ext) })
    wallCards[note.id] = (WallCardKey(note, markdown: markdown), card)
    return card
  }

  /// 同上，建好了而且没过时才给，不建（便签墙排的时候：可见区以下的先按估计的高排）
  func cachedWallCard(of note: Note, markdown: Bool) -> NoteWallCard? {
    guard let cached = wallCards[note.id], cached.key == WallCardKey(note, markdown: markdown)
    else { return nil }
    return cached.card
  }

  /// 谁排在前面：order 小的；一样时（导入带来的）新建的在前，再一样按编号——顺序总是确定的。
  /// ponytail: 几个视图每次访问都现筛现排（几百条是微秒级）；便签上千条、列表卡了再把排好的存下来
  private static func precedes(_ a: Note, _ b: Note) -> Bool {
    if a.order != b.order { return a.order < b.order }
    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
    return a.id < b.id
  }

  // MARK: 改动

  /// 新建一条，排在最前；颜色接着上一条新建的往下轮
  @discardableResult
  func create(body: String = "", title: String = "", now: Date = .now) -> Note {
    let now = Note.stamp(now)
    // 同一刻建的几条里取后加进来的那条
    let latest = notes.enumerated().max {
      ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset)
    }?.element
    let note = Note(
      id: UUID().uuidString, title: Note.sanitized(title: title),
      body: Note.sanitized(text: body),
      color: latest.map { ($0.color + 1) % Note.colorCount } ?? 0, createdAt: now,
      modifiedAt: now, order: top)
    notes.append(note)
    unsaved.insert(note.id)
    flush()
    return note
  }

  /// 「新建便签」用的那一条：没归档没删的里最前面那条还是空白的（标题、正文都没有）就用它，不然新建一条——
  /// 连点几次「新建」不会攒出一串空便签。全部便签窗口、屏幕边缘那叠（标签列下的「+」、全局动作）共用
  func blankOrNew(now: Date = .now) -> Note {
    if let first = active.first, first.title.isEmpty, first.body.isEmpty { return first }
    return create(now: now)
  }

  /// 改正文 / 标题：打字时每个字调一次，攒着等停手再落盘
  func setBody(_ body: String, of id: String, now: Date = .now) {
    let body = Note.sanitized(text: body)
    if mutate(id, now: now, { $0.body = body }) { scheduleSave(at: now) }
  }

  func setTitle(_ title: String, of id: String, now: Date = .now) {
    let title = Note.sanitized(title: title)
    if mutate(id, now: now, { $0.title = title }) { scheduleSave(at: now) }
  }

  func setColor(_ color: Int, of id: String, now: Date = .now) {
    if mutate(id, now: now, { $0.color = Note.clamped(color: color) }) { flush() }
  }

  /// 归档 / 取消归档；取消归档的排回最前
  func setArchived(_ archived: Bool, of id: String) {
    let front = top
    update(id) { note in
      guard note.isArchived != archived else { return }
      note.isArchived = archived
      if !archived { note.order = front }
    }
  }

  func setPinned(_ pinned: Bool, of id: String) { update(id) { $0.isPinned = pinned } }

  /// 挪顺序：把一条没归档、没删的挪成 active 里的第 index 个（挪完之后的下标，越界就放两头）。只改它自己的 order
  /// （取两边中间的值）；两边挨得太近、中间取不出值时（同一处连着插五十来次，或者导入带来了一样的 order）整列重排成 0、1、2…
  func move(_ id: String, to index: Int) {
    var list = active
    guard let from = list.firstIndex(where: { $0.id == id }) else { return }
    let note = list.remove(at: from)
    let target = min(max(index, 0), list.count)
    guard target != from else { return }
    let before = target > 0 ? list[target - 1].order : nil
    let after = target < list.count ? list[target].order : nil
    let order: Double
    switch (before, after) {
    case (nil, nil): return
    case (nil, let after?): order = after - 1
    case (let before?, nil): order = before + 1
    case (let before?, let after?): order = (before + after) / 2
    }
    if let before, let after, !(before < order && order < after) {
      list.insert(note, at: target)
      for (position, item) in list.enumerated() { mutate(item.id) { $0.order = Double(position) } }
      flush()
    } else {
      update(id) { $0.order = order }
    }
  }

  /// 删除：进「最近删除」（留 trashDays 天，restore 放回），不真删
  func delete(_ id: String, now: Date = .now) {
    update(id) { note in
      if note.deletedAt == nil { note.deletedAt = Note.stamp(now) }
    }
  }

  /// 从「最近删除」放回原处
  func restore(_ id: String) { update(id) { $0.deletedAt = nil } }

  /// 永久删除：不进「最近删除」，找不回来
  func erase(_ id: String) { erase([id]) }

  /// 清空「最近删除」：里面的全部永久删除（一个事务）。返回删了几条
  @discardableResult
  func emptyTrash() -> Int {
    let ids = Set(notes.filter { $0.deletedAt != nil }.map(\.id))
    erase(ids)
    return ids.count
  }

  /// 退出前落不下去时用户怎么选
  nonisolated enum QuitChoice { case retry, quitAnyway, cancel }

  /// 退出前把攒着的改动落下去（AppDelegate.applicationShouldTerminate）。落不下去就问（ask 拿到的是原因）：再试一次 /
  /// 仍要退出 / 取消——不悄悄丢。返回能不能退：都落下去了、或者用户说仍要退出是 true，取消是 false。
  /// 没有要落的就不问
  func flushBeforeQuit(ask: (String) -> QuitChoice) -> Bool {
    while !flush() {
      switch ask(saveProblem ?? "原因不明") {
      case .retry: continue
      case .quitAnyway: return true
      case .cancel: return false
      }
    }
    return true
  }

  /// 「最近删除」里放了超过 trashDays 天的真删（启动后、换日时调）。返回删了几条
  @discardableResult
  func purgeExpired(now: Date = .now) -> Int {
    let cutoff = now.addingTimeInterval(-Double(Self.trashDays) * 86_400)
    let expired = notes.filter { note in note.deletedAt.map { $0 < cutoff } ?? false }
    erase(Set(expired.map(\.id)))
    return expired.count
  }

  private func erase(_ ids: Set<String>) {
    let doomed = ids.filter { id in notes.contains { $0.id == id } }
    guard !doomed.isEmpty else { return }
    notes.removeAll { doomed.contains($0.id) }
    for id in doomed {
      summaries[id] = nil
      wallCards[id] = nil
    }
    unsaved.formUnion(doomed)
    flush()
  }

  /// 排到最前用的 order：比现有的都小 1
  private var top: Double { (notes.map(\.order).min() ?? 0) - 1 }

  /// 改一条，只改内存、记成没落盘：真的变了才算——修订号 +1，标题 / 正文 / 颜色变了就把「改于」记成 now
  /// （不动这三样的改动不用给 now）。返回变没变
  @discardableResult
  private func mutate(_ id: String, now: Date? = nil, _ change: (inout Note) -> Void) -> Bool {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
    let old = notes[index]
    var note = old
    change(&note)
    guard note != old else { return false }
    if let now, (note.title, note.body, note.color) != (old.title, old.body, old.color) {
      note.modifiedAt = Note.stamp(now)
    }
    note.revision = Note.nextRevision(after: note.revision)
    notes[index] = note
    unsaved.insert(id)
    return true
  }

  /// 改一条（不动标题、正文、颜色的那些改动）并当场落盘
  private func update(_ id: String, _ change: (inout Note) -> Void) {
    if mutate(id, change) { flush() }
  }

  // MARK: 落盘

  /// 现在就把没落盘的都写下去（一个事务）。返回成没成：不成的留着、原因记进 saveProblem，过一会儿自己再试
  /// （下一次改动、再调一次 flush 也会带上），不悄悄丢
  @discardableResult
  func flush() -> Bool {
    saveTask?.cancel()
    saveTask = nil
    retryTask?.cancel()
    retryTask = nil
    unsavedSince = nil
    guard !unsaved.isEmpty else { return true }
    do {
      try db.transaction {
        // 内存里还有的写上，已经没有的（永久删除、到期清理的）从库里删
        var gone = unsaved
        for note in notes where unsaved.contains(note.id) {
          try db.execute(Self.upsert, Self.encode(note))
          gone.remove(note.id)
        }
        for id in gone { try db.execute("DELETE FROM notes WHERE id = ?", [id]) }
      }
      unsaved = []
      failures = 0
      if saveProblem != nil { saveProblem = nil }
      return true
    } catch {
      saveProblem = "\(error)"
      failures += 1
      Log.storage.error("便签没存上（留着重试）：\(error)")
      retryTask = after(Self.retryDelay(afterFailures: failures))
      return false
    }
  }

  /// 打字之后还要等多久落盘（纯函数）：elapsed 是这一串没落盘的改动里最早那次到现在过了多久。停手 quietDelay 就落；
  /// 一直在改时从最早那次算起不拖过 maxDelay——返回 0 = 现在就落
  nonisolated static func saveDelay(elapsed: TimeInterval) -> TimeInterval {
    max(0, min(quietDelay, maxDelay - elapsed))
  }

  /// 连着失败 count 次之后隔多久再试（纯函数）：5 秒起，每次翻倍，封顶 60 秒
  nonisolated static func retryDelay(afterFailures count: Int) -> TimeInterval {
    min(5 * pow(2, Double(min(max(count, 1), 8) - 1)), 60)
  }

  /// 排一次落盘（上一次排的作废）；到点了就当场落
  private func scheduleSave(at now: Date) {
    let since = unsavedSince ?? now
    let delay = Self.saveDelay(elapsed: now.timeIntervalSince(since))
    guard delay > 0 else {
      flush()
      return
    }
    saveTask?.cancel()
    unsavedSince = since
    saveTask = after(delay)
  }

  /// 等 delay 之后落一次盘；这期间被取消（又有新的改动、已经落过了）、仓库放手了就什么都不做
  private func after(_ delay: TimeInterval) -> Task<Void, Never> {
    Task { [weak self, wait] in
      try? await wait(delay)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  // MARK: 搜索

  /// 在给的这些里搜（一般是 active / archived / trashed）：标题和正文，空白分词、每个词都要命中，不分大小写、全半角、
  /// 变音符号（分词和折叠用剪贴板搜索现成的，Search）；顺序不变，空查询原样返回。
  /// ponytail: 每次把这些便签的正文现折叠一遍（几百条、每条几 KB 是毫秒级）；上千条、边打字边搜卡了，再在仓库里按
  /// 「编号 + 修订号」把折叠结果存下来（同 ClipboardStore.searchKeys，那时改回实例方法）
  static func search(_ query: String, in notes: [Note]) -> [Note] {
    let tokens = Search.tokens(query).map(Search.fold)
    guard !tokens.isEmpty else { return notes }
    return notes.filter { note in
      let bytes = Search.fold(note.title + "\n" + note.body)
      return tokens.allSatisfy { Search.contains(bytes, $0) }
    }
  }

  // MARK: 导出文件

  /// 导入（设置的导出 / 导入里「便签」那一类；entries 是 SettingsArchive.read 查过的）。按编号合并：
  /// - 本机没有的加进来，文件里的时间、颜色、归档、固定、顺序、修订号都照搬（时间不晚于现在）；
  /// - 本机有的，文件里那条改得更晚才整条换成文件里的样子（修订号取两边大的再 +1），否则不动。**被换掉的那一版不丢**：
  ///   文字和文件里的不一样时，另存成一条新便签（新编号）放进「最近删除」，留 trashDays 天——导入不让任何一段本机的
  ///   文字无声消失；
  /// - 文件里「改于」比现在还晚的（那台电脑的钟快，时间信不过）：本机已有就不换，只在本机没有时加进来——不然这种文件
  ///   每导一次都赢一次；
  /// - 本机那条在「最近删除」里的不动（删了的不被导入悄悄救回来，要用就自己放回）；本机独有的不动。
  /// 一个事务落盘；没落下去时 saved 是 false（内容在内存里、留着重试）
  @discardableResult
  func adopt(_ entries: [SettingsArchive.NoteEntry], now: Date = .now) -> Adoption {
    let now = Note.stamp(now)
    var result = Adoption()
    var offsets: [String: Int] = [:]
    for (offset, note) in notes.enumerated() { offsets[note.id] = offset }
    for entry in entries {
      let isAhead = entry.modifiedAt > Note.milliseconds(now)
      let modified = min(Note.date(milliseconds: entry.modifiedAt), now)
      let title = Note.sanitized(title: entry.title)
      let body = Note.sanitized(text: entry.body)
      let color = Note.clamped(color: entry.color)
      let order = entry.order.isFinite ? entry.order : 0
      guard let offset = offsets[entry.id] else {
        offsets[entry.id] = notes.count
        notes.append(
          Note(
            id: entry.id, title: title, body: body, color: color,
            createdAt: min(Note.date(milliseconds: entry.createdAt), now), modifiedAt: modified,
            revision: min(max(entry.revision, 0), Note.maxRevision), isArchived: entry.archived,
            isPinned: entry.pinned, order: order))
        unsaved.insert(entry.id)
        result.added += 1
        continue
      }
      let old = notes[offset]
      guard old.deletedAt == nil, !isAhead, modified > old.modifiedAt else { continue }
      var note = old
      note.title = title
      note.body = body
      note.color = color
      note.modifiedAt = modified
      note.revision = Note.nextRevision(after: max(old.revision, entry.revision))
      note.isArchived = entry.archived
      note.isPinned = entry.pinned
      note.order = order
      notes[offset] = note
      unsaved.insert(entry.id)
      result.updated += 1
      // 被换掉的那一版：有文字、而且和文件里的不一样，就留一份在「最近删除」里
      if (old.title, old.body) != (title, body), !(old.title.isEmpty && old.body.isEmpty) {
        let copy = Note(
          id: UUID().uuidString, title: old.title, body: old.body, color: old.color,
          createdAt: old.createdAt, modifiedAt: old.modifiedAt, isArchived: old.isArchived,
          isPinned: old.isPinned, order: old.order, deletedAt: now)
        notes.append(copy)
        unsaved.insert(copy.id)
      }
    }
    result.saved = flush()
    return result
  }

  // MARK: 库里的一行

  private static func encode(_ note: Note) -> [Any?] {
    [
      note.id, note.title, note.body, note.color, Note.milliseconds(note.createdAt),
      Note.milliseconds(note.modifiedAt), note.revision, note.isArchived, note.isPinned,
      note.order, note.deletedAt.map(Note.milliseconds),
    ]
  }

  /// 库文件也可能被别的东西改过：颜色、修订号夹进范围，不是有限数的顺序当 0
  private static func decode(_ row: Database.Row) -> Note? {
    guard let id = row.text(0), let created = row.int(4), let modified = row.int(5) else {
      return nil
    }
    let order = row.double(9) ?? 0
    return Note(
      id: id, title: row.text(1) ?? "", body: row.text(2) ?? "",
      color: Note.clamped(color: Int(clamping: row.int(3) ?? 0)),
      createdAt: Note.date(milliseconds: created), modifiedAt: Note.date(milliseconds: modified),
      revision: min(max(Int(clamping: row.int(6) ?? 0), 0), Note.maxRevision),
      isArchived: row.int(7) == 1, isPinned: row.int(8) == 1, order: order.isFinite ? order : 0,
      deletedAt: row.int(10).map(Note.date(milliseconds:)))
  }
}
