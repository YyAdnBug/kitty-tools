#!/usr/bin/env swift  // 动画表情包（2026-11-05 用户「所有图标按 URL 加载、缓存在本地」，PLAN §10「功能管理」下的记录）：把 Microsoft Fluent Emoji  // Animated 的全部 746 个（默认肤色）转成应用里用的 HEICS，和包里自带的 28 个同一种转法（status-emoji.swift：HEVC 画质 0.65、
// 帧数和每帧时长原样、不缩放），再出一张对照表 emoji-pack.json（每个一条：编号、表情字、分类、中文名、搜索用的中文 / 英文关键词）
// 和每个一张 96 × 96 的缩略图 emoji-thumb-<编号>.heic（「动画表情」弹窗的格子、还没下好时垫着用，打进包里）。
// 中文名和关键词来自 Unicode CLDR 的中文注释（cldr-json 的 annotations / annotationsDerived 的 zh，Unicode 许可，只在生成时用）。
// 转好的文件传到本仓库的一个单独的 release（tag emoji-pack-<版本>，不标 latest），App 里在「动画表情」气泡挑了、第一次用到时按编号下载、
// 缓存在数据目录（StatusScreen/EmojiPack.swift）；对照表打进包里（Resources/emoji-pack.json）。素材 MIT，许可同
// Resources/status-emoji-LICENSE.txt，release 里也附一份。
// 用法：swift macos/emoji-pack.swift <源目录> <输出目录> --cldr <CLDR 目录> [--tag emoji-pack-1]
//   源目录：每个表情一个子目录，里面是仓库里的 metadata.json 和那个 *_animated*.png（下载脚本照仓库的 assets/<名字>/ 摆）。
//   CLDR 目录：annotations.json（cldr-annotations-full 的 annotations/zh）和 derived.json（cldr-annotations-derived-full 的
//   annotationsDerived/zh）。
//   输出：<输出目录>/<编号>.heics（传到 release）、<输出目录>/emoji-pack.json（拷进 macos/KittyTools/Resources/）、
//   <输出目录>/thumbs/emoji-thumb-<编号>.heic（拷进 macos/KittyTools/Resources/emoji-thumbs/）。
// 编号 = 文件名去掉 _animated / _animated_default、下划线换成连字符（rocket、person-running），只许 [a-z0-9-]，撞了就报错。
// 对照表里的表情字去掉表情变体符（U+FE0F）：搜表情字时 App 也去掉再比。

import Foundation
import ImageIO

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
  guard let flag = arguments.firstIndex(of: name), arguments.indices.contains(flag + 1) else {
    return nil
  }
  defer { arguments.removeSubrange(flag...(flag + 1)) }
  return arguments[flag + 1]
}
let tag = option("--tag") ?? "emoji-pack-1"
guard let cldrPath = option("--cldr"), arguments.count == 2 else {
  print("用法：swift emoji-pack.swift <源目录> <输出目录> --cldr <CLDR 目录> [--tag emoji-pack-1]")
  exit(1)
}
let source = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// 同 status-emoji.swift 的画质
let quality = 0.65

struct Metadata: Decodable {
  let glyph: String
  let group: String
  let cldr: String
  let keywords: [String]
}

/// CLDR 的一条中文注释：tts 是名字，default 是关键词
struct Annotation: Decodable {
  let tts: [String]?
  let `default`: [String]?
}

func annotations(_ file: String, _ path: [String]) throws -> [String: Annotation] {
  let data = try Data(contentsOf: URL(fileURLWithPath: cldrPath).appendingPathComponent(file))
  var node: Any = try JSONSerialization.jsonObject(with: data)
  for key in path { node = (node as? [String: Any])?[key] ?? [:] }
  let raw = try JSONSerialization.data(withJSONObject: node)
  return try JSONDecoder().decode([String: Annotation].self, from: raw)
}
let chinese = try annotations("annotations.json", ["annotations", "annotations"]).merging(
  annotations("derived.json", ["annotationsDerived", "annotations"])
) { first, _ in first }

/// Fluent 的分类 → App 里的分类（同系统表情面板底下那一排：笑脸与人物合在一起）
func tab(_ group: String) -> String {
  switch group {
  case "Smileys & Emotion", "People & Body": "people"
  case "Animals & Nature": "nature"
  case "Food & Drink": "food"
  case "Activities": "activities"
  case "Travel & Places": "travel"
  case "Flags": "flags"
  default: "objects"
  }
}

/// 第一帧缩到 96 × 96 存成 HEIC（带透明）
func thumbnail(_ png: URL, to target: URL) -> Bool {
  guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
      ] as CFDictionary),
    let destination = CGImageDestinationCreateWithURL(
      target as CFURL, "public.heic" as CFString, 1, nil)
  else { return false }
  CGImageDestinationAddImage(
    destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
  return CGImageDestinationFinalize(destination)
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
    destination,
    [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0]] as CFDictionary)
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

struct Entry: Encodable {
  let id: String
  let glyph: String
  let group: String
  let name: String
  let keywords: [String]
}

let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
let thumbs = output.appendingPathComponent("thumbs")
try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
var table: [String: String] = [:]
var entries: [Entry] = []
var ids: Set<String> = []
var unnamed: [String] = []
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
  let thumb = thumbs.appendingPathComponent("emoji-thumb-\(id).heic")
  if !FileManager.default.fileExists(atPath: thumb.path) {
    guard thumbnail(folder.appendingPathComponent(png), to: thumb) else {
      print("缩略图做不了：\(png)")
      failed = true
      continue
    }
  }
  let note = chinese[metadata.glyph] ?? chinese[glyph]
  let name = note?.tts?.first ?? metadata.cldr
  if note?.tts?.first == nil { unnamed.append(id) }
  var words: [String] = []
  for word in (note?.default ?? []) + [metadata.cldr] + metadata.keywords
  where !words.contains(word) {
    words.append(word)
  }
  table[glyph] = id
  entries.append(
    Entry(id: id, glyph: glyph, group: tab(metadata.group), name: name, keywords: words))
  total += ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int) ?? 0
}
if !unnamed.isEmpty { print("没有中文名（用英文）：\(unnamed.joined(separator: " "))") }

struct Catalog: Encodable {
  let tag: String
  let emoji: [Entry]
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
// 照 Fluent 仓库里的顺序（按英文名）不好找：按分类、再按 Unicode 码位排（和系统表情面板差不多的顺序）
let order = ["people", "nature", "food", "activities", "travel", "objects", "flags"]
func rank(_ scalar: UInt32) -> Int {
  let blocks: [ClosedRange<UInt32>] = [
    0x1F600...0x1F64F, 0x1F910...0x1F9FF, 0x1FA70...0x1FAFF, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF,
  ]
  return blocks.firstIndex { $0.contains(scalar) } ?? blocks.count
}
let sorted = entries.sorted {
  let (a, b) = (order.firstIndex(of: $0.group) ?? 9, order.firstIndex(of: $1.group) ?? 9)
  if a != b { return a < b }
  // 码位段排先后，接近系统表情面板：脸（😀–🙏、🤐 往后）在前，再是 🌀–🗿、🚀–🛿，基本平面的老符号（☠☺☕）最后
  let (x, y) = ($0.glyph.unicodeScalars.map(\.value), $1.glyph.unicodeScalars.map(\.value))
  let (rankX, rankY) = (rank(x.first ?? 0), rank(y.first ?? 0))
  return rankX != rankY ? rankX < rankY : x.lexicographicallyPrecedes(y)
}
try encoder.encode(Catalog(tag: tag, emoji: sorted))
  .write(to: output.appendingPathComponent("emoji-pack.json"))
print(
  "\(table.count) 个，共 \(total / 1_048_576) MB，平均 \(table.isEmpty ? 0 : total / table.count / 1024) KB"
)
exit(failed ? 1 : 0)
