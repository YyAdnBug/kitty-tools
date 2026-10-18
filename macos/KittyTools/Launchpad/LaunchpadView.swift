// 启动台的界面（SPEC R1–R6）：压暗的桌面上一页图标，顶上搜索框，底下页点。图标按屏幕大小排成列 × 行；
// 两指滑 / 滚轮翻页（跟手 1:1、松手按位移和速度翻，F17）；方向键在格子间挪、到页边翻页；点图标打开 App；
// 按住稍拖就拿起（跟手、别的图标让位、拖到边上翻页、停在另一个图标中心 0.4 秒才建文件夹，F1 / F3），
// 按住 1 秒或按着 ⌥ 进抖动模式（App Store 装的出 ✕，确认后移到废纸篓）；文件夹在原地展开成一块面板
// （7 列、按内容行数定高、改名、内部分页、拖出 / 拖进，F34）。
// 一点空白处收起；Esc 逐层退（拖动 → 抖动 → 文件夹 → 搜索 → 收起）。减弱动态效果：不缩放、不跟手、不抖，翻页直接换。
// 抖动用图层（每个图标的相位不同，不在每帧重排上百个视图，F35）。

import AppKit
import SwiftUI

struct LaunchpadView: View {
  @Bindable var model: LaunchpadModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var appeared = false

  /// 拖动、落点、格子位置都按这个命名坐标空间算（面板本地坐标）
  nonisolated static let space = "launchpad"

  var body: some View {
    GeometryReader { proxy in
      let metrics = model.metrics
      ZStack(alignment: .top) {
        background
        VStack(spacing: 0) {
          searchField
            .padding(.top, metrics.searchTop)
          Spacer(minLength: 12)
          pager(proxy.size, metrics: metrics)
          Spacer(minLength: 12)
          pageDots
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if model.openFolderID != nil {
          FolderOverlay(model: model, metrics: metrics, space: Self.space)
            .transition(.opacity)
        }
        dragGhost(metrics: metrics)
      }
      .coordinateSpace(name: Self.space)
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

  private var background: some View {
    Color.black.opacity(0.30)
      .ignoresSafeArea()
      .contentShape(Rectangle())
      .onTapGesture { model.backgroundClicked() }
      .accessibilityLabel("启动台")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { model.backgroundClicked() }
  }

  // MARK: 顶上搜索

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .accessibilityHidden(true)
      CommandTextField(
        text: $model.query, placeholder: "搜索", fontSize: 15,
        textColor: .white, placeholderColor: .white.withAlphaComponent(0.45),
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
    .padding(.horizontal, 12)
    .frame(width: 280, height: 32)
    .background(
      RoundedRectangle(cornerRadius: Style.Radius.launchpadSearch, style: .continuous)
        .fill(.black.opacity(0.28))
    )
    .overlay {
      RoundedRectangle(cornerRadius: Style.Radius.launchpadSearch, style: .continuous)
        .stroke(.white.opacity(0.16), lineWidth: Style.hairlineWidth(contrast))
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

  private func pageGrid(_ pageIndex: Int, metrics: LaunchpadMetrics) -> some View {
    let slots = model.previewTiles(page: pageIndex)
    let gap = model.gapIndex(page: pageIndex)
    return VStack(spacing: 0) {
      ForEach(0..<model.rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<model.columns, id: \.self) { column in
            let index = row * model.columns + column
            ZStack {
              if let tile = slots[safe: index] ?? nil {
                tileCell(tile, index: index, metrics: metrics, iconSize: metrics.icon)
              } else if gap == index {
                placeholder(metrics: metrics)
              } else {
                Color.clear
              }
            }
            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
            .gesture(cellGesture(page: pageIndex, index: index, metrics: metrics))
          }
        }
      }
    }
    .frame(width: metrics.gridWidth, height: metrics.gridHeight)
    .animation(reduceMotion ? nil : Style.Motion.settle.animation(), value: gap)
  }

  /// 按住 / 拖 / 松手挂在格子的**位置**上（这一格的 ZStack），不挂在图标上：拖动一激活，这一格就画成空位、图标的视图被拆掉，
  /// 挂在图标上的手势会被 SwiftUI 取消，onEnded 不来、拖动卡死（复查 G30；单测在事件之间强制重画才看得出来）。
  /// 按下时按位置找这一格现在画的是谁；点到格子里的空处不算（图标和名字以外交给背景，点空白收起）。
  /// 搜索时也记下按下：单击打开结果，但不许拖（F5）
  private func cellGesture(page pageIndex: Int, index: Int, metrics: LaunchpadMetrics)
    -> some Gesture
  {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { value in
        if model.drag == nil {
          guard let tile = model.previewTiles(page: pageIndex)[safe: index] ?? nil else { return }
          model.beginDrag(tile: tile, appID: tile.app?.id, folder: nil, at: value.startLocation)
        }
        model.updateDrag(location: value.location, pageWidth: metrics.size.width)
      }
      .onEnded { _ in model.endDrag() }
  }

  private func placeholder(metrics: LaunchpadMetrics) -> some View {
    RoundedRectangle(cornerRadius: Style.Radius.launchpadIcon, style: .continuous)
      .fill(.white.opacity(0.10))
      .frame(width: metrics.icon * 1.22, height: metrics.icon * 1.22)
      .accessibilityHidden(true)
  }

  private func tileCell(
    _ tile: LaunchpadTile, index: Int, metrics: LaunchpadMetrics, iconSize: CGFloat
  ) -> some View {
    let selected = model.selected == index
    let isDragged = model.drag?.tileID == tile.id && model.drag?.isDragging == true
    let pressed = model.pressedTileID == tile.id
    let combined = model.drag?.combineTileID == tile.id
    return VStack(spacing: 7) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.launchpadIcon, style: .continuous)
          .fill(.white.opacity(selected ? (contrast == .increased ? 0.22 : 0.16) : 0.001))
          .frame(width: iconSize * 1.22, height: iconSize * 1.22)
        icon(for: tile, size: iconSize, phase: Double(index % 7) / 7)
      }
      .overlay(alignment: .topLeading) {
        if model.jiggling, let app = tile.app.flatMap({ model.app($0) }),
          LaunchpadCatalog.canDelete(app)
        {
          deleteBadge(app, size: iconSize)
        }
      }
      Text(model.title(of: tile))
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.white.opacity(0.96))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: metrics.labelWidth)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
    .contentShape(Rectangle())
    .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    .opacity(isDragged ? 0.25 : (pressed ? 0.82 : 1))
    .scaleEffect(
      reduceMotion ? 1 : (pressed ? 0.94 : (combined ? 1.06 : 1))
    )
    .animation(Style.Motion.snap.animation(), value: pressed)
    .animation(Style.Motion.snap.animation(), value: combined)
    .help(model.title(of: tile))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.title(of: tile))
    .accessibilityHint(tile.folder == nil ? "打开" : "打开文件夹")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.open(tile) }
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
  private func icon(for tile: LaunchpadTile, size: CGFloat, phase: Double = 0) -> some View {
    switch tile {
    case .app(let ref):
      if let app = model.app(ref) {
        JigglingIcon(
          image: model.icons.icon(for: app, size: size), size: size,
          active: model.jiggling, phase: phase, reduceMotion: reduceMotion
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
      } else {
        placeholderIcon(size: size)
      }
    case .folder(let folder):
      // 文件夹方块比 App 图标小一圈：App 图标那张图自己带留白（F34）
      FolderGlyph(folder: folder, model: model, size: size * 0.8, phase: phase)
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

  @ViewBuilder
  private func dragGhost(metrics: LaunchpadMetrics) -> some View {
    if let drag = model.drag, drag.isDragging, let tile = ghostTile(drag) {
      let size = drag.sourceFolder == nil ? metrics.icon : metrics.icon * 0.8
      VStack(spacing: 6) {
        icon(for: tile, size: size)
        Text(model.title(of: tile))
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.96))
          .lineLimit(1)
      }
      .scaleEffect(reduceMotion ? 1 : 1.12)
      .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
      .position(
        x: drag.start.x + drag.translation.width,
        y: drag.start.y + drag.translation.height
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private func ghostTile(_ drag: LaunchpadDrag) -> LaunchpadTile? {
    if let tile = model.layout.tiles.first(where: { $0.id == drag.tileID }) { return tile }
    if let appID = drag.appID, let ref = model.layout.appRef(appID) { return .app(ref) }
    return nil
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

private struct JigglingIcon: NSViewRepresentable {
  let image: NSImage
  let size: CGFloat
  let active: Bool
  let phase: Double
  let reduceMotion: Bool

  func makeNSView(context: Context) -> NSImageView {
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    return view
  }

  func updateNSView(_ view: NSImageView, context: Context) {
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

/// 文件夹图标：一块半透明圆角底，里面按 3 × 3 画前 9 个 App 的小图标。文件夹里一个都没有时画系统的文件夹符号。
/// 抖动用 TimelineView（只有文件夹这一种视图，数量少；App 图标走图层）。
private struct FolderGlyph: View {
  let folder: LaunchpadFolder
  let model: LaunchpadModel
  let size: CGFloat
  let phase: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(model.jiggling && !reduceMotion)))
    {
      context in
      let angle =
        model.jiggling && !reduceMotion
        ? sin((context.date.timeIntervalSinceReferenceDate + phase) * 2 * .pi / 0.26) * 1.5 : 0
      glyph.rotationEffect(.degrees(angle))
    }
    .accessibilityHidden(true)
  }

  private var glyph: some View {
    let mini = size * 0.255
    let apps = folder.apps.prefix(9).compactMap { model.app($0) }
    return RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
      .fill(.white.opacity(0.14))
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

/// 打开的文件夹：背景再压暗，一块面板从文件夹那一格的位置展开，7 列、按内容行数定高；
/// 标题能改名（回车 / 失焦确认），里面能分页（两指滑 / 圆点），把图标拖出面板就回主网格（F34）。
private struct FolderOverlay: View {
  @Bindable var model: LaunchpadModel
  let metrics: LaunchpadMetrics
  let space: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @FocusState private var editingName: Bool

  var body: some View {
    // 格子宽高分开算（G4，口径在 LaunchpadMetrics.folder*）：宽放得下一行名字，高放得下图标 + 名字
    let columns = LaunchpadLayout.folderColumns
    let rows = model.folderRows
    let gridWidth = metrics.folderGridWidth
    let gridHeight = metrics.folderCellHeight * CGFloat(rows)
    let width = gridWidth + 52
    let height = gridHeight + 116
    ZStack {
      Color.black.opacity(0.34)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
          // 点空白：先提交改名（点别处 = 失焦提交，F34），再收起
          commitName()
          model.closeFolder()
        }
      VStack(spacing: 10) {
        TextField("文件夹名字", text: $model.folderNameDraft)
          .textFieldStyle(.plain)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white.opacity(0.96))
          .multilineTextAlignment(.center)
          .focused($editingName)
          .frame(width: gridWidth)
          .onSubmit { commitName() }
          .onChange(of: editingName) { _, focused in
            if !focused { commitName() }
          }
          .onExitCommand {
            commitName()
            model.closeFolder()
          }
        grid(columns: columns, rows: rows)
        folderDots
      }
      .padding(26)
      .frame(width: width, height: height)
      .background(
        RoundedRectangle(cornerRadius: Style.Radius.launchpadFolder, style: .continuous)
          .fill(.black.opacity(0.32))
      )
      .overlay {
        RoundedRectangle(cornerRadius: Style.Radius.launchpadFolder, style: .continuous)
          .stroke(.white.opacity(0.14), lineWidth: Style.hairlineWidth(contrast))
      }
      .position(clampedAnchor(width: width, height: height))
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .named(space))
      } action: { frame in
        model.folderPanelFrame = frame
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.openFolder?.name ?? "文件夹")
  }

  /// 面板从文件夹那一格长出来；靠边时把面板收进屏里（别有一半在屏幕外，F34）
  private func clampedAnchor(width: CGFloat, height: CGFloat) -> CGPoint {
    let raw =
      model.openFolderAnchor(metrics: metrics)
      ?? CGPoint(x: metrics.size.width / 2, y: metrics.size.height / 2)
    let inset: CGFloat = 12
    let x = min(max(raw.x, width / 2 + inset), metrics.size.width - width / 2 - inset)
    let y = min(max(raw.y, height / 2 + inset), metrics.size.height - height / 2 - inset)
    return CGPoint(x: x, y: y)
  }

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

  private func folderPage(_ page: Int, columns: Int, rows: Int) -> some View {
    let apps = model.openFolder?.pages[safe: page] ?? []
    let cellWidth = metrics.folderCellWidth
    let cellHeight = metrics.folderCellHeight
    return VStack(spacing: 0) {
      ForEach(0..<rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<columns, id: \.self) { column in
            let index = row * columns + column
            if let ref = apps[safe: index], let app = model.app(ref) {
              folderCell(app, ref: ref, index: index, iconSize: metrics.folderIcon)
                .frame(width: cellWidth, height: cellHeight)
            } else {
              Color.clear.frame(width: cellWidth, height: cellHeight)
            }
          }
        }
      }
    }
    .frame(width: cellWidth * CGFloat(columns), height: cellHeight * CGFloat(rows))
  }

  private func folderCell(
    _ app: LaunchpadProjectApp, ref: LaunchpadAppRef, index: Int, iconSize: CGFloat
  ) -> some View {
    let selected = model.selected == index
    let pressed =
      model.pressedTileID == LaunchpadTile.app(ref).id
    return VStack(spacing: LaunchpadMetrics.folderLabelSpacing) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.launchpadFolderIcon, style: .continuous)
          .fill(.white.opacity(selected ? (contrast == .increased ? 0.22 : 0.16) : 0.001))
          .frame(width: iconSize * 1.2, height: iconSize * 1.2)
        JigglingIcon(
          image: model.icons.icon(for: app, size: iconSize), size: iconSize,
          active: model.jiggling, phase: Double(index % 7) / 7, reduceMotion: reduceMotion
        )
        .frame(width: iconSize, height: iconSize)
      }
      .overlay(alignment: .topLeading) {
        if model.jiggling, LaunchpadCatalog.canDelete(app) {
          deleteBadge(app, size: iconSize)
        }
      }
      Text(app.name)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.96))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: metrics.folderLabelWidth, height: LaunchpadMetrics.folderLabelHeight)
    }
    .contentShape(Rectangle())
    .opacity(pressed ? 0.82 : 1)
    .scaleEffect(reduceMotion ? 1 : (pressed ? 0.94 : 1))
    .animation(Style.Motion.snap.animation(), value: pressed)
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
        .onChanged { value in
          if model.drag == nil {
            model.beginDrag(
              tile: .app(ref), appID: ref.id, folder: model.openFolderID, at: value.startLocation)
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
