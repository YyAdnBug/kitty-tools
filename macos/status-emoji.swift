#!/usr/bin/env swift
// 状态屏的动画表情（PLAN §10「状态屏」Z15）：把 Microsoft Fluent Emoji Animated 的动画 PNG 转成应用里用的
// HEICS（HEVC 图像序列，带透明通道）。素材出处 https://github.com/microsoft/fluentui-emoji-animated ，MIT 许可
// （许可全文在 KittyTools/Resources/status-emoji-LICENSE.txt）。原文件每个 0.8–2.8 MB，不进仓库；转完每个约 0.2–0.5 MB。
// 用法：swift macos/status-emoji.swift <放着下载好的 *_animated*.png 的目录>… [--out <输出目录>]
//   默认输出到 macos/KittyTools/Resources/（同步文件夹，文件名 status-emoji-<id>.heics，打进包里是平铺的）。
// 要加一个表情：从上面的仓库下载它的 animated PNG，在 emoji 表里加一行，再跑一遍；应用里的清单在 StatusEmoji.swift。
// 只用 ImageIO / CoreGraphics：帧数、每帧时长原样保留，不缩放（原图就是 256 × 256）。

import Foundation
import ImageIO

/// 应用里的 id → 仓库里的文件名
let emoji: [(id: String, file: String)] = [
  ("raised-hand", "raised_hand_animated_default.png"),
  ("waving-hand", "waving_hand_animated_default.png"),
  ("glowing-star", "glowing_star_animated.png"),
  ("alarm-clock", "alarm_clock_animated.png"),
  ("hourglass", "hourglass_not_done_animated.png"),
  ("hot-beverage", "hot_beverage_animated.png"),
  ("zzz", "zzz_animated.png"),
  ("sleeping-face", "sleeping_face_animated.png"),
  ("shushing-face", "shushing_face_animated.png"),
  ("busts", "busts_in_silhouette_animated.png"),
  ("telephone", "telephone_receiver_animated.png"),
  ("rocket", "rocket_animated.png"),
  ("robot", "robot_animated.png"),
  ("fire", "fire_animated.png"),
  ("high-voltage", "high_voltage_animated.png"),
  ("black-cat", "black_cat_animated.png"),
  ("eyes", "eyes_animated.png"),
]

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
        ]
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
