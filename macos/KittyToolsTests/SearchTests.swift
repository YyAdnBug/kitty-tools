// Search 单测：AND 分词、忽略大小写 / 全半角、按字段权重排序、同分按时间。

import Foundation
import Testing

@testable import KittyTools

struct SearchTests {
  private func item(_ text: String?, note: String? = nil, ocr: String? = nil, ago: TimeInterval = 0)
    -> ClipItem
  {
    var item = ClipItem(kind: .text, copiedAt: Date.now.addingTimeInterval(-ago))
    item.text = text
    item.note = note
    item.ocrText = ocr
    return item
  }

  @Test func emptyQueryKeepsOrder() {
    let items = [item("a"), item("b")]
    #expect(Search.rank(items, query: "  ") == items)
  }

  @Test func allTokensMustMatch() {
    let items = [item("hello world"), item("hello")]
    #expect(Search.rank(items, query: "world HELLO").map(\.text) == ["hello world"])
  }

  @Test func widthAndCaseInsensitive() {
    #expect(Search.rank([item("ＡＢＣ全角")], query: "abc").count == 1)
  }

  @Test func noteOutranksBodyAndTiesGoNewestFirst() {
    let body = item("json 正文", ago: 1)
    let noted = item("别的", note: "json 备注", ago: 5)
    let older = item("json 更早", ago: 10)
    #expect(
      Search.rank([older, body, noted], query: "json").map(\.text) == ["别的", "json 正文", "json 更早"])
  }

  @Test func matchesImageText() {
    var image = ClipItem(kind: .image)
    image.ocrText = "截图里的发票号码"
    #expect(Search.rank([image], query: "发票").count == 1)
  }
}
