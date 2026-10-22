// 便签同步的随机测试（便签未来计划 A；每次全量都跑一小段，按需加大步数）：三台「电脑」各一个真的 NoteStore（内存库、
// 硬件编号不同 → 电脑编号不同），钟各快慢几分钟，随机做：新建、改正文 / 标题 / 颜色、固定、归档、挪顺序、删除、放回、
// 永久删除、清空最近删除、到期清理（时间偶尔跳十天）、把自己的写出去、读别人的合一轮。另有第四台：中途写过一次就再也不动了
// （合上盖子、不用了的那台，它留下的东西一直在）。两种「文件夹」：
// - randomEditsOnSeveralMacsConverge：整份快照（直接 NoteSync.merge → applySync），只测合并规则；
// - randomRoundsThroughTheFolderConverge：走真的文件写法和一轮的规划（NoteSyncFolder.text / note(from:) / round / publish），
//   读别人的文件时随机看到旧一版、看不到（没下载完）、墓碑文件读不出来——同步盘一个个文件慢慢到的样子。
// 检查：
// - **不丢字**：谁打过的每一版内容，最后要么还在（某一条的内容，或者另存进「最近删除」的那条），要么有人在它之上又改过，
//   要么那一条（或另存它的那条）被人永久删了；
// - 最后安静下来（几台轮流写、读几遍，全都看得见）之后，三台的便签一模一样（修订号是各自的账，不比）；
// - 再合一轮什么都不变（不会一直来回改），写出去也没有要写的；
// - 走文件夹的那个：从没误认成「库被退回去了」；读到被外面动过的文件（补了个换行）、自己的文件被写坏了都扛得住。
// 种子和步数：KITTY_NOTES_SYNC_FUZZ_SEED 换一批、KITTY_NOTES_SYNC_FUZZ 改步数（xcodebuild 加 TEST_RUNNER_ 前缀传进来）；
// 每 300 步一个种子。出问题时报种子。

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
    mutating func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[next(items.count)] }
  }

  /// 一台电脑：自己的库、钟快慢多少；整份快照的那种文件夹（folder / tombstones）和走文件的那种（files / erased：
  /// 文件名 → 这个文件先后的几版，最后一版是现在的，nil = 删了）
  private final class Mac {
    let store: NoteStore
    let skew: TimeInterval
    var folder: [String: Note] = [:]
    var tombstones: [String: NoteSync.Tombstone] = [:]
    var files: [String: [String?]] = [:]
    var erased: [Data] = []

    init(host: String, skew: TimeInterval) throws {
      store = try NoteStore(db: Database(path: ":memory:"), wait: { _ in }, host: host)
      self.skew = skew
    }

    func snapshot() {
      folder = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })
      tombstones = store.erased
    }
  }

  /// 打过的每一版（第几步打的）、有人在它之上改过的、被人永久删过的（第几步）——检查「不丢字」用
  private struct Tracker {
    var typed: [String: [String: Int]] = [:]
    var built: [String: Set<String>] = [:]
    var erased: [String: Int] = [:]
    var step = 0

    /// 在一台上随机做一件本机的事（新建、改、固定、归档、挪、删、放回、永久删、清空、到期清理）；记下打过的和删掉的
    mutating func act(on store: NoteStore, random: inout Seeded, now: Date) {
      let words = ["买菜", "开会", "**粗**", "☐ 待办", "", "一段很长的字", "改了", "Hello"]
      let before = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.id, $0) })
      let alive = store.notes.filter { $0.deletedAt == nil }
      let trashed = store.notes.filter { $0.deletedAt != nil }
      var edited: String?
      switch random.next(12) {
      case 0:
        if store.notes.count < 30 {
          edited = store.create(body: random.pick(words) ?? "", now: now).id
        }
      case 1, 2:
        if let note = random.pick(alive) {
          store.setBody(note.body + (random.pick(words) ?? ""), of: note.id, now: now)
          edited = note.id
        }
      case 3:
        if let note = random.pick(alive) {
          store.setTitle(random.pick(words) ?? "", of: note.id, now: now)
          edited = note.id
        }
      case 4:
        if let note = random.pick(alive) {
          store.setColor(random.next(8), of: note.id, now: now)
          edited = note.id
        }
      case 5:
        if let note = random.pick(alive) { store.setPinned(!note.isPinned, of: note.id, now: now) }
      case 6:
        if let note = random.pick(alive) {
          store.setArchived(!note.isArchived, of: note.id, now: now)
        }
      case 7:
        if let note = random.pick(store.active) {
          store.move(note.id, to: random.next(store.active.count + 1), now: now)
        }
      case 8:
        if let note = random.pick(alive) { store.delete(note.id, now: now) }
      case 9:
        if let note = random.pick(trashed) { store.restore(note.id, now: now) }
      case 10:
        if random.chance(4) {
          store.emptyTrash(now: now)
        } else if let note = random.pick(trashed) {
          store.erase(note.id, now: now)
        }
      default:
        store.purgeExpired(now: now)
      }
      // 内容真变了才算打过（改成一样的字、换成同一种颜色不算：不然「打完之后才删」的判断会被这一下往后挪）
      if let id = edited, let after = store.note(id),
        before[id].map(NoteSync.contentHash) != NoteSync.contentHash(after)
      {
        typed[id, default: [:]][NoteSync.contentHash(after)] = step
        if let old = before[id] { built[id, default: []].insert(NoteSync.contentHash(old)) }
      }
      // 本机这一下没了的都是本机永久删的（永久删除、清空、到期清理——另存进最近删除的那条满 30 天也在这里）；
      // 同步删掉的是别处删过的，那台已经记过了
      for id in Set(before.keys).subtracting(store.notes.map(\.id)) { erased[id] = step }
      step += 1
    }

    /// 不丢字：打过的每一版要么还是那一条（或另存它的那条）的内容、要么有人在它之上改过、要么打完之后那一条（或另存它的
    /// 那条）被永久删过
    func check(_ notes: [Note], seed: UInt64) {
      let contents = Dictionary(
        uniqueKeysWithValues: notes.map { ($0.id, NoteSync.contentHash($0)) })
      for (id, hashes) in typed {
        for (hash, typedAt) in hashes where contents[id] != hash {
          let copy = NoteSync.copyID(of: id, content: hash)
          let kept = contents[copy] == hash
          let superseded = built[id]?.contains(hash) == true || built[copy]?.contains(hash) == true
          let erasedLater = (erased[id] ?? -1) >= typedAt || erased[copy] != nil
          if !kept && !superseded && !erasedLater {
            Issue.record("种子 \(seed)：便签 \(id.prefix(8)) 打过的一版（\(hash.prefix(8))）没了")
          }
        }
      }
    }
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

  private func converged(_ macs: [Mac], seed: UInt64) {
    func shapes(_ mac: Mac) -> [String: Shape] {
      Dictionary(uniqueKeysWithValues: mac.store.notes.map { ($0.id, Shape($0)) })
    }
    let reference = shapes(macs[0])
    for mac in macs.dropFirst() where shapes(mac) != reference {
      let mine = shapes(mac)
      let differing = Set(reference.keys).union(mine.keys).filter { reference[$0] != mine[$0] }
      Issue.record(
        "种子 \(seed)：几台没合到一起，不一样的 \(differing.count) 条，例如 \(differing.sorted().prefix(3))")
    }
  }

  private func seeds() -> (first: UInt64, count: Int, steps: Int) {
    let environment = ProcessInfo.processInfo.environment
    let first = UInt64(environment["KITTY_NOTES_SYNC_FUZZ_SEED"] ?? "") ?? 1
    let steps = max(Int(environment["KITTY_NOTES_SYNC_FUZZ"] ?? "") ?? 1200, 1)
    return (first, max(steps / 300, 1), min(steps, 300))
  }

  private func macs() throws -> (live: [Mac], gone: Mac) {
    let live = try [
      Mac(host: "mac-a", skew: 0), Mac(host: "mac-b", skew: -180), Mac(host: "mac-c", skew: 90),
    ]
    return (live, try Mac(host: "mac-gone", skew: 30))
  }

  // MARK: 整份快照

  /// 合一轮：别人快照里的版本 + 所有人的墓碑（并起来）。返回变没变
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
      let fresh = merge.copies.filter { local[$0.id] == nil && tombstones[$0.id] == nil }
      if merge.note != local[id] || !fresh.isEmpty { merges[id] = merge }
    }
    mac.store.applySync(merges, tombstones: tombstones)
    return !merges.isEmpty
  }

  @Test func randomEditsOnSeveralMacsConverge() throws {
    let (first, count, steps) = seeds()
    print("notes-sync-fuzz snapshot seeds=\(first)..<\(first + UInt64(count)) steps=\(steps)")
    for seed in first..<(first + UInt64(count)) {
      var random = Seeded(state: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
      let (macs, gone) = try macs()
      let everyone = macs + [gone]
      let goneAt = random.next(max(steps / 2, 1))
      var tracker = Tracker()
      var clock = Date(timeIntervalSince1970: 1_800_000_000)
      for step in 0..<steps {
        clock = clock.addingTimeInterval(Double(random.next(5_000)) / 1000)
        if random.chance(60) { clock = clock.addingTimeInterval(10 * 86_400) }
        guard let mac = random.pick(step <= goneAt ? everyone : macs) else { continue }
        let now = clock.addingTimeInterval(mac.skew)
        switch random.next(16) {
        case 0..<12: tracker.act(on: mac.store, random: &random, now: now)
        case 12, 13: mac.snapshot()
        default: sync(mac, with: everyone.filter { $0 !== mac }, now: now)
        }
        if step == goneAt { gone.snapshot() }
      }
      // 安静下来：先等到几台的钟都过了刚才那些改动，再轮流写、读几遍（第四台不动了）
      clock = clock.addingTimeInterval(600)
      for _ in 0..<4 {
        clock = clock.addingTimeInterval(1)
        for mac in macs { mac.snapshot() }
        for mac in macs {
          sync(mac, with: everyone.filter { $0 !== mac }, now: clock.addingTimeInterval(mac.skew))
        }
      }
      converged(macs, seed: seed)
      tracker.check(macs[0].store.notes, seed: seed)
      for mac in macs { mac.snapshot() }
      for mac in macs {
        let changed = sync(
          mac, with: everyone.filter { $0 !== mac }, now: clock.addingTimeInterval(mac.skew))
        #expect(!changed, "种子 \(seed)：安静下来之后再合一轮还在变")
      }
    }
  }

  // MARK: 走文件夹（文件写法 + 一轮的规划；读别人的时候随机旧一版、没下载完）

  /// 自己的子文件夹（读自己的不延迟）
  private func own(_ mac: Mac) -> NoteSyncFolder.Device {
    var device = NoteSyncFolder.Device()
    for (name, history) in mac.files {
      guard let id = NoteSyncFolder.noteID(ofFileNamed: name), let text = history.last ?? nil else {
        continue
      }
      if let note = NoteSyncFolder.note(from: text, fileID: id) {
        device.notes[id] = note
      } else {
        device.unreadable.insert(id)
      }
    }
    device.erased = mac.erased.last.map(NoteSyncFolder.tombstones(from:)) ?? .read([:])
    return device
  }

  /// 别人的子文件夹，同步盘那样慢慢到：每个文件七成是最新的、两成是更早的哪一版（或者还没有）、一成没下载完（读不出来）；
  /// 另有一点点是被外面动过的（补了个换行：哈希对不上，当读不出来）。墓碑文件同样。full：全都看得见（收尾时）
  private func view(_ mac: Mac, random: inout Seeded, full: Bool) -> NoteSyncFolder.Device {
    var device = NoteSyncFolder.Device()
    func pick<T>(_ history: [T]) -> (value: T?, unreadable: Bool) {
      guard let last = history.last else { return (nil, false) }
      if full { return (last, false) }
      switch random.next(10) {
      case 0: return (nil, true)
      case 1, 2:
        let back = random.next(history.count + 1)
        return (back < history.count ? history[back] : nil, false)
      default: return (last, false)
      }
    }
    for (name, history) in mac.files {
      guard let id = NoteSyncFolder.noteID(ofFileNamed: name) else { continue }
      let (version, unreadable) = pick(history)
      if unreadable {
        device.unreadable.insert(id)
      } else if var text = version ?? nil {
        if !full, random.chance(20) { text += "\n" }
        if let note = NoteSyncFolder.note(from: text, fileID: id) {
          device.notes[id] = note
        } else {
          device.unreadable.insert(id)
        }
      }
    }
    let (erased, unreadable) = pick(mac.erased)
    device.erased =
      unreadable ? .unreadable : (erased.map(NoteSyncFolder.tombstones(from:)) ?? .read([:]))
    return device
  }

  /// 写出去：NoteSyncFolder.publish 说要写的写成文件（往历史里加一版）、要删的加一个 nil、墓碑变了重写
  @discardableResult
  private func publish(_ mac: Mac) -> Bool {
    let plan = NoteSyncFolder.publish(
      local: mac.store.notes, erased: mac.store.erased,
      own: mac.files.isEmpty && mac.erased.isEmpty ? nil : own(mac), localImages: [],
      folderImages: [])
    for note in plan.writes {
      mac.files[NoteSyncFolder.fileName(of: note.id), default: []].append(
        NoteSyncFolder.text(of: note))
    }
    for id in plan.deletes { mac.files[NoteSyncFolder.fileName(of: id), default: []].append(nil) }
    if let erased = plan.erased { mac.erased.append(NoteSyncFolder.data(of: erased)) }
    return !plan.isEmpty
  }

  /// 自己文件夹里随便一个文件被写坏了（下一次写出去要重写它）
  private func corrupt(_ mac: Mac, random: inout Seeded) {
    guard let name = random.pick(mac.files.keys.sorted()), mac.files[name]?.last != nil else {
      return
    }
    mac.files[name]?.append("写坏了")
  }

  /// 读一轮、合、落下去。返回变没变
  @discardableResult
  private func round(
    _ mac: Mac, with others: [Mac], random: inout Seeded, now: Date, full: Bool, seed: UInt64
  ) -> Bool {
    var folder = NoteSyncFolder.Folder(marker: NoteSyncFolder.Marker(library: "L"))
    folder.devices[mac.store.deviceID] = own(mac)
    for other in others {
      folder.devices[other.store.deviceID] = view(other, random: &random, full: full)
    }
    let regressed = NoteSyncFolder.regressed(
      local: mac.store.notes, folder: folder, device: mac.store.deviceID)
    #expect(regressed.isEmpty, "种子 \(seed)：误认成库被退回去了")
    guard
      case .success(let round) = NoteSyncFolder.round(
        local: mac.store.notes, erased: mac.store.erased, folder: folder, library: "L", now: now)
    else { return false }
    mac.store.applySync(round.merges, tombstones: round.tombstones)
    return !round.merges.isEmpty
  }

  @Test func randomRoundsThroughTheFolderConverge() throws {
    let (first, count, steps) = seeds()
    print("notes-sync-fuzz folder seeds=\(first)..<\(first + UInt64(count)) steps=\(steps)")
    for seed in first..<(first + UInt64(count)) {
      var random = Seeded(state: seed &* 0xBF58_476D_1CE4_E5B9 | 1)
      let (macs, gone) = try macs()
      let everyone = macs + [gone]
      let goneAt = random.next(max(steps / 2, 1))
      var tracker = Tracker()
      var clock = Date(timeIntervalSince1970: 1_800_000_000)
      for step in 0..<steps {
        clock = clock.addingTimeInterval(Double(random.next(5_000)) / 1000)
        if random.chance(60) { clock = clock.addingTimeInterval(10 * 86_400) }
        guard let mac = random.pick(step <= goneAt ? everyone : macs) else { continue }
        let now = clock.addingTimeInterval(mac.skew)
        switch random.next(16) {
        case 0..<12: tracker.act(on: mac.store, random: &random, now: now)
        case 12: publish(mac)
        case 13: if random.chance(5) { corrupt(mac, random: &random) } else { publish(mac) }
        default:
          round(
            mac, with: everyone.filter { $0 !== mac }, random: &random, now: now, full: false,
            seed: seed)
          publish(mac)
        }
        if step == goneAt { publish(gone) }
      }
      clock = clock.addingTimeInterval(600)
      for _ in 0..<4 {
        clock = clock.addingTimeInterval(1)
        for mac in macs { publish(mac) }
        for mac in macs {
          round(
            mac, with: everyone.filter { $0 !== mac }, random: &random,
            now: clock.addingTimeInterval(mac.skew), full: true, seed: seed)
        }
      }
      converged(macs, seed: seed)
      tracker.check(macs[0].store.notes, seed: seed)
      for mac in macs { publish(mac) }
      for mac in macs {
        let changed = round(
          mac, with: everyone.filter { $0 !== mac }, random: &random,
          now: clock.addingTimeInterval(mac.skew), full: true, seed: seed)
        #expect(!changed, "种子 \(seed)：安静下来之后再合一轮还在变")
        let wrote = publish(mac)
        #expect(!wrote, "种子 \(seed)：安静下来之后还有要写的")
      }
    }
  }
}
