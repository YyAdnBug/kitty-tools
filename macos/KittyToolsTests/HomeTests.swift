// 主界面（Shell/HomePanel.swift，2026-10-29 拍板）的纯函数：分节和菜单同一份、单格的节并成一行、关着的功能有几个、
// 面板的高、选中怎么移动、按键对应什么。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct HomeTests {
  private let all = Set(Feature.allCases)

  /// 全开：节名和菜单同名同序（「打开主界面」不列它自己）；每节末尾接那一节的开关；启动台、状态屏、刘海岛三个单格的节
  /// 不画标题、并成最后一行；快捷键是传进来的那份，没设的空着
  @Test func sectionsFollowTheMenu() {
    var state = LauncherItem.ActionState(statusPresets: StatusPreset.builtIn)
    state.features = all
    let sections = Home.sections(state: state, keys: [.screenshot: "⌥A"])
    #expect(sections.map(\.title) == ["剪贴板与启动器", "翻译", "截图与录制", "便签", nil])
    let tiles = sections.flatMap(\.tiles)
    #expect(!tiles.contains { $0.target == .action(.home) })
    #expect(
      sections[0].tiles.map(\.target) == [
        .action(.clipboard), .action(.launcher), .extra(.pauseClipboard),
      ])
    #expect(sections[1].tiles.last?.target == .extra(.copyToTranslate))
    #expect(
      sections.last?.tiles.map(\.target) == [
        .action(.launchpad), .action(.statusScreen), .action(.island),
      ])
    #expect(tiles.first { $0.target == .action(.screenshot) }?.key == "⌥A")
    #expect(tiles.first { $0.target == .action(.clipboard) }?.key == nil)
    // 开关有状态、画在圆里的符号不带圈；别的不是开关
    let pause = tiles.first { $0.target == .extra(.pauseClipboard) }
    #expect(pause?.isOn == false && pause?.symbol == "pause.fill")
    #expect(tiles.filter { $0.isOn != nil }.count == 2)
    // 名字、符号、家族色和菜单 / 启动器同一份（主界面里用的符号都在）
    for tile in tiles {
      #expect(
        NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil) != nil,
        "\(tile.symbol)")
      if case .action(let action) = tile.target {
        #expect(tile.title == action.title && tile.color == action.color)
      }
    }
    #expect(
      NSImage(systemSymbolName: HotKeyAction.home.symbol, accessibilityDescription: nil) != nil)
  }

  /// 开关开着、有钉图、在录屏时：格子跟着现在的样子
  @Test func sectionsFollowState() {
    var state = LauncherItem.ActionState(
      recordingPaused: true, copyToTranslate: true, pinsHidden: true, recording: .screenRecord)
    state.features = all
    let tiles = Home.sections(state: state, keys: [:]).flatMap(\.tiles)
    #expect(tiles.first { $0.target == .extra(.pauseClipboard) }?.isOn == true)
    #expect(tiles.first { $0.target == .extra(.copyToTranslate) }?.isOn == true)
    #expect(tiles.first { $0.target == .action(.screenRecord) }?.title == "停止录屏")
    // 钉图两项接在截图那一节末尾，不是开关
    let shot = Home.sections(state: state, keys: [:])[2].tiles
    #expect(shot.suffix(2).map(\.target) == [.extra(.pinsToggle), .extra(.pinsClose)])
    #expect(shot.last?.isOn == nil && shot.suffix(2).first?.title == "显示全部钉图")
    // 设置、关于、检查更新、退出不是格子（底栏 / 右键菜单里）
    #expect(!tiles.contains { $0.target == .extra(.settings) || $0.target == .extra(.quit) })
  }

  /// 关掉功能：它的格子和那一节的开关都不在；两个功能合一节的只剩一个时节名换成它的；只剩一格的节不画标题、
  /// 和后面连着的单格并成一行（顺序不变）；全关时只剩刘海岛
  @Test func sectionsFollowFeatures() {
    var state = LauncherItem.ActionState()
    state.features = all.subtracting([.clipboard, .notes])
    let sections = Home.sections(state: state, keys: [:])
    // 只剩「启动器」一格：不画标题，排在原来的位置
    #expect(
      sections.first?.title == nil && sections.first?.tiles.map(\.target) == [.action(.launcher)])
    #expect(!sections.flatMap(\.tiles).contains { $0.target == .extra(.pauseClipboard) })
    #expect(!sections.contains { $0.title == "便签" })

    state.features = all.subtracting([.screenshot])
    #expect(Home.sections(state: state, keys: [:]).contains { $0.title == "录制" })

    state.features = []
    let none = Home.sections(state: state, keys: [:])
    #expect(
      none.count == 1 && none[0].title == nil && none[0].tiles.map(\.target) == [.action(.island)])
  }

  /// 关着的功能有几个：只算这台系统上有、而且有入口的（程序坞预览没有全局动作，关着不算；macOS 15 没有启动台，不算）
  @Test func offCount() {
    #expect(Home.offCount(enabled: all, available: all) == 0)
    #expect(Home.offCount(enabled: all.subtracting([.dockPreview]), available: all) == 0)
    #expect(Home.offCount(enabled: all.subtracting([.notes, .record]), available: all) == 2)
    let noLaunchpad = all.subtracting([.launchpad])
    #expect(Home.offCount(enabled: noLaunchpad, available: noLaunchpad) == 0)
  }

  /// 每节自己折行；面板的高按节、行、关着的功能那一行、底栏算；宽放得下 5 格
  @Test func layout() {
    var state = LauncherItem.ActionState()
    state.features = all
    let sections = Home.sections(state: state, keys: [:])
    // 3 / 5 / 8 / 3 / 3（截图与录制 8 格折成 5 + 3）
    #expect(Home.rows(sections).map(\.count) == [3, 5, 5, 3, 3, 3])
    #expect(Home.rows(sections).flatMap { $0 } == Array(0..<22))
    let rows: CGFloat = 6
    let expected =
      Home.top + Home.bottom + 4 * Home.titleHeight + Home.untitledGap + rows * Home.tile.height
      + (rows - 5) * Home.gap + Home.barHeight
    #expect(Home.height(sections, offCount: 0) == expected)
    #expect(Home.height(sections, offCount: 2) == expected + Home.noteHeight)
    #expect(Home.width == 2 * Home.inset + 5 * Home.tile.width + 4 * Home.gap)
  }

  /// ←→ 按顺序走、到头回绕；↑↓ 换行、列不变，短的那行落在最后一格，第一行 / 最后一行不动；还没选中时是第一格
  @Test func movement() {
    let rows = [[0, 1, 2], [3, 4, 5, 6, 7], [8, 9]]
    #expect(Home.moved(nil, .down, rows: rows) == 0)
    #expect(Home.moved(0, .left, rows: rows) == 9)
    #expect(Home.moved(9, .right, rows: rows) == 0)
    #expect(Home.moved(2, .down, rows: rows) == 5)
    #expect(Home.moved(7, .up, rows: rows) == 2)
    #expect(Home.moved(6, .down, rows: rows) == 9)
    #expect(Home.moved(1, .up, rows: rows) == 1)
    #expect(Home.moved(8, .down, rows: rows) == 8)
    #expect(Home.moved(nil, .right, rows: []) == nil)
  }

  /// 按键：方向键、Tab 选，↩ / 空格执行，Esc 收起；带 ⌘⌃⌥ 的不管；⌘, 设置、⌘Q 退出（大写锁定不碍事）
  @Test func keys() {
    #expect(Home.key(code: kVK_DownArrow, modifiers: []) == .move(.down))
    #expect(Home.key(code: kVK_Tab, modifiers: .shift) == .move(.left))
    #expect(Home.key(code: kVK_Space, modifiers: []) == .run)
    #expect(Home.key(code: kVK_Return, modifiers: []) == .run)
    #expect(Home.key(code: kVK_Escape, modifiers: []) == .cancel)
    #expect(Home.key(code: kVK_Return, modifiers: .command) == nil)
    #expect(Home.key(code: kVK_ANSI_A, modifiers: []) == nil)
    #expect(Home.command(code: kVK_ANSI_Comma, modifiers: .command) == .settings)
    #expect(Home.command(code: kVK_ANSI_Q, modifiers: [.command, .capsLock]) == .quit)
    #expect(Home.command(code: kVK_ANSI_Q, modifiers: [.command, .shift]) == nil)
    #expect(Home.command(code: kVK_ANSI_W, modifiers: .command) == nil)
  }

  /// 模型：开关原地切（不收面板）、别的先收面板再做；没选中时 ↩ 什么都不做；刷新时选中留着、超出了落到最后一格
  @Test func modelRunsTiles() {
    var state = LauncherItem.ActionState()
    state.features = all
    let model = HomeModel()
    model.update(Home.sections(state: state, keys: [:]), offCount: 0, appearing: true)
    var hidden = 0
    var done: [Home.Tile.Target] = []
    model.hidePanel = { hidden += 1 }
    model.perform = { done.append($0) }
    model.handle(.run)
    #expect(done.isEmpty)
    model.activate(2)
    #expect(done == [.extra(.pauseClipboard)] && hidden == 0)
    model.activate(0)
    #expect(done.last == .action(.clipboard) && hidden == 1)
    model.handle(.move(.left))
    #expect(model.selection == 0)
    model.handle(.move(.left))
    #expect(model.selection == model.tiles.count - 1)
    state.features = []
    model.update(Home.sections(state: state, keys: [:]), offCount: 0, appearing: false)
    #expect(model.selection == 0)
    model.update(Home.sections(state: state, keys: [:]), offCount: 0, appearing: true)
    #expect(model.selection == nil)
    model.run(.quit)
    #expect(done.last == .extra(.quit) && hidden == 2)
  }
}
