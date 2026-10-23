// 程序坞预览的缩略图（第九族，2026-10-22；拍板 C2：停上去当场截、不做实时画面）。
// 一律用 WindowServer.capture 按编号截整扇窗口（1x）再缩到缩略图大小，别的桌面上的、被挡住的也截得到；在主线程外做
// （@concurrent 第 1 类：缩略图；耗时在 PLAN §10「程序坞预览」）。截不到（接口不在、截出来全透明——最小化的会不会这样
// 还没在真机上看过，HANDTEST「程序坞预览手测」2）就用上次截的，再没有
// 界面画 App 图标。私有接口不在时，当前桌面上的退回 ScreenCaptureKit（屏幕上的窗口才截得到；接口在、只是这一扇没截到时
// 不退：最小化的窗口截出来是空的，ScreenCaptureKit 也截不到）。调用方一扇扇按顺序截，不一下并发几十个（一扇是一次同步的
// 进程间调用，并发多了占满协作线程池）。
// 上次截的只存在内存里：最多 20 张（缩略图最大 520 × 280 像素，最坏约 11 MB），App 退出就丢；空闲回收、关掉功能时清掉（clear）。
// ponytail: 满了丢最早放进来的，不是最久没用的：一次预览最多截十几张，够用；常有几十扇窗口来回看时再换成按用过的先后。
// 要「屏幕录制」授权，没有就不截（界面只列标题，拍板 A2）。

import AppKit
import ScreenCaptureKit

@MainActor final class WindowShots {
  private var cache: [CGWindowID: CGImage] = [:]
  /// 放进缓存的先后，满了先丢最早的
  private var order: [CGWindowID] = []
  static let capacity = 20

  /// 上次截的（没有就 nil）
  func cached(_ id: CGWindowID) -> CGImage? { cache[id] }

  /// 截一扇，缩到 maxPixels 以内；截到的放进缓存。截不到返回 nil（调用方用 cached 或图标）
  func shoot(_ window: DockWindow, maxPixels: CGSize) async -> CGImage? {
    guard Permissions.isScreenRecordingAllowed else { return nil }
    WindowServer.prepare()  // 第一次取符号要在主线程，别落到下面的截图线程上
    var image = await Self.capture(window.id, maxPixels: maxPixels)
    if image == nil, window.state == .shown, !WindowServer.canCapture {
      image = await Self.captureWithScreenCaptureKit(window.id, maxPixels: maxPixels)
    }
    if let image { remember(image, for: window.id) }
    return image
  }

  func clear() {
    cache = [:]
    order = []
  }

  /// 放进缓存（满了丢最早放进来的）
  func remember(_ image: CGImage, for id: CGWindowID) {
    if cache.updateValue(image, forKey: id) == nil { order.append(id) }
    while order.count > Self.capacity { cache[order.removeFirst()] = nil }
  }

  // MARK: 截

  @concurrent private static func capture(_ id: CGWindowID, maxPixels: CGSize) async -> CGImage? {
    guard let full = WindowServer.capture(id), !isBlank(full) else { return nil }
    return scaled(full, toFit: maxPixels)
  }

  private static func captureWithScreenCaptureKit(_ id: CGWindowID, maxPixels: CGSize) async
    -> CGImage?
  {
    guard
      let content = try? await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true),
      let window = content.windows.first(where: { $0.windowID == id })
    else { return nil }
    let size = fitted(
      CGSize(width: window.frame.width * 2, height: window.frame.height * 2), in: maxPixels)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    return try? await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window),
      configuration: configuration)
  }

  // MARK: 纯函数

  /// 按比例缩进 box（不放大），至少 1 像素。纯函数，配单测
  nonisolated static func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0 else { return .zero }
    let scale = min(box.width / size.width, box.height / size.height, 1)
    return CGSize(
      width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded())
    )
  }

  /// 缩到 box 以内（已经够小就原样返回）。画进 8 位 BGRA：原图是 RGB（不是扩展范围的）就沿用它的颜色空间，
  /// 别的（灰度、扩展范围、没有颜色空间）换成 sRGB——8 位预乘的位图只认 RGB，给灰度的颜色空间会建不出来
  nonisolated static func scaled(_ image: CGImage, toFit box: CGSize) -> CGImage? {
    let size = fitted(CGSize(width: image.width, height: image.height), in: box)
    guard Int(size.width) < image.width || Int(size.height) < image.height else { return image }
    let space =
      image.colorSpace.flatMap { $0.model == .rgb && !CGColorSpaceUsesExtendedRange($0) ? $0 : nil }
      ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(origin: .zero, size: size))
    return context.makeImage()
  }

  /// 全透明（截到的是空壳：最小化、刚关上的窗口会这样）。缩成 8 × 8 看 alpha，纯函数
  nonisolated static func isBlank(_ image: CGImage) -> Bool {
    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return true }
    return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 }
  }
}
