// firstNonNil（2026-11-06 程序坞预览闪退）：每个元素只转一次，转的结果第一次有、第二次没有（程序坞的选中在两次读之间
// 变了）也不出事；对照惰性 compactMap 的 first 会对选中的那个元素再转一次（闪退就出在它第二次转出 nil 时的强制解包）。

import Testing

@testable import KittyTools

struct FirstNonNilTests {
  @Test func readsEachElementOnce() {
    var calls: [Int: Int] = [:]
    var stillThere = true
    let found = [1, 2, 3].firstNonNil { n -> Int? in
      calls[n, default: 0] += 1
      // 读到一次之后就读不到了
      guard n == 2, stillThere else { return nil }
      stillThere = false
      return n * 10
    }
    #expect(found == 20)
    #expect(calls == [1: 1, 2: 1])
    #expect([Int]().firstNonNil { $0 } == nil)
    #expect([1, 3].firstNonNil { $0 % 2 == 0 ? $0 : nil } == nil)
  }

  @Test func lazyCompactMapFirstTransformsTwice() {
    // 只数次数（转出来的结果每次一样，不会走到强制解包）：读了两个元素，却转了不止两次
    var calls = 0
    let found = [1, 2, 3].lazy.compactMap { n -> Int? in
      calls += 1
      return n == 2 ? n : nil
    }.first
    #expect(found == 2)
    #expect(calls > 2)
  }
}
