// 交互对齐 macOS 15 的那一轮（2026-10-18，方案 build/research/launchpad/INTERACT.md）：让位停一下才动、松手执行屏上的排法、
// 一拖就抖、停在文件夹上打开它并放进任意一格、拖出文件夹接着在主网格里拖、边上连续翻页、松手滑进落点、空白处拖着翻页、
// 翻页门槛 20%。最后两条在屏外窗口里进程内送真鼠标事件（不发系统事件、不动用户的鼠标），所以整套串行跑。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

@Suite(.serialized)
@MainActor
struct LaunchpadInteractTests {
  private func ref(_ name: String) -> LaunchpadAppRef {
    LaunchpadAppRef(bundleID: "com.example.\(name)", path: "/Applications/\(name).app")
  }

  private func app(_ ref: LaunchpadAppRef) -> LaunchpadProjectApp {
    let name = ref.bundleID ?? ref.path
    return LaunchpadProjectApp(
      id: ref.id, ref: ref,
      item: LauncherItem(
        kind: .app, target: ref.path, title: name, subtitle: "应用程序",
        names: [LauncherMatch.fold(name)], initials: [LauncherMatch.initials(name)]),
      url: URL(filePath: ref.path), isSystem: false, inUtilities: false, isAppStore: false,
      category: nil)
  }

  private func model(
    _ layout: LaunchpadLayout, timing: LaunchpadDragTiming = .macOS15
  ) -> LaunchpadModel {
    let model = LaunchpadModel(
      layout: layout, catalog: layout.apps.map { app($0) }, icons: LaunchpadIcons(), columns: 3,
      rows: 2, screenSize: CGSize(width: 900, height: 600), dragTiming: timing)
    model.gridFrames = Dictionary(
      uniqueKeysWithValues: (0..<max(layout.pageCount, 1)).map {
        ($0, CGRect(x: 0, y: 0, width: 900, height: model.metrics.gridHeight))
      })
    return model
  }

  private func center(_ index: Int, of model: LaunchpadModel) -> CGPoint {
    model.cellCenter(page: model.page, index: index)!
  }

  /// 某一格左半边（插到它前面）
  private func before(_ index: Int, of model: LaunchpadModel) -> CGPoint {
    let rect = LaunchpadModel.cellRect(
      index, in: model.gridFrames[model.page]!, metrics: model.metrics)
    return CGPoint(x: rect.minX + 6, y: rect.midY)
  }

  /// 按轮数等（不按墙钟猜），最多约 2 秒
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func apps(_ names: [String]) -> [LaunchpadTile] { names.map { .app(ref($0)) } }

  // MARK: 让位

  /// 指针到了别的图标边上，要停 0.15 s 别的图标才让位；没停够又挪回空位上就不动
  @Test func reflowWaitsForThePointerToRest() async {
    let model = model(LaunchpadLayout(pages: [apps(["a", "b", "c", "d"])]))
    model.beginDrag(tile: .app(ref("a")), appID: ref("a").id, folder: nil, at: center(0, of: model))
    model.updateDrag(location: before(2, of: model), pageWidth: 900)
    #expect(model.drag?.targetIndex == 0)
    await waitUntil { model.drag?.targetIndex == 1 }
    #expect(model.drag?.targetIndex == 1)
    // 又挪到 d 的左边、马上回到空位上：不让位
    model.updateDrag(location: before(3, of: model), pageWidth: 900)
    model.updateDrag(location: center(1, of: model), pageWidth: 900)
    try? await Task.sleep(for: .milliseconds(300))
    #expect(model.drag?.targetIndex == 1)
    model.cancelDrag()
  }

  /// 松手执行屏上正显示的排法：落点还没换上去（没停够）就松手 = 放回原处
  @Test func releaseCommitsWhatIsShown() {
    let layout = LaunchpadLayout(pages: [apps(["a", "b", "c", "d"])])
    let model = model(layout)
    model.beginDrag(tile: .app(ref("a")), appID: ref("a").id, folder: nil, at: center(0, of: model))
    model.updateDrag(location: before(3, of: model), pageWidth: 900)
    model.endDrag()
    #expect(model.layout == layout)
  }

  // MARK: 抖动、跟手、落位

  /// 一拖起来就进抖动，松手后接着抖；跟手那一份按下时指针在图标哪儿就一直在哪儿；松手后它滑进落点再消失
  @Test func dragJigglesKeepsGrabOffsetAndLands() async {
    let model = model(LaunchpadLayout(pages: [apps(["a", "b", "c"])]), timing: .immediate)
    let origin = center(0, of: model)
    let press = CGPoint(x: origin.x + 12, y: origin.y - 8)
    model.beginDrag(
      tile: .app(ref("a")), appID: ref("a").id, folder: nil, at: press, origin: origin)
    #expect(!model.jiggling)
    let point = CGPoint(x: press.x + 100, y: press.y + 40)
    model.updateDrag(location: point, pageWidth: 900)
    #expect(model.jiggling)
    let drag = try! #require(model.drag)
    #expect(model.ghostCenter(drag) == CGPoint(x: origin.x + 100, y: origin.y + 40))
    model.updateDrag(location: before(2, of: model), pageWidth: 900)
    model.endDrag()
    #expect(model.jiggling)
    #expect(model.layout.tiles.map(\.id) == apps(["b", "a", "c"]).map(\.id))
    #expect(model.landing?.tile.id == LaunchpadTile.app(ref("a")).id)
    await waitUntil { model.landing == nil }
    #expect(model.landing == nil)
  }

  // MARK: 边上翻页

  /// 停在右边 60 pt 里：停够翻一页，一直停着接着翻（不用挪一下）
  @Test func holdingAtTheEdgeKeepsTurning() async {
    var timing = LaunchpadDragTiming.immediate
    timing.edgeDwell = .milliseconds(20)
    timing.edgeRepeat = .milliseconds(40)
    let pages = (0..<4).map { page in apps(["p\(page)a", "p\(page)b"]) }
    let model = model(LaunchpadLayout(pages: pages), timing: timing)
    model.beginDrag(
      tile: .app(ref("p0a")), appID: ref("p0a").id, folder: nil, at: center(0, of: model))
    model.updateDrag(location: CGPoint(x: 900 - 40, y: 200), pageWidth: 900)
    await waitUntil { model.page >= 2 }
    #expect(model.page >= 2)
    model.cancelDrag()
  }

  // MARK: 文件夹

  /// 停在文件夹上：先出合成底板，再停一会儿文件夹打开；放进里面第一格前面
  @Test func hoveringAFolderOpensItAndDropsInside() async {
    var timing = LaunchpadDragTiming.immediate
    timing.combine = .milliseconds(20)
    timing.folderOpen = .milliseconds(30)
    let folder = LaunchpadFolder(name: "X", pages: [[ref("x"), ref("y")]])
    let model = model(
      LaunchpadLayout(pages: [[.app(ref("a")), .folder(folder), .app(ref("b"))]]), timing: timing)
    model.beginDrag(tile: .app(ref("b")), appID: ref("b").id, folder: nil, at: center(2, of: model))
    model.updateDrag(location: center(1, of: model), pageWidth: 900)
    await waitUntil { model.openFolderID == folder.id }
    #expect(model.openFolderID == folder.id)
    #expect(model.drag?.isDragging == true)
    #expect(model.folderAnchor != nil)
    // 进面板、到 x 的左半边
    let x = model.folderCellCenter(0)
    model.updateDrag(location: CGPoint(x: x.x - 10, y: x.y), pageWidth: 900)
    #expect(model.drag?.folderTarget == 0)
    #expect(model.folderPreview(page: 0).first == .some(nil))
    model.endDrag()
    #expect(model.openFolderID == folder.id)
    #expect(model.layout.tiles.count == 2)
    #expect(
      model.layout.tiles[1].folder?.apps.map(\.id) == [ref("b").id, ref("x").id, ref("y").id])
  }

  /// 从外面拖进一个满了一行（7 个）的文件夹：面板多画一行放空位，最后一个不会被挤得看不见
  @Test func draggingIntoAFullRowMakesRoom() {
    let inside = (0..<LaunchpadLayout.folderColumns).map { ref("f\($0)") }
    let folder = LaunchpadFolder(name: "X", pages: [inside])
    let model = model(
      LaunchpadLayout(pages: [[.folder(folder), .app(ref("b"))]]), timing: .immediate)
    #expect(model.layout.tiles[0].folder?.apps.count == 7)
    model.beginDrag(tile: .app(ref("b")), appID: ref("b").id, folder: nil, at: center(1, of: model))
    model.updateDrag(location: CGPoint(x: 10, y: 590), pageWidth: 900)
    model.openFolder(folder.id)
    #expect(model.folderRows == 2)
    model.cancelDrag()
    #expect(model.folderRows == 1)
  }

  /// 文件夹里挪：拖到别的图标右半边就插到它后面（同一个文件夹，不解散）
  @Test func reorderInsideAFolder() {
    let folder = LaunchpadFolder(name: "X", pages: [[ref("x"), ref("y"), ref("z")]])
    let model = model(LaunchpadLayout(pages: [[.folder(folder)]]), timing: .immediate)
    model.openFolder(folder.id)
    let start = model.folderCellCenter(0)
    model.beginDrag(
      tile: .app(ref("x")), appID: ref("x").id, folder: folder.id, at: start, origin: start)
    let z = model.folderCellCenter(2)
    model.updateDrag(location: CGPoint(x: z.x + 10, y: z.y), pageWidth: 900)
    // 拿掉 x 之后 z 在第 1 格（画在第 2 格），右半边 = 插到它后面
    model.endDrag()
    #expect(
      model.layout.tiles[0].folder?.apps.map(\.id) == [ref("y").id, ref("z").id, ref("x").id])
  }

  /// 拖出文件夹面板 14 pt：文件夹马上关上，手里的接着在主网格里拖、松手放在指针那儿（这里放在 c 前面）
  @Test func draggingOutOfAFolderHandsOffToTheGrid() {
    let folder = LaunchpadFolder(name: "X", pages: [[ref("x"), ref("y"), ref("z")]])
    let model = model(
      LaunchpadLayout(pages: [[.folder(folder), .app(ref("b")), .app(ref("c"))]]),
      timing: .immediate)
    model.openFolder(folder.id)
    let start = model.folderCellCenter(1)
    model.beginDrag(
      tile: .app(ref("y")), appID: ref("y").id, folder: folder.id, at: start, origin: start)
    let panel = model.folderPanelRect
    model.updateDrag(location: CGPoint(x: panel.midX, y: panel.minY - 30), pageWidth: 900)
    #expect(model.openFolderID == nil)
    #expect(model.drag?.isDragging == true)
    model.updateDrag(location: before(2, of: model), pageWidth: 900)
    model.endDrag()
    #expect(model.layout.tiles.count == 4)
    #expect(
      model.layout.tiles.compactMap { $0.app?.id } == [ref("b").id, ref("y").id, ref("c").id])
    #expect(model.layout.tiles[0].folder?.apps.map(\.id) == [ref("x").id, ref("z").id])
  }

  /// 放进文件夹的任意一格（纯函数）：顶层的、别的文件夹的（只剩一个就解散）、同一个文件夹里挪；满了顺到下一页
  @Test func placingIntoAFolder() {
    let one = LaunchpadFolder(name: "一", pages: [[ref("x"), ref("y")]])
    let two = LaunchpadFolder(name: "二", pages: [[ref("p"), ref("q")]])
    let layout = LaunchpadLayout(pages: [[.folder(one), .folder(two), .app(ref("a"))]])
    let top = layout.placing(ref("a").id, inFolder: one.id, page: 0, index: 1, capacity: 6)
    #expect(top.tiles.count == 2)
    #expect(top.tiles[0].folder?.apps.map(\.id) == [ref("x").id, ref("a").id, ref("y").id])
    // 从「二」拿走 p：二只剩 q，解散成顶层的 q
    let other = layout.placing(ref("p").id, inFolder: one.id, page: 0, index: 0, capacity: 6)
    #expect(other.tiles[0].folder?.apps.map(\.id) == [ref("p").id, ref("x").id, ref("y").id])
    #expect(other.tiles[1].app?.id == ref("q").id)
    let same = layout.placing(ref("x").id, inFolder: one.id, page: 0, index: 5, capacity: 6)
    #expect(same.tiles[0].folder?.apps.map(\.id) == [ref("y").id, ref("x").id])
    // 一页满了：挤出来的顺到下一页开头
    let full = (0..<LaunchpadLayout.folderCapacity).map { ref("f\($0)") }
    let pages = LaunchpadLayout.inserting(ref("new"), into: [full], page: 0, index: 0)
    #expect(pages.count == 2)
    #expect(pages[0].first?.id == ref("new").id)
    #expect(pages[1] == [full.last!])
  }

  // MARK: 翻页

  /// 空白处按住左右拖 = 跟手翻页；挪不到 5 pt 就松手 = 点了空白（收起）
  @Test func backgroundDragTurnsPagesAndTapCloses() {
    let model = model(LaunchpadLayout(pages: [apps(["a"]), apps(["b"]), apps(["c"])]))
    var closed = 0
    model.onClose = { closed += 1 }
    model.backgroundDragChanged(translation: CGSize(width: -100, height: 0), time: 1)
    model.backgroundDragChanged(translation: CGSize(width: -260, height: 0), time: 1.5)
    model.backgroundDragEnded(time: 2)
    #expect(model.page == 1)
    #expect(closed == 0)
    model.backgroundDragChanged(translation: CGSize(width: 3, height: 0), time: 3)
    model.backgroundDragEnded(time: 3.1)
    #expect(closed == 1)
  }

  /// 翻页门槛 20% 页宽（原来 1/3）：慢慢拖 22% 翻、16% 不翻
  @Test func pagerFlipsAtAFifthOfThePage() {
    var flip = LaunchpadPager()
    _ = flip.feed(delta: -100, time: 1, pageWidth: 900, canBack: true, canForward: true)
    _ = flip.feed(delta: -100, time: 2, pageWidth: 900, canBack: true, canForward: true)
    #expect(flip.finish(canBack: true, canForward: true, pageWidth: 900) == 1)
    var stay = LaunchpadPager()
    _ = stay.feed(delta: -70, time: 1, pageWidth: 900, canBack: true, canForward: true)
    _ = stay.feed(delta: -75, time: 2, pageWidth: 900, canBack: true, canForward: true)
    #expect(stay.finish(canBack: true, canForward: true, pageWidth: 900) == 0)
  }

  // MARK: 真界面（屏外窗口、进程内送事件）

  /// 拖动判定用的面板位置是按算式给的：和真画出来的文件夹图标对得上（不差 1 pt）
  @Test func folderPanelRectMatchesTheDrawnIcons() async throws {
    let folder = LaunchpadFolder(name: "X", pages: [[ref("x"), ref("y"), ref("z")]])
    let model = model(LaunchpadLayout(pages: [[.folder(folder)]]))
    let live = InteractLive(model)
    defer { live.close() }
    await live.waitForGrid()
    model.openFolder(folder.id)
    // 等文件夹长出来、启动台打开的那一下缩放都走完
    try? await Task.sleep(for: .milliseconds(600))
    await live.settle()
    let icons = live.iconCenters()
    #expect(icons.count == 3)
    for (index, icon) in icons.enumerated() {
      let expected = model.folderCellCenter(index)
      #expect(abs(icon.x - expected.x) < 1, "\(index): \(icon) vs \(expected)")
      #expect(abs(icon.y - (expected.y - LaunchpadMetrics.iconLift)) < 1, "\(index)")
    }
  }

  /// 真鼠标：从文件夹里按住一个图标拖出面板 → 文件夹关上（挂在它上面的手势跟着被拆掉）→ 接着拖到主网格、松手照样收得到
  @Test func realDragOutOfAFolderStillDrops() async throws {
    let folder = LaunchpadFolder(name: "X", pages: [[ref("x"), ref("y"), ref("z")]])
    let model = model(
      LaunchpadLayout(pages: [[.folder(folder), .app(ref("b")), .app(ref("c"))]]),
      timing: .immediate)
    let live = InteractLive(model)
    defer { live.close() }
    await live.waitForGrid()
    model.openFolder(folder.id)
    try? await Task.sleep(for: .milliseconds(600))
    await live.settle()
    let start = model.folderCellCenter(1)
    let panel = model.folderPanelRect
    let outside = CGPoint(x: panel.midX, y: panel.maxY + 60)
    await live.send(.leftMouseDown, start)
    for step in 1...8 {
      let t = CGFloat(step) / 8
      await live.send(
        .leftMouseDragged,
        CGPoint(x: start.x + (outside.x - start.x) * t, y: start.y + (outside.y - start.y) * t))
    }
    #expect(model.openFolderID == nil)
    // 在外面停一会儿：文件夹那块界面收完、被拆掉（挂在它上面的手势跟着被取消），之后的挪动和松手只有最外层那份收得到
    try? await Task.sleep(for: .milliseconds(600))
    await live.settle()
    let target = before(2, of: model)
    await live.send(.leftMouseDragged, target)
    await live.send(.leftMouseUp, target)
    #expect(model.drag == nil)
    #expect(
      model.layout.tiles.compactMap { $0.app?.id } == [ref("b").id, ref("y").id, ref("c").id])
    #expect(model.layout.tiles[0].folder?.apps.map(\.id) == [ref("x").id, ref("z").id])
  }
}

/// 屏外窗口里的真启动台界面（同 LaunchpadRecheckTests 的 LiveLaunchpad：进程内 `window.sendEvent`，不当 key）
@MainActor
private struct InteractLive {
  let window: NSWindow
  let host: InteractHost
  let model: LaunchpadModel
  let size = NSSize(width: 900, height: 600)

  init(_ model: LaunchpadModel) {
    self.model = model
    host = InteractHost(
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

  /// 等界面画出来、自己喂的网格框被界面量到的换掉
  func waitForGrid() async {
    for _ in 0..<20 { await settle() }
  }

  func settle() async {
    for _ in 0..<3 {
      try? await Task.sleep(for: .milliseconds(15))
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
    }
  }

  /// 界面里每个 App 图标（NSImageView）中心在窗口里的位置（左上角为原点），按先行后列排
  func iconCenters() -> [CGPoint] {
    func images(in view: NSView) -> [NSImageView] {
      view.subviews.flatMap { ($0 as? NSImageView).map { [$0] } ?? images(in: $0) }
    }
    return images(in: host).map { image in
      let rect = image.convert(image.bounds, to: nil)
      return CGPoint(x: rect.midX, y: size.height - rect.midY)
    }
    .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
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
}

private final class InteractHost: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
