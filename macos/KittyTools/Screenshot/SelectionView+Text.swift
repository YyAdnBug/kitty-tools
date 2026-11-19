// 框选遮罩里的文字标注（第五轮体检 H1 从 SelectionView.swift 拆出）：输入框的开、收、排版，和它的文本代理。

import AppKit

extension SelectionView {
  // MARK: 文字

  /// 在 origin（文字左上角）开始输入；existing 是双击的已有文字标注
  func beginEditing(at origin: CGPoint, existing: Annotation? = nil) {
    endEditing()
    let field = EditorField(frame: .zero)
    field.isRichText = false
    field.drawsBackground = false
    field.allowsUndo = true
    field.textContainerInset = .zero
    field.textContainer?.lineFragmentPadding = 0
    field.isHorizontallyResizable = true
    field.isVerticallyResizable = true
    field.textContainer?.widthTracksTextView = false
    field.textContainer?.heightTracksTextView = false
    field.textContainer?.containerSize = CGSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    field.wantsLayer = true
    // 双击重新编辑时全选：选中底色用品牌粉，字保留自己的颜色（截图家族不用系统强调色）
    field.selectedTextAttributes = [.backgroundColor: Style.Shot.accent.withAlphaComponent(0.4)]
    field.delegate = self
    let style = existing?.style ?? style
    apply(style, to: field)
    if case .text(let string, _)? = existing?.shape { field.string = string }
    editor = Editor(field: field, id: existing?.id, origin: origin, style: style)
    addSubview(field, positioned: .below, relativeTo: toolbar)
    layoutEditor()
    window?.makeFirstResponder(field)
    if existing != nil { field.selectAll(nil) }
    selectedAnnotation = existing?.id
    syncAnnotations()
  }

  /// 收下输入的文字（空的就不要 / 删掉原来那条），记一步撤销
  func endEditing() {
    guard let editor else { return }
    self.editor = nil
    let text = editor.field.string
    // 先把键盘还给自己再拿掉输入框：拿掉之后第一响应者会落到窗口上，单键快捷键就都失灵了
    if window?.firstResponder === editor.field { window?.makeFirstResponder(self) }
    editor.field.removeFromSuperview()
    var next = annotations
    var chosen = editor.id
    let index = editor.id.flatMap { id in next.firstIndex { $0.id == id } }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if let index { next.remove(at: index) }
    } else if let index {
      next[index].shape = .text(text, origin: editor.origin)
      next[index].style = editor.style
    } else {
      let added = Annotation(shape: .text(text, origin: editor.origin), style: editor.style)
      next.append(added)
      chosen = added.id
    }
    commit(next)
    // 收下后选中这条（新写的也是，同画完自动选中）；文字清空后那条已经删了
    selectedAnnotation = next.contains { $0.id == chosen } ? chosen : nil
    syncAnnotations()  // 没改动时 commit 不触发，也要把编辑时藏起来的那条显示回来
  }

  /// 输入框里的文字和收下后画出来的一样（输入中改样式也立刻变）：同字体；无底 = 字带阴影；描边 = 输入框先画带阴影的外描边、
  /// 再画不带阴影的字；底色 = 输入框的底就是带阴影的圆角色块（圆角 6），字用压在色块上的颜色（黄 / 白底黑字）
  func apply(_ style: Annotation.Style, to field: EditorField) {
    let plate = style.option == 2
    let ink = plate ? style.ink : style.paint
    field.font = Annotation.font(size: style.textSize)
    field.textColor = ink
    field.insertionPointColor = Style.Shot.accent  // 光标是强调色的位置（§1.2），截图家族用品牌粉
    field.ringRadius = plate ? 6 : 3
    let shadow = style.option == 0 ? Annotation.textShadow : nil
    let all = NSRange(location: 0, length: field.textStorage?.length ?? 0)
    field.typingAttributes[.shadow] = shadow
    if let shadow {
      field.textStorage?.addAttribute(.shadow, value: shadow, range: all)
    } else {
      field.textStorage?.removeAttribute(.shadow, range: all)
    }
    field.outline = style.option == 1 ? Annotation.outlineAttributes(style) : nil
    guard let layer = field.layer else { return }
    layer.backgroundColor = plate ? style.paint.cgColor : nil
    layer.cornerRadius = plate ? 6 : 0
    // 色块的阴影同 Annotation.textShadow（black 0.28、模糊 3）
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOffset = .zero
    layer.shadowRadius = 1.5
    layer.shadowOpacity = plate ? 0.28 : 0
  }

  /// 输入框比最后画出来的文字框大一圈、字的位置不变（左上角不动，往下长）：底色时这一圈就是色块的留边
  /// （Annotation.platePadding），其余留 3 给字的阴影和外描边（不被输入框的边裁掉），也给行尾的光标留地方
  func layoutEditor() {
    guard let editor else { return }
    let frame = Annotation.textFrame(
      editor.field.string, origin: editor.origin, size: editor.style.textSize)
    let pad = editor.style.option == 2 ? Annotation.platePadding : CGSize(width: 3, height: 3)
    if editor.field.textContainerInset != pad { editor.field.textContainerInset = pad }
    editor.field.frame = frame.insetBy(dx: -pad.width, dy: -pad.height)
    // 外描边画在字外面一圈，NSTextView 只重画改了的字形那块，会留残影：整块重画（输入框很小）
    if editor.field.outline != nil { editor.field.needsDisplay = true }
  }

  func textDidChange(_ notification: Notification) { layoutEditor() }

  /// 输入法组字（marked text）不走 textDidChange，但每次都会动选区：跟着改大小
  func textViewDidChangeSelection(_ notification: Notification) { layoutEditor() }

  func undoManager(for view: NSTextView) -> UndoManager? { editor?.undo }

  /// Esc 收下文字（开着 HUD 菜单时先收菜单；输入法组字时 Esc 先给输入法，不会走到这里）；↩ 换行
  func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    escape()
    return true
  }
}
