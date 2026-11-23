// 搁着的计划第 3 批（第四轮体检 X4 X5 X6 X16 X19，2026-11-17）的单测：
// - 富文本粘进便签转 Markdown（NoteRichPaste）、⌥⇧⌘V 粘纯文本；
// - 快速记一条贴图：记下时每张一行接在正文后面、草稿带着图；
// - 全部便签窗口多选：⌘ / ⇧ 点按、整批删除 / 归档 / 换色 / 固定、一次 ⌘Z 整批放回、导入后撤回；
// - 屏幕边缘那叠的全局快捷键：summoned 扇出、↑↓ ↩；
// - 按最近修改排。
// 全用内存库、不写用户的偏好（偏好域是临时的）。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct NoteBacklogTests {
  private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
  private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  private func make(_ bodies: [String]) throws -> (NotesWindowModel, NoteStore, [String]) {
    let store = try NoteStore(db: Database(path: ":memory:"))
    for (offset, body) in bodies.reversed().enumerated() {
      store.create(body: body, now: Self.at(Double(offset)))
    }
    return (NotesWindowModel(store: store), store, store.active.map(\.id))
  }

  // MARK: X4

  @Test func richTextBecomesMarkdown() throws {
    let body = NSFont.systemFont(ofSize: 13)
    let text = NSMutableAttributedString()
    func add(_ string: String, _ attributes: [NSAttributedString.Key: Any] = [:]) {
      var all: [NSAttributedString.Key: Any] = [.font: body]
      all.merge(attributes) { $1 }
      text.append(NSAttributedString(string: string, attributes: all))
    }
    add("标题\n", [.font: NSFont.boldSystemFont(ofSize: 24)])
    add("看 ")
    add("这里", [.link: URL(string: "https://example.com/a")!])
    add(" 和 ")
    add("粗体", [.font: NSFont.boldSystemFont(ofSize: 13)])
    add(" ")
    add("删掉", [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
    add(" 跑 ")
    add("ls -l", [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
    add("\n")
    let list = NSMutableParagraphStyle()
    list.textLists = [NSTextList(markerFormat: .disc, options: 0)]
    add("\t•\t第一项\n", [.paragraphStyle: list])
    add("\t•\t第二项\n", [.paragraphStyle: list])
    add("let a = 1\n", [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    add("结尾")
    #expect(
      NoteRichPaste.markdown(from: text)
        == """
        # 标题
        看 [这里](https://example.com/a) 和 **粗体** ~~删掉~~ 跑 `ls -l`
        - 第一项
        - 第二项
        `let a = 1`
        结尾
        """)
  }

  /// 剪贴板里只有纯文本、或者带格式却转不出东西来：不走 Markdown（nil，照常粘纯文本）
  @Test func plainPasteboardStaysPlain() throws {
    let board = NSPasteboard(name: .init("kitty-test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("just text", forType: .string)
    #expect(NoteRichPaste.markdown(from: board) == nil)
    let rtf = try #require(
      NSAttributedString(string: "plain").rtf(
        from: NSRange(location: 0, length: 5), documentAttributes: [:]))
    board.clearContents()
    board.setString("plain", forType: .string)
    board.setData(rtf, forType: .rtf)
    #expect(NoteRichPaste.markdown(from: board) == nil)
  }

  // MARK: X5

  @Test func captureAppendsImagesAsLines() throws {
    let image = NoteImages.Image(id: UUID(), ext: "png", width: nil)
    #expect(NoteCaptureModel.text("记一下", images: [image]) == "记一下\n" + NoteImages.token(image))
    #expect(NoteCaptureModel.text("", images: [image, image]).split(separator: "\n").count == 2)
    #expect(NoteCaptureModel.text("只有字", images: []) == "只有字")
    // 草稿带着图：只有图也不是空的，读回来令牌还原成图
    let draft = NoteCaptureModel.Draft(body: "", images: [NoteImages.token(image)])
    #expect(!draft.isEmpty)
    #expect(NoteCaptureModel.Draft(data: draft.data) == draft)
    #expect(NoteCaptureModel.Draft(body: "x", images: []).images == nil)
  }

  // MARK: X6

  @Test func commandAndShiftClicksMark() throws {
    let (model, _, ids) = try make(["A", "B", "C", "D"])
    #expect(model.selection == ids[0] && !model.isMarking)
    #expect(model.click(ids[2], modifiers: .command))
    #expect(model.marked == [ids[0], ids[2]] && model.selection == ids[2])
    #expect(model.targets == [ids[0], ids[2]])
    // ⌘ 再点一下去掉：只剩一条就不算多选了
    #expect(model.click(ids[2], modifiers: .command))
    #expect(!model.isMarking && model.targets == [ids[0]])
    // ⇧ 从选中的那条勾到点的那条
    #expect(model.click(ids[3], modifiers: .shift))
    #expect(model.marked == Set(ids) && model.targets == ids)
    #expect(!model.click(ids[1], modifiers: []))
    // 搜索把一些筛掉：只留看得见的
    model.markAll()
    model.query = "A"
    #expect(!model.isMarking)
    // 列表视图（系统多选）
    model.query = ""
    model.setListSelection([ids[1], ids[3]])
    #expect(model.isMarking && model.listSelection == [ids[1], ids[3]])
    model.setListSelection([ids[2]])
    #expect(!model.isMarking && model.selection == ids[2])
  }

  @Test func batchDeleteArchiveAndUndo() throws {
    let (model, store, ids) = try make(["A", "B", "C", "D"])
    let island = Island(showing: nil)
    model.island = island
    model.setListSelection([ids[1], ids[2]])
    model.deleteTargets()
    #expect(store.trashed.count == 2 && !model.isMarking && model.selection == ids[3])
    #expect(island.content?.title == "已删除 2 条")
    // 一次 ⌘Z 整批放回
    #expect(model.undoRemoval())
    #expect(store.active.map(\.id) == ids && store.trashed.isEmpty)
    // 整批归档，再整批取消归档
    model.setListSelection([ids[0], ids[3]])
    model.archiveTargets()
    #expect(store.archived.count == 2 && store.active.map(\.id) == [ids[1], ids[2]])
    model.scope = .archive
    model.markAll()
    model.archiveTargets()
    #expect(store.archived.isEmpty && store.active.count == 4)
    // 换色、固定对着勾上的全部
    model.scope = .all
    model.setListSelection([ids[0], ids[1]])
    model.cycleColorTargets()
    let colors = [ids[0], ids[1]].compactMap { store.note($0)?.color }
    #expect(colors.count == 2 && colors[0] == colors[1])
    model.pinTargets()
    #expect(store.note(ids[0])?.isPinned == true && store.note(ids[1])?.isPinned == true)
    // 最近删除里整批永久删除先确认
    model.setListSelection([ids[2], ids[3]])
    model.deleteTargets()
    model.scope = .trash
    model.markAll()
    model.deleteTargets()
    #expect(model.erasingBatch.count == 2 && store.trashed.count == 2)
    model.eraseBatch()
    #expect(store.trashed.isEmpty && store.note(ids[2]) == nil)
  }

  @Test func batchRemovalPure() {
    let after = NotesWindowModel.selection(afterRemovingAll:from:)
    let ids = ["a", "b", "c", "d", "e"]
    #expect(after(["b", "c"], ids) == "d")
    #expect(after(["d", "e"], ids) == "c")
    #expect(after(Set(ids), ids) == nil)
  }

  @Test func importReportsAddedIDs() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let entry = SettingsArchive.NoteEntry(
      id: UUID().uuidString, title: "", body: "导进来的", color: 0, createdAt: 1, modifiedAt: 2,
      revision: 1, archived: false, pinned: false, order: 0)
    let adoption = store.adopt([entry])
    #expect(adoption.addedIDs == [entry.id])
    NotesTab.withdraw(adoption.addedIDs, in: store, island: nil)
    #expect(store.active.isEmpty && store.trashed.map(\.id) == [entry.id])
  }

  // MARK: X16

  @Test func summonFansAndKeysWalk() throws {
    var state = NoteDeckState()
    let fanned = state.handle(.summoned)
    #expect(fanned && state.phase == .fanned)
    let again = state.handle(.summoned)
    #expect(!again)
    let dismissed = state.handle(.dismiss)
    #expect(dismissed && state.phase == .rest)

    let store = try NoteStore(db: Database(path: ":memory:"))
    for index in 0..<3 { store.create(body: "第 \(index) 条", now: Self.at(Double(index))) }
    let model = NoteDeckModel(store: store)
    let down = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: UInt16(kVK_DownArrow)))
    let enter = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: UInt16(kVK_Return)))
    // 还没扇出：不接
    #expect(!model.handleFanKey(down))
    model.summonedByKey = true
    model.send(.summoned)
    #expect(model.summonedByKey && model.state.phase == .fanned)
    #expect(model.handleFanKey(down) && model.hovered == model.tabs[0].id)
    #expect(model.handleFanKey(down) && model.hovered == model.tabs[1].id)
    let id = model.tabs[1].id
    #expect(model.handleFanKey(enter) && model.state.openID == id && !model.summonedByKey)
  }

  /// 评审 A1 B1：「一直展开」时快捷键叫出来再 Esc，状态不变也要把键盘还回去、不再算快捷键叫出来的
  @Test func summonedAlwaysFannedReleasesKeyboard() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    store.create(body: "一条", now: Self.at(0))
    let model = NoteDeckModel(store: store)
    var options = model.options
    options.alwaysFanned = true
    model.options = options
    var released = 0
    model.onReleaseKey = { released += 1 }
    #expect(model.state.phase == .fanned)
    model.summonedByKey = true
    model.send(.summoned)
    model.dismiss()
    #expect(released == 1 && !model.summonedByKey && model.state.phase == .fanned)
    // 不是快捷键叫出来的：照旧不动键盘
    model.dismiss()
    #expect(released == 1)
  }

  /// 评审 A3 A8 A4：最近删除里 ⇧⌘A 不归档；勾上的被别处删了就不算；墙上 ⇧ 点按照屏上（固定的在前）的顺序
  @Test func markingFollowsWhatIsShown() throws {
    let (model, store, ids) = try make(["A", "B", "C", "D"])
    model.setListSelection([ids[0], ids[1], ids[2]])
    store.delete(ids[1])
    store.delete(ids[2])
    #expect(!model.isMarking && model.targets == [ids[0]])
    // 最近删除里
    model.scope = .trash
    model.markAll()
    model.archiveTargets()
    #expect(store.archived.isEmpty && store.trashed.count == 2)
    // 墙上：D 固定了排在最前，从 A ⇧ 点到 B 不该带上 D 以外别的
    model.scope = .all
    store.restore(ids[1])
    store.restore(ids[2])
    store.setPinned(true, of: ids[3])
    model.layout = .wall
    model.clearMarks()
    model.selection = ids[0]
    #expect(model.click(ids[1], modifiers: .shift))
    #expect(Set(model.targets) == [ids[0], ids[1]])
    // ⌘ 点掉选中的那条：选中挪到还勾着的
    #expect(model.click(ids[2], modifiers: .command))
    #expect(model.click(ids[2], modifiers: .command) && model.selection != ids[2])
  }

  /// 评审 B3–B6 A9 A10：一行等宽是行内代码、几行等宽中间的空行留在块里、不间断空格不吞、<br> 换成换行、没有标记就不转、
  /// HTML 里去外面取东西的标签去掉、围栏粘在一行中间时补换行
  @Test func richPasteEdgeCases() {
    let body = NSFont.systemFont(ofSize: 13)
    let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    #expect(
      NoteRichPaste.convert(NSAttributedString(string: "foo", attributes: [.font: mono]))
        == ("`foo`", true))
    let block = NSMutableAttributedString(
      string: "func a() {\n\n  b()\n}", attributes: [.font: mono])
    #expect(NoteRichPaste.convert(block).text == "```\nfunc a() {\n\n  b()\n}\n```")
    let spaced = NSMutableAttributedString(string: "foo\u{00A0}", attributes: [.font: body])
    spaced.append(
      NSAttributedString(string: "bar", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
    spaced.append(NSAttributedString(string: "\u{00A0}baz\u{2028}next", attributes: [.font: body]))
    #expect(NoteRichPaste.convert(spaced) == ("foo\u{00A0}**bar**\u{00A0}baz\nnext", true))
    #expect(
      !NoteRichPaste.convert(
        NSAttributedString(string: "para one\n\n\npara two", attributes: [.font: body])
      ).marked)
    #expect(
      NoteRichPaste.withoutRemoteResources(
        #"<p>a<img src="https://x/y.png">b</p><style>p{}</style><link rel="x" href="y">"#)
        == "<p>ab</p>")
    #expect(NoteRichPaste.fitting("```\nx\n```", after: "a", before: "b") == "\n```\nx\n```\n")
    #expect(NoteRichPaste.fitting("```\nx\n```", after: "\n", before: nil) == "```\nx\n```")
  }

  @Test func deckActionIsLastAndNotes() {
    // 第五轮体检 N2 的延时截图、issue #48 的暂停 / 继续录制又追加在它后面
    #expect(HotKeyAction.allCases.suffix(3) == [.noteDeck, .delayedScreenshot, .recordPause])
    #expect(HotKeyAction.noteDeck.feature == .notes && HotKeyAction.noteDeck.defaultHotKey == nil)
  }

  // MARK: X19

  @Test func sortByModifiedKeepsPinnedFirst() throws {
    let (model, store, ids) = try make(["A", "B", "C"])
    store.setBody("C 改过", of: ids[2], now: Self.at(100))
    store.setPinned(true, of: ids[1])
    #expect(model.canReorder)
    model.sort = .modified
    #expect(model.notes.map(\.id) == [ids[1], ids[2], ids[0]] && !model.canReorder)
    model.sort = .manual
    #expect(model.notes.map(\.id) == store.active.map(\.id))
    // 归档、最近删除不看它
    model.sort = .modified
    store.setArchived(true, of: ids[0])
    model.scope = .archive
    #expect(model.notes.map(\.id) == [ids[0]])
  }
}
