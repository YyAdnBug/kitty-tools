// 便签同步的合并规则（便签未来计划 A3 / A4，2026-10-22；规矩在 mac-native §2「便签同步」）。纯函数：同步文件夹（现在做的）
// 和以后要是入会换成 CloudKit 共用，执行层只管把「本机这一版 + 别的电脑的那几版 + 墓碑」交进来、把结果落下去。
// 一条便签分三组各合各的：
// - **内容**（标题、正文、颜色）看版本钟（Note.clock：每台电脑改过几次内容）。一版的钟每格都不大于另一版、内容又不一样
//   = 另一版是在它之上改的，它被盖过了：丢掉、不留旧版（对面改了、本机没改 → 直接换，「最近删除」里不多东西）。剩下谁都
//   盖不住谁的（两边各改各的）才是冲突（A3）：「改于」后的赢（一样时按内容的哈希，几台挑出来的一样），输的那几版文字
//   **各另存一条进「最近删除」**——编号由便签编号 + 输的那版内容的哈希推出来（copyID），别的字段也都由那一版定（只有
//   放进最近删除的时刻是各台的现在）：几台电脑各自发现同一个冲突、各存一条，同步之后还是一条。**另存那条的钟是空的**：它是
//   新的一条，原来那条的钟在它身上没意义——几台从钟不同、字一样的几版另存出同一条时，带着各自的钟接着改就撞号（同一台的
//   同一个次数是两回不同的改动），真改过的字会被当成「被盖过」悄悄扔掉（随机测试抓到的）。合完的钟取所有版本每格的
//   最大值（盖过所有人：输的那台下一轮看到的是快进）。只看钟、不看时钟谁快谁慢：慢了的钟改的字照样是「在之上改的」。
//   **钟能用的前提**（NoteStore 守着）：每次内容变化自己那一格 +1（0.6.0 之前、0.5.0 改过的行，打开库时补一格）、计数不回退
//   （从备份恢复换一个电脑编号）、电脑编号不撞。
// - **状态**（归档、固定、删除）后改的赢，按 stateTime；**顺序**单独按 orderTime（整列重排只动顺序，翻不回别的电脑同时做的
//   删除、归档）。一样时按值本身排，几台挑出来的一样。本机改时这两个时刻只往前走（至少比这条上一次晚 1 毫秒）。
// - **一边删、一边改**：几组分开合 → 最新的内容在「最近删除」里（A4），什么都不丢。
// - **永久删除**（墓碑 Tombstone：被删的那一版的钟和状态时刻，几台的并起来）：钟每格都不超过它、状态也不晚于它的版本——
//   被删那一版本身和它的前身——都当没有，在不在「最近删除」里都一样（不然一台合上盖子一个月、一台不用了留下的旧文件夹，
//   会把清空了的再救回来，还是没删的样子）。删了之后又改过（钟超过）、放回过（状态晚于）的压不住，照常合：宁可多一条。
//   本机那条被压住、又没剩下别的版本 → 本机真删。压不住、留下来的那条，钟里并上墓碑的钟（计数不退回去）。
// - 时间按原值比，不管它是不是比现在还晚（钟快的那台在别人的钟追上之前赢那几个同时的改动；夹成现在的话结果跟各台的现在
//   有关，几台挑出不同的赢家）。
// 合出来和本机那条一样（修订号不算）就原样给回本机那条：执行层据此判断「这一轮这条没变」。

import CryptoKit
import Foundation

nonisolated enum NoteSync {
  /// 永久删除的墓碑：被删的那一版的钟和状态时刻（几台的墓碑并起来：钟每格取最大、时刻取最晚）
  struct Tombstone: Equatable, Sendable {
    var clock: [String: Int]
    var state: Date

    /// 一版是不是被它压住：钟每格都不超过、状态也不晚于
    func buries(_ note: Note) -> Bool {
      note.stateTime <= state && note.clock.allSatisfy { $0.value <= (clock[$0.key] ?? 0) }
    }

    func merged(with other: Tombstone) -> Tombstone {
      Tombstone(clock: joined([clock, other.clock]), state: max(state, other.state))
    }
  }

  /// 合一条的结果
  struct Merge: Equatable, Sendable {
    /// 合完的样子；nil = 本机不该有这条（本机有的话真删：被墓碑压住了）
    var note: Note?
    /// 冲突里输了、文字和赢的不一样的那几版：各另存一条进「最近删除」（编号 copyID，已经有了 / 永久删过的不再存）
    var copies: [Note] = []
    /// 本机那条原来没删、合完进了「最近删除」（一轮里要数它：多了停下来问，A5）
    var trashes = false
    /// 合的时候本机那条的修订号（本机没有是 nil）：落下去之前本机又改了（打了字、删了）就不落这一条，下一轮再合
    var base: Int?
  }

  /// 次数的上限（文件夹里读进来的钟夹在它以内：读进 Int.max 的话本机再 +1 就溢出）
  static let maxCount = 1 << 40

  /// 内容（标题、正文、颜色）的哈希：比「两版内容一不一样」、挑冲突的赢家时一样早晚用它定先后、推另存那条的编号
  static func contentHash(_ note: Note) -> String {
    var data = Data(note.title.utf8)
    data.append(0)
    data.append(contentsOf: note.body.utf8)
    data.append(0)
    data.append(contentsOf: String(note.color).utf8)
    return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// a 被 b 盖过了吗：a 的每一格都不大于 b，而且两个不一样
  static func precedes(_ a: [String: Int], _ b: [String: Int]) -> Bool {
    a != b && a.allSatisfy { $0.value <= (b[$0.key] ?? 0) }
  }

  /// 版本钟在库里、文件头里的写法：`编号:次数` 按编号排、逗号隔开（空钟是空串）
  static func text(of clock: [String: Int]) -> String {
    clock.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
  }

  /// 读回来：写坏的格子（编号不是字母数字和减号、次数不是 1…maxCount 的整数）跳过
  static func clock(text: String) -> [String: Int] {
    var clock: [String: Int] = [:]
    for cell in text.split(separator: ",") {
      let parts = cell.split(separator: ":")
      guard parts.count == 2, let count = Int(parts[1]), (1...maxCount).contains(count),
        (1...64).contains(parts[0].count),
        parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
      else { continue }
      clock[String(parts[0])] = max(clock[String(parts[0])] ?? 0, count)
    }
    return clock
  }

  /// 几个钟合起来：每格取最大
  static func joined(_ clocks: [[String: Int]]) -> [String: Int] {
    clocks.reduce(into: [:]) { result, clock in result.merge(clock, uniquingKeysWith: max) }
  }

  /// 输的那版另存成的那一条的编号：便签编号 + 那版内容的哈希推出来（UUID 第 5 版的写法）。同一版不管哪台电脑、存几次
  /// 都是这一个
  static func copyID(of id: String, content hash: String) -> String {
    var bytes = Array(
      SHA256.hash(data: Data("kitty-note-conflict\0\(id)\0\(hash)".utf8)).prefix(16))
    bytes[6] = bytes[6] & 0x0F | 0x50
    bytes[8] = bytes[8] & 0x3F | 0x80
    let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
    return UUID(uuid: uuid).uuidString
  }

  /// 合一条：local 是本机的（没有 = 本机没有这条，新来的或本机永久删过的），remotes 是别的电脑文件夹里的（同一个编号），
  /// tombstone 是这条的墓碑（本机的和别的电脑的并起来）。now 只用来记另存那几条放进「最近删除」的时刻。规则见文件头
  static func merge(local: Note?, remotes: [Note], tombstone: Tombstone?, now: Date) -> Merge {
    let base = local?.revision
    let others = remotes.filter { tombstone?.buries($0) != true }
    if let local, tombstone?.buries(local) == true, others.isEmpty {
      return Merge(note: nil, base: base)
    }
    let versions = (local.map { [$0] } ?? []) + others
    guard !versions.isEmpty else { return Merge(note: nil, base: base) }

    // 内容：去掉被盖过的（内容不一样、钟被别的版本盖过），剩下的里「改于」后的赢，同一刻按哈希
    let hashes = versions.map(contentHash)
    let standing = versions.indices.filter { i in
      !versions.indices.contains { j in
        hashes[j] != hashes[i] && precedes(versions[i].clock, versions[j].clock)
      }
    }
    func earlier(_ i: Int, _ j: Int) -> Bool {
      (versions[i].modifiedAt, hashes[i]) < (versions[j].modifiedAt, hashes[j])
    }
    guard let winner = standing.max(by: earlier) else { return Merge(note: local, base: base) }
    // 输的：每种内容留一份（同一内容几版里「改于」最晚的那版）
    var losers: [String: Int] = [:]
    for i in standing where hashes[i] != hashes[winner] {
      if let kept = losers[hashes[i]], !earlier(kept, i) { continue }
      losers[hashes[i]] = i
    }
    let stamp = Note.stamp(now)
    let copies = losers.keys.sorted().compactMap { hash -> Note? in
      guard let index = losers[hash] else { return nil }
      let loser = versions[index]
      return Note(
        id: copyID(of: loser.id, content: hash), title: loser.title, body: loser.body,
        color: loser.color, createdAt: loser.createdAt, modifiedAt: loser.modifiedAt,
        order: loser.order, deletedAt: stamp, stateChangedAt: loser.modifiedAt,
        orderChangedAt: loser.modifiedAt)
    }

    // 状态、顺序：各自后改的赢，同一刻按值本身
    func stateKey(_ note: Note) -> (Date, Int64, Int, Int) {
      (
        note.stateTime, note.deletedAt.map(Note.milliseconds) ?? -1, note.isArchived ? 1 : 0,
        note.isPinned ? 1 : 0
      )
    }
    guard let state = versions.max(by: { stateKey($0) < stateKey($1) }),
      let order = versions.max(by: { ($0.orderTime, $0.order) < ($1.orderTime, $1.order) })
    else { return Merge(note: local, base: base) }

    var note = versions[winner]
    // 墓碑的钟也并进来：本机永久删过、又被别处改过的那版救回来时，本机那一格不退回去（退回去的话本机接着改会重复用计数，
    // 也会被当成「库被退回去了」——走文件夹的随机测试抓到的）；被删那一版的前身从此也都被它盖过
    note.clock = joined(versions.map(\.clock) + (tombstone.map { [$0.clock] } ?? []))
    note.createdAt = versions.map(\.createdAt).min() ?? note.createdAt
    note.isArchived = state.isArchived
    note.isPinned = state.isPinned
    note.deletedAt = state.deletedAt
    note.stateChangedAt = state.stateTime
    note.order = order.order
    note.orderChangedAt = order.orderTime
    // 修订号是本机的账：本机有就在本机的上往上走，新来的从 0 起
    guard let local else {
      note.revision = 0
      return Merge(note: note, copies: copies, base: base)
    }
    note.revision = local.revision
    if note == local { return Merge(note: local, copies: copies, base: base) }
    note.revision = Note.nextRevision(after: local.revision)
    return Merge(
      note: note, copies: copies, trashes: local.deletedAt == nil && note.deletedAt != nil,
      base: base)
  }
}
