// 便签图片的裁切（Notes/NoteImageCrop.swift、NoteImageStore.crop、NoteImages.croppedWidth；便签未来计划 D1 / D2）：
// 几何是纯函数（选比例、拖把手到最小边、交出去的像素框取整和翻成左上角原点）；存新图在临时目录里真裁一张
// （转正之后的坐标、方向写 1、DPI 照原图、格式照原图 / GIF 存 PNG、原文件不动）；裁切层的按键和鼠标在屏外窗口里调。
// 编辑器那一半（菜单、换图一步撤销、回来时认目标、收起）在 NoteTextViewImageTests。

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

struct NoteImageCropTests {
  private let directory = FileManager.default.temporaryDirectory.appending(
    path: "kitty-notes-crop-tests-\(UUID().uuidString)")

  private func write(_ data: Data, ext: String) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "\(UUID().uuidString).\(ext)")
    try data.write(to: url)
    return url
  }

  /// 一张图（转正之后）左上角原点的 (x, y) 那个像素是不是白的（夹具的白块；别处是青色）
  private func isWhite(_ url: URL, x: Int, y: Int) throws -> Bool {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 100_000,
    ]
    let image = try #require(
      CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(
      CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // 把要的那个像素挪到 1×1 的画布上（CG 的原点在左下）
    context.draw(
      image,
      in: CGRect(
        x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width),
        height: CGFloat(image.height)))
    return pixel[0] > 230 && pixel[1] > 230 && pixel[2] > 230
  }

  // MARK: 几何

  @Test func ratiosListAndOriginal() {
    let ratios = NoteImageCrop.ratios(for: CGSize(width: 300, height: 200))
    #expect(ratios.map(\.title) == ["自由", "原比例", "1:1", "4:3", "3:4", "16:9", "9:16"])
    #expect(ratios[0].value == nil && ratios[1].value == 1.5)
  }

  /// 选比例：整张图里放得下的最大的框，中心对着现在的框、夹进图；反复换不会越换越小
  @Test func fittedIsTheLargestAroundTheCurrentCenter() {
    let whole = CGRect(x: 0, y: 0, width: 400, height: 200)
    #expect(
      NoteImageCrop.fitted(1, around: whole, in: whole)
        == CGRect(x: 100, y: 0, width: 200, height: 200))
    let right = CGRect(x: 350, y: 50, width: 40, height: 40)
    #expect(NoteImageCrop.fitted(1, around: right, in: whole).minX == 200, "夹进图里")
    let wide = NoteImageCrop.fitted(16.0 / 9, around: whole, in: whole)
    #expect(abs(wide.width - 355.56) < 0.01 && wide.height == 200)
    let back = NoteImageCrop.fitted(
      1, around: NoteImageCrop.fitted(4.0 / 3, around: whole, in: whole), in: whole)
    #expect(back.size == CGSize(width: 200, height: 200))
  }

  /// 拖把手：自由时拖到哪是哪；锁比例时按比例；小过 16 像素停在上一个；越过对边翻过去
  @Test func resizedKeepsRatioAndMinimum() {
    let whole = CGRect(x: 0, y: 0, width: 400, height: 300)
    let start = CGRect(x: 100, y: 100, width: 200, height: 100)
    let free = NoteImageCrop.resized(
      start, current: start, handle: .topRight, to: CGPoint(x: 350, y: 250), in: whole, ratio: nil)
    #expect(free == CGRect(x: 100, y: 100, width: 250, height: 150))
    let square = NoteImageCrop.resized(
      start, current: start, handle: .topRight, to: CGPoint(x: 350, y: 220), in: whole, ratio: 1)
    #expect(square.width == square.height && square.minX == 100 && square.minY == 100)
    let tiny = NoteImageCrop.resized(
      start, current: free, handle: .right, to: CGPoint(x: 110, y: 150), in: whole, ratio: nil)
    #expect(tiny == free, "10 像素宽：停在上一个")
    let flipped = NoteImageCrop.resized(
      start, current: start, handle: .right, to: CGPoint(x: 40, y: 150), in: whole, ratio: nil)
    #expect(flipped == CGRect(x: 40, y: 100, width: 60, height: 100), "越过左边翻过去")
    // 图本身只有 10 像素高：最小边按图
    let short = CGRect(x: 0, y: 0, width: 100, height: 10)
    let thin = NoteImageCrop.resized(
      short, current: short, handle: .left, to: CGPoint(x: 50, y: 5), in: short, ratio: nil)
    #expect(thin == CGRect(x: 50, y: 0, width: 50, height: 10))
  }

  /// 交出去的像素框：四条边各自取整、夹进图、原点翻到左上角；整张图 = 没裁 = nil
  @Test func pixelRectRoundsAndFlips() {
    let size = CGSize(width: 400, height: 300)
    #expect(NoteImageCrop.pixelRect(CGRect(origin: .zero, size: size), imageSize: size) == nil)
    #expect(
      NoteImageCrop.pixelRect(CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50), imageSize: size)
        == CGRect(x: 10, y: 229, width: 101, height: 50))
    #expect(
      NoteImageCrop.pixelRect(CGRect(x: -5, y: 250, width: 100, height: 100), imageSize: size)
        == CGRect(x: 0, y: 0, width: 95, height: 50))
    #expect(
      NoteImageCrop.pixelRect(CGRect(x: 10.2, y: 10, width: 0.2, height: 5), imageSize: size) == nil
    )
  }

  @Test func croppedWidthScalesTheStoredWidth() {
    #expect(NoteImages.croppedWidth(240, from: 400, to: 100) == 60)
    #expect(NoteImages.croppedWidth(nil, from: 400, to: 100) == nil, "没记宽度的照旧不记")
    #expect(
      NoteImages.croppedWidth(NoteImages.maxWidth, from: 400, to: 100) == NoteImages.maxWidth,
      "铺满照旧铺满")
    #expect(NoteImages.croppedWidth(100, from: 1000, to: 100) == NoteImages.minWidth, "夹到 40")
    #expect(NoteImages.croppedWidth(240, from: 0, to: 100) == nil)
  }

  // MARK: 存新图

  /// PNG：格式和 DPI 照原图，裁的是转正之后左上角原点的那一块；新编号，原文件不动
  @Test func cropKeepsFormatAndDPI() async throws {
    let original = try write(
      NoteImageFixture.data(type: .png, width: 400, height: 200, dpi: 144), ext: "png")
    // 夹具的白块在左下角 100 × 50：左上角原点是 (0, 150)
    let stored = try await NoteImageStore.crop(
      fileAt: original, to: CGRect(x: 0, y: 150, width: 100, height: 50), in: directory
    ).get()
    #expect(stored.image.ext == "png" && stored.image.width == nil)
    #expect(stored.size.pixelWidth == 100 && stored.size.pixelHeight == 50)
    #expect(stored.size.dpi == 144 && stored.size.pointSize == CGSize(width: 50, height: 25))
    let url = directory.appending(path: "\(stored.image.id.uuidString).png")
    #expect(try isWhite(url, x: 50, y: 25))
    #expect(FileManager.default.fileExists(atPath: original.path), "原文件不动")
    #expect(original.lastPathComponent != url.lastPathComponent)
  }

  /// EXIF 方向 6（转 90°）的 JPEG：按转正之后的坐标裁，新文件方向写 1、还是 JPEG
  @Test func cropUsesUprightCoordinates() async throws {
    let original = try write(
      NoteImageFixture.data(type: .jpeg, width: 200, height: 100, orientation: 6), ext: "jpg")
    // 原图左下角的白块（50 × 25）转正后在左上角，25 宽 50 高
    let stored = try await NoteImageStore.crop(
      fileAt: original, to: CGRect(x: 0, y: 0, width: 25, height: 50), in: directory
    ).get()
    #expect(stored.image.ext == "jpg")
    #expect(stored.size.orientation == 1)
    #expect(stored.size.pixelWidth == 25 && stored.size.pixelHeight == 50)
    let url = directory.appending(path: "\(stored.image.id.uuidString).jpg")
    #expect(try isWhite(url, x: 12, y: 25))
    // 另一角是青色
    let other = try await NoteImageStore.crop(
      fileAt: original, to: CGRect(x: 50, y: 150, width: 50, height: 50), in: directory
    ).get()
    #expect(
      try !isWhite(directory.appending(path: "\(other.image.id.uuidString).jpg"), x: 25, y: 25))
  }

  /// GIF 存 PNG；框伸到图外的夹进图里；整个在图外的读不出来；文件不在的读不出来
  @Test func cropGIFAndOutOfBounds() async throws {
    let gif = try write(NoteImageFixture.data(type: .gif, width: 80, height: 60), ext: "gif")
    let stored = try await NoteImageStore.crop(
      fileAt: gif, to: CGRect(x: 40, y: 30, width: 100, height: 100), in: directory
    ).get()
    #expect(stored.image.ext == "png")
    #expect(stored.size.pixelWidth == 40 && stored.size.pixelHeight == 30)
    let outside = await NoteImageStore.crop(
      fileAt: gif, to: CGRect(x: 200, y: 200, width: 10, height: 10), in: directory)
    #expect(throws: NoteImageStore.Rejection.unreadable) { try outside.get() }
    let missing = await NoteImageStore.crop(
      fileAt: directory.appending(path: "nope.png"), to: CGRect(x: 0, y: 0, width: 5, height: 5),
      in: directory)
    #expect(throws: NoteImageStore.Rejection.unreadable) { try missing.get() }
  }

  // MARK: 裁切层

  private func overlay(_ size: CGSize = CGSize(width: 400, height: 200)) throws -> (
    NoteImageCropView, NSWindow
  ) {
    let frame = CGRect(x: -30000, y: -30000, width: 440, height: 300)
    try #require(
      !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = NoteImageCropView(
      picture: NoteImages.Image(id: UUID(), ext: "png", width: nil), index: 0, pixelSize: size,
      url: nil)
    view.frame = CGRect(origin: .zero, size: frame.size)
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
  }

  private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [])
    throws -> NSEvent
  {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code))
  }

  /// ↩ 交出像素框（没裁 = nil），Esc / cancelOperation 取消，方向键按点挪、⇧ 一次 10 点
  @Test func keysFinishCancelAndNudge() throws {
    let (view, window) = try overlay()
    defer { window.close() }
    var done: [CGRect?] = []
    var cancelled = 0
    view.onDone = { done.append($0) }
    view.onCancel = { cancelled += 1 }
    #expect(window.firstResponder === view)
    view.keyDown(with: try key(36, "\r"))
    #expect(done.count == 1 && done[0] == nil, "整张图：没裁")
    view.choose(ratioAt: 2)
    #expect(view.crop == CGRect(x: 100, y: 0, width: 200, height: 200))
    let scale = view.imageRect.width / 400
    view.keyDown(with: try key(123, "\u{F702}", flags: .shift))
    #expect(abs(view.crop.minX - (100 - 10 / scale)) < 0.01)
    view.keyDown(with: try key(36, "\r"))
    let rect = try #require(done.last ?? nil)
    #expect(rect.size == CGSize(width: 200, height: 200) && rect.minY == 0)
    view.keyDown(with: try key(53, "\u{1B}"))
    view.cancelOperation(nil)
    #expect(cancelled == 2)
    #expect(view.accessibilityValue() as? String == "200 × 200 像素")
  }

  /// 鼠标：按在右上角把手上往里拖 = 缩框（边跟着鼠标走同样多，不往鼠标底下跳）；框里按住拖 = 挪；框外按下不动
  @Test func mouseDragsHandlesAndMoves() throws {
    let (view, window) = try overlay()
    defer { window.close() }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }
    let scale = view.imageRect.width / 400
    let corner = CGPoint(x: view.cropRect.maxX - 2, y: view.cropRect.maxY - 2)
    view.mouseDown(with: try event(.leftMouseDown, corner))
    view.mouseDragged(
      with: try event(
        .leftMouseDragged, CGPoint(x: corner.x - 100 * scale, y: corner.y - 50 * scale)))
    view.mouseUp(with: try event(.leftMouseUp, .zero))
    #expect(abs(view.crop.width - 300) < 0.5 && abs(view.crop.height - 150) < 0.5)
    #expect(view.crop.origin == .zero)
    let inside = CGPoint(x: view.cropRect.midX, y: view.cropRect.midY)
    view.mouseDown(with: try event(.leftMouseDown, inside))
    view.mouseDragged(
      with: try event(.leftMouseDragged, CGPoint(x: inside.x + 500, y: inside.y + 500)))
    view.mouseUp(with: try event(.leftMouseUp, .zero))
    #expect(abs(view.crop.minX - 100) < 0.5 && abs(view.crop.minY - 50) < 0.5, "挪到右上角为止")
    let before = view.crop
    let outside = CGPoint(x: view.imageRect.minX + 4, y: view.imageRect.minY + 4)
    view.mouseDown(with: try event(.leftMouseDown, outside))
    view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: outside.x + 40, y: outside.y)))
    #expect(view.crop == before)
  }
}
