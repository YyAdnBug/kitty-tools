// App 快捷键（插件，2026-11-17 拍板「全部按推荐」，PLAN §10「App 快捷键」）：单独按住一个修饰键一会儿（默认 ⌘、1 秒；
// 键能换成 ⌥ ⌃ ⇧——2026-11-18 用户要的，时长 0.6 / 1 / 2 秒），弹出前台 App 菜单里的全部快捷键；松开就收（拍板 D1）。
// 下面说的 ⌘ 都是「按住的那个键」，只有留住时执行的组合（⌘S 这些）是真的 ⌘。
// - 怎么认「单独按住」：全局 + 本地监听修饰键变化（要辅助功能授权，同连按两下；本地那份让状态机不漏掉在自家面板里松开的
//   修饰键），交给 ModifierHold；到点时再确认 ⌘ 还单独按着、这期间没按过键 / 鼠标 / 滚轮（HotKeyCenter.quiet）、鼠标键没按着、
//   指针没挪远、前台还是同一个 App、没切过桌面、调度中心没开（拍板 B2 B3）。本 App 的面板、设置窗拿着键盘时不弹（那里按住 ⌘
//   是 ⌘1–9 键帽）；截图框选、状态屏、启动台开着时不弹（isSuppressed）；前台 App 在「按 App 停用快捷键」名单里停了全部
//   或停了「显示 App 快捷键」的不弹；
//   别家不激活的面板拿着键盘时不弹（MenuShortcuts 先问键盘在谁身上）。
// - 什么时候读：单独按住 0.3 秒起在主线程外读（MenuShortcuts.read，整次 1 秒封顶），到点时一般已经读完；每次现读、不缓存（拍板 F1）。
//   按住的那一刻起另挂一个全局监听（按键、点按、滚轮、指针挪远，watchBreaks）：一有动静就作废这一次、取消在读的菜单
//   （第五轮体检 P1：按着 ⌘ 按 ⌘C、挪鼠标时前台 App 不用再白答一遍整个菜单）。
// - 面板（TransientPanel 里的 OverlayPanel，用时建、收起两秒后放掉）出来时不拿键盘：按着 ⌘ 再按别的键 = 那个快捷键照常给
//   App，面板收起；松开 ⌘、切了 App / 桌面、点了外面也收。
// - 点一行 = 执行它（先收起面板，再对那个菜单项 AXPress，MenuShortcuts.press；拍板 D3）。点一下面板别处（多半是搜索框）=
//   留住：面板拿到键盘（按着 ⌘ 点的，系统不一定给，本地监听自己 makeKey；不激活本 App，前台 App 不变），能搜、↑↓、↩，
//   松开 ⌘ 不收；按列表里有的组合 = 执行那一项，别的 ⌘ 组合只收起（编辑搜索框用的 ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z、⌘⌫ ⌘⌦、
//   ⌘ 加方向键和 ⌘W 照常给搜索框 / 面板）；Esc 先清空搜索再收起；切到别的 App、切桌面也收（拍板 D1 D2）。
// - 快捷键页的「显示 App 快捷键」（默认没设；菜单栏、启动器、主界面里也有这一项）：直接打开成留住的样子（toggle）。

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

  /// 存的「按住哪个键」认不出时按 ⌘
  static func holdKey(_ stored: Any?) -> ModifierTaps.Key {
    (stored as? String).flatMap(ModifierTaps.Key.init(rawValue:)) ?? .command
  }

  /// 此刻设的是哪个键（界面上写「按住 ⌥」这类话、速查表那一行都读它）
  static var currentHoldKey: ModifierTaps.Key {
    holdKey(UserDefaults.standard.object(forKey: Prefs.appShortcutsHoldKey))
  }

  /// 此刻不该弹（截图框选、状态屏、启动台开着）
  var isSuppressed: () -> Bool = { false }
  /// 面板收起（空闲回收排一轮）
  var onHide: (() -> Void)?
  /// 刘海岛上说一句（执行不了、前台是本 App 自己）
  var announce: ((LocalizedStringResource) -> Void)?

  private let model = AppShortcutsModel()
  private lazy var panel = TransientPanel { [unowned self] in
    let panel = OverlayPanel(
      size: model.layout.size, firstMouse: true, autoHide: .clickOutside, isPinned: { false },
      content: AppShortcutsView(model: model))
    panel.onHide = { [unowned self] in
      removeMonitors()
      onHide?()
    }
    panel.keyEquivalentHandler = { [unowned self] event in keyEquivalent(event) }
    model.onPerform = { [unowned self] item in perform(item) }
    // 点开「移动与调整大小」后长高：顶边不动、往下伸（同启动器随结果条数）
    model.onResize = { [weak panel] size in panel?.setContentHeight(size.height, animated: true) }
    return panel
  }
  /// 这一次弹的是哪个 App 的（执行时按它的 pid 找菜单）
  private var shownApp: NSRunningApplication?
  private var hold = ModifierHold()
  /// 这一次按住在做的事（等到点）和读菜单；松开、作废时都取消（读菜单在对方 App 的主线程上跑，别白读）
  private var pending: Task<Void, Never>?
  private var reading: Task<MenuReading, Never>?
  private var flagsMonitors: [Any] = []
  /// 按住期间看着按键、点按、滚轮、指针挪远（P1）：有动静就作废、取消读菜单；松开、作废、弹出来时摘掉
  private var breakMonitor: Any?
  /// 面板开着、不拿键盘时看着按键：按了就收（这一下照常到前台 App）
  private var keyMonitor: Any?
  /// 面板开着时看着点在它上面的鼠标：按着 ⌘ 点的，系统不一定让它当 key，这里自己 makeKey（→ 留住）
  private var clickMonitor: Any?
  /// 快捷键打开时读菜单的那一下：和按住 ⌘ 的那套（pending）分开，松开 ⌘ 不取消它
  private var opening: Task<Void, Never>?
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
          self?.dismissForSwitch(to: nil)
        }
      },
      workspace.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let pid = app?.processIdentifier
        MainActor.assumeIsolated { self?.dismissForSwitch(to: pid) }
      },
      // 面板拿到键盘（点了它）：留住
      NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { [weak self] note in
        let window = note.object as? NSWindow
        MainActor.assumeIsolated {
          guard let self, let window, window === self.panel.panel else { return }
          self.stay()
        }
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
    opening?.cancel()
    opening = nil
    hold = ModifierHold()
    flagsMonitors.forEach(NSEvent.removeMonitor)
    flagsMonitors = []
    for observer in observers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      NotificationCenter.default.removeObserver(observer)
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    observers = []
    panel.panel?.hide()
  }

  private func installFlagsMonitor() {
    flagsMonitors.forEach(NSEvent.removeMonitor)
    hold = ModifierHold()
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
    let key = Self.currentHoldKey
    let held = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
    // 弹出来、还没留住，那个键还按着：又按住的修饰键只用来挑亮哪几行（拍板 F2），面板不收；松开那个键照常交给状态机收起
    if let panel = panel.panel, panel.isVisible, !model.isStaying, held.contains(key.flag) {
      model.heldModifiers = Self.symbols(held.subtracting(key.flag))
      return
    }
    switch hold.handle(flags: event.modifierFlags, at: event.timestamp, key: key) {
    case .began(let since): began(since: since, key: key)
    case .ended:
      cancelPending()
      dismissPeek()
    case nil: break
    }
  }

  /// 修饰键 → 和快捷键同一种写法的符号（纯函数）
  static func symbols(_ flags: NSEvent.ModifierFlags) -> Set<String> {
    let names: [(NSEvent.ModifierFlags, String)] = [
      (.function, "🌐"), (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]
    return Set(names.filter { flags.contains($0.0) }.map(\.1))
  }

  private func cancelPending() {
    pending?.cancel()
    pending = nil
    reading?.cancel()
    reading = nil
    unwatchBreaks()
  }

  /// 按住的那一刻起看着：按了键、鼠标键、滚轮，或者指针挪出 maxDrift，就当场作废这一次——读菜单的任务一起取消（它在对方
  /// App 的主线程上应答，别白读）。原来只在 0.3 秒、到点、读完这几个时刻查一次 quiet，中间按的 ⌘C、挪的鼠标都要等松开才停。
  /// 只看、不吞（全局监听，要辅助功能授权——没有的话本来也弹不了）
  private func watchBreaks(from mouse: NSPoint) {
    unwatchBreaks()
    breakMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved,
      ]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        if event.type == .mouseMoved, !Self.drifted(from: mouse, to: NSEvent.mouseLocation) {
          return
        }
        self?.cancelPending()
      }
    }
  }

  private func unwatchBreaks() {
    if let breakMonitor { NSEvent.removeMonitor(breakMonitor) }
    breakMonitor = nil
  }

  /// 指针挪出这么远算动了（纯函数）
  static func drifted(from start: NSPoint, to now: NSPoint) -> Bool {
    hypot(now.x - start.x, now.y - start.y) > maxDrift
  }

  /// 开始单独按住那个键：0.3 秒起读菜单，到点再确认一遍、弹出来
  private func began(since: TimeInterval, key: ModifierTaps.Key) {
    cancelPending()
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Prefs.appShortcutsHold) as? Bool ?? true, opening == nil,
      let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != getpid(), panel.panel?.isVisible != true
    else { return }
    let delay = Self.delay(defaults.object(forKey: Prefs.appShortcutsDelay))
    let hold = Hold(
      since: since, key: key, app: app, spaces: spaceChanges, mouse: NSEvent.mouseLocation)
    watchBreaks(from: hold.mouse)
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
      unwatchBreaks()
      show(result, app: app)
    }
  }

  /// 这一次按住：从什么时候、按的哪个键、对着哪个 App、按下时切过几次桌面、指针在哪
  private struct Hold {
    let since: TimeInterval
    let key: ModifierTaps.Key
    let app: NSRunningApplication
    let spaces: Int
    let mouse: NSPoint
  }

  /// 这一次还算数：那个键还单独按着，这期间没按过键、鼠标、滚轮，鼠标键没按着（按着 ⌘ 拖东西），指针没挪远，前台还是它，
  /// 没切过桌面，本 App 的窗口没拿着键盘，此刻能弹。别的 App 开着安全输入时（正在输密码）不弹：那时按键不经过全局监听，
  /// 分不清按着 ⌘ 时按没按过别的键
  private func holding(_ hold: Hold) -> Bool {
    let mouse = NSEvent.mouseLocation
    return NSEvent.modifierFlags.intersection([.command, .option, .control, .shift, .function])
      == hold.key.flag
      && HotKeyCenter.quiet(
        since: hold.since, now: ProcessInfo.processInfo.systemUptime, types: Self.breaking)
      && NSEvent.pressedMouseButtons == 0
      && !Self.drifted(from: hold.mouse, to: mouse)
      && NSWorkspace.shared.frontmostApplication?.processIdentifier == hold.app.processIdentifier
      && spaceChanges == hold.spaces && NSApp.keyWindow == nil
      && HotKeyBlock.rule(for: hold.app.bundleIdentifier, in: HotKeyBlock.stored)?.blocks(
        .appShortcuts) != true
      && Permissions.isAccessibilityTrusted && !IsSecureEventInputEnabled() && !isSuppressed()
  }

  /// 弹出来。staying：直接留住（快捷键打开的）；按着 ⌘ 弹的不拿键盘
  private func show(_ reading: MenuReading, app: NSRunningApplication, staying: Bool = false) {
    let screen = NSScreen.underMouse
    model.load(
      reading, name: app.localizedName ?? "", icon: app.icon,
      available: screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900))
    shownApp = app
    model.openedByKey = staying
    model.holdSymbol = Self.currentHoldKey.symbol
    let panel = panel.open()
    panel.setContentSize(model.layout.size)
    panel.present(makingKey: staying)
    if !staying { installKeyMonitor() }
    installClickMonitor()
    Island.announce("\(model.appName)，\(model.count) 个快捷键")
  }

  /// 快捷键页的「显示 App 快捷键」（菜单栏、启动器、主界面里同一项）：开着就收起，不然读前台 App、直接留住。
  /// 从本 App 的启动器、主界面点的，前台照旧是底下那个 App（浮层不激活本 App），所以不先问键盘在谁身上
  func toggle() {
    if let panel = panel.panel, panel.isVisible { return panel.dismiss() }
    // 还在读（读得慢的 App）时再按一次 = 不要了
    if let opening {
      opening.cancel()
      self.opening = nil
      return
    }
    guard Permissions.isAccessibilityTrusted else { return Permissions.requestAccessibility() }
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid()
    else {
      announce?("先切到要看的 App，再打开 App 快捷键")
      return
    }
    cancelPending()
    opening = Task { [weak self] in
      let reading = await MenuShortcuts.read(pid: app.processIdentifier, checksFocus: false)
      guard let self, !Task.isCancelled else { return }
      opening = nil
      show(reading, app: app, staying: true)
    }
  }

  /// 留住：拿着键盘，松开 ⌘ 不收；焦点进搜索框（点在别处拿到键盘的也是）
  private func stay() {
    guard let panel = panel.panel, panel.isVisible, !model.isStaying else { return }
    model.isStaying = true
    model.heldModifiers = []
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    if !(panel.firstResponder is NSText), let field = panel.initialFirstResponder {
      panel.makeFirstResponder(field)
    }
  }

  /// 执行一行：先收起面板（键盘回到前台 App），再按那个菜单项；菜单变了按不了就说一声
  private func perform(_ item: MenuShortcut) {
    guard let app = shownApp else { return }
    panel.panel?.hide()
    Self.press(item, in: app) { [weak self] in self?.announce?($0) }
  }

  /// 按菜单里的一项（面板里点一行、启动器里菜单项的 ↩，第五轮体检 N3）：菜单变了按不了、这一刻用不了就说一声
  static func press(
    _ item: MenuShortcut, in app: NSRunningApplication,
    announce: (LocalizedStringResource) -> Void
  ) {
    let name = app.localizedName ?? String(localized: "这个 App")
    switch MenuShortcuts.press(item, pid: app.processIdentifier) {
    case .pressed: break
    case .changed: announce("没能执行「\(item.title)」：\(name)的菜单变了")
    case .refused: announce("「\(item.title)」现在用不了")
    }
  }

  /// 留住时按的组合（OverlayPanel 先问它）：编辑用的几个和 ⌘W 照常（返回 false 交给面板）；带 ⌘ 的、列表里有的执行
  /// 那一项，没有的只收起
  private func keyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
    guard flags.contains(.command) else { return false }
    if Self.editsText(keyCode: event.keyCode, flags: flags, key: event.shortcutCharacters) {
      return false
    }
    let candidates = AppShortcutsModel.candidates(
      keyCode: event.keyCode, flags: event.modifierFlags,
      characters: event.charactersIgnoringModifiers)
    if let item = candidates.firstNonNil(model.item(forKeys:)) {
      perform(item)
    } else {
      panel.panel?.dismiss()
    }
    return true
  }

  /// 留住时交给搜索框 / 面板、不当成 App 快捷键的 ⌘ 组合（纯函数）：编辑文字的 ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z、删到行首 / 行尾
  /// ⌘⌫ ⌘⌦、⌘（加不加 ⇧）方向键，和收起面板的 ⌘W。不然在访达里打着字按 ⌘⌫ 清空，会把选中的文件移进废纸篓
  static func editsText(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String?) -> Bool {
    let flags = flags.intersection([.command, .control, .option, .shift])
    // 按打出来的字认（E2，同各面板）
    let letter = HotKey.keyCode(Int(keyCode), typing: key)
    let movement = [
      kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
    ].contains(Int(keyCode))
    let editing = [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_W]
    return (flags == .command && editing.contains(letter))
      || (flags == [.command, .shift] && letter == kVK_ANSI_Z)
      || ((flags == .command || flags == [.command, .shift]) && movement)
  }

  /// 换了前台 App（不是弹的那个）、切了桌面：收起，留住的也收
  private func dismissForSwitch(to pid: pid_t?) {
    guard let panel = panel.panel, panel.isVisible else { return }
    if let pid, pid == shownApp?.processIdentifier || pid == getpid() { return }
    panel.dismiss(byKeyboard: false)
  }

  /// 不拿键盘的面板收起（松开 ⌘、按了键、切了 App / 桌面）；拿着键盘的（以后点了留住的）不动
  private func dismissPeek() {
    guard let panel = panel.panel, panel.isVisible, !panel.isKeyWindow else { return }
    panel.dismiss(byKeyboard: false)
  }

  private func installKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismissPeek() }
    }
  }

  /// 点在面板上、它还不是 key（按着 ⌘ 点的）：先让它当 key（→ didBecomeKey → 留住），这一下照常交给面板
  private func installClickMonitor() {
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      MainActor.assumeIsolated {
        guard let panel = self?.panel.panel, event.window === panel, !panel.isKeyWindow else {
          return
        }
        panel.makeKey()
      }
      return event
    }
  }

  /// 面板收起：两个监听都摘
  private func removeMonitors() {
    for monitor in [keyMonitor, clickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
    keyMonitor = nil
    clickMonitor = nil
  }
}
