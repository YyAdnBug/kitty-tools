// 框选遮罩「鼠标动一下」的探针（2026-10-26 用户手测「截图的颜色识别快速移动时很卡」；按需开，默认跳过）：
// `TEST_RUNNER_KITTY_SELECTION_PROBE=1` 才跑，数字 grep「selection-probe」。
// 量的是主线程每收到一次鼠标移动要花多久——鼠标 60–120 Hz 地动，一次超过约 8 ms 就跟不上了。
// 分四段：① 放大镜的采样本身（Self.sample，15 × 15 的小位图）② 待选时设一次 mouse ③ 已经框好、
// 正在悬停调整时设一次 mouse ④ 正在拖框。截图和截图翻译两种模式各量一遍（翻译那边没有色值卡、没有工具栏）。
// 屏外窗口、不当 key、不激活本 App。
//
// 2026-10-26 量下来每一下都是 0.02–0.10 ms（最长 0.86 ms），**主线程根本不是瓶颈**：当时「快速移动很卡」
// 是鼠标移动事件被系统合并、本 App 又从不激活，收到的事件比屏幕刷新稀。跟手靠 SelectionView.followPointer
// 那条显示链，这里量不到——改了放大镜这条路之后先跑它看主线程没变重，跟不跟手还得真机看。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct SelectionProbeTests {
  nonisolated private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["KITTY_SELECTION_PROBE"] == "1"
  }

  /// 一块 1920 × 1200 的假冻结帧（每 24 行换个灰度，采样时有东西可取）
  private func frozen(width: Int = 1920, height: Int = 1200) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    for band in 0..<(height / 24) {
      context.setFillColor(CGColor(gray: Double(band % 8) / 8 + 0.1, alpha: 1))
      context.fill(CGRect(x: 0, y: band * 24, width: width, height: 24))
    }
    return context.makeImage()!
  }

  /// 把视图摆进一扇屏外窗口（不当 key、不激活）
  private func stage(_ view: SelectionView, size: NSSize) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFront(nil)
    window.layoutIfNeeded()
    return window
  }

  /// 跑 count 次、返回（中位，最长）毫秒
  private func time(_ count: Int, _ body: (Int) -> Void) -> (median: Double, worst: Double) {
    var samples: [Double] = []
    samples.reserveCapacity(count)
    for i in 0..<count {
      let start = Date()
      body(i)
      samples.append(Date().timeIntervalSince(start) * 1000)
    }
    samples.sort()
    return (samples[samples.count / 2], samples.last ?? 0)
  }

  @Test(.enabled(if: SelectionProbeTests.isEnabled)) func measure() throws {
    let image = frozen()
    let size = NSSize(width: 960, height: 600)  // 点（1920 × 1200 像素 @2x）
    func line(_ what: String, _ result: (median: Double, worst: Double)) -> String {
      String(format: "selection-probe %@：中位 %.2f ms，最长 %.2f ms", what, result.median, result.worst)
    }
    var report: [String] = []

    // ① 采样本身
    report.append(
      line(
        "放大镜采样（15 × 15）",
        time(300) { i in
          _ = SelectionView.sample(image, x: 200 + i * 3, y: 300 + i * 2, size: 15)
        }))

    // ② 截图：待选（没有选区，鼠标在桌面上晃）
    for (what, mode) in [("截图", SelectionView.Mode.capture), ("截图翻译", .quick)] {
      let view = SelectionView(
        image: image, session: SelectionSession(mode: mode, hint: "拖动框选"))
      let window = stage(view, size: size)
      defer { window.orderOut(nil) }
      report.append(
        line(
          "\(what) · 待选时动一下",
          time(200) { i in
            view.mouse = CGPoint(x: 120 + CGFloat(i % 160) * 4, y: 110 + CGFloat(i % 90) * 3)
          }))
      guard mode == .capture else { continue }
      // ③ 截图：框好之后（工具栏、手柄、尺寸胶囊都在）
      view.select(CGRect(x: 160, y: 140, width: 420, height: 260))
      view.isAdjusting = true
      window.layoutIfNeeded()
      report.append(
        line(
          "\(what) · 框好之后动一下",
          time(200) { i in
            view.mouse = CGPoint(x: 180 + CGFloat(i % 160) * 2, y: 160 + CGFloat(i % 90) * 2)
          }))
      // ④ 正在拖框（最热的那条路：每帧都要改选区）
      report.append(
        line(
          "\(what) · 拖框时动一下",
          time(200) { i in
            view.selection = CGRect(
              x: 160, y: 140, width: 420 + CGFloat(i % 40), height: 260 + CGFloat(i % 30))
          }))
    }
    print(report.joined(separator: "\n"))
  }
}
