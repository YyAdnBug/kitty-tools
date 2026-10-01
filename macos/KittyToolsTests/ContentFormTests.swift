// ContentForm / Snippet / Lens 单测：颜色解析、JSON / 链接 / 代码识别、片段占位符与 {cursor} 偏移、透镜定高表；
// 语法着色与放大卡页眉黑白字。

import AppKit
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
    #expect(expanded.text == "日期 \(expected)，剪贴板 abc")
    #expect(expanded.charactersAfterCursor == 0)
    var asked = false
    #expect(
      Snippet.expand(
        "{date}",
        clipboard: {
          asked = true
          return nil
        }, now: date
      ).text == expected)
    #expect(!asked)  // 没用到 {clipboard} 就不读剪贴板
    #expect(Snippet.expand("无占位符 {other}", clipboard: { nil }) == ("无占位符 {other}", 0))
  }

  /// 体检 A7 新增的占位符：时间、日期时间、星期（中文）、UUID（每处各一个）、历史第 N 条（0 = 当前剪贴板），不分大小写；
  /// 固定 now 和时区
  @Test func snippetMorePlaceholders() throws {
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    // 2026-09-26 13:05（周六，东京）
    let date = Date(timeIntervalSince1970: 1_790_395_500)
    let history = ["第一条", "第二条"]
    let expanded = Snippet.expand(
      "{TIME}|{datetime}|{weekday}|{clipboard:0}|{clipboard:2}|{clipboard:9}|{clipboard}",
      clipboard: { "当前" }, history: { $0 <= history.count ? history[$0 - 1] : nil }, now: date,
      timeZone: tokyo)
    #expect(expanded.text == "13:05|2026-09-26 13:05|星期六|当前|第二条||当前")
    let uuids = Snippet.expand("{uuid} {uuid}", clipboard: { nil }).text.split(separator: " ")
    #expect(
      uuids.count == 2 && uuids[0] != uuids[1]
        && uuids.allSatisfy { UUID(uuidString: String($0)) != nil })
    // 只用到历史时不读剪贴板
    var asked = false
    _ = Snippet.expand(
      "{clipboard:1}",
      clipboard: {
        asked = true
        return nil
      }, history: { _ in "x" })
    #expect(!asked)
  }

  /// {cursor}：展开后它后面的字数（按字形簇，和 ← 一次挪一个字对应）；只认第一个，其余去掉
  @Test func snippetCursorOffset() {
    let result = Snippet.expand("Hi {Cursor}, see {clipboard}{cursor}!", clipboard: { "今天" })
    #expect(result.text == "Hi , see 今天!")
    #expect(result.charactersAfterCursor == 9)
    #expect(Snippet.expand("{cursor}", clipboard: { nil }) == ("", 0))
    #expect(Snippet.expand("a{cursor}b\r\nc👍🏽", clipboard: { nil }).charactersAfterCursor == 4)
    #expect(Snippet.expand("前{cursor}", clipboard: { nil }) == ("前", 0))
  }

  /// 透镜正文按类型定高（查表，不量内在尺寸）：前缀和、滚动、窗口预留都靠它
  @Test func lensHeights() {
    func text(_ value: String) -> ClipItem {
      var item = ClipItem(kind: .text)
      item.text = value
      return item
    }
    // 行标题已经原样显示全的一行字没有正文区（同一句话不画第二遍）：首尾空白、末尾的换行不算差别
    #expect(Lens.bodyHeight(for: text("  一句短话  "), form: nil) == 0)
    #expect(Lens.bodyHeight(for: text("git status\n"), form: nil) == 0)
    #expect(Lens.height(for: text("一句短话"), form: nil) == 70)
    // VoiceOver 也不把同一句话念两遍：没有正文区的只说类型
    #expect(Lens.accessibilityValue(for: text("一句短话"), form: nil) == "文本")
    #expect(Lens.accessibilityValue(for: text("两行\n文本"), form: nil) == "文本 · 两行\n文本")
    // 一行但标题列放不下、或者标题把连续空白压成了一个空格（不是原样）：还是两行高的正文
    #expect(Lens.bodyHeight(for: text(String(repeating: "长", count: 60)), form: nil) == 36)
    #expect(Lens.bodyHeight(for: text("a\tb"), form: nil) == 36)
    #expect(Lens.bodyHeight(for: text(String(repeating: "长", count: 61)), form: nil) == 90)
    #expect(Lens.bodyHeight(for: text("两行\n文本"), form: nil) == 90)
    #expect(Lens.bodyHeight(for: text("x"), form: .code) == 128)
    #expect(Lens.bodyHeight(for: text("{}"), form: .json) == 128)
    #expect(Lens.bodyHeight(for: text("#fff"), form: .color) == 72)
    #expect(Lens.bodyHeight(for: text("https://a.com"), form: .link) == 90)
    #expect(Lens.bodyHeight(for: ClipItem(kind: .image), form: nil) == 108)
    #expect(Lens.bodyHeight(for: ClipItem(kind: .file), form: nil) == 76)
    #expect(Lens.height(for: text("{}"), form: .json) == 198)  // 最高的透镜
    #expect(Lens.reserve == 198 - ClipRowView.height)
  }

  /// 行标题有没有把整条文本原样显示全（透镜要不要正文区）：只看条目自己的数据。标题列最窄 342 pt
  /// （右侧文字那一格不管字多短都占满 220），带格式 / 片段 / 收藏标记再各占一点
  @Test func rowShowsWholeText() {
    func text(_ count: Int, _ change: (inout ClipItem) -> Void = { _ in }) -> ClipItem {
      text(String(repeating: "字", count: count), change)  // 13 pt 下一个字约 12.9 pt 宽
    }
    func text(_ value: String, _ change: (inout ClipItem) -> Void = { _ in }) -> ClipItem {
      var item = ClipItem(kind: .text, sourceName: "Safari")
      item.text = value
      change(&item)
      return item
    }
    #expect(ClipRowView.showsWholeText(text("大合唱练歌") { $0.richType = .html }))
    #expect(ClipRowView.showsWholeText(text(26)))
    #expect(!ClipRowView.showsWholeText(text(27)))
    // 备注、来源名多长都一样；三个标记一共占掉 76
    #expect(ClipRowView.showsWholeText(text(26) { $0.note = String(repeating: "备注", count: 20) }))
    func marked(_ count: Int) -> ClipItem {
      text(count) {
        $0.richType = .rtf
        $0.isSnippet = true
        $0.favorite = true
      }
    }
    #expect(ClipRowView.showsWholeText(marked(20)))
    #expect(!ClipRowView.showsWholeText(marked(21)))
    // 不是一行、标题不是原样、不是文本
    #expect(!ClipRowView.showsWholeText(text("两行\n文本")))
    #expect(!ClipRowView.showsWholeText(text("a  b")))
    #expect(!ClipRowView.showsWholeText(text(String(repeating: "x", count: 401))))
    #expect(!ClipRowView.showsWholeText(ClipItem(kind: .image)))
    var file = ClipItem(kind: .file)
    file.filePaths = ["/tmp/a.txt"]
    #expect(!ClipRowView.showsWholeText(file))
  }

  @Test func syntaxHighlight() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    func color(_ text: String, _ language: SyntaxHighlight.Language, at token: String) -> NSColor? {
      let attributed = SyntaxHighlight.attributed(text, language: language, font: font)
      let range = (text as NSString).range(of: token)
      return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
        as? NSColor
    }
    let json = #"{"name": "kitty", "count": 12, "ok": true}"#
    #expect(color(json, .json, at: #""name""#) == .systemBlue)  // 键
    #expect(color(json, .json, at: #""kitty""#) == .systemRed)  // 字符串值
    #expect(color(json, .json, at: "12") == .systemPurple)
    #expect(color(json, .json, at: "true") == .systemPink)
    let code = "let x = 42 // answer\nreturn \"ok\""
    #expect(color(code, .code, at: "let") == .systemPink)
    #expect(color(code, .code, at: "// answer") == .secondaryLabelColor)
    #expect(color(code, .code, at: "42") == .systemPurple)
    #expect(color(code, .code, at: #""ok""#) == .systemRed)
    #expect(color("let x", .plain, at: "let") == .labelColor)  // 纯文本不着色
  }

  @Test func inspectorHeaderText() {
    // 备忘录黄、浅灰上用黑字；系统蓝、深紫上用白字；中等亮度的蓝压暗到白字够 4.5 : 1
    #expect(
      PreviewView.headerStyle(for: NSColor(srgbRed: 0.96, green: 0.77, blue: 0, alpha: 1)).darkText)
    #expect(PreviewView.headerStyle(for: NSColor(white: 0.85, alpha: 1)).darkText)
    #expect(
      !PreviewView.headerStyle(for: NSColor(srgbRed: 0.12, green: 0.45, blue: 0.9, alpha: 1))
        .darkText)
    #expect(
      !PreviewView.headerStyle(for: NSColor(srgbRed: 0.35, green: 0.2, blue: 0.6, alpha: 1))
        .darkText)
    let mid = PreviewView.headerStyle(for: NSColor(srgbRed: 0.3, green: 0.55, blue: 0.95, alpha: 1))
    #expect(!mid.darkText)
    let rgb = mid.background
    func linear(_ v: CGFloat) -> CGFloat {
      v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    let luminance =
      0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
      + 0.0722 * linear(rgb.blueComponent)
    #expect(1.05 / (luminance + 0.05) >= 4.5)
  }

  @Test func syntaxHighlightSkipsCommentsInStrings() {
    let text = #"let u = "https://a.b" // note"#
    let result = SyntaxHighlight.attributed(
      text, language: .code, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    let url = (text as NSString).range(of: "a.b")
    let note = (text as NSString).range(of: "note")
    #expect(
      result.attribute(.foregroundColor, at: url.location, effectiveRange: nil) as? NSColor
        == .systemRed)
    #expect(
      result.attribute(.foregroundColor, at: note.location, effectiveRange: nil) as? NSColor
        == .secondaryLabelColor)
  }

  @Test func translucentColorValues() {
    let values = ColorCard.values(.init(red: 1, green: 0, blue: 0, alpha: 0.5))
    #expect(values[0] == "#FF000080")
    #expect(values[2].hasPrefix("hsla("))
    #expect(values[3].hasSuffix("opacity: 0.50)"))
  }

}
