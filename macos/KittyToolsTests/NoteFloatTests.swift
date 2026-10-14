// 便签第 4 批「浮动便签」的单测（PLAN §10「便签」，规矩在 mac-overlay-panel §12「浮动便签」）：
// - 几何和记下的东西（NoteFloatLayout：脱出的阈值、脱出那一刻摆在哪、跟着鼠标走、算在哪块屏、夹进可见区、不靠拖时
//   摆在哪、收回往哪边滑、层级跟着固定走、记下的大小、固定着的那一张记不记 / 重启后回不回来）；
// - 状态机（NoteFloatState：一次一张、拖着的时候不接别的）和状态变化该做的事（NoteFloat.effects）；
// - 界面读的状态（NoteFloatModel：关法、把手、菜单里那一项叫什么；NoteDeckModel：阈值、它在那叠里的那一份留到松手、
//   点浮着那条的标签走哪条路、浮出去就从那叠里收掉）；
// - 面板和接线（NoteFloat：浮出 / 收回 / 换一张 / 便签没了时面板的有无，层级、记位置、恢复、记大小、屏幕变了、
//   长截图让开、焦点和光标、撤销栈、从那叠里拖出来的整条路、截图和录屏里算什么、退场的替身）。
// 全用内存库和临时偏好域。面板都建在离所有屏幕很远的地方（先确认），**永远不当 key**（takesKeyboard: false——屏外的
// 面板一当 key，用户正在用的那个 App 就丢了键盘），不做动画（animates: false；只有验替身的那一条开着）。
// 不发合成的鼠标键盘事件：把手的那几步直接调模型的入口（界面上的手势只是把鼠标的位置转给它们），按键是构造出事件
// 交给面板的 performKeyEquivalent。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

struct NoteFloatTests {
  private typealias Layout = NoteFloatLayout
  private typealias Place = NoteFloatLayout.Place

  /// 一块 1440 × 900 的屏（菜单栏 25），左下角在 (x, y)
  private static func screen(
    _ name: String = "主屏", x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1440,
    height: CGFloat = 900
  ) -> NoteDeckScreen {
    NoteDeckScreen(
      name: name, frame: CGRect(x: x, y: y, width: width, height: height),
      visibleFrame: CGRect(x: x, y: y, width: width, height: height - 25))
  }

  /// 离所有真屏幕很远的一块：面板都建在它上面
  private static let far = screen("测试", x: -40000, y: -40000)
  /// 那块屏正中的一个点（「鼠标在这块屏上」）
  private static let farPoint = CGPoint(x: far.frame.midX, y: far.frame.midY)
  /// 一条便签在那叠里的位置：贴着那块屏的右边缘（面板给阴影留的 40、标签列 30、间隔 8 以内），中等大小
  private static let farSheet = CGRect(x: -39098, y: -39700, width: 460, height: 380)

  private func prefs() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "NoteFloatTests-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  /// 内存库上的仓库；bodies 就是从前到后的顺序
  private func library(_ bodies: [String]) throws -> (store: NoteStore, ids: [String]) {
    let store = try NoteStore(db: Database(path: ":memory:"))
    for (offset, body) in bodies.reversed().enumerated() {
      store.create(body: body, now: Date(timeIntervalSince1970: 1_760_000_000 + Double(offset)))
    }
    return (store, store.active.map(\.id))
  }

  /// 屏外的浮动便签：不当 key，不做动画（animates 给 true 的只有验替身的那一条），屏幕只有很远的那一块
  private func offscreenFloat(
    _ store: NoteStore, defaults: UserDefaults, animates: Bool = false
  ) throws -> NoteFloat {
    try #require(
      !NSScreen.screens.contains {
        $0.frame.insetBy(dx: -2000, dy: -2000).intersects(Self.far.frame)
      })
    let float = NoteFloat(
      store: store, defaults: defaults, island: nil, takesKeyboard: false, animates: animates)
    float.screens = { [Self.far] }
    return float
  }

  /// 面板的第一响应者是哪条便签的正文框（它的编号）；不是正文框就是 nil
  private func focusedNote(_ panel: NSPanel?) -> String? {
    (panel?.firstResponder as? NoteTextView)?.identifier?.rawValue
  }

  /// 等界面跟上：一轮一轮让出去，到条件成立为止（最多 3 秒；按轮数、不掐时间）
  private func settle(until done: () -> Bool) async throws {
    for _ in 0..<150 where !done() { try await Task.sleep(for: .milliseconds(20)) }
  }

  private func key(
    _ code: Int, _ flags: NSEvent.ModifierFlags = [], characters: String = "",
    in window: NSWindow? = nil
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
  }

  private func onScreen(_ frame: CGRect?) -> Bool {
    guard let frame else { return false }
    return NSScreen.screens.contains { $0.frame.intersects(frame) }
  }

  // MARK: 几何

  /// 按着把手挪过 40 pt（哪个方向都算）才脱出来；没挪开（5 pt 以内）算点了一下
  @Test func detachingNeedsFortyPoints() {
    let start = CGPoint(x: 100, y: 100)
    #expect(Layout.detachDistance == 40)
    #expect(!Layout.detaches(from: start, to: start))
    #expect(!Layout.detaches(from: start, to: CGPoint(x: 61, y: 100)))
    #expect(Layout.detaches(from: start, to: CGPoint(x: 60, y: 100)))
    #expect(Layout.detaches(from: start, to: CGPoint(x: 140, y: 100)))
    #expect(Layout.detaches(from: start, to: CGPoint(x: 100, y: 59)))
    // 斜着走：量的是直线距离
    #expect(!Layout.detaches(from: start, to: CGPoint(x: 128, y: 128)))
    #expect(Layout.detaches(from: start, to: CGPoint(x: 129, y: 129)))
    #expect(!Layout.moved(from: start, to: CGPoint(x: 105, y: 100)))
    #expect(Layout.moved(from: start, to: CGPoint(x: 106, y: 100)))
    #expect(Layout.moved(from: start, to: CGPoint(x: 100, y: 94)))
  }

  /// 脱出那一刻：带着标签的那一侧的上角不动；没记过大小就是原处原大小，一点都不跳
  @Test func liftingKeepsTheTabCornerInPlace() {
    let sheet = CGRect(x: 900, y: 300, width: 460, height: 380)
    #expect(Layout.lifted(sheet: sheet, size: sheet.size, tabOnLeading: true) == sheet)
    #expect(Layout.lifted(sheet: sheet, size: sheet.size, tabOnLeading: false) == sheet)
    let bigger = CGSize(width: 600, height: 500)
    let left = Layout.lifted(sheet: sheet, size: bigger, tabOnLeading: true)
    #expect(left.minX == sheet.minX && left.maxY == sheet.maxY && left.size == bigger)
    let right = Layout.lifted(sheet: sheet, size: bigger, tabOnLeading: false)
    #expect(right.maxX == sheet.maxX && right.maxY == sheet.maxY && right.size == bigger)
    // 跟着鼠标走：鼠标离左下角多远一直不变
    let grab = CGSize(width: 12, height: 200)
    #expect(Layout.origin(grab: grab, pointer: CGPoint(x: 512, y: 700)) == CGPoint(x: 500, y: 500))
  }

  /// 算在哪块屏：给了鼠标就是鼠标所在的那块；否则重叠最多的；哪块都不沾（那块屏拔了）是主显示器
  @Test func homeScreen() {
    let screens = [Self.screen(), Self.screen("副屏", x: 1440)]
    let straddling = CGRect(x: 1300, y: 200, width: 400, height: 300)
    #expect(Layout.home(of: straddling, in: screens) == 1)
    #expect(Layout.home(of: straddling.offsetBy(dx: -100, dy: 0), in: screens) == 0)
    #expect(Layout.home(of: straddling, pointer: CGPoint(x: 1400, y: 300), in: screens) == 0)
    // 鼠标不在任何一块屏上：按重叠算
    #expect(Layout.home(of: straddling, pointer: CGPoint(x: 9000, y: 0), in: screens) == 1)
    #expect(Layout.home(of: CGRect(x: 9000, y: 9000, width: 400, height: 300), in: screens) == 0)
    #expect(Layout.home(of: straddling, in: []) == nil)
  }

  /// 夹进可见区：整块都在里面；出了哪边就贴哪边；比可见区大的缩进来（顶边不动）；不小于最小尺寸
  @Test func clampingKeepsTheWholeNoteVisible() {
    let visible = Self.screen().visibleFrame  // 0, 0, 1440, 875
    let inside = CGRect(x: 200, y: 300, width: 460, height: 380)
    #expect(Layout.clamped(inside, in: visible) == inside)
    #expect(Layout.clamped(inside.offsetBy(dx: 1200, dy: 0), in: visible).maxX == 1440)
    #expect(Layout.clamped(inside.offsetBy(dx: -900, dy: 0), in: visible).minX == 0)
    // 顶上不压进菜单栏，底下不出可见区
    #expect(Layout.clamped(inside.offsetBy(dx: 0, dy: 400), in: visible).maxY == 875)
    #expect(Layout.clamped(inside.offsetBy(dx: 0, dy: -500), in: visible).minY == 0)
    let huge = Layout.clamped(CGRect(x: -50, y: -400, width: 3000, height: 2000), in: visible)
    #expect(huge == visible)
    // 太小的撑到最小尺寸，顶边不动
    let tiny = Layout.clamped(CGRect(x: 200, y: 600, width: 100, height: 80), in: visible)
    #expect(tiny.size == Layout.minSize && tiny.maxY == 680 && tiny.minX == 200)
    // 位置取整到整点
    let fractional = Layout.clamped(inside.offsetBy(dx: 0.4, dy: 0.6), in: visible)
    #expect(fractional.origin == CGPoint(x: 200, y: 301))
    // 落下：按松手那块屏夹；屏幕都没了原样返回
    let screens = [Self.screen(), Self.screen("副屏", x: 1440)]
    let dropped = Layout.settled(
      CGRect(x: 1300, y: 700, width: 460, height: 380), pointer: CGPoint(x: 1500, y: 800),
      in: screens)
    #expect(dropped == CGRect(x: 1440, y: 495, width: 460, height: 380))
    #expect(Layout.settled(inside, in: []) == inside)
  }

  /// 不靠拖浮出来：从那叠里出来的比原处往屏幕里面挪 48；没有原处的在鼠标所在屏的正中。收回时朝那叠所在的边滑
  @Test func placingWithoutADrag() {
    let screens = [Self.screen(), Self.screen("副屏", x: 1440)]
    let sheet = CGRect(x: 902, y: 300, width: 460, height: 380)
    let size = CGSize(width: 500, height: 420)
    let fromRight = Layout.placed(
      size: size, sheet: sheet, edge: .right, mouse: .zero, in: [Self.screen()])
    #expect(fromRight == CGRect(x: 902 - 48, y: 300 - 40, width: 500, height: 420))
    let leftSheet = CGRect(x: 78, y: 300, width: 460, height: 380)
    let fromLeft = Layout.placed(
      size: size, sheet: leftSheet, edge: .left, mouse: .zero, in: [Self.screen()])
    // 左边缘：标签在右边，右上角不动，再往里（右）挪 48
    #expect(fromLeft == CGRect(x: 538 - 500 + 48, y: 260, width: 500, height: 420))
    let centered = Layout.placed(
      size: size, sheet: nil, edge: .right, mouse: CGPoint(x: 2000, y: 400), in: screens)
    #expect(centered == CGRect(x: 1440 + 470, y: 228, width: 500, height: 420))
    #expect(Layout.tuckOffset(toward: .right) == 48 && Layout.tuckOffset(toward: .left) == -48)
    #expect(Layout.tuckOffset(toward: nil) == 0)
  }

  /// 层级跟着固定走；拖着的那一阵一律在上面。只有没归档、没删的便签能浮着
  @Test func levelFollowsThePin() {
    #expect(Layout.level(pinned: true, isDragging: false) == .floating)
    #expect(Layout.level(pinned: false, isDragging: false) == .normal)
    #expect(Layout.level(pinned: false, isDragging: true) == .floating)
    var note = Note(id: "甲", createdAt: .now, modifiedAt: .now)
    #expect(Layout.floats(note) && !Layout.floats(nil))
    note.isArchived = true
    #expect(!Layout.floats(note))
    note.isArchived = false
    note.deletedAt = .now
    #expect(!Layout.floats(note))
  }

  /// 记下的大小：没记过、读不出来用给的那个；不小于最小尺寸
  @Test func rememberedSize() {
    let fallback = CGSize(width: 460, height: 380)
    #expect(Layout.size(stored: nil, fallback: fallback) == fallback)
    #expect(Layout.size(stored: "不是大小", fallback: fallback) == fallback)
    #expect(Layout.size(stored: "{0, 300}", fallback: fallback) == fallback)
    #expect(Layout.size(stored: "{inf, 300}", fallback: fallback) == fallback)
    #expect(
      Layout.size(stored: NSStringFromSize(NSSize(width: 520.4, height: 610.6)), fallback: fallback)
        == CGSize(width: 520, height: 611))
    #expect(Layout.size(stored: "{100, 90}", fallback: fallback) == Layout.minSize)
    #expect(Layout.size(stored: nil, fallback: CGSize(width: 10, height: 10)) == Layout.minSize)
    // 夹进它要出现的那块屏：大外接屏上拉大的回到笔记本上、偏好被写坏成天文数字，都不大过那块屏的可见区
    let laptop = CGSize(width: 1440, height: 875)
    #expect(Layout.size(stored: "{2560, 1440}", fallback: fallback, limit: laptop) == laptop)
    let absurd = NSStringFromSize(NSSize(width: 1e9, height: 1e9))
    #expect(Layout.size(stored: absurd, fallback: fallback, limit: laptop) == laptop)
    #expect(
      Layout.size(stored: "{600, 500}", fallback: fallback, limit: laptop)
        == CGSize(width: 600, height: 500))
    #expect(
      Layout.size(stored: nil, fallback: CGSize(width: 9000, height: 100), limit: laptop)
        == CGSize(width: 1440, height: 220))
  }

  /// 固定着的那一张的位置：存取对得上；不是那个样子的读成 nil
  @Test func placeRoundTrips() {
    let place = Place(id: "甲", frame: CGRect(x: -120.5, y: 300, width: 460, height: 380))
    #expect(Place(stored: place.stored) == place)
    #expect(Place(stored: nil) == nil && Place(stored: "字符串") == nil)
    #expect(Place(stored: ["id": "甲"]) == nil)
    #expect(Place(stored: ["id": "", "frame": "{{0, 0}, {460, 380}}"]) == nil)
    #expect(Place(stored: ["id": "甲", "frame": "乱写的"]) == nil)
    #expect(Place(stored: ["id": "甲", "frame": "{{0, 0}, {0, 380}}"]) == nil)
    #expect(Place(stored: ["id": 3, "frame": 4]) == nil)
  }

  /// 该不该记：浮着、已经落下、固定着才记；没固定的不跨重启
  @Test func onlyAPinnedFloatIsRemembered() {
    let frame = CGRect(x: 100, y: 100, width: 460, height: 380)
    var note = Note(id: "甲", createdAt: .now, modifiedAt: .now)
    #expect(Layout.place(id: "甲", isDragging: false, note: note, frame: frame) == nil)
    note.isPinned = true
    #expect(
      Layout.place(id: "甲", isDragging: false, note: note, frame: frame)
        == Place(id: "甲", frame: frame))
    #expect(Layout.place(id: "甲", isDragging: true, note: note, frame: frame) == nil)
    #expect(Layout.place(id: nil, isDragging: false, note: note, frame: frame) == nil)
    #expect(Layout.place(id: "乙", isDragging: false, note: note, frame: frame) == nil)
    #expect(Layout.place(id: "甲", isDragging: false, note: nil, frame: frame) == nil)
    note.isArchived = true
    #expect(Layout.place(id: "甲", isDragging: false, note: note, frame: frame) == nil)
  }

  /// 重启后回不回来：便签还在、没归档没删、还固定着才回来；位置夹进现在看得见的屏幕，那块屏不在了就到主显示器
  @Test func restoringNeedsALivePinnedNote() {
    let screens = [Self.screen()]
    let frame = CGRect(x: 300, y: 200, width: 460, height: 380)
    var note = Note(id: "甲", createdAt: .now, modifiedAt: .now)
    note.isPinned = true
    let place = Place(id: "甲", frame: frame)
    #expect(Layout.restored(place, note: note, in: screens) == frame)
    #expect(Layout.restored(nil, note: note, in: screens) == nil)
    #expect(Layout.restored(place, note: nil, in: screens) == nil)
    #expect(Layout.restored(Place(id: "乙", frame: frame), note: note, in: screens) == nil)
    #expect(Layout.restored(place, note: note, in: []) == nil)
    // 原来在外接屏上、外接屏拔了：回到主显示器的可见区里
    let away = Place(id: "甲", frame: frame.offsetBy(dx: 3000, dy: 500))
    #expect(
      Layout.restored(away, note: note, in: screens)
        == CGRect(x: 1440 - 460, y: 875 - 380, width: 460, height: 380))
    // 分辨率变小了、记着的比屏幕还大
    let small = [Self.screen(width: 400, height: 325)]
    #expect(Layout.restored(place, note: note, in: small) == small[0].visibleFrame)
    var gone = note
    gone.isPinned = false
    #expect(Layout.restored(place, note: gone, in: screens) == nil)
    gone = note
    gone.isArchived = true
    #expect(Layout.restored(place, note: gone, in: screens) == nil)
    gone = note
    gone.deletedAt = .now
    #expect(Layout.restored(place, note: gone, in: screens) == nil)
  }

  /// 记着的大小、固定着的那一张在哪是这台电脑自己的状态：不注册默认值、不跟着导出走
  @Test func floatStateIsMachineState() {
    for key in [Prefs.notesFloatSize, Prefs.notesFloatPlace] {
      #expect(Prefs.defaults[key] == nil && SettingsArchive.kinds[key] == nil, "\(key)")
    }
  }

  /// 操作菜单最多露几行：平时 8.5 行；便签拉矮了按它的高度收，不出便签
  @Test func menuFitsAShortNote() {
    #expect(NoteSheet.menuRows(height: 380) == 8.5 && NoteSheet.menuRows(height: 320) == 8.5)
    let short = NoteSheet.menuRows(height: Layout.minSize.height)
    #expect(short < 7 && short >= 2.5)
    #expect(36 + short * ActionMenu.rowHeight <= Layout.minSize.height)
    #expect(NoteSheet.menuRows(height: 10) == 2.5)
  }

  // MARK: 状态机

  private func state(_ events: NoteFloatState.Event...) -> NoteFloatState {
    var state = NoteFloatState()
    for event in events { state.handle(event) }
    return state
  }

  /// 一次一张：再浮一张就换成新的；拖着的时候不接「浮出来」「收回」
  @Test func oneNoteAtATime() {
    var state = NoteFloatState()
    /// 来一件事，返回状态变没变
    func changes(_ event: NoteFloatState.Event) -> Bool { state.handle(event) }
    #expect(state.noteID == nil && !state.isDragging)
    // 没有浮着的：松手、收回、便签没了都不变
    #expect(!changes(.drop))
    #expect(!changes(.tuck))
    #expect(!changes(.remove))
    #expect(changes(.detach("甲")))
    #expect(state.noteID == "甲" && state.isDragging)
    // 拖着的时候不接「浮出来」「收回」
    #expect(!changes(.float("乙")))
    #expect(!changes(.tuck))
    #expect(changes(.drop))
    #expect(state.noteID == "甲" && !state.isDragging)
    #expect(!changes(.float("甲")))
    #expect(changes(.float("乙")))
    #expect(state.noteID == "乙")
    #expect(changes(.detach("甲")))
    #expect(state.noteID == "甲" && state.isDragging)
    // 拖着的时候便签没了：直接关
    #expect(changes(.remove))
    #expect(state == NoteFloatState())
    #expect(self.state(.float("甲"), .tuck) == NoteFloatState())
    #expect(self.state(.float("甲"), .remove) == NoteFloatState())
  }

  /// 状态变化该做的事
  @Test func effectsOfEachTransition() {
    typealias Effects = NoteFloat.Effects
    let none = NoteFloatState()
    func effects(_ event: NoteFloatState.Event, from old: NoteFloatState) -> Effects {
      var new = old
      new.handle(event)
      return NoteFloat.effects(event, from: old, to: new)
    }
    // 拖出来：只露出来，还没落下
    #expect(effects(.detach("甲"), from: none) == [.show])
    #expect(effects(.drop, from: state(.detach("甲"))) == [.land])
    // 不靠拖：露出来就落下
    #expect(effects(.float("甲"), from: none) == [.show, .land])
    // 换一张：前一张落盘、收回去
    let floating = state(.float("甲"))
    #expect(effects(.float("乙"), from: floating) == [.flush, .tuckOld, .show, .land])
    #expect(effects(.detach("乙"), from: floating) == [.flush, .tuckOld, .show])
    // 收回是朝边缘滑着淡掉，便签没了是直接淡掉
    #expect(effects(.tuck, from: floating) == [.flush, .tuckOld])
    #expect(effects(.remove, from: floating) == [.flush, .dropOld])
    #expect(effects(.remove, from: state(.detach("甲"))) == [.flush, .dropOld])
    // 没变的不做事
    #expect(effects(.float("甲"), from: floating).isEmpty)
    #expect(effects(.tuck, from: state(.detach("甲"))).isEmpty)
    #expect(effects(.drop, from: floating).isEmpty)
  }

  // MARK: 界面读的状态

  /// 浮着时的关法：关闭钮、Esc、⌘W、菜单里的那一项都是收回（固定着的也收）；归档、删除是直接关。
  /// 菜单里那一项的名字跟着屏幕边缘有没有那叠走
  @Test func floatingNoteClosesByTucking() throws {
    let (store, ids) = try library(["甲", "乙", "丙", "丁"])
    let model = NoteFloatModel(store: store)
    var events: [NoteFloatState.Event] = []
    model.onChange = { event, _, _ in events.append(event) }
    #expect(model.current == nil && !model.isShown && model.isFloating)
    model.send(.float(ids[0]))
    #expect(model.current?.id == ids[0] && model.isShown)
    // 关闭钮、它带着的标签的名字同菜单里那一项（那叠里打开的便签不是这个名字）
    #expect(model.tuckTitle == "收回边缘" && NoteDeckModel(store: store).tuckTitle == nil)
    #expect(model.focusRequest(for: ids[0]) != nil && model.focusRequest(for: ids[1]) == nil)
    model.close()
    #expect(model.current == nil && events == [.float(ids[0]), .tuck])
    // Esc：菜单开着先退菜单，再按才收回
    model.send(.float(ids[0]))
    model.toggleMenu()
    #expect(
      model.menuItems.map(\.title) == [
        "固定", "颜色", "任务", "归档", "删除", "收回边缘", "在「全部便签」里打开",
      ])
    model.edgeShown = false
    #expect(model.menuItems[5].title == "取消浮动" && model.tuckTitle == "取消浮动")
    #expect(model.menuItems[5].symbol == "xmark.rectangle")
    model.edgeShown = true
    // 「收回边缘」的符号朝那叠实际在的那条边
    #expect(model.menuItems[5].symbol == "sidebar.right")
    model.tabOnLeading = false
    #expect(model.menuItems[5].symbol == "sidebar.left" && model.tuckEdge == .left)
    model.tabOnLeading = true
    model.cancel()
    #expect(model.menu == nil && model.current != nil)
    model.cancel()
    #expect(model.current == nil)
    // 固定着的也收（固定管的是层级和重启后回不回来）
    store.setPinned(true, of: ids[0])
    model.send(.float(ids[0]))
    #expect(try model.handleKeyEquivalent(key(kVK_ANSI_W, .command)))
    #expect(model.current == nil && events.last == .tuck)
    #expect(try !model.handleKeyEquivalent(key(kVK_ANSI_W, .command)))
    // 菜单里的「收回边缘」
    model.send(.float(ids[1]))
    model.toggleMenu()
    model.run(model.menuItems[5])
    #expect(model.current == nil && model.menu == nil && events.last == .tuck)
    // 归档、删除：直接关（不是回到边缘）
    model.send(.float(ids[1]))
    model.archive()
    #expect(
      model.current == nil && events.last == .remove && store.note(ids[1])?.isArchived == true)
    model.send(.float(ids[2]))
    model.delete()
    #expect(model.current == nil && events.last == .remove && store.note(ids[2])?.deletedAt != nil)
    // 「在全部便签里打开」：浮着的留着（那叠里的那条会收）
    var shown: [String] = []
    model.showInWindow = { shown.append($0) }
    model.send(.float(ids[3]))
    model.toggleMenu()
    model.run(model.menuItems[6])
    #expect(shown == [ids[3]] && model.state.noteID == ids[3] && model.menu == nil)
    // 别处把它删了
    store.delete(ids[3])
    model.reconcile()
    #expect(model.state.noteID == nil && events.last == .remove)
    // 名字：三处同一份
    #expect(NotesWindowModel.floatTitle(isFloating: false) == "浮在屏幕上")
    #expect(NotesWindowModel.floatTitle(isFloating: false, hasEdge: false) == "浮在屏幕上")
    #expect(NotesWindowModel.floatTitle(isFloating: true) == "收回边缘")
    #expect(NotesWindowModel.floatTitle(isFloating: true, hasEdge: false) == "取消浮动")
    let symbols = [
      NotesWindowModel.floatSymbol(isFloating: false),
      NotesWindowModel.floatSymbol(isFloating: true),
      NotesWindowModel.floatSymbol(isFloating: true, edge: .left),
      NotesWindowModel.floatSymbol(isFloating: true, hasEdge: false),
    ]
    #expect(Set(symbols).count == 4)
    for symbol in symbols {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  /// 浮着时按着把手：挪开了才开始挪窗口；按在它带着的标签上没挪开就松手 = 收回；头部的空白处点一下不做事
  @Test func gripMovesTheFloatingNote() throws {
    let (store, ids) = try library(["甲"])
    let model = NoteFloatModel(store: store)
    var began: [CGPoint] = []
    var moves: [CGPoint] = []
    var ended: [CGPoint] = []
    model.onMoveBegan = { began.append($0) }
    model.onMove = { moves.append($0) }
    model.onMoveEnded = { ended.append($0) }
    let start = CGPoint(x: 500, y: 500)
    // 没有浮着的：不理
    model.gripChanged(at: start)
    model.gripEnded(.tab, at: start)
    #expect(began.isEmpty && model.state.noteID == nil)
    model.send(.float(ids[0]))
    model.gripChanged(at: start)
    model.gripChanged(at: CGPoint(x: 503, y: 500))
    #expect(began.isEmpty && moves.isEmpty)
    model.gripChanged(at: CGPoint(x: 520, y: 510))
    model.gripChanged(at: CGPoint(x: 540, y: 520))
    #expect(began == [start])
    #expect(moves == [CGPoint(x: 520, y: 510), CGPoint(x: 540, y: 520)])
    model.gripEnded(.header, at: CGPoint(x: 541, y: 520))
    #expect(ended == [CGPoint(x: 541, y: 520)] && model.state.noteID == ids[0])
    // 头部的空白处点一下：什么都不做
    model.gripChanged(at: start)
    model.gripEnded(.header, at: start)
    #expect(model.state.noteID == ids[0] && ended.count == 1)
    // 挪过再松手不算点了一下（哪怕按的是标签）
    model.gripChanged(at: start)
    model.gripChanged(at: CGPoint(x: 600, y: 500))
    model.gripEnded(.tab, at: CGPoint(x: 600, y: 500))
    #expect(model.state.noteID == ids[0] && ended.count == 2)
    // 它带着的标签点一下：收回
    model.gripChanged(at: start)
    model.gripEnded(.tab, at: CGPoint(x: 502, y: 501))
    #expect(model.state.noteID == nil)
    // 正被从那叠里拖出来的那一阵：把手不归它
    model.send(.detach(ids[0]))
    model.gripChanged(at: start)
    model.gripChanged(at: CGPoint(x: 700, y: 500))
    model.gripEnded(.tab, at: CGPoint(x: 700, y: 500))
    #expect(began.count == 2 && model.state.isDragging)
  }

  /// 每浮一张一个新的撤销栈；写入按编号落（换一张的那一下，旧的输入框晚到的字落回它自己那条）
  @Test func eachFloatedNoteHasItsOwnUndoStackAndWrites() throws {
    let (store, ids) = try library(["甲的正文", "乙的正文"])
    let model = NoteFloatModel(store: store)
    model.send(.float(ids[0]))
    let first = model.textUndo
    store.setPinned(true, of: ids[0])
    #expect(model.textUndo === first)
    model.send(.float(ids[1]))
    #expect(model.textUndo !== first)
    model.setBody("甲的正文，加上晚到的字", of: ids[0])
    model.setTitle("甲的标题", of: ids[0])
    #expect(store.note(ids[0])?.body == "甲的正文，加上晚到的字")
    #expect(store.note(ids[0])?.title == "甲的标题")
    #expect(store.note(ids[1])?.body == "乙的正文" && store.note(ids[1])?.title == "")
    model.close()
    model.setBody("收回之后才到的", of: ids[1])
    #expect(store.note(ids[1])?.body == "收回之后才到的")
  }

  // MARK: 那叠这边

  private static let enter = NoteDeckState.Event.pillEntered(optionDown: false, allowed: true)

  private func deckModel(_ bodies: [String]) throws -> (
    model: NoteDeckModel, store: NoteStore, ids: [String]
  ) {
    let (store, ids) = try library(bodies)
    let model = NoteDeckModel(store: store)
    model.panelSize = CGSize(width: 538, height: 875)
    model.pillCenter = 437
    return (model, store, ids)
  }

  /// 按着打开的便签的把手往外拖：阈值以内松手 = 没拖；过了阈值它脱出来，**它在这叠里的那一份留到松手**
  /// （状态还是打开着、只是看不见），之后每一下都让浮动面板跟着走；松手才从这叠里收掉
  @Test func draggingTheGripDetachesPastTheThreshold() throws {
    let (model, _, ids) = try deckModel(["甲", "乙"])
    var detached: [(id: String, pointer: CGPoint)] = []
    var drags: [CGPoint] = []
    var drops: [CGPoint] = []
    model.onDetach = { detached.append(($0, $1)) }
    model.onDetachDrag = { drags.append($0) }
    model.onDetachDrop = { drops.append($0) }
    let start = CGPoint(x: 900, y: 500)
    // 没开着便签：不理
    model.gripChanged(at: start)
    model.gripEnded(.tab, at: start)
    model.send(Self.enter)
    model.tapTab(ids[0])
    // 阈值以内：什么都不动；松手一切照旧（挪过了，不算点了一下）
    model.gripChanged(at: start)
    model.gripChanged(at: CGPoint(x: 870, y: 500))
    model.gripEnded(.header, at: CGPoint(x: 870, y: 500))
    #expect(detached.isEmpty && drops.isEmpty && model.state.openID == ids[0])
    #expect(model.liftedID == nil && !model.isDetaching)
    model.gripChanged(at: start)
    model.gripChanged(at: CGPoint(x: 862, y: 500))
    model.gripEnded(.tab, at: CGPoint(x: 862, y: 500))
    #expect(detached.isEmpty && model.state.openID == ids[0])
    // 过了阈值：脱出来，只报一次
    model.toggleMenu()
    model.gripChanged(at: start)
    model.gripChanged(at: CGPoint(x: 880, y: 500))
    let past = CGPoint(x: 850, y: 520)
    model.gripChanged(at: past)
    #expect(detached.count == 1 && detached[0].id == ids[0] && detached[0].pointer == past)
    #expect(model.state.openID == ids[0] && model.liftedID == ids[0] && model.isDetaching)
    #expect(model.menu == nil && drags.isEmpty)
    model.gripChanged(at: CGPoint(x: 600, y: 400))
    model.gripChanged(at: CGPoint(x: 500, y: 380))
    #expect(detached.count == 1 && drags == [CGPoint(x: 600, y: 400), CGPoint(x: 500, y: 380)])
    // 这时浮动便签那边说「它浮着了」：这叠里的那一份不收（手势还连着）
    model.floated(ids[0])
    #expect(model.state.openID == ids[0] && model.floatingID == ids[0])
    model.gripEnded(.tab, at: CGPoint(x: 498, y: 380))
    #expect(drops == [CGPoint(x: 498, y: 380)] && !model.isDetaching)
    #expect(model.state.phase == .fanned && model.liftedID == ids[0])
    // 下次在这叠里打开便签：看不见的标记清掉
    model.floated(nil)
    model.tapTab(ids[0])
    #expect(model.state.openID == ids[0] && model.liftedID == nil)
  }

  /// 按在它带着的标签上、没挪开就松手 = 点了一下 = 关便签（回到那一列）；头部的空白处点一下不关
  @Test func tappingTheOwnTabStillCloses() throws {
    let (model, _, ids) = try deckModel(["甲"])
    model.send(Self.enter)
    model.tapTab(ids[0])
    let point = CGPoint(x: 900, y: 500)
    model.gripChanged(at: point)
    model.gripEnded(.header, at: point)
    #expect(model.state.openID == ids[0])
    model.gripChanged(at: point)
    model.gripEnded(.tab, at: CGPoint(x: 902, y: 499))
    #expect(model.state.phase == .fanned)
    // 手势没报过「按下」就结束了（不该有，兜着）：标签上的照样当点了一下
    model.tapTab(ids[0])
    model.gripEnded(.tab, at: point)
    #expect(model.state.phase == .fanned)
  }

  /// 拖出去的那条在这叠里被关了（Esc、被叫停、换了一条）：它那一份要拆了，当成在鼠标最后的位置松了手
  @Test func closingTheSheetMidDragDropsTheFloat() throws {
    let (model, _, ids) = try deckModel(["甲", "乙"])
    var drops: [CGPoint] = []
    model.onDetachDrop = { drops.append($0) }
    model.send(Self.enter)
    for event in [NoteDeckState.Event.dismiss, .suspend(closesOpen: true), .created(ids[1])] {
      model.send(Self.enter)
      model.tapTab(ids[0])
      #expect(model.state.openID == ids[0])
      model.gripChanged(at: CGPoint(x: 900, y: 500))
      model.gripChanged(at: CGPoint(x: 800, y: 500))
      model.gripChanged(at: CGPoint(x: 700, y: 450))
      #expect(model.isDetaching)
      model.send(event)
      #expect(!model.isDetaching && drops.last == CGPoint(x: 700, y: 450))
      // 晚到的松手不再落一次
      let count = drops.count
      model.gripEnded(.tab, at: CGPoint(x: 600, y: 400))
      #expect(drops.count == count)
      model.send(.dismiss)
    }
    #expect(drops.count == 3)
    // 这块屏的那叠不放了（NoteDeck.close）：同样当成松了手；没在拖的时候不做事
    model.releaseGrip()
    #expect(drops.count == 3)
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.gripChanged(at: CGPoint(x: 900, y: 500))
    model.releaseGrip()
    #expect(drops.count == 3)
    model.gripChanged(at: CGPoint(x: 900, y: 600))
    model.releaseGrip()
    #expect(drops.count == 4 && drops.last == CGPoint(x: 900, y: 600) && !model.isDetaching)
    #expect(model.state.openID == ids[0])
  }

  /// 浮在屏幕上的那条：点它的标签是把浮着的叫到前面，不在这叠里再开一份；悬停不打开它；「新建便签」落在它身上也是
  /// 叫到前面。它刚浮出去时还开在这叠里就从这叠里收掉。操作菜单的「浮在屏幕上」是不靠拖的那条路
  @Test func floatingNoteIsNotOpenedTwice() throws {
    let (model, _, ids) = try deckModel(["甲", "乙"])
    var focused = 0
    var floated: [String] = []
    model.focusFloat = { focused += 1 }
    model.onFloat = { floated.append($0) }
    model.send(Self.enter)
    model.floated(ids[0])
    #expect(model.floatingID == ids[0])
    model.tapTab(ids[0])
    #expect(model.state.phase == .fanned && focused == 1)
    model.openFromHover(ids[0])
    #expect(model.state.phase == .fanned && focused == 1)
    model.open(created: ids[0])
    #expect(model.state.phase == .fanned && focused == 2)
    // 拖动排序里没挪开就松手 = 点了一下：同一条路
    model.dragEnded(ids[0], by: 2)
    #expect(model.state.phase == .fanned && focused == 3)
    // 别的便签照常打开
    model.tapTab(ids[1])
    #expect(model.state.openID == ids[1] && focused == 3)
    // 从菜单把开着的这条浮出去：交给浮动便签；它说「浮着了」，这叠里的那一份收掉
    model.toggleMenu()
    #expect(model.menuItems[5].title == "浮在屏幕上")
    model.run(model.menuItems[5])
    #expect(floated == [ids[1]] && model.menu == nil && model.state.openID == ids[1])
    model.floated(ids[1])
    #expect(model.state.phase == .fanned && model.floatingID == ids[1])
    // 收回之后又能在这叠里打开
    model.floated(nil)
    model.tapTab(ids[1])
    #expect(model.state.openID == ids[1])
    // 没开着便签时菜单那条路不做事
    model.send(.close)
    model.toggleFloating()
    #expect(floated == [ids[1]])
  }

  // MARK: 面板和接线

  /// 浮动便签的面板（第六个例外）：无边框、不激活、能拉大小、能当 key、系统阴影；截图的冻结帧里留着（可见时），
  /// 录屏的白名单里有；它收回时的替身不留
  @Test func floatPanelCountsAsContent() throws {
    let (store, ids) = try library(["一"])
    let model = NoteFloatModel(store: store)
    model.send(.float(ids[0]))
    let panel = NoteFloatPanel(
      frame: CGRect(x: -30000, y: -30000, width: 460, height: 380), model: model)
    #expect(panel.styleMask == [.borderless, .nonactivatingPanel, .resizable])
    #expect(panel.canBecomeKey && !panel.canBecomeMain && panel.becomesKeyOnlyIfNeeded)
    #expect(panel.hasShadow && !panel.isOpaque && !panel.isMovable && !panel.isVisible)
    #expect(panel.minSize == Layout.minSize && panel.level == .normal)
    #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
    #expect(!panel.ignoresMouseEvents && !panel.hidesOnDeactivate && !panel.isReleasedWhenClosed)
    // 位置自己管：系统不再挪一遍（屏外的也不被拉回屏幕里）
    let anywhere = CGRect(x: -90000, y: 70000, width: 460, height: 380)
    #expect(panel.constrainFrameRect(anywhere, to: NSScreen.main) == anywhere)
    #expect(panel.title == "浮动便签")
    let name = String(describing: type(of: panel))
    #expect(name == "NoteFloatPanel")
    func own(_ name: String, visible: Bool, level: NSWindow.Level) -> ScreenCapture.OwnWindow {
      ScreenCapture.OwnWindow(
        id: 9, className: name, level: level.rawValue, isVisible: visible, alpha: 1)
    }
    for level in [NSWindow.Level.normal, .floating] {
      #expect(ScreenCapture.keptOwnWindows([own(name, visible: true, level: level)]) == [9])
      #expect(ScreenCapture.keptOwnWindows([own(name, visible: false, level: level)]).isEmpty)
      #expect(ScreenCapture.recordedOwnWindows([own(name, visible: true, level: level)]) == [9])
      // 收回时的替身：冻结帧、录屏都不要
      let standIn = own(String(describing: PanelStandIn.self), visible: true, level: level)
      #expect(ScreenCapture.keptOwnWindows([standIn]).isEmpty)
      #expect(ScreenCapture.recordedOwnWindows([standIn]).isEmpty)
    }
    // 整扇窗口就是便签：悬停列表里按窗口的 frame 算（不像那叠的面板只算里面的一块）
    let info: [[String: Any]] = [
      [
        kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
        kCGWindowOwnerPID as String: Int32(42), kCGWindowNumber as String: 9,
        kCGWindowBounds as String: ["X": 100.0, "Y": 200.0, "Width": 460.0, "Height": 380.0],
      ]
    ]
    #expect(
      ScreenCapture.windowFrames(info, ownPID: 42, keeping: [9], primaryHeight: 900)
        == [CGRect(x: 100, y: 320, width: 460, height: 380)])
  }

  /// 不靠拖浮出来 → 层级跟着固定走、固定着才记位置 → 收回：面板的有无，都在屏外、不当 key
  @Test func presentingBuildsThePanelAndTuckingReleasesIt() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲", "乙"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    var changes = 0
    float.onChange = { changes += 1 }
    #expect(float.panel == nil)
    // 不能浮着的不浮：没有这条、归档了的
    float.present("没有这条", mouse: Self.farPoint)
    store.setArchived(true, of: ids[1])
    float.present(ids[1], mouse: Self.farPoint)
    #expect(float.panel == nil && changes == 0)
    store.setArchived(false, of: ids[1])

    float.present(ids[0], mouse: Self.farPoint)
    // 没记过大小、不是从那叠里出来的：设置里便签的大小，摆在那块屏可见区的正中
    let expected = Layout.placed(
      size: NoteDeckOptions.NoteSize.medium.size, sheet: nil, edge: .right, mouse: Self.farPoint,
      in: [Self.far])
    #expect(float.model.state.noteID == ids[0] && !float.model.state.isDragging && changes == 1)
    #expect(float.panel?.frame == expected && float.panel?.isVisible == true)
    #expect(float.panel?.isKeyWindow == false && float.panel?.level == .normal)
    #expect(!onScreen(float.panel?.frame))
    #expect(defaults.object(forKey: Prefs.notesFloatPlace) == nil)
    try await settle { focusedNote(float.panel) == ids[0] }
    #expect(focusedNote(float.panel) == ids[0])
    // 固定：到别的窗口上面，位置记下来；取消固定：回到普通层级，记着的删掉
    store.setPinned(true, of: ids[0])
    float.storeChanged()
    #expect(float.panel?.level == .floating)
    #expect(
      Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))
        == Place(id: ids[0], frame: expected))
    store.setPinned(false, of: ids[0])
    float.storeChanged()
    #expect(float.panel?.level == .normal && defaults.object(forKey: Prefs.notesFloatPlace) == nil)
    // 再让同一条浮出来：就是它，不重建
    let same = float.panel
    float.present(ids[0], mouse: Self.farPoint)
    #expect(float.panel === same && changes == 1)
    // 收回（固定着的也收），记着的位置跟着删掉
    store.setPinned(true, of: ids[0])
    float.storeChanged()
    #expect(defaults.object(forKey: Prefs.notesFloatPlace) != nil)
    float.model.close()
    #expect(float.panel == nil && float.model.state.noteID == nil && same?.isVisible == false)
    #expect(defaults.object(forKey: Prefs.notesFloatPlace) == nil)
    #expect(same?.contentView == nil)
    // 全部便签窗口的那个入口：浮出来 / 收回
    float.toggle(ids[1])
    #expect(
      float.model.state.noteID == ids[1] && float.panel != nil && !onScreen(float.panel?.frame))
    float.toggle(ids[1])
    #expect(float.model.state.noteID == nil && float.panel == nil)
  }

  /// 一次一张：再浮一张，前一张的面板收走、换一块新的；便签被删除 / 归档，面板跟着关
  @Test func oneFloatAtATimeAndGoneNotesClose() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲", "乙", "丙"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    float.present(ids[0], mouse: Self.farPoint)
    let first = try #require(float.panel)
    try await settle { focusedNote(first) == ids[0] }
    let firstUndo = float.model.textUndo
    float.present(ids[1], mouse: Self.farPoint)
    let second = try #require(float.panel)
    #expect(second !== first && !first.isVisible && first.contentView == nil)
    #expect(float.model.state.noteID == ids[1] && second.isVisible && !onScreen(second.frame))
    #expect(float.model.textUndo !== firstUndo)
    try await settle { focusedNote(second) == ids[1] }
    #expect(focusedNote(second) == ids[1])
    // 这条便签进了最近删除：面板跟着关
    store.delete(ids[1])
    float.storeChanged()
    #expect(float.panel == nil && float.model.state.noteID == nil && !second.isVisible)
    // 归档同样；从它自己的菜单归档也是
    float.present(ids[2], mouse: Self.farPoint)
    store.setArchived(true, of: ids[2])
    float.storeChanged()
    #expect(float.panel == nil)
    float.present(ids[0], mouse: Self.farPoint)
    float.model.archive()
    #expect(float.panel == nil && store.note(ids[0])?.isArchived == true)
  }

  /// 从那叠里拖出来的整条路（浮动便签这一头）：脱出来的那一刻面板就在原处（原大小、在上面），之后跟着鼠标走，
  /// 松手落下——夹进可见区、层级跟着固定走、焦点进正文、光标还在原来的地方
  @Test func detachDragDrop() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲的正文", "乙"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    let sheet = Self.farSheet
    let grabbed = CGPoint(x: sheet.minX + 12, y: sheet.midY)
    let pointer = CGPoint(x: grabbed.x - 45, y: grabbed.y)
    float.detach(
      ids[0], from: .init(sheet: sheet, selection: NSRange(location: 2, length: 1)), at: pointer)
    let panel = try #require(float.panel)
    #expect(float.model.state.noteID == ids[0] && float.model.state.isDragging)
    // 一点都不跳：原处、原大小；拖着的那一阵在上面（没固定也是）
    #expect(panel.frame == sheet && panel.isVisible && !panel.isKeyWindow)
    #expect(panel.level == .floating && !onScreen(panel.frame))
    float.drag(to: CGPoint(x: pointer.x - 300, y: pointer.y + 40))
    #expect(panel.frame == sheet.offsetBy(dx: -300, dy: 40))
    // 拖着的时候不接别的
    float.present(ids[1], mouse: Self.farPoint)
    float.model.close()
    float.detach(ids[1], from: .init(sheet: sheet), at: pointer)
    #expect(float.model.state.noteID == ids[0] && float.model.state.isDragging)
    #expect(defaults.object(forKey: Prefs.notesFloatPlace) == nil)
    // 拖到那块屏的底边外面松手：夹回可见区里
    let below = CGPoint(x: pointer.x - 300, y: Self.far.frame.minY + 60)
    float.drop(at: below)
    #expect(!float.model.state.isDragging && panel.level == .normal)
    #expect(panel.frame.minY == Self.far.visibleFrame.minY && panel.frame.size == sheet.size)
    #expect(panel.frame.minX == sheet.minX - 300 && !onScreen(panel.frame))
    #expect(float.panel === panel && !panel.isKeyWindow)
    // 焦点进正文，光标 / 选区是从那叠里带过来的
    try await settle {
      focusedNote(panel) == ids[0]
        && (panel.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 1)
    }
    #expect(focusedNote(panel) == ids[0])
    #expect(
      (panel.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 1))
    // 松手之后再来的「跟着走」「松手」不理
    float.drag(to: Self.farPoint)
    float.drop(at: Self.farPoint)
    #expect(panel.frame.minY == Self.far.visibleFrame.minY)
    // 固定着的拖出来：落下就记位置
    float.model.close()
    store.setPinned(true, of: ids[1])
    float.detach(ids[1], from: .init(sheet: sheet), at: pointer)
    #expect(defaults.object(forKey: Prefs.notesFloatPlace) == nil)
    float.drop(at: pointer)
    #expect(float.panel?.level == .floating)
    #expect(
      Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))
        == Place(id: ids[1], frame: sheet))
  }

  /// 按着把手挪：面板跟着鼠标走，松手夹进可见区、固定着的把新位置记下来
  @Test func movingByTheGrip() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲"])
    store.setPinned(true, of: ids[0])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    float.present(ids[0], mouse: Self.farPoint)
    let panel = try #require(float.panel)
    let frame = panel.frame
    let start = CGPoint(x: frame.minX + 10, y: frame.midY)
    float.model.gripChanged(at: start)
    float.model.gripChanged(at: CGPoint(x: start.x + 3, y: start.y))
    #expect(panel.frame == frame)
    float.model.gripChanged(at: CGPoint(x: start.x + 100, y: start.y - 50))
    #expect(panel.frame == frame.offsetBy(dx: 100, dy: -50))
    float.model.gripChanged(at: CGPoint(x: start.x + 120, y: start.y - 60))
    #expect(panel.frame == frame.offsetBy(dx: 120, dy: -60))
    float.model.gripEnded(.tab, at: CGPoint(x: start.x + 120, y: start.y - 60))
    #expect(float.panel === panel && panel.frame == frame.offsetBy(dx: 120, dy: -60))
    #expect(
      Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))
        == Place(id: ids[0], frame: frame.offsetBy(dx: 120, dy: -60)))
    // 挪出那块屏的右边：松手夹回来
    float.model.gripChanged(at: start)
    float.model.gripChanged(at: CGPoint(x: start.x + 5000, y: start.y))
    #expect(panel.frame.minX > Self.far.frame.maxX && !onScreen(panel.frame))
    float.model.gripEnded(.header, at: CGPoint(x: start.x + 5000, y: start.y))
    #expect(panel.frame.maxX == Self.far.visibleFrame.maxX)
    #expect(Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))?.frame == panel.frame)
  }

  /// 拉过的大小记下来，下次浮出来还是这么大；拉过了屏幕边的夹回来
  @Test func resizedSizeIsRemembered() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲", "乙"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    float.present(ids[0], mouse: Self.farPoint)
    let panel = try #require(float.panel)
    #expect(defaults.string(forKey: Prefs.notesFloatSize) == nil)
    var frame = panel.frame
    frame.size = CGSize(width: 600, height: 520)
    panel.setFrame(frame, display: false)
    float.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    #expect(defaults.string(forKey: Prefs.notesFloatSize).map(NSSizeFromString) == frame.size)
    // 系统的拉伸不会小过 minSize；记着的万一更小，读出来也撑到最小
    #expect(panel.minSize == Layout.minSize)
    float.model.close()
    float.present(ids[1], mouse: Self.farPoint)
    #expect(float.panel?.frame.size == frame.size)
    // 从那叠里拖出来的也用记着的大小：带标签那一侧的上角不动
    float.model.close()
    float.detach(ids[0], from: .init(sheet: Self.farSheet), at: Self.farPoint)
    #expect(float.panel?.frame.size == frame.size)
    #expect(float.panel?.frame.minX == Self.farSheet.minX)
    #expect(float.panel?.frame.maxY == Self.farSheet.maxY)
    float.drop(at: Self.farPoint)
    // 拉得比那块屏的可见区还大：夹回来，记下的是夹过的
    let live = try #require(float.panel)
    live.setFrame(
      CGRect(origin: live.frame.origin, size: CGSize(width: 5000, height: 4000)), display: false)
    float.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    #expect(live.frame == Self.far.visibleFrame)
    #expect(
      defaults.string(forKey: Prefs.notesFloatSize).map(NSSizeFromString)
        == Self.far.visibleFrame.size)
  }

  /// 重启后：固定着浮在屏幕上的那一张回到原处、不当 key；记着的那条不固定了 / 没了就不回来，记着的也删掉
  @Test func restoringThePinnedFloat() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲", "乙"])
    store.setPinned(true, of: ids[0])
    let frame = CGRect(x: -39700, y: -39600, width: 520, height: 440)
    // 上一次运行：浮着、固定着，位置记下来了（之后这一份控制器就不在了；偏好里留着的换成一个好认的位置）
    let before = try offscreenFloat(store, defaults: defaults)
    before.present(ids[0], mouse: Self.farPoint)
    #expect(Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))?.id == ids[0])
    before.model.send(.remove)
    #expect(defaults.object(forKey: Prefs.notesFloatPlace) == nil)
    defaults.set(Place(id: ids[0], frame: frame).stored, forKey: Prefs.notesFloatPlace)
    // 这一次运行
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    #expect(float.panel == nil)
    float.restore()
    #expect(float.model.state.noteID == ids[0] && float.panel?.frame == frame)
    #expect(float.panel?.level == .floating && float.panel?.isKeyWindow == false)
    #expect(!onScreen(float.panel?.frame))
    #expect(Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))?.frame == frame)
    try await settle { focusedNote(float.panel) == ids[0] }
    // 已经有浮着的：再恢复一次什么都不做
    let kept = float.panel
    float.restore()
    #expect(float.panel === kept)
    float.model.send(.remove)
    // 原来那块屏不在了（记着的位置哪块屏都不沾）：到现在的屏里
    defaults.set(
      Place(id: ids[0], frame: frame.offsetBy(dx: 9000, dy: 9000)).stored,
      forKey: Prefs.notesFloatPlace)
    float.restore()
    #expect(float.panel.map { Self.far.visibleFrame.contains($0.frame) } == true)
    #expect(float.panel?.frame.size == frame.size)
    float.model.send(.remove)
    // 不固定了、归档了、删了、没有这条、存的不是那个样子：不回来，记着的删掉
    for spoil in 0..<5 {
      defaults.set(Place(id: ids[0], frame: frame).stored, forKey: Prefs.notesFloatPlace)
      switch spoil {
      case 0: store.setPinned(false, of: ids[0])
      case 1: store.setArchived(true, of: ids[0])
      case 2: store.delete(ids[0])
      case 3:
        defaults.set(Place(id: "没有这条", frame: frame).stored, forKey: Prefs.notesFloatPlace)
      default: defaults.set("不是那个样子", forKey: Prefs.notesFloatPlace)
      }
      float.restore()
      #expect(float.panel == nil && float.model.state.noteID == nil, "\(spoil)")
      #expect(defaults.object(forKey: Prefs.notesFloatPlace) == nil, "\(spoil)")
      store.restore(ids[0])
      store.setArchived(false, of: ids[0])
      store.setPinned(true, of: ids[0])
    }
    // 一块屏都没有（还没接上显示器）：不恢复，但记着的留着
    defaults.set(Place(id: ids[0], frame: frame).stored, forKey: Prefs.notesFloatPlace)
    float.screens = { [] }
    float.restore()
    #expect(float.panel == nil && defaults.object(forKey: Prefs.notesFloatPlace) != nil)
  }

  /// 屏幕变了（设置、显示器的变化由 NoteEdge 转过来）：夹回现在的可见区；它带着的标签跟那叠的大小档和在哪条边走
  @Test func screenAndSettingChangesReachTheFloat() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲"])
    store.setPinned(true, of: ids[0])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    var options = NoteDeckOptions()
    float.update(options: options, edgeShown: true)
    #expect(float.model.tabOnLeading && float.model.edgeShown && float.panel == nil)
    #expect(float.model.metrics == NoteDeckMetrics(scale: 1))
    float.present(ids[0], mouse: Self.farPoint)
    let panel = try #require(float.panel)
    let frame = panel.frame
    // 没变的不动
    float.update(options: options, edgeShown: true)
    #expect(panel.frame == frame)
    // 换到左边、大一档、总开关关了：标签到右边、变宽，菜单里那一项改叫「取消浮动」
    options.edge = .left
    options.size = .large
    float.update(options: options, edgeShown: false)
    #expect(!float.model.tabOnLeading && !float.model.edgeShown)
    #expect(float.model.metrics.tabWidth == 38)
    // 那块屏变小了（分辨率、程序坞）：夹回来，记着的位置跟着改
    let smaller = Self.screen("测试", x: -40000, y: -40000, width: 800, height: 600)
    float.screens = { [smaller] }
    float.update(options: options, edgeShown: false)
    #expect(smaller.visibleFrame.contains(panel.frame) && panel.frame.size == frame.size)
    #expect(Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))?.frame == panel.frame)
  }

  /// 长截图：压在选区上的先收走，结束放回来；不相交的不动。点它在那叠里的标签时也放回来
  @Test func longScreenshotMovesTheFloatAside() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    float.suspend(covering: Self.far.frame)
    float.resume()
    float.present(ids[0], mouse: Self.farPoint)
    let panel = try #require(float.panel)
    float.suspend(covering: panel.frame.offsetBy(dx: 5000, dy: 0))
    #expect(panel.isVisible)
    float.suspend(covering: panel.frame.insetBy(dx: 100, dy: 100))
    #expect(!panel.isVisible && float.panel === panel && float.model.state.noteID == ids[0])
    float.resume()
    #expect(panel.isVisible && !panel.isKeyWindow && !onScreen(panel.frame))
    float.resume()
    #expect(panel.isVisible)
    float.suspend(covering: panel.frame)
    float.focus()
    #expect(panel.isVisible)
  }

  /// 浮动面板里的按键入口和撤销：登记撤销的栈、按键动的栈是同一个（这条便签自己的）；⌘Z / ⇧⌘Z、⌘F 和 Esc 的
  /// 层级、⌘W 收回都从面板的 performKeyEquivalent 走到底；面板放掉之后这个栈清了
  @Test func keysAndUndoGoThroughTheFloatPanel() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲的正文"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    float.present(ids[0], mouse: Self.farPoint)
    let panel = try #require(float.panel)
    try await settle { focusedNote(panel) == ids[0] }
    let editor = try #require(NoteDeck.editor(for: ids[0], in: panel.contentView))
    let stack = float.model.textUndo
    #expect(editor.undoManager === stack && panel.focusedTextUndo === stack && !panel.isKeyWindow)
    func undo(redo: Bool = false) throws -> Bool {
      panel.performKeyEquivalent(
        with: try key(
          kVK_ANSI_Z, redo ? [.command, .shift] : .command, characters: redo ? "Z" : "z",
          in: panel))
    }
    #expect(try !undo() && !undo(redo: true))
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    editor.insertText("，加一句", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(store.note(ids[0])?.body == "甲的正文，加一句")
    #expect(try undo())
    #expect(editor.string == "甲的正文" && store.note(ids[0])?.body == "甲的正文")
    #expect(try undo(redo: true))
    #expect(store.note(ids[0])?.body == "甲的正文，加一句")
    // ⌘T 任务、⌘P 固定（层级跟着变）、⌘K 菜单开着时方向键归面板
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_T, .command)))
    #expect(store.note(ids[0])?.body == "☐ 甲的正文，加一句")
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_P, .command)))
    float.storeChanged()
    #expect(store.note(ids[0])?.isPinned == true && panel.level == .floating)
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_K, .command)))
    #expect(float.model.menu != nil && panel.firstResponder === panel)
    panel.keyDown(with: try key(kVK_DownArrow))
    #expect(float.model.menu?.selection == 1)
    panel.cancelOperation(nil)
    #expect(float.model.menu == nil && focusedNote(panel) == ids[0])
    // ⌘F：这条便签自己的查找条；Esc 先关它，便签还浮着
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_F, .command)))
    #expect(editor.enclosingScrollView?.isFindBarVisible == true)
    panel.cancelOperation(nil)
    #expect(editor.enclosingScrollView?.isFindBarVisible == false && float.panel === panel)
    #expect(stack.canUndo)
    // ⌘W：收回（固定着的也收）。面板放掉、正文框离开窗口，这条便签的撤销栈清了
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_W, .command)))
    #expect(float.panel == nil && float.model.state.noteID == nil && !panel.isVisible)
    #expect(!stack.canUndo && panel.contentView == nil)
  }

  /// 拆的时候回读 NoteFloat.panel 的探针：塞进浮动面板的内容里，被移出窗口时调 onLeave（HoverTracker 的追踪视图
  /// 就是在这一下补报「移出」的，第 3 批那叠的真机崩溃是这一下回调进来读了「正写到一半的那个属性」）
  private final class TeardownProbe: NSView {
    var onLeave: () -> Void = {}
    override func viewDidMoveToWindow() { if window == nil { onLeave() } }
  }

  /// 放掉面板时它的视图跟着拆，拆的时候回调进来读 NoteFloat.panel——照 NoteDeck.releasePanel 的写法放（先拿局部变量、
  /// 把属性置空，再收走、拆视图）：收回、换一张、便签没了三条路，探针都在放的当场被叫到、读到的是已经置空的 nil。
  /// 锁的是两件：视图在放的那一下就拆（不留给面板哪天真释放时）；拆的时候属性已经是 nil（没有进行中的写入）。
  /// 2026-10-14 临时换成三种错的放法各跑过一次，都红：直接 `panel = nil`（先不先 orderOut 都一样）——这里面板不在那一下
  /// 释放（同一轮里 AppKit 还拿着它），视图不当场拆，探针没被叫到；先拆视图再置空——探针读到的还是那块面板。
  /// 那叠的真机崩溃本身（面板在「写 panel」的过程中被释放、回读撞上独占访问检查，
  /// NoteDeckTests.releasingThePanelSurvivesViewCallbacks）在浮动便签的放法里复现不出来：它总是同一轮里 orderOut 再放。
  /// **不把面板存进局部变量**（有别人拿着它，放的时候就更不会释放）
  @Test func releasingThePanelSurvivesViewTeardown() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲", "乙"])
    let float = try offscreenFloat(store, defaults: defaults)
    var reads: [Bool] = []
    func probe() {
      let probe = TeardownProbe()
      probe.onLeave = { [weak float] in reads.append(float?.panel == nil) }
      float.panel?.contentView?.addSubview(probe)
    }
    float.present(ids[0], mouse: Self.farPoint)
    probe()
    // 让出一轮：这一段里对面板的临时引用都放手了，下面才是真的释放
    try await Task.sleep(for: .milliseconds(20))
    float.model.close()
    #expect(float.panel == nil && float.model.state.noteID == nil && reads == [true])
    float.present(ids[0], mouse: Self.farPoint)
    probe()
    try await Task.sleep(for: .milliseconds(20))
    float.present(ids[1], mouse: Self.farPoint)
    #expect(float.model.state.noteID == ids[1] && float.panel != nil && reads == [true, true])
    probe()
    try await Task.sleep(for: .milliseconds(20))
    store.delete(ids[1])
    float.storeChanged()
    #expect(float.panel == nil && float.model.state.noteID == nil && reads == [true, true, true])
    // 放掉之后晚到的那几下（界面上还排着的）都不出事
    float.drag(to: Self.farPoint)
    float.drop(at: Self.farPoint)
    float.focus()
    float.resume()
    float.model.gripChanged(at: Self.farPoint)
    float.model.gripEnded(.tab, at: Self.farPoint)
    float.windowDidResize(Notification(name: NSWindow.didResizeNotification))
    float.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    try await Task.sleep(for: .milliseconds(40))
    #expect(float.panel == nil)
  }

  /// 收回时的替身：面板当场收走（键盘马上回去），原位留一块替身去做退场的动画——它是 PanelStandIn（截图不收），
  /// 放完自己收走。减弱动态效果时没有替身
  @Test func tuckingLeavesAStandInBehind() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲"])
    let float = try offscreenFloat(store, defaults: defaults, animates: true)
    defer { float.model.send(.remove) }
    float.homeEdge = { _ in .right }
    float.present(ids[0], mouse: Self.farPoint)
    let panel = try #require(float.panel)
    #expect(!onScreen(panel.frame))
    // 淡入放完（减弱动态效果时本来就是直接出现）
    try await settle { panel.alphaValue == 1 }
    let frame = panel.frame
    func standIns() -> [NSWindow] {
      NSApp.windows.filter { $0 is PanelStandIn && $0.isVisible && $0.frame.contains(frame) }
    }
    #expect(standIns().isEmpty)
    float.model.close()
    #expect(float.panel == nil && !panel.isVisible)
    guard !Style.reduceMotion else {
      #expect(standIns().isEmpty)
      return
    }
    let standIn = try #require(standIns().first)
    // 朝右边滑 48：替身的窗口盖得住起点和终点，四周给阴影留了地方；不接鼠标、不当 key、不在任何一块屏上
    #expect(standIn.frame.contains(frame.offsetBy(dx: Layout.tuckSlide, dy: 0)))
    #expect(standIn.ignoresMouseEvents && !standIn.canBecomeKey && !standIn.hasShadow)
    #expect(!onScreen(standIn.frame))
    try await settle { standIns().isEmpty }
    #expect(standIns().isEmpty)
  }

  /// 全部便签窗口的那个入口（工具栏、右键菜单；屏幕边缘关着时把便签留在屏幕上只有这条路）：浮出来 / 收回，
  /// 那一项的名字跟着走；归档的、删掉的不能浮
  @Test func notesWindowTogglesTheFloat() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲", "乙"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    let model = NotesWindowModel(store: store)
    func note(_ index: Int) -> Note? { store.note(ids[index]) }
    // 还没接上浮动便签（便签用不了时）：不做事，名字照常
    model.toggleFloating(ids[0])
    #expect(!model.isFloating(note(0)) && model.floatTitle(note(0)) == "浮在屏幕上")
    model.float = float.model
    model.toggleFloat = { [weak float] in float?.toggle($0) }
    model.toggleFloating(ids[0])
    #expect(float.model.state.noteID == ids[0] && !onScreen(float.panel?.frame))
    #expect(model.isFloating(note(0)) && !model.isFloating(note(1)) && !model.isFloating(nil))
    #expect(model.floatTitle(note(0)) == "收回边缘" && model.floatTitle(note(1)) == "浮在屏幕上")
    #expect(model.rowItems(try #require(note(0))).map(\.title).contains("收回边缘"))
    // 屏幕边缘没有那叠（总开关关着）：没有「边缘」可回
    float.update(options: NoteDeckOptions(), edgeShown: false)
    #expect(model.floatTitle(note(0)) == "取消浮动")
    #expect(model.floatSymbol(note(0)) != model.floatSymbol(note(1)))
    // 换一条浮出来：一次一张
    model.toggleFloating(ids[1])
    #expect(float.model.state.noteID == ids[1] && !model.isFloating(note(0)))
    model.toggleFloating(ids[1])
    #expect(float.model.state.noteID == nil && float.panel == nil)
    // 归档的、删掉的不能浮（右键菜单里归档的也没有那一项）
    store.setArchived(true, of: ids[1])
    model.toggleFloating(ids[1])
    #expect(float.model.state.noteID == nil)
    #expect(!model.rowItems(try #require(note(1))).map(\.title).contains("浮在屏幕上"))
    store.delete(ids[0])
    model.toggleFloating(ids[0])
    #expect(float.model.state.noteID == nil && float.panel == nil)
  }

  // MARK: 和那叠接起来

  /// 屏外的一叠和一张浮动便签，照 NoteEdge.makeDeck 的接法接上
  private func wired(_ bodies: [String], defaults: UserDefaults) throws -> (
    deck: NoteDeck, float: NoteFloat, ids: [String]
  ) {
    let (store, ids) = try library(bodies)
    let options = NoteDeckOptions()
    let float = try offscreenFloat(store, defaults: defaults)
    for frame in [
      NoteDeckLayout.pillFrame(on: Self.far, edge: .right, count: bodies.count, options: options),
      NoteDeckLayout.panelFrame(on: Self.far, edge: .right, options: options),
    ] {
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
    }
    let deck = NoteDeck(store: store, island: nil, takesKeyboard: false)
    deck.place(on: Self.far, edge: .right, options: options)
    float.update(options: options, edgeShown: true)
    float.homeEdge = { _ in .right }
    deck.onDetach = { [weak float] in float?.detach($0, from: $1, at: $2) }
    deck.model.onDetachDrag = { [weak float] in float?.drag(to: $0) }
    deck.model.onDetachDrop = { [weak float] in float?.drop(at: $0) }
    deck.onFloat = { [weak float] in float?.present($0, from: $1, mouse: Self.farPoint) }
    deck.model.focusFloat = { [weak float] in float?.focus() }
    float.onChange = { [weak deck, weak float] in deck?.model.floated(float?.model.state.noteID) }
    return (deck, float, ids)
  }

  /// 拖出来的整条路，两块面板一起：过了阈值，浮动面板出现在这条便签在那叠里的位置；**鼠标松开之前那叠里的那一份
  /// 还在视图树里**（手势是从它身上开始的）、两个正文框并存，这时打的字按编号落、两边对得上；松手，那叠里的那一份
  /// 收掉，浮动面板拿到焦点。之后点那叠里它的标签不再开第二份
  @Test func deckHandsTheNoteOverToTheFloat() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (deck, float, ids) = try wired(["甲的正文", "乙的正文"], defaults: defaults)
    defer {
      float.model.send(.remove)
      deck.close()
    }
    let store = deck.model.store
    // 便签开着时装着全局的鼠标监听：固定着，用户这时在别处点一下才不会把它收掉
    for id in ids { store.setPinned(true, of: id) }
    deck.pill?.onPress()
    deck.model.tapTab(ids[0])
    try await settle { focusedNote(deck.panel) == ids[0] }
    let deckEditor = try #require(NoteDeck.editor(for: ids[0], in: deck.panel?.contentView))
    deckEditor.setSelectedRange(NSRange(location: 2, length: 0))
    let sheet = deck.contentFrame
    #expect(sheet.width == 460 && sheet.height == 380 && !onScreen(sheet))
    let start = CGPoint(x: sheet.minX + 12, y: sheet.midY)
    deck.model.gripChanged(at: start)
    deck.model.gripChanged(at: CGPoint(x: start.x - 39, y: start.y))
    #expect(float.panel == nil && deck.model.liftedID == nil)
    let past = CGPoint(x: start.x - 60, y: start.y)
    deck.model.gripChanged(at: past)
    // 脱出来了：浮动面板就在原处、盖在上面；那叠还是「打开着」，它的那一份没拆
    let panel = try #require(float.panel)
    #expect(panel.frame == sheet && panel.level == .floating && float.model.state.isDragging)
    #expect(deck.model.state.openID == ids[0] && deck.model.liftedID == ids[0])
    #expect(deck.model.floatingID == ids[0] && deck.panel?.isVisible == true)
    #expect(NoteDeck.editor(for: ids[0], in: deck.panel?.contentView) === deckEditor)
    deck.model.gripChanged(at: CGPoint(x: past.x - 200, y: past.y - 30))
    #expect(panel.frame == sheet.offsetBy(dx: -200, dy: -30) && !onScreen(panel.frame))
    // 两个正文框并存的这一阵：那叠里那一份里打的字落在这条便签上，浮动面板里的跟着变；另一条不动
    deckEditor.insertText("新", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(store.note(ids[0])?.body == "甲的新正文" && store.note(ids[1])?.body == "乙的正文")
    try await settle {
      NoteDeck.editor(for: ids[0], in: panel.contentView)?.string == "甲的新正文"
    }
    let floatEditor = try #require(NoteDeck.editor(for: ids[0], in: panel.contentView))
    #expect(floatEditor !== deckEditor && floatEditor.string == "甲的新正文")
    // 各用各的撤销栈
    #expect(floatEditor.undoManager === float.model.textUndo)
    #expect(deckEditor.undoManager === deck.model.textUndo)
    #expect(float.model.textUndo !== deck.model.textUndo)
    // 松手
    deck.model.gripEnded(.tab, at: CGPoint(x: past.x - 200, y: past.y - 30))
    #expect(deck.model.state.phase == .fanned && !deck.model.isDetaching)
    #expect(!float.model.state.isDragging && float.panel === panel)
    // 这条便签固定着：落下后在别的窗口上面，位置记下来
    #expect(panel.level == .floating && !panel.isKeyWindow)
    #expect(Place(stored: defaults.object(forKey: Prefs.notesFloatPlace))?.id == ids[0])
    try await settle {
      focusedNote(panel) == ids[0]
        && NoteDeck.editor(for: ids[0], in: deck.panel?.contentView) == nil
    }
    #expect(focusedNote(panel) == ids[0])
    #expect(NoteDeck.editor(for: ids[0], in: deck.panel?.contentView) == nil)
    // 浮动面板里接着打字：落在这条便签上
    floatEditor.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(store.note(ids[0])?.body.contains("字") == true)
    #expect(store.note(ids[1])?.body == "乙的正文")
    // 点那叠里它的标签：不在那叠里再开一份
    deck.pill?.onPress()
    deck.model.tapTab(ids[0])
    #expect(deck.model.state.openID == nil && float.panel === panel)
    // 别的便签照常在那叠里打开；从它的操作菜单「浮在屏幕上」：换成它（一次一张），那叠里的那一份收掉
    deck.model.tapTab(ids[1])
    #expect(deck.model.state.openID == ids[1])
    try await settle { focusedNote(deck.panel) == ids[1] }
    let second = deck.contentFrame
    deck.model.toggleFloating()
    #expect(float.model.state.noteID == ids[1] && deck.model.state.phase == .fanned)
    #expect(deck.model.floatingID == ids[1] && float.panel !== panel && !panel.isVisible)
    #expect(
      float.panel?.frame
        == Layout.placed(
          size: second.size, sheet: second, edge: .right, mouse: Self.farPoint, in: [Self.far]))
    #expect(!onScreen(float.panel?.frame))
    // 收回：那叠知道没有浮着的了，又能在那叠里打开
    float.model.close()
    #expect(deck.model.floatingID == nil && float.panel == nil)
    deck.pill?.onPress()
    deck.model.tapTab(ids[1])
    #expect(deck.model.state.openID == ids[1] && deck.model.liftedID == nil)
  }

  /// 拖着的时候那叠那边被关了（Esc、状态屏叫停）：浮动面板当成松了手、落在原地，不会卡在「拖着」
  @Test func suspendingTheDeckMidDragLandsTheFloat() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (deck, float, ids) = try wired(["甲"], defaults: defaults)
    defer {
      float.model.send(.remove)
      deck.close()
    }
    deck.model.store.setPinned(true, of: ids[0])
    deck.pill?.onPress()
    deck.model.tapTab(ids[0])
    try await settle { focusedNote(deck.panel) == ids[0] }
    let sheet = deck.contentFrame
    let start = CGPoint(x: sheet.minX + 12, y: sheet.midY)
    deck.model.gripChanged(at: start)
    deck.model.gripChanged(at: CGPoint(x: start.x - 100, y: start.y))
    deck.model.gripChanged(at: CGPoint(x: start.x - 150, y: start.y))
    #expect(float.model.state.isDragging && float.panel?.frame == sheet.offsetBy(dx: -50, dy: 0))
    deck.suspend(.all)
    #expect(deck.model.state.phase == .rest && !deck.model.isDetaching)
    #expect(!float.model.state.isDragging && float.model.state.noteID == ids[0])
    #expect(float.panel?.frame == sheet.offsetBy(dx: -50, dy: 0) && float.panel?.isVisible == true)
  }

  // MARK: 第 4 批评审后的一轮（2026-10-14）

  /// 那叠里按着把手、没挪够就被关了（按着鼠标按 Esc、截图翻译、别处归档）：视图拆了 SwiftUI 不报松手，按下的地方
  /// 不能留着——再开一条，一次普通的按下松开是点了一下（关便签），不是从旧的起点拖了很远、脱出来
  @Test func closingTheDeckSheetWhileGrippedForgetsTheGrip() throws {
    let (model, _, ids) = try deckModel(["甲", "乙"])
    var detached = 0
    model.onDetach = { _, _ in detached += 1 }
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.gripChanged(at: CGPoint(x: 900, y: 500))
    model.send(.dismiss)
    model.send(Self.enter)
    model.tapTab(ids[1])
    let point = CGPoint(x: 600, y: 300)
    model.gripChanged(at: point)
    #expect(detached == 0 && !model.isDetaching && model.state.openID == ids[1])
    model.gripEnded(.tab, at: point)
    #expect(detached == 0 && model.state.phase == .fanned)
  }

  /// 浮着时按着把手、没挪开就被收回了（按着鼠标按 Esc / ⌘W）、便签没了：再浮一张，一次普通的按下松开是点了一下——
  /// 点头部不挪窗口，点标签收回
  @Test func tuckingTheFloatWhileGrippedForgetsTheGrip() throws {
    let (store, ids) = try library(["甲", "乙"])
    let model = NoteFloatModel(store: store)
    var began: [CGPoint] = []
    model.onMoveBegan = { began.append($0) }
    for gone in [NoteFloatState.Event.tuck, .remove] {
      model.send(.float(ids[0]))
      model.gripChanged(at: CGPoint(x: 900, y: 500))
      model.send(gone)
      #expect(model.state.noteID == nil)
      model.send(.float(ids[1]))
      let point = CGPoint(x: 300, y: 200)
      model.gripChanged(at: point)
      model.gripEnded(.header, at: point)
      #expect(began.isEmpty && model.state.noteID == ids[1], "\(gone)")
      model.gripChanged(at: point)
      model.gripEnded(.tab, at: point)
      #expect(began.isEmpty && model.state.noteID == nil, "\(gone)")
    }
  }

  /// 两块屏相接、那叠被换到左边缘（偏好还是右）：从它里面拖出来，标签在右侧（朝屏幕里面）、右上角不动（纸不跳）；
  /// 从它的菜单浮出来往屏幕里面（右）挪、不压着那叠；「收回边缘」朝左。没有原处的按它所在那块屏的那叠
  @Test func floatFollowsTheEdgeTheDeckIsActuallyOn() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲", "乙"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    float.update(options: NoteDeckOptions(), edgeShown: true)
    #expect(NoteDeckOptions().edge == .right && float.model.tabOnLeading)
    float.homeEdge = { _ in .left }
    // 贴着那块屏左边缘的那叠里打开的便签（面板给阴影留的 40、标签列 30、间隔 8 以外）
    let sheet = CGRect(x: Self.far.frame.minX + 78, y: -39700, width: 460, height: 380)
    let origin = NoteFloat.Origin(sheet: sheet, edge: .left)
    // 拉过大小的：脱出那一刻带标签的那一侧（右）的上角不动
    defaults.set(NSStringFromSize(NSSize(width: 600, height: 500)), forKey: Prefs.notesFloatSize)
    float.detach(ids[0], from: origin, at: CGPoint(x: sheet.maxX + 30, y: sheet.midY))
    let panel = try #require(float.panel)
    #expect(!float.model.tabOnLeading && float.model.tuckEdge == .left)
    #expect(panel.frame.maxX == sheet.maxX && panel.frame.maxY == sheet.maxY)
    #expect(panel.frame.size == CGSize(width: 600, height: 500) && !onScreen(panel.frame))
    float.drop(at: Self.farPoint)
    // 设置、屏幕变了：还是朝那叠实际在的边
    float.update(options: NoteDeckOptions(), edgeShown: true)
    #expect(!float.model.tabOnLeading)
    float.model.close()
    // 从它的菜单浮出来（没拉过大小）：比原处往屏幕里面（右）挪 48
    defaults.removeObject(forKey: Prefs.notesFloatSize)
    float.present(ids[1], from: origin, mouse: Self.farPoint)
    #expect(!float.model.tabOnLeading)
    #expect(float.panel?.frame == sheet.offsetBy(dx: Layout.floatInset, dy: 0))
    float.model.toggleMenu()
    #expect(float.model.menuItems[5].title == "收回边缘")
    #expect(float.model.menuItems[5].symbol == "sidebar.left")
    float.model.closeMenu()
    float.model.close()
    // 没有原处的（全部便签窗口）：按它落下那块屏的那叠；屏幕边缘没有那叠才按偏好
    float.present(ids[0], mouse: Self.farPoint)
    #expect(!float.model.tabOnLeading)
    float.model.close()
    float.homeEdge = { _ in nil }
    float.present(ids[0], mouse: Self.farPoint)
    #expect(float.model.tabOnLeading)
  }

  /// 记下的大小拿出来时夹进它要出现的那块屏：大外接屏上拉大的、偏好被写坏的，拖出来、浮出来都不伸出那块屏
  @Test func rememberedSizeFitsTheScreen() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (store, ids) = try library(["甲"])
    let float = try offscreenFloat(store, defaults: defaults)
    defer { float.model.send(.remove) }
    let visible = Self.far.visibleFrame.size
    for stored in ["{2560, 1440}", NSStringFromSize(NSSize(width: 1e9, height: 1e9))] {
      defaults.set(stored, forKey: Prefs.notesFloatSize)
      float.detach(ids[0], from: .init(sheet: Self.farSheet), at: Self.farPoint)
      #expect(float.panel?.frame.size == visible, "\(stored)")
      #expect(float.panel?.frame.maxY == Self.farSheet.maxY, "\(stored)")
      float.drop(at: Self.farPoint)
      #expect(float.panel?.frame == Self.far.visibleFrame, "\(stored)")
      float.model.close()
      float.present(ids[0], mouse: Self.farPoint)
      #expect(float.panel?.frame.size == visible, "\(stored)")
      float.model.close()
    }
  }

  /// 拖到一半按了截图、遮罩出来后才松手：遮罩拿着 key，落下时不抢（只放第一响应者）；重启后恢复的本来就不当 key。
  /// 遮罩建在屏外 (-20000, -20000)、只 orderFront（同 ScreenshotTests.selectionOverlayKeepsPanelsOpen）
  @Test func landingLeavesTheSelectionOverlayKey() throws {
    let screen = try #require(NSScreen.screens.first)
    let context = try #require(
      CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let overlay = SelectionOverlay(
      shot: ScreenCapture.Shot(screen: screen, image: try #require(context.makeImage())),
      session: SelectionSession(mode: .capture))
    overlay.setFrame(NSRect(x: -20000, y: -20000, width: 40, height: 40), display: false)
    let other = NSWindow()
    #expect(NoteFloat.landsWithKey(true, windows: [other, overlay]))
    #expect(!NoteFloat.landsWithKey(false, windows: [other, overlay]))
    overlay.orderFrontRegardless()
    #expect(!NoteFloat.landsWithKey(true, windows: [other, overlay]))
    overlay.orderOut(nil)
    #expect(NoteFloat.landsWithKey(true, windows: [other, overlay]))
  }

  /// 拖出去之后手势没报松手（那一份看不见了、浮动面板盖到了鼠标底下）：鼠标松开的监听兜底——当成在松开的地方松了手，
  /// 浮动便签落下、那叠里那一份收掉，之后关闭钮 / Esc 都管用；监听是一次性的。正常的松手先到时监听已经摘了，晚到的
  /// 兜底是空转。这里不发真的鼠标事件：直接调监听收到松开时调的那个入口
  @Test func strandedDragLandsOnMouseUp() async throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (deck, float, ids) = try wired(["甲", "乙"], defaults: defaults)
    defer {
      float.model.send(.remove)
      deck.close()
    }
    for id in ids { deck.model.store.setPinned(true, of: id) }
    deck.pill?.onPress()
    deck.model.tapTab(ids[0])
    try await settle { focusedNote(deck.panel) == ids[0] }
    let sheet = deck.contentFrame
    let start = CGPoint(x: sheet.minX + 12, y: sheet.midY)
    #expect(!deck.isWatchingRelease)
    deck.model.gripChanged(at: start)
    deck.model.gripChanged(at: CGPoint(x: start.x - 60, y: start.y))
    #expect(float.model.state.isDragging && deck.model.isDetaching && deck.isWatchingRelease)
    // 手势没回来，监听收到了松开
    let released = CGPoint(x: start.x - 300, y: start.y - 40)
    deck.mouseReleased(at: released)
    #expect(!deck.isWatchingRelease)
    try await settle { !float.model.state.isDragging }
    #expect(!float.model.state.isDragging && float.model.state.noteID == ids[0])
    #expect(float.panel?.frame == sheet.offsetBy(dx: -300 + 60, dy: -40))
    #expect(!deck.model.isDetaching && deck.model.state.phase == .fanned)
    #expect(deck.model.floatingID == ids[0] && !onScreen(float.panel?.frame))
    // 之后能关：Esc 收回
    float.panel?.cancelOperation(nil)
    #expect(float.panel == nil && float.model.state.noteID == nil)
    // 正常的松手先到：监听已经摘了，晚到的兜底不再落一次
    deck.model.tapTab(ids[1])
    try await settle { focusedNote(deck.panel) == ids[1] }
    let second = deck.contentFrame
    let grip = CGPoint(x: second.minX + 12, y: second.midY)
    deck.model.gripChanged(at: grip)
    deck.model.gripChanged(at: CGPoint(x: grip.x - 80, y: grip.y))
    #expect(deck.isWatchingRelease)
    deck.model.gripEnded(.tab, at: CGPoint(x: grip.x - 80, y: grip.y))
    #expect(!deck.isWatchingRelease && !float.model.state.isDragging)
    let landed = float.panel?.frame
    deck.mouseReleased(at: CGPoint(x: grip.x - 500, y: grip.y))
    try await Task.sleep(for: .milliseconds(40))
    #expect(float.panel?.frame == landed && float.model.state.noteID == ids[1])
  }
}
