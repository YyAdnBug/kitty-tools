// issue #51 的屏上探针（按需；边框提醒亮着、刘海上却没有那张卡）：真的刘海岛（start 过、同启动时那样先建好窗口）+ 真的边框，
// 岛上几种状态（空着、刚收起、挂着别的提示 / 进行中、耳朵上有活动、指针停在岛上）× 进出全屏空间的动画中途，到点后看：
// 岛的窗口在不在当前屏上、岛认不认为挂着的卡在显示、抓岛窗口的画面量黑色形体有多高（卡片约是刘海 + 36 pt 以上，
// 缩在刘海里的只有刘海那么高）、边框几条在屏上；收起后边框该一条不剩。全屏空间用一扇自己的窗口全屏造，不合成按键。
// **屏幕会全屏切走再切回几次、四边闪边框、刘海下面出卡片，约一分钟，跑之前先问用户**；抓画面要 Dev 版有「屏幕录制」授权，
// 没有就只报窗口在不在。2026-11-25 本机（27.0.1、刘海屏）10 种全过，没复现。结果 grep「reminder-glow」，给了目录时另写 <目录>/report.md：
//   TEST_RUNNER_KITTY_LIVE_REMINDER_GLOW=/tmp/kitty-glow xcodebuild … test \
//     -only-testing:'KittyToolsTests/ReminderGlowLiveTests/cardShowsWithGlow()'

import AppKit
import ScreenCaptureKit
import Testing

@testable import KittyTools

struct ReminderGlowLiveTests {
  @MainActor
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_REMINDER_GLOW"] != nil))
  func cardShowsWithGlow() async throws {
    let island = Island()
    island.start()
    let glow = ReminderGlow()
    let host = NSWindow(
      contentRect: CGRect(x: 240, y: 240, width: 420, height: 260),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.collectionBehavior = [.fullScreenPrimary]
    var lines: [String] = []
    defer {
      glow.dismiss()
      island.unpin()
      island.dismiss()
      island.window?.orderOut(nil)
      island.unwatchMouse()
      if let observer = island.screenObserver {
        NotificationCenter.default.removeObserver(observer)
      }
      host.close()
    }

    func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    // 同 ReminderCenter.present：先边框、再挂到岛上
    func fire() {
      glow.show()
      island.pin(
        "起来走走", detail: nil, symbol: "alarm.fill",
        actions: [Island.Action("知道了") {}, Island.Action("稍后 5 分钟") {}]
      ) {}
    }
    func clear() {
      glow.dismiss()
      island.unpin()
    }
    func onScreen() -> Set<Int> {
      let list =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
      return Set(list.compactMap { $0[kCGWindowNumber as String] as? Int })
    }
    /// 显示着的边框窗口（收掉的那几扇在这个长跑的测试函数里放不掉——自动释放池要回到事件循环才清——还留在 NSApp.windows 里，不数）
    func strips() -> [NSWindow] {
      NSApp.windows.filter {
        $0.isVisible && $0.level == .statusBar && $0 !== island.window
          && ($0.frame.height == ReminderGlow.depth || $0.frame.width == ReminderGlow.depth)
      }
    }
    /// 岛窗口画面里黑色形体的高（pt）：抓不到（没授权、窗口不在屏上）是 nil
    func shapeHeight() async -> Double? {
      guard let window = island.window,
        let content = try? await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: true),
        let target = content.windows.first(where: { Int($0.windowID) == window.windowNumber })
      else { return nil }
      let scale = window.backingScaleFactor
      let configuration = SCStreamConfiguration()
      configuration.width = Int(window.frame.width * scale)
      configuration.height = Int(window.frame.height * scale)
      configuration.showsCursor = false
      guard
        let image = try? await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: target),
          configuration: configuration)
      else { return nil }
      let width = image.width
      let height = image.height
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      guard
        let context = CGContext(
          data: &pixels, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      // 位图第 0 行在最上（CGContext 的数据按自上而下排）；找最下面一行还有不透明像素的
      var lowest = -1
      for row in 0..<height {
        let base = row * width * 4
        if stride(from: 0, to: width, by: 2).contains(where: { pixels[base + $0 * 4 + 3] > 200 }) {
          lowest = row
        }
      }
      return lowest < 0 ? 0 : Double(lowest + 1) / scale
    }
    func report(_ label: String) async {
      let on = onScreen()
      let islandOn = island.window.map { on.contains($0.windowNumber) } ?? false
      let stripList = strips()
      let stripsOn = stripList.filter { on.contains($0.windowNumber) }.count
      let height = await shapeHeight().map { String(format: "%.0f", $0) } ?? "抓不到"
      let line =
        "reminder-glow \(label)：岛窗口在屏上 \(islandOn)、isOpen \(island.isOpen)、显示着挂着的卡 \(island.isShowingPinned)、"
        + "内容「\(island.content?.title ?? "-")」、形体高 \(height) pt｜边框在屏上 \(stripsOn)/\(stripList.count)"
      print(line)
      lines.append(line)
    }

    await wait(0.5)
    // 1 空着（窗口启动时建好、没出过）
    fire()
    await wait(1.0)
    await report("1 空着时到点")
    clear()
    await wait(1.0)
    await report("1 收起后")

    // 2 刚出过一条提示、已经收起（窗口 orderOut 过）
    island.show("测试提示")
    await wait(0.6)
    island.dismiss()
    await wait(1.0)
    fire()
    await wait(1.0)
    await report("2 提示收起后到点")
    clear()
    await wait(1.0)

    // 3 岛上正挂着一条提示（原地换成卡）
    island.show("测试提示", detail: "带详情")
    await wait(0.4)
    fire()
    await wait(1.0)
    await report("3 挂着提示时到点")
    clear()
    await wait(1.0)

    // 4 进行中的提示
    island.show("正在压缩…", tone: .progress)
    await wait(0.4)
    fire()
    await wait(1.0)
    await report("4 进行中时到点")
    clear()
    island.dismiss()
    await wait(1.0)

    // 5 耳朵上有活动
    island.setActivity(
      Island.Activity(id: "probe", kind: .awake, title: "保持唤醒", symbol: "cup.and.saucer.fill"))
    await wait(1.0)
    fire()
    await wait(1.0)
    await report("5 耳朵上有活动时到点")
    clear()
    await wait(1.0)
    await report("5 收起后（该回到耳朵）")
    island.endActivity("probe")
    await wait(1.0)

    // 6 指针停在岛上的提示上（悬停）：卡先排着，指针一离开（这里指针其实不在岛上，0.2 秒后自己发现）换上
    island.show("测试提示")
    await wait(0.4)
    island.hover(true)
    fire()
    await report("6 悬停时到点（当下）")
    await wait(3.0)
    await report("6 悬停时到点（3 秒后）")
    clear()
    await wait(1.0)

    // 7 进全屏空间的动画中途到点，再退回桌面
    host.makeKeyAndOrderFront(nil)
    NSApp.activate()
    await wait(0.6)
    host.toggleFullScreen(nil)
    await wait(0.15)
    fire()
    await wait(2.5)
    await report("7 进全屏动画中途到点（在全屏空间）")
    host.toggleFullScreen(nil)
    await wait(2.5)
    await report("7 退回桌面")
    clear()
    await wait(1.0)

    // 8 卡亮着时进出全屏空间
    fire()
    await wait(0.6)
    host.toggleFullScreen(nil)
    await wait(2.5)
    await report("8 亮着时进全屏空间")
    host.toggleFullScreen(nil)
    await wait(2.5)
    await report("8 退回桌面")
    clear()
    await wait(1.0)

    // 9 进全屏动画中途收起（知道了）：边框该一条不剩
    fire()
    await wait(0.6)
    host.toggleFullScreen(nil)
    await wait(0.3)
    let old = strips()
    glow.dismiss()
    island.unpin()
    await wait(2.5)
    let on9 = onScreen()
    let line9 =
      "reminder-glow 9 进全屏中途收起：旧边框还在屏上 \(old.filter { on9.contains($0.windowNumber) }.count)/\(old.count)、岛显示着卡 \(island.isShowingPinned)"
    print(line9)
    lines.append(line9)
    host.toggleFullScreen(nil)
    await wait(2.5)

    // 10 出全屏动画中途到点
    host.toggleFullScreen(nil)
    await wait(2.5)
    host.toggleFullScreen(nil)
    await wait(0.15)
    fire()
    await wait(2.5)
    await report("10 出全屏动画中途到点（回到桌面）")
    clear()

    let dir = ProcessInfo.processInfo.environment["KITTY_LIVE_REMINDER_GLOW"] ?? ""
    if dir.hasPrefix("/") {
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? (lines.joined(separator: "\n") + "\n").write(
        toFile: dir + "/report.md", atomically: true, encoding: .utf8)
    }
  }
}
