// 长截图自动滚动的速度（2026-11-04 用户反馈太快）和剪贴板面板、启动器的「面板位置」：
// 三档的比例、认不出的值按标准、步长按实测位移收敛到目标、上下限；长截图面板上的速度那一行（屏外量布局、模拟点一下：
// 26 起的玻璃屏外画不出来，截图自检看不到它）；面板位置三种怎么摆、跟随鼠标时在光标右下、放不下翻到另一侧。
// 只读临时偏好域，不碰用户偏好。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct ScrollSpeedTests {
  @Test func speedsAndDefault() throws {
    #expect(Prefs.ScrollSpeed.slow.fraction == 0.1)
    #expect(Prefs.ScrollSpeed.normal.fraction == 0.2)
    #expect(Prefs.ScrollSpeed.fast.fraction == 0.4)  // 以前唯一的速度
    #expect(Prefs.ScrollSpeed.allCases.map(\.title) == ["慢", "标准", "快"])
    let defaults = try #require(UserDefaults(suiteName: "ScrollSpeedTests"))
    defer { defaults.removePersistentDomain(forName: "ScrollSpeedTests") }
    #expect(Prefs.ScrollSpeed.current(defaults) == .normal)
    defaults.set("turbo", forKey: Prefs.scrollCaptureSpeed)
    #expect(Prefs.ScrollSpeed.current(defaults) == .normal)
    defaults.set("slow", forKey: Prefs.scrollCaptureSpeed)
    #expect(Prefs.ScrollSpeed.current(defaults) == .slow)
  }

  @Test func stepConvergesToTarget() {
    // 选区 500 点高、2 倍屏；这个窗口每发 1 点滚 3 像素（滚轮加速）。标准档每步要滚出 500 × 2 × 0.2 = 200 像素
    let (height, scale, gain): (CGFloat, CGFloat, CGFloat) = (500, 2, 3)
    var step = height * Prefs.ScrollSpeed.normal.fraction
    for _ in 0..<5 {
      step = ScrollCapture.nextStep(
        step, shift: step * gain, height: height, scale: scale, fraction: 0.2)
    }
    #expect(abs(step * gain - 200) < 0.5)
    // 往上滚时位移是负的，一样按绝对值算
    #expect(
      ScrollCapture.nextStep(100, shift: -300, height: height, scale: scale, fraction: 0.2)
        == ScrollCapture.nextStep(100, shift: 300, height: height, scale: scale, fraction: 0.2))
  }

  @Test func stepClamps() {
    // 慢档、窗口滚得特别多：不少于 20 点
    #expect(ScrollCapture.nextStep(30, shift: 5000, height: 400, scale: 2, fraction: 0.1) == 20)
    // 窗口几乎不动：不多于选区高度的 80%
    #expect(ScrollCapture.nextStep(100, shift: 1, height: 400, scale: 2, fraction: 0.4) == 320)
    // 没量到位移（0）：步长不变，不除以 0
    #expect(ScrollCapture.nextStep(77, shift: 0, height: 400, scale: 2, fraction: 0.2) == 77)
  }

  @Test func hudSpeedRow() throws {
    let hud = ScrollCaptureHUD()
    hud.frame = CGRect(x: 0, y: 0, width: ScrollCaptureHUD.width, height: 260)
    hud.layoutSubtreeIfNeeded()
    let control = try #require(Self.first(NSSegmentedControl.self, in: hud))
    #expect(control.segmentCount == 3)
    #expect((0..<3).map { control.label(forSegment: $0) } == ["慢", "标准", "快"])
    #expect(control.selectedSegment == 1)
    #expect(control.accessibilityLabel() == "自动滚动速度")
    hud.speed = .fast
    #expect(control.selectedSegment == 2)
    // 点「慢」：面板记下、告诉会话
    var actions: [ScrollCaptureHUD.Item] = []
    hud.onAction = { actions.append($0) }
    control.selectedSegment = 0
    control.sendAction(control.action, to: control.target)
    #expect(actions == [.speed(.slow)])
    #expect(hud.speed == .slow)
    // 和内容一样宽，在按钮行（✓ 那颗钮）上面、状态下面；不抢第一响应者、第一下点击就算
    let width = ScrollCaptureHUD.width - 20
    #expect(abs(control.frame.width - width) < 0.5)
    let copy = try #require(Self.first(NSButton.self, in: hud) { $0.toolTip == "拷贝（↩）" })
    let below = copy.convert(copy.bounds, to: hud)
    let row = control.convert(control.bounds, to: hud)
    #expect(row.minY > below.maxY)
    #expect(control.refusesFirstResponder)
    #expect(control.acceptsFirstMouse(for: nil))
  }

  private static func first<T: NSView>(
    _ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }
  ) -> T? {
    if let view = view as? T, match(view) { return view }
    for child in view.subviews {
      if let found = first(type, in: child, where: match) { return found }
    }
    return nil
  }

  @Test func panelPositions() {
    let mouse = NSPoint(x: 300, y: 700)
    // 屏幕上方（默认、认不出的值也是）
    for value in ["top", nil, "nonsense"] {
      let place = OverlayPanel.placement(value, hasUserFrame: true, mouse: mouse)
      #expect(place.anchor == nil && place.atTop)
    }
    // 跟随鼠标：带着鼠标位置
    let follow = OverlayPanel.placement("mouse", hasUserFrame: false, mouse: mouse)
    #expect(follow.anchor == mouse && !follow.atTop)
    // 上次位置：拖过就回到那里（不带锚点、不放上方），没拖过放上方
    let dragged = OverlayPanel.placement("last", hasUserFrame: true, mouse: mouse)
    #expect(dragged.anchor == nil && !dragged.atTop)
    let fresh = OverlayPanel.placement("last", hasUserFrame: false, mouse: mouse)
    #expect(fresh.anchor == nil && fresh.atTop)
  }

  @Test func clipboardFollowsMouse() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let size = NSSize(width: 720, height: 480)
    // 屏幕中间：左上角在光标右下 12 点
    let middle = OverlayPanel.frame(near: NSPoint(x: 300, y: 700), size: size, in: visible)
    #expect(middle.minX == 312)
    #expect(middle.maxY == 688)
    // 右下角：翻到光标左上方，整块在可见区里
    let corner = OverlayPanel.frame(near: NSPoint(x: 1400, y: 60), size: size, in: visible)
    #expect(corner.maxX == 1388)
    #expect(corner.minY == 72)
    #expect(visible.contains(corner))
  }
}
