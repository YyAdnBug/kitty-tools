// Style 的动态色要能在任意线程解析：SwiftUI 在显示链接线程异步渲染动画时会解析它们，
// 取色闭包绑定主线程的话会在后台触发执行器断言闪退（2026-09-27 真机崩溃）

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct StyleTests {
  @Test func dynamicColorsResolveOffMainThread() async {
    let colors = [Style.brand, Style.brandInk, Style.onBrand, Style.selectedFill, Style.hairline]
      .map(
        NSColor.init)
    for color in colors {
      #expect(await Self.resolveOffMain(color) != nil)
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
