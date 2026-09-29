// 启动器的匹配与排序（纯函数，配单测）。查询按空白分词，每个词都要命中某个名字（AND），各词取最好的一档、
// 整体取最差的那个词：完全相同 100 > 名字开头 80 > 词首 60 > 首字母缩写开头 50 > 子串 40。
// 缩写让 vsc 能搜到 Visual Studio Code；中文名另有拼音全拼和首字母。
// 最终分 = 匹配分 ×（1 + 0.5·f/(f+3) + 1.0·a/(a+2)），f / a 是全局 / 同查询的使用分（两项都饱和：用得再多，加成最多 ×2.5）。

import Foundation

nonisolated enum LauncherMatch {
  static func fold(_ text: String) -> String {
    text.folding(options: Search.options, locale: nil)
  }

  /// 首字母缩写：按空格 / 标点 / 驼峰分词取首字母（AppCleaner → ac，Visual Studio Code → vsc）
  static func initials(_ name: String) -> String {
    var result = ""
    var previous: Character?
    for character in name {
      let isWordChar = character.isLetter || character.isNumber
      let startsWord =
        isWordChar
        && (previous.map { !($0.isLetter || $0.isNumber) } ?? true
          || (character.isUppercase && previous?.isLowercase == true))
      if startsWord { result.append(character) }
      previous = character
    }
    return fold(result)
  }

  /// 0 表示不匹配
  static func score(_ query: String, item: LauncherItem) -> Double {
    let whole = fold(query.trimmingCharacters(in: .whitespaces))
    guard !whole.isEmpty else { return 0 }
    let tokens = whole.split(whereSeparator: \.isWhitespace).map(String.init)
    // 带空格的整句（「visual studio」）先整体比一次，再逐词比，取好的那个
    let perToken = tokens.map { tier($0, item) }.min() ?? 0
    return tokens.count > 1 ? max(tier(whole, item), perToken) : perToken
  }

  private static func tier(_ token: String, _ item: LauncherItem) -> Double {
    var best: Double = 0
    for name in item.names {
      if name == token { return 100 }
      if name.hasPrefix(token) {
        best = max(best, 80)
      } else if name.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        .contains(where: { $0.hasPrefix(token) })
      {
        best = max(best, 60)
      } else if name.contains(token) {
        best = max(best, 40)
      }
    }
    if best < 50, token.count >= 2, item.initials.contains(where: { $0.hasPrefix(token) }) {
      best = 50
    }
    return best
  }

  /// 同分时的先后（体检 B36）：系统命令最后。它的中文标题只有两三个字、英文名又在 names 里，只比标题长短的话
  /// 「sl」会把没用过的 Slack 排到「睡眠」后面，↩ 下去电脑就睡了。内置动作「退出 Kitty Tools」（MenuExtra.quit）
  /// 同理：↩ 不确认，「退出」「qu」同分时要排在「全部退出」、QuickTime Player 后面
  static func priority(_ item: LauncherItem) -> Int {
    item.kind == .system || (item.kind == .action && item.target == "quit") ? 1 : 0
  }

  /// 匹配、加使用加成、排序；同分先按 priority（系统命令、退出本 App 最后），再标题短的在前，再按原顺序
  static func rank(
    _ items: [LauncherItem], query: String, boost: (LauncherItem) -> (global: Double, query: Double)
  ) -> [LauncherItem] {
    items.enumerated().compactMap { index, item -> (LauncherItem, Double, Int)? in
      let match = score(query, item: item)
      guard match > 0 else { return nil }
      let (f, a) = boost(item)
      return (item, match * (1 + 0.5 * f / (f + 3) + a / (a + 2)), index)
    }
    .sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      let (a, b) = (priority($0.0), priority($1.0))
      if a != b { return a < b }
      if $0.0.title.count != $1.0.title.count { return $0.0.title.count < $1.0.title.count }
      return $0.2 < $1.2
    }
    .map(\.0)
  }
}
