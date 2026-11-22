// 多语言（PLAN §10「多语言」，做法和术语表在 macos/TRANSLATION.md）：读源码里的 String Catalog（同 FinderLinkTests 读扩展源码），
// 查已经有英文的每一条：状态是 translated、占位符和中文一样、英文里没有汉字、核心术语照术语表；目录里没有 stale 的条目。
// 「每条中文都有英文」（requiresEnglish）第 9 批收尾时打开（之前每批只保证自己那一族）；同批加了漏网检查（源码里的中文字面量
// 都在目录里，故意不翻的在 notTranslated 白名单里）、英文里不用直撇号、术语表里大写的功能名按大小写查、例子真能解析。
// Info.plist 的权限说明：每条都有英文，中文和 Config/Info.plist 一字不差。界面语言（InterfaceLanguage）的纯函数也在这里。
// 访达扩展自己的目录（KittyToolsFinder/Localizable.xcstrings，第 8b 批）同样查，而且每条都要有英文（它整个在那一批译完）。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct LocalizationTests {
  /// 第 9 批收尾时改成 true：目录里每条中文都要有英文，不是中文的要么有英文、要么标了不翻
  static let requiresEnglish = true

  private static let macos = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()

  private static func catalog(_ path: String) throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: macos.appending(path: path))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["sourceLanguage"] as? String == "zh-Hans")
    return try #require(json["strings"] as? [String: [String: Any]])
  }

  /// 术语表里不会被别的说法替代的那些（TRANSLATION.md「术语表」，改那边要一起改）：中文里有左边，英文里就得有右边。
  /// 右边带大写字母的是功能名：在句子中间也首字母大写（the Launcher，第 9 批统一），按大小写查；全小写的不分大小写
  static let glossary = [
    ("刘海岛", "Notch"), ("剪贴板", "clipboard"), ("启动器", "Launcher"), ("启动台", "Launchpad"),
    ("便签", "note"), ("状态屏", "Status Screen"), ("程序坞预览", "Dock Preview"),
    ("访达右键", "Finder Menu"), ("晾衣绳", "Clothesline"), ("插件", "plugin"), ("片段", "snippet"),
    ("收藏夹", "collection"), ("生词本", "Word List"), ("截图历史", "Screenshot History"),
    ("长截图", "scrolling capture"), ("复制即译", "Translate on Copy"), ("最近删除", "Recently Deleted"),
    ("主界面", "Home"), ("剪贴板历史", "Clipboard History"), ("透镜", "Lens"), ("便签墙", "Note Wall"),
    ("快速记一条", "Quick Note"), ("保持唤醒", "Keep Awake"), ("睡眠关蓝牙", "Bluetooth Sleep"),
  ]

  private static let han = /[\u{3400}-\u{9FFF}]/

  /// 一条字里的占位符，按位置排好（%@、%lld、%1$@ 这些；%% 不算）
  static func placeholders(_ text: String) -> [String] {
    var next = 0
    var found: [(Int, String)] = []
    for match in text.matches(
      of: /%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA])/)
    {
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
    if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String
    {
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
      // 放不下的地方用的短说法（显式 key、comment 里写「短说法」，TRANSLATION.md 五）不查术语
      let isShortForm = (entry["comment"] as? String)?.contains("短说法") == true
      for (chinese, term) in Self.glossary where source.contains(chinese) && !isShortForm {
        let exact = term.contains(where: \.isUppercase)
        let found = english.allSatisfy {
          exact ? $0.text.contains(term) : $0.text.lowercased().contains(term)
        }
        if !found { problems.append("术语：「\(chinese)」要译成 \(term)：\(key)") }
      }
    }
    #expect(problems.isEmpty, "\(problems.sorted().joined(separator: "\n"))")
  }

  /// 英文里字母之间的撇号一律用弯的 ’（don’t、it’s；第 9 批统一，TRANSLATION.md 四）
  @Test(arguments: LocalizationTests.catalogs + ["KittyTools/Resources/InfoPlist.xcstrings"])
  func curlyApostrophes(_ path: String) throws {
    var problems: [String] = []
    for (key, entry) in try Self.catalog(path) {
      let english = Self.values((entry["localizations"] as? [String: Any])?["en"])
      if english.contains(where: { $0.text.contains(/\p{L}'\p{L}/) }) { problems.append(key) }
    }
    #expect(problems.isEmpty, "英文里用了直撇号 '，换成 ’：\n\(problems.sorted().joined(separator: "\n"))")
  }

  /// 速查表、启动器提示里的例子（中英两份）真能解析（第 2 批留下的）：提醒的一句话走 ReminderPhrase，汇率走 ExchangeRates。
  /// 例子是引号（“” 或「」）里的字；只有关键词的（「提醒 」）、写法模板（「提醒 空格 时间 内容」「remind <time>」）不算
  @Test func examplesParse() throws {
    let strings = try Self.catalog(Self.catalogs[0])
    // 中文：显式 key 的默认值，没有就是 key 本身
    func texts(_ key: String) -> [String] {
      let localizations = strings[key]?["localizations"] as? [String: Any]
      #expect(localizations != nil, "目录里没有：\(key)")
      let chinese = Self.values(localizations?["zh-Hans"]).map(\.text)
      return (chinese.isEmpty ? [key] : chinese) + Self.values(localizations?["en"]).map(\.text)
    }
    func examples(_ key: String, keyword: (String) -> String = { _ in "" }) -> [String] {
      texts(key).flatMap { text in
        let filled = text.replacing(/%(?:\d\$)?@/, with: keyword(text))
        return filled.matches(of: /[“「]([^”」]+)[”」]/).map { String($0.1) }
      }.filter { !ReminderPhrase.isKeyword($0) && !$0.contains("空格") && !$0.contains("<") }
    }
    let reminders =
      [
        "在启动器里输入「提醒 10分钟 喝水」「提醒 明天9点 交周报」：↩ 建好（tx、remind 也行）",
        "试试「10分钟 喝水」「明天9点 交周报」「下午3点半 开会」",
        "还没有提醒：在「提醒 」后面接着写时间和内容，如「10分钟 喝水」",
      ].flatMap { examples($0) }
      // 启动器提示行的副标题：%@ 是关键词（中文那份放「提醒」、英文放 remind）
      + examples("输入「%@ 空格 时间 内容」，如「%@ 10分钟 喝水」；↩ 或 Tab 补全关键词") {
        $0.contains(Self.han) ? "提醒" : "remind"
      }
    #expect(reminders.count == 13)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for example in reminders {
      let phrase = ReminderPhrase.query(example) ?? example
      let parsed = ReminderPhrase.parse(
        phrase, now: now, calendar: Calendar(identifier: .gregorian))
      #expect(parsed != nil && parsed?.title.isEmpty == false, "提醒的例子解析不了：\(example)")
    }
    // 保持唤醒（第 10 批）：设置页小字、速查表、认不出时的提示里的例子，awake 后面那截要认得出来
    let awake = [
      "也能在菜单栏、主界面里开，或者在启动器里输入「awake 2小时」「保持唤醒 到18点」。重启电脑、退出 Kitty Tools 后不再保持。",
      "在启动器里输入「awake 2小时」「保持唤醒 到18点」「awake 无限期」：↩ 开始；开着时第一行是停止",
      "试试「2小时」「30分钟」「到18点」「无限期」",
    ].flatMap { examples($0) }
    #expect(awake.count == 18)
    for example in awake {
      let typed = KeepAwakePlan.query(example) ?? example
      let parsed = KeepAwakePlan.parse(typed, now: now, calendar: Calendar(identifier: .gregorian))
      #expect(parsed != .invalid && parsed != .empty, "保持唤醒的例子解析不了：\(example)")
    }
    let currency =
      examples("汇率换算；也可以直接输「100 美元 转 日元」（要联网取汇率）") + texts("launcher.currencyExample")
    #expect(currency.count == 4)
    for example in currency {
      #expect(
        ExchangeRates.request(for: example) == .init(amount: 100, from: "USD", to: "JPY"),
        "汇率的例子算不出来：\(example)")
    }
  }

  /// 刘海岛收着那一行（Island.rowRoom，第 9 批）：英文的长标题加详情、按钮放不下时截短，整行不超过岛的最宽；
  /// 放得下的（中文的常见长度）标题不限、详情照旧最宽 280
  @Test func islandRowFits() {
    let fits = Island.rowRoom(
      title: "已复制到剪贴板", detail: "授权辅助功能后才能直接粘贴", buttons: ["撤销"], fraction: false)
    #expect(fits.title == nil && fits.detail == 280)
    #expect(Island.rowRoom(title: "Copied", detail: nil, buttons: [], fraction: false).title == nil)
    func width(_ button: String) -> CGFloat {
      (button as NSString).size(withAttributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
      ]).width + 20
    }
    let long = Island.rowRoom(
      title: "Finder Menu needs to be turned on once in System Settings",
      detail: "Right-click in Finder to see it once it’s on", buttons: ["Turn On"], fraction: false)
    #expect(long.title != nil && long.detail >= 120)
    let row = 36 + 26 + 10 + (long.title ?? .infinity) + 10 + long.detail + 10 + width("Turn On")
    #expect(row <= Island.maxWidth)
    // 挂着的提醒收着时两个按钮都露着（2026-11-18）：两个都算进去，整行照样不超过岛的最宽
    let buttons = ["Got It", "Snooze 5 Minutes"]
    let pinned = Island.rowRoom(
      title: "Stand up and stretch · Drink water · Check the oven",
      detail: "Also missed: Pay the rent, Call mom", buttons: buttons, fraction: false)
    #expect(pinned.title != nil && pinned.detail >= 120)
    let pinnedRow =
      36 + 26 + 10 + (pinned.title ?? .infinity) + 10 + pinned.detail + 10 + width(buttons[0]) + 8
      + width(buttons[1])
    #expect(pinnedRow <= Island.maxWidth)
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

  // MARK: 漏网检查（第 9 批）

  /// 源码里的一个字面量（SourceLiterals 读出来的）
  struct Literal {
    let line: Int
    /// 转义解开、插值换成 %@ 的字（多行字面量去掉了缩进）
    let text: String
    /// 写在日志、断言、comment: 这些不显示的地方
    let hidden: Bool
  }

  /// 读一个 Swift 文件里的字符串字面量（插值里嵌着的也读）：跳过注释和正则字面量，记下每个字面量外面套着的调用。
  /// ponytail: 手写的简化词法——认 "…"、"""…"""、#"…"#、插值 \( … )（括号配对）、// /* */（可嵌套）、/…/ 和 #/…/#；
  /// 正则字面量按 Swift 的规矩认（/ 后面不是空白、前面不是标识符或右括号）。认错了只会多报或少报一条，失败信息里有行号可查
  static func literals(in source: String) -> [Literal] {
    let bytes = Array(source.utf8)
    var found: [Literal] = []
    var index = 0
    var line = 1
    /// 套着的括号：( 前面的调用名（Log.storage.error、fatalError），[ { 记成空
    var calls: [String] = []
    func byte(_ offset: Int = 0) -> UInt8 {
      index + offset < bytes.count ? bytes[index + offset] : 0
    }
    func isWord(_ byte: UInt8) -> Bool {
      byte == UInt8(ascii: "_") || (byte >= 0x30 && byte <= 0x39)
        || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A)
        || byte >= 0x80
    }
    /// ( 前面那一串（Log.storage.error、island?.show）
    func callName(before end: Int) -> String {
      var start = end
      while start > 0, isWord(bytes[start - 1]) || ".?!".utf8.contains(bytes[start - 1]) {
        start -= 1
      }
      return String(decoding: bytes[start..<end], as: UTF8.self)
    }
    /// 字面量前面紧挨着的参数标签（comment:）
    func label(before start: Int) -> String {
      var end = start
      while end > 0, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x0A { end -= 1 }
      guard end > 0, bytes[end - 1] == UInt8(ascii: ":") else { return "" }
      return callName(before: end - 1)
    }
    func hidden(at start: Int) -> Bool {
      let silent =
        /^(Log\.\w+|log|logger|Self\.log)\.(debug|info|notice|error|fault|warning|critical|trace)$/
      return calls.contains { name in
        name.wholeMatch(of: silent) != nil
          || [
            "fatalError", "assert", "assertionFailure", "precondition", "preconditionFailure",
            "print",
          ]
          .contains(name) || name.hasSuffix("beginActivity")
      } || ["comment", "debugDescription"].contains(label(before: start))
    }
    /// 跳过一段代码：到和进来时同一层的 ) 为止（插值里）或到文件尾
    func code(insideInterpolation: Bool) {
      let depth = calls.count
      while index < bytes.count {
        let current = byte()
        switch current {
        case 0x0A:
          line += 1
          index += 1
        case UInt8(ascii: "/") where byte(1) == UInt8(ascii: "/"):
          while index < bytes.count, byte() != 0x0A { index += 1 }
        case UInt8(ascii: "/") where byte(1) == UInt8(ascii: "*"):
          var nesting = 0
          repeat {
            if byte() == UInt8(ascii: "/"), byte(1) == UInt8(ascii: "*") {
              nesting += 1
              index += 2
            } else if byte() == UInt8(ascii: "*"), byte(1) == UInt8(ascii: "/") {
              nesting -= 1
              index += 2
            } else {
              if byte() == 0x0A { line += 1 }
              index += 1
            }
          } while nesting > 0 && index < bytes.count
        case UInt8(ascii: "\""), UInt8(ascii: "#"):
          var hashes = 0
          while byte(hashes) == UInt8(ascii: "#") { hashes += 1 }
          if byte(hashes) == UInt8(ascii: "\"") {
            string(hashes: hashes)
          } else if byte(hashes) == UInt8(ascii: "/"), hashes > 0 {
            regex(hashes: hashes)
          } else {
            index += max(hashes, 1)
          }
        case UInt8(ascii: "/"):
          let previous = bytes[..<index].last { $0 != 0x20 } ?? 0
          let opens = !isWord(previous) && !")]}\"".utf8.contains(previous)
          if opens, ![0x20, 0x0A, 0x09, UInt8(ascii: "=")].contains(byte(1)) {
            regex(hashes: 0)
          } else {
            index += 1
          }
        case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"):
          calls.append(current == UInt8(ascii: "(") ? callName(before: index) : "")
          index += 1
        case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
          index += 1
          // 插值收尾的那个 )：回到字符串里
          if insideInterpolation, calls.count == depth { return }
          if !calls.isEmpty { calls.removeLast() }
        default:
          index += 1
        }
      }
    }
    /// 正则字面量：跳到收尾的 /（#/ … /# 要带上井号）；单行的遇到换行就当不是正则
    func regex(hashes: Int) {
      let start = index
      index += hashes + 1
      var inClass = false
      while index < bytes.count {
        let current = byte()
        if current == UInt8(ascii: "\\") {
          index += 2
          continue
        }
        if current == 0x0A, hashes == 0 {
          index = start + 1
          return
        }
        if current == 0x0A { line += 1 }
        if current == UInt8(ascii: "[") { inClass = true }
        if current == UInt8(ascii: "]") { inClass = false }
        if current == UInt8(ascii: "/"), !inClass,
          (0..<hashes).allSatisfy({ byte($0 + 1) == UInt8(ascii: "#") })
        {
          index += hashes + 1
          return
        }
        index += 1
      }
    }
    /// 字符串字面量：攒原文（插值记成 U+0001、递归读里面的代码），收尾后去缩进、解转义
    func string(hashes: Int) {
      let start = index
      let startLine = line
      index += hashes
      let multiline =
        byte() == UInt8(ascii: "\"") && byte(1) == UInt8(ascii: "\"")
        && byte(2) == UInt8(ascii: "\"")
      index += multiline ? 3 : 1
      let silent = hidden(at: start)
      var raw: [UInt8] = []
      let escape = [UInt8(ascii: "\\")] + Array(repeating: UInt8(ascii: "#"), count: hashes)
      let close =
        Array(repeating: UInt8(ascii: "\""), count: multiline ? 3 : 1)
        + Array(repeating: UInt8(ascii: "#"), count: hashes)
      while index < bytes.count {
        if Array(bytes[index..<min(index + close.count, bytes.count)]) == close {
          index += close.count
          break
        }
        if Array(bytes[index..<min(index + escape.count, bytes.count)]) == escape {
          if bytes.count > index + escape.count, bytes[index + escape.count] == UInt8(ascii: "(") {
            index += escape.count + 1
            code(insideInterpolation: true)
            raw.append(1)
            continue
          }
          raw += bytes[index..<min(index + escape.count + 1, bytes.count)]
          index += escape.count + 1
          continue
        }
        if byte() == 0x0A { line += 1 }
        raw.append(byte())
        index += 1
      }
      var text = String(decoding: raw, as: UTF8.self)
      if multiline {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indent = lines.last?.prefix { $0 == " " } ?? ""
        lines = Array(lines.dropFirst().dropLast()).map {
          $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0
        }
        text = lines.joined(separator: "\n")
      }
      found.append(Literal(line: startLine, text: unescape(text, hashes: hashes), hidden: silent))
    }
    code(insideInterpolation: false)
    return found
  }

  /// 解开字面量里的转义（\n、\t、\"、\\、\u{…}、行尾的 \ 续行），插值标记 U+0001 换成 %@
  static func unescape(_ text: String, hashes: Int) -> String {
    let escape = "\\" + String(repeating: "#", count: hashes)
    var result = ""
    var rest = Substring(text)
    while let range = rest.range(of: escape) {
      result += rest[..<range.lowerBound]
      rest = rest[range.upperBound...]
      guard let next = rest.first else { break }
      rest = rest.dropFirst()
      switch next {
      case "n": result += "\n"
      case "t": result += "\t"
      case "0": result += "\0"
      case "\n": rest = rest.drop { $0 == " " }
      case "u":
        if let match = rest.prefixMatch(of: /\{([0-9a-fA-F]+)\}/),
          let scalar = UInt32(match.1, radix: 16).flatMap(Unicode.Scalar.init)
        {
          result.unicodeScalars.append(scalar)
          rest = rest[match.range.upperBound...]
        }
      default: result.append(next)
      }
    }
    return (result + rest).replacing("\u{1}", with: "%@")
  }

  /// 目录里的字比格式用：占位符都写成 %@、%% 写成 %（字面量里插值是 %@、百分号是 %）
  static func shape(_ text: String) -> String {
    text.replacing("%%", with: "\u{2}")
      .replacing(/%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA]/, with: "%@")
      .replacing("\u{2}", with: "%")
  }

  /// 故意不进目录的中文字面量（漏网检查的白名单）：文件（相对 macos/）里等于这些字的（三个字以上的：含这一段就算）；
  /// words：这个文件里解析输入用的短词（不超过 6 个字、没有中文标点）和正则都算
  static let notTranslated: [(file: String, texts: [String], words: Bool, why: String)] = [
    ("KittyTools/Launcher/Calculator.swift", [], true, "单位、进制的中文名：解析输入用，中英都认"),
    ("KittyTools/Launcher/ExchangeRates.swift", [], true, "货币的中文叫法、问法里去掉的字：解析输入用"),
    ("KittyTools/Reminders/ReminderPhrase.swift", [], true, "提醒那一句话里的时间说法、关键词：解析输入用"),
    (
      "KittyTools/KeepAwake/KeepAwakePlan.swift", [], true,
      "启动器「awake …」后面那截里的「无限期」「到 / 直到」这些说法、关键词：解析输入用，中英都认"
    ),
    ("KittyTools/Launcher/WebSearch.swift", ["防息屏"], false, "保持唤醒的关键词：不能再当网页搜索的关键词"),
    ("KittyTools/Launcher/SystemCommands.swift", [], true, "系统命令另外认的中文叫法：只进搜索名，不显示"),
    (
      "KittyTools/Translate/WordLookup.swift", ["美 /rʌn/", "píngguǒ"], true,
      "系统词典词条的词性、语法标签（释义的语言跟着翻译目标，是词条内容）；给大模型的示例词条"
    ),
    (
      "KittyTools/App/AppDelegate+Entry.swift", ["提醒 "], false,
      "启动器里提醒的关键词（ReminderPhrase.keywords）"
    ),
    ("KittyTools/App/KittyToolsApp.swift", ["用法："], false, "识字子进程的命令行用法，写标准错误"),
    ("KittyTools/Clipboard/ClipboardStore.swift", ["CREATE TABLE"], false, "建表的 SQL（中文是 SQL 注释）"),
    ("KittyTools/Screenshot/ShotHistory.swift", ["CREATE TABLE"], false, "建表的 SQL（中文是 SQL 注释）"),
    (
      "KittyTools/FinderMenu/NewFile.swift",
      ["文本文件.txt", "文档.docx", "表格.xlsx", "演示文稿.pptx", "新建文件模板"],
      false, "0.9.0 的访达扩展交来的中文文件名（legacyNames）、模板文件夹名：存下来要认的，永远不翻"
    ),
    (
      "KittyToolsFinder/FinderMenu.swift", ["新建文件模板"], false, "模板文件夹的路径（抄 App 的 NewFile.folderName）"
    ),
    ("KittyTools/Launcher/FileSearch.swift", ["搜索文件", "打开文件", "查找文件"], false, "提示行另外认的中文叫法：只进搜索"),
    (
      "KittyTools/Launcher/IPAddresses.swift", ["ip地址", "本机ip", "局域网ip", "内网ip", "外网ip"], false,
      "「ip」命令认的词"
    ),
    (
      "KittyTools/Launcher/LauncherItem.swift",
      [
        "脚本命令", "脚本写法", "钉图 贴图", "Capture 便签", "启动台 应用", "全部功能", "防息屏 防止睡眠", "便签 侧边",
        "延时 定时 倒计时",
      ],
      false, "动作的英文别名后面另加的中文搜索词：只进搜索名"
    ),
    (
      "KittyTools/Launcher/ScriptAIGuide.swift", ["写一个 Kitty Tools 的脚本命令"], false,
      "给 AI 的写法说明（文件内容，按界面语言写两份）"
    ),
    (
      "KittyTools/Launcher/ScriptLibrary.swift",
      ["@kitty.", "python3", "每行一条结果", "怎么写脚本", "你好", "第一条", "说明一", "第二条", "说明二", "新脚本", "查天气"],
      false,
      "新建脚本的模板和例子：写进文件就是用户的，按建的那一刻的界面语言写两份"
    ),
    ("KittyTools/Notes/NoteCapture.swift", ["字"], false, "量一行字高用的字，不显示"),
    (
      "KittyTools/Notes/NoteDeckOptions.swift", ["右", "左"], false,
      "中文示例便签里的「右 / 左」边缘（英文那份用 rawValue）"
    ),
    (
      "KittyTools/Notes/NoteSample.swift", ["随手记", "欢迎使用便签"], false,
      "示例便签的中文那份：放进库就是用户的便签，按放的那一刻的语言写"
    ),
    ("KittyTools/Notes/NotesBackup.swift", ["备份出来的文件不完整", "用户选了这次先不用便签"], false, "只进日志的失败原因"),
    (
      "KittyTools/Storage/Backup.swift", ["备份出来的文件不完整", "用户选了退出", "Kitty Tools 自动备份"], false,
      "只进日志的失败原因；自动备份的文件名永远不翻"
    ),
    ("KittyTools/Storage/Database.swift", ["不支持的参数类型"], false, "只进日志的失败原因"),
    (
      "KittyTools/Storage/SettingsBackup.swift", ["Kitty Tools 自动备份", "Kitty Tools 导入前"], false,
      "自动备份的文件名：列备份、轮换、恢复都按它认，永远不翻"
    ),
    ("KittyTools/Screenshot/ScrollCapture.swift", ["一\n二"], false, "量两行字高用的字，不显示"),
    (
      "KittyTools/Screenshot/ShotShelf.swift", ["Kitty Tools 截图"], false,
      "拖出用的临时目录名：启动时按名字清空，换了语言也得认得上次的"
    ),
    (
      "KittyTools/Screenshot/VideoExport.swift", [" 压缩版", "压缩中"], false,
      "录屏压缩版的后缀（按它认文件）、写到一半的隐藏临时文件名"
    ),
    (
      "KittyTools/Settings/ScreenshotTab.swift", ["敏捷的棕色狐狸", "跳过了懒狗"], false,
      "识字「接起来」的示例：故意一段中文、一段英文"
    ),
    ("KittyTools/Settings/ScriptsSection.swift", ["/脚本/"], false, "解析自带脚本时给的假路径"),
    (
      "KittyTools/Settings/SyncServerForm.swift", ["Kitty Tools 同步"], false,
      "WebDAV 默认文件夹：中英两台都用默认值时要连到同一个"
    ),
    (
      "KittyTools/Shell/Feature.swift",
      [
        "笔记", "记一条", "闹钟", "请勿触碰", "程序坞", "窗口预览", "右键菜单", "刘海", "灵动岛", "防息屏", "防止睡眠", "唤醒",
        "咖啡因", "合盖", "休眠", "平滑", "鼠标滚轮", "鼠标反向", "滚动方向", "快捷键列表",
        "app 快捷键", "改键", "文本扩展", "文字替换", "缩写", "自动展开",
      ], false,
      "启动器里认插件的词（pluginWords，中英都认）"
    ),
    ("KittyTools/Shell/Island+Notch.swift", ["系统灵动岛", "胶囊", "刘海"], false, "写进日志的屏幕类型"),
    (
      "KittyTools/SnippetExpand/SnippetExpander.swift",
      [
        "关键词之后又打了字", "Kitty 在忙", "安全输入开着", "Kitty 自己的窗口", "名单里的 App", "输入法正在组字", "带填空",
        "没有辅助功能授权", "便签里没等到关键词", "不知道收键的进程",
      ], false, "写进日志的没展开的原因"
    ),
    (
      "KittyTools/Translate/Providers/AIService.swift",
      ["硅基", "深度求索", "月之暗面", "通义", "千问", "百炼", "豆包", "火山方舟", "海螺", "智谱"],
      false, "服务名里认厂商的中文叫法"
    ),
    (
      "KittyTools/Translate/Providers/FreeProviders.swift",
      ["美", "英", "变形：", "美 /", "英 /", "例：%@"], false, "词典词条的内容和朗读要认的标记"
    ),
    (
      "KittyTools/Translate/Providers/Zhipu.swift",
      ["<原文>", "</原文>", "你是一部简明词典", "你是翻译引擎", "你是外语老师", "附加要求：", "外文"], false,
      "给大模型的提示词"
    ),
    (
      "KittyTools/Translate/SentenceExplain.swift", ["她刚坐下", "他一进门", "It started raining"], false,
      "给大模型照着写的讲解示例（issue #35）"
    ),
    ("KittyTools/Translate/Speaker.swift", ["例", "英"], false, "朗读认词典词条的标记"),
  ]

  /// 漏网检查（第 9 批）：源码（App 和访达扩展）里带汉字的字面量（插值外面有汉字的；注释、日志、断言、comment: 不算）要么是
  /// 目录的 key、显式 key 的中文默认值（去掉插值后对得上格式也算），要么在 notTranslated 里。元组字面量、三目写在可选参数里
  /// 这些写法编得过、却只把第一个分支抽进目录（TRANSLATION.md 二），英文界面露中文——这一条把它们找出来。
  /// 读源码、不靠构建产物，所以只能查「目录里有没有这个字」：有的照样可能是没抽进去的那个分支（它的 key 别处抽过、运行时查得到）
  @Test(arguments: [0, 1]) func sourceStringsAreInCatalog(_ catalog: Int) throws {
    let target = catalog == 0 ? "KittyTools" : "KittyToolsFinder"
    var known = Set<String>()
    for (key, entry) in try Self.catalog(Self.catalogs[catalog]) {
      known.insert(Self.shape(key))
      let localizations = entry["localizations"] as? [String: Any]
      for value in Self.values(localizations?["zh-Hans"]) { known.insert(Self.shape(value.text)) }
    }
    let punctuation = /[，。；：！？「」、…（）]/
    var problems: [String] = []
    // 白名单里列了的文件、真用上了的文件：列了却用不上的也报（改了代码、白名单没跟着删）
    var listed = Set<String>()
    var used = Set<String>()
    let folder = Self.macos.appending(path: target)
    let files =
      FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    #expect(files.count > 0)
    for url in files {
      let root = Self.macos.path(percentEncoded: false)
      let path = url.path(percentEncoded: false)
        .replacing(root.hasSuffix("/") ? root : root + "/", with: "", maxReplacements: 1)
      let allowed = Self.notTranslated.filter { $0.file == path }
      if !allowed.isEmpty { listed.insert(path) }
      for literal in Self.literals(in: try String(contentsOf: url, encoding: .utf8)) {
        let text = literal.text
        guard !literal.hidden, text.replacing("%@", with: "").contains(Self.han),
          !known.contains(text), !known.contains(Self.shape(text))
        else { continue }
        let excused = allowed.contains { entry in
          entry.texts.contains { $0 == text || ($0.count >= 3 && text.contains($0)) }
            || (entry.words
              && (text.contains("(?")
                || (text.count(where: { String($0).contains(Self.han) }) <= 6
                  && !text.contains(punctuation))))
        }
        if excused { used.insert(path) } else { problems.append("\(path):\(literal.line)：\(text)") }
      }
    }
    for path in listed.subtracting(used).sorted() {
      problems.append("\(path)：白名单里这个文件的条目已经用不上了，删掉")
    }
    #expect(
      problems.isEmpty,
      "不在目录里的中文字面量（改成能抽进目录的写法，或者是故意不翻的就加进 notTranslated）：\n\(problems.joined(separator: "\n"))")
  }

  /// 词法本身：注释、日志、comment: 跳过；插值换成 %@、里面的字面量照读；多行去缩进；正则里的引号不当字符串
  @Test func literalScanner() {
    let source = #"""
      // "注释里的"
      let a = "甲\(b ? "乙" : "丙")丁"  /* "块注释" */
      Log.storage.error("日志 \(x)")
      String(localized: "k", defaultValue: "默认", comment: "说明")
      let r = /"([^"]*)"/
      let m = """
          多行
            缩进
          """
      let raw = #"原样\n"#
      """#
    let texts = Self.literals(in: source).filter { !$0.hidden }.map(\.text)
    // 插值里的字面量先读完，外面那个收尾时才记下
    #expect(texts == ["乙", "丙", "甲%@丁", "k", "默认", "多行\n  缩进", #"原样\n"#])
    #expect(Self.literals(in: source).first { $0.text == "甲%@丁" }?.line == 2)
    #expect(Self.shape("已下载 %lld%%") == "已下载 %@%")
    #expect(Self.shape("%1$@ 和 %2$lld") == "%@ 和 %@")
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
    #expect(
      InterfaceLanguage.resolved(.english, system: ["zh-Hans"], localizations: ours) == .english)
  }

  @Test func upgradeKeepsChineseOnce() throws {
    let english = ["en-CN", "zh-Hans-CN"]
    let ours = ["zh-Hans", "en", "zh-Hant"]
    func run(_ stored: [String: Any], system: [String]) throws -> (kept: Bool, after: [String: Any])
    {
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
    #expect(
      try !run([Prefs.lastSeenVersion: "0.9.0", Prefs.languageIntroduced: true], system: english)
        .kept)
    // 新装跟系统
    let fresh = try run([:], system: english)
    #expect(!fresh.kept && fresh.after[Prefs.appleLanguages] == nil)
    // 系统中文在前、或者自己选过语言：不动
    #expect(try !run([Prefs.lastSeenVersion: "0.9.0"], system: ["zh-Hans-CN"]).kept)
    let chose = try run(
      [Prefs.lastSeenVersion: "0.9.0", Prefs.appleLanguages: ["en"]], system: english)
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
    #expect(
      try run([Prefs.lastSeenVersion: "0.9.0"], system: ["en-US"]).keys.sorted() == [
        Prefs.lastSeenVersion
      ])
    #expect(
      try run([Prefs.onboardingScreen: 1], system: ["en-US"]).keys.sorted() == [
        Prefs.onboardingScreen
      ])
    let chose = try run([Prefs.translateFirst: "ja"], system: ["en-US"])
    #expect(chose[Prefs.translateFirst] as? String == "ja" && chose[Prefs.translateSecond] == nil)
  }
}
