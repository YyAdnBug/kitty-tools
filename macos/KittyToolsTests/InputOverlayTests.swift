// 录屏的点按圈（手测反馈第 1 批，InputOverlay）：全局坐标 → 窗口内坐标、左 / 右键的圈形状不同、点在本 App 哪些窗口上不画、
// 窗口不进截图冻结帧也不在录屏白名单里（层级高过菜单和截图遮罩，窗口号由 ScreenRecorder 自己并进例外）、按下 / 拖动 /
// 松开各自留下几个图层（用完移除、连点互不吞、选区外按下再拖进来圈跟着）、收起后窗口放掉。除了最后一条，窗口只建不显示
// （不装鼠标监听）；动画的快慢（最短显示 0.2 s、涟漪到点才出现）屏外测不到，真机看（PLAN §12 第 53 条）；
// 真录进画面在按需实录自检 RecordingProbeTests.inputOverlayTake，样子在 ScreenshotSnapshotTests.renderInputOverlay。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct InputOverlayTests {
  static let frame = CGRect(x: 100, y: 200, width: 640, height: 360)

  /// 全局坐标 → 窗口内坐标（原点左下）；选区外面的照算（圈被窗口裁掉）；副屏的负坐标也对
  @Test func localPointInsideAndOutsideTheRecordedRegion() {
    let local = { InputOverlay.local($0, in: Self.frame) }
    #expect(local(CGPoint(x: 100, y: 200)) == .zero)
    #expect(local(CGPoint(x: 420, y: 380)) == CGPoint(x: 320, y: 180))
    #expect(local(CGPoint(x: 740, y: 560)) == CGPoint(x: 640, y: 360))
    // 选区外 10 pt：圆盘还露一半
    #expect(local(CGPoint(x: 90, y: 300)) == CGPoint(x: -10, y: 100))
    // 选区外 100 pt：整个圈都在窗口外面
    #expect(local(CGPoint(x: 0, y: 300)) == CGPoint(x: -100, y: 100))
    let side = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
    #expect(InputOverlay.local(CGPoint(x: -1000, y: 100), in: side) == CGPoint(x: 920, y: 300))
  }

  /// 左键实心圆盘、右键和其它键空心环：形状分开（强调色选石墨时颜色帮不上忙），空心环的线更粗
  @Test func leftIsDiscOthersAreRings() throws {
    #expect(InputOverlay.look(button: 0) == .disc)
    #expect([1, 2, 3, 4].map(InputOverlay.look) == [.ring, .ring, .ring, .ring])
    /// 圈里画强调色的那一层（最上面）
    func ring(_ look: InputOverlay.Look) throws -> CAShapeLayer {
      try #require(InputOverlay.mark(look, scale: 2).sublayers?.last as? CAShapeLayer)
    }
    let disc = try ring(.disc)
    let hollow = try ring(.ring)
    #expect(disc.fillColor != nil && hollow.fillColor == nil)
    #expect(disc.lineWidth == 2 && hollow.lineWidth == 3)
    #expect(disc.strokeColor == Style.Shot.accent.cgColor)
    // 圈比光标大得多（系统的点按圈约 20 pt）
    #expect(InputOverlay.mark(.disc, scale: 2).bounds.size == CGSize(width: 44, height: 44))
  }

  /// 点在本 App 自己的窗口上：只在录屏白名单里的（会录进画面：设置窗这类普通 NSWindow、面板、钉图）画；录不进去的不画，
  /// 不按层级猜——浮动层级的普通面板（长截图面板这类不在白名单里的）、状态栏层级的（录制 HUD、常驻缩略图）、
  /// 没有窗口号的都不画，不然点它们会在画面里凭空留个圈。窗口只建不显示
  @Test func clicksOnOwnWindowsShowOnlyOnRecordedOnes() {
    func window(_ type: NSWindow.Type, level: NSWindow.Level) -> NSWindow {
      let made = type.init(
        contentRect: CGRect(x: -20000, y: -20000, width: 80, height: 60), styleMask: [.borderless],
        backing: .buffered, defer: false)
      made.isReleasedWhenClosed = false
      made.level = level
      return made
    }
    let recorded = window(NSWindow.self, level: .normal)
    let floating = window(NSPanel.self, level: .floating)
    let status = window(NSWindow.self, level: .statusBar)
    #expect(InputOverlay.showsClick(onOwnWindow: recorded.windowNumber))
    #expect(!InputOverlay.showsClick(onOwnWindow: floating.windowNumber))
    #expect(!InputOverlay.showsClick(onOwnWindow: status.windowNumber))
    #expect(!InputOverlay.showsClick(onOwnWindow: 0))
    #expect(!InputOverlay.showsClick(onOwnWindow: -1))
  }

  /// 窗口：普通 NSPanel（不子类化）、不接鼠标、永不当 key、不进旁白、没有阴影；层级高过菜单和截图遮罩（popUpMenu + 1）；
  /// 截图冻结帧按层级不收它，录屏白名单也不列它（窗口号由 ScreenRecorder 并进例外）
  @Test func panelStaysOutOfTheWayAndOutOfFreezeFrames() {
    let overlay = InputOverlay(frame: Self.frame)
    defer { overlay.close() }
    let panel = overlay.panel
    #expect(type(of: panel) == NSPanel.self)
    #expect(panel.frame == Self.frame && !panel.isVisible)
    #expect(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
    #expect(!panel.hasShadow && !panel.isOpaque && !panel.isAccessibilityElement())
    #expect(panel.level.rawValue > NSWindow.Level.popUpMenu.rawValue + 1)
    #expect(
      panel.collectionBehavior.isSuperset(of: [
        .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary,
      ]))
    #expect(overlay.windowID != nil)
    let own = [
      ScreenCapture.OwnWindow(
        id: 7, className: String(describing: type(of: panel)), level: panel.level.rawValue,
        isVisible: true, alpha: 1)
    ]
    #expect(ScreenCapture.keptOwnWindows(own).isEmpty)
    #expect(ScreenCapture.recordedOwnWindows(own).isEmpty)
  }

  /// 按下一个圈、拖动跟着走（直接设位置）、松开移除；同一个键没等到松开又按下（松开被别的 App 吞了）旧的先收掉；
  /// 左右键各管各的；选区外很远的按下也建（看不见），按住拖进选区时圈跟着进来。都走不带动画的入口（终态）
  @Test func pressMoveReleaseKeepNoStaleLayers() throws {
    let overlay = InputOverlay(frame: Self.frame)
    defer { overlay.close() }
    let canvas = try #require(overlay.panel.contentView?.layer)
    #expect(overlay.markCount == 0 && canvas.contents == nil)
    overlay.press(0, at: CGPoint(x: 420, y: 380), animated: false)
    #expect(overlay.markCount == 1)
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 320, y: 180))
    overlay.move(0, to: CGPoint(x: 500, y: 300))
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 400, y: 100))
    // 别的键的拖动不带着它走
    overlay.move(1, to: CGPoint(x: 120, y: 220))
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 400, y: 100))
    overlay.press(1, at: CGPoint(x: 200, y: 260), animated: false)
    #expect(overlay.markCount == 2)
    overlay.press(0, at: CGPoint(x: 300, y: 300), animated: false)
    #expect(overlay.markCount == 2)
    overlay.release(0, animated: false)
    overlay.release(0, animated: false)  // 多来一次松开：没有可收的
    #expect(overlay.markCount == 1)
    overlay.release(1, animated: false)
    #expect(overlay.markCount == 0)
    // 选区外 200 pt 按下（比如按住别的窗口里的一个文件）再拖进选区、松开
    overlay.press(0, at: CGPoint(x: 100, y: 0), animated: false)
    #expect(overlay.markCount == 1)
    overlay.move(0, to: CGPoint(x: 420, y: 380))
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 320, y: 180))
    overlay.release(0, animated: false)
    #expect(overlay.markCount == 0)
  }

  /// 带动画的松开：不当场移除（圆盘留着淡出，另加一圈涟漪；减弱动态效果没有涟漪），连点三下互不吞、各放各的，
  /// 放完都移除（不累积）
  @Test func animatedReleaseRemovesLayersWhenDone() async throws {
    let overlay = InputOverlay(frame: Self.frame)
    defer { overlay.close() }
    for index in 0..<3 {
      overlay.press(0, at: CGPoint(x: 300 + CGFloat(index) * 10, y: 300))
      overlay.release(0)
    }
    #expect(overlay.markCount == (Style.reduceMotion ? 3 : 6))
    for _ in 0..<60 where overlay.markCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(overlay.markCount == 0)
  }

  /// 收起：监听卸掉、图层清掉、窗口收起；会话放手后覆盖层和它的窗口都放掉（不然每录一次漏一个整屏窗口）。
  /// 这一条真的露出来再收（监听和窗口列表才是会留住它的地方）：窗口全透明、不接鼠标、当不了 key，露出来的这一瞬看不见
  @Test func closeReleasesOverlayAndWindow() {
    weak var overlay: InputOverlay?
    weak var panel: NSPanel?
    autoreleasepool {
      let made = InputOverlay(frame: Self.frame)
      made.present()
      #expect(made.panel.isVisible)
      made.press(0, at: CGPoint(x: 420, y: 380), animated: false)
      overlay = made
      panel = made.panel
      made.close()
      #expect(made.markCount == 0 && !made.panel.isVisible)
    }
    #expect(overlay == nil && panel == nil)
  }
}
