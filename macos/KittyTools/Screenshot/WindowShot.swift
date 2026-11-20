// 单击窗口截下时的透明圆角 + 窗口阴影（第五轮体检 N1，2026-11-19；设置 › 截图 › 高级「窗口截图带阴影」，默认开）。
// 对标系统 ⌘⇧4 + 空格：四角透明、四周带窗口阴影的 PNG。**画面一律是冻结帧**（框选时看到的那一帧：同一个 App 压在窗口上的
// 工具提示、弹出菜单、sheet，延时截图等来的悬停状态，带上的鼠标指针，标注指着的东西都在）：
// 1. 单击选中一扇整个在这块屏里的窗口、选区没再动过，按拷贝 / 存储 / 另存为 / 钉图时，SelectionView.output 在交出的那一刻
//    （遮罩还在）就开始用 ScreenCaptureKit 单独截那一扇窗口（`SCContentFilter(desktopIndependentWindow:)`；
//    `ignoreShadowsSingleWindow = true` 不要系统画的阴影、`shouldBeOpaque = false` 不垫白底），连同「冻结时排在它前面、
//    属于别的进程的窗口盖住的那几块」（covered，同一个 App 的子窗口不算）放进 Capture.window；
// 2. 出图前 AppDelegate.deliver 等它截完（2 秒封顶），在这里合成：冻结帧那一块就是画面，只有 covered 那几块换成单独截的
//    （别的 App 的窗口挡住的地方露出这扇窗口自己的）；**画了打码的连这几块也不换**（码是按冻结那一刻看到的摆的，挡住的
//    地方底下的字没被认过）；单独截的那张只借它的形状（alpha ×4：圆角边上的抗锯齿留着，半透明的侧栏当实心）；
// 3. 按形状裁，四周留边画两层阴影（往下偏的一大片淡的在四分之一大小上画再放大，贴边的一圈在原大小上画）。不用系统的窗口阴影：
//    它往外扩多少、窗口落在图里的哪个位置拿不到，标注、钉图的位置就对不上。
// 截不到（窗口没了、系统服务不答、受保护的内容截出来几乎全透明、尺寸和冻结时对不上）就交回原来的矩形裁切。
// 历史存的原图是带阴影、没标注的那张（另记一个「窗口截图」的标记，钉图按它不套框），标注跟着挪进留边；frame 往外扩出留边：
// 飞行卡片、钉图按它摆，窗口落在原来的位置。合成在主线程（同 Annotation.render 出图）：阴影的大头挪到了四分之一大小上画，
// 3000 × 1900 像素的窗口整次见 PLAN §10 的量测。
// 框选时这扇窗口的框（悬停、单击选中）照它真实的圆角画、和出图一个形状（2026-11-20，SelectionView.cornerRadius(of:)）：
// 圆角在这里量（cornerRadius，只截左上角一小块），SelectionSession.windowRadius 记着。

import AppKit
import ScreenCaptureKit

enum WindowShot {
  /// 出图时换成单窗口截图的那扇（SelectionView.output 交出时就开始截）
  struct Pending {
    /// 单独截的那张（遮罩还在时就开始截；截不到 nil）
    let shot: Task<CGImage?, Never>
    /// 冻结时排在它前面、属于别的进程的窗口盖住的几块（点，相对选区左下角）：只有这几块用单独截的画面
    var covered: [CGRect] = []
  }

  /// 四周留给阴影的边（点）：往下偏的那一片要下面多留
  static let margins = NSEdgeInsets(top: 30, left: 48, bottom: 64, right: 48)
  /// 两层阴影（点）：往下偏的一大片淡的、贴边的一圈
  private static let shadow = (offset: CGFloat(20), blur: CGFloat(40), alpha: CGFloat(0.5))
  private static let rim = (blur: CGFloat(1.5), alpha: CGFloat(0.4))
  /// 那一大片淡的按几分之一的大小画（模糊半径几十个像素，按原大小画是整个合成里最贵的一步）
  private static let softScale: CGFloat = 4
  /// 单独截的和冻结帧里那一块最多差几个像素（取整的出入）；差得多 = 窗口这几秒变了大小，标注对不上
  static let tolerance = 2

  /// 冻结时排在 index 那扇前面、属于别的进程的窗口盖住它的几块（点，相对那扇窗口的左下角）。windows 从前到后，owners 和它
  /// 一一对应；同一个进程的（子窗口：工具提示、弹出菜单、sheet）不算，哪扇不知道归谁（空的）也不算。挡着的窗口往外扩出它
  /// 自己阴影的那一圈（按 margins 估）：冻结帧里那一圈是它投下的影子，只换窗口那一块的话影子会留在图上。纯函数，配单测
  static func covered(_ index: Int, windows: [CGRect], owners: [[pid_t]]) -> [CGRect] {
    guard windows.indices.contains(index), owners.indices.contains(index), !owners[index].isEmpty
    else { return [] }
    let window = windows[index]
    let mine = Set(owners[index])
    return (0..<index).compactMap { front in
      guard owners.indices.contains(front), !owners[front].isEmpty,
        mine.isDisjoint(with: owners[front])
      else { return nil }
      let shade = windows[front]
      let overlap = CGRect(
        x: shade.minX - margins.left, y: shade.minY - margins.bottom,
        width: shade.width + margins.left + margins.right,
        height: shade.height + margins.top + margins.bottom
      ).intersection(window)
      guard !overlap.isNull, !overlap.isEmpty else { return nil }
      return overlap.offsetBy(dx: -window.minX, dy: -window.minY)
    }
  }

  /// 换成透明圆角带阴影的那一张；不是窗口出图、截不到、合成失败都交回矩形裁切（去掉 window）
  static func dress(_ capture: RegionSelector.Capture) async -> RegionSelector.Capture {
    guard let pending = capture.window else { return capture }
    var plain = capture
    plain.window = nil
    guard let live = await pending.shot.value,
      let dressed = compose(plain, window: live, covered: pending.covered)
    else { return plain }
    return dressed
  }

  /// 单独截那一扇窗口：不要系统阴影、不垫白底，按窗口所在屏的分辨率；corner 给了就只截左上角 corner 点见方（量圆角；
  /// 窗口不到它两倍大时 nil）。截不到 nil（屏幕录制授权在截图开始时已经查过）。系统服务不答最多等 2 秒（同冻结帧的 E22）
  static func snapshot(_ id: CGWindowID, corner: CGFloat? = nil) async -> CGImage? {
    let shot = try? await ScreenCapture.within(.seconds(2)) { () async throws -> CGImage? in
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let configuration = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      var size = filter.contentRect.size
      if let corner {
        guard size.width >= corner * 2, size.height >= corner * 2 else { return nil }
        size = CGSize(width: corner, height: corner)
        configuration.sourceRect = CGRect(origin: .zero, size: size)  // 原点在窗口左上（27.0.1 实测）
      }
      configuration.width = Int((size.width * scale).rounded())
      configuration.height = Int((size.height * scale).rounded())
      configuration.showsCursor = false
      configuration.ignoreShadowsSingleWindow = true
      configuration.shouldBeOpaque = false
      return try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
    }
    return shot ?? nil
  }

  /// 那扇窗口的圆角（点）：只截左上角 48 点见方来量（cornerRadius(of:)；27.0.1 实测连同列窗口一次约 50 ms）。量不出 nil
  static func cornerRadius(of id: CGWindowID) async -> CGFloat? {
    let side: CGFloat = 48
    guard let corner = await snapshot(id, corner: side), let radius = cornerRadius(of: corner)
    else { return nil }
    return radius * side / CGFloat(corner.width)
  }

  /// 窗口的圆角量出来之前先按这个画（点）：15 上的标准窗口约 10；26 起变大，27.0.1 实测各 App 的窗口都是 16.5
  static var defaultRadius: CGFloat {
    if #available(macOS 26, *) { 16.5 } else { 10 }
  }

  /// 合成（文件头 2、3）。live 是单独截的那扇窗口，和 capture 里的冻结帧那一块同一个大小（差 tolerance 以内）；
  /// covered 是要换成它的那几块（点，相对选区左下角）。截出来几乎全透明、尺寸对不上、合成失败 nil
  static func compose(
    _ capture: RegionSelector.Capture, window live: CGImage, covered: [CGRect] = []
  ) -> RegionSelector.Capture? {
    let frozen = capture.original ?? capture.image
    let size = CGSize(width: live.width, height: live.height)
    guard capture.frame.width > 0, abs(live.width - frozen.width) <= tolerance,
      abs(live.height - frozen.height) <= tolerance, !isMostlyClear(live)
    else { return nil }
    let scale = size.width / capture.frame.width
    let redacts = capture.annotations.contains { $0.tool == .mosaic }
    // 画面：冻结帧；别的 App 的窗口挡住的那几块换成单独截的（画了打码的不换）
    let patched =
      redacts || covered.isEmpty
      ? nil
      : patch(
        frozen, with: live,
        in: covered.map {
          CGRect(
            x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale,
            height: $0.height * scale)
        })
    let base = patched ?? frozen
    // 没换的话成品就是交出来的那张（标注已经画好），不再画一遍
    let annotated: CGImage? =
      patched == nil || capture.annotations.isEmpty
      ? (patched == nil ? capture.image : base)
      : Annotation.render(
        capture.annotations, over: base, pixelRect: CGRect(origin: .zero, size: size),
        viewSize: capture.frame.size)
    guard let annotated, let mask = shape(of: live),
      let original = shadowed(cut(base, to: mask), shape: mask, scale: scale),
      let image =
        annotated === base
        ? original : shadowed(cut(annotated, to: mask), shape: mask, scale: scale)
    else { return nil }
    // 留边按整像素算，换回点：frame 和图的像素 / 点比例不变（Capture.scale）
    let pad = padding(scale: scale)
    let left = pad.left / scale
    let bottom = pad.bottom / scale
    let frame = CGRect(
      x: capture.frame.minX - left, y: capture.frame.minY - bottom,
      width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    return RegionSelector.Capture(
      image: image, frame: frame, action: capture.action, original: original,
      annotations: capture.annotations.map { $0.offset(by: CGSize(width: left, height: bottom)) },
      isWindow: true)
  }

  /// 四边留多少像素（按每点几个像素取整）
  static func padding(scale: CGFloat) -> NSEdgeInsets {
    NSEdgeInsets(
      top: (margins.top * scale).rounded(), left: (margins.left * scale).rounded(),
      bottom: (margins.bottom * scale).rounded(), right: (margins.right * scale).rounded())
  }

  // MARK: 画（纯函数，配单测）

  /// 截出来几乎全透明（受保护的内容、不让截的窗口）：缩成 16 × 16 看，有东西的格子不到一半
  static func isMostlyClear(_ image: CGImage) -> Bool {
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return true }
    let solid = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 24 }.count
    return solid * 2 < side * side
  }

  /// 窗口左上角的圆角半径（像素）：沿对角线从角往里走，alpha 到里面那一点（离角 side − 1 格）的一半处离角 t（像素中心、
  /// 前后两格插值），圆弧的话 t = r(1 − 1/√2)。只读左上角一小块（27.0.1 实测各 App 的窗口四个角一样，WindowRadiusProbeTests）；
  /// 几乎透明、太小 nil，角上就是实心的 0
  static func cornerRadius(of image: CGImage) -> CGFloat? {
    let side = min(96, image.width / 2, image.height / 2)
    guard side >= 4, let corner = image.cropping(to: CGRect(x: 0, y: 0, width: side, height: side))
    else { return nil }
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(corner, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    // 对角线上第 i 格的 alpha（内存里第 0 行在上面）
    let at = { (i: Int) in CGFloat(pixels[(i * side + i) * 4 + 3]) }
    let half = at(side - 1) / 2
    guard drawn, half >= 8, let first = (0..<side).first(where: { at($0) >= half }) else {
      return nil
    }
    guard first > 0 else { return 0 }
    let crossing =
      CGFloat(first) - 0.5 + (half - at(first - 1)) / max(1, at(first) - at(first - 1))
    return crossing / (1 - 1 / 2.squareRoot())
  }

  /// 四角按 radius（像素）裁成透明：截图圆角（SelectionView.output），形状同框选时的框（SelectionView.roundedPath）。
  /// ponytail: 在主线程整张重画一遍（同 Annotation.render 出图），5K 整屏几十毫秒
  static func rounded(_ image: CGImage, radius: CGFloat) -> CGImage? {
    canvas(width: image.width, height: image.height, like: image) { context, rect in
      context.addPath(SelectionView.roundedPath(rect, radius: radius))
      context.clip()
      context.draw(image, in: rect)
    }
  }

  /// 冻结帧那一块垫底，rects（像素，原点左下）里换成单独截的（大小按单独截的）
  static func patch(_ frozen: CGImage, with live: CGImage, in rects: [CGRect]) -> CGImage? {
    canvas(width: live.width, height: live.height, like: live) { context, rect in
      context.draw(frozen, in: rect)
      context.clip(to: rects)
      context.draw(live, in: rect)
    }
  }

  /// 窗口的形状：单独截的那张的 alpha ×4（叠画四遍 plusLighter：圆角边上的抗锯齿还在，半透明的侧栏这类当实心）
  static func shape(of live: CGImage) -> CGImage? {
    canvas(width: live.width, height: live.height, like: live) { context, rect in
      context.setBlendMode(.plusLighter)
      for _ in 0..<4 { context.draw(live, in: rect) }
    }
  }

  /// 按形状裁（destinationIn：留下 image 里形状不透明的那部分）；image 缩放到形状的大小
  static func cut(_ image: CGImage, to mask: CGImage) -> CGImage? {
    canvas(width: mask.width, height: mask.height, like: mask) { context, rect in
      context.draw(image, in: rect)
      context.setBlendMode(.destinationIn)
      context.draw(mask, in: rect)
    }
  }

  /// 四周留边、画两层阴影：往下偏的一大片淡的按形状在 1 / softScale 大小上画（形状本身挪出画布，只让影子落进来）、
  /// 放大垫在最底下；贴边的一圈跟着图在原大小上画
  static func shadowed(_ image: CGImage?, shape mask: CGImage, scale: CGFloat) -> CGImage? {
    guard let image else { return nil }
    let pad = padding(scale: scale)
    let width = image.width + Int(pad.left + pad.right)
    let height = image.height + Int(pad.top + pad.bottom)
    let window = CGRect(
      x: pad.left, y: pad.bottom, width: CGFloat(image.width), height: CGFloat(image.height))
    let factor = softScale
    let far = CGFloat(width) / factor
    let soft = canvas(
      width: Int((CGFloat(width) / factor).rounded(.up)),
      height: Int((CGFloat(height) / factor).rounded(.up)), like: image
    ) { context, _ in
      context.setShadow(
        offset: CGSize(width: -far, height: -shadow.offset * scale / factor),
        blur: shadow.blur * scale / factor, color: CGColor(gray: 0, alpha: shadow.alpha))
      context.draw(
        mask,
        in: CGRect(
          x: window.minX / factor + far, y: window.minY / factor,
          width: window.width / factor, height: window.height / factor))
    }
    return canvas(width: width, height: height, like: image) { context, rect in
      if let soft {
        context.interpolationQuality = .high
        context.draw(soft, in: rect)
      }
      context.setShadow(
        offset: .zero, blur: rim.blur * scale, color: CGColor(gray: 0, alpha: rim.alpha))
      context.draw(image, in: window)
    }
  }

  /// 透明的 8 位 BGRA 画布，颜色空间沿用 like 的（RGB、不是扩展范围的；别的换 sRGB：8 位预乘只认 RGB）
  private static func canvas(
    width: Int, height: Int, like image: CGImage, draw: (CGContext, CGRect) -> Void
  ) -> CGImage? {
    let space =
      image.colorSpace.flatMap { $0.model == .rgb && !CGColorSpaceUsesExtendedRange($0) ? $0 : nil }
      ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    draw(context, CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}
