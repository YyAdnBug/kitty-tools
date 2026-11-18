// 刘海岛的几声提示音（2026-11-17，照 Alcove：拍板页 7XAhtx3TEY8AJkJyiHcVE2 B、C8、C9）：整点报时、日程开始时、睡眠模式打开时。
// 都是系统自带的提示音，设置 › 刘海岛 里各一个开关、默认关。正在录屏 / 录音时都不响（不然录进去）；开着专注模式时只有
// 睡眠那一声响（整点、日程那两声算打扰）。
// 整点报时（HourlyChime）：一个任务睡到下一个整点，到点响一声；电脑睡着过了整点的（醒来时晚了 1 分钟以上）不补。
// ponytail: 睡着的时候改了系统时间、换了时区，那一次照原来算的时刻响（下一个整点就对了）；要准就接 NSSystemClockDidChange。

import AppKit

enum Chime {
  /// 整点、日程开始、睡眠模式打开时各响哪一声（系统自带的提示音名）
  enum Sound: String {
    case hourly = "Tink"
    case event = "Glass"
    case sleep = "Purr"
  }

  /// 正在录屏 / 录音（AppDelegate 给）
  static var isRecording: () -> Bool = { false }

  /// 响一声：录着时不响；开着专注模式时只有 duringFocus 的响
  static func play(_ sound: Sound, duringFocus: Bool = false) {
    guard !isRecording(), duringFocus || SystemFocus.shared.current == nil else { return }
    NSSound(named: sound.rawValue)?.play()
  }
}

/// 整点报时（设置 › 刘海岛「日程」那一节，默认关）：刘海岛插件添加着、开关开着才有一个任务等着
final class HourlyChime {
  private var task: Task<Void, Never>?
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 照偏好起停（启动时、偏好变了时 AppDelegate 调）；没变不动
  func apply() {
    let on = Feature.island.isOn && defaults.bool(forKey: Prefs.islandHourlyChime)
    if on, task == nil {
      task = Task { await Self.run() }
    } else if !on, let task {
      task.cancel()
      self.task = nil
    }
  }

  private static func run() async {
    var last = Date.distantPast
    while !Task.isCancelled {
      // 从刚响过的那个整点之后算：连续时钟和墙上的钟有漂移，醒早了几十毫秒时 .now 还在整点前，会把同一个整点算两遍（评审）
      let next = nextHour(after: max(.now, last))
      // 连续时钟：合盖睡着时也在走，醒来就到点——晚了 1 分钟以上的不响
      try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.05), tolerance: .seconds(1))
      guard !Task.isCancelled else { return }
      if isOnTime(next, now: .now) { Chime.play(.hourly) }
      last = next
    }
  }

  /// 下一个整点（纯函数）
  nonisolated static func nextHour(after date: Date, calendar: Calendar = .current) -> Date {
    calendar.nextDate(
      after: date, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
      ?? date.addingTimeInterval(3600)
  }

  /// 醒来时才到的不算（纯函数）：离整点 1 分钟以内才响
  nonisolated static func isOnTime(_ hour: Date, now: Date) -> Bool {
    abs(now.timeIntervalSince(hour)) < 60
  }
}
