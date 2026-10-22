// 便签同步的数据准备（便签未来计划 A，第 1 批：Notes/NoteSync.swift 的合并规则 + NoteStore 里同步要的账）：
// - 合并（纯函数）：快进不留旧版、旧的那版不理、两边各改了才是冲突（后改的赢、输的那版另存一条、几台存的是同一条）、
//   慢了的钟照样快进、钟一样字不一样也当冲突、状态后改的赢、顺序单独合、一边删一边改（最新内容在最近删除里）、墓碑压住
//   被删那一版和它的前身（旧文件夹里没删的那份也救不回来）、时间按原值比、几个版本换个顺序合出来一样；钟的写法读回来
//   （次数有上限）、另存那条的编号。
// - 仓库：改内容时钟走一格、改状态 / 顺序时记时刻且只往前走、墓碑（被删那一版的钟和状态时刻）落盘且不过期、这台电脑的
//   编号跟着硬件、从备份恢复换新编号、0.5.0 的库打开时加列不升版本、旧版本动过的行算本机改动、把一轮合并结果落下去
//   （本机之后又改了的跳过）、认出库被退回去了时换编号、永久删过又导进来的接着墓碑的钟数。
// 都在内存库里，不碰真实数据目录和偏好。随机的多台电脑模拟在 NoteSyncFuzzTests。

import Foundation
import Testing

@testable import KittyTools

struct NoteSyncTests {
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  /// 一版便签：时间按秒给（相对 t0）
  private func version(
    _ body: String, at seconds: TimeInterval, clock: [String: Int], id: String = "N",
    state: TimeInterval? = nil, deleted: TimeInterval? = nil, pinned: Bool = false,
    archived: Bool = false, revision: Int = 1
  ) -> Note {
    Note(
      id: id, body: body, createdAt: Self.t0, modifiedAt: Self.at(seconds), revision: revision,
      isArchived: archived, isPinned: pinned, deletedAt: deleted.map(Self.at),
      stateChangedAt: Self.at(state ?? seconds), orderChangedAt: Self.at(state ?? seconds),
      clock: clock)
  }

  // MARK: 内容

  /// 对面是在本机这一版之上改的（钟盖过本机的）：直接换，不留旧版；钟取两边的最大
  @Test func fastForwardKeepsNoCopy() {
    let local = version("本机", at: 10, clock: ["A": 1])
    let remote = version("对面改的", at: 20, clock: ["A": 1, "B": 1])
    let merge = NoteSync.merge(local: local, remotes: [remote], tombstone: nil, now: Self.at(100))
    #expect(merge.note?.body == "对面改的" && merge.copies.isEmpty && !merge.trashes)
    #expect(merge.note?.clock == ["A": 1, "B": 1])
    #expect(merge.note?.revision == 2, "这一轮变了：修订号往上走")
  }

  /// 对面那份是旧的（钟被本机盖过）：不理，原样给回本机那条
  @Test func staleRemoteIsIgnored() {
    let local = version("本机新的", at: 30, clock: ["A": 3, "B": 1])
    let stale = version("对面旧的", at: 50, clock: ["A": 1, "B": 1], state: 20)
    let merge = NoteSync.merge(local: local, remotes: [stale], tombstone: nil, now: Self.at(100))
    #expect(merge.note == local && merge.copies.isEmpty)
  }

  /// 两边各改了：「改于」后的赢，输的那版另存一条进「最近删除」；两台电脑各合一遍，赢的一样、另存的是同一条（编号相同）
  @Test func concurrentEditsKeepTheLoserOnce() throws {
    let mine = version("A 改的", at: 20, clock: ["A": 2, "B": 1])
    let theirs = version("B 改的", at: 30, clock: ["A": 1, "B": 2])
    let onA = NoteSync.merge(local: mine, remotes: [theirs], tombstone: nil, now: Self.at(100))
    let onB = NoteSync.merge(local: theirs, remotes: [mine], tombstone: nil, now: Self.at(200))
    #expect(onA.note?.body == "B 改的" && onB.note?.body == "B 改的")
    #expect(onA.note?.clock == ["A": 2, "B": 2] && onB.note?.clock == ["A": 2, "B": 2])
    let copy = try #require(onA.copies.first)
    #expect(onA.copies.count == 1 && onB.copies.map(\.id) == [copy.id])
    #expect(copy.body == "A 改的" && copy.deletedAt == Self.at(100) && copy.id != mine.id)
    #expect(copy.id == NoteSync.copyID(of: "N", content: NoteSync.contentHash(mine)))
    #expect(copy.clock.isEmpty, "另存的那条是新的一条，钟从空的起：两台存的一样")
    // 合完的钟盖过两边：B 下一轮看到 A 合出来的是快进，不再算冲突
    let again = NoteSync.merge(
      local: onB.note, remotes: [try #require(onA.note)], tombstone: nil, now: Self.at(300))
    #expect(again.copies.isEmpty && again.note == onB.note)
  }

  /// 慢了的钟：B 看过 A 的再改，「改于」反而更早——照样是快进（看的是钟，不是时间）
  @Test func slowClockStillFastForwards() {
    let local = version("A 的", at: 500, clock: ["A": 1])
    let remote = version("B 在 A 之上改的", at: 100, clock: ["A": 1, "B": 1])
    let merge = NoteSync.merge(local: local, remotes: [remote], tombstone: nil, now: Self.at(600))
    #expect(merge.note?.body == "B 在 A 之上改的" && merge.copies.isEmpty)
  }

  /// 钟一样、字不一样（0.5.0 改过、钟没跟着走；0.6.0 之前没钟的）：当两边都改了，走冲突那条路，不丢
  @Test func sameClockDifferentTextIsAConflict() {
    let local = version("0.5.0 里改过", at: 40, clock: [:])
    let remote = version("另一台的", at: 30, clock: [:])
    let merge = NoteSync.merge(local: local, remotes: [remote], tombstone: nil, now: Self.at(100))
    #expect(merge.note == local, "本机后改：赢，原样")
    #expect(merge.copies.map(\.body) == ["另一台的"])
    let same = version("一样的字", at: 40, clock: [:])
    let twin = version("一样的字", at: 10, clock: ["B": 1])
    let quiet = NoteSync.merge(local: same, remotes: [twin], tombstone: nil, now: Self.at(100))
    #expect(quiet.copies.isEmpty && quiet.note?.clock == ["B": 1], "字一样：只把钟并起来")
  }

  /// 三版：X 被 Z 盖过、Y 和两个都各改各的——只有 Y 另存（X 是 Z 的前身，不算输）；几个版本换着顺序合，结果一样
  @Test func coveredVersionsAreNotCopiedAndOrderDoesNotMatter() {
    let x = version("X", at: 10, clock: ["A": 1])
    let y = version("Y", at: 20, clock: ["B": 1])
    let z = version("Z", at: 30, clock: ["A": 2])
    let orders = [[x, y, z], [z, y, x], [y, x, z], [y, z, x]]
    let merges = orders.map {
      NoteSync.merge(
        local: $0[0], remotes: Array($0.dropFirst()), tombstone: nil, now: Self.at(100))
    }
    for merge in merges {
      #expect(merge.note?.body == "Z" && merge.note?.clock == ["A": 2, "B": 1])
      #expect(merge.copies.map(\.body) == ["Y"])
    }
  }

  /// 时间按原值比，比现在还晚也一样（钟快的那台赢同时的改动，直到别人的钟追上）：几台挑出来的赢家跟各台的现在无关；
  /// 存下去的就是原来的时刻
  @Test func timesCompareAsTheyAre() {
    let local = version("本机", at: 99, clock: ["A": 2])
    let ahead = version("钟快了的那台", at: 99_999, clock: ["B": 1])
    for now in [Self.at(100), Self.at(500)] {
      let merge = NoteSync.merge(local: local, remotes: [ahead], tombstone: nil, now: now)
      #expect(merge.note?.body == "钟快了的那台" && merge.note?.modifiedAt == Self.at(99_999))
      #expect(merge.copies.map(\.body) == ["本机"], "两边各改了：输的那版另存")
    }
    // 在它之上改的（钟盖过它）：不管时刻，直接是快进
    let onTop = version("看过它再改", at: 120, clock: ["A": 2, "B": 1])
    let forward = NoteSync.merge(local: onTop, remotes: [ahead], tombstone: nil, now: Self.at(130))
    #expect(forward.note?.body == "看过它再改" && forward.copies.isEmpty)
  }

  // MARK: 状态和删除

  /// 状态一组后改的赢，和内容各合各的：本机后改了内容、对面后固定了 → 内容是本机的、固定照对面的
  @Test func statesMergeByTheirOwnTime() {
    let local = version("本机改的字", at: 50, clock: ["A": 2, "B": 1], state: 10)
    let remote = version("旧字", at: 5, clock: ["A": 1, "B": 1], state: 40, pinned: true)
    let merge = NoteSync.merge(local: local, remotes: [remote], tombstone: nil, now: Self.at(100))
    #expect(merge.note?.body == "本机改的字" && merge.note?.isPinned == true)
    #expect(merge.note?.stateChangedAt == Self.at(40) && merge.note?.modifiedAt == Self.at(50))
  }

  /// 一边删、一边改：最新的内容在「最近删除」里（A4）；本机那条原来没删、合完删了要记 trashes（一轮里数它）
  @Test func deleteMeetsEditKeepsTheNewestText() {
    let edited = version("删之后又改了", at: 60, clock: ["A": 2], state: 10)
    let deleted = version("原来的", at: 5, clock: ["A": 1], state: 50, deleted: 50)
    let onEditor = NoteSync.merge(
      local: edited, remotes: [deleted], tombstone: nil, now: Self.at(100))
    #expect(onEditor.note?.body == "删之后又改了" && onEditor.note?.deletedAt == Self.at(50))
    #expect(onEditor.trashes && onEditor.copies.isEmpty)
    let onDeleter = NoteSync.merge(
      local: deleted, remotes: [edited], tombstone: nil, now: Self.at(100))
    #expect(onDeleter.note?.body == "删之后又改了" && onDeleter.note?.deletedAt == Self.at(50))
    #expect(!onDeleter.trashes)
  }

  /// 墓碑压住被删那一版和它的前身（钟每格不超过、状态不晚于），在不在最近删除里都一样：本机的真删、对面那份旧的不理——
  /// 一台合上盖子的、不用了留下的旧文件夹里那份没删的，也救不回来。删了之后又改过（钟超过）、放回过（状态晚于）的压不住，
  /// 照常合（宁可多一条）
  @Test func tombstonesBuryTheErasedVersionAndItsAncestors() {
    let tombstone = NoteSync.Tombstone(clock: ["A": 1], state: Self.at(30))
    func merge(_ local: Note?, _ remotes: [Note]) -> NoteSync.Merge {
      NoteSync.merge(local: local, remotes: remotes, tombstone: tombstone, now: Self.at(100))
    }
    let trashed = version("在最近删除里", at: 10, clock: ["A": 1], state: 20, deleted: 20)
    #expect(merge(trashed, []).note == nil, "本机那条压住了：真删")
    let stale = version("旧文件夹里没删的那份", at: 10, clock: ["A": 1], state: 5)
    #expect(merge(stale, []).note == nil)
    #expect(merge(nil, [stale]).note == nil, "本机永久删过：别人那份旧的救不回来")
    let edited = version("删了之后又改", at: 40, clock: ["A": 2], state: 20, deleted: 20)
    #expect(merge(edited, []).note == edited)
    let restored = version("对面放回了", at: 10, clock: ["A": 1], state: 40)
    #expect(merge(nil, [restored]).note?.body == "对面放回了")
    // 本机压住了、但对面还有一份压不住的：照常合，不删
    #expect(merge(trashed, [restored]).note?.deletedAt == nil)
    // 救回来的那条钟里并上墓碑的：本机那一格不退回去（本机删的时候是 A:5，对面那份只到 A:3）
    let deeper = NoteSync.Tombstone(clock: ["A": 5], state: Self.at(30))
    let concurrent = version("对面删前改过的", at: 25, clock: ["A": 3, "B": 1], state: 25)
    let revived = NoteSync.merge(
      local: nil, remotes: [concurrent], tombstone: deeper, now: Self.at(100))
    #expect(revived.note?.body == "对面删前改过的" && revived.note?.clock == ["A": 5, "B": 1])
    // 几台的墓碑并起来：钟每格取最大、时刻取最晚
    let other = NoteSync.Tombstone(clock: ["A": 0, "B": 2], state: Self.at(10))
    #expect(
      tombstone.merged(with: other)
        == NoteSync.Tombstone(clock: ["A": 1, "B": 2], state: Self.at(30)))
  }

  /// 顺序单独后改的赢：一台整列重排（只动顺序），另一台同时删了这条 → 删除不被翻回去，顺序照重排的
  @Test func orderMergesOnItsOwn() {
    var moved = version("一条", at: 5, clock: ["A": 1], state: 5)
    moved.order = 3
    moved.orderChangedAt = Self.at(60)
    let deleted = version("一条", at: 5, clock: ["A": 1], state: 50, deleted: 50)
    let merge = NoteSync.merge(local: moved, remotes: [deleted], tombstone: nil, now: Self.at(100))
    #expect(merge.note?.deletedAt == Self.at(50) && merge.note?.order == 3)
    #expect(merge.note?.orderChangedAt == Self.at(60) && merge.trashes)
  }

  /// 本机没有的：合出来就是新来的（不带 trashes）；都没有：nil
  @Test func newNotesComeInAndNothingIsNothing() {
    let remote = version("新来的", at: 10, clock: ["B": 1], revision: 7)
    let merge = NoteSync.merge(local: nil, remotes: [remote], tombstone: nil, now: Self.at(100))
    var expected = remote
    expected.revision = 0
    #expect(merge.note == expected && !merge.trashes, "修订号是本机的账：新来的从 0 起")
    #expect(NoteSync.merge(local: nil, remotes: [], tombstone: nil, now: Self.at(100)).note == nil)
  }

  // MARK: 写法

  @Test func clockTextRoundTripsAndSkipsBrokenCells() {
    let clock = ["B-2": 5, "A1": 3]
    #expect(NoteSync.text(of: clock) == "A1:3,B-2:5")
    #expect(NoteSync.clock(text: NoteSync.text(of: clock)) == clock)
    #expect(NoteSync.clock(text: "") == [:])
    #expect(NoteSync.clock(text: "A:2,坏:1,B:0,C:-1,D:x,:3,E:1:2,F:4") == ["A": 2, "F": 4])
    #expect(NoteSync.clock(text: "A:2,A:5") == ["A": 5])
    // 次数有上限：文件夹里读进来的大得离谱的跳过（不然本机再 +1 就溢出）
    #expect(
      NoteSync.clock(text: "A:\(NoteSync.maxCount),B:\(NoteSync.maxCount + 1),C:\(Int.max)") == [
        "A": NoteSync.maxCount
      ])
  }

  @Test func copyIDIsStableAndAUUID() throws {
    let id = NoteSync.copyID(of: "N", content: "abc")
    #expect(id == NoteSync.copyID(of: "N", content: "abc"))
    #expect(id != NoteSync.copyID(of: "N", content: "abd"))
    #expect(id != NoteSync.copyID(of: "M", content: "abc"))
    let uuid = try #require(UUID(uuidString: id))
    #expect(uuid.uuidString == id)
    #expect(id.dropFirst(14).first == "5", "第 5 版的写法")
  }

  // MARK: 仓库

  /// 改内容：「改于」、钟自己那一格 +1，状态 / 顺序时刻不动；改状态：状态时刻记下（同一刻连改两次也往前走 1 毫秒）；
  /// 挪顺序只动顺序时刻；钟和「改于」不动
  @Test func editsAdvanceTheClockAndStateTime() throws {
    let store = try NoteStore(db: Database(path: ":memory:"), host: "mac-a")
    let me = store.deviceID
    let note = store.create(body: "一", now: Self.at(0))
    let other = store.create(body: "二", now: Self.at(0))
    #expect(note.clock == [me: 1] && note.stateChangedAt == Self.at(0))
    #expect(note.orderChangedAt == Self.at(0))
    store.setBody("一二", of: note.id, now: Self.at(5))
    store.setColor(3, of: note.id, now: Self.at(6))
    var now = try #require(store.note(note.id))
    #expect(now.clock == [me: 3] && now.modifiedAt == Self.at(6))
    #expect(now.stateChangedAt == Self.at(0) && now.orderChangedAt == Self.at(0))
    store.setPinned(true, of: note.id, now: Self.at(10))
    store.setPinned(false, of: note.id, now: Self.at(10))
    now = try #require(store.note(note.id))
    #expect(now.stateChangedAt == Note.stamp(Self.at(10.001)), "同一刻又改：往前走 1 毫秒")
    #expect(now.clock == [me: 3] && now.modifiedAt == Self.at(6))
    #expect(now.orderChangedAt == Self.at(0), "固定不算挪顺序")
    store.delete(note.id, now: Self.at(5))
    #expect(
      store.note(note.id)?.stateChangedAt == Note.stamp(Self.at(10.002)), "钟往回拨了：照样往前走")
    store.create(body: "三", now: Self.at(0))
    store.move(other.id, to: 0, now: Self.at(20))
    let moved = try #require(store.note(other.id))
    #expect(moved.orderChangedAt == Self.at(20) && moved.stateChangedAt == Self.at(0))
    #expect(try NoteStore(db: Database(path: ":memory:"), host: "mac-b").deviceID != me)
  }

  /// 永久删除留墓碑（被删那一版的钟和状态时刻）：落盘、再开读回来；清空最近删除、到期清理同样；墓碑不过期；
  /// 又有了（导入）墓碑拿掉
  @Test func tombstonesArePersistedAndKept() throws {
    let db = try Database(path: ":memory:")
    let store = try NoteStore(db: db, host: "mac")
    let me = store.deviceID
    let first = store.create(body: "一", now: Self.at(0))
    let second = store.create(body: "二", now: Self.at(0))
    let third = store.create(body: "三", now: Self.at(0))
    store.erase(first.id, now: Self.at(10))
    store.delete(second.id, now: Self.at(20))
    #expect(store.emptyTrash(now: Self.at(30)) == 1)
    store.delete(third.id, now: Self.at(40))
    #expect(store.purgeExpired(now: Self.at(40 + 31 * 86_400)) == 1)
    #expect(
      store.erased == [
        first.id: NoteSync.Tombstone(clock: [me: 1], state: Self.at(0)),
        second.id: NoteSync.Tombstone(clock: [me: 1], state: Self.at(20)),
        third.id: NoteSync.Tombstone(clock: [me: 1], state: Self.at(40)),
      ])
    let reopened = try NoteStore(db: db, host: "mac")
    #expect(reopened.erased == store.erased)
    reopened.purgeExpired(now: Self.at(400 * 86_400))
    #expect(reopened.erased.count == 3, "墓碑不过期")
    let entry = SettingsArchive.NoteEntry(
      id: second.id, title: "", body: "导回来了", color: 0, createdAt: 0,
      modifiedAt: Note.milliseconds(Self.at(40)), revision: 1, archived: false, pinned: false,
      order: 0)
    reopened.adopt([entry], now: Self.at(50))
    #expect(reopened.erased[second.id] == nil)
    #expect(try NoteStore(db: db, host: "mac").erased[second.id] == nil)
  }

  /// 这台电脑的编号：同一台再开是同一个；硬件编号变了（库被搬到了另一台 Mac）换一个新的；读不到硬件编号时不换
  @Test func deviceIDFollowsTheMac() throws {
    let db = try Database(path: ":memory:")
    let first = try NoteStore(db: db, host: "mac-a").deviceID
    #expect(try NoteStore(db: db, host: "mac-a").deviceID == first)
    let moved = try NoteStore(db: db, host: "mac-b").deviceID
    #expect(moved != first && UUID(uuidString: moved) != nil)
    #expect(try NoteStore(db: db, host: nil).deviceID == moved)
    #expect(try NoteStore(db: db, host: "mac-b").deviceID == moved)
  }

  /// 0.5.0 建的库：打开时加上四列三张表、版本不升；0.6.0 之前的行（没钟）算本机的一次改动：钟补一格、状态和顺序时刻
  /// 往前走一毫秒、修订号 +1（同步时和别的电脑同时改的走另存那条路，不被有钟的版本悄悄盖掉）。0.5.0 照旧的写法改了
  /// 这一条：新加的列不被清掉，再开时认出来（修订号和 written_revision 对不上），同样补一格。0.6.0 自己写的行再开不变
  @Test func olderVersionsEditsCountAsLocalEdits() throws {
    let db = try Database(path: ":memory:")
    try db.execute(
      """
      CREATE TABLE notes(
        id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
        color INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
        sort_order REAL NOT NULL DEFAULT 0, deleted_at INTEGER)
      """)
    try db.execute("PRAGMA user_version = 1")
    let oldUpsert = """
      INSERT INTO notes(id, title, body, color, created_at, modified_at, revision, archived,
        pinned, sort_order, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title = excluded.title, body = excluded.body,
        color = excluded.color, created_at = excluded.created_at,
        modified_at = excluded.modified_at, revision = excluded.revision,
        archived = excluded.archived, pinned = excluded.pinned, sort_order = excluded.sort_order,
        deleted_at = excluded.deleted_at
      """
    let id = UUID().uuidString
    let modified = Note.milliseconds(Self.at(1))
    try db.execute(oldUpsert, [id, "", "旧的", 2, 0, modified, 1, false, false, 0.0, nil])
    let store = try NoteStore(db: db, host: "mac")
    let me = store.deviceID
    let opened = try #require(store.note(id))
    #expect(opened.clock == [me: 1] && opened.revision == 2)
    #expect(opened.stateChangedAt == Note.stamp(Self.at(1.001)))
    #expect(opened.orderChangedAt == Note.stamp(Self.at(1.001)))
    let columns = try db.query("PRAGMA table_info(notes)") { $0.text(1) }
    #expect(
      Set(columns.compactMap { $0 }).isSuperset(of: [
        "state_changed_at", "clock", "order_changed_at", "written_revision",
      ]))
    let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) }
    #expect(Set(tables.compactMap { $0 }).isSuperset(of: ["note_erased", "note_meta"]))
    #expect(try db.query("PRAGMA user_version") { $0.int(0) } == [1])
    store.flush()
    // 0.6.0 自己写过的再开：不变（不会每次打开都补一格）
    #expect(try NoteStore(db: db, host: "mac").note(id) == store.note(id))
    store.setBody("新版本改的", of: id, now: Self.at(10))
    store.setPinned(true, of: id, now: Self.at(11))
    store.flush()
    // 0.5.0 又改了一下这一条：只写原来那几列，修订号往上走
    try db.execute(oldUpsert, [id, "", "0.5.0 又改了", 2, 0, modified, 9, false, true, 0.0, nil])
    let back = try #require(try NoteStore(db: db, host: "mac").note(id))
    #expect(back.body == "0.5.0 又改了" && back.clock == [me: 3] && back.revision == 10)
    #expect(back.stateChangedAt == Note.stamp(Self.at(11.001)))
  }

  /// 从备份恢复：换上来的那份库忘掉电脑编号（版本钟的计数退回去了，再用原来的编号会和恢复前发出去的撞上）；再开得到一个
  /// 新编号
  @Test func restoredLibraryGetsANewDevice() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-notes-sync-restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "notes.sqlite3")
    let before = try NoteStore(db: Database(path: url.path, wal: false), host: "mac").deviceID
    NoteStore.forgetDevice(inDatabaseAt: url)
    let after = try NoteStore(db: Database(path: url.path, wal: false), host: "mac")
    #expect(after.deviceID != before)
    // 更早的备份没有这张表：删不成不算错
    let bare = folder.appending(path: "bare.sqlite3")
    do { _ = try Database(path: bare.path, wal: false) }
    NoteStore.forgetDevice(inDatabaseAt: bare)
  }

  /// 把一轮合并结果落下去：换、加（墓碑拿掉）、真删（墓碑并上读到的那块）、输的那版另存（已经有了的、本机或这一轮有墓碑的
  /// 不再加）；换上的不另 +1；合的时候本机那条的修订号对不上（之后本机又改了）就跳过；落盘、再开一样
  @Test func applySyncReplacesAddsErasesAndKeepsCopiesOnce() throws {
    let db = try Database(path: ":memory:")
    let store = try NoteStore(db: db, host: "mac")
    let kept = store.create(body: "要被换的", now: Self.at(0))
    let doomed = store.create(body: "对面永久删了", now: Self.at(0))
    store.delete(doomed.id, now: Self.at(5))
    let gone = store.create(body: "本机永久删过", now: Self.at(0))
    store.erase(gone.id, now: Self.at(6))
    let local = try #require(store.note(kept.id))
    let doomedNow = try #require(store.note(doomed.id))
    var replaced = local
    replaced.body = "对面改的"
    replaced.clock = ["B": 1, store.deviceID: 1]
    replaced.revision = 7
    let incoming = version("新来的", at: 3, clock: ["B": 1], id: UUID().uuidString)
    let copy = version("输了的", at: 2, clock: ["B": 2], id: UUID().uuidString, deleted: 9)
    let buriedCopy = version("永久删过的那份", at: 2, clock: ["B": 3], id: gone.id, deleted: 9)
    let elsewhere = version("别处永久删过的另存", at: 2, clock: ["B": 3], id: UUID().uuidString)
    let remoteTomb = NoteSync.Tombstone(clock: ["B": 5], state: Self.at(8))
    let saved = store.applySync(
      [
        kept.id: NoteSync.Merge(
          note: replaced, copies: [copy, buriedCopy, elsewhere], base: local.revision),
        doomed.id: NoteSync.Merge(note: nil, base: doomedNow.revision),
        incoming.id: NoteSync.Merge(note: incoming),
      ], tombstones: [doomed.id: remoteTomb, elsewhere.id: remoteTomb])
    #expect(saved)
    #expect(store.note(kept.id) == replaced, "照合出来的放，修订号不另 +1")
    #expect(store.note(doomed.id) == nil)
    #expect(
      store.erased[doomed.id]
        == NoteSync.Tombstone(
          clock: doomedNow.clock.merging(["B": 5]) { max($0, $1) }, state: Self.at(8)))
    #expect(store.note(incoming.id) == incoming && store.note(copy.id) == copy)
    #expect(store.note(gone.id) == nil, "本机永久删过的那份不加回来")
    #expect(store.note(elsewhere.id) == nil, "这一轮读到它的墓碑：不加")
    let reopened = try NoteStore(db: db, host: "mac")
    #expect(reopened.notes.sorted { $0.id < $1.id } == store.notes.sorted { $0.id < $1.id })
    #expect(reopened.erased == store.erased)
    // 再落一遍同样的另存：不会多出第二条
    reopened.applySync(
      [kept.id: NoteSync.Merge(note: replaced, copies: [copy], base: replaced.revision)],
      tombstones: [:])
    #expect(reopened.notes.filter { $0.body == "输了的" }.count == 1)
    // 合完之后本机又改了：这一条跳过（不拿旧的盖它），别的照落
    reopened.setBody("刚打的字", of: kept.id, now: Self.at(80))
    var stale = replaced
    stale.body = "合的时候的样子"
    let newcomer = version("另一条新来的", at: 3, clock: ["B": 1], id: UUID().uuidString)
    reopened.applySync(
      [
        kept.id: NoteSync.Merge(note: stale, base: replaced.revision),
        newcomer.id: NoteSync.Merge(note: newcomer),
      ], tombstones: [:])
    #expect(reopened.note(kept.id)?.body == "刚打的字" && reopened.note(newcomer.id) == newcomer)
    // 本机永久删过的那条，同步加回来（对面放回了）：墓碑拿掉
    let back = version("对面放回了", at: 70, clock: ["B": 4], id: gone.id)
    reopened.applySync([gone.id: NoteSync.Merge(note: back)], tombstones: [:])
    #expect(reopened.note(gone.id) == back && reopened.erased[gone.id] == nil)
  }

  /// 认出库被退回去了：换一个新编号（记进库），给那几条各记一笔新编号的改动（钟 +1、修订号 +1、落盘）；别的不动
  @Test func switchDeviceBumpsTheNamedNotes() throws {
    let db = try Database(path: ":memory:")
    let store = try NoteStore(db: db, host: "mac")
    let old = store.deviceID
    let first = store.create(body: "一", now: Self.at(0))
    let second = store.create(body: "二", now: Self.at(0))
    #expect(try store.switchDevice(bumping: [first.id]))
    let new = store.deviceID
    #expect(new != old && UUID(uuidString: new) != nil)
    #expect(store.note(first.id)?.clock == [old: 1, new: 1] && store.note(first.id)?.revision == 1)
    #expect(store.note(second.id) == second)
    let reopened = try NoteStore(db: db, host: "mac")
    #expect(reopened.deviceID == new && reopened.note(first.id) == store.note(first.id))
  }

  /// 永久删过、又导进来同一条：钟接着墓碑里的往上数（从 1 重新数会被别处留着的那版当成被盖过）
  @Test func adoptingAnErasedNoteContinuesItsClock() throws {
    let store = try NoteStore(db: Database(path: ":memory:"), host: "mac")
    let me = store.deviceID
    let note = store.create(body: "一", now: Self.at(0))
    store.setBody("一二三", of: note.id, now: Self.at(1))
    store.setBody("一二三四", of: note.id, now: Self.at(2))
    store.erase(note.id, now: Self.at(3))
    let entry = SettingsArchive.NoteEntry(
      id: note.id, title: "", body: "导回来", color: 0, createdAt: 0,
      modifiedAt: Note.milliseconds(Self.at(4)), revision: 1, archived: false, pinned: false,
      order: 0)
    store.adopt([entry], now: Self.at(5))
    let adopted = try #require(store.note(note.id)?.clock)
    #expect(adopted == [me: 4])
    // 别处还留着删之前的那版（{本机: 3}）：导进来的这版盖过它，不被当成旧的扔掉
    #expect(NoteSync.precedes([me: 3], adopted))
  }

}
