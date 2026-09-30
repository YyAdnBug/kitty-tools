// 录屏第 1 批的纯函数（ScreenRecorder）：输出像素尺寸（宽或高超过 4096 等比缩、偶数）、菜单栏计时与旁白时长、
// 流停止 / 开录失败的错误码怎么归类、写入失败时按哪个原因说、结果岛的文案、存盘名字按开录时刻、闪退恢复（文件不在 / 打不开）；
// 第 2 批：倒数秒数与播报、放弃 / 取消的结果、录屏设置的默认值。HUD 在 RecordingHUDTests。
// 第 3 批：最后一帧的取帧时刻与尺寸上限、取不到时 nil。视频卡在 VideoCardTests。
// 第 4 批：录制条三个开关的默认值与读偏好、按开关配流和挂哪几路空输出、麦克风授权这一步怎么走、麦克风出错的原因、
// 麦克风中途断开时的结果岛、等麦克风授权框时停止（当取消、开关弹回）。录制条本身在 SelectionInteractionTests，HUD 的声音状态在
// RecordingHUDTests。
// 录音第 6 批（只录声音模式）：录的那一小块（屏内左上角 64 × 64 点）、存盘名的扩展名跟着文件走。
// 真录制在按需实录自检 RecordingProbeTests.screenRecorderTake / audioRecorderSystemTake。

import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing

@testable import KittyTools

struct ScreenRecorderTests {
  /// 原生像素 = 点 × 每点像素；宽或高超过 4096 等比缩到都不超过（第 0 批实测 H.264 硬件编码卡边长）；取偶数、至少 2
  @Test func outputSizeCapsLongestSideAndStaysEven() {
    let size = { (width: CGFloat, height: CGFloat, scale: CGFloat) in
      let size = ScreenRecorder.outputSize(
        points: CGSize(width: width, height: height), scale: scale)
      return [size.width, size.height]
    }
    #expect(size(1710, 1112, 2) == [3420, 2224])  // MacBook Air 整屏，不缩
    #expect(size(400.5, 300, 2) == [800, 600])  // 801 取偶
    #expect(size(2560, 1440, 2) == [4096, 2304])  // 5K 整屏：等比缩到宽 4096
    #expect(size(1440, 2560, 2) == [2304, 4096])  // 竖放的 5K：高到 4096
    #expect(size(2048, 1440, 2) == [4096, 2880])  // 正好 4096 不缩
    #expect(size(0.4, 0.4, 1) == [2, 2])
  }

  @Test func clockAndSpokenDuration() {
    #expect(ScreenRecorder.clock(0) == "0:00")
    #expect(ScreenRecorder.clock(12) == "0:12")
    #expect(ScreenRecorder.clock(605) == "10:05")
    #expect(ScreenRecorder.clock(3723) == "1:02:03")
    #expect(ScreenRecorder.spoken(12) == "12 秒")
    #expect(ScreenRecorder.spoken(65) == "1 分 5 秒")
    #expect(ScreenRecorder.spoken(3723) == "1 小时 2 分 3 秒")
  }

  /// 控制中心「停止共享」（-3817）算用户停的；-3821 提示看磁盘；开录报 -3801 / -3802 按授权问题
  @Test func errorCodesMapToReasons() {
    let domain = SCStreamError.errorDomain
    #expect(ScreenRecorder.reason(streamStopped: domain, code: -3817, text: "") == .user)
    let system = ScreenRecorder.reason(streamStopped: domain, code: -3821, text: "stopped")
    #expect(system == .system(code: -3821, text: "stopped"))
    #expect(system.note == "系统停止了录制，看看磁盘空间")
    #expect(
      ScreenRecorder.reason(streamStopped: domain, code: -3811, text: "").note
        == "系统停止了录制（错误 -3811）")
    // 别的错误域里的同一个数不算
    #expect(
      ScreenRecorder.reason(streamStopped: NSCocoaErrorDomain, code: -3817, text: "")
        == .system(code: -3817, text: ""))
    for code in [-3801, -3802] {
      #expect(
        ScreenRecorder.reason(startFailed: NSError(domain: domain, code: code)) == .denied,
        "\(code)")
    }
    guard
      case .failed(let text) = ScreenRecorder.reason(
        startFailed: NSError(
          domain: domain, code: -3815, userInfo: [NSLocalizedDescriptionKey: "没有可录的屏幕"]))
    else {
      Issue.record("-3815 应按失败说")
      return
    }
    #expect(text == "没能开始录制：没有可录的屏幕")
    #expect(ScreenRecorder.Reason.user.note == nil)
    #expect(ScreenRecorder.Reason.locked.note == "锁屏时已自动停止")
    // 第 4 批：-3820 麦克风出错——流停了按系统中止收尾、原因说麦克风；开录就报这个也说麦克风
    #expect(
      ScreenRecorder.reason(streamStopped: domain, code: -3820, text: "mic").note
        == "麦克风出了问题，已自动停止")
    #expect(
      ScreenRecorder.reason(startFailed: NSError(domain: domain, code: -3820))
        == .failed("没能开始录制：麦克风出了问题"))
  }

  /// 停止原因第一个为准：磁盘满时系统停流（-3821）和写入失败一起来，已经记下的中断原因不被「写入失败」盖掉；
  /// 用户停的、还没停的按写入失败说（用户停的不能说成「已保存录屏」）
  @Test func writeFailureKeepsEarlierInterruption() {
    let full = ScreenRecorder.Reason.system(code: -3821, text: "stopped")
    #expect(ScreenRecorder.reason(writeFailed: "No space", stopping: full) == full)
    #expect(ScreenRecorder.reason(writeFailed: "x", stopping: .locked) == .locked)
    #expect(ScreenRecorder.reason(writeFailed: "x", stopping: .user) == .failed("写入失败：x"))
    #expect(ScreenRecorder.reason(writeFailed: "x", stopping: nil) == .failed("写入失败：x"))
  }

  /// 挪进快速保存目录用的名字按文件的创建时间（开录那一刻），不按挪的时刻
  @Test func savedNameUsesRecordingStart() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-rec-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "录屏 \(UUID()).mp4")
    try Data().write(to: file)
    let start = Date(timeIntervalSinceNow: -3 * 86_400)
    try FileManager.default.setAttributes([.creationDate: start], ofItemAtPath: file.path)
    #expect(
      ScreenRecorder.savedURL(for: file, in: folder)
        == ScreenshotOutput.availableURL(in: folder, date: start, prefix: "录屏", ext: "mp4"))
  }

  /// 闪退恢复（C7）：记录指向的文件不在了 = 只删记录、不提示；打不开 = 留在原地、警告带路径和大小、删记录（只提示一次）；
  /// 能播那条在实录自检里。都用临时偏好域和临时目录
  @Test func recoverDropsRecordAndKeepsBrokenFile() async throws {
    let suite = "kitty-test-recover-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-rec-\(UUID())")
    let saved = folder.appending(path: "saved")
    try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(await ScreenRecorder.recover(into: saved, defaults: defaults) == nil)
    defaults.set(folder.appending(path: "gone.mp4").path, forKey: Prefs.screenRecordingInProgress)
    #expect(await ScreenRecorder.recover(into: saved, defaults: defaults) == nil)
    #expect(defaults.string(forKey: Prefs.screenRecordingInProgress) == nil)

    let broken = folder.appending(path: "录屏 \(UUID()).mp4")
    try Data().write(to: broken)
    defaults.set(broken.path, forKey: Prefs.screenRecordingInProgress)
    let found = try #require(await ScreenRecorder.recover(into: saved, defaults: defaults))
    #expect(found.title == "上次录屏没有正常结束，文件打不开")
    #expect(
      found.detail
        == "\((broken.path as NSString).abbreviatingWithTildeInPath) · \(Int64(0).formatted(.byteCount(style: .file)))"
    )
    #expect("\(found.tone)" == "warning")
    #expect(FileManager.default.fileExists(atPath: broken.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: saved.path).isEmpty)
    #expect(defaults.string(forKey: Prefs.screenRecordingInProgress) == nil)
    #expect(await ScreenRecorder.recover(into: saved, defaults: defaults) == nil)
  }

  /// 结果岛：正常 = 已保存 + 文件名 · 时长；中断 = 警告「已保存已录的部分」+ 原因 · 时长；挪不过去 = 警告 + 路径；
  /// 没录下 = 错误；授权 = 警告
  @Test func summaryWording() {
    let saved = URL(filePath: "/tmp/录屏 2026-09-30 10.00.00.mp4")
    func summary(
      _ file: URL?, moved: Bool = true, seconds: Int64 = 72, _ reason: ScreenRecorder.Reason
    )
      -> [String]
    {
      let result = ScreenRecorder.Result(
        file: file, moved: moved, duration: .seconds(seconds), reason: reason)
      guard let text = ScreenRecorder.summary(result, folder: "桌面") else { return [] }
      return [text.title, text.detail, "\(text.tone)"]
    }
    #expect(summary(saved, .user) == ["已保存录屏", "录屏 2026-09-30 10.00.00.mp4 · 1:12", "success"])
    #expect(summary(saved, .locked) == ["已保存已录的部分", "锁屏时已自动停止 · 1:12", "warning"])
    #expect(
      summary(saved, .lowDisk) == ["已保存已录的部分", "磁盘剩余不到 1 GB，已自动停止 · 1:12", "warning"])
    #expect(summary(saved, moved: false, .user) == ["录屏没能存进「桌面」", "已在访达中显示 · 1:12", "warning"])
    #expect(summary(nil, .failed("没能开始录制")) == ["录屏失败", "没能开始录制", "error"])
    #expect(summary(nil, .user) == ["录屏失败", "没有录下内容", "error"])
    #expect(summary(nil, .denied)[0] == "需要「屏幕录制」授权")
    // 第 2 批：放弃 = 信息岛（文件已删）；倒数中取消 = 不出岛（AppDelegate 只播报「已取消」）
    #expect(summary(nil, .discarded) == ["已放弃录屏", "没有保存", "info"])
    #expect(summary(saved, .discarded) == ["已放弃录屏", "没有保存", "info"])
    #expect(summary(nil, .cancelled) == [])
    #expect(
      ScreenRecorder.Reason.discarded.note == nil && ScreenRecorder.Reason.cancelled.note == nil)
    // 第 4 批：录制中麦克风断开——正常停也是警告岛（用户要知道），卡片上有文件，详情省掉文件名；中断 / 挪不进目录的补在时长前
    func lost(_ reason: ScreenRecorder.Reason, moved: Bool = true) -> [String] {
      var result = ScreenRecorder.Result(
        file: saved, moved: moved, duration: .seconds(72), reason: reason)
      result.microphoneLost = true
      guard let text = ScreenRecorder.summary(result, folder: "桌面") else { return [] }
      return [text.title, text.detail, "\(text.tone)"]
    }
    #expect(lost(.user) == ["已保存录屏", "后半段没有麦克风声音 · 1:12", "warning"])
    #expect(lost(.locked) == ["已保存已录的部分", "锁屏时已自动停止 · 后半段没有麦克风声音 · 1:12", "warning"])
    #expect(
      lost(.user, moved: false) == ["录屏没能存进「桌面」", "已在访达中显示 · 后半段没有麦克风声音 · 1:12", "warning"])
    #expect(lost(.discarded) == ["已放弃录屏", "没有保存", "info"])
  }

  /// 倒数（拍板 R9-a）：设置给 0 / 3 / 5，0…5 之间照用（实录自检用 1 s），出了范围按默认 3；播报按实际秒数
  @Test func countdownSecondsAndAnnouncement() {
    #expect([0, 1, 3, 5].map(ScreenRecorder.countdownSeconds) == [0, 1, 3, 5])
    #expect([-1, 6, 100].map(ScreenRecorder.countdownSeconds) == [3, 3, 3])
    #expect(ScreenRecorder.countdownAnnouncement(3, escapes: true) == "3 秒后开始录屏，按 Esc 取消")
    #expect(ScreenRecorder.countdownAnnouncement(5, escapes: true) == "5 秒后开始录屏，按 Esc 取消")
    // Esc 没注册上：不提它
    #expect(ScreenRecorder.countdownAnnouncement(3, escapes: false) == "3 秒后开始录屏")
  }

  /// 放弃 / 取消过就按它收尾：放弃后写完超时、取消挂着时没开起来或流先停了，都不能说成失败或「已保存已录的部分」
  /// （finalize 只在放弃 / 取消时删文件，summary 按它出信息岛 / 不出岛）；没放弃按 record 返回的
  @Test func abandonedWinsOverLaterEnding() {
    let timedOut = ScreenRecorder.Reason.failed("文件没有按时写完")
    #expect(ScreenRecorder.outcome(timedOut, abandoned: .discarded) == .discarded)
    #expect(ScreenRecorder.outcome(.failed("没能开始录制"), abandoned: .cancelled) == .cancelled)
    #expect(
      ScreenRecorder.outcome(.system(code: -3821, text: ""), abandoned: .cancelled) == .cancelled)
    #expect(ScreenRecorder.outcome(timedOut, abandoned: nil) == timedOut)
    #expect(ScreenRecorder.outcome(.locked, abandoned: nil) == .locked)
  }

  /// 最后一帧（第 3 批，R11-a）：时长前 0.1 s 取（正好在时长上常取不到），不到 0.1 s 的取开头；尺寸按选区像素、
  /// 长边不超过 1600（不解整张 5K），本来就小的不放大
  @Test func posterTimeAndLimit() {
    #expect(abs(ScreenRecorder.posterTime(2.1) - 2.0) < 1e-9)
    #expect(ScreenRecorder.posterTime(0.05) == 0)
    #expect(ScreenRecorder.posterTime(0) == 0)
    #expect(
      ScreenRecorder.posterLimit(CGSize(width: 3420, height: 2224))
        == CGSize(width: 1600, height: 1040))
    #expect(
      ScreenRecorder.posterLimit(CGSize(width: 2304, height: 4096))
        == CGSize(width: 900, height: 1600))
    #expect(
      ScreenRecorder.posterLimit(CGSize(width: 1280, height: 720))
        == CGSize(width: 1280, height: 720))
  }

  /// 文件不在 / 不是视频：没有 poster（AppDelegate 只出岛、卡片用播放符号占位），不抛不卡
  @Test func posterMissingFileIsNil() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-rec-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let size = CGSize(width: 1280, height: 720)
    #expect(
      await ScreenRecorder.poster(of: folder.appending(path: "gone.mp4"), pixels: size) == nil)
    let empty = folder.appending(path: "empty.mp4")
    try Data().write(to: empty)
    #expect(await ScreenRecorder.poster(of: empty, pixels: size) == nil)
  }

  /// 设置 › 截图「录屏」的默认值（拍板 C4-a）：30 fps、倒数 3 秒、显示光标。只写注册域（不落盘）
  @Test func recordingDefaults() {
    Prefs.registerDefaults()
    let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    #expect(registered[Prefs.screenRecordFrameRate] as? Int == 30)
    #expect(registered[Prefs.screenRecordCountdown] as? Int == 3)
    #expect(registered[Prefs.screenRecordShowsCursor] as? Bool == true)
    // 第 4 批：录制条的开关——系统声音开、麦克风关、显示点按关
    #expect(registered[Prefs.screenRecordSystemAudio] as? Bool == true)
    #expect(registered[Prefs.screenRecordMicrophone] as? Bool == false)
    #expect(registered[Prefs.screenRecordShowsClicks] as? Bool == false)
  }

  /// 录制条三个开关从偏好读：没存过按默认（临时偏好域里没有注册域，默认写在 Options 里、和 registerDefaults 一致），存过的照读
  @Test func optionsFromDefaults() throws {
    let suite = "kitty-test-options-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ScreenRecorder.Options(defaults) == ScreenRecorder.Options())
    #expect(
      ScreenRecorder.Options() == .init(systemAudio: true, microphone: false, showsClicks: false))
    defaults.set(false, forKey: Prefs.screenRecordSystemAudio)
    defaults.set(true, forKey: Prefs.screenRecordMicrophone)
    defaults.set(true, forKey: Prefs.screenRecordShowsClicks)
    #expect(
      ScreenRecorder.Options(defaults)
        == .init(systemAudio: false, microphone: true, showsClicks: true))
  }

  /// 按开关配流：录什么挂什么空输出（画面总挂）；系统声音 48 kHz 立体声；麦克风跟随系统输入；显示点按要 BGRA，
  /// 关着时不动默认像素格式（也不开点按）
  @Test func configureFollowsOptions() {
    let plain = SCStreamConfiguration()
    let defaultFormat = plain.pixelFormat
    #expect(
      ScreenRecorder.configure(
        plain, .init(systemAudio: false, microphone: false, showsClicks: false))
        == [.screen])
    #expect(!plain.capturesAudio && !plain.captureMicrophone && !plain.showMouseClicks)
    #expect(plain.pixelFormat == defaultFormat)

    let all = SCStreamConfiguration()
    #expect(
      ScreenRecorder.configure(all, .init(systemAudio: true, microphone: true, showsClicks: true))
        == [.screen, .audio, .microphone])
    #expect(all.capturesAudio && all.sampleRate == 48_000 && all.channelCount == 2)
    #expect(all.captureMicrophone && all.microphoneCaptureDeviceID == nil)
    #expect(all.showMouseClicks && all.pixelFormat == kCVPixelFormatType_32BGRA)

    let micOnly = SCStreamConfiguration()
    #expect(
      ScreenRecorder.configure(micOnly, .init(systemAudio: false, microphone: true))
        == [.screen, .microphone])
    #expect(!micOnly.capturesAudio && micOnly.captureMicrophone)
  }

  /// 麦克风这一步（C1-a）：开关关着不管授权；允许就录；没问过才问（遮罩收起后）；拒绝过、受限不再问（照样开录、不带麦克风）
  @Test func microphoneAccessSteps() {
    let access = ScreenRecorder.microphoneAccess
    for status in [AVAuthorizationStatus.notDetermined, .denied, .restricted, .authorized] {
      #expect(access(false, status) == .unused)
    }
    #expect(access(true, .authorized) == .granted)
    #expect(access(true, .notDetermined) == .ask)
    #expect(access(true, .denied) == .denied)
    #expect(access(true, .restricted) == .denied)
  }

  /// 麦克风授权框开着时要停（再按快捷键、锁屏、退出……）：框返回后直接取消，不进倒数、不开流、不留文件（倒数 0 也一样）；
  /// 点了不允许：开关弹回（下次录制条上是关的），刚点的不打开系统设置。授权状态和系统框都是注入的，不真弹框、不真开流
  @Test func stopWhileAskingMicrophoneCancels() async throws {
    let suite = "kitty-test-mic-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(0, forKey: Prefs.screenRecordCountdown)
    defaults.set(true, forKey: Prefs.screenRecordMicrophone)
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-mic-\(UUID())")
    let screen = try #require(NSScreen.screens.first).frame
    var finished: ScreenRecorder.Result?
    let recorder = try #require(
      ScreenRecorder(
        region: CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 320, height: 200),
        directory: folder, defaults: defaults
      ) { finished = $0 })
    var answer: CheckedContinuation<Bool, Never>?
    recorder.microphoneStatus = { .notDetermined }
    recorder.requestMicrophone = { await withCheckedContinuation { answer = $0 } }
    recorder.start()
    for _ in 0..<100 where answer == nil { try await Task.sleep(for: .milliseconds(10)) }
    recorder.stop()  // 屏幕上还什么都没有时再按了一次 ⌥R
    try #require(answer).resume(returning: false)
    for _ in 0..<100 where finished == nil { try await Task.sleep(for: .milliseconds(10)) }
    let result = try #require(finished, "没收尾")
    #expect(result.reason == .cancelled && result.file == nil && result.duration == .zero)
    #expect(!result.microphoneDenied)
    #expect(!ScreenRecorder.Options(defaults).microphone)
    #expect(ScreenRecorder.summary(result, folder: "桌面") == nil)
  }

  /// 只录声音（录音第 6 批）：那块屏左上角 64 × 64 点，sourceRect 是屏内 (0, 0, 64, 64)；副屏也一样
  @Test func audioOnlyRegionIsTopLeftCorner() {
    for screen in [
      CGRect(x: 0, y: 0, width: 1440, height: 900),
      CGRect(x: 1440, y: -200, width: 1920, height: 1080),
    ] {
      let region = ScreenRecorder.audioOnlyRegion(screen)
      #expect(region == CGRect(x: screen.minX, y: screen.maxY - 64, width: 64, height: 64))
      let rect = RegionSelector.captureRect(region, in: screen, scale: 2)
      #expect(rect.region == region && rect.source == CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    #expect(ScreenRecorder.audioOnlyPixels == 128)
  }
}
