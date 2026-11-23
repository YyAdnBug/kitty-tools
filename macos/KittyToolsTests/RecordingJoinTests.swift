// 录制分段拼接（issue #48）：起点和时间戳换算的纯函数；用 AVAssetWriter 合成和系统录制同形状的几段（H.264 + AAC，
// 画面只在变化时有帧，所以画面不动的结尾视频轨比音轨短）真拼一遍，看成品没有空洞、接缝准、声音连续；格式不一样的拒绝；
// 暂停过的录屏闪退后先拼再挪；结果岛说分成了几段。都在临时目录里，几秒
import AVFoundation
import Testing

@testable import KittyTools

struct RecordingJoinTests {
  /// 每段的起点和视频样本挪多少：起点是前几段时长的累加，挪 = 起点 +（播放时间 − 媒体时间）；几段的编码器各自重排，
  /// 下一段第一个解码时间排不下时整段往后推到刚好排得下（多一个 1/600 s），后面各段跟着推
  @Test func layoutKeepsDecodeOrder() {
    // 整数毫秒构造（CMTime(seconds:) 自己会把 2.05 × 6000 取整成 12299）
    func time(_ seconds: Double) -> CMTime {
      CMTime(value: CMTimeValue((seconds * 1000).rounded()) * 6, timescale: 6000)
    }
    func near(_ one: CMTime, _ other: Double) -> Bool { abs(one.seconds - other) < 1e-6 }
    // 没有视频的几段：起点就是累加
    let plain = RecordingJoin.layout([
      .init(duration: time(1)), .init(duration: time(1.5)), .init(duration: time(1)),
    ])
    #expect(plain.map(\.start.seconds) == [0, 1, 2.5])
    #expect(plain.map(\.shift.seconds) == [0, 1, 2.5])
    #expect(RecordingJoin.layout([]).isEmpty)
    // 媒体时间从 0.1 s 起映射到播放时间 0（H.264 重排）：样本往前挪那么多，再加这一段的起点
    func mapping(_ media: Double) -> CMTimeMapping {
      CMTimeMapping(
        source: CMTimeRange(start: time(media), duration: time(1)),
        target: CMTimeRange(start: .zero, duration: time(1)))
    }
    let mapped = RecordingJoin.layout([
      .init(
        duration: time(2), mapping: mapping(0.1), firstDecode: time(0), lastDecode: time(1.9)),
      .init(
        duration: time(1), mapping: mapping(0.1), firstDecode: time(0), lastDecode: time(0.9)),
    ])
    #expect(near(mapped[1].start, 2) && near(mapped[1].shift, 2 - 0.1))
    // 实录那种：第一段最后一个解码时间挪完是 2.05 − 0.08 = 1.97，第二段第一个是 0.05 + 2 − 0.13 = 1.92，排不下：
    // 第二段整体往后推 0.05 + 1/600，第三段跟着推
    let pushed = RecordingJoin.layout([
      .init(
        duration: time(2), mapping: mapping(0.08), firstDecode: time(0), lastDecode: time(2.05)),
      .init(
        duration: time(1.6), mapping: mapping(0.13), firstDecode: time(0.05), lastDecode: time(1.6)
      ),
      .init(duration: time(1)),
    ])
    let push = 0.05 + 1.0 / 600
    #expect(near(pushed[1].start, 2 + push) && near(pushed[1].shift, 2 - 0.13 + push))
    #expect(near(pushed[2].start, 3.6 + push))
    #expect(near(RecordingJoin.shift(start: time(1), mapping: nil), 1))
  }

  /// 暂停中锁屏、睡眠、显示器睡眠不结束录制（拍板 Q2），别的照常收尾
  @Test func pausedKeepsThroughLockAndSleep() {
    #expect(ScreenRecorder.keepsPaused(.locked))
    #expect(ScreenRecorder.keepsPaused(.sleep))
    #expect(ScreenRecorder.keepsPaused(.displaySleep))
    #expect(!ScreenRecorder.keepsPaused(.user))
    #expect(!ScreenRecorder.keepsPaused(.screenChanged))
    #expect(!ScreenRecorder.keepsPaused(.discarded))
    #expect(!ScreenRecorder.keepsPaused(.lowDisk))
  }

  /// 三段：红 1.0 s（画面到 0.6 s）、绿 0.8 s、蓝 1.0 s（画面到 0.5 s）。拼完 2.8 s，视频、声音都只有一个编辑段；
  /// 每 50 ms 取一帧都取得到（画面不动那截停在上一帧，不是空洞），1.0 s 前红、1.0–1.8 s 绿、之后蓝；声音解码出来 2.8 s
  @Test func joinsWithoutGaps() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let parts = [
      try await Self.segment(in: folder, seconds: 1.0, videoUntil: 0.6, color: (220, 30, 30)),
      try await Self.segment(in: folder, seconds: 0.8, videoUntil: 0.8, color: (30, 200, 30)),
      try await Self.segment(in: folder, seconds: 1.0, videoUntil: 0.5, color: (30, 30, 220)),
    ]
    let target = folder.appending(path: "joined.mp4")
    #expect(await RecordingJoin.join(parts, to: target))
    let asset = AVURLAsset(url: target)
    #expect(abs(try await asset.load(.duration).seconds - 2.8) < 0.01)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    #expect(try await video.load(.segments).count == 1)
    #expect(try await audio.load(.segments).count == 1)
    let videoEnd = try await video.load(.timeRange).end.seconds
    #expect(abs(videoEnd - 2.3) < 0.05)
    var seen: [String] = []
    for time in stride(from: 0.025, to: videoEnd, by: 0.05) {
      let color = await Self.color(target, at: time)
      let expected = time < 1.0 ? "红" : time < 1.8 ? "绿" : "蓝"
      #expect(color == expected, "\(time) s 是\(color)")
      seen.append(color)
    }
    #expect(Set(seen) == ["红", "绿", "蓝"])
    #expect(abs(try await Self.decodedSeconds(target) - 2.8) < 0.03)
    // 存盘名按开录时刻：成品的创建时间是第一段的
    let created = { (url: URL) in try url.resourceValues(forKeys: [.creationDateKey]).creationDate }
    #expect(try created(target) == created(parts[0]))
  }

  /// 几段的视频格式不一样：不拼、不留半个文件，各段原样留着（调用方分开存）
  @Test func joinRefusesMismatchedFormats() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let parts = [
      try await Self.segment(in: folder, seconds: 0.5, videoUntil: 0.5, color: (220, 30, 30)),
      try await Self.segment(
        in: folder, seconds: 0.5, videoUntil: 0.5, color: (30, 30, 220), width: 160, height: 96),
    ]
    let target = folder.appending(path: "joined.mp4")
    #expect(!(await RecordingJoin.join(parts, to: target)))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(parts.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  /// 暂停过的录屏闪退了：「进行中」记着所有段，下次启动先拼成一个再挪进保存目录，各段删掉、记录删掉
  @Test func recoverJoinsParts() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let saved = folder.appending(path: "saved")
    try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
    let suite = "kitty-test-recover-parts-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let parts = [
      try await Self.segment(in: folder, seconds: 0.6, videoUntil: 0.6, color: (220, 30, 30)),
      try await Self.segment(in: folder, seconds: 0.6, videoUntil: 0.3, color: (30, 30, 220)),
    ]
    defaults.set(parts[0].path, forKey: Prefs.screenRecordingInProgress)
    defaults.set(parts.map(\.path), forKey: Prefs.screenRecordingParts)
    let found = try #require(await ScreenRecorder.recover(into: saved, defaults: defaults))
    #expect(found.title == "上次录屏没有正常结束，已保存")
    #expect("\(found.tone)" == "info")
    let files = try FileManager.default.contentsOfDirectory(atPath: saved.path)
    #expect(files.count == 1 && files[0].hasPrefix("录屏 ") && files[0].hasSuffix(".mp4"))
    let duration = try await AVURLAsset(url: saved.appending(path: files[0])).load(.duration)
    #expect(abs(duration.seconds - 1.2) < 0.01)
    #expect(!parts.contains { FileManager.default.fileExists(atPath: $0.path) })
    #expect(defaults.string(forKey: Prefs.screenRecordingInProgress) == nil)
    #expect(defaults.object(forKey: Prefs.screenRecordingParts) == nil)
  }

  /// 拼不成、各段分开存时结果岛说一声（正常停也是警告）
  @Test func summaryMentionsPieces() throws {
    var result = ScreenRecorder.Result(
      file: URL(filePath: "/tmp/录屏 2026-11-23 10.00.00.mp4"), moved: true, duration: .seconds(72),
      reason: .user)
    result.pieces = 3
    let text = try #require(ScreenRecorder.summary(result, folder: "桌面"))
    #expect(text.title == "已保存录屏")
    #expect(text.detail == "存成了 3 个文件 · 1:12")
    #expect("\(text.tone)" == "warning")
  }

  // MARK: 合成片段

  private static func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-join-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// 一段和系统录制同形状的 mp4：整块纯色的 H.264（30 fps，画面只到 videoUntil）+ 440 Hz 的 AAC 48 kHz 立体声（到 seconds），
  /// 文件时长到 seconds
  private static func segment(
    in folder: URL, seconds: Double, videoUntil: Double, color: (UInt8, UInt8, UInt8),
    width: Int = 320, height: Int = 192
  ) async throws -> URL {
    let url = folder.appending(path: "录屏 \(UUID()).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: video,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      ])
    let audio = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
      ])
    // 两路都按时间先后写；实时模式下写入器不为交错卡住某一路
    video.expectsMediaDataInRealTime = true
    audio.expectsMediaDataInRealTime = true
    writer.add(video)
    writer.add(audio)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let frames = Int(videoUntil * 30)
    let samples = Int64(seconds * 48_000)
    var frame = 0
    var written: Int64 = 0
    while frame < frames || written < samples {
      if frame < frames, written >= samples || Double(frame) / 30 <= Double(written) / 48_000 {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
          let bgra = UInt32(color.2) | UInt32(color.1) << 8 | UInt32(color.0) << 16 | 0xFF00_0000
          let count = CVPixelBufferGetBytesPerRow(pixels) * height / 4
          base.bindMemory(to: UInt32.self, capacity: count).update(repeating: bgra, count: count)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        adaptor.append(
          pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        frame += 1
      } else {
        let count = Int(min(1024, samples - written))
        while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        audio.append(try tone(from: written, count: count))
        written += Int64(count)
      }
    }
    video.markAsFinished()
    audio.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: samples, timescale: 48_000))
    // 不用 await writer.finishWriting()：系统桥出来的异步版本恢复时会崩（同 VideoExportTests）
    await withCheckedContinuation { continuation in
      writer.finishWriting { continuation.resume() }
    }
    try #require(writer.status == .completed, "\(String(describing: writer.error))")
    return url
  }

  /// 一块 440 Hz、Float32 交错立体声的声音样本
  private static func tone(from start: Int64, count: Int) throws -> CMSampleBuffer {
    let description = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
      mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
      mReserved: 0)
    let format = try CMAudioFormatDescription(audioStreamBasicDescription: description)
    var values = [Float](repeating: 0, count: count * 2)
    for index in 0..<count {
      let value = Float(sin(2 * .pi * 440 * Double(start + Int64(index)) / 48_000) * 0.3)
      values[2 * index] = value
      values[2 * index + 1] = value
    }
    let block = try CMBlockBuffer(length: count * 8)
    try values.withUnsafeBytes { try block.replaceDataBytes(with: $0) }
    return try CMSampleBuffer(
      dataBuffer: block, formatDescription: format, numSamples: count,
      presentationTimeStamp: CMTime(value: start, timescale: 48_000), packetDescriptions: [])
  }

  /// 某一刻（不放宽容差）取到的画面中心是什么颜色；取不到（空洞）是「空」
  private static func color(_ url: URL, at seconds: Double) async -> String {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard
      let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        .image,
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return "空" }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let pixel = context.data?.assumingMemoryBound(to: UInt8.self) else { return "空" }
    let (red, green, blue) = (pixel[0], pixel[1], pixel[2])
    return red > 150 && green < 90 ? "红" : green > 150 && red < 90 ? "绿" : blue > 150 ? "蓝" : "?"
  }

  /// 整条音轨解码出来多少秒
  private static func decodedSeconds(_ url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: [track],
      audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000])
    reader.add(output)
    reader.startReading()
    var frames = 0
    while let buffer = output.copyNextSampleBuffer() { frames += buffer.numSamples }
    return Double(frames) / 48_000
  }
}
