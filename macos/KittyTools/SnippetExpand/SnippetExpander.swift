// 片段展开（插件，2026-11-22，拍板页 https://claude.ai/artifact/PNApPJNxAgNG36JcSC1q1B「全部按推荐」；PLAN §10「片段展开」）的主线程这一半：
// 跟着插件添没添加、剪贴板开没开、授权、有没有片段设了关键词起停那条拦截线程（KeywordTap），把关键词写给它；它认出一个关键词时
// 在这里决定展不展开、怎么填进去。
// - 起停只有 apply 一个口子：启动时、偏好一变（AppDelegate 的偏好监听）、剪贴板的条目变了（看着 store.items）都调，没变不动。
//   一条片段都没设关键词时不建拦截（Q13 页的「完全不听键盘」）
// - 授权：要「辅助功能」（只查不弹框，运行中添加时 AppDelegate 当场要一次）。授权显示有、拦截却建不起来：记成 failed，等下一次
//   refresh（回到前台、醒来、系统设置里辅助功能的名单变了）
// - 展开前依次看（任何一样成立就不动，打的字原样留着）：认出来之后又打了别的键；Kitty 在忙（状态屏、录快捷键、截图框选，
//   AppDelegate 给的 isBusy）；安全输入开着；收键的是 Kitty 自己（第 3 批：便签里展开）；那个 App 在「不展开」名单里；
//   **输入法正在组字**（Q7）——当前输入源是输入法时，先问收键的那个元素的辅助功能属性 AXTextInputMarkedRange（公开的
//   NSAccessibilityTextInputMarkedRangeAttribute，系统文本框、网页输入框实测都有），问不到再看输入法的候选窗在不在屏上；
//   都看不出来就照常展开（实测照常删再填结果也是对的：退格先删组字里的字母）
// - 填进去（Q6）：按关键词的字数发 ⌫（带记号，拦截不看）→ 展开好的内容带 transient 写进剪贴板（不进历史，别的剪贴板工具也不记）
//   → ⌘V（Paster.pasteToFrontmost，{cursor} 在它里面等 50 ms 再按 ←）→ 300 ms 后剪贴板没被别人动过就把原来的放回去（同样带
//   transient）。0 ms 就还原的话目标 App 读到的是原来的内容（探针实测），50 ms 实测就够，300 ms 留余量。300 ms 里又展开一次：
//   沿用头一次存下的那份，不把中间那份当成原来的
// - 带 {input} 的片段：删掉关键词后交给剪贴板面板问（fill，第 3 批接；没接时不展开）
// - 日志只记没展开的原因和拦截是哪一种，不记关键词、不记打的字

import AppKit
import Carbon.HIToolbox
import OSLog
import Observation
import Synchronization

@MainActor @Observable final class SnippetExpander: NSObject {
  enum Status: Equatable {
    /// 插件没添加
    case off
    /// 添加了，没有辅助功能授权
    case needsPermission
    /// 添加了、有授权，没有片段设关键词（或者剪贴板关着）：不听键盘
    case idle
    /// 授权有，拦截建不起来（或者自己失效了）
    case failed
    case running
  }

  private(set) var status = Status.off

  @ObservationIgnored private let store: ClipboardStore
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let shared: KeywordTap.Shared
  @ObservationIgnored private var thread: Thread?
  /// 授权有、拦截却没建起来过：不每次偏好变化都重试（回到前台、醒来时再试）
  @ObservationIgnored private var gaveUp = false
  /// 借用剪贴板之前存下的原内容、等着还原的那一下（300 ms 里又展开一次时沿用这份）
  @ObservationIgnored private var pendingRestore:
    (items: [NSPasteboardItem], task: Task<Void, Never>)?
  /// AppDelegate 接：Kitty 此刻在忙（状态屏、录快捷键、截图框选）就不展开
  @ObservationIgnored var isBusy: () -> Bool = { false }
  /// 带 {input} 的片段：删掉关键词之后交给剪贴板面板问（第 3 批接）；nil = 这种片段不展开
  @ObservationIgnored var fill: ((ClipItem) -> Void)?

  /// 拦截线程投回主线程时找到这一份（init 里 self 还不能被闭包拿着）
  private final class Relay {
    weak var expander: SnippetExpander?
  }

  /// observes：听回到前台、醒来、辅助功能名单这些通知，并看着剪贴板的条目。截图自检、内存探针传 false：不然测试宿主
  /// 被激活时会照临时偏好真的建起拦截
  init(store: ClipboardStore, defaults: UserDefaults = .standard, observes: Bool = true) {
    self.store = store
    self.defaults = defaults
    let relay = Relay()
    shared = KeywordTap.Shared { match in
      Task { @MainActor in relay.expander?.expand(match) }
    }
    super.init()
    relay.expander = self
    guard observes else { return }
    let centers = [
      (NotificationCenter.default, NSApplication.didBecomeActiveNotification),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
    ]
    for (center, name) in centers {
      center.addObserver(self, selector: #selector(refresh), name: name, object: nil)
    }
    // 本 App 几乎从不在前台：分布式通知要 deliverImmediately（同 SmoothScroll）
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(accessibilityChanged), name: .init("com.apple.accessibility.api"),
      object: nil, suspensionBehavior: .deliverImmediately)
    watchItems()
  }

  /// 剪贴板的条目变了（新设了关键词、删了片段、同步落下来）：照着重算关键词、起停拦截
  private func watchItems() {
    withObservationTracking {
      _ = store.items
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.apply()
        self?.watchItems()
      }
    }
  }

  /// 系统设置里改了辅助功能的名单：这一刻读授权可能还是旧的，等一秒再重建
  @objc nonisolated private func accessibilityChanged() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      self?.refresh()
    }
  }

  /// 拦截认关键词用的那一组：片段里设了的（只看文字的片段）
  static func keywords(in items: [ClipItem]) -> Set<String> {
    Set(items.lazy.filter { $0.isSnippet && $0.kind == .text }.compactMap(\.keyword))
  }

  /// 照插件开关、剪贴板开关、授权和关键词起 / 停（启动时、偏好变了、条目变了时调）：没变不动
  func apply() {
    if let thread, thread.isFinished {
      // 线程自己退了 = 拦截没建起来（授权显示有、系统却不给）或者端口失效了：记下，不每次变化都重起
      self.thread = nil
      gaveUp = true
    }
    let added =
      defaults.object(forKey: Feature.snippetExpand.prefsKey) as? Bool
      ?? Feature.snippetExpand.defaultOn
    let clipboard =
      defaults.object(forKey: Feature.clipboard.prefsKey) as? Bool ?? Feature.clipboard.defaultOn
    if !added { gaveUp = false }
    let keywords = added && clipboard ? Self.keywords(in: store.items) : []
    shared.keywords.withLock { if $0 != keywords { $0 = keywords } }
    let next: Status =
      if !added {
        .off
      } else if !Permissions.isAccessibilityTrusted {
        .needsPermission
      } else if keywords.isEmpty {
        .idle
      } else if gaveUp {
        .failed
      } else {
        .running
      }
    if next == .running {
      if thread == nil {
        thread = KeywordTap.start(shared: shared)
        Log.clipboard.notice("片段展开：开始听键盘")
      }
    } else {
      stop()
    }
    if status != next { status = next }
  }

  /// 回到前台、醒来、设置窗当 key：照现在的授权整条重建一遍（建不起来那次也再试）
  @objc func refresh() {
    gaveUp = false
    stop()
    apply()
  }

  private func stop() {
    guard let thread else { return }
    KeywordTap.stop(thread, shared: shared)
    self.thread = nil
    Log.clipboard.notice("片段展开：不再听键盘")
  }

  // MARK: 展开

  /// 拦截认出了一个关键词：看能不能展开，能就删掉它、填进片段
  private func expand(_ match: KeywordTap.Match) {
    // 这期间又打了别的键（主线程慢了一拍）：不动，不然删掉的是后打的字
    guard shared.sequence.load(ordering: .relaxed) == match.sequence else {
      return skip("关键词之后又打了字")
    }
    guard status == .running, !isBusy() else { return skip("Kitty 在忙") }
    guard !IsSecureEventInputEnabled() else { return skip("安全输入开着") }
    guard
      let snippet = store.items.first(where: {
        $0.isSnippet && $0.kind == .text && $0.keyword == match.keyword
      }), let text = snippet.text
    else { return }
    // ponytail: 收键的是 Kitty 自己（便签、启动器、剪贴板面板的输入框）时不展开；第 3 批接上便签
    guard match.pid != getpid() else { return skip("Kitty 自己的窗口") }
    if let id = NSRunningApplication(processIdentifier: match.pid)?.bundleIdentifier,
      Set(defaults.stringArray(forKey: Prefs.snippetExpandExcluded) ?? []).contains(id)
    {
      return skip("名单里的 App")
    }
    guard !Self.isComposing(pid: match.pid) else { return skip("输入法正在组字") }
    if !Snippet.inputs(in: text).isEmpty {
      guard let fill else { return skip("带填空") }
      KeywordTap.deleteBackward(match.keyword.count)
      fill(snippet)
      return
    }
    // 原来的剪贴板：300 ms 里又展开一次时，此刻剪贴板里是上一段片段，用头一次存下的那份（{clipboard} 也读它）
    let original = pendingRestore?.items ?? Paster.snapshot()
    pendingRestore?.task.cancel()
    let expanded = Snippet.expand(
      text, clipboard: { original.first?.string(forType: .string) }, history: store.historyText)
    KeywordTap.deleteBackward(match.keyword.count)
    let content = NSPasteboardItem()
    content.setString(expanded.text, forType: .string)
    Paster.write([content], transient: true)
    let written = NSPasteboard.general.changeCount
    guard Paster.pasteToFrontmost(movingLeft: expanded.charactersAfterCursor) else {
      Paster.restore(original)
      return skip("没有辅助功能授权")
    }
    // 同剪贴板面板里粘贴：用过的挪到最前
    store.bump(snippet.id)
    let task = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      // 这 300 ms 里有人（用户、别的 App）写过剪贴板：留着他们的，不还原
      if NSPasteboard.general.changeCount == written { Paster.restore(original) }
      self?.pendingRestore = nil
    }
    pendingRestore = (original, task)
  }

  private func skip(_ reason: StaticString) {
    Log.clipboard.notice("片段展开：没展开（\(reason, privacy: .public)）")
  }

  // MARK: 输入法组字

  /// 收键的那个 App 里输入法此刻是不是在组字（当前输入源不是输入法时直接 false）
  static func isComposing(pid: Int32) -> Bool {
    guard let method = InputMethod.current else { return false }
    if let length = markedLength(pid: pid) { return length > 0 }
    return candidateWindowShown(pid: pid, method: method)
  }

  /// 当前输入源是输入法时：它的 bundle id（找候选窗用）
  struct InputMethod {
    var bundleID: String?

    /// TIS 只能在主线程调（后台线程调会 dispatch_assert_queue 闪退，2026-11-22 探针踩过）
    static var current: InputMethod? {
      let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
      func string(_ key: CFString) -> String? {
        TISGetInputSourceProperty(source, key).map {
          Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
      }
      guard string(kTISPropertyInputSourceType) == kTISTypeKeyboardInputMode as String else {
        return nil
      }
      return InputMethod(bundleID: string(kTISPropertyBundleID))
    }
  }

  /// 收键的那个元素正在组的字有多长（问不到 nil）：辅助功能的 AXTextInputMarkedRange，0.1 s 超时
  static func markedLength(pid: Int32) -> Int? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.1)
    var focused: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    var value: CFTypeRef?
    // 上面认过类型
    guard
      AXUIElementCopyAttributeValue(
        // AppKit 的 NSAccessibilityTextInputMarkedRangeAttribute（Swift 里没有对应的常量）
        focused as! AXUIElement, "AXTextInputMarkedRange" as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    // 上面认过类型
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range.length
  }

  /// 输入法的候选窗在不在屏上：输入法自己进程的、层级高过普通窗口的窗口（实测微信输入法），或者收键的 App 自己进程里
  /// 层级 20 的窗口（实测系统拼音的候选窗挂在被打字的 App 下）。只读窗口的属主和层级，不要屏幕录制授权
  /// ponytail: 层级 20 是 2026-11-22 在 macOS 27 上量的；系统换了候选窗的层级就认不出（那时照常展开，结果也对，只剩「；+拼音」误触）
  static func candidateWindowShown(pid: Int32, method: InputMethod) -> Bool {
    let methodPID = method.bundleID.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
    }
    guard
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    return windows.contains { window in
      let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
      let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
      return (owner == methodPID && layer > 0) || (owner == pid && layer == 20)
    }
  }
}
