// 启动台抖动模式里删 App（SPEC R6）：只有从 App Store 装的才给删（`Contents/_MASReceipt/receipt` 而且不在 /System 下，
// 同 LaunchpadCatalog.canDelete）；确认框说清「移到废纸篓、可以再装回来」，确认后走 FileManager.trashItem（和访达
// 「移到废纸篓」同一个 API，用户还能从废纸篓拖回来；现有启动器的 recycle 是 NSWorkspace.recycle，那边是异步的，
// 这里要马上知道成没成才能改布局）。成功后布局里拿掉那一格。
// 确认框用 NSAlert：面板在 .statusBar 层，alert 默认的层级会被它盖住，所以把 alert 的窗口也提到 statusBar + 1。

import AppKit

@MainActor
enum LaunchpadRecycle {
  static func confirm(_ app: LaunchpadProjectApp, over window: NSWindow?) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "把「\(app.name)」移到废纸篓？"
    alert.informativeText = "它从 App Store 装的，以后要再装得去 App Store 里找。废纸篓清空之前都能拿回来。"
    alert.icon = NSWorkspace.shared.icon(forFile: app.path)
    alert.addButton(withTitle: "移到废纸篓")
    alert.addButton(withTitle: "取消")
    // Esc 关掉 = 取消
    if let cancel = alert.buttons.last { cancel.keyEquivalent = "\u{1b}" }
    if let window, window.isVisible {
      // 启动台是 key，系统会把 alert 摆在它上面；层级提一层，免得被全屏面板盖住
      alert.window.level = .statusBar + 1
      return alert.runModal() == .alertFirstButtonReturn
    }
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// 移到废纸篓；返回成没成（失败用刘海岛说一声）
  static func moveToTrash(_ app: LaunchpadProjectApp, island: Island?) -> Bool {
    do {
      try FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
      return true
    } catch {
      island?.show(
        "没能删掉「\(app.name)」", detail: error.localizedDescription, tone: .warning)
      return false
    }
  }
}
