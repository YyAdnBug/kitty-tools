// 翻译语言：应用内语言、系统语种检测（NaturalLanguage，能分简繁）、源 / 目标解析规则（纯函数，配单测）。
// 模型参照 Bob / Easydict（PLAN §11「翻译语言」）：源 = 自动检测或固定；目标 = 自动或固定；设置里只有第一 / 第二语言。
// - 目标「自动」：原文是第一语言就译成第二语言，否则译成第一语言；
// - 源自动、固定目标正好是原文语言：改按「自动」译，并在界面上写明（fellBack）；
// - 源和目标都固定且相同（旧设置留下的）：目标按「自动」处理。

import Foundation
import NaturalLanguage

nonisolated enum Lang: String, CaseIterable, Codable, Sendable {
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"
  case en, ja, ko, fr, de, es, ru, pt, it

  var title: String {
    switch self {
    case .zhHans: "简体中文"
    case .zhHant: "繁体中文"
    case .en: "英语"
    case .ja: "日语"
    case .ko: "韩语"
    case .fr: "法语"
    case .de: "德语"
    case .es: "西班牙语"
    case .ru: "俄语"
    case .pt: "葡萄牙语"
    case .it: "意大利语"
    }
  }

  /// 英文提示词里用的语言名
  var englishName: String {
    switch self {
    case .zhHans: "Simplified Chinese"
    case .zhHant: "Traditional Chinese"
    case .en: "English"
    case .ja: "Japanese"
    case .ko: "Korean"
    case .fr: "French"
    case .de: "German"
    case .es: "Spanish"
    case .ru: "Russian"
    case .pt: "Portuguese"
    case .it: "Italian"
    }
  }

  /// 朗读用的 BCP-47
  var speechCode: String {
    switch self {
    case .zhHans: "zh-CN"
    case .zhHant: "zh-TW"
    case .en: "en-US"
    case .ja: "ja-JP"
    case .ko: "ko-KR"
    case .fr: "fr-FR"
    case .de: "de-DE"
    case .es: "es-ES"
    case .ru: "ru-RU"
    case .pt: "pt-BR"
    case .it: "it-IT"
    }
  }

  /// 同一种语言（简繁中文算同一种）
  func isSameLanguage(as other: Lang) -> Bool {
    self == other || [self, other].allSatisfy { $0 == .zhHans || $0 == .zhHant }
  }

  private var nlLanguage: NLLanguage {
    switch self {
    case .zhHans: .simplifiedChinese
    case .zhHant: .traditionalChinese
    case .en: .english
    case .ja: .japanese
    case .ko: .korean
    case .fr: .french
    case .de: .german
    case .es: .spanish
    case .ru: .russian
    case .pt: .portuguese
    case .it: .italian
    }
  }

  /// 检测原文语种（只在支持的语言里选），先验偏向 preferred（第一 / 第二语言）。不设置信度门槛：
  /// 短文本靠先验也能给出最可能的一种（实测不加先验「你好」会判成繁体、「API」判成意大利语）；
  /// 只有纯数字、符号这类认不出任何语言的返回 nil
  static func detect(_ text: String, preferring preferred: [Lang] = []) -> Lang? {
    var sample = String(text.prefix(2000))
    // 中日韩文里夹几个英文词（「请帮我 review 一下这个 PR」「iPhone 17 Pro Max 发布了」）会被判成英语 / 德语，
    // 自动模式就成了中译中：CJK 字数不少于拉丁词数时只看 CJK 部分
    let cjk = sample.matches(of: /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/).count
    if cjk > 0, cjk >= sample.matches(of: /[A-Za-z]+/).count {
      sample = sample.replacing(/[A-Za-z0-9]+/, with: " ")
    }
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = allCases.map(\.nlLanguage)
    if !preferred.isEmpty {
      var hints = Dictionary(uniqueKeysWithValues: allCases.map { ($0.nlLanguage, 0.02) })
      for (lang, weight) in zip(preferred, [0.5, 0.3]) { hints[lang.nlLanguage] = weight }
      recognizer.languageHints = hints
    }
    recognizer.processString(sample)
    guard let language = recognizer.dominantLanguage else { return nil }
    return allCases.first { $0.nlLanguage == language }
  }

  /// 一次翻译的方向
  struct Plan: Equatable {
    /// 发给服务的源语言：用户固定了才有；自动时交给服务自己识别（本地检测只用来定目标和显示）
    var from: Lang?
    var to: Lang
    /// 源自动、选的固定目标正好是原文语言，改按「自动」译了
    var fellBack = false
  }

  /// source：nil = 自动检测；target：nil = 自动（第一 ⇄ 第二语言）
  static func resolve(
    source: Lang?, target: Lang?, detected: Lang?, first: Lang, second: Lang
  ) -> Plan {
    let original = source ?? detected
    let auto = original?.isSameLanguage(as: first) == true ? second : first
    guard let target, target != source else { return Plan(from: source, to: auto) }
    // 只比同一种写法：原文简体、目标繁体是用户要的转换，不算「同语言」
    if source == nil, original == target { return Plan(from: nil, to: auto, fellBack: true) }
    return Plan(from: source, to: target)
  }
}

extension Lang {
  /// 设置里的第一 / 第二语言（键名沿用 M4 的 translateNativeLang / translateForeignLang）。
  /// 两个选成同一种时第二语言退回英语（第一语言是英语就退回简体中文）
  static var preferredPair: (first: Lang, second: Lang) {
    let defaults = UserDefaults.standard
    return pair(
      first: defaults.string(forKey: Prefs.translateFirst),
      second: defaults.string(forKey: Prefs.translateSecond))
  }

  /// 视图里用 @AppStorage 的原始值算，改设置时能跟着刷新
  static func pair(first rawFirst: String?, second rawSecond: String?) -> (
    first: Lang, second: Lang
  ) {
    let first = rawFirst.flatMap(Lang.init) ?? .zhHans
    var second = rawSecond.flatMap(Lang.init) ?? .en
    if second.isSameLanguage(as: first) { second = first == .en ? .zhHans : .en }
    return (first, second)
  }
}
