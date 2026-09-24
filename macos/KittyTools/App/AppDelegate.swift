// 应用生命周期：单实例检查，按依赖顺序组装各模块（PLAN §4），退出 / 锁屏时的清理。

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 只有真正跑起来的实例才做退出清理：让位退出的重复实例不能碰数据库
  private var isRunning = false
  let hotKeys = HotKeyCenter()
  private lazy var clipboardStore = Self.openClipboardStore()
  private lazy var watcher = ClipboardWatcher(store: clipboardStore)

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
    model.openTranslate = { [unowned self] _ in translatePanel.present() }
    model.openSettings = { [unowned self] in showSettings() }
    return panel
  }()

  private lazy var translatePanel: OverlayPanel = {
    let panel = OverlayPanel(
      size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 400),
      autosaveName: "TranslatePanel", autoHide: .resignKey,
      isPinned: { UserDefaults.standard.bool(forKey: Prefs.floatingPinned) },
      content: TranslatePanelView())
    // 翻译浮窗收起时剪贴板面板还开着：把 key 还给它，键盘操作能接着用
    panel.onHide = { [unowned self] in
      if clipboardPanel.isVisible { clipboardPanel.makeKey() }
    }
    return panel
  }()

  private lazy var settingsWindow = SettingsWindow(tabs: [
    ("剪贴板", "doc.on.clipboard", AnyView(ClipboardTab(store: clipboardStore))),
    ("快捷键", "keyboard", AnyView(HotkeysTab(center: hotKeys))),
  ])

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
    hotKeys.setHandler(for: .inputTranslate) { [unowned self] in showInputTranslate() }
    hotKeys.reload()
  }

  func applicationWillTerminate(_ notification: Notification) {
    if isRunning, UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnQuit) {
      clipboardStore.clearOrdinary()
    }
  }

  func toggleClipboard() {
    if !clipboardPanel.isVisible { clipboardStore.enforceLimits() }
    clipboardPanel.toggle()
  }

  func showInputTranslate() { translatePanel.present() }

  /// 打开设置窗：先按正常隐藏路径收起两个浮层（固定的浮层会盖在设置窗上）
  func showSettings() {
    clipboardPanel.hide()
    translatePanel.hide()
    settingsWindow.show()
  }

  /// 程序坞图标被点（设置窗打开期间才有程序坞图标）
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showSettings()
    return false
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

  /// 数据目录：~/Library/Application Support/<bundle id>/（Debug 与 Release 的 bundle id 不同，数据天然隔离）
  private static func openClipboardStore() -> ClipboardStore {
    do {
      let directory = URL.applicationSupportDirectory.appending(
        path: Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")
      let imagesDirectory = directory.appending(path: "images")
      try FileManager.default.createDirectory(
        at: imagesDirectory, withIntermediateDirectories: true)
      let database = try Database(path: directory.appending(path: "kitty.sqlite3").path)
      return try ClipboardStore(db: database, images: ImageStore(directory: imagesDirectory))
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "无法打开剪贴板历史数据库"
      alert.informativeText = String(describing: error)
      NSApp.activate()
      alert.runModal()
      exit(1)
    }
  }
}
