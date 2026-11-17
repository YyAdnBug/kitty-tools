// 插件的声明（Shell/Plugin.swift，2026-11-17 插件页改版第 1 批）：每个插件都写齐、分组不漏、缺授权的算法、
// 同步留在本机的插件和改版前一样、新插件的「新」标记（没添加也标、添加了就没）。

import Foundation
import Testing

@testable import KittyTools

@MainActor
struct PluginTests {
  /// 每个插件都有组、两三条「能做什么」、「怎么用」、「后台」；不是插件的都没有
  @Test func everyPluginIsDeclared() {
    for feature in Feature.allCases {
      if feature.isPlugin {
        #expect(feature.pluginGroup != nil, "\(feature)")
        #expect((2...3).contains(feature.pluginPoints.count), "\(feature)")
        #expect(feature.pluginHowTo != nil, "\(feature)")
        #expect(feature.pluginBackground != nil, "\(feature)")
      } else {
        #expect(feature.pluginGroup == nil, "\(feature)")
        #expect(feature.pluginPoints.isEmpty && feature.pluginPermissions.isEmpty, "\(feature)")
      }
    }
  }

  /// 各组按 Feature 的先后、合起来正好是这台系统上有的插件（一个不漏、不重）
  @Test func groupsCoverEveryPlugin() {
    let grouped = Feature.PluginGroup.allCases.flatMap(\.plugins)
    #expect(Set(grouped) == Set(Feature.plugins.filter(\.isAvailable)))
    #expect(grouped.count == Set(grouped).count)
    #expect(Feature.PluginGroup.desktop.plugins.first == .launchpad || !Launchpad.isAvailable)
  }

  /// 添加状态只在这台的（拍板 F2）：和改版前 SettingsSync 里点名的那四个一样，加上平滑滚动（要这台给辅助功能、跟这台
  /// 接没接鼠标有关），并且都进了 localKeys
  @Test func localPluginsMatchBefore() {
    let local = Feature.plugins.filter { !$0.syncsAddition }
    #expect(local == [.launchpad, .dockPreview, .finderMenu, .bluetoothSnooze, .smoothScroll, .appShortcuts])
    for plugin in Feature.plugins {
      #expect(
        SettingsSync.localKeys.contains(plugin.prefsKey) == !plugin.syncsAddition, "\(plugin)")
    }
  }

  /// 缺不缺：添加了就要的看给没给；开关才要的只在开关开着时算；查不了的（自动化）不算缺
  @Test func missingPermissions() {
    let always = PluginPermission(kind: .accessibility, reason: "x")
    let option = PluginPermission(kind: .calendar, reason: "x", option: "k")
    let unknown = PluginPermission(kind: .automation, reason: "x")
    let denied: (Permissions.Kind) -> Bool? = { $0 == .automation ? nil : false }
    #expect(always.isMissing(isOn: { _ in false }, granted: denied))
    #expect(!always.isMissing(isOn: { _ in false }, granted: { _ in true }))
    #expect(!option.isMissing(isOn: { _ in false }, granted: denied))
    #expect(option.isMissing(isOn: { $0 == "k" }, granted: denied))
    #expect(!unknown.isMissing(isOn: { _ in true }, granted: denied))
  }

  /// 刘海岛的授权都挂在开关上（插件本身不要授权）；程序坞预览、访达右键、睡眠关蓝牙、状态屏、平滑滚动添加了就要
  @Test func permissionDeclarations() {
    #expect(Feature.island.pluginPermissions.allSatisfy { $0.option != nil })
    #expect(
      Feature.dockPreview.pluginPermissions.map(\.kind) == [.accessibility, .screenRecording])
    #expect(Feature.finderMenu.pluginPermissions.map(\.kind) == [.finderExtension])
    #expect(Feature.bluetoothSnooze.pluginPermissions.map(\.kind) == [.bluetooth])
    #expect(Feature.statusScreen.pluginPermissions.map(\.kind) == [.accessibility])
    #expect(Feature.smoothScroll.pluginPermissions.map(\.kind) == [.accessibility])
    #expect(Feature.appShortcuts.pluginPermissions.map(\.kind) == [.accessibility])
    for plugin in [Feature.notes, .reminders, .launchpad, .keepAwake] {
      #expect(plugin.pluginPermissions.isEmpty, "\(plugin)")
    }
  }

  /// 新插件的「新」（拍板 E1）：插件没添加也标；添加了就不标；碰过（添加时记下）以后移除也不再标
  @Test func newPluginMarks() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let entry = WhatsNew.Entry(
      id: "plugin-x", version: "9.0.0", feature: nil, page: .general, plugin: .keepAwake)
    var ledger = WhatsNew.adopting(.init(), from: "8.0.0", to: "9.0.0", now: now, entries: [entry])
    #expect(WhatsNew.fresh(ledger, enabled: [], now: now, entries: [entry]) == [entry])
    #expect(WhatsNew.fresh(ledger, enabled: [.keepAwake], now: now, entries: [entry]).isEmpty)
    ledger = WhatsNew.touching(ledger, entries: [entry]) { $0.plugin == .keepAwake }
    #expect(WhatsNew.fresh(ledger, enabled: [], now: now, entries: [entry]).isEmpty)
    // 这台用不了的插件不标（「全部插件」里没有它，碰不掉；评审 1）
    for plugin in Feature.plugins where !plugin.isAvailable {
      let gone = WhatsNew.Entry(
        id: "plugin-y", version: "9.0.0", feature: nil, page: .general, plugin: plugin)
      #expect(WhatsNew.fresh(ledger, enabled: [], now: now, entries: [gone]).isEmpty, "\(plugin)")
    }
  }
}
