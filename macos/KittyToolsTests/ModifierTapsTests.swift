// 连按两下修饰键（2026-11-06 拍板 B）：状态机认哪些算、哪些不算（按住太久、隔太久、换了键、两个修饰键、fn、第二下按下时不算、
// 不分左右）；快捷键里怎么记、怎么显示、导入 / 同步认不认（isUsable）、查重。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct ModifierTapsTests {
  /// 按一串（修饰键, 时刻）喂进去，返回每一步的结果
  private func run(_ steps: [(NSEvent.ModifierFlags, TimeInterval)]) -> [ModifierTaps.Tap?] {
    var taps = ModifierTaps()
    return steps.map { taps.handle(flags: $0.0, at: $0.1) }
  }

  @Test func quickDoubleTapFiresOnSecondRelease() {
    let results = run([([.command], 0), ([], 0.1), ([.command], 0.25), ([], 0.35)])
    // 第二下按下时不算（B3：松开那一刻再算，调用方能确认中间没按别的键）
    #expect(results.dropLast().allSatisfy { $0 == nil })
    #expect(results.last == ModifierTaps.Tap(key: .command, since: 0))
  }

  @Test func eachModifierCounts() {
    for key in ModifierTaps.Key.allCases {
      let results = run([([key.flag], 1), ([], 1.1), ([key.flag], 1.2), ([], 1.3)])
      #expect(results.last == ModifierTaps.Tap(key: key, since: 1))
    }
  }

  @Test func holdingTooLongOrWaitingTooLongDoesNotCount() {
    // 第一下按住 0.4 秒
    #expect(run([([.option], 0), ([], 0.4), ([.option], 0.5), ([], 0.6)]).last == .some(nil))
    // 第二下按住 0.4 秒
    #expect(run([([.option], 0), ([], 0.1), ([.option], 0.2), ([], 0.6)]).last == .some(nil))
    // 两下隔了 0.4 秒
    #expect(run([([.option], 0), ([], 0.1), ([.option], 0.5), ([], 0.6)]).last == .some(nil))
    // 隔太久的那一下当成新的第一下，再按一下就成
    let results = run([
      ([.option], 0), ([], 0.1), ([.option], 0.5), ([], 0.6), ([.option], 0.7), ([], 0.8),
    ])
    #expect(results.last == ModifierTaps.Tap(key: .option, since: 0.5))
  }

  @Test func differentKeysOrChordsDoNotCount() {
    // ⌘ 一下、⌥ 一下
    #expect(run([([.command], 0), ([], 0.1), ([.option], 0.2), ([], 0.3)]).last == .some(nil))
    // 按着 ⌘ 又按 ⇧（⌘⇧ 组合的开头），全松开前都不算；全松开后重新数
    let chord = run([
      ([.command], 0), ([.command, .shift], 0.05), ([.command], 0.1), ([], 0.12),
      ([.command], 0.2), ([], 0.25),
    ])
    #expect(chord.allSatisfy { $0 == nil })
    // fn / 🌐 混进来不算
    #expect(
      run([
        ([.command], 0), ([.command, .function], 0.05), ([], 0.1), ([.command], 0.2), ([], 0.3),
      ])
      .last == .some(nil))
  }

  @Test func leftAndRightAreTheSameKey() {
    // 左 ⌘ 按着时右 ⌘ 也按下又松开：设备无关的位不变，不算新的一下；两侧交替连按也算（B4 不分左右）
    let results = run([
      ([.command], 0), ([.command], 0.05), ([], 0.1), ([.command], 0.2), ([], 0.3),
    ])
    #expect(results.last == ModifierTaps.Tap(key: .command, since: 0))
  }

  @Test func capsLockAloneIsIgnored() {
    // 大写锁定的位不在四种修饰键里：中途切一下不影响
    let results = run([
      ([.command], 0), ([], 0.1), ([.capsLock], 0.15), ([.command, .capsLock], 0.2),
      ([.capsLock], 0.3),
    ])
    #expect(results.last == ModifierTaps.Tap(key: .command, since: 0))
  }

  @Test func hotKeyStoresDoubleTapAsTheBareModifier() throws {
    let hotKey = HotKey(doubleTap: .command)
    #expect(hotKey.keyCode == UInt32(kVK_Command) && hotKey.modifiers == 0)
    #expect(hotKey.doubleTap == .command)
    #expect(hotKey.display == "⌘⌘")
    #expect(KeyCombo.caps(hotKey.display) == ["⌘", "⌘"])
    #expect(hotKey.keyEquivalent == nil)
    // 导入、同步认它；带了修饰键位的、右侧的键位不认（录的时候统一记左边那个）
    #expect(hotKey.isUsable)
    #expect(HotKey(keyCode: kVK_Command, modifiers: cmdKey).doubleTap == nil)
    #expect(!HotKey(keyCode: kVK_RightCommand, modifiers: 0).isUsable)
    // 普通组合照旧
    #expect(HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey).doubleTap == nil)
    #expect(!HotKey(keyCode: kVK_ANSI_C, modifiers: 0).isUsable)
    // 存成 JSON 还是原来两个字段（旧版本读得出来、只是不认）
    let json = try #require(String(data: JSONEncoder().encode(hotKey), encoding: .utf8))
    #expect(json.contains("\"keyCode\":55") && json.contains("\"modifiers\":0"))
    let decoded = try JSONDecoder().decode(HotKey.self, from: Data(json.utf8))
    #expect(decoded == hotKey)
  }

  @Test func importKeepsDoubleTapsAndDropsRightSideOrChords() throws {
    let json =
      #"{"app": "Kitty Tools", "format": 2, "version": "0.7.3", "exportedAt": "2026-11-06T08:00:00Z", "#
      + #""hotkeys": {"launcher": {"keyCode": 55, "modifiers": 0}, "#
      + #""clipboard": {"keyCode": 54, "modifiers": 0}, "home": {"keyCode": 56, "modifiers": 512}}}"#
    let archive = try SettingsArchive.read(Data(json.utf8))
    #expect(archive.hotkeys == ["launcher": HotKey(doubleTap: .command)])
  }

  @Test func doubleTapHints() {
    #expect(ModifierTaps.Key.shift.hint.contains("中英文"))
    for key in [ModifierTaps.Key.command, .option, .control] {
      #expect(key.hint.contains("听写"))
    }
    #expect(
      HotKeyCenter.failureMessage(
        HotKeyCenter.needsAccessibility, hotKey: HotKey(doubleTap: .option)) == "连按两下要「辅助功能」授权")
  }
}
