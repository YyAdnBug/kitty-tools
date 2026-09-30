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
  /// 都会删掉可能写了一半的文件
  @concurrent nonisolated static func gif(from video: URL, to target: URL) async throws -> CGImage {
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
      for frame in frames {
        try Task.checkCancellation()
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
}
