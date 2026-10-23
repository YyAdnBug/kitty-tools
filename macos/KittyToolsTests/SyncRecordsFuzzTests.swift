// 全局同步里「一条一条的数据」的随机测试（Storage/SyncRecords.swift）：三台电脑（一台中途才加入）随机加、改、删、合，读别人的
// 那份时随机读到旧一版、自己那份偶尔读不出来，各台的钟差几十毫秒，加的时候常用删过的编号（同一编号再加回来、两台各自新建
// 同一项），改动带上真正改的时刻，偶尔把一台的库和账本一起退回到旧的样子（时间机器）、偶尔丢掉账本（重新加入）；一半种子按
// 设置那样第一次合时整个跟着别人（adopt）。每合一轮查账本和本机对得上；最后安静下来几轮，查三台一模一样、每个值都是
// 谁写过的、再合一轮什么都不变；再让一台改一条、另一台删一条，查改动
// 和删除都传到每一台（改的那台这一轮的钟比谁都慢：先后看版本钟，不看时间）。默认 20 个种子 × 300 步（约 9 秒），按需加大：
// TEST_RUNNER_KITTY_SYNC_RECORDS_FUZZ=<种子数>，TEST_RUNNER_KITTY_SYNC_RECORDS_FUZZ_SEED=<起始种子>。

import Foundation
import Testing

@testable import KittyTools

struct SyncRecordsFuzzTests {
  private struct Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
  }

  private struct Mac {
    let id: String
    var local: [String: String] = [:]
    var ledger: SyncRecords.Ledger?
    /// 自己那份写过的每一版（别人读的时候可能读到旧的）
    var history: [SyncRecords.File] = []
    var joined = false
    var skew: Int64 = 0
    var snapshot: (local: [String: String], ledger: SyncRecords.Ledger?)?
    /// 本机记着的每条真正改的时刻（仓库 / 偏好记的）
    var changed: [String: Int64] = [:]
  }

  @Test func randomOperationsConverge() {
    let environment = ProcessInfo.processInfo.environment
    let count = environment["KITTY_SYNC_RECORDS_FUZZ"].flatMap { Int($0) } ?? 20
    let first = environment["KITTY_SYNC_RECORDS_FUZZ_SEED"].flatMap { UInt64($0) } ?? 1
    for seed in first..<(first + UInt64(count)) {
      if let failure = Self.simulate(seed: seed, steps: 300) {
        Issue.record("种子 \(seed)：\(failure)")
        return
      }
    }
  }

  /// 跑一个种子；出错返回说明
  private static func simulate(seed: UInt64, steps: Int) -> String? {
    var rng = Rng(state: seed)
    var macs = ["A", "B", "C"].map { Mac(id: $0) }
    for index in macs.indices {
      macs[index].skew = Int64(rng.below(101)) - 50
      // A、B 一开始就在；C 第一次合时才加入（没有账本）
      macs[index].ledger = index < 2 ? SyncRecords.Ledger() : nil
      macs[index].joined = index < 2
    }
    var serial = 0
    let join: SyncRecords.Join = seed % 2 == 0 ? .adopt : .union(dedupe: { $0 })
    /// 用过的编号（加的时候常挑一个再用）、写过的值
    var used: [String] = []
    var written: Set<String> = []

    /// behind：这一轮这台的钟比谁都慢（改于是 0）——它在别人之后改的照样要赢（看钟，不看时间）
    func round(
      _ index: Int, at step: Int, stale: Bool, behind: Bool = false, ownUnreadable: Bool = false
    ) -> String? {
      let others = macs.indices.filter { $0 != index }.compactMap { other -> SyncRecords.File? in
        let history = macs[other].history
        guard !history.isEmpty else { return nil }
        return stale && rng.chance(30) ? history[rng.below(history.count)] : history.last
      }
      let now = behind ? 0 : Int64(step) * 100 + macs[index].skew
      let outcome = SyncRecords.round(
        local: macs[index].local, changed: behind ? [:] : macs[index].changed,
        ledger: macs[index].ledger, own: ownUnreadable ? nil : macs[index].history.last,
        others: others, me: macs[index].id, now: now, join: join)
      for (key, value) in outcome.changes { macs[index].local[key] = value }
      macs[index].ledger = outcome.ledger
      macs[index].history.append(outcome.own)
      macs[index].joined = true
      // 账本和本机对得上：同样的几条、同样的哈希
      let entries = outcome.ledger.entries
      guard Set(entries.keys) == Set(macs[index].local.keys),
        macs[index].local.allSatisfy({ entries[$0.key]?.hash == SyncRecords.hash($0.value) })
      else { return "\(macs[index].id) 第 \(step) 步合完账本和本机对不上" }
      return nil
    }

    for step in 0..<steps {
      let index = rng.below(macs.count)
      guard macs[index].joined || rng.chance(50) else { continue }
      switch rng.below(100) {
      case 0..<20:
        serial += 1
        // 偶尔加一条和别的电脑某条内容一样的（第一次合时不该重复）；常用一个用过的编号（删了又加回来、两台各自新建同一项）
        let donor = macs[rng.below(macs.count)].local.values.sorted().first
        let value = rng.chance(10) ? (donor ?? "v\(serial)") : "v\(serial)"
        let id = !used.isEmpty && rng.chance(25) ? used[rng.below(used.count)] : "i\(serial)"
        if !used.contains(id) { used.append(id) }
        macs[index].local[id] = value
        macs[index].changed[id] = Int64(step) * 100 + macs[index].skew
        written.insert(value)
      case 20..<40:
        if let key = macs[index].local.keys.sorted().randomElement(using: &rng) {
          serial += 1
          macs[index].local[key] = "m\(serial)"
          macs[index].changed[key] = Int64(step) * 100 + macs[index].skew
          written.insert("m\(serial)")
        }
      case 40..<50:
        if let key = macs[index].local.keys.sorted().randomElement(using: &rng) {
          macs[index].local[key] = nil
        }
      case 50..<93:
        if let failure = round(index, at: step, stale: true, ownUnreadable: rng.chance(10)) {
          return failure
        }
      case 93..<96:
        // 记下一个「旧的样子」，之后可能退回去
        macs[index].snapshot = (macs[index].local, macs[index].ledger)
      case 96..<98:
        if let snapshot = macs[index].snapshot {
          macs[index].local = snapshot.local
          macs[index].ledger = snapshot.ledger
        }
      default:
        if macs[index].joined { macs[index].ledger = nil }
      }
    }

    // 安静下来：都读最新的，合三遍
    var step = steps
    for _ in 0..<3 {
      for index in macs.indices {
        step += 1
        if let failure = round(index, at: step, stale: false) { return failure }
      }
    }
    guard macs[0].local == macs[1].local, macs[1].local == macs[2].local else {
      return "安静下来之后三台不一样：\(macs.map { $0.local.count })"
    }
    guard macs[0].local.values.allSatisfy({ written.contains($0) }) else {
      return "合出了谁都没写过的值"
    }
    for index in macs.indices {
      step += 1
      let before = macs[index].local
      if let failure = round(index, at: step, stale: false) { return failure }
      guard macs[index].local == before else { return "\(macs[index].id) 再合一轮又变了" }
    }
    // 先后的改动：一台在钟慢得离谱的时候改一条，传到每一台；再让另一台删掉它，删除也传到每一台
    guard let key = macs[0].local.keys.sorted().first else { return nil }
    let slowest = macs.indices.min { macs[$0].skew < macs[$1].skew } ?? 0
    macs[slowest].local[key] = "最后改的"
    macs[slowest].changed[key] = nil
    for offset in 0..<macs.count {
      step += 1
      if let failure = round(
        (slowest + offset) % macs.count, at: step, stale: false, behind: offset == 0)
      {
        return failure
      }
    }
    guard macs.allSatisfy({ $0.local[key] == "最后改的" }) else {
      return "钟最慢的那台最后改的没传到每一台：\(macs.map { $0.local[key] ?? "（没有）" })"
    }
    let deleter = (slowest + 1) % macs.count
    macs[deleter].local[key] = nil
    for offset in 0..<macs.count {
      step += 1
      if let failure = round((deleter + offset) % macs.count, at: step, stale: false) {
        return failure
      }
    }
    guard macs.allSatisfy({ $0.local[key] == nil }) else { return "删掉的那条没在每一台删掉" }
    return nil
  }
}
