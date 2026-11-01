// 快速记一条（PLAN §10「便签」，全局键默认 ⌥N）的状态和规则。面板是 OverlayPanel 的一个实例（AppDelegate.noteCapture），
// 和启动器、剪贴板面板同位置同宽、只开一个；视图在 NoteCaptureView.swift。
// - 草稿：点面板外面、再按热键、⌘W 收起时留着（连同标题、选的目的地），下次呼出还在；Esc 一起清空并收起；保存后一起清空。
//   **重启也不丢**（第四轮体检 E2）：停手约 1 秒（draftDelay）、面板收起、退出前存进数据目录里的 notes-draft.json（原子写；
//   不放偏好——偏好会被设置的导出 / 同步带走；这个文件不在任何备份、导出、同步的范围里），清空时删掉，下次建面板时读回。
//   Esc 清掉的草稿不是空的：岛上「已清空草稿」+「恢复」，点了重新呼出、把内容放回来（这时又打了字的，接在后面）。
// - 标题（2026-10-13 手测反馈）：记成新便签时顶上那一行是个标题框，填了就是新便签的标题，不填照旧取正文第一行；
//   只填了标题、正文空着也算有内容，存成一条只有标题的便签。记到已有的某条时没有这个框（填过的留着、不用它）。
//   焦点：呼出时在正文；正文里 Tab 去标题，标题里 Tab / ↩ 回正文（↩ 不保存）；换目的地后回正文——两个框的交接用
//   focusRequest（titleFocus / bodyFocus，mac-overlay-panel §3）。
// - 记到哪：默认新便签；也可以接在最近改过的 8 条没归档的便签之一后面（⌘1 新便签，⌘2–⌘9 那 8 条）。选了的那条在面板
//   开着时被删了、归档了，就当新便签。
// - 保存（正文里 ↩）：去掉首尾空白，空的不存；新便签 = 新建一条；已有的 = 接在它正文后面（原来有内容、末尾没换行就先换一行）。
//   存完的正文会超过 Note.maxBodyBytes 时不存，底栏就地说（不截断）。存好收起面板，刘海岛「已记下」+ 那条便签的标题，
//   带「打开」（第四轮体检 U6：屏幕边缘那叠开着就在那叠里打开这一条，关着在全部便签窗口里打开；AppDelegate 接）。

import AppKit
import Carbon.HIToolbox
import Observation
import os

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

  /// 草稿停手多久存进文件、文件叫什么（在数据目录里，E2）
  static let draftDelay: Duration = .seconds(1)
  static let draftName = "notes-draft.json"

  let store: NoteStore
  /// 草稿
  var draft = "" {
    didSet {
      guard draft != oldValue else { return }
      notice = nil
      resize(height)
      draftChanged()
    }
  }
  /// 新便签的标题（可不填）。和草稿一起留着、一起清空；记到已有的便签时不用它
  var title = "" {
    didSet {
      guard title != oldValue else { return }
      notice = nil
      draftChanged()
    }
  }
  /// 两个输入框的焦点交接：数变一次，那个框拿一次焦点
  private(set) var titleFocus = 0
  private(set) var bodyFocus = 0
  /// 记到哪条已有的便签（编号）；nil = 新便签。读的时候用 target：它不在目的地里了（删了、归档了）就不算数
  private(set) var destination: String? {
    didSet { if destination != oldValue { draftChanged() } }
  }
  /// 底栏左边的就地提示（存不了的原因）；一改草稿、一换目的地就收
  private(set) var notice: BarNotice?
  /// 鼠标停在第几个目的地上（顶上那一行先写它的名字）；nil = 没停
  var hovered: Int?
  @ObservationIgnored var island: Island?
  /// 保存后收起（立刻）、Esc 收起（淡出）、文本区高度变了
  @ObservationIgnored var hidePanel: () -> Void = {}
  @ObservationIgnored var dismissPanel: () -> Void = {}
  @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }
  /// 岛上的「打开」（存好的那条，U6）、「恢复」（重新呼出面板，E2）：AppDelegate 接
  @ObservationIgnored var openNote: (String) -> Void = { _ in }
  @ObservationIgnored var reopen: () -> Void = {}
  /// 草稿存在哪（nil = 不存：单测、截图自检）
  @ObservationIgnored private let draftURL: URL?
  @ObservationIgnored private var draftTask: Task<Void, Never>?
  /// 正在把文件里读回来的草稿放进来（这时不回头再存一遍）
  @ObservationIgnored private var isLoadingDraft = false

  init(store: NoteStore, draftURL: URL? = nil) {
    self.store = store
    self.draftURL = draftURL
    if let saved = draftURL.flatMap({ Draft(data: try? Data(contentsOf: $0)) }) {
      isLoadingDraft = true
      put(saved)
      isLoadingDraft = false
    }
  }

  // MARK: 草稿（E2）

  /// 草稿的三样：标题、正文、记到哪（notes-draft.json 的样子）
  struct Draft: Codable, Equatable {
    var title = ""
    var body = ""
    var destination: String?

    /// 去掉空白什么都没有：不存文件、Esc 清掉也不给「恢复」
    var isEmpty: Bool {
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 读文件里的（没有、读不出来、是空的都是 nil）
    init?(data: Data?) {
      guard let data, let draft = try? JSONDecoder().decode(Draft.self, from: data), !draft.isEmpty
      else { return nil }
      self = draft
    }

    init(title: String = "", body: String = "", destination: String? = nil) {
      (self.title, self.body, self.destination) = (title, body, destination)
    }

    var data: Data? { try? JSONEncoder().encode(self) }
  }

  /// 现在的草稿
  var current: Draft { Draft(title: title, body: draft, destination: destination) }

  private func put(_ saved: Draft) {
    title = saved.title
    draft = saved.body
    destination = saved.destination
  }

  /// 标题、正文、目的地变了：停手 draftDelay 再存
  private func draftChanged() {
    guard draftURL != nil, !isLoadingDraft else { return }
    draftTask?.cancel()
    draftTask = Task { [weak self] in
      try? await Task.sleep(for: Self.draftDelay)
      guard !Task.isCancelled else { return }
      self?.saveDraft()
    }
  }

  /// 现在就存（面板收起、退出前也调）：空的删掉文件，不空的原子写
  func saveDraft() {
    draftTask?.cancel()
    draftTask = nil
    guard let draftURL else { return }
    let draft = current
    if draft.isEmpty {
      guard FileManager.default.fileExists(atPath: draftURL.path) else { return }
      do {
        try FileManager.default.removeItem(at: draftURL)
      } catch {
        // 删不掉（权限、占用）：写一份空的盖上去（读回来当没有），不然下次启动它又回来、被存第二次
        do {
          try Draft().data?.write(to: draftURL, options: .atomic)
        } catch {
          Log.storage.error(
            "快速记一条的草稿文件删不掉也盖不掉：\(error.localizedDescription, privacy: .public)")
        }
      }
    } else if let data = draft.data {
      do {
        try FileManager.default.createDirectory(
          at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: draftURL, options: .atomic)
      } catch {
        Log.storage.error("快速记一条的草稿没存上：\(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// 岛上的「恢复」：重新呼出面板、把清掉的那份放回来。这几秒里又打了字的：标题空着才换，正文接在后面，目的地还是新便签才换
  func restore(_ saved: Draft) {
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = saved.title }
    draft = draft.isEmpty ? saved.body : Self.body(appending: draft, to: saved.body)
    if destination == nil { destination = saved.destination }
    reopen()
    bodyFocus += 1
  }

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
    // 换了目的地接着打正文（标题框可能正拿着焦点、又跟着目的地没了）
    bodyFocus += 1
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

  // MARK: 标题

  /// 记成新便签时才有标题框
  var hasTitleField: Bool { target == nil }

  /// 新便签用的标题（去掉首尾空白）；记到已有的便签时是空的——不改那条的标题
  var newTitle: String {
    hasTitleField ? title.trimmingCharacters(in: .whitespacesAndNewlines) : ""
  }

  /// 正文里 Tab：去标题框（没有标题框时不动）
  func focusTitle() {
    if hasTitleField { titleFocus += 1 }
  }

  /// 标题框里 Tab / ↩ / ↓：回正文
  func focusBody() { bodyFocus += 1 }

  // MARK: 保存

  /// 现在按 ↩ 有没有东西可记（底栏「记下」置不置灰）：正文有字，或者记成新便签、填了标题
  var canSave: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !newTitle.isEmpty
  }

  /// ↩：记下。存成了就清空草稿、收起面板、刘海岛说一声
  @discardableResult
  func save(now: Date = .now) -> Outcome {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = newTitle
    guard !text.isEmpty || !title.isEmpty else { return .empty }
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
      id = store.create(body: body, title: title, now: now).id
    }
    reset()
    hidePanel()
    if let problem = store.saveProblem {
      // 字在内存里、仓库会自己再试（NoteStore.flush）；退出前还落不下去 AppDelegate 会拦
      island?.show("记下了，但还没存上", detail: Island.excerpt(problem), tone: .warning)
    } else {
      // 「打开」（U6）：在屏幕边缘那叠 / 全部便签窗口里打开这一条，点岛本身也是它
      island?.show(
        "已记下", detail: store.note(id)?.displayTitle,
        actions: [.init("打开", opens: true) { [weak self] in self?.openNote(id) }])
    }
    return .saved(id)
  }

  /// 接在已有的正文后面（纯函数）：原来是空的就是这段话；有内容、末尾没换行就先换一行
  static func body(appending text: String, to old: String?) -> String {
    guard let old, !old.isEmpty else { return text }
    return old + (old.hasSuffix("\n") ? "" : "\n") + text
  }

  /// Esc：清空并收起。清掉的不是空的：岛上「已清空草稿」+「恢复」（E2）
  func cancel() {
    let cleared = current
    reset()
    dismissPanel()
    guard Self.offersRestore(cleared) else { return }
    // 不把草稿的字写上岛（岛会记进那一张里的最近提示：清掉的字不该在那里多留一阵）
    island?.show(
      "已清空草稿", detail: "几秒内点「恢复」能放回来", symbol: "trash.circle.fill",
      actions: [.init("恢复") { [weak self] in self?.restore(cleared) }])
  }

  /// Esc 清掉的这份要不要给「恢复」（纯函数）：去掉空白还有字才给
  static func offersRestore(_ cleared: Draft) -> Bool { !cleared.isEmpty }

  /// 要呼出了：上次选的目的地已经不在了就回到新便签
  func prepareForShow() {
    if target == nil { destination = nil }
    notice = nil
  }

  /// 面板收起了（草稿和目的地留着，顺手存进文件）
  func didHide() {
    hovered = nil
    notice = nil
    if draftTask != nil { saveDraft() }
  }

  /// 清空（存好了、Esc）：草稿文件跟着删
  private func reset() {
    draft = ""
    title = ""
    destination = nil
    notice = nil
    saveDraft()
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
