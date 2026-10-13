// 便签专用的正文编辑器（PLAN §10「便签」第 5 批；规矩在 mac-overlay-panel §3 §12，长相在 mac-whisker-notes.mdc）：
// 全部便签窗口和屏幕边缘那叠的正文都是它（NoteFields.swift 的 NoteBodyField 包着）；快速记一条照旧用 SourceTextView。
// - **显式搭的 TextKit 1**（自己建 NSTextStorage → NSLayoutManager → NSTextContainer 再交给文本视图）：下一批要靠
//   NSLayoutManager 把 Markdown 标记的字形藏起来，普通 NSTextView 拿到的是 TextKit 2，那一招不灵。只拿着文本视图就够：
//   实测（macOS 15.7，独立小程序）存储跟着视图活、跟着视图放，不用另存一份，也就没有「把属性置空」那种事。
// - 纯文本。样式（NoteStyles）是显示时加的属性：只改属性、不改字、不进撤销栈、不动选区；每次编辑只重排受影响的行。
//   **输入法组字期间不重排、不往外写**（settle）：那时动属性会让刚打的字看不见（Noty 踩过），组字里的拼音字母也不该
//   进仓库；确认之后一次补上。组字期间外面那份正文是旧的，所以「外面换了正文」认的是「和上次交出去的不一样」（setText），
//   不拿它和正在打的字比。打进去的字永远是基础样式（typingAttributes），该有的样式由重排补。
// - 任务（NoteTasks，纯函数；这里只管调）：⌘T 切换、点方框打勾（不是 key 的面板里第一下点击就生效）、回车续行和
//   空项退出、列表行 Tab / ⇧Tab 缩进、打「- [ ]」加空格自动转换。改字都走 shouldChangeText → 改 → didChangeText：
//   进撤销栈、照常重排和写出去。
// - 按键照 mac-overlay-panel §3：回车、Tab、Esc 走 doCommand(by:)（输入法组字时这些键归输入法，到不了这里）；
//   没处理的 cancelOperation: 交给窗口；不装按键监听。
// - 上限：会让正文超过 maxBytes 的那一次输入拦下（提示音 + onOverflow），不截断；组字期间不判断，确认后超了退回。
// - 焦点：identifier 是便签的编号（那叠按它找「这条便签的正文框」）；挂进窗口那一刻该它拿就拿，之后每要一次拿一次。
// - 撤销：登记和操作用同一个栈，而且是明说的——noteUndo 是这条便签的撤销栈（建的时候给定），undoManager 就返回它，
//   不靠响应链去问窗口；⌘Z / ⇧⌘Z 的入口（OverlayPanel.undoRedo、NotesWindowModel.undo / redo）直接动
//   「焦点所在输入框的 undoManager」。粒度按系统默认（连着打的字一组）。离开窗口时把这个栈清掉：里面的动作指着的是
//   这个视图的文本存储，视图没了再撤就是野指针（Noty 踩过）。
// - 光标：被浮在上面的东西（「⋯」菜单）盖住时是箭头，在方框上是手指，别的交给文本视图自己（I 形）。
// - 查找：系统自带的查找条（usesFindBar + 增量查找），长在滚动区顶上；Esc 先关它。
// ponytail: 连续排版（没开 allowsNonContiguousLayout）；正文上限 1 MB，几百行没事，真有上万行的便签打字卡了再开。

import AppKit
import SwiftUI

final class NoteTextView: NSTextView, NSTextStorageDelegate {
  /// 正文最多多少字节（UTF-8）；nil = 不限
  var maxBytes: Int?
  /// 正文变了：给的是确认过的全文（输入法组字期间不调）
  var onChange: (String) -> Void = { _ in }
  /// 拦下了会超上限的一次输入
  var onOverflow: () -> Void = {}
  /// Esc（查找条开着时先关它，不到这里）；nil = 交给窗口
  var onCancel: (() -> Void)?
  /// 挂进窗口的那一刻就拿焦点（窗口不必是 key）：那叠里刚打开的那条便签
  var takesFocusOnAppear = false
  /// 上次处理过的「要焦点」的次数（NoteTextEditor.focusRequest）
  var focusRequest = 0
  /// 这条便签的撤销栈（那叠：NoteDeckModel.textUndo；全部便签窗口：NotesWindowModel.textUndo），建的时候给定、之后不换
  /// ——换一条便签时旧的正文框还会留一小会儿，它晚到的改动不能登记进新便签的栈里。nil = 顺着响应链问窗口
  var noteUndo: UndoManager?

  /// 现在的纸色和字号（变了才整篇重排）
  private var paper: NotePaper?
  private var bodyFont = NSFont.systemFont(ofSize: 15)
  private var ink = NSColor.textColor
  private var faded = NSColor.secondaryLabelColor
  /// 上次交出去 / 拿进来的全文：外面再给同样的就不动；输入法确认之后超了上限退回它
  private var reported = ""
  /// 改过字、还没重排的那一段
  private var pending = NoteStyles.Pending()

  /// 点方框的范围比那个字四周放宽多少
  static let boxSlop = CGSize(width: 4, height: 3)

  /// 建一个：TextKit 1 的栈在这里搭
  static func make() -> NoteTextView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    // 行高只按字的上下沿算，不加后备字体自带的行距（方框用的 Apple Symbols 有）；系统字体、苹方、表情的行距本来就是 0
    layout.usesFontLeading = false
    storage.addLayoutManager(layout)
    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    let view = NoteTextView(frame: .zero, textContainer: container)
    storage.delegate = view
    view.isRichText = false
    view.allowsUndo = true
    view.drawsBackground = false
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.minSize = .zero
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.usesFindBar = true
    view.isIncrementalSearchingEnabled = true
    return view
  }

  // MARK: 外面给的

  /// 纸色、字号（换了才动）：基础字体和墨色、插入点，整篇重排
  func setPaper(_ paper: NotePaper, fontSize: CGFloat) {
    guard paper != self.paper || fontSize != bodyFont.pointSize else { return }
    self.paper = paper
    bodyFont = .systemFont(ofSize: fontSize)
    ink = paper.inkColor
    faded = paper.fadedInkColor
    // 纸上的输入框插入点用墨色：强调色选黄时在柠檬色的纸上看不见
    insertionPointColor = ink
    restyleAll()
  }

  /// 外面的正文（仓库里那份）。和上次交出去 / 拿进来的一样就不动——组字期间仓库里那份是旧的，不能拿它盖掉正在组的字；
  /// 真换了（别处改了这条便签）才整段替换，这时撤销栈指着的是旧文字，一起清掉。组字期间外面的改动先不收
  func setText(_ text: String) {
    guard text != reported, !hasMarkedText() else { return }
    replaceAll(with: text)
  }

  private func replaceAll(with text: String) {
    reported = text
    string = text
    _ = pending.take()
    restyleAll()
    undoManager?.removeAllActions()
  }

  // MARK: 样式

  /// 打进去的字永远是基础样式，不跟光标前面那个字走（它可能是方框——另一种字体，或者做完的任务——划线、变淡）；
  /// 组字中的字也按它画。该有的样式等这次编辑收尾了由重排补
  override var typingAttributes: [NSAttributedString.Key: Any] {
    get { [.font: bodyFont, .foregroundColor: ink] }
    set {}
  }

  private func restyleAll() {
    guard let storage = textStorage else { return }
    restyle(NSRange(location: 0, length: storage.length))
  }

  private func restyle(_ lines: NSRange) {
    guard let storage = textStorage else { return }
    NoteStyles.apply(to: storage, lines: lines, font: bodyFont, ink: ink, faded: faded)
  }

  /// 文本存储每处理完一次改字报一次（打字、粘贴、撤销、输入法组字、程序改的都经过这里）：记下改的是哪一段。
  /// 只改属性的（重排自己）不算。系统在改字的那个调用里同步调过来（主线程）
  nonisolated func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    MainActor.assumeIsolated { pending.record(editedRange, delta: delta) }
  }

  override func didChangeText() {
    super.didChangeText()
    settle()
  }

  /// 一次编辑收尾了：没有没确认的组字时，把样式补上、把正文交出去。输入法还在组字就什么都不做——攒着的区间等确认
  /// （或者撤掉组字：都会再走到这里）之后一次处理
  private func settle() {
    guard !hasMarkedText(), let storage = textStorage else { return }
    let text = string
    if let maxBytes, text.utf8.count > maxBytes {
      // 输入法确认的那一下 shouldChangeText 拦不了（那时还在组字）：退回组字之前的样子。
      // ponytail: 整段换回去，光标到末尾、撤销栈清空；只有贴着上限用输入法打字才走到这里，真碰上再细做
      replaceAll(with: reported)
      overflowed()
      return
    }
    if let edited = pending.take() {
      restyle(NoteStyles.lines(covering: edited, in: storage.mutableString))
    }
    guard text != reported else { return }
    reported = text
    onChange(text)
  }

  // MARK: 上限

  /// 把 current 里 ranges 那几段换成 replacements 之后会不会超过 maxBytes（纯函数，UTF-8 字节；区间是 UTF-16 的）。
  /// 没让正文变长的改动（删除、换成更短的）永远不算：正文不知怎么已经超了的时候，得删得动
  nonisolated static func overflows(
    _ current: String, replacing ranges: [NSRange], with replacements: [String], maxBytes: Int
  ) -> Bool {
    let removed = ranges.reduce(0) { total, range in
      total + (Range(range, in: current).map { current[$0].utf8.count } ?? 0)
    }
    let added = replacements.reduce(0) { $0 + $1.utf8.count }
    return added > removed && current.utf8.count - removed + added > maxBytes
  }

  /// 打字、粘贴、拖进来、撤销、程序改字都先问到这里（单段的那个入口也转到这个）：会超上限的那一次不进。
  /// 输入法还在组字时不判断（拦了会打断组字），确认之后由 settle 兜着
  override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?)
    -> Bool
  {
    if let maxBytes, let replacementStrings, !hasMarkedText(),
      Self.overflows(
        string, replacing: affectedRanges.map(\.rangeValue), with: replacementStrings,
        maxBytes: maxBytes)
    {
      overflowed()
      return false
    }
    return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
  }

  private func overflowed() {
    NSSound.beep()
    onOverflow()
  }

  // MARK: 撤销

  /// 文本视图登记撤销、判断能不能撤，问的都是这个：直接给这条便签的栈（等价于代理方法 undoManager(for:)，
  /// 这个视图没有另设代理）
  override var undoManager: UndoManager? { noteUndo ?? super.undoManager }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    // 这个正文框不用了：它登记的撤销动作一起清掉（栈里只有它的——标题框的字段编辑器用的是系统给它单独的栈）
    if newWindow == nil { noteUndo?.removeAllActions() }
    super.viewWillMove(toWindow: newWindow)
  }

  // MARK: 焦点

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    window.initialFirstResponder = self
    if takesFocusOnAppear { window.makeFirstResponder(self) }
  }

  /// 组字到一半焦点走了：输入法一般会自己收尾（确认或者撤掉，都会走 didChangeText）。它没收尾的话——没确认的字还挂在
  /// 这里、仓库里却没有——晚一拍替它确认掉（不当场做：输入法的那一下可能还在路上）：看得见的字和存下的字要一样
  override func resignFirstResponder() -> Bool {
    guard super.resignFirstResponder() else { return false }
    if hasMarkedText() { perform(#selector(commitStrayComposition), with: nil, afterDelay: 0) }
    return true
  }

  @objc private func commitStrayComposition() {
    if hasMarkedText(), window?.firstResponder !== self { unmarkText() }
  }

  // MARK: 按键

  /// 回车、Tab、Esc（输入法组字时这些键归输入法，到不了这里）
  override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(insertNewline(_:)):
      if editLine({ NoteTasks.newline(in: $0, caret: $1) }) { return }
    case #selector(insertTab(_:)):
      if editLine({ NoteTasks.indent($0, caret: $1, outdent: false) }) { return }
    case #selector(insertBacktab(_:)):
      if editLine({ NoteTasks.indent($0, caret: $1, outdent: true) }) { return }
    case #selector(cancelOperation(_:)):
      if dismissFindBar() { return }
      if let onCancel { onCancel() } else { window?.cancelOperation(nil) }
      return
    default: break
    }
    super.doCommand(by: selector)
  }

  /// 行首已经是「- [ ]」时按空格：换成方框（这个空格不插）
  override func insertText(_ string: Any, replacementRange: NSRange) {
    if string as? String == " ", editLine({ NoteTasks.shorthand(in: $0, caret: $1) }) { return }
    super.insertText(string, replacementRange: replacementRange)
  }

  /// 没有选区、没在组字时，拿光标所在的行（不含行尾的换行）和光标在行里的位置去问 change 要不要改；改了返回 true
  private func editLine(_ change: (String, Int) -> NoteTasks.Change?) -> Bool {
    let selection = selectedRange()
    guard selection.length == 0, !hasMarkedText(), let text = textStorage?.mutableString else {
      return false
    }
    var (start, contentsEnd) = (0, 0)
    text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: selection)
    let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
    guard let change = change(line, selection.location - start) else { return false }
    return perform(change, at: start)
  }

  /// 照 NoteTasks 给的改动改字（base：它的位置相对正文的哪里）：一步撤销，改完把选区放到它说的地方。
  /// 被拦下（超上限）返回 false
  @discardableResult
  private func perform(_ change: NoteTasks.Change, at base: Int) -> Bool {
    // 空的改动：这一下吞掉，不做事（列表行没有缩进可退时的 ⇧Tab）
    guard !change.replacements.isEmpty, let storage = textStorage else { return true }
    let ranges = change.replacements.map {
      NSRange(location: $0.range.location + base, length: $0.range.length)
    }
    let texts = change.replacements.map(\.text)
    // 不和前面的打字并成一步撤销
    breakUndoCoalescing()
    guard shouldChangeText(inRanges: ranges.map(NSValue.init(range:)), replacementStrings: texts)
    else { return false }
    storage.beginEditing()
    // 从后往前换：前面的位置不受影响
    for (range, text) in zip(ranges, texts).reversed() {
      storage.replaceCharacters(in: range, with: text)
    }
    storage.endEditing()
    didChangeText()
    let selection = NSRange(
      location: change.selection.location + base, length: change.selection.length)
    setSelectedRange(selection)
    scrollRangeToVisible(selection)
    return true
  }

  // MARK: 任务

  /// ⌘T、头部 / 工具栏的「任务」钮、右键菜单：光标所在行（有选区时是选区碰到的每一行）在普通行和任务之间切换
  @objc func toggleTask(_ sender: Any? = nil) {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    var (start, contentsEnd) = (0, 0)
    text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: selection)
    let block = text.substring(with: NSRange(location: start, length: contentsEnd - start))
    let local = NSRange(location: selection.location - start, length: selection.length)
    if let change = NoteTasks.toggle(block, selection: local) { perform(change, at: start) }
  }

  /// 这一点（视图自己的坐标）是不是落在某个任务的方框上（那个字四周放宽 boxSlop）：是就给方框那个字的位置
  func box(at point: NSPoint) -> Int? {
    guard let layoutManager, let textContainer, let text = textStorage?.mutableString,
      text.length > 0
    else { return nil }
    let index = min(characterIndexForInsertion(at: point), text.length - 1)
    var (start, contentsEnd) = (0, 0)
    text.getLineStart(
      &start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
    // 只看行首的一小段就够认方框（鼠标每动一下都要问，行可能很长）
    let head = text.substring(
      with: NSRange(location: start, length: min(contentsEnd - start, 256)))
    guard let offset = NoteTasks.box(in: head) else { return nil }
    let glyphs = layoutManager.glyphRange(
      forCharacterRange: NSRange(location: start + offset, length: 1), actualCharacterRange: nil)
    let origin = textContainerOrigin
    let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      .offsetBy(dx: origin.x, dy: origin.y)
      .insetBy(dx: -Self.boxSlop.width, dy: -Self.boxSlop.height)
    return rect.contains(point) ? start + offset : nil
  }

  /// 点方框：☐ ↔ ☑（一步撤销；光标和选区不动）
  private func flipBox(at index: Int) {
    guard let storage = textStorage, index < storage.length else { return }
    let range = NSRange(location: index, length: 1)
    let box = Character(storage.mutableString.substring(with: range))
    let flipped = String(NoteTasks.flipped(box))
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: flipped) else { return }
    storage.replaceCharacters(in: range, with: flipped)
    didChangeText()
  }

  // MARK: 鼠标

  /// 不是 key 的面板里第一下点击就勾得上方框（别的地方照文本视图自己的规矩）
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    if let event, box(at: convert(event.locationInWindow, from: nil)) != nil { return true }
    return super.acceptsFirstMouse(for: event)
  }

  override func mouseDown(with event: NSEvent) {
    if isEditable, !hasMarkedText(),
      let index = box(at: convert(event.locationInWindow, from: nil))
    {
      flipBox(at: index)
    } else {
      super.mouseDown(with: event)
    }
  }

  override func mouseMoved(with event: NSEvent) {
    if !setsCursor(at: event.locationInWindow) { super.mouseMoved(with: event) }
  }

  override func cursorUpdate(with event: NSEvent) {
    if !setsCursor(at: event.locationInWindow) { super.cursorUpdate(with: event) }
  }

  /// 这一点（窗口坐标）上的光标归不归自己定：被浮在上面的东西盖住了（「⋯」菜单）是箭头——文本视图不知道自己被盖住，
  /// 鼠标在它的范围里一动就设 I 形（2026-10-13 用户报，同 SourceTextView.FocusTextView）；没被盖住、在方框上是手指；
  /// 别的返回 false，交给文本视图自己
  private func setsCursor(at point: NSPoint) -> Bool {
    if isCovered(at: point) {
      NSCursor.arrow.set()
    } else if box(at: convert(point, from: nil)) != nil {
      NSCursor.pointingHand.set()
    } else {
      return false
    }
    return true
  }

  /// 窗口里这一点上最上面的视图是不是别人的（SwiftUI 画在它上面的内容点到的是宿主视图，不是它）
  private func isCovered(at point: NSPoint) -> Bool {
    guard let content = window?.contentView else { return false }
    let local = content.superview?.convert(point, from: nil) ?? point
    guard let hit = content.hitTest(local) else { return false }
    return hit !== self && !hit.isDescendant(of: self)
  }

  /// 右键菜单最前面加一项「任务」（同名，不写键位）
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event)
    let item = NSMenuItem(
      title: NotesWindowModel.taskTitle, action: #selector(toggleTask(_:)), keyEquivalent: "")
    item.target = self
    menu?.insertItem(item, at: 0)
    menu?.insertItem(.separator(), at: 1)
    return menu
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(toggleTask(_:)) { return isEditable }
    return super.validateUserInterfaceItem(item)
  }

  // MARK: 查找

  /// ⌘F：系统的查找条（长在滚动区顶上，焦点进它的搜索框）
  func showFindBar() { runFinder(.showFindInterface) }

  /// 查找条开着就关掉（焦点回正文），返回关没关：Esc 先关它，再按才轮到便签
  @discardableResult
  func dismissFindBar() -> Bool {
    guard enclosingScrollView?.isFindBarVisible == true else { return false }
    runFinder(.hideFindInterface)
    return true
  }

  private func runFinder(_ action: NSTextFinder.Action) {
    let item = NSMenuItem()
    item.tag = action.rawValue
    performTextFinderAction(item)
  }
}

/// 正文编辑器的 SwiftUI 包装：滚动区铺满给它的大小、滚动条贴右边，文字的左右内缩在 horizontalInset 里
/// （另有 NSTextView 自己的 lineFragmentPadding 5）
struct NoteTextEditor: NSViewRepresentable {
  let note: Note
  let fontSize: CGFloat
  let horizontalInset: CGFloat
  /// 是「该拿焦点的那条」时给第几次要：挂进窗口那一刻拿一次，之后这个数每变一次再拿一次；nil = 不归它拿
  var focusRequest: Int?
  /// 这条便签的撤销栈（只在建的时候取一次，见 NoteTextView.noteUndo）
  var undo: UndoManager?
  let onChange: (String) -> Void
  let onOverflow: () -> Void
  var onCancel: (() -> Void)?

  func makeNSView(context: Context) -> NSScrollView {
    let view = NoteTextView.make()
    view.noteUndo = undo
    // 标上这条便签的编号：换一条时新旧两个正文框同时在，拿焦点的要按编号认（NoteDeck.editor(for:in:)）
    view.identifier = NSUserInterfaceItemIdentifier(note.id)
    view.maxBytes = Note.maxBodyBytes
    view.textContainerInset = NSSize(width: horizontalInset, height: 6)
    view.focusRequest = focusRequest ?? 0
    view.takesFocusOnAppear = focusRequest != nil
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NoteTextView else { return }
    view.onChange = onChange
    view.onOverflow = onOverflow
    view.onCancel = onCancel
    if let request = focusRequest, request != view.focusRequest {
      view.focusRequest = request
      view.window?.makeFirstResponder(view)
    }
    view.setPaper(NotePaper.of(note), fontSize: fontSize)
    view.setText(note.body)
    // 选中文字的底色是强调色 0.28（不露系统蓝；读了 Style.brand，设置里换了强调色这里会重跑）
    view.selectedTextAttributes = [
      .backgroundColor: NSColor(Style.brand).withAlphaComponent(0.28)
    ]
  }
}
