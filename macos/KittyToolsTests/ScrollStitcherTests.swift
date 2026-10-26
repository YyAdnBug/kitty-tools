// 长截图拼接单测：合成一张长「页面」（每行不同的墨点、行间空白），按滚动位置裁出帧，盖上固定的吸顶栏、
// 带闪烁光标的页脚和随滚动移动的滚动条，喂给 ScrollStitcher，逐字节核对拼出的长图。
// 覆盖：往下 / 往上拼、页脚光标闪烁（锁住页脚不能估小）、滚太快对不上后往回滚接着拼、画面不动与小变化、
// 滚到底回弹（单帧、多帧）、往回滚不丢有字的行、长度上限、整页重复行时宁可不接、悬停高亮原地变了一块不算对不上、
// 和上一帧没有重叠时在已拼的画布里重新找到位置。

import CoreGraphics
import Foundation
import Testing

@testable import KittyTools

struct ScrollStitcherTests {
  private static let width = 120
  private static let height = 200
  private static let header = 24
  private static let footer = 30
  private static let scrollbar = 8

  /// 长页面：每 14 行一段「文字」（每行随机墨点，行行不同）、6 行空白
  private static let page: [UInt8] = {
    var rng = SeededGenerator(state: 42)
    var bytes = [UInt8](repeating: 255, count: width * 4 * 3000)
    for y in 0..<3000 where y % 20 < 14 {
      for x in 4..<(width - scrollbar - 4) where rng.next() % 5 == 0 {
        let gray = UInt8(rng.next() % 160)
        bytes.replaceSubrange(
          (y * width + x) * 4..<(y * width + x) * 4 + 3, with: [gray, gray, gray])
      }
    }
    return bytes
  }()

  /// 滚到 offset 的一帧；chrome 时盖上吸顶栏和页脚（caret 控制页脚里的光标），右边画滚动条
  private static func frame(at offset: Int, chrome: Bool = true, caret: Bool = false) -> [UInt8] {
    let rowBytes = width * 4
    var bytes = Array(page[offset * rowBytes..<(offset + height) * rowBytes])
    func fill(_ rows: Range<Int>, _ columns: Range<Int>, _ value: UInt8) {
      for y in rows {
        for x in columns {
          bytes.replaceSubrange(
            (y * width + x) * 4..<(y * width + x) * 4 + 3, with: [value, value, value])
        }
      }
    }
    if chrome {
      fill(0..<header, 0..<width, 60)
      fill(8..<14, 10..<50, 230)  // 标题
      fill((height - footer)..<height, 0..<width, 235)
      fill((height - footer + 6)..<(height - 6), 10..<100, 255)  // 输入框
      if caret { fill((height - footer + 9)..<(height - 9), 14..<16, 0) }
    }
    let knob = offset * (height - 40) / 2800
    fill(knob..<(knob + 40), (width - 6)..<(width - 2), 120)
    return bytes
  }

  private static func image(_ bytes: [UInt8], rows: Int = height) -> CGImage {
    CGImage(
      width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }

  private static func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  /// 期望的长图：第一帧（最上面）的吸顶栏 + 页面 [top + header, bottom - footer) + 最后一帧（最下面）的页脚。
  /// 滚动条那几列跟着各帧走，不核对
  private static func expect(
    _ result: CGImage?, top: Int, bottom: Int, topFrame: [UInt8], bottomFrame: [UInt8],
    chrome: Bool = true
  ) {
    let header = chrome ? header : 0
    let footer = chrome ? footer : 0
    guard let result else {
      Issue.record("没有拼出图")
      return
    }
    #expect(result.height == bottom - top)
    guard result.height == bottom - top else { return }
    let rowBytes = width * 4
    let got = pixels(result)
    var want = Array(topFrame[0..<header * rowBytes])
    want += page[(top + header) * rowBytes..<(bottom - footer) * rowBytes]
    want += bottomFrame[(height - footer) * rowBytes..<height * rowBytes]
    let compared = (width - scrollbar) * 4
    let mismatched = (0..<result.height).filter { y in
      got[y * rowBytes..<y * rowBytes + compared] != want[y * rowBytes..<y * rowBytes + compared]
    }
    #expect(mismatched.isEmpty, "第一处不一致在第 \(mismatched.first ?? -1) 行")
  }

  private static func stitcher(_ first: [UInt8]) throws -> ScrollStitcher {
    try #require(
      ScrollStitcher(first: image(first), scrollbarWidth: scrollbar, maxHeight: 100_000))
  }

  @Test func stitchesDownWithHeaderAndBlinkingFooter() throws {
    let first = Self.frame(at: 100)
    var stitcher = try Self.stitcher(first)
    var last = first
    // 步长不一：小步、大步（重叠只剩一点）、1 像素；光标每帧闪一下
    for (index, offset) in [103, 140, 230, 231, 330, 420, 470].enumerated() {
      last = Self.frame(at: offset, caret: index % 2 == 0)
      guard case .moved(let grown) = stitcher.add(Self.image(last)) else {
        Issue.record("滚到 \(offset) 没对上")
        return
      }
      #expect(grown > 0)
    }
    Self.expect(
      stitcher.makeImage(), top: 100, bottom: 470 + Self.height, topFrame: first, bottomFrame: last)
  }

  @Test func stitchesUpLikeAChatHistory() throws {
    let first = Self.frame(at: 1500, caret: true)
    var stitcher = try Self.stitcher(first)
    var last = first
    for (index, offset) in [1450, 1380, 1379, 1300, 1210].enumerated() {
      last = Self.frame(at: offset, caret: index % 2 == 1)
      guard case .moved = stitcher.add(Self.image(last)) else {
        Issue.record("滚到 \(offset) 没对上")
        return
      }
    }
    #expect(stitcher.isGrowingUp)
    // 往上拼：最上面是最后一帧的吸顶栏，最下面还是第一帧的页脚
    Self.expect(
      stitcher.makeImage(), top: 1210, bottom: 1500 + Self.height, topFrame: last,
      bottomFrame: first)
  }

  @Test func recoversAfterScrollingTooFast() throws {
    let first = Self.frame(at: 0)
    var stitcher = try Self.stitcher(first)
    #expect(stitcher.add(Self.image(Self.frame(at: 80))) == .moved(grown: 80))
    // 一下滚出一整屏：没有重叠，不接
    #expect(stitcher.add(Self.image(Self.frame(at: 400))) == .lost)
    #expect(stitcher.outputHeight == Self.height + 80)
    // 往回滚到和上一帧有重叠的地方，接着往下拼
    let last = Self.frame(at: 200)
    #expect(stitcher.add(Self.image(last)) == .moved(grown: 120))
    Self.expect(
      stitcher.makeImage(), top: 0, bottom: 200 + Self.height, topFrame: first, bottomFrame: last)
  }

  @Test func ignoresStillFramesAndSmallChanges() throws {
    let first = Self.frame(at: 300)
    var stitcher = try Self.stitcher(first)
    #expect(stitcher.add(Self.image(first)) == .unchanged)
    // 只有光标闪了一下
    #expect(stitcher.add(Self.image(Self.frame(at: 300, caret: true))) == .unchanged)
    // 往回滚：在已拼范围里，只挪位置
    #expect(stitcher.add(Self.image(Self.frame(at: 250))) == .moved(grown: 50))
    #expect(stitcher.add(Self.image(Self.frame(at: 280))) == .moved(grown: 0))
  }

  /// 鼠标悬停的高亮：rows 这几行的白底变成浅灰（字还在），像列表里光标下的那一行
  private static func hovered(_ frame: [UInt8], rows: Range<Int>) -> [UInt8] {
    var bytes = frame
    for index in (rows.lowerBound * width * 4)..<(rows.upperBound * width * 4)
    where bytes[index] == 255 && index % 4 != 3 {
      bytes[index] = 236
    }
    return bytes
  }

  @Test func hoverHighlightIsNotLost() throws {
    // 2026-10-13 用户反馈「经常对不上」：在列表上每滚一下停住，光标下那行的高亮就换一次——没滚、原地变了十几二十行
    // （超过 quietShare），原来报对不上
    let first = Self.frame(at: 300)
    var stitcher = try Self.stitcher(first)
    #expect(stitcher.add(Self.image(Self.hovered(first, rows: 60..<90))) == .unchanged)
    #expect(stitcher.outputHeight == Self.height)
    // 带着高亮接着滚，照样接得上
    let next = Self.frame(at: 340)
    #expect(stitcher.add(Self.image(Self.hovered(next, rows: 120..<150))) == .moved(grown: 40))
    // 停住后高亮从一行换到另一行：两处都变了（60 行，三成）
    #expect(stitcher.add(Self.image(Self.hovered(next, rows: 40..<70))) == .unchanged)
    // 真滚出一整屏（原地不变的只剩吸顶栏和页脚）还是对不上
    #expect(stitcher.add(Self.image(Self.frame(at: 900))) == .lost)
  }

  @Test func relocatesInsideTheCanvas() throws {
    // 往下拼到 400，一下滚回 100（和上一帧没有重叠）：在已经拼好的画布里找到位置，不报对不上；
    // 再一下滚到 450（和上一帧还是没有重叠，但压着画布的下沿）：从画布上接着往下拼
    let first = Self.frame(at: 0)
    var stitcher = try Self.stitcher(first)
    for offset in [80, 160, 240, 320, 400] {
      #expect(stitcher.add(Self.image(Self.frame(at: offset))) == .moved(grown: 80))
    }
    #expect(stitcher.add(Self.image(Self.frame(at: 100))) == .moved(grown: 0))
    #expect(stitcher.add(Self.image(Self.frame(at: 150))) == .moved(grown: 0))
    let last = Self.frame(at: 450, caret: true)
    #expect(stitcher.add(Self.image(last)) == .moved(grown: 50))
    Self.expect(
      stitcher.makeImage(), top: 0, bottom: 450 + Self.height, topFrame: first, bottomFrame: last)
    // 从 100 一下滚到只压着画布下沿一小截的地方（能比的行不到这一帧的四分之一）：不接，宁可报对不上；
    // 往回滚一点、压得多了就接上
    #expect(stitcher.add(Self.image(Self.frame(at: 100))) == .moved(grown: 0))
    #expect(stitcher.add(Self.image(Self.frame(at: 570))) == .lost)
    #expect(stitcher.add(Self.image(Self.frame(at: 520))) == .moved(grown: 70))
    // 往上翻的那头一样：滚到画布上面一点，从画布顶上接着往上拼（这里拼的是 1500 往上）
    let bottomFrame = Self.frame(at: 1500)
    var upward = try Self.stitcher(bottomFrame)
    for offset in [1420, 1340, 1260] {
      #expect(upward.add(Self.image(Self.frame(at: offset))) == .moved(grown: 80))
    }
    #expect(upward.add(Self.image(Self.frame(at: 1500))) == .moved(grown: 0))
    let topFrame = Self.frame(at: 1200)
    #expect(upward.add(Self.image(topFrame)) == .moved(grown: 60))
    Self.expect(
      upward.makeImage(), top: 1200, bottom: 1500 + Self.height, topFrame: topFrame,
      bottomFrame: bottomFrame)
  }

  /// 页面到 end 行结束，再往下是越界露出的纯色底
  private static func overscrolled(_ offset: Int, end: Int, chrome: Bool = false) -> CGImage {
    var bytes = frame(at: offset, chrome: chrome)
    let rowBytes = width * 4
    // 内容区 [header, bottom) 里页面 end 行以下的部分
    let bottom = height - (chrome ? footer : 0)
    let blank = min(max(offset + bottom - end, 0), bottom - (chrome ? header : 0))
    for y in (bottom - blank)..<bottom {
      bytes.replaceSubrange(
        y * rowBytes..<(y + 1) * rowBytes,
        with: Array(repeatElement([236, 236, 236, 255] as [UInt8], count: width).joined()))
    }
    return image(bytes)
  }

  @Test func trimsOverscrollAfterBounce() throws {
    // 滚过头 60 行，弹回 20，再弹回原位
    let first = Self.frame(at: 500, chrome: false)
    var stitcher = try Self.stitcher(first)
    #expect(stitcher.add(Self.overscrolled(560, end: 700)) == .moved(grown: 60))
    #expect(stitcher.add(Self.overscrolled(540, end: 700)) == .moved(grown: -20))
    #expect(stitcher.add(Self.overscrolled(500, end: 700)) == .moved(grown: -40))
    Self.expect(
      stitcher.makeImage(), top: 500, bottom: 700, topFrame: first, bottomFrame: first,
      chrome: false)
  }

  @Test func trimsMultiFrameBounceWithFooter() throws {
    // 每 40 毫秒一帧的真实回弹：越界 20、35、42 行，再弹回 30、15、5、0；带页脚
    let end = 1000
    let first = Self.frame(at: end - Self.height + Self.footer - 120)
    var stitcher = try Self.stitcher(first)
    var last = first
    for over in [-60, 20, 35, 42, 30, 15, 5, 0] {
      let offset = end - Self.height + Self.footer + over
      last = Self.frame(at: offset)
      guard case .moved = stitcher.add(Self.overscrolled(offset, end: end, chrome: true)) else {
        Issue.record("越界 \(over) 没对上")
        return
      }
    }
    let top = end - Self.height + Self.footer - 120
    Self.expect(
      stitcher.makeImage(), top: top, bottom: end + Self.footer, topFrame: first, bottomFrame: last)
  }

  @Test func keepsInkWhenScrollingBackALittle() throws {
    // 往下拼一段后往回滚 1–8 行：画布末尾要丢的行只有全是空白才能丢，有字的一行都不能少
    let rowBytes = Self.width * 4
    for start in stride(from: 100, to: 140, by: 3) {
      for back in 1...8 {
        let first = Self.frame(at: start)
        var stitcher = try Self.stitcher(first)
        let grownTo = start + 60
        _ = stitcher.add(Self.image(Self.frame(at: grownTo)))
        let last = Self.frame(at: grownTo - back)
        _ = stitcher.add(Self.image(last))
        let height = stitcher.outputHeight
        let dropped = (start + height - Self.footer)..<(grownTo + Self.height - Self.footer)
        let lostInk = dropped.contains { y in
          Self.page[y * rowBytes..<(y + 1) * rowBytes].contains { $0 != 255 }
        }
        #expect(!lostInk, "从 \(start) 拼到 \(grownTo) 再回滚 \(back) 行，丢了有字的行")
        Self.expect(
          stitcher.makeImage(), top: start, bottom: start + height, topFrame: first,
          bottomFrame: last)
      }
    }
  }

  @Test func stopsAtMaxHeight() throws {
    var stitcher = try #require(
      ScrollStitcher(
        first: Self.image(Self.frame(at: 0)), scrollbarWidth: Self.scrollbar, maxHeight: 300))
    #expect(stitcher.add(Self.image(Self.frame(at: 90))) == .moved(grown: 90))
    #expect(stitcher.add(Self.image(Self.frame(at: 180))) == .full)
    #expect(stitcher.outputHeight == 290)
  }

  /// 像文字的页面：每 20 行一行字（前 12 行），每列随机有一笔竖画（起止行、深浅随机），上下相邻的行大多一样
  private static let strokes: [UInt8] = {
    var rng = SeededGenerator(state: 7)
    var bytes = [UInt8](repeating: 255, count: width * 4 * 1000)
    for line in 0..<50 {
      for x in 4..<(width - scrollbar - 4) where rng.next() % 3 == 0 {
        let start = Int(rng.next() % 6)
        let length = 3 + Int(rng.next() % 4)
        let gray = UInt8(rng.next() % 120)
        for y in (line * 20 + start)..<(line * 20 + start + length) {
          bytes.replaceSubrange(
            (y * width + x) * 4..<(y * width + x) * 4 + 3, with: [gray, gray, gray])
        }
      }
    }
    return bytes
  }()

  /// 滚到 offset（可以带半像素）的一帧：半像素时每行是相邻两行的平均，像网页内核按小数位置重画的字
  private static func strokesFrame(at offset: Double) -> CGImage {
    let rowBytes = width * 4
    let base = Int(offset)
    var bytes = Array(strokes[base * rowBytes..<(base + height) * rowBytes])
    if offset != Double(base) {
      for index in bytes.indices where index % 4 != 3 {
        bytes[index] = UInt8(
          (Int(bytes[index]) + Int(strokes[index + rowBytes + base * rowBytes])) / 2)
      }
    }
    return image(bytes)
  }

  @Test func stitchesFractionalScrolling() throws {
    // 2026-10-17 用户在 macOS 27 上对着 Claude 的对话长截图「一直对不上」：网页内核的滚动停在小数像素上，滚过之后
    // 有字的行没有一行逐字节相同。整像素、半像素交替着滚，每一帧都要接上，长度差不出一两行
    var stitcher = try #require(
      ScrollStitcher(
        first: Self.strokesFrame(at: 100), scrollbarWidth: Self.scrollbar, maxHeight: 100_000))
    for offset in [130.5, 161, 191.5, 236, 270.5] {
      guard case .moved(let grown) = stitcher.add(Self.strokesFrame(at: offset)) else {
        Issue.record("滚到 \(offset) 没对上")
        return
      }
      #expect(grown > 0)
    }
    #expect(abs(stitcher.outputHeight - (270 + Self.height - 100)) <= 2)
    // 一下滚出一整屏照样对不上，不误接
    #expect(stitcher.add(Self.strokesFrame(at: 600.5)) == .lost)
  }

  /// 预览取长图的哪一段（面板上滚轮浏览）：跟随最近接的那头、from 夹进范围、整张放得下时只有一段
  @Test func previewRangePicksSegment() {
    let rows = 100..<400
    func range(_ visible: Int, _ from: Int?, _ up: Bool = false) -> Range<Int> {
      ScrollStitcher.previewRange(rows: rows, visible: visible, from: from, growingUp: up)
    }
    // 跟随：往下接看末尾那段，往上接看开头那段
    #expect(range(80, nil) == 320..<400)
    #expect(range(80, nil, true) == 100..<180)
    // from 给到哪看哪，越界夹住
    #expect(range(80, 200) == 200..<280)
    #expect(range(80, 0) == 100..<180)
    #expect(range(80, 9000) == 320..<400)
    // 整张都放得下：两头一样，from 也只能是这一段
    #expect(range(500, nil, true) == rows)
    #expect(range(500, 250) == rows)
    // 预览框放不下一行、长图还空着：空段（preview 返回 nil）
    #expect(range(0, nil).isEmpty)
    #expect(
      ScrollStitcher.previewRange(rows: 0..<0, visible: 80, from: 5, growingUp: false).isEmpty)
  }

  @Test func refusesAmbiguousRepeatingContent() throws {
    // 整页都是同一小段（周期 20 行）重复：往哪个整周期位移都对得上，分不出来就不接
    let rowBytes = Self.width * 4
    let tile = Array(Self.page[0..<20 * rowBytes])
    let repeated = Array((0..<(Self.height / 20 + 10)).map { _ in tile }.joined())
    func frame(_ offset: Int) -> CGImage {
      Self.image(Array(repeated[offset * rowBytes..<(offset + Self.height) * rowBytes]))
    }
    var stitcher = try #require(
      ScrollStitcher(first: frame(0), scrollbarWidth: Self.scrollbar, maxHeight: 100_000))
    let outcome = stitcher.add(frame(47))
    #expect(outcome == .lost || outcome == .moved(grown: 47))
  }
}

/// 测试要可复现：固定种子的 SplitMix64
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
