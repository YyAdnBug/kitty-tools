// 启动台打开 / 收起的那一个数（2026-10-19，拍板页 build/research/launchpad/GESTURE.md A2 / A7）：0 = 收着、1 = 摆好。
// 总控每块面板一个：捏合时跟着手指（屏幕刷新回调每帧取识别器最新的进度，直接设，不带动画），松手后、以及快捷键 / 菜单 /
// 触发角 / Esc 这些入口，都由同一个临界阻尼的弹簧走到 0 或 1（不冲过头；松手时接着手指的速度）。
// 窗口透明度和上面那层的缩放都只听这一个数（`apply`），不再是「窗口一套 AppKit 动画 + 图标一套 SwiftUI 动画」各算各的——
// 跟手以后两套交接不上。屏幕刷新回调只在跟手 / 落定时开着，落定就停；收起时这一份跟着那块面板走完（刷新回调拿着它），
// 新开的面板用新的一份，互不打扰（同 F20）。单测不开刷新回调，直接喂时间调 `step(at:)`。

import AppKit
import QuartzCore

/// 临界阻尼的弹簧（纯函数）：x(t) = 目标 + (x₀ + (v₀ + ω·x₀)·t)·e^(−ω·t)，x₀ = 起点 − 目标，v₀ = 起始速度（每秒）。
/// 和 SwiftUI 的 `Spring(duration:bounce: 0)` 同一条曲线（ω = 2π ÷ 时长）
nonisolated struct LaunchpadZoomSpring: Equatable {
  var from: Double
  var target: Double
  var velocity: Double
  var omega: Double

  init(from: Double, target: Double, velocity: Double, duration: Double) {
    self.from = from
    self.target = target
    omega = 2 * Double.pi / max(duration, 0.01)
    self.velocity = Self.clamped(velocity, from: from, target: target, omega: omega)
  }

  func value(at time: Double) -> Double {
    let x0 = from - target
    return target + (x0 + (velocity + omega * x0) * time) * exp(-omega * time)
  }

  /// 走到了：离目标不到 0.005（透明度差半个百分点、缩放差万分之五，看不出来）且这一刻几乎不动。
  /// 收起时这一下决定面板什么时候 orderOut，阈值再小就白白多挂约 0.1 s
  func isSettled(at time: Double) -> Bool {
    let x0 = from - target
    let speed = (velocity - omega * (velocity + omega * x0) * time) * exp(-omega * time)
    return abs(value(at: time) - target) < 0.005 && abs(speed) < 0.05
  }

  /// 起始速度限在 ±ω·|x₀|：朝目标再快就会冲过目标再回来（临界阻尼不冲过头的条件）
  static func clamped(_ velocity: Double, from: Double, target: Double, omega: Double) -> Double {
    let limit = omega * abs(target - from)
    return min(max(velocity, -limit), limit)
  }
}

@MainActor
final class LaunchpadZoom: NSObject {
  /// 打开的弹簧时长（同原来的 openZoom 0.4）；收起快一点（原来 closeZoom 0.3）
  static let openDuration = 0.4
  static let closeDuration = 0.3
  /// 跟手刚开始、面板第一帧才画好时，进度可能已经走了一截：这么久追上去，不一下跳过去
  static let catchUp = 0.06

  private enum Mode {
    case idle
    case tracking(source: () -> Double, caughtUp: Bool)
    case settling(LaunchpadZoomSpring, start: CFTimeInterval?)
  }

  private(set) var value: Double
  /// 每次变了就调（总控设窗口透明度和模型里的缩放）
  var apply: (Double) -> Void = { _ in }
  /// 弹簧走到了（0 或 1）
  var onSettled: (Double) -> Void = { _ in }

  private var mode = Mode.idle
  private weak var host: NSView?
  private var link: CADisplayLink?
  private var lastTime: CFTimeInterval?
  /// 每次换走法换一代：兜底的定时只收自己那一次
  private var generation = 0

  /// `host` 用来建屏幕刷新回调（面板的 contentView）；nil = 不建（单测自己调 `step`）
  init(value: Double = 0, host: NSView?) {
    self.value = value
    self.host = host
  }

  var isTracking: Bool {
    if case .tracking = mode { return true }
    return false
  }

  var isSettling: Bool {
    if case .settling = mode { return true }
    return false
  }

  /// 直接设（不动画），停掉正在走的
  func set(_ value: Double) {
    stop()
    update(value)
  }

  /// 跟手：每帧取 `source()`（0…1）直接设；刚开始离得远时 `catchUp` 内追上去
  func track(_ source: @escaping () -> Double) {
    generation += 1
    mode = .tracking(source: source, caughtUp: false)
    lastTime = nil
    startLink()
  }

  /// 走到 `target`；`velocity` 是这个数每秒变多少（松手时手指的速度，正 = 变大）
  func settle(to target: Double, velocity: Double = 0, duration: Double) {
    generation += 1
    let spring = LaunchpadZoomSpring(
      from: value, target: target, velocity: velocity, duration: duration)
    mode = .settling(spring, start: nil)
    startLink()
    // 兜底：刷新回调万一不来（屏幕睡了、窗口被系统拿走），到点直接落定，别让收起的面板一直挂着
    let current = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + duration * 2 + 0.3) { [weak self] in
      guard let self, self.generation == current, self.isSettling else { return }
      self.finish(at: target)
    }
  }

  /// 停在现在的位置（不回调 onSettled）
  func stop() {
    generation += 1
    mode = .idle
    stopLink()
  }

  /// 走一帧（屏幕刷新回调调；单测直接喂时间）。窗口透明度 0 时刷新回调照样来（27.0.1 实测约 60 次 / 秒，
  /// build/research/launchpad/probe/alpha-link），跟手从 0 起步不会卡住
  func step(at time: CFTimeInterval) {
    switch mode {
    case .idle:
      stopLink()
    case .tracking(let source, let caughtUp):
      let target = min(max(source(), 0), 1)
      let dt = lastTime.map { time - $0 } ?? 0
      lastTime = time
      if caughtUp || abs(target - value) < 0.02 {
        mode = .tracking(source: source, caughtUp: true)
        update(target)
      } else {
        update(value + (target - value) * min(1, dt / Self.catchUp))
      }
    case .settling(let spring, let start):
      // 起点按第一次来的这一帧往前推一帧算：动画从这一帧算起（之前的时间可能被建界面吃掉了），但这一帧就要动——
      // 跟手松手时停一帧不动，看着像顿了一下
      let begin = start ?? time - (link?.duration ?? 0)
      if start == nil { mode = .settling(spring, start: begin) }
      let elapsed = time - begin
      if spring.isSettled(at: elapsed) {
        finish(at: spring.target)
      } else {
        update(spring.value(at: elapsed))
      }
    }
  }

  private func finish(at target: Double) {
    mode = .idle
    stopLink()
    update(target)
    onSettled(target)
  }

  private func update(_ next: Double) {
    let clamped = min(max(next, 0), 1)
    guard clamped != value else { return }
    value = clamped
    apply(clamped)
  }

  private func startLink() {
    guard link == nil, let host else { return }
    let made = host.displayLink(target: self, selector: #selector(tick(_:)))
    made.add(to: .main, forMode: .common)
    link = made
  }

  private func stopLink() {
    lastTime = nil
    guard let link else { return }
    self.link = nil
    // 刷新回调拿着自己（收起的那一份只有它拿着）：在回调里当场作废会马上放掉自己，后面的 onSettled 就在放掉的对象上跑了。
    // 先停住、晚一拍再作废，这一拍里自己还活着
    link.isPaused = true
    DispatchQueue.main.async { link.invalidate() }
  }

  @objc private func tick(_ link: CADisplayLink) {
    step(at: link.targetTimestamp)
  }
}
