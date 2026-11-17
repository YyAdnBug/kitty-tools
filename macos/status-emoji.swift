#!/usr/bin/env swift
// 状态屏的动画表情（PLAN §10「状态屏」Z15）：把 Microsoft Fluent Emoji Animated 的动画 PNG 转成应用里用的
// HEICS（HEVC 图像序列，带透明通道）。素材出处 https://github.com/microsoft/fluentui-emoji-animated ，MIT 许可
// （许可全文在 KittyTools/Resources/status-emoji-LICENSE.txt）。原文件每个 0.5–2.8 MB，不进仓库；转完每个约 0.1–0.3 MB。
// 画质 0.65（quality；2026-11-04 试过：默认画质平均 281 KB，0.65 是 186 KB、放大 3 倍看不出差别，0.5 眼睛边缘起块、渐变有断层；
// 抽一半帧只剩 12 帧每秒、动起来卡，不用）。
// 用法：swift macos/status-emoji.swift <放着下载好的 *_animated*.png 的目录>… [--out <输出目录>]
//   默认输出到 macos/KittyTools/Resources/（同步文件夹，文件名 status-emoji-<id>.heics，打进包里是平铺的）。
// 2026-11-17 起这里只转打进包里的那几个：自带的三个状态、三条示例提醒用的和眼睛（StatusEmoji.bundled）。图标格子里
// 另外 22 个和「动画表情」一样在 release emoji-pack-1 上（emoji-pack.swift 转的，同一种转法），第一次用到时下载。
// 要再打进包里一个：从上面的仓库下载它的 animated PNG，在 emoji 表里加一行，再跑一遍，同时加进 StatusEmoji.bundled。
// 只用 ImageIO / CoreGraphics：帧数、每帧时长原样保留，不缩放（原图就是 256 × 256）。
// 2026-11-04 格子里加了 12 个（吃饭、运动、通勤、看病、喝水、学习、专注、庆祝、上班、出门、生日、完成这些场景；动画的那一套里没有
// 药丸、书、耳机、房子、对勾、碗，取最接近的），2026-11-17 起它们也从 release 下载。

import Foundation
import ImageIO

/// 应用里的 id → 仓库里的文件名
let emoji: [(id: String, file: String)] = [
  ("raised-hand", "raised_hand_animated_default.png"),
  ("waving-hand", "waving_hand_animated_default.png"),
  ("glowing-star", "glowing_star_animated.png"),
  ("alarm-clock", "alarm_clock_animated.png"),
  ("hot-beverage", "hot_beverage_animated.png"),
  ("sleeping-face", "sleeping_face_animated.png"),
  ("eyes", "eyes_animated.png"),
]

/// HEVC 的画质（0–1）：见文件头
let quality = 0.65

var arguments = Array(CommandLine.arguments.dropFirst())
var output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("KittyTools/Resources")
if let flag = arguments.firstIndex(of: "--out"), arguments.indices.contains(flag + 1) {
  output = URL(fileURLWithPath: arguments[flag + 1])
  arguments.removeSubrange(flag...(flag + 1))
}
let sources = arguments.map { URL(fileURLWithPath: $0) }
guard !sources.isEmpty else {
  print("用法：swift status-emoji.swift <源目录>… [--out <输出目录>]")
  exit(1)
}

func delay(_ source: CGImageSource, _ index: Int) -> Double {
  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
  let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
  let value =
    png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
    ?? png?[kCGImagePropertyAPNGDelayTime] as? Double ?? 0
  return value > 0 ? value : 1.0 / 24
}

var total = 0
var failed = false
for item in emoji {
  guard
    let url = sources.map({ $0.appendingPathComponent(item.file) })
      .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)
  else {
    print("缺 \(item.file)")
    failed = true
    continue
  }
  let count = CGImageSourceGetCount(source)
  let target = output.appendingPathComponent("status-emoji-\(item.id).heics")
  guard
    count > 1,
    let destination = CGImageDestinationCreateWithURL(
      target as CFURL, "public.heics" as CFString, count, nil)
  else {
    print("写不了 \(target.lastPathComponent)")
    failed = true
    continue
  }
  CGImageDestinationSetProperties(
    destination, [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0]] as CFDictionary)
  for index in 0..<count {
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
    let seconds = delay(source, index)
    CGImageDestinationAddImage(
      destination, image,
      [
        kCGImagePropertyHEICSDictionary: [
          kCGImagePropertyHEICSDelayTime: seconds, kCGImagePropertyHEICSUnclampedDelayTime: seconds,
        ],
        kCGImageDestinationLossyCompressionQuality: quality,
      ] as CFDictionary)
  }
  guard CGImageDestinationFinalize(destination) else {
    print("没写成 \(target.lastPathComponent)")
    failed = true
    continue
  }
  let bytes = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int) ?? 0
  total += bytes
  print("\(item.id)\t\(count) 帧\t\(bytes / 1024) KB")
}
print("共 \(total / 1024) KB")
exit(failed ? 1 : 0)
