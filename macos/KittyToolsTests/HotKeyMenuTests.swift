// 本 App 的菜单开着时按全局热键：菜单马上收起、热键照常触发（HotKeyCenter.watch）。按需启用：
// 会在鼠标处弹一个真菜单、发一次合成按键 ⌃⌥⇧⌘F19（只注册这一个组合，被自己的热键吞掉），要「辅助功能」授权：
//   TEST_RUNNER_KITTY_LIVE_HOTKEY=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test '-only-testing:KittyToolsTests/HotKeyMenuTests/hotKeyClosesOpenMenu()'
// 同一个开关还跑 escapeGoesToOwnKeyPanel()：录屏倒数的临时 Esc，屏外面板短暂 makeKey、发两次合成 Esc（都被自己的热键吞掉）
import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct HotKeyMenuTests {
  nonisolated private static let enabled =
    ProcessInfo.processInfo.environment["KITTY_LIVE_HOTKEY"] != nil

  private final class Times {
    var pressed: Date?
    var fired: Date?
    var rescued = false
  }

  @Test(.enabled(if: enabled)) func hotKeyClosesOpenMenu() throws {
    try #require(CGPreflightPostEventAccess(), "要「辅助功能」授权才能发合成按键")
    // 只注册 ⌃⌥⇧⌘F19：参数域覆盖，不写真实偏好
    let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var domain = saved
    let f19 = HotKey(
      keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey))
    for action in HotKeyAction.allCases {
      domain["hotkey." + action.rawValue] =
        action == .clipboard ? try JSONEncoder().encode(f19) : Data()
    }
    UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
    let times = Times()
    let center = HotKeyCenter()
    center.setHandler(for: .clipboard) { times.fired = .now }
    center.reload()
    defer { center.suspend() }
    try #require(center.bindings.count == 1)

    let menu = NSMenu()
    menu.addItem(withTitle: "热键自检", action: nil, keyEquivalent: "")
    // 菜单跟踪期间只有 common 模式的定时器会跑
    let press = Timer(timeInterval: 0.3, repeats: false) { _ in
      MainActor.assumeIsolated {
        Self.pressF19()
        times.pressed = .now
      }
    }
    let rescue = Timer(timeInterval: 2.5, repeats: false) { _ in
      MainActor.assumeIsolated {
        times.rescued = true
        menu.cancelTracking()
      }
    }
    RunLoop.main.add(press, forMode: .common)
    RunLoop.main.add(rescue, forMode: .common)
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    let closed = Date.now
    press.invalidate()
    rescue.invalidate()
    // 菜单要在按键之后才收起，否则根本没测到「菜单开着时按」（比如鼠标把菜单点掉了）
    let pressed = try #require(times.pressed, "菜单在按键之前就收起了")
    // 同步测试挡住了 NSApp.run：自己取事件、派发（热键以 systemDefined 事件经 sendEvent 到）
    let end = Date.now.addingTimeInterval(0.5)
    while Date.now < end, times.fired == nil {
      if let event = NSApp.nextEvent(
        matching: .any, until: .now.addingTimeInterval(0.02), inMode: .default, dequeue: true)
      {
        NSApp.sendEvent(event)
      }
    }
    #expect(!times.rescued, "菜单没有因为热键收起")
    let fired = try #require(times.fired, "热键没有触发")
    #expect(closed.timeIntervalSince(pressed) < 0.2)
    #expect(fired.timeIntervalSince(pressed) < 0.25)
  }

  /// 录屏倒数的临时 Esc（registerEscape）：本 App 自己的面板拿着键盘时 Esc 照常交给它、不取消倒数；没有自家面板是 key
  /// （别的 App 在前台）时才回调
  @Test(.enabled(if: enabled)) func escapeGoesToOwnKeyPanel() throws {
    try #require(CGPreflightPostEventAccess(), "要「辅助功能」授权才能发合成按键")
    let center = HotKeyCenter()
    let times = Times()
    try #require(center.registerEscape { times.fired = .now }, "Esc 没注册上")
    defer { center.unregisterEscape() }
    // 屏外、无边框、不激活本 App 的面板（同截图遮罩、剪贴板面板）：键盘短暂归它
    let panel = KeyPanel(
      contentRect: CGRect(x: -20000, y: -20000, width: 80, height: 40),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let view = EscapeView()
    panel.contentView = view
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.makeFirstResponder(view)
    defer { panel.orderOut(nil) }
    #expect(NSApp.keyWindow === panel)
    Self.press(kVK_Escape)
    Self.pump { view.escapes > 0 || times.fired != nil }
    #expect(view.escapes == 1 && times.fired == nil, "自家面板是 key 时 Esc 没交给它")
    // 面板收起、键盘回到前台 App：这一下是取消倒数
    panel.orderOut(nil)
    Self.press(kVK_Escape)
    Self.pump { times.fired != nil }
    #expect(times.fired != nil && view.escapes == 1, "没有自家面板是 key 时 Esc 没回调")
  }

  private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
  }

  private final class EscapeView: NSView {
    var escapes = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
      if Int(event.keyCode) == kVK_Escape { escapes += 1 }
    }
  }

  /// 同步测试挡住了 NSApp.run：自己取事件、派发，最多 0.5 s
  private static func pump(until done: () -> Bool) {
    let end = Date.now.addingTimeInterval(0.5)
    while Date.now < end, !done() {
      if let event = NSApp.nextEvent(
        matching: .any, until: .now.addingTimeInterval(0.02), inMode: .default, dequeue: true)
      {
        NSApp.sendEvent(event)
      }
    }
  }

  private static func press(_ key: Int) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
      CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)?
        .post(tap: .cghidEventTap)
    }
  }

  /// 合成 ⌃⌥⇧⌘F19：F 键要带 fn 标志才会被认成热键（实测）
  private static func pressF19() {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_F19), keyDown: down)
      event?.flags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]
      event?.post(tap: .cghidEventTap)
    }
  }
}
