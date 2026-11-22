// 保护高位功能键的 HID 编号，以及与系统已有映射一起读写时的范围。

import Testing

@testable import KittyTools

@MainActor
struct KeyRemappingTests {
  @Test func nativeGlobeAndExtendedFunctionKeys() {
    #expect(HIDKey.globe.id == 0xFF_0000_0003)
    #expect(Array(HIDKey.functionKeys.suffix(5).map(\.id)) == Array(0x7_0000_006F...0x7_0000_0073))
    #expect(HIDKey.customID("0x700000073") == HIDKey.functionKeys.last?.id)
    #expect(HIDKey.customID("0x700010073") == nil)
  }

  @Test func writesAndRemovesOnlyOwnedMappings() throws {
    let source = 0x7_0000_0073 as UInt64
    let existing = [0x7_0000_0072 as UInt64: 0x7_0000_0029 as UInt64]
    let globeRule = RemapRule(source: source, target: HIDKey.globe.id)
    let added = try HIDKeyMapping.plan(current: existing, owned: [:], desired: [globeRule])
    #expect(added.owned == [source: HIDKey.globe.id])
    #expect(added.mapping[source] == HIDKey.globe.id)

    let reapplied = try HIDKeyMapping.plan(
      current: existing, owned: added.owned, desired: [globeRule])
    #expect(reapplied.mapping == added.mapping)
    #expect(reapplied.owned == added.owned)

    let removed = try HIDKeyMapping.plan(current: added.mapping, owned: added.owned, desired: [])
    #expect(removed.mapping == existing)

    let externallyChanged = existing.merging([source: 0x7_0000_002B]) { _, new in new }
    let preserved = try HIDKeyMapping.plan(
      current: externallyChanged, owned: added.owned, desired: [])
    #expect(preserved.mapping == externallyChanged)
    #expect(throws: HIDKeyMapping.Failure.self) {
      try HIDKeyMapping.plan(current: externallyChanged, owned: [:], desired: [globeRule])
    }
  }

  /// 闪退、被强退后重开：系统里还留着上一次写的那条，内存里的账是空的——一模一样的认成自己的，移除插件时撤得掉
  @Test func adoptsIdenticalLeftoverAfterRestart() throws {
    let source = 0x7_0000_0073 as UInt64
    let rule = RemapRule(source: source, target: HIDKey.globe.id)
    let other = [0x7_0000_0039 as UInt64: 0x7_0000_0029 as UInt64]
    let leftover = other.merging([source: HIDKey.globe.id]) { _, new in new }
    let adopted = try HIDKeyMapping.plan(current: leftover, owned: [:], desired: [rule])
    #expect(adopted.mapping == leftover)
    #expect(adopted.owned == [source: HIDKey.globe.id])
    let removed = try HIDKeyMapping.plan(current: leftover, owned: adopted.owned, desired: [])
    #expect(removed.mapping == other)
  }
}
