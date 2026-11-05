// 在 Mac 上生成 Windows 版状态屏的动画表情（PLAN-v12 N5）：swift windows/tools/status-emoji.swift <源目录>
// 素材同 mac 版（macos/status-emoji.swift）：Microsoft Fluent Emoji Animated 的动画 PNG（MIT，https://github.com/microsoft/fluentui-emoji-animated），
// 原文件每个 0.8–2.8 MB、256 × 256、37–73 帧、每帧 1/24 s，不进仓库（本机在 kitty-tools-macos/macos/build/status-emoji/src/）。
// WinUI 放 GIF 只有一位透明，边缘难看；这里每个表情出三样，写进 windows/KittyTools/Resources/StatusEmoji/：
//   <id>.png        帧图集：隔一帧取一帧（12 fps，每帧时长是两帧之和），每帧缩到 cell × cell，按行排（列数 = ceil(√帧数)），
//                   透明通道照留。160 像素、12 fps 共约 9.5 MB；原样 24 fps 要 18 MB、192 像素 25 MB（mac 的 HEICS 共 6 MB，
//                   Windows 不一定装了 HEIF 解码器）。要更顺滑就把 step 改成 1 再跑。
//                   App 里用合成层的表面画刷 + 一段离散的关键帧动画挪偏移来播（StatusEmoji.cs），不占 UI 线程。
//   <id>-still.png  静止画面（第一帧，Still × Still）：设置列表、图标格子、启动器、选状态的卡片这些小地方用。
//   manifest.txt    一个表情一行，制表符隔开：id  格子边长  列数  帧数  每帧毫秒（逗号隔开）。
// 要加表情：两边的清单（这里的 emoji 表、mac 的 status-emoji.swift、App 里的 StatusEmoji.cs）各加一行再跑。
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

/// App 里的 id → 仓库里的文件名（顺序同 mac 的 StatusEmoji.ids，眼睛在最后）
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

guard CommandLine.arguments.count == 2 else {
  print("用法：swift windows/tools/status-emoji.swift <放着下载好的 *_animated*.png 的目录>")
  exit(1)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("../KittyTools/Resources/StatusEmoji").standardizedFileURL
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

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

func write(_ image: CGImage, to url: URL) -> Bool {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { return false }
  CGImageDestinationAddImage(destination, image, nil)
  return CGImageDestinationFinalize(destination)
}

var manifest: [String] = []
var failed = false
var bytes = 0
for item in emoji {
  let url = source.appendingPathComponent(item.file)
  guard let images = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(images) > 1
  else {
    print("缺 \(item.file)")
    failed = true
    continue
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
      print("\(item.file) 第 \(sourceIndex) 帧读不出来")
      failed = true
      break
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

  guard let sheet = atlas.makeImage(), let first else { continue }
  let small = context(still, still)
  small.draw(first, in: CGRect(x: 0, y: 0, width: still, height: still))
  let sheetURL = output.appendingPathComponent("\(item.id).png")
  let stillURL = output.appendingPathComponent("\(item.id)-still.png")
  guard write(sheet, to: sheetURL), let stillImage = small.makeImage(), write(stillImage, to: stillURL)
  else {
    print("写不了 \(item.id)")
    failed = true
    continue
  }

  for written in [sheetURL, stillURL] {
    bytes += (try? FileManager.default.attributesOfItem(atPath: written.path)[.size] as? Int) ?? 0
  }
  manifest.append(
    [item.id, "\(cell)", "\(columns)", "\(count)", delays.map(String.init).joined(separator: ",")]
      .joined(separator: "\t"))
  print("\(item.id)：\(count) 帧，\(columns) 列")
}

try (manifest.joined(separator: "\n") + "\n").write(
  to: output.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
print("共 \(manifest.count) 个，\(bytes / 1024) KB → \(output.path)")
exit(failed ? 1 : 0)
