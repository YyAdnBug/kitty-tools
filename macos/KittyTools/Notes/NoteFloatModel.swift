// 浮动便签的界面读的状态（整个 App 一份；PLAN §10「便签」第 4 批，规矩在 mac-overlay-panel §12「浮动便签」）：
// 状态机 NoteFloatState（浮着的是哪条、是不是正被拖出来）、它带着的那张标签长什么样、按着把手挪窗口。
// 不碰窗口：状态变了报给 NoteFloat（onChange），它去建 / 放掉面板、定层级、当 key、落盘、记位置。
// 这条便签自己的那一半——操作菜单、按键、对它做的事、焦点、撤销栈、写入按编号落——在基类 NoteSheetModel 里，
// 和屏幕边缘那叠里打开的便签（NoteDeckModel）是同一套；这里只说浮着时的关法和把手：
// - 关（关闭钮、它带着的那张标签、Esc、⌘W、操作菜单的「收回边缘」）都是收回（tuck）。**固定着的也收**：固定管的是
//   层级和重启后回不回来，不拦 Esc / ⌘W（同那叠里打开的便签、同各浮层：mac-overlay-panel §2）。
// - 归档、删除之后是直接关（remove）：它不是回到边缘，是没了。
// - 「在全部便签里打开」不收：它是人留在屏幕上的东西，去全部便签窗口里看一眼不该把它收走（同一条便签开在两处，
//   正文靠仓库同步；那叠里的那条会收，是因为那叠本来点别处就收）。
// - 按着把手拖 = 挪窗口（跟着鼠标走，不做动画）；按在标签上没挪开就松手 = 点了一下 = 收回。

import AppKit
import Observation

@Observable final class NoteFloatModel: NoteSheetModel {
  private(set) var state = NoteFloatState()
  /// 它带着的那张标签多宽、字多大（跟那叠的大小档走）、在左边还是右边（跟那叠实际在哪条边走，不是偏好里的那条）：
  /// 从那叠里拖出来的那一下，浮动面板里画的和它在那叠里的一模一样。NoteFloat 设
  var metrics = NoteDeckMetrics(scale: 1)
  var tabOnLeading = true
  /// 屏幕边缘现在有没有那叠（总开关开着、有地方放）：操作菜单里那一项叫「收回边缘」还是「取消浮动」
  var edgeShown = true

  /// 状态变了（来的是哪件事、前后两个状态；NoteFloat 据此动窗口）
  @ObservationIgnored var onChange: (NoteFloatState.Event, NoteFloatState, NoteFloatState) -> Void =
    { _, _, _ in }
  /// 按着把手挪窗口：开始（按下的地方）、挪到哪了、松手在哪（都是全局坐标）
  @ObservationIgnored var onMoveBegan: (CGPoint) -> Void = { _ in }
  @ObservationIgnored var onMove: (CGPoint) -> Void = { _ in }
  @ObservationIgnored var onMoveEnded: (CGPoint) -> Void = { _ in }
  /// 正按着把手：按下的地方、挪没挪开
  @ObservationIgnored private var grip: (start: CGPoint, isMoving: Bool)?

  // MARK: 状态

  func send(_ event: NoteFloatState.Event) {
    let old = state
    guard state.handle(event) else { return }
    if old.noteID != state.noteID {
      // 按着把手时被收回 / 换了一张 / 没了：视图拆了 SwiftUI 不报 onEnded，旧的起点不清的话，下一张的第一下按住
      // 就被当成挪了很远（窗口跳一截、点标签不收回）
      grip = nil
      sheetChanged(to: state.noteID)
    }
    onChange(event, old, state)
  }

  /// 仓库里的便签变了：浮着的那条被别处删了、归档了就关掉
  func reconcile() {
    if state.noteID != nil, current == nil { send(.remove) }
  }

  // MARK: 浮着的便签（NoteSheetModel 问的）

  override var noteID: String? { state.noteID }
  override var isFloating: Bool { true }
  override var hasEdge: Bool { edgeShown }
  /// 标签在朝屏幕里面的那一侧：在左（leading）= 那叠在右边缘
  override var tuckEdge: NoteDeckOptions.Edge { tabOnLeading ? .right : .left }
  override func close() { send(.tuck) }
  override func dismiss() { send(.tuck) }
  override func retire() { send(.remove) }

  /// 操作菜单的「收回边缘」
  override func toggleFloating() {
    closeMenu()
    send(.tuck)
  }

  /// 「在全部便签里打开」：浮着的留着
  override func openInWindow() {
    if let note = current { showInWindow(note.id) }
  }

  /// 按着把手拖：挪开了（过了 dragSlop）才开始挪窗口，之后每一下都跟着鼠标走。正被从那叠里拖出来的那一阵不归这里
  /// （那时的手势在那叠的面板里，NoteDeckModel 在带着它走）
  override func gripChanged(at pointer: CGPoint) {
    guard state.noteID != nil, !state.isDragging else { return }
    guard let held = grip else {
      // 第一下：按下的地方
      grip = (pointer, false)
      return
    }
    if !held.isMoving {
      guard NoteFloatLayout.moved(from: held.start, to: pointer) else { return }
      grip?.isMoving = true
      onMoveBegan(held.start)
    }
    onMove(pointer)
  }

  /// 松手：挪过的落在这里；按在标签上、没挪开的是点了一下（收回）
  override func gripEnded(_ part: Grip, at pointer: CGPoint) {
    let held = grip
    grip = nil
    if held?.isMoving == true {
      onMoveEnded(pointer)
    } else if part == .tab, !NoteFloatLayout.moved(from: held?.start ?? pointer, to: pointer) {
      close()
    }
  }
}
