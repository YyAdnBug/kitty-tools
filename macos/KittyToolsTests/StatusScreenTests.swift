// 状态屏（PLAN §10）的纯函数单测：自带状态和编解码、sanitized 各条、退出判断（ExitHold：按住满 2 秒、别的触碰取消、带修饰键 / 连发
// 不算、松开取消、鼠标按在提示里外、滚动合并、「松不开」的键过期）、时长文字、退出提示和 key 面板的范围、拦截对事件的分类、
// 启动器里每个状态一条；设置 › 状态屏改列表的几个纯函数（加、删、挪、恢复自带的、详情页改一个、摘要）。不进入状态屏、不建面板。
//
// 另有一个按需的实机自检 liveBlockSwallowsKeys()（默认不跑）：真的建起产品的 InputBlock，发一次合成的 ⌃⌥⇧⌘F18，
// 看处理函数收到按下 / 松开、别的全局监听一个都没收到，作废之后再发一次、监听收得到。要「辅助功能」授权。
// **拦截是全吞的：建着的那约半秒里，真实的键盘、鼠标点按和滚轮也会被吞掉**（跑之前手离开键盘鼠标）；
// 作废后那一次 ⌃⌥⇧⌘F18 会发给前台 App（没人用的组合）。
//   TEST_RUNNER_KITTY_LIVE_INPUT_BLOCK=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test '-only-testing:KittyToolsTests/StatusScreenTests/liveBlockSwallowsKeys()'

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct StatusScreenTests {
  nonisolated private static let live =
    ProcessInfo.processInfo.environment["KITTY_LIVE_INPUT_BLOCK"] != nil

  // MARK: 状态

  @Test func builtInPresets() throws {
    let presets = StatusPreset.builtIn
    #expect(presets.map(\.id) == ["clean", "busy", "back"])
    #expect(presets.map(\.title) == ["清洁屏幕", "请勿触碰", "马上回来"])
    #expect(presets.map(\.style) == [.blackout, .dim, .sign])
    #expect(presets.map(\.power) == [.normal, .displayOn, .awake])
    #expect(presets.map(\.autoEndMinutes) == [5, 0, 0])
    #expect(presets.map(\.symbol) == ["sparkles", "hand.raised.fill", "clock.fill"])
    #expect(presets[1].detail == "电脑正在跑任务，别动键盘和鼠标" && presets[0].detail == nil)
    // 自带的本身就合规；编成 JSON 再读回来一样
    #expect(StatusPreset.sanitized(presets) == presets)
    #expect(StatusPreset.decode(try JSONEncoder().encode(presets)) == presets)
    // 可选图标约 20 个、不重复，最低系统上都有
    #expect(StatusPreset.symbols.count == 20 && Set(StatusPreset.symbols).count == 20)
    for symbol in StatusPreset.symbols {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  /// 没存过、解不出、空列表、收拾完一个不剩：都用自带的
  @Test func presetsFallBackToBuiltIn() throws {
    #expect(StatusPreset.decode(nil) == StatusPreset.builtIn)
    #expect(StatusPreset.decode(Data("不是 JSON".utf8)) == StatusPreset.builtIn)
    #expect(StatusPreset.decode(Data("[]".utf8)) == StatusPreset.builtIn)
    // 样式是不认识的值：整张解不出
    let unknown =
      #"[{"id":"a","title":"x","symbol":"","style":"blur","power":"normal","autoEndMinutes":0}]"#
    #expect(StatusPreset.decode(Data(unknown.utf8)) == StatusPreset.builtIn)
    let blank =
      #"[{"id":"a","title":"  ","symbol":"","style":"sign","power":"normal","autoEndMinutes":0}]"#
    #expect(StatusPreset.decode(Data(blank.utf8)) == StatusPreset.builtIn)
    // 没有说明的（键不在）照常解得出
    let plain =
      #"[{"id":"a","title":"开会","symbol":"","style":"sign","power":"awake","autoEndMinutes":30}]"#
    #expect(
      StatusPreset.decode(Data(plain.utf8)) == [
        StatusPreset(
          id: "a", title: "开会", detail: nil, symbol: "", style: .sign, power: .awake,
          autoEndMinutes: 30)
      ])
  }

  @Test func sanitizing() {
    func preset(
      _ id: String, _ title: String, detail: String? = nil, symbol: String = "", minutes: Int = 0
    ) -> StatusPreset {
      StatusPreset(
        id: id, title: title, detail: detail, symbol: symbol, style: .sign, power: .normal,
        autoEndMinutes: minutes)
    }
    let clean = StatusPreset.sanitized([
      preset("a", "  开会\n中  ", detail: "  \n ", symbol: "moon.fill", minutes: 15),
      preset("b", String(repeating: "长", count: 40), detail: String(repeating: "说", count: 80)),
      preset("c", "   "),  // 标题空：丢
      preset("a", "重复的 id"),  // 丢，留先出现的
      preset("", "没有 id"),  // 丢
      preset(String(repeating: "x", count: 65), "id 太长"),  // 丢
      preset("d", "图标不在清单里", symbol: "lock.fill", minutes: 7),
    ])
    #expect(clean.map(\.id) == ["a", "b", "d"])
    // 首尾空白去掉、换行当空格；只有空白的说明就是没有；清单里的图标和可选的分钟数留着
    #expect(clean[0].title == "开会 中" && clean[0].detail == nil)
    #expect(clean[0].symbol == "moon.fill" && clean[0].autoEndMinutes == 15)
    #expect(clean[1].title.count == 30 && clean[1].detail?.count == 60)
    #expect(clean[2].symbol.isEmpty && clean[2].autoEndMinutes == 0)
    // 最多 20 个
    let many = (0..<30).map { preset("p\($0)", "状态 \($0)") }
    #expect(StatusPreset.sanitized(many).map(\.id) == (0..<20).map { "p\($0)" })
  }

  /// 存取走一个偏好键里的 JSON：存进去的是收拾过的，读回来一样；存了空列表读回来是自带的。
  /// 只测编解码这两个纯函数，不建偏好域（临时偏好域删了也会在偏好目录里留一个空文件）
  @Test func presetsRoundTrip() {
    var custom = StatusPreset.builtIn[2]
    custom.id = "meeting"
    custom.title = " 开会中 "
    custom.symbol = "不存在的图标"
    let loaded = StatusPreset.decode(StatusPreset.encoded([custom, StatusPreset.builtIn[0]]))
    #expect(loaded.map(\.id) == ["meeting", "clean"])
    #expect(loaded[0].title == "开会中" && loaded[0].symbol.isEmpty)
    #expect(loaded[1] == StatusPreset.builtIn[0])
    // 全删光了：回到自带的
    #expect(StatusPreset.decode(StatusPreset.encoded([])) == StatusPreset.builtIn)
    // 列表不注册默认值（没存过就是自带的；导出导入在 SettingsArchive.kinds 里单独登记）；退出提示的开关默认开
    #expect(Prefs.defaults[Prefs.statusScreenPresets] == nil)
    #expect(Prefs.defaults[Prefs.statusScreenExitHint] as? Bool == true)
  }

  // MARK: 设置页改列表

  private func preset(_ id: String, _ title: String = "开会") -> StatusPreset {
    StatusPreset(
      id: id, title: title, detail: nil, symbol: "", style: .sign, power: .normal,
      autoEndMinutes: 0)
  }

  /// 列表行的小字：样式 · 电源 · 自动结束，照常、不结束的那一段不写
  @Test func summaries() {
    #expect(
      StatusPreset.builtIn.map(\.summary) == ["熄屏 · 5 分钟后结束", "透出 · 屏幕常亮", "告示 · 不睡眠"])
    var custom = preset("a")
    #expect(custom.summary == "告示")
    custom.power = .displayOn
    custom.autoEndMinutes = 60
    #expect(custom.summary == "告示 · 屏幕常亮 · 1 小时后结束")
    #expect(
      StatusPreset.autoEndChoices.map(StatusPreset.autoEndTitle) == [
        "不结束", "5 分钟", "15 分钟", "30 分钟", "1 小时",
      ])
    // 设置里的叫法：三种样式各一句话，电源三档
    #expect(StatusPreset.Look.allCases.map(\.title) == ["熄屏", "告示", "透出"])
    #expect(StatusPreset.Look.allCases.allSatisfy { !$0.explanation.isEmpty })
    #expect(StatusPreset.Power.allCases.map(\.title) == ["照常", "不睡眠", "不睡眠且屏幕常亮"])
  }

  /// 加：新状态是「新状态」、告示、不睡眠、不自动结束、不带图标，id 各不相同，本身合规；到 20 个就不加
  @Test func addingPresets() {
    let fresh = StatusPreset.new()
    #expect(fresh.title == "新状态" && fresh.detail == nil && fresh.symbol.isEmpty)
    #expect(fresh.style == .sign && fresh.power == .awake && fresh.autoEndMinutes == 0)
    #expect(fresh.id != StatusPreset.new().id && fresh.id.count <= StatusPreset.maxID)
    #expect(StatusPreset.sanitized([fresh]) == [fresh])
    let added = StatusPreset.adding(fresh, to: StatusPreset.builtIn)
    #expect(added.map(\.id) == ["clean", "busy", "back", fresh.id])
    let full = (0..<StatusPreset.maxCount).map { preset("p\($0)") }
    #expect(StatusPreset.adding(fresh, to: full) == full)
    #expect(StatusPreset.adding(fresh, to: Array(full.dropLast())).count == StatusPreset.maxCount)
  }

  /// 删：按 id；至少留一个（只剩一个时不删）；删不存在的不动
  @Test func removingPresets() {
    let list = StatusPreset.builtIn
    #expect(StatusPreset.removing("busy", from: list).map(\.id) == ["clean", "back"])
    #expect(StatusPreset.removing("nope", from: list) == list)
    let last = [list[0]]
    #expect(StatusPreset.removing("clean", from: last) == last)
    // 删之前要不要确认：和自带的一模一样的不用，改过的、自己加的要
    var edited = list[0]
    edited.autoEndMinutes = 15
    #expect(list.allSatisfy(\.isPristine) && !edited.isPristine && !preset("mine").isPristine)
  }

  /// 排序：上移 / 下移一格，到头了、找不到都不动（拖动排序用的是系统的 move(fromOffsets:toOffset:)）
  @Test func movingPresets() {
    let list = StatusPreset.builtIn
    #expect(StatusPreset.moving("back", by: -1, in: list).map(\.id) == ["clean", "back", "busy"])
    #expect(StatusPreset.moving("clean", by: 1, in: list).map(\.id) == ["busy", "clean", "back"])
    #expect(StatusPreset.moving("clean", by: -1, in: list) == list)
    #expect(StatusPreset.moving("back", by: 1, in: list) == list)
    #expect(StatusPreset.moving("nope", by: 1, in: list) == list)
  }

  /// 恢复自带的：缺的（按 id）补到末尾，已有的（哪怕改过）不动；都在时没有可恢复的；补到 20 个为止
  @Test func restoringBuiltIns() {
    var busy = StatusPreset.builtIn[1]
    busy.title = "别碰"
    let list = [preset("mine"), busy]
    #expect(StatusPreset.missingBuiltIns(in: list).map(\.id) == ["clean", "back"])
    let restored = StatusPreset.restoringBuiltIns(in: list)
    #expect(restored.map(\.id) == ["mine", "busy", "clean", "back"])
    #expect(restored[1].title == "别碰" && restored[2] == StatusPreset.builtIn[0])
    #expect(StatusPreset.missingBuiltIns(in: restored).isEmpty)
    #expect(StatusPreset.restoringBuiltIns(in: restored) == restored)
    let nearlyFull = (0..<19).map { preset("p\($0)") }
    #expect(StatusPreset.restoringBuiltIns(in: nearlyFull).map(\.id).last == "clean")
    #expect(StatusPreset.restoringBuiltIns(in: nearlyFull).count == StatusPreset.maxCount)
  }

  /// 详情页改一个：按 id 换掉、别的不动；标题只有空白时留着原来的标题（别的字段照改）；存进去的是收拾过的。
  /// 草稿的问题只是提示：没标题、标题 / 说明超长
  @Test func updatingPreset() {
    let list = StatusPreset.builtIn
    var draft = list[2]
    draft.title = " 开会中 "
    draft.detail = "三点回来"
    draft.style = .dim
    var updated = StatusPreset.updating(list, with: draft)
    #expect(updated[0] == list[0] && updated[1] == list[1])
    #expect(updated[2].title == " 开会中 " && updated[2].style == .dim)
    // 编进偏好再读回来：首尾空白去掉了
    #expect(StatusPreset.decode(StatusPreset.encoded(updated))[2].title == "开会中")
    draft.title = "  "
    draft.symbol = "moon.fill"
    updated = StatusPreset.updating(list, with: draft)
    #expect(updated[2].title == "马上回来" && updated[2].symbol == "moon.fill")
    #expect(StatusPreset.decode(StatusPreset.encoded(updated)).count == 3)
    // 列表里没有这个 id：不动
    #expect(StatusPreset.updating(list, with: preset("nope")) == list)

    #expect(list.allSatisfy { $0.problem == nil })
    #expect(draft.problem == "还没填标题")
    draft.title = String(repeating: "长", count: 31)
    #expect(draft.problem == "标题最多 30 个字，后面的不会保存")
    draft.title = String(repeating: "长", count: 30)
    draft.detail = String(repeating: "说", count: 61)
    #expect(draft.problem == "说明最多 60 个字，后面的不会保存")
    draft.detail = String(repeating: "说", count: 60) + "  "
    #expect(draft.problem == nil)
  }

  // MARK: 退出判断

  /// #expect 里不能直接调 mutating 方法：包一层
  private final class Hold {
    var state = ExitHold()

    func on(_ event: InputBlock.Event, at now: ContinuousClock.Instant, hints: [CGRect] = [])
      -> Bool
    {
      state.handle(event, at: now, hints: hints)
    }
  }

  private static let escape = ExitHold.escape
  private static func down(_ code: Int, isRepeat: Bool = false, modifiers: Bool = false)
    -> InputBlock.Event
  {
    .keyDown(code: code, isRepeat: isRepeat, hasModifiers: modifiers)
  }

  /// 只按着 esc：开始计时（这一下不算触碰），满 2 秒完成；期间 esc 自己的连发不打断
  @Test func holdingEscapeCompletes() {
    let hold = Hold()
    let start = ContinuousClock.now
    #expect(Self.escape == kVK_Escape)
    #expect(!hold.on(Self.down(Self.escape), at: start))
    #expect(hold.state.holding?.source == .key && hold.state.remaining(at: start) == .seconds(2))
    for step in 1...10 {
      let now = start + .milliseconds(150 * step)
      #expect(!hold.on(Self.down(Self.escape, isRepeat: true), at: now))
    }
    #expect(!hold.state.isComplete(at: start + .milliseconds(1999)))
    #expect(hold.state.isComplete(at: start + .seconds(2)))
    // 同一下 esc 两条路都到了（拦截 + key 面板）：接着算，不重来也不取消
    let twice = Hold()
    #expect(!twice.on(Self.down(Self.escape), at: start))
    #expect(!twice.on(Self.down(Self.escape), at: start + .milliseconds(5)))
    #expect(twice.state.holding?.since == start)
    // 没在按住
    #expect(ExitHold().remaining(at: start) == nil && !ExitHold().isComplete(at: start))
  }

  /// 按住 esc 期间碰到别的键：取消、算一次触碰；esc 还按着也不会自己接着算，要松开重按
  @Test func otherKeyCancelsHold() {
    let hold = Hold()
    let start = ContinuousClock.now
    _ = hold.on(Self.down(Self.escape), at: start)
    #expect(hold.on(Self.down(kVK_ANSI_A), at: start + .seconds(1)))
    #expect(hold.state.holding == nil)
    #expect(!hold.on(Self.down(Self.escape, isRepeat: true), at: start + .milliseconds(1100)))
    #expect(hold.state.holding == nil && !hold.state.isComplete(at: start + .seconds(5)))
    // 别的键还按着时重按 esc：不开始，算触碰
    _ = hold.on(.keyUp(code: Self.escape), at: start + .milliseconds(1200))
    #expect(hold.on(Self.down(Self.escape), at: start + .milliseconds(1300)))
    #expect(hold.state.holding == nil)
    // 都松开再按：开始
    _ = hold.on(.keyUp(code: kVK_ANSI_A), at: start + .milliseconds(1400))
    _ = hold.on(.keyUp(code: Self.escape), at: start + .milliseconds(1400))
    #expect(!hold.on(Self.down(Self.escape), at: start + .milliseconds(1500)))
    #expect(hold.state.holding?.since == start + .milliseconds(1500))
  }

  /// 带修饰键的 esc 不开始（算触碰）；一上来就是连发的 esc（进入前就按着）不开始、也不算触碰；别的键按下都算触碰、连发不算
  @Test func modifiersAndRepeatsDoNotStart() {
    let hold = Hold()
    let now = ContinuousClock.now
    #expect(hold.on(Self.down(Self.escape, modifiers: true), at: now))
    #expect(hold.state.holding == nil)
    _ = hold.on(.keyUp(code: Self.escape), at: now)
    #expect(!hold.on(Self.down(Self.escape, isRepeat: true), at: now))
    #expect(hold.state.holding == nil)
    _ = hold.on(.keyUp(code: Self.escape), at: now)
    #expect(hold.on(Self.down(kVK_Space), at: now))
    #expect(!hold.on(Self.down(kVK_Space, isRepeat: true), at: now))
    #expect(!hold.on(.keyUp(code: kVK_Space), at: now))
    #expect(hold.on(.touch, at: now) && hold.on(.touch, at: now))
  }

  /// 松开 esc：取消，不算触碰；重新按要从头算
  @Test func releasingCancelsHold() {
    let hold = Hold()
    let start = ContinuousClock.now
    _ = hold.on(Self.down(Self.escape), at: start)
    #expect(!hold.on(.keyUp(code: Self.escape), at: start + .milliseconds(1900)))
    #expect(hold.state.holding == nil && !hold.state.isComplete(at: start + .seconds(3)))
    _ = hold.on(Self.down(Self.escape), at: start + .seconds(3))
    #expect(hold.state.remaining(at: start + .seconds(4)) == .seconds(1))
    // 锁屏时整个清掉
    hold.state.reset()
    #expect(hold.state.holding == nil && !hold.state.isAnythingDown(at: start + .seconds(4)))
  }

  /// 左键按在退出提示里开始计时（不算触碰）、松开取消；按在外面、提示没显示着时只算触碰；鼠标按住期间按了键盘就取消
  @Test func mouseHoldOnHint() {
    let hints = [CGRect(x: 100, y: 50, width: 120, height: 44)]
    let hold = Hold()
    let start = ContinuousClock.now
    #expect(hold.on(.leftDown(at: CGPoint(x: 10, y: 10)), at: start, hints: hints))
    #expect(hold.state.holding == nil)
    _ = hold.on(.leftUp, at: start)
    // 提示没显示着（范围是空的）：同一个位置只算触碰
    #expect(hold.on(.leftDown(at: CGPoint(x: 150, y: 70)), at: start))
    _ = hold.on(.leftUp, at: start)
    #expect(!hold.on(.leftDown(at: CGPoint(x: 150, y: 70)), at: start, hints: hints))
    #expect(hold.state.holding?.source == .mouse)
    #expect(hold.state.isComplete(at: start + .seconds(2)))
    #expect(hold.on(Self.down(kVK_ANSI_A), at: start + .seconds(1), hints: hints))
    #expect(hold.state.holding == nil && !hold.state.isComplete(at: start + .seconds(2)))
    _ = hold.on(.keyUp(code: kVK_ANSI_A), at: start + .seconds(1))
    #expect(!hold.on(.leftUp, at: start + .milliseconds(1500), hints: hints))
    // 重新按住，松开取消
    #expect(!hold.on(.leftDown(at: CGPoint(x: 150, y: 70)), at: start + .seconds(3), hints: hints))
    #expect(hold.state.holding?.source == .mouse)
    #expect(!hold.on(.leftUp, at: start + .seconds(4), hints: hints))
    #expect(hold.state.holding == nil)
    // 第二块屏上的提示同样认
    let second = hints + [CGRect(x: 2000, y: -300, width: 120, height: 44)]
    #expect(!hold.on(.leftDown(at: CGPoint(x: 2010, y: -290)), at: start, hints: second))
    #expect(hold.state.holding?.source == .mouse)
  }

  /// 按住 esc 期间来了别的触碰（鼠标键、媒体键、大写锁定、修饰键）：取消，要松开重按（Z7：抹布一把抹过去不会退出）
  @Test func anyOtherTouchCancelsHold() throws {
    let start = ContinuousClock.now
    let shift = try #require(
      InputBlock.classify(
        type: 12, code: kVK_Shift, isRepeat: false, flags: CGEventFlags.maskShift.rawValue,
        location: .zero, primaryHeight: 0, subtype: nil, data1: 0
      ).event)
    let others: [InputBlock.Event] = [.touch, .leftDown(at: .zero), shift]
    for other in others {
      let hold = Hold()
      _ = hold.on(Self.down(Self.escape), at: start)
      #expect(hold.on(other, at: start + .seconds(1)), "\(other)")
      #expect(hold.state.holding == nil && !hold.state.isComplete(at: start + .seconds(3)))
    }
    // 修饰键还按着时按 esc：不开始（带修饰键），算触碰；修饰键松开后再按才开始
    let hold = Hold()
    _ = hold.on(shift, at: start)
    #expect(hold.on(Self.down(Self.escape, modifiers: true), at: start + .milliseconds(100)))
    #expect(hold.state.holding == nil)
    _ = hold.on(.keyUp(code: Self.escape), at: start + .milliseconds(200))
    _ = hold.on(.keyUp(code: kVK_Shift), at: start + .milliseconds(200))
    #expect(!hold.on(Self.down(Self.escape), at: start + .milliseconds(300)))
    #expect(hold.state.holding?.source == .key)
  }

  /// 滚动每秒最多算一次触碰
  @Test func scrollCountsOncePerSecond() {
    let hold = Hold()
    let start = ContinuousClock.now
    #expect(hold.on(.scroll, at: start))
    #expect(!hold.on(.scroll, at: start + .milliseconds(10)))
    #expect(!hold.on(.scroll, at: start + .milliseconds(999)))
    #expect(hold.on(.scroll, at: start + .seconds(1)))
    #expect(!hold.on(.scroll, at: start + .milliseconds(1500)))
    // 滚动不打断按住
    _ = hold.on(Self.down(Self.escape), at: start + .seconds(3))
    #expect(hold.on(.scroll, at: start + .seconds(4)))
    #expect(hold.state.isComplete(at: start + .seconds(5)))
  }

  /// 松开的那一下没收到的键不能永远挡着 esc：过了 staleAfter 没有新动静就不算按着；按住不放的（一直有连发）照样算
  @Test func staleKeysDoNotBlockEscape() {
    let hold = Hold()
    let start = ContinuousClock.now
    _ = hold.on(Self.down(kVK_ANSI_A), at: start)
    #expect(hold.on(Self.down(Self.escape), at: start + .seconds(4)))
    #expect(hold.state.holding == nil)
    _ = hold.on(.keyUp(code: Self.escape), at: start + .seconds(4))
    #expect(!hold.on(Self.down(Self.escape), at: start + .seconds(6)))
    #expect(hold.state.holding != nil)
    let held = Hold()
    _ = held.on(Self.down(kVK_ANSI_A), at: start)
    for second in 1...6 {
      _ = held.on(Self.down(kVK_ANSI_A, isRepeat: true), at: start + .seconds(second))
    }
    #expect(held.on(Self.down(Self.escape), at: start + .seconds(7)))
    #expect(held.state.holding == nil)
  }

  /// 退出之后拦截留到按着的键松开：按住满了的 esc / 左键还算按着，松开就没有了
  @Test func lingerUntilReleased() {
    let hold = Hold()
    let start = ContinuousClock.now
    #expect(!hold.state.isAnythingDown(at: start))
    _ = hold.on(Self.down(Self.escape), at: start)
    _ = hold.on(Self.down(Self.escape, isRepeat: true), at: start + .seconds(2))
    #expect(hold.state.isAnythingDown(at: start + .seconds(2)))
    _ = hold.on(.keyUp(code: Self.escape), at: start + .milliseconds(2300))
    #expect(!hold.state.isAnythingDown(at: start + .milliseconds(2300)))
    _ = hold.on(.leftDown(at: .zero), at: start + .seconds(3))
    #expect(hold.state.isAnythingDown(at: start + .seconds(30)))
    _ = hold.on(.leftUp, at: start + .seconds(31))
    #expect(!hold.state.isAnythingDown(at: start + .seconds(31)))
  }

  // MARK: 文字和范围

  @Test func durationText() {
    #expect(StatusScreen.span(0) == "不到 1 分钟" && StatusScreen.span(59) == "不到 1 分钟")
    #expect(StatusScreen.span(60) == "1 分钟" && StatusScreen.span(59 * 60 + 59) == "59 分钟")
    #expect(StatusScreen.span(3600) == "1 小时" && StatusScreen.span(83 * 60) == "1 小时 23 分")
    #expect(StatusScreen.footer(started: "14:02", seconds: 83 * 60) == "14:02 开始 · 已 1 小时 23 分")
    #expect(StatusScreen.footer(started: "14:02", seconds: 30) == "14:02 开始 · 不到 1 分钟")
    #expect(
      StatusScreen.summary(.held, seconds: 83 * 60, touches: 12, autoEndMinutes: 0)
        == "持续 1 小时 23 分 · 挡下 12 次触碰")
    #expect(
      StatusScreen.summary(.unlocked, seconds: 300, touches: 0, autoEndMinutes: 0) == "持续 5 分钟")
    #expect(
      StatusScreen.summary(.held, seconds: 20, touches: 1, autoEndMinutes: 5)
        == "持续不到 1 分钟 · 挡下 1 次触碰")
    #expect(
      StatusScreen.summary(.autoEnd, seconds: 300, touches: 0, autoEndMinutes: 5) == "到 5 分钟自动结束")
    #expect(
      StatusScreen.summary(.autoEnd, seconds: 3600, touches: 3, autoEndMinutes: 60)
        == "到 1 小时自动结束 · 挡下 3 次触碰")
  }

  /// 防残影：第 0 分钟在正中，之后每分钟挪几个点，横向 ±12、纵向 ±8 以内，不会连着三分钟停在同一个位置
  @Test func driftStaysSmallAndMoves() {
    #expect(StatusScreen.drift(minute: 0) == .zero)
    var seen: Set<String> = []
    for minute in 0..<600 {
      let offset = StatusScreen.drift(minute: minute)
      #expect(abs(offset.width) <= 12 && abs(offset.height) <= 8, "\(minute)")
      #expect(offset.width == offset.width.rounded() && offset.height == offset.height.rounded())
      let next = (StatusScreen.drift(minute: minute + 1), StatusScreen.drift(minute: minute + 2))
      #expect(offset != next.0 || offset != next.1, "\(minute)")
      seen.insert("\(offset.width),\(offset.height)")
    }
    // 不是在两三个位置之间来回
    #expect(seen.count > 40)
  }

  /// 每块屏各有一枚退出提示（底部居中，各算各的范围）；鼠标所在屏的面板当 key，都不在就第一块
  @Test func hintAndKeyScreen() {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let side = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
    let hint = StatusScreen.hintFrame(in: main)
    #expect(hint.size == StatusScreen.hintSize && hint.midX == main.midX)
    #expect(hint.minY == StatusScreen.hintBottom && main.contains(hint))
    let other = StatusScreen.hintFrame(in: side)
    #expect(other.midX == side.midX && other.minY == side.minY + StatusScreen.hintBottom)
    #expect(side.contains(other) && !other.intersects(hint))
    #expect(StatusScreen.keyIndex(mouse: CGPoint(x: 100, y: 100), screens: [main, side]) == 0)
    #expect(StatusScreen.keyIndex(mouse: CGPoint(x: 2000, y: -100), screens: [main, side]) == 1)
    #expect(StatusScreen.keyIndex(mouse: CGPoint(x: -500, y: 5000), screens: [main, side]) == 0)
    // 电源：照常不拦，不睡眠只防系统闲置睡眠，屏幕常亮连显示器一起防
    #expect(StatusScreen.activityOptions(.normal) == nil)
    #expect(StatusScreen.activityOptions(.awake)?.contains(.idleDisplaySleepDisabled) == false)
    #expect(StatusScreen.activityOptions(.awake)?.contains(.idleSystemSleepDisabled) == true)
    #expect(StatusScreen.activityOptions(.displayOn)?.contains(.idleDisplaySleepDisabled) == true)
    // 底色：熄屏、告示纯黑不透明，透出压暗（还看得见后面）
    #expect(StatusScreenPanel.backdrop(.blackout) == .black)
    #expect(StatusScreenPanel.backdrop(.sign) == .black)
    let scrim = StatusScreenPanel.backdrop(.dim).alphaComponent
    #expect(scrim > 0.5 && scrim < 0.9)
    // 标题字号跟屏高走，夹在 44–96
    #expect(StatusScreenView.titleSize(screenHeight: 400) == 44)
    #expect(StatusScreenView.titleSize(screenHeight: 1000) == 75)
    #expect(StatusScreenView.titleSize(screenHeight: 2160) == 96)
  }

  // MARK: 拦截

  /// 拦截对各类事件：按键、鼠标键、滚轮、手势、修饰键都吞；媒体键（类型 14 subtype 8）吞、别的 subtype 放行；
  /// 鼠标移动和拖动不在要拦的类型里
  @Test func blockClassification() {
    func classify(
      _ type: UInt32, code: Int = 0, isRepeat: Bool = false, flags: CGEventFlags = [],
      at point: CGPoint = .zero, subtype: Int? = nil, data1: Int = 0
    ) -> (swallow: Bool, event: InputBlock.Event?) {
      InputBlock.classify(
        type: type, code: code, isRepeat: isRepeat, flags: flags.rawValue, location: point,
        primaryHeight: 1000, subtype: subtype, data1: data1)
    }
    #expect(
      classify(10, code: kVK_Escape)
        == (true, .keyDown(code: kVK_Escape, isRepeat: false, hasModifiers: false)))
    #expect(
      classify(10, code: kVK_Tab, isRepeat: true, flags: .maskCommand)
        == (true, .keyDown(code: kVK_Tab, isRepeat: true, hasModifiers: true)))
    // 大写锁定、fn 不算带修饰键
    #expect(
      classify(10, code: kVK_Escape, flags: [.maskAlphaShift, .maskSecondaryFn])
        == (true, .keyDown(code: kVK_Escape, isRepeat: false, hasModifiers: false)))
    #expect(classify(11, code: kVK_Escape) == (true, .keyUp(code: kVK_Escape)))
    // 位置换成 AppKit 的全局坐标（原点左下）
    #expect(
      classify(1, at: CGPoint(x: 300, y: 100)) == (true, .leftDown(at: CGPoint(x: 300, y: 900))))
    #expect(classify(2) == (true, .leftUp))
    #expect(classify(3) == (true, .touch) && classify(25) == (true, .touch))
    #expect(classify(22) == (true, .scroll))
    // 只吞不报：右键 / 其他键松开、其他键拖动、手势、认不出键码的修饰键事件
    for type: UInt32 in [4, 12, 18, 19, 20, 26, 27, 29, 30, 31] {
      #expect(classify(type) == (true, nil), "\(type)")
    }
    // 修饰键也是键：它那一位标志在就是按下（算带修饰键）、不在就是松开；左右两个键共用一位；大写锁定每按一下算一次触碰
    #expect(
      classify(12, code: kVK_Shift, flags: .maskShift)
        == (true, .keyDown(code: kVK_Shift, isRepeat: false, hasModifiers: true)))
    #expect(classify(12, code: kVK_Shift) == (true, .keyUp(code: kVK_Shift)))
    #expect(
      classify(12, code: kVK_RightCommand, flags: [.maskCommand, .maskShift])
        == (true, .keyDown(code: kVK_RightCommand, isRepeat: false, hasModifiers: true)))
    #expect(
      classify(12, code: kVK_Option, flags: .maskShift) == (true, .keyUp(code: kVK_Option)))
    #expect(
      classify(12, code: kVK_Function, flags: .maskSecondaryFn)
        == (true, .keyDown(code: kVK_Function, isRepeat: false, hasModifiers: true)))
    #expect(classify(12, code: kVK_CapsLock, flags: .maskAlphaShift) == (true, .touch))
    #expect(classify(12, code: kVK_CapsLock) == (true, .touch))
    // 媒体键：按下报一次触碰，松开、连发只吞；别的 subtype 放行
    let soundUp = Int(NX_KEYTYPE_SOUND_UP) << 16
    #expect(classify(14, subtype: 8, data1: soundUp | 0xA00) == (true, .touch))
    #expect(classify(14, subtype: 8, data1: soundUp | 0xB00) == (true, nil))
    #expect(classify(14, subtype: 8, data1: soundUp | 0xA01) == (true, nil))
    #expect(classify(14, subtype: 7) == (false, nil) && classify(14) == (false, nil))
    // 鼠标移动、左右键拖动不拦
    #expect(!InputBlock.types.contains { [5, 6, 7].contains($0) })
    for type: UInt32 in [5, 6, 7] { #expect(classify(type) == (false, nil), "\(type)") }
    #expect(Set(InputBlock.types).count == 18)
  }

  // MARK: 入口

  /// 全局快捷键追加在末尾、不设默认键，自己一节；启动器里不是一条「状态屏」，而是每个状态一条，
  /// 搜状态的标题、「状态屏」、拼音都找得到
  @Test func entries() throws {
    #expect(HotKeyAction.allCases.last == .statusScreen)
    #expect(HotKeyAction.statusScreen.defaultHotKey == nil)
    #expect(HotKeyAction.sections.last?.title == "状态屏")
    #expect(HotKeyAction.sections.last?.actions == [.statusScreen])
    #expect(LauncherItem.actions().allSatisfy { !$0.isStatusPreset })
    var presets = StatusPreset.builtIn
    presets[2].symbol = ""
    let items = LauncherItem.actions(.init(statusPresets: presets))
    let targets = items.map(\.target)
    let first = try #require(targets.firstIndex(of: "statusScreen:clean"))
    #expect(
      Array(targets[(first - 1)...(first + 3)]) == [
        "pinClipboard", "statusScreen:clean", "statusScreen:busy", "statusScreen:back", "settings",
      ])
    let statuses = items.filter(\.isStatusPreset)
    #expect(statuses.map(\.title) == ["清洁屏幕", "请勿触碰", "马上回来"])
    // 副标题同别的内置动作（右侧类型才写「状态屏」，不重复）
    #expect(statuses.allSatisfy { $0.subtitle == "Kitty Tools" && $0.kind == .action })
    // 图标是状态自己的；没选图标的用「只有字」的符号垫着
    #expect(statuses.map(\.symbol) == ["sparkles", "hand.raised.fill", "text.alignleft"])
    #expect(NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) != nil)
    // 全局快捷键进的是排在最前面的那个：只有它选中时显示键帽（同别的带全局快捷键的内置动作）
    #expect(statuses.map(\.hotKeyAction) == [.statusScreen, nil, nil])
    let reordered = LauncherItem.actions(.init(statusPresets: [presets[1], presets[0]]))
      .filter(\.isStatusPreset)
    #expect(reordered.map(\.title) == ["请勿触碰", "清洁屏幕"])
    #expect(reordered.map(\.hotKeyAction) == [.statusScreen, nil])
    // ↩ 直接进入、不确认：同分时排在别的结果后面（同系统命令、退出本 App）
    #expect(statuses.allSatisfy { LauncherMatch.priority($0) == 1 })
    #expect(
      items.filter { !$0.isStatusPreset && $0.target != "quit" }.allSatisfy {
        LauncherMatch.priority($0) == 0
      })
    let busy = statuses[1]
    for query in ["请勿", "qingwu", "状态屏", "zhuangtai", "ztp", "status"] {
      #expect(LauncherMatch.score(query, item: busy) > 0, "\(query)")
    }
  }

  // MARK: 实机自检

  private final class Seen {
    var events: [InputBlock.Event] = []
    var monitored: [Int] = []
  }

  /// 产品的 InputBlock 真建起来：合成的 ⌃⌥⇧⌘F18 处理函数收到按下 / 松开、别的全局监听收不到；作废之后不再吞、不再报
  @Test(.enabled(if: live)) func liveBlockSwallowsKeys() throws {
    try #require(CGPreflightPostEventAccess(), "要「辅助功能」授权才能发合成按键")
    let seen = Seen()
    let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
      let code = Int(event.keyCode)
      MainActor.assumeIsolated { seen.monitored.append(code) }
    }
    defer { monitor.map(NSEvent.removeMonitor) }
    let block = try #require(InputBlock { seen.events.append($0) }, "拦截没建起来")
    // 无论断言成不成，拦截都要撤掉、合成按键带的修饰键要松开
    defer {
      block.invalidate()
      Self.releaseModifiers()
    }
    Self.pressF18()
    Self.pump(0.4)
    block.invalidate()
    let (swallowed, leaked) = (seen.events, seen.monitored)
    #expect(swallowed.contains(.keyDown(code: kVK_F18, isRepeat: false, hasModifiers: true)))
    #expect(swallowed.contains(.keyUp(code: kVK_F18)))
    #expect(!leaked.contains(kVK_F18), "吞掉的按键别的监听不该收到")
    // 作废之后：同一个按键别的监听收得到，处理函数不再收到
    Self.pressF18()
    Self.pump(0.4)
    #expect(seen.monitored.contains(kVK_F18), "作废之后按键该放行")
    #expect(seen.events == swallowed, "作废之后不该再报事件")
    print(
      "InputBlock 实机自检：拦着时处理函数收到 \(swallowed)，别的监听收到 \(leaked)；"
        + "作废后别的监听收到 \(seen.monitored)，处理函数多收到 \(seen.events.count - swallowed.count) 个")
  }

  private static func pressF18() {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_F18), keyDown: down)
      event?.flags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]
      event?.post(tap: .cghidEventTap)
    }
  }

  /// 合成按键带的修饰键会留在系统的修饰键状态里（mac-overlay-panel §7）：补一个不带修饰键的「松开 ⌘」和一次 flagsChanged
  private static func releaseModifiers() {
    let source = CGEventSource(stateID: .hidSystemState)
    let up = CGEvent(
      keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
    up?.flags = []
    up?.post(tap: .cghidEventTap)
    let changed = CGEvent(source: source)
    changed?.type = .flagsChanged
    changed?.flags = []
    changed?.post(tap: .cghidEventTap)
  }

  /// 同步测试挡住了 NSApp.run：自己取事件、派发（拦截的源在主运行环上，取事件时顺带跑）
  private static func pump(_ seconds: TimeInterval) {
    let end = Date.now.addingTimeInterval(seconds)
    while Date.now < end {
      if let event = NSApp.nextEvent(
        matching: .any, until: .now.addingTimeInterval(0.02), inMode: .default, dequeue: true)
      {
        NSApp.sendEvent(event)
      }
    }
  }
}
