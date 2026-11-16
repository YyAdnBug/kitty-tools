// 保持唤醒（第一个插件，2026-11-12 拍板 B2，PLAN §10「保持唤醒」）的执行层：手动开的一段（无限期 / 到某一刻）和设置里的
// 定时，哪个在生效就让系统别睡。做法同状态屏的「电源」：ProcessInfo.beginActivity（StatusScreen.activityOptions，屏幕也不熄 =
// displayOn，否则只防系统闲置睡眠）——不起 caffeinate、不要授权，Kitty 退出时系统自动收回。合上盖子照样睡（系统规定）。
// - 手动的一段不跨重启（免得忘了一直亮着）；定时那一段开着就跟着时段走，手动开的优先（时段结束时手动的还没到点就接着）。
// - 没开、没在时段里时什么都不跑：只有一个等到「下一次要变」的 Task（手动那段到点、时段的下一个边界），醒来、改系统时间、
//   换时区、偏好变了（定时、屏幕熄不熄）重新算一遍。
// - 插件移除（功能开关关掉）= stop()：停掉、不再听。开始 / 结束在岛上说一声（announce，AppDelegate 接刘海岛）。
// - 手动开的那一段是刘海岛上的一个活动（2026-11-13，刘海岛扩展拍板 C3）：左耳杯子、右耳倒数（无限期不写数），点开有
//   「停止」；没刘海时是菜单栏那一项。定时那一段不上（每天自动开，天天挂着是噪音）。每次重新算完跟一次（syncIsland）。

import AppKit

@MainActor @Observable final class KeepAwake {
  /// 手动开的那一段到什么时候（.distantFuture = 无限期）；nil = 没开
  private(set) var sessionEnd: Date?
  /// 定时那一段此刻生效着
  private(set) var inSchedule = false

  /// 正在保持唤醒（手动的或定时的）
  var isActive: Bool { sessionEnd != nil || inSchedule }
  /// 手动开的是无限期
  var isIndefinite: Bool { sessionEnd == .distantFuture }

  /// 岛上说一声（标题、说明）
  @ObservationIgnored var announce: (String, String?) -> Void = { _, _ in }
  /// 手动开的那一段挂在它上面（AppDelegate 接；单测里是 nil）
  @ObservationIgnored weak var island: Island?
  static let islandActivity = "keep-awake"

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var activity: NSObjectProtocol?
  @ObservationIgnored private var activeDisplay: Bool?
  @ObservationIgnored private var wake: Task<Void, Never>?
  @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  /// 上次算的时候定时是什么样（定时被改了引起的进出时段不在岛上说：人正看着设置页）
  @ObservationIgnored private var lastSchedule: KeepAwakePlan.Schedule?
  @ObservationIgnored private(set) var isRunning = false

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var schedule: KeepAwakePlan.Schedule {
    .decode(defaults.string(forKey: Prefs.keepAwakeSchedule) ?? "")
  }

  /// 屏幕也不熄（默认开：要的就是防息屏）
  var keepsDisplayOn: Bool { defaults.object(forKey: Prefs.keepAwakeDisplay) as? Bool ?? true }

  /// 「还剩 1 小时 12 分」「无限期」「定时 · 到 18:00」：菜单栏、启动器、设置页现在那一行
  func status(now: Date = .now, calendar: Calendar = .current) -> String {
    if let end = sessionEnd {
      return KeepAwakePlan.remaining(until: isIndefinite ? nil : end, now: now)
    }
    return inSchedule ? "定时 · " + scheduleUntil(now: now, calendar: calendar) : "没开"
  }

  /// 定时那一段管到哪：「到 18:00」；一直在时段里（每天全天）的是「一直开着」
  private func scheduleUntil(now: Date = .now, calendar: Calendar = .current) -> String {
    guard let until = schedule.nextChange(after: now, calendar: calendar) else { return "一直开着" }
    return "到 " + KeepAwakePlan.moment(until, now: now, calendar: calendar)
  }

  // MARK: 起停（插件添加 / 移除）

  func start() {
    guard !isRunning else { return }
    isRunning = true
    observe()
    evaluate(announcing: false)
  }

  func stop() {
    guard isRunning else { return }
    // 手动开着一段时移除插件（卡片、设置页、同步来的）：说一声，不悄悄停
    if sessionEnd != nil { announce("已停止保持唤醒", "插件移除了，电脑会照常睡") }
    isRunning = false
    lastSchedule = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    sessionEnd = nil
    inSchedule = false
    wake?.cancel()
    wake = nil
    apply(false)
    syncIsland()
  }

  /// 上次挂到岛上的样子（nil = 没挂）：偏好一变就重新算一遍，样子没变就不重挂——不然每次都让岛重画、读数的秒拍重来
  @ObservationIgnored private var hung: Hung?

  struct Hung: Equatable {
    var end: Date
    var display: Bool
  }

  /// 岛上的活动跟上：手动那一段开着就挂（再挂一次 = 原地换读数），没开就收。force：岛那边可能把它丢了
  /// （刘海岛插件刚添加：没添加时岛不收活动），照现在的样子重挂一次（AppDelegate.applyFeatures 调）
  func syncIsland(force: Bool = false) {
    let wanted = sessionEnd.map { Hung(end: $0, display: keepsDisplayOn) }
    guard force || wanted != hung else { return }
    hung = wanted
    guard let end = sessionEnd else {
      island?.endActivity(Self.islandActivity)
      return
    }
    island?.setActivity(
      Self.activity(until: isIndefinite ? nil : end, display: keepsDisplayOn) { [weak self] in
        self?.end()
      })
  }

  /// 手动那一段在岛上的样子（纯函数）：until 是 nil = 无限期，右耳不写数；卡片上一个「停止」
  static func activity(until: Date?, display: Bool, stop: @escaping () -> Void) -> Island.Activity {
    Island.Activity(
      id: islandActivity, kind: .awake, title: "保持唤醒", detail: display ? "屏幕也不熄" : "屏幕照常熄",
      symbol: "cup.and.saucer.fill", trailing: until.map { .countdown(to: $0) } ?? .none,
      actions: [Island.Action("停止", run: stop)])
  }

  // MARK: 手动的一段

  /// 开一段：until 是结束的时刻，nil = 无限期；已经开着的换成这一段
  func begin(until: Date?, label: String) {
    guard isRunning else { return }
    sessionEnd = until ?? .distantFuture
    evaluate(announcing: false)
    let screen = keepsDisplayOn ? "屏幕也不熄" : "屏幕照常熄"
    announce("保持唤醒 · " + label, until == nil ? "直到你停止 · " + screen : screen)
  }

  /// 停掉手动的那一段（定时的时段里照样保持唤醒，岛上说清楚）
  func end() {
    guard sessionEnd != nil else { return }
    sessionEnd = nil
    evaluate(announcing: false)
    announce("已停止保持唤醒", inSchedule ? "定时还在，" + scheduleUntil() : "电脑会照常睡")
  }

  /// 快捷键、主界面、启动器那一项：开着就停，没开就开无限期
  func toggle() {
    if sessionEnd != nil {
      end()
    } else {
      begin(until: nil, label: "无限期")
    }
  }

  // MARK: 重新算

  /// 看手动那段到点了没、在不在时段里，让断言跟上；排下一次要变的时刻。announcing：这次进出时段要不要在岛上说——
  /// 定时被改了引起的不说（人正看着设置页），开始时那一下不说；手动那段到点总要说（不是人点的），和进出时段同时发生的并成一句
  private func evaluate(announcing: Bool, now: Date = .now) {
    guard isRunning else { return }
    let calendar = Calendar.current
    let plan = schedule
    let edited = lastSchedule.map { $0 != plan } ?? true
    lastSchedule = plan
    let inside = plan.contains(now, calendar: calendar)
    let enteredOrLeft = inside != inSchedule
    inSchedule = inside
    var expired = false
    if let end = sessionEnd, end <= now {
      sessionEnd = nil
      expired = true
    }
    if expired {
      announce("保持唤醒到点了", inside ? "定时还在，" + scheduleUntil(now: now) : "电脑会照常睡")
    } else if announcing, enteredOrLeft, !edited, sessionEnd == nil {
      announce(
        inside ? "按时段保持唤醒" : "时段结束，不再保持唤醒", inside ? plan.summary : "电脑会照常睡")
    }
    apply(isActive)
    syncIsland()
    wake?.cancel()
    let next = [
      sessionEnd == .distantFuture ? nil : sessionEnd,
      plan.nextChange(after: now, calendar: calendar),
    ]
    .compactMap { $0 }.min()
    guard let next else {
      wake = nil
      return
    }
    // 连续时钟：合盖睡着时也在走，醒来就到点（另有醒来的通知兜底）
    wake = Task { [weak self] in
      try? await Task.sleep(
        for: .seconds(max(next.timeIntervalSinceNow, 0) + 0.05), tolerance: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.evaluate(announcing: true)
    }
  }

  /// 断言跟上：要开、开着的屏幕档位不对就换（先起新的再还旧的，中间不留空档）；不要了就还掉
  private func apply(_ on: Bool) {
    let display = keepsDisplayOn
    guard on else {
      if let activity { ProcessInfo.processInfo.endActivity(activity) }
      activity = nil
      activeDisplay = nil
      return
    }
    guard activeDisplay != display,
      let options = StatusScreen.activityOptions(display ? .displayOn : .awake)
    else { return }
    let next = ProcessInfo.processInfo.beginActivity(options: options, reason: "保持唤醒")
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = next
    activeDisplay = display
  }

  // MARK: 系统事件

  private func observe() {
    let workspace = NSWorkspace.shared.notificationCenter
    let local = NotificationCenter.default
    for (center, name) in [
      (workspace, NSWorkspace.didWakeNotification), (local, .NSSystemClockDidChange),
      (local, .NSSystemTimeZoneDidChange), (local, UserDefaults.didChangeNotification),
    ] {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.evaluate(announcing: true)
        }
      }
      observers.append((center, token))
    }
  }
}
