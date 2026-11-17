// App 快捷键（插件，2026-11-17 拍板「全部按推荐」，PLAN §10「App 快捷键」）：单独按住 ⌘ 一会儿（默认 1 秒，设置里
// 0.6 / 1 / 2 秒），弹出前台 App 菜单里的全部快捷键；松开就收（拍板 D1）。
// - 怎么认「单独按住」：全局 + 本地监听修饰键变化（要辅助功能授权，同连按两下；本地那份让状态机不漏掉在自家面板里松开的
//   修饰键），交给 CommandHold；到点时再确认 ⌘ 还单独按着、这期间没按过键 / 鼠标 / 滚轮（HotKeyCenter.quiet）、鼠标键没按着、
//   指针没挪远、前台还是同一个 App、没切过桌面、调度中心没开（拍板 B2 B3）。本 App 的面板、设置窗拿着键盘时不弹（那里按住 ⌘
//   是 ⌘1–9 键帽）；截图框选、状态屏、启动台开着时不弹（isSuppressed）；前台 App 在「按 App 停用快捷键」名单里停了全部的不弹；
//   别家不激活的面板拿着键盘时不弹（MenuShortcuts 先问键盘在谁身上）。
// - 什么时候读：单独按住 0.3 秒起在主线程外读（MenuShortcuts.read，整次 1 秒封顶），到点时一般已经读完；每次现读、不缓存（拍板 F1）。
// - 面板（TransientPanel 里的 OverlayPanel，用时建、收起两秒后放掉）出来时不拿键盘：按着 ⌘ 再按别的键 = 那个快捷键照常给
//   App，面板收起；松开 ⌘、切了 App / 桌面、点了外面也收。

import AppKit
import Carbon.HIToolbox

final class AppShortcuts {
  /// 按住多久（毫秒）的几档（拍板 B1）
  static let delayChoices = [600, 1000, 2000]
  /// 单独按住多久开始读菜单：过了「⌘ + 键」的正常间隔
  private static let readAfter: Duration = .milliseconds(300)
  /// 作废的事件：按键、鼠标键、滚轮
  private static let breaking: [CGEventType] = [
    .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
  ]
  /// 按着 ⌘ 时指针挪出这么远就作废：按住 ⌘ 去点链接、跳到定义的人不该被盖住（2026-11-17 评审）
  private static let maxDrift: CGFloat = 30

  /// 存的「按住多久」认不出（导入的文件写了别的数）时按 1 秒
  static func delay(_ stored: Any?) -> Int {
    (stored as? Int).flatMap { delayChoices.contains($0) ? $0 : nil } ?? 1000
  }

  /// 此刻不该弹（截图框选、状态屏、启动台开着）
  var isSuppressed: () -> Bool = { false }
  /// 面板收起（空闲回收排一轮）
  var onHide: (() -> Void)?

  private let model = AppShortcutsModel()
  private lazy var panel = TransientPanel { [unowned self] in
    let panel = OverlayPanel(
      size: model.layout.size, firstMouse: true, autoHide: .clickOutside, isPinned: { false },
      content: AppShortcutsView(model: model))
    panel.onHide = { [unowned self] in
      removeKeyMonitor()
      onHide?()
    }
    return panel
  }
  private var hold = CommandHold()
  /// 这一次按住在做的事（等到点）和读菜单；松开、作废时都取消（读菜单在对方 App 的主线程上跑，别白读）
  private var pending: Task<Void, Never>?
  private var reading: Task<MenuReading, Never>?
  private var flagsMonitors: [Any] = []
  /// 面板开着、不拿键盘时看着按键：按了就收（这一下照常到前台 App）
  private var keyMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  /// 切过几次桌面：按下时记一个，到点时对不上就作废
  private var spaceChanges = 0
  private(set) var isRunning = false

  /// 插件添加了：开始看 ⌘（辅助功能授权变了重新挂监听：没授权时挂上的全局监听收不到东西）
  func start() {
    guard !isRunning else { return }
    isRunning = true
    installFlagsMonitor()
    let workspace = NSWorkspace.shared.notificationCenter
    observers = [
      workspace.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.spaceChanges += 1
          self?.dismissPeek()
        }
      },
      workspace.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.dismissPeek() }
      },
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
      ) { [weak self] _ in
        // 系统改授权列表时发（不带是谁）；等一下再读，立刻读可能还是旧的
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(500))
          guard let self, isRunning else { return }
          installFlagsMonitor()
        }
      },
    ]
  }

  /// 插件移除了：摘掉监听、收起面板
  func stop() {
    guard isRunning else { return }
    isRunning = false
    cancelPending()
    hold = CommandHold()
    flagsMonitors.forEach(NSEvent.removeMonitor)
    flagsMonitors = []
    for observer in observers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    observers = []
    panel.panel?.hide()
  }

  private func installFlagsMonitor() {
    flagsMonitors.forEach(NSEvent.removeMonitor)
    hold = CommandHold()
    let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.flagsChanged(event) }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.flagsChanged(event) }
      return event
    }
    flagsMonitors = [global, local].compactMap { $0 }
  }

  private func flagsChanged(_ event: NSEvent) {
    switch hold.handle(flags: event.modifierFlags, at: event.timestamp) {
    case .began(let since): began(since: since)
    case .ended:
      cancelPending()
      dismissPeek()
    case nil: break
    }
  }

  private func cancelPending() {
    pending?.cancel()
    pending = nil
    reading?.cancel()
    reading = nil
  }

  /// 开始单独按住 ⌘：0.3 秒起读菜单，到点再确认一遍、弹出来
  private func began(since: TimeInterval) {
    cancelPending()
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Prefs.appShortcutsHold) as? Bool ?? true,
      let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != getpid(), panel.panel?.isVisible != true
    else { return }
    let delay = Self.delay(defaults.object(forKey: Prefs.appShortcutsDelay))
    let hold = Hold(since: since, app: app, spaces: spaceChanges, mouse: NSEvent.mouseLocation)
    pending = Task { [weak self] in
      try? await Task.sleep(for: Self.readAfter)
      guard let self else { return }
      guard !Task.isCancelled, holding(hold) else { return cancelPending() }
      let reading = Task { await MenuShortcuts.read(pid: app.processIdentifier) }
      self.reading = reading
      let left = Double(delay) / 1000 - (ProcessInfo.processInfo.systemUptime - since)
      if left > 0 { try? await Task.sleep(for: .seconds(left)) }
      guard !Task.isCancelled, holding(hold), !LaunchpadMissionControl.isActive() else {
        return cancelPending()
      }
      let result = await reading.value
      guard !Task.isCancelled, holding(hold), !result.focusedElsewhere else {
        return cancelPending()
      }
      self.reading = nil
      show(result, app: app)
    }
  }

  /// 这一次按住：从什么时候、对着哪个 App、按下时切过几次桌面、指针在哪
  private struct Hold {
    let since: TimeInterval
    let app: NSRunningApplication
    let spaces: Int
    let mouse: NSPoint
  }

  /// 这一次还算数：⌘ 还单独按着，这期间没按过键、鼠标、滚轮，鼠标键没按着（按着 ⌘ 拖东西），指针没挪远，前台还是它，
  /// 没切过桌面，本 App 的窗口没拿着键盘，此刻能弹。别的 App 开着安全输入时（正在输密码）不弹：那时按键不经过全局监听，
  /// 分不清按着 ⌘ 时按没按过别的键
  private func holding(_ hold: Hold) -> Bool {
    let mouse = NSEvent.mouseLocation
    return NSEvent.modifierFlags.intersection([.command, .option, .control, .shift, .function])
      == .command
      && HotKeyCenter.quiet(
        since: hold.since, now: ProcessInfo.processInfo.systemUptime, types: Self.breaking)
      && NSEvent.pressedMouseButtons == 0
      && hypot(mouse.x - hold.mouse.x, mouse.y - hold.mouse.y) <= Self.maxDrift
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == hold.app.processIdentifier
      && spaceChanges == hold.spaces && NSApp.keyWindow == nil
      && HotKeyBlock.rule(for: hold.app.bundleIdentifier, in: HotKeyBlock.stored) != .all
      && Permissions.isAccessibilityTrusted && !IsSecureEventInputEnabled() && !isSuppressed()
  }

  private func show(_ reading: MenuReading, app: NSRunningApplication) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    model.load(
      reading, name: app.localizedName ?? "", icon: app.icon,
      available: screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900))
    let panel = panel.open()
    panel.setContentSize(model.layout.size)
    panel.present(makingKey: false)
    installKeyMonitor()
    Island.announce("\(model.appName)，\(model.count) 个快捷键")
  }

  /// 不拿键盘的面板收起（松开 ⌘、按了键、切了 App / 桌面）；拿着键盘的（以后点了留住的）不动
  private func dismissPeek() {
    guard let panel = panel.panel, panel.isVisible, !panel.isKeyWindow else { return }
    panel.dismiss(byKeyboard: false)
  }

  private func installKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismissPeek() }
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }
}
