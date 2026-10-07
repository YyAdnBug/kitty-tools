// Style 的动态色要能在任意线程解析：SwiftUI 在显示链接线程异步渲染动画时会解析它们，
// 取色闭包绑定主线程的话会在后台触发执行器断言闪退（2026-09-27 真机崩溃）；发丝线宽跟着增强对比度走（Whisker §7）

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct StyleTests {
  @Test func dynamicColorsResolveOffMainThread() async {
    let colors = [
      Style.brand, Style.brandInk, Style.onBrand, Style.selectedFill, Style.hairline,
      Style.inputFill,
    ]
    .map(NSColor.init)
    for color in colors {
      #expect(await Self.resolveOffMain(color) != nil)
    }
  }

  /// 发丝线：平时 0.5 pt，增强对比度 1 pt（Hairline、hairlineBorder、输入框、录制框共用这一个判断）
  @Test func hairlineWidthFollowsContrast() {
    #expect(Style.hairlineWidth(.standard) == 0.5)
    #expect(Style.hairlineWidth(.increased) == 1)
  }

  /// 降低透明度时的 0.9 不透明底只给 15 的毛玻璃；macOS 26 的玻璃自己变实，不再垫（Whisker §7）
  @Test func opaqueUnderlayOnlyBeforeGlass() {
    #expect(!Style.opaqueUnderlay(reduceTransparency: false))
    if #available(macOS 26, *) {
      #expect(!Style.opaqueUnderlay(reduceTransparency: true))
    } else {
      #expect(Style.opaqueUnderlay(reduceTransparency: true))
    }
  }

  /// Panel 皮肤（Whisker §2）：15 是 .popover 毛玻璃 + maskImage 圆角，macOS 26 是 16 pt 圆角的液态玻璃；
  /// 两种都是内容（SwiftUI）和拖边放在同一个父视图里（拖边把滚轮转给它旁边的内容）
  @MainActor @Test func panelMaterialPerSystem() throws {
    let panel = OverlayPanel(
      size: NSSize(width: 300, height: 200), minSize: NSSize(width: 200, height: 100),
      autoHide: .resignKey, isPinned: { false }, content: Color.clear)
    let root = try #require(panel.contentView)
    let background: NSView
    if #available(macOS 26, *) {
      let glass = try #require(root as? NSGlassEffectView)
      #expect(glass.cornerRadius == Style.Radius.panel)
      background = try #require(glass.contentView)
    } else {
      let effect = try #require(root as? NSVisualEffectView)
      #expect(effect.material == .popover && effect.state == .active && effect.maskImage != nil)
      background = effect
    }
    // SwiftUI 内容（铺满）+ 左右两条拖边（毛玻璃自己也有子视图，按类型数）
    let names = background.subviews.map { String(describing: type(of: $0)) }
    #expect(names.filter { $0.hasPrefix("NSHostingView") }.count == 1, "\(names)")
    #expect(names.filter { $0 == "ResizeEdge" }.count == 2, "\(names)")
  }

  /// 面板描边和卡片高光不能是整块位图（常驻内存，2026-10-07）：直接拿渐变描形状，SwiftUI 会把它栅格化成形状外接矩形
  /// 那么大的 PaintShapeLayer，P3 屏上每像素 8 字节——720 × 520 的面板一张 11.4 MB、收起后也不还，三块面板加翻译卡片
  /// 常驻约 55 MB。现在是纯色描边 + 渐变蒙版，两样都是不带位图的图层（mac-whisker §8）。
  /// 认的是 SwiftUI 现在怎么把这两个视图变成图层（macOS 15.7）：系统升级后这条挂了，先用内存探针的屏上模式
  /// （KITTY_MEMORY_PROBE_ONSCREEN）看面板显示后 CoreAnimation 涨了多少，再改这里
  @MainActor @Test func rimAndCardHighlightAreNotRasterized() throws {
    let panel = OverlayPanel(
      size: NSSize(width: 320, height: 240), autoHide: .resignKey, isPinned: { true },
      content: Color.clear.frame(width: 200, height: 120).cardSurface()
        .environment(\.colorScheme, .dark))
    panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    panel.orderFront(nil)
    defer { panel.orderOut(nil) }
    RunLoop.main.run(until: .now.addingTimeInterval(0.2))
    var names: [String] = []
    var gradients = 0
    func collect(_ layer: CALayer) {
      names.append(String(describing: type(of: layer)))
      if layer is CAGradientLayer { gradients += 1 }
      layer.sublayers?.forEach(collect)
      if let mask = layer.mask { collect(mask) }
    }
    collect(try #require(panel.contentView?.layer))
    #expect(!names.contains { $0.contains("PaintShape") }, "\(names)")
    // 高光还在：卡片一层渐变蒙版，面板描边一层（macOS 26 的玻璃不画面板描边）
    if #available(macOS 26, *) {
      #expect(gradients == 1, "\(names)")
    } else {
      #expect(gradients == 2, "\(names)")
    }
  }

  /// 在并发线程池里解析（会调到动态色的取色闭包）
  @concurrent nonisolated private static func resolveOffMain(_ color: NSColor) async -> NSColor? {
    #expect(pthread_main_np() == 0)  // 确实不在主线程
    return color.usingColorSpace(.sRGB)
  }
}

/// 刘海岛详情里的摘录：第一行前 24 个字，后面还有就补「…」
struct IslandExcerptTests {
  @Test func excerpt() {
    #expect(Island.excerpt("  发布吧  ") == "发布吧")
    #expect(Island.excerpt("第一行\n第二行") == "第一行…")
    #expect(Island.excerpt("第一行\r\n第二行") == "第一行…")
    let long = String(repeating: "字", count: 30)
    #expect(Island.excerpt(long) == String(repeating: "字", count: 24) + "…")
    #expect(Island.excerpt(String(repeating: "字", count: 24)) == String(repeating: "字", count: 24))
  }

  /// 进行中的岛改详情（转 GIF、压缩的百分比，第二轮体检 R3）：只改详情；岛上不是这一条（标题不同、不是进行中）就不动
  @MainActor @Test func progressUpdatesDetailInPlace() {
    let content = { (title: String, tone: Island.Tone) in
      Island.Content(title: title, detail: nil, tone: tone, symbol: "circle", leading: .tone)
    }
    let island = Island(showing: content("正在压缩…", .progress))
    island.progress("正在压缩…", detail: "37%")
    #expect(island.content?.detail == "37%" && island.content?.title == "正在压缩…")
    island.progress("正在转成 GIF…", detail: "50%")
    #expect(island.content?.detail == "37%")
    let done = Island(showing: content("已压缩", .success))
    done.progress("已压缩", detail: "99%")
    #expect(done.content?.detail == nil)
    #expect(ShelfCard.progressDetail(37) == "37%")
    #expect(ShelfCard.progressDetail(37, note: "只转前 60 秒") == "只转前 60 秒 · 37%")
    #expect(ShelfCard.progressDetail(140) == "100%" && ShelfCard.progressDetail(-3) == "0%")
  }

  /// 慢活才出「进行中」（识字的「识别中」）：很快做完的不出这一下；过了时限还没做完才出，而且只出一次。
  /// 慢活不靠墙上时钟模拟：全量并行跑时主线程被别的测试占着，「睡 300 ms」和「30 ms 后提示」谁先恢复说不准
  /// （活先恢复就把提示取消了，这在产品里是对的，测试却会判错）。所以慢活 = 等提示出过才做完
  @MainActor @Test(.timeLimit(.minutes(1))) func slowNoticeOnlyWhenWorkIsSlow() async {
    var notices = 0
    let quick = await Island.whenSlow(
      after: .milliseconds(80), notice: { notices += 1 }, work: { 7 })
    try? await Task.sleep(for: .milliseconds(200))
    #expect(quick == 7 && notices == 0)
    let (shown, signal) = AsyncStream<Void>.makeStream()
    let slow = await Island.whenSlow(
      after: .milliseconds(30),
      notice: {
        notices += 1
        signal.yield()
      },
      work: {
        for await _ in shown { break }
        return 9
      })
    #expect(slow == 9 && notices == 1)
  }

  /// 岛的前导缩略图只留 26×18 两倍像素的小图，长截图取顶部一段（不把整张原图放进岛）
  @Test func thumbnailIsSmallTopCrop() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: 100, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    guard case .thumbnail(let thumb) = Island.thumbnail(of: image) else {
      Issue.record("不是缩略图")
      return
    }
    let pixels = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(pixels.width == 52)
    #expect(pixels.height == 36)
  }
}
