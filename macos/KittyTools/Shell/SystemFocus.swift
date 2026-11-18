// 系统现在开着哪个专注模式（2026-11-17 拍板 A1，PLAN §10「专注模式」）：读系统日志。专注模式的服务（donotdisturbd）每次
// 切换写一行「Did receive state update」，里面是新的状态：现在的模式的编号、名字（自定义的也有；系统自带的写英文）、
// 图标（SF 符号名）、颜色名，关掉时编号是 (null)。常驻一个 `/usr/bin/log stream`（谓词只放这一行进来，实测 90 秒 CPU
// 0.01 秒、约 4 MB），每次起 stream 时再用 `log show` 往回查 7 天拿「现在」（空闲时约 2 秒、CPU 1.2 秒，忙时近 10 秒，后台）。都是系统自带的命令行工具，
// 不要授权、不用私有接口（同类 App 在进程内用私有的日志框架读同一行，拍板 A2 没选）。
// 读不到（log stream 起来就退出、连着三次：不是管理员账户 log 不让读之类）：isReadable = false，刘海上不提示，提醒退回只认滤镜
// （ReminderFocus），设置里各一行小字说。
// ponytail: 日志这一行是系统里一个对象的调试描述，不是接口；改了就读不到（退回滤镜，不会出错）。要更稳只有完全磁盘访问读
// ~/Library/DoNotDisturb/DB 的两个 JSON（拍板 A3，没做）。往回查只查 7 天（日志大约留这么久）：更早开的、一直没关过的
// 专注模式启动时认不出来，下一次切换才知道（7 天里查不到切换时留着偏好里记着的那个）。苹果改了日志的写法时 stream 照样跑、
// 只是一行都认不出来：等于一直没开专注模式。App 闪退时 log 留给 launchd，等下一次切换写日志时因为管道断了才退出
// （正常退出时当场停掉，terminate）。日志只认这个用户的（userID）：快速切换用户时别的用户的专注模式不算。
// 谁要它才跑（apply，启动时、偏好一变都调）：刘海岛插件添加着且「在刘海上显示专注模式」开着，或者提醒开着且「专注模式开着时」
// 不是照常。停着时 current 是 nil。
// 变了：刘海上贴着刘海两边提示一下（左边模式的图标、颜色和名字，右边「开 / 关」，2 秒；同耳机、电源那种提示），
// 告诉 ReminderFocus。起来时读到的「现在」不提示（不是刚变的）。现在的模式记在偏好里（Prefs.focusMode，这台电脑自己的），
// 刚启动、往回查的那 2 秒里先按它算（提醒别在这一下把专注期间压着的弹出来）。

import AppKit
import Observation
import os

@Observable final class SystemFocus {
  /// 只有一份（设置 › 刘海岛、设置 › 提醒都读它）；刘海岛由 AppDelegate 接上
  static let shared = SystemFocus()

  /// 一个专注模式：日志里写的样子
  nonisolated struct Mode: Equatable, Codable, Sendable {
    /// com.apple.donotdisturb.mode.default 这种；自定义的是 com.apple.donotdisturb.mode.<名字> 或者一串编号
    var id: String
    /// 日志里的名字：自定义的是用户起的，系统自带的是英文（显示用 displayName）
    var name: String
    /// SF 符号名
    var symbol: String
    /// 系统的颜色名（systemIndigoColor）
    var tint: String

    /// 显示的名字：系统自带的几种按界面语言翻（日志里一律是英文），自定义的原样，读不出名字的叫「专注模式」
    var displayName: String {
      SystemFocus.builtInName(id: id, name: name)
        ?? (name.isEmpty ? String(localized: "专注模式") : name)
    }

    /// 睡眠（批 2：开启时响一声）
    var isSleep: Bool {
      id.contains("sleep") || symbol.hasPrefix("bed.double") || name == "Sleep"
    }
  }

  /// 一行日志说了什么：现在开着哪个（nil = 都关了），和关掉前那个（日志里读得出来才有）
  nonisolated struct Update: Equatable, Sendable {
    var mode: Mode?
    var previous: Mode?
  }

  private(set) var current: Mode?
  /// 读得到系统日志（读不到时设置里说一声、提醒只认滤镜）
  private(set) var isReadable = true
  /// 现在在不在读
  private(set) var isRunning = false
  /// 变了（from → to）：AppDelegate 接给提醒和批 2 的几样
  @ObservationIgnored var onChange: ((Mode?, Mode?) -> Void)?

  @ObservationIgnored weak var island: Island?
  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored private var task: Task<Void, Never>?
  /// 这一次 log stream 的「当场停掉」
  @ObservationIgnored private var stopStream: (@Sendable () -> Void)?
  /// 第几次起 stream（起停、重起都换）：往回查晚回来的、停掉之后还缓冲着的行，次数对不上就不算（评审）
  @ObservationIgnored private var round = 0
  /// 这一次 stream 已经听到过：往回查晚回来的就不用了
  @ObservationIgnored private var heardLive = false
  /// 刘海上一直挂着的是哪个模式（没挂是 nil）
  @ObservationIgnored private var pinned: Mode?

  private init() {
    current = defaults.data(forKey: Prefs.focusMode).flatMap {
      try? JSONDecoder().decode(Mode.self, from: $0)
    }
  }

  /// 要不要读（纯函数）：刘海上显示专注模式（插件添加着），或者提醒开着、专注模式时不是照常，或者开着整点报时 /
  /// 日程开始时响一声（专注模式时它们不响，得知道开没开）
  nonisolated static func wanted(
    island: Bool, islandFocus: Bool, reminders: Bool, reminderStyle: String, chimes: Bool = false
  ) -> Bool {
    (island && (islandFocus || chimes))
      || (reminders && reminderStyle != ReminderFocusStyle.normal.rawValue)
  }

  /// 专注模式开着时不弹电源、电量、耳机、网络的提示（设置 › 刘海岛「专注模式」那一节，默认关；SystemNotices 看它）
  var quietsNotices: Bool {
    current != nil && showsOnNotch && defaults.bool(forKey: Prefs.islandFocusQuiet)
  }

  /// 刘海岛插件添加着、「在刘海上显示专注模式」开着（那一节的另外三样都跟着它）
  private var showsOnNotch: Bool { Feature.island.isOn && defaults.bool(forKey: Prefs.islandFocus) }

  /// 正在播放的右耳要不要画专注模式的符号（开着专注模式、设置里打开了那一样）
  /// ponytail: 任何专注模式都换；要「只在某个模式时换」得列出这台 Mac 有哪些模式（日志里只见过切换到的那几个），以后再说
  /// 开着专注模式时一直挂在刘海两边（设置 › 刘海岛「开着时一直挂在刘海上」，默认开；2026-11-18 用户：「alcove 好像是一直展示的」）：
  /// 左耳模式的符号（模式的颜色），点开是卡片——名字 +「专注模式设置…」。最不要紧（Activity.Kind.focus），放歌、倒数时让给它们
  private func updateActivity() {
    guard let island else { return }
    let next = showsOnNotch && defaults.bool(forKey: Prefs.islandFocusPinned) ? current : nil
    // 只在挂的那个变了时设（偏好一变 apply 就会来；每次都设的话展开着的卡片会被反复重画，评审）
    guard next != pinned else { return }
    pinned = next
    if let next {
      island.setActivity(Self.activity(next))
    } else {
      island.endActivity(Self.activityID)
    }
  }

  /// 刘海岛上专注模式那个活动的编号
  static let activityID = "system-focus"

  /// 一直挂着的那个活动（纯函数，截图自检也用）
  static func activity(_ mode: Mode) -> Island.Activity {
    Island.Activity(
      id: activityID, kind: .focus, title: mode.displayName,
      detail: String(localized: "专注模式开着"), symbol: symbol(mode.symbol, id: mode.id),
      actions: [
        Island.Action("专注模式设置…", opens: true) {
          if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
          }
        }
      ], color: color(named: mode.tint))
  }

  private func updateMark() {
    updateActivity()
    let mark =
      showsOnNotch && defaults.bool(forKey: Prefs.islandFocusWaveform)
      ? current.map {
        Island.FocusMark(
          symbol: Self.symbol($0.symbol, id: $0.id), tint: Self.color(named: $0.tint))
      }
      : nil
    if island?.focusMark != mark { island?.focusMark = mark }
  }

  /// 照偏好起停（启动时、偏好变了时 AppDelegate 调）；没变不动
  func apply() {
    defer { updateMark() }
    let wanted = Self.wanted(
      island: Feature.island.isOn, islandFocus: defaults.bool(forKey: Prefs.islandFocus),
      reminders: Feature.reminders.isOn,
      reminderStyle: defaults.string(forKey: Prefs.remindersDuringFocus) ?? "",
      chimes: defaults.bool(forKey: Prefs.islandHourlyChime)
        || defaults.bool(forKey: Prefs.islandEventChime))
    if wanted, !isRunning {
      start()
    } else if !wanted, isRunning {
      stop()
    } else if !wanted, current != nil {
      // 起来时不用读：偏好里记着的那个不算数了
      record(nil, announces: false)
    }
  }

  private func start() {
    isRunning = true
    isReadable = true
    task = Task { [weak self] in await self?.run() }
  }

  private func stop() {
    halt()
    record(nil, announces: false)
  }

  /// App 退出时（AppDelegate.applicationWillTerminate）：当场停掉 log（任务取消来不及走到停子进程那一步），偏好里记着的
  /// 模式留着——下次启动先按它
  func terminate() { halt() }

  private func halt() {
    isRunning = false
    round += 1
    task?.cancel()
    task = nil
    stopStream?()
    stopStream = nil
  }

  /// 这个用户的编号：日志里别的已登录用户（快速切换用户）的 donotdisturbd 也看得见，只认自己的
  nonisolated static let user = Int(getuid())

  /// 日志里那一行（log 的谓词）
  nonisolated static let predicate =
    #"subsystem == "com.apple.donotdisturb" AND category == "ServiceProvider" AND eventMessage BEGINSWITH "Did receive state update""#

  /// 一直读着：起 log stream，同时往回查一次「现在」；stream 断了隔一会儿重起（重起也再查一次，补上断着的那几秒），
  /// 起来不到 10 秒就退出连着三次（多半是没权限读日志）就不读了。log stream 一起来就先写一行「Filtering the log data…」，
  /// 所以只看活了多久、不看写没写过东西（评审）
  private func run() async {
    var quickFailures = 0
    while !Task.isCancelled {
      round += 1
      let current = round
      heardLive = false
      let started = ContinuousClock.now
      let (lines, stop) = Subprocess.lines(
        "/usr/bin/log", ["stream", "--style", "ndjson", "--predicate", Self.predicate])
      stopStream = stop
      Task { [weak self] in
        let found = await Self.lookBack()
        guard let self, self.round == current, !self.heardLive else { return }
        switch found {
        case .found(let mode): self.record(mode, announces: false)
        case .failed: Log.island.notice("focus: log show failed")
        // 7 天里没切换过：偏好里记着的那个还是对的（评审：「勿扰直到关闭」开了一周多，原来会被清掉）
        case .nothing: break
        }
      }
      for await line in lines {
        guard !Task.isCancelled, round == current else { break }
        guard case .output(let text) = line,
          let update = Self.update(fromJSONLine: text, user: Self.user)
        else { continue }
        heardLive = true
        record(update.mode, previous: update.previous, announces: true)
      }
      guard !Task.isCancelled, round == current else { return }
      stopStream = nil
      let quick = ContinuousClock.now - started < .seconds(10)
      quickFailures = quick ? quickFailures + 1 : 0
      if quickFailures >= 3 {
        Log.island.notice("focus: log stream keeps exiting, giving up")
        isReadable = false
        record(nil, announces: false)
        return
      }
      try? await Task.sleep(for: quick ? .seconds(10) : .seconds(2))
    }
  }

  /// 往回查的结果：查不成（log show 退出码不是 0、超时）、7 天里没切换过、最后一条说的
  nonisolated enum LookBack: Equatable, Sendable {
    case failed, nothing
    case found(Mode?)
  }

  /// 往回查 7 天，最后一条就是现在的
  /// ponytail: 7 天里没切换过、偏好里也没记着的（更早开的「勿扰直到关闭」、头一次用）认不出来，下一次切换才知道
  private nonisolated static func lookBack() async -> LookBack {
    guard
      let result = try? await Subprocess.run(
        "/usr/bin/log", ["show", "--last", "7d", "--style", "ndjson", "--predicate", predicate],
        captures: true, timeout: .seconds(60), quality: .utility),
      result.status == 0
    else { return .failed }
    let last = result.output.split(separator: "\n").reversed().lazy.compactMap {
      update(fromJSONLine: String($0), user: user)
    }.first
    return last.map { .found($0.mode) } ?? .nothing
  }

  /// 记下现在的；变了才告诉别人。announces：刘海上提示一下（stream 听到的才提示）
  private func record(_ next: Mode?, previous: Mode? = nil, announces: Bool) {
    guard next != current else { return }
    let before = current
    current = next
    defaults.set(next.flatMap { try? JSONEncoder().encode($0) }, forKey: Prefs.focusMode)
    onChange?(before, next)
    updateMark()
    guard announces, let island, showsOnNotch, let shown = next ?? before ?? previous else {
      return
    }
    // 睡眠模式刚打开：响一声轻的（照 Alcove；录屏、录音时不响，Chime）
    if let next, next.isSleep, before?.isSleep != true,
      defaults.bool(forKey: Prefs.islandFocusSleepSound)
    {
      Chime.play(.sleep, duringFocus: true)
    }
    let level = Self.level(shown, on: next != nil)
    let name = shown.displayName
    let spoken =
      next != nil ? String(localized: "专注模式「\(name)」已打开") : String(localized: "专注模式「\(name)」已关闭")
    island.showNotice(level, fallback: "\(spoken)")
    Island.announce("\(spoken)")
  }

  /// 刘海上那一条（贴着刘海两边，2 秒）：左边模式的图标 + 名字，右边「开 / 关」；每侧照名字量多宽
  static func level(_ mode: Mode, on: Bool) -> Island.Level {
    let name = mode.displayName
    return Island.Level(
      kind: .toggle, fraction: on ? 1 : 0, glyph: symbol(mode.symbol, id: mode.id), caption: name,
      stay: .seconds(2), tint: mode.tint, wing: wing(for: name))
  }

  /// 每侧伸出多宽（纯函数，量名字）：左边 11 边距 + 16 图标 + 6 间距 + 名字 + 8，最窄同音量提示的 90、最宽 160（再长的截尾）
  /// extra：名字之外左边还占多少（有图标 41；电量低那种只有一句话的 21）
  static func wing(for name: String, extra: CGFloat = 41) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let width = (name as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    return min(max(width + extra, Island.levelWing), 160)
  }

  /// 日志给的符号名系统里没有（iOS 才有的、别的系统版本的；「工作」写的 person.lanyardcard.fill 在 macOS 27 上就没有，
  /// 实测）：系统自带的几种换成意思相近的，别的换成月亮
  static func symbol(_ name: String, id: String = "") -> String {
    if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
    return switch id {
    case "com.apple.focus.work": "briefcase.fill"
    case "com.apple.focus.personal-time": "person.fill"
    case "com.apple.donotdisturb.mode.driving": "car.fill"
    case "com.apple.donotdisturb.mode.workout": "figure.run"
    case "com.apple.focus.reading": "book.fill"
    case "com.apple.focus.gaming": "gamecontroller.fill"
    case "com.apple.focus.mindfulness": "apple.meditate"
    case _ where id.hasPrefix("com.apple.sleep"): "bed.double.fill"
    default: "moon.fill"
    }
  }

  // MARK: 读日志（纯函数，单测锁住）

  /// log 的 ndjson 一行 → 说了什么；不是那一行、读不出来、给了 user 却是别的用户的是 nil
  nonisolated static func update(fromJSONLine line: String, user: Int? = nil) -> Update? {
    guard line.hasPrefix("{"),
      let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
      let message = object["eventMessage"] as? String
    else { return nil }
    if let user, let owner = object["userID"] as? Int, owner != user { return nil }
    return update(fromMessage: message)
  }

  /// 「Did receive state update…」那一行的正文 → 说了什么。新的状态在前、「previousState: 」之后是之前的（长了会被截断）
  nonisolated static func update(fromMessage message: String) -> Update? {
    guard message.hasPrefix("Did receive state update"),
      let stateStart = message.range(of: "state: <DNDState")
    else { return nil }
    let rest = message[stateStart.lowerBound...]
    let split = rest.range(of: "; previousState: ")
    let state = split.map { rest[..<$0.lowerBound] } ?? rest
    let before = split.map { rest[$0.upperBound...] }
    guard let active = value(after: "activeModeIdentifier: ", in: state, until: [">", ";"]) else {
      return nil
    }
    let mode: Mode? =
      active == "(null)"
      ? nil
      : self.mode(in: state).flatMap { $0.id == active ? $0 : nil }
        ?? Mode(id: active, name: "", symbol: "moon.fill", tint: "systemIndigoColor")
    return Update(mode: mode, previous: before.flatMap { self.mode(in: $0) })
  }

  /// 一段状态里「mode: <DNDMode …>」那一截读出模式；读不全是 nil
  private nonisolated static func mode(in text: Substring) -> Mode? {
    guard let start = text.range(of: "mode: <DNDMode") else { return nil }
    let part = text[start.upperBound...]
    guard let name = value(after: "; name: ", in: part, until: ["; modeIdentifier: "]),
      let id = value(after: "; modeIdentifier: ", in: part, until: [";"]),
      let symbol = value(after: "; symbolImageName: ", in: part, until: [";"]),
      let tint = value(after: "; tintColorName: ", in: part, until: [";"])
    else { return nil }
    return Mode(id: id, name: name, symbol: symbol, tint: tint)
  }

  /// key 后面、到最先碰到的那个结尾之前的一截（找不到结尾不算：被截断的那一半不要）
  private nonisolated static func value(
    after key: String, in text: Substring, until ends: [String]
  ) -> String? {
    guard let start = text.range(of: key) else { return nil }
    let tail = text[start.upperBound...]
    guard
      let end = ends.compactMap({ tail.range(of: $0)?.lowerBound }).min()
    else { return nil }
    let value = tail[..<end].trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
  }

  /// 系统自带的几种专注模式按界面语言叫什么（日志里是英文）；认不出的是 nil（原样显示用户起的名字）。睡眠的编号没在本机
  /// 日志里见过，按编号里的 sleep 和英文名认
  nonisolated static func builtInName(id: String, name: String) -> String? {
    switch id {
    case "com.apple.donotdisturb.mode.default": String(localized: "勿扰模式")
    case "com.apple.donotdisturb.mode.driving":
      String(localized: "focus.driving", defaultValue: "驾驶")
    case "com.apple.donotdisturb.mode.workout":
      String(localized: "focus.fitness", defaultValue: "健身")
    case "com.apple.focus.work": String(localized: "focus.work", defaultValue: "工作")
    case "com.apple.focus.personal-time": String(localized: "focus.personal", defaultValue: "个人")
    case "com.apple.focus.reading": String(localized: "focus.reading", defaultValue: "阅读")
    case "com.apple.focus.gaming": String(localized: "focus.gaming", defaultValue: "游戏")
    case "com.apple.focus.mindfulness": String(localized: "focus.mindfulness", defaultValue: "正念")
    case "com.apple.focus.reduce-interruptions": String(localized: "减少干扰")
    default:
      id.hasPrefix("com.apple.sleep") || (id.hasPrefix("com.apple.") && name == "Sleep")
        ? String(localized: "focus.sleep", defaultValue: "睡眠") : nil
    }
  }

  /// 系统的颜色名 → 颜色（认不出的是靛蓝，勿扰的颜色）
  nonisolated static func color(named name: String?) -> NSColor {
    switch name {
    case "systemRedColor": .systemRed
    case "systemOrangeColor": .systemOrange
    case "systemYellowColor": .systemYellow
    case "systemGreenColor": .systemGreen
    case "systemMintColor": .systemMint
    case "systemTealColor": .systemTeal
    case "systemCyanColor": .systemCyan
    case "systemBlueColor": .systemBlue
    case "systemPurpleColor": .systemPurple
    case "systemPinkColor": .systemPink
    case "systemBrownColor": .systemBrown
    case "systemGrayColor": .systemGray
    default: .systemIndigo
    }
  }
}
