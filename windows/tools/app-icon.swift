// 在 Mac 上把 mac 版的应用图标打包成 Windows 用的 .ico：swift windows/tools/app-icon.swift
// 输入是 macos/brand-icons.swift 生成的 AppIcon PNG（改角色先跑那个脚本，再跑这个）；
// 输出 windows/KittyTools/Resources/AppIcon.ico：16 / 20 / 24 / 32 / 40 / 48 / 64 / 256 八档，每档存 PNG。
// 托盘也用这个图标（Windows 托盘习惯用彩色应用图标，不分深浅色）。
// 每档取 mac 那组里不小于它的最小一张缩下来：16、32 用 mac 手调过的小图原样，20、24 从 32 缩，40、48 从 64 缩。
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
let mac = root.appendingPathComponent("macos/KittyTools/Resources/Assets.xcassets/AppIcon.appiconset")
let sources: [(Int, String)] = [
  (16, "icon_16x16.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"), (256, "icon_256x256.png"),
]

func load(_ name: String) -> CGImage {
  let src = CGImageSourceCreateWithURL(mac.appendingPathComponent(name) as CFURL, nil)!
  return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

func png(_ image: CGImage, size: Int) -> Data {
  var image = image
  if image.width != size {
    let ctx = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    image = ctx.makeImage()!
  }
  let data = NSMutableData()
  let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  return data as Data
}

let sizes = [16, 20, 24, 32, 40, 48, 64, 256]
let images = sizes.map { size in png(load(sources.first { $0.0 >= size }!.1), size: size) }

// ICO：6 字节头 + 每档 16 字节目录项 + 各档 PNG 数据（256 在目录项里写 0）
var ico = Data()
func u16(_ v: Int) { ico.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16) }
u16(0); u16(1); u16(sizes.count)
var offset = 6 + 16 * sizes.count
for (size, data) in zip(sizes, images) {
  ico.append(UInt8(size >= 256 ? 0 : size)); ico.append(UInt8(size >= 256 ? 0 : size))
  ico.append(0); ico.append(0); u16(1); u16(32); u32(data.count); u32(offset)
  offset += data.count
}
images.forEach { ico.append($0) }
let out = root.appendingPathComponent("windows/KittyTools/Resources/AppIcon.ico")
try ico.write(to: out)
print("\(sizes.count) 档，\(ico.count) 字节 → \(out.path)")
