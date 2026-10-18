// 便签正文里的图片附件（第 7 批；令牌在 NoteImages.swift，图片目录在 NoteImageStore.swift，编辑器接线在
// NoteTextView.swift / NoteTextView+Images.swift）。存的正文里图片是文字令牌，**载入编辑器时换成附件字符 U+FFFC**
// （NSTextAttachment + 自己的 NSTextAttachmentCell），存盘时换回令牌。样机（屏外、同一套 TextKit 1）比过：附件字符的
// 光标 / 选区命令一次都不会落进图片内部、点图落在图前、图片后 ⌫ 整张删掉、撤销一步，隐藏令牌 + 盖视图那条路这些都不行。
// - 尺寸：cell 重写 `cellFrame(for:proposedLineFragment:glyphPosition:characterIndex:)`（**挂了 cell 的附件走这一条，
//   附件的 attachmentBounds 不被调到**），按「行片段宽 − 两边的 lineFragmentPadding − 这一行的缩进（引用 / 代码块的
//   head / tail indent）− 字形横位置」算可用宽：没记宽度就跟着正文框宽变（不超过原图点宽），记了宽度的超出可用宽时缩到
//   可用宽，最小 40（只管记了宽度和拖把手的）。比正文宽的图**不再被压扁、也不再往上盖住前面的字**（F3）。
//   cell 的框比图多出上下各 padding，图在正中；这一行的高由布局代理按 cell 撑（NoteStyles.centerLine）。
// - 画：缩略图有了就画（圆角），没有先画一块纸色（不是空白一闪），文件不在画占位框（虚线框 + 图标 +「图片找不到了」）。
//   选中描边和右下角的拖动把手由文本视图画（NoteTextView.drawImageChrome：把手要能命中，画在字和选区上面）。
// - 缩略图在 @concurrent 里用 ImageIO 解（带 EXIF 方向、显示那么大的像素），解好回主线程只失效那张图所在的字；
//   解出来的进内存缓存（按像素数算 cost），闲下来放掉（NoteImageThumbnails.discard）。
// - 互转（stored(from:) 和 editorString(from:…)）只在这两个地方拼令牌，别处不许自己拼。
// ponytail: 动图（GIF / APNG）只显示第一帧（ImageIO 的缩略图接口就是这样）；要播就自己按帧驱动图层。

import AppKit
import Synchronization

/// 图片在正文里的尺寸和长相的数值（mac-whisker-notes.mdc「正文里的图片」）
nonisolated enum NoteImageLayout {
  /// 图片那一行上下各留多少（算在 cell 的框里）
  static let padding: CGFloat = 4
  /// 图片四角的圆角
  static let corner: CGFloat = 6
  /// 宽度最小多少（**只管令牌里记了宽度的和拖把手**；没记宽度的图照原图点宽，小图标不被放大糊掉，F21）
  static let minWidth: CGFloat = 40
  /// 文件找不到时占位框的宽（不超过可用宽）和高
  static let placeholderWidth: CGFloat = 200
  static let placeholderHeight: CGFloat = 44
  /// 右下角拖动把手多大
  static let handle: CGFloat = 12
  /// 墙卡片上的缩略图：高上限、和标题之间留多少
  static let thumbnailMaxHeight: CGFloat = 120
  static let thumbnailGap: CGFloat = 8

  /// 这张图显示多大。available：这一行能用的宽（行片段宽 − 两边的内缩 − 这一行的缩进）；
  /// live：拖把手时临时的宽度（只改显示、不改字）
  static func size(
    image: NoteImages.Image, metrics: NoteImageSize?, available: CGFloat, live: CGFloat? = nil
  ) -> CGSize {
    let limit = max(available, 1)
    guard let metrics, metrics.pointSize.width > 0, metrics.pointSize.height > 0 else {
      return CGSize(width: min(placeholderWidth, limit.rounded(.down)), height: placeholderHeight)
    }
    let natural = metrics.pointSize
    // 最小宽度只管「记了宽度的」和「拖把手」：没记宽度的照 min（原图点宽，可用宽）
    let wanted: CGFloat
    let floor: CGFloat
    if let live {
      wanted = live
      floor = minWidth
    } else if let recorded = image.width {
      wanted = CGFloat(recorded)
      floor = minWidth
    } else {
      wanted = natural.width
      floor = 1
    }
    let width = min(max(wanted, floor), limit)
    // 取整**不许超出可用宽**（夹到可用宽时往下取整）：正文框的宽常是小数（380.6），往上取成 381 的话 TextKit 1
    // 在哪一行都放不下这个附件，一行行往下找、永远排不完——主线程卡死、内存涨到几个 GB（复查时随机编辑测试
    // 起始种子 3001 那一批卡在这里：第 7 批评审后的一轮）
    let shown = max(min(width.rounded(), limit.rounded(.down)), 1)
    let height = natural.height * shown / natural.width
    return CGSize(width: shown, height: max(height.rounded(), 1))
  }

  /// 第 index 个字所在段落右边的缩进（代码块的 tail indent；段落样式里是负数，这里给正数，没有给 0）。
  /// 布局时调的（cellFrame）：只读传进来的文本容器背后那份文本存储上的属性（mac-native §3）
  static func tailIndent(at index: Int, in container: NSTextContainer?) -> CGFloat {
    guard let storage = container?.layoutManager?.textStorage, index >= 0, index < storage.length,
      let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil)
        as? NSParagraphStyle
    else { return 0 }
    return max(-style.tailIndent, 0)
  }

  /// 这一行能用的宽：正文可用宽去掉这一行的左右缩进（引用、代码块里的图跟着窄——和 cell 里算的是同一个口径，F3）
  static func availableWidth(_ width: CGFloat, style: NSParagraphStyle) -> CGFloat {
    max(width - style.headIndent + style.tailIndent, 1)
  }

}

/// 一张图在正文里的附件：记着令牌里的那几样和文件在哪。
/// nonisolated：布局管理器读它（附件 cell 的尺寸、画）可能在别的线程上（mac-native §3），字段都是 `let` 的 Sendable 值
nonisolated final class NoteImageAttachment: NSTextAttachment {
  let picture: NoteImages.Image
  let url: URL
  /// 文件头里读出来的尺寸；nil = 文件不在 / 读不出来（画占位框）
  let metrics: NoteImageSize?
  /// 这条便签的纸色（NotePaper.all 的下标）：占位框画在纸上，画的时候按当前外观取色
  let paper: Int

  init(image: NoteImages.Image, url: URL, metrics: NoteImageSize?, paper: Int) {
    self.picture = image
    self.url = url
    self.metrics = metrics
    self.paper = paper
    super.init(data: nil, ofType: nil)
  }

  required init?(coder: NSCoder) { fatalError("便签的图片附件不从归档里读") }

  /// 编辑器里的（带附件的富文本）→ 存的字：附件字符换回令牌，**没挂我们附件的 U+FFFC 原样保留**。
  /// 没有 U+FFFC 的正文（绝大多数）直接原样返回（打字的开销和现在一样）
  static func stored(from attributed: NSAttributedString) -> String {
    let string = attributed.string
    guard string.utf16.contains(0xFFFC) else { return string }
    let text = string as NSString
    var parts: [String] = []
    var last = 0
    attributed.enumerateAttribute(
      .attachment, in: NSRange(location: 0, length: attributed.length)
    ) { value, range, _ in
      guard let attachment = value as? NoteImageAttachment else { return }
      for position in range.location..<NSMaxRange(range)
      where text.character(at: position) == 0xFFFC {
        parts.append(text.substring(with: NSRange(location: last, length: position - last)))
        parts.append(NoteImages.token(attachment.picture))
        last = position + 1
      }
    }
    parts.append(text.substring(from: last))
    return parts.joined()
  }

  /// 存的字 → 编辑器里的富文本：令牌换成附件字符（一个令牌一个字），别的照基础样式。
  /// attachment 由调用方建（要拿图片目录和纸色）。
  /// **代码块里的令牌也换成图**（不按原文）：换的动作在认 Markdown 之前、按位置扫令牌，代码块里的照样换；
  /// 块里那几行其余部分仍旧按原文显示（Markdown 的样式不认块里的字）。见 R5。
  /// ponytail: 升级路径是「代码块里的令牌按原文显示」——要在 `NoteStyles.apply` 里按 `roleKey` 把那几段的附件
  /// 换回令牌（属性层面做不到，得动字），真有人想在代码块里展示令牌原文再做
  static func editorString(
    from stored: String, base: [NSAttributedString.Key: Any],
    attachment: (NoteImages.Image) -> NoteImageAttachment
  ) -> NSMutableAttributedString {
    let result = NSMutableAttributedString()
    let text = stored as NSString
    guard NoteImages.containsToken(stored) else {
      result.append(NSAttributedString(string: stored, attributes: base))
      return result
    }
    var last = 0
    for match in NoteImages.matches(in: text) {
      result.append(
        NSAttributedString(
          string: text.substring(
            with: NSRange(location: last, length: match.range.location - last)),
          attributes: base))
      result.append(NSAttributedString(attachment: attachment(match.image)))
      last = NSMaxRange(match.range)
    }
    result.append(NSAttributedString(string: text.substring(from: last), attributes: base))
    return result
  }
}

/// 图片附件在编辑器里怎么画（缩略图、占位框、无障碍）。布局时调的那几个方法在 SDK 里标了 nonisolated
/// （cellSize / cellFrame / cellBaselineOffset），只读传进来的东西和 `let` 的字段
final class NoteImageAttachmentCell: NSTextAttachmentCell {
  private let picture: NoteImages.Image
  private let url: URL
  private let metrics: NoteImageSize?
  private let paper: Int
  /// 拖把手时临时的宽度（只改显示、不改字；松手才写进正文，Esc 回原样）
  let live = Mutex<CGFloat?>(nil)
  /// 解好缩略图要失效谁（弱引用，不把视图拖住）
  weak var view: NoteTextView?

  init(image: NoteImages.Image, url: URL, metrics: NoteImageSize?, paper: Int) {
    self.picture = image
    self.url = url
    self.metrics = metrics
    self.paper = paper
    super.init(imageCell: nil)
  }

  required init(coder: NSCoder) { fatalError("便签的图片附件不从归档里读") }

  /// 现在的显示宽（拖把手中时是临时的那个）
  var liveWidth: CGFloat? { live.withLock { $0 } }

  nonisolated private func size(available: CGFloat) -> CGSize {
    NoteImageLayout.size(
      image: picture, metrics: metrics, available: available, live: live.withLock { $0 })
  }

  /// 没有行片段可用宽时的尺寸（真的尺寸由 cellFrame 按行片段报）
  nonisolated override func cellSize() -> NSSize {
    let size = size(available: .greatestFiniteMagnitude)
    return NSSize(width: size.width, height: size.height)
  }

  /// 图坐在基线上（图和字同行时字坐在图的底边那条基线上）
  nonisolated override func cellBaselineOffset() -> NSPoint { .zero }

  /// 这一张在行片段里占的那一块：宽按「行片段能用的宽」算（比正文宽的图夹到可用宽、高按比例），
  /// 高 = 图高 + 上下各 padding（图在框里居中）。**挂了 cell 的附件走这一条**（附件的 attachmentBounds 不被调到）：
  /// 默认实现只看 cellSize()（不限可用宽），比正文框宽的图会排成原图大小、盖住前面的字（F3）。
  /// **返回的矩形相对这个字形在基线上的位置**（y 朝上：origin.y = -padding 就是框的底边在基线下面 padding，图的底边正好
  /// 落在基线上），**不是**容器里的绝对坐标——原来写成 `(position.x, position.y - padding)`，position.y 是行片段的 y，
  /// 第一行（y = 0）看不出来，往下的行图被画到上面去、盖住前面的字；当时为了让图看起来在原地，又在布局代理的基线里加了
  /// 行片段的 y，结果图片行上的字被推到行外面看不见（2026-10-17 用户真机报「图片和文字在同一行导致文字不展示了」；
  /// 独立小程序量清楚了 TextKit 1 的解释法：主检出 macos/build/research/notes-images-proto/cellframe-probe.swift）。
  /// position.x 不含行首的 lineFragmentPadding（实测比 `location(forGlyphAt:)` 少 5），算可用宽时左右两边的内缩都要减
  nonisolated override func cellFrame(
    for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect,
    glyphPosition position: NSPoint, characterIndex charIndex: Int
  ) -> NSRect {
    let padding = textContainer?.lineFragmentPadding ?? 0
    // 行片段能用的宽：右边去掉内缩和这一行的 tail indent，再去掉字形已经走过的横位置（行首时 position.x 里已经含 head indent）。
    // tail indent **当场从这个字的段落样式读**（原来是 apply 写在 cell 上的一份：刚粘进来、刚插进代码块的图在 apply
    // 之前就排版，那一份还是 0，算出来的宽比排版器认的多 8 pt，同样在哪一行都放不下、排版死循环）
    let tail = NoteImageLayout.tailIndent(at: charIndex, in: textContainer)
    let available = max(lineFrag.maxX - padding * 2 - tail - position.x, 1)
    let size = size(available: available)
    return NSRect(
      x: 0, y: -NoteImageLayout.padding, width: size.width,
      height: size.height + NoteImageLayout.padding * 2)
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    drawImage(in: cellFrame, controlView: controlView)
  }

  override func draw(
    withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
    layoutManager: NSLayoutManager
  ) {
    drawImage(in: cellFrame, controlView: controlView)
  }

  /// 读屏读到图片时念「图片」（不念 U+FFFC）
  override func accessibilityLabel() -> String? { "图片" }

  // MARK: 画

  private func drawImage(in frame: NSRect, controlView: NSView?) {
    // cell 的框比图多出上下各 padding：图画的框去掉它
    let box = frame.insetBy(dx: 0, dy: NoteImageLayout.padding)
    guard box.width > 0.5, box.height > 0.5 else { return }
    guard metrics != nil else {
      drawPlaceholder(in: box)
      return
    }
    let scale = controlView?.window?.backingScaleFactor ?? 2
    // **长边**取像素（kCGImageSourceThumbnailMaxPixelSize 限的是长边）：竖图不会只解出一半多的分辨率（F7⑥）
    let maxPixel = NoteImageThumbnails.pixel(for: box.size, scale: scale)
    if let thumbnail = NoteImageThumbnails.image(
      for: url, id: picture.id, maxPixel: maxPixel,
      ready: { [weak self] in self?.view?.imageThumbnailArrived(image: self?.picture.id) })
    {
      let path = NSBezierPath(
        roundedRect: box, xRadius: NoteImageLayout.corner, yRadius: NoteImageLayout.corner)
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      NSImage(cgImage: thumbnail, size: box.size).draw(in: box)
      NSGraphicsContext.restoreGraphicsState()
    } else {
      // 还没解好：先画一块纸色（不是空白一闪）
      NotePaper.all[min(max(paper, 0), NotePaper.all.count - 1)].paperColor.setFill()
      NSBezierPath(
        roundedRect: box, xRadius: NoteImageLayout.corner, yRadius: NoteImageLayout.corner
      ).fill()
    }
  }

  /// 文件找不到：纸上的虚线圆角框 + 一个系统图标 +「图片找不到了」（令牌原样留着，存盘不丢）
  private func drawPlaceholder(in frame: NSRect) {
    let ink = NotePaper.all[min(max(paper, 0), NotePaper.all.count - 1)].inkColor
    let path = NSBezierPath(
      roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: NoteImageLayout.corner,
      yRadius: NoteImageLayout.corner)
    path.lineWidth = 1
    path.setLineDash([4, 3], count: 2, phase: 0)
    ink.withAlphaComponent(0.35).setStroke()
    path.stroke()
    let text = "图片找不到了"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink.withAlphaComponent(0.6),
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    let icon =
      NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    let iconSide: CGFloat = 15
    let gap: CGFloat = 6
    let total = (icon == nil ? 0 : iconSide + gap) + size.width
    var x = frame.midX - total / 2
    if let icon {
      icon.isTemplate = true
      let tinted = NSImage(size: NSSize(width: iconSide, height: iconSide), flipped: false) {
        rect in
        icon.draw(in: rect)
        ink.withAlphaComponent(0.6).set()
        rect.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(
        in: NSRect(x: x, y: frame.midY - iconSide / 2, width: iconSide, height: iconSide))
      x += iconSide + gap
    }
    (text as NSString).draw(
      at: NSPoint(x: x, y: frame.midY - size.height / 2), withAttributes: attributes)
  }
}

/// 解好的缩略图（按像素数算 cost，LRU：读到就挪到队尾；闲下来整块放掉）。**线程安全**：布局时也可能从别的线程问
/// （mac-native §3 的布局回调），所以不用 MainActor 的缓存。
/// 不用 `NSCache`：它按 cost 淘汰的时机不可控（刚放进去的一张马上被自己挤掉就没法知道该不该重画）、
/// 缓存键的命中 / 已在解 / 失败三态和负缓存都没有，这里要自己数、自己测（F7；理由在 docs/archive/PLAN-notes.md「第 7 批」）
nonisolated enum NoteImageThumbnails {
  /// 缓存上限（像素数）：一两屏 Retina 满宽的大图（2560 × 1600 ≈ 410 万像素，一张约 16 MB 位图），三四张一起看也放得下。
  /// 单张超过这个数的缩略图**放进去也不会把自己挤掉**（不然画一次解一次，一直占 CPU）
  static let defaultMaxCost = 16_000_000
  /// 现在的上限（单测可以换小一点；正式代码不动）
  static var maxCost: Int { limit.withLock { $0 ?? defaultMaxCost } }
  private static let limit = Mutex<Int?>(nil)
  /// 像素档：maxPixel 按 256 取整（拖把手、拉窗口时宽度每变 1 pt 不该换一个键、整张再解一遍）
  static let pixelBucket = 256

  private struct Store: Sendable {
    var images: [String: CGImage] = [:]
    /// LRU：最近用过的在最后
    var order: [String] = []
    var cost = 0
    /// 正在解
    var pending: Set<String> = []
    /// 解不出来的（负缓存；discard 时清）：不然「解 → 失败 → 失效重画 → 再解」一直占 CPU
    var failed: Set<String> = []
  }

  private static let store = Mutex(Store())
  /// 单测换掉解码（数解了几次 / 给坏数据）；默认走 NoteImageStore
  private static let decoder = Mutex<@Sendable (URL, Int) async -> CGImage?> { url, maxPixel in
    await NoteImageStore.decodeThumbnail(at: url, maxPixel: maxPixel)
  }

  /// 查一次缓存的结果
  enum Lookup {
    case hit(CGImage)
    /// 已经在解（或者上次解失败过）：别再起一次
    case decoding
    /// 缓存里没有、也没在解：调用方自己起解码
    case miss
  }

  /// 显示这么大的一块（点）要解多少像素：**长边** × 屏幕倍数，按 256 一档往上取整
  static func pixel(for size: CGSize, scale: CGFloat) -> Int {
    let longest = max(size.width, size.height) * max(scale, 1)
    let buckets = max(Int((longest / CGFloat(pixelBucket)).rounded(.up)), 1)
    return buckets * pixelBucket
  }

  /// 这个编号的缓存键
  static func key(_ id: UUID, pixel: Int) -> String { "\(id.uuidString)#\(pixel)" }

  /// 解好的缩略图；没有就起一次解码（在 @concurrent 里），解好回主线程调 ready 让那张图重画。
  /// 已经在解、或者上次解不出来：给 nil（调用方画纸色 / 占位框），**不再起解码**。
  /// 同一个编号已经有别的档的缩略图时，先拿那一张（缩放着画，不闪纸色）
  static func image(
    for url: URL, id: UUID, maxPixel: Int, ready: @escaping @MainActor @Sendable () -> Void
  ) -> CGImage? {
    let pixel = max(maxPixel, 1)
    let key = key(id, pixel: pixel)
    switch lookup(key) {
    case .hit(let image):
      return image
    case .decoding:
      return fallback(id: id, pixel: pixel)
    case .miss:
      let decode = decoder.withLock { $0 }
      Task {
        let decoded = await decode(url, pixel)
        finish(decoded, key: key)
        // 解出来了才失效重画：解不出来（文件坏了 / 被删了）不调 ready，不然「重画 → 再解 → 再失败」一直占 CPU
        if decoded != nil { await MainActor.run { ready() } }
      }
      return fallback(id: id, pixel: pixel)
    }
  }

  /// 查一次缓存（命中会挪到 LRU 队尾；没命中且没在解就占住这个键，返回 .miss）
  static func lookup(_ key: String) -> Lookup {
    store.withLock { state in
      if let cached = state.images[key] {
        touch(&state, key)
        return .hit(cached)
      }
      if state.pending.contains(key) || state.failed.contains(key) { return .decoding }
      state.pending.insert(key)
      return .miss
    }
  }

  /// 同一个编号别的档的缩略图（换宽度时先拿它缩放着画）
  private static func fallback(id: UUID, pixel: Int) -> CGImage? {
    let prefix = "\(id.uuidString)#"
    return store.withLock { state in
      let candidates = state.images.filter { $0.key.hasPrefix(prefix) }
      guard !candidates.isEmpty else { return nil }
      // 取不超过这一档里最大的那张（放大总比缩小糊）；都比这一档大就取最小的
      let found = candidates.compactMap {
        key, image -> (pixel: Int, key: String, image: CGImage)? in
        guard let value = Int(key.dropFirst(prefix.count)) else { return nil }
        return (value, key, image)
      }
      let best =
        found.filter { $0.pixel <= pixel }.max(by: { $0.pixel < $1.pixel })
        ?? found.min(by: { $0.pixel < $1.pixel })
      guard let best else { return nil }
      touch(&state, best.key)
      return best.image
    }
  }

  /// 缓存里已经有了的（便签墙的卡片建视图时同步取一次：屏外出图 / 解好之后的那一帧直接画出来）
  static func peek(key: String) -> CGImage? {
    store.withLock { state in
      guard let cached = state.images[key] else { return nil }
      touch(&state, key)
      return cached
    }
  }

  /// 等一张缩略图（便签墙的卡片用：解好再画，解码前占着同样大的一块纸色）
  static func load(for url: URL, id: UUID, maxPixel: Int) async -> CGImage? {
    let pixel = max(maxPixel, 1)
    let key = key(id, pixel: pixel)
    switch lookup(key) {
    case .hit(let image):
      return image
    case .decoding:
      return fallback(id: id, pixel: pixel)
    case .miss:
      let decode = decoder.withLock { $0 }
      let decoded = await decode(url, pixel)
      finish(decoded, key: key)
      return decoded
    }
  }

  /// 解完了（nil = 失败，记负缓存）
  private static func finish(_ image: CGImage?, key: String) {
    if let image {
      insert(image, key: key)
      return
    }
    store.withLock { state in
      state.pending.remove(key)
      state.failed.insert(key)
    }
  }

  /// 放进缓存、按像素数淘汰（LRU，丢最久没用的；**刚放进去的这张不淘汰**）
  private static func insert(_ image: CGImage, key: String) {
    store.withLock { state in
      state.pending.remove(key)
      state.failed.remove(key)
      guard state.images[key] == nil else { return }
      state.images[key] = image
      state.order.append(key)
      state.cost += image.width * image.height
      while state.cost > maxCost, let oldest = state.order.first, oldest != key {
        state.order.removeFirst()
        if let dropped = state.images.removeValue(forKey: oldest) {
          state.cost -= dropped.width * dropped.height
        }
      }
    }
  }

  /// 读到 / 画到就挪到队尾（LRU）
  private static func touch(_ state: inout Store, _ key: String) {
    guard let index = state.order.firstIndex(of: key) else { return }
    state.order.remove(at: index)
    state.order.append(key)
  }

  /// 闲下来放掉（AppDelegate.idleReclaim）。keeping：这几张图（编号）的缩略图留着——浮在屏幕上的那张便签里的：
  /// 清掉的话它下一次重画（点进去、滚动、拉大小）先画一块纸色、等重新解完才出图，看着是闪一下
  static func discard(keeping ids: Set<UUID> = []) {
    let kept = Set(ids.map(\.uuidString))
    store.withLock { state in
      state.order.removeAll { key in
        guard !kept.contains(String(key.prefix { $0 != "#" })) else { return false }
        if let dropped = state.images.removeValue(forKey: key) {
          state.cost -= dropped.width * dropped.height
        }
        return true
      }
      state.pending.removeAll()
      state.failed.removeAll()
    }
  }

  /// 现在占了多少像素（单测、量内存用）
  static var cost: Int { store.withLock { $0.cost } }

  /// 缓存里现在有多少张（单测用）
  static var count: Int { store.withLock { $0.images.count } }

  // MARK: 单测的钩子（正式代码不用）

  /// 单测：换掉解码（数解了几次 / 返回坏数据）
  static func setDecoder(_ decode: @escaping @Sendable (URL, Int) async -> CGImage?) {
    decoder.withLock { $0 = decode }
  }

  /// 单测：换掉上限（nil = 回到默认）
  static func setMaxCost(_ value: Int?) {
    limit.withLock { $0 = value }
  }

  /// 单测：直接放一张进缓存（数 cost、按上限淘汰）
  static func store(_ image: CGImage, key: String) {
    insert(image, key: key)
  }

  /// 单测：换回真的解码
  static func resetDecoder() {
    decoder.withLock {
      $0 = { url, maxPixel in
        await NoteImageStore.decodeThumbnail(at: url, maxPixel: maxPixel)
      }
    }
  }
}
