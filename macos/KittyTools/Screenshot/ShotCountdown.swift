// 延时截图的倒数（第五轮体检 N2，2026-11-19）：按「延时截图」后先数 5 / 10 秒（设置 › 截图 › 高级，Prefs.screenshotDelay）
// 再冻结、进框选——工具提示、拖动中的样子、一按键就消失的弹层这样才截得到（对标系统截屏「选项」里的计时器）。
// 倒数用录屏那一套，不另做：录制 HUD 的倒数态（RecordingHUD，鼠标所在屏可见区底部居中，数字每秒 pop；点数字马上截、
// ✕ 取消）+ 这几秒临时注册的 Esc（HotKeyCenter.registerEscape：本 App 自己的面板拿着键盘时交给面板）+ 开始时的播报。
// 再按一次延时截图也是取消（AppDelegate.delayedScreenshot）。HUD 在状态栏层级，冻结帧本来就不收它；数完先收掉再截。
// 倒数不算「正在截图」（AppDelegate.isCapturing）：这几秒里程序坞预览、按住 ⌘ 的 App 快捷键、刘海岛照常弹，才截得到它们。

import AppKit

final class ShotCountdown {
  private nonisolated enum Event { case tick, now, cancel }

  private let seconds: Int
  private let hotKeys: HotKeyCenter
  private let (events, feed) = AsyncStream.makeStream(of: Event.self)

  init(seconds: Int, hotKeys: HotKeyCenter) {
    self.seconds = seconds
    self.hotKeys = hotKeys
  }

  /// 数完（或点了数字）true，取消（✕、Esc、再按一次快捷键）false。返回前 HUD 已经收掉、Esc 已经注销
  func run() async -> Bool {
    let escapes = hotKeys.registerEscape { [weak self] in self?.cancel() }
    defer { hotKeys.unregisterEscape() }
    let hud = RecordingHUD(state: .countdown(seconds), stopKey: nil, escapes: escapes)
    hud.setAccessibilityLabel(String(localized: "延时截图"))
    hud.onClick = { [weak self] item in
      switch item {
      case .startNow: self?.feed.yield(.now)
      case .cancel: self?.cancel()
      default: break
      }
    }
    let mouse = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
      hud.present(region: screen.frame, on: screen, isFullScreen: true)
    }
    defer { hud.close() }
    Island.announce("\(Self.announcement(seconds, escapes: escapes))")
    // 菜单开着（.eventTracking）时也要数（同录屏的倒数）
    let feed = feed
    let ticker = Timer(timeInterval: 1, repeats: true) { _ in feed.yield(.tick) }
    RunLoop.main.add(ticker, forMode: .common)
    defer { ticker.invalidate() }
    var left = seconds
    for await event in events {
      switch event {
      case .tick:
        left -= 1
        guard left > 0 else { return true }
        hud.update(.countdown(left))
      case .now: return true
      case .cancel: return false
      }
    }
    return false
  }

  func cancel() { feed.yield(.cancel) }

  /// 倒数开始时的播报（按实际秒数）；Esc 没注册上就不提它
  nonisolated static func announcement(_ seconds: Int, escapes: Bool) -> String {
    escapes
      ? String(localized: "\(seconds) 秒后截图，按 Esc 取消") : String(localized: "\(seconds) 秒后截图")
  }
}
