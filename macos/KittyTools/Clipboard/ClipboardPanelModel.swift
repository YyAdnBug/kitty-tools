// 剪贴板面板（透镜指令条 Lens Bar，mac-clipboard §4）的界面状态与操作：筛选标签、选中 / 多选、键盘命令、
// 粘贴 / 复制 / 删除撤销、筛选面板与 ⌘K 操作面板。视图只负责画。
// 焦点始终在搜索框：方向键 / 回车 / Tab / ⇧Tab / ← → / ⌫ / Esc 从搜索框的 doCommandBy 进来，⌘ 组合键从面板的
// performKeyEquivalent 进来（handleKeyEquivalent）。交互按 macOS 习惯设计：
// 单击选中（透镜滑过去）、双击或 ↩ 粘贴（设置里打开「单击条目直接粘贴」后点一下就粘贴）、⌥↩ 纯文本（打开「默认粘贴为纯文本」后反过来）、⌘↩ 仅复制、⌘1–9 直接粘贴第 N 条、
// 删除不确认、⌘Z 连着撤（面板收起时才真正删）；
// 范围和筛选只以搜索框里的标签出现：Tab 开关筛选面板、⇧Tab 循环范围、⌫（搜索为空）先选中最后一个标签再删；
// ⌘K 或 →（光标在末尾）打开操作面板，← 关掉；两个面板开着时搜索框用来过滤条目，↑↓ ↩ 选择执行，Esc 关掉；
// ⌘K 里「移到收藏夹 ›」→ / ↩ 进子列表、← / Esc 回来；右键菜单和 ⌘K 是同一份动作表（actions(for:targets:)）；
// ⌘Y 放大预览（QuickLookView，单独的浮层，不抢键盘：↑↓ 照样在这里换条目）。
// 按类型的动作：⌘T 翻译、⌘O 打开链接 / 文件、⌘R 在访达中显示、⌥⌘C 复制路径、图片钉到屏幕；行能拖到别的 App（dragItems）。

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

  /// 面板里浮起的菜单（都是 Shell/ActionMenu）：Tab 的筛选面板、⌘K 的操作面板、多选底栏「收藏夹…」的收藏夹列表
  enum Palette { case filters, actions, groups }

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
  /// 钉到屏幕（AppDelegate 接 PinBoard.pin，单测里什么都不做）：图、点尺寸的全局 frame
  @ObservationIgnored var pinImage: (CGImage, CGRect) -> Void = { _, _ in }
  /// 屏幕上已有钉图的位置（AppDelegate 接 PinBoard 的钉图，单测里是空的）：钉的时候让开它们
  @ObservationIgnored var pinnedFrames: () -> [CGRect] = { [] }
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
  /// 勾选清空（底栏取消 / 删除、Esc、裁掉看不见的）时，底栏「收藏夹…」的列表跟着关：按钮没了，列表别改去对着单条选中项
  var multiSelection: Set<UUID> = [] {
    didSet { if multiSelection.isEmpty, palette == .groups { palette = nil } }
  }
  var dialog: Dialog? { didSet { if dialog != nil { endQuickLook() } } }
  /// ⌘Y 放大预览开着
  private(set) var isQuickLooking = false
  /// 放大预览的浮层上画不画卡片：打开前设上，浮层真正收走（缩回动画放完）才清掉。
  /// 收走的浮层里别再画：SwiftUI 在看不见的窗口里照样跟着选中重建卡片（Quick Look 视图、2400 px 大图）
  var showsQuickLookContent = false
  /// 底栏左边的提示（BarNotice：undo 是已删除 N 条、已删除收藏夹、取消收藏后会被清理）
  var toast: BarNotice?
  /// 菜单栏「暂停记录剪贴板」开着（AppDelegate 跟 ClipboardWatcher.isUserPaused 一起设）：底栏条数前写「已暂停记录」
  var isRecordingPaused = false
  /// 开着的浮起菜单：搜索框这时改成过滤它的条目（actionQuery），↑↓ ↩ 选择执行
  var palette: Palette? {
    didSet {
      guard palette != oldValue else { return }
      actionQuery = ""
      actionSelection = 0
      actionSubmenu = nil
      armsLastToken = false
      if palette != nil { endQuickLook() }  // 菜单在剪贴板面板里，被预览挡着
    }
  }
  /// ⌘K 里进了哪一行的子列表（ActionMenu.Item.id，「移到收藏夹」）；nil = 在第一级
  private(set) var actionSubmenu: String?
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
  /// 条目里的第一个链接（⌘K / 右键「打开链接」；按条目缓存，右键菜单每画一行都要问，别每次都跑 NSDataDetector）。
  /// 编辑正文时清掉那一条（体检 B18）
  @ObservationIgnored private var linkCache: [UUID: URL?] = [:]
  /// 透镜和放大预览里的 JSON 默认美化（体检 A10）：一次呼出里点过「原文」就一直看原文，收起面板（reset）才复位
  var prettyJSON = true
  /// 美化后的 JSON（按条目缓存：透镜每次重画都要，别每次解析最多 10 万字）；编辑正文时清掉那一条、收起面板时清空
  @ObservationIgnored private var prettyCache: [UUID: String] = [:]

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
    let found = store.search(query)
    // 范围是「全部」、没有筛选时就是搜索结果，不再逐条判断（每次按键要取好几次，800 条一次约 1 ms）
    guard
      scope != .all || kind != nil || form != nil || sourceBundleID != nil || groupFilter != .all
    else { return found }
    return found.filter { item in
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

  /// 透镜和放大预览里的正文：JSON 按开关美化（结果按条目缓存）。ponytail: 超长文本只预览前 10 万字，粘贴仍是全文
  func displayText(of item: ClipItem) -> String {
    let text = String((item.text ?? "").prefix(100_000))
    guard prettyJSON, contentForm(of: item) == .json else { return text }
    if let cached = prettyCache[item.id] { return cached }
    var pretty = text
    if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    {
      pretty = String(decoding: data, as: UTF8.self)
    }
    prettyCache[item.id] = pretty
    return pretty
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
      Island.announce("再按一次删除键，移除筛选：\(last.title)")
    }
    return true
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
  }

  // MARK: 键盘

  /// 搜索框转来的编辑命令（mac-clipboard §4）：↑↓ 移动（带 ⇧ 扩展多选）、↩ 粘贴、⌥↩ 纯文本粘贴、
  /// Tab 开关筛选面板、⇧Tab 循环范围、→（光标在末尾）开 ⌘K / 进子列表、←（过滤词为空）回上一级 / 关菜单、⌫（搜索为空）删标签；
  /// Esc 依次：缩回放大预览 → 回上一级菜单 → 关浮起的菜单 → 关对话框 → 取消标签待删 → 清空搜索词 → 取消多选 → 交给面板关闭。
  /// 条件不满足的返回 false，交还字段编辑器照常处理（移光标、删字）
  func handleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      if isQuickLooking {
        toggleQuickLook()
      } else if actionSubmenu != nil {
        leaveSubmenu()
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
    // → 进子列表（「移到收藏夹 ›」，光标在过滤词末尾时）；← 在过滤词为空时回上一级，第一级就关菜单
    case #selector(NSResponder.moveRight(_:))
    where palette == .actions && caretAtEnd && selectedAction?.submenu != nil:
      runSelectedAction()
    case #selector(NSResponder.moveLeft(_:))
    where (palette == .actions || palette == .groups) && actionQuery.isEmpty:
      if actionSubmenu != nil { leaveSubmenu() } else { palette = nil }
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

  /// 搜索框的光标在最后（没有选中文字）：→ 这时才开 ⌘K / 进子列表，否则照常往右移光标
  private var caretAtEnd: Bool {
    guard let editor = NSApp.currentEvent?.window?.firstResponder as? NSTextView,
      editor.isFieldEditor
    else { return (palette != nil ? actionQuery : query).isEmpty }
    let selection = editor.selectedRange()
    return selection.length == 0 && selection.location == (editor.string as NSString).length
  }

  /// 面板收到的 ⌘ / ⌥⌘ 组合键；返回 false 交还系统（搜索框、过滤框里的复制、粘贴、撤销等）。
  /// 做了才收起浮起的菜单：没做的（过滤框里的复制、粘贴）菜单留着（同启动器，体检 B10）
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    // 不看大写锁定和 fn（⌘⌦ 带 fn），和 OverlayPanel 的 ⌘W 同一套判断
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = Int(event.keyCode)
    // ⌘W 在对话框开着时先关对话框（同 Esc 逐级退），不让 OverlayPanel 连面板带没保存的字一起收掉
    if dialog != nil, key == kVK_ANSI_W, modifiers == .command {
      dialog = nil
      return true
    }
    // 管理收藏夹里删掉的收藏夹：对话框开着时 ⌘Z 也撤（底栏提示就在对话框下面）
    if case .manageGroups = dialog, key == kVK_ANSI_Z, store.canUndo, modifiers == .command {
      undoDelete()
      return true
    }
    guard dialog == nil else { return false }
    if modifiers == [.command, .option] {
      // ⌥⌘C 复制路径（访达同键）：全是文件时才有
      guard key == kVK_ANSI_C, let items = pathTargets else { return false }
      palette = nil
      copyPaths(items)
      return true
    }
    guard modifiers == .command else { return false }
    if key == kVK_ANSI_K {
      if palette == .actions {
        palette = nil
      } else if selectedItem != nil {
        palette = .actions
      }
      return true
    }
    if key == kVK_ANSI_Y {
      toggleQuickLook()
      return true
    }
    // 过滤框里有字：删到行首、全选、粘贴、剪切、撤销都是改过滤词，交给它，菜单留着
    if palette != nil, !actionQuery.isEmpty,
      [kVK_Delete, kVK_ForwardDelete, kVK_ANSI_A, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z].contains(key)
    {
      return false
    }
    let handled = handleCommandKey(event)
    if handled { palette = nil }
    return handled
  }

  private func handleCommandKey(_ event: NSEvent) -> Bool {
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
      guard let single = singleTarget, single.kind == .text else { return true }
      dialog = .edit(single.id)
    case kVK_ANSI_N: dialog = .newSnippet
    case kVK_ANSI_P: togglePinned()
    case kVK_ANSI_Comma: openSettings()
    // 按类型的动作（体检 B14 D2）：不适用时提示音
    case kVK_ANSI_T:
      guard let single = singleTarget, canTranslate(single) else { return beep() }
      translate(single)
    case kVK_ANSI_O:
      guard let single = singleTarget else { return beep() }
      if single.kind == .file {
        openFiles(single)
      } else if let link = firstLink(of: single) {
        openLink(link)
      } else {
        return beep()
      }
    case kVK_ANSI_R:
      guard let single = singleTarget, single.kind == .file else { return beep() }
      revealInFinder(single)
    default:
      guard let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      let items = visibleItems
      if digit < items.count { paste([items[digit]]) }
    }
    return true
  }

  /// 按了当前条目用不了的快捷键：提示音，键算处理过（别落到过滤框 / 搜索框里）
  private func beep() -> Bool {
    NSSound.beep()
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
    // 选中项先取出来：写进 firstIndex 的闭包里的话每比一条都重新搜索、过滤整个列表（选中第 700 条时按一下 300 ms）
    let selectedID = selectedItem(in: items)?.id
    let current = items.firstIndex { $0.id == selectedID } ?? 0
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
      // 大卡开着时新条目进来（大卡里 ⌘C 复制了一段）选中不跳：大卡跟着选中走，会当场换成刚复制的那段（体检 B11）
      isBrowsing = true
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

  /// 鼠标点一行做什么
  enum Click { case check, range, paste, select }

  /// 纯函数（单测）：⌘ 单击切换勾选、⇧ 单击从锚点选一段，都不看开关；其余的平时双击才粘贴，打开「单击条目直接粘贴」后
  /// 点一下就粘贴。clicks 是鼠标的连击数（Style.clickCount）：旁白激活这一行时是 0，照旧只选中（粘贴在它的动作列表里）
  static func click(modifiers: NSEvent.ModifierFlags, clicks: Int, pastesOnClick: Bool) -> Click {
    if modifiers.contains(.command) { return .check }
    if modifiers.contains(.shift) { return .range }
    return clicks >= (pastesOnClick ? 1 : 2) ? .paste : .select
  }

  /// 单击条目直接粘贴（设置 › 剪贴板「面板」，默认关）
  var pastesOnClick: Bool { UserDefaults.standard.bool(forKey: Prefs.clipboardPasteOnClick) }

  /// 单击选中（透镜滑过去），双击粘贴；⌘ 单击切换勾选，⇧ 单击从锚点选到这里。
  /// 双击以第一下选中的条目为准：第一下让透镜收放、行会位移，第二下可能落在别的行上。
  /// 打开「单击条目直接粘贴」后没有第一下，粘贴的就是点中的这条
  func click(_ item: ClipItem) {
    let closesMenu = palette != nil
    isBrowsing = true
    selectionMotion = .glide
    palette = nil
    switch Self.click(
      modifiers: NSApp.currentEvent?.modifierFlags ?? [], clicks: Style.clickCount,
      pastesOnClick: pastesOnClick)
    {
    case .check:
      if multiSelection.isEmpty, let current = selectedItem { multiSelection = [current.id] }
      multiSelection.formSymmetricDifference([item.id])
      anchorID = item.id
    case .range:
      let items = visibleItems
      let anchor = anchorID ?? selectedItem(in: items)?.id
      guard let from = items.firstIndex(where: { $0.id == anchor }),
        let to = items.firstIndex(where: { $0.id == item.id })
      else { return }
      multiSelection = Set(items[min(from, to)...max(from, to)].map(\.id))
    case .paste:
      // 单击直接粘贴时，筛选面板 / ⌘K 开着的那一下只关菜单（同系统菜单：点外面不顺带执行别的）
      if pastesOnClick, closesMenu { return }
      paste([pastesOnClick ? item : selectedItem ?? item])
      return
    case .select:
      multiSelection = []
      anchorID = item.id
    }
    select(item)
  }

  // MARK: 粘贴 / 复制

  /// 操作对象，按复制先后（旧→新：合并粘贴、依次粘贴、一起粘贴都按这个顺序，体检 B3）：多选时是勾选项里现在看得见的
  /// （搜索、筛选换了列表后看不见的不算，体检 B8），否则是当前选中项。底栏计数、⌘D / ⌘⌫ / 收藏夹 / 粘贴都走它
  var targets: [ClipItem] { targets(in: visibleItems) }

  /// 列表已经算好时用它，省一次搜索
  func targets(in items: [ClipItem]) -> [ClipItem] {
    guard !multiSelection.isEmpty else { return selectedItem(in: items).map { [$0] } ?? [] }
    return items.filter { multiSelection.contains($0.id) }.reversed()
  }

  var targetIDs: Set<UUID> { Set(targets.map(\.id)) }

  /// 单条操作（⌘E ⌘T ⌘O ⌘R）的对象：操作对象只有一条时就是它（没有勾选时的选中项，或唯一的勾选项）
  private var singleTarget: ClipItem? {
    let targets = targets
    return targets.count == 1 ? targets[0] : nil
  }

  /// ⌥⌘C 复制路径的对象：全是文件时才有
  private var pathTargets: [ClipItem]? {
    let targets = targets
    return !targets.isEmpty && targets.allSatisfy { $0.kind == .file } ? targets : nil
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

  /// ⌘C / ⌘↩：复制操作对象
  func copySelection(plainText: Bool = false) { copy(targets, plainText: plainText) }

  /// 只写剪贴板，不关面板；列表这时不动，收起面板时再把它挪到最前（合成的记一条新历史，体检 A8），
  /// 下次打开第一条就是剪贴板里的。含图片的混合多选只能写第 1 条，如实说。底栏提示；放大预览开着时底栏被它盖住，改走刘海。
  /// 右键菜单、⌘Y 页脚的「复制」传被点的那一条，不管勾选了什么（体检 B9）
  func copy(_ items: [ClipItem], plainText: Bool = false) {
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
        return showToast(.warning("只复制了第 1 条"), spoken: "只复制了第 1 条，\(detail)")
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

  /// 固定着（点外面不收起）：打开链接 / 文件、在访达中显示、钉到屏幕之后面板留着
  var isPinned: Bool { !UserDefaults.standard.bool(forKey: Prefs.clipboardHideOnUnfocus) }

  /// 条目里还在的文件（都不在了要说一声：activateFileViewerSelecting / open 什么也不做）
  private func existingFiles(_ item: ClipItem) -> [URL]? {
    let urls = (item.filePaths ?? []).filter { FileManager.default.fileExists(atPath: $0) }
      .map { URL(filePath: $0) }
    guard urls.isEmpty else { return urls }
    island?.show("文件已不存在", detail: "已被移走或删除", tone: .warning, symbol: "questionmark.folder")
    return nil
  }

  /// 在访达中显示（⌘R）：没固定就先收起面板（不然盖在访达窗口上，体检 B13）
  func revealInFinder(_ item: ClipItem) {
    guard let urls = existingFiles(item) else { return }
    if !isPinned { hidePanel() }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  /// 打开链接（⌘O）
  func openLink(_ url: URL) { openInBackground([url], failure: "打不开这个链接") }

  /// 打开文件（⌘O，默认 App）：条目里还在的每个文件
  func openFiles(_ item: ClipItem) {
    guard let urls = existingFiles(item) else { return }
    openInBackground(urls, failure: "打不开这个文件")
  }

  /// 没固定就先收起，再交给系统在后台打开（同步的 NSWorkspace.open 要等 App 启动完才返回，面板一直挂着、界面卡住；
  /// 同启动器，体检 B13）；打不开时面板多半已收起，用刘海岛说
  private func openInBackground(_ urls: [URL], failure: String) {
    if !isPinned { hidePanel() }
    for url in urls {
      NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) {
        [weak self] _, error in
        guard let error else { return }
        Task { @MainActor in
          self?.island?.show(failure, detail: error.localizedDescription, tone: .error)
        }
      }
    }
  }

  /// ⌥⌘C 复制路径（体检 D2）：多个按换行拼。是新文字，但面板开着时列表不动：同 ⌘C，收起面板时才记成一条新历史
  func copyPaths(_ items: [ClipItem]) {
    let text = items.flatMap { $0.filePaths ?? [] }.joined(separator: "\n")
    guard !text.isEmpty else { return }
    var entry = ClipItem(kind: .text)
    entry.text = text
    writeClipboard([plainItem(text)])
    pendingCopy = (.new(entry), clipboardChangeCount())
    guard isQuickLooking, let island else { return showToast(.message("已复制路径")) }
    island.show("已复制路径", detail: Island.excerpt(text))
  }

  /// ⌘Y 大卡里选中文字按 ⌘C（体检 B11）：只拷纯文本（不带语法着色、搜索词黄底、放大的字号），经 Paster.write 写
  /// （watcher 跳过：来源不会记成前台的别的 App，也不触发复制即译），记成一条无来源的新条目（同「复制图中文字」）；
  /// 大卡开着时选中不跳（toggleQuickLook 置了 isBrowsing），底栏被大卡挡住，走岛
  func copySelectedText(_ text: String) {
    guard !text.isEmpty else { return }
    Paster.write(string: text, record: true)
    guard let island else { return showToast(.message("已复制")) }
    island.show("已复制", detail: Island.excerpt(text))
  }

  /// 钉到屏幕（体检 D1）：按像素 ÷ 鼠标所在屏的 backingScaleFactor 得点尺寸，超过可见区 80% 等比缩小，
  /// 钉在可见区中央；面板没固定就先收起。让开屏幕上已有的钉图（PinBoard.clipboardFrame：从中央往右下找第一个空格，
  /// 同「钉住剪贴板里的图」）：同一张钉两次、多选的几张都依次错开，不叠在一起。整张解码在后台（缩略图接口按原尺寸取）
  func pin(_ items: [ClipItem]) {
    let images = items.filter { $0.kind == .image }
    guard !images.isEmpty else { return }
    if let gone = unavailable(images) {
      island?.show("没能钉到屏幕", detail: gone, tone: .error)
      return
    }
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    else { return }
    let (scale, visible) = (screen.backingScaleFactor, screen.visibleFrame)
    if !isPinned { hidePanel() }
    let files = store.images
    let (pinImage, pinnedFrames) = (pinImage, pinnedFrames)
    Task {
      // 一张一张钉：前一张钉上了才算下一张的位置，多选的几张也互相让开
      for item in images {
        guard let info = item.image,
          let image = await files.thumbnail(for: item.id, maxPixel: max(info.width, info.height))
        else { continue }
        pinImage(
          image,
          PinBoard.clipboardFrame(
            pixels: CGSize(width: image.width, height: image.height), scale: scale,
            visible: visible, pinned: pinnedFrames()))
      }
    }
  }

  /// 钉图的位置（纯函数，配单测）：点尺寸 = 像素 ÷ scale，超过可见区 80% 等比缩小，放在可见区中央；
  /// 第 index 张往右下错开 24 × index pt
  static func pinFrame(pixels: CGSize, scale: CGFloat, visible: CGRect, index: Int) -> CGRect {
    let size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
    let fit = min(1, visible.width * 0.8 / size.width, visible.height * 0.8 / size.height)
    let width = (size.width * fit).rounded()
    let height = (size.height * fit).rounded()
    let offset = CGFloat(index) * 24
    return CGRect(
      x: (visible.midX - width / 2 + offset).rounded(),
      y: (visible.midY - height / 2 - offset).rounded(), width: width, height: height)
  }

  /// 新建片段（名称存成备注，搜索时能搜到；体检 C2）：被当前范围、筛选、搜索挡住看不见时（像没存上），用刘海说一声
  func saveSnippet(_ text: String, name: String = "") {
    store.saveSnippet(text)
    guard let saved = store.items.first, saved.text == text else { return }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { store.update([saved.id]) { $0.note = name } }
    guard !visibleItems.contains(where: { $0.id == saved.id }) else { return }
    island?.show("已存为片段", detail: Island.excerpt(text), symbol: "text.badge.star")
  }

  /// 复制图片里识别出的文字（对标 Raycast「Copy Text from Image」、Maccy 的复制识别文字）：是新内容，记进历史
  /// （和截图识字同一个入口 Paster.write(string:record:)：过敏感文本过滤、已有同文只挪到最前）
  func copyRecognizedText(_ item: ClipItem) {
    guard let text = item.ocrText, !text.isEmpty else { return }
    Paster.write(string: text, record: true)
    // 放大预览开着时底栏被它盖住，走岛（同 ⌘C）
    guard isQuickLooking, let island else { return showToast(.message("已复制图中文字")) }
    island.show("已复制图中文字", detail: Island.excerpt(text))
  }

  /// ⌘P / 底栏图钉：固定 = 点面板外面不收起（Esc、⌘W、再按热键照样收，mac-overlay-panel §2）。
  /// 和底栏图钉读写同一个偏好（clipboardHideOnUnfocus 为 false 即固定），底栏就地提示
  func togglePinned() {
    let defaults = UserDefaults.standard
    let pinning = defaults.bool(forKey: Prefs.clipboardHideOnUnfocus)
    defaults.set(!pinning, forKey: Prefs.clipboardHideOnUnfocus)
    let text = pinning ? "已固定" : "已取消固定"
    // 放大预览开着时底栏和图钉都被它盖住，改走刘海（岛自己会播报）
    guard isQuickLooking, let island else { return showToast(.message(text)) }
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

  /// 改会让条目从当前列表消失的数据（删除、「收藏」范围里取消收藏、收藏夹筛选里移走、片段范围里移出片段）：
  /// 选中的那条消失了就挪到最后一个消失项之后第一条留下的，没有就取之前最近的一条（照翻译历史 moveSelection(awayFrom:)；
  /// 不这样会跳回第一条，连按 ⌘⌫ 删错，体检 B7）；勾选只留还看得见的，一条不剩就退出多选（体检 B8）
  private func changingList(_ change: () -> Void) {
    let before = visibleItems
    let selected = selectedItem(in: before)
    change()
    let after = Set(visibleItems.map(\.id))
    if !multiSelection.isEmpty { multiSelection.formIntersection(after) }
    guard let selected, !after.contains(selected.id),
      let last = before.lastIndex(where: { !after.contains($0.id) })
    else { return }
    let next =
      before[last...].first { after.contains($0.id) }
      ?? before[..<last].last { after.contains($0.id) }
    selectedID = next?.id
    selectionMotion = .snap
    isBrowsing = true
  }

  /// 删除一律不确认：进撤销栈，面板收起前 ⌘Z 一批一批连着撤（收起或退出 App 时才真正删，体检 A2）。
  /// 底栏「已删除 N 条 · 撤销 ⌘Z」5 秒后淡出，⌘Z 照样有效
  func delete(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    listMotion = .settle
    changingList { store.deleteWithUndo(ids) }
    showUndo("已删除 \(ids.count) 条", symbol: "trash")
  }

  /// ⌘Z / 底栏「撤销」：撤最近一批，VoiceOver 播报撤了什么；删掉的回来后选中这一批里最靠前的那条
  func undoDelete() {
    toastTask?.cancel()
    listMotion = .settle
    toast = nil
    switch store.undo() {
    case .deleted(let batch):
      let ids = Set(batch.map(\.id))
      if let first = visibleItems.first(where: { ids.contains($0.id) }) {
        selectedID = first.id
        selectionMotion = .snap
        isBrowsing = true
      }
      Island.announce("已恢复 \(batch.count) 条")
    case .group(let group, _, _): Island.announce("已恢复收藏夹「\(group.name)」")
    case .unretained(let items): Island.announce("已撤销，\(items.count) 条不会被清理")
    case nil: break
    }
  }

  /// ⌘D / 收藏按钮：取消收藏同时移出收藏夹，备注不动（体检 A1 A3）
  func toggleFavorite(_ ids: Set<UUID>) {
    var expiring = 0
    changingList { expiring = store.toggleFavorite(ids) }
    warnExpiring(expiring)
  }

  /// 移出片段（体检 C1）：收藏、收藏夹、备注都不动
  func removeFromSnippets(_ ids: Set<UUID>) {
    var expiring = 0
    changingList { expiring = store.removeFromSnippets(ids) }
    warnExpiring(expiring)
  }

  /// 取消收藏 / 移出片段后已超过保留天数的条目：说一声收起面板后会被清理（⌘Z 改回来）
  private func warnExpiring(_ count: Int) {
    guard count > 0 else { return }
    showUndo("超过 \(ClipboardStore.Limits.days) 天，收起面板后会被清理", symbol: "clock")
  }

  /// 能撤销的操作的提示：底栏「… · 撤销 ⌘Z」5 秒（播报「…，按 Command-Z 撤销」）；放大预览开着时底栏被它盖住，
  /// 另走刘海（岛自己会播报）
  private func showUndo(_ text: String, symbol: String) {
    showToast(.undo(text), spoken: "\(text)，按 Command-Z 撤销")
    if isQuickLooking, let island {
      island.show(text, detail: "⌘Z 撤销", tone: .info, symbol: symbol)
    }
  }

  /// 删除收藏夹（管理收藏夹里）：里面的条目留在默认收藏，不确认，⌘Z 连归属一起回来
  func deleteGroup(_ group: ClipGroup) {
    store.deleteGroup(group.id)
    if groupFilter == .group(group.id) { groupFilter = .all }
    showUndo("已删除收藏夹「\(group.name)」", symbol: "folder.badge.minus")
  }

  /// 编辑正文：按正文缓存的形态、链接、美化结果都清掉（不然 ⌘K「打开链接」还开旧网址，体检 B18）
  func edit(_ id: UUID, text: String) {
    formCache[id] = nil
    linkCache[id] = nil
    prettyCache[id] = nil
    store.update([id]) { $0.text = text }
  }

  /// 编辑 / 新建片段对话框能不能保存（体检 C2）：去掉空白后不空、且改过（没改动的不白写一次库，空白的采集时也会被拒）
  static func canSave(_ text: String, initial: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text != initial
  }

  /// 移到收藏夹（就是收藏）；group 为 nil = 移出收藏夹，留在默认收藏
  func assign(_ ids: Set<UUID>, to group: UUID?) {
    changingList { store.assign(ids, to: group) }
  }

  /// 能翻译：文本，或识别出文字的图片
  func canTranslate(_ item: ClipItem) -> Bool {
    !(item.text ?? item.ocrText ?? "").isEmpty
  }

  func translate(_ item: ClipItem) {
    guard let text = item.text ?? item.ocrText, !text.isEmpty else { return }
    openTranslate(text)
  }

  /// 底栏左边的就地提示：焦点一直在搜索框，读屏听不到，主动播报（spoken 比显示的字多说一点时给；体检 B16）；
  /// 放大预览开着时另走的岛自己会播报，这里不重复
  func showToast(_ toast: BarNotice, spoken: String? = nil) {
    toastTask?.cancel()
    self.toast = toast
    if !(isQuickLooking && island != nil) { Island.announce(spoken ?? toast.text) }
    // 到期只让提示淡出；删掉的在面板收起时才提交（⌘Z 一直有效）
    toastTask = Task {
      try? await Task.sleep(for: .seconds(toast.seconds))
      guard !Task.isCancelled else { return }
      self.toast = nil
    }
  }

  // MARK: ⌘K 操作面板 / 右键菜单

  /// ⌘K：操作对象能做的全部操作（只勾了一条时对着那一条，和 ⌘E ⌘T 这些单条快捷键一致）
  var actions: [ActionMenu.Item] {
    let items = visibleItems
    let targets = targets(in: items)
    guard !targets.isEmpty, let item = targets.count == 1 ? targets[0] : selectedItem(in: items)
    else { return [] }
    return actions(for: item, targets: targets)
  }

  /// ⌘K 和右键菜单共用的动作表（体检 B12）：名字、顺序、出现条件一致，按 section 分节（⌘K 画发丝线、右键菜单插分隔线，
  /// 右键不显示键位）。item 是透镜里的那条，targets 是操作对象（按复制先后）：⌘K 传选中项 + targets，右键传被点的 [item]。
  /// 勾了不止一条（targets 不只是 item 自己）就只给批量操作：单条操作对着预览的那条，批量操作对着勾选的，混在一起会弄错对象。
  /// 右键菜单每画一行都会算一次：这里只用缓存过的判断（形态、链接），不搜索、不读剪贴板
  func actions(for item: ClipItem, targets: [ClipItem]) -> [ActionMenu.Item] {
    let ids = Set(targets.map(\.id))
    let single: ClipItem? = ids == [item.id] ? item : nil
    var actions: [ActionMenu.Item] = []
    func add(
      _ title: String, _ symbol: String, _ shortcut: String? = nil, section: Int,
      id: String? = nil, submenu: [ActionMenu.Item]? = nil, isDestructive: Bool = false,
      run: @escaping () -> Void = {}
    ) {
      actions.append(
        ActionMenu.Item(
          title: title, symbol: symbol, shortcut: shortcut, id: id, section: section,
          submenu: submenu, isDestructive: isDestructive, run: run))
    }
    // 0 粘贴与复制。纯文本的替代粘贴 / 复制只在有得换时给：带格式的文本（片段本来就是纯文本）或多条
    let formatted = single.map { $0.kind == .text && $0.richType != nil && !$0.isSnippet } ?? true
    add(PasteMode(targets).verb, "arrow.turn.down.left", "↩", section: 0) { [unowned self] in
      paste(targets)
    }
    if formatted {
      let plain = !pastesPlainByDefault
      add(alternatePasteTitle, plain ? "doc.plaintext" : "textformat", "⌥↩", section: 0) {
        [unowned self] in paste(targets, plainText: plain)
      }
    }
    add("仅复制", "doc.on.doc", "⌘↩", section: 0) { [unowned self] in copy(targets) }
    if formatted {
      add("复制为纯文本", "doc.on.clipboard", section: 0) { [unowned self] in
        copy(targets, plainText: true)
      }
    }
    if let single, single.kind == .image, !(single.ocrText ?? "").isEmpty {
      add("复制图中文字", "text.viewfinder", section: 0) { [unowned self] in
        copyRecognizedText(single)
      }
    }
    if targets.allSatisfy({ $0.kind == .file }) {
      add("复制路径", "link", "⌥⌘C", section: 0) { [unowned self] in copyPaths(targets) }
    }
    // 1 按类型打开 / 查看
    if let single {
      if single.kind == .file {
        add("打开", "arrow.up.forward.app", "⌘O", section: 1) { [unowned self] in openFiles(single) }
        add("在访达中显示", "folder", "⌘R", section: 1) { [unowned self] in revealInFinder(single) }
      } else if let link = firstLink(of: single) {
        add("打开链接", "safari", "⌘O", section: 1) { [unowned self] in openLink(link) }
      }
      if single.kind == .image {
        add("钉到屏幕", "pin", section: 1) { [unowned self] in pin([single]) }
      }
      if canTranslate(single) {
        add("翻译", "character.bubble", "⌘T", section: 1) { [unowned self] in translate(single) }
      }
      if contentForm(of: single) == .json {
        add(prettyJSON ? "显示原文" : "美化 JSON", "curlybraces", section: 1) { [unowned self] in
          prettyJSON.toggle()
        }
      }
      add("放大预览", "eye", "⌘Y", section: 1) { [unowned self] in
        select(single)
        toggleQuickLook()
      }
    } else if targets.contains(where: { $0.kind == .image }) {
      add("钉到屏幕", "pin", section: 1) { [unowned self] in pin(targets) }
    }
    // 2 收藏、收藏夹、片段、备注、编辑
    let favorite = targets.allSatisfy(\.favorite)
    add(favorite ? "取消收藏" : "收藏", favorite ? "star.slash" : "star", "⌘D", section: 2) {
      [unowned self] in toggleFavorite(ids)
    }
    // 收藏夹：有收藏夹时是一级子列表（当前的 ✓、移出、新建，体检 C3），一个都没有就直接新建
    if store.groups.isEmpty {
      add("放进新收藏夹…", "folder.badge.plus", section: 2) { [unowned self] in
        dialog = .newGroup(ids)
      }
    } else {
      add("移到收藏夹", "folder", section: 2, id: "groups", submenu: groupItems(for: targets))
    }
    if let single, single.kind == .text, !single.isSnippet {
      add("存为片段", "text.badge.star", section: 2) { [unowned self] in
        store.update([single.id]) { $0.isSnippet = true }
      }
    }
    // 移出片段（体检 C1）：多选时有片段就给
    let snippets = Set(targets.filter(\.isSnippet).map(\.id))
    if !snippets.isEmpty {
      add("移出片段", "text.badge.minus", section: 2) { [unowned self] in
        removeFromSnippets(snippets)
      }
    }
    if let single {
      // 备注：所有条目都能写（体检 A3），不设快捷键（⌘R 给了在访达中显示）
      add("备注…", "note.text", section: 2) { [unowned self] in dialog = .note(single.id) }
      if single.kind == .text {
        add("编辑内容…", "pencil", "⌘E", section: 2) { [unowned self] in
          dialog = .edit(single.id)
        }
      }
    }
    add("删除", "trash", "⌘⌫", section: 3, isDestructive: true) { [unowned self] in delete(ids) }
    return actions
  }

  /// 收藏夹列表（⌘K「移到收藏夹」的子列表、多选底栏「收藏夹…」同一份，按拖动排的顺序）：
  /// 都在里面的那个打 ✓，再选一次就移出；有一条在收藏夹里就给「移出收藏夹」（留在默认收藏）；最后「新建收藏夹…」
  func groupItems(for targets: [ClipItem]) -> [ActionMenu.Item] {
    let ids = Set(targets.map(\.id))
    var items = store.groups.map { group in
      let isIn = !targets.isEmpty && targets.allSatisfy { $0.groupID == group.id }
      return ActionMenu.Item(
        title: group.name, symbol: "folder", isChecked: isIn, id: "group.\(group.id)"
      ) { [unowned self] in assign(ids, to: isIn ? nil : group.id) }
    }
    if targets.contains(where: { $0.groupID != nil }) {
      items.append(
        ActionMenu.Item(title: "移出收藏夹", symbol: "folder.badge.minus", section: 1) {
          [unowned self] in assign(ids, to: nil)
        })
    }
    items.append(
      ActionMenu.Item(title: "新建收藏夹…", symbol: "folder.badge.plus", section: 1) {
        [unowned self] in dialog = .newGroup(ids)
      })
    return items
  }

  private func firstLink(of item: ClipItem) -> URL? {
    guard item.kind == .text else { return nil }
    if let cached = linkCache[item.id] { return cached }
    let url = ContentForm.firstLink(in: item.text ?? "")
    linkCache[item.id] = url
    return url
  }

  // MARK: 筛选面板

  /// Tab 筛选面板的条目：收藏、各个收藏夹（紧跟在「收藏」下面，按拖动排的顺序）、片段 | 类型、形态 | 来源（按条数多→少）
  /// | 「管理收藏夹…」（| 是分节线）。已生效的项打勾，再选一次取消；选完生成标签并关面板（run 里关）
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
          id: "kind.\(kind.rawValue)", section: 1
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
          id: "form.\(form.rawValue)", section: 1
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
          detail: "来源 \(source.count)", isChecked: isOn, id: "source.\(source.bundleID)",
          section: 2
        ) { [unowned self] in sourceBundleID = isOn ? nil : source.bundleID })
    }
    items.append(
      ActionMenu.Item(
        title: "管理收藏夹…", symbol: "folder.badge.gearshape", id: "manage", section: 3
      ) {
        [unowned self] in dialog = .manageGroups
      })
    return items
  }

  /// 开着的菜单这一级的条目（⌘K 进了子列表就是子列表的）
  var menuItems: [ActionMenu.Item] {
    switch palette {
    case .filters: return filterItems
    case .actions:
      let root = actions
      guard let actionSubmenu else { return root }
      return root.first { $0.id == actionSubmenu }?.submenu ?? root
    case .groups: return groupItems(for: targets)
    case nil: return []
    }
  }

  /// 按 actionQuery 过滤（ActionMenu.filter：标题或说明包含，中文标题认拼音前缀；输「来源」列出全部来源、fy 找到翻译）
  var filteredActions: [ActionMenu.Item] { ActionMenu.filter(menuItems, query: actionQuery) }

  /// 子列表顶上「‹ 移到收藏夹」的标题；在第一级时 nil
  var submenuTitle: String? {
    guard palette == .actions, let actionSubmenu else { return nil }
    return actions.first { $0.id == actionSubmenu }?.title
  }

  private var selectedAction: ActionMenu.Item? {
    let actions = filteredActions
    return actions.indices.contains(actionSelection) ? actions[actionSelection] : nil
  }

  private func moveAction(by offset: Int) {
    let count = filteredActions.count
    guard count > 0 else { return }
    actionSelection = (actionSelection + offset + count) % count
  }

  func runSelectedAction() {
    guard let action = selectedAction else { return NSSound.beep() }
    run(action)
  }

  /// 有子列表的行：进去（过滤词清空、选第一行，菜单不关）；其余先关菜单再执行
  func run(_ action: ActionMenu.Item) {
    if action.submenu != nil {
      actionSubmenu = action.id
      actionQuery = ""
      actionSelection = 0
      return
    }
    palette = nil
    action.run()
  }

  /// ← / Esc / 点「‹」：从子列表回到第一级，选中进去的那一行
  func leaveSubmenu() {
    guard let id = actionSubmenu else { return }
    actionSubmenu = nil
    actionQuery = ""
    actionSelection = actions.firstIndex { $0.id == id } ?? 0
  }

  // MARK: 拖出去（体检 D3）

  /// 拖一行出去的东西（ClipDrag 起会话）：拖的是勾选项之一就拖全部勾选项（看得见的，按复制先后），否则就这一条。
  /// 和粘贴写进剪贴板的同一份：文本带格式、片段展开成纯文本、多条文本合成一段、全是文件时是去重后的全部文件；
  /// 图片另加一个临时文件（「图片 宽×高.png」，拖进访达是文件、拖进聊天窗口是图）。
  /// 拖放不算粘贴：不挪到最前、不改选中、不记新历史。图片丢了、文件都不在了的不拖
  func dragItems(for item: ClipItem) -> [NSPasteboardItem] {
    let items = multiSelection.contains(item.id) ? targets : [item]
    guard !items.isEmpty, unavailable(items) == nil else { return [] }
    switch PasteMode(items) {
    case .merged, .together: return payload(for: items, plainText: false).writes[0]
    case .single, .sequential: break
    }
    return items.flatMap { item in
      let written = payload(for: [item], plainText: false).writes[0]
      if item.kind == .image, let first = written.first, let file = dragFile(for: item) {
        first.setString(file.absoluteString, forType: .fileURL)
      }
      return written
    }
  }

  /// 拖出去的图片文件：从图片库克隆一份（APFS 上瞬间完成、不占空间），名字「图片 宽×高.png」。放在截图拖出用的临时目录下
  /// 按条目分的子目录里（同尺寸的截图名字一样，不能共用一个文件）；同一条的图不会变，克隆过就复用
  /// （启动时清空、用时不删：放下后对方可能还在读）
  private func dragFile(for item: ClipItem) -> URL? {
    let name = item.image.map { "图片 \($0.width)×\($0.height).png" } ?? "图片.png"
    let folder = ShotShelf.dragDirectory.appending(path: item.id.uuidString)
    let url = folder.appending(path: name)
    let files = FileManager.default
    if files.fileExists(atPath: url.path) { return url }
    try? files.createDirectory(at: folder, withIntermediateDirectories: true)
    guard (try? files.copyItem(at: store.images.url(for: item.id), to: url)) != nil else {
      return nil
    }
    return url
  }

  // MARK: 显示 / 隐藏

  /// 每次隐藏都复位：搜索、筛选标签（含待删）、浮起的菜单、多选、对话框，选中项回到第一条，JSON 回到美化；
  /// 没撤销的删除落库，⌘C 复制过的挪到最前
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
    prettyJSON = true
    prettyCache = [:]
  }

  /// 筛选 / 搜索变了：回到第一条；勾选只留新列表里看得见的（一条不剩就退出多选，体检 B8）
  private func restartBrowsing() {
    isBrowsing = false
    selectedID = nil
    selectionMotion = .instant
    listMotion = .instant
    listGeneration += 1
    pruneMultiSelection()
  }

  /// 勾选里看不见的去掉：批量操作不打到看不见的条目（体检 B8）
  private func pruneMultiSelection() {
    guard !multiSelection.isEmpty else { return }
    multiSelection.formIntersection(visibleItems.map(\.id))
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
    pruneMultiSelection()
  }
}
