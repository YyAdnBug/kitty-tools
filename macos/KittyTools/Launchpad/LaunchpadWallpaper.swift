// 启动台的背景（2026-10-18 真机反馈「样式和 macOS 15 差很多」）：照 macOS 15，是那块屏的**桌面壁纸**模糊之后的样子，
// 颜色保留得很足，界面上再轻轻压暗一层。这里只读壁纸文件（`NSWorkspace.desktopImageURL`），不截屏、不要权限；
// 在后台按屏幕的 1/4 分辨率读图、按「填满」裁到屏幕比例、高斯模糊（反正是糊的，存一张小图就够，约 1.5 MB）。
// 动态壁纸（.heic 多张）取第一张；视频 / 航拍这类拿不到图的返回 nil，面板退回系统毛玻璃。
// 按（文件、修改时间、尺寸）缓存一份，换了壁纸下次打开重做。

import AppKit
import CoreImage

@MainActor
final class LaunchpadWallpaper {
  struct Key: Equatable, Sendable {
    let url: URL
    let modified: Date?
    let width: Int
    let height: Int
  }

  private var cached: (key: Key, image: CGImage)?
  private var loading: Key?

  /// 这块屏现在的壁纸（模糊好的）：缓存里有就直接给；没有就去后台做，做好了调 `ready`（主线程），这次先返回 nil
  func image(for screen: NSScreen, ready: @escaping (CGImage) -> Void) -> CGImage? {
    guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    let scale = screen.backingScaleFactor
    let key = Key(
      url: url, modified: modified, width: max(Int(screen.frame.width * scale / 4), 1),
      height: max(Int(screen.frame.height * scale / 4), 1))
    if let cached, cached.key == key { return cached.image }
    guard loading != key else { return nil }
    loading = key
    Task { [weak self] in
      let image = await Self.blurred(url: url, width: key.width, height: key.height)
      guard let self else { return }
      if self.loading == key { self.loading = nil }
      guard let image else { return }
      self.cached = (key, image)
      ready(image)
    }
    return nil
  }

  @concurrent
  nonisolated private static func blurred(url: URL, width: Int, height: Int) async -> CGImage? {
    guard let source = load(url: url, maxPixel: max(width, height) * 2) else { return nil }
    return render(source: source, width: width, height: height)
  }

  /// 读壁纸文件（缩着读，不解整张大图）
  nonisolated static func load(url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// 按「填满」裁到 width × height、高斯模糊（纯函数，任何线程都能调；单测喂造的图）
  nonisolated static func render(source: CGImage, width: Int, height: Int) -> CGImage? {
    let target = CGSize(width: max(width, 1), height: max(height, 1))
    let scale = max(
      target.width / CGFloat(max(source.width, 1)), target.height / CGFloat(max(source.height, 1)))
    let scaled = CIImage(cgImage: source).transformed(
      by: CGAffineTransform(scaleX: scale, y: scale))
    let extent = scaled.extent
    let origin = CGPoint(x: extent.midX - target.width / 2, y: extent.midY - target.height / 2)
    let frame = CGRect(origin: .zero, size: target)
    let cropped = scaled.cropped(to: CGRect(origin: origin, size: target))
      .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    // 半径按图的大小走：1/4 分辨率下约 25 px，相当于全尺寸上 100 px 那么糊
    let sigma = Double(max(target.width, target.height)) / 30
    let blurred = cropped.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: frame)
    return CIContext().createCGImage(blurred, from: frame)
  }
}
