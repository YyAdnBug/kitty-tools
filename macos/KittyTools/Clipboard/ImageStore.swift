// 剪贴板图片的磁盘存储：<数据目录>/images/<id>.png。解码、转 PNG、哈希、写盘都在 @concurrent 里做，不卡主线程。

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ImageStore: Sendable {
  /// 超过这个像素数的图片不记录（约 8K×5K；再大单张 PNG 编码的内存峰值太高）
  static let maxPixels = 40_000_000

  let directory: URL

  func url(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).png") }

  /// 把剪贴板里的 PNG / TIFF 数据存成 PNG。尺寸只读元数据判断，超限或解码失败返回 nil。
  /// ponytail: 按 PNG 字节去重，同一张图换了编码（TIFF 截图 vs 网页 PNG）会记成两条
  @concurrent func save(_ data: Data, isPNG: Bool, id: UUID) async -> ClipItem.ImageInfo? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width * height <= Self.maxPixels
    else { return nil }
    let png: Data
    if isPNG {
      png = data
    } else {
      let output = NSMutableData()
      guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let destination = CGImageDestinationCreateWithData(
          output, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      png = output as Data
    }
    do {
      try png.write(to: url(for: id), options: .atomic)
    } catch {
      return nil
    }
    let sha256 = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    return ClipItem.ImageInfo(width: width, height: height, byteCount: png.count, sha256: sha256)
  }

  /// 按需生成缩略图（长边 maxPixel），不解码整张原图
  @concurrent func thumbnail(for id: UUID, maxPixel: Int) async -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url(for: id) as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  func delete(_ id: UUID) {
    try? FileManager.default.removeItem(at: url(for: id))
  }

  /// 删掉库里没有记录的图片文件（异常退出时留下的）。只删 cutoff 之前就存在的文件，
  /// 免得删掉刚写好、还没来得及入库的那张
  func removeOrphans(keeping ids: Set<UUID>, createdBefore cutoff: Date) {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
    for file in files {
      guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
        !ids.contains(id),
        let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
        created < cutoff
      else { continue }
      try? FileManager.default.removeItem(at: file)
    }
  }
}
