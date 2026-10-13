// 全部便签窗口的界面（系统皮肤的普通窗口，mac-whisker-notes.mdc「全部便签」；窗口和状态在 NotesWindow.swift）。
// NavigationSplitView 两栏。左：顶上分段「全部 / 归档 / 最近删除」（带条数）→ 搜索框 → 列表（行 = 纸色圆点、标题、
// 一行预览、相对时间，固定的带图钉；选中是中性高亮；「全部」里没在搜索时能拖动排序）。右：这条便签——整块是它的纸色，
// 顶上一条色条，标题框、正文、底下一行小字（改于什么时候、多少字；这三件在 NoteFields.swift，和屏幕边缘那叠共用）；
// 最近删除里的只读，列表下面多一行「清空最近删除…」。操作在工具栏和右键菜单里，名字取自 NotesWindowModel 的同一份；
// 键盘挂在看不见的按钮上（shortcuts）。

import SwiftUI

struct NotesWindowView: View {
  @Bindable var model: NotesWindowModel
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15
  @FocusState private var searchFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private typealias Model = NotesWindowModel

  var body: some View {
    NavigationSplitView {
      sidebar.navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
    } detail: {
      detail
        .navigationTitle(HotKeyAction.noteAll.title)
        .toolbar { toolbar }
    }
    .toolbar(removing: .sidebarToggle)
    .background { shortcuts }
    .onChange(of: model.searchFocus) { searchFocused = true }
    .confirmationDialog(
      "永久删除「\(model.erasing.flatMap(model.store.note)?.displayTitle ?? "")」？",
      isPresented: Binding {
        model.erasing != nil
      } set: {
        if !$0 { model.erasing = nil }
      }
    ) {
      Button("永久删除", role: .destructive) {
        if let id = model.erasing { model.erase(id) }
      }
    } message: {
      Text("这条便签会被永久删除，不能撤销。")
    }
    .confirmationDialog("清空最近删除？", isPresented: $model.isEmptyingTrash) {
      Button("清空", role: .destructive) { model.emptyTrash() }
    } message: {
      Text("里面的 \(model.list(.trash).count) 条便签会被永久删除，不能撤销。")
    }
    .symbolEffectsRemoved(reduceMotion)
    .appAccent()
  }

  // MARK: 左边

  private var sidebar: some View {
    VStack(spacing: 0) {
      Picker("视图", selection: $model.scope) {
        ForEach(Model.Scope.allCases) { scope in
          let count = model.list(scope).count
          Text(count > 0 ? "\(scope.title) \(count)" : scope.title).tag(scope)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 10)
      .padding(.top, 4)
      .padding(.bottom, 8)
      searchField.padding(.horizontal, 10)
      list
      if model.scope == .trash, !model.list(.trash).isEmpty { trashBar }
    }
  }

  /// 最近删除的列表下面：留多久 + 清空（危险色的系统按钮，mac-whisker §3「危险色」）
  private var trashBar: some View {
    VStack(spacing: 0) {
      Hairline()
      HStack(spacing: 8) {
        Text("留 \(NoteStore.trashDays) 天后自动删除")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 4)
        DangerButton(Model.emptyTrashTitle) { model.isEmptyingTrash = true }
          .controlSize(.small)
      }
      .padding(.horizontal, 10)
      .frame(height: 36)
    }
  }

  /// 搜索框：输入框底和焦点环用 Whisker 的现成件（同翻译历史的搜索框）
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      TextField("搜索便签", text: $model.query)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused($searchFocused)
        .onExitCommand { model.query = "" }
      if !model.query.isEmpty {
        Button("清除搜索", systemImage: "xmark.circle.fill") { model.query = "" }
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .modifier(InputBox(isFocused: searchFocused))
  }

  @ViewBuilder private var list: some View {
    let notes = model.notes
    if notes.isEmpty {
      empty.padding(20)
    } else {
      List(selection: $model.selection) {
        ForEach(notes) { note in
          NoteRow(note: note, isSelected: note.id == model.selection)
            .tag(note.id)
            .contextMenu { menu(for: note) }
        }
        .onMove(perform: model.canReorder ? { model.move(from: $0, to: $1) } : nil)
      }
      // 焦点在列表上时 ⌫ 也是删除（⌘⌫ 由窗口按键码认，NotesWindow.handlesKeyDown）
      .onDeleteCommand { if let id = model.selection { model.delete(id) } }
    }
  }

  @ViewBuilder private var empty: some View {
    if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
      EmptyState(symbol: "magnifyingglass", title: "没有匹配的便签") {
        Button("清除搜索") { model.query = "" }
          .buttonStyle(.plain)
          .foregroundStyle(Style.brandInk)
          .pointerStyle(.link)
      }
    } else {
      switch model.scope {
      case .all:
        EmptyState(symbol: HotKeyAction.noteAll.symbol, title: "还没有便签") {
          VStack(spacing: 6) {
            keyHint("在这里新建一条", "⌘N")
            if let hotKey = HotKeyAction.noteCapture.hotKey {
              keyHint("在任何地方\(HotKeyAction.noteCapture.title)", hotKey.display)
            }
          }
        }
      case .archive:
        EmptyState(symbol: "archivebox", title: "归档是空的") {
          Text("暂时不看的便签可以归档，要用时再取消归档").foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      case .trash:
        EmptyState(symbol: "trash", title: "最近删除是空的") {
          Text("删掉的便签在这里留 \(NoteStore.trashDays) 天").foregroundStyle(.secondary)
        }
      }
    }
  }

  private func keyHint(_ text: String, _ keys: String) -> some View {
    HStack(spacing: 6) {
      Text(text).foregroundStyle(.secondary)
      KeyCombo(keys)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: 右边

  @ViewBuilder private var detail: some View {
    if let note = model.current {
      // 一条便签一块编辑区（.id）：换一条时滚动位置、光标、撤销栈都从头来
      NoteEditor(model: model, note: note, fontSize: Prefs.notesFontSize(fontSize)).id(note.id)
    } else if !model.notes.isEmpty {
      Text("没有选中的便签").font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      // 列表是空的：左边的空状态已经说了，这边不再重复
      Color.clear
    }
  }

  // MARK: 操作

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      let note = model.current
      if model.scope == .trash {
        Button(Model.restoreTitle, systemImage: "arrow.uturn.backward") {
          if let note { model.restore(note.id) }
        }
        .disabled(note == nil)
        .help(Model.restoreTitle)
        Button(role: .destructive) {
          if let note { model.delete(note.id) }
        } label: {
          Label(Model.eraseTitle, systemImage: "trash.slash").foregroundStyle(Style.danger)
        }
        .disabled(note == nil)
        .help("永久删除（⌘⌫）")
      } else {
        Button(
          Model.pinTitle(note), systemImage: note?.isPinned == true ? "pin.slash" : "pin"
        ) {
          if let note { model.togglePinned(note.id) }
        }
        .disabled(note == nil)
        .help("\(Model.pinTitle(note))（⌘P）")
        Button(Model.archiveTitle(note), systemImage: "archivebox") {
          if let note { model.toggleArchived(note.id) }
        }
        .disabled(note == nil)
        .help("\(Model.archiveTitle(note))（⇧⌘A）")
        Menu(Model.colorTitle, systemImage: "paintpalette") {
          if let note { colorPicker(note) }
        }
        .disabled(note == nil)
        .help("换颜色（⌘. 换下一种）")
        Button(role: .destructive) {
          if let note { model.delete(note.id) }
        } label: {
          Label(Model.deleteTitle, systemImage: "trash").foregroundStyle(Style.danger)
        }
        .disabled(note == nil)
        .help("删除（⌘⌫），进「最近删除」")
      }
      Button(Model.newTitle, systemImage: HotKeyAction.noteNew.symbol) { model.create() }
        .help("新建便签（⌘N）")
    }
  }

  /// 右键菜单：和工具栏同名的那几项（不写键位，HIG）；破坏性的给 role，颜色由系统定
  @ViewBuilder private func menu(for note: Note) -> some View {
    if note.deletedAt != nil {
      Button(Model.restoreTitle) { model.restore(note.id) }
      Divider()
      Button(Model.eraseTitle, role: .destructive) { model.delete(note.id) }
      Button(Model.emptyTrashTitle, role: .destructive) { model.isEmptyingTrash = true }
    } else {
      Button(Model.pinTitle(note)) { model.togglePinned(note.id) }
      Button(Model.archiveTitle(note)) { model.toggleArchived(note.id) }
      Menu(Model.colorTitle) { colorPicker(note) }
      Divider()
      Button(Model.deleteTitle, role: .destructive) { model.delete(note.id) }
    }
  }

  /// 8 种纸色：圆点 + 名字，现在的那种打勾
  private func colorPicker(_ note: Note) -> some View {
    Picker(
      Model.colorTitle,
      selection: Binding {
        note.color
      } set: {
        model.setColor($0, of: note.id)
      }
    ) {
      ForEach(Array(NotePaper.all.enumerated()), id: \.offset) { index, paper in
        Label {
          Text(paper.name)
        } icon: {
          Image(nsImage: paper.swatch())
        }
        .tag(index)
      }
    }
    .pickerStyle(.inline)
    .labelsHidden()
  }

  /// 键盘。不挂在工具栏按钮上：窗口窄了工具栏项会收进「»」，挂在上面的键就跟着不灵。
  /// ⌘⌫ 不在这里：SwiftUI 的 .keyboardShortcut(.delete) 认的是字符 U+0008，⌫ 键按出来是 U+007F（屏外窗口里发合成按键
  /// 实测不触发），所以由窗口按键码认（NotesWindow.handlesKeyDown）
  private var shortcuts: some View {
    Group {
      Button("新建便签") { model.create() }.keyboardShortcut("n")
      Button("搜索") { model.focusSearch() }.keyboardShortcut("f")
      Button("撤销") { model.undo() }.keyboardShortcut("z")
      Button("归档") {
        if let id = model.selection { model.toggleArchived(id) }
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])
      Button("固定") {
        if let id = model.selection { model.togglePinned(id) }
      }
      .keyboardShortcut("p")
      Button("换颜色") {
        if let id = model.selection { model.cycleColor(id) }
      }
      .keyboardShortcut(".")
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

/// 列表的一行：纸色圆点、标题（固定的带图钉）、相对时间；下面一行预览。选中 = 中性高亮（原生的强调色高亮关掉自己画，
/// 同设置窗侧栏的做法；这里不反白：列表选中全 App 是中性的，mac-whisker §1）
private struct NoteRow: View {
  let note: Note
  let isSelected: Bool

  var body: some View {
    let paper = NotePaper.of(note)
    let preview = note.preview
    HStack(alignment: .top, spacing: 8) {
      // 圆点对着标题那一行的中线（标题行高 16）
      NoteDot(paper: paper).padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(note.displayTitle)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 4)
          if note.isPinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          Text(NotesWindowModel.ago(note)).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        Text(preview.isEmpty ? "没有更多内容" : preview)
          .font(.system(size: 12))
          .foregroundStyle(preview.isEmpty ? .tertiary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.vertical, 4)
    .background(NativeHighlightOff())
    .listRowBackground(isSelected ? highlight : nil)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [note.displayTitle, note.isPinned ? "已固定" : nil, paper.name, NotesWindowModel.ago(note)]
        .compactMap { $0 }.joined(separator: "，")
    )
    .accessibilityValue(preview)
  }

  /// 侧栏列表选中块的几何（同设置窗侧栏：左右各内缩 10、整行高）
  private var highlight: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    return shape.fill(Style.selectedFill)
      .overlay { shape.contrastSelectionBorder() }
      .padding(.horizontal, 10)
  }
}

/// 一条便签的编辑区：整块是它的纸色，字是墨色。最近删除里的只读（放回之后才能改）
private struct NoteEditor: View {
  let model: NotesWindowModel
  let note: Note
  let fontSize: CGFloat

  /// 标题、正文、底下小字共用的左右边线（设置窗边距 20）
  private static let margin: CGFloat = 20

  var body: some View {
    let paper = NotePaper.of(note)
    VStack(spacing: 0) {
      paper.strip.frame(height: 3).accessibilityHidden(true)
      if note.deletedAt == nil {
        // 标题框、正文框和屏幕边缘那叠里打开的便签是同一份（Notes/NoteFields.swift）。
        // NSTextField 自己左右各有 2 pt 的内缩：外面少留 2，字才和正文同一条左边线
        NoteTitleField(
          note: note, setTitle: { model.setTitle($0, of: note.id) }, onCommand: titleCommand
        )
        .padding(.horizontal, Self.margin - 2)
        .padding(.top, 14)
        .padding(.bottom, 4)
        // 滚动区铺满右边、文字缩进放在 horizontalInset 里（15 + NSTextView 自己的 5 = 20）：滚动条贴窗口右边
        NoteBodyField(
          note: note, fontSize: fontSize, margin: Self.margin,
          setBody: { model.setBody($0, of: note.id) }, onOverflow: model.overflowed)
      } else {
        readOnly(paper)
      }
      NoteFootnote(
        note: note, isOverLimit: model.isOverLimit, isUnsaved: model.store.saveProblem != nil
      )
      .padding(.horizontal, Self.margin)
      .frame(height: 28)
    }
    .background(paper.paper)
  }

  /// 标题框里 ↩、↓、Tab 都是去正文；Esc 不做事（普通窗口，不关）
  private func titleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)),
      #selector(NSResponder.insertTab(_:)):
      model.focusBody()
      return true
    case #selector(NSResponder.cancelOperation(_:)): return true
    default: return false
    }
  }

  /// 最近删除里的：标题和正文只读、能选中复制。
  /// ponytail: 正文整段交给一个 Text（1 MB 的正文排起来慢）；删掉的便签只是看一眼、放回再改，卡了再换成只读的文本框
  private func readOnly(_ paper: NotePaper) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        // 没起标题的不另写一行（列表里的标题取的就是正文第一行）
        if !note.title.isEmpty { Text(note.title).font(.system(size: 20, weight: .semibold)) }
        if !note.body.isEmpty { Text(note.body).font(.system(size: fontSize)) }
      }
      .foregroundStyle(paper.ink)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Self.margin)
      .padding(.top, 14)
    }
  }
}
