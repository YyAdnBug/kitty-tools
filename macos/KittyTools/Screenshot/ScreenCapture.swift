// 截图与截图翻译的冻结帧：按下热键时先把每块屏幕截成静止图，框选、裁剪、取色都只读这一帧（先截后选，PLAN §10）。
// ScreenCaptureKit 逐屏截：各屏的缩放比例可以不同，一屏一张、各按自己的像素尺寸（修旧版混合缩放错位，§11 #14）。
// 同一时刻拍一份窗口快照（CGWindowList，从前到后），截图模式悬停高亮、单击截整窗都按它命中（§11 #41）。

import AppKit
import ScreenCaptureKit

enum ScreenCapture {
  struct Shot {
    let screen: NSScreen
    /// 该屏的物理像素图
    let image: CGImage
    /// 冻结那一刻与该屏相交的窗口（该屏视图坐标，点，原点左下），从前到后
    var windows: [CGRect] = []
  }

  /// 截下所有屏幕。调用前先确认有「屏幕录制」授权（Permissions），否则每块屏幕会各弹一个系统框。
  /// keeping：要留在截图里的自家窗口（钉图）；其余自家窗口除菜单栏图标外都排除
  static func freeze(keeping: Set<CGWindowID> = []) async throws -> [Shot] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let windows = windowFrames(
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? [],
      ownPID: getpid(), keeping: keeping, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    // 排除自家窗口（浮层、设置窗、正在淡出的菜单栏菜单、上一次的框选遮罩），只保留菜单栏图标本身和钉图
    let ownWindows = content.windows.filter {
      $0.owningApplication?.processID == getpid()
        && $0.windowLayer != NSWindow.Level.statusBar.rawValue && !keeping.contains($0.windowID)
    }
    var shots: [Shot] = []
    for display in content.displays {
      guard
        let screen = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value == display.displayID
        })
      else { continue }
      let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
      let configuration = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      configuration.width = Int(filter.contentRect.width * scale)
      configuration.height = Int(filter.contentRect.height * scale)
      configuration.showsCursor = false
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
      let origin = screen.frame.origin
      shots.append(
        Shot(
          screen: screen, image: image,
          windows: windows.filter { $0.intersects(screen.frame) }.map {
            $0.offsetBy(dx: -origin.x, dy: -origin.y)
          }))
    }
    return shots
  }

  /// 窗口列表（CGWindowListCopyWindowInfo 的结果，从前到后）→ 可截的窗口矩形（AppKit 全局坐标，原点在主屏左下），
  /// 顺序不变。只要普通层到浮动面板（低于程序坞）和展开着的弹出菜单；去掉全透明、太小的和自家窗口（钉图除外）。
  /// 纯函数，配单测
  static func windowFrames(
    _ info: [[String: Any]], ownPID: pid_t, keeping: Set<CGWindowID>, primaryHeight: CGFloat
  ) -> [CGRect] {
    let popUpMenu = Int(CGWindowLevelForKey(.popUpMenuWindow))
    let dock = Int(CGWindowLevelForKey(.dockWindow))
    return info.compactMap { window in
      guard let layer = window[kCGWindowLayer as String] as? Int,
        (0..<dock).contains(layer) || layer == popUpMenu,
        (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        rect.width >= 20, rect.height >= 20
      else { return nil }
      let pid = window[kCGWindowOwnerPID as String] as? Int32
      let id = window[kCGWindowNumber as String] as? Int ?? 0
      if pid == ownPID, !keeping.contains(CGWindowID(id)) { return nil }
      // CG 全局坐标原点在主屏左上、y 向下
      return CGRect(
        x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
  }
}
