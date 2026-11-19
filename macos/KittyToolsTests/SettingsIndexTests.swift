// 设置项登记表（设置改版 S7 S8，Settings/SettingsIndex.swift）的单测：每一项都挂在页面上、只挂一次（读源码），
// 偏好键都是注册了默认值的，每页都有登记，搜索的排序和条数上限，选了一项之后导航落到哪。

import Foundation
import Testing

@testable import KittyTools

struct SettingsIndexTests {
  private static let settings = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "KittyTools/Settings")

  /// 源码里挂了哪些锚（`.settingsAnchor(.x)` 的 x），一项一次
  private static func anchors() throws -> [String] {
    let files = try FileManager.default.contentsOfDirectory(
      at: settings, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsIndex.swift" }
    return try files.flatMap { file in
      try String(contentsOf: file, encoding: .utf8).matches(of: /\.settingsAnchor\(\.(\w+)\)/)
        .map { String($0.output.1) }
    }
  }

  /// 每一项都挂在了页面上、只挂了一次（挂两次：搜索滚过去时两处都描）；挂的都是登记过的
  @Test func everyItemIsAnchoredOnce() throws {
    let names = try Self.anchors()
    let cases = Set(SettingsItem.allCases.map { "\($0)" })
    #expect(
      Set(names) == cases, "没挂的：\(cases.subtracting(names))；没登记的：\(Set(names).subtracting(cases))")
    let twice = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
    #expect(twice.isEmpty, "挂了不止一次：\(twice.sorted())")
  }

  /// 登记的偏好键都注册了默认值（恢复默认靠它回到默认；不注册的是这台电脑自己的，不该登记进来）
  @Test func keysAreRegisteredDefaults() {
    let registered = Set(Prefs.defaults.keys)
    for item in SettingsItem.allCases {
      for key in item.info.keys {
        #expect(registered.contains(key), "\(item) 的 \(key) 没注册默认值")
      }
    }
  }

  /// 除了「全部插件」（那一页的行是插件，另有描边），每一页都至少登记了一行
  @Test func everyPageHasItems() {
    let pages = Set(SettingsItem.allCases.map(\.page))
    for page in SettingsPage.allCases where page != .plugins {
      #expect(pages.contains(page), "\(page) 一行都没登记")
    }
  }

  /// 搜索：标题打头的排最前，同一档按侧栏的页序；只靠搜索词也找得到；最多 12 条；侧栏里没有的页不列
  @Test func searchRanksAndLimits() {
    #expect(SettingsItem.matching("强调色", hidden: []).first == .generalAccent)
    #expect(SettingsItem.matching("透镜", hidden: []).first == .clipboardLens)
    #expect(SettingsItem.matching("晾衣绳", hidden: []).contains(.screenshotPlacement))
    // 两页都有「面板位置」：剪贴板在启动器前面（侧栏的页序）
    let position = SettingsItem.matching("面板位置", hidden: [])
    #expect(Array(position.prefix(2)) == [.clipboardPanelPosition, .launcherPanelPosition])
    // 标题打头的（「显示光标」）排在标题中间有的（「框选时显示操作提示」）前面
    let shows = SettingsItem.matching("显示", hidden: [])
    #expect(shows.count == SettingsItem.resultLimit)
    #expect(shows.firstIndex(of: .recordCursor)! < shows.firstIndex(of: .screenshotHint) ?? .max)
    #expect(SettingsItem.matching("刘海", hidden: [.island]).allSatisfy { $0.page != .island })
    #expect(SettingsItem.matching("  ", hidden: []).isEmpty)
  }

  /// 每一项的标题就是那一行（或那一节标题）的字面量：锚点前 25 行里能找到它。不查的：标题不是字面量的（语言那一行用显式
  /// key、打开全部便签那一行用动作名），和标题写在共用零件里的（权限行、面板大小那一行、另存一份到那一行）
  @Test func titlesMatchTheirRows() throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: Self.settings, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsIndex.swift" }
    var near: [String: String] = [:]
    for file in files {
      let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
      for (index, line) in lines.enumerated() {
        guard let match = line.firstMatch(of: /\.settingsAnchor\(\.(\w+)\)/) else { continue }
        near[String(match.output.1)] = lines[max(0, index - 25)...index].joined(separator: "\n")
      }
    }
    let skipped: Set<SettingsItem> = [
      .generalLanguage, .notesOpenAll, .generalAccessibility, .generalScreenRecording,
      .generalMirror, .clipboardPanelSize, .launcherPanelSize, .translatePanelSize,
      // 推进行的标题是子页名（SettingsSubpage.title）
      .launcherScripts,
    ]
    for item in SettingsItem.allCases where !skipped.contains(item) {
      let title = "\"" + item.info.title.key + "\""
      #expect(near["\(item)"]?.contains(title) == true, "\(item) 的标题 \(title) 不在锚点前面")
    }
  }

  /// 侧栏列的页包括搜到的每一行所在的页（不止「设置项」里列出来的 12 条）：选了哪一行都不会把搜索词清掉
  @Test func sidebarListsEveryResultPage() {
    for query in ["显示", "提示", "历史", "刘海", "颜色", "快捷键"] {
      let listed = Set(SettingsPage.listed(query, hidden: []))
      for item in SettingsItem.matching(query, hidden: [], limit: .max) {
        #expect(listed.contains(item.page), "搜「\(query)」时 \(item) 的页不在侧栏里")
      }
    }
  }

  /// 跟着开关才露出来的行，开关关着时落到那个开关上
  @Test func hiddenRowsLandOnTheirSwitch() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: Prefs.shotHistory)
    defaults.set(false, forKey: Prefs.settingsBackupEnabled)
    #expect(SettingsItem.screenshotHistoryDays.landing(defaults) == .screenshotHistory)
    #expect(SettingsItem.generalMirror.landing(defaults) == .generalBackup)
    #expect(SettingsItem.generalSyncPeers.landing(defaults) == .generalSync)
    defaults.set(true, forKey: Prefs.shotHistory)
    defaults.set(true, forKey: Prefs.settingsBackupEnabled)
    #expect(SettingsItem.screenshotHistorySize.landing(defaults) == .screenshotHistorySize)
    #expect(SettingsItem.generalMirror.landing(defaults) == .generalMirror)
    #expect(SettingsItem.clipboardLens.landing(defaults) == .clipboardLens)
  }

  /// 选了一项：换到那一页、退回推进的详情页、描那一行
  @MainActor @Test func openLandsOnTheRow() {
    let navigation = SettingsNavigation(defaults: nil)
    navigation.page = .translate
    navigation.path = ["google"]
    navigation.open(.clipboardLens)
    #expect(navigation.page == .clipboard)
    #expect(navigation.path.isEmpty)
    #expect(navigation.highlighted == .clipboardLens)
    // 两秒内再选同一项：次数往上走，表单再滚一次
    let round = navigation.highlightRound
    navigation.open(.clipboardLens)
    #expect(navigation.highlightRound == round + 1)
  }
}

/// 第 2 批：子页、「高级…」、恢复默认、合起来的两个选单、推进行行尾
struct SettingsPlacesTests {
  /// 选了子页里、「高级…」里的一项：推进那个子页 / 打开那页的表单
  @MainActor @Test func openGoesIntoSubpagesAndAdvanced() {
    let navigation = SettingsNavigation(defaults: nil)
    navigation.open(.screenshotHistoryDays)
    #expect(navigation.page == .screenshot)
    #expect(navigation.path == [SettingsSubpage.screenshotHistory.route])
    #expect(navigation.advanced == nil)
    navigation.open(.clipboardLens)
    #expect(navigation.page == .clipboard)
    #expect(navigation.path.isEmpty)
    #expect(navigation.advanced == .clipboard)
    // 换页收起表单、退回子页
    navigation.page = .general
    #expect(navigation.advanced == nil)
  }

  /// 每个子页都有登记的行；子页的路由认得回来，不和服务 id 这类路由撞
  @Test func subpagesHaveRowsAndRoutes() {
    for subpage in SettingsSubpage.allCases {
      #expect(SettingsItem.allCases.contains { $0.place == .subpage(subpage) }, "\(subpage) 没有行")
      #expect(SettingsSubpage(route: subpage.route) == subpage)
    }
    #expect(SettingsSubpage(route: "google") == nil)
  }

  /// 恢复默认不碰功能开关、上限和没注册默认值的键
  @Test func resetKeysSkipLimitsAndFeatures() {
    let keys = Set(SettingsReset.keys(of: SettingsItem.allCases))
    #expect(keys.isDisjoint(with: SettingsReset.limits))
    #expect(keys.isDisjoint(with: Feature.allCases.map(\.prefsKey)))
    #expect(keys.isSubset(of: Prefs.defaults.keys))
  }

  /// 只删改过的；撤销原样写回
  @Test func resetRemovesOnlyChangedAndRestores() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: Prefs.screenshotCursor)
    defaults.set("center", forKey: Prefs.screenshotToolbarAlign)
    defaults.set(9, forKey: Prefs.shotHistoryDays)  // 不在这次的键里：不动
    let keys = [Prefs.screenshotCursor, Prefs.screenshotToolbarAlign, Prefs.screenshotLoupe]
    let before = SettingsReset.reset(keys, in: defaults, domain: suite)
    #expect(Set(before.keys) == [Prefs.screenshotCursor, Prefs.screenshotToolbarAlign])
    let stored = defaults.persistentDomain(forName: suite) ?? [:]
    #expect(stored.keys.sorted() == [Prefs.shotHistoryDays])
    #expect(!SettingsReset.differs(keys, in: defaults))
    SettingsReset.restore(before, in: defaults)
    #expect(SettingsReset.differs(keys, in: defaults))
    #expect(defaults.bool(forKey: Prefs.screenshotCursor))
    #expect(defaults.string(forKey: Prefs.screenshotToolbarAlign) == "center")
    #expect(SettingsReset.changed(keys, in: defaults, domain: suite).count == 2)
    // 存着、但和默认值一样：按钮不亮
    defaults.set(Prefs.defaults[Prefs.screenshotLoupe], forKey: Prefs.screenshotLoupe)
    #expect(!SettingsReset.differs([Prefs.screenshotLoupe], in: defaults))
  }

  /// 「自动清空普通历史」：两个键的四种组合读得回来，换一项只写变了的键
  @Test func autoClearWritesOnlyChangedKeys() {
    typealias Choice = ClipboardTab.AutoClear
    for quit in [false, true] {
      for lock in [false, true] {
        let old = Choice(quit: quit, lock: lock)
        #expect(old.quit == quit && old.lock == lock)
        for new in Choice.allCases {
          let writes = new.writes(from: old)
          #expect(writes.count == [new.quit != quit, new.lock != lock].filter { $0 }.count)
          for write in writes {
            #expect(write.value == (write.key == Prefs.clipboardClearOnQuit ? new.quit : new.lock))
          }
        }
      }
    }
  }

  /// 「悬停时识别」：选「关」不动网页那个键；只写变了的
  @Test func elementDetectionWritesOnlyChangedKeys() {
    typealias Choice = ScreenshotTab.ElementDetection
    #expect(Choice(finds: false, web: true) == .off)
    #expect(Choice(finds: true, web: false) == .windows)
    #expect(Choice(finds: true, web: true) == .web)
    #expect(Choice.off.writes(finds: true, web: true).map(\.key) == [Prefs.screenshotFindsElements])
    #expect(Choice.web.writes(finds: true, web: true).isEmpty)
    let fromOff = Choice.web.writes(finds: false, web: false)
    #expect(
      fromOff.map(\.key) == [Prefs.screenshotFindsElements, Prefs.screenshotFindsWebElements])
    #expect(fromOff.allSatisfy { $0.value })
    #expect(
      Choice.windows.writes(finds: false, web: false).map(\.key) == [Prefs.screenshotFindsElements])
  }

  /// 推进行行尾那一句
  @Test func pushRowValues() {
    func text(_ value: LocalizedStringResource) -> String { String(localized: value) }
    #expect(text(GeneralTab.permissionsValue(missing: 0)) == "都已允许")
    #expect(text(GeneralTab.permissionsValue(missing: 2)) == "缺 2 项")
    #expect(
      GeneralTab.missingPermissions(
        needs: [.accessibility, .screenRecording], granted: { $0 == .accessibility },
        clipboardBlocked: true) == 2)
    #expect(text(GeneralTab.syncValue(status: .off, lastSync: nil).text) == "关")
    #expect(GeneralTab.syncValue(status: .stopped(.missingFolder), lastSync: nil).isProblem)
    #expect(text(GeneralTab.syncValue(status: .idle, lastSync: nil).text) == "开着")
    #expect(GeneralTab.backupValue(isOn: true, failed: true, latest: nil).isProblem)
    #expect(text(GeneralTab.backupValue(isOn: false, failed: true, latest: nil).text) == "自动备份关着")
    #expect(text(GeneralTab.backupValue(isOn: true, failed: false, latest: nil).text) == "还没有备份")
    let now = Date.now
    #expect(
      text(GeneralTab.backupValue(isOn: true, failed: false, latest: now).text)
        == SettingsBackup.when(now))
    #expect(text(ScreenshotTab.historyValue(keeps: false, days: 30, megabytes: 2048)) == "关")
    #expect(
      text(ScreenshotTab.historyValue(keeps: true, days: 30, megabytes: 2048))
        == "30 天 · 2 GB")
  }
}

/// 第 3 批：翻译、启动器、便签、刘海岛的子页
struct SettingsPagesTests {
  private func text(_ value: LocalizedStringResource) -> String { String(localized: value) }

  /// 「英文单词发音」：两个键的四种组合读得回来，换一项只写变了的键
  @Test func wordVoiceWritesOnlyChangedKeys() {
    typealias Choice = TranslateTab.WordVoice
    for recording in [false, true] {
      for accent in ["us", "uk"] {
        let old = Choice(recording: recording, accent: accent)
        #expect(old.recording == recording && old.accent == accent)
        for new in Choice.allCases {
          let writes = new.writes(from: old)
          #expect(writes.recording == (new.recording == recording ? nil : new.recording))
          #expect(writes.accent == (new.accent == accent ? nil : new.accent))
        }
      }
    }
    // 导入、同步来的怪值当美音
    #expect(Choice(recording: true, accent: "xx") == .humanUS)
  }

  /// 搜子页的名字，落到那个子页的第一行
  @Test func subpageTitlesAreSearchable() {
    for subpage in SettingsSubpage.allCases {
      let first = SettingsItem.allCases.first { $0.place == .subpage(subpage) }
      let hits = SettingsItem.matching(String(localized: subpage.title), hidden: [], limit: .max)
      #expect(
        first.map(hits.contains) == true, "搜「\(String(localized: subpage.title))」找不到 \(subpage)")
    }
  }

  /// 推进行行尾那一句
  @Test func pushRowValues() {
    #expect(text(TranslateTab.lookupValue(dictionary: true, voice: .humanUK)) == "词典 · 真人英音")
    #expect(text(TranslateTab.lookupValue(dictionary: false, voice: .systemUS)) == "系统美音")
    #expect(text(TranslateTab.historyValue(enabled: false, limit: 5000)) == "关")
    #expect(text(TranslateTab.historyValue(enabled: true, limit: 0)) == "不限")
    // 数字按界面语言排（5,000）
    #expect(
      text(TranslateTab.historyValue(enabled: true, limit: 5000))
        == String(localized: "最多 \(5000) 条"))
    #expect(text(LauncherTab.scriptsValue(on: false, scripts: 3, problems: 1).text) == "关")
    #expect(LauncherTab.scriptsValue(on: true, scripts: 3, problems: 1).isProblem)
    #expect(text(LauncherTab.scriptsValue(on: true, scripts: 3, problems: 0).text) == "3 个脚本")
    #expect(text(NotesTab.deckValue(enabled: true, edge: .left)) == "开着 · 左边")
    #expect(text(NotesTab.deckValue(enabled: false, edge: .left)) == "关")
    #expect(
      text(IslandCalendarPage.value(nextEvent: true, calendar: false, hourly: true)) == "开着 2 样")
    #expect(text(IslandNoticesPage.value([false, false])) == "关")
    #expect(IslandLevelsPage.value(on: true, catches: false).isProblem)
    #expect(text(IslandLevelsPage.value(on: false, catches: false).text) == "关")
  }
}
