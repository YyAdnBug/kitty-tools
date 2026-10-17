// 便签的模型和仓库（Notes/Note.swift、Notes/NoteStore.swift）单测。
// 模型：显示用的标题和摘要、时间和整数毫秒互转、进仓库前的收拾（去 NUL、标题截到上限、颜色和修订号夹进范围）。
// 仓库：新建（排最前、颜色轮着取）、每种改动之后「改于」和修订号各变不变、打字的改动攒着等 flush、停手之后自己落盘、
// 下一次改动把上一次排的作废、连着改满 2 s 当场落、「还要等多久」的两个纯函数、写不成的留着并自己再试、带 NUL 的文字
// 存得全、软删 / 放回 / 到期清理 / 永久删除、归档、挪顺序（中间取不出值时整列重排）、搜索、表结构版本比认识的大时
// 不读不写、库里离谱的修订号和顺序、导入合并的每一种情况（被换掉的那一版进「最近删除」、时间在未来的不覆盖、没落下去要说）。
// 另有退出前落盘的询问（flushBeforeQuit，第 2 批）；清空最近删除在 NotesWindowTests。
// 全用内存库；时间都是传进去的固定值，等待换成测试自己放行的，不等真实时间、不碰用户的数据目录。

import Foundation
import Testing

@testable import KittyTools

struct NoteStoreTests {
  /// 固定的「现在」（带毫秒以下的零头：进仓库会对齐到毫秒）
  private static let t0 = Date(timeIntervalSince1970: 1_760_000_000.123_4)
  private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  /// 测试里的「等一会儿」：记下仓库要等多久，停在那里直到测试放行。被取消的任务也停着（放行后它自己看取消标记）
  final class Sleeper {
    private(set) var requested: [TimeInterval] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { pending.count }

    func wait(_ seconds: TimeInterval) async {
      requested.append(seconds)
      await withCheckedContinuation { pending.append($0) }
    }

    /// 放行最早开始等的那个
    func release() { pending.removeFirst().resume() }

    func releaseAll() {
      for continuation in pending { continuation.resume() }
      pending = []
    }
  }

  /// 内存库上的仓库。sleeper：仓库的等待都交给它（不给就是真的等，同步的测试用不到）
  private func open(_ db: Database? = nil, sleeper: Sleeper? = nil) throws -> (
    store: NoteStore, db: Database
  ) {
    let db = try db ?? Database(path: ":memory:")
    guard let sleeper else { return (try NoteStore(db: db), db) }
    return (try NoteStore(db: db) { await sleeper.wait($0) }, db)
  }

  /// 让排着的任务跑一跑：一轮一轮让出主线程，直到条件成立（最多 rounds 轮；按轮数不按时间）
  private func settle(rounds: Int = 300, until done: () -> Bool = { false }) async {
    for _ in 0..<rounds where !done() { await Task.yield() }
  }

  /// 库里现在的样子（另建一个仓库从同一个库读），按编号排好
  private func saved(_ db: Database) throws -> [Note] {
    try NoteStore(db: db).notes.sorted { $0.id < $1.id }
  }

  private func sorted(_ store: NoteStore) -> [Note] { store.notes.sorted { $0.id < $1.id } }

  private func entry(
    _ id: String, _ body: String, modified: Int64, title: String = "", color: Int = 0,
    created: Int64 = 1_700_000_000_000, revision: Int = 3, archived: Bool = false,
    pinned: Bool = false, order: Double = 0
  ) -> SettingsArchive.NoteEntry {
    SettingsArchive.NoteEntry(
      id: id, title: title, body: body, color: color, createdAt: created, modifiedAt: modified,
      revision: revision, archived: archived, pinned: pinned, order: order)
  }

  // MARK: 模型

  /// 标题：自己起的优先；否则正文第一个有内容的行，去掉行首的 # 和任务符号，60 个字截断；都没有是「未命名便签」。
  /// 摘要：其余有内容的行拼成一行，120 个字截断
  @Test func displayTitleAndPreview() {
    func note(_ body: String, title: String = "") -> Note {
      Note(id: "x", title: title, body: body, createdAt: .now, modifiedAt: .now)
    }
    #expect(note("").displayTitle == "未命名便签")
    #expect(note(" \n\n\t\n").displayTitle == "未命名便签")
    #expect(note("买菜\n牛奶").displayTitle == "买菜")
    #expect(note("\n\n  买菜  \n牛奶").displayTitle == "买菜")
    #expect(note("正文第一行", title: "  周报 ").displayTitle == "周报")
    #expect(note("正文第一行", title: "   ").displayTitle == "正文第一行")
    // 行首的标题标记和任务符号不带出来；「#标签」不是标题标记
    #expect(note("# 计划").displayTitle == "计划")
    #expect(note("###   三级标题").displayTitle == "三级标题")
    #expect(note("#标签 你好").displayTitle == "#标签 你好")
    #expect(note("####### 七个井号").displayTitle == "####### 七个井号")
    #expect(note("☐ 买牛奶").displayTitle == "买牛奶")
    #expect(note("☑买牛奶").displayTitle == "买牛奶")
    #expect(note("## ☐ 待办").displayTitle == "待办")
    // 去掉标记之后是空的那一行跳过
    #expect(note("#\n☐\n真正的第一行").displayTitle == "真正的第一行")
    #expect(note("#\n☐").displayTitle == "未命名便签")
    // 60 个字以内原样，超过的截断加「…」
    let sixty = String(repeating: "字", count: 60)
    #expect(note(sixty).displayTitle == sixty)
    #expect(note(sixty + "多").displayTitle == sixty + "…")
    // Windows 换行也按行算
    #expect(note("第一行\r\n第二行").displayTitle == "第一行")

    #expect(note("").preview == "")
    #expect(note("只有一行").preview == "")
    #expect(note("买菜\n\n☐ 牛奶\n  # 水果 \n鸡蛋").preview == "牛奶 水果 鸡蛋")
    // 自己起了标题：正文第一行也进摘要
    #expect(note("买菜\n牛奶", title: "清单").preview == "买菜 牛奶")
    let long = (0..<100).map { "第 \($0) 行的内容" }.joined(separator: "\n")
    let preview = note(long).preview
    #expect(preview.count == 121 && preview.hasSuffix("…") && preview.hasPrefix("第 1 行的内容 第 2 行"))
    // 拼起来正好 120 个字：后面没有了就不加「…」，还有就加
    let exact = "标题\n" + String(repeating: "字", count: 120)
    #expect(note(exact).preview == String(repeating: "字", count: 120))
    #expect(note(exact + "\n还有").preview == String(repeating: "字", count: 120) + "…")
    // 很长的正文只读到够用为止（这里只核对结果对）
    let huge = "标题\n" + String(repeating: "一行\n", count: 200_000)
    #expect(note(huge).displayTitle == "标题" && note(huge).preview.count == 121)
  }

  /// 时间和整数毫秒互转不丢：对齐过的时间存进去、读回来是同一个值；离谱的时间给 0，不闪退
  @Test func millisecondsRoundTrip() {
    for base in [Int64(0), 1_000, 978_307_200_000, 1_760_000_000_000, 4_102_444_800_000] {
      for offset in stride(from: Int64(0), to: 3_000, by: 7) {
        let value = base + offset
        #expect(Note.milliseconds(Note.date(milliseconds: value)) == value)
      }
    }
    let ragged = Date(timeIntervalSince1970: 1_760_000_000.123_456)
    let stamped = Note.stamp(ragged)
    #expect(Note.milliseconds(stamped) == 1_760_000_000_123)
    #expect(Note.stamp(stamped) == stamped)
    #expect(Note.date(milliseconds: Note.milliseconds(stamped)) == stamped)
    #expect(Note.milliseconds(Date(timeIntervalSince1970: 1e300)) == 0)
    #expect(Note.milliseconds(Date(timeIntervalSince1970: .nan)) == 0)
  }

  /// 进仓库前的收拾：文字里的 NUL 去掉、别的原样；标题截到 200 个字、并且不超过 1 KB（一个字挂一长串组合符号的也拦得住）；
  /// 颜色夹进范围；修订号 +1 到顶为止，不溢出
  @Test func sanitizesTextTitlesColorsAndRevisions() {
    #expect(Note.sanitized(text: "前\0后\0") == "前后")
    #expect(Note.sanitized(text: "\0") == "")
    #expect(Note.sanitized(text: "没有 NUL 的\n原样") == "没有 NUL 的\n原样")
    // NUL 后面跟着组合符号（和它拼成一个字）也去得掉
    #expect(Note.sanitized(text: "a\0\u{301}b").unicodeScalars.contains("\0") == false)

    #expect(Note.sanitized(title: "周\0报") == "周报")
    let plain = String(repeating: "字", count: Note.maxTitleLength)
    #expect(Note.sanitized(title: plain) == plain)
    #expect(Note.sanitized(title: plain + "多出来的") == plain)
    // 每个字 25 个字节的表情：先到的是字节上限，停在整字上
    let family = "👨‍👩‍👧‍👦"
    #expect(family.utf8.count == 25)
    let families = Note.sanitized(title: String(repeating: family, count: 100))
    #expect(families == String(repeating: family, count: Note.maxTitleBytes / 25))
    // 一个字后面挂 2000 个组合符号：它自己就超了，一个字都留不下；前面有正常的字就留到它之前
    let monster = "a" + String(repeating: "\u{301}", count: 2000)
    #expect(monster.count == 1 && monster.utf8.count > Note.maxTitleBytes)
    #expect(Note.sanitized(title: monster) == "")
    #expect(Note.sanitized(title: "标题" + monster + "后面") == "标题")
    for title in [plain + plain, String(repeating: family, count: 300), monster + monster] {
      let cut = Note.sanitized(title: title)
      #expect(cut.count <= Note.maxTitleLength && cut.utf8.count <= Note.maxTitleBytes)
    }

    #expect(Note.clamped(color: -1) == 0 && Note.clamped(color: 3) == 3)
    #expect(Note.clamped(color: 99) == Note.colorCount - 1)
    #expect(Note.clamped(color: .max) == Note.colorCount - 1 && Note.clamped(color: .min) == 0)

    #expect(Note.nextRevision(after: 0) == 1 && Note.nextRevision(after: 41) == 42)
    #expect(Note.nextRevision(after: Note.maxRevision - 1) == Note.maxRevision)
    #expect(Note.nextRevision(after: Note.maxRevision) == Note.maxRevision)
    #expect(Note.nextRevision(after: .max) == Note.maxRevision)
    #expect(Note.nextRevision(after: -5) == 1)
  }

  // MARK: 新建和改动

  /// 新便签排最前、颜色接着上一条往下轮、时间是传进去的现在（对齐到毫秒）、编号是 UUID；写进了库
  @Test func createPutsNewNotesFirstAndRotatesColors() throws {
    let (store, db) = try open()
    #expect(store.notes.isEmpty && store.active.isEmpty)
    let first = store.create(body: "第一条", now: Self.t0)
    #expect(first.color == 0 && first.revision == 0 && first.title.isEmpty)
    #expect(first.createdAt == Note.stamp(Self.t0) && first.modifiedAt == first.createdAt)
    #expect(first.createdAt != Self.t0)
    #expect(UUID(uuidString: first.id) != nil)
    // 同一刻连着建：颜色照样往下轮，新的在前
    let rest = (1..<Note.colorCount + 1).map { store.create(body: "第 \($0 + 1) 条", now: Self.t0) }
    #expect(rest.map(\.color) == [1, 2, 3, 4, 5, 6, 7, 0])
    #expect(store.active.map(\.id) == (rest.reversed() + [first]).map(\.id))
    #expect(Set(store.notes.map(\.id)).count == 9)
    #expect(try saved(db) == sorted(store))
    // 重新打开：顺序、颜色照旧，接着往下轮
    let reopened = try NoteStore(db: db)
    #expect(reopened.active.map(\.id) == store.active.map(\.id))
    #expect(reopened.create(now: Self.t0).color == 1)
  }

  /// 修订号：任何字段真的变了一次就 +1；「改于」只在标题 / 正文 / 颜色变时更新；值没变的改动什么都不动
  @Test func editsBumpRevisionAndTouchModifiedOnlyForContent() throws {
    let (store, db) = try open()
    let id = store.create(body: "原文", now: Self.t0).id
    let created = try #require(store.note(id)).createdAt
    var (revision, clock) = (0, 0.0)
    /// 做一次改动（过了一分钟），核对修订号 +1、「改于」变没变
    func expect(touches: Bool, _ change: (Date) -> Void) throws {
      clock += 60
      let before = try #require(store.note(id))
      change(Self.at(clock))
      let after = try #require(store.note(id))
      revision += 1
      #expect(after.revision == revision)
      #expect(after.createdAt == created)
      #expect(after.modifiedAt == (touches ? Note.stamp(Self.at(clock)) : before.modifiedAt))
    }
    try expect(touches: true) { store.setBody("改过的正文", of: id, now: $0) }
    try expect(touches: true) { store.setTitle("标题", of: id, now: $0) }
    try expect(touches: true) { store.setColor(3, of: id, now: $0) }
    try expect(touches: false) { _ in store.setPinned(true, of: id) }
    try expect(touches: false) { _ in store.setArchived(true, of: id) }
    try expect(touches: false) { _ in store.setArchived(false, of: id) }
    try expect(touches: false) { store.delete(id, now: $0) }
    try expect(touches: false) { _ in store.restore(id) }
    let other = store.create(body: "另一条", now: Self.at(clock)).id
    try expect(touches: false) { _ in store.move(id, to: 0) }
    #expect(store.active.map(\.id) == [id, other])

    // 值没变：修订号、「改于」都不动
    let settled = try #require(store.note(id))
    let later = Self.at(clock + 60)
    store.setBody("改过的正文", of: id, now: later)
    store.setTitle("标题", of: id, now: later)
    store.setColor(3, of: id, now: later)
    store.setPinned(true, of: id)
    store.setArchived(false, of: id)
    store.restore(id)
    store.move(id, to: 0)
    #expect(store.note(id) == settled)
    // 颜色夹进范围；不认识的编号什么都不做
    store.setColor(99, of: id, now: later)
    #expect(store.note(id)?.color == Note.colorCount - 1)
    store.setColor(-5, of: id, now: later)
    #expect(store.note(id)?.color == 0)
    store.setBody("没有这条", of: "不存在", now: later)
    store.delete("不存在", now: later)
    #expect(store.notes.count == 2)
    #expect(store.flush())
    #expect(try saved(db) == sorted(store))
  }

  /// 带 NUL 的文字：每个写入口都先去掉它，存下去再读回来是去掉 NUL 之后的全文（不然库里只剩 NUL 前面那一截）
  @Test func textWithNULIsStoredWhole() throws {
    let (store, db) = try open()
    let made = store.create(body: "新建\0的正文", title: "标\0题", now: Self.t0)
    #expect(made.body == "新建的正文" && made.title == "标题")
    #expect(try saved(db) == [made])
    store.setBody("改\0过的\0正文，后半截还在", of: made.id, now: Self.at(1))
    store.setTitle("\0改过的标题", of: made.id, now: Self.at(1))
    #expect(store.flush())
    let row = try #require(try saved(db).first)
    #expect(row.body == "改过的正文，后半截还在" && row.title == "改过的标题")
    #expect(row == store.note(made.id))
    let id = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    store.adopt(
      [entry(id, "导入\0的正文", modified: 1_700_000_000_000, title: "导入\0的标题")], now: Self.at(2))
    let adopted = try #require(try saved(db).first { $0.id == id })
    #expect(adopted.body == "导入的正文" && adopted.title == "导入的标题")
  }

  /// 标题超过上限：新建、改标题、导入都截到上限（不清空、不原样留着）
  @Test func titlesAreCutToTheLimit() throws {
    let (store, db) = try open()
    let limit = String(repeating: "长", count: Note.maxTitleLength)
    let made = store.create(body: "正文", title: limit + "多出来的", now: Self.t0)
    #expect(made.title == limit)
    store.setTitle("短的", of: made.id, now: Self.at(1))
    store.setTitle(limit + limit, of: made.id, now: Self.at(2))
    #expect(store.note(made.id)?.title == limit)
    let id = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    store.adopt(
      [entry(id, "正文", modified: 1_700_000_000_000, title: limit + "多出来的")], now: Self.at(3))
    #expect(store.note(id)?.title == limit)
    #expect(store.flush())
    #expect(try saved(db) == sorted(store))
  }

  // MARK: 落盘

  /// 「打字之后还要等多久落盘」：停手 250 ms；一直在改时，从最早那次没落盘的改动算起不拖过 2 s。
  /// 「失败之后隔多久再试」：5 秒起，每次翻倍，封顶 60 秒
  @Test func delaysArePureFunctions() {
    #expect(NoteStore.saveDelay(elapsed: 0) == 0.25)
    #expect(NoteStore.saveDelay(elapsed: 1) == 0.25)
    #expect(NoteStore.saveDelay(elapsed: 1.75) == 0.25)
    #expect(abs(NoteStore.saveDelay(elapsed: 1.9) - 0.1) < 1e-9)
    #expect(NoteStore.saveDelay(elapsed: 2) == 0)
    #expect(NoteStore.saveDelay(elapsed: 60) == 0)
    // 钟往回拨了：照常等一个停手的时间，不会等更久
    #expect(NoteStore.saveDelay(elapsed: -30) == 0.25)

    #expect((1...6).map(NoteStore.retryDelay(afterFailures:)) == [5, 10, 20, 40, 60, 60])
    #expect(NoteStore.retryDelay(afterFailures: 0) == 5)
    #expect(NoteStore.retryDelay(afterFailures: 1_000_000) == 60)
  }

  /// 改正文 / 标题先只改内存，flush 才写库；别的改动当场落、把攒着的一起带下去；连着改满 2 s 那一下当场落
  @Test func typingIsSavedOnFlushAndOtherChangesSaveAtOnce() throws {
    let (store, db) = try open()
    let id = store.create(body: "原文", now: Self.t0).id
    store.setBody("打了几个字", of: id, now: Self.at(1))
    store.setTitle("新标题", of: id, now: Self.at(1))
    #expect(store.note(id)?.body == "打了几个字")
    #expect(try saved(db).first?.body == "原文" && saved(db).first?.title == "")
    #expect(store.flush())
    #expect(try saved(db) == sorted(store))
    #expect(store.flush())  // 没有要落的也算成

    // 别的改动当场落，攒着的正文一起带下去
    store.setBody("又打了几个字", of: id, now: Self.at(2))
    #expect(try saved(db).first?.body == "打了几个字")
    store.setPinned(true, of: id)
    #expect(try saved(db) == sorted(store))

    // 连着改：没满 2 s 都攒着，满了的那一下当场落；之后重新计
    store.setBody("连着改 1", of: id, now: Self.at(10))
    store.setBody("连着改 2", of: id, now: Self.at(11.2))
    store.setBody("连着改 3", of: id, now: Self.at(11.9))
    #expect(try saved(db).first?.body == "又打了几个字")
    store.setBody("连着改 4", of: id, now: Self.at(12.1))
    #expect(try saved(db).first?.body == "连着改 4")
    store.setBody("连着改 5", of: id, now: Self.at(12.2))
    #expect(try saved(db).first?.body == "连着改 4")
    #expect(store.flush())
    #expect(try saved(db) == sorted(store))
  }

  /// 停手之后不用谁来调，自己落盘：改了正文，等的那一下过去之后库里就是新的；
  /// 下一次改动把上一次排的作废——上一次的等到了点也不落，落的是后排的那一次
  @Test func typingSavesItselfAfterTheQuietDelay() async throws {
    let sleeper = Sleeper()
    let (store, db) = try open(sleeper: sleeper)
    let id = store.create(body: "原文", now: Self.t0).id
    store.setBody("停手之后自己落下去", of: id, now: Self.at(1))
    await settle { sleeper.waiting == 1 }
    #expect(sleeper.requested == [NoteStore.quietDelay])
    #expect(try saved(db).first?.body == "原文")
    sleeper.release()
    await settle { (try? saved(db).first?.body) == "停手之后自己落下去" }
    #expect(try saved(db) == sorted(store))

    // 连着打两下：第一下排的那次作废
    store.setBody("第一下", of: id, now: Self.at(5))
    await settle { sleeper.waiting == 1 }
    store.setBody("第二下", of: id, now: Self.at(5.1))
    await settle { sleeper.waiting == 2 }
    #expect(sleeper.requested.count == 3)
    sleeper.release()  // 第一下的等到了点
    await settle(rounds: 50)
    #expect(try saved(db).first?.body == "停手之后自己落下去")
    sleeper.release()  // 第二下的
    await settle { (try? saved(db).first?.body) == "第二下" }
    #expect(try saved(db) == sorted(store))
    // 没有东西要落了，也没有多排出来的
    await settle(rounds: 50)
    #expect(sleeper.waiting == 0 && sleeper.requested.count == 3)
  }

  /// 写不成：改动留在内存里、原因记下来、flush 说没成；库好了之后再落一次就都下去了（连删除在内），原因收掉
  @Test func failedWritesAreKeptAndFlushedLater() throws {
    let (store, db) = try open()
    let kept = store.create(body: "留着的", now: Self.t0).id
    let doomed = store.create(body: "要删的", now: Self.t0).id
    #expect(store.saveProblem == nil)
    // 把表挪走：之后的写都会失败
    try db.execute("ALTER TABLE notes RENAME TO parked")
    store.setPinned(true, of: kept)
    #expect(store.saveProblem?.isEmpty == false)
    #expect(store.note(kept)?.isPinned == true)
    store.setBody("没存上的正文", of: kept, now: Self.at(1))
    store.erase(doomed)
    #expect(!store.flush())
    #expect(store.notes.map(\.id) == [kept] && store.saveProblem != nil)

    try db.execute("ALTER TABLE parked RENAME TO notes")
    #expect(try saved(db).count == 2 && saved(db).allSatisfy { !$0.isPinned })
    #expect(store.flush())
    #expect(store.saveProblem == nil)
    let rows = try saved(db)
    #expect(rows == sorted(store))
    #expect(rows.map(\.id) == [kept] && rows.first?.body == "没存上的正文")
    #expect(rows.first?.isPinned == true)
  }

  /// 退出前落盘：没有要落的、落得下去的不问；落不下去就问——再试一次（库好了就成）、仍要退出（放行）、取消（不退）
  @Test func flushBeforeQuitAsksOnlyWhenWritesFail() throws {
    let (store, db) = try open()
    let id = store.create(body: "旧的", now: Self.t0).id
    var asked: [String] = []
    let ask = { (choice: NoteStore.QuitChoice) in
      { (problem: String) -> NoteStore.QuitChoice in
        asked.append(problem)
        return choice
      }
    }
    #expect(store.flushBeforeQuit(ask: ask(.cancel)))
    store.setBody("攒着的", of: id, now: Self.at(1))
    #expect(store.flushBeforeQuit(ask: ask(.cancel)))
    #expect(try asked.isEmpty && saved(db).first?.body == "攒着的")

    try db.execute("ALTER TABLE notes RENAME TO parked")
    store.setBody("没存上的", of: id, now: Self.at(2))
    #expect(!store.flushBeforeQuit(ask: ask(.cancel)))
    #expect(asked.count == 1 && asked[0].isEmpty == false)
    #expect(store.flushBeforeQuit(ask: ask(.quitAnyway)))
    #expect(asked.count == 2 && store.saveProblem != nil)
    // 再试一次：问的时候把库修好，下一轮就落下去了，不再问
    let repaired = store.flushBeforeQuit { problem in
      asked.append(problem)
      try? db.execute("ALTER TABLE parked RENAME TO notes")
      return .retry
    }
    #expect(repaired && asked.count == 3 && store.saveProblem == nil)
    #expect(try saved(db).first?.body == "没存上的")
  }

  /// 写不成之后自己再试：5 秒后一次，还不成 10 秒后再一次……库好了的那一次成了，原因收掉、不再排
  @Test func failedWritesRetryOnTheirOwn() async throws {
    let sleeper = Sleeper()
    let (store, db) = try open(sleeper: sleeper)
    let id = store.create(body: "正文", now: Self.t0).id
    try db.execute("ALTER TABLE notes RENAME TO parked")
    store.setPinned(true, of: id)
    #expect(store.saveProblem != nil)
    await settle { sleeper.waiting == 1 }
    #expect(sleeper.requested == [5])
    // 到点了库还没好：再排一次，隔得更久
    sleeper.release()
    await settle { sleeper.requested.count == 2 && sleeper.waiting == 1 }
    #expect(sleeper.requested == [5, 10] && store.saveProblem != nil)
    // 库好了：到点的那一次落下去
    try db.execute("ALTER TABLE parked RENAME TO notes")
    sleeper.release()
    await settle { store.saveProblem == nil }
    #expect(store.saveProblem == nil)
    #expect(try saved(db).first?.isPinned == true)
    await settle(rounds: 50)
    #expect(sleeper.waiting == 0 && sleeper.requested == [5, 10])

    // 等着重试的时候自己先落成了（下一次改动、有人调 flush）：排着的那次作废，之后重新从 5 秒算
    try db.execute("ALTER TABLE notes RENAME TO parked")
    store.setPinned(false, of: id)
    await settle { sleeper.waiting == 1 }
    try db.execute("ALTER TABLE parked RENAME TO notes")
    #expect(store.flush())
    sleeper.release()
    await settle(rounds: 50)
    #expect(sleeper.requested == [5, 10, 5] && sleeper.waiting == 0)
    #expect(try saved(db) == sorted(store))
    sleeper.releaseAll()
  }

  // MARK: 删除、归档、顺序

  /// 删除进「最近删除」（刚删的在前），放回去回到原处；放了超过 30 天的清理时真删——正好 30 天的还留着；永久删除直接没
  @Test func softDeleteRestoreAndPurge() throws {
    let (store, db) = try open()
    let day = 86_400.0
    let ids = (0..<4).map { store.create(body: "第 \($0) 条", now: Self.t0).id }
    #expect(store.active.map(\.id) == ids.reversed())
    store.delete(ids[1], now: Self.t0)
    store.delete(ids[2], now: Self.at(day))
    #expect(store.active.map(\.id) == [ids[3], ids[0]])
    #expect(store.trashed.map(\.id) == [ids[2], ids[1]])
    #expect(store.trashed.first?.deletedAt == Note.stamp(Self.at(day)))
    #expect(store.exportable.map(\.id) == [ids[3], ids[0]])
    // 再删一次不改删除时间
    let deleted = store.note(ids[1])
    store.delete(ids[1], now: Self.at(day + 10))
    #expect(store.note(ids[1]) == deleted)
    #expect(try saved(db) == sorted(store))

    store.restore(ids[2])
    #expect(store.active.map(\.id) == [ids[3], ids[2], ids[0]])
    #expect(store.note(ids[2])?.deletedAt == nil)

    // ids[1] 是第 0 天删的：第 29 天还在；正好满 30 天的那一刻还在，过一毫秒就清掉
    let deletedAt = try #require(store.note(ids[1])?.deletedAt)
    let thirty = deletedAt.addingTimeInterval(Double(NoteStore.trashDays) * day)
    #expect(store.purgeExpired(now: deletedAt.addingTimeInterval(29 * day)) == 0)
    #expect(store.purgeExpired(now: thirty) == 0)
    #expect(store.trashed.map(\.id) == [ids[1]])
    #expect(store.purgeExpired(now: thirty.addingTimeInterval(0.001)) == 1)
    #expect(store.trashed.isEmpty && store.notes.count == 3)
    #expect(try saved(db) == sorted(store))
    // 清过了再清一遍：没有东西
    #expect(store.purgeExpired(now: thirty.addingTimeInterval(day)) == 0)

    store.erase(ids[3])
    store.erase("不存在")
    #expect(store.notes.map(\.id).sorted() == [ids[0], ids[2]].sorted())
    #expect(try saved(db) == sorted(store))
  }

  /// 归档的不在 active 里、按最近改过的排；取消归档回到最前
  @Test func archivedNotesLeaveTheListAndComeBackOnTop() throws {
    let (store, db) = try open()
    let ids = (0..<3).map { store.create(body: "第 \($0) 条", now: Self.t0).id }
    store.setBody("后改的", of: ids[0], now: Self.at(60))
    store.setBody("最后改的", of: ids[2], now: Self.at(120))
    store.setArchived(true, of: ids[0])
    store.setArchived(true, of: ids[2])
    #expect(store.active.map(\.id) == [ids[1]])
    #expect(store.archived.map(\.id) == [ids[2], ids[0]])
    #expect(store.exportable.count == 3)
    store.delete(ids[2], now: Self.at(180))
    #expect(store.archived.map(\.id) == [ids[0]] && store.trashed.map(\.id) == [ids[2]])
    store.setArchived(false, of: ids[0])
    #expect(store.active.map(\.id) == [ids[0], ids[1]])
    #expect(try saved(db) == sorted(store))
  }

  /// 挪顺序：挪完之后是第 index 个，越界放两头；只改被挪那条的 order；同一处连着插很多次、两边的 order 一样时
  /// 整列重排，顺序照样对
  @Test func moveReordersByChangingOneNote() throws {
    let (store, db) = try open()
    let ids = (0..<5).map { store.create(body: "第 \($0) 条", now: Self.t0).id }.reversed().map { $0 }
    #expect(store.active.map(\.id) == ids)
    func expectOrder(_ indices: [Int]) throws {
      #expect(store.active.map(\.id) == indices.map { ids[$0] })
      #expect(try NoteStore(db: db).active.map(\.id) == indices.map { ids[$0] })
    }
    store.move(ids[4], to: 0)
    try expectOrder([4, 0, 1, 2, 3])
    store.move(ids[4], to: 2)
    try expectOrder([0, 1, 4, 2, 3])
    store.move(ids[0], to: 99)
    try expectOrder([1, 4, 2, 3, 0])
    store.move(ids[3], to: -3)
    try expectOrder([3, 1, 4, 2, 0])
    store.move(ids[1], to: 3)
    try expectOrder([3, 4, 2, 1, 0])
    // 五次都只有被挪的那条变了
    #expect(store.notes.map(\.revision).reduce(0, +) == 5)
    // 归档的、删掉的、不认识的不挪
    store.setArchived(true, of: ids[0])
    store.move(ids[0], to: 0)
    store.move("不存在", to: 0)
    try expectOrder([3, 4, 2, 1])

    // 同一处连着插 80 次：中间早就取不出值了，顺序每次都对
    for round in 0..<80 {
      let moving = round.isMultiple(of: 2) ? ids[2] : ids[1]
      store.move(moving, to: 1)
      #expect(Array(store.active.map(\.id).prefix(2)) == [ids[3], moving])
    }
    #expect(Set(store.active.map(\.order)).count == 4)
    #expect(try NoteStore(db: db).active.map(\.id) == store.active.map(\.id))

    // 导入带来一样的 order：插到它们中间照样排得对
    let twins = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]
    store.adopt(
      twins.map { entry($0, "一样的顺序", modified: 1_700_000_000_000, order: 500) }, now: Self.t0)
    let before = store.active.map(\.id)
    #expect(Array(before.suffix(2)) == twins)
    store.move(before[0], to: before.count - 2)
    #expect(
      store.active.map(\.id) == Array(before[1..<(before.count - 1)]) + [before[0], twins[1]])
    #expect(Set(store.active.map(\.order)).count == before.count)
    #expect(try NoteStore(db: db).active.map(\.id) == store.active.map(\.id))
  }

  // MARK: 搜索

  /// 搜标题和正文：不分大小写、全半角，空白分词每个词都要命中；顺序不变，空查询原样返回
  @Test func searchMatchesTitleAndBody() throws {
    let (store, _) = try open()
    let weekly = store.create(body: "本周：发布 0.5.0\nReview 便签的数据层", title: "周报")
    let shopping = store.create(body: "牛奶、鸡蛋\nＡＰＰＬＥ 两斤")
    let empty = store.create()
    let all = store.active
    #expect(all.map(\.id) == [empty.id, shopping.id, weekly.id])
    #expect(NoteStore.search("", in: all) == all)
    #expect(NoteStore.search("   ", in: all) == all)
    #expect(NoteStore.search("周报", in: all).map(\.id) == [weekly.id])
    #expect(NoteStore.search("review", in: all).map(\.id) == [weekly.id])
    #expect(NoteStore.search("apple", in: all).map(\.id) == [shopping.id])
    #expect(NoteStore.search("牛奶 两斤", in: all).map(\.id) == [shopping.id])
    #expect(NoteStore.search("牛奶 发布", in: all).isEmpty)
    #expect(NoteStore.search("0.5 周报", in: all).map(\.id) == [weekly.id])
    // 标题和正文不会连成一个词
    #expect(NoteStore.search("周报本周", in: all).isEmpty)
    // 只在给的那些里搜
    #expect(NoteStore.search("牛奶", in: [weekly]).isEmpty)
  }

  /// F19：搜索不看正文里的图片令牌——搜「image」「png」或者编号里的十六进制都不该命中带图的便签
  @Test func searchIgnoresImageTokens() throws {
    let (store, _) = try open()
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let withImage = store.create(
      body: "买菜\n\(NoteImages.token(NoteImages.Image(id: id, ext: "png")))\n牛奶")
    let plain = store.create(body: "另一条")
    let all = store.active
    #expect(NoteStore.search("牛奶", in: all).map(\.id) == [withImage.id])
    #expect(NoteStore.search("买菜", in: all).map(\.id) == [withImage.id])
    #expect(NoteStore.search("image", in: all).isEmpty)
    #expect(NoteStore.search("png", in: all).isEmpty)
    #expect(NoteStore.search("11111111", in: all).isEmpty)
    #expect(NoteStore.search("另一条", in: all).map(\.id) == [plain.id])
  }

  // MARK: 表结构的版本、库里离谱的值

  /// 新库建好表、版本设成 1；再开一次照常。版本比认识的大：抛说得清原因的错，库一个字都不写
  @Test func refusesDatabasesFromNewerVersions() throws {
    let db = try Database(path: ":memory:")
    let version = { try db.query("PRAGMA user_version") { $0.int(0) } }
    #expect(try version() == [0])
    let store = try NoteStore(db: db)
    #expect(try version() == [Int64(NoteStore.schemaVersion)])
    let id = store.create(body: "留着").id
    #expect(try NoteStore(db: db).notes.map(\.id) == [id])

    // 以后的版本：多了一列，版本号 +1
    try db.execute("ALTER TABLE notes ADD COLUMN mood TEXT")
    try db.execute("PRAGMA user_version = \(NoteStore.schemaVersion + 1)")
    let schema = { try db.query("SELECT sql FROM sqlite_master") { $0.text(0) } }
    let before = try schema()
    #expect(throws: NoteStore.Failure.newer(NoteStore.schemaVersion + 1)) {
      try NoteStore(db: db)
    }
    #expect(try version() == [Int64(NoteStore.schemaVersion + 1)])
    #expect(try schema() == before)
    #expect(try db.query("SELECT body FROM notes") { $0.text(0) } == ["留着"])
    let message = "\(NoteStore.Failure.newer(2))"
    #expect(message.contains("便签的数据是更新版本的 Kitty Tools 写的"))
  }

  /// 库里的值离谱（文件被别的东西改过）：修订号夹到上限、再改也不溢出；不是有限数的顺序当 0；颜色夹进范围
  @Test func readsOutOfRangeRowsSafely() throws {
    let (store, db) = try open()
    let id = store.create(body: "正文", now: Self.t0).id
    try db.execute(
      "UPDATE notes SET revision = ?, sort_order = ?, color = ? WHERE id = ?",
      [Int64.max, Double.infinity, 99, id])
    let reopened = try NoteStore(db: db)
    let note = try #require(reopened.note(id))
    #expect(note.revision == Note.maxRevision && note.order == 0)
    #expect(note.color == Note.colorCount - 1)
    reopened.setPinned(true, of: id)
    reopened.setBody("还能改", of: id, now: Self.at(1))
    #expect(reopened.note(id)?.revision == Note.maxRevision)
    #expect(reopened.flush())
    #expect(try saved(db) == sorted(reopened))
    try db.execute("UPDATE notes SET revision = ? WHERE id = ?", [Int64.min, id])
    #expect(try NoteStore(db: db).note(id)?.revision == 0)
  }

  // MARK: 导入合并

  /// 按编号合并：本机没有的加进来（时间、颜色、归档、固定、顺序、修订号照文件）；本机有的，文件里改得更晚才换成文件的；
  /// 一样新、更旧的不动；本机在「最近删除」里的不动；本机独有的不动。再导一遍什么都不变；库里和内存一致
  @Test func adoptMergesByID() throws {
    let (store, db) = try open()
    let local = store.create(body: "本机独有的", now: Self.t0)
    let older = store.create(body: "本机旧、文件新", now: Self.t0)
    let newer = store.create(body: "本机新、文件旧", now: Self.t0)
    let same = store.create(body: "一样新", now: Self.t0)
    let trashed = store.create(body: "本机删了的", now: Self.t0)
    store.setPinned(true, of: older.id)
    store.delete(trashed.id, now: Self.t0)
    let now = Note.milliseconds(Self.t0)
    let fresh = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    let before = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })

    let entries = [
      entry(
        fresh, "文件里才有的", modified: now - 5_000, title: "新来的", color: 5,
        created: now - 9_000, revision: 12, archived: true, pinned: true, order: 7.5),
      entry(
        older.id, "文件里更新的一版", modified: now + 1, title: "换了标题", color: 2,
        created: 1, revision: 40, archived: true, pinned: false, order: -20),
      entry(newer.id, "文件里更旧的一版", modified: now - 1, color: 6, revision: 99),
      entry(same.id, "文件里一样新的一版", modified: now, color: 6, revision: 99),
      entry(trashed.id, "文件里改得更晚", modified: now + 60_000, revision: 99),
    ]
    let importedAt = Self.at(120)
    let outcome = store.adopt(entries, now: importedAt)
    #expect(outcome == NoteStore.Adoption(added: 1, updated: 1, saved: true))

    #expect(
      store.note(fresh)
        == Note(
          id: fresh, title: "新来的", body: "文件里才有的", color: 5,
          createdAt: Note.date(milliseconds: now - 9_000),
          modifiedAt: Note.date(milliseconds: now - 5_000), revision: 12, isArchived: true,
          isPinned: true, order: 7.5))
    let replaced = try #require(store.note(older.id))
    #expect(replaced.body == "文件里更新的一版" && replaced.title == "换了标题" && replaced.color == 2)
    #expect(replaced.modifiedAt == Note.date(milliseconds: now + 1))
    #expect(replaced.isArchived && !replaced.isPinned && replaced.order == -20)
    // 建于不跟文件走；修订号在两边大的上面 +1
    #expect(replaced.createdAt == older.createdAt && replaced.revision == 41)
    for id in [local.id, newer.id, same.id, trashed.id] { #expect(store.note(id) == before[id]) }
    // 六条 + 被换掉的那一版（在「最近删除」里，见 adoptKeepsTheVersionItReplaces）
    #expect(store.notes.count == 7 && store.trashed.count == 2)
    #expect(try saved(db) == sorted(store))

    // 再导一遍：没有新的、没有更新的，也不再多出「被换掉的」
    let settled = sorted(store)
    let again = store.adopt(entries, now: Self.at(240))
    #expect(again == NoteStore.Adoption())
    #expect(sorted(store) == settled)
    #expect(store.adopt([], now: Self.at(240)) == NoteStore.Adoption())
  }

  /// 导入把本机的一条整条换掉时，被换掉的那一版不丢：另存成一条新便签（新编号，标题、正文、颜色照旧）放进「最近删除」，
  /// 能放回来。文字和文件里一样的（只是颜色、归档不同）、本来就是空的，不用留
  @Test func adoptKeepsTheVersionItReplaces() throws {
    let (store, db) = try open()
    let mine = store.create(body: "本机写了很久的一版", title: "我的标题", now: Self.t0)
    let sameText = store.create(body: "两边文字一样", now: Self.t0)
    let blank = store.create(now: Self.t0)
    store.setColor(6, of: mine.id, now: Self.t0)
    store.setPinned(true, of: mine.id)
    let old = try #require(store.note(mine.id))
    let now = Note.milliseconds(Self.t0)
    let importedAt = Self.at(3_600)
    let outcome = store.adopt(
      [
        entry(mine.id, "文件里的一版", modified: now + 1_000, title: "文件的标题", color: 1),
        entry(sameText.id, "两边文字一样", modified: now + 1_000, color: 4, archived: true),
        entry(blank.id, "文件里有字", modified: now + 1_000),
      ], now: importedAt)
    #expect(outcome == NoteStore.Adoption(added: 0, updated: 3, saved: true))
    #expect(store.note(mine.id)?.body == "文件里的一版")
    #expect(store.note(sameText.id)?.color == 4 && store.note(sameText.id)?.isArchived == true)
    #expect(store.note(blank.id)?.body == "文件里有字")

    // 只有文字被换掉的那一条留了一版
    #expect(store.notes.count == 4 && store.trashed.count == 1)
    let kept = try #require(store.trashed.first)
    #expect(kept.id != mine.id && UUID(uuidString: kept.id) != nil)
    #expect(kept.title == "我的标题" && kept.body == "本机写了很久的一版" && kept.color == 6)
    #expect(kept.deletedAt == Note.stamp(importedAt))
    #expect(kept.createdAt == old.createdAt && kept.modifiedAt == old.modifiedAt)
    #expect(try saved(db) == sorted(store))
    // 放回来：两版都在
    store.restore(kept.id)
    #expect(Set(store.exportable.map(\.body)).isSuperset(of: ["文件里的一版", "本机写了很久的一版"]))
    // 留 30 天：和别的「最近删除」一样到期清掉
    store.delete(kept.id, now: importedAt)
    #expect(store.purgeExpired(now: importedAt.addingTimeInterval(31 * 86_400)) == 1)
    #expect(store.trashed.isEmpty)
  }

  /// 文件里「改于」比现在还晚的那条（那台电脑的钟快）：本机已有就不覆盖，本机没有才加进来（时间收成现在）。
  /// 同一个文件连导两遍，第二遍什么都不变。颜色夹进范围；文件里重复的编号只认第一条
  @Test func adoptDoesNotLetFutureTimesWin() throws {
    let (store, db) = try open()
    let mine = store.create(body: "本机的", now: Self.t0)
    let now = Note.milliseconds(Self.t0)
    let id = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    let entries = [
      entry(id, "钟快的电脑写的", modified: now + 86_400_000, color: 42, created: now + 3_600_000),
      entry(id, "重复的编号", modified: now + 86_400_000, color: 1),
      entry(mine.id, "钟快的电脑上的一版", modified: now + 86_400_000),
    ]
    let importedAt = Self.at(60)
    let first = store.adopt(entries, now: importedAt)
    #expect(first == NoteStore.Adoption(added: 1, updated: 0, saved: true))
    let note = try #require(store.note(id))
    #expect(note.body == "钟快的电脑写的" && note.color == Note.colorCount - 1)
    #expect(note.createdAt == Note.stamp(importedAt) && note.modifiedAt == Note.stamp(importedAt))
    #expect(store.note(mine.id) == mine)
    #expect(try saved(db) == sorted(store))

    // 再导一遍、过一阵再导一遍：都不变（不会每导一次赢一次），也不往「最近删除」里塞东西
    let settled = sorted(store)
    for later in [importedAt, Self.at(3_600), Self.at(7_200)] {
      #expect(store.adopt(entries, now: later) == NoteStore.Adoption())
      #expect(sorted(store) == settled)
    }
    #expect(store.trashed.isEmpty)
    // 等到文件里的时间不再是未来（真过了一天多）：这时它确实比本机的新，才换（两条都是；重复的那条照旧不认）
    let caughtUp = store.adopt(entries, now: Self.at(2 * 86_400))
    #expect(caughtUp == NoteStore.Adoption(added: 0, updated: 2, saved: true))
    #expect(store.note(mine.id)?.body == "钟快的电脑上的一版" && store.note(id)?.body == "钟快的电脑写的")
    #expect(store.trashed.map(\.body) == ["本机的"])

    // 导出再导回来：编号、内容、时间都对得上，什么都不变
    let exported = store.exportable.compactMap(SettingsArchive.NoteEntry.init)
    #expect(store.adopt(exported, now: Self.at(3 * 86_400)) == NoteStore.Adoption())
  }

  /// 导入的时候没落下去：结果里说没存上（内容在内存里、留着重试），库好了之后落得下去
  @Test func adoptReportsWhenNothingWasSaved() throws {
    let (store, db) = try open()
    try db.execute("ALTER TABLE notes RENAME TO parked")
    let id = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    let outcome = store.adopt([entry(id, "没存上的", modified: 1_700_000_000_000)], now: Self.t0)
    #expect(outcome == NoteStore.Adoption(added: 1, updated: 0, saved: false))
    #expect(store.note(id)?.body == "没存上的" && store.saveProblem != nil)
    try db.execute("ALTER TABLE parked RENAME TO notes")
    #expect(store.flush())
    #expect(try saved(db).map(\.id) == [id])
  }
}
