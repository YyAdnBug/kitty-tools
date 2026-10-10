// 快捷键界面的纯函数单测：键帽拆分（速查表 / 录制框 / 引导共用）、注册失败原因（-9868 只在只带 ⌥ 时才是系统限制）、
// 速查表 sheet 的高度放得进设置窗、录制时拒绝各 App 通用的编辑键、默认键（输入翻译 ⌥T）。

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
    // 快捷键页、速查表里那一行的名字：只有状态屏另写（它的键默认是先选一个状态，设置里改成直进时是进排在最前面的），
    // 别的就是动作名
    #expect(HotKeyAction.statusScreen.rowTitle(statusEntersFirst: false) == "选一个状态进入")
    #expect(HotKeyAction.statusScreen.rowTitle(statusEntersFirst: true) == "进入排在最前面的状态")
    #expect(
      HotKeyAction.allCases.filter { $0 != .statusScreen }.allSatisfy {
        $0.rowTitle(statusEntersFirst: false) == $0.title
          && $0.rowTitle(statusEntersFirst: true) == $0.title
      })
    // 快捷键页的分组同样一个不漏、不重
    let grouped = HotKeyAction.sections.flatMap(\.actions)
    #expect(
      Set(grouped) == Set(HotKeyAction.allCases) && grouped.count == HotKeyAction.allCases.count)
  }

  /// ⌘C、⇧⌘Z 这类各 App 通用的键设成全局会在所有 App 里失效：录制时拒绝；⌥C、⌘⇧C 照常能录
  @Test func reservedEditKeys() {
    #expect(HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey).isReservedEditKey)
    #expect(HotKey(keyCode: kVK_ANSI_Z, modifiers: cmdKey | shiftKey).isReservedEditKey)
    #expect(HotKey(keyCode: kVK_ANSI_Grave, modifiers: cmdKey).isReservedEditKey)
    #expect(!HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey).isReservedEditKey)
    #expect(!HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | shiftKey).isReservedEditKey)
    #expect(HotKey.reservedEditKeys.count == 12)
  }

  /// 默认键：输入翻译是 ⌥T（体检 A15，和其它功能一样单 ⌥）；默认键互不重复、都不是通用编辑键
  @Test func defaultHotKeys() {
    #expect(
      HotKeyAction.inputTranslate.defaultHotKey == HotKey(keyCode: kVK_ANSI_T, modifiers: optionKey)
    )
    let defaults = HotKeyAction.allCases.compactMap(\.defaultHotKey)
    #expect(Set(defaults).count == defaults.count)
    #expect(defaults.allSatisfy { !$0.isReservedEditKey })
  }

  /// 默认键让给用户自己设的：早先把 ⌥T 手动给了「划词翻译并替换」，输入翻译没设过也不再取默认 ⌥T（免得抢先注册、
  /// 那个动作每次启动都注册失败）；清除过（空数据）照旧是 nil，别的动作没占就照常取默认
  @Test func defaultYieldsToUserBinding() throws {
    let optionT = HotKey(keyCode: kVK_ANSI_T, modifiers: optionKey)
    let optionTData = try JSONEncoder().encode(optionT)
    var stored: [HotKeyAction: Data] = [:]
    #expect(HotKeyAction.inputTranslate.resolve { stored[$0] } == optionT)
    stored[.translateReplace] = optionTData
    #expect(HotKeyAction.inputTranslate.resolve { stored[$0] } == nil)
    #expect(HotKeyAction.translateReplace.resolve { stored[$0] } == optionT)
    // 输入翻译自己存了 ⌥T（两边都存同一个键不该出现，存了就照存的）；清除过的是 nil
    stored[.inputTranslate] = optionTData
    #expect(HotKeyAction.inputTranslate.resolve { stored[$0] } == optionT)
    stored[.inputTranslate] = Data()
    #expect(HotKeyAction.inputTranslate.resolve { stored[$0] } == nil)
    // 被清除的动作不占默认键
    stored = [.translateReplace: Data()]
    #expect(HotKeyAction.inputTranslate.resolve { stored[$0] } == optionT)
  }

  /// 速查表 sheet 挂在设置窗工具栏下沿：默认内容 600、最小 460，减去约 52 的工具栏后都放得下，窗口再大也只到 520
  @Test func cheatSheetFitsSettingsWindow() {
    #expect(ShortcutsButton.sheetHeight(available: 600 - 52) <= 600 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 460 - 52) <= 460 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 2000) == 520)
  }
}
