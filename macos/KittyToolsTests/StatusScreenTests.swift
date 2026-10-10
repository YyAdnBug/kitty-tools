// 状态屏（PLAN §10）的纯函数单测：自带状态和编解码、sanitized 各条、退出判断（ExitHold：按住满 2 秒、别的触碰取消、带修饰键 / 连发
// 不算、松开取消、鼠标按在提示里外、滚动合并、「松不开」的键过期）、时长文字、退出提示和 key 面板的范围、拦截对事件的分类、
// 启动器里每个状态一条；设置 › 状态屏改列表的几个纯函数（加、删、挪、恢复自带的、详情页改一个、摘要）；选状态的面板
// （第 4 批：选中怎么移动、按键、默认选中、排版、进入时给出去的卡片位置）和从卡片长到整屏的起始变换；告示上的动画
// （第 5 批：表情的清单、17 个资源都在包里且解得出、旧符号名换成表情、每帧时长 → keyTimes、图层上挂的那段动画、
// 表情视图挂进屏外窗口真的在换帧、动不动 / 冒不冒眼睛 / 要解哪些帧的判断、表情和眼睛的尺寸位置、出场的时间表）。
// 不进入状态屏、不建面板。
//
// 另有一个按需的实机自检 liveBlockSwallowsKeys()（默认不跑）：真的建起产品的 InputBlock，发一次合成的 ⌃⌥⇧⌘F18，
// 看处理函数收到按下 / 松开、别的全局监听一个都没收到，作废之后再发一次、监听收得到。要「辅助功能」授权。
// **拦截是全吞的：建着的那约半秒里，真实的键盘、鼠标点按和滚轮也会被吞掉**（跑之前手离开键盘鼠标）；
// 作废后那一次 ⌃⌥⇧⌘F18 会发给前台 App（没人用的组合）。
//   TEST_RUNNER_KITTY_LIVE_INPUT_BLOCK=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test '-only-testing:KittyToolsTests/StatusScreenTests/liveBlockSwallowsKeys()'

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

/// emojiViewPlaysThenStops 用的：给表情视图换帧的那份状态，和把它摆进窗口的壳
@Observable private final class EmojiBox {
  var frames: StatusEmoji.Frames?
}

private struct EmojiHost: View {
  let box: EmojiBox

  var body: some View {
    StatusEmojiView(id: StatusEmoji.eyes, frames: box.frames).frame(width: 120, height: 120)
  }
}

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
    #expect(presets.map(\.symbol) == ["glowing-star", "raised-hand", "alarm-clock"])
    #expect(presets[1].detail == "电脑正在跑任务，别动键盘和鼠标" && presets[0].detail == nil)
    // 自带的本身就合规；编成 JSON 再读回来一样
    #expect(StatusPreset.sanitized(presets) == presets)
    #expect(StatusPreset.decode(try JSONEncoder().encode(presets)) == presets)
    // 没选图标时垫的系统符号，最低系统上有
    let plain = NSImage(systemSymbolName: StatusPreset.plainSymbol, accessibilityDescription: nil)
    #expect(plain != nil && StatusPreset.plainSymbol == "text.alignleft")
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
      preset("a", "  开会\n中  ", detail: "  \n ", symbol: "rocket", minutes: 15),
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
    #expect(clean[0].symbol == "rocket" && clean[0].autoEndMinutes == 15)
    #expect(clean[1].title.count == 30 && clean[1].detail?.count == 60)
    #expect(clean[2].symbol.isEmpty && clean[2].autoEndMinutes == 0)
    // 最多 20 个
    let many = (0..<30).map { preset("p\($0)", "状态 \($0)") }
    #expect(StatusPreset.sanitized(many).map(\.id) == (0..<20).map { "p\($0)" })
    // 清单里的 16 个表情都留着；「眼睛」只在被碰时用，不能选
    let all = StatusEmoji.ids.enumerated().map { preset("e\($0.offset)", "状态", symbol: $0.element) }
    #expect(StatusPreset.sanitized(all).map(\.symbol) == StatusEmoji.ids)
    let peeking = StatusPreset.sanitized([preset("eyes", "状态", symbol: StatusEmoji.eyes)])
    #expect(peeking.map(\.symbol) == [""])
  }

  /// 第 5 批之前图标存的是系统符号名（20 个）：意思对得上的 11 个换成对应的表情，其余置空；收拾一遍之后再收拾不变。
  /// 自带的三个原来是 sparkles / hand.raised.fill / clock.fill——存着旧名的列表读出来和现在自带的一模一样
  @Test func legacySymbolsBecomeEmoji() throws {
    let expected = [
      "sparkles": "glowing-star", "hand.raised.fill": "raised-hand", "clock.fill": "alarm-clock",
      "hourglass": "hourglass", "moon.fill": "sleeping-face", "zzz": "zzz",
      "cup.and.saucer.fill": "hot-beverage", "phone.fill": "telephone", "person.2.fill": "busts",
      "terminal.fill": "robot", "bolt.fill": "high-voltage", "fork.knife": "", "figure.walk": "",
      "video.fill": "", "hammer.fill": "", "arrow.down.circle.fill": "",
      "exclamationmark.triangle.fill": "", "bell.slash.fill": "", "headphones": "",
      "gamecontroller.fill": "",
    ]
    #expect(expected.count == 20)
    for (old, emoji) in expected {
      #expect(StatusPreset.emoji(for: old) == emoji, "\(old)")
      #expect(emoji.isEmpty || StatusEmoji.ids.contains(emoji), "\(emoji)")
    }
    #expect(StatusPreset.emoji(for: "") == "" && StatusPreset.emoji(for: "lock.fill") == "")
    #expect(StatusPreset.emoji(for: "../status-emoji-eyes") == "")
    for id in StatusEmoji.ids { #expect(StatusPreset.emoji(for: id) == id) }
    // 换过来的值都在清单里：对照表没有指到不存在的表情
    #expect(StatusPreset.legacySymbols.values.allSatisfy(StatusEmoji.ids.contains))
    var old = StatusPreset.builtIn
    for (index, symbol) in ["sparkles", "hand.raised.fill", "clock.fill"].enumerated() {
      old[index].symbol = symbol
    }
    let loaded = StatusPreset.decode(try JSONEncoder().encode(old))
    #expect(loaded == StatusPreset.builtIn && loaded.allSatisfy(\.isPristine))
    #expect(StatusPreset.sanitized(loaded) == loaded)
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
    // 按快捷键默认先选状态（直进的开关默认关，跟着导出走）；上次进入的是这台电脑自己的状态，不注册默认值
    #expect(Prefs.defaults[Prefs.statusScreenHotKeyEntersFirst] as? Bool == false)
    #expect(Prefs.defaults[Prefs.statusScreenLastPreset] == nil)
    // 告示上的动画默认开（注册了默认值：跟着导出走）
    #expect(Prefs.defaults[Prefs.statusScreenAnimations] as? Bool == true)
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
    draft.symbol = "rocket"
    updated = StatusPreset.updating(list, with: draft)
    #expect(updated[2].title == "马上回来" && updated[2].symbol == "rocket")
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
    // 图标是状态自己的表情（行里画它的静止画面）；没选的是空，行里用「只有字」的符号垫着。别的结果没有这一项
    #expect(statuses.map(\.presetEmoji) == ["glowing-star", "raised-hand", ""])
    #expect(statuses.allSatisfy { $0.symbol == "text.alignleft" })
    #expect(items.filter { !$0.isStatusPreset }.allSatisfy { $0.presetEmoji == nil })
    // 全局快捷键默认是先出选状态的面板：哪一条都不带键帽
    #expect(statuses.map(\.hotKeyAction) == [nil, nil, nil])
    // 设置里打开「按快捷键直接进入排在最前面的状态」：键进的是排在最前面的那个，只有它选中时显示键帽
    let direct = LauncherItem.actions(.init(statusPresets: presets, statusEntersFirst: true))
      .filter(\.isStatusPreset)
    #expect(direct.map(\.hotKeyAction) == [.statusScreen, nil, nil])
    let reordered = LauncherItem.actions(
      .init(statusPresets: [presets[1], presets[0]], statusEntersFirst: true)
    )
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

  // MARK: 告示上的动画（第 5 批）

  /// 清单：可选的 16 个、id 不重复、顺序固定、各有中文名；「眼睛」另算，不在可选的里面
  @Test func emojiCatalog() {
    #expect(
      StatusEmoji.ids == [
        "raised-hand", "waving-hand", "glowing-star", "alarm-clock", "hourglass", "hot-beverage",
        "zzz", "sleeping-face", "shushing-face", "busts", "telephone", "rocket", "robot", "fire",
        "high-voltage", "black-cat",
      ])
    #expect(
      StatusEmoji.choices.map(\.name) == [
        "举手", "挥手", "发光的星", "闹钟", "沙漏", "热饮", "Zzz", "睡觉", "嘘", "开会", "电话", "火箭", "机器人", "火",
        "闪电", "黑猫",
      ])
    #expect(Set(StatusEmoji.ids).count == 16 && Set(StatusEmoji.choices.map(\.name)).count == 16)
    #expect(StatusEmoji.eyes == "eyes" && !StatusEmoji.ids.contains(StatusEmoji.eyes))
    #expect(StatusEmoji.name("alarm-clock") == "闹钟" && StatusEmoji.name("eyes") == nil)
    #expect(StatusEmoji.name("") == nil)
    // 只认清单里的 id：空的、旧的符号名、带路径的都取不到文件，也没有静止画面
    for id in ["", "sparkles", "../status-emoji-eyes", "eyes/../rocket", "Rocket"] {
      #expect(StatusEmoji.url(id) == nil && StatusEmoji.still(id) == nil, "\(id)")
    }
  }

  /// 17 个资源都在包里（测试宿主就是 App）而且解得出：每个都取得到文件，帧数大于 1、每帧 256 × 256、带透明通道
  /// （四角是透明的）、每帧时长大于 0；静止画面就是第一帧那么大，取第二次是缓存里的同一张
  @Test func emojiResourcesDecode() async throws {
    for id in StatusEmoji.ids + [StatusEmoji.eyes] {
      let url = try #require(StatusEmoji.url(id), "\(id)")
      #expect(url.lastPathComponent == "status-emoji-\(id).heics")
      let frames = try #require(await StatusEmoji.decode(id), "\(id)")
      #expect(frames.images.count > 1 && frames.images.count == frames.delays.count, "\(id)")
      #expect(frames.delays.allSatisfy { $0 > 0 } && frames.duration > 1, "\(id)")
      for image in frames.images {
        #expect(image.width == 256 && image.height == 256, "\(id)")
        #expect(image.alphaInfo == .premultipliedFirst, "\(id)")
      }
      #expect(Self.alpha(of: frames.images[0], x: 0, y: 0) == 0, "\(id) 的左上角该是透明的")
      #expect(Self.opaquePixels(in: frames.images[0]) > 2000, "\(id) 的第一帧该有画面")
      #expect(frames.keyTimes.count == frames.images.count + 1, "\(id)")
      let still = try #require(StatusEmoji.still(id), "\(id)")
      #expect(still.width == 256 && still.height == 256 && still.alphaInfo == .premultipliedFirst)
      #expect(StatusEmoji.still(id) === still, "\(id)")
      #expect(Self.opaquePixels(in: still) == Self.opaquePixels(in: frames.images[0]), "\(id)")
    }
    #expect(StatusEmoji.menuImage("rocket")?.size == NSSize(width: 16, height: 16))
    #expect(StatusEmoji.menuImage("") == nil)
    #expect(await StatusEmoji.decode("sparkles") == nil)
    // 素材的许可随包带着（MIT 要求），关于页的链接打开的就是它
    let license = try #require(
      Bundle.main.url(forResource: "status-emoji-LICENSE", withExtension: "txt"))
    #expect(try String(contentsOf: license, encoding: .utf8).contains("MIT License"))
    #expect(AboutTab.emojiCredit == "状态屏的动画表情来自 Microsoft Fluent Emoji（MIT 许可）")
  }

  /// 解好的帧是预乘透明度的 BGRA（小端）：一个像素 4 字节，透明度在最后一个
  private static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    return data[y * image.bytesPerRow + x * 4 + 3]
  }

  private static func opaquePixels(in image: CGImage) -> Int {
    guard let data = image.dataProvider?.data as Data? else { return 0 }
    return (0..<image.height).reduce(0) { count, y in
      count
        + (0..<image.width).count { x in data[y * image.bytesPerRow + x * 4 + 3] > 200 }
    }
  }

  /// 每帧时长 → 关键帧动画离散模式的 keyTimes：比帧数多一个，从 0 到 1，按时长分；总时长是各帧之和
  @Test func emojiKeyTimes() {
    #expect(StatusEmoji.keyTimes([0.1, 0.1, 0.2]) == [0, 0.25, 0.5, 1])
    #expect(StatusEmoji.keyTimes([0.5]) == [0, 1])
    #expect(StatusEmoji.keyTimes([]).isEmpty && StatusEmoji.keyTimes([0, 0]).isEmpty)
    let even = StatusEmoji.keyTimes(Array(repeating: 0.041, count: 73))
    #expect(even.count == 74 && even.first == 0 && even.last == 1)
    #expect(zip(even, even.dropFirst()).allSatisfy { $0 < $1 })
    #expect(abs(even[1] - 1.0 / 73) < 1e-9)
    let frames = StatusEmoji.Frames(images: [], delays: [0.041, 0.041, 0.1])
    #expect(abs(frames.duration - 0.182) < 1e-9 && frames.keyTimes.count == 4)
  }

  /// 图层上挂的那段动画：按帧换 contents 的离散关键帧动画，无限循环，时长是各帧之和；图层自己的 contents 不动
  /// （动画一拿掉就什么都不显示，静止画面在它下面）；同一份帧再给一次不重新挂（不从头播），换一份才换
  @Test func emojiPlaysAsKeyframes() async throws {
    let frames = try #require(await StatusEmoji.decode(StatusEmoji.eyes))
    let layer = CALayer()
    StatusEmoji.play(frames, on: layer)
    let animation = try #require(
      layer.animation(forKey: StatusEmoji.animationKey) as? CAKeyframeAnimation)
    #expect(animation.keyPath == "contents" && animation.calculationMode == .discrete)
    #expect(animation.values?.count == frames.images.count)
    #expect(animation.values?.first as AnyObject? === frames.images[0])
    #expect(animation.keyTimes?.count == frames.images.count + 1)
    #expect(animation.keyTimes?.first == 0 && animation.keyTimes?.last == 1)
    #expect(animation.repeatCount == .infinity && animation.duration == frames.duration)
    #expect(layer.contents == nil && layer.animationKeys() == [StatusEmoji.animationKey])
    // 同一份：还是原来那段（图层手里是同一个动画对象）
    StatusEmoji.play(frames, on: layer)
    #expect(layer.animation(forKey: StatusEmoji.animationKey) === animation)
    #expect(layer.animationKeys()?.count == 1)
    // 换一份帧：换成新的
    let other = StatusEmoji.Frames(
      images: Array(frames.images.reversed()), delays: frames.delays)
    StatusEmoji.play(other, on: layer)
    let replaced = layer.animation(forKey: StatusEmoji.animationKey) as? CAKeyframeAnimation
    #expect(replaced !== animation && replaced?.values?.first as AnyObject? === other.images[0])
    #expect(layer.animationKeys()?.count == 1)
  }

  /// 表情视图真挂进窗口走一遍（屏外的普通窗口）：没有帧时只有静止画面、没有哪一层在播；帧来了，播的那一层挂着动画，
  /// 过一会儿画面真的换到了后面的帧（都是给它的那些帧）；帧拿走，那一层连动画一起拆掉
  @Test func emojiViewPlaysThenStops() async throws {
    let box = EmojiBox()
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: EmojiHost(box: box))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    func playing(_ layer: CALayer?) -> CALayer? {
      guard let layer else { return nil }
      if layer.animation(forKey: StatusEmoji.animationKey) != nil { return layer }
      return layer.sublayers?.lazy.compactMap(playing).first
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(playing(window.contentView?.layer) == nil)
    let frames = try #require(await StatusEmoji.decode(StatusEmoji.eyes))
    let known = Set(frames.images.map { ObjectIdentifier($0) })
    box.frames = frames
    var shown: Set<ObjectIdentifier> = []
    for _ in 0..<40 where shown.count < 3 {
      try await Task.sleep(for: .milliseconds(50))
      if let contents = playing(window.contentView?.layer)?.presentation()?.contents {
        shown.insert(ObjectIdentifier(contents as AnyObject))
      }
    }
    #expect(shown.count >= 3 && shown.isSubset(of: known), "看到 \(shown.count) 帧")
    let layer = try #require(playing(window.contentView?.layer))
    #expect(layer.contents == nil && layer.contentsGravity == .resizeAspect)
    box.frames = nil
    for _ in 0..<40 where playing(window.contentView?.layer) != nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(playing(window.contentView?.layer) == nil)
    #expect(layer.animation(forKey: StatusEmoji.animationKey) == nil)
  }

  /// 动不动：总开关开着而且系统没开「减弱动态效果」才动。冒不冒眼睛：动着才冒，熄屏样式不冒。
  /// 进入时要解哪些帧：这个状态的表情（选了才有）和眼睛；熄屏、不动时一个都不解
  @Test func animationDecisions() {
    #expect(StatusScreen.animates(enabled: true, reduceMotion: false))
    #expect(!StatusScreen.animates(enabled: false, reduceMotion: false))
    #expect(!StatusScreen.animates(enabled: true, reduceMotion: true))
    #expect(!StatusScreen.animates(enabled: false, reduceMotion: true))
    #expect(StatusScreen.peeks(.sign, animates: true) && StatusScreen.peeks(.dim, animates: true))
    #expect(!StatusScreen.peeks(.blackout, animates: true))
    for look in StatusPreset.Look.allCases { #expect(!StatusScreen.peeks(look, animates: false)) }
    let (clean, busy, back) = (
      StatusPreset.builtIn[0], StatusPreset.builtIn[1], StatusPreset.builtIn[2]
    )
    #expect(StatusScreen.emojiToDecode(busy, animates: true) == ["raised-hand", "eyes"])
    #expect(StatusScreen.emojiToDecode(back, animates: true) == ["alarm-clock", "eyes"])
    #expect(StatusScreen.emojiToDecode(clean, animates: true).isEmpty)
    #expect(StatusScreen.emojiToDecode(preset("plain"), animates: true) == ["eyes"])
    for preset in StatusPreset.builtIn {
      #expect(StatusScreen.emojiToDecode(preset, animates: false).isEmpty)
    }
    // 摆样子的会话（截图自检、预览、卡片）默认不动、出场摆在播完；真的会话的出场由画面自己播
    let still = StatusScreen(showing: busy, startedAt: .now, elapsed: 0)
    #expect(!still.animates && !still.showsEyes && still.frames.isEmpty)
    #expect(still.entranceAt == .infinity && StatusScreen().entranceAt == nil)
    let posed = StatusScreen(
      showing: busy, startedAt: .now, elapsed: 0, showsEyes: true, animates: true, entrance: 0.3)
    #expect(posed.animates && posed.showsEyes && posed.entranceAt == 0.3)
  }

  /// 表情的边长 = 标题字号 × 1.3；眼睛的边长 = 标题字号，在退出提示右边、露出八成（下面两成在屏幕底边外），每块屏各算各的
  @Test func emojiAndEyesGeometry() {
    #expect(abs(StatusScreenView.emojiSide(title: 60) - 78) < 0.001)
    #expect(abs(StatusScreenView.emojiSide(title: 96) - 124.8) < 0.001)
    #expect(StatusScreen.eyesSide(screenHeight: 800) == 60)
    #expect(StatusScreen.eyesSide(screenHeight: 400) == 44)
    #expect(StatusScreen.eyesSide(screenHeight: 2160) == 96)
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let side = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
    for screen in [main, side] {
      let (eyes, hint) = (StatusScreen.eyesFrame(in: screen), StatusScreen.hintFrame(in: screen))
      let edge = StatusScreen.eyesSide(screenHeight: screen.height)
      #expect(eyes.size == CGSize(width: edge, height: edge))
      #expect(eyes.minX == hint.maxX + StatusScreen.eyesGap && !eyes.intersects(hint))
      // 露出来的那一截：从屏幕底边起，高是整只的八成；左右都在这块屏里
      let shown = eyes.intersection(screen)
      #expect(shown.minY == screen.minY && abs(shown.height - edge * 0.8) < 0.001)
      #expect(abs(shown.width - edge) < 0.001 && eyes.maxX < screen.maxX)
      // 缩回去（往下挪一个边长）就整只在屏幕外
      #expect(!eyes.offsetBy(dx: 0, dy: -edge).intersects(screen))
    }
  }

  /// 出场的时间表：表情一上来就落下；标题第一个字 0.06 s 起、字与字错开 0.045 s、每个字走 0.28 s，先快后慢；
  /// 说明和小字等最后一个字浮到一半才淡入；整个出场结束时所有东西都到位。标题很长时错开的间隔压小，30 个字也在 1.4 s 内出完
  @Test func entranceTimetable() {
    let four = StatusEntrance(glyphs: 4)
    #expect(four.step == 0.045)
    #expect(abs(four.restStart - (0.06 + 0.135 + 0.14)) < 1e-9)
    #expect(abs(four.end - (four.restStart + 0.28)) < 1e-9)
    // 一开始什么都没有
    #expect(StatusEntrance.emoji(at: 0) == 0 && StatusEntrance.board(at: 0) == 0)
    #expect((0..<4).allSatisfy { four.glyph($0, at: 0) == 0 } && four.rest(at: 0) == 0)
    // 0.2 s：前面的字浮得多、后面的少，第四个字刚开始；说明还没出
    let mid = (0..<4).map { four.glyph($0, at: 0.2) }
    #expect(mid[0] > mid[1] && mid[1] > mid[2] && mid[2] > mid[3] && mid[3] > 0 && mid[0] < 1)
    #expect(four.rest(at: 0.2) == 0)
    // 先快后慢：走了一半时间，浮现过半
    #expect(four.glyph(0, at: 0.06 + 0.14) > 0.8)
    // 各个字到点正好浮完；说明从 restStart 起线性淡入
    for index in 0..<4 {
      let done = 0.06 + 0.045 * Double(index) + 0.28
      #expect(four.glyph(index, at: done) == 1 && four.glyph(index, at: done - 0.05) < 1)
    }
    #expect(abs(four.rest(at: four.restStart + 0.14) - 0.5) < 1e-9)
    // 结束时（和摆在无穷大时）都到位
    for time in [four.end, .infinity] {
      #expect((0..<8).allSatisfy { four.glyph($0, at: time) == 1 })
      #expect(four.rest(at: time) == 1 && StatusEntrance.emoji(at: time) == 1)
      #expect(StatusEntrance.board(at: time) == 1)
    }
    #expect(StatusEntrance.emoji(at: 0.32) == 1 && StatusEntrance.emoji(at: 0.16) > 0.8)
    #expect(StatusEntrance.board(at: 0.1) == 0.5 && StatusEntrance.board(at: 0.2) == 1)
    // 字形比字数多：多出来的跟最后一个字一起
    #expect(four.glyph(9, at: 0.25) == four.glyph(3, at: 0.25))
    // 长标题：间隔压小，整个标题 0.9 s 内都开始浮现
    let long = StatusEntrance(glyphs: StatusPreset.maxTitle)
    #expect(abs(long.step - 0.9 / 29) < 1e-9 && long.end < 1.4)
    #expect(long.glyph(29, at: 0.06 + 0.9) < 0.001 && long.glyph(29, at: long.end) == 1)
    #expect(StatusEntrance(glyphs: 22).step < 0.045)
    #expect(abs(StatusEntrance(glyphs: 21).step - 0.045) < 1e-12)
    // 一个字、空标题也不出错
    for count in [0, 1] {
      let short = StatusEntrance(glyphs: count)
      #expect(short.step == 0 && abs(short.restStart - 0.2) < 1e-9)
      #expect(short.glyph(0, at: 0.34) == 1 && short.glyph(0, at: 0) == 0)
    }
  }

  /// 标题的渲染器和它用的时间表在渲染线程上也能用（mac-native §3：TextRenderer 的类型必须 nonisolated——默认的主线程隔离
  /// 编译零警告，动画一播就闪退）：在主线程外建、读、改一遍。能编译就说明没有绑着主线程
  @concurrent nonisolated private static func rendererOffMain() async -> Double {
    #expect(pthread_main_np() == 0)
    var renderer = GlyphEmerge(time: 0, entrance: StatusEntrance(glyphs: 4), rise: 10)
    renderer.animatableData = 0.2
    return renderer.entrance.glyph(0, at: renderer.time) * Double(GlyphEmerge.blur)
  }

  /// 出场真的播一遍（屏外的普通窗口，不建状态屏的面板、不进入）：画面出现后逐字浮现的渲染器被逐帧调，播完不闪退；
  /// 摆在中间一刻的画面也画得出来
  @Test func entrancePlaysWithoutCrashing() async throws {
    #expect(await Self.rendererOffMain() == 0.875 * 8)
    for entrance in [nil, 0.25] as [Double?] {
      let screen = StatusScreen(
        showing: StatusPreset.builtIn[1], startedAt: .now, elapsed: 0, showsEyes: true,
        animates: true, entrance: entrance)
      let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: StatusScreenView(screen: screen))
      window.orderFront(nil)
      try await Task.sleep(for: .seconds(entrance == nil ? 1 : 0.2))
      #expect(window.isVisible)
      window.orderOut(nil)
    }
  }

  // MARK: 选状态的面板

  /// ←→ 挨个走、到头回绕；↑↓ 换行、列不变，到头不动；下一行不满、正下方没有卡片时落在最后一张
  @Test func pickerMoves() {
    let moved = StatusPicker.moved
    // 7 张：第一行 0–3，第二行 4–6
    #expect(moved(0, .right, 7) == 1 && moved(3, .right, 7) == 4)
    #expect(moved(6, .right, 7) == 0 && moved(0, .left, 7) == 6)
    #expect(moved(4, .left, 7) == 3)
    #expect(moved(0, .down, 7) == 4 && moved(2, .down, 7) == 6)
    // 正下方没有卡片：落在最后一张；已经在最后一行、第一行：不动
    #expect(moved(3, .down, 7) == 6)
    #expect(moved(5, .down, 7) == 5 && moved(1, .up, 7) == 1)
    #expect(moved(4, .up, 7) == 0 && moved(6, .up, 7) == 2)
    // 只有一行：↑↓ 不动，←→ 照样回绕；只有一张：都不动
    for index in 0..<3 {
      #expect(moved(index, .up, 3) == index && moved(index, .down, 3) == index)
    }
    #expect(moved(2, .right, 3) == 0 && moved(0, .left, 3) == 2)
    for move in [StatusPicker.Move.left, .right, .up, .down] { #expect(moved(0, move, 1) == 0) }
    // 正好满行（8 张）、三行（9 张：最后一行只有一张）
    #expect(moved(7, .right, 8) == 0 && moved(3, .down, 8) == 7 && moved(7, .down, 8) == 7)
    #expect(moved(5, .down, 9) == 8 && moved(4, .down, 9) == 8 && moved(8, .up, 9) == 4)
    // 20 张走一圈回到原处，每张都到过
    var (index, seen) = (0, Set<Int>())
    for _ in 0..<20 {
      index = moved(index, .right, 20)
      seen.insert(index)
    }
    #expect(index == 0 && seen.count == 20)
    #expect(moved(0, .right, 0) == 0)
  }

  /// 按键：方向键、Tab / ⇧Tab（同 → ←）、↩ 和小键盘 Enter、Esc、主键盘和小键盘的 1–9（按键码，不看布局）；
  /// 带 ⌘⌃⌥ 的、别的键不认（交还给系统）
  @Test func pickerKeys() {
    func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) -> StatusPicker.Key? {
      StatusPicker.key(code: code, modifiers: flags)
    }
    // 方向键的事件自带 numericPad、function 两个标志
    let arrow: NSEvent.ModifierFlags = [.numericPad, .function]
    #expect(
      key(kVK_LeftArrow, arrow) == .move(.left) && key(kVK_RightArrow, arrow) == .move(.right))
    #expect(key(kVK_UpArrow, arrow) == .move(.up) && key(kVK_DownArrow, arrow) == .move(.down))
    #expect(key(kVK_Tab) == .move(.right) && key(kVK_Tab, .shift) == .move(.left))
    #expect(key(kVK_Return) == .enter && key(kVK_ANSI_KeypadEnter, .numericPad) == .enter)
    #expect(key(kVK_Escape) == .cancel)
    #expect(
      key(kVK_ANSI_1) == .pick(0) && key(kVK_ANSI_5) == .pick(4) && key(kVK_ANSI_9) == .pick(8))
    #expect(key(kVK_ANSI_Keypad1, .numericPad) == .pick(0))
    #expect(key(kVK_ANSI_Keypad9, .numericPad) == .pick(8))
    // 大写锁定开着、按着 ⇧（有的布局数字要 ⇧）照认
    #expect(key(kVK_ANSI_3, .capsLock) == .pick(2) && key(kVK_ANSI_3, .shift) == .pick(2))
    #expect(key(kVK_ANSI_0) == nil && key(kVK_ANSI_A) == nil && key(kVK_Space) == nil)
    for flags: NSEvent.ModifierFlags in [.command, .control, .option] {
      #expect(key(kVK_ANSI_1, flags) == nil && key(kVK_Return, flags) == nil, "\(flags)")
      #expect(key(kVK_RightArrow, flags.union(arrow)) == nil, "\(flags)")
    }
    // 底栏「直接进入」后面的键帽写到有几张为止
    #expect(StatusPicker.digitsCap(count: 1) == "1" && StatusPicker.digitsCap(count: 3) == "1–3")
    #expect(StatusPicker.digitsCap(count: 9) == "1–9" && StatusPicker.digitsCap(count: 20) == "1–9")
  }

  /// 默认选中上次进入的那个；没有记录、它已经被删了：第一张
  @Test func pickerDefaultSelection() {
    let presets = StatusPreset.builtIn
    #expect(StatusPicker.selection(last: "back", in: presets) == 2)
    #expect(StatusPicker.selection(last: "busy", in: presets) == 1)
    #expect(StatusPicker.selection(last: nil, in: presets) == 0)
    #expect(StatusPicker.selection(last: "删掉了的", in: presets) == 0)
    #expect(StatusPicker.selection(last: "back", in: []) == 0)
  }

  /// 排版：一行最多 4 张、多了折行；面板宽至少两格；高超过屏幕给的上限就在面板里滚，一出来先滚到露出选中的那一行
  @Test func pickerLayout() {
    let (cell, inset, bar) = (StatusPicker.cell, StatusPicker.inset, StatusPicker.barHeight)
    #expect(StatusPicker.card == CGSize(width: 200, height: 125))
    #expect(cell == CGSize(width: 208, height: 157))
    func layout(_ count: Int, _ maxHeight: CGFloat = 2000) -> StatusPicker.Layout {
      StatusPicker.layout(count: count, maxHeight: maxHeight)
    }
    let oneRow = inset * 2 + cell.height + bar
    // 1、2 张都是两格宽（底下那行按键提示放得下），3、4 张跟着变宽
    #expect(
      layout(1) == .init(columns: 1, rows: 1, size: CGSize(width: 456, height: 225), scrolls: false)
    )
    #expect(layout(2).size == CGSize(width: 456, height: oneRow) && layout(2).columns == 2)
    #expect(layout(3).size == CGSize(width: 672, height: oneRow) && layout(3).rows == 1)
    #expect(layout(4).size == CGSize(width: 888, height: oneRow) && layout(4).columns == 4)
    // 5–8 张两行，再多也不超过 4 列；20 张 5 行
    #expect(layout(5).rows == 2 && layout(5).columns == 4 && layout(5).size.width == 888)
    let twoRows = inset * 2 + cell.height * 2 + StatusPicker.rowGap + bar
    #expect(layout(7).size.height == twoRows)
    #expect(layout(8).rows == 2 && layout(9).rows == 3)
    let all = layout(StatusPreset.maxCount)
    let fiveRows: CGFloat = 901  // 上下内缩 32 + 5 行各 157 + 4 道行间 12 + 底栏 36
    #expect(all.rows == 5 && !all.scrolls)
    #expect(all.size.height == fiveRows)
    // 矮屏：高度夹到上限，卡片那一块滚；上限再小也露出一整行
    let short = layout(20, 700)
    #expect(short.scrolls && short.size == CGSize(width: 888, height: 700) && short.rows == 5)
    #expect(layout(20, 100).size.height == oneRow && layout(20, 100).scrolls)
    #expect(!layout(4, oneRow).scrolls && layout(5, oneRow).scrolls)
    #expect(layout(0) == layout(1))
    // 各行在滚动内容里的位置
    #expect(StatusPicker.span(of: 0) == inset...inset + cell.height)
    #expect(StatusPicker.span(of: 3) == StatusPicker.span(of: 0))
    #expect(StatusPicker.span(of: 4).lowerBound == inset + cell.height + StatusPicker.rowGap)
    // 刚呼出时：选中的在看得见的行里就不滚；在下面就滚到它底下留一格内缩；不滚的面板永远是 0
    #expect(StatusPicker.initialScroll(selection: 0, layout: short) == 0)
    #expect(StatusPicker.initialScroll(selection: 7, layout: short) == 0)
    let viewport = short.size.height - bar
    let last = StatusPicker.span(of: 19)
    let scrolled = last.upperBound + inset - viewport
    #expect(StatusPicker.initialScroll(selection: 19, layout: short) == scrolled)
    #expect(StatusPicker.initialScroll(selection: 19, layout: all) == 0)
  }

  /// 面板的状态：呼出前换成现在的列表、选中上次进入的；数字键、↩、单击进入时把状态和那张卡片的位置交出去；
  /// 没有这一张的数字键不做事
  @Test func pickerModel() {
    let model = StatusPickerModel()
    var entered: [(id: String, card: CGRect?)] = []
    model.onEnter = { entered.append(($0.id, $1)) }
    let presets = StatusPreset.builtIn
    model.prepare(presets, last: "busy", maxHeight: 800)
    #expect(model.selection == 1 && model.shows == 1 && model.presets == presets)
    #expect(model.layout == StatusPicker.layout(count: 3, maxHeight: 800))
    // 画面报上来的卡片位置：进入时原样给出去；没报的（滚出可见区）是 nil
    let card = CGRect(x: 240, y: 20, width: 208, height: 130)
    model.cardFrames[1] = card
    model.handle(.enter)
    model.handle(.pick(0))
    model.handle(.pick(5))  // 没有第 6 张
    model.enter(2)  // 单击
    #expect(entered.map(\.id) == ["busy", "clean", "back"])
    #expect(entered.map(\.card) == [card, nil, nil])
    // 移动（再按一次全局快捷键 = 下一张，回绕）
    model.move(.right)
    model.handle(.move(.right))
    #expect(model.selection == 0)
    model.handle(.move(.left))
    #expect(model.selection == 2)
    model.handle(.cancel)  // Esc 归面板管，这里不动
    #expect(model.selection == 2 && entered.count == 3)
    // 再呼出：列表变了（上次的被删了）回到第一张，旧的卡片位置和悬停不留
    model.hovered = 2
    model.prepare([presets[0]], last: "back", maxHeight: 800)
    #expect(model.selection == 0 && model.shows == 2 && model.hovered == nil)
    #expect(model.cardFrames.isEmpty && model.layout.columns == 1)
  }

  /// Esc 交给面板的 cancelOperation（真面板是 OverlayPanel.dismiss）：数一数来了几次
  private final class CancelCountingWindow: NSWindow {
    var cancels = 0
    override func cancelOperation(_ sender: Any?) { cancels += 1 }
  }

  /// 面板的画面在屏外的普通窗口里走一遍（不建真面板、不上屏、不进入）：收按键的视图把自己设成窗口的 initialFirstResponder；
  /// 按键经它到模型（方向键、Tab、数字、↩），Esc 交给窗口的 cancelOperation；20 个状态在矮屏上
  /// 一出来就滚到选中的最后一张，↑ 回第一行时跟着滚回去，滚出可见区的卡片不报位置
  @Test func pickerKeysAndScrolling() throws {
    let presets = (1...StatusPreset.maxCount).map { index in
      var preset = StatusPreset.new(id: "p\(index)")
      preset.title = "状态 \(index)"
      return preset
    }
    let model = StatusPickerModel(presets: presets, selection: 19, maxHeight: 700)
    var entered: [String] = []
    model.onEnter = { preset, _ in entered.append(preset.id) }
    let window = CancelCountingWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: model.layout.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: StatusPickerView(model: model))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    // 同 OverlayPanel.present：露出来、把布局跑完，收按键的视图这时已经建出来、拿着焦点
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(window.initialFirstResponder != nil)
    #expect(window.firstResponder === window.initialFirstResponder)
    /// 等界面跟上：按轮数等，条件满足就不再等
    func settle(until done: () -> Bool = { false }) {
      for turn in 1...10 where !(done() && turn > 2) {
        RunLoop.main.run(until: .now.addingTimeInterval(0.05))
      }
    }
    settle { model.cardFrames[19] != nil }
    let keys = try #require(window.initialFirstResponder)
    #expect(window.makeFirstResponder(keys) && window.firstResponder === keys)
    // 点面板别处不会把焦点换走：鼠标点到的都是 SwiftUI 的宿主视图，它不接第一响应者
    #expect(window.contentView?.acceptsFirstResponder == false)
    func press(_ code: Int, _ flags: NSEvent.ModifierFlags = []) throws {
      keys.keyDown(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))))
    }
    // 一出来：最后一行看得全（卡片整张在滚动区里），第一行滚出去了
    let viewport = model.layout.size.height - StatusPicker.barHeight
    let last = try #require(model.cardFrames[19])
    #expect(last.minY >= 0 && last.maxY <= viewport, "\(last)")
    #expect(model.cardFrames[0] == nil)
    // ↑ 四次回到第一行同一列：跟着滚回顶上
    for _ in 0..<4 { try press(kVK_UpArrow, [.numericPad, .function]) }
    #expect(model.selection == 3)
    settle { (model.cardFrames[3]?.minY ?? -1) >= 0 && model.cardFrames[19] == nil }
    let first = try #require(model.cardFrames[3])
    #expect(first.minY >= 0 && first.maxY <= viewport, "\(first)")
    #expect(model.cardFrames[19] == nil)
    try press(kVK_Tab)
    #expect(model.selection == 4)
    try press(kVK_Tab, .shift)
    try press(kVK_LeftArrow, [.numericPad, .function])
    #expect(model.selection == 2)
    // 数字键直接进入对应的那张，↩ 进入选中的；Esc 归窗口
    try press(kVK_ANSI_2)
    try press(kVK_Return)
    #expect(entered == ["p2", "p3"])
    #expect(window.cancels == 0)
    try press(kVK_Escape)
    #expect(window.cancels == 1 && entered.count == 2)
  }

  // MARK: 从卡片长到整屏

  /// 上一级坐标里的矩形经过图层变换（绕 anchor 做）之后在哪
  private func applied(_ transform: CGAffineTransform, to rect: CGRect, about anchor: CGPoint)
    -> CGRect
  {
    rect.offsetBy(dx: -anchor.x, dy: -anchor.y).applying(transform)
      .offsetBy(dx: anchor.x, dy: anchor.y)
  }

  private func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01
      && abs(a.height - b.height) < 0.01
  }

  /// 起始变换把整屏的图层正好摆到卡片上（横竖各缩各的），不管图层的 anchor 在角上还是正中；卡片就是整屏时是原位。
  /// 长的是卡片所在的那块屏的面板
  @Test func zoomStartMapsScreenOntoCard() {
    let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let card = CGRect(x: 420, y: 500, width: 208, height: 130)
    for anchor in [CGPoint.zero, CGPoint(x: full.midX, y: full.midY), CGPoint(x: 30, y: -40)] {
      let start = StatusScreenPanel.zoomStart(from: card, to: full, about: anchor)
      #expect(close(applied(start, to: full, about: anchor), card), "\(anchor)")
      #expect(start.b == 0 && start.c == 0)
      #expect(abs(start.a - 208.0 / 1512) < 1e-9 && abs(start.d - 130.0 / 982) < 1e-9)
      // 屏里的点按比例落在卡片里：屏的正中 → 卡片的正中
      let middle = applied(
        start, to: CGRect(x: full.midX, y: full.midY, width: 0, height: 0), about: anchor)
      #expect(abs(middle.minX - card.midX) < 0.01 && abs(middle.minY - card.midY) < 0.01)
      let same = StatusScreenPanel.zoomStart(from: full, to: full, about: anchor)
      #expect(close(applied(same, to: full, about: anchor), full) && same.a == 1 && same.d == 1)
    }
    // 上一级里不在原点的图层（frame 的原点不是 0）
    let inset = CGRect(x: 100, y: 50, width: 800, height: 500)
    let anchor = CGPoint(x: 100, y: 50)
    let start = StatusScreenPanel.zoomStart(from: card, to: inset, about: anchor)
    #expect(close(applied(start, to: inset, about: anchor), card))
    #expect(StatusScreenPanel.zoomStart(from: card, to: .zero, about: .zero) == .identity)
    // 哪块屏的面板长：卡片的中心所在的那块，都不在就第一块
    let side = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
    #expect(StatusScreen.growingIndex(card: card, screens: [full, side]) == 0)
    #expect(
      StatusScreen.growingIndex(card: card.offsetBy(dx: 1600, dy: 0), screens: [full, side]) == 1)
    #expect(
      StatusScreen.growingIndex(card: card.offsetBy(dx: 0, dy: 9000), screens: [full, side]) == 0)
  }

  /// 同一件事在真的图层上看一遍（屏外的普通窗口，不建状态屏的面板、不上屏）：铺满窗口的 NSHostingView（翻转的视图，
  /// 状态屏面板的内容就是它）图层设上起始变换，它在上一级里的 frame 就是卡片换到窗口里的位置——和面板里 grow 的算法一样
  @Test func zoomStartLandsOnCardLayer() throws {
    let frame = NSRect(x: -20000, y: -20000, width: 1200, height: 800)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: Color.black)
    host.sizingOptions = []
    host.wantsLayer = true
    window.contentView = host
    window.setFrame(frame, display: false)
    let layer = try #require(host.layer)
    let parent = try #require(host.superview)
    // 前提：图层在上一级图层里的 frame = 视图在上一级视图里的 frame
    #expect(layer.frame == host.frame && host.frame.size == frame.size)
    let card = CGRect(x: frame.minX + 700, y: frame.minY + 520, width: 208, height: 130)
    let target = parent.convert(window.convertFromScreen(card), from: nil)
    #expect(close(target, CGRect(x: 700, y: 520, width: 208, height: 130)))
    layer.setAffineTransform(
      StatusScreenPanel.zoomStart(from: target, to: host.frame, about: layer.position))
    #expect(close(layer.frame, target), "\(layer.frame)")
  }

  /// 长到整屏的那段动画真挂上了（屏外的普通窗口，同上；不建状态屏的面板）：内容图层上有变换和圆角两段动画，变换的起点
  /// 就是 zoomStart、终点是原位，模型值没动（动画一没画面就在整屏）；期间内容视图裁切（圆角才看得见），
  /// 动画放完（约 0.7 秒）恢复、done 调一次。没法放（视图不在窗口里）时 done 当场调。
  /// 动画的完成回调走主队列：测试自己占着主队列时它永远不来（同 MemoryProbeTests 文件头第 2 个坑），所以等它放完时
  /// 把主线程让出来（按轮数睡，不自己转跑环）。原来是整段投到主跑环的一个块里、在块里转跑环等——别的测试正好也在转
  /// 跑环时，这个块会落在它那一层里跑，主队列排不到、完成回调等不来（第 5 批的全量单测里偶发失败；只拿这一条和两个
  /// 截图自检函数一起跑，两遍里失败一遍）
  @Test func growAnimatesContentLayer() async {
    let failures = await Self.growFailures()
    #expect(failures.isEmpty, "\(failures)")
  }

  private static func growFailures() async -> [String] {
    var failures: [String] = []
    func check(_ passed: Bool, _ name: String) {
      if !passed { failures.append(name) }
    }
    var done = 0
    StatusScreenPanel.grow(NSView(), from: .zero) { done += 1 }
    StatusScreenPanel.grow(nil, from: .zero) { done += 1 }
    check(done == 2, "放不了时 done 当场调")
    let frame = NSRect(x: -20000, y: -20000, width: 1200, height: 800)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    // 和状态屏面板里一样：内容视图没有另外要图层，grow 自己要
    let host = NSHostingView(rootView: Color.black)
    host.sizingOptions = []
    window.contentView = host
    window.setFrame(frame, display: false)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let card = CGRect(x: frame.minX + 496, y: frame.minY + 366, width: 208, height: 130)
    StatusScreenPanel.grow(host, from: card) { done += 1 }
    guard let layer = host.layer else { return ["内容视图没有图层"] }
    guard let zoom = layer.animation(forKey: "grow") as? CASpringAnimation,
      let round = layer.animation(forKey: "round") as? CASpringAnimation,
      let from = (zoom.fromValue as? NSValue)?.caTransform3DValue,
      let to = (zoom.toValue as? NSValue)?.caTransform3DValue
    else { return ["两段动画没挂上"] }
    let expected = StatusScreenPanel.zoomStart(
      from: CGRect(x: 496, y: 366, width: 208, height: 130), to: host.frame, about: layer.position)
    check(
      CATransform3DEqualToTransform(from, CATransform3DMakeAffineTransform(expected)), "变换的起点")
    check(CATransform3DIsIdentity(to) && CATransform3DIsIdentity(layer.transform), "终点和模型值是原位")
    // 卡片上 10 pt 的圆角按缩放倒回去；圆角那段不回弹（不会弹成负的），两段都是 island 的时长
    let radius = round.fromValue as? CGFloat ?? 0
    check(abs(radius - Style.Radius.card / expected.a) < 0.001, "圆角的起点 \(radius)")
    check(round.toValue as? CGFloat == 0 && layer.cornerRadius == 0, "圆角的终点和模型值")
    let near = { (value: Double, target: Double) in abs(value - target) < 0.001 }
    check(
      near(zoom.perceptualDuration, 0.42) && near(zoom.bounce, 0.22),
      "变换走 island 曲线：\(zoom.perceptualDuration) / \(zoom.bounce)")
    check(
      near(round.perceptualDuration, 0.42) && near(round.bounce, 0),
      "圆角不回弹：\(round.perceptualDuration) / \(round.bounce)")
    check(host.clipsToBounds && done == 2, "放的时候裁切、done 还没调")
    // 放完：恢复裁切、done 调一次（弹簧收敛约 0.7 秒；最多等 40 轮）
    for _ in 0..<40 where done < 3 { try? await Task.sleep(for: .milliseconds(50)) }
    check(done == 3 && !host.clipsToBounds, "放完恢复：done \(done)，裁切 \(host.clipsToBounds)")
    check(layer.animation(forKey: "grow") == nil, "动画放完就不在了")
    // 图层是 grow 当场要来的：它的位置（变换绕着它做）之后没有再变，起点没有算在一个还没摆好的图层上
    let settled = StatusScreenPanel.zoomStart(
      from: CGRect(x: 496, y: 366, width: 208, height: 130), to: host.frame, about: layer.position)
    check(
      CATransform3DEqualToTransform(from, CATransform3DMakeAffineTransform(settled))
        && layer.frame == host.frame, "图层摆好之后起点还对：\(layer.position) \(layer.frame)")
    return failures
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
