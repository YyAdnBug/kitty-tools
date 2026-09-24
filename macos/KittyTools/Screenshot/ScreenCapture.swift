// 截图翻译的冻结帧：按下热键时先把每块屏幕截成静止图，框选、裁剪都只读这一帧（先截后选，PLAN §10）。
// ScreenCaptureKit 逐屏截：各屏的缩放比例可以不同，一屏一张、各按自己的像素尺寸（修旧版混合缩放错位，§11 #14）。

import AppKit
import ScreenCaptureKit

enum ScreenCapture {
  struct Shot {
    let screen: NSScreen
    /// 该屏的物理像素图
    let image: CGImage
  }

  /// 截下所有屏幕。调用前先确认有「屏幕录制」授权（Permissions），否则每块屏幕会各弹一个系统框
  static func freeze() async throws -> [Shot] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    // 排除自家窗口（浮层、设置窗、正在淡出的菜单栏菜单、上一次的框选遮罩），只保留菜单栏图标本身
    let ownWindows = content.windows.filter {
      $0.owningApplication?.processID == getpid()
        && $0.windowLayer != NSWindow.Level.statusBar.rawValue
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
      shots.append(Shot(screen: screen, image: image))
    }
    return shots
  }
}
