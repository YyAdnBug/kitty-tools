// 启动台的界面（SPEC R1–R6）：模糊的壁纸上一页图标，顶上搜索框，底下页点。图标按屏幕大小排成列 × 行，
// 位置和大小照 macOS 15 的比例（LaunchpadMetrics，2026-10-18 真机反馈后）；
// 两指滑 / 滚轮翻页（跟手 1:1、松手按位移和速度翻，F17）；方向键在格子间挪、到页边翻页；点图标打开 App；
// 按住稍拖就拿起（跟手、别的图标让位、拖到边上翻页、停在另一个图标中心 0.4 秒才建文件夹，F1 / F3），
// 按住 1 秒或按着 ⌥ 进抖动模式（App Store 装的出 ✕，确认后移到废纸篓）；文件夹照 macOS 15 在屏幕中间展开：
// 后面的网格模糊压暗，一块浅色毛玻璃面板（7 列、按内容行数定高、内部分页、拖出 / 拖进，F34），名字在面板上方、点一下能改。
// 一点空白处收起；Esc 逐层退（拖动 → 抖动 → 文件夹 → 搜索 → 收起）。减弱动态效果：不缩放、不跟手、不抖，翻页直接换。
// 抖动用图层（每个图标的相位不同，不在每帧重排上百个视图，F35）。
// 文件夹那几层在 LaunchpadFolderView.swift，图标视图（抖动）在 LaunchpadIconView.swift。

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
  /// 量格子位置用：文件夹开着时网格缩了，这层在缩之前，量到的还是没缩的位置
  nonisolated static let gridSpace = "launchpad-grid"

  var body: some View {
    GeometryReader { proxy in
      let metrics = model.metrics
      ZStack(alignment: .top) {
        background
        // 文件夹开着时后面这一整块缩到 0.97（照 macOS 15）。格子位置在缩之前那层坐标里量（gridSpace，和 space 原点重合）：
        // 落点、纸的起止都按没缩的位置算，不跟着动画变；缩着的时候主网格被文件夹的底挡着，不接拖动
        let shrink = model.openFolderID != nil && !reduceMotion
        ZStack(alignment: .top) {
          searchField(metrics)
            .padding(.top, metrics.searchTop)
          pager(proxy.size, metrics: metrics)
            .padding(.top, metrics.gridTop)
          pageDots
            .position(x: proxy.size.width / 2, y: metrics.dotsY)
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        .coordinateSpace(name: Self.gridSpace)
        .visualEffect { content, _ in content.scaleEffect(shrink ? 0.97 : 1) }
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
            proxy.frame(in: .named(Self.gridSpace))
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

/// 一页里的一个图标和它摆在第几格（按图标的 id 认：落点变了，它从原来那格滑过去）
private struct PlacedTile: Identifiable {
  let index: Int
  let tile: LaunchpadTile
  var id: String { tile.id }
}
