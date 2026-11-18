// 访达里的 ⌘X 剪切、⌘V 移动（FinderKeys，issue #33）：认哪两个键、什么时候吞、什么算输入框。平时的单测不建拦截、不发键。
// 另有一个按需的实机自检 liveTargetsKeyWindowOwner（KITTY_LIVE_FINDER_KEYS=1，要测试宿主有「辅助功能」授权）：
// 在会话层加了注解的那一点建拦截，发两次**合成**的 ⌃⌥⇧⌘F19（带 FinderKeys.marker，拦截自己吞掉，到不了任何 App），看事件上带的
// 「要送去的进程」——第一次是前台 App；第二次先让一块屏幕外的不激活面板当 key（前台 App 不变），应该是本进程。FinderKeys 靠的
// 就是这个：启动器、别家的搜索框浮在访达上时，前台还是访达，键却不是给访达的。**面板当 key 的约半秒里真的按键会落到它上面**，
// 跑之前手离开键盘。最后只读地问一次访达的焦点元素，看它在超时以内回来（grep「finder-keys」）。

import AppKit
import Carbon.HIToolbox
import Synchronization
import Testing

@testable import KittyTools

@MainActor
struct FinderKeysTests {
  /// 只按着 ⌘ 的 X / V；别的修饰键混进来、别的键都不认；大写锁定、fn 不算
  @Test func recognizesOnlyCommandXAndV() {
    #expect(FinderKeys.key(code: Int64(kVK_ANSI_X), flags: .maskCommand) == .cut)
    #expect(FinderKeys.key(code: Int64(kVK_ANSI_V), flags: .maskCommand) == .paste)
    #expect(
      FinderKeys.key(code: Int64(kVK_ANSI_X), flags: [.maskCommand, .maskAlphaShift]) == .cut)
    #expect(
      FinderKeys.key(code: Int64(kVK_ANSI_V), flags: [.maskCommand, .maskSecondaryFn]) == .paste)
    // ⌥⌘V 是访达自己的移动、⌘⇧V 是别的 App 的「粘贴并匹配样式」：都不管
    #expect(FinderKeys.key(code: Int64(kVK_ANSI_V), flags: [.maskCommand, .maskAlternate]) == nil)
    #expect(FinderKeys.key(code: Int64(kVK_ANSI_V), flags: [.maskCommand, .maskShift]) == nil)
    #expect(FinderKeys.key(code: Int64(kVK_ANSI_X), flags: [.maskCommand, .maskControl]) == nil)
    #expect(FinderKeys.key(code: Int64(kVK_ANSI_X), flags: []) == nil)
    #expect(FinderKeys.key(code: Int64(kVK_ANSI_C), flags: .maskCommand) == nil)
  }

  /// ⌘X 不在输入框里就接；⌘V 只在有剪切时接（没剪切时连输入框都不问）；按下时吞了的键，连发也吞
  @Test func verdicts() {
    var asked = 0
    func editing(_ value: Bool) -> Bool {
      asked += 1
      return value
    }
    func verdict(
      _ key: FinderKeys.Key, repeat isRepeat: Bool = false, held: Bool = false, armed: Bool = false,
      editing value: Bool
    ) -> FinderKeys.Verdict {
      FinderKeys.verdict(
        key: key, isRepeat: isRepeat, held: held, armed: armed, editing: editing(value))
    }
    #expect(verdict(.cut, editing: false) == .act)
    #expect(verdict(.cut, editing: true) == .pass)
    #expect(verdict(.paste, armed: true, editing: false) == .act)
    #expect(verdict(.paste, armed: true, editing: true) == .pass)
    #expect(asked == 4)
    #expect(verdict(.paste, editing: false) == .pass)
    #expect(asked == 4)  // 没剪切：不问访达（辅助功能是跨进程的）
    // 连发：按下时吞了的跟着吞（⌘V 移完之后的连发不能落到访达变成粘贴），按下时放行的跟着放行；都不再问
    #expect(verdict(.paste, repeat: true, held: true, editing: false) == .swallow)
    #expect(verdict(.cut, repeat: true, editing: false) == .pass)
    #expect(asked == 4)
  }

  /// 访达里的输入框（改名、搜索、前往文件夹、显示简介）是这几种；列表、图标、分栏这些不是。读不到角色也当输入框（放行）
  @Test func textRoles() {
    for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] {
      #expect(FinderKeys.isTextRole(role), "\(role)")
    }
    for role in [kAXOutlineRole, kAXListRole, kAXGroupRole, kAXScrollAreaRole, kAXBrowserRole] {
      #expect(!FinderKeys.isTextRole(role), "\(role)")
    }
    #expect(FinderKeys.isTextRole(nil))
  }

  // MARK: 实机自检（按需）

  /// 拦截回调里记下带记号的 F19 送去的进程（回调是 C 函数，经 refcon 拿到它）
  private final class Probe: Sendable {
    let targets = Mutex<[Int32]>([])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_FINDER_KEYS"] == "1"))
  func liveTargetsKeyWindowOwner() async throws {
    try #require(Permissions.isAccessibilityTrusted, "测试宿主没有「辅助功能」授权")
    let front = try #require(NSWorkspace.shared.frontmostApplication)
    try #require(front != .current, "测试宿主在前台：换到别的 App 再跑")
    let probe = Probe()
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    let created = CGEvent.tapCreate(
      tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: { _, type, event, refcon in
        guard let refcon, type == .keyDown || type == .keyUp,
          event.getIntegerValueField(.eventSourceUserData) == FinderKeys.marker
        else { return Unmanaged.passUnretained(event) }
        let probe = Unmanaged<Probe>.fromOpaque(refcon).takeUnretainedValue()
        if type == .keyDown {
          probe.targets.withLock { $0.append(FinderKeys.target(of: event)) }
        }
        return nil  // 带记号的都吞掉：到不了任何 App
      }, userInfo: Unmanaged.passUnretained(probe).toOpaque())
    let port = try #require(created, "拦截没建起来")
    let source = CFMachPortCreateRunLoopSource(nil, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    defer {
      CGEvent.tapEnable(tap: port, enable: false)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      CFMachPortInvalidate(port)
      withExtendedLifetime(probe) {}
    }

    func send() async -> Int32? {
      let count = probe.targets.withLock(\.count)
      let flags: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
      for keyDown in [true, false] {
        let event = CGEvent(
          keyboardEventSource: CGEventSource(stateID: .privateState),
          virtualKey: CGKeyCode(kVK_F19), keyDown: keyDown)
        event?.flags = flags
        event?.setIntegerValueField(.eventSourceUserData, value: FinderKeys.marker)
        event?.post(tap: .cgSessionEventTap)
      }
      for _ in 0..<40 where probe.targets.withLock(\.count) == count {
        try? await Task.sleep(for: .milliseconds(25))
      }
      return probe.targets.withLock { $0.count > count ? $0.last : nil }
    }

    // 1. 平常：送去前台 App
    let first = await send()
    // 别的 App 的不激活面板正当着 key 时这里对不上（那正是要分开的情形），失败信息里写是谁
    let firstName = first.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
    #expect(
      first == front.processIdentifier,
      "前台 \(front.localizedName ?? "?") \(front.processIdentifier)，事件上 \(firstName ?? "?") \(first ?? -1)"
    )

    // 2. 不激活的面板当 key：前台还是那个 App，键却是给面板的（本进程）
    let panel = NSPanel(
      contentRect: NSRect(x: -4000, y: -4000, width: 40, height: 40),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.orderFrontRegardless()
    panel.makeKey()
    defer { panel.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(150))
    try #require(panel.isKeyWindow, "面板没当上 key")
    let second = await send()
    #expect(NSWorkspace.shared.frontmostApplication == front)
    #expect(second == getpid(), "本进程 \(getpid())，事件上 \(second ?? -1)")

    // 3. 问访达的焦点元素（只读）：0.1 秒超时，按 ⌘X / ⌘V 时拦截线程上就等这么久
    if let finder = NSRunningApplication.runningApplications(
      withBundleIdentifier: FinderKeys.finderID
    ).first {
      let clock = ContinuousClock()
      var editing = false
      let spent = clock.measure { editing = FinderKeys.editingText(in: finder.processIdentifier) }
      print("finder-keys: 访达焦点在输入框 = \(editing)，问了 \(spent)")
      #expect(spent < .milliseconds(300))
    }
  }
}
