// 全部便签窗口的「便签墙」（默认的显示方式；另一种是列表，NotesWindowView 里的 NavigationSplitView）。长相在
// mac-whisker-notes.mdc「便签墙」，排法、倾斜、方向键、拖动排序的规则在 NoteWall.swift，状态在 NotesWindowModel。
// - 墙：一张张纸色的卡片（标题、正文开头几行带样式、任务进度、固定的带图钉、底下相对时间），一样宽、高随内容，
//   按窗口宽度排几列、竖排瀑布流；固定的一段在前。每张微微斜一点；鼠标停着的立正、稍微抬起来；选中的立正、
//   后面垫一块中性的选中底（列表选中不用强调色）。
// - 只画可见区附近的卡片（同剪贴板列表的 ListWindow：滚动位置按段记，跨段才重算画哪些）。位置全按 NoteWall.layout
//   算——方向键、跟随滚动、拖动排序、放大的起点都按它，不量视图。卡片上的字是一块 Canvas（NoteWallCard 量的高和
//   画出来的是同一套排版），不是一个个 NSView：卡片要斜着、要缩放。
// - 点一张（或 ↩ / 空格）= 在窗口中央放大成编辑卡：后面一层暗；一块纸色的形状从卡片的位置长到中央，里面是列表视图
//   右栏那一套编辑区（NoteEditor）淡入——编辑区里有 NSTextView，不拿它做缩放。Esc、点暗处、⌘W（NotesWindow 认）
//   收回，收回前落盘（NotesWindowModel.collapse）。减弱动态效果时只淡入淡出。
// - 键盘：方向键在卡片之间走、↩ / 空格打开、⌫ 删除（⌘⌫ 由窗口认）；拖动排序只在「全部」里、没在搜索时。
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
  @FocusState private var focused: Bool
  /// 墙多宽（排几列）、可见区多高（画哪些）、滚到了第几段
  @State private var width: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  @State private var band = 0
  @State private var position = ScrollPosition()
  /// 选中跟随滚动用哪条曲线：键盘 snap、连发 instant、点选 glide
  @State private var motion = Style.Motion.snap
  @State private var drag: WallDrag?
  /// 滚到哪、墙顶上那一条多高：放大编辑卡时算起点用。放在不被看着的盒子里：滚动时不重画墙
  @State private var spot = WallSpot()

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
        board
      }
      footer
    }
    .overlay { editorLayer }
    .onChange(of: model.wallFocus) { focused = true }
    .onAppear { focused = true }
  }

  // MARK: 墙

  /// 墙上现在的样子：notes 是仓库的顺序（分段排好）、base 按它排；拖着一张时 shown / layout 是让过位之后的
  private func arrangement() -> (base: NoteWall.Layout, shown: [Note], layout: NoteWall.Layout) {
    let groups = model.wallGroups
    let notes = groups.flatMap(\.notes)
    let counts = groups.map(\.notes.count)
    let titles = groups.map(\.title)
    let base = arrange(notes, counts: counts, titles: titles)
    guard let drag, drag.from != drag.to else { return (base, notes, base) }
    let shown = NoteWall.moved(notes, from: drag.from, to: drag.to)
    return (base, shown, arrange(shown, counts: counts, titles: titles))
  }

  private func arrange(_ notes: [Note], counts: [Int], titles: [String?]) -> NoteWall.Layout {
    var sections: [NoteWall.Section] = []
    var start = 0
    for (count, title) in zip(counts, titles) {
      let slice = notes[start..<start + count]
      sections.append(
        NoteWall.Section(
          title: title, ids: slice.map(\.id),
          heights: slice.map { model.card($0, markdown: markdown).height }))
      start += count
    }
    return NoteWall.layout(sections, width: width)
  }

  private var board: some View {
    let (base, shown, layout) = arrangement()
    // 选中的、放大着的、仓库在 ForEach 外面取一次：每张卡片各读一遍的话，每张都要单独挂一份「盯着它变」
    let (selection, expanded, canReorder) = (model.selection, model.expanded, model.canReorder)
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
            shown[item.index], at: item.index, in: layout, base: base,
            isSelected: item.id == selection, isOpen: item.id == expanded, canReorder: canReorder)
        }
      }
      .frame(maxWidth: .infinity, minHeight: layout.height, alignment: .topLeading)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
      .contentShape(.rect)
      .onTapGesture { focused = true }
      .coordinateSpace(.named(wallSpace))
      // 顺序变了（固定、删除、拖动让位）卡片滑到新位置；窗口改宽、打字变高不动画
      .animation(
        (drag == nil ? Style.Motion.settle : Style.Motion.glide).animation(reduced: reduceMotion),
        value: shown.map(\.id))
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      viewportHeight = $0
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
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
      guard model.expanded == nil else { return .ignored }
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
      guard model.expanded == nil, let id = model.selection else { return .ignored }
      model.open(id)
      return .handled
    }
    .onDeleteCommand {
      if model.expanded == nil, let id = model.selection { model.delete(id) }
    }
    .onExitCommand { model.collapse() }
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
    _ note: Note, at index: Int, in layout: NoteWall.Layout, base: NoteWall.Layout,
    isSelected: Bool, isOpen: Bool, canReorder: Bool
  ) -> some View {
    let frame = layout.frames[index]
    let dragged = drag.flatMap { $0.id == note.id ? $0 : nil }
    let origin =
      dragged.map { CGPoint(x: $0.point.x - $0.grab.width, y: $0.point.y - $0.grab.height) }
      ?? frame.origin
    let summary = model.store.summary(of: note)
    WallCard(
      note: note, card: model.card(note, markdown: markdown), summary: summary,
      tilt: layout.tilts[index], isSelected: isSelected, isDragged: dragged != nil
    )
    .frame(width: frame.width, height: frame.height)
    // 放大成编辑卡的那张：纸从它这里长出去，它自己淡掉；收回时淡回来
    .opacity(isOpen ? 0 : 1)
    .animation(
      reduceMotion ? .easeInOut(duration: 0.2) : Style.Motion.settle.animation(), value: isOpen
    )
    .contentShape(.rect)
    .onTapGesture {
      motion = .glide
      model.open(note.id)
    }
    .gesture(dragGesture(note.id), including: canReorder ? .all : .none)
    // 系统菜单（右键、⌃ 点按才接），同列表行
    .overlay { ActionSystemMenu { model.rowItems(note) } }
    .accessibilityAction { model.open(note.id) }
    .accessibilityActions {
      ForEach(model.rowItems(note).filter { $0.submenu == nil }) { item in
        Button(item.title, action: item.run)
      }
    }
    .offset(x: origin.x, y: origin.y)
    .zIndex(dragged != nil ? 1 : 0)
  }

  // MARK: 拖动排序

  /// 按住一张拖：它跟着指针走，指针进到同一段里另一张的里面（四边各收 dragInset）时它让到那个位置，别的卡片滑开；
  /// 松手写回仓库的顺序（NotesWindowModel.reorder）。在不动的坐标系（墙的内容）里量：卡片自己正被 offset 挪着
  private func dragGesture(_ id: String) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(wallSpace))
      .onChanged { value in
        guard let current = drag else {
          let base = arrangement().base
          guard let from = base.index(of: id) else { return }
          let frame = base.frames[from]
          drag = WallDrag(
            id: id, from: from, to: from, point: value.location,
            grab: CGSize(
              width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
          )
          return
        }
        drag?.point = value.location
        let layout = arrangement().layout
        guard
          let over = NoteWall.item(at: value.location, in: layout, inset: NoteWall.dragInset),
          over != current.to, let to = NoteWall.landing(from: current.to, over: over, in: layout)
        else { return }
        drag?.to = to
      }
      .onEnded { _ in
        guard let current = drag else { return }
        let base = arrangement().base
        if current.from != current.to, let section = base.section(of: current.from) {
          model.reorder(
            current.id, in: NoteWall.moved(base.ids, from: current.from, to: current.to),
            section: base.sections[section])
        }
        withAnimation(Style.Motion.glide.animation(reduced: reduceMotion)) { drag = nil }
      }
  }

  // MARK: 编辑卡

  /// 放大着的那张：暗的一层 + 长到中央的纸 + 编辑区。纸的起点是那张卡片现在在窗口里的位置（墙上的位置 − 滚过的 +
  /// 顶上那一条）；它不在墙上（被搜索词筛掉了）就从中央略小一点长出来
  private var editorLayer: some View {
    GeometryReader { proxy in
      let size = NoteWall.editorSize(in: proxy.size)
      let target = CGRect(
        x: ((proxy.size.width - size.width) / 2).rounded(),
        y: ((proxy.size.height - size.height) / 2).rounded(), width: size.width, height: size.height
      )
      ZStack(alignment: .topLeading) {
        if let note = model.current, model.expanded == note.id {
          Color.black.opacity(reduceTransparency ? NoteWall.solidDim : NoteWall.dim)
            .contentShape(.rect)
            .onTapGesture { model.collapse() }
            .accessibilityHidden(true)
            .transition(.opacity)
          if !reduceMotion {
            WallPaper(paper: NotePaper.of(note))
              .transition(
                .modifier(
                  active: PaperFrame(rect: source(of: note.id) ?? target.insetBy(dx: 24, dy: 24)),
                  identity: PaperFrame(rect: target)))
          }
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

  /// 编号是 id 的那张卡片现在在这一块（墙连顶上那一条）里的位置
  private func source(of id: String) -> CGRect? {
    let layout = arrangement().layout
    guard let index = layout.index(of: id) else { return nil }
    return layout.frames[index].offsetBy(dx: 0, dy: spot.top - spot.scrollY)
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

/// 不被看着的两个数（见 NotesWall.spot）
private final class WallSpot {
  var scrollY: CGFloat = 0
  var top: CGFloat = 0
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
  @State private var isHovered = false
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme
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
        CardText(card: card, scheme: scheme)
          .equatable()
          .frame(width: NoteWall.textWidth, height: card.textHeight, alignment: .topLeading)
          .mask { fade }
          .padding(.top, NoteWall.topInset)
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
    .background { HoverTracker { isHovered = $0 } }
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

/// 卡片上的字：标题（一两行，排不下的末尾「…」）和正文开头几行，NoteWallCard 量高时用的同一套排版画出来。
/// 卡片没换（同一个 NoteWallCard、同一种外观）就不重画：悬停、选中、滑动时只动外面的变换
private struct CardText: View, Equatable {
  let card: NoteWallCard
  let scheme: ColorScheme

  nonisolated static func == (a: Self, b: Self) -> Bool {
    a.card === b.card && a.scheme == b.scheme
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
