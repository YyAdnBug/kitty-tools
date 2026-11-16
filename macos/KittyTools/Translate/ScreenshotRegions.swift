// 截图翻译的容器范围：只在近似纯色、闭合的背景区域里排字，识别气泡、按钮和描边标签。
// 原创实现；借鉴区域约束排版思路，不依赖 OpenCV、模型或第三方代码。
import CoreGraphics

nonisolated struct ScreenshotRegions {
  private let width: Int
  private let height: Int
  private var labels: [UInt16]
  private var regions: [CGRect?] = []
  // ponytail: 每张图最多探测两百万个背景像素；渐变、大图或不闭合的区域不加容器约束，保留既有排法。
  // 若以后需要覆盖大幅复杂图片，再独立做区域分割；不在截图路径上无界扫描。
  private var remaining = 2_000_000

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
    labels = Array(repeating: 0, count: width * height)
  }

  /// 从字框四周找同底色的连通背景，取能包住字框的最小闭合区域；描边标签和外层气泡可能同色。
  mutating func container(
    around box: CGRect, lineHeight: CGFloat, background: ScreenshotOverlay.RGB,
    color: (Int, Int) -> ScreenshotOverlay.RGB
  ) -> CGRect? {
    let gap = max(1, lineHeight * 0.08)
    let seeds = [
      CGPoint(x: box.midX, y: box.maxY + gap),
      CGPoint(x: box.midX, y: box.minY - gap),
      CGPoint(x: box.minX - gap, y: box.midY),
      CGPoint(x: box.maxX + gap, y: box.midY),
    ]
    var found: CGRect?
    for seed in seeds {
      let x = Int(seed.x)
      let y = Int(seed.y)
      guard x >= 0, x < width, y >= 0, y < height,
        color(x, y).distance(to: background) < 0.065,
        let rect = region(x: x, y: y, background: background, color: color),
        rect.contains(box.insetBy(dx: 1, dy: 1)), rect.height >= lineHeight * 1.1
      else { continue }
      if let previous = found {
        if rect.width * rect.height < previous.width * previous.height { found = rect }
      } else {
        found = rect
      }
    }
    return found
  }

  /// 同一背景区域只遍历一次。碰到图边或预算耗尽就停止，不能把无边界的页面背景当按钮。
  private mutating func region(
    x: Int, y: Int, background: ScreenshotOverlay.RGB,
    color: (Int, Int) -> ScreenshotOverlay.RGB
  ) -> CGRect? {
    let start = y * width + x
    if labels[start] > 0 { return regions[Int(labels[start]) - 1] }
    guard remaining > 0, regions.count < Int(UInt16.max) else { return nil }
    let id = UInt16(regions.count + 1)
    regions.append(nil)
    labels[start] = id
    var queue: [Int32] = [Int32(start)]
    var cursor = 0
    var minX = x
    var maxX = x
    var minY = y
    var maxY = y
    while cursor < queue.count {
      guard remaining > 0 else { return nil }
      remaining -= 1
      let index = Int(queue[cursor])
      cursor += 1
      let px = index % width
      let py = index / width
      guard px > 0, px < width - 1, py > 0, py < height - 1 else { return nil }
      minX = min(minX, px)
      maxX = max(maxX, px)
      minY = min(minY, py)
      maxY = max(maxY, py)
      for direction in 0..<4 {
        let next =
          switch direction {
          case 0: index - 1
          case 1: index + 1
          case 2: index - width
          default: index + width
          }
        guard labels[next] == 0,
          color(next % width, next / width).distance(to: background) < 0.065
        else { continue }
        labels[next] = id
        queue.append(Int32(next))
      }
    }
    let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    // 背景得占区域的大半，避免把字母内部的孔或复杂纹理误当容器。
    guard CGFloat(queue.count) >= rect.width * rect.height * 0.5 else { return nil }
    regions[Int(id) - 1] = rect
    return rect
  }
}
