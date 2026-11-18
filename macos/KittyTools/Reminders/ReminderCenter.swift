// 提醒的执行层（PLAN §10「提醒」）：只挂一个计时任务，指向最近要响的那一刻；醒来、解锁、改系统时间、换时区、换日、
// 列表变了时重新看一遍（ReminderCheck.check，纯函数）。到点的挂在刘海岛上直到处理（Island.pin，C2），几条同时到点合成一条
// （B5），错过的（晚了超过 5 分钟：睡着、锁着屏、App 没开）合成一条「错过了 N 个提醒」（B4）。
// 「知道了」（或在岛上双指上滑）：一次的从列表里删掉（D7），间隔的从这一刻重新数；「稍后」推 N 分钟（C8，设置 › 提醒）。
// 间隔提醒碰上锁屏、醒来、5 分钟没碰键盘鼠标，算休息过了，回来重新数（B3）：有开着的间隔提醒时每分钟看一眼空闲了多久，
// 没有就不看。锁着屏时一条都不响，解锁后再看（晚了 5 分钟以内照常响）。
// 方式（C1，第 2 批）：几条一起到点时按最显眼的那条（状态屏 > 全屏 > 边框 > 轻提醒）；轻提醒挂在岛上，边框 = 四边的光 + 岛，
// 全屏 = ReminderScreen（岛上不再挂），进入状态屏 = 到点直接进那个状态、算处理了（进不去时退成全屏，底板上说为什么，C12）。
// 正在录屏、录音时全都降成轻提醒、也不出声（C11，不然录进去）；在状态屏里、锁着屏时一条都不响，退出 / 解锁后再看。
// ponytail: 已经出来的边框 / 全屏，之后才开始录屏的不收（会录进去）；要的话在录屏开始时调一次 present。
// 声音（C9）：提示音或朗读标题，只响一声（提示音可以是自己选的文件，最多 30 秒、处理了就停，ReminderSound）。催促（C10）：岛上挂着没理的，每隔 N 分钟再响一声、岛晃一下，第 3 次换成全屏，
// 之后不再催。
// 状态（每条处理到哪一刻、推到几点）存在 Prefs.remindersState：这台电脑自己的，不导出；间隔的锚点只在内存里（重启就是重新数）。
// 起停跟着功能开关（AppDelegate.applyFeatures）；关掉时岛上挂着的收掉，数据和状态不动。
// 倒数（2026-11-13，刘海岛扩展 C2）：一小时以内要响的一次性提醒（「提醒 10分钟 喝水」）挂在刘海岛的耳朵上倒数，只挂最近的
// 那一条；点开能「提前结束」（同「知道了」：从列表里删掉、不响）或「推后 5 分钟」。暂停全部提醒时不挂。
// 专注模式（2026-11-17 拍板 B2–B7，ReminderFocus.swift；当晚起任何专注模式都认，SystemFocus）：专注模式开着、设置或滤镜说不照常时，
// 到点的（没开「专注模式时也照常提醒」的）
// 先压着（heldFired / heldMissed）：不弹出、不出声、不升方式、不催；「只在刘海上挂图标」时耳朵上挂一个——左耳闹钟、右耳几条（强调色），
// 点开是卡片（知道了 / 稍后），「先不提醒」时什么都不挂。专注模式结束（滤镜回到照常）时压着的照轻提醒的样子弹一次、响一声，
// 期间没数的间隔提醒从那一刻重新数（同离开电脑）。耳朵上的倒数照常挂（B7）。
// 第五轮体检：暂停全部提醒时间隔类也不攒、暂停结束从那一刻重新数，「暂停到明天」到明天第一个时段开始（E6）；
// 全屏倒数完自己收起时，倒数期间没人碰过键盘鼠标（或会话切走、锁着屏）不算知道了，挂到刘海岛上等处理（E7）；
// 接上 / 拔掉显示器、合上盖子时全屏和边框按现在的屏重摆（E13）；时钟明显往回调才收回将来的时刻（E5）。

import AppKit

@MainActor final class ReminderCenter {
  var island: Island?
  /// 正在录屏 / 录音（AppDelegate 给）：边框、全屏、状态屏都降成轻提醒，也不出声
  var isRecording: () -> Bool = { false }
  /// 正在状态屏里：先不响，退出后 AppDelegate 调 recheck
  var isStatusActive: () -> Bool = { false }
  /// 进入某个状态（状态屏的状态 id）；进不去时给原因，grants = 缺辅助功能授权
  var enterStatus: (String) -> (reason: String, grants: Bool)? = { _ in
    (String(localized: "状态屏不可用"), false)
  }
  /// 朗读一段文字（翻译那边现成的朗读）
  var speak: (String) -> Void = { _ in }
  /// 全屏上的「去授权」
  var grantAccessibility: () -> Void = {}
  private let screen = ReminderScreen()
  private let glow = ReminderGlow()
  /// 现在挂着的这一批用哪种方式（轻提醒 / 边框 / 全屏；进入状态屏的当场就处理完了，不留在这）。又有新的到点只升不降
  private var mode = Reminder.Alert.light
  /// 进入状态屏没进去的原因：写在全屏上（C12）
  private var note: (text: String, grants: Bool)?
  /// 催了几次（C10）
  private var nags = 0
  private var nagTask: Task<Void, Never>?
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
  /// 专注模式滤镜现在说的（ReminderFocus 给；照常 = 没有专注模式在让提醒安静）
  private var focus = ReminderFocusStyle.normal
  /// 专注模式里到点、先压着的（按出现的顺序）：到点的、错过的
  private var heldFired: [String] = []
  private var heldMissed: [String] = []
  private var wake: Task<Void, Never>?
  private var idlePoll: Task<Void, Never>?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  /// 多久没碰键盘鼠标算离开了（B3）
  static let awayAfter: TimeInterval = 5 * 60

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    screen.onDone = { [weak self] in self?.acknowledge() }
    screen.onExpire = { [weak self] in self?.expired(after: $0) }
    screen.onSnooze = { [weak self] in self?.snooze(minutes: $0) }
    screen.onGrant = { [weak self] in self?.grantAccessibility() }
  }

  /// 状态屏退出后、刘海岛插件开关后（AppDelegate 调）：在里面时到点的这会儿再看；专注模式里压着的重新挂一次
  /// （插件刚添加时耳朵才挂得上）
  func recheck() {
    presentHeld()
    check()
  }

  /// 暂停全部提醒到 date（菜单栏，D6；nil = 恢复）：这期间一条都不响，之后晚了 5 分钟以内照常响、更晚的合成「错过了」；
  /// 间隔类不攒，恢复时从那一刻重新数（E6：原来暂停结束马上补响一次，可能落在它的时段外）
  func pause(until date: Date?) {
    guard isRunning else { return }
    state.pausedUntil = date
    if date == nil { restartIntervals(at: .now) }
    saveState()
    check()
  }

  /// 「暂停到明天」到哪一刻：明天第一个时段开始，没设时段的到 8:00（E6，ReminderCheck.pauseUntilTomorrow）
  func pauseUntilTomorrow() -> Date {
    ReminderCheck.pauseUntilTomorrow(list, now: .now, calendar: .current)
  }

  /// 暂停到几点（还在暂停才有）
  var pausedUntil: Date? { state.pausedUntil.flatMap { $0 > .now ? $0 : nil } }

  /// 下一条要响的是哪条、几点（菜单栏「下一个」）；正挂着的不算
  func nextUp() -> (reminder: Reminder, at: Date)? {
    let now = Date.now
    let showing = showing
    // 暂停着时间隔类不按旧锚点响（暂停期间不攒、结束时重新数，E6），不列
    let paused = pausedUntil != nil
    return list.filter {
      $0.isOn && !showing.contains($0.id) && !(paused && $0.schedule.kind == .interval)
    }
    .compactMap { reminder in
      ReminderCheck.due(reminder, state: state, anchors: anchors, calendar: .current)
        .flatMap { $0 > now ? (reminder, $0) : nil }
    }
    .min { $0.1 < $1.1 }
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    observe()
    // 专注模式：先按记着的上一次，再问系统现在的（App 没开着时系统不送）
    focus = ReminderFocus.shared.style
    ReminderFocus.shared.onChange = { [weak self] in self?.focusChanged($0) }
    Task { await ReminderFocus.shared.refresh() }
    listData = defaults.data(forKey: Prefs.reminders)
    list = Reminder.decode(listData)
    // 没有提醒在用的提示音文件清掉（只在存过列表时：没存过 / 解不出来时 decode 给的是示例，不能拿它当准）
    if let listData, (try? JSONSerialization.jsonObject(with: listData)) is [Any] {
      ReminderSound.purge(keeping: Set(list.map(\.chime)))
    }
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
    island?.endActivity(Self.islandActivity)
    island?.endActivity(Self.heldActivity)
    ReminderFocus.shared.onChange = nil
    heldFired = []
    heldMissed = []
    ReminderSound.stop()
    hideSurfaces()
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
    // 压着的打开了「专注模式时也照常提醒」：放出来照常挂（不再压着）
    let urgent = Set(list.filter(\.duringFocus).map(\.id))
    firing += heldFired.filter { on.contains($0) && urgent.contains($0) }
    missed += heldMissed.filter { on.contains($0) && urgent.contains($0) }
    heldFired = heldFired.filter { on.contains($0) && !urgent.contains($0) }
    heldMissed = heldMissed.filter { on.contains($0) && !urgent.contains($0) }
    reconcile()
    if firing != before.0 || missed != before.1 || !firing.isEmpty || !missed.isEmpty { present() }
    presentHeld()
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
      if same, showing.contains(reminder.id) { continue }
      anchors[reminder.id] = same ? self.anchors[reminder.id] ?? now : now
    }
    self.anchors = anchors
    anchorRules = rules
    watchIdle(intervals.isEmpty == false)
  }

  /// 间隔提醒都从 date 重新数（启动、醒来、解锁、离开电脑回来），推过的也作废（算休息过了）；正挂着的、压着的不动。
  /// quietOnly：只数专注模式里歇着的那些（没开「专注模式时也照常提醒」的，B6）
  private func restartIntervals(at date: Date, quietOnly: Bool = false) {
    var cleared = false
    let showing = showing
    for reminder in list where reminder.isOn && reminder.schedule.kind == .interval {
      if showing.contains(reminder.id) || (quietOnly && reminder.duringFocus) { continue }
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
    // 暂停到点了：间隔类从这一刻重新数（暂停期间它们不攒，E6）
    if state.endPause(now: now) {
      restartIntervals(at: now)
      saveState()
    }
    let paused = pausedUntil
    let holding = isLocked || isStatusActive() || paused != nil
    if !holding { releaseHeld() }
    let quiet = focus != .normal
    // 暂停着的间隔类同离开电脑：不响也不等，暂停结束重新数（E6）
    let result = ReminderCheck.check(
      list, state: state, anchors: anchors, showing: showing, now: now,
      held: holding, away: isAway || paused != nil, focus: quiet,
      calendar: .current)
    // 过了点、已经出了时段的间隔类：不补响，从现在数（下一个时段，ReminderCheck.check）
    for id in result.rested { anchors[id] = now }
    let fresh = result.fire + result.missed
    if !fresh.isEmpty {
      for id in fresh {
        state.snoozed[id] = nil
        // 一次性的不挪：没点「知道了」就退出了，下次打开还要告诉你
        if list.first(where: { $0.id == id })?.schedule.kind != .once { state.marks[id]?.at = now }
        anchors[id] = nil  // 间隔的：挂着期间不再数，处理了从那一刻数
      }
      // 专注模式里先压着的（B2 B4）：不弹、不响、不升方式、不催
      let heldNow = ReminderCheck.heldBack(result.fire, list: list, focus: quiet)
      let heldLost = ReminderCheck.heldBack(result.missed, list: list, focus: quiet)
      heldFired += heldNow
      heldMissed += heldLost
      let fire = result.fire.filter { !heldNow.contains($0) }
      let lost = result.missed.filter { !heldLost.contains($0) }
      firing += fire
      missed += lost
      saveState()
      if !heldNow.isEmpty || !heldLost.isEmpty { presentHeld() }
      if !fire.isEmpty || !lost.isEmpty {
        let newly = fire.compactMap { id in list.first { $0.id == id } }
        // 新到点的从第 1 次重新数催促（不然它的第 2 次就换成全屏了）
        if !newly.isEmpty { nags = 0 }
        sound(for: newly)
        // 进了状态屏的只算这一批处理了：之前挂着没理的、这次一起算出来错过的照样留着，退出状态屏后看得到
        // （2026-11-04 评审：原来全算处理了，没看到的一次性提醒被删掉）
        if escalate(with: newly) {
          firing.removeAll { fire.contains($0) }
          return finish(fire)
        }
        present()
        scheduleNag()
      }
    }
    // 暂停着的到点了要再看一眼（那时补响 / 合成错过的）；离下一条一次性提醒还远时，到该开始倒数的那一刻再看
    let countdown = updateCountdown(now: now)
    guard let next = [result.next, paused, countdown].compactMap({ $0 }).min() else { return }
    wake = Task { [weak self] in
      try? await Task.sleep(
        for: .seconds(max(next.timeIntervalSinceNow, 0) + 0.05), tolerance: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.check()
    }
  }

  // MARK: 倒数（刘海岛扩展 C2）

  /// 刘海岛上提醒倒数那个活动的编号
  static let islandActivity = "reminder-countdown"
  /// 离响还有多久起在耳朵上倒数
  static let countdownWindow: TimeInterval = 60 * 60
  /// 倒数上的「推后 5 分钟」
  static let postponeStep: TimeInterval = 5 * 60
  /// 推得最远能到现在之后多久（E5）：倒数只挂一小时以内的，再「推后 5 分钟」就是 65 分钟；全屏的「稍后」最多 1 小时
  static let farthestSnooze = countdownWindow + postponeStep

  /// 下一条要响的一次性提醒和几点（纯函数）：开着、没挂着、还没到点的里面最近的一条（推过的按推到的时刻）
  static func nextOnce(
    _ list: [Reminder], state: ReminderState, anchors: [String: Date], showing: Set<String>,
    now: Date, calendar: Calendar
  ) -> (reminder: Reminder, at: Date)? {
    list.filter { $0.isOn && $0.schedule.kind == .once && !showing.contains($0.id) }
      .compactMap { reminder in
        ReminderCheck.due(reminder, state: state, anchors: anchors, calendar: calendar)
          .flatMap { $0 > now ? (reminder, $0) : nil }
      }
      .min { $0.1 < $1.1 }
  }

  /// 一小时以内要响的那条挂上倒数（没有就收掉）；还早时返回该开始倒数的那一刻（check 那时再看）
  private func updateCountdown(now: Date) -> Date? {
    guard let island else { return nil }
    guard pausedUntil == nil,
      let (reminder, at) = Self.nextOnce(
        list, state: state, anchors: anchors, showing: showing, now: now, calendar: .current)
    else {
      island.endActivity(Self.islandActivity)
      return nil
    }
    let start = at - Self.countdownWindow
    guard start <= now else {
      island.endActivity(Self.islandActivity)
      return start
    }
    island.setActivity(
      Island.Activity(
        id: Self.islandActivity, kind: .reminder, title: reminder.displayTitle,
        detail: String(
          localized: "reminders.countdownAt",
          defaultValue: "\(at.formatted(date: .omitted, time: .shortened)) 提醒",
          comment: "刘海岛上倒数的提醒：几点响"),
        symbol: "alarm.fill",
        trailing: .countdown(to: at),
        actions: [
          Island.Action("提前结束") { [weak self] in self?.finish([reminder.id]) },
          Island.Action("推后 5 分钟") { [weak self] in
            self?.postpone(reminder.id, by: Self.postponeStep)
          },
        ],
        // 设了图标的左耳画它（静止的第一帧，拍板 C5），没设是闹钟
        emoji: reminder.symbol.isEmpty ? nil : reminder.symbol))
    return nil
  }

  /// 还没响的那条推后一段（倒数上的「推后 5 分钟」）：从它原来要响的那一刻往后推
  private func postpone(_ id: String, by seconds: TimeInterval) {
    guard let reminder = list.first(where: { $0.id == id }),
      let at = ReminderCheck.due(reminder, state: state, anchors: anchors, calendar: .current)
    else { return }
    state.snoozed[id] = at + seconds
    saveState()
    check()
  }

  // MARK: 专注模式（拍板 B2–B7）

  /// 刘海岛上「专注模式里压着的提醒」那个活动的编号
  static let heldActivity = "reminder-held"

  /// 正挂着的 + 专注模式里压着的：这些不再响、不再倒数
  private var showing: Set<String> { Set(firing + missed + heldFired + heldMissed) }

  /// 专注模式滤镜变了（ReminderFocus.onChange）：回到照常时把压着的照轻提醒的样子弹一次、响一声（B5，不升全屏、不进状态屏），
  /// 期间歇着的间隔提醒从这一刻重新数（B6）；「挂图标」和「先不提醒」之间换了，耳朵上跟着挂 / 收
  private func focusChanged(_ next: ReminderFocusStyle) {
    guard isRunning, next != focus else { return }
    focus = next
    if next == .normal { restartIntervals(at: .now, quietOnly: true) }
    presentHeld()
    check()
  }

  /// 专注模式已经结束、压着的这会儿能弹了（check 里调，锁着屏、在状态屏里、暂停着时不弹，回来那一下的 check 再弹——
  /// 2026-11-17 评审：定时的睡眠专注 7:00 结束时还锁着屏，原来当场在锁屏上响了）：照轻提醒的样子弹一次、响一声（B5）
  private func releaseHeld() {
    guard focus == .normal, !heldFired.isEmpty || !heldMissed.isEmpty else { return }
    let fired = heldFired
    firing += fired
    missed += heldMissed
    heldFired = []
    heldMissed = []
    island?.endActivity(Self.heldActivity)
    let newly = fired.compactMap { id in list.first { $0.id == id } }
    if !newly.isEmpty { nags = 0 }
    sound(for: newly)
    present()
    scheduleNag()
  }

  /// 压着的挂到耳朵上（B3）：只在「只在刘海上挂图标」时——左耳闹钟、右耳几条（强调色），点开是卡片（知道了 / 稍后）；
  /// 「先不提醒」、没有压着的时候收掉
  private func presentHeld() {
    let fired = heldFired.compactMap { id in list.first { $0.id == id } }
    let lost = heldMissed.compactMap { id in list.first { $0.id == id } }
    guard focus == .light, let notice = Self.notice(fired: fired, missed: lost) else {
      island?.endActivity(Self.heldActivity)
      return
    }
    var actions = [Island.Action("知道了") { [weak self] in self?.acknowledgeHeld() }]
    if !fired.isEmpty {
      actions.append(Island.Action("稍后 \(snoozeMinutes) 分钟") { [weak self] in self?.snoozeHeld() })
    }
    island?.setActivity(
      Island.Activity(
        id: Self.heldActivity, kind: .heldReminder, title: notice.title, detail: notice.detail,
        symbol: "alarm.fill", trailing: .text("\(fired.count + lost.count)"), actions: actions,
        tintsReading: true))
  }

  /// 耳朵上那张卡片的「知道了」：压着的都算处理了（一次的删掉、间隔的从这一刻数）
  private func acknowledgeHeld() {
    let handled = heldFired + heldMissed
    heldFired = []
    heldMissed = []
    island?.endActivity(Self.heldActivity)
    finish(handled)
  }

  /// 「稍后」：压着的到点的推 N 分钟（到点时专注模式还开着就再压着），错过的算处理了
  private func snoozeHeld() {
    let until = Date.now.addingTimeInterval(TimeInterval(snoozeMinutes * 60))
    for id in heldFired { state.snoozed[id] = until }
    let handled = heldMissed
    heldFired = []
    heldMissed = []
    island?.endActivity(Self.heldActivity)
    finish(handled)
  }

  // MARK: 方式

  /// 新到点的这几条要什么方式：比现在挂着的更显眼才换（只升不降）。要进状态屏的当场进；进成了返回 true（这一批算处理了），
  /// 进不去退成全屏、记下原因
  private func escalate(with newly: [Reminder]) -> Bool {
    guard !newly.isEmpty else { return false }
    var target = Self.alert(for: newly, recording: isRecording())
    if target == .status, let preset = newly.first(where: { $0.alert == .status })?.statusID {
      guard let failure = enterStatus(preset) else { return true }
      target = .full
      note = (failure.reason, failure.grants)
    }
    if Self.rank(target) > Self.rank(mode) { mode = target }
    return false
  }

  /// 把挂着的（到点的 + 错过的）按现在的方式摆出来：全屏 / 边框 + 岛 / 岛；只剩错过的一律在岛上；都没有了就全收掉
  private func present() {
    let fired = firing.compactMap { id in list.first { $0.id == id } }
    let lost = missed.compactMap { id in list.first { $0.id == id } }
    guard let notice = Self.notice(fired: fired, missed: lost) else {
      hideSurfaces()
      island?.unpin()
      return
    }
    // 只剩错过的（到点的被关掉、改了时间）：方式和催促都回到初始，下一条到点不会沿用刚才的边框 / 全屏
    if fired.isEmpty { hideSurfaces() }
    if !fired.isEmpty, mode == .full {
      glow.dismiss()
      island?.unpin()
      screen.show(
        .init(
          title: notice.title, detail: notice.detail,
          symbol: fired.first(where: { !$0.symbol.isEmpty })?.symbol ?? "",
          seconds: Self.fullSeconds(for: fired),
          snoozes: Self.snoozeChoices(default: snoozeMinutes),
          note: note))
      return
    }
    screen.dismiss()
    if !fired.isEmpty, mode == .glow { glow.show() } else { glow.dismiss() }
    // 第一个是主按钮（白底、在最右；两个一开始就并排露着，Island 的 pinnedCard）
    var actions = [Island.Action("知道了") { [weak self] in self?.acknowledge() }]
    if !fired.isEmpty {
      actions.append(Island.Action("稍后 \(snoozeMinutes) 分钟") { [weak self] in self?.snooze() })
    }
    island?.pin(notice.title, detail: notice.detail, symbol: "alarm.fill", actions: actions) {
      [weak self] in self?.acknowledge()
    }
  }

  private func hideSurfaces() {
    screen.dismiss()
    glow.dismiss()
    nagTask?.cancel()
    nagTask = nil
    mode = .light
    note = nil
    nags = 0
  }

  /// 几条一起到点时用哪种方式（纯函数，B5 + C11）：最显眼的那条；正在录屏录音时一律轻提醒
  static func alert(for reminders: [Reminder], recording: Bool) -> Reminder.Alert {
    guard !recording else { return .light }
    return reminders.map(\.alert).max { rank($0) < rank($1) } ?? .light
  }

  static func rank(_ alert: Reminder.Alert) -> Int {
    switch alert {
    case .light: 0
    case .glow: 1
    case .full: 2
    case .status: 3
    }
  }

  /// 全屏多久自己收（纯函数）：有一条要「点了才收」就点了才收，否则取最长的；不是全屏的那几条（含进不去状态屏、退成全屏的）不算
  static func fullSeconds(for reminders: [Reminder]) -> Int {
    // 状态屏的没进去、退成全屏的不自己收（详情页里它没有「多久自己收起」，藏着的旧值不算；人可能不在跟前，C12）
    let seconds = reminders.filter { $0.alert == .full }.map(\.fullSeconds)
    return seconds.contains(0) || seconds.isEmpty ? 0 : seconds.max() ?? 0
  }

  /// 全屏上「稍后」的几个选项（纯函数，C8）：设置里定的那个 + 15 分钟 + 1 小时，去重、从小到大
  static func snoozeChoices(default minutes: Int) -> [Int] {
    Array(Set([minutes, 15, 60])).sorted()
  }

  // MARK: 催促（C10）

  /// 挂着的里头有要催的（岛上、边框；全屏不催）：按最短的间隔排下一次
  private func scheduleNag() {
    nagTask?.cancel()
    nagTask = nil
    let minutes = firing.compactMap { id in list.first { $0.id == id }?.nagMinutes }.filter {
      $0 > 0
    }
    guard mode != .full, let every = minutes.min() else { return }
    nagTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(every * 60), tolerance: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.nag()
    }
  }

  /// 再响一声、岛晃一下；第 3 次（到点那次算第 1 次）换成全屏，之后不再催。锁着屏、在状态屏里时等下一轮
  private func nag() {
    guard isRunning, !firing.isEmpty, mode != .full else { return }
    if isLocked || isStatusActive() || pausedUntil != nil { return scheduleNag() }
    let fired = firing.compactMap { id in list.first { $0.id == id } }
    nags += 1
    sound(for: fired)
    if nags >= 2 {
      if isRecording() {
        island?.nudge()
      } else {
        mode = .full
        present()
      }
      return
    }
    island?.nudge()
    scheduleNag()
  }

  /// 岛上那一条写什么（纯函数）：到点的标题连在一起（只有一条时带它的说明），错过的写在详情里；只有错过的时
  /// 「错过了提醒：喝水」/「错过了 3 个提醒」+ 是哪几个
  static func notice(fired: [Reminder], missed: [Reminder]) -> (title: String, detail: String?)? {
    let lostTitles = missed.map(\.displayTitle).joinedAsList()
    if fired.isEmpty {
      guard let first = missed.first else { return nil }
      return missed.count == 1
        ? (String(localized: "错过了提醒：\(first.displayTitle)"), first.displayDetail)
        : (String(localized: "错过了 \(missed.count) 个提醒"), lostTitles)
    }
    var detail = fired.count == 1 ? fired[0].displayDetail : nil
    if !missed.isEmpty {
      let line = String(localized: "还错过了：\(lostTitles)")
      detail = detail.map { [$0, line].joinedAsClauses() } ?? line
    }
    return (fired.map(\.displayTitle).joined(separator: " · "), detail)
  }

  /// 全屏倒数完自己收起（C5）：倒数期间有人碰过键盘鼠标才算「知道了」；一直没人碰、会话切走了、锁着屏（人不在跟前：
  /// 显示器睡了没锁、去开会了、切到了别的用户），不是间隔类的不算——收起全屏、挂到刘海岛上等处理（E7：原来一次性的就这样
  /// 被删掉了，回来岛上、列表里都没有）；间隔类照旧算处理了、从这一刻重新数（「休息眼睛」照做的人正好 20 秒不碰键鼠，
  /// 挂到岛上的话锚点空着、之后不再数；离开本来就算休息过，B3）。挂上去不再催：全屏已经出过（同「第 3 次换成全屏，之后不再催」）
  private func expired(after shown: TimeInterval) {
    let away = isLocked || InputBlock.isSessionAway
    let pending = Self.unattended(
      firing + missed, list: list, idle: Self.idleSeconds(), shown: shown, away: away)
    guard !pending.isEmpty else { return acknowledge() }
    let handled = (firing + missed).filter { !pending.contains($0) }
    firing = firing.filter(pending.contains)
    missed = missed.filter(pending.contains)
    hideSurfaces()
    finish(handled)
  }

  /// 全屏自己收起时还要挂在岛上等处理的（纯函数）：出来的这 shown 秒里没人碰过键盘鼠标（空闲得比它还久）、或者会话不在
  /// 用户手里时，不是间隔类的那几条；有人碰过、或者全是间隔类，是空的（都算知道了）
  static func unattended(
    _ ids: [String], list: [Reminder], idle: TimeInterval, shown: TimeInterval, away: Bool
  ) -> [String] {
    guard away || idle >= shown else { return [] }
    return ids.filter { id in list.first { $0.id == id }?.schedule.kind != .interval }
  }

  /// 「知道了」：挂着的都算处理了
  private func acknowledge() {
    ReminderSound.stop()  // 自己选的长音频：用户处理了才停（进入状态屏、只剩错过的那几条收面板时不停：刚响的那声还要响完）
    let handled = firing + missed
    firing = []
    missed = []
    finish(handled)
  }

  /// 「稍后」：到点的推 N 分钟（岛上是设置里定的那个，全屏上能另选）；一起挂着的错过的算处理了
  private func snooze(minutes: Int? = nil) {
    ReminderSound.stop()
    let until = Date.now.addingTimeInterval(TimeInterval((minutes ?? snoozeMinutes) * 60))
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
    // 还有没处理的（进状态屏只处理了那一批）就照样摆着，都处理了才全收
    if firing.isEmpty, missed.isEmpty {
      hideSurfaces()
      island?.unpin()
    } else {
      present()
    }
    check()
  }

  /// 声音（C9，只响一声）：几条一起到点时按第一条要出声的——提示音，或者把这几条的标题念出来。录屏录音时不出声（C11）
  private func sound(for reminders: [Reminder]) {
    guard !isRecording(), let first = reminders.first(where: { $0.sound != .none }) else { return }
    switch first.sound {
    case .chime: ReminderSound.play(first.chime)
    case .speak: speak(reminders.map(\.displayTitle).joined(separator: Island.comma))
    case .none: break
    }
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
      Task { await ReminderFocus.shared.refresh() }
      $0.isAway = false
      $0.restartIntervals(at: .now)
      $0.check()
    }
    // 系统时间往回调过：记在「将来」的时刻收回来，不然要等真实时间追上才响；只收明显往回调的，推后的最远按 65 分钟算（E5）
    add(local, .NSSystemClockDidChange) {
      let pulled = $0.state.pulledBack(now: .now, maxSnooze: Self.farthestSnooze)
      if pulled != $0.state {
        $0.state = pulled
        $0.saveState()
      }
      $0.check()
    }
    for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
      add(local, name) { $0.check() }
    }
    // 接上 / 拔掉显示器、合上盖子：显示着的全屏和边框按现在的屏重摆，内容沿用（E13，同状态屏）
    add(local, NSApplication.didChangeScreenParametersNotification) {
      $0.screen.screensChanged()
      $0.glow.screensChanged()
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
