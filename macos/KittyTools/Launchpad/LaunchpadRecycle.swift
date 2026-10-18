// 启动台抖动模式里删 App（SPEC R6）：只有从 App Store 装的才给删（`Contents/_MASReceipt/receipt` 而且不在 /System 下，
// 同 LaunchpadCatalog.canDelete）；确认框在界面里（SwiftUI 的 confirmationDialog，不激活本 App），确认后走
// FileManager.trashItem（和访达「移到废纸篓」同一个 API，用户还能从废纸篓拖回来；现有启动器的 recycle 是
// NSWorkspace.recycle，那边是异步的，这里要马上知道成没成才能改布局）。成功后布局里拿掉那一格。

import AppKit

@MainActor
enum LaunchpadRecycle {
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
