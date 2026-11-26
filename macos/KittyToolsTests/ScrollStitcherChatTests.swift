// 长截图拼接单测（聊天窗口，issue #57）：合成一页像电脑版聊天 App 的对话——纯色底、左右两边的气泡和扁平头像、
// 居中的时间条、图片消息，上面固定的标题栏、下面固定的输入框（光标在闪）、对话那一栏右边的浮动滚动条；
// 选区三种：只有对话、左边多框了不动的会话列表、右边多框进去一截桌面（滚动条落进比较的列）。按不均匀的位移
// （整像素、越滚越慢的惯性、半像素）往下、往上滚，每一帧都要接上；整像素的长图逐像素核对对话那一栏。

import CoreGraphics
import Foundation
import Testing

@testable import KittyTools

struct ScrollStitcherChatTests {
  /// 对话那一栏宽、会话列表宽、整帧高；标题栏、输入框高；右边滚动条宽
  nonisolated private static let chatWidth = 360
  nonisolated private static let sidebarWidth = 120
  nonisolated private static let height = 420
  nonisolated private static let title = 36
  nonisolated private static let input = 90
  nonisolated private static let scrollbar = 8
  private static var chatRows: Int { height - title - input }

  nonisolated private struct Color { let b, g, r: UInt8 }
  nonisolated private static let background = Color(b: 245, g: 245, r: 245)
  nonisolated private static let white = Color(b: 255, g: 255, r: 255)
  nonisolated private static let green = Color(b: 105, g: 236, r: 149)

  /// 对话页（只有对话那一栏，BGRA）：4000 行
  nonisolated private static let pageRows = 4000
  nonisolated private static let page: [UInt8] = {
    var rng = ChatGenerator(state: 57)
    var bytes = [UInt8](repeating: 0, count: chatWidth * 4 * pageRows)
    func paint(_ rows: Range<Int>, _ columns: Range<Int>, _ color: Color) {
      for y in rows where y < pageRows {
        for x in columns where x >= 0 && x < chatWidth {
          let index = (y * chatWidth + x) * 4
          bytes[index] = color.b
          bytes[index + 1] = color.g
          bytes[index + 2] = color.r
          bytes[index + 3] = 255
        }
      }
    }
    paint(0..<pageRows, 0..<chatWidth, background)
    /// 一行「字」：随机的深色点（字形）
    func glyphs(_ rows: Range<Int>, _ columns: Range<Int>) {
      for y in rows where y < pageRows {
        for x in columns where x < chatWidth && rng.next() % 4 == 0 {
          let gray = UInt8(rng.next() % 120)
          paint(y..<(y + 1), x..<(x + 1), Color(b: gray, g: gray, r: gray))
        }
      }
    }
    // 三个人的头像：纯色方块里一个浅色方块（扁平头像，块里很多行一模一样）
    let avatars = [
      Color(b: 200, g: 120, r: 60), Color(b: 80, g: 160, r: 220), Color(b: 140, g: 140, r: 140),
    ]
    var y = 16
    var message = 0
    while y < pageRows - 200 {
      if message % 5 == 0 {
        // 时间条：居中一小段灰字
        glyphs((y + 4)..<(y + 14), (chatWidth / 2 - 30)..<(chatWidth / 2 + 30))
        y += 30
      }
      message += 1
      let mine = rng.next() % 3 == 0
      let avatar = 28
      let ax = mine ? chatWidth - 12 - avatar : 12
      let who = mine ? 0 : 1 + Int(rng.next() % 2)
      paint(y..<(y + avatar), ax..<(ax + avatar), avatars[who])
      paint((y + 8)..<(y + 20), (ax + 8)..<(ax + 20), white)
      if rng.next() % 7 == 0 {
        // 图片消息：一块渐变加噪点
        let x0 = mine ? ax - 8 - 120 : ax + avatar + 8
        for row in 0..<90 {
          for column in 0..<120 {
            let value = UInt8((row * 2 + column) % 200 + Int(rng.next() % 30))
            paint(
              (y + row)..<(y + row + 1), (x0 + column)..<(x0 + column + 1),
              Color(b: value, g: value / 2 + 60, r: 255 - value))
          }
        }
        y += 90 + 16
        continue
      }
      let lines = 1 + Int(rng.next() % 4)
      let width = lines > 1 ? 220 : 60 + Int(rng.next() % 160)
      let x0 = mine ? ax - 8 - width : ax + avatar + 8
      let bubble = lines * 20 + 16
      paint(y..<(y + bubble), x0..<(x0 + width), mine ? green : white)
      for line in 0..<lines {
        let top = y + 8 + line * 20 + 3
        let end =
          line == lines - 1 ? x0 + 10 + Int(rng.next() % UInt64(width - 20)) : x0 + width - 10
        glyphs(top..<(top + 14), (x0 + 10)..<max(end, x0 + 20))
      }
      y += max(bubble, avatar) + 16
    }
    return bytes
  }()

  /// 选区框了哪些：只有对话那一栏；左边多框了一栏不动的会话列表（点了整个窗口）；右边多框进去一截桌面
  /// （对话那一栏的浮动滚动条因此落在比较的列里，不在右边排除掉的那一条里）
  enum Selection: CaseIterable { case chat, sidebar, desktop }

  /// 对话那一栏左边从第几列起、整帧多宽
  private static func columns(_ selection: Selection) -> (left: Int, width: Int) {
    switch selection {
    case .chat: (0, chatWidth)
    case .sidebar: (sidebarWidth, sidebarWidth + chatWidth)
    case .desktop: (0, chatWidth + 40)
    }
  }

  /// 滚到 offset（可以是小数：半像素那一帧每行是相邻两行的平均，像按小数位置重画的字）的一帧；caret：输入框里的光标亮着
  /// dimmed：整扇压暗到 78%（WPS 失焦时那样）
  private static func frame(
    at offset: Double, _ selection: Selection, caret: Bool, dimmed: Bool = false
  ) -> CGImage {
    let (left, width) = columns(selection)
    let right = left + chatWidth
    var bytes = [UInt8](repeating: 255, count: width * 4 * height)
    func set(_ x: Int, _ y: Int, _ value: UInt8) {
      let index = (y * width + x) * 4
      bytes[index] = value
      bytes[index + 1] = value
      bytes[index + 2] = value
    }
    func fill(_ rows: Range<Int>, _ columns: Range<Int>, _ value: UInt8) {
      for y in rows { for x in columns { set(x, y, value) } }
    }
    var rng = ChatGenerator(state: 7)
    if selection == .sidebar {
      // 会话列表：一条 60 行，头像 + 两行字，第二条选中
      fill(0..<height, 0..<left, 232)
      for item in 0..<(height / 60) {
        let top = item * 60
        if item == 1 { fill(top..<(top + 60), 0..<left, 210) }
        fill((top + 12)..<(top + 48), 8..<44, UInt8(80 + item * 20))
        for y in (top + 16)..<(top + 26) {
          for x in 52..<110 where rng.next() % 3 == 0 { set(x, y, 40) }
        }
        for y in (top + 34)..<(top + 42) {
          for x in 52..<100 where rng.next() % 4 == 0 { set(x, y, 140) }
        }
      }
    }
    if selection == .desktop {
      // 桌面：一块有起伏的壁纸
      for y in 0..<height {
        for x in right..<width { set(x, y, UInt8(90 + (x * 7 + y * 3) % 60 + Int(rng.next() % 9))) }
      }
    }
    // 标题栏和它下面的分隔线
    fill(0..<title, left..<right, 238)
    for y in 12..<24 {
      for x in (left + 16)..<(left + 90) where rng.next() % 3 == 0 { set(x, y, 30) }
    }
    fill((title - 1)..<title, left..<right, 220)
    // 对话
    let base = Int(offset)
    let fraction = offset - Double(base)
    let rowBytes = chatWidth * 4
    for y in 0..<chatRows {
      let row = base + y
      for x in 0..<chatWidth {
        for channel in 0..<3 {
          let a = Double(page[row * rowBytes + x * 4 + channel])
          let b = Double(page[(row + 1) * rowBytes + x * 4 + channel])
          bytes[((title + y) * width + left + x) * 4 + channel] = UInt8(
            (a * (1 - fraction) + b * fraction).rounded())
        }
      }
    }
    // 浮动滚动条：对话那一栏最右边，跟着滚的位置走
    let knob = title + base * (chatRows - 60) / (pageRows - chatRows)
    fill(knob..<(knob + 60), (right - 6)..<(right - 2), 160)
    // 输入框：分隔线、一排工具图标、光标
    let inputTop = height - input
    fill(inputTop..<height, left..<right, 255)
    fill(inputTop..<(inputTop + 1), left..<right, 220)
    for icon in 0..<5 {
      let x0 = left + 14 + icon * 26
      fill((inputTop + 10)..<(inputTop + 26), x0..<(x0 + 16), 120)
    }
    if caret { fill((inputTop + 40)..<(inputTop + 58), (left + 16)..<(left + 18), 0) }
    if dimmed {
      for index in bytes.indices where index % 4 != 3 {
        bytes[index] = UInt8(Double(bytes[index]) * 0.78)
      }
    }
    return image(bytes, width: width)
  }

  private static func image(_ bytes: [UInt8], width: Int, rows: Int = height) -> CGImage {
    CGImage(
      width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }

  private static func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  /// 按 offsets 一帧帧喂进去（第 n 帧光标亮不亮轮着来），每一帧都要接上；返回拼好的
  private static func stitch(_ offsets: [Double], _ selection: Selection) throws -> ScrollStitcher {
    var stitcher = try #require(
      ScrollStitcher(
        first: frame(at: offsets[0], selection, caret: false), scrollbarWidth: scrollbar,
        maxHeight: 100_000))
    for (index, offset) in offsets.enumerated().dropFirst() {
      let outcome = stitcher.add(frame(at: offset, selection, caret: index % 2 == 1))
      guard case .moved = outcome else {
        Issue.record("滚到 \(offset) 没接上：\(outcome)，\(stitcher.attempts)")
        break
      }
    }
    return stitcher
  }

  /// 整像素滚动拼出来的长图逐像素核对对话那一栏（会话列表、桌面、滚动条那几列跟着各帧走，不核对）：
  /// 最上面那帧的标题栏 + 对话 [top, bottom) + 最下面那帧的输入框
  private static func expect(
    _ stitcher: ScrollStitcher, _ selection: Selection, top: Int, bottom: Int, lastCaret: Bool
  ) throws {
    let result = try #require(stitcher.makeImage())
    let rows = bottom - top + title + input
    #expect(result.height == rows)
    guard result.height == rows else { return }
    let (left, width) = columns(selection)
    let got = pixels(result)
    let topFrame = pixels(frame(at: Double(top), selection, caret: false))
    let bottomFrame = pixels(frame(at: Double(bottom - chatRows), selection, caret: lastCaret))
    // 对话那一栏、去掉右边滚动条那几列
    let checked = left..<(left + chatWidth - 8)
    func row(_ bytes: [UInt8], _ y: Int, width: Int, from x0: Int = 0) -> [UInt8] {
      Array(
        bytes[
          ((y * width + checked.lowerBound - x0) * 4)..<((y * width + checked.upperBound - x0) * 4)]
      )
    }
    let mismatched = (0..<rows).filter { y in
      let want =
        y < title
        ? row(topFrame, y, width: width)
        : y >= rows - input
          ? row(bottomFrame, height - (rows - y), width: width)
          : row(page, top + y - title, width: chatWidth, from: left)
      return row(got, y, width: width) != want
    }
    #expect(mismatched.isEmpty, "第一处不一致在第 \(mismatched.first ?? -1) 行，共 \(mismatched.count) 行")
  }

  /// 往下翻、往上翻（聊天记录）、手在触控板上一甩越滚越慢；位移不均匀，有 1 行的也有半屏的
  static let down: [Double] = [100, 113, 160, 165, 255, 286, 330, 331, 400, 512, 560, 610, 700]
  static let inertia: [Double] = [100, 180, 240, 285, 318, 342, 360, 372, 380, 385, 388, 389]

  @Test(arguments: Selection.allCases)
  func stitchesChatWindow(selection: Selection) throws {
    // issue #57：电脑版聊天 App 里长截图「一直对不上」。选区里有不跟着滚、又有内容的竖条（会话列表、桌面、
    // 比较区里的浮动滚动条）时整行一行都对不上，原来只剩容差投票：整像素也接歪一行、往上翻几步就断
    for offsets in [Self.down, Self.inertia] {
      let lastCaret = (offsets.count - 1) % 2 == 1
      try Self.expect(
        Self.stitch(offsets, selection), selection, top: Int(offsets[0]),
        bottom: Int(offsets.last!) + Self.chatRows, lastCaret: lastCaret)
      let up = offsets.reversed().map { $0 + 600 }
      try Self.expect(
        Self.stitch(up, selection), selection, top: Int(up.last!),
        bottom: Int(up[0]) + Self.chatRows, lastCaret: false)
    }
  }

  @Test(arguments: Selection.allCases)
  func relocatesAfterScrollingTooFast(selection: Selection) throws {
    // 滚太快和上一帧没有重叠（对不上），再滚回已经拼过、但和上一帧也不重叠的地方：在画布里按段找回位置接着拼
    var stitcher = try Self.stitch([100, 300, 500, 700], selection)
    #expect(stitcher.add(Self.frame(at: 1500, selection, caret: false)) == .lost)
    let back = stitcher.add(Self.frame(at: 150, selection, caret: true))
    #expect(back == .moved(grown: 0), "\(stitcher.attempts)")
    guard case .moved = stitcher.add(Self.frame(at: 190, selection, caret: false)) else {
      Issue.record("找回位置后接着滚没接上：\(stitcher.attempts)")
      return
    }
    #expect(stitcher.outputHeight == 700 - 100 + Self.height)
  }

  @Test func restartsWhenTheWindowDimsBeforeScrolling() throws {
    // issue #57 第二轮：WPS 把失焦的窗口整扇压暗，长截图的第一帧截在压暗之前，之后每一帧都对不上。还没开始滚、
    // 也没拼上过东西时拿压暗后的那一帧重新当第一帧，接着滚就一路接上，长图是压暗后的样子
    var stitcher = try #require(
      ScrollStitcher(
        first: Self.frame(at: 100, .chat, caret: false), scrollbarWidth: Self.scrollbar,
        maxHeight: 100_000))
    let dim = Self.frame(at: 100, .chat, caret: false, dimmed: true)
    let outcome = stitcher.add(dim)
    #expect(outcome == .lost)
    #expect(ScrollCapture.restarts(outcome, hasScrolled: false, stitched: false))
    #expect(!ScrollCapture.restarts(outcome, hasScrolled: true, stitched: false))
    #expect(!ScrollCapture.restarts(outcome, hasScrolled: false, stitched: true))
    #expect(!ScrollCapture.restarts(.unchanged, hasScrolled: false, stitched: false))
    stitcher.restart(from: ScrollStitcher.Frame(dim, layout: stitcher.layout))
    for offset in [160.0, 250, 330] {
      guard case .moved = stitcher.add(Self.frame(at: offset, .chat, caret: false, dimmed: true))
      else {
        Issue.record("重取第一帧后滚到 \(offset) 没接上：\(stitcher.attempts)")
        return
      }
    }
    #expect(stitcher.outputHeight == 330 - 100 + Self.height)
    #expect(stitcher.rows == 0..<(330 - 100 + Self.height))
  }

  @Test(arguments: Selection.allCases)
  func stitchesChatAtHalfPixels(selection: Selection) throws {
    // 停在小数位置的滚动：上一帧是糊开的、这一帧是实的（或反过来）都要接上，往上翻也一样；
    // 每道半像素的接缝最多差半行，长度差不出接缝的个数
    let half: [Double] = [100, 113.5, 160, 165.5, 255, 286.5, 330, 331.5, 400, 512.5, 560]
    for offsets in [half, half.reversed().map { $0 + 600 }] {
      let stitcher = try Self.stitch(offsets, selection)
      let span = Int(abs(offsets.last! - offsets[0]))
      #expect(abs(stitcher.outputHeight - (span + Self.height)) <= 5)
    }
  }
}

/// 固定种子的 SplitMix64
nonisolated private struct ChatGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
