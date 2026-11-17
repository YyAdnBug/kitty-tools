// 「单独按住 ⌘」的状态机（App 快捷键，拍板 B2；纯函数，配单测 AppShortcutsTests）：只看修饰键的变化（flagsChanged），
// 同连按两下（Shell/ModifierTaps.swift）一样不分左右。
// - 只按着 ⌘ 一个修饰键时开始算（began，带按下的时刻）；
// - 按着时又按了别的修饰键、🌐，这一次作废（ended），要全部松开才重新算；
// - 全松开：ended。
// 按着时按过别的键、鼠标、滚轮，前台换了，到点时由调用方查（AppShortcuts：HotKeyCenter.quiet），这里只管修饰键。

import AppKit

struct CommandHold {
  enum Event: Equatable {
    /// 开始单独按住 ⌘（时刻同 NSEvent.timestamp，开机以来的秒数）
    case began(TimeInterval)
    /// 松开了，或者按乱了：这一次不算了
    case ended
  }

  /// 正按着的那一次的开始时刻
  private(set) var since: TimeInterval?
  /// 按乱了：全部松开之前什么都不算
  private var spoiled = false

  /// 修饰键变了一次（flags：变化之后按着的）
  mutating func handle(flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Event? {
    let held = flags.intersection([.command, .option, .control, .shift, .function])
    if held.isEmpty {
      spoiled = false
      guard since != nil else { return nil }
      since = nil
      return .ended
    }
    guard held == .command, !spoiled else {
      spoiled = true
      guard since != nil else { return nil }
      since = nil
      return .ended
    }
    // 两边的 ⌘ 换着按：还是同一次
    guard since == nil else { return nil }
    since = time
    return .began(time)
  }
}
