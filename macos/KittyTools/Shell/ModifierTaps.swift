// 连按两下修饰键（2026-11-06 用户：「按两次 ⌘ 触发启动器」；拍板页 B1–B8 全部按推荐）：
// 只认修饰键自己按下 / 松开的变化（flagsChanged），一个纯状态机，热键中心（全局监听）和录制框（本地监听）各喂一份。
// - 每一下按住不超过 maxHold、第一下松开到第二下按下不超过 maxGap，第二下**松开**时才算（B3：松开那一刻调用方再确认
//   这段时间里没按过别的键、鼠标，避开「单按一下 ⌘ 紧接着 ⌘C」被当成连按）；
// - 不分左右（B4）：看的是设备无关的修饰键位，左 ⌘、右 ⌘ 都是 ⌘；
// - 按着时又按了别的修饰键、fn / 🌐（系统拿它开听写和表情）都作废，要全松开才重新算（B5）。
// 只有 ⌘ ⌥ ⌃ ⇧ 四种（B6）。纯函数，配单测（ModifierTapsTests）。

import AppKit
import Carbon.HIToolbox

struct ModifierTaps {
  /// 能连按的修饰键。HotKey 里记成「这个修饰键自己的键位（左边那个）、不带修饰键位」
  enum Key: CaseIterable {
    case command, option, control, shift

    var flag: NSEvent.ModifierFlags {
      switch self {
      case .command: .command
      case .option: .option
      case .control: .control
      case .shift: .shift
      }
    }

    /// 修饰键自己的键位（左边那个；右边的 kVK_Right… 不用：不分左右）
    var keyCode: Int {
      switch self {
      case .command: kVK_Command
      case .option: kVK_Option
      case .control: kVK_Control
      case .shift: kVK_Shift
      }
    }

    var symbol: String {
      switch self {
      case .command: "⌘"
      case .option: "⌥"
      case .control: "⌃"
      case .shift: "⇧"
      }
    }

    /// 录上之后在那一行下面提醒的一句（B6）：⇧ 是输入法切中英文，别的是系统听写可能占用
    var hint: String {
      self == .shift
        ? "中文输入法里单按 ⇧ 切中英文，连按两下会切过去再切回来"
        : "系统听写可以设成连按这个键，设了的话两边都会响应"
    }
  }

  /// 每一下最多按住多久、两下之间最多隔多久（秒，B2；固定，不放进设置）
  static let maxHold: TimeInterval = 0.3
  static let maxGap: TimeInterval = 0.3

  /// 连按成了：哪个键，第一下是什么时候按下的（调用方拿它确认这段时间里没按过别的键、鼠标）
  struct Tap: Equatable {
    let key: Key
    let since: TimeInterval
  }

  /// 正按着的那一个修饰键和按下的时刻
  private var down: (key: Key, at: TimeInterval)?
  /// 已经按完的第一下（按下、松开的时刻）
  private var first: (key: Key, down: TimeInterval, up: TimeInterval)?
  /// 按乱了（两个修饰键、fn）：全部松开之前什么都不算
  private var spoiled = false

  /// 修饰键变了一次（flags：变化之后按着的；time：事件的时刻，秒，同 NSEvent.timestamp）。连按成了返回它
  mutating func handle(flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Tap? {
    let held = Key.allCases.filter { flags.contains($0.flag) }
    if held.isEmpty {
      defer {
        down = nil
        spoiled = false
      }
      guard !spoiled, let down else { return nil }
      guard time - down.at <= Self.maxHold else {
        first = nil
        return nil
      }
      if let first, first.key == down.key {
        self.first = nil
        return Tap(key: down.key, since: first.down)
      }
      first = (down.key, down.at, time)
      return nil
    }
    guard !spoiled, held.count == 1, !flags.contains(.function) else {
      spoil()
      return nil
    }
    let key = held[0]
    if let down {
      // 同一个键还按着（另一侧也按下 / 松开了一个）：不算新的一下
      if down.key != key { spoil() }
      return nil
    }
    if let first, first.key != key || time - first.up > Self.maxGap { self.first = nil }
    down = (key, time)
    return nil
  }

  private mutating func spoil() {
    spoiled = true
    down = nil
    first = nil
  }
}
