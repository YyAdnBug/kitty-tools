// 截图框选 / 拖边的纯几何（RegionSelector，mac-whisker §6「框选 / 拖边」「键盘调整」「尺寸胶囊」）：⇧ 比例、⌥ 从中心、
// 超出屏幕时等比缩小、6 pt 吸附、⌘ / ⌥ + 方向键推收边、尺寸输入换算、比例预设套用。坐标是 AppKit 的（y 朝上）。

import CoreGraphics
import Testing

@testable import KittyTools

struct SelectionGeometryTests {
  let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

  private func ratio(_ rect: CGRect) -> CGFloat { rect.width / rect.height }

  @Test func drawnPlainFollowsPointerAnyDirection() {
    #expect(
      RegionSelector.drawn(
        from: CGPoint(x: 300, y: 200), to: CGPoint(x: 700, y: 500), within: bounds)
        == CGRect(x: 300, y: 200, width: 400, height: 300))
    // 往左下拖
    #expect(
      RegionSelector.drawn(
        from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50), within: bounds)
        == CGRect(x: 100, y: 50, width: 200, height: 150))
  }

  // ⇧ 正方形：按拖得更远的那边定大小，方向跟着指针
  @Test func drawnSquareUsesLongerSide() {
    #expect(
      RegionSelector.drawn(
        from: CGPoint(x: 300, y: 200), to: CGPoint(x: 500, y: 260), ratio: 1, within: bounds)
        == CGRect(x: 300, y: 200, width: 200, height: 200))
    #expect(
      RegionSelector.drawn(
        from: CGPoint(x: 300, y: 400), to: CGPoint(x: 250, y: 100), ratio: 1, within: bounds)
        == CGRect(x: 0, y: 100, width: 300, height: 300))
    // 锁着的预设比例
    let wide = RegionSelector.drawn(
      from: CGPoint(x: 100, y: 100), to: CGPoint(x: 260, y: 130), ratio: 16.0 / 9, within: bounds)
    #expect(wide.origin == CGPoint(x: 100, y: 100))
    #expect(wide.width == 160)
    #expect(abs(ratio(wide) - 16.0 / 9) < 1e-9)
  }

  // ⌥ 从中心：锚点是中心，两侧对称；贴着屏幕边时两侧一起缩（中心不动）
  @Test func drawnFromCenter() {
    #expect(
      RegionSelector.drawn(
        from: CGPoint(x: 500, y: 400), to: CGPoint(x: 600, y: 450), fromCenter: true,
        within: bounds) == CGRect(x: 400, y: 350, width: 200, height: 100))
    #expect(
      RegionSelector.drawn(
        from: CGPoint(x: 50, y: 400), to: CGPoint(x: 200, y: 450), fromCenter: true,
        within: bounds) == CGRect(x: 0, y: 350, width: 100, height: 100))
  }

  // 锁比例时碰到屏幕边：等比缩小，不变形
  @Test func drawnRatioShrinksInsideBounds() {
    let rect = RegionSelector.drawn(
      from: CGPoint(x: 1000, y: 700), to: CGPoint(x: 1200, y: 800), ratio: 1, within: bounds)
    #expect(rect == CGRect(x: 1000, y: 700, width: 100, height: 100))
    let centered = RegionSelector.drawn(
      from: CGPoint(x: 1100, y: 400), to: CGPoint(x: 1200, y: 600), ratio: 1, fromCenter: true,
      within: bounds)
    #expect(centered == CGRect(x: 1000, y: 300, width: 200, height: 200))
  }

  // ⇧ 拖角保持原比例（按更远的那边）；锁着的比例拖边时另一边跟着、以原中心对齐
  @Test func resizedKeepsRatio() {
    let original = CGRect(x: 300, y: 200, width: 400, height: 200)
    let corner = RegionSelector.resized(
      original, .topRight, to: CGPoint(x: 900, y: 420), within: bounds, ratio: 2)
    #expect(corner == CGRect(x: 300, y: 200, width: 600, height: 300))
    let edge = RegionSelector.resized(
      original, .right, to: CGPoint(x: 900, y: 0), within: bounds, ratio: 2)
    #expect(edge == CGRect(x: 300, y: 150, width: 600, height: 300))
    let top = RegionSelector.resized(
      original, .top, to: CGPoint(x: 0, y: 500), within: bounds, ratio: 2)
    #expect(top == CGRect(x: 200, y: 200, width: 600, height: 300))
    // 越过对边：翻过去，比例不变
    let flipped = RegionSelector.resized(
      original, .bottomRight, to: CGPoint(x: 200, y: 500), within: bounds, ratio: 2)
    #expect(flipped == CGRect(x: 100, y: 400, width: 200, height: 100))
  }

  // ⌥ 从中心：对边反向一起动；角两条边都对称
  @Test func resizedFromCenter() {
    let original = CGRect(x: 300, y: 200, width: 400, height: 200)
    #expect(
      RegionSelector.resized(
        original, .right, to: CGPoint(x: 750, y: 0), within: bounds, fromCenter: true)
        == CGRect(x: 250, y: 200, width: 500, height: 200))
    #expect(
      RegionSelector.resized(
        original, .bottomLeft, to: CGPoint(x: 250, y: 150), within: bounds, fromCenter: true)
        == CGRect(x: 250, y: 150, width: 500, height: 300))
    // 从中心 + 锁比例，碰到屏幕边时等比缩
    let clamped = RegionSelector.resized(
      CGRect(x: 100, y: 300, width: 200, height: 200), .right, to: CGPoint(x: 400, y: 0),
      within: bounds, ratio: 1, fromCenter: true)
    #expect(clamped == CGRect(x: 0, y: 200, width: 400, height: 400))
  }

  @Test func snappingWithinSixPoints() {
    let edges: [CGFloat] = [0, 400, 412, 1200]
    #expect(RegionSelector.snapped(405, to: edges) == (400, 400))
    #expect(RegionSelector.snapped(407, to: edges) == (412, 412))  // 取最近的
    #expect(RegionSelector.snapped(394, to: edges) == (400, 400))  // 正好 6 pt 也吸
    #expect(RegionSelector.snapped(393, to: edges).edge == nil)
    #expect(RegionSelector.snapped(393, to: edges).value == 393)
    #expect(RegionSelector.snapped(5, to: []).edge == nil)
  }

  // ⌘ 推外、⌥ 收里：方向键选那一侧的边（↑ 是上边 maxY）；短边不小于 8，夹在屏内
  @Test func pushedEdges() {
    let rect = CGRect(x: 300, y: 200, width: 400, height: 300)
    #expect(
      RegionSelector.pushed(rect, .right, by: 1, within: bounds)
        == CGRect(x: 300, y: 200, width: 401, height: 300))
    #expect(
      RegionSelector.pushed(rect, .left, by: -10, within: bounds)
        == CGRect(x: 310, y: 200, width: 390, height: 300))
    #expect(
      RegionSelector.pushed(rect, .top, by: 1, within: bounds)
        == CGRect(x: 300, y: 200, width: 400, height: 301))
    #expect(
      RegionSelector.pushed(rect, .bottom, by: 10, within: bounds)
        == CGRect(x: 300, y: 190, width: 400, height: 310))
    // 收到只剩 8 就停；推到屏幕边就停
    let narrow = CGRect(x: 300, y: 200, width: 12, height: 300)
    #expect(RegionSelector.pushed(narrow, .right, by: -10, within: bounds).width == 8)
    #expect(RegionSelector.pushed(narrow, .left, by: -10, within: bounds).minX == 304)
    #expect(
      RegionSelector.pushed(
        CGRect(x: 1195, y: 0, width: 5, height: 5), .right, by: 10, within: bounds
      )
      .maxX == 1200)
    // 本来就比 8 小的不再收
    let tiny = CGRect(x: 10, y: 10, width: 4, height: 4)
    #expect(RegionSelector.pushed(tiny, .top, by: -1, within: bounds) == tiny)
  }

  // 尺寸输入：像素 → 点（每点 2 像素），左上角不动（对齐到像素格），夹进屏内
  @Test func sizedKeepsTopLeft() {
    let rect = CGRect(x: 300, y: 200, width: 400, height: 300)
    let scale = CGSize(width: 2, height: 2)
    #expect(
      RegionSelector.sized(
        rect, pixels: CGSize(width: 1280, height: 720), scale: scale, within: bounds)
        == CGRect(x: 300, y: 140, width: 640, height: 360))
    // 太大：右边、下边夹在屏幕边
    #expect(
      RegionSelector.sized(
        rect, pixels: CGSize(width: 5000, height: 5000), scale: scale, within: bounds)
        == CGRect(x: 300, y: 0, width: 900, height: 500))
    // 左上角在半像素上：先对齐（1 点 = 2 像素时 0.25 点对到 0.5 的倍数）
    let fractional = CGRect(x: 10.2, y: 20, width: 100, height: 99.8)
    let snapped = RegionSelector.sized(
      fractional, pixels: CGSize(width: 100, height: 100), scale: scale, within: bounds)
    #expect(snapped.minX == 10)
    #expect(snapped.maxY == 120)
    #expect(snapped.size == CGSize(width: 50, height: 50))
    // 左上角和显示、裁出来的一样（pixelRect 往外取整：左边向下、上边向上），输入宽高不挪它
    let view = CGSize(width: 1200, height: 800)
    for (dragged, scale) in [
      (CGRect(x: 300.7, y: 200.2, width: 399.5, height: 300.2), CGSize(width: 1, height: 1)),
      (CGRect(x: 300.3, y: 200.2, width: 399.5, height: 300.1), CGSize(width: 2, height: 2)),
    ] {
      let image = CGSize(width: view.width * scale.width, height: view.height * scale.height)
      let before = RegionSelector.pixelRect(dragged, viewSize: view, imageSize: image)
      let typed = RegionSelector.sized(
        dragged, pixels: CGSize(width: 300, height: 300), scale: scale, within: bounds)
      let after = RegionSelector.pixelRect(typed, viewSize: view, imageSize: image)
      #expect(after.origin == before.origin, "\(dragged) @\(scale.width)x")
      #expect(after.size == CGSize(width: 300, height: 300))
    }
  }

  // 比例预设：宽不变、顶边和水平中心不动；下面放不下按剩下的高反推（只会变窄）
  @Test func applyingRatioKeepsTopAndCenter() {
    let rect = CGRect(x: 300, y: 200, width: 400, height: 300)
    #expect(
      RegionSelector.applying(16.0 / 9, to: rect, within: bounds)
        == CGRect(x: 300, y: 275, width: 400, height: 225))
    let tall = RegionSelector.applying(9.0 / 16, to: rect, within: bounds)
    #expect(tall.maxY == 500)
    #expect(tall.minY == 0)
    #expect(abs(tall.midX - 500) < 1e-9)
    #expect(abs(ratio(tall) - 9.0 / 16) < 1e-9)
    #expect(RegionSelector.ratioTitle(16.0 / 9) == "16:9")
    #expect(RegionSelector.ratioTitle(nil) == "自由")
  }

  // 拖过对边后在动的是另一侧：左边拖到右边外面就是右边，角两个方向各自翻；只看这个手柄管的方向
  @Test func handleFacingFlipsAcrossOppositeEdge() {
    let rect = CGRect(x: 700, y: 200, width: 100, height: 300)
    #expect(RegionSelector.Handle.left.facing(CGPoint(x: 800, y: 350), in: rect) == .right)
    #expect(RegionSelector.Handle.left.facing(CGPoint(x: 700, y: 350), in: rect) == .left)
    #expect(RegionSelector.Handle.top.facing(CGPoint(x: 900, y: 200), in: rect) == .bottom)
    #expect(RegionSelector.Handle.topLeft.facing(CGPoint(x: 800, y: 500), in: rect) == .topRight)
    #expect(
      RegionSelector.Handle.topLeft.facing(CGPoint(x: 800, y: 200), in: rect) == .bottomRight)
  }

  /// 长截图、录屏在实时画面上截的那块（RegionSelector.captureRect）：夹进屏、四边对齐到像素，sourceRect 是屏内、原点左上；
  /// 副屏（全局坐标不从 0 起）也一样
  @Test func captureRectClampsSnapsAndFlips() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let (region, source) = RegionSelector.captureRect(
      CGRect(x: 100.3, y: 200.2, width: 400.4, height: 300.1), in: screen, scale: 2)
    #expect(region == CGRect(x: 100.5, y: 200, width: 400.5, height: 300))
    #expect(source == CGRect(x: 100.5, y: 982 - 500, width: 400.5, height: 300))
    // 伸出屏外的部分裁掉；整屏的 sourceRect 就是整屏
    let right = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
    let clamped = RegionSelector.captureRect(
      CGRect(x: 1400, y: 700, width: 400, height: 400), in: right, scale: 1)
    #expect(clamped.region == CGRect(x: 1512, y: 700, width: 288, height: 180))
    #expect(clamped.source == CGRect(x: 0, y: 0, width: 288, height: 180))
    let full = RegionSelector.captureRect(screen, in: screen, scale: 2)
    #expect(full.region == screen && full.source == screen)
  }
}
