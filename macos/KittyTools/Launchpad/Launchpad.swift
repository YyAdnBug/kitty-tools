// 启动台的总控（SPEC §5）：热键 / 菜单栏 / 现有启动器 / 触发角都调 toggle()。管本机 App 目录的刷新、
// 布局的读写（Prefs.launchpadLayout，JSON 字符串）、第一次用的默认排法、面板的建立与释放、打开 App。
// 不激活本 App（mac-overlay-panel 的规矩）；和别的浮层互斥由 AppDelegate 的 willOpen / hidePanels 接线。
// 面板收起后放掉窗口和界面（R11）；图标缓存留着，闲下来（两分钟）没再打开就清掉。
// 触控板捏合（TouchpadWatcher）和触发角（LaunchpadCorner）也由它拿着：applySettings() 按偏好和系统手势开关起停。
// 2026-10-18 四批评审之后：面板先出、刘海岛的提示后出（F14）；收起的簿记按窗口记，旧的收晚到也只会收走自己（F20）；
// 内容晚一拍再拆（F21）；删 App 走 NSWorkspace.recycle、失败带「在访达里看」（F22）；失去 key 时看新 key 是不是自己的（F23）；
// 布局「存过但读不出来」时原文另存、这次只在内存里用默认排法（F27）；撤销存在偏好里，重启后还能用一次（F41）；
// App 目录在后台扫、扫完接上，导入也在后台（F31）。

import AppKit
import SwiftUI

@MainActor
final class Launchpad {
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
  private let icons = LaunchpadIcons()
  /// 上一次打开看的是第几页（F24：关掉再开回到那一页）
  private var lastPage = 0
  /// 图标缓存空闲回收（R11；和别的浮层用同一个 IdleTimer，F42）
  private lazy var iconIdle = Memory.IdleTimer(
    after: Memory.idleDelay, isIdle: { [weak self] in self?.isOpen == false },
    work: { [weak self] in
      self?.icons.clear()
      Memory.relieve()
    })
  private var prepareTask: Task<Void, Never>?
  private var importTask: Task<Void, Never>?
  /// 本次打开是「还没存过布局」：等目录扫完（或马上）自动按系统旧库导入一次
  private var pendingAutoImport = false
  /// 上一次导入 / 恢复默认之前的布局：设置页和岛上的「撤销」用它（只留一份；存在偏好里，重启后还在，F41）
  private var undoLayout: LaunchpadLayout?
  /// 换屏 / 拔掉屏的通知：总控和 App 同寿命，不注销（deinit 是 nonisolated，碰不了它）
  private var screenObserver: NSObjectProtocol?
  /// 触控板捏合（SPEC §5.6，R7）：只在功能开着、系统的捏合关着时注册回调
  private let touchpad = TouchpadWatcher()
  /// 触发角（SPEC §5.7，R8）
  private let corner = LaunchpadCorner()

  init() {
    undoLayout = LaunchpadUndo.load(from: .standard)
    touchpad.onGesture = { [weak self] gesture in
      guard let self, canOpen() else { return }
      switch gesture {
      case .pinch:
        // 系统手势可能在监听起来之后才被打开：认到的那一刻再读一次（F13）
        guard !systemPinchIsOn, !isOpen else { return }
        open()
      case .spread: if isOpen { close(animated: true) }
      }
    }
    corner.onTrigger = { [weak self] in
      guard let self, canOpen(), !isOpen else { return }
      open()
    }
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

  func open() {
    guard !isOpen else { return }
    guard UserDefaults.standard.bool(forKey: Prefs.launchpadEnabled) else { return }
    guard canOpen() else {
      NSSound.beep()
      return
    }
    willOpen()
    prepare()
    guard
      let screen = NSScreen.screens.first(where: {
        NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
      }) ?? NSScreen.main
    else { return }
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
    let model = LaunchpadModel(
      layout: layout, catalog: catalog, icons: icons, columns: Self.columns, rows: Self.rows,
      screenSize: screen.frame.size, startPage: lastPage)
    model.onClose = { [weak self] in self?.close(animated: true) }
    model.onOpenApp = { [weak self] app in self?.open(app) }
    model.onLayoutChange = { [weak self] layout in self?.save(layout) }
    model.onDeleteApp = { [weak self] app in self?.delete(app) }
    model.folderName = { first, second in
      LaunchpadCatalog.folderName(first: first, second: second)
    }
    self.model = model
    let panel = LaunchpadPanel(frame: screen.frame, model: model)
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
    panel.onResignKey = { [weak self] in self?.panelResignedKey() }
    book.adopt(panel)
    isOpen = true
    // 岛在面板之后出：面板一 orderFrontRegardless 就盖满屏，先出岛会被盖住（F14）
    LaunchpadOpenSequence.run(
      present: { present(panel) },
      notice: notice.map { notice in
        { [weak self] in
          self?.island?.show(notice.title, detail: notice.detail, symbol: notice.symbol)
        }
      })
    autoImportIfNeeded()
  }

  /// 收起；animated = false 用于打开别的窗口 / 截图 / 状态屏之前（不能留一块全屏面板盖着）
  func close(animated: Bool) {
    guard let panel = book.beginClose() as? LaunchpadPanel else { return }
    lastPage = model?.page ?? lastPage
    model?.beginClosing()
    isOpen = false
    if animated, !Style.reduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        MainActor.assumeIsolated { self?.finishClose(panel) }
      }
    } else {
      finishClose(panel)
    }
  }

  /// 收尾按**窗口**做（F20）：哪怕收起动画还没完又打开了一块新的，晚到的 completion 也只收走自己；
  /// 内容和模型晚一拍再拆——收起可能是在这个面板的手势 / 按键回调里进来的（F21）
  private func finishClose(_ panel: LaunchpadPanel) {
    panel.orderOut(nil)
    DispatchQueue.main.async { [weak self, weak panel] in
      guard let panel else { return }
      panel.contentView = nil
      if let self, !self.isOpen, self.book.panel == nil, self.model?.onClose != nil {
        // 旧界面的回调已经不用了：模型一并放掉（新的那次打开有自己的）
        self.model = nil
      }
    }
    // 图标缓存：两分钟没再打开就放掉（R11；不占常驻内存；复用 Memory.IdleTimer，F42）
    iconIdle.schedule()
  }

  private func present(_ panel: LaunchpadPanel) {
    panel.alphaValue = Style.reduceMotion ? 1 : 0
    panel.orderFrontRegardless()
    panel.layoutIfNeeded()
    panel.makeKey()
    // 搜索框是 initialFirstResponder（CommandTextField 挂进窗口时登记的）：一打开就能打字（R3）
    if !(panel.firstResponder is NSText), let first = panel.initialFirstResponder {
      panel.makeFirstResponder(first)
    }
    guard !Style.reduceMotion else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
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
      if let model = self.model {
        model.adopt(catalog: apps)
        if changed, self.isOpen, !self.pendingAutoImport { self.mergeCatalogIntoOpenModel() }
      }
      self.autoImportIfNeeded()
    }
  }

  /// 扫完 / 导入完把目录喂进去（模型里按 id 找 App）
  private func mergeCatalogIntoOpenModel() {
    guard let model, model.drag == nil, !model.isSearching else { return }
    let updated = model.layout.merged(apps: catalog.map(\.ref), capacity: Self.capacity)
    guard updated != model.layout else { return }
    model.replace(layout: updated)
    save(updated)
  }

  /// 第一次打开时自动导入旧库（F31）：目录还没扫出来就等扫完；导入在后台做，面板已经显示默认排法
  private func autoImportIfNeeded() {
    guard pendingAutoImport, !catalog.isEmpty else { return }
    guard !LaunchpadLayout.isStored(in: .standard) else {
      pendingAutoImport = false
      return
    }
    pendingAutoImport = false
    let local = Self.localApps(catalog)
    let capacity = Self.capacity
    importTask?.cancel()
    importTask = Task { [weak self] in
      let result = await LaunchpadImport.readSystemLayoutInBackground(
        local: local, capacity: capacity)
      guard !Task.isCancelled, let self else { return }
      // 这期间用户可能已经动过布局（那就不要再覆盖）
      guard !LaunchpadLayout.isStored(in: .standard) else { return }
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
      self.model?.replace(layout: layout)
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
    close(animated: false)
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

  /// 要不要注册触控板回调（纯函数，单测直接喂）：功能开着、这一项开着、框架能用、系统手势关着
  nonisolated static func pinchShouldRun(
    enabled: Bool, usePinch: Bool, available: Bool, systemOn: Bool
  ) -> Bool {
    enabled && usePinch && available && !systemOn
  }

  /// 按偏好起停触控板监听和触发角（启动时、设置改了、导入设置之后调）
  func applySettings() {
    let defaults = UserDefaults.standard
    let enabled = defaults.bool(forKey: Prefs.launchpadEnabled)
    let pinch = defaults.bool(forKey: Prefs.launchpadPinch)
    let sensitivity =
      PinchRecognizer.Sensitivity(
        rawValue: defaults.string(forKey: Prefs.launchpadPinchSense) ?? "") ?? .standard
    // 系统的捏合还开着时我们认到也不打开（不然两个一起出来，SPEC R7）：干脆不注册回调
    if Self.pinchShouldRun(
      enabled: enabled, usePinch: pinch, available: pinchAvailable, systemOn: systemPinchIsOn)
    {
      touchpad.start(sensitivity: sensitivity)
    } else {
      touchpad.stop()
    }
    applyCorner()
  }

  private func applyCorner() {
    let enabled = UserDefaults.standard.bool(forKey: Prefs.launchpadEnabled)
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
      self.model?.replace(layout: merged)
      self.island?.show(
        "已按原来的启动台排好",
        detail: result.skipped > 0 ? "跳过 \(result.skipped) 个已经卸掉的 App" : nil,
        symbol: "square.grid.3x3",
        action: (title: "撤销", run: { [weak self] in self?.undoLastLayoutChange() }))
    }
  }

  /// 设置里改了一页几列几行：按新容量重新分页并存盘（启动台没开着也生效，下次打开就是新的页）
  func reflow() {
    guard let layout = LaunchpadLayout.load(from: .standard) else { return }
    let updated = layout.repaginated(capacity: Self.capacity)
    save(updated)
    model?.replace(layout: updated)
  }

  /// 设置 › 启动台「恢复默认排列」（二次确认在设置页里）
  func resetToDefault() {
    prepare()
    let old = LaunchpadLayout.load(from: .standard)
    let layout = LaunchpadLayout.defaultLayout(Self.defaultApps(catalog), capacity: Self.capacity)
    setUndoLayout(old)
    save(layout)
    model?.replace(layout: layout)
    island?.show(
      "已恢复默认排列", detail: "需要的话点「撤销」换回原来的", symbol: "arrow.uturn.backward",
      action: (title: "撤销", run: { [weak self] in self?.undoLastLayoutChange() }))
  }

  /// 撤销上一次导入 / 恢复默认（只留一份；存在偏好里，重启后还能用一次，F41）
  func undoLastLayoutChange() {
    guard let undoLayout else { return }
    setUndoLayout(nil)
    save(undoLayout)
    model?.replace(layout: undoLayout)
    island?.show("已还原上一次的排列", symbol: "arrow.uturn.backward")
  }

  var canUndoLayout: Bool { undoLayout != nil }

  private func setUndoLayout(_ layout: LaunchpadLayout?) {
    undoLayout = layout
    LaunchpadUndo.save(layout, to: .standard)
  }

  // MARK: 偏好

  static var capacity: Int { columns * rows }

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
