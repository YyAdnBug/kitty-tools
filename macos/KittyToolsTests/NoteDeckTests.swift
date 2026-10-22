// 便签第 3 批「屏幕边缘那叠」的单测（PLAN §10「便签」，规矩在 mac-overlay-panel §12）：
// - 设置（NoteDeckOptions：默认值、不认识的值、哪些键跟着导出走）；
// - 几何（NoteDeckLayout / NoteDeckMetrics：三档大小、露出的一截跟着最长的标题走、68% 上限和最小露出、「+N」、
//   放不下时的视口、药丸多高、放哪块屏哪条边、药丸 / 那叠 / 便签摆在哪、热区、拖动排序落在第几格、⌥ 拖药丸）；
// - 竖排标题（NoteDeckLabel：哪些字正着放、分段、截断）；
// - 状态机（NoteDeckState：每一条转移和不该发生的转移、叫停、让给别的屏、一直展开）；
// - 什么时候有、第一次出现的提示只说一次（NoteEdge）；
// - 界面读的状态（NoteDeckModel：一次 5 张和「+N」、新建、归档 / 删除之后、操作菜单、按键、拖动排序）；
// - 两块窗口各算什么（药丸：截图和录屏都不收；那叠的面板：冻结帧里留着、录屏白名单里有）、点哪算点别处。
// 全用内存库和临时偏好域；窗口只建不显示——唯一真露出来的一次（扇出再被叫停）摆在离所有屏幕很远的地方，先确认再露。
// 打开便签那一步面板会当 key（抢键盘），不在测试里走。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

struct NoteDeckTests {
  private typealias Edge = NoteDeckOptions.Edge
  private typealias Layout = NoteDeckLayout

  /// 一块 1440 × 900 的屏（菜单栏 25），左下角在 origin
  private static func screen(
    _ name: String = "主屏", x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1440,
    height: CGFloat = 900
  ) -> NoteDeckScreen {
    NoteDeckScreen(
      name: name, frame: CGRect(x: x, y: y, width: width, height: height),
      visibleFrame: CGRect(x: x, y: y, width: width, height: height - 25))
  }

  private func prefs() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "NoteDeckTests-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  /// 内存库上的仓库和模型；bodies 就是标签从上到下的顺序（新建的排最前，所以倒着建）
  private func make(_ bodies: [String]) throws -> (
    model: NoteDeckModel, store: NoteStore, ids: [String]
  ) {
    let store = try NoteStore(db: Database(path: ":memory:"))
    for (offset, body) in bodies.reversed().enumerated() {
      store.create(body: body, now: Date(timeIntervalSince1970: 1_760_000_000 + Double(offset)))
    }
    let model = NoteDeckModel(store: store)
    model.panelSize = CGSize(width: 538, height: 875)
    model.pillCenter = 437
    return (model, store, store.active.map(\.id))
  }

  private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: UInt16(code)))
  }

  // MARK: 设置

  /// 没存过的都是默认值（单测的临时偏好域里没有注册默认值），和注册的默认值是同一套
  @Test func optionsDefaultToTheRegisteredValues() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let options = NoteDeckOptions(defaults)
    #expect(options == NoteDeckOptions())
    #expect(options.isEnabled && options.edge == .right && options.display == .main)
    #expect(options.style == .tabs && options.size == .standard && options.sense == 14)
    #expect(!options.alwaysFanned && !options.hidesPill && options.showsPreview)
    #expect(!options.opensOnHover && !options.overFullScreen && options.noteSize == .medium)
    #expect(options.position == 0.5)
    let registered = Prefs.defaults
    #expect(registered[Prefs.notesDeckEnabled] as? Bool == true)
    #expect(registered[Prefs.notesDeckEdge] as? String == "right")
    #expect(registered[Prefs.notesDeckDisplay] as? String == "main")
    #expect(registered[Prefs.notesDeckStyle] as? String == "tabs")
    #expect(registered[Prefs.notesDeckSize] as? String == "standard")
    #expect(registered[Prefs.notesDeckSense] as? Int == 14)
    #expect(registered[Prefs.notesDeckAlwaysFanned] as? Bool == false)
    #expect(registered[Prefs.notesDeckHidesPill] as? Bool == false)
    #expect(registered[Prefs.notesDeckPreview] as? Bool == true)
    #expect(registered[Prefs.notesDeckOpensOnHover] as? Bool == false)
    #expect(registered[Prefs.notesDeckOverFullScreen] as? Bool == false)
    #expect(registered[Prefs.notesDeckNoteSize] as? String == "medium")
  }

  /// 设置跟着导出文件走；药丸的位置、指定的是哪块屏、提示说没说过、示例便签放没放过是这台电脑自己的状态，
  /// 不注册默认值、不导出
  @Test func machineStateIsNotRegistered() {
    let exported = [
      Prefs.notesDeckEnabled, Prefs.notesDeckEdge, Prefs.notesDeckDisplay, Prefs.notesDeckStyle,
      Prefs.notesDeckSize, Prefs.notesDeckSense, Prefs.notesDeckAlwaysFanned,
      Prefs.notesDeckHidesPill, Prefs.notesDeckPreview, Prefs.notesDeckOpensOnHover,
      Prefs.notesDeckOverFullScreen, Prefs.notesDeckNoteSize,
    ]
    for key in exported {
      #expect(Prefs.defaults[key] != nil && SettingsArchive.kinds[key] != nil, "\(key)")
    }
    for key in [
      Prefs.notesDeckPosition, Prefs.notesDeckChosenDisplay, Prefs.notesDeckHintShown,
      Prefs.notesSampleAdded,
    ] {
      #expect(Prefs.defaults[key] == nil && SettingsArchive.kinds[key] == nil, "\(key)")
    }
  }

  /// 存了的照读；不在档位里的、类型不对的按默认算（导入的文件、手改的偏好）
  @Test func optionsReadStoredAndRejectUnknownValues() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: Prefs.notesDeckEnabled)
    defaults.set("left", forKey: Prefs.notesDeckEdge)
    defaults.set("all", forKey: Prefs.notesDeckDisplay)
    defaults.set("chips", forKey: Prefs.notesDeckStyle)
    defaults.set("large", forKey: Prefs.notesDeckSize)
    defaults.set(44, forKey: Prefs.notesDeckSense)
    defaults.set(true, forKey: Prefs.notesDeckAlwaysFanned)
    defaults.set(true, forKey: Prefs.notesDeckHidesPill)
    defaults.set(false, forKey: Prefs.notesDeckPreview)
    defaults.set(true, forKey: Prefs.notesDeckOpensOnHover)
    defaults.set(true, forKey: Prefs.notesDeckOverFullScreen)
    defaults.set("extraLarge", forKey: Prefs.notesDeckNoteSize)
    defaults.set(0.25, forKey: Prefs.notesDeckPosition)
    var options = NoteDeckOptions(defaults)
    #expect(!options.isEnabled && options.edge == .left && options.display == .all)
    #expect(options.style == .chips && options.size == .large && options.sense == 44)
    #expect(options.alwaysFanned && options.hidesPill && !options.showsPreview)
    #expect(options.opensOnHover && options.overFullScreen && options.noteSize == .extraLarge)
    #expect(options.position == 0.25)
    #expect(options.size.scale == 1.25 && NoteDeckOptions.Size.small.scale == 0.85)
    #expect(
      NoteDeckOptions.NoteSize.allCases.map(\.size) == [
        CGSize(width: 400, height: 320), CGSize(width: 460, height: 380),
        CGSize(width: 560, height: 470), CGSize(width: 680, height: 560),
      ])

    defaults.set("top", forKey: Prefs.notesDeckEdge)
    defaults.set("huge", forKey: Prefs.notesDeckSize)
    defaults.set(13, forKey: Prefs.notesDeckSense)
    defaults.set("poster", forKey: Prefs.notesDeckNoteSize)
    defaults.set(7.5, forKey: Prefs.notesDeckPosition)
    options = NoteDeckOptions(defaults)
    #expect(options.edge == .right && options.size == .standard && options.sense == 14)
    #expect(options.noteSize == .medium && options.position == 1)
    defaults.set(-3, forKey: Prefs.notesDeckPosition)
    #expect(NoteDeckOptions(defaults).position == 0)

    // 指定某一块：要两个键都在；只说「指定」没说是哪块 = 主显示器
    defaults.set("chosen", forKey: Prefs.notesDeckDisplay)
    #expect(NoteDeckOptions(defaults).display == .main)
    defaults.set("DELL U2720Q", forKey: Prefs.notesDeckChosenDisplay)
    #expect(NoteDeckOptions(defaults).display == .named("DELL U2720Q"))
    defaults.set("everywhere", forKey: Prefs.notesDeckDisplay)
    #expect(NoteDeckOptions(defaults).display == .main)
  }

  /// 标签倾斜（2026-10-13 加成开关；2026-10-15 用户改成一律斜着、删掉开关）：角度右边缘逆时针、左边缘顺时针，
  /// 列里打开的那张立正（isOn 是 false）；朝屏幕边多画出去的一截随大小档缩放、够盖住斜出来的缝。
  /// 只是画面上的变换，排法里没有它（NoteDeckLayout 不看它）
  @Test func tiltGeometry() throws {
    #expect(
      Layout.tilt(edge: .right, isOn: true) == -3 && Layout.tilt(edge: .left, isOn: true) == 3)
    #expect(
      Layout.tilt(edge: .right, isOn: false) == 0 && Layout.tilt(edge: .left, isOn: false) == 0)
    #expect(NoteDeckMetrics(scale: 1).tiltBleed == 14)
    #expect(
      NoteDeckMetrics(scale: 0.85).tiltBleed == 12 && NoteDeckMetrics(scale: 1.25).tiltBleed == 18)
    for size in NoteDeckOptions.Size.allCases {
      let metrics = NoteDeckMetrics(scale: size.scale)
      // 最高的一张（露出最长的一截 + 被压住的）绕贴边那一侧的中点转 3°：上下角离开屏幕边的距离
      let gap = (metrics.stripMax + metrics.lap) / 2 * sin(Layout.tiltDegrees * .pi / 180)
      #expect(metrics.tiltBleed > gap + 2, "\(size)")
    }
  }

  // MARK: 尺寸和排法

  /// 三档大小：所有尺寸一起按比例，都是整点（叠着的标签不出缝）；字最小 10 pt
  @Test func metricsScaleTogetherOnWholePoints() {
    let standard = NoteDeckMetrics(scale: 1)
    #expect(standard.pillWidth == 12 && standard.tabWidth == 30 && standard.lap == 40)
    #expect(standard.stripMin == 56 && standard.stripMax == 106 && standard.stripFloor == 36)
    #expect(standard.chipHeight == 24 && standard.fontSize == 12)
    for size in NoteDeckOptions.Size.allCases {
      let metrics = NoteDeckMetrics(scale: size.scale)
      let values = [
        metrics.pillWidth, metrics.pillMinHeight, metrics.pillPadding, metrics.dashWidth,
        metrics.dashHeight, metrics.dashGap, metrics.tabWidth, metrics.lap, metrics.stripMin,
        metrics.stripMax, metrics.stripFloor, metrics.labelPadding, metrics.labelInset,
        metrics.chipHeight, metrics.chipGap, metrics.moreHeight, metrics.moreGap,
        metrics.plusSize, metrics.plusGap, metrics.fontSize, metrics.glyphAdvance,
      ]
      #expect(values.allSatisfy { $0 == $0.rounded() && $0 > 0 }, "\(size)")
      #expect(metrics.fontSize >= 10)
      #expect(metrics.tabWidth == (30 * size.scale).rounded())
      #expect(metrics.dashWidth < metrics.pillWidth && metrics.plusSize <= metrics.tabWidth)
    }
    #expect(NoteDeckMetrics(scale: 0.85).tabWidth == 26 && NoteDeckMetrics(scale: 1.25).lap == 50)
  }

  /// 带标题的标签：露出的一截 = 最长的标题 + 20，夹在 56–106；每张高 = 那一截 + 压住的 40，相邻两张顶边差一截
  @Test func stripFollowsTheLongestTitle() {
    func layout(_ longest: CGFloat, count: Int = 3) -> Layout {
      Layout(
        count: count, hidden: 0, longestLabel: longest, height: 900, options: NoteDeckOptions())
    }
    #expect(layout(10).step == 56 && layout(10).itemHeight == 96)
    #expect(layout(50).step == 70 && layout(50).itemHeight == 110)
    #expect(layout(300).step == 106 && layout(300).itemHeight == 146)
    let three = layout(50)
    #expect(three.spacing == -40 && three.stackHeight == 2 * 70 + 110 && three.viewport == nil)
    #expect(three.strip(at: 0) == 70 && three.strip(at: 2) == 110)  // 最后一张没人压，整张露着
    #expect(three.tabCenter(0) == 35 && three.tabCenter(1) == 105 && three.tabCenter(2) == 175)
    // 整列 = 标签 + 最下面的「+」（间隔 10、26 见方）；有「+N」再加间隔 7、高 30
    #expect(three.columnHeight == 286)  // 250 + 10 + 26
    let more = Layout(
      count: 5, hidden: 2, longestLabel: 50, height: 900, options: NoteDeckOptions())
    let expected: CGFloat = 390 + 37 + 36  // 4 × 70 + 110，「+N」37，「+」36
    #expect(more.hidden == 2 && more.columnHeight == expected)
    #expect(layout(50, count: 0).stackHeight == 0 && layout(50, count: 0).viewport == nil)
  }

  /// 一共占的高度不超过屏高的 68%：超了把露出的一截压短，最短 36；还放不下（「+N」展开之后）就给一个视口在里面滚
  @Test func heightBudgetSqueezesThenScrolls() {
    let options = NoteDeckOptions()
    // 屏高 600：预算 = 600 × 0.68 − (10 + 26) = 372。5 张、每张想露 106：5 × 106 + 40 = 570 超了
    let squeezed = Layout(count: 5, hidden: 0, longestLabel: 300, height: 600, options: options)
    #expect(squeezed.step == 66 && squeezed.stackHeight == 4 * 66 + 106)  // (372 − 40) / 5 向下取整
    #expect(squeezed.stackHeight <= 372 && squeezed.viewport == nil)
    // 有「+N」时预算再让出它的 37
    let withMore = Layout(count: 5, hidden: 9, longestLabel: 300, height: 600, options: options)
    #expect(withMore.step == 59 && withMore.columnHeight <= 600 * 0.68)
    // 30 张：压到 36 也放不下——反正要滚，就不压了（按最小的 56 排），标签那一段在视口里滚，整列正好是预算
    let all = Layout(count: 30, hidden: 0, longestLabel: 300, height: 600, options: options)
    #expect(all.step == 56 && all.itemHeight == 96 && all.stackHeight == 29 * 56 + 96)
    #expect(all.viewport == 372 && all.tabsHeight == 372 && all.columnHeight == 408)
    // 大一号：各个数跟着乘 1.25
    var large = options
    large.size = .large
    let big = Layout(count: 30, hidden: 0, longestLabel: 300, height: 600, options: large)
    #expect(big.step == 70 && big.itemHeight == 120 && big.tabWidth == 38)
  }

  /// 只有色块：每条 30 × 24、间隔 6，不看标题
  @Test func chipsAreFixedSize() {
    var options = NoteDeckOptions()
    options.style = .chips
    let layout = Layout(count: 5, hidden: 3, longestLabel: 999, height: 900, options: options)
    #expect(layout.itemHeight == 24 && layout.step == 30 && layout.spacing == 6)
    #expect(layout.stackHeight == 4 * 30 + 24 && layout.strip(at: 0) == 30)
    #expect(layout.columnHeight == 217)  // 144 + 37 + 36
    options.size = .small
    let small = Layout(count: 2, hidden: 0, longestLabel: 0, height: 900, options: options)
    #expect(small.itemHeight == 20 && small.step == 25 && small.tabWidth == 26)
  }

  /// 药丸：一条便签一道色条，最多 14 道，再多的合成一道；条数少时不矮于 28
  @Test func pillGrowsWithTheNotes() {
    let metrics = NoteDeckMetrics(scale: 1)
    func height(_ count: Int) -> CGFloat { Layout.pillHeight(count: count, metrics: metrics) }
    #expect(height(1) == 28 && height(2) == 36)  // 12 + 10 = 22 不到 28；12 + 20 + 4
    #expect(height(6) == 92)  // 12 + 60 + 20
    #expect(height(14) == 12 + 140 + 52 && height(15) == 12 + 150 + 56)
    #expect(height(20) == height(15) && height(500) == height(15))
    // 16 + 78 + 25
    #expect(Layout.pillHeight(count: 6, metrics: NoteDeckMetrics(scale: 1.25)) == 119)
  }

  // MARK: 放哪块屏、哪条边

  /// 单屏：想放哪边就哪边；默认只放主显示器
  @Test func singleScreenTakesThePreferredEdge() {
    let screens = [Self.screen()]
    var options = NoteDeckOptions()
    #expect(Layout.placements(screens, options: options) == [.init(screen: 0, edge: .right)])
    options.edge = .left
    #expect(Layout.placements(screens, options: options) == [.init(screen: 0, edge: .left)])
    options.display = .all
    #expect(Layout.placements(screens, options: options) == [.init(screen: 0, edge: .left)])
    #expect(Layout.placements([], options: options).isEmpty)
  }

  /// 左右相接：相接的那条边不放、换到另一侧
  @Test func joinedEdgeMovesToTheOtherSide() {
    let screens = [Self.screen(), Self.screen("副屏", x: 1440)]
    #expect(
      Layout.isJoined(.right, of: 0, in: screens) && !Layout.isJoined(.left, of: 0, in: screens))
    #expect(
      Layout.isJoined(.left, of: 1, in: screens) && !Layout.isJoined(.right, of: 1, in: screens))
    var options = NoteDeckOptions()
    // 主屏的右边贴着副屏：换到左边
    #expect(Layout.placements(screens, options: options) == [.init(screen: 0, edge: .left)])
    options.display = .all
    #expect(
      Layout.placements(screens, options: options) == [
        .init(screen: 0, edge: .left), .init(screen: 1, edge: .right),
      ])
    options.edge = .left
    #expect(
      Layout.placements(screens, options: options) == [
        .init(screen: 0, edge: .left), .init(screen: 1, edge: .right),
      ])
    // 副屏在左边
    let mirrored = [Self.screen(), Self.screen("副屏", x: -1440)]
    options = NoteDeckOptions()
    #expect(Layout.placements(mirrored, options: options) == [.init(screen: 0, edge: .right)])
    options.edge = .left
    #expect(Layout.placements(mirrored, options: options) == [.init(screen: 0, edge: .right)])
  }

  /// 上下相接不碍左右两条边；斜着摆（纵向没有重叠）也不算相接；只错开一部分算
  @Test func stackedScreensKeepBothEdges() {
    let stacked = [Self.screen(), Self.screen("上面", y: 900)]
    var options = NoteDeckOptions()
    options.display = .all
    #expect(
      Layout.placements(stacked, options: options) == [
        .init(screen: 0, edge: .right), .init(screen: 1, edge: .right),
      ])
    let diagonal = [Self.screen(), Self.screen("右上", x: 1440, y: 900)]
    #expect(!Layout.isJoined(.right, of: 0, in: diagonal))
    let offset = [Self.screen(), Self.screen("错开", x: 1440, y: 600)]
    #expect(Layout.isJoined(.right, of: 0, in: offset) && Layout.isJoined(.left, of: 1, in: offset))
  }

  /// 三块屏一排：中间那块两侧都相接，不放
  @Test func middleOfThreeScreensGetsNothing() {
    let screens = [
      Self.screen(), Self.screen("左", x: -1440), Self.screen("右", x: 1440),
    ]
    var options = NoteDeckOptions()
    #expect(Layout.freeEdge(of: 0, in: screens, preferring: .right) == nil)
    #expect(Layout.placements(screens, options: options).isEmpty)
    options.display = .all
    #expect(
      Layout.placements(screens, options: options) == [
        .init(screen: 1, edge: .left), .init(screen: 2, edge: .right),
      ])
  }

  /// 指定某一块：按名字认；它没接着时退回主显示器
  @Test func chosenDisplayFallsBackToMain() {
    let screens = [Self.screen(), Self.screen("DELL", y: 900)]
    var options = NoteDeckOptions()
    options.display = .named("DELL")
    #expect(Layout.placements(screens, options: options) == [.init(screen: 1, edge: .right)])
    options.display = .named("拔掉的那块")
    #expect(Layout.placements(screens, options: options) == [.init(screen: 0, edge: .right)])
  }

  // MARK: frame

  /// 药丸那块窗口：贴着可见区的边，宽 = 感应范围，高 = 药丸高；纵向 0 = 最上、1 = 最下（各留 8）
  @Test func pillFrameHugsTheEdge() {
    let screen = Self.screen()  // 可见区 0…875
    var options = NoteDeckOptions()
    var frame = Layout.pillFrame(on: screen, edge: .right, count: 6, options: options)
    #expect(frame.width == 14 && frame.height == 92 && frame.maxX == 1440)
    // 顶 = 875 − 8 − 92 = 775，底 = 8：正中是 775 − 767 / 2，取整到整点
    #expect(frame.minY == 392)
    frame = Layout.pillFrame(on: screen, edge: .left, count: 6, options: options)
    #expect(frame.minX == 0 && frame.width == 14)
    options.position = 0
    #expect(Layout.pillFrame(on: screen, edge: .right, count: 6, options: options).maxY == 867)
    options.position = 1
    #expect(Layout.pillFrame(on: screen, edge: .right, count: 6, options: options).minY == 8)
    // 感应范围 44：窗口就那么宽；8 比药丸（12）还窄：窗口至少装得下药丸
    options.sense = 44
    #expect(Layout.pillFrame(on: screen, edge: .right, count: 1, options: options).width == 44)
    options.sense = 8
    #expect(Layout.pillFrame(on: screen, edge: .right, count: 1, options: options).width == 13)
    // 程序坞在右边时贴的是可见区的边，不压在程序坞上
    var docked = screen
    docked.visibleFrame.size.width = 1380
    #expect(
      Layout.pillFrame(on: docked, edge: .right, count: 1, options: NoteDeckOptions()).maxX == 1380)
  }

  /// 那叠的面板：贴边，宽 = 便签宽 + 间隔 8 + 标签列 30 + 余量 40，高 = 可见区高
  @Test func panelFrameFitsTheNoteAndTheColumn() {
    let screen = Self.screen()
    var options = NoteDeckOptions()
    var frame = Layout.panelFrame(on: screen, edge: .right, options: options)
    #expect(frame == CGRect(x: 1440 - 538, y: 0, width: 538, height: 875))
    frame = Layout.panelFrame(on: screen, edge: .left, options: options)
    #expect(frame.minX == 0 && frame.width == 538)
    options.noteSize = .extraLarge
    options.size = .large
    // 680 + 8 + 38 + 40
    #expect(Layout.panelFrame(on: screen, edge: .right, options: options).width == 766)
    // 屏幕比它还窄：不超出可见区
    #expect(
      Layout.panelFrame(on: Self.screen(width: 600), edge: .right, options: options).width == 600)
  }

  /// 标签列对着药丸的中线居中、夹在面板里；打开的便签对着它那张标签居中、夹在面板里
  @Test func columnAndNoteStayInsideThePanel() {
    #expect(Layout.columnTop(pillCenter: 437, columnHeight: 300, panelHeight: 875) == 287)
    #expect(Layout.columnTop(pillCenter: 30, columnHeight: 300, panelHeight: 875) == 12)
    #expect(Layout.columnTop(pillCenter: 860, columnHeight: 300, panelHeight: 875) == 563)
    #expect(Layout.columnTop(pillCenter: 100, columnHeight: 900, panelHeight: 875) == 12)
    #expect(Layout.noteTop(tabCenter: 400, noteHeight: 380, panelHeight: 875) == 210)
    #expect(Layout.noteTop(tabCenter: 50, noteHeight: 380, panelHeight: 875) == 10)
    #expect(Layout.noteTop(tabCenter: 860, noteHeight: 380, panelHeight: 875) == 485)
    let panel = CGSize(width: 538, height: 875)
    #expect(
      Layout.noteSize(CGSize(width: 460, height: 380), in: panel, tabWidth: 30)
        == CGSize(width: 460, height: 380))
    // 小屏幕：便签夹进面板（上下各留 10，旁边让出标签列和间隔）
    #expect(
      Layout.noteSize(
        CGSize(width: 680, height: 560), in: CGSize(width: 500, height: 400), tabWidth: 30)
        == CGSize(width: 462, height: 380))
  }

  /// 热区：标签列四周再往外 20 pt；预览卡出着时连它一起算
  @Test func hotZoneReachesTwentyPointsOut() {
    let panel = CGRect(x: 902, y: 0, width: 538, height: 875)
    var zone = Layout.hotZone(
      panel: panel, edge: .right, columnTop: 200, columnHeight: 300, tabWidth: 30,
      showsPreview: false)
    #expect(zone == CGRect(x: 1390, y: 355, width: 70, height: 340))
    #expect(zone.contains(CGPoint(x: 1395, y: 500)) && !zone.contains(CGPoint(x: 1385, y: 500)))
    #expect(zone.contains(CGPoint(x: 1430, y: 360)) && !zone.contains(CGPoint(x: 1430, y: 350)))
    zone = Layout.hotZone(
      panel: panel, edge: .right, columnTop: 200, columnHeight: 300, tabWidth: 30,
      showsPreview: true)
    #expect(zone.minX == 1440 - 30 - 10 - 220 - 20 && zone.contains(CGPoint(x: 1200, y: 500)))
    zone = Layout.hotZone(
      panel: CGRect(x: 0, y: 0, width: 538, height: 875), edge: .left, columnTop: 200,
      columnHeight: 300, tabWidth: 30, showsPreview: false)
    #expect(zone == CGRect(x: -20, y: 355, width: 70, height: 340))
  }

  /// 拖动排序：要拖过一格的 60% 才换位（50% 时手一抖会来回跳），两头夹住
  @Test func dragNeedsSixtyPercentOfASlot() {
    func target(_ offset: CGFloat, from: Int = 2) -> Int {
      Layout.dragTarget(from: from, offset: offset, step: 70, count: 5)
    }
    #expect(target(0) == 2 && target(35) == 2 && target(41) == 2)  // 50%、58% 都不换
    #expect(target(42) == 3 && target(69) == 3 && target(111) == 3)  // 60% 起
    #expect(target(112) == 4 && target(1000) == 4)
    #expect(target(-41) == 2 && target(-42) == 1 && target(-112) == 0 && target(-1000) == 0)
    #expect(target(1000, from: 0) == 4 && target(-10, from: 0) == 0)
    #expect(Layout.dragTarget(from: 1, offset: 50, step: 0, count: 5) == 1)
    #expect(Layout.dragTarget(from: 0, offset: 50, step: 70, count: 0) == 0)
  }

  /// 按住 ⌥ 拖药丸：贴鼠标所在那一半的边，高度跟着鼠标；相接的边换另一侧；只有「指定某一块」时能拖到别的屏
  @Test func draggingThePillPicksEdgeAndHeight() throws {
    let screens = [Self.screen(), Self.screen("副屏", x: 1440)]
    func drag(_ x: CGFloat, _ y: CGFloat, from: Int = 0, crosses: Bool = false) -> (
      placement: NoteDeckPlacement, position: Double
    )? {
      Layout.dragged(
        to: CGPoint(x: x, y: y), screens: screens, from: from, crossesScreens: crosses,
        pillHeight: 92)
    }
    // 主屏左半边：左边
    let result = try #require(drag(200, 400))
    #expect(result.placement == .init(screen: 0, edge: .left))
    // 可见区 0…875，药丸高 92：顶 = 775、底 = 8；鼠标对着药丸的中线
    #expect(abs(result.position - (775 - (400 - 46)) / 767) < 0.0001)
    // 主屏右半边：右边贴着副屏，换回左边
    #expect(try #require(drag(1300, 400)).placement == .init(screen: 0, edge: .left))
    // 拖到最上、最下：夹在 0…1
    #expect(try #require(drag(200, 2000)).position == 0)
    #expect(try #require(drag(200, -500)).position == 1)
    // 不许换屏时鼠标到了副屏也还在主屏；许换屏时跟过去（副屏右半边 = 右边，左半边贴着主屏 = 也是右边）
    #expect(try #require(drag(2600, 400)).placement == .init(screen: 0, edge: .left))
    #expect(
      try #require(drag(2600, 400, crosses: true)).placement == .init(screen: 1, edge: .right))
    #expect(
      try #require(drag(1500, 400, crosses: true)).placement == .init(screen: 1, edge: .right))
    #expect(drag(100, 100, from: 9) == nil)
    // 三块屏一排，从右边那块拖进中间那块（两侧都相接）：留在原来那块
    let row = [Self.screen(), Self.screen("左", x: -1440), Self.screen("右", x: 1440)]
    let stuck = try #require(
      Layout.dragged(
        to: CGPoint(x: 700, y: 400), screens: row, from: 2, crossesScreens: true, pillHeight: 92))
    #expect(stuck.placement == .init(screen: 2, edge: .right))
    #expect(
      Layout.dragged(
        to: CGPoint(x: 700, y: 400), screens: row, from: 0, crossesScreens: false, pillHeight: 92)
        == nil)
  }

  // MARK: 竖排标题

  /// 中日韩文字、全角符号、表情正着放；拉丁字母、数字、半角符号转着放
  @Test func uprightCharacters() {
    for character in "买菜あアㄅ한，。！（）「」ＡＢ１🙂✅❤️🇨🇳𠮷" {
      #expect(NoteDeckLabel.isUpright(character), "\(character)")
    }
    for character in "aZ09,.!()-_#é я" {
      #expect(!NoteDeckLabel.isUpright(character), "\(character)")
    }
  }

  /// 分段：正立的一字一格，别的整段在一起；空白挨着转着放的字就跟着那一段，夹在正立的字中间才是竖着的一格空
  @Test func labelRuns() {
    typealias Run = NoteDeckLabel.Run
    func upright(_ text: String) -> Run { Run(text: text, isUpright: true) }
    func rotated(_ text: String) -> Run { Run(text: text, isUpright: false) }
    #expect(NoteDeckLabel.runs(for: "周报") == [upright("周"), upright("报")])
    #expect(NoteDeckLabel.runs(for: "Groceries: milk") == [rotated("Groceries: milk")])
    #expect(
      NoteDeckLabel.runs(for: "买 milk 和蛋") == [
        upright("买"), rotated(" milk "), upright("和"), upright("蛋"),
      ])
    #expect(NoteDeckLabel.runs(for: "你 好") == [upright("你"), upright(" "), upright("好")])
    #expect(
      NoteDeckLabel.runs(for: "wifi密码2026") == [
        rotated("wifi"), upright("密"), upright("码"), rotated("2026"),
      ])
    #expect(NoteDeckLabel.runs(for: "🙂ok") == [upright("🙂"), rotated("ok")])
    #expect(NoteDeckLabel.runs(for: "").isEmpty)
  }

  /// 排不下从后面截、加「…」：跟在转着的那段后面一起转；前面是正立的字就单独一段（转过来是竖着的三个点）
  @Test func labelsTruncateWithAnEllipsis() {
    typealias Run = NoteDeckLabel.Run
    // 正立的一格 10，转着的一个字 6
    let advance: (Run) -> CGFloat = { $0.isUpright ? 10 : CGFloat($0.text.count) * 6 }
    func fitted(_ title: String, _ limit: CGFloat) -> [Run] {
      NoteDeckLabel.fitted(title, limit: limit, advance: advance)
    }
    func length(_ runs: [Run]) -> CGFloat { runs.reduce(0) { $0 + advance($1) } }
    #expect(fitted("周报", 20) == NoteDeckLabel.runs(for: "周报"))  // 正好放下：原样
    let cjk = fitted("一二三四五六七八", 46)
    #expect(cjk.map(\.text) == ["一", "二", "三", "四", "…"] && cjk.last?.isUpright == false)
    #expect(length(cjk) <= 46)
    let latin = fitted("Groceries and more", 50)
    #expect(latin == [Run(text: "Groceri…", isUpright: false)] && length(latin) <= 50)
    // 截在空格上：不留「词 …」中间的空格
    #expect(fitted("ab cd ef", 24) == [Run(text: "ab…", isUpright: false)])
    #expect(fitted("ab cd ef", 30) == [Run(text: "ab c…", isUpright: false)])
    let mixed = fitted("买 milk 和蛋 bread", 60)
    #expect(mixed.map(\.text) == ["买", " milk…"] && length(mixed) <= 60)
    // 转着的那段一个字都放不下：省略号接在前面正立的字后面
    #expect(fitted("买菜 milk", 26).map(\.text) == ["买", "菜", "…"])
    // 压得很短、连一个字加省略号都放不下：只留打头的那一截，不加省略号
    #expect(fitted("周报和别的", 14) == [Run(text: "周", isUpright: true)])
    #expect(fitted("Groceries", 11) == [Run(text: "G", isUpright: false)])
    #expect(fitted("周报和别的", 5) == [Run(text: "…", isUpright: false)])
    // 真字体量出来的：一段转着的字的长就是它横排的宽，正立的每格一个字高
    let metrics = NoteDeckMetrics(scale: 1)
    #expect(NoteDeckLabel.length("周报", metrics: metrics) == 2 * metrics.glyphAdvance)
    #expect(
      NoteDeckLabel.length("ab", metrics: metrics) < NoteDeckLabel.length("abab", metrics: metrics))
    let real = NoteDeckLabel.fitted("一条很长很长的标题，长到放不下", limit: 80) {
      NoteDeckLabel.advance(of: $0, metrics: metrics)
    }
    #expect(real.last?.text == "…")
    #expect(real.reduce(0) { $0 + NoteDeckLabel.advance(of: $1, metrics: metrics) } <= 80)
  }

  // MARK: 状态机

  private func state(_ events: NoteDeckState.Event...) -> NoteDeckState {
    var state = NoteDeckState()
    for event in events { state.handle(event) }
    return state
  }

  private static let enter = NoteDeckState.Event.pillEntered(optionDown: false, allowed: true)

  /// 静置 → 扇出：鼠标进药丸。按着 ⌥（要拖它）、这时不许扇出（截图框选、状态屏…）都不扇出
  @Test func pillEntryFansOut() {
    var state = NoteDeckState()
    #expect(state.phase == .rest && !state.showsAll && !state.isDragging && state.openID == nil)
    #expect(!state.handle(.pillEntered(optionDown: true, allowed: true)) && state.phase == .rest)
    #expect(!state.handle(.pillEntered(optionDown: false, allowed: false)) && state.phase == .rest)
    #expect(state.handle(Self.enter) && state.phase == .fanned)
    let again = state.handle(Self.enter)  // 已经扇着：没变
    #expect(!again && state.phase == .fanned)
  }

  /// 扇出 → 静置：离开热区、4 秒没动静、Esc / ⌘W（dismiss）；拖着标签排序时不收。鼠标的「关」（close）在只扇着时
  /// 没有东西可关
  @Test func fanCollapses() {
    var fanned = state(Self.enter)
    let closed = fanned.handle(.close)
    #expect(!closed && fanned.phase == .fanned)
    for event in [NoteDeckState.Event.left, .idle, .dismiss] {
      var state = state(Self.enter, .showAll)
      #expect(state.showsAll)
      #expect(state.handle(event) && state.phase == .rest && !state.showsAll, "\(event)")
    }
    var dragging = state(Self.enter, .dragBegan)
    #expect(dragging.isDragging)
    #expect(!dragging.handle(.left) && !dragging.handle(.idle) && dragging.phase == .fanned)
    #expect(!dragging.handle(.tab("a")) && dragging.phase == .fanned)  // 拖着时松手不算点
    #expect(dragging.handle(.dragEnded) && !dragging.isDragging)
    #expect(dragging.handle(.left) && dragging.phase == .rest)
  }

  /// 扇出 → 打开：点标签；打开着点另一张 = 换一条，点它自己 = 关（回到扇出）
  @Test func tabsOpenSwitchAndClose() {
    var state = state(Self.enter)
    #expect(state.handle(.tab("a")) && state.phase == .open("a") && state.openID == "a")
    #expect(state.handle(.tab("b")) && state.phase == .open("b"))
    #expect(state.handle(.tab("b")) && state.phase == .fanned && state.openID == nil)
    // 「+N」展开着打开、关掉：还是展开着
    state.handle(.showAll)
    state.handle(.tab("z"))
    #expect(state.handle(.close) && state.phase == .fanned && state.showsAll)
  }

  /// 打开的便签：用鼠标关（关闭钮、它的标签）、归档 / 删除之后回到扇出；用键盘关（Esc / ⌘W）连那一列一起收回
  /// （固定着的也是）；点别处回到静置，固定的不收；不按时间自己收
  @Test func openNoteClosesOnlyWhenAsked() {
    var state = state(Self.enter, .tab("a"))
    #expect(!state.handle(.idle) && !state.handle(.left) && state.phase == .open("a"))
    #expect(!state.handle(.clickedOutside(pinned: true)) && state.phase == .open("a"))
    #expect(!state.handle(Self.enter) && !state.handle(.dragBegan) && state.phase == .open("a"))
    #expect(state.handle(.close) && state.phase == .fanned)
    state.handle(.tab("a"))
    #expect(state.handle(.dismiss) && state.phase == .rest)
    state.handle(Self.enter)
    state.handle(.tab("a"))
    #expect(state.handle(.clickedOutside(pinned: false)) && state.phase == .rest)
    // 静置、扇出时点别处不关它的事
    let atRest = state.handle(.clickedOutside(pinned: false))
    #expect(!atRest && state.phase == .rest)
    state.handle(Self.enter)
    #expect(!state.handle(.clickedOutside(pinned: false)) && state.phase == .fanned)
  }

  /// 静置时除了鼠标进药丸和新建，别的事都不动它
  @Test func restIgnoresEverythingElse() {
    var state = NoteDeckState()
    let events: [NoteDeckState.Event] = [
      .left, .idle, .tab("a"), .showAll, .close, .dismiss, .clickedOutside(pinned: false),
      .dragBegan, .dragEnded, .suspend(closesOpen: true), .suspend(closesOpen: false),
      .yield(pinned: false), .yield(pinned: true),
    ]
    for event in events { #expect(!state.handle(event) && state == NoteDeckState(), "\(event)") }
  }

  /// 新建一条：从哪种样子都直接打开它
  @Test func creatingOpensFromAnywhere() {
    #expect(state(.created("n")).phase == .open("n"))
    #expect(state(Self.enter, .created("n")).phase == .open("n"))
    #expect(state(Self.enter, .tab("a"), .created("n")).phase == .open("n"))
    let dragging = state(Self.enter, .dragBegan, .created("n"))
    #expect(dragging.phase == .open("n") && !dragging.isDragging)
  }

  /// 叫停：扇出的收起；打开的要不要收由调用方说。让给别的屏：扇着的收，打开的只收没固定的（固定的不收）
  @Test func suspendAndYield() {
    #expect(state(Self.enter, .suspend(closesOpen: false)).phase == .rest)
    #expect(state(Self.enter, .dragBegan, .suspend(closesOpen: false)) == NoteDeckState())
    #expect(state(Self.enter, .tab("a"), .suspend(closesOpen: false)).phase == .open("a"))
    #expect(state(Self.enter, .tab("a"), .suspend(closesOpen: true)).phase == .rest)
    #expect(state(Self.enter, .yield(pinned: false)).phase == .rest)
    #expect(state(Self.enter, .yield(pinned: true)).phase == .rest)
    #expect(state(Self.enter, .tab("a"), .yield(pinned: false)).phase == .rest)
    #expect(state(Self.enter, .tab("a"), .yield(pinned: true)).phase == .open("a"))
  }

  /// 「+N」：扇着、便签开着时都能点（列出全部，便签留着）；收回时跟着收起来
  @Test func showAllWorksWhileOpen() {
    var state = state(Self.enter, .tab("a"))
    #expect(state.handle(.showAll) && state.showsAll && state.phase == .open("a"))
    let again = state.handle(.showAll)
    #expect(!again)
    #expect(state.handle(.close) && state.showsAll && state.phase == .fanned)
    #expect(state.handle(.left) && !state.showsAll)
  }

  /// 「一直展开」：没有静置，收回就是回到扇出那一列（「+N」收起来）；关掉这个设置后照常收
  @Test func alwaysFannedHasNoRest() {
    var state = NoteDeckState()
    state.setAlwaysFanned(true)
    #expect(state.phase == .fanned && state.alwaysFanned)
    state.handle(.showAll)
    #expect(state.handle(.left) && state.phase == .fanned && !state.showsAll)
    #expect(!state.handle(.idle) && !state.handle(.close) && state.phase == .fanned)
    state.handle(.tab("a"))
    #expect(state.handle(.clickedOutside(pinned: false)) && state.phase == .fanned)
    state.handle(.tab("a"))
    #expect(state.handle(.suspend(closesOpen: true)) && state.phase == .fanned)
    state.handle(.tab("a"))
    #expect(state.handle(.yield(pinned: false)) && state.phase == .fanned)
    // 一直展开时用键盘关：没有静置，回到那一列
    state.handle(.tab("a"))
    #expect(state.handle(.dismiss) && state.phase == .fanned)
    state.setAlwaysFanned(false)
    #expect(state.phase == .fanned)  // 还扇着，等鼠标离开 / 没动静
    #expect(state.handle(.idle) && state.phase == .rest)
    // 打开着便签时开关这个设置：便签不动
    var open = self.state(Self.enter, .tab("a"))
    open.setAlwaysFanned(true)
    #expect(open.phase == .open("a"))
  }

  // MARK: 什么时候有、第一次的提示

  /// 总开关开着，而且至少有一条没归档没删的便签
  @Test func shownOnlyWithNotesAndTheSwitch() {
    #expect(NoteEdge.isShown(enabled: true, count: 1) && NoteEdge.isShown(enabled: true, count: 99))
    #expect(!NoteEdge.isShown(enabled: true, count: 0))
    #expect(!NoteEdge.isShown(enabled: false, count: 5))
  }

  /// 每台电脑只说一次（记在偏好里）；左边时说左边
  @Test func hintIsTakenOnce() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(NoteEdge.takesHint(defaults))
    #expect(!NoteEdge.takesHint(defaults) && !NoteEdge.takesHint(defaults))
    #expect(defaults.bool(forKey: Prefs.notesDeckHintShown))
    #expect(NoteEdge.hint(.right).title == "便签在屏幕右边缘")
    #expect(NoteEdge.hint(.left).title == "便签在屏幕左边缘")
    #expect(NoteEdge.hint(.right).detail == "鼠标靠过去就能看到")
  }

  // MARK: 界面读的状态

  /// 一次最多 5 张，其余收进「+N」；点了「+N」是全部；排法跟着走
  @Test func tabsShowFiveThenAll() throws {
    let (model, _, ids) = try make((1...8).map { "便签 \($0)" })
    #expect(model.tabs.map(\.id) == Array(ids.prefix(5)))
    #expect(model.layout.count == 5 && model.layout.hidden == 3)
    model.send(Self.enter)
    model.send(.showAll)
    #expect(model.tabs.map(\.id) == ids && model.layout.hidden == 0 && model.layout.count == 8)
    // 鼠标走了：收回，「+N」也收起来
    model.send(.left)
    #expect(model.tabs.count == 5)
    // 没超过 5 条：没有「+N」
    #expect(try make(["一", "二"]).model.layout.hidden == 0)
  }

  /// 点标签打开、再点它关；状态变了会报给窗口那边
  @Test func tappingTabsOpensAndCloses() throws {
    let (model, _, ids) = try make(["一", "二", "三"])
    var changes: [NoteDeckState.Phase] = []
    model.onChange = { _, new in changes.append(new.phase) }
    model.send(Self.enter)
    model.tapTab(ids[1])
    #expect(model.current?.id == ids[1])
    model.tapTab(ids[2])
    model.tapTab(ids[2])
    #expect(model.current == nil && model.state.phase == .fanned)
    #expect(changes == [.fanned, .open(ids[1]), .open(ids[2]), .fanned])
    // 便签对着它自己那张标签摆；它不在这一列里就对着药丸
    model.tapTab(ids[0])
    let layout = model.layout
    #expect(
      model.noteTop(layout)
        == Layout.noteTop(
          tabCenter: model.columnTop(layout) + layout.tabCenter(0), noteHeight: 380,
          panelHeight: 875))
    #expect(model.noteSize(layout) == CGSize(width: 460, height: 380))
  }

  /// 新建：建一条排最前并打开；最前面那条还是空白的就用它
  @Test func creatingOpensAFreshNote() throws {
    let (model, store, _) = try make(["旧的"])
    model.create()
    let fresh = try #require(model.current)
    #expect(store.active.count == 2 && store.active.first?.id == fresh.id && fresh.body.isEmpty)
    model.send(.close)
    model.create()
    #expect(store.active.count == 2 && model.current?.id == fresh.id)
    model.setBody("写了字", of: fresh.id)
    model.setTitle("标题", of: fresh.id)
    #expect(store.note(fresh.id)?.body == "写了字" && store.note(fresh.id)?.title == "标题")
    model.send(.close)
    model.create()
    #expect(store.active.count == 3 && model.current?.id != fresh.id)
  }

  /// 固定、换色不关便签；归档、删除之后回到扇出（删除进「最近删除」）；「在全部便签里打开」把编号交出去
  @Test func noteActions() throws {
    let (model, store, ids) = try make(["一", "二", "三"])
    var shown: [String] = []
    model.showInWindow = { shown.append($0) }
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.togglePinned()
    #expect(store.note(ids[0])?.isPinned == true && model.current?.id == ids[0])
    let color = try #require(store.note(ids[0])?.color)
    model.cycleColor()
    #expect(store.note(ids[0])?.color == NotesWindowModel.nextColor(after: color))
    model.setColor(5)
    #expect(store.note(ids[0])?.color == 5 && model.current != nil)
    model.archive()
    #expect(store.archived.map(\.id) == [ids[0]] && model.state.phase == .fanned)
    model.tapTab(ids[1])
    model.delete()
    #expect(store.trashed.map(\.id) == [ids[1]] && model.state.phase == .fanned)
    model.tapTab(ids[2])
    model.openInWindow()
    #expect(shown == [ids[2]] && model.state.phase == .fanned)
    // 没有打开的便签时这些都不做事
    model.togglePinned()
    model.archive()
    model.delete()
    #expect(store.active.map(\.id) == [ids[2]])
  }

  /// 打开着的那条被别处（全部便签窗口）删了、归档了：关掉
  @Test func reconcileClosesANoteThatWentAway() throws {
    let (model, store, ids) = try make(["一", "二"])
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.reconcile()
    #expect(model.current?.id == ids[0])
    store.delete(ids[0])
    #expect(model.current == nil)
    model.reconcile()
    #expect(model.state.phase == .fanned)
    model.tapTab(ids[1])
    store.setArchived(true, of: ids[1])
    model.reconcile()
    #expect(model.state.phase == .fanned)
  }

  /// 操作菜单：九项四节（2026-10-15 加了「便签设置…」、第 8 批之后加了「导出为 Markdown…」），名字和全部便签窗口同一份；
  /// 颜色是子列表；Esc 先退菜单再关便签
  @Test func actionMenu() throws {
    let (model, store, ids) = try make(["一", "二"])
    var menuEvents: [Bool] = []
    model.onMenu = { menuEvents.append($0) }
    model.toggleMenu()
    #expect(model.menu == nil)  // 没有打开的便签：不开
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.toggleMenu()
    #expect(model.menu == .init() && menuEvents == [true])
    #expect(
      model.menuItems.map(\.title) == [
        "固定", "颜色", "任务", "归档", "删除", "浮在屏幕上", "在「全部便签」里打开",
        "导出为 Markdown…", "便签设置…",
      ])
    #expect(model.menuItems.map(\.section) == [0, 0, 0, 1, 1, 2, 2, 2, 3])
    #expect(
      model.menuItems.map(\.isDestructive) == [
        false, false, false, false, true, false, false, false, false,
      ])
    #expect(model.menuItems[2].shortcut == "⌘T")
    #expect(model.menuItems[1].submenu?.count == Note.colorCount + 1, "8 种 +「其他颜色…」")
    // 鼠标移到哪一行，选中跟到哪一行（越界的不理）；再把它挪回第一行，下面的 ↓ 照旧从头走
    model.menuHover(4)
    #expect(model.menu?.selection == 4)
    model.menuHover(99)
    #expect(model.menu?.selection == 4)
    model.menuHover(0)
    #expect(model.menu?.selection == 0)
    // ↓ 到「颜色」，→ 进去：选中的是现在的颜色
    #expect(try model.handleMenuKey(key(kVK_DownArrow)))
    #expect(try model.handleMenuKey(key(kVK_RightArrow)))
    let color = try #require(store.note(ids[0])?.color)
    #expect(model.menu?.inColors == true && model.menu?.selection == color)
    #expect(
      model.menuItems.map(\.title) == NotePaper.all.map(\.name) + [NotePaper.otherColorTitle])
    #expect(model.menuItems[color].isChecked == true)
    // ↓ ↩：换成下一种，菜单关掉
    #expect(try model.handleMenuKey(key(kVK_DownArrow)))
    #expect(try model.handleMenuKey(key(kVK_Return)))
    #expect(store.note(ids[0])?.color == (color + 1) % Note.colorCount && model.menu == nil)
    #expect(menuEvents == [true, false])
    // 颜色那一级 ← / Esc 回上一级（停在「颜色」那一行），再 Esc 关菜单，再 Esc 关便签
    model.toggleMenu()
    model.run(model.menuItems[1])
    #expect(try model.handleMenuKey(key(kVK_LeftArrow)))
    #expect(model.menu == .init(inColors: false, selection: 1))
    model.run(model.menuItems[1])
    model.cancel()
    #expect(model.menu?.inColors == false)
    model.cancel()
    #expect(model.menu == nil && model.current != nil)
    // 用键盘关的：连那一列一起收回
    model.cancel()
    #expect(model.current == nil && model.state.phase == .rest)
    // ↑ 从第一行绕到最后一行；固定之后第一行叫「取消固定」
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.toggleMenu()
    #expect(try model.handleMenuKey(key(kVK_UpArrow)))
    #expect(model.menu?.selection == 8)
    #expect(try model.handleMenuKey(key(kVK_DownArrow)) && model.menu?.selection == 0)
    #expect(try model.handleMenuKey(key(kVK_Return)))
    #expect(store.note(ids[0])?.isPinned == true)
    model.toggleMenu()
    #expect(model.menuItems.first?.title == "取消固定")
    // 菜单开着时别的键吞掉；换一条便签菜单跟着关
    #expect(try model.handleMenuKey(key(kVK_ANSI_A)))
    model.tapTab(ids[1])
    #expect(model.menu == nil)
    #expect(try !model.handleMenuKey(key(kVK_DownArrow)))
    // 从纸色圆点点开：直接是颜色那一级，Esc 直接关
    model.toggleMenu(fromDot: true)
    #expect(model.menu?.inColors == true && model.menu?.fromDot == true)
    model.cancel()
    #expect(model.menu == nil && model.current?.id == ids[1])
  }

  /// 面板的 ⌘ 组合键：⌘W 关（用键盘关的：便签连那一列一起收回）；便签开着时 ⌘P ⌘K ⌘. ⌘T ⌘F ⇧⌘A；⌘⌫ 不接（归输入框）；
  /// ⌘Z 不在这里（面板直接动焦点所在输入框的撤销栈）
  @Test func keyEquivalents() throws {
    let (model, store, ids) = try make(["一", "二"])
    func press(_ code: Int, _ flags: NSEvent.ModifierFlags = .command) throws -> Bool {
      model.handleKeyEquivalent(try key(code, flags))
    }
    #expect(try !press(kVK_ANSI_W) && !press(kVK_ANSI_P))  // 静置：都不接
    model.send(Self.enter)
    #expect(try !press(kVK_ANSI_P) && !press(kVK_ANSI_K))  // 没有打开的便签
    model.tapTab(ids[0])
    #expect(try press(kVK_ANSI_P, [.command, .capsLock]) && store.note(ids[0])?.isPinned == true)
    let color = try #require(store.note(ids[0])?.color)
    #expect(try press(kVK_ANSI_Period))
    #expect(store.note(ids[0])?.color == NotesWindowModel.nextColor(after: color))
    #expect(try press(kVK_ANSI_K) && model.menu != nil)
    #expect(try press(kVK_ANSI_K) && model.menu == nil)
    #expect(try !press(kVK_Delete) && store.trashed.isEmpty)  // ⌘⌫ 是输入框的「删到行首」
    #expect(try !press(kVK_ANSI_A) && !press(kVK_ANSI_P, [.command, .option]))
    #expect(try !press(kVK_ANSI_P, []))
    // ⌘T 任务、⌘F 便签内查找：交给开着的那条的正文编辑器（这里没有窗口，只看交没交过去、焦点要没要回正文）
    var asked = 0
    var focused = 0
    model.withEditor = { _ in asked += 1 }
    model.focusBody = { focused += 1 }
    #expect(try press(kVK_ANSI_T) && asked == 1 && focused == 1)
    #expect(try press(kVK_ANSI_F) && asked == 2 && focused == 1)
    #expect(try !press(kVK_ANSI_T, [.command, .shift]) && !press(kVK_ANSI_Z))
    #expect(try press(kVK_ANSI_K) && press(kVK_ANSI_W))  // 菜单开着按 ⌘W：连便签、那一列一起收回
    #expect(model.menu == nil && model.state.phase == .rest)
    #expect(try !press(kVK_ANSI_W))
    // 只扇着时 ⌘W 也收回
    model.send(Self.enter)
    #expect(try press(kVK_ANSI_W) && model.state.phase == .rest)
    model.send(Self.enter)
    model.tapTab(ids[1])
    #expect(try press(kVK_ANSI_A, [.command, .shift]))
    #expect(store.archived.map(\.id) == [ids[1]] && model.state.phase == .fanned)
  }

  /// 拖动排序：挪过 5 pt 才算拖；过了一格的 60% 换位，松手落到仓库里；没挪开的是点了一下
  @Test func draggingATabReorders() throws {
    let (model, store, ids) = try make(["一", "二", "三", "四"])
    model.send(Self.enter)
    let step = model.layout.step
    model.dragChanged(ids[0], by: 3)
    #expect(model.drag == nil && !model.state.isDragging)
    model.dragEnded(ids[0], by: 3)
    #expect(model.current?.id == ids[0])  // 点了一下：打开
    model.send(.close)
    model.dragChanged(ids[0], by: step * 0.5)
    #expect(model.drag == .init(id: ids[0], from: 0, offset: step * 0.5, target: 0))
    #expect(model.state.isDragging)
    model.dragChanged(ids[0], by: step * 1.7)
    #expect(model.drag?.target == 2)
    model.send(.idle)  // 拖着时不收
    #expect(model.state.phase == .fanned)
    model.dragEnded(ids[0], by: step * 1.7)
    #expect(model.drag == nil && !model.state.isDragging && model.current == nil)
    #expect(store.active.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
    // 拖回原处：不动仓库
    let revision = store.note(ids[1])?.revision
    model.dragChanged(ids[1], by: 20)
    model.dragEnded(ids[1], by: 20)
    #expect(store.active.first?.id == ids[1] && store.note(ids[1])?.revision == revision)
    // 便签打开着时不拖
    model.tapTab(ids[3])
    model.dragChanged(ids[1], by: 200)
    #expect(model.drag == nil)
  }

  /// 鼠标停在标签上：记下是哪张；预览卡只在扇出时出，状态一变就收；打到上限的标记换一条就清
  @Test func hoverAndOverflowFlags() throws {
    let (model, _, ids) = try make(["一", "二"])
    model.hover(ids[0], true)
    #expect(model.hovered == nil)  // 没扇出：不理
    model.send(Self.enter)
    model.hover(ids[0], true)
    #expect(model.hovered == ids[0])
    model.setPreview(ids[0])
    #expect(model.previewNote?.id == ids[0])
    model.hover(ids[0], false)
    #expect(model.hovered == nil)
    model.tapTab(ids[1])
    #expect(model.preview == nil && model.hovered == nil)
    model.overflowed()
    #expect(model.isOverLimit)
    model.setBody("又打了一个字", of: ids[1])
    #expect(!model.isOverLimit)
    model.overflowed()
    model.tapTab(ids[0])
    #expect(!model.isOverLimit)
  }

  /// 「一直展开」这个设置一变，状态跟着变、报给窗口那边
  @Test func optionsDriveAlwaysFanned() throws {
    let (model, _, _) = try make(["一"])
    var changes = 0
    model.onChange = { _, _ in changes += 1 }
    var options = NoteDeckOptions()
    options.noteSize = .large
    model.options = options
    #expect(changes == 0 && model.state.phase == .rest)
    options.alwaysFanned = true
    model.options = options
    #expect(changes == 1 && model.state.phase == .fanned)
    options.alwaysFanned = false
    model.options = options
    #expect(changes == 2 && model.state.phase == .fanned && !model.state.alwaysFanned)
  }

  /// 全部便签窗口「在这里打开某一条」：换到它所在的视图、清掉搜索词、选中
  @Test func notesWindowRevealsANote() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let first = store.create(body: "一").id
    let second = store.create(body: "二").id
    store.setArchived(true, of: first)
    let model = NotesWindowModel(store: store)
    model.query = "找不到"
    model.reveal(first)
    #expect(model.scope == .archive && model.query.isEmpty && model.selection == first)
    model.reveal(second)
    #expect(model.scope == .all && model.current?.id == second)
    store.delete(second)
    model.reveal(second)
    #expect(model.scope == .trash && model.selection == second)
    model.reveal("没有这条")
    #expect(model.selection == second)
  }

  // MARK: 两块窗口

  /// 那叠的面板（第五个例外）：无边框、不激活、能当 key、浮动层级；截图的冻结帧里留着（可见时），录屏的白名单里有
  @Test func deckPanelCountsAsContent() throws {
    let (model, _, _) = try make(["一"])
    let panel = NoteDeckPanel(
      frame: CGRect(x: -30000, y: -30000, width: 538, height: 875), model: model, onPointer: {})
    #expect(panel.styleMask == [.borderless, .nonactivatingPanel])
    #expect(panel.canBecomeKey && !panel.canBecomeMain && panel.becomesKeyOnlyIfNeeded)
    #expect(panel.level == .floating && !panel.isOpaque && !panel.hasShadow)
    #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
    // 透明的地方要点穿：不能设过 ignoresMouseEvents
    #expect(!panel.ignoresMouseEvents && !panel.hidesOnDeactivate && !panel.isVisible)
    let name = String(describing: type(of: panel))
    #expect(name == "NoteDeckPanel")
    func own(visible: Bool, level: NSWindow.Level = .floating) -> ScreenCapture.OwnWindow {
      ScreenCapture.OwnWindow(
        id: 7, className: name, level: level.rawValue, isVisible: visible, alpha: 1)
    }
    #expect(ScreenCapture.keptOwnWindows([own(visible: true)]) == [7])
    #expect(ScreenCapture.keptOwnWindows([own(visible: false)]).isEmpty)  // 收起着的不在画面里
    #expect(ScreenCapture.recordedOwnWindows([own(visible: true)]) == [7])
    #expect(ScreenCapture.recordedOwnWindows([own(visible: false)]) == [7])  // 开录后露出来照样录
    #expect(ScreenCapture.recordedOwnWindows([own(visible: true, level: .statusBar)]).isEmpty)
  }

  /// 截图的悬停列表里，那叠的面板只算里面真有东西的那一块（打开的便签 / 标签列），不是整块透明的窗口；
  /// 那一块在屏幕上的位置按面板、边、便签的大小算
  @Test func captureSeesOnlyTheDeckContent() {
    let panel = CGRect(x: 902, y: 0, width: 538, height: 875)
    let note = Layout.noteFrame(
      panel: panel, edge: .right, top: 100, size: CGSize(width: 460, height: 380), tabWidth: 30)
    #expect(note == CGRect(x: 1440 - 38 - 460, y: 875 - 100 - 380, width: 460, height: 380))
    let leftNote = Layout.noteFrame(
      panel: CGRect(x: 0, y: 0, width: 538, height: 875), edge: .left, top: 100,
      size: CGSize(width: 460, height: 380), tabWidth: 30)
    #expect(leftNote.minX == 38 && leftNote.maxY == 775)
    let column = Layout.columnFrame(panel: panel, edge: .right, top: 200, height: 300, width: 30)
    #expect(column == CGRect(x: 1410, y: 375, width: 30, height: 300))
    #expect(
      Layout.columnFrame(
        panel: CGRect(x: 0, y: 0, width: 538, height: 875), edge: .left, top: 200, height: 300,
        width: 30
      ).minX == 0)

    // 窗口表里那叠的面板是整块（538 × 875）；给了 contents 就换成里面那一块，Z 序不变
    let own: pid_t = 77
    func window(_ rect: CGRect, pid: pid_t, id: Int) -> [String: Any] {
      [
        kCGWindowLayer as String: 3, kCGWindowAlpha as String: 1.0,
        kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
        kCGWindowOwnerPID as String: Int32(pid), kCGWindowNumber as String: id,
      ]
    }
    let info = [
      window(CGRect(x: 902, y: 25, width: 538, height: 875), pid: own, id: 5),
      window(CGRect(x: 0, y: 100, width: 1440, height: 700), pid: 1, id: 6),
    ]
    let whole = ScreenCapture.windowFrames(info, ownPID: own, keeping: [5], primaryHeight: 900)
    #expect(whole.first == panel)
    let frames = ScreenCapture.windowFrames(
      info, ownPID: own, keeping: [5], primaryHeight: 900, contents: [5: note])
    #expect(frames == [note, CGRect(x: 0, y: 100, width: 1440, height: 700)])
    // 里面那一块小得选不中（或者没有）：这扇窗口不进列表；别的进程的窗口不看 contents
    let none = ScreenCapture.windowFrames(
      info, ownPID: own, keeping: [5], primaryHeight: 900, contents: [5: .zero, 6: note])
    #expect(none == [CGRect(x: 0, y: 100, width: 1440, height: 700)])
  }

  /// 边上的药丸：状态栏层级的普通 NSPanel——截图的冻结帧、录屏的白名单都不收它；永不当 key；
  /// 默认不盖在全屏 App 上，设置里开了才加 fullScreenAuxiliary
  @Test func pillStaysOutOfCaptures() {
    let pill = NoteDeckPill()
    var options = NoteDeckOptions()
    let frame = CGRect(x: -30000, y: -30000, width: 14, height: 92)
    pill.update(frame: frame, edge: .right, colors: [0, 1, 2, 3, 4, 5], options: options)
    let panel = pill.panel
    #expect(String(describing: type(of: panel)) == "NSPanel" && panel.level == .statusBar)
    #expect(panel.styleMask == [.borderless, .nonactivatingPanel])
    #expect(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hasShadow && !panel.isOpaque)
    #expect(!panel.ignoresMouseEvents && !panel.isVisible && panel.frame == frame)
    #expect(
      panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .ignoresCycle]))
    #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
    let own = ScreenCapture.OwnWindow(
      id: 9, className: "NSPanel", level: panel.level.rawValue, isVisible: true, alpha: 1)
    #expect(ScreenCapture.keptOwnWindows([own]).isEmpty)
    #expect(ScreenCapture.recordedOwnWindows([own]).isEmpty)
    // 一层 HUD 底 + 一道道色条，都是图层；旁白读得出是什么、有几条
    let view = panel.contentView
    #expect(view?.layer?.sublayers?.count == 1)
    #expect(view?.layer?.sublayers?.first?.sublayers?.count { $0.name == "dash" } == 6)
    #expect(view?.accessibilityLabel() == "便签，6 条" && view?.accessibilityRole() == .button)
    options.overFullScreen = true
    pill.update(frame: frame, edge: .left, colors: Array(repeating: 0, count: 20), options: options)
    #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    // 20 条：14 道色条 + 一道灰的
    #expect(view?.layer?.sublayers?.first?.sublayers?.count { $0.name == "dash" } == 15)
    #expect(view?.accessibilityLabel() == "便签，20 条")
  }

  /// 打开便签时点哪算「点别处」：那叠自己（面板、药丸）不算，Kitty 的浮层不算，截图框选中都不算
  @Test func whatCountsAsClickingElsewhere() throws {
    let (model, _, _) = try make(["一"])
    let offscreen = CGRect(x: -30000, y: -30000, width: 200, height: 100)
    let panel = NoteDeckPanel(frame: offscreen, model: model, onPointer: {})
    let pill = NoteDeckPill()
    let overlay = OverlayPanel(
      size: offscreen.size, autoHide: .clickOutside, isPinned: { false }, content: Color.clear)
    let other = NSWindow(
      contentRect: offscreen, styleMask: [.borderless], backing: .buffered, defer: true)
    let own: [NSWindow?] = [panel, pill.panel]
    func outside(_ window: NSWindow?, selecting: Bool = false) -> Bool {
      NoteDeck.isOutside(window, own: own, isSelectingRegion: selecting)
    }
    #expect(!outside(panel) && !outside(pill.panel) && !outside(overlay))
    #expect(outside(other) && outside(nil))
    #expect(!outside(other, selecting: true) && !outside(nil, selecting: true))
    #expect(NoteDeck.isOutside(nil, own: [nil, nil], isSelectingRegion: false))
  }

  /// F6：「插入图片…」的选文件面板在本进程里：面板里点一下不算「点别处」
  /// （算的话没固定的便签会被收起、正文框被拆掉，图插不进去、键盘也没还回来）
  @Test func savePanelsAreNotClickingElsewhere() throws {
    let (model, _, _) = try make(["一"])
    let offscreen = CGRect(x: -30000, y: -30000, width: 200, height: 100)
    let panel = NoteDeckPanel(frame: offscreen, model: model, onPointer: {})
    let own: [NSWindow?] = [panel, nil]
    #expect(!NoteDeck.isOutside(NSSavePanel(), own: own, isSelectingRegion: false))
    // 文件面板里的内容是另一个进程画的，点它只有 global 监听收得到（2026-10-18 真机：没固定的便签被收起）：
    // 点在本进程开着的文件面板框里不算点别处，框外照算
    let panelFrame = CGRect(x: 400, y: 200, width: 600, height: 400)
    #expect(NoteDeck.isInsideFilePanel(CGPoint(x: 500, y: 300), frames: [panelFrame]))
    #expect(!NoteDeck.isInsideFilePanel(CGPoint(x: 100, y: 300), frames: [panelFrame]))
    #expect(!NoteDeck.isInsideFilePanel(CGPoint(x: 500, y: 300), frames: []))
    #expect(!NoteDeck.isOutside(NSOpenPanel(), own: own, isSelectingRegion: false))
    let other = NSWindow(
      contentRect: offscreen, styleMask: [.borderless], backing: .buffered, defer: true)
    #expect(NoteDeck.isOutside(other, own: own, isSelectingRegion: false))
  }

  /// F9：正文里插图被拒 / 存图没成时那句话经 model 手里的岛说出来（标题 + 说明两行）。
  /// 原来 NoteBodyField 用 `@Environment(Island.self)`，三个宿主都没注入 → 只剩一声提示音
  @Test func imageProblemsReachTheIsland() throws {
    let (model, _, _) = try make(["一"])
    let island = Island(
      showing: .init(
        title: "占位", detail: nil, tone: .info, symbol: "note.text", leading: .tone))
    model.island = island
    model.imageProblem("图片太大了", "单张最多 20 MB")
    #expect(island.content?.title == "图片太大了")
    #expect(island.content?.detail == "单张最多 20 MB")
    #expect(island.content?.tone == .warning)
  }

  /// 扇出才建面板；被叫停（截图、状态屏开始）当场收走，不等动画；这块屏不放了，两块窗口都放掉。
  /// 窗口摆在离所有屏幕很远的地方（先确认），只露出来、不当 key
  @Test func fanningBuildsThePanelAndSuspendHidesItAtOnce() throws {
    let far = NoteDeckScreen(
      name: "测试", frame: CGRect(x: -40000, y: -40000, width: 1440, height: 900),
      visibleFrame: CGRect(x: -40000, y: -40000, width: 1440, height: 875))
    let options = NoteDeckOptions()
    let frames = [
      Layout.pillFrame(on: far, edge: .right, count: 2, options: options),
      Layout.panelFrame(on: far, edge: .right, options: options),
    ]
    for frame in frames {
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
    }
    let store = try NoteStore(db: Database(path: ":memory:"))
    store.create(body: "一")
    store.create(body: "二")
    let deck = NoteDeck(store: store, island: nil)
    var expanded = 0
    deck.onExpand = { expanded += 1 }
    #expect(deck.pill == nil && deck.panel == nil)
    deck.place(on: far, edge: .right, options: options)
    let pill = try #require(deck.pill)
    #expect(pill.panel.frame == frames[0] && pill.panel.isVisible && deck.panel == nil)
    #expect(
      deck.model.panelSize == frames[1].size
        && deck.model.pillCenter == frames[1].maxY - frames[0].midY)
    // 这时不许扇出：鼠标进药丸也不建面板
    deck.canFan = { false }
    pill.onEnter(false)
    #expect(deck.panel == nil && deck.model.state.phase == .rest)
    // 按着 ⌥：也不扇出
    deck.canFan = { true }
    pill.onEnter(true)
    #expect(deck.panel == nil)
    pill.onEnter(false)
    let panel = try #require(deck.panel)
    #expect(deck.model.state.phase == .fanned && expanded == 1)
    #expect(panel.isVisible && !panel.isKeyWindow && panel.frame == frames[1])
    #expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(panel.frame) })
    // 叫停：扇着的当场收走
    deck.suspend(.keepsOpen)
    #expect(deck.model.state.phase == .rest && !panel.isVisible && !deck.model.isRevealed)
    // 「一直展开」：没有药丸，面板一直在
    var always = options
    always.alwaysFanned = true
    deck.place(on: far, edge: .right, options: always)
    #expect(deck.pill == nil && deck.model.state.phase == .fanned && deck.panel?.isVisible == true)
    #expect(deck.panel?.collectionBehavior.contains(.fullScreenAuxiliary) == false)
    deck.suspend(.all)
    #expect(deck.panel?.isVisible == true)
    deck.close()
    #expect(deck.pill == nil && deck.panel == nil && !panel.isVisible)
  }

  /// 界面上用到的符号在这台系统上都有（名字写错了图标就是空的）
  @Test func symbolsExist() {
    for name in [
      "pin", "pin.fill", "pin.slash", "ellipsis", "xmark", "plus", "paintpalette", "archivebox",
      "trash", "trash.circle.fill", "note.text", "note.text.badge.plus", "gearshape",
      "sidebar.right", "sidebar.left", "checklist", "checkmark.square", "checkmark.square.fill",
      "macwindow.on.rectangle", "xmark.rectangle",
    ] {
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }

  // MARK: 评审后的一轮（2026-10-13）

  private static let offscreen = CGRect(x: -30000, y: -30000, width: 538, height: 875)

  /// 一块摆在离所有屏幕很远的地方的那叠（先确认真在屏幕外）。**永远不当 key**（takesKeyboard: false——屏外的面板
  /// 一当 key，用户正在用的那个 App 就丢了键盘）；要打开便签的测试先把便签固定上：便签开着时装着全局的鼠标监听，
  /// 用户这时在别处点一下，没固定的会被当成「点别处」收掉
  private func offscreenDeck(_ bodies: [String], lingering: Duration = .seconds(2)) throws
    -> NoteDeck
  {
    let far = NoteDeckScreen(
      name: "测试", frame: CGRect(x: -40000, y: -40000, width: 1440, height: 900),
      visibleFrame: CGRect(x: -40000, y: -40000, width: 1440, height: 875))
    let options = NoteDeckOptions()
    for frame in [
      Layout.pillFrame(on: far, edge: .right, count: bodies.count, options: options),
      Layout.panelFrame(on: far, edge: .right, options: options),
    ] {
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
    }
    let store = try NoteStore(db: Database(path: ":memory:"))
    for body in bodies.reversed() { store.create(body: body) }
    let deck = NoteDeck(store: store, island: nil, lingering: lingering, takesKeyboard: false)
    deck.place(on: far, edge: .right, options: options)
    return deck
  }

  /// 面板的第一响应者是哪条便签的正文框（它的编号）；不是正文框就是 nil
  private func focusedNote(_ deck: NoteDeck) -> String? {
    (deck.panel?.firstResponder as? NoteTextView)?.identifier?.rawValue
  }

  /// 等界面跟上：一轮一轮让出去，到条件成立为止（最多 3 秒；按轮数、不掐时间）
  private func settle(until done: () -> Bool) async throws {
    for _ in 0..<150 where !done() { try await Task.sleep(for: .milliseconds(20)) }
  }

  /// 面板宿主上「跟鼠标」的那块追踪区（自己加的：activeAlways + mouseMoved）
  private func pointerAreas(_ panel: NSPanel?) -> [NSTrackingArea] {
    panel?.contentView?.trackingAreas.filter {
      $0.options.contains([.activeAlways, .mouseMoved])
    } ?? []
  }

  /// 写标题、正文按「这个输入框是哪条便签的」落，不按现在开着哪条：换一条时旧的输入框还在淡出，它晚到的那一下
  /// （输入法组字到一半失焦时提交的字）不能把新开的那条盖掉；关掉之后晚到的也照样落回去；那条不在了就不写
  @Test func writesGoToTheNoteTheyBelongTo() throws {
    let (model, store, ids) = try make(["甲的正文", "乙的正文"])
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.tapTab(ids[1])
    #expect(model.state.openID == ids[1])
    model.setBody("甲的正文，加上组字到一半提交的字", of: ids[0])
    model.setTitle("甲的标题", of: ids[0])
    #expect(store.note(ids[0])?.body == "甲的正文，加上组字到一半提交的字")
    #expect(store.note(ids[0])?.title == "甲的标题")
    #expect(store.note(ids[1])?.body == "乙的正文" && store.note(ids[1])?.title == "")
    model.send(.close)
    model.setBody("关掉之后才到的", of: ids[1])
    #expect(store.note(ids[1])?.body == "关掉之后才到的")
    store.erase(ids[0])
    model.setBody("这条已经没了", of: ids[0])
    model.setTitle("这条已经没了", of: ids[0])
    #expect(store.note(ids[0]) == nil && store.notes.map(\.id) == [ids[1]])
    // 「打到上限」的标记只被现在开着的那条的输入清掉
    model.tapTab(ids[1])
    model.overflowed()
    model.setBody("别的便签晚到的字", of: "别的编号")
    #expect(model.isOverLimit)
    model.setBody("这条自己的字", of: ids[1])
    #expect(!model.isOverLimit)
  }

  /// 状态变了该做哪几件事：只有新打开 / 换了一条才当 key、聚焦；任何「打开 → 扇出」都当场把键盘还回去；
  /// 用键盘关的（和点别处）整块收走
  @Test func effectsOfEachTransition() {
    typealias Effects = NoteDeck.Effects
    func effects(_ old: NoteDeckState, _ event: NoteDeckState.Event) -> Effects {
      var new = old
      new.handle(event)
      return NoteDeck.effects(from: old, to: new)
    }
    let rest = NoteDeckState()
    let fanned = state(Self.enter)
    let open = state(Self.enter, .tab("a"))
    #expect(effects(rest, Self.enter) == [.expand, .present, .watch])
    #expect(effects(rest, .created("n")) == [.expand, .present, .focus])
    #expect(effects(fanned, .tab("a")) == [.expand, .focus])
    #expect(effects(fanned, .showAll) == [.watch])
    #expect(effects(fanned, .left) == [.hide])
    #expect(effects(fanned, .dismiss) == [.hide])
    #expect(effects(open, .tab("b")) == [.flush, .expand, .focus])
    // 鼠标关（关闭钮、它自己的标签）、归档 / 删除之后：回到那一列，键盘当场还回去
    #expect(effects(open, .close) == [.flush, .releaseKey, .watch])
    #expect(effects(open, .tab("a")) == [.flush, .releaseKey, .watch])
    // 键盘关、点别处、被叫停、让位：整块收走（键盘自然回去）
    #expect(effects(open, .dismiss) == [.flush, .hide])
    #expect(effects(open, .clickedOutside(pinned: false)) == [.flush, .hide])
    #expect(effects(open, .suspend(closesOpen: true)) == [.flush, .hide])
    #expect(effects(open, .yield(pinned: false)) == [.flush, .hide])
    // 便签开着时别的变化（「+N」、切「一直展开」）：什么都不做——尤其不许当 key
    #expect(effects(open, .showAll) == [])
    var always = open
    always.setAlwaysFanned(true)
    #expect(NoteDeck.effects(from: open, to: always) == [])
    var back = always
    back.setAlwaysFanned(false)
    #expect(NoteDeck.effects(from: always, to: back) == [])
    // 一直展开：静置的直接成了那一列；用键盘关便签回到那一列、键盘还回去；关掉设置后只是重新看着
    var shown = rest
    shown.setAlwaysFanned(true)
    #expect(NoteDeck.effects(from: rest, to: shown) == [.expand, .present, .watch])
    #expect(effects(always, .dismiss) == [.flush, .releaseKey, .watch])
    var watched = shown
    watched.setAlwaysFanned(false)
    #expect(NoteDeck.effects(from: shown, to: watched) == [.watch])
  }

  /// 输入法正组着字时的「点别处」不收（多半是在用鼠标点候选词，候选窗是别的进程的窗口）
  @Test func composingClicksAreNotOutside() {
    let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
    #expect(!NoteDeck.isComposing(text) && !NoteDeck.isComposing(nil))
    #expect(!NoteDeck.isComposing(NSView()))
    text.setMarkedText(
      "pin", selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(text.hasMarkedText() && NoteDeck.isComposing(text))
    text.unmarkText()
    #expect(!NoteDeck.isComposing(text))
  }

  /// 点在输入法的窗口上（系统的「表情与符号」、候选窗、第三方输入法）不算点别处：按点中的窗口归哪个 App、
  /// 那个 App 装在不在「Input Methods」目录里认（未来计划 B）
  @Test func inputMethodWindowsAreNotOutside() {
    let palette = URL(fileURLWithPath: "/System/Library/Input Methods/CharacterPalette.app")
    #expect(OverlayPanel.isInputMethod(palette))
    #expect(OverlayPanel.isInputMethod(URL(fileURLWithPath: "/Library/Input Methods/Foo.app")))
    #expect(
      OverlayPanel.isInputMethod(
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/Foo.app")))
    #expect(!OverlayPanel.isInputMethod(URL(fileURLWithPath: "/Applications/TextEdit.app")))
    #expect(!OverlayPanel.isInputMethod(URL(fileURLWithPath: "/Applications/Input Methods.app")))
    #expect(!OverlayPanel.isInputMethod(nil))
    // 点在所有屏幕外面：没点中窗口
    #expect(ScreenCapture.ownerPID(at: CGPoint(x: -1_000_000, y: -1_000_000)) == nil)
  }

  /// 换一条便签时新旧两个正文框都在视图树里：拿焦点的按便签的编号认，不是先碰到哪个算哪个
  @Test func editorIsFoundByNoteID() {
    let root = NSView()
    let (old, new) = (NSView(), NSView())
    let first = NoteTextView.make()
    first.identifier = NSUserInterfaceItemIdentifier("甲")
    let second = NoteTextView.make()
    second.identifier = NSUserInterfaceItemIdentifier("乙")
    old.addSubview(first)
    new.addSubview(second)
    root.addSubview(old)
    root.addSubview(new)
    #expect(NoteDeck.editor(for: "乙", in: root) === second)
    #expect(NoteDeck.editor(for: "甲", in: root) === first)
    #expect(NoteDeck.editor(for: "丙", in: root) == nil && NoteDeck.editor(for: "甲", in: nil) == nil)
    // 没标编号的、别处的多行输入框（SourceTextView）不会被当成它
    root.addSubview(NoteTextView.make())
    let foreign = SourceTextView.FocusTextView(frame: .zero)
    foreign.identifier = NSUserInterfaceItemIdentifier("丙")
    root.addSubview(foreign)
    #expect(NoteDeck.editor(for: "", in: root) == nil && NoteDeck.editor(for: "丙", in: root) == nil)
  }

  /// 共用的正文框标着便签的编号、插入点用墨色（不是强调色：强调色选黄时在柠檬色的纸上看不见）；标题框同样
  @Test func paperInputsUseInkForTheCaret() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let note = store.create(body: "正文")
    let paper = NotePaper.of(note)
    func rgb(_ color: NSColor?) -> [Int] {
      var parts: [Int] = []
      NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        let resolved = color?.usingColorSpace(.sRGB)
        parts = [resolved?.redComponent, resolved?.greenComponent, resolved?.blueComponent]
          .map { Int((($0 ?? -1) * 255).rounded()) }
      }
      return parts
    }
    let ink = [
      (paper.light.ink >> 16) & 0xFF, (paper.light.ink >> 8) & 0xFF, paper.light.ink & 0xFF,
    ]
    let window = NSWindow(
      contentRect: Self.offscreen, styleMask: [.borderless], backing: .buffered, defer: true)
    let host = NSHostingView(
      rootView: NoteBodyField(
        note: note, fontSize: 15, margin: 14, setBody: { _ in }, onOverflow: {}))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let editor = try #require(NoteDeck.editor(for: note.id, in: host))
    #expect(rgb(editor.insertionPointColor) == ink && rgb(editor.textColor) == ink)

    let field = CommandTextField.FocusField()
    field.frame = CGRect(x: 0, y: 0, width: 200, height: 22)
    let fieldWindow = NSWindow(
      contentRect: Self.offscreen, styleMask: [.borderless], backing: .buffered, defer: true)
    fieldWindow.contentView?.addSubview(field)
    #expect(fieldWindow.makeFirstResponder(field))
    let caret = { (field.currentEditor() as? NSTextView)?.insertionPointColor }
    // 没给墨色的（别的调用方）：照旧是强调色
    field.applyBrandColors(.systemPink)
    #expect(caret() == .systemPink)
    field.caretColor = paper.inkColor
    field.applyBrandColors(.systemPink)
    #expect(rgb(caret()) == ink)
  }

  /// 悬停：叫停着（「一直展开」时那一列还在）不出预览卡、不悬停打开；先报「进了下一张」再报「出了这一张」时不把
  /// 下一张的取消掉；悬停打开的不抢键盘
  @Test func hoverRespectsPauseAndOrder() throws {
    let (model, _, ids) = try make(["一", "二", "三"])
    model.send(Self.enter)
    var allowed = false
    model.canFan = { allowed }
    model.hover(ids[0], true)
    #expect(model.hovered == nil)
    model.openFromHover(ids[0])
    #expect(model.state.phase == .fanned)
    allowed = true
    model.hover(ids[0], true)
    model.hover(ids[1], true)
    model.hover(ids[0], false)
    #expect(model.hovered == ids[1])
    model.hover(ids[1], false)
    #expect(model.hovered == nil)
    var takesKey: [Bool] = []
    model.onChange = { [unowned model] _, new in
      if new.openID != nil { takesKey.append(model.takesKey) }
    }
    model.openFromHover(ids[2])
    #expect(model.state.openID == ids[2] && takesKey == [false] && model.takesKey)
    model.send(.close)
    model.tapTab(ids[1])
    #expect(takesKey == [false, true])
  }

  /// 别的屏的那叠要展开：这块屏打开着的便签没固定才收，固定的不收
  @Test func yieldingKeepsPinnedNotes() throws {
    let (model, store, ids) = try make(["一", "二"])
    model.send(Self.enter)
    model.yield()
    #expect(model.state.phase == .rest)
    model.send(Self.enter)
    model.tapTab(ids[0])
    store.setPinned(true, of: ids[0])
    model.yield()
    #expect(model.state.openID == ids[0])
    store.setPinned(false, of: ids[0])
    model.yield()
    #expect(model.state.phase == .rest)
  }

  /// 叫停的三档到「打开着的便签收不收」
  @Test func suspensionKinds() {
    typealias Kind = NoteEdge.Suspension
    #expect(!Kind.keepsOpen.closesOpen(pinned: false) && !Kind.keepsOpen.closesOpen(pinned: true))
    #expect(Kind.unlessPinned.closesOpen(pinned: false))
    #expect(!Kind.unlessPinned.closesOpen(pinned: true))
    #expect(Kind.all.closesOpen(pinned: false) && Kind.all.closesOpen(pinned: true))
  }

  /// 面板里真有东西的那一块：静置是 .zero（截图的悬停列表里就没有这扇窗口——nil 才是「整个窗口」）
  @Test func contentFrameIsZeroWhenThereIsNothing() throws {
    let (model, _, ids) = try make(["一", "二"])
    let panel = CGRect(x: 902, y: 0, width: 538, height: 875)
    #expect(model.contentFrame(in: panel) == .zero)
    model.send(Self.enter)
    var layout = model.layout
    #expect(
      model.contentFrame(in: panel)
        == Layout.columnFrame(
          panel: panel, edge: .right, top: model.columnTop(layout), height: layout.columnHeight,
          width: 30))
    model.tapTab(ids[0])
    layout = model.layout
    #expect(
      model.contentFrame(in: panel)
        == Layout.noteFrame(
          panel: panel, edge: .right, top: model.noteTop(layout),
          size: CGSize(width: 460, height: 380), tabWidth: 30))
    model.send(.dismiss)
    #expect(model.contentFrame(in: panel) == .zero)
    let deckPanel = NoteDeckPanel(frame: Self.offscreen, model: model, onPointer: {})
    #expect(deckPanel.contentFrame() == .zero)
    let own = ScreenCapture.OwnWindow(
      id: 5, className: "NoteDeckPanel", level: 3, isVisible: true, alpha: 1, content: .zero)
    #expect(own.content == .zero)
  }

  /// 便签的位置在打开那一刻定住：标签露出多长跟着最长的标题实时变，便签不跟着一跳一跳；关掉再开、面板大小变了才重算
  @Test func openNoteStaysPutWhileTitlesChange() throws {
    let (model, store, ids) = try make(["短", "也短", "三"])
    model.send(Self.enter)
    #expect(model.openTop == nil)
    model.tapTab(ids[0])
    let top = model.noteTop(model.layout)
    let step = model.layout.step
    #expect(model.openTop == top)
    store.setBody("这一条的第一行现在变得很长很长很长很长", of: ids[2])
    #expect(model.layout.step > step)
    #expect(model.noteTop(model.layout) == top)
    model.send(.showAll)
    #expect(model.noteTop(model.layout) == top)
    model.send(.close)
    #expect(model.openTop == nil)
    model.tapTab(ids[0])
    #expect(model.noteTop(model.layout) != top && model.openTop != nil)
    // 换一条：按那一条的标签重算
    let first = model.openTop
    model.tapTab(ids[2])
    #expect(model.openTop != first)
    // 面板大小变了（换了屏幕 / 设置）：重算一次
    let before = model.openTop
    model.panelSize = CGSize(width: 538, height: 600)
    model.pillCenter = 300
    #expect(model.openTop == before)
    model.relayout()
    #expect(model.openTop != before)
  }

  /// 底下那行小字：有改动没落下盘先说「没存上，正在重试」，再是打到上限；都没有照常
  @Test func footnoteWarnsWhenUnsaved() {
    #expect(NoteFootnote.warning(isUnsaved: false, isOverLimit: false) == nil)
    #expect(NoteFootnote.warning(isUnsaved: true, isOverLimit: false) == "没存上，正在重试")
    #expect(NoteFootnote.warning(isUnsaved: true, isOverLimit: true) == "没存上，正在重试")
    #expect(
      NoteFootnote.warning(isUnsaved: false, isOverLimit: true) == NotesWindowModel.overLimitText)
  }

  /// 「新建便签」复用的空白便签正好开着（面板可能不是 key）：状态没变，也要把焦点放进正文
  @Test func creatingAnAlreadyOpenBlankNoteFocusesIt() throws {
    let (model, store, _) = try make(["旧的"])
    var focused = 0
    model.focusBody = { focused += 1 }
    model.create()
    let id = try #require(model.state.openID)
    #expect(focused == 0 && store.active.count == 2)  // 刚打开的：聚焦由状态变化那条路管
    model.create()
    #expect(focused == 1 && store.active.count == 2 && model.state.openID == id)
    model.open(created: id)
    #expect(focused == 2)
  }

  /// 最前面那条还是空白的就复用（全部便签窗口、那叠共用的那一个方法）
  @Test func blankNoteIsReused() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let first = store.blankOrNew()
    #expect(store.active.count == 1 && store.blankOrNew().id == first.id)
    store.setTitle("起了标题", of: first.id)
    let second = store.blankOrNew()
    #expect(second.id != first.id && store.active.first?.id == second.id)
    store.setBody("写了字", of: second.id)
    store.setArchived(true, of: second.id)
    #expect(store.blankOrNew().id != second.id && store.active.count == 2)
  }

  /// 每条便签自己的撤销栈：换一条换一个新的（A 里打的字不能在 B 里被 ⌘Z 撤到）。正文框建出来时拿到它
  /// （undoAndRedoGoThroughThePanelKeys 里验「登记和操作是同一个」）
  @Test func eachNoteHasItsOwnUndoStack() throws {
    let (model, _, ids) = try make(["一", "二"])
    model.send(Self.enter)
    model.tapTab(ids[0])
    let first = model.textUndo
    model.togglePinned()
    model.send(.showAll)
    #expect(model.textUndo === first)
    model.tapTab(ids[1])
    let second = model.textUndo
    #expect(second !== first)
    model.tapTab(ids[0])
    #expect(model.textUndo !== second && model.textUndo !== first)
  }

  /// ⌘Z / ⇧⌘Z 的事件（按键入口用：直接交给面板的 performKeyEquivalent，不往系统里发）
  private func undoKey(redo: Bool = false, in window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: redo ? [.command, .shift] : .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "z",
        charactersIgnoringModifiers: redo ? "Z" : "z", isARepeat: false,
        keyCode: UInt16(kVK_ANSI_Z)))
  }

  private func titleField(in view: NSView?) -> CommandTextField.FocusField? {
    guard let view else { return nil }
    return (view as? CommandTextField.FocusField)
      ?? view.subviews.lazy.compactMap { titleField(in: $0) }.first
  }

  /// ⌘B ⌘I ⌘E ⇧⌘X（手测反馈第 4 批）从那叠的面板的按键入口走到正文框：面板先问自己的键（NoteSheetModel.
  /// handleKeyEquivalent：⌘W ⌘P ⌘K ⌘. ⌘T ⌘F ⇧⌘A ⌘,）——都不是这四个——再沿着视图树问到焦点所在的正文；
  /// 仓库里那份跟着变，能撤（⌘Z 也从面板走）。面板在屏外、不当 key
  @Test func formatKeysReachTheOpenNote() async throws {
    let deck = try offscreenDeck(["甲的正文"])
    defer { deck.close() }
    let store = deck.model.store
    let id = try #require(store.active.first?.id)
    store.setPinned(true, of: id)
    deck.pill?.onPress()
    deck.model.tapTab(id)
    try await settle { focusedNote(deck) == id }
    let panel = try #require(deck.panel)
    let editor = try #require(NoteDeck.editor(for: id, in: panel.contentView))
    func press(_ key: String, _ code: Int, _ flags: NSEvent.ModifierFlags = .command) throws -> Bool
    {
      panel.performKeyEquivalent(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: flags.contains(.shift) ? key.uppercased() : key,
            isARepeat: false, keyCode: UInt16(code))))
    }
    editor.setSelectedRange(NSRange(location: 0, length: 2))
    #expect(try press("b", kVK_ANSI_B) && store.note(id)?.body == "**甲的**正文")
    #expect(try press("i", kVK_ANSI_I) && store.note(id)?.body == "***甲的***正文")
    #expect(try press("e", kVK_ANSI_E) && store.note(id)?.body == "***`甲的`***正文")
    #expect(try press("x", kVK_ANSI_X, [.command, .shift]))
    // 行内代码里不能再加删除线：响一声、不改
    #expect(store.note(id)?.body == "***`甲的`***正文" && !panel.isKeyWindow)
    // ⌘Z 撤回去（测试里几次按键不在各自的一轮事件循环里，系统会并成一组；一步一撤在 NoteTextViewTests）
    var undos = 0
    while store.note(id)?.body != "甲的正文", undos < 4, try press("z", kVK_ANSI_Z) { undos += 1 }
    #expect(undos >= 1 && store.note(id)?.body == "甲的正文")
  }

  /// 撤销 / 重做从按键入口走到底（2026-10-13 用户报「便签输入区域不支持撤销和回退」）：往正文里打字、勾任务、改标题，
  /// 把 ⌘Z / ⇧⌘Z 的事件交给面板的 performKeyEquivalent，字真的回去、再回来，仓库里那份跟着变。
  /// 登记撤销的栈和按键动的栈是同一个（这条便签的 textUndo）；换一条便签各有各的栈。面板在屏外、不当 key
  @Test func undoAndRedoGoThroughThePanelKeys() async throws {
    let deck = try offscreenDeck(["甲的正文", "☐ 乙的任务"])
    defer { deck.close() }
    let store = deck.model.store
    let ids = store.active.map(\.id)
    for id in ids { store.setPinned(true, of: id) }
    deck.pill?.onPress()
    deck.model.tapTab(ids[0])
    try await settle { focusedNote(deck) == ids[0] }
    let panel = try #require(deck.panel)
    func press(redo: Bool = false) throws -> Bool {
      panel.performKeyEquivalent(with: try undoKey(redo: redo, in: panel))
    }
    func insert(_ text: String, into view: NSTextView) {
      view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    let editor = try #require(NoteDeck.editor(for: ids[0], in: panel.contentView))
    // 同一个栈：文本视图登记用的、按键入口动的、这条便签的
    #expect(editor.undoManager === deck.model.textUndo)
    #expect(panel.focusedTextUndo === deck.model.textUndo && !panel.isKeyWindow)
    // 没有可撤销 / 重做的：不算处理了
    #expect(try !press() && !press(redo: true))

    // 正文里打两段 → ⌘Z 回到打之前 → ⇧⌘Z 回来
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    insert("，加一句", into: editor)
    insert("再一句", into: editor)
    let typed = "甲的正文，加一句再一句"
    #expect(editor.string == typed && store.note(ids[0])?.body == typed)
    var presses = 0
    while editor.string != "甲的正文", presses < 4, try press() { presses += 1 }
    #expect(presses >= 1 && editor.string == "甲的正文" && store.note(ids[0])?.body == "甲的正文")
    #expect(try !press())
    while editor.string != typed, presses > 0, try press(redo: true) { presses -= 1 }
    #expect(editor.string == typed && store.note(ids[0])?.body == typed)
    #expect(try !press(redo: true))

    // 标题框：它的字段编辑器有自己的栈——⌘Z 撤的是标题里打的字，正文不动
    let title = try #require(titleField(in: panel.contentView))
    #expect(panel.makeFirstResponder(title))
    let fieldEditor = try #require(title.currentEditor() as? NSTextView)
    #expect(panel.focusedTextUndo === fieldEditor.undoManager)
    #expect(fieldEditor.undoManager !== deck.model.textUndo)
    insert("新标题", into: fieldEditor)
    #expect(store.note(ids[0])?.title == "新标题")
    #expect(try press())
    #expect(store.note(ids[0])?.title == "" && store.note(ids[0])?.body == typed)
    #expect(try press(redo: true))
    #expect(store.note(ids[0])?.title == "新标题" && editor.string == typed)

    // 换到乙：新的栈。勾任务 → ⌘Z → ⇧⌘Z；甲里打的字不动
    deck.model.tapTab(ids[1])
    try await settle { focusedNote(deck) == ids[1] }
    let second = try #require(NoteDeck.editor(for: ids[1], in: panel.contentView))
    #expect(second.undoManager === deck.model.textUndo && second.undoManager !== editor.noteUndo)
    #expect(try !press())
    #expect(store.note(ids[0])?.body == typed && store.note(ids[1])?.body == "☐ 乙的任务")
    panel.contentView?.layoutSubtreeIfNeeded()
    let manager = try #require(second.layoutManager)
    let container = try #require(second.textContainer)
    manager.ensureLayout(for: container)
    let box = manager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
    let origin = second.textContainerOrigin
    let point = second.convert(NSPoint(x: box.midX + origin.x, y: box.midY + origin.y), to: nil)
    let click = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    second.mouseDown(with: click)
    #expect(store.note(ids[1])?.body == "☑ 乙的任务")
    #expect(try press())
    #expect(second.string == "☐ 乙的任务" && store.note(ids[1])?.body == "☐ 乙的任务")
    #expect(try press(redo: true))
    #expect(store.note(ids[1])?.body == "☑ 乙的任务" && store.note(ids[0])?.body == typed)
    // ⌘T（面板的按键入口）也是一步能撤的
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_T, .command)))
    #expect(store.note(ids[1])?.body == "乙的任务")
    #expect(try press() && store.note(ids[1])?.body == "☑ 乙的任务")
    // ⌘F：这条便签自己的查找条；Esc 先关它，便签还开着
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_F, .command)))
    #expect(second.enclosingScrollView?.isFindBarVisible == true)
    deck.model.cancel()
    #expect(second.enclosingScrollView?.isFindBarVisible == false && deck.model.current != nil)
  }

  /// 面板的按键入口（不显示、不当 key，直接调）：Esc → onCancel；⌘ 组合先问 keyEquivalentHandler；
  /// 焦点不在输入框里时的按键给 keyDownHandler
  @Test func panelRoutesKeys() throws {
    let (model, _, _) = try make(["一"])
    let panel = NoteDeckPanel(frame: Self.offscreen, model: model, onPointer: {})
    var cancels = 0
    var equivalents: [Int] = []
    var downs: [Int] = []
    panel.onCancel = { cancels += 1 }
    panel.keyEquivalentHandler = {
      equivalents.append(Int($0.keyCode))
      return Int($0.keyCode) == kVK_ANSI_P
    }
    panel.keyDownHandler = {
      downs.append(Int($0.keyCode))
      return true
    }
    #expect(!panel.isVisible && !panel.isKeyWindow)
    panel.cancelOperation(nil)
    #expect(cancels == 1)
    #expect(try panel.performKeyEquivalent(with: key(kVK_ANSI_P, .command)))
    #expect(try !panel.performKeyEquivalent(with: key(kVK_ANSI_Y, .command)))
    #expect(equivalents == [kVK_ANSI_P, kVK_ANSI_Y])
    try panel.keyDown(with: key(kVK_Escape))
    #expect(cancels == 2 && downs.isEmpty)
    try panel.keyDown(with: key(kVK_DownArrow))
    #expect(downs == [kVK_DownArrow])
  }

  /// 跟鼠标的追踪区只挂在热区那一块上，没有热区就不挂（便签开着、一直展开时鼠标在面板上动不唤醒本进程）
  @Test func pointerTrackingCoversOnlyTheHotZone() throws {
    let (model, _, _) = try make(["一"])
    let frame = Self.offscreen
    let panel = NoteDeckPanel(frame: frame, model: model, onPointer: {})
    #expect(pointerAreas(panel).isEmpty)
    panel.track(CGRect(x: frame.maxX - 50, y: frame.minY + 300, width: 70, height: 340))
    let rect = try #require(pointerAreas(panel).first?.rect)
    #expect(pointerAreas(panel).count == 1)
    #expect(rect.width == 70 && rect.height == 340 && rect.minX == 538 - 50)
    panel.track(.zero)
    #expect(pointerAreas(panel).isEmpty)
  }

  /// 收回的那 0.14 秒里（标签往回滑、面板还没收走）被叫停：当场收走，冻结帧里不留半截；这一小会儿也不算有内容。
  /// 追踪区只在扇着时挂
  @Test func suspendCutsAPendingHideShort() throws {
    let deck = try offscreenDeck(["一", "二"])
    defer { deck.close() }
    deck.pill?.onEnter(false)
    let panel = try #require(deck.panel)
    #expect(panel.isVisible && !panel.isKeyWindow && deck.contentFrame != .zero)
    #expect(pointerAreas(panel).count == 1)
    deck.model.send(.left)
    #expect(deck.model.state.phase == .rest && deck.contentFrame == .zero)
    #expect(pointerAreas(panel).isEmpty)
    if !Style.reduceMotion { #expect(panel.isVisible) }
    deck.suspend(.keepsOpen)
    #expect(!panel.isVisible)
  }

  /// 面板收起后到点放掉；留着的时候又展开就接着用同一块、不放（同 TransientPanelTests）。
  /// 不掐时间（全量单测并行跑时一次 sleep 可能拖很久）：看「是不是正等着放掉」，最后才等它真放掉
  @Test func panelIsReleasedAfterLingering() async throws {
    let deck = try offscreenDeck(["一"], lingering: .milliseconds(40))
    defer { deck.close() }
    #expect(!deck.isLingering)
    deck.pill?.onPress()
    let first = try #require(deck.panel)
    deck.suspend(.keepsOpen)
    #expect(deck.panel === first && !first.isVisible && deck.isLingering)
    // 留着的时候又展开：等着放掉的那一下作废，接着用同一块
    deck.pill?.onPress()
    #expect(deck.panel === first && first.isVisible && !deck.isLingering)
    deck.suspend(.keepsOpen)
    #expect(deck.isLingering)
    for _ in 0..<500 where deck.panel != nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(deck.panel == nil)
    // 放掉之后再扇出：新建的一块
    deck.pill?.onPress()
    #expect(deck.panel != nil && deck.panel !== first)
  }

  /// 点标签（打开、换一条）、「新建便签」、悬停打开之后，焦点自己进那条便签的正文（2026-10-13 手测反馈）。
  /// 面板在屏幕外、**不当 key**（makeFirstResponder 不要求窗口是 key）；便签都固定着（见 offscreenDeck）
  @Test func openingANoteFocusesItsBody() async throws {
    let deck = try offscreenDeck(["甲", "乙", "丙"])
    defer { deck.close() }
    let store = deck.model.store
    let ids = store.active.map(\.id)
    for id in ids { store.setPinned(true, of: id) }
    deck.pill?.onPress()
    #expect(focusedNote(deck) == nil)
    // 打开
    deck.model.tapTab(ids[0])
    try await settle { focusedNote(deck) == ids[0] }
    #expect(focusedNote(deck) == ids[0] && deck.panel?.isKeyWindow == false)
    // 换一条：旧的那块编辑区还在淡出，焦点要进新的那条
    deck.model.tapTab(ids[1])
    try await settle { focusedNote(deck) == ids[1] }
    #expect(focusedNote(deck) == ids[1])
    // 「新建便签」落在别的一条上（全局动作、标签列下的「+」最后都走 open(created:)）
    deck.model.open(created: ids[2])
    try await settle { focusedNote(deck) == ids[2] }
    #expect(focusedNote(deck) == ids[2])
    // 焦点被拿走之后（操作菜单开着时在面板自己身上），再要一次还回来：标题框里 ↩ / Tab、复用的空白便签
    deck.panel?.makeFirstResponder(nil)
    #expect(focusedNote(deck) == nil)
    deck.model.open(created: ids[2])
    try await settle { focusedNote(deck) == ids[2] }
    #expect(focusedNote(deck) == ids[2])
    // 关掉回到那一列，再靠悬停打开：不当 key，第一响应者照样落在正文上
    deck.model.send(.close)
    #expect(deck.model.state.phase == .fanned)
    deck.model.openFromHover(ids[0])
    try await settle { focusedNote(deck) == ids[0] }
    #expect(focusedNote(deck) == ids[0] && deck.panel?.isKeyWindow == false)
  }

  /// 该哪条便签的正文拿焦点（界面读的那一份）：每次打开 / 换一条记一次，只有那一条拿得到；再要一次次数加一；
  /// 便签没开着时要了不算
  @Test func focusFollowsTheOpenNote() throws {
    let (model, _, ids) = try make(["甲", "乙"])
    var asked = 0
    model.focusBody = { asked += 1 }
    #expect(model.focus == nil && model.focusRequest(for: ids[0]) == nil)
    model.requestFocus()
    #expect(model.focus == nil && asked == 0)
    model.send(Self.enter)
    model.tapTab(ids[0])
    let first = try #require(model.focusRequest(for: ids[0]))
    #expect(model.focusRequest(for: ids[1]) == nil)
    model.tapTab(ids[1])
    let second = try #require(model.focusRequest(for: ids[1]))
    #expect(second > first && model.focusRequest(for: ids[0]) == nil && asked == 0)
    // 标题框里 ↩ / Tab、复用的空白便签：再要一次（并叫窗口那边当 key、兜底去找）
    model.requestFocus()
    #expect(model.focusRequest(for: ids[1]) == second + 1 && asked == 1)
    model.open(created: ids[1])
    #expect(model.focusRequest(for: ids[1]) == second + 2 && asked == 2)
    // 悬停打开的也记（不当 key，第一响应者照样落在正文上）
    model.send(.close)
    model.openFromHover(ids[0])
    #expect(model.focusRequest(for: ids[0]) == second + 3)
  }

  /// 视图树里有几块 HoverTracker 的追踪视图（标签、预览卡的悬停）
  private func hoverViews(in view: NSView?) -> Int {
    guard let view else { return 0 }
    return (view is HoverTracker.TrackingView ? 1 : 0)
      + view.subviews.reduce(0) { $0 + hoverViews(in: $1) }
  }

  /// 2026-10-13 真机崩溃的复现（扇出、收回约 2 秒后必崩）：放掉面板时它的视图跟着拆，标签上 HoverTracker 的视图被
  /// 移出窗口会补报一个「移出」，一路回调到 NoteDeck 去读 panel——原来那句 `panel = nil` 正写到一半，独占访问检查
  /// 直接终止进程。走「收起后到点放掉」和 close() 两条路都不能崩。
  /// **这里不能把面板存进局部变量**：有别人拿着它，置空时就不释放、复现不出来（panelIsReleasedAfterLingering
  /// 没崩就是这个原因）
  @Test func releasingThePanelSurvivesViewCallbacks() async throws {
    let deck = try offscreenDeck(["一", "二"], lingering: .milliseconds(40))
    // 收起时报一声（AppDelegate 排空闲回收，调优 T2）
    var hidden = 0
    deck.onHide = { hidden += 1 }
    deck.pill?.onPress()
    deck.panel?.contentView?.layoutSubtreeIfNeeded()
    // 标签的悬停追踪视图真建出来了（没有它们就复现不了）
    #expect(hoverViews(in: deck.panel?.contentView) >= 2)
    #expect(hidden == 0)
    deck.suspend(.keepsOpen)
    #expect(deck.isLingering && hidden == 1)
    for _ in 0..<500 where deck.panel != nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(deck.panel == nil && deck.model.state.phase == .rest && !deck.isAwaitingLeave)
    // close() 那条路：扇着的时候这块屏不放了
    deck.pill?.onPress()
    deck.panel?.contentView?.layoutSubtreeIfNeeded()
    #expect(hoverViews(in: deck.panel?.contentView) >= 2)
    // 让出一轮：这一段里对面板的临时引用都放手了，close() 里才是真的释放
    try await Task.sleep(for: .milliseconds(20))
    #expect(deck.model.state.phase == .fanned)
    deck.close()
    #expect(deck.panel == nil && deck.pill == nil && !deck.isAwaitingLeave)
  }

  /// 旁白「按下」药丸扇出的：鼠标本来就不在热区里，不排「离开了就收」（只靠 4 秒没动静）；鼠标进来的那条路照常——
  /// 这里鼠标其实不在（窗口在屏幕外），排上确认、过一会儿收回
  @Test func pressingThePillDoesNotCollapseOnLeave() async throws {
    let deck = try offscreenDeck(["一"])
    defer { deck.close() }
    deck.pill?.onPress()
    #expect(deck.model.state.phase == .fanned && !deck.isAwaitingLeave)
    // 之后有动静（比如旁白挪到了一张标签上）也不排
    deck.model.hover(deck.model.tabs[0].id, true)
    #expect(deck.model.state.phase == .fanned && !deck.isAwaitingLeave)
    deck.suspend(.keepsOpen)
    #expect(deck.model.state.phase == .rest)
    deck.pill?.onEnter(false)
    #expect(deck.model.state.phase == .fanned && deck.isAwaitingLeave)
    for _ in 0..<500 where deck.model.state.phase != .rest {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(deck.model.state.phase == .rest && !deck.isAwaitingLeave)
  }

  /// 显示器同名的加序号（设置页的菜单不出重复的 id，「指定某一块」也分得清）；⌥ 拖药丸只有指定的那块真接着时才能
  /// 换屏——它不在、药丸是退回主显示器的，这时不改写「指定的是哪块」
  @Test func displayNamesAndCrossingScreens() {
    #expect(Layout.uniqueNames([]) == [])
    #expect(Layout.uniqueNames(["内建", "DELL"]) == ["内建", "DELL"])
    #expect(
      Layout.uniqueNames(["DELL", "内建", "DELL", "DELL"]) == ["DELL", "内建", "DELL 2", "DELL 3"])
    let screens = [Self.screen(), Self.screen("DELL", x: 1440)]
    #expect(Layout.crossesScreens(.named("DELL"), screens: screens))
    #expect(!Layout.crossesScreens(.named("拔掉的那块"), screens: screens))
    #expect(!Layout.crossesScreens(.main, screens: screens))
    #expect(!Layout.crossesScreens(.all, screens: screens))
    #expect(NoteDeckOptions.DisplayMode.allCases.map(\.rawValue) == ["main", "all", "chosen"])
    #expect(NoteDeckOptions.TabStyle.allCases.map(\.rawValue) == ["tabs", "chips"])
  }

  /// 预览卡：标题取自正文第一行、后面又没有别的内容时只写标题（折到三行），不另写「没有更多内容」
  @Test func previewCardTitleOnly() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let oneLine = store.create(body: "只有这一行字")
    let twoLines = store.create(body: "第一行\n第二行")
    let titled = store.create(body: "", title: "自己起的标题")
    let blank = store.create()
    let titleOnly = { (note: Note) in
      NotePreviewCard.isTitleOnly(note, summary: store.summary(of: note))
    }
    #expect(titleOnly(oneLine))
    #expect(!titleOnly(twoLines))
    #expect(!titleOnly(titled) && !titleOnly(blank))
  }

  // MARK: 纸色

  /// 打开的便签带着的那张标签（纸上叠一层色条色）：墨在上面仍够 4.5:1，两套都是
  @Test func tabTintKeepsInkReadable() {
    func channels(_ rgb: Int) -> [Double] {
      [Double((rgb >> 16) & 0xFF), Double((rgb >> 8) & 0xFF), Double(rgb & 0xFF)].map { $0 / 255 }
    }
    func luminance(_ color: [Double]) -> Double {
      let linear = color.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
      return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    func contrast(_ a: [Double], _ b: [Double]) -> Double {
      let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
      return (high + 0.05) / (low + 0.05)
    }
    for paper in NotePaper.all {
      for tone in [paper.light, paper.dark] {
        let tinted = zip(channels(tone.paper), channels(tone.strip)).map {
          $0 * (1 - NotePaper.tabTint) + $1 * NotePaper.tabTint
        }
        #expect(contrast(tinted, channels(tone.ink)) >= 4.5, "\(paper.name)")
      }
    }
  }

  // MARK: 手测反馈第 3 批（2026-10-15）

  /// 右键一张标签：这条便签的操作，不用先打开它——条目和名字（固定 / 没固定、浮着 / 没浮着；名字同全部便签窗口），
  /// 点了各项落到右键的那一条上，不是开着的那条；开着的那条被归档 / 删除时先关掉；归档了的没有菜单
  @Test func tabMenuActsOnItsOwnNote() throws {
    let (model, store, ids) = try make(["甲", "乙", "丙"])
    var toggled: [String] = []
    var floatedOpen: [String] = []
    model.toggleFloat = { toggled.append($0) }
    model.onFloat = { floatedOpen.append($0) }
    model.send(Self.enter)
    model.tapTab(ids[0])
    let items = model.tabItems(ids[1])
    #expect(items.map(\.title) == ["固定", "颜色", "浮在屏幕上", "归档", "删除"])
    #expect(items.map(\.section) == [0, 0, 0, 1, 1] && items.map(\.isDestructive).last == true)
    // 颜色那一级：8 种，每项前面纸色圆点，现在的那种打勾（同一份表）
    let colors = try #require(items[1].submenu)
    #expect(
      colors.count == Note.colorCount + 1
        && colors.prefix(Note.colorCount).allSatisfy { $0.image != nil })
    #expect(
      colors.prefix(Note.colorCount).map(\.isChecked)
        == (0..<Note.colorCount).map { $0 == store.note(ids[1])?.color })
    #expect(colors.last?.title == NotePaper.otherColorTitle && colors.last?.section == 2)
    items[0].run()
    #expect(store.note(ids[1])?.isPinned == true && store.note(ids[0])?.isPinned == false)
    #expect(model.tabItems(ids[1])[0].title == "取消固定")
    colors[5].run()
    #expect(store.note(ids[1])?.color == 5 && model.state.openID == ids[0])
    // 浮在屏幕上：没打开的交给浮动便签（toggleFloat），开着的走操作菜单那条路（从它现在的位置浮出去）
    items[2].run()
    model.tabItems(ids[0])[2].run()
    #expect(toggled == [ids[1]] && floatedOpen == [ids[0]])
    model.floated([ids[1]])
    #expect(model.tabItems(ids[1])[2].title == "收回边缘")
    model.tabItems(ids[1])[2].run()
    #expect(toggled == [ids[1], ids[1]])
    // 归档没打开的那条：开着的不动；归档了的不在那叠里，右键没有菜单
    model.tabItems(ids[2])[3].run()
    #expect(store.note(ids[2])?.isArchived == true && model.state.openID == ids[0])
    #expect(model.tabItems(ids[2]).isEmpty)
    // 删除开着的那条：先关掉（回到那一列）
    model.tabItems(ids[0])[4].run()
    #expect(store.note(ids[0])?.deletedAt != nil && model.state.openID == nil)
    #expect(model.state.phase == .fanned)
    // 旁白的自定义动作用的那一份只看传进来的值
    let floating = model.tabItems(try #require(store.note(ids[1])), isFloating: true)
    #expect(floating.map(\.title) == ["取消固定", "颜色", "收回边缘", "归档", "删除"])
  }

  /// 右键标签列的空白处、「+」、药丸：同一份三项（新建便签、全部便签、设置…），前面是图；新建的就在这一叠里打开
  @Test func edgeMenuIsTheSameEverywhere() throws {
    let (model, store, _) = try make(["甲"])
    var (notes, settings) = (0, 0)
    model.showNotes = { notes += 1 }
    model.showSettings = { settings += 1 }
    let items = model.edgeItems
    #expect(items.map(\.title) == ["新建便签", "全部便签", "设置…"])
    #expect(items.map(\.section) == [0, 0, 1] && items.allSatisfy { $0.image != nil })
    items[1].run()
    items[2].run()
    #expect(notes == 1 && settings == 1)
    items[0].run()
    #expect(store.active.count == 2 && model.state.openID == store.active.first?.id)
    // 系统菜单（药丸的右键也是这一份）：三项、一条分隔线，每项都有图
    let menu = NSMenu.of(items)
    #expect(menu.items.map(\.title) == ["新建便签", "全部便签", "", "设置…"])
    #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
  }

  /// ⌘,、操作菜单的「便签设置…」：打开设置的「便签」页；那叠里打开的便签先收起（它在浮动层级，会压在设置窗上）
  @Test func settingsFromTheDeck() throws {
    let (model, _, ids) = try make(["甲", "乙"])
    var settings = 0
    model.showSettings = { settings += 1 }
    model.send(Self.enter)
    model.tapTab(ids[0])
    model.toggleMenu()
    #expect(model.menuItems.last?.title == "便签设置…" && model.menuItems.last?.shortcut == "⌘,")
    #expect(model.menuItems.last?.symbol == NotesWindowModel.settingsSymbol)
    model.run(try #require(model.menuItems.last))
    #expect(settings == 1 && model.state.phase == .rest && model.menu == nil)
    model.send(Self.enter)
    model.tapTab(ids[1])
    #expect(try model.handleKeyEquivalent(key(kVK_ANSI_Comma, .command)))
    #expect(settings == 2 && model.state.phase == .rest)
    // 那叠收着时不接（面板不是 key，也到不了这里）
    #expect(try !model.handleKeyEquivalent(key(kVK_ANSI_Comma, .command)))
  }

  /// 右键菜单开着时这一列不收：鼠标出了热区不算走了（菜单长在列外面）；关了照常——鼠标不在热区里就收
  /// （这里的那叠在屏幕外，鼠标永远不在它的热区里）
  @Test func columnStaysWhileAMenuIsOpen() async throws {
    let deck = try offscreenDeck(["一"])
    defer { deck.close() }
    var activity = 0
    let reported = deck.model.onActivity
    deck.model.onActivity = {
      activity += 1
      reported()
    }
    deck.model.menuShown(true)
    #expect(deck.model.isShowingMenu && activity == 0)
    deck.pill?.onEnter(false)
    #expect(deck.model.state.phase == .fanned && !deck.isAwaitingLeave)
    try await Task.sleep(for: .milliseconds(400))
    #expect(deck.model.state.phase == .fanned)
    deck.model.menuShown(false)
    #expect(!deck.model.isShowingMenu && activity == 1 && deck.isAwaitingLeave)
    for _ in 0..<500 where deck.model.state.phase != .rest {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(deck.model.state.phase == .rest)
  }
}
