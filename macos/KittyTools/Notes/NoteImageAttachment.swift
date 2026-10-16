// 便签正文里的图片附件（第 7 批；令牌在 NoteImages.swift，图片目录在 NoteImageStore.swift，编辑器接线在
// NoteTextView.swift / NoteTextView+Images.swift）。存的正文里图片是文字令牌，**载入编辑器时换成附件字符 U+FFFC**
// （NSTextAttachment + 自己的 NSTextAttachmentCell），存盘时换回令牌。样机（屏外、同一套 TextKit 1）比过：附件字符的
// 光标 / 选区命令一次都不会落进图片内部、点图落在图前、图片后 ⌫ 整张删掉、撤销一步，隐藏令牌 + 盖视图那条路这些都不行。
// - 尺寸：附件自己报（`attachmentBounds(for:proposedLineFragment:…)`，按正文可用宽算：没记宽度就跟着正文框宽变，
//   不超过原图点宽；记了宽度的超出可用宽时缩到可用宽，最小 40）。原点是基线上的字形位置，图的左下角在 (0, -高)：
//   底边落在基线上（和字同行时字坐在图的底边那条基线上），顶边和布局代理给的 usedRect 是同一个位置。
//   图片那一行的高由段落样式定死（NoteStyles.apply 写 imageLineKey + 行高），布局代理按它把基线下移
//   （NoteStyles.centerLine）——这一条是样机量出来的（不撑高的话图会被裁成一行高）。
// - 画：缩略图有了就画（圆角），没有先画一块纸色（不是空白一闪），文件不在画占位框（虚线框 + 图标 +「图片找不到了」）。
//   选中描边和右下角的拖动把手由文本视图画（NoteTextView.drawImageChrome：把手要能命中，画在字和选区上面）。
// - 缩略图在 @concurrent 里用 ImageIO 解（带 EXIF 方向、显示那么大的像素），解好回主线程只失效那张图所在的字；
//   解出来的进 NSCache 那样的内存缓存（按像素数算 cost），闲下来放掉（NoteImageThumbnails.discard）。
// - 互转（stored(from:) 和 editorString(from:…)）只在这两个地方拼令牌，别处不许自己拼。
// ponytail: 动图（GIF / APNG）只显示第一帧（ImageIO 的缩略图接口就是这样）；要播就自己按帧驱动图层。

import AppKit
import Synchronization

/// 图片在正文里的尺寸和长相的数值（mac-whisker-notes.mdc「正文里的图片」）
nonisolated enum NoteImageLayout {
  /// 图片那一行上下各留多少（撑高时算进去）
  static let padding: CGFloat = 4
  /// 图片四角的圆角
  static let corner: CGFloat = 6
  /// 宽度最小多少（记了更小的宽度也按它）
  static let minWidth: CGFloat = 40
  /// 文件找不到时占位框的宽（不超过可用宽）和高
  static let placeholderWidth: CGFloat = 200
  static let placeholderHeight: CGFloat = 44
  /// 右下角拖动把手多大
  static let handle: CGFloat = 12
  /// 墙卡片上的缩略图：高上限、和标题之间留多少
  static let thumbnailMaxHeight: CGFloat = 120
  static let thumbnailGap: CGFloat = 8

  /// 这张图显示多大。available：正文可用宽（正文框宽 − 两边的内缩）；live：拖把手时临时的宽度（只改显示、不改字）
  static func size(
    image: NoteImages.Image, metrics: NoteImageSize?, available: CGFloat, live: CGFloat? = nil
  ) -> CGSize {
    let limit = max(available, 1)
    guard let metrics, metrics.pointSize.width > 0, metrics.pointSize.height > 0 else {
      return CGSize(width: min(placeholderWidth, limit).rounded(), height: placeholderHeight)
    }
    let natural = metrics.pointSize
    let wanted = live ?? image.width.map(CGFloat.init) ?? natural.width
    let width = min(max(wanted, minWidth), limit)
    let height = natural.height * width / natural.width
    return CGSize(width: width.rounded(), height: max(height.rounded(), 1))
  }

  /// 图片那一行的段落样式要多高（图片 + 上下留白；至少正文一行那么高，见 NoteStyles.apply）
  static func lineHeight(for imageHeight: CGFloat, base: CGFloat) -> CGFloat {
    max(base, imageHeight + padding * 2)
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

  /// 图在正文里占多大。**原点是基线上的字形位置**（NSTextAttachment.bounds 的约定，实测 15.7 走的是这一条）：
  /// 图的左下角在 (0, -高)，底边就落在基线上——和字同行时字坐在图的底边那条基线上；
  /// 顶边落在行片段顶 + 上留白，和布局代理给的那一块（usedRect）是同一个位置。没记宽度的图跟着正文框的可用宽变
  override func attachmentBounds(
    for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
    glyphPosition position: CGPoint, characterIndex charIndex: Int
  ) -> CGRect {
    let padding = textContainer?.lineFragmentPadding ?? 0
    let available = lineFrag.width - padding * 2
    let live = (attachmentCell as? NoteImageAttachmentCell)?.liveWidth
    let size = NoteImageLayout.size(
      image: picture, metrics: metrics, available: available, live: live)
    return CGRect(x: 0, y: -size.height, width: size.width, height: size.height)
  }

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
/// （cellSize / cellBaselineOffset），只读传进来的东西和 `let` 的字段
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

  /// 没有可用宽时的尺寸（真的尺寸由附件的 attachmentBounds 按可用宽报）
  nonisolated override func cellSize() -> NSSize {
    let size = size(available: .greatestFiniteMagnitude)
    return NSSize(width: size.width, height: size.height)
  }

  /// 图坐在基线上（图和字同行时字坐在图的底边那条基线上）
  nonisolated override func cellBaselineOffset() -> NSPoint { .zero }

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
    guard let metrics else {
      drawPlaceholder(in: frame)
      return
    }
    let scale = controlView?.window?.backingScaleFactor ?? 2
    let maxPixel = Int(max(frame.width * scale, 1))
    if let thumbnail = NoteImageThumbnails.image(
      for: url, key: "\(picture.id.uuidString)@\(maxPixel)", maxPixel: maxPixel,
      ready: { [weak self] in self?.view?.imageThumbnailArrived(image: self?.picture.id) })
    {
      let path = NSBezierPath(
        roundedRect: frame, xRadius: NoteImageLayout.corner, yRadius: NoteImageLayout.corner)
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      NSImage(cgImage: thumbnail, size: frame.size).draw(in: frame)
      NSGraphicsContext.restoreGraphicsState()
    } else {
      // 还没解好：先画一块纸色（不是空白一闪）
      NotePaper.all[min(max(paper, 0), NotePaper.all.count - 1)].paperColor.setFill()
      NSBezierPath(
        roundedRect: frame, xRadius: NoteImageLayout.corner, yRadius: NoteImageLayout.corner
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

/// 解好的缩略图（按像素数算 cost，超过上限丢最旧的；闲下来整块放掉）。**线程安全**：布局时也可能从别的线程问
/// （mac-native §3 的布局回调），所以不用 MainActor 的缓存
nonisolated enum NoteImageThumbnails {
  /// 缓存的上限（像素数；一张显示大小的缩略图几十万像素，约合 16 MB 位图）
  static let maxCost = 4_000_000

  private struct Store: Sendable {
    var images: [String: CGImage] = [:]
    var order: [String] = []
    var cost = 0
    var pending: Set<String> = []
  }

  private static let store = Mutex(Store())

  /// 解好的缩略图；没有就开始解（在 @concurrent 里），解好回主线程调 ready 让那张图重画。
  /// 已经在解、或者没在解但文件不在都给 nil（调用方先画纸色 / 占位框）
  static func image(
    for url: URL, key: String, maxPixel: Int, ready: @escaping @MainActor @Sendable () -> Void
  ) -> CGImage? {
    let hit = store.withLock { state -> CGImage? in
      if let cached = state.images[key] { return cached }
      guard state.pending.insert(key).inserted else { return nil }
      return nil
    }
    if let hit { return hit }
    Task {
      let decoded = await NoteImageStore.decodeThumbnail(at: url, maxPixel: maxPixel)
      insert(decoded, key: key)
      await MainActor.run { ready() }
    }
    return nil
  }

  /// 缓存里已经有了的（便签墙的卡片建视图时同步取一次：屏外出图 / 解好之后的那一帧直接画出来）
  static func peek(key: String) -> CGImage? { store.withLock { $0.images[key] } }

  /// 等一张缩略图（便签墙的卡片用：解好再画，解码前占着同样大的一块纸色）
  static func load(for url: URL, key: String, maxPixel: Int) async -> CGImage? {
    if let hit = store.withLock({ $0.images[key] }) { return hit }
    let decoded = await NoteImageStore.decodeThumbnail(at: url, maxPixel: maxPixel)
    insert(decoded, key: key)
    return decoded
  }

  /// 放进缓存、按像素数轮换（超过上限丢最旧的）
  private static func insert(_ image: CGImage?, key: String) {
    store.withLock { state in
      state.pending.remove(key)
      guard let image, state.images[key] == nil else { return }
      state.images[key] = image
      state.order.append(key)
      state.cost += image.width * image.height
      while state.cost > maxCost, let oldest = state.order.first {
        state.order.removeFirst()
        if let dropped = state.images.removeValue(forKey: oldest) {
          state.cost -= dropped.width * dropped.height
        }
      }
    }
  }

  /// 闲下来放掉（AppDelegate.idleReclaim）
  static func discard() {
    store.withLock { state in
      state.images.removeAll()
      state.order.removeAll()
      state.cost = 0
    }
  }

  /// 现在占了多少像素（单测、量内存用）
  static var cost: Int { store.withLock { $0.cost } }
}
