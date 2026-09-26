// 截图遮罩外观的纯几何：洞 / 高亮框的圆角路径元素数恒定（S5 变形要求）、工具栏放哪、HUD 小控件的外圈描边、
// 工具栏图标在 macOS 15 上都有

import AppKit
import Testing

@testable import KittyTools

@MainActor @Suite
struct ShotChromeTests {
  private func elements(_ path: CGPath) -> [CGPathElementType] {
    var types: [CGPathElementType] = []
    path.applyWithBlock { types.append($0.pointee.type) }
    return types
  }

  // 窗口（圆角 10）、光标处的零尺寸占位、选区（圆角 0）三种洞的路径结构一样，才能互相插值
  @Test func roundedPathKeepsElementsForMorphing() {
    let window = SelectionView.roundedPath(
      CGRect(x: 10, y: 20, width: 300, height: 200), radius: 10)
    let spot = SelectionView.roundedPath(CGRect(x: 50, y: 60, width: 0, height: 0), radius: 10)
    let selection = SelectionView.roundedPath(
      CGRect(x: 10, y: 20, width: 300, height: 200), radius: 0)
    #expect(elements(window).count == 10)
    #expect(elements(window) == elements(spot))
    #expect(elements(window) == elements(selection))
    #expect(spot.boundingBoxOfPath == CGRect(x: 50, y: 60, width: 0, height: 0))
    #expect(window.boundingBoxOfPath == CGRect(x: 10, y: 20, width: 300, height: 200))
  }

  // 选区下方放不下 → 上方；上下都放不下（整屏）→ 选区底部里面；横向夹在屏内 10 pt
  @Test func toolbarPlacement() {
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let size = CGSize(width: 700, height: 40)
    let below = SelectionView.toolbarPlacement(
      size: size, selection: CGRect(x: 300, y: 200, width: 400, height: 300), in: bounds)
    #expect(below.origin == CGPoint(x: 150, y: 150))
    #expect(below.edge == .top)
    let above = SelectionView.toolbarPlacement(
      size: size, selection: CGRect(x: 0, y: 20, width: 200, height: 300), in: bounds)
    #expect(above.origin == CGPoint(x: 10, y: 330))
    #expect(above.edge == .bottom)
    let inside = SelectionView.toolbarPlacement(size: size, selection: bounds, in: bounds)
    #expect(inside.origin == CGPoint(x: 250, y: 10))
    #expect(inside.edge == .bottom)
    // 鼠标给的小数点选区：栏落在整点上（图标、描边不发糊）
    let fractional = SelectionView.toolbarPlacement(
      size: size, selection: CGRect(x: 300.3, y: 200.6, width: 400.5, height: 300), in: bounds)
    #expect(fractional.origin == CGPoint(x: 151, y: 151))
  }

  // 纯图层画的 HUD 小控件（尺寸胶囊、提示、信息卡）也有外圈 0.5 pt black 0.5：边外 0.5、圆角大 0.5，跟着尺寸走，不重复加
  @Test func hudSkinHasOuterStroke() throws {
    let layer = CALayer()
    Style.HUD.applySkin(to: layer, radius: 6)
    layer.bounds = CGRect(x: 0, y: 0, width: 120, height: 26)
    Style.HUD.applySkin(to: layer, radius: 13, curve: .circular)
    #expect(layer.sublayers?.count == 1)
    let ring = try #require(layer.sublayers?.first)
    #expect(ring.frame == CGRect(x: -0.5, y: -0.5, width: 121, height: 27))
    #expect(ring.borderWidth == 0.5 && ring.cornerRadius == 13.5 && ring.cornerCurve == .circular)
    #expect(ring.borderColor == Style.HUD.outerStroke.cgColor)
    let field = SizeField()
    field.show(width: 640, height: 480, interactive: true, ratio: "自由", locked: false)
    let outer = try #require(field.layer?.sublayers?.first { $0.name == ring.name })
    #expect(outer.frame == field.bounds.insetBy(dx: -0.5, dy: -0.5))
  }

  // 栏里用到的 SF Symbols 在最低系统上都存在（force unwrap 不会崩）
  @Test func toolbarSymbolsExist() {
    let symbols =
      Annotation.Tool.allCases.map(\.symbol) + [
        "arrow.uturn.backward", "arrow.uturn.forward", "text.viewfinder", "character.bubble",
        "rectangle.expand.vertical", "pin", "square.and.arrow.down", "chevron.down", "xmark",
        "checkmark",
      ]
    for symbol in symbols {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  // 两段胶囊并排、间距 6；每个工具按钮都在左段里
  @Test func toolbarLayout() throws {
    let toolbar = EditorToolbar()
    #expect(toolbar.frame.height == 40)
    let frames = Annotation.Tool.allCases.map(toolbar.toolButtonFrame)
    #expect(frames.allSatisfy { $0.width == 32 && $0.height == 32 }, "\(frames)")
    #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX < $1.minX })
    let save = try #require(toolbar.button(for: .output(.save)))
    #expect(save.convert(save.bounds, to: toolbar).minX > frames.last!.maxX + 6)
  }
}
