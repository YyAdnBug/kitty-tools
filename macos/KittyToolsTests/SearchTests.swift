// Search 单测：AND 分词、忽略大小写 / 全半角、只过滤不排序（体检 A6：顺序和没有搜索词时一样）；命中摘录（行标题和透镜正文）。

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
    #expect(Search.filter(items, query: "  ") == items)
  }

  @Test func allTokensMustMatch() {
    let items = [item("hello world"), item("hello")]
    #expect(Search.filter(items, query: "world HELLO").map(\.text) == ["hello world"])
  }

  @Test func widthAndCaseInsensitive() {
    #expect(Search.filter([item("ＡＢＣ全角")], query: "abc").count == 1)
  }

  /// 只过滤：备注、正文、来源都能搜到，顺序保持传进来的（复制时间新→旧），备注命中不往前排；词可以分别命中不同字段
  @Test func filterKeepsOrder() {
    let body = item("json 正文", ago: 1)
    let noted = item("别的", note: "json 备注", ago: 5)
    var source = item("来自微信", ago: 7)
    source.sourceName = "json 工具"
    let older = item("json 更早", ago: 10)
    let items = [body, noted, source, older]
    #expect(
      Search.filter(items, query: "json").map(\.text) == ["json 正文", "别的", "来自微信", "json 更早"])
    #expect(Search.filter(items, query: "备注 别的").map(\.text) == ["别的"])
  }

  @Test func matchesImageText() {
    var image = ClipItem(kind: .image)
    image.ocrText = "截图里的发票号码"
    #expect(Search.filter([image], query: "发票").count == 1)
  }

  @Test func excerptStartsNearFirstHit() throws {
    let text = String(repeating: "前", count: 100) + "命中词" + String(repeating: "后", count: 100)
    let excerpt = try #require(Search.excerpt(of: text, query: "命中", before: 40, after: 40))
    #expect(
      excerpt == "…" + String(repeating: "前", count: 40) + "命中词" + String(repeating: "后", count: 39)
        + "…")
    // 几个词取最靠前的命中；比较口径同搜索（全半角、大小写）
    #expect(Search.excerpt(of: text, query: "后 命中", before: 2, after: 1) == "…前前命中词…")
    #expect(
      Search.excerpt(of: "0123456789ＳｗｉｆｔＵＩ!", query: "swiftui", before: 3, after: 5)
        == "…789ＳｗｉｆｔＵＩ!")
  }

  @Test func excerptNilWhenHitIsNearStartOrMissing() {
    #expect(Search.excerpt(of: "hello world", query: "world", before: 40) == nil)  // 从头显示就看得到
    #expect(Search.excerpt(of: "0123456789abc", query: "abc", before: 10) == nil)  // 正好从头开始，不补「…」
    #expect(Search.excerpt(of: "hello world", query: "zzz") == nil)
    #expect(Search.excerpt(of: "hello world", query: "  ") == nil)
    #expect(Search.firstHit(in: "abc", query: "") == nil)
  }
}
