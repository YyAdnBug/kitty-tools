// 多语言（PLAN §10「多语言」，做法和术语表在 macos/TRANSLATION.md）：读源码里的 String Catalog（同 FinderLinkTests 读扩展源码），
// 查已经有英文的每一条：状态是 translated、占位符和中文一样、英文里没有汉字、核心术语照术语表；目录里没有 stale 的条目。
// 「每条中文都有英文」（requiresEnglish）第 9 批收尾时打开，之前每批只保证自己那一族。
// Info.plist 的权限说明：每条都有英文，中文和 Config/Info.plist 一字不差。界面语言（InterfaceLanguage）的纯函数也在这里。
// 访达扩展自己的目录（KittyToolsFinder/Localizable.xcstrings，第 8b 批）同样查，而且每条都要有英文（它整个在那一批译完）。

import Foundation
import Testing

@testable import KittyTools

struct LocalizationTests {
  /// 第 9 批收尾时改成 true：目录里每条中文都要有英文，不是中文的要么有英文、要么标了不翻
  static let requiresEnglish = false

  private static let macos = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()

  private static func catalog(_ path: String) throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: macos.appending(path: path))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["sourceLanguage"] as? String == "zh-Hans")
    return try #require(json["strings"] as? [String: [String: Any]])
  }

  /// 术语表里不会被别的说法替代的那些（TRANSLATION.md「术语表」，改那边要一起改）：中文里有左边，英文里就得有右边
  static let glossary = [
    ("刘海岛", "notch"), ("剪贴板", "clipboard"), ("启动器", "launcher"), ("启动台", "launchpad"),
    ("便签", "note"), ("状态屏", "status screen"), ("程序坞预览", "dock preview"),
    ("访达右键", "finder menu"), ("晾衣绳", "clothesline"), ("插件", "plugin"), ("片段", "snippet"),
    ("收藏夹", "collection"), ("生词本", "word list"), ("截图历史", "screenshot history"),
    ("长截图", "scrolling capture"), ("复制即译", "translate on copy"), ("最近删除", "recently deleted"),
    ("主界面", "home"),
  ]

  private static let han = /[\u{3400}-\u{9FFF}]/

  /// 一条字里的占位符，按位置排好（%@、%lld、%1$@ 这些；%% 不算）
  static func placeholders(_ text: String) -> [String] {
    var next = 0
    var found: [(Int, String)] = []
    for match in text.matches(of: /%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA])/) {
      next += 1
      let position = match.1.flatMap { Int($0) } ?? next
      let spec = String(match.2).replacing(/^[-+ #0]*\d*(?:\.\d+)?/, with: "")
      found.append((position, spec))
    }
    return found.sorted { $0.0 < $1.0 }.map(\.1)
  }

  /// 一种语言下所有的字（单复数、设备这些变体里的都算）
  typealias Value = (text: String, state: String?, variant: String)

  static func values(_ localization: Any?) -> [Value] {
    guard let localization = localization as? [String: Any] else { return [] }
    var result: [Value] = []
    if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
      result.append((text: value, state: unit["state"] as? String, variant: ""))
    }
    for (_, kinds) in localization["variations"] as? [String: [String: Any]] ?? [:] {
      for (name, nested) in kinds {
        result += values(nested).map { (text: $0.text, state: $0.state, variant: name) }
      }
    }
    return result
  }

  /// App 的和访达扩展的两份目录
  nonisolated static let catalogs = [
    "KittyTools/Resources/Localizable.xcstrings", "KittyToolsFinder/Localizable.xcstrings",
  ]

  @Test(arguments: LocalizationTests.catalogs) func englishMatchesChinese(_ path: String) throws {
    var problems: [String] = []
    for (key, entry) in try Self.catalog(path) {
      if entry["extractionState"] as? String == "stale" {
        problems.append("代码里已经不用了（stale），从目录里删掉：\(key)")
      }
      let localizations = entry["localizations"] as? [String: Any] ?? [:]
      // 空串不行：查不到译文、默认值又是空的时候系统显示 key 本身（实测，显式 key 会把「list.quoted」露出来）
      for (language, localization) in localizations
      where Self.values(localization).contains(where: { $0.text.isEmpty }) {
        problems.append("\(language) 是空串：\(key)")
      }
      let source = Self.values(localizations["zh-Hans"]).first?.text ?? key
      let english = Self.values(localizations["en"])
      let needsEnglish = source.contains(Self.han) || entry["shouldTranslate"] as? Bool != false
      if english.isEmpty {
        let required = Self.requiresEnglish || path.hasPrefix("KittyToolsFinder")
        if required, needsEnglish, !key.isEmpty { problems.append("没有英文：\(key)") }
        continue
      }
      // 带 substitutions 的（一句里两处单复数）占位符换成了 %#@名字@，只查汉字
      let checksPlaceholders = (localizations["en"] as? [String: Any])?["substitutions"] == nil
      let expected = Self.placeholders(source)
      for value in english {
        if value.state != "translated" { problems.append("英文不是 translated：\(key)") }
        if value.text.contains(Self.han) { problems.append("英文里有汉字：\(key) → \(value.text)") }
        guard checksPlaceholders else { continue }
        let got = Self.placeholders(value.text)
        // 复数的 one / zero 可以不写数字（「1 小时」写成 an hour），其余必须一样
        let optional = value.variant == "one" || value.variant == "zero"
        if got != expected, !(optional && Set(got).isSubset(of: Set(expected))) {
          problems.append("占位符对不上：\(key) → \(value.text)")
        }
      }
      let lowered = english.map { $0.text.lowercased() }
      // 放不下的地方用的短说法（显式 key、comment 里写「短说法」，TRANSLATION.md 五）不查术语
      let isShortForm = (entry["comment"] as? String)?.contains("短说法") == true
      for (chinese, term) in Self.glossary where source.contains(chinese) && !isShortForm {
        if !lowered.allSatisfy({ $0.contains(term) }) {
          problems.append("术语：「\(chinese)」要译成 \(term)：\(key)")
        }
      }
    }
    #expect(problems.isEmpty, "\(problems.sorted().joined(separator: "\n"))")
  }

  /// 访达扩展：语言列表同 App（不然繁体中文的系统落到英文、App 是中文），自带模板在菜单里的名字和 App 建出来的文件名
  /// 是同几条中文、英文也一样（两份目录各存一份）
  @Test func finderExtensionMatchesApp() throws {
    let languages = { (name: String) in
      let plist = NSDictionary(contentsOf: Self.macos.appending(path: "Config/\(name)"))
      return plist?["CFBundleLocalizations"] as? [String] ?? []
    }
    #expect(!languages("Info.plist").isEmpty)
    #expect(languages("Finder-Info.plist") == languages("Info.plist"))
    let app = try Self.catalog(Self.catalogs[0])
    let finder = try Self.catalog(Self.catalogs[1])
    let english = { (entry: [String: Any]?) in
      Self.values((entry?["localizations"] as? [String: Any])?["en"]).first?.text
    }
    for key in ["文本文件", "Word 文档", "Excel 表格", "PPT 演示文稿"] {
      #expect(english(finder[key]) != nil && english(finder[key]) == english(app[key]), "\(key)")
    }
  }

  @Test func usageDescriptionsAreTranslated() throws {
    let plist = try #require(
      NSDictionary(contentsOf: Self.macos.appending(path: "Config/Info.plist")) as? [String: Any])
    let strings = try Self.catalog("KittyTools/Resources/InfoPlist.xcstrings")
    let keys = plist.keys.filter { $0.hasSuffix("UsageDescription") }
    #expect(keys.count >= 7)
    for key in keys {
      let localizations = strings[key]?["localizations"] as? [String: Any]
      #expect(Self.values(localizations?["zh-Hans"]).first?.text == plist[key] as? String, "\(key)")
      let english = Self.values(localizations?["en"]).first
      #expect(english?.state == "translated" && english?.text.contains(Self.han) == false, "\(key)")
    }
  }

  /// 存下来还要读回来比对的名字永远不翻（TRANSLATION.md 二「存下来的字」，第 7 批）：自动备份的文件名（列备份、轮换、
  /// 恢复都按它认，几台不同语言的 Mac 共用一个另存的文件夹）、WebDAV 默认文件夹（中英两台都用默认值时要连到同一个）
  /// 不进目录——进了目录，英文界面写出来的就和中文的对不上、认不回来
  @Test func storedNamesNeverTranslated() throws {
    let keys = try Self.catalog("KittyTools/Resources/Localizable.xcstrings").keys
    // 新建文件模板的文件夹名（扩展的只读例外、扩展里抄的路径、用户放进去的模板都认它，第 8b 批）
    #expect(NewFile.folderName == "新建文件模板")
    for catalog in Self.catalogs {
      #expect(try !Self.catalog(catalog).keys.contains(NewFile.folderName), "\(catalog)")
    }
    for fixed in ["Kitty Tools 自动备份", "Kitty Tools 导入前"] {
      #expect(!keys.contains { $0.hasPrefix(fixed) }, "\(fixed)")
    }
    #expect(SyncServerForm.defaultFolder == "Kitty Tools 同步")
    #expect(!keys.contains(SyncServerForm.defaultFolder))
    // 0.9.0 写下的名字照样认得出；英文界面导出的设置文件（「Kitty Tools Settings …」）不当成自动备份
    let calendar = Calendar(identifier: .gregorian)
    let daily = SettingsBackup.parse("Kitty Tools 自动备份 2026-10-08 3F9A.json", calendar: calendar)
    #expect(daily?.kind == .daily && daily?.owner == "3F9A")
    let before = SettingsBackup.parse("Kitty Tools 导入前 2026-10-08 153012.json", calendar: calendar)
    #expect(before?.kind == .beforeImport)
    #expect(SettingsBackup.parse("Kitty Tools Settings 2026-10-08.json", calendar: calendar) == nil)
  }

  @Test func placeholderParsing() {
    #expect(Self.placeholders("版本 %@（%@）") == ["@", "@"])
    #expect(Self.placeholders("Next: %2$@ (%1$lld)") == ["lld", "@"])
    #expect(Self.placeholders("%lld%% 已完成，%.1f MB") == ["lld", "f"])
  }

  /// 中文原文（搜索中英都认用）：字面量的 key、显式 key 的默认值，插进去的值照样填上
  @Test func chineseOriginal() {
    #expect(HotKeyAction.clipboard.titleResource.chinese == "剪贴板历史")
    #expect(HotKeyAction.screenshot.titleResource.chinese == "截图")
    // chinese 靠的是 locale 能指定取哪一种语言：单测宿主是中文，反过来指到英文验一下
    var english = HotKeyAction.screenshot.titleResource
    english.locale = Locale(identifier: "en")
    #expect(String(localized: english) == "Take Screenshot")
    let name = "工作"
    let moved: LocalizedStringResource = "已复制到我的脚本：\(name)"
    #expect(moved.chinese == "已复制到我的脚本：工作")
    #expect(ActionMenu.Item(title: "在访达中显示").original == "在访达中显示")
    // 英文界面里打中文也找得到：标题和原文都认（这里两个是同一个字，照样只出一次）
    let items = [ActionMenu.Item(title: "在访达中显示"), ActionMenu.Item(title: "打开")]
    #expect(ActionMenu.filter(items, query: "zfd").map(\.title) == ["在访达中显示"])
  }

  // MARK: 界面语言

  @Test func storedChoice() {
    #expect(InterfaceLanguage.choice(in: [:]) == .system)
    #expect(InterfaceLanguage.choice(in: [Prefs.appleLanguages: ["en"]]) == .english)
    #expect(InterfaceLanguage.choice(in: [Prefs.appleLanguages: ["zh-Hans-CN"]]) == .chinese)
    #expect(InterfaceLanguage.choice(in: [Prefs.appleLanguages: ["zh-Hant"]]) == .chinese)
  }

  @Test func resolvesLikeTheSystem() {
    let ours = ["zh-Hans", "en", "zh-Hant"]
    func resolve(_ system: [String]) -> InterfaceLanguage {
      InterfaceLanguage.resolved(.system, system: system, localizations: ours)
    }
    #expect(resolve(["en-CN", "zh-Hans-CN"]) == .english)
    #expect(resolve(["zh-Hans-CN", "en-CN"]) == .chinese)
    #expect(resolve(["zh-Hant-TW"]) == .chinese)
    #expect(resolve(["de-DE"]) == .english)
    #expect(resolve(["fr-FR", "zh-Hans-CN"]) == .chinese)
    #expect(InterfaceLanguage.resolved(.english, system: ["zh-Hans"], localizations: ours) == .english)
  }

  @Test func upgradeKeepsChineseOnce() throws {
    let english = ["en-CN", "zh-Hans-CN"]
    let ours = ["zh-Hans", "en", "zh-Hant"]
    func run(_ stored: [String: Any], system: [String]) throws -> (kept: Bool, after: [String: Any]) {
      let name = "kitty-tests.language.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      defer { defaults.removePersistentDomain(forName: name) }
      defaults.setPersistentDomain(stored, forName: name)
      let kept = InterfaceLanguage.keepChineseOnUpgrade(
        defaults, domainName: name, system: system, localizations: ours)
      return (kept, defaults.persistentDomain(forName: name) ?? [:])
    }
    // 从 0.9.x 升上来、系统英文在前：定成中文
    let upgrade = try run([Prefs.lastSeenVersion: "0.9.0"], system: english)
    #expect(upgrade.kept)
    #expect(upgrade.after[Prefs.appleLanguages] as? [String] == ["zh-Hans"])
    #expect(upgrade.after[Prefs.languageIntroduced] as? Bool == true)
    // 只做一次：之后改回跟随系统不会再被定成中文
    #expect(try !run([Prefs.lastSeenVersion: "0.9.0", Prefs.languageIntroduced: true], system: english).kept)
    // 新装跟系统
    let fresh = try run([:], system: english)
    #expect(!fresh.kept && fresh.after[Prefs.appleLanguages] == nil)
    // 系统中文在前、或者自己选过语言：不动
    #expect(try !run([Prefs.lastSeenVersion: "0.9.0"], system: ["zh-Hans-CN"]).kept)
    let chose = try run([Prefs.lastSeenVersion: "0.9.0", Prefs.appleLanguages: ["en"]], system: english)
    #expect(!chose.kept && chose.after[Prefs.appleLanguages] as? [String] == ["en"])
  }

  /// 翻译的第一 / 第二语言：新装、系统英文在中文前面时明写成英语 / 简体中文；别的情况不写（注册的默认值不动）
  @Test func seedsTranslateLanguagesOnNewInstall() throws {
    func run(_ stored: [String: Any], system: [String]) throws -> [String: Any] {
      let name = "kitty-tests.translate-lang.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      defer { defaults.removePersistentDomain(forName: name) }
      defaults.setPersistentDomain(stored, forName: name)
      Lang.seedNewInstall(defaults, domainName: name, system: system)
      return defaults.persistentDomain(forName: name) ?? [:]
    }
    let fresh = try run([:], system: ["en-CN", "zh-Hans-CN"])
    #expect(fresh[Prefs.translateFirst] as? String == "en")
    #expect(fresh[Prefs.translateSecond] as? String == "zh-Hans")
    #expect(try run([:], system: ["ja-JP", "en-US"])[Prefs.translateFirst] as? String == "en")
    // 中文在前、没有中英文：不写
    #expect(try run([:], system: ["zh-Hans-CN", "en-CN"]).isEmpty)
    #expect(try run([:], system: ["de-DE"]).isEmpty)
    // 升级上来的、引导开过的、自己选过的：不碰
    #expect(try run([Prefs.lastSeenVersion: "0.9.0"], system: ["en-US"]).keys.sorted() == [Prefs.lastSeenVersion])
    #expect(try run([Prefs.onboardingScreen: 1], system: ["en-US"]).keys.sorted() == [Prefs.onboardingScreen])
    let chose = try run([Prefs.translateFirst: "ja"], system: ["en-US"])
    #expect(chose[Prefs.translateFirst] as? String == "ja" && chose[Prefs.translateSecond] == nil)
  }
}
