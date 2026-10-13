// 屏幕边缘那叠的界面（画在 NoteDeckPanel 里，整块透明；长相在 mac-whisker-notes.mdc「屏幕边缘那叠」，状态在 NoteDeckModel.swift）：
// - 标签列贴着屏幕的那条边：「带标题的标签」一张压一张（纸色的底、竖排的标题，固定的带个小点，打开的那张探出来一截），
//   或「只有色块」；下面是「+N」（HUD 皮肤，点了变成可滚动的一列）和「+」（右键是新建便签 / 全部便签 / 设置…）。出场一张接一张滑出来（间隔 45 ms，pop），
//   减弱动态效果时直接出现。按着一张上下拖 = 排序，别的给它让位。
// - 预览卡：鼠标在标签上停一下，旁边出一张小卡（标题、开头几行）。
// - 打开的便签：纸色的一张，挨着标签列、对着它自己那张标签，从边缘那边滑出来（短距离位移 + 一点缩放 + 淡入）。
//   靠屏幕里面的那一侧带着它自己的标签（竖排标题的一条，点它 = 关掉便签、回到那一列）；头部是纸色圆点（点了换颜色）、标题、固定、
//   「⋯」（操作菜单，同 ⌘K）、关闭；正文和全部便签窗口是同一套（Notes/NoteFields.swift）；底下一行小字。
// 纸上的字一律用这条便签的墨色，不用强调色（纸色是内容的颜色）；面板不激活本 App，悬停一律用 HoverTracker。

import SwiftUI

struct NoteDeckView: View {
  let model: NoteDeckModel
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let layout = model.layout
    let onRight = model.edge == .right
    let alignment: Alignment = onRight ? .topTrailing : .topLeading
    let inner: Edge.Set = onRight ? .trailing : .leading
    let top = model.columnTop(layout)
    ZStack(alignment: alignment) {
      NoteFan(model: model, layout: layout).padding(.top, top)
      if let note = model.previewNote,
        let index = model.tabs.firstIndex(where: { $0.id == note.id })
      {
        NotePreviewCard(model: model, note: note)
          // 对着那张标签的顶；太靠下时往上收，别出了面板。
          // ponytail: 「+N」展开后滚过的列表不知道滚到了哪，卡片按没滚时的位置摆（夹在这一列里）；要对准得把滚动位置记下来
          .padding(
            .top,
            min(
              top + min(CGFloat(index) * layout.step, max(layout.tabsHeight - layout.step, 0)),
              model.panelSize.height - NoteDeckLayout.previewHeight)
          )
          .padding(inner, layout.tabWidth + NoteDeckLayout.previewGap)
          .transition(
            .opacity.combined(with: .offset(x: onRight ? 8 : -8))
              .animation(Style.Motion.snap.animation(reduced: reduceMotion)))
      }
      if let note = model.current {
        let size = model.noteSize(layout)
        NoteSheet(
          model: model, note: note, metrics: layout.metrics, height: size.height,
          fontSize: Prefs.notesFontSize(fontSize)
        )
        .frame(width: size.width, height: size.height)
        .padding(.top, model.noteTop(layout))
        .padding(inner, layout.tabWidth + NoteDeckLayout.noteGap)
        .transition(
          .asymmetric(
            insertion: .modifier(
              active: NoteEmerge(isHidden: true, onRight: onRight),
              identity: NoteEmerge(isHidden: false, onRight: onRight)),
            removal: .opacity.animation(.easeIn(duration: Style.fadeOut)))
        )
        // 一条便签一块编辑区：换一条时光标、滚动位置、撤销栈都从头来
        .id(note.id)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    // 指针点出来的位移：glide（减弱动态效果时直接出现）
    .animation(Style.Motion.glide.animation(reduced: reduceMotion), value: model.state.openID)
    .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: model.preview)
    .symbolEffectsRemoved(reduceMotion)
    .appAccent()
  }
}

/// 便签从它的标签那里出来：往边缘那边偏 24 pt、缩到 0.97（锚在边缘那一侧）、透明——别做成整窗飞进来
private struct NoteEmerge: ViewModifier {
  let isHidden: Bool
  let onRight: Bool

  func body(content: Content) -> some View {
    content
      .scaleEffect(isHidden ? 0.97 : 1, anchor: onRight ? .trailing : .leading)
      .offset(x: isHidden ? (onRight ? 24 : -24) : 0)
      .opacity(isHidden ? 0 : 1)
  }
}

/// 贴着屏幕边缘的形状：朝屏幕里面的两个角是圆的，贴边的两个角是方的
private func edgeShape(onRight: Bool, radius: CGFloat) -> UnevenRoundedRectangle {
  UnevenRoundedRectangle(
    topLeadingRadius: onRight ? radius : 0, bottomLeadingRadius: onRight ? radius : 0,
    bottomTrailingRadius: onRight ? 0 : radius, topTrailingRadius: onRight ? 0 : radius,
    style: .continuous)
}

// MARK: 标签列

private struct NoteFan: View {
  let model: NoteDeckModel
  let layout: NoteDeckLayout
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var onRight: Bool { model.edge == .right }
  private var metrics: NoteDeckMetrics { layout.metrics }
  /// 滚动区朝屏幕里面多出来的宽：装得下探出来的 8 pt 和阴影
  private static let scrollBleed: CGFloat = 20

  var body: some View {
    let tabs = model.tabs
    VStack(alignment: onRight ? .trailing : .leading, spacing: 0) {
      if let viewport = layout.viewport {
        // 「+N」展开后放不下：在视口里滚。滚动区比标签宽一截：标签探出来的那一截和阴影不被它裁掉。
        // ponytail: 一次画全部标签（见 NoteDeckModel.tabs）；拖动排序拖到视口外不自动滚
        ScrollView(.vertical) {
          stack(tabs).frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
        }
        .scrollIndicators(.hidden)
        .frame(width: layout.tabWidth + Self.scrollBleed, height: viewport)
      } else {
        stack(tabs)
      }
      if layout.hidden > 0 {
        more.padding(.top, metrics.moreGap)
          .modifier(reveal(tabs.count))
      }
      plus.padding(.top, metrics.plusGap)
        .modifier(reveal(tabs.count + (layout.hidden > 0 ? 1 : 0)))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("便签，\(model.notes.count) 条")
  }

  /// 一张压一张靠的是负的间距（真的布局，点哪张就是哪张）；后画的在上面，正好是下一张压住上一张
  private func stack(_ tabs: [Note]) -> some View {
    VStack(alignment: onRight ? .trailing : .leading, spacing: layout.spacing) {
      ForEach(Array(tabs.enumerated()), id: \.element.id) { index, note in
        let isDragged = model.drag?.id == note.id
        NoteTab(model: model, note: note, index: index, layout: layout)
          .offset(y: shift(index, of: note))
          // 让位的那几张滑过去；被拖的那张不做动画，跟着手走
          .animation(
            isDragged ? nil : Style.Motion.glide.animation(reduced: reduceMotion),
            value: model.drag?.target
          )
          .zIndex(isDragged ? 1 : 0)
          .modifier(reveal(index))
      }
    }
    // 增删、换了顺序：剩下的滑到新位置
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: tabs.map(\.id))
  }

  /// 拖动排序时每张挪多少：被拖的跟着手；它和目标格之间的那几张往反方向让一格
  private func shift(_ index: Int, of note: Note) -> CGFloat {
    guard let drag = model.drag else { return 0 }
    if drag.id == note.id { return drag.offset }
    if drag.from < drag.target, index > drag.from, index <= drag.target { return -layout.step }
    if drag.from > drag.target, index < drag.from, index >= drag.target { return layout.step }
    return 0
  }

  private func reveal(_ index: Int) -> NoteTabReveal {
    NoteTabReveal(
      index: index, isRevealed: model.isRevealed, distance: layout.tabWidth + 24,
      onRight: onRight, isReduced: reduceMotion)
  }

  /// 「+N」：还有几条没列出来，点了变成可滚动的一列（便签开着时也能点：列出全部，便签留着）
  private var more: some View {
    Button {
      model.send(.showAll)
    } label: {
      // 三四位数（上限 5000 条）也不折行、不贴边：缩小一点；verbatim：不要千位的逗号
      Text(verbatim: "+\(layout.hidden)")
        .font(.system(size: max(10, metrics.fontSize - 1), weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 2)
        .frame(width: layout.tabWidth, height: metrics.moreHeight)
        .hudSkin(edgeShape(onRight: onRight, radius: Style.Radius.control))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("还有 \(layout.hidden) 条便签")
    .accessibilityHint("全部列出来")
  }

  /// 最下面的「+」：新建一条并在这叠里打开。右键是和药丸同名的三项——鼠标一到药丸就扇出、药丸淡掉，
  /// 药丸自己的右键菜单多半点不到，这里是扇出之后的那个入口
  private var plus: some View {
    Button {
      model.create()
    } label: {
      Image(systemName: "plus")
        .font(.system(size: metrics.fontSize, weight: .semibold))
        .frame(width: metrics.plusSize, height: metrics.plusSize)
        .hudSkin(Circle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(HotKeyAction.noteNew.title) { model.create() }
      Button(HotKeyAction.noteAll.title) { model.showNotes() }
      Divider()
      Button("设置…") { model.showSettings() }
    }
    .padding(.horizontal, (layout.tabWidth - metrics.plusSize) / 2)
    .accessibilityLabel(HotKeyAction.noteNew.title)
  }
}

/// 出场：从边外滑进来、淡入，一张接一张（每张晚 45 ms，pop）；收回时一起淡出滑回去。减弱动态效果时直接出现 / 消失
private struct NoteTabReveal: ViewModifier {
  let index: Int
  let isRevealed: Bool
  let distance: CGFloat
  let onRight: Bool
  let isReduced: Bool

  func body(content: Content) -> some View {
    content
      .offset(x: isRevealed || isReduced ? 0 : (onRight ? distance : -distance))
      .opacity(isRevealed ? 1 : 0)
      .animation(
        isReduced
          ? nil
          : isRevealed
            ? Style.Motion.pop.animation(reduced: false)?.delay(Double(index) * 0.045)
            : .easeIn(duration: Style.fadeOut),
        value: isRevealed)
  }
}

/// 一张标签（两种样式）。按着上下拖 = 排序，没挪开就是点了一下
private struct NoteTab: View {
  let model: NoteDeckModel
  let note: Note
  let index: Int
  let layout: NoteDeckLayout
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let paper = NotePaper.of(note)
    let onRight = model.edge == .right
    let isOpen = model.state.openID == note.id
    let isLifted = model.drag?.id == note.id
    let isHovered = model.hovered == note.id
    // 往屏幕里探出多少：打开的那张最多，鼠标停着的、正拖着的一点
    let reach: CGFloat = isOpen ? 8 : isHovered || isLifted ? 4 : 0
    let isChip = layout.style == .chips
    let shape = edgeShape(
      onRight: onRight, radius: isChip ? Style.Radius.control : Style.Radius.card)
    let strip = layout.strip(at: index)
    ZStack(alignment: .top) {
      if !isChip {
        NoteTabLabel(
          title: note.displayTitle, length: layout.labelHeight - layout.metrics.labelInset,
          metrics: layout.metrics, ink: paper.ink
        )
        .frame(width: layout.tabWidth, height: layout.labelHeight)
      }
    }
    .frame(width: layout.tabWidth + reach, height: layout.itemHeight, alignment: .top)
    .background {
      shape.fill(paper.paper)
        .shadow(
          color: .black.opacity(isLifted ? 0.30 : 0.18), radius: isLifted ? 10 : 5,
          x: onRight ? -1.5 : 1.5, y: isLifted ? 4 : 1)
    }
    // 色块没有标题：一圈色条色的边才认得出是哪种纸（同纸色圆点）；带标题的只描一道发丝线
    .overlay {
      if isChip {
        shape.strokeBorder(paper.strip, lineWidth: 1.5)
      } else {
        shape.hairlineBorder(paper.rule(contrast))
      }
    }
    // 打开的那张：朝里的那条边上一道色条
    .overlay(alignment: onRight ? .leading : .trailing) {
      if isOpen {
        paper.strip.frame(width: 3, height: layout.labelHeight - 12)
          .clipShape(.capsule)
          .padding(.horizontal, 3)
          .padding(.top, isChip ? 0 : 6)
          .frame(maxHeight: .infinity, alignment: isChip ? .center : .top)
      }
    }
    // 固定的：贴边那一侧的上角一个小点
    .overlay(alignment: onRight ? .topTrailing : .topLeading) {
      if note.isPinned {
        Circle().fill(paper.strip).frame(width: 5, height: 5).padding(5)
      }
    }
    .contentShape(.rect)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { model.dragChanged(note.id, by: $0.translation.height) }
        .onEnded { model.dragEnded(note.id, by: $0.translation.height) }
    )
    // 悬停只认露在外面的那一截（下面那截被下一张压着；追踪区不看遮挡，整张都挂会两张一起报）
    .overlay(alignment: .top) {
      HoverTracker { model.hover(note.id, $0) }.frame(height: strip)
    }
    .animation(Style.Motion.glide.animation(reduced: reduceMotion), value: reach)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [note.displayTitle, note.isPinned ? "已固定" : nil, paper.name].compactMap { $0 }
        .joined(separator: "，")
    )
    .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { model.tapTab(note.id) }
  }
}

/// 竖排的标题：正着放的字一字一格，别的整段转 90°（从上往下读）；排不下的截断加「…」（NoteDeckLabel）
private struct NoteTabLabel: View {
  let title: String
  /// 能排多长
  let length: CGFloat
  let metrics: NoteDeckMetrics
  let ink: Color

  var body: some View {
    let runs = NoteDeckLabel.fitted(title, limit: length) {
      NoteDeckLabel.advance(of: $0, metrics: metrics)
    }
    VStack(spacing: 0) {
      ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
        let advance = NoteDeckLabel.advance(of: run, metrics: metrics)
        if run.isUpright {
          Text(run.text).frame(width: metrics.tabWidth, height: advance)
        } else {
          // rotationEffect 只转画面、不转布局：先按横排的尺寸排好，转过来再按竖着的尺寸占位
          Text(run.text)
            .fixedSize()
            .frame(width: advance, height: metrics.tabWidth)
            .rotationEffect(.degrees(90))
            .frame(width: metrics.tabWidth, height: advance)
        }
      }
    }
    .font(.system(size: metrics.fontSize, weight: .semibold))
    .foregroundStyle(ink)
    .lineLimit(1)
  }
}

// MARK: 预览卡

/// 鼠标停在标签上时旁边的小卡：标题、开头几行；点它 = 打开这条
struct NotePreviewCard: View {
  let model: NoteDeckModel
  let note: Note
  @Environment(\.colorSchemeContrast) private var contrast

  /// 这条便签只有一行字、标题就是它（没自己起标题、正文第一行之后没有别的）：卡上只写标题、让它折到三行，
  /// 不另写一句「没有更多内容」。一个字都没有的（「未命名便签」）、自己起了标题而正文空着的照旧写那一句
  static func isTitleOnly(_ note: Note) -> Bool {
    note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.preview.isEmpty
      && note.displayTitle != Note.untitled
  }

  var body: some View {
    let paper = NotePaper.of(note)
    let preview = note.preview
    let titleOnly = Self.isTitleOnly(note)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    Button {
      model.tapTab(note.id)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 6) {
          Text(note.displayTitle)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(titleOnly ? 3 : 1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          if note.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)) }
        }
        .foregroundStyle(paper.ink)
        if !titleOnly {
          Text(preview.isEmpty ? "没有更多内容" : preview)
            .font(.system(size: 11))
            .foregroundStyle(preview.isEmpty ? paper.ink.opacity(0.35) : paper.secondaryInk)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(width: NoteDeckLayout.previewWidth, alignment: .leading)
      .background { shape.fill(paper.paper).floatingShadow() }
      .overlay(shape.hairlineBorder(paper.rule(contrast)))
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .background { HoverTracker { model.hoverPreview($0) } }
    // 标签自己已经读了标题；预览卡是给眼睛看的
    .accessibilityHidden(true)
  }
}

// MARK: 打开的便签

private struct NoteSheet: View {
  let model: NoteDeckModel
  let note: Note
  let metrics: NoteDeckMetrics
  let height: CGFloat
  let fontSize: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  /// 标题、正文、底下小字共用的左右边线
  private static let margin: CGFloat = 14
  private static let headerHeight: CGFloat = 36

  var body: some View {
    let paper = NotePaper.of(note)
    let onRight = model.edge == .right
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let rule = paper.rule(contrast).frame(width: Style.hairlineWidth(contrast))
    HStack(spacing: 0) {
      // 它自己的标签在朝屏幕里面的那一侧（先出来的那一头）
      if onRight {
        tab(paper)
        rule
      }
      sheet(paper)
      if !onRight {
        rule
        tab(paper)
      }
    }
    .clipShape(shape)
    .background { shape.fill(paper.paper).floatingShadow() }
    .overlay(shape.hairlineBorder(paper.rule(contrast)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("便签「\(note.displayTitle)」")
  }

  /// 便签带着的那张标签：竖排的标题，底色比纸深一档；点它 = 关掉便签、回到那一列
  private func tab(_ paper: NotePaper) -> some View {
    Button {
      model.send(.close)
    } label: {
      NoteTabLabel(
        title: note.displayTitle, length: height - 2 * Self.margin, metrics: metrics,
        ink: paper.ink
      )
      .frame(width: metrics.tabWidth)
      .frame(maxHeight: .infinity)
      .background(paper.strip.opacity(NotePaper.tabTint))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("关闭便签")
  }

  private func sheet(_ paper: NotePaper) -> some View {
    VStack(spacing: 0) {
      header(paper)
      NoteBodyField(
        // 写入绑着这条便签的编号：换一条时这块编辑区还会留一小会儿（淡出），它晚到的那一下要落回它自己那条
        note: note, fontSize: fontSize, margin: Self.margin,
        setBody: { model.setBody($0, of: note.id) }, onOverflow: model.overflowed,
        onCancel: model.cancel)
      NoteFootnote(
        note: note, isOverLimit: model.isOverLimit, isUnsaved: model.store.saveProblem != nil
      )
      .padding(.horizontal, Self.margin)
      .frame(height: 26)
    }
    // 操作菜单开着：点菜单外面先关菜单
    .overlay {
      if model.menu != nil {
        Color.clear.contentShape(.rect).onTapGesture { model.closeMenu() }
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: model.menu?.fromDot == true ? .topLeading : .topTrailing) { menu }
    .animation(
      Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn),
      value: model.menu != nil)
  }

  /// 头部：纸色圆点（点了换颜色）、标题、固定、「⋯」、关闭。圆点的左边和正文的字同一条线
  private func header(_ paper: NotePaper) -> some View {
    HStack(spacing: 2) {
      Button {
        model.toggleMenu(fromDot: true)
      } label: {
        NoteDot(paper: paper).frame(width: 12, height: 24).contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(NotesWindowModel.colorTitle)：\(paper.name)")
      // NSTextField 自己左右各有 2 pt：标题的字离圆点 8
      NoteTitleField(
        note: note, fontSize: 14, height: 20, setTitle: { model.setTitle($0, of: note.id) },
        onCommand: titleCommand
      )
      .padding(.leading, 4)
      .padding(.trailing, 4)
      NoteIconButton(
        symbol: note.isPinned ? "pin.fill" : "pin",
        label: "\(NotesWindowModel.pinTitle(note))（⌘P）", ink: paper.ink
      ) {
        model.togglePinned()
      }
      NoteIconButton(symbol: "ellipsis", label: "操作（⌘K）", ink: paper.ink) {
        model.toggleMenu()
      }
      NoteIconButton(symbol: "xmark", label: "关闭（Esc）", ink: paper.ink) {
        model.send(.close)
      }
    }
    .padding(.leading, Self.margin)
    .padding(.trailing, 6)
    .frame(height: Self.headerHeight)
  }

  /// 操作菜单（Shell/ActionMenu）：长在「⋯」下面；从圆点点开的是颜色那一级，长在圆点下面
  @ViewBuilder private var menu: some View {
    if let menu = model.menu {
      ActionMenu(
        items: model.menuItems, selection: menu.selection,
        header: menu.inColors && !menu.fromDot ? NotesWindowModel.colorTitle : nil,
        onBack: model.menuBack, anchor: menu.fromDot ? .topLeading : .topTrailing,
        maxRows: 8.5, onRun: model.run
      )
      .padding(.top, Self.headerHeight - 2)
      .padding(.horizontal, 6)
    }
  }

  /// 标题框里 ↩、↓、Tab 去正文；Esc 同正文里的 Esc
  private func titleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)),
      #selector(NSResponder.insertTab(_:)):
      model.focusBody()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      model.cancel()
      return true
    default: return false
    }
  }
}

/// 便签头部的图标按钮：墨色的符号，鼠标停着时垫一块墨色的淡底
private struct NoteIconButton: View {
  let symbol: String
  let label: String
  let ink: Color
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 24, height: 24)
        .background(
          ink.opacity(isHovered ? 0.10 : 0),
          in: .rect(cornerRadius: Style.Radius.control, style: .continuous)
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background {
      HoverTracker { inside in
        withAnimation(.easeOut(duration: 0.10)) { isHovered = inside }
      }
    }
    .accessibilityLabel(label)
    .help(label)
  }
}
