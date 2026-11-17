// 平滑滚动（插件，2026-11-17，issue #14；PLAN §10「平滑滚动」）的主线程这一半：跟着插件添没添加、授权起停那条滚动线程
// （ScrollTap），把设置（偏好）和「前台 App 停没停用」写进它的 ScrollShared。
// - 起停只有 apply 一个口子：启动时、偏好一变（AppDelegate 的偏好监听）都调，没变不动；插件移除 = 线程停掉、拦截撤掉
// - 要「辅助功能」授权（会吞事件的拦截要它；只查不弹框，运行中添加时 AppDelegate 当场要一次）。没有授权不起，设置页说清楚、给「去授权」
// - 本 App 回到前台、醒来、设置窗当 key、系统设置里辅助功能的名单变了（分布式通知，等一秒再看）时整条重建（refresh）：授权可能
//   刚给 / 刚收回，拦截可能在睡着时被系统停了而通知没到
// - 授权显示有、拦截却建不起来（Dev 版重签后系统记的还是旧的那份），或者端口自己失效了：记成 failed，不每次偏好变化都重起，
//   等下一次 refresh
// - Kitty 自己要一格一格滚轮的面板当 key 时（启动台：一格一页；截图框选：一格换一层）当成停用（pausesSmoothing）：
//   这两块面板不激活本 App，前台还是别的 App

import AppKit
import Synchronization

@MainActor @Observable final class SmoothScroll: NSObject {
  enum Status: Equatable {
    /// 插件没添加
    case off
    /// 添加了，没有辅助功能授权
    case needsPermission
    /// 授权有，拦截建不起来（或者自己失效了）
    case failed
    case running
  }

  private(set) var status = Status.off

  let shared = ScrollShared()
  @ObservationIgnored private var thread: Thread?
  /// 起过第几条线程：建不起来的回调晚到时（这期间已经重建过）认得出不是现在这条
  @ObservationIgnored private var generation = 0
  private let defaults: UserDefaults
  /// 前台 App 和它的分类（游戏自动停用）：换前台时在主线程读好
  @ObservationIgnored private var front: (id: String?, category: String?)
  /// 当 key 的、要一格一格滚轮的 Kitty 面板
  @ObservationIgnored private var pausingPanel: ObjectIdentifier?

  /// observes：听前台 App、醒来、回到前台、窗口当 key、辅助功能名单这些通知（一直听着：插件没添加时 apply / refresh 什么都
  /// 不起，只多读几个偏好）。截图自检、内存探针传 false：不然测试宿主被激活时会照临时偏好真的建起拦截
  init(defaults: UserDefaults = .standard, observes: Bool = true) {
    self.defaults = defaults
    front = Self.describe(NSWorkspace.shared.frontmostApplication)
    super.init()
    guard observes else { return }
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(
      self, selector: #selector(frontChanged), name: NSWorkspace.didActivateApplicationNotification,
      object: nil)
    workspace.addObserver(
      self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    let local = NotificationCenter.default
    local.addObserver(
      self, selector: #selector(refresh), name: NSApplication.didBecomeActiveNotification,
      object: nil)
    local.addObserver(
      self, selector: #selector(keyChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
    local.addObserver(
      self, selector: #selector(keyChanged), name: NSWindow.didResignKeyNotification, object: nil)
    // 本 App 几乎从不在前台：分布式通知要 deliverImmediately，不然被系统压着等下次激活（同 MediaKeys）
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(accessibilityChanged), name: .init("com.apple.accessibility.api"),
      object: nil, suspensionBehavior: .deliverImmediately)
  }

  @objc private func frontChanged(_ note: Notification) {
    front = Self.describe(
      note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    push()
  }

  @objc private func keyChanged(_ note: Notification) {
    guard let window = note.object as? NSWindow else { return }
    if note.name == NSWindow.didBecomeKeyNotification {
      pausingPanel = Self.pausesSmoothing(window) ? ObjectIdentifier(window) : nil
    } else if pausingPanel == ObjectIdentifier(window) {
      pausingPanel = nil
    }
    push()
  }

  /// 系统设置里改了辅助功能的名单：这一刻读授权可能还是旧的，等一秒再重建
  @objc nonisolated private func accessibilityChanged() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      self?.refresh()
    }
  }

  /// 要一格一格滚轮的 Kitty 面板：启动台（一格一页）、截图框选（一格换一层）
  static func pausesSmoothing(_ window: NSWindow) -> Bool {
    window is LaunchpadPanel || window is SelectionOverlay
  }

  /// 偏好里的设置
  static func settings(_ defaults: UserDefaults) -> ScrollSmoothing.Settings {
    ScrollSmoothing.Settings(
      strength: defaults.object(forKey: Prefs.smoothScrollStrength) as? Int ?? 50,
      speed: defaults.object(forKey: Prefs.smoothScrollSpeed) as? Int ?? 100,
      reverseVertical: defaults.bool(forKey: Prefs.smoothScrollReverseVertical),
      reverseHorizontal: defaults.bool(forKey: Prefs.smoothScrollReverseHorizontal))
  }

  /// 照插件开关、授权起 / 停，设置和前台 App 跟上（启动时、偏好变了时 AppDelegate 调）：没变不动
  func apply() {
    push()
    let added =
      defaults.object(forKey: Feature.smoothScroll.prefsKey) as? Bool
      ?? Feature.smoothScroll.defaultOn
    guard added else {
      halt()
      status = .off
      return
    }
    guard Permissions.isAccessibilityTrusted else {
      halt()
      status = .needsPermission
      return
    }
    guard status != .failed, thread == nil else { return }
    let rate = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
    shared.state.withLock { $0.frameInterval = 1 / Double(min(max(rate, 60), 240)) }
    generation += 1
    let current = generation
    thread = ScrollTap.start(shared: shared) { [weak self] in
      Task { @MainActor in self?.tapFailed(generation: current) }
    }
    status = .running
  }

  /// 回到前台、醒来、设置窗当 key：照现在的授权整条重建一遍（建不起来那次也再试）
  @objc func refresh() {
    halt()
    if status == .failed { status = .off }
    apply()
  }

  private func halt() {
    guard let thread else { return }
    ScrollTap.stop(thread, shared: shared)
    self.thread = nil
  }

  private func tapFailed(generation failed: Int) {
    guard thread != nil, failed == generation else { return }
    thread = nil
    status = .failed
  }

  /// 设置、前台 App 停没停用写给滚动线程（没变不写）
  private func push() {
    let settings = Self.settings(defaults)
    let excluded =
      pausingPanel != nil
      || ScrollSmoothing.isExcluded(
        app: front.id, category: front.category,
        list: Set(defaults.stringArray(forKey: Prefs.smoothScrollExcluded) ?? []))
    shared.state.withLock {
      if $0.settings != settings { $0.settings = settings }
      if $0.excluded != excluded { $0.excluded = excluded }
    }
  }

  /// App 的 bundle id 和它 Info.plist 里写的分类
  nonisolated private static func describe(_ app: NSRunningApplication?) -> (
    id: String?, category: String?
  ) {
    let category =
      app?.bundleURL.flatMap(Bundle.init(url:))?
      .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    return (app?.bundleIdentifier, category)
  }

  /// 此刻开着的、也会改鼠标滚轮的工具的名字（设置页、添加插件时的提示现读）
  static func runningOtherTools() -> [String] {
    ScrollSmoothing.runningOtherTools(
      NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.localizedName) })
  }

  /// 系统设置里的「自然滚动」开着没有（鼠标和触控板是同一个开关；没存过 = 开着）
  static var naturalScrolling: Bool {
    UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
  }
}
