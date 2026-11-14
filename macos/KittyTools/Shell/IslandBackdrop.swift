// 展开的岛四周的渐进模糊（2026-11-14，照 Alcove 的实录：卡片背后的东西越靠近卡片越糊；用户同意用非公开接口）。
// 岛的窗口里、SwiftUI 宿主下面垫一块系统毛玻璃（NSVisualEffectView，behindWindow），把它里面那层 CABackdropLayer 的滤镜
// 换成 **私有的 CAFilter「variableBlur」**：一张蒙版图说哪里糊多少——形体那一块全糊，往外 spread（56 pt）之内渐渐不糊（三次曲线：只有贴着形体的那一小段才重，外面一大圈只是让字变软）。
// 毛玻璃自带的底色、高光那几层藏掉（只要模糊，不要底色）。只在岛展开成「大面」（卡片、那一张）时出，收起就藏
// （藏着时窗口服务器不算它）；它只盖形体外面那一圈，不盖整扇窗口。
// 私有的东西都按名字取、取不到就什么都不做（岛照旧只有阴影）：CAFilter 这个类和 filterWithType:、CABackdropLayer 这个
// 类名和它的 scale（取背景的分辨率）、variableBlur 这种滤镜和它的 inputMaskImage / inputRadius / inputNormalizeEdges 三个键。2026-11-14 在 macOS 27.0.1
// 上屏验证过（探针 macos/build/research/island-polish-2026-11-13/blur/，不进仓库）：换一次滤镜约 15 ms，系统不会自己换回去。
// 每个 macOS 大版本先跑一遍那个探针。系统设置里开着「降低透明度」时不出。
// ponytail: 蒙版按形体的**目标**大小画一次，不跟着弹簧逐帧重画（重画一次要建一张位图）：形体长到位（0.18 秒）之后
// （形体长到差不多到位，0.18 秒之后）半径才从 0 长出来，形体一开始收就先把它收掉。要跟手就得每帧换蒙版，先量窗口服务器的开销。

import AppKit
import QuartzCore

final class IslandBackdrop: NSView {
  /// 模糊半径、往形体外面晕开多远
  static let radius: CGFloat = 7
  static let spread: CGFloat = 56
  /// 形体的目标变了之后等多久才出：蒙版是照目标大小画的，形体还在往那儿长（约 0.25 秒到顶、这时已经差不多到位），
  /// 先出就是一块悬空的模糊
  static let settle = Duration.milliseconds(180)

  private let effect = NSVisualEffectView()
  /// 现在要照着出的那个形体（没有是 nil）；applied：蒙版已经换上了
  private var wanted: Shape?
  private var applied = false
  /// 排着出的（等形体长到位）、收尾的（半径缩完把毛玻璃藏起来）：两件事各一个任务——合用一个的话，连着两次 hide
  /// （收起时一次、30 毫秒后形体变小又一次）第二次会把收尾的那个取消掉，毛玻璃就一直没藏、一直占着窗口服务器（评审 A）
  private var appearing: Task<Void, Never>?
  private var hiding: Task<Void, Never>?

  struct Shape: Equatable {
    /// 形体在这块视图里的位置（左下角原点）
    var frame: CGRect
    var corner: CGFloat
    /// 顶边贴着屏幕顶（刘海屏）：顶上两个角是方的
    var flatTop: Bool
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.material = .hudWindow
    effect.isHidden = true
    addSubview(effect)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  /// 点不到（它只是垫在后面的一层）
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// 这一版系统上用不用得了：CAFilter、CABackdropLayer 两个类都在，系统的滤镜种类里有 variableBlur
  /// （filterWithType: 给它不认识的名字也返回一个空滤镜，光看它建不建得出来不够）
  static var isAvailable: Bool {
    guard makeFilter() != nil, NSClassFromString("CABackdropLayer") != nil,
      let type = NSClassFromString("CAFilter") as? NSObject.Type
    else { return false }
    let list = NSSelectorFromString("filterTypes")
    guard type.responds(to: list),
      let kinds = type.perform(list)?.takeUnretainedValue() as? [String]
    else { return false }
    return kinds.contains("variableBlur")
  }

  /// 照这个形体出模糊圈（已经照它出着 / 排着就不动）。形体换了：先收掉，等形体长到位（settle）再从 0 长出来。
  /// animated false（减弱动态效果）：当场换上
  func show(around shape: Shape, animated: Bool) {
    guard shape != wanted else { return }
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
      return hide(animated: false)
    }
    hide(animated: animated)
    wanted = shape
    guard animated else { return apply(shape, grows: false) }
    appearing = Task { [weak self] in
      try? await Task.sleep(for: Self.settle)
      guard !Task.isCancelled, let self, self.wanted == shape else { return }
      self.apply(shape, grows: true)
    }
  }

  private func apply(_ shape: Shape, grows: Bool) {
    let area = shape.frame.insetBy(dx: -Self.spread, dy: -Self.spread).intersection(bounds)
    // 没有刘海的屏上形体离窗口上沿只有 2 pt：那一圈在顶上被窗口切掉，切口是一道平的硬边——顶上那一段往上渐隐
    let cut = !shape.flatTop && shape.frame.maxY + Self.spread > bounds.maxY
    // 蒙版按 1x 画（低频的渐变用不着 2x；2x 要 6–10 ms，1x 是 2–3 ms）
    guard !area.isEmpty, let filter = Self.makeFilter(),
      let mask = Self.mask(
        size: area.size, shape: shape.frame.offsetBy(dx: -area.minX, dy: -area.minY),
        corner: shape.corner, flatTop: shape.flatTop, scale: 1, fadeTop: cut ? 16 : 0)
    else { return }
    hiding?.cancel()
    effect.frame = area
    effect.isHidden = false
    effect.layoutSubtreeIfNeeded()
    guard let backdrop = effect.layer.flatMap(Self.backdropLayer) else {
      effect.isHidden = true
      return
    }
    filter.setValue(mask, forKey: "inputMaskImage")
    filter.setValue(Self.radius, forKey: "inputRadius")
    filter.setValue(true, forKey: "inputNormalizeEdges")
    filter.setValue("variableBlur", forKey: "name")
    backdrop.removeAnimation(forKey: "radius")
    // 毛玻璃自己的背景层只按 1/8 的分辨率取背景（反正整块都糊）：不调回 1 的话，蒙版说「不糊」的地方也是糊的，
    // 模糊圈的外沿就是一道硬边（2026-11-14 屏上探针：scale = 0.125）
    if backdrop.responds(to: NSSelectorFromString("setScale:")) {
      backdrop.setValue(1.0, forKey: "scale")
    }
    backdrop.filters = [filter]
    // 底色、高光那几层不要
    for sibling in backdrop.superlayer?.sublayers ?? [] where sibling !== backdrop {
      sibling.isHidden = true
    }
    applied = true
    guard grows else { return }
    let grow = CABasicAnimation(keyPath: "filters.variableBlur.inputRadius")
    grow.fromValue = 0
    grow.toValue = Self.radius
    grow.duration = 0.3
    grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
    backdrop.add(grow, forKey: "radius")
  }

  /// 收掉：半径很快缩到 0 再藏（藏着时窗口服务器不算它）。形体这时已经在往回缩，慢了就是一块悬空的模糊
  func hide(animated: Bool) {
    appearing?.cancel()
    appearing = nil
    wanted = nil
    // 没出着：不动收尾的那个任务（它正等着把毛玻璃藏起来）
    guard applied else { return }
    applied = false
    hiding?.cancel()
    guard animated, let backdrop = effect.layer.flatMap(Self.backdropLayer) else {
      effect.isHidden = true
      return
    }
    let shrink = CABasicAnimation(keyPath: "filters.variableBlur.inputRadius")
    shrink.toValue = 0
    shrink.duration = 0.08
    shrink.fillMode = .forwards
    shrink.isRemovedOnCompletion = false
    backdrop.add(shrink, forKey: "radius")
    hiding = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(90))
      guard !Task.isCancelled, let self, !self.applied else { return }
      self.effect.isHidden = true
    }
  }

  // MARK: 私有接口（都按名字取，取不到是 nil）

  private static func makeFilter() -> NSObject? {
    guard let type = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
    let make = NSSelectorFromString("filterWithType:")
    guard type.responds(to: make) else { return nil }
    return type.perform(make, with: "variableBlur")?.takeUnretainedValue() as? NSObject
  }

  private static func backdropLayer(in layer: CALayer) -> CALayer? {
    if String(describing: type(of: layer)) == "CABackdropLayer" { return layer }
    return (layer.sublayers ?? []).firstNonNil(backdropLayer)
  }

  /// 蒙版（alpha 就是糊几成）：形体那一块不透明，边往外 spread 之内渐渐变成全透明（到 spread 正好是 0：阴影那种
  /// 永远拖着一点尾巴的晕法，在模糊圈的外沿会留下一道看得见的边）。做法：沿形体的边从粗到细一圈圈描，越细的越不透明、
  /// 盖在上面。size、shape 是这块毛玻璃自己的坐标（左下角原点）；flatTop 时形体顶上两个角是方的；fadeTop：最上面
  /// 这么高的一段往上渐隐到 0（那一圈在顶上被窗口切掉时用）
  static func mask(
    size: CGSize, shape: CGRect, corner: CGFloat, flatTop: Bool, scale: CGFloat,
    fadeTop: CGFloat = 0
  ) -> CGImage? {
    let width = Int((size.width * scale).rounded(.up))
    let height = Int((size.height * scale).rounded(.up))
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    let radius = min(corner, shape.width / 2, shape.height / 2)
    let path = CGMutablePath()
    if flatTop {
      // 顶边方、底边圆（左下角原点：minY 是底）
      path.move(to: CGPoint(x: shape.minX, y: shape.maxY))
      path.addLine(to: CGPoint(x: shape.minX, y: shape.minY + radius))
      path.addQuadCurve(
        to: CGPoint(x: shape.minX + radius, y: shape.minY),
        control: CGPoint(x: shape.minX, y: shape.minY))
      path.addLine(to: CGPoint(x: shape.maxX - radius, y: shape.minY))
      path.addQuadCurve(
        to: CGPoint(x: shape.maxX, y: shape.minY + radius),
        control: CGPoint(x: shape.maxX, y: shape.minY))
      path.addLine(to: CGPoint(x: shape.maxX, y: shape.maxY))
      path.closeSubpath()
    } else {
      path.addRoundedRect(in: shape, cornerWidth: radius, cornerHeight: radius)
    }
    // 后画的整个盖掉先画的（不叠加）
    context.setBlendMode(.copy)
    context.setLineJoin(.round)
    var distance = spread
    while distance > 0 {
      context.setStrokeColor(NSColor.black.withAlphaComponent(falloff(distance)).cgColor)
      context.setLineWidth(distance * 2)
      context.addPath(path)
      context.strokePath()
      distance -= 1
    }
    context.setFillColor(NSColor.black.cgColor)
    context.addPath(path)
    context.fillPath()
    if fadeTop > 0,
      let fade = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor] as CFArray,
        locations: [0, 1])
    {
      // 只动最上面那一段：已有的 alpha 乘上「顶上 0、往下到 1」的渐变
      context.clip(to: CGRect(x: 0, y: size.height - fadeTop, width: size.width, height: fadeTop))
      context.setBlendMode(.destinationIn)
      context.drawLinearGradient(
        fade, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height - fadeTop),
        options: [])
    }
    return context.makeImage()
  }

  /// 离形体的边 distance 远的地方糊几成（纯函数）：贴着边是 1，到 spread 是 0，中间三次曲线（靠外的一大半都很淡：字只是变软，贴着形体的那一段才糊成一片——2026-11-14 用户对着 Alcove 的截图调的，
  /// 原来半径 12、晕开 36、二次曲线：字是一下子被抹掉的，不像糊了）
  static func falloff(_ distance: CGFloat) -> CGFloat {
    let t = 1 - min(max(distance / spread, 0), 1)
    return t * t * t
  }
}
