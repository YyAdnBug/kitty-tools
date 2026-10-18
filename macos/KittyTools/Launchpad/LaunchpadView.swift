// 启动台的界面（SPEC R1–R6）：模糊的壁纸上一页图标，顶上搜索框，底下页点。图标按屏幕大小排成列 × 行，
// 位置和大小照 macOS 15 的比例（LaunchpadMetrics，2026-10-18 真机反馈后）；
// 两指滑 / 滚轮翻页（跟手 1:1、松手按位移和速度翻，F17）；方向键在格子间挪、到页边翻页；点图标打开 App；
// 按住稍拖就拿起（跟手、别的图标让位、拖到边上翻页、停在另一个图标中心 0.4 秒才建文件夹，F1 / F3），
// 按住 1 秒或按着 ⌥ 进抖动模式（App Store 装的出 ✕，确认后移到废纸篓）；文件夹照 macOS 15 在屏幕中间展开：
// 后面的网格模糊压暗，一块浅色毛玻璃面板（7 列、按内容行数定高、内部分页、拖出 / 拖进，F34），名字在面板上方、点一下能改。
// 一点空白处收起；Esc 逐层退（拖动 → 抖动 → 文件夹 → 搜索 → 收起）。减弱动态效果：不缩放、不跟手、不抖，翻页直接换。
// 抖动用图层（每个图标的相位不同，不在每帧重排上百个视图，F35）。

import AppKit
import SwiftUI

struct LaunchpadView: View {
  @Bindable var model: LaunchpadModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var appeared = false
  /// 文件夹面板那块纸（开着、正在缩回去的时候都在；缩完了拆掉）
  @State private var folderSheet: FolderSheet?

  /// 拖动、落点、格子位置都按这个命名坐标空间算（面板本地坐标）
  nonisolated static let space = "launchpad"

  var body: some View {
    GeometryReader { proxy in
      let metrics = model.metrics
      ZStack(alignment: .top) {
        background
        searchField(metrics)
          .padding(.top, metrics.searchTop)
        pager(proxy.size, metrics: metrics)
          .padding(.top, metrics.gridTop)
        pageDots
          .position(x: proxy.size.width / 2, y: metrics.dotsY)
        // 层次写死（zIndex）：ZStack 里正在离场的视图，SwiftUI 会把它挪到兄弟视图下面画——关文件夹时面板就缩到网格和不透明的壁纸
        // 后面去了，只看得见后面那层淡掉，像「没有动画」（2026-10-18 真机反馈两次；进场的总在上面，所以打开一直是好的）
        if model.openFolderID != nil {
          FolderBackdrop(model: model)
            .transition(.opacity)
            .zIndex(1)
        }
        // 面板那块纸（同便签墙的编辑卡）：打开时从文件夹方块那儿长到屏幕中间，关的时候从中间一路缩回文件夹方块
        // （圆角、底色也变回方块的样子），纸一直不透明；里面的图标和名字晚一点淡进来、关的时候先淡掉
        if let sheet = folderSheet {
          FolderPaper(
            sheet: sheet,
            panel: model.openFolderID == sheet.id ? model.folderPanelRect : sheet.panel
          )
          .id(sheet.serial)
          .zIndex(2)
        }
        if model.openFolderID != nil {
          FolderOverlay(model: model, metrics: metrics, space: Self.space)
            .transition(folderContentTransition)
            .zIndex(3)
        }
        dragGhost(metrics: metrics)
          .zIndex(4)
      }
      // 拖动的「挪 / 松手」另在最外层收一份：格子只负责按下。拖出文件夹时文件夹那块界面会被拆掉，挂在格子上的手势跟着被取消、
      // 松手收不到（同 G30）；最外层这份一直在。两份都喂进去没关系：模型按同一个指针位置算，松手第二次进来时已经没有拖动了
      .simultaneousGesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
          .onChanged { value in
            guard model.drag != nil else { return }
            model.updateDrag(location: value.location, pageWidth: metrics.size.width)
          }
          .onEnded { _ in
            guard model.drag != nil else { return }
            model.endDrag()
          }
      )
      .coordinateSpace(name: Self.space)
      // initial：界面出来时文件夹就开着（截图自检这么摆）——纸直接在面板的位置，不长
      .onChange(of: model.openFolderID, initial: true) { old, new in
        folderChanged(from: old, to: new)
      }
      .opacity(appeared ? (model.isClosing ? 0 : 1) : 0)
      .scaleEffect(scale)
      .animation(openAnimation, value: appeared)
      .animation(closingAnimation, value: model.isClosing)
      .onAppear {
        withAnimation(openAnimation) { appeared = true }
      }
    }
    .confirmationDialog(
      "删除「\(model.deleteCandidate?.name ?? "")」？",
      isPresented: Binding {
        model.deleteCandidate != nil
      } set: {
        if !$0 { model.deleteCandidate = nil }
      }
    ) {
      Button("删除", role: .destructive) { model.confirmDelete() }
      Button("取消", role: .cancel) { model.deleteCandidate = nil }
    } message: {
      Text("这个 App 会被移到废纸篓。")
    }
  }

  private var scale: CGFloat {
    if reduceMotion { return 1 }
    if model.isClosing { return 0.97 }
    return appeared ? 1 : 1.1
  }

  private var openAnimation: Animation {
    reduceMotion
      ? .easeOut(duration: Style.fadeIn)
      : (Style.Motion.pop.animation() ?? .easeOut(duration: 0.32))
  }

  private var closingAnimation: Animation { .easeOut(duration: Style.fadeIn) }

  /// 让位的动画：0.45 s、不弹，从当前位置接着动（照同类里最像 macOS 15 的那个：强 ease-out，弹簧写法同 Whisker 的签名时刻）
  static let reflow = Animation.spring(duration: 0.45, bounce: 0)

  /// 文件夹里的内容（名字、图标、页点）：晚一点淡进来（纸先长出去），关的时候先淡掉（纸再缩回去），同便签墙的编辑区
  private var folderContentTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: Style.fadeIn).delay(0.08)),
        // 关的时候比便签墙的编辑区淡得更快、一开始就掉：纸马上往文件夹那儿走，慢慢淡的话图标像被留在了中间（屏上逐帧录过）
        removal: .opacity.animation(.easeOut(duration: 0.07)))
  }

  /// 文件夹开了 / 关了（点开、停在上面打开；点空白、Esc、拖出去、解散）：开了，纸从那个文件夹方块**现在**的位置长到中间；
  /// 关了，纸缩回方块**现在**的位置（它不在这一页了——被解散、翻走了——就在中间缩一点淡掉）。减弱动态效果时只淡入淡出
  private func folderChanged(from old: UUID?, to new: UUID?) {
    if let new {
      // 第一次（initial）进来时 old == new：本来就开着，纸直接在面板那儿
      let already = old == new
      folderSheet = FolderSheet(
        id: new, from: reduceMotion || already ? nil : model.folderGlyphRect(new),
        panel: model.folderPanelRect, grown: reduceMotion || already)
      return
    }
    guard let old, var closing = folderSheet, closing.id == old, !closing.isClosing else { return }
    guard !reduceMotion else {
      folderSheet = nil
      return
    }
    closing.isClosing = true
    closing.to = model.folderGlyphRect(old)
    let serial = closing.serial
    withAnimation(Style.Motion.settle.animation()) {
      folderSheet = closing
    } completion: {
      if folderSheet?.serial == serial { folderSheet = nil }
    }
  }

  /// 壁纸模糊后的样子再轻轻压暗（照 macOS 15）；拿不到壁纸时是面板底下的系统毛玻璃，压暗一点
  private var background: some View {
    ZStack {
      if let wallpaper = model.wallpaper {
        Image(decorative: wallpaper, scale: 1)
          .resizable()
          .transition(.opacity)
        Color.black.opacity(0.14)
      } else {
        Color.black.opacity(0.12)
      }
    }
    .animation(.easeOut(duration: Style.fadeIn), value: model.wallpaper != nil)
    .ignoresSafeArea()
    .contentShape(Rectangle())
    // 空白处按住左右拖 = 跟手翻页（照 macOS 15）；没挪够 5 pt 就松手 = 点了空白（收起 / 退抖动）
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          model.backgroundDragChanged(
            translation: value.translation, time: value.time.timeIntervalSinceReferenceDate)
        }
        .onEnded { value in
          model.backgroundDragEnded(time: value.time.timeIntervalSinceReferenceDate)
        }
    )
    .accessibilityLabel("启动台")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.backgroundClicked() }
  }

  // MARK: 顶上搜索

  /// 顶上居中、约 1/6 屏宽的浅色半透明圆角框；没打字时「放大镜 + 搜索」整组居中、插入点藏起来，打了字移到左边（照 macOS 15）
  private func searchField(_ metrics: LaunchpadMetrics) -> some View {
    let empty = model.query.isEmpty
    return HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
        .opacity(empty ? 0 : 1)
        .accessibilityHidden(true)
      CommandTextField(
        text: $model.query, placeholder: "", fontSize: 14, textColor: .white,
        caretColor: empty ? .clear : .white,
        onCommand: { selector in
          switch selector {
          case #selector(NSResponder.moveLeft(_:)):
            model.navigate(.left)
            return true
          case #selector(NSResponder.moveRight(_:)):
            model.navigate(.right)
            return true
          case #selector(NSResponder.moveUp(_:)):
            model.navigate(.up)
            return true
          case #selector(NSResponder.moveDown(_:)):
            model.navigate(.down)
            return true
          case #selector(NSResponder.insertNewline(_:)):
            model.returnPressed()
            return true
          case #selector(NSResponder.cancelOperation(_:)):
            model.cancel()
            return true
          default:
            return false
          }
        }
      )
      .frame(height: 20)
    }
    .padding(.horizontal, 10)
    .frame(width: metrics.searchWidth, height: LaunchpadMetrics.searchHeight)
    .overlay {
      if empty {
        HStack(spacing: 5) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .medium))
          Text("搜索")
            .font(.system(size: 14))
        }
        .foregroundStyle(.white.opacity(0.62))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: Style.Radius.launchpadSearch, style: .continuous)
        .fill(.white.opacity(contrast == .increased ? 0.24 : 0.16))
    )
    .overlay {
      RoundedRectangle(cornerRadius: Style.Radius.launchpadSearch, style: .continuous)
        .stroke(.white.opacity(0.18), lineWidth: Style.hairlineWidth(contrast))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("搜索")
  }

  // MARK: 网格

  private func pager(_ size: CGSize, metrics: LaunchpadMetrics) -> some View {
    let pages = model.displayPages
    return HStack(spacing: 0) {
      ForEach(pages.indices, id: \.self) { index in
        pageGrid(index, metrics: metrics)
          .frame(width: size.width, height: metrics.gridHeight, alignment: .top)
          .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.space))
          } action: { frame in
            model.gridFrames[index] = frame
          }
      }
    }
    .frame(width: size.width * CGFloat(max(pages.count, 1)), alignment: .leading)
    .offset(x: -CGFloat(model.page) * size.width + model.pageOffset)
    .frame(width: size.width, alignment: .leading)
    .clipped()
    .animation(reduceMotion ? nil : Style.Motion.glide.animation(), value: model.page)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.isSearching ? "搜索结果" : "第 \(model.page + 1) 页")
  }

  /// 一页：每个图标按**自己的 id** 摆在它那一格的位置上，不是「第几格画谁」——落点一变，让位的图标真的从原来那格滑到新的那格，
  /// 换行的那个斜着滑过去（照 macOS 15；原来格子按位置建、只是换了格子里画的图标，看不到滑动，2026-10-18 真机反馈）。空位就是空着。
  /// 按住挂在每个图标上（只管按下）；挪和松手由最外层那份收——拖动一激活手里那个就从这一页拿掉了，它身上的手势会被取消（G30）
  private func pageGrid(_ pageIndex: Int, metrics: LaunchpadMetrics) -> some View {
    let slots = model.previewTiles(page: pageIndex)
    let gap = model.gapIndex(page: pageIndex)
    let columns = max(model.columns, 1)
    let placed = slots.enumerated().compactMap { index, tile in
      tile.flatMap { index < model.capacity ? PlacedTile(index: index, tile: $0) : nil }
    }
    return ZStack(alignment: .topLeading) {
      ForEach(placed) { item in
        tileCell(
          item.tile, index: item.index, metrics: metrics, iconSize: metrics.icon,
          live: pageIndex == model.page
        )
        .gesture(
          cellGesture(page: pageIndex, tile: item.tile, index: item.index, metrics: metrics)
        )
        .position(
          x: (CGFloat(item.index % columns) + 0.5) * metrics.cellWidth,
          y: (CGFloat(item.index / columns) + 0.5) * metrics.cellHeight)
      }
    }
    .frame(width: metrics.gridWidth, height: metrics.gridHeight, alignment: .topLeading)
    .animation(reduceMotion ? nil : Self.reflow, value: gap)
  }

  /// 按下：记下按的是哪一格（挪 / 松手两边都喂：这一份、最外层那份，模型按同一个指针位置算）。搜索时也记下按下：单击打开结果，但不许拖（F5）
  private func cellGesture(
    page pageIndex: Int, tile: LaunchpadTile, index: Int, metrics: LaunchpadMetrics
  ) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { value in
        if model.drag == nil {
          model.beginDrag(
            tile: tile, appID: tile.app?.id, folder: nil, at: value.startLocation,
            origin: model.cellCenter(page: pageIndex, index: index))
        }
        model.updateDrag(location: value.location, pageWidth: metrics.size.width)
      }
      .onEnded { _ in model.endDrag() }
  }

  /// `live`：这一页正看着（只有它的图标在抖）；搜索结果、跟手的那份不传
  private func tileCell(
    _ tile: LaunchpadTile, index: Int, metrics: LaunchpadMetrics, iconSize: CGFloat,
    live: Bool = true
  ) -> some View {
    let selected = model.selected == index
    let isDragged = model.drag?.tileID == tile.id && model.drag?.isDragging == true
    let pressed = model.pressedTileID == tile.id
    let combined = model.drag?.combineTileID == tile.id
    let landing = model.landing?.tile.id == tile.id
    return VStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.launchpadIcon, style: .continuous)
          .fill(.white.opacity(selected ? (contrast == .increased ? 0.22 : 0.16) : 0))
          .frame(width: iconSize * 1.22, height: iconSize * 1.22)
          .allowsHitTesting(false)
        if combined {
          // 停够了要合成：目标后面长出一块浅色圆角底板（像文件夹的样子），目标本身不放大
          combinePlate(size: iconSize)
            .transition(.scale(scale: 0.15).combined(with: .opacity))
        }
        icon(for: tile, size: iconSize, phase: Double(index % 7) / 7, jiggles: live)
      }
      // 只有图标那一块算点到（照 macOS 15；2026-10-18 真机反馈：点名字、图标旁边的空处也打开了）。
      // 外面那圈是选中底的留白（1.22 倍），文件夹方块本身只有图标的 0.8
      .contentShape(Rectangle().inset(by: iconSize * (tile.folder == nil ? 0.11 : 0.21)))
      .overlay(alignment: .topLeading) {
        if model.jiggling, let app = tile.app.flatMap({ model.app($0) }),
          LaunchpadCatalog.canDelete(app)
        {
          deleteBadge(app, size: iconSize)
        }
      }
      Text(model.title(of: tile))
        .font(.system(size: LaunchpadMetrics.labelSize, weight: .regular))
        .foregroundStyle(.white.opacity(0.96))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: metrics.labelWidth)
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
        .allowsHitTesting(false)
    }
    .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    // 松手后那一份还在滑过来：落点上这一格先不画，到了再换上
    .opacity(isDragged || landing ? 0 : (pressed ? 0.82 : 1))
    .scaleEffect(reduceMotion ? 1 : (pressed ? 0.94 : 1))
    .animation(Style.Motion.snap.animation(), value: pressed)
    .animation(Style.Motion.snap.animation(), value: combined)
    .help(model.title(of: tile))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.title(of: tile))
    .accessibilityHint(tile.folder == nil ? "打开" : "打开文件夹")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.open(tile) }
  }

  /// 合成底板：和文件夹方块同一种浅色半透明（圆角 25%），比文件夹方块大一圈，把目标图标框在里面
  private func combinePlate(size: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
    return
      shape
      .fill(.white.opacity(contrast == .increased ? 0.4 : 0.32))
      .overlay { shape.stroke(.white.opacity(0.22), lineWidth: 0.5) }
      .frame(width: size * 1.05, height: size * 1.05)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func deleteBadge(_ app: LaunchpadProjectApp, size: CGFloat) -> some View {
    Button {
      model.requestDelete(app)
    } label: {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: max(18, size * 0.26)))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, .black.opacity(0.72))
        .background(Circle().fill(.white.opacity(0.9)).padding(1))
    }
    .buttonStyle(.plain)
    .offset(x: -size * 0.06, y: -size * 0.06)
    .accessibilityLabel("删除「\(app.name)」")
  }

  @ViewBuilder
  private func icon(
    for tile: LaunchpadTile, size: CGFloat, phase: Double = 0, jiggles: Bool = true
  ) -> some View {
    switch tile {
    case .app(let ref):
      if let app = model.app(ref) {
        // 主网格一直是 AppKit 的图层视图（抖动只加一个图层动画，几乎不占主线程；不在两种视图之间换，进出编辑不闪）
        JigglingIcon(
          image: model.icons.icon(for: app, size: size), size: size,
          active: model.jiggling && jiggles, phase: phase, reduceMotion: reduceMotion
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
      } else {
        placeholderIcon(size: size)
      }
    case .folder(let folder):
      // 文件夹方块比 App 图标小一圈：App 图标那张图自己带留白（F34）
      FolderGlyph(folder: folder, model: model, size: size * 0.8, phase: phase, jiggles: jiggles)
    }
  }

  private func placeholderIcon(size: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
      .fill(.white.opacity(0.12))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: "questionmark.app.dashed")
          .font(.system(size: size * 0.4))
          .foregroundStyle(.white.opacity(0.5))
      }
      .accessibilityHidden(true)
  }

  // MARK: 页点

  private var pageDots: some View {
    // 拖到最后一页的右边缘停够了：多画一个亮着的页点，表示松手会新开一页（G10）
    let appending = model.drag?.appendsPage == true
    return HStack(spacing: 9) {
      ForEach(0..<model.pageCount, id: \.self) { index in
        dot(active: index == model.page && !appending) { model.go(to: index) }
          .accessibilityLabel("第 \(index + 1) 页")
          .accessibilityAddTraits(index == model.page ? [.isSelected, .isButton] : .isButton)
          .accessibilityAction { model.go(to: index) }
      }
      if appending {
        dot(active: true) {}
          .accessibilityLabel("新的一页")
      }
    }
    .opacity(model.pageCount > 1 || appending ? 1 : 0)
    .padding(.bottom, 16)
    .accessibilityElement(children: .contain)
  }

  private func dot(active: Bool, action: @escaping () -> Void) -> some View {
    Circle()
      .fill(.white.opacity(active ? 0.92 : 0.35))
      .frame(width: 7, height: 7)
      .contentShape(Rectangle().inset(by: -6))
      .onTapGesture(perform: action)
  }

  // MARK: 拖动时跟着鼠标的那一份

  /// 拖着的时候跟着指针（放大 1.1、淡阴影、不抖；指针在图标哪儿就一直在哪儿）；松手 / 取消后按 `model.landing` 滑进落点 / 滑回原位
  @ViewBuilder
  private func dragGhost(metrics: LaunchpadMetrics) -> some View {
    if let drag = model.drag, drag.isDragging, let tile = model.ghostTile(drag) {
      ghost(tile, size: metrics.icon)
        .scaleEffect(reduceMotion ? 1 : 1.1)
        .position(model.ghostCenter(drag))
    } else if let landing = model.landing {
      ghost(landing.tile, size: metrics.icon)
        .scaleEffect(landing.scale)
        .opacity(landing.opacity)
        .position(landing.position)
    }
  }

  private func ghost(_ tile: LaunchpadTile, size: CGFloat) -> some View {
    VStack(spacing: 6) {
      icon(for: tile, size: size, jiggles: false)
      Text(model.title(of: tile))
        .font(.system(size: LaunchpadMetrics.labelSize))
        .foregroundStyle(.white.opacity(0.96))
        .lineLimit(1)
    }
    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// 文件夹面板那块纸的状态（同便签墙的 WallSheet）：哪个文件夹、从哪长出来（文件夹方块的框；nil = 在中间略小一圈）、
/// 开着时面板在哪（关的时候它已经不在 model 里了）、正在缩回没有、缩回哪。每打开一次一个新编号：缩完时认它
private struct FolderSheet {
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

/// 面板那块纸：打开时从文件夹方块长到面板的位置（glide，出现的那一刻开始），关的时候缩回方块（settle，动画在外面给）；
/// 圆角和底色也跟着在面板（26 pt、white 0.14）和文件夹方块（边长的 22%、white 0.32）之间变，落下去就是那个方块的样子。
/// 没有方块可回（不在这一页了）就在中间缩一点淡掉
private struct FolderPaper: View {
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
        withAnimation(Style.Motion.glide.animation()) { grown = true }
      }
      .accessibilityHidden(true)
  }
}

/// App 图标：抖动时用图层转 ±1.5°（每个图标相位不同）。不走 SwiftUI 的 rotationEffect + repeatForever，
/// 那会让上百个视图每帧重排（F35 / R11）。
/// 抖动的那一下转动（纯函数，单测直接喂）：绕图标的中心转。layer-backed 视图的 anchorPoint 不一定是中心
/// （AppKit 默认左下角），把转轴从 anchor 挪到中心：先平移 −p、转、再平移 +p，p = 中心相对 anchor 的偏移（G15）
nonisolated enum LaunchpadJiggle {
  static func transform(degrees: Double, size: CGSize, anchor: CGPoint) -> CGAffineTransform {
    let pivot = CGPoint(x: (0.5 - anchor.x) * size.width, y: (0.5 - anchor.y) * size.height)
    return CGAffineTransform(translationX: pivot.x, y: pivot.y)
      .rotated(by: degrees * .pi / 180)
      .translatedBy(x: -pivot.x, y: -pivot.y)
  }
}

/// 没有固有尺寸的 NSImageView：大小只听 SwiftUI 给的 frame。普通的 NSImageView 拿图的尺寸当固有尺寸，抗压缩优先级又高，
/// SwiftUI 缩不到比图小——位图按最大那块屏画，换到图标小一些的屏上图标（和点得到的范围）就比格子要的大（2026-10-18 单测量出来的）
final class IconImageView: NSImageView {
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }
}

private struct JigglingIcon: NSViewRepresentable {
  let image: NSImage
  let size: CGFloat
  let active: Bool
  let phase: Double
  let reduceMotion: Bool

  func makeNSView(context: Context) -> IconImageView {
    let view = IconImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    return view
  }

  func updateNSView(_ view: IconImageView, context: Context) {
    view.image = image
    // 不碰 frame / anchorPoint / bounds：layer-backed 视图的几何归 AppKit / SwiftUI 管，改了会被布局复位、
    // 图标偏半个边长或绕着角转（G15）。转轴按图层**现在的** anchorPoint 算到图标中心上
    guard let layer = view.layer else { return }
    if active, !reduceMotion {
      if layer.animation(forKey: "launchpad-jiggle") == nil {
        let side = CGSize(width: size, height: size)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(
          caTransform3D: CATransform3DMakeAffineTransform(
            LaunchpadJiggle.transform(degrees: -1.5, size: side, anchor: layer.anchorPoint)))
        animation.toValue = NSValue(
          caTransform3D: CATransform3DMakeAffineTransform(
            LaunchpadJiggle.transform(degrees: 1.5, size: side, anchor: layer.anchorPoint)))
        animation.duration = 0.13
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timeOffset = phase * 0.26
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "launchpad-jiggle")
      }
    } else {
      layer.removeAnimation(forKey: "launchpad-jiggle")
    }
  }
}

/// 文件夹面板里的 App 图标：平时是 SwiftUI 的 Image（建得快：35 个的文件夹展开第一帧约 30 ms，全用 NSImageView 约 50 ms），
/// 抖动时换成图层抖动的 `JigglingIcon`（35 个主线程约 7%；SwiftUI 自己的 repeatForever 要 18–24%）。**换的时候不带动画**
/// （`.transition(.identity)` + 事务里去掉动画）：原来这一换跟着进抖动的动画淡出淡入，每个图标发白一下，看着闪（2026-10-18 真机反馈）；
/// 不带动画就不闪，屏上实录自检量过（LaunchpadAnimationLiveTests：和静止时最多差约 0.02，带动画的那版约 0.07）。主网格一直是 `JigglingIcon`
private struct AppIconView: View {
  let image: NSImage
  let size: CGFloat
  let jiggling: Bool
  let phase: Double
  let reduceMotion: Bool

  var body: some View {
    Group {
      if jiggling, !reduceMotion {
        JigglingIcon(image: image, size: size, active: true, phase: phase, reduceMotion: false)
      } else {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      }
    }
    .transition(.identity)
    .transaction { $0.animation = nil }
  }
}

/// SwiftUI 的抖动（文件夹面板里的图标、主网格的文件夹方块）：绕中心 ±1.5° 来回（0.13 s 一程），按格序晚一点开始、彼此错开。
/// 只转、不改布局；只有看得见的那一页在抖（R11）
private struct Jiggle: ViewModifier {
  let active: Bool
  let phase: Double
  @State private var tilted = false

  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(active ? (tilted ? 1.5 : -1.5) : 0))
      .onChange(of: active, initial: true) { _, on in
        if on {
          // 下一轮再开始：和进抖动同一轮的布局变化别被这条一直重复的动画带上
          DispatchQueue.main.async {
            withAnimation(
              .easeInOut(duration: 0.13).repeatForever(autoreverses: true).delay(phase * 0.13)
            ) { tilted = true }
          }
        } else {
          withAnimation(.easeOut(duration: 0.1)) { tilted = false }
        }
      }
  }
}

/// 一页里的一个图标和它摆在第几格（按图标的 id 认：落点变了，它从原来那格滑过去）
private struct PlacedTile: Identifiable {
  let index: Int
  let tile: LaunchpadTile
  var id: String { tile.id }
}

/// 文件夹图标：一块浅色半透明圆角底（照 macOS 15），里面按 3 × 3 画前 9 个 App 的小图标。文件夹里一个都没有时画系统的文件夹符号。
/// 抖动和 App 图标同一个 `Jiggle`。
private struct FolderGlyph: View {
  let folder: LaunchpadFolder
  let model: LaunchpadModel
  let size: CGFloat
  let phase: Double
  /// 这一页正看着（只有它抖）
  var jiggles = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    glyph
      .modifier(Jiggle(active: model.jiggling && jiggles && !reduceMotion, phase: phase))
      .accessibilityHidden(true)
  }

  private var glyph: some View {
    let mini = size * 0.255
    let apps = folder.apps.prefix(9).compactMap { model.app($0) }
    let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
    return
      shape
      .fill(.white.opacity(0.32))
      .overlay { shape.stroke(.white.opacity(0.22), lineWidth: 0.5) }
      .overlay {
        if apps.isEmpty {
          Image(systemName: "folder.fill")
            .font(.system(size: size * 0.44))
            .foregroundStyle(.white.opacity(0.55))
        } else {
          VStack(spacing: size * 0.055) {
            ForEach(0..<3, id: \.self) { row in
              HStack(spacing: size * 0.055) {
                ForEach(0..<3, id: \.self) { column in
                  let index = row * 3 + column
                  if index < apps.count {
                    Image(nsImage: model.icons.icon(for: apps[index], size: mini))
                      .resizable()
                      .interpolation(.high)
                      .frame(width: mini, height: mini)
                  } else {
                    Color.clear.frame(width: mini, height: mini)
                  }
                }
              }
            }
          }
        }
      }
      .frame(width: size, height: size)
  }
}

/// 打开文件夹时后面那一层：整张网格糊掉（材质在窗口里取后面的内容，图标的 NSImageView 也一起糊），上面再铺八成的壁纸、
/// 压暗一层，只剩一点糊掉的网格影子，面板里外的字不会混在一起（材质一律按深色：面板窗口本来就是深色）。点它收起文件夹
private struct FolderBackdrop: View {
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
private struct FolderOverlay: View {
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
    .animation(reduceMotion ? nil : Style.Motion.glide.animation(), value: model.folderPage)
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
