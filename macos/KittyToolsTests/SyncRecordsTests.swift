// 全局同步里「一条一条的数据」的合并规则和文件写法（Storage/SyncRecords.swift）：本机新加的发出去、别处的收进来、先后的改动
// 直接换、同时改了后改的赢（按真正改的时刻）、删除传过去、删了又被别处改过的留下、账本被退回去了先追上（钟快的旧值不翻掉
// 后来的）、第一次合（同样内容不重复、只对活着的版本去重、跟着文件夹、设置整个跟着别的电脑、不误报刹车）、删过的编号再加
// 回来（还有一台的旧文件也立得住）、两台各自新设同一项、两种写法的同一个字不来回改、自己那份读不出来、刹车和本机删除的
// 计数、文件的往返和读得严。纯函数，不碰文件。

import Foundation
import Testing

@testable import KittyTools

struct SyncRecordsTests {
  /// 一台电脑：本机的、账本、自己那份
  private struct Mac {
    let id: String
    var local: [String: String] = [:]
    var ledger: SyncRecords.Ledger? = SyncRecords.Ledger()
    var own: SyncRecords.File?

    init(_ id: String, joining: Bool = false) {
      self.id = id
      if joining { ledger = nil }
    }

    @discardableResult
    mutating func round(
      _ others: [Mac], at now: Int64, join: SyncRecords.Join = .union(dedupe: { $0 }),
      changed: [String: Int64] = [:], ownUnreadable: Bool = false
    ) -> SyncRecords.Outcome {
      let outcome = SyncRecords.round(
        local: local, changed: changed, ledger: ledger, own: ownUnreadable ? nil : own,
        others: others.compactMap(\.own), me: id, now: now, join: join)
      for (key, value) in outcome.changes { local[key] = value }
      ledger = outcome.ledger
      own = outcome.own
      return outcome
    }
  }

  /// 内容的哈希是 SHA-256 前 16 字节的小写十六进制（写进文件、账本，换写法要一字不差）
  @Test func hashIsTheShortSHA256() {
    #expect(SyncRecords.hash("abc") == "ba7816bf8f01cfea414140de5dae2223")
    #expect(Signing.hex([0x00, 0x0F, 0xA0, 0xFF]) == "000fa0ff")
  }

  @Test func newItemsTravelAndEditsInOrderReplace() {
    var a = Mac("A")
    var b = Mac("B")
    a.local["1"] = "一"
    a.round([b], at: 1)
    #expect(a.own?.records["1"]?.clock == ["A": 1])
    b.round([a], at: 2)
    #expect(b.local == ["1": "一"])
    b.local["1"] = "一二"
    b.round([a], at: 3)
    let outcome = a.round([b], at: 4)
    #expect(a.local == ["1": "一二"] && outcome.changes == ["1": "一二"])
    #expect(a.ledger?.entries["1"]?.clock == ["A": 1, "B": 1])
    // 再合一轮：什么都不变
    #expect(a.round([b], at: 5).changes.isEmpty && b.round([a], at: 6).changes.isEmpty)
  }

  @Test func concurrentEditsLaterWinsOnBothSides() {
    var a = Mac("A")
    var b = Mac("B")
    a.local["1"] = "原来的"
    a.round([b], at: 1)
    b.round([a], at: 2)
    a.local["1"] = "A 改的"
    b.local["1"] = "B 后改的"
    a.round([b], at: 10)
    b.round([a], at: 20)
    a.round([b], at: 30)
    #expect(a.local == ["1": "B 后改的"] && b.local == ["1": "B 后改的"])
    #expect(a.ledger?.entries["1"]?.clock == b.ledger?.entries["1"]?.clock)
  }

  @Test func deletionTravelsButAConcurrentEditSurvives() {
    var a = Mac("A")
    var b = Mac("B")
    a.local = ["1": "删", "2": "删了又被改"]
    a.round([b], at: 1)
    b.round([a], at: 2)
    a.local = [:]
    b.local["2"] = "B 改了"
    a.round([b], at: 3)
    #expect(a.own?.erased.keys.sorted() == ["1", "2"])
    let outcome = b.round([a], at: 4)
    #expect(b.local == ["2": "B 改了"] && outcome.trashing == 1)
    a.round([b], at: 5)
    #expect(a.local == ["2": "B 改了"])
  }

  /// 账本被退回去了（时间机器）：自己那份里的钟先并进来，接着改不撞号；没改的那条跟着自己那份发出去的新内容
  @Test func rolledBackLedgerCatchesUp() {
    var a = Mac("A")
    var b = Mac("B")
    a.local = ["1": "一", "2": "甲"]
    a.round([b], at: 1)
    let snapshot = a
    a.local["1"] = "一二"
    a.local["2"] = "甲乙"
    a.round([b], at: 2)
    b.round([a], at: 3)
    // 恢复成旧的库和账本，自己那份还是新的；恢复后改了「1」
    var restored = snapshot
    restored.own = a.own
    restored.local["1"] = "一（恢复后）"
    restored.round([b], at: 4)
    #expect(restored.ledger?.entries["1"]?.clock == ["A": 3])
    #expect(restored.local == ["1": "一（恢复后）", "2": "甲乙"])
    b.round([restored], at: 5)
    #expect(b.local == restored.local)
  }

  @Test func joiningDoesNotDuplicateOrOverrideTheFolder() {
    var a = Mac("A")
    a.local = ["a1": "同样的片段", "a2": "新内容"]
    a.round([], at: 1)
    var b = Mac("B", joining: true)
    // b1 和 a1 内容一样（编号不同）：只留 a1；a2 本机有个旧样子（同一编号，账本里没有）：跟着文件夹
    b.local = ["b1": "同样的片段", "a2": "旧内容", "b2": "只有 B 有"]
    let outcome = b.round([a], at: 2)
    #expect(b.local == ["a1": "同样的片段", "a2": "新内容", "b2": "只有 B 有"])
    #expect(outcome.trashing == 0)
    a.round([b], at: 3)
    #expect(a.local == b.local)
  }

  /// 设置：第一次合时别的电脑已经有这一类，整个跟着它们（本机多出来的回到默认）；还没有的话本机的发出去
  @Test func settingsAdoptTheExistingMacs() {
    var a = Mac("A", joining: true)
    a.local = ["fontSize": "17", "edge": "\"left\""]
    a.round([], at: 1, join: .adopt)
    #expect(a.own?.records.count == 2)
    var b = Mac("B", joining: true)
    b.local = ["fontSize": "13", "sound": "false"]
    let outcome = b.round([a], at: 2, join: .adopt)
    #expect(b.local == ["fontSize": "17", "edge": "\"left\""] && outcome.trashing == 0)
  }

  /// 一台把设置项改回默认（删掉）、另一台跟着删；之后又在另一台设上：立得住，传回来
  @Test func aResetKeyCanBeSetAgain() {
    var a = Mac("A")
    var b = Mac("B")
    a.local = ["k": "1"]
    a.round([b], at: 1)
    b.round([a], at: 2)
    a.local = [:]
    a.round([b], at: 3)
    b.round([a], at: 4)
    #expect(b.local.isEmpty)
    b.local["k"] = "2"
    b.round([a], at: 5)
    a.round([b], at: 6)
    #expect(a.local == ["k": "2"])
  }

  @Test func brakeCountsOnlyRealDeletions() {
    var a = Mac("A")
    var b = Mac("B")
    a.local = Dictionary(uniqueKeysWithValues: (0..<10).map { ("\($0)", "第 \($0) 条") })
    a.round([b], at: 1)
    b.round([a], at: 2)
    for key in ["0", "1", "2"] { a.local[key] = nil }
    a.round([b], at: 3)
    let outcome = b.round([a], at: 4)
    #expect(outcome.trashing == 3 && outcome.alive == 10)
  }

  @Test func fileRoundTripAndStrictRead() throws {
    var file = SyncRecords.File()
    let odd = "引号\"、换行\n、NUL\u{0}、\u{2028}、👩‍👩‍👧、" + String(repeating: "长", count: 100_000)
    file.records["x"] = .init(value: #"{"text":"你好"}"#, clock: ["A": 2, "B": 1], modified: 1234)
    file.records["z"] = .init(value: odd, clock: ["B": 1], modified: 1)
    file.erased["y"] = ["A": 1]
    let data = SyncRecords.data(of: file, kind: .clips)
    guard case .read(let back) = SyncRecords.file(from: data, kind: .clips) else {
      Issue.record("读不回来")
      return
    }
    #expect(back == file && back.records["z"]?.value.utf8.elementsEqual(odd.utf8) == true)
    // 换个顺序建的同一份：同样的字节
    var reordered = SyncRecords.File()
    reordered.erased["y"] = ["A": 1]
    reordered.records["z"] = file.records["z"]
    reordered.records["x"] = file.records["x"]
    #expect(SyncRecords.data(of: reordered, kind: .clips) == data, "同样的内容同样的字节")
    #expect(SyncRecords.data(of: back, kind: .clips) == data)
    #expect(SyncRecords.file(from: data, kind: .vocabulary) == .unreadable)
    let newer = Data(#"{"format":99,"kind":"clips","records":[],"erased":[],"extra":1}"#.utf8)
    #expect(SyncRecords.file(from: newer, kind: .clips) == .newer)
    // 结构对不上的、别的类别的：不算更新版本
    let shapeless = Data(#"{"format":2,"kind":"clips","records":{}}"#.utf8)
    #expect(SyncRecords.file(from: shapeless, kind: .clips) == .unreadable)
    #expect(SyncRecords.file(from: newer, kind: .settings) == .unreadable)
    let badClock = Data(
      #"{"format":1,"kind":"clips","erased":[],"records":[{"id":"x","clock":"A:1,B:x","modified":1,"value":"1"}]}"#
        .utf8)
    #expect(SyncRecords.file(from: badClock, kind: .clips) == .unreadable)
    let twice = Data(
      #"{"format":1,"kind":"clips","erased":[],"records":[{"id":"x","clock":"A:1","modified":1,"value":"1"},{"id":"x","clock":"A:2","modified":2,"value":"2"}]}"#
        .utf8)
    #expect(SyncRecords.file(from: twice, kind: .clips) == .unreadable)
    #expect(SyncRecords.file(from: Data("{".utf8), kind: .clips) == .unreadable)
  }

  // MARK: 审查后补的

  /// 删过的编号再加回来：还有一台（合盖的 C）的文件停在删之前，照样立得住
  @Test func reAddedIDSurvivesAStaleThirdFile() {
    var a = Mac("A")
    var b = Mac("B")
    var c = Mac("C")
    a.local = ["k": "1"]
    a.round([b, c], at: 1)
    b.round([a, c], at: 2)
    c.round([a, b], at: 3)
    a.local = [:]
    a.round([b, c], at: 4)
    b.round([a, c], at: 5)
    a.local["k"] = "2"
    a.round([b, c], at: 6)
    #expect(a.local == ["k": "2"])
    b.round([a, c], at: 7)
    #expect(b.local == ["k": "2"])
  }

  /// 两台在看到对方之前各自新设同一项：后设的赢（C3）
  @Test func twoMacsSettingTheSameNewKeyLaterWins() {
    var a = Mac("A")
    var b = Mac("B")
    a.local["k"] = "A 先设的"
    a.round([b], at: 10)
    b.local["k"] = "B 后设的"
    b.round([a], at: 20)
    a.round([b], at: 30)
    #expect(a.local == ["k": "B 后设的"] && b.local == ["k": "B 后设的"])
  }

  /// 改于用真正改的时刻：A 先改、退出（第二天才合到），B 后改——B 的赢
  @Test func realChangeTimesDecide() {
    var a = Mac("A")
    var b = Mac("B")
    a.local["k"] = "原来"
    a.round([b], at: 1)
    b.round([a], at: 2)
    a.local["k"] = "A 昨天改的"
    b.local["k"] = "B 今天改的"
    b.round([a], at: 100, changed: ["k": 90])
    a.round([b], at: 200, changed: ["k": 10])
    b.round([a], at: 210)
    #expect(a.local == ["k": "B 今天改的"] && b.local == ["k": "B 今天改的"])
  }

  /// 账本被退回去了：只追上自己那一格——钟快的那台当时的旧值，不会因为改于晚翻掉之后（钟上明确在后）改的
  @Test func rollbackDoesNotLetAFastClockOldValueWin() {
    var a = Mac("A")
    var b = Mac("B")
    var c = Mac("C")
    c.local["k"] = "v1"
    c.round([a, b], at: 10_000)
    a.round([b, c], at: 1)
    let snapshot = a
    b.round([a, c], at: 2)
    b.local["k"] = "v2"
    b.round([a, c], at: 5_000)
    a.round([b, c], at: 6_000)
    var restored = snapshot
    restored.own = a.own
    restored.round([b, c], at: 7_000)
    #expect(restored.local == ["k": "v2"])
  }

  /// 第一次合的去重只对活着的版本：文件夹里那版已经被改掉 / 删掉，本机同样内容的那条留着
  @Test func joiningDedupesOnlyAgainstLiveVersions() {
    var a = Mac("A")
    var b = Mac("B")
    a.local = ["r": "foo", "s": "bar"]
    a.round([b], at: 1)
    b.round([a], at: 2)
    a.local["r"] = "改掉了"
    a.local["s"] = nil
    a.round([b], at: 3)
    var j = Mac("J", joining: true)
    j.local = ["j1": "foo", "j2": "bar"]
    j.round([a, b], at: 4)
    #expect(j.local["j1"] == "foo" && j.local["j2"] == "bar" && j.local["r"] == "改掉了")
  }

  /// 两种写法的同一个字（合成的 é 和 e + 组合重音）：合完稳定，不来回改
  @Test func unicodeSpellingsSettle() {
    var a = Mac("A")
    var b = Mac("B")
    a.local["k"] = "caf\u{E9}"
    b.local["k"] = "cafe\u{301}"
    a.round([b], at: 1)
    b.round([a], at: 2)
    a.round([b], at: 3)
    b.round([a], at: 4)
    let clock = a.ledger?.entries["k"]?.clock
    #expect(a.round([b], at: 5).changes.isEmpty && b.round([a], at: 6).changes.isEmpty)
    #expect(a.ledger?.entries["k"]?.clock == clock, "钟不再涨")
  }

  /// 设置第一次合（adopt）：文件夹里那几项都被删了（还剩一台的旧文件），本机那几项回到默认，但不误报刹车
  @Test func adoptDoesNotTripTheBrake() {
    var a = Mac("A")
    var old = Mac("O")
    a.local = Dictionary(uniqueKeysWithValues: (0..<10).map { ("k\($0)", "\($0)") })
    a.round([old], at: 1)
    old.round([a], at: 2)
    a.local = ["k0": "0"]
    a.round([old], at: 3)
    var j = Mac("J", joining: true)
    j.local = Dictionary(uniqueKeysWithValues: (0..<15).map { ("k\($0)", "本机 \($0)") })
    let outcome = j.round([a, old], at: 4, join: .adopt)
    #expect(j.local == ["k0": "0"] && outcome.trashing == 0)
  }

  /// 自己那份读不出来、账本还在：照常合，本机改的用没用过的次数；本机自己删一大批时数出来（执行层先问）
  @Test func unreadableOwnFileAndErasingCount() {
    var a = Mac("A")
    var b = Mac("B")
    a.local = ["1": "一", "2": "二", "3": "三"]
    a.round([b], at: 1)
    b.round([a], at: 2)
    a.local["1"] = "一改"
    a.round([b], at: 3, ownUnreadable: true)
    #expect(a.ledger?.entries["1"]?.clock == ["A": 2])
    a.local = [:]
    let outcome = a.round([b], at: 4)
    #expect(outcome.erasing == 3)
  }
}
