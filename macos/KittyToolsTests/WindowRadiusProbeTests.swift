import AppKit
import ScreenCaptureKit
import Testing

@testable import KittyTools

// 量本机屏幕上各扇窗口真实的圆角（按需，TEST_RUNNER_KITTY_LIVE_WINDOW_RADIUS=1 才跑，要「屏幕录制」授权；不出图、不弹窗，
// 只在测试输出里打「window-radius」一行一扇：App、窗口大小、左上角的半径（点）、单独截一次花多久）。截图框选时悬停 /
// 选中窗口的圆角照这个口径量（WindowShot.cornerRadius）：
//   TEST_RUNNER_KITTY_LIVE_WINDOW_RADIUS=1 xcodebuild … test -only-testing:'KittyToolsTests/WindowRadiusProbeTests/measure()'
@MainActor struct WindowRadiusProbeTests {
  nonisolated static let enabled =
    ProcessInfo.processInfo.environment["KITTY_LIVE_WINDOW_RADIUS"] != nil

  @Test(.enabled(if: enabled)) func measure() async throws {
    let listing = ContinuousClock.now
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    print("window-radius listing \(ContinuousClock.now - listing)")
    let windows = content.windows.filter {
      $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 120 && $0.frame.height >= 80
        && $0.owningApplication != nil
    }
    for window in windows {
      let start = ContinuousClock.now
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let configuration = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      configuration.width = Int((filter.contentRect.width * scale).rounded())
      configuration.height = Int((filter.contentRect.height * scale).rounded())
      configuration.showsCursor = false
      configuration.ignoreShadowsSingleWindow = true
      configuration.shouldBeOpaque = false
      guard
        let image = try? await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: configuration)
      else { continue }
      let elapsed = ContinuousClock.now - start
      let radius = WindowShot.cornerRadius(of: image).map { String(format: "%.1f", $0 / scale) }
      // 实际用的那条路：只截左上角 48 点见方（WindowShot.cornerRadius(of: 窗口号)，含列窗口）
      let corner = ContinuousClock.now
      let quick = await WindowShot.cornerRadius(of: window.windowID).map {
        String(format: "%.1f", $0)
      }
      print(
        "window-radius \(window.owningApplication?.bundleIdentifier ?? "?") "
          + "\(Int(window.frame.width))×\(Int(window.frame.height)) radius=\(radius ?? "-") "
          + "\(elapsed) | corner=\(quick ?? "-") \(ContinuousClock.now - corner)")
    }
  }
}
