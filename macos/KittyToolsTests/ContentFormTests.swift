// ContentForm / Snippet 单测：颜色解析、JSON / 链接 / 代码识别、片段占位符。

import Foundation
import Testing

@testable import KittyTools

struct ContentFormTests {
  @Test func colors() throws {
    let red = try #require(ContentForm.color(in: " #f00 "))
    #expect(red == .init(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(ContentForm.color(in: "#00ff0080")?.alpha == Double(0x80) / 255)
    #expect(
      ContentForm.color(in: "rgba(0, 0, 255, 0.5)") == .init(red: 0, green: 0, blue: 1, alpha: 0.5))
    let green = try #require(ContentForm.color(in: "hsl(120, 100%, 50%)"))
    #expect(abs(green.green - 1) < 0.001 && green.red < 0.001)
    #expect(ContentForm.color(in: "#12345") == nil)
    #expect(ContentForm.color(in: "rgb(1, 2)") == nil)
    #expect(ContentForm.detect("#ABCDEF") == .color)
  }

  @Test func jsonLinkCode() {
    #expect(ContentForm.detect(#"{"a": [1, 2]}"#) == .json)
    #expect(ContentForm.detect("{not json") != .json)
    #expect(ContentForm.detect("https://example.com/a?b=1") == .link)
    #expect(ContentForm.detect("看这个 https://example.com") == nil)  // 夹在句子里不算「链接」形态
    #expect(ContentForm.firstLink(in: "看这个 https://example.com/x。")?.host() == "example.com")
    #expect(ContentForm.detect("import SwiftUI\nstruct A {}") == .code)
    #expect(ContentForm.detect("SELECT *\nFROM t") == .code)
    #expect(ContentForm.detect("今天天气不错\n明天也是") == nil)
  }

  @Test func snippetPlaceholders() {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let expected = date.formatted(
      Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
    let expanded = Snippet.expand(
      "日期 {DATE}，剪贴板 {clipboard}{cursor}", clipboard: { "abc" }, now: date)
    #expect(expanded == "日期 \(expected)，剪贴板 abc")
    var asked = false
    #expect(
      Snippet.expand(
        "{date}",
        clipboard: {
          asked = true
          return nil
        }, now: date) == expected)
    #expect(!asked)  // 没用到 {clipboard} 就不读剪贴板
    #expect(Snippet.expand("无占位符 {other}", clipboard: { nil }) == "无占位符 {other}")
  }
}
