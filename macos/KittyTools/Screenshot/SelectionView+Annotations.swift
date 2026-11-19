// 框选遮罩里的标注（第五轮体检 H1 从 SelectionView.swift 拆出）：选中、复制、提交一笔、撤销 / 重做、改样式、删除。

import AppKit

extension SelectionView {
  // MARK: 标注

  var selected: Annotation? {
    selectedAnnotation.flatMap { id in annotations.first { $0.id == id } }
  }

  /// 样式栏显示的样式：输入中的文字 > 选中的标注 > 新标注用的
  var shownStyle: Annotation.Style { editor?.style ?? selected?.style ?? style }

  /// 标注层显示的：已有的（正在编辑的那条文字由输入框显示）+ 正在拖出来的
  func syncAnnotations() {
    let editing = editor?.id
    var shown = annotations.filter { $0.id != editing }
    if let draft { shown.append(draft) }
    annotationCanvas?.annotations = shown
    refresh()
  }

  /// 最上面那条被点中的标注（按画的层次，见 Annotation.topmost）
  func annotation(at point: CGPoint) -> Annotation? {
    Annotation.topmost(in: annotations, at: point)
  }

  /// 按在选中标注的哪个手柄上（半径 7 内最近的，point 是手柄的位置）：按下时比选区边优先，两者叠在一起时拖的是标注
  func annotationHandle(at point: CGPoint) -> (
    annotation: Annotation, handle: Annotation.Handle, point: CGPoint
  )? {
    guard editor == nil, let selected else { return nil }
    let distance = { (grip: (Annotation.Handle, CGPoint)) in
      hypot(grip.1.x - point.x, grip.1.y - point.y)
    }
    return selected.handles.filter { distance($0) <= 7 }.min { distance($0) < distance($1) }
      .map { (selected, $0.0, $0.1) }
  }

  /// 换掉同 id 的那条（拖动、改大小时跟手，撤销在松手时记）
  func replace(_ annotation: Annotation) {
    guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
    annotations[index] = annotation
  }

  /// 复制一份（新 id，序号换成下一个号），调用方放到最上面
  func duplicate(_ original: Annotation, offset: CGSize) -> Annotation {
    var copy = original.duplicated(offset: offset)
    if case .counter(_, let center) = copy.shape {
      copy.shape = .counter(Annotation.nextCounter(in: annotations), center: center)
    }
    return copy
  }

  /// 正拖着标注（画、挪、改大小）：撤销 / 重做 / 删除 / 复制 / 方向键挪标注都不响应。松手时要按按下前的样子记一步撤销，
  /// 中途改了标注列表，撤销栈和松手时的那一步就对不上了
  var isDraggingAnnotation: Bool {
    switch drag {
    case .annotate?, .moveAnnotation?, .resizeAnnotation?: true
    default: false
    }
  }

  /// ⌘D：选中的标注复制一份，往右下偏 12（原点左下，y 是 −12），选中副本
  func duplicateSelected() {
    guard !isDraggingAnnotation, let selected else { return }
    let copy = duplicate(selected, offset: CGSize(width: 12, height: -12))
    commit(annotations + [copy])
    selectedAnnotation = copy.id
  }

  /// 一次拖动（挪、改大小、⌥ 复制、放序号）松手时记一步撤销；没变不记
  func recordUndo(from before: [Annotation]) {
    guard annotations != before else { return }
    undoStack.append(before)
    redoStack = []
    refresh()
  }

  /// 再按一次同一个工具就收起（回到拖动平移选区）；选上时读这个工具上次的样式
  func choose(_ next: Annotation.Tool) {
    endEditing()
    pickingColor = false  // 换工具就不取色了
    let chosen = tool == next ? nil : next
    // 先换样式再换工具：托盘换工具那一下拿到的就是这个工具的样式（反过来色点先显示旧样式、再弹一下）
    if let chosen { style = Annotation.Style.remembered(for: chosen, in: styleDefaults) }
    tool = chosen
    selectedAnnotation = nil
    refreshCursor()
    announce(
      chosen.map { String(localized: "\($0.title)工具") } ?? String(localized: "已收起工具"))
  }

  /// 改了标注就记一步撤销（没变不记）
  func commit(_ next: [Annotation]) {
    guard next != annotations else { return }
    undoStack.append(annotations)
    redoStack = []
    annotations = next
  }

  func undo() {
    guard !isDraggingAnnotation else { return }
    endEditing()
    guard let previous = undoStack.popLast() else { return NSSound.beep() }
    redoStack.append(annotations)
    annotations = previous
    if selected == nil { selectedAnnotation = nil }
  }

  func redo() {
    guard !isDraggingAnnotation else { return }
    endEditing()
    guard let next = redoStack.popLast() else { return NSSound.beep() }
    undoStack.append(annotations)
    annotations = next
    if selected == nil { selectedAnnotation = nil }
  }

  /// 改颜色 / 粗细 / 选项：作用于正在输入的文字、选中的标注（修旧版改样式不作用于选中项，#47）或当前工具的新标注，
  /// 并记成那个工具的样式（Prefs.screenshotToolStyles）
  func restyle(_ change: (inout Annotation.Style) -> Void) {
    hudMenu?.dismiss()  // 点托盘也是点在菜单外面：同点栏上的按钮，先收菜单
    finishSizeEditing(commit: true)  // 输入着尺寸点了托盘：点别处提交
    if var editor {
      change(&editor.style)
      self.editor = editor
      apply(editor.style, to: editor.field)
      layoutEditor()
      remember(editor.style, for: .text)
    } else if let id = selectedAnnotation,
      let index = annotations.firstIndex(where: { $0.id == id })
    {
      var next = annotations
      change(&next[index].style)
      commit(next)
      remember(next[index].style, for: next[index].tool)
    } else if let tool {
      var changed = style
      change(&changed)
      remember(changed, for: tool)
    }
    refresh()
  }

  /// 记住这个工具的样式；是当前工具的话新标注也用它
  private func remember(_ changed: Annotation.Style, for owner: Annotation.Tool) {
    Annotation.Style.remember(changed, for: owner, in: styleDefaults)
    if owner == tool { style = changed }
  }

  func deleteSelected() {
    guard !isDraggingAnnotation, let id = selectedAnnotation else { return }
    selectedAnnotation = nil
    commit(annotations.filter { $0.id != id })
  }
}
