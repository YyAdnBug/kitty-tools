// 截图时的快捷键（2026-11-06 拍板 A）：默认的那一套、存法（和默认一样删键、清除存空数据）、按键对哪个动作、固定的键和
// 重复的不收、和全局快捷键一样的不收；设置导出 / 导入带上它们（shot.<名字>），固定的、重复的读文件时丢掉。只用临时偏好域。

import Carbon.HIToolbox
import Foundation
import Testing

@testable import KittyTools

struct ShotKeysTests {
  private func suite() throws -> (UserDefaults, String) {
    let name = "ShotKeysTests-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
  }

  @Test func defaultsAreTheOldFixedKeys() {
    #expect(
      ShotKey.tools.map(\.defaultKey.display) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    #expect(ShotKey.tools.compactMap(\.tool) == Annotation.Tool.allCases)
    let others = Dictionary(
      uniqueKeysWithValues: ShotKey.others.map { ($0, $0.defaultKey.display) })
    #expect(others[.copy] == "⌘C" && others[.save] == "⌘S" && others[.saveAs] == "⇧⌘S")
    #expect(others[.undo] == "⌘Z" && others[.redo] == "⇧⌘Z")
    #expect(others[.pin] == "T" && others[.scroll] == "S" && others[.recognize] == "O")
    #expect(others[.record] == "R" && others[.lastRegion] == "D" && others[.pickColor] == "C")
    // 默认的二十一个键互不重复，也都不是固定的键
    let all = ShotKey.allCases.map(\.defaultKey)
    #expect(Set(all).count == all.count)
    #expect(all.allSatisfy(ShotKey.isUsable))
  }

  @Test func storingAndMatching() throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(ShotKey.toolsAreDefault(in: defaults))
    let rKey = HotKey(keyCode: kVK_ANSI_R, modifiers: 0)
    #expect(ShotKey.matching(rKey, in: defaults) == .record)
    // 矩形改成 R、录屏清掉
    ShotKey.record.set(nil, in: defaults)
    ShotKey.rectangle.set(rKey, in: defaults)
    #expect(ShotKey.record.key(in: defaults) == nil)
    #expect(ShotKey.matching(rKey, in: defaults) == .rectangle)
    #expect(ShotKey.matching(HotKey(keyCode: kVK_ANSI_1, modifiers: 0), in: defaults) == nil)
    #expect(!ShotKey.toolsAreDefault(in: defaults))
    // 改回默认：删掉这个键（回到「没存过」）
    ShotKey.rectangle.set(ShotKey.rectangle.defaultKey, in: defaults)
    #expect(defaults.object(forKey: ShotKey.rectangle.prefsKey) == nil)
    #expect(ShotKey.toolsAreDefault(in: defaults))
    // 带修饰键的也行：⇧ 是区分的
    let optionOne = HotKey(keyCode: kVK_ANSI_1, modifiers: optionKey)
    ShotKey.pin.set(optionOne, in: defaults)
    #expect(ShotKey.matching(optionOne, in: defaults) == .pin)
    #expect(ShotKey.matching(HotKey(keyCode: kVK_ANSI_T, modifiers: shiftKey), in: defaults) == nil)
  }

  @Test func reservedDuplicatesAndGlobalsAreRefused() throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    for (code, modifiers) in [
      (kVK_Escape, 0), (kVK_Return, 0), (kVK_Delete, 0), (kVK_Tab, 0), (kVK_Space, 0),
      (kVK_LeftArrow, cmdKey), (kVK_DownArrow, optionKey), (kVK_ANSI_D, cmdKey),
      (kVK_ANSI_0, cmdKey), (kVK_ANSI_1, cmdKey), (kVK_ANSI_Minus, cmdKey), (kVK_Command, 0),
    ] {
      let hotKey = HotKey(keyCode: code, modifiers: modifiers)
      #expect(ShotKey.isReserved(hotKey), "\(hotKey.display)")
      #expect(ShotKey.problem(with: hotKey, for: .pin, in: defaults)?.contains("另有用处") == true)
    }
    // 截图里重复：T 是钉图的
    #expect(
      ShotKey.problem(
        with: HotKey(keyCode: kVK_ANSI_T, modifiers: 0), for: .rectangle, in: defaults)
        == "和截图里的「钉到屏幕」重复")
    // 自己原来的键不算重复
    #expect(
      ShotKey.problem(with: HotKey(keyCode: kVK_ANSI_T, modifiers: 0), for: .pin, in: defaults)
        == nil)
    // 和全局快捷键一样（截图的默认 ⌥A）
    let optionA = HotKey(keyCode: kVK_ANSI_A, modifiers: optionKey)
    #expect(ShotKey.problem(with: optionA, for: .pin, in: defaults) == "和全局快捷键「截图」重复")
    // 范围外的修饰键位不收
    #expect(!ShotKey.isUsable(HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(1 << 20))))
  }

  @Test func archiveCarriesShotKeys() throws {
    let (source, sourceName) = try suite()
    defer { source.removePersistentDomain(forName: sourceName) }
    let optionP = HotKey(keyCode: kVK_ANSI_P, modifiers: optionKey)
    ShotKey.pin.set(optionP, in: source)
    ShotKey.record.set(nil, in: source)
    let archive = SettingsArchive.capture(
      from: source, domainName: sourceName, services: [], notes: [], version: "9.9.9",
      now: Date(timeIntervalSince1970: 1_760_000_000))
    #expect(archive.hotkeys?["shot.pin"] == .some(optionP))
    #expect(archive.hotkeys?["shot.record"] == .some(nil))
    #expect(archive.hotkeys?["shot.copy"] == nil)

    // 读文件：固定的键（Esc）、截图里重复的（第二个 ⌥P）丢掉，别的照收
    var file = archive
    file.hotkeys?["shot.copy"] = HotKey(keyCode: kVK_Escape, modifiers: 0)
    file.hotkeys?["shot.save"] = optionP
    let read = try SettingsArchive.read(file.encoded())
    #expect(read.hotkeys?["shot.copy"] == nil)
    #expect(
      read.hotkeys?["shot.pin"] == .some(optionP) || read.hotkeys?["shot.save"] == .some(optionP))
    #expect(
      !(read.hotkeys?["shot.pin"] == .some(optionP) && read.hotkeys?["shot.save"] == .some(optionP))
    )

    // 导入：整类换成文件里的样子，本机改过、文件里没有的回到默认
    let (target, targetName) = try suite()
    defer { target.removePersistentDomain(forName: targetName) }
    ShotKey.undo.set(HotKey(keyCode: kVK_ANSI_U, modifiers: 0), in: target)
    try SettingsArchive.read(archive.encoded()).apply(
      [.hotkeys], to: target, domainName: targetName)
    #expect(ShotKey.pin.key(in: target) == optionP)
    #expect(ShotKey.record.key(in: target) == nil)
    #expect(ShotKey.undo.key(in: target) == ShotKey.undo.defaultKey)
  }
}
