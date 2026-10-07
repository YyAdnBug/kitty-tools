import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Testing

@testable import KittyTools

/// 设置的导出与导入（Storage/SettingsArchive.swift）：导出只带改过的、文件往返、导入时整类替换 / 按 id 合并、
/// 读文件时的校验（别人给的、手改过的文件）、密钥的加解密；片段、文字收藏、生词本的导出和并进库（ClipboardStore.adopt、
/// HistoryStore.adoptFavorites）。全用临时偏好域、内存库和假的钥匙串读取，不碰用户的偏好、数据和钥匙串
struct SettingsArchiveTests {
  /// 整秒：文件里的时间是 ISO 8601，不带小数秒
  private static let moment = Date(timeIntervalSince1970: 1_760_000_000)

  private func suite() throws -> (defaults: UserDefaults, name: String) {
    let name = "kitty-test-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
  }

  private func stored(_ action: HotKeyAction, in defaults: UserDefaults) -> HotKey? {
    action.resolve { defaults.data(forKey: $0.prefsKey) }
  }

  private func archive(json: String) throws -> SettingsArchive {
    try SettingsArchive.read(Data(json.utf8))
  }

  /// 一个最小的合法文件，中间插别的字段
  private func file(_ body: String) -> String {
    #"{"app": "Kitty Tools", "format": 1, "version": "0.3.1", "#
      + #""exportedAt": "2026-10-07T08:00:00Z", \#(body)}"#
  }

  /// 内存库上的剪贴板仓库（图片目录是临时的，用不到）
  private func clipboard(_ db: Database? = nil) throws -> (store: ClipboardStore, db: Database) {
    let db = try db ?? Database(path: ":memory:")
    let images = ImageStore(
      directory: FileManager.default.temporaryDirectory.appending(
        path: "kitty-test-\(UUID().uuidString)"))
    return (try ClipboardStore(db: db, images: images), db)
  }

  private func clip(
    _ text: String, favorite: Bool = false, snippet: Bool = false, ago: TimeInterval = 0
  ) -> ClipItem {
    var item = ClipItem(kind: .text, copiedAt: Date.now.addingTimeInterval(-ago))
    item.text = text
    item.favorite = favorite
    item.isSnippet = snippet
    return item
  }

  private var ai: TranslateService {
    var service = TranslateService.newAI()
    service.id = "ai:1a2b3c4d"
    service.name = "DeepSeek"
    service.baseURL = "https://api.deepseek.com/v1"
    service.model = "deepseek-chat"
    return service
  }

  // MARK: 导出

  /// 注册了默认值的键都认得出类型（新加一个别的类型的设置时这里会挂），外加两个没有默认值的字符串键；
  /// 状态键、截图的存储文件夹、快捷键和两张列表不按偏好导出
  @Test func everyRegisteredDefaultIsExportable() {
    let kinds = SettingsArchive.kinds
    #expect(Set(kinds.keys).isSuperset(of: Prefs.defaults.keys))
    #expect(kinds.count == Prefs.defaults.count + 2)
    #expect(kinds[Prefs.translateSource] == .string)
    #expect(kinds[Prefs.clipboardExcludedBundleIDs] == .strings)
    #expect(kinds[Prefs.translateFontScale] == .double)
    #expect(kinds[Prefs.clipboardRetentionDays] == .int)
    #expect(kinds[Prefs.statusItemVisible] == .bool)
    for key in [
      Prefs.lastSeenVersion, Prefs.settingsPage, Prefs.screenshotLastRegion,
      Prefs.folderAccessRequested, Prefs.screenRecordingInProgress, Prefs.updateNotifiedVersion,
      Prefs.screenshotSaveDirectory,
      Prefs.launcherWebSearchEngines, HotKeyAction.clipboard.prefsKey, "translateServices",
    ] {
      #expect(kinds[key] == nil)
    }
  }

  /// 只带用户存过的：没碰过的设置不进文件（以后默认值变了跟着变）；快捷键分得清「设了」「清除了」「没动过」
  @Test func capturesOnlyWhatWasStored() throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: Prefs.statusItemVisible)
    defaults.set(30, forKey: Prefs.clipboardRetentionDays)
    defaults.set(1.2, forKey: Prefs.translateFontScale)
    defaults.set("dark", forKey: Prefs.appearance)
    defaults.set(["com.example.vault"], forKey: Prefs.clipboardExcludedBundleIDs)
    defaults.set("ja", forKey: Prefs.translateTarget)
    // 每台机器各自的：不导出
    defaults.set(NSHomeDirectory() + "/Pictures/Shots", forKey: Prefs.screenshotSaveDirectory)
    defaults.set("0.3.1", forKey: Prefs.lastSeenVersion)
    defaults.set("{{0, 0}, {10, 10}}", forKey: Prefs.screenshotLastRegion)
    defaults.set("100 100 780 600", forKey: "NSWindow Frame Settings")
    let combo = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)
    defaults.set(HotKeyAction.stored(combo), forKey: HotKeyAction.clipboard.prefsKey)
    defaults.set(HotKeyAction.stored(nil), forKey: HotKeyAction.launcher.prefsKey)
    let engines = [
      SearchEngine(
        id: "custom-1", name: "内网", keyword: "w", urlTemplate: "https://wiki.example/{query}",
        enabled: false)
    ]
    defaults.set(try JSONEncoder().encode(engines), forKey: Prefs.launcherWebSearchEngines)

    let archive = SettingsArchive.capture(
      from: defaults, domainName: name, services: [.zhipu, ai], version: "9.9.9",
      now: Self.moment)
    #expect(
      archive.preferences == [
        Prefs.statusItemVisible: .bool(false), Prefs.clipboardRetentionDays: .int(30),
        Prefs.translateFontScale: .double(1.2), Prefs.appearance: .string("dark"),
        Prefs.clipboardExcludedBundleIDs: .strings(["com.example.vault"]),
        Prefs.translateTarget: .string("ja"),
      ])
    // 设了的、清除了的（null）在文件里，没动过的不在
    #expect(archive.hotkeys == ["clipboard": combo, "launcher": nil])
    #expect(archive.searchEngines == engines)
    #expect(archive.translateServices == [.zhipu, ai])
    #expect(archive.secrets == nil)
    #expect(archive.sections == SettingsArchive.Section.allCases)
    #expect(archive.version == "9.9.9")
  }

  /// 没存过网页搜索的列表：导出默认的那几条（设置里看到的就是导出的）
  @Test func capturesDefaultEnginesWhenNeverStored() throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let archive = SettingsArchive.capture(from: defaults, domainName: name, services: [])
    #expect(archive.searchEngines == WebSearch.defaults)
    #expect(archive.preferences == [:])
    #expect(archive.hotkeys == [:])
  }

  /// 写成文件再读回来一模一样；没勾的类别不在文件里；文件名带当天日期
  @Test func fileRoundTrip() throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: Prefs.clipboardPastePlain)
    defaults.set(1.0, forKey: Prefs.translateFontScale)
    defaults.set(
      HotKeyAction.stored(HotKey(keyCode: kVK_F5, modifiers: 0)),
      forKey: HotKeyAction.screenshot.prefsKey)
    defaults.set(HotKeyAction.stored(nil), forKey: HotKeyAction.recognizeText.prefsKey)
    let archive = SettingsArchive.capture(
      from: defaults, domainName: name, services: [.zhipu, ai], version: "9.9.9",
      now: Self.moment)
    let data = try archive.encoded()
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains(#""app" : "Kitty Tools""#))
    #expect(text.contains(#""recognizeText" : null"#))
    #expect(text.contains("https://api.deepseek.com/v1"))  // 斜杠不转义，人看得懂
    // 1.0 写出来是 1：小数的键读回来照样是小数
    #expect(!text.contains("1.0"))
    #expect(try SettingsArchive.read(data) == archive)

    let partial = archive.keeping([.hotkeys])
    #expect(partial.sections == [.hotkeys])
    let partialText = try #require(String(data: partial.encoded(), encoding: .utf8))
    #expect(!partialText.contains("translateServices") && !partialText.contains("preferences"))
    #expect(try SettingsArchive.read(partial.encoded()).sections == [.hotkeys])

    #expect(
      SettingsArchive.fileName(now: Self.moment).wholeMatch(
        of: /Kitty Tools 设置 \d{4}-\d{2}-\d{2}\.json/) != nil)
  }

  // MARK: 导入

  /// 「设置」「快捷键」整类换成文件里的样子：文件里有的写上，没有的删掉（回到默认）；没勾的类别不动
  @Test func applyReplacesPreferencesAndHotkeys() throws {
    let (source, sourceName) = try suite()
    defer { source.removePersistentDomain(forName: sourceName) }
    source.set(true, forKey: Prefs.clipboardPastePlain)
    source.set(365, forKey: Prefs.clipboardRetentionDays)
    source.set(1.4, forKey: Prefs.translateFontScale)
    source.set(["com.example.vault"], forKey: Prefs.clipboardExcludedBundleIDs)
    let combo = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)
    source.set(HotKeyAction.stored(combo), forKey: HotKeyAction.clipboard.prefsKey)
    source.set(HotKeyAction.stored(nil), forKey: HotKeyAction.launcher.prefsKey)
    let archive = try SettingsArchive.read(
      SettingsArchive.capture(from: source, domainName: sourceName, services: []).encoded())

    let (target, targetName) = try suite()
    defer { target.removePersistentDomain(forName: targetName) }
    target.set(false, forKey: Prefs.clipboardPastePlain)  // 文件里有：换掉
    target.set(true, forKey: Prefs.translateAutoCopy)  // 文件里没有：回到默认
    target.set("0.3.1", forKey: Prefs.lastSeenVersion)  // 状态：不碰
    let other = HotKey(keyCode: kVK_ANSI_K, modifiers: controlKey)
    target.set(HotKeyAction.stored(other), forKey: HotKeyAction.screenshot.prefsKey)

    archive.apply([.preferences], to: target, domainName: targetName)
    var domain = target.persistentDomain(forName: targetName) ?? [:]
    #expect(domain[Prefs.clipboardPastePlain] as? Bool == true)
    #expect(domain[Prefs.clipboardRetentionDays] as? Int == 365)
    #expect(domain[Prefs.translateFontScale] as? Double == 1.4)
    #expect(domain[Prefs.clipboardExcludedBundleIDs] as? [String] == ["com.example.vault"])
    #expect(domain[Prefs.translateAutoCopy] == nil)
    #expect(domain[Prefs.lastSeenVersion] as? String == "0.3.1")
    // 快捷键那一类没勾：原样
    #expect(stored(.screenshot, in: target) == other)
    #expect(domain[HotKeyAction.clipboard.prefsKey] == nil)

    archive.apply([.hotkeys], to: target, domainName: targetName)
    domain = target.persistentDomain(forName: targetName) ?? [:]
    #expect(stored(.clipboard, in: target) == combo)
    #expect(stored(.launcher, in: target) == nil)
    #expect((domain[HotKeyAction.launcher.prefsKey] as? Data)?.isEmpty == true)
    // 文件里没有截图的键：本机改过的那个删掉，回到默认
    #expect(domain[HotKeyAction.screenshot.prefsKey] == nil)
    #expect(stored(.screenshot, in: target) == HotKeyAction.screenshot.defaultHotKey)
  }

  /// 文件把截图设成了剪贴板的默认键 ⌥C：导入后截图用它，没动过的剪贴板让位、当没设（不会两个动作抢同一个键）
  @Test func importedHotkeyTakesOverAnotherDefault() throws {
    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    let taken = try #require(HotKeyAction.clipboard.defaultHotKey)
    var archive = SettingsArchive(version: "1", exportedAt: Self.moment)
    archive.hotkeys = [HotKeyAction.screenshot.rawValue: taken]
    try SettingsArchive.read(archive.encoded()).apply([.hotkeys], to: target, domainName: name)
    #expect(stored(.screenshot, in: target) == taken)
    #expect(stored(.clipboard, in: target) == nil)
    #expect(stored(.launcher, in: target) == HotKeyAction.launcher.defaultHotKey)
  }

  /// 旧版本文件里已经不是档位的保留天数挪到现在的档位（Prefs.migrate），不留一个选择器显示不出来的值
  @Test func applyMovesLegacyChoices() throws {
    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    let archive = try archive(
      json: file(#""preferences": {"clipboardHistoryRetentionDays": 14}"#))
    archive.apply([.preferences], to: target, domainName: name)
    #expect(target.integer(forKey: Prefs.clipboardRetentionDays) == 30)
  }

  /// 两张列表按 id 合并：文件里的在前（同 id 的换成文件里的），本机独有的接在后面、不删
  @Test func applyMergesLists() throws {
    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    func engine(_ id: String, _ keyword: String) -> SearchEngine {
      SearchEngine(
        id: id, name: id, keyword: keyword, urlTemplate: "https://\(id).example/?q={query}",
        enabled: false)
    }
    target.set(
      try JSONEncoder().encode([engine("google", "g"), engine("custom-mine", "m")]),
      forKey: Prefs.launcherWebSearchEngines)
    var archive = SettingsArchive(version: "1", exportedAt: Self.moment)
    archive.searchEngines = [engine("custom-theirs", "t h"), engine("google", "gg")]
    try SettingsArchive.read(archive.encoded()).apply([.engines], to: target, domainName: name)
    let merged = SearchEngineDetail.decode(target.data(forKey: Prefs.launcherWebSearchEngines))
    #expect(merged.map(\.id) == ["custom-theirs", "google", "custom-mine"])
    // 关键词里不能有空格（同设置页写回时）
    #expect(merged.map(\.keyword) == ["th", "gg", "m"])

    var mine = ai
    mine.id = "ai:0000aaaa"
    var theirs = TranslateService.zhipu
    theirs.isEnabled = false
    let services = SettingsArchive.merge([ai, theirs], into: [.zhipu, mine])
    #expect(services.map(\.id) == ["ai:1a2b3c4d", "zhipu", "ai:0000aaaa"])
    #expect(services[1].isEnabled == false)
  }

  // MARK: 读文件时的校验

  @Test func rejectsFilesThatAreNotOurs() throws {
    func failure(_ text: String) -> SettingsArchive.Failure? {
      do {
        _ = try SettingsArchive.read(Data(text.utf8))
        return nil
      } catch {
        return error as? SettingsArchive.Failure
      }
    }
    #expect(failure("不是 JSON") == .notArchive)
    #expect(failure(#"{"name": "别的 App 的配置", "format": 1}"#) == .notArchive)
    #expect(failure(#"{"app": "Kitty Tools"}"#) == .notArchive)
    #expect(failure(#"{"app": "Kitty Tools", "format": 2, "version": "9"}"#) == .newer)
    // 内容本身读得出来、只是格式号不对的：更新的说「先更新」，0 和负数不认
    let valid = file(#""preferences": {}"#)
    #expect(failure(valid.replacing(#""format": 1"#, with: #""format": 2"#)) == .newer)
    #expect(failure(valid.replacing(#""format": 1"#, with: #""format": 0"#)) == .notArchive)
    #expect(failure(valid.replacing("Kitty Tools", with: "Other App")) == .notArchive)
    // 标记和版本对，里面的东西不对
    #expect(failure(file(#""hotkeys": "全部""#)) == .unreadable)
    #expect(
      failure(file(#""translateServices": [{"id": "x", "kind": "telepathy"}]"#)) == .unreadable)
    #expect(failure(#"{"app": "Kitty Tools", "format": 1}"#) == .unreadable)
    // 超过大小上限的不读（内容本身是合法的，后面垫空格垫过了上限）
    var oversized = Data(file(#""preferences": {}"#).utf8)
    oversized.append(Data(repeating: 0x20, count: SettingsArchive.maxFileSize))
    #expect(throws: SettingsArchive.Failure.notArchive) { try SettingsArchive.read(oversized) }
    #expect(failure(file(#""preferences": {}"#)) == nil)
  }

  /// 读用户选的文件：只读到上限多一个字节（再大的不认）；正常的文件读得出来
  @Test func readsFilesUpToTheSizeLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "kitty-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let good = directory.appending(path: "good.json")
    try Data(file(#""hotkeys": {}"#).utf8).write(to: good)
    #expect(try SettingsArchive.read(contentsOf: good).sections == [.hotkeys])
    let huge = directory.appending(path: "huge.json")
    try Data(repeating: 0x20, count: SettingsArchive.maxFileSize + 1).write(to: huge)
    #expect(throws: SettingsArchive.Failure.notArchive) {
      try SettingsArchive.read(contentsOf: huge)
    }
    #expect(throws: (any Error).self) {
      try SettingsArchive.read(contentsOf: directory.appending(path: "没有这个文件.json"))
    }
  }

  /// 字符串、数组、整数的上限：超了的那一项不要
  @Test func dropsOversizedPreferences() throws {
    let long = String(repeating: "x", count: 4097)
    let many = (0..<1001).map { #""a\#($0)""# }.joined(separator: ",")
    let wide = String(repeating: "y", count: 513)
    func kept(_ preferences: String) throws -> [String: SettingsArchive.Value]? {
      try archive(json: file(#""preferences": {\#(preferences)}"#)).preferences
    }
    #expect(try kept(#""translateCollapsedServices": "\#(long)""#) == [:])
    #expect(try kept(#""clipboardExcludedBundleIDs": [\#(many)]"#) == [:])
    #expect(try kept(#""clipboardExcludedBundleIDs": ["\#(wide)"]"#) == [:])
    #expect(try kept(#""clipboardImageCacheMaxMb": 1000001"#) == [:])
    #expect(
      try kept(#""clipboardImageCacheMaxMb": 1000000"#)
        == [Prefs.clipboardImageBudgetMB: .int(1_000_000)])
    // 最大的值乘成字节也不溢出
    #expect(1_000_000.multipliedReportingOverflow(by: 1_048_576).overflow == false)
  }

  /// 不认识的键、类型或范围不对的值都丢掉（导入时这些键回到默认）；译文字号夹进滑块的范围；
  /// 截图的存储文件夹不收（别人给的文件不能改截图存到哪）
  @Test func dropsInvalidPreferences() throws {
    let archive = try archive(
      json: file(
        """
        "preferences": {
          "appearance": "dark", "statusItemVisible": "yes", "clipboardImageCacheMaxMb": 9000000000000,
          "clipboardHistoryRetentionDays": -1, "translateHistoryLimit": 1000, "translateFontScale": 9,
          "clipboardExcludedBundleIDs": ["a.b", "c.d"], "autoCopy": 1, "lastSeenVersion": "0.0.1",
          "NSWindow Frame Settings": "0 0 1 1", "ocrJoinLines": null, "translateWordMode": {"a": 1},
          "screenshotSaveDirectory": "/Users/Shared", "launcherRomanInput": true
        }
        """))
    #expect(
      archive.preferences == [
        Prefs.appearance: .string("dark"), Prefs.translateHistoryLimit: .int(1000),
        Prefs.translateFontScale: .double(TranslateCoordinator.fontScales.upperBound),
        Prefs.clipboardExcludedBundleIDs: .strings(["a.b", "c.d"]),
        Prefs.launcherRomanInput: .bool(true),
      ])

    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    target.set(4096, forKey: Prefs.clipboardImageBudgetMB)
    target.set("/tmp", forKey: Prefs.screenshotSaveDirectory)
    archive.apply([.preferences], to: target, domainName: name)
    let domain = target.persistentDomain(forName: name) ?? [:]
    // 本机选的存储文件夹不是文件管的：不改也不删
    #expect(domain[Prefs.screenshotSaveDirectory] as? String == "/tmp")
    // 超大的值没写进去（按 MB 乘成字节会溢出），本机原来的也按「文件里没有」删掉
    #expect(domain[Prefs.clipboardImageBudgetMB] == nil)
    #expect(domain[Prefs.statusItemVisible] == nil)
    #expect(domain[Prefs.lastSeenVersion] == nil)
    #expect(
      domain[Prefs.translateFontScale] as? Double == TranslateCoordinator.fontScales.upperBound)
  }

  /// 快捷键过录制框的规则：没带 ⌘ / ⌃ / ⌥（F 键除外）、各 App 通用的编辑键、范围外的键码和修饰键位都不要；
  /// 重复的组合留给靠前的动作；不认识的动作丢掉；null（清除了）照留
  @Test func dropsUnusableHotkeys() throws {
    #expect(HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey).isUsable)
    #expect(HotKey(keyCode: kVK_F13, modifiers: 0).isUsable)
    #expect(!HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey).isUsable)
    #expect(!HotKey(keyCode: kVK_ANSI_A, modifiers: shiftKey).isUsable)
    #expect(!HotKey(keyCode: 500, modifiers: cmdKey).isUsable)
    #expect(!HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey | 1 << 20).isUsable)
    let archive = try archive(
      json: file(
        """
        "hotkeys": {
          "clipboard": {"keyCode": \(kVK_ANSI_V), "modifiers": \(cmdKey | shiftKey)},
          "launcher": {"keyCode": \(kVK_ANSI_V), "modifiers": \(cmdKey | shiftKey)},
          "selectionTranslate": {"keyCode": \(kVK_ANSI_C), "modifiers": \(cmdKey)},
          "inputTranslate": {"keyCode": \(kVK_ANSI_A), "modifiers": 0},
          "screenshot": {"keyCode": 500, "modifiers": \(cmdKey)},
          "recognizeText": null,
          "audioRecord": {"keyCode": \(kVK_F13), "modifiers": 0},
          "selfDestruct": {"keyCode": \(kVK_ANSI_X), "modifiers": \(controlKey)}
        }
        """))
    #expect(
      archive.hotkeys == [
        "clipboard": HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey),
        "recognizeText": nil, "audioRecord": HotKey(keyCode: kVK_F13, modifiers: 0),
      ])
  }

  /// 服务的 id 是钥匙串账户名的前半截：内置服务必须等于种类名，AI 服务必须是 ai:xxxx；重复的只留第一个
  @Test func dropsServicesAndEnginesWithBadIDs() throws {
    func service(_ id: String, _ kind: String) -> String {
      #"{"id": "\#(id)", "kind": "\#(kind)", "name": "n", "isEnabled": true}"#
    }
    func engine(_ id: String) -> String {
      #"{"id": "\#(id)", "name": "n", "keyword": "", "urlTemplate": "https://e.example", "enabled": false}"#
    }
    let services = [
      service("zhipu", "zhipu"), service("zhipu", "ai"), service("baidu", "deepl"),
      service("ai:1a2b3c4d", "ai"), service("ai:1a2b3c4d", "ai"), service("ai:../../x", "ai"),
      service("ai:", "ai"), service("deepl", "deepl"),
    ]
    let engines = [engine("google"), engine(""), engine("google"), engine("custom-1")]
    let archive = try archive(
      json: file(
        #""translateServices": [\#(services.joined(separator: ","))], "#
          + #""searchEngines": [\#(engines.joined(separator: ","))]"#))
    #expect(archive.translateServices?.map(\.id) == ["zhipu", "ai:1a2b3c4d", "deepl"])
    #expect(archive.translateServices?.map(\.kind) == [.zhipu, .ai, .deepl])
    #expect(archive.searchEngines?.map(\.id) == ["google", "custom-1"])

    // 字段长得离谱的整条不要（不截断）；区域只收字母、数字、连字符
    var longName = ai
    longName.name = String(repeating: "名", count: 201)
    var longAddress = ai
    longAddress.id = "ai:2b3c4d5e"
    longAddress.baseURL = "https://a.example/" + String(repeating: "p", count: 2048)
    var badRegion = TranslateService.builtin(.microsoft)
    badRegion.region = "eastasia\r\nX-Injected: 1"
    var goodRegion = TranslateService.builtin(.baidu)
    goodRegion.region = "southeast-asia2"
    var long = SettingsArchive(version: "1", exportedAt: Self.moment)
    long.translateServices = [longName, longAddress, badRegion, goodRegion, .zhipu]
    long.searchEngines = [
      SearchEngine(
        id: "a", name: "n", keyword: "k",
        urlTemplate: "https://a.example/" + String(repeating: "q", count: 2048), enabled: false),
      SearchEngine(
        id: "b", name: String(repeating: "n", count: 201), keyword: "k",
        urlTemplate: "https://b.example", enabled: false),
      SearchEngine(
        id: "c", name: "n", keyword: String(repeating: "k", count: 65),
        urlTemplate: "https://c.example", enabled: false),
      SearchEngine(
        id: "d", name: "n", keyword: "k", urlTemplate: "https://d.example", enabled: true),
    ]
    let cleaned = try SettingsArchive.read(long.encoded())
    #expect(cleaned.translateServices?.map(\.id) == ["baidu", "zhipu"])
    #expect(cleaned.searchEngines?.map(\.id) == ["d"])
  }

  /// 导入前列给用户看的地址：AI 服务补全后的主机名（带端口的连端口）、DeepLX 的地址；内置服务的官方接口不列，重复的只列一次
  @Test func listsCustomHosts() throws {
    func service(_ name: String, _ address: String, _ kind: TranslateService.AIProtocol = .openai)
      -> TranslateService
    {
      var service = TranslateService.newAI()
      service.name = name
      service.baseURL = address
      service.aiProtocol = kind
      return service
    }
    var deepLX = TranslateService.builtin(.deepl)
    deepLX.usesDeepLX = true
    deepLX.baseURL = "192.168.1.8:1188/translate"
    var archive = SettingsArchive(version: "1", exportedAt: Self.moment)
    archive.translateServices = [
      .zhipu, service("OpenAI", "https://api.openai.com@evil.example/v1"),
      service("本机", "http://127.0.0.1:11434/v1"), service("Claude", "", .anthropic),
      service("没填地址", ""), service("又一个", "evil.example"), .builtin(.deepl), deepLX,
    ]
    #expect(
      archive.customHosts == [
        "evil.example", "127.0.0.1:11434", "api.anthropic.com", "192.168.1.8:1188",
      ])
    #expect(SettingsArchive(version: "1", exportedAt: Self.moment).customHosts == [])

    // 启用的排前面（导入后马上会用到的）：藏在一长串停用的服务后面也排第一
    var enabled = service("启用的", "https://last.example/v1")
    enabled.isEnabled = true
    archive.translateServices?.append(enabled)
    #expect(archive.customHosts.first == "last.example")
    #expect(archive.customHosts.count == 5)

    // DeepLX 地址开头带空格：发请求时会去掉空格照样连过去，这里也得列出来（和 DeepL.stream 同一个解析）
    var padded = TranslateService.builtin(.deepl)
    padded.usesDeepLX = true
    padded.baseURL = " https://padded.example/translate"
    // 认不出主机的地址把填的原样列出来，不跳过
    archive.translateServices = [padded, service("怪地址", " ::::\n")]
    #expect(archive.customHosts == ["padded.example", "::::"])
    #expect(DeepL.deepLXURL(padded)?.host() == "padded.example")
    #expect(DeepL.deepLXURL(.builtin(.deepl)) == nil)
  }

  /// 导入「设置」会让隐私保护变弱时逐条说出来：关掉敏感过滤、不记录的 App 变少、新打开复制即译；文件里没有的键按默认值算
  @Test func listsPrivacyLosses() throws {
    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    func losses(_ preferences: String) throws -> [String] {
      try archive(json: file(#""preferences": {\#(preferences)}"#))
        .privacyLosses(comparedTo: target)
    }
    target.set(true, forKey: Prefs.clipboardBlockSensitive)
    target.set(false, forKey: Prefs.translateCopyToTranslate)
    target.set(ClipboardFilter.defaultExcluded, forKey: Prefs.clipboardExcludedBundleIDs)
    // 什么都没改的文件 = 都回到默认：和现在一样，不提醒
    #expect(try losses("") == [])
    #expect(try losses(#""clipboardBlockSensitive": false"#).count == 1)
    #expect(try losses(#""clipboardExcludedBundleIDs": []"#).count == 1)
    #expect(try losses(#""translateClipboardMonitor": true"#).count == 1)
    #expect(
      try losses(
        #""clipboardBlockSensitive": false, "clipboardExcludedBundleIDs": ["a.b"], "#
          + #""translateClipboardMonitor": true"#
      ).count == 3)
    // 本机多排除了一个 App，文件里没有它（回到默认列表）：也算变少
    target.set(
      ClipboardFilter.defaultExcluded + ["com.example.vault"],
      forKey: Prefs.clipboardExcludedBundleIDs)
    #expect(try losses("").count == 1)
    let more = (ClipboardFilter.defaultExcluded + ["com.example.vault", "x.y"])
      .map { #""\#($0)""# }.joined(separator: ",")
    #expect(try losses(#""clipboardExcludedBundleIDs": [\#(more)]"#) == [])
    // 本机已经关着 / 开着的不算
    target.set(false, forKey: Prefs.clipboardBlockSensitive)
    target.set(true, forKey: Prefs.translateCopyToTranslate)
    #expect(
      try losses(
        #""clipboardBlockSensitive": false, "translateClipboardMonitor": true, "#
          + #""clipboardExcludedBundleIDs": [\#(more)]"#) == [])
    // 不带「设置」这一类的文件不提醒
    #expect(try archive(json: file(#""hotkeys": {}"#)).privacyLosses(comparedTo: target) == [])
  }

  // MARK: 密钥

  /// 按密码算密钥：RFC 7914 §11 的 PBKDF2-HMAC-SHA256 测试向量（P = "passwd"、S = "salt"、c = 1 的前 32 字节）
  @Test func keyDerivationMatchesTestVector() throws {
    let key = try SettingsArchive.key(password: "passwd", salt: Data("salt".utf8), rounds: 1)
    #expect(
      key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    // 同一个字的两种码位序列（é 的合成 / 分解）算出同一把密钥
    let composed = try SettingsArchive.key(password: "caf\u{E9}", salt: Data(), rounds: 2)
    let decomposed = try SettingsArchive.key(password: "cafe\u{301}", salt: Data(), rounds: 2)
    #expect(composed == decomposed)
  }

  /// 密钥只从钥匙串读这些服务自己的字段；封进文件后文件里没有明文；密码对才解得开；
  /// 解出来的只收这次导入的服务自己的字段
  @Test func secretsAreSealedWithThePassword() throws {
    let keychain = [
      "zhipu.apiKey": "sk-zhipu-明文", "ai:1a2b3c4d.apiKey": "sk-deepseek-明文",
      "baidu.appId": "不在导出的列表里", "ai:1a2b3c4d.other": "不是这个服务的字段",
    ]
    let secrets = SettingsArchive.secrets(of: [.zhipu, ai, .builtin(.deepl)]) { keychain[$0] }
    #expect(
      secrets == ["zhipu.apiKey": "sk-zhipu-明文", "ai:1a2b3c4d.apiKey": "sk-deepseek-明文"])

    var archive = SettingsArchive(version: "1", exportedAt: Self.moment)
    archive.translateServices = [.zhipu, ai]
    try archive.seal(secrets, password: "correct horse 电池")
    let data = try archive.encoded()
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("sk-zhipu") && !text.contains("sk-deepseek") && !text.contains("明文"))
    #expect(archive.secrets?.rounds == SettingsArchive.rounds)
    #expect(archive.secrets?.salt.count == 16)

    let back = try SettingsArchive.read(data)
    #expect(try back.unseal(password: "correct horse 电池") == secrets)
    #expect(throws: SettingsArchive.Failure.wrongPassword) {
      try back.unseal(password: "correct horse 电池 ")
    }
    // 每次封都是新的盐和随机数
    var again = archive
    try again.seal(secrets, password: "correct horse 电池")
    #expect(again.secrets?.salt != archive.secrets?.salt)
    #expect(again.secrets?.sealed != archive.secrets?.sealed)

    // 密文被改过
    var tampered = back
    tampered.secrets?.sealed[20] ^= 1
    #expect(throws: SettingsArchive.Failure.wrongPassword) {
      try tampered.unseal(password: "correct horse 电池")
    }
    // 密钥和服务往哪发请求绑在一起：文件里某个服务的地址、协议被人改了，或者多了少了服务，密码对也解不开
    for change: (inout SettingsArchive) -> Void in [
      { $0.translateServices?[1].baseURL = "https://evil.example/v1" },
      { $0.translateServices?[1].aiProtocol = .anthropic },
      { $0.translateServices?.removeLast() },
      { $0.translateServices?.append(.builtin(.deepl)) },
    ] {
      var redirected = back
      change(&redirected)
      #expect(throws: SettingsArchive.Failure.wrongPassword) {
        try redirected.unseal(password: "correct horse 电池")
      }
    }
    // 不决定往哪发的字段（名字、模型、开关）改了不影响
    var renamed = back
    renamed.translateServices?[1].name = "改了个名"
    renamed.translateServices?[1].isEnabled.toggle()
    #expect(try renamed.unseal(password: "correct horse 电池") == secrets)

    // 轮数离谱、盐太短太长、密文短得不成样子、算法不认识：读不出来（不去算）
    for change: (inout SettingsArchive.Sealed) -> Void in [
      { $0.rounds = 0 }, { $0.rounds = -1 }, { $0.rounds = 10_000_001 },
      { $0.rounds = 2_000_000_000 }, { $0.salt = Data(count: 7) }, { $0.salt = Data(count: 65) },
      { $0.sealed = Data(count: 27) }, { $0.kdf = "rot13" },
    ] {
      var broken = back
      if var sealed = broken.secrets {
        change(&sealed)
        broken.secrets = sealed
      }
      #expect(throws: SettingsArchive.Failure.unreadable) {
        try broken.unseal(password: "correct horse 电池")
      }
    }
    // 校验过了、里面却不是「账户名 → 值」：读不出来，不是密码不对
    let salt = Data(repeating: 7, count: 16)
    let key = try SettingsArchive.key(password: "pw", salt: salt, rounds: 1000)
    var odd = SettingsArchive(version: "1", exportedAt: Self.moment)
    odd.translateServices = []
    odd.secrets = SettingsArchive.Sealed(
      rounds: 1000, salt: salt,
      sealed: try #require(
        try AES.GCM.seal(Data("[1, 2]".utf8), using: key, authenticating: Data()).combined))
    #expect(throws: SettingsArchive.Failure.unreadable) { try odd.unseal(password: "pw") }
    #expect(throws: SettingsArchive.Failure.unreadable) {
      try SettingsArchive(version: "1", exportedAt: Self.moment).unseal(password: "pw")
    }

    // 文件说的账户名不全信：只收列表里的服务自己的字段
    #expect(
      back.accepted([
        "zhipu.apiKey": "a", "ai:1a2b3c4d.apiKey": "b", "baidu.appId": "c", "zhipu.other": "d",
        "ai:ffffffff.apiKey": "e", "com.apple.account": "f",
      ]) == ["zhipu.apiKey": "a", "ai:1a2b3c4d.apiKey": "b"])
    // 空的、长得离谱的值不存
    #expect(
      back.accepted([
        "zhipu.apiKey": "", "ai:1a2b3c4d.apiKey": String(repeating: "k", count: 4097),
      ]) == [:])
    // 不导出翻译服务就不带密钥；文件里只有密钥没有服务的，读的时候丢掉
    #expect(archive.keeping([.preferences, .hotkeys, .engines]).secrets == nil)
    var orphan = archive
    orphan.translateServices = nil
    #expect(try SettingsArchive.read(orphan.encoded()).secrets == nil)
  }

  /// 导入的整条路：密码不对时什么都不写；对了才写偏好、合并服务、存这些服务自己的密钥；不填密码只导入服务
  @Test func installWritesNothingOnWrongPassword() throws {
    let (source, sourceName) = try suite()
    defer { source.removePersistentDomain(forName: sourceName) }
    source.set(true, forKey: Prefs.clipboardPastePlain)
    var archive = SettingsArchive.capture(
      from: source, domainName: sourceName, services: [.zhipu, ai], now: Self.moment)
    try archive.seal(
      ["zhipu.apiKey": "sk-zhipu", "ai:1a2b3c4d.apiKey": "sk-deepseek", "baidu.appId": "别人的"],
      password: "correct horse 电池")
    archive = try SettingsArchive.read(archive.encoded())

    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    var mine = ai
    mine.id = "ai:0000aaaa"
    let services = TranslateServiceStore(services: [mine])
    var keychain: [String: String] = [:]
    let all = Set(SettingsArchive.Section.allCases)
    #expect(throws: SettingsArchive.Failure.wrongPassword) {
      try archive.install(
        all, password: "不对的密码", services: services, to: target, domainName: name
      ) { keychain[$0] = $1 }
    }
    #expect(target.persistentDomain(forName: name)?.isEmpty != false)
    #expect(services.services == [mine])
    #expect(keychain.isEmpty)

    // 不填密码：服务照导入，密钥不动
    #expect(
      try archive.install(all, services: services, to: target, domainName: name) {
        keychain[$0] = $1
      }.secrets == 0)
    #expect(services.services.map(\.id) == ["zhipu", "ai:1a2b3c4d", "ai:0000aaaa"])
    #expect(target.bool(forKey: Prefs.clipboardPastePlain))
    #expect(keychain.isEmpty)

    #expect(
      try archive.install(
        all, password: "correct horse 电池", services: services, to: target, domainName: name
      ) { keychain[$0] = $1 }.secrets == 2)
    #expect(keychain == ["zhipu.apiKey": "sk-zhipu", "ai:1a2b3c4d.apiKey": "sk-deepseek"])
    // 再导一遍不会多出重复的服务
    #expect(services.services.map(\.id) == ["zhipu", "ai:1a2b3c4d", "ai:0000aaaa"])

    // 没勾翻译服务：密码填了也不碰服务和密钥
    keychain = [:]
    let untouched = TranslateServiceStore(services: [mine])
    #expect(
      try archive.install(
        [.preferences], password: "correct horse 电池", services: untouched, to: target,
        domainName: name
      ) { keychain[$0] = $1 } == SettingsArchive.Outcome())
    #expect(untouched.services == [mine] && keychain.isEmpty)
  }

  // MARK: 片段、收藏、生词本

  /// 只带用户留下的文字：片段、文字类的收藏（连备注、所在收藏夹的名字、时间）；普通历史、图片和文件类的收藏不带；
  /// 收藏夹的名字按顺序（空的也带）；生词本只带收藏的翻译。写成文件再读回来一样
  @Test func capturesOnlyRetainedText() throws {
    let (store, _) = try clipboard()
    store.record(clip("普通历史，不导出"))
    store.record(clip("你好，{clipboard}", snippet: true, ago: 30))
    var link = clip("https://developer.apple.com", favorite: true, ago: 20)
    link.note = "文档"
    store.record(link)
    let work = try #require(store.createGroup(named: "工作"))
    store.createGroup(named: "空的")
    store.assign([link.id], to: work.id)
    var picture = ClipItem(kind: .image, copiedAt: Date.now.addingTimeInterval(-10))
    picture.image = .init(width: 4, height: 4, byteCount: 16, sha256: "test")
    picture.ocrText = ""
    picture.favorite = true
    store.record(picture)
    var file = ClipItem(kind: .file, copiedAt: Date.now.addingTimeInterval(-5))
    file.filePaths = ["/Applications/Safari.app"]
    file.favorite = true
    store.record(file)

    let history = try HistoryStore(db: Database(path: ":memory:"))
    history.add(source: "ordinary", target: .zhHans, result: "普通的", service: "智谱", limit: 0)
    history.setFavorite(
      source: "serendipity", target: .zhHans, result: "意外发现美好事物的运气", service: "智谱", true)

    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let archive = SettingsArchive.capture(
      from: defaults, domainName: name, services: [], clips: store.items, groups: store.groups,
      words: history.search("", limit: 0), version: "9.9.9", now: Self.moment)
    let clips = try #require(archive.clips)
    #expect(clips.map(\.text) == ["https://developer.apple.com", "你好，{clipboard}"])
    #expect(clips[0].favorite && !clips[0].snippet && clips[0].note == "文档")
    #expect(clips[0].group == "工作")
    #expect(clips[1].snippet && !clips[1].favorite && clips[1].group == nil && clips[1].note == nil)
    #expect(archive.clipGroups == ["工作", "空的"])
    #expect(archive.vocabulary?.map(\.source) == ["serendipity"])
    #expect(archive.vocabulary?.first?.target == Lang.zhHans.rawValue)

    let data = try archive.encoded()
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("你好，{clipboard}") && !text.contains("普通历史") && !text.contains("Safari"))
    let back = try SettingsArchive.read(data)
    // 文件里的时间精确到秒
    #expect(back.clips?.map(\.text) == clips.map(\.text))
    #expect(back.clips?.map(\.group) == clips.map(\.group))
    #expect(back.clipGroups == archive.clipGroups)
    #expect(back.vocabulary?.map(\.result) == ["意外发现美好事物的运气"])
    // 不勾就不在文件里；收藏夹跟着片段与收藏一起
    let kept = archive.keeping([.vocabulary])
    #expect(kept.clips == nil && kept.clipGroups == nil && kept.sections == [.vocabulary])
  }

  /// 片段和文字收藏并进库：已有同样正文的只补标记（收藏、片段取并集；原来有的备注、收藏夹不换），时间和位置不动；
  /// 没有的新建，按原来的时间排进去（未来的时间算现在）；收藏夹按名字对、没有的新建；文件里重复的正文并成一条；
  /// 删了还没提交的先提交，不会变成两条。再导一遍什么都不变。库里的和内存里的一致
  @Test func adoptMergesClipsIntoTheStore() throws {
    let (store, db) = try clipboard()
    // 按时间先后记：列表平时就是按复制时间新→旧的
    store.record(clip("C：删了还没提交的", ago: 120))
    let doomed = try #require(store.items.first).id
    var local = clip("B：本机已经收藏", favorite: true, ago: 60)
    local.note = "本机的备注"
    store.record(local)
    store.record(clip("A：普通历史里已有"))
    let personal = try #require(store.createGroup(named: "个人"))
    store.assign([local.id], to: personal.id)
    store.deleteWithUndo([doomed])
    let before = store.items

    func incoming(
      _ text: String, favorite: Bool = false, snippet: Bool = false, note: String? = nil,
      group: String? = nil, ago: TimeInterval = 0
    ) -> SettingsArchive.Clip {
      SettingsArchive.Clip(
        text: text, note: note, favorite: favorite, snippet: snippet, group: group,
        copiedAt: Date.now.addingTimeInterval(-ago))
    }
    let clips = [
      incoming("E：时间在未来", favorite: true, ago: -86_400),
      incoming("A：普通历史里已有", snippet: true, note: "文件的备注", group: "工作"),
      incoming("B：本机已经收藏", favorite: true, note: "文件的备注", group: "工作"),
      incoming("C：删了还没提交的", favorite: true, ago: 10),
      incoming("D：一年前的片段", snippet: true, ago: 365 * 86_400),
      incoming("D：一年前的片段", favorite: true, group: "新的"),
    ]
    let result = store.adopt(clips, groups: ["工作", "空收藏夹", "个人"])
    #expect(result.added == 3 && result.updated == 1)
    #expect(!store.canUndo)
    #expect(store.groups.map(\.name) == ["个人", "工作", "空收藏夹", "新的"])
    func item(_ prefix: String) throws -> ClipItem {
      try #require(store.items.first { $0.text?.hasPrefix(prefix) == true })
    }
    func group(_ name: String) -> UUID? { store.groups.first { $0.name == name }?.id }
    // A：补上片段、备注、收藏夹（归了收藏夹就是收藏），时间不动
    let a = try item("A")
    #expect(a.isSnippet && a.favorite && a.note == "文件的备注" && a.groupID == group("工作"))
    #expect(a.copiedAt == before.first { $0.text == a.text }?.copiedAt)
    // B：本机的备注、收藏夹留着
    #expect(try item("B") == before.first { $0.id == local.id })
    // C：先提交了删除，再按文件新建一条（不是两条）
    #expect(store.items.filter { $0.text?.hasPrefix("C") == true }.count == 1)
    #expect(try item("C").id != doomed && item("C").favorite)
    // D：文件里的两条并成一条
    let d = try item("D")
    #expect(d.isSnippet && d.favorite && d.groupID == group("新的"))
    #expect(store.items.filter { $0.text == d.text }.count == 1)
    // E：未来的时间算现在，排在最前；一年前的排在最后
    #expect(store.items.first?.text == "E：时间在未来")
    #expect(try item("E").copiedAt <= .now)
    #expect(store.items.last?.id == d.id)
    #expect(store.items.map(\.copiedAt) == store.items.map(\.copiedAt).sorted(by: >))
    #expect(store.items.allSatisfy { $0.groupID == nil || $0.favorite })

    // 库里的和内存里的一致（重新读一遍）
    let reopened = try clipboard(db).store
    #expect(reopened.items == store.items)
    #expect(reopened.groups == store.groups)
    // 再导一遍：什么都不变
    let again = store.adopt(clips, groups: ["工作", "空收藏夹", "个人"])
    #expect(again.added == 0 && again.updated == 0)
    #expect(store.items == reopened.items)
  }

  /// 文件里的时间只到秒：同一秒的几条、未来的时间（都算现在）导入后顺序和文件里一样，库里读回来也一样
  @Test func adoptKeepsFileOrderForEqualTimestamps() throws {
    let (store, db) = try clipboard()
    store.record(clip("本机的，更早", favorite: true, ago: 3600))
    let second = Date(
      timeIntervalSinceReferenceDate: (Date.now.timeIntervalSinceReferenceDate - 60).rounded())
    let future = Date.now.addingTimeInterval(86_400)
    func incoming(_ text: String, at date: Date) -> SettingsArchive.Clip {
      SettingsArchive.Clip(text: text, favorite: true, snippet: false, copiedAt: date)
    }
    let clips = [
      incoming("未来 1", at: future), incoming("未来 2", at: future),
      incoming("同一秒 1", at: second), incoming("同一秒 2", at: second),
      incoming("同一秒 3", at: second),
    ]
    #expect(store.adopt(clips, groups: []).added == 5)
    #expect(store.items.map(\.text) == clips.map(\.text) + ["本机的，更早"])
    #expect(try clipboard(db).store.items == store.items)
  }

  /// 已有的带格式条目补上标记后格式还在（正文没变）；撤销栈里删掉的收藏夹：先提交，文件里同名的按新的建
  @Test func adoptKeepsRichTextAndCommitsPendingUndo() throws {
    let (store, _) = try clipboard()
    var rich = clip("带格式的一段")
    rich.richType = .rtf
    store.record(rich, rich: Data("{\\rtf1 带格式的一段}".utf8))
    let old = try #require(store.createGroup(named: "工作"))
    store.assign([rich.id], to: old.id)
    store.deleteGroup(old.id)
    #expect(store.canUndo && store.groups.isEmpty)

    let result = store.adopt(
      [
        SettingsArchive.Clip(
          text: "带格式的一段", favorite: false, snippet: true, group: "工作", copiedAt: .now)
      ], groups: [])
    #expect(result.added == 0 && result.updated == 1)
    #expect(!store.canUndo)
    let item = try #require(store.items.first)
    #expect(item.id == rich.id && item.isSnippet && item.favorite && item.richType == .rtf)
    #expect(store.groups.map(\.name) == ["工作"])
    #expect(item.groupID == store.groups.first?.id && item.groupID != old.id)
    // 粘贴时格式还读得出来
    #expect(store.pasteboardItems(for: item).first?.data(forType: .rtf) != nil)
  }

  /// 生词本并进库：没有的按原来的时间记成收藏（未来的时间算现在）；已有的只标成收藏，译文和时间不动；再导一遍不变
  @Test func adoptFavoritesMergesVocabulary() throws {
    let history = try HistoryStore(db: Database(path: ":memory:"))
    history.add(source: "hello", target: .zhHans, result: "你好", service: "智谱", limit: 0)
    history.setFavorite(source: "world", target: .zhHans, result: "世界", service: "智谱", true)
    func word(
      _ source: String, _ result: String, target: String = Lang.zhHans.rawValue, ago: TimeInterval
    ) -> SettingsArchive.Word {
      SettingsArchive.Word(
        source: source, target: target, result: result, service: "文件",
        createdAt: Date.now.addingTimeInterval(-ago))
    }
    let words = [
      word("hello", "文件里的译法", ago: 500), word("world", "文件里的译法", ago: 500),
      word("  serendipity \n", "意外之喜", ago: 86_400), word("future", "未来", ago: -86_400),
      word("klingon", "？", target: "tlh", ago: 0), word("   ", "空的", ago: 0),
    ]
    #expect(history.adoptFavorites(words) == 2)
    let favorites = history.search("", favoritesOnly: true, limit: 0)
    #expect(Set(favorites.map(\.source)) == ["hello", "world", "serendipity", "future"])
    #expect(favorites.first { $0.source == "hello" }?.result == "你好")
    #expect(favorites.first { $0.source == "world" }?.result == "世界")
    #expect(favorites.allSatisfy { $0.createdAt <= .now })
    let old = try #require(favorites.first { $0.source == "serendipity" })
    #expect(abs(old.createdAt.timeIntervalSinceNow + 86_400) < 5 && old.service == "文件")
    #expect(history.adoptFavorites(words) == 0)
    #expect(history.counts.total == 4 && history.counts.favorites == 4)
    // 去掉首尾空白后是同一个词的两条：只记一条
    #expect(
      history.adoptFavorites([word("twice", "一", ago: 0), word(" twice ", "二", ago: 0)]) == 1)
    #expect(history.search("twice", limit: 0).map(\.result) == ["一"])
  }

  /// 文件里的片段 / 收藏 / 生词也按不可信输入查：没有正文、不是留下的、目标语言不认识的不要；
  /// 收藏夹的名字不合规的只是不归进去；条数有上限；没带片段与收藏就没有收藏夹
  @Test func dropsInvalidClipsAndWords() throws {
    func clipJSON(
      _ text: String, favorite: Bool = true, snippet: Bool = false, note: String? = nil,
      group: String? = nil
    ) -> String {
      let extras = [note.map { #", "note": "\#($0)""# }, group.map { #", "group": "\#($0)""# }]
        .compactMap { $0 }.joined()
      return #"{"text": "\#(text)", "favorite": \#(favorite), "snippet": \#(snippet), "#
        + #""copiedAt": "2026-10-01T00:00:00Z"\#(extras)}"#
    }
    func wordJSON(_ source: String, _ result: String, _ target: String) -> String {
      #"{"source": "\#(source)", "target": "\#(target)", "result": "\#(result)", "#
        + #""service": "s", "createdAt": "2026-10-01T00:00:00Z"}"#
    }
    let clips = [
      clipJSON("好的"), clipJSON(""), clipJSON("不是留下的", favorite: false),
      clipJSON("备注两千字", note: String(repeating: "注", count: 2001)),
      clipJSON("收藏夹名字太长", group: String(repeating: "名", count: ClipGroup.maxName + 1)),
      clipJSON("名字带空白", snippet: true, note: "", group: "  工作 "),
    ]
    let (chinese, english) = (Lang.zhHans.rawValue, Lang.en.rawValue)
    let words = [
      wordJSON("ok", "好", chinese), wordJSON("bad", "坏", "tlh"), wordJSON(" ", "空", english),
      wordJSON("empty", "", english),
    ]
    let archive = try archive(
      json: file(
        #""clips": [\#(clips.joined(separator: ","))], "#
          + #""clipGroups": [" 工作 ", "工作", "", "\#(String(repeating: "长", count: 25))", "个人"], "#
          + #""vocabulary": [\#(words.joined(separator: ","))]"#))
    #expect(archive.clips?.map(\.text) == ["好的", "备注两千字", "收藏夹名字太长", "名字带空白"])
    #expect(archive.clips?.map(\.group) == [nil, nil, nil, "工作"])
    #expect(archive.clips?[1].note?.count == 2001)
    #expect(archive.clips?.last?.note == nil)
    #expect(archive.clipGroups == ["工作", "个人"])
    #expect(archive.vocabulary?.map(\.source) == ["ok"])
    #expect(archive.sections == [.clips, .vocabulary])

    let many = (0...SettingsArchive.maxClips).map { clipJSON("第 \($0) 条") }
    #expect(
      try self.archive(json: file(#""clips": [\#(many.joined(separator: ","))]"#)).clips?.count
        == SettingsArchive.maxClips)
    // 只有收藏夹、没有片段与收藏这一类：收藏夹不要
    #expect(try self.archive(json: file(#""clipGroups": ["工作"]"#)).clipGroups == nil)

    // 收藏夹总数封顶，条目带出来的名字也算：先到的占名额，后面的条目照收、只是不归收藏夹
    let limit = SettingsArchive.maxGroups
    let grouped = (0..<(limit + 50)).map { clipJSON("条目 \($0)", group: "夹 \($0)") }
    let capped = try self.archive(
      json: file(
        #""clipGroups": ["列表里的"], "clips": [\#(grouped.joined(separator: ","))]"#))
    #expect(capped.clips?.count == limit + 50)
    #expect(Set((capped.clips ?? []).compactMap(\.group)).count == limit - 1)
    #expect(capped.clips?.last?.group == nil && capped.clipGroups == ["列表里的"])
    let (store, _) = try clipboard()
    store.adopt(capped.clips ?? [], groups: capped.clipGroups ?? [])
    #expect(store.groups.count == limit && store.items.count == limit + 50)

    // 备注长得离谱：条目留着，只是不带备注
    let noted = try self.archive(
      json: file(
        #""clips": [\#(clipJSON("备注很长", note: String(repeating: "注", count: 10_001)))]"#))
    #expect(noted.clips?.map(\.text) == ["备注很长"] && noted.clips?.first?.note == nil)
    // 超过剪贴板单条上限的正文不要；生词条数封顶
    let huge = String(repeating: "x", count: ClipboardWatcher.maxTextBytes + 1)
    #expect(try self.archive(json: file(#""clips": [\#(clipJSON(huge))]"#)).clips == [])
    let manyWords = (0...SettingsArchive.maxWords).map { wordJSON("w\($0)", "译", chinese) }
    #expect(
      try self.archive(json: file(#""vocabulary": [\#(manyWords.joined(separator: ","))]"#))
        .vocabulary?.count == SettingsArchive.maxWords)
  }

  /// 导出前拦住导入时不肯全收的：条数、收藏夹数、生词数、文件大小；正常的不拦
  @Test func exportRefusesWhatImportWouldDrop() {
    func clip(_ index: Int) -> SettingsArchive.Clip {
      SettingsArchive.Clip(text: "第 \(index) 条", favorite: true, snippet: false, copiedAt: .now)
    }
    var archive = SettingsArchive(version: "1", exportedAt: Self.moment)
    #expect(archive.exportProblem(encodedSize: 100) == nil)
    #expect(archive.exportProblem(encodedSize: SettingsArchive.maxFileSize) == nil)
    #expect(archive.exportProblem(encodedSize: SettingsArchive.maxFileSize + 1) != nil)
    archive.clips = (0..<SettingsArchive.maxClips).map(clip)
    #expect(archive.exportProblem(encodedSize: 100) == nil)
    archive.clips?.append(clip(-1))
    #expect(archive.exportProblem(encodedSize: 100)?.contains("片段") == true)
    archive.clips = []
    archive.clipGroups = (0...SettingsArchive.maxGroups).map { "夹 \($0)" }
    #expect(archive.exportProblem(encodedSize: 100)?.contains("收藏夹") == true)
    archive.clipGroups = nil
    archive.vocabulary = (0...SettingsArchive.maxWords).map {
      SettingsArchive.Word(
        source: "w\($0)", target: Lang.en.rawValue, result: "译", service: "", createdAt: .now)
    }
    #expect(archive.exportProblem(encodedSize: 100)?.contains("生词本") == true)
  }

  /// 导入的整条路带上片段、收藏、生词本：勾了的并进各自的库并报数，没勾的不动
  @Test func installMergesClipsAndVocabulary() throws {
    let (source, _) = try clipboard()
    source.record(clip("签名：{date}", snippet: true))
    let words = try HistoryStore(db: Database(path: ":memory:"))
    words.setFavorite(source: "ephemeral", target: .zhHans, result: "短暂的", service: "智谱", true)
    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    let archive = try SettingsArchive.read(
      SettingsArchive.capture(
        from: target, domainName: name, services: [], clips: source.items,
        groups: source.groups, words: words.search("", limit: 0), now: Self.moment
      ).keeping([.clips, .vocabulary]).encoded())
    #expect(archive.sections == [.clips, .vocabulary])
    let services = TranslateServiceStore(services: [])
    let (store, _) = try clipboard()
    let history = try HistoryStore(db: Database(path: ":memory:"))
    // 没勾的不动
    #expect(
      try archive.install(
        [.vocabulary], services: services, clipboard: store, history: history, to: target,
        domainName: name) == SettingsArchive.Outcome(wordsAdded: 1))
    #expect(store.items.isEmpty)
    #expect(
      try archive.install(
        [.clips, .vocabulary], services: services, clipboard: store, history: history,
        to: target, domainName: name) == SettingsArchive.Outcome(clipsAdded: 1))
    #expect(store.items.map(\.text) == ["签名：{date}"])
    #expect(store.items.first?.isSnippet == true)
    // 偏好没被碰过（这两类不写偏好）
    #expect(target.persistentDomain(forName: name)?.isEmpty != false)
  }

  /// 刘海岛上那一行：类别少就列名字、多就说几类；带密钥说一声；有清理说清理，没有才说新增
  @Test func importSummaryStaysShort() {
    typealias Outcome = SettingsArchive.Outcome
    #expect(ImportSheet.summary([.hotkeys], outcome: Outcome(), pruned: 0) == "快捷键")
    #expect(
      ImportSheet.summary([.hotkeys, .services], outcome: Outcome(secrets: 2), pruned: 0)
        == "快捷键、翻译服务，含密钥")
    #expect(
      ImportSheet.summary(
        SettingsArchive.Section.allCases,
        outcome: Outcome(secrets: 1, clipsAdded: 12, clipsUpdated: 3, wordsAdded: 30), pruned: 0)
        == "6 类，含密钥，新增 42 条")
    #expect(
      ImportSheet.summary(
        [.preferences, .clips, .vocabulary], outcome: Outcome(clipsAdded: 1), pruned: 5)
        == "设置、片段与收藏、生词本，清理了 5 条历史")
    #expect(
      ImportSheet.summary(
        [.preferences, .clips, .vocabulary], outcome: Outcome(clipsAdded: 1), pruned: 50)
        == "3 类，清理了 50 条历史")
    #expect(
      ImportSheet.summary([.preferences, .hotkeys], outcome: Outcome(), pruned: 5)
        == "设置、快捷键，清理了 5 条历史")
    #expect(
      ImportSheet.summary([.clips, .vocabulary], outcome: Outcome(clipsUpdated: 4), pruned: 0)
        == "片段与收藏、生词本")
    // 六类的每一种勾法、各种数：都不超过岛上放得下的 22 个字
    let all = SettingsArchive.Section.allCases
    for mask in 1..<(1 << all.count) {
      let sections = all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
      for (outcome, pruned) in [
        (Outcome(), 0), (Outcome(secrets: 9), 0), (Outcome(secrets: 9), 99_999),
        (Outcome(secrets: 9, clipsAdded: 5000, wordsAdded: 20_000), 0),
        (Outcome(clipsAdded: 5000, wordsAdded: 20_000), 0), (Outcome(), 99_999),
      ] {
        let summary = ImportSheet.summary(sections, outcome: outcome, pruned: pruned)
        #expect(summary.count <= 22, "\(summary)")
      }
    }
  }

  // MARK: 导入前的提醒

  /// 导入后历史保留得比现在少（保留天数、图片上限、翻译历史条数变小，新打开退出 / 锁屏清空）才提醒；
  /// 文件里没有的键按默认值算；0 = 永久 / 不限
  @Test func warnsWhenHistoryWouldShrink() throws {
    let (target, name) = try suite()
    defer { target.removePersistentDomain(forName: name) }
    func current(days: Int, megabytes: Int = 512, limit: Int = 5000) {
      target.set(days, forKey: Prefs.clipboardRetentionDays)
      target.set(megabytes, forKey: Prefs.clipboardImageBudgetMB)
      target.set(limit, forKey: Prefs.translateHistoryLimit)
      target.set(false, forKey: Prefs.clipboardClearOnQuit)
      target.set(false, forKey: Prefs.clipboardClearOnLock)
    }
    func incoming(_ preferences: String) throws -> SettingsArchive {
      try archive(json: file(#""preferences": {\#(preferences)}"#))
    }
    // 文件里什么都没改 = 都回到默认（7 天、512 MB、5000 条）
    current(days: 7)
    #expect(try !incoming("").keepsLessHistory(than: target))
    current(days: 0)
    #expect(try incoming("").keepsLessHistory(than: target))
    current(days: 30)
    #expect(try incoming("").keepsLessHistory(than: target))
    #expect(try !incoming(#""clipboardHistoryRetentionDays": 0"#).keepsLessHistory(than: target))
    #expect(try !incoming(#""clipboardHistoryRetentionDays": 90"#).keepsLessHistory(than: target))
    current(days: 7, megabytes: 0)
    #expect(try incoming("").keepsLessHistory(than: target))
    #expect(try !incoming(#""clipboardImageCacheMaxMb": 0"#).keepsLessHistory(than: target))
    current(days: 7, limit: 0)
    #expect(try incoming(#""translateHistoryLimit": 1000"#).keepsLessHistory(than: target))
    current(days: 7)
    #expect(try incoming(#""clipboardClearOnLock": true"#).keepsLessHistory(than: target))
    target.set(true, forKey: Prefs.clipboardClearOnLock)
    #expect(try !incoming(#""clipboardClearOnLock": true"#).keepsLessHistory(than: target))
    // 不带「设置」这一类的文件不提醒
    current(days: 0)
    #expect(try !archive(json: file(#""hotkeys": {}"#)).keepsLessHistory(than: target))
  }
}
