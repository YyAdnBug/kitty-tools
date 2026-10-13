// 一块屏上的那叠（PLAN §10「便签」第 3 批；规矩在 mac-overlay-panel §12）。两块窗口、两件事：
// - 边上的药丸（NoteDeckPill，装饰）：常驻，鼠标靠过来报一声；
// - 那叠（NoteDeckPanel，内容）：扇出的一列标签和打开的便签。**用时再建、收起后放掉**（收起后留 lingering 再放，
//   刚收又开接着用同一块；同 Shell/TransientPanel 的路数——它只拿 OverlayPanel，这里就十来行，没为它改成泛型）。
// NoteDeck 管窗口：界面读的状态在 NoteDeckModel，它的状态一变，这里按前后两个状态算出该做哪几件事（effects，纯函数、
// 有单测）再去做——露出 / 收起面板、当 key、把焦点放进正文、把键盘还给原来的 App、落盘、点别处的鼠标监听
// （global + local，打开便签时装、关掉时卸）、离开热区和 4 秒没动静的计时（可取消的 Task，静置时一个都没有）。
// 几块屏的那叠谁展开、什么时候有、放哪，在 NoteEdge。
// 永远不调 NSApp.activate；扇出时不当 key，点开便签才 makeKey（悬停打开的不当），关掉便签当场把键盘还回去。
// 焦点进正文有两道：正文框自己在挂进窗口 / 被点名时拿（NoteDeckModel.focus → NoteBodyField），这里再晚一拍按编号去找
// 一次当兜底，没找到（编辑区还没建出来）隔一小会儿再找两次。

import AppKit
import SwiftUI

final class NoteDeck: NSObject {
  /// 状态变了之后要做的事（effects 算出来的；装卸点别处的监听只看「现在开没开着便签」，不在这里面）
  nonisolated struct Effects: OptionSet, Sendable {
    let rawValue: Int
    /// 攒着的改动落盘（关掉、换一条、收起）
    static let flush = Effects(rawValue: 1 << 0)
    /// 这块屏要展开了：让别的屏的那叠让开
    static let expand = Effects(rawValue: 1 << 1)
    /// 露出面板（没有就建）
    static let present = Effects(rawValue: 1 << 2)
    /// 收起面板
    static let hide = Effects(rawValue: 1 << 3)
    /// 把键盘还给原来的 App（面板留着）
    static let releaseKey = Effects(rawValue: 1 << 4)
    /// 焦点进正文，并当 key（悬停打开的那一次不当 key，见 NoteDeckModel.takesKey）
    static let focus = Effects(rawValue: 1 << 5)
    /// 开始看着：离开热区、4 秒没动静
    static let watch = Effects(rawValue: 1 << 6)
  }

  /// 状态从 old 变成 new 该做哪几件事（纯函数）。要点：
  /// - 只有**新打开 / 换了一条**才当 key、聚焦——别的变化（切了「一直展开」之类的设置、「+N」）不许抢键盘；
  /// - 任何一条「打开 → 扇出」的路都当场把键盘还回去（面板留着）；回到静置是整块收走，键盘自然回去。
  nonisolated static func effects(from old: NoteDeckState, to new: NoteDeckState) -> Effects {
    var effects: Effects = []
    let opened = new.openID != nil && old.openID != new.openID
    if old.openID != nil, old.openID != new.openID { effects.insert(.flush) }
    if new.phase != .rest, old.phase == .rest || opened { effects.insert(.expand) }
    switch new.phase {
    case .rest:
      effects.insert(.hide)
    case .fanned:
      if old.phase == .rest { effects.insert(.present) }
      if old.openID != nil { effects.insert(.releaseKey) }
      effects.insert(.watch)
    case .open:
      if old.phase == .rest { effects.insert(.present) }
      if opened { effects.insert(.focus) }
    }
    return effects
  }

  /// 扇出后多久没动静收回、鼠标离开热区多久后再确认一次、收起时标签滑回去给多久
  static let idleDelay: Duration = .seconds(4)
  static let leaveDelay: Duration = .milliseconds(150)
  static let hideDuration: Duration = .milliseconds(140)
  /// 兜底去找正文框没找到时，隔多久再找（各一次）
  static let focusRetryDelays: [TimeInterval] = [0.05, 0.15]

  let model: NoteDeckModel
  /// 「一直展开」时没有药丸
  private(set) var pill: NoteDeckPill?
  /// 没展开过、收起后放掉了都是 nil
  private(set) var panel: NoteDeckPanel?
  private(set) var screen = NoteDeckScreen(name: "", frame: .zero, visibleFrame: .zero)
  /// 面板该在的位置（全局坐标）
  private var frame = CGRect.zero
  /// 面板收起后留多久再放掉（单测传几十毫秒）
  private let lingering: Duration
  /// 打开便签时面板当不当 key。只有单测传 false：屏外的面板一当 key，用户正在用的那个 App 就丢了键盘
  private let takesKeyboard: Bool
  /// 兜底去找正文框已经重试了几次
  private var focusRetries = 0

  /// 现在能不能扇出（没在截图框选 / 长截图 / 录屏选区和倒数 / 状态屏）：鼠标进药丸、悬停出预览卡 / 悬停打开时问
  var canFan: () -> Bool = { true }
  /// 这块屏要展开了（别的屏的那叠该让开）
  var onExpand: () -> Void = {}
  var pillMenu: () -> NSMenu? = { nil }
  /// 按住 ⌥ 拖药丸：拖到哪了、松手在哪（全局坐标）
  var onPillDrag: (CGPoint) -> Void = { _ in }
  var onPillDrop: (CGPoint) -> Void = { _ in }

  private var monitors: [Any] = []
  private var idleTask: Task<Void, Never>?
  private var leaveTask: Task<Void, Never>?
  private var hideTask: Task<Void, Never>?
  private var releaseTask: Task<Void, Never>?
  private var lastActivity = ContinuousClock.now
  /// 正被叫停（截图、状态屏开始的那一下）：收起不做动画，冻结帧里不留半截
  private var isSuspending = false
  /// 正等着确认「鼠标真的离开了」、面板收起后正等着放掉（单测看这两个，不靠掐时间）
  var isAwaitingLeave: Bool { leaveTask != nil }
  var isLingering: Bool { releaseTask != nil }
  /// 这次是旁白「按下」药丸扇出的：鼠标本来就不在热区里，不做「离开了就收」，只靠 4 秒没动静；鼠标真进过热区、
  /// 或者这一列收回之后复原
  private var skipsLeave = false

  init(
    store: NoteStore, island: Island?, lingering: Duration = .seconds(2),
    takesKeyboard: Bool = true
  ) {
    model = NoteDeckModel(store: store)
    self.lingering = lingering
    self.takesKeyboard = takesKeyboard
    super.init()
    model.island = island
    // 都弱引用：这块屏不放了之后，界面那边还可能有晚到的一下（悬停的计时、追踪区的事件）
    model.onChange = { [weak self] old, new in self?.stateChanged(from: old, to: new) }
    model.onActivity = { [weak self] in self?.pointerMoved() }
    model.focusBody = { [weak self] in self?.focusBody() }
    model.onMenu = { [weak self] open in self?.menuChanged(open) }
    model.canFan = { [weak self] in self?.canFan() ?? true }
    model.withEditor = { [weak self] body in
      guard let self, let id = model.state.openID,
        let editor = Self.editor(for: id, in: panel?.contentView)
      else { return }
      body(editor)
    }
  }

  // MARK: 摆放

  /// 摆到这块屏的这条边（设置变了、屏幕变了、便签条数变了都重摆一遍）。只摆窗口，**不许当 key**：
  /// 固定着的便签开着时在设置里动一下开关，键盘不能被它抢走
  func place(on screen: NoteDeckScreen, edge: NoteDeckOptions.Edge, options: NoteDeckOptions) {
    self.screen = screen
    let colors = model.store.active.map(\.color)
    let pillFrame = NoteDeckLayout.pillFrame(
      on: screen, edge: edge, count: colors.count, options: options)
    frame = NoteDeckLayout.panelFrame(on: screen, edge: edge, options: options)
    // 面板、便签的大小变了：打开着的便签定住的位置按新的重算一次（光是便签多了少了、换了颜色不动它）
    let resized =
      model.panelSize != frame.size || model.options.noteSize != options.noteSize
      || model.options.size != options.size || model.edge != edge
    if model.edge != edge { model.edge = edge }
    if model.panelSize != frame.size { model.panelSize = frame.size }
    let center = frame.maxY - pillFrame.midY
    if model.pillCenter != center { model.pillCenter = center }
    if options.alwaysFanned {
      releasePill()
    } else {
      let pill = self.pill ?? makePill()
      pill.update(frame: pillFrame, edge: edge, colors: colors, options: options)
      if self.pill == nil {
        self.pill = pill
        pill.panel.orderFrontRegardless()
      }
      pill.setShown(model.state.phase == .rest)
    }
    if let panel, panel.frame != frame { panel.setFrame(frame, display: true) }
    // 最后设：「一直展开」刚打开时这一下会当场把面板露出来，要用上面摆好的位置
    if model.options != options { model.options = options }
    if resized { model.relayout() }
    updateTracking()
    applyBehavior()
  }

  /// 按住 ⌥ 拖着的时候：只挪药丸，松手才写偏好、整个重摆
  func movePill(to screen: NoteDeckScreen, edge: NoteDeckOptions.Edge, options: NoteDeckOptions) {
    let colors = model.store.active.map(\.color)
    pill?.update(
      frame: NoteDeckLayout.pillFrame(
        on: screen, edge: edge, count: colors.count, options: options),
      edge: edge, colors: colors, options: options)
  }

  /// 仓库里的便签变了（NoteEdge 转过来）：打开着的那条没了就关；标签多了少了，热区跟着变
  func storeChanged() {
    model.reconcile()
    updateTracking()
  }

  private func makePill() -> NoteDeckPill {
    let pill = NoteDeckPill()
    pill.onEnter = { [weak self] optionDown in
      guard let self else { return }
      model.send(.pillEntered(optionDown: optionDown, allowed: canFan()))
      pointerMoved()
    }
    pill.onPress = { [weak self] in
      guard let self else { return }
      skipsLeave = true
      model.send(.pillEntered(optionDown: false, allowed: canFan()))
    }
    pill.onExit = { [weak self] in self?.pointerMoved() }
    pill.onDrag = { [weak self] in self?.onPillDrag($0) }
    pill.onDrop = { [weak self] in self?.onPillDrop($0) }
    pill.menu = { [weak self] in self?.pillMenu() }
    return pill
  }

  private func makePanel() -> NoteDeckPanel {
    let panel = NoteDeckPanel(frame: frame, model: model) { [weak self] in self?.pointerMoved() }
    panel.keyEquivalentHandler = { [weak model] in model?.handleKeyEquivalent($0) ?? false }
    panel.keyDownHandler = { [weak model] in model?.handleMenuKey($0) ?? false }
    panel.onCancel = { [weak model] in model?.cancel() }
    // 失去 key（切到别的 App、点了别的窗口）：攒着的改动先落下去
    panel.onResignKey = { [weak model] in model?.store.flush() }
    panel.contentFrame = { [weak self] in self?.contentFrame ?? .zero }
    return panel
  }

  /// 面板里真有东西的那一块（全局坐标；没有就是 .zero）：截图的悬停列表用它——面板本身是「便签宽 + 标签列」×
  /// 整个可见区高的一块透明窗口，按窗口的 frame 算的话屏幕边上一大片都被它占着。正在收（标签往回滑的那一小会儿）
  /// 也算没有
  var contentFrame: CGRect {
    guard panel?.isVisible == true, hideTask == nil else { return .zero }
    return model.contentFrame(in: frame)
  }

  /// 这块屏不放了（总开关关了、便签删光了、屏幕拔了）：都收掉
  func close() {
    model.store.flush()
    removeMonitors()
    stopWatching()
    hideTask?.cancel()
    hideTask = nil
    releaseTask?.cancel()
    releaseTask = nil
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    releasePanel()
    releasePill()
  }

  /// 放掉面板（收起后留够了、这块屏不放了）。**不能直接写 `panel = nil`**（2026-10-13 真机崩溃，扇出再收回约 2 秒后必崩）：
  /// 那一句会在「写 panel」的过程中把面板释放掉，面板的视图跟着拆，HoverTracker 的视图被移出窗口时补报一个「移出」
  /// → NoteDeckModel.hover → pointerMoved → updateTracking 又来读 panel——同一个属性写到一半被读，Swift 运行时的
  /// 独占访问检查（Simultaneous accesses…）直接终止进程。
  /// 所以：先拿到局部变量、把属性置空（局部变量还拿着，这一下不释放），再收走、把它的视图拆掉（回调进来时属性已经是
  /// nil、没有进行中的写入），函数结束局部变量才放手。NoteDeckTests.releasingThePanelSurvivesViewCallbacks 复现它
  private func releasePanel() {
    guard let old = panel else { return }
    panel = nil
    old.orderOut(nil)
    old.contentView = nil
  }

  /// 放掉药丸：同一个写法。它的视图现在拆掉时不回调，照这样写以后加了也不出事
  private func releasePill() {
    guard let old = pill else { return }
    pill = nil
    old.panel.orderOut(nil)
  }

  /// 被叫停（NoteEdge.suspend）：先落盘；扇出的当场收起，打开的便签要不要收看是哪种。「一直展开」时那一列不收
  /// （它是屏幕上常驻的东西），悬停出预览卡 / 悬停打开靠 canFan 那一问挡住
  func suspend(_ kind: NoteEdge.Suspension) {
    model.store.flush()
    // 刚收回、标签还在往回滑（面板要过一小会儿才收走）：当场收走，截图的冻结帧里不留半截
    if hideTask != nil { orderOut() }
    isSuspending = true
    defer { isSuspending = false }
    model.send(.suspend(closesOpen: kind.closesOpen(pinned: model.current?.isPinned ?? false)))
  }

  // MARK: 状态变了

  private func stateChanged(from old: NoteDeckState, to new: NoteDeckState) {
    let effects = Self.effects(from: old, to: new)
    if effects.contains(.flush) { model.store.flush() }
    if effects.contains(.expand) { onExpand() }
    if effects.contains(.hide) {
      removeMonitors()
      stopWatching()
      hide(animated: !isSuspending)
    } else {
      if effects.contains(.present) || panel?.isVisible != true { present() }
      // 点别处的监听：便签开着才装（幂等）
      if new.openID != nil { installMonitors() } else { removeMonitors() }
      if effects.contains(.releaseKey) { releaseKey() }
      if effects.contains(.watch) { watch() } else { stopWatching() }
      if effects.contains(.focus) { focusBody(makesKey: model.takesKey) }
    }
    updateTracking()
    applyBehavior()
  }

  /// 露出面板（没有就建；等着收起、等着放掉的都作废）。不当 key、不激活本 App
  private func present() {
    hideTask?.cancel()
    hideTask = nil
    releaseTask?.cancel()
    releaseTask = nil
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    panel.orderFrontRegardless()
    pill?.setShown(false)
    // 标签一张接一张滑出来：先让它们在边外排好一遍（没排过的话一置真就是直接出现，没有动画），下一拍再露出来。
    // 减弱动态效果时直接出现
    if Style.reduceMotion {
      model.setRevealed(true)
    } else {
      panel.contentView?.layoutSubtreeIfNeeded()
      perform(#selector(reveal), with: nil, afterDelay: 0, inModes: [.common])
    }
  }

  @objc private func reveal() {
    if model.state.phase != .rest { model.setRevealed(true) }
  }

  /// 收起：标签滑回边外再把窗口收走，药丸回来；之后留 lingering 再放掉面板。被叫停、减弱动态效果时当场收走；
  /// **面板还当着 key 时也当场收走**（用键盘关的：键盘要马上回到原来的 App，不等那 0.14 秒）
  private func hide(animated: Bool) {
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(reveal), object: nil)
    model.setRevealed(false)
    pill?.setShown(true)
    hideTask?.cancel()
    hideTask = nil
    guard let panel, panel.isVisible else { return }
    guard animated, !Style.reduceMotion, !panel.isKeyWindow else { return orderOut() }
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: Self.hideDuration)
      guard !Task.isCancelled else { return }
      self?.orderOut()
    }
  }

  private func orderOut() {
    hideTask?.cancel()
    hideTask = nil
    panel?.orderOut(nil)
    releaseTask?.cancel()
    releaseTask = Task { [weak self, lingering] in
      try? await Task.sleep(for: lingering)
      // 留着的时候又展开了（present 作废了这一下）就不放
      guard !Task.isCancelled, let self, panel?.isVisible == false else { return }
      releasePanel()
    }
  }

  /// 关掉便签回到那一列时：面板还得留在屏幕上，键盘却要**当场**还给原来的 App——不然人回去打的字全被这块面板吞掉
  /// （还响提示音）。系统没有「留着但不当 key」的接口，只能收走再露出来（不再 makeKey）。
  /// 这一收一放在同一轮事件里，闪不闪要真机看（HANDTEST「便签手测」）
  private func releaseKey() {
    guard let panel, panel.isKeyWindow else { return }
    panel.orderOut(nil)
    panel.orderFrontRegardless()
  }

  /// 别的 App 全屏时能不能出：呼出来的都能；只有「一直展开」又没开「盖在全屏 App 上」时那一列不进全屏（打开便签的
  /// 那一阵照样进，不然全屏里按「新建便签」开在看不见的地方）
  private func applyBehavior() {
    guard let panel else { return }
    let options = model.options
    let everywhere =
      !options.alwaysFanned || options.overFullScreen || model.state.openID != nil
    let behavior: NSWindow.CollectionBehavior =
      everywhere ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces]
    if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
  }

  // MARK: 焦点

  /// 点开便签（或「新建便签」）：面板当 key（不激活本 App；悬停打开的不当，makesKey 是 false），焦点进这条便签的正文。
  /// 正文框自己会拿（挂进窗口的那一刻、被点名时）；这里是兜底：晚一拍按编号去找——它的编辑区这时还没建出来。
  /// 用 perform(afterDelay:)（下一轮 run loop，SwiftUI 那时已经更新过；同 NotesWindow），不用裸 Task
  private func focusBody(makesKey: Bool = true) {
    guard let panel, model.state.openID != nil else { return }
    if makesKey, takesKeyboard, !panel.isKeyWindow { panel.makeKey() }
    focusRetries = 0
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(focusBodyNow), object: nil)
    perform(#selector(focusBodyNow), with: nil, afterDelay: 0, inModes: [.common])
  }

  /// 找到就放（已经在它身上就不动）；没找到再试 focusRetryDelays 那几次。面板放掉了、便签关了、操作菜单开着就停；
  /// 换了一条会重新来一遍（focusBody 把前一条排着的作废）
  @objc private func focusBodyNow() {
    guard let panel, let id = model.state.openID, model.menu == nil else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    if let editor = Self.editor(for: id, in: panel.contentView) {
      if panel.firstResponder !== editor { panel.makeFirstResponder(editor) }
    } else if focusRetries < Self.focusRetryDelays.count {
      focusRetries += 1
      perform(
        #selector(focusBodyNow), with: nil, afterDelay: Self.focusRetryDelays[focusRetries - 1],
        inModes: [.common])
    }
  }

  /// 视图树里**这条便签**的正文框（NoteBodyField 给它标了便签的编号）。换一条的那 0.1 秒里新旧两个正文框都在：
  /// 按类型找第一个会先碰到旧的那个——它淡完移走后焦点就掉到面板上、打不进字
  static func editor(for id: String, in view: NSView?) -> NoteTextView? {
    guard let view else { return nil }
    if let editor = view as? NoteTextView, editor.identifier?.rawValue == id { return editor }
    return view.subviews.lazy.compactMap { editor(for: id, in: $0) }.first
  }

  /// 操作菜单开着时焦点放到面板自己身上（↑↓ ↩ 走面板的 keyDown，不进正文）；关了还给正文
  private func menuChanged(_ open: Bool) {
    if open { panel?.makeFirstResponder(nil) } else { focusBodyNow() }
  }

  // MARK: 点别处

  /// 打开便签时装：点别处就收起（固定的不收）。global 管别的 App，local 管自家窗口；关掉时卸，成对
  private func installMonitors() {
    guard monitors.isEmpty else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.clickedOutside() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        let isOutside = Self.isOutside(
          event.window, own: [self.panel, self.pill?.panel],
          isSelectingRegion: OverlayPanel.isSelectingRegion(in: NSApp.windows))
        if isOutside { self.clickedOutside() }
      }
      return event
    }
    monitors = [global, local].compactMap { $0 }
  }

  private func removeMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  /// 自家窗口上的这一下算不算「点别处」：点那叠自己（面板、药丸）不算，点 Kitty 的任何一块浮层（OverlayPanel）不算，
  /// 截图框选中点遮罩也不算（便签是内容，留在冻结帧里、截完还开着，同 OverlayPanel）
  static func isOutside(_ window: NSWindow?, own: [NSWindow?], isSelectingRegion: Bool) -> Bool {
    if isSelectingRegion || window is OverlayPanel { return false }
    return !own.contains { $0 != nil && $0 === window }
  }

  /// 输入法正组着字（正文框、标题框的字段编辑器里有没上屏的拼音）：这时的「点别处」多半是用鼠标点候选词——
  /// 候选窗是别的进程的窗口，global 监听分不出来——不收，不然便签一收候选词就落空了。
  /// ponytail: 只认组字中。表情与符号面板（没有组字）点了照样会把没固定的便签收掉；要放过它得按窗口的归属认
  /// （CGWindowList 查点中的是谁的窗口），真碰上再做
  static func isComposing(_ responder: NSResponder?) -> Bool {
    (responder as? NSTextView)?.hasMarkedText() ?? false
  }

  private func clickedOutside() {
    if Self.isComposing(panel?.firstResponder) { return }
    model.send(.clickedOutside(pinned: model.current?.isPinned ?? false))
  }

  // MARK: 离开热区、没动静

  /// 热区（全局坐标）：标签列四周 20 pt，预览卡出着时连它
  var hotZone: CGRect { model.hotZone(in: frame) }

  /// 面板里那块跟鼠标的追踪区只挂在热区上，而且只在「扇着、等着收回」时挂：便签开着、「一直展开」时没有——
  /// 鼠标在便签那一大片上来回动不该一下下唤醒本进程
  private func updateTracking() {
    guard let panel else { return }
    let watching = model.state.phase == .fanned && !model.options.alwaysFanned
    panel.track(watching ? hotZone : .zero)
  }

  /// 扇出后开始看着：4 秒没动静收回；鼠标这时就不在热区里（用鼠标关掉便签回到那一列时）也照样确认一次再收。
  /// 「一直展开」不看
  private func watch() {
    idleTask?.cancel()
    idleTask = nil
    leaveTask?.cancel()
    leaveTask = nil
    guard !model.options.alwaysFanned else { return }
    lastActivity = .now
    idleTask = Task { [weak self] in
      while !Task.isCancelled, let wait = self?.idleWait() {
        try? await Task.sleep(for: wait)
      }
    }
    pointerMoved()
  }

  private func stopWatching() {
    idleTask?.cancel()
    idleTask = nil
    leaveTask?.cancel()
    leaveTask = nil
    skipsLeave = false
  }

  /// 离「没动静满 idleDelay」还差多久；到了就发 idle（正拖着标签时不算，重新数），返回 nil
  private func idleWait() -> Duration? {
    let left = Self.idleDelay - (ContinuousClock.now - lastActivity)
    guard left <= .zero else { return left }
    if model.state.isDragging {
      lastActivity = .now
      return Self.idleDelay
    }
    model.send(.idle)
    return nil
  }

  /// 鼠标动了（面板热区上的追踪区、药丸的进出、标签的悬停和点击都报到这里）：在热区里就算有动静；
  /// 出了热区，过 leaveDelay 确认还在外面才收（从标签挪到预览卡、手抖一下出去又回来都不收）。
  /// 面板已经没了（收着、放掉了；面板的视图被拆掉时也会回调到这里，见 releasePanel）就什么都不做——尤其不许再排出
  /// 「离开确认」之类的任务
  private func pointerMoved() {
    guard panel != nil else { return }
    updateTracking()
    guard model.state.phase == .fanned, !model.options.alwaysFanned else { return }
    if hotZone.contains(NSEvent.mouseLocation) {
      lastActivity = .now
      skipsLeave = false
      leaveTask?.cancel()
      leaveTask = nil
    } else if !skipsLeave, leaveTask == nil {
      leaveTask = Task { [weak self] in
        try? await Task.sleep(for: Self.leaveDelay)
        guard !Task.isCancelled, let self else { return }
        leaveTask = nil
        if !hotZone.contains(NSEvent.mouseLocation) { model.send(.left) }
      }
    }
  }
}
