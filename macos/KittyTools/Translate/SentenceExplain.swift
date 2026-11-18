// 句子讲解（issue #35，2026-11-18 拍板，PLAN §10「翻译讲解与附加要求」）：翻译浮窗里遇到「一句外文、译成第一语言」时，
// 打开了「讲解外文句子」的大模型服务（TranslateService.explainsSentences）给出译文 + 重点词 + 句型。
// 这里只有两样：这句讲不讲（applies），和给模型照着写的完整示例（example）——免费的 glm-4-flash 会把写成说明的格式要求
// 原样抄出来，所以格式靠示例（mac-translate §5.2）；示例在请求里写成前面的一问一答（Zhipu.messages / AIService.stream，联网实测）。

import Foundation
import NaturalLanguage

nonisolated enum SentenceExplain {
  /// 原文估出来最多多少 token 还讲（LongText.weight：约 300 个字母 / 100 个汉字）。讲解是译文的好几倍长，内置智谱一次只能出 1024，
  /// 更长的照常翻译
  static let maxWeight = 100.0

  /// 这次讲不讲：原文是外文（不是第一语言）、译成第一语言（讲解用第一语言写）、只有一句、不长。source 是固定的源语言或检测结果
  static func applies(_ text: String, source: Lang?, target: Lang, first: Lang) -> Bool {
    guard let source, !source.isSameLanguage(as: first), target.isSameLanguage(as: first) else {
      return false
    }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, LongText.weight(text) <= maxWeight else { return false }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    return tokenizer.tokens(for: text.startIndex..<text.endIndex).count == 1
  }

  /// 照着写的完整示例：讲解用中文时是一句英文，别的语言是一句中文（同 WordLookup.example 的分法）。
  /// 段落标题和读音的写法就是卡片上看到的样子（块级 Markdown：粗体标题、- 列表）
  static func example(to target: Lang) -> (sentence: String, entry: String) {
    if target.isSameLanguage(as: .zhHans) {
      return (
        "She had barely sat down when the phone rang again.",
        """
        她刚坐下，电话就又响了。

        **重点词汇**
        - barely /ˈbeəli/ adv. 几乎不；刚刚——这里和 when 连用，表示「刚……就……」
        - sit down 坐下（sat 是过去式）
        - ring /rɪŋ/ v. （电话、铃）响——rang 是过去式

        **句型**
        had barely done … when …：主句用过去完成时，表示先发生的动作；when 引导的从句用一般过去时，表示紧接着发生的事。
        """
      )
    }
    return (
      "他一进门就开始下雨了。",
      """
      It started raining as soon as he came in.

      **Key words**
      - 一……就…… yī… jiù… as soon as
      - 进门 jìn mén v. to come in through the door
      - 下雨 xià yǔ v. to rain

      **Sentence pattern**
      一 + verb + 就 + verb: the second action happens right after the first. 他一进门 is the first action and \
      就开始下雨了 the second; 了 marks the change.
      """
    )
  }
}
