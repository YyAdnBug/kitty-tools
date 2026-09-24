// 应用生命周期：单实例检查，按依赖顺序组装各模块（PLAN §4），热键与各翻译入口，首次安装 / 更新后打开设置窗，
// 退出 / 锁屏时的清理。

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 只有真正跑起来的实例才做退出清理：让位退出的重复实例不能碰数据库
  private var isRunning = false
  /// 划词取词进行中：重复按热键直接忽略
  private var isReadingSelection = false
  let hotKeys = HotKeyCenter()

  // MARK: 数据与服务（按依赖顺序）

  private let dataDirectory = URL.applicationSupportDirectory.appending(
    path: Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")
  private lazy var database: Database = Self.openOrQuit { [dataDirectory] in
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    return try Database(path: dataDirectory.appending(path: "kitty.sqlite3").path)
  }
  private lazy var clipboardStore: ClipboardStore = Self.openOrQuit { [database, dataDirectory] in
    let images = dataDirectory.appending(path: "images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    return try ClipboardStore(db: database, images: ImageStore(directory: images))
  }
  private lazy var historyStore: HistoryStore = Self.openOrQuit { [database] in
    try HistoryStore(db: database)
  }
  private lazy var watcher = ClipboardWatcher(store: clipboardStore)
  private let serviceStore = TranslateServiceStore()
  private lazy var coordinator = TranslateCoordinator(services: serviceStore, history: historyStore)
  private let speaker = Speaker()

  // MARK: 窗口

  private lazy var clipboardModel = ClipboardPanelModel(store: clipboardStore)

  private lazy var clipboardPanel: OverlayPanel = {
    let model = clipboardModel
    let panel = OverlayPanel(
      size: NSSize(width: 680, height: 520), autoHide: .clickOutside,
      isPinned: { !UserDefaults.standard.bool(forKey: Prefs.clipboardHideOnUnfocus) },
      content: ClipboardPanelView(model: model))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    panel.onHide = { [unowned model] in model.reset() }
    model.hidePanel = { [unowned panel] in panel.hide() }
    // 剪贴板面板保持打开（兄弟浮层），翻译浮窗出现在旁边
    model.openTranslate = { [unowned self] text in
      coordinator.translate(text)
      translatePanel.present()
    }
    model.openSettings = { [unowned self] in showSettings() }
    return panel
  }()

  private lazy var translatePanel: OverlayPanel = {
    let panel = OverlayPanel(
      size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 400),
      autosaveName: "TranslatePanel", autoHide: .resignKey,
      isPinned: { UserDefaults.standard.bool(forKey: Prefs.floatingPinned) },
      content: TranslatePanelView(coordinator: coordinator, speaker: speaker) { [unowned self] in
        showSettings()
      })
    panel.onHide = { [unowned self] in
      // 收起即作废进行中的请求（省额度）；剪贴板面板还开着就把 key 还给它
      coordinator.cancel()
      if clipboardPanel.isVisible { clipboardPanel.makeKey() }
    }
    return panel
  }()

  private lazy var settingsWindow = SettingsWindow(tabs: [
    (
      "通用", "gearshape",
      AnyView(
        GeneralTab { [unowned self] in
          await LegacyImport.run(
            services: serviceStore, clipboard: clipboardStore, history: historyStore,
            db: database)
        })
    ),
    ("剪贴板", "doc.on.clipboard", AnyView(ClipboardTab(store: clipboardStore))),
    ("翻译", "character.bubble", AnyView(TranslateTab(services: serviceStore))),
    ("快捷键", "keyboard", AnyView(HotkeysTab(center: hotKeys))),
    ("关于", "info.circle", AnyView(AboutTab())),
  ])

  // MARK: 生命周期

  func applicationDidFinishLaunching(_ notification: Notification) {
    // 单测以本 App 为宿主运行：不碰真实数据、不起热键
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
    if yieldToOlderInstance() { return }
    isRunning = true
    Prefs.registerDefaults()

    let launchedAt = Date.now
    clipboardStore.enforceLimits()
    clipboardStore.images.removeOrphans(
      keeping: Set(clipboardStore.items.map(\.id)), createdBefore: launchedAt)
    clipboardStore.recognizePendingImages()
    watcher.onText = { [unowned self] text in copyToTranslate(text) }
    watcher.start()
    DistributedNotificationCenter.default().addObserver(
      forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [unowned self] _ in
      MainActor.assumeIsolated {
        if UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnLock) {
          clipboardStore.clearOrdinary()
        }
      }
    }

    hotKeys.setHandler(for: .clipboard) { [unowned self] in toggleClipboard() }
    hotKeys.setHandler(for: .selectionTranslate) { [unowned self] in selectionTranslate() }
    hotKeys.setHandler(for: .inputTranslate) { [unowned self] in showInputTranslate() }
    hotKeys.reload()
    showWelcomeIfNeeded()
  }

  func applicationWillTerminate(_ notification: Notification) {
    if isRunning, UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnQuit) {
      clipboardStore.clearOrdinary()
    }
  }

  /// 程序坞图标被点（设置窗打开期间才有程序坞图标）
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showSettings()
    return false
  }

  // MARK: 入口

  func toggleClipboard() {
    if !clipboardPanel.isVisible { clipboardStore.enforceLimits() }
    clipboardPanel.toggle()
  }

  func showInputTranslate() {
    coordinator.beginInput()
    translatePanel.present()
  }

  /// 划词翻译：取词完成前绝不显示浮窗（先显示会取消原 App 的选区）。自家浮层是 key 时先收起，
  /// 否则 AX 读到的、⌘C 发到的都是自己
  func selectionTranslate() {
    guard !isReadingSelection else { return }
    isReadingSelection = true
    if clipboardPanel.isKeyWindow { clipboardPanel.hide() }
    if translatePanel.isKeyWindow { translatePanel.orderOut(nil) }
    Task {
      defer { isReadingSelection = false }
      if let text = await SelectionReader.read(pausing: watcher) {
        coordinator.translate(text)
      } else if !Permissions.isAccessibilityTrusted {
        coordinator.showNotice("划词翻译需要「辅助功能」授权")
        Permissions.requestAccessibility()
      } else {
        coordinator.beginInput()  // 没有选中文字：当输入翻译用
      }
      translatePanel.present()
    }
  }

  /// 复制即译：只露出浮窗、不抢键盘（用户可能正在别的 App 里继续打字）
  private func copyToTranslate(_ text: String) {
    guard UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate) else { return }
    coordinator.translate(text)
    translatePanel.present(makingKey: false)
  }

  /// 打开设置窗（tab 为标签标题，nil 保持上次的标签）：先按正常隐藏路径收起两个浮层（固定的浮层会盖在设置窗上）
  func showSettings(tab: String? = nil) {
    clipboardPanel.hide()
    translatePanel.hide()
    settingsWindow.show(tab: tab)
  }

  // MARK: 启动辅助

  /// 首次安装打开通用页（权限、导入旧版）；更新后第一次启动打开关于页看本版更新内容
  private func showWelcomeIfNeeded() {
    let last = UserDefaults.standard.string(forKey: Prefs.lastSeenVersion)
    UserDefaults.standard.set(AboutTab.version, forKey: Prefs.lastSeenVersion)
    if last == nil {
      showSettings(tab: "通用")
    } else if last != AboutTab.version {
      showSettings(tab: "关于")
    }
  }

  /// LaunchServices 不保证同一 bundle id 只跑一份（例如 DMG 里一份、/Applications 里又一份）：
  /// 发现更早启动的实例就把它激活，自己退出。只让「更晚的」退出：两份同时启动时
  /// 若都见到对方就退，会一起退光（实测过）；启动时间相同再比 pid
  private func yieldToOlderInstance() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let me = NSRunningApplication.current
    let rank = { (app: NSRunningApplication) in
      (app.launchDate ?? .distantPast, app.processIdentifier)
    }
    let older = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      $0.processIdentifier != me.processIdentifier && rank($0) < rank(me)
    }
    guard let older else { return false }
    older.activate()
    NSApp.terminate(nil)
    return true
  }

  /// 数据库打不开就没法工作：弹窗说明后退出。数据目录 ~/Library/Application Support/<bundle id>/
  /// （Debug 与 Release 的 bundle id 不同，数据天然隔离）
  private static func openOrQuit<T>(_ open: () throws -> T) -> T {
    do {
      return try open()
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "无法打开数据库"
      alert.informativeText = String(describing: error)
      NSApp.activate()
      alert.runModal()
      exit(1)
    }
  }
}
