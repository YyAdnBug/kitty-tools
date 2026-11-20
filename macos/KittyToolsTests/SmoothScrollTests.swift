// 平滑滚动（插件，2026-11-17）：哪些滚轮归它管、修饰键和反向、滚多远、怎么滑（指数逼近、整数像素不丢）、滚轮抖一下不理、
// 停用的 App、别的改滚轮的工具、设置页的橙字。平时的单测不建拦截、不发事件。
// 另有两个按需的实机自检（要测试宿主有「辅助功能」授权；**跑之前先跟用户说一声**）：
// - liveProbe（TEST_RUNNER_KITTY_LIVE_SMOOTH_SCROLL=1）：真的起滚动线程、建拦截（探针模式：真的滚轮原样放过），发几个带探针
//   记号的**合成**滚轮事件，量第一帧多快出来、一共滑多远、主线程卡住半秒时帧还在不在出、停了之后线程退没退。帧也带记号、
//   回到拦截里就吞掉，一个都到不了别的 App。只有拦截没建起来时探针事件才会落到光标下的窗口（滚一下）：先等拦截建好才发
// - record（TEST_RUNNER_KITTY_SMOOTH_SCROLL_RECORD=<秒>）：只听不改的拦截，这几秒里用真鼠标拨滚轮，打印系统给的每个事件的
//   行数 / 像素 / 定点、连续不连续、阶段（拿来定「每行 40 点、一格至少一行」那两个数）；触控板也可以划几下对比

import AppKit
import Foundation
import Synchronization
import Testing

@testable import KittyTools

@MainActor
struct SmoothScrollTests {
  typealias S = ScrollSmoothing

  // MARK: 归不归它管

  @Test func onlyMouseWheelsAreSmoothed() {
    let settings = S.Settings()
    // 连续的、带阶段的不平滑（触控板放过；妙控鼠标只反向，见下一条）
    #expect(S.decide(.init(continuous: true, dy: -3), settings: settings, excluded: false) == .pass)
    #expect(S.decide(.init(phased: true, dy: -3), settings: settings, excluded: false) == .pass)
    // 停用的 App 在前台、没有距离的：放过
    #expect(S.decide(.init(dy: -1), settings: settings, excluded: true) == .pass)
    #expect(S.decide(.init(), settings: settings, excluded: false) == .pass)
    // 鼠标滚轮：一行 40 点
    #expect(
      S.decide(.init(dy: -1), settings: settings, excluded: false)
        == .smooth(dx: 0, dy: -40, flipped: false))
    #expect(
      S.decide(.init(dx: 2), settings: settings, excluded: false)
        == .smooth(dx: 80, dy: 0, flipped: false))
  }

  /// 妙控鼠标：不平滑，只照开关反向；触控板发一模一样的事件，照样放过（2026-11-18 用户反馈 0.10.0「怎么设都不对、鼠标没反向」：
  /// 用户接的是妙控鼠标，原来连续的一律放过）。样本是那天只听的探针在用户的妙控鼠标（蓝牙 0x004C / 0x0269）和 M3 Air 触控板上
  /// 录的原值：两台的事件一样，只有发送设备（字段 87）不同
  @Test func magicMouseIsOnlyReversed() {
    // 妙控鼠标往上滑一下：开始（行数、定点都是 0，像素 1）→ 变化 → 结束 → 惯性
    let samples: [S.Wheel] = [
      .init(continuous: true, phased: true, dy: 0),  // phase=1 d1=0 pt1=1 fx1=0
      .init(continuous: true, phased: true, dy: 1.4),  // phase=2 d1=1 pt1=14 fx1=1.4
      .init(continuous: true, phased: true, dy: 2.3),  // phase=2 d1=2 pt1=23 fx1=2.3
      .init(continuous: true, phased: true, dy: 0),  // phase=4（结束）
      .init(continuous: true, phased: true, dy: 2.6),  // mom=1 d1=2 pt1=26 fx1=2.6
      .init(continuous: true, phased: true, dy: 2.7),  // mom=2 d1=2 pt1=27 fx1=2.7
      .init(continuous: true, phased: true, dy: -2.2),  // 往下：phase=2 d1=-2 pt1=-23 fx1=-2.2
      .init(continuous: true, phased: true, dy: 0.8, dx: -1),  // 斜着划：d2=-1 pt2=-5
    ]
    var reverse = S.Settings()
    reverse.reverseVertical = true
    for var wheel in samples {
      // 触控板（同样的值）：开不开反向都放过
      #expect(S.decide(wheel, settings: reverse, excluded: false) == .pass)
      wheel.magicMouse = true
      // 妙控鼠标：没开反向放过；开了每个事件都反（开头距离是 0 的也反，不然那一个像素倒着走）
      #expect(S.decide(wheel, settings: S.Settings(), excluded: false) == .pass)
      #expect(
        S.decide(wheel, settings: reverse, excluded: false)
          == .flip(vertical: true, horizontal: false))
      // 停用的 App 里不反
      #expect(S.decide(wheel, settings: reverse, excluded: true) == .pass)
    }
    // 修饰键、平滑程度 0 都不影响反向；左右反向管妙控鼠标左右划（它有真的横向，⇧ 不改归哪个开关）
    var both = reverse
    both.reverseHorizontal = true
    both.strength = 0
    let swipe = S.Wheel(continuous: true, phased: true, magicMouse: true, dx: -1, shift: true)
    #expect(
      S.decide(swipe, settings: both, excluded: false) == .flip(vertical: true, horizontal: true))
    var sideways = S.Settings()
    sideways.reverseHorizontal = true
    #expect(
      S.decide(
        .init(continuous: true, magicMouse: true, dy: 2, option: true), settings: sideways,
        excluded: false)
        == .flip(vertical: false, horizontal: true))
    // 合成的事件、拿不到设备的：不当成妙控鼠标
    #expect(!ScrollTap.isMagicMouse(sender: 0))
    #expect(!ScrollTap.isMagicMouse(sender: -1))
  }

  /// 就地反向对连续的（妙控鼠标的惯性那一段，探针原值 d1=2 pt1=27 fx1=2.7）同样三个都反，App 读到的精确距离也反了、阶段不变。
  /// 只建事件、不发
  @Test func negateFlipsContinuousEvent() throws {
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)
    )
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 2)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 27)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.7)
    ScrollTap.negate(event, axis: 1)
    #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -2)
    #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -27)
    #expect(abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) + 2.7) < 0.001)
    let ns = try #require(NSEvent(cgEvent: event))
    #expect(ns.hasPreciseScrollingDeltas)
    #expect(ns.scrollingDeltaY == -27)
    #expect(ns.momentumPhase == .changed)
  }

  /// 一格至少一行（系统加速在慢慢拨时给不到一行）；快拨时系统给的多行照算；滚动距离按百分比乘
  @Test func distanceFollowsSystemLinesAndSpeed() {
    var settings = S.Settings()
    #expect(
      S.decide(.init(dy: -0.3), settings: settings, excluded: false)
        == .smooth(dx: 0, dy: -40, flipped: false))
    #expect(
      S.decide(.init(dy: 2.5), settings: settings, excluded: false)
        == .smooth(dx: 0, dy: 100, flipped: false))
    settings.speed = 200
    #expect(
      S.decide(.init(dy: 1), settings: settings, excluded: false)
        == .smooth(dx: 0, dy: 80, flipped: false))
    // 范围外的（导入、同步来的）夹进 50…300
    settings.speed = 10
    #expect(settings.pointsPerLine == 20)
    settings.speed = 1000
    #expect(settings.pointsPerLine == 120)
    #expect(S.lines(0) == 0 && S.lines(-0.1) == -1 && S.lines(3.5) == 3.5)
  }

  @Test func modifiersAndReverse() {
    var settings = S.Settings()
    // ⌥：不平滑；⌘ / ⌃：交给 App（缩放）
    #expect(S.decide(.init(dy: -1, option: true), settings: settings, excluded: false) == .pass)
    #expect(S.decide(.init(dy: -1, command: true), settings: settings, excluded: false) == .pass)
    // ⇧：上下换成左右，照样平滑；系统已经换成左右的不再换
    #expect(
      S.decide(.init(dy: -1, shift: true), settings: settings, excluded: false)
        == .smooth(dx: -40, dy: 0, flipped: false))
    #expect(
      S.decide(.init(dx: 1, shift: true), settings: settings, excluded: false)
        == .smooth(dx: 40, dy: 0, flipped: false))
    // 反向：平滑的距离反过来；按着修饰键时不平滑，但照样反
    settings.reverseVertical = true
    #expect(
      S.decide(.init(dy: -1), settings: settings, excluded: false)
        == .smooth(dx: 0, dy: 40, flipped: true))
    #expect(
      S.decide(.init(dy: -1, option: true), settings: settings, excluded: false)
        == .flip(vertical: true, horizontal: false))
    #expect(
      S.decide(.init(dx: 1, command: true), settings: settings, excluded: false) == .pass)
    // ⇧ 拨的还是上下那个滚轮：跟着「上下反向」，系统换没换到左右那一轴都一样
    #expect(
      S.decide(.init(dy: -1, shift: true), settings: settings, excluded: false)
        == .smooth(dx: 40, dy: 0, flipped: true))
    #expect(
      S.decide(.init(dx: 1, shift: true), settings: settings, excluded: false)
        == .smooth(dx: -40, dy: 0, flipped: true))
    // 「左右反向」只管横向的滚轮，不管 ⇧ 拨的
    settings.reverseVertical = false
    settings.reverseHorizontal = true
    #expect(
      S.decide(.init(dx: 1, shift: true), settings: settings, excluded: false)
        == .smooth(dx: 40, dy: 0, flipped: false))
    #expect(
      S.decide(.init(dx: 1), settings: settings, excluded: false)
        == .smooth(dx: -40, dy: 0, flipped: true))
    settings.reverseVertical = true
    #expect(
      S.decide(.init(dy: 1, dx: 1, command: true), settings: settings, excluded: false)
        == .flip(vertical: true, horizontal: true))
    // 停用的 App 里也不反
    #expect(S.decide(.init(dy: -1, option: true), settings: settings, excluded: true) == .pass)
  }

  /// issue #37：按着 ⌘ / ⌃ / ⌥ 拨的一格原样放过（缩放交给 App 和系统），滑着的那一段停下（不然一边缩放一边往下滚）。
  /// 修饰键从真的 CGEvent 上取（只建不发）
  @Test func modifierWheelsPassAndHalt() throws {
    let settings = S.Settings()
    func wheel(_ flags: CGEventFlags) throws -> S.Wheel {
      let event = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0,
          wheel3: 0))
      event.flags = flags
      return ScrollTap.wheel(event, isMagicMouse: { _ in false })
    }
    let zooms: [CGEventFlags] = [
      .maskCommand, .maskControl, .maskAlternate, [.maskCommand, .maskShift],
    ]
    for flags in zooms {
      let zoom = try wheel(flags)
      #expect(!zoom.continuous && !zoom.phased && zoom.dy == -1 && zoom.dx == 0)
      let decision = S.decide(zoom, settings: settings, excluded: false)
      #expect(decision == .pass)
      #expect(S.halts(zoom, decision: decision))
    }
    // 不按修饰键的照样平滑、不停；按着 ⇧ 的换成左右、照样平滑
    let plain = try wheel([])
    let smooth = S.decide(plain, settings: settings, excluded: false)
    #expect(smooth == .smooth(dx: 0, dy: -40, flipped: false))
    #expect(!S.halts(plain, decision: smooth))
    #expect(
      S.decide(try wheel(.maskShift), settings: settings, excluded: false)
        == .smooth(dx: -40, dy: 0, flipped: false))
    // 触控板（连续的）一碰就停；没有距离的不连续事件不停
    #expect(S.halts(.init(continuous: true), decision: .pass))
    #expect(!S.halts(.init(), decision: .pass))
  }

  /// issue #37：钉图滚轮缩放，开着平滑滚动（一格变成一串没有手势阶段的像素增量，默认一行 40 点）和不开时一格一样大；
  /// 触控板、妙控鼠标（带阶段）照旧
  @Test func pinZoomMatchesSmoothedWheel() {
    let line = PinPanel.zoomDelta(1, precise: false, phased: false)
    #expect(line == 8)
    #expect(PinPanel.zoomDelta(S.Settings().pointsPerLine, precise: true, phased: false) == line)
    #expect(PinPanel.zoomDelta(40, precise: true, phased: true) == 40)
  }

  /// 平滑程度 0：不平滑，只反向
  @Test func zeroStrengthOnlyReverses() {
    var settings = S.Settings(strength: 0)
    #expect(!settings.smooths)
    #expect(S.decide(.init(dy: -1), settings: settings, excluded: false) == .pass)
    settings.reverseVertical = true
    #expect(
      S.decide(.init(dy: -1), settings: settings, excluded: false)
        == .flip(vertical: true, horizontal: false))
  }

  @Test func strengthMapsToTau() {
    var settings = S.Settings()
    #expect(abs(settings.tau - 0.12) < 1e-9)
    settings.strength = 0
    #expect(abs(settings.tau - 0.04) < 1e-9)
    settings.strength = 100
    #expect(abs(settings.tau - 0.2) < 1e-9)
    settings.strength = 500
    #expect(abs(settings.tau - 0.2) < 1e-9)
  }

  /// 就地反向：行、像素、定点三个都反过来（写行数时系统会重算后两个），NSEvent 读到的也反了；「方向已经翻过」跟着翻。
  /// 只建事件、不发
  @Test func negateFlipsAllThree() throws {
    for axis in [1, 2] {
      let event = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: axis == 1 ? 3 : 0,
          wheel2: axis == 2 ? 3 : 0, wheel3: 0))
      ScrollTap.negate(event, axis: axis)
      let (line, point, fixed): (CGEventField, CGEventField, CGEventField) =
        axis == 1
        ? (
          .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1,
          .scrollWheelEventFixedPtDeltaAxis1
        )
        : (
          .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2,
          .scrollWheelEventFixedPtDeltaAxis2
        )
      #expect(event.getIntegerValueField(line) == -3)
      #expect(event.getIntegerValueField(point) == -30)
      #expect(event.getDoubleValueField(fixed) == -3)
      let ns = try #require(NSEvent(cgEvent: event))
      #expect((axis == 1 ? ns.scrollingDeltaY : ns.scrollingDeltaX) == -3)
    }
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0
      ))
    #expect(NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == false)
    ScrollTap.toggleInverted(event)
    #expect(NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true)
    ScrollTap.toggleInverted(event)
    #expect(NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == false)
  }

  // MARK: 滑

  /// 放完的帧加起来一点不差、每帧同向、越来越慢，一秒内滑完；默认平滑程度九成五在 0.4 秒内
  @Test func motionDeliversEveryPixel() {
    let tau = S.Settings().tau
    for distance in [1.0, 7.3, 40, 120, -333.7, 4000] {
      var motion = S.Motion()
      motion.add(dx: 0, dy: distance)
      var sent = 0
      var frames: [Int] = []
      while !motion.isIdle, frames.count < 1000 {
        let step = motion.step(dt: 1.0 / 120, tau: tau)
        #expect(step.dx == 0)
        sent += step.dy
        frames.append(step.dy)
      }
      #expect(sent == Int(distance.rounded()))
      #expect(frames.allSatisfy { $0 == 0 || ($0 > 0) == (distance > 0) })
      #expect(Double(frames.count) / 120 < 1.2, "\(distance)：\(frames.count) 帧")
    }
    var motion = S.Motion()
    motion.add(dx: 0, dy: 400)
    var sent = 0
    for _ in 0..<Int(0.4 * 120) { sent += motion.step(dt: 1.0 / 120, tau: tau).dy }
    #expect(sent >= 380)
  }

  /// 同向接着拨：叠上去；往回拨：没滚完的扔掉、马上往回走
  @Test func motionAccumulatesAndReverses() {
    var motion = S.Motion()
    motion.add(dx: 0, dy: 40)
    motion.add(dx: 0, dy: 40)
    #expect(motion.remainingY == 80)
    _ = motion.step(dt: 1.0 / 60, tau: 0.12)
    #expect(motion.remainingY > 0 && motion.remainingY < 80)
    motion.add(dx: 0, dy: -40)
    #expect(motion.remainingY == -40)
    var sent = 0
    while !motion.isIdle { sent += motion.step(dt: 1.0 / 60, tau: 0.12).dy }
    #expect(sent == -40)
    // 两个轴各管各的
    motion.add(dx: 30, dy: -10)
    motion.add(dx: -5, dy: 0)
    #expect(motion.remainingX == -5 && motion.remainingY == -10)
  }

  /// 线程被耽搁了很久：这一帧也只按 maxStep 放，不一下子跳到底
  @Test func longGapsAreCapped() {
    var motion = S.Motion()
    motion.add(dx: 0, dy: 1000)
    let step = motion.step(dt: 5, tau: 0.12)
    #expect(step.dy > 0 && step.dy < 400)
    #expect(motion.step(dt: -1, tau: 0.12).dy == 0)
  }

  /// 一串里夹的单独一格反向不理；连着两格反向才认（只丢第一格）；隔得久的反向马上认
  @Test func bounceIsIgnored() {
    var bounce = S.Bounce()
    // （左右, 上下, 时刻）→ 认不认
    let steps: [(Double, Double, Double, Bool)] = [
      (0, -40, 0, true), (0, -40, 0.03, true),
      // 一串里夹的单独一格反向
      (0, 40, 0.04, false), (0, -40, 0.06, true),
      // 真往回拨：第一格丢，第二格认，之后照常
      (0, 40, 0.08, false), (0, 40, 0.1, true), (0, 40, 0.12, true),
      // 停了一会儿再往回：马上认
      (0, -40, 0.5, true),
      // 换到另一个轴不算反向；左右之间也认抖动
      (40, 0, 0.51, true), (-40, 0, 0.52, false),
    ]
    for (dx, dy, time, expected) in steps {
      let accepted = bounce.accept(dx: dx, dy: dy, time: time)
      #expect(accepted == expected, "时刻 \(time)")
    }
  }

  // MARK: 停用的 App、别的工具

  @Test func excludedApps() {
    #expect(S.isGame(category: "public.app-category.games"))
    #expect(S.isGame(category: "public.app-category.role-playing-games"))
    #expect(!S.isGame(category: "public.app-category.developer-tools"))
    #expect(!S.isGame(category: "games") && !S.isGame(category: nil))
    #expect(S.isExcluded(app: "com.example.a", category: nil, list: ["com.example.a"]))
    #expect(S.isExcluded(app: "com.vmware.fusion", category: nil, list: []))
    #expect(S.isExcluded(app: nil, category: "public.app-category.action-games", list: []))
    #expect(
      !S.isExcluded(app: "com.apple.Safari", category: "public.app-category.productivity", list: [])
    )
  }

  @Test func otherToolsAreNamed() {
    #expect(
      S.runningOtherTools([
        ("com.caldis.Mos", "Mos"), ("com.apple.Safari", "Safari"), (nil, nil),
        ("com.pilotmoon.scroll-reverser", nil),
      ]) == ["Mos", "com.pilotmoon.scroll-reverser"])
    #expect(SmoothScrollTab.warning(failed: false, others: []) == nil)
    let both = SmoothScrollTab.warning(failed: true, others: ["A", "B"]) ?? ""
    #expect(both.contains("关掉再打开"))
    #expect(both.contains("「A」「B」也在处理鼠标滚轮"))
  }

  /// 偏好读成设置：没存过是默认值（临时偏好域，不碰用户的）
  @Test func settingsFromDefaults() throws {
    let suite = "smooth-scroll-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(SmoothScroll.settings(defaults) == S.Settings())
    defaults.set(80, forKey: Prefs.smoothScrollStrength)
    defaults.set(150, forKey: Prefs.smoothScrollSpeed)
    defaults.set(true, forKey: Prefs.smoothScrollReverseVertical)
    #expect(
      SmoothScroll.settings(defaults)
        == S.Settings(strength: 80, speed: 150, reverseVertical: true))
  }

  /// 「滚动」页脚的恢复默认：只管两条滑块，回到的正是滚动用的默认值，反向开关不动（临时偏好域）
  @Test func resetRestoresOnlySliders() throws {
    #expect(SmoothScrollTab.resetKeys == [Prefs.smoothScrollStrength, Prefs.smoothScrollSpeed])
    #expect(Prefs.defaults[Prefs.smoothScrollStrength] as? Int == S.Settings().strength)
    #expect(Prefs.defaults[Prefs.smoothScrollSpeed] as? Int == S.Settings().speed)
    let suite = "smooth-scroll-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(80, forKey: Prefs.smoothScrollStrength)
    defaults.set(150, forKey: Prefs.smoothScrollSpeed)
    defaults.set(true, forKey: Prefs.smoothScrollReverseVertical)
    #expect(SettingsReset.differs(SmoothScrollTab.resetKeys, in: defaults))
    _ = SettingsReset.reset(SmoothScrollTab.resetKeys, in: defaults, domain: suite)
    #expect(SmoothScroll.settings(defaults) == S.Settings(reverseVertical: true))
  }

  // MARK: 按需的实机自检

  /// 见文件头。合成的探针滚轮：3 行往下，应滑出 120 点
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_SMOOTH_SCROLL"] == "1")
  )
  func liveProbe() async throws {
    try #require(Permissions.isAccessibilityTrusted, "测试宿主没有「辅助功能」授权")
    let suite = "smooth-scroll-live-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: Feature.smoothScroll.prefsKey)
    let scroll = SmoothScroll(defaults: defaults)
    scroll.shared.state.withLock { $0.probe = true }
    scroll.apply()
    defer {
      defaults.set(false, forKey: Feature.smoothScroll.prefsKey)
      scroll.apply()
    }
    #expect(scroll.status == .running)
    for _ in 0..<40 where !scroll.shared.isListening {
      try await Task.sleep(for: .milliseconds(50))
    }
    let listening = scroll.shared.isListening
    try #require(listening, "拦截没建起来")

    // 一格：第一帧多快、一共多远、多久滑完
    let posted = ProcessInfo.processInfo.systemUptime
    try Self.postProbe(lines: -3)
    try await Task.sleep(for: .milliseconds(900))
    let frames = scroll.shared.state.withLock { state in
      defer { state.probeFrames = [] }
      return state.probeFrames
    }
    let first = try #require(frames.first, "一帧都没收到")
    let total = frames.reduce(0) { $0 + $1.dy }
    let span = (frames.last?.time ?? first.time) - first.time
    print(
      "smooth-scroll-probe 第一帧 \(Int((first.time - posted) * 1000)) ms，\(frames.count) 帧，"
        + "共 \(total) 点，滑了 \(Int(span * 1000)) ms")
    #expect(total == -120)
    #expect(frames.allSatisfy { $0.dy <= 0 && $0.dx == 0 })
    #expect(first.time - posted < 0.05)
    #expect(frames.count > 10 && span < 0.8)

    // 主线程卡住半秒：帧照样出（拦截和出帧都在滚动线程上）
    try Self.postProbe(lines: 3)
    let blockStart = ProcessInfo.processInfo.systemUptime
    usleep(500_000)
    let blockEnd = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(for: .milliseconds(600))
    let during = scroll.shared.state.withLock { state in
      state.probeFrames.filter { $0.time > blockStart && $0.time < blockEnd }
    }
    print("smooth-scroll-probe 主线程卡住的半秒里出了 \(during.count) 帧")
    let back = scroll.shared.state.withLock { $0.probeFrames.reduce(0) { $0 + $1.dy } }
    #expect(during.count > 10)
    #expect(back == 120)

    // 停：线程退出、拦截撤掉
    defaults.set(false, forKey: Feature.smoothScroll.prefsKey)
    scroll.apply()
    for _ in 0..<40 where scroll.shared.isListening {
      try await Task.sleep(for: .milliseconds(50))
    }
    let stillListening = scroll.shared.isListening
    #expect(!stillListening)
    #expect(scroll.status == .off)
  }

  /// 带探针记号的合成滚轮（行单位：不连续，同鼠标滚轮）
  private static func postProbe(lines: Int32) throws {
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
        wheel3: 0))
    // 不带修饰键（系统修饰键状态卡着时新建的事件会带上：带 ⌘ 的不吞、会落到光标下的窗口去缩放）
    event.flags = []
    event.setIntegerValueField(.eventSourceUserData, value: ScrollTap.probeMarker)
    event.post(tap: .cgSessionEventTap)
  }

  /// 见文件头：只听不改，打印真滚轮给的值
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["KITTY_SMOOTH_SCROLL_RECORD"] != nil))
  func record() async throws {
    let seconds =
      Int(ProcessInfo.processInfo.environment["KITTY_SMOOTH_SCROLL_RECORD"] ?? "")
      ?? 15
    let recorder = Recorder()
    let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
      eventsOfInterest: CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue),
      callback: { _, type, event, refcon in
        guard type == .scrollWheel, let refcon else { return Unmanaged.passUnretained(event) }
        let field = { (name: CGEventField) in event.getIntegerValueField(name) }
        let line =
          "连续 \(field(.scrollWheelEventIsContinuous)) 阶段 \(field(.scrollWheelEventScrollPhase))/"
          + "\(field(.scrollWheelEventMomentumPhase)) 行 \(field(.scrollWheelEventDeltaAxis1)) "
          + "定点 \(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)) "
          + "像素 \(field(.scrollWheelEventPointDeltaAxis1)) 左右行 \(field(.scrollWheelEventDeltaAxis2)) "
          + "时刻 \(event.timestamp / 1_000_000) ms"
        Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue().lines.withLock {
          $0.append(line)
        }
        return Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(recorder).toOpaque())
    let port = try #require(tap, "建不起只听的拦截")
    let source = CFMachPortCreateRunLoopSource(nil, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    print("smooth-scroll-record 开始：\(seconds) 秒里拨鼠标滚轮（慢拨几格、快拨一串），也可以在触控板上划几下")
    try await Task.sleep(for: .seconds(seconds))
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    CFMachPortInvalidate(port)
    for line in recorder.lines.withLock({ $0 }) { print("smooth-scroll-record \(line)") }
    withExtendedLifetime(recorder) {}
  }

  /// record() 的拦截回调往这里记（回调拿到的是它的指针）
  private final class Recorder: Sendable {
    let lines = Mutex<[String]>([])
  }
}
