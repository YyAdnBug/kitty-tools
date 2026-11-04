// 提醒的执行层（PLAN §10「提醒」）：只挂一个计时任务，指向最近要响的那一刻；醒来、解锁、改系统时间、换时区、换日、
// 列表变了时重新看一遍（ReminderCheck.check，纯函数）。到点的挂在刘海岛上直到处理（Island.pin，C2），几条同时到点合成一条
// （B5），错过的（晚了超过 5 分钟：睡着、锁着屏、App 没开）合成一条「错过了 N 个提醒」（B4）。
// 「知道了」（或岛上的 ×、双指上滑）：一次的从列表里删掉（D7），间隔的从这一刻重新数；「稍后」推 N 分钟（C8，设置 › 提醒）。
// 间隔提醒碰上锁屏、醒来、5 分钟没碰键盘鼠标，算休息过了，回来重新数（B3）：有开着的间隔提醒时每分钟看一眼空闲了多久，
// 没有就不看。锁着屏时一条都不响，解锁后再看（晚了 5 分钟以内照常响）。
// 第 1 批只有轻提醒和提示音：边框、全屏、进入状态屏、朗读、催促、录屏时降级、状态屏里排着在第 2 批，
// 现在都按轻提醒出（ponytail：第 2 批换成各自的方式）。
// 状态（每条处理到哪一刻、推到几点）存在 Prefs.remindersState：这台电脑自己的，不导出；间隔的锚点只在内存里（重启就是重新数）。
// 起停跟着功能开关（AppDelegate.applyFeatures）；关掉时岛上挂着的收掉，数据和状态不动。

import AppKit

@MainActor final class ReminderCenter {
  var island: Island?
  private let defaults: UserDefaults
  private var isRunning = false
  private var list: [Reminder] = []
  /// 上一次读到的列表原样：偏好变了先比这个，自己写的、别的键变了都不重来
  private var listData: Data?
  private var state = ReminderState()
  /// 间隔提醒从哪一刻数起（B3），连着记下当时的时间规则：改了规则从改的那一刻重新数
  private var anchors: [String: Date] = [:]
  private var anchorRules: [String: Reminder.Schedule] = [:]
  /// 正挂在岛上的：到点的、错过的（按出现的顺序）
  private var firing: [String] = []
  private var missed: [String] = []
  private var isLocked = false
  /// 5 分钟以上没碰键盘鼠标：间隔提醒先不响，回来重新数
  private var isAway = false
  private var wake: Task<Void, Never>?
  private var idlePoll: Task<Void, Never>?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  /// 多久没碰键盘鼠标算离开了（B3）
  static let awayAfter: TimeInterval = 5 * 60

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    observe()
    listData = defaults.data(forKey: Prefs.reminders)
    list = Reminder.decode(listData)
    state = ReminderState.decode(defaults.data(forKey: Prefs.remindersState))
    restartIntervals(at: .now)
    reconcile()
    check()
  }

  /// 功能关掉：计时、监听都停，岛上挂着的收掉；状态留着，打开后接着算（错过的照样告诉你）
  func stop() {
    guard isRunning else { return }
    isRunning = false
    wake?.cancel()
    idlePoll?.cancel()
    idlePoll = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    if !firing.isEmpty || !missed.isEmpty { island?.unpin() }
    firing = []
    missed = []
    anchors = [:]
    anchorRules = [:]
    // 再打开时当成没锁、没离开（关着的这段时间收不到解锁和空闲的变化）
    isLocked = false
    isAway = false
  }

  /// 偏好变了（AppDelegate 看着 UserDefaults 的变化调）：只有列表变了才重新看
  func defaultsChanged() {
    guard isRunning else { return }
    let data = defaults.data(forKey: Prefs.reminders)
    guard data != listData else { return }
    listData = data
    let old = list
    list = Reminder.decode(data)
    // 删掉的、关掉的、改了时间的不再挂着（改了时间的按新时间再算，reconcile 从现在起）；还在的换上新标题
    let before = (firing, missed)
    let on = Set(list.filter(\.isOn).map(\.id)).subtracting(
      ReminderCheck.rescheduled(from: old, to: list))
    firing = firing.filter(on.contains)
    missed = missed.filter(on.contains)
    reconcile()
    if firing != before.0 || missed != before.1 || !firing.isEmpty || !missed.isEmpty { present() }
    check()
  }

  // MARK: 看一遍

  private var snoozeMinutes: Int {
    let value = defaults.integer(forKey: Prefs.remindersSnoozeMinutes)
    return Reminder.snoozeChoices.contains(value) ? value : Reminder.snoozeChoices[0]
  }

  /// 状态跟上列表：每周 / 每月的处理记录、间隔的锚点（新开的、改了规则的从现在数）；空闲检查按有没有间隔提醒起停
  private func reconcile() {
    let now = Date.now
    let next = ReminderCheck.reconciled(state, with: list, now: now)
    if next != state {
      state = next
      saveState()
    }
    let intervals = list.filter { $0.isOn && $0.schedule.kind == .interval }
    var anchors: [String: Date] = [:]
    var rules: [String: Reminder.Schedule] = [:]
    for reminder in intervals {
      rules[reminder.id] = reminder.schedule
      let same = anchorRules[reminder.id] == reminder.schedule
      // 正挂着的没有锚点（处理了才从那一刻数），规则没变就别给它补一个
      if same, firing.contains(reminder.id) || missed.contains(reminder.id) { continue }
      anchors[reminder.id] = same ? self.anchors[reminder.id] ?? now : now
    }
    self.anchors = anchors
    anchorRules = rules
    watchIdle(intervals.isEmpty == false)
  }

  /// 间隔提醒都从 date 重新数（启动、醒来、解锁、离开电脑回来），推过的也作废（算休息过了）；正挂着的不动
  private func restartIntervals(at date: Date) {
    var cleared = false
    for reminder in list where reminder.isOn && reminder.schedule.kind == .interval {
      if firing.contains(reminder.id) || missed.contains(reminder.id) { continue }
      anchors[reminder.id] = date
      anchorRules[reminder.id] = reminder.schedule
      if state.snoozed.removeValue(forKey: reminder.id) != nil { cleared = true }
    }
    if cleared { saveState() }
  }

  private func check() {
    guard isRunning else { return }
    wake?.cancel()
    let now = Date.now
    // 到点前一刻才离开的，等不到下一次空闲检查：有间隔提醒要看时现读一次
    if !isAway, idlePoll != nil, Self.idleSeconds() >= Self.awayAfter { isAway = true }
    let result = ReminderCheck.check(
      list, state: state, anchors: anchors, showing: Set(firing + missed), now: now,
      held: isLocked, away: isAway, calendar: .current)
    let fresh = result.fire + result.missed
    if !fresh.isEmpty {
      for id in fresh {
        state.snoozed[id] = nil
        // 一次性的不挪：没点「知道了」就退出了，下次打开还要告诉你
        if list.first(where: { $0.id == id })?.schedule.kind != .once { state.marks[id]?.at = now }
        anchors[id] = nil  // 间隔的：挂着期间不再数，处理了从那一刻数
      }
      firing += result.fire
      missed += result.missed
      saveState()
      present()
      chime(for: result.fire)
    }
    guard let next = result.next else { return }
    wake = Task { [weak self] in
      try? await Task.sleep(
        for: .seconds(max(next.timeIntervalSinceNow, 0) + 0.05), tolerance: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.check()
    }
  }

  // MARK: 岛

  /// 把挂着的（到点的 + 错过的）合成一条挂在岛上；都没有了就收掉
  private func present() {
    guard let island else { return }
    let fired = firing.compactMap { id in list.first { $0.id == id } }
    let lost = missed.compactMap { id in list.first { $0.id == id } }
    guard let notice = Self.notice(fired: fired, missed: lost) else { return island.unpin() }
    // 第一个是主按钮（露在行尾）
    var actions = [Island.Action("知道了") { [weak self] in self?.acknowledge() }]
    if !fired.isEmpty {
      actions.append(Island.Action("稍后 \(snoozeMinutes) 分钟") { [weak self] in self?.snooze() })
    }
    island.pin(notice.title, detail: notice.detail, symbol: "alarm.fill", actions: actions) {
      [weak self] in self?.acknowledge()
    }
  }

  /// 岛上那一条写什么（纯函数）：到点的标题连在一起（只有一条时带它的说明），错过的写在详情里；只有错过的时
  /// 「错过了提醒：喝水」/「错过了 3 个提醒」+ 是哪几个
  static func notice(fired: [Reminder], missed: [Reminder]) -> (title: String, detail: String?)? {
    let lostTitles = missed.map(\.title).joined(separator: "、")
    if fired.isEmpty {
      guard let first = missed.first else { return nil }
      return missed.count == 1
        ? ("错过了提醒：\(first.title)", first.detail) : ("错过了 \(missed.count) 个提醒", lostTitles)
    }
    var detail = fired.count == 1 ? fired[0].detail : nil
    if !missed.isEmpty {
      let line = "还错过了：" + lostTitles
      detail = detail.map { $0 + "；" + line } ?? line
    }
    return (fired.map(\.title).joined(separator: " · "), detail)
  }

  /// 「知道了」：挂着的都算处理了
  private func acknowledge() {
    let handled = firing + missed
    firing = []
    missed = []
    finish(handled)
  }

  /// 「稍后」：到点的推 N 分钟；一起挂着的错过的算处理了
  private func snooze() {
    let until = Date.now.addingTimeInterval(TimeInterval(snoozeMinutes * 60))
    for id in firing { state.snoozed[id] = until }
    let handled = missed
    firing = []
    missed = []
    finish(handled)
  }

  /// 处理完：一次的从列表里删掉（D7；推过的不删，它还要再响），间隔的从这一刻重新数，岛收掉，再看一遍
  private func finish(_ handled: [String]) {
    let now = Date.now
    var removed: Set<String> = []
    for id in handled {
      guard let reminder = list.first(where: { $0.id == id }) else { continue }
      switch reminder.schedule.kind {
      case .once: removed.insert(id)
      case .interval:
        anchors[id] = now
        anchorRules[id] = reminder.schedule
      case .weekly, .monthly: break
      }
    }
    if !removed.isEmpty {
      list.removeAll { removed.contains($0.id) }
      listData = Reminder.encoded(list)
      defaults.set(listData, forKey: Prefs.reminders)
      state = ReminderCheck.reconciled(state, with: list, now: now)
    }
    saveState()
    island?.unpin()
    check()
  }

  /// 提示音（C9，只响一声）：几条一起到点时响第一条选的。朗读第 2 批做（ponytail：现在选了朗读的不出声）
  private func chime(for ids: [String]) {
    guard
      let reminder = ids.lazy.compactMap({ id in self.list.first { $0.id == id } })
        .first(where: { $0.sound == .chime })
    else { return }
    NSSound(named: reminder.chime)?.play()
  }

  private func saveState() {
    defaults.set(state.encoded, forKey: Prefs.remindersState)
  }

  // MARK: 系统事件

  private func observe() {
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    let local = NotificationCenter.default
    add(distributed, .init("com.apple.screenIsLocked")) { $0.isLocked = true }
    // 解锁、醒来：间隔提醒算休息过了；锁着时到点的这会儿再看（晚了 5 分钟以内照常响）
    add(distributed, .init("com.apple.screenIsUnlocked")) {
      $0.isLocked = false
      $0.isAway = false
      $0.restartIntervals(at: .now)
      $0.check()
    }
    add(workspace, NSWorkspace.didWakeNotification) {
      $0.isAway = false
      $0.restartIntervals(at: .now)
      $0.check()
    }
    // 系统时间往回调过：记在「将来」的时刻收回来，不然要等真实时间追上才响
    add(local, .NSSystemClockDidChange) {
      let max = TimeInterval((Reminder.snoozeChoices.last ?? 30) * 60)
      let pulled = $0.state.pulledBack(now: .now, maxSnooze: max)
      if pulled != $0.state {
        $0.state = pulled
        $0.saveState()
      }
      $0.check()
    }
    for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
      add(local, name) { $0.check() }
    }
  }

  private func add(
    _ center: NotificationCenter, _ name: Notification.Name,
    _ handle: @escaping @MainActor (ReminderCenter) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isRunning else { return }
        handle(self)
      }
    }
    observers.append((center, token))
  }

  /// 有开着的间隔提醒时每分钟看一眼空闲了多久（B3）：离开 5 分钟以上先不响，回来从回来那一刻重新数
  private func watchIdle(_ needed: Bool) {
    guard needed else {
      idlePoll?.cancel()
      idlePoll = nil
      isAway = false
      return
    }
    guard idlePoll == nil else { return }
    idlePoll = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
        guard !Task.isCancelled else { return }
        self?.pollIdle()
      }
    }
  }

  private func pollIdle() {
    let idle = Self.idleSeconds()
    if idle >= Self.awayAfter {
      guard !isAway else { return }
      isAway = true
      check()
    } else if isAway {
      isAway = false
      restartIntervals(at: Date.now.addingTimeInterval(-idle))
      check()
    }
  }

  /// 离上一次碰键盘鼠标过了几秒（不要授权；同程序坞预览判断点没点过鼠标的读法）
  static func idleSeconds() -> TimeInterval {
    let types: [CGEventType] = [
      .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      .leftMouseDragged, .scrollWheel,
    ]
    return types.map {
      CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
    }.min() ?? 0
  }
}
