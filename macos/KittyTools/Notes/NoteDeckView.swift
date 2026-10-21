// 屏幕边缘那叠的界面（画在 NoteDeckPanel 里，整块透明；长相在 mac-whisker-notes.mdc「屏幕边缘那叠」，状态在 NoteDeckModel.swift）：
// - 标签列贴着屏幕的那条边：「带标题的标签」一张压一张（纸色的底、竖排的标题，固定的带个小点，打开的那张探出来一截），
//   或「只有色块」，一律斜一点（2026-10-15 起默认就斜、没有开关；打开的那张立正）；下面是「+N」（HUD 皮肤，点了变成
//   可滚动的一列）和「+」。出场一张接一张滑出来（间隔 45 ms，pop），减弱动态效果时直接出现。按着一张上下拖 = 排序，
//   别的给它让位。右键一张标签是这条便签的操作（固定、颜色、浮在屏幕上、归档、删除）；右键空白处、「+」是新建便签 /
//   全部便签 / 设置…（同药丸）——都是系统菜单（ActionSystemMenu，只接右键和 ⌃ 点按）。
// - 每张标签只拿画它要的那几样（开着没有、浮着没有、鼠标停着没有、正拖着没有、标题），不自己去读那叠的状态：
//   换一条、悬停一下时只有变了的那两三张重画（「+N」展开成几百张时，原来是每张都重画一遍）。
// - 预览卡：鼠标在标签上停一下，旁边出一张小卡（标题、开头几行）。
// - 打开的便签：纸色的一张，挨着标签列、对着它自己那张标签，从边缘那边滑出来（短距离位移 + 一点缩放 + 淡入）。
//   这一张本身是 NoteSheet（Notes/NoteSheet.swift，浮动便签画的也是它）；这里只管把它摆在哪、怎么出场。
//   它被拖出去、变成浮动便签的那一阵（NoteDeckModel.liftedID），这里的这一份留着不拆、只是看不见。
// - 浮在屏幕上的那条便签，列里它的标签带一道色条色的竖条（同打开的那张，但不探出来）：它开着，只是不在这儿。
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
          fontSize: Prefs.notesFontSize(fontSize), tabOnLeading: onRight
        )
        .frame(width: size.width, height: size.height)
        // 被拖出去了（浮动面板正带着它走）：这一份不拆——拖着的手势是从它身上开始的，拆了就断——只是看不见
        .opacity(model.liftedID == note.id ? 0 : 1)
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
  /// 滚动位置的段（ListWindow）：可见区的顶落在第几段，跨段才换要画的那几张
  @State private var band = 0

  private var onRight: Bool { model.edge == .right }
  private var metrics: NoteDeckMetrics { layout.metrics }
  /// 滚动区朝屏幕里面多出来的宽：装得下探出来的 8 pt 和阴影
  private static let scrollBleed: CGFloat = 20

  var body: some View {
    let tabs = model.tabs
    VStack(alignment: onRight ? .trailing : .leading, spacing: 0) {
      if let viewport = layout.viewport {
        // 「+N」展开后放不下：在视口里滚。滚动区比标签宽一截：标签探出来的那一截和阴影不被它裁掉。
        // 只画可见区附近（stack 的 window）；拖动排序拖到视口外不自动滚
        ScrollView(.vertical) {
          stack(tabs).frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
        }
        .scrollIndicators(.hidden)
        .modifier(TracksScrollBand(band: $band))
        .onAppear { band = 0 }
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
    // 空白处（标签和「+N」「+」之间的那几道缝）右键也是药丸那三项。整块透明的地方系统会点穿到后面的窗口：垫一层
    // 看不出来的底（1% 的黑）把这一列接住
    .background {
      Color.black.opacity(0.01)
        .overlay { ActionSystemMenu(items: { model.edgeItems }, onMenu: model.menuShown) }
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("便签，\(model.notes.count) 条")
  }

  /// 一张压一张靠的是负的间距（真的布局，点哪张就是哪张）；后画的在上面，正好是下一张压住上一张
  /// 那叠的状态在 ForEach 外面读一次：每张标签各读一遍的话，每一张都要单独挂一份「盯着它变」，几百张时光这一项就不少
  /// 「+N」展开成上千张时只画可见区附近（window(_:)，ListWindow，同剪贴板列表、便签墙）：上下用撑高的空档占位，
  /// 滚动位置、拖动排序、悬停、↑↓、「+N」收回都不变。实测 5000 条 -O 展开到第一屏 4735 → 57 ms、滚一屏 63 → 12 ms，
  /// notesDeck() 的 76 张图逐像素和改前一样（2026-10-21）
  private func stack(_ tabs: [Note]) -> some View {
    let (openID, liftedID, floatingIDs) = (model.state.openID, model.liftedID, model.floatingIDs)
    let (hovered, drag, isRevealed) = (model.hovered, model.drag, model.isRevealed)
    let rows = window(tabs)
    return VStack(alignment: onRight ? .trailing : .leading, spacing: layout.spacing) {
      if rows.start > 0 {
        // 上面没画的那几张撑起来：VStack 的间距是负的，开头这一块要把它补回去
        Color.clear.frame(height: CGFloat(rows.start) * layout.step - layout.spacing)
      }
      ForEach(rows.items, id: \.id) { item in
        let index = item.index
        let note = tabs[index]
        let isDragged = drag?.id == note.id
        NoteTab(
          model: model, note: note, summary: model.store.summary(of: note), index: index,
          layout: layout, onRight: onRight,
          // 被拖出去的那条（它在这叠里的那一份还留着、只是看不见）不算开着：标签当场缩回去
          isOpen: openID == note.id && liftedID != note.id,
          isFloating: floatingIDs.contains(note.id),
          isLifted: isDragged, isHovered: hovered == note.id
        )
        .offset(y: shift(index, of: note, drag: drag))
        // 让位的那几张滑过去；被拖的那张不做动画，跟着手走
        .animation(
          isDragged ? nil : Style.Motion.glide.animation(reduced: reduceMotion),
          value: drag?.target
        )
        .zIndex(isDragged ? 1 : 0)
        .modifier(reveal(index, isRevealed: isRevealed))
      }
      if rows.end < tabs.count {
        Color.clear.frame(height: layout.stackHeight - CGFloat(rows.end) * layout.step)
      }
    }
    // 窗口化之后最宽的那张可能没画（打开的那张探出 8 pt）：按整列算，列的宽和贴边的位置不跟着变
    .frame(width: layout.tabWidth + widestReach(tabs), alignment: onRight ? .trailing : .leading)
    // 增删、换了顺序：剩下的滑到新位置
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: tabs.map(\.id))
  }

  /// 这一列要画的下标：视口放得下就全画；放不下（「+N」展开）只画可见区附近（上下各多 overscan，ListWindow 算）
  private func window(_ tabs: [Note]) -> (start: Int, end: Int, items: [(index: Int, id: String)]) {
    guard let viewport = layout.viewport else {
      return (0, tabs.count, tabs.enumerated().map { (index: $0.offset, id: $0.element.id) })
    }
    var tops = (0...tabs.count).map { CGFloat($0) * layout.step }
    tops[tabs.count] = layout.stackHeight
    let range = ListWindow.range(tops, band: band, inset: 0, viewport: viewport)
    return (range.lowerBound, range.upperBound, range.map { (index: $0, id: tabs[$0].id) })
  }

  /// 这一列里最宽的那张往屏幕里探出多少（打开 8、悬停 / 拖着 4；同 NoteTab 里的 reach）：没画的那几张也算
  private func widestReach(_ tabs: [Note]) -> CGFloat {
    let (open, lifted, hovered) = (model.state.openID, model.liftedID, model.hovered)
    var reach: CGFloat = 0
    for note in tabs {
      if note.id == open, note.id != lifted { return 8 }
      if note.id == lifted || note.id == hovered { reach = 4 }
    }
    return reach
  }

  /// 拖动排序时每张挪多少：被拖的跟着手；它和目标格之间的那几张往反方向让一格
  private func shift(_ index: Int, of note: Note, drag: NoteDeckModel.Drag?) -> CGFloat {
    guard let drag else { return 0 }
    if drag.id == note.id { return drag.offset }
    if drag.from < drag.target, index > drag.from, index <= drag.target { return -layout.step }
    if drag.from > drag.target, index < drag.from, index >= drag.target { return layout.step }
    return 0
  }

  private func reveal(_ index: Int, isRevealed: Bool? = nil) -> NoteTabReveal {
    NoteTabReveal(
      index: index, isRevealed: isRevealed ?? model.isRevealed, distance: layout.tabWidth + 24,
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

  /// 最下面的「+」：新建一条并在这叠里打开。右键是和药丸同一份三项（NoteDeckModel.edgeItems）——鼠标一到药丸就
  /// 扇出、药丸淡掉，药丸自己的右键菜单多半点不到，扇出之后靠这里和空白处
  private var plus: some View {
    Button {
      model.create()
    } label: {
      Image(systemName: "plus")
        .font(.system(size: metrics.fontSize, weight: .semibold))
        .frame(width: metrics.plusSize, height: metrics.plusSize)
        .hudSkin(Circle(), glass: false)  // 小圆钮不换玻璃（Style.hudSkin）
    }
    .buttonStyle(.plain)
    .overlay { ActionSystemMenu(items: { model.edgeItems }, onMenu: model.menuShown) }
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

/// 一张标签（两种样式）。按着上下拖 = 排序，没挪开就是点了一下；右键是这条便签的操作。
/// 画它要的那几样都由那一列传进来（见文件头）：body 里不读那叠的状态，没变的标签就不重画
private struct NoteTab: View {
  let model: NoteDeckModel
  let note: Note
  /// 标题、任务进度（仓库的缓存）
  let summary: NoteStore.Summary
  let index: Int
  let layout: NoteDeckLayout
  let onRight: Bool
  let isOpen: Bool
  let isFloating: Bool
  /// 正被拖着排序
  let isLifted: Bool
  let isHovered: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let paper = NotePaper.of(note)
    // 往屏幕里探出多少：打开的那张最多，鼠标停着的、正拖着的一点
    let reach: CGFloat = isOpen ? 8 : isHovered || isLifted ? 4 : 0
    let isChip = layout.style == .chips
    let shape = edgeShape(
      onRight: onRight, radius: isChip ? Style.Radius.control : Style.Radius.card)
    let strip = layout.strip(at: index)
    // 标签一律斜一点（2026-10-15 起没有开关），纸朝屏幕边多画出去一截（斜了之后贴边那一侧的角会离开屏幕边，不多画
    // 就露出楔形的缝；多出去的在屏幕外、被窗口裁掉）。打开的那张立正：它要接上旁边那张正着的便签
    let bleed = layout.metrics.tiltBleed
    let outer: Edge.Set = onRight ? .trailing : .leading
    ZStack(alignment: .top) {
      if !isChip {
        NoteTabLabel(
          title: summary.title, length: layout.labelHeight - layout.metrics.labelInset,
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
          x: onRight ? -1.5 : 1.5, y: isLifted ? 4 : 1
        )
        .padding(outer, -bleed)
    }
    // 色块没有标题：一圈色条色的边才认得出是哪种纸（同纸色圆点）；带标题的只描一道发丝线
    .overlay {
      Group {
        if isChip {
          shape.strokeBorder(paper.strip, lineWidth: 1.5)
        } else {
          shape.hairlineBorder(paper.rule(contrast))
        }
      }
      .padding(outer, -bleed)
    }
    // 打开的那张：朝里的那条边上一道色条。浮在屏幕上的那条也有（它开着，只是不在这儿——所以不探出来）
    .overlay(alignment: onRight ? .leading : .trailing) {
      if isOpen || isFloating {
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
    // 只转画面：下面的点击区、拖动、悬停、右键都按不斜的来
    .rotationEffect(
      .degrees(NoteDeckLayout.tilt(edge: onRight ? .right : .left, isOn: !isOpen)),
      anchor: onRight ? .trailing : .leading
    )
    .animation(Style.Motion.glide.animation(reduced: reduceMotion), value: isOpen)
    .contentShape(.rect)
    // 在不动的坐标系里量（.global）：这张标签自己正被外面的 .offset 挪着，按默认的本地坐标系量的话坐标系跟着视图走，
    // 挪了多少就少算多少、下一帧又弹回来——被拖的那张一直抖（2026-10-13 手测）
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { model.dragChanged(note.id, by: $0.translation.height) }
        .onEnded { model.dragEnded(note.id, by: $0.translation.height) }
    )
    // 悬停只认露在外面的那一截（下面那截被下一张压着；追踪区不看遮挡，整张都挂会两张一起报）
    .overlay(alignment: .top) {
      HoverTracker { model.hover(note.id, $0) }.frame(height: strip)
    }
    // 右键（和 ⌃ 点按）：这条便签的操作。别的点击、悬停、拖动照常穿过去。菜单在右键的那一刻按仓库里现在的样子建
    .overlay {
      ActionSystemMenu(
        items: { [model, id = note.id] in model.tabItems(id) }, onMenu: model.menuShown)
    }
    .animation(Style.Motion.glide.animation(reduced: reduceMotion), value: reach)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [
        summary.title, note.isPinned ? "已固定" : nil, isFloating ? "浮在屏幕上" : nil,
        paper.name, summary.progress.map(Note.progressSpoken),
      ]
      .compactMap { $0 }.joined(separator: "，")
    )
    .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { model.tapTab(note.id) }
    // 旁白的「更多动作」：右键菜单里不带子菜单的那几项（颜色那一级靠 ⌘. 或打开后的操作菜单）
    .accessibilityActions {
      ForEach(
        model.tabItems(note, isFloating: isFloating, colors: false).filter { $0.submenu == nil }
      ) {
        item in
        Button(item.title, action: item.run)
      }
    }
  }
}

/// 竖排的标题：正着放的字一字一格，别的整段转 90°（从上往下读）；排不下的截断加「…」（NoteDeckLabel）。
/// 列里的标签和打开的便签带着的那张标签（NoteSheet）共用
struct NoteTabLabel: View {
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
  /// 不另写一句「没有更多内容」。一个字都没有的（「未命名便签」）、自己起了标题而正文空着的照旧写那一句。
  /// 标题、摘要用仓库缓存的那份（NoteStore.summary），不现算
  static func isTitleOnly(_ note: Note, summary: NoteStore.Summary) -> Bool {
    note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && summary.preview.isEmpty
      && summary.title != Note.untitled
  }

  var body: some View {
    let paper = NotePaper.of(note)
    let summary = model.store.summary(of: note)
    let preview = summary.preview
    let titleOnly = Self.isTitleOnly(note, summary: summary)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    Button {
      model.tapTab(note.id)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 6) {
          Text(summary.title)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(titleOnly ? 3 : 1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          if let progress = summary.progress {
            NoteProgress(progress: progress).foregroundStyle(paper.secondaryInk)
          }
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
