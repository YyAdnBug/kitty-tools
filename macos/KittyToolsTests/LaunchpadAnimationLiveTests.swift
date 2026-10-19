// 启动台动画的屏上实录自检（按需：TEST_RUNNER_KITTY_LIVE_LAUNCHPAD_ANIM=<目录> 才跑，要「屏幕录制」授权；**屏幕左下角会出现一块
// 640 × 400 的窗口约 5 秒**——放在所有窗口后面、不当 key、不动鼠标键盘，跑之前先跟用户说一声）。
// 为什么要它：屏外的 cacheDisplay 画不出动画中途的变换和离场视图的层次，屏外窗口 ScreenCaptureKit 也录不到（-3811）——
// 2026-10-18「关文件夹没有动画」「进出编辑一闪」两个问题屏外单测都看不出，是这样屏上逐帧录出来的。
// 录：打开文件夹、点空白关上、进抖动、退抖动、拖着让位、文件夹开着时进出抖动，每一段一串 PNG 写进目录，report.md 记每帧的变化量。
// 查两件：文件夹开 / 关都有中间帧（不是一下子出现 / 没了）；进出抖动时网格那块的平均亮度不跳（原来换视图那一下图标发白）。
//   TEST_RUNNER_KITTY_LIVE_LAUNCHPAD_ANIM=/tmp/kitty-launchpad-anim xcodebuild … test \
//     -only-testing:'KittyToolsTests/LaunchpadAnimationLiveTests/recordAnimations()'

import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing

@testable import KittyTools

nonisolated private let liveDirectory = ProcessInfo.processInfo.environment[
  "KITTY_LIVE_LAUNCHPAD_ANIM"]

@MainActor
struct LaunchpadAnimationLiveTests {
  /// 进出抖动时图标里面和静止时的差最多多少：2026-10-18 量过——现在约 0.01，抖动时换视图的那版（一闪）约 0.07
  static let flashLimit = 0.05

  private func ref(_ name: String) -> LaunchpadAppRef {
    LaunchpadAppRef(bundleID: "com.example.\(name)", path: "/System/Applications/Calculator.app")
  }

  private func app(_ ref: LaunchpadAppRef) -> LaunchpadProjectApp {
    LaunchpadProjectApp(
      id: ref.id, ref: ref,
      item: LauncherItem(
        kind: .app, target: ref.path, title: ref.bundleID ?? "App", subtitle: "应用程序",
        names: [LauncherMatch.fold(ref.bundleID ?? "App")], initials: ["x"]),
      url: URL(filePath: ref.path), isSystem: false, inUtilities: false, isAppStore: false,
      category: nil)
  }

  /// 一帧：录下的时刻和像素（RGBA，一行 width × 4）
  private struct Frame {
    let label: String
    let ms: Int
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(label: String, ms: Int, image: CGImage) {
      self.label = label
      self.ms = ms
      width = image.width
      height = image.height
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      if let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      {
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      }
      self.pixels = pixels
    }

    /// 和另一帧每个像素（隔 4 个取一个）的平均差（0…1）
    func difference(_ other: Frame) -> Double {
      guard other.width == width, other.height == height else { return 1 }
      var sum = 0.0
      var count = 0.0
      for y in stride(from: 0, to: height, by: 4) {
        for x in stride(from: 0, to: width, by: 4) {
          let i = (y * width + x) * 4
          for c in 0..<3 { sum += abs(Double(pixels[i + c]) - Double(other.pixels[i + c])) }
          count += 3
        }
      }
      return count > 0 ? sum / count / 255 : 0
    }

    /// 和另一帧在几块方形（左上角为原点、按点算，scale 是像素 / 点）里的平均差（0…1）：只看图标里面，不看它周围的背景
    func difference(_ other: Frame, in squares: [CGRect], scale: CGFloat) -> Double {
      guard other.width == width, other.height == height else { return 1 }
      var sum = 0.0
      var count = 0.0
      for square in squares {
        let minX = max(Int(square.minX * scale), 0)
        let maxX = min(Int(square.maxX * scale), width)
        let minY = max(Int(square.minY * scale), 0)
        let maxY = min(Int(square.maxY * scale), height)
        for y in stride(from: minY, to: maxY, by: 1) {
          for x in stride(from: minX, to: maxX, by: 1) {
            let i = (y * width + x) * 4
            for c in 0..<3 { sum += abs(Double(pixels[i + c]) - Double(other.pixels[i + c])) }
            count += 3
          }
        }
      }
      return count > 0 ? sum / count / 255 : 0
    }
  }

  @Test(.enabled(if: liveDirectory != nil)) func recordAnimations() async throws {
    let out = try #require(liveDirectory)
    try? FileManager.default.removeItem(atPath: out)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let inside = (0..<6).map { ref("f\($0)") }
    let others = (0..<5).map { ref("o\($0)") }
    let folder = LaunchpadFolder(name: "X", pages: [inside])
    let layout = LaunchpadLayout(pages: [[.folder(folder)] + others.map { .app($0) }])
    let size = NSSize(width: 640, height: 400)
    let model = LaunchpadModel(
      layout: layout, catalog: (inside + others).map(app), icons: LaunchpadIcons(), columns: 4,
      rows: 3, screenSize: size, dragTiming: .immediate)
    model.onClose = {}
    // 背景用本机现在的壁纸（不透明：面板要是画到它后面去了，录出来就看不见——当初的毛病正是这样）
    model.wallpaper = NSScreen.main
      .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
      .flatMap { LaunchpadWallpaper.load(url: $0, maxPixel: 640) }
      .flatMap { LaunchpadWallpaper.render(source: $0, width: 320, height: 200) }
    let screen = try #require(NSScreen.main)
    let origin = NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20)
    let host = NSHostingView(
      rootView: AnyView(LaunchpadView(model: model).frame(width: size.width, height: size.height)))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    // 放在所有窗口后面、不当 key：ScreenCaptureKit 按窗口录，被挡着也录得到
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    try? await Task.sleep(for: .milliseconds(900))
    let shareable = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    let scWindow = try #require(
      shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let config = SCStreamConfiguration()
    config.width = Int(size.width * 2)
    config.height = Int(size.height * 2)
    config.showsCursor = false
    var report = ["# 启动台动画屏上实录", "", "| 段 | 帧 | 时刻 | 和上一帧的差 |", "|---|---|---|---|"]

    func burst(_ label: String, ms: Int) async -> [Frame] {
      var frames: [Frame] = []
      let start = CACurrentMediaTime()
      while CACurrentMediaTime() - start < Double(ms) / 1000 {
        let at = Int((CACurrentMediaTime() - start) * 1000)
        guard
          let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        else { break }
        let frame = Frame(label: label, ms: at, image: image)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(
          to: URL(filePath: "\(out)/\(label)-\(String(format: "%02d", frames.count))-\(at)ms.png"))
        let change = frames.last.map { frame.difference($0) } ?? 0
        report.append(
          "| \(label) | \(frames.count) | \(at) ms | \(String(format: "%.4f", change)) |")
        frames.append(frame)
      }
      return frames
    }

    func click(_ point: NSPoint) {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        {
          window.sendEvent(event)
        }
      }
    }

    /// 开 / 关的中途有几帧和开始、结束两头都明显不一样（一下子出现 / 没了的话是 0）
    func middleFrames(_ frames: [Frame], before: Frame, after: Frame) -> Int {
      frames.filter { $0.difference(before) > 0.01 && $0.difference(after) > 0.01 }.count
    }

    let closed = await burst("0-start", ms: 1)
    model.openFolder(folder.id)
    let opening = await burst("1-open", ms: 450)
    try? await Task.sleep(for: .milliseconds(300))
    let open = await burst("2-open-settled", ms: 1)
    click(NSPoint(x: 12, y: 12))
    let closing = await burst("3-close", ms: 500)
    try? await Task.sleep(for: .milliseconds(300))
    let back = await burst("4-closed-settled", ms: 1)
    // 主网格上每个 App 图标里面那一块（中间 60%，转 ±1.5° 时边上的像素会变、里面基本不变）：进出抖动时和静止的那一帧比
    let metrics = model.metrics
    let inner = metrics.icon * 0.6
    let squares = (1..<6).compactMap { index in
      model.cellCenter(page: 0, index: index).map { center in
        CGRect(
          x: center.x - inner / 2, y: center.y - LaunchpadMetrics.iconLift - inner / 2,
          width: inner, height: inner)
      }
    }
    model.enterJiggle()
    let entering = await burst("5-enter-jiggle", ms: 400)
    try? await Task.sleep(for: .milliseconds(300))
    model.exitJiggle()
    let leaving = await burst("6-exit-jiggle", ms: 400)
    // 让位：拖起第一个，挪到第三个的左边沿（让位停 0.15 s 的那条这里不等：immediate）
    let start = try #require(model.cellCenter(page: 0, index: 1))
    model.beginDrag(
      tile: .app(others[0]), appID: others[0].id, folder: nil, at: start, origin: start)
    let edge = LaunchpadModel.cellRect(3, in: try #require(model.gridFrames[0]), metrics: metrics)
    model.updateDrag(location: CGPoint(x: edge.minX + 4, y: edge.midY), pageWidth: size.width)
    _ = await burst("7-reflow", ms: 500)
    model.cancelDrag()
    // 文件夹开着时进出抖动：文件夹里的图标平时是 SwiftUI 画的，抖动时换成图层视图——换的那一下不许闪
    model.exitJiggle()
    model.openFolder(folder.id)
    try? await Task.sleep(for: .milliseconds(600))
    let folderStill = await burst("8-folder-still", ms: 1)
    model.enterJiggle()
    let folderEntering = await burst("9-folder-enter-jiggle", ms: 400)
    try? await Task.sleep(for: .milliseconds(300))
    model.exitJiggle()
    let folderLeaving = await burst("10-folder-exit-jiggle", ms: 400)
    let folderSquares = (0..<6).map { index in
      let center = model.folderCellCenter(index)
      return CGRect(
        x: center.x - inner / 2, y: center.y - LaunchpadMetrics.iconLift - inner / 2, width: inner,
        height: inner)
    }

    let first = try #require(closed.first)
    let openFrame = try #require(open.first)
    let backFrame = try #require(back.first)
    let opened = middleFrames(opening, before: first, after: openFrame)
    let shut = middleFrames(closing, before: openFrame, after: backFrame)
    let jumps = (entering + leaving).map { $0.difference(backFrame, in: squares, scale: 2) }
    let worstJump = jumps.max() ?? 0
    let folderBase = try #require(folderStill.first)
    let folderJumps = (folderEntering + folderLeaving).map {
      $0.difference(folderBase, in: folderSquares, scale: 2)
    }
    let worstFolderJump = folderJumps.max() ?? 0
    report += [
      "", "- 打开的中间帧：\(opened)", "- 关上的中间帧：\(shut)",
      "- 进出抖动时图标里面和静止时最多差 \(String(format: "%.4f", worstJump))",
      "- 文件夹开着时进出抖动，文件夹里的图标和静止时最多差 \(String(format: "%.4f", worstFolderJump))",
    ]
    try report.joined(separator: "\n").write(
      toFile: "\(out)/report.md", atomically: true, encoding: .utf8)
    #expect(opened >= 1, "打开文件夹没有中间帧")
    #expect(shut >= 1, "关文件夹没有中间帧（面板一下子没了，或画到了网格后面）")
    #expect(worstJump < Self.flashLimit, "进出抖动时图标闪了一下（和静止时差 \(worstJump)）")
    #expect(
      worstFolderJump < Self.flashLimit, "文件夹里进出抖动时图标闪了一下（和静止时差 \(worstFolderJump)）")
  }
}
