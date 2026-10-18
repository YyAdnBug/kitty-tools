// 按需的触控板实录探针（SPEC §10.3 / F6）：默认跳过，只有 `TEST_RUNNER_KITTY_LIVE_TOUCH=1` 才跑。
// 它真的会注册 MultitouchSupport 的回调、读这块触控板（用户要在 5 秒内放四根手指捏一下）；
// 平时的单测只喂造好的 `MTFinger` 缓冲区，不碰真设备。

import Foundation
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadLiveTouchTests {
  // 命令行写 TEST_RUNNER_KITTY_LIVE_TOUCH=1；xcodebuild 去掉前缀，测试进程里读到的是 KITTY_LIVE_TOUCH（G16）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TOUCH"] == "1"))
  func liveTouchFramesArrive() async throws {
    let before = TouchpadWatcher.framesSeen
    let watcher = TouchpadWatcher()
    watcher.start(sensitivity: .standard)
    defer { watcher.stop() }
    #expect(watcher.availability == .available)
    // 给用户 5 秒：在触控板上放四根手指、捏一下
    for _ in 0..<50 {
      if TouchpadWatcher.framesSeen > before { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    #expect(
      TouchpadWatcher.framesSeen > before,
      "5 秒内没有收到触点：确认这块 Mac 有触控板，并在跑的时候放四根手指捏一下")
  }
}
