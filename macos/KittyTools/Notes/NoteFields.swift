// 一条便签的编辑区里共用的三件（全部便签窗口的右栏、屏幕边缘那叠里打开的便签都用它们，不各抄一份）：
// 标题框（CommandTextField，墨色、上限 Note.maxTitleLength）、正文框（便签专用的编辑器 NoteTextView：墨色、任务、
// Markdown 样式（跟设置 › 便签的开关走）、上限 Note.maxBodyBytes——会超的那一次输入不进）、底下那行小字
// （改于什么时候、多少字；没存上、正文打到上限时换成警告）。占位都自己画（墨色淡一档）：系统的占位灰在有颜色的纸上太浅。
// 外面怎么摆（边距、高度）由用的地方定。
// 另有任务进度的小件（NoteProgress：「☑ 2 / 5」，全部便签窗口的列表行、屏幕边缘那叠的悬停预览卡共用）。
// **写入的闭包由用的地方绑好这条便签的编号**（setTitle / setBody 只给新的字）：换一条便签时旧的输入框还会在视图树里
// 留一小会儿（淡出），它晚到的那一下——输入法组字到一半失焦时提交的字——得落回它自己那条，不能按「现在开着哪条」写。
// 规范在 mac-whisker-notes.mdc；输入框的规矩在 mac-overlay-panel §3。

import SwiftUI

/// 标题框。↩ / ↓ / Tab / Esc 这些键转给 onCommand（返回 true = 处理了）
struct NoteTitleField: View {
  let note: Note
  var fontSize: CGFloat = 20
  var height: CGFloat = 26
  let setTitle: (String) -> Void
  let onCommand: (Selector) -> Bool

  var body: some View {
    let paper = NotePaper.of(note)
    CommandTextField(
      text: Binding {
        note.title
      } set: {
        setTitle($0)
      }, placeholder: "", fontSize: fontSize, weight: .semibold, textColor: paper.inkColor,
      maxLength: Note.maxTitleLength, onCommand: onCommand
    )
    .frame(height: height)
    .overlay(alignment: .leading) {
      if note.title.isEmpty {
        NotePlaceholder(text: "标题", size: fontSize, weight: .semibold, paper: paper)
      }
    }
    .accessibilityLabel("标题")
  }
}

/// 正文框。滚动区铺满给它的宽、文字缩进放在 horizontalInset 里（margin − NSTextView 自己的 5）：滚动条贴着右边
struct NoteBodyField: View {
  let note: Note
  let fontSize: CGFloat
  /// 文字的左边线离这块视图的左边多远
  let margin: CGFloat
  let setBody: (String) -> Void
  let onOverflow: () -> Void
  /// Esc（输入法组字时 Esc 归输入法，到不了这里）；全部便签窗口里不做事
  var onCancel: () -> Void = {}
  /// 屏幕边缘那叠用：这条便签是「该拿焦点的那条」时给第几次要（NoteDeckModel.focusRequest(for:)）——正文框挂进窗口的
  /// 那一刻自己拿焦点，之后这个数每变一次再拿一次。nil = 不归它拿（全部便签窗口不给：选中一条时焦点留在列表上）
  var focusRequest: Int?
  /// 这条便签的撤销栈（NoteDeckModel.textUndo / NotesWindowModel.textUndo）：正文里打的字登记在它上面，⌘Z / ⇧⌘Z
  /// 动的也是它
  var undo: UndoManager?
  /// 设置 › 便签「Markdown 样式」：变了正文整篇重排
  @AppStorage(Prefs.notesMarkdown) private var markdown = true

  var body: some View {
    let paper = NotePaper.of(note)
    NoteTextEditor(
      note: note, fontSize: fontSize, horizontalInset: margin - 5, focusRequest: focusRequest,
      undo: undo, markdown: markdown, onChange: setBody, onOverflow: onOverflow, onCancel: onCancel
    )
    .accessibilityLabel("正文")
    .overlay(alignment: .topLeading) {
      // 位置就是第一个字的位置（左 = 边线，上 6 = 编辑器的 textContainerInset）：一打字不跳
      if note.body.isEmpty {
        NotePlaceholder(text: "写点什么…", size: fontSize, weight: .regular, paper: paper)
          .padding(.leading, margin - 2)
          .padding(.top, 6)
      }
    }
  }
}

/// 底下一行小字：「改于 今天 09:12 · 128 字」（最近删除里是删于什么时候、还留几天）；有改动没落下盘、正文打到上限时
/// 换成警告（只染三角，字用墨色：橙字在纸上对比度不够）
struct NoteFootnote: View {
  let note: Note
  let isOverLimit: Bool
  /// 仓库里有没落下盘的改动（NoteStore.saveProblem 不是 nil；它自己会再试）
  var isUnsaved = false

  static let unsavedText = "没存上，正在重试"

  /// 这一行该换成哪句警告（纯函数）：没存上的先说（字可能丢），再是打到上限；都没有是 nil
  static func warning(isUnsaved: Bool, isOverLimit: Bool) -> String? {
    isUnsaved ? unsavedText : isOverLimit ? NotesWindowModel.overLimitText : nil
  }

  var body: some View {
    let paper = NotePaper.of(note)
    HStack(spacing: 6) {
      if let warning = Self.warning(isUnsaved: isUnsaved, isOverLimit: isOverLimit) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Color(nsColor: .systemOrange))
          .accessibilityHidden(true)
        Text(warning).foregroundStyle(paper.ink)
      } else {
        Text(NotesWindowModel.footnote(note)).foregroundStyle(paper.secondaryInk)
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 11))
    .lineLimit(1)
  }
}

/// 输入框空着时的占位（墨的 35%）。NSTextField / NSTextView 的字自己左边各有 2 pt，占位跟着让 2
struct NotePlaceholder: View {
  let text: String
  let size: CGFloat
  let weight: Font.Weight
  let paper: NotePaper

  var body: some View {
    Text(text)
      .font(.system(size: size, weight: weight))
      .foregroundStyle(paper.ink.opacity(0.35))
      .padding(.leading, 2)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// 任务进度：一个小方框符号 +「2 / 5」（做完几条 / 共几条）。颜色由用的地方给（列表行是 secondary，预览卡是次要的墨）。
/// 是给眼睛看的：旁白那句由用它的行自己读（Note.progressSpoken）
struct NoteProgress: View {
  let progress: (done: Int, total: Int)

  var body: some View {
    HStack(spacing: 3) {
      Image(
        systemName: progress.done == progress.total ? "checkmark.square.fill" : "checkmark.square"
      )
      .font(.system(size: 10, weight: .medium))
      Text(verbatim: Note.progressText(progress)).font(.system(size: 11)).monospacedDigit()
    }
    .lineLimit(1)
    .fixedSize()
    .accessibilityHidden(true)
  }
}
