// 官网截图：把 macos 分支 WebsiteShotsTests 出的 PNG 转成网页用的格式，写进 docs/assets/。
// 用法（仓库根目录）：swift tools/site-shots.swift <探针的出图目录>
//   <名字>-light.png / -dark.png（带透明角的面板，@2x）→ shots/<名字>-light.avif、-dark.avif（原尺寸），
//     另出 shots/<名字>-light.png（缩到 @1x，给不认 AVIF 的旧浏览器）
//   island*.png（纯黑带透明，很小）→ shots/ 原样拷贝
//   其余 <名字>.png（全屏类，不透明）→ shots/<名字>.jpg（最宽 1600）
//   wallpaper-light.png / -dark.png → wallpaper-light.avif、-dark.avif（最宽 1600，面板背后的底）
// 只用 ImageIO / CoreGraphics。网页里 <img> 的 width / height 只管加载前占位，图换了比例也不会变形。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let avif = UTType("public.avif")!

let input = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let assets = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../docs/assets").standardized
let shots = assets.appending(path: "shots")
try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

func load(_ url: URL) -> CGImage {
  let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
  return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func scaled(_ image: CGImage, maxWidth: Int) -> CGImage {
  guard image.width > maxWidth else { return image }
  let width = maxWidth
  let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()!
}

func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil) {
  let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
  var options: [CFString: Any] = [:]
  if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
  CGImageDestinationAddImage(destination, image, options as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { fatalError("写不出 \(url.path)") }
  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  print("\(url.lastPathComponent)\t\(image.width)×\(image.height)\t\(size / 1024) KB")
}

let names = try FileManager.default.contentsOfDirectory(atPath: input.path).filter { $0.hasSuffix(".png") }.sorted()
for name in names {
  let base = String(name.dropLast(4))
  let image = load(input.appending(path: name))
  if base.hasPrefix("wallpaper-") {
    write(scaled(image, maxWidth: 1600), to: assets.appending(path: base + ".avif"), type: avif, quality: 0.7)
  } else if base.hasPrefix("island") {
    try? FileManager.default.removeItem(at: shots.appending(path: name))
    try FileManager.default.copyItem(at: input.appending(path: name), to: shots.appending(path: name))
    print("\(name)\t\(image.width)×\(image.height)\t拷贝")
  } else if base.hasSuffix("-light") || base.hasSuffix("-dark") {
    write(image, to: shots.appending(path: base + ".avif"), type: avif, quality: 0.72)
    if base.hasSuffix("-light") {
      write(scaled(image, maxWidth: image.width / 2), to: shots.appending(path: name), type: .png)
    }
  } else {
    write(scaled(image, maxWidth: 1600), to: shots.appending(path: base + ".jpg"), type: .jpeg, quality: 0.84)
  }
}
