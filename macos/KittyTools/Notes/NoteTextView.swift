// 便签专用的正文编辑器（PLAN §10「便签」第 5、6 批；规矩在 mac-overlay-panel §3 §12，长相在 mac-whisker-notes.mdc）：
// 全部便签窗口和屏幕边缘那叠的正文都是它（NoteFields.swift 的 NoteBodyField 包着）；快速记一条照旧用 SourceTextView。
// - **显式搭的 TextKit 1**（自己建 NSTextStorage → NSLayoutManager → NSTextContainer 再交给文本视图）：Markdown 的标记
//   靠 NSLayoutManager 把字形藏起来，普通 NSTextView 拿到的是 TextKit 2，那一招不灵。只拿着文本视图就够：
//   实测（macOS 15.7，独立小程序）存储跟着视图活、跟着视图放，不用另存一份，也就没有「把属性置空」那种事。
// - 纯文本。样式（NoteStyles）是显示时加的属性：只改属性、不改字、不进撤销栈、不动选区；每次编辑只重排受影响的行。
//   **输入法组字期间不重排、不往外写**（settle）：那时动属性会让刚打的字看不见（Noty 踩过），组字里的拼音字母也不该
//   进仓库；确认之后一次补上。**撤掉组字**（输入法里按 Esc、把拼音退格删光）时系统最后那次 didChangeText 还算在组字、
//   之后不再有：要在 setMarkedText 之后自己收尾。组字期间外面那份正文是旧的，所以「外面换了正文」认的是「和上次交出去的
//   不一样」（setText），不拿它和正在打的字比。打进去的字永远是基础样式（typingAttributes），该有的样式由重排补。
// - **Markdown 的标记只在「该露的行」露出来**（syncMarkers；设置 › 便签可以整个关掉）：选区碰到的每一行，而且得是
//   正文框拿着焦点、窗口是 key、能编辑——别的行、别的时候标记都藏着（零宽、不画，NoteStyles.hideGlyphs）。
//   排标记的入口，都先过同一道闸（没在组字、没有没处理完的编辑）：settle（一次编辑收尾：didChangeText 之后；撤掉组字
//   是 setMarkedText 之后；再加兜底的那次 settleLeftover）、选区变完（鼠标拖选的过程中不算，松手才算）、拿到 / 失去
//   焦点、窗口当上 / 不再是 key、mouseDown 末尾；另有整篇重排（换纸色 / 字号 / 开关、外面换了正文）。
//   **选区变化可能在一次改字还没收尾时就来**，那时不动，留给紧跟着的 didChangeText → settle；万一哪条路改了字却没有
//   didChangeText（真输入法没模拟到的），选区变化时发现了就排一次下一轮的收尾（兜底）。露着标记的行不另记：
//   记在字上（NoteStyles.shownKey），编辑把那一行挪到哪、拆成几行都找得回来。用鼠标点进来（拿焦点 / 把窗口点成 key）
//   的那一刻先不排，晚一拍、等这一下点完（syncUnlessClicking、mouseDown 的末尾）：不然旧光标那一行先露出标记，
//   字在鼠标底下挪，点不准。
// - 链接：⌘ 点才打开（只有 http / https / mailto 的地址记在字上），普通点击照常放光标；不用系统的 .link 属性。
//   右键点在能打开的链接上，菜单最前面多一项「打开链接」——不靠 ⌘ 点的那条路（键盘、旁白用户）。
// - 任务（NoteTasks，纯函数；这里只管调）：⌘T 切换、点方框打勾（不是 key 的面板里第一下点击就生效）、回车续行和
//   空项退出、列表行 Tab / ⇧Tab 缩进、打「- [ ]」加空格自动转换。改字都走 shouldChangeText → 改 → didChangeText：
//   进撤销栈、照常重排和写出去。
// - 按键照 mac-overlay-panel §3：回车、Tab、Esc 走 doCommand(by:)（输入法组字时这些键归输入法，到不了这里）；
//   ⌃↩（insertLineBreak:）当普通换行；没处理的 cancelOperation: 交给窗口；不装按键监听。
// - 上限：会让正文超过 maxBytes 的那一次输入拦下（提示音 + onOverflow），不截断；组字期间不判断，确认后超了退回
//   （只退让正文变长了的那一次：正文不知怎么已经超了的时候得删得动）。
// - 焦点：identifier 是便签的编号（那叠按它找「这条便签的正文框」）；挂进窗口那一刻该它拿就拿，之后每要一次拿一次。
// - 撤销：登记和操作用同一个栈，而且是明说的——noteUndo 是这条便签的撤销栈（建的时候给定），undoManager 就返回它，
//   不靠响应链去问窗口；⌘Z / ⇧⌘Z 的入口（OverlayPanel.undoRedo、NotesWindowModel.undo / redo）直接动
//   「焦点所在输入框的 undoManager」。粒度按系统默认（连着打的字一组）。离开窗口时把这个栈清掉：里面的动作指着的是
//   这个视图的文本存储，视图没了再撤就是野指针（Noty 踩过）。
// - 光标：被浮在上面的东西（「⋯」菜单）盖住时是箭头，在方框上、按着 ⌘ 在链接上是手指，别的交给文本视图自己（I 形）。
// - 查找：系统自带的查找条（usesFindBar + 增量查找），长在滚动区顶上；Esc 先关它。
// ponytail: 连续排版（没开 allowsNonContiguousLayout）；正文上限 1 MB，几百行没事，真有上万行的便签打字卡了再开。
// 一整段很长又中英混排时 TextKit 1 超线性（实测 Release、M3 Air）——64 KB 不换行的一段，打一个字约 2.3 s（关掉
// Markdown 约 0.9 s、原生 TextKit 1 约 0.45 s）；贴一行很长的日志 / JSON 会碰到。
// ponytail: 鼠标停在链接上不动、这时才按下 / 松开 ⌘，手指光标要等鼠标再动一下才换（没接 flagsChanged）。
// ponytail: 焦点在查找条里时正文不算拿着焦点，标记都藏着——搜到的字正好在藏着的标记里（链接的地址）时看不见高亮。
// 要看得见就在查找条开着时把匹配所在的行也算进 revealedLines。
// ponytail: 贴进来的软换行（U+2028）不管：NSString 把它算新的一行、段落样式却按段算，它后面的「> 引用」缩进不对、
// 竖线压在字上（自己按 ⌃↩ 打不出来：当普通换行了）。要对就改成「行首不是段首的不当引用」。

import AppKit
import SwiftUI

final class NoteTextView: NSTextView, NSTextStorageDelegate, NSLayoutManagerDelegate {
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
  /// ⌘ 点链接、右键菜单的「打开链接」拿地址去做什么：默认交给系统打开（单测换掉——不许真的开浏览器）
  var onOpenLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

  /// 现在的纸色，和它连同字号、Markdown 开关定下来的字体和颜色（变了才整篇重排）
  private var paper: NotePaper?
  private var theme = NoteStyles.Theme()
  /// 上次交出去 / 拿进来的全文：外面再给同样的就不动；输入法确认之后超了上限退回它
  private var reported = ""
  /// 改过字、还没重排的那一段
  private var pending = NoteStyles.Pending()
  /// 组字期间来了要整篇重排的事（换纸色、字号、Markdown 开关）：先欠着，确认之后补
  private var owesFullRestyle = false
  /// 自己是不是第一响应者、所在的窗口是不是 key：两样都是，选区碰到的行才露出 Markdown 的标记
  private var isFocused = false
  private var isInKeyWindow = false

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
    // 生成字形时来问：带「藏起来」属性的字当成零宽的控制字符（layoutManager(_:shouldGenerateGlyphs:…) 那两个）
    layout.delegate = view
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

  /// 纸色、字号、Markdown 样式开没开（换了才动）：基础字体和墨色、插入点，整篇重排
  func setPaper(_ paper: NotePaper, fontSize: CGFloat, markdown: Bool) {
    guard paper != self.paper || fontSize != theme.font.pointSize || markdown != theme.markdown
    else { return }
    self.paper = paper
    theme = NoteStyles.Theme(paper: paper, fontSize: fontSize, markdown: markdown)
    // 纸上的输入框插入点用墨色：强调色选黄时在柠檬色的纸上看不见
    insertionPointColor = theme.ink
    restyleAll()
  }

  /// 外面的正文（仓库里那份）。和上次交出去 / 拿进来的一样就不动——组字期间仓库里那份是旧的，不能拿它盖掉正在组的字；
  /// 真换了（别处改了这条便签）才整段替换，这时撤销栈指着的是旧文字，一起清掉。组字期间外面的改动先不收
  func setText(_ text: String) {
    guard text != reported, !hasMarkedText() else { return }
    replaceAll(with: text)
  }

  /// 整段换成 text（新建的正文框第一次拿到字、别处改了这条、超上限退回）：先在一份不挂排版的文本存储上把样式排好，
  /// 再一次换进来——只排一遍版。原来先放字（排一遍）再整篇重排样式（又排一遍），是换一条便签时主线程上最大的几块之一
  /// （手测反馈第 3 批屏外量的）。标记先都藏着，换完由 syncMarkers 按焦点和选区露出该露的那几行
  private func replaceAll(with text: String) {
    reported = text
    let styled = NSTextStorage(string: text)
    NoteStyles.apply(
      to: styled, lines: NSRange(location: 0, length: styled.length), theme: theme, shown: [])
    textStorage?.setAttributedString(styled)
    _ = pending.take()
    owesFullRestyle = false
    markWholeViewDirty()
    syncMarkers()
    if isFocused { updateInsertionPointStateAndRestartTimer(true) }
    undoManager?.removeAllActions()
  }

  // MARK: 样式

  /// 打进去的字永远是基础样式，不跟光标前面那个字走（它可能是方框——另一种字体，或者做完的任务——划线、变淡）；
  /// 组字中的字也按它画。该有的样式等这次编辑收尾了由重排补
  override var typingAttributes: [NSAttributedString.Key: Any] {
    get { [.font: theme.font, .foregroundColor: theme.ink] }
    set {}
  }

  /// 整篇重排。输入法正组着字就先欠着（那时不许动属性），确认之后由 settle 补
  private func restyleAll() {
    guard let storage = textStorage else { return }
    guard !hasMarkedText() else {
      owesFullRestyle = true
      return
    }
    owesFullRestyle = false
    restyle(NSRange(location: 0, length: storage.length))
  }

  /// 把这几行（整行）的样式重排一遍。**调它的地方都得先确认没在组字**
  private func restyle(_ lines: NSRange) {
    guard let storage = textStorage else { return }
    NoteStyles.apply(to: storage, lines: lines, theme: theme, shown: revealedLines())
    markWholeViewDirty()
    // 标记露出 / 收起、字体变了之后这一行的字会左右挪：插入点跟着重算
    if isFocused { updateInsertionPointStateAndRestartTimer(true) }
  }

  /// 引用的竖线画在字的外面（左边空出来的那一条）：这几行排版变了不一定会带着那一条重画，整个视图标成要重画
  /// （真画的只有看得见的那一块）。**不许顺手排版**（avoidAdditionalLayout）：文本视图的 needsDisplay = true 会为了算
  /// 「这一块里有哪些字」当场把整个视图那么高的字全排一遍——换一条便签时它占了正文框建出来的九成多（5 KB 的正文，
  /// Debug 约 50 ms；手测反馈第 3 批 sample 出来的）。排版留给真要画的那一刻
  private func markWholeViewDirty() {
    setNeedsDisplay(bounds, avoidAdditionalLayout: true)
  }

  // MARK: Markdown 的标记：露在哪几行

  /// 现在该露出标记的行（整行的区间，选区有几段就是几段）：选区碰到的每一行——前提是 Markdown 开着、能编辑、
  /// 正文框拿着焦点、窗口是 key；不然一行都不露
  private func revealedLines() -> [NSRange] {
    guard theme.markdown, isEditable, isFocused, isInKeyWindow,
      let text = textStorage?.mutableString
    else { return [] }
    return selectedRanges.map { text.lineRange(for: $0.rangeValue) }
  }

  /// 让标记的露 / 藏跟上现在的选区、焦点：该收的行收回去，该露的行露出来（各自一段、各自一对 beginEditing /
  /// endEditing）。**输入法组字期间、有没处理完的编辑时什么都不做**——选区变化可能在一次改字还没收尾时就来，
  /// 那时动属性会让刚打的字看不见；这两种情况都会再走到 settle，由它调回来
  private func syncMarkers() {
    guard theme.markdown, !hasMarkedText(), pending.range == nil, let storage = textStorage else {
      return
    }
    for lines in NoteStyles.outdated(in: storage, shown: revealedLines()) { restyle(lines) }
  }

  /// 选区变了（打字、方向键、点击、拖选、程序设的都经过这里）。鼠标拖选的过程中（stillSelecting）不重排：
  /// 字在鼠标底下跳会选不准，松手的那一次再排
  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
  ) {
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    if !stillSelecting { syncMarkers() }
    // 兜底：没在组字、却有没收尾的编辑。正常的编辑中途也会走到这里（改字 → 选区 → didChangeText），那时排的这一次
    // 等到下一轮 didChangeText 早收过尾了，是空转（settleLeftover）；真有哪条路改了字却没有 didChangeText，靠它收
    if !hasMarkedText(), pending.range != nil {
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(settleLeftover), object: nil)
      perform(#selector(settleLeftover), with: nil, afterDelay: 0)
    }
  }

  /// 兜底的那次收尾（下一轮才跑）：还有没收尾的编辑才做事
  @objc private func settleLeftover() {
    if pending.range != nil { settle() }
  }

  /// 窗口当上 / 不再是 key（通知进来的；单测直接调——屏外的窗口不许真的当 key）：不是 key 时标记都藏着，
  /// 固定在屏幕边上、人已经去别的 App 干活的便签不该露着一行标记
  func keyChanged(_ isKey: Bool) {
    guard isKey != isInKeyWindow else { return }
    isInKeyWindow = isKey
    syncUnlessClicking()
  }

  /// 拿到焦点 / 窗口当上 key 时排标记。**用鼠标点进来的那一刻先不排**（isClick）：这时选区还是旧的，露出旧光标那一行
  /// 的标记会让字在鼠标底下挪（那一行多折出一行，点中的就不是想点的那一行了）。晚一拍再排：这一下点击要是交给了
  /// 正文（mouseDown），按着鼠标的那段时间轮不到它（系统在跟着鼠标走的那个循环里），松手、选区定了才排；
  /// 要是被系统拿去只把窗口点成了 key（不是 key 的窗口里第一下点击不给正文），下一轮就排
  private func syncUnlessClicking() {
    if isClick(NSApp.currentEvent) {
      perform(#selector(syncAfterClick), with: nil, afterDelay: 0)
    } else {
      syncMarkers()
    }
  }

  @objc private func syncAfterClick() { syncMarkers() }

  /// 这个事件是不是鼠标在正文上按下的那一下（这个窗口里、落在正文看得见的那一块上的左键按下）。点在正文外面
  /// （标题框、头部）的不算
  func isClick(_ event: NSEvent?) -> Bool {
    guard let event, event.type == .leftMouseDown, let window,
      event.windowNumber == window.windowNumber
    else { return false }
    return visibleRect.contains(convert(event.locationInWindow, from: nil))
  }

  @objc private func windowBecameKey(_ notification: Notification) { keyChanged(true) }

  @objc private func windowResignedKey(_ notification: Notification) { keyChanged(false) }

  /// 布局管理器生成字形时问到这两处：带「藏起来」属性的字当成零宽的控制字符（NoteStyles.hideGlyphs / isHidden；
  /// 为什么不用空字形见 NoteStyles 的文件头）。布局时调的代码，不碰这个视图自己的状态（mac-native §3）
  nonisolated func layoutManager(
    _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange
  ) -> Int {
    NoteStyles.hideGlyphs(
      in: layoutManager, glyphs: glyphs, properties: properties,
      characterIndexes: characterIndexes, font: font, glyphRange: glyphRange)
  }

  nonisolated func layoutManager(
    _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    NoteStyles.isHidden(at: charIndex, in: layoutManager) ? .zeroAdvancement : action
  }

  /// 引用左边的竖线（色条色，圆头）：在缩进空出来的那一条里，碰不到字；画在最上面——选中这几行时选区的底色
  /// 铺满整行，画在下面会被盖掉。连着的几行引用是一整段属性，画成一条
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawQuoteBars(in: dirtyRect)
  }

  private func drawQuoteBars(in dirtyRect: NSRect) {
    guard theme.markdown, let layoutManager, let textContainer, let storage = textStorage,
      storage.length > 0
    else { return }
    let origin = textContainerOrigin
    let glyphs = layoutManager.glyphRange(
      forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
    let dirty = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let full = NSRange(location: 0, length: storage.length)
    let width = NoteStyles.quoteBarWidth
    theme.bar.setFill()
    storage.enumerateAttribute(NoteStyles.quoteKey, in: dirty) { value, range, _ in
      guard value != nil else { return }
      // 要画的是整段引用（不只是这次要重画的那几行）：圆头才落在两端
      var quote = range
      _ = storage.attribute(
        NoteStyles.quoteKey, at: range.location, longestEffectiveRange: &quote, in: full)
      let quoted = layoutManager.glyphRange(forCharacterRange: quote, actualCharacterRange: nil)
      guard quoted.length > 0 else { return }
      let top = layoutManager.lineFragmentRect(forGlyphAt: quoted.location, effectiveRange: nil)
      let bottom = layoutManager.lineFragmentRect(
        forGlyphAt: NSMaxRange(quoted) - 1, effectiveRange: nil)
      let bar = NSRect(
        x: origin.x + textContainer.lineFragmentPadding, y: origin.y + top.minY + 1, width: width,
        height: bottom.maxY - top.minY - 2)
      NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
    }
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

  /// 输入法组字（组着的字每变一次来一次）。**撤掉组字**（给的是空的：输入法里按 Esc、把拼音退格删光）时系统的顺序是
  /// 「改字 → 选区 → didChangeText」，而 didChangeText 那一刻 hasMarkedText() 还是 true、这个调用返回了才变 false，
  /// 之后不再有 didChangeText（实测 macOS 15.7，TextKit 1）——settle 在那里什么都没做，这里补一次。不补的话攒着的
  /// 编辑一直没人收：标记冻住、改过的行不重排；先选中一段再组字、然后撤掉时，选中的字没了却没往外写
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    if !hasMarkedText() { settle() }
  }

  /// 一次编辑收尾了：没有没确认的组字时，把样式补上、把正文交出去。输入法还在组字就什么都不做——攒着的区间等确认
  /// 之后一次处理：确认会再走 didChangeText 到这里；撤掉组字不会（那一刻还算在组字），由 setMarkedText 之后那次调过来。
  /// 没有没收尾的东西时再调一遍是空转（不重排、不往外写）
  private func settle() {
    guard !hasMarkedText(), let storage = textStorage else { return }
    let text = string
    // 只退让正文变长了的那一次：正文不知怎么已经超了的时候，得删得动（同 overflows）
    if let maxBytes, text.utf8.count > maxBytes, text.utf8.count > reported.utf8.count {
      // 输入法确认的那一下 shouldChangeText 拦不了（那时还在组字）：退回组字之前的样子。
      // ponytail: 整段换回去，光标到末尾、撤销栈清空；只有贴着上限用输入法打字才走到这里，真碰上再细做
      replaceAll(with: reported)
      overflowed()
      return
    }
    if owesFullRestyle {
      _ = pending.take()
      restyleAll()
    } else if let edited = pending.take() {
      restyle(NoteStyles.lines(covering: edited, in: storage.mutableString))
    }
    // 这次编辑可能把光标带到了别的行（撤销、粘贴了几行）：原来露着的收回去，现在这一行露出来
    syncMarkers()
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
    if newWindow == nil {
      noteUndo?.removeAllActions()
      // 兜底的那次收尾还没跑的话不跑了
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(settleLeftover), object: nil)
    }
    if let window {
      let center = NotificationCenter.default
      center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
      center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  // MARK: 焦点

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else {
      keyChanged(false)
      return
    }
    // 窗口是不是 key 决定标记露不露（keyChanged）：跟着它的通知走
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification,
      object: window)
    center.addObserver(
      self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification,
      object: window)
    keyChanged(window.isKeyWindow)
    window.initialFirstResponder = self
    if takesFocusOnAppear { window.makeFirstResponder(self) }
  }

  /// 拿到焦点：选区碰到的行露出标记（用鼠标点进来的等这一下点完再排，见 syncUnlessClicking）
  override func becomeFirstResponder() -> Bool {
    guard super.becomeFirstResponder() else { return false }
    isFocused = true
    syncUnlessClicking()
    return true
  }

  /// 组字到一半焦点走了：输入法一般会自己收尾（确认或者撤掉，都会走 didChangeText）。它没收尾的话——没确认的字还挂在
  /// 这里、仓库里却没有——晚一拍替它确认掉（不当场做：输入法的那一下可能还在路上）：看得见的字和存下的字要一样
  override func resignFirstResponder() -> Bool {
    guard super.resignFirstResponder() else { return false }
    isFocused = false
    if hasMarkedText() { perform(#selector(commitStrayComposition), with: nil, afterDelay: 0) }
    // 失去焦点：标记都藏起来（还组着字的话这里不动，等它确认后 settle 来收）
    syncMarkers()
    return true
  }

  @objc private func commitStrayComposition() {
    if hasMarkedText(), window?.firstResponder !== self { unmarkText() }
  }

  // MARK: 按键

  /// 回车、Tab、Esc（输入法组字时这些键归输入法，到不了这里）。⌃↩（insertLineBreak:）当普通换行：系统给它插的是
  /// 软换行 U+2028——NSString 把它算新的一行、段落样式却按段算，后面的「> 引用」缩进不对、竖线压在字上；任务续行
  /// 那些也照常
  override func doCommand(by selector: Selector) {
    let selector =
      selector == #selector(insertLineBreak(_:)) ? #selector(insertNewline(_:)) : selector
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

  // MARK: 链接

  /// 这一点（视图自己的坐标）上有没有能打开的链接：有就给它的地址。点在字上才算（行尾、正文下面的空白不算）；
  /// 只有 http / https / mailto 的地址记在字上（NoteStyles.linkKey），别的链接只有下划线
  func link(at point: NSPoint) -> URL? {
    guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0
    else { return nil }
    let origin = textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
    let rect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
    guard rect.contains(local) else { return nil }
    let index = layoutManager.characterIndexForGlyph(at: glyph)
    return storage.attribute(NoteStyles.linkKey, at: index, effectiveRange: nil) as? URL
  }

  /// 这一下点击要打开哪个链接：只按着 ⌘、点在能打开的链接上才有；普通点击（放光标）、带别的修饰键的都是 nil
  func linkToOpen(by event: NSEvent) -> URL? {
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    else { return nil }
    return link(at: convert(event.locationInWindow, from: nil))
  }

  // MARK: 鼠标

  /// 不是 key 的面板里第一下点击就勾得上方框、⌘ 点得开链接（别的地方照文本视图自己的规矩）
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    if let event,
      box(at: convert(event.locationInWindow, from: nil)) != nil || linkToOpen(by: event) != nil
    {
      return true
    }
    return super.acceptsFirstMouse(for: event)
  }

  override func mouseDown(with event: NSEvent) {
    if isEditable, !hasMarkedText(),
      let index = box(at: convert(event.locationInWindow, from: nil))
    {
      flipBox(at: index)
    } else if let url = linkToOpen(by: event) {
      onOpenLink(url)
    } else {
      // 文本视图在这里面跟着鼠标走完一整次按下—拖动—松开才回来
      super.mouseDown(with: event)
    }
    // 这一下点完、选区定了：松手时系统已经报过一次（setSelectedRanges），点进来时晚一拍的那次也快到了
    // （syncUnlessClicking）；这里当场再对一遍——没有不对的行就什么都不做
    syncMarkers()
  }

  override func mouseMoved(with event: NSEvent) {
    if !setsCursor(at: event.locationInWindow) { super.mouseMoved(with: event) }
  }

  override func cursorUpdate(with event: NSEvent) {
    if !setsCursor(at: event.locationInWindow) { super.cursorUpdate(with: event) }
  }

  /// 这一点（窗口坐标）上的光标归不归自己定：被浮在上面的东西盖住了（「⋯」菜单）是箭头——文本视图不知道自己被盖住，
  /// 鼠标在它的范围里一动就设 I 形（2026-10-13 用户报，同 SourceTextView.FocusTextView）；没被盖住、在方框上是手指，
  /// 按着 ⌘ 在能打开的链接上也是；别的返回 false，交给文本视图自己
  private func setsCursor(at point: NSPoint) -> Bool {
    let local = convert(point, from: nil)
    if isCovered(at: point) {
      NSCursor.arrow.set()
    } else if box(at: local) != nil
      || (NSEvent.modifierFlags.contains(.command) && link(at: local) != nil)
    {
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

  /// 右键菜单里「打开链接」那一项的名字
  static let openLinkTitle = "打开链接"

  /// 右键菜单最前面加一项「任务」（同名，不写键位）；点在能打开的链接上时，它前面再多一项「打开链接」——
  /// 不靠 ⌘ 点的那条路（键盘、旁白用户）
  override func menu(for event: NSEvent) -> NSMenu? {
    // 先看点在哪，再让父类建菜单：它可能会选中点到的那个词，那一行露出标记、字就挪了。
    // 不是鼠标点出来的菜单（键盘的 ⌃↩、旁白）事件里没有点的位置：看光标所在的字
    let isMouse = [.rightMouseDown, .leftMouseDown, .otherMouseDown].contains(event.type)
    let url = isMouse ? link(at: convert(event.locationInWindow, from: nil)) : linkAtCaret()
    let menu = super.menu(for: event)
    let item = NSMenuItem(
      title: NotesWindowModel.taskTitle, action: #selector(toggleTask(_:)), keyEquivalent: "")
    item.target = self
    menu?.insertItem(item, at: 0)
    menu?.insertItem(.separator(), at: 1)
    if let url {
      let open = NSMenuItem(
        title: Self.openLinkTitle, action: #selector(openLink(_:)), keyEquivalent: "")
      open.target = self
      open.representedObject = url
      menu?.insertItem(open, at: 0)
    }
    return menu
  }

  /// 右键菜单的「打开链接」：地址是建菜单时记在那一项上的
  /// 光标（选区开头）挨着的字上有没有能打开的链接：光标在链接的字中间、或紧跟在最后一个字后面都算
  private func linkAtCaret() -> URL? {
    guard let storage = textStorage else { return nil }
    let caret = selectedRange().location
    return [caret, caret - 1].lazy
      .filter { $0 >= 0 && $0 < storage.length }
      .compactMap { storage.attribute(NoteStyles.linkKey, at: $0, effectiveRange: nil) as? URL }
      .first
  }

  @objc private func openLink(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { onOpenLink(url) }
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(toggleTask(_:)) { return isEditable }
    if item.action == #selector(openLink(_:)) { return true }
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

/// 纸上正文的滚动条（手测反馈第 3 批）：**不画轨道**（knob slot），滑块照系统的画法、跟外观走。系统设置「显示滚动条：
/// 根据鼠标或触控板自动」时，连着鼠标是常显的老式滚动条（legacy），它的轨道是一条浅色的底，画在纸色上就是「白底加
/// 滚动条」；悬浮式的鼠标停上去展开时也画这条底。正文框每换一条便签新建一次、建的那一刻取系统当时的样式，所以同一条
/// 便签切走再切回来，样子可能就变了。不画轨道之后两种样式都不露白；内容没超出时不显示（autohidesScrollers）。
/// 屏幕边缘那叠、浮动便签、全部便签窗口的正文都是这一个（NoteTextEditor）
final class NoteScroller: NSScroller {
  /// 子类默认算「和悬浮式不兼容」，滚动区会因此一直用老式的：这里只是不画轨道，悬浮式照常
  override class var isCompatibleWithOverlayScrollers: Bool { true }

  /// 轨道不画：后面透出来的就是纸
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

  /// 老式滚动条自认不透明（它本来铺满轨道），不画轨道就得让后面的纸画出来
  override var isOpaque: Bool { false }
}

/// 正文编辑器的 SwiftUI 包装：滚动区铺满给它的大小、滚动条贴右边（不画轨道的 NoteScroller，内容没超出时不显示），
/// 文字的左右内缩在 horizontalInset 里（另有 NSTextView 自己的 lineFragmentPadding 5）
struct NoteTextEditor: NSViewRepresentable {
  let note: Note
  let fontSize: CGFloat
  let horizontalInset: CGFloat
  /// 是「该拿焦点的那条」时给第几次要：挂进窗口那一刻拿一次，之后这个数每变一次再拿一次；nil = 不归它拿
  var focusRequest: Int?
  /// 这条便签的撤销栈（只在建的时候取一次，见 NoteTextView.noteUndo）
  var undo: UndoManager?
  /// 设置 › 便签「Markdown 样式」开没开
  let markdown: Bool
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
    // 先给一个像样的大小（SwiftUI 摆的时候再改成真的；正文框跟着滚动区的宽走，autoresizingMask）：宽是 0 的文本视图
    // 一挂进窗口就按「一个字一行」把整篇排一遍，5 KB 的正文要几十毫秒——换一条便签时最大的一块（Debug，手测反馈
    // 第 3 批屏外量的）
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    scroll.drawsBackground = false
    scroll.verticalScroller = NoteScroller()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    view.frame = NSRect(origin: .zero, size: scroll.contentSize)
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
    view.setPaper(NotePaper.of(note), fontSize: fontSize, markdown: markdown)
    view.setText(note.body)
    // 选中文字的底色是强调色 0.28（不露系统蓝；读了 Style.brand，设置里换了强调色这里会重跑）
    view.selectedTextAttributes = [
      .backgroundColor: NSColor(Style.brand).withAlphaComponent(0.28)
    ]
  }
}
