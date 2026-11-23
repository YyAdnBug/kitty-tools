// 录制分段拼接（issue #48，PLAN §10「录制暂停」）：系统录制管线 SCRecordingOutput 没有暂停，ScreenRecorder 暂停时停流
// （这一段写完）、继续时新开一条流写下一段；停止时（和闪退后下次启动时）把几段拼成一个 mp4。
// - 视频：逐样本原样拷贝、不重新编码。时间戳 = 源轨道第一个有内容的编辑段把媒体时间换成播放时间（H.264 重排，实录
//   0.067 s），再加上前几段的总长；几段的编码器各自重排，挪完排不下的那一段整体往后推一点（layout）。前一段最后一帧一直显示到下一段第一帧：系统录制只在画面变化时写帧，暂停前画面不动的
//   那截视频轨比音轨短，拿 composition + Passthrough 拼会成空编辑段、解码出黑帧，拉长最后一帧的 scaleTimeRange
//   Passthrough 又导不出来（探针实测，macos/build/research/issue-48-record-pause/）。
// - 声音：几段音轨按同样的起点排进一个 composition 解码成 PCM（系统按编辑表去掉每段开头的 AAC 预热，段间空着的地方是静音），
//   再编成一条连续的 AAC（采样率、声道数照源，码率取源音轨的估计值）。成品的视频、声音都只有一个编辑段，不靠播放器认中间的编辑表。
// 主线程外（@concurrent，mac-native §3：读写几百 MB 的文件，临时文件可能在卡住的网络盘上的保存目录里）；探针 878 MB 0.73 s。
// 几段的视频格式描述不一样（没见过：同一次录制设置不变，实录三段一样）、多于两个声道、写不成都返回 false，调用方各段分开存。

import AVFoundation
import OSLog

nonisolated enum RecordingJoin {
  /// 一段的样子（layout 用）：时长、视频轨第一个有内容的编辑段、视频第一个 / 最后一个样本的解码时间（媒体时间；没有视频是 nil）
  struct Part {
    var duration: CMTime
    var mapping: CMTimeMapping?
    var firstDecode: CMTime?
    var lastDecode: CMTime?
  }

  /// 每段在成品里从哪一刻开始、视频样本的时间戳挪多少（纯函数）。起点是前几段时长的累加；挪 = 起点 + 源轨道第一个有内容的
  /// 编辑段的（播放时间 − 媒体时间）。几段的编码器各自重排（实录第一段第一帧的解码时间比显示时间早 0.08 s、第二段早 0.13 s，
  /// 每段不一样），挪完下一段第一个解码时间可能不比上一段最后一个晚——写入器不收（-11800 / -16364，实录）：这时把这一段
  /// 连同它的声音、后面各段整体往后推到刚好排得下（多一个时基刻度），推出来的那一小截停在上一帧、声音是静音，音画照样对齐
  static func layout(_ parts: [Part]) -> [(start: CMTime, shift: CMTime)] {
    let tick = CMTime(value: 1, timescale: 600)
    var cursor = CMTime.zero
    var lastDecode: CMTime?
    return parts.map { part in
      var shift = shift(start: cursor, mapping: part.mapping)
      if let previous = lastDecode, let first = part.firstDecode, first + shift <= previous {
        let push = previous + tick - (first + shift)
        cursor = cursor + push
        shift = shift + push
      }
      defer {
        if let last = part.lastDecode { lastDecode = last + shift }
        cursor = cursor + part.duration
      }
      return (cursor, shift)
    }
  }

  /// 一段视频样本的时间戳挪多少：这一段在成品里的起点 + 源轨道第一个有内容的编辑段的（播放时间 − 媒体时间）；
  /// 没有编辑段时媒体时间就是播放时间
  static func shift(start: CMTime, mapping: CMTimeMapping?) -> CMTime {
    guard let mapping else { return start }
    return start + mapping.target.start - mapping.source.start
  }

  /// 拼好写到 target（和各段同一个文件夹的新文件，创建时间改成第一段的：存盘名按开录时刻）。成功 true；不成删掉没写完的
  /// target，各段原样留着
  @concurrent static func join(_ parts: [URL], to target: URL) async -> Bool {
    do {
      try await write(parts, to: target)
      if let created = (try? parts.first?.resourceValues(forKeys: [.creationDateKey]))?.creationDate
      {
        try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: target.path)
      }
      return true
    } catch {
      Log.record.error("录制的几段拼不起来：\(error)")
      try? FileManager.default.removeItem(at: target)
      return false
    }
  }

  /// 删掉几个文件（拼好之后的各段、放弃的各段）：主线程外，同 join
  @concurrent static func remove(_ files: [URL]) async {
    for file in files { try? FileManager.default.removeItem(at: file) }
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
  }

  private static func write(_ parts: [URL], to target: URL) async throws {
    try? FileManager.default.removeItem(at: target)
    // 留住各段的 asset 到声音读完：composition 里的音轨对它是弱引用，放掉就读不出来（同 ScreenRecorder.extractAudio 的实测）
    let assets = parts.map { AVURLAsset(url: $0) }
    defer { withExtendedLifetime(assets) {} }
    var shapes: [Part] = []
    var hasVideo: [Bool] = []
    var videoFormat: CMFormatDescription?
    for asset in assets {
      var shape = Part(duration: try await asset.load(.duration))
      let video = try await asset.loadTracks(withMediaType: .video).first
      hasVideo.append(video != nil)
      if let track = video {
        let format = try await track.load(.formatDescriptions).first
        if let videoFormat, let format,
          !CMFormatDescriptionEqual(videoFormat, otherFormatDescription: format)
        {
          throw Failure("几段的视频格式不一样")
        }
        if videoFormat == nil { videoFormat = format }
        shape.mapping = try await track.load(.segments).first { !$0.isEmpty }?.timeMapping
        // 第一个 / 最后一个样本的解码时间（没有解码时间的按显示时间）：只看样本表，不读数据
        if try await track.load(.canProvideSampleCursors) {
          let first = track.makeSampleCursorAtFirstSampleInDecodeOrder()
          let last = track.makeSampleCursorAtLastSampleInDecodeOrder()
          shape.firstDecode = first.map {
            $0.decodeTimeStamp.isValid ? $0.decodeTimeStamp : $0.presentationTimeStamp
          }
          shape.lastDecode = last.map {
            $0.decodeTimeStamp.isValid ? $0.decodeTimeStamp : $0.presentationTimeStamp
          }
        }
      }
      shapes.append(shape)
    }
    let placed = layout(shapes)
    var videoParts: [(url: URL, shift: CMTime)] = []
    let audio = AVMutableComposition()
    var audioTrack: AVMutableCompositionTrack?
    var audioFormat: CMFormatDescription?
    var bitrate: Float = 0
    for (index, asset) in assets.enumerated() {
      if hasVideo[index] { videoParts.append((asset.url, placed[index].shift)) }
      if let track = try await asset.loadTracks(withMediaType: .audio).first {
        let range = try await track.load(.timeRange)
        if audioTrack == nil {
          audioTrack = audio.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        try audioTrack?.insertTimeRange(range, of: track, at: placed[index].start + range.start)
        if audioFormat == nil { audioFormat = try await track.load(.formatDescriptions).first }
        bitrate = max(bitrate, try await track.load(.estimatedDataRate))
      }
    }
    let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
    var videoInput: AVAssetWriterInput?
    if let videoFormat {
      let input = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
      guard writer.canAdd(input) else { throw Failure("加不上视频轨") }
      writer.add(input)
      videoInput = input
    }
    var audioInput: AVAssetWriterInput?
    var audioReader: AVAssetReader?
    var audioOutput: AVAssetReaderAudioMixOutput?
    if let audioTrack, let audioFormat,
      let source = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
    {
      // 多于两个声道的 AAC 要另给声道布局；系统声音和麦克风混出来是立体声，没见过多声道
      guard source.mChannelsPerFrame <= 2 else { throw Failure("声道太多") }
      let format: [String: Any] = [
        AVSampleRateKey: source.mSampleRate, AVNumberOfChannelsKey: source.mChannelsPerFrame,
      ]
      var settings = format.merging([
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: max(64_000, Int(bitrate)),
      ]) { $1 }
      // 码率编码器不收（取到的估计值离谱）就交给编码器定；还不收就不拼（不让 AVAssetWriterInput 抛 ObjC 异常闪退）
      if !writer.canApply(outputSettings: settings, forMediaType: .audio) {
        settings[AVEncoderBitRateKey] = nil
      }
      guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
        throw Failure("编不了声音")
      }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      guard writer.canAdd(input) else { throw Failure("加不上音轨") }
      writer.add(input)
      audioInput = input
      let reader = try AVAssetReader(asset: audio)
      let output = AVAssetReaderAudioMixOutput(
        audioTracks: [audioTrack],
        audioSettings: format.merging([
          AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
          AVLinearPCMIsBigEndianKey: false,
        ]) { $1 })
      guard reader.canAdd(output) else { throw Failure("读不出声音") }
      reader.add(output)
      audioReader = reader
      audioOutput = output
    }
    guard writer.startWriting() else { throw writer.error ?? Failure("写不了") }
    if let audioReader, !audioReader.startReading() {
      throw audioReader.error ?? Failure("读不出声音")
    }
    writer.startSession(atSourceTime: .zero)
    do {
      try await copy(
        videoParts, into: videoInput, audio: audioOutput, from: audioReader, into: audioInput,
        writer: writer)
    } catch {
      writer.cancelWriting()
      audioReader?.cancelReading()
      throw error
    }
    writer.endSession(
      atSourceTime: (placed.last?.start ?? .zero) + (shapes.last?.duration ?? .zero))
    // 不用 await writer.finishWriting()：系统桥出来的异步版本恢复时会崩（VideoExportTests 实测）
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else { throw writer.error ?? Failure("没写完") }
  }

  /// 两路轮流写，写完各自 markAsFinished
  private static func copy(
    _ videoParts: [(url: URL, shift: CMTime)], into videoInput: AVAssetWriterInput?,
    audio audioOutput: AVAssetReaderAudioMixOutput?, from audioReader: AVAssetReader?,
    into audioInput: AVAssetWriterInput?, writer: AVAssetWriter
  ) async throws {
    var feed = VideoFeed(parts: videoParts)
    var pending = try await feed.next()
    var videoDone = videoInput == nil
    var audioDone = audioInput == nil
    var idle = Duration.zero
    // 两路轮流写：哪一路此刻收就写哪一路（写入器按时间交错，一路写多了它就不收那一路，只盯一路会互相等死）。
    // ponytail: 两路都不收时睡 2 ms 再看（不挂 requestMediaDataWhenReady：要另开派发队列、把读写器塞进锁里）；
    // 探针 878 MB 0.73 s，抢 CPU 时会慢几倍。真嫌慢再换回调
    while !(videoDone && audioDone) {
      var moved = false
      while !videoDone, let videoInput, videoInput.isReadyForMoreMediaData {
        guard let sample = pending else {
          videoInput.markAsFinished()
          videoDone = true
          break
        }
        guard videoInput.append(sample) else { throw writer.error ?? Failure("视频写不进去") }
        pending = try await feed.next()
        moved = true
      }
      while !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
        guard let sample = audioOutput.copyNextSampleBuffer() else {
          if audioReader?.status == .failed { throw audioReader?.error ?? Failure("读不出声音") }
          audioInput.markAsFinished()
          audioDone = true
          break
        }
        guard audioInput.append(sample) else { throw writer.error ?? Failure("声音写不进去") }
        moved = true
      }
      if moved {
        idle = .zero
        continue
      }
      if writer.status == .failed { throw writer.error ?? Failure("写入失败") }
      guard idle < .seconds(10) else { throw Failure("写入没有进展") }
      try await Task.sleep(for: .milliseconds(2))
      idle += .milliseconds(2)
    }
  }

  /// 各段的视频样本挨个读出来、改好时间戳（一段读完开下一段）
  private struct VideoFeed {
    let parts: [(url: URL, shift: CMTime)]
    var index = 0
    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?

    init(parts: [(url: URL, shift: CMTime)]) { self.parts = parts }

    mutating func next() async throws -> CMSampleBuffer? {
      while index < parts.count {
        if output == nil {
          let asset = AVURLAsset(url: parts[index].url)
          guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            index += 1
            continue
          }
          let reader = try AVAssetReader(asset: asset)
          let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
          output.alwaysCopiesSampleData = false
          guard reader.canAdd(output) else { throw Failure("读不出视频") }
          reader.add(output)
          guard reader.startReading() else { throw reader.error ?? Failure("读不出视频") }
          self.reader = reader
          self.output = output
        }
        if let sample = output?.copyNextSampleBuffer() {
          guard sample.numSamples > 0 else { continue }
          return try RecordingJoin.retimed(sample, by: parts[index].shift)
        }
        if reader?.status == .failed { throw reader?.error ?? Failure("读不出视频") }
        reader = nil
        output = nil
        index += 1
      }
      return nil
    }
  }

  /// 样本原样、时间戳整体挪 shift（解码时间有的话一起挪）
  static func retimed(_ sample: CMSampleBuffer, by shift: CMTime) throws -> CMSampleBuffer {
    var timing = try sample.sampleTimingInfos()
    for index in timing.indices {
      timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + shift
      if timing[index].decodeTimeStamp.isValid {
        timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + shift
      }
    }
    return try CMSampleBuffer(copying: sample, withNewTiming: timing)
  }
}
