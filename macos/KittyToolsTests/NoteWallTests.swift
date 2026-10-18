// 全部便签窗口「便签墙」的单测（2026-10-15 手测反馈；Notes/NoteWall.swift、NotesWallView.swift、NotesWindowModel）：
// - 纯函数：按宽度排几列、瀑布流的摆法（两段、小标题、空段；高边排边要）、倾斜的大小和方向、方向键在卡片之间怎么走、
//   指针下是哪张、拖动排序落到哪（只看拖动开始时的排法，同一个指针位置怎么问都一样）、落成仓库的哪个下标（固定的和
//   没固定的混着排）、编辑卡多大、它那块纸从哪长出来 / 缩回哪（按那一刻的排法和滚动位置）、卡片上带正文的哪一段
//   （以代码块开头、没起标题的不少一行）、卡片上的字（标记删掉、样式跟编辑器一样）和高；
// - 模型：显示方式的偏好（临时域）、打开 / 收回编辑卡和选中的关系、「编辑卡开着」认的是哪条（在别处没了的不算）、
//   不给正文焦点时墙拿焦点、⌘F、新建 / 从那叠打开、方向键、拖动排序写回仓库、工具栏「任务」置灰；
// - 卡片的缓存（仓库那一层）和墙怎么排：可见区附近的当场建、往下的先按估计的高、剩下的分批建好；
// - 窗口接线：屏外带标题栏的窗口（不当 key、不激活），默认是便签墙；点开 / 收回编辑卡（⌘W 由窗口认）、编辑卡里打字
//   按编号落、撤销栈各归各、删除 / 在别处删了之后编辑卡收回、焦点回到墙上，切到列表再切回来选中的还在、最近删除里
//   只读、空的墙；按编号找正文框找不到就是没有。
// 全用内存库；偏好只用临时域；不发真实的鼠标键盘事件。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

struct NoteWallTests {
  private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

  /// 内存库，bodies 是「全部」里从上到下的顺序
  private func library(_ bodies: [String]) throws -> (store: NoteStore, ids: [String]) {
    let store = try NoteStore(db: Database(path: ":memory:"))
    for (offset, body) in bodies.reversed().enumerated() {
      store.create(body: body, now: Self.t0.addingTimeInterval(Double(offset)))
    }
    return (store, store.active.map(\.id))
  }

  private func section(_ ids: [String], _ heights: [CGFloat], title: String? = nil)
    -> NoteWall.Section
  {
    NoteWall.Section(title: title, ids: ids, heights: heights)
  }

  // MARK: 排

  /// 列宽固定：窗口宽一点就多一列；窄窗口（最小 720）两列、默认 940 三列、宽的四五列
  @Test func columnsFollowTheWidth() {
    #expect(NoteWall.columnCount(width: 0) == 1 && NoteWall.columnCount(width: 300) == 1)
    #expect(NoteWall.columnCount(width: 720) == 2)
    #expect(NoteWall.columnCount(width: 940) == 3)
    #expect(NoteWall.columnCount(width: 1200) == 4)
    #expect(NoteWall.columnCount(width: 1280) == 5)
  }

  /// 瀑布流：一张张放进当时最矮的那一列（一样矮取左边的），整块居中；墙的高 = 最高那列 + 底边
  @Test func masonryPlacesIntoTheShortestColumn() {
    let layout = NoteWall.layout(
      [section(["a", "b", "c", "d", "e"], [100, 200, 150, 120, 80])], width: 940)
    #expect(layout.columnCount == 3 && layout.ids == ["a", "b", "c", "d", "e"])
    // 三列共 704 宽，(940 − 704) / 2 = 118
    #expect(layout.frames.map(\.minX) == [118, 358, 598, 118, 598])
    #expect(layout.frames.map(\.minY) == [20, 20, 20, 136, 186])
    #expect(layout.frames.map(\.height) == [100, 200, 150, 120, 80])
    #expect(layout.frames.allSatisfy { $0.width == NoteWall.cardWidth })
    #expect(layout.columns == [0, 1, 2, 0, 2])
    #expect(layout.height == 286 && layout.headers.isEmpty && layout.sections == [0..<5])
    // 太窄：一列、贴着左边的边距
    let narrow = NoteWall.layout([section(["a", "b"], [100, 100])], width: 200)
    #expect(narrow.columnCount == 1 && narrow.frames.map(\.minX) == [20, 20])
    #expect(narrow.frames.map(\.minY) == [20, 136])
    // 空的墙
    #expect(NoteWall.layout([], width: 940).height == 40)
  }

  /// 两段（固定的、其他）：各有一行小标题，第二段从第一段最低的那列下面再空一点开始；空的段连标题都不要
  @Test func sectionsStackWithHeaders() {
    let layout = NoteWall.layout(
      [
        section(["p"], [130], title: "已固定"), section([], [], title: "空的"),
        section(["x", "y"], [100, 100], title: "其他"),
      ], width: 720)
    // 两列共 464 宽，(720 − 464) / 2 = 128
    #expect(layout.headers.map(\.title) == ["已固定", "其他"])
    #expect(layout.headers[0].frame == CGRect(x: 128, y: 20, width: 464, height: 24))
    #expect(layout.frames[0].origin == CGPoint(x: 128, y: 44))
    // 第一段到 44 + 130 = 174，再空 12：第二段的标题在 186、卡片从 210 起（又从左边第一列放起）
    #expect(layout.headers[1].frame.minY == 186)
    #expect(layout.frames[1].origin == CGPoint(x: 128, y: 210))
    #expect(layout.frames[2].origin == CGPoint(x: 368, y: 210))
    #expect(layout.sections == [0..<1, 1..<3] && layout.height == 330)
    #expect(
      layout.section(of: 0) == 0 && layout.section(of: 2) == 1 && layout.section(of: 9) == nil)
  }

  /// 倾斜：大小按编号定（1–2°，每次一样），方向按位置交错——同一列上下挨着的、一段的第一排左右挨着的不同向
  @Test func tiltIsStableAndAlternates() {
    #expect(NoteWall.tilt(id: "A", column: 0, row: 0) == NoteWall.tilt(id: "A", column: 0, row: 0))
    #expect(NoteWall.tilt(id: "A", column: 0, row: 0) == -NoteWall.tilt(id: "A", column: 0, row: 1))
    let ids = (0..<200).map {
      "\(UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", $0))")!)"
    }
    let sizes = ids.map { abs(NoteWall.tilt(id: $0, column: 0, row: 0)) }
    #expect(sizes.allSatisfy { (1...2).contains($0) })
    // 编号不同大小也不同（不是一个常数）
    #expect(Set(sizes.map { ($0 * 100).rounded() }).count > 20)
    let layout = NoteWall.layout(
      [section(Array(ids.prefix(12)), (0..<12).map { CGFloat(100 + ($0 * 37) % 90) })], width: 940)
    for index in layout.ids.indices {
      // 同一列里下面紧挨着的那张
      let below = layout.ids.indices.filter {
        layout.columns[$0] == layout.columns[index]
          && layout.frames[$0].minY > layout.frames[index].minY
      }.min { layout.frames[$0].minY < layout.frames[$1].minY }
      if let below { #expect((layout.tilts[index] < 0) != (layout.tilts[below] < 0)) }
    }
    // 第一排左右挨着的不同向
    #expect(layout.tilts[0] < 0 && layout.tilts[1] > 0 && layout.tilts[2] < 0)
  }

  // MARK: 方向键

  /// ↑↓ 在同一列里走（这一列那边没有了去最近的列）；←→ 去旁边那列里竖直方向离得最近的；走不动是 nil
  @Test func arrowKeysWalkTheWall() {
    // a(列 0, 20–120) b(列 1, 20–220) c(列 2, 20–170) d(列 0, 136–256) e(列 2, 186–266)
    let layout = NoteWall.layout(
      [section(["a", "b", "c", "d", "e"], [100, 200, 150, 120, 80])], width: 940)
    func go(_ id: String, _ direction: NoteWall.Direction) -> String? {
      NoteWall.neighbor(of: layout.index(of: id)!, direction, in: layout).map { layout.ids[$0] }
    }
    #expect(go("a", .down) == "d" && go("c", .down) == "e" && go("b", .down) == "d")
    #expect(go("d", .down) == "e" && go("e", .down) == nil)
    #expect(go("d", .up) == "a" && go("e", .up) == "c" && go("a", .up) == nil)
    #expect(go("a", .right) == "b" && go("d", .right) == "b" && go("b", .right) == "c")
    #expect(go("e", .left) == "b" && go("b", .left) == "a" && go("a", .left) == nil)
    #expect(go("c", .right) == nil)
    #expect(NoteWall.neighbor(of: 9, .down, in: layout) == nil)
  }

  /// 模型里的方向键：没有选中的选第一张；编辑卡开着时不走
  @Test func arrowKeysMoveTheSelection() throws {
    let (store, ids) = try library(["a", "b", "c"])
    let model = NotesWindowModel(store: store)
    let layout = NoteWall.layout([section(ids, [100, 100, 100])], width: 940)
    model.selection = nil
    model.moveSelection(.right, in: layout)
    #expect(model.selection == ids[0])
    model.moveSelection(.right, in: layout)
    #expect(model.selection == ids[1])
    model.moveSelection(.right, in: layout)
    model.moveSelection(.right, in: layout)
    #expect(model.selection == ids[2])
    model.open(ids[0], focus: false)
    model.moveSelection(.right, in: layout)
    #expect(model.selection == ids[0] && model.expanded == ids[0])
  }

  // MARK: 拖动排序

  /// 指针下是哪张（拖动时四边往里收一点）；落点只在同一段里
  @Test func dragLandsWithinItsSection() {
    let layout = NoteWall.layout(
      [
        section(["p", "q"], [100, 100], title: "已固定"), section(["x", "y", "z"], [100, 100, 100]),
      ],
      width: 940)
    let x = layout.frames[2]
    #expect(NoteWall.item(at: CGPoint(x: x.midX, y: x.midY), in: layout) == 2)
    // 卡片边上（收进去的那一圈里）不算
    let edge = CGPoint(x: x.minX + 2, y: x.minY + 2)
    #expect(NoteWall.item(at: edge, in: layout) == 2)
    #expect(NoteWall.item(at: edge, in: layout, inset: NoteWall.dragInset) == nil)
    #expect(NoteWall.item(at: .zero, in: layout) == nil)
    #expect(NoteWall.landing(from: 4, over: 2, in: layout) == 2)
    #expect(NoteWall.landing(from: 0, over: 1, in: layout) == 1)
    #expect(NoteWall.landing(from: 0, over: 3, in: layout) == nil)
    #expect(NoteWall.landing(from: 3, over: 1, in: layout) == nil)
    #expect(NoteWall.moved(["a", "b", "c"], from: 2, to: 0) == ["c", "a", "b"])
    #expect(NoteWall.moved(["a", "b", "c"], from: 0, to: 2) == ["b", "c", "a"])
    #expect(NoteWall.moved(["a", "b", "c"], from: 0, to: 5) == ["a", "b", "c"])
  }

  /// 拖动排序的落点只看拖动开始时那份排法：指针不动，怎么反复问都是同一个落点（原来按让过位之后的墙判断，那份墙又随
  /// 落点变，指针不动也在两个位置之间来回跳——这组随机的墙里有 14 个）。随机的墙、指针停在随便哪张里面，每个都照
  /// 墙上一帧帧的样子连问 8 次
  @Test func dropTargetIsStable() {
    var seed: UInt64 = 7
    func next(_ bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(seed >> 33) % bound
    }
    for _ in 0..<4000 {
      let count = 3 + next(12)
      let ids = (0..<count).map { "n\($0)" }
      let heights = ids.map { _ in CGFloat(NoteWall.minHeight + CGFloat(next(209))) }
      let base = NoteWall.layout([section(ids, heights)], width: 940)
      let from = next(count)
      // 指针停在随便哪张卡片里面
      let card = base.frames[next(count)]
      let point = CGPoint(
        x: card.minX + CGFloat(next(Int(card.width))),
        y: card.minY + CGFloat(next(Int(card.height))))
      var to = from
      var seen: [Int] = []
      for _ in 0..<8 {
        to = NoteWall.dropTarget(from: from, current: to, at: point, in: base)
        seen.append(to)
      }
      #expect(Set(seen).count == 1, "from \(from) at \(point) heights \(heights): \(seen)")
    }
    // 落在同一段里另一张的里面：就是那张的位置；在别的段里、在空白处：不动
    let layout = NoteWall.layout(
      [
        section(["p", "q"], [100, 100], title: "已固定"), section(["x", "y", "z"], [100, 100, 100]),
      ],
      width: 940)
    let y = layout.frames[3]
    #expect(
      NoteWall.dropTarget(from: 2, current: 2, at: CGPoint(x: y.midX, y: y.midY), in: layout) == 3)
    let q = layout.frames[1]
    #expect(
      NoteWall.dropTarget(from: 2, current: 4, at: CGPoint(x: q.midX, y: q.midY), in: layout) == 4)
    #expect(NoteWall.dropTarget(from: 2, current: 4, at: .zero, in: layout) == 4)
  }

  /// 拖完写回仓库：仓库的顺序里固定的和没固定的混着排，照它在墙上同一段里紧挨着的那张放
  @Test func dragWritesBackTheStoreOrder() throws {
    let (store, ids) = try library(["A", "B", "C", "D", "E"])
    let model = NotesWindowModel(store: store)
    let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
    store.setPinned(true, of: b)
    store.setPinned(true, of: d)
    func wall() -> [[String]] { model.wallGroups.map { $0.notes.map(\.id) } }
    #expect(model.wallGroups.map(\.title) == ["已固定", "其他"])
    #expect(wall() == [[b, d], [a, c, e]])
    func drag(_ from: Int, to: Int) {
      let order = model.wallGroups.flatMap(\.notes).map(\.id)
      let sections = [0..<2, 2..<5]
      let section = sections.first { $0.contains(from) }!
      model.reorder(order[from], in: NoteWall.moved(order, from: from, to: to), section: section)
    }
    // E 拖到 A 上：放到 A 前面
    drag(4, to: 2)
    #expect(wall() == [[b, d], [e, a, c]])
    // A 拖到最后（C 上）：它是这一段最后一张，放到 C 后面
    drag(3, to: 4)
    #expect(wall() == [[b, d], [e, c, a]])
    // 固定的那段里：D 拖到 B 上
    drag(1, to: 0)
    #expect(wall() == [[d, b], [e, c, a]])
    // 在搜索、不在「全部」里时不动
    model.query = "A"
    drag(0, to: 0)
    model.reorder(a, in: [a], section: 0..<1)
    model.query = ""
    #expect(wall() == [[d, b], [e, c, a]])
    #expect(NoteWall.storeIndex(of: "x", in: ["a"], section: 0..<1, active: ["a"]) == nil)
  }

  /// 便签墙上分几段：有固定的才分（固定的、其他）；最近删除里不分
  @Test func wallGroupsPinnedFirst() throws {
    let (store, ids) = try library(["A", "B", "C"])
    let model = NotesWindowModel(store: store)
    #expect(model.wallGroups.count == 1 && model.wallGroups[0].title == nil)
    store.setPinned(true, of: ids[2])
    #expect(model.wallGroups.map { $0.notes.map(\.id) } == [[ids[2]], [ids[0], ids[1]]])
    store.delete(ids[2])
    store.delete(ids[0])
    model.scope = .trash
    #expect(model.wallGroups.count == 1 && model.wallGroups[0].title == nil)
    #expect(Set(model.wallGroups[0].notes.map(\.id)) == [ids[0], ids[2]])
  }

  // MARK: 编辑卡

  /// 编辑卡多大：墙的七八成，最大 680 × 560
  @Test func editorSizeFollowsTheWindow() {
    #expect(
      NoteWall.editorSize(in: CGSize(width: 720, height: 368)) == CGSize(width: 562, height: 309))
    #expect(
      NoteWall.editorSize(in: CGSize(width: 940, height: 528)) == CGSize(width: 680, height: 444))
    #expect(NoteWall.editorSize(in: CGSize(width: 1600, height: 1000)) == NoteWall.editorMax)
  }

  /// 打开 / 收回编辑卡：打开 = 选中 + 放大（列表视图里只选中）；收回落盘、墙拿回焦点；选中的换了、删了、归档了、
  /// 换到列表、窗口关了都收回；新建、从那叠「在全部便签里打开」直接放大
  @Test func openingAndCollapsing() throws {
    let (store, ids) = try library(["A", "B", "C"])
    let model = NotesWindowModel(store: store)
    var focused = 0
    model.focusBody = { focused += 1 }
    model.open(ids[1])
    #expect(model.selection == ids[1] && model.expanded == ids[1] && focused == 1)
    #expect(model.isEditing && model.wallFocus == 0)
    // 编辑卡里打字（按编号落），收回时落盘（焦点回到墙上由墙自己看着 expanded 拿）
    model.setBody("B 改了", of: ids[1])
    model.collapse()
    #expect(model.expanded == nil && !model.isEditing)
    #expect(store.note(ids[1])?.body == "B 改了")
    model.collapse()
    #expect(model.expanded == nil && model.wallFocus == 0)
    // 换一条：收回
    model.open(ids[0], focus: false)
    model.selection = ids[2]
    #expect(model.expanded == nil)
    // 删掉开着的那条：选中挪到旁边、收回
    model.open(ids[2], focus: false)
    model.delete(ids[2])
    #expect(model.expanded == nil && model.selection == ids[1])
    // 归档开着的那条
    model.open(ids[1], focus: false)
    model.toggleArchived(ids[1])
    #expect(model.expanded == nil)
    // 固定、换色不收
    model.open(ids[0], focus: false)
    model.togglePinned(ids[0])
    model.cycleColor(ids[0])
    #expect(model.expanded == ids[0])
    // 换到列表：收回，选中的还在
    model.layout = .list
    #expect(model.expanded == nil && model.selection == ids[0])
    model.open(ids[0], focus: false)
    #expect(model.expanded == nil && model.selection == ids[0])
    model.layout = .wall
    // 新建：在墙上直接放大
    model.create()
    #expect(model.expanded == store.active.first?.id && model.selection == model.expanded)
    // 从那叠「在全部便签里打开」一条归档的：换到归档、放大
    model.reveal(ids[1])
    #expect(model.scope == .archive && model.expanded == ids[1])
    // 最近删除里的也能打开（只读，界面管）
    model.reveal(ids[2])
    #expect(model.scope == .trash && model.expanded == ids[2])
    // 窗口关了
    model.closed()
    #expect(model.expanded == nil)
    // 不在当前视图里的不放大
    model.scope = .all
    model.open(ids[2], focus: false)
    #expect(model.expanded == nil)
  }

  /// 编辑卡那块纸从哪长出来 / 缩回哪：那张卡片现在在窗口里的位置（墙上的位置 − 滚过的 + 顶上那一条）；滚出了可见区、
  /// 不在墙上的是 nil（中央淡掉）。收回时照收回那一刻的排法和滚动位置算：挪了、滚了都跟着
  @Test func paperFollowsTheCardNow() throws {
    let layout = NoteWall.layout(
      [section(["a", "b", "c", "d"], [120, 300, 160, 140])], width: 940)
    let (top, viewport): (CGFloat, CGFloat) = (45, 500)
    let a = layout.frames[0]
    // 没滚：墙上的位置往下挪顶上那一条那么高
    #expect(
      NoteWall.paperRect(card: a, top: top, scrollY: 0, viewport: viewport)
        == a.offsetBy(dx: 0, dy: top))
    // 滚了 100：跟着往上 100（露着一截也算）
    #expect(
      NoteWall.paperRect(card: a, top: top, scrollY: 100, viewport: viewport)
        == a.offsetBy(dx: 0, dy: top - 100))
    // 整张滚出了可见区（上面、下面）：没有卡片可回
    #expect(NoteWall.paperRect(card: a, top: top, scrollY: a.maxY + 1, viewport: viewport) == nil)
    let d = layout.frames[3]
    #expect(NoteWall.paperRect(card: d, top: top, scrollY: 0, viewport: d.minY - 1) == nil)
    // 不在墙上（被搜索词筛掉了、删了）
    #expect(NoteWall.paperRect(card: nil, top: top, scrollY: 0, viewport: viewport) == nil)
    // 开着的时候它挪了（比如固定了、排到了最前）：按新的排法算出来的是新的位置
    let moved = NoteWall.layout(
      [section(["d", "a", "b", "c"], [140, 120, 300, 160])], width: 940)
    let now = try #require(moved.index(of: "d"))
    #expect(
      NoteWall.paperRect(card: moved.frames[now], top: top, scrollY: 0, viewport: viewport)
        == moved.frames[now].offsetBy(dx: 0, dy: top))
    #expect(moved.frames[now] != d)
  }

  /// 「编辑卡开着」认的是放大着的那条还是这个视图里选中的那条：它在别处被删了 / 归档了的那一下 expanded 还留着，
  /// 不算开着——方向键、↩、⌫、⌘W 不再被它挡住；墙看着 current 收回它（这里照墙的做法调 collapse）
  @Test func editingFollowsTheCurrentNote() throws {
    let (store, ids) = try library(["A", "B", "C"])
    let model = NotesWindowModel(store: store)
    model.open(ids[1], focus: false)
    #expect(model.isEditing)
    // 屏幕边缘那叠里把它删了：expanded 还在，但不算开着；方向键照走
    store.delete(ids[1])
    #expect(model.expanded == ids[1] && !model.isEditing && model.current == nil)
    let layout = model.wallLayout(model.wallGroups, width: 940, reach: 2000, markdown: true)
    model.moveSelection(.down, in: layout)
    #expect(model.selection == layout.ids[0])
    // 墙收回它之后，在那叠里 ⌘Z 放回来：编辑卡不会自己又弹出来
    model.collapse()
    store.restore(ids[1])
    #expect(model.expanded == nil && !model.isEditing)
    // 归档同理
    model.open(ids[0], focus: false)
    store.setArchived(true, of: ids[0])
    #expect(model.expanded == ids[0] && !model.isEditing)
    // 窗口的 ⌘W：不算开着时不拿去收回，照常关窗口（返回 false）
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "w",
        charactersIgnoringModifiers: "w", isARepeat: false, keyCode: UInt16(kVK_ANSI_W)))
    #expect(event.window === window && !NotesWindow.handlesKeyDown(event, in: window, model: model))
    model.collapse()
    model.open(ids[2], focus: false)
    #expect(NotesWindow.handlesKeyDown(event, in: window, model: model) && model.expanded == nil)
  }

  /// 不给正文焦点的打开（从那叠打开、最近删除里只读的）让墙拿焦点；⌘F 在编辑卡开着时是正文的查找条，不去搜索框；
  /// 「任务」只在有正文框时点得了（列表右栏、开着的编辑卡）
  @Test func focusWhenOpening() throws {
    let (store, ids) = try library(["A", "B"])
    let model = NotesWindowModel(store: store)
    var (bodies, finds) = (0, 0)
    model.focusBody = { bodies += 1 }
    model.withEditor = { _ in finds += 1 }
    #expect(!model.toolbarState.canTask)
    model.open(ids[0])
    #expect(bodies == 1 && model.wallFocus == 0 && model.toolbarState.canTask)
    let search = model.searchFocus
    model.find()
    #expect(finds == 1 && model.searchFocus == search)
    model.collapse()
    #expect(!model.toolbarState.canTask)
    model.find()
    #expect(model.searchFocus == search + 1)
    // 从那叠打开：不给正文焦点，墙拿
    model.reveal(ids[1])
    #expect(bodies == 1 && model.wallFocus == 1 && model.isEditing)
    model.collapse()
    // 最近删除里的：只读、没有正文框——点开（要焦点）也是墙拿
    store.delete(ids[1])
    model.scope = .trash
    model.open(ids[1])
    #expect(bodies == 1 && model.wallFocus == 2 && model.isEditing)
    #expect(!model.toolbarState.canTask)
    model.collapse()
    // 列表视图：选中就有正文框
    model.scope = .all
    model.layout = .list
    model.open(ids[0])
    #expect(bodies == 2 && model.wallFocus == 2 && model.toolbarState.canTask)
  }

  /// 显示方式的偏好：没存过是便签墙；换了就记（这台电脑自己的状态，没注册默认值）；不给偏好域时不记
  @Test func layoutPreference() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try NoteStore(db: Database(path: ":memory:"))
    let model = NotesWindowModel(store: store, defaults: defaults)
    #expect(model.layout == .wall && defaults.object(forKey: Prefs.notesWindowLayout) == nil)
    model.layout = .list
    #expect(defaults.string(forKey: Prefs.notesWindowLayout) == "list")
    #expect(NotesWindowModel(store: store, defaults: defaults).layout == .list)
    model.layout = .wall
    #expect(NotesWindowModel(store: store, defaults: defaults).layout == .wall)
    // 认不出的值按便签墙
    defaults.set("grid", forKey: Prefs.notesWindowLayout)
    #expect(NotesWindowModel(store: store, defaults: defaults).layout == .wall)
    // 没注册默认值：不跟着导出 / 导入走
    #expect(Prefs.defaults[Prefs.notesWindowLayout] == nil)
    // 不给偏好域（单测、截图自检）：只在内存里
    let unsaved = NotesWindowModel(store: store)
    unsaved.layout = .list
    #expect(NotesWindowModel(store: store).layout == .wall)
    #expect(Model.Layout.allCases.map(\.title) == ["便签墙", "列表"])
  }

  private typealias Model = NotesWindowModel

  // MARK: 卡片上的字

  /// 卡片带正文的哪一段：自己起了标题就从头带；没起的，标题就是第一个有内容的行，跳过它（和前面的空行、围栏行）；
  /// 最多 excerptLines 行；代码块挪到这一段的坐标里
  @Test func excerptSkipsTheTitleLine() {
    func note(_ body: String, title: String = "") -> Note {
      Note(id: "n", title: title, body: body, createdAt: Self.t0, modifiedAt: Self.t0)
    }
    #expect(NoteWall.excerpt(of: note("第一行\n第二行", title: "T")).text == "第一行\n第二行")
    #expect(NoteWall.excerpt(of: note("\n\n第一行\n\n第二行\n")).text == "第二行")
    #expect(NoteWall.excerpt(of: note("只有一行")).text.isEmpty)
    #expect(NoteWall.excerpt(of: note("")).text.isEmpty)
    let long = (1...40).map { "第 \($0) 行" }.joined(separator: "\n")
    let lines = NoteWall.excerpt(of: note(long, title: "T")).text.components(separatedBy: "\n")
    #expect(lines.count == NoteWall.excerptLines && lines.last == "第 \(NoteWall.excerptLines) 行")
    // 一整段没有换行的长字：截到 excerptLength 个字
    let paragraph = String(repeating: "字", count: 5000)
    #expect(NoteWall.excerpt(of: note(paragraph, title: "T")).text.count == NoteWall.excerptLength)
    // 标题取自代码块里的一行：后面的收尾围栏不带
    #expect(NoteWall.excerpt(of: note("```\nlet a = 1\n```\n后面的字")).text == "后面的字")
    // 以代码块开头、没起标题：标题是块里的第一行，这一段从块里的第二行起——块的开头被截在这一段前面，这一段的第一行
    // 是块里的字、不是围栏（原来被当成开头的围栏行，卡片上少一行）
    for (body, shown) in [
      ("```\nlet a = 1\nlet b = 2\nlet c = 3\n```\nafter", "let b = 2\nlet c = 3\nafter"),
      ("```\nA\nB\n```\nC", "B\nC"),
    ] {
      let card = NoteWallCard.make(for: note(body), title: note(body).displayTitle, markdown: true)
      #expect(card.title.string == (body.hasPrefix("```\nA") ? "A" : "let a = 1"))
      #expect(card.body.string == shown)
      let cut = NoteWall.excerpt(of: note(body))
      #expect(NoteMarkdown.role(at: 0, in: cut.blocks) == .content)
    }
    // 图片（第 7 批）：卡片上只有图片的行整行不要、行内的写成「[图片]」，顶上放第一张图的缩略图
    let image = NoteImages.token(
      NoteImages.Image(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, ext: "png"))
    // 自己起了标题：这一段从正文开头带（不然第一行会被当成标题跳掉）
    func withImages(_ body: String) -> Note {
      Note(id: "n", title: "我的标题", body: body, createdAt: Self.t0, modifiedAt: Self.t0)
    }
    func card(_ body: String, sizes: ((NoteImages.Image) -> CGSize?)? = nil) -> NoteWallCard {
      NoteWallCard.make(
        for: withImages(body), title: "我的标题", markdown: true,
        sizes: sizes ?? { _ in nil }, url: { _ in URL(fileURLWithPath: "/tmp/x.png") })
    }
    #expect(card("买菜\n\(image)\n牛奶").body.string == "买菜\n牛奶", "只有图片的行整行不要")
    #expect(card("\(image)\n买菜").body.string == "买菜")
    #expect(card("\(image)").body.string == "")
    #expect(card("前面\(image)后面").body.string == "前面[图片]后面", "行内的写成「[图片]」")
    // 缩略图：第一张图，高按元数据算（按比例、有上限）
    let plain = card("买菜\n牛奶")
    let withoutSizes = card("\(image)\n买菜")
    #expect(withoutSizes.thumbnail == nil, "没给尺寸（文件不在）：不放缩略图")
    #expect(withoutSizes.height == plain.height)
    let sized = card("\(image)\n买菜") { _ in CGSize(width: 800, height: 400) }
    #expect(sized.thumbnail != nil && sized.thumbnailURL != nil)
    #expect(
      sized.thumbnailHeight == min(NoteImageLayout.thumbnailMaxHeight, NoteWall.textWidth / 2),
      "高按比例、有上限")
    #expect(sized.height > plain.height, "卡片的高把缩略图算进去")
    // 行内的第一张图也算（摘要是从正文里找的第一张图，不是这一段里的）
    #expect(card("前\(image)后") { _ in CGSize(width: 40, height: 40) }.thumbnail != nil)

    // F11：令牌在 excerptLength 处不截成两半、只有图片的行先去掉再数行（原来先截取再换令牌）
    let filler = String(repeating: "字", count: NoteWall.excerptLength - 10)
    let nearCut = NoteWall.excerpt(of: withImages("\(filler)\(image)")).text
    #expect(!nearCut.contains("kitty-note-image"), "截取处不许露出令牌原文")
    #expect(nearCut.hasSuffix("[图片]"))
    let imageOnlyFirst = NoteWall.excerpt(of: withImages("\(image)\n买菜\n牛奶")).text
    #expect(imageOnlyFirst == "买菜\n牛奶", "只有图片的行先去掉，不占 16 行的名额")
    // 只有图片的便签：这一段是空的（不是令牌原文）
    #expect(NoteWall.excerpt(of: withImages(image)).text.isEmpty)
    // 令牌跨在 excerptScan（只看正文开头多少个字）的截断处：截到令牌后面，不把它截成两半（前面全是空行时
    // 这一行就是卡片上的第一行）
    let blanks = String(repeating: "\n", count: NoteWall.excerptScan - 20)
    let straddling = NoteWall.excerpt(of: withImages("\(blanks)前\(image)后")).text
    #expect(!straddling.contains("kitty-note-image"), "截断处不许露出半截令牌")
    #expect(straddling.contains("[图片]"))

    // 代码块：挪到这一段的坐标里；截在尾上的照样是块
    let fenced = NoteWall.excerpt(of: note("```swift\nlet a = 1\n```\n后面", title: "T"))
    #expect(fenced.blocks.count == 1 && fenced.blocks[0].open.location == 0)
    let cut = (["```"] + (1...30).map { "代码 \($0)" } + ["```"]).joined(separator: "\n")
    let open = NoteWall.excerpt(of: note(cut, title: "T"))
    #expect(open.blocks.count == 1)
    #expect(
      NoteMarkdown.role(at: (open.text as NSString).range(of: "代码 10").location, in: open.blocks)
        == .content)
  }

  /// 卡片上的字：标题、正文开头几行带编辑器同一套样式，藏着的标记删掉；Markdown 关着时按原文（任务照常）。
  /// 高：只有标题的是最矮的那张，长的到上限、超出的截断
  @Test func cardTextAndHeight() throws {
    var note = Note(
      id: "n", title: "", body: "# 标题行\n**粗体** 和 `代码`\n☑ 做完", createdAt: Self.t0,
      modifiedAt: Self.t0)
    let card = NoteWallCard.make(for: note, title: note.displayTitle, markdown: true)
    #expect(card.title.string == "标题行")
    #expect(card.body.string == "粗体 和 代码\n☑ 做完")
    let body = card.body.string as NSString
    let bold = card.body.attribute(.font, at: body.range(of: "粗体").location, effectiveRange: nil)
    #expect((bold as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(
      card.body.attribute(.backgroundColor, at: body.range(of: "代码").location, effectiveRange: nil)
        != nil)
    #expect(
      card.body.attribute(
        .strikethroughStyle, at: body.range(of: "做完").location, effectiveRange: nil)
        != nil)
    let plain = NoteWallCard.make(for: note, title: note.displayTitle, markdown: false)
    #expect(plain.body.string == "**粗体** 和 `代码`\n☑ 做完")
    // 代码块：围栏行不上卡片，块里的行垫代码的底；Markdown 关着时没有代码块
    note.body = "代码\n```swift\nlet a = 1\n```"
    let code = NoteWallCard.make(for: note, title: note.displayTitle, markdown: true)
    #expect(code.body.string == "let a = 1")
    #expect(code.body.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
    #expect(
      NoteWallCard.make(for: note, title: note.displayTitle, markdown: false).body.string
        == "```swift\nlet a = 1\n```")
    note.body = "# 标题行\n**粗体** 和 `代码`\n☑ 做完"
    // 只有标题：最矮
    note.body = ""
    note.title = "想法"
    let short = NoteWallCard.make(for: note, title: note.displayTitle, markdown: true)
    #expect(short.height == NoteWall.minHeight && short.bodyHeight == 0 && !short.overflows)
    #expect(short.titleHeight == NoteWall.titleLine)
    // 标题很长：最多两行
    note.title = String(repeating: "很长的标题", count: 20)
    let titled = NoteWallCard.make(for: note, title: note.displayTitle, markdown: true)
    #expect(titled.titleHeight == NoteWall.titleLine * 2)
    // 固定的给图钉让出一截
    note.isPinned = true
    #expect(
      NoteWallCard.make(for: note, title: note.displayTitle, markdown: true).titleWidth
        == NoteWall.textWidth - NoteWall.pinRoom)
    // 很长的正文：到上限、超出
    note.isPinned = false
    note.body = (1...40).map { "第 \($0) 行，写得长一点让它折行，看卡片怎么截断" }.joined(separator: "\n")
    let tall = NoteWallCard.make(for: note, title: note.displayTitle, markdown: true)
    #expect(tall.height == NoteWall.maxHeight && tall.overflows)
    #expect(tall.textHeight == tall.titleHeight + NoteWall.titleGap + tall.bodyRoom)
    // 几行：高随内容，在上下限之间
    note.body = "第一行\n第二行\n第三行"
    let some = NoteWallCard.make(for: note, title: note.displayTitle, markdown: true)
    #expect(some.height > NoteWall.minHeight && some.height < NoteWall.maxHeight && !some.overflows)
  }

  /// 卡片按便签缓存在仓库那一层：标题、正文、颜色、固定、Markdown 开关都没变就是同一张；哪一样变了都重建（不建时
  /// 问不到过时的）；窗口的模型换一个（关掉再开）还是那张；永久删除的跟着丢
  @Test func cardsAreCachedPerNote() throws {
    let (store, ids) = try library(["一", "二"])
    func note() throws -> Note { try #require(store.note(ids[0])) }
    #expect(store.cachedWallCard(of: try note(), markdown: true) == nil)
    let card = store.wallCard(of: try note(), markdown: true)
    #expect(store.wallCard(of: try note(), markdown: true) === card)
    #expect(store.cachedWallCard(of: try note(), markdown: true) === card)
    // Markdown 开关：换了就不是这张
    #expect(store.cachedWallCard(of: try note(), markdown: false) == nil)
    #expect(store.wallCard(of: try note(), markdown: false) !== card)
    var last = store.wallCard(of: try note(), markdown: true)
    for change in [
      { store.setBody("一改了", of: ids[0]) }, { store.setTitle("标题", of: ids[0]) },
      { store.setColor(3, of: ids[0]) }, { store.setPinned(true, of: ids[0]) },
    ] {
      change()
      #expect(store.cachedWallCard(of: try note(), markdown: true) == nil)
      let rebuilt = store.wallCard(of: try note(), markdown: true)
      #expect(rebuilt !== last)
      last = rebuilt
    }
    #expect(last.title.string == "标题")
    // 归档、挪顺序不动卡片上的字：还是那张
    store.setArchived(true, of: ids[0])
    store.setArchived(false, of: ids[0])
    store.move(ids[0], to: 1)
    #expect(store.cachedWallCard(of: try note(), markdown: true) === last)
    // 全部便签窗口的模型换了一个（关掉再开）：仓库里的还在
    _ = NotesWindowModel(store: store)
    #expect(store.cachedWallCard(of: try note(), markdown: true) === last)
    // 永久删除：跟着丢（同 summary）
    let other = try #require(store.note(ids[1]))
    _ = store.wallCard(of: other, markdown: true)
    store.delete(ids[1])
    store.erase(ids[1])
    #expect(store.cachedWallCard(of: other, markdown: true) == nil)
  }

  /// 墙怎么排（第一次进墙、开关 Markdown 不再一口气全建）：顶在 reach 以内的当场建、位置是准的，往下的先按估计的高排；
  /// 剩下的在后面几轮分批建好（cardBatches 变），之后按真的高排、和一口气全建出来的一样
  @Test func wallBuildsVisibleCardsFirst() async throws {
    let bodies = (0..<40).map { index in
      (0..<(index % 6 + 1)).map { "第 \(index) 条的第 \($0) 行" }.joined(separator: "\n")
    }
    let (store, ids) = try library(bodies)
    let model = NotesWindowModel(store: store)
    let reach: CGFloat = 300
    let layout = model.wallLayout(model.wallGroups, width: 940, reach: reach, markdown: true)
    #expect(layout.ids == ids)
    let built = ids.filter { id in
      store.note(id).flatMap { store.cachedWallCard(of: $0, markdown: true) } != nil
    }
    // 建了的是开头连着的一段，正好是顶在 reach 以内的那些
    #expect(!built.isEmpty && built.count < ids.count)
    #expect(built == Array(ids.prefix(built.count)))
    #expect(layout.frames.prefix(built.count).allSatisfy { $0.minY <= reach })
    #expect(layout.frames.dropFirst(built.count).allSatisfy { $0.minY > reach })
    #expect(
      layout.frames.dropFirst(built.count).allSatisfy { $0.height == NoteWall.estimatedHeight })
    // 剩下的分批建好
    for _ in 0..<500 {
      if ids.allSatisfy({ id in
        store.note(id).flatMap { store.cachedWallCard(of: $0, markdown: true) } != nil
      }) {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.cardBatches > 0)
    let full = model.wallLayout(model.wallGroups, width: 940, reach: reach, markdown: true)
    let heights = store.active.map { store.wallCard(of: $0, markdown: true).height }
    #expect(full == NoteWall.layout([section(ids, heights)], width: 940))
    // 开在前面的那段位置没变过（可见区里的不挪）
    #expect(Array(full.frames.prefix(built.count)) == Array(layout.frames.prefix(built.count)))
    // 开关 Markdown：又是先建可见区附近的、其余分批
    let batches = model.cardBatches
    _ = model.wallLayout(model.wallGroups, width: 940, reach: reach, markdown: false)
    for _ in 0..<500 where model.cardBatches == batches {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.cardBatches > batches)
    model.closed()
  }

  // MARK: 窗口

  /// 屏外带标题栏的窗口（同 NotesWindow 的配法，不当 key）：默认是便签墙，墙上没有正文框；点开一张有了它的编辑区，
  /// 打字按编号落；⌘W 先收回编辑卡（窗口的按键监听认），再按才轮到关窗口；换一张换一个撤销栈；切到列表右栏是选中的
  /// 那条、切回来选中的还在；最近删除里的打开是只读的（没有正文框）；空的墙
  @Test func wallInTheWindow() throws {
    let (store, ids) = try library(["甲的正文", "乙的正文"])
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = NotesWindowModel(store: store, defaults: defaults)
    #expect(model.layout == .wall)
    let hosting = NSHostingController(
      rootView: AnyView(NotesWindowView(model: model).defaultAppStorage(defaults)))
    hosting.sceneBridgingOptions = [.title, .toolbars]
    let window = WallWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 940, height: 580))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    #expect(window.screen == nil && !window.isKeyWindow)
    let settle = { for _ in 0..<8 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    func editor(_ id: String? = nil) -> NoteTextView? {
      let found = NotesWindow.editor(in: window.contentView, for: id)
      return id == nil || found?.identifier?.rawValue == id ? found : nil
    }
    func commandW() throws -> Bool {
      NotesWindow.handlesKeyDown(
        try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: UInt16(kVK_ANSI_W))),
        in: window, model: model)
    }
    settle()
    #expect(editor() == nil)

    // 点开甲：编辑卡里是它的编辑区；打字落在甲上
    model.open(ids[0], focus: false)
    settle()
    let first = try #require(editor(ids[0]))
    #expect(first.undoManager === model.textUndo)
    #expect(window.makeFirstResponder(first))
    first.setSelectedRange(NSRange(location: 4, length: 0))
    first.insertText("，加一句", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(store.note(ids[0])?.body == "甲的正文，加一句")
    // ⌘W：收回编辑卡（窗口不关），编辑区跟着拆掉
    #expect(try commandW() && model.expanded == nil && window.isVisible)
    settle()
    #expect(editor() == nil)
    #expect(try !commandW())

    // 换一张：新的撤销栈；甲里打的字和它无关
    let firstUndo = model.textUndo
    model.open(ids[1], focus: false)
    settle()
    let second = try #require(editor(ids[1]))
    #expect(model.textUndo !== firstUndo && second.undoManager === model.textUndo)
    #expect(window.makeFirstResponder(second))
    second.insertText("！", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(store.note(ids[1])?.body.hasSuffix("！") == true)
    #expect(store.note(ids[0])?.body == "甲的正文，加一句")

    // 开着编辑卡切到列表：收回，右栏是选中的那条；记下来了
    model.layout = .list
    settle()
    #expect(model.expanded == nil && model.selection == ids[1])
    #expect(editor(ids[1]) != nil)
    #expect(defaults.string(forKey: Prefs.notesWindowLayout) == "list")
    model.layout = .wall
    settle()
    #expect(model.selection == ids[1] && editor() == nil)

    // 最近删除里的：打开是只读的
    store.delete(ids[0])
    model.scope = .trash
    model.open(ids[0], focus: false)
    settle()
    #expect(model.expanded == ids[0] && editor() == nil)
    model.collapse()

    // 空的墙（换一个空库）
    let empty = NotesWindowModel(store: try NoteStore(db: Database(path: ":memory:")))
    hosting.rootView = AnyView(NotesWindowView(model: empty).defaultAppStorage(defaults))
    settle()
    #expect(empty.layout == .wall && empty.notes.isEmpty && editor() == nil)
  }
}

extension NoteWallTests {
  /// 屏外带标题栏的窗口（同 wallInTheWindow）
  private func wallWindow(_ model: NotesWindowModel, defaults: UserDefaults) -> NSWindow {
    let window = WallWindow(
      contentViewController: .windowContent(
        AnyView(NotesWindowView(model: model).defaultAppStorage(defaults))))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 940, height: 580))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    return window
  }

  /// 编辑卡收回之后焦点回到墙上（不管从哪条路收回：工具栏 / 快捷键删除、归档，在别处删了）——方向键、↩、⌫ 接着用；
  /// 从那叠打开（不给正文焦点）时焦点也在墙上，不留在被暗层盖住的搜索框里；按编号找正文框找不到就是没有
  @Test func collapsingReturnsFocusToTheWall() throws {
    let (store, ids) = try library(["甲", "乙", "丙", "丁"])
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = NotesWindowModel(store: store, defaults: defaults)
    let window = wallWindow(model, defaults: defaults)
    defer { window.orderOut(nil) }
    #expect(window.screen == nil && !window.isKeyWindow)
    let settle = { for _ in 0..<8 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    func editor(_ id: String) -> NoteTextView? {
      NotesWindow.editor(in: window.contentView, for: id)
    }
    /// 焦点在墙上：第一响应者是 SwiftUI 的宿主那边的视图，不是输入框（正文、标题、搜索框的字段编辑器），也不是没人拿着
    func wallHasFocus() -> Bool {
      guard let view = window.firstResponder as? NSView, !(view is NSText) else { return false }
      return view.isDescendant(of: try! #require(window.contentView))
    }
    settle()

    let removals: [(name: String, run: (String) -> Void)] = [
      ("删除", { model.delete($0) }), ("归档", { model.toggleArchived($0) }),
      ("在别处删了", { store.delete($0) }),
    ]
    for (id, removal) in zip(ids, removals) {
      model.open(id, focus: false)
      settle()
      let body = try #require(editor(id))
      #expect(window.makeFirstResponder(body))
      removal.run(id)
      settle()
      #expect(model.expanded == nil, "\(removal.name)")
      #expect(editor(id) == nil, "\(removal.name)")
      print(
        "notes-wall first responder after \(removal.name):",
        window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
      #expect(wallHasFocus(), "\(removal.name)")
    }
    // 找正文框：给了编号就只要那一条的
    model.open(ids[3], focus: false)
    settle()
    #expect(editor(ids[3]) != nil && NotesWindow.editor(in: window.contentView, for: ids[0]) == nil)
    #expect(NotesWindow.editor(in: window.contentView) != nil)
    // 从那叠打开：焦点在墙上（先把焦点放进搜索框）
    model.collapse()
    model.focusSearch()
    settle()
    #expect(window.firstResponder is NSText)
    model.reveal(ids[3])
    settle()
    #expect(model.isEditing && wallHasFocus())
  }
}

extension NoteWallTests {
  /// 开 / 关编辑卡时墙不重新求值（放大、收回的动画期间也不，收回放完拆掉那块纸也不）：墙是一个只看排法和卡片的子视图，
  /// 编辑卡那一层（暗、纸、编辑区）和「放大着的那张淡掉」都不挂在它上面——原来每开 / 关一次整面墙要重新求值四五遍，
  /// 300 条时每遍约 10 ms，正卡在点开、收回的那一下和收回动画的末尾
  @Test func wallStaysPutWhileTheEditorOpens() throws {
    let (store, ids) = try library(["甲", "乙", "丙", "丁"])
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = NotesWindowModel(store: store, defaults: defaults)
    let window = wallWindow(model, defaults: defaults)
    defer { window.orderOut(nil) }
    #expect(window.screen == nil && !window.isKeyWindow)
    let settle = { for _ in 0..<10 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    settle()
    model.selection = ids[1]
    settle()
    let start = model.wallEvaluations
    #expect(start > 0)
    // 点开选中的那张（↩、点它）、收回；再从那叠打开一张（不给正文焦点、墙拿焦点）、Esc 收回
    model.open(ids[1])
    settle()
    #expect(model.isEditing && NotesWindow.editor(in: window.contentView, for: ids[1]) != nil)
    model.collapse()
    settle()
    model.open(ids[1], focus: false)
    settle()
    model.collapse()
    settle()
    #expect(!model.isEditing && NotesWindow.editor(in: window.contentView, for: ids[1]) == nil)
    #expect(model.wallEvaluations == start)
    // 墙在意的变了（固定一张：排法变了）照样重新求值
    model.togglePinned(ids[2])
    settle()
    #expect(model.wallEvaluations > start)
  }
}

/// 带标题栏的窗口摆在屏外（系统默认会把它挪回屏幕里）
private final class WallWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
