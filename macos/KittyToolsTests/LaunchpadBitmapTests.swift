// 启动台「画进位图」的位置单测（SPEC §10.1、§8 的教训：排版的矩形对 ≠ 画出来对）：屏外窗口里真的把界面画一遍，
// 在第二页第 3 行那一格的范围内找图标（颜色和底色明显不同）、在空格子的范围里确认没有；第 1 页第 3 行第 3 格同理。
// 采样范围留了格子的六成宽 / 六成高，不按图标中心的精确像素（字体、阴影各差一点都能过）。不 makeKey、不弹窗。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadBitmapTests {
  private func projectApp(_ app: LaunchpadProjectApp) -> LaunchpadProjectApp {
    LaunchpadProjectApp(
      id: app.id, ref: app.ref, item: app.item, url: app.url, isSystem: app.isSystem,
      inUtilities: app.inUtilities, isAppStore: false, category: app.category)
  }

  @Test func tilesPaintInTheirOwnCellsOnTheSecondPage() throws {
    let real = LaunchpadCatalog.load()
    try #require(real.count >= 16)
    let apps = real.prefix(16).map { projectApp($0) }
    // 一页 3 × 3：第 1 页 9 个放满、第 2 页 7 个（第 3 行只有第 1 格有）
    let layout = LaunchpadLayout(
      pages: LaunchpadLayout.paginate(apps.map { LaunchpadTile.app($0.ref) }, capacity: 9))
    try #require(layout.pages.count == 2 && layout.pages[1].count == 7)
    let size = NSSize(width: 900, height: 620)
    let model = LaunchpadModel(
      layout: layout, catalog: apps, icons: LaunchpadIcons(), columns: 3, rows: 3,
      screenSize: size)
    model.go(to: 1)
    let host = NSHostingView(
      rootView: LaunchpadView(model: model).frame(width: size.width, height: size.height))
    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .popover
    background.state = .active
    host.frame = background.bounds
    background.addSubview(host)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = background
    window.orderFront(nil)
    for _ in 0..<8 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let frame = try #require(model.gridFrames[1], "第二页的网格框没量到")
    let metrics = model.metrics
    let bitmap = try #require(background.bitmapImageRepForCachingDisplay(in: background.bounds))
    background.cacheDisplay(in: background.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    // 底色取网格框右下角（那里一定是空的）
    let backgroundSample =
      bitmap.colorAt(
        x: min(Int((frame.maxX - 4) * scale), bitmap.pixelsWide - 1),
        y: min(Int((frame.maxY - 4) * scale), bitmap.pixelsHigh - 1)) ?? .clear

    func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
      abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
        + abs(a.blueComponent - b.blueComponent)
    }

    /// 这一格的范围里有没有「和底色明显不同」的像素
    func hasIcon(row: Int, column: Int, in frame: CGRect) -> Bool {
      let centerX = frame.minX + metrics.side + (CGFloat(column) + 0.5) * metrics.cellWidth
      let centerY = frame.minY + (CGFloat(row) + 0.5) * metrics.cellHeight
      let halfWidth = metrics.cellWidth * 0.3
      let halfHeight = metrics.cellHeight * 0.3
      var found = false
      var x = centerX - halfWidth
      while x <= centerX + halfWidth, !found {
        var y = centerY - halfHeight
        while y <= centerY + halfHeight {
          let pixel =
            bitmap.colorAt(
              x: min(max(Int(x * scale), 0), bitmap.pixelsWide - 1),
              y: min(max(Int(y * scale), 0), bitmap.pixelsHigh - 1)) ?? .clear
          if difference(pixel, backgroundSample) > 0.06 {
            found = true
            break
          }
          y += 3
        }
        x += 3
      }
      return found
    }

    // 第二页：第 3 行只有第 1 格有图标，第 2 / 3 格是空的；第 1、2 行各有三个
    #expect(hasIcon(row: 2, column: 0, in: frame), "第二页第 3 行第 1 格应该有图标")
    #expect(!hasIcon(row: 2, column: 1, in: frame), "第二页第 3 行第 2 格应该是空的")
    #expect(!hasIcon(row: 2, column: 2, in: frame), "第二页第 3 行第 3 格应该是空的")
    #expect(hasIcon(row: 0, column: 0, in: frame))
    #expect(hasIcon(row: 1, column: 2, in: frame))
    // 第 1 页第 3 行第 3 格有图标（一页 9 个放满）
    model.go(to: 0)
    for _ in 0..<4 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let firstFrame = try #require(model.gridFrames[0])
    let bitmap2 = try #require(background.bitmapImageRepForCachingDisplay(in: background.bounds))
    background.cacheDisplay(in: background.bounds, to: bitmap2)
    let backgroundSample2 =
      bitmap2.colorAt(
        x: min(Int((firstFrame.maxX - 4) * scale), bitmap2.pixelsWide - 1),
        y: min(Int((firstFrame.maxY - 4) * scale), bitmap2.pixelsHigh - 1)) ?? .clear
    func hasIcon2(row: Int, column: Int) -> Bool {
      let centerX = firstFrame.minX + metrics.side + (CGFloat(column) + 0.5) * metrics.cellWidth
      let centerY = firstFrame.minY + (CGFloat(row) + 0.5) * metrics.cellHeight
      var found = false
      var x = centerX - metrics.cellWidth * 0.3
      while x <= centerX + metrics.cellWidth * 0.3, !found {
        var y = centerY - metrics.cellHeight * 0.3
        while y <= centerY + metrics.cellHeight * 0.3 {
          let pixel =
            bitmap2.colorAt(
              x: min(max(Int(x * scale), 0), bitmap2.pixelsWide - 1),
              y: min(max(Int(y * scale), 0), bitmap2.pixelsHigh - 1)) ?? .clear
          if difference(pixel, backgroundSample2) > 0.06 {
            found = true
            break
          }
          y += 3
        }
        x += 3
      }
      return found
    }
    #expect(hasIcon2(row: 2, column: 2), "第一页第 3 行第 3 格应该有图标")
    window.orderOut(nil)
  }
}
