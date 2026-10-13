// 便签第 5 批的纯函数单测（PLAN §10「便签」）：
// - NoteTasks：认行首的标记（缩进、方框后面要空格或行尾、行中间的方框不算、无序 / 有序）、⌘T 切换（单行、多行选区、
//   无序符号换成方框、空行、选区怎么跟着挪）、回车续行（三种列表）和空项退出、Tab / ⇧Tab 缩进、打「- [ ]」加空格的
//   自动转换、和 Markdown 互转（往返不变）、任务进度；
// - NoteStyles：一行要哪些样式（区间 + 种类）、编辑过的区间攒成一段、要重排哪几行（中文和表情的 UTF-16 区间、
//   插入 / 删除换行、文末空行）；
// - 示例便签、标题和摘要跟任务的关系没被改坏。

import Foundation
import Testing

@testable import KittyTools

struct NoteTasksTests {
  private typealias Change = NoteTasks.Change
  private typealias Replacement = NoteTasks.Replacement

  private func range(_ location: Int, _ length: Int = 0) -> NSRange {
    NSRange(location: location, length: length)
  }

  /// 把一次改动套到 text 上（从后往前换），返回改完的文字
  private func applied(_ change: Change?, to text: String) -> String? {
    guard let change else { return nil }
    let result = NSMutableString(string: text)
    for replacement in change.replacements.reversed() {
      result.replaceCharacters(in: replacement.range, with: replacement.text)
    }
    return result as String
  }

  // MARK: 认标记

  @Test func prefixesOfTasks() {
    let open = NoteTasks.prefix(of: "☐ 周报")
    #expect(open?.lead == .task(isDone: false) && open?.indent == 0 && open?.contentStart == 2)
    let done = NoteTasks.prefix(of: "  \t☑ 订会议室")
    #expect(done?.lead == .task(isDone: true) && done?.indent == 3 && done?.contentStart == 5)
    // 方框在行尾（后面的空格没了）也算；后面直接跟字的不算（别处贴来的符号）
    let bare = NoteTasks.prefix(of: "☐")
    #expect(bare?.lead == .task(isDone: false) && bare?.hasSpace == false)
    #expect(bare?.contentStart == 1)
    #expect(NoteTasks.prefix(of: "☐周报") == nil && NoteTasks.prefix(of: "☑\t周报") == nil)
    // 行中间的方框不算
    #expect(NoteTasks.prefix(of: "记得 ☐ 周报") == nil && NoteTasks.box(in: "a ☑ b") == nil)
    #expect(NoteTasks.box(in: "☐ a") == 0 && NoteTasks.box(in: "    ☑") == 4)
    #expect(NoteTasks.box(in: "- a") == nil && NoteTasks.box(in: "") == nil)
    #expect(NoteTasks.flipped("☐") == "☑" && NoteTasks.flipped("☑") == "☐")
  }

  @Test func prefixesOfLists() {
    #expect(NoteTasks.prefix(of: "- 牛奶")?.lead == .bullet("-"))
    #expect(NoteTasks.prefix(of: "  * 鸡蛋")?.lead == .bullet("*"))
    #expect(NoteTasks.prefix(of: "+ ")?.lead == .bullet("+"))
    // 符号后面要有空格：「-5」「**粗**」「---」都不是列表
    #expect(NoteTasks.prefix(of: "-5 度") == nil && NoteTasks.prefix(of: "**粗**") == nil)
    #expect(NoteTasks.prefix(of: "---") == nil && NoteTasks.prefix(of: "-") == nil)
    let ordered = NoteTasks.prefix(of: " 12. 第十二")
    #expect(ordered?.lead == .ordered(12, ".") && ordered?.markerLength == 3)
    #expect(ordered?.contentStart == 5)
    #expect(NoteTasks.prefix(of: "3) 第三")?.lead == .ordered(3, ")"))
    // 「2026.」后面没空格、十位以上的一长串数字、空行、普通行
    #expect(NoteTasks.prefix(of: "2026.10") == nil && NoteTasks.prefix(of: "1.") == nil)
    #expect(NoteTasks.prefix(of: "1234567890. 太长") == nil)
    #expect(NoteTasks.prefix(of: "") == nil && NoteTasks.prefix(of: "   ") == nil)
    #expect(NoteTasks.prefix(of: "普通的一行") == nil)
  }

  // MARK: ⌘T

  @Test func toggleSingleLine() {
    // 普通行 → 任务：光标跟着往后让；光标在行首时落到方框后面
    var change = NoteTasks.toggle("周报", selection: range(1))
    #expect(applied(change, to: "周报") == "☐ 周报" && change?.selection == range(3))
    change = NoteTasks.toggle("周报", selection: range(0))
    #expect(change?.selection == range(2))
    // 保留缩进
    change = NoteTasks.toggle("  周报", selection: range(4))
    #expect(applied(change, to: "  周报") == "  ☐ 周报" && change?.selection == range(6))
    // 任务（做完没做完都一样）→ 普通行
    change = NoteTasks.toggle("☐ 周报", selection: range(4))
    #expect(applied(change, to: "☐ 周报") == "周报" && change?.selection == range(2))
    change = NoteTasks.toggle("\t☑ 周报", selection: range(1))
    #expect(applied(change, to: "\t☑ 周报") == "\t周报" && change?.selection == range(1))
    // 光标夹在方框和空格中间：收到行首
    #expect(NoteTasks.toggle("☐ 周报", selection: range(1))?.selection == range(0))
    // 无序列表项：符号换成方框
    change = NoteTasks.toggle("- 牛奶", selection: range(4))
    #expect(applied(change, to: "- 牛奶") == "☐ 牛奶" && change?.selection == range(4))
    #expect(applied(NoteTasks.toggle("  * 鸡蛋", selection: range(0)), to: "  * 鸡蛋") == "  ☐ 鸡蛋")
    // 有序的保留序号
    #expect(applied(NoteTasks.toggle("1. 第一", selection: range(0)), to: "1. 第一") == "☐ 1. 第一")
    // 空行：先按 ⌘T 再打字
    change = NoteTasks.toggle("", selection: range(0))
    #expect(applied(change, to: "") == "☐ " && change?.selection == range(2))
    #expect(applied(NoteTasks.toggle("  ", selection: range(2)), to: "  ") == "  ☐ ")
    // 方框在行尾（没有空格）也去得掉
    #expect(applied(NoteTasks.toggle("☐", selection: range(1)), to: "☐") == "")
  }

  @Test func toggleSeveralLines() {
    // 有一行还不是任务：都变成任务（已经是的不动、空行不动）
    let mixed = "周报\n☑ 订会议室\n\n- 报销单"
    var change = NoteTasks.toggle(mixed, selection: range(0, (mixed as NSString).length))
    #expect(applied(change, to: mixed) == "☐ 周报\n☑ 订会议室\n\n☐ 报销单")
    // 选区照旧盖着这几行（开头不挪，末尾跟着变长）
    #expect(change?.selection == range(0, (mixed as NSString).length + 2))
    // 都是任务：都去掉
    let tasks = "☐ 周报\n  ☑ 订会议室\n☐ 报销单"
    change = NoteTasks.toggle(tasks, selection: range(2, 10))
    #expect(applied(change, to: tasks) == "周报\n  订会议室\n报销单")
    #expect(change?.selection == range(0, 8))
    // 选了好几行、全是空行：没有可改的
    #expect(NoteTasks.toggle("\n\n", selection: range(0, 2)) == nil)
    // 替换是从前到后、互不相交的
    let ranges = NoteTasks.toggle(mixed, selection: range(0, 3))?.replacements.map(\.range) ?? []
    #expect(ranges == [range(0), range(11, 1)])
    // Windows 换行也分得开
    #expect(
      applied(NoteTasks.toggle("a\r\nb", selection: range(0, 4)), to: "a\r\nb") == "☐ a\r\n☐ b")
  }

  @Test func selectionFollowsReplacements() {
    let insert = [Replacement(range: range(2), text: "☐ ")]
    // 光标在插入点前面不动、正好在插入点上挪到后面、在后面跟着让
    #expect(NoteTasks.mapped(range(1), through: insert) == range(1))
    #expect(NoteTasks.mapped(range(2), through: insert) == range(4))
    #expect(NoteTasks.mapped(range(5), through: insert) == range(7))
    // 一段选区的开头正好在插入点上：不挪，选区变长
    #expect(NoteTasks.mapped(range(2, 3), through: insert) == range(2, 5))
    let remove = [Replacement(range: range(2, 2), text: "")]
    #expect(NoteTasks.mapped(range(3), through: remove) == range(2))
    #expect(NoteTasks.mapped(range(4), through: remove) == range(2))
    #expect(NoteTasks.mapped(range(1, 6), through: remove) == range(1, 4))
  }

  // MARK: 回车、Tab、自动转换

  @Test func newlineContinuesLists() {
    // 任务：下一行带「☐ 」（做完的那行续出来的也是没做完的），保留缩进
    var change = NoteTasks.newline(in: "☐ 周报", caret: 4)
    #expect(applied(change, to: "☐ 周报") == "☐ 周报\n☐ " && change?.selection == range(7))
    change = NoteTasks.newline(in: "  ☑ 订会议室", caret: 8)
    #expect(applied(change, to: "  ☑ 订会议室") == "  ☑ 订会议室\n  ☐ ")
    // 光标在中间：后半句带到新的一条上
    change = NoteTasks.newline(in: "☐ 周报和月报", caret: 4)
    #expect(applied(change, to: "☐ 周报和月报") == "☐ 周报\n☐ 和月报" && change?.selection == range(7))
    // 无序：同一个符号；有序：下一个数字、同一种分隔
    #expect(applied(NoteTasks.newline(in: "* 牛奶", caret: 4), to: "* 牛奶") == "* 牛奶\n* ")
    #expect(applied(NoteTasks.newline(in: "\t- 牛奶", caret: 5), to: "\t- 牛奶") == "\t- 牛奶\n\t- ")
    #expect(applied(NoteTasks.newline(in: "9. 九", caret: 4), to: "9. 九") == "9. 九\n10. ")
    #expect(applied(NoteTasks.newline(in: "1) 一", caret: 4), to: "1) 一") == "1) 一\n2) ")
    // 不是列表行、光标还在标记前面：照常换行
    #expect(NoteTasks.newline(in: "普通的一行", caret: 3) == nil)
    #expect(NoteTasks.newline(in: "☐ 周报", caret: 0) == nil)
    #expect(NoteTasks.newline(in: "  ☐ 周报", caret: 3) == nil)
    #expect(NoteTasks.newline(in: "☐ 周报", caret: 99) == nil)
  }

  @Test func newlineOnAnEmptyItemLeavesTheList() {
    // 空任务、空列表项：去掉标记（留着缩进），光标在缩进后面
    var change = NoteTasks.newline(in: "☐ ", caret: 2)
    #expect(applied(change, to: "☐ ") == "" && change?.selection == range(0))
    change = NoteTasks.newline(in: "  - ", caret: 4)
    #expect(applied(change, to: "  - ") == "  " && change?.selection == range(2))
    #expect(applied(NoteTasks.newline(in: "3. ", caret: 3), to: "3. ") == "")
    #expect(applied(NoteTasks.newline(in: "☑", caret: 1), to: "☑") == "")
    // 后面只有空白也算空的
    #expect(applied(NoteTasks.newline(in: "☐   ", caret: 3), to: "☐   ") == "")
  }

  @Test func tabIndentsListLines() {
    var change = NoteTasks.indent("☐ 周报", caret: 4, outdent: false)
    #expect(applied(change, to: "☐ 周报") == "  ☐ 周报" && change?.selection == range(6))
    #expect(applied(NoteTasks.indent("- a", caret: 0, outdent: false), to: "- a") == "  - a")
    #expect(applied(NoteTasks.indent("1. a", caret: 0, outdent: false), to: "1. a") == "  1. a")
    // 退回：两个空格；只有一个就退一个；行首是 Tab 退那一个 Tab
    change = NoteTasks.indent("    ☐ 周报", caret: 8, outdent: true)
    #expect(applied(change, to: "    ☐ 周报") == "  ☐ 周报" && change?.selection == range(6))
    change = NoteTasks.indent(" ☐ 周报", caret: 0, outdent: true)
    #expect(applied(change, to: " ☐ 周报") == "☐ 周报" && change?.selection == range(0))
    #expect(applied(NoteTasks.indent("\t- a", caret: 4, outdent: true), to: "\t- a") == "- a")
    // 没有缩进可退：这一下吞掉，什么都不改
    change = NoteTasks.indent("☐ 周报", caret: 2, outdent: true)
    #expect(change?.replacements.isEmpty == true && change?.selection == range(2))
    // 别的行：照常（Tab 是制表符）
    #expect(NoteTasks.indent("普通的一行", caret: 0, outdent: false) == nil)
    #expect(NoteTasks.indent("", caret: 0, outdent: true) == nil)
  }

  @Test func shorthandBecomesABox() {
    var change = NoteTasks.shorthand(in: "- [ ]", caret: 5)
    #expect(applied(change, to: "- [ ]") == "☐ " && change?.selection == range(2))
    #expect(applied(NoteTasks.shorthand(in: "* [ ]", caret: 5), to: "* [ ]") == "☐ ")
    #expect(applied(NoteTasks.shorthand(in: "- [x]", caret: 5), to: "- [x]") == "☑ ")
    #expect(applied(NoteTasks.shorthand(in: "+ [X]", caret: 5), to: "+ [X]") == "☑ ")
    // 保留缩进；后面已经有字也行
    change = NoteTasks.shorthand(in: "  - [ ]周报", caret: 7)
    #expect(applied(change, to: "  - [ ]周报") == "  ☐ 周报" && change?.selection == range(4))
    // 不在行首、光标不紧跟在后面、括号里是别的：不转
    #expect(NoteTasks.shorthand(in: "a - [ ]", caret: 7) == nil)
    #expect(NoteTasks.shorthand(in: "- [ ]", caret: 4) == nil)
    #expect(NoteTasks.shorthand(in: "- [y]", caret: 5) == nil)
    #expect(NoteTasks.shorthand(in: "-[ ] ", caret: 5) == nil)
    #expect(NoteTasks.shorthand(in: "", caret: 0) == nil)
  }

  // MARK: Markdown

  @Test func markdownRoundTrips() {
    let body = "周五前交的东西\n☐ 周报\n  ☑ 订会议室\r\n\t☐\n记得 ☐ 不算\n☐后面没空格\n"
    let markdown = NoteTasks.markdown(from: body)
    #expect(
      markdown == "周五前交的东西\n- [ ] 周报\n  - [x] 订会议室\r\n\t- [ ]\n记得 ☐ 不算\n☐后面没空格\n")
    #expect(NoteTasks.body(fromMarkdown: markdown) == body)
    // 别的写法的 Markdown 任务也认；不是任务的不动
    let foreign = "* [ ] 甲\n+ [X] 乙\n- [ ]丙\n- [] 丁\n- 普通列表\n  - [x]"
    let converted = NoteTasks.body(fromMarkdown: foreign)
    #expect(converted == "☐ 甲\n☑ 乙\n- [ ]丙\n- [] 丁\n- 普通列表\n  ☑")
    // 再转回去是规整过的写法，之后往返不变
    let canonical = NoteTasks.markdown(from: converted)
    #expect(canonical == "- [ ] 甲\n- [x] 乙\n- [ ]丙\n- [] 丁\n- 普通列表\n  - [x]")
    #expect(NoteTasks.markdown(from: NoteTasks.body(fromMarkdown: canonical)) == canonical)
    #expect(NoteTasks.markdown(from: "") == "" && NoteTasks.body(fromMarkdown: "") == "")
  }

  // MARK: 进度

  @Test func progressCountsTasks() {
    #expect(NoteTasks.progress(in: "") == nil && NoteTasks.progress(in: "没有任务\n- 列表") == nil)
    let body = "周五前交的东西\n☐ 周报\n☐ 报销单\n☑ 订会议室\n下午三点"
    #expect(NoteTasks.progress(in: body)?.done == 1 && NoteTasks.progress(in: body)?.total == 3)
    // 缩进的算；行中间的、后面没空格的不算；方框在行尾、在文末都算；各种换行
    let tricky = "  ☑ 一\r\n\t☑\n记得 ☐ 不算\n☐不算\r☐ 二\u{2028}☑"
    let progress = NoteTasks.progress(in: tricky)
    #expect(progress?.done == 3 && progress?.total == 4)
    // 和认标记的口径是同一个：逐行数出来一样
    var (done, total) = (0, 0)
    tricky.enumerateLines { line, _ in
      if case .task(let isDone) = NoteTasks.prefix(of: line)?.lead {
        total += 1
        if isDone { done += 1 }
      }
    }
    #expect(progress?.done == done && progress?.total == total)
    let note = Note(id: "n", body: body, createdAt: .now, modifiedAt: .now)
    #expect(note.taskProgress?.done == 1 && note.taskProgress?.total == 3)
    #expect(Note.progressText((1, 3)) == "1 / 3" && Note.progressSpoken((1, 3)) == "任务完成 1 项，共 3 项")
  }

  // MARK: 样式

  @Test func spansOfALine() {
    typealias Span = NoteStyles.Span
    // 没做完的：只有方框那一个字
    #expect(NoteStyles.spans(in: "☐ 周报") == [Span(range: range(0, 1), kind: .box)])
    // 做完的：方框 + 内容（划线、变淡），缩进不算
    #expect(
      NoteStyles.spans(in: "  ☑ 订会议室 🙂")
        == [Span(range: range(2, 1), kind: .box), Span(range: range(4, 7), kind: .done)])
    // 做完的空任务没有内容
    #expect(NoteStyles.spans(in: "☑ ") == [Span(range: range(0, 1), kind: .box)])
    #expect(NoteStyles.spans(in: "☑") == [Span(range: range(0, 1), kind: .box)])
    // 不是任务的行没有样式
    #expect(NoteStyles.spans(in: "普通的一行").isEmpty && NoteStyles.spans(in: "- 列表").isEmpty)
    #expect(NoteStyles.spans(in: "记得 ☑ 不算").isEmpty && NoteStyles.spans(in: "").isEmpty)
  }

  @Test func dirtyLinesCoverTheEdit() {
    let text = "第一行\n🙂 表情\n☐ 任务\n" as NSString
    #expect(text.length == 15)
    // 改一个字：只排这一行（连行尾的换行）
    #expect(NoteStyles.lines(covering: range(5, 1), in: text) == range(4, 6))
    // 表情是两个 UTF-16：区间落在它中间也不越界、扩到整行
    #expect(NoteStyles.lines(covering: range(5, 0), in: text) == range(4, 6))
    // 行首的编辑带上前一行（插入、删除换行时两头都要重排）
    #expect(NoteStyles.lines(covering: range(4, 1), in: text) == range(0, 10))
    // 刚插入的换行：前后两行
    #expect(NoteStyles.lines(covering: range(3, 1), in: text) == range(0, 10))
    // 文末的空行：带上最后一行，不越界
    #expect(NoteStyles.lines(covering: range(15, 0), in: text) == range(10, 5))
    // 区间比正文还长（攒着的时候正文变短了）：夹回来
    #expect(NoteStyles.lines(covering: range(12, 99), in: text) == range(10, 5))
    #expect(NoteStyles.lines(covering: range(99, 5), in: text) == range(15, 0))
    #expect(NoteStyles.lines(covering: range(0, 0), in: "" as NSString) == range(0, 0))
    #expect(NoteStyles.lines(covering: range(0, 0), in: text) == range(0, 4))
  }

  @Test func pendingMergesEdits() {
    var pending = NoteStyles.Pending()
    #expect(pending.take() == nil)
    // 组字：同一个地方连着改（「p」→「pi」→「pin」→「拼」）
    pending.record(range(5, 1), delta: 1)
    pending.record(range(5, 2), delta: 1)
    pending.record(range(5, 3), delta: 1)
    pending.record(range(5, 1), delta: -2)
    #expect(pending.take() == range(5, 1) && pending.range == nil)
    // 后面记着一段，前面又插了字：后面那段跟着往后挪
    pending.record(range(20, 4), delta: 4)
    pending.record(range(2, 3), delta: 3)
    #expect(pending.take() == range(2, 25))
    // 前面记着一段，后面又改：并成一段
    pending.record(range(2, 3), delta: 3)
    pending.record(range(30, 2), delta: -5)
    #expect(pending.take() == range(2, 30))
    // 删到比记下的还靠前
    pending.record(range(10, 5), delta: 5)
    pending.record(range(4, 0), delta: -8)
    #expect(pending.take() == range(4, 3))
  }

  // MARK: 示例便签、标题、摘要

  @Test func sampleNoteAndTitlesStillWork() {
    let body = NoteSample.body(edge: .right, hotKey: "⌥N")
    // 示例里的三行都是能点的任务
    #expect(NoteTasks.progress(in: body)?.total == 3 && NoteTasks.progress(in: body)?.done == 0)
    let lines = body.split(separator: "\n").map(String.init)
    #expect(lines.filter { NoteTasks.box(in: $0) != nil }.count == 3)
    // 标题和摘要不带方框
    let note = Note(id: "n", body: "☐ 周报\n☑ 订会议室\n下午三点", createdAt: .now, modifiedAt: .now)
    #expect(note.displayTitle == "周报" && note.preview == "订会议室 下午三点")
  }
}
