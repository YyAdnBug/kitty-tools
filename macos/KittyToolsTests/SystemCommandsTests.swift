// 启动器系统命令单测：目录（符号、保留关键词）、匹配（Alfred 关键词、中文名 / 口语 / 拼音）、带对象模式的解析与
// 列举过滤、执行流程（面板先收起、不记使用、不可撤销的要再按一次）。执行只走注入的 perform，从不真锁屏、关机。

import AppKit
import Testing

@testable import KittyTools

struct SystemCommandsTests {
  private func model() throws -> (LauncherModel, LauncherUsage) {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    return (LauncherModel(usage: usage, apps: []), usage)
  }

  private func app(_ title: String, chinese: String? = nil) -> LauncherItem {
    let pinyin = chinese.flatMap(AppCatalog.pinyin)
    return LauncherItem(
      kind: .app, target: "/Applications/\(title).app", title: chinese ?? title, subtitle: title,
      names: [chinese, title, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) })
  }

  @Test func catalog() {
    #expect(SystemCommands.items.count == SystemCommand.allCases.count)
    #expect(Set(SystemCommands.items.map(\.title)).count == SystemCommand.allCases.count)
    #expect(SystemCommands.items.allSatisfy { $0.kind == .system && $0.subtitle == $0.target })
    for symbol in SystemCommand.allCases.map(\.symbol) + SystemCommands.Verb.allCases.map(\.symbol)
    {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
    // 带对象的关键词不能被网页搜索占掉
    for verb in SystemCommands.Verb.allCases {
      #expect(WebSearch.reservedKeywords[verb.rawValue] != nil, "\(verb)")
    }
    #expect(SystemCommand.allCases.filter { $0.confirmation != nil } == [.emptytrash, .quitall])
  }

  @Test func matching() throws {
    let (model, _) = try model()
    func first(_ query: String) -> String? {
      model.query = query
      return model.results.first.map { $0.kind == .system ? $0.target : $0.title }
    }
    #expect(first("lock") == "lock")
    #expect(first("sleep") == "sleep")  // 关键词完全相同的排在 sleepdisplays 前面
    #expect(first("sleepd") == "sleepdisplays")
    #expect(first("锁屏") == "lock")
    #expect(first("suoding") == "lock")
    #expect(first("重启") == "restart")
    #expect(first("屏保") == "screensaver")
    #expect(first("qdfzl") == "emptytrash")
    // screen：屏幕保护程序（英文名开头）、锁定屏幕（英文名词首）都在；和「截图」同分时标题短的在前，用多了自己排上来
    model.query = "screen"
    #expect(model.results.contains { $0.target == "screensaver" })
    #expect(model.results.contains { $0.target == "lock" })
  }

  @Test func requestParsing() {
    typealias Request = SystemCommands.Request
    #expect(SystemCommands.request(for: "quit") == nil)  // 只输关键词：补全提示，不进模式
    #expect(SystemCommands.request(for: "quit ") == Request(verb: .quit, terms: []))
    #expect(SystemCommands.request(for: "Quit  saf") == Request(verb: .quit, terms: ["saf"]))
    #expect(SystemCommands.request(for: "quitall") == nil)  // 固定命令
    #expect(SystemCommands.request(for: "forcequit 微信") == Request(verb: .forcequit, terms: ["微信"]))
    #expect(SystemCommands.request(for: "eject ") == Request(verb: .eject, terms: []))
    #expect(SystemCommands.request(for: "hider x") == nil)
    let prompts = SystemCommands.promptItems(for: "quit")
    #expect(prompts.exact.map(\.completion) == ["quit "])
    #expect(SystemCommands.promptItems(for: "ej").partial.map(\.target) == ["system-eject"])
  }

  @Test func targetFilters() {
    let lists = { SystemCommands.lists(bundleID: $0, policy: $1, isCurrent: $2, for: $3) }
    #expect(lists("com.apple.Safari", .regular, false, .quit))
    #expect(!lists("com.apple.finder", .regular, false, .quit))  // 访达没有「退出」
    #expect(!lists("com.apple.finder", .regular, false, .forcequit))
    #expect(lists("com.apple.finder", .regular, false, .hide))
    #expect(!lists("com.example.menubar", .accessory, false, .quit))  // 菜单栏 App 不列
    #expect(!lists("com.yy.kitty-tools.native", .regular, true, .hide))  // 不含本 App
    let ejectable = {
      SystemCommands.isEjectable(root: $0, browsable: $1, ejectable: $2, removable: $3, local: $4)
    }
    #expect(!ejectable(true, true, false, false, true))  // 启动宗卷
    #expect(!ejectable(false, true, false, false, true))  // 内置的另一个分区
    #expect(ejectable(false, true, true, true, true))  // 磁盘映像 / U 盘
    #expect(ejectable(false, true, false, false, false))  // 网络宗卷
    #expect(!ejectable(false, false, true, true, true))  // 访达里看不见的
  }

  @Test func runningAppRowsDoNotReadBundles() {
    // 名字来自 NSRunningApplication（已是中文名），副标题是包名；拼音、包名、首字母都能搜
    let notes = SystemCommands.appItem(name: "备忘录", path: "/System/Applications/Notes.app")
    #expect(notes.kind == .app && notes.title == "备忘录" && notes.subtitle == "Notes")
    for query in ["备忘", "beiwang", "notes", "bwl"] {
      #expect(LauncherMatch.score(query, item: notes) > 0, "\(query)")
    }
    let local = SystemCommands.appItem(name: "Demo", path: "/Users/me/Desktop/Demo.app")
    #expect(local.subtitle == "应用程序" && local.names == ["demo"])
  }

  @Test func finderCanOnlyBeHidden() throws {
    let (model, _) = try model()
    let finder = LauncherItem(
      kind: .app, target: SystemCommands.finderPath, title: "访达", subtitle: "Finder",
      names: ["访达", "finder"])
    var performed: [SystemControl.Action] = []
    model.commandTargets = { _ in [finder] }
    model.perform = { performed.append($0) }
    model.query = "hide "
    let row = try #require(model.selectedItem)
    #expect(model.commandReturnAction(for: row) == nil)
    #expect(!model.actions.contains { $0.shortcut == "⌘↩" })
    model.execute(row)
    #expect(performed == [.hide(SystemCommands.finderPath)])
  }

  @Test func targetModeRunsOnceWithoutRecording() throws {
    let (model, usage) = try model()
    let safari = app("Safari")
    let notes = app("Notes", chinese: "备忘录")
    var listed: [SystemCommands.Verb] = []
    var performed: [SystemControl.Action] = []
    var hides = 0
    model.commandTargets = {
      listed.append($0)
      return [safari, notes]
    }
    model.perform = { performed.append($0) }
    model.hidePanel = { hides += 1 }
    model.query = "quit"
    #expect(model.results.first?.target == "system-quit")
    model.query = "quit "
    #expect(model.groupTitle == "正在运行的 App")
    #expect(model.results.map(\.title) == ["Safari", "备忘录"])
    model.query = "quit bei"
    #expect(model.results.map(\.title) == ["备忘录"])
    #expect(model.groupTitle == nil)
    #expect(listed == [.quit])  // 进模式时列一次，打字只过滤
    let target = try #require(model.selectedItem)
    #expect(model.primaryAction(for: target).title == "退出")
    #expect(model.commandReturnAction(for: target)?.title == "强制退出")
    #expect(model.copyTitle(for: target) == "复制路径")
    model.execute(target)
    #expect(performed == [.quit(notes.target)] && hides == 1)
    #expect(usage.entries.isEmpty)  // 退出过的 App 不在普通搜索里加分
    model.query = "hide "
    model.execute(try #require(model.results.first))
    #expect(performed.last == .hide(safari.target) && listed == [.quit, .hide])
    model.query = "eject "
    #expect(model.groupTitle == "可推出的磁盘" && listed.last == .eject)
  }

  @Test func irreversibleCommandsNeedSecondPress() throws {
    let (model, usage) = try model()
    var performed: [SystemControl.Action] = []
    var hides = 0
    model.perform = { performed.append($0) }
    model.hidePanel = { hides += 1 }
    model.query = "emptytrash"
    let trash = try #require(model.results.first)
    #expect(trash.target == "emptytrash")
    model.execute(trash)
    #expect(performed.isEmpty && hides == 0 && model.isArmed(trash))
    #expect(model.alternateSubtitle(for: trash) == "再按 ↩ 清倒废纸篓，不能撤销")
    #expect(model.primaryAction(for: trash).title == "确认清倒废纸篓")
    // Esc 先撤掉上膛，搜索词还在
    #expect(model.handleCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(model.query == "emptytrash" && !model.isArmed(trash))
    model.execute(trash)
    model.execute(trash)
    #expect(performed == [.command(.emptytrash)] && hides == 1)
    #expect(!usage.entries.isEmpty)
    // 不用确认的直接执行；用过的进「最近使用」
    model.query = "lock"
    model.execute(try #require(model.results.first))
    #expect(performed.last == .command(.lock) && hides == 2)
    model.query = ""
    #expect(model.results.contains { $0.kind == .system && $0.target == "lock" })
    // forcequit 的 ↩：打字撤掉上膛，要重新按两下
    let safari = app("Safari")
    model.commandTargets = { _ in [safari] }
    model.query = "forcequit "
    model.execute(try #require(model.results.first))
    #expect(performed.count == 2)
    #expect(model.alternateSubtitle(for: safari) == SystemCommands.forceQuitConfirmation(key: "↩"))
    model.query = "forcequit s"
    model.execute(try #require(model.results.first))
    #expect(performed.count == 2)
    model.execute(try #require(model.results.first))
    #expect(performed.last == .forceQuit(safari.target))
    // quit 里的 ⌘↩（⌘K 菜单第二行同一段代码）：也要再按一次
    model.query = "quit "
    model.selection = 0
    let force = try #require(model.actions.first { $0.shortcut == "⌘↩" })
    #expect(force.title == "强制退出")
    force.run()
    #expect(performed.count == 3)
    #expect(model.actions.first { $0.shortcut == "⌘↩" }?.title == "确认强制退出")
    try #require(model.actions.first { $0.shortcut == "⌘↩" }).run()
    #expect(performed.last == .forceQuit(safari.target) && performed.count == 4)
  }
}
