// 屏幕边缘那叠的状态机（纯状态，单测 NoteDeckTests 逐条锁住；规矩在 mac-overlay-panel §12）。一块屏一份。
// 三种样子：静置（只有边上的药丸）→ 扇出（一列标签）→ 打开（某一条便签）；另记「+N」展没展开、是不是正拖着标签排序。
// - 静置 → 扇出：鼠标进药丸。按着 ⌥ 不扇出（那是要拖它）；这时不许扇出（截图框选、长截图、录屏选区和倒数、状态屏）也不扇出。
// - 扇出 → 静置：鼠标离开热区又确认了一次、4 秒没动静、Esc / ⌘W；拖着标签排序时不收。
// - 扇出 → 打开：点标签（悬停即打开时停够久）。打开着点另一张 = 换一条，点它自己那张 = 关（回到扇出）。
// - 打开 → 扇出（close）：用鼠标关的——关闭按钮、它自己的标签；归档、删除之后。
// - 打开 → 静置（dismiss）：用键盘关的——Esc、⌘W：人已经回去干活了，那一列也跟着收回，键盘当场还给原来的 App。
// - 打开 → 静置：点别处，而且这条没固定。打开的便签不按时间自己收。
// - 「+N」：扇出、打开时都能点，列出全部（打开着的便签留着）。
// - 新建一条：从哪种样子都直接打开它。
// - 被叫停（suspend）：扇出的收起；打开的要不要收由调用方说（截图 / 录屏框选时留着，它是内容；状态屏、没固定时的
//   截图翻译和长截图收）。别的屏的那叠要展开了（yield）：这块屏扇着的收起，打开的只收没固定的（固定的不收）。
// 「一直展开」（设置）：没有静置这一档，「收回」就是回到扇出那一列。
// 该做的事（建窗口、当 key、落盘、装卸鼠标监听、计时）不在这里：NoteDeck.effects 看前后两个状态定。

import Foundation

nonisolated struct NoteDeckState: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case rest
    case fanned
    /// 打开着的那条便签的编号
    case open(String)
  }

  enum Event: Equatable, Sendable {
    /// 鼠标进了药丸。optionDown：按着 ⌥；allowed：现在能不能扇出
    case pillEntered(optionDown: Bool, allowed: Bool)
    /// 鼠标离开热区，过一会儿确认了还在外面
    case left
    /// 4 秒没动静
    case idle
    /// 点了一张标签（或者在上面停够久了）
    case tab(String)
    /// 点了「+N」
    case showAll
    /// 用鼠标关便签（关闭按钮、它带着的那张标签）；归档、删除之后：回到那一列
    case close
    /// 用键盘关（Esc、⌘W）：便签连那一列一起收回
    case dismiss
    /// 点了别处。pinned：打开的这条是不是固定着
    case clickedOutside(pinned: Bool)
    /// 新建了一条，要在这叠里打开
    case created(String)
    case dragBegan, dragEnded
    /// 被叫停。closesOpen：打开着的便签也收
    case suspend(closesOpen: Bool)
    /// 别的屏的那叠要展开了。pinned：这块屏打开的这条是不是固定着（固定的不收）
    case yield(pinned: Bool)
  }

  private(set) var phase = Phase.rest
  /// 「+N」展开了：列出全部没归档的
  private(set) var showsAll = false
  /// 正拖着一张标签排序
  private(set) var isDragging = false
  /// 设置里的「一直展开」：改它由 setAlwaysFanned
  private(set) var alwaysFanned = false

  /// 打开着的便签
  var openID: String? {
    if case .open(let id) = phase { id } else { nil }
  }

  /// 「收回」之后的样子
  private var home: Phase { alwaysFanned ? .fanned : .rest }

  /// 展开着：比「收回」之后的样子多出来了（一直展开时静置的那一列不算，打开着便签才算）。空闲回收看它
  var isExpanded: Bool { phase != home }

  /// 开关「一直展开」：打开时静置的直接成了扇出；关掉时还扇着的不动，等鼠标离开 / 没动静时照常收
  mutating func setAlwaysFanned(_ always: Bool) {
    alwaysFanned = always
    if always, phase == .rest { phase = .fanned }
  }

  /// 来了一件事。返回状态变没变
  @discardableResult
  mutating func handle(_ event: Event) -> Bool {
    let old = self
    switch (event, phase) {
    case (.pillEntered(let optionDown, let allowed), .rest):
      if !optionDown, allowed { phase = .fanned }
    case (.left, .fanned), (.idle, .fanned):
      if !isDragging { collapse() }
    case (.tab(let id), .fanned):
      if !isDragging { phase = .open(id) }
    case (.tab(let id), .open(let current)):
      phase = id == current ? .fanned : .open(id)
    case (.showAll, .fanned), (.showAll, .open):
      showsAll = true
    case (.close, .open):
      phase = .fanned
    case (.dismiss, .open), (.dismiss, .fanned):
      collapse()
    case (.clickedOutside(let pinned), .open):
      if !pinned { collapse() }
    case (.created(let id), _):
      isDragging = false
      phase = .open(id)
    case (.dragBegan, .fanned):
      isDragging = true
    case (.dragEnded, _):
      isDragging = false
    case (.suspend, .fanned), (.suspend(closesOpen: true), .open), (.yield, .fanned),
      (.yield(pinned: false), .open):
      collapse()
    default:
      break
    }
    return self != old
  }

  private mutating func collapse() {
    phase = home
    showsAll = false
    isDragging = false
  }
}
