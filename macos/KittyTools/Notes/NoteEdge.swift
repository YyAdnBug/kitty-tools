// 屏幕边缘的便签（PLAN §10「便签」拍板 B；规矩在 mac-overlay-panel §12）：平时贴在屏幕边上的一条药丸，鼠标靠过去扇出
// 一列标签，点一张，便签从边缘滑出来直接打字。这里管「几块屏」的事，一块屏上的那叠在 NoteDeck：
// - **什么时候有**：设置里的总开关开着（默认开），而且没归档没删的便签至少一条——否则一个窗口都不建。从 0 条变成有的
//   那一刻出现；每台电脑第一次出现时刘海岛说一句在哪（说过了记在偏好里，这个键不注册默认值、不跟设置的导出走）。
// - **放在哪**：主显示器（默认）/ 所有显示器 / 指定的那一块，右边（默认）或左边；两块屏相接的那条边不放、换到另一侧
//   （NoteDeckLayout.placements）。设置变了、屏幕参数变了、便签的条数和颜色变了、系统的「增强对比度 / 降低透明度」
//   变了就重摆——都是现成的通知和 Observation，没有定时器、没有轮询。
// - **只展开一块屏的**：一块屏的那叠要展开，别的屏的让开（固定着的便签不收）。
// - **叫停**（suspend）：截图框选、长截图、录屏选区和倒数、状态屏开始的地方由 AppDelegate 显式来调——先落盘，扇出的
//   当场收起；鼠标进药丸、悬停出预览卡时还会再问一句 canFan。不靠「被别的窗口盖住就收不到鼠标」（追踪区不看遮挡）。
// - 「新建便签」（全局动作、菜单栏、启动器、药丸和「+」的右键菜单）：建一条并在鼠标所在屏的那叠里打开。
// - **浮动便签**（NoteFloat，第 4 批）也由这里拿着——它不看总开关（屏幕边缘关着时照样能从全部便签窗口浮出来）：
//   各块屏的那叠把「拖出来了 / 从菜单浮出去 / 点了浮着那条的标签」转给它，它的状态变了这里告诉各叠（哪条浮着；
//   那条正开在某一叠里就从那叠里收掉）；设置、屏幕、便签的变化顺手转给它（不另挂一份通知）；启动时让固定着的
//   那一张回到原处。

import AppKit
import Observation
import SwiftUI

final class NoteEdge {
  /// 叫停时打开着的便签怎么办
  enum Suspension {
    /// 留着：截图 / 录屏框选和倒数——它是内容，留在冻结帧和录屏里
    case keepsOpen
    /// 没固定的收：截图翻译、识字、长截图（同没固定的浮层）
    case unlessPinned
    /// 都收：状态屏
    case all

    /// 打开着的便签收不收（纯函数）。pinned：它是不是固定着
    nonisolated func closesOpen(pinned: Bool) -> Bool {
      switch self {
      case .keepsOpen: false
      case .unlessPinned: !pinned
      case .all: true
      }
    }
  }

  private let store: NoteStore
  private let defaults: UserDefaults
  private let island: Island?
  /// 浮动便签（一次一张；总开关关着、一块屏都没放时也在）
  let float: NoteFloat
  /// 现在能不能扇出（AppDelegate 给：没在截图框选 / 长截图 / 录屏选区和倒数 / 状态屏）
  var canFan: () -> Bool = { true }
  /// 药丸（和标签列下「+」）右键菜单的三项
  var newNote: () -> Void = {}
  var showNotes: () -> Void = {}
  var showSettings: () -> Void = {}
  /// 打开的便签「在全部便签里打开」
  var showInWindow: (String) -> Void = { _ in }

  /// 放着的那几叠（按显示器认）
  private var decks: [(display: CGDirectDisplayID, deck: NoteDeck)] = []
  private var options: NoteDeckOptions
  /// 上次摆的时候没归档的便签各是什么颜色（条数、顺序、颜色变了才重摆）
  private var colors: [Int] = []
  private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
  /// 自己正在写偏好（⌥ 拖完药丸）：这期间偏好变了的通知不理，写完统一摆一次
  private var isWritingPrefs = false
  private var hintTask: Task<Void, Never>?

  init(store: NoteStore, defaults: UserDefaults = .standard, island: Island?) {
    self.store = store
    self.defaults = defaults
    self.island = island
    options = NoteDeckOptions(defaults)
    float = NoteFloat(store: store, defaults: defaults, island: island)
    float.homeEdge = { [unowned self] in homeEdge(near: $0) }
    float.onChange = { [unowned self] in floatChanged() }
    float.model.showInWindow = { [unowned self] in showInWindow($0) }
  }

  /// 开始：摆一次，之后跟着设置、屏幕、便签、系统的显示辅助开关的变化重摆；上次固定着浮在屏幕上的那一张回到原处
  func start() {
    defer { float.restore() }
    func observe(
      _ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil,
      _ work: @escaping @MainActor (NoteEdge) -> Void
    ) {
      let token = center.addObserver(forName: name, object: object, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          if let self { work(self) }
        }
      }
      tokens.append((center, token))
    }
    observe(.default, UserDefaults.didChangeNotification, object: defaults) { $0.prefsChanged() }
    observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refresh() }
    // 药丸是常驻的、皮肤只在重摆时取色：增强对比度 / 降低透明度中途开关了要跟上
    observe(
      NSWorkspace.shared.notificationCenter,
      NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    ) { $0.refresh() }
    observeStore()
    refresh()
  }

  // MARK: 什么时候有、放在哪

  /// 该不该有（纯函数）：总开关开着，而且至少有一条没归档没删的便签
  nonisolated static func isShown(enabled: Bool, count: Int) -> Bool { enabled && count > 0 }

  /// 第一次出现时岛上说的话
  nonisolated static func hint(
    _ edge: NoteDeckOptions.Edge
  ) -> (title: String, detail: String) {
    ("便签在屏幕\(edge.name)边缘", "鼠标靠过去就能看到")
  }

  /// 这台电脑上说过「便签在屏幕右边缘」了吗：没说过就记成说过、返回 true（只这一次）
  nonisolated static func takesHint(_ defaults: UserDefaults) -> Bool {
    guard !defaults.bool(forKey: Prefs.notesDeckHintShown) else { return false }
    defaults.set(true, forKey: Prefs.notesDeckHintShown)
    return true
  }

  /// 按现在的设置、屏幕、便签重摆：该有的建出来 / 挪到位，不该有的收掉
  func refresh() {
    options = NoteDeckOptions(defaults)
    colors = store.active.map(\.color)
    let live = NSScreen.screens
    let screens = NoteDeckScreen.attached()
    let placements =
      Self.isShown(enabled: options.isEnabled, count: colors.count)
      ? NoteDeckLayout.placements(screens, options: options) : []
    var placed: [(display: CGDirectDisplayID, deck: NoteDeck)] = []
    for placement in placements {
      let display = live[placement.screen].displayID ?? CGDirectDisplayID(placement.screen)
      let deck = decks.first { $0.display == display }?.deck ?? makeDeck()
      deck.place(on: screens[placement.screen], edge: placement.edge, options: options)
      placed.append((display, deck))
    }
    for old in decks where !placed.contains(where: { $0.deck === old.deck }) { old.deck.close() }
    let appeared = decks.isEmpty && !placed.isEmpty
    decks = placed
    float.update(options: options, edgeShown: !decks.isEmpty)
    if appeared, let edge = placements.first?.edge { hintIfFirst(edge) }
  }

  private func makeDeck() -> NoteDeck {
    let deck = NoteDeck(store: store, island: island)
    deck.canFan = { [unowned self] in canFan() }
    deck.onExpand = { [unowned self, unowned deck] in
      for other in decks where other.deck !== deck { other.deck.model.yield() }
    }
    deck.pillMenu = { [unowned self] in menu() }
    deck.onPillDrag = { [unowned self, unowned deck] in dragPill(of: deck, to: $0, drops: false) }
    deck.onPillDrop = { [unowned self, unowned deck] in dragPill(of: deck, to: $0, drops: true) }
    deck.model.showInWindow = { [unowned self] in showInWindow($0) }
    deck.model.showNotes = { [unowned self] in showNotes() }
    deck.model.showSettings = { [unowned self] in showSettings() }
    // 浮动便签：拖出来（过了阈值 → 跟着走 → 松手）、从操作菜单浮出去、点了浮着那条的标签
    deck.onDetach = { [unowned self] in float.detach($0, from: $1, at: $2) }
    deck.model.onDetachDrag = { [unowned self] in float.drag(to: $0) }
    deck.model.onDetachDrop = { [unowned self] in float.drop(at: $0) }
    deck.onFloat = { [unowned self] in float.present($0, from: $1) }
    deck.model.focusFloat = { [unowned self] in float.focus() }
    deck.model.floated(float.model.state.noteID)
    return deck
  }

  /// 浮着的换了一条 / 没有了：告诉各叠（它的标签上有记号、点它是把浮着的叫到前面；刚浮出去的那条还开在哪一叠里
  /// 就从那叠里收掉，NoteDeckModel.floated）
  private func floatChanged() {
    for entry in decks { entry.deck.model.floated(float.model.state.noteID) }
  }

  /// 屏幕边缘的那叠实际在哪条边（不从那叠里出来的浮动便签按它定标签在哪一侧、收回往哪边滑）：它所在的那块屏放了就是
  /// 那块屏的，没放用放了的第一块的；一块都没放（总开关关着、没有便签）是 nil
  private func homeEdge(near frame: CGRect) -> NoteDeckOptions.Edge? {
    let home = decks.first { $0.deck.screen.frame.intersects(frame) } ?? decks.first
    return home?.deck.model.edge
  }

  private func hintIfFirst(_ edge: NoteDeckOptions.Edge) {
    guard let island, Self.takesHint(defaults) else { return }
    let hint = Self.hint(edge)
    hintTask = Task { [weak self] in
      // 刚记下第一条时岛上正说着「已记下」：等它说完，不顶掉
      if island.isOpen { try? await Task.sleep(for: .seconds(2.4)) }
      guard !Task.isCancelled, self?.decks.isEmpty == false else { return }
      island.show(hint.title, detail: hint.detail, tone: .info, symbol: "note.text")
    }
  }

  // MARK: 跟着变

  private func prefsChanged() {
    if !isWritingPrefs, NoteDeckOptions(defaults) != options { refresh() }
  }

  /// 便签变了（Observation：读过 notes，它一变就回调一次，回调里再挂下一次）
  private func observeStore() {
    withObservationTracking {
      _ = store.notes
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.storeChanged()
        self?.observeStore()
      }
    }
  }

  private func storeChanged() {
    for entry in decks { entry.deck.storeChanged() }
    float.storeChanged()
    if store.active.map(\.color) != colors { refresh() }
  }

  // MARK: 叫停、新建

  /// 截图框选 / 长截图 / 录屏选区和倒数 / 状态屏开始的地方调：先落盘，扇出的当场收起。浮动便签不收（它是人自己放在
  /// 屏幕上的内容，同钉图：冻结帧和录屏里有它，状态屏盖在它上面），对它来说就是开头的那一下落盘
  func suspend(_ kind: Suspension) {
    store.flush()
    for entry in decks { entry.deck.suspend(kind) }
  }

  /// 「新建便签」：建一条（最前面那条还是空白的就用它，NoteStore.blankOrNew）并在鼠标所在屏的那叠里打开（那块屏没放就用
  /// 放了的第一块）。返回 false = 这边开不了（总开关关着、哪块屏都放不了），调用方照老办法在全部便签窗口里打开
  func openNew() -> Bool {
    let options = NoteDeckOptions(defaults)
    guard options.isEnabled,
      !NoteDeckLayout.placements(NoteDeckScreen.attached(), options: options).isEmpty
    else { return false }
    let note = store.blankOrNew()
    refresh()  // 这是第一条的话，那叠这时才有
    let mouse = NSEvent.mouseLocation
    let home = decks.first { $0.deck.screen.frame.contains(mouse) } ?? decks.first
    guard let deck = home?.deck else { return false }
    deck.model.open(created: note.id)
    return true
  }

  // MARK: 药丸

  /// 右键药丸：就三项（标签列下的「+」右键是同名的三项，NoteDeckView）
  private func menu() -> NSMenu {
    let menu = NSMenu()
    let color = NSColor(Style.Family.notes)
    menu.addAction(HotKeyAction.noteNew.title, symbol: HotKeyAction.noteNew.symbol, color: color) {
      [unowned self] in newNote()
    }
    menu.addAction(HotKeyAction.noteAll.title, symbol: HotKeyAction.noteAll.symbol, color: color) {
      [unowned self] in showNotes()
    }
    menu.addItem(.separator())
    menu.addAction("设置…", symbol: "gearshape", color: NSColor(Style.Family.general)) {
      [unowned self] in showSettings()
    }
    return menu
  }

  /// 按住 ⌥ 拖药丸：跟着鼠标换边、换高度（「指定某一块」、而且那块真接着时还能换屏）；松手（drops）记进偏好再整个重摆。
  /// 哪条边是设置（跟着导出走），纵向位置和指定的是哪块屏是这台电脑自己的状态
  private func dragPill(of deck: NoteDeck, to mouse: CGPoint, drops: Bool) {
    let live = NSScreen.screens
    let screens = NoteDeckScreen.attached()
    // 指定的那块没接着、药丸是退回主显示器的：只换边和高度，不改写「指定的是哪块」
    let crossesScreens = NoteDeckLayout.crossesScreens(options.display, screens: screens)
    let display = decks.first { $0.deck === deck }?.display
    let height = NoteDeckLayout.pillHeight(
      count: colors.count, metrics: NoteDeckMetrics(scale: options.size.scale))
    guard let index = live.firstIndex(where: { $0.displayID == display }),
      let result = NoteDeckLayout.dragged(
        to: mouse, screens: screens, from: index, crossesScreens: crossesScreens,
        pillHeight: height)
    else { return }
    let target = screens[result.placement.screen]
    guard drops else {
      var moved = options
      moved.position = result.position
      return deck.movePill(to: target, edge: result.placement.edge, options: moved)
    }
    isWritingPrefs = true
    defaults.set(result.placement.edge.rawValue, forKey: Prefs.notesDeckEdge)
    defaults.set(result.position, forKey: Prefs.notesDeckPosition)
    if crossesScreens { defaults.set(target.name, forKey: Prefs.notesDeckChosenDisplay) }
    isWritingPrefs = false
    refresh()
  }
}

extension NoteDeckScreen {
  /// 现在接着的显示器（主显示器在前）。名字是系统给的显示名，同名的第二块起加序号（NoteDeckLayout.uniqueNames）
  static func attached() -> [NoteDeckScreen] {
    let screens = NSScreen.screens
    let names = NoteDeckLayout.uniqueNames(screens.map(\.localizedName))
    return zip(screens, names).map {
      NoteDeckScreen(name: $1, frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
  }
}
