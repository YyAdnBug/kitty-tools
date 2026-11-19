// 框选遮罩的键盘（第五轮体检 H1 从 SelectionView.swift 拆出；输入文字时按键都归输入框）：工具键、修饰键、⌘ 键、方向键推选区和标注。

import AppKit
import Carbon.HIToolbox

extension SelectionView {
  // MARK: 键盘（输入文字时按键都归输入框，不到这里）

  /// 方向键对应的选区边（AppKit 坐标 y 朝上：↑ 是上边 maxY）
  private static let arrowEdges: [Int: RegionSelector.Handle] = [
    kVK_LeftArrow: .left, kVK_RightArrow: .right, kVK_UpArrow: .top, kVK_DownArrow: .bottom,
  ]

  override func keyDown(with event: NSEvent) {
    if let key = rebinding { return rebind(key, with: event) }
    let code = Int(event.keyCode)
    if code == kVK_Escape { return escape() }
    // 空格：拖动框选时整块平移（截图翻译 / 识字也是）；按住不放的自动重复不算新按下
    if code == kVK_Space {
      if !event.isARepeat { isSpaceDown = true }
      return
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option])
    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
    // ⌥ + 方向键：那条边往里收（⌘ + 方向键走 performKeyEquivalent）
    if adjusts, flags == .option, let edge = Self.arrowEdges[code] {
      return push(edge, by: -step)
    }
    guard adjusts else { return super.keyDown(with: event) }
    // 固定的键（不带 ⌘ ⌃ ⌥；⇧ + 方向键是 10 点）：↩ 确认、⌫ 删标注、方向键微调。录屏只认 ↩ 和方向键
    if flags.isEmpty {
      switch code {
      case kVK_Return, kVK_ANSI_KeypadEnter:
        if isAdjusting { confirm() }
        return
      case kVK_Delete where annotates, kVK_ForwardDelete where annotates: return deleteSelected()
      case kVK_Tab where selection == nil && session.findsElements: return toggleWindowOnly()
      case kVK_LeftArrow: return nudge(-step, 0)
      case kVK_RightArrow: return nudge(step, 0)
      case kVK_UpArrow: return nudge(0, step)
      case kVK_DownArrow: return nudge(0, -step)
      default: break
      }
    }
    // 截图时的快捷键（ShotKeys，设置 › 快捷键里能改；带 ⌘ 的多半先到 performKeyEquivalent）。
    // ponytail: 按物理键位，Dvorak 等布局下位置不同
    if let key = ShotKey.matching(event), perform(key) { return }
    super.keyDown(with: event)
  }

  /// ⌘+ / ⌘−（⌘=、⇧⌘=、⌘-、小键盘 ⌘+ ⌘-，就是 ShotKeys.isReserved 留出来的那几个，改键改不到它们）是往大 / 往小一档；
  /// 别的 nil。长图标注遮罩也用它
  static func fontStep(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Int? {
    switch (event.typedKeyCode, flags) {
    case (kVK_ANSI_Equal, .command), (kVK_ANSI_Equal, [.command, .shift]),
      (kVK_ANSI_KeypadPlus, .command):
      return 1
    case (kVK_ANSI_Minus, .command), (kVK_ANSI_KeypadMinus, .command): return -1
    default: return nil
    }
  }

  /// 截图时的一个快捷键（ShotKeys）：这个模式用得上就做、返回 true（吃掉这一下）。录屏只认上次区域和取色：
  /// 出图键、工具、撤销、切到录屏都是截图的
  private func perform(_ key: ShotKey) -> Bool {
    switch key {
    case .lastRegion:
      if !session.selectLastRegion() { refuseWipe(String(localized: "有标注时不跳到别的屏")) }
      return true
    case .pickColor:
      // 吸管取色时 C 也是取色（放大镜的信息卡上亮着 C），不能结束截图把选区和标注丢掉
      if pickingColor {
        pickColor()
        return true
      }
      // 设置里不显示色值时不取：看不见要拷的是什么，误按一下这次截图就结束了（录屏没有色值卡，照旧按设置）
      if showsMagnifier, loupeStyle == .full, let sampled { session.finish(.color(sampled.hex)) }
      return true
    case .record where !Feature.record.isOn:
      return false
    default:
      break
    }
    guard annotates else { return false }
    guard isAdjusting else { return true }
    if let tool = key.tool {
      choose(tool)
      return true
    }
    switch key {
    case .pin: output(.pin)
    case .scroll: startScroll()
    case .recognize: output(.recognize)
    case .record: switchToRecording()
    case .copy: output(.copy)
    case .save: output(.save)
    case .saveAs: output(.saveAs)
    case .undo: undo()
    case .redo: redo()
    default: return false
    }
    return true
  }

  /// 修饰键按下 / 松开：⌘ 十字准线跟着出现 / 消失；框选、拖边、画 / 拖标注途中按上次的鼠标位置重算（⇧ ⌥ ⌃ 立刻生效）
  override func flagsChanged(with event: NSEvent) {
    modifiers = event.modifierFlags
    if let dragPoint {
      switch drag {
      case .draw(_, let last, _)?: extend(to: last)
      case .resize(let handle, let original)?: resize(handle, from: original, to: dragPoint)
      case .annotate?, .moveAnnotation?, .resizeAnnotation?: dragAnnotation(to: dragPoint)
      default: break
      }
    }
    super.flagsChanged(with: event)
  }

  override func keyUp(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Space { isSpaceDown = false } else { super.keyUp(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard adjusts, window?.isKeyWindow == true else {
      return super.performKeyEquivalent(with: event)
    }
    // 等着新的快捷键：带 ⌘ ⌃ 的组合也先到这里
    if let key = rebinding {
      rebind(key, with: event)
      return true
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = event.typedKeyCode
    // 焦点在译文卡片的字上：选中了字时 ⌘C 拷那段字（不是整张截图；没选中照常拷截图）、⌘A 全选这段；
    // ⌘ + 方向键留给字自己（不推选区的边，不然卡片跟着收掉）
    if let translationCard, translationCard.owns(window?.firstResponder),
      let text = window?.firstResponder as? NSTextView
    {
      if Self.arrowEdges[Int(event.keyCode)] != nil { return false }
      if flags == .command,
        key == kVK_ANSI_A || (key == kVK_ANSI_C && text.selectedRange().length > 0),
        let action = OverlayPanel.editActions[key]
      {
        return OverlayPanel.sendEditAction(action, from: self)
      }
    }
    // 输入文字 / 尺寸时：⌘C / ⌘V / ⌘X / ⌘A 发给输入框（本 App 不激活，主菜单收不到）；⌘Z / ⇧⌘Z 直接动输入框自己的
    // 撤销栈（NSWindow.undoFocusedText，第三轮体检：原来发 undo: / redo: 动作，顺着响应链到头是窗口接、字不变）
    // ⌘+ / ⌘−：正在输入或选中文字时换一档字号（拍板 A2）；⌘= 不按 ⇧ 也算 +
    if annotates, !sizeField.isEditing, editor != nil || selected?.tool == .text,
      let step = Self.fontStep(event, flags: flags)
    {
      // 拖着标注时吞掉不做：中途改了列表，松手记的那一步撤销就对不上（同 ⌘Z / ⌫）
      if !isDraggingAnnotation { restyle { $0 = $0.stepped(step, for: .text) } }
      return true
    }
    if editor != nil || sizeField.isEditing {
      if key == kVK_ANSI_Z, flags.subtracting(.shift) == .command {
        if window?.undoFocusedText(redo: flags.contains(.shift)) != true { NSSound.beep() }
        return true
      }
      guard flags == .command, let action = OverlayPanel.editActions[key] else {
        return super.performKeyEquivalent(with: event)
      }
      return OverlayPanel.sendEditAction(action, from: self)
    }
    guard isAdjusting else { return super.performKeyEquivalent(with: event) }
    // ⌘ + 方向键：那条边往外推（⇧ 10 点）
    if flags.subtracting(.shift) == .command, let edge = Self.arrowEdges[Int(event.keyCode)] {
      push(edge, by: flags.contains(.shift) ? 10 : 1)
      return true
    }
    // 出图 / 撤销这些（ShotKeys，默认 ⌘C ⌘S ⇧⌘S ⌘Z ⇧⌘Z，能改）；⌘D 复制标注固定
    if let key = ShotKey.matching(event), perform(key) { return true }
    guard annotates, key == kVK_ANSI_D, flags == .command, selectedAnnotation != nil
    else { return super.performKeyEquivalent(with: event) }
    duplicateSelected()
    return true
  }

  /// ⌘ / ⌥ + 方向键：选区那条边往外推（delta > 0）/ 往里收，短边不小于 8
  private func push(_ edge: RegionSelector.Handle, by delta: CGFloat) {
    guard isAdjusting, let selection else { return }
    self.selection = RegionSelector.pushed(selection, edge, by: delta, within: bounds)
    refreshCursor()
  }

  /// 方向键：选中了标注就挪标注（每下记一步撤销），否则微调选区
  private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
    guard isAdjusting, !isDraggingAnnotation, let selection else { return }
    if let id = selectedAnnotation, let index = annotations.firstIndex(where: { $0.id == id }) {
      var next = annotations
      next[index] = next[index].offset(by: CGSize(width: dx, height: dy))
      return commit(next)
    }
    self.selection = RegionSelector.moved(
      selection, by: CGSize(width: dx, height: dy), within: bounds)
    refreshCursor()
  }
}
