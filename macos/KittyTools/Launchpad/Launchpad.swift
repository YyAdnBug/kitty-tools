// 启动台的总控（SPEC §5）：热键 / 菜单栏 / 现有启动器 / 触发角都调 toggle()。管本机 App 目录的刷新、
// 布局的读写（Prefs.launchpadLayout，JSON 字符串）、第一次用的默认排法、面板的建立与释放、打开 App。
// 不激活本 App（mac-overlay-panel 的规矩）；和别的浮层互斥由 AppDelegate 的 willOpen / hidePanels 接线。
// 面板收起后放掉窗口和界面（R11）。图标在后台画成位图、常驻（2026-10-18 真机反馈「第一次打开卡一阵」，用户定的常驻）；
// 背景是那块屏的壁纸模糊后的样子（LaunchpadWallpaper），第一次自动导入旧布局时岛上先挂「正在排列…」。
// 触控板捏合（TouchpadWatcher）和触发角（LaunchpadCorner）也由它拿着：applySettings() 按偏好和系统手势开关起停。
// 2026-10-19 起捏合跟手（GESTURE.md A）：认到开始捏就建面板（透明、不收鼠标、不拿键盘），画面跟着手指走，松手按进度和速度
// 打开（这时才 makeKey）或缩回；开着时张开手指同样跟手收起。所有入口的开关都由那块面板的 `LaunchpadZoom` 走同一条弹簧。
// 2026-10-18 四批评审之后：面板先出、刘海岛的提示后出（F14）；收起的簿记按窗口记，旧的收晚到也只会收走自己（F20）；
// 内容晚一拍再拆（F21）；删 App 走 NSWorkspace.recycle、失败带「在访达里看」（F22）；失去 key 时看新 key 是不是自己的（F23）；
// 布局「存过但读不出来」时原文另存、这次只在内存里用默认排法（F27）；撤销存在偏好里，重启后还能用一次（F41）；
// App 目录在后台扫、扫完接上，导入也在后台（F31）。
// 只在 macOS 26 起有（`isAvailable`，2026-10-19 用户定）：15 上系统自带启动台，我们的整个藏起来、什么都不起。

import AppKit
import SwiftUI

@MainActor
final class Launchpad {
  /// 只在 macOS 26 起有：系统自带的启动台 15 是最后一版（26 删了），15 上用系统的、我们的整个藏起来——菜单栏、启动器、
  /// 快捷键页、速查表、设置侧栏都没有它，快捷键不注册，不扫目录、不起捏合和触发角。排法和快捷键照旧存着、导出导入照旧带上（升到 26 就出来）
  nonisolated static let isAvailable: Bool = {
    if #available(macOS 26, *) { return true }
    return false
  }()

  /// 这台系统有、总开关也开着
  static var isOn: Bool {
    isAvailable && UserDefaults.standard.bool(forKey: Prefs.launchpadEnabled)
  }

  /// 刘海岛（打不开 App、导入 / 恢复默认的结果）
  var island: Island?
  /// 现在能不能打开（截图框选、录屏、状态屏、正在录快捷键…时不能）
  var canOpen: () -> Bool = { true }
  /// 打开之前把别的浮层收起（剪贴板、启动器、选状态、快速记一条、翻译浮窗）
  var willOpen: () -> Void = {}
  private(set) var isOpen = false
  /// 打开中的窗口 / 收起的簿记（F20：按窗口记，不信一个全局代号）
  private let book = LaunchpadWindowBook()
  private var panel: LaunchpadPanel? { book.panel as? LaunchpadPanel }
  private var model: LaunchpadModel?
  private var catalog: [LaunchpadProjectApp] = []
  private var signature: [Date?] = []
  private var screen: NSScreen?
  private let icons = LaunchpadIcons(synchronous: false)
  private let wallpaper = LaunchpadWallpaper()
  /// 上一次打开看的是第几页（F24：关掉再开回到那一页）
  private var lastPage = 0
  private var prepareTask: Task<Void, Never>?
  private var importTask: Task<Void, Never>?
  /// 本次打开是「还没存过布局」：等目录扫完（或马上）自动按系统旧库导入一次
  private var pendingAutoImport = false
  /// 正在拖时来的布局（导入、恢复默认）：松手再换（G26）
  private var pendingLayout: LaunchpadLayout?
  /// 正在拖 / 正在搜时扫完的目录还没并进布局（G14）
  private var mergePending = false
  /// 上一次导入 / 恢复默认之前的布局：设置页和岛上的「撤销」用它（只留一份；存在偏好里，重启后还在，F41）
  private var undoLayout: LaunchpadLayout?
  /// 换屏 / 拔掉屏的通知：总控和 App 同寿命，不注销（deinit 是 nonisolated，碰不了它）
  private var screenObserver: NSObjectProtocol?
  /// 触控板捏合（SPEC §5.6，R7）：功能开着就注册回调；系统的捏合开着时认到也不打开（开始捏的那一刻读系统设置）
  private let touchpad = TouchpadWatcher()
  /// 触发角（SPEC §5.7，R8）
  private let corner = LaunchpadCorner()
  /// 现在这块面板的开 / 收进度（窗口透明度 + 上面那层的缩放）；收起时交给那块面板自己走完
  private var zoom: LaunchpadZoom?
  /// 正在跟手的那一下：捏合 = 正在打开，张开 = 正在收起；nil = 没在跟
  private var pinchTracking: PinchRecognizer.Gesture?
  /// 捏合建的面板还没定开不开（松手走完才算打开）：这期间不自动导入、不出提示
  private var awaitingCommit = false
  /// 捏合打开时先压着的提示（排列读不出来）：松手定了打开才出，捏一下又退回去的不出
  private var deferredNotice: (() -> Void)?
  /// 跟手时看触控板还有没有在报帧：设备中途断开（妙控板没电）就收不到松手了
  private var pinchWatchdog: Task<Void, Never>?
  /// 调度中心开着时要打开：等它退干净再开（`openAfterMissionControl`）
  private var missionControlWait: Task<Void, Never>?

  init() {
    undoLayout = LaunchpadUndo.load(from: .standard)
    touchpad.onPinch = { [weak self] event in self?.pinch(event) }
    corner.onTrigger = { [weak self] in
      guard let self, canOpen(), !isOpen else { return }
      open()
    }
    corner.isLaunchpadOpen = { [weak self] in self?.isOpen ?? false }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // 换屏 / 拔掉屏：全屏面板跟着收起（下次按鼠标所在的屏重新开，SPEC R9），触发角重新摆
        if self.isOpen { self.close(animated: false) }
        self.applyCorner()
      }
    }
  }

  // MARK: 打开 / 收起

  func toggle() {
    if isOpen { close(animated: true) } else { open() }
  }

  /// 打开；`interactive` = 捏合开始时建的（跟着手指走，松手才定开不开）。返回真的建了面板没有
  @discardableResult
  func open(interactive: Bool = false) -> Bool {
    guard !isOpen else { return false }
    guard Self.isOn else { return false }
    guard canOpen() else {
      NSSound.beep()
      return false
    }
    // 调度中心开着：先让它退，退干净了再开（捏合的也不跟手，直接开）
    if missionControlWait != nil || LaunchpadMissionControl.isActive() {
      openAfterMissionControl()
      return false
    }
    willOpen()
    prepare()
    // 已经画好的不再画；启动时启动台还关着、刚打开的话这里补上
    icons.prewarm(catalog, pixelSize: Self.iconPixelSize)
    guard
      let screen = NSScreen.screens.first(where: {
        NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
      }) ?? NSScreen.main
    else { return false }
    self.screen = screen
    let capacity = Self.capacity
    let stored = LaunchpadLayout.stored(in: .standard)
    let plan = LaunchpadLayout.openingPlan(
      stored: stored, apps: catalog.map(\.ref), defaults: Self.defaultApps(catalog),
      capacity: capacity)
    let layout = plan.layout
    var notice: (title: String, detail: String?, symbol: String)?
    if case .unreadable(let text) = stored {
      // 存过、读不出来：原文另存一份，这次只在内存里用默认排法，**不写盘**（用户第一次改动才写，F27）
      UserDefaults.standard.set(text, forKey: Prefs.launchpadLayoutUnreadable)
      notice = ("排列读不出来，先按默认排法打开", "原来的排布另存了一份，没有被覆盖", "exclamationmark.triangle")
    }
    if case .missing = stored {
      // 第一次打开（还没存过布局）：面板先出，这一帧过去再按系统旧启动台导入（SPEC §3.6 / R9，F31）
      pendingAutoImport = true
    }
    if plan.shouldSave { save(layout) }
    // 上一次打开时压着没换的（那次收起前没松手）已经存进偏好、这次读到的就是：别留到这一次再拿旧的盖上来
    pendingLayout = nil
    mergePending = false
    let model = LaunchpadModel(
      layout: layout, catalog: catalog, icons: icons, columns: Self.columns, rows: Self.rows,
      screenSize: screen.frame.size, startPage: lastPage)
    model.onClose = { [weak self] in self?.close(animated: true) }
    // 只认现在这块的：收起途中的旧面板还是 key，按 ↩ 打开 App 时别把新开的（正在捏的那块）收掉
    model.onOpenApp = { [weak self, weak model] app in
      guard let self, let model, model === self.model else { return }
      self.open(app)
    }
    model.onLayoutChange = { [weak self] layout in self?.save(layout) }
    model.onDeleteApp = { [weak self] app in self?.delete(app) }
    model.folderName = { first, second in
      LaunchpadCatalog.folderName(first: first, second: second)
    }
    // 壁纸：做过的直接用；没做过（第一次、换了壁纸）后台做好再换上，这次先是系统毛玻璃
    model.wallpaper = wallpaper.image(for: screen) { [weak model] image in
      model?.wallpaper = image
    }
    // 先停在「收着」：面板第一帧画完再走（present）
    model.zoom = 0
    self.model = model
    let panel = LaunchpadPanel(frame: screen.frame, model: model)
    let zoom = LaunchpadZoom(host: panel.contentView)
    zoom.apply = { [weak panel, weak model] value in
      panel?.alphaValue = value
      model?.zoom = value
    }
    self.zoom = zoom
    panel.onScroll = { [weak model] event in
      model?.scroll(
        deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
        precise: event.hasPreciseScrollingDeltas, phase: event.phase,
        momentum: event.momentumPhase, time: event.timestamp,
        inverted: event.isDirectionInvertedFromDevice)
    }
    panel.onNavigate = { [weak model] direction in model?.navigate(direction) }
    panel.onReturn = { [weak model] in model?.returnPressed() }
    panel.onCancel = { [weak model] in model?.cancel() }
    panel.onFirstPage = { [weak model] in model?.firstPage() }
    panel.onLastPage = { [weak model] in model?.lastPage() }
    panel.onCloseRequest = { [weak model] in model?.requestClose() }
    panel.onFlagsChanged = { [weak model] held in model?.optionChanged(held) }
    // 只认现在这块：收起途中的旧面板走完 orderOut 时也会失去 key，那时新开的那块（捏合建的，还没当过 key）不能被当成「别的 App 到前台」收掉
    panel.onResignKey = { [weak self, weak panel] in
      guard let self, let panel, panel === self.panel else { return }
      self.panelResignedKey()
    }
    panel.onSearchClick = { [weak model] in model?.searchClicked() }
    model.onSearchFocus = { [weak panel] focused in panel?.setSearchFocus(focused) }
    model.onSettled = { [weak self] in self?.applyPending() }
    book.adopt(panel)
    isOpen = true
    // 岛在面板之后出：面板一 orderFrontRegardless 就盖满屏，先出岛会被盖住（F14）
    let showNotice: (() -> Void)? = notice.map { notice in
      { [weak self] in
        self?.island?.show(notice.title, detail: notice.detail, symbol: notice.symbol)
      }
    }
    // 捏合建的：提示和第一次自动导入等松手定了打开再做（捏一下又退回去的不该导入布局、挂提示）
    awaitingCommit = interactive
    deferredNotice = interactive ? showNotice : nil
    LaunchpadOpenSequence.run(
      present: { present(panel, zoom: zoom, interactive: interactive) },
      notice: interactive ? nil : showNotice)
    if !interactive { autoImportIfNeeded() }
    return true
  }

  /// 调度中心开着时打开：它给窗口画的 ✕ 会盖在启动台上面、还点得到（调度中心不是普通窗口，层级调高也盖不住），所以先让它退；
  /// **等它退干净（WindowManager 那块 19 层窗口没了）再过 0.3 s 才打开**——退场还没走完就把面板盖上来、makeKey，
  /// WindowManager 的窗口排序会被打乱：之后某个应用的窗口一直压在最上面，切到别的应用也盖不过它，要重启 WindowManager 才好
  /// （2026-10-19 真机两次；独立小程序分开试过：光让它退不会，等退干净再盖面板也不会）。最多等 1.5 s，退不掉也照开
  private func openAfterMissionControl() {
    guard missionControlWait == nil else { return }
    LaunchpadMissionControl.dismiss()
    missionControlWait = Task { [weak self] in
      for _ in 0..<30 {
        try? await Task.sleep(for: .milliseconds(50))
        if !LaunchpadMissionControl.isActive() { break }
      }
      try? await Task.sleep(for: .milliseconds(300))
      guard let self else { return }
      self.missionControlWait = nil
      self.open()
    }
  }

  /// 收起；animated = false 用于打开别的窗口 / 截图 / 状态屏之前（不能留一块全屏面板盖着）
  func close(animated: Bool) {
    close(animated: animated, velocity: 0, forward: true)
  }

  /// `velocity`：开 / 收进度每秒变多少（张开松手时接着手指的速度）；`forward` = false 是捏到一半松手、倒着走打开那一段
  private func close(animated: Bool, velocity: Double, forward: Bool) {
    guard let panel = book.beginClose() as? LaunchpadPanel else { return }
    // 这块面板的模型在这里就取：走完的时候 self.model 可能已经是后来又开的那块的（G20）
    let closingModel = model
    lastPage = model?.page ?? lastPage
    model?.beginClosing(forward: forward)
    isOpen = false
    if awaitingCommit {
      // 捏一下又退回去：没真的打开过，第一次自动导入留到下次真打开（那时还没存过布局，会再排上）
      pendingAutoImport = false
      awaitingCommit = false
    }
    pinchTracking = nil
    pinchWatchdog?.cancel()
    deferredNotice = nil
    // 触发角：开着的时候离开角收不到事件，收起时鼠标不在角里就重新武装（不然要再离开一次才推得开）
    corner.launchpadDidClose()
    // 走的这一段里点击落到后面去（面板已经在淡掉了）
    panel.ignoresMouseEvents = true
    let zoom = self.zoom
    self.zoom = nil
    // 照 macOS 15：图标往前放大、整块淡掉（减弱动态效果时只淡掉，界面不缩）。这一份跟着这块面板走完，新开的面板用新的一份
    if animated, let zoom {
      zoom.onSettled = { [weak self] _ in self?.finishClose(panel, model: closingModel) }
      zoom.settle(to: 0, velocity: velocity, duration: LaunchpadZoom.closeDuration)
    } else {
      zoom?.stop()
      finishClose(panel, model: closingModel)
    }
  }

  /// 收尾按**窗口**做（F20）：哪怕收起动画还没完又打开了一块新的，晚到的 completion 也只收走自己；
  /// 内容和模型晚一拍再拆——收起可能是在这个面板的手势 / 按键回调里进来的（F21）
  private func finishClose(_ panel: LaunchpadPanel, model closingModel: LaunchpadModel?) {
    panel.orderOut(nil)
    // 这块面板的模型（收起那一刻取的）：晚一拍拆的时候只放它自己的（中间又开了一块新的，新模型不能被放掉，G20）
    DispatchQueue.main.async { [weak self] in
      // 面板在这里强持一拍：非动画收起时它在那一轮自动释放池倒掉时就没了，原来的 weak 拿不到、模型一直放不掉
      panel.contentView = nil
      guard let self, let closingModel, self.model === closingModel, !self.isOpen else { return }
      self.model = nil
    }
  }

  /// 打开：整块（壁纸和上面的图标）跟着窗口淡入，图标同时从 1.1 倍缩回原大（照 macOS 15），都由 `zoom` 一个数管。
  /// 淡入只在窗口上做一次：原来界面里再淡一遍，两层透明度相乘，开头那段几乎看不见、像是晚了一拍才出来。
  /// 捏合开始建的（`interactive`）：不收鼠标、不拿键盘，跟着手指走，松手定了打开才 `activate`
  private func present(_ panel: LaunchpadPanel, zoom: LaunchpadZoom, interactive: Bool) {
    panel.alphaValue = 0
    panel.ignoresMouseEvents = interactive
    panel.orderFrontRegardless()
    panel.layoutIfNeeded()
    if !interactive { activate(panel) }
    // 先把第一帧画好（建界面、上百个图标的图层，这一下最重），动画从画好之后才开始算：不然开头几帧被这一下吃掉，看着是跳出来的
    panel.displayIfNeeded()
    if interactive {
      zoom.track { [weak self] in self?.touchpad.pinchProgress ?? 0 }
    } else {
      zoom.settle(to: 1, duration: LaunchpadZoom.openDuration)
    }
  }

  /// 拿键盘：收鼠标、当 key、焦点进搜索框（initialFirstResponder，CommandTextField 挂进窗口时登记的；一打开就能打字，R3）
  private func activate(_ panel: LaunchpadPanel) {
    panel.ignoresMouseEvents = false
    panel.makeKey()
    if !(panel.firstResponder is NSText), let first = panel.initialFirstResponder {
      panel.makeFirstResponder(first)
    }
  }

  // MARK: 捏合跟手

  /// 识别器的三件事（已经在主线程）：开始捏（关着时）→ 建面板跟手；开始张开（开着时）→ 跟手收；松手 / 取消 → 走完或退回去
  private func pinch(_ event: PinchRecognizer.Event) {
    switch event {
    case .began(.pinch):
      // 系统手势可能在监听起来之后才被打开：认到的那一刻再读一次（F13）
      guard pinchTracking == nil, !isOpen, canOpen(), !systemPinchIsOn else { return }
      guard open(interactive: true) else { return }
      pinchTracking = .pinch
      watchPinch()
    case .began(.spread):
      guard pinchTracking == nil, isOpen, let model, !model.isClosing, let zoom else { return }
      pinchTracking = .spread
      model.zoomForward = true
      zoom.track { [weak self] in 1 - (self?.touchpad.pinchProgress ?? 0) }
      watchPinch()
    case .ended(let gesture, let progress, let velocity):
      guard pinchTracking == gesture else { return }
      pinchTracking = nil
      finishPinch(
        gesture, completes: PinchRecognizer.completes(progress: progress, velocity: velocity),
        velocity: velocity)
    case .cancelled(let gesture):
      guard pinchTracking == gesture else { return }
      pinchTracking = nil
      finishPinch(gesture, completes: false, velocity: 0)
    }
  }

  /// 松手之后走到哪（纯函数，单测）：`velocity` 是捏合 / 张开的进度每秒变多少。打开那一段 zoom 就是进度；
  /// 收起那一段 zoom = 1 − 进度，速度反号。`forward` 只对走到 0 有意义：张开收起往前冲出去，捏一半退回是倒着走打开那一段
  nonisolated static func release(
    _ gesture: PinchRecognizer.Gesture, completes: Bool, velocity: Double
  ) -> (target: Double, velocity: Double, forward: Bool) {
    switch (gesture, completes) {
    case (.pinch, true): (1, velocity, false)
    case (.pinch, false): (0, velocity, false)
    case (.spread, true): (0, -velocity, true)
    case (.spread, false): (1, -velocity, true)
    }
  }

  private func finishPinch(_ gesture: PinchRecognizer.Gesture, completes: Bool, velocity: Double) {
    pinchWatchdog?.cancel()
    guard let panel, let zoom else { return }
    let end = Self.release(gesture, completes: completes, velocity: velocity)
    if end.target == 0 {
      close(animated: true, velocity: end.velocity, forward: end.forward)
      return
    }
    zoom.settle(to: 1, velocity: end.velocity, duration: LaunchpadZoom.openDuration)
    guard gesture == .pinch else { return }
    // 定了打开：拿键盘，压着的提示和第一次自动导入这时才做
    awaitingCommit = false
    activate(panel)
    deferredNotice?()
    deferredNotice = nil
    autoImportIfNeeded()
  }

  /// 跟手期间每 0.5 s 看一眼触控板还在不在报帧（手指放着不动也一直有帧）：没涨 = 设备断了 / 监听没了，等不到松手，当取消。
  /// 不然面板半透明地挂着、不收鼠标也不拿键盘，Esc 都到不了它
  private func watchPinch() {
    pinchWatchdog?.cancel()
    pinchWatchdog = Task { [weak self] in
      var last = TouchpadWatcher.framesSeen
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let self, let gesture = self.pinchTracking else { return }
        let now = TouchpadWatcher.framesSeen
        if now == last {
          self.pinchTracking = nil
          self.finishPinch(gesture, completes: false, velocity: 0)
          return
        }
        last = now
      }
    }
  }

  /// 面板失去 key（F23）：新的 key 窗口不是自己的（确认框的 sheet、文件夹上弹出的东西）才收起。
  /// 打开 App 时那个 App 自己会变 key，这时也要收——它不挂在面板上，判断照样成立。
  private func panelResignedKey() {
    guard isOpen else { return }
    // 等这一轮 key 的交接走完再看：resignKey 发出来的时候 NSApp.keyWindow 可能还是自己
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isOpen else { return }
      guard LaunchpadPanelShouldClose.onResign(key: NSApp.keyWindow, own: self.panel) else {
        return
      }
      self.close(animated: false)
    }
  }

  // MARK: 本机 App 目录

  /// 扫目录（启动时预热一次，打开时按目录修改时间决定要不要重扫）。真正的扫描在后台（F31），
  /// 扫完接上：已经开着的话把新目录喂给模型、新装的接在最后。
  func prepare() {
    guard Self.isAvailable else { return }
    let signature = AppCatalog.signature()
    if !catalog.isEmpty, signature == self.signature {
      autoImportIfNeeded()
      return
    }
    self.signature = signature
    prepareTask?.cancel()
    prepareTask = Task { [weak self] in
      let apps = await LaunchpadCatalog.loadInBackground()
      guard !Task.isCancelled, let self else { return }
      let changed = self.catalog.map(\.id) != apps.map(\.id)
      self.catalog = apps
      // 图标在后台画好、常驻：打开时只贴位图（新装的 App 只补画它自己）。启动台关着时不画（约 15 MB），开了以后第一次打开再补
      if Self.isOn {
        self.icons.prewarm(apps, pixelSize: Self.iconPixelSize)
        if let screen = NSScreen.main { _ = self.wallpaper.image(for: screen) { _ in } }
      }
      if let model = self.model {
        model.adopt(catalog: apps)
        if changed, self.isOpen, !self.pendingAutoImport { self.mergeCatalogIntoOpenModel() }
      }
      self.autoImportIfNeeded()
    }
  }

  /// 扫完 / 导入完把目录喂进去（模型里按 id 找 App）。正在拖 / 正在搜时先压着，松手 / 清空搜索时接上（G14）
  private func mergeCatalogIntoOpenModel() {
    guard let model else { return }
    guard model.drag == nil, !model.isSearching else {
      mergePending = true
      return
    }
    mergePending = false
    let updated = model.layout.merged(apps: catalog.map(\.ref), capacity: Self.capacity)
    guard updated != model.layout else { return }
    model.replace(layout: updated)
    save(updated)
  }

  /// 换一份布局进开着的模型：正在拖的话等松手再换（G26：中途 replace 会把手里那一格换成别的 App）
  private func replaceOpenLayout(_ layout: LaunchpadLayout) {
    guard let model else { return }
    if model.drag != nil {
      pendingLayout = layout
    } else {
      model.replace(layout: layout)
    }
  }

  /// 松手 / 清空搜索之后：压着的布局、目录接上
  private func applyPending() {
    if let layout = pendingLayout, let model, model.drag == nil {
      pendingLayout = nil
      model.replace(layout: layout)
    }
    if mergePending { mergeCatalogIntoOpenModel() }
  }

  /// 第一次打开时自动导入旧库（F31）：目录还没扫出来就等扫完；导入在后台做，面板已经显示默认排法
  private func autoImportIfNeeded() {
    // 捏合建的面板还没定开不开：等松手（`finishPinch`）
    guard pendingAutoImport, !catalog.isEmpty, !awaitingCommit else { return }
    guard !LaunchpadLayout.isStored(in: .standard) else {
      pendingAutoImport = false
      return
    }
    pendingAutoImport = false
    let local = Self.localApps(catalog)
    let capacity = Self.capacity
    // 读旧库要一会儿：岛上先挂着「进行中」，排好换成结果（2026-10-18 真机反馈「卡一阵、没有提示」）
    island?.show("正在按原来的启动台排列…", tone: .progress, symbol: "square.grid.3x3")
    importTask?.cancel()
    importTask = Task { [weak self] in
      let result = await LaunchpadImport.readSystemLayoutInBackground(
        local: local, capacity: capacity)
      guard !Task.isCancelled, let self else { return }
      // 这期间用户可能已经动过布局（那就不要再覆盖）；进行中的提示照样换掉
      guard !LaunchpadLayout.isStored(in: .standard) else {
        self.island?.show("已保留你刚才的排列", symbol: "square.grid.3x3")
        return
      }
      let layout: LaunchpadLayout
      let detail: String?
      if let result, !result.layout.tiles.isEmpty {
        layout = result.layout.merged(apps: self.catalog.map(\.ref), capacity: capacity)
        detail = result.skipped > 0 ? "跳过 \(result.skipped) 个已经卸掉的 App" : nil
      } else {
        layout = LaunchpadLayout.defaultLayout(Self.defaultApps(self.catalog), capacity: capacity)
        detail = nil
      }
      self.save(layout)
      self.replaceOpenLayout(layout)
      self.island?.show(
        result == nil ? "已按默认排法排好" : "已按原来的启动台排好", detail: detail,
        symbol: "square.grid.3x3")
    }
  }

  /// 本机 App 现在有没有（删 App 前确认用）
  func app(id: String) -> LaunchpadProjectApp? { catalog.first { $0.id == id } }

  var apps: [LaunchpadProjectApp] { catalog }

  // MARK: 打开 App / 删除

  private func open(_ app: LaunchpadProjectApp) {
    // 照 macOS 15：启动台淡出、App 出来（2026-10-18 交互对齐；原来一下子消失）
    close(animated: true)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let name = app.name
    NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) {
      [weak self] _, error in
      guard let error else { return }
      let detail = error.localizedDescription
      Task { @MainActor [weak self] in
        self?.island?.show("打不开「\(name)」", detail: detail, tone: .warning)
      }
    }
  }

  /// 抖动模式里的 ✕（R6）：界面里已经确认过，这里移到废纸篓（NSWorkspace.recycle，异步，F22）再把布局拿掉。
  /// 只在 App Store 装的 App 上出现（SPEC R6），系统 App 不给删。失败时岛上带「在访达中显示」。
  private func delete(_ app: LaunchpadProjectApp) {
    guard LaunchpadCatalog.canDelete(app) else { return }
    LaunchpadRecycle.moveToTrash(app) { [weak self] success in
      guard let self else { return }
      guard success else {
        self.island?.show(
          "没能删掉「\(app.name)」",
          detail: "可能没有权限，或者它正在被使用；可以在访达里看它",
          tone: .warning,
          action: (
            title: "在访达中显示",
            run: { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
          ))
        return
      }
      self.catalog.removeAll { $0.id == app.id }
      guard let model = self.model else { return }
      let updated = model.layout.removing(app.id, capacity: Self.capacity)
      self.save(updated)
      model.adopt(catalog: self.catalog)
      model.replace(layout: updated)
      self.island?.show("已移到废纸篓", detail: app.name, symbol: "trash")
    }
  }

  // MARK: 布局

  /// 存盘；和存着的已经一样就不写（打开一次不重写、也不把「读不出来」的原文顶掉，F27）
  private func save(_ layout: LaunchpadLayout) {
    LaunchpadLayout.save(layout, to: .standard)
  }

  // MARK: 捏合和触发角（R7 / R8）

  /// 私有框架在这台 Mac 上能不能用（设置页那一行据此显示 / 灰掉）
  var pinchAvailable: Bool { TouchpadWatcher.libraryAvailable }

  /// 系统的捏合手势还开着没有（设置页每次出现读一次，不轮询）
  var systemPinchIsOn: Bool { TrackpadSystemGesture.systemPinchIsOn() }

  /// 要不要注册触控板回调（纯函数，单测直接喂）：功能开着、这一项开着、框架能用。
  /// **不看系统手势开没开**（2026-10-19 真机）：原来系统的开着就不注册，可系统设置改了我们收不到——Kitty 启动时系统的开着，
  /// 之后用户照提示关掉，捏合一直没反应，要开一次设置页才接上。现在一直注册，开始捏的那一刻再读系统的（`pinch`）
  nonisolated static func pinchShouldRun(enabled: Bool, usePinch: Bool, available: Bool) -> Bool {
    enabled && usePinch && available
  }

  /// 按偏好起停触控板监听和触发角（启动时、设置改了、导入设置之后调）
  func applySettings() {
    // macOS 15：什么都没起过，也就不用停；连私有框架都不去找
    guard Self.isAvailable else { return }
    let defaults = UserDefaults.standard
    let enabled = Self.isOn
    let fingers =
      PinchFingers(rawValue: defaults.string(forKey: Prefs.launchpadPinchGesture) ?? "") ?? .four
    let sensitivity =
      PinchRecognizer.Sensitivity(
        rawValue: defaults.string(forKey: Prefs.launchpadPinchSense) ?? "") ?? .standard
    // 系统的捏合还开着时我们认到也不打开（不然两个一起出来，SPEC R7）：在开始捏的那一刻读，不在这里挡
    if Self.pinchShouldRun(enabled: enabled, usePinch: fingers != .off, available: pinchAvailable) {
      touchpad.start(sensitivity: sensitivity, fingers: fingers)
    } else {
      touchpad.stop()
    }
    applyCorner()
  }

  private func applyCorner() {
    let enabled = Self.isOn
    let option =
      LaunchpadCornerOption(
        rawValue: UserDefaults.standard.string(forKey: Prefs.launchpadCorner) ?? "") ?? .off
    corner.apply(option: enabled ? option : .off, screens: NSScreen.screens)
  }

  /// 设置 › 启动台「从系统启动台重新导入…」（二次确认在设置页里）：导入前留一份，可在设置 / 岛上撤销一次
  func importFromSystem() {
    prepare()
    guard !catalog.isEmpty else {
      island?.show(
        "本机 App 目录还没扫出来", detail: "等几秒再试一次", tone: .warning, symbol: "square.grid.3x3")
      return
    }
    let local = Self.localApps(catalog)
    let capacity = Self.capacity
    island?.show("正在按原来的启动台排列…", tone: .progress, symbol: "square.grid.3x3")
    importTask?.cancel()
    importTask = Task { [weak self] in
      let result = await LaunchpadImport.readSystemLayoutInBackground(
        local: local, capacity: capacity)
      guard !Task.isCancelled, let self else { return }
      guard let result, !result.layout.tiles.isEmpty else {
        self.island?.show(
          "没找到系统启动台的数据", detail: "可能系统里已经没有了，或者读不了", tone: .warning,
          symbol: "square.grid.3x3")
        return
      }
      let old = LaunchpadLayout.load(from: .standard)
      self.setUndoLayout(old)
      let merged = result.layout.merged(apps: self.catalog.map(\.ref), capacity: capacity)
      self.save(merged)
      self.replaceOpenLayout(merged)
      // 之前没存过布局就没东西可撤：岛上不带「撤销」（G25）
      self.island?.show(
        "已按原来的启动台排好",
        detail: result.skipped > 0 ? "跳过 \(result.skipped) 个已经卸掉的 App" : nil,
        symbol: "square.grid.3x3", action: self.undoAction(after: old))
    }
  }

  /// 设置里改了一页几列几行：按新容量重新分页并存盘（启动台没开着也生效，下次打开就是新的页）
  func reflow() {
    guard let layout = LaunchpadLayout.load(from: .standard) else { return }
    let updated = layout.repaginated(capacity: Self.capacity)
    save(updated)
    replaceOpenLayout(updated)
  }

  /// 设置 › 启动台「恢复默认排列」（二次确认在设置页里）
  func resetToDefault() {
    prepare()
    // 目录还没扫出来时别存一个空的默认排法（G2）
    guard !catalog.isEmpty else {
      island?.show(
        "本机 App 目录还没扫出来", detail: "等几秒再试一次", tone: .warning, symbol: "square.grid.3x3")
      return
    }
    let old = LaunchpadLayout.load(from: .standard)
    let layout = LaunchpadLayout.defaultLayout(Self.defaultApps(catalog), capacity: Self.capacity)
    setUndoLayout(old)
    save(layout)
    replaceOpenLayout(layout)
    island?.show(
      "已恢复默认排列", detail: old == nil ? nil : "需要的话点「撤销」换回原来的",
      symbol: "arrow.uturn.backward", action: undoAction(after: old))
  }

  /// 撤销上一次导入 / 恢复默认（只留一份；存在偏好里，重启后还能用一次，F41）
  func undoLastLayoutChange() {
    guard let undoLayout else { return }
    setUndoLayout(nil)
    save(undoLayout)
    replaceOpenLayout(undoLayout)
    island?.show("已还原上一次的排列", symbol: "arrow.uturn.backward")
  }

  var canUndoLayout: Bool { undoLayout != nil }

  /// 岛上的「撤销」：之前没存过布局就没东西可撤，不带按钮（G25）。单独写成函数——直接在 Task 里写三目 + 捕获列表的闭包，
  /// Swift 6.2.4 的类型检查会崩
  private func undoAction(after old: LaunchpadLayout?) -> (title: String, run: () -> Void)? {
    guard old != nil else { return nil }
    return (title: "撤销", run: { [weak self] in self?.undoLastLayoutChange() })
  }

  private func setUndoLayout(_ layout: LaunchpadLayout?) {
    undoLayout = layout
    LaunchpadUndo.save(layout, to: .standard)
  }

  // MARK: 偏好

  static var capacity: Int { columns * rows }

  /// 图标位图的边长（像素）：所有屏里最大的那个图标 × 缩放倍数（换了更大的屏，下次扫完目录重画）
  static var iconPixelSize: Int {
    let sizes = NSScreen.screens.map {
      LaunchpadMetrics(size: $0.frame.size, columns: columns, rows: rows).icon
        * $0.backingScaleFactor
    }
    return Int((sizes.max() ?? 164).rounded(.up))
  }

  static var columns: Int {
    let value = UserDefaults.standard.integer(forKey: Prefs.launchpadColumns)
    return min(
      max(value, Prefs.launchpadColumnChoices.lowerBound), Prefs.launchpadColumnChoices.upperBound)
  }

  static var rows: Int {
    let value = UserDefaults.standard.integer(forKey: Prefs.launchpadRows)
    return min(
      max(value, Prefs.launchpadRowChoices.lowerBound), Prefs.launchpadRowChoices.upperBound)
  }

  /// 导入旧库时把库里的 bundle id / 标题对到本机路径
  private static func localApps(_ catalog: [LaunchpadProjectApp]) -> [LaunchpadImport.LocalApp] {
    catalog.map { LaunchpadImport.LocalApp(ref: $0.ref, name: $0.name) }
  }

  private static func defaultApps(_ catalog: [LaunchpadProjectApp]) -> [LaunchpadLayout.DefaultApp]
  {
    catalog.map {
      LaunchpadLayout.DefaultApp(
        ref: $0.ref, name: $0.name, isSystem: $0.isSystem, inUtilities: $0.inUtilities)
    }
  }
}

/// 撤销上一次导入 / 恢复默认的「上一次」（F41）：只留一份，存在偏好里，重启后还能用一次。
/// 纯读写，单测用注入的 suite。
nonisolated enum LaunchpadUndo {
  static func save(_ layout: LaunchpadLayout?, to defaults: UserDefaults) {
    if let text = layout?.jsonString() {
      defaults.set(text, forKey: Prefs.launchpadUndoLayout)
    } else {
      defaults.removeObject(forKey: Prefs.launchpadUndoLayout)
    }
  }

  static func load(from defaults: UserDefaults) -> LaunchpadLayout? {
    guard let text = defaults.string(forKey: Prefs.launchpadUndoLayout),
      let data = text.data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(LaunchpadLayout.self, from: data)
  }
}

/// 打开时的顺序（F14）：先把全屏面板摆上，再出岛；拆成纯函数单测锁住
nonisolated enum LaunchpadOpenSequence {
  static func run(present: () -> Void, notice: (() -> Void)?) {
    present()
    notice?()
  }
}
