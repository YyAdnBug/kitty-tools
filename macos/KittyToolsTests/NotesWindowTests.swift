// 便签第 2 批的单测（PLAN §10「便签」）：
// - 全部便签窗口的模型（Notes/NotesWindow.swift）：三个视图的筛选和搜索、选中项在删除 / 归档 / 搜索 / 换视图后落到哪、
//   删除的撤销栈和 ⌘Z 归谁、最近删除里的放回 / 永久删除 / 清空、换色轮转、新建（最前面那条是空白的就用它）、拖动排序、
//   行上的相对时间和底下那行小字、正文到上限的标记；
// - 纸色表（Notes/NotePaper.swift）：8 色两套都有、墨对纸够 4.5:1、深色那套还是同一个色相；
// - 三个入口：热键动作追加在末尾、默认键、分节、启动器 / 速查表 / 设置页 / 导入的快捷键里都有；
// - 普通窗口关掉时程序坞图标留不留、字号偏好。
// 全用内存库和固定的时间；不建真的全部便签窗口（有标题栏的窗口摆不到屏外），不写用户的偏好。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

struct NotesWindowTests {
  private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
  private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }()
  private static func moment(day: Int = 8, hour: Int = 9, minute: Int = 12) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  /// 内存库上的仓库和窗口的模型。bodies 就是「全部」里从上到下的顺序（新建的排最前，所以倒着建）
  private func make(_ bodies: [String] = [], db: Database? = nil) throws -> (
    model: NotesWindowModel, store: NoteStore, ids: [String]
  ) {
    let store = try NoteStore(db: db ?? Database(path: ":memory:"))
    for (offset, body) in bodies.reversed().enumerated() {
      store.create(body: body, now: Self.at(Double(offset)))
    }
    return (NotesWindowModel(store: store), store, store.active.map(\.id))
  }

  /// 撤销栈里的一步「打的字」
  private final class Typing: NSObject {
    var undone = 0
    @objc func undo(_ sender: Any?) { undone += 1 }
  }

  private func shown(_ model: NotesWindowModel) -> [String] { model.notes.map(\.id) }

  // MARK: 列表

  /// 三个视图各列各的；搜索只在当前视图里搜（标题和正文）；打开时选中第一条，换视图、改搜索词后选中的跟着走
  @Test func scopesFilterAndSearch() throws {
    let (model, store, ids) = try make(["买菜 牛奶", "周报", "读书笔记"])
    #expect(shown(model) == ids && model.selection == ids[0] && model.current?.id == ids[0])
    store.setArchived(true, of: ids[1])
    store.delete(ids[2], now: Self.at(100))
    #expect(model.list(.all).map(\.id) == [ids[0]])
    #expect(model.list(.archive).map(\.id) == [ids[1]])
    #expect(model.list(.trash).map(\.id) == [ids[2]])
    #expect(NotesWindowModel.Scope.allCases.map(\.title) == ["全部", "归档", "最近删除"])

    model.scope = .archive
    #expect(shown(model) == [ids[1]] && model.selection == ids[1])
    model.scope = .trash
    #expect(shown(model) == [ids[2]] && model.current?.id == ids[2])
    #expect(!model.canReorder)
    model.scope = .all
    #expect(model.selection == ids[0] && model.canReorder)

    store.setTitle("采购", of: ids[0], now: Self.at(200))
    for query in ["牛奶", "采购", "买菜  牛奶", "NIUNAI"] {
      model.query = query
      #expect(shown(model) == (query == "NIUNAI" ? [] : [ids[0]]), "\(query)")
    }
    #expect(model.selection == nil && model.current == nil && !model.canReorder)
    // 归档的那条在「全部」里搜不到，到「归档」里才有
    model.query = "周报"
    #expect(shown(model).isEmpty)
    model.scope = .archive
    #expect(shown(model) == [ids[1]] && model.selection == ids[1])
    model.query = ""
    model.scope = .all
    #expect(model.selection == ids[0])
  }

  /// 正在改的那条被搜索词筛掉了：列表里没有它，编辑区还是它（不把人从打了一半的字里赶走）
  @Test func editingKeepsSelectionWhenFilteredOut() throws {
    let (model, store, ids) = try make(["牛奶", "面包"])
    model.query = "牛奶"
    #expect(model.selection == ids[0])
    store.setBody("改成了豆浆", of: ids[0], now: Self.at(50))
    #expect(shown(model).isEmpty && model.selection == ids[0] && model.current?.id == ids[0])
    // 别处把它删了：编辑区不再显示它
    store.delete(ids[0])
    #expect(model.current == nil)
  }

  @Test func selectionRules() {
    let keep = NotesWindowModel.selection(keeping:in:)
    #expect(keep("b", ["a", "b"]) == "b")
    #expect(keep("x", ["a", "b"]) == "a" && keep(nil, ["a", "b"]) == "a")
    #expect(keep("x", []) == nil && keep(nil, []) == nil)
    let after = NotesWindowModel.selection(afterRemoving:from:)
    #expect(after("b", ["a", "b", "c"]) == "c")
    #expect(after("c", ["a", "b", "c"]) == "b")
    #expect(after("a", ["a"]) == nil && after("x", ["a", "b"]) == nil)
    #expect(
      NotesWindowModel.belongs(Note(id: "n", createdAt: Self.t0, modifiedAt: Self.t0), to: .all))
  }

  // MARK: 删除和撤销

  /// 删除进「最近删除」，选中挪到顶上来的那条（最后一条就挪到上一条）；⌘Z 一条条放回原处并选中它
  @Test func deleteMovesSelectionAndUndoRestores() throws {
    let (model, store, ids) = try make(["A", "B", "C"])
    model.selection = ids[1]
    model.delete(ids[1])
    #expect(store.trashed.map(\.id) == [ids[1]] && model.selection == ids[2])
    model.delete(ids[2])
    #expect(model.selection == ids[0] && model.undoStack == [ids[1], ids[2]])
    // 右键删一条没选中的：选中的不动
    let extra = store.create(body: "D", now: Self.at(500)).id
    model.delete(extra)
    #expect(model.selection == ids[0] && model.undoStack.last == extra)

    #expect(model.undoDelete() && model.selection == extra)
    #expect(model.undoDelete() && model.selection == ids[2])
    #expect(model.undoDelete() && model.selection == ids[1])
    #expect(store.active.map(\.id) == [extra] + ids && store.trashed.isEmpty)
    #expect(!model.undoDelete() && model.undoStack.isEmpty)
  }

  /// 栈里的那条已经不在「最近删除」里了（自己放回了、永久删了）就跳过；归档里删的放回归档；被搜索词挡着就清掉搜索词；
  /// 窗口关掉时栈清空
  @Test func undoStackEdgeCases() throws {
    let (model, store, ids) = try make(["A", "B", "C"])
    model.delete(ids[0])
    model.delete(ids[1])
    model.delete(ids[2])
    store.restore(ids[2])
    store.erase(ids[1])
    #expect(model.undoDelete() && model.selection == ids[0] && model.undoStack.isEmpty)

    store.setArchived(true, of: ids[2])
    model.scope = .archive
    model.delete(ids[2])
    model.scope = .all
    model.query = "A"
    #expect(model.undoDelete())
    #expect(model.scope == .archive && model.query.isEmpty && model.selection == ids[2])
    #expect(store.archived.map(\.id) == [ids[2]])

    model.scope = .all
    model.delete(ids[0])
    model.closed()
    #expect(model.undoStack.isEmpty && !model.undoDelete())
    #expect(store.trashed.map(\.id) == [ids[0]])
  }

  /// ⌘Z：焦点所在的输入框自己还有可撤销的打字，归它；否则先放回刚删的，再轮到正文里打的字。
  /// ⇧⌘Z：重做焦点所在输入框的；焦点不在输入框里看正文的
  @Test func undoGoesToTextWhileEditing() throws {
    let (model, store, ids) = try make(["A", "B"])
    let typing = Typing()
    func type(in stack: UndoManager) {
      stack.groupsByEvent = false
      stack.beginUndoGrouping()
      stack.registerUndo(withTarget: typing, selector: #selector(Typing.undo(_:)), object: nil)
      stack.endUndoGrouping()
    }
    // 右键删掉没选中的那条（选中的不变，打的字还在撤销栈里）。焦点在正文里：正文的栈就是 textUndo
    type(in: model.textUndo)
    model.delete(ids[1])
    // 焦点所在输入框的栈（窗口那边是 NSWindow.undoFocusedText；这里拿一个栈顶替）
    func focus(on stack: UndoManager?) {
      model.undoFocusedText = { redo in
        guard let stack, redo ? stack.canRedo : stack.canUndo else { return false }
        if redo { stack.redo() } else { stack.undo() }
        return true
      }
    }
    focus(on: model.textUndo)
    model.undo()
    #expect(typing.undone == 1 && store.trashed.count == 1)
    model.undo()
    #expect(store.trashed.isEmpty && typing.undone == 1)
    // ⇧⌘Z：重做刚撤销的（撤销动作里没再登记，这里只看它问的是焦点所在的那个栈）
    var asked: [Bool] = []
    model.undoFocusedText = {
      asked.append($0)
      return true
    }
    model.redo()
    #expect(asked == [true])

    // 焦点在标题框 / 搜索框里：动的是那个输入框自己的栈（字段编辑器的），不去撤正文里打的字
    let field = UndoManager()
    type(in: model.textUndo)
    type(in: field)
    focus(on: field)
    model.undo()
    #expect(typing.undone == 2 && !field.canUndo && model.textUndo.canUndo)
    // 它没有可撤销的了：没有刚删的便签，才轮到正文里打的字
    model.undo()
    #expect(typing.undone == 3 && !model.textUndo.canUndo)

    // 焦点不在输入框里：先放回刚删的，再撤销打的字
    model.selection = ids[0]
    type(in: model.textUndo)
    model.delete(ids[1])
    focus(on: nil)
    model.undo()
    #expect(store.trashed.isEmpty && typing.undone == 3)
    // 放回时选中了它 = 换了一条便签：上一条里打的字的撤销栈作废，不会撤到这一条上
    #expect(model.selection == ids[1] && !model.textUndo.canUndo)
  }

  /// 换一条便签、窗口失去 key、窗口关闭：打字攒着的改动落盘；换一条时撤销栈换新的，「到上限」的标记收掉
  @Test func changingSelectionFlushesAndResetsEditorState() throws {
    let db = try Database(path: ":memory:")
    let (model, store, ids) = try make(["A", "B"], db: db)
    let onDisk = { (id: String) in try NoteStore(db: db).note(id)?.body }
    let manager = model.textUndo
    model.overflowed()
    #expect(model.isOverLimit)
    // 打字的改动先攒着（仓库停手 250 ms 才落；这里没让出主线程，它排的那一下跑不到）
    model.setBody("改了", of: ids[0])
    #expect(!model.isOverLimit && store.note(ids[0])?.body == "改了")
    #expect(try onDisk(ids[0]) == "A")
    model.overflowed()
    model.selection = ids[1]
    #expect(try onDisk(ids[0]) == "改了")
    #expect(!model.isOverLimit && model.textUndo !== manager)
    // 选回同一条不算换
    let same = model.textUndo
    model.selection = ids[1]
    #expect(model.textUndo === same)

    model.setTitle("标题", of: ids[1])
    #expect(try NoteStore(db: db).note(ids[1])?.title == "")
    model.resignedKey()
    #expect(try NoteStore(db: db).note(ids[1])?.title == "标题")
    model.setBody("关窗前打的", of: ids[1])
    model.closed()
    #expect(try onDisk(ids[1]) == "关窗前打的")
  }

  // MARK: 最近删除

  /// 最近删除里：⌘⌫ 是永久删除、先等确认；放回回到原来的视图；清空全部永久删除
  @Test func trashActions() throws {
    let (model, store, ids) = try make(["A", "B", "C", "D"])
    for id in ids.dropFirst() { model.delete(id) }
    model.scope = .trash
    let trashed = shown(model)
    #expect(Set(trashed) == Set(ids.dropFirst()) && model.selection == trashed[0])

    model.delete(trashed[0])
    #expect(model.erasing == trashed[0] && store.note(trashed[0]) != nil)
    model.erase(trashed[0])
    #expect(store.note(trashed[0]) == nil && model.selection == trashed[1])

    model.restore(trashed[1])
    #expect(store.active.contains { $0.id == trashed[1] } && model.selection == trashed[2])
    // 没删的不能「放回」
    model.restore(ids[0])
    #expect(store.active.count == 2)

    #expect(store.emptyTrash() == 1 && store.trashed.isEmpty)
    #expect(store.emptyTrash() == 0)
    model.delete(ids[0])
    model.scope = .trash
    model.emptyTrash()
    #expect(store.trashed.isEmpty && model.selection == nil && shown(model).isEmpty)
    // 落盘了：另开一个仓库读到的也是清空之后的
    #expect(store.saveProblem == nil)
  }

  // MARK: 归档、固定、颜色、新建、排序

  @Test func archivePinAndColor() throws {
    let (model, store, ids) = try make(["A", "B"])
    model.toggleArchived(ids[0])
    #expect(store.archived.map(\.id) == [ids[0]] && model.selection == ids[1])
    model.scope = .archive
    model.toggleArchived(ids[0])
    #expect(store.active.map(\.id) == ids && model.selection == nil)
    model.scope = .all

    model.togglePinned(ids[1])
    #expect(store.note(ids[1])?.isPinned == true)
    #expect(NotesWindowModel.pinTitle(store.note(ids[1])) == "取消固定")
    #expect(NotesWindowModel.pinTitle(store.note(ids[0])) == "固定")
    #expect(NotesWindowModel.pinTitle(nil) == "固定" && NotesWindowModel.archiveTitle(nil) == "归档")
    model.togglePinned(ids[1])
    #expect(store.note(ids[1])?.isPinned == false)

    #expect((0..<Note.colorCount).map(NotesWindowModel.nextColor) == [1, 2, 3, 4, 5, 6, 7, 0])
    #expect(NotesWindowModel.nextColor(after: -3) == 1)
    let before = try #require(store.note(ids[0])?.color)
    model.cycleColor(ids[0])
    #expect(store.note(ids[0])?.color == NotesWindowModel.nextColor(after: before))
    model.setColor(5, of: ids[0])
    #expect(store.note(ids[0])?.color == 5)
    // 最近删除里的不能改
    model.delete(ids[0])
    model.setColor(2, of: ids[0])
    model.cycleColor(ids[0])
    model.togglePinned(ids[0])
    model.toggleArchived(ids[0])
    let deleted = try #require(store.note(ids[0]))
    #expect(deleted.color == 5 && !deleted.isPinned && !deleted.isArchived)
  }

  /// 新建：排最前、选中、焦点进正文、回到「全部」并清掉搜索词；最前面那条还是空白的就用它，不多建
  @Test func createReusesBlankNoteOnTop() throws {
    let (model, store, _) = try make()
    var focused = 0
    model.focusBody = { focused += 1 }
    #expect(model.selection == nil && model.current == nil)
    model.create()
    let first = try #require(store.active.first?.id)
    #expect(store.notes.count == 1 && model.selection == first && focused == 1)
    model.create()
    #expect(store.notes.count == 1 && model.selection == first && focused == 2)

    model.setBody("写了字", of: first)
    model.scope = .trash
    model.query = "找不到的"
    model.create()
    #expect(store.notes.count == 2 && model.scope == .all && model.query.isEmpty)
    #expect(model.selection == store.active.first?.id && model.selection != first)
    // 只写了标题的不算空白
    model.setTitle("只有标题", of: store.active[0].id)
    model.create()
    #expect(store.notes.count == 3)
  }

  @Test func dragReorders() throws {
    #expect(NotesWindowModel.landingIndex(from: 0, to: 2) == 1)
    #expect(NotesWindowModel.landingIndex(from: 0, to: 3) == 2)
    #expect(NotesWindowModel.landingIndex(from: 2, to: 0) == 0)
    #expect(NotesWindowModel.landingIndex(from: 1, to: 1) == 1)

    let (model, store, ids) = try make(["A", "B", "C"])
    model.move(from: IndexSet(integer: 0), to: 3)
    #expect(store.active.map(\.id) == [ids[1], ids[2], ids[0]])
    model.move(from: IndexSet(integer: 2), to: 0)
    #expect(store.active.map(\.id) == ids)
    model.move(from: IndexSet(integer: 1), to: 3)
    #expect(store.active.map(\.id) == [ids[0], ids[2], ids[1]])
    // 搜索时、别的视图里不排
    model.query = "A"
    model.move(from: IndexSet(integer: 0), to: 3)
    model.query = ""
    model.scope = .archive
    model.move(from: IndexSet(integer: 0), to: 3)
    #expect(store.active.map(\.id) == [ids[0], ids[2], ids[1]])
  }

  // MARK: 文字

  /// 行右边的相对时间看「改于」（最近删除里看删的时间）；底下那行小字写改于什么时候、多少字（空白不算）
  @Test func timeTexts() throws {
    let (_, store, _) = try make()
    let now = Self.moment(hour: 10, minute: 0)
    let note = store.create(body: "你好 world\n\t第二行", now: Self.moment())
    #expect(NotesWindowModel.ago(note, now: Self.moment()) == "现在")
    #expect(NotesWindowModel.ago(note, now: Self.moment(minute: 15)) == "3分钟前")
    #expect(NotesWindowModel.ago(note, now: Self.moment(day: 9)) == "昨天")
    #expect(
      NotesWindowModel.footnote(note, now: now, calendar: Self.calendar) == "改于 今天 09:12 · 10 字")
    #expect(
      NotesWindowModel.footnote(note, now: Self.moment(day: 9), calendar: Self.calendar)
        == "改于 昨天 09:12 · 10 字")

    store.delete(note.id, now: Self.moment(day: 9, hour: 22, minute: 40))
    let deleted = try #require(store.note(note.id))
    let later = Self.moment(day: 10, hour: 8, minute: 40)
    #expect(NotesWindowModel.ago(deleted, now: later) == "10小时前")
    #expect(
      NotesWindowModel.footnote(deleted, now: later, calendar: Self.calendar)
        == "删于 昨天 22:40 · 30 天后永久删除")
    let nearEnd = Self.moment(day: 9, hour: 22, minute: 40).addingTimeInterval(29.5 * 86_400)
    #expect(
      NotesWindowModel.footnote(deleted, now: nearEnd, calendar: Self.calendar)
        .hasSuffix("1 天后永久删除"))
    let overdue = Self.moment(day: 9, hour: 22, minute: 40).addingTimeInterval(31 * 86_400)
    #expect(
      NotesWindowModel.footnote(deleted, now: overdue, calendar: Self.calendar)
        .hasSuffix("即将永久删除"))
  }

  /// F19：底下的「N 字」不数图片的令牌（一张图算 0 个字，不是六七十个）
  @Test func footnoteDoesNotCountImageTokens() throws {
    let (_, store, _) = try make()
    let image = NoteImages.token(NoteImages.Image(id: UUID(), ext: "png"))
    let note = store.create(body: "你好\n\(image)\n世界", now: Self.moment())
    #expect(
      NotesWindowModel.footnote(note, now: Self.moment(hour: 10), calendar: Self.calendar)
        == "改于 今天 09:12 · 4 字")
  }

  // MARK: 纸色

  /// 8 种纸色、名字不重；浅色那套是说明里给的值；两套的墨对纸、次要的字对纸都够 4.5:1；深色那套的色条还是同一个色相。
  /// 正文里的 Markdown 用的几种色（第 6 批）：墨压在行内代码的底上够 7:1（16 套都是）；平时两种外观下各取的是哪一档；
  /// 露出来的标记增强对比度那档比平时深。**增强对比度那一档取不取得到这里验不了**：系统开关关着时按名字造出来的
  /// 高对比外观就是普通外观（实测 macOS 15.7），要真机开着开关看（HANDTEST「便签手测」）
  @Test func paperTable() {
    let papers = NotePaper.all
    #expect(papers.count == Note.colorCount && Set(papers.map(\.name)).count == papers.count)
    #expect(papers.map(\.name) == ["柠檬", "桃", "玫瑰", "丁香", "天蓝", "薄荷", "沙", "石板"])
    #expect(papers[0].light == .init(paper: 0xFCE795, strip: 0xE0AD08, ink: 0x3A3008))
    #expect(papers[7].light == .init(paper: 0xCBD6E2, strip: 0x4E6579, ink: 0x1A242E))
    // 增强对比度那档的标记比平时深；这几个数就是下面按外观核对的那几档
    #expect(NotePaper.markerContrastOpacity > NotePaper.markerOpacity)
    #expect(NotePaper.markerOpacity == 0.35 && NotePaper.markerContrastOpacity == 0.6)
    #expect(NotePaper.codeFillOpacity == 0.08 && NotePaper.secondaryOpacity == 0.75)
    /// 动态色在这个外观下取到的：[0xRRGGBB, 不透明度的百分数]
    func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> [Int] {
      var parts: [Int] = []
      NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        parts = [
          channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8
            | channel(rgb.blueComponent),
          Int((rgb.alphaComponent * 100).rounded()),
        ]
      }
      return parts
    }
    let mix = { (ink: Int, paper: Int, opacity: Double) -> NSColor in
      let (a, b) = (srgb(ink), srgb(paper))
      let channel = { (x: CGFloat, y: CGFloat) in x * opacity + y * (1 - opacity) }
      return NSColor(
        srgbRed: channel(a.redComponent, b.redComponent),
        green: channel(a.greenComponent, b.greenComponent),
        blue: channel(a.blueComponent, b.blueComponent), alpha: 1)
    }
    for paper in papers {
      for (tone, name) in [(paper.light, "浅"), (paper.dark, "深")] {
        #expect(
          AccentPalette.contrast(srgb(tone.ink), srgb(tone.paper)) >= 7, "\(paper.name) \(name)")
        let secondary = mix(tone.ink, tone.paper, NotePaper.secondaryOpacity)
        #expect(
          AccentPalette.contrast(secondary, srgb(tone.paper)) >= 4.5, "\(paper.name) \(name) 次要")
        // 色条在纸上看得出来（圆点的圈、顶上那一条）
        #expect(
          AccentPalette.contrast(srgb(tone.strip), srgb(tone.paper)) >= 1.5,
          "\(paper.name) \(name) 色条")
        // 行内代码、代码块（连围栏行）：墨压在代码的底（纸上叠一层墨）上。围栏行原来是标记那一档（墨 35%，压在底上
        // 最低 1.67:1）；次要的墨（75%）真叠在底上沙色浅纸是 4.498:1，不到 4.5——所以围栏行也用墨（评审后那一轮查的）
        let fill = mix(tone.ink, tone.paper, NotePaper.codeFillOpacity)
        #expect(AccentPalette.contrast(srgb(tone.ink), fill) >= 7, "\(paper.name) \(name) 代码")
      }
      // 平时（没开增强对比度）两种外观下取到的：代码的底是墨的 8%、标记是墨的 35%、引用的竖线是色条色、
      // 引用的字是墨的 75%
      for (appearance, tone) in [(NSAppearance.Name.aqua, paper.light), (.darkAqua, paper.dark)] {
        let label = "\(paper.name) \(appearance.rawValue)"
        #expect(resolved(paper.codeFillColor, appearance) == [tone.ink, 8], "\(label) 代码的底")
        #expect(resolved(paper.markerInkColor, appearance) == [tone.ink, 35], "\(label) 标记")
        #expect(resolved(paper.quoteBarColor, appearance) == [tone.strip, 100], "\(label) 竖线")
        #expect(resolved(paper.secondaryInkColor, appearance) == [tone.ink, 75], "\(label) 引用")
      }
      // 深色外观下纸是深的、字是浅的
      #expect(AccentPalette.luminance(srgb(paper.dark.paper)) < 0.08, "\(paper.name)")
      #expect(AccentPalette.luminance(srgb(paper.light.paper)) > 0.6, "\(paper.name)")
      // 同一个色相（石板、沙这种灰的也在 25° 以内）
      let hue = { (hex: Int) in srgb(hex).hueComponent * 360 }
      let gap = abs(hue(paper.light.strip) - hue(paper.dark.strip))
      #expect(min(gap, 360 - gap) <= 25, "\(paper.name) 色相差 \(gap)")
    }
    // 越界的下标不崩
    var note = Note(id: "n", createdAt: Self.t0, modifiedAt: Self.t0)
    note.color = 99
    #expect(NotePaper.of(note) == papers[7])
    note.color = -1
    #expect(NotePaper.of(note) == papers[0])
    #expect(papers[2].swatch().size == NSSize(width: 12, height: 12))
  }

  /// 便签的家族黄太亮：种类色块上的符号用深色，别的家族照旧是白的
  @Test func tileInkOnYellow() {
    #expect(Style.Family.onTile(Style.Family.notes) != .white)
    for color in [Style.Family.clipboard, Style.Family.keyboard, Style.Family.statusScreen] {
      #expect(Style.Family.onTile(color) == .white)
    }
    #expect(AccentPalette.contrast(.white, .systemYellow) < 3)
    #expect(AccentPalette.contrast(NSColor.black.withAlphaComponent(0.85), .systemYellow) >= 4.5)
  }

  // MARK: 入口

  /// 三个全局动作追加在末尾（注册 id 是下标；启动台又接在它们后面）；只有「快速记一条」有默认键 ⌥N；
  /// 「便签」一节在「截图与录制」之后、「启动台」之前，三项按这个顺序
  @Test func hotKeyActions() throws {
    #expect(
      Array(HotKeyAction.allCases.suffix(4)) == [.noteCapture, .noteNew, .noteAll, .launchpad])
    #expect(
      HotKeyAction.noteCapture.defaultHotKey == HotKey(keyCode: kVK_ANSI_N, modifiers: optionKey))
    #expect(HotKeyAction.noteNew.defaultHotKey == nil && HotKeyAction.noteAll.defaultHotKey == nil)
    let titles = HotKeyAction.sections.map(\.title)
    let index = try #require(titles.firstIndex(of: "便签"))
    #expect(titles[index - 1] == "截图与录制" && titles[index + 1] == "启动台")
    let actions = HotKeyAction.sections[index].actions
    #expect(actions == [.noteCapture, .noteNew, .noteAll])
    #expect(actions.map(\.title) == ["快速记一条", "新建便签", "全部便签"])
    #expect(actions.allSatisfy { $0.color == Style.Family.notes })
    #expect(Set(actions.map(\.symbol)).count == 3)
    for symbol in actions.map(\.symbol) + ["rectangle.split.2x1", "archivebox", "trash.slash"] {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
    // 默认键让给用户自己设的：别的动作存了 ⌥N，快速记一条没设过就当没设
    let optionN = try JSONEncoder().encode(HotKey(keyCode: kVK_ANSI_N, modifiers: optionKey))
    #expect(HotKeyAction.noteCapture.resolve { $0 == .noteNew ? optionN : nil } == nil)
    #expect(HotKeyAction.noteCapture.resolve { _ in nil } != nil)
  }

  /// 启动器的内置动作、速查表、设置页、导入的快捷键里都有这三项，同名同序
  @Test func entriesEverywhere() throws {
    let launcher = LauncherItem.actions()
    let targets = launcher.map(\.target)
    let start = try #require(targets.firstIndex(of: "noteCapture"))
    #expect(Array(targets[start..<start + 3]) == ["noteCapture", "noteNew", "noteAll"])
    #expect(
      targets[start - 1] == "pinClipboard" && targets[start + 3] == "launchpad"
        && targets[start + 4] == "settings")
    #expect(launcher[start..<start + 3].map(\.title) == ["快速记一条", "新建便签", "全部便签"])
    for item in launcher[start..<start + 3] {
      #expect(item.symbol == item.hotKeyAction?.symbol, "\(item.title)")
      for query in ["便签", "note", "bianqian"]
      where item.target != "noteCapture" || query != "bianqian" {
        #expect(LauncherMatch.score(query, item: item) > 0, "\(item.title) \(query)")
      }
    }
    #expect(LauncherMatch.score("ksj", item: launcher[start]) > 0)

    let group = try #require(ShortcutsSheet.groups.first { $0.title == "便签" })
    #expect(
      group.globals == [.noteCapture, .noteNew, .noteAll] && group.color == Style.Family.notes)
    let titles = ShortcutsSheet.groups.map(\.title)
    // 第 3 批在中间加了「屏幕边缘」一组，第 4 批在它后面加了「浮在屏幕上」一小组
    #expect(titles.firstIndex(of: "便签")! + 1 == titles.firstIndex(of: "便签 · 屏幕边缘")!)
    #expect(titles.firstIndex(of: "便签 · 屏幕边缘")! + 1 == titles.firstIndex(of: "便签 · 浮在屏幕上")!)
    #expect(titles.firstIndex(of: "便签 · 浮在屏幕上")! + 1 == titles.firstIndex(of: "便签 · 全部便签")!)
    // 2026-10-18 起「启动台」一节排在便签之后、状态屏之前
    #expect(titles.firstIndex(of: "便签 · 全部便签")! + 1 == titles.firstIndex(of: "启动台")!)
    #expect(titles.firstIndex(of: "启动台")! + 1 == titles.firstIndex(of: "状态屏")!)
    let keys = Set(
      ShortcutsSheet.groups.filter { $0.title.hasPrefix("便签") }.flatMap(\.entries).flatMap(\.keys))
    #expect(
      keys.isSuperset(of: [
        "↩", "⇧↩", "⌘1", "⌘2–9", "Esc", "⌘N", "⌘F", "⌘⌫", "⌘Z", "⇧⌘A", "⌘P", "⌘.", "⌘K", "⌘W",
        "Tab",
      ]))

    let pages = SettingsPage.allCases
    #expect(pages[pages.firstIndex(of: .record)! + 1] == .notes)
    #expect(SettingsPage.notes.title == "便签" && SettingsPage.notes.color == Style.Family.notes)
    #expect(SettingsPage.page(for: "便签", current: .general) == .notes)
    #expect(SettingsPage.page(for: "最近删除", current: .general) == .notes)
    #expect(SettingsPage.notes.matches("字号") && SettingsPage.hotkeys.matches("快速记一条"))

    var archive = SettingsArchive(version: "0.5.0", exportedAt: Self.t0)
    let combo = HotKey(keyCode: kVK_ANSI_J, modifiers: optionKey | controlKey)
    archive.hotkeys = ["noteNew": combo, "noteAll": nil, "noteCapture": combo]
    // 重复的组合留给靠前的动作（按 HotKeyAction 的顺序：快速记一条在前）
    #expect(
      try SettingsArchive.read(archive.encoded()).hotkeys == ["noteCapture": combo, "noteAll": nil])
  }

  // MARK: 窗口和偏好

  /// 普通窗口关掉时：别的普通窗口还开着就留在程序坞里，都不开着了才收起；面板、无边框窗口不算
  @Test func dockStaysWhileAnotherWindowIsOpen() {
    let place = NSRect(x: -20000, y: -20000, width: 300, height: 200)
    // 带标题栏的窗口：先建、挪到屏外、确认真在屏外了再露出来（直接按屏外的位置建会被系统摆回屏幕里）
    let titled = {
      let window = Offscreen(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.setFrameOrigin(place.origin)
      return window
    }
    let (settings, notes) = (titled(), titled())
    let panel = NSPanel(
      contentRect: place, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    guard settings.frame.maxX < -10000, notes.frame.maxX < -10000 else {
      Issue.record("窗口没摆到屏外，不往下试了")
      return
    }
    for window in [settings, notes, panel] { window.orderFront(nil) }
    defer { for window in [settings, notes, panel] { window.orderOut(nil) } }
    #expect(settings.screen == nil && notes.screen == nil)  // 没被挪进屏幕里（跑测试时不闪窗口）
    let all: [NSWindow] = [settings, notes, panel]
    #expect(NSApplication.hasOrdinaryWindow(in: all, besides: settings))
    #expect(NSApplication.hasOrdinaryWindow(in: all, besides: notes))
    notes.orderOut(nil)
    #expect(!NSApplication.hasOrdinaryWindow(in: all, besides: settings))
    #expect(!NSApplication.hasOrdinaryWindow(in: [settings, panel], besides: settings))
    #expect(NSApplication.hasOrdinaryWindow(in: all, besides: notes))
  }

  /// 键盘（NotesWindowView 里看不见的按钮上挂着的那几个键）真的到得了模型，工具栏的项和右键菜单同名：
  /// 按 NotesWindow 的配法建带标题栏的窗口（工具栏桥接要它），摆在屏外、不激活，把键一个个按过去。
  /// ⌘⌫ 是窗口按键码认的（真窗口这里不建），只测它交给模型之后的事
  @Test func keyboardShortcutsReachTheModel() throws {
    let (model, store, ids) = try make(["A", "B"])
    var focused = 0
    var settings = 0
    model.focusBody = { focused += 1 }
    model.showSettings = { settings += 1 }
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let hosting = NSHostingController(
      rootView: NotesWindowView(model: model).defaultAppStorage(defaults))
    hosting.sceneBridgingOptions = [.title, .toolbars]
    let window = Offscreen(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 940, height: 580))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    #expect(window.screen == nil)  // 没被挪进屏幕里（跑测试时不闪窗口）
    let settle = { for _ in 0..<5 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    // plain：不算修饰键（⇧ 除外）时的字符，nil = 和 characters 一样
    func press(
      _ characters: String, _ keyCode: Int, _ flags: NSEvent.ModifierFlags = .command,
      plain: String? = nil
    ) throws -> Bool {
      defer { settle() }
      return window.performKeyEquivalent(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: plain ?? characters, isARepeat: false,
            keyCode: UInt16(keyCode))))
    }
    settle()
    // 默认是便签墙；工具栏最前面是显示方式的切换（便签墙 / 列表），两种显示方式的工具栏一样
    #expect(model.layout == .wall)
    #expect(
      window.toolbar?.items.map(\.label) == [
        "显示方式", "固定", "归档", "任务", "颜色", "浮在屏幕上", "删除", "新建便签", "便签设置",
      ])
    #expect(model.selection == ids[0])

    #expect(try press("p", kVK_ANSI_P) && store.note(ids[0])?.isPinned == true)
    let color = try #require(store.note(ids[0])?.color)
    #expect(try press(".", kVK_ANSI_Period))
    #expect(store.note(ids[0])?.color == NotesWindowModel.nextColor(after: color))
    // ⌘⌫ 不是 SwiftUI 的键（它认的是字符 U+0008，⌫ 键按出来是 U+007F）：窗口按键码认，交给 handleDeleteKey。
    // 输入框里（搜索、标题、正文）不接
    #expect(try !press("\u{7f}", kVK_Delete))
    #expect(!model.handleDeleteKey(inTextField: true) && store.trashed.isEmpty)
    #expect(model.handleDeleteKey(inTextField: false))
    #expect(store.trashed.map(\.id) == [ids[0]] && model.selection == ids[1])
    #expect(try press("z", kVK_ANSI_Z))
    #expect(store.trashed.isEmpty && model.selection == ids[0])
    #expect(try press("a", kVK_ANSI_A, [.command, .shift], plain: "A"))
    #expect(store.archived.map(\.id) == [ids[0]] && model.selection == ids[1])
    #expect(try press("n", kVK_ANSI_N))
    #expect(store.active.count == 2 && focused == 1 && model.selection == store.active.first?.id)
    // ⌘F：⌘N 在便签墙上把新的那条放大成了编辑卡——是它正文的查找条，不去被暗层盖着的搜索框（手测反馈第 6 批）
    #expect(try press("f", kVK_ANSI_F) && model.searchFocus == 0)
    // ⌘,：打开设置的「便签」页（手测反馈第 3 批）
    #expect(try press(",", kVK_ANSI_Comma) && settings == 1)
    // ⌘1 / ⌘2：便签墙 / 列表（⌘N 在便签墙上把新的那条放大成了编辑卡，换到列表时收回）
    #expect(model.expanded == store.active.first?.id)
    #expect(try press("2", kVK_ANSI_2) && model.layout == .list && model.expanded == nil)
    // 列表里焦点不在正文：⌘F 去搜索框
    #expect(try press("f", kVK_ANSI_F) && model.searchFocus == 1)
    #expect(try press("1", kVK_ANSI_1) && model.layout == .wall)

    // 最近删除里工具栏换成放回 / 永久删除；⌘⌫ 是永久删除，先等确认
    model.scope = .trash
    settle()
    #expect(
      window.toolbar?.items.map(\.label) == ["显示方式", "放回", "永久删除…", "新建便签", "便签设置"])
    model.scope = .all
    model.selection = ids[1]
    #expect(model.handleDeleteKey(inTextField: false))
    model.scope = .trash
    #expect(model.handleDeleteKey(inTextField: false) && model.erasing == ids[1])
    #expect(store.note(ids[1]) != nil)
    model.erasing = nil
    // 没有选中的：不接
    model.selection = nil
    #expect(!model.handleDeleteKey(inTextField: false))
  }

  /// 正文编辑器的键在全部便签窗口里走到底（屏外带标题栏的窗口、不激活；事件直接交给窗口的 performKeyEquivalent）：
  /// ⌘Z / ⇧⌘Z 撤销重做焦点所在输入框里打的字（2026-10-13 用户报「便签输入区域不支持撤销和回退」；原来没有重做，
  /// 焦点在标题框里按 ⌘Z 撤的还是正文）、⌘T 任务、⌘F 的两种去向（焦点在正文里是便签内查找，否则去搜索框）
  @Test func editorKeysInTheWindow() throws {
    let (model, store, ids) = try make(["甲的正文", "乙"])
    // 列表视图：右栏一直是选中的那条的编辑区（便签墙上要点开才有，NoteWallTests.wallInTheWindow）
    model.layout = .list
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let hosting = NSHostingController(
      rootView: NotesWindowView(model: model).defaultAppStorage(defaults))
    hosting.sceneBridgingOptions = [.title, .toolbars]
    let window = Offscreen(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 940, height: 580))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    #expect(window.screen == nil && !window.isKeyWindow)
    // 同 NotesWindow.init 里的接法
    model.undoFocusedText = { window.undoFocusedText(redo: $0) }
    model.isEditingBody = {
      NotesWindow.isInBody(
        window.firstResponder, editor: NotesWindow.editor(in: window.contentView))
    }
    model.withEditor = { body in
      if let editor = NotesWindow.editor(in: window.contentView) { body(editor) }
    }
    let settle = { for _ in 0..<5 { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) } }
    func press(
      _ characters: String, _ keyCode: Int, _ flags: NSEvent.ModifierFlags = .command,
      plain: String? = nil
    ) throws -> Bool {
      defer { settle() }
      return window.performKeyEquivalent(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: plain ?? characters, isARepeat: false,
            keyCode: UInt16(keyCode))))
    }
    // ⇧⌘Z 是窗口的按键监听认的（NotesWindow.handlesKeyDown）：把同一个事件交给它
    func redo() throws -> Bool {
      defer { settle() }
      return NotesWindow.handlesKeyDown(
        try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "z",
            charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: UInt16(kVK_ANSI_Z))),
        in: window, model: model)
    }
    func insert(_ text: String, into view: NSTextView) {
      view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func field(in view: NSView?) -> CommandTextField.FocusField? {
      guard let view else { return nil }
      return (view as? CommandTextField.FocusField)
        ?? view.subviews.lazy.compactMap { field(in: $0) }.first
    }
    settle()
    let editor = try #require(NotesWindow.editor(in: window.contentView))
    #expect(editor.identifier?.rawValue == ids[0] && editor.undoManager === model.textUndo)

    // 正文：打字 → ⌘Z 回到打之前 → ⇧⌘Z 回来（仓库里那份跟着变）
    #expect(window.makeFirstResponder(editor))
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    insert("，加一句", into: editor)
    #expect(store.note(ids[0])?.body == "甲的正文，加一句")
    #expect(try press("z", kVK_ANSI_Z) && store.note(ids[0])?.body == "甲的正文")
    #expect(editor.string == "甲的正文")
    #expect(try redo() && store.note(ids[0])?.body == "甲的正文，加一句")
    // ⌘T：光标所在行变成任务，也能撤
    #expect(try press("t", kVK_ANSI_T) && store.note(ids[0])?.body == "☐ 甲的正文，加一句")
    #expect(try press("z", kVK_ANSI_Z) && store.note(ids[0])?.body == "甲的正文，加一句")

    // 标题框：撤的是标题里打的字，正文不动
    let title = try #require(field(in: window.contentView))
    #expect(window.makeFirstResponder(title))
    let fieldEditor = try #require(title.currentEditor() as? NSTextView)
    insert("新标题", into: fieldEditor)
    #expect(store.note(ids[0])?.title == "新标题")
    #expect(try press("z", kVK_ANSI_Z))
    #expect(store.note(ids[0])?.title == "" && store.note(ids[0])?.body == "甲的正文，加一句")
    #expect(try redo() && store.note(ids[0])?.title == "新标题")

    // ⌘F：焦点在标题框里（不在正文里）→ 去搜索框
    #expect(try press("f", kVK_ANSI_F) && model.searchFocus == 1)
    #expect(editor.enclosingScrollView?.isFindBarVisible == false)
    // 焦点在正文里 → 便签内查找（系统的查找条）；再按一次还是它（焦点这时在查找条里）
    #expect(window.makeFirstResponder(editor))
    #expect(try press("f", kVK_ANSI_F) && model.searchFocus == 1)
    #expect(editor.enclosingScrollView?.isFindBarVisible == true)
    #expect(try press("f", kVK_ANSI_F) && model.searchFocus == 1)
    editor.dismissFindBar()

    // ⌘B ⌘I ⌘E ⇧⌘X（手测反馈第 4 批）：窗口把 ⌘ 组合沿着视图树问到正文框（隐藏的按钮、主菜单都不接这四个）；
    // 能撤；焦点在标题框里时不归正文
    #expect(window.makeFirstResponder(editor))
    editor.setSelectedRange(NSRange(location: 0, length: 4))
    #expect(try press("b", kVK_ANSI_B) && store.note(ids[0])?.body == "**甲的正文**，加一句")
    #expect(try press("i", kVK_ANSI_I) && store.note(ids[0])?.body == "***甲的正文***，加一句")
    #expect(try press("e", kVK_ANSI_E) && store.note(ids[0])?.body == "***`甲的正文`***，加一句")
    #expect(
      try press("x", kVK_ANSI_X, [.command, .shift], plain: "X")
        && store.note(ids[0])?.body == "***`~~甲的正文~~`***，加一句")
    // ⌘Z 撤回去（测试是同步跑的：几次按键都在同一轮事件循环里，系统把它们并成了一组；一步一撤在 NoteTextViewTests）
    var undos = 0
    while store.note(ids[0])?.body != "甲的正文，加一句", undos < 4, try press("z", kVK_ANSI_Z) {
      undos += 1
    }
    #expect(undos >= 1 && store.note(ids[0])?.body == "甲的正文，加一句")
    #expect(window.makeFirstResponder(title))
    #expect(try !press("b", kVK_ANSI_B) && store.note(ids[0])?.body == "甲的正文，加一句")

    // 换一条便签：新的栈，上一条里打的字撤不到
    model.selection = ids[1]
    settle()
    let second = try #require(NotesWindow.editor(in: window.contentView))
    #expect(second !== editor && second.undoManager === model.textUndo)
    #expect(window.makeFirstResponder(second))
    #expect(try press("z", kVK_ANSI_Z))  // 这个键窗口总是接（没有可撤销的只响一声）
    #expect(store.note(ids[0])?.body == "甲的正文，加一句" && store.note(ids[1])?.body == "乙")
  }

  /// 正文字号：默认 15、在档位里；存了不在档位里的值按默认算（只读注册的默认值，不写偏好）
  @Test func fontSizePref() {
    #expect(Prefs.defaults[Prefs.notesFontSize] as? Int == 15)
    #expect(Prefs.notesFontSizeChoices == [13, 15, 17, 20])
    #expect(Prefs.notesFontSizeChoices.map(Prefs.notesFontSize) == [13, 15, 17, 20])
    #expect(Prefs.notesFontSize(0) == 15 && Prefs.notesFontSize(999) == 15)
    #expect(SettingsArchive.kinds[Prefs.notesFontSize] != nil)
  }

  // MARK: 颜色菜单（2026-10-13 手测反馈：每一项前面要有纸色圆点）

  private func mouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws
    -> NSEvent
  {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: 100, y: 20), modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  /// 系统菜单里每一项都带着自己那张非模板的图（纸色圆点；模板图会被系统染成单色）、只有现在的那种打勾
  private func expectColorDots(_ menu: NSMenu, current: Int) {
    #expect(menu.items.map(\.title) == NotePaper.all.map(\.name))
    for (index, item) in menu.items.enumerated() {
      #expect(item.image != nil && item.image?.isTemplate == false, "\(item.title)")
      #expect(item.image?.size == NSSize(width: 16, height: 16), "\(item.title)")
      #expect(item.state == (index == current ? .on : .off), "\(item.title)")
      #expect(item.isEnabled && item.action != nil && item.submenu == nil, "\(item.title)")
    }
  }

  /// 工具栏的颜色下拉：系统菜单，8 种纸色各一项、前面是纸色圆点、现在的那种打勾；点一项就换成那种
  @Test func colorMenuHasADotForEveryPaper() throws {
    let (model, store, ids) = try make(["一条"])
    store.setColor(2, of: ids[0])
    let menu = NSMenu.of(model.colorItems(try #require(store.note(ids[0]))))
    expectColorDots(menu, current: 2)
    menu.performActionForItem(at: 5)
    #expect(store.note(ids[0])?.color == 5)
    // 换完再开：勾跟着走
    expectColorDots(NSMenu.of(model.colorItems(try #require(store.note(ids[0])))), current: 5)
    // 屏幕边缘那叠的颜色子列表是同一份表（同样的名字、图、勾）
    let items = NotePaper.colorItems(current: 5) { _ in }
    #expect(items.map(\.title) == NotePaper.all.map(\.name))
    #expect(items.map(\.isChecked) == (0..<Note.colorCount).map { $0 == 5 })
    #expect(items.allSatisfy { $0.image != nil } && Set(items.map(\.id)).count == Note.colorCount)
  }

  /// 行的右键菜单（系统菜单）：和工具栏同名的那几项，「颜色」是带圆点的那份子菜单；最近删除里的是放回 / 永久删除 / 清空
  @Test func rowMenuCarriesTheColorDots() throws {
    let (model, store, ids) = try make(["一条", "另一条"])
    store.setColor(3, of: ids[0])
    let menu = NSMenu.of(model.rowItems(try #require(store.note(ids[0]))))
    #expect(menu.items.map(\.title) == ["固定", "归档", "颜色", "浮在屏幕上", "", "删除"])
    #expect(menu.items[4].isSeparatorItem && menu.items.allSatisfy { $0.image == nil })
    expectColorDots(try #require(menu.items[2].submenu), current: 3)
    // 点里面的一项：换色；固定、归档、删除照做
    menu.items[2].submenu?.performActionForItem(at: 6)
    #expect(store.note(ids[0])?.color == 6)
    menu.performActionForItem(at: 0)
    #expect(store.note(ids[0])?.isPinned == true)
    let pinned = NSMenu.of(model.rowItems(try #require(store.note(ids[0]))))
    #expect(pinned.items.first?.title == "取消固定")
    pinned.performActionForItem(at: 1)
    #expect(store.note(ids[0])?.isArchived == true)
    let archived = NSMenu.of(model.rowItems(try #require(store.note(ids[0]))))
    // 归档里的不能浮着：没有那一项
    #expect(archived.items.map(\.title) == ["取消固定", "取消归档", "颜色", "", "删除"])
    archived.performActionForItem(at: 4)
    let trashed = NSMenu.of(model.rowItems(try #require(store.note(ids[0]))))
    #expect(trashed.items.map(\.title) == ["放回", "", "永久删除…", "清空最近删除…"])
    trashed.performActionForItem(at: 3)
    #expect(model.isEmptyingTrash)
    trashed.performActionForItem(at: 0)
    #expect(store.note(ids[0])?.deletedAt == nil)
  }

  /// 盖在行上的那块只接会弹右键菜单的那一下（右键按下、⌃ 点按），别的点击照常落到下面的行；接到了给的是系统菜单。
  /// 屏外、不显示：不发鼠标事件，只把造出来的事件对象直接交给它
  @Test func rowMenuOverlayTakesOnlyMenuClicks() throws {
    typealias Source = ActionSystemMenu.Source
    #expect(try Source.opensMenu(mouse(.rightMouseDown)))
    #expect(try Source.opensMenu(mouse(.leftMouseDown, .control)))
    #expect(try !Source.opensMenu(mouse(.leftMouseDown)) && !Source.opensMenu(nil))
    #expect(try !Source.opensMenu(mouse(.leftMouseDown, .command)))
    #expect(try !Source.opensMenu(mouse(.rightMouseUp)) && !Source.opensMenu(mouse(.leftMouseUp)))

    let (model, store, ids) = try make(["一条"])
    let note = try #require(store.note(ids[0]))
    let host = NSHostingView(
      rootView: Text("一行").frame(width: 200, height: 40)
        .overlay { ActionSystemMenu { model.rowItems(note) } })
    let window = Offscreen(
      contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 40), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> Source? {
      (view as? Source) ?? view.subviews.lazy.compactMap(find).first
    }
    let source = try #require(find(host))
    let point = NSPoint(x: 100, y: 20)
    // 平时（现在没有哪个事件是右键）：点不到它，落到下面
    #expect(host.hitTest(point) !== source)
    // 是右键的那一下：SwiftUI 把点击交到它手上，它给出系统菜单
    source.isMenuClick = { true }
    #expect(host.hitTest(point) === source)
    let menu = try #require(source.menu(for: mouse(.rightMouseDown)))
    #expect(menu.items.map(\.title) == ["固定", "归档", "颜色", "浮在屏幕上", "", "删除"])
    expectColorDots(try #require(menu.items[2].submenu), current: note.color)
  }

}

extension NotesWindowTests {
  /// 左边的列表记着上次算好的（手测反馈第 3 批）：仓库变了、换视图、换搜索词都要重算，不能拿旧的
  @Test func listFollowsTheStore() throws {
    let (model, store, ids) = try make(["苹果", "香蕉"])
    model.query = "梨"
    #expect(model.notes.isEmpty)
    store.setBody("梨子", of: ids[1])
    #expect(model.notes.map(\.id) == [ids[1]])
    store.setArchived(true, of: ids[1])
    #expect(model.notes.isEmpty)
    model.scope = .archive
    #expect(model.notes.map(\.id) == [ids[1]])
    model.query = ""
    #expect(model.notes.map(\.id) == [ids[1]])
    model.scope = .all
    #expect(model.notes.map(\.id) == [ids[0]])
  }

  /// 工具栏只拿画得出来的那几样（手测反馈第 3 批：换一条便签时它们没变，工具栏就不重建）：两条都没固定、没归档的
  /// 便签之间换，这几样一模一样；固定了的、归档里的、最近删除里的各自不同
  @Test func toolbarStateOnlyCarriesWhatIsDrawn() throws {
    let (model, store, ids) = try make(["A", "B", "C"])
    model.selection = ids[0]
    let first = model.toolbarState
    model.selection = ids[1]
    #expect(model.toolbarState == first)
    #expect(first.hasNote && !first.isTrash && first.canFloat && first.pinTitle == "固定")
    #expect(first.pinSymbol == "pin" && first.archiveTitle == "归档" && first.floatTitle == "浮在屏幕上")
    store.setPinned(true, of: ids[1])
    #expect(model.toolbarState.pinTitle == "取消固定" && model.toolbarState.pinSymbol == "pin.slash")
    model.selection = nil
    #expect(!model.toolbarState.hasNote && !model.toolbarState.canFloat)
    store.setArchived(true, of: ids[2])
    model.scope = .archive
    #expect(model.toolbarState.archiveTitle == "取消归档" && !model.toolbarState.canFloat)
    model.scope = .trash
    #expect(model.toolbarState.isTrash && !model.toolbarState.hasNote)
    // 名字和符号：同操作菜单那一份
    #expect(
      NotesWindowModel.settingsTitle == "便签设置" && NotesWindowModel.settingsSymbol == "gearshape")
  }
}

/// 带标题栏的窗口摆在屏外（系统默认会把它挪回屏幕里）
private final class Offscreen: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

}
