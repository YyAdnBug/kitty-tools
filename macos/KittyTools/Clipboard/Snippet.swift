// 片段占位符（名字不区分大小写；体检 A7）：{date} 当天日期（yyyy-MM-dd）、{time} 时间（HH:mm）、{datetime}（yyyy-MM-dd HH:mm）、
// {weekday} 星期（跟着界面语言：「星期六」/「Saturday」）、{uuid} 随机 UUID（每处各一个）、{clipboard} / {clipboard:0} 粘贴时剪贴板里的文本、
// {clipboard:N}（N = 1…9）全部历史里第 N 条文本（跳过图片、文件和片段：刚粘过的片段排在最前，不跳过会取到它自己；取不到就是空）、
// {cursor} → 去掉，同时算出它后面还有几个字：粘贴落地后按这么多次 ← 把光标挪回去（Alfred / Raycast 的做法，
// mac-clipboard §4 N17）。只认第一个 {cursor}，其余的直接去掉。
// 第四轮体检 X20（2026-11-17，对标 Raycast 的动态占位符）：
// - 日期时间能偏移、自定格式：{date+1d}、{date-2w:yyyy/MM/dd}、{time+30m}、{weekday+1d}、{datetime:M月d日 HH:mm}。偏移可以连写
//   （{date+1M-1d}），单位区分大小写：m 分钟、h 小时、d 天、w 周、M 月、y 年；格式是 Unicode 日期格式（月份、星期的名字跟界面语言），
//   不写格式的照旧固定格式。格式只认「像日期格式」的：冒号后面紧跟着字（不是空格）、没有 %、英文字母都是日期格式用的那些
//   （单引号里的原样）——`{time: 30}`（JS 对象）、`{date:%Y-%m-%d}`（Python 的 f-string）照旧原样留着（评审 A1 B6）。
// - 填空：{input}、{input:称呼}。粘贴 / 复制前在剪贴板面板里一个个问（同一个名字只问一次、几处都填它；没写名字的几处
//   算同一个空），Esc 不粘。不问的那条路（拖出去）inputs 给 nil：{input…} 原样留着，不悄悄填成空的。
// 认不出的 {…}（片段里的 JSON、模板语法）原样留着。

import Foundation

nonisolated enum Snippet {
  /// 对话框里列的全部占位符（编辑片段、新建片段），每个一句话
  static let placeholderHelp: LocalizedStringResource =
    "占位符：{date} 日期、{time} 时间、{datetime} 日期和时间、{weekday} 星期几（能加偏移和格式：{date+1d}、{date-1w:yyyy/MM/dd}；单位 m 分钟、h 小时、d 天、w 周、M 月、y 年）、{uuid} 随机编号、{clipboard} 当前剪贴板、{clipboard:1}–{clipboard:9} 历史第 N 条文字（不算片段）、{input:称呼} 粘贴前填空、{cursor} 粘贴后光标停在这里"

  // Regex 不是 Sendable、不能存成 static let：每次现建（编译期就解析好了，便宜）
  /// 花括号里的一段（不跨行、不嵌套）
  private static var token: Regex<(Substring, Substring)> { /\{([^{}\n]+)\}/ }
  private static var input: Regex<(Substring, Substring?)> { /(?i:input)(?::(.*))?/ }
  private static var dated: Regex<(Substring, Substring, Substring, Substring?)> {
    /((?i:datetime|date|time|weekday))((?:[+-][0-9]{1,4}[mhdwMy])*)(?::(.*))?/
  }
  private static var offset: Regex<(Substring, Substring, Substring, Substring)> {
    /([+-])([0-9]{1,4})([mhdwMy])/
  }

  /// 片段里要先问的空（{input:名字} 的名字，没写名字是空串），按出现顺序、同名只算一次
  static func inputs(in text: String) -> [String] {
    var seen = Set<String>()
    return text.matches(of: token).compactMap { match in
      guard let name = (try? input.wholeMatch(in: match.1)).map({ label($0.1) }),
        seen.insert(name).inserted
      else { return nil }
      return name
    }
  }

  /// 日期格式里能用的字母（Unicode 日期格式的那些）
  private static let patternLetters = Set("GyYuUrQqMLlwWdDFgEecabBhHKkjJCmsSAzZOvVXx")

  /// 冒号后面这段像不像日期格式（纯函数）：开头不是空白、没有 %、单引号外面的英文字母都是格式字母。空的算（用默认格式）
  static func isDateFormat(_ format: Substring) -> Bool {
    guard !format.isEmpty else { return true }
    guard let first = format.first, !first.isWhitespace, !format.contains("%") else { return false }
    var quoted = false
    for character in format {
      if character == "'" {
        quoted.toggle()
      } else if !quoted, character.isASCII, character.isLetter,
        !patternLetters.contains(character)
      {
        return false
      }
    }
    return true
  }

  private static func label(_ raw: Substring?) -> String {
    raw.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
  }

  /// clipboard：粘贴时剪贴板里的文本；history(n)：历史第 n 条文本（1 起）。两者都只在用到时才读。
  /// inputs：填空填的字（按 inputs(in:) 的名字）；没填的是空；nil = 没问过（拖出去），{input…} 原样留着。
  /// charactersAfterCursor：展开后 {cursor} 之后的字数（字形簇，和 ← 一次挪一个字对应）；没有 {cursor} 是 0
  static func expand(
    _ text: String, clipboard: () -> String?, history: (Int) -> String? = { _ in nil },
    inputs: [String: String]? = [:], now: Date = .now, timeZone: TimeZone = .current
  ) -> (text: String, charactersAfterCursor: Int) {
    guard text.contains(token) else { return (text, 0) }
    var clipboardCache: String?
    func clipboardText() -> String {
      if let clipboardCache { return clipboardCache }
      let text = clipboard() ?? ""
      clipboardCache = text
      return text
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    func date(_ name: String, offsets: Substring, format: Substring?) -> String {
      var date = now
      for step in offsets.matches(of: offset) {
        let amount = (Int(step.2) ?? 0) * (step.1 == "-" ? -1 : 1)
        let component: Calendar.Component =
          switch step.3 {
          case "m": .minute
          case "h": .hour
          case "d": .day
          case "w": .weekOfYear
          case "M": .month
          default: .year
          }
        date = calendar.date(byAdding: component, value: amount, to: date) ?? date
      }
      // 固定格式、按本地时区：不跟系统的 12 / 24 小时制和语言走（ISO8601FormatStyle 默认 UTC，凌晨会差一天）；
      // 星期几的名字、自定格式里的月份 / 星期名跟着界面语言（Locale.current）
      let formatter = DateFormatter()
      formatter.timeZone = timeZone
      formatter.calendar = calendar
      if let format, !format.trimmingCharacters(in: .whitespaces).isEmpty {
        formatter.locale = .current
        formatter.dateFormat = String(format)
      } else {
        formatter.locale = name == "weekday" ? .current : Locale(identifier: "en_US_POSIX")
        formatter.dateFormat =
          switch name {
          case "date": "yyyy-MM-dd"
          case "time": "HH:mm"
          case "datetime": "yyyy-MM-dd HH:mm"
          default: "EEEE"
          }
      }
      return formatter.string(from: date)
    }
    /// 一个 {…} 换成什么；nil = 不是占位符、原样留着
    func value(_ inside: Substring) -> String? {
      switch inside.lowercased() {
      case "uuid": return UUID().uuidString
      case "cursor": return ""
      case "clipboard", "clipboard:0": return clipboardText()
      case let name where name.wholeMatch(of: /clipboard:[1-9]/) != nil:
        return history(Int(String(name.last!)) ?? 0) ?? ""
      default: break
      }
      if let match = try? input.wholeMatch(in: inside) {
        guard let inputs else { return nil }
        return inputs[label(match.1)] ?? ""
      }
      if let match = try? dated.wholeMatch(in: inside), isDateFormat(match.3 ?? "") {
        return date(match.1.lowercased(), offsets: match.2, format: match.3)
      }
      return nil
    }
    func fill(_ part: Substring) -> String {
      String(part).replacing(token) { match in value(match.1) ?? String(match.0) }
    }
    guard let cursor = text.firstRange(of: /\{cursor\}/.ignoresCase()) else {
      return (fill(text[...]), 0)
    }
    let after = fill(text[cursor.upperBound...])
    return (fill(text[..<cursor.lowerBound]) + after, after.count)
  }
}
