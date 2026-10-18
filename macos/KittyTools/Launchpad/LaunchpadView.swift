// 启动台的界面（SPEC R1–R6）：压暗的桌面上一页图标，顶上搜索框，底下页点。图标按屏幕大小排成列 × 行；
// 两指滑 / 滚轮翻页（跟手偏移由面板喂给 model）；方向键在格子间挪、到页边翻页；点图标打开 App；
// 按住稍拖就拿起（跟手、别的图标让位、拖到边上翻页、拖到另一个图标上建文件夹），按住 1 秒或按着 ⌥ 进抖动模式
// （App Store 装的出 ✕，确认后移到废纸篓）；文件夹在原地展开成一块面板（改名、内部分页、拖出 / 拖进）。
// 一点空白处收起；Esc 逐层退（拖动 → 抖动 → 文件夹 → 搜索 → 收起）。减弱动态效果：不缩放、不跟手、不抖，翻页直接换。

import AppKit
import SwiftUI

struct LaunchpadView: View {
  @Bindable var model: LaunchpadModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
      .opacity(appeared ? 1 : 0)
      .scaleEffect(appeared ? 1 : 1.06)
      .onAppear {
        withAnimation(
          reduceMotion ? .easeOut(duration: Style.fadeIn) : Style.Motion.pop.animation()
        ) {
          appeared = true
        }
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
      Button("移到废纸篓", role: .destructive) { model.confirmDelete() }
      Button("取消", role: .cancel) { model.deleteCandidate = nil }
    } message: {
      Text("这个 App 会被移到废纸篓，以后要再装得去 App Store 里找。")
    }
  }

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
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(.black.opacity(0.28))
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(.white.opacity(0.16), lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
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
    .animation(reduceMotion ? nil : Style.Motion.instant.animation(), value: model.pageOffset)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.isSearching ? "搜索结果" : "第 \(model.page + 1) 页")
  }

  private func pageGrid(_ pageIndex: Int, metrics: LaunchpadMetrics) -> some View {
    let slots = model.previewTiles(page: pageIndex)
    return VStack(spacing: 0) {
      ForEach(0..<model.rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<model.columns, id: \.self) { column in
            let index = row * model.columns + column
            ZStack {
              if let tile = slots[safe: index] ?? nil {
                tileCell(tile, index: index, metrics: metrics, iconSize: metrics.icon)
              } else if model.drag?.targetIndex == index, model.page == pageIndex {
                placeholder(metrics: metrics)
              } else {
                Color.clear
              }
            }
            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
          }
        }
      }
    }
    .frame(width: metrics.gridWidth, height: metrics.gridHeight)
    .animation(reduceMotion ? nil : Style.Motion.settle.animation(), value: model.drag?.targetIndex)
  }

  private func placeholder(metrics: LaunchpadMetrics) -> some View {
    RoundedRectangle(cornerRadius: 22, style: .continuous)
      .fill(.white.opacity(0.10))
      .frame(width: metrics.icon * 1.22, height: metrics.icon * 1.22)
      .accessibilityHidden(true)
  }

  private func tileCell(
    _ tile: LaunchpadTile, index: Int, metrics: LaunchpadMetrics, iconSize: CGFloat
  ) -> some View {
    let selected = model.selected == index
    let isDragged = model.drag?.tileID == tile.id && model.drag?.isDragging == true
    return VStack(spacing: 7) {
      ZStack {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(.white.opacity(selected ? 0.16 : 0.001))
          .frame(width: iconSize * 1.22, height: iconSize * 1.22)
        icon(for: tile, size: iconSize)
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
    .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    .contentShape(Rectangle())
    .opacity(isDragged ? 0.25 : 1)
    .rotationEffect(.degrees(wobble(index: index)))
    .animation(
      model.jiggling && !reduceMotion
        ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true) : nil,
      value: model.jiggling
    )
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
        .onChanged { value in
          guard !model.isSearching else { return }
          if model.drag == nil {
            model.beginDrag(
              tile: tile, appID: tile.app?.id, folder: nil, at: value.startLocation)
          }
          model.updateDrag(location: value.location, pageWidth: metrics.size.width)
        }
        .onEnded { _ in model.endDrag() }
    )
    .help(model.title(of: tile))
    .accessibilityLabel(model.title(of: tile))
    .accessibilityHint(tile.folder == nil ? "打开" : "打开文件夹")
  }

  /// 抖动的相位：相邻的图标反着晃
  private func wobble(index: Int) -> Double {
    guard model.jiggling, !reduceMotion else { return 0 }
    return index.isMultiple(of: 2) ? 1.5 : -1.5
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
  private func icon(for tile: LaunchpadTile, size: CGFloat) -> some View {
    switch tile {
    case .app(let ref):
      if let app = model.app(ref) {
        Image(nsImage: model.icons.icon(for: app, size: size))
          .resizable()
          .interpolation(.high)
          .frame(width: size, height: size)
          .accessibilityHidden(true)
      } else {
        placeholderIcon(size: size)
      }
    case .folder(let folder):
      FolderGlyph(folder: folder, model: model, size: size)
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
    HStack(spacing: 9) {
      ForEach(0..<model.pageCount, id: \.self) { index in
        dot(active: index == model.page) { model.go(to: index) }
          .accessibilityLabel("第 \(index + 1) 页")
          .accessibilityAddTraits(index == model.page ? [.isSelected, .isButton] : .isButton)
          .accessibilityAction { model.go(to: index) }
      }
    }
    .opacity(model.pageCount > 1 ? 1 : 0)
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

  // MARK: 文件夹（R4）

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

/// 文件夹图标（batch 2 打开文件夹、batch 3 导入都会用到）：一块半透明圆角底，里面按 3 × 3 画前 9 个 App 的小图标。
/// 文件夹里一个都没有时画一个系统的文件夹符号（导入的脏数据兜底）。
private struct FolderGlyph: View {
  let folder: LaunchpadFolder
  let model: LaunchpadModel
  let size: CGFloat

  var body: some View {
    let mini = size * 0.255
    let apps = folder.apps.prefix(9).compactMap { model.app($0) }
    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
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
      .accessibilityHidden(true)
  }
}

/// 打开的文件夹：背景再压暗，中间一块面板，标题能改名（回车确认），里面 3 × 3 一页、能分页，
/// 把图标拖出面板就回主网格。
private struct FolderOverlay: View {
  @Bindable var model: LaunchpadModel
  let metrics: LaunchpadMetrics
  let space: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let iconSize = min(metrics.icon * 0.8, 84)
    let cell = iconSize * 1.55
    let width = cell * 3 + 52
    let height = cell * 3 + 108
    ZStack {
      Color.black.opacity(0.34)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { model.closeFolder() }
      VStack(spacing: 12) {
        TextField("文件夹名字", text: $model.folderNameDraft)
          .textFieldStyle(.plain)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white.opacity(0.96))
          .multilineTextAlignment(.center)
          .frame(width: cell * 3)
          .onSubmit {
            if let id = model.openFolderID { model.renameFolder(id, to: model.folderNameDraft) }
          }
        grid(iconSize: iconSize, cell: cell)
        folderDots
      }
      .padding(26)
      .frame(width: width, height: height)
      .background(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .fill(.black.opacity(0.32))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .stroke(.white.opacity(0.14), lineWidth: 0.5)
      }
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .named(space))
      } action: { frame in
        model.folderPanelFrame = frame
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.openFolder?.name ?? "文件夹")
  }

  private func grid(iconSize: CGFloat, cell: CGFloat) -> some View {
    let apps = model.folderApps
    return VStack(spacing: 0) {
      ForEach(0..<3, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<3, id: \.self) { column in
            let index = row * 3 + column
            if let ref = apps[safe: index], let app = model.app(ref) {
              folderCell(app, ref: ref, index: index, iconSize: iconSize)
                .frame(width: cell, height: cell)
            } else {
              Color.clear.frame(width: cell, height: cell)
            }
          }
        }
      }
    }
    .frame(width: cell * 3, height: cell * 3)
  }

  private func folderCell(
    _ app: LaunchpadProjectApp, ref: LaunchpadAppRef, index: Int, iconSize: CGFloat
  ) -> some View {
    let selected = model.selected == index
    return VStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(.white.opacity(selected ? 0.16 : 0.001))
          .frame(width: iconSize * 1.2, height: iconSize * 1.2)
        Image(nsImage: model.icons.icon(for: app, size: iconSize))
          .resizable()
          .interpolation(.high)
          .frame(width: iconSize, height: iconSize)
      }
      Text(app.name)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.96))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: iconSize + 28)
    }
    .contentShape(Rectangle())
    .rotationEffect(
      .degrees(model.jiggling && !reduceMotion ? (index.isMultiple(of: 2) ? 1.5 : -1.5) : 0)
    )
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
    .accessibilityLabel(app.name)
    .accessibilityHint("打开")
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
