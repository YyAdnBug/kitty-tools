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
      editor.onImageProblem = { [unowned self] in problems.append($0) }
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
    #expect(rig.editor.selectedRange() == NSRange(location: 4, length: 0), "光标在图那一行的末尾（图后面）")
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
    #expect(rig.stored == "文字\n\(rig.token(one))\n\(rig.token(two))")
    #expect(rig.images.count == 2)
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
    // 还要算上插图时前面加的那个换行
    rig.editor.maxBytes = NoteImages.token(image).utf8.count + "正文".utf8.count + 1
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

  @Test func linkPasteOverAnImageRestsylesTheLine() async throws {
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
    // 选中的那张图被包成链接：这一行不再是图片行（段落样式和 imageLineKey 都要收回去）
    #expect(rig.images.isEmpty)
    #expect(
      rig.editor.textStorage?.attribute(NoteStyles.imageLineKey, at: index, effectiveRange: nil)
        == nil)
    let line = rig.stored.split(separator: "\n").last.map(String.init) ?? ""
    #expect(line.hasPrefix("["))
    board.releaseGlobally()
  }

  // MARK: 读屏

  @Test func accessibilityValueSaysImage() async throws {
    let rig = try Rig()
    let image = try await rig.addImage()
    rig.load("前面\(rig.token(image))后面")
    let value = try #require(spoken(rig.editor))
    #expect(value == "前面图片后面")
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
}
