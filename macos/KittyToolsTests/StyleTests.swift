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
