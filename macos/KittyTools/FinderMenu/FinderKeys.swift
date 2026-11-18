// 访达里用 ⌘X 剪切、⌘V 移动（issue #33，2026-11-18 用户「按推荐做」；访达右键插件里的一个开关，Prefs.finderMenuKeys，
// 默认关，设置 › 访达右键「整理文件」；PLAN §10「访达右键」）。访达的「剪切」对文件是灰的，⌘X 在访达里对文件什么都不做：
// - 按给访达的 ⌘X：吞掉，替访达按一下 ⌘C，读出它拷进剪贴板的文件交给 FileMoves.cut（和右键「剪切」是同一个剪切）
// - 剪切还有效时按给访达的 ⌘V：吞掉，改发 ⌥⌘V（访达自己的「移动项目到这里」：撤销、同名的提示、进度都是访达的），忘掉剪切；
//   没剪切、剪切作废了（之后又拷了别的）的 ⌘V 照常粘贴
// **全仓库第四处事件拦截**（mac-overlay-panel §11）。它看得到每一个按键，红线：
// - 只收按下（keyDown），只认只按着 ⌘ 的 X / V；别的键原样放行，不记、不存
// - 只认真正发给访达的：拦截建在会话层「加了注解」的那一点（.cgAnnotatedSessionEventTap），那里的事件带着要送去的进程，
//   等于访达的才管——启动器、别家的搜索框这类不激活的面板浮在访达上时，前台 App 还是访达，键却是发给面板的
//   （实机自检 FinderKeysTests.liveTargetsKeyWindowOwner）
// - 访达里焦点在输入框（改名、搜索、前往文件夹、显示简介）时放行：问访达的辅助功能焦点元素，0.1 秒超时，只在按了 ⌘X / ⌘V
//   时问；问不到也放行
// - ⌘V 只在剪切有效时吞：拦截线程上只看一个标记（armed，FileMoves 剪切 / 忘掉时设），主线程再按剪贴板核一遍，作废了就把
//   ⌘V 原样补发
// - 按下时吞了的键，按住的连发也吞（不然 ⌘V 的连发在移动之后落到访达，变成粘贴）
// - 拦截在**单独的线程**上（同 MediaKeys：主线程卡住时全系统打字不跟着卡），回调里不碰 AppKit；发键、读剪贴板、剪切投回主线程。
//   自己发的键带记号（marker），拦截里认出来放行
// - 被系统停掉就重新打开；回到前台、醒来时整条重建
// - 要「辅助功能」授权（只查不弹框）；没有、建不起来就什么都不做
// ponytail: 按物理键位认 X / V / C（Dvorak 这类布局下是别的键），同 Paster.pasteToFrontmost；真有人用再按布局查键码
// ponytail: ⌘X 之后、替访达拷贝还没回来的那约 0.1 秒里紧接着按的 ⌘V 是普通粘贴

import AppKit
import Carbon.HIToolbox
import Synchronization

@MainActor final class FinderKeys: NSObject {
  /// 认得的两个键
  nonisolated enum Key: Sendable { case cut, paste }

  /// 一条事件怎么办
  nonisolated enum Verdict: Equatable, Sendable {
    /// 原样交出去
    case pass
    /// 吞掉、什么都不做（按住的连发）
    case swallow
    /// 吞掉、照着做
    case act
  }

  /// 剪切还有效（FileMoves 剪切时设、忘掉剪切时清；拦截线程读）。只是让 ⌘V 不用每次都绕主线程：主线程动手前再按剪贴板核一遍
  nonisolated private static let armed = Atomic<Bool>(false)

  nonisolated static func setArmed(_ value: Bool) { armed.store(value, ordering: .relaxed) }

  /// 自己发的键带的记号（CGEvent 的 eventSourceUserData）：拦截认出来放行，不再管
  nonisolated static let marker: Int64 = 0x4B49_5454_5946_4B

  /// 访达
  nonisolated static let finderID = "com.apple.finder"

  /// 拦截线程和主线程共用的：访达的进程号（主线程写、拦截线程读；0 = 没在跑）、动手的回调（投回主线程）
  nonisolated private final class Shared: Sendable {
    let finder = Atomic<Int32>(0)
    let act: @Sendable (Key) -> Void

    init(act: @escaping @Sendable (Key) -> Void) { self.act = act }
  }

  /// 只在拦截线程上用的：拦截的端口（被系统停掉时要拿它重新打开）、按下时吞了的键（它的连发也吞）
  nonisolated private final class Box {
    let shared: Shared
    var port: CFMachPort?
    var held: Key?

    init(shared: Shared) { self.shared = shared }
  }

  /// 拦截线程投回主线程时找到这一份（init 里 self 还不能被闭包拿着）
  private final class Relay {
    weak var keys: FinderKeys?
  }

  private let defaults: UserDefaults
  private weak var island: Island?
  nonisolated private let shared: Shared
  private var thread: Thread?
  /// 授权有、拦截却没建起来过：不每次偏好变化都重试（回到前台、醒来时再试）
  private var gaveUp = false

  init(island: Island, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.island = island
    let relay = Relay()
    shared = Shared { key in Task { @MainActor in relay.keys?.act(key) } }
    super.init()
    relay.keys = self
    // 「辅助功能」授权可能刚变、拦截可能在睡着时被系统停了而通知没到：回到前台、醒来时整条重建
    let centers = [
      (NotificationCenter.default, NSApplication.didBecomeActiveNotification),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
    ]
    for (center, name) in centers {
      center.addObserver(self, selector: #selector(refresh), name: name, object: nil)
    }
    // 访达重开过（进程号变了）：它回到前台时记下新的；按键总是在访达到前台之后
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(appActivated(_:)),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
  }

  @objc private func refresh() {
    gaveUp = false
    stop()
    apply()
  }

  @objc private func appActivated(_ note: Notification) {
    guard
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
      app.bundleIdentifier == Self.finderID
    else { return }
    shared.finder.store(app.processIdentifier, ordering: .relaxed)
  }

  /// 拦截建着没有
  var isRunning: Bool { thread.map { !$0.isFinished } ?? false }

  /// 照偏好和授权起 / 停（启动时、偏好变了时 AppDelegate 调）：没变不动
  func apply() {
    if let thread, thread.isFinished {
      // 线程自己退了 = 拦截没建起来（授权显示有、系统却不给）或者端口失效了：记下，不每次偏好变化都重起
      self.thread = nil
      gaveUp = true
    }
    let added =
      defaults.object(forKey: Feature.finderMenu.prefsKey) as? Bool
      ?? Feature.finderMenu.defaultOn
    let on = added && defaults.bool(forKey: Prefs.finderMenuKeys)
    if !on { gaveUp = false }
    let wanted = on && !gaveUp && Permissions.isAccessibilityTrusted
    if wanted, thread == nil {
      let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderID)
      shared.finder.store(finder.first?.processIdentifier ?? 0, ordering: .relaxed)
      start()
    } else if !wanted {
      stop()
    }
  }

  private func stop() {
    guard let thread else { return }
    thread.cancel()
    perform(#selector(wake), on: thread, with: nil, waitUntilDone: false)
    self.thread = nil
  }

  private func start() {
    let shared = shared
    let thread = Thread {
      let box = Box(shared: shared)
      guard
        let port = CGEvent.tapCreate(
          tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
          eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
          callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = autoreleasepool { FinderKeys.handle(box, type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
          }, userInfo: Unmanaged.passUnretained(box).toOpaque())
      else { return }
      box.port = port
      CFRunLoopAddSource(
        CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
      CGEvent.tapEnable(tap: port, enable: true)
      // 一直转到 stop()（cancel + 往这条线程上排一个 wake 把这一轮转停）；端口失效了（.finished）就退出
      while !Thread.current.isCancelled {
        if CFRunLoopRunInMode(.defaultMode, 3600, false) == .finished { break }
      }
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
      withExtendedLifetime(box) {}
    }
    thread.name = "kitty.finder-keys"
    thread.qualityOfService = .userInteractive
    thread.start()
    self.thread = thread
  }

  /// 在拦截线程上跑：把它这一轮 run loop 转停（线程已经 cancel，随后退出）
  @objc nonisolated private func wake() {
    CFRunLoopStop(CFRunLoopGetCurrent())
  }

  // MARK: 主线程上动手

  private func act(_ key: Key) {
    switch key {
    case .cut: Task { await cut() }
    case .paste: paste()
    }
  }

  /// 替访达按 ⌘C，等它把选中的文件拷进剪贴板（最多 1 秒），交给右键「剪切」那一条路
  private func cut() async {
    let pasteboard = NSPasteboard.general
    let before = pasteboard.changeCount
    Self.press(kVK_ANSI_C, flags: .maskCommand)
    for _ in 0..<20 where pasteboard.changeCount == before {
      try? await Task.sleep(for: .milliseconds(50))
    }
    let files =
      pasteboard.changeCount == before
      ? []
      : pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        as? [URL] ?? []
    // 没选中东西（或者选中的是侧栏这类拷不出文件的）：同访达按灰掉的菜单键，响一声
    guard !files.isEmpty else { return NSSound.beep() }
    FileMoves.cut(files, island: island)
  }

  /// 剪切还有效：让访达自己移过来（⌥⌘V）；作废了（之后又拷了别的）：⌘V 原样补发，照常粘贴
  private func paste() {
    if FileMoves.hasCut {
      Self.press(kVK_ANSI_V, flags: [.maskCommand, .maskAlternate])
    } else {
      Self.press(kVK_ANSI_V, flags: .maskCommand)
    }
    FileMoves.forgetCut()
  }

  /// 按一下键（带记号，拦截认出来放行）：发到会话层，和真的按键一样送到 key 窗口——就是刚才按键的访达
  private static func press(_ key: Int, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
      guard
        let event = CGEvent(
          keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown)
      else { continue }
      event.flags = flags
      event.setIntegerValueField(.eventSourceUserData, value: marker)
      event.post(tap: .cgSessionEventTap)
    }
  }

  // MARK: 拦截线程上

  /// 一条事件来了：吞不吞（true = 吞掉）。只在拦截线程上调
  nonisolated private static func handle(_ box: Box, _ type: CGEventType, _ event: CGEvent) -> Bool
  {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port = box.port { CGEvent.tapEnable(tap: port, enable: true) }
      return false
    }
    let finder = box.shared.finder.load(ordering: .relaxed)
    guard type == .keyDown, finder != 0,
      event.getIntegerValueField(.eventSourceUserData) != marker,
      let key = key(
        code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags),
      target(of: event) == finder
    else { return false }
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let verdict = verdict(
      key: key, isRepeat: isRepeat, held: box.held == key,
      armed: armed.load(ordering: .relaxed), editing: editingText(in: finder))
    switch verdict {
    case .pass:
      if !isRepeat { box.held = nil }
      return false
    case .swallow:
      return true
    case .act:
      box.held = key
      box.shared.act(key)
      return true
    }
  }

  /// 这一下要送去的进程（加了注解的拦截点上才有；别处是 0）
  nonisolated static func target(of event: CGEvent) -> Int32 {
    Int32(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
  }

  /// 访达里此刻焦点在不在输入框里（改名、搜索、前往文件夹、显示简介里的名字和注释）。问不到（超时、没有焦点元素）也当在——
  /// 那时放行，⌘X / ⌘V 照访达原来的样子
  nonisolated static func editingText(in pid: Int32) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.1)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return true }
    var role: CFTypeRef?
    // 上面认过类型
    AXUIElementCopyAttributeValue(value as! AXUIElement, kAXRoleAttribute as CFString, &role)
    return isTextRole(role as? String)
  }

  // MARK: 纯函数（单测锁住）

  /// 只按着 ⌘ 的 X / V（不管大写锁定、fn）；别的组合是 nil
  nonisolated static func key(code: Int64, flags: CGEventFlags) -> Key? {
    guard
      flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskCommand
    else { return nil }
    switch Int(code) {
    case kVK_ANSI_X: return .cut
    case kVK_ANSI_V: return .paste
    default: return nil
    }
  }

  /// 输入框的角色（搜索框是文字框的一种）
  nonisolated static func isTextRole(_ role: String?) -> Bool {
    guard let role else { return true }
    return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
  }

  /// 发给访达的这一下怎么办。held = 这个键按下时被我们吞了（它的连发跟着吞）；armed = 有剪切；editing 只在要动手时才问
  nonisolated static func verdict(
    key: Key, isRepeat: Bool, held: Bool, armed: Bool, editing: @autoclosure () -> Bool
  ) -> Verdict {
    if isRepeat { return held ? .swallow : .pass }
    if key == .paste, !armed { return .pass }
    return editing() ? .pass : .act
  }
}
