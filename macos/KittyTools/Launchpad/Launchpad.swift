// 启动台的总控（SPEC §5）：热键 / 菜单栏 / 现有启动器 / 触发角都调 toggle()。管本机 App 目录的刷新、
// 布局的读写（Prefs.launchpadLayout，JSON 字符串）、第一次用的默认排法、面板的建立与释放、打开 App。
// 不激活本 App（mac-overlay-panel 的规矩）；和别的浮层互斥由 AppDelegate 的 willOpen / hidePanels 接线。
// 面板收起后放掉窗口和界面（R11）；图标缓存留着，闲下来（两分钟）没再打开就清掉。
// 触控板捏合（TouchpadWatcher）和触发角（LaunchpadCorner）也由它拿着：applySettings() 按偏好和系统手势开关起停。

import AppKit
import SwiftUI

@MainActor
final class Launchpad {
  /// 刘海岛（打不开 App、恢复默认排列的结果）
  var island: Island?
  /// 现在能不能打开（截图框选、录屏、状态屏、正在录快捷键…时不能）
  var canOpen: () -> Bool = { true }
  /// 打开之前把别的浮层收起（剪贴板、启动器、选状态、快速记一条、翻译浮窗）
  var willOpen: () -> Void = {}
  /// 设置 › 启动台（面板里的齿轮、菜单栏）
  var showSettings: () -> Void = {}

  private(set) var isOpen = false
  private var panel: LaunchpadPanel?
  private var model: LaunchpadModel?
  private var catalog: [LaunchpadProjectApp] = []
  private var signature: [Date?] = []
  private var screen: NSScreen?
  private var panelGeneration = UUID()
  private let icons = LaunchpadIcons()
  private var releaseTask: Task<Void, Never>?
  /// 上一次导入 / 恢复默认之前的布局：设置页的「撤销上一次导入」用它（只留一份）
  private(set) var undoLayout: LaunchpadLayout?
  /// 换屏 / 拔掉屏的通知：总控和 App 同寿命，不注销（deinit 是 nonisolated，碰不了它）
  private var screenObserver: NSObjectProtocol?
  /// 触控板捏合（SPEC §5.6，R7）：只在功能开着、系统的捏合关着时注册回调
  private let touchpad = TouchpadWatcher()
  /// 触发角（SPEC §5.7，R8）
  private let corner = LaunchpadCorner()

  init() {
    touchpad.onGesture = { [weak self] gesture in
      guard let self, canOpen() else { return }
      switch gesture {
      case .pinch: if !isOpen { open() }
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
    var layout = LaunchpadLayout.load(from: .standard)
    if layout == nil || layout?.tiles.isEmpty == true {
      // 第一次打开（还没存过布局）：有系统旧启动台库就自动按它导入，读不到用默认排法（SPEC §3.6 / R9）
      if !LaunchpadLayout.isStored(in: .standard),
        let imported = LaunchpadImport.readSystemLayout(
          local: Self.localApps(catalog), capacity: capacity),
        !imported.layout.tiles.isEmpty
      {
        layout = imported.layout
        island?.show(
          "已按原来的启动台排好",
          detail: imported.skipped > 0 ? "跳过 \(imported.skipped) 个已经卸掉的 App" : nil,
          symbol: "square.grid.3x3")
      } else {
        layout = LaunchpadLayout.defaultLayout(Self.defaultApps(catalog), capacity: capacity)
      }
    }
    var merged =
      layout?.merged(apps: catalog.map(\.ref), capacity: capacity) ?? LaunchpadLayout(pages: [])
    merged = merged.repaginated(capacity: capacity)
    save(merged)
    let model = LaunchpadModel(
      layout: merged, catalog: catalog, icons: icons, columns: Self.columns, rows: Self.rows,
      screenSize: screen.frame.size)
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
        momentum: event.momentumPhase)
    }
    panel.onNavigate = { [weak model] direction in model?.navigate(direction) }
    panel.onReturn = { [weak model] in model?.returnPressed() }
    panel.onCancel = { [weak model] in model?.cancel() }
    panel.onFirstPage = { [weak model] in model?.firstPage() }
    panel.onLastPage = { [weak model] in model?.lastPage() }
    panel.onCloseRequest = { [weak model] in model?.requestClose() }
    panel.onFlagsChanged = { [weak model] held in model?.optionChanged(held) }
    self.panel = panel
    isOpen = true
    present(panel)
    releaseTask?.cancel()
    releaseTask = nil
  }

  /// 收起；animated = false 用于打开别的窗口 / 截图 / 状态屏之前（不能留一块全屏面板盖着）
  func close(animated: Bool) {
    guard let panel else { return }
    model?.beginClosing()
    panelGeneration = UUID()
    let generation = panelGeneration
    isOpen = false
    if animated, !Style.reduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        MainActor.assumeIsolated { self?.finishClose(panel, generation: generation) }
      }
    } else {
      finishClose(panel, generation: generation)
    }
  }

  private func finishClose(_ panel: LaunchpadPanel, generation: UUID) {
    guard generation == panelGeneration else { return }
    panel.orderOut(nil)
    panel.contentView = nil
    if self.panel === panel {
      self.panel = nil
      model = nil
    }
    // 图标缓存：两分钟没再打开就放掉（R11；不占常驻内存）
    releaseTask?.cancel()
    releaseTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(120))
      guard !Task.isCancelled, let self, !isOpen else { return }
      icons.clear()
      Memory.relieve()
    }
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

  /// 窗口换了一块屏（全屏面板还没实现跟屏，直接收起；§9 手测「换屏」）
  func screenChanged() {
    if isOpen { close(animated: false) }
  }

  // MARK: 本机 App 目录

  /// 扫目录（启动时预热一次，打开时按目录修改时间决定要不要重扫）
  func prepare() {
    let signature = AppCatalog.signature()
    if catalog.isEmpty || signature != self.signature {
      self.signature = signature
      catalog = LaunchpadCatalog.load()
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

  /// 抖动模式里的 ✕（R6）：界面里已经确认过，这里移到废纸篓（同现有启动器的「移到废纸篓」）再把布局拿掉。
  /// 只在 App Store 装的 App 上出现（SPEC R6），系统 App 不给删。
  private func delete(_ app: LaunchpadProjectApp) {
    guard LaunchpadCatalog.canDelete(app) else { return }
    guard LaunchpadRecycle.moveToTrash(app, island: island) else { return }
    guard let layout = model?.layout else { return }
    let updated = layout.removing(app.id, capacity: Self.capacity)
    save(updated)
    model?.replace(layout: updated)
    island?.show("已移到废纸篓", detail: app.name, symbol: "trash")
  }

  // MARK: 布局

  private func save(_ layout: LaunchpadLayout) {
    guard let text = layout.jsonString() else { return }
    UserDefaults.standard.set(text, forKey: Prefs.launchpadLayout)
  }

  // MARK: 捏合和触发角（R7 / R8）

  /// 私有框架在这台 Mac 上能不能用（设置页那一行据此显示 / 灰掉）
  var pinchAvailable: Bool { TouchpadWatcher.libraryAvailable }

  /// 系统的捏合手势还开着没有（设置页每次出现读一次，不轮询）
  var systemPinchIsOn: Bool { TrackpadSystemGesture.systemPinchIsOn() }

  /// 按偏好起停触控板监听和触发角（启动时、设置改了、导入设置之后调）
  func applySettings() {
    let defaults = UserDefaults.standard
    let enabled = defaults.bool(forKey: Prefs.launchpadEnabled)
    let pinch = defaults.bool(forKey: Prefs.launchpadPinch)
    let sensitivity =
      PinchRecognizer.Sensitivity(
        rawValue: defaults.string(forKey: Prefs.launchpadPinchSense) ?? "") ?? .standard
    // 系统的捏合还开着时我们认到也不打开（不然两个一起出来，SPEC R7）：干脆不注册回调
    if enabled, pinch, pinchAvailable, !systemPinchIsOn {
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

  /// 设置 › 启动台「从系统启动台重新导入…」（二次确认在设置页里）：导入前留一份，可在设置里撤销一次
  func importFromSystem() {
    prepare()
    guard
      let result = LaunchpadImport.readSystemLayout(
        local: Self.localApps(catalog), capacity: Self.capacity),
      !result.layout.tiles.isEmpty
    else {
      island?.show(
        "没找到系统启动台的数据", detail: "可能系统里已经没有了，或者读不了", tone: .warning,
        symbol: "square.grid.3x3")
      return
    }
    undoLayout = LaunchpadLayout.load(from: .standard)
    let merged = result.layout.merged(apps: catalog.map(\.ref), capacity: Self.capacity)
    save(merged)
    model?.replace(layout: merged)
    island?.show(
      "已按原来的启动台排好",
      detail: result.skipped > 0 ? "跳过 \(result.skipped) 个已经卸掉的 App" : nil,
      symbol: "square.grid.3x3")
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
    undoLayout = old
    save(layout)
    model?.replace(layout: layout)
    island?.show("已恢复默认排列", detail: "可以用设置里的「撤销上一次导入」还原", symbol: "arrow.uturn.backward")
  }

  /// 撤销上一次导入 / 恢复默认（只留一份）
  func undoLastLayoutChange() {
    guard let undoLayout else { return }
    save(undoLayout)
    model?.replace(layout: undoLayout)
    self.undoLayout = nil
    island?.show("已还原上一次的排列", symbol: "arrow.uturn.backward")
  }

  var canUndoLayout: Bool { undoLayout != nil }

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
