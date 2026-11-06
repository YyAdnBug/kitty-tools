// 长截图自动滚动的速度（2026-11-04 用户反馈太快）和剪贴板面板、启动器的「面板位置」：
// 三档的速度、认不出的值按标准、匀速滚动（2026-11-05）的每秒发多少、按实测位移校准倍率、每一帧发几点和零头、
// 比上次接上的那一帧最多领先半个选区高（2026-11-06 大选区反复对不上）；长截图面板上的速度那一行（屏外量布局、模拟点一下：
// 26 起的玻璃屏外画不出来，截图自检看不到它）；面板位置三种怎么摆、跟随鼠标时在光标右下、放不下翻到另一侧。
// 只读临时偏好域，不碰用户偏好。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct ScrollSpeedTests {
  @Test func speedsAndDefault() throws {
    #expect(Prefs.ScrollSpeed.slow.heightsPerSecond == 0.3)
    #expect(Prefs.ScrollSpeed.normal.heightsPerSecond == 0.6)
    #expect(Prefs.ScrollSpeed.fast.heightsPerSecond == 1.2)
    #expect(Prefs.ScrollSpeed.allCases.map(\.title) == ["慢", "标准", "快"])
    let defaults = try #require(UserDefaults(suiteName: "ScrollSpeedTests"))
    defer { defaults.removePersistentDomain(forName: "ScrollSpeedTests") }
    #expect(Prefs.ScrollSpeed.current(defaults) == .normal)
    defaults.set("turbo", forKey: Prefs.scrollCaptureSpeed)
    #expect(Prefs.ScrollSpeed.current(defaults) == .normal)
    defaults.set("slow", forKey: Prefs.scrollCaptureSpeed)
    #expect(Prefs.ScrollSpeed.current(defaults) == .slow)
  }

  @Test func velocityFromSpeedAndGain() {
    // 选区 500 点高、2 倍屏，1 点滚轮滚 2 像素：标准档每秒 0.6 × 500 × 2 = 600 像素 = 300 点
    #expect(ScrollCapture.velocity(speed: .normal, height: 500, scale: 2, gain: 2) == 300)
    // 这个窗口 1 点滚 4 像素：发一半就够
    #expect(ScrollCapture.velocity(speed: .normal, height: 500, scale: 2, gain: 4) == 150)
    // 快是标准的两倍、慢是一半
    #expect(ScrollCapture.velocity(speed: .fast, height: 500, scale: 2, gain: 2) == 600)
    #expect(ScrollCapture.velocity(speed: .slow, height: 500, scale: 2, gain: 2) == 150)
    // 上下限：最少每秒 10 点，最多每秒三个选区高
    #expect(ScrollCapture.velocity(speed: .slow, height: 20, scale: 1, gain: 8) == 10)
    #expect(ScrollCapture.velocity(speed: .fast, height: 500, scale: 2, gain: 0.01) == 1500)
  }

  @Test func calibrationConvergesAndIgnoresNoise() {
    // 先按屏幕倍率猜 2，实际 1 点滚 3 像素：几段之后贴近 3
    var gain: CGFloat = 2
    for _ in 0..<8 { gain = ScrollCapture.calibrated(gain, shift: 300, sent: 100, scale: 2) }
    #expect(abs(gain - 3) < 0.01)
    // 发得太少、画面往回走：不动
    #expect(ScrollCapture.calibrated(2, shift: 30, sent: 3, scale: 2) == 2)
    #expect(ScrollCapture.calibrated(2, shift: -50, sent: 40, scale: 2) == 2)
    // 夹在屏幕倍率的 1/4 到 8 倍
    #expect(ScrollCapture.calibrated(0.5, shift: 1, sent: 1000, scale: 2) == 0.5)
    #expect(ScrollCapture.calibrated(16, shift: 100_000, sent: 4, scale: 2) == 16)
  }

  @Test func tickPointsKeepTheRemainder() {
    // 每秒 300 点、这一帧 25 ms：7.5 点 → 发 7 点，留 0.5 到下一帧
    let first = ScrollCapture.tickPoints(velocity: 300, seconds: 0.025, carry: 0)
    #expect(first.points == 7)
    #expect(abs(first.carry - 0.5) < 0.001)
    #expect(ScrollCapture.tickPoints(velocity: 300, seconds: 0.025, carry: first.carry).points == 8)
    // 每秒 100 点：一帧不到 2 点，零头留着，一秒下来一共发 99–100 点、每帧 1 或 2 点（匀速，不攒成一大步）
    var carry: CGFloat = 0
    var total: CGFloat = 0
    for _ in 0..<60 {
      let next = ScrollCapture.tickPoints(velocity: 100, seconds: 1.0 / 60, carry: carry)
      #expect(next.points == 1 || next.points == 2)
      #expect(next.carry >= 0 && next.carry < 1)
      carry = next.carry
      total += next.points
    }
    #expect(total >= 99 && total <= 100)
    // 卡了一秒才来下一帧：只按 50 ms 算，不猛冲一大段
    #expect(ScrollCapture.tickPoints(velocity: 300, seconds: 1, carry: 0).points == 15)
    #expect(ScrollCapture.tickPoints(velocity: 300, seconds: -1, carry: 0.5).points == 0)
  }

  @Test func leadIsCappedAtHalfARegion() {
    // 选区 1000 点高、2 倍屏、1 点滚 2 像素：最多领先 500 点（半个选区高 = 1000 像素）
    #expect(ScrollCapture.room(lead: 0, height: 1000, scale: 2, gain: 2) == 500)
    #expect(ScrollCapture.room(lead: 480, height: 1000, scale: 2, gain: 2) == 20)
    #expect(ScrollCapture.room(lead: 700, height: 1000, scale: 2, gain: 2) == 0)
    // 1 点滚 4 像素：发一半就到半个选区高；往回退过（lead 是负的）可以多发
    #expect(ScrollCapture.room(lead: 0, height: 1000, scale: 2, gain: 4) == 250)
    #expect(ScrollCapture.room(lead: -100, height: 1000, scale: 2, gain: 2) == 600)
    // 每一帧最多发 room 点：发不完的扔掉、零头清零，到顶了一点不发
    let capped = ScrollCapture.tickPoints(velocity: 600, seconds: 0.025, carry: 0.5, room: 9.7)
    #expect(capped.points == 9)
    #expect(capped.carry == 0)
    #expect(ScrollCapture.tickPoints(velocity: 600, seconds: 0.025, carry: 0, room: 0).points == 0)
    // 没到顶：和不封顶一样，零头照留
    let free = ScrollCapture.tickPoints(velocity: 300, seconds: 0.025, carry: 0, room: 100)
    #expect(free.points == 7 && abs(free.carry - 0.5) < 0.001)
    // 整屏大选区、快档、一轮抓帧拼接要 2 秒（Debug 构建实测）：不封顶的话两帧之间滚出两个多选区高；
    // 封顶后不管等多久，两帧之间最多半个选区高
    let height: CGFloat = 1050
    let velocity = ScrollCapture.velocity(speed: .fast, height: height, scale: 2, gain: 2)
    var lead: CGFloat = 0
    var carry: CGFloat = 0
    for _ in 0..<120 {
      let next = ScrollCapture.tickPoints(
        velocity: velocity, seconds: 1.0 / 60, carry: carry,
        room: ScrollCapture.room(lead: lead, height: height, scale: 2, gain: 2))
      lead += next.points
      carry = next.carry
    }
    #expect(velocity * 2 > height * 2)
    #expect(lead <= height * ScrollCapture.maxLead)
    #expect(lead >= height * ScrollCapture.maxLead - 1)
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
