// 长截图拼接（纯逻辑，配单测）：每来一帧选区截图，和上一帧比出纵向位移，把新露出来的行接到长图的上边或下边。
// - 位移：逐行哈希（不看右边滚动条那一条），新帧的每一行去上一帧里找一模一样的行，按行号差投票；最高票至少是
//   第二名的两倍才算对上（重复的表格行、代码行会给好几个位移投票，分不出来就宁可不接）。纯色行、在帧里重复太多次的行
//   （空白、竖线边框）和原地没变的行（吸顶栏、页脚）不投票。AppKit 的界面按整像素滚动，逐行完全相同，先走这条。
//   实测（合成页面，带吸顶栏 / 页脚 / 滚动条 / 动画块 / 光标）零误接；Vision 的平移配准在有吸顶栏时大半算错、
//   置信度却总是 1，不能用。
// - 整行对不上时按竖条分段再投一次（stripeMatch，2026-11-26 issue #57：聊天窗口、Office 类「一直对不上」）：选区里只要有
//   一条不跟着滚、又有内容的竖条——多框进去的一点会话列表 / 桌面、导航窗格、冻结的列、没被右边那条排除掉的浮动滚动条——
//   整行哈希就一行都对不上，只剩容差投票。每 `stripe` 像素宽一段各自哈希、各自投票（规矩同整行），不动的段原地没变不投票，
//   滚动条那一段对不上也只少它那几票；画布里找位置同样按段。
// - 网页内核的界面（Claude、Chrome、VS Code……）滚动停在小数像素上，文字按小数位置重画，滚过之后有字的行没有一行
//   逐字节相同（2026-10-17）：逐字节和画布里都找不到时，再按每行的分段亮度和容差投票（fuzzyMatch，规矩同上）。
//   容差投票只比两帧之间在动的那几段（2026-10-29 用户报「电脑上的移动端网页完全识别不到」）：移动端版式两边的灰底留白、
//   固定的侧栏、开着的开发者工具原地不动，算进去时对的位移也对不上（侧栏的字不跟着滚）、错的位移又处处一样（留白）。
//   「有字」看这一行和上下行有没有差别，不看左右有没有起伏：留白和内容的分界每行都在，按左右看空白行也成了有字。
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
// - 在动的那一块（2026-11-13）：累计真滚过的那些帧里变过的行 / 列（没滚时原地变的不算），取最长的连续一段
//   （`movingRows` / `movingColumns`）。
//   选区里嵌着一个小滚动区（页面里的一块列表、对话记录）时，两帧之间能接上的位移只和这一块有关，不是选区高——
//   长截图会话按它算自动滚动的领先上限（`ScrollCapture.room`）、把滚轮对准这一块（`aimAtBand`）。

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
  /// 画布每行每一段的哈希（一行 stripes 个连着存），和 above / below 同样的两段、同样的行序（relocate 用）
  private var aboveStripes: [Int] = []
  private var belowStripes: [Int]
  private let stripes: Int
  /// 最近往哪头接过（回弹只修这头）
  private var lastGrown: Edge?

  private enum Edge { case top, bottom }

  /// 一行在帧里出现超过这么多次就不投票（空白里的竖线边框、重复的代码行）
  nonisolated private static let maxRepeat = 8
  /// 分段投票每段多宽（像素，最右一段连着余下的）：一条不动的竖条只毁掉它所在的一两段；窄了碰巧相同的段变多
  nonisolated private static let stripe = 128
  /// 「在动的那一块」里允许隔几行没变：块里空了白的行、行间留白滚过去还是白的，不算「变过」，
  /// 不连起来的话量出来的这一块会小一半（2026-11-13 实测：每 20 行一段字、6 行空白，80 行的一块只量出 14 行）
  private static let bandGap = 32
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
  /// 容差匹配（fuzzyMatch）：每行按这么宽（像素）一段求亮度和；某个位移下每像素平均差不超过 fuzzyTolerance 级亮度的行
  /// 算一票；票数还要占重叠部分有字行的这个比例。和上一行或下一行在某一段上差出 inkLevels 级（每像素平均）的行才算有字
  nonisolated private static let bin = 16
  private static let fuzzyTolerance = 2
  private static let fuzzyShare = 0.5
  nonisolated private static let inkLevels = 3

  /// 长图当前的高度（像素）
  var outputHeight: Int { bottom - top }
  /// 最近是往上接的（往上翻聊天记录）：自动滚动跟着往上、预览显示顶上那头
  var isGrowingUp: Bool { lastGrown == .top }
  /// 最近一次对上时的位移（像素，> 0 是往下滚）：自动滚动据此校准滚轮方向
  private(set) var lastShift = 0

  /// 最近一帧每一步投票的最高票（诊断日志用，只有数、没有画面内容）：哪一步、位移、票数、第二名、参与投票的
  /// （整行 / 分段是行或段的个数）。步骤名：rows 整行、stripes 分段、canvas 在画布里找、fuzzy 容差
  struct Attempt: CustomStringConvertible {
    let step: String
    let dy: Int
    let votes: Int
    let second: Int
    let voters: Int
    var description: String { "\(step) dy=\(dy) \(votes)/\(second)/\(voters)" }
  }
  private(set) var attempts: [Attempt] = []

  /// 画面里真正在动的那一块（像素行）：会话里累计「真滚过的帧里变过的行」中最长的连续一段（中间最多隔 bandGap 行）。
  /// 长截图会话按它算自动滚动最多能领先多少——选区里嵌着一个小滚动区时，两帧之间能接上的位移只和这一块有关，
  /// 按选区高算就会一次滚过这块、一直「对不上」（2026-11-13 用户报）。空着 = 还没量出来，按整个选区算
  private(set) var movingRows = 0..<0
  /// 同上，横向（像素列）：只在 tracksColumns 时统计
  private(set) var movingColumns = 0..<0
  /// 自动滚动时由会话打开：要把滚轮落进在动的那一块，得知道它的左右边界（手动滚的落点由用户的光标定，不用算）
  var tracksColumns = false
  /// 累计变过的行、列（列按 bin 一段：一列要变就整段变）
  private var movedRows: [Bool]
  private var movedColumns: [Bool]

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
    let bins = compared / ScrollStitcher.bin
    guard height > 1, maxHeight >= height,
      let frame = Frame(
        first, layout: Layout(width: width, height: height, compared: compared, space: colorSpace))
    else { return nil }
    movedRows = [Bool](repeating: false, count: height)
    movedColumns = [Bool](repeating: false, count: bins)
    reference = frame
    below = frame.pixels
    belowStripes = frame.stripeHashes
    stripes = frame.stripes
    bottom = height
  }

  /// 换一张第一帧（长截图还没开始滚、也没拼上过东西时画面变了：被截的 App 刚拿回焦点、悬停、重画，issue #57）：
  /// 画布、位置、在动的那一块都从这一帧重来。尺寸不对（nil）不换
  mutating func restart(from frame: Frame?) {
    guard let frame else { return }
    reference = frame
    referenceTop = 0
    (top, bottom, anchor) = (0, height, 0)
    above = []
    aboveStripes = []
    below = frame.pixels
    belowStripes = frame.stripeHashes
    lastGrown = nil
    lastShift = 0
    movedRows = [Bool](repeating: false, count: height)
    movedColumns = [Bool](repeating: false, count: movedColumns.count)
    (movingRows, movingColumns) = (0..<0, 0..<0)
  }

  /// 接一帧（尺寸必须和第一帧相同）：当场算帧再接（单测、截图自检用；长截图会话在主线程外算帧，见 frame(_:layout:)）
  mutating func add(_ image: CGImage) -> Outcome {
    add(Frame(image, layout: layout))
  }

  /// 算一帧要的东西（拷像素、逐行哈希、分段亮度和）只看这几样，带到主线程外去算
  nonisolated struct Layout: Sendable {
    let width: Int
    let height: Int
    let compared: Int
    let space: CGColorSpace
  }

  var layout: Layout { Layout(width: width, height: height, compared: compared, space: colorSpace) }

  /// 在主线程外算好一帧（第四轮体检 F1：一帧要拷几 MB 像素、逐行哈希，长截图静止时原来也每秒在主线程上算 25 帧；
  /// mac-native §3 第 1 类 hash）。接到长图上（add）仍在主线程、按截的先后来，拼出来的和当场算的一样
  @concurrent nonisolated static func frame(_ image: CGImage, layout: Layout) async -> Frame? {
    Frame(image, layout: layout)
  }

  /// 接一帧算好的（nil：尺寸不对、画不进位图）
  mutating func add(_ frame: Frame?) -> Outcome {
    attempts = []
    guard let frame else { return .lost }
    let a = reference.hashes
    let b = frame.hashes
    let changed = (0..<height).count { a[$0] != b[$0] }
    guard changed > 0 else { return .unchanged }
    var found =
      Self.match(from: reference, to: frame, attempts: &attempts)
      ?? Self.stripeMatch(from: reference, to: frame, attempts: &attempts)
    if found == nil {
      let ink = (0..<height).count { reference.ink[$0] }
      let still = (0..<height).count { reference.ink[$0] && a[$0] == b[$0] }
      if Double(changed) < Self.quietShare * Double(height)
        || Double(still) > Self.stillShare * Double(ink)
      {
        return .unchanged
      }
      found =
        relocate(frame, attempts: &attempts)
        ?? Self.fuzzyMatch(from: reference, to: frame, attempts: &attempts)
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
    noteMoved(frame)
    reference = frame
    referenceTop = position
    lastShift = dy
    return .moved(grown: outputHeight - before)
  }

  // MARK: 在动的那一块

  /// 这一帧真滚过了（对上了、位移不是 0）：把和上一帧比变过的行 / 列记进去。没滚时原地变的（光标闪烁、悬停高亮、
  /// 选区里在放的动画 / 视频）不记——不然一开自动滚动，光标就被挪到动画上，滚的不是用户指着的那一块
  private mutating func noteMoved(_ frame: Frame) {
    var grew = false
    for row in 0..<height where reference.hashes[row] != frame.hashes[row] {
      if !movedRows[row] {
        movedRows[row] = true
        grew = true
      }
      guard tracksColumns else { continue }
      let base = row * frame.bins
      for bin in 0..<frame.bins
      where !movedColumns[bin] && frame.profile[base + bin] != reference.profile[base + bin] {
        movedColumns[bin] = true
        grew = true
      }
    }
    if grew { bandGrew() }
  }

  /// 累计变过的范围长大了：重算在动的那一块（行、列分开算）
  private mutating func bandGrew() {
    movingRows = Self.largestRun(movedRows, gap: Self.bandGap)
    let columns = Self.largestRun(movedColumns, gap: 1)
    if !columns.isEmpty {
      movingColumns = (columns.lowerBound * Self.bin)..<(columns.upperBound * Self.bin)
    }
  }

  /// moved 里最长的连续一段（中间最多隔 gap 个没动的位置）：光标闪烁、页脚里走的秒表只是零星的几行，
  /// 连不成一段，不会把「在动的那一块」撑成整个选区。纯函数，配单测
  static func largestRun(_ moved: [Bool], gap: Int) -> Range<Int> {
    var best = 0..<0
    var start = -1
    var last = -1
    for (row, isMoved) in moved.enumerated() where isMoved {
      if start < 0 || row - last > gap + 1 {
        if start >= 0, last - start + 1 > best.count { best = start..<(last + 1) }
        start = row
      }
      last = row
    }
    if start >= 0, last - start + 1 > best.count { best = start..<(last + 1) }
    return best
  }

  /// 拼好的长图
  func makeImage() -> CGImage? { image(of: top..<bottom) }

  /// 长图现在占的行（绝对行号，往上接时往负数长；`preview` 和 `previewRange` 的 from 是同一套坐标）
  var rows: Range<Int> { top..<bottom }

  /// 预览：宽 width 像素，最高 maxHeight 像素；长图更高时取 from 起的那一段（nil = 最近接的那头）。
  /// 缩得越小隔的行越多（选区很宽时整张长图都在预览里，逐行拷贝要上百 MB）
  func preview(width: Int, maxHeight: Int, from: Int? = nil) -> CGImage? {
    guard width > 0, maxHeight > 0 else { return nil }
    let scale = Double(width) / Double(self.width)
    let range = previewRange(width: width, maxHeight: maxHeight, from: from)
    guard !range.isEmpty else { return nil }
    let height = max(Int((Double(range.count) * scale).rounded()), 1)
    guard let source = image(of: range, every: max(Int(1 / scale), 1)),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: Self.bitmapInfo)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  /// 这个预览框现在显示长图的哪一段（绝对行号）：面板按它算滚轮走多少、位置指示条画在哪
  func previewRange(width: Int, maxHeight: Int, from: Int?) -> Range<Int> {
    guard width > 0, maxHeight > 0 else { return top..<top }
    let scale = Double(width) / Double(self.width)
    return Self.previewRange(
      rows: rows, visible: Int(Double(maxHeight) / scale), from: from, growingUp: isGrowingUp)
  }

  /// 预览取哪一段：visible 是预览里放得下多少行，from 是起始行（nil = 跟着最近接的那头，长图整张放得下时
  /// 两头一样），夹进长图范围。纯函数，配单测
  static func previewRange(rows: Range<Int>, visible: Int, from: Int?, growingUp: Bool)
    -> Range<Int>
  {
    let count = min(rows.count, max(visible, 0))
    guard count > 0 else { return rows.lowerBound..<rows.lowerBound }
    guard let from else {
      return growingUp
        ? rows.lowerBound..<(rows.lowerBound + count) : (rows.upperBound - count)..<rows.upperBound
    }
    let start = min(max(from, rows.lowerBound), rows.upperBound - count)
    return start..<(start + count)
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

  /// 票数最高的那个位移（同票取靠前的），和离它 exclude 以外的位移里票最多的。逐字节比时两行以内的位移也不算第二名
  /// （exclude 2，同容差投票）：一样的几行空白给相邻位移也投了票；字和网格线在小数位置上各自取整时，内容分别走了
  /// dy - 1、dy、dy + 1（2026-11-26 WPS 表格实测 315 对 312 票），都是同一处对法，按「第二名」算就永远不够两倍。
  /// 这时接缝最多差一两行
  private static func best(_ tally: [Int], exclude: Int = 0) -> (
    index: Int, votes: Int, second: Int
  )? {
    guard let peak = tally.indices.max(by: { tally[$0] < tally[$1] }) else { return nil }
    let second = tally.indices.lazy.filter { abs($0 - peak) > exclude }.map { tally[$0] }.max() ?? 0
    return (peak, tally[peak], second)
  }

  /// 分段投票时算比例的那些段（行号 × stripes + 段号）：去掉在这个位移下整条几乎一票都没有的段——它不跟着滚
  /// （混着一截不动的桌面、会话列表的那一段），本来就对不上，算进分母会把对的位移拉到比例以下。
  /// 调用方另要求留下的不是空的：每条段都几乎没票（碰巧几段一样）时全被去掉，比例就失去意义了。不按投票的个数要求
  /// 留下多少：混着一截桌面的那条段每一行都有内容、每一行都投票，个数反而比别的段多
  private static func living(_ overlap: [Int], stripes: Int, matched: (Int) -> Bool) -> [Int] {
    var total = [Int](repeating: 0, count: stripes)
    var hits = [Int](repeating: 0, count: stripes)
    for key in overlap {
      total[key % stripes] += 1
      if matched(key) { hits[key % stripes] += 1 }
    }
    return overlap.filter { hits[$0 % stripes] * 10 > total[$0 % stripes] }
  }

  /// b 相对 a 对上了没有（整行比）
  private static func match(from a: Frame, to b: Frame, attempts: inout [Attempt]) -> Match? {
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
    guard let top = best(tally, exclude: 2) else { return nil }
    let (peak, votes, second) = top
    let dy = peak - height
    attempts.append(
      Attempt(step: "rows", dy: dy, votes: votes, second: second, voters: voters.count))
    // 重叠部分里能对上的：落到上一帧原地没动的行上的（吸顶栏、页脚）本来就对不上，不算进比例（一下滚过大半屏时
    // 重叠部分有一大截压在页脚上，算进去的话对的位移也凑不够比例）
    let overlap = voters.filter {
      (0..<height).contains($0 + dy) && a.hashes[$0 + dy] != b.hashes[$0 + dy]
    }
    guard dy != 0, votes >= minVotes, votes >= minLead * second,
      Double(votes) >= minShare * Double(overlap.count)
    else { return nil }
    let matched = overlap.filter { b.hashes[$0] == a.hashes[$0 + dy] }
    return Match(
      dy: dy, overlap: max(0, -dy)..<min(height, height - dy), first: matched.first ?? 0,
      last: matched.last ?? height - 1)
  }

  /// 整行对不上时按段比（规矩同 match，一行里的每一段各算一个投票的）：不动的竖条（会话列表、导航窗格、冻结的列、
  /// 选区边上框进去的一点桌面）原地没变不投票，选区中间的浮动滚动条只少它那一段的票
  private static func stripeMatch(from a: Frame, to b: Frame, attempts: inout [Attempt]) -> Match? {
    let height = a.hashes.count
    let stripes = a.stripes
    guard stripes > 1 else { return nil }  // 只有一段就是整行，match 已经比过了
    // 投票的段（行号 × stripes + 段号）
    var voters: [Int] = []
    var tally = [Int](repeating: 0, count: 2 * height + 1)
    for key in 0..<(height * stripes) {
      let stripe = key % stripes
      let hash = b.stripeHashes[key]
      guard !b.stripeSolid[key], hash != a.stripeHashes[key],
        !a.stripeCommon[stripe].contains(hash), !b.stripeCommon[stripe].contains(hash)
      else { continue }
      voters.append(key)
      let i = key / stripes
      for j in a.stripeLookup[stripe][hash] ?? [] { tally[j - i + height] += 1 }
    }
    guard let top = best(tally, exclude: 2) else { return nil }
    let (peak, votes, second) = top
    let dy = peak - height
    attempts.append(
      Attempt(step: "stripes", dy: dy, votes: votes, second: second, voters: voters.count))
    let overlap = voters.filter {
      (0..<height).contains($0 / stripes + dy)
        && a.stripeHashes[$0 + dy * stripes] != b.stripeHashes[$0 + dy * stripes]
    }
    func hit(_ key: Int) -> Bool { b.stripeHashes[key] == a.stripeHashes[key + dy * stripes] }
    let counted = living(overlap, stripes: stripes, matched: hit)
    guard dy != 0, votes >= minVotes, votes >= minLead * second, !counted.isEmpty,
      Double(votes) >= minShare * Double(counted.count)
    else { return nil }
    let matched = overlap.filter(hit)
    return Match(
      dy: dy, overlap: max(0, -dy)..<min(height, height - dy),
      first: matched.first.map { $0 / stripes } ?? 0,
      last: matched.last.map { $0 / stripes } ?? height - 1)
  }

  /// 和上一帧对不上时，在整张画布里找 b 的位置（按段投票，规矩同 stripeMatch；原地没变的段是吸顶栏、页脚、不动的竖条，
  /// 照样不投）。找到的位置可以就是上一帧的位置（dy == 0）：画布上那几行是更早的帧留下的，和上一帧不一样（悬停高亮挪走了）
  private func relocate(_ b: Frame, attempts: inout [Attempt]) -> Match? {
    let rows = bottom - top
    // 投票的段（行号 × stripes + 段号），每一条段一张「哈希 → 行号」表
    var voters: [Int] = []
    var lookup = [[Int: [Int]]](repeating: [:], count: stripes)
    for key in 0..<(height * stripes) {
      let stripe = key % stripes
      let hash = b.stripeHashes[key]
      guard !b.stripeSolid[key], hash != reference.stripeHashes[key],
        !b.stripeCommon[stripe].contains(hash)
      else { continue }
      voters.append(key)
      lookup[stripe][hash, default: []].append(key / stripes)
    }
    // 画布第 j 行（从 top 数）的某一段和 b 第 i 行的同一段一样：给「b 的第 0 行在画布第 j - i 行」投一票
    var tally = [Int](repeating: 0, count: rows + height)
    for j in 0..<rows {
      for stripe in 0..<stripes {
        for i in lookup[stripe][canvasStripe(top + j, stripe)] ?? [] { tally[j - i + height] += 1 }
      }
    }
    guard let best = Self.best(tally, exclude: 2) else { return nil }
    let (peak, votes, second) = best
    let offset = peak - height
    attempts.append(
      Attempt(
        step: "canvas", dy: top + offset - referenceTop, votes: votes, second: second,
        voters: voters.count))
    let range = max(0, -offset)..<min(height, rows - offset)
    let overlap = voters.filter { range.contains($0 / stripes) }
    func hit(_ key: Int) -> Bool {
      b.stripeHashes[key] == canvasStripe(top + offset + key / stripes, key % stripes)
    }
    let counted = Self.living(overlap, stripes: stripes, matched: hit)
    guard votes >= Self.minVotes, votes >= Self.minLead * second,
      !counted.isEmpty,
      Double(votes) >= Self.relocateShare * Double(counted.count),
      Double(votes) >= Self.relocateCover * Double(voters.count)
    else { return nil }
    let matched = overlap.filter(hit)
    return Match(
      dy: top + offset - referenceTop, overlap: range,
      first: matched.first.map { $0 / stripes } ?? range.lowerBound,
      last: matched.last.map { $0 / stripes } ?? range.upperBound - 1)
  }

  /// 逐字节对不上时和上一帧比的退路：滚动停在小数像素上的界面（网页内核的 App：Claude、Chrome、VS Code……2026-10-17
  /// 用户在 macOS 27 上报「一直对不上」，实测滚过之后有字的行没有一行逐字节相同，最佳整像素位移下每像素平均差 0.2–1 级）
  /// 文字按小数位置重画，抗锯齿的边每帧都不一样。按每行的分段亮度和比：某个位移下每像素平均差不超过 fuzzyTolerance 级的
  /// 有字行算一票，规矩同 match（原地没变的行不投），另要占重叠部分有字行的 fuzzyShare；第二名只算离开最高票 3 行以上的
  /// （小数位移让相邻一两行也对得上）。真实帧上对的位移拿七成以上的票，第二名不到它的四分之一；一次约 15 ms。
  /// 「落在两行之间」两个方向都认（2026-11-26 issue #57）：上一帧停在小数位置（字是糊开的）、这一帧停在整像素（字是实的）时，
  /// 新帧的行不在上一帧任何两行之间，倒过来上一帧的行在新帧两行之间——只认一个方向时往上翻一半对不上。
  /// 整像素滚动时相邻两个位移（dy - 1 落在后一行上、dy 落在前一行上）票一样多，取后一个（原来取前一个，每道接缝多一行）。
  /// ponytail: 两个方向都比，一帧彻底对不上时要多花一倍（Release 整屏 3420 × 1982 的合成长文从约 190 ms 到约 360 ms，
  /// 先比总和筛掉一部分；1035 × 1079 的选区约 30 ms，接上的帧不受影响，1–2 ms）。整屏选区连着对不上时界面会顿；
  /// 真碰到再先用每行总和的互相关挑出几个候选位移、只对它们逐段比
  private static func fuzzyMatch(from a: Frame, to b: Frame, attempts: inout [Attempt]) -> Match? {
    let height = a.ink.count
    let bins = a.bins
    // 在动的段：两帧同一位置上变了的行超过二十分之一。原地没变的（留白、固定侧栏、开发者工具；只有光标在闪的也算）不比
    let moving = (0..<bins).filter { k in
      (0..<height).count { a.profile[$0 * bins + k] != b.profile[$0 * bins + k] } > height / 20
    }
    guard !moving.isEmpty else { return nil }
    // 有字：在动的段里和上一行或下一行差出 inkLevels 级（同 Frame.ink，只看这几段）。
    // 隔一行取一行投票：票数的比例不变、快一倍；对上的首尾行最多差一行，页脚和吸顶栏只会估大（宁大勿小）
    let spread = Int32(inkLevels * bin * 4)
    func varies(_ y: Int) -> Bool {
      moving.contains { k in
        let value = b.profile[y * bins + k]
        return (y > 0 && abs(value - b.profile[(y - 1) * bins + k]) > spread)
          || (y + 1 < height && abs(value - b.profile[(y + 1) * bins + k]) > spread)
      }
    }
    let voters = stride(from: 0, to: height, by: 2).filter {
      b.hashes[$0] != a.hashes[$0] && varies($0)
    }
    let limit = Int32(fuzzyTolerance * bin * 4 * moving.count)
    // b 的第 i 行停在 a 的第 j 行和第 j + 1 行之间（滚了 dy + 一个小数）：每段亮度应落在这两行之间，只算超出的部分；
    // 或者倒过来，a 的第 j 行停在 b 的第 i - 1 行和第 i 行之间。每行的上下界先算好
    func envelope(_ profile: [Int32], next: Int) -> (low: [Int32], high: [Int32]) {
      var low = profile
      var high = profile
      for index in max(0, -next)..<(profile.count - max(next, 0)) {
        low[index] = min(low[index], profile[index + next])
        high[index] = max(high[index], profile[index + next])
      }
      return (low, high)
    }
    let (low, high) = envelope(a.profile, next: bins)
    let (lowB, highB) = envelope(b.profile, next: -bins)
    // 每行在动的那几段加起来：逐段超出的加起来至少是总和超出的那么多，先比总和能筛掉一大半（两个方向都比之后，
    // 一帧彻底对不上时整屏要多花一倍，加了这一步比原来只比一个方向还快）
    func totals(_ values: [Int32]) -> [Int32] {
      (0..<height).map { y in moving.reduce(0) { $0 + values[y * bins + $1] } }
    }
    let (totalA, totalB) = (totals(a.profile), totals(b.profile))
    let (lowTotal, highTotal) = (totals(low), totals(high))
    let (lowTotalB, highTotalB) = (totals(lowB), totals(highB))
    func within(_ rows: [Int32], _ v: Int, _ low: [Int32], _ high: [Int32], _ e: Int) -> Bool {
      var sum: Int32 = 0
      for k in moving {
        let value = rows[v * bins + k]
        sum += max(low[e * bins + k] - value, value - high[e * bins + k], 0)
        if sum > limit { return false }
      }
      return true
    }
    func close(_ i: Int, _ j: Int) -> Bool {
      (totalB[i] >= lowTotal[j] - limit && totalB[i] <= highTotal[j] + limit
        && within(b.profile, i, low, high, j))
        || (totalA[j] >= lowTotalB[i] - limit && totalA[j] <= highTotalB[i] + limit
          && within(a.profile, j, lowB, highB, i))
    }
    var tally = [Int](repeating: 0, count: 2 * height)
    for dy in (1 - height)..<height where dy != 0 {
      for i in voters where (0..<height).contains(i + dy) && close(i, i + dy) {
        tally[dy + height] += 1
      }
    }
    guard let top = best(tally, exclude: 2) else { return nil }
    var (peak, votes) = (top.index, top.votes)
    let second = top.second
    // 下一个位移的票差不多一样多：真位移在这两个中间（整像素），取后一个
    if peak + 1 < tally.count, tally[peak + 1] * 10 >= votes * 9 {
      peak += 1
      votes = tally[peak]
    }
    let dy = peak - height
    attempts.append(
      Attempt(step: "fuzzy", dy: dy, votes: votes, second: second, voters: voters.count))
    let overlap = voters.filter { (0..<height).contains($0 + dy) }
    guard dy != 0, votes >= minVotes, votes >= minLead * second,
      Double(votes) >= fuzzyShare * Double(overlap.count)
    else { return nil }
    let matched = overlap.filter { close($0, $0 + dy) }
    return Match(
      dy: dy, overlap: max(0, -dy)..<min(height, height - dy), first: matched.first ?? 0,
      last: matched.last ?? height - 1)
  }

  /// 画布第 row 行第 stripe 段的哈希
  private func canvasStripe(_ row: Int, _ stripe: Int) -> Int {
    row >= anchor
      ? belowStripes[(row - anchor) * stripes + stripe]
      : aboveStripes[(anchor - 1 - row) * stripes + stripe]
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
    belowStripes.append(
      contentsOf: frame.stripeHashes[(rows.lowerBound * stripes)..<(rows.upperBound * stripes)])
    bottom += rows.count
  }

  /// rows 按从上到下给，倒着塞进 above
  private mutating func prependTop(_ frame: Frame, rows: Range<Int>) {
    for row in rows.reversed() {
      above.append(contentsOf: frame.pixels[(row * rowBytes)..<((row + 1) * rowBytes)])
      aboveStripes.append(
        contentsOf: frame.stripeHashes[(row * stripes)..<((row + 1) * stripes)])
    }
    top -= rows.count
  }

  private mutating func removeBottom(_ count: Int) {
    let fromBelow = min(count, below.count / rowBytes)
    below.removeLast(fromBelow * rowBytes)
    belowStripes.removeLast(fromBelow * stripes)
    let rest = count - fromBelow
    if rest > 0 {  // below 已经空了：接着删 above 里挨着 anchor 的行
      above.removeFirst(rest * rowBytes)
      aboveStripes.removeFirst(rest * stripes)
      anchor -= rest
    }
    bottom -= count
  }

  private mutating func removeTop(_ count: Int) {
    let fromAbove = min(count, above.count / rowBytes)
    above.removeLast(fromAbove * rowBytes)
    aboveStripes.removeLast(fromAbove * stripes)
    let rest = count - fromAbove
    if rest > 0 {  // above 已经空了：接着删 below 开头的行（只在第一次往上接时发生）
      below.removeFirst(rest * rowBytes)
      belowStripes.removeFirst(rest * stripes)
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
  nonisolated private static let bitmapInfo =
    CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

  // MARK: 帧

  /// 一行像素的哈希（只在一次会话里比相等，不用随机种子）：每次吃 8 字节，左旋 5 位、异或、乘一个奇数常数（FxHash 的
  /// 做法），最后把高半截折进低半截。比系统的 Hasher（SipHash）快好几倍：整窗口 3420 × 1982 的一帧算帧从 22 ms 到 10 ms
  /// （2026-11-12，选区大了常对不上：一轮越短两帧之间滚得越少）
  nonisolated static func rowHash(_ row: UnsafeRawPointer, count: Int) -> Int {
    let multiplier: UInt64 = 0x517c_c1b7_2722_0a95
    var hash: UInt64 = 0
    var offset = 0
    while offset + 8 <= count {
      hash = (hash << 5 | hash >> 59) ^ row.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
      hash &*= multiplier
      offset += 8
    }
    while offset < count {
      hash = (hash << 5 | hash >> 59) ^ UInt64(row.load(fromByteOffset: offset, as: UInt8.self))
      hash &*= multiplier
      offset += 1
    }
    return Int(bitPattern: UInt(hash ^ hash >> 32))
  }

  /// 算好的一帧（值类型，能从主线程外带回来）
  nonisolated struct Frame: Sendable {
    /// 第 0 行是图的顶行
    let pixels: [UInt8]
    let hashes: [Int]
    let solid: [Bool]
    /// 行哈希 → 行号：只收非纯色、在本帧里出现不超过 maxRepeat 次的行
    let lookup: [Int: [Int]]
    /// 在本帧里出现太多次的行哈希
    let common: Set<Int>
    /// 容差匹配用：每行 bins 段的亮度和（B + 2G + R，只看比较的列），按行连着存；ink 是这一行和上下行有差别
    /// （有字；纯色、大块同色底和只差一两级的渐变底不算）
    let bins: Int
    let profile: [Int32]
    let ink: [Bool]
    /// 分段投票用：每行 stripes 段（每段 stripe 像素宽，最右一段连着余下的）的哈希、是不是纯色，按行连着存；
    /// 每一条段一张「哈希 → 行号」表（规矩同 lookup / common）
    let stripes: Int
    let stripeHashes: [Int]
    let stripeSolid: [Bool]
    let stripeLookup: [[Int: [Int]]]
    let stripeCommon: [Set<Int>]

    init?(_ image: CGImage, layout: Layout) {
      let (width, height, compared, space) = (
        layout.width, layout.height, layout.compared, layout.space
      )
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
      let bin = ScrollStitcher.bin
      let bins = compared / bin
      var profile = [Int32](repeating: 0, count: bins * height)
      let stripe = ScrollStitcher.stripe
      let stripes = max(compared / stripe, 1)
      var stripeHashes = [Int](repeating: 0, count: stripes * height)
      var stripeSolid = [Bool](repeating: false, count: stripes * height)
      pixels.withUnsafeBytes { buffer in
        let bytes = buffer.bindMemory(to: UInt8.self)
        for y in 0..<height {
          let row = buffer.baseAddress! + y * rowBytes
          // 整行的哈希由各段的合成（同 rowHash 的做法），不再把整行另算一遍
          var whole: UInt64 = 0
          for s in 0..<stripes {
            let start = s * stripe * 4
            let count = (s == stripes - 1 ? compared : (s + 1) * stripe) * 4 - start
            let hash = ScrollStitcher.rowHash(row + start, count: count)
            stripeHashes[y * stripes + s] = hash
            stripeSolid[y * stripes + s] = memcmp(row + start + 4, row + start, count - 4) == 0
            whole = (whole << 5 | whole >> 59) ^ UInt64(UInt(bitPattern: hash))
            whole &*= 0x517c_c1b7_2722_0a95
          }
          hashes[y] = Int(bitPattern: UInt(whole ^ whole >> 32))
          solid[y] = memcmp(row + 4, row, compared * 4 - 4) == 0
          for k in 0..<bins {
            var sum: Int32 = 0
            var offset = y * rowBytes + k * bin * 4
            for _ in 0..<bin {
              sum += Int32(bytes[offset]) + 2 * Int32(bytes[offset + 1]) + Int32(bytes[offset + 2])
              offset += 4
            }
            profile[y * bins + k] = sum
          }
        }
      }
      // 有字：和上一行或下一行在某一段上差出 inkLevels 级（竖着有起伏）
      let inkSpread = Int32(ScrollStitcher.inkLevels * bin * 4)
      var edge = [Bool](repeating: false, count: height + 1)  // 第 y 行和第 y - 1 行不一样
      for y in 1..<max(height, 1) {
        edge[y] = (0..<bins).contains { k in
          abs(profile[y * bins + k] - profile[(y - 1) * bins + k]) > inkSpread
        }
      }
      let ink = (0..<height).map { edge[$0] || edge[$0 + 1] }
      var rows: [Int: [Int]] = [:]
      for y in 0..<height where !solid[y] { rows[hashes[y], default: []].append(y) }
      self.pixels = pixels
      self.hashes = hashes
      self.solid = solid
      lookup = rows.filter { $0.value.count <= ScrollStitcher.maxRepeat }
      common = Set(rows.keys.filter { rows[$0]!.count > ScrollStitcher.maxRepeat })
      self.bins = bins
      self.profile = profile
      self.ink = ink
      var segments = [[Int: [Int]]](repeating: [:], count: stripes)
      for key in 0..<(stripes * height) where !stripeSolid[key] {
        segments[key % stripes][stripeHashes[key], default: []].append(key / stripes)
      }
      self.stripes = stripes
      self.stripeHashes = stripeHashes
      self.stripeSolid = stripeSolid
      stripeLookup = segments.map { $0.filter { $0.value.count <= ScrollStitcher.maxRepeat } }
      stripeCommon = segments.map { table in
        Set(table.keys.filter { table[$0]!.count > ScrollStitcher.maxRepeat })
      }
    }
  }
}
