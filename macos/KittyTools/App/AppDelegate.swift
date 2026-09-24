// 应用生命周期：单实例检查，按顺序组装各模块（PLAN §4 依赖注入），后续在这里做退出清理。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let hotKeys = HotKeyCenter()

  private lazy var clipboardPanel = OverlayPanel(
    size: NSSize(width: 680, height: 520), autoHide: .clickOutside,
    isPinned: { !UserDefaults.standard.bool(forKey: Prefs.clipboardHideOnUnfocus) },
    content: ClipboardPanelView(
      onPaste: { [unowned self] in paste($0) },
      onOpenTranslate: { [unowned self] in translatePanel.present() }))

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

  func applicationDidFinishLaunching(_ notification: Notification) {
    if yieldToOlderInstance() { return }
    Prefs.registerDefaults()
    hotKeys.register(.clipboardDefault) { [unowned self] in toggleClipboard() }
    hotKeys.register(.inputTranslateDefault) { [unowned self] in showInputTranslate() }
  }

  func toggleClipboard() { clipboardPanel.toggle() }

  func showInputTranslate() { translatePanel.present() }

  private func paste(_ text: String) {
    clipboardPanel.hide()
    Paster.write(string: text)
    if !Paster.pasteToFrontmost() { Permissions.requestAccessibility() }
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
}
