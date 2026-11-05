#!/usr/bin/env swift
// 动画表情包（2026-11-05 用户「所有图标按 URL 加载、缓存在本地」，PLAN §10「功能管理」下的记录）：把 Microsoft Fluent Emoji
// Animated 的全部 746 个（默认肤色）转成应用里用的 HEICS，和包里自带的 28 个同一种转法（status-emoji.swift：HEVC 画质 0.65、
// 帧数和每帧时长原样、不缩放），再出一张对照表 emoji-pack.json：表情字 → 文件编号。
// 转好的文件传到本仓库的一个单独的 release（tag emoji-pack-<版本>，不标 latest），App 里挑到有动画版的系统表情时按编号去下载、
// 缓存在数据目录（StatusScreen/EmojiPack.swift）；对照表打进包里（Resources/emoji-pack.json）。素材 MIT，许可同
// Resources/status-emoji-LICENSE.txt，release 里也附一份。
// 用法：swift macos/emoji-pack.swift <源目录> <输出目录> [--tag emoji-pack-1]
//   源目录：每个表情一个子目录，里面是仓库里的 metadata.json 和那个 *_animated*.png（下载脚本照仓库的 assets/<名字>/ 摆）。
//   输出：<输出目录>/<编号>.heics 和 <输出目录>/emoji-pack.json（再拷进 macos/KittyTools/Resources/）。
// 编号 = 文件名去掉 _animated / _animated_default、下划线换成连字符（rocket、person-running），只许 [a-z0-9-]，撞了就报错。
// 对照表里的表情字去掉表情变体符（U+FE0F）：系统表情面板插进来的带不带它不一定，查的时候 App 也去掉。

import Foundation
import ImageIO

var arguments = Array(CommandLine.arguments.dropFirst())
var tag = "emoji-pack-1"
if let flag = arguments.firstIndex(of: "--tag"), arguments.indices.contains(flag + 1) {
  tag = arguments[flag + 1]
  arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 2 else {
  print("用法：swift emoji-pack.swift <源目录> <输出目录> [--tag emoji-pack-1]")
  exit(1)
}
let source = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// 同 status-emoji.swift 的画质
let quality = 0.65

struct Metadata: Decodable {
  let glyph: String
}

func delay(_ source: CGImageSource, _ index: Int) -> Double {
  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
  let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
  let value =
    png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
    ?? png?[kCGImagePropertyAPNGDelayTime] as? Double ?? 0
  return value > 0 ? value : 1.0 / 24
}

func convert(_ png: URL, to target: URL) -> Bool {
  guard let source = CGImageSourceCreateWithURL(png as CFURL, nil) else { return false }
  let count = CGImageSourceGetCount(source)
  guard count > 1,
    let destination = CGImageDestinationCreateWithURL(
      target as CFURL, "public.heics" as CFString, count, nil)
  else { return false }
  CGImageDestinationSetProperties(
    destination, [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0]] as CFDictionary)
  for index in 0..<count {
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return false }
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
  return CGImageDestinationFinalize(destination)
}

func identifier(_ file: String) -> String {
  file.replacingOccurrences(of: ".png", with: "")
    .replacingOccurrences(of: "_animated_default", with: "")
    .replacingOccurrences(of: "_animated", with: "")
    .replacingOccurrences(of: "_", with: "-")
    .lowercased()
}

let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
var table: [String: String] = [:]
var ids: Set<String> = []
var total = 0
var failed = false
let folders = try FileManager.default.contentsOfDirectory(
  at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
).sorted { $0.path < $1.path }
for folder in folders {
  let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
  guard let png = files.first(where: { $0.hasSuffix(".png") }),
    let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
    let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
  else {
    print("缺文件：\(folder.lastPathComponent)")
    failed = true
    continue
  }
  let id = identifier(png)
  let glyph = metadata.glyph.replacingOccurrences(of: "\u{FE0F}", with: "")
  guard !id.isEmpty, id.allSatisfy(allowed.contains), ids.insert(id).inserted,
    table[glyph] == nil
  else {
    print("编号不合规或重复：\(id) \(glyph)")
    failed = true
    continue
  }
  let target = output.appendingPathComponent("\(id).heics")
  if !FileManager.default.fileExists(atPath: target.path) {
    guard convert(folder.appendingPathComponent(png), to: target) else {
      print("转不了：\(png)")
      failed = true
      continue
    }
  }
  table[glyph] = id
  total += ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int) ?? 0
}

struct Catalog: Encodable {
  let tag: String
  let emoji: [String: String]
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(Catalog(tag: tag, emoji: table))
  .write(to: output.appendingPathComponent("emoji-pack.json"))
print("\(table.count) 个，共 \(total / 1_048_576) MB，平均 \(table.isEmpty ? 0 : total / table.count / 1024) KB")
exit(failed ? 1 : 0)
