// 系统专注模式（Shell/SystemFocus.swift）：读日志那几个纯函数、提醒怎么合起来算（ReminderFocus.effective）。
// 样本是本机 macOS 27.0 的 donotdisturbd 原样写的（每行在 1062 字处被截断，previousState 后半截没了）

import Foundation
import Testing

@testable import KittyTools

struct SystemFocusTests {
  /// 定时的勿扰 22:00 打开（系统自带的写英文名）
  static let dndOn =
    #"Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x77d4fc8d80; reason: scheduled; source: local; options: <none>; state: <DNDState: 0x77d4e942c0; suppressionState: while UI locked; startDate: 2026-11-17 13:00:00 +0000; userVisibleTransitionDate: 2026-11-17 23:20:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: <DNDMutableModeConfiguration: 0x77d487a580; mode: <DNDMode: 0x77d4807160; name: Do Not Disturb; modeIdentifier: com.apple.donotdisturb.mode.default; symbolImageName: moon.fill; tintColorName: systemIndigoColor; symbolDescriptor: (null); semanticType: 0; visibility: 0; identifier: 43ABFA76-85A7-44D2-8E31-84EA5286EB85; isPlaceHolder: NO>; impactsAvailability: default; dimsLockScreen: default>; activeModeIdentifier: com.apple.donotdisturb.mode.default>; previousState: <DNDState: 0x77d4e94f80; suppressionState: inactive; startDate: 2026-11-15 22:40:00 +0000; userVisibleTransitionDate: 2026-11-18 04:00:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: (null); activeModeI"#

  /// 自己建的「午睡」13:30 结束：新状态是 (null)，之前那个在 previousState 里
  static let napOff =
    #"Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x780a867ae0; reason: scheduled; source: local; options: <none>; state: <DNDState: 0x780a8bd880; suppressionState: inactive; startDate: 2026-11-17 04:30:00 +0000; userVisibleTransitionDate: 2026-11-18 04:00:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: (null); activeModeIdentifier: (null)>; previousState: <DNDState: 0x780a831640; suppressionState: while UI locked; startDate: 2026-11-17 04:00:00 +0000; userVisibleTransitionDate: 2026-11-17 04:30:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: <DNDMutableModeConfiguration: 0x780ae1b500; mode: <DNDMode: 0x780a8040f0; name: 午睡; modeIdentifier: com.apple.donotdisturb.mode.headphones; symbolImageName: headphones; tintColorName: systemIndigoColor; symbolDescriptor: (null); semanticType: -1; visibility: 0; identifier: E723E9B4-50CC-4911-8AA3-04918B3F41AC; isPlaceHolder: NO>; impactsAvailability: default; dimsLockScreen: default>; activeModeIdentifier: com.apple.donotdistur"#

  static let nap = SystemFocus.Mode(
    id: "com.apple.donotdisturb.mode.headphones", name: "午睡", symbol: "headphones",
    tint: "systemIndigoColor")

  @Test func readsModeTurningOn() {
    let update = SystemFocus.update(fromMessage: Self.dndOn)
    #expect(
      update?.mode
        == SystemFocus.Mode(
          id: "com.apple.donotdisturb.mode.default", name: "Do Not Disturb", symbol: "moon.fill",
          tint: "systemIndigoColor"))
    // 之前什么都没开（previousState 里 activeModeConfiguration 是 (null)）
    #expect(update?.previous == nil)
  }

  @Test func readsModeTurningOffWithPrevious() {
    let update = SystemFocus.update(fromMessage: Self.napOff)
    #expect(update != nil)
    #expect(update?.mode == nil)
    #expect(update?.previous == Self.nap)
  }

  @Test func readsNDJSONLine() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "timestamp": "2026-11-17 22:00:03.021", "eventMessage": Self.dndOn,
    ])
    let line = String(decoding: data, as: UTF8.self)
    #expect(
      SystemFocus.update(fromJSONLine: line)?.mode?.id == "com.apple.donotdisturb.mode.default")
    // 别的用户（快速切换用户）的不算
    let other = try JSONSerialization.data(withJSONObject: [
      "userID": 502, "eventMessage": Self.dndOn,
    ])
    #expect(
      SystemFocus.update(fromJSONLine: String(decoding: other, as: UTF8.self), user: 501) == nil)
    let mine = try JSONSerialization.data(withJSONObject: [
      "userID": 501, "eventMessage": Self.dndOn,
    ])
    #expect(
      SystemFocus.update(fromJSONLine: String(decoding: mine, as: UTF8.self), user: 501) != nil)
    // log stream 开头那句说明、别的行
    #expect(
      SystemFocus.update(fromJSONLine: #"Filtering the log data using "subsystem == …""#) == nil)
    #expect(
      SystemFocus.update(fromJSONLine: #"{"eventMessage":"Delivering state update: pid=766"}"#)
        == nil)
  }

  @Test func ignoresTruncatedOrForeignMessages() {
    // 截断在新状态的模式编号之前：读不出来就不算（不能当成关了）
    let cut = String(Self.dndOn.prefix(300))
    #expect(SystemFocus.update(fromMessage: cut) == nil)
    #expect(SystemFocus.update(fromMessage: "Delivering active mode update: pid=7399") == nil)
  }

  @Test func modeWithoutReadableDetailsStillCounts() {
    // 新状态里模式那一截写法变了（只剩编号）：照样算开着，名字空着、图标月亮
    let message =
      "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x1; state: <DNDState: 0x2; activeModeConfiguration: <X>; activeModeIdentifier: com.example.focus>; previousState: <DNDState: 0x3>"
    let mode = SystemFocus.update(fromMessage: message)?.mode
    #expect(mode?.id == "com.example.focus")
    #expect(mode?.symbol == "moon.fill")
    #expect(mode?.displayName == "专注模式")
  }

  @Test func builtInNamesAreTranslatedCustomKept() {
    #expect(
      SystemFocus.builtInName(id: "com.apple.donotdisturb.mode.default", name: "Do Not Disturb")
        == "勿扰模式")
    #expect(SystemFocus.builtInName(id: "com.apple.focus.work", name: "Work") == "工作")
    #expect(SystemFocus.builtInName(id: "com.apple.sleep.sleep-mode", name: "Sleep") == "睡眠")
    #expect(Self.nap.displayName == "午睡")
    #expect(SystemFocus.Mode(id: "x", name: "Sleep", symbol: "bed.double.fill", tint: "").isSleep)
    #expect(!Self.nap.isSleep)
  }

  @MainActor @Test func wingFitsNameWithinBounds() {
    #expect(SystemFocus.wing(for: "午睡") == Island.levelWing)
    let long = SystemFocus.wing(for: "Reduce Interruptions and More")
    #expect(long == 160)
    let mid = SystemFocus.wing(for: "Do Not Disturb")
    #expect(mid > Island.levelWing && mid < 160)
    // 系统里没有的符号换成月亮
    #expect(SystemFocus.symbol("no.such.symbol.kitty") == "moon.fill")
    #expect(SystemFocus.symbol("headphones") == "headphones")
    #expect(
      SystemFocus.symbol("person.lanyardcard.fill", id: "com.apple.focus.work") == "briefcase.fill")
  }

  @Test func readsOnlyWhenSomethingNeedsIt() {
    #expect(
      SystemFocus.wanted(island: true, islandFocus: true, reminders: false, reminderStyle: "normal")
    )
    #expect(
      !SystemFocus.wanted(
        island: false, islandFocus: true, reminders: false, reminderStyle: "light"))
    #expect(
      SystemFocus.wanted(island: false, islandFocus: false, reminders: true, reminderStyle: "light")
    )
    #expect(
      !SystemFocus.wanted(
        island: true, islandFocus: false, reminders: true, reminderStyle: "normal"))
    // 整点报时 / 日程开始时响一声开着：要知道专注模式开没开（开着时不响）
    #expect(
      SystemFocus.wanted(
        island: true, islandFocus: false, reminders: false, reminderStyle: "normal", chimes: true))
  }

  @Test func filterOverridesSettingWhileFocused() {
    // 没开专注模式、滤镜没另选：照常
    #expect(ReminderFocus.effective(filter: .follow, focused: false, setting: .light) == .normal)
    // 开着任何模式：按设置
    #expect(ReminderFocus.effective(filter: .follow, focused: true, setting: .light) == .light)
    #expect(ReminderFocus.effective(filter: .follow, focused: true, setting: .hold) == .hold)
    #expect(ReminderFocus.effective(filter: .follow, focused: true, setting: .normal) == .normal)
    // 滤镜另选了的以滤镜为准（设置照常、只给某个模式加滤镜；读不到日志时滤镜照样管用）
    #expect(ReminderFocus.effective(filter: .light, focused: true, setting: .normal) == .light)
    #expect(ReminderFocus.effective(filter: .light, focused: false, setting: .normal) == .light)
    #expect(ReminderFocus.effective(filter: .normal, focused: true, setting: .hold) == .normal)
  }

  /// 一直跑着的子进程按行交出来（SystemFocus 的 log stream 走它）：分几次写的行拼得起来，没换行的半行不交，退出时交退出码
  @MainActor @Test func subprocessLinesStreamsUntilExit() async {
    var got: [Subprocess.Line] = []
    for await line in Subprocess.lines(
      "/bin/sh", ["-c", "printf 'a\\nb'; sleep 0.2; printf 'c\\n{\\n'; printf 'tail'; exit 3"]
    ).lines {
      got.append(line)
    }
    #expect(got == [.output("a"), .output("bc"), .output("{"), .exited(3)])
    // 当场停掉：流随之结束、交出被信号结束的退出码
    let (lines, stop) = Subprocess.lines("/bin/sleep", ["30"])
    stop()
    var ended: [Subprocess.Line] = []
    for await line in lines { ended.append(line) }
    #expect(ended == [.exited(SIGTERM)])
  }

  /// 一直挂着的那个活动：最不要紧（放歌时让给正在播放）；没刘海的屏上不进菜单栏（系统自己有专注模式的图标）
  @MainActor @Test func pinnedActivityYieldsAndStaysOutOfMenuBar() {
    let focus = SystemFocus.activity(Self.nap)
    #expect(focus.kind < .media)
    #expect(focus.color != nil && focus.title == "午睡")
    #expect(IslandMenuItem.pick([focus], wings: false) == nil)
  }
}
