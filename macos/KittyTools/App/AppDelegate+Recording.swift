// AppDelegate 里的录屏、录音（第五轮体检 H1 从 AppDelegate.swift 拆出）：开录前的拦阻、开录、结果落地（飞入、视频卡 / 录音卡）。

import AppKit
import SwiftUI

extension AppDelegate {
  /// 录屏：在录（含倒数）就停止 / 取消；否则冻结各屏、框选（同截图：窗口、整屏、拖框、D 上次区域，和截图共用上次区域），
  /// 交回选区后开录（按设置先倒数）。isCapturing 只占框选阶段：开录后录制状态在 recorder 里，截图、识字照常，
  /// 再按一次快捷键就停（C9）
  func screenRecord() {
    if let recorder { return recorder.stop() }
    guard !refusesRecording(.screen) else { return }
    beginCapture(hidingPanels: false) { [self] in
      let lastRegion = UserDefaults.standard.string(forKey: Prefs.screenshotLastRegion).map(
        NSRectFromString)
      guard
        let outcome = await frozenSelection(
          "录屏", { await RegionSelector.record($0, lastRegion: lastRegion) })
      else { return nil }
      switch outcome {
      case .color(let hex): copyColor(hex)
      case .record(let region): beginRecording(region)
      case .capture, .scroll: break
      }
      return nil
    }
  }

  /// 现在开不了 medium 的原因（岛的标题、说明；nil = 能录）：录屏和录音互斥（C9-a，另一种在录，含倒数、等授权）、
  /// 同一种已经在录（录屏中截图再按 R）、正在装更新（装好会退出重新打开，录到一半会被截断；录制中的「不能更新」只防得住
  /// 先录后更新）。录音待录（控制条开着、没开始）不算在录：不拦录屏，真要录屏时 beginRecording 把控制条收掉
  func recordingBlocker(_ medium: ScreenRecorder.Medium) -> (title: String, detail: String)? {
    let busy = String(localized: "先停止这一段再录")
    if recorder != nil {
      return (
        medium == .screen ? String(localized: "已经在录屏") : String(localized: "正在录屏"), busy
      )
    }
    if audioRecorder?.isStarted == true {
      return (
        medium == .audio ? String(localized: "已经在录音") : String(localized: "正在录音"), busy
      )
    }
    if case .installing = updater.state {
      return (
        String(localized: "正在更新"),
        medium == .screen
          ? String(localized: "装好会自动重新打开，之后再录屏")
          : String(localized: "装好会自动重新打开，之后再录音")
      )
    }
    return nil
  }

  /// 开不了就出警告岛，返回 true
  private func refusesRecording(_ medium: ScreenRecorder.Medium) -> Bool {
    guard let blocker = recordingBlocker(medium) else { return false }
    island.show("\(blocker.title)", detail: "\(blocker.detail)", tone: .warning)
    return true
  }

  /// 录音（录音第 5 批，拍板 A1-a；手测反馈第 3 批改成先出控制条）：没有会话时，默认先在屏幕底部出录音控制条（待录，不录），
  /// 设置 › 录制「按快捷键后立即开始录音」开着才直接开始；待录时再触发（快捷键 / 菜单栏 / 启动器，或点控制条的 ●）= 开始；
  /// 录着时 = 停止（菜单栏 / 启动器这时叫「停止录音」）。录什么看来源（设置 › 录制「录音」、待录的控制条上都能改，第 6 批）。
  /// 和录屏互斥（C9-a）：录屏在录（含倒数、等麦克风授权）时岛说先停止那一段；正在装更新时不开录（同录屏）
  func audioRecord() {
    if let audioRecorder {
      return audioRecorder.isStarted ? audioRecorder.stop() : audioRecorder.start()
    }
    guard !refusesRecording(.audio) else { return }
    let immediately = UserDefaults.standard.bool(forKey: Prefs.audioRecordStartsImmediately)
    // 立即开始：开不了（录系统声音没有屏幕录制授权）就不建会话，同以前
    if immediately, !allowsAudioRecording(AudioRecorder.Source(.standard)) { return }
    let recorder = AudioRecorder(
      directory: ScreenshotOutput.saveDirectory, island: island, hotKeys: hotKeys
    ) { [weak self] in
      self?.recorded($0, .audio)
    }
    audioRecorder = recorder
    ReminderSound.stop()  // 正在放的长提示音别录进去（提醒 C11）
    if immediately { return recorder.start() }
    // 先出控制条：来源可能在控制条上改，真正开始那一刻（点 ●、再触发一次）才查
    recorder.allowsStart = { [weak self] in self?.allowsAudioRecording($0) ?? false }
    recorder.open()
  }

  /// 真正开始录音那一刻能不能录（开不了已出警告岛）：互斥和正在装更新再看一次（待录期间状态可能变了）；录系统声音走录屏
  /// 管线，要「屏幕录制」授权（同截图，screenRecordingAllowed）。能录就从这时起挡更新（待录时不挡）
  private func allowsAudioRecording(_ source: AudioRecorder.Source) -> Bool {
    guard !refusesRecording(.audio),
      source == .microphone || screenRecordingAllowed(for: "录系统声音")
    else { return false }
    updater.blocker = String(localized: "录制结束后再更新")
    return true
  }

  /// 待录的录音控制条当场收掉（还没开始，没有东西要收尾、不等回调）：要录屏了、退出 App。在录的不动
  func closeReadyAudio() {
    guard let audioRecorder, !audioRecorder.isStarted else { return }
    audioRecorder.close()
    self.audioRecorder = nil
  }

  /// 框选交回录屏选区（⌥R 的框选、截图里按 R 切过去的）：记成上次区域（和截图共用）、收走压在选区上的常驻缩略图
  /// （同长截图；钉图照常录进去）、开录（先倒数）
  func beginRecording(_ region: CGRect) {
    // 截图里按 R 时已经问过（SelectionSession.recordingBlocker，停在截图里）；框选期间状态还可能变（系统睡眠停了录音、
    // 更新开始装），这里兜底
    guard !refusesRecording(.screen) else { return }
    // 倒数的那几秒便签的药丸不响应（canFanNotes），扇着的一列先收起；打开着的便签留着（它是内容，会录进去）
    noteEdge?.suspend(.keepsOpen)
    closeReadyAudio()  // 录音控制条开着、还没开始：收掉，照常录屏（录屏和录音只留一个）
    UserDefaults.standard.set(NSStringFromRect(region), forKey: Prefs.screenshotLastRegion)
    shelf.dismiss(covering: region)
    guard
      let recorder = ScreenRecorder(
        region: region, directory: ScreenshotOutput.saveDirectory, hotKeys: hotKeys,
        island: island, onFinish: { [weak self] in self?.recorded($0, .screen) })
    else {
      return island.show("没能开始录屏", detail: "找不到选区所在的屏幕", tone: .warning)
    }
    self.recorder = recorder
    updater.blocker = String(localized: "录制结束后再更新")
    ReminderSound.stop()  // 正在放的长提示音别录进去（提醒 C11）
    recorder.start()
  }

  /// 录屏 / 录音收尾：文件已挪进快速保存目录（挪不过去的留在原地、在访达里选中），刘海岛说结果（成功时岛让菜单栏图标弹一下）；
  /// 挪进去了还要飞卡片、留视频卡 / 录音卡（landRecording）。倒数中（录音：等授权框时、关掉待录的控制条）取消的不出岛，只播报。录制中麦克风断开的
  /// （第 4 批）summary 是警告：卡片照飞，岛也出来说「后半段没有麦克风声音」；开着麦克风（录音总是）但之前拒绝过授权的，这时打开
  /// 系统设置的麦克风页（录音被拒时岛说「需要麦克风授权」，第 5 批）；开着显示按键但没有辅助功能授权的同样这时去授权（Permissions.grant）
  private func recorded(_ result: ScreenRecorder.Result, _ medium: ScreenRecorder.Medium) {
    if medium == .screen { recorder = nil } else { audioRecorder = nil }
    // 关掉待录的录音控制条也走到这里（按取消收尾）：另一种在录时不替它放开更新
    if recorder == nil, audioRecorder?.isStarted != true { updater.blocker = nil }
    defer {
      if quitsAfterRecording {
        quitsAfterRecording = false
        replyQuit()
      }
    }
    // 开录报屏幕录制授权问题（录屏、录系统声音）
    if result.reason == .denied { Permissions.Kind.screenRecording.openSettings() }
    // 开着麦克风但之前拒绝过：开录时只出了警告岛，这时才打开（开录前打开会盖住选区、录进画面）
    if result.microphoneDenied { Permissions.Kind.microphone.openSettings() }
    // 开着显示按键但没有辅助功能授权（手测反馈第 2 批）：同样到这时才去授权（Permissions.grant，第五轮体检 U11：从没问过
    // 只弹系统框——它自己带「打开系统设置」，也让本 App 进系统设置的列表；问过了才打开辅助功能页，不再两样一起来）。
    // 麦克风页刚打开的这次不管它（再弹框、再开一页会把前一个盖掉，用户只看得到后一个）：开关已经弹回，下次打开显示按键再提示
    if result.keysDenied, !result.microphoneDenied { Permissions.grant(.accessibility) }
    // 挪不进快速保存目录：在访达里选中留下的文件，马上能拖走
    if let file = result.file, !result.moved {
      NSWorkspace.shared.activateFileViewerSelecting([file])
    }
    // 存下的名字，不去问保存目录（可能在卡住的网络盘上，第五轮体检 P2）
    let folder = ScreenshotOutput.saveFolderName
    guard let summary = ScreenRecorder.summary(result, folder: folder, medium: medium) else {
      return Island.announce("已取消")
    }
    var leading = Island.Leading.tone
    if result.moved, let file = result.file {
      // 飞过去了：落地的角标已写目录名，正常停的不再出岛（同截图快速保存），只给 VoiceOver 说一句
      if landRecording(file, result, medium), summary.tone == .success {
        let spoken = ScreenRecorder.spoken(Int(result.duration.components.seconds))
        return Island.announce(
          medium == .screen ? "录屏已保存到「\(folder)」，\(spoken)" : "录音已保存到「\(folder)」，\(spoken)")
      }
      if summary.tone == .success, let poster = result.poster {
        leading = Island.thumbnail(of: poster)
      }
    }
    let symbol = medium == .screen ? "video.circle.fill" : "waveform.circle.fill"
    // 挪不进去是没有写权限（U7）：出路换成「打开系统设置」「更改保存位置」（文件已经在访达里选中了）
    let actions =
      result.moveDenied ? saveFolderActions : result.file.map([Island.Action].file) ?? []
    island.show(
      "\(summary.title)", detail: "\(summary.detail)", tone: summary.tone,
      symbol: summary.tone == .success ? symbol : nil, leading: leading, actions: actions)
  }

  /// 录屏存进快速保存目录后（拍板 R11-a）：最后一帧从选区（整屏录制就是那块屏）按 S1 飞到右下角，没有快门声，落地弹文件夹
  /// 角标，再交给常驻缩略图的视频卡（设置里关了常驻缩略图就停 0.9 s 自己滑走）。减弱动态效果、没取到最后一帧时不飞，
  /// 视频卡在角落淡入（关了常驻缩略图就只有岛）。录音（第 5 批，A5-a）同一套：波形图从 HUD 的位置（result.region，和图同比例的
  /// 小框）长到录音卡那么大（AudioRecorder.posterSize），交给录音卡。返回飞了没有（飞了的正常停不再出岛）
  private func landRecording(
    _ file: URL, _ result: ScreenRecorder.Result, _ medium: ScreenRecorder.Medium
  ) -> Bool {
    let seconds = Int(result.duration.components.seconds)
    let audio = medium == .audio
    // 录制的也进同一个历史（拍板 B1）：只记文件路径和一张封面，不复制那个文件。
    // 挂到晾衣绳上要它的编号：记完再挂（R4：原来异步赋值、不飞的那条路同步就挂，编号一定是空的，绳子空着下来又收回）
    let source = frontmostAppName()
    let remembered = Task {
      await shotHistory.record(
        file: file, poster: result.poster, kind: audio ? .audio : .video, source: source)
    }
    let size = audio ? AudioRecorder.posterSize : nil
    let pixels = result.poster.map { CGSize(width: $0.width, height: $0.height) } ?? size ?? .zero
    let landing = shotLanding(pixels: pixels, frame: result.region)
    let slot = landing.slot
    let peg = pegger(remembered, on: landing.screen)
    let flies = result.poster != nil && !Style.reduceMotion
    let linger: (CGRect, FlyCard.Badge) -> Void = { [weak self] rect, _ in
      guard let self else { return }
      switch landing.placement {
      case .corner:
        shelf.add(
          recording: file, seconds: seconds, audio: audio, poster: result.poster,
          source: result.region, at: rect, fadesIn: !flies)
      case .clothesline: peg()
      case .none: break
      }
    }
    let keepsThumbnail = landing.placement != .none
    guard flies, let poster = result.poster else {
      if keepsThumbnail, let rect = slot ?? FlyCard.landingRect(for: result.region, size: size) {
        linger(rect, .saved(file))
      }
      return false
    }
    let flight = FlyCard.fly(
      poster, from: result.region, size: size, to: slot,
      linger: keepsThumbnail ? linger : nil,
      seconds: seconds, audio: audio)
    flight.onShow = { [weak self] in self?.statusItem?.pop() }
    // 文件已经存好了：直接给角标（落地时弹出来）；结果由调用方说（带时长，或中断的岛）
    flight.land(.saved(file), announces: false)
    return true
  }
}
