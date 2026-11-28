// 触控板捏合（SPEC §5.6，R7）：`Shell/Touchpad` 的一个订阅者。私有框架、设备、醒来和插拔都归 Touchpad，这里只有捏合那一半。
// 框架线程上每帧交给 Mutex 里的识别器（每个设备一个）；跟着的那一下的进度每帧写进 `PinchTracker.progress`（Mutex，
// 主线程的屏幕刷新回调每帧来取），开始 / 松手 / 取消三件事才 DispatchQueue.main.async 回主线程（2026-10-19 起跟手，
// GESTURE.md A7：每帧都派一次的话，触控板约 8 ms 一帧、屏幕 60 / 120 Hz，节奏对不上会抖）——**框架线程上不碰主线程状态**（mac-native §3）。
// 功能开着就订（系统的捏合开着时总控在开始捏的那一刻自己不打开）；停的时候退订。Touchpad 重新枚举设备之后（醒来、插拔）
// 换一个新的识别器、报一次取消。

import Foundation
import Synchronization

/// 捏合在框架线程上的那一半：识别器（Mutex 里）、最新进度、把三件事交给 `onEvent`。
/// **必须 `nonisolated`**：工程默认 MainActor 隔离，不写的话这个类和它的方法会被推成 @MainActor，框架线程一调进来
/// 就被 Swift 6 的隔离检查当场 trap（G1）
nonisolated final class PinchTracker: Sendable {
  private let recognizers = Mutex<[UInt: PinchRecognizer]>([:])
  /// 正在跟的那一下最新的进度（0…1）：框架线程每帧写、主线程的屏幕刷新回调每帧读。只在跟着的时候写，
  /// 开始那一帧先写进度再派「开始」，主线程收到「开始」时这里已经是这一下的了
  let progress = Mutex<Double>(0)
  private let sensitivity: PinchRecognizer.Sensitivity
  private let fingers: PinchFingers
  let onEvent: @Sendable (PinchRecognizer.Event) -> Void

  init(
    sensitivity: PinchRecognizer.Sensitivity, fingers: PinchFingers = .four,
    onEvent: @escaping @Sendable (PinchRecognizer.Event) -> Void
  ) {
    self.sensitivity = sensitivity
    self.fingers = fingers
    self.onEvent = onEvent
  }

  func feed(device: UInt, frame: TouchFrame) {
    let (event, current) = recognizers.withLock { table -> (PinchRecognizer.Event?, Double?) in
      var recognizer =
        table[device] ?? PinchRecognizer(sensitivity: sensitivity, fingers: fingers)
      let result = recognizer.feed(frame)
      table[device] = recognizer
      return (result, recognizer.progress)
    }
    if let current { progress.withLock { $0 = current } }
    if let event { onEvent(event) }
  }
}

/// 触控板捏合的监听（Launchpad 拿着；功能开着就 start）
@MainActor
final class TouchpadWatcher {
  /// 在 Touchpad 上订的那一份
  static let key = "launchpad.pinch"

  var availability: Touchpad.Availability { Touchpad.shared.availability }
  /// 开始 / 松手 / 取消（已经在主线程）；每帧的进度看 `pinchProgress`
  var onPinch: ((PinchRecognizer.Event) -> Void)?

  private var sensitivity: PinchRecognizer.Sensitivity = .standard
  private var fingers: PinchFingers = .four
  /// 每次订 / 退订换一代：派回主线程的旧手势看到代号变了就不回调（F25）
  private var generation = 0
  /// 订着时有；nil = 没在听
  private var tracker: PinchTracker?

  /// 正在跟的那一下最新的进度（屏幕刷新回调每帧读；没在听时 0）
  var pinchProgress: Double { tracker?.progress.withLock { $0 } ?? 0 }

  /// 开着监听。已经开着、灵敏度和手指数也没变时什么都不做（G8：别的窗口变 key、导入设置都会走到这里，
  /// 每次都换识别器会把正在捏的那一下清掉）
  func start(sensitivity: PinchRecognizer.Sensitivity, fingers: PinchFingers = .four) {
    if tracker != nil, sensitivity == self.sensitivity, fingers == self.fingers { return }
    self.sensitivity = sensitivity
    self.fingers = fingers
    if tracker != nil { abandonGesture() }
    subscribe()
  }

  /// 关掉：退订（最后一个订阅者走了 Touchpad 会注销回调、停设备），旧识别器派回来的都不认
  func stop() {
    abandonGesture()
    generation += 1
    guard tracker != nil else { return }
    tracker = nil
    Touchpad.shared.unsubscribe(Self.key)
  }

  /// 换一个新的识别器订上（同一个 key：Touchpad 只换快照，设备不动）
  private func subscribe() {
    generation += 1
    let tracker = PinchTracker(
      sensitivity: sensitivity, fingers: fingers,
      onEvent: Self.forwarder(to: self, generation: generation))
    self.tracker = tracker
    Touchpad.shared.subscribe(
      Self.key, consumer: Self.consumer(feeding: tracker),
      onReset: { [weak self] in
        // 重新枚举过设备：旧的设备编号和做到一半的手势都作废
        guard let self, self.tracker != nil else { return }
        self.abandonGesture()
        self.subscribe()
      })
  }

  /// 框架线程上收帧的那一下：在 nonisolated 的上下文里建，闭包不会被推成 MainActor（G1）
  nonisolated static func consumer(feeding tracker: PinchTracker) -> TouchConsumer {
    { device, frame in tracker.feed(device: device, frame: frame) }
  }

  /// 识别结果派回主线程的那一下：同上，在 nonisolated 的上下文里建（它是在框架线程上被调的，G1）
  nonisolated private static func forwarder(
    to watcher: TouchpadWatcher, generation: Int
  ) -> @Sendable (PinchRecognizer.Event) -> Void {
    { [weak watcher] event in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let watcher, watcher.tracker != nil, watcher.generation == generation else {
            return
          }
          watcher.onPinch?(event)
        }
      }
    }
  }

  /// 正在跟的那一下等不到松手了（退订、重新枚举之后旧的事件都不认）：两种各报一次取消，总控只认它正在跟的那种——
  /// 不然捏到一半的面板一直半透明地挂着、不收鼠标也不拿键盘
  private func abandonGesture() {
    onPinch?(.cancelled(.pinch))
    onPinch?(.cancelled(.spread))
  }
}
