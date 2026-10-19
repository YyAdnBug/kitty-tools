// 真机反馈后照 macOS 15 对齐的那一轮（2026-10-18）：尺寸算式（几种屏幕）、图标位图缓存（后台画、只画一次、屏变大重画）、
// 壁纸背景的裁剪和模糊（喂造的图，不读用户的壁纸）。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadLookTests {
  private let screens = [
    CGSize(width: 1280, height: 800), CGSize(width: 1512, height: 982),
    CGSize(width: 1710, height: 1112), CGSize(width: 1920, height: 1080),
    CGSize(width: 2560, height: 1440),
  ]

  /// 7 × 5 时照 macOS 15 的比例：网格居中占 80% 屏宽，第一行图标中心在约 15% 屏高处，图标约屏宽的 5.4%，
  /// 搜索框中心约 6.7%、宽约 1/6，页点在网格下面、屏幕里面
  @Test func metricsFollowMacOS15Proportions() {
    for size in screens {
      let metrics = LaunchpadMetrics(size: size, columns: 7, rows: 5)
      #expect(abs(metrics.side * 2 + metrics.gridWidth - size.width) < 0.5, "\(size)")
      #expect(abs(metrics.gridWidth / size.width - 0.80) < 0.01, "\(size)")
      #expect(abs(metrics.icon / size.width - 0.054) < 0.004, "\(size)")
      // 格子里那一组（选中底 1.22 倍 + 间距 + 一行字）竖着居中：图标中心
      let block = metrics.icon * 1.22 + 6 + 14
      let firstIcon =
        metrics.gridTop + (metrics.cellHeight - block) / 2 + metrics.icon * 0.61
      #expect(firstIcon / size.height > 0.13 && firstIcon / size.height < 0.17, "\(size)")
      let searchCenter = metrics.searchTop + LaunchpadMetrics.searchHeight / 2
      #expect(abs(searchCenter / size.height - 0.067) < 0.01, "\(size)")
      #expect(abs(metrics.searchWidth - size.width / 6) < 1, "\(size)")
      #expect(metrics.gridTop >= metrics.searchTop + LaunchpadMetrics.searchHeight, "\(size)")
      #expect(metrics.dotsY > metrics.gridTop + metrics.gridHeight, "\(size)")
      #expect(metrics.dotsY < size.height - 8, "\(size)")
    }
  }

  /// 行列数改了（设置里 5–10 列、4–8 行）：图标和一行名字仍放得进格子，名字比格子窄
  @Test func iconAndLabelFitEveryGrid() {
    for size in screens {
      for columns in [5, 7, 10] {
        for rows in [4, 5, 8] {
          let metrics = LaunchpadMetrics(size: size, columns: columns, rows: rows)
          let label = "\(size) \(columns)×\(rows)"
          #expect(metrics.icon * 1.22 + 6 + 14 <= metrics.cellHeight, "\(label)")
          #expect(metrics.icon * 1.22 <= metrics.cellWidth, "\(label)")
          #expect(metrics.labelWidth < metrics.cellWidth, "\(label)")
        }
      }
    }
  }

  /// 文件夹面板：图标和主网格一样大，7 列放得进屏幕，满 5 行加上面的名字也放得进屏高
  @Test func folderPanelUsesMainIconSizeAndFits() {
    for size in screens {
      let metrics = LaunchpadMetrics(size: size, columns: 7, rows: 5)
      #expect(metrics.folderIcon == metrics.icon, "\(size)")
      let width = metrics.folderGridWidth + LaunchpadMetrics.folderPadding * 2
      #expect(width <= size.width - 48 + 0.5, "\(size)")
      let height =
        metrics.folderCellHeight * 5 + 10 + 7 + LaunchpadMetrics.folderPadding * 2 + 18 + 34
      #expect(height <= size.height, "\(size)")
    }
  }

  private let calculator = LaunchpadProjectApp(
    id: "com.apple.calculator",
    ref: LaunchpadAppRef(
      bundleID: "com.apple.calculator", path: "/System/Applications/Calculator.app"),
    item: LauncherItem(
      kind: .app, target: "/System/Applications/Calculator.app", title: "计算器", subtitle: "应用程序",
      names: [LauncherMatch.fold("计算器")], initials: [LauncherMatch.initials("计算器")]),
    url: URL(filePath: "/System/Applications/Calculator.app"), isSystem: true, inUtilities: false,
    isAppStore: false, category: nil)

  /// 等后台画完：按轮数等（不按墙钟时间猜），最多约 2 秒
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// 后台模式：先给透明占位，后台画好换成一张 pixelSize 见方的位图；再要不重画（同一个对象）
  @Test func iconsRenderInBackgroundOnce() async {
    let icons = LaunchpadIcons(synchronous: false, pixelSize: 120)
    let first = icons.icon(for: calculator, size: 60)
    #expect(first === LaunchpadIcons.placeholder)
    await waitUntil { icons.count == 1 }
    #expect(icons.count == 1)
    let drawn = icons.icon(for: calculator, size: 60)
    #expect(drawn !== LaunchpadIcons.placeholder)
    #expect(drawn.representations.first?.pixelsWide == 120)
    #expect(icons.icon(for: calculator, size: 60) === drawn)
    // 再预热一次（目录又扫完了）：已经有的不再画
    icons.prewarm([calculator])
    await Task.yield()
    #expect(icons.icon(for: calculator, size: 60) === drawn)
  }

  /// 换了更大的屏：按新的像素尺寸重画，画好之前旧图照样显示
  @Test func iconsRerenderWhenScreenGetsBigger() async {
    let icons = LaunchpadIcons(synchronous: false, pixelSize: 64)
    icons.prewarm([calculator])
    await waitUntil { icons.count == 1 }
    let small = icons.icon(for: calculator, size: 32)
    #expect(small.representations.first?.pixelsWide == 64)
    icons.prewarm([calculator], pixelSize: 128)
    #expect(icons.icon(for: calculator, size: 32) === small)
    await waitUntil { icons.icon(for: calculator, size: 32) !== small }
    #expect(icons.icon(for: calculator, size: 32).representations.first?.pixelsWide == 128)
    #expect(icons.pixelSize == 128)
  }

  /// 画位图不靠主线程：后台线程直接调
  @Test func iconRenderWorksOffMainThread() async {
    let image = await Task.detached {
      LaunchpadIcons.render(path: "/System/Applications/Calculator.app", pixelSize: 96)
    }.value
    #expect(image?.width == 96 && image?.height == 96)
  }

  /// 壁纸按「填满」裁到屏幕比例再模糊：左红右蓝的宽图，裁出来左边偏红、右边偏蓝，尺寸是要的尺寸
  @Test func wallpaperFillsAndBlurs() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 200, y: 0, width: 200, height: 100))
    let source = try #require(context.makeImage())
    let image = try #require(LaunchpadWallpaper.render(source: source, width: 160, height: 100))
    #expect(image.width == 160 && image.height == 100)
    let rep = NSBitmapImageRep(cgImage: image)
    let left = try #require(rep.colorAt(x: 2, y: 50)?.usingColorSpace(.sRGB))
    let right = try #require(rep.colorAt(x: 157, y: 50)?.usingColorSpace(.sRGB))
    let middle = try #require(rep.colorAt(x: 80, y: 50)?.usingColorSpace(.sRGB))
    #expect(left.redComponent > left.blueComponent)
    #expect(right.blueComponent > right.redComponent)
    // 糊过：正中间（红蓝交界）两种颜色混在一起
    #expect(middle.redComponent > 0.2 && middle.blueComponent > 0.2)
  }

  @Test func wallpaperMissingFileGivesNil() {
    #expect(
      LaunchpadWallpaper.load(url: URL(filePath: "/nonexistent/wallpaper.heic"), maxPixel: 100)
        == nil)
  }
}
