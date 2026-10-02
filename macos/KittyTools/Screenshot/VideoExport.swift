// 录屏转成 GIF（录屏录音第 7 批，PLAN §10「录屏与录音」，拍板 R12-a）：常驻缩略图的视频卡上点「转成 GIF」（ShelfCard.convertToGIF），
// 15 fps、宽不超过 960（按比例缩、宽高取偶数，比原片小才缩）、最长只转前 60 s，存进快速保存目录「录屏 <开录时刻>.gif」、循环播放。
// AVAssetImageGenerator 逐帧取（容差 0、maximumSize 直接给输出尺寸，不解整张），逐帧交给 CGImageDestination，不留整段的帧：
// 编码是 mac-native §3 @concurrent 第 1 类（图片编码），生成器和目标只在 gif(from:to:) 里建和用，进出都是 Sendable 的值（URL、CGImage）。
// 实测（2026-09-30，960 × 540 × 300 帧）：ImageIO 的 GIF 默认用全局调色板，要等 Finalize 时把所有帧一起量化，峰值约 600 MB；
// 关掉全局调色板（kCGImagePropertyGIFHasGlobalColorMap = false，每帧自己的调色板，颜色也更准）后每加一帧就编好，全程约 5 MB。
// 文件在 Finalize 时才一次写出：中途取消（卡片被关掉）、App 退出都不会在保存目录里留下半成品。
// 视频轨比整段短（录了声音、画面后来不动：视频轨停在最后一次画面变化，第 4 批实录）时，轨外不再取帧，最后一帧停到整段结束，
// GIF 的长度仍和录屏一样（停在结果画面上再循环）。
// 实录（gifTake）：2560 × 1440 一直在动的 2 s → 960 × 540、33 帧、2.5 MB，每帧约 25 ms（60 s 的 900 帧约 23 s）。
// ponytail: GIF 的延时以 1/100 s 记，1/15 s 存成 0.07 s（实测读回），放起来比原片慢约 5%；要分毫不差就按累计时刻交替给 0.07 / 0.06。
// 压缩（第二轮体检 R1，文件末尾）：视频卡上点「压缩」（ShelfCard.compress），用系统的导出把录好的文件压小、另存一份
// 「<原名> 压缩版.mp4」，原文件不动。

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoExport {
  nonisolated static let frameRate = 15
  nonisolated static let maxSeconds: Double = 60
  nonisolated static let maxWidth: CGFloat = 960

  /// GIF 的一帧：从视频哪一刻取、在 GIF 里停多久（秒）
  nonisolated struct Frame: Equatable, Sendable {
    let time: CMTime
    let delay: Double
  }

  /// 转不成的原因（岛的详情）
  nonisolated struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
  }

  /// 帧（纯函数，配单测）：每 1/15 s 一帧、最多前 60 s；不到一帧的也给一帧。duration 是整段、videoEnd 是视频轨的结束：
  /// 轨外的时刻不取，最后一帧停到整段结束
  nonisolated static func frames(duration: Double, videoEnd: Double) -> [Frame] {
    // k / 15 < seconds 的 k 有几个（减一点点：2.0 × 15 算成 30.000…04 时别多出一帧落在结尾上）
    let rate = Double(frameRate)
    let count = { (seconds: Double) -> Int in Int((seconds * rate - 1e-6).rounded(.up)) }
    let total = count(min(duration, maxSeconds))
    let shown = min(total, count(videoEnd))
    guard shown > 0 else { return [] }
    return (0..<shown).map { (index: Int) -> Frame in
      let holds = index == shown - 1 ? total - index : 1
      return Frame(
        time: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)),
        delay: Double(holds) / rate)
    }
  }

  /// 输出尺寸（纯函数，配单测）：宽超过 960 才按比例缩到 960，高取偶数；不超过的原样
  nonisolated static func size(for pixels: CGSize) -> CGSize {
    guard pixels.width > maxWidth else { return pixels }
    let even = max(2, (pixels.height * maxWidth / pixels.width / 2).rounded() * 2)
    return CGSize(width: maxWidth, height: even)
  }

  /// 存成什么名字：和视频同名换扩展名（「录屏 <开录时刻>.gif」，重名加序号），存进 directory
  static func target(for video: URL, in directory: URL) -> URL {
    ScreenRecorder.savedURL(for: video, in: directory, ext: "gif")
  }

  /// 把 video 转成 GIF 写到 target，返回第一帧（GIF 卡的图、岛的前导）。取消时抛 CancellationError，转不成抛错（岛写原因）；
  /// 都会删掉可能写了一半的文件。progress：转到百分之几了（整数变了才报，在主线程上调）
  @concurrent nonisolated static func gif(
    from video: URL, to target: URL, progress: @MainActor @Sendable (Int) -> Void = { _ in }
  ) async throws -> CGImage {
    do {
      let asset = AVURLAsset(url: video)
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw Failure("视频里没有画面")
      }
      let (pixels, range) = try await track.load(.naturalSize, .timeRange)
      let frames = frames(
        duration: try await asset.load(.duration).seconds, videoEnd: range.end.seconds)
      guard !frames.isEmpty else { throw Failure("视频里没有画面") }
      guard
        let destination = CGImageDestinationCreateWithURL(
          target as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
      else { throw Failure("没能新建 GIF 文件") }
      CGImageDestinationSetProperties(
        destination,
        [
          kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false,
          ]
        ] as CFDictionary)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      generator.maximumSize = size(for: pixels)
      var first: CGImage?
      var percent = 0
      for (index, frame) in frames.enumerated() {
        try Task.checkCancellation()
        if index * 100 / frames.count > percent {
          percent = index * 100 / frames.count
          await progress(percent)
        }
        let image = try await generator.image(at: frame.time).image
        CGImageDestinationAddImage(
          destination, image,
          [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frame.delay]]
            as CFDictionary)
        if first == nil { first = image }
      }
      try Task.checkCancellation()
      guard let first, CGImageDestinationFinalize(destination) else {
        throw Failure("没能写入 GIF 文件")
      }
      return first
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw Task.isCancelled ? CancellationError() : error
    }
  }

  // MARK: 压缩

  /// 压缩后的文件最多多大（字节；纯函数，配单测）：视频码率按 48 × 像素数^0.75 给（3306 × 1892 是 6 Mbps，1652 × 946 是
  /// 2.1 Mbps，1080p 2.6 Mbps），加上原来的音频码率，乘时长；再不超过原文件的 60%（本来就不大的也要明显变小）。
  /// 用合成的录屏量的（M3，30 fps、20 s，文字很多的桌面，中间 8 s 有一块在滚动）：
  /// - 3306 × 1892、41.6 MB（16.5 Mbps）→ 15.3 MB，用了 8.4 s；静止时的小字和原片比 PSNR 38 dB、滚动时 30 dB，放大看不出差别。
  ///   再低：4 Mbps 小字边上开始有毛刺（33 dB），3 Mbps 明显；再高：8 Mbps 只多 4 dB、文件大三成。
  /// - 1652 × 946、15.1 MB（6 Mbps）→ 5.5 MB，用了 2.4 s，静止 37 dB、滚动 30 dB。
  /// - 录屏本身的码率是系统按编码和分辨率定的（实录 3306 × 1892 的 H.264 约 24.7 Mbps），照这个上限压完约剩四分之一。
  /// 没用别的预设：H.264 的「最高画质」不给上限是原样拷贝（一样大）；1080p 预设 9 Mbps、缩到 1920 宽，更大还更糊（21 dB）；
  /// HEVC 预设只小 15%，而且换了编码。ponytail: 不看帧率和内容——60 fps、整段都在动的片子（游戏、视频）按这个码率会有
  /// 块状；嫌糊再按帧率加码（nominalFrameRate ≥ 45 时乘 1.4）
  nonisolated static func compressedLimit(
    pixels: CGSize, seconds: Double, audioBitrate: Double, bytes: Int64
  ) -> Int64 {
    let video = 48 * pow(Double(pixels.width * pixels.height), 0.75)
    return Int64(min((video + audioBitrate) * seconds / 8, Double(bytes) * 0.6))
  }

  /// 压缩后存成什么名字：原名后面加「 压缩版」，mp4；重名加序号
  static func compressedTarget(for video: URL, in directory: URL) -> URL {
    let base = video.deletingPathExtension().lastPathComponent + " 压缩版"
    var url = directory.appending(path: "\(base).mp4")
    var index = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = directory.appending(path: "\(base) \(index).mp4")
      index += 1
    }
    return url
  }

  /// 把 video 压小另存到 target（原文件不动）：系统的导出，「最高画质」预设 + 文件大小上限（compressedLimit）——分辨率、
  /// 帧率、音轨照旧，画面按上限重新编码成 H.264（原片是 HEVC 的也出 H.264：压缩版多半是拿去发给别人的，哪儿都能放）。
  /// 导出会话不是 Sendable：在主线程上建、主线程上等（编码在系统线程上跑，不卡界面）。progress：到百分之几了。
  /// 取消（卡片被关掉）抛 CancellationError，压不成抛错；都会删掉可能写了一半的文件
  static func compress(_ video: URL, to target: URL, progress: @escaping (Int) -> Void) async throws
  {
    do {
      let asset = AVURLAsset(url: video)
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw Failure("视频里没有画面")
      }
      let pixels = try await track.load(.naturalSize)
      let seconds = try await asset.load(.duration).seconds
      var audio = 0.0
      for track in try await asset.loadTracks(withMediaType: .audio) {
        audio += Double(try await track.load(.estimatedDataRate))
      }
      let bytes = (try? video.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      guard
        let session = AVAssetExportSession(
          asset: asset, presetName: AVAssetExportPresetHighestQuality)
      else { throw Failure("这段视频压不了") }
      session.fileLengthLimit = compressedLimit(
        pixels: pixels, seconds: seconds, audioBitrate: audio, bytes: Int64(bytes))
      session.shouldOptimizeForNetworkUse = true
      let updates = Task {
        for await state in session.states(updateInterval: 0.2) {
          if case .exporting(let done) = state { progress(Int(done.fractionCompleted * 100)) }
        }
      }
      defer { updates.cancel() }
      try await session.export(to: target, as: .mp4)
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw Task.isCancelled ? CancellationError() : error
    }
  }
}
