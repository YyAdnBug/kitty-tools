// 触控板手势插件的识别（issue #59 第 2 批，PLAN §10「触控板手势」）：一个设备上三到五根手指的轻点、长按，单指在四个角的轻点
// （FingerGesture），和同一种轻点连着两下算双击（TapSequence）。
// 改写自 Trackpad Edges（https://github.com/Jiao77/trackpad-edges，Copyright (c) 2026 Jiao77，MIT 许可，许可全文随包在
// Resources/trackpad-gestures-LICENSE.txt）的 Gesture.swift / TapSequence：留多指的轻点 / 长按 / 双击和角落的轻点 / 双击
// （他的 Contact.corner、Gesture.update 里的 corner），边缘滑动不要；阈值和判断的先后照他的，按本仓库的写法重写。
// - 轻点：第一根手指落下后 0.34 s 内全抬起来；中途有一根离起点横向超过 0.035、纵向超过 0.05（归一化的触控板坐标）就不算。
//   手指数按同时按着最多的那一刻算，而且一共只碰过这么多根（抬起一根又落下另一根的不算）；一根根抬起来也算。
// - 角落：一共只碰过一根手指，落在某个角（两个方向都在边上 9% 以内，y = 1 是触控板上沿）、一直没出那个角，其余同轻点。
//   角落不认长按（拇指搭在角上一会儿就算了，2026-11-28 角落拍板）。
// - 长按：那么多根手指都按着、没挪过，同一个候选连着 0.55 s（候选变了——多落下一根、抬起一根——从那一帧重新算）；一下只算一次，
//   长按过的那一下抬起来不再算轻点。手指停着时帧也一直来，所以长按直接看帧的时间，不另起定时器（他是主线程上的定时器）。
// - 双击：同一个设备、同样手指数（同一个角）的两下轻点，第二下在第一下之后 0.29 s 内（他的还按前台 App 分开，这里不分）。
// 都是纯的、时间从外面给：FingerGesture 在框架线程上的 Mutex 里跑，TapSequence 在主线程上跑；他的自检（GestureChecks.swift
// 里多指和角落的那几条）照搬进了 TrackpadGesturesTests。

/// 一个设备上正在做的那一下（他的 Gesture，只留多指和角落）。**nonisolated**：在框架线程上的 Mutex 里跑（G1）
nonisolated struct FingerGesture {
  /// 触控板的四个角（他的 PressTarget 里角落那四个）；原始值写进偏好，别改
  nonisolated enum Corner: String, CaseIterable, Hashable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// 两个方向都在边上这么多以内（归一化坐标）算在角上
    static let zone = 0.09

    /// 这个点在哪个角（他的 Contact.corner）；y = 1 是触控板上沿
    init?(x: Double, y: Double) {
      let left = x <= Self.zone
      let right = x >= 1 - Self.zone
      let top = y >= 1 - Self.zone
      let bottom = y <= Self.zone
      switch (left, right, top, bottom) {
      case (true, _, true, _): self = .topLeft
      case (_, true, true, _): self = .topRight
      case (true, _, _, true): self = .bottomLeft
      case (_, true, _, true): self = .bottomRight
      default: return nil
      }
    }
  }

  enum Event: Equatable, Sendable {
    case tap(fingers: Int)
    case hold(fingers: Int)
    /// 单指在角上轻点
    case corner(Corner)
  }

  static let tapDuration = 0.34
  static let holdDuration = 0.55
  /// 手指离起点超过这么多（归一化坐标）就不算轻点、长按
  static let slopX = 0.035
  static let slopY = 0.05
  static let fingerCounts = 3...5

  private var origins: [Int32: (x: Double, y: Double)] = [:]
  private var started = 0.0
  /// 同时按着最多的那一刻有几根
  private var peak = 0
  /// 这一帧按着几根
  private var count = 0
  private var still = true
  /// 长按已经算过了
  private var consumed = false
  private var candidate: Int?
  private var candidateSince = 0.0
  /// 第一根手指落在的角；那根手指出了这个角、又落下别的手指就清掉
  private var corner: Corner?

  var idle: Bool { origins.isEmpty }

  /// 按手指数算的那一种：同时按着最多的那一刻有三到五根，而且一共就碰过这么多根
  private var fingers: Int? {
    guard peak == origins.count, Self.fingerCounts.contains(peak) else { return nil }
    return peak
  }

  /// 长按的候选（他的 holdTarget）：没挪过、还没算过长按、那么多根手指都还按着
  var holdCandidate: Int? {
    guard still, !consumed, count == peak else { return nil }
    return fingers
  }

  /// 喂一帧（时间是框架给的，秒）：全抬起来的那一帧可能是轻点，按着的那几帧可能到了长按
  mutating func update(_ touches: [TouchPoint], at time: Double) -> Event? {
    // 只认真按在面上的（3 = 刚碰上、4 = 按着；悬着、正在离开的不算）、坐标在面内的（同他的驱动）
    let touching = touches.filter {
      ($0.state == 3 || $0.state == 4) && (0...1).contains($0.x) && (0...1).contains($0.y)
    }
    count = touching.count
    guard !touching.isEmpty else {
      let quick = still && !consumed && time - started <= Self.tapDuration
      let event: Event? =
        if !quick {
          nil
        } else if let fingers {
          .tap(fingers: fingers)
        } else if peak == 1, origins.count == 1, let corner {
          .corner(corner)
        } else {
          nil
        }
      self = FingerGesture()
      return event
    }
    if origins.isEmpty {
      started = time
      corner = touching.count == 1 ? Corner(x: touching[0].x, y: touching[0].y) : nil
    }
    if corner != nil, touching.count != 1 || Corner(x: touching[0].x, y: touching[0].y) != corner {
      corner = nil
    }
    peak = max(peak, count)
    for touch in touching {
      let origin = origins[touch.id] ?? (touch.x, touch.y)
      origins[touch.id] = origin
      if abs(touch.x - origin.x) > Self.slopX || abs(touch.y - origin.y) > Self.slopY {
        still = false
      }
    }
    let current = holdCandidate
    if current != candidate {
      candidate = current
      candidateSince = time
    }
    guard let current, time - candidateSince >= Self.holdDuration else { return nil }
    consumed = true
    return .hold(fingers: current)
  }
}

/// 同一种轻点连着两下（他的 TapSequence；按设备和手指数 / 哪个角分开）。主线程上跑，时间是主线程收到那一下的时刻
nonisolated struct TapSequence {
  struct Key: Hashable, Sendable {
    let device: UInt
    let source: TrackpadGesture.Source
  }

  struct Pending: Equatable, Sendable {
    let key: Key
    let deadline: Double
  }

  static let interval = 0.29
  private var pending: [Key: Pending] = [:]

  /// 一下轻点：上一下还在等、没过期 = 凑成双击（nil）；否则这一下开始等第二下
  mutating func tap(_ key: Key, at time: Double) -> Pending? {
    if let prior = pending[key], time <= prior.deadline {
      pending[key] = nil
      return nil
    }
    let single = Pending(key: key, deadline: time + Self.interval)
    pending[key] = single
    return single
  }

  /// 等够了：这一下还没凑成双击（也没被后来的一下顶掉）就拿走，当轻点
  mutating func takeSingle(_ expected: Pending) -> Bool {
    guard pending[expected.key] == expected else { return false }
    pending[expected.key] = nil
    return true
  }

  /// 这一种在等的那一下作废（角落的一下让给了系统的点按）
  mutating func cancel(_ key: Key) { pending[key] = nil }
}
