// 长截图拼接单测：合成一张长「页面」（每行不同的墨点、行间空白），按滚动位置裁出帧，盖上固定的吸顶栏、
// 带闪烁光标的页脚和随滚动移动的滚动条，喂给 ScrollStitcher，逐字节核对拼出的长图。
// 覆盖：往下 / 往上拼、页脚光标闪烁（锁住页脚不能估小）、滚太快对不上后往回滚接着拼、画面不动与小变化、
// 滚到底回弹（单帧、多帧）、往回滚不丢有字的行、长度上限、整页重复行时宁可不接。

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
