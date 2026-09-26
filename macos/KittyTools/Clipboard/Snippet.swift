// 片段占位符（不区分大小写）：{date} → 当天日期（yyyy-MM-dd），{clipboard} → 粘贴时剪贴板里的文本，
// {cursor} → 去掉，同时算出它后面还有几个字：粘贴落地后按这么多次 ← 把光标挪回去（Alfred / Raycast 的做法，
// mac-clipboard §4 N17）。只认第一个 {cursor}，其余的直接去掉。

import Foundation

nonisolated enum Snippet {
  /// charactersAfterCursor：展开后 {cursor} 之后的字数（字形簇，和 ← 一次挪一个字对应）；没有 {cursor} 是 0
  static func expand(_ text: String, clipboard: () -> String?, now: Date = .now) -> (
    text: String, charactersAfterCursor: Int
  ) {
    let placeholder = /\{(date|clipboard|cursor)\}/.ignoresCase()
    guard text.contains(placeholder) else { return (text, 0) }
    let clipboardText =
      text.localizedCaseInsensitiveContains("{clipboard}") ? clipboard() ?? "" : ""
    func fill(_ part: Substring) -> String {
      String(part).replacing(placeholder) { match in
        switch match.1.lowercased() {
        // ISO8601FormatStyle 默认按 UTC 算日期，必须指定本地时区，否则凌晨会差一天
        case "date":
          now.formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
        case "clipboard": clipboardText
        default: ""
        }
      }
    }
    guard let cursor = text.firstRange(of: /\{cursor\}/.ignoresCase()) else {
      return (fill(text[...]), 0)
    }
    let after = fill(text[cursor.upperBound...])
    return (fill(text[..<cursor.lowerBound]) + after, after.count)
  }
}
