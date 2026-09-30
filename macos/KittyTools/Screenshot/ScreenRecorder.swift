// 录屏会话（录屏第 1 批，PLAN §10「录屏与录音」；框选是 RegionSelector.record / SelectionView 的 .record 模式）：
// 系统录制管线 SCRecordingOutput 直接写 mp4（H.264、30 / 60 fps、光标可关、sRGB，设置 › 截图「录屏」），先写到和快速保存目录
// 同一个卷、系统不清理的地方（workFile：Application Support 或保存目录里的隐藏文件），写完挪进快速保存目录（同卷只是改名）。
// 选区按相交面积最大的屏录；整屏不设 sourceRect。
// 开录前先倒数（录屏第 2 批，拍板 R9-a，设置里可选 0 / 3 / 5 秒）：数完才开流、倒数不进文件；倒数期间边框走蚂蚁线、
// 录制 HUD（RecordingHUD）数秒，Esc 走临时热键（HUD 不当 key），✕ / Esc / 再按录屏快捷键取消，点数字马上开始。
// 本 App 的窗口（R4-a）：过滤器排除整个本 App，只把几类面板（剪贴板、启动器、翻译、⌘Y、钉图、设置窗）列进例外
// （ScreenCapture.recordedOwnWindows）；录制中每秒比一次它们的窗口号，变了（第一次呼出的面板、新钉图）就换过滤器。
// 录制中：选区外一圈静止的强调色边框（整屏不画）+ 录制 HUD（红点、计时、放弃、停止）+ 菜单栏另起一个「■ 0:12」停止项
// （左键即停）；期间不让系统闲置睡眠。放弃（HUD 的 ✕ 点两下）= 停流、删文件、不挪。
// 锁屏、睡眠、显示器睡眠、被录的屏变了、磁盘剩余不到 1 GB、系统停止流：和用户停止走同一条收尾（停流 → 等文件写完 →
// 挪文件 → 回调），保存已录的部分，原因写进结果岛。开录时把临时文件路径记进偏好，闪退后下次启动由 recover 接手
// （第 0 批实测：文件由系统进程 replayd 写，本 App 被 kill -9 后它自己收尾、文件能播）。
// 委托和样本输出在后台线程回调（第 0 批实测）：RecordingEvents 是 nonisolated、无状态的类，只把 Sendable 的事件投进
// AsyncStream，会话在主线程逐个消费（mac-native §3）。停流不等 stopCapture 回来，收尾只看事件和超时。
// 挪进快速保存目录后取最后一帧当 poster（录屏第 3 批，拍板 R11-a）：AppDelegate 拿它从选区飞到右下角、交给常驻缩略图的视频卡。

import AVFoundation
import AppKit
import OSLog
import ScreenCaptureKit

/// 录制委托 + 空样本输出：只把发生了什么投进会话的事件流。录什么就挂什么空输出（第 0 批实测：不挂时系统日志每帧一条
/// 「stream output NOT found. Dropping frame」，挂了 0 条）；这一批只录画面，挂一路 .screen（第 4 批开声音时按配置
/// 再挂 .audio / .microphone）
nonisolated final class RecordingEvents: NSObject, SCRecordingOutputDelegate, SCStreamDelegate,
  SCStreamOutput, Sendable
{
  enum Event: Sendable {
    /// 开始写文件：计时零点
    case started
    /// 文件写完
    case finished
    /// 写入失败（文件里可能已经有一部分）
    case failed(String)
    /// 流停了（控制中心「停止共享」、系统中止……）
    case stopped(domain: String, code: Int, text: String)
    /// 会话自己投的：要停（点停止、中断、放弃、倒数中取消）、开始 / 写完超时
    case stop(ScreenRecorder.Reason)
    case startTimedOut, finishTimedOut
    /// 倒数：过了一秒、点了数字马上开始
    case tick, startNow
  }

  let feed: AsyncStream<Event>.Continuation

  init(feed: AsyncStream<Event>.Continuation) { self.feed = feed }

  func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
    feed.yield(.started)
  }

  func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    feed.yield(.finished)
  }

  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
    feed.yield(.failed(error.localizedDescription))
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let error = error as NSError
    feed.yield(.stopped(domain: error.domain, code: error.code, text: error.localizedDescription))
  }

  /// 空输出：样本直接丢（录制管线自己写文件）
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {}
}

final class ScreenRecorder: NSObject {
  /// 选区短边至少这么多点（13 条默认细节：太小的录出来看不清）
  static let minimumSide: CGFloat = 64
  /// 宽或高超过它就等比缩（第 0 批实测：H.264 硬件编码卡边长，4096 × 2880、2560 × 4096 是硬件，4224 宽就退软件编码）
  nonisolated static let maxSide = 4096
  /// 临时文件所在卷剩余不到这么多就停
  static let minimumFreeBytes: Int64 = 1_000_000_000

  /// 为什么停（第一个为准）
  nonisolated enum Reason: Equatable, Sendable {
    /// 点停止项、再按快捷键、菜单栏 / 启动器、退出 App、控制中心「停止共享」
    case user
    /// 倒数中取消（✕、Esc、再按录屏快捷键）：没开流、没有文件，不出岛
    case cancelled
    /// 录制中点了两下放弃：停流、删文件，不挪、不留闪退记录
    case discarded
    case locked, sleep, displaySleep, screenChanged, lowDisk
    /// 流被系统停了（「停止共享」以外）
    case system(code: Int, text: String)
    /// 没开起来（授权以外）、写入失败、没按时写完
    case failed(String)
    /// startCapture 报 -3801 / -3802：屏幕录制授权问题
    case denied

    /// 岛的详情里的原因（简短）；正常停止 nil
    var note: String? {
      switch self {
      case .user, .cancelled, .discarded: nil
      case .locked: "锁屏时已自动停止"
      case .sleep: "睡眠前已自动停止"
      case .displaySleep: "显示器睡眠时已自动停止"
      case .screenChanged: "屏幕有变化，已自动停止"
      case .lowDisk: "磁盘剩余不到 1 GB，已自动停止"
      // 社区观测多半和磁盘空间有关（PLAN §10 C6）
      case .system(code: SCStreamError.Code.systemStoppedStream.rawValue, _):
        "系统停止了录制，看看磁盘空间"
      case .system(let code, _): "系统停止了录制（错误 \(code)）"
      case .failed(let text): text
      case .denied: "没有屏幕录制授权"
      }
    }
  }

  struct Result {
    /// 录下的文件：挪进快速保存目录的那份；挪不过去时是留在 workFile 那里的那份（moved 为 false）；nil = 没有录下东西
    var file: URL?
    var moved: Bool
    var duration: Duration
    var reason: Reason
    /// 录的区域（点，全局坐标；整屏就是那块屏）：飞入的起点
    var region: CGRect = .zero
    /// 最后一帧（挪进快速保存目录了才取；文件太短、取不到是 nil）
    var poster: CGImage?
  }

  /// poster 长边最多这么多像素：够飞行卡片起飞时铺满选区、落地后缩成卡片，不解整张 5K
  nonisolated static let posterMaxSide: CGFloat = 1600

  /// 选区（点，全局坐标，对齐到像素，夹在那块屏里）
  private let region: CGRect
  /// ScreenCaptureKit 的 sourceRect（屏内、点、原点左上）；整屏时不设
  private let source: CGRect
  private let isFullScreen: Bool
  /// 被录的屏：编号、开录时的 frame 和每点像素（变了就停）
  private let displayID: CGDirectDisplayID
  private let screenFrame: CGRect
  private let scale: CGFloat
  /// 设置 › 截图「录屏」（开录时读一次）：帧率 30 / 60、开录前倒数几秒、画不画光标
  private let frameRate: Int
  private let countdown: Int
  private let showsCursor: Bool
  /// 倒数期间临时注册 Esc 用（单测 / 实录自检里是 nil：没有 Esc，只能点 ✕）
  private weak var hotKeys: HotKeyCenter?
  /// 快速保存目录；进行中的文件在和它同一个卷的 workFile
  private let directory: URL
  private let temp: URL
  /// 「进行中」记在哪（单测换成临时偏好域）
  private let defaults: UserDefaults
  private let onFinish: (Result) -> Void
  private let events: AsyncStream<RecordingEvents.Event>
  private let delegate: RecordingEvents
  private var stream: SCStream?
  private var output: SCRecordingOutput?
  /// 计时零点（recordingOutputDidStartRecording）和停止的那一刻
  private var startedAt: ContinuousClock.Instant?
  private var endedAt: ContinuousClock.Instant?
  private var finishDeadline: Task<Void, Never>?
  /// 用户放弃 / 取消了（第一个为准）：之后不管怎么收尾（写完超时、没开起来、流先停了），结果都按它——删文件、不出失败岛
  private var abandoned: Reason?
  private var border: NSPanel?
  private var hud: RecordingHUD?
  private var stopItem: NSStatusItem?
  private var timer: Timer?
  private var ticks = 0
  private var activity: NSObjectProtocol?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  /// 当前过滤器里列进例外的窗口号（每秒和此刻的比，变了换过滤器）
  private var exceptedWindows: Set<CGWindowID> = []
  private var isRefreshingFilter = false

  /// region：选区（点，AppKit 全局坐标）；directory：快速保存目录；defaults：录屏设置从这里读、「进行中」记在这里；
  /// hotKeys：倒数时临时注册 Esc。选区不在任何屏上时 nil
  init?(
    region: CGRect, directory: URL, defaults: UserDefaults = .standard,
    hotKeys: HotKeyCenter? = nil, onFinish: @escaping (Result) -> Void
  ) {
    let screens = NSScreen.screens
    guard let (index, _) = RegionSelector.placement(of: region, in: screens.map(\.frame)),
      let displayID = screens[index].displayID
    else { return nil }
    let screen = screens[index]
    let rect = RegionSelector.captureRect(
      region, in: screen.frame, scale: screen.backingScaleFactor)
    self.region = rect.region
    source = rect.source
    isFullScreen = rect.region == screen.frame
    self.displayID = displayID
    screenFrame = screen.frame
    scale = screen.backingScaleFactor
    frameRate = defaults.integer(forKey: Prefs.screenRecordFrameRate) == 60 ? 60 : 30
    countdown = Self.countdownSeconds(defaults.integer(forKey: Prefs.screenRecordCountdown))
    showsCursor = defaults.object(forKey: Prefs.screenRecordShowsCursor) as? Bool ?? true
    self.hotKeys = hotKeys
    self.directory = directory
    temp = Self.workFile(for: directory)
    self.defaults = defaults
    self.onFinish = onFinish
    let (events, feed) = AsyncStream<RecordingEvents.Event>.makeStream()
    self.events = events
    delegate = RecordingEvents(feed: feed)
    super.init()
  }

  /// 开录（异步：开起来之后才出边框和停止项），结束时回调 onFinish
  func start() {
    defaults.set(temp.path, forKey: Prefs.screenRecordingInProgress)
    Task {
      let reason = await record()
      tearDown()
      var result = finalize(Self.outcome(reason, abandoned: abandoned))
      if result.moved, let file = result.file {
        let size = Self.outputSize(points: region.size, scale: scale)
        result.poster = await Self.poster(
          of: file, pixels: CGSize(width: size.width, height: size.height))
      }
      onFinish(result)
    }
  }

  /// 停止并保存（点停止项、再按快捷键、中断）。倒数中是取消；开流了还没开始时等开始了再停；已经在停了就不管
  func stop(_ reason: Reason = .user) {
    delegate.feed.yield(.stop(reason))
  }

  // MARK: 录制

  /// 倒数 → 开流 → 等开始 → 等停止 → 停流、等文件写完；返回停的原因（第一个为准）
  /// ponytail: 取窗口表和 startCapture 的 await 不罩超时（5 s 开始超时从它们返回后算）：SCK 这两个调用都会返回或抛错、
  /// 没见过卡住；要罩住得把开流挪进子任务、处理超时后才开起来的流，真遇到了再做
  private func record() async -> Reason {
    // 倒数前就听：倒数中锁屏、睡眠、屏幕变了直接取消（不在锁屏界面上开流、不带着旧的屏幕参数开录）
    observeInterruptions()
    if countdown > 0 {
      guard await countDown() else { return .cancelled }
      // 数完：蚂蚁线停成实线，HUD 换成录制态（红点 pop 后呼吸），开流
      border?.contentView = ScrollBorderView(animates: false)
      hud?.update(.recording(0))
    }
    let stream: SCStream
    do {
      stream = try await makeStream()
      try await stream.startCapture()
    } catch {
      return Self.reason(startFailed: error)
    }
    self.stream = stream
    let feed = delegate.feed
    let startDeadline = Task {
      try? await Task.sleep(for: .seconds(5))
      feed.yield(.startTimedOut)
    }
    defer {
      startDeadline.cancel()
      finishDeadline?.cancel()
    }
    var reason: Reason?
    /// 还没开始就要停（启动途中点了停止）：开始了再停
    var pending: Reason?
    /// 没人要停文件就写完了 = 流自己停了；流停止的原因（另一个后台回调）可能还在路上
    var finished = false
    for await event in events {
      switch event {
      case .started:
        guard startedAt == nil else { continue }
        startDeadline.cancel()
        startedAt = .now
        showChrome()
        if let pending {
          reason = pending
          halt(stream)
        }
      case .stop(let why):
        // 放弃 / 取消（倒数刚结束才到的）：结果按它（outcome），不留闪退记录（文件写完就删，这期间闪退也不该被 recover 捡回来）
        if why == .discarded || why == .cancelled {
          abandoned = abandoned ?? why
          defaults.removeObject(forKey: Prefs.screenRecordingInProgress)
        }
        if startedAt == nil {
          pending = pending ?? why
        } else if reason == nil, !finished {
          reason = why
          halt(stream)
        }
      case .startTimedOut:
        guard startedAt == nil else { continue }
        stopCapture(stream)
        return .failed("没能开始录制")
      case .stopped(let domain, let code, let text):
        let why = Self.reason(streamStopped: domain, code: code, text: text)
        Log.record.notice("录屏的流停了：\(domain) \(code) \(text)")
        guard startedAt != nil, !finished else { return why }
        if reason == nil {
          reason = why
          halt(stream, running: false)
        }
      case .failed(let text):
        Log.record.error("录屏写入失败：\(text)")
        if reason == nil, !finished { halt(stream) }
        return Self.reason(writeFailed: text, stopping: reason)
      case .finished:
        if let reason { return reason }
        // 等一小会儿流停止的原因（控制中心「停止共享」算正常停），没等到才算意外结束
        finished = true
        halt(stream, running: false, wait: .milliseconds(500))
      case .finishTimedOut:
        return .failed(finished ? "录制意外结束" : "文件没有按时写完")
      case .tick, .startNow:
        continue
      }
    }
    return reason ?? .user
  }

  /// 倒数（拍板 R9-a）：数完才开流（倒数不进文件）。选区边框走蚂蚁线（整屏没有）、HUD 数秒；点数字马上开始，✕ / Esc /
  /// 再按录屏快捷键取消。Esc 是这几秒里临时注册的全局热键（HUD 不当 key，收不到按键），数完 / 取消 / 开录立刻注销；
  /// 注册不上只能用快捷键和 ✕（HotKeyCenter 记日志，播报和 ✕ 的提示不提 Esc）。本 App 自己的面板拿着键盘时这一下 Esc
  /// 交给它（HotKeyCenter.fire）。菜单栏停止项这时还没有。返回 false = 取消了
  private func countDown() async -> Bool {
    let escapes = hotKeys?.registerEscape { [weak self] in self?.stop(.cancelled) } ?? false
    defer { hotKeys?.unregisterEscape() }
    showFrame(counting: true, escapes: escapes)
    Island.announce(Self.countdownAnnouncement(countdown, escapes: escapes))
    // 菜单开着（.eventTracking）时也要数
    let feed = delegate.feed
    let ticker = Timer(timeInterval: 1, repeats: true) { _ in feed.yield(.tick) }
    RunLoop.main.add(ticker, forMode: .common)
    defer { ticker.invalidate() }
    var left = countdown
    for await event in events {
      switch event {
      case .tick:
        left -= 1
        guard left > 0 else { return true }
        hud?.update(.countdown(left))
      case .startNow:
        return true
      case .stop:
        return false
      default:
        continue
      }
    }
    return false
  }

  /// 过滤器、配置、录制输出、空样本输出
  private func makeStream() async throws -> SCStream {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw NoDisplay()
    }
    let (filter, excepted) = makeFilter(display: display, content: content)
    exceptedWindows = excepted
    let configuration = SCStreamConfiguration()
    let size = Self.outputSize(
      points: isFullScreen ? filter.contentRect.size : source.size,
      scale: CGFloat(filter.pointPixelScale))
    configuration.width = size.width
    configuration.height = size.height
    if !isFullScreen { configuration.sourceRect = source }
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    configuration.showsCursor = showsCursor
    // 第 0 批实测：不设时 P3 屏色相明显偏；设 sRGB 色相对，中间调仍偏亮约 4%（itur_709 更差）
    configuration.colorSpaceName = CGColorSpace.sRGB
    // 这一批不录声音；第 4 批开声音前先写上作保险（排除本 App 时它自己的声音本来就录不进去）
    configuration.excludesCurrentProcessAudio = true
    let recording = SCRecordingOutputConfiguration()
    recording.outputURL = temp
    recording.videoCodecType = .h264
    recording.outputFileType = .mp4
    let output = SCRecordingOutput(configuration: recording, delegate: delegate)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
    try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: nil)
    try stream.addRecordingOutput(output)
    self.output = output
    return stream
  }

  private struct NoDisplay: LocalizedError {
    var errorDescription: String? { "找不到选区所在的屏幕" }
  }

  /// 排除整个本 App，白名单里的面板列进例外（不看可见不可见）。返回过滤器和真正列进例外的窗口号（这次窗口表里找到的）
  private func makeFilter(display: SCDisplay, content: SCShareableContent) -> (
    SCContentFilter, Set<CGWindowID>
  ) {
    let ids = ScreenCapture.recordedOwnWindows(ScreenCapture.ownWindows())
    let excepted = content.windows.filter { ids.contains($0.windowID) }
    let found = Set(excepted.map(\.windowID))
    if let me = content.applications.first(where: { $0.processID == getpid() }) {
      return (
        SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: excepted),
        found
      )
    }
    // 找不到本 App 的 SCRunningApplication（按理不会：菜单栏图标一直在）：退回按窗口排除本 App 此刻不在白名单里的窗口。
    // ponytail: 这时之后才建的装饰窗口（第一次弹的岛、飞行卡片）会进画面；真遇到了再连它们一起每秒比
    let excluded = content.windows.filter {
      $0.owningApplication?.processID == getpid() && !ids.contains($0.windowID)
    }
    return (SCContentFilter(display: display, excludingWindows: excluded), found)
  }

  /// 白名单里的窗口号变了（第一次呼出的面板：OverlayPanel 是 defer 建的，没显示过没有窗口号；新钉图；第一次打开的设置窗）：
  /// 重取窗口表、换过滤器（第 0 批实测换过滤器不停录，新窗口马上录进去）。换成功了才记下真正列进去的窗口号：失败、或新窗口
  /// 这次还没出现在窗口表里时，下一秒接着试。失败只记日志。
  /// ponytail: 跟着每秒的计时比，新露出来的面板最多晚 1 s 进画面；要更快就让面板 present 时通知这里。白名单里的窗口
  /// 一直不在窗口表里时每秒重取一次窗口表（没见过）
  private func refreshFilterIfNeeded() {
    let ids = ScreenCapture.recordedOwnWindows(ScreenCapture.ownWindows())
    guard ids != exceptedWindows, !isRefreshingFilter, let stream else { return }
    isRefreshingFilter = true
    Task {
      defer { isRefreshingFilter = false }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        guard self.stream === stream,
          let display = content.displays.first(where: { $0.displayID == displayID })
        else { return }
        let (filter, excepted) = makeFilter(display: display, content: content)
        try await stream.updateContentFilter(filter)
        exceptedWindows = excepted
      } catch {
        Log.record.error("录屏换过滤器失败：\(error)")
      }
    }
  }

  /// 停：边框、HUD 和停止项立刻收掉、停流（流自己停了就不用），最多等 wait 文件写完（超时按失败，文件照样保留）
  private func halt(_ stream: SCStream, running: Bool = true, wait: Duration = .seconds(10)) {
    endedAt = endedAt ?? .now
    hideChrome()
    self.stream = nil
    let feed = delegate.feed
    finishDeadline?.cancel()
    finishDeadline = Task {
      try? await Task.sleep(for: wait)
      feed.yield(.finishTimedOut)
    }
    if running { stopCapture(stream) }
  }

  /// 停流不等它回来：被录的屏正被拔掉时它可能迟迟不回，收尾交给事件和上面的超时，别让会话卡在这里（再按快捷键停不了、
  /// 更新一直置灰）
  private func stopCapture(_ stream: SCStream) {
    Task {
      do { try await stream.stopCapture() } catch { Log.record.error("录屏停流失败：\(error)") }
    }
  }

  // MARK: 录制中

  /// 边框（整屏不画）和录制 HUD：倒数时（counting）边框走蚂蚁线、HUD 数秒；不倒数时开始录了才出，边框静止、HUD 直接是录制态。
  /// escapes：倒数的 Esc 注册上了（✕ 的提示写不写 Esc）
  private func showFrame(counting: Bool, escapes: Bool = false) {
    if !isFullScreen {
      let view = ScrollBorderView(animates: counting)
      if counting { view.update(lost: false, marching: true) }
      let border = ScrollCapture.makeBorder(around: region, view: view)
      // 录的是整块屏的一部分：切到别的桌面、全屏 App 上也要看得到在录哪
      border.collectionBehavior.insert(.canJoinAllSpaces)
      border.orderFrontRegardless()
      self.border = border
    }
    let hud = RecordingHUD(
      state: counting ? .countdown(countdown) : .recording(0),
      stopKey: HotKeyAction.screenRecord.hotKey?.display, escapes: escapes)
    hud.onClick = { [weak self] in self?.clicked($0) }
    if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
      hud.present(region: region, on: screen, isFullScreen: isFullScreen)
    }
    self.hud = hud
  }

  private func clicked(_ item: RecordingHUD.Item) {
    switch item {
    case .startNow: delegate.feed.yield(.startNow)
    case .cancel: stop(.cancelled)
    case .discard: stop(.discarded)
    case .stop: stop()
    }
  }

  /// 开始了：边框和 HUD（倒数过就已经有了）、菜单栏停止项、每秒的计时、防睡眠（中断监听在 record 一开头就装了）
  private func showChrome() {
    if hud == nil { showFrame(counting: false) }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
      image?.isTemplate = true
      button.image = image
      button.imagePosition = .imageLeading
      button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      button.target = self
      button.action = #selector(stopClicked)
      button.setAccessibilityLabel("停止录屏")
    }
    stopItem = item
    // 菜单开着（.eventTracking）时计时也要走
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    updateClock()
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
      reason: "录屏")
    Island.announce("开始录屏")
  }

  /// 边框、HUD、停止项、计时立刻收掉（停的那一刻；文件还在写）
  private func hideChrome() {
    border?.orderOut(nil)
    border = nil
    hud?.close()
    hud = nil
    if let stopItem { NSStatusBar.system.removeStatusItem(stopItem) }
    stopItem = nil
    timer?.invalidate()
    timer = nil
  }

  @objc private func stopClicked() { stop() }

  private func tick() {
    ticks += 1
    updateClock()
    refreshFilterIfNeeded()
    // 每 5 s 看一次临时文件所在卷还剩多少
    if ticks % 5 == 0,
      let free = try? temp.deletingLastPathComponent().resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ]).volumeAvailableCapacityForImportantUsage, free < Self.minimumFreeBytes
    {
      stop(.lowDisk)
    }
  }

  /// 菜单栏停止项和 HUD 同一个时钟
  private func updateClock() {
    guard let button = stopItem?.button, let startedAt else { return }
    let seconds = Int((ContinuousClock.now - startedAt).components.seconds)
    hud?.update(.recording(seconds))
    button.title = Self.clock(seconds)
    button.setAccessibilityValue("已录 " + Self.spoken(seconds))
  }

  /// 锁屏、睡眠、显示器睡眠、被录的屏变了：停止并保存（不自动续录）；倒数中就是取消
  private func observeInterruptions() {
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.willSleepNotification, .sleep)
    observe(workspace, NSWorkspace.screensDidSleepNotification, .displaySleep)
    observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked"), .locked)
    let token = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkScreen() }
    }
    observers.append((NotificationCenter.default, token))
  }

  private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: Reason) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop(reason) }
    }
    observers.append((center, token))
  }

  /// 被录的屏不在了、或它的 frame / 缩放变了才停；别的屏变化不管
  private func checkScreen() {
    let screen = NSScreen.screens.first { $0.displayID == displayID }
    if screen?.frame != screenFrame || screen?.backingScaleFactor != scale {
      stop(.screenChanged)
    }
  }

  // MARK: 收尾

  private func tearDown() {
    delegate.feed.finish()
    hideChrome()
    stream = nil
    output = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
  }

  /// 挪文件：开始过、文件在就挪进快速保存目录（「录屏 <开录时刻>」，重名追加序号）。挪不过去（如桌面的文件夹授权被拒）的
  /// 留在原地（系统不清理），改成同样的名字，AppDelegate 在访达里选中它。放弃的（倒数刚结束时按到的取消也算）删掉。
  /// 都删「进行中」记录：这次是正常收尾，下次启动不该说「没有正常结束」
  private func finalize(_ reason: Reason) -> Result {
    defaults.removeObject(forKey: Prefs.screenRecordingInProgress)
    let manager = FileManager.default
    let duration = startedAt.map { (endedAt ?? .now) - $0 } ?? .zero
    guard startedAt != nil, manager.fileExists(atPath: temp.path),
      reason != .discarded, reason != .cancelled
    else {
      try? manager.removeItem(at: temp)
      return Result(file: nil, moved: false, duration: duration, reason: reason, region: region)
    }
    let target = Self.savedURL(for: temp, in: directory)
    do {
      try manager.moveItem(at: temp, to: target)
      return Result(file: target, moved: true, duration: duration, reason: reason, region: region)
    } catch {
      Log.record.error("录屏挪不进快速保存目录：\(error)")
      let renamed = Self.savedURL(for: temp, in: temp.deletingLastPathComponent())
      let file = (try? manager.moveItem(at: temp, to: renamed)) != nil ? renamed : temp
      return Result(file: file, moved: false, duration: duration, reason: reason, region: region)
    }
  }

  /// 最后一帧（R11-a 飞入用；不用框选时的冻结帧，录了几分钟画面早变了）：取在时长前一点点（正好在时长上常取不到），
  /// 先要那一刻的那一帧，取不到再放宽容差（可能退到更早的关键帧）；按 pixels（选区像素）限长边 1600。
  /// 系统的 async API，主线程直接 await。文件太短、取不到返回 nil（AppDelegate 只出岛、卡片用播放符号占位）
  static func poster(of file: URL, pixels: CGSize) async -> CGImage? {
    let asset = AVURLAsset(url: file)
    guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.maximumSize = posterLimit(pixels)
    generator.requestedTimeToleranceAfter = .zero
    let time = CMTime(seconds: posterTime(duration.seconds), preferredTimescale: 600)
    for before in [CMTime.zero, .positiveInfinity] {
      generator.requestedTimeToleranceBefore = before
      if let image = try? await generator.image(at: time).image { return image }
    }
    Log.record.notice("录屏取不到最后一帧：\(file.lastPathComponent)")
    return nil
  }

  /// 进行中的文件放哪（C7）：不放系统临时目录——开机 / 登录时系统会清空 TemporaryItems，断电或闪退后再开机就找不到了。
  /// 快速保存目录和 Application Support 同卷（常见：都在启动盘）时放 Application Support/<bundle id>/Recording/（系统不清理，
  /// 也不受桌面 / 下载的文件夹授权影响）；不同卷（移动硬盘、NAS）时放快速保存目录里的隐藏文件。都和保存目录同卷，
  /// 写完 moveItem 只是改名。文件名带 UUID：打不开留在原地的旧文件不会被下一次覆盖
  private static func workFile(for directory: URL) -> URL {
    let name = "录屏 \(UUID().uuidString).mp4"
    let volume = { (url: URL) in
      (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }
    let support = URL.applicationSupportDirectory
    guard let here = volume(support), let there = volume(directory), here.isEqual(there) else {
      return directory.appending(path: "." + name)
    }
    let folder = support.appending(
      path: "\(Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")/Recording")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: name)
  }

  /// 挪进快速保存目录用的名字：「录屏 <开录的时刻>.mp4」——取文件的创建时间（系统开录时建文件），不按挪的时刻：
  /// 录 30 分钟的、闪退后隔几天才恢复的，名字都还是开录那一刻（C8）
  static func savedURL(for file: URL, in directory: URL) -> URL {
    let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    return ScreenshotOutput.availableURL(
      in: directory, date: created ?? .now, prefix: "录屏", ext: "mp4")
  }

  /// 启动时（AppDelegate，单测宿主不跑）：偏好里还记着进行中的文件 = 上次没正常收尾（闪退、断电）。文件不在了只删记录；
  /// 能播（常见：本 App 被 kill -9 后 replayd 自己收尾）就挪进快速保存目录；打不开（系统崩溃 / 断电）留在原地、说路径和大小。
  /// 都删记录（只提示一次）；返回要弹的岛
  static func recover(into directory: URL, defaults: UserDefaults = .standard) async -> (
    title: String, detail: String, tone: Island.Tone
  )? {
    guard let path = defaults.string(forKey: Prefs.screenRecordingInProgress) else { return nil }
    defaults.removeObject(forKey: Prefs.screenRecordingInProgress)
    let manager = FileManager.default
    guard manager.fileExists(atPath: path) else { return nil }
    let file = URL(filePath: path)
    let playable = (try? await AVURLAsset(url: file).load(.isPlayable)) ?? false
    if playable {
      let target = savedURL(for: file, in: directory)
      if (try? manager.moveItem(at: file, to: target)) != nil {
        return ("上次录屏没有正常结束，已保存", target.lastPathComponent, .info)
      }
    }
    let bytes =
      ((try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    return (
      playable ? "上次录屏没有正常结束" : "上次录屏没有正常结束，文件打不开",
      "\((path as NSString).abbreviatingWithTildeInPath) · \(bytes.formatted(.byteCount(style: .file)))",
      .warning
    )
  }

  // MARK: 纯函数（配单测）

  /// 输出像素：点 × 每点像素；宽或高超过 4096 时等比缩到都不超过；宽高取偶数（H.264）、至少 2
  nonisolated static func outputSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
    var width = points.width * scale
    var height = points.height * scale
    let longest = max(width, height)
    if longest > CGFloat(maxSide) {
      width *= CGFloat(maxSide) / longest
      height *= CGFloat(maxSide) / longest
    }
    let even = { (value: CGFloat) in max(2, Int(value.rounded()) / 2 * 2) }
    return (even(width), even(height))
  }

  /// poster 取帧的时刻（秒）：时长前 0.1 s，不到 0.1 s 的取开头
  nonisolated static func posterTime(_ duration: Double) -> Double {
    max(0, duration - 0.1)
  }

  /// poster 的尺寸上限（AVAssetImageGenerator.maximumSize，等比缩进去）：选区像素，长边不超过 posterMaxSide
  nonisolated static func posterLimit(_ pixels: CGSize) -> CGSize {
    let fit = min(1, posterMaxSide / max(pixels.width, pixels.height, 1))
    return CGSize(width: (pixels.width * fit).rounded(), height: (pixels.height * fit).rounded())
  }

  /// 开录前倒数几秒：设置里只给 0 / 3 / 5，存的值在 0…5 之间照用（实录自检用 1 s），出了这个范围按默认 3
  nonisolated static func countdownSeconds(_ stored: Int) -> Int {
    (0...(Prefs.screenRecordCountdownChoices.max() ?? 5)).contains(stored) ? stored : 3
  }

  /// 倒数开始时的播报（按实际秒数）；Esc 没注册上就不提它
  nonisolated static func countdownAnnouncement(_ seconds: Int, escapes: Bool) -> String {
    "\(seconds) 秒后开始录屏" + (escapes ? "，按 Esc 取消" : "")
  }

  /// 收尾按什么说：用户放弃 / 取消过就按它（放弃后写完超时、取消挂着时没开起来，都不能说成「已保存已录的部分」/「录屏失败」、
  /// 把文件挪进保存目录），否则按 record 返回的
  nonisolated static func outcome(_ returned: Reason, abandoned: Reason?) -> Reason {
    abandoned ?? returned
  }

  /// 计时：「0:12」，一小时起「1:02:03」（菜单栏停止项和录制 HUD 共用）
  nonisolated static func clock(_ seconds: Int) -> String {
    let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", seconds / 60, rest)
  }

  /// 旁白读的时长：「12 秒」「1 分 5 秒」「1 小时 2 分 3 秒」
  nonisolated static func spoken(_ seconds: Int) -> String {
    let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    if hours > 0 { return "\(hours) 小时 \(minutes) 分 \(rest) 秒" }
    return minutes > 0 ? "\(minutes) 分 \(rest) 秒" : "\(rest) 秒"
  }

  /// 流停了：控制中心「停止共享」（-3817）当用户停的，其余是系统中止
  nonisolated static func reason(streamStopped domain: String, code: Int, text: String) -> Reason {
    domain == SCStreamError.errorDomain && code == SCStreamError.Code.userStopped.rawValue
      ? .user : .system(code: code, text: text)
  }

  /// 写入失败时按什么说（停止原因第一个为准）：已经因为中断在停（锁屏、磁盘满时系统停流……）按那个原因说；
  /// 用户停的、还没停的按写入失败说（用户停的不能说成「已保存录屏」）
  nonisolated static func reason(writeFailed text: String, stopping: Reason?) -> Reason {
    if let stopping, stopping != .user { return stopping }
    return .failed("写入失败：\(text)")
  }

  /// startCapture 抛错：-3801（用户拒绝）/ -3802（没开起来，多半是授权）按屏幕录制授权问题，其余照错误说
  nonisolated static func reason(startFailed error: any Error) -> Reason {
    let error = error as NSError
    let denied = [SCStreamError.Code.userDeclined, .failedToStart].map(\.rawValue)
    return error.domain == SCStreamError.errorDomain && denied.contains(error.code)
      ? .denied : .failed("没能开始录制：\(error.localizedDescription)")
  }

  /// 结果岛：正常停 = 已保存 + 文件名 · 时长；中断 / 失败但文件在 = 警告「已保存已录的部分」+ 原因 · 时长；
  /// 挪不进快速保存目录 = 警告「已在访达中显示」（AppDelegate 在访达里选中它；岛不接鼠标、2 s 就走，长路径没用）；
  /// 什么也没录下 = 错误；放弃 = 信息「已放弃录屏」。倒数中取消是用户自己点的，不出岛（nil，AppDelegate 只播报）。
  /// folder 是快速保存目录的访达显示名
  static func summary(_ result: Result, folder: String) -> (
    title: String, detail: String, tone: Island.Tone
  )? {
    switch result.reason {
    case .cancelled: return nil
    case .discarded: return ("已放弃录屏", "没有保存", .info)
    case .denied: return ("需要「屏幕录制」授权", "录屏要用，授权后可能要重新打开本 App", .warning)
    default: break
    }
    guard let file = result.file else {
      return ("录屏失败", result.reason.note ?? "没有录下内容", .error)
    }
    let length = clock(Int(result.duration.components.seconds))
    guard result.moved else {
      return ("录屏没能存进「\(folder)」", "已在访达中显示 · \(length)", .warning)
    }
    guard let note = result.reason.note else {
      return ("已保存录屏", "\(file.lastPathComponent) · \(length)", .success)
    }
    return ("已保存已录的部分", "\(note) · \(length)", .warning)
  }
}
