// 便签专用的正文编辑器（PLAN §10「便签」第 5、6 批；规矩在 mac-overlay-panel §3 §12，长相在 mac-whisker-notes.mdc）：
// 全部便签窗口和屏幕边缘那叠的正文都是它（NoteFields.swift 的 NoteBodyField 包着）；快速记一条照旧用 SourceTextView。
// - **显式搭的 TextKit 1**（自己建 NSTextStorage → NSLayoutManager → NSTextContainer 再交给文本视图）：Markdown 的标记
//   靠 NSLayoutManager 把字形藏起来，普通 NSTextView 拿到的是 TextKit 2，那一招不灵。只拿着文本视图就够：
//   实测（macOS 15.7，独立小程序）存储跟着视图活、跟着视图放，不用另存一份，也就没有「把属性置空」那种事。
// - 纯文本。样式（NoteStyles）是显示时加的属性：只改属性、不改字、不进撤销栈、不动选区；每次编辑只重排受影响的行。
//   **整段换字（新建的正文框第一次拿到字、别处改了这条）只当场排开头一屏**（eagerStyleLength 个字，扩到整行），其余的在
//   后面几轮一段段补（styleRest；手测反馈第 6 批：「切到文字多的便签时过渡还是会卡一下」，50 KB 的正文整篇排一遍样式
//   -O 约 24 ms，是切换那一下里最大的一块）。补的那一段守着同样的红线（组字期间、有没处理完的编辑时不动），排法就是
//   普通的重排——和整篇排一遍逐字一样。没排过的字认得出来：排过的每个字都记着这一行的主字体（lineFontKey），没排过的没有。
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
// - **行高定死、字和插入点居中**（手测反馈第 4 批：「几乎没有间距，视觉上看起来非常累」）：每一行的行高是段落样式
//   定死的（NoteStyles.apply，设置 › 便签「行距」三档）；字在行里怎么放由布局管理器的代理定（shouldSetLineFragmentRect →
//   NoteStyles.centerLine）：基线按这一行的主字体居中，「用到的那一块」（usedRect）收成字那么高——插入点、输入法候选窗
//   （firstRect）、选区的头尾两行都按它，所以插入点只有字那么高、不跟着撑高的行走。没重写 drawInsertionPoint：
//   macOS 14 起插入点是系统的 NSTextInsertionIndicator 画的，改在源头（usedRect）两条路都管——单测量的是布局管理器
//   给插入点的矩形（零长度的 rectArray、firstRect），屏外的窗口不当 key、不画插入点，真画出来的没看过。选区：头一行从字的上沿起、
//   末一行到字的下沿，中间几行连成一片（同系统编辑器）。空着的最后一行不经过代理，由 NoteLayoutManager 照样收。
// - **代码块**（三个反引号围起来的几行）：等宽、按原文，底是一块圆角矩形（drawBackground，画在字和选区下面）；
//   块里回车不续列表、Tab 是制表符、「- [ ]」加空格不转换、⌘T 和加标记的键不动、方框点了不勾。它是唯一跨行的语法：
//   一次编辑收尾时，除了改过的行，还重排角色变了的行（restyleEdited），保证和整篇排一遍逐字一样。
// - ⌘B ⌘I ⇧⌘X ⌘E 加粗体、斜体、删除线、行内代码（performKeyEquivalent，焦点在自己身上才接；规则在
//   NoteMarkdown.toggle）；右键菜单里有「格式」。选中一段字粘贴一个网址 = 粘成链接（paste → NoteMarkdown.linkPaste）。
//   改字都走 perform（shouldChangeText → 改 → didChangeText）：一步撤销、照常重排和写出去。
// - 链接：⌘ 点才打开（只有 http / https / mailto 的地址记在字上），普通点击照常放光标；不用系统的 .link 属性。
//   右键点在能打开的链接上，菜单最前面多一项「打开链接」——不靠 ⌘ 点的那条路（键盘、旁白用户）。
// - 任务（NoteTasks，纯函数；这里只管调）：⌘T 切换、点方框打勾（不是 key 的面板里第一下点击就生效）、回车续行和
//   空项退出、列表行 Tab / ⇧Tab 缩进、打「- [ ]」加空格自动转换。改字都走 shouldChangeText → 改 → didChangeText：
//   进撤销栈、照常重排和写出去。
// - 按键照 mac-overlay-panel §3：回车、Tab、Esc 走 doCommand(by:)（输入法组字时这些键归输入法，到不了这里）；
//   ⌃↩（insertLineBreak:）弹正文的右键菜单（第 8 批：键盘用户选任务状态 / 文字颜色）；没处理的
//   cancelOperation: 交给窗口；不装按键监听。
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
// 手测反馈第 6 批量过（50 KB 的正文，屏外，-O）：首屏排版开 / 不开 10.2 / 10.8 ms、排完整篇 31.4 / 35.9 ms——正文框从顶上
// 开始，连续排版本来也只排到这一屏；切换卡的大头是整篇上样式，所以改的是「先排一屏」，没开它（要核对的地方多：
// edgeBand、box(at:)、link(at:)、scrollRangeToVisible、firstRect、插入点、查找条）。
// 一整段很长又中英混排时 TextKit 1 超线性（实测 Release、M3 Air）——64 KB 不换行的一段，打一个字约 2.3 s（关掉
// Markdown 约 0.9 s、原生 TextKit 1 约 0.45 s）；贴一行很长的日志 / JSON 会碰到。
// ponytail: 鼠标停在链接上不动、这时才按下 / 松开 ⌘，手指光标要等鼠标再动一下才换（没接 flagsChanged）。
// ponytail: 焦点在查找条里时正文不算拿着焦点，标记都藏着——搜到的字正好在藏着的标记里（链接的地址）时看不见高亮。
// 要看得见就在查找条开着时把匹配所在的行也算进 revealedLines。
// - 软换行（U+2028）和 U+0085 进了文本存储就换成普通换行（unifyLineBreaks，便签未来计划 A）：NSString 把它们算新的
//   一行、TextKit 1 却不当分段，段落样式按段算——后面那一行用的是上一段的行高和缩进（「> 引用」缩进不对、竖线压在字上，
//   「# 标题」的大字挤在正文的行高里）。从网页、文档里贴进来的字常带它们（第 8 批起 ⌃↩ 弹右键菜单，自己打不出来）。
// ponytail: 只在编辑器里换。仓库里已经存着软换行的正文（快速记一条里贴进来的、导入的）打开就换掉、下次改动时存回去，
//   在那之前便签墙卡片照旧按段排（NoteStyles.center 把字夹在自己的行片段里）；要全对就在 Note.sanitized(text:) 里也换。

import AppKit
import SwiftUI
import Synchronization

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
  /// 插图被拒（太大 / 像素太多 / 读不出来）、存图没成时说什么：刘海岛的**标题 + 说明**分开传
  /// （NoteBodyField 接上 model 手里的 island；单测里数次数、看两句）
  var onImageProblem: (String, String) -> Void = { _, _ in }
  /// 这条便签的图片目录（NoteStore.images 给的；nil = 图都画占位框、粘进来的存不了）。建附件、存图都用它
  var imageStore: NoteImageStore?
  /// 粘贴 / 拖进来的图存进目录时要等的这一刻里，正文变了没有（变了就插在当前光标处，见 NoteTextView+Images）
  var pendingImages: [NoteImages.Image] = []
  /// 组字期间欠着的插图插在哪（nil = 当前光标；选中的那一段会被换掉）
  var pendingImagesAt: NSRange?
  /// 鼠标停在哪张图上（把手在悬停时也显示）
  var hoveredImage: Int?
  /// 正文里有没有图片附件（鼠标动、改字这几条热路径先看它，省得每次都问排版）
  private var hasImages = false
  /// 正拖着把手改宽度的那张图（nil = 没在拖）
  var widthDrag: WidthDrag?
  /// 拖的时候按了 Esc（松手不写进正文，回原来的大小）
  var isWidthDragCancelled = false
  /// 拖把手的按键监听（Esc 取消；装了就卸）
  var widthMonitor: Any?

  /// 正拖着把手改宽度：哪一张图、它的 cell、按下时多宽、按下时指针在哪、现在多宽
  struct WidthDrag {
    var index: Int
    var cell: NoteImageAttachmentCell
    var startWidth: CGFloat
    var startX: CGFloat
    var current: CGFloat
  }

  /// 现在的纸色，和它连同字号、Markdown 开关定下来的字体和颜色（变了才整篇重排）
  private var paper: NotePaper?
  /// 这条便签的颜色下标（图片的占位框、缩略图的底用）
  private var paperIndex = 0
  private var theme = NoteStyles.Theme()
  /// 照现在的正文认出来的代码块（Markdown 关着时是空的）：改了字、收尾时（settle）重认，整篇重排时也是。
  /// 没在组字、没有没处理完的编辑时，它就是现在这篇正文的
  private var blocks: [NoteMarkdown.CodeBlock] = []
  /// 上次交出去 / 拿进来的全文：外面再给同样的就不动；输入法确认之后超了上限退回它。
  /// **是存的形式**（图片是令牌，不是附件字符）：和外面比、算上限都按它
  var reported = ""
  /// reported 有多少字节（UTF-8；一个附件按它的令牌那么长算）。打字时每次改完重算一遍，
  /// shouldChangeText 里判断超没超直接用（不在每次按键时把整篇走一遍）
  var reportedBytes = 0
  /// 改过字、还没重排的那一段
  private var pending = NoteStyles.Pending()
  /// 组字期间来了要整篇重排的事（换纸色、字号、Markdown 开关）：先欠着，确认之后补
  private var owesFullRestyle = false
  /// 自己是不是第一响应者、所在的窗口是不是 key：两样都是，选区碰到的行才露出 Markdown 的标记
  private var isFocused = false
  private var isInKeyWindow = false
  /// 字上有没有露着的标记（第 8 批的性能：颜色让每一行多出两段属性，`outdated` 每挪一次光标要把整篇过一遍；
  /// 从没露过标记时（没焦点 / 不是 key）直接跳过，别为查「有没有该藏的」扫整篇）
  private var hasShownMarkers = false

  /// 点方框的范围比那个字四周放宽多少
  static let boxSlop = CGSize(width: 4, height: 3)
  /// 整段换字时当场排多少个字（UTF-16，扩到整行）：最高的正文框一屏五六十行，密排的中文一行四五十个字，4000 个字排得满；
  /// 其余的在后面几轮一段段补，一段 restChunk 个字（-O 约 3 ms）。随机探针、单测把它们改小（只改自己那个编辑器的），
  /// 好走到「还没排完」的那段路
  var eagerStyleLength = 4000
  var restChunk = 8000

  /// 建一个：TextKit 1 的栈在这里搭
  static func make() -> NoteTextView {
    let storage = NSTextStorage()
    let layout = NoteLayoutManager()
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

  /// 纸色、字号、Markdown 样式开没开、行距（换了才动）：基础字体和墨色、插入点，整篇重排。
  /// paperIndex：这条便签的颜色下标（图片的占位框画在纸上，要按当前外观取纸色）
  func setPaper(
    _ paper: NotePaper, fontSize: CGFloat, markdown: Bool, spacing: NoteStyles.Spacing,
    paperIndex: Int = 0
  ) {
    guard
      paper != self.paper || fontSize != theme.font.pointSize || markdown != theme.markdown
        || spacing != theme.spacing
    else { return }
    self.paper = paper
    self.paperIndex = paperIndex
    theme = NoteStyles.Theme(
      paper: paper, fontSize: fontSize, markdown: markdown, spacing: spacing)
    // 空着的最后一行（正文末尾的换行后面）按打进去的字排：布局管理器那边读不到 typingAttributes，告诉它字的上下沿
    (layoutManager as? NoteLayoutManager)?.extraLine.withLock {
      $0 = (theme.font.ascender, theme.font.descender)
    }
    // 纸上的输入框插入点用墨色：强调色选黄时在柠檬色的纸上看不见
    insertionPointColor = theme.ink
    // 空的正文：下面的整篇重排没有字可排，空着的那一行（额外行片段，按 typingAttributes 排）不会跟着重排——换了字号、
    // 行距它还是旧的高、插入点不挪。让布局管理器把整个容器重排一次（空的，就只有这一行）
    if textStorage?.length == 0, let textContainer {
      layoutManager?.textContainerChangedGeometry(textContainer)
    }
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
  /// （手测反馈第 3 批屏外量的）。标记先都藏着，换完由 syncMarkers 按焦点和选区露出该露的那几行。
  /// **只当场排开头一屏**（eagerStyleLength 个字，扩到整行）：其余的先铺基础样式（字号、墨、行高：排版不至于差太多），
  /// 不记主字体，下一轮起一段段补上（styleRest）。
  /// 图片：令牌换成附件字符（一个令牌一个字），文件头读出来的宽高在这一刻读好、缓存起来（布局回调里不读盘）
  private func replaceAll(with text: String) {
    reported = text
    reportedBytes = text.utf8.count
    // 建的时候就铺上基础样式（比建好再铺省一遍）：开头那一屏下面再排，其余的就这么等着补
    let base: [NSAttributedString.Key: Any] = [
      .font: theme.font, .foregroundColor: theme.ink, .paragraphStyle: theme.baseParagraph,
    ]
    let styled = NSTextStorage(
      attributedString: NoteImageAttachment.editorString(from: text, base: base) { image in
        self.makeAttachment(for: image)
      })
    blocks = theme.markdown ? NoteMarkdown.codeBlocks(in: styled.mutableString) : []
    let head = styled.mutableString.lineRange(
      for: NSRange(location: 0, length: min(eagerStyleLength, styled.length)))
    let rest = NSRange(location: NSMaxRange(head), length: styled.length - NSMaxRange(head))
    NoteStyles.apply(
      to: styled, lines: head, theme: theme, shown: [], blocks: blocks,
      availableWidth: availableWidth)
    textStorage?.setAttributedString(styled)
    hasImages = styled.string.utf16.contains(0xFFFC)
    _ = pending.take()
    owesFullRestyle = false
    hasShownMarkers = false
    markWholeViewDirty()
    syncMarkers()
    if isFocused, isInKeyWindow { updateInsertionPointStateAndRestartTimer(true) }
    undoManager?.removeAllActions()
    // 补样式的这几轮里不在空闲时往下排版：补一段就把那一段的版作废一次，连续排版下它后面排好的也跟着重排，边补边排
    // 白排好几遍（屏外量的：50 KB 切过去之后 1.5 秒里主线程忙了 1.2 s）。补完再一口气往下排（styleRest 末尾）
    layoutManager?.backgroundLayoutEnabled = rest.length == 0
    restHint = rest.location
    if rest.length > 0 { scheduleRest(after: 0) }
  }

  /// 一张图的附件（令牌 → 附件字符时建）：文件在哪、宽高多少、占位框画在哪张纸上
  func makeAttachment(for image: NoteImages.Image) -> NoteImageAttachment {
    let store = imageStore
    let url = store?.url(for: image.id, ext: image.ext) ?? URL(fileURLWithPath: "/")
    let metrics = store?.size(of: image.id, ext: image.ext)
    let attachment = NoteImageAttachment(
      image: image, url: url, metrics: metrics, paper: paperIndex)
    let cell = NoteImageAttachmentCell(
      image: image, url: url, metrics: metrics, paper: paperIndex)
    attachment.attachmentCell = cell
    cell.attachment = attachment
    cell.view = self
    return attachment
  }

  /// 正文的可用宽（排版时算没记宽度的图显示多大）：正文框宽去掉两边的内缩和文本容器的内边距。
  /// 还没摆好（宽是 0）时给一个像样的数（同 NoteTextEditor.makeNSView 里给的那个）
  var availableWidth: CGFloat {
    guard let textContainer else { return 320 }
    let width = textContainer.size.width - textContainer.lineFragmentPadding * 2
    return width > 60 ? width : 320
  }

  /// 还没排过的那些行（replaceAll 只当场排了开头一屏）一段段补上：每轮一段（restChunk 个字，扩到整行），补完一段让
  /// 主线程转一轮（画一帧、接按键）。守着改属性的红线：组字期间、有没处理完的编辑时不动，过一会儿再看（不在每一轮里
  /// 空转）。排的就是普通的重排（restyle：和整篇排一遍逐字一样——代码块照现在的正文认，露不露标记照现在的焦点和选区）。
  /// 中途有了编辑：改过的行由那次收尾排（restyleEdited），没排过的照样留给这里；整篇重排（换纸色、字号…）一次全排完
  @objc private func styleRest() {
    guard let storage = textStorage, let start = nextUnstyled(in: storage) else {
      layoutManager?.backgroundLayoutEnabled = true
      return
    }
    guard !hasMarkedText(), pending.range == nil else { return scheduleRest(after: 0.1) }
    // 从第一个没排过的字起往后一段（中间夹着编辑时排过的行也一起再排一遍：结果一样）
    let lines = storage.mutableString.lineRange(
      for: NSRange(location: start, length: min(restChunk, storage.length - start)))
    restyle(lines)
    restHint = NSMaxRange(lines)
    if nextUnstyled(in: storage) != nil {
      scheduleRest(after: 0)
    } else {
      layoutManager?.backgroundLayoutEnabled = true
    }
  }

  /// 补样式补到哪了（下一段从这往后找）：只是个起点，编辑挪了位置也不要紧——往后找不到再从头找一遍
  private var restHint = 0

  private func nextUnstyled(in storage: NSTextStorage) -> Int? {
    Self.unstyled(in: storage, from: min(restHint, storage.length)) ?? Self.unstyled(in: storage)
  }

  private func scheduleRest(after delay: TimeInterval) {
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(styleRest), object: nil)
    perform(#selector(styleRest), with: nil, afterDelay: delay)
  }

  /// 从 start 往后第一个还没排过的字：排过的每个字都记着这一行的主字体（NoteStyles.apply 整行铺回基础样式时写的
  /// lineFontKey），没排过的没有。都排过了是 nil。按属性的段一段段跳（不用 enumerate 的闭包：每段一次，几万段时
  /// Debug 下光闭包就要几毫秒）
  static func unstyled(in storage: NSTextStorage, from start: Int = 0) -> Int? {
    var location = start
    while location < storage.length {
      var range = NSRange()
      if storage.attribute(NoteStyles.lineFontKey, at: location, effectiveRange: &range) == nil {
        return location
      }
      location = max(NSMaxRange(range), location + 1)
    }
    return nil
  }

  /// 还有没排过的字（整段换字之后、后面几轮补完之前）
  var isStylingRest: Bool { textStorage.map { Self.unstyled(in: $0) != nil } ?? false }

  // MARK: 样式

  /// 打进去的字永远是基础样式，不跟光标前面那个字走（它可能是方框——另一种字体，或者做完的任务——划线、变淡）；
  /// 组字中的字也按它画。该有的样式等这次编辑收尾了由重排补。**段落那几样跟着光标所在的那一行走**（段落样式、
  /// 主字体、代码块的角色、**这一行有没有图**）：一行的段落样式看的是行首那个字，组字期间不重排——在代码块、引用、
  /// 标题的行首组字时，组着的字要是带着正文的段落样式，整行的行高和缩进当场就变了、确认之后再变回来（跳两下）。
  /// 图片行行首组字时也要带上 imageLineKey：不然布局代理认不出这一行是图片行，按字体在高行里居中，
  /// 基线跑到中间、图往上跳半个图高（F17）。空着的最后一行是正文的
  override var typingAttributes: [NSAttributedString.Key: Any] {
    get {
      var attributes: [NSAttributedString.Key: Any] = [
        .font: theme.font, .foregroundColor: theme.ink, .paragraphStyle: theme.baseParagraph,
        NoteStyles.lineFontKey: theme.font,
      ]
      if let storage = textStorage, selectedRange().location < storage.length {
        let start = storage.mutableString.lineRange(
          for: NSRange(location: selectedRange().location, length: 0)
        ).location
        for key in [
          .paragraphStyle, NoteStyles.lineFontKey, NoteStyles.roleKey, NoteStyles.imageLineKey,
        ] {
          if let value = storage.attribute(key, at: start, effectiveRange: nil) {
            attributes[key] = value
          }
        }
      }
      return attributes
    }
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
    blocks = theme.markdown ? NoteMarkdown.codeBlocks(in: storage.mutableString) : []
    restyle(NSRange(location: 0, length: storage.length))
  }

  /// 把这几行（整行）的样式重排一遍。**调它的地方都得先确认没在组字**
  func restyle(_ lines: NSRange) {
    guard let storage = textStorage else { return }
    let shown = revealedLines()
    if !shown.isEmpty { hasShownMarkers = true }
    NoteStyles.apply(
      to: storage, lines: lines, theme: theme, shown: shown, blocks: blocks,
      availableWidth: availableWidth)
    markWholeViewDirty()
    // 标记露出 / 收起、字体变了之后这一行的字会左右挪：插入点跟着重算
    if isFocused, isInKeyWindow { updateInsertionPointStateAndRestartTimer(true) }
  }

  /// 正文框变宽变窄了：有图片的行按新的可用宽重排（没记宽度的图跟着变，记了宽度的超出时缩到可用宽）。
  /// **不在这里当场重排**：宽度变化可能发生在一次排版中间（老式滚动条出现、正文框变窄 15 pt），
  /// 当场 setAttributes 会把这一遍排出来的版作废；组字中更是不能动属性。记个标志，下一轮再排（F18）
  override func setFrameSize(_ newSize: NSSize) {
    let before = textContainer?.size.width ?? 0
    super.setFrameSize(newSize)
    let after = textContainer?.size.width ?? 0
    guard abs(after - before) > 0.5 else { return }
    guard hasImages || hoveredImage != nil else { return }
    owesWidthRestyle = true
    scheduleWidthRestyle()
  }

  /// 宽变了还没重排（组字中先欠着，确认之后 settle 里补）
  private var owesWidthRestyle = false

  private func scheduleWidthRestyle() {
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(widthRestyle), object: nil)
    perform(#selector(widthRestyle), with: nil, afterDelay: 0)
  }

  /// 宽变了的那次重排（下一轮跑）：组字中、还有没处理完的编辑时先欠着，等 settle
  @objc func widthRestyle() {
    guard owesWidthRestyle, !hasMarkedText(), pending.range == nil else { return }
    owesWidthRestyle = false
    restyleImageLines()
  }

  /// 有图片的那几行重排一遍（整行，不相邻的各自一段）
  private func restyleImageLines() {
    guard !isRestylingImages, !hasMarkedText(), pending.range == nil, let storage = textStorage,
      storage.length > 0
    else { return }
    let lines = imageLines(in: storage)
    guard !lines.isEmpty else { return }
    isRestylingImages = true
    defer { isRestylingImages = false }
    for line in NoteStyles.merged(lines) { restyle(line) }
  }

  private var isRestylingImages = false

  /// 正文里有图片附件的那几行（整行）：宽变了要重排它们
  private func imageLines(in storage: NSTextStorage) -> [NSRange] {
    var lines: [NSRange] = []
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
      value, range, _ in
      guard value is NoteImageAttachment else { return }
      lines.append(
        storage.mutableString.lineRange(for: NSRange(location: range.location, length: 0)))
    }
    return lines
  }

  /// 引用的竖线画在字的外面（左边空出来的那一条）：这几行排版变了不一定会带着那一条重画，整个视图标成要重画
  /// （真画的只有看得见的那一块）。**不许顺手排版**（avoidAdditionalLayout）：文本视图的 needsDisplay = true 会为了算
  /// 「这一块里有哪些字」当场把整个视图那么高的字全排一遍——换一条便签时它占了正文框建出来的九成多（5 KB 的正文，
  /// Debug 约 50 ms；手测反馈第 3 批 sample 出来的）。排版留给真要画的那一刻
  private func markWholeViewDirty() {
    setNeedsDisplay(bounds, avoidAdditionalLayout: true)
  }

  /// 一次编辑收尾时重排受影响的行：改过的那几行；代码块照现在的正文重认一遍，角色变了的行（围栏配上 / 拆开，
  /// 一整块都变——代码块是唯一跨行的语法）；再各往上下带一行（引用块的段前段后看上下两行是不是引用）。不相邻的几段
  /// 各自重排（各自一对 beginEditing / endEditing）。这样排出来的和整篇排一遍逐个属性一样（单测
  /// NoteTextViewTests.codeBlocksInTheEditor / quoteMarginsFollowNeighbors，随机探针 NoteEditorFuzzTests 每步逐字比）。
  /// ponytail: 每次收尾都把整篇的围栏行重认一遍（一行一行看行首）；有代码块时还把字上记着角色的那几段过一遍。
  /// 实测数在 docs/archive/PLAN-notes.md「手测反馈第 4 批」；真卡了改成只在改到的行里有、或改之前有围栏时才重认
  private func restyleEdited(_ edited: NSRange, in storage: NSTextStorage) {
    let text = storage.mutableString
    let previous = blocks
    blocks = theme.markdown ? NoteMarkdown.codeBlocks(in: text) : []
    var changed = [NoteStyles.lines(covering: edited, in: text)]
    // 前后都没有代码块：字上也就没有记着的角色（改过的行另算），不用找
    if !previous.isEmpty || !blocks.isEmpty {
      changed += NoteStyles.roleChanges(in: storage, blocks: blocks)
    }
    for lines in NoteStyles.merged(changed.map { NoteStyles.neighborLines($0, in: text) }) {
      restyle(lines)
    }
  }

  /// 选区碰到的行里有没有代码块的行（围栏行也算）：这些行里加标记、续列表、切任务都不做（块里按原文）
  private func touchesCodeBlock(_ selection: NSRange) -> Bool {
    guard !blocks.isEmpty, let text = textStorage?.mutableString,
      NSMaxRange(selection) <= text.length
    else { return false }
    let lines = text.lineRange(for: selection)
    return blocks.contains {
      NSLocationInRange(lines.location, $0.range) || NSLocationInRange($0.range.location, lines)
    }
  }

  // MARK: Markdown 的标记：露在哪几行

  /// 现在该露出标记的行（整行的区间，选区有几段就是几段）：选区碰到的每一行——前提是 Markdown 开着、能编辑、
  /// 正文框拿着焦点、窗口是 key；不然一行都不露
  private func revealedLines() -> [NSRange] {
    // 颜色不看 Markdown 开关（第 8 批）：关着时这一行也要露出颜色的标记，所以这里不判 theme.markdown
    guard isEditable, isFocused, isInKeyWindow,
      let text = textStorage?.mutableString
    else { return [] }
    return selectedRanges.map { text.lineRange(for: $0.rangeValue) }
  }

  /// 让标记的露 / 藏跟上现在的选区、焦点：该收的行收回去，该露的行露出来（各自一段、各自一对 beginEditing /
  /// endEditing）。**输入法组字期间、有没处理完的编辑时什么都不做**——选区变化可能在一次改字还没收尾时就来，
  /// 那时动属性会让刚打的字看不见；这两种情况都会再走到 settle，由它调回来
  private func syncMarkers() {
    guard !hasMarkedText(), pending.range == nil, let storage = textStorage else {
      return
    }
    let shown = revealedLines()
    guard !shown.isEmpty || hasShownMarkers else { return }
    // ponytail: 每挪一次光标都把整篇的 shownKey 过一遍（让系统把同值的段并起来，NoteStyles.outdated；1 MB 每行有颜色
    // -O 3.5 ms、没颜色 1.4 ms）。试过只排「上次 / 这次露着的两行」，随机探针抓出标记露错行（编辑把行挪走之后位置对不上），
    // 回退了。再要快：让 shown 的行号跟着 textStorage 的 didProcessEditing 一起挪（记行不记位置），再走快路
    for lines in NoteStyles.outdated(in: storage, shown: shown) { restyle(lines) }
    hasShownMarkers = !shown.isEmpty
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

  /// 排好一个行片段时问到这里：行高是段落样式定死的，字按这一行的主字体在里面竖直居中，「用到的那一块」（插入点、
  /// 选区的上下沿按它）收成字那么高（NoteStyles.centerLine）。布局时调的代码，同上
  nonisolated func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
    baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer,
    forGlyphRange glyphRange: NSRange
  ) -> Bool {
    NoteStyles.centerLine(
      in: layoutManager, glyphRange: glyphRange, rect: lineFragmentRect,
      used: &lineFragmentUsedRect.pointee, baseline: &baselineOffset.pointee)
  }

  /// 引用左边的竖线（色条色，圆头）：在缩进空出来的那一条里，碰不到字；画在最上面——选中这几行时选区的底色
  /// 铺满整行，画在下面会被盖掉。连着的几行引用是一整段属性，画成一条
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawQuoteBars(in: dirtyRect)
    drawImageChrome(in: dirtyRect)
  }

  /// 代码块的底画在字和选区的下面（文本视图先画自己的底、再让布局管理器画选区和字）
  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    drawCodeBlocks(in: rect)
  }

  /// 第 index 个字那一行占的那一条：行片段去掉段前段后（行高定死的那么高，字在里面居中）
  private func band(ofCharacterAt index: Int) -> NSRect? {
    guard let layoutManager, let storage = textStorage, index >= 0, index < storage.length,
      let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil)
        as? NSParagraphStyle
    else { return nil }
    var glyphs = NSRange()
    let line = layoutManager.lineFragmentRect(
      forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: &glyphs)
    let before = NoteStyles.spacingBefore(
      at: layoutManager.characterIndexForGlyph(at: glyphs.location), style: style,
      in: storage.mutableString)
    let height = style.minimumLineHeight > 0 ? style.minimumLineHeight : line.height - before
    return NSRect(x: line.minX, y: line.minY + before, width: line.width, height: height)
  }

  /// 代码块的底：一块一个圆角矩形（墨的 8%，同行内代码的底；圆角 control），从开头那行的那一条顶上到收尾那行的
  /// 那一条底下、再往上下各多出 codePadding，左右是正文那一栏（块里的字再往里缩 codeInset）。块按字上记着的角色找（roleKey，跟着字走：
  /// 组字、编辑到一半时也和字的位置对得上）。
  /// **块的头 / 尾在这次要画的字外面时不问它的行片段**（问了，布局管理器就得把版一直排到那里）：底直接画出这次要画的
  /// 那一块（dirtyRect）外面一点，那一头的圆角这次本来就画不到；头尾真在要画的字里才按行片段算（edgeBand）。
  /// ponytail: 实测（屏外 -O 小程序，没进仓库，M3 Air）1.2 MB 整篇一个代码块：新建的
  /// 正文框第一次画顶上一屏 511–545 → 3.4–3.9 ms，版排到中间时在那里打一个字再画光标那一条 254 → 1.3 ms（没有围栏
  /// 1.8 / 0.6 ms）；整篇一个引用块的竖线同样 666–671 → 2.9 ms、332–334 → 1.3 ms。块里的字照旧要排到这一屏为止
  /// （连续排版，见文件头）；块很长时每画一次还要按字上的角色找一遍整块（codeBlock(around:)，只看属性、不排版）
  private func drawCodeBlocks(in dirtyRect: NSRect) {
    guard theme.markdown, let layoutManager, let textContainer, let storage = textStorage,
      storage.length > 0
    else { return }
    let origin = textContainerOrigin
    // 多问上下各 codePadding：只重画块外那一小条时，伸出去的那点也画得上
    let glyphs = layoutManager.glyphRange(
      forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        .insetBy(dx: 0, dy: -NoteStyles.codePadding),
      in: textContainer)
    let dirty = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let padding = textContainer.lineFragmentPadding
    let radius = Style.Radius.control
    // 头尾在要画的字外面时，底伸出 dirtyRect 多远：盖过圆角和多出的 codePadding
    let overshoot = radius + NoteStyles.codePadding + 1
    // 上一块到哪为止：一块只画一次
    var drawn = 0
    theme.codeFill.setFill()
    storage.enumerateAttribute(NoteStyles.roleKey, in: dirty) { value, range, _ in
      guard value != nil, range.location >= drawn,
        let block = codeBlock(around: range.location, in: storage),
        let edges = edgeBand(of: block, dirty: dirty, rect: dirtyRect, overshoot: overshoot)
      else { return }
      drawn = NSMaxRange(block)
      let rect = NSRect(
        x: origin.x + padding, y: edges.top - NoteStyles.codePadding,
        width: textContainer.size.width - padding * 2,
        height: edges.bottom - edges.top + NoteStyles.codePadding * 2)
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
  }

  /// 一整块（代码块、一段引用：字的区间）在视图里从哪到哪（头一行那一条的顶、末一行那一条的底）：头 / 尾在这次要画的字
  /// （dirty）里才问它的行片段，不在就是 dirtyRect 的边再往外 overshoot——不为画一块底把版排到这一屏外面去。
  /// 问行片段问不到（不该有）给 nil
  private func edgeBand(of block: NSRange, dirty: NSRange, rect: NSRect, overshoot: CGFloat)
    -> (top: CGFloat, bottom: CGFloat)?
  {
    let origin = textContainerOrigin
    var top = rect.minY - overshoot
    var bottom = rect.maxY + overshoot
    if NSLocationInRange(block.location, dirty) {
      guard let band = band(ofCharacterAt: block.location) else { return nil }
      top = origin.y + band.minY
    }
    if NSLocationInRange(NSMaxRange(block) - 1, dirty) {
      guard let band = band(ofCharacterAt: NSMaxRange(block) - 1) else { return nil }
      bottom = origin.y + band.maxY
    }
    return (top, bottom)
  }

  /// 第 index 个字所在的代码块（整块的字的区间）：照字上记着的角色往前找到开头的围栏行、往后找到收尾的围栏行
  /// （角色 开头 1 < 块里 2 < 收尾 3：往前只认更小的、往后只认更大的，挨着的两块分得开）。不在块里给 nil
  private func codeBlock(around index: Int, in storage: NSTextStorage) -> NSRange? {
    let full = NSRange(location: 0, length: storage.length)
    func run(at position: Int) -> (role: Int, range: NSRange)? {
      guard position >= 0, position < storage.length else { return nil }
      var range = NSRange()
      guard
        let role = storage.attribute(
          NoteStyles.roleKey, at: position, longestEffectiveRange: &range, in: full) as? Int
      else { return nil }
      return (role, range)
    }
    guard var first = run(at: index) else { return nil }
    var last = first
    while let previous = run(at: first.range.location - 1), previous.role < first.role {
      first = previous
    }
    while let next = run(at: NSMaxRange(last.range)), next.role > last.role { last = next }
    return NSRange(
      location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
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
      // 头尾两行的那一条（不含引用块上下的留白）；头尾在这次要画的字外面时不问（同代码块的底，edgeBand）
      guard quote.length > 0,
        let edges = edgeBand(of: quote, dirty: dirty, rect: dirtyRect, overshoot: width)
      else { return }
      let bar = NSRect(
        x: origin.x + textContainer.lineFragmentPadding, y: edges.top + 1, width: width,
        height: edges.bottom - edges.top - 2)
      NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
    }
  }

  /// 文本存储每次改字、处理之前（打字、粘贴、拖进来、撤销、输入法组字、外面换进来的正文都经过这里）：改到的那一段里的
  /// 软换行换成普通换行（unifyLineBreaks）。系统允许在这一步改字（NSTextStorageDelegate 的文档）
  nonisolated func textStorage(
    _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    Self.unifyLineBreaks(in: textStorage, range: editedRange)
  }

  /// range 里的 U+2028（软换行）、U+0085 换成 \n：一个字换一个字，长度不变——撤销（按区间记的）、选区、攒着的编辑区间
  /// 都不受影响，字上的属性跟着原来那个字。没有的时候只是两次查找。系统在改字的那个调用里同步调过来，只动传进来的
  /// 文本存储（同布局代理那几个，mac-native §3）
  nonisolated static func unifyLineBreaks(in storage: NSTextStorage, range: NSRange) {
    let text = storage.mutableString
    for separator in ["\u{2028}", "\u{85}"] {
      var search = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
      while search.length > 0 {
        let found = text.range(of: separator, options: .literal, range: search)
        guard found.location != NSNotFound else { break }
        storage.replaceCharacters(in: found, with: "\n")
        let next = NSMaxRange(found)
        search = NSRange(location: next, length: NSMaxRange(search) - next)
      }
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
  /// 没有没收尾的东西时再调一遍是空转（不重排、不往外写）。
  /// 交出去的是**存的形式**（附件字符换回令牌），上限也按它算
  private func settle() {
    guard !hasMarkedText(), let storage = textStorage else { return }
    // 组字期间欠着的插图（粘贴 / 拖进来的图等组字结束再插）：**先插上、再取正文**——原来先取 text 再插，
    // 内层 settle 交出带图的正文之后外层又把 reported 改回旧的、onChange 一次不带图的，图就从正文里丢了（F4）。
    // 插的动作会再走一次 settle（那一次把带图的正文交出去），外层这次取到的就是带图的
    if !pendingImages.isEmpty { insertPendingImages() }
    let text = NoteImageAttachment.stored(from: storage)
    hasImages = storage.string.utf16.contains(0xFFFC)
    // 只退让正文变长了的那一次：正文不知怎么已经超了的时候，得删得动（同 overflows）
    if let maxBytes, text.utf8.count > maxBytes, text.utf8.count > reported.utf8.count {
      // 输入法确认的那一下 shouldChangeText 拦不了（那时还在组字）：退回组字之前的样子。
      // ponytail: 整段换回去，光标到末尾、撤销栈清空；只有贴着上限用输入法打字才走到这里，真碰上再细做
      replaceAll(with: reported)
      overflowed()
      return
    }
    let edited = pending.take()
    if owesFullRestyle {
      restyleAll()
    } else if let edited {
      restyleEdited(edited, in: storage)
    }
    // 改过字：悬停的那张图的下标可能已经指到别的字上了，清掉（把手不再画着，F20）
    if edited != nil { clearHoveredImage() }
    // 这次编辑可能把光标带到了别的行（撤销、粘贴了几行）：原来露着的收回去，现在这一行露出来
    syncMarkers()
    // 宽变了欠着的那次重排（组字中先欠着）
    if owesWidthRestyle { scheduleWidthRestyle() }
    guard text != reported else { return }
    reported = text
    reportedBytes = text.utf8.count
    onChange(text)
  }

  // MARK: 上限

  /// 打字、粘贴、拖进来、撤销、程序改字都先问到这里（单段的那个入口也转到这个）：会超上限的那一次不进。
  /// **按存的字算**（附件字符按它的令牌那么长，不是 U+FFFC 的 3 个字节：贴一张图不会因为附件字符短就放过超限）。
  /// 输入法还在组字时不判断（拦了会打断组字），确认之后由 settle 兜着
  override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?)
    -> Bool
  {
    if let maxBytes, let replacementStrings, !hasMarkedText() {
      let removed = affectedRanges.reduce(0) { $0 + storedByteCount(of: $1.rangeValue) }
      // 加进来的那几段里有附件字符时按 U+FFFC 的字节数算（只会少算，不会误拦）：插图、粘贴图片那几条路
      // 都在调进来之前自己按存的形式查过一遍（NoteTextView.insert(images:at:) 的 canFit）
      let added = replacementStrings.reduce(0) { $0 + $1.utf8.count }
      if added > removed, reportedBytes - removed + added > maxBytes {
        overflowed()
        return false
      }
    }
    return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
  }

  /// range 那一段按存的字算多少字节：附件字符按它的令牌那么长，别的照 UTF-8 算
  func storedByteCount(of range: NSRange) -> Int {
    guard let storage = textStorage, storage.length > 0 else { return 0 }
    let start = min(max(range.location, 0), storage.length)
    let end = min(max(NSMaxRange(range), start), storage.length)
    let clamped = NSRange(location: start, length: end - start)
    guard clamped.length > 0 else { return 0 }
    let text = storage.mutableString
    var total = 0
    var location = clamped.location
    while location < NSMaxRange(clamped) {
      var effective = NSRange()
      let value = storage.attribute(
        .attachment, at: location, longestEffectiveRange: &effective, in: clamped)
      let end = min(NSMaxRange(effective), NSMaxRange(clamped))
      if let attachment = value as? NoteImageAttachment {
        total += NoteImages.token(attachment.picture).utf8.count * (end - location)
      } else {
        total +=
          text.substring(with: NSRange(location: location, length: end - location)).utf8.count
      }
      location = max(end, location + 1)
    }
    return total
  }

  func overflowed() {
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
      // 兜底的那次收尾、还没补完的样式还没跑的话不跑了
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(settleLeftover), object: nil)
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(styleRest), object: nil)
      NSObject.cancelPreviousPerformRequests(
        withTarget: self, selector: #selector(widthRestyle), object: nil)
      // 正拖着把手：监听卸掉（不然一直挂在事件循环上）
      finishWidthDrag()
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
    // 离开窗口时把没补完的样式停了：又挂回来就接着补
    if isStylingRest { scheduleRest(after: 0) }
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

  /// 回车、Tab、Esc（输入法组字时这些键归输入法，到不了这里）。⌃↩（insertLineBreak:）**弹正文的右键菜单**
  /// （第 8 批：键盘用户用它选任务状态、文字颜色；原来当普通换行，系统给它插的是软换行 U+2028，NSString 把它算
  /// 新的一行、段落样式却按段算，后面的「> 引用」缩进不对、竖线压在字上）
  override func doCommand(by selector: Selector) {
    if selector == #selector(insertLineBreak(_:)) {
      popUpContextMenu()
      return
    }
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

  /// 没有选区、没在组字时，拿光标所在的行（不含行尾的换行）和光标在行里的位置去问 change 要不要改；改了返回 true。
  /// 代码块里的行不问（块里按原文：回车就是换行、Tab 就是制表符、「- [ ]」加空格不转换）
  private func editLine(_ change: (String, Int) -> NoteTasks.Change?) -> Bool {
    let selection = selectedRange()
    guard selection.length == 0, !hasMarkedText(), !touchesCodeBlock(selection),
      let text = textStorage?.mutableString
    else {
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
    // 从后往前换：前面的位置不受影响。**带上基础属性换**（不给纯字符串）：纯字符串换进去时系统会把换掉那一段的属性
    // 抄给新字（换成一张图的位置时连 .attachment 一起抄），紧接着的样式那一遍就会把这一行还当成图片行
    let attributes = baseAttributes
    for (range, text) in zip(ranges, texts).reversed() {
      storage.replaceCharacters(
        in: range, with: NSAttributedString(string: text, attributes: attributes))
    }
    storage.endEditing()
    didChangeText()
    let selection = NSRange(
      location: change.selection.location + base, length: change.selection.length)
    setSelectedRange(selection)
    // 屏外的正文框（单测 / 探针）不当 key：不滚。滚动要排版，排到「坏掉的图片令牌 + 落单的代理项」时
    // TextKit 1 会死循环（第 7 批复查那条 ponytail）
    if isInKeyWindow { scrollRangeToVisible(selection) }
    return true
  }

  // MARK: 任务

  /// ⌘T、头部 / 工具栏的「任务」钮、右键菜单：光标所在行（有选区时是选区碰到的每一行）在普通行和任务之间切换。
  /// 选区碰到代码块（连围栏行）时不切、响一声：块里按原文，方框也只是字
  @objc func toggleTask(_ sender: Any? = nil) {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    guard !touchesCodeBlock(selection) else { return NSSound.beep() }
    let block = lineBlock(for: selection, in: text)
    let local = NSRange(location: selection.location - block.start, length: selection.length)
    if let change = NoteTasks.toggle(block.text, selection: local) {
      perform(change, at: block.start)
    }
  }

  /// 第 8 批：右键「任务状态」选了某种。选区碰到的每一行改成这种（见 NoteTasks.setState）
  func setTaskState(_ state: NoteTasks.State) {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    guard !touchesCodeBlock(selection) else { return NSSound.beep() }
    let block = lineBlock(for: selection, in: text)
    let local = NSRange(location: selection.location - block.start, length: selection.length)
    guard let change = NoteTasks.setState(state, in: block.text, selection: local) else {
      return NSSound.beep()
    }
    perform(change, at: block.start)
  }

  /// 第 8 批：右键「文字颜色」选了某种（nil = 默认颜色）。选了字才能上色，选区碰到代码块、组字期间不动
  func setTextColor(_ color: NoteColor?) {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    guard selection.length > 0 else { return NSSound.beep() }
    guard !touchesCodeBlock(selection) else { return NSSound.beep() }
    let block = lineBlock(for: selection, in: text)
    let local = NSRange(location: selection.location - block.start, length: selection.length)
    guard let change = NoteMarkdown.color(color, in: block.text, selection: local) else {
      return NSSound.beep()
    }
    perform(change, at: block.start)
  }

  /// 划词翻译「替换原文」用：range 里的字还是 original 时用 text 换掉（一步撤销），返回做没做。
  /// 便签里的字被改过、范围越界、不能编辑都给 false（调用方只复制）
  @discardableResult
  func replaceIfUnchanged(_ range: NSRange, original: String, with text: String) -> Bool {
    guard isEditable, let storage = textStorage, NSMaxRange(range) <= storage.length,
      storage.mutableString.substring(with: range) == original
    else { return false }
    return replaceSelection(
      with: NSAttributedString(string: text, attributes: baseAttributes), at: range)
  }

  /// 选区里的字给划词翻译用：先转回存的形式（图片附件是 U+FFFC，NoteMarkdown.plain 只认令牌），
  /// 再逐行过 NoteMarkdown.plain（标记去掉、图片成「[图片]」，blocks: false）；代码块里的行按原文、令牌也成「[图片]」。
  /// 没选区给 nil
  func plainText(in range: NSRange) -> String? {
    guard let storage = textStorage, range.length > 0 else { return nil }
    let text = storage.mutableString
    let clamped = clamped(range, in: storage)
    guard clamped.length > 0 else { return nil }
    var pieces: [String] = []
    var location =
      text.lineRange(for: NSRange(location: clamped.location, length: 0)).location
    while location < NSMaxRange(clamped) {
      var (start, end, contentsEnd) = (0, 0, 0)
      text.getLineStart(
        &start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      let from = max(clamped.location, start)
      let to = min(NSMaxRange(clamped), contentsEnd)
      if to > from {
        let raw = NoteImageAttachment.stored(
          from: storage.attributedSubstring(from: NSRange(location: from, length: to - from)))
        pieces.append(
          NoteMarkdown.role(at: start, in: blocks) == nil
            ? NoteMarkdown.plain(raw, blocks: false) : NoteImages.display(raw))
      } else {
        pieces.append("")
      }
      location = max(end, location + 1)
      if location < NSMaxRange(clamped) { pieces.append("\n") }
    }
    return pieces.joined()
  }

  /// 选区碰到的那几行：start 是整篇里的位置，text 是不含最后一行换行的几行，local 是选区相对它。
  /// 光标（长度 0）算它所在的那一行
  func lineBlock(for selection: NSRange, in text: NSString) -> (
    start: Int, text: String, local: NSRange
  ) {
    var (start, end, contentsEnd) = (0, 0, 0)
    text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: selection)
    var blockEnd = contentsEnd
    while end < NSMaxRange(selection) {
      var nextEnd = 0
      var nextContents = 0
      text.getLineStart(
        nil, end: &nextEnd, contentsEnd: &nextContents,
        for: NSRange(location: end, length: 0))
      blockEnd = nextContents
      end = nextEnd
      if nextEnd == 0 { break }
    }
    return (
      start, text.substring(with: NSRange(location: start, length: blockEnd - start)),
      NSRange(location: selection.location - start, length: selection.length)
    )
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
    // 代码块里的方框只是字
    guard NoteMarkdown.role(at: start, in: blocks) == nil else { return nil }
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
  func flipBox(at index: Int) {
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

  /// 不是 key 的面板里第一下点击就勾得上方框、⌘ 点得开链接、选中图片 / 拖把手（别的地方照文本视图自己的规矩）
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    if let event {
      let point = convert(event.locationInWindow, from: nil)
      if box(at: point) != nil || linkToOpen(by: event) != nil || imageChar(at: point) != nil {
        return true
      }
    }
    return super.acceptsFirstMouse(for: event)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if isEditable, !hasMarkedText(), let index = box(at: point) {
      flipBox(at: index)
    } else if let url = linkToOpen(by: event) {
      onOpenLink(url)
    } else if isEditable, !hasMarkedText(), let index = imageHandle(at: point) {
      // 按在拖动把手上：开始改宽度。**不进系统的拖选循环**（父类的 mouseDown 会跟着鼠标走完一整次按下—拖动—松开，
      // 单测里调它就会卡住等真实的鼠标松开）：跟踪靠 mouseDragged / mouseUp，改多少 → 新宽度是纯函数
      beginWidthDrag(at: index, event: event)
    } else if !hasMarkedText(), let index = imageChar(at: point) {
      // 单击图片 = 选中这张图（选区就是那一个字），不进系统的拖选循环（组字中点图不抢组字，同点方框那一支，F20）
      setSelectedRange(NSRange(location: index, length: 1))
    } else {
      // 文本视图在这里面跟着鼠标走完一整次按下—拖动—松开才回来
      super.mouseDown(with: event)
    }
    // 这一下点完、选区定了：松手时系统已经报过一次（setSelectedRanges），点进来时晚一拍的那次也快到了
    // （syncUnlessClicking）；这里当场再对一遍——没有不对的行就什么都不做
    syncMarkers()
  }

  /// 拖把手改宽度：只改显示（cell 上临时的宽度 + 重排这一行），松手才写进正文
  override func mouseDragged(with event: NSEvent) {
    if updateWidthDrag(with: event) { return }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if widthDrag != nil {
      if isWidthDragCancelled { cancelWidthDrag() } else { commitWidthDrag() }
      return
    }
    super.mouseUp(with: event)
  }

  /// 鼠标在正文里进出：离开时把悬停的那张图清掉（不然把手一直画着，F20）
  private var hoverArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    // 只动自己这一块（NSTextView 自己的光标矩形那几块不碰）：进出可见区都要知道
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseExited(with event: NSEvent) {
    clearHoveredImage()
    super.mouseExited(with: event)
  }

  /// 悬停的那张图清掉（鼠标离开正文框、改过字之后）：把手跟着不画了
  func clearHoveredImage() {
    guard let index = hoveredImage else { return }
    hoveredImage = nil
    if let rect = imageRect(ofCharacterAt: index) {
      setNeedsDisplay(rect.insetBy(dx: -3, dy: -3), avoidAdditionalLayout: true)
    }
  }

  override func mouseMoved(with event: NSEvent) {
    if hasImages { updateHoveredImage(at: convert(event.locationInWindow, from: nil)) }
    if !setsCursor(at: event.locationInWindow) { super.mouseMoved(with: event) }
  }

  override func cursorUpdate(with event: NSEvent) {
    updateHoveredImage(at: convert(event.locationInWindow, from: nil))
    if !setsCursor(at: event.locationInWindow) { super.cursorUpdate(with: event) }
  }

  /// 这一点（窗口坐标）上的光标归不归自己定：被浮在上面的东西盖住了（「⋯」菜单）是箭头——文本视图不知道自己被盖住，
  /// 鼠标在它的范围里一动就设 I 形（2026-10-13 用户报，同 SourceTextView.FocusTextView）；没被盖住、在方框上是手指，
  /// 按着 ⌘ 在能打开的链接上也是，在图片上是箭头、在拖动把手上是斜向拉伸的光标；别的返回 false，交给文本视图自己
  private func setsCursor(at point: NSPoint) -> Bool {
    let local = convert(point, from: nil)
    if isCovered(at: point) {
      NSCursor.arrow.set()
    } else if imageHandle(at: local) != nil {
      // 斜向拉伸的光标（macOS 15 起有公开接口）
      NSCursor.frameResize(position: .bottomRight, directions: [.inward, .outward]).set()
    } else if imageChar(at: local) != nil {
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
  /// 右键菜单里插图那一项的名字
  static let insertImageTitle = "插入图片…"
  /// 右键菜单里「任务状态」「文字颜色」两个子菜单的名字
  static let taskStateTitle = "任务状态"
  static let colorTitle = "文字颜色"

  /// ⌃↩：把正文的右键菜单弹在光标旁边（键盘用户选任务状态、文字颜色）
  func popUpContextMenu() {
    // 只有真的窗口是 key 时才弹（屏外测试里 window 不是 key：弹菜单会进系统跟踪循环、卡住）
    guard window?.isKeyWindow == true, let event = NSApp.currentEvent, event.type == .keyDown,
      let menu = menu(for: event)
    else { return }
    let caret = selectedRange().location
    var point = NSPoint(x: 8, y: bounds.height - 8)
    if let window {
      let screen = firstRect(
        forCharacterRange: NSRange(location: min(caret, textStorage?.length ?? 0), length: 0),
        actualRange: nil)
      point = convert(window.convertPoint(fromScreen: screen.origin), from: nil)
    }
    menu.popUp(positioning: nil, at: point, in: self)
  }

  /// 右键菜单最前面加一项「任务」（同名，不写键位），后面是「任务状态」「格式」「文字颜色」，再后面一项
  /// 「插入图片…」（选文件面板）；点在能打开的链接上时，最前面再多一项「打开链接」——不靠 ⌘ 点的那条路
  /// （键盘、旁白用户）。**右键点在任务的方框上时只弹五种状态的小菜单**，不弹这个大的；**点在图片上（或选区正好是
  /// 一张图时按 ⌃↩）只弹图片自己的小菜单**（宽度五档、拷贝，`imageMenu`）
  override func menu(for event: NSEvent) -> NSMenu? {
    // 先看点在哪，再让父类建菜单：它可能会选中点到的那个词，那一行露出标记、字就挪了。
    // 不是鼠标点出来的菜单（键盘的 ⌃↩、旁白）事件里没有点的位置：看光标所在的字
    let isMouse = [.rightMouseDown, .leftMouseDown, .otherMouseDown].contains(event.type)
    let point = isMouse ? convert(event.locationInWindow, from: nil) : nil
    if let point, isEditable, !hasMarkedText(), let index = box(at: point) {
      return boxMenu(at: index)
    }
    if isEditable, !hasMarkedText() {
      if let point, let index = imageChar(at: point) { return imageMenu(clicked: index) }
      if point == nil, selectedImageChar() != nil { return imageMenu(clicked: nil) }
    }
    let url = point.map { link(at: $0) } ?? linkAtCaret()
    // 先把选区记下来：super.menu(for:) 会选中鼠标 / 光标底下的那个词，之后再看选区就晚了
    let selection = selectedRange()
    let menu = super.menu(for: event)
    // 右键点在行尾后面的空白处：父类把那一行的换行（或一串空白）当成「点到的词」选上，选区的底色一直铺到行尾
    // （2026-10-18 用户真机报）。点的不是字、选上的又只是空白时，改成把光标放在点的地方
    if let point, !isOverGlyph(point), selectionIsBlank() {
      setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
    }
    let item = NSMenuItem(
      title: NotesWindowModel.taskTitle, action: #selector(toggleTask(_:)), keyEquivalent: "")
    item.target = self
    let states = stateItem(in: selection)
    let format = formatItem(in: selection)
    let colors = colorItem(in: selection)
    let image = NSMenuItem(
      title: Self.insertImageTitle, action: #selector(insertImageFromPanel(_:)), keyEquivalent: "")
    image.target = self
    for (offset, extra) in [item, states, format, colors, image, .separator()].enumerated() {
      menu?.insertItem(extra, at: offset)
    }
    if let url {
      let open = NSMenuItem(
        title: Self.openLinkTitle, action: #selector(openLink(_:)), keyEquivalent: "")
      open.target = self
      open.representedObject = url
      menu?.insertItem(open, at: 0)
    }
    // 这几项自己说了算：系统自动启用会把「没选字时文字颜色停用」「代码块里两个都停用」改回可用。
    // 带子菜单的两项要**插进菜单之后**再设（insertItem 会把 isEnabled 恢复成 true）
    menu?.autoenablesItems = false
    menu?.item(withTitle: Self.colorTitle)?.isEnabled =
      isEditable && selection.length > 0 && !touchesCodeBlock(selection)
    menu?.item(withTitle: Self.taskStateTitle)?.isEnabled =
      isEditable && !touchesCodeBlock(selection)
    for item in menu?.items ?? [] where item.action != nil && item.submenu == nil {
      item.isEnabled = validateUserInterfaceItem(item)
    }
    return menu
  }

  /// 这一点（视图自己的坐标）落没落在一个字的字形上（行尾后面、正文下面的空白都不算）
  private func isOverGlyph(_ point: NSPoint) -> Bool {
    guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0
    else { return false }
    let origin = textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
    // 离点最近的是换行 / 空白（行尾后面点的就是它）也不算：换行的字形框可能一直伸到行尾
    let index = layoutManager.characterIndexForGlyph(at: glyph)
    guard index < storage.length,
      let scalar = UnicodeScalar(storage.mutableString.character(at: index)),
      !CharacterSet.whitespacesAndNewlines.contains(scalar)
    else { return false }
    let rect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
    return rect.contains(local)
  }

  /// 选区不是空的、选上的全是空白（空格、Tab、换行）
  private func selectionIsBlank() -> Bool {
    guard let text = textStorage?.mutableString else { return false }
    let range = selectedRange()
    guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
    return text.substring(with: range).allSatisfy(\.isWhitespace)
  }

  /// 右键点在方框上：只弹五种状态（现在那种打勾），选了就改这一行
  private func boxMenu(at index: Int) -> NSMenu? {
    guard let text = textStorage?.mutableString else { return nil }
    var (start, contentsEnd) = (0, 0)
    text.getLineStart(
      &start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
    let state = NoteTasks.state(
      of: text.substring(with: NSRange(location: start, length: contentsEnd - start)))
    let menu = NSMenu(title: Self.taskStateTitle)
    for option in NoteTasks.State.allCases {
      let item = NSMenuItem(
        title: option.title, action: #selector(setStateFromMenu(_:)), keyEquivalent: "")
      item.target = self
      item.tag = option.rawValue
      item.state = option == state ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  /// 「任务状态 ›」那一项：五种状态，选区碰到的任务都是同一种时打勾。作用于选区碰到的每一行
  private func stateItem(in selection: NSRange) -> NSMenuItem {
    let item = NSMenuItem(title: Self.taskStateTitle, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: Self.taskStateTitle)
    let current: NoteTasks.State?
    if let text = textStorage?.mutableString {
      let block = lineBlock(for: selection, in: text)
      current = NoteTasks.state(
        in: block.text,
        selection: NSRange(location: selection.location - block.start, length: selection.length))
    } else {
      current = nil
    }
    for option in NoteTasks.State.allCases {
      let row = NSMenuItem(
        title: option.title, action: #selector(setStateFromMenu(_:)), keyEquivalent: "")
      row.target = self
      row.tag = option.rawValue
      row.state = option == current ? .on : .off
      menu.addItem(row)
    }
    item.submenu = menu
    item.isEnabled = isEditable && !touchesCodeBlock(selection)
    return item
  }

  /// 「文字颜色 ›」那一项：六种颜色（前面是小圆点）+ 分隔线 + 默认颜色；选中的字全是同一种时那一项打勾。
  /// 没选字、选区碰到代码块、不能编辑时整个子菜单停用
  private func colorItem(in selection: NSRange) -> NSMenuItem {
    let item = NSMenuItem(title: Self.colorTitle, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: Self.colorTitle)
    let current = selectionColor(in: selection)
    for option in NoteColor.allCases {
      let row = NSMenuItem(
        title: option.title, action: #selector(setColorFromMenu(_:)), keyEquivalent: "")
      row.target = self
      row.tag = option.rawValue
      row.image = option.swatch(side: 16)
      row.state = !current.mixed && current.color == option ? .on : .off
      menu.addItem(row)
    }
    menu.addItem(.separator())
    let plain = NSMenuItem(
      title: "默认颜色", action: #selector(setColorFromMenu(_:)), keyEquivalent: "")
    plain.target = self
    plain.tag = -1
    plain.state = !current.mixed && current.color == nil && selection.length > 0 ? .on : .off
    menu.addItem(plain)
    item.submenu = menu
    item.isEnabled = isEditable && selection.length > 0 && !touchesCodeBlock(selection)
    return item
  }

  /// 选中的字是不是同一种颜色（跳过藏 / 露的标记和空白）：mixed = 混着好几种。
  /// color 为 nil = 全是默认颜色（没上色）
  private func selectionColor(in selection: NSRange) -> (mixed: Bool, color: NoteColor?) {
    guard let storage = textStorage, selection.length > 0 else { return (false, nil) }
    var (seen, mixed, color) = (false, false, NoteColor?.none)
    storage.enumerateAttributes(in: clamped(selection, in: storage)) { attributes, range, _ in
      guard attributes[NoteStyles.hiddenKey] == nil, attributes[NoteStyles.shownKey] == nil else {
        return
      }
      let text = storage.mutableString.substring(with: range)
      guard text.contains(where: { !$0.isWhitespace }) else { return }
      let found = (attributes[NoteStyles.colorKey] as? Int).flatMap(NoteColor.init(rawValue:))
      if seen {
        if found != color { mixed = true }
      } else {
        (seen, color) = (true, found)
      }
    }
    return (mixed, color)
  }

  @objc private func setStateFromMenu(_ sender: NSMenuItem) {
    guard let state = NoteTasks.State(rawValue: sender.tag) else { return }
    setTaskState(state)
  }

  @objc private func setColorFromMenu(_ sender: NSMenuItem) {
    // 加了一个「默认颜色」：-1 = 去掉颜色
    setTextColor(sender.tag < 0 ? nil : NoteColor(rawValue: sender.tag))
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
    if item.action == #selector(setImageWidthFromMenu(_:)) {
      return isEditable && !selectedImageChars().isEmpty
    }
    if item.action == #selector(setStateFromMenu(_:)) {
      return isEditable && !touchesCodeBlock(selectedRange())
    }
    if item.action == #selector(setColorFromMenu(_:)) {
      return isEditable && selectedRange().length > 0 && !touchesCodeBlock(selectedRange())
    }
    if item.action == #selector(formatFromMenu(_:)) {
      return isEditable && !touchesCodeBlock(selectedRange())
    }
    if item.action == #selector(blockFromMenu(_:)) {
      return isEditable && !touchesCodeBlock(selectedRange())
    }
    if item.action == #selector(toggleCodeBlock(_:)) {
      guard let text = textStorage?.mutableString else { return false }
      return isEditable
        && NoteMarkdown.codeSpot(in: text, selection: selectedRange()) != .straddles
    }
    if item.action == #selector(insertLinkFromMenu(_:)) {
      return isEditable && !touchesCodeBlock(selectedRange())
    }
    if item.action == #selector(clearFormatFromMenu(_:)) {
      return isEditable && selectedRange().length > 0
        && !touchesCodeBlock(selectedRange())
    }
    if item.action == #selector(openLink(_:)) { return true }
    if item.action == #selector(insertImageFromPanel(_:)) { return isEditable }
    // 粘贴：按**自己读的那个剪贴板**判（`pasteboard`；单测换成自己建的）——有我们处理得了的图片，或者有能读的类型
    // （字、文件、自家的正文）就可用。不交给父类：父类看的是系统剪贴板，和 paste(_:) 真读的不是同一个
    // （单测里结果会跟着用户当时拷了什么变）。原来直接返回 isEditable && canPasteImages，有字时是 false，
    // 全部便签窗口里 ⌘V 粘不了字（F2）
    if item.action == #selector(paste(_:)) {
      return isEditable
        && (canPasteImages(from: pasteboard)
          || pasteboard.availableType(from: readablePasteboardTypes) != nil)
    }
    return super.validateUserInterfaceItem(item)
  }

  // MARK: 加标记（⌘B ⌘I ⇧⌘X ⌘E）、粘贴网址成链接

  /// 右键菜单里那一项的名字
  static let formatTitle = "格式"

  /// 这个按键是不是四个加标记的键之一（修饰键只比 ⌘⌃⌥⇧、不看大写锁定；按字认，同各浮层的 ⌘C ⌘V）
  static func wrap(for event: NSEvent) -> NoteMarkdown.Wrap? {
    guard event.type == .keyDown else { return nil }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = event.charactersIgnoringModifiers?.lowercased()
    return NoteMarkdown.Wrap.allCases.first { $0.modifiers == flags && $0.key == key }
  }

  /// ⌘B ⌘I ⇧⌘X ⌘E：窗口把 ⌘ 组合沿着视图树问一遍（在主菜单之前；那叠、浮动便签的面板先问过自己的键，
  /// 都没接这四个），焦点在自己身上才接。输入法组字期间吞掉、不做事（键盘在输入法手里）；代码块里响一声（format）
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard let wrap = Self.wrap(for: event), window?.firstResponder === self, isEditable else {
      return super.performKeyEquivalent(with: event)
    }
    if !hasMarkedText() { format(wrap) }
    return true
  }

  /// 加 / 去掉一种标记（规则在 NoteMarkdown.toggle：没有选区插一对；有选区时粗体 / 斜体 / 删除线整段一种、
  /// 行内代码每行各自包；已经包着的去掉）：一步撤销，改字走 perform。Markdown 关着时照样加（存的本来就是 Markdown
  /// 的原文，只是不显示成样式）；选区碰到代码块、没有可包的字时不改、响一声
  func format(_ wrap: NoteMarkdown.Wrap) {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    guard !touchesCodeBlock(selection) else { return NSSound.beep() }
    let block = localBlock(selection, in: text)
    guard let change = NoteMarkdown.toggle(wrap, in: block.text, selection: block.local) else {
      return NSSound.beep()
    }
    perform(change, at: block.start)
  }

  /// 选区碰到的那几行，和夹在里面的选区（去掉最后一行换行、不超出这几行）：NoteMarkdown 里那些函数要的
  private func localBlock(
    _ selection: NSRange, in text: NSString
  ) -> (start: Int, text: String, local: NSRange) {
    let block = lineBlock(for: selection, in: text)
    let length = (block.text as NSString).length
    let start = min(block.local.location, length)
    let local = NSRange(
      location: start,
      length: max(0, min(NSMaxRange(block.local), length) - start))
    return (block.start, block.text, local)
  }

  /// 右键菜单的「格式」：粗体 / 斜体 / 删除线 / 代码（带键位），一条分节线，标题 1–3、引用、无序列表、有序列表、
  /// 代码块，一条分节线，链接、清除格式。打勾：粗体 / 斜体 / 删除线看选区里能加的字是不是全都已经是；块格式看选区
  /// 碰到的非空行是不是全都是；代码块看选中的行是不是都在块里；代码、链接、清除格式不自动打勾。停用：代码块里除了
  /// 「代码块」都停用；链接跨行时停用；清除格式没选字时停用。**带子菜单这一项要自己说了算**（autoenablesItems = false）
  private func formatItem(in selection: NSRange) -> NSMenuItem {
    let submenu = NSMenu(title: Self.formatTitle)
    submenu.autoenablesItems = false
    let text = textStorage?.mutableString
    let block = text.map { localBlock(selection, in: $0) }
    let spot = text.map { NoteMarkdown.codeSpot(in: $0, selection: selection) } ?? .outside
    let inCode = spot != .outside
    let crossing =
      block.map { NoteMarkdown.crossesLines($0.text, selection: $0.local) } ?? true
    func add(
      _ title: String, _ action: Selector, key: String = "",
      mask: NSEvent.ModifierFlags = .command, tag: Int, enabled: Bool, checked: Bool = false
    ) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      if !key.isEmpty { item.keyEquivalentModifierMask = mask }
      item.tag = tag
      item.target = self
      item.isEnabled = enabled
      item.state = checked ? .on : .off
      submenu.addItem(item)
    }
    for wrap in [NoteMarkdown.Wrap.bold, .italic, .strike, .code] {
      let checked: Bool
      if wrap == .code || block == nil {
        checked = false
      } else {
        checked = NoteMarkdown.isFormatted(wrap, in: block!.text, selection: block!.local) == true
      }
      add(
        wrap.title, #selector(formatFromMenu(_:)), key: wrap.key, mask: wrap.modifiers,
        tag: wrap.rawValue, enabled: isEditable && !inCode, checked: checked)
    }
    // 链接和加标记的几个放一组（R5 的顺序），块格式在分节线后面
    add(
      "链接", #selector(insertLinkFromMenu(_:)), tag: FormatTag.link.rawValue,
      enabled: isEditable && !inCode && !crossing)
    submenu.addItem(.separator())
    let blockFormats: [(NoteMarkdown.BlockFormat, FormatTag)] = [
      (.heading(1), .heading1), (.heading(2), .heading2), (.heading(3), .heading3),
      (.quote, .quote), (.bullet, .bullet), (.ordered, .ordered),
    ]
    for (format, tag) in blockFormats {
      let checked: Bool
      if let block {
        checked = NoteMarkdown.blockIsOn(format, in: block.text, selection: block.local) == true
      } else {
        checked = false
      }
      add(
        format.title, #selector(blockFromMenu(_:)), tag: tag.rawValue,
        enabled: isEditable && !inCode, checked: checked)
    }
    add(
      "代码块", #selector(toggleCodeBlock(_:)), tag: FormatTag.codeBlock.rawValue,
      enabled: isEditable && spot != .straddles, checked: spot == .inside)
    submenu.addItem(.separator())
    add(
      "清除格式", #selector(clearFormatFromMenu(_:)), tag: FormatTag.clear.rawValue,
      enabled: isEditable && !inCode && selection.length > 0)
    let item = NSMenuItem(title: Self.formatTitle, action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  /// 「格式」子菜单里各项的 tag（粗体那四个用 Wrap.rawValue）
  private enum FormatTag: Int {
    case heading1 = 10
    case heading2
    case heading3
    case quote
    case bullet
    case ordered
    case codeBlock
    case link
    case clear
  }

  @objc private func formatFromMenu(_ sender: NSMenuItem) {
    if let wrap = NoteMarkdown.Wrap(rawValue: sender.tag) { format(wrap) }
  }

  @objc private func blockFromMenu(_ sender: NSMenuItem) {
    let format: NoteMarkdown.BlockFormat
    switch FormatTag(rawValue: sender.tag) {
    case .heading1: format = .heading(1)
    case .heading2: format = .heading(2)
    case .heading3: format = .heading(3)
    case .quote: format = .quote
    case .bullet: format = .bullet
    case .ordered: format = .ordered
    default: return
    }
    setBlock(format)
  }

  @objc private func toggleCodeBlock(_ sender: NSMenuItem) { setCodeBlock() }

  @objc private func insertLinkFromMenu(_ sender: NSMenuItem) { makeLink() }

  @objc private func clearFormatFromMenu(_ sender: NSMenuItem) { clearFormat() }

  /// 换成一种块格式 / 去掉（NoteMarkdown.block：标题、引用、无序列表、有序列表；代码块里响一声）
  func setBlock(_ format: NoteMarkdown.BlockFormat) {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    guard !touchesCodeBlock(selection) else { return NSSound.beep() }
    let block = localBlock(selection, in: text)
    guard let change = NoteMarkdown.block(format, in: block.text, selection: block.local) else {
      return NSSound.beep()
    }
    perform(change, at: block.start)
  }

  /// 「代码块」那一项：选中块里的行去掉围栏、光标在空行插三行、别的给碰到的行上下加围栏（一半在块里响一声）
  func setCodeBlock() {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    guard let change = NoteMarkdown.codeBlock(in: text, selection: selectedRange()) else {
      return NSSound.beep()
    }
    perform(change, at: 0)
  }

  /// 「链接」那一项：没选字插 `[]()`、光标在方括号里；选了字换成 `[选中的字]()`、光标在小括号里
  func makeLink() {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    guard !touchesCodeBlock(selection) else { return NSSound.beep() }
    let block = localBlock(selection, in: text)
    guard let change = NoteMarkdown.link(in: block.text, selection: block.local) else {
      return NSSound.beep()
    }
    perform(change, at: block.start)
  }

  /// 「清除格式」：选区里的粗体、斜体、删除线、颜色去掉，碰到的行内代码和链接去掉标记；块格式不动
  func clearFormat() {
    guard isEditable, !hasMarkedText(), let text = textStorage?.mutableString else { return }
    let selection = selectedRange()
    guard selection.length > 0 else { return NSSound.beep() }
    guard !touchesCodeBlock(selection) else { return NSSound.beep() }
    let block = localBlock(selection, in: text)
    guard let change = NoteMarkdown.clear(in: block.text, selection: block.local) else {
      return NSSound.beep()
    }
    perform(change, at: block.start)
  }

  /// 粘贴从哪个剪贴板读（单测换成自己建的，不碰系统的）
  var pasteboard = NSPasteboard.general

  /// 粘贴（⌘V，面板里经 OverlayPanel.sendEditAction 发过来）。顺序（第 7 批起）：
  /// ① 自家类型（便签正文，存的形式）→ 按令牌换成附件插进来（引用同一个文件、不复制文件）；
  /// ② 图片文件 → 每张存进目录、各插一张；
  /// ③ 有非空的纯文字 → 照现在走（选中一行里的一段字、不在代码块里、剪贴板是一个能打开的网址时粘成链接，别的照常粘纯文本）。
  ///    理由：表格、文稿里复制的字常常还附带一张「渲染图」，用户要的是字；
  /// ④ 只有图片数据（截图、浏览器里「拷贝图像」）→ 存进目录、插一张。
  /// 纯文字里带的 U+FFFC（别的 App 里那是一张图的占位）去掉，不在正文里留一个没挂附件的占位字符
  override func paste(_ sender: Any?) {
    if pasteImages(from: pasteboard) { return }
    if pasteLink(from: pasteboard) { return }
    // ③ 有非空的纯文字：**显式按 .string 读**（不让系统按 readablePasteboardTypes 的顺序挑中图片类型，
    // 见 F5）。别的 App 里 U+FFFC 是一张图的占位，贴进来没有意义，去掉
    if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
      let text = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
      guard !text.isEmpty else { return }
      replaceSelection(
        with: NSAttributedString(string: text, attributes: baseAttributes), at: selectedRange())
      return
    }
    if pasteboard.name == .general {
      super.paste(sender)
    } else {
      _ = readSelection(from: pasteboard)
    }
  }

  /// 正文的基础样式（拼替换用的富文本时用）
  var baseAttributes: [NSAttributedString.Key: Any] {
    [.font: theme.font, .foregroundColor: theme.ink, .paragraphStyle: theme.baseParagraph]
  }

  // MARK: 剪贴板和拖动

  /// 自家类型：选中的那一段的**存的形式**（带令牌）。贴回便签时按它把图片一起带过去（引用同一个文件）
  static let noteTextType = NSPasteboard.PasteboardType("com.yy.kitty-tools.note-text")

  /// 可写的类型：自家的、纯文本（图片的位置写「[图片]」）、选区正好是一张图时再加上图片本身
  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
    var types = super.writablePasteboardTypes
    for type in [Self.noteTextType, .string, .tiff, .png] where !types.contains(type) {
      types.insert(type, at: 0)
    }
    return types
  }

  /// 复制 / 剪切 / 往别的 App 拖 / 文本视图内部拖动都走这里：写自家的存的形式；选区正好是一张图时只写那张图
  /// （原字节原类型；不是 PNG 的再加一份 PNG），字里夹着图时写纯文本（「[图片]」）+ RTFD（真的图片），见 writeNoteSelection
  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType])
    -> Bool
  {
    writeNoteSelection(to: pboard) ?? super.writeSelection(to: pboard, types: types)
  }

  /// 可读 / 可拖进来的类型：自家的类型排在最前面（文本视图内部拖动时图片跟着走），**图片类型和 fileURL 排在
  /// 父类列表的末尾**（.string 的前面）：这两个数组是「按偏好排序」的，系统按这个顺序挑类型——原来把图片类型
  /// 插到最前，同时有字和图（表格、文稿复制的「字 + 渲染图」、访达拷文件带的图标 TIFF）时进来的都是图（F5）
  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
    var types = super.readablePasteboardTypes.filter { $0 != Self.noteTextType }
    for type in [NSPasteboard.PasteboardType.fileURL, .tiff, .png] where !types.contains(type) {
      types.append(type)
    }
    return [Self.noteTextType] + types
  }

  override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
    var types = super.acceptableDragTypes.filter { $0 != Self.noteTextType }
    for type in [NSPasteboard.PasteboardType.fileURL, .tiff, .png] where !types.contains(type) {
      types.append(type)
    }
    return [Self.noteTextType] + types
  }

  /// 拖进来（落点由系统先设成选区）：自家的类型按令牌插、图片文件 / 图片数据存进目录再插；别的交给父类
  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool
  {
    if readImageSelection(from: pboard, type: type) { return true }
    return super.readSelection(from: pboard, type: type)
  }

  // 读屏（F13）：原来这里把 accessibilityValue 重写成「把附件字符换成一个『图片』两个字」，长度和文本存储对不上，
  // 读屏的选区、按行范围、accessibilityString(for:) 全按存储的下标算，图后面的位置就全错一位。去掉这个重写：
  // 系统把附件当附件读，图片念什么由附件 cell 的 accessibilityLabel 给（NoteImageAttachmentCell → 「图片」）
  /// 这一段选区里有没有图片附件（粘网址成链接不许包住图：图会被换成一个裸 U+FFFC 的链接、图丢了，F12）
  func selectionContainsAttachment(_ range: NSRange) -> Bool {
    guard let storage = textStorage, range.length > 0 else { return false }
    var found = false
    storage.enumerateAttribute(.attachment, in: clamped(range, in: storage)) { value, _, stop in
      if value is NoteImageAttachment {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  /// 照上面的规矩粘成链接；粘了返回 true
  func pasteLink(from pasteboard: NSPasteboard) -> Bool {
    guard theme.markdown, isEditable, !hasMarkedText(), selectedRanges.count == 1,
      let text = textStorage?.mutableString
    else { return false }
    let selection = selectedRange()
    guard selection.length > 0, !touchesCodeBlock(selection),
      !selectionContainsAttachment(selection), let pasted = pasteboard.string(forType: .string)
    else { return false }
    var (start, contentsEnd) = (0, 0)
    text.getLineStart(
      &start, end: nil, contentsEnd: &contentsEnd,
      for: NSRange(location: selection.location, length: 0))
    // 跨行的不算
    guard NSMaxRange(selection) <= contentsEnd,
      let change = NoteMarkdown.linkPaste(
        pasted, in: text.substring(with: NSRange(location: start, length: contentsEnd - start)),
        selection: NSRange(location: selection.location - start, length: selection.length))
    else { return false }
    return perform(change, at: start)
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

/// 正文编辑器的布局管理器（NoteTextView.make 建的；便签墙卡片的正文也用它画，NoteWallCard.layout）。多管三件事：
/// 任务方框画成圆角方框（drawGlyphs）、图片行的选区（fillBackgroundRectArray），和空着的最后一行（正文末尾的换行后面那一行、
/// 空的正文）。别的行由布局管理器的代理定字的位置（NoteStyles.centerLine），这一行不经过代理，按打进去的字
/// （typingAttributes）的行高排、字却贴在顶上：这里同样把「用到的那一块」收成字那么高、居中——插入点在空行上
/// 和别的行一样高、一样位置。布局时调的代码：字的上下沿由文本视图换纸色 / 字号时存进来（Mutex，读写都是一下）
nonisolated final class NoteLayoutManager: NSLayoutManager {
  /// 打进去的字的上下沿（ascender、descender）；还没设过时不管
  let extraLine = Mutex<(ascender: CGFloat, descender: CGFloat)?>(nil)
  /// 正在画底色的那一次的原点（drawBackground 传进来的 origin）：fillBackgroundRectArray 拿到的矩形在视图坐标里，
  /// 换回文本容器的坐标才能找行片段
  private let backgroundOrigin = Mutex<NSPoint>(.zero)

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    backgroundOrigin.withLock { $0 = origin }
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
  }

  /// 字形。任务方框那个字（字上记着 taskBoxKey）不交给系统画，改画圆角方框（NoteTaskBox）；别的字一段段照常交给父类。
  /// 方框字是 BMP 里的单个字、一个字形，按它切开不会把代理对 / 附件拆成两半
  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    guard glyphsToShow.length > 0, let storage = textStorage, let container = textContainers.first
    else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
    let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    var boxes: [(glyph: Int, char: Int, state: NoteTasks.State)] = []
    storage.enumerateAttribute(NoteStyles.taskBoxKey, in: chars) { value, range, _ in
      guard let raw = value as? Int, let state = NoteTasks.State(rawValue: raw) else { return }
      for char in range.location..<NSMaxRange(range) {
        let glyph = glyphIndexForCharacter(at: char)
        if NSLocationInRange(glyph, glyphsToShow) { boxes.append((glyph, char, state)) }
      }
    }
    guard !boxes.isEmpty else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
    let scale =
      NSGraphicsContext.current.map { abs($0.cgContext.userSpaceToDeviceSpaceTransform.a) } ?? 2
    var start = glyphsToShow.location
    for box in boxes.sorted(by: { $0.glyph < $1.glyph }) where box.glyph >= start {
      if box.glyph > start {
        super.drawGlyphs(forGlyphRange: NSRange(start..<box.glyph), at: origin)
      }
      start = box.glyph + 1
      let attributes = storage.attributes(at: box.char, effectiveRange: nil)
      guard let color = attributes[.foregroundColor] as? NSColor,
        let geometry = taskBox(atGlyph: box.glyph, in: container, origin: origin, scale: scale)
      else { continue }
      NoteTaskBox.draw(
        box.state, in: geometry, color: color, mark: attributes[NoteStyles.taskMarkKey] as? NSColor)
    }
    if start < NSMaxRange(glyphsToShow) {
      super.drawGlyphs(forGlyphRange: NSRange(start..<NSMaxRange(glyphsToShow)), at: origin)
    }
  }

  /// 第 glyph 个字形（任务方框那个字）上的圆角方框画在哪：横向在这个字占的那一格里居中，竖向对着这一行正文的字
  /// （lineFontKey）的中线。origin：文本容器的原点（drawGlyphs 传进来的）；scale：屏幕像素 / 点
  func taskBox(atGlyph glyph: Int, in container: NSTextContainer, origin: NSPoint, scale: CGFloat)
    -> NoteTaskBox.Geometry?
  {
    guard let storage = textStorage else { return nil }
    let char = characterIndexForGlyph(at: glyph)
    guard char < storage.length,
      let font = storage.attribute(NoteStyles.lineFontKey, at: char, effectiveRange: nil) as? NSFont
    else { return nil }
    let cell = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    return NoteTaskBox.geometry(
      size: font.pointSize, advance: (cell.minX + origin.x, cell.width),
      baseline: line.minY + location(forGlyphAt: glyph).y + origin.y, capHeight: font.capHeight,
      scale: scale)
  }

  /// 选区的底色。**图片那一行**的行片段被撑到图那么高（NoteStyles.centerLine），系统按整个行片段（头尾两行按 usedRect，
  /// 就是图那一块）铺底色——同一行里的字只在图的底边那一条，选中时字后面是一大块图那么高的底（2026-10-18 用户真机报）。
  /// 这里把落在图片行里的那几块收成「字那一条」：竖向是这一行正文的行高、和字居中（同普通的行）；图自己有选中的描边，
  /// 底色只剩它底边那一条、被图盖住。别的行原样。正文里没有图片行时直接交给父类
  override func fillBackgroundRectArray(
    _ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
    forCharacterRange charRange: NSRange, color: NSColor
  ) {
    guard rectCount > 0, let storage = textStorage, let container = textContainers.first,
      NSMaxRange(charRange) <= storage.length, Self.touchesImageLine(charRange, in: storage)
    else {
      return super.fillBackgroundRectArray(
        rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }
    let origin = backgroundOrigin.withLock { $0 }
    var rects: [NSRect] = []
    for viewRect in UnsafeBufferPointer(start: rectArray, count: rectCount) {
      let rect = viewRect.offsetBy(dx: -origin.x, dy: -origin.y)
      var covered = false
      enumerateLineFragments(forGlyphRange: glyphRange(forBoundingRect: rect, in: container)) {
        fragment, used, _, glyphs, _ in
        var slice = rect.intersection(fragment)
        guard !slice.isNull, slice.height > 0 else { return }
        covered = true
        // 普通的行怎么铺，图片行就怎么铺：选区的头尾两行系统按 usedRect（字那么高）铺，中间整行选中的按整个行片段
        // （行高）铺——这一块盖满了整个行片段就是「中间整行」
        let full = slice.height >= fragment.height - 0.5
        if let band = self.textBand(
          of: fragment, used: used, glyphs: glyphs, in: storage, full: full)
        {
          // 字的那一条，**不按行片段裁**：图片行的行片段在基线下面只留了一点（NoteImageLayout.padding），裁了的话底色的
          // 下沿贴着字、比普通的行矮一截（2026-10-18 用户再报「和普通行的选中保持一致」）。多出来的那一两 pt 伸进下一行的
          // 行片段顶上，下一行的字在它自己的行里居中、碰不到
          slice.origin.y = band.minY
          slice.size.height = band.height
        }
        rects.append(slice.offsetBy(dx: origin.x, dy: origin.y))
      }
      // 不在任何行片段里的那一块（空着的最后一行之类）原样
      if !covered { rects.append(viewRect) }
    }
    guard !rects.isEmpty else { return }
    rects.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      super.fillBackgroundRectArray(
        base, count: buffer.count, forCharacterRange: charRange, color: color)
    }
  }

  /// 这段字碰没碰到图片行（字上记着 imageLineKey）
  private static func touchesImageLine(_ chars: NSRange, in storage: NSTextStorage) -> Bool {
    let range = storage.mutableString.lineRange(for: chars)
    var found = false
    storage.enumerateAttribute(NoteStyles.imageLineKey, in: range) { value, _, stop in
      if value != nil {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  /// 图片那一行（这个行片段里真的有图）里字的那一条：full（中间整行选中）时竖向 = 这一行正文的行高（段落样式的
  /// minimumLineHeight）、和字居中；不然 = 字那么高（主字体的上下沿，基线在图底），同普通行头尾两行的 usedRect。
  /// 不是图片行给 nil
  private func textBand(
    of fragment: NSRect, used: NSRect, glyphs: NSRange, in storage: NSTextStorage, full: Bool
  ) -> NSRect? {
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.length > 0, chars.location < storage.length else { return nil }
    let attributes = storage.attributes(at: chars.location, effectiveRange: nil)
    guard attributes[NoteStyles.imageLineKey] != nil,
      NoteStyles.containsAttachment(in: chars, of: storage),
      let font = attributes[NoteStyles.lineFontKey] as? NSFont,
      let style = attributes[.paragraphStyle] as? NSParagraphStyle
    else { return nil }
    // 基线在图底：图片行的 usedRect 就是图那一块（NoteStyles.centerLine），它的下沿就是基线。不用
    // location(forGlyphAt:)——行片段的头一个字形是附件，问它拿到的不是字的基线（屏外量的，偏下约 2 pt）
    let baseline = used.maxY
    let box = font.ascender - font.descender
    let height = full ? max(style.minimumLineHeight, box) : box
    let top = baseline - font.ascender - (height - box) / 2
    return NSRect(x: fragment.minX, y: top, width: fragment.width, height: height)
  }

  override func setExtraLineFragmentRect(
    _ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer
  ) {
    var used = usedRect
    if fragmentRect.height > 0, let metrics = extraLine.withLock({ $0 }) {
      var baseline: CGFloat = 0
      NoteStyles.center(
        height: fragmentRect.height, ascender: metrics.ascender, descender: metrics.descender,
        before: 0, rect: fragmentRect, used: &used, baseline: &baseline)
    }
    super.setExtraLineFragmentRect(fragmentRect, usedRect: used, textContainer: container)
  }
}

extension NoteMarkdown.Wrap {
  /// 键位：⌘B 粗体、⌘I 斜体、⇧⌘X 删除线、⌘E 代码（按键认的、右键菜单上写的都是它）
  var key: String {
    switch self {
    case .bold: "b"
    case .italic: "i"
    case .strike: "x"
    case .code: "e"
    }
  }

  var modifiers: NSEvent.ModifierFlags { self == .strike ? [.command, .shift] : .command }
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
  /// 设置 › 便签「Markdown 样式」开没开、行距
  let markdown: Bool
  let spacing: NoteStyles.Spacing
  let onChange: (String) -> Void
  let onOverflow: () -> Void
  var onCancel: (() -> Void)?
  /// 插图被拒 / 存图没成时说什么（刘海岛的标题 + 说明；默认不说）
  var onImageProblem: (String, String) -> Void = { _, _ in }
  /// 这条便签的图片目录（NoteStore.images）
  var images: NoteImageStore?

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
    view.onImageProblem = onImageProblem
    view.imageStore = images
    // 换一条便签时正文框可能被复用（setText 换正文）：编号跟着换，替换原文才认得出「已经不是那条便签了」
    view.identifier = NSUserInterfaceItemIdentifier(note.id)
    if let request = focusRequest, request != view.focusRequest {
      view.focusRequest = request
      view.window?.makeFirstResponder(view)
    }
    view.setPaper(
      NotePaper.of(note), fontSize: fontSize, markdown: markdown, spacing: spacing,
      paperIndex: Note.clamped(color: note.color))
    view.setText(note.body)
    // 选中文字的底色是强调色 0.28（不露系统蓝；读了 Style.brand，设置里换了强调色这里会重跑）
    view.selectedTextAttributes = [
      .backgroundColor: NSColor(Style.brand).withAlphaComponent(0.28)
    ]
  }
}
