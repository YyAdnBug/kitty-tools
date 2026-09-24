// 应用生命周期：启动时的单实例检查（PLAN §4）。后续在这里按顺序组装各模块、做退出清理。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // LaunchServices 不保证同一 bundle id 只跑一份（例如 DMG 里一份、/Applications 里又一份）：
    // 发现更早启动的实例就把它激活，自己退出。只让「更晚的」退出：两份同时启动时
    // 若都见到对方就退，会一起退光（实测过）；启动时间相同再比 pid
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let me = NSRunningApplication.current
    let rank = { (app: NSRunningApplication) in
      (app.launchDate ?? .distantPast, app.processIdentifier)
    }
    let older = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      $0.processIdentifier != me.processIdentifier && rank($0) < rank(me)
    }
    if let older {
      older.activate()
      NSApp.terminate(nil)
    }
  }
}
