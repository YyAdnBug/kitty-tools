// 全部便签窗口的界面（系统皮肤的普通窗口，mac-whisker-notes.mdc「全部便签」；窗口和状态在 NotesWindow.swift）。
// 两种显示方式，工具栏上切（⌘1 / ⌘2，记住上次选的）：**便签墙**（默认，NotesWallView.swift：一张张卡片，点一张放大
// 成编辑卡；顶上一条是同一个分段和搜索框）和**列表**（下面这些）。选中的那条两边共用。
// 列表：NavigationSplitView 两栏。左：顶上分段「全部 / 归档 / 最近删除」（带条数）→ 搜索框 → 列表（行 = 纸色圆点、标题、
// 一行预览、相对时间，固定的带图钉；选中是中性高亮；「全部」里没在搜索时能拖动排序）。右：这条便签——整块是它的纸色，
// 顶上一条色条，标题框、正文、底下一行小字（改于什么时候、多少字；这三件在 NoteFields.swift，和屏幕边缘那叠共用）；
// 最近删除里的只读，列表下面多一行「清空最近删除…」。操作在工具栏和右键菜单里，名字取自 NotesWindowModel 的同一份；
// 工具栏是单独的一个视图（NotesToolbar），只拿画得出来的那几样：换一条便签时它们没变，工具栏就不重建（重建一次很贵）。
// 列表行上的标题、摘要、任务进度走仓库的缓存（NoteStore.summary）。键盘挂在看不见的按钮上（shortcuts）。选颜色：工具栏那个按钮弹的是系统菜单（NSMenu.of：SwiftUI 的 Menu 放进工具栏
// 不画纸色圆点），行的右键菜单也是系统菜单（ActionSystemMenu，同样的原因），里面的「颜色」是同一份表（NotePaper.colorItems）。

import SwiftUI

struct NotesWindowView: View {
  @Bindable var model: NotesWindowModel
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15
  @FocusState private var searchFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private typealias Model = NotesWindowModel

  var body: some View {
    Group {
      switch model.layout {
      case .list:
        NavigationSplitView {
          sidebar.navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
          detail
            .navigationTitle(HotKeyAction.noteAll.title)
        }
        .toolbar(removing: .sidebarToggle)
      case .wall:
        NotesWall(model: model) {
          wallHeader
        } empty: {
          empty.padding(20)
        } footer: {
          if model.scope == .trash, !model.list(.trash).isEmpty { trashBar(inset: NoteWall.margin) }
        }
        .navigationTitle(HotKeyAction.noteAll.title)
      }
    }
    .background { NotesToolbar(model: model, state: model.toolbarState).equatable() }
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
      scopePicker
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
      searchField.padding(.horizontal, 10)
      list
      if model.scope == .trash, !model.list(.trash).isEmpty { trashBar(inset: 10) }
    }
  }

  /// 系统分段「全部 N / 归档 N / 最近删除 N」（0 条不写数）：列表的左栏、便签墙顶上那一条同一个
  private var scopePicker: some View {
    Picker("视图", selection: $model.scope) {
      ForEach(Model.Scope.allCases) { scope in
        let count = model.list(scope).count
        Text(count > 0 ? "\(scope.title) \(count)" : scope.title).tag(scope)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }

  /// 便签墙顶上那一条：左边分段、右边搜索框（宽 240），左右和墙的边线对齐（20），下面一条发丝线
  private var wallHeader: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        scopePicker.fixedSize()
        Spacer(minLength: 0)
        searchField.frame(width: 240)
      }
      .padding(.horizontal, NoteWall.margin)
      .padding(.vertical, 8)
      Hairline()
    }
  }

  /// 最近删除的列表下面：留多久 + 清空（危险色的系统按钮，mac-whisker §3「危险色」）。inset：左右边距——列表左栏 10、
  /// 便签墙 20（和墙的边线对齐）
  private func trashBar(inset: CGFloat) -> some View {
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
      .padding(.horizontal, inset)
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

  /// 选中的、仓库在 ForEach 外面取一次：每一行各读一遍 model.selection 的话，每一行都要单独挂一份「盯着它变」，
  /// 几百行时一次重画光这一项就占一成多（手测反馈第 3 批 sample 出来的）
  @ViewBuilder private var list: some View {
    let notes = model.notes
    let (selection, store) = (model.selection, model.store)
    if notes.isEmpty {
      empty.padding(20)
    } else {
      List(selection: $model.selection) {
        ForEach(notes) { note in
          NoteRow(note: note, store: store, isSelected: note.id == selection)
            .tag(note.id)
            // 系统菜单，不用 .contextMenu：SwiftUI 桥出来的右键菜单不带「颜色」每一项前面的纸色圆点
            .overlay { ActionSystemMenu { model.rowItems(note) } }
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

  /// 键盘。不挂在工具栏按钮上：窗口窄了工具栏项会收进「»」，挂在上面的键就跟着不灵。
  /// ⌘⌫ 不在这里：SwiftUI 的 .keyboardShortcut(.delete) 认的是字符 U+0008，⌫ 键按出来是 U+007F（屏外窗口里发合成按键
  /// 实测不触发），所以由窗口按键码认（NotesWindow.handlesKeyDown；⇧⌘Z 重做也在那里）
  private var shortcuts: some View {
    Group {
      Button("新建便签") { model.create() }.keyboardShortcut("n")
      // ⌘F：焦点在正文里是便签内查找，否则去搜索框（NotesWindowModel.find）
      Button("查找") { model.find() }.keyboardShortcut("f")
      // 墙上没开编辑卡时没有「光标所在的那一行」：同工具栏的「任务」置灰，⌘T 不接（系统响一声）
      Button(Model.taskTitle) { model.toggleTask() }.keyboardShortcut("t")
        .disabled(!model.toolbarState.canTask)
      // ⇧⌘Z 重做不挂在这里：同一个字母再挂一个带 ⇧ 的，⌘Z 会被它抢走（由窗口的按键监听认，NotesWindow.handlesKeyDown）
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
      Button(Model.settingsTitle) { model.openSettings() }.keyboardShortcut(",")
      // ⌘1 / ⌘2：便签墙 / 列表（同工具栏上的切换）
      ForEach(Array(Model.Layout.allCases.enumerated()), id: \.element) { index, layout in
        Button(layout.title) { model.layout = layout }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
      }
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

/// 工具栏（窗口的统一工具栏，右边一组）。单独一个视图、只拿 state（名字、符号、能不能点）：选中的换了一条而这些没变时
/// SwiftUI 不再算它的 body（.equatable），工具栏不重建。点了才去问现在选中的是哪条（model.current）
private struct NotesToolbar: View, Equatable {
  let model: NotesWindowModel
  let state: NotesWindowModel.ToolbarState

  private typealias Model = NotesWindowModel

  nonisolated static func == (a: Self, b: Self) -> Bool {
    a.state == b.state && a.model === b.model
  }

  var body: some View {
    Color.clear.toolbar {
      // 显示方式：便签墙 / 列表（⌘1 / ⌘2），系统的分段、只放符号
      ToolbarItem(placement: .primaryAction) {
        Picker(
          "显示方式",
          selection: Binding {
            state.layout
          } set: {
            model.layout = $0
          }
        ) {
          ForEach(Model.Layout.allCases) { layout in
            Label(layout.title, systemImage: layout.symbol).tag(layout)
          }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("便签墙（⌘1）/ 列表（⌘2）")
      }
      ToolbarItemGroup(placement: .primaryAction) {
        if state.isTrash {
          Button(Model.restoreTitle, systemImage: "arrow.uturn.backward") {
            if let note = model.current { model.restore(note.id) }
          }
          .disabled(!state.hasNote)
          .help(Model.restoreTitle)
          Button(role: .destructive) {
            if let note = model.current { model.delete(note.id) }
          } label: {
            Label(Model.eraseTitle, systemImage: "trash.slash").foregroundStyle(Style.danger)
          }
          .disabled(!state.hasNote)
          .help("永久删除（⌘⌫）")
        } else {
          Button(state.pinTitle, systemImage: state.pinSymbol) {
            if let note = model.current { model.togglePinned(note.id) }
          }
          .disabled(!state.hasNote)
          .help("\(state.pinTitle)（⌘P）")
          Button(state.archiveTitle, systemImage: "archivebox") {
            if let note = model.current { model.toggleArchived(note.id) }
          }
          .disabled(!state.hasNote)
          .help("\(state.archiveTitle)（⇧⌘A）")
          Button(Model.taskTitle, systemImage: Model.taskSymbol) { model.toggleTask() }
            .disabled(!state.canTask)
            .help(Model.taskHelp)
          // 系统菜单，不用 SwiftUI 的 Menu：放进工具栏的 Menu 不画每一项前面的纸色圆点（2026-10-13 真机）
          Button(Model.colorTitle, systemImage: "paintpalette") {
            if let note = model.current { NSMenu.of(model.colorItems(note)).popUpAtPointer() }
          }
          .disabled(!state.hasNote)
          .help("换颜色（⌘. 换下一种）")
          // 浮动便签（第 4 批）：屏幕边缘关着时，这是把一条便签留在屏幕上的入口。归档里的不能浮着
          Button(state.floatTitle, systemImage: state.floatSymbol) {
            if let note = model.current { model.toggleFloating(note.id) }
          }
          .disabled(!state.canFloat)
          .help(state.floatTitle)
          Button(role: .destructive) {
            if let note = model.current { model.delete(note.id) }
          } label: {
            Label(Model.deleteTitle, systemImage: "trash").foregroundStyle(Style.danger)
          }
          .disabled(!state.hasNote)
          .help("删除（⌘⌫），进「最近删除」")
        }
        Button {
          model.create()
        } label: {
          Label {
            Text(Model.newTitle)
          } icon: {
            Image(symbol: HotKeyAction.noteNew.symbol)
          }
        }
        .help("新建便签（⌘N）")
        // 手测反馈第 3 批：去设置的快捷入口，落在「便签」那一页
        Button(Model.settingsTitle, systemImage: Model.settingsSymbol) { model.openSettings() }
          .help("\(Model.settingsTitle)（⌘,）")
      }
    }
  }
}

/// 列表的一行：纸色圆点、标题（固定的带图钉）、相对时间；下面一行预览。选中 = 中性高亮（原生的强调色高亮关掉自己画，
/// 同设置窗侧栏的做法；这里不反白：列表选中全 App 是中性的，mac-whisker §1）。标题、摘要、任务进度走仓库的缓存
private struct NoteRow: View {
  let note: Note
  let store: NoteStore
  let isSelected: Bool

  var body: some View {
    let paper = NotePaper.of(note)
    let summary = store.summary(of: note)
    let preview = summary.preview
    let progress = summary.progress
    HStack(alignment: .top, spacing: 8) {
      // 圆点对着标题那一行的中线（标题行高 16）
      NoteDot(paper: paper).padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(summary.title)
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
        HStack(spacing: 6) {
          Text(preview.isEmpty ? "没有更多内容" : preview)
            .font(.system(size: 12))
            .foregroundStyle(preview.isEmpty ? .tertiary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
          // 有任务的：预览那一行的右边写做完几条 / 共几条
          if let progress {
            Spacer(minLength: 4)
            NoteProgress(progress: progress).foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 4)
    .background(NativeHighlightOff())
    .listRowBackground(isSelected ? highlight : nil)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [
        summary.title, note.isPinned ? "已固定" : nil, paper.name,
        progress.map(Note.progressSpoken), NotesWindowModel.ago(note),
      ]
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

/// 一条便签的编辑区：整块是它的纸色，字是墨色。最近删除里的只读（放回之后才能改）。
/// 列表视图的右栏、便签墙的编辑卡（NotesWallView）同一份
struct NoteEditor: View {
  let model: NotesWindowModel
  let note: Note
  let fontSize: CGFloat
  /// 便签墙的编辑卡：标题框、正文里按 Esc 收回它；nil = 列表的右栏（普通窗口，Esc 不做事）
  var onClose: (() -> Void)?

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
          setBody: { model.setBody($0, of: note.id) }, onOverflow: model.overflowed,
          onCancel: onClose ?? {}, undo: model.textUndo, images: model.store.images,
          imageArrivals: model.store.imageArrivals, onImageProblem: model.imageProblem)
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

  /// 标题框里 ↩、↓、Tab 都是去正文；Esc 在便签墙的编辑卡里是收回，列表里不做事（普通窗口，不关）
  private func titleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)),
      #selector(NSResponder.insertTab(_:)):
      model.focusBody()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    default: return false
    }
  }

  /// 最近删除里的：标题和正文只读、能选中复制。**图片的令牌换成「[图片]」**（`note.readOnlyBody`，F11）：只读视图
  /// 不带任务 / Markdown 的样式、也不把令牌换成附图，露着 `![image](kitty-note-image://…)` 没有意义。
  /// ponytail: 正文整段交给一个 Text（1 MB 的正文排起来慢），不带任务 / Markdown 的样式（看到的是带标记的原文）；
  /// 删掉的便签只是看一眼、放回再改，卡了、或者要和编辑时长得一样，再换成只读的文本框（NoteTextView 认 isEditable）
  private func readOnly(_ paper: NotePaper) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        // 没起标题的不另写一行（列表里的标题取的就是正文第一行）
        if !note.title.isEmpty { Text(note.title).font(.system(size: 20, weight: .semibold)) }
        if !note.body.isEmpty { Text(note.readOnlyBody).font(.system(size: fontSize)) }
      }
      .foregroundStyle(paper.ink)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Self.margin)
      .padding(.top, 14)
    }
  }
}
