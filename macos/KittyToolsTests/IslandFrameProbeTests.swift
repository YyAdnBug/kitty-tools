// 刘海岛动画的掉帧探针（按需，2026-10-26 用户报「灵动岛的交互动画存在卡顿」）：屏上建一座真的岛（屏幕顶部正中，约 8 秒，
// 不动鼠标、不抢键盘），依次走出现 → 悬停展开 → 收起 → 开那一张 → 收那一张 → 进行中换成结果，期间挂一条显示链，
// 记主线程每一拍回调的时刻：SwiftUI 每帧在主线程排版排不完，回调就会晚，间隔超过 1.5 帧算掉一帧。改了岛的动画后前后各跑一遍：
//   TEST_RUNNER_KITTY_ISLAND_FRAMES=1 xcodebuild … test -only-testing:'KittyToolsTests/IslandFrameProbeTests/measure()'
// 结果 grep「island-frames」。只看主线程这一侧；渲染服务那一侧掉的帧（比如阴影、模糊的离屏渲染）这里看不到——
// 那一侧看 recording()（同一个开关，要「屏幕录制」授权）：岛背后垫一块浅灰窗口，用 ScreenCaptureKit 逐帧抓刘海那一块，
// 量黑色形体每一帧的宽和高，看收起有没有先停一下、换内容有没有先变宽再缩回、动画中途有没有一样的帧连着出（卡住）。
// 结果 grep「island-shape」

import AppKit
import QuartzCore
import ScreenCaptureKit
import Synchronization
import Testing

@testable import KittyTools

/// 显示链每拍记一次时刻
@MainActor private final class FrameClock: NSObject {
  var stamps: [(phase: String, time: CFTimeInterval)] = []
  var phase = ""
  private var link: CADisplayLink?

  func start() {
    let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick))
    link?.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() { link?.invalidate() }

  @objc private func tick(_ link: CADisplayLink) {
    stamps.append((phase, CACurrentMediaTime()))
  }
}

struct IslandFrameProbeTests {
  @MainActor
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["KITTY_ISLAND_FRAMES"] != nil))
  func measure() async throws {
    let island = Island()
    let url = URL(filePath: "/tmp/截屏 2026-10-26 14.32.08.png")
    island.boardActions = {
      HotKeyAction.islandShortcuts.map { Island.Action($0.title, symbol: $0.symbol) {} }
    }
    // 先垫几条进列表（那一张里要有东西排）
    for title in ["已复制", "已存为片段", "翻译失败", "已导出 12 条", "已暂停记录剪贴板", "已复制色值"] {
      island.show(title, detail: "https://example.com/kitty-tools/\(title)")
    }
    try await Task.sleep(for: .seconds(0.6))
    island.dismiss()
    try await Task.sleep(for: .seconds(1))

    let clock = FrameClock()
    clock.start()
    func step(_ name: String, seconds: Double, _ action: () -> Void) async throws {
      clock.phase = name
      action()
      try await Task.sleep(for: .seconds(seconds))
    }
    try await step("出现", seconds: 0.8) {
      island.show(
        "已保存到「桌面」", detail: "截屏 2026-10-26 14.32.08.png", actions: .file(url))
    }
    try await step("悬停展开", seconds: 0.8) { island.hover(true) }
    try await step("收起", seconds: 0.9) { island.dismiss() }
    try await step("开那一张", seconds: 1.0) { island.toggleBoard() }
    try await step("收那一张", seconds: 1.0) { island.toggleBoard() }
    try await step("进行中", seconds: 0.6) { island.show("正在压缩…", tone: .progress) }
    try await step("换成结果", seconds: 0.8) {
      island.show("已压缩", detail: "12.4 MB → 3.1 MB", actions: .file(url))
    }
    try await step("收起结果", seconds: 0.9) { island.dismiss() }
    clock.stop()

    let frame = 1.0 / 60
    var report: [String] = []
    var order: [String] = []
    for stamp in clock.stamps where !order.contains(stamp.phase) { order.append(stamp.phase) }
    var totalDropped = 0
    var worst = 0.0
    for phase in order {
      let times = clock.stamps.filter { $0.phase == phase }.map(\.time)
      let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
      let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) }
      let longest = (gaps.max() ?? 0) * 1000
      totalDropped += dropped
      worst = max(worst, longest)
      report.append(
        String(format: "%@ 回调 %d 次、掉 %d 帧、最长 %.1f ms", phase, times.count, dropped, longest))
    }
    print("island-frames " + report.joined(separator: "；"))
    print(String(format: "island-frames 合计掉 %d 帧，最长一拍 %.1f ms", totalDropped, worst))
  }

  /// 屏上实录：逐帧量形体的宽高（见文件头）
  @MainActor
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["KITTY_ISLAND_FRAMES"] != nil))
  func recording() async throws {
    let mouse = NSEvent.mouseLocation
    let screen = try #require(
      NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
    let top: CGFloat =
      if case .notch(_, let height) = Island.geometry(of: screen) { height } else { 0 }
    let area = CGRect(
      x: screen.frame.midX - 300, y: screen.frame.maxY - 300, width: 600, height: 300)
    let backdrop = NSWindow(
      contentRect: area, styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false
    backdrop.level = .statusBar
    backdrop.backgroundColor = NSColor(white: 0.8, alpha: 1)
    backdrop.ignoresMouseEvents = true
    backdrop.orderFrontRegardless()
    defer { backdrop.orderOut(nil) }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let screenID =
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    let display = try #require(content.displays.first { $0.displayID == screenID })
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = CGRect(
      x: area.minX - screen.frame.minX, y: 0, width: area.width, height: area.height)
    configuration.width = Int(area.width)
    configuration.height = Int(area.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    let sink = ShapeSink(row: Int(top) + 3)
    let stream = SCStream(
      filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration,
      delegate: sink)
    try stream.addStreamOutput(
      sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "island-shape"))
    try await stream.startCapture()

    let island = Island()
    let url = URL(filePath: "/tmp/a.png")
    var marks: [(String, Double)] = []
    func step(_ name: String, seconds: Double, _ action: () -> Void) async throws {
      marks.append((name, CACurrentMediaTime()))
      action()
      try await Task.sleep(for: .seconds(seconds))
    }
    try await Task.sleep(for: .milliseconds(300))
    try await step("出现", seconds: 0.8) {
      island.show("已保存到「桌面」", detail: "截屏 2026-10-26 14.32.08.png", actions: .file(url))
    }
    try await step("换成结果", seconds: 0.8) {
      island.show("已复制", detail: "https://example.com")
    }
    try await step("收起", seconds: 0.8) { island.dismiss() }
    try await step("开那一张", seconds: 0.9) { island.toggleBoard() }
    try await step("收那一张", seconds: 0.8) { island.toggleBoard() }
    try await stream.stopCapture()

    let frames = sink.frames.withLock { $0 }
    var lines: [String] = []
    for (index, (name, start)) in marks.enumerated() {
      let end = index + 1 < marks.count ? marks[index + 1].1 : .infinity
      let phase = frames.filter { $0.time >= start && $0.time < end }
      guard let last = phase.last else { continue }
      // 动起来之前停了多久：第一帧和上一阶段末尾的形体不一样的时刻
      let before = frames.last { $0.time < start }
      let moved = phase.first { $0.width != before?.width || $0.height != before?.height }
      let latency = moved.map { ($0.time - start) * 1000 } ?? -1
      // 中途卡住：还没到终点时连着 3 帧以上一模一样
      var stall = 0
      var run = 1
      for (a, b) in zip(phase, phase.dropFirst()) {
        if a.width == b.width, a.height == b.height,
          (b.width, b.height) != (last.width, last.height)
        {
          run += 1
          stall = max(stall, run)
        } else {
          run = 1
        }
      }
      let widest = phase.map(\.width).max() ?? 0
      let series = phase.map { "\($0.width)×\($0.height)" }.joined(separator: " ")
      lines.append(
        String(
          format: "%@：%d 帧，%.0f ms 后开始动，最长卡 %d 帧，最宽 %d、最后 %d×%d | %@", name, phase.count,
          latency, stall, widest, last.width, last.height, series))
    }
    for line in lines { print("island-shape " + line) }
  }
}

/// 逐帧量黑色形体：row 那一行最左、最右的黑点之间是宽；正中那一列从下往上第一个黑点是底（高）。系统在后台线程回调
nonisolated private final class ShapeSink: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
  let row: Int
  let frames = Mutex<[(time: Double, width: Int, height: Int)]>([])

  init(row: Int) { self.row = row }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let (width, height) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let pixels = UnsafeRawBufferPointer(start: base, count: stride * height)
    func black(_ x: Int, _ y: Int) -> Bool {
      let offset = y * stride + x * 4
      return max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < 40
    }
    let y = min(row, height - 1)
    let xs = (0..<width).filter { black($0, y) }
    let shapeWidth = (xs.last ?? 0) - (xs.first ?? 0)
    let bottom = (0..<height).reversed().first { black(width / 2, $0) } ?? 0
    frames.withLock {
      $0.append((sampleBuffer.presentationTimeStamp.seconds, xs.isEmpty ? 0 : shapeWidth, bottom))
    }
  }
}
