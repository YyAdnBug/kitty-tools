// 浮层退场淡出的替身（OverlayPanel.fadeOutStandIn，2026-10-03）：用户关掉面板时不走系统的窗口淡出（毛玻璃底会泛白），
// 换一块同样材质的替身窗口在原位淡出，内容是画出来的图。
// 平时跑的两条：内容分两张画（挂合成滤镜的图层单独一张）、dismiss 之后真面板立刻收走而替身留着淡。
// 屏上实录自检（TEST_RUNNER_KITTY_LIVE_PANEL_FADE=1 才跑，要「屏幕录制」授权）：屏幕右下角垫一块自己的深色底、上面放
// 一块真的 OverlayPanel，关掉它，用 ScreenCaptureKit 逐帧抓那一小块屏幕（里面只有探针自己的窗口），看面板中间的平均亮度：
// 淡出期间不该比关之前亮。系统淡出时这里从 42 冲到 87；改 dismiss、换材质、上 macOS 26 的液态玻璃分支后都跑一遍：
//   TEST_RUNNER_KITTY_LIVE_PANEL_FADE=1 xcodebuild … test -only-testing:'KittyToolsTests/PanelFadeTests/closingNeverBrightens(appearance:)'

import AppKit
import ScreenCaptureKit
import SwiftUI
import Synchronization
import Testing

@testable import KittyTools

nonisolated private let probesScreen =
  ProcessInfo.processInfo.environment["KITTY_LIVE_PANEL_FADE"] != nil

/// 抓到的每一帧只记时刻和中间那块的平均亮度。系统在后台线程回调，所以整个类 nonisolated（同 RecordingProbeTests）
nonisolated private final class LumaSink: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
  let frames = Mutex<[(time: Double, luma: Double)]>([])

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
    var sum = 0.0
    var count = 0.0
    for y in (height * 3 / 8)..<(height * 5 / 8) {
      for x in (width * 3 / 8)..<(width * 5 / 8) {
        let offset = y * stride + x * 4  // BGRA
        sum +=
          0.0722 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.2126
          * Double(pixels[offset + 2])
        count += 1
      }
    }
    let frame = (sampleBuffer.presentationTimeStamp.seconds, sum / max(count, 1))
    frames.withLock { $0.append(frame) }
  }
}

@MainActor @Suite(.serialized)
struct PanelFadeTests {
  /// 有主文字、次要文字（毛玻璃上「鲜亮」的那种）、分隔线、色块、选中底的一小块内容
  private struct Sample: View {
    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text("搜索").font(.system(size: 20)).padding(14)
        Divider()
        ForEach(0..<4, id: \.self) { index in
          HStack {
            RoundedRectangle(cornerRadius: 6).fill(.blue).frame(width: 24, height: 24)
            Text("第 \(index + 1) 行").font(.system(size: 14))
            Text("副标题").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
          }
          .padding(.horizontal, 12).frame(height: 40)
          .background(index == 0 ? Style.selectedFill : .clear, in: .rect(cornerRadius: 8))
          .padding(.horizontal, 6)
        }
        Spacer(minLength: 0)
      }
    }
  }

  /// 图里某一点的颜色分量（0–255，左上角为原点）
  private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [] }
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
      .map { Int(($0 * 255).rounded()) }
  }

  /// 内容分两张画：挂着合成滤镜的图层（毛玻璃上「鲜亮」的次要文字）单独一张、带着那个滤镜，普通内容另一张；
  /// 混着的容器底下，不带滤镜的那一支只进普通的那张。画完图层的隐藏状态原样不变。屏外窗口，不显示
  @Test func snapshotsSplitVibrantLayers() throws {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
    view.wantsLayer = true
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 60, height: 20), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    let root = try #require(view.layer)
    func block(_ x: CGFloat, _ color: NSColor, filter: String? = nil) -> CALayer {
      let layer = CALayer()
      layer.frame = CGRect(x: x, y: 0, width: 20, height: 20)
      layer.backgroundColor = color.cgColor
      layer.compositingFilter = filter
      return layer
    }
    let plain = block(0, .red)
    let group = CALayer()
    group.frame = root.bounds
    let vibrant = block(20, .white, filter: "plusL")
    let sibling = block(40, .green)
    let hidden = block(40, .white, filter: "plusL")
    hidden.isHidden = true
    root.addSublayer(plain)
    root.addSublayer(group)
    for layer in [vibrant, sibling, hidden] { group.addSublayer(layer) }

    let images = OverlayPanel.snapshots(of: view)
    #expect(images.count == 2)
    let normal = try #require(images.first { $0.filter == nil }?.image)
    let lit = try #require(images.first { $0.filter != nil })
    #expect(lit.filter as? String == "plusL")
    let scale = normal.width / 60
    let at = { (image: CGImage, x: Int) in self.pixel(image, x: x * scale, y: 10 * scale) }
    // 图是显示器的色彩空间，换算回来纯色也不是 255 / 0，只看哪个分量最大：红块、绿块在普通的那张里，白块只在带滤镜的那张里
    let (red, green, white) = (at(normal, 10), at(normal, 50), at(lit.image, 30))
    #expect(red[0] > 200 && red[0] > red[1] + 100 && red[3] == 255)
    #expect(green[1] > 200 && green[1] > green[0] + 100 && green[3] == 255)
    #expect(at(normal, 30).last == 0)
    #expect(white.allSatisfy { $0 > 240 })
    #expect(at(lit.image, 10).last == 0 && at(lit.image, 50).last == 0)
    #expect(!plain.isHidden && !vibrant.isHidden && !sibling.isHidden && hidden.isHidden)
    // 没有带滤镜的图层：只有普通的一张
    vibrant.compositingFilter = nil
    hidden.compositingFilter = nil
    #expect(OverlayPanel.snapshots(of: view).map { $0.filter == nil } == [true])
  }

  /// 用户关掉（dismiss）：真面板立刻收走、onHide 当场调，原位留一块替身在淡（截图的留用名单不认它），淡完自己收走；
  /// 程序收起（hide）没有替身。屏外窗口，不抢键盘
  @Test func dismissLeavesAFadingStandIn() async throws {
    let panel = OverlayPanel(
      size: NSSize(width: 240, height: 160), autoHide: .clickOutside, isPinned: { true },
      content: Sample())
    panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    var hides = 0
    panel.onHide = { hides += 1 }
    let standIns = {
      NSApp.windows.filter { String(describing: type(of: $0)) == "PanelStandIn" && $0.isVisible }
    }
    panel.present(makingKey: false, keepsPlace: true)
    panel.hide()
    #expect(hides == 1 && standIns().isEmpty)
    guard !Style.reduceMotion else { return }  // 减弱动态效果时 dismiss 也没有替身
    panel.present(makingKey: false, keepsPlace: true)
    let frame = panel.frame
    panel.dismiss()
    #expect(!panel.isVisible && hides == 2)
    let standIn = try #require(standIns().first)
    #expect(standIn.frame == frame && standIn.ignoresMouseEvents && !standIn.canBecomeKey)
    #expect(standIn.level == panel.level && panel.animationBehavior == .none)
    let kept = ScreenCapture.keptOwnWindows(ScreenCapture.ownWindows())
    #expect(!kept.contains(CGWindowID(standIn.windowNumber)))
    for _ in 0..<50 where !standIns().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(standIns().isEmpty)
  }

  /// 屏上实录：关掉面板后的每一帧，面板中间那块的亮度都不比关之前高（深色底上只该越淡越暗），最后回到底色
  @Test(.enabled(if: probesScreen), arguments: [NSAppearance.Name.darkAqua, .aqua])
  func closingNeverBrightens(appearance: NSAppearance.Name) async throws {
    try #require(CGPreflightScreenCaptureAccess(), "要「屏幕录制」授权")
    let screen = try #require(NSScreen.main)
    let area = NSRect(
      x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.minY + 20, width: 400, height: 320)
    let backdrop = NSWindow(
      contentRect: area, styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false
    backdrop.level = .floating
    backdrop.ignoresMouseEvents = true
    backdrop.hasShadow = false
    backdrop.backgroundColor = NSColor(white: 0.12, alpha: 1)
    backdrop.orderFrontRegardless()
    defer { backdrop.orderOut(nil) }
    let panel = OverlayPanel(
      size: NSSize(width: 320, height: 240), autoHide: .clickOutside, isPinned: { true },
      content: Sample())
    panel.appearance = NSAppearance(named: appearance)
    panel.setFrameOrigin(NSPoint(x: area.midX - 160, y: area.midY - 120))

    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let display = try #require(
      content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = CGRect(  // 显示器坐标：点，原点左上
      x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY, width: area.width,
      height: area.height)
    configuration.width = Int(area.width)
    configuration.height = Int(area.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    let sink = LumaSink()
    let stream = SCStream(
      filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration,
      delegate: sink)
    try stream.addStreamOutput(
      sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "panel-fade"))
    try await stream.startCapture()
    try await Task.sleep(for: .milliseconds(400))
    panel.present(makingKey: false, keepsPlace: true)
    try await Task.sleep(for: .milliseconds(800))
    try #require(panel.isVisible, "面板被点掉了（探针开着时别点别处），重跑")
    let closed = CACurrentMediaTime()
    panel.dismiss()
    try await Task.sleep(for: .milliseconds(600))
    try await stream.stopCapture()

    let frames = sink.frames.withLock { $0 }
    let before = try #require(frames.last { $0.time < closed - 0.05 }?.luma)
    let closing = frames.filter { $0.time >= closed }.map(\.luma)
    print("PanelFade[\(appearance.rawValue)] 关之前 \(before)，之后逐帧 \(closing.map { Int($0) })")
    #expect(closing.count >= 3, "没抓到淡出的帧")
    #expect((closing.max() ?? .infinity) <= before + 3, "淡出期间比关之前亮：泛白")
    #expect(abs((closing.last ?? 0) - 31) < 3)  // 底色 0.12 白的亮度
  }
}
