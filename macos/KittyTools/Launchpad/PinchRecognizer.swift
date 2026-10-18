// 触控板捏合的识别器（SPEC §5.6、R7）：纯状态机，输入一帧帧触点（时间 + 各指在触控板上的归一化位置），
// 输出「捏合了」/「张开了」。不碰框架、不碰窗口，单测直接喂造好的帧序列。
// 规则（数值写在这里、也写进 mac-launchpad.mdc）：
// - 同时至少 4 指在面上（手指数变了就重来：中途抬一指不算一次完整手势）；
// - 所有指到质心的平均距离，从手势开始时的距离缩到 pinchRatio 以下 = 捏合，涨到 spreadRatio 以上 = 张开；
// - 质心挪动超过 maxTravel 的当成四指横扫 / 竖扫（切桌面、调度中心），不认；
// - 一次手势只触发一次，直到手指全抬起来（或手指数变了）才重置；
// - 灵敏度三档只改那两个比例（越松越容易触发）。
// ponytail: 只看平均距离和质心位移，不做轨迹拟合；真机上误判多再加「每指位移方向一致」这类条件。

import CoreGraphics
import Foundation

/// 一帧里的一个触点：id（同一根手指跨帧不变）、在触控板上的归一化位置（0…1，左下角原点，和框架给的口径一致）、
/// 框架给的状态（0 = 没在跟踪、4 = 按着；别的值照「在面上」算）
nonisolated struct TouchPoint: Equatable, Sendable {
  var id: Int32
  var x: Double
  var y: Double
  var state: Int32
}

/// 一帧触点（时间来自框架的 timestamp，秒）
nonisolated struct TouchFrame: Equatable, Sendable {
  var time: Double
  var touches: [TouchPoint]
}

nonisolated struct PinchRecognizer: Sendable {
  enum Gesture: Equatable, Sendable {
    case pinch
    case spread
  }

  /// 灵敏度（设置 › 启动台；数值是「缩到 / 涨到原来的多少」）
  enum Sensitivity: String, CaseIterable, Sendable {
    case tight, standard, loose

    var title: String {
      switch self {
      case .tight: "紧"
      case .standard: "标准"
      case .loose: "松"
      }
    }

    var pinchRatio: Double {
      switch self {
      case .tight: 0.62
      case .standard: 0.72
      case .loose: 0.82
      }
    }

    var spreadRatio: Double {
      switch self {
      case .tight: 1.60
      case .standard: 1.40
      case .loose: 1.22
      }
    }
  }

  /// 至少这么多指
  static let minimumFingers = 4
  /// 质心挪动超过这么多（归一化单位）当横扫 / 竖扫
  static let maxTravel = 0.22
  /// 太快（噪声）和太慢（不是捏合）都不要
  static let minimumDuration = 0.04
  static let maximumDuration = 1.4

  var sensitivity: Sensitivity

  init(sensitivity: Sensitivity = .standard) {
    self.sensitivity = sensitivity
  }

  private var startDistance: Double?
  private var startCentroid = CGPoint.zero
  private var startTime: Double = 0
  private var fingerCount = 0
  private var fired = false

  mutating func reset() {
    startDistance = nil
    startCentroid = .zero
    startTime = 0
    fingerCount = 0
    fired = false
  }

  /// 喂一帧；识别出一次手势就返回它（同一次手势不会返回第二次）
  mutating func feed(_ frame: TouchFrame) -> Gesture? {
    let touching = frame.touches.filter { $0.state != 0 && $0.state != 7 }
    guard touching.count >= Self.minimumFingers else {
      reset()
      return nil
    }
    let count = touching.count
    if count != fingerCount {
      // 手指数变了：以这一帧为新起点重来
      fingerCount = count
      fired = false
      startDistance = nil
    }
    let centroid = Self.centroid(touching)
    let distance = Self.averageDistance(touching, from: centroid)
    guard let startDistance else {
      self.startDistance = distance
      startCentroid = centroid
      startTime = frame.time
      return nil
    }
    guard !fired else { return nil }
    let duration = frame.time - startTime
    guard duration >= Self.minimumDuration, duration <= Self.maximumDuration else { return nil }
    let travel = hypot(centroid.x - startCentroid.x, centroid.y - startCentroid.y)
    guard travel <= Self.maxTravel else { return nil }
    guard startDistance > 0.001 else { return nil }
    let ratio = distance / startDistance
    if ratio <= sensitivity.pinchRatio {
      fired = true
      return .pinch
    }
    if ratio >= sensitivity.spreadRatio {
      fired = true
      return .spread
    }
    return nil
  }

  private static func centroid(_ touches: [TouchPoint]) -> CGPoint {
    guard !touches.isEmpty else { return .zero }
    var sumX = 0.0
    var sumY = 0.0
    for touch in touches {
      sumX += touch.x
      sumY += touch.y
    }
    let count = Double(touches.count)
    return CGPoint(x: sumX / count, y: sumY / count)
  }

  private static func averageDistance(_ touches: [TouchPoint], from centroid: CGPoint) -> Double {
    guard !touches.isEmpty else { return 0 }
    var total = 0.0
    for touch in touches {
      total += hypot(touch.x - centroid.x, touch.y - centroid.y)
    }
    return total / Double(touches.count)
  }
}

/// 系统的四指 / 五指捏合手势开没开（只读；SPEC §5.6）。`com.apple.AppleMultitouchTrackpad` 是内置触控板，
/// 蓝牙妙控板在 `com.apple.driver.AppleBluetoothMultitouch.trackpad`。实测（27.0.1）两个键都是 2 = 开，
/// 0 = 关；这里按「非 0 且存在 = 开」认（没存过 = 关，和系统默认一致）。**只读，不写、不重启 Dock**。
nonisolated enum TrackpadSystemGesture {
  static let fourFingerKey = "TrackpadFourFingerPinchGesture"
  static let fiveFingerKey = "TrackpadFiveFingerPinchGesture"
  static let domains = [
    "com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad",
  ]

  /// 一个域里的两个键（注入的 UserDefaults 给单测）
  static func pinchIsOn(_ defaults: UserDefaults) -> Bool {
    let four = defaults.object(forKey: fourFingerKey) as? Int ?? 0
    let five = defaults.object(forKey: fiveFingerKey) as? Int ?? 0
    return four != 0 || five != 0
  }

  /// 本机（两个域任一开着）
  static func systemPinchIsOn() -> Bool {
    domains.contains { domain in
      UserDefaults(suiteName: domain).map(pinchIsOn) ?? false
    }
  }
}
