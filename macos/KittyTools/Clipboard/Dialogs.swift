// 剪贴板面板内的对话框：备注、编辑正文、新建片段、新建 / 管理收藏夹（mac-whisker §6 剪贴板）。
// 直接画在面板里、不开 sheet 窗口：非激活浮层的 sheet 拿不稳键盘焦点。一张宽 708、圆角 card 的卡从搜索栏下沿落下
// （settle，y −8→0 + 淡入；关掉淡出），只压暗列表区；输入框焦点环品牌粉，保存是品牌粉主按钮。
// 输入框用 isDialogField：出现时抢焦点，关闭后焦点回到它之前的输入框（搜索框，或管理收藏夹下面的新建框）；Esc 关对话框。
// 管理收藏夹（体检 A1）是键盘列表：行 28、中性高亮、↑↓ 选、↩ / 双击就地改名、⌘⌫ / 行尾「−」删除（不确认，⌘Z 撤销）、拖动排序。

import SwiftUI

/// 盖在列表区上：一直在视图树里，有对话框时才画压暗层和卡片（两者各自转场）
struct DialogOverlay: View {
  @Bindable var model: ClipboardPanelModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let drop: AnyTransition =
      reduceMotion ? .opacity : .offset(y: -8).combined(with: .opacity)
    ZStack(alignment: .top) {
      if model.dialog != nil {
        Button(action: close) { Color.black.opacity(0.2) }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭对话框")
          .transition(.opacity)
      }
      if let dialog = model.dialog {
        let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        card(dialog)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          // 阴影只挂在底上：挂在整张卡上会给里面的每个字都加阴影
          .background {
            shape.fill(.regularMaterial).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
          }
          .overlay(shape.hairlineBorder())
          .padding(6)
          .id(dialog.id)
          .transition(
            .asymmetric(
              insertion: drop,
              removal: .opacity.animation(.easeIn(duration: Style.fadeOut))))
      }
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: model.dialog?.id)
  }

  @ViewBuilder private func card(_ dialog: ClipboardPanelModel.Dialog) -> some View {
    switch dialog {
    case .note(let id):
      if let item = item(id) {
        NoteDialog(initial: item.note ?? "", onCancel: close) { text in
          let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
          model.store.update([id]) { $0.note = note.isEmpty ? nil : note }
          close()
        }
      }
    case .edit(let id):
      if let item = item(id) {
        // 提示只说和这条有关的（体检 C2）：片段说占位符（片段本来就按纯文本粘，带格式也不提丢格式），
        // 其余带格式的才说保存后丢格式
        let hint =
          item.isSnippet
          ? "⌘↩ 保存 · 占位符：" + Snippet.placeholderHelp
          : item.richType != nil ? "⌘↩ 保存 · 保存后不再保留原来的格式" : "⌘↩ 保存"
        TextDialog(title: "编辑内容", hint: hint, initial: item.text ?? "", onCancel: close) {
          text, _ in
          model.edit(id, text: text)
          close()
        }
      }
    case .newSnippet:
      TextDialog(
        title: "新建片段", hint: "⌘↩ 保存 · 占位符：" + Snippet.placeholderHelp, initial: "",
        asksName: true, onCancel: close
      ) { text, name in
        model.saveSnippet(text, name: name)
        close()
      }
    case .newGroup(let ids):
      NewGroupDialog(model: model, onCancel: close) { group in
        model.assign(ids, to: group.id)
        close()
      }
    case .manageGroups:
      ManageGroupsDialog(model: model, onClose: close)
    }
  }

  private func item(_ id: UUID) -> ClipItem? {
    model.store.items.first { $0.id == id }
  }

  private func close() {
    model.dialog = nil
  }
}

/// 多行文本对话框（编辑 / 新建片段）：⌘↩ 保存。正文去掉空白后为空、或和原文一样时「保存」置灰、⌘↩ 不生效（体检 C2）。
/// asksName（新建片段）：顶上一行可选的名称（存成备注，搜索时能搜到），焦点先在这里，Tab 切到正文
private struct TextDialog: View {
  let title: String
  let hint: String
  let initial: String
  var asksName = false
  let onCancel: () -> Void
  /// 正文、名称
  let onSave: (String, String) -> Void
  @State private var text: String
  @State private var name = ""
  /// 名称框里按 Tab 加一：正文框拿焦点
  @State private var bodyFocus = 0
  /// 有名称框时两个框轮流拿焦点：焦点环只画在拿着焦点的那个上（名称框出现时就抢焦点）
  @State private var nameFocused = true
  @State private var bodyFocused = false

  init(
    title: String, hint: String, initial: String, asksName: Bool = false,
    onCancel: @escaping () -> Void, onSave: @escaping (String, String) -> Void
  ) {
    self.title = title
    self.hint = hint
    self.initial = initial
    self.asksName = asksName
    self.onCancel = onCancel
    self.onSave = onSave
    _text = State(initialValue: initial)
  }

  var body: some View {
    let canSave = ClipboardPanelModel.canSave(text, initial: initial)
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      if asksName {
        CommandTextField(
          text: $name, placeholder: "名称（可选，用于搜索）", isDialogField: true,
          onCommand: { selector in
            switch selector {
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
              bodyFocus += 1
            case #selector(NSResponder.cancelOperation(_:)): onCancel()
            default: return false
            }
            return true
          }, onFocusChange: { nameFocused = $0 }
        )
        .dialogField(focused: nameFocused)
      }
      // 框的左右内边距改在文字上（6 + 2）：滚动条贴框的右边。有名称框时焦点先给名称框，Tab 过来
      SourceTextView(
        text: $text, submitsOnEnter: false, horizontalInset: 8, isDialogField: true,
        focusRequest: asksName ? bodyFocus : nil, onCancel: onCancel,
        onFocusChange: asksName ? { bodyFocused = $0 } : nil
      )
      .frame(height: 200)
      .dialogField(horizontalPadding: 0, focused: !asksName || bodyFocused)
      Text(hint).font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("取消", action: onCancel)
        Button("保存") { onSave(text, name) }
          .keyboardShortcut(.return, modifiers: .command)
          .buttonStyle(BrandButtonStyle())
          .disabled(!canSave)
      }
    }
  }
}

/// 备注（体检 A3）：单行，↩ 保存、Esc 取消，空着保存就是清除。所有条目都能写，不影响保留
private struct NoteDialog: View {
  let onCancel: () -> Void
  let onSave: (String) -> Void
  @State private var text: String

  init(initial: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
    self.onCancel = onCancel
    self.onSave = onSave
    _text = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("备注").font(.headline)
      // 搜索只过滤、不排序（体检 A6），备注命中不会排到前面：照实写「能搜到」
      CommandTextField(text: $text, placeholder: "给这条起个名字，搜索时能搜到", isDialogField: true) {
        selector in
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): onSave(text)
        case #selector(NSResponder.cancelOperation(_:)): onCancel()
        default: return false
        }
        return true
      }
      .dialogField()
      HStack {
        Spacer()
        Button("取消", action: onCancel)
        Button("保存") { onSave(text) }.buttonStyle(BrandButtonStyle())
      }
    }
  }
}

/// 新建收藏夹并把条目放进去（放进去就是收藏）
private struct NewGroupDialog: View {
  let model: ClipboardPanelModel
  let onCancel: () -> Void
  let onCreate: (ClipGroup) -> Void
  @State private var name = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("新建收藏夹").font(.headline)
      GroupNameField(text: $name, placeholder: "收藏夹名称") { selector in
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): create()
        case #selector(NSResponder.cancelOperation(_:)): onCancel()
        default: return false
        }
        return true
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消", action: onCancel)
        Button("创建", action: create).buttonStyle(BrandButtonStyle())
      }
    }
  }

  private func create() {
    if let group = model.store.createGroup(named: name) {
      onCreate(group)
    } else {
      error = "名称为空或已有同名收藏夹"
    }
  }
}

/// 管理收藏夹（体检 A1）：上面是收藏夹列表（行 28、中性 fill.selected 高亮、行尾 11 pt 条数和「−」），下面「新建收藏夹」输入框。
/// 焦点一直在输入框里：↑↓ 移动选中；输入框空着时 ↩ 就地改名（有字时 ↩ 创建）、⌘⌫ 删除；双击一行也改名。
/// 改名的输入框在那一行里：↩ 保存、Esc 取消，关掉后焦点回到下面的输入框。拖动一行排序（顺序存在 clip_groups.position，
/// ⌘K 和筛选面板按它排）；删除不确认，里面的条目留在默认收藏，底栏「已删除收藏夹「X」· 撤销 ⌘Z」
private struct ManageGroupsDialog: View {
  let model: ClipboardPanelModel
  let onClose: () -> Void
  @State private var selection: UUID?
  @State private var renaming: UUID?
  @State private var renameText = ""
  @State private var newName = ""
  @State private var error: String?
  /// 正在拖的那一行和它跟着指针走了多远
  @State private var drag: (id: UUID, dy: CGFloat)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let rowHeight: CGFloat = 28
  /// 超过这么多行在列表里滚动（给半行，露出下面还有）
  static let visibleRows: CGFloat = 6.5

  private var groups: [ClipGroup] { model.store.groups }

  var body: some View {
    let groups = self.groups
    var counts: [UUID: Int] = [:]
    for item in model.store.items { if let id = item.groupID { counts[id, default: 0] += 1 } }
    return VStack(alignment: .leading, spacing: 10) {
      Text("管理收藏夹").font(.headline)
      if groups.isEmpty {
        Text("还没有收藏夹。放进收藏夹的条目都算收藏，不会被清理")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                row(group, index: index, count: counts[group.id] ?? 0).id(group.id)
              }
            }
          }
          .scrollBounceBehavior(.basedOnSize)
          .frame(height: min(CGFloat(groups.count), Self.visibleRows) * Self.rowHeight)
          .onChange(of: selection) { _, id in
            if let id, drag == nil { proxy.scrollTo(id) }
          }
        }
      }
      GroupNameField(text: $newName, placeholder: "新建收藏夹", onCommand: newFieldCommand)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Text("↑↓ 选择 · ↩ 改名 · ⌘⌫ 删除 · 拖动排序")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("完成", action: onClose).buttonStyle(BrandButtonStyle())
      }
    }
    .onAppear { selection = groups.first?.id }
  }

  // MARK: 行

  private func row(_ group: ClipGroup, index: Int, count: Int) -> some View {
    let isSelected = group.id == selection
    let isDragged = drag?.id == group.id
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    let fill: Color = isSelected || isDragged ? Style.selectedFill : .clear
    let motion: Animation? = isDragged ? nil : Style.Motion.snap.animation(reduced: reduceMotion)
    return rowContent(group, index: index, count: count)
      .buttonStyle(.plain)
      .font(.system(size: 13))
      .padding(.horizontal, 8)
      .frame(height: Self.rowHeight)
      .background(fill, in: shape)
      .overlay { if isSelected { shape.contrastSelectionBorder() } }
      .offset(y: offset(of: group, index: index))
      .zIndex(isDragged ? 1 : 0)
      // 拖着的那行跟手（不动画），别的行让位用 snap
      .animation(motion, value: dropIndex)
      .contextMenu { rowMenu(group, index: index) }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(group.name)，\(count) 条")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityAction(named: "改名") { startRename(group) }
      .accessibilityAction(named: "上移") { move(group, by: -1) }
      .accessibilityAction(named: "下移") { move(group, by: 1) }
      .accessibilityAction(named: "删除") { delete(group) }
  }

  /// 改名时是行内输入框；平时整行是按钮：单击选中，双击改名，行尾「−」删除
  @ViewBuilder private func rowContent(_ group: ClipGroup, index: Int, count: Int) -> some View {
    if renaming == group.id {
      HStack(spacing: 8) {
        folderIcon
        GroupNameField(
          text: $renameText, placeholder: group.name, compact: true, onCommand: renameCommand)
      }
    } else {
      Button {
        if Style.isDoubleClick { startRename(group) } else { select(group.id) }
      } label: {
        rowLabel(group, count: count)
      }
      .simultaneousGesture(dragGesture(group, index: index))
    }
  }

  private func rowLabel(_ group: ClipGroup, count: Int) -> some View {
    HStack(spacing: 8) {
      folderIcon
      Text(group.name).lineLimit(1)
      Spacer(minLength: 8)
      Text("\(count)")
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
      Button("删除「\(group.name)」", systemImage: "minus") { delete(group) }
        .buttonStyle(.plain)  // 按钮的标签里不继承外面的 .plain，会画成带底的按钮
        .labelStyle(.iconOnly)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Style.danger)
        .frame(width: 16, height: 16)
        .contentShape(.rect)
        .help("删除（⌘⌫）")
    }
    .contentShape(.rect)
  }

  @ViewBuilder private func rowMenu(_ group: ClipGroup, index: Int) -> some View {
    Button("改名") { startRename(group) }
    Button("上移") { move(group, by: -1) }.disabled(index == 0)
    Button("下移") { move(group, by: 1) }.disabled(index == groups.count - 1)
    Divider()
    Button("删除", role: .destructive) { delete(group) }
  }

  private var folderIcon: some View {
    Image(systemName: "folder")
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: 16)
  }

  // MARK: 拖动排序

  private func dragGesture(_ group: ClipGroup, index: Int) -> some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        guard renaming == nil else { return }
        drag = (group.id, value.translation.height)
        selection = group.id
      }
      .onEnded { _ in
        guard let target = dropIndex else { return }
        withAnimation(Style.Motion.snap.animation(reduced: reduceMotion)) {
          model.store.moveGroup(group.id, to: target)
          drag = nil
        }
      }
  }

  /// 拖着的那行现在会落到第几个（按行高四舍五入）
  private var dropIndex: Int? {
    guard let drag, let from = groups.firstIndex(where: { $0.id == drag.id }) else { return nil }
    return min(max(from + Int((drag.dy / Self.rowHeight).rounded()), 0), groups.count - 1)
  }

  /// 拖着的行跟着指针；它经过的行往反方向让一格
  private func offset(of group: ClipGroup, index: Int) -> CGFloat {
    guard let drag, let to = dropIndex,
      let from = groups.firstIndex(where: { $0.id == drag.id })
    else { return 0 }
    if group.id == drag.id { return drag.dy }
    if from < to, index > from, index <= to { return -Self.rowHeight }
    if from > to, index >= to, index < from { return Self.rowHeight }
    return 0
  }

  // MARK: 键盘

  /// 下面「新建收藏夹」输入框的按键：↑↓ 移动选中；空着时 ↩ 改名、⌘⌫ 删除选中的；有字时 ↩ 创建；Esc 关对话框
  private func newFieldCommand(_ selector: Selector) -> Bool {
    let empty = newName.trimmingCharacters(in: .whitespaces).isEmpty
    switch selector {
    case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
    case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
    case #selector(NSResponder.insertNewline(_:)) where empty:
      guard let group = selectedGroup else { return true }
      startRename(group)
    case #selector(NSResponder.insertNewline(_:)): create()
    case #selector(NSResponder.deleteToBeginningOfLine(_:)) where newName.isEmpty:
      if let group = selectedGroup { delete(group) }
    case #selector(NSResponder.cancelOperation(_:)): onClose()
    default: return false
    }
    return true
  }

  /// 行里改名的输入框：↩ 保存、Esc 取消（不关对话框）
  private func renameCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)): commitRename()
    case #selector(NSResponder.cancelOperation(_:)): renaming = nil
    default: return false
    }
    return true
  }

  private var selectedGroup: ClipGroup? {
    groups.first { $0.id == selection } ?? groups.first
  }

  private func select(_ id: UUID) {
    if renaming != id { renaming = nil }
    selection = id
  }

  private func moveSelection(by offset: Int) {
    guard !groups.isEmpty else { return }
    let current = groups.firstIndex { $0.id == selection } ?? 0
    selection = groups[(current + offset + groups.count) % groups.count].id
  }

  private func startRename(_ group: ClipGroup) {
    selection = group.id
    renameText = group.name
    renaming = group.id
    error = nil
  }

  private func commitRename() {
    guard let id = renaming else { return }
    if model.store.renameGroup(id, to: renameText) {
      renaming = nil
      error = nil
    } else {
      error = "名称为空或已有同名收藏夹"
    }
  }

  private func create() {
    if let group = model.store.createGroup(named: newName) {
      newName = ""
      selection = group.id
      error = nil
    } else {
      error = "名称为空或已有同名收藏夹"
    }
  }

  private func move(_ group: ClipGroup, by offset: Int) {
    guard let index = groups.firstIndex(of: group) else { return }
    withAnimation(Style.Motion.snap.animation(reduced: reduceMotion)) {
      model.store.moveGroup(group.id, to: index + offset)
    }
  }

  /// 删掉后选中挪到同一位置的下一个（删的是最后一个就上一个）
  private func delete(_ group: ClipGroup) {
    guard let index = groups.firstIndex(of: group) else { return }
    if renaming == group.id { renaming = nil }
    model.deleteGroup(group)
    let rest = groups
    selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
  }
}

/// 收藏夹名字的输入框：最多 24 字，超出的那次输入被拦下（不截断），到上限时右边显示「24/24」。
/// compact：在管理列表的行里就地改名（28 pt 行里放得下，不画焦点外发光）
private struct GroupNameField: View {
  @Binding var text: String
  let placeholder: String
  var compact = false
  let onCommand: (Selector) -> Bool

  var body: some View {
    let field = CommandTextField(
      text: $text, placeholder: placeholder, isDialogField: true, fontSize: compact ? 13 : 14,
      maxLength: ClipGroup.maxName, onCommand: onCommand)
    HStack(spacing: 6) {
      if compact {
        field
          .padding(.horizontal, 4)
          .frame(height: 22)
          .background(
            Style.inputFill, in: .rect(cornerRadius: Style.Radius.mini, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: Style.Radius.mini, style: .continuous)
              .strokeBorder(Style.brand.opacity(0.55), lineWidth: 1))
      } else {
        field.dialogField()
      }
      if text.count >= ClipGroup.maxName {
        Text("\(ClipGroup.maxName)/\(ClipGroup.maxName)")
          .font(.system(size: 11))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .accessibilityLabel("已到 \(ClipGroup.maxName) 字上限")
      }
    }
  }
}

extension View {
  /// 对话框里的输入框（Whisker §3）：InputBox（Style.inputFill 底，焦点环 1 pt 品牌粉 0.55 + 粉 0.18 外发光）加内边距。
  /// 只有一个输入框的对话框一直拿着焦点，焦点环常亮；有两个的（新建片段：名称 + 正文）传 focused，没焦点的只描发丝线
  fileprivate func dialogField(horizontalPadding: CGFloat = 6, focused: Bool = true) -> some View {
    padding(.horizontal, horizontalPadding)
      .padding(.vertical, 6)
      .modifier(InputBox(isFocused: focused))
  }
}
