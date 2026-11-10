// 应用别名：解析、稳定身份、原名保留、精确命中优先、偏好变更失效及导出往返。
// 只用假 App、内存库和临时偏好域，不扫应用目录、不打开应用、不写真实偏好。

import Foundation
import Testing

@testable import KittyTools

struct AppAliasTests {
  private func app(_ title: String, bundleID: String? = nil) -> LauncherItem {
    LauncherItem(
      kind: .app, target: "/Applications/\(title).app", title: title, subtitle: "",
      names: [LauncherMatch.fold(title)], appBundleID: bundleID)
  }

  @Test func separatesAndFoldsWithoutSplittingPhrases() {
    #expect(
      AppAliases.parse(" WX，聊天; wx； Work Chat\n\nＣＡＦÉ\r\n café ") == [
        "wx", "聊天", "work chat", "cafe",
      ])
    #expect(AppAliases.parse(" ,，；; \n ").isEmpty)
  }

  @Test func originalNamesAndIdentitySurviveAliases() throws {
    let item = app("WeChat", bundleID: "com.tencent.xinWeChat")
    let raw = " WX, 聊天, Work Chat "
    let text = try #require(AppAliases().setting(raw, for: item))
    let aliases = AppAliases(text: text)
    let indexed = aliases.applying(to: item)
    #expect(aliases.text(for: item) == raw)
    #expect(indexed.title == item.title && indexed.target == item.target && indexed.id == item.id)
    #expect(indexed.subtitle == item.subtitle)
    for query in ["wechat", "wx", "w", "聊天", "liaotian", "lt", "work chat"] {
      #expect(LauncherMatch.score(query, item: indexed) > 0, "\(query)")
    }
    #expect(aliases.exactlyMatches(indexed, query: "  ＷＸ  "))
    #expect(!aliases.exactlyMatches(indexed, query: "w"))
    #expect(!aliases.exactlyMatches(indexed, query: " "))
    #expect(aliases.applying(to: indexed) == indexed)
  }

  @Test func aliasesFollowBundleIDAndKeepAbsentApps() throws {
    let old = app("Old Name", bundleID: "example.chat")
    let renamed = app("New Name", bundleID: "example.chat")
    let absent = app("Absent", bundleID: "example.absent")
    var text = try #require(AppAliases().setting("chat", for: old))
    text = try #require(AppAliases(text: text).setting("later", for: absent))
    let aliases = AppAliases(text: text)
    #expect(aliases.text(for: renamed) == "chat")
    #expect(aliases.text(for: app("Old Name", bundleID: "example.other")).isEmpty)
    text = try #require(aliases.setting("talk", for: renamed))
    #expect(AppAliases(text: text).text(for: absent) == "later")
    text = try #require(AppAliases(text: text).setting("", for: renamed))
    #expect(AppAliases(text: text).text(for: old).isEmpty)
    #expect(AppAliases(text: text).text(for: absent) == "later")
    #expect(AppAliases(text: text).count == 1)
    text = try #require(AppAliases(text: text).setting("", for: absent))
    #expect(text.isEmpty)
  }

  @Test func missingBundleIDUsesPathAndNonAppsAreIgnored() throws {
    let item = app("Local")
    let text = try #require(AppAliases().setting("localtool", for: item))
    let aliases = AppAliases(text: text)
    let samePath = LauncherItem(
      kind: .app, target: "/Applications/Utilities/../Local.app", title: "Local", subtitle: "")
    #expect(aliases.text(for: samePath) == "localtool")
    #expect(aliases.text(for: app("Other")).isEmpty)
    let pane = LauncherItem(kind: .url, target: item.target, title: "设置", subtitle: "")
    #expect(aliases.applying(to: pane) == pane)
    #expect(!aliases.exactlyMatches(pane, query: "localtool"))
    #expect(aliases.setting("setting", for: pane) == nil)
  }

  @Test func malformedAndOversizedSettingsAreBounded() throws {
    for text in ["", "[]", "{", #"{"app":1}"#, String(repeating: " ", count: 65_537)] {
      #expect(AppAliases(text: text).values.isEmpty)
    }
    let item = app("Example", bundleID: "example.app")
    let limit = String(repeating: "x", count: AppAliases.entryLimit)
    #expect(AppAliases().setting(limit, for: item) != nil)
    #expect(AppAliases().setting(limit + "x", for: item) == nil)
    let data = try JSONEncoder().encode([
      AppAliases.key(for: item): limit + "x", "bundle:good": "good",
    ])
    let aliases = AppAliases(text: try #require(String(data: data, encoding: .utf8)))
    #expect(aliases.text(for: item).isEmpty)
    #expect(aliases.values["bundle:good"] == "good")
  }

  @Test func catalogReadsStableIdentifierFromAppBundle() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let bundle = root.appending(path: "Example.app")
    let contents = bundle.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "example.stable", "CFBundlePackageType": "APPL"],
      format: .xml, options: 0)
    try info.write(to: contents.appending(path: "Info.plist"))
    let item = AppCatalog.item(path: bundle.path)
    #expect(item.appBundleID == "example.stable")
    #expect(AppAliases.key(for: item) == "bundle:example.stable")
    #expect(item.target == bundle.path)
  }

  @Test func exactAliasOutranksFrequentAppAndKeepsOneResult() throws {
    let target = app("WeChat", bundleID: "example.chat")
    let frequent = app("WX Helper")
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    for _ in 0..<20 { usage.record(frequent, query: "wx") }
    let model = LauncherModel(usage: usage, apps: [frequent, target])
    let text = try #require(AppAliases().setting("wx, 聊天", for: target))
    model.appAliasesText = { text }
    model.query = "wx"
    #expect(model.results.first?.id == target.id)
    #expect(model.results.filter { $0.id == target.id }.count == 1)
    #expect(model.results.contains { $0.id == frequent.id })
    // 原名仍然能找到同一个结果，使用记录 / 收藏没有换身份。
    model.query = "wechat"
    #expect(model.results.first?.id == target.id)
  }

  @Test func editsAndRemovalInvalidateSearchCache() throws {
    let target = app("WeChat", bundleID: "example.chat")
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [target])
    var text = try #require(AppAliases().setting("wx", for: target))
    model.appAliasesText = { text }
    model.query = "wx"
    #expect(model.results.contains { $0.id == target.id })
    text = try #require(AppAliases(text: text).setting("talk", for: target))
    model.query = "talk"
    #expect(model.results.first?.id == target.id)
    model.query = "wx"
    #expect(!model.results.contains { $0.id == target.id })
    text = ""
    model.query = "talk"
    #expect(!model.results.contains { $0.id == target.id })
    model.query = "wechat"
    #expect(model.results.first?.id == target.id)
  }

  @Test func duplicateAliasesKeepBothAppsWithUsageOrdering() throws {
    let first = app("First", bundleID: "example.first")
    let second = app("Second", bundleID: "example.second")
    var text = try #require(AppAliases().setting("chat", for: first))
    text = try #require(AppAliases(text: text).setting("chat", for: second))
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    usage.record(second, query: "chat")
    let model = LauncherModel(usage: usage, apps: [first, second])
    model.appAliasesText = { text }
    model.query = "chat"
    #expect(Array(model.results.prefix(2).map(\.id)) == [second.id, first.id])
  }

  @Test func fullAliasWinsOverKeywordPromptButArgumentsKeepTheirMode() throws {
    let target = app("Chat", bundleID: "example.chat")
    let text = try #require(AppAliases().setting("fy, find my", for: target))
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [target])
    model.appAliasesText = { text }
    model.query = "fy"
    #expect(model.results.first?.id == target.id)
    model.query = "fy hello"
    #expect(model.results.first?.kind == .translate)
    model.query = "find my"
    let request = try #require(model.fileRequest)
    model.showFiles([], for: request)
    #expect(model.results.first?.id == target.id)
  }

  @Test func preferencesExportAndImportLongAliasLists() throws {
    let suite = "kitty-test-app-aliases-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.register(defaults: Prefs.defaults)
    var text = ""
    for index in 0..<120 {
      text = try #require(
        AppAliases(text: text).setting(
          "chat\(index), 聊天\(index)", for: app("Chat\(index)", bundleID: "example.chat\(index)")))
    }
    #expect(text.count > 4096)
    #expect(SettingsArchive.kinds[Prefs.launcherAppAliases] == .text)
    defaults.set(text, forKey: Prefs.launcherAppAliases)
    let archive = SettingsArchive.capture(
      from: defaults, domainName: suite, services: [], notes: [])
    let imported = try SettingsArchive.read(archive.encoded())
    #expect(imported.preferences[Prefs.launcherAppAliases] == .string(text))
    let value = try #require(imported.preferences[Prefs.launcherAppAliases])
    let restored = try #require(SettingsArchive.Kind.text.plist(value) as? String)
    #expect(AppAliases(text: restored).count == 120)
    let sync = SettingsSync(defaults: defaults, domainName: suite)
    let synced = try #require(sync.syncValues()["pref:" + Prefs.launcherAppAliases])
    #expect(
      try JSONDecoder().decode(SettingsArchive.Value.self, from: Data(synced.utf8)) == .string(text)
    )
  }
}
