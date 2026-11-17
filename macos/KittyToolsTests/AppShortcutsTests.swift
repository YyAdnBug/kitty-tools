// App 快捷键（插件，2026-11-17）的纯函数：菜单项属性还原成快捷键（数据取自本机实测，
// macos/build/research/cheatsheet-plugin-2026-11-17/）、标题收拾、单独按住 ⌘ 的状态机、分组和面板排版。

import AppKit
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
    var hold = CommandHold()
    #expect(hold.handle(flags: .command, at: 1) == .began(1))
    #expect(hold.handle(flags: [.command, .capsLock], at: 1.2) == nil)
    #expect(hold.handle(flags: [], at: 2) == .ended)
    #expect(hold.handle(flags: [], at: 2.1) == nil)
    // ⇧⌘：作废，松开 ⇧ 只剩 ⌘ 也不算，全松开后才重新算
    #expect(hold.handle(flags: [.shift, .command], at: 3) == nil)
    #expect(hold.handle(flags: .command, at: 3.1) == nil)
    #expect(hold.handle(flags: [], at: 3.2) == nil)
    #expect(hold.handle(flags: .command, at: 4) == .began(4))
    // 按着时又按了 ⌥ / 🌐：这一次结束
    #expect(hold.handle(flags: [.command, .option], at: 4.5) == .ended)
    #expect(hold.handle(flags: .command, at: 4.6) == nil)
    #expect(hold.handle(flags: [], at: 5) == nil)
    #expect(hold.handle(flags: .command, at: 6) == .began(6))
    #expect(hold.handle(flags: [.command, .function], at: 6.2) == .ended)
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
    #expect(one.size.width == AppShortcutsLayout.padding * 2 + AppShortcutsLayout.columnWidth)
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

  @Test func globeIsAModifierCap() {
    #expect(KeyCombo.caps("🌐⌃F") == ["🌐", "⌃", "F"])
    #expect(KeyCombo.caps("🎤") == ["🎤"])
    #expect(KeyCombo.caps("⌃⇧F7") == ["⌃", "⇧", "F7"])
  }
}
