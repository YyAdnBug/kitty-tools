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
  // 第四轮体检 X1（2026-11-17）：常用的 30 种。新的只能加在末尾（浮窗、设置里的列表按这个顺序；原值存进偏好和历史）
  case vi, th, id, ms, ar, tr, hi, nl, pl, uk, sv, da, fi, nb, cs, el, he, hu, ro

  /// 界面上的语言名（跟界面语言）
  var titleResource: LocalizedStringResource {
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
    case .vi: "越南语"
    case .th: "泰语"
    case .id: "印尼语"
    case .ms: "马来语"
    case .ar: "阿拉伯语"
    case .tr: "土耳其语"
    case .hi: "印地语"
    case .nl: "荷兰语"
    case .pl: "波兰语"
    case .uk: "乌克兰语"
    case .sv: "瑞典语"
    case .da: "丹麦语"
    case .fi: "芬兰语"
    case .nb: "挪威语"
    case .cs: "捷克语"
    case .el: "希腊语"
    case .he: "希伯来语"
    case .hu: "匈牙利语"
    case .ro: "罗马尼亚语"
    }
  }

  var title: String { String(localized: titleResource) }

  /// 翻译浮窗顶栏胶囊里的语言名：英文的简繁中文太长（Simplified Chinese 把胶囊挤成「Simplifi…hinese」），用短说法；
  /// 中文和别的语言同 title
  var shortTitle: String {
    switch self {
    case .zhHans:
      String(localized: "lang.short.zhHans", defaultValue: "简体中文", comment: "翻译浮窗顶栏胶囊里的语言名（短说法）")
    case .zhHant:
      String(localized: "lang.short.zhHant", defaultValue: "繁体中文", comment: "翻译浮窗顶栏胶囊里的语言名（短说法）")
    default: title
    }
  }

  /// 智谱中文提示词里用的语言名：固定中文（中文原文），不跟界面语言变——给大模型的提示词不翻
  var chineseName: String { titleResource.key }

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
    case .vi: "Vietnamese"
    case .th: "Thai"
    case .id: "Indonesian"
    case .ms: "Malay"
    case .ar: "Arabic"
    case .tr: "Turkish"
    case .hi: "Hindi"
    case .nl: "Dutch"
    case .pl: "Polish"
    case .uk: "Ukrainian"
    case .sv: "Swedish"
    case .da: "Danish"
    case .fi: "Finnish"
    case .nb: "Norwegian"
    case .cs: "Czech"
    case .el: "Greek"
    case .he: "Hebrew"
    case .hu: "Hungarian"
    case .ro: "Romanian"
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
    case .vi: "vi-VN"
    case .th: "th-TH"
    case .id: "id-ID"
    case .ms: "ms-MY"
    case .ar: "ar-SA"
    case .tr: "tr-TR"
    case .hi: "hi-IN"
    case .nl: "nl-NL"
    case .pl: "pl-PL"
    case .uk: "uk-UA"
    case .sv: "sv-SE"
    case .da: "da-DK"
    case .fi: "fi-FI"
    case .nb: "nb-NO"
    case .cs: "cs-CZ"
    case .el: "el-GR"
    case .he: "he-IL"
    case .hu: "hu-HU"
    case .ro: "ro-RO"
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
    case .vi: .vietnamese
    case .th: .thai
    case .id: .indonesian
    case .ms: .malay
    case .ar: .arabic
    case .tr: .turkish
    case .hi: .hindi
    case .nl: .dutch
    case .pl: .polish
    case .uk: .ukrainian
    case .sv: .swedish
    case .da: .danish
    case .fi: .finnish
    case .nb: .norwegian
    case .cs: .czech
    case .el: .greek
    case .he: .hebrew
    case .hu: .hungarian
    case .ro: .romanian
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

extension Lang {
  /// 新装第一次启动时（AppDelegate 里、Prefs.registerDefaults 之前，同 Feature.seedNewInstall）：系统语言列表里英文排在
  /// 中文前面的 Mac，把第一 / 第二语言明写成英语 / 简体中文；中文在前（或者都没有）的照旧不写，用注册的默认值（简体中文 / 英语）。
  /// 注册的默认值全 App 一套、不改（mac-native §1：导出、同步里「没有这一项 = 默认值」，各台不同会把没动过的设置悄悄换掉）。
  /// 新装 = 还没看过任何一版、引导也没开过（同 Feature.seedNewInstall）；升级上来的、已经存过的都不碰。只看持久域
  @MainActor static func seedNewInstall(
    _ defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier,
    system: [String] = InterfaceLanguage.systemLanguages
  ) {
    let stored = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    guard stored[Prefs.lastSeenVersion] == nil, stored[Prefs.onboardingScreen] == nil,
      stored[Prefs.translateFirst] == nil, stored[Prefs.translateSecond] == nil,
      system.first(where: { $0.hasPrefix("en") || $0.hasPrefix("zh") })?.hasPrefix("en") == true
    else { return }
    defaults.set(Lang.en.rawValue, forKey: Prefs.translateFirst)
    defaults.set(Lang.zhHans.rawValue, forKey: Prefs.translateSecond)
  }
}
