// 录屏转成 GIF（录屏录音第 7 批，R12-a）的纯函数：帧时刻（15 fps、只转前 60 s、不到一帧也给一帧、视频轨比整段短时最后一帧
// 停到结尾）、输出尺寸（宽不超过 960、高取偶数、比原片小才缩）、存盘名（和视频同名换扩展名，按开录时刻，重名加序号）。
// 真转一段在 RecordingProbeTests/gifTake()（按需实录）。
// 压缩（第二轮体检 R1）：文件大小上限的算法、存盘名，和真压一段合成视频（不用录屏；变小、尺寸时长编码不变、取消不留文件）。

import AVFoundation
import Testing

@testable import KittyTools

struct VideoExportTests {
  @Test func framesAt15fpsUpTo60Seconds() {
    let two = VideoExport.frames(duration: 2, videoEnd: 2)
    #expect(two.count == 30)
    #expect(two.first?.time == .zero)
    #expect(two.last?.time == CMTime(value: 29, timescale: 15))
    #expect(two.allSatisfy { abs($0.delay - 1.0 / 15) < 1e-9 })
    // 超过 60 s 只转前 60 s
    let long = VideoExport.frames(duration: 95.4, videoEnd: 95.4)
    #expect(long.count == 900)
    #expect(long.last?.time == CMTime(value: 899, timescale: 15))
    // 浮点误差别多出或少掉一帧：1.4 s 是 21 帧（0 … 20/15）
    #expect(VideoExport.frames(duration: 1.4, videoEnd: 1.4).count == 21)
    // 不到一帧也给一帧；什么都没有就没有
    let tiny = VideoExport.frames(duration: 0.03, videoEnd: 0.03)
    #expect(tiny.count == 1 && abs(tiny[0].delay - 1.0 / 15) < 1e-9)
    #expect(VideoExport.frames(duration: 0, videoEnd: 0).isEmpty)
  }

  /// 视频轨比整段短（录了声音、画面后来不动）：轨外不取帧，最后一帧停到整段结束，总长不变
  @Test func lastFrameHoldsPastVideoTrack() {
    let frames = VideoExport.frames(duration: 2.12, videoEnd: 1.28)
    #expect(frames.count == 20)
    #expect(frames.last?.time == CMTime(value: 19, timescale: 15))
    #expect(abs((frames.last?.delay ?? 0) - 13.0 / 15) < 1e-9)
    #expect(abs(frames.map(\.delay).reduce(0, +) - 32.0 / 15) < 1e-9)
    // 超过 60 s 时停到第 60 s
    let capped = VideoExport.frames(duration: 90, videoEnd: 20)
    #expect(capped.count == 300)
    #expect(abs(capped.map(\.delay).reduce(0, +) - 60) < 1e-9)
  }

  @Test func sizeCapsWidthAt960() {
    #expect(
      VideoExport.size(for: CGSize(width: 1280, height: 720)) == CGSize(width: 960, height: 540))
    #expect(
      VideoExport.size(for: CGSize(width: 3420, height: 2224)) == CGSize(width: 960, height: 624))
    // 按比例算出奇数高时取偶数
    #expect(
      VideoExport.size(for: CGSize(width: 3000, height: 1001)) == CGSize(width: 960, height: 320))
    // 不比原片大：本来就不宽的原样
    #expect(
      VideoExport.size(for: CGSize(width: 960, height: 540)) == CGSize(width: 960, height: 540))
    #expect(
      VideoExport.size(for: CGSize(width: 640, height: 1200)) == CGSize(width: 640, height: 1200))
  }

  /// 「录屏 <开录时刻>.gif」：时间取视频文件的创建时间（开录那一刻），已有同名就加序号
  @Test func targetNamedLikeVideo() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-gif-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appending(path: "录屏 2026-09-30 14.03.21.mp4")
    try Data([0]).write(to: video)
    let started = try #require(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 30, hour: 14, minute: 3, second: 21)))
    try FileManager.default.setAttributes([.creationDate: started], ofItemAtPath: video.path)
    let target = VideoExport.target(for: video, in: folder)
    #expect(target.lastPathComponent == "录屏 2026-09-30 14.03.21.gif")
    try Data([0]).write(to: target)
    #expect(
      VideoExport.target(for: video, in: folder).lastPathComponent == "录屏 2026-09-30 14.03.21 2.gif"
    )
  }

  /// 压缩的文件大小上限（第二轮体检 R1）：视频码率按 48 × 像素数^0.75（3306 × 1892 约 6 Mbps、1652 × 946 约 2.1 Mbps），
  /// 加原来的音频码率，乘时长；再不超过原文件的 60%
  @Test func compressedLimitScalesWithPixelsAndCapsAtSixtyPercent() {
    let megabits = { (width: CGFloat, height: CGFloat) in
      Double(
        VideoExport.compressedLimit(
          pixels: CGSize(width: width, height: height), seconds: 8, audioBitrate: 0,
          bytes: .max / 2)) / 1e6
    }
    #expect(abs(megabits(3306, 1892) - 6.0) < 0.1)
    #expect(abs(megabits(1652, 946) - 2.12) < 0.05)
    #expect(abs(megabits(1920, 1080) - 2.62) < 0.05)
    // 用户报告的那段：39 s、3306 × 1892、121.8 MB，带一条 128 kbps 的音轨 → 约 30 MB（四分之一）
    let reported = VideoExport.compressedLimit(
      pixels: CGSize(width: 3306, height: 1892), seconds: 39, audioBitrate: 128_000,
      bytes: 121_800_000)
    #expect(abs(Double(reported) / 1e6 - 29.9) < 0.5)
    // 本来码率就不高的：按原文件的 60% 封顶，照样明显变小
    let small = VideoExport.compressedLimit(
      pixels: CGSize(width: 3306, height: 1892), seconds: 39, audioBitrate: 0, bytes: 20_000_000)
    #expect(small == 12_000_000)
  }

  /// 压缩后的名字：原名加「 压缩版」，存成 mp4（原片是别的扩展名也一样），重名加序号
  @Test func compressedTargetKeepsTheNameAndAddsSuffix() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-zip-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appending(path: "录屏 2026-10-02 21.00.00.mp4")
    let first = VideoExport.compressedTarget(for: video, in: folder)
    #expect(first.lastPathComponent == "录屏 2026-10-02 21.00.00 压缩版.mp4")
    try Data([0]).write(to: first)
    #expect(
      VideoExport.compressedTarget(for: video, in: folder).lastPathComponent
        == "录屏 2026-10-02 21.00.00 压缩版 2.mp4")
    #expect(
      VideoExport.compressedTarget(for: folder.appending(path: "a.mov"), in: folder)
        .lastPathComponent == "a 压缩版.mp4")
  }

  /// 真压一段合成的视频（640 × 360、2 s、每帧都是噪点所以码率高；不到一秒）：出来的文件明显变小、尺寸和时长不变、
  /// 还是 H.264，进度报过数；原文件不动。中途取消抛 CancellationError、不留半成品
  @MainActor @Test func compressShrinksASyntheticVideo() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-zip-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // 正在压的临时文件记在临时偏好域里（不写用户的偏好）
    let suite = "kitty-zip-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = folder.appending(path: "录屏 合成.mp4")
    try await Self.writeNoise(to: source, width: 640, height: 360, frames: 60)
    let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
    let before = size(source)
    let target = VideoExport.compressedTarget(for: source, in: folder)
    var reported: [Int] = []
    try await VideoExport.compress(source, to: target, defaults: defaults) { reported.append($0) }
    #expect(size(source) == before)
    #expect(
      size(target) > 0 && Double(size(target)) < Double(before) * 0.7, "\(before) → \(size(target))"
    )
    #expect(reported.allSatisfy { (0...100).contains($0) })
    let asset = AVURLAsset(url: target)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let (pixels, formats) = try await track.load(.naturalSize, .formatDescriptions)
    #expect(pixels == CGSize(width: 640, height: 360))
    #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264)
    #expect(abs(try await asset.load(.duration).seconds - 2) < 0.2)
    // 取消：不留文件
    let cancelled = VideoExport.compressedTarget(for: source, in: folder)
    let task = Task {
      try await VideoExport.compress(source, to: cancelled, defaults: defaults) { _ in }
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: cancelled.path))
    // 先写隐藏的临时名、做完改名（第四轮体检 E24）：文件夹里不留临时文件，记着的「正在压」也划掉了（做完、取消都划）；
    // 做的这一会儿目标名被占了就另起一个
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(!names.contains { $0.hasPrefix(".") })
    #expect(defaults.object(forKey: Prefs.compressingFiles) == nil)
    let taken = VideoExport.compressedTarget(for: source, in: folder)
    try Data().write(to: taken)
    let saved = try await VideoExport.compress(source, to: taken, defaults: defaults) { _ in }
    #expect(saved != taken && saved.lastPathComponent.hasPrefix("录屏 合成 压缩版"))
    #expect((try? taken.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == 0)
  }

  /// 压缩中途退出留下的临时文件（第四轮体检 E24）：启动时只删记下的那几个路径（不在了的跳过），旁边的文件不动、
  /// 不列目录，记录清掉；压缩出来的那段不再给「压缩」（U1）
  @Test func partialsAreCleanedAndCompressedVideosAreKnown() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-partial-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let suite = "kitty-partial-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let partial = VideoExport.partialName()
    #expect(partial.hasPrefix(".") && partial.hasSuffix(".mp4"))
    for name in [partial, "录屏 a.mp4", ".Kitty 压缩中 别人的.mp4"] {
      try Data().write(to: folder.appending(path: name))
    }
    defaults.set(
      [folder.appending(path: partial).path, folder.appending(path: "不在了.mp4").path],
      forKey: Prefs.compressingFiles)
    await VideoExport.removePartials(defaults: defaults)
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        == ["录屏 a.mp4", ".Kitty 压缩中 别人的.mp4"])
    #expect(defaults.object(forKey: Prefs.compressingFiles) == nil)
    #expect(VideoExport.isCompressed(URL(filePath: "/a/录屏 a 压缩版.mp4")))
    #expect(VideoExport.isCompressed(URL(filePath: "/a/录屏 a 压缩版 2.mp4")))
    #expect(!VideoExport.isCompressed(URL(filePath: "/a/录屏 a.mp4")))
    let video = URL(filePath: "/a/录屏 a.mp4")
    #expect(VideoJob.available(for: .video, file: video) == [.gif, .compress])
    #expect(
      VideoJob.available(for: .video, file: URL(filePath: "/a/录屏 a 压缩版.mp4")) == [.gif])
    #expect(VideoJob.available(for: .audio, file: URL(filePath: "/a/录音 a.m4a")).isEmpty)
    #expect(VideoJob.available(for: .gif, file: URL(filePath: "/a/录屏 a.gif")).isEmpty)
    #expect(VideoJob.available(for: .video, file: nil).isEmpty)
  }

  /// 写一段每帧都是噪点的 H.264 视频（30 fps，约 8 Mbps）
  @MainActor private static func writeNoise(
    to url: URL, width: Int, height: Int, frames: Int
  ) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var generator = SystemRandomNumberGenerator()
    for frame in 0..<frames {
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
      let pixels = try #require(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      if let base = CVPixelBufferGetBaseAddress(pixels) {
        let count = CVPixelBufferGetBytesPerRow(pixels) * height
        let bytes = base.bindMemory(to: UInt64.self, capacity: count / 8)
        for index in 0..<(count / 8) { bytes[index] = generator.next() }
      }
      CVPixelBufferUnlockBaseAddress(pixels, [])
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
      adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    // 不用 await writer.finishWriting()：系统桥出来的那个异步版本在这里一恢复就崩（实测，续体是空的）
    await withCheckedContinuation { continuation in
      writer.finishWriting { continuation.resume() }
    }
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
  }
}
