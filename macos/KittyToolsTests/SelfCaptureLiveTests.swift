// 截图 / 录屏 / 长截图拍不拍得到本 App 自己的窗口（按需实录探针，2026-11-20）：屏幕左下角摆一扇红色、带标题栏、普通层级的
// NSWindow（设置窗的样子，不当 key）和旁边一块绿色的 NSPanel（不在白名单里的自家窗口）约 2 秒，分别用截图的冻结帧
// （ScreenCapture.freeze）、录屏的过滤器写法（排除本 App、把红窗口列进例外）、长截图的过滤器（ScrollCapture.filter）、不排除
// 任何东西的 ScreenCaptureKit 和系统的 screencapture 命令各截一次，看红块在不在。另把正在跑的正式版 Kitty Tools 在屏上的窗口
// 逐个用系统的 screencapture -l 单独截一张，看别家截图工具拍不拍得到。要「屏幕录制」授权；图存进输出目录（绝对路径），看完自己删：
//   TEST_RUNNER_KITTY_LIVE_SELF_CAPTURE=/tmp/kitty-self xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test '-only-testing:KittyToolsTests/SelfCaptureLiveTests/ownWindowInEveryPath()'
import AppKit
import ScreenCaptureKit
import Testing

@testable import KittyTools

nonisolated private let selfCaptureDirectory = ProcessInfo.processInfo.environment[
  "KITTY_LIVE_SELF_CAPTURE"
].map { URL(filePath: $0, directoryHint: .isDirectory) }

@Suite(.enabled(if: selfCaptureDirectory != nil, "按需：TEST_RUNNER_KITTY_LIVE_SELF_CAPTURE=<目录>"))
struct SelfCaptureLiveTests {
  @Test func ownWindowInEveryPath() async throws {
    let folder = try #require(selfCaptureDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let screen = try #require(NSScreen.screens.first)
    let visible = screen.visibleFrame
    let frame = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 160, height: 120)
    let window = NSWindow(
      contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.backgroundColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    let side = frame.offsetBy(dx: frame.width + 40, dy: 0)
    let panel = NSPanel(
      contentRect: side, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.backgroundColor = NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1)
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    panel.orderFrontRegardless()
    defer {
      window.orderOut(nil)
      panel.orderOut(nil)
    }
    try await Task.sleep(for: .milliseconds(400))
    var lines: [String] = []
    let id = try #require(ScreenCapture.windowID(window.windowNumber))

    // 1. 截图的冻结帧
    let shots = try await ScreenCapture.freeze()
    let shot = try #require(shots.first { $0.screen == screen })
    lines.append("截图冻结帧 ScreenCapture.freeze：\(sample(shot.image, at: frame, on: screen))")
    #expect(isRed(shot.image, at: frame, on: screen), "截图冻结帧里没有设置窗样子的自家窗口")

    // 2. 不排除任何东西的 ScreenCaptureKit
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    let display = try #require(content.displays.first { $0.displayID == screen.displayID })
    let plain = try await capture(SCContentFilter(display: display, excludingWindows: []))
    lines.append("SCK 不排除：\(sample(plain, at: frame, on: screen))")

    // 3. 录屏的过滤器：排除本 App，把这扇窗口列进例外（ScreenRecorder.makeFilter 的写法）
    let me = content.applications.first { $0.processID == getpid() }
    let listed = content.windows.filter { $0.windowID == id }
    lines.append("本 App 在 SCK 的 App 列表里：\(me != nil)；这扇窗口在窗口表里：\(!listed.isEmpty)")
    if let me {
      let recorded = try await capture(
        SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: listed))
      lines.append("录屏过滤器（排除本 App + 例外）：\(sample(recorded, at: frame, on: screen))")
    }

    // 3b. 长截图的过滤器（产品代码）：红窗口照拍、绿面板不拍
    let scrolled = try await capture(ScrollCapture.filter(display: display, content: content))
    lines.append(
      "长截图过滤器 ScrollCapture.filter：红窗口 \(sample(scrolled, at: frame, on: screen))；绿面板处读回 \(sample(scrolled, at: side, on: screen))"
    )
    #expect(isRed(scrolled, at: frame, on: screen), "长截图拍不到设置窗样子的自家窗口")
    #expect(!isGreen(scrolled, at: side, on: screen), "长截图拍进了不在白名单里的自家面板")

    // 4. 系统的 screencapture（同 ⌘⇧4 / ⌘⇧5 的截屏进程）
    let file = folder.appending(path: "system-region.png")
    let top = (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY
    run([
      "-x", "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", file.path,
    ])
    if let image = load(file) {
      lines.append(
        "系统 screencapture -R：\(sample(image, at: CGRect(origin: .zero, size: frame.size), on: nil))"
      )
    } else {
      lines.append("系统 screencapture -R：没出文件")
    }
    window.orderOut(nil)
    panel.orderOut(nil)

    // 5. 正式版 Kitty Tools 在屏上的窗口：系统 screencapture -l 单独截
    let release = content.windows.filter {
      $0.owningApplication?.bundleIdentifier == "com.yy.kitty-tools.native" && $0.isOnScreen
    }
    lines.append("正式版在屏上的窗口 \(release.count) 扇")
    for item in release {
      let out = folder.appending(path: "release-\(item.windowID).png")
      run(["-x", "-o", "-l\(item.windowID)", out.path])
      let verdict =
        load(out).map { "出了 \($0.width)×\($0.height)，不透明像素 \(opaqueRatio($0))%" } ?? "没出文件"
      lines.append(
        "  \(item.windowID) 层 \(item.windowLayer) 「\(item.title ?? "")」 \(Int(item.frame.width))×\(Int(item.frame.height))：\(verdict)"
      )
    }
    let report = lines.joined(separator: "\n")
    try report.write(to: folder.appending(path: "report.md"), atomically: true, encoding: .utf8)
    print("self-capture\n" + report)
  }

  private func capture(_ filter: SCContentFilter) async throws -> CGImage {
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = Int(filter.contentRect.width * scale)
    configuration.height = Int(filter.contentRect.height * scale)
    configuration.showsCursor = false
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
  }

  /// 色块中心读回的颜色和「是不是红的」；screen 为 nil 时 rect 就是图里的点坐标
  private func sample(_ image: CGImage, at rect: CGRect, on screen: NSScreen?) -> String {
    guard let (r, g, b) = center(image, at: rect, on: screen) else { return "读不到像素" }
    return "\(isRed(image, at: rect, on: screen) ? "拍到了" : "没拍到")（\(r),\(g),\(b)）"
  }

  private func isRed(_ image: CGImage, at rect: CGRect, on screen: NSScreen?) -> Bool {
    center(image, at: rect, on: screen).map { $0.0 > 180 && $0.1 < 80 && $0.2 < 80 } ?? false
  }

  private func isGreen(_ image: CGImage, at rect: CGRect, on screen: NSScreen?) -> Bool {
    center(image, at: rect, on: screen).map { $0.0 < 80 && $0.1 > 160 && $0.2 < 100 } ?? false
  }

  private func center(_ image: CGImage, at rect: CGRect, on screen: NSScreen?) -> (Int, Int, Int)? {
    let k = CGFloat(image.width) / (screen?.frame.width ?? rect.width)
    let x = Int(((screen.map { rect.midX - $0.frame.minX } ?? rect.midX)) * k)
    let y = Int(((screen.map { $0.frame.maxY - rect.midY } ?? rect.midY)) * k)
    return rgb(image, x: x, y: y)
  }

  private func rgb(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int)? {
    guard (0..<image.width).contains(x), (0..<image.height).contains(y) else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(
      image,
      in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
  }

  private func opaqueRatio(_ image: CGImage) -> Int {
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    guard
      let context = CGContext(
        data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let opaque = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 200 }.count
    return opaque * 100 / max(w * h, 1)
  }

  private func run(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/sbin/screencapture")
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
  }

  private func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}
