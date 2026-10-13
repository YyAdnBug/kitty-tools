// 快速记一条（PLAN §10「便签」，全局键默认 ⌥N）的状态和规则。面板是 OverlayPanel 的一个实例（AppDelegate.noteCapture），
// 和启动器、剪贴板面板同位置同宽、只开一个；视图在 NoteCaptureView.swift。
// - 草稿：点面板外面、再按热键、⌘W 收起时留着（连同选的目的地），下次呼出还在；Esc 清空并收起；保存后清空。
// - 记到哪：默认新便签；也可以接在最近改过的 8 条没归档的便签之一后面（⌘1 新便签，⌘2–⌘9 那 8 条）。选了的那条在面板
//   开着时被删了、归档了，就当新便签。
// - 保存（↩）：去掉首尾空白，空的不存；新便签 = 新建一条；已有的 = 接在它正文后面（原来有内容、末尾没换行就先换一行）。
//   存完的正文会超过 Note.maxBodyBytes 时不存，底栏就地说（不截断）。存好收起面板，刘海岛「已记下」+ 那条便签的标题。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class NoteCaptureModel {
  /// 按 ↩ 之后怎么样了
  enum Outcome: Equatable {
    /// 去掉首尾空白是空的：不存，面板留着
    case empty
    /// 存完会超过单条上限：不存，底栏说原因
    case tooLong
    /// 存进了这条便签（编号）
    case saved(String)
  }

  /// 面板的排版（视图按它排，高度按它算）
  enum Layout {
    /// 顶上「记到哪」那一行、底栏
    static let headerHeight: CGFloat = 44
    static let barHeight: CGFloat = 36
    /// 文字、底栏的左右边线（同搜索线的左右内边距）
    static let margin: CGFloat = 18
    static let fontSize: CGFloat = 15
    /// 正文 3 行起，最多 8 行，再多在框里滚
    static let lines = 3...8
    /// 文本区上下：框外各 4 + SourceTextView 自己的上下内缩 6
    static let textPadding: CGFloat = 4
    static let textInset: CGFloat = 6
  }

  /// 目的地里最多列几条已有的便签（⌘2–⌘9）
  static let destinationLimit = 8

  let store: NoteStore
  /// 草稿
  var draft = "" {
    didSet {
      guard draft != oldValue else { return }
      notice = nil
      resize(height)
    }
  }
  /// 记到哪条已有的便签（编号）；nil = 新便签。读的时候用 target：它不在目的地里了（删了、归档了）就不算数
  private(set) var destination: String?
  /// 底栏左边的就地提示（存不了的原因）；一改草稿、一换目的地就收
  private(set) var notice: BarNotice?
  /// 鼠标停在第几个目的地上（顶上那一行先写它的名字）；nil = 没停
  var hovered: Int?
  @ObservationIgnored var island: Island?
  /// 保存后收起（立刻）、Esc 收起（淡出）、文本区高度变了
  @ObservationIgnored var hidePanel: () -> Void = {}
  @ObservationIgnored var dismissPanel: () -> Void = {}
  @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }

  init(store: NoteStore) { self.store = store }

  // MARK: 目的地

  /// 能接着记的便签：没归档、没删的里最近改过的几条（新的在前）
  var destinations: [Note] { Self.destinations(in: store.active) }

  static func destinations(in active: [Note]) -> [Note] {
    Array(
      active.sorted { ($0.modifiedAt, $0.id) > ($1.modifiedAt, $1.id) }.prefix(destinationLimit))
  }

  /// 选中的那条已有的便签；nil = 记成新便签
  var target: Note? { destination.flatMap { id in destinations.first { $0.id == id } } }

  /// 选中的是第几个目的地：0 = 新便签，1…8 = destinations 里的第几条
  var selectedIndex: Int {
    destination.flatMap { id in destinations.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
  }

  /// 第几个目的地叫什么（顶上那一行、旁白）
  func title(of index: Int) -> String {
    let list = destinations
    return list.indices.contains(index - 1) ? list[index - 1].displayTitle : "新便签"
  }

  /// 选第几个目的地（⌘1–⌘9、点圆点）；没有那一条就响一声
  func select(_ index: Int) {
    let list = destinations
    guard index == 0 || list.indices.contains(index - 1) else { return NSSound.beep() }
    destination = index == 0 ? nil : list[index - 1].id
    notice = nil
    // 焦点一直在输入框里，换了目的地旁白读不到
    Island.announce(index == 0 ? "记成新便签" : "记到「\(list[index - 1].displayTitle)」")
  }

  /// ⌘1 新便签、⌘2–⌘9 记到已有的某一条（面板的 keyEquivalentHandler）
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
      let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode))
    else { return false }
    select(digit)
    return true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]

  // MARK: 保存

  /// 现在按 ↩ 有没有东西可记（底栏「记下」置不置灰）
  var canSave: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// ↩：记下。存成了就清空草稿、收起面板、刘海岛说一声
  @discardableResult
  func save(now: Date = .now) -> Outcome {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .empty }
    let old = target
    let body = Self.body(appending: text, to: old?.body)
    guard body.utf8.count <= Note.maxBodyBytes else {
      notice = .warning(old == nil ? "太长了，一条便签最多 1 MB" : "接上这段就超过一条便签 1 MB 的上限了，换一条记")
      Island.announce(notice?.text ?? "")
      return .tooLong
    }
    let id: String
    if let old {
      store.setBody(body, of: old.id, now: now)
      store.flush()
      id = old.id
    } else {
      id = store.create(body: body, now: now).id
    }
    reset()
    hidePanel()
    if let problem = store.saveProblem {
      // 字在内存里、仓库会自己再试（NoteStore.flush）；退出前还落不下去 AppDelegate 会拦
      island?.show("记下了，但还没存上", detail: Island.excerpt(problem), tone: .warning)
    } else {
      island?.show("已记下", detail: store.note(id)?.displayTitle)
    }
    return .saved(id)
  }

  /// 接在已有的正文后面（纯函数）：原来是空的就是这段话；有内容、末尾没换行就先换一行
  static func body(appending text: String, to old: String?) -> String {
    guard let old, !old.isEmpty else { return text }
    return old + (old.hasSuffix("\n") ? "" : "\n") + text
  }

  /// Esc：清空并收起
  func cancel() {
    reset()
    dismissPanel()
  }

  /// 要呼出了：上次选的目的地已经不在了就回到新便签
  func prepareForShow() {
    if target == nil { destination = nil }
    notice = nil
  }

  /// 面板收起了（草稿和目的地留着）
  func didHide() {
    hovered = nil
    notice = nil
  }

  private func reset() {
    draft = ""
    destination = nil
    notice = nil
  }

  // MARK: 高度

  /// 整块面板的高：顶上一行 + 文本区 + 底栏（两条发丝线各算 0.5，同启动器）
  var height: CGFloat { Self.height(for: draft) }

  static func height(for draft: String) -> CGFloat {
    Layout.headerHeight + 0.5 + textHeight(for: draft)
      + 2 * (Layout.textInset + Layout.textPadding) + 0.5 + Layout.barHeight
  }

  /// 文本区里字占多高（纯函数）：按面板的宽排一遍草稿，夹在 3 行和 8 行之间。只排前 4000 个字：再窄的字这么多也早过了
  /// 8 行（贴进来一大段时不用每按一个键把整段重排一遍）。
  /// ponytail: 是估的——系统设成一直显示滚动条时文本框窄 15 pt，可能早折一行；差的那一行在框里滚得到
  static func textHeight(for draft: String) -> CGFloat {
    let font = NSFont.systemFont(ofSize: Layout.fontSize)
    let measure = { (text: String) in
      ceil(
        (text as NSString).boundingRect(
          with: NSSize(
            width: Style.listPanelWidth - 2 * Layout.margin, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        ).height)
    }
    let line = measure("字")
    return min(
      max(measure(String(draft.prefix(4000))), line * CGFloat(Layout.lines.lowerBound)),
      line * CGFloat(Layout.lines.upperBound))
  }
}
