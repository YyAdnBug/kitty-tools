// 便签正文编辑器里的行内图片（Notes/NoteTextView.swift + NoteTextView+Images.swift + NoteImageAttachment.swift，第 7 批）
// 在屏外窗口里的行为：令牌 ↔ 附件字符互转（存的 = 读进来的）、附件不会被样式那一遍抹掉、附件字符上没有 hiddenKey、
// 光标 / 选区命令一次都不落进图片内部、⌫ / 选中删 / 撤销 / 重做、插图独占一行和一步撤销、上限按**存的字**算、
// 拖把手改宽度（只改显示，松手才写进正文，一步撤销）、粘贴的四个顺序、复制写出的三种类型、纯文字里的 U+FFFC 去掉、
// Markdown 开关来回切图还在、外面换了正文、读屏念「图片」。图片都是测试现画的，目录是临时的；
// 剪贴板全是自己建的（用完 releaseGlobally），不碰系统的，也不碰真实数据目录。

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

struct NoteTextViewImageTests {
  /// 撤销栈由它给的窗口（同 NoteDeckPanel / NotesWindow）
  private final class Host: NSWindow {
    let notes = UndoManager()
    override var undoManager: UndoManager? { notes }
  }

  private final class Rig {
    let directory: URL
    let store: NoteImageStore
    let window: Host
    let scroll = NSScrollView()
    let editor = NoteTextView.make()
    var changes: [String] = []
    var overflows = 0
    var problems: [String] = []
    var pasteboard: NSPasteboard?

    init(maxBytes: Int? = nil) throws {
      directory = FileManager.default.temporaryDirectory.appending(
        path: "kitty-notes-editor-image-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      store = NoteImageStore(directory: directory)
      let frame = CGRect(x: -30000, y: -30000, width: 420, height: 320)
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
      window = Host(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.notes.groupsByEvent = false
      editor.identifier = NSUserInterfaceItemIdentifier("便签甲")
      editor.imageStore = store
      editor.maxBytes = maxBytes
      editor.textContainerInset = NSSize(width: 9, height: 6)
      editor.onChange = { [unowned self] in changes.append($0) }
      editor.onOverflow = { [unowned self] in overflows += 1 }
      editor.onImageProblem = { [unowned self] title, detail in
        problems.append("\(title)|\(detail)")
      }
      scroll.hasVerticalScroller = true
      scroll.documentView = editor
      window.contentView = scroll
      editor.setPaper(
        NotePaper.all[2], fontSize: 15, markdown: true, spacing: .standard, paperIndex: 2)
      window.makeFirstResponder(editor)
    }

    /// 存一张真图进临时目录（拿到的令牌没有记宽度）
    func addImage(width: Int = 200, height: Int = 100, type: UTType = .png) async throws
      -> NoteImages.Image
    {
      let stored = try #require(
        try? await NoteImageStore.store(
          data: NoteImageFixture.data(type: type, width: width, height: height), in: directory
        ).get())
      store.remember(stored)
      return stored.image
    }

    func token(_ image: NoteImages.Image, width: Int? = nil) -> String {
      NoteImages.token(NoteImages.Image(id: image.id, ext: image.ext, width: width))
    }

    func load(_ body: String) {
      editor.setText(body)
      layout()
    }

    func layout() {
      scroll.layoutSubtreeIfNeeded()
      if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
    }

    /// 一步（一组撤销）
    func step(_ body: () throws -> Void) rethrows {
      window.notes.beginUndoGrouping()
      defer { window.notes.endUndoGrouping() }
      try body()
    }

    /// 现在存的形式（编辑器里那份转回令牌）
    var stored: String {
      NoteImageAttachment.stored(from: editor.textStorage ?? NSAttributedString())
    }

    /// 正文里所有图片的（位置、编号、记着的宽度）
    var images: [(index: Int, id: UUID, width: Int?)] {
      guard let storage = editor.textStorage else { return [] }
      var found: [(Int, UUID, Int?)] = []
      storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
        value, range, _ in
        guard let attachment = value as? NoteImageAttachment else { return }
        found.append((range.location, attachment.picture.id, attachment.picture.width))
      }
      return found.map { (index: $0.0, id: $0.1, width: $0.2) }
    }

    /// 造一个鼠标事件：point 是**视图自己的坐标**（翻转的、从上往下），事件里要的是窗口坐标（从下往上）
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }

    /// 等到正文里有 count 张图（存图在后台做，插回主线程）：按轮数等，不看墙上时间
    func waitForImages(_ count: Int) async {
      for _ in 0..<200 where images.count != count {
        try? await Task.sleep(for: .milliseconds(20))
      }
    }

    /// 真的 mouseExited 事件（mouseExited(with:) 会校验事件的类型，拿别的类型会抛异常）
    func exitEvent() throws -> NSEvent {
      try #require(
        NSEvent.enterExitEvent(
          with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
          userData: nil))
    }

    func pasteboardNamed(_ name: String) -> NSPasteboard {
      let board = NSPasteboard(name: NSPasteboard.Name(name))
      board.clearContents()
      pasteboard = board
      return board
    }
  }

  /// 读屏读到的那段字（accessibilityValue 在协议里也有一份属性声明，直接调会撞名字，走 KVC）
  private func spoken(_ view: NSTextView) -> String? {
    view.value(forKey: "accessibilityValue") as? String
  }

  /// 一段正文：第一行、一张图（200 宽）、第三行、行内图 + 字
  private func sample(_ rig: Rig, _ image: NoteImages.Image, _ other: NoteImages.Image) -> String {
    "第一行文字\n\(rig.token(image, width: 200))\n第三行\n前面\(rig.token(other, width: 120))后面\n末行"
  }

  // MARK: 互转

  @Test func loadsTokensAsAttachments() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = sample(rig, image, image)
    rig.load(body)
    #expect(rig.stored == body, "存的 = 读进来的")
    #expect(rig.images.count == 2)
    #expect(rig.images[0].index == 6, "「第一行文字」5 个字 + 换行，图在第 7 个字")
    #expect(rig.images[0].id == image.id)
    #expect(rig.images[0].width == 200)
    #expect(rig.editor.string.utf16.count < body.utf16.count, "编辑器里令牌变成了一个附件字符")
    // 编辑器里的字符是 U+FFFC
    #expect((rig.editor.string as NSString).character(at: rig.images[0].index) == 0xFFFC)
    // 附件字符上没有 hiddenKey（有的话它变成零宽的、图看不见）
    #expect(
      rig.editor.textStorage?.attribute(
        NoteStyles.hiddenKey, at: rig.images[0].index, effectiveRange: nil) == nil)
  }

  @Test func storingKeepsBarePlaceholders() async throws {
    let rig = try Rig()
    // 没挂我们附件的 U+FFFC（别处贴进来的）原样保留
    rig.load("前\u{FFFC}后")
    #expect(rig.stored == "前\u{FFFC}后")
    #expect(rig.images.isEmpty)
  }

  @Test func textOutsideChangesImages() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = "文字\n\(rig.token(image, width: 100))"
    rig.load(body)
    #expect(rig.images.count == 1)
    // 外面把图片拿掉了
    rig.editor.setText("只剩文字")
    #expect(rig.stored == "只剩文字")
    #expect(rig.images.isEmpty)
    // 外面又贴回来
    rig.editor.setText(body)
    #expect(rig.stored == body)
    #expect(rig.images.count == 1)
    // 给和外面一样的（存的形式）不动
    rig.editor.setText(body)
    #expect(rig.stored == body)
  }

  @Test func markdownToggleKeepsImages() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = "# 标题\n\(rig.token(image))\n**粗体**"
    rig.load(body)
    rig.editor.setPaper(
      NotePaper.all[2], fontSize: 15, markdown: false, spacing: .standard, paperIndex: 2)
    rig.layout()
    #expect(rig.stored == body, "Markdown 关掉：正文一个字都不变，图片还在")
    #expect(rig.images.count == 1)
    #expect(
      rig.editor.textStorage?.attribute(
        NoteStyles.hiddenKey, at: rig.images[0].index, effectiveRange: nil) == nil)
    rig.editor.setPaper(
      NotePaper.all[2], fontSize: 15, markdown: true, spacing: .standard, paperIndex: 2)
    rig.layout()
    #expect(rig.images.count == 1)
    #expect(rig.stored == body)
  }

  @Test func stylesDoNotHideTheAttachment() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    // 图片被粗体包着：样式那一遍的 setAttributes 会把 .attachment 抹掉，得放回去
    rig.load("**前\(rig.token(image))后**")
    rig.layout()
    #expect(rig.images.count == 1)
    let index = rig.images[0].index
    #expect(rig.editor.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) != nil)
    #expect(
      rig.editor.textStorage?.attribute(NoteStyles.hiddenKey, at: index, effectiveRange: nil) == nil
    )
    #expect(
      rig.editor.textStorage?.attribute(NoteStyles.lineFontKey, at: index, effectiveRange: nil)
        != nil)
    #expect(rig.stored == "**前\(rig.token(image))后**")
  }

  // MARK: 光标和删

  @Test func cursorCommandsNeverEnterTheImage() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let other = try await rig.addImage(width: 120, height: 90)
    rig.load(sample(rig, image, other))
    let images = rig.images
    let first = images[0].index
    let second = images[1].index
    let commands: [(String, Selector)] = [
      ("→", #selector(NSResponder.moveRight(_:))), ("←", #selector(NSResponder.moveLeft(_:))),
      ("↑", #selector(NSResponder.moveUp(_:))), ("↓", #selector(NSResponder.moveDown(_:))),
      ("⌥→", #selector(NSResponder.moveWordRight(_:))),
      ("⌥←", #selector(NSResponder.moveWordLeft(_:))),
      ("⌘→", #selector(NSResponder.moveToEndOfLine(_:))),
      ("⌘←", #selector(NSResponder.moveToBeginningOfLine(_:))),
      ("⇧→", #selector(NSResponder.moveRightAndModifySelection(_:))),
      ("⇧←", #selector(NSResponder.moveLeftAndModifySelection(_:))),
      ("⇧↓", #selector(NSResponder.moveDownAndModifySelection(_:))),
      ("⇧⌥→", #selector(NSResponder.moveWordRightAndModifySelection(_:))),
    ]
    let starts = [first - 1, first, first + 1, second - 1, second, second + 1]
    var inside = 0
    var total = 0
    for start in starts {
      for (_, selector) in commands {
        rig.editor.setSelectedRange(NSRange(location: start, length: 0))
        rig.editor.doCommand(by: selector)
        let selection = rig.editor.selectedRange()
        total += 1
        for image in [first, second]
        where selection.location > image
          && selection.location < image + 1
        {
          inside += 1
        }
        if selection.location > first, selection.location < first + 1 { inside += 1 }
      }
    }
    #expect(total > 0)
    #expect(inside == 0, "72 次那样的光标 / 选区命令一次都不该停进图片里")

    // 点图片正中：落在图前（不是图里面），单击选中整张
    let rect = try #require(rig.editor.imageRect(ofCharacterAt: first))
    let middle = NSPoint(x: rect.midX, y: rect.midY)
    #expect(rig.editor.imageChar(at: middle) == first)
    rig.editor.mouseDown(with: try rig.mouse(.leftMouseDown, at: middle))
    #expect(rig.editor.selectedRange() == NSRange(location: first, length: 1))
  }

  @Test func backspaceAfterImageDeletesItAndUndoes() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = "文字\n\(rig.token(image))\n后面"
    rig.load(body)
    let index = try #require(rig.images.first?.index)
    rig.editor.setSelectedRange(NSRange(location: index + 1, length: 0))
    rig.step { rig.editor.deleteBackward(nil) }
    #expect(rig.images.isEmpty, "图片后面按一次 ⌫ 整张删掉")
    #expect(!rig.stored.contains("kitty-note-image"), "不该露出令牌原文")
    rig.window.notes.undo()
    #expect(rig.stored == body)
    #expect(rig.images.count == 1)
  }

  @Test func deletingASelectedImageKeepsUndoInOneStep() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = "文字\n\(rig.token(image))\n后面"
    rig.load(body)
    let index = try #require(rig.images.first?.index)
    rig.editor.setSelectedRange(NSRange(location: index, length: 1))
    rig.step { rig.editor.deleteBackward(nil) }
    #expect(rig.images.isEmpty)
    rig.window.notes.undo()
    #expect(rig.stored == body)
    rig.window.notes.redo()
    #expect(rig.images.isEmpty)
  }

  @Test func typingNextToAnImageKeepsTheToken() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = "前面\(rig.token(image, width: 120))后面"
    rig.load(body)
    let index = try #require(rig.images.first?.index)
    rig.editor.setSelectedRange(NSRange(location: index + 1, length: 0))
    rig.step {
      rig.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    #expect(rig.stored == "前面\(rig.token(image, width: 120))你后面")
    #expect(rig.images.count == 1)
    // 打进去的字是基础样式（不带附件、不带藏起来的标记）
    let typed = index + 1
    #expect(rig.editor.textStorage?.attribute(.attachment, at: typed, effectiveRange: nil) == nil)
    #expect(
      rig.editor.textStorage?.attribute(NoteStyles.hiddenKey, at: typed, effectiveRange: nil) == nil
    )
    #expect(rig.changes.last == rig.stored)
  }

  // MARK: 插入

  @Test func insertingAnImageGivesItItsOwnLine() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("前半后半")
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.step { rig.editor.insert(images: [image]) }
    #expect(rig.stored == "前半\n\(rig.token(image))\n后半")
    #expect(rig.images.count == 1)
    #expect(
      rig.editor.selectedRange() == NSRange(location: 5, length: 0),
      "光标落到图下面那一行的行首（图后面那一行是「后半」）")
    #expect(rig.changes.last == rig.stored, "交出去的是存的形式")
    rig.window.notes.undo()
    #expect(rig.stored == "前半后半", "插图是一步撤销")
  }

  @Test func insertingSeveralImagesAndEditorWriterLocation() async throws {
    let rig = try Rig()
    let one = try await rig.addImage()
    let two = try await rig.addImage()
    rig.load("文字")
    // 光标在行尾（3）：前面有字，先换行
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.step { rig.editor.insert(images: [one, two]) }
    #expect(rig.stored == "文字\n\(rig.token(one))\n\(rig.token(two))\n")
    #expect(rig.images.count == 2)
    #expect(rig.editor.selectedRange() == NSRange(location: 7, length: 0), "光标在两张图下面那一行的行首")
    // 插到正文最前面：后面有字，图后面换行
    rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
    rig.step { rig.editor.insert(images: [one]) }
    #expect(rig.stored.hasPrefix("\(rig.token(one))\n"))
    #expect(rig.images.count == 3)
  }

  @Test func insertingWhileComposingWaitsForTheComposition() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("文字")
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.window.notes.beginUndoGrouping()
    rig.editor.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.editor.insert(images: [image])
    #expect(rig.images.isEmpty, "组字期间先不插")
    rig.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.window.notes.endUndoGrouping()
    rig.editor.breakUndoCoalescing()
    #expect(rig.images.count == 1, "组字确认之后补上")
    #expect(rig.stored.contains(rig.token(image)))
  }

  @Test func overflowCountsTheStoredForm() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    // 上限 = 现在的正文再加一点点：一张图（令牌 69 个字节）放不下，但附件字符只有 3 个字节
    rig.load("文字")
    rig.editor.maxBytes = 40
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.step { rig.editor.insert(images: [image]) }
    #expect(rig.images.isEmpty, "按存的字算：超过上限的那一次不进")
    #expect(rig.overflows == 1)
    #expect(rig.stored == "文字")
  }

  @Test func canFitUsesTheTokenLength() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("正文")
    // 还要算上插图时前面加的那个换行和后面补的那个（F16①：光标落到下一行）
    rig.editor.maxBytes = NoteImages.token(image).utf8.count + "正文".utf8.count + 2
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.step { rig.editor.insert(images: [image]) }
    #expect(rig.images.count == 1, "正好放下")
  }

  // MARK: 改宽度

  @Test func draggingTheHandleWritesTheWidthOnRelease() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("文字\n\(rig.token(image))")
    let index = try #require(rig.images.first?.index)
    let rect = try #require(rig.editor.imageRect(ofCharacterAt: index))
    #expect(rect.width == 200, "没记宽度：按原图点宽")
    let handle = try #require(rig.editor.handleRect(ofImageAt: index))
    #expect(rect.contains(NSPoint(x: handle.midX, y: handle.midY)))
    // 按在把手上 → 拖 +60 → 松手
    let start = NSPoint(x: handle.midX, y: handle.midY)
    try rig.step {
      rig.editor.beginWidthDrag(at: index, event: try rig.mouse(.leftMouseDown, at: start))
      #expect(rig.editor.widthDrag != nil)
      rig.editor.mouseDragged(
        with: try rig.mouse(.leftMouseDragged, at: NSPoint(x: start.x + 60, y: start.y)))
      #expect(rig.editor.widthDrag?.current == 260)
      #expect(rig.editor.imageCell(at: index)?.liveWidth == 260)
      #expect(rig.stored == "文字\n\(rig.token(image))", "拖的时候只改显示，不改字")
      rig.editor.mouseUp(
        with: try rig.mouse(.leftMouseUp, at: NSPoint(x: start.x + 60, y: start.y)))
    }
    let expected = Int(
      NoteTextView.draggedWidth(from: 200, by: 60, limit: rig.editor.availableWidth).rounded())
    #expect(expected == 260)
    #expect(rig.stored == "文字\n\(rig.token(image, width: 260))")
    #expect(rig.images.first?.width == 260)
    #expect(rig.changes.last == rig.stored)
    rig.window.notes.undo()
    #expect(rig.stored == "文字\n\(rig.token(image))", "改宽度是一步撤销")
  }

  @Test func escapeCancelsTheWidthDrag() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("\(rig.token(image))")
    let index = try #require(rig.images.first?.index)
    let rect = try #require(rig.editor.imageRect(ofCharacterAt: index))
    let handle = try #require(rig.editor.handleRect(ofImageAt: index))
    let start = NSPoint(x: handle.midX, y: handle.midY)
    rig.editor.beginWidthDrag(at: index, event: try rig.mouse(.leftMouseDown, at: start))
    #expect(rig.editor.widthDrag != nil)
    rig.editor.mouseDragged(
      with: try rig.mouse(.leftMouseDragged, at: NSPoint(x: start.x + 80, y: start.y)))
    #expect(rig.editor.widthDrag?.current == 280)
    #expect(rig.editor.imageCell(at: index)?.liveWidth == 280)
    #expect(rig.editor.imageRect(ofCharacterAt: index)?.width != rect.width, "拖着时看得见变大")
    rig.editor.cancelWidthDrag()
    #expect(rig.editor.widthDrag == nil)
    #expect(rig.stored == "\(rig.token(image))", "Esc 取消：字没变")
    #expect(rig.editor.imageRect(ofCharacterAt: index)?.width == rect.width, "回到原来的大小")
  }

  @Test func draggedWidthIsClamped() {
    #expect(NoteTextView.draggedWidth(from: 200, by: 100, limit: 300) == 300)
    #expect(NoteTextView.draggedWidth(from: 200, by: -180, limit: 600) == 40)
    #expect(NoteTextView.draggedWidth(from: 200, by: -10, limit: 600) == 190)
    #expect(NoteTextView.draggedWidth(from: 200, by: 400, limit: 30) == 40, "可用宽比最小宽度还小时给最小宽")
  }

  @Test func storedWidthFollowsTheAvailableWidth() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 900, height: 450)
    rig.load("\(rig.token(image, width: 800))")
    let index = try #require(rig.images.first?.index)
    // 记的 800 比正文可用宽还宽：显示时缩到可用宽（比例跟着）
    let wide = try #require(rig.editor.imageRect(ofCharacterAt: index))
    #expect(abs(wide.width - rig.editor.availableWidth) < 2)
    #expect(abs(wide.height - wide.width / 2) < 1.5, "锁比例（原图 900 × 450）")
    // 正文框变窄到 300：跟着变窄
    rig.editor.setFrameSize(NSSize(width: 300, height: 320))
    rig.layout()
    let narrow = try #require(rig.editor.imageRect(ofCharacterAt: index))
    #expect(narrow.width < wide.width)
    #expect(abs(narrow.width - rig.editor.availableWidth) < 2)
    #expect(rig.stored.contains("image|800]("), "重排只改显示，存的宽度不变")
    // 记的宽度比可用宽小时用记的那个
    rig.editor.setFrameSize(NSSize(width: 420, height: 320))
    rig.load("\(rig.token(image, width: 200))")
    let small = try #require(rig.editor.imageRect(ofCharacterAt: index))
    #expect(small.width == 200)
    #expect(abs(small.height - 100) < 1.5)
  }

  @Test func autoWidthFollowsTheAvailableWidth() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 900, height: 450)
    rig.load("\(rig.token(image))")
    let index = try #require(rig.images.first?.index)
    let wide = try #require(rig.editor.imageRect(ofCharacterAt: index))
    #expect(abs(wide.width - rig.editor.availableWidth) < 2, "没记宽度：不超过可用宽")
    rig.editor.setFrameSize(NSSize(width: 300, height: 320))
    rig.layout()
    let narrow = try #require(rig.editor.imageRect(ofCharacterAt: index))
    #expect(narrow.width < wide.width, "正文框变窄：跟着变")
    #expect(abs(narrow.width - rig.editor.availableWidth) < 2)
  }

  // MARK: 复制 / 粘贴

  @Test func copyWritesOurTypeTextAndTheImageItself() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("\(rig.token(image, width: 150))")
    let board = rig.pasteboardNamed("kitty-notes-copy-\(UUID().uuidString)")
    let index = try #require(rig.images.first?.index)
    rig.editor.setSelectedRange(NSRange(location: index, length: 1))
    #expect(rig.editor.writeSelection(to: board, types: rig.editor.writablePasteboardTypes))
    #expect(board.string(forType: NoteTextView.noteTextType) == rig.token(image, width: 150))
    #expect(board.string(forType: .string) == "[图片]")
    let written = try #require(board.data(forType: .png))
    let source = try #require(CGImageSourceCreateWithData(written as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier, "原文件的字节和类型")
    board.releaseGlobally()
  }

  @Test func copyOfTextWithAnImageWritesPlaceholder() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = "第一行\n\(rig.token(image))"
    rig.load(body)
    let board = rig.pasteboardNamed("kitty-notes-copy-\(UUID().uuidString)")
    rig.editor.setSelectedRange(NSRange(location: 0, length: (body as NSString).length))
    #expect(rig.editor.writeSelection(to: board, types: rig.editor.writablePasteboardTypes))
    #expect(board.string(forType: .string) == "第一行\n[图片]")
    #expect(board.string(forType: NoteTextView.noteTextType) == body)
    board.releaseGlobally()
  }

  @Test func pastingOurTypeKeepsTheSameFile() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let body = "来源\n\(rig.token(image, width: 90))"
    rig.load(body)
    let board = rig.pasteboardNamed("kitty-notes-copy-\(UUID().uuidString)")
    rig.editor.setSelectedRange(NSRange(location: 0, length: (body as NSString).length))
    _ = rig.editor.writeSelection(to: board, types: rig.editor.writablePasteboardTypes)
    // 贴到末尾
    rig.editor.setSelectedRange(
      NSRange(location: (rig.editor.string as NSString).length, length: 0))
    rig.editor.pasteboard = board
    rig.step { rig.editor.paste(nil) }
    #expect(rig.images.count == 2)
    #expect(rig.images.map(\.id) == [image.id, image.id], "引用同一个文件、不复制文件")
    #expect(rig.store.files().count == 1)
    board.releaseGlobally()
  }

  @Test func pasteOrderOwnTypeThenFilesThenTextThenImageData() async throws {
    let rig = try Rig()
    // ① 自家类型排在图片文件前面
    let image = try await rig.addImage()
    let board = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    board.setString(rig.token(image), forType: NoteTextView.noteTextType)
    board.setString("一段文字", forType: .string)
    rig.editor.pasteboard = board
    rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
    var handled = false
    rig.step { handled = rig.editor.pasteImages(from: board) }
    #expect(handled)
    #expect(rig.images.count == 1)
    #expect(rig.store.files().count == 1, "自家类型不复制文件")
    board.releaseGlobally()

    // ② 图片文件排在纯文字前面（拷文件时带上文件名，要的还是图）。存图在后台做，等它回来
    let file = rig.directory.appending(path: "外星.png")
    try NoteImageFixture.data(type: .png, width: 40, height: 30).write(to: file)
    let second = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    second.writeObjects([file as NSURL])
    second.setString("外星.png", forType: .string)
    rig.editor.pasteboard = second
    rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(rig.editor.pasteImages(from: second))
    await rig.waitForImages(2)
    #expect(rig.images.count == 2)
    second.releaseGlobally()

    // ③ 有非空的纯文字：不走图片那条路（带一张「渲染图」的文稿，用户要的是字）
    let third = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    third.setString("文稿里的字", forType: .string)
    third.setData(NoteImageFixture.data(type: .png, width: 20, height: 20), forType: .tiff)
    rig.editor.pasteboard = third
    #expect(!rig.editor.pasteImages(from: third))
    #expect(rig.images.count == 2, "什么都没插")
    third.releaseGlobally()

    // ④ 只有图片数据
    let fourth = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    fourth.setData(NoteImageFixture.data(type: .png, width: 50, height: 25), forType: .png)
    rig.editor.pasteboard = fourth
    rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(rig.editor.pasteImages(from: fourth))
    await rig.waitForImages(3)
    #expect(rig.images.count == 3)
    fourth.releaseGlobally()
  }

  @Test func pastePlainTextStripsPlaceholders() async throws {
    let rig = try Rig()
    rig.load("abc")
    let board = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    board.setString("前\u{FFFC}后", forType: .string)
    rig.editor.pasteboard = board
    rig.editor.setSelectedRange(NSRange(location: 3, length: 0))
    rig.step { rig.editor.paste(nil) }
    #expect(rig.stored == "abc前后", "别的 App 里那张图的占位字符不要带进来")
    board.releaseGlobally()
  }

  @Test func pasteOfBrokenFileStillShowsPlaceholder() async throws {
    let rig = try Rig()
    // 令牌指向一个文件不在的编号：照样插，画占位框（存的字不丢）
    let missing = NoteImages.Image(id: UUID(), ext: "png", width: nil)
    let board = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    board.setString("\(rig.token(missing))", forType: NoteTextView.noteTextType)
    rig.editor.pasteboard = board
    rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
    rig.step { rig.editor.paste(board) }
    #expect(rig.images.count == 1)
    #expect(rig.stored == rig.token(missing))
    board.releaseGlobally()
  }

  /// F12：选中的是图（或选区带图）时粘网址**不包成链接**（包了图会被换成一个裸 U+FFFC 的链接、图丢了）：
  /// 照常粘贴纯文字，正文里不留令牌、也不留没挂附件的占位字符
  @Test func linkPasteOverAnImagePastesPlainText() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("文字\n\(rig.token(image))")
    let index = try #require(rig.images.first?.index)
    #expect(
      rig.editor.textStorage?.attribute(NoteStyles.imageLineKey, at: index, effectiveRange: nil)
        != nil)
    rig.editor.setSelectedRange(NSRange(location: index, length: 1))
    let board = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    board.setString("https://example.com/a", forType: .string)
    rig.editor.pasteboard = board
    rig.step { rig.editor.paste(nil) }
    #expect(rig.images.isEmpty, "选中的那张图被网址换掉了（不是换成一个坏掉的链接）")
    #expect(rig.stored == "文字\nhttps://example.com/a")
    #expect(!rig.stored.contains("kitty-note-image"), "不许留下令牌原文")
    #expect(!rig.stored.contains("\u{FFFC}"), "不许留下没挂附件的占位字符")
    #expect(!rig.stored.contains("]("), "不许粘成一个链接")
    #expect(
      rig.editor.textStorage?.attribute(NoteStyles.imageLineKey, at: index, effectiveRange: nil)
        == nil, "这一行不再是图片行")
    board.releaseGlobally()
  }

  /// F12 的另一半：`selectionContainsAttachment` 只看挂着我们附件的字（裸 U+FFFC 不算）
  @Test func selectionWithAnAttachmentIsDetected() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("前\(rig.token(image))后")
    let index = try #require(rig.images.first?.index)
    #expect(rig.editor.selectionContainsAttachment(NSRange(location: index, length: 1)))
    #expect(rig.editor.selectionContainsAttachment(NSRange(location: 0, length: index + 1)))
    #expect(!rig.editor.selectionContainsAttachment(NSRange(location: 0, length: 1)))
    #expect(!rig.editor.selectionContainsAttachment(NSRange(location: 0, length: 0)))
  }

  // MARK: 读屏

  /// F13：不再重写 accessibilityValue（重写把一个附件字符换成两个字，读屏的选区、按行范围全按存储的下标算，
  /// 图后面的位置就全错一位）。系统给的就是文本存储那一份（附件是 U+FFFC，长度不变）；图片念什么由附件 cell 的
  /// accessibilityLabel 给（R10）
  @Test func accessibilityKeepsTheStorageLengthAndLabelsTheCell() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("前面\(rig.token(image))后面")
    let value = try #require(spoken(rig.editor))
    #expect(value == "前面\u{FFFC}后面")
    #expect((value as NSString).length == (rig.editor.string as NSString).length, "替换后长度不变")
    #expect(!value.contains("kitty-note-image"), "不念令牌")
    let index = try #require(rig.images.first?.index)
    #expect(rig.editor.imageCell(at: index)?.accessibilityLabel() == "图片")
    rig.load("没有图片")
    #expect(spoken(rig.editor) == "没有图片")
  }

  // MARK: 右键菜单

  @Test func contextMenuHasInsertImageItem() throws {
    let rig = try Rig()
    rig.load("文字")
    let event = try rig.mouse(.rightMouseDown, at: NSPoint(x: 12, y: 12))
    let menu = try #require(rig.editor.menu(for: event))
    let titles = menu.items.map(\.title)
    #expect(titles.contains(NoteTextView.insertImageTitle))
    #expect(titles.first == NotesWindowModel.taskTitle, "任务还是在最前面")
    #expect(titles.dropFirst().first == NoteTextView.formatTitle)
  }
  // MARK: 第 7 批评审后的修复（F1–F25）

  /// F2：剪贴板里是**纯文字**时主菜单 / 右键的「粘贴」要可用（原来直接返回 `isEditable && canPasteImages`，
  /// 有字时 `canPasteImages` 是 false，全部便签窗口里 ⌘V 粘不了字）；只有图片数据也可用；空剪贴板照父类
  @Test func pasteAvailabilityFollowsTheClipboard() throws {
    let rig = try Rig()
    rig.load("文字")
    let item = NSMenuItem(
      title: "粘贴", action: #selector(NSTextView.paste(_:)), keyEquivalent: "")
    func available(_ board: NSPasteboard) -> Bool {
      rig.editor.pasteboard = board
      return rig.editor.validateUserInterfaceItem(item)
    }
    let text = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    text.setString("一段字", forType: .string)
    #expect(available(text), "纯文字：可用")
    let image = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    image.setData(NoteImageFixture.data(type: .png, width: 20, height: 20), forType: .png)
    #expect(available(image), "只有图片数据：可用")
    let empty = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    // 空剪贴板：不可用。**判的是编辑器自己读的那个剪贴板**（不问父类：父类看的是系统剪贴板，结果会跟着用户当时
    // 拷了什么变——原来这里纯文字那一条就因此在用户剪贴板里只有图时红过）
    #expect(!available(empty), "空剪贴板：不可用")
    #expect(!rig.editor.canPasteImages(from: empty), "空剪贴板没有图可粘")
    rig.editor.isEditable = false
    #expect(!available(text), "不能编辑：不可用")
    rig.editor.isEditable = true
    text.releaseGlobally()
    image.releaseGlobally()
    empty.releaseGlobally()
  }

  /// F3：比正文可用宽还宽的图夹到可用宽、高按比例；图在自己的行片段里（不往上盖住前面的字）；
  /// 引用里、代码块里的图跟着窄（可用宽 = 正文可用宽 − 这一行的缩进）；描边矩形和排出来的那一块一致
  @Test func wideImagesFollowTheAvailableWidth() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 1440, height: 900)
    func check(_ body: String, indent: CGFloat, _ label: String) throws {
      rig.load(body)
      let index = try #require(rig.images.first?.index)
      let rect = try #require(rig.editor.imageRect(ofCharacterAt: index))
      let manager = try #require(rig.editor.layoutManager)
      let glyph = manager.glyphIndexForCharacter(at: index)
      let size = manager.attachmentSize(forGlyphAt: glyph)
      let expected = rig.editor.availableWidth - indent
      #expect(abs(rect.width - expected) < 2, "\(label)：宽夹到可用宽（减这一行的缩进）")
      #expect(abs(rect.height - rect.width * 900 / 1440) < 2, "\(label)：高按比例")
      // attachmentSize 是布局管理器自己另算的一版（比真排出来的宽一点：它是拿行首的提议算的），
      // 描边 / 把手 / 命中一律按 boundingRect 那一块（上面比过它和画出来的图逐像素一致）
      #expect(size.width >= rect.width - 0.5, "\(label)：排出来的块不小于描边的块")
      let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let origin = rig.editor.textContainerOrigin
      #expect(rect.minY - origin.y >= fragment.minY - 0.5, "\(label)：图的上沿不高过行片段的上沿（不盖住上一行）")
      #expect(rect.maxY - origin.y <= fragment.maxY + 0.5, "\(label)：图在行片段里")
    }
    try check("前面\n\(rig.token(image))\n后面", indent: 0, "普通行")
    // 往下好几十行的图：图的上下沿照样落在自己的行片段里（布局代理给图片行的基线要和行片段对得上，
    // 不能只在前两行碰巧对）
    try check(
      String(repeating: "一行字\n", count: 40) + "\(rig.token(image))\n后面", indent: 0, "第 41 行")
    try check("> \(rig.token(image))", indent: NoteStyles.quoteIndent, "引用里")
    try check("```\n\(rig.token(image))\n```", indent: NoteStyles.codeInset * 2, "代码块里")
  }

  /// F16②：图后面同一段的长字折行后，**不含图的那几个行片段是正文行高**（原来整段的行高都定死成图高）
  @Test func wrappedLinesAfterAnImageKeepTheBodyHeight() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 200, height: 100)
    rig.load("\(rig.token(image)) " + String(repeating: "字", count: 200))
    rig.layout()
    let manager = try #require(rig.editor.layoutManager)
    let bodyHeight = NoteStyles.Theme(
      paper: NotePaper.all[2], fontSize: 15, markdown: true, spacing: .standard
    ).lineHeight(15)
    var (tall, normal) = (0, 0)
    var glyph = 0
    while glyph < manager.numberOfGlyphs {
      var range = NSRange()
      let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
      let chars = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
      var isImage = false
      rig.editor.textStorage?.enumerateAttribute(.attachment, in: chars) { value, _, stop in
        if value != nil {
          isImage = true
          stop.pointee = true
        }
      }
      if isImage {
        tall += 1
        #expect(fragment.height >= 100 + NoteImageLayout.padding * 2 - 0.5, "图那一行要撑到图高 + 留白")
      } else {
        normal += 1
        #expect(abs(fragment.height - bodyHeight) < 0.5, "折出来的别的行是正文行高")
      }
      glyph = NSMaxRange(range)
    }
    #expect(tall == 1 && normal >= 2, "一个图片行片段 + 至少两个折行片段")
  }

  /// F4：组字中欠着的插图补上之后，**交出去的最后一次**要带令牌（原来外层 settle 又把不带图的正文交了一遍）
  @Test func pendingImageIsInTheLastReportedBody() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("文字")
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.window.notes.beginUndoGrouping()
    rig.editor.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.editor.insert(images: [image])
    rig.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.window.notes.endUndoGrouping()
    rig.editor.breakUndoCoalescing()
    #expect(rig.images.count == 1)
    let last = try #require(rig.changes.last)
    #expect(last.contains(rig.token(image)), "最后一次交出去的正文带令牌（图不能丢）")
    #expect(rig.stored.contains(rig.token(image)))
  }

  /// F23：异步插图**换掉发起那一刻的整段选区**（原来只用了 range.location，选中的字留着）；
  /// 组字中连着欠两批插图都要插上（原来后一批把前一批顶掉）
  @Test func asyncInsertReplacesTheCapturedSelectionAndKeepsEveryBatch() async throws {
    let rig = try Rig()
    rig.load("前中后")
    let file = rig.directory.appending(path: "异步.png")
    try NoteImageFixture.data(type: .png, width: 40, height: 30).write(to: file)
    rig.editor.setSelectedRange(NSRange(location: 1, length: 1))
    rig.editor.storeAndInsert(files: [file], at: rig.editor.selectedRange())
    await rig.waitForImages(1)
    #expect(!rig.stored.contains("中"), "选中的那段字要被换掉")
    #expect(rig.stored.contains("前") && rig.stored.contains("后"))
    #expect(rig.images.count == 1)

    // 组字中欠两批
    let one = try await rig.addImage()
    let two = try await rig.addImage()
    rig.load("文字")
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.window.notes.beginUndoGrouping()
    rig.editor.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.editor.insert(images: [one])
    rig.editor.insert(images: [two])
    #expect(rig.images.isEmpty, "组字期间先欠着")
    rig.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.window.notes.endUndoGrouping()
    rig.editor.breakUndoCoalescing()
    #expect(rig.images.count == 2, "连着欠的两批都要插上")
    #expect(rig.stored.contains(rig.token(one)) && rig.stored.contains(rig.token(two)))
  }

  /// F5：剪贴板 / 拖进来同时有字和图时，进来的先是字（表格、文稿复制的「字 + 渲染图」、访达拷文件的图标 TIFF）
  @Test func textWinsOverAnAttachedImage() async throws {
    let rig = try Rig()
    rig.load("前面")
    let board = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    board.setString("文稿里的字", forType: .string)
    board.setData(NoteImageFixture.data(type: .png, width: 20, height: 20), forType: .tiff)
    rig.editor.pasteboard = board
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.step { rig.editor.paste(nil) }
    #expect(rig.images.isEmpty, "进来的应该是字，不是图")
    #expect(rig.stored == "前面文稿里的字")
    #expect(rig.store.files().isEmpty, "不该往目录里多出文件")
    // 拖进来（readSelection）照粘贴的同一个顺序：图片数据这条路交给父类按字读
    #expect(!rig.editor.readImageSelection(from: board, type: .tiff))
    #expect(rig.images.isEmpty)
    rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
    var read = false
    rig.step { read = rig.editor.readSelection(from: board, type: .string) }
    #expect(read, "交给父类按字读")
    #expect(rig.stored.contains("文稿里的字"))
    // 只有图片数据：进来的是图
    let onlyImage = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    onlyImage.setData(NoteImageFixture.data(type: .png, width: 20, height: 20), forType: .tiff)
    #expect(rig.editor.readImageSelection(from: onlyImage, type: .tiff))
    await rig.waitForImages(1)
    #expect(rig.images.count == 1)
    board.releaseGlobally()
    onlyImage.releaseGlobally()
  }

  /// F14：剪贴板里的图片数据先取 PNG（原图、体积小），没有再取 TIFF（预览、浏览器常常先给未压缩的 TIFF）
  @Test func pngDataIsPreferredOverTIFF() async throws {
    let rig = try Rig()
    rig.load("文字")
    let board = rig.pasteboardNamed("kitty-notes-paste-\(UUID().uuidString)")
    board.setData(NoteImageFixture.data(type: .tiff, width: 20, height: 20), forType: .tiff)
    board.setData(NoteImageFixture.data(type: .png, width: 30, height: 20), forType: .png)
    rig.editor.pasteboard = board
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.step { rig.editor.paste(nil) }
    await rig.waitForImages(1)
    let id = try #require(rig.images.first?.id)
    #expect(rig.store.size(of: id, ext: "png")?.pixelWidth == 30, "取的是 PNG 那一份")
    board.releaseGlobally()
  }

  /// F15：任务行里插图（方框后面）——图留在这一行，不被挤到下一行
  @Test func imageAfterATaskBoxStaysOnTheLine() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("☐ 买菜")
    rig.editor.setSelectedRange(NSRange(location: 2, length: 0))
    rig.step { rig.editor.insert(images: [image]) }
    #expect(rig.stored == "☐ \(rig.token(image))\n买菜", "图在方框后面那一行")
    #expect(rig.images.count == 1)
  }

  /// F8：拖把手松手之后清掉临时的宽度——撤销回来的是原来那个附件，屏上也回到原来的宽度；
  /// 按住不拖就松手，没记宽度的图照旧跟着正文框变
  @Test func releaseClearsTheTemporaryWidth() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 200, height: 100)
    rig.load("文字\n\(rig.token(image))")
    let index = try #require(rig.images.first?.index)
    let rect = try #require(rig.editor.imageRect(ofCharacterAt: index))
    let handle = try #require(rig.editor.handleRect(ofImageAt: index))
    rig.window.notes.beginUndoGrouping()
    rig.editor.beginWidthDrag(
      at: index, event: try rig.mouse(.leftMouseDown, at: NSPoint(x: handle.midX, y: handle.midY)))
    rig.editor.mouseDragged(
      with: try rig.mouse(
        .leftMouseDragged, at: NSPoint(x: handle.midX + 60, y: handle.midY)))
    rig.editor.mouseUp(
      with: try rig.mouse(.leftMouseUp, at: NSPoint(x: handle.midX + 60, y: handle.midY)))
    rig.window.notes.endUndoGrouping()
    #expect(rig.stored.contains("image|260]("))
    #expect(rig.editor.imageCell(at: index)?.liveWidth == nil, "松手之后临时的宽度要清掉")
    rig.window.notes.undo()
    let restored = try #require(rig.editor.imageRect(ofCharacterAt: index))
    #expect(abs(restored.width - rect.width) < 0.5, "撤销之后排出来的宽度回到原来的")

    // 按住没拖就松手：没记宽度的图照着正文框变（用一张比正文框宽的图才看得出）
    let wideImage = try await rig.addImage(width: 900, height: 450)
    rig.load("文字\n\(rig.token(wideImage))")
    let index2 = try #require(rig.images.first?.index)
    let handle2 = try #require(rig.editor.handleRect(ofImageAt: index2))
    rig.editor.beginWidthDrag(
      at: index2,
      event: try rig.mouse(.leftMouseDown, at: NSPoint(x: handle2.midX, y: handle2.midY)))
    rig.editor.mouseUp(
      with: try rig.mouse(.leftMouseUp, at: NSPoint(x: handle2.midX, y: handle2.midY)))
    #expect(rig.editor.imageCell(at: index2)?.liveWidth == nil)
    let wide = try #require(rig.editor.imageRect(ofCharacterAt: index2)).width
    rig.editor.setFrameSize(NSSize(width: 300, height: 320))
    rig.layout()
    let narrow = try #require(rig.editor.imageRect(ofCharacterAt: index2)).width
    #expect(narrow < wide, "没记宽度的图还是要跟着正文框变")
  }

  /// F17：图片行**行首**组字时图不往上跳（typingAttributes 也要带上 imageLineKey）
  @Test func composingAtTheStartOfAnImageLineKeepsTheImageInPlace() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 200, height: 100)
    rig.load(rig.token(image))
    let index = try #require(rig.images.first?.index)
    let before = try #require(rig.editor.imageRect(ofCharacterAt: index))
    rig.window.notes.beginUndoGrouping()
    rig.editor.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.layout()
    let moved = try #require(rig.images.first?.index, "组字插在图片前面：图的字往后挪了")
    let after = try #require(rig.editor.imageRect(ofCharacterAt: moved))
    #expect(abs(after.minY - before.minY) < 0.5, "组字期间图的上下位置不跳")
    #expect(abs(after.height - before.height) < 0.5)
    rig.editor.unmarkText()
    rig.window.notes.endUndoGrouping()
  }

  /// F18：组字中改宽度**不当场重排**（组字期间不动属性），确认之后补上：图片行的高按新的宽度。
  /// 不补的话这一行停在旧宽度（原来在 setFrameSize 里当场排，组字中那一次直接跳过、事后不补）
  @Test func widthChangeWhileComposingAppliesAfterTheComposition() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 900, height: 450)
    rig.load(rig.token(image))
    let index = try #require(rig.images.first?.index)
    func imageLineHeight(_ at: Int) -> CGFloat? {
      rig.editor.textStorage?.attribute(NoteStyles.imageLineKey, at: at, effectiveRange: nil)
        as? CGFloat
    }
    let before = try #require(imageLineHeight(index))
    rig.window.notes.beginUndoGrouping()
    rig.editor.setMarkedText(
      "n", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.editor.setFrameSize(NSSize(width: 300, height: 320))
    rig.layout()
    let moved = try #require(rig.images.first?.index)
    #expect(
      abs((imageLineHeight(moved) ?? 0) - before) < 0.5,
      "组字期间不动属性：图片行的高还是旧的（当场重排会把这一遍的版作废）")
    rig.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
    rig.window.notes.endUndoGrouping()
    rig.editor.breakUndoCoalescing()
    for _ in 0..<200 where abs((imageLineHeight(moved) ?? 0) - before) < 0.5 {
      try await Task.sleep(for: .milliseconds(10))
    }
    let after = try #require(imageLineHeight(moved))
    #expect(after < before, "确认之后图片行按新的宽度重排")
    #expect(
      abs((rig.editor.imageRect(ofCharacterAt: moved)?.width ?? 0) - rig.editor.availableWidth)
        < 2,
      "排出来的图就是新的可用宽（比正文框宽的图夹到可用宽）")
    #expect(abs(after - rig.editor.availableWidth * 450 / 900) < 2, "行高按新的宽度")
  }

  /// F20：鼠标离开正文框、改过字之后，悬停的那张图要清掉（不然把手一直画着 / 指到别的字上）
  @Test func hoveredImageIsClearedWhenLeavingOrEditing() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("前面\(rig.token(image))后面")
    let index = try #require(rig.images.first?.index)
    let rect = try #require(rig.editor.imageRect(ofCharacterAt: index))
    rig.editor.updateHoveredImage(at: NSPoint(x: rect.midX, y: rect.midY))
    #expect(rig.editor.hoveredImage == index)
    rig.editor.mouseExited(with: try rig.exitEvent())
    #expect(rig.editor.hoveredImage == nil, "离开正文框：把手不画了")
    rig.editor.updateHoveredImage(at: NSPoint(x: rect.midX, y: rect.midY))
    #expect(rig.editor.hoveredImage == index)
    rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
    rig.step {
      rig.editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    #expect(rig.editor.hoveredImage == nil, "改过字：悬停的下标可能已经指到别的字上")
  }

  /// F21：没记宽度的图不被放小（最小 40 只管令牌里记了宽度的和拖把手）
  @Test func smallImagesAreNotEnlarged() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 16, height: 16)
    rig.load(rig.token(image))
    let index = try #require(rig.images.first?.index)
    #expect(try #require(rig.editor.imageRect(ofCharacterAt: index)).width == 16, "小图标照原样")
    rig.load(rig.token(image, width: 40))
    #expect(try #require(rig.editor.imageRect(ofCharacterAt: index)).width == 40)
    // 拖把手的临时宽度：最小 40
    let metrics = NoteImageSize(
      pixelWidth: 16, pixelHeight: 16, dpi: 72, orientation: 1,
      pointSize: CGSize(width: 16, height: 16))
    #expect(
      NoteImageLayout.size(image: image, metrics: metrics, available: 300, live: 10).width == 40)
    #expect(NoteImageLayout.size(image: image, metrics: metrics, available: 300).width == 16)
  }

  /// F24：光标 / 选区命令把图片当成**一个字**——照一张表比对每条命令的落点。
  /// 原来那条 `location > image && location < image + 1` 对整数永远不成立，是空检验
  @Test func cursorCommandsLandWhereTheTableSays() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let other = try await rig.addImage(width: 120, height: 90)
    rig.load(sample(rig, image, other))
    let images = rig.images
    let first = images[0].index
    let second = images[1].index
    // （起点，命令，期望的 location，期望的 length）
    let table: [(Int, Selector, Int, Int)] = [
      (first, #selector(NSResponder.moveRight(_:)), first + 1, 0),
      (first, #selector(NSResponder.moveLeft(_:)), first - 1, 0),
      (first, #selector(NSResponder.moveWordRight(_:)), first + 1, 0),
      (first, #selector(NSResponder.moveToBeginningOfLine(_:)), first, 0),
      (first, #selector(NSResponder.moveRightAndModifySelection(_:)), first, 1),
      (first, #selector(NSResponder.moveLeftAndModifySelection(_:)), first - 1, 1),
      (first + 1, #selector(NSResponder.moveLeft(_:)), first, 0),
      (first + 1, #selector(NSResponder.moveRight(_:)), first + 2, 0),
      (first + 1, #selector(NSResponder.moveLeftAndModifySelection(_:)), first, 1),
      (second, #selector(NSResponder.moveRight(_:)), second + 1, 0),
      (second, #selector(NSResponder.moveLeft(_:)), second - 1, 0),
      (second, #selector(NSResponder.moveWordLeft(_:)), second - 2, 0),
      (second, #selector(NSResponder.moveRightAndModifySelection(_:)), second, 1),
      (second + 1, #selector(NSResponder.moveLeft(_:)), second, 0),
      (second + 1, #selector(NSResponder.moveLeftAndModifySelection(_:)), second, 1),
    ]
    for (start, selector, location, length) in table {
      rig.editor.setSelectedRange(NSRange(location: start, length: 0))
      rig.editor.doCommand(by: selector)
      #expect(
        rig.editor.selectedRange() == NSRange(location: location, length: length),
        "从 \(start) 出发：\(NSStringFromSelector(selector)) 该落到 \(location)+\(length)")
    }
  }

  /// F9：插图被拒时编辑器把**标题和说明分开**交给宿主（再经 model 手里的岛说出来）
  @Test func rejectionReportsTitleAndDetail() async throws {
    let rig = try Rig()
    rig.load("文字")
    let bad = rig.directory.appending(path: "假.png")
    try Data("这不是图片".utf8).write(to: bad)
    rig.editor.storeAndInsert(files: [bad], at: NSRange(location: 0, length: 0))
    for _ in 0..<200 where rig.problems.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(rig.problems.first == "读不出这张图片|换个文件试试")
    #expect(rig.images.isEmpty)
  }

  /// F25：走编辑器那一层的令牌往返（editorString → 编辑器 → stored(from:)）逐字一样
  @Test func editorRoundTripKeepsTheStoredForm() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    let other = try await rig.addImage(width: 100, height: 60)
    let bodies = [
      rig.token(image),
      "文字\n\(rig.token(image, width: 120))\n后面",
      "\(rig.token(other))\(rig.token(image))",
      "前面\u{FFFC}后面",
      "```\n\(rig.token(image))\n```",
      "# 标题\n\(rig.token(image, width: 400))\n> 引用",
    ]
    for body in bodies {
      rig.load(body)
      rig.layout()
      #expect(rig.stored == body, "往返逐字一样：\(body.debugDescription)")
    }
  }

  /// 复查时找到的排版死循环：图的宽取整**不许超出可用宽**——正文框的宽常是小数，往上取整多出零点几，TextKit 1
  /// 在哪一行都放不下这个附件、一行行往下找，主线程卡死、内存涨到几个 GB（随机编辑测试起始种子 3001 卡在这里）
  @Test func sizesNeverExceedAFractionalWidth() {
    let image = NoteImages.Image(id: UUID(), ext: "png", width: nil)
    let big = NoteImageSize(
      pixelWidth: 2000, pixelHeight: 1000, dpi: 72, orientation: 1,
      pointSize: CGSize(width: 2000, height: 1000))
    for available in [380.6, 380.4, 40.5, 1.7] {
      let size = NoteImageLayout.size(image: image, metrics: big, available: available)
      #expect(size.width <= available, "没记宽度：\(available) → \(size.width)")
    }
    let recorded = NoteImages.Image(id: UUID(), ext: "png", width: 3000)
    #expect(NoteImageLayout.size(image: recorded, metrics: big, available: 300.5).width <= 300.5)
    #expect(
      NoteImageLayout.size(image: image, metrics: big, available: 300.5, live: 999).width <= 300.5,
      "拖把手时同样")
    #expect(
      NoteImageLayout.size(image: image, metrics: nil, available: 150.6).width <= 150.6, "占位框同样")
  }

  /// 同一个死循环的另一条路：刚贴进代码块的图在重排之前就排版——代码块那一行的右缩进要当场从段落样式读，
  /// 不能等重排写进来（原来是 apply 写在 cell 上的一份，那一刻还是 0，算出来比排版器认的宽 8 pt）。
  /// 正文框的宽是小数、图比正文宽：排得完、放得下，没有排出一串空的行片段
  @Test func wideImagePastedIntoACodeBlockLaysOut() async throws {
    let rig = try Rig()
    let image = try await rig.addImage(width: 1600, height: 800)
    rig.window.setContentSize(NSSize(width: 417.3, height: 320))
    rig.load("```\n代码\n```")
    rig.editor.setSelectedRange(NSRange(location: 4, length: 0))
    let board = rig.pasteboardNamed("kitty-notes-code-\(UUID().uuidString)")
    board.setString(rig.token(image), forType: NoteTextView.noteTextType)
    rig.editor.pasteboard = board
    rig.step { rig.editor.paste(nil) }
    rig.layout()
    let index = try #require(rig.images.first?.index)
    let manager = try #require(rig.editor.layoutManager)
    let glyph = manager.glyphIndexForCharacter(at: index)
    let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let size = manager.attachmentSize(forGlyphAt: glyph)
    #expect(
      size.width > 100 && size.width <= fragment.width, "放得下（\(size.width) / \(fragment.width)）")
    var fragments = 0
    var next = 0
    while next < manager.numberOfGlyphs {
      var range = NSRange()
      _ = manager.lineFragmentRect(forGlyphAt: next, effectiveRange: &range)
      fragments += 1
      next = NSMaxRange(range)
    }
    #expect(fragments < 10, "没有排出一串空的行片段（\(fragments) 个）")
    board.releaseGlobally()
  }

  /// 插图 / 粘贴换字用的区间两头挪到整字的边上：不把表情（代理对）拆成两半（落单的低位代理项后面接一张要折行的图，
  /// TextKit 1 排版死循环——复查时随机编辑测试卡死在这里）
  @Test func insertionRangesSnapToWholeCharacters() throws {
    let rig = try Rig()
    rig.load("前🙂后")
    let storage = try #require(rig.editor.textStorage)
    #expect(
      rig.editor.clamped(NSRange(location: 2, length: 0), in: storage)
        == NSRange(location: 1, length: 0))
    #expect(
      rig.editor.clamped(NSRange(location: 0, length: 2), in: storage)
        == NSRange(location: 0, length: 3))
    #expect(
      rig.editor.clamped(NSRange(location: 2, length: 2), in: storage)
        == NSRange(location: 1, length: 3))
    #expect(
      rig.editor.clamped(NSRange(location: 9, length: 3), in: storage)
        == NSRange(location: 4, length: 0))
  }
}
