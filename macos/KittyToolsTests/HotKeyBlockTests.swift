// 按 App 停用快捷键（2026-11-10，HotKeyBlock）：名单的存法（往返、坏条目、重复、不认识的动作名留着）、此刻停哪些（全部 /
// 只停几个 / 空的当没停）、设置页那一行勾上取消的结果。不读写偏好，全部喂字符串。

import Testing

@testable import KittyTools

struct HotKeyBlockTests {
  @Test func entriesRoundTrip() {
    for entry in ["com.adobe.Photoshop", "com.foo.app|clipboard,launcher", "com.foo.app|"] {
      #expect(HotKeyBlock(entry: entry)?.entry == entry)
    }
    #expect(HotKeyBlock(entry: "com.foo.app")?.actions == nil)
    #expect(HotKeyBlock(entry: "com.foo.app|")?.actions == [])
  }

  @Test func badAndDuplicateEntriesAreDropped() {
    let list = HotKeyBlock.list(["", "|clipboard", "has space", "a.b", "a.b|launcher", "c.d"])
    #expect(list.map(\.bundleID) == ["a.b", "c.d"])
    #expect(list[0].actions == nil)  // 同一个 App 只认第一条
  }

  @Test func ruleForFrontApp() {
    let entries = ["a.all", "b.some|clipboard,screenshot", "c.none|", "d.unknown|fromTheFuture"]
    #expect(HotKeyBlock.rule(for: "a.all", in: entries) == .all)
    #expect(HotKeyBlock.rule(for: "b.some", in: entries) == .only([.clipboard, .screenshot]))
    #expect(HotKeyBlock.rule(for: "c.none", in: entries) == nil)
    #expect(HotKeyBlock.rule(for: "d.unknown", in: entries) == nil)
    #expect(HotKeyBlock.rule(for: "z.other", in: entries) == nil)
    #expect(HotKeyBlock.rule(for: nil, in: entries) == nil)

    let some = HotKeyBlock.Rule.only([.clipboard])
    #expect(some.blocks(.clipboard) && !some.blocks(.launcher) && !some.blocksCommands)
    #expect(HotKeyBlock.Rule.all.blocks(.launcher) && HotKeyBlock.Rule.all.blocksCommands)
  }

  @Test func togglingActions() {
    let shown: [HotKeyAction] = [.clipboard, .launcher, .screenshot]
    let all = HotKeyBlock(bundleID: "a.b")
    // 从「全部」取消一个 = 只停看得见的其余几个，按 allCases 的顺序存
    let fromAll = all.setting(.launcher, blocked: false, shown: shown)
    #expect(fromAll.actions == ["clipboard", "screenshot"])
    #expect(fromAll.blocks(.clipboard) && !fromAll.blocks(.launcher))
    // 不认识的动作名（更新版本加的）原样留着
    let future = HotKeyBlock(bundleID: "a.b", actions: ["fromTheFuture", "screenshot"])
    #expect(
      future.setting(.clipboard, blocked: true, shown: shown).actions
        == ["clipboard", "screenshot", "fromTheFuture"])
    #expect(future.setting(.screenshot, blocked: false, shown: shown).actions == ["fromTheFuture"])
  }

  @Test func scopeTitles() {
    #expect(HotKeyBlockSection.scope(HotKeyBlock(bundleID: "a.b")) == "全部快捷键")
    #expect(
      HotKeyBlockSection.scope(HotKeyBlock(bundleID: "a.b", actions: ["clipboard"])) == "1 个快捷键")
    #expect(HotKeyBlockSection.scope(HotKeyBlock(bundleID: "a.b", actions: [])) == "没有停用的")
  }
}
