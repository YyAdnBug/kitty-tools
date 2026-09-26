// 快捷键界面的纯函数单测：键帽拆分（速查表 / 录制框 / 引导共用）、注册失败原因（-9868 只在只带 ⌥ 时才是系统限制）、
// 速查表 sheet 的高度放得进设置窗。

import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct ShortcutsTests {
  @Test func keyCaps() {
    #expect(KeyCombo.caps("⇧⌘S") == ["⇧", "⌘", "S"])
    #expect(KeyCombo.caps("⌥空格") == ["⌥", "空格"])
    #expect(KeyCombo.caps("⌘1–9") == ["⌘", "1–9"])
    #expect(KeyCombo.caps("⌘-") == ["⌘", "-"])
    #expect(KeyCombo.caps("⌘方向键") == ["⌘", "方向键"])
    #expect(KeyCombo.caps("⌥⇧") == ["⌥", "⇧"])  // 录制中只按着修饰键
    #expect(KeyCombo.caps("Esc") == ["Esc"])
    #expect(KeyCombo.caps("↑↓") == ["↑↓"])
    #expect(KeyCombo.caps("") == [])
  }

  @Test func failureMessages() {
    let optionC = HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey)
    let optionShiftC = HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey | shiftKey)
    let commandShiftI = HotKey(keyCode: kVK_ANSI_I, modifiers: cmdKey | shiftKey)
    let internalError = OSStatus(eventInternalErr)
    #expect(HotKeyCenter.failureMessage(internalError, hotKey: optionC).contains("只带 ⌥"))
    #expect(HotKeyCenter.failureMessage(internalError, hotKey: optionShiftC).contains("只带 ⌥"))
    #expect(!HotKeyCenter.failureMessage(internalError, hotKey: commandShiftI).contains("只带 ⌥"))
    #expect(
      HotKeyCenter.failureMessage(OSStatus(eventHotKeyExistsErr), hotKey: commandShiftI)
        .contains("重复"))
  }

  /// 速查表每组至少一行、组名不重复（ForEach 按组名当 id）
  @Test func cheatSheetGroups() {
    let titles = ShortcutsSheet.groups.map(\.title)
    #expect(Set(titles).count == titles.count)
    #expect(ShortcutsSheet.groups.allSatisfy { !$0.entries.isEmpty })
    // 每个全局快捷键都出现在速查表里，且只出现一次
    let globals = ShortcutsSheet.groups.flatMap(\.globals)
    #expect(
      Set(globals) == Set(HotKeyAction.allCases) && globals.count == HotKeyAction.allCases.count)
    // 快捷键页的分组同样一个不漏、不重
    let grouped = HotKeyAction.sections.flatMap(\.actions)
    #expect(
      Set(grouped) == Set(HotKeyAction.allCases) && grouped.count == HotKeyAction.allCases.count)
  }

  /// 速查表 sheet 挂在设置窗工具栏下沿：默认内容 600、最小 460，减去约 52 的工具栏后都放得下，窗口再大也只到 520
  @Test func cheatSheetFitsSettingsWindow() {
    #expect(ShortcutsButton.sheetHeight(available: 600 - 52) <= 600 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 460 - 52) <= 460 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 2000) == 520)
  }
}
