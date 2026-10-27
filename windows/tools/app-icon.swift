// 在 Mac 上把 mac 版的应用图标打包成 Windows 用的 .ico：swift windows/tools/app-icon.swift
// 输入是 macos/brand-icons.swift 生成的 AppIcon PNG（改角色先跑那个脚本，再跑这个）；输出两个文件，各 16 / 20 / 24 / 32 /
// 40 / 48 / 64 / 256 八档、每档存 PNG：
// - windows/KittyTools/Resources/AppIcon.ico：应用图标，托盘也用它（Windows 托盘习惯用彩色应用图标，不分深浅色）；
// - windows/KittyTools/Resources/AppIconRecording.ico：同一张图右下角加一个红点（录屏、录音时的托盘图标，PLAN-v4 V8）。
// 另出安装程序（Inno Setup，PLAN-setup-inno §3）的两组透明底 PNG，放在 windows/installer/：右上角的小图 wizard-small-*.png，
// 完成页左边那条 wizard-large-<宽>x<高>.png（只放图标，深浅色外观都能用）；尺寸照 Inno 帮助里按 DPI 的表，它自己挑最接近的。
// 每档取 mac 那组里不小于它的最小一张缩下来：16、32 用 mac 手调过的小图原样，20、24 从 32 缩，40、48 从 64 缩。
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
let mac = root.appendingPathComponent("macos/KittyTools/Resources/Assets.xcassets/AppIcon.appiconset")
let resources = root.appendingPathComponent("windows/KittyTools/Resources")
let sources: [(Int, String)] = [
  (16, "icon_16x16.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"), (256, "icon_256x256.png"),
]
let sizes = [16, 20, 24, 32, 40, 48, 64, 256]

func load(_ name: String) -> CGImage {
  let src = CGImageSourceCreateWithURL(mac.appendingPathComponent(name) as CFURL, nil)!
  return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

func canvas(_ size: Int) -> CGContext {
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  return ctx
}

func scaled(_ image: CGImage, to size: Int) -> CGImage {
  if image.width == size { return image }
  let ctx = canvas(size)
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
  return ctx.makeImage()!
}

/// 右下角的红点：直径约四成，白边隔开底下的图（CG 坐标原点在左下）
func recording(_ image: CGImage) -> CGImage {
  let size = CGFloat(image.width)
  let ctx = canvas(image.width)
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
  let diameter = (size * 0.44).rounded()
  let ring = max(1, (size * 0.06).rounded())
  let dot = CGRect(x: size - diameter, y: 0, width: diameter, height: diameter)
  ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
  ctx.fillEllipse(in: dot)
  ctx.setFillColor(CGColor(srgbRed: 1, green: 0x3B / 255.0, blue: 0x30 / 255.0, alpha: 1))
  ctx.fillEllipse(in: dot.insetBy(dx: ring, dy: ring))
  return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
  let data = NSMutableData()
  let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  return data as Data
}

/// ICO：6 字节头 + 每档 16 字节目录项 + 各档 PNG 数据（256 在目录项里写 0）
func ico(_ images: [Data]) -> Data {
  var out = Data()
  func u16(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
  func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16) }
  u16(0); u16(1); u16(sizes.count)
  var offset = 6 + 16 * sizes.count
  for (size, data) in zip(sizes, images) {
    out.append(UInt8(size >= 256 ? 0 : size)); out.append(UInt8(size >= 256 ? 0 : size))
    out.append(0); out.append(0); u16(1); u16(32); u32(data.count); u32(offset)
    offset += data.count
  }
  images.forEach { out.append($0) }
  return out
}

let base = sizes.map { size in scaled(load(sources.first { $0.0 >= size }!.1), to: size) }
for (name, images) in [("AppIcon.ico", base), ("AppIconRecording.ico", base.map(recording))] {
  let data = ico(images.map(png))
  try data.write(to: resources.appendingPathComponent(name))
  print("\(name)：\(sizes.count) 档，\(data.count) 字节")
}

let installer = root.appendingPathComponent("windows/installer")
try FileManager.default.createDirectory(at: installer, withIntermediateDirectories: true)
let large = load("icon_512x512@2x.png")
for size in [58, 77, 97, 116, 124, 143, 159] {
  try png(scaled(large, to: size)).write(to: installer.appendingPathComponent("wizard-small-\(size).png"))
}
for (width, height) in [(202, 386), (269, 515), (336, 643), (403, 772), (430, 824), (498, 953), (534, 1022)] {
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  // 图标宽占六成、中心在离顶边四成的地方（CG 坐标原点在左下）
  let side = (CGFloat(width) * 0.6).rounded()
  ctx.draw(large, in: CGRect(x: (CGFloat(width) - side) / 2, y: CGFloat(height) * 0.6 - side / 2, width: side, height: side))
  try png(ctx.makeImage()!).write(to: installer.appendingPathComponent("wizard-large-\(width)x\(height).png"))
}
print("installer：7 张小图、7 张品牌图")
