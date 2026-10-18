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
        if model.openFolderID != nil {
          FolderBackdrop(model: model)
            .transition(.opacity)
          // 照 macOS 15 从文件夹图标那儿长到屏幕中间、关的时候缩回去（减弱动态效果时只淡入淡出）
          FolderOverlay(model: model, metrics: metrics, space: Self.space)
            .transition(folderTransition(metrics))
        }
        dragGhost(metrics: metrics)
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

  private func folderTransition(_ metrics: LaunchpadMetrics) -> AnyTransition {
    guard !reduceMotion, let from = model.folderAnchor else { return .opacity }
    let panel = model.folderPanelRect
    let center = CGPoint(x: metrics.size.width / 2, y: metrics.size.height / 2)
    let start = min(1, metrics.icon * 0.8 / max(panel.width, 1))
    return .modifier(
      active: FolderZoom(progress: 0, from: from, center: center, start: start),
      identity: FolderZoom(progress: 1, from: from, center: center, start: start))
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

  private func pageGrid(_ pageIndex: Int, metrics: LaunchpadMetrics) -> some View {
    let slots = model.previewTiles(page: pageIndex)
    let gap = model.gapIndex(page: pageIndex)
    return VStack(spacing: 0) {
      ForEach(0..<model.rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<model.columns, id: \.self) { column in
            let index = row * model.columns + column
            // 空位就是空着（照 macOS 15，不画灰方块）
            ZStack {
              if let tile = slots[safe: index] ?? nil {
                tileCell(tile, index: index, metrics: metrics, iconSize: metrics.icon)
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
    .animation(reduceMotion ? nil : Self.reflow, value: gap)
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
          model.beginDrag(
            tile: tile, appID: tile.app?.id, folder: nil, at: value.startLocation,
            origin: model.cellCenter(page: pageIndex, index: index))
        }
        model.updateDrag(location: value.location, pageWidth: metrics.size.width)
      }
      .onEnded { _ in model.endDrag() }
  }

  private func tileCell(
    _ tile: LaunchpadTile, index: Int, metrics: LaunchpadMetrics, iconSize: CGFloat
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
        icon(for: tile, size: iconSize, phase: Double(index % 7) / 7)
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

/// 打开文件夹的那一下：从文件夹图标那儿（`from`，缩成文件夹方块那么大）长到屏幕中间。
/// 作为 transition 用（progress 0 → 1），关的时候反过来缩回去；只动变换，不改布局
private struct FolderZoom: ViewModifier, Animatable {
  var progress: CGFloat
  let from: CGPoint
  let center: CGPoint
  let start: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    content
      .scaleEffect(start + (1 - start) * progress)
      .offset(x: (from.x - center.x) * (1 - progress), y: (from.y - center.y) * (1 - progress))
      .opacity(min(1, 0.2 + progress * 1.6))
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

/// 文件夹图标：一块浅色半透明圆角底（照 macOS 15），里面按 3 × 3 画前 9 个 App 的小图标。文件夹里一个都没有时画系统的文件夹符号。
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
  @State private var titleShown = false

  var body: some View {
    // 格子宽高分开算（G4，口径在 LaunchpadMetrics.folder*）：宽和主网格一样，高放得下图标 + 名字
    let columns = LaunchpadLayout.folderColumns
    let rows = model.folderRows
    let panel = RoundedRectangle(cornerRadius: Style.Radius.launchpadFolder, style: .continuous)
    VStack(spacing: LaunchpadMetrics.folderTitleSpacing) {
      title
        .opacity(titleShown ? 1 : 0)
      VStack(spacing: 10) {
        grid(columns: columns, rows: rows)
        folderDots
      }
      .padding(LaunchpadMetrics.folderPadding)
      // 面板是一层浅白：底下已经是糊掉的壁纸，透出来就是一块浅色毛玻璃（不再叠一层材质，省一次全面板模糊）
      .background(panel.fill(.white.opacity(contrast == .increased ? 0.22 : 0.14)))
      .overlay { panel.stroke(.white.opacity(0.2), lineWidth: Style.hairlineWidth(contrast)) }
    }
    .position(x: metrics.size.width / 2, y: metrics.size.height / 2)
    .onAppear {
      // 名字在面板长到七成时才淡进来
      withAnimation(.easeOut(duration: Style.fadeIn).delay(reduceMotion ? 0 : 0.17)) {
        titleShown = true
      }
    }
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
    return TextField("文件夹名字", text: $model.folderNameDraft)
      .textFieldStyle(.plain)
      .font(Font(Self.titleFont))
      .foregroundStyle(.white.opacity(0.96))
      .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
      .multilineTextAlignment(.center)
      .focused($editingName)
      .frame(width: width, height: LaunchpadMetrics.folderTitleHeight)
      .background(shape.fill(.white.opacity(editingName ? 0.14 : 0)))
      .animation(.easeOut(duration: Style.fadeIn), value: editingName)
      .onSubmit { commitName() }
      .onChange(of: editingName) { _, focused in
        if !focused { commitName() }
      }
      .onExitCommand {
        commitName()
        model.closeFolder()
      }
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
  private func folderPage(_ page: Int, columns: Int, rows: Int) -> some View {
    let apps = model.folderPreview(page: page)
    let cellWidth = metrics.folderCellWidth
    let cellHeight = metrics.folderCellHeight
    return VStack(spacing: 0) {
      ForEach(0..<rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<columns, id: \.self) { column in
            let index = row * columns + column
            if let ref = apps[safe: index] ?? nil, let app = model.app(ref) {
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
    .animation(reduceMotion ? nil : LaunchpadView.reflow, value: model.drag?.folderTarget)
  }

  private func folderCell(
    _ app: LaunchpadProjectApp, ref: LaunchpadAppRef, index: Int, iconSize: CGFloat
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
        JigglingIcon(
          image: model.icons.icon(for: app, size: iconSize), size: iconSize,
          active: model.jiggling, phase: Double(index % 7) / 7, reduceMotion: reduceMotion
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
