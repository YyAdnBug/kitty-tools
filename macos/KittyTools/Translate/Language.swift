// 翻译语言：应用内语言、系统语种检测（NaturalLanguage，能分简繁）、源 / 目标解析规则（纯函数，配单测）。
// 规则（原生重新设计，不沿用旧版的双向互译四分支）：
// - 目标选「智能」：原文是母语就译成常用外语，否则译成母语；
// - 目标选了固定语言但和原文同属一种语言（简繁算同一种）：改译成另一端，免得「中文译中文」。

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

  /// 检测原文语种（只在支持的语言里选）；太短或拿不准返回 nil，交给翻译服务自己判断
  static func detect(_ text: String) -> Lang? {
    let sample = String(text.prefix(2000))
    guard sample.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = allCases.map(\.nlLanguage)
    recognizer.processString(sample)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
      confidence >= 0.4
    else { return nil }
    return allCases.first { $0.nlLanguage == language }
  }

  /// source：nil = 自动（用 detected）；target：nil = 智能。返回的 from 为 nil 表示交给服务自动识别
  static func resolve(
    source: Lang?, target: Lang?, detected: Lang?, native: Lang, foreign: Lang
  ) -> (from: Lang?, to: Lang) {
    let from = source ?? detected
    let opposite = from.map { $0.isSameLanguage(as: native) ? foreign : native } ?? native
    guard let target else { return (from, opposite) }
    if let from, from.isSameLanguage(as: target) { return (from, opposite) }
    return (from, target)
  }
}
