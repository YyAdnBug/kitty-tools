// 截图标注模型单测（Whisker §6「工具」）：10 个工具的元数据（图标不随系统语言换字形）、拖出的形状与 ⇧ 约束、点中判断（按画的层次）、手柄与改大小、复制、
// 序号编号、每个工具记住的样式，以及 drawAll 的像素：聚光灯只压暗选区里的洞外、重叠的洞不再压暗、挪洞 / 挪选区 / 画笔累点只需重画变了的几块、
// 序号压在后画的标注上面、模糊马赛克和像素马赛克不同且都认不出字、荧光笔正片叠底在屏幕（透明标注层）和导出上一样、文字底色块；
// 弯箭头：弯曲手柄 ↔ 弯度 / 控制点、沿弦停在 ¼ / ¾、吸回直的、拖两端等比、外框和点中跟着弧线（远处先按外框排除）、沿弧线画、
// 颈部不折、拖短了照样沿弧线画且都在外框里，直箭头的七边形不变。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct AnnotationToolTests {
  private let view = CGSize(width: 100, height: 100)

  // MARK: 元数据

  @Test func toolMetadata() {
    #expect(
      Annotation.Tool.allCases.map(\.key) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    #expect(
      Annotation.Tool.allCases.first == .rectangle && Annotation.Tool.allCases.last == .spotlight)
    for tool in Annotation.Tool.allCases {
      #expect(
        NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil, "\(tool)")
      #expect(tool.weightTitles.count == Annotation.Weight.allCases.count)
    }
    #expect(Annotation.Tool.allCases.filter { !$0.hasColor } == [.mosaic, .spotlight])
    #expect(Annotation.Tool.allCases.filter { !$0.isDragDrawn } == [.text, .counter])
    #expect(Annotation.Tool.text.optionTitles == ["无底", "描边", "底色"])
    #expect(Annotation.Tool.mosaic.optionTitles == ["像素", "模糊"])
    #expect(Annotation.Tool.arrow.optionTitles.isEmpty)
    #expect(Annotation.Palette.allCases.first == .pink && Annotation.Palette.allCases.count == 8)
  }

  @Test func toolSymbolsDoNotFollowSystemLanguage() throws {
    // textformat 在中文系统上画成「格式」：工具栏图标在中文、英文下要画得一模一样
    func png(_ name: String, _ locale: String) throws -> Data? {
      let image = try #require(
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
          .withSymbolConfiguration(.init(pointSize: 30, weight: .medium))?
          .withLocale(Locale(identifier: locale)))
      let rep = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      image.draw(in: NSRect(x: 4, y: 4, width: 40, height: 40))
      NSGraphicsContext.restoreGraphicsState()
      return rep.representation(using: .png, properties: [:])
    }
    #expect(try png("textformat", "en") != png("textformat", "zh-Hans"), "这台机器上验证不出本地化字形")
    for tool in Annotation.Tool.allCases {
      #expect(try png(tool.symbol, "en") == png(tool.symbol, "zh-Hans"), "\(tool)")
    }
  }

  // MARK: 几何

  @Test func shapesForEveryDragTool() {
    let start = CGPoint(x: 10, y: 10)
    let end = CGPoint(x: 40, y: -5)
    for tool in Annotation.Tool.allCases {
      let shape = Annotation.shape(for: tool, from: start, to: end, constrained: false)
      if tool.isDragDrawn {
        #expect(shape.map { Annotation(shape: $0).tool } == tool, "\(tool)")
      } else {
        #expect(shape == nil, "\(tool)")
      }
    }
    let square = CGRect(x: 10, y: -20, width: 30, height: 30)
    #expect(
      Annotation.shape(for: .ellipse, from: start, to: end, constrained: true) == .ellipse(square))
    #expect(
      Annotation.shape(for: .spotlight, from: start, to: end, constrained: true)
        == .spotlight(square))
    #expect(
      Annotation.shape(for: .mosaic, from: start, to: end, constrained: false)
        == .mosaic(CGRect(x: 10, y: -5, width: 30, height: 15)))
    #expect(
      Annotation.shape(for: .pen, from: start, to: end, constrained: true) == .pen([start, end]))
    // 线类 ⇧ 吸 45°，长度不变
    for tool in [Annotation.Tool.line, .highlighter] {
      guard
        let shape = Annotation.shape(
          for: tool, from: .zero, to: CGPoint(x: 100, y: 90), constrained: true),
        case (.start, _) = Annotation(shape: shape).handles[0],
        case (.end, let tip) = Annotation(shape: shape).handles[1]
      else { return #expect(Bool(false), "\(tool)") }
      #expect(abs(tip.x - tip.y) < 0.001 && abs(hypot(tip.x, tip.y) - hypot(100, 90)) < 0.001)
    }
  }

  @Test func hitTestingPerTool() {
    let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
    var filled = Annotation.Style()
    filled.option = 1
    // 空心矩形 / 椭圆只认线，实心认整块
    let hollowRect = Annotation(shape: .rectangle(rect))
    #expect(
      hollowRect.contains(CGPoint(x: 101, y: 150)) && !hollowRect.contains(CGPoint(x: 200, y: 150)))
    #expect(Annotation(shape: .rectangle(rect), style: filled).contains(CGPoint(x: 200, y: 150)))
    let hollowEllipse = Annotation(shape: .ellipse(rect))
    #expect(hollowEllipse.contains(CGPoint(x: 200, y: 199)))  // 上边的弧
    #expect(!hollowEllipse.contains(CGPoint(x: 200, y: 150)))
    #expect(!hollowEllipse.contains(CGPoint(x: 104, y: 196)))  // 外接矩形的角上不算
    #expect(Annotation(shape: .ellipse(rect), style: filled).contains(CGPoint(x: 200, y: 150)))
    // 聚光灯只认边（里面还要接着画别的标注），马赛克认整块
    let spotlight = Annotation(shape: .spotlight(rect))
    #expect(
      spotlight.contains(CGPoint(x: 299, y: 150)) && !spotlight.contains(CGPoint(x: 200, y: 150)))
    #expect(Annotation(shape: .mosaic(rect)).contains(CGPoint(x: 200, y: 150)))
    // 线类
    let line = Annotation(shape: .line(from: .zero, to: CGPoint(x: 100, y: 0)))
    #expect(line.contains(CGPoint(x: 50, y: 5)) && !line.contains(CGPoint(x: 50, y: 8)))
    let highlighter = Annotation(shape: .highlighter(from: .zero, to: CGPoint(x: 100, y: 0)))
    #expect(
      highlighter.contains(CGPoint(x: 50, y: 12)) && !highlighter.contains(CGPoint(x: 50, y: 15)))
    let pen = Annotation(shape: .pen([.zero, CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)]))
    #expect(pen.contains(CGPoint(x: 53, y: 30)) && !pen.contains(CGPoint(x: 20, y: 30)))
    // 序号认整个圆（中号直径 26）
    let counter = Annotation(shape: .counter(1, center: CGPoint(x: 50, y: 50)))
    #expect(counter.contains(CGPoint(x: 50, y: 65)) && !counter.contains(CGPoint(x: 50, y: 68)))
    #expect(counter.bounds.width >= 26)
    #expect(Annotation(shape: .counter(1, center: .zero)).isMeaningful)
    #expect(!Annotation(shape: .pen([.zero, CGPoint(x: 1, y: 1)])).isMeaningful)
    #expect(!Annotation(shape: .line(from: .zero, to: CGPoint(x: 3, y: 3))).isMeaningful)
  }

  @Test func handlesAndResize() {
    let rect = CGRect(x: 10, y: 20, width: 40, height: 30)
    let box = Annotation(shape: .rectangle(rect))
    let corners = Dictionary(uniqueKeysWithValues: box.handles.map { ($0.0, $0.1) })
    #expect(
      corners[.topLeft] == CGPoint(x: 10, y: 50) && corners[.bottomRight] == CGPoint(x: 50, y: 20))
    #expect(corners.count == 4)
    // 拖左上角：右下角不动；拖过头翻过去；⇧ 正方形
    let grown = box.resized(.topLeft, to: CGPoint(x: 0, y: 60), constrained: false)
    #expect(
      grown.id == box.id && grown.shape == .rectangle(CGRect(x: 0, y: 20, width: 50, height: 40)))
    #expect(
      box.resized(.topLeft, to: CGPoint(x: 60, y: 10), constrained: false).shape
        == .rectangle(CGRect(x: 50, y: 10, width: 10, height: 10)))
    #expect(
      box.resized(.bottomRight, to: CGPoint(x: 70, y: 40), constrained: true).shape
        == .rectangle(CGRect(x: 10, y: -10, width: 60, height: 60)))
    #expect(box.resized(.start, to: .zero, constrained: false) == box)
    // 线类两端：另一端不动，⇧ 吸 45°；箭头还有弧线中点的弯曲手柄（直的在弦中点），直线、荧光笔没有
    let arrow = Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 100, y: 0)))
    #expect(arrow.handles.map(\.0) == [.start, .end, .bend])
    #expect(arrow.handles.map(\.1) == [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 0)])
    #expect(Annotation(shape: .line(from: .zero, to: CGPoint(x: 100, y: 0))).handles.count == 2)
    #expect(
      arrow.resized(.start, to: CGPoint(x: 10, y: 10), constrained: false).shape
        == .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 0)))
    guard
      case .arrow(let from, let to, _) = arrow.resized(
        .end, to: CGPoint(x: 80, y: 70), constrained: true
      ).shape
    else { return #expect(Bool(false)) }
    #expect(from == .zero && abs(to.x - to.y) < 0.001)
    #expect(box.resized(.bend, to: .zero, constrained: false) == box)
    // 文字、序号、画笔只能拖动
    #expect(Annotation(shape: .text("字", origin: .zero)).handles.isEmpty)
    #expect(Annotation(shape: .counter(1, center: .zero)).handles.isEmpty)
    #expect(Annotation(shape: .pen([.zero, CGPoint(x: 9, y: 9)])).handles.isEmpty)
  }

  // MARK: 弯箭头

  private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 1e-9 }

  @Test func arrowBendFollowsTheMidpointHandle() {
    let (from, to) = (CGPoint.zero, CGPoint(x: 100, y: 0))
    // 弯曲手柄拖到 (50, 25)：弧线中点就在那儿，二次贝塞尔的控制点 = 2 · 中点 − 弦中点
    let bend = Annotation.arrowBend(
      from: from, to: to, through: CGPoint(x: 50, y: 25), constrained: false)
    #expect(bend == CGVector(dx: 0, dy: 0.25))
    #expect(Annotation.arrowMidpoint(from: from, to: to, bend: bend) == CGPoint(x: 50, y: 25))
    #expect(Annotation.arrowControl(from: from, to: to, bend: bend) == CGPoint(x: 50, y: 50))
    // 斜的弦、偏向一端地拖：中点照样落在手柄上
    let (a, b) = (CGPoint(x: 10, y: 20), CGPoint(x: 70, y: 100))
    let skewed = Annotation.arrowBend(
      from: a, to: b, through: CGPoint(x: 20, y: 80), constrained: false)
    #expect(skewed.dx != 0)
    #expect(near(Annotation.arrowMidpoint(from: a, to: b, bend: skewed), CGPoint(x: 20, y: 80)))
    // ⇧：只留垂直弦的那份，弯成对称的弧
    #expect(
      Annotation.arrowBend(from: from, to: to, through: CGPoint(x: 80, y: -50), constrained: true)
        == CGVector(dx: 0, dy: -0.5))
    // 离弦不到 4 点吸回直的（弦的延长线上也是）；弦长为 0 是直的
    for point in [CGPoint(x: 70, y: 3.9), CGPoint(x: 70, y: -3.9), CGPoint(x: 160, y: 0)] {
      #expect(
        Annotation.arrowBend(from: from, to: to, through: point, constrained: false) == .zero)
    }
    #expect(
      Annotation.arrowBend(from: from, to: to, through: CGPoint(x: 50, y: 4), constrained: false)
        != .zero)
    #expect(
      Annotation.arrowBend(from: from, to: from, through: CGPoint(x: 5, y: 50), constrained: false)
        == .zero)
    // 拖弯曲手柄：两端不动，弧线中点跟到手柄上；原来的箭头默认是直的
    let arrow = Annotation(shape: .arrow(from: from, to: to))
    #expect(arrow.shape == .arrow(from: from, to: to, bend: .zero))
    let bent = arrow.resized(.bend, to: CGPoint(x: 30, y: -40), constrained: false)
    #expect(bent.id == arrow.id)
    guard case .arrow(let start, let end, let dragged) = bent.shape else {
      return #expect(Bool(false))
    }
    #expect(start == from && end == to)
    #expect(
      near(Annotation.arrowMidpoint(from: from, to: to, bend: dragged), CGPoint(x: 30, y: -40)))
    #expect(bent.handles.last.map { $0.0 == .bend && near($0.1, CGPoint(x: 30, y: -40)) } == true)
    // 弦短于 32 的短箭头不给弯曲手柄；只看弦：弧线中点被拖到离尖端不到 16（弦 40、中点在 ¾ 处离弦 4）也还在，
    // 拖着它的时候不会从光标下消失
    #expect(Annotation(shape: .arrow(from: from, to: CGPoint(x: 30, y: 0))).handles.count == 2)
    #expect(Annotation(shape: .arrow(from: from, to: CGPoint(x: 32, y: 0))).handles.count == 3)
    let short = Annotation(
      shape: .arrow(from: from, to: CGPoint(x: 40, y: 0), bend: CGVector(dx: 0.25, dy: 0.1)))
    let grip = short.handles.first { $0.0 == .bend }?.1
    #expect(grip.map { near($0, CGPoint(x: 30, y: 4)) && hypot(40 - $0.x, $0.y) < 16 } == true)
  }

  @Test func bendHandleStopsAtAQuarterOfTheChord() {
    // 手柄沿弦拖过尖端 / 尾端：弧线中点停在弦的 ¾ / ¼ 处（离弦的那份照旧跟手），控制点落在那一端的垂线上，弧线在弦上的
    // 投影从头到尾单调、不出两端（以前拖过尖端弧线拐过去再折回来，杆叠成两层、箭头朝反方向）
    let (from, to) = (CGPoint(x: 40, y: 150), CGPoint(x: 200, y: 150))
    for (handle, along) in [(CGPoint(x: 330, y: 156), 0.25), (CGPoint(x: -90, y: 144), -0.25)] {
      let bend = Annotation.arrowBend(from: from, to: to, through: handle, constrained: false)
      #expect(bend.dx == along && abs(bend.dy - (handle.y - 150) / 160) < 1e-12)
      let control = Annotation.arrowControl(from: from, to: to, bend: bend)
      #expect(abs(control.x - (along > 0 ? to.x : from.x)) < 1e-9)
      let xs = (0...1000).map { step -> CGFloat in
        let t = CGFloat(step) / 1000
        return (1 - t) * (1 - t) * from.x + 2 * t * (1 - t) * control.x + t * t * to.x
      }
      #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
      #expect(xs.min()! >= from.x - 1e-9 && xs.max()! <= to.x + 1e-9)
    }
  }

  @Test func curvedArrowHeadMeetsTheShaftWithoutAKink() throws {
    // 手柄拖到弦的 ¾ 处、离弦 12：弧线贴着尖端拐个钩，底边中点到尖端的弦和杆在颈部差 20° 多。箭头底边垂直于杆（颈部不折），
    // 尖端还在终点上
    let (from, to) = (CGPoint.zero, CGPoint(x: 160, y: 0))
    let bend = Annotation.arrowBend(
      from: from, to: to, through: CGPoint(x: 120, y: 12), constrained: false)
    #expect(bend.dx == 0.25)
    /// 两个方向的夹角（度）
    func angle(_ a: CGVector, _ b: CGVector) -> CGFloat {
      abs(atan2(a.dx * b.dy - a.dy * b.dx, a.dx * b.dx + a.dy * b.dy)) * 180 / .pi
    }
    /// 左右一对偏移点（左减右）转回前进方向
    func heading(_ left: CGPoint, _ right: CGPoint) -> CGVector {
      CGVector(dx: left.y - right.y, dy: right.x - left.x)
    }
    for width: CGFloat in [4, 6] {
      let path = try #require(Annotation.arrowPath(from: from, to: to, width: width, bend: bend))
      var points: [CGPoint] = []
      path.applyWithBlock { element in
        if element.pointee.type != .closeSubpath { points.append(element.pointee.points[0]) }
      }
      // 轮廓：左侧杆 … 颈、翼、尖端、翼、颈 … 右侧杆
      let tip = try #require(points.firstIndex(of: to))
      let shaft = heading(points[tip - 3], points[tip + 3])  // 杆最后一个采样点的走向
      let across = heading(points[tip - 1], points[tip + 1])  // 箭头底边的法向
      let neck = CGPoint(
        x: (points[tip - 2].x + points[tip + 2].x) / 2,
        y: (points[tip - 2].y + points[tip + 2].y) / 2)
      #expect(angle(CGVector(dx: to.x - neck.x, dy: to.y - neck.y), shaft) > 15)
      #expect(angle(across, shaft) < 3)
    }
  }

  @Test func curvedArrowIsAlwaysDrawnInsideItsBounds() throws {
    // 弯过的粗箭头被拖短（弦 10、弧线鼓出 18）：整条弧都离尖端不到一个头长，箭头缩短照样沿弧线画，不退回画直的，
    // 和外框、点中对得上
    let degenerate = Annotation(
      shape: .arrow(
        from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 100), bend: CGVector(dx: 0, dy: 1.8)),
      style: .init(weight: .large))
    let path = try #require(
      Annotation.arrowPath(
        from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 100), width: 6,
        bend: CGVector(dx: 0, dy: 1.8)))
    #expect(path.boundingBoxOfPath.maxY > 112)  // 直的短箭头只到 y ≈ 105
    #expect(degenerate.contains(CGPoint(x: 105, y: 118)))
    #expect(path.contains(CGPoint(x: 104, y: 115)))
    #expect(degenerate.handles.count == 2)  // 弦太短，不给弯曲手柄
    // 各种弯法、粗细：画出来的都在外框里（点中先按外框排除，不能排掉画出来的部分）
    for weight in Annotation.Weight.allCases {
      for length: CGFloat in [10, 32, 80, 400] {
        for bend in [
          CGVector(dx: 0, dy: 0.03), CGVector(dx: 0.25, dy: 0.05), CGVector(dx: -0.25, dy: -0.2),
          CGVector(dx: 0.1, dy: 0.6), CGVector(dx: 0.25, dy: 1.5), CGVector(dx: 0, dy: -3),
        ] {
          let (from, to) = (
            CGPoint(x: 20, y: 30), CGPoint(x: 20 + length * 0.6, y: 30 + length * 0.8)
          )
          let arrow = Annotation(
            shape: .arrow(from: from, to: to, bend: bend), style: .init(weight: weight))
          let drawn = try #require(
            Annotation.arrowPath(from: from, to: to, width: weight.lineWidth, bend: bend))
          #expect(arrow.bounds.insetBy(dx: -1e-6, dy: -1e-6).contains(drawn.boundingBoxOfPath))
        }
      }
    }
  }

  @Test func hitTestingSkipsArrowsFarFromThePointer() {
    // 每次鼠标移动都要问一遍所有标注：光标离弯箭头很远时先按外框排除，不逐段量距离、不建轮廓（没排除时 Debug 下一次
    // 几百微秒，2000 次要一秒上下）
    let arrow = Annotation(
      shape: .arrow(
        from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1500, y: 900),
        bend: CGVector(dx: 0.1, dy: 0.4)),
      style: .init(weight: .large))
    let start = ContinuousClock.now
    let hits = (0..<2000).filter { arrow.contains(CGPoint(x: 3000 + $0, y: 50)) }
    #expect(ContinuousClock.now - start < .milliseconds(250))
    #expect(hits.isEmpty)
  }

  @Test func arrowEndsKeepTheBendProportional() throws {
    // 弦从 (0,0)→(100,0) 拖成 (0,0)→(0,200)：放大 2 倍、逆时针转 90°，弧线中点 (50, 25) 跟着变到 (−50, 100)
    let arrow = Annotation(
      shape: .arrow(from: .zero, to: CGPoint(x: 100, y: 0), bend: CGVector(dx: 0, dy: 0.25)))
    let resized = arrow.resized(.end, to: CGPoint(x: 0, y: 200), constrained: false)
    guard case .arrow(let from, let to, let bend) = resized.shape else {
      return #expect(Bool(false))
    }
    #expect(from == .zero && to == CGPoint(x: 0, y: 200) && bend == CGVector(dx: 0, dy: 0.25))
    let mid = try #require(resized.handles.first { $0.0 == .bend }?.1)
    #expect(near(mid, CGPoint(x: -50, y: 100)))
    // 拖起点同样；挪动、复制、⌘D 偏移都带着弯度
    guard
      case .arrow(_, _, let moved) = arrow.resized(
        .start, to: CGPoint(x: -30, y: 7), constrained: true
      )
      .shape
    else { return #expect(Bool(false)) }
    #expect(moved == CGVector(dx: 0, dy: 0.25))
    #expect(
      arrow.offset(by: CGSize(width: 5, height: -3)).shape
        == .arrow(
          from: CGPoint(x: 5, y: -3), to: CGPoint(x: 105, y: -3), bend: CGVector(dx: 0, dy: 0.25)))
    #expect(
      arrow.duplicated().shape
        == .arrow(
          from: CGPoint(x: 12, y: -12), to: CGPoint(x: 112, y: -12),
          bend: CGVector(dx: 0, dy: 0.25)))
  }

  @Test func curvedArrowBoundsAndHitTestingFollowTheCurve() {
    // 弦 (0,0)→(100,0)，弧线顶点 (50, 25)：外框、点中都认鼓出来的那截，弦上（离弧线 25 点）点不中
    let arrow = Annotation(
      shape: .arrow(from: .zero, to: CGPoint(x: 100, y: 0), bend: CGVector(dx: 0, dy: 0.25)))
    let straight = Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 100, y: 0)))
    let pad = straight.bounds.maxY  // 直箭头的外框 = 两端的框外扩 max(箭头半宽, 线宽)
    #expect(abs(arrow.bounds.maxY - (25 + pad)) < 1e-9)
    #expect(arrow.bounds.minX == straight.bounds.minX && arrow.bounds.minY == straight.bounds.minY)
    #expect(arrow.drawBounds.contains(arrow.bounds))
    // 往下鼓、偏向一端的也一样：y 的极值在 t = 0.5（控制点 y 的一半），控制点偏到弦的右端外面、弧线鼓出右端
    // （x 的极值在 t ≈ 0.92，逐点找最右）
    let skewed = Annotation(
      shape: .arrow(from: .zero, to: CGPoint(x: 100, y: 0), bend: CGVector(dx: 0.3, dy: -0.4)))
    let control = Annotation.arrowControl(
      from: .zero, to: CGPoint(x: 100, y: 0), bend: CGVector(dx: 0.3, dy: -0.4))
    #expect(abs(skewed.bounds.minY - (control.y / 2 - pad)) < 1e-9)
    var rightmost: CGFloat = 0
    for step in 0...1000 {
      let t = CGFloat(step) / 1000
      rightmost = max(rightmost, 2 * t * (1 - t) * control.x + t * t * 100)
    }
    #expect(rightmost > 100 && abs(skewed.bounds.maxX - (rightmost + pad)) < 0.01)
    // 点中：弧线顶点、离顶点 5 点（半宽 2 + 容差 4）算，8 点、弦中点不算
    #expect(arrow.contains(CGPoint(x: 50, y: 25)) && arrow.contains(CGPoint(x: 50, y: 30)))
    #expect(!arrow.contains(CGPoint(x: 50, y: 33)) && !arrow.contains(CGPoint(x: 50, y: 0)))
    #expect(Annotation.topmost(in: [arrow], at: CGPoint(x: 50, y: 24))?.id == arrow.id)
    #expect(Annotation.topmost(in: [arrow], at: CGPoint(x: 50, y: 2)) == nil)
  }

  @Test func straightArrowGeometryIsUnchanged() throws {
    // 直箭头还是原来那个七边形（尾部半宽 0.15 × 线宽、颈 0.6 × 线宽、头长 4 × 线宽、半角 28°），一个点都不变
    for (from, to, width) in [
      (CGPoint(x: 20, y: 20), CGPoint(x: 180, y: 150), CGFloat(4)),
      (CGPoint(x: 170.3, y: 30.7), CGPoint(x: 40.2, y: 60.9), 6),
      (CGPoint(x: 100, y: 100), CGPoint(x: 108, y: 104), 2),
    ] {
      let length = hypot(to.x - from.x, to.y - from.y)
      let head = min(length, width * 4)
      let wing = head * tan(28 * .pi / 180)
      let unit = CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
      let base = CGPoint(x: to.x - unit.x * head, y: to.y - unit.y * head)
      let beside = { (point: CGPoint, side: CGFloat) in
        CGPoint(x: point.x - unit.y * side, y: point.y + unit.x * side)
      }
      let (tail, neck) = (width * 0.15, min(width * 0.6, wing))
      let reference = CGMutablePath()
      reference.addLines(between: [
        beside(from, tail), beside(base, neck), beside(base, wing), to, beside(base, -wing),
        beside(base, -neck), beside(from, -tail),
      ])
      reference.closeSubpath()
      #expect(Annotation.arrowPath(from: from, to: to, width: width) == reference)
      #expect(Annotation.arrowPath(from: from, to: to, width: width, bend: .zero) == reference)
    }
  }

  @Test func curvedArrowDrawsAlongTheCurve() throws {
    let white = try Self.solid(gray: 1)
    let (from, to) = (CGPoint(x: 10, y: 20), CGPoint(x: 90, y: 20))
    // 几乎直的弯箭头（弯度远小于一个像素）和直箭头画出来一样：弯的轮廓在直的时候退化成同一个七边形，接缝处没有折角、错位
    let straight = try draw([Annotation(shape: .arrow(from: from, to: to))], over: white)
    let almost = try draw(
      [Annotation(shape: .arrow(from: from, to: to, bend: CGVector(dx: 0, dy: 1e-7)))], over: white)
    #expect(zip(straight.data, almost.data).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    // 手柄拖到 (50, 60)：弧线顶点上是红色的，弦中点上是白底；箭头沿弧线末端的走向（朝右下 63°）
    let bend = Annotation.arrowBend(
      from: from, to: to, through: CGPoint(x: 50, y: 60), constrained: false)
    let curved = try draw([Annotation(shape: .arrow(from: from, to: to, bend: bend))], over: white)
    #expect(Array(curved(50, 59)[0..<3]) == [255, 59, 48])
    #expect(curved(50, 20)[1] > 240)
    #expect(Array(curved(87, 25)[0..<3]) == [255, 59, 48])  // 尖端往回沿切线 6 点：箭头里
    #expect(curved(83, 20)[1] > 150)  // 顺着弦往回 6 点：直箭头的箭头在这里，弯的不在
  }

  @Test func duplicateAndCounterNumbers() {
    let counter = Annotation(shape: .counter(3, center: CGPoint(x: 20, y: 20)))
    let copy = counter.duplicated()
    #expect(copy.id != counter.id && copy.style == counter.style)
    #expect(copy.shape == .counter(3, center: CGPoint(x: 32, y: 8)))  // 往右下偏 12（原点左下）
    #expect(counter.duplicated(offset: .zero).shape == counter.shape)
    #expect(Annotation.nextCounter(in: []) == 1)
    #expect(
      Annotation.nextCounter(in: [
        counter, Annotation(shape: .counter(1, center: .zero)),
        Annotation(shape: .rectangle(.zero)),
      ]) == 4)
  }

  @Test func stylesAreRememberedPerTool() throws {
    let suite = "AnnotationToolTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let style = Annotation.Style(color: .blue, weight: .large, option: 2)
    let decoded = try JSONDecoder().decode(
      Annotation.Style.self, from: JSONEncoder().encode(style))
    #expect(decoded == style)
    // 第一次：红色中号、荧光笔黄色
    #expect(Annotation.Style.remembered(for: .arrow, in: defaults) == Annotation.Style())
    #expect(Annotation.Style().color == .red && Annotation.Style().weight == .medium)
    #expect(Annotation.Style.remembered(for: .highlighter, in: defaults).color == .yellow)
    Annotation.Style.remember(style, for: .text, in: defaults)
    Annotation.Style.remember(Annotation.Style(color: .green), for: .arrow, in: defaults)
    #expect(Annotation.Style.remembered(for: .text, in: defaults) == style)
    #expect(Annotation.Style.remembered(for: .arrow, in: defaults).color == .green)
    #expect(Annotation.Style.remembered(for: .rectangle, in: defaults) == Annotation.Style())
    // 存的是以 rawValue 字符串为键的 JSON 字典
    let data = try #require(defaults.data(forKey: Prefs.screenshotToolStyles))
    let saved = try JSONDecoder().decode([String: Annotation.Style].self, from: data)
    #expect(Set(saved.keys) == ["3", "7"])
  }

  // MARK: 绘制

  @Test func spotlightDimsOutsideItsHoleOnly() throws {
    let white = try Self.solid(gray: 1)
    let spot = Annotation(shape: .spotlight(CGRect(x: 20, y: 20, width: 40, height: 40)))
    let pixel = try draw([spot], over: white)
    #expect(pixel(40, 40)[0] == 255)  // 洞里不动
    #expect((120...135).contains(pixel(5, 5)[0]))  // 洞外压暗 0.5
    #expect((120...135).contains(pixel(90, 90)[0]))
    // 两个重叠的洞：重叠处仍是亮的（偶奇规则不能把它又压暗）；压暗程度取最后一个的档
    var deep = Annotation(shape: .spotlight(CGRect(x: 40, y: 40, width: 40, height: 40)))
    deep.style.weight = .large
    let both = try draw([spot, deep], over: white)
    #expect(both(50, 50)[0] == 255 && both(30, 30)[0] == 255 && both(70, 70)[0] == 255)
    #expect((80...95).contains(both(5, 5)[0]))  // 1 - 0.65
  }

  @Test func movingASpotlightOnlyRedrawsItsHoles() throws {
    // 标注层的局部重画：压暗的档没变时只重画新旧两个洞，结果和整块重画一样
    let white = try Self.solid(gray: 1)
    let old = Annotation(shape: .spotlight(CGRect(x: 10, y: 10, width: 30, height: 30)))
    var moved = old
    moved.shape = .spotlight(CGRect(x: 50, y: 40, width: 30, height: 30))
    #expect(Annotation.dimLevel(of: [old]) == Annotation.dimLevel(of: [moved]))
    #expect(Annotation.dimLevel(of: []) == nil)
    let context = try Self.context()
    Annotation.drawAll([old], in: context, image: white, viewSize: view, shadowScale: 1)
    for rect in [old.drawBounds, moved.drawBounds] {
      context.saveGState()
      context.clip(to: rect)
      context.clear(rect)
      Annotation.drawAll(
        [moved], in: context, image: white, viewSize: view, shadowScale: 1, dirty: rect)
      context.restoreGState()
    }
    let partial = try Pixels(try #require(context.makeImage()))
    #expect(partial.data == (try draw([moved], over: white, transparent: true)).data)
  }

  @Test func growingAPenOnlyRedrawsItsTail() throws {
    // 画笔边画边累点：只重画 penGrowth 给的那一截，结果和整条重画一样；不是接着画的（挪动、改样式、变短）给 nil
    let white = try Self.solid(gray: 1)
    let points = [
      CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 70), CGPoint(x: 50, y: 20), CGPoint(x: 70, y: 60),
    ]
    let old = Annotation(shape: .pen(points))
    var grown = old
    grown.shape = .pen(points + [CGPoint(x: 80, y: 50)])
    let tail = try #require(grown.penGrowth(from: old))
    #expect(tail.minX > grown.drawBounds.minX + 30)
    let context = try Self.context()
    Annotation.drawAll([old], in: context, image: white, viewSize: view, shadowScale: 1)
    context.saveGState()
    context.clip(to: tail)
    context.clear(tail)
    Annotation.drawAll(
      [grown], in: context, image: white, viewSize: view, shadowScale: 1, dirty: tail)
    context.restoreGState()
    let partial = try Pixels(try #require(context.makeImage()))
    // 带阴影的整条重画和局部重画之间有 1/255 的舍入差（阴影按不同大小的缓冲模糊），看不出来
    let full = try draw([grown], over: white, transparent: true)
    #expect(zip(partial.data, full.data).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    var restyled = grown
    restyled.style.color = .blue
    #expect(restyled.penGrowth(from: old) == nil)
    #expect(grown.offset(by: CGSize(width: 1, height: 0)).penGrowth(from: old) == nil)
    #expect(old.penGrowth(from: grown) == nil)
  }

  @Test func spotlightDimsOnlyInsideTheSelection() throws {
    // 屏幕上压暗只在选区里（选区外有遮罩的蒙层）；洞伸出选区的那截不能反过来把选区外压暗
    let white = try Self.solid(gray: 1)
    let spot = Annotation(shape: .spotlight(CGRect(x: 40, y: 40, width: 50, height: 50)))
    let selection = CGRect(x: 10, y: 10, width: 60, height: 60)
    let render = { (selection: CGRect) throws -> CGContext in
      let context = try Self.context()
      Annotation.drawAll(
        [spot], in: context, image: white, viewSize: self.view, shadowScale: 1,
        spotlightBounds: selection)
      return context
    }
    let pixel = try Pixels(try #require(try render(selection).makeImage()))
    #expect(pixel(20, 20)[3] > 120)  // 选区里、洞外：压暗
    #expect(pixel(50, 50)[3] == 0 && pixel(5, 5)[3] == 0 && pixel(80, 80)[3] == 0)
    // 平移选区：只重画 dimChange 给的几条，和整块重画一样
    let moved = selection.offsetBy(dx: 7, dy: -4)
    let strips = Annotation.dimChange(from: selection, to: moved)
    #expect(strips.count == 4 && strips.allSatisfy { min($0.width, $0.height) <= 7 })
    let context = try render(selection)
    for strip in strips.map({ $0.insetBy(dx: -2, dy: -2) }) {
      context.saveGState()
      context.clip(to: strip)
      context.clear(strip)
      Annotation.drawAll(
        [spot], in: context, image: white, viewSize: view, shadowScale: 1, dirty: strip,
        spotlightBounds: moved)
      context.restoreGState()
    }
    let partial = try Pixels(try #require(context.makeImage()))
    #expect(partial.data == (try Pixels(try #require(try render(moved).makeImage()))).data)
    #expect(Annotation.dimChange(from: selection, to: selection).isEmpty)
  }

  @Test func onScreenSpotlightLayerMatchesExport() throws {
    // 屏幕上：冻结帧 → 标注层下面的压暗图层（spotlightDim 的偶奇路径）→ 标注层（只给垫底的马赛克、荧光笔补同样的压暗）；
    // 导出：冻结帧上一次 drawAll。叠出来要一样（拖选区时只换压暗图层的路径，不重画标注层）
    let base = try ScreenshotTests.image(size: 100) { context in
      for index in 0..<10 {
        context.setFillColor(
          CGColor(
            red: CGFloat(index) / 10, green: 1 - CGFloat(index) / 10, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: index * 10, width: 100, height: 10))
      }
    }
    let selection = CGRect(x: 5, y: 5, width: 90, height: 90)
    let annotations = [
      Annotation(shape: .mosaic(CGRect(x: 10, y: 10, width: 40, height: 30))),
      Annotation(
        shape: .highlighter(from: CGPoint(x: 10, y: 75), to: CGPoint(x: 90, y: 75)),
        style: .init(color: .yellow)),
      Annotation(shape: .rectangle(CGRect(x: 58, y: 15, width: 30, height: 30))),
      Annotation(shape: .spotlight(CGRect(x: 30, y: 30, width: 40, height: 30))),
    ]
    let export = try Self.context()
    export.draw(base, in: CGRect(origin: .zero, size: view))
    Annotation.drawAll(
      annotations, in: export, image: base, viewSize: view, shadowScale: 1,
      spotlightBounds: selection)
    let exported = try Pixels(try #require(export.makeImage()))

    let screen = try Self.context()
    screen.draw(base, in: CGRect(origin: .zero, size: view))
    let dim = try #require(
      Annotation.spotlightDim(annotations.filter { $0.tool == .spotlight }, bounds: selection))
    screen.setFillColor(CGColor(gray: 0, alpha: dim.alpha))
    screen.addPath(dim.path)
    screen.fillPath(using: .evenOdd)
    let layer = try Self.context()
    Annotation.drawAll(
      annotations, in: layer, image: base, viewSize: view, shadowScale: 1,
      spotlightBounds: selection, dimsUnderlaysOnly: true)
    screen.draw(try #require(layer.makeImage()), in: CGRect(origin: .zero, size: view))
    let onScreen = try Pixels(try #require(screen.makeImage()))
    // 马赛克里（洞外、洞里）、荧光笔上、矩形边上、洞里、洞外、选区外
    for (x, y) in [(15, 15), (40, 35), (20, 75), (60, 75), (58, 30), (50, 45), (80, 55), (2, 2)] {
      let delta = zip(onScreen(x, y), exported(x, y)).map { abs(Int($0) - Int($1)) }.max() ?? 0
      #expect(delta <= 2, "(\(x), \(y))")
    }
    // 整张：只有垫底标注的抗锯齿边上差一点
    let deltas = zip(onScreen.data, exported.data).map { abs(Int($0) - Int($1)) }
    #expect(deltas.filter { $0 > 2 }.count < 200, "\(deltas.max() ?? 0)")
  }

  @Test func bandedDrawingMatchesWholeDraw() throws {
    // 大的线条切成不重叠的细条各画一遍（Annotation.bands），和整块画一样：矩形、椭圆逐像素；斜线 CG 按裁剪区大小栅格化本来就
    // 差零点几像素（局部重画也一样），只比墨迹总量——切条漏了一截的话总量会少一大块
    let size = CGSize(width: 1200, height: 800)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let bitmap = {
      CGContext(
        data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 1200 * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    let base = try #require(bitmap()?.makeImage())
    let cases: [(Annotation, exact: Bool)] = [
      (Annotation(shape: .rectangle(CGRect(x: 100.3, y: 100.7, width: 900, height: 550))), true),
      (
        Annotation(
          shape: .rectangle(CGRect(x: 100, y: 100, width: 900, height: 550)),
          style: .init(color: .blue, weight: .large, option: 1)), true
      ),
      (Annotation(shape: .ellipse(CGRect(x: 100, y: 100, width: 900, height: 550))), true),
      (
        Annotation(
          shape: .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1100, y: 700)),
          style: .init(weight: .large)), false
      ),
      (
        // 弯箭头鼓出两端围成的框：切条要沿着弧线切，漏了鼓出来的那截墨迹总量会少一大块
        Annotation(
          shape: .arrow(
            from: CGPoint(x: 100, y: 150), to: CGPoint(x: 1100, y: 250),
            bend: CGVector(dx: 0.1, dy: 0.4)),
          style: .init(weight: .large)), false
      ),
      (
        Annotation(shape: .line(from: CGPoint(x: 100, y: 700), to: CGPoint(x: 1100, y: 100))), false
      ),
      (
        Annotation(
          shape: .highlighter(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1100, y: 700)),
          style: .init(color: .yellow)), false
      ),
    ]
    let saved = Annotation.bandingArea
    defer { Annotation.bandingArea = saved }
    for (annotation, exact) in cases {
      var renders: [CGContext] = []
      for area in [CGFloat.infinity, 250_000] {
        Annotation.bandingArea = area
        let context = try #require(bitmap())
        Annotation.drawAll(
          [annotation], in: context, image: base, viewSize: size, shadowScale: 1)
        renders.append(context)
      }
      let count = 1200 * 800 * 4
      let whole = try #require(renders[0].data).bindMemory(to: UInt8.self, capacity: count)
      let banded = try #require(renders[1].data).bindMemory(to: UInt8.self, capacity: count)
      var (maxDelta, wholeMass, bandedMass) = (0, 0, 0)
      for index in 0..<count {
        let (a, b) = (Int(whole[index]), Int(banded[index]))
        maxDelta = max(maxDelta, abs(a - b))
        wholeMass += a
        bandedMass += b
      }
      if exact { #expect(maxDelta <= 1, "\(annotation.tool)") }
      #expect(abs(wholeMass - bandedMass) * 200 < wholeMass, "\(annotation.tool)")
    }
  }

  @Test func hitTestingFollowsPaintOrder() {
    // 后加的马赛克画在矩形下面：点矩形的边拿到矩形；序号压在后画的矩形上面：点序号拿到序号
    let rectangle = Annotation(shape: .rectangle(CGRect(x: 50, y: 10, width: 40, height: 80)))
    let mosaic = Annotation(shape: .mosaic(CGRect(x: 0, y: 0, width: 100, height: 100)))
    let counter = Annotation(shape: .counter(1, center: CGPoint(x: 50, y: 50)))
    #expect(
      Annotation.topmost(in: [rectangle, mosaic], at: CGPoint(x: 50, y: 30))?.id == rectangle.id)
    #expect(
      Annotation.topmost(in: [rectangle, mosaic], at: CGPoint(x: 20, y: 30))?.id == mosaic.id)
    #expect(
      Annotation.topmost(in: [counter, rectangle, mosaic], at: CGPoint(x: 50, y: 50))?.id
        == counter.id)
    // 同一层后画的在上
    let later = Annotation(shape: .rectangle(CGRect(x: 50, y: 20, width: 10, height: 10)))
    #expect(Annotation.topmost(in: [rectangle, later], at: CGPoint(x: 50, y: 25))?.id == later.id)
    #expect(Annotation.topmost(in: [rectangle], at: CGPoint(x: 70, y: 50)) == nil)
  }

  @Test func countersAreDrawnOnTop() throws {
    let white = try Self.solid(gray: 1)
    let counter = Annotation(
      shape: .counter(1, center: CGPoint(x: 50, y: 50)),
      style: .init(color: .red, weight: .large))
    // 后画的黑色粗矩形左边线穿过序号圆
    let rectangle = Annotation(
      shape: .rectangle(CGRect(x: 50, y: 10, width: 40, height: 80)),
      style: .init(color: .black, weight: .large))
    let pixel = try draw([counter, rectangle], over: white)
    #expect(Array(pixel(50, 62)[0..<3]) == [255, 59, 48])  // 圆里、数字外：还是序号的红
    #expect(pixel(50, 20)[0] < 30)  // 圆外是矩形的黑边
  }

  @Test func blurMosaicDiffersFromPixelMosaic() async throws {
    let image = try ScreenshotTests.render(["Secret password 12345"])
    let viewSize = CGSize(width: 600, height: 60)
    let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var blur = Annotation.Style()
    blur.option = 1
    let pixelated = try #require(
      Annotation.render(
        [Annotation(shape: .mosaic(CGRect(origin: .zero, size: viewSize)))], over: image,
        pixelRect: full, viewSize: viewSize))
    let blurred = try #require(
      Annotation.render(
        [Annotation(shape: .mosaic(CGRect(origin: .zero, size: viewSize)), style: blur)],
        over: image, pixelRect: full, viewSize: viewSize))
    let pixelData = try #require(pixelated.dataProvider?.data as Data?)
    let blurData = try #require(blurred.dataProvider?.data as Data?)
    #expect(pixelData != blurData)
    // 模糊也得认不出原来的字（打码的本意）
    #expect(await OCR.recognizeText(in: blurred)?.contains("Secret") == false)
  }

  @Test func highlighterLooksTheSameOnScreenAndInExport() throws {
    // 左半黑、右半白；黄色荧光笔横穿。导出直接画在底图上，屏幕上画在透明的标注层、再叠到冻结帧上
    let base = try ScreenshotTests.image(size: 100) { context in
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
    }
    let marker = Annotation(
      shape: .highlighter(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 90, y: 50)),
      style: .init(color: .yellow))
    let exported = try draw([marker], over: base)
    #expect(exported(25, 50)[0] < 10)  // 黑字上还是黑的（正片叠底）
    #expect(exported(75, 50)[2] < 180 && exported(75, 50)[0] > 240)  // 白底变黄
    let layer = try draw([marker], over: base, transparent: true)
    let onScreen = try Self.composite(layer.image, over: base)
    for x in [25, 75] {
      let delta = zip(onScreen(x, 50), exported(x, 50)).map { abs(Int($0) - Int($1)) }.max() ?? 0
      #expect(delta <= 2, "x = \(x)")
    }
  }

  @Test func textOptionsDrawOutlineAndPlate() throws {
    let white = try Self.solid(gray: 1)
    let origin = CGPoint(x: 20, y: 60)
    let frame = Annotation.textFrame("字", origin: origin, weight: .medium)
    var plate = Annotation.Style(color: .blue)
    plate.option = 2
    let plated = try draw(
      [Annotation(shape: .text("字", origin: origin), style: plate)], over: white)
    // 色块在文字框左边留的 6 点里；无底的那里还是白的
    #expect(Array(plated(Int(frame.minX) - 5, Int(frame.midY))[0..<3]) == [0, 122, 255])
    let plain = try draw([Annotation(shape: .text("字", origin: origin))], over: white)
    #expect(plain(Int(frame.minX) - 5, Int(frame.midY))[2] > 240)
    #expect(
      Annotation(shape: .text("字", origin: origin), style: plate).bounds.contains(
        Annotation.textPlate(frame)))
  }

  // MARK: 工具

  /// 100×100 点、1x 的 sRGB 位图：先铺底图（transparent 时不铺，模拟屏幕上透明的标注层），再 drawAll。
  /// 返回按视图坐标（原点左下）取 RGBA 的函数，image 是画完的图
  private func draw(_ annotations: [Annotation], over base: CGImage, transparent: Bool = false)
    throws -> Pixels
  {
    let context = try Self.context()
    if !transparent { context.draw(base, in: CGRect(origin: .zero, size: view)) }
    Annotation.drawAll(annotations, in: context, image: base, viewSize: view, shadowScale: 1)
    return try Pixels(try #require(context.makeImage()))
  }

  struct Pixels {
    let image: CGImage
    let data: Data

    init(_ image: CGImage) throws {
      self.image = image
      data = try #require(image.dataProvider?.data as Data?)
    }

    func callAsFunction(_ x: Int, _ y: Int) -> [UInt8] {
      let offset = (image.height - 1 - y) * image.bytesPerRow + x * 4
      return Array(data[offset..<offset + 4])
    }
  }

  private static func context() throws -> CGContext {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(
      CGContext(
        data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  }

  private static func solid(gray: CGFloat) throws -> CGImage {
    try ScreenshotTests.image(size: 100) { context in
      context.setFillColor(CGColor(gray: gray, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    }
  }

  private static func composite(_ layer: CGImage, over base: CGImage) throws -> Pixels {
    let context = try context()
    context.draw(base, in: CGRect(x: 0, y: 0, width: 100, height: 100))
    context.draw(layer, in: CGRect(x: 0, y: 0, width: 100, height: 100))
    return try Pixels(try #require(context.makeImage()))
  }
}
