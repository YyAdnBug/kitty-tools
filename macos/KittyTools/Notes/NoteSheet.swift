// 一条打开着的便签的界面：纸色的一张，一侧带着它自己的标签（竖排的标题），头部是纸色圆点（点了换颜色）、标题、任务、
// 固定、「⋯」（操作菜单，同 ⌘K）、关闭；正文和全部便签窗口是同一套（Notes/NoteFields.swift）；底下一行小字。
// **屏幕边缘那叠里打开的便签（NoteDeckView）和浮动便签（NoteFloatPanel）画的都是它**，状态都读 NoteSheetModel——
// 不各写一份长得差不多的（PLAN §10「便签」第 4 批；长相在 mac-whisker-notes.mdc「打开的便签」「浮动便签」）。
// 两边只差两样：阴影（那叠里是纸自己画的，浮动便签是单独的窗口、用系统的窗口阴影）和外面怎么摆。
// **把手**：它带着的那张标签（整条）和头部的空白处。按着拖——在那叠里是把这条便签拖出来、变成浮动便签，浮着时是
// 挪窗口（各自的 NoteSheetModel.gripChanged）；按在标签上没挪开就松手 = 点了一下 = 关掉 / 收回。
// 手势在**全局坐标**里量，位置取鼠标在屏幕上的位置：被拖的东西自己在动（浮着时整扇窗口跟着鼠标走，拖出来时这一份
// 换成了另一扇窗口），按本地坐标量的话动了多少就少算多少（第 3 批标签拖动排序踩过）。
// 纸上的字一律用这条便签的墨色，不用强调色（纸色是内容的颜色）；面板不激活本 App，悬停一律用 HoverTracker。

import SwiftUI

struct NoteSheet: View {
  let model: NoteSheetModel
  let note: Note
  /// 它带着的那张标签多宽、字多大（跟那叠的大小档走）
  let metrics: NoteDeckMetrics
  let height: CGFloat
  let fontSize: CGFloat
  /// 它带着的那张标签在左边（那叠在右边缘时：朝屏幕里面的那一侧）还是右边
  let tabOnLeading: Bool
  /// 阴影由纸自己画（那叠：一块透明面板上浮着的纸）；浮动便签是单独的窗口，用系统的窗口阴影
  var castsShadow = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  /// 标题、正文、底下小字共用的左右边线
  private static let margin: CGFloat = 14
  private static let headerHeight: CGFloat = 36

  /// 操作菜单最多露几行（再多在菜单里滚）：平时 8.5 行；便签矮（浮动便签拉小了）时按它的高度收，菜单不出便签
  static func menuRows(height: CGFloat) -> CGFloat {
    min(8.5, max(2.5, (height - headerHeight - 14) / ActionMenu.rowHeight))
  }

  var body: some View {
    let paper = NotePaper.of(note)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let rule = paper.rule(contrast).frame(width: Style.hairlineWidth(contrast))
    HStack(spacing: 0) {
      // 它自己的标签在朝屏幕里面的那一侧（先出来的那一头）
      if tabOnLeading {
        tab(paper)
        rule
      }
      sheet(paper)
      if !tabOnLeading {
        rule
        tab(paper)
      }
    }
    .clipShape(shape)
    .background {
      if castsShadow { shape.fill(paper.paper).floatingShadow() } else { shape.fill(paper.paper) }
    }
    .overlay(shape.hairlineBorder(paper.rule(contrast)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("便签「\(note.displayTitle)」")
  }

  /// 按着把手拖。位置取鼠标在屏幕上的位置（见文件头）；第一下是按下的那一刻
  private func grip(_ part: NoteSheetModel.Grip) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { _ in model.gripChanged(at: NSEvent.mouseLocation) }
      .onEnded { _ in model.gripEnded(part, at: NSEvent.mouseLocation) }
  }

  /// 便签带着的那张标签：竖排的标题，底色比纸深一档。点它 = 关掉便签（那叠里回到那一列，浮着的收回边缘）；
  /// 按着它拖 = 把手。旁白读的名字同头部的关闭钮（浮着时是「收回边缘」/「取消浮动」，NoteSheetModel.tuckTitle）
  private func tab(_ paper: NotePaper) -> some View {
    NoteTabLabel(
      title: note.displayTitle, length: height - 2 * Self.margin, metrics: metrics,
      ink: paper.ink
    )
    .frame(width: metrics.tabWidth)
    .frame(maxHeight: .infinity)
    .background(paper.strip.opacity(NotePaper.tabTint))
    .contentShape(.rect)
    .gesture(grip(.tab))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.tuckTitle ?? "关闭便签")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.close() }
  }

  private func sheet(_ paper: NotePaper) -> some View {
    VStack(spacing: 0) {
      header(paper)
      NoteBodyField(
        // 写入绑着这条便签的编号：换一条、浮出去 / 收回来时这块编辑区还会留一小会儿，它晚到的那一下要落回它自己那条
        note: note, fontSize: fontSize, margin: Self.margin,
        setBody: { model.setBody($0, of: note.id) }, onOverflow: model.overflowed,
        onCancel: model.cancel, focusRequest: model.focusRequest(for: note.id),
        undo: model.textUndo)
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

  /// 头部：纸色圆点（点了换颜色）、标题、任务、固定、「⋯」、关闭。圆点的左边和正文的字同一条线。
  /// 钮和标题框以外的空白处是把手（垫在最下面：点得到钮和标题框的地方轮不到它）
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
        symbol: NotesWindowModel.taskSymbol, label: "\(NotesWindowModel.taskTitle)（⌘T）",
        ink: paper.ink
      ) {
        model.toggleTask()
      }
      NoteIconButton(
        symbol: note.isPinned ? "pin.fill" : "pin",
        label: "\(NotesWindowModel.pinTitle(note))（⌘P）", ink: paper.ink
      ) {
        model.togglePinned()
      }
      NoteIconButton(symbol: "ellipsis", label: "操作（⌘K）", ink: paper.ink) {
        model.toggleMenu()
      }
      NoteIconButton(symbol: "xmark", label: "\(model.tuckTitle ?? "关闭")（Esc）", ink: paper.ink) {
        model.close()
      }
    }
    .padding(.leading, Self.margin)
    .padding(.trailing, 6)
    .frame(height: Self.headerHeight)
    .background {
      Color.clear.contentShape(.rect).gesture(grip(.header)).accessibilityHidden(true)
    }
  }

  /// 操作菜单（Shell/ActionMenu）：长在「⋯」下面；从圆点点开的是颜色那一级，长在圆点下面
  @ViewBuilder private var menu: some View {
    if let menu = model.menu {
      ActionMenu(
        items: model.menuItems, selection: menu.selection,
        header: menu.inColors && !menu.fromDot ? NotesWindowModel.colorTitle : nil,
        onBack: model.menuBack, anchor: menu.fromDot ? .topLeading : .topTrailing,
        maxRows: Self.menuRows(height: height), onHover: model.menuHover, onRun: model.run
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
      model.requestFocus()
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
