// 一键打码（2026-11-12 拍板 C5）的单测：一行字里认哪几段（手机号、邮箱、过 Luhn 的卡号、过校验位的身份证号）、
// 不认哪些（订单号、半截号码、紧挨着别的数字）、识字框换成视图里的打码框，以及合成图上走一遍真的识字

import CoreGraphics
import Testing

@testable import KittyTools

@MainActor
struct RedactionTests {
  private func found(_ text: String) -> [String] {
    Redaction.ranges(in: text).map { String(text[$0]) }
  }

  @Test func findsPhonesEmailsCardsAndIDs() {
    #expect(found("电话 138 0013 8000，备用 13800138000") == ["138 0013 8000", "13800138000"])
    #expect(found("+86 139-1234-5678") == ["+86 139-1234-5678"])
    #expect(found("邮箱 zhang.xm@example.com 联系") == ["zhang.xm@example.com"])
    #expect(found("卡号 4111 1111 1111 1111") == ["4111 1111 1111 1111"])
    #expect(found("身份证 11010519491231002X") == ["11010519491231002X"])
    #expect(found("a@b.co 和 4111111111111111") == ["a@b.co", "4111111111111111"])
  }

  // 评审实测的漏洞：两个按空格分组的手机号挨着，不能连成一串「卡号」吃掉一个、另一个露出半截；重叠的合成一段
  @Test func adjacentNumbersAreBothCovered() {
    #expect(found("138 0000 8000 139 1820 5678") == ["138 0000 8000", "139 1820 5678"])
    #expect(found("6222 0212 3456 7890 123") == [])  // 19 位但过不了 Luhn
    #expect(found("4111-1111-1111-1111") == ["4111-1111-1111-1111"])
  }

  @Test func leavesOtherNumbersAlone() {
    #expect(found("1731395200123").isEmpty)  // 13 位毫秒时间戳
    #expect(found("2026111200384756 2026111200384757 2026111200384758").isEmpty)  // 2 开头的订单号
    #expect(found("100 200 300 400 500").isEmpty)
    #expect(found("icon@2x.png AppIcon@3x.png").isEmpty)
    #expect(found("110105194913310021").isEmpty)  // 13 月
    #expect(found("910105194912310021").isEmpty)  // 地区码 9 开头
    #expect(found("订单号 2026111200384756").isEmpty)  // 16 位但过不了 Luhn
    #expect(found("验证码 482913，5 分钟内有效").isEmpty)
    #expect(found("12345678901").isEmpty)  // 2 开头不是手机号段
    #expect(found("9138001380001").isEmpty)  // 手机号前面紧挨着数字
    #expect(found("1380013800012345").isEmpty)  // 16 位、过不了 Luhn，也不拆出手机号
    #expect(found("11010519491231002Y").isEmpty)
    #expect(found("110105194912310021").isEmpty)  // 校验位不对
    #expect(found("Q1 ¥1200 +0%").isEmpty)
  }

  @Test func checksums() {
    #expect(Redaction.passesLuhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
    #expect(!Redaction.passesLuhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]))
    #expect(!Redaction.passesLuhn([]))
    #expect(Redaction.isIDNumber("11010519491231002x"))
    #expect(Redaction.isCardNumber([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
    #expect(!Redaction.isCardNumber([1, 7, 3, 1, 3, 9, 5, 2, 0, 0, 1, 2, 3, 4, 5, 6]))  // 1 开头
    #expect(!Redaction.isIDNumber("1101051949123100"))
  }

  /// 识字框（归一化、原点左下）铺到区域上，四周放 3 点、夹回区域；已经被打码盖住的、太小的不要
  @Test func boxesBecomeAreas() {
    let area = CGRect(x: 100, y: 200, width: 400, height: 100)
    let boxes = [
      CGRect(x: 0.1, y: 0.4, width: 0.25, height: 0.2),
      CGRect(x: 0.9, y: 0.9, width: 0.2, height: 0.2),  // 伸出区域：夹回来
      CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001),  // 太小
    ]
    let areas = Redaction.areas(boxes, in: area, existing: [])
    #expect(areas.first == CGRect(x: 137, y: 237, width: 106, height: 26))
    #expect(areas.count == 2 && areas[1].maxX == 500 && areas[1].maxY == 300)
    // 再点一次：已经被这几块盖住，不叠第二层
    let existing = areas.map { Annotation(shape: .mosaic($0)) }
    #expect(Redaction.areas(boxes, in: area, existing: existing).isEmpty)
  }

  /// 合成图上真的识一遍：两处号码都给框，订单号不给
  @Test func recognizesOnARenderedImage() async throws {
    let image = try ScreenshotTests.render([
      "电话 138 0013 8000", "订单号 2026111200384756", "邮箱 kitty@example.com",
    ])
    let boxes = try #require(await OCR.redactionBoxes(in: image))
    #expect(boxes.count == 2, "\(boxes)")
    // 三行从上往下排：电话在最上面那行，邮箱在最下面（归一化坐标原点在左下）
    #expect(boxes.contains { $0.midY > 0.66 } && boxes.contains { $0.midY < 0.34 })
  }
}
