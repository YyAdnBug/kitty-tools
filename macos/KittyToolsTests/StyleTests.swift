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
