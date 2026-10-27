// 长图标注窗口（第 1 批）的单测：画布的坐标换算（脏区 ↔ 图里的像素）、窗口默认大小、按宽适配的缩放、
// 工具栏是长图那一套（只有识字，没有翻译 / 长截图 / 录屏 / 钉图）、按键出图。
// 很高的长图在真窗口里滚动、导出要多久、占多少内存在按需探针 AnnotateOverlayProbeTests 里量。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor
struct AnnotateOverlayTests {
  /// 长图：width × height 像素的纯色图（scale 2 时点尺寸是一半）
  private func image(width: Int, height: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  /// 脏区（点，原点左下）→ 图里的像素（原点左上）：顶上那段对着图的第 0 行，底下那段对着最后一行，
  /// 换回点坐标时要盖住原来的脏区（画出来不缺边）
  @Test func pixelRectMapsDirtyArea() {
    let size = CGSize(width: 600, height: 3000)  // 点
    let pixels = CGSize(width: 1200, height: 6000)
    let top = ScrollCanvas.pixelRect(
      of: CGRect(x: 0, y: 2900, width: 600, height: 100), in: size, pixels: pixels)
    #expect(top.minY == 0 && top.minX == 0 && top.maxX == 1200)
    #expect(top.height >= 200 && top.height <= 202)
    let bottom = ScrollCanvas.pixelRect(
      of: CGRect(x: 0, y: 0, width: 600, height: 100), in: size, pixels: pixels)
    #expect(bottom.maxY == 6000 && bottom.height >= 200)
    // 中间一段：换回点坐标盖得住原来的脏区
    let dirty = CGRect(x: 120, y: 1500, width: 200, height: 300)
    let middle = ScrollCanvas.pixelRect(of: dirty, in: size, pixels: pixels)
    #expect(middle == CGRect(x: 239, y: 2399, width: 402, height: 602))
    let back = ScrollCanvas.pointRect(of: middle, in: size, pixels: pixels)
    #expect(back.contains(dirty))
    // 整张、空画布
    #expect(
      ScrollCanvas.pixelRect(of: CGRect(origin: .zero, size: size), in: size, pixels: pixels)
        == CGRect(origin: .zero, size: pixels))
    #expect(ScrollCanvas.pixelRect(of: .zero, in: .zero, pixels: pixels) == .zero)
  }

  /// 按宽适配：宽的长图缩小，窄的不放大（最大 1:1）
  @Test func fitMagnificationNeverEnlarges() {
    #expect(AnnotateOverlay.fitMagnification(pointWidth: 1200, viewportWidth: 600) == 0.5)
    #expect(AnnotateOverlay.fitMagnification(pointWidth: 400, viewportWidth: 900) == 1)
    #expect(AnnotateOverlay.fitMagnification(pointWidth: 0, viewportWidth: 900) == 1)
    // 极宽的长图也不缩到看不见（夹在缩放下限）
    #expect(AnnotateOverlay.fitMagnification(pointWidth: 100_000, viewportWidth: 600) == 0.1)
  }

  /// 图在遮罩里占哪一块：按可见区的八成多适配、最大 1:1、居中；超小的图也有最小尺寸
  @Test func imageBoxFitsTheScreen() {
    let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let big = AnnotateOverlay.imageBox(
      pointSize: CGSize(width: 4000, height: 3000), in: visible, origin: .zero)
    #expect(big.width <= visible.width * 0.84 + 1 && big.height <= visible.height * 0.78 + 1)
    #expect(abs(big.width / big.height - 4.0 / 3.0) < 0.01)  // 比例不变
    #expect(abs(big.midX - visible.midX) <= 1)  // 横向居中
    // 小图不放大
    let small = AnnotateOverlay.imageBox(
      pointSize: CGSize(width: 300, height: 200), in: visible, origin: .zero)
    #expect(small.size == CGSize(width: 300, height: 200))
    // 很长的长图：高度按框封顶（里面滚），宽度跟着比例缩
    let long = AnnotateOverlay.imageBox(
      pointSize: CGSize(width: 600, height: 15000), in: visible, origin: .zero)
    #expect(long.height <= visible.height * 0.78 + 1 && long.width >= 240)
    // 面板盖整块屏：可见区的原点要换算进面板坐标（菜单栏那一条）
    let offset = AnnotateOverlay.imageBox(
      pointSize: CGSize(width: 300, height: 200),
      in: CGRect(x: 0, y: 0, width: 1600, height: 960), origin: CGPoint(x: 0, y: -40))
    #expect(offset.midY > 0)
  }

  /// 工具栏是长图那一套（拍板 C1）：识字留着，翻译 / 长截图 / 录屏 / 钉图不出现；标注工具和撤销重做照旧在
  @Test func toolbarKeepsOnlyRecognize() {
    func tips(_ mode: EditorToolbar.Mode) -> Set<String> {
      func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
      return Set(all(EditorToolbar(mode: mode)).compactMap { ($0 as? NSButton)?.toolTip })
    }
    let longShot = tips(.longShot)
    #expect(longShot.contains("识字并拷贝（O）"))
    #expect(longShot.isDisjoint(with: ["长截图（S，不带标注）", "录屏（R）", "钉到屏幕（T）", "翻译"]))
    #expect(longShot.contains("矩形（1）") && longShot.contains("撤销（⌘Z）"))
    #expect(longShot.contains("拷贝（↩）") && longShot.contains("取消（Esc）"))
    #expect(tips(.capture).contains("长截图（S，不带标注）"))
  }

  /// ↩ 拷贝之后窗口关掉（这次长截图到此结束）；O 识字只把文字拿走、窗口留着；Esc 什么都不出
  @Test func keysEmitAndClose() throws {
    var actions: [RegionSelector.Action] = []
    let editor = AnnotateOverlay(image: image(width: 400, height: 2400), scale: 2) {
      action, _, _, _ in actions.append(action)
    }
    let content = try #require(editor.panel.contentView as? AnnotateOverlayView)
    func press(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: UInt16(keyCode)))
      content.keyDown(with: event)
    }
    try press(kVK_ANSI_O, "o")
    #expect(actions == [.recognize])
    #expect(editor.panel.isVisible == false)  // 没 show 过：这里只看它没被关掉的副作用影响
    try press(kVK_Return, "\r")
    #expect(actions == [.recognize, .copy])
    editor.close()
  }

  /// 输入文字时的编辑键交给输入框（第三轮体检 R5）：⌘S / ⌘C 不再出图关窗，⌘Z 撤的是框里打的字、不是整条标注
  /// （之前画好的那条也还在），⌘← / ⌘⌫ 这类行编辑键交回给输入框、不吞。
  /// ⌘C 只在框里没选中字、面板也不是 key（发出去的拷贝落不到它身上）时按一下，看剪贴板没动；⌘V / ⌘X 不按
  @Test func typingKeepsEditKeysInTheField() throws {
    var actions: [RegionSelector.Action] = []
    let editor = AnnotateOverlay(image: image(width: 400, height: 600), scale: 2) {
      action, _, _, _ in actions.append(action)
    }
    defer { editor.close() }
    let content = try #require(editor.panel.contentView as? AnnotateOverlayView)
    let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
    let canvas = try #require(scroll.documentView as? ScrollCanvas)
    // 先有一条画好的，再开一个输入框打字
    canvas.annotations = [
      Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 50)))
    ]
    canvas.choose(.text)
    canvas.beginEditing(at: CGPoint(x: 40, y: 200))
    let field = try #require(canvas.subviews.compactMap { $0 as? EditorField }.first)
    #expect(editor.panel.firstResponder === field)
    field.insertText("注意", replacementRange: NSRange(location: NSNotFound, length: 0))
    RunLoop.main.run(until: .now.addingTimeInterval(0.05))  // 让撤销的分组收口
    func press(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = .command)
      throws -> Bool
    {
      try editor.panel.performKeyEquivalent(
        with: #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(keyCode))))
    }
    let pasteboard = NSPasteboard.general.changeCount
    #expect(try press(kVK_ANSI_S, "s"))
    #expect(try press(kVK_ANSI_C, "c"))
    #expect(actions.isEmpty, "打字时 ⌘S / ⌘C 出图了：\(actions)")
    #expect(NSPasteboard.general.changeCount == pasteboard)
    // ⌘← / ⌘⌫：没人在 performKeyEquivalent 里接（返回 false），AppKit 接着把它当 keyDown 交给输入框
    let left = String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)
    #expect(try !press(kVK_LeftArrow, left, [.command, .numericPad, .function]))
    #expect(try !press(kVK_Delete, "\u{7F}"))
    #expect(try press(kVK_ANSI_D, "d"))
    #expect(canvas.annotations.count == 1)  // ⌘D 也没落到画布上
    #expect(try press(kVK_ANSI_Z, "z"))
    #expect(field.string.isEmpty, "⌘Z 没撤掉框里打的字")
    #expect(editor.panel.firstResponder === field)  // 还在输入
    #expect(canvas.annotations.count == 1)  // 画好的那条还在（原来整条撤掉）
    #expect(try press(kVK_ANSI_Z, "Z", [.command, .shift]))
    #expect(field.string == "注意")
    canvas.endEditing()
    #expect(canvas.annotations.count == 2)
    // 输入框收起之后 ⌘C 照常出图
    #expect(try press(kVK_ANSI_C, "c"))
    #expect(actions == [.copy])
  }

  // MARK: 标注（第 2 批）

  /// 画布摆进一扇屏外窗口：坐标就是窗口坐标（画布当 contentView，原点一致），事件可以直接喂
  private func canvasInWindow(_ pixels: (width: Int, height: Int) = (800, 2400)) -> (
    canvas: ScrollCanvas, window: NSWindow
  ) {
    let canvas = ScrollCanvas(image: image(width: pixels.width, height: pixels.height), scale: 2)
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: canvas.bounds.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false  // 不设的话 close() 会把窗口放掉，局部变量再放一次就崩
    window.contentView = canvas
    canvas.styleDefaults = UserDefaults(suiteName: "scroll-editor-tests")!
    return (canvas, window)
  }

  private func mouse(
    _ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = [],
    clickCount: Int = 1
  ) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
  }

  /// 按下 → 拖到 → 松手（from == to 就是单击）
  private func drag(
    _ canvas: ScrollCanvas, from: CGPoint, to: CGPoint, flags: NSEvent.ModifierFlags = [],
    clickCount: Int = 1
  ) throws {
    canvas.mouseDown(
      with: try mouse(.leftMouseDown, at: from, flags: flags, clickCount: clickCount))
    if from != to { canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: to, flags: flags)) }
    canvas.mouseUp(with: try mouse(.leftMouseUp, at: to, flags: flags))
  }

  private func press(
    _ canvas: ScrollCanvas, _ keyCode: Int, _ characters: String,
    _ flags: NSEvent.ModifierFlags = []
  ) throws {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: UInt16(keyCode)))
    if flags.contains(.command) {
      _ = canvas.performKeyEquivalent(with: event)
    } else {
      canvas.keyDown(with: event)
    }
  }

  /// 选工具、拖一个矩形出来：画完自动选中、工具保持；撤销重做回得去
  @Test func drawsAndUndoes() throws {
    let (canvas, window) = canvasInWindow()
    defer { window.orderOut(nil) }
    try press(canvas, kVK_ANSI_1, "1")
    #expect(canvas.tool == .rectangle)
    try drag(canvas, from: CGPoint(x: 60, y: 900), to: CGPoint(x: 260, y: 1000))
    #expect(canvas.annotations.count == 1)
    #expect(canvas.selectedAnnotation == canvas.annotations.first?.id)
    #expect(canvas.tool == .rectangle)  // 工具保持
    #expect(canvas.canUndo && !canvas.canRedo)
    canvas.undo()
    #expect(canvas.annotations.isEmpty && canvas.canRedo)
    canvas.redo()
    #expect(canvas.annotations.count == 1)
    // 再按一次同一个数字键收起工具
    try press(canvas, kVK_ANSI_1, "1")
    #expect(canvas.tool == nil)
  }

  /// 选中之后：拖本体移动、⌥ 拖复制、⌘D 复制、方向键微调、⌫ 删除
  @Test func movesCopiesAndDeletes() throws {
    let (canvas, window) = canvasInWindow()
    defer { window.orderOut(nil) }
    try press(canvas, kVK_ANSI_1, "1")
    try drag(canvas, from: CGPoint(x: 60, y: 900), to: CGPoint(x: 260, y: 1000))
    try press(canvas, kVK_ANSI_1, "1")  // 收起工具，免得下一下又画一个
    let drawn = try #require(canvas.annotations.first)
    // 空心矩形点中间不算命中（同遮罩里的标注）：拖它的边
    let onEdge = CGPoint(x: 160, y: 900)
    try drag(canvas, from: onEdge, to: CGPoint(x: 200, y: 900))
    #expect(canvas.annotations.count == 1)
    #expect(canvas.annotations[0].bounds.minX > drawn.bounds.minX)
    // ⌥ 拖：多一份（序号类还会换号），选中的是副本
    try drag(canvas, from: CGPoint(x: 200, y: 900), to: CGPoint(x: 300, y: 900), flags: .option)
    #expect(canvas.annotations.count == 2)
    #expect(canvas.selectedAnnotation != drawn.id)
    try press(canvas, kVK_ANSI_D, "d", .command)
    #expect(canvas.annotations.count == 3)
    let before = try #require(canvas.annotations.last?.bounds.minX)
    try press(canvas, kVK_RightArrow, "\u{F703}")
    #expect(canvas.annotations.last?.bounds.minX == before + 1)
    try press(canvas, kVK_Delete, "\u{8}")
    #expect(canvas.annotations.count == 2 && canvas.selectedAnnotation == nil)
  }

  /// 文字：单击放输入框，收下时变成一条标注；空的不留下
  @Test func textBecomesAnnotation() throws {
    let (canvas, window) = canvasInWindow()
    defer { window.orderOut(nil) }
    try press(canvas, kVK_ANSI_7, "7")
    #expect(canvas.tool == .text)
    canvas.beginEditing(at: CGPoint(x: 80, y: 800))
    let field = try #require(canvas.subviews.compactMap { $0 as? EditorField }.first)
    field.string = "注意这里"
    canvas.endEditing()
    #expect(canvas.annotations.count == 1)
    if case .text(let string, _)? = canvas.annotations.first?.shape {
      #expect(string == "注意这里")
    } else {
      Issue.record("收下的不是文字标注")
    }
    canvas.beginEditing(at: CGPoint(x: 80, y: 600))
    canvas.endEditing()
    #expect(canvas.annotations.count == 1)  // 空的不留下
  }

  /// 序号：单击放一个，编号自动 +1
  @Test func countersNumberThemselves() throws {
    let (canvas, window) = canvasInWindow()
    defer { window.orderOut(nil) }
    try press(canvas, kVK_ANSI_8, "8")
    try drag(canvas, from: CGPoint(x: 100, y: 1000), to: CGPoint(x: 100, y: 1000))
    try drag(canvas, from: CGPoint(x: 200, y: 1000), to: CGPoint(x: 200, y: 1000))
    let numbers = canvas.annotations.compactMap { annotation -> Int? in
      if case .counter(let number, _) = annotation.shape { return number }
      return nil
    }
    #expect(numbers == [1, 2])
  }

  /// 出图：没画标注就是原图（很长的图不白渲一遍），画了就重渲一张
  @Test func composedRendersOnlyWithAnnotations() throws {
    let (canvas, window) = canvasInWindow()
    defer { window.orderOut(nil) }
    #expect(canvas.composed() === canvas.image)
    try press(canvas, kVK_ANSI_1, "1")
    try drag(canvas, from: CGPoint(x: 60, y: 900), to: CGPoint(x: 260, y: 1000))
    let composed = canvas.composed()
    #expect(composed !== canvas.image)
    #expect(composed.width == canvas.image.width && composed.height == canvas.image.height)
  }

  /// 缩小看长图时手柄还点得中（命中半径按缩放补偿）、选中框跟着画在标注层上
  @Test func handlesScaleWithZoom() throws {
    let (canvas, window) = canvasInWindow()
    defer { window.orderOut(nil) }
    try press(canvas, kVK_ANSI_1, "1")
    try drag(canvas, from: CGPoint(x: 60, y: 900), to: CGPoint(x: 260, y: 1000))
    let corner = CGPoint(x: 260, y: 1000)  // 画完自动选中，手柄就在四角
    canvas.zoom = 0.25
    // 离角 20 点：1:1 时够不着，缩到 0.25 时在屏幕上只有 5 点，够得着
    try drag(canvas, from: CGPoint(x: corner.x + 20, y: corner.y), to: CGPoint(x: 400, y: 1000))
    #expect(canvas.annotations.first?.bounds.maxX ?? 0 > 300)
    let chrome = try #require(
      canvas.subviews.compactMap { $0 as? AnnotationCanvas }.first?.chrome)
    #expect(chrome.selected.id == canvas.selectedAnnotation && chrome.zoom == 0.25)
  }

  /// 没选工具时样式托盘是藏着的（2026-10-26 手测：窗口左下角露出半块空胶囊）；
  /// 选了工具出来、收起工具又收回去
  @Test func styleBarOnlyShowsWithTool() throws {
    let editor = AnnotateOverlay(image: image(width: 972, height: 4800), scale: 2) {
      _, _, _, _ in
    }
    defer { editor.close() }
    let content = try #require(editor.panel.contentView)
    let styleBar = try #require(content.subviews.compactMap { $0 as? StyleBar }.first)
    #expect(styleBar.isHidden && !styleBar.isShown)
    let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
    let canvas = try #require(scroll.documentView as? ScrollCanvas)
    canvas.choose(.rectangle)
    #expect(styleBar.isShown && !styleBar.isHidden)
    canvas.choose(nil)
    #expect(!styleBar.isShown)
  }

  /// 聚光灯：压暗盖住整张长图，所以它一动整层都要重画（2026-10-26 手测「画的时候不变暗，
  /// 存出来的图却是暗的」）；遮罩那边压暗在自己的图层上，照旧只重画变了的那块
  @Test func spotlightRedrawsWholeCanvas() {
    let spotlight = Annotation(
      shape: .spotlight(CGRect(x: 10, y: 10, width: 80, height: 60)), style: Annotation.Style())
    let rectangle = Annotation(
      shape: .rectangle(CGRect(x: 10, y: 10, width: 80, height: 60)), style: Annotation.Style())
    // 加上第一个聚光灯、改它、删掉它：都要整层重来
    #expect(AnnotationCanvas.redrawsEverything(from: [], to: [spotlight], dimsItself: true))
    #expect(AnnotationCanvas.redrawsEverything(from: [spotlight], to: [], dimsItself: true))
    #expect(
      AnnotationCanvas.redrawsEverything(
        from: [spotlight], to: [spotlight, rectangle], dimsItself: true))
    // 没有聚光灯时照旧只重画变了的那块
    #expect(!AnnotationCanvas.redrawsEverything(from: [], to: [rectangle], dimsItself: true))
    // 遮罩那边压暗在自己的图层上，不走这条
    #expect(!AnnotationCanvas.redrawsEverything(from: [], to: [spotlight], dimsItself: false))
  }

  /// 画了聚光灯之后，洞外面的画面真的被压暗了（端到端：直接画一块出来比像素）
  @Test func spotlightDimsOutsideTheHole() throws {
    let (canvas, window) = canvasInWindow()
    defer { window.orderOut(nil) }
    let outside = CGRect(x: 0, y: 1100, width: 120, height: 80)
    func brightness(_ rect: CGRect) throws -> CGFloat {
      let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: rect))
      canvas.cacheDisplay(in: rect, to: bitmap)
      return try #require(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        .brightnessComponent
    }
    let before = try brightness(outside)
    try press(canvas, kVK_ANSI_0, "0")  // 聚光灯
    try drag(canvas, from: CGPoint(x: 200, y: 600), to: CGPoint(x: 320, y: 700))
    #expect(canvas.annotations.count == 1)
    let after = try brightness(outside)
    #expect(after < before - 0.05, "聚光灯外面没被压暗：\(before) → \(after)")
  }

  /// 画布的点尺寸 = 像素 / scale；长图一打开停在最上面（原点左下，顶边是最大的 y）
  @Test func canvasUsesPointSize() {
    let canvas = ScrollCanvas(image: image(width: 1200, height: 7480), scale: 2)
    #expect(canvas.bounds.size == CGSize(width: 600, height: 3740))
    #expect(canvas.isOpaque)
  }
}
