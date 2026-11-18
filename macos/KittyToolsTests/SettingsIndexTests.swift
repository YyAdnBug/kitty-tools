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
