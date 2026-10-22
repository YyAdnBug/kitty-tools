// 功能开关（Shell/Feature.swift，2026-10-21）：每个快捷键动作归一个功能、关掉的功能在分节 / 启动器内置动作 / 速查表里
// 都不出现（纯函数喂集合，不读也不写用户的偏好）、只剩一个功能的合并节改名、启动台原来的总开关迁过来。

import Foundation
import Testing

@testable import KittyTools

@MainActor
struct FeatureTests {
  private let all = Set(Feature.allCases)

  /// 每个动作恰好归一个功能，就是它所在那一节里的；每个功能至少一个动作；和设置页同名
  @Test func everyActionBelongsToOneFeature() {
    for feature in Feature.allCases {
      #expect(HotKeyAction.allCases.contains { $0.feature == feature })
      #expect(feature.page.rawValue == feature.rawValue)
    }
    #expect(HotKeyAction.screenshotTranslate.feature == .translate)
    #expect(HotKeyAction.pinClipboard.feature == .screenshot)
    #expect(HotKeyAction.audioRecord.feature == .record)
    // 菜单栏的非热键项跟着它那一节的动作走
    #expect(MenuExtra.pauseClipboard.section?.feature == .clipboard)
    #expect(MenuExtra.copyToTranslate.section?.feature == .translate)
    #expect(MenuExtra.pinsClose.section?.feature == .screenshot)
    #expect(MenuExtra.quit.section == nil)
  }

  /// 关掉的功能的动作不列、空了的节不列；两个功能合一节的只剩一个时节标题换成它的名字
  @Test func sectionsFollowFeatures() {
    let full = HotKeyAction.visibleSections(enabled: all)
    #expect(Set(full.flatMap(\.actions)) == Set(HotKeyAction.allCases))
    #expect(full.first?.title == "剪贴板与启动器")
    #expect(HotKeyAction.visibleSections(enabled: []).isEmpty)

    let noClipboard = HotKeyAction.visibleSections(enabled: all.subtracting([.clipboard]))
    #expect(noClipboard.first?.title == "启动器")
    #expect(noClipboard.first?.actions == [.launcher])

    let noRecord = HotKeyAction.visibleSections(enabled: all.subtracting([.record]))
    let shots = noRecord.first { $0.actions.contains(.screenshot) }
    #expect(shots?.title == "截图")
    #expect(shots?.actions.contains(.screenRecord) == false)

    let noShots = HotKeyAction.visibleSections(enabled: all.subtracting([.screenshot]))
    let records = noShots.first { $0.actions.contains(.screenRecord) }
    #expect(records?.title == "录制")
    #expect(records?.actions == [.screenRecord, .audioRecord])

    // 一个功能一节的（翻译）关掉就整节没有
    let noTranslate = HotKeyAction.visibleSections(enabled: all.subtracting([.translate]))
    #expect(!noTranslate.contains { $0.title == "翻译" })
    #expect(noTranslate.count == full.count - 1)
  }

  /// 启动器的内置动作（和菜单栏同一份）：关掉的功能的动作、它那一节的菜单栏项、状态屏的各个状态都不列；
  /// 同样的其它状态换了开着的功能不吃旧缓存
  @Test func launcherActionsFollowFeatures() {
    var state = LauncherItem.ActionState(statusPresets: StatusPreset.builtIn)
    state.features = all
    let full = Set(LauncherItem.actions(state).map(\.target))
    #expect(full.contains(LauncherItem.actionID(.selectionTranslate)))
    #expect(full.contains(MenuExtra.copyToTranslate.rawValue))
    #expect(full.contains { $0.hasPrefix(LauncherItem.statusPresetPrefix) })

    let off: Set<Feature> = [.translate, .statusScreen, .clipboard]
    state.features = all.subtracting(off)
    let reduced = Set(LauncherItem.actions(state).map(\.target))
    for action in HotKeyAction.allCases where off.contains(action.feature) {
      #expect(!reduced.contains(LauncherItem.actionID(action)))
    }
    #expect(!reduced.contains(MenuExtra.copyToTranslate.rawValue))
    #expect(!reduced.contains(MenuExtra.pauseClipboard.rawValue))
    #expect(!reduced.contains { $0.hasPrefix(LauncherItem.statusPresetPrefix) })
    // 不归功能的几项照旧在
    #expect(reduced.contains(MenuExtra.settings.rawValue))
    #expect(reduced.contains(MenuExtra.quit.rawValue))
    #expect(reduced.contains(LauncherItem.actionID(.screenshot)))
  }

  /// 启动器里归关着的功能的内置动作收藏：只藏不删（空搜索框每次都会清还原不出来的收藏），打开功能就回到原位
  @Test func hiddenFavoritesSurvive() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let model = LauncherModel(usage: usage, apps: [])
    var state = LauncherItem.ActionState()
    state.features = all
    model.actionState = { state }
    let shot = try #require(
      LauncherItem.actions(state).first { $0.target == LauncherItem.actionID(.screenshot) })
    usage.toggleFavorite(shot)
    model.query = ""
    #expect(model.results.first?.target == shot.target)
    state.features = all.subtracting([.screenshot])
    model.query = "x"
    model.query = ""
    #expect(!model.results.contains { $0.target == shot.target })
    #expect(usage.favorites.map(\.target) == [shot.target])
    state.features = all
    model.query = "x"
    model.query = ""
    #expect(model.results.first?.target == shot.target)
  }

  /// 速查表：关掉的功能那几组不列；列出来的组里关着的功能的全局键、指向它的行也去掉
  @Test func cheatSheetFollowsFeatures() {
    let full = ShortcutsSheet.groups(enabled: all)
    let noTranslate = ShortcutsSheet.groups(enabled: all.subtracting([.translate]))
    #expect(!noTranslate.contains { $0.title.hasPrefix("翻译") })
    let clipboard = noTranslate.first { $0.title == "剪贴板" }
    #expect(clipboard?.entries.contains { $0.keys == ["⌘T"] } == false)
    #expect(full.first { $0.title == "剪贴板" }?.entries.contains { $0.keys == ["⌘T"] } == true)
    #expect(
      noTranslate.first { $0.title == "启动器" }?.entries.contains { $0.keys == ["fy"] } == false)

    // 框选也是截图翻译和录屏的第一步：截图关了、翻译开着时这一组还在，只是没有截图的全局键
    let noShots = ShortcutsSheet.groups(enabled: all.subtracting([.screenshot]))
    let selecting = noShots.first { $0.title == "截图 · 框选" }
    #expect(selecting?.globals.isEmpty == true)
    #expect(!noShots.contains { $0.title == "截图 · 标注" })
    #expect(!noShots.contains { $0.title == "钉图" })

    let noRecord = ShortcutsSheet.groups(enabled: all.subtracting([.record]))
    #expect(!noRecord.contains { $0.title == "录屏" })
    #expect(
      noRecord.first { $0.title == "截图 · 出图" }?.entries.contains { $0.keys == ["R"] } == false)

    // 都关掉只剩不归功能的「设置」一组
    #expect(ShortcutsSheet.groups(enabled: []).map(\.title) == ["设置"])
  }

  /// 启动台原来的总开关（launchpadEnabled，没发布过）挪进功能开关一次：只在新键没存过时搬，旧键都删
  @Test func migratesLaunchpadSwitch() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = Feature.launchpad.prefsKey
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.persistentDomain(forName: suite)?[key] == nil)

    defaults.set(false, forKey: Prefs.launchpadEnabledLegacy)
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.object(forKey: key) as? Bool == false)
    #expect(defaults.object(forKey: Prefs.launchpadEnabledLegacy) == nil)

    // 新键已经有值：旧键只删不搬
    defaults.set(true, forKey: key)
    defaults.set(false, forKey: Prefs.launchpadEnabledLegacy)
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.object(forKey: key) as? Bool == true)
    #expect(defaults.object(forKey: Prefs.launchpadEnabledLegacy) == nil)
  }

  /// 开关注册了默认值（跟着导出的「设置」一类走），默认开
  @Test func switchesAreExportedSettings() {
    for feature in Feature.allCases {
      #expect(Prefs.defaults[feature.prefsKey] as? Bool == true)
      #expect(SettingsArchive.kinds[feature.prefsKey] != nil)
    }
  }
}
