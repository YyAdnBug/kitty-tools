// 刘海岛的「那一张」和键盘（U9、第五轮体检 A2；H1 从 Island.swift 拆出）：打开 / 收起那一张，临时当 key 时的按键，键盘交给提示上的按钮、到点还回去。

import AppKit
import SwiftUI

extension Island {
  /// 打开 / 收起那一张（快捷键「打开刘海岛」、点刘海）。岛上正有提示时换成那一张（那条已经记在列表里）。
  /// byKeyboard：快捷键叫出的——临时当 key，Esc / ←→ / ↩ 能用，到点自己收（U9）；岛上正挂着带按钮的提示 / 卡片时
  /// 先把键盘交给它的按钮（focusButtons），已经交给它了再按一次才换成那一张（第五轮体检 A2）
  func toggleBoard(byKeyboard: Bool = false) {
    if isBoardOpen { return dismiss() }
    if byKeyboard, !holdsKeyboard, focusButtons() { return }
    openBoard(byKeyboard: byKeyboard)
  }

  /// 键盘交给岛上那条提示 / 那张卡片的按钮（第五轮体检 A2；HIG：每个操作都要能用键盘做——「删除 → 撤销」「清掉草稿 →
  /// 恢复」这类只在岛上给出路）：收着的一行只露主按钮，先展开成卡片（全部按钮都看得见），选中主按钮；之后 ↩ 执行选中的、
  /// ←→ 换（卡片上主按钮在最右：← 往左 = 往后一个，到头回绕）、Esc 收（同 ×：挂着的提醒也算处理了）。窗口临时当 key、
  /// 不激活本 App；读屏念标题和选中的按钮。没有带按钮的东西（音量提示、一瞥、播放卡片、空着）返回 false
  private func focusButtons() -> Bool {
    guard hasButtonsToFocus, let content, let window else { return false }
    if !isExpanded {
      changedAt = .now
      withAnimation(Self.bloom) { isExpanded = true }
    }
    buttonSelection = 0
    takeKeyboard(window)
    armKeyboard()
    if actions.count == 1 {
      Self.announce("\(content.title)，回车「\(actions[0].title)」，Esc 关闭")
    } else {
      Self.announce("\(content.title)，左右键选按钮，回车执行，Esc 关闭；现在是「\(actions[0].title)」")
    }
    return true
  }

  /// 岛上正挂着能交键盘的按钮：一条提示、一张活动的卡片，带至少一个按钮（音量提示、一瞥没有按钮；播放卡片的按钮不是
  /// Island.Action，另有自己的手势）。全屏时藏着的岛（hidesNow：窗口全透明）不算——不然一扇看不见的窗口当 key，全屏 App
  /// 里打的字全被吞、↩ 执行看不见的按钮（评审 1）；这时照旧开那一张（那一张不藏）
  var hasButtonsToFocus: Bool {
    content != nil && !actions.isEmpty && level == nil && !isGlance && cardActivity?.media == nil
      && !hidesNow
  }

  /// 拿着键盘时没人按键多久还回去：那一张、会到点收起的提示 / 卡片重新数 6 秒、到点收起（收起时还键盘）；进行中的提示、
  /// 挂着的提醒不到点收起——只还键盘，照指针不在上面时的样子合回一行（排着的那条换上来，同 hover(false)）
  private func armKeyboard() {
    keyIdle?.cancel()
    keyIdle = nil
    guard !isBoardOpen, content?.tone == .progress || isShowingPinned else {
      if !isHovered { arm(Self.boardKeyboardDwell) }
      return
    }
    keyIdle = Task { [weak self] in
      try? await Task.sleep(for: Self.boardKeyboardDwell)
      guard !Task.isCancelled else { return }
      self?.dropKeyboard()
    }
  }

  /// 键盘不在岛上了（6 秒没按键、点了别处让岛不再是 key，评审 5）：还回去；原来在提示的按钮上、指针又不在岛上时照
  /// hover(false) 的样子收拾——排着的那条换上来，进行中的、挂着的提醒合回一行（会到点收起的照旧等它自己的时间）
  private func dropKeyboard() {
    guard holdsKeyboard else { return }
    let onButtons = !isBoardOpen
    releaseKeyboard()
    guard onButtons, !isHovered else { return }
    if let (next, actions) = pending {
      pending = nil
      return apply(next, actions: actions)
    }
    if content?.tone == .progress || isShowingPinned {
      withAnimation(Style.Motion.retract.animation()) { isExpanded = false }
    }
  }

  /// 按钮换了（活动原地更新、挂着的提醒换按钮）：键盘在按钮上时选中的跟着夹，没有按钮了就还键盘（A2，评审 4）
  func buttonsChanged() {
    guard let selection = buttonSelection else { return }
    if let kept = Self.reselected(selection, count: actions.count) {
      buttonSelection = kept
    } else {
      releaseKeyboard()
    }
  }

  /// 按钮换了之后选中哪一个（纯函数）：还在范围里不动，超出了夹到最后一个，没有按钮了是 nil
  static func reselected(_ selection: Int, count: Int) -> Int? {
    count == 0 ? nil : min(selection, count - 1)
  }

  func openBoard(byKeyboard: Bool = false) {
    // 键盘原来在提示的按钮上（A2，再按一次快捷键）：交给那一张；不是按键开的就还回去
    buttonSelection = nil
    if !byKeyboard { releaseKeyboard() }
    dwell?.cancel()
    hoverCheck?.cancel()
    // 正捏着等出音量 / 亮度的提示：不出了（不然那一张刚开出来就被它顶掉，后来的动作反而输）
    pinch?.cancel()
    pendingLevel = nil
    showsHistory = UserDefaults.standard.bool(forKey: Prefs.islandShowsHistory)
    // 摆出来的岛（单测、截图）用给进来的那一天，不读偏好、不读日程
    if !isStaged {
      calendarDay = UserDefaults.standard.bool(forKey: Prefs.islandCalendar) ? .now : nil
      agenda = calendarDay == nil ? nil : agendaProvider?()
    }
    // 进行中的提示留着（排着，progress() 接着改它的百分比），收起那一张时换回来；别的排着的：列着最近的提示时丢掉（它
    // 已经在列表里了），不列时照样留到那一张收起再出（评审 4：不然这条提示从没露过面）
    if let content, content.tone == .progress {
      pending = (content, actions)
    } else if pending?.content.tone != .progress {
      if showsHistory { pending = nil }
      onToneChange?(nil)
    }
    isRetracting = false
    quickActions = boardActions()
    changedAt = .now
    deadline = .now
    showWindow()
    // 决定画哪一种内容的那几样和 content 在同一个事务里清（见 apply 的说明）
    withAnimation(isOpen ? Self.resize : Style.Motion.island.animation()) {
      isOpen = true
      seated = false
      content = nil
      isBoardOpen = true
      actions = []
      expandedActivity = nil
      glancing = nil
      level = nil
      levelShaped = false
      isExpanded = false
      isPeeking = false
      isHovered = false
      pinched = false
    }
    let heading =
      quickActions.isEmpty && calendarDay != nil && !showsHistory
      ? String(localized: "月历")
      : !showsHistory
        ? String(localized: "快捷动作")
        : quickActions.isEmpty ? String(localized: "最近的提示") : String(localized: "最近的提示和快捷动作")
    guard byKeyboard, let window else { return Self.post(heading) }
    boardSelection = quickActions.isEmpty ? nil : 0
    takeKeyboard(window)
    armKeyboard()
    Self.announce(
      quickActions.isEmpty
        ? "\(heading)，按 Esc 关闭"
        : "\(heading)，左右键选快捷动作，回车执行，Esc 关闭；现在是「\(quickActions[0].title)」")
  }

  /// 那一张没人碰时多久自己收（同带按钮的岛）
  static let boardKeyboardDwell = Duration.seconds(6)

  /// 快捷键叫出的那一张、键盘交给提示上的按钮时：临时当 key（窗口是不激活本 App 的面板，前台 App 不变）
  private func takeKeyboard(_ window: IslandPanel) {
    if let key = NSApp.keyWindow, key !== window { keyBeforeBoard = key }
    holdsKeyboard = true
    window.keyable = true
    window.onKey = { [weak self] in self?.keyPressed($0) }
    // 点了别的 App、别的窗口拿走了键盘：岛就不再拿着它（不然新提示照样排着、再按快捷键直接换成那一张，评审 5）
    window.onResign = { [weak self] in self?.dropKeyboard() }
    window.makeKey()
  }

  /// 窗口当 key 时 sendEvent 交过来的按键：那一张开着归那一张，不然归提示上的按钮
  private func keyPressed(_ event: NSEvent) {
    guard holdsKeyboard else { return }
    if isBoardOpen { boardKey(event) } else { buttonKey(event) }
  }

  /// 那一张上的按键：Esc 收、←→ 选（到头回绕）、↩ 执行；别的键吞掉、不响
  private func boardKey(_ event: NSEvent) {
    // 按了键就重新计时（鼠标停在岛上时计时本来就停着）
    armKeyboard()
    switch Int(event.keyCode) {
    case 53:
      dismiss()
    case 123, 124:
      guard
        let next = Self.moved(
          boardSelection, by: event.keyCode == 123 ? -1 : 1,
          count: quickActions.count)
      else { return }
      boardSelection = next
      Self.post(quickActions[next].title)
    case 36, 76:
      if let index = boardSelection, quickActions.indices.contains(index) {
        perform(quickActions[index], checked: false)
      }
    default:
      break
    }
  }

  /// 提示 / 卡片上的按钮拿着键盘时的按键（A2）：Esc 收（同 ×）、←→ 换按钮、↩ 执行选中的；别的键吞掉、不响
  private func buttonKey(_ event: NSEvent) {
    guard let selection = buttonSelection, content != nil else { return }
    armKeyboard()
    switch Int(event.keyCode) {
    case 53:
      swipeAway()
    case 123, 124:
      guard
        let next = Self.moved(
          selection, by: Self.buttonStep(left: event.keyCode == 123), count: actions.count)
      else { return }
      buttonSelection = next
      Self.post(actions[next].title)
    case 36, 76:
      if actions.indices.contains(selection) { perform(actions[selection], checked: false) }
    default:
      break
    }
  }

  /// 卡片上的按钮从右往左排（主按钮 actions[0] 在最右，挨着 ×）：← 是往后一个、→ 是往前一个（纯函数）
  static func buttonStep(left: Bool) -> Int { left ? 1 : -1 }

  /// ←→ 选快捷动作（纯函数）：到头回绕；还没选中时从第一个起；没有快捷动作是 nil
  static func moved(_ selection: Int?, by step: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let selection else { return 0 }
    return ((selection + step) % count + count) % count
  }

  /// 收起 / 换成别的提示时把键盘还回去：叫出之前本 App 里有 key 窗口就还给它；本 App 不在前台（键盘本来在别的 App 里）
  /// 就 deactivate 一次——不激活的面板收起后 AppKit 会把 key 交给本进程别的面板、一直不放（同 NoteFloats.returnKeyboard）
  func releaseKeyboard() {
    keyIdle?.cancel()
    keyIdle = nil
    guard holdsKeyboard else { return }
    holdsKeyboard = false
    boardSelection = nil
    buttonSelection = nil
    window?.keyable = false
    window?.onKey = nil
    // 先摘：下面把键盘还给别的窗口时岛会 resignKey
    window?.onResign = nil
    defer { keyBeforeBoard = nil }
    guard window?.isKeyWindow == true else { return }
    if let previous = keyBeforeBoard, previous.isVisible {
      previous.makeKey()
    } else if !NSApp.isActive {
      NSApp.deactivate()
    }
  }
}
