import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing

@testable import KittyTools

// 界面卡顿与玻璃观感的量测探针（2026-11-23「UI 更美、少卡顿」那一轮，PLAN §10「美化与提速」；按需开，平时不跑）。
// 前后对比用同一种构建（优化构建：命令行加 SWIFT_OPTIMIZATION_LEVEL=-O）：
//   TEST_RUNNER_KITTY_POLISH_PROBE=<输出目录> xcodebuild … test SWIFT_OPTIMIZATION_LEVEL=-O \
//     -only-testing:'KittyToolsTests/PolishProbeTests/measure()'
// 报告追加在 <目录>/report.md。另加 TEST_RUNNER_KITTY_POLISH_PROBE_ONSCREEN=1：面板摆在主屏右上角（透明度 0.05、不接鼠标、
// 不当 key，同 MemoryProbeTests），系统真的画图层；不加就摆在屏外。量的都是主线程：
//   - 同步那一下：改状态 → layoutSubtreeIfNeeded → displayIfNeeded → CATransaction.flush（「其中改 xx」是改模型本身）
//   - 之后一小段里跑环每一轮忙了多久（CFRunLoopObserver：醒来 → 要睡之间，含 CA 提交），记合计和最长一下
// 场景：启动器（呼出、打字、↓）、剪贴板（5000 / 300 条：呼出、↑↓、只换透镜不滚动的 ↓↑、滚动、打字搜）、翻译浮窗（出结果、三张卡流式出字）、
// 设置窗（每页第一次 / 第二次打开）。偏好用临时域，库在内存里，图片在临时目录。
// 要看主线程忙在哪：另加 TEST_RUNNER_KITTY_POLISH_LOOP=clip-down / clip-swap / clip-search / clip-narrow / clip-scroll / launcher-type / settings /
// translate-wait（三张卡等结果）/ translate-stream（经协调器的流一轮接一轮），
// 只把那一件来回做 10 秒，pid 写在 <目录>/pid，这时 `sample <pid> 7`。
// 只量其中几块：TEST_RUNNER_KITTY_POLISH_ONLY=launcher,clip,translate,settings,files（逗号隔开）。files = 启动器文件搜索真查本机
// Spotlight（2026-11-24「.xl」卡顿；逐字打删「␣.xlsx」「open .xlsx」「␣report」，_LOOP=files-type 给 sample）。
// 翻译浮窗屏外量时另加 TEST_RUNNER_KITTY_POLISH_ANIMATE=always / lines：改高度照真 App 带动画（always：变化 8 pt 以上就带；
// lines：有卡在出字时不带），看流式时窗口高度动画的开销（屏上的面板透明度 0.05，本来就不做高度动画）。
// 第一次呼出预排过的（P7，OverlayPanel.prewarm）：另加 TEST_RUNNER_KITTY_POLISH_PREWARM=1（再屏外画一遍：=display），启动器、剪贴板
// 面板建好后先预排、闲 1 秒再量第一次呼出，报告里多一行预排花了多久、phys_footprint 多了多少；和不加的那一遍对比。
// capture()：ScreenCapture.freeze() 连做 6 次各多久（要「屏幕录制」授权，只在内存里截、不存图）。
// glass()：屏上真玻璃（屏外截图画不出玻璃）——三块主面板各摆在一扇背景窗口上，两扇都放在所有窗口后面（屏幕左下角，
// 不当 key），ScreenCaptureKit 只合成这两扇抓出来，图在 <目录>/glass/。要 TEST_RUNNER_KITTY_POLISH_GLASS=1；
// TEST_RUNNER_KITTY_POLISH_GLASS_TINT=0（「透明」，系统默认）/ 1（「着色」）在本进程的参数域里临时覆盖、不写盘——
// 开发机设的是「着色」，验玻璃一定两档都看；_GLASS_KINDS（clipboard,launcher,translate,clipboard-actions,
// clipboard-scrolled,launcher-actions）、_GLASS_BACKGROUNDS（page,wallpaper）挑一部分。

struct PolishProbeTests {
  nonisolated static let directory = ProcessInfo.processInfo.environment["KITTY_POLISH_PROBE"]

  @Test(.enabled(if: directory != nil)) func measure() async throws {
    let failure: String? = await withCheckedContinuation { continuation in
      RunLoop.main.perform {
        MainActor.assumeIsolated {
          do {
            try PolishProbe().run()
            continuation.resume(returning: nil)
          } catch {
            continuation.resume(returning: "\(error)")
          }
        }
      }
    }
    #expect(failure == nil)
  }

  @Test(.enabled(if: directory != nil)) func capture() async throws {
    guard CGPreflightScreenCaptureAccess() else {
      PolishProbe.log("capture: 没有屏幕录制授权，跳过")
      return
    }
    var times: [Double] = []
    for _ in 0..<6 {
      let start = CACurrentMediaTime()
      let shots = try await ScreenCapture.freeze()
      times.append((CACurrentMediaTime() - start) * 1000)
      _ = shots.count
    }
    PolishProbe.log(
      "capture: ScreenCapture.freeze() 每次 \(PolishProbe.list(times)) ms（\(NSScreen.screens.count) 块屏）"
    )
  }
  /// 屏上真玻璃（macOS 26 起的主路径；屏外 layer.render 画不出玻璃）：三块主面板各摆在一扇背景窗口上面，两扇都放在所有窗口后面
  /// （屏幕左下角，不当 key），ScreenCaptureKit 只合成这两扇抓出来。背景两种（浅色网页 / 彩色壁纸样），浅深色各一。
  /// TEST_RUNNER_KITTY_POLISH_GLASS_TINT=0（透明，系统默认）/ 1（着色）在本进程的参数域里临时覆盖，不写盘
  @MainActor
  @Test(
    .enabled(
      if: directory != nil && ProcessInfo.processInfo.environment["KITTY_POLISH_GLASS"] != nil))
  func glass() async throws {
    let out = try #require(Self.directory) + "/glass"
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let tint = ProcessInfo.processInfo.environment["KITTY_POLISH_GLASS_TINT"] ?? "0"
    let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var merged = arguments
    merged["NSGlassTintAmount"] = Double(tint) ?? 0
    UserDefaults.standard.setVolatileDomain(merged, forName: UserDefaults.argumentDomain)
    defer {
      UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    let probe = PolishProbe()
    let suite = "kitty-polish-glass-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    let saved = (SiteIcons.shared.roots, ServiceIcons.shared.directory, ServiceIcons.shared.fetch)
    defer {
      (SiteIcons.shared.roots, ServiceIcons.shared.directory, ServiceIcons.shared.fetch) = saved
    }
    SiteIcons.shared.roots = { [] }
    ServiceIcons.shared.fetch = { _ in nil }
    let screen = try #require(NSScreen.main)
    let size = CGSize(width: 980, height: 720)
    let origin = NSPoint(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.minY + 10)
    let kinds =
      ProcessInfo.processInfo.environment["KITTY_POLISH_GLASS_KINDS"]?.split(separator: ",").map(
        String.init)
      ?? ["clipboard", "launcher", "translate"]
    let backgrounds =
      ProcessInfo.processInfo.environment["KITTY_POLISH_GLASS_BACKGROUNDS"]?.split(separator: ",")
      .map(String.init)
      ?? ["page", "wallpaper"]
    for background in backgrounds {
      let image = try PolishProbe.backdrop(background, size: size)
      for dark in [false, true] {
        for kind in kinds {
          let bg = NSWindow(
            contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
          bg.isReleasedWhenClosed = false
          bg.hasShadow = false
          let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
          imageView.image = NSImage(cgImage: image, size: size)
          imageView.imageScaling = .scaleAxesIndependently
          bg.contentView = imageView
          bg.orderBack(nil)
          let panel = try probe.makePanel(kind, prefs: prefs)
          panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
          panel.level = .normal
          panel.ignoresMouseEvents = true
          panel.setFrameTopLeftPoint(
            NSPoint(
              x: origin.x + (size.width - panel.frame.width) / 2, y: origin.y + size.height - 60))
          panel.alphaValue = 1
          panel.order(.above, relativeTo: bg.windowNumber)
          try? await Task.sleep(for: .milliseconds(600))
          if kind.hasSuffix("scrolled"), let list = probe.lists(in: panel.contentView).first {
            list.contentView.scroll(to: NSPoint(x: 0, y: 330))
            list.reflectScrolledClipView(list.contentView)
          }
          try? await Task.sleep(for: .milliseconds(900))
          let shareable = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
          let windows = shareable.windows.filter {
            $0.windowID == CGWindowID(bg.windowNumber)
              || $0.windowID == CGWindowID(panel.windowNumber)
          }
          let display = try #require(
            shareable.displays.first {
              $0.displayID
                == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                  as? CGDirectDisplayID)
            } ?? shareable.displays.first)
          let config = SCStreamConfiguration()
          let flipped = CGRect(
            x: origin.x - screen.frame.minX, y: screen.frame.maxY - origin.y - size.height,
            width: size.width, height: size.height)
          config.sourceRect = flipped
          config.width = Int(size.width * 2)
          config.height = Int(size.height * 2)
          config.showsCursor = false
          let shot = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, including: windows),
            configuration: config)
          let name = "\(kind)-\(background)-\(dark ? "dark" : "light")-tint\(tint).png"
          try #require(NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:]))
            .write(to: URL(filePath: "\(out)/\(name)"))
          panel.orderOut(nil)
          bg.orderOut(nil)
          try? await Task.sleep(for: .milliseconds(200))
        }
      }
    }
  }
}

/// 跑环每一轮忙了多久（醒来 → 要睡）
@MainActor private final class LoopMeter {
  private var observer: CFRunLoopObserver?
  private var woke: CFTimeInterval = 0
  private(set) var slices: [Double] = []

  func start() {
    slices = []
    woke = CACurrentMediaTime()
    let early = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.woke = CACurrentMediaTime() }
    }
    let late = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
    ) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.slices.append((CACurrentMediaTime() - self.woke) * 1000)
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), early, .commonModes)
    CFRunLoopAddObserver(CFRunLoopGetMain(), late, .commonModes)
    observer = late
    extra = early
  }
  private var extra: CFRunLoopObserver?

  func stop() {
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    if let extra { CFRunLoopRemoveObserver(CFRunLoopGetMain(), extra, .commonModes) }
    observer = nil
    extra = nil
  }
}

@MainActor final class PolishProbe {
  nonisolated static let onscreen =
    ProcessInfo.processInfo.environment["KITTY_POLISH_PROBE_ONSCREEN"] == "1"
  /// 给 sample 用：只把这一件来回做 10 秒（clip-down / clip-search / clip-scroll / launcher-type / settings / settings-pair / translate-wait / translate-stream），
  /// pid 写进 <目录>/pid
  nonisolated static let loop = ProcessInfo.processInfo.environment["KITTY_POLISH_LOOP"]
  /// 翻译浮窗改高度带不带动画（量真 App 的高度动画用，只在屏外有效）：always / lines，见 translate()
  nonisolated static let animate = ProcessInfo.processInfo.environment["KITTY_POLISH_ANIMATE"]

  private func looping(_ name: String, _ step: (Int) -> Void) -> Bool {
    guard Self.loop == name else { return false }
    let directory = PolishProbeTests.directory!
    try? "\(getpid())".write(toFile: directory + "/pid", atomically: true, encoding: .utf8)
    spin(2)
    let end = CACurrentMediaTime() + 10
    var index = 0
    while CACurrentMediaTime() < end {
      step(index)
      index += 1
      spin(0.016)
    }
    try? FileManager.default.removeItem(atPath: directory + "/pid")
    return true
  }

  /// 同上，整段自己做：whole 收到该停的时刻（翻译的流一轮要等它出完，不是每 16 ms 一步）
  private func looping(_ name: String, whole: (CFTimeInterval) -> Void) -> Bool {
    guard Self.loop == name else { return false }
    let directory = PolishProbeTests.directory!
    try? "\(getpid())".write(toFile: directory + "/pid", atomically: true, encoding: .utf8)
    spin(2)
    whole(CACurrentMediaTime() + 10)
    try? FileManager.default.removeItem(atPath: directory + "/pid")
    return true
  }
  private let suite = "kitty-polish-probe-\(UUID().uuidString)"
  private let scratch = FileManager.default.temporaryDirectory.appending(
    path: "kitty-polish-probe-\(UUID().uuidString)")
  private let meter = LoopMeter()
  /// settle 里 work() 本身（改模型，不含排版画图）用了多久
  private var lastWork = 0.0
  private static var lines: [String] = []

  nonisolated static func log(_ line: String) {
    print("polish-probe \(line)")
    guard let directory = PolishProbeTests.directory else { return }
    let url = URL(filePath: directory).appending(path: "report.md")
    try? FileManager.default.createDirectory(
      at: URL(filePath: directory), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data((line + "\n").utf8))
      try? handle.close()
    } else {
      try? Data((line + "\n").utf8).write(to: url)
    }
  }

  nonisolated static func list(_ values: [Double]) -> String {
    values.map { String(format: "%.1f", $0) }.joined(separator: " / ")
  }

  nonisolated static func stats(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "—" }
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let over16 = values.filter { $0 > 16.7 }.count
    let over8 = values.filter { $0 > 8.3 }.count
    return String(
      format: "中位 %.1f / p95 %.1f / 最长 %.1f ms（>8.3 ms %d 次、>16.7 ms %d 次，共 %d 次）",
      median, p95, sorted.last!, over8, over16, values.count)
  }

  func run() throws {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep, reason: "界面量测")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    guard let prefs = UserDefaults(suiteName: suite) else { throw CocoaError(.featureUnsupported) }
    defer { prefs.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let saved = (SiteIcons.shared.roots, ServiceIcons.shared.directory, ServiceIcons.shared.fetch)
    defer {
      (SiteIcons.shared.roots, ServiceIcons.shared.directory, ServiceIcons.shared.fetch) = saved
    }
    SiteIcons.shared.roots = { [] }
    ServiceIcons.shared.directory = scratch.appending(path: "ServiceIcons")
    ServiceIcons.shared.fetch = { _ in nil }

    Self.log(
      "\n## \(Date.now.formatted(date: .numeric, time: .standard))（\(Self.onscreen ? "屏上" : "屏外")，"
        + "屏幕刷新 \(NSScreen.main?.maximumFramesPerSecond ?? 0) Hz）")
    // 热身：进程里第一块 SwiftUI 面板的一次性开销
    let warm = OverlayPanel(
      size: NSSize(width: 400, height: 300), autoHide: .clickOutside, isPinned: { true },
      content: Text("热身").frame(maxWidth: .infinity, maxHeight: .infinity))
    let warmCost = show(warm)
    Self.log("热身面板首帧 \(String(format: "%.1f", warmCost.sync)) ms")
    warm.hide()
    spin(0.3)

    // TEST_RUNNER_KITTY_POLISH_ONLY=launcher,settings：只量这几块
    let only = ProcessInfo.processInfo.environment["KITTY_POLISH_ONLY"]?.split(separator: ",")
    let wants: (String) -> Bool = { name in
      (Self.loop == nil || Self.loop!.hasPrefix(name))
        && (only?.contains { name.hasPrefix($0) || $0.hasPrefix(name) } ?? true)
    }
    if wants("launcher") { try launcher(prefs) }
    if wants("clip") { try clipboard(prefs, count: Self.loop == nil ? 5000 : 300) }
    if Self.loop == nil, wants("clip") { try clipboard(prefs, count: 300) }
    if wants("translate") { try translate(prefs) }
    if wants("settings") { try settings(prefs) }
    if wants("files") { try launcherFiles(prefs) }
  }

  // MARK: - 共用

  private func spin(_ seconds: Double) {
    autoreleasepool { RunLoop.main.run(until: .now.addingTimeInterval(seconds)) }
  }

  /// 改状态之后：同步排完画完提交的那一下 + 之后 after 秒跑环里的忙
  @discardableResult
  private func settle(_ window: NSWindow, after: Double = 0.4, _ work: () -> Void) -> (
    sync: Double, busy: Double, longest: Double
  ) {
    let start = CACurrentMediaTime()
    work()
    lastWork = (CACurrentMediaTime() - start) * 1000
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
    let sync = (CACurrentMediaTime() - start) * 1000
    guard after > 0 else { return (sync, 0, 0) }
    meter.start()
    spin(after)
    meter.stop()
    return (sync, meter.slices.reduce(0, +), meter.slices.max() ?? 0)
  }

  private func place(_ panel: NSWindow) {
    if Self.onscreen {
      let visible = NSScreen.main?.visibleFrame ?? .zero
      panel.setFrameTopLeftPoint(
        NSPoint(x: visible.maxX - panel.frame.width - 8, y: visible.maxY - 8))
      panel.ignoresMouseEvents = true
    } else {
      panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }
  }

  @discardableResult
  private func show(_ panel: OverlayPanel, before: () -> Void = {}) -> (
    sync: Double, busy: Double, longest: Double
  ) {
    settle(panel) {
      before()
      if Self.onscreen {
        panel.alphaValue = 0.05
        place(panel)
        panel.orderFrontRegardless()
      } else {
        place(panel)
        panel.present(makingKey: false, keepsPlace: true)
      }
    }
  }

  /// TEST_RUNNER_KITTY_POLISH_PREWARM=1（=display：预排完再屏外画一遍，比较用）：面板建好后先屏外预排（OverlayPanel.prewarm，P7），记它花了多久、
  /// footprint 多了多少，再闲 1 秒；返回闲完的时刻（第一次呼出从这里算）。没开就 nil
  private func prewarmIfAsked(_ panel: OverlayPanel) -> CFTimeInterval? {
    guard let mode = ProcessInfo.processInfo.environment["KITTY_POLISH_PREWARM"] else { return nil }
    let before = Self.footprint()
    let start = CACurrentMediaTime()
    if mode == "display" {
      panel.prewarm()
      panel.displayIfNeeded()
    } else {
      panel.prewarm()
    }
    let cost = (CACurrentMediaTime() - start) * 1000
    spin(1)
    Self.log(
      String(
        format: "预排（%@）%.1f ms，phys_footprint +%.1f MB", mode == "display" ? "排版 + 画" : "只排版",
        cost, Self.footprint() - before))
    return CACurrentMediaTime()
  }

  /// phys_footprint（活动监视器的口径），MB
  static func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
  }

  private func fmt(_ value: (sync: Double, busy: Double, longest: Double)) -> String {
    String(
      format: "同步 %.1f ms，之后 0.4 s 主线程忙 %.1f ms（最长一下 %.1f ms）", value.sync, value.busy,
      value.longest)
  }

  private func scrollViews(in view: NSView?) -> [NSScrollView] {
    guard let view else { return [] }
    return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
  }

  /// 背景：浅色网页样 / 彩色壁纸样
  static func backdrop(_ kind: String, size: CGSize) throws -> CGImage {
    let scale: CGFloat = 2
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    if kind == "page" {
      NSColor(srgbRed: 0.969, green: 0.973, blue: 0.980, alpha: 1).setFill()
      CGRect(origin: .zero, size: size).fill()
      let words =
        "Hengdian World Studios, in eastern China, is often called China's Hollywood. Many period dramas are shot there."
      var y = size.height - 40
      while y > 20 {
        NSAttributedString(
          string: words,
          attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(white: 0.13, alpha: 1),
          ]
        ).draw(at: NSPoint(x: 20, y: y))
        y -= 30
      }
      NSColor.systemBlue.setFill()
      NSBezierPath(
        roundedRect: CGRect(x: 60, y: 300, width: 160, height: 36), xRadius: 18, yRadius: 18
      ).fill()
    } else {
      let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.18, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.25, blue: 0.70, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.55, blue: 0.35, alpha: 1),
      ])!
      gradient.draw(in: CGRect(origin: .zero, size: size), angle: 35)
      NSColor(white: 1, alpha: 0.25).setFill()
      NSBezierPath(ovalIn: CGRect(x: 520, y: 260, width: 420, height: 420)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.cgImage)
  }

  /// 照 AppDelegate 摆的三块主面板（内容同 measure）
  func lists(in view: NSView?) -> [NSScrollView] {
    scrollViews(in: view).sorted {
      $0.documentView?.frame.height ?? 0 > $1.documentView?.frame.height ?? 0
    }
  }

  func makePanel(_ kind: String, prefs: UserDefaults) throws -> OverlayPanel {
    switch kind {
    case "clipboard", "clipboard-actions", "clipboard-scrolled":
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      let store = try makeStore(count: 60)
      keep.append(store)
      let model = ClipboardPanelModel(store: store)
      keep.append(model)
      if kind == "clipboard-actions" { model.showsActions = true }
      let panel = OverlayPanel(
        size: NSSize(
          width: ClipboardPanelView.width,
          height: ClipboardPanelView.height(for: model, showsLens: true, banner: false)),
        topAnchored: true, autoHide: .clickOutside, isPinned: { true },
        content: ClipboardPanelView(model: model).defaultAppStorage(prefs))
      model.resize = { [weak panel] in panel?.setContentHeight($0, animated: false) }
      return panel
    case "launcher", "launcher-actions":
      let model = LauncherModel(
        usage: try LauncherUsage(db: Database(path: ":memory:")), apps: AppCatalog.scan())
      keep.append(model)
      model.boundHotKey = { $0.defaultHotKey }
      model.prepareForShow()
      model.query = "s"
      if kind == "launcher-actions" { model.showsActions = true }
      let panel = OverlayPanel(
        size: NSSize(width: Style.listPanelWidth, height: LauncherPanelView.height(for: model)),
        topAnchored: true, autoHide: .clickOutside, isPinned: { true },
        content: LauncherPanelView(model: model).defaultAppStorage(prefs))
      model.resize = { [weak panel] in panel?.setContentHeight($0, animated: false) }
      return panel
    default:
      let services = TranslateServiceStore(services: [.zhipu, .builtin(.google), .builtin(.deepl)])
      let coordinator = TranslateCoordinator(
        services: services, history: try HistoryStore(db: Database(path: ":memory:")))
      let speaker = Speaker()
      keep.append(coordinator)
      keep.append(speaker)
      coordinator.beginInput()
      coordinator.sourceText = Self.english
      coordinator.translatedSource = coordinator.sourceText
      coordinator.detected = .en
      coordinator.target = .zhHans
      coordinator.cards = services.services.map { .init(service: $0, state: .done(Self.chinese)) }
      weak var created: OverlayPanel?
      let panel = OverlayPanel(
        size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 200),
        autoHide: .resignKey, isPinned: { true },
        content: TranslatePanelView(
          coordinator: coordinator, speaker: speaker,
          resize: { height, mustFit in
            let height = TranslatePanelView.panelHeight(height, mustFit: mustFit, visible: 900)
            created?.setContentHeight(height, animated: false)
          }
        ).defaultAppStorage(prefs))
      created = panel
      return panel
    }
  }
  private var keep: [AnyObject] = []

  // MARK: - 启动器

  private func launcher(_ prefs: UserDefaults) throws {
    let apps = AppCatalog.scan()
    Self.log("\n### 启动器（本机 \(apps.count) 个 App）")
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: apps)
    model.boundHotKey = { $0.defaultHotKey }
    var built: OverlayPanel?
    let start = CACurrentMediaTime()
    model.prepareForShow()
    let panel = OverlayPanel(
      size: NSSize(width: Style.listPanelWidth, height: LauncherPanelView.height(for: model)),
      topAnchored: true, autoHide: .clickOutside, isPinned: { true },
      content: LauncherPanelView(model: model).defaultAppStorage(prefs))
    panel.onHide = { [unowned model] in model.didHide() }
    model.hidePanel = { [weak panel] in panel?.hide() }
    // 同 AppDelegate：⌘K 菜单开着、连着打字时直接到位（P4）
    var resizes = (all: 0, animated: 0)
    model.resize = { [weak panel, unowned model] in
      let animated = !model.showsActions && !model.isTyping
      resizes.all += 1
      resizes.animated += animated ? 1 : 0
      panel?.setContentHeight($0, animated: animated)
    }
    built = panel
    // 预排（P7，同 AppDelegate.prewarmPanels）：之后第一次呼出照真 App 再 prepareForShow 一次
    let prewarmed = prewarmIfAsked(panel)
    // 第一次呼出 = 显示之前花的（建面板、prepareForShow；预排过的从闲完那一刻算，是 0）+ 显示那一下同步的；之后 0.4 s 跑环里的
    // 另记（原来把那 0.4 s 的空转也算了进去，比真的多 400 ms 左右）
    let beforeShow = (CACurrentMediaTime() - (prewarmed ?? start)) * 1000
    let cold = show(panel, before: { if prewarmed != nil { model.prepareForShow() } })
    Self.log(
      "第一次呼出（\(prewarmed == nil ? "建面板 + 排版 + 首帧" : "预排过：prepareForShow + 首帧")）\(String(format: "%.1f", beforeShow + cold.sync)) ms；"
        + fmt(cold))
    if looping(
      "launcher-type",
      { index in
        let words = ["s", "sa", "saf", "safa", "safar", "safari", "safar", "safa", "saf", "sa"]
        model.query = words[index / 3 % words.count]
      })
    {
      return
    }
    var again: [Double] = []
    var busy: [Double] = []
    for _ in 0..<10 {
      panel.hide()
      spin(0.15)
      let value = show(panel, before: { model.prepareForShow() })
      again.append(value.sync)
      busy.append(value.longest)
    }
    Self.log("再呼出（prepareForShow + 显示）：同步 \(Self.stats(again))；之后最长一下 \(Self.stats(busy))")
    for (label, word) in [
      ("App 名", "safari"), ("中文", "系统设置"), ("计算", "12*(3+4)/7"), ("没结果", "zqxjkvw"),
    ] {
      settle(panel, after: 0.2) { model.query = "" }
      var keys: [Double] = []
      var works: [Double] = []
      var longest: [Double] = []
      var busy: [Double] = []
      var typed = ""
      resizes = (0, 0)
      for character in word {
        typed.append(character)
        let value = settle(panel, after: 0.12) { model.query = typed }
        keys.append(value.sync)
        works.append(lastWork)
        longest.append(value.longest)
        busy.append(value.busy)
      }
      Self.log(
        "打字（\(label)「\(word)」逐字）：同步 \(Self.stats(keys))；其中改 query（搜索本身）\(Self.stats(works))；之后最长一下 \(Self.stats(longest))；"
          + "之后 0.12 s 合计忙 \(Self.stats(busy))；改高度 \(resizes.all) 次（带动画 \(resizes.animated) 次）"
      )
    }
    // ↓ 连按
    settle(panel, after: 0.2) { model.query = "s" }
    var moves: [Double] = []
    for _ in 0..<20 {
      moves.append(
        settle(panel, after: 0.03) { _ = model.handleCommand(#selector(NSResponder.moveDown(_:))) }
          .sync)
    }
    Self.log("↓（查「s」，20 下）：同步 \(Self.stats(moves))")
    panel.hide()
    built = nil
    _ = built
    spin(0.3)
  }

  // MARK: - 启动器的文件搜索

  /// 2026-11-24 用户反馈：文件搜索逐字打「.xlsx」、再删「sx」都卡一会。真查本机 Spotlight（宿主 = Dev 版的授权），
  /// 每个字：改 query 那一下同步多久、之后 1.5 s 里结果到了几批、最后一批什么时候到、主线程最长一下 / 合计忙多久；
  /// 再按 0.1 s 一个字连着打一遍，看整段里主线程最长卡多久。只记数量，不记文件名。
  /// _LOOP=files-type：照 0.15 s 一个字来回打删 10 秒，给 sample 用
  private func launcherFiles(_ prefs: UserDefaults) throws {
    Self.log("\n### 启动器文件搜索（本机 Spotlight）")
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: AppCatalog.scan())
    model.boundHotKey = { $0.defaultHotKey }
    model.prepareForShow()
    let panel = OverlayPanel(
      size: NSSize(width: Style.listPanelWidth, height: LauncherPanelView.height(for: model)),
      topAnchored: true, autoHide: .clickOutside, isPinned: { true },
      content: LauncherPanelView(model: model).defaultAppStorage(prefs))
    model.resize = { [weak panel, unowned model] in
      panel?.setContentHeight($0, animated: !model.showsActions && !model.isTyping)
    }
    show(panel)
    spin(0.3)
    // 带 apps 建的模型（isFixture）不查 Spotlight：照 searchFiles 自己起（同一个 FileSearch、同一个 showFiles）
    var deliveries: [(at: CFTimeInterval, hits: Int)] = []
    func type(_ text: String) {
      model.query = text
      guard let request = model.fileRequest, !request.isTooShort else { return }
      model.files.start(request, used: model.usedFiles) { [weak model] hits in
        deliveries.append((CACurrentMediaTime(), hits.count))
        model?.showFiles(hits, for: request)
      }
    }
    /// 逐字打完，再逐字删回 2 个字
    func steps(_ word: String) -> [String] {
      var typed: [String] = []
      var text = ""
      for character in word {
        text.append(character)
        typed.append(text)
      }
      while text.count > 2 {
        text.removeLast()
        typed.append(text)
      }
      return typed
    }
    if looping(
      "files-type",
      { index in
        let all = steps(" .xlsx")
        if index % 9 == 0 { type(all[index / 9 % all.count]) }
      })
    {
      return
    }
    let visible = { (text: String) in text.replacingOccurrences(of: " ", with: "␣") }
    for word in [" .xlsx", "open .xlsx", " report", ".xlsx"] {
      settle(panel, after: 0.3) { model.query = "" }
      var lines: [String] = []
      var syncs: [Double] = []
      var longest: [Double] = []
      for text in steps(word) {
        deliveries = []
        let start = CACurrentMediaTime()
        let value = settle(panel, after: 1.5) { type(text) }
        syncs.append(value.sync)
        longest.append(value.longest)
        let last = deliveries.last.map { ($0.at - start) * 1000 } ?? 0
        lines.append(
          String(
            format: "「%@」同步 %.1f ms，%d 批（最后一批 %.0f ms、%d 条）、之后最长一下 %.1f ms、合计忙 %.1f ms",
            visible(text), value.sync, deliveries.count, last, deliveries.last?.hits ?? 0,
            value.longest, value.busy))
      }
      Self.log(
        "逐字（每字等 1.5 s）「\(visible(word))」：同步 \(Self.stats(syncs))；之后最长一下 \(Self.stats(longest))")
      for line in lines { Self.log("  - " + line) }
      // 连着打：0.1 s 一个字，整段（含最后等 1.5 s）主线程每一轮
      settle(panel, after: 0.3) { model.query = "" }
      meter.start()
      var fast: [Double] = []
      for text in steps(word) {
        let start = CACurrentMediaTime()
        type(text)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        fast.append((CACurrentMediaTime() - start) * 1000)
        spin(0.1)
      }
      spin(1.5)
      meter.stop()
      Self.log(
        "连着打（0.1 s 一字）「\(visible(word))」：每字同步 \(Self.stats(fast))；整段跑环每一轮 \(Self.stats(meter.slices))"
      )
    }
    panel.hide()
    model.files.stop()
    spin(0.3)
  }

  // MARK: - 剪贴板

  private func png(index: Int) throws -> (Data, Int, Int) {
    let (width, height) = (1200, 800)
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    for band in 0..<20 {
      let hue = Double((index * 37 + band * 11) % 100) / 100
      context.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1).cgColor)
      context.fill(CGRect(x: 0, y: band * 40, width: width, height: 40))
    }
    let image = try #require(context.makeImage())
    let data = try #require(
      NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    return (data, width, height)
  }

  private func makeStore(count: Int) throws -> ClipboardStore {
    let images = ImageStore(directory: scratch.appending(path: "images"))
    try FileManager.default.createDirectory(at: images.directory, withIntermediateDirectories: true)
    let store = try ClipboardStore(db: Database(path: ":memory:"), images: images)
    let sources: [(String, String)] = [
      ("备忘录", "com.apple.Notes"), ("Xcode", "com.apple.dt.Xcode"),
      ("Safari 浏览器", "com.apple.Safari"), ("微信", "com.tencent.xinWeChat"),
      ("终端", "com.apple.Terminal"),
    ]
    var items: [ClipItem] = []
    for index in 0..<count {
      let source = sources[index % sources.count]
      if index % 125 == 7 {
        var item = ClipItem(kind: .image, sourceName: source.0, sourceBundleID: source.1)
        let (data, width, height) = try png(index: index)
        try data.write(to: images.url(for: item.id))
        item.image = .init(width: width, height: height, byteCount: data.count, sha256: "p\(index)")
        item.ocrText = "截图 \(index)"
        items.append(item)
        continue
      }
      if index % 97 == 3 {
        var item = ClipItem(kind: .file, sourceName: "访达", sourceBundleID: "com.apple.finder")
        item.filePaths = ["/System/Applications/Notes.app"]
        items.append(item)
        continue
      }
      var item = ClipItem(kind: .text, sourceName: source.0, sourceBundleID: source.1)
      item.text =
        switch index % 6 {
        case 0: "第 \(index) 条：SwiftUI 用声明式的方式描述界面，状态一变，框架就会自动更新对应的视图。"
        case 1: "struct Row\(index): View {\n  var body: some View { Text(\"row \(index)\") }\n}"
        case 2: "{\"index\": \(index), \"name\": \"kitty\", \"tags\": [1, 2, 3]}"
        case 3: "https://example.com/articles/\(index)?ref=clipboard"
        case 4: "#\(String(format: "%06X", (index * 7919) % 0xFFFFFF))"
        default: "短文本 \(index) swift kitty"
        }
      items.append(item)
    }
    for (index, var item) in items.enumerated().reversed() {
      item.copiedAt = .now.addingTimeInterval(-Double(index) * 30)
      store.record(item)
    }
    return store
  }

  private func clipboard(_ prefs: UserDefaults, count: Int = 5000) throws {
    let start = CACurrentMediaTime()
    let store = try makeStore(count: count)
    Self.log(
      "\n### 剪贴板（\(store.items.count) 条；建库 \(String(format: "%.0f", (CACurrentMediaTime() - start) * 1000)) ms）"
    )
    let model = ClipboardPanelModel(store: store)
    let open = CACurrentMediaTime()
    let panel = OverlayPanel(
      size: NSSize(
        width: ClipboardPanelView.width,
        height: ClipboardPanelView.height(for: model, showsLens: true, banner: false)),
      topAnchored: true, autoHide: .clickOutside, isPinned: { true },
      content: ClipboardPanelView(model: model).defaultAppStorage(prefs))
    panel.onHide = { [unowned model] in model.reset() }
    model.hidePanel = { [weak panel] in panel?.hide() }
    // 同 AppDelegate：打字带来的高度变化直接到位
    model.resize = { [weak panel, unowned model] in
      panel?.setContentHeight($0, animated: !model.isTyping)
    }
    let prewarmed = prewarmIfAsked(panel)
    let beforeShow = (CACurrentMediaTime() - (prewarmed ?? open)) * 1000
    let cold = show(panel)
    Self.log(
      "第一次呼出（\(prewarmed == nil ? "建面板 + 首帧" : "预排过：首帧")）\(String(format: "%.1f", beforeShow + cold.sync)) ms；\(fmt(cold))"
    )
    if looping(
      "clip-down",
      { index in
        _ = model.handleCommand(
          index % 80 < 40 ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:)))
      })
    {
      return
    }
    if looping(
      "clip-swap",
      { index in
        if index == 0 { model.select(model.visibleItems[2]) }
        _ = model.handleCommand(
          index % 2 == 0 ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:)))
      })
    {
      return
    }
    if looping(
      "clip-search",
      { index in
        let words = ["s", "sw", "swi", "swif", "swift", "swif", "swi", "sw", "s", ""]
        model.query = words[index / 4 % words.count]
      })
    {
      return
    }
    if looping(
      "clip-narrow",
      { index in
        let words = ["第", "第 1", "第 12", "第 1", "第", ""]
        model.query = words[index / 4 % words.count]
      })
    {
      return
    }
    if looping(
      "clip-scroll",
      { index in
        guard
          let list = scrollViews(in: panel.contentView).max(by: {
            $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0
          })
        else { return }
        let y = CGFloat(index % 400 < 200 ? index % 200 : 200 - index % 200) * 24
        list.contentView.scroll(to: NSPoint(x: 0, y: y))
        list.reflectScrolledClipView(list.contentView)
      })
    {
      return
    }
    var again: [Double] = []
    var after: [Double] = []
    var enforce: [Double] = []
    for _ in 0..<10 {
      panel.hide()
      spin(0.15)
      // 同 AppDelegate.toggleClipboard：没开着时先 enforceLimits
      let limits = CACurrentMediaTime()
      _ = store.enforceLimits()
      enforce.append((CACurrentMediaTime() - limits) * 1000)
      let value = show(panel)
      again.append(value.sync)
      after.append(value.longest)
    }
    Self.log(
      "再呼出：enforceLimits \(Self.stats(enforce))；显示同步 \(Self.stats(again))；之后最长一下 \(Self.stats(after))"
    )

    var downs: [Double] = []
    var downWork: [Double] = []
    var downLongest: [Double] = []
    for _ in 0..<60 {
      let value = settle(panel, after: 0.03) {
        _ = model.handleCommand(#selector(NSResponder.moveDown(_:)))
      }
      downWork.append(lastWork)
      downs.append(value.sync)
      downLongest.append(value.longest)
    }
    Self.log(
      "↓ 60 下：同步 \(Self.stats(downs))；其中改选中本身 \(Self.stats(downWork))；之后最长一下 \(Self.stats(downLongest))"
    )
    var ups: [Double] = []
    for _ in 0..<60 {
      ups.append(
        settle(panel, after: 0.03) { _ = model.handleCommand(#selector(NSResponder.moveUp(_:))) }
          .sync)
    }
    Self.log("↑ 60 下：同步 \(Self.stats(ups))")
    // 透镜只在屏上几行之间换（不带出滚动）：选中第 3 条后 ↓↑ 交替，看换透镜本身多贵（↓ 60 下里大半带着滚动、跨段补行）
    settle(panel, after: 0.3) { model.select(model.visibleItems[2]) }
    var swaps: [Double] = []
    var swapLongest: [Double] = []
    for index in 0..<60 {
      let value = settle(panel, after: 0.03) {
        _ = model.handleCommand(
          index % 2 == 0 ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:)))
      }
      swaps.append(value.sync)
      swapLongest.append(value.longest)
    }
    Self.log("↓↑ 不滚动 60 下：同步 \(Self.stats(swaps))；之后最长一下 \(Self.stats(swapLongest))")

    // 滚动：找列表那个滚动视图，每步 24 pt（像触控板一帧的量），往下 300 步再回来
    let scrolls = scrollViews(in: panel.contentView).sorted {
      $0.documentView?.frame.height ?? 0 > $1.documentView?.frame.height ?? 0
    }
    if let list = scrolls.first {
      let height = list.documentView?.frame.height ?? 0
      var steps: [Double] = []
      var y: CGFloat = 0
      for step in 0..<600 {
        y += step < 300 ? 24 : -24
        let value = settle(panel, after: 0) {
          list.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
          list.reflectScrolledClipView(list.contentView)
        }
        steps.append(value.sync)
        if step % 10 == 0 { spin(0.001) }
      }
      meter.start()
      spin(0.3)
      meter.stop()
      Self.log(
        "滚动（列表内容高 \(Int(height)) pt，每步 24 pt，下 300 步再上 300 步）：每步同步 \(Self.stats(steps))；"
          + "停下后 0.3 s 最长一下 \(String(format: "%.1f", meter.slices.max() ?? 0)) ms")
      // 一次拖到底（拖滚动条）
      let jump = settle(panel) {
        list.contentView.scroll(
          to: NSPoint(x: 0, y: max(0, height - list.contentView.bounds.height)))
        list.reflectScrolledClipView(list.contentView)
      }
      Self.log("一下拖到底：\(fmt(jump))")
      _ = settle(panel, after: 0.2) {
        list.contentView.scroll(to: .zero)
        list.reflectScrolledClipView(list.contentView)
      }
      flingGaps(panel, list)
    } else {
      Self.log("没找到列表的滚动视图")
    }

    for word in ["swift", "第 12", "zqxj"] {
      settle(panel, after: 0.2) { model.query = "" }
      var works: [Double] = []
      var keys: [Double] = []
      var longest: [Double] = []
      var typed = ""
      for character in word {
        typed.append(character)
        let value = settle(panel, after: 0.15) { model.query = typed }
        keys.append(value.sync)
        works.append(lastWork)
        longest.append(value.longest)
      }
      Self.log(
        "搜索「\(word)」逐字：同步 \(Self.stats(keys))；其中改 query \(Self.stats(works))；之后最长一下 \(Self.stats(longest))"
      )
    }
    settle(panel, after: 0.2) { model.query = "" }
    // ⌘Y / 空格大卡不量（TransientPanel 要照 AppDelegate 接线）；透镜跟着选中换在 ↓ 里
    panel.hide()
    spin(0.3)
  }

  /// 快甩露不露白：每步滚 step pt（一帧滚这么多），每步排完画完立刻、再跑一帧之后各看一次可见区里最长的一截「空的」
  /// （左边 16–300 pt 这一溜里一整行像素颜色都一样：行的图标、标题、分组标题、透镜的字都落在这里，没画出来的地方是空的），
  /// 超过 30 pt 才算露白（两行图标之间最多空 16 pt、隔着分组标题 40 pt 的空里也有标题字）
  private func flingGaps(_ panel: NSWindow, _ list: NSScrollView) {
    func blank() -> CGFloat {
      let rect = list.contentView.frame
      guard let rep = list.bitmapImageRepForCachingDisplay(in: rect) else { return -1 }
      list.cacheDisplay(in: rect, to: rep)
      let scale = CGFloat(rep.pixelsWide) / rect.width
      var run = 0
      var longest = 0
      for y in 0..<rep.pixelsHigh {
        var low = 255
        var high = 0
        for x in stride(from: Int(16 * scale), to: min(Int(300 * scale), rep.pixelsWide), by: 2) {
          guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
          let value = Int(
            color.redComponent * 255 + color.greenComponent * 255 + color.blueComponent * 255)
          low = min(low, value)
          high = max(high, value)
        }
        run = high - low < 12 ? run + 1 : 0
        longest = max(longest, run)
      }
      return CGFloat(longest) / scale
    }
    var lines: [String] = []
    for step in [40.0, 120, 240, 400] {
      var now: [Double] = []
      var later: [Double] = []
      var y: CGFloat = 0
      _ = settle(panel, after: 0.1) {
        list.contentView.scroll(to: .zero)
        list.reflectScrolledClipView(list.contentView)
      }
      for _ in 0..<30 {
        y += step
        _ = settle(panel, after: 0) {
          list.contentView.scroll(to: NSPoint(x: 0, y: y))
          list.reflectScrolledClipView(list.contentView)
        }
        now.append(Double(blank()))
        spin(0.017)
        later.append(Double(blank()))
      }
      lines.append(
        String(
          format: "每步 %.0f pt：立刻 最长空 %.0f pt（>30 的 %d 步），一帧后 %.0f pt（>30 的 %d 步）", step,
          now.max() ?? 0, now.filter { $0 > 30 }.count, later.max() ?? 0,
          later.filter { $0 > 30 }.count))
    }
    _ = settle(panel, after: 0.2) {
      list.contentView.scroll(to: .zero)
      list.reflectScrolledClipView(list.contentView)
    }
    Self.log("快甩露白（30 步）：" + lines.joined(separator: "；"))
  }

  // MARK: - 翻译

  private func translate(_ prefs: UserDefaults) throws {
    Self.log("\n### 翻译浮窗（三张结果卡）")
    var list = [TranslateService.zhipu, .builtin(.google), .builtin(.deepl)]
    for index in list.indices { list[index].isEnabled = true }
    let services = TranslateServiceStore(services: list)
    let history = try HistoryStore(db: Database(path: ":memory:"))
    let coordinator = TranslateCoordinator(services: services, history: history)
    // 不读用户的折叠偏好（折叠着的服务不翻）
    coordinator.collapsed = { [] }
    let speaker = Speaker()
    coordinator.beginInput()
    coordinator.sourceText = Self.english
    coordinator.translatedSource = coordinator.sourceText
    coordinator.detected = .en
    coordinator.target = .zhHans
    coordinator.cards = services.services.map { .init(service: $0, state: .waiting) }
    weak var created: OverlayPanel?
    let visible = NSScreen.main?.visibleFrame.height ?? 900
    /// 窗口高度真改了几次（流式时应该只在行数变了时改）
    var resizes = 0
    let panel = OverlayPanel(
      size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 200),
      autoHide: .resignKey, isPinned: { true },
      content: TranslatePanelView(
        coordinator: coordinator, speaker: speaker,
        resize: { height, mustFit in
          let height = TranslatePanelView.panelHeight(height, mustFit: mustFit, visible: visible)
          guard let created else { return }
          if abs(created.frame.height - height) > 0.5 { resizes += 1 }
          // 屏上（透明度 0.05）的面板本来就不做高度动画；屏外量真 App 的动画：
          // _ANIMATE=always：变化 8 pt 以上就带（0.3 – P4 的写法），=lines：有卡在出字时不带（P5）
          let streaming = coordinator.cards.contains {
            if case .running(let text) = $0.state { !text.isEmpty } else { false }
          }
          let animated =
            switch Self.animate {
            case "always": abs(created.frame.height - height) >= 8
            case "lines": !streaming && abs(created.frame.height - height) >= 8
            default: false
            }
          created.setContentHeight(height, animated: animated)
        }
      ).defaultAppStorage(prefs))
    created = panel
    let cold = show(panel)
    Self.log("第一次呼出（三张卡在等）：\(fmt(cold))")
    // 给 sample 用：等待中（骨架 + 彗星）原样摆 10 秒
    if looping("translate-wait", whole: { end in spin(end - CACurrentMediaTime()) }) {
      panel.hide()
      return
    }
    // 等待中（骨架 + 彗星）1 秒里主线程忙多少：刚呼出后（0.4 s 起）一秒、再一秒（出现时的一次性活干完了，只剩循环动效）
    for label in ["等待中 1 秒", "等待中再 1 秒"] {
      meter.start()
      let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      spin(1)
      let cpu1 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      meter.stop()
      Self.log(
        "\(label)：主线程 CPU \(String(format: "%.1f", Double(cpu1 - cpu0) / 1e7))%（最长一下 \(String(format: "%.1f", meter.slices.max() ?? 0)) ms）"
      )
    }
    // 经协调器的流（真 App 的路径：每来一段字是主线程上的一次 job，三个服务各来各的）：每个服务每 30 ms 多一个字，
    // 三个服务的相位错开 10 ms
    let full = Array(Self.chinese)
    coordinator.stream = { service, _ in
      let phase = list.firstIndex { $0.id == service.id } ?? 0
      return AsyncThrowingStream { continuation in
        let task = Task {
          try? await Task.sleep(for: .milliseconds(10 * phase))
          for step in 1...full.count {
            guard !Task.isCancelled else { break }
            continuation.yield(String(full.prefix(step)))
            try? await Task.sleep(for: .milliseconds(30))
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    /// 跑一轮：从开跑到三张都出完（最多 10 秒）
    func streamOnce(until end: CFTimeInterval) {
      coordinator.translate(Self.english, fromCopy: true)
      spin(0.05)
      while coordinator.isRunning, CACurrentMediaTime() < end { spin(0.05) }
    }
    if looping(
      "translate-stream",
      whole: { end in
        while CACurrentMediaTime() < end { streamOnce(until: end) }
      })
    {
      panel.hide()
      return
    }
    resizes = 0
    let cpuS = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let wallS = CACurrentMediaTime()
    streamOnce(until: wallS + 10)
    let cpuE = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let wall = (CACurrentMediaTime() - wallS) * 1000
    let streamed = coordinator.cards.map(\.state) == Array(repeating: .done(Self.chinese), count: 3)
    Self.log(
      "经协调器流式（三个服务各自每 30 ms 一个字、相位错开 10 ms，各 \(full.count) 字）：主线程 CPU "
        + "\(String(format: "%.0f", Double(cpuE - cpuS) / 1e6)) ms / \(String(format: "%.0f", wall)) ms 墙上时间"
        + "（\(String(format: "%.1f", Double(cpuE - cpuS) / 1e4 / wall))%）；窗口改高 \(resizes) 次；"
        + (streamed ? "三张都出完" : "没出完：\(coordinator.cards.map(\.state))"))
    // 流式：每 30 ms 三张卡各多一个字，共 3 秒（直接改模型、每次同步排完画完：量一次更新本身多贵）
    coordinator.cards = services.services.map { .init(service: $0, state: .waiting) }
    spin(0.3)
    resizes = 0
    var updates: [Double] = []
    meter.start()
    let cpu2 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    for step in 1...100 {
      let value = settle(panel, after: 0) {
        for index in coordinator.cards.indices {
          coordinator.cards[index].state = .running(String(full.prefix(min(full.count, step))))
        }
      }
      updates.append(value.sync)
      spin(0.03)
    }
    let cpu3 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    meter.stop()
    Self.log(
      "流式出字（三张卡每 30 ms 各多一个字，100 次）：每次同步 \(Self.stats(updates))；"
        + "这段主线程 CPU \(String(format: "%.0f", Double(cpu3 - cpu2) / 1e6)) ms / 约 \(String(format: "%.1f", 100 * 0.03 * 1000 + updates.reduce(0, +))) ms 墙上时间；跑环最长一下 \(String(format: "%.1f", meter.slices.max() ?? 0)) ms；窗口改高 \(resizes) 次"
    )
    let done = settle(panel) {
      for index in coordinator.cards.indices {
        coordinator.cards[index].state = .done(Self.chinese)
      }
    }
    Self.log("出完（三张换成完成）：\(fmt(done))")
    panel.hide()
    spin(0.3)
  }

  // MARK: - 设置窗

  private func settings(_ prefs: UserDefaults) throws {
    Self.log("\n### 设置窗（每页第一次打开 / 再打开）")
    let store = try ClipboardStore(
      db: Database(path: ":memory:"), images: ImageStore(directory: scratch.appending(path: "s")))
    let services = TranslateServiceStore(services: [.zhipu, .builtin(.google), .builtin(.deepl)])
    let history = try HistoryStore(db: Database(path: ":memory:"))
    let hotKeys = HotKeyCenter()
    let speaker = Speaker()
    let navigation = SettingsNavigation(defaults: nil)
    let root = SettingsRoot(navigation: navigation) { page in
      switch page {
      case .general: AnyView(GeneralTab())
      case .island: AnyView(IslandTab())
      case .plugins: AnyView(PluginsPage())
      case .clipboard: AnyView(ClipboardTab(store: store))
      case .launcher: AnyView(EmptyView())
      case .launchpad: AnyView(EmptyView())
      case .screenshot: AnyView(ScreenshotTab(shots: nil))
      case .record: AnyView(RecordTab())
      case .notes: AnyView(NotesTab {})
      case .statusScreen: AnyView(StatusScreenTab())
      case .reminders: AnyView(EmptyView())
      case .dockPreview: AnyView(DockPreviewTab())
      case .finderMenu: AnyView(FinderMenuTab(extensionEnabled: false))
      case .keepAwake: AnyView(EmptyView())
      case .bluetoothSnooze: AnyView(BluetoothSnoozeTab(requestAccess: {}, authorized: false))
      case .smoothScroll: AnyView(SmoothScrollTab(smoothScroll: SmoothScroll(observes: false)))
      case .appShortcuts: AnyView(AppShortcutsTab(trusted: false))
      case .keyRemapping: AnyView(EmptyView())
      case .translate:
        AnyView(TranslateTab(services: services, history: history, speaker: speaker))
      case .hotkeys: AnyView(HotkeysTab(center: hotKeys))
      case .about: AnyView(AboutTab(updater: Updater()))
      }
    } onboarding: {
      AnyView(EmptyView())
    }
    let window = PolishParkedWindow(
      contentViewController: .windowContent(root.defaultAppStorage(prefs)))
    window.title = navigation.page.title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 780, height: 600))
    let open = settle(window) {
      if Self.onscreen { window.alphaValue = 0.05 }
      place(window)
      window.orderFrontRegardless()
    }
    Self.log("打开（通用页）：\(fmt(open))")
    let pages: [SettingsPage] = [
      .clipboard, .translate, .screenshot, .record, .notes, .hotkeys, .statusScreen, .plugins,
      .island, .dockPreview, .about, .general, .bluetoothSnooze, .smoothScroll, .appShortcuts,
      .keyRemapping, .finderMenu,
    ]
    let opened = Self.footprint()
    if looping(
      "settings",
      { index in
        if index % 12 == 0 { navigation.page = pages[index / 12 % pages.count] }
      })
    {
      return
    }
    // settings-pair：通用 ↔ 快捷键来回切
    if looping(
      "settings-pair",
      { index in
        if index % 12 == 0 { navigation.page = index / 12 % 2 == 0 ? .general : .hotkeys }
      })
    {
      return
    }
    var firsts: [String] = []
    for page in pages {
      let value = settle(window, after: 0.5) { navigation.page = page }
      firsts.append(
        "\(page.rawValue) \(String(format: "%.0f", value.sync))+\(String(format: "%.0f", value.busy))"
      )
    }
    Self.log("第一次换到各页（同步 + 之后 0.5 s 忙，ms）：\(firsts.joined(separator: "，"))")
    var seconds: [String] = []
    for page in pages {
      let value = settle(window, after: 0.4) { navigation.page = page }
      seconds.append(
        "\(page.rawValue) \(String(format: "%.0f", value.sync))+\(String(format: "%.0f", value.busy))"
      )
    }
    Self.log("再换到各页：\(seconds.joined(separator: "，"))")
    // 来回切两页（真用的时候最常见：在两三页之间改来改去）
    for pair in [(SettingsPage.general, SettingsPage.hotkeys), (.statusScreen, .translate)] {
      var back: [Double] = []
      settle(window, after: 0.3) { navigation.page = pair.0 }
      settle(window, after: 0.3) { navigation.page = pair.1 }
      for step in 0..<10 {
        back.append(
          settle(window, after: 0.3) { navigation.page = step % 2 == 0 ? pair.0 : pair.1 }.sync)
      }
      Self.log("来回切 \(pair.0.rawValue) ↔ \(pair.1.rawValue)（10 次）：同步 \(Self.stats(back))")
    }
    let visited = Self.footprint()
    // 拖窗口改大小
    var resizes: [Double] = []
    for step in 0..<10 {
      resizes.append(
        settle(window, after: 0) {
          window.setContentSize(NSSize(width: 780 + CGFloat(step % 2) * 60, height: 600))
        }.sync)
      spin(0.05)
    }
    Self.log(
      String(
        format: "各页都看过两遍后 phys_footprint 比刚打开时 +%.1f MB；改窗口大小（10 次）：同步 %@",
        visited - opened, Self.stats(resizes)))
    window.close()
    spin(1)
    Self.log(String(format: "关窗后 phys_footprint 比刚打开时 +%.1f MB", Self.footprint() - opened))
  }

  private static let english =
    "SwiftUI lets you describe your interface declaratively: say what it should look like for a "
    + "state, and the framework keeps it up to date."
  private static let chinese =
    "SwiftUI 用声明式的方式描述界面：你只需要写出界面在某个状态下应该是什么样子，状态一变，框架就会自动更新对应的视图。"
    + "视图是轻量的值类型，组合起来很便宜，所以可以放心地把大界面拆成许多小视图。"
}

private final class PolishParkedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
