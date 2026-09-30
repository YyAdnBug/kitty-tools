// 录音第 5 批（AudioRecorder）的纯函数与不真录的流程：电平历史（HUD 的最近 3 s = 24 根、每根 2.5 个样本取最大；整段包络有上限、
// 满了两两合并）、「没听到声音」的门槛（−70 dB、开头 5 s）、电平竖条高度的映射（−50 dB → 2 pt、0 dB → 20 pt）、包络按条数重新
// 分组、飞入起点（HUD 处和 poster 同比例的小框）、波形 poster 的尺寸和画法、结果岛的录音说法、闪退恢复（录音的偏好键）、
// 授权（拒绝过 / 刚点了不允许 / 等授权框时停止——授权状态和系统框都是注入的，不真弹框、不真录音）。
// 真录在按需实录自检 RecordingProbeTests.audioRecorderTake；录音 HUD 在 RecordingHUDTests，录音卡在 VideoCardTests。

import AVFoundation
import AppKit
import Testing

@testable import KittyTools

struct AudioRecorderTests {
  /// HUD 的电平：20 Hz 采样，每 2.5 个样本一根（3、2、3、2…，取最大），只留最近 24 根（3 s）
  @Test func recentLevelsGroupAndCap() {
    var levels = AudioRecorder.Levels()
    for value in [-60, -40, -50, -30, -35] as [Float] { levels.add(value) }
    // 第 0–2 个样本一根（最大 −40），第 3–4 个一根（最大 −30）
    #expect(levels.recent == [-40, -30])
    for _ in 0..<200 { levels.add(-20) }
    #expect(levels.recent.count == AudioRecorder.Levels.bars)
    #expect(levels.recent.allSatisfy { $0 == -20 })
    // 3 s（60 个样本）正好 24 根
    var three = AudioRecorder.Levels()
    for index in 0..<60 { three.add(Float(-index)) }
    #expect(three.recent.count == 24 && three.recent.first == 0 && three.recent.last == -58)
  }

  /// 整段的包络：桶数到上限就两两合并（取最大）、每桶样本数加倍——长录音不无限涨，最响的那一下不丢
  @Test func envelopeStaysBounded() {
    var levels = AudioRecorder.Levels()
    let limit = AudioRecorder.Levels.envelopeLimit
    for index in 0..<limit { levels.add(index == 7 ? -3 : -40) }
    #expect(levels.envelope.count == limit)
    levels.add(-40)  // 满了：合并成一半再接一个新桶
    #expect(levels.envelope.count == limit / 2 + 1)
    #expect(levels.envelope[3] == -3)  // 第 7 个样本在合并后的第 3 桶
    for _ in 0..<(20 * 60 * 60) { levels.add(-45) }  // 再录一小时
    #expect(levels.envelope.count <= limit)
    #expect(levels.envelope.max() == -3)
  }

  /// 「没听到声音」（A4-a）：门槛 −70 dB（安静房间底噪约 −41 到 −51 不算、数字静音 −120 算），开头 5 s 一直没到才出，
  /// 听到过就收起
  @Test func silenceNeedsFiveQuietSeconds() {
    #expect(AudioRecorder.silenceThreshold == -70)
    var quiet = AudioRecorder.Levels()
    for _ in 0..<100 { quiet.add(-120) }
    #expect(!quiet.heard)
    #expect(!AudioRecorder.showsSilence(heard: quiet.heard, recorded: .seconds(4.9)))
    #expect(AudioRecorder.showsSilence(heard: quiet.heard, recorded: .seconds(5)))
    var room = AudioRecorder.Levels()
    room.add(-51)  // 安静房间最低的底噪
    #expect(room.heard)
    #expect(!AudioRecorder.showsSilence(heard: room.heard, recorded: .seconds(30)))
    var edge = AudioRecorder.Levels()
    edge.add(-70.5)
    #expect(!edge.heard)
    edge.add(-70)
    #expect(edge.heard)
  }

  /// 竖条高度：−50 dB 及以下 2 pt、0 dB 到最高（HUD 20 pt），中间按 dB 线性
  @Test func meterHeightMapsDecibels() {
    #expect(AudioRecorder.meterHeight(-120) == 2)
    #expect(AudioRecorder.meterHeight(-50) == 2)
    #expect(AudioRecorder.meterHeight(-25) == 11)
    #expect(AudioRecorder.meterHeight(0) == 20)
    #expect(AudioRecorder.meterHeight(6) == 20)
    #expect(AudioRecorder.meterHeight(0, tallest: 70) == 70)
  }

  /// 包络按条数重新分组：每条取那一段的最大；比条数少时按比例重复；空的没有条
  @Test func resampleKeepsPeaks() {
    #expect(AudioRecorder.resample([-10, -20, -30, -40], to: 2) == [-10, -30])
    #expect(AudioRecorder.resample([-10, -20, -3, -40, -50, -60], to: 3) == [-10, -3, -50])
    #expect(AudioRecorder.resample([-10, -20], to: 4) == [-10, -10, -20, -20])
    #expect(AudioRecorder.resample([], to: 4).isEmpty)
  }

  /// 飞入起点：HUD 的中心、HUD 那么高、poster 的宽高比（16:10）——从小卡长到 200 × 125 的录音卡
  @Test func flightStartsSmallAtTheHUD() throws {
    let hud = CGRect(x: 600, y: 94, width: 300, height: 40)
    let start = AudioRecorder.flightStart(hud: hud)
    #expect(start == CGRect(x: 718, y: 94, width: 64, height: 40))
    #expect(
      start.width / start.height == AudioRecorder.posterSize.width / AudioRecorder.posterSize.height
    )
    // 落地是 poster 的尺寸（不按起点的小框算）
    let screen = try #require(NSScreen.screens.first)
    let from = CGRect(
      x: screen.frame.midX - 32, y: screen.frame.minY + 100, width: 64, height: 40)
    #expect(
      FlyCard.landingRect(for: from, size: AudioRecorder.posterSize)?.size
        == CGSize(width: 200, height: 125))
    #expect(FlyCard.landingRect(for: from)?.size == from.size)
  }

  /// 波形 poster：2x、和视频卡同比例；响的那段竖条高、安静的那段只有 2 pt，底色是 HUD 底色
  @Test func waveformPoster() throws {
    let loud = Array(repeating: Float(0), count: 20) + Array(repeating: Float(-120), count: 20)
    let poster = try #require(AudioRecorder.waveform(loud))
    #expect(poster.width == 400 && poster.height == 250)
    // 左半（响）中线往上 60 px 处是竖条，右半（静）那里是底色
    let data = try #require(poster.dataProvider?.data as Data?)
    let row = poster.bytesPerRow
    func brightness(x: Int, y: Int) -> Int { Int(data[y * row + x * 4 + 1]) }  // BGRA 的 G
    let upper = 125 - 60
    let loudColumn = (0..<200).map { brightness(x: $0, y: upper) }.max() ?? 0
    let quietColumn = (200..<400).map { brightness(x: $0, y: upper) }.max() ?? 0
    #expect(loudColumn > 180 && quietColumn < 60, "响 \(loudColumn)，静 \(quietColumn)")
    // 底色不透明（它是卡片上的图，半透明会透出卡片下面桌面的字）
    #expect(data[3] == 255 && data[row * 125 + 399 * 4 + 3] == 255)
    #expect(AudioRecorder.waveform([]) != nil)  // 不到一个样本也有图（全是最矮的竖条）
  }

  /// 结果岛把「录屏」换成「录音」；拒绝授权是「需要麦克风授权」；闪退恢复读录音自己的偏好键、名字「录音 ….m4a」
  @Test func summaryAndRecoverSpeakAudio() async throws {
    let saved = URL(filePath: "/tmp/录音 2026-09-30 10.00.00.m4a")
    func summary(_ file: URL?, moved: Bool = true, _ reason: ScreenRecorder.Reason) -> [String] {
      let result = ScreenRecorder.Result(
        file: file, moved: moved, duration: .seconds(65), reason: reason)
      guard let text = ScreenRecorder.summary(result, folder: "桌面", medium: .audio) else {
        return []
      }
      return [text.title, text.detail, "\(text.tone)"]
    }
    #expect(summary(saved, .user) == ["已保存录音", "录音 2026-09-30 10.00.00.m4a · 1:05", "success"])
    #expect(summary(saved, .sleep) == ["已保存已录的部分", "睡眠前已自动停止 · 1:05", "warning"])
    #expect(summary(saved, .microphoneLost) == ["已保存已录的部分", "麦克风断开了，已自动停止 · 1:05", "warning"])
    #expect(summary(saved, moved: false, .user) == ["录音没能存进「桌面」", "已在访达中显示 · 1:05", "warning"])
    #expect(summary(nil, .failed("没能开始录音")) == ["录音失败", "没能开始录音", "error"])
    #expect(summary(nil, .discarded) == ["已放弃录音", "没有保存", "info"])
    #expect(summary(nil, .denied) == ["需要麦克风授权", "到 系统设置 › 麦克风 里打开", "warning"])
    #expect(summary(nil, .cancelled) == [])

    let suite = "kitty-test-audio-recover-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-audio-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let broken = folder.appending(path: "录音 \(UUID()).m4a")
    try Data().write(to: broken)
    defaults.set(broken.path, forKey: Prefs.audioRecordingInProgress)
    // 录屏的键上没东西：录屏那一次不管它
    #expect(await ScreenRecorder.recover(into: folder, defaults: defaults) == nil)
    let found = try #require(
      await ScreenRecorder.recover(into: folder, defaults: defaults, medium: .audio))
    #expect(found.title == "上次录音没有正常结束，文件打不开")
    #expect(defaults.string(forKey: Prefs.audioRecordingInProgress) == nil)
    let start = Date(timeIntervalSinceNow: -86_400)
    try FileManager.default.setAttributes([.creationDate: start], ofItemAtPath: broken.path)
    #expect(
      ScreenRecorder.savedURL(for: broken, in: folder, medium: .audio)
        == ScreenshotOutput.availableURL(in: folder, date: start, prefix: "录音", ext: "m4a"))
    #expect(
      ScreenRecorder.workFile(for: folder, medium: .audio).lastPathComponent.hasPrefix("录音 "))
  }

  /// 授权（注入，不真弹框、不真录音）：拒绝过 = 不录、岛「需要麦克风授权」、收尾时打开系统设置（microphoneDenied）；
  /// 没问过、刚点了不允许 = 不录、不打开系统设置；等授权框时再按了一次（stop）= 框返回后当取消、不出岛。都不留文件和「进行中」记录
  @Test func permissionOutcomes() async throws {
    let suite = "kitty-test-audio-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-audio-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    func run(
      _ status: AVAuthorizationStatus, answer: Bool = false, stopsWhileAsking: Bool = false
    ) async throws -> ScreenRecorder.Result {
      var finished: ScreenRecorder.Result?
      let recorder = AudioRecorder(directory: folder, defaults: defaults) { finished = $0 }
      var pending: CheckedContinuation<Bool, Never>?
      recorder.microphoneStatus = { status }
      recorder.requestMicrophone = { await withCheckedContinuation { pending = $0 } }
      recorder.start()
      #expect(defaults.string(forKey: Prefs.audioRecordingInProgress) != nil)
      if status == .notDetermined {
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        if stopsWhileAsking { recorder.stop() }
        try #require(pending).resume(returning: answer)
      }
      for _ in 0..<100 where finished == nil { try await Task.sleep(for: .milliseconds(10)) }
      let result = try #require(finished, "没收尾")
      #expect(result.file == nil && result.duration == .zero && result.poster == nil)
      #expect(defaults.string(forKey: Prefs.audioRecordingInProgress) == nil)
      return result
    }

    let denied = try await run(.denied)
    #expect(denied.reason == .denied && denied.microphoneDenied)
    let restricted = try await run(.restricted)
    #expect(restricted.reason == .denied && restricted.microphoneDenied)
    let refused = try await run(.notDetermined, answer: false)
    #expect(refused.reason == .denied && !refused.microphoneDenied)
    let cancelled = try await run(.notDetermined, answer: true, stopsWhileAsking: true)
    #expect(cancelled.reason == .cancelled)
    #expect(ScreenRecorder.summary(cancelled, folder: "桌面", medium: .audio) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }
}
