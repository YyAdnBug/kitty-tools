// 录屏第 1 批的纯函数（ScreenRecorder）：输出像素尺寸（宽或高超过 4096 等比缩、偶数）、菜单栏计时与旁白时长、
// 流停止 / 开录失败的错误码怎么归类、写入失败时按哪个原因说、结果岛的文案、存盘名字按开录时刻、闪退恢复（文件不在 / 打不开）。
// 真录制在按需实录自检 RecordingProbeTests.screenRecorderTake。

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
      let text = ScreenRecorder.summary(result, folder: "桌面")
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
  }
}
