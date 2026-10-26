// 晾衣绳面板的内容（第十族，2026-10-26 拍板 C3 D1 + 同日手测反馈重做了线 / 夹子 / 动画；
// 长相见 mac-whisker-capture.mdc「晾衣绳」）：一根绳子横在屏幕顶上、中间断开给刘海岛让位，
// 挂着的截图一张张从两边往中间挂，每张上面一枚品牌粉的木夹子。
// **位置和角度每帧由绳子的物理给**（ClotheslineRope，verlet；模型里的 hangs / ropes），这里只管画——
// 摇摆是绳子带的，卡片自己没有动画。
// 卡片就是常驻缩略图那一张（圆角 10、white 0.25 发丝线描边 + black 0.28 / r16 / y6 阴影，Style.shotCard），
// 图是截图历史里那条的缩略图（ShotThumbnails，和历史窗口共用一份缓存）。
// 悬停压一层蒙层、右上角出 ✕（点它取下，拍板 D2）；单击拷贝、双击进标注窗口、拖出去是一个文件、
// 拖到废纸篓取下、右键是一整套菜单——鼠标全在 CardMouse 那块 AppKit 视图里收（本 App 不激活、面板永不当 key，
// SwiftUI 的 onHover 和手势在这种窗口里都不稳，同常驻缩略图的做法）。
// 排法、静止时的样子由 ClotheslineLayout 算（面板内坐标，原点左上）。
// 面板是整块透明的（没有毛玻璃底）：透明的地方系统自己点穿，只有卡片接鼠标（Clothesline.makePanel）。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClotheslineView: View {
  let model: ClotheslineModel

  var body: some View {
    // 读一下：改完标注、缩略图重做好之后要重画（ShotThumbnails 不是 @Observable）
    let _ = model.redraws
    ZStack(alignment: .topLeading) {
      rope
      ForEach(model.hangs) { hang in
        if let item = model.item(hang.id) {
          ClotheslineCard(model: model, item: item)
            .frame(width: hang.rect.width, height: hang.rect.height)
            // 绕挂点转（挂点在卡片顶边上面 hangDrop 点，夹子就在那儿）
            .rotationEffect(
              .radians(hang.angle),
              anchor: UnitPoint(x: 0.5, y: -ClotheslineLayout.hangDrop / hang.rect.height)
            )
            .position(x: hang.rect.midX, y: hang.rect.midY)
            // 取下：往下坠一截、淡出（不进物理，绳子那边是一个向上的释放脉冲）
            .transition(
              .asymmetric(
                insertion: .identity,
                removal: .offset(y: ClotheslineLayout.leaveDrop).combined(with: .opacity)))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// 细线 + 投影：1.5 pt 的墨色实线（圆头）、底下垫一道同形状、线宽 +1、往下偏 2.5 的黑影（看得出悬空）。
  /// 两端不画挂点：四个端点钉在面板上沿以上，藏在菜单栏后面（2026-10-26 用户要求）
  private var rope: some View {
    let shape = RopeShape(ropes: model.ropes)
    return ZStack {
      shape
        .stroke(
          .black.opacity(ClotheslineLayout.ropeShadowInk),
          style: StrokeStyle(lineWidth: ClotheslineLayout.ropeWidth + 1, lineCap: .round)
        )
        .offset(y: ClotheslineLayout.ropeShadowOffset)
      shape
        .stroke(
          .primary.opacity(ClotheslineLayout.ropeInk),
          style: StrokeStyle(lineWidth: ClotheslineLayout.ropeWidth, lineCap: .round))
    }
    .allowsHitTesting(false)
  }
}

/// 绳子：质点连成的线（相邻质点的中点当锚、质点当控制点，同样机的 ropePath，拐角才圆滑）。
/// nonisolated：path(in:) 可能在 SwiftUI 的渲染线程上调（mac-native §3），只读传进来的几何
nonisolated private struct RopeShape: Shape {
  let ropes: [[CGPoint]]

  func path(in rect: CGRect) -> Path {
    var path = Path()
    for points in ropes where points.count > 1 {
      path.move(to: points[0])
      for index in 1..<(points.count - 1) {
        let point = points[index]
        let next = points[index + 1]
        path.addQuadCurve(
          to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
      }
      path.addLine(to: points[points.count - 1])
    }
    return path
  }
}

/// 挂在绳子上的一张：缩略图 + 顶上那枚夹子 + 悬停时的蒙层和 ✕
private struct ClotheslineCard: View {
  let model: ClotheslineModel
  let item: ShotHistory.Item
  private var isHovered: Bool { model.hovered == item.id }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    // 图放在 overlay 里铺满：比例和卡片不一样时也不会把卡片撑大（同常驻缩略图）
    Color.clear
      .overlay {
        if let image = model.thumbnail(for: item) {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
          Color(nsColor: Style.HUD.solidFill)
        }
      }
      // 不是截图的（长截图、录屏、录音、GIF）左下角一枚小角标，同历史窗口的网格
      .overlay(alignment: .bottomLeading) {
        if item.kind != .shot, !isHovered { kindBadge }
      }
      .overlay {
        if isHovered {
          ZStack {
            Style.Shot.cardScrim
            closeButton.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          }
          .transition(.opacity)
        }
      }
      .shotCard(shape)
      // 夹子夹在卡片顶边上：中心在顶边上方 clipCenterAboveCard，绳子正好从两片之间穿过去
      .overlay(alignment: .top) {
        Clip()
          .offset(y: -ClotheslineLayout.clipBar.height / 2 - ClotheslineLayout.clipCenterAboveCard)
      }
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .overlay { mouse }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(item.kind.title)，\(ShotHistoryModel.caption(item))")
      .accessibilityActions {
        ForEach(ClotheslineModel.menu(for: item).flatMap { $0 }, id: \.self) { command in
          Button(command.title) { model.onCommand(command, item) }
        }
      }
  }

  /// 鼠标：悬停、单击 / 双击、点 ✕、拖出去（见 CardMouse）
  private var mouse: some View {
    CardMouse(
      image: model.thumbnail(for: item), file: model.dragFiles[item.id],
      onHover: { inside in model.hovered = inside ? item.id : nil },
      onClick: { model.onCommand(.copy, item) },
      onDoubleClick: { model.onCommand(.edit, item) },
      onClose: { model.onCommand(.unpeg, item) },
      onTrash: { model.onCommand(.unpeg, item) }
    )
    // 右键不归它：落到宿主上弹这个菜单（危险项交给系统画，mac-whisker §3「危险色」）
    .contextMenu {
      ForEach(Array(ClotheslineModel.menu(for: item).enumerated()), id: \.offset) { index, group in
        if index > 0 { Divider() }
        ForEach(group, id: \.self) { command in
          Button(command.title, role: command == .forget ? .destructive : nil) {
            model.onCommand(command, item)
          }
        }
      }
    }
  }

  private var closeButton: some View {
    Image(systemName: "xmark")
      .font(.system(size: 10, weight: .bold))
      .frame(width: ClotheslineLayout.closeSide, height: ClotheslineLayout.closeSide)
      // 小圆钮不换玻璃：26 起玻璃在这么小的圆上画出来是一块带圆角的方块（Style.hudSkin 那条注释）
      .hudSkin(Circle(), glass: false)
      .padding(ClotheslineLayout.closeInset)
      .accessibilityHidden(true)
  }

  private var kindBadge: some View {
    Text(item.kind.title)
      .font(.system(size: 10, weight: .semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color(nsColor: Style.HUD.fill), in: Capsule())
      .foregroundStyle(.white)
      .padding(6)
      .accessibilityHidden(true)
  }

}

/// 木夹子（2026-10-26 手测反馈「要真的像夹子」，样机里挑的那个）：品牌粉的两片圆角竖条
/// （各 4.5 × 20、圆角 2、0.9 透明度，中间留 1.5 的缝）+ 中间一道 0.65 透明度的弧当弹簧
private struct Clip: View {
  var body: some View {
    let bar = ClotheslineLayout.clipBar
    let pink = Color(nsColor: Style.Shot.accent)
    ZStack {
      HStack(spacing: ClotheslineLayout.clipGap) {
        ForEach(0..<2, id: \.self) { _ in
          RoundedRectangle(cornerRadius: ClotheslineLayout.clipRadius, style: .continuous)
            .fill(pink.opacity(0.9))
            .frame(width: bar.width, height: bar.height)
        }
      }
      Spring()
        .stroke(
          pink.opacity(0.65),
          style: StrokeStyle(lineWidth: ClotheslineLayout.clipSpringWidth, lineCap: .round))
    }
    .frame(width: bar.width * 2 + ClotheslineLayout.clipGap, height: bar.height)
    .shadow(color: Style.Shot.cardShadow, radius: 3, y: 1)
    .accessibilityHidden(true)
  }
}

/// 夹子中间那道弹簧：半径 4.6 的弧，从 0.15π 到 0.85π（下半圈），圆心在中心往上 1 点。
/// nonisolated：同 RopeShape
nonisolated private struct Spring: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.addArc(
      center: CGPoint(x: rect.midX, y: rect.midY - 1),
      radius: ClotheslineLayout.clipSpringRadius, startAngle: .radians(.pi * 0.15),
      endAngle: .radians(.pi * 0.85), clockwise: false)
    return path
  }
}

/// 一张卡片上的鼠标（第 2 批，拍板 C3）：本 App 从不激活、面板永不当 key，SwiftUI 的 onHover 和点击手势在这种窗口里
/// 都不稳（常驻缩略图同样自建追踪区，mac-overlay-panel §8），所以悬停、单击 / 双击、点 ✕、拖出去都在这里收。
/// 单击和双击分得开：单击先排在双击间隔之后，期间来了第二下就作废（SwiftUI 两个 tap 手势叠着时单击会先响一次）。
/// 拖出去用 AppKit 的拖拽会话，**拖到废纸篓（operation 是 .delete）就取下**——SwiftUI 的 onDrag 没有结束回调，
/// 收不到这件事；ponytail: 拖进文件夹和拖进别的 App 系统给的都是 .copy，分不出来，所以这两样都只发一份、卡片留着
/// （拍板 C3 的「拖进文件夹存下并取下」做不到，要分得出来得自己接管落点）。
/// 右键不接：落到宿主上弹 SwiftUI 的 contextMenu（危险项的红字交给系统画）
private struct CardMouse: NSViewRepresentable {
  let image: NSImage?
  let file: URL?
  let onHover: (Bool) -> Void
  let onClick: () -> Void
  let onDoubleClick: () -> Void
  let onClose: () -> Void
  let onTrash: () -> Void

  func makeNSView(context: Context) -> MouseView { MouseView() }

  func updateNSView(_ view: MouseView, context: Context) {
    view.image = image
    view.file = file
    view.onHover = onHover
    view.onClick = onClick
    view.onDoubleClick = onDoubleClick
    view.onClose = onClose
    view.onTrash = onTrash
  }

  final class MouseView: NSView, NSDraggingSource {
    var image: NSImage?
    var file: URL?
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onClose: () -> Void = {}
    var onTrash: () -> Void = {}
    /// 按下的位置（拖过 4 点才开始拖）
    private var pressedAt: NSPoint?
    private var isInside = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 整张卡片都接鼠标；✕ 那一小块也归它（SwiftUI 画的按钮在这块真视图下面，点不到）
    private var closeRect: CGRect {
      let side = ClotheslineLayout.closeSide
      let inset = ClotheslineLayout.closeInset
      return CGRect(
        x: bounds.maxX - inset - side, y: bounds.maxY - inset - side, width: side, height: side)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
      addTrackingArea(
        NSTrackingArea(
          rect: .zero,
          options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
          owner: self))
    }

    /// 卡片出现在静止的光标下时没有 mouseEntered：动一下鼠标也算进来（同常驻缩略图）
    override func mouseEntered(with event: NSEvent) { setInside(true) }
    override func mouseExited(with event: NSEvent) { setInside(false) }
    override func mouseMoved(with event: NSEvent) { if !isInside { setInside(true) } }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window == nil else { return }
      // 卡片被取下 / 面板收起：等着的那一下单击作废（不然动作落在已经不在绳子上的那条上）
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(fireClick), object: nil)
      setInside(false)
    }

    private func setInside(_ inside: Bool) {
      guard inside != isInside else { return }
      isInside = inside
      onHover(inside)
    }

    override func mouseDown(with event: NSEvent) {
      pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
      guard let pressedAt, let file else { return }
      let point = convert(event.locationInWindow, from: nil)
      guard abs(point.x - pressedAt.x) > 4 || abs(point.y - pressedAt.y) > 4 else { return }
      self.pressedAt = nil
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(fireClick), object: nil)
      let item = NSDraggingItem(pasteboardWriter: file as NSURL)
      item.setDraggingFrame(bounds, contents: image)
      beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
      guard let pressedAt, bounds.contains(pressedAt) else { return }
      self.pressedAt = nil
      if closeRect.contains(pressedAt) { return onClose() }
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(fireClick), object: nil)
      guard event.clickCount < 2 else { return onDoubleClick() }
      // 单击先等一个双击间隔：第二下来了就作废
      perform(#selector(fireClick), with: nil, afterDelay: NSEvent.doubleClickInterval)
    }

    @objc private func fireClick() { onClick() }

    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      context == .withinApplication ? [] : [.copy, .delete]
    }

    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
      // 拖到废纸篓：取下（东西还在历史里，拍板 D2 不问）
      if operation == .delete { onTrash() }
    }
  }
}
