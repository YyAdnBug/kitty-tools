// 常驻缩略图和晾衣绳共用的面板（第五轮体检 A3：原来只能用鼠标，读屏用户也只有自定义动作）：指针停在卡片上时临时当 key
// 接键盘（⌘C 拷贝、⌘S 存储、Esc 关），移开就还回去。无边框窗口默认当不了 key，所以子类化（mac-overlay-panel §1 的例外，
// 同刘海岛的 IslandPanel）；不激活本 App、前台 App 不变。
// 什么时候拿（takesKeyboard，评审：一移上就拿会让前台 App 丢一个键、打断输入法组字）：指针在卡片上停够 dwell、指针下面
// 真是这扇窗口（没被别的窗口盖着）、最近 quiet 里没按过键（人正在别处打字时不拿）、键盘不在本 App 自己的别的窗口里
// （翻译浮窗失焦就收起，人可能正在剪贴板面板 / 设置 / 便签里打字）、调用方说这时候可以（卡片在滑走、绳子在收就不行）。
// 拿着键盘时按键全归 onKey、不进响应链（不让 ⌘Q 退出本 App、⌘, 开设置）；onKey 不认的那一下吞掉，接着把键盘还回去。
// 收起（orderOut / close）、划词取词发 ⌘C 之前（releaseAll）都先还。

import AppKit
import Carbon.HIToolbox

final class HoverKeyPanel: NSPanel {
  /// 拿着键盘时的按键；认得的返回 true
  var onKey: ((NSEvent) -> Bool)?
  /// 这时候能不能拿（调用方给：卡片在滑走、绳子收着 / 在淡出时不行）
  var allowsKeyboard: () -> Bool = { true }
  private var keyable = false
  /// 停够 dwell 再拿：指针停在卡片上时每隔 dwell 看一次条件
  private var waiting: Task<Void, Never>?

  /// 指针停多久才拿
  static let dwell = Duration.seconds(0.4)
  /// 最近这么久里按过键就不拿（人正在别处打字）
  nonisolated static let quiet: TimeInterval = 1

  override var canBecomeKey: Bool { keyable }
  override var canBecomeMain: Bool { false }

  /// 指针移上卡片 / 离开（调用方报）：停着时每隔 dwell 看一次能不能拿（takesKeyboard），离开就还
  func pointer(inside: Bool) {
    waiting?.cancel()
    waiting = nil
    guard inside else { return releaseKeyboard() }
    waiting = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.dwell)
        guard !Task.isCancelled, let self else { return }
        if self.mayTake() { return self.takeKeyboard() }
      }
    }
  }

  /// 拿键盘的条件（纯函数，配单测）：调用方允许、指针下面就是这扇窗口、最近 quiet 里没按过键、键盘不在本 App 别的窗口里
  nonisolated static func takesKeyboard(
    allowed: Bool, underPointer: Bool, secondsSinceKey: TimeInterval, keyboardInOwnWindow: Bool
  ) -> Bool {
    allowed && underPointer && secondsSinceKey >= quiet && !keyboardInOwnWindow
  }

  private func mayTake() -> Bool {
    Self.takesKeyboard(
      allowed: isVisible && allowsKeyboard(),
      underPointer: NSWindow.windowNumber(
        at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == windowNumber,
      secondsSinceKey: CGEventSource.secondsSinceLastEventType(
        .combinedSessionState, eventType: .keyDown),
      keyboardInOwnWindow: NSApp.keyWindow.map { !($0 is HoverKeyPanel) } ?? false)
  }

  /// 当 key（不激活本 App）。第一响应者给窗口自己，按钮上不出焦点环、空格不按到按钮
  private func takeKeyboard() {
    guard !keyable else { return }
    keyable = true
    makeKey()
    makeFirstResponder(nil)
  }

  /// 指针移开、卡片收走、按了不认的键：还键盘。本 App 不在前台（键盘本来在别的 App 里）就 deactivate 一次——不激活的面板
  /// 不当 key 之后 AppKit 会把 key 交给本进程别的面板、一直不放（同 Island.releaseKeyboard、NoteFloats.returnKeyboard）
  func releaseKeyboard() {
    waiting?.cancel()
    waiting = nil
    guard keyable else { return }
    keyable = false
    if isKeyWindow, !NSApp.isActive { NSApp.deactivate() }
  }

  /// 所有拿着键盘的都还掉（划词取词发合成 ⌘C 之前：不然 ⌘C 落到卡片上，拷的是截图）
  static func releaseAll() {
    for case let panel as HoverKeyPanel in NSApp.windows { panel.releaseKeyboard() }
  }

  /// 被别的窗口拿走了（点了别的 App、挪到了另一张卡片、截图遮罩来了）：不再拿着，也不用还
  override func resignKey() {
    super.resignKey()
    keyable = false
  }

  /// 收起之前先还（还当着 key 就收起的话，AppKit 会把 key 交给本进程别的面板）
  override func orderOut(_ sender: Any?) {
    releaseKeyboard()
    super.orderOut(sender)
  }

  override func close() {
    releaseKeyboard()
    super.close()
  }

  override func sendEvent(_ event: NSEvent) {
    guard keyable, event.type == .keyDown else { return super.sendEvent(event) }
    take(event)
  }

  /// 带 ⌘ 的组合先到这里（不然主菜单的 ⌘Q、⌘, 会接走）
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard keyable, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
    take(event)
    return true
  }

  private func take(_ event: NSEvent) {
    if onKey?(event) != true { releaseKeyboard() }
  }

  /// 按键 → 卡片上的哪个动作：⌘C 拷贝、⌘S 存储、Esc 关（C、S 按打出来的字认，同各面板的 HotKey.keyCode(_:typing:)：换了键盘布局
  /// 也对、俄文这类布局退回键位；Esc 按键位）。key 是 NSEvent.shortcutCharacters。空格不接：
  /// 现有动作里没有「快速查看」，拿去「用默认 App 打开」不对。纯函数，配单测
  static func command(key: String, keyCode: Int, flags: NSEvent.ModifierFlags) -> ShelfCard.Command?
  {
    let flags = flags.intersection([.command, .control, .option, .shift])
    if keyCode == kVK_Escape { return flags.isEmpty ? .close : nil }
    guard flags == .command else { return nil }
    return switch HotKey.keyCode(keyCode, typing: key) {
    case kVK_ANSI_C: .copy
    case kVK_ANSI_S: .save
    default: nil
    }
  }

  static func command(for event: NSEvent) -> ShelfCard.Command? {
    command(
      key: event.shortcutCharacters ?? "", keyCode: Int(event.keyCode),
      flags: event.modifierFlags)
  }
}
