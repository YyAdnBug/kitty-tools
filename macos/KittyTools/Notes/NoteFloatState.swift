// 浮动便签的状态机（纯状态，单测 NoteFloatTests 逐条锁住；规矩在 mac-overlay-panel §12「浮动便签」）。
// 整个 App 一份：**一次只浮一张**（PLAN §10「便签」拍板 C②）。
// - 没有 → 拖着：在那叠里按着打开的便签的把手往外拖，过了阈值（detach）。浮动面板这时已经跟着鼠标走，还没落下。
// - 拖着 → 浮着：松手（drop）。
// - 没有 → 浮着：不靠拖——操作菜单、全部便签窗口、重启后恢复（float）。
// - 已经浮着一张时再浮另一张（detach / float 别的编号）：换成新的那张，前一张收回去。
// - 浮着 → 没有：收回（tuck：关闭钮、它带着的那张标签、Esc、⌘W、菜单里的「收回边缘」）；这条便签不在了
//   （remove：删除、归档、进了最近删除）。
// 拖着的时候不接 float、tuck（鼠标还按着：这两样都要等它落下）。
// 该做的事（建窗口、当 key、落盘、记位置）不在这里：NoteFloat.effects 看来的是哪件事和前后两个状态定。

import Foundation

nonisolated struct NoteFloatState: Equatable, Sendable {
  enum Event: Equatable, Sendable {
    /// 从那叠里拖出来，过了阈值（鼠标还按着）
    case detach(String)
    /// 不靠拖浮出来：操作菜单、全部便签窗口、重启后恢复
    case float(String)
    /// 松手，落下
    case drop
    /// 收回
    case tuck
    /// 这条便签不在了：直接关
    case remove
  }

  /// 浮着的那条便签（nil = 没有）
  private(set) var noteID: String?
  /// 正被拖出来、还没松手
  private(set) var isDragging = false

  /// 来了一件事。返回状态变没变
  @discardableResult
  mutating func handle(_ event: Event) -> Bool {
    let old = self
    switch event {
    case .detach(let id):
      noteID = id
      isDragging = true
    case .float(let id):
      if !isDragging { noteID = id }
    case .drop:
      isDragging = false
    case .tuck:
      if !isDragging { noteID = nil }
    case .remove:
      noteID = nil
      isDragging = false
    }
    return self != old
  }
}
