// 启动台捏合跟手（2026-10-19，GESTURE.md A）的单测：开 / 收进度的弹簧、LaunchpadZoom 跟手和落定（直接喂时间，不开屏幕刷新回调）、
// 上面那层的缩放、桥把进度先写好再派事件。不注册触控板回调、不建真面板、不 makeKey。

import AppKit
import Synchronization
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadZoomTests {
  // MARK: 弹簧

  /// 从 0 走到 1：一路往上、不冲过头，时长左右落定
  @Test func springSettlesWithoutOvershoot() {
    let spring = LaunchpadZoomSpring(from: 0, target: 1, velocity: 0, duration: 0.4)
    var last = spring.value(at: 0)
    #expect(last == 0)
    var settledAt: Double?
    for step in 1...120 {
      let time = Double(step) / 120
      let value = spring.value(at: time)
      #expect(value >= last - 1e-12)
      #expect(value <= 1 + 1e-12)
      last = value
      if settledAt == nil, spring.isSettled(at: time) { settledAt = time }
    }
    #expect(settledAt.map { $0 > 0.3 && $0 < 0.7 } == true)
  }

  /// 松手时接着手指的速度：太快的限在 ω·距离以内（再快就冲过头）；朝目标的初速度让它比静止起步走得快
  @Test func springKeepsReleaseVelocityButNeverOvershoots() {
    let omega = 2 * Double.pi / 0.3
    let fast = LaunchpadZoomSpring(from: 0.6, target: 0, velocity: -50, duration: 0.3)
    #expect(abs(fast.velocity - (-omega * 0.6)) < 1e-9)
    for step in 0...60 {
      #expect(fast.value(at: Double(step) / 120) >= -1e-12)
    }
    let still = LaunchpadZoomSpring(from: 0.6, target: 0, velocity: 0, duration: 0.3)
    let flung = LaunchpadZoomSpring(from: 0.6, target: 0, velocity: -2, duration: 0.3)
    #expect(flung.value(at: 0.05) < still.value(at: 0.05))
    // 已经在目标上：初速度只能是 0
    #expect(LaunchpadZoomSpring(from: 1, target: 1, velocity: 3, duration: 0.4).velocity == 0)
  }

  // MARK: LaunchpadZoom

  /// 按键打开：弹簧从 0 走到 1，每帧回调 apply，走到了回调 onSettled(1) 一次、停下
  @Test func settleAppliesEveryFrameAndReportsOnce() {
    let zoom = LaunchpadZoom(host: nil)
    var applied: [Double] = []
    var settled: [Double] = []
    zoom.apply = { applied.append($0) }
    zoom.onSettled = { settled.append($0) }
    zoom.settle(to: 1, duration: LaunchpadZoom.openDuration)
    #expect(zoom.isSettling)
    var time = 10.0
    for _ in 0..<120 where zoom.isSettling {
      zoom.step(at: time)
      time += 1.0 / 60
    }
    #expect(!zoom.isSettling)
    #expect(settled == [1])
    #expect(zoom.value == 1)
    #expect(applied.count > 10)
    #expect(zip(applied, applied.dropFirst()).allSatisfy { $0 <= $1 })
    // 停了以后再来帧也不动
    zoom.step(at: time + 1)
    #expect(settled == [1])
  }

  /// 跟手：第一帧离得远（面板第一帧画好时手指已经捏了一截）就追上去、不一下跳过去；追上之后每帧直接等于手指的进度
  @Test func trackingCatchesUpThenFollowsExactly() {
    let zoom = LaunchpadZoom(host: nil)
    var finger = 0.4
    zoom.track { finger }
    #expect(zoom.isTracking)
    zoom.step(at: 0)
    #expect(zoom.value == 0)  // 第一帧没有间隔：还没走
    zoom.step(at: 1.0 / 60)
    #expect(zoom.value > 0 && zoom.value < 0.4)
    for frame in 2..<20 { zoom.step(at: Double(frame) / 60) }
    #expect(abs(zoom.value - 0.4) < 1e-9)
    finger = 0.7
    zoom.step(at: 21.0 / 60)
    #expect(zoom.value == 0.7)
    finger = 1.3  // 进度夹在 0…1
    zoom.step(at: 22.0 / 60)
    #expect(zoom.value == 1)
  }

  /// 跟手中途松手：从现在的位置接着走（不跳回起点），stop 停在原地、不回调 onSettled
  @Test func settleStartsFromWhereTrackingLeftOff() {
    let zoom = LaunchpadZoom(host: nil)
    var settled: [Double] = []
    zoom.onSettled = { settled.append($0) }
    zoom.set(0.3)
    zoom.track { 0.3 }
    zoom.step(at: 0)
    #expect(zoom.value == 0.3)
    zoom.settle(to: 0, velocity: -1, duration: LaunchpadZoom.closeDuration)
    zoom.step(at: 1)
    #expect(zoom.value <= 0.3)
    zoom.step(at: 1 + 1.0 / 60)
    #expect(zoom.value < 0.3 && zoom.value > 0)
    zoom.stop()
    let frozen = zoom.value
    zoom.step(at: 2)
    #expect(zoom.value == frozen)
    #expect(settled.isEmpty)
  }

  // MARK: 松手之后走到哪

  /// 四种松手：捏合走完到 1、退回到 0（倒着走打开那一段）；张开走完到 0（往前冲出去）、退回到 1；张开那一段速度反号
  @Test func releaseMapsGestureToTargetAndVelocity() {
    let opened = Launchpad.release(.pinch, completes: true, velocity: 2)
    #expect(opened.target == 1 && opened.velocity == 2 && !opened.forward)
    let backed = Launchpad.release(.pinch, completes: false, velocity: -1.5)
    #expect(backed.target == 0 && backed.velocity == -1.5 && !backed.forward)
    let closed = Launchpad.release(.spread, completes: true, velocity: 2)
    #expect(closed.target == 0 && closed.velocity == -2 && closed.forward)
    let kept = Launchpad.release(.spread, completes: false, velocity: -1)
    #expect(kept.target == 1 && kept.velocity == 1 && kept.forward)
  }

  // MARK: 缩放

  /// 打开的走法 1.1 → 1；收起的走法 1 → 1.08；两种走法在摆好（1）时都是原大
  @Test func contentScaleFollowsZoom() {
    #expect(LaunchpadZoomScale.scale(zoom: 0, forward: false) == 1.1)
    #expect(LaunchpadZoomScale.scale(zoom: 1, forward: false) == 1)
    #expect(abs(LaunchpadZoomScale.scale(zoom: 0.5, forward: false) - 1.05) < 1e-9)
    #expect(LaunchpadZoomScale.scale(zoom: 1, forward: true) == 1)
    #expect(abs(LaunchpadZoomScale.scale(zoom: 0, forward: true) - 1.08) < 1e-9)
  }

  /// 收起分两种走法：按键 / 张开往前冲出去，捏到一半松手倒着走打开那一段；收起只算一次
  @Test func beginClosingPicksTheDirection() {
    let model = LaunchpadModel(
      layout: LaunchpadLayout(pages: []), catalog: [], icons: LaunchpadIcons(),
      columns: 7, rows: 5, screenSize: CGSize(width: 1440, height: 900))
    #expect(model.zoom == 1 && !model.zoomForward)
    model.beginClosing(forward: false)
    #expect(model.isClosing && !model.zoomForward)
    var closes = 0
    model.onClose = { closes += 1 }
    model.requestClose()
    #expect(closes == 0)
    let other = LaunchpadModel(
      layout: LaunchpadLayout(pages: []), catalog: [], icons: LaunchpadIcons(),
      columns: 7, rows: 5, screenSize: CGSize(width: 1440, height: 900))
    other.beginClosing()
    #expect(other.zoomForward)
  }

  // MARK: 桥

  /// 框架线程上：进度每帧写进桥里、只在开始 / 松手时派事件；「开始」派出去之前进度已经是这一下的
  @Test func bridgePublishesProgressBeforeEvents() async {
    let recorder = Recorder()
    let bridge = TouchpadBridge(sensitivity: .standard) { event in
      let current = recorder.bridge.withLock { $0 }?.progress.withLock { $0 } ?? -1
      recorder.events.withLock { $0.append((event, current)) }
    }
    recorder.bridge.withLock { $0 = bridge }
    let frames = [
      (0.0, 0.2), (0.05, 0.17), (0.1, 0.16), (0.15, 0.15),
    ].map { time, radius in
      TouchFrame(
        time: time,
        touches: [
          (0.5 - radius, 0.5), (0.5, 0.5 - radius), (0.5 + radius, 0.5), (0.5, 0.5 + radius),
        ]
        .enumerated().map { TouchPoint(id: Int32($0), x: $1.0, y: $1.1, state: 4) })
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        for frame in frames { bridge.feed(device: 1, frame: frame) }
        bridge.feed(device: 1, frame: TouchFrame(time: 0.2, touches: []))
        continuation.resume()
      }
    }
    let events = recorder.events.withLock { $0 }
    #expect(events.count == 2)
    #expect(events.first?.0 == .began(.pinch))
    #expect(abs((events.first?.1 ?? 0) - 0.15 / 0.28) < 1e-9)
    if case .ended(.pinch, let progress, _) = events.last?.0 {
      #expect(abs(progress - 0.25 / 0.28) < 1e-9)
    } else {
      Issue.record("没认出松手")
    }
    #expect(abs(bridge.progress.withLock { $0 } - 0.25 / 0.28) < 1e-9)
  }
}

/// 桥的回调在后台线程上记下事件和那一刻桥里的进度（Mutex 不能直接被逃逸闭包捕获，包一层）
private final class Recorder: Sendable {
  let events = Mutex<[(PinchRecognizer.Event, Double)]>([])
  let bridge = Mutex<TouchpadBridge?>(nil)
}
