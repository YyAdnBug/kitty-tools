// 长图标注窗口的探针（第 1 批，按需开）：`TEST_RUNNER_KITTY_SCROLL_EDITOR_PROBE=1` 才跑，数字 grep「scroll-editor-probe」。
// 拍板页第 1 批要先验的就是这几样（长图上限 30000 像素高、约 137 MB）：
//   - 一屏画多久（画布只裁看得见的那一段：顶 / 中 / 底各一次，适配和 1:1 两档），滚动时每帧都要重画它；
//   - 建图、装进画布、放掉前后的 phys_footprint（活动监视器的口径）；
//   - 导出 PNG 多久、峰值涨多少（第 2 批带标注导出还要再渲一张同尺寸位图，到时候一起量）。
// 量不到的一样：**超大视图的图层会不会撞 GPU 纹理上限**只在屏幕上才看得出来（屏外窗口不走合成），
// 看 HANDTEST「长图标注手测」第 1 条。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct AnnotateOverlayProbeTests {
  nonisolated private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["KITTY_SCROLL_EDITOR_PROBE"] == "1"
  }

  private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
  }

  /// 画一块（在位图上下文里直接调画布的 draw，同窗口里重画那一段）；返回秒
  private func paint(_ canvas: ScrollCanvas, _ rect: CGRect, scale: CGFloat) -> Double {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale),
        pixelsHigh: Int(rect.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return 0 }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
    let start = Date()
    canvas.draw(rect)
    context.flushGraphics()
    return Date().timeIntervalSince(start)
  }

  /// 长图：每 20 行一道深色横线（真实内容那样有变化，别让画布画一张纯色图就蒙混过去）
  private func longImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    for y in stride(from: 0, to: height, by: 20) {
      context.fill(CGRect(x: 40, y: y, width: width - 120, height: 6))
    }
    return context.makeImage()!
  }

  @Test(.enabled(if: AnnotateOverlayProbeTests.isEnabled)) func measure() async throws {
    let megabyte = 1024 * 1024
    let base = footprint()
    let pixels = (width: 1600, height: 30000)  // 点宽 800 > 一屏 880 的内容宽：适配那一档真的会缩
    let made = Date()
    let image = longImage(width: pixels.width, height: pixels.height)
    let makeTime = Date().timeIntervalSince(made)
    let afterImage = footprint()

    let scale: CGFloat = 2
    let canvas = ScrollCanvas(image: image, scale: scale)
    var editor: AnnotateOverlay? = AnnotateOverlay(image: image, scale: scale) {
      _, _, _, _ in
    }
    let window = try #require(editor?.panel)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    window.layoutIfNeeded()
    let afterWindow = footprint()

    // 一屏：窗口默认大小里看得见的那一块，顶 / 中 / 底各画两遍（第二遍是热的）
    let viewport = CGSize(width: 700, height: 560)
    var times: [String: [Double]] = [:]
    for (name, y) in [
      ("顶", canvas.bounds.height - viewport.height), ("中", canvas.bounds.height / 2), ("底", 0),
    ] {
      let rect = CGRect(x: 0, y: y, width: viewport.width, height: viewport.height)
      times[name] = [paint(canvas, rect, scale: scale), paint(canvas, rect, scale: scale)]
    }
    // 适配那一档（缩到约 0.73）：同样一屏，画的内容更多
    let fit = AnnotateOverlay.fitMagnification(
      pointWidth: canvas.bounds.width, viewportWidth: viewport.width)
    let fitRect = CGRect(
      x: 0, y: canvas.bounds.height / 2, width: viewport.width / fit, height: viewport.height / fit)
    let fitTime = paint(canvas, fitRect, scale: scale * fit)

    let exported = Date()
    let png = await ScreenshotOutput.png(image, scale: scale)
    let exportTime = Date().timeIntervalSince(exported)
    let afterExport = footprint()

    editor?.close()
    editor = nil
    window.orderOut(nil)
    try? await Task.sleep(for: .milliseconds(300))  // 让自动释放池清一轮（async 里不能嵌套跑 RunLoop）
    let afterClose = footprint()

    func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / Double(megabyte)) }
    func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }
    print(
      """
      scroll-editor-probe 长图 \(pixels.width) × \(pixels.height)（点 \(Int(canvas.bounds.width)) \
      × \(Int(canvas.bounds.height))，建图 \(ms(makeTime))）
      scroll-editor-probe 一屏 \(Int(viewport.width)) × \(Int(viewport.height)) @\(Int(scale))x：\
      顶 \(times["顶"]!.map(ms).joined(separator: " / ")) · 中 \
      \(times["中"]!.map(ms).joined(separator: " / ")) · 底 \
      \(times["底"]!.map(ms).joined(separator: " / "))（第一遍 / 第二遍）
      scroll-editor-probe 适配那一档（\(String(format: "%.2f", fit))×）一屏 \(ms(fitTime))
      scroll-editor-probe 导出 PNG \(ms(exportTime))，\(png.map { mb($0.count) } ?? "失败")
      scroll-editor-probe footprint：起点 \(mb(base)) → 建图后 \(mb(afterImage)) \
      → 窗口建好 \(mb(afterWindow)) → 导出后 \(mb(afterExport)) → 关掉放掉 \(mb(afterClose))
      """)
    #expect(png != nil)
  }
}
