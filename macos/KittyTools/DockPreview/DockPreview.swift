// 程序坞预览（第九族，2026-10-22；拍板页 build/research/dock-preview-2026-10-22/decisions.html，PLAN §10「程序坞预览」）：
// 鼠标停在程序坞的 App 图标上 0.2 秒，图标上方弹出它所有窗口的缩略图；弹着时换到别的图标立刻换（面板滑过去、内容交叉淡变）；
// 鼠标离开图标和面板 0.3 秒后收起（留时间从图标挪到面板上）；点程序坞图标、点别处立刻收（拍板 B1–B3）。
// 点一张切到那扇窗口，点 ✕ 关掉那扇。没窗口的 App、不是 App 的图标不弹（B4）。启动台开着、状态屏、截图框选时不弹，
// 弹着时它们一来就收（D2）。
// 收不收按鼠标在哪定：弹着时每 0.1 秒看一眼鼠标还在不在面板、图标和两者之间那道缝里（DockPreviewLayout.keepsOpen /
// Linger），收着时不看。不用追踪区的进出：面板改尺寸会重建追踪区、淡出时进来的事件会丢，进出状态会卡住（评审 H1）；
// 也不全信程序坞的选中（鼠标离开程序坞时它不一定清选中）。
// 面板是普通 NSPanel 实例（不子类化，mac-overlay-panel §1）：无边框、不激活本 App、永不当 key（键盘一直在前台 App 里）、
// 状态栏层级（盖住程序坞的名字提示）、所有桌面和全屏 App 上都在；内容第一下点击就给（宿主 acceptsFirstMouse）。
// 永不当 key，收起直接淡掉窗口自己的透明度（OverlayPanel 要替身是因为淡出时它还当着 key）。
// 第一次弹时才建，收起时清掉内容、面板留着（弹过一次 14 扇的约 +10 MB，收起后照样占着，屏上量的，PLAN §10）；空闲回收
// 时收着的面板整块放掉（回落约 6 MB）、连同缩略图缓存，下次弹时再建；关掉功能时清缓存。开关是功能开关 Feature.dockPreview（默认关，拍板 A3），
// 起停在 AppDelegate.applyFeatures。
// ponytail: 换一次图标就在主线程同步列一次窗口（中位约 20 ms、最长约 50 ms，PLAN §10）；缩略图一扇扇串行截（一扇约
// 15 ms，二十扇约 0.3 s，先显示上次的图）。顺着程序坞划过一排图标觉得卡了，再给列窗口加防抖、截图开两三路并发。

import AppKit
import SwiftUI

@MainActor final class DockPreview {
  /// 别的功能占着屏幕时不弹（AppDelegate 给：启动台开着、状态屏、截图框选）
  var isSuppressed: () -> Bool = { false }
  /// 收起了（AppDelegate 拿它排空闲回收：两分钟没再弹就清缩略图缓存）
  var onHide: () -> Void = {}

  private let watcher = DockWatcher()
  private let lister = DockWindows()
  private let shots = WindowShots()
  /// 探针在屏上量面板时直接填它（DockPreviewProbeTests/memory()）
  let model = DockPreviewModel()
  private var panel: NSPanel?
  private var host: PreviewHost?
  /// 正在预览的：哪个 App、哪个图标（位置是弹出那一刻重读过的）、哪块屏（nil = 收着）
  private var shown: (app: NSRunningApplication, item: DockWatcher.Item, screen: NSScreen)?
  /// 等着出现的那一下（新的到来就作废旧的）
  private var pendingShow: Task<Void, Never>?
  private var capturing: Task<Void, Never>?
  /// 弹着时看鼠标在哪的定时器（收着时不跑）
  private var watch: Timer?
  private var linger = DockPreviewLayout.Linger()
  private var clickMonitors: [Any] = []
  /// 点了程序坞图标（或别处）收起之后，程序坞可能对着同一个图标再报一次选中：鼠标离开那个图标之前不再弹
  private var dismissedURL: URL?
  /// 图标的 URL → bundle id（路径经过符号链接时按它配进程；读一次 Info.plist 就记下）
  private var bundleIDs: [URL: String] = [:]

  static let showDelay: Duration = .milliseconds(200)
  static let watchInterval: TimeInterval = 0.1

  init() {
    model.onOpen = { [unowned self] in open($0) }
    model.onClose = { [unowned self] in close($0) }
  }

  /// 起：挂上程序坞。没有辅助功能授权时这一下挂不上，之后程序坞那边每 5 秒体检时接着试（授权了就挂上）
  func start() {
    WindowServer.prepare()
    watcher.onChange = { [unowned self] in dockChanged($0) }
    watcher.start()
  }

  /// 停：摘掉程序坞、收起、缩略图缓存跟着还（关掉功能 = 占着的缓存也放掉）
  func stop() {
    watcher.stop()
    hide(animated: false)
    shots.clear()
  }

  /// 空闲回收：丢掉缩略图缓存；收着时整块面板也放掉（下次弹时再建）。照 NoteDeck.releasePanel 的写法：
  /// 先拿到局部变量、属性置空，再拆
  func reclaim() {
    shots.clear()
    guard shown == nil, let old = panel else { return }
    panel = nil
    host = nil
    old.orderOut(nil)
    old.contentView = nil
    old.close()
  }

  // MARK: 什么时候弹

  private func dockChanged(_ item: DockWatcher.Item?) {
    pendingShow?.cancel()
    // 离开了程序坞、停在不是 App 的图标上：收不收由 watch 按鼠标在哪定
    guard let item else {
      dismissedURL = nil
      return
    }
    if item.bundleURL != dismissedURL { dismissedURL = nil }
    // 按着鼠标（拖东西经过程序坞）不弹；没开着的 App 不弹
    guard dismissedURL == nil, NSEvent.pressedMouseButtons == 0,
      let target = runningApp(at: item.bundleURL)
    else { return }
    if shown != nil {
      present(target, at: item)
    } else {
      pendingShow = Task { [weak self] in
        try? await Task.sleep(for: Self.showDelay)
        guard !Task.isCancelled else { return }
        self?.present(target, at: item)
      }
    }
  }

  /// 程序坞图标指向的那个开着的 App：先按解开链接后的路径配（/Applications/Safari.app 是指向别处的链接），配不上再按
  /// bundle id
  private func runningApp(at url: URL?) -> NSRunningApplication? {
    guard let url else { return nil }
    let path = url.resolvingSymlinksInPath().standardizedFileURL
    let apps = NSWorkspace.shared.runningApplications
    if let match = apps.first(where: {
      $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == path
    }) {
      return match
    }
    if bundleIDs[url] == nil { bundleIDs[url] = Bundle(url: url)?.bundleIdentifier }
    guard let id = bundleIDs[url] else { return nil }
    return apps.first { $0.bundleIdentifier == id }
  }

  // MARK: 弹出、换、收

  private func present(_ target: NSRunningApplication, at item: DockWatcher.Item) {
    guard !isSuppressed() else { return hide(animated: false) }
    // 停了 0.2 秒，放大、自动隐藏滑出的动画大多走完了：图标的位置重读一次
    var item = item
    if let frame = DockWatcher.currentFrame(of: item) { item.frame = frame }
    let windows = lister.list(target)
    let screens = NSScreen.screens
    guard !windows.isEmpty,
      let index = DockPreviewLayout.screenIndex(for: item.frame, in: screens.map(\.frame))
    else { return hide(animated: true) }
    let screen = screens[index]
    let edge = DockPreviewLayout.Edge(orientation: Self.dockOrientation())
    let showsThumbnails = Permissions.isScreenRecordingAllowed
    let (plan, frame) = layout(
      windows, item: item.frame, edge: edge, screen: screen, compact: !showsThumbnails)
    let listed = Array(windows.prefix(plan.thumbs.count))
    let sameApp = shown?.app.processIdentifier == target.processIdentifier
    let panel = self.panel ?? makePanel()
    let switching = shown != nil && panel.isVisible
    shown = (target, item, screen)
    linger = DockPreviewLayout.Linger()

    let update = {
      self.model.appName = target.localizedName ?? ""
      self.model.appIcon = target.icon
      self.model.windows = listed
      // 没有屏幕录制授权（撤销过）时别拿缓存里的旧图
      self.model.images =
        showsThumbnails ? listed.reduce(into: [:]) { $0[$1.id] = self.shots.cached($1.id) } : [:]
      self.model.closable = Set(listed.filter(self.lister.canClose).map(\.id))
      self.model.plan = plan
      self.model.edge = edge
      self.model.showsThumbnails = showsThumbnails
      if !sameApp { self.model.generation += 1 }
    }
    let reduced = Style.reduceMotion
    if switching {
      withAnimation(Style.Motion.settle.animation(reduced: reduced)) { update() }
      move(panel, to: frame, animated: !reduced)
    } else {
      update()
      panel.setFrame(frame, display: false)
      if panel.isVisible {
        // 还在淡出（刚收、马上又叫出来）：不再淡入，直接不透明（Whisker §4 面板进出）
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0
          panel.animator().alphaValue = 1
        }
      } else {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animateIn(edge: edge, reduced: reduced)
      }
      startWatching()
    }
    if showsThumbnails { capture(listed, thumbs: plan.thumbs, scale: screen.backingScaleFactor) }
  }

  /// 排好、算出面板的帧（夹进这块屏）
  private func layout(
    _ windows: [DockWindow], item: CGRect, edge: DockPreviewLayout.Edge, screen: NSScreen,
    compact: Bool
  ) -> (DockPreviewLayout.Plan, NSRect) {
    let room = DockPreviewLayout.room(
      item: item, edge: edge, screen: screen.frame, visible: screen.visibleFrame)
    let plan = DockPreviewLayout.plan(
      windows.map(\.size), edge: edge, along: room.along, across: room.across, compact: compact)
    let origin = DockPreviewLayout.origin(
      panel: plan.panel, item: item, edge: edge, screen: screen.frame,
      visible: screen.visibleFrame)
    return (plan, NSRect(origin: origin, size: plan.panel))
  }

  /// 入场，同 OverlayPanel.animateIn：窗口淡入（fadeIn），内容从图标那边错开 6 点弹回（弹簧 0.24 / 0.12），材质本身不动；
  /// 减弱动态效果时只淡入
  private func animateIn(edge: DockPreviewLayout.Edge, reduced: Bool) {
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
    guard !reduced, let layer = host?.layer else { return }
    let rise = CASpringAnimation(perceptualDuration: 0.24, bounce: 0.12)
    // AppKit 图层 y 向上：程序坞在下面时从下方 6 点升上来，在左右两边时从那一侧出来
    rise.keyPath = edge.isHorizontal ? "transform.translation.y" : "transform.translation.x"
    rise.fromValue = edge == .right ? 6 : -6
    rise.toValue = 0
    rise.duration = rise.settlingDuration
    layer.add(rise, forKey: "enter")
  }

  /// 换图标、关掉一扇后面板滑到新位置、改尺寸。内容铺满宿主，大小只跟着窗口走，不另走一条曲线
  /// ponytail: 窗口帧动画只能用贝塞尔，这里是 glide（0.26 s）的近似（同 OverlayPanel），中途换目标会丢掉速度；
  /// 要真弹簧得改成一块固定的大窗口、里面的内容层做弹簧位移
  private func move(_ panel: NSPanel, to frame: NSRect, animated: Bool) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animated ? 0.26 : 0
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
      panel.animator().setFrame(frame, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { panel.invalidateShadow() }
    }
  }

  /// 一张张当场截（主线程外缩小）；换了 App、收起了就停
  private func capture(_ windows: [DockWindow], thumbs: [CGSize], scale: CGFloat) {
    capturing?.cancel()
    let generation = model.generation
    capturing = Task { [weak self] in
      for (window, thumb) in zip(windows, thumbs) {
        guard let self, !Task.isCancelled, self.model.generation == generation else { return }
        let box = CGSize(width: thumb.width * scale, height: thumb.height * scale)
        guard let image = await self.shots.shoot(window, maxPixels: box) else { continue }
        guard !Task.isCancelled, self.model.generation == generation else { return }
        self.model.images[window.id] = image
      }
    }
  }

  func hide(animated: Bool) {
    pendingShow?.cancel()
    capturing?.cancel()
    stopWatching()
    shown = nil
    guard let panel, panel.isVisible else { return clearContent() }
    onHide()
    guard animated, !Style.reduceMotion else {
      panel.orderOut(nil)
      return clearContent()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeOut
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // 淡的时候又弹出来了就别收
        guard let self, self.shown == nil else { return }
        panel.orderOut(nil)
        self.clearContent()
      }
    }
  }

  private func clearContent() {
    model.windows = []
    model.images = [:]
    model.closable = []
  }

  // MARK: 弹着时

  /// 每 0.1 秒：别的功能来了就收；鼠标离开面板、图标和中间那道缝 0.3 秒就收
  private func startWatching() {
    guard watch == nil else { return }
    let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    RunLoop.main.add(timer, forMode: .common)
    watch = timer
    watchClicks()
  }

  private func stopWatching() {
    watch?.invalidate()
    watch = nil
    linger = DockPreviewLayout.Linger()
    for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
    clickMonitors = []
  }

  private func check() {
    guard let shown, let panel else { return stopWatching() }
    if isSuppressed() { return hide(animated: false) }
    let inside = DockPreviewLayout.keepsOpen(
      mouse: NSEvent.mouseLocation, panel: panel.frame, item: shown.item.frame, edge: model.edge)
    if linger.update(inside: inside, now: CACurrentMediaTime()) { hide(animated: true) }
  }

  /// 弹着时点了面板以外的任何地方（别的 App、程序坞的图标、本 App 自己的别的窗口）就收；点那个图标收起的，
  /// 鼠标离开它之前不再弹
  private func watchClicks() {
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.clickedOutside() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        if let self, event.window !== self.panel { self.clickedOutside() }
      }
      return event
    }
    clickMonitors = [global, local].compactMap { $0 }
  }

  private func clickedOutside() {
    dismissedURL = shown?.item.bundleURL
    hide(animated: false)
  }

  // MARK: 点了

  private func open(_ window: DockWindow) {
    // 换 App 交叉淡变时点到的可能是旧那排的卡片：不是现在列着的就不理
    guard let shown, model.windows.contains(where: { $0.id == window.id }) else { return }
    lister.focus(window, of: shown.app)
    hide(animated: false)
  }

  private func close(_ window: DockWindow) {
    guard let shown, let panel, model.windows.contains(where: { $0.id == window.id }),
      lister.close(window)
    else { return }
    // 关掉的先拿掉（App 要是弹「要不要存」，那扇其实还在，下次停上去再列出来）；按同一个图标重新排、夹进屏幕
    let windows = model.windows.filter { $0.id != window.id }
    guard !windows.isEmpty else { return hide(animated: true) }
    let (plan, frame) = layout(
      windows, item: shown.item.frame, edge: model.edge, screen: shown.screen,
      compact: !model.showsThumbnails)
    withAnimation(Style.Motion.settle.animation()) {
      model.windows = Array(windows.prefix(plan.thumbs.count))
      model.plan = plan
    }
    move(panel, to: frame, animated: !Style.reduceMotion)
  }

  // MARK: 窗口

  /// 探针也用（屏上量面板占多少）
  func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    let (root, background) = OverlayPanel.makeBackground()
    let host = PreviewHost(rootView: DockPreviewView(model: model))
    host.sizingOptions = []
    host.wantsLayer = true  // 入场的错开弹回动在它的图层上
    host.frame = background.bounds
    host.autoresizingMask = [.width, .height]
    background.addSubview(host)
    panel.contentView = root
    self.panel = panel
    self.host = host
    return panel
  }

  /// 程序坞在哪一边（系统设置 › 桌面与程序坞「在屏幕上的位置」，存在 com.apple.dock 的 orientation）
  private static func dockOrientation() -> String? {
    UserDefaults.standard.persistentDomain(forName: DockWatcher.bundleID)?["orientation"] as? String
  }
}

/// 面板的宿主：第一下点击就给（本 App 不激活，面板永不当 key）
private final class PreviewHost: NSHostingView<DockPreviewView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
