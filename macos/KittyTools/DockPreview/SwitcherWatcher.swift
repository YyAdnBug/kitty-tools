// ⌘Tab 切换时也弹窗口预览（2026-11-06 用户：「command+tab 切换时也添加预览窗口，和 dock-preview 一致」；拍板页 C1–C5
// 全部按推荐）：系统的 ⌘Tab 照旧，这里只看它选中了哪个 App。系统的切换器是程序坞进程画的，辅助功能里是一个子角色
// AXProcessSwitcherList 的列表（只在切换器开着时有；DockDoor 也这么读）。选中的那一项旧系统上和程序坞图标一样带 AXURL，
// macOS 27 上只有标题（2026-11-06 本机探针），按标题配开着的 App。
// - 按下 ⌘（全局 + 本地监听修饰键变化，只听不拦；要辅助功能，程序坞预览本来就要）才开始每 0.1 秒找一次那个列表，找到就
//   挂观察者听它的选中变化，不再找；松开 ⌘、列表没了就报 nil（切换器收起）。平时不找。
// - 找的时候只往不是列表的元素里钻（程序坞自己的图标列表也是 AXList，钻进去要读几十个图标），最多三层。
// 设置 › 程序坞预览「按 ⌘Tab 时也显示」（Prefs.dockPreviewCmdTab，默认开）每按一次 ⌘ 现读，关着不找。
// ponytail: 哪个系统版本上读不到这个列表就一直不弹（不崩），设置页不提示——按住 ⌘ 时分不清「没按 Tab」和「读不到」；
// 真遇到了再加按 Tab 的按键监听来判断。

import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor final class SwitcherWatcher {
  /// 切换器里选中的 App，和切换器那一排在屏幕上的位置（AppKit 全局坐标）
  struct Selection: Equatable {
    let bundleURL: URL?
    /// 那一项的标题：macOS 27 上切换器的项没有 AXURL（2026-11-06 本机探针：只有 AXTitle、AXPosition 这些），
    /// 只能按它配开着的 App（DockPreview.runningApp(titled:)）
    let title: String
    let listFrame: CGRect
  }

  /// 选中变了（nil = 切换器收起了）
  var onChange: ((Selection?) -> Void)?
  /// 正跟着切换器（挂着观察者）
  var isActive: Bool { list != nil }

  private var monitors: [Any] = []
  private var poll: Timer?
  private var observer: AXObserver?
  private var list: AXUIElement?
  private var current: Selection?

  static let subrole = "AXProcessSwitcherList"
  static let pollInterval: TimeInterval = 0.1

  /// 观察者拿的是不持有的 self：放掉之前一定摘干净
  isolated deinit { stop() }

  func start() {
    guard monitors.isEmpty else { return }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.commandChanged(event.modifierFlags.contains(.command)) }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.commandChanged(event.modifierFlags.contains(.command)) }
      return event
    }
    monitors = [global, local].compactMap { $0 }
  }

  func stop() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
    detach()
  }

  /// 按下 ⌘：开始找切换器；松开：切换器收起了
  private func commandChanged(_ down: Bool) {
    guard down else { return detach() }
    guard poll == nil, list == nil, UserDefaults.standard.bool(forKey: Prefs.dockPreviewCmdTab)
    else { return }
    let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.look() }
    }
    RunLoop.main.add(timer, forMode: .common)
    poll = timer
  }

  /// 找一次切换器；⌘ 已经松开（监听漏了那一下）就停
  private func look() {
    guard NSEvent.modifierFlags.contains(.command) else { return detach() }
    guard let dock = DockWatcher.dockElement(), let found = Self.findList(in: dock, depth: 3),
      let pid = NSRunningApplication.runningApplications(withBundleIdentifier: DockWatcher.bundleID)
        .first?.processIdentifier
    else { return }
    attach(found, pid: pid)
  }

  /// 程序坞里那个切换器列表：只往不是列表的元素里钻
  static func findList(in element: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth > 0 else { return nil }
    let children = DockWatcher.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    for child in children {
      if DockWatcher.value(child, kAXSubroleAttribute) as? String == subrole { return child }
      guard DockWatcher.value(child, kAXRoleAttribute) as? String != kAXListRole else { continue }
      if let found = findList(in: child, depth: depth - 1) { return found }
    }
    return nil
  }

  private func attach(_ found: AXUIElement, pid: pid_t) {
    poll?.invalidate()
    poll = nil
    var created: AXObserver?
    guard AXObserverCreate(pid, switcherNotified, &created) == .success, let created else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    for name in [kAXSelectedChildrenChangedNotification, kAXUIElementDestroyedNotification] {
      AXObserverAddNotification(created, found, name as CFString, context)
    }
    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), CFRunLoopMode.commonModes)
    observer = created
    list = found
    selectionChanged()
  }

  private func detach() {
    poll?.invalidate()
    poll = nil
    if let observer, let list {
      for name in [kAXSelectedChildrenChangedNotification, kAXUIElementDestroyedNotification] {
        AXObserverRemoveNotification(observer, list, name as CFString)
      }
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
    }
    observer = nil
    list = nil
    if current != nil {
      current = nil
      onChange?(nil)
    }
  }

  fileprivate func notified(_ name: String) {
    if name == kAXUIElementDestroyedNotification { return detach() }
    selectionChanged()
  }

  private func selectionChanged() {
    guard let list else { return }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    var next: Selection?
    if let selected = (DockWatcher.value(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?
      .first,
      let origin = DockWatcher.point(list, kAXPositionAttribute),
      let size = DockWatcher.size(list, kAXSizeAttribute)
    {
      next = Selection(
        bundleURL: DockWatcher.value(selected, kAXURLAttribute) as? URL,
        title: DockWatcher.value(selected, kAXTitleAttribute) as? String ?? "",
        listFrame: DockWatcher.appKitFrame(origin: origin, size: size, primaryHeight: primaryHeight)
      )
    }
    guard next != current else { return }
    current = next
    onChange?(next)
  }

  /// 收起系统的切换器（点了一张缩略图，切到那扇窗口）：按着 ⌘ 时按 Esc 就是取消，松开 ⌘ 时就不会再切到选中的 App
  static func dismissSystemSwitcher() {
    for down in [true, false] {
      guard
        let event = CGEvent(
          keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)
      else {
        continue
      }
      event.flags = .maskCommand
      event.post(tap: .cghidEventTap)
    }
  }
}

/// 辅助功能观察者的 C 回调：源挂在主运行循环上，所以就在主线程（context 是不持有的 SwitcherWatcher，stop 前先摘掉）
nonisolated private func switcherNotified(
  _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let watcher = Unmanaged<SwitcherWatcher>.fromOpaque(context).takeUnretainedValue()
  let name = notification as String
  MainActor.assumeIsolated { watcher.notified(name) }
}
