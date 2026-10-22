// 便签同步的随机测试（便签未来计划 A；每次全量都跑一小段，按需加大步数）：三台「电脑」各一个真的 NoteStore（内存库、
// 硬件编号不同 → 电脑编号不同），钟各快慢几分钟，随机做：新建、改正文 / 标题 / 颜色、固定、归档、挪顺序、删除、放回、
// 永久删除、清空最近删除、到期清理（时间偶尔跳十天）、把自己的写进「文件夹」（快照 + 墓碑）、读别人的合一轮
// （NoteSync.merge → applySync）。另有第四台：中途写过一次文件夹就再也不动了（合上盖子、不用了的那台，旧文件夹一直留着）。
// 检查：
// - **不丢字**：谁打过的每一版内容，最后要么还在（某一条的内容，或者另存进「最近删除」的那条），要么有人在它之上又改过，
//   要么那一条（或另存它的那条）被人永久删了；
// - 最后安静下来（几台轮流写、读几遍）之后，三台的便签一模一样（修订号是各自的账，不比）；
// - 再合一轮什么都不变（不会一直来回改）。
// 种子和步数：KITTY_NOTES_SYNC_FUZZ_SEED 换一批、KITTY_NOTES_SYNC_FUZZ 改步数（xcodebuild 加 TEST_RUNNER_ 前缀传进来）；
// 每 300 步一个种子。出问题时报种子。
// ponytail: 文件夹是整份的原子快照；真的执行层一个个文件延迟、只看到一部分的情况由执行层那批的测试管

import Foundation
import Testing

@testable import KittyTools

struct NoteSyncFuzzTests {
  /// 线性同余，够随机、可复现（同 LaunchpadFuzzTests）
  private struct Seeded {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(max(bound, 1)))
    }
    mutating func chance(_ odds: Int) -> Bool { next(odds) == 0 }
  }

  /// 一台电脑：自己的库、钟快慢多少、写进文件夹的那份
  private final class Mac {
    let store: NoteStore
    let skew: TimeInterval
    var folder: [String: Note] = [:]
    var tombstones: [String: NoteSync.Tombstone] = [:]

    init(host: String, skew: TimeInterval) throws {
      store = try NoteStore(db: Database(path: ":memory:"), wait: { _ in }, host: host)
      self.skew = skew
    }

    func publish() {
      folder = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })
      tombstones = store.erased
    }
  }

  /// 合一轮：别人文件夹里的版本 + 所有人的墓碑（并起来）。返回变没变
  @discardableResult
  private func sync(_ mac: Mac, with others: [Mac], now: Date) -> Bool {
    var remotes: [String: [Note]] = [:]
    var tombstones = mac.store.erased
    for other in others {
      for (id, note) in other.folder { remotes[id, default: []].append(note) }
      for (id, tombstone) in other.tombstones {
        tombstones[id] = tombstones[id].map { $0.merged(with: tombstone) } ?? tombstone
      }
    }
    let local = Dictionary(uniqueKeysWithValues: mac.store.notes.map { ($0.id, $0) })
    var merges: [String: NoteSync.Merge] = [:]
    for id in Set(local.keys).union(remotes.keys) {
      let merge = NoteSync.merge(
        local: local[id], remotes: remotes[id] ?? [], tombstone: tombstones[id], now: now)
      let fresh = merge.copies.filter {
        local[$0.id] == nil && mac.store.erased[$0.id] == nil && tombstones[$0.id] == nil
      }
      if merge.note != local[id] || !fresh.isEmpty { merges[id] = merge }
    }
    mac.store.applySync(merges, tombstones: tombstones)
    return !merges.isEmpty
  }

  /// 比的那几样（修订号是各自的账，不比）
  private struct Shape: Equatable {
    let title: String
    let body: String
    let color: Int
    let created: Int64
    let modified: Int64
    let archived: Bool
    let pinned: Bool
    let order: Double
    let deleted: Int64?
    let state: Int64
    let ordered: Int64
    let clock: [String: Int]

    init(_ note: Note) {
      (title, body, color) = (note.title, note.body, note.color)
      (created, modified) = (Note.milliseconds(note.createdAt), Note.milliseconds(note.modifiedAt))
      (archived, pinned, order) = (note.isArchived, note.isPinned, note.order)
      deleted = note.deletedAt.map(Note.milliseconds)
      state = Note.milliseconds(note.stateTime)
      ordered = Note.milliseconds(note.orderTime)
      clock = note.clock
    }
  }

  private func shapes(_ mac: Mac) -> [String: Shape] {
    Dictionary(uniqueKeysWithValues: mac.store.notes.map { ($0.id, Shape($0)) })
  }

  @Test func randomEditsOnSeveralMacsConverge() throws {
    let environment = ProcessInfo.processInfo.environment
    let first = UInt64(environment["KITTY_NOTES_SYNC_FUZZ_SEED"] ?? "") ?? 1
    let steps = max(Int(environment["KITTY_NOTES_SYNC_FUZZ"] ?? "") ?? 1200, 1)
    let seeds = max(steps / 300, 1)
    print("notes-sync-fuzz seeds=\(first)..<\(first + UInt64(seeds)) steps=\(steps)")
    for seed in first..<(first + UInt64(seeds)) {
      try run(seed: seed, steps: min(steps, 300))
    }
  }

  private func run(seed: UInt64, steps: Int) throws {
    var random = Seeded(state: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
    let macs = try [
      Mac(host: "mac-a", skew: 0), Mac(host: "mac-b", skew: -180), Mac(host: "mac-c", skew: 90),
    ]
    // 第四台：随机做几步、写一次文件夹，之后再也不动（它的旧文件夹一直在）
    let gone = try Mac(host: "mac-gone", skew: 30)
    let goneAt = random.next(max(steps / 2, 1))
    let everyone = macs + [gone]
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let words = ["买菜", "开会", "**粗**", "☐ 待办", "", "一段很长的字", "改了", "Hello"]
    func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[random.next(items.count)] }
    // 谁打过的每一版内容（便签编号 → 内容哈希）、有人在它之上改过的（同上）、被人永久删过的编号
    var typed: [String: Set<String>] = [:]
    var built: [String: Set<String>] = [:]
    var userErased: Set<String> = []
    for step in 0..<steps {
      clock = clock.addingTimeInterval(Double(random.next(5_000)) / 1000)
      if random.chance(60) { clock = clock.addingTimeInterval(10 * 86_400) }
      guard let mac = pick(step <= goneAt ? everyone : macs) else { continue }
      let store = mac.store
      let now = clock.addingTimeInterval(mac.skew)
      let before = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })
      let alive = store.notes.filter { $0.deletedAt == nil }
      let trashed = store.notes.filter { $0.deletedAt != nil }
      var edited: String?
      let operation = random.next(16)
      switch operation {
      case 0 where store.notes.count < 30:
        edited = store.create(body: pick(words) ?? "", now: now).id
      case 1, 2:
        if let note = pick(alive) {
          store.setBody(note.body + (pick(words) ?? ""), of: note.id, now: now)
          edited = note.id
        }
      case 3:
        if let note = pick(alive) {
          store.setTitle(pick(words) ?? "", of: note.id, now: now)
          edited = note.id
        }
      case 4:
        if let note = pick(alive) {
          store.setColor(random.next(8), of: note.id, now: now)
          edited = note.id
        }
      case 5:
        if let note = pick(alive) { store.setPinned(!note.isPinned, of: note.id, now: now) }
      case 6:
        if let note = pick(alive) { store.setArchived(!note.isArchived, of: note.id, now: now) }
      case 7:
        if let note = pick(store.active) {
          store.move(note.id, to: random.next(store.active.count + 1), now: now)
        }
      case 8:
        if let note = pick(alive) { store.delete(note.id, now: now) }
      case 9:
        if let note = pick(trashed) { store.restore(note.id, now: now) }
      case 10:
        if random.chance(4) {
          store.emptyTrash(now: now)
        } else if let note = pick(trashed) {
          store.erase(note.id, now: now)
        }
      case 11:
        store.purgeExpired(now: now)
      case 12, 13:
        mac.publish()
      default:
        sync(mac, with: everyone.filter { $0 !== mac }, now: now)
      }
      if let id = edited, let after = store.note(id) {
        typed[id, default: []].insert(NoteSync.contentHash(after))
        if let old = before[id], NoteSync.contentHash(old) != NoteSync.contentHash(after) {
          built[id, default: []].insert(NoteSync.contentHash(old))
        }
      }
      // 本机永久删掉的（永久删除、清空、到期清理）；同步删掉的是别处删过的，那台已经记过了
      if operation == 10 || operation == 11 {
        userErased.formUnion(Set(before.keys).subtracting(store.notes.map(\.id)))
      }
      if step == goneAt { gone.publish() }
    }
    // 安静下来：先等到几台的钟都过了刚才那些改动，再轮流写、读几遍（第四台不动了）
    clock = clock.addingTimeInterval(600)
    for _ in 0..<4 {
      clock = clock.addingTimeInterval(1)
      for mac in macs { mac.publish() }
      for mac in macs {
        sync(mac, with: everyone.filter { $0 !== mac }, now: clock.addingTimeInterval(mac.skew))
      }
    }
    let reference = shapes(macs[0])
    for mac in macs.dropFirst() where shapes(mac) != reference {
      let mine = shapes(mac)
      let differing = Set(reference.keys).union(mine.keys).filter { reference[$0] != mine[$0] }
      Issue.record(
        "种子 \(seed)：几台没合到一起，不一样的 \(differing.count) 条，例如 \(differing.sorted().prefix(3))")
    }
    // 不丢字：打过的每一版要么还在、要么有人在它之上改过、要么它那条 / 另存它的那条被永久删过
    let contents = Set(macs[0].store.notes.map(NoteSync.contentHash))
    for (id, hashes) in typed where !userErased.contains(id) {
      for hash in hashes where !contents.contains(hash) {
        let copy = NoteSync.copyID(of: id, content: hash)
        let superseded = built[id]?.contains(hash) == true || built[copy]?.contains(hash) == true
        if !superseded && !userErased.contains(copy) {
          Issue.record("种子 \(seed)：便签 \(id.prefix(8)) 打过的一版（\(hash.prefix(8))）没了")
        }
      }
    }
    // 再合一轮：什么都不变
    for mac in macs { mac.publish() }
    for mac in macs {
      let changed = sync(
        mac, with: everyone.filter { $0 !== mac }, now: clock.addingTimeInterval(mac.skew))
      #expect(!changed, "种子 \(seed)：安静下来之后再合一轮还在变")
    }
  }
}
