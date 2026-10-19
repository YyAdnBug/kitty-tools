// 触控板捏合识别器、系统手势开关读法、触发角几何的单测（第八族，SPEC §5.6 §5.7 / §10）：喂造好的帧序列，
// 不注册回调、不读真触点、不改系统设置。

import CoreGraphics
import Foundation
import Testing

@testable import KittyTools

struct LaunchpadPinchTests {
  private func frame(_ time: Double, _ points: [(Double, Double)], state: Int32 = 4) -> TouchFrame {
    TouchFrame(
      time: time,
      touches: points.enumerated().map { index, point in
        TouchPoint(id: Int32(index), x: point.0, y: point.1, state: state)
      })
  }

  /// 四根手指围着 (cx, cy)、半径 r
  private func ring(_ r: Double, x cx: Double = 0.5, y cy: Double = 0.5) -> [(Double, Double)] {
    [(cx - r, cy), (cx, cy - r), (cx + r, cy), (cx, cy + r)]
  }

  /// 四指收拢：缩过 4% 开始跟、进度按满格比例算、抬手（手指一根根离开）= 松手，带松手前的进度和速度；抬完再来一次照样认
  @Test func convergingFourFingersTrackAndEndOnLift() throws {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, ring(0.2))) == nil)
    // 落指后不到 40 ms：接触面还在变，不算开始
    #expect(recognizer.feed(frame(0.02, ring(0.17))) == nil)
    #expect(recognizer.progress == nil)
    #expect(recognizer.feed(frame(0.05, ring(0.17))) == .began(.pinch))
    // 比例 0.85、标准档满格 0.72：(1 − 0.85) ÷ 0.28
    #expect(abs((recognizer.progress ?? 0) - 0.15 / 0.28) < 1e-9)
    #expect(recognizer.feed(frame(0.1, ring(0.14))) == nil)
    #expect(recognizer.progress == 1)  // 捏过满格夹在 1
    #expect(recognizer.feed(frame(0.12, ring(0.14))) == nil)
    // 抬起一根：松手
    let lifted = recognizer.feed(frame(0.2, Array(ring(0.14).prefix(3))))
    guard case .ended(.pinch, let progress, let velocity) = lifted else {
      Issue.record("没认出松手：\(String(describing: lifted))")
      return
    }
    #expect(progress == 1)
    #expect(velocity > 0)  // 一直在往里收
    #expect(PinchRecognizer.completes(progress: progress, velocity: velocity))
    #expect(recognizer.progress == nil)
    // 剩下的手指抬起来不再报事
    #expect(recognizer.feed(frame(0.21, [], state: 0)) == nil)
    // 再来一次
    #expect(recognizer.feed(frame(0.3, ring(0.2))) == nil)
    #expect(recognizer.feed(frame(0.4, ring(0.17))) == .began(.pinch))
  }

  /// 张开反过来：比例涨到 1.2，标准档满格 1.4 → 进度 0.5
  @Test func spreadingFourFingersSpreads() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, ring(0.1))) == nil)
    #expect(recognizer.feed(frame(0.1, ring(0.12))) == .began(.spread))
    #expect(abs((recognizer.progress ?? 0) - 0.5) < 1e-9)
  }

  /// 四指横扫 / 竖扫：距离几乎不变、质心在挪 → 不开始；距离缩了 5% 但质心挪得比它还多（整体平移带一点收拢）也不开始
  @Test func fourFingerSwipesDoNotBegin() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, [(0.2, 0.5), (0.35, 0.4), (0.5, 0.5), (0.35, 0.6)])) == nil)
    // 往右横扫：质心挪了 0.3，距离不变
    #expect(recognizer.feed(frame(0.1, [(0.5, 0.5), (0.65, 0.4), (0.8, 0.5), (0.65, 0.6)])) == nil)
    #expect(recognizer.feed(frame(0.2, [(0.5, 0.5), (0.65, 0.4), (0.8, 0.5), (0.65, 0.6)])) == nil)
    var vertical = PinchRecognizer(sensitivity: .standard)
    #expect(vertical.feed(frame(0, [(0.3, 0.2), (0.5, 0.2), (0.7, 0.2), (0.5, 0.35)])) == nil)
    #expect(vertical.feed(frame(0.1, [(0.3, 0.5), (0.5, 0.5), (0.7, 0.5), (0.5, 0.65)])) == nil)
    // 半径 0.2 → 0.19（比例 0.95，够了 4%）但质心挪了 0.03 > 距离的变化 0.01：是在平移
    var drifting = PinchRecognizer(sensitivity: .standard)
    #expect(drifting.feed(frame(0, ring(0.2))) == nil)
    #expect(drifting.feed(frame(0.1, ring(0.19, x: 0.53))) == nil)
    #expect(drifting.progress == nil)
  }

  /// 跟着的时候变成横扫（质心挪过 0.22）：取消，之后同一把手指再怎么捏都不认，换了手指数才重来
  @Test func swipeWhileTrackingCancelsAndLatches() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, ring(0.2))) == nil)
    #expect(recognizer.feed(frame(0.1, ring(0.17))) == .began(.pinch))
    #expect(recognizer.feed(frame(0.2, ring(0.17, x: 0.75))) == .cancelled(.pinch))
    #expect(recognizer.progress == nil)
    #expect(recognizer.feed(frame(0.3, ring(0.1, x: 0.75))) == nil)
    #expect(recognizer.feed(frame(0.4, ring(0.05, x: 0.75))) == nil)
    // 抬起来不是松手（已经取消了）
    #expect(recognizer.feed(frame(0.5, [], state: 0)) == nil)
    #expect(recognizer.feed(frame(0.6, ring(0.2))) == nil)
    #expect(recognizer.feed(frame(0.7, ring(0.17))) == .began(.pinch))
  }

  /// 跟着的时候多放上一根（四指档变成五指）：取消，不是松手
  @Test func extraFingerCancels() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, ring(0.2))) == nil)
    #expect(recognizer.feed(frame(0.1, ring(0.17))) == .began(.pinch))
    #expect(recognizer.feed(frame(0.2, ring(0.16) + [(0.5, 0.5)])) == .cancelled(.pinch))
  }

  /// 三指不算；四指放上去没捏、抬掉一根也不报事
  @Test func needsFourFingersAndLiftingWithoutTrackingIsQuiet() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5)])) == nil)
    #expect(recognizer.feed(frame(0.1, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5)])) == nil)
    #expect(recognizer.feed(frame(0.2, ring(0.2))) == nil)
    #expect(recognizer.feed(frame(0.3, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5)])) == nil)
    #expect(recognizer.feed(frame(0.4, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5)])) == nil)
  }

  /// 手指先搁着（超过 1.4 s 没开始）再捏：以搁着之后为新起点，照样认
  @Test func restingFingersThenPinchStillBegins() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, ring(0.2))) == nil)
    #expect(recognizer.feed(frame(1.6, ring(0.2))) == nil)
    #expect(recognizer.feed(frame(1.7, ring(0.18))) == .began(.pinch))
  }

  /// 灵敏度三档只改满格：同样收到 0.86，松的走得多、紧的走得少；越过满格夹在 1，往反方向是 0
  @Test func sensitivityChangesTheFullScale() {
    let standard = PinchRecognizer.progress(of: .pinch, ratio: 0.86, sensitivity: .standard)
    let tight = PinchRecognizer.progress(of: .pinch, ratio: 0.86, sensitivity: .tight)
    let loose = PinchRecognizer.progress(of: .pinch, ratio: 0.86, sensitivity: .loose)
    #expect(abs(standard - 0.5) < 1e-9)
    #expect(tight < standard && standard < loose)
    #expect(PinchRecognizer.progress(of: .pinch, ratio: 0.5, sensitivity: .standard) == 1)
    #expect(PinchRecognizer.progress(of: .pinch, ratio: 1.1, sensitivity: .standard) == 0)
    #expect(
      abs(PinchRecognizer.progress(of: .spread, ratio: 1.2, sensitivity: .standard) - 0.5) < 1e-9)
  }

  /// 松手：过一半就走完；快甩（≥ 1.5 满格 / 秒）不到一半也走完；往回甩（≤ −1）过了一半也退回去
  @Test func releaseDecision() {
    #expect(PinchRecognizer.completes(progress: 0.6, velocity: 0))
    #expect(!PinchRecognizer.completes(progress: 0.4, velocity: 0))
    #expect(PinchRecognizer.completes(progress: 0.2, velocity: 2))
    #expect(!PinchRecognizer.completes(progress: 0.8, velocity: -1.5))
    #expect(PinchRecognizer.completes(progress: 0.5, velocity: -0.5))
  }

  /// 两块触控板交错：各认各的（真机上每个设备一个识别器）
  @Test func twoDevicesInterleaveIndependently() {
    var first = PinchRecognizer(sensitivity: .standard)
    var second = PinchRecognizer(sensitivity: .standard)
    #expect(first.feed(frame(0, ring(0.2))) == nil)
    #expect(second.feed(frame(0.01, ring(0.1))) == nil)
    #expect(second.feed(frame(0.05, ring(0.2))) == .began(.spread))
    #expect(first.feed(frame(0.06, ring(0.1))) == .began(.pinch))
  }

  // MARK: 系统手势开关（只读注入的 UserDefaults）

  @Test func systemPinchReadsTheTrackpadDomains() throws {
    let suite = "launchpad.pinch.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(TrackpadSystemGesture.pinchIsOn(defaults))  // 两个键都没存过 = 系统默认开（F13）
    defaults.set(0, forKey: TrackpadSystemGesture.fourFingerKey)
    defaults.set(0, forKey: TrackpadSystemGesture.fiveFingerKey)
    #expect(!TrackpadSystemGesture.pinchIsOn(defaults))
    defaults.set(2, forKey: TrackpadSystemGesture.fiveFingerKey)
    #expect(TrackpadSystemGesture.pinchIsOn(defaults))  // 任一非 0 = 开
    defaults.set(0, forKey: TrackpadSystemGesture.fiveFingerKey)
    defaults.set(2, forKey: TrackpadSystemGesture.fourFingerKey)
    #expect(TrackpadSystemGesture.pinchIsOn(defaults))
  }

  // MARK: 触发角几何

  @Test func cornerOriginsSitInTheRightCorner() {
    let frame = CGRect(x: 100, y: 200, width: 1000, height: 800)
    let size: CGFloat = 6
    #expect(LaunchpadCornerOption.off.origin(in: frame, size: size) == nil)
    #expect(
      LaunchpadCornerOption.topLeft.origin(in: frame, size: size) == CGPoint(x: 100, y: 994))
    #expect(
      LaunchpadCornerOption.topRight.origin(in: frame, size: size) == CGPoint(x: 1094, y: 994))
    #expect(
      LaunchpadCornerOption.bottomLeft.origin(in: frame, size: size) == CGPoint(x: 100, y: 200))
    #expect(
      LaunchpadCornerOption.bottomRight.origin(in: frame, size: size) == CGPoint(x: 1094, y: 200))
  }
}
