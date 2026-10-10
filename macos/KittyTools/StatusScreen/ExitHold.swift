// 状态屏的退出判断（PLAN §10「状态屏」Z7）：纯状态、时刻注入，配单测。
// 只按着 esc（不带 ⌘⌃⌥⇧、不是连发、此刻没有别的键按着）或左键按在退出提示上开始计时，满 duration 完成；
// 计时中松开 esc / 左键、或又来了别的触碰（别的键、修饰键、鼠标键、媒体键）就取消，要松开重按——抹布一把抹过去、
// 猫踩过去都不会退出。滚动不取消（触控板上蹭一下太常见）。
// 顺带数「触碰」：除了开始按住的那一下，其余按键按下（不算连发）、鼠标键按下、媒体键各算一次，滚动每秒最多算一次。
// 事件从拦截（InputBlock）和 key 面板两条路来，喂给同一个 handle。

import CoreGraphics
import Foundation

struct ExitHold {
  /// 按住多久算数（秒；画面上的进度环也按它走满）
  static let seconds: TimeInterval = 2
  static let duration: Duration = .seconds(seconds)
  /// 滚动多久算一次触碰
  static let scrollGap: Duration = .seconds(1)
  /// 记着「按着」的键这么久没有新动静就不再算数：松开的那一下万一没收到（拦截被系统停用过、安全输入中途打开、
  /// 焦点被抢走），不能让一个「松不开」的键永远挡着 esc。
  /// ponytail: 靠连发判断还按没按着——不连发的键（修饰键、关了按键重复时的所有键）按住超过 5 秒会被当成松开，
  /// 那之后单按 esc 能开始计时；要准就问系统此刻的键盘状态（CGEventSource.keyState）
  static let staleAfter: Duration = .seconds(5)
  /// kVK_Escape
  static let escape = 53

  enum Source { case key, mouse }

  /// 正在按住：哪一种、从什么时候起
  private(set) var holding: (source: Source, since: ContinuousClock.Instant)?
  private var keysDown: [Int: ContinuousClock.Instant] = [:]
  private var isLeftDown = false
  private var lastScroll: ContinuousClock.Instant?

  /// 来了一个事件，返回算不算一次触碰。hints：这时看得见的退出提示在各屏上的范围（没显示着就是空的）
  mutating func handle(
    _ event: InputBlock.Event, at now: ContinuousClock.Instant, hints: [CGRect] = []
  ) -> Bool {
    switch event {
    case .keyDown(let code, let isRepeat, let hasModifiers):
      let others = keysDown.contains { $0.key != code && now - $0.value < Self.staleAfter }
      keysDown[code] = now
      guard !isRepeat else { return false }
      if code == Self.escape, !hasModifiers, !others {
        // 已经在按住 esc 时又来一下（同一下按键两条路都到了）：接着算，不重来、不取消
        if holding?.source == .key { return false }
        if holding == nil {
          holding = (.key, now)
          return false
        }
      }
      holding = nil
      return true
    case .keyUp(let code):
      keysDown[code] = nil
      if code == Self.escape, holding?.source == .key { holding = nil }
      return false
    case .leftDown(let point):
      isLeftDown = true
      if holding == nil, hints.contains(where: { $0.contains(point) }) {
        holding = (.mouse, now)
        return false
      }
      holding = nil
      return true
    case .leftUp:
      isLeftDown = false
      if holding?.source == .mouse { holding = nil }
      return false
    case .touch:
      holding = nil
      return true
    case .scroll:
      if let lastScroll, now - lastScroll < Self.scrollGap { return false }
      lastScroll = now
      return true
    }
  }

  /// 按住还差多久（nil = 没在按住，≤ 0 = 满了）
  func remaining(at now: ContinuousClock.Instant) -> Duration? {
    holding.map { Self.duration - (now - $0.since) }
  }

  func isComplete(at now: ContinuousClock.Instant) -> Bool {
    remaining(at: now).map { $0 <= .zero } ?? false
  }

  /// 还有键 / 左键按着（退出之后拦截留到它们松开）
  func isAnythingDown(at now: ContinuousClock.Instant) -> Bool {
    isLeftDown || keysDown.values.contains { now - $0 < Self.staleAfter }
  }

  /// 取消进行中的按住、忘掉按着的键（锁屏：之后松开的那一下收不到）
  mutating func reset() {
    holding = nil
    keysDown = [:]
    isLeftDown = false
  }
}
