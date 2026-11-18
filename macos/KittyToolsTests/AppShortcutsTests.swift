// App 快捷键（插件，2026-11-17）的纯函数：菜单项属性还原成快捷键（数据取自本机实测，
// macos/build/research/cheatsheet-plugin-2026-11-17/）、标题收拾、单独按住 ⌘ 的状态机、分组和面板排版。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct AppShortcutsTests {
  /// 实测各 App 菜单里的原始属性 → 符号（访达、Xcode、VS Code 里各种键都在）
  @Test func decodesRealMenuItems() {
    func keys(_ char: String?, _ modifiers: Int?, glyph: Int? = nil, virtualKey: Int? = nil)
      -> String?
    {
      MenuShortcuts.keys(char: char, glyph: glyph, virtualKey: virtualKey, modifiers: modifiers)
    }
    #expect(keys("S", 0) == "⌘S")
    #expect(keys("s", nil) == "⌘S")
    #expect(keys(",", 0) == "⌘,")
    #expect(keys("N", 1) == "⇧⌘N")
    #expect(keys("1", 6) == "⌃⌥⌘1")
    // 访达「清倒废纸篓」两条（⌥ 替换项）
    #expect(keys("\u{8}", 1, glyph: 23, virtualKey: 51) == "⇧⌘⌫")
    #expect(keys("\u{8}", 3, glyph: 23, virtualKey: 51) == "⌥⇧⌘⌫")
    // 16 是 🌐：访达「表情与符号」= 24、「填充」= 28、「左右」只有键码 = 29
    #expect(keys("E", 24) == "🌐E")
    #expect(keys("F", 28) == "🌐⌃F")
    #expect(keys("", 29, virtualKey: 123) == "🌐⌃⇧←")
    // 「开始听写」：字形 0x96 是麦克风（头文件里没有）
    #expect(keys("🎤", 8, glyph: 150, virtualKey: 128) == "🎤")
    // 方向键、⇥、F 键（Xcode 单步调试只有 F6）
    #expect(keys("\u{F700}", 0, glyph: 104, virtualKey: 126) == "⌘↑")
    #expect(keys("\u{F700}", 2, glyph: 104, virtualKey: 126) == "⌥⌘↑")
    #expect(keys("\t", 12, glyph: 2, virtualKey: 48) == "⌃⇥")
    #expect(keys("\u{F709}", 8) == "F6")
    #expect(keys("\u{F709}", 12) == "⌃F6")
    #expect(keys("\r", 7) == "⌃⌥⇧⌘↩")
    #expect(keys(" ", 4) == "⌃⌘空格")
    #expect(keys("\u{3}", 0) == "⌘⌤")  // 小键盘的 Enter
    // 没有快捷键、还原不出的
    #expect(keys(nil, nil) == nil)
    #expect(keys("", 0, glyph: 0) == nil)
    #expect(keys("\u{F8FF}", 0) == nil)
    #expect(keys("", 0, virtualKey: 0) == nil)  // 只给了字母的键码：要键盘布局才知道是什么字，不猜
  }

  @Test func cleansTitles() {
    #expect(MenuShortcuts.cleaned("Save As…") == "Save As")
    #expect(MenuShortcuts.cleaned("打开...") == "打开")
    #expect(MenuShortcuts.cleaned("拷贝") == "拷贝")
    #expect(
      MenuShortcuts.bracketed("Keyboard Shortcuts [⌘K ⌘S]")! == ("Keyboard Shortcuts", "⌘K ⌘S"))
    #expect(MenuShortcuts.bracketed("Insiders [beta]") == nil)
    #expect(MenuShortcuts.bracketed("[⌘K]") == nil)
    #expect(MenuShortcuts.bracketed("没有括号") == nil)
  }

  /// 单独按住 ⌘：别的修饰键、🌐 掺进来就作废，全松开才重新算；两边的 ⌘ 换着按还是同一次
  @Test func commandHold() {
    var hold = ModifierHold()
    func handle(_ flags: NSEvent.ModifierFlags, _ time: TimeInterval) -> ModifierHold.Event? {
      hold.handle(flags: flags, at: time, key: .command)
    }
    #expect(handle(.command, 1) == .began(1))
    #expect(handle([.command, .capsLock], 1.2) == nil)
    #expect(handle([], 2) == .ended)
    #expect(handle([], 2.1) == nil)
    // ⇧⌘：作废，松开 ⇧ 只剩 ⌘ 也不算，全松开后才重新算
    #expect(handle([.shift, .command], 3) == nil)
    #expect(handle(.command, 3.1) == nil)
    #expect(handle([], 3.2) == nil)
    #expect(handle(.command, 4) == .began(4))
    // 按着时又按了 ⌥ / 🌐：这一次结束
    #expect(handle([.command, .option], 4.5) == .ended)
    #expect(handle(.command, 4.6) == nil)
    #expect(handle([], 5) == nil)
    #expect(handle(.command, 6) == .began(6))
    #expect(handle([.command, .function], 6.2) == .ended)
  }

  /// 按哪个键能换（2026-11-18）：换成 ⌥ 时只认 ⌥，单按 ⌘ 不算；存的值认不出按 ⌘
  @Test func otherHoldKeys() {
    var hold = ModifierHold()
    #expect(hold.handle(flags: .command, at: 1, key: .option) == nil)
    #expect(hold.handle(flags: [], at: 1.1, key: .option) == nil)
    #expect(hold.handle(flags: .option, at: 2, key: .option) == .began(2))
    #expect(hold.handle(flags: [.option, .shift], at: 2.5, key: .option) == .ended)
    #expect(hold.handle(flags: [], at: 3, key: .option) == nil)
    #expect(hold.handle(flags: .shift, at: 4, key: .shift) == .began(4))
    #expect(hold.handle(flags: [], at: 5, key: .shift) == .ended)
    #expect(hold.handle(flags: .control, at: 6, key: .control) == .began(6))
    #expect(AppShortcuts.holdKey("option") == .option)
    #expect(AppShortcuts.holdKey("shift") == .shift)
    #expect(AppShortcuts.holdKey("fn") == .command)
    #expect(AppShortcuts.holdKey(nil) == .command)
    #expect(AppShortcuts.holdKey(3) == .command)
  }

  /// 按顶层菜单分组：菜单栏里第几个分组（同名的也分开），先后照菜单
  @Test func groupsByTopMenu() {
    func item(_ menu: String, _ bar: Int, _ title: String) -> MenuShortcut {
      MenuShortcut(menu: menu, path: [], title: title, keys: "⌘A", location: [bar, 0])
    }
    let groups = AppShortcutsModel.groups([
      item("文件", 2, "新建"), item("文件", 2, "打开"), item("编辑", 3, "拷贝"), item("编辑", 5, "另一个编辑"),
    ])
    #expect(groups.map(\.id) == [2, 3, 5])
    #expect(groups.map(\.title) == ["文件", "编辑", "编辑"])
    #expect(groups[0].items.map(\.title) == ["新建", "打开"])
  }

  /// 排版：放得下就用最少的列；放不下用最多的列、竖着滚；按先后一列列往下排，列底放不下的卡拆到下一列
  @Test func layout() {
    let screen = NSSize(width: 1470, height: 920)
    let empty = AppShortcutsLayout.make(rows: [], available: screen)
    #expect(empty.size == AppShortcutsLayout.emptySize)
    #expect(empty.columns.isEmpty)

    let one = AppShortcutsLayout.make(rows: [5], available: screen)
    #expect(one.columns == [[AppShortcutsLayout.Segment(group: 0, rows: 0..<5)]])
    // 只有一列时被最窄宽度撑开（顶上那一行放得下），列跟着放宽
    #expect(one.size.width == AppShortcutsLayout.minWidth)
    #expect(one.columnWidth > AppShortcutsLayout.columnWidth)
    #expect(
      one.size.height
        == AppShortcutsLayout.padding * 2 + AppShortcutsLayout.header
        + AppShortcutsLayout.cardHeight(rows: 5))
    #expect(!one.scrolls)

    // 访达那样八组 117 条（一组 30 条）：13 寸屏上多列、一屏放得下，每一行都排上、先后不乱
    let rows = [4, 30, 22, 25, 20, 10, 5, 1]
    let finder = AppShortcutsLayout.make(rows: rows, available: screen)
    #expect(finder.columns.count > 1)
    #expect(!finder.scrolls)
    #expect(finder.size.width <= screen.width * 0.9)
    #expect(finder.size.height <= screen.height * 0.8)
    let segments = finder.columns.flatMap { $0 }
    for (group, count) in rows.enumerated() {
      let parts = segments.filter { $0.group == group }.map(\.rows)
      #expect(parts.first?.lowerBound == 0)
      #expect(parts.last?.upperBound == count)
      #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }
    #expect(segments.map(\.group) == segments.map(\.group).sorted())
    #expect(
      segments.filter(\.continued).allSatisfy { $0.rows.lowerBound >= AppShortcutsLayout.minSplit })

    // Xcode 那样 12 组 214 条：最多列，竖着滚
    let big = AppShortcutsLayout.make(
      rows: Array(repeating: 14, count: 11) + [60], available: screen)
    #expect(big.columns.count == 5)
    #expect(big.scrolls)
    #expect(big.size.height <= screen.height * 0.8)

    let flowed = AppShortcutsLayout.flow([3, 3, 3, 3], into: 2)
    #expect(flowed.columns.map { $0.map(\.group) } == [[0, 1], [2, 3]])
    #expect(flowed.height == AppShortcutsLayout.cardHeight(rows: 3) * 2 + AppShortcutsLayout.gap)
    // 一组 30 条排进两列：拆成两段，第二段接着第一段
    let split = AppShortcutsLayout.flow([30], into: 2)
    #expect(split.columns.count == 2)
    #expect(split.columns[0][0].rows.lowerBound == 0)
    #expect(split.columns[1][0].continued)
    #expect(split.columns[1][0].rows.upperBound == 30)
  }

  /// 实读访达的菜单（按需：TEST_RUNNER_KITTY_LIVE_MENU=1，测试宿主要有辅助功能授权；只读、不点菜单）：主线程外读得出来、
  /// 一秒内读完、有上百条，还原得出 🌐 那几条
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_MENU"] != nil))
  func readsFinderMenus() async throws {
    let finder = try #require(
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    let clock = ContinuousClock()
    let start = clock.now
    let reading = await MenuShortcuts.read(pid: finder.processIdentifier, checksFocus: false)
    let elapsed = clock.now - start
    print("app-shortcuts live: 访达 \(reading.shortcuts.count) 条，\(elapsed)")
    #expect(reading.finished)
    #expect(!reading.unreadable)
    #expect(reading.shortcuts.count > 60)
    #expect(reading.shortcuts.contains { $0.keys.hasPrefix("🌐") })
    #expect(reading.shortcuts.allSatisfy { $0.location.count >= 2 && $0.location[0] > 0 })
  }

  /// 「按住多久」认不出的值（导入的文件写了别的数）按 1 秒
  @Test func delayFallsBackToOneSecond() {
    #expect(AppShortcuts.delay(600) == 600)
    #expect(AppShortcuts.delay(2000) == 2000)
    #expect(AppShortcuts.delay(0) == 1000)
    #expect(AppShortcuts.delay(nil) == 1000)
    #expect(AppShortcuts.delay("1000") == 1000)
  }

  /// 搜索：每个词都对上某个名字的一段，或者首字母缩写的开头（中文认拼音）；没有对上的组整组去掉；
  /// 选中第一条，↑↓ 在看得见的里挪，↩ 执行选中的，Esc 先清空
  @Test func searchAndSelection() {
    func item(_ menu: String, _ bar: Int, _ index: Int, _ title: String, _ keys: String)
      -> MenuShortcut
    {
      MenuShortcut(menu: menu, path: [], title: title, keys: keys, location: [bar, index])
    }
    var reading = MenuReading()
    reading.shortcuts = [
      item("访达", 1, 0, "清倒废纸篓", "⇧⌘⌫"), item("文件", 2, 0, "新建文件夹", "⇧⌘N"),
      item("文件", 2, 1, "移到废纸篓", "⌘⌫"), item("编辑", 3, 0, "拷贝", "⌘C"),
    ]
    let model = AppShortcutsModel()
    model.load(reading, name: "访达", icon: nil, available: NSSize(width: 1470, height: 920))
    var performed: [String] = []
    model.onPerform = { performed.append($0.title) }

    model.search("废纸篓")
    #expect(model.flat.map(\.title) == ["清倒废纸篓", "移到废纸篓"])
    #expect(model.visible.map(\.title) == ["访达", "文件"])
    #expect(model.selection == [1, 0])
    #expect(model.layout.size == model.layout.size)
    model.search("qd")  // 清倒废纸篓的首字母
    #expect(model.flat.map(\.title) == ["清倒废纸篓"])
    model.search("xinjian")  // 新建文件夹的全拼
    #expect(model.flat.map(\.title) == ["新建文件夹"])
    model.search("wenjian")  // 菜单名也算
    #expect(model.flat.map(\.title) == ["新建文件夹", "移到废纸篓"])
    #expect(model.command(#selector(NSResponder.moveDown(_:))))
    #expect(model.selection == [2, 1])
    #expect(model.command(#selector(NSResponder.moveDown(_:))))
    #expect(model.selection == [2, 1])  // 到底了不动
    #expect(model.command(#selector(NSResponder.insertNewline(_:))))
    #expect(performed == ["移到废纸篓"])
    model.search("没有这个")
    #expect(model.visible.isEmpty && model.selection == nil)
    // Esc：先清空，空了交给面板收起
    #expect(model.command(#selector(NSResponder.cancelOperation(_:))))
    #expect(model.query.isEmpty && model.flat.count == 4)
    #expect(!model.command(#selector(NSResponder.cancelOperation(_:))))
    // 留住时按的组合：先看得见的、再全部
    #expect(model.item(forKeys: "⌘C")?.title == "拷贝")
    #expect(model.item(forKeys: "⌘S") == nil)
    // 搜索时面板大小不变
    let opened = model.layout.size
    model.search("拷贝")
    #expect(model.layout.size == opened)
  }

  /// 按键 → 和读出来的同一种写法：方向键、F 键本身带的 fn 位不算 🌐，字母带 fn 才算
  @Test func keysFromEvents() {
    #expect(AppShortcutsModel.keys(keyCode: UInt16(kVK_F6), flags: .function) == "F6")
    #expect(
      AppShortcutsModel.keys(
        keyCode: UInt16(kVK_UpArrow), flags: [.command, .function, .numericPad])
        == "⌘↑")
    #expect(
      AppShortcutsModel.keys(keyCode: UInt16(kVK_ANSI_F), flags: [.function, .control]).hasPrefix(
        "🌐⌃"))
    #expect(AppShortcutsModel.keys(keyCode: UInt16(kVK_Delete), flags: .command) == "⌘⌫")
  }

  /// 留住时交给搜索框的组合：编辑文字、删到行首、⌘ 方向键、⌘W；别的 ⌘ 组合当 App 快捷键
  @Test func textEditingCombosStayInTheField() {
    func edits(_ code: Int, _ flags: NSEvent.ModifierFlags, _ key: String?) -> Bool {
      AppShortcuts.editsText(keyCode: UInt16(code), flags: flags, key: key)
    }
    #expect(edits(kVK_ANSI_A, .command, "a") && edits(kVK_ANSI_V, .command, "v"))
    #expect(edits(kVK_ANSI_Z, [.command, .shift], "Z"))
    #expect(edits(kVK_Delete, .command, nil) && edits(kVK_LeftArrow, [.command, .shift], nil))
    #expect(edits(kVK_ANSI_W, [.command, .capsLock], "w"))
    #expect(!edits(kVK_ANSI_S, .command, "s"))
    #expect(!edits(kVK_ANSI_A, [.command, .shift], "A"))  // ⇧⌘A 是访达的「应用程序」
    #expect(!edits(kVK_Delete, [.command, .option], nil))  // ⌥⌘⌫ 是「立即删除」
  }

  /// 带 ⇧ 才打得出的标点：菜单里是「⌘?」，按键是 ⇧⌘/，两种写法都试
  @Test func shiftedPunctuationCandidates() {
    let slash = AppShortcutsModel.candidates(
      keyCode: UInt16(kVK_ANSI_Slash), flags: [.command, .shift], characters: "?")
    #expect(slash.contains("⌘?"))
    let save = AppShortcutsModel.candidates(
      keyCode: UInt16(kVK_ANSI_S), flags: .command, characters: "s")
    #expect(save.count == 1)
  }

  @Test func globeIsAModifierCap() {
    #expect(KeyCombo.caps("🌐⌃F") == ["🌐", "⌃", "F"])
    #expect(KeyCombo.caps("🎤") == ["🎤"])
    #expect(KeyCombo.caps("⌃⇧F7") == ["⌃", "⇧", "F7"])
  }
}
