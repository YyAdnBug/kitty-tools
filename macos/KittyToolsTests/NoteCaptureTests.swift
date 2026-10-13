// 快速记一条（Notes/NoteCapture.swift）的单测：保存的规则（空的不存、新建、接在已有的后面、目的地没了当新便签、
// 超过单条上限不存）、目的地列表（最近改过的 8 条没归档的）、⌘1–⌘9、草稿在收起后留着 / Esc 清空、面板的高度；
// 另有多行输入框字节上限的判断（SourceTextView.overflows）。
// 全用内存库；不给岛（岛会真的开窗口），不碰用户的偏好和数据目录。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct NoteCaptureTests {
  private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
  private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  /// 记下面板被收起了几次、怎么收的
  private final class Panel {
    var hidden = 0
    var dismissed = 0
    var heights: [CGFloat] = []
  }

  private func make() throws -> (model: NoteCaptureModel, store: NoteStore, panel: Panel) {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let model = NoteCaptureModel(store: store)
    let panel = Panel()
    model.hidePanel = { panel.hidden += 1 }
    model.dismissPanel = { panel.dismissed += 1 }
    model.resize = { panel.heights.append($0) }
    return (model, store, panel)
  }

  /// 空的、只有空白的不存，面板留着；有字的去掉首尾空白存成新便签，草稿清空、面板收起
  @Test func savesTrimmedTextAsNewNote() throws {
    let (model, store, panel) = try make()
    #expect(!model.canSave && model.save() == .empty)
    model.draft = "  \n\t "
    #expect(!model.canSave && model.save() == .empty)
    #expect(store.notes.isEmpty && panel.hidden == 0 && model.draft == "  \n\t ")

    model.draft = "\n  买牛奶\n第二行  \n"
    #expect(model.canSave)
    let outcome = model.save(now: Self.t0)
    let note = try #require(store.active.first)
    #expect(outcome == .saved(note.id))
    #expect(note.body == "买牛奶\n第二行" && note.displayTitle == "买牛奶")
    #expect(store.notes.count == 1 && model.draft.isEmpty && panel.hidden == 1)
    #expect(panel.dismissed == 0)
    // 落盘了：另开一个仓库从同一个库读得到（这里只看没有攒着的）
    #expect(store.saveProblem == nil)
  }

  /// 接在已有的便签后面：原来有内容、末尾没换行就先换一行；末尾已经换行、原来是空的就直接接
  @Test func appendsToExistingNote() throws {
    #expect(NoteCaptureModel.body(appending: "新的", to: nil) == "新的")
    #expect(NoteCaptureModel.body(appending: "新的", to: "") == "新的")
    #expect(NoteCaptureModel.body(appending: "新的", to: "旧的") == "旧的\n新的")
    #expect(NoteCaptureModel.body(appending: "新的", to: "旧的\n") == "旧的\n新的")

    let (model, store, panel) = try make()
    let old = store.create(body: "周报", now: Self.t0)
    model.select(1)
    #expect(model.target?.id == old.id && model.selectedIndex == 1)
    model.draft = " 第二条 "
    #expect(model.save(now: Self.at(60)) == .saved(old.id))
    #expect(store.notes.count == 1 && store.note(old.id)?.body == "周报\n第二条")
    #expect(store.note(old.id)?.modifiedAt == Note.stamp(Self.at(60)))
    #expect(panel.hidden == 1 && model.draft.isEmpty)
    // 存完回到新便签
    #expect(model.target == nil && model.selectedIndex == 0)
  }

  /// 选了的那条在面板开着时被删了 / 归档了：当新便签记
  @Test func vanishedDestinationFallsBackToNewNote() throws {
    for vanish in ["delete", "archive"] {
      let (model, store, _) = try make()
      let old = store.create(body: "旧的", now: Self.t0)
      model.select(1)
      model.draft = "记一条"
      if vanish == "delete" { store.delete(old.id) } else { store.setArchived(true, of: old.id) }
      #expect(model.target == nil && model.selectedIndex == 0, "\(vanish)")
      guard case .saved(let id) = model.save(now: Self.at(1)) else {
        Issue.record("没存上：\(vanish)")
        continue
      }
      #expect(id != old.id && store.note(id)?.body == "记一条", "\(vanish)")
      #expect(store.note(old.id)?.body == "旧的", "\(vanish)")
    }
  }

  /// 存完会超过单条上限：不存、不截断，底栏说原因，草稿和面板都留着；正好到上限的能存
  @Test func refusesTextOverTheLimit() throws {
    let (model, store, panel) = try make()
    model.draft = String(repeating: "a", count: Note.maxBodyBytes + 1)
    #expect(model.save() == .tooLong)
    #expect(store.notes.isEmpty && panel.hidden == 0)
    #expect(model.draft.utf8.count == Note.maxBodyBytes + 1)
    guard case .warning(let text)? = model.notice else {
      Issue.record("底栏没有说原因")
      return
    }
    #expect(text.contains("1 MB"))
    // 一改草稿提示就收
    model.draft = String(repeating: "a", count: Note.maxBodyBytes)
    #expect(model.notice == nil)
    guard case .saved(let id) = model.save(now: Self.t0) else {
      Issue.record("正好到上限的没存上")
      return
    }
    #expect(store.note(id)?.body.utf8.count == Note.maxBodyBytes)

    // 接在已有的后面：加上换行和这段就超了
    model.select(1)
    model.draft = "再来一个字"
    #expect(model.save() == .tooLong && model.notice != nil)
    #expect(store.note(id)?.body.utf8.count == Note.maxBodyBytes && model.draft == "再来一个字")
    // 换成新便签就能记
    model.select(0)
    #expect(model.notice == nil)
    guard case .saved(let other) = model.save(now: Self.at(1)) else {
      Issue.record("换成新便签也没存上")
      return
    }
    #expect(other != id)
  }

  /// 目的地：没归档、没删的里最近改过的 8 条，新改的在前
  @Test func destinationsAreTheLatestEdited() throws {
    let (model, store, _) = try make()
    #expect(model.destinations.isEmpty && model.title(of: 0) == "新便签")
    let ids = (0..<10).map { store.create(body: "第 \($0) 条", now: Self.at(Double($0))).id }
    store.setArchived(true, of: ids[9])
    store.delete(ids[8])
    #expect(model.destinations.map(\.id) == Array(ids[0...7].reversed()))
    // 改了一条旧的，它排到最前
    store.setBody("改过", of: ids[0], now: Self.at(100))
    #expect(model.destinations.first?.id == ids[0])
    #expect(model.destinations.count == NoteCaptureModel.destinationLimit)
    #expect(model.title(of: 1) == "改过" && model.title(of: 2) == "第 7 条")
    // 选中的那条跟着它自己走，不跟着位置
    model.select(2)
    store.setBody("又改了一条", of: ids[3], now: Self.at(200))
    #expect(model.target?.id == ids[7] && model.selectedIndex == 3)
  }

  /// ⌘1 新便签、⌘2–⌘9 已有的；不带 ⌘、多带了别的修饰键的不接
  @Test func commandDigitsPickDestination() throws {
    let (model, store, _) = try make()
    let first = store.create(body: "一", now: Self.t0).id
    let second = store.create(body: "二", now: Self.at(1)).id
    func press(_ key: Int, _ flags: NSEvent.ModifierFlags) throws -> Bool {
      model.handleKeyEquivalent(
        try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(key))))
    }
    #expect(try press(kVK_ANSI_3, .command) && model.target?.id == first)
    #expect(try press(kVK_ANSI_2, [.command, .capsLock]) && model.target?.id == second)
    #expect(try press(kVK_ANSI_1, .command) && model.target == nil)
    #expect(try !press(kVK_ANSI_2, []) && !press(kVK_ANSI_2, [.command, .shift]))
    #expect(try !press(kVK_ANSI_K, .command) && model.target == nil)
  }

  /// 收起（点外面、再按热键）草稿和目的地留着；Esc 清空并收起；再呼出时目的地没了就回到新便签
  @Test func draftSurvivesHideButNotEscape() throws {
    let (model, store, panel) = try make()
    let old = store.create(body: "旧的", now: Self.t0)
    model.draft = "写了一半"
    model.select(1)
    model.hovered = 1
    model.didHide()
    model.prepareForShow()
    #expect(model.draft == "写了一半" && model.target?.id == old.id && model.hovered == nil)
    store.delete(old.id)
    model.prepareForShow()
    #expect(model.draft == "写了一半" && model.selectedIndex == 0)

    model.cancel()
    #expect(model.draft.isEmpty && panel.dismissed == 1 && panel.hidden == 0)
    #expect(store.active.isEmpty)
  }

  /// 面板的高：正文 3 行起、最多 8 行；草稿变了就报新的高
  @Test func heightFollowsDraftWithinThreeToEightLines() throws {
    let lines = { (count: Int) in Array(repeating: "一行", count: count).joined(separator: "\n") }
    let short = NoteCaptureModel.height(for: "")
    #expect(NoteCaptureModel.height(for: lines(3)) == short)
    let five = NoteCaptureModel.height(for: lines(5))
    let eight = NoteCaptureModel.height(for: lines(8))
    #expect(short < five && five < eight)
    #expect(NoteCaptureModel.height(for: lines(40)) == eight)
    // 一行很长的字折成几行也算
    #expect(NoteCaptureModel.height(for: String(repeating: "长", count: 400)) > short)
    let line = (eight - short) / 5
    #expect(line >= 16 && line <= 22)

    let (model, _, panel) = try make()
    model.draft = lines(5)
    model.draft = lines(5)
    #expect(panel.heights == [five])
  }

  /// 多行输入框的字节上限：算的是换完之后的 UTF-8 字节，被换掉的那段要减掉
  @Test func textViewOverflowCountsBytesAfterReplacement() {
    let overflows = { (current: String, range: NSRange, replacement: String, max: Int) in
      SourceTextView.overflows(current, replacing: range, with: replacement, maxBytes: max)
    }
    #expect(!overflows("abc", NSRange(location: 3, length: 0), "de", 5))
    #expect(overflows("abc", NSRange(location: 3, length: 0), "def", 5))
    // 中文一个字 3 字节
    #expect(!overflows("", NSRange(location: 0, length: 0), "你好", 6))
    #expect(overflows("", NSRange(location: 0, length: 0), "你好", 5))
    // 选中一段再粘贴：先减掉被换掉的
    #expect(!overflows("你好吗", NSRange(location: 1, length: 2), "们", 6))
    #expect(overflows("你好吗", NSRange(location: 3, length: 0), "们", 9))
    // 没让正文变长的改动永远不算超（已经超了的正文得删得动）：删除、换成一样长或更短的
    #expect(!overflows("你好吗", NSRange(location: 0, length: 1), "", 1))
    #expect(!overflows("你好吗", NSRange(location: 0, length: 1), "abc", 1))
    #expect(overflows("你好吗", NSRange(location: 0, length: 1), "abcd", 1))
  }
}
