#!/usr/bin/env swift
// 品牌图标生成脚本（Whisker C 阶段，D1 原创角色「探头」：小黑猫扒在剪贴板卡片边上往下看）。
// 用法：swift macos/brand-icons.swift [预览目录]
// 写入 KittyTools/Resources/Assets.xcassets：AppIcon 10 张 PNG（1024 画布、主体 824、四边留 100、超椭圆圆角约 185、
// 烘焙阴影 y 10 / σ 10 / 黑 30%；16、32 像素用手调的简化版）和菜单栏模板图 StatusIcon（22 × 16 pt，@1x / @2x）。
// 只用 AppKit / CoreGraphics，几何都在这一个文件里：改角色就改这里再跑一遍。给了预览目录时另存放大的预览图。

import AppKit

// MARK: 画布

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

let ink = hex(0x3A2530)
let cream = hex(0xFFF5F0)
let beans = hex(0xFF9FB8)
let cardLine = hex(0xFFCFDC)

/// 像素画布，坐标原点左上、y 向下，`unit` 个设计单位 = 画布边长
func render(pixels: Int, unit: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(pixels))
  ctx.scaleBy(x: CGFloat(pixels) / unit, y: -CGFloat(pixels) / unit)
  draw(ctx)
  return ctx.makeImage()!
}

func ellipse(
  _ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor
) {
  ctx.setFillColor(color)
  ctx.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

func roundRect(
  _ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
  _ color: CGColor
) {
  ctx.setFillColor(color)
  ctx.addPath(
    CGPath(
      roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r,
      transform: nil))
  ctx.fillPath()
}

/// 圆角三角形：填充 + 同色圆角描边（耳朵、鼻子）
func triangle(_ ctx: CGContext, _ points: [CGPoint], _ color: CGColor, round: CGFloat) {
  let path = CGMutablePath()
  path.addLines(between: points)
  path.closeSubpath()
  ctx.setFillColor(color)
  ctx.setStrokeColor(color)
  ctx.setLineWidth(round)
  ctx.setLineJoin(.round)
  ctx.addPath(path)
  ctx.drawPath(using: .fillStroke)
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// 左右对称：给左边的点，镜像出右边（画布中线 = unit / 2）
func mirrored(_ points: [CGPoint], unit: CGFloat) -> [CGPoint] {
  points.map { CGPoint(x: unit - $0.x, y: $0.y) }
}

/// macOS 图标外形：超椭圆（n = 5）近似连续圆角，主体 824、四边留 100 时圆角约 185
func squircle(center: CGFloat, radius: CGFloat) -> CGPath {
  let path = CGMutablePath()
  let n: CGFloat = 5
  let steps = 256
  for i in 0..<steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let x = cos(t)
    let y = sin(t)
    let px = center + radius * (x < 0 ? -1 : 1) * pow(abs(x), 2 / n)
    let py = center + radius * (y < 0 ? -1 : 1) * pow(abs(y), 2 / n)
    if i == 0 { path.move(to: point(px, py)) } else { path.addLine(to: point(px, py)) }
  }
  path.closeSubpath()
  return path
}

/// 底板：粉色渐变 + 左上一点柔光 + 烘焙阴影；之后的内容都裁在底板里
func plate(_ ctx: CGContext, unit: CGFloat, pixelsPerUnit: CGFloat, shadow: Bool = true) {
  let shape = squircle(center: unit / 2, radius: unit * 412 / 1024)
  if shadow {
    ctx.saveGState()
    // 阴影参数不跟 CTM 走，按像素给：y 10、σ 10（CG 的 blur 约等于 2σ）
    ctx.setShadow(
      offset: CGSize(width: 0, height: -10 * pixelsPerUnit * unit / 1024),
      blur: 20 * pixelsPerUnit * unit / 1024, color: hex(0x000000, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(hex(0xFF4D7E))
    ctx.fillPath()
    ctx.restoreGState()
  }
  ctx.addPath(shape)
  ctx.clip()
  let fill = CGGradient(
    colorsSpace: sRGB, colors: [hex(0xFF86A9), hex(0xFF4D7E), hex(0xE93A6D)] as CFArray,
    locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(
    fill, start: point(0, unit * 100 / 1024), end: point(0, unit * 924 / 1024), options: [])
  let glow = CGGradient(
    colorsSpace: sRGB, colors: [hex(0xFFFFFF, 0.22), hex(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawRadialGradient(
    glow, startCenter: point(unit * 0.3, unit * 0.2), startRadius: 0,
    endCenter: point(unit * 0.3, unit * 0.2), endRadius: unit * 0.55, options: [])
}

// MARK: 探头（1024 设计单位）

func kitten(_ ctx: CGContext) {
  let u: CGFloat = 1024
  // 耳朵（外黑内粉）：耳尖往外撇，和脸颊之间留出一个缺口（不然头像顶头盔）
  let ear = [point(352, 392), point(296, 204), point(478, 330)]
  triangle(ctx, ear, ink, round: 32)
  triangle(ctx, mirrored(ear, unit: u), ink, round: 32)
  let inner = [point(366, 354), point(338, 260), point(426, 320)]
  triangle(ctx, inner, hex(0xFF7FA0), round: 12)
  triangle(ctx, mirrored(inner, unit: u), hex(0xFF7FA0), round: 12)
  // 头
  ellipse(ctx, 512, 522, 256, 208, ink)
  // 腮红
  ellipse(ctx, 352, 568, 30, 16, hex(0xFF7FA0, 0.8))
  ellipse(ctx, 672, 568, 30, 16, hex(0xFF7FA0, 0.8))
  // 眼睛：奶油色眼白，瞳孔往下看卡片，一大一小两个高光
  for cx: CGFloat in [424, 600] {
    ellipse(ctx, cx, 500, 56, 60, cream)
    ellipse(ctx, cx + 6, 524, 34, 35, ink)
    ellipse(ctx, cx + 21, 507, 11.5, 11.5, hex(0xFFFFFF))
    ellipse(ctx, cx - 8, 541, 5.5, 5.5, hex(0xFFFFFF, 0.9))
  }
  // 鼻子和 ω 嘴
  triangle(ctx, [point(496, 566), point(528, 566), point(512, 585)], hex(0xFF7FA0), round: 10)
  let mouth = CGMutablePath()
  mouth.move(to: point(490, 594))
  mouth.addQuadCurve(to: point(512, 596), control: point(500, 612))
  mouth.addQuadCurve(to: point(534, 594), control: point(524, 612))
  ctx.setStrokeColor(hex(0xFF9FB8))
  ctx.setLineWidth(8)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.addPath(mouth)
  ctx.strokePath()
  // 剪贴板卡片 + 内容条
  roundRect(ctx, 168, 614, 688, 440, 60, cream)
  roundRect(ctx, 252, 744, 400, 32, 16, cardLine)
  roundRect(ctx, 252, 812, 520, 32, 16, cardLine)
  roundRect(ctx, 252, 880, 300, 32, 16, cardLine)
  // 爪子在卡片上压出的一点影子，再画爪子和肉垫
  for cx: CGFloat in [386, 638] {
    ellipse(ctx, cx, 652, 70, 13, hex(0xE9C6D0, 0.8))
    ellipse(ctx, cx, 616, 76, 46, ink)
    for (dx, dy) in [(-26.0, 14.0), (0.0, 21.0), (26.0, 14.0)] as [(CGFloat, CGFloat)] {
      ellipse(ctx, cx + dx, 616 + dy, 10, 9, beans)
    }
  }
}

/// 32 像素手调：头、耳、眼白、卡片、爪子都对到像素格上（设计单位 = 像素）
func kitten32(_ ctx: CGContext) {
  let u: CGFloat = 32
  let ear = [point(9.3, 14.4), point(9.9, 6.9), point(14.6, 10.6)]
  triangle(ctx, ear, ink, round: 1.2)
  triangle(ctx, mirrored(ear, unit: u), ink, round: 1.2)
  ellipse(ctx, 16, 16, 8.2, 6.6, ink)
  for cx: CGFloat in [13.2, 18.8] {
    ellipse(ctx, cx, 15.3, 1.9, 2, cream)
    ellipse(ctx, cx + 0.2, 16, 1.1, 1.1, ink)
  }
  roundRect(ctx, 5.2, 19.2, 21.6, 14, 2.2, cream)
  roundRect(ctx, 8, 24, 11, 1.2, 0.6, cardLine)
  roundRect(ctx, 8, 26.6, 14, 1.2, 0.6, cardLine)
  for cx: CGFloat in [12, 20] { ellipse(ctx, cx, 19.3, 2.5, 1.5, ink) }
}

/// 16 像素手调：只留黑头、两只耳朵、两点眼睛和卡片的一条边
func kitten16(_ ctx: CGContext) {
  let u: CGFloat = 16
  let ear = [point(4.7, 6.6), point(4.8, 3.1), point(7.1, 5)]
  triangle(ctx, ear, ink, round: 0.7)
  triangle(ctx, mirrored(ear, unit: u), ink, round: 0.7)
  ellipse(ctx, 8, 8.4, 4.2, 3.4, ink)
  ellipse(ctx, 6.5, 8, 1, 1, cream)
  ellipse(ctx, 9.5, 8, 1, 1, cream)
  roundRect(ctx, 2.5, 10.5, 11, 7, 1.2, cream)
}

func appIcon(pixels: Int) -> CGImage {
  switch pixels {
  case ...16:
    return render(pixels: pixels, unit: 16) {
      plate($0, unit: 16, pixelsPerUnit: CGFloat(pixels) / 16)
      kitten16($0)
    }
  case ...32:
    return render(pixels: pixels, unit: 32) {
      plate($0, unit: 32, pixelsPerUnit: CGFloat(pixels) / 32)
      kitten32($0)
    }
  default:
    return render(pixels: pixels, unit: 1024) {
      plate($0, unit: 1024, pixelsPerUnit: CGFloat(pixels) / 1024)
      kitten($0)
    }
  }
}

// MARK: 菜单栏剪影（22 × 16 pt，单色模板：只看不透明度）

func statusIcon(scale: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: 22 * scale, height: 16 * scale, bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(16 * scale))
  ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
  let black = hex(0x000000)
  let ear = [point(4.4, 7.4), point(5.0, 1.0), point(9.0, 3.9)]
  triangle(ctx, ear, black, round: 1)
  triangle(ctx, mirrored(ear, unit: 22), black, round: 1)
  // 头：椭圆在卡片边以上的部分
  let head = CGMutablePath()
  head.addEllipse(in: CGRect(x: 11 - 7.4, y: 8.3 - 6.2, width: 14.8, height: 12.4))
  ctx.saveGState()
  ctx.clip(to: CGRect(x: 0, y: 0, width: 22, height: 11))
  ctx.addPath(head)
  ctx.setFillColor(black)
  ctx.fillPath()
  ctx.restoreGState()
  // 卡片边 + 爪子：先在爪子周围挖出一圈缝，和头分开
  ctx.setBlendMode(.clear)
  for cx: CGFloat in [7, 15] { ellipse(ctx, cx, 12.9, 3, 2.3, black) }
  ctx.setBlendMode(.normal)
  roundRect(ctx, 0.5, 14, 21, 2, 1, black)
  for cx: CGFloat in [7, 15] { ellipse(ctx, cx, 12.9, 2.3, 1.8, black) }
  // 眼睛挖空（圆心在像素边界上）
  ctx.setBlendMode(.clear)
  for cx: CGFloat in [8, 14] { ellipse(ctx, cx, 7, 1.35, 1.45, black) }
  return ctx.makeImage()!
}

// MARK: 写文件

func writePNG(_ image: CGImage, to url: URL) {
  let rep = NSBitmapImageRep(cgImage: image)
  rep.size = NSSize(width: image.width, height: image.height)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let assets = macos.appending(path: "KittyTools/Resources/Assets.xcassets")
let appIconSet = assets.appending(path: "AppIcon.appiconset")
for (points, scale) in [
  (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
  let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
  writePNG(appIcon(pixels: points * scale), to: appIconSet.appending(path: name))
}
let statusSet = assets.appending(path: "StatusIcon.imageset")
try! FileManager.default.createDirectory(at: statusSet, withIntermediateDirectories: true)
writePNG(statusIcon(scale: 1), to: statusSet.appending(path: "StatusIcon.png"))
writePNG(statusIcon(scale: 2), to: statusSet.appending(path: "StatusIcon@2x.png"))
try! """
{
  "images" : [
    { "filename" : "StatusIcon.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "StatusIcon@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}

""".write(to: statusSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("已写入 AppIcon 10 张、StatusIcon @1x / @2x")

// 预览：大图原样，小图按像素放大 8 倍（不插值），菜单栏放在浅 / 深两条栏上
if CommandLine.arguments.count > 1 {
  let preview = URL(fileURLWithPath: CommandLine.arguments[1])
  try! FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
  writePNG(appIcon(pixels: 1024), to: preview.appending(path: "icon-1024.png"))
  func magnify(_ image: CGImage, _ factor: Int, background: CGColor?) -> CGImage {
    let ctx = CGContext(
      data: nil, width: image.width * factor, height: image.height * factor, bitsPerComponent: 8,
      bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background {
      ctx.setFillColor(background)
      ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    return ctx.makeImage()!
  }
  writePNG(
    magnify(appIcon(pixels: 16), 16, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-16-x16.png"))
  writePNG(
    magnify(appIcon(pixels: 32), 8, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-32-x8.png"))
  writePNG(
    magnify(appIcon(pixels: 64), 4, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-64-x4.png"))
  for (scale, factor) in [(1, 16), (2, 8)] {
    writePNG(
      magnify(statusIcon(scale: scale), factor, background: hex(0xF4EFF1)),
      to: preview.appending(path: "status-\(scale)x.png"))
  }
}
