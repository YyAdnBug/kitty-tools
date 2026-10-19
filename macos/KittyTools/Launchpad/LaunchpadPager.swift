// 启动台翻页的纯状态机（从 LaunchpadModel 拆出来，2026-10-18）：两指滑 / 滚轮 / 空白处鼠标拖都喂它，主网格和文件夹各一份。
// 翻页的动画也在这里（2026-10-19）：不回弹的弹簧，松手时接着手指的速度走。

import CoreGraphics
import Foundation
import SwiftUI

/// 翻页的纯状态机（F17）：跟手 1:1、两头橡皮筋，松手按位移（页宽的 `flipFraction`）或最后几帧的速度决定。
/// `travel` 向右为正（看上一页），向左为负（看下一页）；和页面的 `pageOffset` 同一个方向。
nonisolated struct LaunchpadPager: Equatable {
  private(set) var offset: CGFloat = 0
  private var travel: CGFloat = 0
  private var lastTime: TimeInterval = 0
  private var velocity: CGFloat = 0

  /// 快甩的阈值（点 / 秒）：真机上一段很短但很快的甩动也能翻
  static let flickVelocity: CGFloat = 650
  /// 到头那侧的橡皮筋最多露出页宽的多少
  static let resistance: CGFloat = 0.18

  mutating func reset() {
    offset = 0
    travel = 0
    lastTime = 0
    velocity = 0
  }

  /// 喂这一帧的横向位移（点）；返回跟手的偏移
  mutating func feed(
    delta: CGFloat, time: TimeInterval, pageWidth: CGFloat, canBack: Bool, canForward: Bool
  ) -> CGFloat {
    let width = max(pageWidth, 1)
    if lastTime == 0 {
      // 第一帧只记时间、不算速度：dt 夹成 4 ms 时一帧 6 pt 就是快甩，轻碰一下就翻页（G13）
      lastTime = time
    } else {
      let dt = max(time - lastTime, 0.004)
      lastTime = time
      velocity = velocity * 0.55 + (delta / CGFloat(dt)) * 0.45
    }
    travel += delta
    let allowed = travel < 0 ? canForward : canBack
    if !allowed {
      offset = (travel < 0 ? -1 : 1) * min(abs(travel) * Self.resistance, width * Self.resistance)
    } else if abs(travel) <= width {
      offset = travel
    } else {
      offset = (travel < 0 ? -1 : 1) * (width + (abs(travel) - width) * Self.resistance)
    }
    return offset
  }

  /// 手指停住多久以后，松手时不再算快甩（停住再抬 = 慢慢放，G13）
  static let flickWindow: TimeInterval = 0.08

  /// 位移过页宽的多少算翻（2026-10-18 交互对齐：轻轻一滑就翻；原来是 1/3）
  static let flipFraction: CGFloat = 0.2

  /// 松手那一刻手指的速度（点 / 秒，和 offset 同向）；手指停住再抬起来算 0。`time` 是松手那一刻（nil = 最后一帧）
  func releaseVelocity(time: TimeInterval? = nil) -> CGFloat {
    let idle = time.map { $0 - lastTime } ?? 0
    return idle > Self.flickWindow ? 0 : velocity
  }

  /// 松手那一刻页在屏上的速度：一般就是手指的速度；拉到橡皮筋那一段时屏上只走手指的 `resistance` 倍——
  /// 拿手指的速度当弹簧初速度的话，弹回来之前会先往外再冲一截
  func screenVelocity(time: TimeInterval? = nil) -> CGFloat {
    let finger = releaseVelocity(time: time)
    return abs(offset - travel) > 0.5 ? finger * Self.resistance : finger
  }

  /// 松手：位移超过页宽 `flipFraction`、或者最后几帧够快就翻；返回 -1 上一页 / +1 下一页 / 0 回弹。
  /// 快甩按**速度**的方向：和位移方向相反（拖过去又往回甩）就回弹，不翻过去（G13）。`time` 是松手那一刻（nil = 最后一帧）
  mutating func finish(
    canBack: Bool, canForward: Bool, pageWidth: CGFloat, time: TimeInterval? = nil
  ) -> Int {
    let width = max(pageWidth, 1)
    let distance = abs(travel)
    let speed = releaseVelocity(time: time)
    let fast = abs(speed) >= Self.flickVelocity && distance > 4
    defer { reset() }
    guard distance > width * Self.flipFraction || fast else { return 0 }
    let byTravel = travel < 0 ? 1 : -1
    if fast, (speed < 0 ? 1 : -1) != byTravel { return 0 }
    let direction = byTravel
    if direction > 0, canForward { return 1 }
    if direction < 0, canBack { return -1 }
    return 0
  }

  // MARK: 翻页的动画

  /// 翻页的弹簧（照 macOS 15：不回弹、不冲过头，整页滑完约 0.4 s）。松手、键盘、点页点、拖到边上翻页、文件夹里翻页都用它
  static let spring = Spring(duration: 0.42, bounce: 0)

  /// 松手后滑到位（翻过去或弹回来）时弹簧的初速度：接着手指的速度减速停下，不是停一下再从静止起步（2026-10-19 真机反馈「不够丝滑」）。
  /// SwiftUI 的插值弹簧按这一次要走的距离归一（进度 0 → 1，正 = 朝目标走），所以手指的速度除以还要走的点数；
  /// 限在 ±ω（ω = 2π / 时长）以内：临界阻尼的弹簧初速度超过 ω 会冲过目标再回来。两个参数同一个方向口径（点 / 秒、点）
  static func initialVelocity(velocity: CGFloat, distance: CGFloat) -> Double {
    guard abs(distance) >= 1 else { return 0 }
    let omega = 2 * Double.pi / spring.duration
    return min(max(Double(velocity / distance), -omega), omega)
  }

  /// 翻页 / 回弹的动画（`velocity` 0 = 键盘、点页点这种从静止起步的）
  static func animation(velocity: CGFloat = 0, distance: CGFloat = 0) -> Animation {
    .interpolatingSpring(
      spring, initialVelocity: initialVelocity(velocity: velocity, distance: distance))
  }
}
