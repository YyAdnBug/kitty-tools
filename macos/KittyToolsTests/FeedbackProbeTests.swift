// 两条用户反馈的按需实录探针（2026-11-12）：
// - recordingLag()：录屏一开始鼠标就延迟。整屏录制前后各发几秒合成的鼠标移动，量事件从发出到被分发（global 监听收到）
//   隔了多久、WindowServer 占多少 CPU、录制中换了几次过滤器；另看本 App 藏着的白名单窗口在不在 SCShareableContent 里。
// - scrollLive()：长截图选区大了常对不上。开一个真的 Chrome 窗口（独立的临时用户目录）铺满屏、放一篇长网页，整个窗口当选区，
//   照长截图会话的循环边截边滚（自动滚动、模拟手动一段一段地滚各一轮），记每帧的结果和耗时，对不上的那几帧存 PNG。
// 要「屏幕录制」和「辅助功能」授权；会录下整块主屏、移动鼠标、在主屏上开一个 Chrome 窗口滚动，跑时别碰键鼠。输出目录写绝对路径：
//   TEST_RUNNER_KITTY_LIVE_FEEDBACK_DIR=/tmp/kitty-feedback xcodebuild -project macos/KittyTools.xcodeproj \
//     -scheme KittyTools test '-only-testing:KittyToolsTests/FeedbackProbeTests/recordingLag()'
// 报告追加在 <输出目录>/report.md。
import AppKit
import ScreenCaptureKit
import Testing

@testable import KittyTools

nonisolated private let feedbackDirectory = ProcessInfo.processInfo.environment[
  "KITTY_LIVE_FEEDBACK_DIR"
].map { URL(filePath: $0, directoryHint: .isDirectory) }

@Suite(.serialized, .enabled(if: feedbackDirectory != nil))
@MainActor
struct FeedbackProbeTests {
  static var directory: URL { feedbackDirectory! }

  static func report(_ text: String) {
    print(text)
    let url = directory.appending(path: "report.md")
    let data = Data((text + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }

  // MARK: 录屏时鼠标

  /// 光标是不是画在帧缓冲里（软件光标）：CGCursorIsDrawnInFramebuffer 在 Swift 里标了不可用，按符号取
  static var softwareCursor: String {
    guard
      let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsDrawnInFramebuffer")
    else { return "取不到" }
    let call = unsafeBitCast(symbol, to: (@convention(c) () -> UInt32).self)
    return call() != 0 ? "是" : "否"
  }

  /// WindowServer 累计用了多少 CPU 秒（ps 的 TIME 列）
  static func windowServerSeconds() -> Double {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/ps")
    process.arguments = ["-axo", "time=,comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let line =
      String(decoding: data, as: UTF8.self).split(separator: "\n")
      .first { $0.hasSuffix("/WindowServer") } ?? ""
    let time = line.split(separator: " ").first.map(String.init) ?? "0:0"
    // [h:]m:s.xx
    return time.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
  }

  struct Lag {
    var latencies: [Double] = []
    /// 收到的时刻（相对开始量的那一刻，秒）
    var times: [Double] = []
    var cpu = 0.0
    /// 收到的相邻两个事件最长隔了多久（发的是每 16 ms 一个：卡住时这里会冒出来）、在第几秒
    var gap: (seconds: Double, at: Double) {
      zip(times, times.dropFirst()).map { ($1 - $0, $0) }.max { $0.0 < $1.0 } ?? (0, 0)
    }

    var summary: String {
      let sorted = latencies.sorted()
      func pick(_ q: Double) -> Double {
        sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 1000
      }
      return String(
        format:
          "收到 %d 个，延迟 p50 %.1f ms、p90 %.1f ms、最大 %.1f ms，相邻两个最长隔 %.0f ms（第 %.1f 秒）；WindowServer CPU %.0f%%",
        sorted.count, pick(0.5), pick(0.9), pick(1), gap.seconds * 1000, gap.at, cpu * 100)
    }
  }

  /// seconds 秒里每 1/60 秒发一个合成的鼠标移动（光标在 center 附近转小圈），量 global 监听收到它时比事件时刻晚多少
  static func measureLag(
    seconds: Double, center: CGPoint, at moment: Double = .infinity, _ action: () -> Void = {}
  ) async -> Lag {
    var lag = Lag()
    let begin = ProcessInfo.processInfo.systemUptime
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
      let now = ProcessInfo.processInfo.systemUptime
      MainActor.assumeIsolated {
        lag.latencies.append(now - event.timestamp)
        lag.times.append(now - begin)
      }
    }
    var acted = false
    defer { monitor.map(NSEvent.removeMonitor) }
    let cpu0 = windowServerSeconds()
    let start = Date()
    var step = 0
    while Date().timeIntervalSince(start) < seconds {
      if !acted, Date().timeIntervalSince(start) >= moment {
        acted = true
        action()
      }
      let angle = Double(step) * 0.2
      let point = CGPoint(x: center.x + 60 * cos(angle), y: center.y + 60 * sin(angle))
      CGEvent(
        mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
        mouseButton: .left)?.post(tap: .cghidEventTap)
      step += 1
      try? await Task.sleep(for: .milliseconds(16))
    }
    try? await Task.sleep(for: .milliseconds(300))
    lag.cpu = (windowServerSeconds() - cpu0) / Date().timeIntervalSince(start)
    return lag
  }

  @Test func recordingLag() async throws {
    try #require(CGPreflightScreenCaptureAccess(), "要「屏幕录制」授权")
    try #require(Permissions.isAccessibilityTrusted, "要「辅助功能」授权（发合成鼠标事件）")
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    let screen = try #require(NSScreen.screens.first)
    let primaryHeight = screen.frame.height
    let center = CGPoint(x: screen.frame.midX, y: primaryHeight - screen.frame.midY)
    Self.report(
      "\n## 录屏时鼠标（\(Date.now.formatted())，macOS \(ProcessInfo.processInfo.operatingSystemVersionString)）\n"
        + "主屏 \(Int(screen.frame.width)) × \(Int(screen.frame.height)) 点 @\(screen.backingScaleFactor)x"
    )
    // 本 App 藏着的白名单窗口（真 App 里剪贴板、启动器、翻译这些面板平时都藏着）：一扇显示过又收起、一扇建了没显示过
    let shownThenHidden = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 200, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    shownThenHidden.isReleasedWhenClosed = false
    shownThenHidden.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(200))
    shownThenHidden.orderOut(nil)
    let neverShown = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 200, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    neverShown.isReleasedWhenClosed = false
    defer {
      shownThenHidden.close()
      neverShown.close()
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    let listed = Set(content.windows.map(\.windowID))
    let whitelisted = ScreenCapture.recordedOwnWindows(ScreenCapture.ownWindows())
    Self.report(
      "- 白名单窗口 \(whitelisted.count) 扇，其中不在 SCShareableContent 里的 \(whitelisted.subtracting(listed).count) 扇"
        + "（显示过又收起的：\(ScreenCapture.windowID(shownThenHidden.windowNumber).map(listed.contains) ?? false ? "在" : "不在")；"
        + "没显示过的：窗口号 \(neverShown.windowNumber)、\(ScreenCapture.windowID(neverShown.windowNumber).map(listed.contains) ?? false ? "在" : "不在")）"
    )
    // 系统自带的录屏（screencapture -v；-C 带光标）开着时是不是也换成软件光标：对照
    for flags in [["-C"], []] {
      let file = Self.directory.appending(path: "system.mov")
      let process = Process()
      process.executableURL = URL(filePath: "/usr/sbin/screencapture")
      process.arguments = ["-v", "-x"] + flags + ["-V", "3", file.path]
      try process.run()
      try await Task.sleep(for: .seconds(2))
      let software = Self.softwareCursor
      process.waitUntilExit()
      Self.report(
        "- 系统录屏 screencapture -v \(flags.joined())：录制中软件光标 \(software)，"
          + "文件\(FileManager.default.fileExists(atPath: file.path) ? "有" : "没有")")
      try? FileManager.default.removeItem(at: file)
    }
    let before = await Self.measureLag(seconds: 5, center: center)
    Self.report("- 开录前：\(before.summary)；软件光标：\(Self.softwareCursor)")
    for (rate, countdown, cursor) in [(30, 0, true), (30, 0, false)] {
      let suite = "kitty-test-feedback-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(countdown, forKey: Prefs.screenRecordCountdown)
      defaults.set(rate, forKey: Prefs.screenRecordFrameRate)
      defaults.set(cursor, forKey: Prefs.screenRecordShowsCursor)
      let folder = Self.directory.appending(path: "recording-\(rate)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var finished: ScreenRecorder.Result?
      let recorder = try #require(
        ScreenRecorder(region: screen.frame, directory: folder, defaults: defaults) {
          finished = $0
        })
      let starting = await Self.measureLag(seconds: 5 + Double(countdown), center: center, at: 1) {
        recorder.start()
      }
      Self.report(
        "- 第 1 秒开录、量 5 秒（\(rate) fps、整屏、\(cursor ? "录光标" : "不录光标")、系统声音、倒数 \(countdown) 秒）：\(starting.summary)"
      )
      let during = await Self.measureLag(seconds: 6, center: center)
      Self.report(
        "- 录制中：\(during.summary)；换过滤器 \(recorder.filterRefreshes) 次；光标画在帧缓冲里（软件光标）："
          + "\(Self.softwareCursor)")
      let stopping = await Self.measureLag(seconds: 3, center: center, at: 1) { recorder.stop() }
      Self.report("- 第 1 秒停录、量 3 秒：\(stopping.summary)")
      for _ in 0..<200 where finished == nil { try await Task.sleep(for: .milliseconds(50)) }
      if let file = finished?.file { try? FileManager.default.removeItem(at: file) }
      try? FileManager.default.removeItem(at: folder)
    }
  }

  // MARK: 长截图大选区

  @Test func scrollLive() async throws {
    try #require(CGPreflightScreenCaptureAccess(), "要「屏幕录制」授权")
    try #require(Permissions.isAccessibilityTrusted, "要「辅助功能」授权（发合成滚轮）")
    let folder = Self.directory.appending(path: "scroll")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let screen = try #require(NSScreen.screens.first)
    let page = folder.appending(path: "long.html")
    try Self.longPage.write(to: page, atomically: true, encoding: .utf8)
    let visible = screen.visibleFrame
    let primaryHeight = screen.frame.height
    let chrome = Process()
    chrome.executableURL = URL(
      filePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    chrome.arguments = [
      "--user-data-dir=\(folder.appending(path: "profile").path)", "--no-first-run",
      "--no-default-browser-check", "--disable-features=Translate",
      "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
      "--remote-debugging-port=9557",
      "--window-position=\(Int(visible.minX)),\(Int(primaryHeight - visible.maxY))",
      "--window-size=\(Int(visible.width)),\(Int(visible.height))", "--new-window",
      page.absoluteString,
    ]
    chrome.standardError = FileHandle.nullDevice
    // 测试宿主的环境里有注入测试用的 DYLD_* 变量，别带给 Chrome
    chrome.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    try chrome.run()
    defer { chrome.terminate() }
    // Chrome 的窗口（CG 坐标，左上原点）→ AppKit 全局坐标；整个窗口就是选区（大选区）
    var infos: [[String: Any]] = []
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(250))
      infos =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
      if infos.contains(where: {
        ($0[kCGWindowOwnerPID as String] as? pid_t) == chrome.processIdentifier
          && ($0[kCGWindowLayer as String] as? Int) == 0
      }) {
        break
      }
    }
    try await Task.sleep(for: .seconds(2))
    infos =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let bounds = try #require(
      infos.filter {
        ($0[kCGWindowOwnerPID as String] as? pid_t) == chrome.processIdentifier
          && ($0[kCGWindowLayer as String] as? Int) == 0
      }.compactMap { info -> CGRect? in
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap {
          CGRect(dictionaryRepresentation: $0 as CFDictionary)
        }
      }.max { $0.width * $0.height < $1.width * $1.height }, "没找到 Chrome 的窗口")
    try await Self.connectDevTools(port: 9557)
    let window = CGRect(
      x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    // 去掉标签栏和地址栏那一截（约 90 点）也照样是大选区；两种都跑
    for (name, region) in [
      ("整个窗口", window), ("网页部分", window.divided(atDistance: 88, from: .maxYEdge).remainder),
    ] {
      for mode in ["auto", "manual"] {
        try await run(
          mode: mode, name: name, region: region, screen: screen, folder: folder,
          chrome: chrome.processIdentifier)
      }
    }
  }

  /// 只录帧序列（不拼）：模拟手在触控板上一甩一甩地滚（加速 0.25 s 到峰值、惯性衰减约 1 s、停 1 s，峰值轮着
  /// 1500 / 3000 / 5000 点每秒），能截多快截多快，每帧原样存成 BGRA 裸数据 + 时刻，留给离线按 Release 的耗时回放
  @Test func scrollFrames() async throws {
    try #require(CGPreflightScreenCaptureAccess(), "要「屏幕录制」授权")
    let folder = Self.directory.appending(path: "frames")
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let screen = try #require(NSScreen.screens.first)
    let page = Self.directory.appending(path: "long.html")
    try Self.longPage.write(to: page, atomically: true, encoding: .utf8)
    let visible = screen.visibleFrame
    let primaryHeight = screen.frame.height
    let chrome = Process()
    chrome.executableURL = URL(
      filePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    chrome.arguments = [
      "--user-data-dir=\(Self.directory.appending(path: "profile").path)", "--no-first-run",
      "--no-default-browser-check", "--disable-features=Translate",
      "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
      "--remote-debugging-port=9557",
      "--window-position=\(Int(visible.minX)),\(Int(primaryHeight - visible.maxY))",
      "--window-size=\(Int(visible.width)),\(Int(visible.height))", "--new-window",
      page.absoluteString,
    ]
    chrome.standardError = FileHandle.nullDevice
    chrome.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    try chrome.run()
    defer { chrome.terminate() }
    try await Self.connectDevTools(port: 9557)
    try await Task.sleep(for: .seconds(3))
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    let windows = content.windows.filter {
      $0.owningApplication?.processID == chrome.processIdentifier && $0.windowLayer == 0
    }
    let window = try #require(
      windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    let display = try #require(content.displays.first { $0.displayID == screen.displayID })
    let scale = screen.backingScaleFactor
    // 选区 = 整个 Chrome 窗口（SCWindow.frame 是 CG 坐标、点）
    let region = CGRect(
      x: window.frame.minX, y: primaryHeight - window.frame.maxY, width: window.frame.width,
      height: window.frame.height)
    let (_, source) = RegionSelector.captureRect(region, in: screen.frame, scale: scale)
    var filter = SCContentFilter(display: display, including: [window])
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = source
    configuration.width = Int((source.width * scale).rounded())
    configuration.height = Int((source.height * scale).rounded())
    configuration.showsCursor = false
    Self.scroll(-200_000)
    try await Task.sleep(for: .seconds(1))
    let start = Date()
    let peaks: [CGFloat] = [1500, 3000, 5000]
    let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
      MainActor.assumeIsolated {
        let t = Date().timeIntervalSince(start)
        let cycle = 2.4
        let phase = t.truncatingRemainder(dividingBy: cycle)
        let peak = peaks[Int(t / cycle) % peaks.count]
        let speed: CGFloat =
          phase < 0.25 ? peak * phase / 0.25 : phase < 1.4 ? peak * exp(-(phase - 0.25) * 4) : 0
        if speed > 1 { Self.scroll(speed / 60) }
      }
    }
    RunLoop.main.add(ticker, forMode: .common)
    defer { ticker.invalidate() }
    var times: [Double] = []
    while Date().timeIntervalSince(start) < 14.4 {
      let t = Date().timeIntervalSince(start)
      // 偶尔报 CoreGraphicsErrorDomain 1004（窗口表变了）：重取一次过滤器接着截
      guard
        let image = try? await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: configuration)
      else {
        let fresh = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        if let same = fresh.windows.first(where: { $0.windowID == window.windowID }) {
          filter = SCContentFilter(display: display, including: [same])
        }
        continue
      }
      // 原样画进 BGRA 预乘（同 ScrollStitcher 的排列）存成裸数据
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
      times.append(t)
      if times.count == 1 {
        Self.report(
          "\n### 长截图帧序列：\(image.width) × \(image.height) 像素，窗口 \(Int(region.width)) × \(Int(region.height)) 点"
        )
      }
    }
    let meta = ["width": configuration.width, "height": configuration.height] as [String: Any]
    try JSONSerialization.data(withJSONObject: meta.merging(["times": times]) { $1 }).write(
      to: folder.appending(path: "meta.json"))
    Self.report("录了 \(times.count) 帧（平均每 \(Int(14.4 / Double(times.count) * 1000)) ms 一帧）")
  }

  /// 照 ScrollCapture 的循环跑一轮：auto 照自动滚动的那套（ScrollCapture 的纯函数）；manual 模拟手：
  /// 0.6 s 一段匀速滚（速度轮着 600 / 1200 / 2400 点每秒）、停 0.8 s
  /// chrome：滚轮直接投给它（屏幕上盖着状态屏这类拦输入的东西时，发到 HID 层的会被拦掉），截图只收它的窗口
  private func run(
    mode: String, name: String, region: CGRect, screen: NSScreen, folder: URL, chrome: pid_t
  ) async throws {
    Self.target = chrome
    let scale = screen.backingScaleFactor
    let primaryHeight = screen.frame.height
    // 回到顶上
    Self.scroll(-200_000)
    try await Task.sleep(for: .seconds(1))
    let (snapped, source) = RegionSelector.captureRect(region, in: screen.frame, scale: scale)
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    let display = try #require(content.displays.first { $0.displayID == screen.displayID })
    // 只收 Chrome 的窗口（选区里别的东西——盖在上面的状态屏——不进画面）
    let filter = SCContentFilter(
      display: display,
      including: content.windows.filter { $0.owningApplication?.processID == chrome })
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = source
    configuration.width = Int((source.width * scale).rounded())
    configuration.height = Int((source.height * scale).rounded())
    configuration.showsCursor = false
    var image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    var stitcher = try #require(
      ScrollStitcher(first: image, scrollbarWidth: Int(16 * scale), maxHeight: 60_000))
    var referenceImage = image
    // 滚轮：自动滚动照 ScrollCapture 的公式，每 1/60 秒一 tick；手动按段
    var posted: CGFloat = 0
    var postedAtCapture: CGFloat = 0
    var postedAtReference: CGFloat = 0
    var gain = scale
    var velocity = ScrollCapture.velocity(
      speed: .normal, height: snapped.height, scale: scale, gain: gain)
    var carry: CGFloat = 0
    let start = Date()
    let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
      MainActor.assumeIsolated {
        let t = Date().timeIntervalSince(start)
        var points: CGFloat = 0
        if mode == "auto" {
          let next = ScrollCapture.tickPoints(
            velocity: velocity, seconds: 1.0 / 60, carry: carry,
            room: ScrollCapture.room(
              lead: posted - postedAtReference, height: snapped.height, scale: scale, gain: gain))
          carry = next.carry
          points = next.points
        } else {
          let cycle = t.truncatingRemainder(dividingBy: 1.4)
          let speeds: [CGFloat] = [600, 1200, 2400]
          if cycle < 0.6 { points = speeds[Int(t / 1.4) % 3] / 60 }
        }
        if points != 0 {
          posted += points
          Self.scroll(points)
        }
      }
    }
    RunLoop.main.add(ticker, forMode: .common)
    defer { ticker.invalidate() }
    var tags: [String] = []
    var timings: [(capture: Double, frame: Double, add: Double)] = []
    var shifts: [Int] = []
    var lostSaved = 0
    var quiet = 0
    var lostStreak = 0
    let duration: Double = mode == "auto" ? 14 : 13
    while Date().timeIntervalSince(start) < duration {
      postedAtCapture = posted
      let t0 = Date()
      image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
      let t1 = Date()
      let frame = await ScrollStitcher.frame(image, layout: stitcher.layout)
      let t2 = Date()
      let outcome = stitcher.add(frame)
      let t3 = Date()
      timings.append(
        (t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t3.timeIntervalSince(t2)))
      quiet = outcome == .unchanged ? quiet + 1 : 0
      switch outcome {
      case .moved:
        lostStreak = 0
        shifts.append(stitcher.lastShift)
        tags.append("\(stitcher.lastShift * 100 / stitcher.height)")
        if mode == "auto" {
          let sent = postedAtCapture - postedAtReference
          gain = ScrollCapture.calibrated(
            gain, shift: CGFloat(stitcher.lastShift), sent: sent, scale: scale)
          velocity = ScrollCapture.velocity(
            speed: .normal, height: snapped.height, scale: scale, gain: gain)
        }
        postedAtReference = postedAtCapture
        referenceImage = image
      case .lost:
        tags.append("L")
        if lostSaved < 4 {
          lostSaved += 1
          Self.savePNG(
            referenceImage, folder.appending(path: "\(name)-\(mode)-lost\(lostSaved)-ref.png"))
          Self.savePNG(image, folder.appending(path: "\(name)-\(mode)-lost\(lostSaved)-new.png"))
        }
        lostStreak += 1
        if mode == "auto" {
          if lostStreak >= 4 {
            tags.append("停")
            break
          }
          let back = ((posted - postedAtReference) / 2).rounded()
          if back > 0 {
            posted -= back
            Self.scroll(-back)
          }
          velocity /= 2
        }
      case .unchanged:
        tags.append(".")
        if tags.count == 3 {
          Self.savePNG(image, folder.appending(path: "\(name)-\(mode)-still.png"))
        }
      case .full: tags.append("F")
      }
      if mode == "auto", lostStreak >= 4 { break }
      if let interval = ScrollCapture.interval(isAutoScrolling: mode == "auto", quietFrames: quiet)
      {
        try await Task.sleep(for: interval)
      }
    }
    ticker.invalidate()
    func average(_ values: [Double]) -> Double {
      values.reduce(0, +) / Double(max(values.count, 1)) * 1000
    }
    let lost = tags.count { $0 == "L" }
    Self.report(
      "\n### 长截图实录 · \(name) · \(mode == "auto" ? "自动滚动（标准档）" : "模拟手动")\n"
        + "选区 \(Int(snapped.width)) × \(Int(snapped.height)) 点、帧 \(stitcher.width) × \(stitcher.height) 像素；"
        + "\(tags.count) 帧、对不上 \(lost) 帧、长图 \(stitcher.outputHeight) 像素、最大位移 \(shifts.map(abs).max() ?? 0) 像素\n"
        + String(
          format: "截一张平均 %.0f ms（最长 %.0f）、算帧 %.0f ms、拼接 %.0f ms（最长 %.0f）\n",
          average(timings.map(\.capture)), (timings.map(\.capture).max() ?? 0) * 1000,
          average(timings.map(\.frame)), average(timings.map(\.add)),
          (timings.map(\.add).max() ?? 0) * 1000)
        + "每帧（接上的写位移占帧高的百分比）：" + tags.joined(separator: " "))
  }

  static var target: pid_t = 0
  /// 滚轮落在页面里哪（CSS 像素，视口内）
  static var location = CGPoint(x: 700, y: 400)
  static var devTools: URLSessionWebSocketTask?
  static var nextID = 0

  /// 连上 Chrome 的页面（DevTools 协议）：滚轮走 Input.dispatchMouseEvent，和真的滚轮一样进 Chrome 的合成器
  /// （屏幕上盖着状态屏这类拦输入的东西时，系统层的合成滚轮到不了 Chrome）
  static func connectDevTools(port: Int) async throws {
    for _ in 0..<40 {
      if let (data, _) = try? await URLSession.shared.data(
        from: URL(string: "http://127.0.0.1:\(port)/json/list")!),
        let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        let page = list.first(where: { $0["type"] as? String == "page" }),
        let url = (page["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:))
      {
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        devTools = socket
        // 收掉回包（不看）
        Task {
          while (try? await socket.receive()) != nil {}
        }
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    Issue.record("连不上 Chrome 的 DevTools")
  }

  /// 像素级的滚轮，正数往下滚（点 = CSS 像素）
  static func scroll(_ points: CGFloat) {
    guard let devTools else { return }
    nextID += 1
    let message: [String: Any] = [
      "id": nextID, "method": "Input.dispatchMouseEvent",
      "params": [
        "type": "mouseWheel", "x": location.x, "y": location.y, "deltaX": 0,
        "deltaY": Double(points),
      ],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    devTools.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
  }

  static func savePNG(_ image: CGImage, _ url: URL) {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
  }

  /// 一篇很长的文档页：顶栏、左边固定的目录、正文（标题、段落、代码块、列表、表格），够滚 15 秒
  static var longPage: String {
    let words = [
      "长截图", "拼接", "滚动", "选区", "预览", "the", "quick", "brown", "fox", "frame", "pixel",
      "window", "layout", "配置", "函数", "变量", "文档", "render", "capture", "stitch",
    ]
    var generator = SystemRandomNumberGenerator()
    func sentence(_ count: Int) -> String {
      (0..<count).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
    }
    var main = ""
    for section in 0..<220 {
      main += "<h2>第 \(section) 节 \(sentence(3))</h2>"
      for _ in 0..<3 { main += "<p>\(sentence(60))</p>" }
      if section % 3 == 0 {
        main +=
          "<pre>\((0..<6).map { _ in "let x = \(sentence(5))" }.joined(separator: "\n"))</pre>"
      }
      if section % 4 == 1 {
        main += "<ul>\((0..<4).map { _ in "<li>\(sentence(8))</li>" }.joined())</ul>"
      }
      if section % 5 == 2 {
        main +=
          "<table>\((0..<5).map { r in "<tr><td>\(r)</td><td>\(sentence(4))</td><td>\(sentence(3))</td></tr>" }.joined())</table>"
      }
    }
    let nav = (0..<80).map { "<div>第 \($0) 节 \(sentence(1))</div>" }.joined()
    return """
      <!doctype html><html><head><meta charset="utf-8"><style>
      body{margin:0;background:#fff;font:15px/1.65 -apple-system,"PingFang SC",sans-serif;color:#1d1d1f}
      .top{position:fixed;top:0;left:0;right:0;height:52px;background:#f5f5f7;border-bottom:1px solid #ddd;font-weight:600;line-height:52px;padding-left:20px;z-index:2}
      .nav{position:fixed;top:53px;left:0;bottom:0;width:240px;background:#fafafa;border-right:1px solid #e5e5e5;font-size:13px;line-height:2;padding:10px 16px;overflow:hidden;color:#444}
      .main{margin-left:280px;max-width:900px;padding:70px 30px 80px}
      pre{background:#f6f8fa;border-radius:6px;padding:12px;font:13px/1.5 Menlo,monospace}
      td{border:1px solid #ddd;padding:4px 8px}
      </style></head><body><div class="top">开发者文档 · 长截图实录页</div><div class="nav">\(nav)</div><div class="main">\(main)</div></body></html>
      """
  }
}
