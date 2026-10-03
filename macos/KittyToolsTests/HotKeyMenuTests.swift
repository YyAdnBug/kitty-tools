// 本 App 的菜单开着时按全局热键：菜单马上收起、热键照常触发（HotKeyCenter.watch）。按需启用：
// 会在鼠标处弹一个真菜单、发一次合成按键 ⌃⌥⇧⌘F19（只注册这一个组合，被自己的热键吞掉），要「辅助功能」授权：
//   TEST_RUNNER_KITTY_LIVE_HOTKEY=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test '-only-testing:KittyToolsTests/HotKeyMenuTests/hotKeyClosesOpenMenu()'
// 同一个开关还跑 escapeGoesToOwnKeyPanel()：录屏倒数的临时 Esc，屏外面板短暂 makeKey、发两次合成 Esc（都被自己的热键吞掉）
// 和 keyMonitorsMissHotKeysAndSkipOwnKeys()：录屏「显示按键」靠的两条系统行为（热键 keyDown 监听收不到；本进程发的合成按键
// 收得到但带着本进程号），会向前台 App 发一次没注册成热键的 ⌃⌥⇧⌘F19
import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct HotKeyMenuTests {
  nonisolated private static let enabled =
    ProcessInfo.processInfo.environment["KITTY_LIVE_HOTKEY"] != nil

  private final class Times {
    /// 定时器的闭包是 @Sendable，不能直接捕获 NSMenu：经这个主线程隔离的对象拿
    var menu: NSMenu?
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
    times.menu = menu
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
        times.menu?.cancelTracking()
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

  private final class Seen {
    var global: [NSEvent] = []
    var local = 0
    var fired = 0
  }

  /// 录屏「显示按键」（InputOverlay，手测反馈第 2 批）靠的两条系统行为：
  /// 1. 注册成全局热键的组合被 Carbon 吃掉，global / local 的 keyDown 监听都收不到——所以本 App 的快捷键由 AppDelegate 在
  ///    热键触发时补给胶囊，不会显示两次；
  /// 2. 本进程经 CGEvent 发给前台 App 的合成按键（粘贴的 ⌘V 那条路径：combinedSessionState → cgSessionEventTap）global
  ///    监听收得到，事件源的进程号是本进程（发之前改成 0 也会被系统盖回来）——InputOverlay 据此不显示。
  /// 会向前台 App 发一次没注册成热键的 ⌃⌥⇧⌘F19（没人用的组合）；覆盖层的窗口在屏外
  @Test(.enabled(if: enabled)) func keyMonitorsMissHotKeysAndSkipOwnKeys() throws {
    try #require(CGPreflightPostEventAccess(), "要「辅助功能」授权才能发合成按键")
    try #require(Permissions.isAccessibilityTrusted, "要「辅助功能」授权才收得到别的 App 的按键")
    try #require(!NSApp.isActive, "本 App 在前台时按键归它自己，global 监听收不到")
    let seen = Seen()
    let monitors = [
      NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        MainActor.assumeIsolated { if Int(event.keyCode) == kVK_F19 { seen.global.append(event) } }
      },
      NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        MainActor.assumeIsolated { if Int(event.keyCode) == kVK_F19 { seen.local += 1 } }
        return event
      },
    ]
    defer { monitors.compactMap { $0 }.forEach(NSEvent.removeMonitor) }
    let overlay = InputOverlay(
      frame: CGRect(x: -20000, y: -20000, width: 640, height: 200), clicks: false,
      keysBottom: -20000 + 32)
    overlay.present()
    defer { overlay.close() }

    // 1. 只注册 ⌃⌥⇧⌘F19（参数域覆盖，不写真实偏好）再按：热键触发，两个监听都没看到这一下
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
    let center = HotKeyCenter()
    center.setHandler(for: .clipboard) { seen.fired += 1 }
    center.reload()
    defer { center.suspend() }
    Self.pressF19()
    Self.pump { seen.fired > 0 }
    Self.pump { !seen.global.isEmpty || seen.local > 0 }
    #expect(seen.fired == 1, "热键没有触发")
    #expect(seen.global.isEmpty && seen.local == 0, "注册成热键的组合被 keyDown 监听看到了")
    #expect(overlay.keys.tokens.isEmpty)

    // 2. 反注册后同粘贴的 ⌘V 那条路径发给前台 App：global 监听收得到、带着本进程号，覆盖层不显示
    center.suspend()
    for pid in [nil, 0] as [Int64?] {
      seen.global = []
      let source = CGEventSource(stateID: .combinedSessionState)
      for down in [true, false] {
        let event = CGEvent(
          keyboardEventSource: source, virtualKey: CGKeyCode(kVK_F19), keyDown: down)
        event?.flags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]
        if let pid { event?.setIntegerValueField(.eventSourceUnixProcessID, value: pid) }
        event?.post(tap: .cgSessionEventTap)
      }
      Self.releaseModifiers(source, tap: .cgSessionEventTap)
      Self.pump { !seen.global.isEmpty }
      #expect(seen.global.count == 1, "本进程发的合成按键 global 监听没收到")
      #expect(seen.global.allSatisfy(InputOverlay.isSynthesized))
    }
    Self.pump { !overlay.keys.tokens.isEmpty }
    #expect(seen.fired == 1 && seen.local == 0)
    #expect(overlay.keys.tokens.isEmpty && overlay.keysBarFrame == nil, "本进程发的合成按键进了胶囊")
    // 发完不把 ⌃⌥⇧⌘ 留在系统的修饰键状态里
    let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
    #expect(CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: held))
    #expect(CGEventSource.flagsState(.hidSystemState).isDisjoint(with: held))
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
    releaseModifiers(source, tap: .cghidEventTap)
  }

  /// 合成按键带的修饰键会留在系统的修饰键状态里（实测：发完 ⌃⌥⇧⌘F19 没人碰键鼠时 CGEventSource.flagsState 过了
  /// 几分钟还是 ⌃⌥⇧⌘fn，之后从这个状态造的合成 Esc 也带着它们、对不上不带修饰键的临时热键，escapeGoesToOwnKeyPanel
  /// 就不过）：补一个不带修饰键的「松开 ⌘」把状态清掉（实测四个修饰键和 fn 一起清）
  private static func releaseModifiers(_ source: CGEventSource?, tap: CGEventTapLocation) {
    let event = CGEvent(
      keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
    event?.flags = []
    event?.post(tap: tap)
  }
}
