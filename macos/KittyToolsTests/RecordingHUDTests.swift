// 录制 HUD（录屏第 2 批，RecordingHUD）：摆位（选区外 = 录制条的位置、整屏 = 可见区底部居中离底 24、拖过的按拖到的地方）、
// 放弃要点两下的时序（纯状态）、窗口不进截图冻结帧和录制白名单（状态栏层级的普通 NSPanel，永不当 key）、按钮在两种状态下
// 交回什么。HUD 的窗口只建不显示（不弹到屏幕上、不抢键盘）。

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
}
