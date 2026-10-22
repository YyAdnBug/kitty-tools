// 浮动便签（PLAN §10「便签」拍板 B⑤ C②，第 4 批；规矩在 mac-overlay-panel §12「浮动便签」）：从屏幕边缘那叠里拖出来、
// 或者从操作菜单「浮在屏幕上」，留在屏幕上的一张便签。**一个实例管一张**：同时浮几张（2026-10-22 便签未来计划 C）是
// NoteFloats 建几个它、管上限和「最久没碰」、记位置；这里管这一张的窗口；界面读的状态在 NoteFloatModel，
// 它的状态一变，这里按来的是哪件事和前后两个状态算出该做哪几件（effects，纯函数、有单测）再去做。
// - **拖出来时两块面板的交接**：手势是在那叠的面板里的视图上开始的，过了阈值，NoteDeck 把这条便签在那叠里的位置和
//   正文里的选区交过来（detach），这里当场建一块面板、摆在同一个地方（带标签那一侧的上角不动，纸不跳）、盖在那叠
//   上面，之后每一下跟着鼠标摆（drag）；那叠里的那一份留着不拆、只是看不见，直到松手（drop）。松手才夹进
//   可见区、当 key、把焦点和光标放回正文——接着就能打字。
// - **一律浮动层级**（NoteFloatPanel，手测反馈第 6 批）：「浮在屏幕上」就一直在别的 App 的窗口上面；固定只管重启后
//   回不回到原处。
// - **不激活、key**：永远不调 NSApp.activate。落下、从菜单浮出来、点了那叠里它的标签才 makeKey；重启后恢复的不当 key。
//   **收回 / 关掉要当场把键盘还给原来的 App**：面板自己立刻 orderOut，原位留一张图当替身去做退场的动画（leave；
//   同 OverlayPanel.dismiss 的路数——真窗口自己淡的话，淡的那一会儿它还当着 key，人回去打的字被它吞掉）。
// - **放掉面板不许直接把属性置空**（第 3 批的真机崩溃，mac-overlay-panel §12）：照 NoteDeck.releasePanel 的写法——
//   先拿到局部变量、把属性置空，再收走、拆视图（releasePanel）。
// - **标签在哪一侧、往哪边挪、收回往哪边滑，看这一叠实际在哪条边**，不看偏好里的边：两块屏相接时那叠会换到另一侧
//   （NoteDeckLayout.placements；笔记本做主屏、外接屏放右边，那叠就在左边）。从那叠里出来的带着那一叠的边（Origin），
//   别的按它所在那块屏的那叠（homeEdge），屏幕边缘没有那叠才按偏好。
// - 记下的大小拿出来时夹进它要出现的那块屏的可见区（大外接屏上拉大的回到笔记本上不伸出屏幕）。
// - 落下时截图框选正开着（拖到一半按了截图）：不抢遮罩的 key，只放第一响应者。
// - 落盘：浮出来之前、换一张、收回、便签不在了、失去 key、长截图让开，都先 NoteStore.flush()。
// - **记着的两样**（都是这台电脑自己的状态，不注册默认值）：拉过的大小（下次浮出来还是这么大，这里记）；固定着的
//   在哪——这里只报（place、onPersist），几张一起由 NoteFloats 记、重启后让它们回来（restore(_:frame:)）。
// - 截图 / 录屏里它是内容，同钉图：冻结帧里有、能悬停选中（整扇窗口），录屏白名单里有（ScreenCapture）；长截图时
//   压在选区上的先收走、结束放回（suspend(covering:) / resume，同钉图：它会吞掉滚轮）。没有「点别处就收」这回事。
// 几块屏、设置、仓库的变化由 NoteEdge 转过来（update / storeChanged）：不另挂一份通知。

import AppKit
import SwiftUI

final class NoteFloat: NSObject, NSWindowDelegate {
  /// 状态变了之后要做的事（effects 算出来的）
  nonisolated struct Effects: OptionSet, Sendable {
    let rawValue: Int
    /// 攒着的改动落盘（前一张要走了）
    static let flush = Effects(rawValue: 1 << 0)
    /// 前一张收回边缘（面板当场收走，替身朝那条边滑着淡掉）
    static let tuckOld = Effects(rawValue: 1 << 1)
    /// 前一张直接淡掉（这条便签不在了：它不是回到边缘）
    static let dropOld = Effects(rawValue: 1 << 2)
    /// 建面板、露出来（不当 key）
    static let show = Effects(rawValue: 1 << 3)
    /// 落下：当 key、焦点进正文（拖出来的还要夹进可见区）
    static let land = Effects(rawValue: 1 << 4)
  }

  /// 来了 event、状态从 old 变成 new，该做哪几件事（纯函数）
  nonisolated static func effects(
    _ event: NoteFloatState.Event, from old: NoteFloatState, to new: NoteFloatState
  ) -> Effects {
    var effects: Effects = []
    let changed = old.noteID != new.noteID
    if changed, old.noteID != nil {
      effects.insert(.flush)
      effects.insert(event == .remove ? .dropOld : .tuckOld)
    }
    if changed, new.noteID != nil { effects.insert(.show) }
    if new.noteID != nil, !new.isDragging, changed || old.isDragging { effects.insert(.land) }
    return effects
  }

  /// 从那叠里出来的：它在那叠里的位置（全局坐标）、那一叠实际在哪条边（不一定是偏好里的那条，见文件头）、正文里的
  /// 选区（浮出去之后光标还在那儿）
  struct Origin {
    var sheet: CGRect
    var edge = NoteDeckOptions.Edge.right
    var selection: NSRange?
  }

  /// 下一张露出来时用的：摆在哪、它从哪条边来（标签在哪一侧、收回往哪边）、从哪滑过来（不靠拖、从那叠里出来的才有）、
  /// 正文里的选区、落下时当不当 key
  private struct Arrival {
    var frame: CGRect
    var edge: NoteDeckOptions.Edge
    var slidesFrom: CGRect?
    var selection: NSRange?
    var takesKey = true
  }

  /// 替身四周给阴影留多少
  private static let shadowMargin: CGFloat = 40
  /// 落下时夹进可见区、不靠拖浮出来时滑过去用多久（窗口的帧动画只认贝塞尔：settle 0.24 / glide 0.26 的近似，
  /// 同 OverlayPanel.move）
  private static let settleDuration = 0.24
  private static let glideDuration = 0.26

  let model: NoteFloatModel
  /// 没有浮着的是 nil
  private(set) var panel: NoteFloatPanel?
  /// 现在接着的显示器（单测给一块离所有屏幕很远的）
  var screens: () -> [NoteDeckScreen] = { NoteDeckScreen.attached() }
  /// 屏幕边缘的那叠在哪条边（给的是浮动便签的位置：它所在那块屏的那叠，那块屏没放就是放了的第一块）。没有原处的
  /// 那一张（全部便签窗口、重启后恢复）按它定标签在哪一侧、收回往哪边；nil = 屏幕边缘没有那叠
  var homeEdge: (CGRect) -> NoteDeckOptions.Edge? = { _ in nil }
  /// 浮着的换了一条 / 没有了 / 落下了（NoteEdge 据此告诉各块屏的那叠）
  var onChange: () -> Void = {}
  /// 面板放掉了（收回、关掉、换成另一张）：NoteEdge 转给 AppDelegate 排空闲回收
  var onHide: () -> Void = {}
  /// 碰了它一下（当上 key、被叫到前面、按着把手挪）：NoteFloats 据此认「最久没碰」的是哪张
  var onTouch: () -> Void = {}
  /// 固定着的位置该重记了（NoteFloats 把几张一起写进偏好）
  var onPersist: () -> Void = {}
  /// 收回 / 关掉时面板拿着键盘（NoteFloats 看 AppKit 是不是把 key 交给了另一张浮动便签）
  var onKeyReleased: () -> Void = {}

  private let defaults: UserDefaults
  /// 落下时面板当不当 key。只有单测传 false：屏外的面板一当 key，用户正在用的那个 App 就丢了键盘
  private let takesKeyboard: Bool
  /// 做不做出场 / 落下 / 退场的动画（单测传 false：帧动画没放完时窗口的 frame 是中间值）
  private let animates: Bool
  private var options = NoteDeckOptions()
  private var arrival: Arrival?
  /// 这一张落下时当不当 key、正文里的选区还没放上去的（编辑区建出来才放得上）
  private var landsWithKey = true
  private var caret: NSRange?
  /// 面板该在的位置（帧动画没放完时 panel.frame 是中间值，记位置、算落点都按它）
  private var rest = CGRect.zero
  /// 跟着鼠标走时，鼠标离面板左下角多远
  private var grab = CGSize.zero
  /// 松手的地方（落在哪块屏按它算）
  private var dropPoint: CGPoint?
  /// 长截图期间让开着（收走了，结束放回来）
  private var isCovered = false

  private var isAnimated: Bool { animates && !Style.reduceMotion }
  private var store: NoteStore { model.store }

  init(
    store: NoteStore, defaults: UserDefaults = .standard, island: Island?,
    takesKeyboard: Bool = true, animates: Bool = true
  ) {
    model = NoteFloatModel(store: store)
    self.defaults = defaults
    self.takesKeyboard = takesKeyboard
    self.animates = animates
    super.init()
    model.island = island
    // 都弱引用：面板放掉之后，界面那边还可能有晚到的一下
    model.onChange = { [weak self] event, old, new in
      self?.stateChanged(event, from: old, to: new)
    }
    model.focusBody = { [weak self] in self?.focusBody() }
    model.onMenu = { [weak self] open in self?.menuChanged(open) }
    model.withEditor = { [weak self] body in
      guard let self, let id = model.state.noteID,
        let editor = NoteDeck.editor(for: id, in: panel?.contentView)
      else { return }
      body(editor)
    }
    model.onMoveBegan = { [weak self] in self?.beginMove(from: $0) }
    model.onMove = { [weak self] in self?.follow($0) }
    model.onMoveEnded = { [weak self] in self?.endMove(at: $0) }
  }

  // MARK: 浮出来、收回去

  /// 从那叠里拖出来，过了阈值（鼠标还按着）：在它原来的地方建一块面板，之后跟着鼠标走（drag），松手落下（drop）
  func detach(_ id: String, from origin: Origin, at pointer: CGPoint) {
    guard NoteFloatLayout.floats(store.note(id)), !model.state.isDragging else { return }
    store.flush()
    // 带标签那一侧按这一叠实际在的边：偏好是右、那叠被换到左边时标签在右，拖出来那一刻纸不跳
    let frame = NoteFloatLayout.lifted(
      sheet: origin.sheet, size: size(fallback: origin.sheet.size, near: origin.sheet),
      tabOnLeading: origin.edge == .right)
    grab = CGSize(width: pointer.x - frame.minX, height: pointer.y - frame.minY)
    arrival = Arrival(frame: frame, edge: origin.edge, selection: origin.selection)
    model.send(.detach(id))
  }

  /// 拖着：面板跟着鼠标走（不做动画）
  func drag(to pointer: CGPoint) {
    guard model.state.isDragging else { return }
    follow(pointer)
  }

  /// 松手：留在这里，夹进鼠标所在那块屏的可见区，拿到键盘
  func drop(at pointer: CGPoint) {
    guard model.state.isDragging else { return }
    follow(pointer)
    dropPoint = pointer
    model.send(.drop)
  }

  /// 不靠拖浮出来（操作菜单的「浮在屏幕上」、全部便签窗口）：origin 是它在那叠里的位置（从那叠里出来的才有）。
  /// 已经浮着的就是它：叫到前面（几张一起由 NoteFloats 管：别的编号不会交给浮着的这一张）。
  /// avoiding：已经浮着的那几张在哪——和它们错开（NoteFloatLayout.cascaded）
  func present(
    _ id: String, from origin: Origin? = nil, mouse: CGPoint = NSEvent.mouseLocation,
    avoiding others: [CGRect] = []
  ) {
    guard NoteFloatLayout.floats(store.note(id)), !model.state.isDragging else { return }
    guard model.state.noteID != id else { return focus() }
    store.flush()
    // 没有原处的：大小按鼠标所在那块屏夹，标签朝它落下那块屏的那叠
    let size = size(
      fallback: origin?.sheet.size ?? options.noteSize.size, near: origin?.sheet ?? .zero,
      pointer: origin == nil ? mouse : nil)
    let attached = screens()
    var frame = NoteFloatLayout.placed(
      size: size, sheet: origin?.sheet, edge: origin?.edge ?? options.edge, mouse: mouse,
      in: attached)
    if !others.isEmpty, let home = NoteFloatLayout.home(of: frame, in: attached) {
      frame = NoteFloatLayout.cascaded(frame, avoiding: others, in: attached[home].visibleFrame)
    }
    arrival = Arrival(
      frame: frame, edge: origin?.edge ?? edge(near: frame),
      slidesFrom: origin.map {
        NoteFloatLayout.lifted(sheet: $0.sheet, size: frame.size, tabOnLeading: $0.edge == .right)
      }, selection: origin?.selection)
    model.send(.float(id))
    Island.announce("已浮在屏幕上")
  }

  /// 全部便签窗口的「浮在屏幕上」/「收回边缘」：浮着的就是它就收回，不然让它浮出来
  func toggle(_ id: String) {
    if model.state.noteID == id { model.close() } else { present(id) }
  }

  /// 把浮着的那张叫到前面、给它键盘（点了那叠里它的标签、「新建便签」落在它身上）
  func focus() {
    guard let panel, !model.state.isDragging else { return }
    resume()
    panel.orderFrontRegardless()
    model.requestFocus()
    onTouch()
  }

  /// 重启后：固定着浮在屏幕上的这一张回到 frame（不当 key；NoteFloats 认过这条还在、还固定着，位置夹进了现在的屏幕）
  func restore(_ id: String, frame: CGRect) {
    guard model.state.noteID == nil else { return }
    arrival = Arrival(frame: frame, edge: edge(near: frame), takesKey: false)
    model.send(.float(id))
  }

  /// 记下的大小（拉过才有；没拉过用 fallback），不大过它要出现的那块屏的可见区（哪块屏：frame / pointer 按
  /// NoteFloatLayout.home 认）
  private func size(fallback: CGSize, near frame: CGRect, pointer: CGPoint? = nil) -> CGSize {
    let screens = screens()
    let limit = NoteFloatLayout.home(of: frame, pointer: pointer, in: screens).map {
      screens[$0].visibleFrame.size
    }
    return NoteFloatLayout.size(
      stored: defaults.string(forKey: Prefs.notesFloatSize), fallback: fallback, limit: limit)
  }

  /// 没有原处的那一张从哪条边来：它所在那块屏的那叠在的边；屏幕边缘没有那叠就按偏好
  private func edge(near frame: CGRect) -> NoteDeckOptions.Edge {
    homeEdge(frame) ?? options.edge
  }

  /// 标签在哪一侧（收回往哪边、菜单里「收回边缘」的符号朝哪都跟着它）：朝这条边。要在面板建出来之前设——拖出来那一刻
  /// 浮动面板里画的要和它在那叠里的一模一样
  private func face(_ edge: NoteDeckOptions.Edge) {
    let onLeading = edge == .right
    if model.tabOnLeading != onLeading { model.tabOnLeading = onLeading }
  }

  // MARK: 跟着变（NoteEdge 转过来的）

  /// 设置变了、屏幕变了、那叠有了 / 没了：它带着的标签跟那叠的大小档和在哪条边（它所在那块屏的那叠实际在的那条）走；
  /// 位置夹回可见区
  func update(options: NoteDeckOptions, edgeShown: Bool) {
    self.options = options
    let metrics = NoteDeckMetrics(scale: options.size.scale)
    if model.metrics != metrics { model.metrics = metrics }
    if model.edgeShown != edgeShown { model.edgeShown = edgeShown }
    guard panel != nil, !model.state.isDragging else { return }
    face(edge(near: rest))
    let settled = NoteFloatLayout.settled(rest, in: screens())
    if settled != rest {
      setFrame(settled)
      onPersist()
    }
  }

  /// 仓库里的便签变了：浮着的那条没了就关；固定变了，「记不记位置」跟着变
  func storeChanged() {
    model.reconcile()
    onPersist()
  }

  /// 长截图开始：压在选区上的先收走——它会吞掉滚轮和自动滚动的合成滚轮（同钉图，体检 B40）；长截图滤掉了本 App，
  /// 长图里本来就没有它。结束（拷贝、存储、取消、出错）时 resume 放回来
  func suspend(covering region: CGRect) {
    guard let panel, panel.isVisible, panel.frame.intersects(region) else { return }
    store.flush()
    isCovered = true
    panel.orderOut(nil)
  }

  func resume() {
    guard isCovered else { return }
    isCovered = false
    panel?.orderFrontRegardless()
  }

  // MARK: 状态变了

  private func stateChanged(
    _ event: NoteFloatState.Event, from old: NoteFloatState, to new: NoteFloatState
  ) {
    let effects = Self.effects(event, from: old, to: new)
    if effects.contains(.flush) { store.flush() }
    if effects.contains(.tuckOld) { releasePanel(slides: true) }
    if effects.contains(.dropOld) { releasePanel(slides: false) }
    if effects.contains(.show) { show() }
    if effects.contains(.land) { land(settles: old.isDragging) }
    if event == .tuck { Island.announce(model.edgeShown ? "已收回边缘" : "已取消浮动") }
    onPersist()
    onChange()
  }

  /// 建面板、露出来（不当 key、不激活本 App）。拖出来的当场出现在原处；不靠拖的淡入，从那叠里出来的同时从原处
  /// 滑到位（减弱动态效果时直接出现）
  private func show() {
    guard let arrival, model.state.noteID != nil else { return }
    self.arrival = nil
    // 在前一张放掉之后才转：前一张退场的替身画的还是它自己那一侧
    face(arrival.edge)
    landsWithKey = arrival.takesKey
    caret = arrival.selection
    let eases = isAnimated && !model.state.isDragging
    let panel = makePanel(frame: eases ? arrival.slidesFrom ?? arrival.frame : arrival.frame)
    self.panel = panel
    rest = panel.frame
    isCovered = false
    // 先排一遍：编辑区这时建出来（它挂进窗口的那一刻自己拿第一响应者），纸的形状也有了（阴影按它算）
    panel.contentView?.layoutSubtreeIfNeeded()
    if eases { panel.alphaValue = 0 }
    panel.orderFrontRegardless()
    // 透明窗口的系统阴影按画出来的纸算：这一下纸可能还没画上去，下一轮再算一次
    panel.invalidateShadow()
    perform(#selector(refreshShadow), with: nil, afterDelay: 0, inModes: [.common])
    guard eases else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
    setFrame(arrival.frame, duration: Self.glideDuration)
  }

  @objc private func refreshShadow() { panel?.invalidateShadow() }

  /// 落下：拖出来的夹进松手那块屏的可见区；当 key、焦点进正文（重启后恢复的不当 key）
  private func land(settles: Bool) {
    guard panel != nil else { return }
    if settles { settle(at: dropPoint) }
    dropPoint = nil
    if Self.landsWithKey(landsWithKey, windows: NSApp.windows) { focusBody() } else { focusNow() }
  }

  /// 落下时当不当 key：这一张要（重启后恢复的不要），而且没在截图框选——拖到一半按了截图、遮罩出来后才松手时，遮罩
  /// 拿着 key：抢过来的话 Esc 收回的是便签、遮罩还在。不当 key 时只放第一响应者（截完遮罩把 key 还给截图前的那扇窗口）
  static func landsWithKey(_ wanted: Bool, windows: [NSWindow]) -> Bool {
    wanted && !OverlayPanel.isSelectingRegion(in: windows)
  }

  /// 夹进可见区（pointer：松手的地方，落在哪块屏按它算）。要挪才做动画；本来就在里面的一步到位
  private func settle(at pointer: CGPoint?) {
    let target = NoteFloatLayout.settled(rest, pointer: pointer, in: screens())
    setFrame(target, duration: target == rest ? 0 : Self.settleDuration)
  }

  private func makePanel(frame: CGRect) -> NoteFloatPanel {
    let panel = NoteFloatPanel(frame: frame, model: model)
    panel.delegate = self
    panel.keyEquivalentHandler = { [weak model] in model?.handleKeyEquivalent($0) ?? false }
    panel.keyDownHandler = { [weak model] in model?.handleMenuKey($0) ?? false }
    panel.onCancel = { [weak model] in model?.cancel() }
    // 失去 key（切到别的 App、点了别的窗口）：攒着的改动先落下去
    panel.onResignKey = { [weak model] in model?.store.flush() }
    return panel
  }

  /// 放掉面板（收回、便签不在了、换成另一张）。**不能直接写 `panel = nil`**（第 3 批的真机崩溃，见
  /// NoteDeck.releasePanel）：先拿到局部变量、把属性置空（局部变量还拿着，这一下不释放），再收走、把它的视图拆掉
  /// （视图拆掉时回调进来读 panel，属性已经是 nil、没有进行中的写入），函数结束局部变量才放手。
  /// 面板当场 orderOut：键盘马上回到原来的 App；退场的动画由替身去做（leave）
  private func releasePanel(slides: Bool) {
    guard let old = panel else { return }
    panel = nil
    isCovered = false
    caret = nil
    grab = .zero
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    let hadKey = old.isKeyWindow
    // 朝它来的那条边滑（同它的标签在哪一侧）；屏幕边缘没有那叠时没有边可回
    if isAnimated, old.isVisible, old.alphaValue > 0 {
      leave(old, toward: slides && model.edgeShown ? model.tuckEdge : nil)
    }
    old.delegate = nil
    old.orderOut(nil)
    old.contentView = nil
    onHide()
    if hadKey { onKeyReleased() }
  }

  /// 退场的替身（同 OverlayPanel.dismiss 的路数，mac-overlay-panel §1）：原位留一张这一刻的图，盖在面板上面——
  /// 朝那条边滑着淡掉（retract）；没有边可回（edge 是 nil：屏幕边缘没有那叠，或者这条便签不在了）只淡（fadeOut）。
  /// 图画在一块比便签大一圈的透明窗口里的图层上：窗口不动、不改大小，动的只是图层的位置和透明度（真的弹簧曲线；
  /// 窗口的帧动画只认贝塞尔）。阴影是图层自己的（替身的窗口没有系统阴影：它跟不上在动的图层）
  private func leave(_ panel: NoteFloatPanel, toward edge: NoteDeckOptions.Edge?) {
    guard let view = panel.contentView else { return }
    // 这一刻的内容按 OverlayPanel.snapshots 分张画：挂着合成滤镜的图层（操作菜单开着时毛玻璃上的次要字、图标）另画
    // 一张、在替身里挂回同一个滤镜，同 OverlayPanel.fadeOutStandIn
    let images = OverlayPanel.snapshots(of: view)
    guard !images.isEmpty else { return }
    let slide = NoteFloatLayout.tuckOffset(toward: edge)
    let sheet = panel.frame
    let frame = sheet.union(sheet.offsetBy(dx: slide, dy: 0))
      .insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin)
    let standIn = PanelStandIn(
      frame: frame, level: panel.level, behavior: panel.collectionBehavior, hasShadow: false)
    let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
    root.wantsLayer = true
    let paper = CALayer()
    paper.frame = sheet.offsetBy(dx: -frame.minX, dy: -frame.minY)
    for (image, filter) in images {
      let layer = CALayer()
      layer.frame = paper.bounds
      layer.contents = image
      layer.compositingFilter = filter
      paper.addSublayer(layer)
    }
    // 近似系统窗口阴影（被替下来的真窗口用的是它）：black 0.25、模糊 18、向下 8，模糊按仓库的换算——CALayer 的
    // shadowRadius 取一半（同 Style.HUD.applyShadow）。必须给 shadowPath
    paper.shadowPath = CGPath(
      roundedRect: paper.bounds, cornerWidth: Style.Radius.card, cornerHeight: Style.Radius.card,
      transform: nil)
    paper.shadowColor = NSColor.black.cgColor
    paper.shadowOpacity = 0.25
    paper.shadowRadius = 9
    paper.shadowOffset = CGSize(width: 0, height: -8)
    root.layer?.addSublayer(paper)
    standIn.contentView = root
    standIn.order(.above, relativeTo: panel.windowNumber)

    let fade: CABasicAnimation
    var move: CABasicAnimation?
    if slide != 0,
      let spring = Style.Motion.retract.caAnimation(keyPath: "opacity", reduced: false)
        as? CABasicAnimation,
      let travel = Style.Motion.retract.caAnimation(keyPath: "position.x", reduced: false)
        as? CABasicAnimation
    {
      fade = spring
      travel.fromValue = paper.position.x
      travel.toValue = paper.position.x + slide
      move = travel
    } else {
      fade = CABasicAnimation(keyPath: "opacity")
      fade.duration = Style.fadeOut
      fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
    }
    fade.fromValue = 1
    fade.toValue = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated { standIn.orderOut(nil) }
    }
    // 模型值直接设成终点，动画从现在的样子走过去
    paper.opacity = 0
    paper.add(fade, forKey: "fade")
    if let move {
      paper.position.x += slide
      paper.add(move, forKey: "tuck")
    }
    CATransaction.commit()
  }

  /// 它该在的位置（帧动画没放完时 panel.frame 是中间值）；没有面板是 nil（NoteFloats 错开新的一张时看）
  var restingFrame: CGRect? { panel == nil ? nil : rest }

  /// 这一张现在该记在哪（固定着、浮着、落下了才有；NoteFloatLayout.place 定）：NoteFloats 几张一起写进偏好
  var place: NoteFloatLayout.Place? {
    NoteFloatLayout.place(
      id: panel == nil ? nil : model.state.noteID, isDragging: model.state.isDragging,
      note: model.current, frame: rest)
  }

  /// 把面板摆到 frame，并记成它该在的位置。不做动画（duration 0）也走零时长的 animator：直接 setFrame 盖不掉正在跑的
  /// 帧动画，动画结束会把旧目标写回来（同 OverlayPanel.setContentHeight）
  private func setFrame(_ frame: CGRect, duration: Double = 0) {
    rest = frame
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = isAnimated ? duration : 0
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
      panel.animator().setFrame(frame, display: true)
    } completionHandler: { [weak panel] in
      MainActor.assumeIsolated { panel?.invalidateShadow() }
    }
  }

  // MARK: 跟着鼠标走

  /// 按着把手开始挪：到最前面（同一层级里那叠扇出的那一列、别的 App 的浮动窗口可能盖着一部分），记下鼠标离左下角多远。还在跑的帧动画先停在原地
  private func beginMove(from start: CGPoint) {
    guard let panel else { return }
    onTouch()
    setFrame(panel.frame)
    panel.orderFrontRegardless()
    grab = CGSize(width: start.x - rest.minX, height: start.y - rest.minY)
  }

  /// 跟着鼠标摆（拖出来的那一阵、按着把手挪的时候；不做动画）
  private func follow(_ pointer: CGPoint) {
    guard let panel else { return }
    rest.origin = NoteFloatLayout.origin(grab: grab, pointer: pointer)
    panel.setFrameOrigin(rest.origin)
  }

  /// 挪完松手：夹进松手那块屏的可见区，位置记下来（固定着的）
  private func endMove(at pointer: CGPoint) {
    follow(pointer)
    settle(at: pointer)
    onPersist()
  }

  // MARK: 焦点

  /// 面板当 key（不激活本 App），焦点进这条便签的正文。正文框自己会拿（挂进窗口的那一刻、被点名时）；这里兜底：
  /// 当场找一次，下一轮（SwiftUI 那时更新过了）再找一次
  private func focusBody() {
    guard let panel, model.state.noteID != nil else { return }
    if takesKeyboard, !panel.isKeyWindow { panel.makeKey() }
    focusNow()
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(focusNow), object: nil)
    perform(#selector(focusNow), with: nil, afterDelay: 0, inModes: [.common])
  }

  /// 找到就放（已经在它身上就不动），从那叠里带过来的选区也这时放上去。面板放掉了、操作菜单开着就不做
  @objc private func focusNow() {
    guard let panel, let id = model.state.noteID, model.menu == nil else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    guard let editor = NoteDeck.editor(for: id, in: panel.contentView) else { return }
    if panel.firstResponder !== editor { panel.makeFirstResponder(editor) }
    guard let caret else { return }
    self.caret = nil
    let length = (editor.string as NSString).length
    let location = min(caret.location, length)
    let selection = NSRange(location: location, length: min(caret.length, length - location))
    editor.setSelectedRange(selection)
    editor.scrollRangeToVisible(selection)
  }

  /// 操作菜单开着时焦点放到面板自己身上（↑↓ ↩ 走面板的 keyDown，不进正文）；关了还给正文
  private func menuChanged(_ open: Bool) {
    if open { panel?.makeFirstResponder(nil) } else { focusNow() }
  }

  // MARK: 窗口的委托

  /// 点了它当上 key：算碰了一下。AppKit 自己把 key 交过来的（收回另一张之后）不算；落下、被叫到前面、按把手挪各自
  /// 明说 onTouch
  func windowDidBecomeKey(_ notification: Notification) {
    if let event = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(event.type) {
      onTouch()
    }
  }

  func windowDidResize(_ notification: Notification) {
    guard let panel else { return }
    // 透明窗口的系统阴影按纸的形状算：大小变了要重算
    panel.invalidateShadow()
    if panel.inLiveResize { rest = panel.frame }
  }

  /// 拉完：夹回可见区（拉过了屏幕边、程序坞），大小记下来（下次浮出来还是这么大），固定着的连位置一起记
  func windowDidEndLiveResize(_ notification: Notification) {
    guard let panel else { return }
    setFrame(NoteFloatLayout.settled(panel.frame, in: screens()))
    defaults.set(NSStringFromSize(rest.size), forKey: Prefs.notesFloatSize)
    onPersist()
  }
}
