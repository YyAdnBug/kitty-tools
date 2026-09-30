// 录音会话（录音第 5 批，PLAN §10「录屏与录音」，拍板 A1-a「一键录，先麦克风」、A3-a、A4-a、A5-a、C6-a、C9-a）：
// 按一下开始、再按停止。AVAudioRecorder 录 m4a（AAC、48 kHz、单声道、128 kbps），输入设备跟随系统；在主线程直接用
// （第 0 批实测：init + prepareToRecord 10 ms、record() 冷启动 41 ms）。不挂委托：录着时 20 Hz 的电平定时器顺带看它还在
// 不在录（编码出错这类它会自己停），停了按失败收尾、保住已录的部分（ponytail，上限和升级路径见 tick()）。
// - 授权：开录前看麦克风授权，没问过就问（这里没有遮罩，直接问）；拒绝 / 受限不录，警告岛，之前就拒绝过的打开系统设置。
// - 文件：先写 ScreenRecorder.workFile（和快速保存目录同卷、系统不清理），停止后挪进快速保存目录「录音 <开录时刻>.m4a」，
//   挪不进留在原地、在访达里选中；「进行中」记在偏好里，闪退后下次启动由 ScreenRecorder.recover 接手（同录屏）。
// - 暂停 / 继续：pause() / record() 续写同一个文件（第 0 批实测），计时不算暂停的时间。
// - 电平：20 Hz updateMeters() + averagePower；Levels 留最近 3 s 给 HUD、整段的包络（桶数有上限）给波形 poster。开头 5 s
//   一直低于 −70 dB（数字静音在 −120，安静房间的底噪约 −41 到 −51，第 0 批实测）时 HUD 出「没听到声音」，有声音就收起。
// - 中断（C6-a 录音的写法）：只录麦克风，锁屏、显示器睡眠照录；系统睡眠、开录时的输入设备断开、卷剩余不到 1 GB 停止并保存；
//   录制期间防系统闲置睡眠（不禁显示器睡眠）。
// - 界面：RecordingHUD 的录音形态（鼠标所在屏可见区底部居中）+ 菜单栏「■ 0:42」停止项（同录屏）；停止后电平包络画成波形
//   poster，AppDelegate 从 HUD 的位置按 S1 飞到右下角、交给常驻缩略图的录音卡。
// - 来源（录音第 6 批，拍板 A2-a，设置 › 截图「录音」）：麦克风走上面的 AVAudioRecorder；系统声音 / 两者复用录屏管线
//   （ScreenRecorder 的只录声音模式 engine：鼠标所在屏左上角 64 × 64 点、1 fps，写 mp4、录完无损导出成 m4a）。那两种
//   不能暂停（SCRecordingOutput 没有暂停，HUD 的 ⏸ 置灰）；锁屏、系统睡眠、显示器睡眠、被录的屏变了都停止并保存（同录屏，
//   在 engine 里），所以录制期间同录屏连显示器闲置睡眠一起防；两者的麦克风授权、麦克风中途断开（不停、播报，HUD 计时后面出橙字
//   「麦克风断开了」，结果岛补一句）也照录屏；电平由 engine 在样本回调里算好投过来，「没听到声音」只看麦克风那一路（只录系统
//   声音时不提示）。HUD 出来之前叫停当取消（同只录麦克风）。录音 HUD、停止项、计时、防睡眠、磁盘检查、波形 poster 仍在这里。

import AVFoundation
import AppKit
import OSLog

final class AudioRecorder: NSObject {
  /// 录什么（设置 › 截图「录音」的来源，录音第 6 批）：麦克风能暂停、锁屏照录；系统声音 / 两者走录屏管线——菜单栏有屏幕录制
  /// 指示、锁屏会停、不能暂停
  nonisolated enum Source: String, Sendable {
    case microphone, system, both

    /// 从偏好读；没存过、存的认不出按麦克风（同 Prefs.registerDefaults 给的默认）
    init(_ defaults: UserDefaults) {
      self =
        defaults.string(forKey: Prefs.audioRecordSource).flatMap(Self.init(rawValue:))
        ?? .microphone
    }
  }

  /// m4a：AAC、48 kHz、单声道、128 kbps（拍板 A3-a；第 0 批实测码率生效，128–133 kbps）
  static let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey: 128_000,
  ]
  /// 「没听到声音」的门槛：开头 silenceWindow 里电平一直低于它（A4-a，按第 0 批实测改：安静房间的底噪中位约 −41、最低约
  /// −51 dB，用 −50 会误报；真正要抓的是数字静音 −120，通话占着麦克风、输入音量拉到底这类）
  nonisolated static let silenceThreshold: Float = -70
  nonisolated static let silenceWindow: Duration = .seconds(5)
  /// 波形 poster 的尺寸（点，16:10，和常见的整屏视频卡一样大）；按 2x 出图
  nonisolated static let posterSize = CGSize(width: 200, height: 125)
  /// 电平每秒采几次
  private static let meterRate = 20

  /// 电平历史（纯值类型，配单测）：HUD 要最近 3 s（24 根，每根 2.5 个样本 = 125 ms，取最大），波形 poster 要整段的包络
  /// （最多 envelopeLimit 个桶：满了两两合并、每桶的样本数加倍，录几个小时也不涨）
  nonisolated struct Levels: Equatable {
    static let bars = 24
    static let envelopeLimit = 256
    /// 最近几根（旧 → 新），最多 bars 根
    private(set) var recent: [Float] = []
    /// 整段的包络（旧 → 新），每桶取最大
    private(set) var envelope: [Float] = []
    /// 有没有哪一次到了「没听到声音」的门槛（看 listening 那一路）
    private(set) var heard = false
    private var samples = 0
    private var perBucket = 1
    private var lastBucketFill = 0

    /// power：这一格的电平（HUD 的竖条、波形 poster 画它）；listening：「没听到声音」看的那一路，默认就是 power
    /// （录音第 6 批「两者」：画两路里最响的，只看麦克风有没有声音）
    mutating func add(_ power: Float, listening: Float? = nil) {
      heard = heard || (listening ?? power) >= AudioRecorder.silenceThreshold
      // 第 n 个样本落在第 2n/5 根（每根 2.5 个样本：3、2、3、2…），和上一个样本不在同一根就开新的一根
      if samples == 0 || samples * 2 / 5 != (samples - 1) * 2 / 5 {
        recent.append(power)
        if recent.count > Self.bars { recent.removeFirst(recent.count - Self.bars) }
      } else {
        recent[recent.count - 1] = max(recent[recent.count - 1], power)
      }
      samples += 1
      if envelope.isEmpty || lastBucketFill == perBucket {
        if envelope.count == Self.envelopeLimit {
          envelope = stride(from: 0, to: envelope.count, by: 2).map {
            max(envelope[$0], envelope[min($0 + 1, envelope.count - 1)])
          }
          perBucket *= 2
        }
        envelope.append(power)
        lastBucketFill = 1
      } else {
        envelope[envelope.count - 1] = max(envelope[envelope.count - 1], power)
        lastBucketFill += 1
      }
    }
  }

  /// 这次录什么（开录前从偏好读一次）
  let source: Source
  private let directory: URL
  /// 只录麦克风时写的文件；系统声音 / 两者的文件在 engine 里（这里只拿它查磁盘剩余，同一个卷）
  private let temp: URL
  /// 「进行中」记在哪（单测 / 实录自检换成临时偏好域）
  private let defaults: UserDefaults
  private let onFinish: (ScreenRecorder.Result) -> Void
  /// 麦克风授权此刻的状态、没问过时怎么问（单测换掉：不读真状态、不真弹框）
  var microphoneStatus = { Permissions.microphoneStatus }
  var requestMicrophone = Permissions.requestMicrophone
  /// 两者被拒麦克风授权时的警告岛、导出时的「正在存储录音…」（engine 用；单测 / 实录自检里是 nil）
  private weak var island: Island?
  private var recorder: AVAudioRecorder?
  /// 系统声音 / 两者：录屏管线的只录声音模式（麦克风授权、开流、中断、导出 m4a、挪文件、「进行中」记录都在它那里）
  private var engine: ScreenRecorder?
  /// engine 送来的电平（dB）：这一格（50 ms）里系统声音、麦克风各自最响的一块
  private var pending: (system: Float, microphone: Float) = (-120, -120)
  /// 「没听到声音」看不看：录着麦克风才看（只录系统声音时没在放东西是正常的；两者被拒了麦克风同样不看）
  private var listens = true
  /// 飞入的起点：收 HUD 那一刻记下（engine 的收尾要等文件写完、导出，那时 HUD 早收了）
  private var region: CGRect = .zero
  private(set) var isPaused = false
  /// 要停了（第一个原因为准；收尾在下一轮）
  private var stopping: ScreenRecorder.Reason?
  /// 还没开始录就要停（等授权框时再按了一次快捷键、退出）：开始前当取消
  private var stoppedEarly = false
  /// 电平历史（实录自检读它看电平来过没有）
  private(set) var levels = Levels()
  /// 暂停之前录了多久、这一段从什么时候开始（计时不算暂停的时间）
  private var recordedBefore: Duration = .zero
  private var resumedAt: ContinuousClock.Instant?
  private var shownSeconds = -1
  private var silenceShown = false
  private var ticks = 0
  private var hud: RecordingHUD?
  private var stopItem: NSStatusItem?
  private var timer: Timer?
  private var activity: NSObjectProtocol?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  /// 开录时的默认输入设备（AVCaptureDevice.uniqueID）：它断开了就停
  private var microphoneID: String?

  /// directory：快速保存目录（进行中的文件在和它同一个卷的 workFile）；defaults：来源从这里读、「进行中」记在这里；
  /// island：交给 engine（系统声音 / 两者）
  init(
    directory: URL, defaults: UserDefaults = .standard, island: Island? = nil,
    onFinish: @escaping (ScreenRecorder.Result) -> Void
  ) {
    self.directory = directory
    temp = ScreenRecorder.workFile(for: directory, medium: .audio)
    source = Source(defaults)
    self.island = island
    self.defaults = defaults
    self.onFinish = onFinish
    super.init()
  }

  /// 开录（异步：问过授权、开起来之后才出 HUD 和停止项），结束时回调 onFinish
  func start() {
    if source != .microphone { return startEngine() }
    defaults.set(temp.path, forKey: ScreenRecorder.Medium.audio.inProgressKey)
    Task { await begin() }
  }

  /// 停止并保存（再按快捷键、HUD 的 ■、停止项、中断）；放弃是 .discarded。还没开始录（等授权框）时记下、开始前当取消。
  /// 收尾在下一轮：可能是 HUD 自己的按钮在调（收尾会拿掉 HUD）。系统声音 / 两者交给 engine：还没开始（HUD 没出来：等授权框、
  /// 流还在开）同样当取消——不然 engine 等开起来再停，存下几乎 0 秒的文件、卡片从 (0, 0) 飞出来；它停流那一刻（下一轮）经
  /// onHalted 收 HUD 和停止项
  func stop(_ reason: ScreenRecorder.Reason = .user) {
    if let engine {
      guard stopping == nil else { return }
      stopping = reason
      return engine.stop(resumedAt == nil ? .cancelled : reason)
    }
    guard recorder != nil else {
      stoppedEarly = true
      return
    }
    guard stopping == nil else { return }
    stopping = reason
    Task { finish(reason) }
  }

  /// 暂停 / 继续（HUD 的 ⏸ / ▶）：续写同一个文件，计时停在暂停那一刻；旁白播报。系统声音 / 两者不能暂停（HUD 的 ⏸ 置灰）
  func togglePause() {
    guard let recorder, stopping == nil else { return }
    if isPaused {
      guard recorder.record() else { return stop(.failed("没能继续录音")) }
      resumedAt = .now
    } else {
      recorder.pause()
      recordedBefore = recorded
      resumedAt = nil
    }
    isPaused.toggle()
    hud?.setPaused(isPaused)
    Island.announce(isPaused ? "已暂停" : "已继续")
  }

  /// 录了多久（不算暂停的时间）
  private var recorded: Duration {
    recordedBefore + (resumedAt.map { .now - $0 } ?? .zero)
  }

  // MARK: 开录

  /// 授权 → 开录 → HUD、停止项、计时。没问过授权这时才问（没有遮罩，系统框不会被压住）；拒绝 / 受限不录（之前就拒绝过的
  /// 收尾时 AppDelegate 打开系统设置，刚在系统框里点了不允许的不打开，同录屏第 4 批）
  private func begin() async {
    switch ScreenRecorder.microphoneAccess(wanted: true, status: microphoneStatus()) {
    case .granted, .unused: break
    case .ask:
      let allowed = await requestMicrophone()
      if stoppedEarly { return finish(.cancelled) }
      if !allowed { return finish(.noMicrophoneAccess) }
    case .denied: return finish(.noMicrophoneAccess, microphoneDenied: true)
    }
    if stoppedEarly { return finish(.cancelled) }
    let recorder: AVAudioRecorder
    do {
      recorder = try AVAudioRecorder(url: temp, settings: Self.settings)
    } catch {
      Log.record.error("录音开不起来：\(error)")
      return finish(.failed("没能开始录音"))
    }
    recorder.isMeteringEnabled = true
    guard recorder.prepareToRecord(), recorder.record() else {
      Log.record.error("录音 record() 失败")
      return finish(.failed("没能开始录音"))
    }
    self.recorder = recorder
    resumedAt = .now
    showChrome()
    // 开录这一刻的默认输入（麦克风跟随系统输入）：它断开了才停。第一次查约 70 ms（第 4 批实测），放在 HUD 出来之后
    microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID
  }

  /// 系统声音 / 两者（拍板 A2-a「复用录屏管线」）：鼠标所在屏左上角那一小块只为声音，开起来了（onStarted）才出 HUD 和停止项
  private func startEngine() {
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
      let engine = ScreenRecorder(
        region: ScreenRecorder.audioOnlyRegion(screen.frame), directory: directory,
        defaults: defaults, island: island,
        audioOnly: .init(systemAudio: true, microphone: source == .both),
        onFinish: { [weak self] in self?.engineFinished($0) })
    else { return finish(.failed("找不到要录的屏幕")) }
    engine.microphoneStatus = microphoneStatus
    engine.requestMicrophone = requestMicrophone
    engine.onStarted = { [weak self] in self?.engineStarted() }
    engine.onHalted = { [weak self] in self?.tearDown() }
    engine.onLevel = { [weak self] in self?.metered($0, microphone: $1) }
    engine.onMicrophoneLost = { [weak self] in self?.microphoneLost() }
    self.engine = engine
    engine.start()
  }

  /// engine 开始写了：计时从这时起，出 HUD（⏸ 置灰）和停止项。开起来之前就叫停了（等流开起来时又按了一次）不出
  private func engineStarted() {
    guard stopping == nil, let engine else { return }
    listens = engine.capturesMicrophone
    resumedAt = .now
    showChrome()
  }

  /// engine 的一块声音样本的电平：记下这一格里各路最响的，20 Hz 的 tick 取走
  private func metered(_ power: Float, microphone: Bool) {
    if microphone {
      pending.microphone = max(pending.microphone, power)
    } else {
      pending.system = max(pending.system, power)
    }
  }

  /// 两者录制中开录时的麦克风断开（engine 不停、已播报，结果岛补一句）：HUD 计时后面换成「麦克风断开了」，之后不再看
  /// 「没听到声音」（后面本来就没有麦克风声音）
  private func microphoneLost() {
    listens = false
    silenceShown = false
    hud?.microphoneLost()
  }

  /// engine 收尾了（文件写完、导出成 m4a、挪好）：HUD 在停的那一刻已收，补上飞入起点和波形 poster 交给 AppDelegate
  private func engineFinished(_ finished: ScreenRecorder.Result) {
    tearDown()
    engine = nil
    var result = finished
    result.region = region
    if result.moved { result.poster = Self.waveform(levels.envelope) }
    onFinish(result)
  }

  /// HUD（鼠标所在屏可见区底部居中，从底边长出来）、菜单栏停止项、20 Hz 的电平 / 计时、防睡眠、中断监听
  /// （只录麦克风时；系统声音 / 两者的中断在 engine 里，同录屏）
  private func showChrome() {
    let mouse = NSEvent.mouseLocation
    let hud = RecordingHUD(
      state: .recording(0), stopKey: HotKeyAction.audioRecord.hotKey?.display, medium: .audio,
      pausable: source == .microphone)
    hud.onClick = { [weak self] in self?.clicked($0) }
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
      hud.present(region: screen.frame, on: screen, isFullScreen: true)
    }
    self.hud = hud
    stopItem = ScreenRecorder.makeStopItem(
      label: "停止录音", target: self, action: #selector(stopClicked))
    // 菜单开着（.eventTracking）时电平和计时也要走
    let timer = Timer(timeInterval: 1 / Double(Self.meterRate), repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    updateClock()
    // 麦克风：只防系统闲置睡眠（只录声音，显示器照常熄、照录）。系统声音 / 两者同录屏连显示器闲置睡眠一起防：engine 监听
    // 显示器睡眠就停，不防的话没人碰键鼠的长录音（听播客、网课）会在「关闭显示器」的时间被截断
    var options: ProcessInfo.ActivityOptions = [.idleSystemSleepDisabled, .userInitiated]
    if source != .microphone { options.insert(.idleDisplaySleepDisabled) }
    activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "录音")
    if source == .microphone { observeInterruptions() }
    Island.announce("开始录音")
  }

  private func clicked(_ item: RecordingHUD.Item) {
    switch item {
    case .pause: togglePause()
    case .discard: stop(.discarded)
    case .stop: stop()
    case .startNow, .cancel: break
    }
  }

  @objc private func stopClicked() { stop() }

  // MARK: 录制中

  /// 20 Hz：每 5 s 查剩余空间；没暂停时看还在不在录、读电平（HUD 电平、「没听到声音」）、走计时
  private func tick() {
    ticks += 1
    guard stopping == nil else { return }
    if ticks % (5 * Self.meterRate) == 0, ScreenRecorder.isLowOnDisk(temp) { return stop(.lowDisk) }
    guard !isPaused else { return }
    if let recorder {
      // 没人叫停它却不录了（编码出错这类，AVAudioRecorder 自己停）：保住已录的部分。
      // ponytail: 不挂委托、靠这里看 isRecording：看不到具体出错原因（只能说「录音意外停止」）、最多晚一个 tick（50 ms）
      // 才发现、暂停中不查。真遇到了按 mac-native §3 挂 nonisolated 的 AVAudioRecorderDelegate
      // （audioRecorderEncodeErrorDidOccur / audioRecorderDidFinishRecording），把错误文字投回主线程再收尾
      guard recorder.isRecording else { return stop(.failed("录音意外停止")) }
      recorder.updateMeters()
      levels.add(recorder.averagePower(forChannel: 0))
    } else {
      // engine：这一格里两路最响的画电平，「没听到声音」只看麦克风那一路
      levels.add(max(pending.system, pending.microphone), listening: pending.microphone)
      pending = (-120, -120)
    }
    hud?.updateMeter(levels.recent)
    let silent = listens && Self.showsSilence(heard: levels.heard, recorded: recorded)
    if silent != silenceShown {
      silenceShown = silent
      hud?.setSilent(silent)
      if silent { Island.announce("没听到声音") }
    }
    updateClock()
  }

  /// 菜单栏停止项和 HUD 同一个时钟（整秒变了才换）
  private func updateClock() {
    let seconds = Int(recorded.components.seconds)
    guard seconds != shownSeconds else { return }
    shownSeconds = seconds
    hud?.update(.recording(seconds))
    ScreenRecorder.showClock(seconds, on: stopItem)
  }

  /// 只录麦克风（C6-a）：锁屏、显示器睡眠照录；系统睡眠停止并保存；开录时的输入设备断开（拔了 USB 麦克风、蓝牙耳机走远了）
  /// 停止并保存
  private func observeInterruptions() {
    let sleep = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop(.sleep) }
    }
    let unplugged = NotificationCenter.default.addObserver(
      forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
    ) { [weak self] note in
      let id = (note.object as? AVCaptureDevice)?.uniqueID
      MainActor.assumeIsolated {
        guard let self, let id, id == self.microphoneID else { return }
        self.stop(.microphoneLost)
      }
    }
    observers = [
      (NSWorkspace.shared.notificationCenter, sleep), (NotificationCenter.default, unplugged),
    ]
  }

  // MARK: 收尾

  /// 停录（AVAudioRecorder.stop 当场关文件）、HUD 和停止项收掉、挪文件、画波形 poster；飞入的起点是 HUD 的位置
  private func finish(_ reason: ScreenRecorder.Reason, microphoneDenied: Bool = false) {
    let duration = recorded
    let started = recorder != nil
    recorder?.stop()
    recorder = nil
    tearDown()
    defaults.removeObject(forKey: ScreenRecorder.Medium.audio.inProgressKey)
    let (file, moved) = ScreenRecorder.settle(
      temp, into: directory, medium: .audio,
      keeps: started && reason != .discarded && reason != .cancelled)
    var result = ScreenRecorder.Result(
      file: file, moved: moved, duration: duration, reason: reason, region: region)
    result.microphoneDenied = microphoneDenied
    if moved { result.poster = Self.waveform(levels.envelope) }
    onFinish(result)
  }

  /// HUD、停止项、计时、防睡眠、中断监听收掉（收 HUD 前记下飞入的起点）；可以重复调
  private func tearDown() {
    if let hud { region = Self.flightStart(hud: hud.screenFrame) }
    timer?.invalidate()
    timer = nil
    hud?.close()
    hud = nil
    if let stopItem { NSStatusBar.system.removeStatusItem(stopItem) }
    stopItem = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
  }

  // MARK: 纯函数（配单测）

  /// 开头 silenceWindow 里一次都没到门槛：HUD 出「没听到声音」；听到过就收起（之后再安静也不再出）
  nonisolated static func showsSilence(heard: Bool, recorded: Duration) -> Bool {
    !heard && recorded >= silenceWindow
  }

  /// 一块声音样本的电平（dBFS，按均方根，同 AVAudioRecorder.averagePower 的口径；录音第 6 批：录屏管线给的系统声音 /
  /// 麦克风样本没有现成的 metering，在 RecordingEvents 的样本回调里算）。没有样本、全是 0（数字静音）算 −120
  nonisolated static func power(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return -120 }
    let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
    return max(-120, 10 * log10(meanSquare))
  }

  /// 电平竖条的高度（HUD 的电平、波形 poster 共用）：−50 dB 及以下 2 pt，0 dB 到 tallest，中间按 dB 线性
  nonisolated static func meterHeight(_ decibels: Float, tallest: CGFloat = 20) -> CGFloat {
    let fraction = CGFloat((min(max(decibels, -50), 0) + 50) / 50)
    return 2 + (tallest - 2) * fraction
  }

  /// 包络按条数重新分组（每条取那一段的最大）；比条数少时按比例重复
  nonisolated static func resample(_ values: [Float], to count: Int) -> [Float] {
    guard !values.isEmpty, count > 0 else { return [] }
    return (0..<count).map { index in
      let from = index * values.count / count
      let to = max(from + 1, (index + 1) * values.count / count)
      return values[from..<to].max() ?? values[from]
    }
  }

  /// 飞入的起点（录音没有选区）：HUD 的中心、HUD 那么高、poster 的宽高比——从小卡长到常驻缩略图那么大（S1 录音版）
  nonisolated static func flightStart(hud: CGRect) -> CGRect {
    let width = (hud.height * posterSize.width / posterSize.height).rounded()
    return CGRect(
      x: (hud.midX - width / 2).rounded(), y: hud.minY, width: width, height: hud.height)
  }

  /// 波形 poster（A5-a）：HUD 底色（不透明的 solidFill）上一排 HUD 主文字色的竖条（宽 3、间隔 2、左右各留 14，竖直居中、最高 poster 高的 56%），
  /// 按 2x 出图，和视频卡同尺寸比例；飞入、录音卡、减弱动态效果时岛的小图都用它
  static func waveform(_ envelope: [Float]) -> CGImage? {
    let size = posterSize
    let scale: CGFloat = 2
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(Style.HUD.solidFill.cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    let (bar, gap, margin) = (CGFloat(3), CGFloat(2), CGFloat(14))
    let count = Int((size.width - 2 * margin + gap) / (bar + gap))
    let left = (size.width - CGFloat(count) * (bar + gap) + gap) / 2
    let levels = resample(envelope.isEmpty ? [-120] : envelope, to: count)
    for (index, level) in levels.enumerated() {
      let height = meterHeight(level, tallest: (size.height * 0.56).rounded())
      let rect = CGRect(
        x: left + CGFloat(index) * (bar + gap), y: (size.height - height) / 2, width: bar,
        height: height)
      context.addPath(
        CGPath(
          roundedRect: rect, cornerWidth: bar / 2, cornerHeight: min(bar, height) / 2,
          transform: nil))
    }
    context.setFillColor(Style.HUD.text.cgColor)
    context.fillPath()
    return context.makeImage()
  }
}
