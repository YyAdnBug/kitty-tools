// 录制 HUD（录屏第 2 批，RecordingHUD）：摆位（选区外 = 录制条的位置、整屏 = 可见区底部居中离底 24、拖过的按拖到的地方）、
// 放弃要点两下的时序（纯状态）、窗口不进截图冻结帧和录制白名单（状态栏层级的普通 NSPanel，永不当 key）、按钮在两种状态下
// 交回什么；录制中的声音状态（录屏第 4 批：只读图标、两个都关不显示、麦克风断开变橙）；录音的形态（录音第 5 批：暂停钮、
// 暂停时的样子与旁白、「没听到声音」让 HUD 变宽、名字）；录系统声音时不能暂停（录音第 6 批：⏸ 原位置灰、提示原因）、「两者」麦克风断开的橙字。
// 录音的待录态（手测反馈第 3 批）：[系统声音][麦克风] ｜ [✕][●]——有哪些钮、名字和提示、✕ 点一下就关、● 交回 .start、
// 来源开关读写临时偏好域（至少留一个、只重画变了的那个、别处改了偏好跟着重画、不经 onClick）、开始中置灰、原地换成
// 录制态（换完的头一小段不认 ⏸：它正好落在刚才 ● 的位置）。
// HUD 的窗口只建不显示（不弹到屏幕上、不抢键盘）。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct RecordingHUDTests {
  /// 主屏 1440 × 900（菜单栏 24、程序坞 70），右边一块外接屏从 x = 1440 起
  static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
  static let visible = CGRect(x: 0, y: 70, width: 1440, height: 806)
  static let size = CGSize(width: 160, height: 40)

  private func origin(
    _ region: CGRect, screen: CGRect = screen, visible: CGRect = visible, full: Bool = false,
    dragged: CGPoint? = nil
  ) -> CGPoint {
    RecordingHUD.origin(
      size: Self.size, region: region, screen: screen, visible: visible, isFullScreen: full,
      dragged: dragged)
  }

  /// 选区录制：录制条原来的位置（选区下方 10、水平居中），下面放不下放上方，都放不下放进选区底部；整屏：可见区底部居中离底 24
  @Test func placesWhereTheRecordBarWas() {
    let region = CGRect(x: 300, y: 300, width: 600, height: 400)
    #expect(origin(region) == CGPoint(x: 520, y: 250))
    // 下面正好放得下 40 高 + 10 的间距（不给样式托盘留地方）；再少一点就放上方
    #expect(origin(CGRect(x: 300, y: 50, width: 600, height: 400)) == CGPoint(x: 520, y: 0))
    #expect(origin(CGRect(x: 300, y: 44, width: 600, height: 400)) == CGPoint(x: 520, y: 454))
    // 上下都放不下：选区底部里面
    #expect(origin(CGRect(x: 0, y: 20, width: 1440, height: 860)) == CGPoint(x: 640, y: 30))
    // 夹在屏内 10 pt
    #expect(origin(CGRect(x: 1400, y: 400, width: 40, height: 100)).x == 1270)  // 1440 − 160 − 10
    // 整屏：可见区（程序坞上方）底部居中、离底 24
    #expect(origin(Self.screen, full: true) == CGPoint(x: 640, y: 94))
    // 外接屏：按那块屏自己的坐标算，再换回全局
    let external = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
    let region2 = CGRect(x: 1640, y: 100, width: 800, height: 500)
    #expect(origin(region2, screen: external, visible: external) == CGPoint(x: 1960, y: 50))
    #expect(
      origin(external, screen: external, visible: external, full: true)
        == CGPoint(x: 2320, y: -176))
  }

  /// 这次运行里拖过：按拖到的地方（底边中点，宽度变了也居中），夹进可见区
  @Test func draggedPositionWinsAndStaysVisible() {
    let region = CGRect(x: 300, y: 300, width: 600, height: 400)
    #expect(origin(region, dragged: CGPoint(x: 1000, y: 600)) == CGPoint(x: 920, y: 600))
    #expect(origin(region, full: true, dragged: CGPoint(x: 1000, y: 600)).x == 920)
    // 拖到了屏外 / 菜单栏上（上次录时屏幕排布不同）：夹回可见区
    #expect(origin(region, dragged: CGPoint(x: 5, y: 10)) == CGPoint(x: 0, y: 70))
    #expect(origin(region, dragged: CGPoint(x: 2000, y: 890)) == CGPoint(x: 1280, y: 836))
    // 倒数换录制态变宽（137 → 168）按原来的水平中心重摆：倒数时离右边 10 pt 的（中心 1361.5）夹回可见区，不伸出屏幕
    #expect(RecordingHUD.x(width: 168, midX: 1361.5, in: Self.visible) == 1272)  // 1440 − 168
    #expect(RecordingHUD.x(width: 168, midX: 700, in: Self.visible) == 616)
  }

  /// 收起时断开 HUD ↔ 窗口的互相持有：录完一次 HUD 和它的窗口都放掉（不然每录一次漏一个状态栏窗口）
  @Test func closeReleasesHUDAndWindow() {
    weak var hud: RecordingHUD?
    weak var panel: NSPanel?
    autoreleasepool {
      let made = RecordingHUD(state: .countdown(3), stopKey: nil)
      made.update(.recording(0))
      hud = made
      panel = made.panel
      made.close()
    }
    #expect(hud == nil && panel == nil)
  }

  /// 放弃要点两下：第一下上膛，2 s 内再点才放弃；过了 2 s 恢复，下一下重新上膛
  @Test func discardNeedsTwoPressesWithinTwoSeconds() {
    let start = ContinuousClock.now
    var discard = RecordingHUD.Discard()
    /// 在 start 之后 seconds 秒点一下：放弃了没有
    func press(_ seconds: Double) -> Bool { discard.press(at: start + .seconds(seconds)) }
    #expect(!discard.isArmed(at: start))
    let first = press(0)
    #expect(!first && discard.isArmed(at: start + .seconds(1.9)))
    let second = press(1.9)
    #expect(second && !discard.isArmed(at: start + .seconds(1.9)))
    // 过时：恢复，这一下重新上膛而不是放弃
    let late = press(3)
    #expect(!late && !discard.isArmed(at: start + .seconds(5)))
    let rearm = press(5)
    let confirm = press(5.5)
    #expect(!rearm && confirm)
  }

  /// 状态栏层级的普通 NSPanel：截图冻结帧（keptOwnWindows）和录制的白名单（recordedOwnWindows）都不收它；
  /// 不激活本 App、永不当 key，所有桌面、全屏 App 上都在
  @Test func windowStaysOutOfCapturesAndNeverKey() {
    let hud = RecordingHUD(state: .countdown(3), stopKey: "⌥R")
    let panel = hud.panel
    let own = ScreenCapture.OwnWindow(
      id: 42, className: String(describing: type(of: panel)), level: panel.level.rawValue,
      isVisible: true, alpha: 1)
    #expect(own.className == "NSPanel" && panel.level == .statusBar)
    #expect(ScreenCapture.keptOwnWindows([own]).isEmpty)
    #expect(ScreenCapture.recordedOwnWindows([own]).isEmpty)
    #expect(!panel.canBecomeKey && !panel.canBecomeMain)
    #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.becomesKeyOnlyIfNeeded)
    #expect(
      panel.collectionBehavior.isSuperset(of: [
        .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
      ]))
    #expect(panel.isMovableByWindowBackground)
    #expect(!panel.isVisible)
  }

  /// 倒数：点数字马上开始、✕ 取消；录制中：✕ 第一下只上膛（变红、名字换成「再点一次放弃」），第二下才放弃；■ 停止，
  /// 提示写当前的录屏快捷键（没绑定只写「停止并保存」）
  @Test func buttonsReportByState() throws {
    var clicks: [RecordingHUD.Item] = []
    let hud = RecordingHUD(state: .countdown(3), stopKey: "⌥R")
    hud.onClick = { clicks.append($0) }
    #expect(hud.accessibilityLabel() == "录屏控制" && hud.accessibilityValue() as? String == "3 秒后开始")
    try #require(hud.button(for: .startNow)).performClick(nil)
    let close = try #require(hud.button(for: .cancel))
    // Esc 没注册上（默认）：提示不写 Esc
    #expect(close.accessibilityLabel() == "取消" && close.toolTip == "取消")
    let escaping = RecordingHUD(state: .countdown(3), stopKey: "⌥R", escapes: true)
    #expect(try #require(escaping.button(for: .cancel)).toolTip == "取消（Esc）")
    close.performClick(nil)
    #expect(clicks == [.startNow, .cancel])

    clicks = []
    let countdownWidth = hud.frame.width
    hud.update(.recording(0))
    #expect(hud.frame.width != countdownWidth)
    let discard = try #require(hud.button(for: .discard))
    #expect(discard.accessibilityLabel() == "放弃录制")
    discard.performClick(nil)
    #expect(clicks.isEmpty)
    #expect(discard.accessibilityLabel() == "再点一次放弃" && discard.contentTintColor == .systemRed)
    #expect(discard.toolTip == "再点一次放弃，不会保存")
    discard.performClick(nil)
    #expect(clicks == [.discard])
    let stop = try #require(hud.button(for: .stop))
    #expect(stop.toolTip == "停止并保存（⌥R）" && stop.accessibilityLabel() == "停止并保存")
    stop.performClick(nil)
    #expect(clicks == [.discard, .stop])
    // 每秒换读数：宽度按 h:mm:ss 留好，一小时起也不跳（重新量一次）；读屏读值、不逐秒播报
    let width = hud.frame.width
    hud.update(.recording(3725))
    RunLoop.main.run(until: .now + 0.1)
    hud.fit()
    #expect(hud.frame.width == width)
    #expect(hud.accessibilityValue() as? String == "已录 1 小时 2 分 5 秒")

    let unbound = RecordingHUD(state: .recording(0), stopKey: nil)
    #expect(try #require(unbound.button(for: .stop)).toolTip == "停止并保存")
  }

  /// 录制中的声音状态（第 4 批）：计时和 ✕ 之间两个只读图标（开 = 强调色、关 = 再次文字色 + 斜杠），两个都关不显示这段；
  /// 倒数时没有；开录时的麦克风断开 → 麦克风图标变 systemOrange、旁白说后面没有麦克风声音（只对开着的麦克风）
  @Test func soundStatusIsReadOnly() throws {
    func icons(_ hud: RecordingHUD) -> [NSImageView] {
      var found: [NSImageView] = []
      var queue: [NSView] = [hud]
      while let view = queue.popLast() {
        if let image = view as? NSImageView, !(view.superview is NSButton) { found.append(image) }
        queue += view.subviews
      }
      return found.sorted {
        $0.convert($0.bounds, to: hud).minX < $1.convert($1.bounds, to: hud).minX
      }
    }
    let silent = RecordingHUD(state: .recording(0), stopKey: nil)
    #expect(icons(silent).isEmpty)
    let both = RecordingHUD(state: .countdown(3), stopKey: nil, systemAudio: true, microphone: true)
    #expect(icons(both).isEmpty)  // 倒数时不显示
    both.update(.recording(0))
    let shown = icons(both)
    #expect(shown.map { $0.accessibilityLabel() } == ["系统声音：开", "麦克风：开"])
    #expect(shown.allSatisfy { $0.contentTintColor == Style.Shot.accent })
    #expect(shown.allSatisfy { $0.toolTip == "录制中不能开关声音" })
    #expect(both.frame.width > silent.frame.width)
    // 声音图标在计时和 ✕ 之间
    let close = try #require(both.button(for: .discard))
    #expect(
      shown.allSatisfy {
        $0.convert($0.bounds, to: both).maxX < close.convert(close.bounds, to: both).minX
      })
    both.microphoneLost()
    let lost = icons(both)
    #expect(lost[1].contentTintColor == .systemOrange)
    #expect(lost[1].accessibilityLabel() == "麦克风断开了，后面没有麦克风声音")
    #expect(lost[0].contentTintColor == Style.Shot.accent)

    let systemOnly = RecordingHUD(state: .recording(0), stopKey: nil, systemAudio: true)
    let mixed = icons(systemOnly)
    #expect(mixed.map { $0.accessibilityLabel() } == ["系统声音：开", "麦克风：关"])
    #expect(mixed[1].contentTintColor == Style.HUD.tertiaryText)
    systemOnly.microphoneLost()  // 没录麦克风：不变
    #expect(icons(systemOnly)[1].contentTintColor == Style.HUD.tertiaryText)
  }

  /// 录音的形态（录音第 5 批）：[● 0:42][电平] ｜ [⏸] ｜ [✕][■]——没有倒数；⏸ 交回 .pause，暂停后变 ▶「继续录音」、旁白值
  /// 「已暂停，已录 …」；✕ 叫「放弃录音」（同样点两下）；■ 提示写录音快捷键；「没听到声音」出现时 HUD 变宽、收起时变回
  @Test func audioFormPausesAndWarns() throws {
    var clicks: [RecordingHUD.Item] = []
    let hud = RecordingHUD(state: .recording(42), stopKey: "⌃⌥V", medium: .audio)
    hud.onClick = { clicks.append($0) }
    #expect(hud.accessibilityLabel() == "录音控制")
    #expect(hud.accessibilityValue() as? String == "已录 42 秒")
    // 窗口四周留 24 pt 透明边（从底边长出时往下偏 8 pt 不被切掉）、阴影是 HUDBar 自己的；录屏 HUD 不留、用系统阴影
    #expect(hud.superview === hud.panel.contentView && hud.frame.origin == CGPoint(x: 24, y: 24))
    #expect(!hud.panel.hasShadow)
    let screenHUD = RecordingHUD(state: .recording(0), stopKey: nil)
    #expect(screenHUD.frame.origin == .zero && screenHUD.panel.hasShadow)
    let pause = try #require(hud.button(for: .pause))
    let close = try #require(hud.button(for: .discard))
    let stop = try #require(hud.button(for: .stop))
    #expect(pause.accessibilityLabel() == "暂停录音" && pause.toolTip == "暂停录音")
    #expect(close.accessibilityLabel() == "放弃录音" && close.toolTip == "放弃录音（不保存）")
    #expect(stop.toolTip == "停止并保存（⌃⌥V）" && stop.accessibilityLabel() == "停止并保存")
    // 从左到右：暂停在 ✕ 前面、■ 最后
    let x = { (view: NSView) in view.convert(view.bounds, to: hud).minX }
    #expect(x(pause) < x(close) && x(close) < x(stop))
    pause.performClick(nil)
    #expect(clicks == [.pause])  // 暂停由会话来做，HUD 等它回头 setPaused
    #expect(!hud.isPaused)
    hud.setPaused(true)
    #expect(hud.isPaused && pause.accessibilityLabel() == "继续录音" && pause.toolTip == "继续录音")
    #expect(hud.accessibilityValue() as? String == "已暂停，已录 42 秒")
    hud.update(.recording(43))
    #expect(hud.accessibilityValue() as? String == "已暂停，已录 43 秒")
    hud.setPaused(false)
    #expect(
      pause.accessibilityLabel() == "暂停录音" && hud.accessibilityValue() as? String == "已录 43 秒")
    close.performClick(nil)
    close.performClick(nil)
    stop.performClick(nil)
    #expect(clicks == [.pause, .discard, .stop])
    // 「没听到声音」：计时旁边出一行橙字，HUD 变宽；收起后宽度回来
    let width = hud.frame.width
    hud.setSilent(true)
    #expect(hud.frame.width > width)
    hud.setSilent(false)
    #expect(hud.frame.width == width)
    hud.updateMeter([-60, -20, -0.5])  // 只画，不改布局
    #expect(hud.frame.width == width)
    // 录屏的 HUD 没有暂停钮，暂停 / 没听到声音对它不起作用
    let screen = RecordingHUD(state: .recording(0), stopKey: nil)
    #expect(screen.button(for: .pause) == nil && screen.accessibilityLabel() == "录屏控制")
    let screenWidth = screen.frame.width
    screen.setPaused(true)
    screen.setSilent(true)
    #expect(!screen.isPaused && screen.frame.width == screenWidth)
    #expect(try #require(screen.button(for: .discard)).accessibilityLabel() == "放弃录制")
  }

  /// 录系统声音（录音第 6 批，录屏管线没有暂停）：⏸ 还在原来的位置（HUD 一样宽）、置灰、提示为什么；点它不交回点击
  @Test func systemAudioCannotPause() throws {
    var clicks: [RecordingHUD.Item] = []
    let hud = RecordingHUD(state: .recording(7), stopKey: nil, medium: .audio, pausable: false)
    hud.onClick = { clicks.append($0) }
    let pause = try #require(hud.button(for: .pause))
    #expect(!pause.isEnabled && pause.alphaValue == 0.35)
    #expect(pause.toolTip == "录系统声音时不能暂停" && pause.accessibilityLabel() == "暂停录音")
    let pausable = RecordingHUD(state: .recording(7), stopKey: nil, medium: .audio)
    #expect(hud.frame.width == pausable.frame.width)
    #expect(try #require(pausable.button(for: .pause)).isEnabled)
    pause.performClick(nil)
    #expect(clicks.isEmpty)
    try #require(hud.button(for: .stop)).performClick(nil)
    #expect(clicks == [.stop])
  }

  /// 录音的待录态（手测反馈第 3 批）：[系统声音][麦克风] ｜ [✕][●]。✕ 叫「关闭」、点一下就交回 .cancel（没有东西可放弃，
  /// 不上膛）；● 叫「开始录音」、提示写录音快捷键（没设不写括号）、交回 .start；旁白一组「录音控制」、值「还没开始录」。
  /// 来源开关按偏好画（开 = 强调色），点了写偏好、至少留一个、不经 onClick；别处改了偏好（设置 › 录制）跟着重画
  @Test func readyFormTogglesSourceAndStarts() throws {
    let suite = "kitty-test-hud-ready-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var clicks: [RecordingHUD.Item] = []
    let hud = RecordingHUD(state: .ready, stopKey: "⌃⌥V", medium: .audio, defaults: defaults)
    hud.onClick = { clicks.append($0) }
    defer { hud.close() }
    #expect(hud.accessibilityLabel() == "录音控制" && hud.accessibilityValue() as? String == "还没开始录")
    let system = try #require(hud.button(for: .systemAudio))
    let microphone = try #require(hud.button(for: .microphone))
    let close = try #require(hud.button(for: .cancel))
    let start = try #require(hud.button(for: .start))
    // 从左到右：系统声音、麦克风、✕、●；待录时没有暂停、停止（不在栏里）
    let x = { (view: NSView) in view.convert(view.bounds, to: hud).minX }
    #expect(x(system) < x(microphone) && x(microphone) < x(close) && x(close) < x(start))
    #expect(try #require(hud.button(for: .pause)).superview == nil)
    #expect(try #require(hud.button(for: .stop)).superview == nil)
    #expect(close.accessibilityLabel() == "关闭" && close.toolTip == "关闭")
    #expect(start.accessibilityLabel() == "开始录音" && start.toolTip == "开始录音（⌃⌥V）")
    #expect(start.frame.size == CGSize(width: 28, height: 28))
    #expect(start.layer?.backgroundColor == Style.Shot.accent.cgColor)
    let unbound = RecordingHUD(state: .ready, stopKey: nil, medium: .audio, defaults: defaults)
    defer { unbound.close() }
    #expect(try #require(unbound.button(for: .start)).toolTip == "开始录音")
    // 录屏的 HUD 没有这三个钮
    let screen = RecordingHUD(state: .recording(0), stopKey: nil)
    #expect(
      screen.button(for: .start) == nil && screen.button(for: .systemAudio) == nil
        && screen.button(for: .microphone) == nil)

    /// 开关开着没有：里面的符号染强调色
    func isOn(_ button: NSButton) -> Bool {
      button.subviews.compactMap { $0 as? NSImageView }.first?.contentTintColor == Style.Shot.accent
    }
    /// 开关里画着的那张图（每次重画都是新的一张：没重画就还是同一张）
    func image(_ button: NSButton) -> NSImage? {
      button.subviews.compactMap { $0 as? NSImageView }.first?.image
    }
    // 临时偏好域里没存过：默认麦克风
    #expect(!isOn(system) && isOn(microphone))
    #expect(system.accessibilityLabel() == "系统声音：关")
    // 只重画状态变了的那个：没变的开关不跟着放一遍 .replace 过渡（评审）
    var (systemImage, microphoneImage) = (image(system), image(microphone))
    system.performClick(nil)
    #expect(AudioRecorder.Source(defaults) == .both && isOn(system) && isOn(microphone))
    #expect(image(system) !== systemImage && image(microphone) === microphoneImage)
    #expect(system.accessibilityLabel() == "系统声音：开")
    #expect(microphone.accessibilityLabel()?.hasPrefix("麦克风：开") == true)
    systemImage = image(system)
    microphone.performClick(nil)
    #expect(AudioRecorder.Source(defaults) == .system && isOn(system) && !isOn(microphone))
    #expect(image(system) === systemImage && image(microphone) !== microphoneImage)
    #expect(microphone.accessibilityLabel()?.hasPrefix("麦克风：关") == true)
    // 关掉唯一开着的那个：另一个自动打开（两个都变，都重画）
    microphoneImage = image(microphone)
    system.performClick(nil)
    #expect(AudioRecorder.Source(defaults) == .microphone && !isOn(system) && isOn(microphone))
    #expect(image(system) !== systemImage && image(microphone) !== microphoneImage)
    #expect(clicks.isEmpty)  // 开关是 HUD 自己的事，不交给会话
    // 别处改了偏好：开关跟着重画（另一个 HUD 同一个偏好域，出现时按偏好画）
    defaults.set(AudioRecorder.Source.both.rawValue, forKey: Prefs.audioRecordSource)
    RunLoop.main.run(until: .now + 0.05)
    #expect(isOn(system) && isOn(microphone))
    #expect(isOn(try #require(unbound.button(for: .systemAudio))))

    // ✕ 点一下就关（不上膛）；● 开始
    close.performClick(nil)
    #expect(clicks == [.cancel] && close.contentTintColor == Style.HUD.text)
    start.performClick(nil)
    #expect(clicks == [.cancel, .start])
  }

  /// 按了开始、还没真正录起来（等授权框、流还在开）：来源开关和 ● 置灰、点了没反应，✕ 还能点；录起来后同一个 HUD 原地
  /// 换成录制态（开关和 ● 换成计时、电平、⏸、■，✕ 变成要点两下的「放弃录音」），录系统声音的 ⏸ 置灰
  @Test func readyGoesBusyThenRecordsInPlace() throws {
    let suite = "kitty-test-hud-ready-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(AudioRecorder.Source.system.rawValue, forKey: Prefs.audioRecordSource)
    var clicks: [RecordingHUD.Item] = []
    weak var released: RecordingHUD?
    try autoreleasepool {
      let hud = RecordingHUD(state: .ready, stopKey: nil, medium: .audio, defaults: defaults)
      released = hud
      hud.onClick = { clicks.append($0) }
      let panel = hud.panel
      let system = try #require(hud.button(for: .systemAudio))
      let microphone = try #require(hud.button(for: .microphone))
      let start = try #require(hud.button(for: .start))
      let close = try #require(hud.button(for: .cancel))
      let readyWidth = hud.frame.width
      hud.setStarting()
      #expect(!system.isEnabled && !microphone.isEnabled && !start.isEnabled)
      #expect(system.alphaValue == 0.35 && start.alphaValue == 0.35)
      #expect(close.isEnabled && hud.frame.width == readyWidth)
      system.performClick(nil)
      start.performClick(nil)
      #expect(clicks.isEmpty && AudioRecorder.Source(defaults) == .system)
      close.performClick(nil)
      #expect(clicks == [.cancel])

      clicks = []
      hud.setPausable(false)
      hud.update(.recording(0))
      #expect(hud.panel === panel && hud.state == .recording(0))
      #expect(hud.frame.width > readyWidth)
      #expect(system.superview == nil && microphone.superview == nil && start.superview == nil)
      #expect(hud.accessibilityValue() as? String == "已录 0 秒")
      let pause = try #require(hud.button(for: .pause))
      #expect(pause.superview != nil && !pause.isEnabled && pause.toolTip == "录系统声音时不能暂停")
      let stop = try #require(hud.button(for: .stop))
      #expect(stop.superview != nil)
      let discard = try #require(hud.button(for: .discard))
      #expect(discard === close && discard.accessibilityLabel() == "放弃录音")
      discard.performClick(nil)
      #expect(clicks.isEmpty)  // 录制中的 ✕ 要点两下
      stop.performClick(nil)
      #expect(clicks == [.stop])
      // 和直接开始的录音 HUD 一样宽；能暂停的来源 ⏸ 可点
      let direct = RecordingHUD(
        state: .recording(0), stopKey: nil, medium: .audio, pausable: false)
      #expect(hud.frame.width == direct.frame.width)
      hud.setPausable(true)
      #expect(pause.isEnabled && pause.toolTip == "暂停录音")
      // ⏸ 正好落在刚才 ● 的位置上：换成录制态后的头一小段（系统的双击间隔，最多 1 s）点它不算，免得双击 ● 一开始就
      // 暂停；过了照常。直接开始的录音 HUD 不挡
      pause.performClick(nil)
      #expect(clicks == [.stop])
      #expect(hud.ignoresPause(at: .now) && !hud.ignoresPause(at: .now + .seconds(1)))
      #expect(!direct.ignoresPause(at: .now))
      hud.close()
    }
    // 收起后放掉（偏好的观察者摘了）
    #expect(released == nil)
  }

  /// 「两者」录着时麦克风断开（录音第 6 批，评审 S1）：录音 HUD 没有声音图标，「没听到声音」那个位置换成橙字「麦克风断开了」、
  /// HUD 变宽；已经在出「没听到声音」时也换成它
  @Test func audioMicrophoneLostShowsNote() throws {
    func note(_ hud: RecordingHUD) -> NSTextField? {
      var views: [NSView] = [hud]
      while let view = views.popLast() {
        if let label = view as? NSTextField, !label.isHidden, label.textColor == .systemOrange {
          return label
        }
        views += view.subviews
      }
      return nil
    }
    let hud = RecordingHUD(state: .recording(7), stopKey: nil, medium: .audio, pausable: false)
    let width = hud.frame.width
    #expect(note(hud) == nil)
    hud.microphoneLost()
    let label = try #require(note(hud))
    #expect(label.stringValue == "麦克风断开了")
    #expect(label.toolTip == "麦克风断开了，后面没有麦克风声音")
    #expect(hud.frame.width > width)
    let silent = RecordingHUD(state: .recording(7), stopKey: nil, medium: .audio, pausable: false)
    silent.setSilent(true)
    silent.microphoneLost()
    #expect(try #require(note(silent)).stringValue == "麦克风断开了")
  }
}
