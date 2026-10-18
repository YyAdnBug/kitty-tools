// 便签任务的圆角方框（Notes/NoteTaskBox.swift，2026-10-18）：几何（边长、圆角、描边、像素对齐、在那一格里居中、对着
// 中线）、颜色（8 张纸 × 浅深：记号对底 ≥ 3:1、描边对纸 ≥ 3:1）、编辑器里（五种状态一样宽、方框落在点方框的命中区里、
// 画出来的是方框不是字形、代码块里不画）、墙卡片（换成布局管理器之后量出来的高和原来 draw(with:) 的口径一样）。
// 窗口摆在离所有屏幕很远的地方、不当 key；不发合成事件。增强对比度那一档读的是系统开关，这里只验平时的。

import AppKit
import Testing

@testable import KittyTools

struct NoteTaskBoxTests {
  @Test func geometry() {
    for size in [13, 15, 17, 20] as [CGFloat] {
      let capHeight = NSFont.systemFont(ofSize: size).capHeight
      let box = NoteTaskBox.geometry(
        size: size, advance: (10.3, 15.5), baseline: 20.25, capHeight: capHeight, scale: 2)
      let label = "\(size)"
      #expect(box.rect.width == box.rect.height, "\(label)")
      #expect(abs(box.rect.width - size * NoteTaskBox.sideRatio) <= 0.25, "\(label)")
      #expect(abs(box.stroke - max(size / NoteTaskBox.strokeDivisor, 1)) <= 0.25, "\(label)")
      #expect(abs(box.corner - box.rect.width * NoteTaskBox.cornerRatio) < 0.001, "\(label)")
      #expect(abs(box.mark - box.stroke * NoteTaskBox.markRatio) < 0.001, "\(label)")
      // 外沿、描边都落在整像素上（2x）
      for value in [box.rect.minX, box.rect.minY, box.rect.width, box.stroke] {
        #expect((value * 2).rounded() == value * 2, "\(label) \(value)")
      }
      // 横向在那一格里居中，竖向对着基线上方 capHeight / 2（取整最多差半个像素）
      #expect(abs(box.rect.midX - (10.3 + 15.5 / 2)) <= 0.25, "\(label)")
      #expect(abs(box.rect.midY - (20.25 - capHeight / 2)) <= 0.25, "\(label)")
    }
    // 1x 屏：整点，描边至少 1
    let box = NoteTaskBox.geometry(
      size: 15, advance: (0.4, 14.1), baseline: 18.3, capHeight: 10.6, scale: 1)
    #expect(box.rect.minX == box.rect.minX.rounded() && box.rect.minY == box.rect.minY.rounded())
    #expect(box.rect.width == 13 && box.stroke == 1)
  }

  /// 方框对着 capHeight / 2：量过和汉字字形的竖直中点差不多（20 pt 时差 0.33，别的字号不到 0.1）
  @Test func capHeightCenterIsNearTheHanCenter() {
    for size in [13, 15, 17, 20] as [CGFloat] {
      let font = NSFont.systemFont(ofSize: size)
      let han = CTFontCreateForString(font, "中" as CFString, CFRange(location: 0, length: 1))
      var units = Array("中".utf16)
      var glyph = CGGlyph(0)
      _ = CTFontGetGlyphsForCharacters(han, &units, &glyph, 1)
      var rect = CGRect.zero
      _ = CTFontGetBoundingRectsForGlyphs(han, .horizontal, &glyph, &rect, 1)
      #expect(abs(rect.midY - font.capHeight / 2) < 0.4, "\(size)：\(rect.midY)")
    }
  }

  @Test func colorsReadOnEveryPaper() {
    /// 动态色在这个外观下取到的：(0xRRGGBB, 不透明度的百分数)
    func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> (hex: Int, alpha: Int) {
      var result = (hex: -1, alpha: -1)
      NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        result = (
          channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8
            | channel(rgb.blueComponent), Int((rgb.alphaComponent * 100).rounded())
        )
      }
      return result
    }
    /// ink 以 opacity 叠在 paper 上
    func mix(_ ink: Int, _ paper: Int, _ opacity: Double) -> Int {
      [16, 8, 0].reduce(0) { hex, shift in
        let value =
          Double(ink >> shift & 0xFF) * opacity + Double(paper >> shift & 0xFF) * (1 - opacity)
        return hex | Int(value.rounded()) << shift
      }
    }
    var lowest = Double.infinity
    for paper in NotePaper.all {
      for (appearance, tone, red) in [
        (NSAppearance.Name.aqua, paper.light, NoteColor.red.light),
        (.darkAqua, paper.dark, NoteColor.red.dark),
      ] {
        let label = "\(paper.name) \(appearance.rawValue)"
        // 完成：色条色的底，对勾对底 ≥ 3:1
        #expect(resolved(paper.taskDoneColor, appearance) == (tone.strip, 100), "\(label)")
        let done = resolved(paper.taskDoneMarkColor, appearance)
        #expect(done.alpha == 100 && NoteTaskBox.contrast(done.hex, tone.strip) >= 3, "\(label) 对勾")
        // 紧急：红底，感叹号对底 ≥ 3:1
        let urgent = resolved(paper.taskUrgentMarkColor, appearance)
        #expect(NoteTaskBox.contrast(urgent.hex, red) >= 3, "\(label) 感叹号")
        // 待办 / 进行中：墨的 72%，叠在纸上对纸 ≥ 3:1（非文字图形的门槛）
        #expect(resolved(paper.taskStrokeColor, appearance) == (tone.ink, 72), "\(label)")
        let stroke = NoteTaskBox.contrast(mix(tone.ink, tone.paper, 0.72), tone.paper)
        #expect(stroke >= 3, "\(label) 描边 \(stroke)")
        lowest = min(
          lowest, NoteTaskBox.contrast(done.hex, tone.strip), NoteTaskBox.contrast(urgent.hex, red))
      }
    }
    #expect(lowest >= 3.8, "记号最低 \(lowest)")
    // 两者取高：浅色柠檬的色条上用墨、红底上用白
    #expect(NoteTaskBox.mark(on: 0xE0AD08, ink: 0x3A3008) == 0x3A3008)
    #expect(NoteTaskBox.mark(on: 0xA11A14, ink: 0x3A3008) == 0xFFFFFF)
    #expect(abs(NoteTaskBox.contrast(0xFFFFFF, 0x000000) - 21) < 0.01)
  }

  @Test func editorDrawsBoxesInPlaceOfTheGlyphs() throws {
    let frame = CGRect(x: -30000, y: -30000, width: 420, height: 320)
    try #require(
      !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    let scroll = NSScrollView(frame: CGRect(origin: .zero, size: frame.size))
    let editor = NoteTextView.make()
    editor.frame = CGRect(origin: .zero, size: frame.size)
    editor.textContainerInset = NSSize(width: 9, height: 6)
    scroll.documentView = editor
    window.contentView = scroll
    editor.setPaper(NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard)
    // 每行 4 个字（方框、空格、字、换行）；代码块里的方框从 24 开始
    let body = "☐ 字\n◧ 字\n▣ 字\n☑ 字\n☒ 字\n```\n☐ 代码\n```"
    editor.setText(body)
    let manager = try #require(editor.layoutManager as? NoteLayoutManager)
    let container = try #require(editor.textContainer)
    manager.ensureLayout(for: container)
    let storage = try #require(editor.textStorage)
    let origin = editor.textContainerOrigin

    var boxes: [NoteTaskBox.Geometry] = []
    var xs: [CGFloat] = []
    for line in 0..<5 {
      let start = line * 4
      #expect(
        storage.attribute(NoteStyles.taskBoxKey, at: start, effectiveRange: nil) as? Int == line)
      let glyph = manager.glyphIndexForCharacter(at: start)
      let box = try #require(
        manager.taskBox(atGlyph: glyph, in: container, origin: origin, scale: 2))
      boxes.append(box)
      // 方框后面那个字的 x（五种状态一样：换状态后面的字不挪）
      let after = manager.glyphIndexForCharacter(at: start + 2)
      xs.append(
        manager.lineFragmentRect(forGlyphAt: after, effectiveRange: nil).minX
          + manager.location(forGlyphAt: after).x)
      // 画出来的方框整个落在点方框的命中区里
      for point in [
        NSPoint(x: box.rect.midX, y: box.rect.midY),
        NSPoint(x: box.rect.minX + 0.5, y: box.rect.minY + 0.5),
        NSPoint(x: box.rect.maxX - 0.5, y: box.rect.maxY - 0.5),
      ] {
        #expect(editor.box(at: point) == start, "第 \(line) 行 \(point)")
      }
    }
    #expect(xs.max()! - xs.min()! < 0.01, "后面的字 \(xs)")
    #expect(Set(boxes.map(\.rect.width)).count == 1)
    // 代码块里的方框只是字
    #expect(storage.attribute(NoteStyles.taskBoxKey, at: 24, effectiveRange: nil) == nil)

    // 画一张位图：待办中间是空的、边上有描边；完成是色条色的底（原来的 ☑ 是墨色的细框）；紧急是红底
    let rep = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
    editor.cacheDisplay(in: editor.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / editor.bounds.width
    func color(_ box: NoteTaskBox.Geometry, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
      rep.colorAt(
        x: Int((box.rect.minX + box.rect.width * x) * scale),
        y: Int((box.rect.minY + box.rect.height * y) * scale))?.usingColorSpace(.sRGB)
    }
    func near(_ color: NSColor?, _ hex: Int) -> Bool {
      guard let color, color.alphaComponent > 0.95 else { return false }
      let parts = [color.redComponent, color.greenComponent, color.blueComponent]
      return zip(parts, [16, 8, 0]).allSatisfy { value, shift in
        abs(value * 255 - CGFloat(hex >> shift & 0xFF)) < 12
      }
    }
    #expect((color(boxes[0], 0.5, 0.5)?.alphaComponent ?? 1) < 0.05, "待办中间")
    #expect((color(boxes[0], 0.5, 0.02)?.alphaComponent ?? 0) > 0.3, "待办的描边")
    #expect(near(color(boxes[3], 0.25, 0.25), NotePaper.all[0].light.strip), "完成的底")
    #expect(near(color(boxes[2], 0.2, 0.2), NoteColor.red.light), "紧急的底")
    // 进行中：左半边实、右半边空
    #expect((color(boxes[1], 0.3, 0.5)?.alphaComponent ?? 0) > 0.5, "进行中左半")
    #expect((color(boxes[1], 0.7, 0.5)?.alphaComponent ?? 1) < 0.05, "进行中右半")
  }

  /// 墙卡片的正文换成布局管理器排（方框才画得成圆角方框）：量出来的高和原来 NSAttributedString 的口径一样，
  /// 卡片的高不变
  @Test func wallCardHeightIsUnchanged() {
    let bodies = [
      "",
      "一行字",
      "☐ 周报\n☑ 报销单\n▣ 紧急的事\n◧ 做着的\n☒ 不做了\n下午三点和设计过一遍首页的改动。",
      "# 标题\n**粗体** 和 *斜体*、`代码`\n> 引用的一行\n- 列表\n```\nlet x = 1\n```\n之后",
      String(repeating: "很长很长的一段字，要折好几行，看高度是不是一样。", count: 12),
      "☐ 一个很长很长的任务，长到一行放不下要折到第二行，看方框和后面的字是不是还对得齐",
    ]
    for body in bodies {
      let note = Note(
        id: "n", title: "", body: body, createdAt: .distantPast, modifiedAt: .distantPast)
      let card = NoteWallCard.make(for: note, title: note.displayTitle, markdown: true)
      let drawn =
        card.body.length == 0
        ? 0
        : ceil(
          card.body.boundingRect(
            with: NSSize(width: NoteWall.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
          ).height)
      #expect(card.bodyHeight == drawn, "\(body.prefix(12))")
    }
  }
}
