// 启动台抖动模式里删 App（SPEC R6）：只有从 App Store 装的才给删（`Contents/_MASReceipt/receipt` 而且不在 /System 下，
// 同 LaunchpadCatalog.canDelete）；确认框在界面里（SwiftUI 的 confirmationDialog，不激活本 App），确认后走
// NSWorkspace.recycle（和访达「移到废纸篓」同一个 API，用户还能从废纸篓拖回来，F22）。它是异步的：
// 完成回调回主线程再说成没成，成功了才改布局；失败由调用方在岛上说原因并给「在访达中显示」。
// 2026-10-18：以前用 FileManager.trashItem 同步删，删大 App 会卡住主线程，也不给失败留出口。

import AppKit

@MainActor
enum LaunchpadRecycle {
  /// 真正做回收的那一下：单测注入假的（不碰用户的废纸篓）。回调一律回主线程。
  typealias Recycler = @MainActor ([URL], @escaping @MainActor (Error?) -> Void) -> Void

  static let systemRecycler: Recycler = { urls, done in
    NSWorkspace.shared.recycle(urls) { _, error in
      Task { @MainActor in done(error) }
    }
  }

  /// 移到废纸篓；完成时回主线程，成功为 true
  static func moveToTrash(
    _ app: LaunchpadProjectApp, using recycle: Recycler = systemRecycler,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    recycle([app.url]) { error in completion(error == nil) }
  }
}
