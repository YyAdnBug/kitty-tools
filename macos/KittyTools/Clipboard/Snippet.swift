// 片段占位符（不区分大小写）：{date} → 当天日期（yyyy-MM-dd），{clipboard} → 粘贴时剪贴板里的文本，
// {cursor} → 去掉。ponytail: {cursor} 还不会把光标挪到该处（要在粘贴完成后按左方向键，时序难保证），
// 和旧版一致，见 PLAN §11。

import Foundation

nonisolated enum Snippet {
  static func expand(_ text: String, clipboard: () -> String?, now: Date = .now) -> String {
    let placeholder = /\{(date|clipboard|cursor)\}/.ignoresCase()
    guard text.contains(placeholder) else { return text }
    let clipboardText =
      text.localizedCaseInsensitiveContains("{clipboard}") ? clipboard() ?? "" : ""
    return text.replacing(placeholder) { match in
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
}
