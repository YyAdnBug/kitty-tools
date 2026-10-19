// 启动台翻页的纯状态机（从 LaunchpadModel 拆出来，2026-10-18）：两指滑 / 滚轮 / 空白处鼠标拖都喂它，主网格和文件夹各一份。

import CoreGraphics
import Foundation

/// 翻页的纯状态机（F17）：跟手 1:1、两头橡皮筋，松手按位移（页宽 1/3）或最后几帧的速度决定。
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

  /// 松手：位移超过页宽 `flipFraction`、或者最后几帧够快就翻；返回 -1 上一页 / +1 下一页 / 0 回弹。
  /// 快甩按**速度**的方向：和位移方向相反（拖过去又往回甩）就回弹，不翻过去（G13）。`time` 是松手那一刻（nil = 最后一帧）
  mutating func finish(
    canBack: Bool, canForward: Bool, pageWidth: CGFloat, time: TimeInterval? = nil
  ) -> Int {
    let width = max(pageWidth, 1)
    let distance = abs(travel)
    let idle = time.map { $0 - lastTime } ?? 0
    let speed = idle > Self.flickWindow ? 0 : velocity
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
}
