// 功能图标的生成脚本（2026-10-30 拍板 D1）：icons/feature/kitty.*.svg 是 mac 和 Windows 共用的唯一来源，
// 这里把每个图标里的填充、线条和虚线都描成面、合成一条路径，再出两边要的格式：
//   mac      → macos/KittyTools/Resources/Assets.xcassets/FeatureIcons/<名字>.symbolset（自定义符号模板，只放 Regular-M）
//   windows  → windows/KittyTools/Shell/FeatureIcons.cs（24 格坐标的路径数据）
// 用法（仓库根目录）：swift icons/build-icons.swift mac | windows | mac windows
// （main 上的 windows/ 是旧快照，只在 windows-wip 上出 windows 那份）
// 只用 Foundation + CoreGraphics（路径的并集要 macOS 13）。自检：每个图标合成后的路径和逐个元素直接画的样子逐像素比，
// 再比非零 / 奇偶两种填充规则，差太多就报错退出。
// SVG 只认这套图标用到的：path（M L H V C Q A Z，大小写都认）、rect、circle、g；fill / stroke / stroke-width /
// stroke-linecap / stroke-linejoin / stroke-dasharray / fill-rule，写在 g 上也继承；transform 只认 rotate(a [cx cy])。

import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("build-icons: \(message)\n".utf8))
  exit(1)
}

/// 一个元素怎么画（从外层 g 继承下来）
struct Paint {
  var fill = true  // SVG 默认填黑
  var stroke = false
  var width: CGFloat = 1
  var cap = CGLineCap.butt
  var join = CGLineJoin.miter
  var dash: [CGFloat] = []
  var evenOdd = false
  var transform = CGAffineTransform.identity
}

struct Piece {
  let path: CGPath
  let paint: Paint
}

// MARK: 读 SVG

final class Reader: NSObject, XMLParserDelegate {
  private var stack = [Paint()]
  private var inTitle = false
  private(set) var pieces: [Piece] = []
  private(set) var title = ""

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes a: [String: String]
  ) {
    var paint = stack.last!
    apply(a, to: &paint)
    stack.append(paint)
    switch name {
    case "svg", "g": break
    case "title": inTitle = true
    case "path": add(SVGPath.parse(a["d"] ?? ""), paint)
    case "rect":
      let rect = CGRect(
        x: number(a["x"]), y: number(a["y"]), width: number(a["width"]),
        height: number(a["height"]))
      let radius = min(number(a["rx"] ?? a["ry"]), rect.width / 2, rect.height / 2)
      add(
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil), paint)
    case "circle":
      let r = number(a["r"])
      add(
        CGPath(
          ellipseIn: CGRect(x: number(a["cx"]) - r, y: number(a["cy"]) - r, width: r * 2, height: r * 2),
          transform: nil), paint)
    default: fail("不认识的元素 <\(name)>")
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    stack.removeLast()
    if name == "title" { inTitle = false }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if inTitle { title += string }
  }

  private func add(_ path: CGPath, _ paint: Paint) {
    var transform = paint.transform
    pieces.append(Piece(path: path.copy(using: &transform) ?? path, paint: paint))
  }

  private func apply(_ a: [String: String], to paint: inout Paint) {
    if let v = a["fill"] { paint.fill = v != "none" }
    if let v = a["stroke"] { paint.stroke = v != "none" }
    if let v = a["stroke-width"] { paint.width = number(v) }
    if let v = a["stroke-linecap"] { paint.cap = ["round": .round, "square": .square][v] ?? .butt }
    if let v = a["stroke-linejoin"] { paint.join = ["round": .round, "bevel": .bevel][v] ?? .miter }
    if let v = a["stroke-dasharray"] { paint.dash = numbers(v) }
    if let v = a["fill-rule"] { paint.evenOdd = v == "evenodd" }
    if let v = a["transform"] { paint.transform = rotation(v).concatenating(paint.transform) }
  }

  private func rotation(_ text: String) -> CGAffineTransform {
    guard text.hasPrefix("rotate(") else { fail("transform 只认 rotate：\(text)") }
    let v = numbers(String(text.dropFirst("rotate(".count).dropLast()))
    let (cx, cy) = v.count == 3 ? (v[1], v[2]) : (0, 0)
    return CGAffineTransform(translationX: -cx, y: -cy)
      .concatenating(CGAffineTransform(rotationAngle: v[0] * .pi / 180))
      .concatenating(CGAffineTransform(translationX: cx, y: cy))
  }
}

func number(_ text: String?) -> CGFloat { CGFloat(Double(text ?? "0") ?? 0) }

func numbers(_ text: String) -> [CGFloat] {
  text.split(whereSeparator: { $0 == " " || $0 == "," }).map { number(String($0)) }
}

/// SVG 的路径语法 → CGPath（弧线换成三次贝塞尔）
enum SVGPath {
  enum Token { case command(Character), value(CGFloat) }

  static func tokens(_ d: String) -> [Token] {
    var out: [Token] = []
    var chars = Array(d)[...]
    while let c = chars.first {
      if "MmLlHhVvCcQqAaZz".contains(c) {
        out.append(.command(c))
        chars = chars.dropFirst()
      } else if c == "-" || c == "+" || c == "." || c.isNumber {
        var text = String(c)
        chars = chars.dropFirst()
        var seenDot = c == "."
        while let n = chars.first {
          if n.isNumber {
            text.append(n)
          } else if n == ".", !seenDot {
            seenDot = true
            text.append(n)
          } else if n == "e" || n == "E" {
            text.append(n)
            chars = chars.dropFirst()
            if let sign = chars.first, sign == "-" || sign == "+" { text.append(sign) } else { continue }
          } else {
            break
          }
          chars = chars.dropFirst()
        }
        guard let value = Double(text) else { fail("读不懂的数：\(text)") }
        out.append(.value(CGFloat(value)))
      } else if c == " " || c == "," || c == "\n" || c == "\t" {
        chars = chars.dropFirst()
      } else {
        fail("路径里不认识的字符：\(c)")
      }
    }
    return out
  }

  static func parse(_ d: String) -> CGPath {
    let tokens = tokens(d)
    let path = CGMutablePath()
    var index = 0
    var command: Character = " "
    var current = CGPoint.zero
    var start = CGPoint.zero

    func value() -> CGFloat {
      guard index < tokens.count, case .value(let v) = tokens[index] else { fail("路径少了数：\(d)") }
      index += 1
      return v
    }

    while index < tokens.count {
      if case .command(let c) = tokens[index] {
        command = c
        index += 1
      } else if command == "Z" || command == "z" || command == " " {
        fail("路径里多出来的数：\(d)")
      }
      let relative = command.isLowercase
      func point() -> CGPoint {
        let x = value()
        let y = value()
        return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
      }
      switch command.uppercased() {
      case "M":
        current = point()
        start = current
        path.move(to: current)
        command = relative ? "l" : "L"  // 后面跟着的数当直线
      case "L":
        current = point()
        path.addLine(to: current)
      case "H":
        let x = value()
        current.x = relative ? current.x + x : x
        path.addLine(to: current)
      case "V":
        let y = value()
        current.y = relative ? current.y + y : y
        path.addLine(to: current)
      case "C":
        let c1 = point()
        let c2 = point()
        let end = point()
        path.addCurve(to: end, control1: c1, control2: c2)
        current = end
      case "Q":
        let control = point()
        let end = point()
        path.addQuadCurve(to: end, control: control)
        current = end
      case "A":
        let rx = value()
        let ry = value()
        let degrees = value()
        let large = value() != 0
        let sweep = value() != 0
        let end = point()
        arc(path, from: current, to: end, rx: rx, ry: ry, degrees: degrees, large: large, sweep: sweep)
        current = end
      case "Z":
        path.closeSubpath()
        current = start
      default:
        fail("不认识的路径命令 \(command)")
      }
    }
    return path
  }

  /// SVG 规范 F.6.5 的端点式 → 圆心式，按每段不超过 90° 切成三次贝塞尔
  static func arc(
    _ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
    degrees: CGFloat, large: Bool, sweep: Bool
  ) {
    var rx = abs(rx)
    var ry = abs(ry)
    guard rx > 0, ry > 0, p0 != p1 else { return path.addLine(to: p1) }
    let phi = degrees * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2
    let dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if lambda > 1 {
      rx *= sqrt(lambda)
      ry *= sqrt(lambda)
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var coefficient = sqrt(max(0, numerator / denominator))
    if large == sweep { coefficient = -coefficient }
    let cx1 = coefficient * rx * y1 / ry
    let cy1 = -coefficient * ry * x1 / rx
    let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
    let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
    let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
    let step = delta / CGFloat(segments)
    let k = 4 / 3 * tan(step / 4)
    func on(_ t: CGFloat) -> CGPoint {
      CGPoint(
        x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
        y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
    }
    func tangent(_ t: CGFloat) -> CGPoint {
      CGPoint(
        x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
        y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
    }
    var t = theta
    for segment in 0..<segments {
      let next = t + step
      let a = on(t)
      let b = segment == segments - 1 ? p1 : on(next)
      let da = tangent(t)
      let db = tangent(next)
      path.addCurve(
        to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
        control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
      t = next
    }
  }
}

// MARK: 合成和自检

/// 一块描成面：填充按它的规则规整，线条（含虚线）描边
func outlines(_ piece: Piece) -> [CGPath] {
  var out: [CGPath] = []
  let paint = piece.paint
  if paint.fill { out.append(piece.path.normalized(using: paint.evenOdd ? .evenOdd : .winding)) }
  if paint.stroke {
    let line =
      paint.dash.isEmpty ? piece.path : piece.path.copy(dashingWithPhase: 0, lengths: paint.dash)
    out.append(
      line.copy(
        strokingWithWidth: paint.width, lineCap: paint.cap, lineJoin: paint.join, miterLimit: 4
      ).normalized())
  }
  return out
}

func merge(_ pieces: [Piece]) -> CGPath {
  let shapes = pieces.flatMap(outlines)
  guard var merged = shapes.first else { fail("空图标") }
  for shape in shapes.dropFirst() { merged = merged.union(shape) }
  return merged
}

/// 画成 240 × 240 的黑白图（不抗锯齿），返回每个像素有没有墨
func coverage(_ draw: (CGContext) -> Void) -> [Bool] {
  let side = 240
  let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  context.setFillColor(gray: 1, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: side, height: side))
  context.setShouldAntialias(false)
  context.scaleBy(x: 10, y: 10)
  context.setFillColor(gray: 0, alpha: 1)
  context.setStrokeColor(gray: 0, alpha: 1)
  draw(context)
  let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
  return (0..<side * side).map { pixels[$0] < 128 }
}

/// 两张图差了几成（按两张里有墨的像素算）
func mismatch(_ a: [Bool], _ b: [Bool]) -> Double {
  let differ = zip(a, b).filter { $0 != $1 }.count
  let ink = zip(a, b).filter { $0 || $1 }.count
  return ink == 0 ? 1 : Double(differ) / Double(ink)
}

func check(_ name: String, _ pieces: [Piece], _ merged: CGPath) {
  let reference = coverage { context in
    for piece in pieces {
      let paint = piece.paint
      if paint.fill {
        context.addPath(piece.path)
        context.fillPath(using: paint.evenOdd ? .evenOdd : .winding)
      }
      if paint.stroke {
        context.setLineWidth(paint.width)
        context.setLineCap(paint.cap)
        context.setLineJoin(paint.join)
        context.setMiterLimit(4)
        context.setLineDash(phase: 0, lengths: paint.dash)
        context.addPath(piece.path)
        context.strokePath()
      }
    }
  }
  let winding = coverage { $0.addPath(merged); $0.fillPath(using: .winding) }
  let evenOdd = coverage { $0.addPath(merged); $0.fillPath(using: .evenOdd) }
  let drift = mismatch(reference, winding)
  let rules = mismatch(winding, evenOdd)
  guard drift < 0.02, rules < 0.002 else {
    fail("\(name) 合成后不对：和直接画的差 \(drift)，两种填充规则差 \(rules)")
  }
}

// MARK: 输出

func format(_ value: CGFloat) -> String {
  var text = String(format: "%.3f", Double(value))
  while text.contains("."), text.hasSuffix("0") { text.removeLast() }
  if text.hasSuffix(".") { text.removeLast() }
  return text == "-0" ? "0" : text
}

/// 路径 → SVG / XAML 都认的路径数据（M L Q C Z），每个点先过 map
func pathData(_ path: CGPath, map: (CGPoint) -> CGPoint = { $0 }) -> String {
  var parts: [String] = []
  func p(_ point: CGPoint) -> String {
    let q = map(point)
    return "\(format(q.x)) \(format(q.y))"
  }
  path.applyWithBlock { element in
    let e = element.pointee
    switch e.type {
    case .moveToPoint: parts.append("M\(p(e.points[0]))")
    case .addLineToPoint: parts.append("L\(p(e.points[0]))")
    case .addQuadCurveToPoint: parts.append("Q\(p(e.points[0])) \(p(e.points[1]))")
    case .addCurveToPoint: parts.append("C\(p(e.points[0])) \(p(e.points[1])) \(p(e.points[2]))")
    case .closeSubpath: parts.append("Z")
    @unknown default: fail("不认识的路径元素")
    }
  }
  return parts.joined()
}

/// 自定义符号模板（Template v.3.0）：中号的基线在 1126、大写高 70.46；24 格放大 5 倍成 120 宽，
/// 格子中心对着大写高的中线（同 SF Symbols 的垂直居中）。左右边距就是格子两边，所有图标一样宽
func symbolTemplate(_ path: CGPath) -> String {
  let left = 1440.0
  let data = pathData(path) { CGPoint(x: $0.x * 5, y: $0.y * 5 - 95.23) }
  let guide = "style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\" x1=\"263\" x2=\"3036\""
  let margin = "style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" y1=\"1030.79\" y2=\"1150.12\""
  return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <!-- 生成的文件，别手改：源在仓库根的 icons/feature/，改完跑 swift icons/build-icons.swift mac -->
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <g id="Notes">
      <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
      <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
     </g>
     <g id="Guides">
      <line id="Baseline-S" \(guide) y1="696" y2="696"/>
      <line id="Capline-S" \(guide) y1="625.541" y2="625.541"/>
      <line id="Baseline-M" \(guide) y1="1126" y2="1126"/>
      <line id="Capline-M" \(guide) y1="1055.54" y2="1055.54"/>
      <line id="Baseline-L" \(guide) y1="1556" y2="1556"/>
      <line id="Capline-L" \(guide) y1="1485.54" y2="1485.54"/>
      <line id="left-margin-Regular-M" \(margin) x1="\(format(left))" x2="\(format(left))"/>
      <line id="right-margin-Regular-M" \(margin) x1="\(format(left + 120))" x2="\(format(left + 120))"/>
     </g>
     <g id="Symbols">
      <g id="Regular-M" transform="matrix(1 0 0 1 \(format(left)) 1126)">
       <path d="\(data)"/>
      </g>
     </g>
    </svg>

    """
}

let contentsInfo = "\"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }"

func writeMac(_ icons: [(name: String, title: String, path: CGPath)]) throws {
  let folder = URL(fileURLWithPath: "macos/KittyTools/Resources/Assets.xcassets/FeatureIcons")
  // 整个重出：改名、删掉的不留旧的
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try "{\n  \(contentsInfo)\n}\n".write(
    to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
  for icon in icons {
    let set = folder.appending(path: "\(icon.name).symbolset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try symbolTemplate(icon.path).write(
      to: set.appending(path: "\(icon.name).svg"), atomically: true, encoding: .utf8)
    let contents = """
      {
        \(contentsInfo),
        "symbols" : [
          {
            "filename" : "\(icon.name).svg",
            "idiom" : "universal"
          }
        ]
      }

      """
    try contents.write(to: set.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
  }
  print("mac: \(icons.count) 个 → \(folder.path)")
}

/// kitty.translate.selection → TranslateSelection
func constantName(_ name: String) -> String {
  name.dropFirst("kitty.".count).split(separator: ".").map { $0.prefix(1).uppercased() + $0.dropFirst() }
    .joined()
}

func writeWindows(_ icons: [(name: String, title: String, path: CGPath)]) throws {
  let file = URL(fileURLWithPath: "windows/KittyTools/Shell/FeatureIcons.cs")
  guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else {
    fail("没有 windows/KittyTools/Shell/（windows 那份在 windows-wip 上出）")
  }
  var lines = [
    "// 生成的文件，别手改：源在仓库根的 icons/feature/*.svg，改完在 Mac 上跑 swift icons/build-icons.swift windows。",
    "// 功能图标（2026-10-30 拍板）：mac 和 Windows 共用的那一套，24 × 24 格的路径数据（XAML 路径语法）。",
    "// 线条已经描成面、合成一条，非零和奇偶两种填充规则画出来一样。",
    "namespace KittyTools;",
    "",
    "internal static class FeatureIcons",
    "{",
  ]
  for (index, icon) in icons.enumerated() {
    if index > 0 { lines.append("") }
    lines.append("    /// <summary>\(icon.title)（\(icon.name)）。</summary>")
    lines.append("    public const string \(constantName(icon.name)) = \"F1 \(pathData(icon.path))\";")
  }
  lines.append("}")
  try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
  print("windows: \(icons.count) 个 → \(file.path)")
}

// MARK: 主流程

let targets = Set(CommandLine.arguments.dropFirst())
guard !targets.isEmpty, targets.isSubset(of: ["mac", "windows"]) else {
  fail("用法：swift icons/build-icons.swift mac | windows | mac windows（在仓库根目录跑）")
}
let source = URL(fileURLWithPath: "icons/feature")
guard
  let files = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    .filter({ $0.pathExtension == "svg" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
  !files.isEmpty
else { fail("找不到 icons/feature/*.svg（要在仓库根目录跑）") }

let icons = files.map { file -> (name: String, title: String, path: CGPath) in
  let name = file.deletingPathExtension().lastPathComponent
  guard name.hasPrefix("kitty.") else { fail("\(name)：文件名要以 kitty. 开头") }
  let reader = Reader()
  let parser = XMLParser(contentsOf: file)!
  parser.delegate = reader
  guard parser.parse() else { fail("\(name)：SVG 读不了 \(parser.parserError.map { "\($0)" } ?? "")") }
  let merged = merge(reader.pieces)
  check(name, reader.pieces, merged)
  return (name, reader.title.trimmingCharacters(in: .whitespacesAndNewlines), merged)
}
if targets.contains("mac") { try writeMac(icons) }
if targets.contains("windows") { try writeWindows(icons) }
