// 剪贴板面板内的对话框：备注、编辑正文、新建片段、新建 / 管理分组（mac-whisker §6 剪贴板）。
// 直接画在面板里、不开 sheet 窗口：非激活浮层的 sheet 拿不稳键盘焦点。一张宽 708、圆角 card 的卡从搜索栏下沿落下
// （settle，y −8→0 + 淡入；关掉淡出），只压暗列表区；输入框焦点环品牌粉，保存是品牌粉主按钮。
// 输入框用 isDialogField：出现时抢焦点，关闭后焦点回到搜索框；Esc 关对话框。

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
          .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
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
        TextDialog(
          title: "备注", hint: "Enter 保存，Shift+Enter 换行，留空即清除", initial: item.note ?? "",
          submitsOnEnter: true, onCancel: close
        ) { text in
          let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
          model.store.update([id]) { $0.note = note.isEmpty ? nil : note }
          close()
        }
      }
    case .edit(let id):
      if let item = item(id) {
        TextDialog(
          title: "编辑内容", hint: "⌘↩ 保存。保存后不再保留原来的格式", initial: item.text ?? "",
          submitsOnEnter: false, onCancel: close
        ) { text in
          if !text.isEmpty { model.edit(id, text: text) }
          close()
        }
      }
    case .newSnippet:
      TextDialog(
        title: "新建片段", hint: "⌘↩ 保存。占位符：{date} 当天日期、{clipboard} 当前剪贴板、{cursor} 粘贴后光标停在这里",
        initial: "",
        submitsOnEnter: false, onCancel: close
      ) { text in
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          model.store.saveSnippet(text)
        }
        close()
      }
    case .newGroup(let ids):
      NewGroupDialog(model: model, onCancel: close) { group in
        model.assign(ids, to: group.id)
        close()
      }
    case .manageGroups:
      ManageGroupsDialog(store: model.store, onClose: close)
    }
  }

  private func item(_ id: UUID) -> ClipItem? {
    model.store.items.first { $0.id == id }
  }

  private func close() {
    model.dialog = nil
  }
}

/// 多行文本对话框（备注 / 编辑 / 新建片段）
private struct TextDialog: View {
  let title: String
  let hint: String
  let submitsOnEnter: Bool
  let onCancel: () -> Void
  let onSave: (String) -> Void
  @State private var text: String

  init(
    title: String, hint: String, initial: String, submitsOnEnter: Bool,
    onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void
  ) {
    self.title = title
    self.hint = hint
    self.submitsOnEnter = submitsOnEnter
    self.onCancel = onCancel
    self.onSave = onSave
    _text = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      // 框的左右内边距改在文字上（6 + 2）：滚动条贴框的右边
      SourceTextView(
        text: $text, submitsOnEnter: submitsOnEnter, horizontalInset: 8, isDialogField: true,
        onCancel: onCancel
      ) { onSave(text) }
      .frame(height: submitsOnEnter ? 80 : 200)
      .dialogField(horizontalPadding: 0)
      Text(hint).font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("取消", action: onCancel)
        Button("保存") { onSave(text) }
          .keyboardShortcut(.return, modifiers: .command)
          .buttonStyle(.borderedProminent)
          .tint(Style.brand)
      }
    }
  }
}

/// 新建分组并把条目归进去
private struct NewGroupDialog: View {
  let model: ClipboardPanelModel
  let onCancel: () -> Void
  let onCreate: (ClipGroup) -> Void
  @State private var name = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("新建分组").font(.headline)
      CommandTextField(text: $name, placeholder: "分组名称（最多 24 字）", isDialogField: true) { selector in
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): create()
        case #selector(NSResponder.cancelOperation(_:)): onCancel()
        default: return false
        }
        return true
      }
      .dialogField()
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消", action: onCancel)
        Button("创建", action: create).buttonStyle(.borderedProminent).tint(Style.brand)
      }
    }
  }

  private func create() {
    if let group = model.store.createGroup(named: name) {
      onCreate(group)
    } else {
      error = "名称为空或已有同名分组"
    }
  }
}

/// 管理分组：新建、重命名、删除（删除只解除条目的归属）
private struct ManageGroupsDialog: View {
  let store: ClipboardStore
  let onClose: () -> Void
  @State private var name = ""
  @State private var renaming: ClipGroup?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("管理分组").font(.headline)
      if store.groups.isEmpty {
        Text("还没有分组").foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(spacing: 2) {
            ForEach(store.groups) { group in
              HStack {
                Text(group.name).lineLimit(1)
                Text("\(store.items.filter { $0.groupID == group.id }.count)")
                  .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重命名", systemImage: "pencil") {
                  renaming = group
                  name = group.name
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                  store.deleteGroup(group.id)
                }
              }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .padding(.vertical, 3)
            }
          }
        }
        .frame(maxHeight: 180)
      }
      Divider()
      CommandTextField(
        text: $name, placeholder: renaming.map { "重命名「\($0.name)」" } ?? "新建分组名称",
        isDialogField: true
      ) { selector in
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit()
        case #selector(NSResponder.cancelOperation(_:)): onClose()
        default: return false
        }
        return true
      }
      .dialogField()
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        if renaming != nil {
          Button("取消重命名") {
            renaming = nil
            name = ""
          }
        }
        Spacer()
        Button(renaming == nil ? "新建" : "重命名", action: submit)
        Button("完成", action: onClose).buttonStyle(.borderedProminent).tint(Style.brand)
      }
    }
  }

  private func submit() {
    let succeeded =
      if let renaming { store.renameGroup(renaming.id, to: name) } else {
        store.createGroup(named: name) != nil
      }
    guard succeeded else {
      error = "名称为空或已有同名分组"
      return
    }
    renaming = nil
    name = ""
    error = nil
  }
}

extension View {
  /// 对话框里的输入框（Whisker §3）：primary 0.045（深 0.07）底 + 0.5 pt 发丝线，焦点环 1 pt 品牌粉 0.55 + 粉 0.18 外发光。
  /// 对话框里只有一个输入框、一直拿着焦点，所以焦点环常亮
  fileprivate func dialogField(horizontalPadding: CGFloat = 6) -> some View {
    modifier(DialogField(horizontalPadding: horizontalPadding))
  }
}

private struct DialogField: ViewModifier {
  var horizontalPadding: CGFloat = 6
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    content
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, 6)
      .background(Color.primary.opacity(scheme == .dark ? 0.07 : 0.045), in: shape)
      // 外发光画在描边上再模糊（不给整块加 shadow：那样连里面的字都带光晕）
      .background {
        shape.stroke(Style.brand.opacity(0.18), lineWidth: 4).blur(radius: 2)
      }
      .overlay(shape.strokeBorder(Style.brand.opacity(0.55), lineWidth: 1))
  }
}
