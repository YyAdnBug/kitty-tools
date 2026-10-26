// 晾衣绳（第十族，2026-10-26 拍板；SPEC 和拍板页在 macos/build/research/clothesline-2026-10-26/，规矩在
// mac-overlay-panel §14、长相在 mac-whisker-capture.mdc「晾衣绳」）：截完图挂到屏幕顶上一根绳子上，
// 手边常备一排——它和右下角的常驻缩略图二选一（设置 › 截图「截完图放哪」，拍板 B1）。
// 挂的就是截图历史里的那几条（拍板 B2：挂着的在这里记一笔，取下只是把这一笔去掉，历史不动；历史里删掉的跟着没），
// 不另存一份数据，也不跨重启（B3：退出即清）。最多 8 张、屏幕窄时按宽度减，超了最旧的自动取下（还在历史里）。
// 什么时候出来（C1 D3）：鼠标停在菜单栏那一条上 0.3 秒滑下来，离开 0.4 秒收起；只在鼠标所在的那块屏上，换屏跟过去；
// 另有一个可设的全局快捷键（HotKeyAction.clothesline，默认不占键）。收不收按鼠标位置算，不用追踪区的进出
// （面板改尺寸会重建追踪区、淡出时进来的事件会丢，同程序坞预览 mac-dock-preview §5）。
// 面板是普通 NSPanel 实例（不子类化，mac-overlay-panel §1）：无边框、不激活本 App、永不当 key、状态栏层级
// （截图的冻结帧和录屏的白名单按层级都不收它）、所有桌面上都在；**不加 fullScreenAuxiliary**，所以别的 App
// 全屏占着那块屏时它不出来（拍板 D3，同便签屏幕边缘的药丸）。整块透明、没有毛玻璃底：透明的地方系统自己点穿，
// 只有卡片接鼠标。永不当 key，所以收起直接淡掉窗口自己的透明度（OverlayPanel 要替身是因为淡出时它还当着 key）。
// 内容在 ClotheslineView.swift，几何和时机在 ClotheslineLayout.swift（纯函数）。

import AppKit
import SwiftUI

/// 绳子上要画的东西（Clothesline 填，视图只读）
@Observable final class ClotheslineModel {
  /// 挂着的历史编号，挂上的先后（先挂上的靠外）。**它就是「挂着」那个标记**（拍板 B2）：不进库、不跨重启
  private(set) var pegged: [UUID] = []
  /// 这块屏上排好的样子（面板内坐标）
  var plan = ClotheslineLayout.Plan()
  /// 截图历史：绳子只是它的一个视图（B2）。这次用不了（功能关着、历史关着）时是 nil，什么都挂不上
  @ObservationIgnored let history: ShotHistory?

  init(history: ShotHistory?) { self.history = history }

  /// 挂着、而且历史里还在的那几条（历史里删掉的跟着没，B2）。
  /// ponytail: 8 张各在历史里线性找一遍（历史几千条时也就几万次比较，都在一次重画里）；慢了再给历史加一张按编号的表
  var items: [ShotHistory.Item] {
    guard let history else { return [] }
    return pegged.compactMap { id in history.items.first { $0.id == id } }
  }

  var isEmpty: Bool { items.isEmpty }

  /// 换一批（Clothesline 算好容量之后给）
  func setPegged(_ ids: [UUID]) { pegged = ids }
}

@MainActor final class Clothesline {
  let model: ClotheslineModel
  /// 别的功能占着屏幕时不出来（AppDelegate 给：截图框选 / 长截图中、状态屏、启动台开着）
  var isSuppressed: () -> Bool = { false }
  /// 收起了（AppDelegate 拿它排空闲回收）
  var onHide: () -> Void = {}
  /// 这块屏上刘海那一块（中间给刘海岛让位，拍板 C2）；单测和截图自检注入
  var notch: (NSScreen) -> CGRect? = { Island.notchRect(of: $0) }

  private var panel: NSPanel?
  private var host: ClotheslineHost?
  /// 挂在哪块屏上（nil = 收着）
  private var shown: NSScreen?
  /// 等着滑下来的那一下（鼠标离开那一条就作废）
  private var pendingShow: Task<Void, Never>?
  /// 刚挂上去：先亮着不收（看得见它落在哪）
  private var holdUntil: ContinuousClock.Instant?
  /// 出来之后看鼠标在哪的定时器（收着时不跑）
  private var watch: Timer?
  private var linger = ClotheslineLayout.Linger()
  /// 挂着东西时才装的鼠标监听（绳子上空着时一点开销都不要）
  private var monitors: [Any] = []
  private var started = false

  init(history: ShotHistory?) { model = ClotheslineModel(history: history) }

  var isEmpty: Bool { model.isEmpty }

  // MARK: 起停

  /// 起（截图这个功能开着时）：挂着东西才真去听鼠标
  func start() {
    started = true
    updateWatching()
  }

  /// 停（关掉截图功能、退出）：收起、取下全部（挂着的标记本来就不跨重启）
  func stop() {
    started = false
    model.setPegged([])
    hide(animated: false)
    updateWatching()
  }

  /// 空闲回收：收着时把整块面板放掉（下次再建）
  func reclaim() {
    guard shown == nil, let old = panel else { return }
    panel = nil
    host = nil
    old.orderOut(nil)
    old.contentView = nil
    old.close()
  }

  // MARK: 挂上、取下

  /// 挂一张上去（截图 / 长截图 / 录制刚进历史的那一条）：挂满了最旧的自动取下（还在历史里，拍板 B3），
  /// 出来摇一下、先亮 2.5 秒
  func peg(_ id: UUID) {
    guard started, model.history != nil else { return }
    var ids = model.pegged.filter { $0 != id }
    ids.append(id)
    model.setPegged(trimmed(ids, on: screenForMouse()))
    holdUntil = .now.advanced(by: ClotheslineLayout.pegHold)
    updateWatching()
    if let screen = screenForMouse() { present(on: screen) }
  }

  /// 取下（只去掉「挂着」这一笔，历史不动，拍板 B2 D2）
  func unpeg(_ id: UUID) {
    guard model.pegged.contains(id) else { return }
    withAnimation(Style.Motion.settle.animation()) {
      model.setPegged(model.pegged.filter { $0 != id })
      replan()
    }
    if model.isEmpty { hide(animated: true) }
    updateWatching()
  }

  /// 下一张挂在哪（屏幕坐标）：截图的飞行卡片照它落地（拍板 B1）。pixels 是原图的像素尺寸；
  /// 挂不上（历史关着、绳子一张都放不下）时 nil
  func slot(for pixels: CGSize, on screen: NSScreen) -> CGRect? {
    guard started, model.history != nil else { return nil }
    var sizes = model.items.map(\.pixelSize)
    sizes.append(pixels)
    let width = screen.frame.width
    let gap = ClotheslineLayout.gap(notch: notch(screen))
    while sizes.count > 1, ClotheslineLayout.fits(sizes, width: width, gap: gap) < sizes.count {
      sizes.removeFirst()
    }
    let plan = ClotheslineLayout.plan(sizes, width: width, gap: gap)
    // 新的那一张排在最后（挂上的先后）
    guard let card = plan.cards.last, plan.cards.count == sizes.count else { return nil }
    return Self.screenRect(card, in: Self.panelFrame(for: screen))
  }

  /// 挂不下的先从最旧的取下来（还在历史里）
  private func trimmed(_ ids: [UUID], on screen: NSScreen?) -> [UUID] {
    guard let screen, let history = model.history else { return ids }
    var ids = ids
    let gap = ClotheslineLayout.gap(notch: notch(screen))
    while ids.count > 1 {
      let sizes = ids.compactMap { id in history.items.first { $0.id == id }?.pixelSize }
      guard
        ClotheslineLayout.fits(sizes, width: screen.frame.width, gap: gap) < sizes.count
      else { break }
      ids.removeFirst()
    }
    return ids
  }

  // MARK: 出来、收起

  /// 全局快捷键（C1）：出来 / 收起
  func toggle() {
    guard started, !model.isEmpty else { return }
    if shown != nil { return hide(animated: true) }
    guard let screen = screenForMouse() else { return }
    holdUntil = .now.advanced(by: ClotheslineLayout.pegHold)
    present(on: screen)
  }

  private func present(on screen: NSScreen) {
    pendingShow?.cancel()
    pendingShow = nil
    guard started, !model.isEmpty, !isSuppressed() else { return }
    let panel = self.panel ?? makePanel()
    replan(for: screen)
    let frame = Self.panelFrame(for: screen)
    let moving = shown != nil && panel.isVisible
    shown = screen
    linger = ClotheslineLayout.Linger()
    if moving {
      // 换屏跟过去（D3）：直接挪，不再滑一次
      panel.setFrame(frame, display: true)
    } else {
      panel.setFrame(frame, display: false)
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Style.fadeIn
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
      }
      slide(down: true)
    }
    startWatching()
  }

  /// 滑下来 / 收回去：窗口淡入淡出，内容在菜单栏下面上下滑（glide 弹簧）。
  /// 减弱动态效果时 caAnimation 给 nil，只剩淡入淡出（拍板 D1）
  private func slide(down: Bool) {
    guard let layer = host?.layer else { return }
    layer.transform = CATransform3DIdentity
    guard
      let slide = Style.Motion.glide.caAnimation(keyPath: "transform.translation.y")
        as? CASpringAnimation
    else { return }
    // AppKit 图层 y 向上：收着时内容在面板上面（菜单栏底下，看不见）
    slide.fromValue = down ? ClotheslineLayout.panelHeight : 0
    slide.toValue = down ? 0 : ClotheslineLayout.panelHeight
    layer.add(slide, forKey: "slide")
  }

  func hide(animated: Bool) {
    pendingShow?.cancel()
    pendingShow = nil
    holdUntil = nil
    stopWatching()
    guard shown != nil else { return }
    shown = nil
    guard let panel, panel.isVisible else { return }
    onHide()
    guard animated, !Style.reduceMotion else {
      panel.orderOut(nil)
      return
    }
    slide(down: false)
    NSAnimationContext.runAnimationGroup { context in
      // 和滑回去的位移同时跑（0.18 s：淡得太快就看不见它滑上去了）
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // 淡的时候又出来了就别收
        guard let self, self.shown == nil else { return }
        panel.orderOut(nil)
      }
    }
  }

  // MARK: 排版

  private func replan(for screen: NSScreen? = nil) {
    guard let screen = screen ?? shown else { return }
    model.plan = ClotheslineLayout.plan(
      model.items.map(\.pixelSize), width: screen.frame.width,
      gap: ClotheslineLayout.gap(notch: notch(screen)))
  }

  /// 面板：贴在菜单栏下沿、铺满这块屏的宽度
  static func panelFrame(for screen: NSScreen) -> CGRect {
    let top = ClotheslineLayout.top(
      screen: screen.frame, visible: screen.visibleFrame, menuBar: NSStatusBar.system.thickness)
    return CGRect(
      x: screen.frame.minX, y: top - ClotheslineLayout.panelHeight, width: screen.frame.width,
      height: ClotheslineLayout.panelHeight)
  }

  /// 这块屏上菜单栏那一条（停上去就滑下来、停在上面不收）
  static func strip(for screen: NSScreen) -> CGRect {
    ClotheslineLayout.strip(
      screen: screen.frame, visible: screen.visibleFrame, menuBar: NSStatusBar.system.thickness)
  }

  /// 面板内坐标（原点左上）→ 屏幕坐标
  static func screenRect(_ rect: CGRect, in panel: CGRect) -> CGRect {
    CGRect(
      x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  // MARK: 鼠标

  /// 挂着东西、而且起着，才去听鼠标
  private func updateWatching() {
    guard started, !model.isEmpty else { return unwatchMouse() }
    watchMouse()
  }

  /// 只看位置、不吞事件；鼠标移动不要辅助功能授权（同刘海岛、程序坞预览）
  private func watchMouse() {
    guard monitors.isEmpty else { return }
    let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      MainActor.assumeIsolated { self?.moved() }
      return event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      MainActor.assumeIsolated { self?.moved() }
    }
    monitors = [local, global].compactMap { $0 }
  }

  private func unwatchMouse() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    pendingShow?.cancel()
    pendingShow = nil
    if shown != nil { hide(animated: false) }
  }

  /// 收着时：鼠标停到菜单栏那一条上 0.3 秒就滑下来（出来之后交给定时器）
  private func moved() {
    guard shown == nil, !isSuppressed() else { return }
    guard let screen = screenForMouse(), wantsShow(on: screen) else {
      pendingShow?.cancel()
      pendingShow = nil
      return
    }
    guard pendingShow == nil else { return }
    pendingShow = Task { [weak self] in
      try? await Task.sleep(for: ClotheslineLayout.showDelay)
      guard !Task.isCancelled, let self else { return }
      self.pendingShow = nil
      // 这 0.3 秒里可能挪到别的屏上去了：现取
      guard let screen = self.screenForMouse(), self.wantsShow(on: screen) else { return }
      self.present(on: screen)
    }
  }

  private func wantsShow(on screen: NSScreen) -> Bool {
    ClotheslineLayout.wantsShow(
      mouse: NSEvent.mouseLocation, strip: Self.strip(for: screen), notch: notch(screen))
  }

  private func screenForMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  }

  private func startWatching() {
    guard watch == nil else { return }
    let timer = Timer(timeInterval: ClotheslineLayout.watchInterval, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    RunLoop.main.add(timer, forMode: .common)
    watch = timer
  }

  private func stopWatching() {
    watch?.invalidate()
    watch = nil
    linger = ClotheslineLayout.Linger()
  }

  /// 出来之后每 0.1 秒：别的功能来了、挂着的没了就收；换屏跟过去；鼠标离开满 0.4 秒收起
  private func check() {
    guard let screen = shown, let panel else { return stopWatching() }
    if isSuppressed() || model.isEmpty { return hide(animated: false) }
    guard let under = screenForMouse() else { return }
    if under !== screen, wantsShow(on: under) { return present(on: under) }
    if let holdUntil {
      guard .now >= holdUntil else {
        linger = ClotheslineLayout.Linger()
        return
      }
      self.holdUntil = nil
    }
    let inside = ClotheslineLayout.keepsOpen(
      mouse: NSEvent.mouseLocation, panel: panel.frame, strip: Self.strip(for: screen))
    if linger.update(inside: inside, now: CACurrentMediaTime()) { hide(animated: true) }
  }

  // MARK: 窗口

  private func makePanel() -> NSPanel {
    // styleMask 在 init 里一次写全（.nonactivatingPanel 之后再加不生效）
    let panel = NSPanel(
      contentRect: CGRect(origin: .zero, size: CGSize(width: 100, height: 100)),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    // 本 App 失活时不收（NSPanel 默认收）
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // 卡片自己带阴影（Style.shotCard），窗口不要系统阴影：整块透明的窗口会画出一圈方的影子
    panel.hasShadow = false
    panel.level = .statusBar
    // 所有桌面上都在；**不加 fullScreenAuxiliary**：别的 App 全屏占着那块屏时不出来（拍板 D3）
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    let host = ClotheslineHost(rootView: ClotheslineView(model: model))
    host.sizingOptions = []
    host.wantsLayer = true  // 滑下来的位移动在它的图层上
    panel.contentView = host
    self.panel = panel
    self.host = host
    return panel
  }
}

/// 面板的宿主：第一下点击就给卡片（本 App 不激活、面板永不当 key）
private final class ClotheslineHost: NSHostingView<ClotheslineView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
