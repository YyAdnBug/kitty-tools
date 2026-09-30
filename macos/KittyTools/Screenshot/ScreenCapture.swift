// 截图与截图翻译的冻结帧：按下热键时先把每块屏幕截成静止图，框选、裁剪、取色都只读这一帧（先截后选，PLAN §10）。
// ScreenCaptureKit 逐屏截：各屏的缩放比例可以不同，一屏一张、各按自己的像素尺寸（修旧版混合缩放错位，§11 #14）；
// 几块屏同时截（体检 B47：以前一块截完才截下一块，热键到遮罩的等待随屏幕数线性增加）。
// 同一时刻拍一份窗口快照（CGWindowList，从前到后），截图模式悬停高亮、单击截整窗都按它命中（§11 #41）。
// 本 App 开着的窗口（浮层、设置窗、引导、钉图）照常截进去、能悬停选中；截图自己的装饰排除（keptOwnWindows）。

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

  /// 本 App 窗口的几项特征（取自 NSApp.windows），决定它留不留在冻结帧里
  struct OwnWindow {
    let id: CGWindowID
    let className: String
    let level: Int
    let isVisible: Bool
    let alpha: CGFloat
    /// 挂在哪个窗口上（sheetParent ?? parent 的窗口号）：sheet、确认框、弹出框这类子窗口
    var parent: CGWindowID? = nil
  }

  /// 截下所有屏幕。调用前先确认有「屏幕录制」授权（Permissions），否则每块屏幕会各弹一个系统框。
  /// 本 App 的窗口只留 keptOwnWindows 认下的，其余排除
  static func freeze() async throws -> [Shot] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let own = ownWindows()
    let kept = keptOwnWindows(own)
    let known = Set(own.map(\.id))
    let windows = windowFrames(
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? [],
      ownPID: getpid(), keeping: kept, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    // 不在 NSApp.windows 里的自家窗口（系统淡出用的快照等）也排除；只有状态栏层级的照旧留（菜单栏图标，以防它不在列表里）
    let ownWindows = content.windows.filter {
      $0.owningApplication?.processID == getpid() && !kept.contains($0.windowID)
        && (known.contains($0.windowID)
          || $0.windowLayer != NSWindow.Level.statusBar.rawValue)
    }
    let jobs = content.displays.compactMap { display -> (NSScreen, SCContentFilter)? in
      guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID })
      else { return nil }
      return (screen, SCContentFilter(display: display, excludingWindows: ownWindows))
    }
    // 几块屏一起等系统截（真正的活在 ScreenCaptureKit 的进程里）：每块屏一个任务，都留在主 actor 上，只带着
    // Filters（主 actor 隔离的类是 Sendable）和下标走——SCContentFilter 不是 Sendable，不能直接捕获进任务
    // （TaskGroup 的 @MainActor 子任务在 Swift 6.2 的区域检查器里报「不认识的模式」，所以用一组 Task）。
    // 按屏幕原来的顺序收；一块失败就取消其余的，整个抛出去
    let filters = Filters(jobs.map(\.1))
    let tasks = jobs.indices.map { index in
      Task {
        let filter = filters.items[index]
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: configuration)
      }
    }
    defer { for task in tasks { task.cancel() } }
    var images: [CGImage] = []
    for task in tasks { images.append(try await task.value) }
    return zip(jobs, images).map { job, image in
      let screen = job.0
      let origin = screen.frame.origin
      return Shot(
        screen: screen, image: image,
        windows: windows.filter { $0.intersects(screen.frame) }.map {
          $0.offsetBy(dx: -origin.x, dy: -origin.y)
        })
    }
  }

  /// 本 App 此刻的窗口（NSApp.windows）。windowNumber 没显示过时是负数（defer 建的面板第一次露出来之前），先滤掉再转 CGWindowID
  static func ownWindows() -> [OwnWindow] {
    let number = { (window: NSWindow) in
      window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil
    }
    return NSApp.windows.compactMap { window in
      number(window).map {
        OwnWindow(
          id: $0, className: String(describing: type(of: window)), level: window.level.rawValue,
          isVisible: window.isVisible, alpha: window.alphaValue,
          parent: (window.sheetParent ?? window.parent).flatMap(number))
      }
    }
  }

  /// freeze 里各屏截图任务共用的 filter（见 freeze）
  private final class Filters {
    let items: [SCContentFilter]
    init(_ items: [SCContentFilter]) { self.items = items }
  }

  /// 本 App 哪些窗口留在冻结帧和悬停列表里（用户 2026-09-26：截图要能截到本 App 自己）：开着的普通窗口都留——
  /// 剪贴板面板、翻译浮窗、启动器、⌘Y 放大预览、设置窗、引导、钉图，截图时能悬停、单击选中；菜单栏图标也留
  /// （状态栏层级、类名带 StatusBar）。其余排除：刚 orderOut / 系统淡出中的（不可见或全透明）、状态栏层级及以上的
  /// 截图装饰（刘海岛、飞行卡片、常驻缩略图、长截图 / 录屏的边框、上一次的遮罩、菜单），以及按类名认的遮罩、长截图面板、
  /// 菜单、工具提示。录屏时菜单栏的停止项（NSStatusBarWindow）同菜单栏图标一样留在冻结帧里（它本来就在菜单栏上，
  /// 不在悬停列表里：windowFrames 只要程序坞以下的层），可以接受。纯函数，配单测
  static func keptOwnWindows(_ windows: [OwnWindow]) -> Set<CGWindowID> {
    let status = NSWindow.Level.statusBar.rawValue
    let chrome = ["SelectionOverlay", "ScrollCapturePanel", "Menu", "ToolTip"]
    return Set(
      windows.filter { window in
        if window.level == status { return window.className.contains("StatusBar") }
        return window.isVisible && window.alpha > 0 && window.level < status
          && !chrome.contains { window.className.contains($0) }
      }.map(\.id))
  }

  /// 录屏时本 App 哪些窗口录进去（R4-a，白名单）：过滤器排除整个本 App，只把这几类面板列进例外——OverlayPanel（剪贴板、
  /// 启动器、翻译浮窗、两个 ⌘Y）、钉图 PinPanel、设置窗（普通 NSWindow）和它的 SwiftUI sheet（引导、速查表，实测类名
  /// SheetPresentationWindow）、选文件夹 / 另存为（NSOpenPanel / NSSavePanel，不挂在窗口上），以及挂在这些窗口上的子窗口
  /// （确认框 _NSAlertPanel 的 sheet、弹出框 _NSPopoverWindow，一层套一层也跟着）。**不看可见不可见**：收起着的、开过又
  /// 收起的开录后露出来照样录进去（第 0 批实测）。刘海岛、飞行卡片、常驻缩略图、截图遮罩、长截图面板、录制边框和停止项、
  /// 菜单、工具提示永远不列：以后新加的装饰窗口默认不进画面。层级到状态栏及以上的一律不列（同名类也不行）。纯函数，配单测
  static func recordedOwnWindows(_ windows: [OwnWindow]) -> Set<CGWindowID> {
    let status = NSWindow.Level.statusBar.rawValue
    let panels: Set = [
      "OverlayPanel", "PinPanel", "NSWindow", "SheetPresentationWindow", "NSOpenPanel",
      "NSSavePanel",
    ]
    var ids = Set(windows.filter { panels.contains($0.className) && $0.level < status }.map(\.id))
    while true {
      let children = windows.filter { window in
        !ids.contains(window.id) && window.level < status
          && window.parent.map(ids.contains) == true
          && !["Menu", "ToolTip"].contains { window.className.contains($0) }
      }
      if children.isEmpty { return ids }
      ids.formUnion(children.map(\.id))
    }
  }

  /// 窗口列表（CGWindowListCopyWindowInfo 的结果，从前到后）→ 可截的窗口矩形（AppKit 全局坐标，原点在主屏左下），
  /// 顺序不变。只要普通层到浮动面板（低于程序坞）和展开着的弹出菜单；去掉全透明、太小的和自家窗口
  /// （keeping 里的除外：keptOwnWindows 留下的）。纯函数，配单测
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

extension NSScreen {
  /// ScreenCaptureKit 的 SCDisplay.displayID 对得上的屏幕编号
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}
