// 飞行卡片（Whisker S1）单测：卡片上的图先按选区比例取顶部、再等比缩进上限，本来就小的原样返回（飞行卡片和常驻缩略图共用）。

import CoreGraphics
import Testing

@testable import KittyTools

struct FlyCardTests {
  private func image(width: Int, height: Int) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }

  @Test func thumbnailFitsLimitKeepingAspect() throws {
    // 5K 宽的选区，落地 200×67 pt、2x 屏：上限 800×268 像素
    let small = FlyCard.thumbnail(
      of: try image(width: 5120, height: 1715), fitting: CGSize(width: 800, height: 268))
    #expect(small.width == 800)
    #expect(small.height == 268)
    #expect(small.colorSpace?.name == CGColorSpace.displayP3)
    // 高的（长截图顶部那屏）按高度缩
    let tall = FlyCard.thumbnail(
      of: try image(width: 1000, height: 3000), fitting: CGSize(width: 800, height: 560))
    #expect(tall.width == 187)
    #expect(tall.height == 560)
  }

  @Test func cardImageCropsToSelectionThenFits() throws {
    // 长截图 1000×3000，选区 2:1：先取顶部 1000×500，再缩进 200×100 pt 卡片的 2 倍（2x 屏 = 800×400 像素）
    let card = FlyCard.cardImage(
      of: try image(width: 1000, height: 3000), frame: CGRect(x: 0, y: 0, width: 500, height: 250),
      size: CGSize(width: 200, height: 100), backingScale: 2)
    #expect(card.width == 800)
    #expect(card.height == 400)
  }

  @Test func thumbnailKeepsSmallImage() throws {
    let original = try image(width: 300, height: 200)
    #expect(FlyCard.thumbnail(of: original, fitting: CGSize(width: 800, height: 560)) === original)
  }
}
