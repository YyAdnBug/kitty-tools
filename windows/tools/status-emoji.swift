// 在 Mac 上生成 Windows 版状态屏的动画表情（PLAN-v12 N5；2026-11-17 补齐 28 个、加动画表情包，REVIEW R107）。两种用法：
//   swift windows/tools/status-emoji.swift <源目录>
//     包里自带的 28 个 + 眼睛，写进 windows/KittyTools/Resources/StatusEmoji/。
//   swift windows/tools/status-emoji.swift --pack <源目录> <输出目录> [--catalog <emoji-pack.json>]
//     动画表情包（release emoji-pack-1-win，App 里按需下载，KittyTools/StatusScreen/EmojiPack.cs）：源目录下面（可以分子目录，
//     同 mac 的 emoji-pack.swift 照素材仓库的 assets/<名字>/ 摆）所有 *_animated*.png 各出一个 <输出目录>/<编号>.png，再拷一份 LICENSE.txt。
//     编号 = 文件名去掉 _animated_default / _animated、下划线换成连字符（同 mac emoji-pack.swift），只许 [a-z0-9-]，撞了就报错。
//     给了 --catalog（windows/KittyTools/Resources/StatusEmoji/emoji-pack.json）就核对：对照表里每个编号都要有文件。
// 素材同 mac 版：Microsoft Fluent Emoji Animated 的动画 PNG（MIT，https://github.com/microsoft/fluentui-emoji-animated），
// 原文件每个 0.8–2.8 MB、256 × 256、37–73 帧、每帧 1/24 s，不进仓库（自带那 29 个本机在 kitty-tools-macos-modules/macos/build/status-emoji/src/；
// 表情包的 746 个共 1.6 GB，mac 发完 emoji-pack-1 就删了，要重新下）。
// WinUI 放 GIF 只有一位透明，边缘难看；每个表情出的是帧图集：
//   <id>.png        隔一帧取一帧（12 fps，每帧时长是两帧之和），每帧缩到 cell × cell，按行排（列数 = ceil(√帧数)），透明通道照留。
//                   160 像素、12 fps 自带的 28 个约 15 MB（png-squeeze 之后）；原样 24 fps 要翻倍、192 像素再多一半（mac 的 HEICS
//                   共 5.5 MB，Windows 不一定装了 HEIF 解码器）。App 里用合成层的表面画刷 + 一段离散的关键帧动画挪偏移来播（StatusEmoji.cs）。
//   自带的另出 <id>-still.png（第一帧，Still × Still：设置列表、图标格子、启动器、选状态的卡片这些小地方用）和 manifest.txt
//   （一个表情一行，制表符隔开：id  格子边长  列数  帧数  每帧毫秒（逗号隔开））。
//   表情包的不出静止画面、没有 manifest：同样那一行（去掉 id）写进图集自己的一个 tEXt 块（关键字 kitty-emoji），一个文件就能放
//   （Core 的 EmojiPackFile 读它、核对尺寸）。
// 生成完在 Windows 上跑一遍 png-squeeze（无损再压，约 -22%，tEXt 块原样留着）：
//   dotnet run windows/tools/png-squeeze.cs -- windows/KittyTools/Resources/StatusEmoji   （表情包换成输出目录）
// 要加自带的表情：两边的清单（这里的 emoji 表、mac 的 status-emoji.swift、Core 的 StatusEmojiCatalog.Choices）各加一行再跑。
// 只用 ImageIO / CoreGraphics。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图集里每帧多大：告示上表情最大约 125 DIP（标题字号上限 96 × 1.3），125% 屏上 156 像素（150% 屏上略放大）。
let cell = 160
/// 隔几帧取一帧（2 = 12 fps）
let step = 2
/// 静止画面多大：最大用在 40 DIP 的小图标上（200% 屏 80 像素）。
let still = 96
/// App 收的表情包文件上限（EmojiPack.MaxFileBytes），超了 App 不认
let maxPackBytes = 3 * 1_048_576
/// 图集里那个 tEXt 块的关键字（Core EmojiPackFile.Keyword）
let keyword = "kitty-emoji"
/// App 收的图集（Core EmojiSheet.Decode）：帧数 2…256（隔帧取完至少还有两帧）、列数和行数都不超过 16
let maxFrames = 256
let maxColumns = 16

/// App 里的 id → 仓库里的文件名（顺序同 mac 的 StatusEmoji.ids，眼睛在最后；后 12 个是 mac 2026-11-04 加的）
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
  ("cook", "cook_animated_default.png"),
  ("person-running", "person_running_animated_default.png"),
  ("automobile", "automobile_animated.png"),
  ("health-worker", "health_worker_animated_default.png"),
  ("droplet", "droplet_animated.png"),
  ("student", "student_animated_default.png"),
  ("lotus-position", "person_in_lotus_position_animated_default.png"),
  ("party-popper", "party_popper_animated.png"),
  ("office-worker", "office_worker_animated_default.png"),
  ("person-walking", "person_walking_animated_default.png"),
  ("birthday-cake", "birthday_cake_animated.png"),
  ("thumbs-up", "thumbs_up_animated_default.png"),
  ("eyes", "eyes_animated.png"),
]

let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("../KittyTools/Resources/StatusEmoji").standardizedFileURL

func delay(_ images: CGImageSource, _ index: Int) -> Int {
  let properties = CGImageSourceCopyPropertiesAtIndex(images, index, nil) as? [CFString: Any]
  let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
  let value =
    png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
    ?? png?[kCGImagePropertyAPNGDelayTime] as? Double ?? 0
  return max(10, Int(((value > 0 ? value : 1.0 / 24) * 1000).rounded()))
}

func context(_ width: Int, _ height: Int) -> CGContext {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.interpolationQuality = .high
  return context
}

func encode(_ image: CGImage) -> Data? {
  let data = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
  else { return nil }
  CGImageDestinationAddImage(destination, image, nil)
  return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// PNG 块的 CRC-32（ISO 3309，同 zlib 的 crc32）
let crcTable: [UInt32] = (0..<256).map { n in
  var c = UInt32(n)
  for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
  return c
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
  var c: UInt32 = 0xFFFF_FFFF
  for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
  return c ^ 0xFFFF_FFFF
}

func bigEndian(_ value: UInt32) -> [UInt8] {
  [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

/// 在 IEND 前面插一个 tEXt 块（关键字 \0 文字，都是 ASCII）
func withText(_ png: Data, _ text: String) -> Data? {
  let bytes = [UInt8](png)
  let iend: [UInt8] = [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
  guard bytes.count > 20, Array(bytes.suffix(12)) == iend else { return nil }
  let body = [UInt8]("tEXt".utf8) + [UInt8](keyword.utf8) + [0] + [UInt8](text.utf8)
  let chunk = bigEndian(UInt32(body.count - 4)) + body + bigEndian(crc32(body))
  return Data(bytes.dropLast(12) + chunk + iend)
}

struct Sheet {
  let png: Data
  let first: CGImage
  /// manifest 那一行去掉 id：格子边长、列数、帧数、每帧毫秒
  let meta: String
  let count: Int
  let columns: Int
}

/// 一个动画 PNG → 帧图集。不到两帧、读不出来是 nil（原因已经打出来）
func makeSheet(_ url: URL) -> Sheet? {
  guard let images = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(images) > 1
  else {
    print("缺 / 不是动画：\(url.lastPathComponent)")
    return nil
  }

  let all = CGImageSourceGetCount(images)
  let picked = Array(stride(from: 0, to: all, by: step))
  let count = picked.count
  let columns = Int(ceil(Double(count).squareRoot()))
  let rows = (count + columns - 1) / columns
  let atlas = context(columns * cell, rows * cell)
  var delays: [Int] = []
  var first: CGImage?
  for (index, sourceIndex) in picked.enumerated() {
    guard let frame = CGImageSourceCreateImageAtIndex(images, sourceIndex, nil) else {
      print("\(url.lastPathComponent) 第 \(sourceIndex) 帧读不出来")
      return nil
    }
    first = first ?? frame
    // CoreGraphics 原点在左下：第 0 行在最上面
    let row = index / columns
    let column = index % columns
    atlas.draw(
      frame,
      in: CGRect(x: column * cell, y: (rows - 1 - row) * cell, width: cell, height: cell))
    delays.append((sourceIndex..<min(sourceIndex + step, all)).reduce(0) { $0 + delay(images, $1) })
  }

  guard let image = atlas.makeImage(), let png = encode(image), let first else {
    print("编不出 \(url.lastPathComponent)")
    return nil
  }
  // 同 App 的 EmojiSheet.Decode：超了 App 不认，这里先拦（R107 审查）
  guard count >= 2, count <= maxFrames, columns <= maxColumns, rows <= maxColumns else {
    print("\(url.lastPathComponent) 有 \(count) 帧（\(columns) 列 × \(rows) 行），超过 App 收的 \(maxFrames) 帧 / \(maxColumns) 列")
    return nil
  }
  let meta = ["\(cell)", "\(columns)", "\(count)", delays.map(String.init).joined(separator: ",")]
    .joined(separator: "\t")
  return Sheet(png: png, first: first, meta: meta, count: count, columns: columns)
}

func size(_ url: URL) -> Int {
  (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

/// 自带的 28 个 + 眼睛
func bundled(_ source: URL) throws -> Bool {
  try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
  var manifest: [String] = []
  var failed = false
  var bytes = 0
  for item in emoji {
    guard let sheet = makeSheet(source.appendingPathComponent(item.file)) else {
      failed = true
      continue
    }

    let small = context(still, still)
    small.draw(sheet.first, in: CGRect(x: 0, y: 0, width: still, height: still))
    let sheetURL = resources.appendingPathComponent("\(item.id).png")
    let stillURL = resources.appendingPathComponent("\(item.id)-still.png")
    guard let stillImage = small.makeImage(), let stillPNG = encode(stillImage),
      (try? sheet.png.write(to: sheetURL)) != nil, (try? stillPNG.write(to: stillURL)) != nil
    else {
      print("写不了 \(item.id)")
      failed = true
      continue
    }

    bytes += size(sheetURL) + size(stillURL)
    manifest.append(item.id + "\t" + sheet.meta)
    print("\(item.id)：\(sheet.count) 帧，\(sheet.columns) 列")
  }

  try (manifest.joined(separator: "\n") + "\n").write(
    to: resources.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
  print("共 \(manifest.count) 个，\(bytes / 1024) KB → \(resources.path)")
  return !failed
}

/// 编号：文件名去掉 _animated_default / _animated、下划线换成连字符（同 mac emoji-pack.swift）
func packID(_ file: String) -> String? {
  var name = (file as NSString).deletingPathExtension
  for suffix in ["_animated_default", "_animated"] where name.hasSuffix(suffix) {
    name = String(name.dropLast(suffix.count))
    break
  }
  let id = name.lowercased().replacingOccurrences(of: "_", with: "-")
  let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
  return !id.isEmpty && id.count <= 64 && id.allSatisfy { allowed.contains($0) } ? id : nil
}

/// 动画表情包：源目录下所有 *_animated*.png
func pack(_ source: URL, _ output: URL, catalog: URL?) throws -> Bool {
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let files = (FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL } ?? [])
    .filter { $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.contains("_animated") }
    .sorted { $0.path < $1.path }
  var seen: [String: String] = [:]
  var failed = false
  var bytes = 0
  for file in files {
    guard let id = packID(file.lastPathComponent) else {
      print("编号不合规：\(file.lastPathComponent)")
      failed = true
      continue
    }
    if let other = seen[id] {
      print("编号撞了：\(id)（\(other) 和 \(file.lastPathComponent)）")
      failed = true
      continue
    }
    seen[id] = file.lastPathComponent
    guard let sheet = makeSheet(file), let tagged = withText(sheet.png, sheet.meta) else {
      failed = true
      continue
    }
    if tagged.count > maxPackBytes {
      print("\(id) 有 \(tagged.count / 1024) KB，超过 App 收的 \(maxPackBytes / 1024) KB")
      failed = true
    }
    let target = output.appendingPathComponent("\(id).png")
    guard (try? tagged.write(to: target)) != nil else {
      print("写不了 \(id)")
      failed = true
      continue
    }
    bytes += tagged.count
  }

  let license = resources.appendingPathComponent("LICENSE.txt")
  let licenseCopy = output.appendingPathComponent("LICENSE.txt")
  try? FileManager.default.removeItem(at: licenseCopy)
  try FileManager.default.copyItem(at: license, to: licenseCopy)

  if let catalog {
    let data = try Data(contentsOf: catalog)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let ids = ((root?["emoji"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    let missing = ids.filter { seen[$0] == nil }
    let extra = seen.keys.filter { !ids.contains($0) }.sorted()
    if !missing.isEmpty {
      print("对照表里有、没生成的 \(missing.count) 个：\(missing.prefix(20).joined(separator: " "))")
      failed = true
    }
    if !extra.isEmpty {
      print("生成了、对照表里没有的 \(extra.count) 个（App 不会去下）：\(extra.prefix(20).joined(separator: " "))")
    }
  }

  print("共 \(seen.count) 个，\(bytes / 1024) KB → \(output.path)")
  return !failed
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--pack" {
  arguments.removeFirst()
  var catalog: URL?
  if let flag = arguments.firstIndex(of: "--catalog"), arguments.indices.contains(flag + 1) {
    catalog = URL(fileURLWithPath: arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
  }
  guard arguments.count == 2 else {
    print("用法：swift windows/tools/status-emoji.swift --pack <源目录> <输出目录> [--catalog <emoji-pack.json>]")
    exit(1)
  }
  let ok = try pack(
    URL(fileURLWithPath: arguments[0]), URL(fileURLWithPath: arguments[1]), catalog: catalog)
  exit(ok ? 0 : 1)
}

guard arguments.count == 1 else {
  print("用法：swift windows/tools/status-emoji.swift <放着下载好的 *_animated*.png 的目录>")
  print("　　　swift windows/tools/status-emoji.swift --pack <源目录> <输出目录> [--catalog <emoji-pack.json>]")
  exit(1)
}
exit(try bundled(URL(fileURLWithPath: arguments[0])) ? 0 : 1)
