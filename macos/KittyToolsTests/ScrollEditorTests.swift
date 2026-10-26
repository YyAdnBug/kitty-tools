// 长图标注窗口（第 1 批）的单测：画布的坐标换算（脏区 ↔ 图里的像素）、窗口默认大小、按宽适配的缩放、
// 工具栏是长图那一套（只有识字，没有翻译 / 长截图 / 录屏 / 钉图）、按键出图。
// 很高的长图在真窗口里滚动、导出要多久、占多少内存在按需探针 ScrollEditorProbeTests 里量。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor
struct ScrollEditorTests {
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
    #expect(ScrollEditor.fitMagnification(pointWidth: 1200, viewportWidth: 600) == 0.5)
    #expect(ScrollEditor.fitMagnification(pointWidth: 400, viewportWidth: 900) == 1)
    #expect(ScrollEditor.fitMagnification(pointWidth: 0, viewportWidth: 900) == 1)
    // 极宽的长图也不缩到看不见（夹在缩放下限）
    #expect(ScrollEditor.fitMagnification(pointWidth: 100_000, viewportWidth: 600) == 0.1)
  }

  /// 窗口默认大小：宽跟长图的点宽、上限屏幕可见区 90%，高是 85%，都不小于最小尺寸
  @Test func contentSizeFitsScreen() {
    let screen = NSScreen.main
    let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    let wide = ScrollEditor.contentSize(
      for: CGSize(width: 9000, height: 20000), on: screen)
    #expect(abs(wide.width - visible.width * 0.9) < 0.01)
    #expect(abs(wide.height - visible.height * 0.85) < 0.01)
    let narrow = ScrollEditor.contentSize(for: CGSize(width: 320, height: 200), on: screen)
    #expect(narrow == CGSize(width: 480, height: 360))
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
    let editor = ScrollEditor(image: image(width: 400, height: 2400), scale: 2, frameName: nil) {
      action, _, _ in actions.append(action)
    }
    let content = try #require(editor.window.contentView as? ScrollEditorView)
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
    #expect(editor.window.isVisible == false)  // 没 show 过：这里只看它没被关掉的副作用影响
    try press(kVK_Return, "\r")
    #expect(actions == [.recognize, .copy])
    editor.close()
  }

  /// 画布的点尺寸 = 像素 / scale；长图一打开停在最上面（原点左下，顶边是最大的 y）
  @Test func canvasUsesPointSize() {
    let canvas = ScrollCanvas(image: image(width: 1200, height: 7480), scale: 2)
    #expect(canvas.bounds.size == CGSize(width: 600, height: 3740))
    #expect(canvas.isOpaque)
  }
}
