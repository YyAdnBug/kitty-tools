// 全部便签窗口「便签墙」的单测（2026-10-15 手测反馈；Notes/NoteWall.swift、NotesWallView.swift、NotesWindowModel）：
// - 纯函数：按宽度排几列、瀑布流的摆法（两段、小标题、空段）、倾斜的大小和方向、方向键在卡片之间怎么走、指针下是哪张、
//   拖动排序落到哪、落成仓库的哪个下标（固定的和没固定的混着排）、编辑卡多大、卡片上带正文的哪一段、卡片上的字
//   （标记删掉、样式跟编辑器一样）和高；
// - 模型：显示方式的偏好（临时域）、打开 / 收回编辑卡和选中的关系、新建 / 从那叠打开、方向键、拖动排序写回仓库、
//   卡片的缓存；
// - 窗口接线：屏外带标题栏的窗口（不当 key、不激活），默认是便签墙；点开 / 收回编辑卡（⌘W 由窗口认）、编辑卡里打字
//   按编号落、撤销栈各归各、切到列表再切回来选中的还在、最近删除里只读、空的墙。
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
    // 编辑卡里打字（按编号落），收回时落盘
    model.setBody("B 改了", of: ids[1])
    let focus = model.wallFocus
    model.collapse()
    #expect(model.expanded == nil && model.wallFocus == focus + 1)
    #expect(store.note(ids[1])?.body == "B 改了")
    model.collapse()
    #expect(model.wallFocus == focus + 1)
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

  /// 卡片按便签缓存：标题、正文、颜色、固定、Markdown 开关都没变就是同一个；变了重建
  @Test func cardsAreCachedPerNote() throws {
    let (store, ids) = try library(["一", "二"])
    let model = NotesWindowModel(store: store)
    let note = try #require(store.note(ids[0]))
    let card = model.card(note, markdown: true)
    #expect(model.card(note, markdown: true) === card)
    #expect(model.card(note, markdown: false) !== card)
    store.setBody("一改了", of: ids[0])
    let changed = model.card(try #require(store.note(ids[0])), markdown: true)
    #expect(changed !== card && changed.title.string == "一改了")
    store.setPinned(true, of: ids[0])
    #expect(model.card(try #require(store.note(ids[0])), markdown: true) !== changed)
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

/// 带标题栏的窗口摆在屏外（系统默认会把它挪回屏幕里）
private final class WallWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
