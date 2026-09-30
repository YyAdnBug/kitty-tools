// 录屏转成 GIF（录屏录音第 7 批，R12-a）的纯函数：帧时刻（15 fps、只转前 60 s、不到一帧也给一帧、视频轨比整段短时最后一帧
// 停到结尾）、输出尺寸（宽不超过 960、高取偶数、比原片小才缩）、存盘名（和视频同名换扩展名，按开录时刻，重名加序号）。
// 真转一段在 RecordingProbeTests/gifTake()（按需实录）。

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
}
