// 刘海岛上的「下一个日程」（2026-11-14，以 Alcove 为准的那一轮 D3，用户「全部按推荐」；归刘海岛插件里一组、默认关）。
// 读系统「日历」（EventKit）：下一个日程开始前 10 分钟挂到刘海两边倒数（没刘海时是菜单栏那一项），点开是标题、
// 时间和地点、「加入会议」（日程里有认得的会议链接时）和「打开日历」；开始那一刻收掉。全天的、已拒绝的、取消的不算。
// - 授权：要「日历」的完整访问（读日程）。**只在设置里打开那个开关的那一刻问一次**（requestAccess，设置页调）；这里从不
//   弹框——开关开着却没授权（后来在系统设置里关掉了）就什么都不做，设置页橙字说一声；本 App 回到前台、问完授权时
//   重查一次（从系统设置里打开授权回来就跟上）。开关这个偏好跟着这台 Mac 的授权：不注册默认值，不导出、不同步。
// - 不轮询：听系统的「日历变了」通知（同步日历时一连来很多条：合并 0.4 秒再读）、醒来、改时间 / 时区，另有一个等到
//   「下一次要变」的 Task（该开始倒数的那一刻、日程开始的那一刻；最远 6 小时后再看一遍：只读了之后 24 小时的日程）。
// - 日程的标题、地点只留在本机：不进日志、不进最近的提示。会议链接只认 https 的、主机是认得的那几家的（日程是别人
//   能发来的邀请，里面的网址不能随便开）。
// ponytail: 读日程在主线程（之后 24 小时的那几条，EventKit 自己有缓存）；日历多到读得慢再挪出去。
// ponytail: 进行中的日程不显示（Alcove 显示进度）。月历和当天的列表在那一张上（Shell/IslandCalendar.swift，2026-11-14）：
// 今天的日程由这里的 agenda() 读，同样只在已经授权时读、从不弹框。

import AppKit
import EventKit

@MainActor final class NextEvent {
  static let activityID = "next-event"
  /// 开始前多久挂上去
  static let lead: TimeInterval = 10 * 60
  /// 往后看多久的日程、最远多久之后再看一遍
  static let window: TimeInterval = 24 * 3600
  static let recheck: TimeInterval = 6 * 3600

  /// 一个日程里用得上的几样（从 EKEvent 里当场取出来的值；挑哪一个、画成什么样的纯函数只看它）
  struct Entry: Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    /// 我拒绝了、或者整个取消了
    var declined = false
    var location: String?
    var url: URL?
    var notes: String?
    /// 它所在日历的颜色（设置 › 刘海岛「用日历的颜色」打开时画）
    var color: CGColor?
  }

  /// 设置里列的一个日历（选哪些日历）
  struct CalendarInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var color: CGColor?
  }

  /// 这台 Mac 上能读的日历（设置 › 刘海岛「选择日历」列；没授权是空的）。建一个 EventKitStore 要几十毫秒，只在那一页打开时调
  static func eventCalendars() -> [CalendarInfo] {
    guard isAuthorized else { return [] }
    return EKEventStore().calendars(for: .event)
      .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: $0.cgColor) }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  /// 不看的日历（设置 › 刘海岛「选择日历」关掉的，一行一个编号；这台 Mac 自己的，Prefs.islandHiddenCalendars）
  static func hiddenCalendars(_ defaults: UserDefaults) -> Set<String> {
    Set(
      (defaults.string(forKey: Prefs.islandHiddenCalendars) ?? "").split(separator: "\n").map(
        String.init))
  }

  private weak var island: Island?
  private let defaults: UserDefaults
  private var store: EKEventStore?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  /// 一直听着的两样（不跟着起停）：本 App 回到前台、设置页问完授权——授权可能刚变
  private var accessObservers: [NSObjectProtocol] = []
  private var wait: Task<Void, Never>?
  /// 挂在刘海上的那一条、它开始时响过没有（设置 › 刘海岛「日程开始时响一声」，Chime）
  private var shown: Entry?
  private var chimed: String?
  /// 那一张的月历读今天的日程用（「下一个日程」没开时 store 是 nil）：第一次用到才建，留着（建一个要几十毫秒）
  private var agendaStore: EKEventStore?
  /// 上一次读的时候看的那几样偏好（不看的日历、拒绝的也列、用日历的颜色）：变了就重读
  private var filterKey = ""

  init(island: Island, defaults: UserDefaults = .standard) {
    self.island = island
    self.defaults = defaults
    for name in [NSApplication.didBecomeActiveNotification, Self.accessChanged] {
      accessObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.apply(recheck: true) }
        })
    }
  }

  /// 有没有「日历」的完整访问（只查、不弹框）
  static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

  /// 系统还没问过（这时调 requestAccess 才会弹框；问过之后只能去系统设置里开）
  static var canAsk: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

  /// 设置页问完授权后发：正跑着的那个实例跟上
  static let accessChanged = Notification.Name("KittyNextEventAccessChanged")

  /// 问一次「日历」授权（系统框只弹一次；之后要去系统设置里开）。只有设置页调
  static func requestAccess() async -> Bool {
    if isAuthorized { return true }
    let store = EKEventStore()
    // 回调在 EventKit 自己的队列上、SDK 里它的类型没标 Sendable：不写 @Sendable 就继承主线程隔离，一来就触发执行器
    // 断言闪退（同 NowPlaying.proxy 那次）。只把结果带回来
    let granted = await withCheckedContinuation { continuation in
      store.requestFullAccessToEvents { @Sendable granted, _ in
        continuation.resume(returning: granted)
      }
    }
    // store 留到回调之后再放
    withExtendedLifetime(store) {}
    NotificationCenter.default.post(name: accessChanged, object: nil)
    return granted
  }

  /// 照偏好和授权起 / 停（启动时、偏好变了时 AppDelegate 调）：没变不动。平时跑着就不再查授权（偏好一变就来一次）；
  /// recheck：授权可能刚变（回到前台、设置页问完），跑着的也查一遍
  func apply(recheck: Bool = false) {
    let added =
      defaults.object(forKey: Feature.island.prefsKey) as? Bool ?? Feature.island.defaultOn
    let wanted =
      added && defaults.bool(forKey: Prefs.islandNextEvent)
      && (store != nil && !recheck || Self.isAuthorized)
    if wanted, store == nil {
      start()
    } else if !wanted, store != nil {
      stop()
    }
    let key = [
      defaults.string(forKey: Prefs.islandHiddenCalendars) ?? "",
      "\(defaults.bool(forKey: Prefs.islandShowDeclined))",
      "\(defaults.bool(forKey: Prefs.islandCalendarColors))",
    ].joined(separator: "|")
    if key != filterKey {
      filterKey = key
      if store != nil { refreshSoon() }
    }
  }

  /// 要读的日历：去掉设置里关掉的；都关掉了是空的（nil = 全部）
  private func calendars(in store: EKEventStore) -> [EKCalendar]? {
    let hidden = Self.hiddenCalendars(defaults)
    guard !hidden.isEmpty else { return nil }
    return store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
  }

  private func start() {
    let store = EKEventStore()
    self.store = store
    let local = NotificationCenter.default
    for (center, name, object) in [
      (local, Notification.Name.EKEventStoreChanged, store as AnyObject?),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, nil),
      (local, .NSSystemClockDidChange, nil), (local, .NSSystemTimeZoneDidChange, nil),
    ] {
      let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshSoon() }
      }
      observers.append((center, token))
    }
    refreshSoon()
  }

  private func stop() {
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    wait?.cancel()
    wait = nil
    store = nil
    island?.endActivity(Self.activityID)
  }

  /// 有变化了：过 0.4 秒再读（同步日历时通知一连来很多条，醒来时「醒来」和「时钟变了」一起来；每条都整读一遍是白做）。
  /// 刚打开时也走这里：不在启动那一下同步读日历
  private func refreshSoon() {
    wait?.cancel()
    wait = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }

  /// 重新看一遍：下一个日程到了该倒数的时候就挂上，还早就收着；排好下一次要变的时刻
  private func refresh(now: Date = .now) {
    guard let store else { return }
    // 挂着的那一条刚到开始的那一刻（plan 排的下一次就是它）：响一声
    if let shown, Self.isStarting(shown, now: now), chimed != shown.id,
      defaults.bool(forKey: Prefs.islandEventChime)
    {
      chimed = shown.id
      Chime.play(.event)
    }
    let chosen = calendars(in: store)
    let predicate = store.predicateForEvents(
      withStart: now, end: now.addingTimeInterval(Self.window), calendars: chosen)
    // 先按便宜的几样筛掉（全天的、已经开始的），剩下的才取参会人、备注（EventKit 用到才去读）；日历都关掉了就不读
    let upcoming =
      chosen?.isEmpty == true
      ? [] : store.events(matching: predicate).filter { !$0.isAllDay && $0.startDate > now }
    let next = Self.pick(
      upcoming.map(Self.entry), now: now,
      declined: defaults.bool(forKey: Prefs.islandShowDeclined))
    let plan = Self.plan(next, now: now)
    shown = plan.shows ? next : nil
    if plan.shows, let next {
      island?.setActivity(
        Self.activity(
          next, join: { NSWorkspace.shared.open($0) },
          openCalendar: {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
          }, colored: defaults.bool(forKey: Prefs.islandCalendarColors)))
    } else {
      island?.endActivity(Self.activityID)
    }
    wait?.cancel()
    // 连续时钟：合盖睡着时也在走，醒来就到点（另有醒来的通知兜底）
    wait = Task { [weak self] in
      try? await Task.sleep(
        for: .seconds(max(plan.next.timeIntervalSince(now), 0) + 0.05), tolerance: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }

  private static func entry(_ event: EKEvent) -> Entry {
    let mine = event.attendees?.first(where: \.isCurrentUser)
    return Entry(
      id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "",
      start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
      declined: mine?.participantStatus == .declined || event.status == .canceled,
      location: event.location, url: event.url, notes: event.notes, color: event.calendar?.cgColor)
  }

  /// 今天的日程（那一张的月历旁边列；Island.agendaProvider 接到这里）。没有「日历」授权是 nil——只查不弹框。
  /// 读的是今天零点到明天零点的那几条，在主线程（那一张打开的那一下；同 refresh 的 ponytail）
  func agenda(now: Date = .now, calendar: Calendar = .current) -> Island.Agenda? {
    guard Self.isAuthorized, let day = calendar.dateInterval(of: .day, for: now) else {
      // 授权没了：授权期间建的那个不留（重新给了授权再建新的）
      agendaStore = nil
      return nil
    }
    let store = store ?? agendaStore ?? EKEventStore()
    agendaStore = self.store == nil ? store : nil
    let chosen = calendars(in: store)
    guard chosen?.isEmpty != true else { return Island.Agenda(items: []) }
    let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: chosen)
    // 先按便宜的几样筛（已经结束的、正好明天零点开始的不要），剩下的才取参会人、备注（EventKit 用到才去读）
    let events = store.events(matching: predicate).filter {
      $0.startDate < day.end && ($0.isAllDay || $0.endDate > now)
    }
    var agenda = Self.today(
      events.map(Self.entry), now: now, declined: defaults.bool(forKey: Prefs.islandShowDeclined),
      colored: defaults.bool(forKey: Prefs.islandCalendarColors))
    // 月历上标出有日程的日子（设置 › 刘海岛，默认关）：读这一整个月
    if defaults.bool(forKey: Prefs.islandCalendarDots),
      let month = calendar.dateInterval(of: .month, for: now)
    {
      let all = store.events(
        matching: store.predicateForEvents(
          withStart: month.start, end: month.end, calendars: chosen))
      agenda.busy = Self.busyDays(
        all.map(Self.entry), month: month,
        declined: defaults.bool(forKey: Prefs.islandShowDeclined), calendar: calendar)
    }
    return agenda
  }

  // MARK: 纯函数（单测锁住）

  /// 今天的日程排成月历旁边那几行：全天的在前，其余按开始时刻；已经结束的、拒绝 / 取消的不列；最多 limit 条，
  /// 另记还有几条。标题空的写「日程」、最多 80 个字
  static func today(
    _ entries: [Entry], now: Date, limit: Int = 3, timeZone: TimeZone = .current,
    declined: Bool = false, colored: Bool = false
  ) -> Island.Agenda {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.timeZone = timeZone
    let rows =
      entries
      .filter { (declined || !$0.declined) && ($0.isAllDay || $0.end > now) }
      .sorted {
        ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title)
      }
      .map { entry -> Island.AgendaItem in
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 编号拼上开始时刻：每天重复的日程各次共用一个编号，跨零点的那种（23:00–07:00）昨天那次和今天那次会同时在
        return Island.AgendaItem(
          id: "\(entry.id)@\(entry.start.timeIntervalSince1970)",
          title: title.isEmpty ? Self.untitled : String(title.prefix(80)),
          time: entry.isAllDay ? String(localized: "全天") : entry.start.formatted(style),
          color: colored ? entry.color : nil)
      }
    return Island.Agenda(items: Array(rows.prefix(limit)), more: max(rows.count - limit, 0))
  }

  /// 没有标题的日程叫什么（显式 key：设置 › 刘海岛 那一节也叫「日程」，英文不同）
  static var untitled: String {
    String(localized: "event.untitled", defaultValue: "日程", comment: "没有标题的日历日程")
  }

  /// 这一条是不是刚开始（纯函数）：开始了、还不到 1 分钟（睡着醒来时早过了的不响）
  static func isStarting(_ entry: Entry, now: Date) -> Bool {
    let since = now.timeIntervalSince(entry.start)
    return since >= 0 && since < 60
  }

  /// 下一个日程：还没开始的里面最早的（同一刻的按标题排，几台读出来一样）；全天的、拒绝 / 取消的不算
  /// declined：「显示已拒绝的日程」打开时拒绝 / 取消的也算
  static func pick(_ entries: [Entry], now: Date, declined: Bool = false) -> Entry? {
    entries.filter { !$0.isAllDay && (declined || !$0.declined) && $0.start > now }
      .min { ($0.start, $0.title) < ($1.start, $1.title) }
  }

  /// 现在挂不挂、下一次什么时候再看：到了开始前 lead 就挂，日程开始那一刻再看（收掉、换下一个）；还早就等到该挂的
  /// 那一刻；没有日程、离得远的最远 recheck 之后再看（只读了之后 window 的）
  static func plan(_ next: Entry?, now: Date) -> (shows: Bool, next: Date) {
    let later = now.addingTimeInterval(recheck)
    guard let next else { return (false, later) }
    let from = next.start.addingTimeInterval(-lead)
    return now >= from ? (true, next.start) : (false, min(from, later))
  }

  /// 第二行：「14:30–15:00 · 会议室 A」。地点只取第一行、最多 60 个字；地点本身是个网址的不写（它在「加入会议」里）
  static func detail(_ entry: Entry, timeZone: TimeZone = .current) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.timeZone = timeZone
    let time = "\(entry.start.formatted(style))–\(entry.end.formatted(style))"
    let place = entry.location?.split(whereSeparator: \.isNewline).first.map {
      String($0.trimmingCharacters(in: .whitespaces).prefix(60))
    }
    guard let place, !place.isEmpty, !place.contains("://") else { return time }
    return time + " · " + place
  }

  /// 认得的会议服务（主机名等于它或者以「.它」结尾）
  static let meetingHosts = [
    "zoom.us", "zoom.com.cn", "meet.google.com", "teams.microsoft.com", "teams.live.com",
    "webex.com", "meeting.tencent.com", "voovmeeting.com", "vc.feishu.cn", "vc.larksuite.com",
    "meeting.dingtalk.com", "whereby.com", "meet.jit.si", "facetime.apple.com",
  ]

  /// 日程里的会议链接：先看日程自己的网址，再从地点、备注里找；主机要是认得的那几家，开的一律是 https（文字里不带
  /// 协议的「zoom.us/j/…」会被认成 http：主机认得就换成 https；别的协议不要）。没有是 nil
  static func meetingURL(_ entry: Entry) -> URL? {
    var candidates = [entry.url].compactMap { $0 }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    for text in [entry.location, entry.notes].compactMap({ $0 }) {
      // 备注可以很长（整封邀请信）：只看开头和结尾各一段（入会的那一段常在信尾）
      let parts =
        text.count > 8000 ? [String(text.prefix(4000)), String(text.suffix(4000))] : [text]
      for part in parts {
        let range = NSRange(part.startIndex..., in: part)
        candidates += detector?.matches(in: part, range: range).compactMap(\.url) ?? []
      }
    }
    for url in candidates {
      guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
        let host = url.host()?.lowercased(),
        meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { continue }
      parts.scheme = "https"
      if let secure = parts.url { return secure }
    }
    return nil
  }

  /// 挂在岛上的样子：类别是日程（比保持唤醒、提醒的倒数要紧，让给录制和长任务），左耳日历、右耳倒数到开始；卡片上「加入会议」（有链接时）和「打开日历」。
  /// 标题最多 200 个字，空的写「日程」
  /// colored：耳朵、卡片上的日历符号用它所在日历的颜色（设置 › 刘海岛「用日历的颜色」）
  static func activity(
    _ entry: Entry, join: @escaping (URL) -> Void, openCalendar: @escaping () -> Void,
    colored: Bool = false
  ) -> Island.Activity {
    var actions: [Island.Action] = []
    if let link = meetingURL(entry) {
      actions.append(Island.Action("加入会议", opens: true) { join(link) })
    }
    actions.append(Island.Action("打开日历", opens: actions.isEmpty, run: openCalendar))
    let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return Island.Activity(
      id: activityID, kind: .event,
      title: title.isEmpty ? Self.untitled : String(title.prefix(200)),
      detail: detail(entry), symbol: "calendar", trailing: .countdown(to: entry.start),
      actions: actions, color: colored ? entry.color.flatMap { NSColor(cgColor: $0) } : nil)
  }

  /// 这个月里哪几天有日程（纯函数）：几号的集合；跨天的每一天都算，月外的不算
  static func busyDays(
    _ entries: [Entry], month: DateInterval, declined: Bool = false, calendar: Calendar
  ) -> Set<Int> {
    var days: Set<Int> = []
    for entry in entries where declined || !entry.declined {
      var day = calendar.startOfDay(for: max(entry.start, month.start))
      // 结束在零点整的（全天的、到 24:00 的）不算到第二天
      let last = min(entry.end.addingTimeInterval(-1), month.end.addingTimeInterval(-1))
      while day <= last {
        days.insert(calendar.component(.day, from: day))
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
    }
    return days
  }
}
