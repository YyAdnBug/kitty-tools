// 长截图对着真 App 的按需实录探针（issue #57，2026-11-26）：用一个 App 打开自己生成的测试文档（不碰用户的文件），
// 把它最前面那扇窗口（整扇 / 中间正文那一块）当选区，按长截图的几种滚法边发滚轮边截帧，帧原样存盘；
// replay() 用当前的 ScrollStitcher 把存下的帧按顺序拼一遍，报每帧接没接上——改了拼接算法后对着同一批真帧比。
// 要「屏幕录制」授权；跑时会把那个 App 叫到前台、往它的窗口里发合成滚轮（光标挪到窗口中间、从 HID 层发），约 1 分钟，别碰键鼠。
// 帧是裸 BGRA，一帧几 MB，看完把目录删掉。
//   TEST_RUNNER_KITTY_LIVE_SCROLL_APP=/tmp/kitty-scroll xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test '-only-testing:KittyToolsTests/ScrollAppProbeTests/record()'
//   （同一个目录）… '-only-testing:KittyToolsTests/ScrollAppProbeTests/replay()'
// 另可加 TEST_RUNNER_KITTY_LIVE_SCROLL_APP_BUNDLE=<bundle id>（默认 WPS：com.kingsoft.wpsoffice.mac）、
// TEST_RUNNER_KITTY_LIVE_SCROLL_APP_DOCS=doc,sheet,pdf（录哪几份，默认全部）。
import AppKit
import ScreenCaptureKit
import Testing

@testable import KittyTools

nonisolated private let scrollAppDirectory = ProcessInfo.processInfo.environment[
  "KITTY_LIVE_SCROLL_APP"
].map { URL(filePath: $0, directoryHint: .isDirectory) }

@Suite(.serialized, .enabled(if: scrollAppDirectory != nil))
@MainActor
struct ScrollAppProbeTests {
  static var directory: URL { scrollAppDirectory! }
  static var bundle: String {
    ProcessInfo.processInfo.environment["KITTY_LIVE_SCROLL_APP_BUNDLE"]
      ?? "com.kingsoft.wpsoffice.mac"
  }

  /// 三种滚法：pixel = 自动滚动那样每 1/60 秒一小段像素滚轮（连续的，同触控板）；flick = 手在触控板上一甩
  /// （0.2 s 加速、0.8 s 衰减、停 0.6 s）；wheel = 普通鼠标滚轮一格一格（不连续，App 自己做平滑动画）
  static let modes = ["pixel", "flick", "wheel"]

  @Test func record() async throws {
    try #require(CGPreflightScreenCaptureAccess(), "要「屏幕录制」授权")
    let app = try #require(
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundle), "没装 \(Self.bundle)")
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    let wanted =
      (ProcessInfo.processInfo.environment["KITTY_LIVE_SCROLL_APP_DOCS"] ?? "doc,sheet,pdf")
      .split(separator: ",").map(String.init)
    for document in try Self.makeDocuments()
    where wanted.contains(where: { document.lastPathComponent.contains("-\($0).") }) {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      let running = try await NSWorkspace.shared.open(
        [document], withApplicationAt: app, configuration: configuration)
      try await Task.sleep(for: .seconds(6))
      let sheet = document.pathExtension == "csv"
      for region in sheet ? ["body"] : ["window", "body"] {
        for mode in sheet ? ["pixel", "wheel"] : Self.modes {
          try await capture(
            name: "\(document.deletingPathExtension().lastPathComponent)-\(region)-\(mode)",
            pid: running.processIdentifier, region: region, mode: mode)
        }
      }
    }
  }

  /// 一份长文档（标题、段落、列表、表格，转成 docx）、一张表格（CSV）和同一篇文档排成 A4 的 PDF，内容是随机拼的词
  static func makeDocuments() throws -> [URL] {
    let words = [
      "长截图", "拼接", "滚动", "选区", "预览", "文档", "表格", "段落", "标题", "列表", "the", "quick", "brown",
      "fox", "frame", "pixel", "window", "layout", "render", "capture", "stitch", "report", "季度",
    ]
    var generator = SystemRandomNumberGenerator()
    func sentence(_ count: Int) -> String {
      (0..<count).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
    }
    var html = "<html><head><meta charset='utf-8'></head><body>"
    for section in 0..<60 {
      html += "<h2>第 \(section) 节 \(sentence(3))</h2>"
      for _ in 0..<3 { html += "<p>\(sentence(40 + Int.random(in: 0..<40)))</p>" }
      html += "<ul>" + (0..<4).map { _ in "<li>\(sentence(8))</li>" }.joined() + "</ul>"
      if section % 3 == 0 {
        html += "<table border='1'>"
        for row in 0..<5 {
          html += "<tr>" + (0..<4).map { _ in "<td>\(row) \(sentence(2))</td>" }.joined() + "</tr>"
        }
        html += "</table>"
      }
    }
    html += "</body></html>"
    let source = directory.appending(path: "scroll-probe-doc.html")
    try html.write(to: source, atomically: true, encoding: .utf8)
    let docx = directory.appending(path: "scroll-probe-doc.docx")
    try? FileManager.default.removeItem(at: docx)
    let convert = Process()
    convert.executableURL = URL(filePath: "/usr/bin/textutil")
    convert.arguments = ["-convert", "docx", "-output", docx.path, source.path]
    try convert.run()
    convert.waitUntilExit()
    var csv = "编号,名称,类别,数量,单价,金额,日期,备注\n"
    for row in 1...600 {
      csv += "\(row),\(sentence(2)),\(words.randomElement()!),\(Int.random(in: 1..<999)),"
      csv += "\(Int.random(in: 1..<99)).\(Int.random(in: 10..<99)),\(Int.random(in: 100..<99999)),"
      csv += "2026-\(Int.random(in: 1...12))-\(Int.random(in: 1...28)),\(sentence(3))\n"
    }
    let sheet = directory.appending(path: "scroll-probe-sheet.csv")
    try csv.write(to: sheet, atomically: true, encoding: .utf8)
    let pdf = directory.appending(path: "scroll-probe-pdf.pdf")
    try makePDF(html: Data(html.utf8), to: pdf)
    return [docx, sheet, pdf]
  }

  /// 把 HTML 排成 A4（595 × 842 点、四边 56 点）多页 PDF：CoreText 一页一页地排
  static func makePDF(html: Data, to url: URL) throws {
    let text = try NSAttributedString(
      data: html, options: [.documentType: NSAttributedString.DocumentType.html],
      documentAttributes: nil)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    var start = 0
    while start < text.length {
      context.beginPDFPage(nil)
      let frame = CTFramesetterCreateFrame(
        framesetter, CFRange(location: start, length: 0),
        CGPath(rect: box.insetBy(dx: 56, dy: 56), transform: nil), nil)
      CTFrameDraw(frame, context)
      context.endPDFPage()
      let visible = CTFrameGetVisibleStringRange(frame).length
      guard visible > 0 else { break }
      start += visible
    }
    context.closePDF()
  }

  /// 只录不滚（TEST_RUNNER_KITTY_LIVE_SCROLL_APP_WATCH=<秒>）：用那个 App 打开生成的 PDF，录它最大那扇窗口，
  /// 画面变了才存一帧（带时刻），期间由用户自己在上面走一遍长截图——看框选遮罩盖上、拿掉的前后那个 App 画了什么
  /// （2026-11-26：WPS 的 PDF 长截图一开始第一帧就和之后的帧一张都对不上）
  @Test func watch() async throws {
    let seconds = try #require(
      ProcessInfo.processInfo.environment["KITTY_LIVE_SCROLL_APP_WATCH"].flatMap(Double.init))
    try #require(CGPreflightScreenCaptureAccess(), "要「屏幕录制」授权")
    let app = try #require(
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundle), "没装 \(Self.bundle)")
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    let pdf = try #require(Self.makeDocuments().first { $0.pathExtension == "pdf" })
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let running = try await NSWorkspace.shared.open(
      [pdf], withApplicationAt: app, configuration: configuration)
    try await Task.sleep(for: .seconds(3))
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let windows = content.windows.filter {
      $0.owningApplication?.processID == running.processIdentifier && $0.windowLayer == 0
    }
    let window = try #require(
      windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    let screen = try #require(NSScreen.screens.first)
    let scale = screen.backingScaleFactor
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let stream = SCStreamConfiguration()
    stream.width = Int(window.frame.width * scale)
    stream.height = Int(window.frame.height * scale)
    stream.showsCursor = false
    let folder = Self.directory.appending(path: "watch")
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    print("scroll-watch 开始录 \(Int(seconds)) 秒：\(Date())")
    var times: [Double] = []
    var last = 0
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
      guard
        let image = try? await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: stream),
        let data = image.dataProvider?.data as Data?
      else { continue }
      let hash = data.hashValue
      guard hash != last else { continue }
      last = hash
      let rowBytes = image.width * 4
      var pixels = Data(count: rowBytes * image.height)
      pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      }
      try pixels.write(to: folder.appending(path: String(format: "%04d.raw", times.count)))
      times.append(Date().timeIntervalSince1970)
    }
    let meta: [String: Any] = ["width": stream.width, "height": stream.height, "epoch": times]
    try JSONSerialization.data(withJSONObject: meta).write(to: folder.appending(path: "watch.json"))
    print("scroll-watch 存了 \(times.count) 帧")
  }

  /// 找那个 App 最大的普通窗口，按 region 取选区，按 mode 滚 6 秒、能截多快截多快，帧存进 <目录>/<name>/
  private func capture(name: String, pid: pid_t, region: String, mode: String) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let windows = content.windows.filter {
      $0.owningApplication?.processID == pid && $0.windowLayer == 0
    }
    let window = try #require(
      windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height },
      "\(Self.bundle) 没有窗口")
    let screen = try #require(NSScreen.screens.first)
    let display = try #require(content.displays.first { $0.displayID == screen.displayID })
    let primaryHeight = screen.frame.height
    let scale = screen.backingScaleFactor
    // CG 坐标（原点左上）的窗口框 → 选区
    var area = window.frame
    if region == "body" {
      area = CGRect(
        x: area.minX + area.width * 0.2, y: area.minY + 160, width: area.width * 0.6,
        height: area.height - 220)
    }
    let global = CGRect(
      x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
    let (_, source) = RegionSelector.captureRect(global, in: screen.frame, scale: scale)
    let filter = SCContentFilter(display: display, including: windows)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = source
    configuration.width = Int((source.width * scale).rounded())
    configuration.height = Int((source.height * scale).rounded())
    configuration.showsCursor = false
    let folder = Self.directory.appending(path: name)
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = CGPoint(x: area.midX, y: area.midY)
    // 滚轮和长截图自动滚动一样发到 HID 层、交给光标下的窗口（投给进程的 Qt 程序不理，2026-11-26 WPS 实测）
    CGWarpMouseCursorPosition(target)
    // 回到最上面
    for _ in 0..<40 { Self.post(lines: 30, at: target, pid: pid) }
    try await Task.sleep(for: .seconds(1.5))
    let start = Date()
    let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
      MainActor.assumeIsolated {
        let t = Date().timeIntervalSince(start)
        switch mode {
        case "pixel": Self.post(pixels: -10, at: target, pid: pid)  // 600 点每秒
        case "flick":
          let phase = t.truncatingRemainder(dividingBy: 1.6)
          let speed =
            phase < 0.2 ? 2500 * phase / 0.2 : phase < 1.0 ? 2500 * exp(-(phase - 0.2) * 5) : 0
          if speed > 30 { Self.post(pixels: -Int32(speed / 60), at: target, pid: pid) }
        default:
          // 一格一格：每 0.15 秒一格
          if Int(t * 60) % 9 == 0 { Self.post(lines: -1, at: target, pid: pid) }
        }
      }
    }
    RunLoop.main.add(ticker, forMode: .common)
    defer { ticker.invalidate() }
    var times: [Double] = []
    while Date().timeIntervalSince(start) < 6 {
      guard
        let image = try? await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: configuration)
      else { continue }
      let rowBytes = image.width * 4
      var pixels = Data(count: rowBytes * image.height)
      pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: rowBytes, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      }
      try pixels.write(to: folder.appending(path: String(format: "%04d.raw", times.count)))
      if times.isEmpty { FeedbackProbeTests.savePNG(image, folder.appending(path: "first.png")) }
      times.append(Date().timeIntervalSince(start))
      // 截一帧 + 算一帧在真会话里约 50 ms：间隔照这个来，帧也少存一些
      try await Task.sleep(for: .milliseconds(25))
    }
    let meta: [String: Any] = [
      "width": configuration.width, "height": configuration.height, "scale": scale, "times": times,
    ]
    try JSONSerialization.data(withJSONObject: meta).write(to: folder.appending(path: "meta.json"))
    print("scroll-app \(name): \(times.count) 帧 \(configuration.width)×\(configuration.height)")
  }

  /// 像素滚轮（连续的，同触控板；负数往下滚），交给光标下的窗口（point、pid 只留着对照）
  static func post(pixels: Int32, at point: CGPoint, pid: pid_t) {
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0,
        wheel3: 0)
    else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.post(tap: .cghidEventTap)
  }

  /// 鼠标滚轮一格（不连续；正数往上滚）
  static func post(lines: Int32, at point: CGPoint, pid: pid_t) {
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
        wheel3: 0)
    else { return }
    event.post(tap: .cghidEventTap)
  }

  /// 把存下的每一组帧用当前的 ScrollStitcher 拼一遍：每帧一个记号（接上的写位移像素，. 没动，L 对不上），
  /// 对不上的前后两帧另存 PNG（lost-N-ref / lost-N-new），另报每帧算帧、拼接的平均耗时（量要用 -O 构建）
  @Test func replay() async throws {
    let folders = try FileManager.default.contentsOfDirectory(
      at: Self.directory, includingPropertiesForKeys: nil
    ).filter { FileManager.default.fileExists(atPath: $0.appending(path: "meta.json").path) }
    for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let meta = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "meta.json")))
          as? [String: Any])
      let width = try #require(meta["width"] as? Int)
      let height = try #require(meta["height"] as? Int)
      let count = (meta["times"] as? [Double])?.count ?? 0
      func frame(_ index: Int) throws -> CGImage {
        let data = try Data(contentsOf: folder.appending(path: String(format: "%04d.raw", index)))
        return CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
              | CGBitmapInfo.byteOrder32Little.rawValue),
          provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
          intent: .defaultIntent)!
      }
      guard count > 1 else { continue }
      var reference = try frame(0)
      var stitcher = try #require(
        ScrollStitcher(first: reference, scrollbarWidth: 32, maxHeight: 200_000))
      var tags: [String] = []
      var lost = 0
      var prepare: Duration = .zero
      var stitch: Duration = .zero
      let clock = ContinuousClock()
      for index in 1..<count {
        let image = try frame(index)
        let start = clock.now
        let prepared = await ScrollStitcher.frame(image, layout: stitcher.layout)
        let middle = clock.now
        let outcome = stitcher.add(prepared)
        prepare += middle - start
        stitch += clock.now - middle
        switch outcome {
        case .moved:
          tags.append("\(stitcher.lastShift)")
          reference = image
        case .unchanged: tags.append(".")
        case .full: tags.append("F")
        case .lost:
          tags.append("L")
          lost += 1
          if lost <= 3 {
            print("scroll-lost \(folder.lastPathComponent) #\(index): \(stitcher.attempts)")
            FeedbackProbeTests.savePNG(reference, folder.appending(path: "lost-\(lost)-ref.png"))
            FeedbackProbeTests.savePNG(image, folder.appending(path: "lost-\(lost)-new.png"))
          }
        }
      }
      if let result = stitcher.makeImage() {
        FeedbackProbeTests.savePNG(result, folder.appending(path: "stitched.png"))
      }
      print(
        "scroll-replay \(folder.lastPathComponent): \(count) 帧、对不上 \(lost)、长图 \(stitcher.outputHeight) 像素、"
          + "每帧算帧 \(prepare / (count - 1))、拼接 \(stitch / (count - 1)) | "
          + tags.joined(separator: " "))
    }
  }
}
