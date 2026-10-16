// 全部便签窗口的「便签墙」（默认的显示方式；另一种是列表，NotesWindowView 里的 NavigationSplitView）。长相在
// mac-whisker-notes.mdc「便签墙」，排法、倾斜、方向键、拖动排序的规则在 NoteWall.swift，状态在 NotesWindowModel。
// - 墙：一张张纸色的卡片（标题、正文开头几行带样式、任务进度、固定的带图钉、底下相对时间），一样宽、高随内容，
//   按窗口宽度排几列、竖排瀑布流；固定的一段在前。每张微微斜一点；鼠标停着的立正、稍微抬起来；选中的立正、
//   后面垫一块中性的选中底（列表选中不用强调色）。编辑卡开着时后面的卡片不认悬停。
// - 只画可见区附近的卡片（同剪贴板列表的 ListWindow：滚动位置按段记，跨段才重算画哪些）。位置全按排法算
//   （NotesWindowModel.wallLayout）——方向键、跟随滚动、拖动排序、编辑卡那块纸的起点终点都按它，不量视图。卡片的高：
//   可见区附近的当场建，往下的先按估计的高排，剩下的在后面几轮分批建好（第一次进墙、开关 Markdown 不再一口气全建）。
//   卡片上的字是一块 Canvas（NoteWallCard 量的高和画出来的是同一套排版），不是一个个 NSView：卡片要斜着、要缩放。
// - 点一张（或 ↩ / 空格）= 在窗口中央放大成编辑卡：后面一层暗；一块纸色的形状从卡片的位置长到中央，里面是列表视图
//   右栏那一套编辑区（NoteEditor）淡入——编辑区里有 NSTextView，不拿它做缩放。Esc、点暗处（双击卡片的第二下不算）、
//   ⌘W（NotesWindow 认）收回，收回前落盘（NotesWindowModel.collapse）；那块纸缩回那张卡片**收回那一刻**在窗口里的
//   位置（按那时的排法和滚动位置重算；卡片滚出了可见区、不在墙上就在中央淡掉）。不管从哪条路收回（删了、归档了、
//   放回了、在别处没了），焦点都回到墙上。减弱动态效果时只淡入淡出。
// - 分两层：墙本身是一个只看排法和卡片的子视图（WallBoard，Equatable），编辑卡那一层（暗、纸、编辑区）挂在外面
//   （NotesWall 的 overlay）。开 / 关编辑卡、纸长出来缩回去的每一帧，墙都不重新求值、不重排（放大着的那张淡掉由每张
//   卡片上的一小层 OpenFade 自己看 expanded）；原来整面墙跟着编辑卡一起求值，一次开关四五遍，300 条时每遍约 10 ms。
// - 键盘：方向键在卡片之间走、↩ / 空格打开、⌫ 删除（⌘⌫ 由窗口认）。
// - 点开和拖动排序是同一个手势（同屏幕边缘那叠的标签）：按下就开始跟，挪过 4 pt 才算拖（只在「全部」里、没在搜索时），
//   没到就是点了一下。落点只看拖动开始时那份排法（NoteWall.dropTarget）。
// - 右键菜单和列表行同一份（model.rowItems，系统菜单，ActionSystemMenu）。

import SwiftUI

struct NotesWall<Header: View, Empty: View, Footer: View>: View {
  @Bindable var model: NotesWindowModel
  /// 墙顶上那一条（分段、搜索框）、没有便签时的空状态、墙下面那一条（最近删除的「清空」）：和列表视图同一份
  @ViewBuilder var header: Header
  @ViewBuilder var empty: Empty
  @ViewBuilder var footer: Footer
  @AppStorage(Prefs.notesMarkdown) private var markdown = true
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  /// 墙拿着焦点（方向键、↩、⌫）：挂在 WallBoard 的滚动区上，什么时候拿由这里定（出来时、收回编辑卡时、wallFocus）
  @FocusState private var focused: Bool
  /// 滚到哪、墙多宽多高、墙顶上那一条多高：编辑卡那块纸的起点终点用。放在不被看着的盒子里：滚动时不重画墙
  @State private var spot = WallSpot()
  /// 编辑卡长出来 / 缩回去的那块纸（减弱动态效果时没有）
  @State private var sheet: WallSheet?

  var body: some View {
    VStack(spacing: 0) {
      header
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          spot.top = $0
        }
      if model.notes.isEmpty {
        empty
      } else {
        // 墙本身只看排法和卡片：开 / 关编辑卡、那块纸长出来缩回去的每一帧都不让它重新求值（这里重新求值时按 == 跳过）
        WallBoard(model: model, spot: spot, focus: $focused).equatable()
      }
      footer
    }
    .overlay { editorLayer }
    .onChange(of: model.expanded) { old, new in expandedChanged(from: old, to: new) }
    // 编辑卡开着的那条在别处被删了 / 归档了 / 放回了（屏幕边缘那叠、浮动便签里）：它不再是这个视图里选中的那条，收回
    .onChange(of: model.current?.id) {
      if model.expanded != nil, model.current?.id != model.expanded { model.collapse() }
    }
    .onChange(of: model.wallFocus) { focused = true }
    .onAppear {
      focused = true
      spot.isCovered = model.expanded != nil
      // 窗口出来时编辑卡已经开着（从那叠「在全部便签里打开」）：纸直接在中央
      if !reduceMotion, let id = model.expanded, let note = model.store.note(id) {
        sheet = WallSheet(id: id, color: note.color, from: nil, isGrown: true)
      }
    }
  }

  /// 编辑卡开了 / 收了（不管从哪条路：点开、↩、⌘N、从那叠打开；Esc、点暗处、⌘W、删除 / 归档 / 放回、换视图、在别处没了）。
  /// 收了：焦点回到墙上（方向键、↩、⌫ 接着用）；那块纸缩回那张卡片**现在**在窗口里的位置——按这一刻的排法和滚动位置
  /// 重算（开着的时候它可能挪了：固定了、改长了；收回的路上墙不动），它不在可见区里（滚走了、被筛掉了、删了）就在中央
  /// 略小一圈淡掉。开了：纸从那张卡片现在的位置长到中央
  private func expandedChanged(from old: String?, to new: String?) {
    spot.isCovered = new != nil
    if new == nil { focused = true }
    guard !reduceMotion else {
      sheet = nil
      return
    }
    if let new, let note = model.store.note(new) {
      sheet = WallSheet(id: new, color: note.color, from: source(of: new))
      return
    }
    guard let old, var closing = sheet, closing.id == old, !closing.isClosing else { return }
    closing.isClosing = true
    closing.to = source(of: old)
    let serial = closing.serial
    withAnimation(Style.Motion.settle.animation()) {
      sheet = closing
    } completion: {
      if sheet?.serial == serial { sheet = nil }
    }
  }

  // MARK: 编辑卡

  /// 放大着的那张：暗的一层 + 长到中央的纸 + 编辑区
  private var editorLayer: some View {
    GeometryReader { proxy in
      let size = NoteWall.editorSize(in: proxy.size)
      let target = CGRect(
        x: ((proxy.size.width - size.width) / 2).rounded(),
        y: ((proxy.size.height - size.height) / 2).rounded(), width: size.width, height: size.height
      )
      let note = model.isEditing ? model.current : nil
      ZStack(alignment: .topLeading) {
        if note != nil {
          Color.black.opacity(reduceTransparency ? NoteWall.solidDim : NoteWall.dim)
            .contentShape(.rect)
            .onTapGesture {
              // 双击一张卡片：第一下打开了编辑卡，第二下落在这层暗上——不算收回
              guard (NSApp.currentEvent?.clickCount ?? 1) < 2 else { return }
              model.collapse()
            }
            .accessibilityHidden(true)
            .transition(.opacity)
        }
        if let sheet {
          // 颜色跟着这条便签走（开着的时候换了色）；它没了就用记下的
          let color = model.store.note(sheet.id)?.color ?? sheet.color
          WallSheetPaper(
            paper: NotePaper.all[min(max(color, 0), NotePaper.all.count - 1)], sheet: sheet,
            target: target
          )
          .id(sheet.serial)
        }
        if let note {
          WallEditor(
            model: model, note: note, fontSize: Prefs.notesFontSize(fontSize),
            castsShadow: reduceMotion
          )
          .frame(width: size.width, height: size.height)
          .offset(x: target.minX, y: target.minY)
          .transition(
            reduceMotion
              ? .opacity
              : .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: Style.fadeIn).delay(0.08)),
                removal: .opacity.animation(.easeIn(duration: Style.fadeOut))))
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .animation(
        reduceMotion
          ? .easeInOut(duration: 0.2)
          : (model.expanded != nil ? Style.Motion.glide : Style.Motion.settle).animation(),
        value: model.expanded)
    }
  }

  /// 编号是 id 的那张卡片现在在这一块（墙连顶上那一条；编辑卡也摆在这里）里的位置：按现在的排法（仓库这一刻的样子、
  /// 墙的宽度）和滚动位置算；不在墙上、滚出了可见区给 nil（NoteWall.paperRect）。不看正拖着的那张让到了哪
  /// （拖着的时候按 ↩ 才会碰上：那张跟着指针、不在排法的格子里，按哪份排都不对）
  private func source(of id: String) -> CGRect? {
    let layout = model.wallLayout(
      model.wallGroups, width: spot.width,
      reach: WallBoard.reach(band: WallBoard.band(of: spot.scrollY), viewport: spot.viewport),
      markdown: markdown)
    return NoteWall.paperRect(
      card: layout.index(of: id).map { layout.frames[$0] }, top: spot.top, scrollY: spot.scrollY,
      viewport: spot.viewport)
  }
}

/// 墙本身（不连顶上那一条、编辑卡那一层）：卡片、小标题、只画可见区附近、方向键、拖动排序、跟随滚动。只看排法和卡片的
/// 数据、选中的那张——编辑卡开没开（expanded）不经过它，放大着的那张淡掉由每张卡片上的 OpenFade 自己看：开 / 关编辑卡、
/// 那块纸长出来缩回去的每一帧，墙都不重新求值、不重排（原来整面墙跟着编辑卡那一层一起求值，一次开关四五遍，300 条时
/// 每遍约 10 ms）。外面（NotesWall）重新求值时按 == 跳过：同一个模型、同一个盒子就是同一面墙（焦点的绑定指着
/// NotesWall 的同一个 FocusState，不用比）
private struct WallBoard: View, Equatable {
  let model: NotesWindowModel
  let spot: WallSpot
  let focus: FocusState<Bool>.Binding
  @AppStorage(Prefs.notesMarkdown) private var markdown = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 墙多宽（排几列）、可见区多高（画哪些）、滚到了第几段
  @State private var width: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  @State private var band = 0
  @State private var position = ScrollPosition()
  /// 选中跟随滚动用哪条曲线：键盘 snap、连发 instant、点选 glide
  @State private var motion = Style.Motion.snap
  @State private var drag: WallDrag?

  nonisolated static func == (a: Self, b: Self) -> Bool {
    a.model === b.model && a.spot === b.spot
  }

  /// 滚到 y（可见区的顶）时在第几段（同 TracksScrollBand）
  static func band(of y: CGFloat) -> Int { Int(max(y, 0) / ListWindow.bandHeight) }

  /// 可见区附近到哪（墙的坐标）：顶在这以内的卡片当场建（要画出来），往下的先按估计的高排。比要画的那一段
  /// （visible）的下沿还多一点：滚动位置按段记，这一段的下面一整段都算
  static func reach(band: Int, viewport: CGFloat) -> CGFloat {
    CGFloat(band + 1) * ListWindow.bandHeight + viewport + ListWindow.overscan
  }

  var body: some View {
    #if DEBUG
      model.wallEvaluations += 1
    #endif
    let (_, shown, layout) = arrangement()
    // 选中的、仓库在 ForEach 外面取一次：每张卡片各读一遍的话，每张都要单独挂一份「盯着它变」
    let (selection, canReorder) = (model.selection, model.canReorder)
    let items = visible(layout, keeping: [selection, drag?.id])
    return ScrollView {
      ZStack(alignment: .topLeading) {
        ForEach(layout.headers, id: \.title) { header in
          Text(header.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: header.frame.width, height: header.frame.height, alignment: .leading)
            .offset(x: header.frame.minX, y: header.frame.minY)
            .accessibilityAddTraits(.isHeader)
        }
        ForEach(items) { item in
          card(
            shown[item.index], at: item.index, in: layout, isSelected: item.id == selection,
            canReorder: canReorder)
        }
      }
      .frame(maxWidth: .infinity, minHeight: layout.height, alignment: .topLeading)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
        spot.width = $0
      }
      .contentShape(.rect)
      .onTapGesture { focus.wrappedValue = true }
      .coordinateSpace(.named(wallSpace))
      // 顺序变了（固定、删除、拖动让位）卡片滑到新位置；窗口改宽、打字变高不动画
      .animation(
        (drag == nil ? Style.Motion.settle : Style.Motion.glide).animation(reduced: reduceMotion),
        value: shown.map(\.id))
    }
    // 从空状态回来（没有便签 → 有了）这是一个新的滚动区，从顶上开始：滚动位置按段记的那两个跟着回到顶上——留着旧值
    // 的话按旧的段去画，顶上一片空白（同剪贴板面板、翻译历史）
    .onAppear {
      band = 0
      spot.scrollY = 0
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      viewportHeight = $0
      spot.viewport = $0
    }
    .onScrollGeometryChange(for: CGFloat.self) {
      $0.visibleRect.minY
    } action: {
      spot.scrollY = $1
    }
    .modifier(TracksScrollBand(band: $band))
    .modifier(
      RevealsSelection(
        position: $position, key: selection, motion: motion, coveredTop: NoteWall.margin,
        inset: NoteWall.margin, span: { span(of: model.selection, in: layout) })
    )
    // 正拖着的时候系统把这一下手势取消了（拖着时 ⌘⌫ 删了它、别处改了顺序、换了视图、打了搜索词），SwiftUI 不报松手：
    // 清掉，不然它一直悬在指针最后的地方
    .onChange(of: model.notes.map(\.id)) { drag = nil }
    .onChange(of: canReorder) { drag = nil }
    .focusable()
    .focused(focus)
    .focusEffectDisabled()
    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
      guard !model.isEditing else { return .ignored }
      let direction: NoteWall.Direction =
        switch press.key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        default: .right
        }
      motion = press.phase == .repeat ? .instant : .snap
      model.moveSelection(direction, in: arrangement().layout)
      return .handled
    }
    .onKeyPress(keys: [.return, .space]) { _ in
      guard !model.isEditing, let id = model.selection else { return .ignored }
      model.open(id)
      return .handled
    }
    .onDeleteCommand {
      if !model.isEditing, let id = model.selection { model.delete(id) }
    }
    .onExitCommand { model.collapse() }
  }

  /// 墙上现在的样子：notes 是仓库的顺序（分段排好）、base 按它排；拖着一张时 shown / layout 是让过位之后的
  private func arrangement() -> (base: NoteWall.Layout, shown: [Note], layout: NoteWall.Layout) {
    let groups = model.wallGroups
    let notes = groups.flatMap(\.notes)
    let reach = Self.reach(band: band, viewport: viewportHeight)
    let base = model.wallLayout(groups, width: width, reach: reach, markdown: markdown)
    guard let drag, drag.from != drag.to else { return (base, notes, base) }
    let shown = NoteWall.moved(notes, from: drag.from, to: drag.to)
    // 让过位之后各段的张数不变（只在同一段里挪）
    var moved: [(title: String?, notes: [Note])] = []
    var start = 0
    for group in groups {
      moved.append((group.title, Array(shown[start..<start + group.notes.count])))
      start += group.notes.count
    }
    return (
      base, shown, model.wallLayout(moved, width: width, reach: reach, markdown: markdown)
    )
  }

  /// 要画的卡片：可见区上下各多 overscan 里的（同 ListWindow：滚动位置按段记），加上选中的、正拖着的（拖到外面也在）
  private func visible(_ layout: NoteWall.Layout, keeping kept: [String?]) -> [WallItem] {
    let top = min(
      CGFloat(band) * ListWindow.bandHeight, max(layout.height - viewportHeight, 0))
    let lower = top - ListWindow.overscan
    let upper = top + ListWindow.bandHeight + viewportHeight + ListWindow.overscan
    return layout.frames.indices.compactMap { index in
      let frame = layout.frames[index]
      let id = layout.ids[index]
      guard (frame.maxY >= lower && frame.minY <= upper) || kept.contains(id) else { return nil }
      return WallItem(id: id, index: index)
    }
  }

  /// 选中的那张在墙上的竖直范围（跟随滚动用）；它是一段的第一排时连那一段的小标题
  private func span(of id: String?, in layout: NoteWall.Layout) -> ClosedRange<CGFloat>? {
    guard let index = id.flatMap(layout.index(of:)) else { return nil }
    let frame = layout.frames[index]
    let header = layout.headers.first { abs($0.frame.maxY - frame.minY) < 1 }
    return (header?.frame.minY ?? frame.minY)...frame.maxY
  }

  @ViewBuilder private func card(
    _ note: Note, at index: Int, in layout: NoteWall.Layout, isSelected: Bool, canReorder: Bool
  ) -> some View {
    let frame = layout.frames[index]
    let dragged = drag.flatMap { $0.id == note.id ? $0 : nil }
    let origin =
      dragged.map { CGPoint(x: $0.point.x - $0.grab.width, y: $0.point.y - $0.grab.height) }
      ?? frame.origin
    WallCard(
      note: note, card: model.store.wallCard(of: note, markdown: markdown),
      summary: model.store.summary(of: note), tilt: layout.tilts[index], isSelected: isSelected,
      isDragged: dragged != nil, spot: spot
    )
    .frame(width: frame.width, height: frame.height)
    // 放大成编辑卡的那张淡掉、收回时淡回来：它自己看着 expanded，墙不看
    .modifier(OpenFade(model: model, id: note.id))
    .contentShape(.rect)
    // 点开和拖动排序是同一个手势（同屏幕边缘那叠的标签）：不另挂 onTapGesture——两个手势挂在一起在 macOS 上分不分得清
    // 没验过；能不能拖动排序只在手势里面看（不能拖时照样点得开：.gesture(_, including: .none) 会连点按一起关掉）
    .gesture(cardGesture(note.id, canReorder: canReorder))
    // 系统菜单（右键、⌃ 点按才接），同列表行
    .overlay { ActionSystemMenu { model.rowItems(note) } }
    .accessibilityAction { model.open(note.id) }
    // 旁白的「更多动作」：右键菜单里不带子菜单的那几项（不带「颜色」那一级：每次重画都要，纸色圆点的图不白建）
    .accessibilityActions {
      ForEach(model.rowItems(note, colors: false)) { item in
        Button(item.title, action: item.run)
      }
    }
    .offset(x: origin.x, y: origin.y)
    // 被拖着的那张跟着指针走：别的卡片让位时它不跟着滑（松手那一下 drag 已经是 nil，照常落下去）
    .transaction { if dragged != nil { $0.animation = nil } }
    .zIndex(dragged != nil ? 1 : 0)
  }

  // MARK: 点开、拖动排序

  /// 按下就开始跟（minimumDistance 0，同屏幕边缘那叠的标签）：挪过 dragSlop 才算拖——只在能拖动排序时（「全部」里、
  /// 没在搜索），它跟着指针走、抬起来，指针进到同一段里另一张的里面时它让到那个位置，别的卡片滑开；松手写回仓库的顺序
  /// （NotesWindowModel.reorder）。没挪开就松手 = 点了一下 = 打开编辑卡。在不动的坐标系（墙的内容）里量：卡片自己正被
  /// offset 挪着
  private func cardGesture(_ id: String, canReorder: Bool) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(wallSpace))
      .onChanged { value in
        if drag == nil {
          guard canReorder,
            hypot(value.translation.width, value.translation.height) >= NoteWall.dragSlop
          else { return }
          let base = arrangement().base
          guard let from = base.index(of: id) else { return }
          let frame = base.frames[from]
          drag = WallDrag(
            id: id, from: from, to: from, point: value.location,
            grab: CGSize(
              width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
          )
        }
        guard let current = drag, current.id == id else { return }
        drag?.point = value.location
        // 落点只看拖动开始时那份排法（让位之前的）：只取决于指针在哪，不会在两个位置之间来回跳
        let to = NoteWall.dropTarget(
          from: current.from, current: current.to, at: value.location, in: arrangement().base)
        if to != current.to { drag?.to = to }
      }
      .onEnded { value in
        guard let current = drag, current.id == id else {
          // 没挪开：点了一下。双击的第二下也到这里——编辑卡已经开着，不再开一次
          if hypot(value.translation.width, value.translation.height) < NoteWall.dragSlop,
            !model.isEditing
          {
            motion = .glide
            model.open(id)
          }
          return
        }
        let base = arrangement().base
        if current.from != current.to, let section = base.section(of: current.from) {
          model.reorder(
            current.id, in: NoteWall.moved(base.ids, from: current.from, to: current.to),
            section: base.sections[section])
        }
        withAnimation(Style.Motion.glide.animation(reduced: reduceMotion)) { drag = nil }
      }
  }
}

/// 放大成编辑卡的那张：纸从它这里长出去，它自己淡掉；收回时淡回来。只有这一小层看着 expanded（墙不看）：开 / 关编辑卡时
/// 每张画着的卡片上只重新求值这一层、只改透明度
private struct OpenFade: ViewModifier {
  let model: NotesWindowModel
  let id: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let isOpen = model.expanded == id
    content
      .opacity(isOpen ? 0 : 1)
      .animation(
        reduceMotion ? .easeInOut(duration: 0.2) : Style.Motion.settle.animation(), value: isOpen)
  }
}

/// 墙上画的一张：编号（ForEach 的身份）和它在墙上的下标
private struct WallItem: Identifiable {
  let id: String
  let index: Int
}

/// 正拖着的那张：原来第几张、现在让到第几张、指针在哪（墙的坐标）、按下时指针离卡片左上角多远
private struct WallDrag: Equatable {
  let id: String
  let from: Int
  var to: Int
  var point: CGPoint
  let grab: CGSize
}

/// 不被看着的几样（见 NotesWall.spot）：滚到哪、墙多宽、可见区多高、墙顶上那一条多高（编辑卡那块纸的起点终点用，
/// WallBoard 量到了写进来）；编辑卡开着没有（卡片的悬停看它：鼠标进来那一刻才问，编辑卡开 / 关时不用把每张卡片都重画一遍）
final class WallSpot {
  var scrollY: CGFloat = 0
  var width: CGFloat = 0
  var viewport: CGFloat = 0
  var top: CGFloat = 0
  var isCovered = false
}

/// 墙的内容的坐标系（拖动在它里面量）
private let wallSpace = "notes-wall"

/// 一块纸摆在 rect 上（墙连顶上那一条的坐标）：编辑卡长出来、缩回去时动的就是它
private struct PaperFrame: ViewModifier {
  let rect: CGRect

  func body(content: Content) -> some View {
    content.frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
  }
}

/// 编辑卡那块纸的状态：哪条便签（颜色是打开时记下的，它没了时用）、从哪长出来（nil = 中央略小一圈）、收回中没有、
/// 缩到哪（nil = 中央略小一圈、淡掉）。每打开一次一个新的编号：收回的动画放完时认的是它（这时又打开了别的就不拆）
private struct WallSheet {
  let id: String
  let color: Int
  let from: CGRect?
  /// 打开时已经在中央（窗口出来时编辑卡就开着）
  var isGrown = false
  var isClosing = false
  var to: CGRect?
  let serial = WallSheet.next()

  init(id: String, color: Int, from: CGRect?, isGrown: Bool = false) {
    (self.id, self.color, self.from, self.isGrown) = (id, color, from, isGrown)
  }

  private static var counter = 0
  private static func next() -> Int {
    counter &+= 1
    return counter
  }
}

/// 编辑卡那块纸：打开时从起点长到中央（glide，出现的那一刻开始），收回时缩到终点（终点在外面算好、带着 settle 的动画给），
/// 没有终点就在中央略小一圈淡掉
private struct WallSheetPaper: View {
  let paper: NotePaper
  let sheet: WallSheet
  let target: CGRect
  @State private var grown = false

  var body: some View {
    let shrunk = target.insetBy(dx: NoteWall.paperInset, dy: NoteWall.paperInset)
    let rect =
      sheet.isClosing ? sheet.to ?? shrunk : grown || sheet.isGrown ? target : sheet.from ?? shrunk
    WallPaper(paper: paper)
      .modifier(PaperFrame(rect: rect))
      .opacity(sheet.isClosing && sheet.to == nil ? 0 : 1)
      .onAppear {
        withAnimation(Style.Motion.glide.animation()) { grown = true }
      }
  }
}

// MARK: 卡片

/// 墙上的一张：纸色的底、顶上 3 pt 色条、墨 14% 的发丝线、一点阴影（同屏幕边缘的标签：black 0.18 / r5 / y1；抬起来时
/// 0.30 / r10 / y4，同正拖着的标签）。上面是标题和正文开头几行（CardText）、右上角固定的图钉、底下一行小字和任务进度。
/// 斜着放；鼠标停着、正拖着的立正、放大 1.02、往上抬 2 pt（glide）；选中的立正，后面垫一块中性的选中底（snap）。
/// 截图自检单独画它（抬起来的那一张）
struct WallCard: View {
  let note: Note
  let card: NoteWallCard
  let summary: NoteStore.Summary
  let tilt: Double
  let isSelected: Bool
  let isDragged: Bool
  /// 墙的那几个不被看着的数：编辑卡开着（这张在暗层后面）时鼠标从上面过不立正、不抬起。nil = 不在墙上（截图自检）
  var spot: WallSpot?
  @State private var isHovered = false
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let paper = NotePaper.of(note)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let lifted = isHovered || isDragged
    ZStack {
      if isSelected {
        // 中性的选中底（列表选中不用强调色，mac-whisker §1）：比卡片四周各大 6，圆角跟着大
        let plate = RoundedRectangle(cornerRadius: Style.Radius.card + 6, style: .continuous)
        plate.fill(Style.selectedFill)
          .overlay { plate.contrastSelectionBorder() }
          .padding(-6)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 0) {
        paper.strip.frame(height: NoteWall.stripHeight)
        // 卡片顶上那张缩略图（正文里的第一张图；高按元数据算，墙的排法只看量出来的高）
        if let thumbnail = card.thumbnail, card.thumbnailURL != nil, card.thumbnailHeight > 0 {
          WallThumbnail(
            url: card.thumbnailURL, image: thumbnail, paper: paper, displayScale: displayScale
          )
          .frame(width: NoteWall.textWidth, height: card.thumbnailHeight)
          .clipShape(
            RoundedRectangle(cornerRadius: NoteImageLayout.corner, style: .continuous)
          )
          .padding(.top, NoteWall.topInset)
          .padding(.horizontal, NoteWall.padding)
        }
        CardText(card: card, scheme: scheme, contrast: contrast)
          .equatable()
          .frame(width: NoteWall.textWidth, height: card.textHeight, alignment: .topLeading)
          .mask { fade }
          .padding(.top, card.thumbnail == nil ? NoteWall.topInset : NoteImageLayout.thumbnailGap)
          .padding(.horizontal, NoteWall.padding)
        Spacer(minLength: 0)
        footer(paper)
          .frame(height: NoteWall.footerHeight)
          .padding(.horizontal, NoteWall.padding)
          .padding(.bottom, NoteWall.bottomInset)
      }
      .background(paper.paper)
      .clipShape(shape)
      .overlay { shape.hairlineBorder(paper.rule(contrast)) }
      .overlay(alignment: .topTrailing) {
        if note.isPinned {
          Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(paper.secondaryInk)
            .padding(.top, NoteWall.stripHeight + NoteWall.topInset + 3)
            .padding(.trailing, NoteWall.padding)
            .accessibilityHidden(true)
        }
      }
      .background {
        shape.fill(paper.paper)
          .shadow(
            color: .black.opacity(lifted ? 0.30 : 0.18), radius: lifted ? 10 : 5,
            y: lifted ? 4 : 1)
      }
      .scaleEffect(lifted ? 1.02 : 1)
      .offset(y: lifted ? -2 : 0)
      .rotationEffect(.degrees(lifted || isSelected ? 0 : tilt))
    }
    .animation(Style.Motion.glide.animation(reduced: reduceMotion), value: lifted)
    .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: isSelected)
    .background { HoverTracker { isHovered = $0 && spot?.isCovered != true } }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [
        summary.title, note.isPinned ? "已固定" : nil, paper.name,
        summary.progress.map(Note.progressSpoken), NotesWindowModel.ago(note),
      ]
      .compactMap { $0 }.joined(separator: "，")
    )
    .accessibilityValue(summary.preview)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  /// 正文超出时底下渐隐（渐变蒙版，不是位图）
  @ViewBuilder private var fade: some View {
    if card.overflows {
      VStack(spacing: 0) {
        Color.black
        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
          .frame(height: NoteWall.fadeHeight)
      }
    } else {
      Color.black
    }
  }

  /// 底下一行：相对时间（最近删除里是删的时间），有任务的右边写进度
  private func footer(_ paper: NotePaper) -> some View {
    HStack(spacing: 6) {
      Text(NotesWindowModel.ago(note))
        .font(.system(size: 11))
        .foregroundStyle(paper.secondaryInk)
        .lineLimit(1)
      Spacer(minLength: 4)
      if let progress = summary.progress {
        NoteProgress(progress: progress).foregroundStyle(paper.secondaryInk)
      }
    }
  }
}

/// 卡片顶上那张缩略图（正文里的第一张图）：后台解、解好了再画，解码前占着同样大的一块纸色；
/// 高按比例（用元数据算好的 card.thumbnailHeight），超出的裁掉、居中。**屏外出图里画得出来**（真解一张缩略图）
private struct WallThumbnail: View {
  let url: URL?
  let image: NoteImages.Image
  let paper: NotePaper
  let displayScale: CGFloat
  /// 缓存里已经有的话建视图时就拿上（不然第一帧画的是纸色，等那一轮状态更新才变）
  private let key: String
  @State private var decoded: CGImage?

  init(url: URL?, image: NoteImages.Image, paper: NotePaper, displayScale: CGFloat) {
    self.url = url
    self.image = image
    self.paper = paper
    self.displayScale = displayScale
    let maxPixel = Int(NoteWall.textWidth * max(displayScale, 1))
    key = "wall-\(image.id.uuidString)@\(maxPixel)"
    _decoded = State(initialValue: NoteImageThumbnails.peek(key: key))
  }

  var body: some View {
    let cached = NoteImageThumbnails.peek(key: key)
    return ZStack {
      paper.paper
      // 缓存里已经有就直接画（那一轮状态更新还没回来时也能画出来：屏外出图 / 刚解好）
      if let image = decoded ?? cached {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }
    }
    .clipped()
    .accessibilityHidden(true)
    .task(id: image.id) {
      guard let url else { return }
      decoded = await NoteImageThumbnails.load(
        for: url, key: key, maxPixel: Int(NoteWall.textWidth * max(displayScale, 1)))
    }
  }
}

/// 卡片上的字：标题（一两行，排不下的末尾「…」）和正文开头几行，NoteWallCard 量高时用的同一套排版画出来。
/// 卡片没换（同一个 NoteWallCard、同一种外观、增强对比度没开关）就不重画：悬停、选中、滑动时只动外面的变换。
/// 增强对比度要比：纸上的墨、标记、做完的任务是跟着它变的动态色（NotePaper），开关一换得重画
private struct CardText: View, Equatable {
  let card: NoteWallCard
  let scheme: ColorScheme
  let contrast: ColorSchemeContrast

  nonisolated static func == (a: Self, b: Self) -> Bool {
    a.card === b.card && a.scheme == b.scheme && a.contrast == b.contrast
  }

  var body: some View {
    let card = card
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    Canvas { context, _ in
      context.withCGContext { cg in
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        // 纸色、墨是动态色：按卡片的外观取
        let draw = {
          card.title.draw(
            with: CGRect(x: 0, y: 0, width: card.titleWidth, height: card.titleHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil)
          if card.body.length > 0 {
            card.body.draw(
              with: CGRect(
                x: 0, y: card.titleHeight + NoteWall.titleGap, width: NoteWall.textWidth,
                height: card.bodyHeight),
              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
          }
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
        NSGraphicsContext.restoreGraphicsState()
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: 编辑卡

/// 编辑卡长出来、缩回去时动的那块纸：纸色、顶上色条、发丝线、浮起来的阴影（面板里浮起来的东西，floatingShadow）。
/// 放大着的时候它垫在编辑区下面（阴影是它的）
private struct WallPaper: View {
  let paper: NotePaper
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    shape.fill(paper.paper)
      .overlay(alignment: .top) { paper.strip.frame(height: NoteWall.stripHeight) }
      .clipShape(shape)
      .background { shape.fill(paper.paper).floatingShadow() }
      .overlay { shape.hairlineBorder(paper.rule(contrast)) }
      .accessibilityHidden(true)
  }
}

/// 编辑卡：列表视图右栏那一套编辑区（NoteEditor：标题框、正文、底下小字），切成卡片的圆角、描一道发丝线；
/// 最近删除里的只读，右下角多「放回」「永久删除…」。是一组「便签「标题」」。
/// castsShadow：自己画阴影（减弱动态效果时没有那块长出来的纸垫着）
private struct WallEditor: View {
  let model: NotesWindowModel
  let note: Note
  let fontSize: CGFloat
  let castsShadow: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  private typealias Model = NotesWindowModel

  var body: some View {
    let paper = NotePaper.of(note)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    NoteEditor(model: model, note: note, fontSize: fontSize, onClose: { model.collapse() })
      .id(note.id)
      .clipShape(shape)
      .background {
        if castsShadow { shape.fill(paper.paper).floatingShadow() }
      }
      .overlay { shape.hairlineBorder(paper.rule(contrast)) }
      .overlay(alignment: .bottomTrailing) {
        if note.deletedAt != nil {
          HStack(spacing: 8) {
            Button(Model.restoreTitle) { model.restore(note.id) }
            DangerButton(Model.eraseTitle) { model.delete(note.id) }
          }
          .controlSize(.small)
          .padding(.trailing, 20)
          .frame(height: 28)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("便签「\(model.store.summary(of: note).title)」")
      .onExitCommand { model.collapse() }
  }
}
