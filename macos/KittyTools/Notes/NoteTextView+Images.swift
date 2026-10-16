// 便签正文编辑器里跟图片有关的那一半（第 7 批；主文件 NoteTextView.swift 里的互转四个口子、宽变了的重排、
// 画选中描边和把手都在那边调到这里）。这里管：
// - 命中：这一点上是不是图片、拖动把手在哪、哪张图被选中 / 悬停（描边和把手由文本视图自己画：要能命中、画在字和选区上面）；
// - 拖把手改宽度：**不进系统的鼠标跟踪循环**（父类的 mouseDown 会跟着鼠标走完一整次按下—拖动—松开，单测里调它就卡住等
//   真实的鼠标松开），靠 mouseDragged / mouseUp；「拖了多少 → 新宽度」是纯函数，松手写进正文是可直接调的方法；
//   拖的时候只改显示（cell 上临时的宽度 + 重排那一行），松手才写进正文（一步撤销），Esc 取消回原样；
// - 插图：每张独占一行（落点前面有字先换行、后面有字在图后换行），一步撤销，插完光标在图后面；组字期间欠着，确认后插；
// - 粘贴 / 拖进：自家类型（存的形式）→ 令牌换成附件；图片文件 / 图片数据 → 后台存进目录（转码、写盘不在主线程）、
//   回主线程插——**按「是哪个编辑器、哪条便签」落**（等的这一下用户换了便签、关了便签就不插，文件变孤儿由清理收）；
// - 复制 / 剪切 / 拖出：自家的存的形式 + 纯文本（图片写「[图片]」）+ 选区正好一张图时再写那张图本身；
// - 右键「插入图片…」：不模态的选文件面板（本 App 不在前台时先激活，选完把前台还给原来的 App、键盘还给这条便签）。
// 三条红线照旧（mac-overlay-panel §3）：输入法组字期间不动属性、有没处理完的编辑时不在选区回调里动属性、
// 打进去的字永远是基础样式。插图和改宽度都走 shouldChangeText → 改 → didChangeText（一步撤销、照常重排和写出去）。

import AppKit
import ImageIO
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

extension NoteTextView {
  // MARK: 命中

  /// 这一点（视图自己的坐标）上是哪张图：先按字形找到那个字，再看点在不在它那一块里
  /// （行尾、正文下面的空白不算）
  func imageChar(at point: NSPoint) -> Int? {
    guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0
    else { return nil }
    let origin = textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard local.x >= 0, local.y >= 0 else { return nil }
    let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
    guard glyph < layoutManager.numberOfGlyphs else { return nil }
    let index = layoutManager.characterIndexForGlyph(at: glyph)
    guard index < storage.length,
      storage.attribute(.attachment, at: index, effectiveRange: nil) is NoteImageAttachment,
      let rect = imageRect(ofCharacterAt: index)
    else { return nil }
    return rect.insetBy(dx: -2, dy: -2).contains(point) ? index : nil
  }

  /// 第 index 个字（是图片附件）在视图里占的那一块。**不按 boundingRect 算**（实测 15.7：附件字形的框和
  /// 真正的图对不上——图的高度是 attachmentBounds 报的），照和布局代理同一套算：x 是字形的横位置，
  /// y 是「行片段顶 + 段前 + 上留白」，宽高是附件报的那一块
  func imageRect(ofCharacterAt index: Int) -> NSRect? {
    guard let layoutManager, let textContainer, let storage = textStorage, index >= 0,
      index < storage.length,
      let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil)
        as? NoteImageAttachment
    else { return nil }
    // 刚改过这一行（拖把手只改显示、重排过）：这一个字先排到，问出来的才是新的尺寸
    layoutManager.ensureLayout(forCharacterRange: NSRange(location: index, length: 1))
    let glyph = layoutManager.glyphIndexForCharacter(at: index)
    guard glyph < layoutManager.numberOfGlyphs else { return nil }
    let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let location = layoutManager.location(forGlyphAt: glyph)
    let before =
      (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
      .map { NoteStyles.spacingBefore(at: index, style: $0, in: storage.mutableString) } ?? 0
    let bounds = attachment.attachmentBounds(
      for: textContainer, proposedLineFragment: fragment, glyphPosition: location,
      characterIndex: index)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let origin = textContainerOrigin
    return NSRect(
      x: location.x + origin.x, y: fragment.minY + before + NoteImageLayout.padding + origin.y,
      width: bounds.width, height: bounds.height)
  }

  /// 第 index 张图右下角的拖动把手（12 pt 的方块，贴着图里侧 1 pt）
  func handleRect(ofImageAt index: Int) -> NSRect? {
    guard let rect = imageRect(ofCharacterAt: index) else { return nil }
    let side = NoteImageLayout.handle
    guard rect.width > side + 2, rect.height > side + 2 else { return nil }
    return NSRect(
      x: rect.maxX - side - 1, y: rect.maxY - side - 1, width: side, height: side)
  }

  /// 这一点（视图自己的坐标）是不是在某个把手上（把手只在悬停或选中时显示，鼠标在图上时本来就是悬停）：是就给那张图
  func imageHandle(at point: NSPoint) -> Int? {
    guard let index = imageChar(at: point), let handle = handleRect(ofImageAt: index),
      handle.contains(point)
    else { return nil }
    return index
  }

  /// 选区正好是一张图时那个字（选中整张：⌫ 删、复制时再写图片本身都按它）
  func selectedImageChar() -> Int? {
    let selection = selectedRange()
    guard selection.length == 1, let storage = textStorage, selection.location < storage.length,
      storage.attribute(.attachment, at: selection.location, effectiveRange: nil)
        is NoteImageAttachment
    else { return nil }
    return selection.location
  }

  /// 第 index 个字的附件 cell
  func imageCell(at index: Int) -> NoteImageAttachmentCell? {
    guard let storage = textStorage, index >= 0, index < storage.length,
      let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil)
        as? NoteImageAttachment
    else { return nil }
    return attachment.attachmentCell as? NoteImageAttachmentCell
  }

  // MARK: 画（选中描边、拖动把手）

  /// 鼠标停到哪张图上了：换了一张就把旧的那块和新那块标成要重画（把手在悬停时也显示）
  func updateHoveredImage(at point: NSPoint) {
    let found = imageChar(at: point)
    guard found != hoveredImage else { return }
    for index in [hoveredImage, found].compactMap({ $0 }) {
      if let rect = imageRect(ofCharacterAt: index) {
        setNeedsDisplay(rect.insetBy(dx: -3, dy: -3), avoidAdditionalLayout: true)
      }
    }
    hoveredImage = found
  }

  /// 选中 / 悬停的图片：选中时一圈强调色描边，选中或悬停时右下角一个把手（画在字和选区上面，super.draw 之后调）
  func drawImageChrome(in dirtyRect: NSRect) {
    let selected = selectedImageChar()
    var shown = [selected, hoveredImage].compactMap { $0 }
    shown = shown.reduce(into: []) { list, index in
      if !list.contains(index) { list.append(index) }
    }
    guard !shown.isEmpty else { return }
    for index in shown {
      guard let rect = imageRect(ofCharacterAt: index), rect.intersects(dirtyRect) else { continue }
      if index == selected {
        let path = NSBezierPath(
          roundedRect: rect.insetBy(dx: -1.5, dy: -1.5),
          xRadius: NoteImageLayout.corner + 1.5, yRadius: NoteImageLayout.corner + 1.5)
        path.lineWidth = 2
        NSColor(Style.brand).setStroke()
        path.stroke()
      }
      if let handle = handleRect(ofImageAt: index), handle.intersects(dirtyRect) {
        drawHandle(handle)
      }
    }
  }

  /// 把手：强调色的圆角方块 + 两条白色的斜线（右下角拉伸）
  private func drawHandle(_ rect: NSRect) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
    NSColor(Style.brand).setFill()
    path.fill()
    NSColor.white.setStroke()
    let lines = NSBezierPath()
    lines.lineWidth = 1.2
    lines.lineCapStyle = .round
    for offset in [CGFloat(3), 6] {
      lines.move(to: NSPoint(x: rect.minX + offset, y: rect.minY + 3))
      lines.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - offset))
    }
    lines.stroke()
  }

  // MARK: 拖把手改宽度

  /// 拖了多少 → 新的宽度（纯函数）：夹在最小宽度和正文可用宽之间（锁比例由算尺寸那一步管）
  static func draggedWidth(from start: CGFloat, by delta: CGFloat, limit: CGFloat) -> CGFloat {
    let ceiling = max(limit, NoteImageLayout.minWidth)
    return min(max((start + delta).rounded(), NoteImageLayout.minWidth), ceiling)
  }

  /// 按在把手上：开始拖（不交给父类）。Esc 取消靠临时装一个按键监听
  func beginWidthDrag(at index: Int, event: NSEvent) {
    guard let cell = imageCell(at: index), let rect = imageRect(ofCharacterAt: index) else {
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    widthDrag = WidthDrag(
      index: index, cell: cell, startWidth: rect.width, startX: point.x, current: rect.width)
    isWidthDragCancelled = false
    setSelectedRange(NSRange(location: index, length: 1))
    widthMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53, let self, self.widthDrag != nil else { return event }
      self.isWidthDragCancelled = true
      self.cancelWidthDrag()
      return nil
    }
  }

  /// 拖着：只改显示（cell 上临时的宽度 + 重排这一行），**不改字**。返回有没有在处理（false = 交给父类）
  func updateWidthDrag(with event: NSEvent) -> Bool {
    guard var drag = widthDrag else { return false }
    let point = convert(event.locationInWindow, from: nil)
    let width = Self.draggedWidth(
      from: drag.startWidth, by: point.x - drag.startX, limit: availableWidth)
    drag.current = width
    widthDrag = drag
    drag.cell.live.withLock { $0 = width }
    restyleImageLine(at: drag.index)
    return true
  }

  /// 松手：宽度变了才写进正文（一步撤销）
  func commitWidthDrag() {
    guard let drag = widthDrag else { return }
    let width = Int(drag.current.rounded())
    finishWidthDrag()
    guard width != Int(drag.startWidth.rounded()) else { return }
    replaceImageWidth(at: drag.index, width: width)
  }

  /// Esc / 便签关了：回到原来的大小
  func cancelWidthDrag() {
    guard let drag = widthDrag else { return }
    finishWidthDrag()
    drag.cell.live.withLock { $0 = nil }
    restyleImageLine(at: drag.index)
  }

  /// 收尾：清状态、卸按键监听
  func finishWidthDrag() {
    widthDrag = nil
    isWidthDragCancelled = false
    if let widthMonitor {
      NSEvent.removeMonitor(widthMonitor)
      self.widthMonitor = nil
    }
  }

  private func restyleImageLine(at index: Int) {
    guard let storage = textStorage, index >= 0, index < storage.length else { return }
    restyle(storage.mutableString.lineRange(for: NSRange(location: index, length: 0)))
  }

  /// 把第 index 张图的宽度写进正文（换成一条记了新宽度的令牌；一步撤销）。
  /// 上限按存的字算（令牌长了几位）；宽度写坏（不在 40…4000）时当没写宽度。可以直接调（单测用）
  @discardableResult
  func replaceImageWidth(at index: Int, width: Int) -> Bool {
    guard isEditable, let storage = textStorage, index >= 0, index < storage.length,
      let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil)
        as? NoteImageAttachment
    else { return false }
    var image = attachment.picture
    image.width = NoteImages.width(width)
    guard image != attachment.picture else { return true }
    if let maxBytes {
      let before = NoteImages.token(attachment.picture).utf8.count
      let after = NoteImages.token(image).utf8.count
      if after > before, reportedBytes - before + after > maxBytes {
        overflowed()
        return false
      }
    }
    let replacement = makeAttachment(for: image)
    let range = NSRange(location: index, length: 1)
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: "\u{FFFC}") else { return false }
    storage.replaceCharacters(in: range, with: NSAttributedString(attachment: replacement))
    didChangeText()
    setSelectedRange(range)
    return true
  }

  // MARK: 插图

  /// 往正文里插几张图（每张独占一行、一步撤销、插完光标在图后面）。location = nil 时插在当前选区。
  /// **正在组字时欠着**（动字会打断组字）：记下来，组字确认之后由 settle 补
  func insert(images: [NoteImages.Image], at location: Int? = nil) {
    guard !images.isEmpty, isEditable else { return }
    guard !hasMarkedText() else {
      pendingImages = images
      pendingImagesAt = location
      return
    }
    insertNow(images, at: location)
  }

  /// 组字确认之后补上欠着的插图
  func insertPendingImages() {
    guard !pendingImages.isEmpty else { return }
    let images = pendingImages
    let at = pendingImagesAt
    pendingImages = []
    pendingImagesAt = nil
    insertNow(images, at: at)
  }

  private func insertNow(_ images: [NoteImages.Image], at location: Int?) {
    guard let storage = textStorage, !images.isEmpty else { return }
    let range =
      location.map { NSRange(location: min(max($0, 0), storage.length), length: 0) }
      ?? selectedRange()
    let plan = NoteImages.insertion(
      in: storage.mutableString, replacing: range, count: images.count)
    let replacement = NSMutableAttributedString()
    if plan.lead { replacement.append(NSAttributedString(string: "\n")) }
    for (offset, image) in images.enumerated() {
      if offset > 0 { replacement.append(NSAttributedString(string: "\n")) }
      replacement.append(NSAttributedString(attachment: makeAttachment(for: image)))
    }
    if plan.trail { replacement.append(NSAttributedString(string: "\n")) }
    guard canFit(replacing: range, with: replacement) else { return }
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
    storage.replaceCharacters(in: range, with: replacement)
    didChangeText()
    let caret = min(range.location + plan.caret, storage.length)
    setSelectedRange(NSRange(location: caret, length: 0))
    scrollRangeToVisible(selectedRange())
  }

  /// 用一段富文本换掉 range（粘贴自家类型、去掉占位字符的纯文本走这里）：一步撤销，光标放到换完的后面
  @discardableResult
  func replaceSelection(with replacement: NSAttributedString, at range: NSRange) -> Bool {
    guard isEditable, let storage = textStorage else { return false }
    let range = clamped(range, in: storage)
    guard canFit(replacing: range, with: replacement) else { return false }
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: replacement.string) else { return false }
    storage.replaceCharacters(in: range, with: replacement)
    didChangeText()
    let caret = min(range.location + replacement.length, storage.length)
    setSelectedRange(NSRange(location: caret, length: 0))
    scrollRangeToVisible(selectedRange())
    return true
  }

  /// range 夹进正文的长度里。**不能直接用 NSIntersectionRange**：零长度的区间（光标、行尾）和别的区间算交集会塌成 {0,0}，
  /// 光标在正文末尾时粘进来的东西会跑到开头
  func clamped(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
    let location = min(max(range.location, 0), storage.length)
    let end = min(max(NSMaxRange(range), location), storage.length)
    return NSRange(location: location, length: end - location)
  }

  /// 这一段富文本按存的字算多少字节（附件按它的令牌那么长）
  func storedByteCount(of attributed: NSAttributedString) -> Int {
    guard attributed.length > 0 else { return 0 }
    let text = attributed.string as NSString
    var total = 0
    attributed.enumerateAttribute(
      .attachment, in: NSRange(location: 0, length: attributed.length)
    ) { value, range, _ in
      if let attachment = value as? NoteImageAttachment {
        total += NoteImages.token(attachment.picture).utf8.count * range.length
      } else {
        total += text.substring(with: range).utf8.count
      }
    }
    return total
  }

  /// 换完会不会超过正文上限（按存的形式算：一张图不会因为附件字符短就放过）。超了就提示音 + 报告
  func canFit(replacing range: NSRange, with replacement: NSAttributedString) -> Bool {
    guard let maxBytes else { return true }
    let removed = storedByteCount(of: range)
    let added = storedByteCount(of: replacement)
    guard added > removed, reportedBytes - removed + added > maxBytes else { return true }
    overflowed()
    return false
  }

  // MARK: 粘贴 / 拖进

  /// 剪贴板里有没有我们处理得了的图片（右键菜单 / 主菜单「粘贴」的可用状态：只有图时也要能点）
  func canPasteImages(from pasteboard: NSPasteboard) -> Bool {
    if pasteboard.string(forType: Self.noteTextType) != nil { return true }
    if !imageFileURLs(in: pasteboard).isEmpty { return true }
    // 有非空的纯文字：照现在的路走（父类那边本来就可用）
    if !(pasteboard.string(forType: .string) ?? "").isEmpty { return false }
    return firstImageData(in: pasteboard) != nil
  }

  /// 粘贴 / 拖进：读剪贴板的顺序见 paste(_:)。处理了返回 true
  @discardableResult
  func pasteImages(from pasteboard: NSPasteboard) -> Bool {
    guard isEditable, textStorage != nil else { return false }
    // ① 自家类型（便签正文，存的形式）：按令牌换成附件插进来，引用同一个文件、不复制文件
    if let stored = pasteboard.string(forType: Self.noteTextType) {
      pasteStored(stored)
      return true
    }
    // ② 图片文件：每张存进目录、各插一张
    let urls = imageFileURLs(in: pasteboard)
    if !urls.isEmpty {
      storeAndInsert(files: urls, at: selectedRange())
      return true
    }
    // ③ 有非空的纯文字：照现在走（粘成链接 / 照常粘贴纯文本）
    if !(pasteboard.string(forType: .string) ?? "").isEmpty { return false }
    // ④ 只有图片数据（截图、浏览器里「拷贝图像」）
    if let data = firstImageData(in: pasteboard) {
      storeAndInsert(data: data, at: selectedRange())
      return true
    }
    return false
  }

  /// 贴一段「存的形式」的正文（自家类型）：令牌换成附件、引用同一个文件；文件不在的照样插，画占位框
  func pasteStored(_ stored: String) {
    guard isEditable, textStorage != nil else { return }
    let replacement = NoteImageAttachment.editorString(
      from: stored, base: baseAttributes
    ) { makeAttachment(for: $0) }
    replaceSelection(with: replacement, at: selectedRange())
  }

  /// 拖进来（落点由系统先设成选区）：自家的类型、图片文件、图片数据；别的交给父类
  func readImageSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard isEditable else { return false }
    if type == Self.noteTextType {
      guard let stored = pboard.string(forType: type) else { return false }
      pasteStored(stored)
      return true
    }
    if type == .fileURL {
      let urls = imageFileURLs(in: pboard)
      guard !urls.isEmpty else { return false }
      storeAndInsert(files: urls, at: selectedRange())
      return true
    }
    guard UTType(type.rawValue)?.conforms(to: .image) == true,
      let data = pboard.data(forType: type), !data.isEmpty
    else { return false }
    storeAndInsert(data: data, at: selectedRange())
    return true
  }

  /// 剪贴板里是图片的文件（UTType 属于 .image 的）
  private func imageFileURLs(in pasteboard: NSPasteboard) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]
    return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
  }

  /// 剪贴板里的第一份图片数据（按类型的先后）
  private func firstImageData(in pasteboard: NSPasteboard) -> Data? {
    for type in pasteboard.types ?? []
    where UTType(type.rawValue)?.conforms(to: .image) == true {
      if let data = pasteboard.data(forType: type), !data.isEmpty { return data }
    }
    return nil
  }

  /// 图片文件 / 图片数据：**在主线程外**转码写盘，回主线程再插。插的时候按「是哪个编辑器、哪条便签」落：
  /// 等的这一下用户换了便签、关了便签就不插（文件变孤儿，由 30 天的清理收）。插的位置用发起时的选区；
  /// 这期间正文变了就插在当前光标处
  func storeAndInsert(files: [URL], at range: NSRange) {
    guard let store = imageStore else {
      return rejectImage(.unreadable)
    }
    let directory = store.directory
    let noteID = identifier?.rawValue
    let captured = reported
    Task { @MainActor in
      var images: [NoteImages.Image] = []
      var rejection: NoteImageStore.Rejection?
      for url in files {
        switch await NoteImageStore.store(fileAt: url, in: directory) {
        case .success(let stored):
          store.remember(stored)
          images.append(stored.image)
        case .failure(let reason):
          rejection = rejection ?? reason
        }
      }
      if let rejection { rejectImage(rejection) }
      insertStored(images, at: range, noteID: noteID, captured: captured)
    }
  }

  /// 同上，剪贴板里的图片数据
  func storeAndInsert(data: Data, at range: NSRange) {
    guard let store = imageStore else {
      return rejectImage(.unreadable)
    }
    let directory = store.directory
    let noteID = identifier?.rawValue
    let captured = reported
    Task { @MainActor in
      switch await NoteImageStore.store(data: data, in: directory) {
      case .success(let stored):
        store.remember(stored)
        insertStored([stored.image], at: range, noteID: noteID, captured: captured)
      case .failure(let reason):
        rejectImage(reason)
      }
    }
  }

  private func insertStored(
    _ images: [NoteImages.Image], at range: NSRange, noteID: String?, captured: String
  ) {
    guard !images.isEmpty, isEditable, window != nil, identifier?.rawValue == noteID else {
      return
    }
    let at = reported == captured ? range.location : selectedRange().location
    // 这一步是等存图的那一下回来之后才做的：可能落在自动的「一个事件一组」之外（单测里干脆关掉了自动分组），
    // 自己开一组，插图始终是一步撤销
    let manager = undoManager
    manager?.beginUndoGrouping()
    insert(images: images, at: at)
    manager?.endUndoGrouping()
  }

  /// 拒收 / 存不成：提示音 + 说一句为什么
  private func rejectImage(_ rejection: NoteImageStore.Rejection) {
    NSSound.beep()
    onImageProblem(rejection.notice)
  }

  // MARK: 复制 / 剪切 / 拖出

  /// 写剪贴板：自家的存的形式（带令牌）+ 纯文本（图片写「[图片]」）+ 选区正好是一张图时再写那张图本身。
  /// 没有选区（或者选的是空）给 nil，交给父类
  func writeNoteSelection(to pboard: NSPasteboard) -> Bool? {
    guard let storage = textStorage else { return nil }
    var stored: [String] = []
    var plain: [String] = []
    for value in selectedRanges {
      let range = clamped(value.rangeValue, in: storage)
      guard range.length > 0 else { continue }
      let slice = NoteImageAttachment.stored(
        from: storage.attributedSubstring(from: range))
      stored.append(slice)
      plain.append(NoteImages.display(slice))
    }
    guard !stored.isEmpty else { return nil }
    let image = selectedImageChar().flatMap { imageWrite(forCharacterAt: $0) }
    var types: [NSPasteboard.PasteboardType] = [Self.noteTextType, .string]
    if let image {
      types.append(image.type)
      if image.png != nil, image.type != .png { types.append(.png) }
    }
    pboard.declareTypes(types, owner: nil)
    pboard.setString(stored.joined(separator: "\n"), forType: Self.noteTextType)
    pboard.setString(plain.joined(separator: "\n"), forType: .string)
    if let image {
      pboard.setData(image.data, forType: image.type)
      if let png = image.png, image.type != .png { pboard.setData(png, forType: .png) }
    }
    return true
  }

  /// 选区正好是一张图时要写的图片本身：原文件的字节和类型；不是 PNG 的再加一份 PNG。
  /// ponytail: 转 PNG 在主线程上做（用户主动复制一张图，几 MB 是几十毫秒）；大图卡了再挪后台、异步写
  private func imageWrite(forCharacterAt index: Int)
    -> (data: Data, type: NSPasteboard.PasteboardType, png: Data?)?
  {
    guard let storage = textStorage,
      let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil)
        as? NoteImageAttachment, let data = try? Data(contentsOf: attachment.url)
    else { return nil }
    let type =
      UTType(filenameExtension: attachment.picture.ext).map {
        NSPasteboard.PasteboardType($0.identifier)
      } ?? .tiff
    guard attachment.picture.ext != "png" else { return (data, type, nil) }
    return (data, type, Self.pngData(from: data))
  }

  /// 转一份 PNG（ImageIO；转不出来给 nil）
  static func pngData(from data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  // MARK: 缩略图解好了

  /// 缩略图在后台解好了：只失效那张图所在的字（不重排、不动属性、不改行高——尺寸缓存是载入时就有的）
  func imageThumbnailArrived(image id: UUID?) {
    guard let id, let storage = textStorage else { return }
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
      value, range, _ in
      guard let attachment = value as? NoteImageAttachment, attachment.picture.id == id else {
        return
      }
      layoutManager?.invalidateDisplay(forCharacterRange: range)
    }
  }

  // MARK: 插入图片…（选文件面板）

  /// 右键菜单的「插入图片…」：不模态的选文件面板（只能选图片、可多选）。本 App 不在前台时先激活
  /// （面板才拿得到键盘），选完把前台还给原来的 App、键盘还给这条便签的正文
  @objc func insertImageFromPanel(_ sender: Any? = nil) {
    guard isEditable, imageStore != nil else { return NSSound.beep() }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.image]
    panel.prompt = "插入"
    panel.message = "选要插进便签的图片"
    let previous = NSApp.isActive ? nil : NSWorkspace.shared.frontmostApplication
    if previous != nil {
      NSApp.activate()
      if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
    let range = selectedRange()
    panel.begin { [weak self] response in
      previous?.activate()
      guard let self else { return }
      // 键盘还给这条便签的正文（那叠和浮动便签是不激活本 App 的面板）
      self.window?.makeFirstResponder(self)
      guard response == .OK, !panel.urls.isEmpty else { return }
      self.storeAndInsert(files: panel.urls, at: range)
    }
  }
}
