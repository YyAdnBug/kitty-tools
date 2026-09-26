// 截图 / 截图翻译单测：选区（点）→ 冻结帧像素矩形的换算（各种缩放、y 翻转、夹边）、窗口快照（Z 序、坐标翻转、过滤）、
// 手柄调整与平移、上次区域落到哪块屏、放大镜取色（sRGB、y 方向）、快速保存不覆盖，以及 Vision 识别多语种
// （锁住 §11 #21：写死一组语言、或给语言提示时，混排图里日文假名、韩文、俄文会丢）。

import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Testing

@testable import KittyTools

struct ScreenshotTests {
  private func pixels(_ rect: CGRect, view: CGSize, image: CGSize) -> CGRect {
    RegionSelector.pixelRect(rect, viewSize: view, imageSize: image)
  }

  @Test func pixelRectScalesAndFlips() {
    let view = CGSize(width: 1512, height: 982)
    // 2x：原点左下 → 左上，尺寸翻倍
    #expect(
      pixels(
        CGRect(x: 10, y: 20, width: 100, height: 50), view: view,
        image: CGSize(width: 3024, height: 1964))
        == CGRect(x: 20, y: 1824, width: 200, height: 100))
    // 1x
    #expect(
      pixels(CGRect(x: 0, y: 0, width: 10, height: 10), view: view, image: view)
        == CGRect(x: 0, y: 972, width: 10, height: 10))
    // 非整数缩放（外接屏 1.5x）：向外取整，不丢边上的像素
    #expect(
      pixels(
        CGRect(x: 1, y: 1, width: 3, height: 3), view: CGSize(width: 100, height: 100),
        image: CGSize(width: 150, height: 150))
        == CGRect(x: 1, y: 144, width: 5, height: 5))
  }

  @Test func pixelRectClampsToImage() {
    let size = CGSize(width: 100, height: 100)
    #expect(
      pixels(CGRect(x: 90, y: -5, width: 20, height: 20), view: size, image: size)
        == CGRect(x: 90, y: 85, width: 10, height: 15))
  }

  @Test func windowFramesKeepZOrder() {
    let own: pid_t = 42
    func window(
      _ rect: CGRect, layer: Int = 0, pid: Int32 = 7, id: Int = 1, alpha: Double = 1
    ) -> [String: Any] {
      [
        kCGWindowBounds as String: rect.dictionaryRepresentation, kCGWindowLayer as String: layer,
        kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id,
        kCGWindowAlpha as String: alpha,
      ]
    }
    let info = [
      window(CGRect(x: 100, y: 100, width: 200, height: 100)),  // 前面的小窗
      window(CGRect(x: 0, y: 0, width: 800, height: 600)),  // 后面的大窗
      window(CGRect(x: 0, y: 0, width: 1512, height: 24), layer: 25),  // 菜单栏图标层：不要
      window(CGRect(x: 0, y: 0, width: 300, height: 300), alpha: 0),  // 全透明：不要
      window(CGRect(x: 0, y: 0, width: 10, height: 300)),  // 太窄：不要
      window(CGRect(x: 0, y: 0, width: 300, height: 300), pid: own, id: 9),  // 自家浮层：不要
      window(CGRect(x: 500, y: 500, width: 100, height: 100), pid: own, id: 5),  // 钉图：要
      window(CGRect(x: 10, y: 10, width: 120, height: 200), layer: 101),  // 展开的菜单：要
    ]
    let frames = ScreenCapture.windowFrames(info, ownPID: own, keeping: [5], primaryHeight: 1000)
    // CG 原点在左上、y 向下 → AppKit 原点在左下
    #expect(
      frames == [
        CGRect(x: 100, y: 800, width: 200, height: 100),
        CGRect(x: 0, y: 400, width: 800, height: 600),
        CGRect(x: 500, y: 400, width: 100, height: 100),
        CGRect(x: 10, y: 790, width: 120, height: 200),
      ])
    // 命中按 Z 序：点在两个窗口里取前面的小窗（旧版按面积排会选中被挡住的，§11 #41）
    #expect(frames.first { $0.contains(CGPoint(x: 150, y: 850)) } == frames[0])
  }

  @Test func handlesResizeAndMove() {
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
    let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
    #expect(RegionSelector.handle(at: CGPoint(x: 302, y: 199), in: rect) == .topRight)
    #expect(RegionSelector.handle(at: CGPoint(x: 200, y: 100), in: rect) == .bottom)
    #expect(RegionSelector.handle(at: CGPoint(x: 200, y: 150), in: rect) == nil)
    // 整条边都能拖：离手柄远的边上、边外 8 点内都算；再远就不算
    #expect(RegionSelector.handle(at: CGPoint(x: 140, y: 200), in: rect) == .top)
    #expect(RegionSelector.handle(at: CGPoint(x: 140, y: 207), in: rect) == .top)
    #expect(RegionSelector.handle(at: CGPoint(x: 140, y: 209), in: rect) == nil)
    #expect(RegionSelector.handle(at: CGPoint(x: 96, y: 130), in: rect) == .left)
    // 边内的带可以收窄（小选区中间留给平移）
    #expect(RegionSelector.handle(at: CGPoint(x: 140, y: 195), in: rect, inner: 3) == nil)
    // 右边拖过左边：翻过去；只动这条边
    #expect(
      RegionSelector.resized(rect, .right, to: CGPoint(x: 50, y: 999), within: bounds)
        == CGRect(x: 50, y: 100, width: 50, height: 100))
    // 角：两条边一起动，点先夹进屏内
    #expect(
      RegionSelector.resized(rect, .topLeft, to: CGPoint(x: -20, y: 450), within: bounds)
        == CGRect(x: 0, y: 100, width: 300, height: 300))
    // 拖到和对边重合：至少 1 点
    #expect(
      RegionSelector.resized(rect, .top, to: CGPoint(x: 0, y: 100), within: bounds).height == 1)
    // 选区贴着屏幕上边，把下边拖到最上沿：补出的 1 点留在屏内（越界的选区裁不出图，↩ 会静默取消）
    let top = CGRect(x: 0, y: 300, width: 500, height: 100)
    #expect(
      RegionSelector.resized(top, .bottom, to: CGPoint(x: 0, y: 400), within: bounds)
        == CGRect(x: 0, y: 399, width: 500, height: 1))
    // 平移（方向键、拖动）整块留在屏内
    #expect(
      RegionSelector.moved(rect, by: CGSize(width: 1000, height: -1000), within: bounds)
        == CGRect(x: 300, y: 0, width: 200, height: 100))
  }

  @Test func lastRegionPlacement() {
    let screens = [
      CGRect(x: 0, y: 0, width: 1512, height: 982),
      CGRect(x: 1512, y: 0, width: 1920, height: 1080),
    ]
    // 大部分在外接屏：放到外接屏，夹掉越界的部分，换成屏内坐标
    let placed = RegionSelector.placement(
      of: CGRect(x: 1400, y: 100, width: 400, height: 200), in: screens)
    #expect(placed?.index == 1)
    #expect(placed?.rect == CGRect(x: 0, y: 100, width: 288, height: 200))
    // 外接屏拔掉后落在屏外
    #expect(
      RegionSelector.placement(of: CGRect(x: 5000, y: 0, width: 10, height: 10), in: screens) == nil
    )
  }

  @Test func magnifierSamplesSRGB() throws {
    // 上半红、下半蓝（sRGB）：按左上原点取像素，色值按 sRGB 原样读出；靠边时超出图的部分补黑、中心仍是该像素
    let image = try Self.image(size: 20) { context in
      context.setFillColor(
        CGColor(srgbRed: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
      context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
    }
    #expect(SelectionView.sample(image, x: 10, y: 15, size: 15)?.hex == "#3478F6")
    let corner = try #require(SelectionView.sample(image, x: 0, y: 2, size: 15))
    #expect(corner.hex == "#FF0000")
    #expect(corner.image.width == 15 && corner.image.height == 15)
    // 放大的图也是正的：顶上 5 行、左边 7 列在图外（黑），其余是红
    let pixels = try #require(corner.image.dataProvider?.data as Data?)
    let red = { (row: Int, column: Int) in pixels[row * corner.image.bytesPerRow + column * 4] }
    #expect(red(0, 10) == 0 && red(4, 10) == 0 && red(5, 10) == 255)
    #expect(red(10, 6) == 0 && red(10, 7) == 255)
  }

  @Test func quickSaveNamesNeverOverwrite() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = try #require(
      Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 4, hour: 8, minute: 5, second: 3)))
    let first = ScreenshotOutput.availableURL(in: directory, date: date)
    #expect(first.lastPathComponent == "截图 2026-09-04 08.05.03.png")
    try Data().write(to: first)
    // 同一秒再存一张：追加序号（旧版会覆盖前一张，§11 #46）
    #expect(
      ScreenshotOutput.availableURL(in: directory, date: date).lastPathComponent
        == "截图 2026-09-04 08.05.03 2.png")
  }

  @Test func annotationHitTesting() {
    let rectangle = Annotation(shape: .rectangle(CGRect(x: 100, y: 100, width: 200, height: 100)))
    #expect(rectangle.contains(CGPoint(x: 101, y: 150)))  // 左边线上
    #expect(!rectangle.contains(CGPoint(x: 200, y: 150)))  // 空心框里面点不中，免得挡住下面的标注
    #expect(!rectangle.contains(CGPoint(x: 90, y: 150)))
    let arrow = Annotation(shape: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100)))
    #expect(arrow.contains(CGPoint(x: 52, y: 48)))
    #expect(!arrow.contains(CGPoint(x: 60, y: 40)))
    let mosaic = Annotation(shape: .mosaic(CGRect(x: 0, y: 0, width: 50, height: 50)))
    #expect(mosaic.contains(CGPoint(x: 25, y: 25)))
    // 文字框从左上角往下长；占的范围再按字号留边（泰文声调等会画出框外）
    let frame = Annotation.textFrame("标注", origin: CGPoint(x: 10, y: 100), weight: .medium)
    #expect(frame.maxY == 100 && frame.minX == 10 && frame.height > 10)
    let text = Annotation(shape: .text("标注", origin: CGPoint(x: 10, y: 100)))
    #expect(text.bounds.contains(frame) && text.bounds.maxY > 100)
    #expect(text.contains(CGPoint(x: 15, y: 95)))
    #expect(!Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 2, height: 40))).isMeaningful)
    #expect(!Annotation(shape: .text(" \n", origin: .zero)).isMeaningful)
  }

  @Test func shiftConstrainsShapes() {
    // ⇧：矩形变正方形（跟着拖的方向），箭头吸附到 45°
    #expect(
      Annotation.shape(
        for: .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: -5), constrained: true)
        == .rectangle(CGRect(x: 10, y: -20, width: 30, height: 30)))
    guard
      case .arrow(_, let end)? = Annotation.shape(
        for: .arrow, from: .zero, to: CGPoint(x: 100, y: 10), constrained: true)
    else { return #expect(Bool(false)) }
    #expect(abs(end.y) < 0.001 && abs(end.x - hypot(100, 10)) < 0.001)
    #expect(Annotation.shape(for: .text, from: .zero, to: .zero, constrained: false) == nil)
  }

  @Test func renderDrawsAnnotationsIntoTheSelection() throws {
    // 2x 白底图（视图 100×50 点）；选区是右半边，矩形左边线在 x = 60 点 → 选区图里 x = 20 像素
    let image = try Self.image(size: 200) { context in
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    }
    let viewSize = CGSize(width: 100, height: 100)
    let rectangle = Annotation(
      shape: .rectangle(CGRect(x: 60, y: 20, width: 30, height: 60)),
      style: .init(color: .red, weight: .medium))
    let result = try #require(
      Annotation.render(
        [rectangle], over: image, pixelRect: CGRect(x: 100, y: 0, width: 100, height: 200),
        viewSize: viewSize))
    #expect(result.width == 100 && result.height == 200)
    let pixels = try #require(result.dataProvider?.data as Data?)
    // BGRA（premultipliedFirst + little endian）；第 100 行是图的正中
    let pixel = { (x: Int, y: Int) -> (red: UInt8, green: UInt8) in
      let offset = y * result.bytesPerRow + x * 4
      return (pixels[offset + 2], pixels[offset + 1])
    }
    #expect(pixel(20, 100) == (255, 59))  // 边线：#FF3B30
    #expect(pixel(50, 100) == (255, 255))  // 框里面还是白的
    #expect(pixel(5, 100) == (255, 255))
  }

  @Test func exportedShadowIsMeasuredInPoints() throws {
    // Quartz 在自建位图里按像素算阴影、不跟 CTM 走：render 不乘每点几像素的话，2x 导出的阴影只有屏幕上的一半。
    // 黑色矩形左边线外缘在 38 点，取 36–37 点那一列：1x、2x 一样深，而且确实有阴影
    func shadow(scale: Int) throws -> Int {
      let side = 100 * scale
      let image = try Self.image(size: side) { context in
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
      }
      let rectangle = Annotation(
        shape: .rectangle(CGRect(x: 40, y: 20, width: 40, height: 60)),
        style: .init(color: .black, weight: .medium))
      let result = try #require(
        Annotation.render(
          [rectangle], over: image, pixelRect: CGRect(x: 0, y: 0, width: side, height: side),
          viewSize: CGSize(width: 100, height: 100)))
      let pixels = try #require(result.dataProvider?.data as Data?)
      let row = 50 * scale  // 视图 y = 50 点
      let columns = (36 * scale)..<(37 * scale)
      return columns.map { Int(pixels[row * result.bytesPerRow + $0 * 4 + 1]) }.reduce(0, +)
        / columns.count
    }
    let one = try shadow(scale: 1)
    let two = try shadow(scale: 2)
    #expect(one < 250 && abs(one - two) <= 4, "1x \(one) / 2x \(two)")
  }

  @Test func mosaicHidesTextFromRecognition() async throws {
    // 打码后的合成图识别不出原来的字（修旧版把未打码的原图拿去识字，§11 #44）
    let image = try Self.render(["Secret password 12345"])
    let viewSize = CGSize(width: 600, height: 60)
    let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let plain = try #require(
      Annotation.render([], over: image, pixelRect: full, viewSize: viewSize))
    #expect(await OCR.recognizeText(in: plain)?.contains("Secret") == true)
    let masked = try #require(
      Annotation.render(
        [Annotation(shape: .mosaic(CGRect(origin: .zero, size: viewSize)))], over: image,
        pixelRect: full, viewSize: viewSize))
    #expect(await OCR.recognizeText(in: masked)?.contains("Secret") == false)
  }

  @Test func recognizesQRCode() async throws {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data("https://example.com/kitty".utf8)
    let output = try #require(filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)))
    let image = try #require(CIContext().createCGImage(output, from: output.extent))
    #expect(await OCR.barcodes(in: image) == ["https://example.com/kitty"])
    #expect(await OCR.barcodes(in: try Self.render(["no code here"])).isEmpty)
  }

  @Test func joiningLinesKeepsCJKTight() {
    #expect(OCR.joiningLines("第一行文字\n接着第二行") == "第一行文字接着第二行")
    #expect(OCR.joiningLines("hello\nworld") == "hello world")
    #expect(OCR.joiningLines("an exam-\nple") == "an example")
    #expect(OCR.joiningLines("中文\nEnglish") == "中文English")
    #expect(OCR.joiningLines("한국어\n텍스트") == "한국어 텍스트")
    #expect(OCR.joiningLines("第一行\r\n  second line \n\n第三行") == "第一行second line第三行")
  }

  @Test func recognizesMixedScripts() async throws {
    let image = try Self.render(["中文识别测试", "日本語のテキストです", "한국어 텍스트", "Привет мир", "Hello World"])
    let text = try #require(await OCR.recognizeText(in: image))
    for expected in ["中文识别", "日本語のテキスト", "한국어", "Привет", "Hello"] {
      #expect(text.contains(expected), "没识别出「\(expected)」：\(text)")
    }
  }

  @Test func blankImageHasNoText() async throws {
    let text = await OCR.recognizeText(in: try Self.render([]))
    #expect(text == "")
  }

  /// size×size 的 sRGB 图，fill 在原点左下的上下文里画
  static func image(size: Int, _ fill: (CGContext) -> Void) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    fill(context)
    return try #require(context.makeImage())
  }

  /// 白底黑字，一行一段，2x 像素
  static func render(_ lines: [String]) throws -> CGImage {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 120 * max(lines.count, 1),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
    for (index, line) in lines.enumerated() {
      NSAttributedString(
        string: line,
        attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
      ).draw(at: NSPoint(x: 30, y: bitmap.pixelsHigh - 100 - index * 120))
    }
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.cgImage)
  }
}
