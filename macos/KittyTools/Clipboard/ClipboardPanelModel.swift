// 剪贴板面板（透镜指令条 Lens Bar，mac-clipboard §4）的界面状态与操作：筛选标签、选中 / 多选、键盘命令、
// 粘贴 / 复制 / 删除撤销、筛选面板与 ⌘K 操作面板。视图只负责画。
// 焦点始终在搜索框：方向键 / 回车 / Tab / ⇧Tab / ← → / ⌫ / Esc 从搜索框的 doCommandBy 进来，⌘ 组合键从面板的
// performKeyEquivalent 进来（handleKeyEquivalent）。交互按 macOS 习惯设计：
// 单击选中（透镜滑过去）、双击或 ↩ 粘贴、⌥↩ 纯文本（打开「默认粘贴为纯文本」后反过来）、⌘↩ 仅复制、⌘1–9 直接粘贴第 N 条、
// 删除不确认、⌘Z 连着撤（面板收起时才真正删）；
// 范围和筛选只以搜索框里的标签出现：Tab 开关筛选面板、⇧Tab 循环范围、⌫（搜索为空）先选中最后一个标签再删；
// ⌘K 或 →（光标在末尾）打开操作面板，← 关掉；两个面板开着时搜索框用来过滤条目，↑↓ ↩ 选择执行，Esc 关掉；
// ⌘Y 放大预览（QuickLookView，单独的浮层，不抢键盘：↑↓ 照样在这里换条目）。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class ClipboardPanelModel {
  enum Scope: String, CaseIterable {
    case all, favorites, snippets

    var title: String {
      switch self {
      case .all: "全部"
      case .favorites: "收藏"
      case .snippets: "片段"
      }
    }

    var symbol: String {
      switch self {
      case .all: "tray.full"
      case .favorites: "star"
      case .snippets: "text.badge.star"
      }
    }
  }

  /// 面板里浮起的两个菜单（都是 Shell/ActionMenu）：Tab 的筛选面板、⌘K 的操作面板
  enum Palette { case filters, actions }

  /// 搜索框里的筛选标签（范围「全部」不出标签）；一种筛选最多一个，所以按种类当 id
  struct Token: Identifiable, Equatable {
    enum Kind: Hashable { case scope, type, source, group }
    let kind: Kind
    let title: String
    var id: Kind { kind }
  }

  /// 收藏夹筛选（体检 A1：分组并进收藏，收藏夹里的都是收藏）
  enum GroupFilter: Hashable {
    case all
    case group(UUID)
  }

  enum Dialog: Identifiable {
    case note(UUID)
    case edit(UUID)
    case newSnippet, manageGroups
    case newGroup(Set<UUID>)

    var id: String { String(describing: self) }
  }

  /// 底栏左边的提示：message 带绿色对勾；warning 橙色三角（没做全，如「只复制了第 1 条」）；
  /// undo 后面跟「撤销 ⌘Z」（已删除 N 条、已删除收藏夹、取消收藏后会被清理）
  enum Toast: Equatable {
    case message(String)
    case warning(String)
    case undo(String)
  }

  /// 一次粘贴 / 复制写进剪贴板的东西：writes 每项是一次写入（逐条粘贴时有多项）
  struct Payload {
    /// 写进剪贴板的内容在历史里是哪条：单条 = 它自己（挪到最前）；合成一段文本 / 一组文件 = 新记一条
    enum Entry {
      case existing(UUID)
      case new(ClipItem)
    }

    var writes: [[NSPasteboardItem]]
    /// 单条片段粘贴后按几次 ← 把光标挪回 {cursor}（N17；多条合并粘贴不挪）
    var caretMoves = 0
    /// nil = 逐条粘贴（不另记）
    var entry: Entry?
  }

  let store: ClipboardStore
  @ObservationIgnored var hidePanel: () -> Void = {}
  /// 面板高度变了（条数、筛选、透镜开关）：窗口顶边不动地伸缩
  @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }
  @ObservationIgnored var openTranslate: (String) -> Void = { _ in }
  @ObservationIgnored var openSettings: () -> Void = {}
  @ObservationIgnored var openQuickLook: () -> Void = {}
  /// 写剪贴板（单测换掉它，不碰真剪贴板：写一下别的剪贴板工具、正在跑的本 App 都会记一条）
  @ObservationIgnored var writeClipboard: ([NSPasteboardItem]) -> Void = { Paster.write($0) }
  /// 剪贴板的 changeCount（单测换掉它，真剪贴板随时会被别的 App 改）
  @ObservationIgnored var clipboardChangeCount: () -> Int = { NSPasteboard.general.changeCount }
  /// 刘海岛（AppDelegate 给，单测里是 nil）：面板收起、底栏被放大预览挡住、出错时的提示走它
  @ObservationIgnored var island: Island?
  /// animated = false：面板收起、粘贴时直接消失
  @ObservationIgnored var closeQuickLook: (_ animated: Bool) -> Void = { _ in }
  /// 透镜（透镜关掉 / 多选时是选中行那一格）在面板里的位置（窗口坐标，原点左上；只算列表可见区里的那部分）和它是哪一条，
  /// 由选中高亮按前缀和上报：放大预览从这里长出来、缩回这里。滚出可见区、列表清空时为 nil；
  /// id 不是当前选中项（刚换了选中、还没布局）时别用
  @ObservationIgnored var cardFrame: (id: UUID, rect: CGRect)?

  /// 启动器「cb 关键词」呼出面板后直接设它；reset() 清空
  var query = "" {
    didSet {
      armsLastToken = false
      restartBrowsing()
    }
  }
  var scope = Scope.all { didSet { restartBrowsing() } }
  /// nil = 全部类型。选了图片 / 文件就清掉形态筛选（形态只对文本有意义）
  var kind: ClipItem.Kind? {
    didSet {
      if kind != .text && kind != nil { form = nil }
      restartBrowsing()
    }
  }
  /// 选了形态就把类型切到文本
  var form: ContentForm? {
    didSet {
      if form != nil { kind = .text }
      restartBrowsing()
    }
  }
  var sourceBundleID: String? { didSet { restartBrowsing() } }
  var groupFilter = GroupFilter.all { didSet { restartBrowsing() } }
  var multiSelection: Set<UUID> = []
  var dialog: Dialog? { didSet { if dialog != nil { endQuickLook() } } }
  /// ⌘Y 放大预览开着
  private(set) var isQuickLooking = false
  /// 放大预览的浮层上画不画卡片：打开前设上，浮层真正收走（缩回动画放完）才清掉。
  /// 收走的浮层里别再画：SwiftUI 在看不见的窗口里照样跟着选中重建卡片（Quick Look 视图、2400 px 大图）
  var showsQuickLookContent = false
  var toast: Toast?
  /// 菜单栏「暂停记录剪贴板」开着（AppDelegate 跟 ClipboardWatcher.isUserPaused 一起设）：底栏条数前写「已暂停记录」
  var isRecordingPaused = false
  /// 开着的浮起菜单：搜索框这时改成过滤它的条目（actionQuery），↑↓ ↩ 选择执行
  var palette: Palette? {
    didSet {
      guard palette != oldValue else { return }
      actionQuery = ""
      actionSelection = 0
      armsLastToken = false
      if palette != nil { endQuickLook() }  // 菜单在剪贴板面板里，被预览挡着
    }
  }
  /// ⌘K 操作面板开着（旧接口，等于 palette == .actions）
  var showsActions: Bool {
    get { palette == .actions }
    set { palette = newValue ? .actions : palette == .actions ? nil : palette }
  }
  var actionQuery = "" { didSet { actionSelection = 0 } }
  var actionSelection = 0
  /// 搜索为空时按了一下 ⌫：最后一个标签待删（粉 0.30 底），再按一下才删；打字、Esc、换面板都取消
  var armsLastToken = false
  /// 选中高亮这次怎么移动（Whisker §4）：键盘单按 snap，连发与筛选变化不动画，点选 glide
  private(set) var selectionMotion = Style.Motion.instant
  /// 列表增删的动画：筛选 / 搜索换列表时这一次不动画（instant），视图画完这次后调 settleList() 恢复
  private(set) var listMotion = Style.Motion.settle
  /// 每次换列表（筛选 / 搜索）加一：视图据此在画完后恢复 listMotion
  private(set) var listGeneration = 0
  /// 选中条目里的第一个链接（⌘K「打开链接」；按条目缓存，别每次渲染都跑 NSDataDetector）
  @ObservationIgnored private var linkCache: (id: UUID, url: URL?)?
  /// 预览里的 JSON 美化开关，切换条目时复位
  var prettyJSON = false

  private var selectedID: UUID?
  /// 用户在主动浏览（方向键、⌘数字、修饰键点击）时，新条目进来不抢选中
  private var isBrowsing = false
  private var anchorID: UUID?
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  /// ⌘C 复制的条目：面板开着时列表不动，收起（reset）时再挪到最前 / 记新历史（体检 A8）。
  /// changeCount 是写完那一刻的：收起时剪贴板已被别的内容换掉（复制图中文字、色值块、固定着去别处复制）就不挪
  @ObservationIgnored private var pendingCopy: (entry: Payload.Entry?, changeCount: Int)?
  @ObservationIgnored private var formCache: [UUID: ContentForm?] = [:]

  init(store: ClipboardStore) {
    self.store = store
  }

  // MARK: 列表

  var visibleItems: [ClipItem] {
    store.search(query).filter { item in
      switch scope {
      case .all: break
      case .favorites: guard item.favorite else { return false }
      case .snippets: guard item.isSnippet else { return false }
      }
      if let kind, item.kind != kind { return false }
      if let form, contentForm(of: item) != form { return false }
      if let sourceBundleID, item.sourceBundleID != sourceBundleID { return false }
      switch groupFilter {
      case .all: return true
      case .group(let id): return item.groupID == id
      }
    }
  }

  var selectedItem: ClipItem? { selectedItem(in: visibleItems) }

  /// 列表已经算好时用它，省一次搜索
  func selectedItem(in items: [ClipItem]) -> ClipItem? {
    items.first { $0.id == selectedID } ?? items.first
  }

  /// 有搜索词，或类型 / 形态 / 来源 / 收藏夹筛选生效（范围不算）：没有结果时是「没有匹配的条目」
  var isFiltered: Bool {
    !query.isEmpty || kind != nil || form != nil || sourceBundleID != nil || groupFilter != .all
  }

  /// 片段范围第一行的「＋ 新建片段」：片段范围里搜索 / 筛选没有结果时不画，让位给「没有匹配的条目」和清除按钮
  func showsNewSnippetRow(in items: [ClipItem]) -> Bool {
    scope == .snippets && !(items.isEmpty && isFiltered)
  }

  /// 空态的「清除搜索和筛选」：不像 reset() 那样提交删除、关对话框
  func clearSearchAndFilters() {
    query = ""
    scope = .all
    kind = nil
    form = nil
    sourceBundleID = nil
    groupFilter = .all
  }

  /// 透镜和放大预览里的正文：JSON 按开关美化。ponytail: 超长文本只预览前 10 万字，粘贴仍是全文
  func displayText(of item: ClipItem) -> String {
    let text = String((item.text ?? "").prefix(100_000))
    guard prettyJSON, contentForm(of: item) == .json,
      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return text }
    return String(decoding: data, as: UTF8.self)
  }

  /// 来源 App 筛选的候选（出现过的 App，按条目数多→少）
  var sources: [(bundleID: String, name: String, count: Int)] {
    var counts: [String: (name: String, count: Int)] = [:]
    for item in store.items {
      guard let id = item.sourceBundleID else { continue }
      counts[id, default: (item.sourceName ?? id, 0)].count += 1
    }
    return counts.sorted { $0.value.count > $1.value.count }.map {
      ($0.key, $0.value.name, $0.value.count)
    }
  }

  // MARK: 筛选标签

  /// 生效的范围 / 筛选，按 范围 → 类型或形态 → 来源 → 收藏夹 排
  var tokens: [Token] {
    var tokens: [Token] = []
    if scope != .all { tokens.append(Token(kind: .scope, title: scope.title)) }
    if let form {
      tokens.append(Token(kind: .type, title: form.title))
    } else if let kind {
      tokens.append(Token(kind: .type, title: kind.title))
    }
    if let sourceBundleID {
      let name = store.items.first { $0.sourceBundleID == sourceBundleID }?.sourceName
      tokens.append(Token(kind: .source, title: name ?? sourceBundleID))
    }
    if case .group(let id) = groupFilter {
      tokens.append(
        Token(kind: .group, title: store.groups.first { $0.id == id }?.name ?? "收藏夹"))
    }
    return tokens
  }

  func remove(_ token: Token.Kind) {
    armsLastToken = false
    switch token {
    case .scope: scope = .all
    case .type:
      form = nil
      kind = nil
    case .source: sourceBundleID = nil
    case .group: groupFilter = .all
    }
  }

  /// ⇧Tab：范围在 全部 → 收藏 → 片段 之间循环
  func cycleScope() {
    let all = Scope.allCases
    palette = nil
    scope = all[((all.firstIndex(of: scope) ?? 0) + 1) % all.count]
  }

  /// ⌫（搜索为空）：第一下选中最后一个标签，第二下删掉
  private func deleteBackwardOnTokens() -> Bool {
    guard let last = tokens.last else { return false }
    if armsLastToken {
      remove(last.kind)
    } else {
      armsLastToken = true
      announce("再按一次删除键，移除筛选：\(last.title)")
    }
    return true
  }

  func announce(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  func contentForm(of item: ClipItem) -> ContentForm? {
    guard item.kind == .text, let text = item.text else { return nil }
    if let cached = formCache[item.id] { return cached }
    let form = ContentForm.detect(text)
    formCache[item.id] = form
    return form
  }

  func select(_ item: ClipItem) {
    selectedID = item.id
    prettyJSON = false
  }

  // MARK: 键盘

  /// 搜索框转来的编辑命令（mac-clipboard §4）：↑↓ 移动（带 ⇧ 扩展多选）、↩ 粘贴、⌥↩ 纯文本粘贴、
  /// Tab 开关筛选面板、⇧Tab 循环范围、→（光标在末尾）开 ⌘K、←（⌘K 过滤词为空）关 ⌘K、⌫（搜索为空）删标签；
  /// Esc 依次：缩回放大预览 → 关浮起的菜单 → 关对话框 → 取消标签待删 → 清空搜索词 → 取消多选 → 交给面板关闭。
  /// 条件不满足的返回 false，交还字段编辑器照常处理（移光标、删字）
  func handleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      if isQuickLooking {
        toggleQuickLook()
      } else if palette != nil {
        palette = nil
      } else if dialog != nil {
        dialog = nil
      } else if armsLastToken {
        armsLastToken = false
      } else if !query.isEmpty {
        query = ""
      } else if !multiSelection.isEmpty {
        multiSelection = []
      } else {
        return false
      }
    case _ where dialog != nil: return false
    case #selector(NSResponder.insertTab(_:)):
      palette = palette == .filters ? nil : .filters
    case #selector(NSResponder.insertBacktab(_:)): cycleScope()
    case #selector(NSResponder.moveUp(_:)) where palette != nil: moveAction(by: -1)
    case #selector(NSResponder.moveDown(_:)) where palette != nil: moveAction(by: 1)
    case #selector(NSResponder.insertNewline(_:)) where palette != nil: runSelectedAction()
    case #selector(NSResponder.moveLeft(_:)) where palette == .actions && actionQuery.isEmpty:
      palette = nil
    // ⌥↩ 在操作面板里就是菜单上写的「粘贴为纯文本」（打开默认纯文本后是「保留格式粘贴」）；筛选面板里、以及 ⌃O 这类同选择器的非回车键一律吞掉
    // （交给字段编辑器会往过滤框插一个换行）
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
    where palette == .actions && Style.isReturnKey:
      palette = nil
      pasteSelection(plainText: !pastesPlainByDefault)
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) where palette != nil: break
    case _ where palette != nil: return false
    case #selector(NSResponder.moveRight(_:)) where caretAtEnd && selectedItem != nil:
      palette = .actions
    case #selector(NSResponder.deleteBackward(_:)) where query.isEmpty:
      return deleteBackwardOnTokens()
    case #selector(NSResponder.moveUp(_:)): move(by: -1)
    case #selector(NSResponder.moveDown(_:)): move(by: 1)
    case #selector(NSResponder.moveUpAndModifySelection(_:)): move(by: -1, extending: true)
    case #selector(NSResponder.moveDownAndModifySelection(_:)): move(by: 1, extending: true)
    case #selector(NSResponder.insertNewline(_:)): pasteSelection()
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) where Style.isReturnKey:
      pasteSelection(plainText: !pastesPlainByDefault)
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): break
    default: return false
    }
    return true
  }

  /// 搜索框的光标在最后（没有选中文字）：→ 这时才开 ⌘K，否则照常往右移光标
  private var caretAtEnd: Bool {
    guard let editor = NSApp.currentEvent?.window?.firstResponder as? NSTextView,
      editor.isFieldEditor
    else { return query.isEmpty }
    let selection = editor.selectedRange()
    return selection.length == 0 && selection.location == (editor.string as NSString).length
  }

  /// 面板收到的 ⌘ 组合键；返回 false 交还系统（搜索框里的复制、粘贴、撤销等）
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // ⌘W 在对话框开着时先关对话框（同 Esc 逐级退），不让 OverlayPanel 连面板带没保存的字一起收掉；
    // 不看 Caps Lock，和 OverlayPanel 的 ⌘W 同一套判断
    if dialog != nil, Int(event.keyCode) == kVK_ANSI_W,
      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    {
      dialog = nil
      return true
    }
    // 管理收藏夹里删掉的收藏夹：对话框开着时 ⌘Z 也撤（底栏提示就在对话框下面）
    if case .manageGroups = dialog, Int(event.keyCode) == kVK_ANSI_Z, store.canUndo,
      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    {
      undoDelete()
      return true
    }
    guard dialog == nil, modifiers == .command else { return false }
    if Int(event.keyCode) == kVK_ANSI_K {
      if palette == .actions {
        palette = nil
      } else if selectedItem != nil {
        palette = .actions
      }
      return true
    }
    if Int(event.keyCode) == kVK_ANSI_Y {
      toggleQuickLook()
      return true
    }
    palette = nil
    let fieldEditor = event.window?.firstResponder as? NSTextView
    let fieldHasSelection = (fieldEditor?.selectedRange().length ?? 0) > 0
    switch Int(event.keyCode) {
    case kVK_Return: copySelection()
    case kVK_ANSI_C where !fieldHasSelection: copySelection()
    // 焦点在放大预览的正文里（不是搜索框）时 ⌘A 是全选那段文字
    case kVK_ANSI_A where query.isEmpty && fieldEditor?.isFieldEditor != false:
      multiSelection = Set(visibleItems.map(\.id))
    case kVK_ANSI_D: toggleFavorite(targetIDs)
    case kVK_Delete, kVK_ForwardDelete: delete(targetIDs)
    case kVK_ANSI_Z where store.canUndo: undoDelete()
    case kVK_ANSI_E:
      guard let item = selectedItem, item.kind == .text, multiSelection.isEmpty else { return true }
      dialog = .edit(item.id)
    case kVK_ANSI_N: dialog = .newSnippet
    case kVK_ANSI_P: togglePinned()
    case kVK_ANSI_Comma: openSettings()
    default:
      guard let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      let items = visibleItems
      if digit < items.count { paste([items[digit]]) }
    }
    return true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]

  /// extending：⇧↑ / ⇧↓，从锚点到新位置整段选中（和系统列表一致）
  private func move(by offset: Int, extending: Bool = false) {
    let items = visibleItems
    guard !items.isEmpty else { return }
    let current = items.firstIndex { $0.id == selectedItem?.id } ?? 0
    let next =
      extending
      ? min(max(current + offset, 0), items.count - 1)
      : (current + offset + items.count) % items.count
    isBrowsing = true
    selectionMotion = Style.isKeyRepeat ? .instant : .snap
    if extending {
      if anchorID == nil || multiSelection.isEmpty { anchorID = items[current].id }
      let anchor = items.firstIndex { $0.id == anchorID } ?? current
      multiSelection = Set(items[min(anchor, next)...max(anchor, next)].map(\.id))
    } else {
      multiSelection = []
    }
    select(items[next])
  }

  // MARK: 放大预览

  /// ⌘Y：打开 / 缩回放大预览（没有选中条目时只有提示音）
  func toggleQuickLook() {
    if isQuickLooking {
      isQuickLooking = false
      closeQuickLook(true)
    } else if selectedItem != nil {
      palette = nil
      isQuickLooking = true
      openQuickLook()
    } else {
      NSSound.beep()
    }
  }

  /// 预览浮层收走了（缩回放完、点了外面、跟着面板收起）：同步状态、拆掉卡片
  func quickLookDidHide() {
    isQuickLooking = false
    showsQuickLookContent = false
  }

  private func endQuickLook() {
    guard isQuickLooking else { return }
    isQuickLooking = false
    closeQuickLook(false)
  }

  // MARK: 鼠标

  /// 单击选中（透镜滑过去），双击粘贴；⌘ 单击切换勾选，⇧ 单击从锚点选到这里。
  /// 双击以第一下选中的条目为准：第一下让透镜收放、行会位移，第二下可能落在别的行上
  func click(_ item: ClipItem) {
    let event = NSApp.currentEvent
    let modifiers = event?.modifierFlags ?? []
    isBrowsing = true
    selectionMotion = .glide
    palette = nil
    if modifiers.contains(.command) {
      if multiSelection.isEmpty, let current = selectedItem { multiSelection = [current.id] }
      multiSelection.formSymmetricDifference([item.id])
      anchorID = item.id
    } else if modifiers.contains(.shift) {
      let items = visibleItems
      guard let from = items.firstIndex(where: { $0.id == (anchorID ?? selectedItem?.id) }),
        let to = items.firstIndex(where: { $0.id == item.id })
      else { return }
      multiSelection = Set(items[min(from, to)...max(from, to)].map(\.id))
    } else if Style.isDoubleClick {
      paste([selectedItem ?? item])
      return
    } else {
      multiSelection = []
      anchorID = item.id
    }
    select(item)
  }

  // MARK: 粘贴 / 复制

  /// 操作对象：多选时是全部勾选项，否则是当前选中项
  var targetIDs: Set<UUID> {
    multiSelection.isEmpty ? Set(selectedItem.map { [$0.id] } ?? []) : multiSelection
  }

  /// 操作对象按复制先后（旧→新）：合并粘贴、依次粘贴、一起粘贴都按这个顺序（体检 B3）
  private var targets: [ClipItem] {
    let ids = targetIDs
    return visibleItems.filter { ids.contains($0.id) }.reversed()
  }

  /// 默认粘贴为纯文本（设置 › 剪贴板，体检 A5）：打开后 ↩ / 双击 / ⌘1–9 走纯文本，⌥↩ 反过来保留格式
  var pastesPlainByDefault: Bool { UserDefaults.standard.bool(forKey: Prefs.clipboardPastePlain) }

  /// ⌥↩ 的名字（⌘K、右键、底栏按住 ⌥ 的提示同一个）
  var alternatePasteTitle: String { pastesPlainByDefault ? "保留格式粘贴" : "粘贴为纯文本" }

  /// 多条怎么粘（体检 B3）：全是文本合成一段、全是文件一次粘进去、其余（含图片，或文本和文件混着）逐条
  enum PasteMode {
    case single, merged, together, sequential

    init(_ items: [ClipItem]) {
      self =
        if items.count <= 1 { .single } else if items.allSatisfy({ $0.kind == .text }) {
          .merged
        } else if items.allSatisfy({ $0.kind == .file }) { .together } else { .sequential }
    }

    /// ⌘K 首项、底栏多选按钮同一个名字
    var verb: String {
      switch self {
      case .single: "粘贴"
      case .merged: "合并粘贴"
      case .together: "一起粘贴"
      case .sequential: "依次粘贴"
      }
    }
  }

  /// plainText 为 nil 时按「默认粘贴为纯文本」；⌥↩ 传它的反面
  func pasteSelection(plainText: Bool? = nil) { paste(targets, plainText: plainText) }

  /// 全是文本：按复制先后换行合成一段（片段展开占位符）粘贴，并记成一条新历史；全是文件：一次写进全部文件、一次 ⌘V；
  /// 其余（含图片，或文本和文件混着）：按复制先后逐条粘贴，文本之间补换行，间隔 250ms（目标 App 要时间处理上一次 ⌘V）
  func paste(_ items: [ClipItem], plainText: Bool? = nil) {
    guard !items.isEmpty else { return }
    if let gone = unavailable(items) {
      island?.show("没能粘贴", detail: gone, tone: .error)
      return
    }
    let payload = payload(for: items, plainText: plainText ?? pastesPlainByDefault)
    pendingCopy = nil  // 粘贴的那条才是剪贴板里的
    guard Permissions.isAccessibilityTrusted else {
      writeClipboard(payload.writes[0])
      // 是警告不是成功；系统授权框一点，没固定的面板就收了，底栏提示会跟着丢
      island?.show(
        "已复制到剪贴板",
        detail: payload.writes.count > 1 ? "只复制了第 1 条，授权辅助功能后才能直接粘贴" : "授权辅助功能后才能直接粘贴",
        tone: .warning)
      Permissions.requestAccessibility()
      return
    }
    hidePanel()
    let writeClipboard = writeClipboard
    Task {
      for (index, write) in payload.writes.enumerated() {
        if index > 0 { try? await Task.sleep(for: .milliseconds(250)) }
        writeClipboard(write)
        _ = Paster.pasteToFrontmost(movingLeft: payload.caretMoves)
      }
    }
    remember(payload.entry)
  }

  /// ⌘C：只写剪贴板，不关面板；列表这时不动，收起面板时再把它挪到最前（合成的记一条新历史，体检 A8），
  /// 下次打开第一条就是剪贴板里的。含图片的混合多选只能写第 1 条，如实说。底栏提示；放大预览开着时底栏被它盖住，改走刘海
  func copySelection(plainText: Bool = false) {
    let items = targets
    guard !items.isEmpty else { return }
    let partial = PasteMode(items) == .sequential
    let written = partial ? [items[0]] : items
    if let gone = unavailable(written) {  // 只查真会写进去的
      island?.show("没能复制", detail: gone, tone: .error)
      return
    }
    let payload = payload(for: written, plainText: plainText)
    writeClipboard(payload.writes[0])
    pendingCopy = (payload.entry, clipboardChangeCount())
    let mode = PasteMode(items)
    if partial {
      // 没做全是警告，不带绿色对勾
      let detail = "剪贴板一次只能放一条，含图片的多选请直接粘贴"
      guard isQuickLooking, let island else {
        showToast(.warning("只复制了第 1 条"))
        return announce("只复制了第 1 条，\(detail)")
      }
      return island.show("只复制了第 1 条", detail: detail, tone: .warning)
    }
    let text = mode == .together ? "已复制 \(payload.writes[0].count) 个文件" : "已复制"
    guard isQuickLooking, let island else { return showToast(.message(text)) }
    let detail =
      switch mode {
      case .merged: "\(items.count) 条合成一段"
      case .together: Island.excerpt(items[0].title) + " 等 \(items.count) 条"
      case .single, .sequential: Island.excerpt(items[0].title)
      }
    island.show(text, detail: detail)
  }

  /// 粘贴 / 收起面板时：写进剪贴板的那条挪到最前，合成的记一条新历史（时间按现在，排在最前也按时间对得上；
  /// 菜单栏暂停记录时不记新的，D4）
  private func remember(_ entry: Payload.Entry?) {
    switch entry {
    case .existing(let id): store.bump(id)
    case .new(var item):
      guard !isRecordingPaused else { return }
      item.copiedAt = .now
      store.record(item)
    case nil: break
    }
  }

  /// 粘不出东西的条目（图片文件丢了、文件都已被移走）：写进去是空的，⌘V 会粘出剪贴板里原来的内容，
  /// 所以先拦下来说清楚。nil = 都能用
  private func unavailable(_ items: [ClipItem]) -> String? {
    for item in items {
      switch item.kind {
      case .text: continue
      case .image:
        if !FileManager.default.fileExists(atPath: store.images.url(for: item.id).path) {
          return "这张图片的文件已丢失"
        }
      case .file:
        if !(item.filePaths ?? []).contains(where: { FileManager.default.fileExists(atPath: $0) }) {
          return "文件已被移走或删除"
        }
      }
    }
    return nil
  }

  /// 在访达中显示：文件都不在了 activateFileViewerSelecting 什么也不做，要说一声
  func revealInFinder(_ item: ClipItem) {
    let urls = (item.filePaths ?? []).filter { FileManager.default.fileExists(atPath: $0) }
      .map { URL(filePath: $0) }
    guard !urls.isEmpty else {
      island?.show("文件已不存在", detail: "已被移走或删除", tone: .warning, symbol: "questionmark.folder")
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  /// 新建片段：被当前范围、筛选、搜索挡住看不见时（像没存上），用刘海说一声
  func saveSnippet(_ text: String) {
    store.saveSnippet(text)
    guard let saved = store.items.first, saved.text == text,
      !visibleItems.contains(where: { $0.id == saved.id })
    else { return }
    island?.show("已存为片段", detail: Island.excerpt(text), symbol: "text.badge.star")
  }

  /// 复制图片里识别出的文字（对标 Raycast「Copy Text from Image」、Maccy 的复制识别文字）：是新内容，记进历史
  /// （和截图识字同一个入口 Paster.write(string:record:)：过敏感文本过滤、已有同文只挪到最前）
  func copyRecognizedText(_ item: ClipItem) {
    guard let text = item.ocrText, !text.isEmpty else { return }
    Paster.write(string: text, record: true)
    showToast(.message("已复制图中文字"))
  }

  /// ⌘P / 底栏图钉：固定 = 点面板外面不收起（Esc、⌘W、再按热键照样收，mac-overlay-panel §2）。
  /// 和底栏图钉读写同一个偏好（clipboardHideOnUnfocus 为 false 即固定），底栏就地提示
  func togglePinned() {
    let defaults = UserDefaults.standard
    let pinning = defaults.bool(forKey: Prefs.clipboardHideOnUnfocus)
    defaults.set(!pinning, forKey: Prefs.clipboardHideOnUnfocus)
    let text = pinning ? "已固定" : "已取消固定"
    // 放大预览开着时底栏和图钉都被它盖住，改走刘海（岛自己会播报）；底栏提示不播报，另发一次
    guard isQuickLooking, let island else {
      showToast(.message(text))
      return announce(text)
    }
    island.show(text, symbol: pinning ? "pin.fill" : "pin")
  }

  /// 要写进剪贴板的内容（见 paste）。片段一律纯文本、展开占位符；{clipboard} 用调用时剪贴板里的那一份
  func payload(for items: [ClipItem], plainText: Bool) -> Payload {
    let clipboard = { NSPasteboard.general.string(forType: .string) }
    switch PasteMode(items) {
    case .merged:
      var merged = ClipItem(kind: .text)
      merged.text = Self.merged(items, clipboard: clipboard(), history: historyText)
      return Payload(writes: [[plainItem(merged.text ?? "")]], entry: .new(merged))
    case .together:
      // 访达复制多个文件也是一次写进多个 file URL；同一个文件只写一次
      var files = ClipItem(kind: .file)
      var seen = Set<String>()
      files.filePaths = items.flatMap { $0.filePaths ?? [] }.filter { seen.insert($0).inserted }
      return Payload(writes: [store.pasteboardItems(for: files)], entry: .new(files))
    case .single, .sequential: break
    }
    var caretMoves = 0
    let writes = items.enumerated().map { index, item in
      var write: [NSPasteboardItem]
      if item.isSnippet, let text = item.text {
        let expanded = Snippet.expand(text, clipboard: clipboard, history: historyText)
        caretMoves = items.count == 1 ? expanded.charactersAfterCursor : 0
        write = [plainItem(expanded.text)]
      } else if plainText, item.kind == .text {
        write = [plainItem(item.text ?? "")]
      } else {
        write = store.pasteboardItems(for: item)
      }
      // 逐条粘贴：文本后面补一个换行，不然几段字会粘成一行（带格式的只补纯文本那一份）
      if index < items.count - 1, item.kind == .text, let first = write.first {
        first.setString((first.string(forType: .string) ?? "") + "\n", forType: .string)
      }
      return write
    }
    return Payload(
      writes: writes, caretMoves: caretMoves, entry: items.count == 1 ? .existing(items[0].id) : nil
    )
  }

  /// 多条文本合成一段（体检 B1）：按复制先后（旧→新）换行连起来，片段展开占位符（{cursor} 只去掉、不挪光标），
  /// 所有 {clipboard} 共用调用前读的同一份
  static func merged(
    _ items: [ClipItem], clipboard: String?, history: (Int) -> String? = { _ in nil },
    now: Date = .now
  ) -> String {
    items.sorted { $0.copiedAt < $1.copiedAt }.compactMap { item in
      guard let text = item.text else { return nil }
      guard item.isSnippet else { return text }
      return Snippet.expand(text, clipboard: { clipboard }, history: history, now: now).text
    }
    .joined(separator: "\n")
  }

  /// 片段 {clipboard:N}：历史第 N 条文本（按全部历史、不看筛选，跳过图片、文件和片段：
  /// 片段是模板不是复制来的字，刚粘过的片段排在最前，不跳过的话 {clipboard:1} 会取到它自己）
  private func historyText(_ n: Int) -> String? {
    guard n > 0 else { return nil }
    return store.items.lazy.filter { $0.kind == .text && !$0.isSnippet }.dropFirst(n - 1).first?
      .text
  }

  private func plainItem(_ text: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    return item
  }

  // MARK: 编辑类操作

  /// 删除一律不确认：进撤销栈，面板收起前 ⌘Z 一批一批连着撤（收起或退出 App 时才真正删，体检 A2）。
  /// 底栏「已删除 N 条 · 撤销 ⌘Z」5 秒后淡出，⌘Z 照样有效
  func delete(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    listMotion = .settle
    store.deleteWithUndo(ids)
    multiSelection.subtract(ids)
    showUndo("已删除 \(ids.count) 条", symbol: "trash")
  }

  /// ⌘Z / 底栏「撤销」：撤最近一批，VoiceOver 播报撤了什么
  func undoDelete() {
    toastTask?.cancel()
    listMotion = .settle
    toast = nil
    switch store.undo() {
    case .deleted(let batch): announce("已恢复 \(batch.count) 条")
    case .group(let group, _, _): announce("已恢复收藏夹「\(group.name)」")
    case .unretained(let items): announce("已撤销，\(items.count) 条不会被清理")
    case nil: break
    }
  }

  /// ⌘D / 收藏按钮：取消收藏同时移出收藏夹，备注不动（体检 A1 A3）
  func toggleFavorite(_ ids: Set<UUID>) {
    warnExpiring(store.toggleFavorite(ids))
  }

  /// 移出片段（体检 C1）：收藏、收藏夹、备注都不动
  func removeFromSnippets(_ ids: Set<UUID>) {
    warnExpiring(store.removeFromSnippets(ids))
  }

  /// 取消收藏 / 移出片段后已超过保留天数的条目：说一声收起面板后会被清理（⌘Z 改回来）
  private func warnExpiring(_ count: Int) {
    guard count > 0 else { return }
    showUndo("超过 \(ClipboardStore.Limits.days) 天，收起面板后会被清理", symbol: "clock")
  }

  /// 能撤销的操作的提示：底栏「… · 撤销 ⌘Z」5 秒；放大预览开着时底栏被它盖住，改走刘海（岛自己会播报），
  /// 否则另发一次播报（底栏提示不朗读）
  private func showUndo(_ text: String, symbol: String) {
    showToast(.undo(text), seconds: 5)
    if isQuickLooking, let island {
      island.show(text, detail: "⌘Z 撤销", tone: .info, symbol: symbol)
    } else {
      announce("\(text)，⌘Z 撤销")
    }
  }

  /// 删除收藏夹（管理收藏夹里）：里面的条目留在默认收藏，不确认，⌘Z 连归属一起回来
  func deleteGroup(_ group: ClipGroup) {
    store.deleteGroup(group.id)
    if groupFilter == .group(group.id) { groupFilter = .all }
    showUndo("已删除收藏夹「\(group.name)」", symbol: "folder.badge.minus")
  }

  func edit(_ id: UUID, text: String) {
    formCache[id] = nil
    store.update([id]) { $0.text = text }
  }

  /// 移到收藏夹（就是收藏）；group 为 nil = 移出收藏夹，留在默认收藏
  func assign(_ ids: Set<UUID>, to group: UUID?) {
    store.assign(ids, to: group)
  }

  func translate(_ item: ClipItem) {
    guard let text = item.text ?? item.ocrText, !text.isEmpty else { return }
    openTranslate(text)
  }

  func showToast(_ toast: Toast, seconds: Double = 1.6) {
    toastTask?.cancel()
    self.toast = toast
    // 到期只让提示淡出；删掉的在面板收起时才提交（⌘Z 一直有效）
    toastTask = Task {
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self.toast = nil
    }
  }

  // MARK: ⌘K 操作面板

  /// 当前条目（或多选）能做的全部操作，按常用程度排
  var actions: [ActionMenu.Item] {
    guard let item = selectedItem else { return [] }
    // 有勾选就只给批量操作：单条操作对着预览的那条，批量操作对着勾选的，混在一起会弄错对象
    let many = !multiSelection.isEmpty
    let targets = self.targets
    var actions = [
      ActionMenu.Item(
        title: PasteMode(targets).verb, symbol: "arrow.turn.down.left", shortcut: "↩"
      ) {
        [unowned self] in pasteSelection()
      }
    ]
    if item.kind == .text || many {
      let plain = !pastesPlainByDefault
      actions.append(
        ActionMenu.Item(
          title: alternatePasteTitle, symbol: plain ? "doc.plaintext" : "textformat",
          shortcut: "⌥↩"
        ) { [unowned self] in pasteSelection(plainText: plain) })
    }
    actions.append(
      ActionMenu.Item(title: "仅复制", symbol: "doc.on.doc", shortcut: "⌘↩") { [unowned self] in
        copySelection()
      })
    if item.kind == .text || many {
      actions.append(
        ActionMenu.Item(title: "复制为纯文本", symbol: "doc.on.clipboard") { [unowned self] in
          copySelection(plainText: true)
        })
    }
    if !many, item.kind == .image, !(item.ocrText ?? "").isEmpty {
      actions.append(
        ActionMenu.Item(title: "复制图中文字", symbol: "text.viewfinder") { [unowned self] in
          copyRecognizedText(item)
        })
    }
    let favorite = targets.allSatisfy(\.favorite)
    actions.append(
      ActionMenu.Item(
        title: favorite ? "取消收藏" : "收藏", symbol: favorite ? "star.slash" : "star", shortcut: "⌘D"
      ) {
        [unowned self] in toggleFavorite(targetIDs)
      })
    if !many, item.kind == .text || !(item.ocrText ?? "").isEmpty {
      actions.append(
        ActionMenu.Item(title: "翻译", symbol: "character.bubble") { [unowned self] in
          translate(item)
        })
    }
    if !many, let link = firstLink(of: item) {
      actions.append(
        ActionMenu.Item(title: "打开链接", symbol: "safari") { NSWorkspace.shared.open(link) })
    }
    if !many, item.kind == .text {
      actions.append(
        ActionMenu.Item(title: "编辑内容…", symbol: "pencil", shortcut: "⌘E") { [unowned self] in
          dialog = .edit(item.id)
        })
      if !item.isSnippet {
        actions.append(
          ActionMenu.Item(title: "存为片段", symbol: "text.badge.star") { [unowned self] in
            store.update([item.id]) { $0.isSnippet = true }
          })
      }
    }
    // 移出片段（体检 C1）：多选时有片段就给
    let snippets = Set(targets.filter(\.isSnippet).map(\.id))
    if !snippets.isEmpty {
      actions.append(
        ActionMenu.Item(title: "移出片段", symbol: "text.badge.minus") { [unowned self] in
          removeFromSnippets(snippets)
        })
    }
    // 备注：所有条目都能写（体检 A3）
    if !many {
      actions.append(
        ActionMenu.Item(title: "备注…", symbol: "note.text") { [unowned self] in
          dialog = .note(item.id)
        })
    }
    if !many, contentForm(of: item) == .json {
      actions.append(
        ActionMenu.Item(title: prettyJSON ? "显示原文" : "美化 JSON", symbol: "curlybraces") {
          [unowned self] in prettyJSON.toggle()
        })
    }
    if !many {
      actions.append(
        ActionMenu.Item(title: "放大预览", symbol: "eye", shortcut: "⌘Y") { [unowned self] in
          toggleQuickLook()
        })
    }
    if !many, item.kind == .file {
      actions.append(
        ActionMenu.Item(title: "在访达中显示", symbol: "folder") { [unowned self] in
          revealInFinder(item)
        })
    }
    // 收藏夹（和右键菜单、多选底栏一样全，按拖动排的顺序）：移到已有收藏夹（都已在里面的那个不列）、移出收藏夹（留在默认收藏）、
    // 放进新收藏夹。二级列表在第 3 批（C3）做
    for group in store.groups where !targets.allSatisfy({ $0.groupID == group.id }) {
      actions.append(
        ActionMenu.Item(
          title: "移到「\(group.name)」", symbol: "folder", detail: "收藏夹", id: "group.\(group.id)"
        ) { [unowned self] in assign(targetIDs, to: group.id) })
    }
    if targets.contains(where: { $0.groupID != nil }) {
      actions.append(
        ActionMenu.Item(title: "移出收藏夹", symbol: "folder.badge.minus", detail: "收藏夹") {
          [unowned self] in assign(targetIDs, to: nil)
        })
    }
    actions.append(
      ActionMenu.Item(title: "放进新收藏夹…", symbol: "folder.badge.plus", detail: "收藏夹") {
        [unowned self] in dialog = .newGroup(targetIDs)
      })
    actions.append(
      ActionMenu.Item(title: "删除", symbol: "trash", shortcut: "⌘⌫") { [unowned self] in
        delete(targetIDs)
      })
    return actions
  }

  private func firstLink(of item: ClipItem) -> URL? {
    if let linkCache, linkCache.id == item.id { return linkCache.url }
    let url = item.kind == .text ? ContentForm.firstLink(in: item.text ?? "") : nil
    linkCache = (item.id, url)
    return url
  }

  // MARK: 筛选面板

  /// Tab 筛选面板的条目：收藏、各个收藏夹（紧跟在「收藏」下面，按拖动排的顺序）、片段、类型、形态、来源（按条数多→少），
  /// 最后「管理收藏夹…」。已生效的项打勾，再选一次取消；选完生成标签并关面板（run 里关）
  var filterItems: [ActionMenu.Item] {
    func scopeItem(_ scope: Scope) -> ActionMenu.Item {
      ActionMenu.Item(
        title: scope.title, symbol: scope.symbol, detail: "范围", isChecked: self.scope == scope,
        id: "scope.\(scope.rawValue)"
      ) { [unowned self] in self.scope = self.scope == scope ? .all : scope }
    }
    var items = [scopeItem(.favorites)]
    var groupCounts: [UUID: Int] = [:]
    for item in store.items { if let id = item.groupID { groupCounts[id, default: 0] += 1 } }
    for group in store.groups {
      let isOn = groupFilter == .group(group.id)
      items.append(
        ActionMenu.Item(
          title: group.name, symbol: "folder", detail: "收藏夹 \(groupCounts[group.id] ?? 0)",
          isChecked: isOn, id: "group.\(group.id)"
        ) { [unowned self] in groupFilter = isOn ? .all : .group(group.id) })
    }
    items.append(scopeItem(.snippets))
    for kind in [ClipItem.Kind.text, .image, .file] {
      let isOn = self.kind == kind && form == nil
      items.append(
        ActionMenu.Item(
          title: kind.title, symbol: kind.symbol, detail: "类型", isChecked: isOn,
          id: "kind.\(kind.rawValue)"
        ) { [unowned self] in
          form = nil
          self.kind = isOn ? nil : kind
        })
    }
    for form in ContentForm.allCases {
      let isOn = self.form == form
      items.append(
        ActionMenu.Item(
          title: form.title, symbol: form.symbol, detail: "形态", isChecked: isOn,
          id: "form.\(form.rawValue)"
        ) { [unowned self] in
          self.form = isOn ? nil : form
          if isOn { kind = nil }
        })
    }
    for source in sources {
      let isOn = sourceBundleID == source.bundleID
      items.append(
        ActionMenu.Item(
          title: source.name, symbol: "app", image: AppIcons.icon(for: source.bundleID),
          detail: "来源 \(source.count)", isChecked: isOn, id: "source.\(source.bundleID)"
        ) { [unowned self] in sourceBundleID = isOn ? nil : source.bundleID })
    }
    items.append(
      ActionMenu.Item(title: "管理收藏夹…", symbol: "folder.badge.gearshape", id: "manage") {
        [unowned self] in dialog = .manageGroups
      })
    return items
  }

  /// 开着的菜单的条目，按 actionQuery 过滤（标题或说明包含，不分大小写：输「来源」列出全部来源）
  var filteredActions: [ActionMenu.Item] {
    let all = palette == .filters ? filterItems : actions
    let query = actionQuery.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return all }
    return all.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private func moveAction(by offset: Int) {
    let count = filteredActions.count
    guard count > 0 else { return }
    actionSelection = (actionSelection + offset + count) % count
  }

  func runSelectedAction() {
    let actions = filteredActions
    guard actions.indices.contains(actionSelection) else { return NSSound.beep() }
    run(actions[actionSelection])
  }

  func run(_ action: ActionMenu.Item) {
    palette = nil
    action.run()
  }

  // MARK: 显示 / 隐藏

  /// 每次隐藏都复位：搜索、筛选标签（含待删）、浮起的菜单、多选、对话框，选中项回到第一条；没撤销的删除落库，
  /// ⌘C 复制过的挪到最前
  func reset() {
    endQuickLook()
    toastTask?.cancel()
    store.commitDeletion()
    if let pendingCopy, pendingCopy.changeCount == clipboardChangeCount() {
      remember(pendingCopy.entry)
    }
    pendingCopy = nil
    query = ""
    scope = .all
    kind = nil
    form = nil
    sourceBundleID = nil
    groupFilter = .all
    multiSelection = []
    dialog = nil
    toast = nil
    palette = nil
    armsLastToken = false
    isBrowsing = false
    selectedID = nil
    anchorID = nil
    prettyJSON = false
  }

  /// 筛选 / 搜索变了：回到第一条
  private func restartBrowsing() {
    isBrowsing = false
    selectedID = nil
    prettyJSON = false
    selectionMotion = .instant
    listMotion = .instant
    listGeneration += 1
  }

  /// 换列表那一帧画完了：之后的增删（新复制、删除、撤销）照常动画
  func settleList() { listMotion = .settle }

  /// 新条目进来：用户没在浏览就让选中回到第一条
  func itemsChanged() {
    listMotion = .settle
    if !isBrowsing {
      selectionMotion = .instant
      selectedID = nil
    }
    if let sourceBundleID, !store.items.contains(where: { $0.sourceBundleID == sourceBundleID }) {
      self.sourceBundleID = nil
    }
  }
}
