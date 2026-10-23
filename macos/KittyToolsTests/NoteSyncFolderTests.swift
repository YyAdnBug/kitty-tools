// 便签同步文件夹（Notes/NoteSyncFolder.swift，便签未来计划 A1 / A5）：便签文件往返一个字不差（导出那套键也认得）、认不出的
// 和被动过的文件（哈希对不上、写了却解不出来的键、重复的键、太大、钟太长）给 nil、设置里「导入…」认得出同步文件、墓碑文件
// 往返；一轮：不是那个文件夹 / 更新的格式 / 谁的墓碑读不出来就整轮不合、读不出来的那一版不算、自己子文件夹里本机没有的合回来、
// 只交出变了的、数要放进最近删除的条数和刹车；写出去：和自己文件夹里不一样的重写（读不出来的也重写）、该删的、墓碑、图片
// 传上去拿下来；认出库被退回去了（哪几条）。全是纯函数，不碰文件系统。经过文件夹的随机测试在 NoteSyncFuzzTests。

import Foundation
import Testing

@testable import KittyTools

struct NoteSyncFolderTests {
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  private func note(
    _ body: String, id: String = UUID().uuidString, at seconds: TimeInterval = 10,
    clock: [String: Int] = ["A": 1], deleted: TimeInterval? = nil, revision: Int = 1
  ) -> Note {
    Note(
      id: id, body: body, createdAt: Self.t0, modifiedAt: Self.at(seconds), revision: revision,
      deletedAt: deleted.map(Self.at), stateChangedAt: Self.at(deleted ?? seconds),
      orderChangedAt: Self.at(seconds), clock: clock)
  }

  private func folder(_ devices: [String: NoteSyncFolder.Device]) -> NoteSyncFolder.Folder {
    NoteSyncFolder.Folder(marker: NoteSyncFolder.Marker(library: "L"), devices: devices)
  }

  // MARK: 便签文件

  /// 往返一个字不差：只有空格的标题、带 `---` 的行、开头的空行、行尾的空白、\r、U+2028、自定义纸色、删除时刻、钟、小数的顺序
  @Test func noteFilesRoundTripExactly() throws {
    var tricky = note(
      "\n\n---\n第一行 \r\n---\u{2028}☐ 待办\n![image](kitty-note-image://6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F.png)\n\n",
      deleted: 30, revision: 42)
    tricky.title = "  "
    tricky.color = Note.custom(rgb: 0xC2DFF8)
    tricky.isArchived = true
    tricky.isPinned = true
    tricky.order = -0.1 + 1e-9
    tricky.clock = ["A": 3, "B-2": 7]
    tricky.createdAt = Note.date(milliseconds: 1_700_000_000_123)
    var plain = note("一行")
    plain.title = "标题：带「引号」\"和\\反斜杠\"\n换行"
    for original in [tricky, plain, note(""), note("x", clock: [:])] {
      let text = NoteSyncFolder.text(of: original)
      let back = try #require(NoteSyncFolder.note(from: text, fileID: original.id))
      #expect(back == original)
      #expect(NoteSyncFolder.isSyncFile(text))
    }
    // 设置里「导入…」的头也读得懂（它认出是同步文件就跳过，见 MarkdownImport）
    let header = try #require(NoteMarkdownFiles.parseHeader(NoteSyncFolder.text(of: tricky)))
    #expect(header.id == tricky.id && header.title == "  " && header.archived && header.pinned)
    #expect(Note.color(preset: header.color, tint: header.tint) == tricky.color)
    #expect(header.order == tricky.order)
    #expect(!NoteSyncFolder.isSyncFile(NoteMarkdownFiles.header(for: tricky) + "\n\n正文"))
  }

  /// 认不出、被动过的给 nil：导出的文件、编号和文件名对不上、头没收尾、正文补了个换行（哈希对不上）、标题写成不带引号的、
  /// 颜色超出范围、删除时刻写坏了、同一个键写了两遍、钟太多格、整个文件太大
  @Test func foreignOrTamperedFilesAreNotNotes() {
    let good = note("正文")
    let text = NoteSyncFolder.text(of: good)
    func reads(_ text: String) -> Bool { NoteSyncFolder.note(from: text, fileID: good.id) != nil }
    #expect(reads(text))
    #expect(NoteSyncFolder.note(from: text, fileID: UUID().uuidString) == nil, "编号对不上")
    #expect(!reads(NoteMarkdownFiles.header(for: good) + "\n\n正文"))
    #expect(!reads("---\nkitty-note: \(good.id)\nsync-clock: A:1\n"))
    #expect(!reads(text + "\n"), "编辑器补了一个换行")
    #expect(!reads(text.replacingOccurrences(of: "正文", with: "正")), "读到一半")
    #expect(
      !reads(text.replacingOccurrences(of: "---\nkitty-note", with: "---\ntitle: 没引号\nkitty-note")))
    #expect(!reads(text.replacingOccurrences(of: "color: 0", with: "color: 9")))
    #expect(
      !reads(text.replacingOccurrences(of: "sync-clock:", with: "sync-deleted: 坏\nsync-clock:")))
    #expect(
      !reads(text.replacingOccurrences(of: "pinned: false", with: "pinned: false\npinned: true")))
    #expect(!reads(text.replacingOccurrences(of: "pinned: false", with: "pinned: 否")))
    let cells = (0..<1100).map { "D\($0):1" }.joined(separator: ",")
    #expect(!reads(text.replacingOccurrences(of: "sync-clock: A:1", with: "sync-clock: \(cells)")))
    #expect(!reads(text + String(repeating: "字", count: Note.maxBodyBytes / 3 + 30_000)))
    #expect(!reads("随便什么"))
  }

  @Test func fileNamesAreIDs() {
    let id = UUID().uuidString
    #expect(NoteSyncFolder.fileName(of: id) == "\(id).md")
    #expect(NoteSyncFolder.noteID(ofFileNamed: "\(id).md") == id)
    #expect(NoteSyncFolder.noteID(ofFileNamed: "\(id.lowercased()).md") == id)
    #expect(NoteSyncFolder.noteID(ofFileNamed: "\(id).txt") == nil)
    #expect(NoteSyncFolder.noteID(ofFileNamed: "笔记.md") == nil)
  }

  /// 墓碑文件往返；坏的读不出来、格式更新的说更新；编号不是 UUID 的条目跳过；同一个编号大小写写了两份并起来
  @Test func tombstoneFilesRoundTrip() throws {
    let id = UUID().uuidString
    let tombstones = [id: NoteSync.Tombstone(clock: ["A": 2, "B": 1], state: Self.at(5))]
    #expect(
      NoteSyncFolder.tombstones(from: NoteSyncFolder.data(of: tombstones)) == .read(tombstones))
    #expect(NoteSyncFolder.tombstones(from: NoteSyncFolder.data(of: [:])) == .read([:]))
    #expect(NoteSyncFolder.tombstones(from: Data("坏了".utf8)) == .unreadable)
    let newer = #"{"format": 99, "erased": {}}"#
    #expect(NoteSyncFolder.tombstones(from: Data(newer.utf8)) == .newer)
    let odd = #"{"format": 1, "erased": {"不是编号": {"clock": "A:1", "state": 5}}}"#
    #expect(NoteSyncFolder.tombstones(from: Data(odd.utf8)) == .read([:]))
    let twice = """
      {"format": 1, "erased": {"\(id)": {"clock": "A:2", "state": 5},
        "\(id.lowercased())": {"clock": "B:3", "state": 9}}}
      """
    #expect(
      NoteSyncFolder.tombstones(from: Data(twice.utf8))
        == .read([
          id: NoteSync.Tombstone(
            clock: ["A": 2, "B": 3], state: Date(timeIntervalSince1970: 0.009))
        ]))
  }

  // MARK: 一轮

  /// 不是那个文件夹（没标记、编号不对）、更新的格式（标记或墓碑文件）、谁的墓碑读不出来（带上是哪台）：整轮不合
  @Test func roundStops() {
    var folder = NoteSyncFolder.Folder()
    func round() -> Result<NoteSyncFolder.Round, NoteSyncFolder.Stop> {
      NoteSyncFolder.round(
        local: [note("本机")], erased: [:], folder: folder, library: "L", now: Self.at(100))
    }
    #expect(round() == .failure(.notTheFolder))
    folder.marker = NoteSyncFolder.Marker(library: "别的")
    #expect(round() == .failure(.notTheFolder))
    folder.marker = NoteSyncFolder.Marker(format: 2, library: "L")
    #expect(round() == .failure(.newerFormat))
    folder.marker = NoteSyncFolder.Marker(library: "L")
    folder.devices["B"] = NoteSyncFolder.Device(erased: .unreadable)
    #expect(round() == .failure(.unreadableTombstones(device: "B")))
    folder.devices["B"] = NoteSyncFolder.Device(erased: .newer)
    #expect(round() == .failure(.newerFormat))
    folder.devices["B"] = NoteSyncFolder.Device()
    #expect((try? round().get()) != nil)
  }

  /// 合一轮：别人的新来、对面改了的换上；自己子文件夹里本机没有、也没墓碑的合回来；读不出来的那一版不算（本机的照旧）；
  /// 没变的不交出来
  @Test func roundMergesEveryoneAndSkipsUnreadableVersions() throws {
    let same = note("没变的", clock: ["A": 1])
    let changed = note("本机旧的", clock: ["A": 1])
    var theirs = changed
    theirs.body = "对面改的"
    theirs.clock = ["A": 1, "B": 1]
    theirs.modifiedAt = Self.at(20)
    let incoming = note("新来的", clock: ["B": 1])
    let blocked = note("这条那边没下载完", clock: ["A": 1])
    let orphan = note("自己文件夹里有、本机没有（0.5.0 清掉了）", clock: ["A": 2])
    let round = try NoteSyncFolder.round(
      local: [same, changed, blocked], erased: [:],
      folder: folder([
        "A": NoteSyncFolder.Device(notes: [same.id: same, orphan.id: orphan]),
        "B": NoteSyncFolder.Device(
          notes: [same.id: same, changed.id: theirs, incoming.id: incoming],
          unreadable: [blocked.id]),
      ]), library: "L", now: Self.at(100)
    ).get()
    #expect(Set(round.merges.keys) == [changed.id, incoming.id, orphan.id])
    #expect(round.merges[changed.id]?.note?.body == "对面改的")
    #expect(round.merges[incoming.id]?.note?.body == "新来的")
    #expect(round.merges[orphan.id]?.note?.body == orphan.body)
    #expect(round.skipped == [blocked.id] && round.merges[blocked.id] == nil)
    #expect(round.trashing == 0 && round.alive == 3 && !round.brakes)
  }

  /// 数要放进最近删除（或真删）的条数：对面删了的、墓碑压住的（本机没删的那份）；本机原来就在最近删除里的不算
  @Test func roundCountsTrashing() throws {
    let deletedThere = note("对面删了", clock: ["A": 1])
    var theirs = deletedThere
    theirs.deletedAt = Self.at(50)
    theirs.stateChangedAt = Self.at(50)
    let buried = note("对面永久删了", clock: ["A": 1])
    let alreadyTrashed = note("本机早就删了", clock: ["A": 1], deleted: 5)
    var theirsToo = alreadyTrashed
    theirsToo.deletedAt = Self.at(60)
    theirsToo.stateChangedAt = Self.at(60)
    let round = try NoteSyncFolder.round(
      local: [deletedThere, buried, alreadyTrashed], erased: [:],
      folder: folder([
        "B": NoteSyncFolder.Device(
          notes: [deletedThere.id: theirs, alreadyTrashed.id: theirsToo],
          erased: .read([buried.id: NoteSync.Tombstone(clock: ["A": 1], state: Self.at(70))]))
      ]), library: "L", now: Self.at(100)
    ).get()
    #expect(round.trashing == 2 && round.alive == 2)
    #expect(round.merges[buried.id]?.note == nil)
    #expect(round.tombstones[buried.id] != nil)
  }

  /// 刹车：超过 20 条；或者至少 5 条、超过三成
  @Test func brakes() {
    #expect(NoteSyncFolder.brakes(trashing: 21, alive: 1000))
    #expect(!NoteSyncFolder.brakes(trashing: 20, alive: 1000))
    #expect(!NoteSyncFolder.brakes(trashing: 4, alive: 5), "不到 5 条不按三成算")
    #expect(NoteSyncFolder.brakes(trashing: 5, alive: 10))
    #expect(!NoteSyncFolder.brakes(trashing: 6, alive: 20), "正好三成不算")
    #expect(NoteSyncFolder.brakes(trashing: 7, alive: 20))
    #expect(!NoteSyncFolder.brakes(trashing: 0, alive: 0))
  }

  // MARK: 写出去

  /// 和自己文件夹里那一版不一样的、没有的、读不出来的重写；本机已经没有的删；墓碑变了重写；正文里的图片：文件夹没有的传、
  /// 本机没有的拿
  @Test func publishWritesDeletesAndMovesImages() {
    let image = NoteImages.Image(id: UUID(), ext: "png", width: 240)
    let other = NoteImages.Image(id: UUID(), ext: "jpg", width: nil)
    let synced = note("没变的", revision: 3)
    let edited = note("改过的", revision: 5)
    var stale = edited
    stale.revision = 4
    let missing = note("文件被人删了", revision: 2)
    let broken = note("自己那份写坏了", revision: 2)
    let pictured = note(
      "图 \(NoteImages.token(image)) 和 \(NoteImages.token(other))", revision: 1)
    let goneID = UUID().uuidString
    // 本机没有、也没墓碑、读不出来（还在下载 / 库被退回去了）：可能是唯一的一份，不删
    let strayID = UUID().uuidString
    let own = NoteSyncFolder.Device(
      notes: [synced.id: synced, edited.id: stale, goneID: note("永久删了的", id: goneID)],
      unreadable: [broken.id, strayID])
    let tombstones = [goneID: NoteSync.Tombstone(clock: ["A": 1], state: Self.at(9))]
    let plan = NoteSyncFolder.publish(
      local: [synced, edited, missing, broken, pictured], erased: tombstones, own: own,
      localImages: ["\(image.id.uuidString).png"], folderImages: ["\(other.id.uuidString).jpg"])
    #expect(Set(plan.writes.map(\.id)) == [edited.id, missing.id, broken.id, pictured.id])
    #expect(plan.deletes == [goneID] && plan.erased == tombstones)
    #expect(plan.uploads == [NoteImages.Image(id: image.id, ext: "png", width: nil)])
    #expect(plan.downloads == [other])
    // 都一样：什么都不用做
    let calm = NoteSyncFolder.publish(
      local: [synced], erased: [:], own: NoteSyncFolder.Device(notes: [synced.id: synced]),
      localImages: [], folderImages: [])
    #expect(calm.isEmpty)
    // 自己的子文件夹还没有（第一次）：全写、墓碑文件也写；墓碑文件读不出来：重写
    let first = NoteSyncFolder.publish(
      local: [synced], erased: [:], own: nil, localImages: [], folderImages: [])
    #expect(first.writes.map(\.id) == [synced.id] && first.erased == [:])
    let rewrite = NoteSyncFolder.publish(
      local: [], erased: [:], own: NoteSyncFolder.Device(erased: .unreadable), localImages: [],
      folderImages: [])
    #expect(rewrite.erased == [:])
  }

  /// 库被退回去了：哪一版（自己的、别人的）里本机那一格的钟比库里大，就是那几条；别的电脑那一格大不算；本机没有的不算
  @Test func regressionIsDetected() {
    let current = note("现在的", clock: ["A": 3, "B": 2])
    var ahead = current
    ahead.clock = ["A": 5, "B": 2]
    var otherAhead = current
    otherAhead.clock = ["A": 3, "B": 9]
    var carried = current
    carried.clock = ["A": 4, "B": 3]
    let vanished = note("后来建的", clock: ["A": 1])
    func regressed(_ devices: [String: NoteSyncFolder.Device]) -> Set<String> {
      NoteSyncFolder.regressed(local: [current], folder: folder(devices), device: "A")
    }
    #expect(regressed(["A": NoteSyncFolder.Device(notes: [current.id: current])]).isEmpty)
    #expect(regressed(["A": NoteSyncFolder.Device(notes: [current.id: otherAhead])]).isEmpty)
    #expect(regressed(["A": NoteSyncFolder.Device(notes: [current.id: ahead])]) == [current.id])
    #expect(
      regressed(["B": NoteSyncFolder.Device(notes: [current.id: carried])]) == [current.id],
      "自己的文件读不出来时，别人那份里也带着本机那一格")
    #expect(regressed(["A": NoteSyncFolder.Device(notes: [vanished.id: vanished])]).isEmpty)
  }
}
