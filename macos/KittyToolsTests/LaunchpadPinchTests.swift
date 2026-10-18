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

  /// 四指从半径 0.2 收到 0.14（比例 0.7 < 0.72）：捏合一次
  @Test func convergingFourFingersPinchesOnce() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    let start = frame(0, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5), (0.5, 0.7)])
    #expect(recognizer.feed(start) == nil)
    #expect(
      recognizer.feed(frame(0.1, [(0.33, 0.5), (0.5, 0.33), (0.67, 0.5), (0.5, 0.67)])) == nil)
    #expect(
      recognizer.feed(frame(0.2, [(0.36, 0.5), (0.5, 0.36), (0.64, 0.5), (0.5, 0.64)])) == .pinch)
    // 一次手势只触发一次
    #expect(
      recognizer.feed(frame(0.3, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5), (0.5, 0.6)])) == nil)
    // 手指抬起来之后重来
    #expect(recognizer.feed(frame(0.5, [], state: 0)) == nil)
    #expect(recognizer.feed(frame(0.6, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5), (0.5, 0.7)])) == nil)
    #expect(
      recognizer.feed(frame(0.7, [(0.36, 0.5), (0.5, 0.36), (0.64, 0.5), (0.5, 0.64)])) == .pinch)
  }

  /// 张开反过来
  @Test func spreadingFourFingersSpreads() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5), (0.5, 0.6)])) == nil)
    #expect(
      recognizer.feed(frame(0.1, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5), (0.5, 0.7)])) == .spread)
  }

  /// 四指横扫 / 竖扫：距离几乎不变、质心在挪 → 不认
  @Test func fourFingerSwipesAreNotPinches() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, [(0.2, 0.5), (0.35, 0.4), (0.5, 0.5), (0.35, 0.6)])) == nil)
    // 往右横扫：质心挪了 0.3，距离不变
    #expect(recognizer.feed(frame(0.1, [(0.5, 0.5), (0.65, 0.4), (0.8, 0.5), (0.65, 0.6)])) == nil)
    #expect(recognizer.feed(frame(0.2, [(0.5, 0.5), (0.65, 0.4), (0.8, 0.5), (0.65, 0.6)])) == nil)
    var vertical = PinchRecognizer(sensitivity: .standard)
    #expect(vertical.feed(frame(0, [(0.3, 0.2), (0.5, 0.2), (0.7, 0.2), (0.5, 0.35)])) == nil)
    #expect(vertical.feed(frame(0.1, [(0.3, 0.5), (0.5, 0.5), (0.7, 0.5), (0.5, 0.65)])) == nil)
  }

  /// 三指不算；中途抬一指（4 → 3）也不算一次完整手势
  @Test func needsFourFingersAndResetsWhenCountChanges() {
    var recognizer = PinchRecognizer(sensitivity: .standard)
    #expect(recognizer.feed(frame(0, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5)])) == nil)
    #expect(recognizer.feed(frame(0.1, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5)])) == nil)
    #expect(recognizer.feed(frame(0.2, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5), (0.5, 0.6)])) == nil)
    // 抬掉一指：以三指重新算，不会触发
    #expect(recognizer.feed(frame(0.3, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5)])) == nil)
    #expect(recognizer.feed(frame(0.4, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5)])) == nil)
  }

  /// 灵敏度三档：松的一下就过、紧的要收得更狠
  @Test func sensitivityChangesTheThreshold() {
    let start = [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5), (0.5, 0.7)]
    let gentle = [(0.34, 0.5), (0.5, 0.34), (0.66, 0.5), (0.5, 0.66)]  // 半径 0.16，比例 0.8
    var loose = PinchRecognizer(sensitivity: .loose)
    #expect(loose.feed(frame(0, start)) == nil)
    #expect(loose.feed(frame(0.1, gentle)) == .pinch)
    var tight = PinchRecognizer(sensitivity: .tight)
    #expect(tight.feed(frame(0, start)) == nil)
    #expect(tight.feed(frame(0.1, gentle)) == nil)
    #expect(tight.feed(frame(0.2, [(0.38, 0.5), (0.5, 0.38), (0.62, 0.5), (0.5, 0.62)])) == .pinch)
  }

  /// 两块触控板交错：各认各的（真机上每个设备一个识别器）
  @Test func twoDevicesInterleaveIndependently() {
    var first = PinchRecognizer(sensitivity: .standard)
    var second = PinchRecognizer(sensitivity: .standard)
    #expect(first.feed(frame(0, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5), (0.5, 0.7)])) == nil)
    #expect(second.feed(frame(0.01, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5), (0.5, 0.6)])) == nil)
    #expect(second.feed(frame(0.05, [(0.3, 0.5), (0.5, 0.3), (0.7, 0.5), (0.5, 0.7)])) == .spread)
    #expect(first.feed(frame(0.06, [(0.4, 0.5), (0.5, 0.4), (0.6, 0.5), (0.5, 0.6)])) == .pinch)
  }

  // MARK: 系统手势开关（只读注入的 UserDefaults）

  @Test func systemPinchReadsTheTrackpadDomains() throws {
    let suite = "launchpad.pinch.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!TrackpadSystemGesture.pinchIsOn(defaults))  // 没存过 = 关
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
