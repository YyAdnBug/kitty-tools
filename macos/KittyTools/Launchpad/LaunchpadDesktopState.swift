// 只观察 macOS 26 原生「显示桌面」，不发送桌面动作、不接管它的动画。
// 桌面显示时捏合用于系统还原窗口，启动台让开；未知状态不猜窗口层级。只使用已有辅助功能权限。

import AppKit
import ApplicationServices

@MainActor final class LaunchpadDesktopState {
  nonisolated enum State: Equatable, Sendable {
    case unknown, desktop, other

    var isShowingDesktop: Bool { self == .desktop }

    mutating func receive(_ notification: String) {
      switch notification {
      case "AXExposeShowDesktop": self = .desktop
      case "AXExposeExit", "AXExposeShowAllWindows", "AXExposeShowFrontWindows": self = .other
      default: break
      }
    }
  }

  private(set) var state: State = .unknown
  var isShowingDesktop: Bool { state.isShowingDesktop }
  private var observer: AXObserver?
  private var dockElement: AXUIElement?
  private var dockPID: pid_t?
  private var isStarted = false
  private var isSuspended = false
  private var applicationObservation: NSKeyValueObservation?
  private var workspaceObservers: [NSObjectProtocol] = []
  private static let notifications = [
    "AXExposeShowDesktop", "AXExposeExit", "AXExposeShowAllWindows", "AXExposeShowFrontWindows",
  ]

  isolated deinit { stop() }

  /// 权限未给时不申请、不阻止其他启动台入口。设置刷新和手势开始时可重试连接。
  func start() {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
      Permissions.isAccessibilityTrusted
    else {
      stop()
      return
    }
    if !isStarted {
      isStarted = true
      observeWorkspace()
    }
    reconnectIfNeeded()
  }

  func stop() {
    isStarted = false
    applicationObservation?.invalidate()
    applicationObservation = nil
    let center = NSWorkspace.shared.notificationCenter
    for token in workspaceObservers { center.removeObserver(token) }
    workspaceObservers.removeAll()
    isSuspended = false
    detach()
  }

  private func observeWorkspace() {
    let workspace = NSWorkspace.shared
    // Dock 是 LSUIElement，普通应用启动 / 退出通知不可靠；观察进程列表，不轮询。
    applicationObservation = workspace.observe(\.runningApplications) { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.reconnectIfNeeded() }
    }
    let center = workspace.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.isSuspended = true
            self?.detach()
          }
        })
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.isSuspended = false
            self?.reconnectIfNeeded()
          }
        })
    }
    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.state = .unknown
          self?.reconnectIfNeeded()
        }
      })
  }

  private func reconnectIfNeeded() {
    guard isStarted, !isSuspended else { return }
    guard Permissions.isAccessibilityTrusted else {
      detach()
      return
    }
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
      .first?.processIdentifier
    if observer != nil, pid == dockPID { return }
    detach()
    guard let pid else { return }
    let element = AXUIElementCreateApplication(pid)
    guard AXUIElementSetMessagingTimeout(element, 0.3) == .success else { return }
    var created: AXObserver?
    guard AXObserverCreate(pid, launchpadDesktopStateChanged, &created) == .success,
      let created
    else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    var subscribed: [String] = []
    for name in Self.notifications {
      guard AXObserverAddNotification(created, element, name as CFString, context) == .success
      else {
        for registered in subscribed {
          AXObserverRemoveNotification(created, element, registered as CFString)
        }
        return
      }
      subscribed.append(name)
    }
    observer = created
    dockElement = element
    dockPID = pid
    CFRunLoopAddSource(
      CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), CFRunLoopMode.commonModes)
  }

  private func detach() {
    state = .unknown
    if let observer {
      let source = AXObserverGetRunLoopSource(observer)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
      CFRunLoopSourceInvalidate(source)
      if let element = dockElement {
        for name in Self.notifications {
          AXObserverRemoveNotification(observer, element, name as CFString)
        }
      }
    }
    observer = nil
    dockElement = nil
    dockPID = nil
  }

  fileprivate func received(_ notification: String, from source: UInt) {
    guard let observer,
      UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque()) == source
    else { return }
    state.receive(notification)
  }
}

nonisolated private func launchpadDesktopStateChanged(
  _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let desktop = Unmanaged<LaunchpadDesktopState>.fromOpaque(context).takeUnretainedValue()
  let name = notification as String
  let source = UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
  // 回调源只挂主运行循环，摘掉并失效后才释放上下文。
  MainActor.assumeIsolated { desktop.received(name, from: source) }
}
