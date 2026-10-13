// 长截图拼接（纯逻辑，配单测）：每来一帧选区截图，和上一帧比出纵向位移，把新露出来的行接到长图的上边或下边。
// - 位移：逐行哈希（不看右边滚动条那一条），新帧的每一行去上一帧里找一模一样的行，按行号差投票；最高票至少是
//   第二名的两倍才算对上（重复的表格行、代码行会给好几个位移投票，分不出来就宁可不接）。纯色行、在帧里重复太多次的行
//   （空白、竖线边框）和原地没变的行（吸顶栏、页脚）不投票。屏幕内容按整像素滚动，逐行完全相同，用不着模糊匹配。
//   实测（合成页面，带吸顶栏 / 页脚 / 滚动条 / 动画块 / 光标）零误接；Vision 的平移配准在有吸顶栏时大半算错、
//   置信度却总是 1，不能用。
// - 两个方向都能拼（聊天记录往上翻）：每帧在「画布」上有个位置，超出画布下边就接到下面、超出上边就接到上面，
//   在画布里面（往回滚）只更新位置。
// - 吸顶栏 / 页脚：往下接先去掉画布末尾的页脚、再接新帧的新内容连同它的页脚，所以长图始终是「最上面那帧的
//   吸顶栏 + 内容 + 最下面那帧的页脚」；往上接同理。页脚高度取「首尾原地不变的行」和「对上的最后一行以下」中大的：
//   页脚里有闪烁的光标（聊天输入框）时前者会估小，估小会在长图中间留下页脚碎片；估大没关系（多去掉的内容由新帧补回）。
// - 和上一帧对不上时再看两样（2026-10-13）：上一帧有内容的行大半原地没动 = 画面没滚，只是原地变了一块（鼠标悬停的
//   高亮、工具提示：列表上每滚一下停住，悬停的那行就换一次），当没动；否则拿整张画布找这一帧的位置（滚太快越过去了、
//   又滚回已经拼过的地方），画布每行的哈希一直留着。都不行才是对不上。
// - 回弹：触控板滚到头会越界再弹回来，越界露出的是纯色底。刚接过的那头往回滚时：画布那头和新帧那头逐字节相同的行
//   （页脚、还露着的越界底色）换成新帧的，再往里画布比新帧多出来的行只有全是纯色才去掉，有字的行一行都不丢。

import CoreGraphics
import Foundation

struct ScrollStitcher {
  enum Outcome: Equatable {
    /// 画面没动，或者只有光标闪烁、小动画这类小变化
    case unchanged
    /// 对上了；grown 是长图变高了多少行（往回滚、回弹时可以是 0 或负数）
    case moved(grown: Int)
    /// 对不上：两帧之间滚得太多没有重叠，或者重叠部分没有可比的内容
    case lost
    /// 再接就超过长度上限，这一帧不接
    case full
  }

  /// 帧的像素尺寸
  let width: Int
  let height: Int
  /// 长图最多多少行（像素）
  let maxHeight: Int
  private let colorSpace: CGColorSpace
  /// 参与比较的列 [0, compared)：右边留出系统的浮动滚动条（它随滚动出现、移动）
  private let compared: Int
  private var rowBytes: Int { width * 4 }

  /// 上一帧及它在画布上的位置（它第 0 行的画布行号）
  private var reference: Frame
  private var referenceTop = 0
  /// 画布范围 [top, bottom)。像素分两段存：below 是 [anchor, bottom) 顺序存，
  /// above 是 [top, anchor) 倒序存（第 0 行是 anchor - 1），往上接不用搬动已有的行
  private var top = 0
  private var bottom: Int
  private var anchor = 0
  private var above: [UInt8] = []
  private var below: [UInt8]
  /// 画布每行的哈希，和 above / below 同样的两段、同样的顺序（relocate 用）
  private var aboveHashes: [Int] = []
  private var belowHashes: [Int]
  /// 最近往哪头接过（回弹只修这头）
  private var lastGrown: Edge?

  private enum Edge { case top, bottom }

  /// 一行在帧里出现超过这么多次就不投票（空白里的竖线边框、重复的代码行）
  private static let maxRepeat = 8
  /// 对上至少要这么多行投票、票数是第二名的这么多倍，且占重叠部分可比行的这个比例
  /// （比例只挡「重叠部分大多在变、碰巧几行一样」，比如选区里在放视频）
  private static let minVotes = 6
  private static let minLead = 2
  private static let minShare = 0.25
  /// 对不上时，变了的行不到这个比例就当画面没动（光标闪烁、小动画），不报「对不上」
  private static let quietShare = 0.1
  /// 对不上时，上一帧有内容的行里原地没动的超过这个比例也当画面没动（悬停高亮、工具提示：变的那块比 quietShare 大）。
  /// 真滚过了的话有内容的行几乎都变了，原地不变的只剩吸顶栏和页脚
  private static let stillShare = 0.5
  /// 在画布里找位置比和上一帧比更容易碰巧（画布长、没有「刚滚了一点」这个前提）：票数要占到重叠部分可比行的一半，
  /// 还要占到这一帧全部可比行的四分之一——只压着画布边上一小截的不接（长页面里隔很远的两处可能有几行一模一样，
  /// 比如每段末尾的同一个按钮），再往回滚一点就够了
  private static let relocateShare = 0.5
  private static let relocateCover = 0.25

  /// 长图当前的高度（像素）
  var outputHeight: Int { bottom - top }
  /// 最近是往上接的（往上翻聊天记录）：自动滚动跟着往上、预览显示顶上那头
  var isGrowingUp: Bool { lastGrown == .top }
  /// 最近一次对上时的位移（像素，> 0 是往下滚）：自动滚动据此校准滚轮方向
  private(set) var lastShift = 0

  /// first：第一帧；scrollbarWidth：右边不参与比较的宽度（像素）
  init?(first: CGImage, scrollbarWidth: Int, maxHeight: Int) {
    width = first.width
    height = first.height
    self.maxHeight = maxHeight
    // 沿用截图自带的色彩空间（屏幕的），拼出来的颜色和截图一致
    if let space = first.colorSpace, space.model == .rgb {
      colorSpace = space
    } else {
      colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    }
    compared = width - min(max(scrollbarWidth, 0), width / 4)
    guard height > 1, maxHeight >= height,
      let frame = Frame(first, width: width, height: height, compared: compared, space: colorSpace)
    else { return nil }
    reference = frame
    below = frame.pixels
    belowHashes = frame.hashes
    bottom = height
  }

  /// 接一帧（尺寸必须和第一帧相同）
  mutating func add(_ image: CGImage) -> Outcome {
    guard
      let frame = Frame(image, width: width, height: height, compared: compared, space: colorSpace)
    else { return .lost }
    let a = reference.hashes
    let b = frame.hashes
    let changed = (0..<height).count { a[$0] != b[$0] }
    guard changed > 0 else { return .unchanged }
    var found = Self.match(from: reference, to: frame)
    if found == nil {
      let ink = (0..<height).count { !reference.solid[$0] }
      let still = (0..<height).count { !reference.solid[$0] && a[$0] == b[$0] }
      if Double(changed) < Self.quietShare * Double(height)
        || Double(still) > Self.stillShare * Double(ink)
      {
        return .unchanged
      }
      found = relocate(frame)
      // 位置没变：原地变回了画布上更早的样子（.moved 的位移不会是 0，自动滚动拿它当除数）
      if found?.dy == 0 { return .unchanged }
    }
    guard let match = found else { return .lost }
    let dy = match.dy
    let position = referenceTop + dy
    guard max(bottom, position + height) - min(top, position) <= maxHeight else { return .full }
    let head = (0..<height).prefix { a[$0] == b[$0] }.count
    let tail = (0..<height).reversed().prefix { a[$0] == b[$0] }.count
    let before = outputHeight
    if position < top {
      // 往上接：去掉画布顶上的吸顶栏，接上新帧露出来的内容连同它的吸顶栏。
      // 新帧顶上露出来的是新内容，重叠部分里对上的第一行往上都算吸顶栏
      let header = max(head, match.first - match.overlap.lowerBound)
      let trimmed = min(header, position + height - top)
      removeTop(trimmed)
      prependTop(frame, rows: 0..<(top - position))
      lastGrown = .top
    } else if position + height > bottom {
      let footer = max(tail, match.overlap.upperBound - 1 - match.last)
      let trimmed = min(footer, bottom - position)
      removeBottom(trimmed)
      appendBottom(frame, rows: (bottom - position)..<height)
      lastGrown = .bottom
    } else if dy < 0, lastGrown == .bottom {
      // 往下接过又往回滚（滚到底的回弹）：末尾相同的行换成新帧的，再往上多出来的全是纯色才去掉
      let kept = sameRows(as: frame, atBottom: true)
      let end = position + height - kept
      if isSolid(end..<(bottom - kept)) {
        removeBottom(bottom - end)
        appendBottom(frame, rows: (height - kept)..<height)
      }
    } else if dy > 0, lastGrown == .top {
      let kept = sameRows(as: frame, atBottom: false)
      let start = position + kept
      if isSolid((top + kept)..<start) {
        removeTop(start - top)
        prependTop(frame, rows: 0..<kept)
      }
    }
    reference = frame
    referenceTop = position
    lastShift = dy
    return .moved(grown: outputHeight - before)
  }

  /// 拼好的长图
  func makeImage() -> CGImage? { image(of: top..<bottom) }

  /// 预览：宽 width 像素，最高 maxHeight 像素；长图更高时只取最近接的那头。
  /// 缩得越小隔的行越多（选区很宽时整张长图都在预览里，逐行拷贝要上百 MB）
  func preview(width: Int, maxHeight: Int) -> CGImage? {
    guard width > 0, maxHeight > 0 else { return nil }
    let scale = Double(width) / Double(self.width)
    let rows = min(outputHeight, Int(Double(maxHeight) / scale))
    let range = lastGrown == .top ? top..<(top + rows) : (bottom - rows)..<bottom
    let height = max(Int((Double(rows) * scale).rounded()), 1)
    guard let source = image(of: range, every: max(Int(1 / scale), 1)),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: Self.bitmapInfo)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  // MARK: 位移

  /// 对上的结果：dy 是位移，b 的第 i 行 = a 的第 i + dy 行（> 0 是内容往上走，即往下滚）；
  /// overlap 是 b 里和对照的那边（上一帧，或 relocate 时的画布）有对应行的那段，first / last 是其中对上的第一行、最后一行
  private struct Match {
    let dy: Int
    let overlap: Range<Int>
    let first: Int
    let last: Int
  }

  /// b 相对 a 对上了没有
  private static func match(from a: Frame, to b: Frame) -> Match? {
    let height = a.hashes.count
    // 能投票的行：非纯色、原地变了、在两帧里都不算常见
    let voters = (0..<height).filter { i in
      let hash = b.hashes[i]
      return !b.solid[i] && hash != a.hashes[i] && !a.common.contains(hash)
        && !b.common.contains(hash)
    }
    var tally = [Int](repeating: 0, count: 2 * height + 1)
    for i in voters {
      for j in a.lookup[b.hashes[i]] ?? [] { tally[j - i + height] += 1 }
    }
    guard let peak = tally.indices.max(by: { tally[$0] < tally[$1] }) else { return nil }
    let votes = tally[peak]
    let second = tally.indices.lazy.filter { $0 != peak }.map { tally[$0] }.max() ?? 0
    let dy = peak - height
    let overlap = voters.filter { (0..<height).contains($0 + dy) }
    guard dy != 0, votes >= minVotes, votes >= minLead * second,
      Double(votes) >= minShare * Double(overlap.count)
    else { return nil }
    let matched = overlap.filter { b.hashes[$0] == a.hashes[$0 + dy] }
    return Match(
      dy: dy, overlap: max(0, -dy)..<min(height, height - dy), first: matched.first ?? 0,
      last: matched.last ?? height - 1)
  }

  /// 和上一帧对不上时，在整张画布里找 b 的位置（投票的规矩同 match；原地没变的行是吸顶栏、页脚，照样不投）。
  /// 找到的位置可以就是上一帧的位置（dy == 0）：画布上那几行是更早的帧留下的，和上一帧不一样（悬停高亮挪走了）
  private func relocate(_ b: Frame) -> Match? {
    let rows = bottom - top
    let voters = (0..<height).filter { i in
      !b.solid[i] && b.hashes[i] != reference.hashes[i] && !b.common.contains(b.hashes[i])
    }
    let lookup = Dictionary(grouping: voters) { b.hashes[$0] }
    // 画布第 j 行（从 top 数）和 b 的第 i 行一样：给「b 的第 0 行在画布第 j - i 行」投一票
    var tally = [Int](repeating: 0, count: rows + height)
    for j in 0..<rows {
      for i in lookup[canvasHash(top + j)] ?? [] { tally[j - i + height] += 1 }
    }
    guard let peak = tally.indices.max(by: { tally[$0] < tally[$1] }) else { return nil }
    let votes = tally[peak]
    let second = tally.indices.lazy.filter { $0 != peak }.map { tally[$0] }.max() ?? 0
    let offset = peak - height
    let range = max(0, -offset)..<min(height, rows - offset)
    let overlap = voters.filter(range.contains)
    guard votes >= Self.minVotes, votes >= Self.minLead * second,
      Double(votes) >= Self.relocateShare * Double(overlap.count),
      Double(votes) >= Self.relocateCover * Double(voters.count)
    else { return nil }
    let matched = overlap.filter { b.hashes[$0] == canvasHash(top + offset + $0) }
    return Match(
      dy: top + offset - referenceTop, overlap: range, first: matched.first ?? range.lowerBound,
      last: matched.last ?? range.upperBound - 1)
  }

  private func canvasHash(_ row: Int) -> Int {
    row >= anchor ? belowHashes[row - anchor] : aboveHashes[anchor - 1 - row]
  }

  // MARK: 画布

  /// 画布末尾（atBottom）或开头和 frame 同一头逐字节相同的行数（只看比较的列）
  private func sameRows(as frame: Frame, atBottom: Bool) -> Int {
    frame.pixels.withUnsafeBytes { pixels in
      (0..<height).prefix { i in
        let (row, frameRow) = atBottom ? (bottom - 1 - i, height - 1 - i) : (top + i, i)
        return withRow(row) {
          memcmp($0, pixels.baseAddress! + frameRow * rowBytes, compared * 4) == 0
        }
      }.count
    }
  }

  /// 画布上 range 这些行全是纯色（只看比较的列）
  private func isSolid(_ range: Range<Int>) -> Bool {
    range.allSatisfy { row in
      withRow(row) { memcmp($0 + 4, $0, compared * 4 - 4) == 0 }
    }
  }

  private func withRow<T>(_ row: Int, _ body: (UnsafeRawPointer) -> T) -> T {
    if row >= anchor {
      return below.withUnsafeBytes { body($0.baseAddress! + (row - anchor) * rowBytes) }
    }
    return above.withUnsafeBytes { body($0.baseAddress! + (anchor - 1 - row) * rowBytes) }
  }

  private mutating func appendBottom(_ frame: Frame, rows: Range<Int>) {
    below.append(
      contentsOf: frame.pixels[(rows.lowerBound * rowBytes)..<(rows.upperBound * rowBytes)])
    belowHashes.append(contentsOf: frame.hashes[rows])
    bottom += rows.count
  }

  /// rows 按从上到下给，倒着塞进 above
  private mutating func prependTop(_ frame: Frame, rows: Range<Int>) {
    for row in rows.reversed() {
      above.append(contentsOf: frame.pixels[(row * rowBytes)..<((row + 1) * rowBytes)])
      aboveHashes.append(frame.hashes[row])
    }
    top -= rows.count
  }

  private mutating func removeBottom(_ count: Int) {
    let fromBelow = min(count, below.count / rowBytes)
    below.removeLast(fromBelow * rowBytes)
    belowHashes.removeLast(fromBelow)
    let rest = count - fromBelow
    if rest > 0 {  // below 已经空了：接着删 above 里挨着 anchor 的行
      above.removeFirst(rest * rowBytes)
      aboveHashes.removeFirst(rest)
      anchor -= rest
    }
    bottom -= count
  }

  private mutating func removeTop(_ count: Int) {
    let fromAbove = min(count, above.count / rowBytes)
    above.removeLast(fromAbove * rowBytes)
    aboveHashes.removeLast(fromAbove)
    let rest = count - fromAbove
    if rest > 0 {  // above 已经空了：接着删 below 开头的行（只在第一次往上接时发生）
      below.removeFirst(rest * rowBytes)
      belowHashes.removeFirst(rest)
      anchor += rest
    }
    top += count
  }

  /// 画布上 range 这些行拼成图；every > 1 时每隔几行取一行（预览用）
  private func image(of range: Range<Int>, every step: Int = 1) -> CGImage? {
    let rows = stride(from: range.lowerBound, to: range.upperBound, by: step)
    let count = (range.count + step - 1) / step
    guard count > 0 else { return nil }
    var data = Data(capacity: count * rowBytes)
    for row in rows {
      withRow(row) { data.append($0.assumingMemoryBound(to: UInt8.self), count: rowBytes) }
    }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width, height: count, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// BGRA 预乘（ScreenCaptureKit 默认的排列，画进来不用转换）
  private static let bitmapInfo =
    CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

  // MARK: 帧

  private struct Frame {
    /// 第 0 行是图的顶行
    let pixels: [UInt8]
    let hashes: [Int]
    let solid: [Bool]
    /// 行哈希 → 行号：只收非纯色、在本帧里出现不超过 maxRepeat 次的行
    let lookup: [Int: [Int]]
    /// 在本帧里出现太多次的行哈希
    let common: Set<Int>

    init?(_ image: CGImage, width: Int, height: Int, compared: Int, space: CGColorSpace) {
      guard image.width == width, image.height == height else { return nil }
      let rowBytes = width * 4
      var pixels = [UInt8](repeating: 0, count: rowBytes * height)
      let drawn = pixels.withUnsafeMutableBytes { buffer in
        guard
          let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: rowBytes, space: space, bitmapInfo: ScrollStitcher.bitmapInfo)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      guard drawn else { return nil }
      var hashes = [Int](repeating: 0, count: height)
      var solid = [Bool](repeating: false, count: height)
      pixels.withUnsafeBytes { buffer in
        for y in 0..<height {
          let row = buffer.baseAddress! + y * rowBytes
          var hasher = Hasher()
          hasher.combine(bytes: UnsafeRawBufferPointer(start: row, count: compared * 4))
          hashes[y] = hasher.finalize()
          solid[y] = memcmp(row + 4, row, compared * 4 - 4) == 0
        }
      }
      var rows: [Int: [Int]] = [:]
      for y in 0..<height where !solid[y] { rows[hashes[y], default: []].append(y) }
      self.pixels = pixels
      self.hashes = hashes
      self.solid = solid
      lookup = rows.filter { $0.value.count <= ScrollStitcher.maxRepeat }
      common = Set(rows.keys.filter { rows[$0]!.count > ScrollStitcher.maxRepeat })
    }
  }
}
