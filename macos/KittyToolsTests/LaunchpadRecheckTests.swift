// 复查后第二轮（FIXES-2，2026-10-18）的锁定测试：每条对应清单里的一项（测试名后的 G 编号）。
// 屏外建 model / 面板 / 窗口，不 makeKey；G1 不注册真的触控板回调，只在后台线程上直接调那个 C 回调、装假的桥；
// G29 的真拖动、2026-10-18 真机反馈后的「点到的范围」是进程内 `window.sendEvent`（不发系统事件、不动用户的鼠标）。

import AppKit
import SwiftUI
import Synchronization
import Testing

@testable import KittyTools

/// 串行跑：后面几条在屏外窗口里送真的鼠标事件，几条一起跑会在 await 处交错——整个 App 只有一个指针，
/// 一个窗口拖到一半另一个窗口按下去，SwiftUI 的手势会被搅乱（真机上不会有两个指针）
@Suite(.serialized)
@MainActor
struct LaunchpadRecheckTests {
  private func ref(_ name: String) -> LaunchpadAppRef {
    LaunchpadAppRef(bundleID: "com.example.\(name)", path: "/Applications/\(name).app")
  }

  private func app(_ ref: LaunchpadAppRef, category: String? = nil) -> LaunchpadProjectApp {
    let name = ref.bundleID ?? ref.path
    return LaunchpadProjectApp(
      id: ref.id, ref: ref,
      item: LauncherItem(
        kind: .app, target: ref.path, title: name, subtitle: "应用程序",
        names: [LauncherMatch.fold(name)], initials: [LauncherMatch.initials(name)]),
      url: URL(filePath: ref.path), isSystem: false, inUtilities: false, isAppStore: false,
      category: category)
  }

  private func model(
    _ layout: LaunchpadLayout, catalog: [LaunchpadProjectApp]? = nil, columns: Int = 3,
    rows: Int = 2
  ) -> LaunchpadModel {
    LaunchpadModel(
      layout: layout, catalog: catalog ?? layout.apps.map { app($0) }, icons: LaunchpadIcons(),
      columns: columns, rows: rows, screenSize: CGSize(width: 900, height: 600))
  }

  /// 照真界面喂网格框：全宽的页容器（网格在里面居中、两边各留 side）
  private func grid(_ model: LaunchpadModel, page: Int) -> CGRect {
    let frame = CGRect(x: 0, y: 0, width: 900, height: model.metrics.gridHeight)
    model.gridFrames[page] = frame
    return frame
  }

  private func center(_ index: Int, in frame: CGRect, of model: LaunchpadModel) -> CGPoint {
    let rect = LaunchpadModel.cellRect(index, in: frame, metrics: model.metrics)
    return CGPoint(x: rect.midX, y: rect.midY)
  }

  private func waitForCombine(_ model: LaunchpadModel) async {
    for _ in 0..<60 where model.drag?.combineTileID == nil {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  // MARK: G1 触控板回调的线程

  /// 框架是在它自己的线程上调回调的：在后台线程上直接调那个 C 回调，不能 trap（修之前整个测试进程会崩）
  @Test func contactCallbackRunsOnABackgroundThread() async {
    let bridge = TouchpadBridge(sensitivity: .standard) { _ in }
    TouchpadWatcher.installBridgeForTesting(bridge)
    defer { TouchpadWatcher.installBridgeForTesting(nil) }
    let callback = TouchpadWatcher.contactCallbackForTesting
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4 * 96, alignment: 8)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 4 * 96)
        let device = UnsafeMutableRawPointer(bitPattern: 0x10)
        _ = callback(device, buffer, 4, 1, 1)
        // 全抬起来的空帧也要能进
        _ = callback(device, nil, 0, 1.01, 2)
        buffer.deallocate()
        continuation.resume()
      }
    }
    #expect(bridge.frames.withLock { $0 } == 2)
  }

  // MARK: G2 刚启动、目录还没扫出来

  @Test func openingBeforeCatalogScanKeepsStoredLayout() {
    let stored = LaunchpadLayout(pages: [[.app(ref("a")), .app(ref("b"))], [.app(ref("c"))]])
    let plan = LaunchpadLayout.openingPlan(
      stored: .loaded(stored), apps: [], defaults: [], capacity: 35)
    #expect(plan.layout == stored)
    #expect(plan.shouldSave == false)
    #expect(stored.merged(apps: [], capacity: 35) == stored)
  }

  // MARK: G3 合成的目标就是指针下面画着的那个

  @Test func dropTargetKeepsTheIconUnderThePointer() {
    // 拿掉被拖那格后是 [b c d]，空位在 0：画出来是 [_ b c d]
    var hit = LaunchpadModel.dropTarget(cell: 0, zone: .center, gap: 0, count: 3)
    #expect(hit.target == nil && hit.combine == nil)
    hit = LaunchpadModel.dropTarget(cell: 2, zone: .center, gap: 0, count: 3)
    #expect(hit.target == nil && hit.combine == 1)  // 第 2 格画的是 c（列表第 1 个）
    hit = LaunchpadModel.dropTarget(cell: 2, zone: .before, gap: 0, count: 3)
    #expect(hit.target == 1 && hit.combine == nil)  // 插到 c 前面：空位挪到 1，c 还画在第 2 格
    hit = LaunchpadModel.dropTarget(cell: 2, zone: .after, gap: 0, count: 3)
    #expect(hit.target == 2)
    // 空位在后面时，前面的格子就是列表里同一个下标
    hit = LaunchpadModel.dropTarget(cell: 1, zone: .center, gap: 3, count: 3)
    #expect(hit.combine == 1)
    // 最后一个后面的空格：放末尾
    hit = LaunchpadModel.dropTarget(cell: 5, zone: .before, gap: 0, count: 3)
    #expect(hit.target == 3)
  }

  @Test func combineTargetStaysUnderPointer() async {
    let refs = ["a", "b", "c", "d"].map(ref)
    let model = model(LaunchpadLayout(pages: [refs.map { LaunchpadTile.app($0) }]))
    let frame = grid(model, page: 0)
    model.beginDrag(
      tile: .app(refs[0]), appID: refs[0].id, folder: nil, at: center(0, in: frame, of: model))
    model.updateDrag(location: center(2, in: frame, of: model), pageWidth: 900)
    await waitForCombine(model)
    #expect(model.drag?.combineTileID == LaunchpadTile.app(refs[2]).id)
    // 指针下面那一格画的就是它（原来是空位，c 被挤到旁边一格）
    #expect(model.previewTiles(page: 0)[safe: 2]??.id == LaunchpadTile.app(refs[2]).id)
    model.endDrag()
    #expect(
      model.layout.tiles.compactMap(\.folder).first?.apps.map(\.id) == [refs[2].id, refs[0].id])
  }

  /// 第 2 页、第 3 行（SPEC §8：只测第一页第一行的会漏）
  @Test func combineTargetOnSecondPageThirdRow() async {
    let source = ref("x")
    let targets = (0..<9).map { ref("t\($0)") }
    let model = model(
      LaunchpadLayout(pages: [[.app(source)], targets.map { LaunchpadTile.app($0) }]),
      columns: 3, rows: 3)
    let frame = grid(model, page: 1)
    model.beginDrag(tile: .app(source), appID: source.id, folder: nil, at: CGPoint(x: 10, y: 10))
    model.go(to: 1)
    model.updateDrag(location: center(7, in: frame, of: model), pageWidth: 900)
    await waitForCombine(model)
    #expect(model.drag?.combineTileID == LaunchpadTile.app(targets[7]).id)
    #expect(model.previewTiles(page: 1)[safe: 7]??.id == LaunchpadTile.app(targets[7]).id)
  }

  /// 从图标的边上挪过来、再进它的中心：它不被空位挤走（原来会一直追着指针跑）
  @Test func approachingAnIconFromItsEdgeDoesNotChaseIt() async {
    let refs = ["a", "b", "c", "d", "e", "f"].map(ref)
    let model = model(LaunchpadLayout(pages: [refs.map { LaunchpadTile.app($0) }]))
    let frame = grid(model, page: 0)
    let rect = LaunchpadModel.cellRect(4, in: frame, metrics: model.metrics)
    model.beginDrag(
      tile: .app(refs[0]), appID: refs[0].id, folder: nil, at: center(0, in: frame, of: model))
    // 先到 e 那一格的左边沿（插到 e 前面），再进 e 的中心
    model.updateDrag(location: CGPoint(x: rect.minX + 4, y: rect.midY), pageWidth: 900)
    model.updateDrag(location: CGPoint(x: rect.midX, y: rect.midY), pageWidth: 900)
    await waitForCombine(model)
    #expect(model.drag?.combineTileID == LaunchpadTile.app(refs[4]).id)
    #expect(model.previewTiles(page: 0)[safe: 4]??.id == LaunchpadTile.app(refs[4]).id)
  }

  // MARK: G4 文件夹面板的格子

  @Test func folderCellsFitIconAndOneLineName() {
    let font = NSFont.systemFont(ofSize: 11)
    let line = ceil(
      NSAttributedString(string: "AI Rules Manager", attributes: [.font: font]).size().height)
    #expect(line <= LaunchpadMetrics.folderLabelHeight)
    for size in [
      CGSize(width: 1280, height: 800), CGSize(width: 1512, height: 982),
      CGSize(width: 2560, height: 1440),
    ] {
      let metrics = LaunchpadMetrics(size: size, columns: 7, rows: 5)
      // 图标的选中底（1.2 倍）+ 间距 + 一行名字放得进格子高；选中底放得进格子宽；名字比格子窄
      #expect(
        metrics.folderCellHeight
          >= metrics.folderIcon * 1.2 + LaunchpadMetrics.folderLabelSpacing
          + LaunchpadMetrics.folderLabelHeight, "\(size)")
      #expect(metrics.folderCellWidth >= metrics.folderIcon * 1.2, "\(size)")
      #expect(metrics.folderLabelWidth < metrics.folderCellWidth, "\(size)")
      #expect(metrics.folderGridWidth + 52 <= size.width, "\(size)")
    }
  }

  // MARK: G5 系统手势的几个域

  @Test func systemGestureDomainsCombine() throws {
    #expect(TrackpadSystemGesture.combined([false, nil]) == false)
    #expect(TrackpadSystemGesture.combined([nil, nil]) == true)
    #expect(TrackpadSystemGesture.combined([true, false]) == true)
    #expect(TrackpadSystemGesture.combined([nil, true]) == true)
    let suite = "launchpad.recheck.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(TrackpadSystemGesture.pinchSetting(defaults) == nil)
    defaults.set(0, forKey: TrackpadSystemGesture.fourFingerKey)
    defaults.set(0, forKey: TrackpadSystemGesture.fiveFingerKey)
    #expect(TrackpadSystemGesture.pinchSetting(defaults) == false)
  }

  // MARK: G6 / G7 触发角

  @Test func cornerSensorPaintsAFaintBackground() {
    let panel = LaunchpadCorner.makeSensorPanel(
      frame: CGRect(x: -20000, y: -20000, width: LaunchpadCorner.size, height: LaunchpadCorner.size)
    )
    #expect(panel.alphaValue == 1)
    #expect((panel.backgroundColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0) > 0)
    #expect(panel.level.rawValue >= NSWindow.Level.statusBar.rawValue)
    #expect(panel.sharingType == .none)
    #expect(!panel.ignoresMouseEvents)
    #expect(!panel.isVisible)
  }

  @Test func cornerDoesNotRearmWhileLaunchpadIsOpen() {
    var arm = CornerArm()
    let first = arm.trigger()
    #expect(first)
    // 启动台开着时全屏面板盖住了角：这时的「离开」不算
    arm.mouseExited(launchpadOpen: true)
    let whileOpen = arm.trigger()
    #expect(!whileOpen)
    arm.mouseExited(launchpadOpen: false)
    let afterLeaving = arm.trigger()
    #expect(afterLeaving)
    // 系统设置里选「—」写的是 1：不算占用
    #expect(!LaunchpadCorner.systemCornerIsOn(.bottomRight, dock: ["wvous-br-corner": 1]))
    #expect(!LaunchpadCorner.systemCornerIsOn(.bottomRight, dock: ["wvous-br-corner": 0]))
    #expect(LaunchpadCorner.systemCornerIsOn(.bottomRight, dock: ["wvous-br-corner": 2]))
  }

  // MARK: G8 设置页只在系统手势变了时重起监听

  @Test func settingsReappliesOnlyWhenSystemGestureChanges() {
    #expect(!LaunchpadTab.shouldReapply(old: true, new: true))
    #expect(!LaunchpadTab.shouldReapply(old: false, new: false))
    #expect(LaunchpadTab.shouldReapply(old: true, new: false))
  }

  // MARK: G9 焦点还给搜索框

  @Test func searchFocusReturnsAfterFolderAndJiggle() async throws {
    let folder = LaunchpadFolder(name: "X", pages: [[ref("a"), ref("b")]])
    let model = model(LaunchpadLayout(pages: [[.folder(folder), .app(ref("c"))]]))
    let panel = LaunchpadPanel(
      frame: NSRect(x: -20000, y: -20000, width: 900, height: 600), model: model)
    model.onSearchFocus = { [weak panel] focused in panel?.setSearchFocus(focused) }
    panel.orderFront(nil)
    defer { panel.orderOut(nil) }
    for _ in 0..<20 where panel.initialFirstResponder == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    let field = try #require(panel.initialFirstResponder)
    func searchFocused() -> Bool {
      guard let responder = panel.firstResponder else { return false }
      if responder === field { return true }
      return ((responder as? NSTextView)?.delegate as? NSView) === field
    }
    panel.setSearchFocus(true)
    #expect(searchFocused())
    model.openFolder(folder.id)
    #expect(!searchFocused())
    model.closeFolder()
    #expect(searchFocused())
    model.enterJiggle(byOption: true)
    #expect(!searchFocused())
    model.exitJiggle()
    #expect(searchFocused())
    #expect(!panel.isKeyWindow)
  }

  // MARK: G10 最后一页再往右 = 新开一页

  @Test func holdingAtTheRightEdgeOfTheLastPageMakesANewPage() async {
    let refs = ["a", "b", "c"].map(ref)
    let model = model(LaunchpadLayout(pages: [refs.map { LaunchpadTile.app($0) }]))
    _ = grid(model, page: 0)
    model.beginDrag(tile: .app(refs[0]), appID: refs[0].id, folder: nil, at: CGPoint(x: 300, y: 80))
    model.updateDrag(location: CGPoint(x: 890, y: 80), pageWidth: 900)
    for _ in 0..<60 where model.drag?.appendsPage != true {
      try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.drag?.appendsPage == true)
    model.endDrag()
    #expect(model.layout.pages.count == 2)
    #expect(model.layout.pages.last?.map(\.id) == [LaunchpadTile.app(refs[0]).id])
  }

  // MARK: G11 拖文件夹不合成

  @Test func draggingAFolderOverAnAppCenterStillMovesIt() async {
    let folder = LaunchpadFolder(name: "X", pages: [[ref("a"), ref("b")]])
    let c = ref("c")
    let d = ref("d")
    let model = model(LaunchpadLayout(pages: [[.folder(folder), .app(c), .app(d)]]))
    let frame = grid(model, page: 0)
    model.beginDrag(
      tile: .folder(folder), appID: nil, folder: nil, at: center(0, in: frame, of: model))
    let rect = LaunchpadModel.cellRect(2, in: frame, metrics: model.metrics)
    model.updateDrag(location: CGPoint(x: rect.midX + 2, y: rect.midY), pageWidth: 900)
    try? await Task.sleep(for: .milliseconds(500))
    #expect(model.drag?.combineTileID == nil)
    model.endDrag()
    #expect(
      model.layout.tiles.map(\.id) == [
        LaunchpadTile.app(c).id, LaunchpadTile.app(d).id, LaunchpadTile.folder(folder).id,
      ])
  }

  // MARK: G12 文件夹的名字（生产用的那个函数）

  @Test func folderNameFallsBackToTheSecondCategory() {
    let plain = app(ref("a"))
    let office = app(ref("b"), category: "效率")
    #expect(LaunchpadCatalog.folderName(first: plain, second: office) == "效率")
    #expect(LaunchpadCatalog.folderName(first: office, second: plain) == "效率")
    #expect(LaunchpadCatalog.folderName(first: plain, second: plain) == "未命名")
  }

  // MARK: G13 翻页快甩

  @Test func pagerIgnoresFirstFrameSpikeAndBackwardFlick() {
    var tap = LaunchpadPager()
    _ = tap.feed(delta: -6, time: 1, pageWidth: 900, canBack: true, canForward: true)
    #expect(tap.finish(canBack: true, canForward: true, pageWidth: 900, time: 1.005) == 0)
    // 往左拖 100、再往右快甩回来：不该翻到下一页
    var back = LaunchpadPager()
    _ = back.feed(delta: -100, time: 1, pageWidth: 900, canBack: true, canForward: true)
    _ = back.feed(delta: 30, time: 1.01, pageWidth: 900, canBack: true, canForward: true)
    _ = back.feed(delta: 30, time: 1.02, pageWidth: 900, canBack: true, canForward: true)
    #expect(back.finish(canBack: true, canForward: true, pageWidth: 900, time: 1.025) != 1)
    // 快拖一小段、停住再抬：不算快甩
    var held = LaunchpadPager()
    _ = held.feed(delta: -30, time: 1, pageWidth: 900, canBack: true, canForward: true)
    _ = held.feed(delta: -30, time: 1.01, pageWidth: 900, canBack: true, canForward: true)
    _ = held.feed(delta: -30, time: 1.02, pageWidth: 900, canBack: true, canForward: true)
    #expect(held.finish(canBack: true, canForward: true, pageWidth: 900, time: 1.3) == 0)
  }

  // MARK: G14 搜索时点布局里还没有的新 App

  @Test func clickingASearchResultMissingFromTheLayoutOpensIt() {
    let old = ref("oldword")
    let fresh = ref("freshword")
    let model = model(
      LaunchpadLayout(pages: [[.app(old)]]), catalog: [app(old), app(fresh)])
    var opened: String?
    model.onOpenApp = { opened = $0.id }
    var settled = 0
    model.onSettled = { settled += 1 }
    model.query = "freshword"
    guard let result = model.currentTiles.first else {
      Issue.record("搜不到刚装的那个")
      return
    }
    model.beginDrag(tile: result, appID: result.app?.id, folder: nil, at: CGPoint(x: 100, y: 100))
    model.endDrag()
    #expect(opened == fresh.id)
    #expect(settled >= 1)
    let before = settled
    model.query = ""
    #expect(settled == before + 1)
  }

  // MARK: G15 抖动的转轴

  @Test func jiggleRotatesAroundTheIconCenter() {
    let size = CGSize(width: 60, height: 60)
    for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0)] {
      let transform = LaunchpadJiggle.transform(degrees: 1.5, size: size, anchor: anchor)
      // 图层的变换以 anchor 为原点：图标中心在 ((0.5 − ax)·w, (0.5 − ay)·h)
      let middle = CGPoint(x: (0.5 - anchor.x) * size.width, y: (0.5 - anchor.y) * size.height)
      let moved = middle.applying(transform)
      #expect(abs(moved.x - middle.x) < 0.0001 && abs(moved.y - middle.y) < 0.0001, "\(anchor)")
      let corner = CGPoint(x: -anchor.x * size.width, y: -anchor.y * size.height)
      let turned = corner.applying(transform)
      #expect(hypot(turned.x - corner.x, turned.y - corner.y) > 0.1, "\(anchor)")
    }
  }

  // MARK: G17 按框架的偏移读触点

  @Test func touchesAreReadAtTheFrameworkOffsets() {
    #expect(MemoryLayout<MTFinger>.offset(of: \.zTotal) == 48)
    #expect(MemoryLayout<MTFinger>.offset(of: \.angle) == 56)
    #expect(MemoryLayout<MTFinger>.offset(of: \.absoluteX) == 68)
    #expect(MemoryLayout<MTFinger>.offset(of: \.zDensity) == 92)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4 * 96, alignment: 8)
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 4 * 96)
    defer { buffer.deallocate() }
    // 按框架的偏移写（不经过 MTFinger），再走回调里那段读法
    for index in 0..<4 {
      let base = index * 96
      buffer.storeBytes(of: Int32(10 + index), toByteOffset: base + 16, as: Int32.self)
      buffer.storeBytes(of: Int32(4), toByteOffset: base + 20, as: Int32.self)
      buffer.storeBytes(of: Float(index) * 0.1, toByteOffset: base + 32, as: Float.self)
      buffer.storeBytes(of: Float(index) * 0.2, toByteOffset: base + 36, as: Float.self)
    }
    let touches = TouchpadWatcher.touches(from: buffer, count: 4)
    #expect(touches.map(\.id) == [10, 11, 12, 13])
    #expect(touches.allSatisfy { $0.state == 4 })
    #expect(abs(touches[3].x - 0.3) < 0.0001 && abs(touches[3].y - 0.6) < 0.0001)
  }

  // MARK: G22 设置导入里的布局

  @Test func archivedLayoutIsNormalizedAndEmptyOnesRejected() throws {
    let messy = LaunchpadLayout(pages: [[.app(ref("a")), .app(ref("a")), .app(ref("b"))]])
    let text = try #require(messy.jsonString())
    let clean = LaunchpadLayout(pages: [[.app(ref("a")), .app(ref("b"))]])
    #expect(SettingsArchive.layoutText(.string(text)) == clean.jsonString())
    let empty = try #require(LaunchpadLayout(pages: []).jsonString())
    #expect(SettingsArchive.layoutText(.string(empty)) == nil)
  }

  // MARK: G29 真的 SwiftUI 拖动（进程内送事件）

  @Test func realGestureClickOpensAndDragReorders() async throws {
    let refs = ["a", "b", "c", "d", "e", "f"].map(ref)
    let model = model(LaunchpadLayout(pages: [refs.map { LaunchpadTile.app($0) }]))
    var opened: String?
    model.onOpenApp = { opened = $0.id }
    let live = LiveLaunchpad(model)
    defer { live.close() }
    let frame = try #require(await live.gridFrame())
    // 单击 b：打开 b
    await live.click(center(1, in: frame, of: model))
    #expect(opened == refs[1].id)
    #expect(model.drag == nil)
    // 把 a 拖到 e 那一格的左边沿松手：挪到 e 前面，不建文件夹，手势收得到松手
    let start = center(0, in: frame, of: model)
    let edge = LaunchpadModel.cellRect(4, in: frame, metrics: model.metrics)
    let target = CGPoint(x: edge.minX + 6, y: edge.midY)
    await live.send(.leftMouseDown, start)
    for step in 1...10 {
      let t = CGFloat(step) / 10
      await live.send(
        .leftMouseDragged,
        CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
    }
    await live.send(.leftMouseUp, target)
    #expect(model.drag == nil)
    #expect(model.layout.tiles.allSatisfy { $0.folder == nil })
    #expect(
      model.layout.tiles.map(\.id)
        == ["b", "c", "d", "a", "e", "f"].map { LaunchpadTile.app(ref($0)).id })
  }

  // MARK: 2026-10-18 真机反馈：点到的范围

  /// 只有点到图标才打开：图标旁边的空处、名字上都不算（点空处 = 点背景，收起；收起后界面淡掉、不再收点击，
  /// 所以每种点法各用一块新的界面）。图标的位置按界面里真的 NSImageView 量，不按算式猜
  @Test func onlyTheIconOpensTheApp() async throws {
    let refs = ["a", "b", "c"].map(ref)
    func attempt(_ point: (CGRect) -> CGPoint) async throws -> (opened: [String], closed: Int) {
      let model = model(LaunchpadLayout(pages: [refs.map { LaunchpadTile.app($0) }]))
      var opened: [String] = []
      var closed = 0
      model.onOpenApp = { opened.append($0.id) }
      model.onClose = { closed += 1 }
      let live = LiveLaunchpad(model)
      defer { live.close() }
      _ = try #require(await live.gridFrame())
      let icons = live.iconRects()
      #expect(icons.count == 3)
      let icon = try #require(icons[safe: 1])
      await live.click(point(icon))
      return (opened, closed)
    }
    // 图标里面、靠近角上：打开
    let inside = try await attempt { CGPoint(x: $0.maxX - 4, y: $0.minY + 4) }
    #expect(inside.opened == [refs[1].id] && inside.closed == 0)
    // 图标右边、名字那么宽的范围里（原来整块都算点到）
    let beside = try await attempt { CGPoint(x: $0.maxX + 20, y: $0.midY) }
    #expect(beside.opened.isEmpty && beside.closed == 1)
    // 名字上：图标下面隔着选中底的留白（0.11 个图标）和 6 pt，再往下半行字
    let label = try await attempt { CGPoint(x: $0.midX, y: $0.maxY + $0.height * 0.11 + 6 + 6) }
    #expect(label.opened.isEmpty && label.closed == 1)
  }

  /// 文件夹名只有字那一块能点进编辑：同一行字外面的空处 = 点背景（收起文件夹），点字上不收
  @Test func onlyTheFolderTitleTextStartsEditing() async throws {
    let refs = ["a", "b", "c"].map(ref)
    let folder = LaunchpadFolder(name: "工具", pages: [refs])
    let model = model(LaunchpadLayout(pages: [[.folder(folder)]]))
    let live = LiveLaunchpad(model)
    defer { live.close() }
    _ = await live.gridFrame()
    model.openFolder(folder.id)
    for _ in 0..<20 where model.folderPanelFrame.isEmpty { await live.settle() }
    await live.settle()
    let panel = model.folderPanelFrame
    #expect(!panel.isEmpty)
    // 名字那一行：面板上方 18 + 半行（28 pt 字约 34 高）
    let rowY = panel.minY - 18 - 18
    await live.click(CGPoint(x: panel.midX, y: rowY))
    for _ in 0..<10 where !(live.window.firstResponder is NSText) { await live.settle() }
    #expect(model.openFolderID == folder.id)
    #expect(live.window.firstResponder is NSText)
    // 同一行、离字远的地方（原来整行宽都是输入框）
    await live.click(CGPoint(x: panel.minX + 60, y: rowY))
    #expect(model.openFolderID == nil)
  }
}

/// 屏外窗口里的真启动台界面，进程内 `window.sendEvent` 送鼠标事件（不发系统事件、不动用户的鼠标，不当 key）
@MainActor
private struct LiveLaunchpad {
  let window: NSWindow
  let host: FirstMouseHost
  let model: LaunchpadModel
  let size: NSSize

  init(_ model: LaunchpadModel, size: NSSize = NSSize(width: 900, height: 600)) {
    self.model = model
    self.size = size
    host = FirstMouseHost(
      rootView: AnyView(
        LaunchpadView(model: model).frame(width: size.width, height: size.height)))
    host.frame = NSRect(origin: .zero, size: size)
    window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
  }

  func close() { window.orderOut(nil) }

  /// 等第一页画出来、量到网格框
  func gridFrame() async -> CGRect? {
    for _ in 0..<20 where model.gridFrames[0] == nil {
      try? await Task.sleep(for: .milliseconds(50))
    }
    return model.gridFrames[0]
  }

  /// 让界面真的更新、重排一遍（真机上两次鼠标事件之间界面都会重画；不这么做的话，拖动一激活就把
  /// 挂着手势的那一格换掉、手势被取消这类问题在单测里看不出来）
  func settle() async {
    // 按轮数等（不按墙钟猜）：几轮「让出主线程 → 重排 → 重画」，第一次起测试宿主时也够
    for _ in 0..<3 {
      try? await Task.sleep(for: .milliseconds(15))
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
    }
  }

  func send(_ type: NSEvent.EventType, _ point: CGPoint) async {
    if let event = NSEvent.mouseEvent(
      with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    {
      window.sendEvent(event)
    }
    await settle()
  }

  /// 界面里每个 App 图标（NSImageView）在窗口里的位置（左上角为原点），按先行后列排
  func iconRects() -> [CGRect] {
    func images(in view: NSView) -> [NSImageView] {
      view.subviews.flatMap { ($0 as? NSImageView).map { [$0] } ?? images(in: $0) }
    }
    return images(in: host).map { image in
      let rect = image.convert(image.bounds, to: nil)
      return CGRect(
        x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }
    .filter { $0.width > 1 }
    .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
  }

  func click(_ point: CGPoint) async {
    await send(.leftMouseDown, point)
    await send(.leftMouseUp, point)
  }
}

/// 进程内送鼠标事件用：第一下点击就给内容（屏外窗口不当 key）
private final class FirstMouseHost: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
