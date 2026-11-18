// 刘海那块屏上前台 App 是不是全屏（2026-11-18，照 Alcove「全屏时藏起」；设置 › 刘海岛「全屏时藏起来」，默认关）。
// 公开接口 CGWindowListCopyWindowInfo（不要授权，不读窗口名；mac-native §3 的 C 接口名单里登记了这个文件）。
// 怎么认（本机 macOS 27 实测，探针 build/research/focus-2026-11-17/probe/fullscreen，用户在场把 Safari 全屏 26 秒）：
// 全屏时前台 App 的普通窗口（第 0 层）从刘海下沿一直到屏幕底、和屏一样宽（1710 × 1074），程序坞那扇窗口（第 20 层、
// 整屏大）不在列表里；平时放大的窗口同样宽，但到程序坞上沿为止、程序坞在。菜单栏那一层的窗口全屏时照样在，认不了；
// 系统的展示选项（currentSystemPresentationOptions）只管本 App，也认不了。
// 程序坞那扇窗口在别的屏上（外接屏是主屏）时认不了——刘海屏上铺满的窗口和全屏一个样子——一律不算全屏（评审）。
// ponytail: 程序坞设成「自动隐藏」时，放大到屏幕底的窗口可能也被当成全屏（自动隐藏时程序坞那扇窗口还在不在没实测）；
// 程序坞在别的屏上时这一项等于不起作用。要准就用辅助功能读前台窗口的 AXFullScreen（要授权）。

import AppKit

enum IslandFullScreen {
  /// 程序坞那扇窗口的层（kCGDockWindowLevel）
  static let dockLayer = 20

  /// 一扇窗口：属于哪个进程、第几层、在哪（CG 坐标：原点在主屏左上）、是不是程序坞的
  struct Window: Equatable {
    var pid: pid_t
    var layer: Int
    var frame: CGRect
    var isDock: Bool
  }

  /// 认（纯函数）：screen 是刘海那块屏（CG 坐标），top 是菜单栏 / 刘海那一条多高；前台进程有一扇第 0 层的窗口和屏一样宽、
  /// 顶在那一条下沿以内、底到屏幕底，而且程序坞那扇窗口哪块屏上都没有
  static func isFullScreen(_ windows: [Window], screen: CGRect, top: CGFloat, front: pid_t) -> Bool
  {
    let dock = windows.contains { $0.isDock && $0.layer == dockLayer }
    guard !dock else { return false }
    return windows.contains { window in
      window.pid == front && window.layer == 0
        && abs(window.frame.width - screen.width) <= 1 && abs(window.frame.minX - screen.minX) <= 1
        && window.frame.minY <= screen.minY + top + 1 && abs(window.frame.maxY - screen.maxY) <= 1
    }
  }

  /// 现在刘海那块屏上前台是不是全屏（读一次窗口列表，主线程，约 1 ms）
  static func isFullScreen(on screen: NSScreen) -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let main = NSScreen.screens.first,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    let frame = CGRect(
      x: screen.frame.minX, y: main.frame.maxY - screen.frame.maxY, width: screen.frame.width,
      height: screen.frame.height)
    let windows = list.compactMap { info -> Window? in
      guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds),
        let pid = info[kCGWindowOwnerPID as String] as? pid_t
      else { return nil }
      return Window(
        pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0, frame: rect,
        isDock: info[kCGWindowOwnerName as String] as? String == "Dock")
    }
    return isFullScreen(
      windows, screen: frame, top: max(screen.safeAreaInsets.top, 24), front: front)
  }
}
