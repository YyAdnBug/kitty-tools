// 程序坞预览听程序坞（第九族，2026-10-22）：程序坞通过辅助功能公开了图标列表（AXList，每个图标一个 AXDockItem），鼠标停到哪个
// 图标上，它就把那一个设成选中、发 kAXSelectedChildrenChangedNotification——听这一条就知道停在哪，不用盯着鼠标，平时不耗电
// （DockDoor 的做法）。只认 App 图标（子角色 AXApplicationDockItem）；文件夹、废纸篓、分隔线、最近使用里的都算「没停在 App 上」。
// 挂上之后每 5 秒体检一次（DockDoor 同样这么做）：程序坞重启过（进程号变了）、重建了界面（列表换了一份，旧对象不再发通知）、
// 上次没挂上（没授权、程序坞刚起来辅助功能树还没建好）都重挂。不靠 NSWorkspace 的启动通知：程序坞是 LSUIElement 的 App，
// 系统不为它发（Apple 文档写明，本机 Info.plist 核对过）。
// ponytail: 程序坞重启后最多 5 秒停上去没反应；要更快再改成 KVO 盯 runningApplications + 退避重试。
// 观察者的源挂在主运行循环上，回调在主线程来：C 回调本身 nonisolated，里面 assumeIsolated。要辅助功能授权。

import AppKit
import ApplicationServices

@MainActor final class DockWatcher {
  /// 鼠标停着的那个 App 图标
  struct Item: Equatable {
    let title: String
    /// 图标指向的 App（程序坞给的 AXURL）；拿它找开着的进程
    let bundleURL: URL?
    /// 图标在屏幕上的位置（AppKit 全局坐标，原点在主屏左下）；开着放大时是放大后的。收到通知那一刻读的：
    /// 放大、自动隐藏滑出的动画可能还没走完，真用之前拿 currentFrame 重读一次
    var frame: CGRect
    /// 图标的辅助功能对象（重读位置用；不参与相等）
    let element: AXUIElement?

    static func == (lhs: Item, rhs: Item) -> Bool {
      lhs.title == rhs.title && lhs.bundleURL == rhs.bundleURL && lhs.frame == rhs.frame
    }
  }

  /// 图标现在的位置（AppKit 全局坐标）；读不到时 nil
  static func currentFrame(of item: Item) -> CGRect? {
    guard let element = item.element, let origin = point(element, kAXPositionAttribute),
      let size = size(element, kAXSizeAttribute)
    else { return nil }
    return appKitFrame(
      origin: origin, size: size, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
  }

  /// 停着的图标变了（nil = 离开了程序坞，或停在不是 App 的图标上）
  var onChange: ((Item?) -> Void)?
  private(set) var current: Item?

  private var observer: AXObserver?
  private var lists: [AXUIElement] = []
  /// 挂上时程序坞的进程号：体检时对不上 = 重启过
  private var dockPID: pid_t?
  private var checkup: Timer?
  static let checkupInterval: TimeInterval = 5

  /// 观察者拿的是不持有的 self：放掉之前一定摘干净
  isolated deinit { stop() }

  static let bundleID = "com.apple.dock"

  /// 挂上，并开始体检。这一下没挂上（没有辅助功能授权、程序坞没在跑）返回 false，之后体检时接着试
  @discardableResult func start() -> Bool {
    if checkup == nil {
      let timer = Timer(timeInterval: Self.checkupInterval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.examine() }
      }
      timer.tolerance = 1
      RunLoop.main.add(timer, forMode: .common)
      checkup = timer
    }
    return attach()
  }

  func stop() {
    checkup?.invalidate()
    checkup = nil
    detach()
  }

  /// 挂着没有
  var isAttached: Bool { observer != nil }

  /// 体检：还挂在同一个程序坞的同一份列表上就什么都不做（一次辅助功能调用），否则重挂
  private func examine() {
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?
      .processIdentifier
    if observer != nil, pid == dockPID, let dock = Self.dockElement() {
      let now = Self.lists(of: dock)
      if now.count == lists.count, zip(now, lists).allSatisfy({ CFEqual($0, $1) }) { return }
    }
    attach()
  }

  /// 程序坞的辅助功能对象（探针、拿方位用）；没授权或没在跑时 nil
  static func dockElement() -> AXUIElement? {
    guard Permissions.isAccessibilityTrusted,
      let dock = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    else { return nil }
    return AXUIElementCreateApplication(dock.processIdentifier)
  }

  /// 程序坞里的图标列表（一般就一个 AXList）
  static func lists(of dock: AXUIElement) -> [AXUIElement] {
    let children = Self.value(dock, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return children.filter { Self.value($0, kAXRoleAttribute) as? String == kAXListRole }
  }

  @discardableResult private func attach() -> Bool {
    detach()
    guard let dock = Self.dockElement(),
      let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        .first?.processIdentifier
    else { return false }
    // 程序坞刚起来时辅助功能树可能还是空的：这次不挂，下次体检再来
    let found = Self.lists(of: dock)
    guard !found.isEmpty else { return false }
    var created: AXObserver?
    guard AXObserverCreate(pid, dockSelectionChanged, &created) == .success, let created else {
      return false
    }
    let context = Unmanaged.passUnretained(self).toOpaque()
    let subscribed = found.filter {
      AXObserverAddNotification(
        created, $0, kAXSelectedChildrenChangedNotification as CFString, context) == .success
    }
    guard !subscribed.isEmpty else { return false }
    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), CFRunLoopMode.commonModes)
    observer = created
    lists = subscribed
    dockPID = pid
    return true
  }

  private func detach() {
    if let observer {
      for list in lists {
        AXObserverRemoveNotification(
          observer, list, kAXSelectedChildrenChangedNotification as CFString)
      }
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
    }
    observer = nil
    lists = []
    dockPID = nil
    if current != nil {
      current = nil
      onChange?(nil)
    }
  }

  fileprivate func selectionChanged() {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let item = lists.lazy.compactMap { Self.selectedItem(in: $0, primaryHeight: primaryHeight) }
      .first
    guard item != current else { return }
    current = item
    onChange?(item)
  }

  /// 列表里选中的那个图标（只认 App 图标）
  private static func selectedItem(in list: AXUIElement, primaryHeight: CGFloat) -> Item? {
    guard let selected = (value(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first,
      value(selected, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
      let origin = point(selected, kAXPositionAttribute),
      let size = size(selected, kAXSizeAttribute)
    else { return nil }
    return Item(
      title: value(selected, kAXTitleAttribute) as? String ?? "",
      bundleURL: value(selected, kAXURLAttribute) as? URL,
      frame: appKitFrame(origin: origin, size: size, primaryHeight: primaryHeight),
      element: selected)
  }

  /// 辅助功能的坐标（原点主屏左上、y 向下）→ AppKit 全局坐标（原点主屏左下）。纯函数，配单测
  nonisolated static func appKitFrame(origin: CGPoint, size: CGSize, primaryHeight: CGFloat)
    -> CGRect
  {
    CGRect(
      x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width, height: size.height
    )
  }

  // MARK: 读属性

  /// 读别的进程的辅助功能最多等多久（秒）
  static let messagingTimeout: Float = 0.3

  /// 读一个属性。先给这个对象设超时：超时只管设了的那一个对象（取回来的子对象照样默认等 6 秒），所以每次读都设，
  /// 卡住的程序坞 / App 最多把主线程拖住这么久
  static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
      ? value : nil
  }

  static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
      return nil
    }
    var point = CGPoint.zero
    return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
  }

  static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
      return nil
    }
    var size = CGSize.zero
    return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
  }
}

/// 辅助功能观察者的 C 回调：源挂在主运行循环上，所以就在主线程（context 是不持有的 DockWatcher，stop / 重挂前先摘掉）
nonisolated private func dockSelectionChanged(
  _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let watcher = Unmanaged<DockWatcher>.fromOpaque(context).takeUnretainedValue()
  MainActor.assumeIsolated { watcher.selectionChanged() }
}
