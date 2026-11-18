// 第四轮体检「搁着的计划」第 5 批（启动器、外壳、程序坞）的纯函数：主界面打字转启动器（X12）、反馈问题的网址（X14）、
// 快捷指令（X10）、别名查重算上应用别名（T3）、跳过这个版本（X11）

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct ShellBacklogTests {
  /// X12：能打出来的字才转去启动器；带 ⌘⌃⌥、空格、方向键、控制字符的不算（⇧ 打出来的大写、标点算）
  @Test func homeTypingGoesToLauncher() {
    #expect(Home.typed("a", modifiers: []) == "a")
    #expect(Home.typed("A", modifiers: .shift) == "A")
    #expect(Home.typed("你", modifiers: []) == "你")
    #expect(Home.typed("?", modifiers: .shift) == "?")
    #expect(Home.typed("a", modifiers: .command) == nil)
    #expect(Home.typed("a", modifiers: .control) == nil)
    #expect(Home.typed("å", modifiers: .option) == nil)
    #expect(Home.typed(" ", modifiers: []) == nil)
    #expect(Home.typed("\r", modifiers: []) == nil)
    #expect(Home.typed("\u{1B}", modifiers: []) == nil)
    #expect(Home.typed("\u{F700}", modifiers: .function) == nil)
    #expect(Home.typed("", modifiers: []) == nil)
    #expect(Home.typed(nil, modifiers: []) == nil)
  }

  /// X14：只带版本号、芯片和系统版本，别的什么都不带
  @Test func feedbackURLCarriesOnlyVersions() throws {
    let url = AboutTab.feedbackURL(
      version: "0.10.0",
      system: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1),
      chip: "Apple silicon")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "github.com")
    #expect(components.path == "/YyAdnBug/kitty-tools/issues/new")
    let items = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(Set(items.keys) == ["title", "body"])
    #expect(items["title"] == "[macOS 0.10.0] ")
    let body = try #require(items["body"])
    #expect(body.contains("0.10.0") && body.contains("Apple silicon"))
    #expect(body.contains("macOS 15.6.1"))
  }

  /// X10：shortcuts list 一行一个名字，去掉空行、首尾空白和重复的；目标「shortcut:名字」来回对得上
  @Test func shortcutsListParses() {
    #expect(
      SystemShortcuts.parse("打开专注\n  夜间模式 \n\n打开专注\n翻译剪贴板\n") == [
        "打开专注", "夜间模式", "翻译剪贴板",
      ])
    #expect(SystemShortcuts.parse("") == [])
    let target = SystemShortcuts.target("夜间模式")
    #expect(SystemShortcuts.name(fromTarget: target) == "夜间模式")
    #expect(SystemShortcuts.name(fromTarget: "lock") == nil)
    let item = SystemShortcuts.item("夜间模式")
    #expect(item.kind == .system && item.target == target)
    #expect(item.names.contains(LauncherMatch.fold("夜间模式")))
    #expect(item.names.contains("shortcut"))
  }

  /// T3：别名和应用别名撞了也描橙框（大小写、全半角按启动器的折叠比）
  @Test func aliasConflictsCountAppAliases() {
    let entries: [(id: String, alias: String?)] = [("a", "cal"), ("b", "dl"), ("c", "x")]
    #expect(LauncherCommands.conflicts(entries, engineKeywords: []) == [])
    #expect(
      LauncherCommands.conflicts(entries, engineKeywords: ["DL"], appAliases: ["cal"]) == [
        "a", "b",
      ])
    let aliases = AppAliases(text: #"{"com.apple.calculator": "cal, 计算"}"#)
    #expect(aliases.words.contains("cal"))
  }

  /// T3：应用别名按 bundle id 记——读包里的 Info.plist 拿得到；不是 App 的路径是 nil
  @Test func bundleIDFromPath() {
    #expect(
      AppCatalog.bundleID(at: "/System/Applications/Calculator.app") == "com.apple.calculator")
    #expect(AppCatalog.bundleID(at: "/tmp/not-an-app-\(UUID().uuidString)") == nil)
  }

  /// X11：跳过的那一版不挂角标、不进菜单和底栏；更新的版本出来照常提
  @Test func skippedVersionIsNotNudged() {
    let release = Updater.Release(
      version: "0.11.0", archive: URL(string: "https://example.com/a_arm64.zip")!,
      page: Updater.releasesPage)
    #expect(Updater.nudge(release, skipped: nil) == release)
    #expect(Updater.nudge(release, skipped: "0.11.0") == nil)
    #expect(Updater.nudge(release, skipped: "0.10.1") == release)
    #expect(Updater.nudge(nil, skipped: "0.11.0") == nil)
    let skipping = Updater(state: .available(release), skipped: "0.11.0")
    #expect(skipping.available == release && skipping.nudge == nil)
    #expect(!skipping.hasPrepared)
    let fresh = Updater(state: .available(release), skipped: nil)
    #expect(fresh.nudge == release)
    // 没有后台下好的包：退出时不装
    #expect(!fresh.hasPrepared)
  }

  /// X11 评审：清单和 API 两条路查到的同一版（一个带 sha256、一个没有）算同一个包；版本或地址不同就不是
  @Test func sameReleaseIgnoresChecksumAndPage() {
    let archive = URL(string: "https://example.com/a_arm64.zip")!
    let manifest = Updater.Release(
      version: "0.11.0", archive: archive, page: Updater.releasesPage, sha256: "ab")
    let api = Updater.Release(
      version: "0.11.0", archive: archive, page: URL(string: "https://example.com/r")!)
    #expect(Updater.same(manifest, api))
    #expect(!Updater.same(manifest, nil) && !Updater.same(nil, nil))
    let newer = Updater.Release(version: "0.11.1", archive: archive, page: Updater.releasesPage)
    #expect(!Updater.same(manifest, newer))
    let elsewhere = Updater.Release(
      version: "0.11.0", archive: URL(string: "https://example.com/b_arm64.zip")!,
      page: Updater.releasesPage)
    #expect(!Updater.same(manifest, elsewhere))
    #expect(
      Updater.backupURL(of: URL(filePath: "/Applications/Kitty Tools.app")).path
        == "/Applications/.Kitty Tools.app.before-update")
  }
}
