// 触控板捏合的识别器（SPEC §5.6、R7；2026-10-19 起跟手，拍板页 build/research/launchpad/GESTURE.md A）：纯状态机，
// 输入一帧帧触点（时间 + 各指在触控板上的归一化位置），输出「开始捏 / 开始张开」「松手（进度 + 速度）」「取消」，
// 跟着的那一下每帧的进度（0…1）放在 `progress` 里（桥每帧拷给主线程的屏幕刷新回调读）。不碰框架、不碰窗口，单测直接喂造好的帧序列。
// 规则（数值写在这里、也写进 mac-launchpad.mdc §6）：
// - 四指捏合认正好 4 指、五指捏合认 5 指及以上（设置 › 启动台「触控板手势」选哪种，`PinchFingers`）；
// - 比例 = 所有指到质心的平均距离 ÷ 落指时的距离。缩了 / 涨了 `beginRatio`（4%）、质心挪动不超过 `beginTravel`、
//   且距离的变化不小于质心的挪动（捏合是往里收，横扫是整体平移）= 开始；
// - 进度：捏合 = (1 − 比例) ÷ (1 − pinchRatio)，张开 = (比例 − 1) ÷ (spreadRatio − 1)，夹在 0…1；灵敏度三档只改这两个「满格」比例；
// - 跟着的时候质心挪动超过 maxTravel = 其实是四指横扫 / 竖扫，取消；手指数变少（抬手是一根根离开的）= 松手，变多 = 取消；
// - 一次手势只出一次结果；取消之后等手指数变了才重来；落指后一直没开始、放了超过 maximumDuration 就以现在为新起点。
// 松手后打开还是缩回由 `completes(progress:velocity:)` 定（纯函数）。
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

/// 用几根手指捏（设置 › 启动台「触控板手势」，`Prefs.launchpadPinchGesture` 存 rawValue；默认四指，同系统的拇指和三指）。
/// 四指只认正好 4 根：五指的手势留给别的；五指认 5 根及以上：和四指的横扫（切换桌面、调度中心）完全错开
nonisolated enum PinchFingers: String, CaseIterable, Sendable {
  case off, four, five

  var title: String {
    switch self {
    case .off: "关闭"
    case .four: "四指捏合"
    case .five: "五指捏合"
    }
  }

  func accepts(_ count: Int) -> Bool {
    switch self {
    case .off: false
    case .four: count == 4
    case .five: count >= 5
    }
  }
}

nonisolated struct PinchRecognizer: Sendable {
  enum Gesture: Equatable, Sendable {
    case pinch
    case spread
  }

  /// 识别器往外报的三件事（每帧的进度不算事件，看 `progress`）
  enum Event: Equatable, Sendable {
    case began(Gesture)
    /// 松手：松手前最后的进度、速度（满格 / 秒，正 = 进度在涨）
    case ended(Gesture, progress: Double, velocity: Double)
    case cancelled(Gesture)
  }

  /// 灵敏度（设置 › 启动台；数值是捏到 / 张到原来的多少算「满格」：画面走满、松手一定打开）
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

  /// 比例变了这么多算开始（再小就是手指放着的抖动）
  static let beginRatio = 0.04
  /// 开始时质心最多挪这么多（归一化单位）
  static let beginTravel = 0.05
  /// 跟着的时候质心挪动超过这么多 = 横扫 / 竖扫，取消
  static let maxTravel = 0.22
  /// 落指后这么久之内不算开始（落指那几帧接触面还在变，比例会抖）
  static let minimumDuration = 0.04
  /// 落指后放了这么久还没开始：以现在为新起点（手指先搁着再捏也认）
  static let maximumDuration = 1.4
  /// 松手的判定：朝打开方向这么快（满格 / 秒）一定打开，朝回这么快一定缩回，都不是就看过没过一半
  static let flickVelocity = 1.5
  static let backVelocity = 1.0
  static let half = 0.5

  var sensitivity: Sensitivity
  var fingers: PinchFingers

  init(sensitivity: Sensitivity = .standard, fingers: PinchFingers = .four) {
    self.sensitivity = sensitivity
    self.fingers = fingers
  }

  /// 正在跟的那一下的进度（0…1）；没在跟 = nil
  private(set) var progress: Double?
  private var tracking: Gesture?
  private var velocity = 0.0
  private var lastTime = 0.0
  private var startDistance: Double?
  private var startCentroid = CGPoint.zero
  private var startTime: Double = 0
  private var fingerCount = 0
  /// 这一下取消了：等手指数变了再重来
  private var latched = false

  mutating func reset() {
    progress = nil
    tracking = nil
    velocity = 0
    lastTime = 0
    startDistance = nil
    startCentroid = .zero
    startTime = 0
    fingerCount = 0
    latched = false
  }

  /// 喂一帧；开始 / 松手 / 取消时返回那件事
  mutating func feed(_ frame: TouchFrame) -> Event? {
    // 只认「按在面上」的 3 / 4：悬停（1 / 2）和抬起中（5 / 6）都不算（F25）。空帧 = 全抬起来了
    let touching = frame.touches.filter { $0.state == 3 || $0.state == 4 }
    if touching.count != fingerCount {
      let lifted = touching.count < fingerCount
      fingerCount = touching.count
      startDistance = nil
      latched = false
      if let gesture = tracking {
        // 松手按松手之前那一帧的进度和速度算：抬手那一帧剩下的手指位置会跳
        let event: Event =
          lifted
          ? .ended(gesture, progress: progress ?? 0, velocity: velocity) : .cancelled(gesture)
        stopTracking()
        return event
      }
    }
    guard fingers.accepts(touching.count), !latched else { return nil }
    let centroid = Self.centroid(touching)
    let distance = Self.averageDistance(touching, from: centroid)
    guard let startDistance, startDistance > 0.001 else {
      setStart(distance: distance, centroid: centroid, time: frame.time)
      return nil
    }
    let ratio = distance / startDistance
    let travel = hypot(centroid.x - startCentroid.x, centroid.y - startCentroid.y)
    if let gesture = tracking {
      guard travel <= Self.maxTravel else {
        stopTracking()
        latched = true
        return .cancelled(gesture)
      }
      let next = Self.progress(of: gesture, ratio: ratio, sensitivity: sensitivity)
      let dt = max(frame.time - lastTime, 0.004)
      velocity = velocity * 0.55 + ((next - (progress ?? next)) / dt) * 0.45
      progress = next
      lastTime = frame.time
      return nil
    }
    let duration = frame.time - startTime
    if duration > Self.maximumDuration {
      setStart(distance: distance, centroid: centroid, time: frame.time)
      return nil
    }
    guard duration >= Self.minimumDuration, travel <= Self.beginTravel,
      abs(distance - startDistance) >= travel
    else { return nil }
    let gesture: Gesture
    if ratio <= 1 - Self.beginRatio {
      gesture = .pinch
    } else if ratio >= 1 + Self.beginRatio {
      gesture = .spread
    } else {
      return nil
    }
    tracking = gesture
    progress = Self.progress(of: gesture, ratio: ratio, sensitivity: sensitivity)
    velocity = 0
    lastTime = frame.time
    return .began(gesture)
  }

  /// 比例换成进度（0…1）
  static func progress(of gesture: Gesture, ratio: Double, sensitivity: Sensitivity) -> Double {
    let raw =
      switch gesture {
      case .pinch: (1 - ratio) / (1 - sensitivity.pinchRatio)
      case .spread: (ratio - 1) / (sensitivity.spreadRatio - 1)
      }
    return min(max(raw, 0), 1)
  }

  /// 松手后走完（true）还是缩回（false）：同翻页，看位移或快甩
  static func completes(progress: Double, velocity: Double) -> Bool {
    if velocity >= flickVelocity { return true }
    if velocity <= -backVelocity { return false }
    return progress >= half
  }

  private mutating func setStart(distance: Double, centroid: CGPoint, time: Double) {
    startDistance = distance
    startCentroid = centroid
    startTime = time
  }

  private mutating func stopTracking() {
    tracking = nil
    progress = nil
    velocity = 0
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
/// 0 = 关；这里按「两个键都没存过 = 这个域没信息、显式 0 = 关」认，几个域合起来见 `combined`（F13 / G5）。
/// **只读，不写、不重启 Dock**。
nonisolated enum TrackpadSystemGesture {
  static let fourFingerKey = "TrackpadFourFingerPinchGesture"
  static let fiveFingerKey = "TrackpadFiveFingerPinchGesture"
  static let domains = [
    "com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad",
  ]

  /// 一个域里的两个键（注入的 UserDefaults 给单测）：nil = 这个域里没有信息（两个键都没存过）
  static func pinchSetting(_ defaults: UserDefaults) -> Bool? {
    let four = defaults.object(forKey: fourFingerKey) as? Int
    let five = defaults.object(forKey: fiveFingerKey) as? Int
    if four == nil, five == nil { return nil }
    return (four ?? 0) != 0 || (five ?? 0) != 0
  }

  /// 单个域的读法：没信息按系统默认开（F13）
  static func pinchIsOn(_ defaults: UserDefaults) -> Bool { pinchSetting(defaults) ?? true }

  /// 几个域合起来（纯函数，G5）：任一域显式开着 = 开；有域显式关了、没有显式开的 = 关；所有域都没信息才按系统默认开。
  /// 原来是对每个域「没信息就算开」再取或：没配过蓝牙触控板的 Mac 上那个域是空的，用户关了系统手势也永远算开着
  static func combined(_ settings: [Bool?]) -> Bool {
    if settings.contains(true) { return true }
    if settings.contains(false) { return false }
    return true
  }

  /// 本机的两个域
  static func systemPinchIsOn() -> Bool {
    combined(domains.map { domain in UserDefaults(suiteName: domain).flatMap(pinchSetting) })
  }
}
