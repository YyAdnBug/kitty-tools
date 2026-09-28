// 片段占位符（不区分大小写；体检 A7）：{date} 当天日期（yyyy-MM-dd）、{time} 时间（HH:mm）、{datetime}（yyyy-MM-dd HH:mm）、
// {weekday} 星期（「星期六」）、{uuid} 随机 UUID（每处各一个）、{clipboard} / {clipboard:0} 粘贴时剪贴板里的文本、
// {clipboard:N}（N = 1…9）全部历史里第 N 条文本（跳过图片、文件和片段：刚粘过的片段排在最前，不跳过会取到它自己；取不到就是空）、
// {cursor} → 去掉，同时算出它后面还有几个字：粘贴落地后按这么多次 ← 把光标挪回去（Alfred / Raycast 的做法，
// mac-clipboard §4 N17）。只认第一个 {cursor}，其余的直接去掉。

import Foundation

nonisolated enum Snippet {
  /// 提示里列的全部占位符（新建片段对话框），每个一句话
  static let placeholderHelp =
    "{date} 日期、{time} 时间、{datetime} 日期和时间、{weekday} 星期几、{uuid} 随机编号、"
    + "{clipboard} 当前剪贴板、{clipboard:1}–{clipboard:9} 历史第 N 条文字（不算片段）、{cursor} 粘贴后光标停在这里"

  /// clipboard：粘贴时剪贴板里的文本；history(n)：历史第 n 条文本（1 起）。两者都只在用到时才读。
  /// charactersAfterCursor：展开后 {cursor} 之后的字数（字形簇，和 ← 一次挪一个字对应）；没有 {cursor} 是 0
  static func expand(
    _ text: String, clipboard: () -> String?, history: (Int) -> String? = { _ in nil },
    now: Date = .now, timeZone: TimeZone = .current
  ) -> (text: String, charactersAfterCursor: Int) {
    let placeholder =
      /\{(date|time|datetime|weekday|uuid|clipboard(?::(\d))?|cursor)\}/.ignoresCase()
    guard text.contains(placeholder) else { return (text, 0) }
    var clipboardCache: String?
    func clipboardText() -> String {
      if let clipboardCache { return clipboardCache }
      let text = clipboard() ?? ""
      clipboardCache = text
      return text
    }
    func format(_ pattern: String, locale: String = "en_US_POSIX") -> String {
      // 固定格式、按本地时区：不跟系统的 12 / 24 小时制和语言走（ISO8601FormatStyle 默认 UTC，凌晨会差一天）
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: locale)
      formatter.timeZone = timeZone
      formatter.dateFormat = pattern
      return formatter.string(from: now)
    }
    func fill(_ part: Substring) -> String {
      String(part).replacing(placeholder) { match in
        switch match.1.lowercased() {
        case "date": format("yyyy-MM-dd")
        case "time": format("HH:mm")
        case "datetime": format("yyyy-MM-dd HH:mm")
        case "weekday": format("EEEE", locale: "zh-Hans")
        case "uuid": UUID().uuidString
        case "cursor": ""
        default:  // clipboard / clipboard:N
          match.2.flatMap { Int($0) }.map { $0 == 0 ? clipboardText() : history($0) ?? "" }
            ?? clipboardText()
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
