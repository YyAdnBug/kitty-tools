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
// （录制 HUD 从倒数换成录制态，倒数不进文件：录下来仍是 2 s），录制中连 HUD 一起截图。
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
      hudWindow = NSApp.windows.first { $0.contentView is RecordingHUD && $0.isVisible }
    }
    let hud = try #require(hudWindow?.contentView as? RecordingHUD, "倒数时没出 HUD")
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
    // 结尾那一帧：白名单里的窗口录进去了，不在白名单的没有（和背景比只记下来，桌面颜色可能碰巧相近）
    let last = try #require(await frame(file, at: max(0, media.duration - 0.3)))
    let at = { (window: NSWindow) in
      pixel(
        last, x: Int((window.frame.midX - region.minX) * scale),
        y: Int((region.maxY - window.frame.midY) * scale))
    }
    let red = try #require(at(listed))
    #expect(red.0 > 180 && red.1 < 80 && red.2 < 80, "白名单窗口没录进去：\(red)")
    let green = at(unlisted).map { "\($0)" } ?? "读不到"
    note(
      "ScreenRecorder 真录（录屏第 1 批）",
      [
        "结果：\(result.reason)，挪进输出目录 \(result.moved)，会话计的时长 \(result.duration)，文件 \(file.lastPathComponent)",
        "先倒数 1 s 再开流：文件时长 \(String(format: "%.2f", media.duration)) s（录 2 s；倒数进了文件会是 3 s 左右）",
        "结尾一帧：白名单里的 NSWindow（红 230,26,26）读回 \(red)；不在白名单的 NSPanel（绿 26,204,51）处读回 \(green)",
      ] + media.summary)
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
