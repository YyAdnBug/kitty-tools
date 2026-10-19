// 启动台打开的文件夹（从 LaunchpadView 拆出来，2026-10-18）：后面那层糊掉压暗（FolderBackdrop）、面板那块从文件夹方块长出来 /
// 缩回去的纸（FolderSheet / FolderPaper，同便签墙的编辑卡）、纸上面的名字 / 图标 / 页点（FolderOverlay）。
// 层次和动画由 LaunchpadView 摆（zIndex、开 / 关的时机），口径在 mac-whisker-launchpad §4。

import AppKit
import SwiftUI

/// 文件夹面板那块纸的状态（同便签墙的 WallSheet）：哪个文件夹、从哪长出来（文件夹方块的框；nil = 在中间略小一圈）、
/// 开着时面板在哪（关的时候它已经不在 model 里了）、正在缩回没有、缩回哪。每打开一次一个新编号：缩完时认它
struct FolderSheet {
  let id: UUID
  let from: CGRect?
  let panel: CGRect
  /// 一出来就在中间（减弱动态效果）
  var grown = false
  var isClosing = false
  var to: CGRect?
  let serial = FolderSheet.next()

  private static var counter = 0
  private static func next() -> Int {
    counter &+= 1
    return counter
  }
}

/// 面板那块纸：打开时从文件夹方块长到面板的位置（`LaunchpadView.folderGrow`，出现的下一轮开始），关的时候缩回方块（settle，动画在外面给）；
/// 圆角和底色也跟着在面板（26 pt、white 0.14）和文件夹方块（边长的 22%、white 0.32）之间变，落下去就是那个方块的样子。
/// 没有方块可回（不在这一页了）就在中间缩一点淡掉
struct FolderPaper: View {
  let sheet: FolderSheet
  let panel: CGRect
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var grown = false

  var body: some View {
    let glyph = sheet.isClosing ? sheet.to : sheet.from
    let atPanel = !sheet.isClosing && (grown || sheet.grown || sheet.from == nil)
    let shrunk = panel.insetBy(dx: panel.width * 0.04, dy: panel.height * 0.04)
    let rect = atPanel ? panel : glyph ?? shrunk
    let corner = atPanel || glyph == nil ? Style.Radius.launchpadFolder : rect.width * 0.22
    let fill = atPanel || glyph == nil ? (contrast == .increased ? 0.22 : 0.14) : 0.32
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    shape
      .fill(.white.opacity(fill))
      .overlay { shape.stroke(.white.opacity(0.2), lineWidth: Style.hairlineWidth(contrast)) }
      .frame(width: rect.width, height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .opacity(sheet.isClosing && sheet.to == nil ? 0 : 1)
      .allowsHitTesting(!sheet.isClosing)
      .onAppear {
        // 下一轮再长：出现的这一帧要建文件夹里几十个图标（约 40 ms），动画从这之前算的话开头几帧被吃掉、看着是跳出来的
        DispatchQueue.main.async {
          withAnimation(LaunchpadView.folderGrow) { grown = true }
        }
      }
      .accessibilityHidden(true)
  }
}

/// 打开文件夹时后面那一层：整张网格糊掉（材质在窗口里取后面的内容，图标的 NSImageView 也一起糊），上面再铺八成的壁纸、
/// 压暗一层，只剩一点糊掉的网格影子，面板里外的字不会混在一起（材质一律按深色：面板窗口本来就是深色）。点它收起文件夹
struct FolderBackdrop: View {
  let model: LaunchpadModel

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
      if let wallpaper = model.wallpaper {
        Image(decorative: wallpaper, scale: 1)
          .resizable()
          .opacity(0.8)
      }
      Color.black.opacity(0.16)
    }
    .ignoresSafeArea()
    .contentShape(Rectangle())
    .onTapGesture {
      // 点空白：先提交改名（点别处 = 失焦提交，F34），再收起
      if let id = model.openFolderID, model.folderNameDraft != model.openFolder?.name {
        model.renameFolder(id, to: model.folderNameDraft)
      }
      model.closeFolder()
    }
  }
}

/// 打开的文件夹（照 macOS 15）：屏幕中间一块浅色毛玻璃面板，7 列、按内容行数定高；名字在面板上方（大号白字，回车 / 失焦确认改名，
/// 晚一点淡入），里面能分页（两指滑 / 圆点）、拖着挪（别的让位）；把图标拖出面板就关上、回主网格接着拖（F34，2026-10-18 交互对齐）。
/// 面板在屏上的位置由 `model.folderPanelRect` 按同一个算式给（拖动判定用它，不量）
struct FolderOverlay: View {
  @Bindable var model: LaunchpadModel
  let metrics: LaunchpadMetrics
  let space: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @FocusState private var editingName: Bool
  /// 名字正在改：平时是一行字，点一下才换成输入框（照 macOS 15 单击名字改名；输入框建起来要 20 ms，展开那一下不建它）
  @State private var editing = false

  var body: some View {
    // 格子宽高分开算（G4，口径在 LaunchpadMetrics.folder*）：宽和主网格一样，高放得下图标 + 名字
    let columns = LaunchpadLayout.folderColumns
    let rows = model.folderRows
    // 面板的底（浅白的那一层）是 LaunchpadView 的 FolderPaper：这里只有名字、图标和页点，淡进淡出
    VStack(spacing: LaunchpadMetrics.folderTitleSpacing) {
      title
      VStack(spacing: 10) {
        grid(columns: columns, rows: rows)
        folderDots
      }
      .padding(LaunchpadMetrics.folderPadding)
    }
    .position(x: metrics.size.width / 2, y: metrics.size.height / 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.openFolder?.name ?? "文件夹")
  }

  /// 文件夹名：只有字那一块能点进编辑（照 macOS 15；2026-10-18 真机反馈：整行都能点）。框按字量出来的宽度，
  /// 跟着打的字变宽，最宽到面板那么宽；旁边的空处点了和点背景一样（提交改名、收起文件夹）。编辑时垫一块浅底
  private var title: some View {
    let text = model.folderNameDraft.isEmpty ? "文件夹名字" : model.folderNameDraft
    let width = min(
      ceil(NSAttributedString(string: text, attributes: [.font: Self.titleFont]).size().width) + 24,
      metrics.folderGridWidth)
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return Group {
      if editing {
        TextField("文件夹名字", text: $model.folderNameDraft)
          .textFieldStyle(.plain)
          .font(Font(Self.titleFont))
          .foregroundStyle(.white.opacity(0.96))
          .multilineTextAlignment(.center)
          .focused($editingName)
          .onAppear {
            // 换成输入框的这一下就拿焦点（下一轮：这一轮它还没挂进窗口）
            DispatchQueue.main.async { editingName = true }
          }
          .onSubmit { finishEditing() }
          .onChange(of: editingName) { _, focused in
            if !focused { finishEditing() }
          }
          .onExitCommand {
            finishEditing()
            model.closeFolder()
          }
      } else {
        Text(text)
          .font(Font(Self.titleFont))
          .foregroundStyle(.white.opacity(0.96))
          .lineLimit(1)
          .truncationMode(.tail)
          .contentShape(Rectangle())
          .onTapGesture { editing = true }
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("改名")
      }
    }
    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    .frame(width: width, height: LaunchpadMetrics.folderTitleHeight)
    .background(shape.fill(.white.opacity(editing ? 0.14 : 0)))
    .animation(.easeOut(duration: Style.fadeIn), value: editing)
  }

  private func finishEditing() {
    commitName()
    editing = false
  }

  private static let titleFont = NSFont.systemFont(ofSize: 28, weight: .medium)

  private func grid(columns: Int, rows: Int) -> some View {
    let pages = model.openFolder?.pages ?? []
    let gridWidth = metrics.folderGridWidth
    let gridHeight = metrics.folderCellHeight * CGFloat(rows)
    return HStack(spacing: 0) {
      ForEach(pages.indices, id: \.self) { page in
        folderPage(page, columns: columns, rows: rows)
          .frame(width: gridWidth, height: gridHeight, alignment: .top)
      }
    }
    .frame(width: gridWidth, height: gridHeight, alignment: .leading)
    .offset(x: -CGFloat(model.folderPage) * gridWidth + model.folderPageOffset)
    .frame(width: gridWidth, height: gridHeight, alignment: .leading)
    .clipped()
    // 翻页的动画由模型给（同主网格，松手时带着手指的速度）
  }

  /// 一页文件夹：拖着的时候手里那个拿掉、落点处空着（别的让位，同主网格）
  /// 一页文件夹：同主网格，每个图标按自己的 id 摆在它那一格（拖着的时候手里那个拿掉、落点处空着，别的真的滑过去让位）
  private func folderPage(_ page: Int, columns: Int, rows: Int) -> some View {
    let apps = model.folderPreview(page: page)
    let cellWidth = metrics.folderCellWidth
    let cellHeight = metrics.folderCellHeight
    let placed = apps.enumerated().compactMap { index, ref in
      ref.flatMap { ref in
        model.app(ref).map { (index: index, ref: ref, app: $0) }
      }
    }
    return ZStack(alignment: .topLeading) {
      ForEach(placed, id: \.ref.id) { item in
        folderCell(
          item.app, ref: item.ref, index: item.index, iconSize: metrics.folderIcon,
          live: page == model.folderPage
        )
        .frame(width: cellWidth, height: cellHeight)
        .position(
          x: (CGFloat(item.index % columns) + 0.5) * cellWidth,
          y: (CGFloat(item.index / columns) + 0.5) * cellHeight)
      }
    }
    .frame(
      width: cellWidth * CGFloat(columns), height: cellHeight * CGFloat(rows),
      alignment: .topLeading
    )
    .animation(reduceMotion ? nil : LaunchpadView.reflow, value: model.drag?.folderTarget)
  }

  private func folderCell(
    _ app: LaunchpadProjectApp, ref: LaunchpadAppRef, index: Int, iconSize: CGFloat,
    live: Bool
  ) -> some View {
    let selected = model.selected == index
    let pressed =
      model.pressedTileID == LaunchpadTile.app(ref).id
    let landing = model.landing?.tile.app?.id == ref.id
    return VStack(spacing: LaunchpadMetrics.folderLabelSpacing) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.launchpadFolderIcon, style: .continuous)
          .fill(.white.opacity(selected ? (contrast == .increased ? 0.22 : 0.16) : 0))
          .frame(width: iconSize * 1.22, height: iconSize * 1.22)
          .allowsHitTesting(false)
        AppIconView(
          image: model.icons.icon(for: app, size: iconSize), size: iconSize,
          jiggling: model.jiggling && live, phase: Double(index % 7) / 7, reduceMotion: reduceMotion
        )
        .frame(width: iconSize, height: iconSize)
      }
      // 和主网格一样只有图标算点到
      .contentShape(Rectangle().inset(by: iconSize * 0.11))
      .overlay(alignment: .topLeading) {
        if model.jiggling, LaunchpadCatalog.canDelete(app) {
          deleteBadge(app, size: iconSize)
        }
      }
      Text(app.name)
        .font(.system(size: LaunchpadMetrics.labelSize))
        .foregroundStyle(.white.opacity(0.96))
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: metrics.folderLabelWidth, height: LaunchpadMetrics.folderLabelHeight)
        .allowsHitTesting(false)
    }
    .opacity(landing ? 0 : (pressed ? 0.82 : 1))
    .scaleEffect(reduceMotion ? 1 : (pressed ? 0.94 : 1))
    .animation(Style.Motion.snap.animation(), value: pressed)
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
        .onChanged { value in
          if model.drag == nil {
            model.beginDrag(
              tile: .app(ref), appID: ref.id, folder: model.openFolderID, at: value.startLocation,
              origin: model.folderCellCenter(index))
          }
          model.updateDrag(location: value.location, pageWidth: metrics.size.width)
        }
        .onEnded { _ in model.endDrag() }
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(app.name)
    .accessibilityHint("打开")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.open(app: ref) }
  }

  private func deleteBadge(_ app: LaunchpadProjectApp, size: CGFloat) -> some View {
    Button {
      model.requestDelete(app)
    } label: {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: max(16, size * 0.3)))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, .black.opacity(0.72))
        .background(Circle().fill(.white.opacity(0.9)).padding(1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("删除「\(app.name)」")
  }

  private func commitName() {
    guard let id = model.openFolderID else { return }
    if model.folderNameDraft != model.openFolder?.name {
      model.renameFolder(id, to: model.folderNameDraft)
    }
  }

  private var folderDots: some View {
    HStack(spacing: 9) {
      ForEach(0..<model.folderPageCount, id: \.self) { index in
        Circle()
          .fill(.white.opacity(index == model.folderPage ? 0.92 : 0.35))
          .frame(width: 7, height: 7)
          .contentShape(Rectangle().inset(by: -6))
          .onTapGesture { model.goToFolderPage(index) }
          .accessibilityLabel("第 \(index + 1) 页")
          .accessibilityAddTraits(index == model.folderPage ? [.isSelected, .isButton] : .isButton)
          .accessibilityAction { model.goToFolderPage(index) }
      }
    }
    .opacity(model.folderPageCount > 1 ? 1 : 0)
  }
}
