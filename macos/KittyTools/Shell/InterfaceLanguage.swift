// 界面语言（多语言第 0 批，2026-11-15 拍板 D2，PLAN §10「多语言」）：本 App 用简体中文还是英文。
// 默认跟系统；系统设置 › 通用 › 语言与地区 › 应用程序 里能给本 App 单独选，设置 › 通用「语言」写的是同一样东西——本 App
// 自己偏好域里的 AppleLanguages（Prefs.appleLanguages）。系统在第一次取字时读一次就定下了，改了要重新打开才生效。
// 跟着这台 Mac：不注册默认值，不导出、不同步。界面语言定了以后 Locale.current 也跟着它（2026-11-15 最小 .app 实测：定成中文时
// zh_CN、跟随英文系统时 en_CN），格式化日期数字直接用 Locale.current / FormatStyle 的默认，不写死 zh-Hans。
// 升级上来的保持中文（D2b）：0.10.0 之前只有中文，系统语言英文在前的 Mac（开发机就是）一升级会突然变成英文。带英文的版本第一次
// 打开时（Main 里、第一次取字之前；写在那一刻当次就生效，同日实测），是升级、按系统会落到英文，就把本 App 定成简体中文，
// 「已更新到」那座岛说一声。新装跟系统。

import Foundation
import SwiftUI

enum InterfaceLanguage: String, CaseIterable, Identifiable {
  case system
  case chinese = "zh-Hans"
  case english = "en"

  var id: String { rawValue }

  /// 选项上的名字：语言名写它自己的文字（同系统设置）
  var title: String {
    switch self {
    // 显式 key：外观、强调色也有「跟随系统」，英文各叫各的
    case .system: String(localized: "language.system", defaultValue: "跟随系统")
    case .chinese: "简体中文"
    case .english: "English"
    }
  }

  /// 本 App 偏好域里存的那一项。系统设置写进来的 zh-Hans-CN、zh-Hant 都算中文（繁体也落回简体，Info.plist）
  static func choice(in domain: [String: Any]) -> InterfaceLanguage {
    guard let first = (domain[Prefs.appleLanguages] as? [String])?.first else { return .system }
    if first.hasPrefix("zh") { return .chinese }
    return first.hasPrefix("en") ? .english : .system
  }

  /// 这台 Mac 上选的（只读本 App 自己的偏好域：AppleLanguages 也在系统那一份里，那份是系统的语言列表）
  static var stored: InterfaceLanguage {
    choice(
      in: Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
        ?? [:])
  }

  /// 写进偏好，下次启动生效
  static func store(_ choice: InterfaceLanguage, to defaults: UserDefaults = .standard) {
    if choice == .system {
      defaults.removeObject(forKey: Prefs.appleLanguages)
    } else {
      defaults.set([choice.rawValue], forKey: Prefs.appleLanguages)
    }
  }

  /// 系统的语言列表（全局那一份，不被本 App 自己的选择盖住）；nonisolated：后台扫 App 目录时按它取 App 的名字
  nonisolated static var systemLanguages: [String] {
    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[
      Prefs.appleLanguages]
      as? [String] ?? []
  }

  /// 这次运行界面用的是哪种（启动时定下的）
  static var running: InterfaceLanguage { resolve(Bundle.main.preferredLocalizations) }

  /// 选 choice、系统语言列表是 system 时，界面会是哪种
  static func resolved(_ choice: InterfaceLanguage, system: [String], localizations: [String])
    -> InterfaceLanguage
  {
    guard choice == .system else { return choice }
    return resolve(Bundle.preferredLocalizations(from: localizations, forPreferences: system))
  }

  /// 只有简体中文和英文两份字：不是英文的都是中文（zh-Hant 没有自己的字，落回开发语言）
  private static func resolve(_ picked: [String]) -> InterfaceLanguage {
    picked.first?.hasPrefix("en") == true ? .english : .chinese
  }

  /// 启动时存的那一项（Main 里记下）：这次运行的语言是按它定的
  static var storedAtLaunch = InterfaceLanguage.system

  /// 这次运行里改过、而且换成的语言和现在的不一样：要重新打开才生效。只看「改过没有」，不拿系统语言硬算——
  /// 单测宿主、用参数指定语言启动的，界面语言本来就和偏好推出来的不一样
  static var needsRelaunch: Bool {
    stored != storedAtLaunch
      && resolved(stored, system: systemLanguages, localizations: Bundle.main.localizations)
        != running
  }

  /// 这次启动替用户定成了中文（Main 里记下，「已更新到」那座岛读）
  static var keptChinese = false

  /// 升级保持中文（Main 里、第一次取字之前调一次）：带英文的版本第一次打开、是升级（看过别的版本）、没自己选过语言、
  /// 按系统会落到英文 → 定成简体中文，返回 true。不管定没定，记下「第一次打开过了」，以后不再做
  static func keepChineseOnUpgrade(
    _ defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier,
    system: [String] = systemLanguages, localizations: [String] = Bundle.main.localizations
  ) -> Bool {
    let stored = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    guard stored[Prefs.languageIntroduced] == nil else { return false }
    defaults.set(true, forKey: Prefs.languageIntroduced)
    guard stored[Prefs.lastSeenVersion] != nil, stored[Prefs.appleLanguages] == nil,
      resolved(.system, system: system, localizations: localizations) == .english
    else { return false }
    store(.chinese, to: defaults)
    return true
  }
}

extension Sequence<String> {
  /// 并列的几个名字连成一串：中文「剪贴板、启动器」，英文「Clipboard, Launcher」
  nonisolated func joinedAsList() -> String {
    joined(
      separator: String(
        localized: "list.enumeration", defaultValue: "、", comment: "并列的几个名字之间（剪贴板、启动器）"))
  }

  /// 几句话并成一句：中文「；」、英文「; 」（同 AppDelegate.semicolon 那个 key）
  nonisolated func joinedAsClauses() -> String {
    joined(
      separator: String(
        localized: "list.semicolon", defaultValue: "；", comment: "两句话并成一句时中间的分号"))
  }
}

extension LocalizedStringResource {
  /// 中文原文（开发语言的那一份，插进去的值照样填上；显式 key 的取它的默认值）：搜索时中英都认
  /// （TRANSLATION.md「搜索中英都认」：英文界面里打中文、拼音也找得到）
  nonisolated var chinese: String {
    var copy = self
    copy.locale = Locale(identifier: InterfaceLanguage.chinese.rawValue)
    return String(localized: copy)
  }

  /// 英文的那一份（还没有英文的落回中文）：中文界面里打英文也找得到（启动器的搜索名）
  nonisolated var english: String {
    var copy = self
    copy.locale = Locale(identifier: InterfaceLanguage.english.rawValue)
    return String(localized: copy)
  }
}

extension InterfaceLanguage {
  /// 这次运行界面是不是英文（同 running；nonisolated：后台扫 App 目录、读脚本头部时按它挑显示的名字）
  nonisolated static var isEnglish: Bool {
    Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
  }
}

extension Text {
  /// 目录里的字，不解析 Markdown。收 LocalizedStringResource 的组件显示时用它：Text(LocalizedStringResource) 连
  /// "\(x)" 插进去的用户的字一起当 Markdown 解析（文件名里的 *、反引号会变成斜体、代码样式，实测）；这些组件在 0.9.0
  /// 收的是 String、原样显示（TRANSLATION.md 二）
  init(plain resource: LocalizedStringResource) { self.init(String(localized: resource)) }
}
