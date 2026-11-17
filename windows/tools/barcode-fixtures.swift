// 在 Mac 上生成 Windows 版「识字认二维码 / 条码」的单测图：swift windows/tools/barcode-fixtures.swift（REVIEW R105）
// 写进 windows/KittyTools.Tests/Fixtures/barcodes/：一张张 8 位灰度 / RGB 的 PNG，和清单 manifest.json
// （[{"file": "...", "codes": ["...", ...]}]，codes 是图里每个码的内容，没码的图是空数组）。
// 二维码大部分用 CoreImage 的 CIQRCodeGenerator 生成（各种版本 1–40、四个纠错等级）；数字 / 字母数字 / 汉字模式、ECI、
// 混合几段、指定掩码这些 CoreImage 管不了，用下面一个照 ISO/IEC 18004 写的小编码器生成。Code 128 用 CICode128BarcodeGenerator，
// EAN-13 / EAN-8 / UPC-A / UPC-E / Code 39 / ITF 照规范自己画条。然后转一转、透视、缩放、加噪声、模糊、深色底、一图多码，
// 再加几张没码的图（文字、噪点、格子）。
// 生成完每张都用 Vision（VNDetectBarcodesRequest，mac 版识字认码用的就是它）读一遍，和清单对不上的打出来（Vision 读不出的
// 也打出来：说明这张对 mac 也难，Windows 读不出时先看这里）。随机数固定种子，再跑一遍图一字不差。
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let outputDirectory: URL = {
  if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1]) }
  let script = URL(fileURLWithPath: #filePath)
  return script.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("KittyTools.Tests/Fixtures/barcodes")
}()

// MARK: 固定种子的随机数（SplitMix64）

var seed: UInt64 = 0x4B49_5454_5931_3035
func random() -> UInt64 {
  seed &+= 0x9E37_79B9_7F4A_7C15
  var z = seed
  z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
  z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
  return z ^ (z >> 31)
}
func random(_ n: Int) -> Int { Int(random() % UInt64(n)) }
func letters(_ count: Int) -> String {
  String((0..<count).map { _ in Character(Unicode.Scalar(UInt8(97 + random(26)))) })
}

// MARK: 小二维码编码器（ISO/IEC 18004；只在这里生成测试图用）

enum QrEncoder {
  enum Segment {
    case numeric(String)
    case alphanumeric(String)
    case bytes([UInt8])
    case kanji(String)
    case eci(Int)
  }

  static let eccPerBlock: [[Int]] = [
    [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  ]
  static let blocks: [[Int]] = [
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
  ]
  static let levelBits = [1, 0, 3, 2]  // L M Q H

  static func rawModules(_ v: Int) -> Int {
    var result = (16 * v + 128) * v + 64
    if v >= 2 {
      let n = v / 7 + 2
      result -= (25 * n - 10) * n - 55
      if v >= 7 { result -= 36 }
    }
    return result
  }
  static func dataCodewords(_ v: Int, _ level: Int) -> Int {
    rawModules(v) / 8 - eccPerBlock[level][v] * blocks[level][v]
  }
  static func alignment(_ v: Int) -> [Int] {
    if v == 1 { return [] }
    let n = v / 7 + 2
    let step = (v * 8 + n * 3 + 5) / (n * 4 - 4) * 2
    var result = [6]
    var p = v * 4 + 10
    var tail: [Int] = []
    for _ in 1..<n {
      tail.insert(p, at: 0)
      p -= step
    }
    result += tail
    return result
  }

  static let alphanumericSet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

  static func bits(_ segments: [Segment], _ v: Int) -> [Bool] {
    var out: [Bool] = []
    func put(_ value: Int, _ count: Int) {
      for i in stride(from: count - 1, through: 0, by: -1) { out.append((value >> i) & 1 == 1) }
    }
    let size = v <= 9 ? 0 : v <= 26 ? 1 : 2
    for segment in segments {
      switch segment {
      case .eci(let value):
        put(7, 4)
        if value < 128 {
          put(value, 8)
        } else if value < 16384 {
          put(0b10, 2)
          put(value, 14)
        } else {
          put(0b110, 3)
          put(value, 21)
        }
      case .numeric(let digits):
        put(1, 4)
        put(digits.count, [10, 12, 14][size])
        let d = Array(digits).map { Int(String($0))! }
        var i = 0
        while i < d.count {
          let n = min(3, d.count - i)
          var value = 0
          for j in 0..<n { value = value * 10 + d[i + j] }
          put(value, [4, 7, 10][n - 1])
          i += n
        }
      case .alphanumeric(let text):
        put(2, 4)
        let c = Array(text).map { alphanumericSet.firstIndex(of: $0)! }
        put(c.count, [9, 11, 13][size])
        var i = 0
        while i + 1 < c.count {
          put(c[i] * 45 + c[i + 1], 11)
          i += 2
        }
        if i < c.count { put(c[i], 6) }
      case .bytes(let data):
        put(4, 4)
        put(data.count, size == 0 ? 8 : 16)
        for b in data { put(Int(b), 8) }
      case .kanji(let text):
        put(8, 4)
        let sjis = [UInt8](text.data(using: .shiftJIS)!)
        put(sjis.count / 2, [8, 10, 12][size])
        var i = 0
        while i < sjis.count {
          let c = Int(sjis[i]) << 8 | Int(sjis[i + 1])
          let s = c - (c <= 0x9FFC ? 0x8140 : 0xC140)
          put((s >> 8) * 0xC0 + (s & 0xFF), 13)
          i += 2
        }
      }
    }
    return out
  }

  static func gfMul(_ a: Int, _ b: Int) -> Int {
    var x = a
    var y = b
    var z = 0
    while y > 0 {
      if y & 1 == 1 { z ^= x }
      x <<= 1
      if x & 0x100 != 0 { x ^= 0x11D }
      y >>= 1
    }
    return z
  }

  static func ecc(_ data: [Int], _ degree: Int) -> [Int] {
    var g = [1]
    var root = 1
    for _ in 0..<degree {
      var next = [Int](repeating: 0, count: g.count + 1)
      for j in 0..<g.count {
        next[j] ^= g[j]
        next[j + 1] ^= gfMul(g[j], root)
      }
      g = next
      root = gfMul(root, 2)
    }
    var rem = [Int](repeating: 0, count: degree)
    for b in data {
      let factor = b ^ rem[0]
      rem.removeFirst()
      rem.append(0)
      for j in 0..<degree { rem[j] ^= gfMul(g[j + 1], factor) }
    }
    return rem
  }

  /// 返回 [行][列] 的模块（true = 深色）
  static func encode(_ segments: [Segment], level: Int, mask: Int, minVersion: Int = 1) -> [[Bool]] {
    var v = minVersion
    while bits(segments, v).count > dataCodewords(v, level) * 8 { v += 1 }
    var stream = bits(segments, v)
    let capacity = dataCodewords(v, level) * 8
    stream += [Bool](repeating: false, count: min(4, capacity - stream.count))
    while stream.count % 8 != 0 { stream.append(false) }
    var data: [Int] = []
    for i in stride(from: 0, to: stream.count, by: 8) {
      var b = 0
      for j in 0..<8 { b = b << 1 | (stream[i + j] ? 1 : 0) }
      data.append(b)
    }
    var pad = 0xEC
    while data.count < capacity / 8 {
      data.append(pad)
      pad = pad == 0xEC ? 0x11 : 0xEC
    }
    // 分块、纠错码、交织
    let n = blocks[level][v]
    let e = eccPerBlock[level][v]
    let raw = rawModules(v) / 8
    let short = n - raw % n
    let shortLength = raw / n
    var dataBlocks: [[Int]] = []
    var eccBlocks: [[Int]] = []
    var k = 0
    for i in 0..<n {
      let length = shortLength - e + (i < short ? 0 : 1)
      let block = Array(data[k..<(k + length)])
      k += length
      dataBlocks.append(block)
      eccBlocks.append(ecc(block, e))
    }
    var codewords: [Int] = []
    for i in 0...(shortLength - e) {
      for b in 0..<n where i < dataBlocks[b].count { codewords.append(dataBlocks[b][i]) }
    }
    for i in 0..<e {
      for b in 0..<n { codewords.append(eccBlocks[b][i]) }
    }
    // 画功能图形
    let size = 17 + 4 * v
    var m = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
    var function = m
    func set(_ x: Int, _ y: Int, _ dark: Bool) {
      m[y][x] = dark
      function[y][x] = true
    }
    for (fx, fy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
      for dy in -4...4 {
        for dx in -4...4 {
          let x = fx + dx
          let y = fy + dy
          if x < 0 || y < 0 || x >= size || y >= size { continue }
          let d = max(abs(dx), abs(dy))
          set(x, y, d != 2 && d != 4)
        }
      }
    }
    for i in 0..<size {
      if !function[6][i] { set(i, 6, i % 2 == 0) }
      if !function[i][6] { set(6, i, i % 2 == 0) }
    }
    let positions = alignment(v)
    for (i, ax) in positions.enumerated() {
      for (j, ay) in positions.enumerated() {
        if (i == 0 && j == 0) || (i == 0 && j == positions.count - 1) || (i == positions.count - 1 && j == 0) { continue }
        for dy in -2...2 {
          for dx in -2...2 { set(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1) }
        }
      }
    }
    // 先占住格式信息、版本信息、暗模块的位置
    for i in 0..<9 where i != 6 {
      set(8, i, false)
      set(i, 8, false)
    }
    for i in 0..<8 {
      set(size - 1 - i, 8, false)
      set(8, size - 1 - i, false)
    }
    set(8, size - 8, true)
    var versionBits = 0
    if v >= 7 {
      var rem = v
      for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
      versionBits = v << 12 | rem
      for i in 0..<18 {
        let bit = (versionBits >> i) & 1 == 1
        set(size - 11 + i % 3, i / 3, bit)
        set(i / 3, size - 11 + i % 3, bit)
      }
    }
    // 放数据
    var bitIndex = 0
    var right = size - 1
    while right >= 1 {
      if right == 6 { right = 5 }
      for vert in 0..<size {
        for j in 0..<2 {
          let x = right - j
          let upward = ((right + 1) & 2) == 0
          let y = upward ? size - 1 - vert : vert
          if function[y][x] { continue }
          if bitIndex < codewords.count * 8 {
            m[y][x] = (codewords[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1 == 1
          }
          bitIndex += 1
        }
      }
      right -= 2
    }
    for y in 0..<size {
      for x in 0..<size where !function[y][x] {
        let flip: Bool
        switch mask {
        case 0: flip = (x + y) % 2 == 0
        case 1: flip = y % 2 == 0
        case 2: flip = x % 3 == 0
        case 3: flip = (x + y) % 3 == 0
        case 4: flip = (x / 3 + y / 2) % 2 == 0
        case 5: flip = x * y % 2 + x * y % 3 == 0
        case 6: flip = (x * y % 2 + x * y % 3) % 2 == 0
        default: flip = ((x + y) % 2 + x * y % 3) % 2 == 0
        }
        if flip { m[y][x].toggle() }
      }
    }
    // 格式信息
    let formatData = levelBits[level] << 3 | mask
    var rem = formatData
    for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
    let format = (formatData << 10 | rem) ^ 0x5412
    func bit(_ i: Int) -> Bool { (format >> i) & 1 == 1 }
    for i in 0...5 { m[i][8] = bit(i) }
    m[7][8] = bit(6)
    m[8][8] = bit(7)
    m[8][7] = bit(8)
    for i in 9..<15 { m[8][14 - i] = bit(i) }
    for i in 0..<8 { m[8][size - 1 - i] = bit(i) }
    for i in 8..<15 { m[size - 15 + i][8] = bit(i) }
    m[size - 8][8] = true
    return m
  }
}

// MARK: CoreImage 生成的码 → 模块

let ciContext = CIContext(options: [.useSoftwareRenderer: true])

func grayPixels(_ image: CIImage) -> (pixels: [UInt8], width: Int, height: Int) {
  let extent = image.extent.integral
  let width = Int(extent.width)
  let height = Int(extent.height)
  var pixels = [UInt8](repeating: 0, count: width * height)
  let space = CGColorSpaceCreateDeviceGray()
  let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: space,
    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  let cg = ciContext.createCGImage(image, from: extent)!
  context.interpolationQuality = .none
  context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
  return (pixels, width, height)
}

/// CIQRCodeGenerator 的输出（一个模块一个像素，带一圈留白）→ 去掉留白的模块矩阵
func coreImageQR(_ text: String, level: String) -> [[Bool]] {
  let filter = CIFilter.qrCodeGenerator()
  filter.message = text.data(using: .utf8)!
  filter.correctionLevel = level
  let (pixels, width, height) = grayPixels(filter.outputImage!)
  var minX = width
  var minY = height
  var maxX = 0
  var maxY = 0
  for y in 0..<height {
    for x in 0..<width where pixels[y * width + x] < 128 {
      minX = min(minX, x)
      maxX = max(maxX, x)
      minY = min(minY, y)
      maxY = max(maxY, y)
    }
  }
  return (minY...maxY).map { y in (minX...maxX).map { x in pixels[y * width + x] < 128 } }
}

func coreImageCode128(_ text: String) -> [Bool] {
  let filter = CIFilter.code128BarcodeGenerator()
  filter.message = text.data(using: .ascii)!
  filter.quietSpace = 0
  filter.barcodeHeight = 4
  let (pixels, width, height) = grayPixels(filter.outputImage!)
  let row = height / 2
  return (0..<width).map { pixels[row * width + $0] < 128 }
}

// MARK: 一维码照规范画条（true = 条）

func widths(_ pattern: [Int], startDark: Bool) -> [Bool] {
  var out: [Bool] = []
  var dark = startDark
  for w in pattern {
    out += [Bool](repeating: dark, count: w)
    dark.toggle()
  }
  return out
}

let eanL: [[Int]] = [[3, 2, 1, 1], [2, 2, 2, 1], [2, 1, 2, 2], [1, 4, 1, 1], [1, 1, 3, 2], [1, 2, 3, 1], [1, 1, 1, 4], [1, 3, 1, 2], [1, 2, 1, 3], [3, 1, 1, 2]]
let eanParity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
let upceParity = ["GGGLLL", "GGLGLL", "GGLLGL", "GGLLLG", "GLGGLL", "GLLGGL", "GLLLGG", "GLGLGL", "GLGLLG", "GLLGLG"]

func checkDigit(_ digits: [Int]) -> Int {
  var total = 0
  for (i, d) in digits.reversed().enumerated() { total += i % 2 == 0 ? d * 3 : d }
  return (10 - total % 10) % 10
}
func digitsOf(_ s: String) -> [Int] { s.map { Int(String($0))! } }

func ean13(_ twelve: String) -> (String, [Bool]) {
  var d = digitsOf(twelve)
  d.append(checkDigit(d))
  var bars = widths([1, 1, 1], startDark: true)
  let parity = Array(eanParity[d[0]])
  for i in 1...6 {
    let p = eanL[d[i]]
    bars += widths(parity[i - 1] == "L" ? p : p.reversed(), startDark: false)
  }
  bars += widths([1, 1, 1, 1, 1], startDark: false)
  for i in 7...12 { bars += widths(eanL[d[i]], startDark: true) }
  bars += widths([1, 1, 1], startDark: true)
  return (d.map(String.init).joined(), bars)
}

func ean8(_ seven: String) -> (String, [Bool]) {
  var d = digitsOf(seven)
  d.append(checkDigit(d))
  var bars = widths([1, 1, 1], startDark: true)
  for i in 0..<4 { bars += widths(eanL[d[i]], startDark: false) }
  bars += widths([1, 1, 1, 1, 1], startDark: false)
  for i in 4..<8 { bars += widths(eanL[d[i]], startDark: true) }
  bars += widths([1, 1, 1], startDark: true)
  return (d.map(String.init).joined(), bars)
}

/// six: 号码系统 0 的 UPC-E 六位；返回八位（0 + 六位 + 校验位）
func upce(_ six: String) -> (String, [Bool]) {
  let d = digitsOf(six)
  let expanded: [Int]
  switch d[5] {
  case 0, 1, 2: expanded = [d[0], d[1], d[5], 0, 0, 0, 0, d[2], d[3], d[4]]
  case 3: expanded = [d[0], d[1], d[2], 0, 0, 0, 0, 0, d[3], d[4]]
  case 4: expanded = [d[0], d[1], d[2], d[3], 0, 0, 0, 0, 0, d[4]]
  default: expanded = [d[0], d[1], d[2], d[3], d[4], 0, 0, 0, 0, d[5]]
  }
  let check = checkDigit([0] + expanded)
  let parity = Array(upceParity[check])
  var bars = widths([1, 1, 1], startDark: true)
  for i in 0..<6 {
    let p = eanL[d[i]]
    bars += widths(parity[i] == "L" ? p : p.reversed(), startDark: false)
  }
  bars += widths([1, 1, 1, 1, 1, 1], startDark: false)
  return ("0" + six + String(check), bars)
}

let code39Chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%*")
let code39Patterns: [Int] = [
  0x034, 0x121, 0x061, 0x160, 0x031, 0x130, 0x070, 0x025, 0x124, 0x064,
  0x109, 0x049, 0x148, 0x019, 0x118, 0x058, 0x00D, 0x10C, 0x04C, 0x01C,
  0x103, 0x043, 0x142, 0x013, 0x112, 0x052, 0x007, 0x106, 0x046, 0x016,
  0x181, 0x0C1, 0x1C0, 0x091, 0x190, 0x0D0, 0x085, 0x184, 0x0C4, 0x0A8,
  0x0A2, 0x08A, 0x02A, 0x094,
]

func code39(_ text: String, wide: Int = 3) -> [Bool] {
  var bars: [Bool] = []
  for c in "*" + text + "*" {
    let p = code39Patterns[code39Chars.firstIndex(of: c)!]
    let w = (0..<9).map { (p >> (8 - $0)) & 1 == 1 ? wide : 1 }
    bars += widths(w, startDark: true)
    bars.append(false)
  }
  bars.removeLast()
  return bars
}

let itfPatterns = [0b00110, 0b10001, 0b01001, 0b11000, 0b00101, 0b10100, 0b01100, 0b00011, 0b10010, 0b01010]

func itf(_ digits: String, wide: Int = 3) -> [Bool] {
  let d = digitsOf(digits)
  var bars = widths([1, 1, 1, 1], startDark: true)
  for i in stride(from: 0, to: d.count, by: 2) {
    var w: [Int] = []
    for j in 0..<5 {
      w.append((itfPatterns[d[i]] >> (4 - j)) & 1 == 1 ? wide : 1)
      w.append((itfPatterns[d[i + 1]] >> (4 - j)) & 1 == 1 ? wide : 1)
    }
    bars += widths(w, startDark: true)
  }
  bars += widths([wide, 1, 1], startDark: true)
  return bars
}

// MARK: 画图

struct Canvas {
  let width: Int
  let height: Int
  let context: CGContext

  init(_ width: Int, _ height: Int, color: Bool = false, background: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) {
    self.width = width
    self.height = height
    let space = color ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
    context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: color ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(CGColor(srgbRed: background.0, green: background.1, blue: background.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // 坐标原点放到左上角，y 向下（和图的像素行一致）
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
  }

  /// 在 (x, y)（左上角）画一个码，每个模块 module 像素，angle 度绕码的中心顺时针转，quiet 是留白模块数
  func draw(
    _ modules: [[Bool]], x: CGFloat, y: CGFloat, module: CGFloat, angle: CGFloat = 0, quiet: Int = 4,
    dark: (CGFloat, CGFloat, CGFloat) = (0, 0, 0), light: (CGFloat, CGFloat, CGFloat)? = (1, 1, 1)
  ) {
    let rows = modules.count
    let columns = modules[0].count
    let w = CGFloat(columns + 2 * quiet) * module
    let h = CGFloat(rows + 2 * quiet) * module
    context.saveGState()
    context.translateBy(x: x + w / 2, y: y + h / 2)
    context.rotate(by: angle * .pi / 180)
    context.translateBy(x: -w / 2, y: -h / 2)
    context.setShouldAntialias(angle != 0 || module != module.rounded())
    if let light {
      context.setFillColor(CGColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    context.setFillColor(CGColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1))
    for r in 0..<rows {
      var c = 0
      while c < columns {
        if !modules[r][c] {
          c += 1
          continue
        }
        var e = c
        while e < columns && modules[r][e] { e += 1 }
        context.fill(
          CGRect(
            x: CGFloat(quiet + c) * module, y: CGFloat(quiet + r) * module, width: CGFloat(e - c) * module,
            height: module))
        c = e
      }
    }
    context.restoreGState()
  }

  func drawBars(_ bars: [Bool], x: CGFloat, y: CGFloat, module: CGFloat, height: CGFloat, angle: CGFloat = 0) {
    let rows = [[Bool]](repeating: bars, count: 1)
    // 一维码：一行模块拉高（quiet = 10 个模块）
    let w = CGFloat(bars.count + 20) * module
    context.saveGState()
    context.translateBy(x: x + w / 2, y: y + height / 2)
    context.rotate(by: angle * .pi / 180)
    context.translateBy(x: -w / 2, y: -height / 2)
    context.setShouldAntialias(angle != 0 || module != module.rounded())
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: w, height: height))
    context.setFillColor(gray: 0, alpha: 1)
    var c = 0
    while c < bars.count {
      if !rows[0][c] {
        c += 1
        continue
      }
      var e = c
      while e < bars.count && bars[e] { e += 1 }
      context.fill(CGRect(x: CGFloat(10 + c) * module, y: module * 4, width: CGFloat(e - c) * module, height: height - module * 8))
      c = e
    }
    context.restoreGState()
  }

  func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, gray: CGFloat = 0.1) {
    context.saveGState()
    // 文字要正着画：临时翻回 y 向上
    context.translateBy(x: x, y: y + size)
    context.scaleBy(x: 1, y: -1)
    let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: CGColor(gray: gray, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }

  var image: CGImage { context.makeImage()! }
}

/// 透视：把码画成的图交给 CIPerspectiveTransform，四个角各往里收一点
func perspective(_ image: CGImage, _ insets: [CGFloat]) -> CGImage {
  let ci = CIImage(cgImage: image)
  let w = ci.extent.width
  let h = ci.extent.height
  let filter = CIFilter.perspectiveTransform()
  filter.inputImage = ci
  filter.topLeft = CGPoint(x: insets[0] * w, y: h - insets[1] * h)
  filter.topRight = CGPoint(x: w - insets[2] * w, y: h - insets[3] * h)
  filter.bottomRight = CGPoint(x: w - insets[4] * w, y: insets[5] * h)
  filter.bottomLeft = CGPoint(x: insets[6] * w, y: insets[7] * h)
  let output = filter.outputImage!.composited(over: CIImage(color: .white).cropped(to: ci.extent))
  return ciContext.createCGImage(output, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!
}

func blur(_ image: CGImage, radius: Double) -> CGImage {
  let ci = CIImage(cgImage: image)
  let output = ci.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ci.extent)
  return ciContext.createCGImage(output, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!
}

/// 每个像素加上 ±amplitude 的均匀噪声（灰度图）
func noisy(_ image: CGImage, amplitude: Int) -> CGImage {
  let width = image.width
  let height = image.height
  var pixels = [UInt8](repeating: 0, count: width * height)
  let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  for i in 0..<pixels.count {
    let v = Int(pixels[i]) + random(2 * amplitude + 1) - amplitude
    pixels[i] = UInt8(max(0, min(255, v)))
  }
  return context.makeImage()!
}

// MARK: 写文件、Vision 核对

struct Fixture: Encodable {
  let file: String
  let codes: [String]
}
var fixtures: [Fixture] = []
var problems: [String] = []

func vision(_ image: CGImage) -> [String] {
  let request = VNDetectBarcodesRequest()
  let handler = VNImageRequestHandler(cgImage: image)
  try? handler.perform([request])
  var seen: [String] = []
  for observation in request.results ?? [] {
    if let s = observation.payloadStringValue, !seen.contains(s) { seen.append(s) }
  }
  return seen
}

func save(_ name: String, _ image: CGImage, _ codes: [String]) {
  let url = outputDirectory.appendingPathComponent(name + ".png")
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
  fixtures.append(Fixture(file: name + ".png", codes: codes))
  let read = vision(image)
  if Set(read) != Set(codes) {
    problems.append("\(name): 期望 \(codes) Vision 读到 \(read)")
  }
}

/// 一个码居中放在留了边的白底上
func single(_ name: String, _ modules: [[Bool]], _ codes: [String], module: CGFloat = 4) {
  let side = Int(CGFloat(modules.count + 8) * module) + 40
  let canvas = Canvas(side, side)
  canvas.draw(modules, x: 20, y: 20, module: module)
  save(name, canvas.image, codes)
}

func linear(_ name: String, _ bars: [Bool], _ codes: [String], module: CGFloat = 2, angle: CGFloat = 0, amplitude: Int = 0) {
  let w = CGFloat(bars.count + 20) * module
  let h: CGFloat = 120
  let side = Int(max(w, h) * (angle == 0 ? 1 : 1.2)) + 40
  let canvas = Canvas(side, angle == 0 ? Int(h) + 40 : side)
  let y = angle == 0 ? 20 : (CGFloat(side) - h) / 2
  canvas.drawBars(bars, x: (CGFloat(side) - w) / 2, y: y, module: module, height: h, angle: angle)
  save(name, amplitude > 0 ? noisy(canvas.image, amplitude: amplitude) : canvas.image, codes)
}

// MARK: 清单

try? FileManager.default.removeItem(at: outputDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// 各版本、各纠错等级（字节模式，内容凑满那个版本）
let levels = ["L", "M", "Q", "H"]
func byteCapacity(_ v: Int, _ level: Int) -> Int {
  (QrEncoder.dataCodewords(v, level) * 8 - 4 - (v <= 9 ? 8 : 16)) / 8
}
for (v, level) in [(1, 0), (2, 1), (3, 2), (4, 3), (5, 0), (7, 1), (10, 2), (14, 3), (20, 0), (27, 1), (33, 2), (40, 0), (40, 3)] {
  let text = letters(byteCapacity(v, level))
  let modules = coreImageQR(text, level: levels[level])
  precondition(modules.count == 17 + 4 * v, "CoreImage 的版本不是 \(v)")
  single(String(format: "qr-v%02d-%@", v, levels[level]), modules, [text], module: v >= 27 ? 3 : 4)
}

let url = "https://example.com/kitty-tools?from=qr&id=20261117"
let urlCode = coreImageQR(url, level: "M")
let chinese = "扫码看看：二维码里的中文 UTF-8，标点「」、数字 123 和 emoji 🐱"
single("qr-utf8-chinese", coreImageQR(chinese, level: "Q"), [chinese])
let wifi = "WIFI:T:WPA;S:Kitty 的网络;P:12345678;;"
single("qr-wifi", coreImageQR(wifi, level: "L"), [wifi])

// 自己编码：各种模式、ECI、掩码 0–7
single("qr-numeric-mask0", QrEncoder.encode([.numeric("0123456789012345678901234567890123")], level: 1, mask: 0), ["0123456789012345678901234567890123"])
let alnum = "HTTPS://EXAMPLE.COM/A-Z $%*+./:09"
single("qr-alphanumeric-mask1", QrEncoder.encode([.alphanumeric(alnum)], level: 2, mask: 1), [alnum])
let kanji = "日本語の漢字モード点検"
single("qr-kanji-mask2", QrEncoder.encode([.kanji(kanji)], level: 1, mask: 2), [kanji])
let eciText = "ECI 26：中文 ✓ émoji 😀"
single("qr-eci-utf8-mask3", QrEncoder.encode([.eci(26), .bytes([UInt8](eciText.utf8))], level: 0, mask: 3), [eciText])
let latin = "Größe café"
single("qr-eci-latin1-mask4", QrEncoder.encode([.eci(3), .bytes([UInt8](latin.data(using: .isoLatin1)!))], level: 3, mask: 4), [latin])
let mixedText = "ORDER-2026/11/17 01234567890123 共 3 件"
single(
  "qr-mixed-segments-mask5",
  QrEncoder.encode([.alphanumeric("ORDER-2026/11/17 "), .numeric("01234567890123"), .bytes([UInt8](" 共 3 件".utf8))], level: 1, mask: 5),
  [mixedText])
let v8Text = letters(120)
single("qr-v08-mask6", QrEncoder.encode([.bytes([UInt8](v8Text.utf8))], level: 1, mask: 6, minVersion: 8), [v8Text])
let v15Text = String(repeating: "0123456789", count: 30)
single("qr-v15-mask7", QrEncoder.encode([.numeric(v15Text)], level: 2, mask: 7, minVersion: 15), [v15Text])
let gbText = "国标编码：简体中文"
let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
single("qr-eci-gb18030", QrEncoder.encode([.eci(29), .bytes([UInt8](gbText.data(using: gb18030)!))], level: 1, mask: 0), [gbText])
single("qr-gbk-no-eci", QrEncoder.encode([.bytes([UInt8](gbText.data(using: gb18030)!))], level: 1, mask: 3), [gbText])

// 摆法、画质
func placed(_ name: String, side: Int, module: CGFloat, angle: CGFloat, amplitude: Int = 0, blurRadius: Double = 0) {
  let canvas = Canvas(side, side)
  let w = CGFloat(urlCode.count + 8) * module
  canvas.draw(urlCode, x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - w) / 2, module: module, angle: angle)
  var image = canvas.image
  if blurRadius > 0 { image = blur(image, radius: blurRadius) }
  if amplitude > 0 { image = noisy(image, amplitude: amplitude) }
  save(name, image, [url])
}
placed("qr-rotate-12", side: 300, module: 5, angle: 12)
placed("qr-rotate-45", side: 380, module: 5, angle: 45)
placed("qr-rotate-180", side: 260, module: 5, angle: 180)
placed("qr-rotate-100", side: 300, module: 4.5, angle: 100)
placed("qr-scale-2px", side: 120, module: 2, angle: 0)
placed("qr-scale-2.6px", side: 150, module: 2.6, angle: 0)
placed("qr-scale-18px", side: 700, module: 18, angle: 0)
placed("qr-noise", side: 260, module: 5, angle: 0, amplitude: 60)
placed("qr-blur", side: 260, module: 5, angle: 0, blurRadius: 1.2)
placed("qr-rotate-noise-blur", side: 300, module: 5, angle: 20, amplitude: 35, blurRadius: 0.8)

for (name, insets) in [
  ("qr-perspective-1", [0.10, 0.04, 0.02, 0.0, 0.0, 0.0, 0.05, 0.02] as [CGFloat]),
  ("qr-perspective-2", [0.0, 0.0, 0.12, 0.08, 0.12, 0.08, 0.0, 0.0] as [CGFloat]),
] {
  let side = (urlCode.count + 8) * 7 + 20
  let canvas = Canvas(side, side)
  canvas.draw(urlCode, x: 10, y: 10, module: 7)
  save(name, perspective(canvas.image, insets), [url])
}
do {
  // 大版本透视：要靠右下角的校正图形
  let big = letters(300)
  let modules = coreImageQR(big, level: "M")
  let side = (modules.count + 8) * 4 + 20
  let canvas = Canvas(side, side)
  canvas.draw(modules, x: 10, y: 10, module: 4)
  save("qr-perspective-v13", perspective(canvas.image, [0.06, 0.03, 0.0, 0.0, 0.03, 0.02, 0.0, 0.05]), [big])
}

// 深色底：浅色模块（深色模式的界面），和白卡片放在深色底上
do {
  let canvas = Canvas(300, 300, background: (0.12, 0.12, 0.13))
  canvas.draw(urlCode, x: 40, y: 40, module: 5, dark: (0.92, 0.92, 0.92), light: nil)
  save("qr-dark-inverted", canvas.image, [url])
  let card = Canvas(320, 320, background: (0.1, 0.1, 0.12))
  card.draw(urlCode, x: 50, y: 50, module: 5)
  save("qr-dark-card", card.image, [url])
  let color = Canvas(300, 300, color: true, background: (1, 0.95, 0.75))
  color.draw(urlCode, x: 40, y: 40, module: 5, dark: (0.1, 0.2, 0.55), light: (1, 0.95, 0.75))
  save("qr-color", color.image, [url])
}

// 镜像的码（矩阵转置）
do {
  let n = urlCode.count
  let mirrored = (0..<n).map { y in (0..<n).map { x in urlCode[x][y] } }
  single("qr-mirrored", mirrored, [url])
}

// 一维码
let (eanText, eanBars) = ean13("690123456789")
linear("ean13", eanBars, [eanText])
let (ean8Text, ean8Bars) = ean8("9638507")
linear("ean8", ean8Bars, [ean8Text])
let (upcaText, upcaBars) = ean13("003600029145")  // UPC-A 0 36000 29145 2 = EAN-13 前面补 0
linear("upca", upcaBars, [upcaText])
let (upceText, upceBars) = upce("123456")
linear("upce", upceBars, [upceText])
for (name, text) in [("code128-text", "Kitty-Tools 0.3.0"), ("code128-digits", "20261117123456"), ("code128-mixed", "abc123456789XYZ")] {
  linear(name, coreImageCode128(text), [text])
}
linear("code39", code39("KITTY-39"), ["KITTY-39"], module: 2)
linear("code39-wide2", code39("A1 B2.C3", wide: 2), ["A1 B2.C3"], module: 3)
linear("itf", itf("1234567890"), ["1234567890"], module: 2)
linear("itf14", itf("00012345600012"), ["00012345600012"], module: 2)
linear("ean13-rotate-90", eanBars, [eanText], angle: 90)
linear("ean13-rotate-180", eanBars, [eanText], angle: 180)
linear("code128-rotate-7", coreImageCode128("Kitty-Tools 0.3.0"), ["Kitty-Tools 0.3.0"], angle: 7)
linear("ean13-noise", eanBars, [eanText], module: 3, amplitude: 40)
linear("ean13-1.5px", eanBars, [eanText], module: 1.5)

// 一图多码：三个二维码（一个转过、一个深色）+ 一个 EAN-13
do {
  let canvas = Canvas(900, 600)
  let a = "第一个码 A"
  let b = "SECOND-CODE-B"
  let c = "third code c"
  canvas.draw(coreImageQR(a, level: "M"), x: 30, y: 30, module: 6)
  canvas.draw(coreImageQR(b, level: "H"), x: 330, y: 40, module: 5, angle: -15)
  canvas.draw(coreImageQR(c, level: "L"), x: 620, y: 30, module: 6, dark: (0.2, 0.2, 0.2))
  canvas.drawBars(eanBars, x: 200, y: 400, module: 3, height: 140)
  save("multi-3qr-1ean", canvas.image, [a, b, c, eanText])
}

// 大截图里的小码：一屏文字 + 一个模块 3 像素的码（走缩小找定位那条路）
do {
  let canvas = Canvas(2600, 1600)
  for row in 0..<12 {
    canvas.text("第 \(row + 1) 行：这是一段模拟截图里的文字 The quick brown fox jumps over the lazy dog 0123456789", x: 60, y: CGFloat(60 + row * 46), size: 26)
  }
  let small = coreImageQR(url, level: "M")
  canvas.draw(small, x: 2300, y: 1300, module: 3)
  save("screen-large-small-qr", canvas.image, [url])
}

// 没有码的图
do {
  let text = Canvas(800, 400)
  for row in 0..<9 {
    text.text("没有二维码的一段文字 Line \(row)：||| ||| 1 1 3 1 1 ■ □ ■ ¦ Il1|", x: 20, y: CGFloat(20 + row * 40), size: 24)
  }
  save("none-text", text.image, [])
  let noise = noisy(Canvas(300, 300, background: (0.5, 0.5, 0.5)).image, amplitude: 120)
  save("none-noise", noise, [])
  let grid = Canvas(400, 400)
  for i in 0..<20 {
    for j in 0..<20 where (i + j) % 2 == 0 || (i * j) % 7 == 1 {
      grid.context.fill(CGRect(x: i * 20, y: j * 20, width: 20, height: 20))
    }
  }
  grid.context.fill(CGRect(x: 40, y: 40, width: 70, height: 70))
  save("none-grid", grid.image, [])
  save("none-blank", Canvas(200, 200).image, [])
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(fixtures).write(to: outputDirectory.appendingPathComponent("manifest.json"))
print("写了 \(fixtures.count) 张图到 \(outputDirectory.path)")
if problems.isEmpty {
  print("Vision 全部读对了")
} else {
  print("Vision 和清单对不上的：")
  for p in problems { print("  " + p) }
}
