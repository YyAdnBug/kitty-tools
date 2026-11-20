// 快捷键界面的纯函数单测：键帽拆分（速查表 / 录制框 / 引导共用）、注册失败原因（-9868 只在只带 ⌥ 时才是系统限制）、
// 速查表 sheet 的高度放得进设置窗、录制时拒绝各 App 通用的编辑键、默认键（输入翻译 ⌥T）、安全输入挡哪些组合（issue #27）。

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
    // 功能全开着时的样子（不读宿主 App 的偏好：用户在 Dev 版里关过哪个功能也不影响）
    let all = Set(Feature.allCases)
    let groups = ShortcutsSheet.groups(enabled: all)
    let titles = groups.map(\.id)
    #expect(Set(titles).count == titles.count)
    #expect(groups.allSatisfy { !$0.entries.isEmpty })
    // 每个全局快捷键都出现在速查表里，且只出现一次
    let globals = groups.flatMap(\.globals)
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
    let grouped = HotKeyAction.visibleSections(enabled: all).flatMap(\.actions)
    #expect(
      Set(grouped) == Set(HotKeyAction.allCases) && grouped.count == HotKeyAction.allCases.count)
  }

  /// ⌘C、⇧⌘Z 这类各 App 通用的键设成全局会在所有 App 里失效：录制时拒绝；⌥C、⌘⇧C 照常能录
  /// 安全输入开着时收不到的：只带 ⌥ / ⌥⇧ 的出字的键（字母、数字、符号；macOS 27.0.1 实测 2026-11-16、11-20）；带 ⌘ / ⌃ 的、
  /// 不出字的键（⌥空格、⌥↩、⌥↓、F 键）、连按两下照常。默认键除了启动器的 ⌥空格全是这种
  @Test func secureInputYields() {
    let yields = { (key: Int, modifiers: Int) in
      HotKey(keyCode: key, modifiers: modifiers).yieldsToSecureInput
    }
    #expect(yields(kVK_ANSI_A, optionKey))
    #expect(yields(kVK_ANSI_A, optionKey | shiftKey))
    #expect(yields(kVK_ANSI_1, optionKey))
    #expect(yields(kVK_ANSI_Slash, optionKey))
    #expect(!yields(kVK_Space, optionKey))
    #expect(!yields(kVK_Return, optionKey))
    #expect(!yields(kVK_DownArrow, optionKey))
    #expect(!yields(kVK_ANSI_A, optionKey | controlKey))
    #expect(!yields(kVK_ANSI_A, optionKey | cmdKey))
    #expect(!yields(kVK_ANSI_A, cmdKey | shiftKey))
    #expect(!yields(kVK_F5, optionKey))
    #expect(!HotKey(doubleTap: .option).yieldsToSecureInput)
    let defaults = HotKeyAction.allCases.compactMap { action in
      action.defaultHotKey.map { (action, $0) }
    }
    #expect(!defaults.isEmpty)
    for (action, key) in defaults {
      #expect(key.yieldsToSecureInput == (action != .launcher), "\(action)")
    }
    // 录制框的提示跟着同一个判断走
    #expect(
      HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey)).secureInputHint != nil)
    #expect(HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)).secureInputHint == nil)
    #expect(
      HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey | controlKey)).secureInputHint
        == nil)
  }

  /// 按开着安全输入的 App 给关法：认 bundle id（不分大小写、浏览器和 1Password 认前缀），认不出的说切回那个 App
  @Test func secureInputAdvice() {
    typealias Block = HotKeyCenter.SecureInputBlock
    let holder = { (id: String?) in Block.Holder(bundleID: id) }
    #expect(holder("com.apple.Terminal") == .terminal)
    #expect(holder("com.googlecode.iterm2") == .iTerm)
    #expect(holder("com.google.Chrome") == .browser)
    #expect(holder("com.google.Chrome.canary") == .browser)
    #expect(holder("com.microsoft.edgemac.Dev") == .browser)
    #expect(holder("company.thebrowser.Browser") == .browser)
    #expect(holder("com.1password.1password") == .onePassword)
    #expect(holder("com.agilebits.onepassword7") == .onePassword)
    #expect(holder("com.apple.loginwindow") == .loginWindow)
    #expect(holder("com.tencent.xinWeChat") == .other)
    #expect(holder(nil) == .other)
    let other = Block(holder: "WeChat", bundleID: "com.tencent.xinWeChat")
    #expect(other.advice.contains("WeChat"))
    #expect(other.summary.contains("WeChat"))
    #expect(other.explanation.contains(other.advice))
    let unknown = Block(holder: nil)
    #expect(unknown.advice != other.advice && !unknown.summary.isEmpty)
    #expect(Block(holder: "终端", bundleID: "com.apple.Terminal").advice != other.advice)
  }

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

  /// 速查表左栏按设置页分类：和设置侧栏同序、通用排最后，钉图归截图、录屏录音归录制、刘海岛归刘海岛插件（2026-11-13）、「设置」归通用。
  /// 搜索跨类找：空格分开的词都要对上（组名 + 说明 + 按键），词全在组名里的整组列出，别的只留对上的行
  @Test func cheatSheetSectionsAndSearch() throws {
    let groups = ShortcutsSheet.groups(enabled: Set(Feature.allCases))
    #expect(
      ShortcutsSheet.sections(groups) == [
        .clipboard, .launcher, .translate, .screenshot, .record, .notes, .reminders, .statusScreen,
        .launchpad, .keepAwake, .appShortcuts, .island, .general,
      ])
    #expect(groups.first { $0.title.key == "提醒" }?.page == .reminders)
    func page(_ title: String) -> SettingsPage? { groups.first { $0.title.key == title }?.page }
    #expect(page("钉图") == .screenshot && page("截图 · 框选") == .screenshot)
    #expect(page("录音") == .record && page("系统命令") == .launcher)
    #expect(page("刘海岛") == .island && page("主界面") == .general && page("设置") == .general)

    let pin = ShortcutsSheet.matching(groups, query: "钉")
    let pinGroup = try #require(groups.first { $0.title.key == "钉图" })
    #expect(pin.first { $0.title.key == "钉图" }?.entries == pinGroup.entries)
    #expect(pin.first { $0.title.key == "截图 · 出图" }?.entries.map(\.keys) == [["T"]])
    let menu = ShortcutsSheet.matching(groups, query: "剪贴板 ⌘K")
    #expect(menu.map(\.title.key) == ["剪贴板"])
    #expect(menu.first?.globals.isEmpty == true && menu.first?.entries.count == 1)
    #expect(!ShortcutsSheet.matching(groups, query: "esc").isEmpty)
    #expect(ShortcutsSheet.matching(groups, query: "没有这种键").isEmpty)
    #expect(ShortcutsSheet.matching(groups, query: "  ").count == groups.count)
  }

  /// 速查表 sheet 挂在设置窗工具栏下沿：默认内容 600、最小 460，减去约 52 的工具栏后都放得下，窗口再大也只到 520
  @Test func cheatSheetFitsSettingsWindow() {
    #expect(ShortcutsButton.sheetHeight(available: 600 - 52) <= 600 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 460 - 52) <= 460 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 2000) == 520)
  }
}
