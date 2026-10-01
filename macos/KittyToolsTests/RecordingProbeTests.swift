// 录屏 / 录音的按需实录探针（第 0 批，2026-09-30）：真开 ScreenCaptureKit 录几秒、用 AVAudioRecorder 录几秒，把拍板方案
// 押着的事实量出来——系统录制管线（SCRecordingOutput）要不要挂样本输出、回调在哪个线程、开始回调多久来、音轨与混音、色彩、
// 排除本 App 时哪些自家窗口进画面、H.264 硬件编码上限、文件大小、录到一半和闪退后的文件、小区域录系统声音、麦克风。
// 只报告、少断言；结论写回 PLAN §10「录屏与录音」。要「屏幕录制」授权；会录下当前屏幕（整屏原始视频留在输出目录，看完
// 自己删）、在屏幕上闪色块窗口、铺一块滚动的大面板约 30 秒、用 afplay 放几声系统提示音。输出目录要写绝对路径：
//   TEST_RUNNER_KITTY_LIVE_RECORD_DIR=/tmp/kitty-record xcodebuild -project macos/KittyTools.xcodeproj \
//     -scheme KittyTools test -only-testing:KittyToolsTests/RecordingProbeTests
// 另加 TEST_RUNNER_KITTY_LIVE_RECORD_MIC=1：麦克风几项（第一次会弹麦克风授权框，要人点）。
// 闪退：先加 TEST_RUNNER_KITTY_LIVE_RECORD_KILL=1 只跑 crashRecording()（录 5 s 后 kill -9 自己，这次测试必然报崩溃），
// 过十几秒再加 TEST_RUNNER_KITTY_LIVE_RECORD_INSPECT=1 只跑 crashInspect() 看留下的文件。报告在 <输出目录>/report.md。
// 录屏第 1 批加了 screenRecorderTake()：用 ScreenRecorder 真录 2 s（只验产品代码，可以单独跑）；第 2 批起先倒数 1 s
// （录制 HUD 从倒数换成录制态，倒数不进文件：录下来仍是 2 s），录制中连 HUD 一起截图；第 3 批起顺带验最后一帧（poster）的
// 尺寸和内容（存成 recorder-poster.png，看完和视频一起删）；第 4 批起按录制条的偏好开系统声音 + 麦克风 + 显示点按：
// 0.5 s 时 afplay 放一声，验文件只有一条音轨、前 0.4 s 有麦克风底噪（第 0 批的对照法：只录系统声音那段是数字静音），
// 报告里记这段时间系统日志「NOT found」的条数（录什么挂什么空输出，应为 0）。要麦克风授权（Dev 版已有）。
// 手测反馈第 1 批（2026-10-01）加了 inputOverlayTake()：显示点按改成自己画（InputOverlay），开着它真录 2 s、直接调它的按下 /
// 拖动入口（不发合成鼠标事件、不真点任何东西），从 mp4 取帧验圈真的录进了画面、截图冻结帧里没有它、文件带色彩标记。
// 录音第 5 批加了 audioRecorderTake()（另加 TEST_RUNNER_KITTY_LIVE_RECORD_MIC=1）：用 AudioRecorder 录 1.5 s、暂停 1 s、再录 1.5 s，
// 验 m4a 能播、时长约 3 s、AAC 48 kHz 单声道约 128 kbps、名字「录音 …」挪进输出目录的 audio/、波形 poster；录制中截一张 HUD。
// 录音第 6 批加了 audioRecorderSystemTake(_:)（同样要 _MIC=1）：来源是系统声音 / 两者时走录屏管线只录声音，录约 2 s、0.5 s 时
// afplay 放一声，验 m4a 能播、只有一条 AAC 音轨、没有视频轨、时长对、电平事件来过、中间的 mp4 已删、⏸ 置灰。
// 录屏录音第 7 批加了 gifTake()：ScreenRecorder 真录 2 s 后用 VideoExport 转 GIF，验帧数约 30、宽 ≤ 960、循环、每帧约 1/15 s，
// 视频轨比文件短时最后一帧停到结尾，转到一半取消不留文件；录下的视频和 GIF 验完就删（第一帧 gif-first.png 看完自己删）。
import AVFoundation
import AppKit
import ScreenCaptureKit
import Synchronization
import Testing

@testable import KittyTools

/// 输出目录（TEST_RUNNER_KITTY_LIVE_RECORD_DIR，绝对路径）；没设就整组不跑
nonisolated private let probeDirectory = ProcessInfo.processInfo.environment[
  "KITTY_LIVE_RECORD_DIR"
].map { URL(filePath: $0, directoryHint: .isDirectory) }
nonisolated private let probeMicrophone =
  ProcessInfo.processInfo.environment["KITTY_LIVE_RECORD_MIC"] != nil
nonisolated private let probeKill =
  ProcessInfo.processInfo.environment["KITTY_LIVE_RECORD_KILL"] != nil
nonisolated private let probeInspect =
  ProcessInfo.processInfo.environment["KITTY_LIVE_RECORD_INSPECT"] != nil

/// 录制回调只记下发生了什么、在哪个线程。系统在后台线程回调，所以整个类 nonisolated（默认 MainActor 的类遵守这些协议
/// 编译不报错，回调一来就闪退）；可变状态放 Mutex
nonisolated final class ProbeCallbacks: NSObject, SCRecordingOutputDelegate, SCStreamDelegate,
  SCStreamOutput, Sendable
{
  struct State: Sendable {
    var started: Date?
    var finished: Date?
    var failure: String?
    var streamError: String?
    /// 回调名 → 有没有哪一次在主线程
    var threads: [String: Bool] = [:]
    /// SCStreamOutputType.rawValue → 收到的样本数
    var samples: [Int: Int] = [:]

    mutating func seen(_ callback: String, main: Bool) {
      threads[callback] = (threads[callback] ?? false) || main
    }
  }

  let state = Mutex(State())

  func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
    let main = Thread.isMainThread
    state.withLock {
      $0.started = .now
      $0.seen("didStart", main: main)
    }
  }

  func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    let main = Thread.isMainThread
    state.withLock {
      $0.finished = .now
      $0.seen("didFinish", main: main)
    }
  }

  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
    let text = Self.describe(error)
    let main = Thread.isMainThread
    state.withLock {
      $0.failure = text
      $0.finished = .now
      $0.seen("didFail", main: main)
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let text = Self.describe(error)
    let main = Thread.isMainThread
    state.withLock {
      $0.streamError = text
      $0.seen("didStop", main: main)
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    let main = Thread.isMainThread
    state.withLock {
      $0.samples[type.rawValue, default: 0] += 1
      $0.seen("sample\(type.rawValue)", main: main)
    }
  }

  static func describe(_ error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code) \(error.localizedDescription)"
  }
}

@Suite(.serialized, .enabled(if: probeDirectory != nil))
struct RecordingProbeTests {
  static var directory: URL { probeDirectory! }

  /// 录制 HUD 的窗口里的 HUD（内容视图是个容器，录音的四周留了边）
  static func hud(in window: NSWindow) -> RecordingHUD? {
    window.contentView?.subviews.first as? RecordingHUD
  }

  // MARK: - 回调、开始时刻、输出

  /// 开始回调多久来（画面静止 / 在动）、回调线程（挂一路画面输出看样本回调）、录制中截图（C9）
  @Test func startAndThreads() async throws {
    let env = try await Env.make()
    let mover = env.panel(.systemTeal, x: 0.1)
    let (filter, _) = try await env.filter(excepting: [mover])
    var lines: [String] = []
    let still = try await record("start-still", filter, env.configuration(filter)) { _ in
      try await Task.sleep(for: .seconds(3))
    }
    lines.append("— 画面静止")
    lines += still.summary + (await inspect(still.url)).summary
    var shot = "没截"
    let moving = try await record(
      "start-moving", filter, env.configuration(filter), outputs: [.screen]
    ) { _ in
      let started = Date.now
      do {
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: env.configuration(filter))
        shot = "成功 \(image.width)×\(image.height)，\(ms(since: started)) ms"
      } catch {
        shot = "失败 \(ProbeCallbacks.describe(error))"
      }
      try await animate(mover, seconds: 3)
    }
    mover.orderOut(nil)
    lines.append("— 画面在动、挂一路画面输出")
    lines += moving.summary + (await inspect(moving.url)).summary
    lines.append("录制中截图（SCScreenshotManager）：\(shot)")
    note("开始时刻、回调线程", lines)
  }

  /// 不挂样本输出行不行：对照组（开了系统声音却只挂画面输出，已知会刷「stream output NOT found」）和两种不挂的，
  /// 各数这段时间系统日志里的「NOT found」条数、看文件和 CPU
  @Test func outputsAndLogs() async throws {
    let env = try await Env.make()
    let mover = env.panel(.systemIndigo, x: 0.1)
    let (filter, _) = try await env.filter(excepting: [mover])
    var lines: [String] = []
    let variants: [(String, Bool, [SCStreamOutputType])] = [
      ("对照：开系统声音、只挂画面输出", true, [.screen]),
      ("开系统声音、挂画面和声音两路输出", true, [.screen, .audio]),
      ("开系统声音、不挂任何输出", true, []),
      ("不录声音、不挂任何输出", false, []),
    ]
    for (index, variant) in variants.enumerated() {
      let configuration = env.configuration(filter)
      configuration.capturesAudio = variant.1
      configuration.excludesCurrentProcessAudio = true
      var cpu = ""
      let since = Date.now
      let take = try await record(
        "outputs\(index)", filter, configuration, outputs: variant.2
      ) { _ in
        try await animate(mover, seconds: 1)
        play("Glass")
        try await animate(mover, seconds: 1)
        cpu = await processCPU()
        try await animate(mover, seconds: 1)
      }
      let media = await inspect(take.url)
      let logs = await notFoundLogs(since: since)
      lines.append("— \(variant.0)：日志「NOT found」\(logs)；CPU \(cpu)")
      lines += take.summary + media.summary
    }
    mover.orderOut(nil)
    note("样本输出挂不挂（日志用 log show --info --debug 按 eventMessage 过滤）", lines)
  }

  // MARK: - 声音

  /// 系统声音：本 App 在 0.3 s 放 Funk，别的进程在 2.5 s 放 Glass，按 1.5 s 分前后两段看峰值；
  /// excludesCurrentProcessAudio 开 / 关各一次（关的是对照：Funk 应该录进去）
  @Test func systemAudio() async throws {
    let env = try await Env.make()
    let (filter, _) = try await env.filter(excepting: [])
    var lines: [String] = []
    for excludes in [true, false] {
      let configuration = env.configuration(filter)
      configuration.capturesAudio = true
      configuration.excludesCurrentProcessAudio = excludes
      var played = false
      var player: AVAudioPlayer?
      let take = try await record("system-audio-\(excludes)", filter, configuration) { _ in
        try await Task.sleep(for: .milliseconds(300))
        // 本进程自己出声：AVAudioPlayer 在本进程里播（NSSound 的系统音效实测两种设置下都录不进去，测不出排除）
        player = try? AVAudioPlayer(contentsOf: URL(filePath: "/System/Library/Sounds/Funk.aiff"))
        played = player?.play() ?? false
        try await Task.sleep(for: .seconds(2.2))
        play("Glass")
        try await Task.sleep(for: .seconds(2))
      }
      let media = await inspect(take.url, split: 1.5)
      lines.append(
        "— excludesCurrentProcessAudio = \(excludes)（本进程 AVAudioPlayer 放 Funk，play() 返回 \(played)）")
      player?.stop()
      lines += take.summary + media.summary
    }
    note("系统声音：0.3 s 本 App 放 Funk、2.5 s afplay 放 Glass，按 1.5 s 分段", lines)
  }

  // MARK: - 色彩

  /// 已知 sRGB 色块（品牌粉、绿、灰阶 32 / 64 / 128 / 192），几种像素格式 × 色彩空间各录一段，取中间一帧按 sRGB 读回
  @Test func colors() async throws {
    let env = try await Env.make()
    let swatches: [(String, (Int, Int, Int))] = [
      ("品牌粉", (255, 77, 126)), ("绿", (0, 200, 0)), ("灰32", (32, 32, 32)), ("灰64", (64, 64, 64)),
      ("灰128", (128, 128, 128)), ("灰192", (192, 192, 192)),
    ]
    let panels = swatches.enumerated().map { index, swatch in
      env.panel(srgb(swatch.1), x: 0.05 + 0.15 * Double(index), width: 150)
    }
    let (filter, _) = try await env.filter(excepting: panels)
    let bgra = kCVPixelFormatType_32BGRA
    let variants: [(String, OSType?, CFString?)] = [
      ("默认（420v，不设色彩空间）", nil, nil), ("420v + sRGB", nil, CGColorSpace.sRGB),
      ("420v + ITU-R 709", nil, CGColorSpace.itur_709), ("BGRA + sRGB", bgra, CGColorSpace.sRGB),
      ("BGRA + ITU-R 709", bgra, CGColorSpace.itur_709),
    ]
    var lines: [String] = []
    for (index, variant) in variants.enumerated() {
      let configuration = env.configuration(filter)
      if let format = variant.1 { configuration.pixelFormat = format }
      if let space = variant.2 { configuration.colorSpaceName = space }
      let take = try await record("color\(index)", filter, configuration) { _ in
        try await Task.sleep(for: .seconds(2))
      }
      let media = await inspect(take.url)
      var samples: [String] = []
      if let image = await frame(take.url, at: media.duration / 2) {
        for (panel, swatch) in zip(panels, swatches) {
          let point = env.pixel(of: panel, in: image)
          if let got = pixel(image, x: point.x, y: point.y) {
            samples.append("\(swatch.0) \(got) 差 \(distance(got, swatch.1))")
          }
        }
      } else {
        samples.append("取不到帧")
      }
      lines.append("\(variant.0)：标记 \(media.colors)；" + samples.joined(separator: "；"))
    }
    for panel in panels { panel.orderOut(nil) }
    note("色彩（按 sRGB 读回，差 = 三通道绝对差之和）", lines)
  }

  // MARK: - 本 App 的窗口

  /// R4-a：排除本 App、把自家窗口列进例外。D 开录前就开着；A 开过又收起、B 从没显示过，都在 0.5 s 露出；E 开录前就开着但
  /// 不在例外里；C 在 0.5 s 新建、不在例外里，2.0 s 时换一个把 C 也列进例外的新过滤器（updateContentFilter）。
  /// 1.3 s（换过滤器之前）和结尾各取一帧，每个色块和「没有本 App 窗口时这里的背景」比，离谁近算谁
  @Test func ownWindows() async throws {
    let env = try await Env.make()
    let d = env.panel(.systemRed, x: 0.08)
    let a = env.panel(.systemBlue, x: 0.26)
    a.orderOut(nil)
    let b = env.panel(.systemYellow, x: 0.44, show: false)
    let e = env.panel(.systemPurple, x: 0.8)
    let (filter, found) = try await env.filter(excepting: [d, a, b])
    let configuration = env.configuration(filter)
    configuration.colorSpaceName = CGColorSpace.sRGB
    let background = try await SCScreenshotManager.captureImage(
      contentFilter: try await env.filter(excepting: []).0, configuration: configuration)
    var c: NSPanel?
    var updated = "没调"
    let take = try await record("own-windows", filter, configuration) { context in
      try await Task.sleep(for: .milliseconds(500))
      a.orderFrontRegardless()
      b.orderFrontRegardless()
      c = env.panel(.systemGreen, x: 0.62)
      try await Task.sleep(for: .seconds(1.5))
      do {
        let (next, _) = try await env.filter(excepting: [d, a, b, c].compactMap { $0 })
        try await context.stream.updateContentFilter(next)
        updated = "换了新过滤器（加上 C），调用成功"
      } catch {
        updated = "抛错 \(ProbeCallbacks.describe(error))"
      }
      try await Task.sleep(for: .seconds(1.5))
    }
    let media = await inspect(take.url)
    var lines = [
      "SCShareableContent(onScreenWindowsOnly: false) 找到例外窗口：D \(found[0]) · A（收起过）\(found[1]) · B（没显示过，windowNumber \(b.windowNumber)）\(found[2])",
      "录制中 updateContentFilter：\(updated)；结束回调比停止早（被停了）\(take.finishedEarly)",
    ]
    let named: [(String, NSPanel?, NSColor)] = [
      ("D 开录前开着、在例外", d, .systemRed), ("A 收起过、0.5 s 露出、在例外", a, .systemBlue),
      ("B 没显示过、0.5 s 露出、在例外", b, .systemYellow),
      ("C 0.5 s 新建、2.0 s 才加进例外", c, .systemGreen), ("E 开录前开着、不在例外", e, .systemPurple),
    ]
    for (label, time) in [("1.3 s（换过滤器前）", 1.3), ("结尾", max(0, media.duration - 0.3))] {
      guard let image = await frame(take.url, at: time) else {
        lines.append("\(label)：取不到帧")
        continue
      }
      let verdicts = named.compactMap { name, panel, color -> String? in
        guard let panel else { return nil }
        let point = env.pixel(of: panel, in: image)
        let back = env.pixel(of: panel, in: background)
        guard let got = pixel(image, x: point.x, y: point.y),
          let behind = pixel(background, x: back.x, y: back.y)
        else { return "\(name) 读不到" }
        let toPanel = distance(got, rgb(color))
        let toBehind = distance(got, behind)
        return "\(name)：\(toPanel < toBehind ? "在" : "不在")（离色块 \(toPanel)、离背景 \(toBehind)）"
      }
      lines.append("\(label)：" + verdicts.joined(separator: "；"))
    }
    for panel in [d, a, b, c, e].compactMap({ $0 }) { panel.orderOut(nil) }
    note("本 App 窗口进不进画面（排除本 App + 例外窗口）", take.summary + media.summary + lines)
  }

  // MARK: - 编码与大小

  /// H.264 60 fps 各尺寸：分清硬件上限卡的是宽、高还是面积；HEVC 5K 作参照。看实际帧率和编码进程 CPU
  @Test func encoderLimits() async throws {
    let env = try await Env.make()
    let mover = env.panel(.systemMint, x: 0.1)
    let (filter, _) = try await env.filter(excepting: [mover])
    var lines = [
      "可选编码：\(SCRecordingOutputConfiguration().availableVideoCodecTypes.map(\.rawValue))，容器：\(SCRecordingOutputConfiguration().availableOutputFileTypes.map(\.rawValue))"
    ]
    let sizes: [(Int, Int, AVVideoCodecType)] = [
      (3840, 2160, .h264), (4096, 2304, .h264), (4096, 2560, .h264), (4224, 2376, .h264),
      (4096, 2880, .h264), (4480, 2520, .h264), (2304, 4096, .h264), (2560, 4096, .h264),
      (5120, 2880, .h264), (5120, 2880, .hevc),
    ]
    for (width, height, codec) in sizes {
      let configuration = env.configuration(filter, fps: 60)
      configuration.width = width
      configuration.height = height
      var cpu = ""
      let take = try await record(
        "encoder-\(codec.rawValue)-\(width)x\(height)", filter, configuration, codec: codec
      ) { _ in
        try await animate(mover, seconds: 1.5)
        cpu = await processCPU()
        try await animate(mover, seconds: 1.5)
      }
      let media = await inspect(take.url)
      lines.append(
        "\(codec.rawValue) \(width)×\(height)（\(fmt(Double(width * height) / 1_000_000)) MP）：\(take.state.failure ?? "没报错")；实际 \(media.effectiveFPS) fps；CPU \(cpu)"
      )
      try? FileManager.default.removeItem(at: take.url)
    }
    mover.orderOut(nil)
    note("编码上限（60 fps，画面里一块色块在动；帧率上限还受画面变化本身约 58 fps 限制）", lines)
  }

  /// 大面积运动的文件大小：一块铺满可见区的「网页」一直往上滚，30 / 60 fps 各录 15 s
  @Test func heavyMotionSize() async throws {
    let env = try await Env.make()
    let (panel, page) = env.scrollingPage()
    let (filter, _) = try await env.filter(excepting: [panel])
    var lines: [String] = []
    for fps in [30, 60] {
      let take = try await record("heavy\(fps)", filter, env.configuration(filter, fps: fps)) { _ in
        try await scroll(page, in: panel, seconds: 15)
      }
      let media = await inspect(take.url)
      lines.append(
        "\(fps) fps：\(media.megabytesPerMinute) MB/分钟，实际 \(media.effectiveFPS) fps，\(Int(media.size.width))×\(Int(media.size.height))，\(fmt(media.duration)) s"
      )
      try? FileManager.default.removeItem(at: take.url)
    }
    panel.orderOut(nil)
    note("大面积运动的文件大小（整块主屏原生像素）", lines)
  }

  // MARK: - 录到一半、闪退

  /// 录制中谁开着文件（lsof）、文件里有哪些顶层 box；录到 3 s、12 s 各拷一份看能不能播
  @Test func partialFile() async throws {
    let env = try await Env.make()
    let mover = env.panel(.systemBrown, x: 0.1)
    let (filter, _) = try await env.filter(excepting: [mover])
    var lines: [String] = []
    for (fileType, marks) in [(AVFileType.mp4, [3.0, 12.0]), (.mov, [3.0])] {
      let ext = fileType == .mp4 ? "mp4" : "mov"
      var holders = ""
      var copies: [(Double, URL)] = []
      let take = try await record(
        "partial-source", filter, env.configuration(filter), fileType: fileType
      ) { context in
        var elapsed = 0.0
        for mark in marks {
          try await animate(mover, seconds: mark - elapsed)
          elapsed = mark
          if holders.isEmpty { holders = await fileHolders(context.url) }
          let copy = Self.directory.appending(path: "partial-\(Int(mark))s.\(ext)")
          try? FileManager.default.removeItem(at: copy)
          try FileManager.default.copyItem(at: context.url, to: copy)
          copies.append((mark, copy))
        }
        try await animate(mover, seconds: 2)
      }
      lines.append("\(ext)：录制中开着文件的进程 \(holders)")
      for (mark, copy) in copies {
        let partial = await inspect(copy)
        lines.append(
          "\(ext) 录到 \(Int(mark)) s 的拷贝：\(partial.bytes / 1024) KB，box \(boxes(copy))，能播 \(partial.playable)，时长 \(fmt(partial.duration)) s"
        )
      }
      let whole = await inspect(take.url)
      lines.append("\(ext) 完整文件：box \(boxes(take.url))，时长 \(fmt(whole.duration)) s")
    }
    mover.orderOut(nil)
    note("录到一半的文件", lines)
  }

  /// 真闪退：录 5 s 后 kill -9 自己（这次测试必然报崩溃）。之后用 crashInspect() 看留下的 crash.mp4
  @Test(.enabled(if: probeKill)) func crashRecording() async throws {
    let env = try await Env.make()
    let mover = env.panel(.systemGray, x: 0.1)
    let (filter, _) = try await env.filter(excepting: [mover])
    _ = try await record("crash", filter, env.configuration(filter)) { context in
      try await animate(mover, seconds: 5)
      note(
        "闪退：录制中 kill -9",
        ["\(Date.now.formatted(.iso8601))：录了 5 s，kill -9 进程 \(getpid())，文件 \(context.url.path)"])
      kill(getpid(), SIGKILL)
    }
  }

  @Test(.enabled(if: probeInspect)) func crashInspect() async throws {
    let url = Self.directory.appending(path: "crash.mp4")
    try #require(FileManager.default.fileExists(atPath: url.path), "先跑 crashRecording()")
    let media = await inspect(url)
    note(
      "闪退后留下的文件",
      ["box \(boxes(url))；现在开着它的进程 \(await fileHolders(url))"] + media.summary)
  }

  // MARK: - 小区域只为录系统声音

  /// A2-a：64×64 点的小区域、1 fps 录系统声音（3 s 短录），再把音轨无损导出成 m4a
  @Test func tinyAudioOnly() async throws {
    let env = try await Env.make()
    let (filter, _) = try await env.filter(excepting: [])
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = CGRect(x: 0, y: 0, width: 64, height: 64)
    configuration.width = 128
    configuration.height = 128
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    let take = try await record("tiny-audio", filter, configuration) { _ in
      try await Task.sleep(for: .milliseconds(500))
      play("Glass")
      try await Task.sleep(for: .seconds(2.5))
    }
    var lines = take.summary + (await inspect(take.url)).summary
    for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
      let out = Self.directory.appending(path: "tiny-audio-\(preset).m4a")
      try? FileManager.default.removeItem(at: out)
      let started = Date.now
      do {
        let asset = AVURLAsset(url: take.url)
        let composition = AVMutableComposition()
        let source = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let range = try await source.load(.timeRange)
        let track = try #require(
          composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(range, of: source, at: .zero)
        let session = try #require(AVAssetExportSession(asset: composition, presetName: preset))
        try await session.export(to: out, as: .m4a)
        let exported = await inspect(out)
        lines.append(
          "导出 \(preset)：成功，\(ms(since: started)) ms；" + exported.summary.joined(separator: "；"))
      } catch {
        lines.append("导出 \(preset)：失败 \(ProbeCallbacks.describe(error))")
      }
    }
    note("小区域 1 fps 只为录系统声音（A2-a，3 s 短录）", lines)
  }

  // MARK: - 麦克风（KITTY_LIVE_RECORD_MIC）

  /// 先测 AVAudioRecorder（设备闲置了一阵，第一次算冷启动；三次看耗时，默认码率 / 固定码率看实际码率，读 3 s 电平），
  /// 再用系统录制管线录：只录系统声音（对照）、麦克风 + 系统声音、只录麦克风，都不挂样本输出；Glass 在 0.5 s 之后才放，
  /// 所以 0–0.4 s 只录系统声音应是数字静音，有麦克风就该有底噪
  @Test(.enabled(if: probeMicrophone)) func microphone() async throws {
    let before = AVCaptureDevice.authorizationStatus(for: .audio)
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    let device = AVCaptureDevice.default(for: .audio)
    var lines = [
      "授权：之前 \(before.rawValue)（0 没问过 / 2 拒绝 / 3 允许），现在 \(granted ? "允许" : "拒绝")",
      "默认输入：\(device?.localizedName ?? "无")，transportType \(device.map { fourCC(UInt32(bitPattern: $0.transportType)) } ?? "")",
    ]
    try #require(granted, "麦克风没授权")
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

    for (index, constant) in [false, false, true].enumerated() {
      let url = Self.directory.appending(path: "recorder\(index).m4a")
      try? FileManager.default.removeItem(at: url)
      var settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
      ]
      if constant { settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant }
      var started = Date.now
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.isMeteringEnabled = true
      let prepared = recorder.prepareToRecord()
      let prepareMs = ms(since: started)
      started = .now
      let recording = recorder.record()
      let recordMs = ms(since: started)
      var powers: [Float] = []
      for step in 0..<30 {
        if index == 0, step == 15 {
          recorder.pause()
          try await Task.sleep(for: .seconds(1))
          recorder.record()
        }
        try await Task.sleep(for: .milliseconds(100))
        recorder.updateMeters()
        powers.append(recorder.averagePower(forChannel: 0))
      }
      recorder.stop()
      try await Task.sleep(for: .milliseconds(300))
      let media = await inspect(url)
      let sorted = powers.sorted()
      lines.append(
        "AVAudioRecorder 第 \(index + 1) 次\(constant ? "（固定码率）" : "")：init + prepareToRecord \(prepared) \(prepareMs) ms，record() \(recording) \(recordMs) ms；\(index == 0 ? "录 1.5 s、停 1 s、再录 1.5 s → " : "")时长 \(fmt(media.duration)) s，实际码率 \(media.audioKbps) kbps；电平 最低 \(fmt(Double(sorted.first ?? 0))) / 中位 \(fmt(Double(sorted[sorted.count / 2]))) / 最高 \(fmt(Double(sorted.last ?? 0))) dB"
      )
    }

    let env = try await Env.make()
    let (filter, _) = try await env.filter(excepting: [])
    for (name, system, mic) in [
      ("只录系统声音（对照）", true, false), ("麦克风 + 系统声音", true, true), ("只录麦克风", false, true),
    ] {
      let configuration = env.configuration(filter)
      configuration.capturesAudio = system
      configuration.excludesCurrentProcessAudio = true
      configuration.captureMicrophone = mic
      let take = try await record("mic-\(system)-\(mic)", filter, configuration) { _ in
        try await Task.sleep(for: .milliseconds(500))
        if system { play("Glass") }
        try await Task.sleep(for: .seconds(3))
      }
      let media = await inspect(take.url, split: 0.4)
      lines.append("— \(name)（不挂样本输出）")
      lines += take.summary + media.summary
    }
    note("麦克风", lines)
  }

  // MARK: - 录屏第 1 批：ScreenRecorder 真录

  /// ScreenRecorder 真录 2 s（主屏可见区里 640 × 360 点的一块）：先倒数 1 s（第 2 批：录制 HUD 是倒数态、还没有停止项），
  /// 数完才开流，所以文件仍约 2 s（倒数不进文件）；文件挪进输出目录的 recorder/、能播、尺寸 = 点 × 缩放、编码 avc1；
  /// 「进行中」记录和录屏设置都在临时偏好域、收尾后删掉。录制中连本 App 一起截一张整屏（recorder-chrome.png 和三块局部：
  /// 菜单栏停止项、选区边框、录制 HUD），看停止项、边框、HUD 画得对不对；停下后 HUD 和停止项都立刻收掉。只跑这一个：
  ///   -only-testing:KittyToolsTests/RecordingProbeTests/screenRecorderTake()
  @Test func screenRecorderTake() async throws {
    let env = try await Env.make()
    let suite = "kitty-test-record-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(1, forKey: Prefs.screenRecordCountdown)
    defaults.set(30, forKey: Prefs.screenRecordFrameRate)
    defaults.set(true, forKey: Prefs.screenRecordShowsCursor)
    // 第 4 批：录制条的三个开关全开（麦克风要已授权：没授权时 ScreenRecorder 会照样开录、不带麦克风，下面的底噪断言会失败）
    defaults.set(true, forKey: Prefs.screenRecordSystemAudio)
    defaults.set(true, forKey: Prefs.screenRecordMicrophone)
    defaults.set(true, forKey: Prefs.screenRecordShowsClicks)
    try #require(
      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Dev 版没有麦克风授权")
    let since = Date.now
    let folder = Self.directory.appending(path: "recorder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let visible = env.screen.visibleFrame
    let region = CGRect(x: visible.minX + 240, y: visible.midY - 180, width: 640, height: 360)
    // 选区里两块本 App 的窗口：左边普通 NSWindow（设置窗的类，在白名单里，要录进去）、右边 NSPanel（不在白名单，不录）
    let listed = NSWindow(
      contentRect: CGRect(x: region.minX + 60, y: region.midY - 60, width: 160, height: 120),
      styleMask: [.borderless], backing: .buffered, defer: false)
    listed.backgroundColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    listed.level = .floating
    listed.isReleasedWhenClosed = false
    listed.orderFrontRegardless()
    let unlisted = NSPanel(
      contentRect: CGRect(x: region.maxX - 220, y: region.midY - 60, width: 160, height: 120),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    unlisted.backgroundColor = NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1)
    unlisted.level = .floating
    unlisted.isReleasedWhenClosed = false
    unlisted.orderFrontRegardless()
    defer {
      listed.orderOut(nil)
      unlisted.orderOut(nil)
    }
    var finished: ScreenRecorder.Result?
    let recorder = try #require(
      ScreenRecorder(region: region, directory: folder, defaults: defaults) { finished = $0 })
    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
    recorder.start()
    #expect(defaults.string(forKey: Prefs.screenRecordingInProgress) != nil)
    // 倒数：HUD 先出来（倒数态），停止项还没有
    var hudWindow: NSWindow?
    for _ in 0..<20 where hudWindow == nil {
      try await Task.sleep(for: .milliseconds(25))
      hudWindow = NSApp.windows.first { Self.hud(in: $0) != nil && $0.isVisible }
    }
    let hud = try #require(hudWindow.flatMap(Self.hud(in:)), "倒数时没出 HUD")
    #expect(hud.state == .countdown(1))
    #expect(
      !NSApp.windows.contains {
        String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.isVisible
          && !existing.contains(ObjectIdentifier($0))
      })
    // 开始了才出停止项：新出来的那个状态栏窗口
    var stopItem: NSWindow?
    for _ in 0..<100 where stopItem == nil {
      try await Task.sleep(for: .milliseconds(50))
      stopItem = NSApp.windows.first {
        String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.isVisible
          && !existing.contains(ObjectIdentifier($0))
      }
    }
    let item = try #require(stopItem, "5 s 内没开始录")
    let began = Date.now
    guard case .recording = hud.state else {
      Issue.record("开录后 HUD 不是录制态：\(hud.state)")
      return
    }
    // 头 1 s 让左边那块来回挪（画面在动才出新帧），之后停在原位
    let origin = listed.frame.origin
    for step in 0..<60 {
      if step == 30 { play("Glass") }  // 约 0.5 s：别的进程出声，系统声音录得进去
      listed.setFrameOrigin(CGPoint(x: origin.x + CGFloat(step % 20) * 3, y: origin.y))
      try await Task.sleep(for: .milliseconds(16))
    }
    listed.setFrameOrigin(origin)
    // 连本 App 一起截：停止项、边框
    let filter = SCContentFilter(display: env.display, excludingWindows: [])
    let chrome = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: env.configuration(filter))
    let screen = env.screen.frame
    let k = CGFloat(chrome.width) / screen.width
    func crop(_ rect: CGRect) -> CGImage? {
      chrome.cropping(
        to: CGRect(
          x: (rect.minX - screen.minX) * k, y: (screen.maxY - rect.maxY) * k,
          width: rect.width * k, height: rect.height * k
        ).integral)
    }
    try save(chrome, "recorder-chrome.png")
    if let bar = crop(item.frame.insetBy(dx: -40, dy: 0)) {
      try save(bar, "recorder-stop-item.png")
    }
    if let corner = crop(
      CGRect(x: region.minX - 30, y: region.maxY - 90, width: 120, height: 120))
    {
      try save(corner, "recorder-border.png")
    }
    if let hudWindow, let shot = crop(hudWindow.frame.insetBy(dx: -24, dy: -24)) {
      try save(shot, "recorder-hud.png")
    }
    try await Task.sleep(for: .seconds(max(0, 2 - Date.now.timeIntervalSince(began))))
    recorder.stop()
    for _ in 0..<300 where finished == nil { try await Task.sleep(for: .milliseconds(50)) }
    let result = try #require(finished, "15 s 内没收尾")
    #expect(result.reason == .user && result.moved)
    #expect(defaults.string(forKey: Prefs.screenRecordingInProgress) == nil)
    #expect(!NSApp.windows.contains { ($0 === item || $0 === hudWindow) && $0.isVisible })
    let file = try #require(result.file)
    let media = await inspect(file)
    let scale = env.screen.backingScaleFactor
    #expect(file.lastPathComponent.hasPrefix("录屏 ") && file.pathExtension == "mp4")
    #expect(media.playable && media.codec == "avc1")
    #expect(abs(media.duration - 2) < 0.4, "时长 \(media.duration)")
    #expect(media.size == CGSize(width: 640 * scale, height: 360 * scale))
    // 第 4 批：系统声音 + 麦克风混成一条音轨；Glass 在 0.5 s 后才响，前 0.4 s 不是数字静音就是麦克风的底噪
    #expect(media.audioTracks == 1, "音轨 \(media.audioTracks)")
    let asset = AVURLAsset(url: file)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let head = try #require(peak(asset, track, to: 0.4), "读不出前 0.4 s 的音频")
    #expect(head > 0, "前 0.4 s 是数字静音：麦克风没录进去")
    let whole = peak(asset, track)
    let logs = await notFoundLogs(since: since)
    // 结尾那一帧：白名单里的窗口录进去了，不在白名单的没有（和背景比只记下来，桌面颜色可能碰巧相近）。
    // 按视频轨的结束取（第 4 批：录了声音、画面后来不动时视频轨比文件短，停在最后一次画面变化）
    let videoRange = try #require(
      try await asset.loadTracks(withMediaType: .video).first?.load(.timeRange))
    let videoEnd = videoRange.end.seconds
    let last = try #require(await frame(file, at: max(0, videoEnd - 0.3)))
    let at = { (window: NSWindow) in
      pixel(
        last, x: Int((window.frame.midX - region.minX) * scale),
        y: Int((region.maxY - window.frame.midY) * scale))
    }
    let red = try #require(at(listed))
    #expect(red.0 > 180 && red.1 < 80 && red.2 < 80, "白名单窗口没录进去：\(red)")
    let green = at(unlisted).map { "\($0)" } ?? "读不到"
    // 第 3 批：挪进目录后取的最后一帧（飞入和视频卡用）：尺寸按选区像素、长边不超过 1600，红色窗口在里面
    let poster = try #require(result.poster, "没取到最后一帧")
    try save(poster, "recorder-poster.png")
    #expect(
      CGSize(width: poster.width, height: poster.height) == ScreenRecorder.posterLimit(media.size))
    let perPoint = CGFloat(poster.width) / region.width
    let posterRed = try #require(
      pixel(
        poster, x: Int((listed.frame.midX - region.minX) * perPoint),
        y: Int((region.maxY - listed.frame.midY) * perPoint)))
    #expect(
      posterRed.0 > 180 && posterRed.1 < 80 && posterRed.2 < 80, "最后一帧里没有红色窗口：\(posterRed)")
    note(
      "ScreenRecorder 真录（录屏第 1 批）",
      [
        "结果：\(result.reason)，挪进输出目录 \(result.moved)，会话计的时长 \(result.duration)，文件 \(file.lastPathComponent)",
        "先倒数 1 s 再开流：文件时长 \(String(format: "%.2f", media.duration)) s（录 2 s；倒数进了文件会是 3 s 左右）",
        "结尾一帧：白名单里的 NSWindow（红 230,26,26）读回 \(red)；不在白名单的 NSPanel（绿 26,204,51）处读回 \(green)",
        "最后一帧（第 3 批 poster）：\(poster.width)×\(poster.height)，红色窗口处读回 \(posterRed)",
        "第 4 批：系统声音 + 麦克风 + 显示点按全开：视频轨到 \(String(format: "%.2f", videoEnd)) s（画面 1 s 后不动），音轨 \(media.audioTracks) 条，前 0.4 s 峰值 \(decibels(head))（麦克风底噪），整段 \(decibels(whole))（0.5 s 放了 Glass）；这段时间日志「NOT found」\(logs)",
      ] + media.summary)
  }

  // MARK: - 手测反馈第 1 批：点按圈录进画面

  /// 开着显示点按真录约 2 s（不倒数、不录声音、不画光标；主屏可见区里 640 × 360 点），选区里垫一块白色的白名单窗口。
  /// 开录后直接调 InputOverlay 的入口（不发合成鼠标事件、不真点任何东西）：左键按在白窗口左半、右键按在右半，1.2 s 时把
  /// 左键的圈拖到下面一点；另带动画轻点一下中键，停之前它的图层已经移除（真显示着的窗口里松开动画放得完）。从 mp4 取两帧：
  /// - 0.5 s（每秒换过滤器的第一次检查之前）：左键处是掺了强调色的白、圈上有强调色，右键处中心还是白（空心环）、圈上有
  ///   强调色——开流那次的过滤器就把这层状态栏以上的窗口列进了例外；
  /// - 结尾：圆盘到了新位置，原位置回到白。
  /// 录制中另拍一次截图冻结帧（ScreenCapture.freeze）：圈不在里面（按层级不收），白窗口在。文件带色彩标记（不再用 BGRA）。
  /// 停下后覆盖层立刻收掉。录下的视频验完就删（两帧存成 clicks-early.png / clicks-last.png，看完自己删）。只跑这一个：
  ///   -only-testing:'KittyToolsTests/RecordingProbeTests/inputOverlayTake()'
  @Test func inputOverlayTake() async throws {
    let env = try await Env.make()
    let suite = "kitty-test-clicks-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(0, forKey: Prefs.screenRecordCountdown)
    defaults.set(30, forKey: Prefs.screenRecordFrameRate)
    defaults.set(false, forKey: Prefs.screenRecordShowsCursor)
    defaults.set(false, forKey: Prefs.screenRecordSystemAudio)
    defaults.set(false, forKey: Prefs.screenRecordMicrophone)
    defaults.set(true, forKey: Prefs.screenRecordShowsClicks)
    let folder = Self.directory.appending(path: "clicks")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let visible = env.screen.visibleFrame
    let region = CGRect(x: visible.minX + 240, y: visible.midY - 180, width: 640, height: 360)
    // 白底：普通 NSWindow（设置窗的类，在白名单里），圈压在它上面颜色才算得准
    let ground = NSWindow(
      contentRect: region.insetBy(dx: 40, dy: 40), styleMask: [.borderless], backing: .buffered,
      defer: false)
    ground.backgroundColor = .white
    ground.level = .floating
    ground.isReleasedWhenClosed = false
    ground.orderFrontRegardless()
    defer { ground.orderOut(nil) }
    var finished: ScreenRecorder.Result?
    let recorder = try #require(
      ScreenRecorder(region: region, directory: folder, defaults: defaults) { finished = $0 })
    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
    recorder.start()
    // 开始了才出停止项
    var stopItem: NSWindow?
    for _ in 0..<100 where stopItem == nil {
      try await Task.sleep(for: .milliseconds(50))
      stopItem = NSApp.windows.first {
        String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.isVisible
          && !existing.contains(ObjectIdentifier($0))
      }
    }
    try #require(stopItem != nil, "5 s 内没开始录")
    let began = Date.now
    let overlay = try #require(recorder.inputOverlay, "开着显示点按却没有覆盖层")
    let panel = overlay.panel
    let covered = panel.frame
    #expect(panel.isVisible)
    let left = CGPoint(x: region.minX + 200, y: region.midY + 40)
    let right = CGPoint(x: region.maxX - 200, y: region.midY + 40)
    let dragged = CGPoint(x: left.x + 60, y: left.y - 100)
    overlay.press(0, at: left)
    overlay.press(1, at: right)
    // 再带动画轻点一下中键（按下紧跟松开）：真显示着的窗口里圈等满最短显示、淡出后图层移除（停之前看，只剩按着的两个）
    overlay.press(2, at: CGPoint(x: region.midX, y: region.midY - 80))
    overlay.release(2)
    #expect(overlay.markCount == (Style.reduceMotion ? 3 : 4))
    try await Task.sleep(for: .seconds(1.2))
    // 截图冻结帧：圈不在里面（层级在状态栏以上，keptOwnWindows 不收），白窗口在
    let shots = try await ScreenCapture.freeze()
    let shot = try #require(shots.first { $0.screen == env.screen }).image
    let perPoint = CGFloat(shot.width) / env.screen.frame.width
    let frozen = try #require(
      pixel(
        shot, x: Int((left.x - env.screen.frame.minX) * perPoint),
        y: Int((env.screen.frame.maxY - left.y) * perPoint)))
    #expect(distance(frozen, (255, 255, 255)) < 12, "冻结帧里有点按圈：\(frozen)")
    overlay.move(0, to: dragged)
    try await Task.sleep(for: .seconds(max(0, 2 - Date.now.timeIntervalSince(began))))
    #expect(overlay.markCount == 2, "轻点的圈放完没移除：还有 \(overlay.markCount) 个图层")
    recorder.stop()
    for _ in 0..<300 where finished == nil { try await Task.sleep(for: .milliseconds(50)) }
    let result = try #require(finished, "15 s 内没收尾")
    #expect(result.reason == .user && result.moved)
    // 覆盖层盖住被录的区域（对齐到像素后的选区；窗口的 frame 被 AppKit 取成整点，最多大出 1 pt），停下后收掉
    #expect(
      covered.contains(result.region) && result.region.insetBy(dx: -1, dy: -1).contains(covered),
      "覆盖层 \(covered)，被录区域 \(result.region)")
    #expect(recorder.inputOverlay == nil && !panel.isVisible)
    let file = try #require(result.file)
    defer { try? FileManager.default.removeItem(at: file) }
    let media = await inspect(file)
    #expect(media.playable && media.codec == "avc1")
    #expect(!media.colors.contains("无"), "文件不带色彩标记：\(media.colors)")
    let scale = env.screen.backingScaleFactor
    let accent = rgb(Style.Shot.accent)
    // 圆盘填的是掺了 30% 白的强调色、0.5 不透明：白底上 = 白 0.65 + 强调色 0.35
    let tinted = (
      Int(255 * 0.65 + Double(accent.0) * 0.35), Int(255 * 0.65 + Double(accent.1) * 0.35),
      Int(255 * 0.65 + Double(accent.2) * 0.35)
    )
    /// 画面里 point（全局坐标）往 angle 方向 radius 点处的像素
    func at(_ image: CGImage, _ point: CGPoint, radius: CGFloat = 0, angle: Double = 0)
      -> (Int, Int, Int)?
    {
      pixel(
        image, x: Int((point.x + radius * cos(angle) - region.minX) * scale),
        y: Int((region.maxY - point.y - radius * sin(angle)) * scale))
    }
    /// 圈上（描边中线）八个方向里离强调色最近的那个像素差多少
    func ring(_ image: CGImage, _ point: CGPoint, radius: CGFloat) -> Int {
      (0..<8).compactMap { at(image, point, radius: radius, angle: Double($0) * .pi / 4) }
        .map { distance($0, accent) }.min() ?? .max
    }
    let early = try #require(await frame(file, at: 0.5), "取不到 0.5 s 的帧")
    try save(early, "clicks-early.png")
    let disc = try #require(at(early, left))
    let hollow = try #require(at(early, right))
    #expect(distance(disc, tinted) < 60, "0.5 s 左键处不是圆盘的颜色：\(disc)，应约 \(tinted)")
    #expect(distance(disc, (255, 255, 255)) > 40, "0.5 s 左键处还是白的：\(disc)")
    #expect(distance(hollow, (255, 255, 255)) < 30, "右键的空心环中间不该有填充：\(hollow)")
    let discRing = ring(early, left, radius: 21)
    let hollowRing = ring(early, right, radius: 20.5)
    #expect(discRing < 90 && hollowRing < 90, "圈上没有强调色：\(discRing) / \(hollowRing)")
    let videoRange = try #require(
      try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first?.load(.timeRange))
    let last = try #require(await frame(file, at: max(0, videoRange.end.seconds - 0.05)))
    try save(last, "clicks-last.png")
    let moved = try #require(at(last, dragged))
    let vacated = try #require(at(last, left))
    #expect(distance(moved, tinted) < 60, "拖动后新位置不是圆盘的颜色：\(moved)")
    #expect(distance(vacated, (255, 255, 255)) < 30, "拖走后原位置还有圈：\(vacated)")
    note(
      "点按圈录进画面（手测反馈第 1 批，InputOverlay）",
      [
        "强调色 \(accent)，白底上的圆盘应约 \(tinted)；覆盖层窗口层级 \(panel.level.rawValue)",
        "0.5 s 的帧：左键圆盘中心 \(disc)、圈上离强调色最近差 \(discRing)；右键空心环中心 \(hollow)、圈上差 \(hollowRing)",
        "结尾的帧（视频轨到 \(String(format: "%.2f", videoRange.end.seconds)) s）：拖到的新位置 \(moved)，原位置 \(vacated)",
        "录制中的截图冻结帧左键处 \(frozen)（白 = 圈没被截进去）",
      ] + media.summary)
  }

  // MARK: - 录音第 5 批：AudioRecorder 真录

  /// AudioRecorder 真录（要麦克风授权，Dev 版已有，不会弹框）：录 1.5 s、暂停 1 s、再录 1.5 s——文件挪进输出目录的 audio/
  /// 「录音 ….m4a」、能播、时长约 3 s（暂停那 1 s 不进文件）、AAC 48 kHz 单声道、码率约 128 kbps；会话计的时长也不算暂停；
  /// 录制中（0.3 s 放一声 Glass，电平有起伏）截一张 HUD（audio-hud.png：鼠标所在屏底部居中、[● 计时][电平] ｜ [⏸] ｜ [✕][■]），
  /// 停下后 HUD 和菜单栏停止项立刻收掉、波形 poster 400 × 250（audio-poster.png）。「进行中」记录在临时偏好域、收尾后删掉；
  /// 录下的音频验完就删（两张截图看完自己删）。只跑这一个：
  ///   -only-testing:'KittyToolsTests/RecordingProbeTests/audioRecorderTake()'
  @Test(.enabled(if: probeMicrophone)) func audioRecorderTake() async throws {
    let env = try await Env.make()
    try #require(
      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Dev 版没有麦克风授权")
    let suite = "kitty-test-audio-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folder = Self.directory.appending(path: "audio")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var finished: ScreenRecorder.Result?
    let recorder = AudioRecorder(directory: folder, defaults: defaults) { finished = $0 }
    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
    let began = Date.now
    recorder.start()
    #expect(defaults.string(forKey: Prefs.audioRecordingInProgress) != nil)
    var hudWindow: NSWindow?
    for _ in 0..<100 where hudWindow == nil {
      try await Task.sleep(for: .milliseconds(10))
      hudWindow = NSApp.windows.first {
        Self.hud(in: $0)?.medium == .audio && $0.isVisible
      }
    }
    let hud = try #require(hudWindow.flatMap(Self.hud(in:)), "1 s 内没出录音 HUD")
    let latency = ms(since: began)
    let stopItem = NSApp.windows.first {
      String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.isVisible
        && !existing.contains(ObjectIdentifier($0))
    }
    #expect(stopItem != nil, "没有菜单栏停止项")
    try await Task.sleep(for: .seconds(0.3))
    play("Glass")
    try await Task.sleep(for: .seconds(1.2))
    // 连本 App 一起截 HUD（在主屏上才截）
    if env.screen.frame.contains(hud.screenFrame) {
      let filter = SCContentFilter(display: env.display, excludingWindows: [])
      let shot = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: env.configuration(filter))
      let screen = env.screen.frame
      let k = CGFloat(shot.width) / screen.width
      let rect = hud.screenFrame.insetBy(dx: -24, dy: -24)
      if let crop = shot.cropping(
        to: CGRect(
          x: (rect.minX - screen.minX) * k, y: (screen.maxY - rect.maxY) * k,
          width: rect.width * k, height: rect.height * k
        ).integral)
      {
        try save(crop, "audio-hud.png")
      }
    }
    recorder.togglePause()
    #expect(recorder.isPaused && hud.isPaused)
    try await Task.sleep(for: .seconds(1))
    recorder.togglePause()
    #expect(!recorder.isPaused && !hud.isPaused)
    try await Task.sleep(for: .seconds(1.5))
    recorder.stop()
    for _ in 0..<100 where finished == nil { try await Task.sleep(for: .milliseconds(20)) }
    let result = try #require(finished, "2 s 内没收尾")
    #expect(result.reason == .user && result.moved)
    #expect(defaults.string(forKey: Prefs.audioRecordingInProgress) == nil)
    #expect(!NSApp.windows.contains { ($0 === hudWindow || $0 === stopItem) && $0.isVisible })
    let file = try #require(result.file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(file.lastPathComponent.hasPrefix("录音 ") && file.pathExtension == "m4a")
    #expect(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    let asset = AVURLAsset(url: file)
    let playable = try await asset.load(.isPlayable)
    let duration = try await asset.load(.duration).seconds
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    let stream = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    let rate = try await track.load(.estimatedDataRate)
    #expect(playable)
    #expect(abs(duration - 3) < 0.4, "时长 \(duration)")
    let session =
      Double(result.duration.components.seconds)
      + Double(result.duration.components.attoseconds) * 1e-18
    #expect(abs(session - 3) < 0.4, "会话计的时长 \(result.duration)")
    #expect(stream.mFormatID == kAudioFormatMPEG4AAC)
    #expect(stream.mSampleRate == 48_000 && stream.mChannelsPerFrame == 1)
    #expect(rate > 110_000 && rate < 150_000, "码率 \(rate)")
    let poster = try #require(result.poster, "没有波形 poster")
    #expect(poster.width == 400 && poster.height == 250)
    try save(poster, "audio-poster.png")
    let region = result.region
    #expect(
      region.height == hud.screenFrame.height && abs(region.width / region.height - 1.6) < 0.05)
    let head = peak(asset, track, to: 0.25)
    note(
      "AudioRecorder 真录（录音第 5 批）",
      [
        "结果：\(result.reason)，挪进输出目录 \(result.moved)，文件 \(file.lastPathComponent)，HUD 在开录后 \(latency) ms 出来",
        "录 1.5 s、暂停 1 s、再录 1.5 s：文件时长 \(fmt(duration)) s，会话计的时长 \(result.duration)（都不算暂停）",
        "音轨 \(fourCC(stream.mFormatID)) \(Int(stream.mSampleRate)) Hz \(stream.mChannelsPerFrame) 声道，码率约 \(Int(rate / 1000)) kbps，开头 0.25 s 峰值 \(decibels(head))",
        "波形 poster \(poster.width)×\(poster.height)，飞入起点 \(region)",
      ])
  }

  // MARK: - 录音第 6 批：系统声音 / 两者走录屏管线

  /// AudioRecorder 的来源是系统声音 / 两者（要「屏幕录制」和麦克风授权，Dev 版都有，不会弹框）：录屏管线只录声音（鼠标所在屏
  /// 左上角 64 × 64 点、1 fps），录约 2 s、0.5 s 时 afplay 放一声 Glass——HUD 出来且 ⏸ 置灰、菜单栏有停止项；停下后 HUD 和停止项
  /// 立刻收掉，m4a 挪进输出目录的 audio-<来源>/「录音 ….m4a」、能播、只有一条 AAC 音轨、没有视频轨、时长约 2 s（和会话计的一致）、
  /// 中间的 mp4 不在了；电平事件来过（Glass 那一下到 −60 dB 以上），两者时麦克风的底噪算「听到了」（只录系统声音不看）；
  /// 波形 poster 400 × 250；再开一次、HUD 出来之前马上叫停：当取消、不留文件。「进行中」记录和来源都在临时偏好域。录下的音频
  /// 验完就删（HUD 截图看完自己删）。只跑这个：
  ///   -only-testing:'KittyToolsTests/RecordingProbeTests/audioRecorderSystemTake(_:)'
  @Test(.enabled(if: probeMicrophone), arguments: [AudioRecorder.Source.system, .both])
  func audioRecorderSystemTake(_ source: AudioRecorder.Source) async throws {
    let env = try await Env.make()
    try #require(
      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Dev 版没有麦克风授权")
    let suite = "kitty-test-audio-system-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(source.rawValue, forKey: Prefs.audioRecordSource)
    let folder = Self.directory.appending(path: "audio-\(source.rawValue)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var finished: ScreenRecorder.Result?
    let recorder = AudioRecorder(directory: folder, defaults: defaults) { finished = $0 }
    #expect(recorder.source == source)
    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
    let began = Date.now
    recorder.start()
    let working = try #require(defaults.string(forKey: Prefs.audioRecordingInProgress))
    #expect(working.hasSuffix(".mp4"))
    var hudWindow: NSWindow?
    for _ in 0..<250 where hudWindow == nil {
      try await Task.sleep(for: .milliseconds(20))
      hudWindow = NSApp.windows.first { Self.hud(in: $0)?.medium == .audio && $0.isVisible }
    }
    let hud = try #require(hudWindow.flatMap(Self.hud(in:)), "5 s 内没出录音 HUD")
    let latency = ms(since: began)
    let started = Date.now
    #expect(try #require(hud.button(for: .pause)).isEnabled == false)
    let stopItem = NSApp.windows.first {
      String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.isVisible
        && !existing.contains(ObjectIdentifier($0))
    }
    #expect(stopItem != nil, "没有菜单栏停止项")
    try await Task.sleep(for: .seconds(0.5))
    play("Glass")
    try await Task.sleep(for: .seconds(1))
    if env.screen.frame.contains(hud.screenFrame) {
      let filter = SCContentFilter(display: env.display, excludingWindows: [])
      let shot = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: env.configuration(filter))
      let screen = env.screen.frame
      let k = CGFloat(shot.width) / screen.width
      let rect = hud.screenFrame.insetBy(dx: -24, dy: -24)
      if let crop = shot.cropping(
        to: CGRect(
          x: (rect.minX - screen.minX) * k, y: (screen.maxY - rect.maxY) * k,
          width: rect.width * k, height: rect.height * k
        ).integral)
      {
        try save(crop, "audio-\(source.rawValue)-hud.png")
      }
    }
    try await Task.sleep(for: .seconds(max(0, 2 - Date.now.timeIntervalSince(started))))
    recorder.stop()
    for _ in 0..<500 where finished == nil { try await Task.sleep(for: .milliseconds(20)) }
    let result = try #require(finished, "10 s 内没收尾")
    #expect(result.reason == .user && result.moved)
    #expect(defaults.string(forKey: Prefs.audioRecordingInProgress) == nil)
    #expect(AudioRecorder.Source(defaults) == source)
    #expect(!NSApp.windows.contains { ($0 === hudWindow || $0 === stopItem) && $0.isVisible })
    let file = try #require(result.file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(file.lastPathComponent.hasPrefix("录音 ") && file.pathExtension == "m4a")
    #expect(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    #expect(!FileManager.default.fileExists(atPath: working), "中间的 mp4 还在")
    let asset = AVURLAsset(url: file)
    let playable = try await asset.load(.isPlayable)
    let duration = try await asset.load(.duration).seconds
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(audioTracks.first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    let stream = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    let session =
      Double(result.duration.components.seconds)
      + Double(result.duration.components.attoseconds) * 1e-18
    #expect(playable && audioTracks.count == 1 && videoTracks.isEmpty)
    #expect(stream.mFormatID == kAudioFormatMPEG4AAC)
    #expect(abs(duration - 2) < 0.4, "时长 \(duration)")
    #expect(abs(duration - session) < 0.3, "文件 \(duration) s，会话计的 \(session) s")
    let loudest = recorder.levels.envelope.max() ?? -120
    #expect(loudest > -60, "电平没来：最响 \(loudest) dB")
    #expect(recorder.levels.heard == (source == .both), "麦克风那一路「听到了」\(recorder.levels.heard)")
    let poster = try #require(result.poster, "没有波形 poster")
    #expect(poster.width == 400 && poster.height == 250)
    let whole = peak(asset, track)
    // HUD 出来之前就叫停（评审 C2：刚按下录音马上再按）：当取消，同只录麦克风——不留文件、不飞卡片、删「进行中」记录
    var early: ScreenRecorder.Result?
    let quick = AudioRecorder(directory: folder, defaults: defaults) { early = $0 }
    quick.start()
    let quickWorking = try #require(defaults.string(forKey: Prefs.audioRecordingInProgress))
    quick.stop()
    for _ in 0..<500 where early == nil { try await Task.sleep(for: .milliseconds(20)) }
    let cancelled = try #require(early, "马上叫停的 10 s 内没收尾")
    #expect(cancelled.reason == .cancelled && cancelled.file == nil && cancelled.poster == nil)
    #expect(defaults.string(forKey: Prefs.audioRecordingInProgress) == nil)
    #expect(!FileManager.default.fileExists(atPath: quickWorking))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
        $0.hasPrefix("录音 ")
      } == [file.lastPathComponent])
    note(
      "AudioRecorder 录屏管线只录声音（录音第 6 批，来源 \(source.rawValue)）",
      [
        "结果：\(result.reason)，挪进输出目录 \(result.moved)，文件 \(file.lastPathComponent)，HUD 在开录后 \(latency) ms 出来（等流开起来）",
        "m4a：能播 \(playable)，时长 \(fmt(duration)) s（会话计的 \(fmt(session)) s），音轨 \(audioTracks.count) 条（\(fourCC(stream.mFormatID)) \(Int(stream.mSampleRate)) Hz \(stream.mChannelsPerFrame) 声道）、视频轨 \(videoTracks.count) 条，整段峰值 \(decibels(whole))；中间的 mp4 已删",
        "电平：包络 \(recorder.levels.envelope.count) 桶，最响 \(fmt(Double(loudest))) dB，麦克风那一路听到了 \(recorder.levels.heard)",
        "HUD 出来之前叫停：\(cancelled.reason)，没有留下文件",
      ])
  }

  // MARK: - 录屏录音第 7 批：转成 GIF

  /// ScreenRecorder 真录 2 s（1280 × 720 点，2x 屏上 2560 × 1440 像素，画面一直在动）后用 VideoExport 转 GIF：帧数约 30、
  /// 宽 ≤ 960（这里是 960 × 540）、循环播放、每帧约 1/15 s，存盘名「录屏 <开录时刻>.gif」；再录一段带系统声音、只动头 1 s 的
  /// （视频轨停在最后一次画面变化、比文件短），验最后一帧停到结尾、总长仍约 2 s；转到一半取消不留文件。报告里记转换耗时。
  /// 录下的视频和 GIF 验完就删。只跑这一个：
  ///   -only-testing:'KittyToolsTests/RecordingProbeTests/gifTake()'
  @Test func gifTake() async throws {
    let env = try await Env.make()
    let suite = "kitty-test-gif-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(0, forKey: Prefs.screenRecordCountdown)
    defaults.set(30, forKey: Prefs.screenRecordFrameRate)
    defaults.set(false, forKey: Prefs.screenRecordMicrophone)
    defaults.set(false, forKey: Prefs.screenRecordShowsClicks)
    let folder = Self.directory.appending(path: "gif")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let visible = env.screen.visibleFrame
    let region = CGRect(x: visible.minX + 120, y: visible.midY - 360, width: 1280, height: 720)
    let panel = NSPanel(
      contentRect: CGRect(x: region.minX + 80, y: region.midY - 80, width: 240, height: 160),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }

    /// 录一段：moving 秒内画面一直动，总共录 2 s；返回挪进 folder 的文件
    func take(systemAudio: Bool, moving: Double) async throws -> URL {
      defaults.set(systemAudio, forKey: Prefs.screenRecordSystemAudio)
      var finished: ScreenRecorder.Result?
      let recorder = try #require(
        ScreenRecorder(region: region, directory: folder, defaults: defaults) { finished = $0 })
      let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
      recorder.start()
      var stopItem: NSWindow?
      for _ in 0..<100 where stopItem == nil {
        try await Task.sleep(for: .milliseconds(50))
        stopItem = NSApp.windows.first {
          String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.isVisible
            && !existing.contains(ObjectIdentifier($0))
        }
      }
      try #require(stopItem != nil, "5 s 内没开始录")
      let began = Date.now
      try await animate(panel, seconds: moving)
      try await Task.sleep(for: .seconds(max(0, 2 - Date.now.timeIntervalSince(began))))
      recorder.stop()
      for _ in 0..<300 where finished == nil { try await Task.sleep(for: .milliseconds(50)) }
      let result = try #require(finished, "15 s 内没收尾")
      #expect(result.reason == .user && result.moved)
      return try #require(result.file)
    }

    /// 读回 GIF：帧数、第一帧像素宽高、循环次数、每帧延时
    func inspectGIF(_ url: URL) throws -> (
      frames: Int, size: CGSize, loops: Int?, delays: [Double]
    ) {
      let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
      let count = CGImageSourceGetCount(source)
      let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
      let loops =
        (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[
          kCGImagePropertyGIFLoopCount] as? Int
      var delays: [Double] = []
      var size = CGSize.zero
      for index in 0..<count {
        let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        delays.append(gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0)
        if index == 0 {
          size = CGSize(
            width: frame?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: frame?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
      }
      return (count, size, loops, delays)
    }

    // 1. 只录画面、一直在动：视频轨到停止
    let video = try await take(systemAudio: false, moving: 2.1)
    let target = VideoExport.target(for: video, in: folder)
    #expect(target.lastPathComponent.hasPrefix("录屏 ") && target.pathExtension == "gif")
    #expect(
      target.deletingPathExtension().lastPathComponent
        == video.deletingPathExtension().lastPathComponent)
    let asset = AVURLAsset(url: video)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let (natural, range) = try await track.load(.naturalSize, .timeRange)
    let started = Date.now
    let first = try await VideoExport.gif(from: video, to: target)
    let elapsed = Date.now.timeIntervalSince(started)
    let gif = try inspectGIF(target)
    #expect(abs(gif.frames - 30) <= 3, "帧数 \(gif.frames)")
    #expect(gif.size.width <= 960 && gif.size.width >= 958, "宽 \(gif.size.width)")
    #expect(gif.loops == 0, "循环 \(String(describing: gif.loops))")
    #expect(gif.delays.dropLast().allSatisfy { abs($0 - 1.0 / 15) < 0.011 }, "延时 \(gif.delays)")
    #expect(first.width == Int(gif.size.width))
    let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    try save(first, "gif-first.png")

    // 2. 带系统声音、只动头 1 s：视频轨停在最后一次画面变化，GIF 最后一帧停到结尾
    let still = try await take(systemAudio: true, moving: 1)
    let stillAsset = AVURLAsset(url: still)
    let stillEnd = try #require(
      try await stillAsset.loadTracks(withMediaType: .video).first?.load(.timeRange).end.seconds)
    let stillDuration = try await stillAsset.load(.duration).seconds
    let stillTarget = VideoExport.target(for: still, in: folder)
    _ = try await VideoExport.gif(from: still, to: stillTarget)
    let held = try inspectGIF(stillTarget)
    let total = held.delays.reduce(0, +)
    #expect(abs(total - stillDuration) < 0.15, "GIF 总长 \(total) s，文件 \(stillDuration) s")

    // 3. 转到一半取消：抛 CancellationError，不留文件
    let cancelled = folder.appending(path: "cancelled.gif")
    let task = Task { try await VideoExport.gif(from: video, to: cancelled) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    var threw: (any Error)?
    do { _ = try await task.value } catch { threw = error }
    #expect(threw is CancellationError || threw == nil, "取消后抛的是 \(String(describing: threw))")
    #expect(threw == nil || !FileManager.default.fileExists(atPath: cancelled.path))

    note(
      "转成 GIF（录屏录音第 7 批）",
      [
        "只录画面、一直在动的 2 s：视频 \(Int(natural.width))×\(Int(natural.height))，视频轨 \(fmt(range.start.seconds))–\(String(format: "%.2f", range.end.seconds)) s → GIF \(gif.frames) 帧、\(Int(gif.size.width))×\(Int(gif.size.height))、循环 \(gif.loops.map(String.init) ?? "没写")、延时 \(Set(gif.delays.map { String(format: "%.3f", $0) }).sorted().joined(separator: " / ")) s、\(Int64(bytes).formatted(.byteCount(style: .file)))，转换耗时 \(String(format: "%.2f", elapsed)) s（每帧 \(String(format: "%.1f", elapsed / Double(max(gif.frames, 1)) * 1000)) ms，60 s 的 900 帧约 \(String(format: "%.0f", elapsed / Double(max(gif.frames, 1)) * 900)) s）",
        "带系统声音、只动头 1 s：视频轨到 \(String(format: "%.2f", stillEnd)) s、文件 \(String(format: "%.2f", stillDuration)) s → GIF \(held.frames) 帧，最后一帧停 \(String(format: "%.2f", held.delays.last ?? 0)) s，总长 \(String(format: "%.2f", total)) s",
        "转到一半取消：\(threw.map { "\(type(of: $0))" } ?? "取消前已经转完")，留下文件 \(FileManager.default.fileExists(atPath: cancelled.path))",
      ])
  }

  // MARK: - 录制

  struct Take {
    let url: URL
    let state: ProbeCallbacks.State
    let beginning: Date
    let startLatency: Int
    let stopping: Date

    var finishedEarly: Bool { state.finished.map { $0 < stopping } ?? false }

    var summary: [String] {
      let startDelay = state.started.map { "\(Int($0.timeIntervalSince(beginning) * 1000)) ms" }
      let finishDelay = state.finished.map { "\(Int($0.timeIntervalSince(stopping) * 1000)) ms" }
      return [
        "startCapture 返回 \(startLatency) ms、didStart 在调用后 \(startDelay ?? "没来")；从调用 stopCapture 起 \(finishDelay ?? "10 s 内没等到") 收到结束回调；失败 \(state.failure ?? "无")；流错误 \(state.streamError ?? "无")",
        "回调在主线程过：\(state.threads.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))；样本数 \(state.samples.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))",
      ]
    }

    struct Context {
      let url: URL
      let stream: SCStream
    }
  }

  /// 默认不挂任何样本输出（第 0 批结论）；outputs 给了才挂，队列传 nil
  func record(
    _ name: String, _ filter: SCContentFilter, _ configuration: SCStreamConfiguration,
    outputs: [SCStreamOutputType] = [], codec: AVVideoCodecType = .h264,
    fileType: AVFileType = .mp4, during: (Take.Context) async throws -> Void
  ) async throws -> Take {
    let url = Self.directory.appending(path: name + (fileType == .mov ? ".mov" : ".mp4"))
    try? FileManager.default.removeItem(at: url)
    let recording = SCRecordingOutputConfiguration()
    recording.outputURL = url
    recording.videoCodecType = codec
    recording.outputFileType = fileType
    let callbacks = ProbeCallbacks()
    let output = SCRecordingOutput(configuration: recording, delegate: callbacks)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: callbacks)
    for type in outputs {
      try stream.addStreamOutput(callbacks, type: type, sampleHandlerQueue: nil)
    }
    try stream.addRecordingOutput(output)
    let beginning = Date.now
    try await stream.startCapture()
    let startLatency = ms(since: beginning)
    try await during(Take.Context(url: url, stream: stream))
    let stopping = Date.now
    try await stream.stopCapture()
    let deadline = Date.now.addingTimeInterval(10)
    while callbacks.state.withLock({ $0.finished == nil }), Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    return Take(
      url: url, state: callbacks.state.withLock { $0 }, beginning: beginning,
      startLatency: startLatency, stopping: stopping)
  }

  // MARK: - 环境：主屏、自家色块窗口、过滤器

  struct Env {
    let screen: NSScreen
    let display: SCDisplay

    static func make() async throws -> Env {
      try #require(CGPreflightScreenCaptureAccess(), "要「屏幕录制」授权")
      try #require(
        RecordingProbeTests.directory.path.hasPrefix("/"),
        "TEST_RUNNER_KITTY_LIVE_RECORD_DIR 要写绝对路径")
      try FileManager.default.createDirectory(
        at: RecordingProbeTests.directory, withIntermediateDirectories: true)
      let screen = try #require(NSScreen.screens.first)
      let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      let display = try #require(content.displays.first { $0.displayID == id })
      return Env(screen: screen, display: display)
    }

    /// 主屏中间一排的纯色无边框面板；x 是在屏幕宽度上的比例
    func panel(_ color: NSColor, x: Double, width: CGFloat = 200, show: Bool = true) -> NSPanel {
      let frame = screen.visibleFrame
      let panel = NSPanel(
        contentRect: CGRect(
          x: frame.minX + frame.width * x, y: frame.midY - 80, width: width, height: 160),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.backgroundColor = color
      panel.level = .floating
      panel.hasShadow = false
      panel.isReleasedWhenClosed = false
      if show { panel.orderFrontRegardless() }
      return panel
    }

    /// 铺满可见区的「网页」：一张两屏高的图（灰字行 + 彩色块），往上滚它就是大面积运动
    func scrollingPage() -> (NSPanel, CALayer) {
      let frame = screen.visibleFrame
      let panel = NSPanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
      panel.backgroundColor = .white
      panel.level = .floating
      panel.hasShadow = false
      panel.isReleasedWhenClosed = false
      let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
      view.wantsLayer = true
      panel.contentView = view
      let page = CALayer()
      page.anchorPoint = .zero
      page.frame = CGRect(x: 0, y: -frame.height, width: frame.width, height: frame.height * 2)
      page.contentsScale = screen.backingScaleFactor
      page.contents = pageImage(
        width: Int(frame.width * screen.backingScaleFactor),
        height: Int(frame.height * 2 * screen.backingScaleFactor))
      view.layer?.addSublayer(page)
      panel.orderFrontRegardless()
      return (panel, page)
    }

    func filter(excepting panels: [NSPanel]) async throws -> (SCContentFilter, [Bool]) {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      let own = content.applications.filter { $0.processID == getpid() }
      let windows = panels.map { panel in
        content.windows.first { $0.windowID == CGWindowID(max(0, panel.windowNumber)) }
      }
      let filter = SCContentFilter(
        display: display, excludingApplications: own, exceptingWindows: windows.compactMap { $0 })
      return (filter, windows.map { $0 != nil })
    }

    func configuration(_ filter: SCContentFilter, fps: Int = 30) -> SCStreamConfiguration {
      let configuration = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      configuration.width = Int(filter.contentRect.width * scale) / 2 * 2
      configuration.height = Int(filter.contentRect.height * scale) / 2 * 2
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
      configuration.showsCursor = true
      return configuration
    }

    /// 面板中心在整块主屏的一帧里的像素位置（原点左上）
    func pixel(of panel: NSPanel, in image: CGImage) -> (x: Int, y: Int) {
      let frame = screen.frame
      return (
        Int((panel.frame.midX - frame.minX) / frame.width * CGFloat(image.width)),
        Int((frame.maxY - panel.frame.midY) / frame.height * CGFloat(image.height))
      )
    }
  }
}

// MARK: - 读录出来的文件

struct ProbeMedia {
  var bytes = 0
  var playable = false
  var duration = 0.0
  var videoTracks = 0
  var audioTracks = 0
  var size = CGSize.zero
  var codec = ""
  var colors = ""
  var frames = 0
  var audioKbps = "—"
  var audio: [String] = []

  var megabytesPerMinute: String {
    duration > 0 ? fmt(Double(bytes) / 1_048_576 / duration * 60) : "—"
  }

  var effectiveFPS: String { duration > 0 ? fmt(Double(frames) / duration) : "—" }

  var summary: [String] {
    [
      "文件 \(bytes / 1024) KB，能播 \(playable)，时长 \(fmt(duration)) s，视频轨 \(videoTracks)、音轨 \(audioTracks)",
      "视频 \(codec) \(Int(size.width))×\(Int(size.height))，\(frames) 帧（\(effectiveFPS) fps），色彩标记 \(colors)",
    ] + audio
  }
}

private func inspect(_ url: URL, split: Double? = nil) async -> ProbeMedia {
  var media = ProbeMedia()
  media.bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
  let asset = AVURLAsset(url: url)
  media.playable = (try? await asset.load(.isPlayable)) ?? false
  media.duration = (try? await asset.load(.duration).seconds) ?? 0
  let videos = (try? await asset.loadTracks(withMediaType: .video)) ?? []
  let audios = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
  media.videoTracks = videos.count
  media.audioTracks = audios.count
  if let video = videos.first {
    media.size = (try? await video.load(.naturalSize)) ?? .zero
    if let format = try? await video.load(.formatDescriptions).first {
      media.codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
      let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
      media.colors = [
        kCMFormatDescriptionExtension_ColorPrimaries,
        kCMFormatDescriptionExtension_TransferFunction,
        kCMFormatDescriptionExtension_YCbCrMatrix,
      ].map { "\(extensions[$0 as String] ?? "无")" }.joined(separator: " / ")
    }
    media.frames = sampleCount(asset, video)
  }
  for (index, track) in audios.enumerated() {
    var line = "音轨 \(index + 1)："
    if let format = try? await track.load(.formatDescriptions).first,
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
    {
      line +=
        "\(fourCC(description.mFormatID)) \(Int(description.mSampleRate)) Hz \(description.mChannelsPerFrame) 声道，"
    }
    if let rate = try? await track.load(.estimatedDataRate) {
      media.audioKbps = "\(Int(rate / 1000))"
      line += "码率约 \(media.audioKbps) kbps，"
    }
    line += "峰值 \(decibels(peak(asset, track)))"
    if let split {
      line +=
        "（0–\(fmt(split)) s \(decibels(peak(asset, track, to: split)))，之后 \(decibels(peak(asset, track, from: split))))"
    }
    media.audio.append(line)
  }
  return media
}

/// 不解码，只数压缩样本
private func sampleCount(_ asset: AVAsset, _ track: AVAssetTrack) -> Int {
  guard let reader = try? AVAssetReader(asset: asset) else { return -1 }
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
  reader.add(output)
  guard reader.startReading() else { return -1 }
  var count = 0
  while let buffer = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(buffer) }
  return reader.status == .completed ? count : -1
}

/// 一段里的峰值（0–1）；读失败返回 nil（和真静音分开）
private func peak(_ asset: AVAsset, _ track: AVAssetTrack, from: Double = 0, to: Double? = nil)
  -> Float?
{
  guard let reader = try? AVAssetReader(asset: asset) else { return nil }
  reader.timeRange = CMTimeRange(
    start: CMTime(seconds: from, preferredTimescale: 600),
    end: to.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity)
  let output = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
    ])
  reader.add(output)
  guard reader.startReading() else { return nil }
  var peak: Float = 0
  while let buffer = output.copyNextSampleBuffer() {
    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
    let length = CMBlockBufferGetDataLength(block)
    var floats = [Float](repeating: 0, count: length / 4)
    floats.withUnsafeMutableBytes {
      _ = CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
    }
    for value in floats { peak = max(peak, abs(value)) }
  }
  return reader.status == .completed ? peak : nil
}

private func frame(_ url: URL, at seconds: Double) async -> CGImage? {
  let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

/// 某个像素按 sRGB 读回来（0–255），原点左上
private func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int)? {
  guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
  var bytes = [UInt8](repeating: 0, count: 4)
  let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
    guard
      let context = CGContext(
        data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    // CG 原点在左下：把目标像素挪到 (0, 0)
    context.draw(
      image,
      in: CGRect(
        x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return true
  }
  return drawn ? (Int(bytes[0]), Int(bytes[1]), Int(bytes[2])) : nil
}

private func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
  abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
}

private func rgb(_ color: NSColor) -> (Int, Int, Int) {
  let color = color.usingColorSpace(.sRGB) ?? color
  return (
    Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)
  )
}

private func srgb(_ value: (Int, Int, Int)) -> NSColor {
  NSColor(
    srgbRed: CGFloat(value.0) / 255, green: CGFloat(value.1) / 255, blue: CGFloat(value.2) / 255,
    alpha: 1)
}

/// 文件的顶层 box（mp4 / mov 的 atom）：类型和大小，截断的也照读到哪算哪
private func boxes(_ url: URL) -> String {
  guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return "读不到" }
  var names: [String] = []
  var offset = 0
  while offset + 8 <= data.count, names.count < 20 {
    let size32 = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
    let type = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii) ?? "?"
    var size = size32
    if size32 == 1, offset + 16 <= data.count {
      size = data[offset + 8..<offset + 16].reduce(0) { $0 << 8 | Int($1) }
    } else if size32 == 0 {
      size = data.count - offset
    }
    names.append("\(type) \(size / 1024) KB")
    guard size >= 8 else { break }
    offset += size
  }
  return names.joined(separator: " · ")
}

// MARK: - 小工具

/// 让面板一直动、一直换色，逼系统每帧都出画面（静止画面 ScreenCaptureKit 不出新帧）
private func animate(_ panel: NSPanel, seconds: Double) async throws {
  let origin = panel.frame.origin
  let end = Date.now.addingTimeInterval(seconds)
  var step = 0
  while Date.now < end {
    step += 1
    panel.setFrameOrigin(CGPoint(x: origin.x + CGFloat(step % 120) * 4, y: origin.y))
    panel.backgroundColor = NSColor(
      hue: CGFloat(step % 60) / 60, saturation: 0.7, brightness: 0.9, alpha: 1)
    try await Task.sleep(for: .milliseconds(16))
  }
  panel.setFrameOrigin(origin)
}

/// 大面板上的「网页」往上滚（每帧 6 点，滚完一屏回到开头）
private func scroll(_ page: CALayer, in panel: NSPanel, seconds: Double) async throws {
  let height = panel.frame.height
  let end = Date.now.addingTimeInterval(seconds)
  var offset: CGFloat = 0
  while Date.now < end {
    offset = (offset + 6).truncatingRemainder(dividingBy: height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    page.position = CGPoint(x: 0, y: -height + offset)
    CATransaction.commit()
    try await Task.sleep(for: .milliseconds(16))
  }
}

/// 白底上一行行灰色「字」和几块彩色图，像一页网页
private func pageImage(width: Int, height: Int) -> CGImage? {
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  var y = 40
  var line = 0
  while y < height - 40 {
    line += 1
    if line % 9 == 0 {
      context.setFillColor(
        CGColor(
          srgbRed: CGFloat(line * 37 % 255) / 255, green: CGFloat(line * 91 % 255) / 255,
          blue: CGFloat(line * 53 % 255) / 255, alpha: 1))
      context.fill(CGRect(x: 80, y: y, width: width / 3, height: 220))
      y += 260
      continue
    }
    var x = 80
    while x < width - 200 {
      let word = 30 + (x * 7 + line * 13) % 120
      context.setFillColor(CGColor(gray: 0.15 + CGFloat(line % 3) * 0.1, alpha: 1))
      context.fill(CGRect(x: x, y: y, width: word, height: 18))
      x += word + 16
    }
    y += 44
  }
  return context.makeImage()
}

/// 别的进程放一声系统提示音（本 App 自己的声音会被 excludesCurrentProcessAudio 排除）
private func play(_ sound: String) {
  Task {
    _ = try? await Subprocess.run("/usr/bin/afplay", ["/System/Library/Sounds/\(sound).aiff"])
  }
}

/// 此刻本进程、replayd、视频编码进程的 CPU（ps 的 %cpu，最近一段的平均）
private func processCPU() async -> String {
  guard
    let result = try? await Subprocess.run(
      "/bin/ps", ["-A", "-o", "%cpu=,pid=,comm="], captures: true)
  else { return "读不到" }
  let own = String(getpid())
  let lines = result.output.split(separator: "\n").compactMap { line -> String? in
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count == 3 else { return nil }
    let name = parts[2].split(separator: "/").last.map(String.init) ?? ""
    guard parts[1] == own || name.contains("replayd") || name.contains("VTEncoder") else {
      return nil
    }
    return "\(parts[1] == own ? "本进程" : name) \(parts[0])"
  }
  return lines.joined(separator: "，")
}

/// since 以来系统日志里含「NOT found」的条数（ScreenCaptureKit 缺样本输出时打的那条）
private func notFoundLogs(since: Date) async -> String {
  let start = since.formatted(
    Date.VerbatimFormatStyle(
      format:
        "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
      timeZone: .current, calendar: Calendar(identifier: .gregorian)))
  guard
    let result = try? await Subprocess.run(
      "/usr/bin/log",
      [
        "show", "--start", start, "--info", "--debug", "--style", "compact", "--predicate",
        "eventMessage CONTAINS \"NOT found\"",
      ], captures: true)
  else { return "读不到" }
  let hits = result.output.split(separator: "\n").filter { $0.contains("NOT found") }
  return "\(hits.count) 条" + (hits.first.map { "（例：\($0.suffix(90))）" } ?? "")
}

/// 此刻开着这个文件的进程（lsof 的 COMMAND 列）
private func fileHolders(_ url: URL) async -> String {
  guard let result = try? await Subprocess.run("/usr/sbin/lsof", [url.path], captures: true)
  else { return "读不到" }
  let names = result.output.split(separator: "\n").dropFirst().compactMap {
    $0.split(separator: " ").first.map(String.init)
  }
  return names.isEmpty ? "没有" : Set(names).sorted().joined(separator: "、")
}

private func note(_ title: String, _ lines: [String]) {
  let url = RecordingProbeTests.directory.appending(path: "report.md")
  if !FileManager.default.fileExists(atPath: url.path) {
    let header =
      "# 录屏 / 录音实测\n\n\(ProcessInfo.processInfo.operatingSystemVersionString)，主屏 \(NSScreen.screens.first.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) 点 × \($0.backingScaleFactor)" } ?? "")\n\n"
    try? header.write(to: url, atomically: true, encoding: .utf8)
  }
  let text = "## \(title)\n" + lines.map { "- \($0)\n" }.joined() + "\n"
  print(text)
  if let handle = try? FileHandle(forWritingTo: url) {
    handle.seekToEndOfFile()
    handle.write(Data(text.utf8))
    try? handle.close()
  }
}

/// 截图存成输出目录里的 PNG（看完和视频一起删）
private func save(_ image: CGImage, _ name: String) throws {
  let data = try #require(
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
  try data.write(to: RecordingProbeTests.directory.appending(path: name))
}

private func ms(since date: Date) -> Int { Int(Date.now.timeIntervalSince(date) * 1000) }
private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

private func decibels(_ value: Float?) -> String {
  guard let value else { return "读失败" }
  return value <= 0 ? "数字静音" : "\(fmt(Double(20 * log10(value)))) dBFS"
}

private func fourCC(_ code: FourCharCode) -> String {
  let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
  return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}
