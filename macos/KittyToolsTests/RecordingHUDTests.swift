// 录制 HUD（录屏第 2 批，RecordingHUD）：摆位（选区外 = 录制条的位置、整屏 = 可见区底部居中离底 24、拖过的按拖到的地方；
// 2026-10-12 视觉对齐起按右边线对齐：录制条 → 倒数 → 录制态、录音的待录 → 录制，✕ 和主圆钮不挪，宽度变了右边线不动）、
// 放弃要点两下的时序（纯状态）、窗口不进截图冻结帧和录制白名单（状态栏层级的普通 NSPanel，永不当 key）、按钮在两种状态下
// 交回什么；录制中的声音状态（录屏第 4 批：只读图标、两个都关不显示、麦克风断开变橙）；录音的形态（录音第 5 批：暂停钮、
// 暂停时的样子与旁白、「没听到声音」让 HUD 变宽、名字）；录系统声音时不能暂停（录音第 6 批：⏸ 原位置灰、提示原因）、「两者」麦克风断开的橙字。
// 计时是图层排的（Shell/Ticker.swift，2026-10-11 从 numericText 换过来）：每秒只换变了的那位、暂停时整行重排、按当前读数的
// 位数留宽（到 10 分钟、1 小时各变宽一次）。
// 录音的待录态（手测反馈第 3 批）：[系统声音][麦克风] ｜ [✕][●]——有哪些钮、名字和提示、✕ 点一下就关、● 交回 .start、
// 来源开关读写临时偏好域（至少留一个、只重画变了的那个、别处改了偏好跟着重画、不经 onClick）、开始中置灰、原地换成
// 录制态（换完的头一小段不认 ■：它正好落在刚才 ● 的位置）。
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
  /// 录制条的宽（真的栏是 RecordBar.width，formsShareTheRecordBarsRightEdge 锁住；这里给定值，期望的数好核对）
  static let bar: CGFloat = 222

  private func origin(
    _ region: CGRect, size: CGSize = size, screen: CGRect = screen, visible: CGRect = visible,
    full: Bool = false, dragged: CGPoint? = nil
  ) -> CGPoint {
    RecordingHUD.origin(
      size: size, region: region, screen: screen, visible: visible, isFullScreen: full,
      dragged: dragged, bar: Self.bar)
  }

  /// 选区录制：接在录制条原来的位置（222 宽的栏在选区下方 10、水平居中），右边线对着录制条的右边线；下面放不下放上方，
  /// 都放不下放进选区底部；整屏：可见区底部居中离底 24
  @Test func placesWhereTheRecordBarWas() {
    let region = CGRect(x: 300, y: 300, width: 600, height: 400)
    // 录制条 489…711：160 宽的 HUD 右边线也在 711
    #expect(origin(region) == CGPoint(x: 551, y: 250))
    // 不管 HUD 多宽（倒数、录制态、带不带声音图标），右边线都在录制条的右边线上
    for width: CGFloat in [146, 172, 194, 222] {
      let placed = origin(region, size: CGSize(width: width, height: 40))
      #expect(placed.x + width == 711 && placed.y == 250)
    }
    // 下面正好放得下 40 高 + 10 的间距（不给样式托盘留地方）；再少一点就放上方
    #expect(origin(CGRect(x: 300, y: 50, width: 600, height: 400)) == CGPoint(x: 551, y: 0))
    #expect(origin(CGRect(x: 300, y: 44, width: 600, height: 400)) == CGPoint(x: 551, y: 454))
    // 上下都放不下：选区底部里面（录制条 609…831）
    #expect(origin(CGRect(x: 0, y: 20, width: 1440, height: 860)) == CGPoint(x: 671, y: 30))
    // 录制条夹在屏内 10 pt，HUD 跟着它的右边线：贴右边的选区右边线离屏边 10，贴左边的录制条 10…232
    #expect(origin(CGRect(x: 1400, y: 400, width: 40, height: 100)).x == 1270)  // 1440 − 10 − 160
    #expect(origin(CGRect(x: 0, y: 400, width: 40, height: 100)).x == 72)  // 232 − 160
    // 整屏：可见区（程序坞上方）底部居中、离底 24（不跟录制条）
    #expect(origin(Self.screen, full: true) == CGPoint(x: 640, y: 94))
    // 外接屏：按那块屏自己的坐标算，再换回全局（录制条在那块屏里 489…711）
    let external = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
    let region2 = CGRect(x: 1640, y: 100, width: 800, height: 500)
    #expect(origin(region2, screen: external, visible: external) == CGPoint(x: 1991, y: 50))
    #expect(
      origin(external, screen: external, visible: external, full: true)
        == CGPoint(x: 2320, y: -176))
  }

  /// 这次运行里拖过：按拖到的地方（记的是右下角：各种宽度的形态右边线都摆在那），夹进可见区
  @Test func draggedPositionWinsAndStaysVisible() {
    let region = CGRect(x: 300, y: 300, width: 600, height: 400)
    #expect(origin(region, dragged: CGPoint(x: 1000, y: 600)) == CGPoint(x: 840, y: 600))
    #expect(origin(region, full: true, dragged: CGPoint(x: 1000, y: 600)).x == 840)
    // 拖到了屏外 / 菜单栏上（上次录时屏幕排布不同）：夹回可见区
    #expect(origin(region, dragged: CGPoint(x: 5, y: 10)) == CGPoint(x: 0, y: 70))
    #expect(origin(region, dragged: CGPoint(x: 2000, y: 890)) == CGPoint(x: 1280, y: 836))
    // 宽度变了重摆（倒数换录制态、计时多一位、出橙字）：右边线不动，往左长
    #expect(RecordingHUD.x(width: 172, maxX: 711, in: Self.visible) == 539)
    #expect(RecordingHUD.x(width: 194, maxX: 711, in: Self.visible) == 517)
    // 贴着左边的变宽后会伸出屏幕：夹回可见区（这时右边线才挪）；右边线在屏外的夹回来
    #expect(RecordingHUD.x(width: 311, maxX: 160, in: Self.visible) == 0)
    #expect(RecordingHUD.x(width: 168, maxX: 2000, in: Self.visible) == 1272)  // 1440 − 168
  }

  /// 钮的中心离栏的右边线多远（栏按右边线对齐：这个数一样 = 屏幕上同一个位置）
  private func fromRight(_ button: NSView, in bar: NSView) -> CGFloat {
    bar.layoutSubtreeIfNeeded()
    return bar.bounds.maxX - button.convert(button.bounds, to: bar).midX
  }

  /// 右边线对齐（2026-10-12 视觉对齐）：录制条 → 倒数 → 录制态都接在同一条右边线上，✕ 三态同一个位置、■ 落在录制条的 ●
  /// 上；倒数没有圆钮，那个位置空着。之后计时多一位（10:00、1:00:00）HUD 往左长、右边线不动
  @Test func formsShareTheRecordBarsRightEdge() throws {
    let suite = "kitty-test-hud-align-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let bar = RecordBar(defaults: defaults)
    // 算位置用的栏宽和真的栏一样（往录制条里加减钮要跟着改 RecordBar.width）
    #expect(bar.frame.width == RecordBar.width)
    let region = CGRect(x: 300, y: 300, width: 600, height: 400)
    let barFrame = CGRect(
      origin: SelectionView.toolbarPlacement(
        size: bar.frame.size, selection: region, in: Self.screen, tray: 0
      ).origin, size: bar.frame.size)
    let barClose = fromRight(try #require(bar.button(for: .cancel)), in: bar)
    let barStart = fromRight(try #require(bar.button(for: .start)), in: bar)

    let hud = RecordingHUD(state: .countdown(3), stopKey: nil, systemAudio: true)
    defer { hud.close() }
    hud.arrange(
      region: region, screen: Self.screen, visible: Self.visible, display: 0x7E57_0001,
      isFullScreen: false)
    #expect(!hud.panel.isVisible)
    // 倒数：比录制条窄，右边线、底边和录制条一样；✕ 在录制条的 ✕ 那里（右边空着圆钮的位置）
    #expect(hud.screenFrame.maxX == barFrame.maxX && hud.screenFrame.minY == barFrame.minY)
    #expect(hud.screenFrame.width < barFrame.width)
    #expect(fromRight(try #require(hud.button(for: .cancel)), in: hud) == barClose)
    // 录制态：右边线不动，✕ 还在原地，■ 落在 ● 上
    hud.update(.recording(0))
    #expect(hud.screenFrame.maxX == barFrame.maxX && hud.screenFrame.minY == barFrame.minY)
    #expect(hud.screenFrame.width < barFrame.width)
    #expect(fromRight(try #require(hud.button(for: .discard)), in: hud) == barClose)
    #expect(fromRight(try #require(hud.button(for: .stop)), in: hud) == barStart)
    // 计时按位数留宽：9:59 以内不变，10:00、1:00:00 各变宽一次——往左长，右边线不动
    let narrow = hud.screenFrame
    hud.update(.recording(599))
    #expect(hud.screenFrame == narrow)
    hud.update(.recording(600))
    let wider = hud.screenFrame
    #expect(wider.maxX == narrow.maxX && wider.width > narrow.width)
    hud.update(.recording(3599))
    #expect(hud.screenFrame == wider)
    hud.update(.recording(3600))
    #expect(hud.screenFrame.maxX == narrow.maxX && hud.screenFrame.width > wider.width)
    #expect(fromRight(try #require(hud.button(for: .stop)), in: hud) == barStart)
  }

  /// 拖过的位置按屏记的是右下角：下次这块屏上各种宽度的形态都把右边线摆在那（✕ 和主圆钮回到拖到的地方）；
  /// 录屏、录音的 HUD 各记各的
  @Test func draggedSpotAnchorsTheRightEdge() throws {
    let display: CGDirectDisplayID = 0x7E57_0002
    let region = CGRect(x: 300, y: 300, width: 600, height: 400)
    func arrange(_ hud: RecordingHUD, full: Bool = false) {
      hud.arrange(
        region: full ? Self.screen : region, screen: Self.screen, visible: Self.visible,
        display: display, isFullScreen: full)
    }
    let first = RecordingHUD(state: .countdown(3), stopKey: nil)
    defer { first.close() }
    arrange(first)
    first.update(.recording(0))
    // 用户把录制态的 HUD 拖到了别处（窗口没显示：直接挪窗口、报一次挪动）
    first.panel.setFrameOrigin(CGPoint(x: 900, y: 500))
    first.windowDidMove(Notification(name: NSWindow.didMoveNotification))
    let spot = first.screenFrame
    #expect(spot.origin == CGPoint(x: 900, y: 500))

    let next = RecordingHUD(state: .countdown(3), stopKey: nil)
    defer { next.close() }
    arrange(next)
    #expect(next.screenFrame.maxX == spot.maxX && next.screenFrame.minY == spot.minY)
    #expect(next.screenFrame.width != spot.width)
    next.update(.recording(0))
    #expect(next.screenFrame == spot)  // 录制态回到拖到的那个位置
    // 程序自己摆（换状态变宽）不算拖：再来一个还是那个位置
    let third = RecordingHUD(state: .recording(0), stopKey: nil)
    defer { third.close() }
    arrange(third)
    #expect(third.screenFrame == spot)

    // 录音的 HUD 另记：这块屏上没拖过，还是可见区底部居中
    let suite = "kitty-test-hud-drag-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let audio = RecordingHUD(state: .ready, stopKey: nil, medium: .audio, defaults: defaults)
    defer { audio.close() }
    arrange(audio, full: true)
    #expect(abs(audio.screenFrame.midX - Self.visible.midX) <= 0.5)
    #expect(audio.screenFrame.minY == Self.visible.minY + 24)
  }

  /// 录音（2026-10-12 视觉对齐）：待录 → 录制右边线不动，条往左长出计时和电平——✕ 原地不动，■ 落在刚才 ● 的位置上；
  /// 之后出 / 收「没听到声音」同样只动左边
  @Test func readyGrowsLeftIntoRecording() throws {
    let suite = "kitty-test-hud-grow-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let hud = RecordingHUD(state: .ready, stopKey: nil, medium: .audio, defaults: defaults)
    defer { hud.close() }
    hud.arrange(
      region: Self.screen, screen: Self.screen, visible: Self.visible, display: 0x7E57_0003,
      isFullScreen: true)
    let ready = hud.screenFrame
    #expect(abs(ready.midX - Self.visible.midX) <= 0.5 && ready.minY == Self.visible.minY + 24)
    // 窗口四周留的 24 pt 透明边不算在 HUD 的位置里
    #expect(hud.panel.frame == ready.insetBy(dx: -24, dy: -24))
    let start = fromRight(try #require(hud.button(for: .start)), in: hud)
    let close = fromRight(try #require(hud.button(for: .cancel)), in: hud)

    hud.update(.recording(0))
    let recording = hud.screenFrame
    #expect(recording.maxX == ready.maxX && recording.minY == ready.minY)
    #expect(recording.width > ready.width)
    #expect(fromRight(try #require(hud.button(for: .stop)), in: hud) == start)
    #expect(fromRight(try #require(hud.button(for: .discard)), in: hud) == close)
    // ⏸ 不在 ● 原来的位置上了（在它左边，隔着 ✕）
    #expect(fromRight(try #require(hud.button(for: .pause)), in: hud) > close)

    hud.setSilent(true)
    #expect(hud.screenFrame.maxX == ready.maxX && hud.screenFrame.width > recording.width)
    hud.setSilent(false)
    #expect(hud.screenFrame == recording)
    hud.microphoneLost()
    #expect(hud.screenFrame.maxX == ready.maxX && hud.screenFrame.width > recording.width)
  }

  /// ■ 换到了刚点过的 ● 的位置上：换上来后的一小段（系统的双击间隔，最多 1 s）不认 ■，免得双击 ● 刚开始录就停了。
  /// 时刻是注入的。会挡的两种：录音待录 → 录制（readyGoesBusyThenRecordsInPlace）、录屏不倒数直接出录制态
  /// （接在录制条的位置）；倒数完的录屏、按快捷键直接开始的录音没有 ● 可点，不挡
  @Test func stopIsIgnoredRightAfterItReplacesStart() throws {
    let start = ContinuousClock.now
    func ignores(_ seconds: Double, since swapped: ContinuousClock.Instant?, _ doubleClick: Double)
      -> Bool
    {
      RecordingHUD.ignoresStop(
        at: start + .seconds(seconds), swappedAt: swapped, doubleClick: doubleClick)
    }
    #expect(!ignores(0, since: nil, 0.5))
    #expect(ignores(0, since: start, 0.5) && ignores(0.49, since: start, 0.5))
    #expect(!ignores(0.5, since: start, 0.5))
    // 双击调得很慢的人：最多挡 1 s
    #expect(ignores(0.99, since: start, 5) && !ignores(1, since: start, 5))
    // 双击调得快的：只挡那么久
    #expect(ignores(0.14, since: start, 0.15) && !ignores(0.15, since: start, 0.15))

    // 录屏不倒数：一建出来就是录制态（马上接在录制条的位置）→ 挡；点 ■ 不交回点击，✕ 照常（第一下上膛）
    var clicks: [RecordingHUD.Item] = []
    let direct = RecordingHUD(state: .recording(0), stopKey: nil)
    direct.onClick = { clicks.append($0) }
    #expect(direct.ignoresStop(at: .now) && !direct.ignoresStop(at: .now + .seconds(1)))
    try #require(direct.button(for: .stop)).performClick(nil)
    #expect(clicks.isEmpty)
    // 倒数完换成录制态：■ 出现在倒数时空着的位置，没有刚点过的 ●，不挡
    let counted = RecordingHUD(state: .countdown(3), stopKey: nil)
    counted.onClick = { clicks.append($0) }
    counted.update(.recording(0))
    #expect(!counted.ignoresStop(at: .now))
    try #require(counted.button(for: .stop)).performClick(nil)
    #expect(clicks == [.stop])
    // 按快捷键直接开始的录音：不挡
    #expect(!RecordingHUD(state: .recording(0), stopKey: nil, medium: .audio).ignoresStop(at: .now))
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
    // 每秒换读数：计时按当前读数的位数留宽——同一档里（0:00–9:59）不变，一小时起多了三位、HUD 跟着变宽（和直接
    // 建在那个读数上的一样宽）；读屏读值、不逐秒播报
    let width = hud.frame.width
    hud.update(.recording(59))
    #expect(hud.frame.width == width)
    hud.update(.recording(3725))
    #expect(hud.frame.width > width)
    #expect(
      hud.frame.width == RecordingHUD(state: .recording(3725), stopKey: nil).frame.width)
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

  /// 计时是图层排的（Shell/Ticker.swift；不用 numericText：它每秒逐帧重画，录制期间一直占着 CPU）：字就是 ScreenRecorder.clock，
  /// 每秒只换变了的那一位（减弱动态效果时整行直接换）；录音暂停 / 继续换颜色，整行重排；按当前读数的位数留宽
  /// （「0:00」「10:00」「1:00:00」各一档：留的就是这一行字的宽，多一位时 HUD 跟着变宽）；读数不进旁白（HUD 自己有值）
  @Test func clockRollsOnlyChangedDigits() throws {
    func ticker(_ hud: RecordingHUD) -> TickerView? {
      var queue: [NSView] = [hud]
      while let view = queue.popLast() {
        if let ticker = view as? TickerView { return ticker }
        queue += view.subviews
      }
      return nil
    }
    let hud = RecordingHUD(state: .recording(42), stopKey: nil, medium: .audio)
    let clock = try #require(ticker(hud))
    #expect(String(clock.characters) == "0:42" && !clock.isAccessibilityElement())
    #expect(ticker(RecordingHUD(state: .countdown(3), stopKey: nil)) == nil)
    var cells = clock.cells
    hud.update(.recording(43))
    #expect(String(clock.characters) == "0:43")
    #expect(zip(clock.cells, cells).filter { $0 !== $1 }.count == (Style.reduceMotion ? 4 : 1))
    cells = clock.cells
    hud.setPaused(true)
    #expect(String(clock.characters) == "0:43" && zip(clock.cells, cells).allSatisfy { $0 !== $1 })
    #expect(clock.cells.allSatisfy { $0.animation(forKey: TickerView.slideKey) == nil })
    cells = clock.cells
    hud.setPaused(false)
    #expect(zip(clock.cells, cells).allSatisfy { $0 !== $1 })
    // 留宽：同一档里不变；多一位（10:00）、再多两位（1:00:00）各变宽一次，字都放得下；一路数上来的和直接建在那个
    // 读数上的一样宽
    let width = hud.frame.width
    let reserved = clock.frame.width
    hud.update(.recording(599))
    hud.layoutSubtreeIfNeeded()
    #expect(String(clock.characters) == "9:59" && hud.frame.width == width)
    #expect(clock.frame.width == reserved)
    #expect(try #require(clock.cells.last).frame.maxX <= clock.bounds.width + 1)
    var last = (hud: width, clock: reserved)
    for (seconds, text) in [(600, "10:00"), (3600, "1:00:00")] {
      hud.update(.recording(seconds))
      hud.layoutSubtreeIfNeeded()
      #expect(String(clock.characters) == text)
      #expect(hud.frame.width > last.hud && clock.frame.width > last.clock)
      // HUD 多出来的就是计时多出来的那几位
      #expect(hud.frame.width - last.hud == clock.frame.width - last.clock)
      #expect(try #require(clock.cells.last).frame.maxX <= clock.bounds.width + 1)
      #expect(
        hud.frame.width
          == RecordingHUD(state: .recording(seconds), stopKey: nil, medium: .audio).frame.width)
      last = (hud.frame.width, clock.frame.width)
    }
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
      // ■ 正好落在刚才 ● 的位置上（右边线不动）：换成录制态后的头一小段（系统的双击间隔，最多 1 s）点它不算，免得
      // 双击 ● 刚开始录就停了；过了照常。直接开始的录音 HUD（没有 ● 可点）不挡
      stop.performClick(nil)
      #expect(clicks.isEmpty)
      #expect(hud.ignoresStop(at: .now) && !hud.ignoresStop(at: .now + .seconds(1)))
      // 和直接开始的录音 HUD 一样宽；能暂停的来源 ⏸ 可点
      let direct = RecordingHUD(
        state: .recording(0), stopKey: nil, medium: .audio, pausable: false)
      direct.onClick = { clicks.append($0) }
      #expect(hud.frame.width == direct.frame.width)
      #expect(!direct.ignoresStop(at: .now))
      try #require(direct.button(for: .stop)).performClick(nil)
      #expect(clicks == [.stop])
      // ⏸ 前面换上来的是电平，不用挡了：刚换完就能点
      clicks = []
      hud.setPausable(true)
      #expect(pause.isEnabled && pause.toolTip == "暂停录音")
      pause.performClick(nil)
      #expect(clicks == [.pause])
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
