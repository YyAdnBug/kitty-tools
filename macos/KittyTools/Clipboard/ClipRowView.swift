// 剪贴板列表的一行（Lens Bar，mac-whisker §6 剪贴板）：40 pt，24 pt 图标块（色块 > 缩略图 > 来源 App 图标 + 代码角标
// > 网站图标 / 种类图标），标题 13 regular 单行（代码 / JSON 用 SF Mono 12；有搜索词时从第一个命中处摘录、命中词黄底），
// 右侧 11 pt「来源 · 多久前」（有备注时换成备注），再右是收藏夹 / 带格式 / 片段 / 收藏标记；
// 标题已经把整条文本原样显示全的（showsWholeText），透镜不再画第二遍、有搜索词也不摘录；
// ⌘1–9 键帽只在按住 ⌘ 时出现。选中是列表背后一块滑动的中性高亮（透镜的底），行本身不填色、文字不反白；
// 多选时最左边多一个品牌粉勾选圆，勾中的行品牌粉 0.14 底。选中行在它下面展开透镜（LensView）。
// 行内用到的摘要文字、图标与取色缓存、缩略图也放在这里。

import AppKit
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem
  let form: ContentForm?
  /// 搜索词：标题从命中处摘录、命中词高亮
  var query = ""
  /// 0...8：显示 ⌘1…⌘9
  let shortcutIndex: Int?
  /// 按住 ⌘：把 ⌘数字键帽亮出来
  let showsShortcut: Bool
  /// nil = 不在多选状态
  let isChecked: Bool?
  /// 所在收藏夹的名字：只在收藏夹筛选为「全部」时传
  let groupName: String?
  let images: ImageStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let height: CGFloat = 40
  /// 行内间距、左右内边距、右侧文字最宽：布局和 showsWholeText 的宽度预算共用
  private static let spacing: CGFloat = 10
  private static let padding: CGFloat = 10
  private static let trailingMax: CGFloat = 220

  var body: some View {
    HStack(spacing: Self.spacing) {
      if let isChecked {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(isChecked ? Style.brand : .secondary)
          .contentTransition(.symbolEffect(.replace))
      }
      IconTile(item: item, form: form, images: images)
      Text(title)
        .font(
          form == .code || form == .json
            ? .system(size: 12, design: .monospaced) : .system(size: 13)
        )
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      trailing
        .font(.system(size: 11))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: Self.trailingMax, alignment: .trailing)
        .layoutPriority(1)
      if let groupName {
        Text(groupName)
          .font(.system(size: 10, weight: .medium))
          .lineLimit(1)
          .padding(.horizontal, 6)
          .frame(height: 16)
          .background(
            Style.controlFill, in: .rect(cornerRadius: Style.Radius.control, style: .continuous))
      }
      if item.richType != nil {
        // 带格式（RTF / HTML）。textformat 在中文系统上画成「格式」两个字；B I U 不跟系统语言换字形
        Image(systemName: "bold.italic.underline").imageScale(.small).foregroundStyle(.tertiary)
          .help("带格式")
      }
      if item.isSnippet {
        Image(systemName: "text.badge.star").imageScale(.small).foregroundStyle(.secondary)
          .help("片段")
      }
      Image(systemName: "star.fill")
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: .systemYellow))
        .opacity(item.favorite ? 1 : 0)
        .scaleEffect(item.favorite || reduceMotion ? 1 : 0.4)
        .symbolEffect(.bounce, value: item.favorite)
        // 宽度也在动画里：收藏时星星挤开旁边的标记，而不是跳
        .frame(width: item.favorite ? nil : 0)
        .animation(Style.Motion.pop.animation(reduced: reduceMotion), value: item.favorite)
        .accessibilityLabel(item.favorite ? "已收藏" : "")
      // 没按 ⌘ 时不在布局里（占着宽度和间距的话，前九行的标题比别的行早截断）
      if isChecked == nil, let shortcutIndex, showsShortcut {
        KeyCap("⌘\(shortcutIndex + 1)")
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
      }
    }
    .animation(
      reduceMotion
        ? .easeOut(duration: 0.12)
        : .easeOut(duration: 0.12).delay(Double(shortcutIndex ?? 0) * 0.015), value: showsShortcut
    )
    .padding(.horizontal, Self.padding)
    .frame(height: Self.height)
    .background(
      isChecked == true ? Style.brand.opacity(0.14) : .clear,
      in: .rect(cornerRadius: Style.Radius.card, style: .continuous)
    )
  }

  /// 标题：有搜索词且命中不在开头时从命中处摘录（前 12 字 + 「…」），命中词黄底。
  /// 图片靠识别文字搜到的，「图片 宽×高」后面接上命中的那段识别文字
  private var title: AttributedString {
    let full = item.title
    guard !query.isEmpty else { return AttributedString(full) }
    var shown = full
    switch item.kind {
    case .text:
      // 标题本来就显示得全的不摘录：这时透镜没有正文区，摘录会把开头藏起来。
      // 多选时行首多一个勾选圆、标题列变窄（透镜也收着），照旧摘录
      if isChecked != nil || !Self.showsWholeText(item) {
        let text = String((item.text ?? "").prefix(20_000))
        shown = Search.excerpt(of: text, query: query, before: 12, after: 160) ?? full
      }
    case .image:
      if let ocr = item.ocrText, Search.firstHit(in: ocr, query: query) != nil {
        shown =
          full + " · "
          + (Search.excerpt(of: ocr, query: query, before: 12, after: 160)
            ?? String(ocr.prefix(200)))
      }
    case .file:
      shown = Search.excerpt(of: full, query: query, before: 12, after: 160) ?? full
    }
    var attributed = AttributedString(shown.replacing(/\s+/, with: " "))
    attributed.highlight(query)
    return attributed
  }

  /// 标题已经把整条文本原样显示出来了：去掉首尾空白后和标题一字不差（一行，没有被压成一个空格的连续空白），
  /// 而且标题列最窄时也放得下。这时透镜不再把同一句话画第二遍（Lens.bodyHeight 给 0，只剩元信息行），
  /// 有搜索词时标题也不摘录。透镜的高度进前缀和，所以只看条目自己的数据（纯函数，不读时间、修饰键、系统设置）：
  /// ⌘数字键帽和常显的滚动条都当它在——真的标题列只会比这里算的宽（342 – 396 pt 减去标记；
  /// ClipboardPanelTests.wholeTitleIsNotTruncated 把行画出来对过）。
  /// ponytail: 收藏夹筛选为「全部」时行尾多一个收藏夹胶囊，没算进来：收藏夹名超过三个字、标题又贴着上限时
  /// 会被截掉几个字（⌘Y 看全文）；真碰到再把收藏夹名的宽度传进来
  static func showsWholeText(_ item: ClipItem) -> Bool {
    // 标题列再宽也放不下 400 字节（最窄的字母也有 3 pt 多）；长文本不在这里整段去空白
    guard item.kind == .text, let text = item.text, text.utf8.count <= 400 else { return false }
    let title = item.title
    guard title == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
    // 标题列最窄时：行宽 − 常显的滚动条 16 − 左右内边距 − 图标块 − 四处固定间距（图标后、Spacer 两边、星标前）
    // − Spacer 最窄 8 − 右侧文字那一格（带 maxWidth 的 frame 有多少占多少，字再短也占满 220）
    // − ⌘数字键帽（⌘9 约 27.4）连它前面的间距
    var room =
      ClipboardPanelView.width - 2 * ClipboardPanelView.inset - 16 - 2 * padding - IconTile.side
      - 4 * spacing - 8 - trailingMax - (spacing + 28)
    // 标记的宽度是 SF Symbols 实测后取整：带格式 23、片段 14、星标 15
    if item.richType != nil { room -= spacing + 24 }
    if item.isSnippet { room -= spacing + 16 }
    if item.favorite { room -= 16 }
    let width = (title as NSString).size(
      withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
    ).width
    return ceil(width) <= room
  }

  /// 右侧：有备注时是备注（secondary，所有条目都能写，体检 A3），否则「来源 · 多久前」（tertiary）
  @ViewBuilder private var trailing: some View {
    if let note = item.note, !note.isEmpty {
      Text(note).foregroundStyle(.secondary)
    } else {
      let ago = item.copiedAt.formatted(
        .relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))
      Text([item.sourceName, ago].compactMap { $0 }.joined(separator: " · "))
        .foregroundStyle(.tertiary)
    }
  }
}

/// 行首 24 pt 图标块（圆角 tile(24)）：颜色 = 色块（透明时垫棋盘格）；图片 = 缩略图；文本 = 来源 App 图标，
/// JSON / 代码 / 链接在右下角加 11 pt 角标（链接取过预览后是网站图标）；都没有时是网站图标或种类图标。
/// 新条目插进来时 0.85→1（pop，只播一次，见 IconPop）。拖动预览（ClipDrag）也用它
struct IconTile: View {
  let item: ClipItem
  let form: ContentForm?
  let images: ImageStore
  @AppStorage(Prefs.clipboardLinkPreview) private var showsLinkPreview = true
  @Environment(\.clipRowArriving) private var arriving

  static let side: CGFloat = 24
  static let badge: CGFloat = 11

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(Self.side), style: .continuous)
    let badgeShape = RoundedRectangle(cornerRadius: Style.Radius.mini - 1, style: .continuous)
    Group {
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        shape.fill(Color(color))
          .background(Checkerboard(cell: 4).clipShape(shape))
          .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
      } else if item.kind == .image {
        // 先定框再裁：fill 的图比框宽（长截图 5:1），只裁自己的边界会溢出盖住标题
        ThumbnailView(id: item.id, images: images, maxPixel: ThumbnailView.iconPixel)
          .frame(width: Self.side, height: Self.side)
          .clipShape(shape)
          .overlay(shape.hairlineBorder())
      } else if let icon = AppIcons.icon(for: item.sourceBundleID) {
        Image(nsImage: icon).resizable().scaledToFit()
          .overlay(alignment: .bottomTrailing) {
            if let form, form != .color {
              Group {
                // 链接取过预览后，角标换成网站图标
                if let favicon {
                  Image(nsImage: favicon).resizable().interpolation(.high).padding(1)
                } else {
                  Image(systemName: form.symbol).font(.system(size: 6, weight: .bold))
                }
              }
              .frame(width: Self.badge, height: Self.badge)
              .background(.regularMaterial, in: badgeShape)
              .overlay(badgeShape.hairlineBorder())
              .offset(x: 2, y: 2)
            }
          }
      } else if let favicon {
        Image(nsImage: favicon).resizable().interpolation(.high)
          .clipShape(shape)
          .overlay(shape.hairlineBorder())
      } else {
        Image(systemName: form?.symbol ?? item.kind.symbol)
          .font(.system(size: 11, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Style.controlFill, in: shape)
      }
    }
    .frame(width: Self.side, height: Self.side)
    .scaleEffect(arriving ? 0.85 : 1)
    .animation(Style.Motion.pop.animation(), value: arriving)
    .accessibilityHidden(true)
  }

  private var favicon: NSImage? {
    form == .link && showsLinkPreview ? LinkPreview.shared.favicon(forLink: item.text ?? "") : nil
  }
}

extension EnvironmentValues {
  /// 这一行正随插入过渡出现（IconPop）
  @Entry var clipRowArriving = false
}

/// 行插入过渡里带上它：把「正在插入」写进环境，IconTile 自己按 pop 从 0.85 长到 1。
/// 所以只在列表真的插入一行时播（新复制进来、撤销删除）：搜索 / 筛选换列表那一帧不动画、
/// 滚动时新进可见区附近的行不算插入（不在动画里改，见 ClipboardPanelView.list），都不播；减弱动态效果时行只淡入，不带它
struct IconPop: Transition {
  func body(content: Content, phase: TransitionPhase) -> some View {
    content.environment(\.clipRowArriving, phase == .willAppear)
  }
}

/// 棋盘格底（透明色、透明图片下面）
struct Checkerboard: View {
  var cell: CGFloat = 8

  var body: some View {
    Canvas { context, size in
      let columns = Int(ceil(size.width / cell))
      let rows = Int(ceil(size.height / cell))
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.04)))
      for row in 0..<rows {
        for column in 0..<columns where (row + column) % 2 == 0 {
          context.fill(
            Path(
              CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
            with: .color(.primary.opacity(0.08)))
        }
      }
    }
  }
}

extension ClipItem.Kind {
  var symbol: String {
    switch self {
    case .text: "text.alignleft"
    case .image: "photo"
    case .file: "doc"
    }
  }

  var title: String {
    switch self {
    case .text: "文本"
    case .image: "图片"
    case .file: "文件"
    }
  }
}

extension ContentForm {
  var symbol: String {
    switch self {
    case .color: "paintpalette"
    case .json: "curlybraces"
    case .link: "link"
    case .code: "chevron.left.forwardslash.chevron.right"
    }
  }
}

extension ClipItem {
  /// 列表里的一行摘要
  var title: String {
    switch kind {
    case .text:
      return String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        .replacing(/\s+/, with: " ")
    case .image:
      guard let image else { return "图片" }
      return "图片 \(image.width)×\(image.height)"
    case .file:
      let names = (filePaths ?? []).map { URL(filePath: $0).lastPathComponent }
      return names.count == 1 ? names[0] : names.joined(separator: "、")
    }
  }
}

extension Color {
  init(_ rgba: ContentForm.RGBA) {
    self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
  }
}

/// 来源 App 图标与取色（按 bundle ID 缓存；App 被卸载时为 nil）
enum AppIcons {
  private static var cache: [String: NSImage?] = [:]
  private static var colors: [String: NSColor] = [:]

  /// ⌘Y 放大卡的页眉色：图标 12×12 采样，跳过透明和过亮 / 过暗的像素求平均，饱和度 ×1.25 + 0.08、亮度 ×0.85
  /// 夹在 0.35–0.75（白字才读得清）。取不到时用系统蓝
  static func accentColor(for bundleID: String?) -> NSColor {
    guard let bundleID else { return .systemBlue }
    if let cached = colors[bundleID] { return cached }
    let color = icon(for: bundleID).flatMap(Self.average) ?? .systemBlue
    colors[bundleID] = color
    return color
  }

  /// 图标主色（也给链接预览的网站图标用）
  static func average(of image: NSImage) -> NSColor? {
    let side = 12
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return nil }
    var sum = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Double(pixels[index + 3]) / 255
      guard alpha > 0.5 else { continue }
      let r = Double(pixels[index]) / 255 / alpha
      let g = Double(pixels[index + 1]) / 255 / alpha
      let b = Double(pixels[index + 2]) / 255 / alpha
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      guard luminance > 0.08, luminance < 0.92 else { continue }
      sum = (sum.r + r, sum.g + g, sum.b + b, sum.n + 1)
    }
    guard sum.n > 0 else { return nil }
    let color = NSColor(
      srgbRed: sum.r / sum.n, green: sum.g / sum.n, blue: sum.b / sum.n, alpha: 1)
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    return NSColor(
      hue: hue, saturation: min(saturation * 1.25 + 0.08, 1),
      brightness: min(max(brightness * 0.85, 0.35), 0.75), alpha: 1)
  }

  static func icon(for bundleID: String?) -> NSImage? {
    guard let bundleID else { return nil }
    if let cached = cache[bundleID] { return cached }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
      NSWorkspace.shared.icon(forFile: $0.path)
    }
    cache[bundleID] = icon
    return icon
  }

  /// App 的显示名（按 bundle ID 找到 App 包；找不到是 nil）：来源标记、排除 App 列表用
  static func name(for bundleID: String) -> String? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
      FileManager.default.displayName(atPath: $0.path).replacing(/\.app$/, with: "")
    }
  }
}

/// 图片条目的缩略图：后台按需生成，NSCache 复用。缓存里有的在建视图时就直接用（滚回来、透镜展开不闪一下占位）。
/// 缓存有上限（第二轮体检 M1）：画过的缩略图每张在内存里留两份「宽 × 高 × 4」（CG raster data、CoreAnimation 各一份，
/// 内存探针实测），窗口关了也不还，缓存放手才还。行图标单独一个缓存（icons），透镜和 ⌘Y 大卡共用一个（previews）；
/// 大卡那一档在大卡放掉时整档丢掉（dropCards）。正在显示的那张不怕被淘汰：视图自己的 @State 还拿着它
struct ThumbnailView: View {
  let id: UUID
  let images: ImageStore
  let maxPixel: Int
  var contentMode = ContentMode.fill
  @State private var image: NSImage?

  /// 三档的长边（像素）：行图标、透镜、⌘Y 大卡
  static let iconPixel = 72
  static let lensPixel = 720
  static let cardPixel = 2400

  /// 行图标最多留这么多张，单独一个缓存：不让大图把它们挤掉（重做一张要把原图整张解码）。一张最大 72 × 72，
  /// 画过后实测留 25–31 KB，留满 7–10 MB；列表一屏十来行，300 张 = 连着翻过二三十屏的图片
  static let iconCount = 300
  /// 透镜 + 大卡最多留这么多（按 cost）：约 18 张整屏截图的透镜，或一张大卡（整屏截图约 29 MB）+ 7 张透镜。
  /// 最大的一张大卡（2400 × 2400，44 MB）加同一张图的透镜（720 × 720，4 MB）也放得下：正在看的这两张不会把对方挤掉
  static let previewBytes = 48 * 1_048_576

  /// 不是 private：内存探针（MemoryProbeTests）要清空它们，量清掉后回落多少
  static let icons = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = iconCount
    return cache
  }()
  static let previews = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = previewBytes
    return cache
  }()
  /// 进过缓存的大卡档的 key：NSCache 列不出自己有什么，dropCards 照着这份丢
  private static var cardKeys: Set<String> = []

  init(id: UUID, images: ImageStore, maxPixel: Int, contentMode: ContentMode = .fill) {
    self.id = id
    self.images = images
    self.maxPixel = maxPixel
    self.contentMode = contentMode
    _image = State(
      initialValue: Self.cache(for: maxPixel).object(forKey: Self.key(id, maxPixel) as NSString))
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
      } else {
        Style.controlFill
      }
    }
    // 不自己裁：调用方按自己的圆角裁 ThumbnailView 本身（行图标 tile、透镜和 ⌘Y 大卡 control），
    // .fit 时图片比容器小，只裁外面的容器图片会是直角
    .task(id: id) {
      image = await Self.load(id, images: images, maxPixel: maxPixel)
    }
  }

  /// 缓存里有就直接给，没有就在后台生成再缓存（截图自检也先用它把缓存填好：屏外渲染时 .task 来不及跑）
  static func load(_ id: UUID, images: ImageStore, maxPixel: Int) async -> NSImage? {
    let key = key(id, maxPixel)
    let cache = cache(for: maxPixel)
    if let cached = cache.object(forKey: key as NSString) { return cached }
    guard let cgImage = await images.thumbnail(for: id, maxPixel: maxPixel) else { return nil }
    let loaded = NSImage(cgImage: cgImage, size: .zero)
    // 尺寸取 CGImage 自己的：NSImage 的 rep 报的是另一个数
    cache.setObject(
      loaded, forKey: key as NSString, cost: cost(width: cgImage.width, height: cgImage.height))
    if maxPixel >= cardPixel { cardKeys.insert(key) }
    return loaded
  }

  /// 一张缩略图画过之后占的内存：宽 × 高 × 4 字节，两份
  static func cost(width: Int, height: Int) -> Int { width * height * 4 * 2 }

  /// 这一档进哪个缓存：行图标档进 icons，更大的（透镜、大卡）进 previews
  static func cache(for maxPixel: Int) -> NSCache<NSString, NSImage> {
    maxPixel <= iconPixel ? icons : previews
  }

  /// ⌘Y 大卡放掉了：大卡档的缩略图都丢掉（一张整屏截图约 29 MB，留着会把透镜档挤出去）
  static func dropCards() {
    for key in cardKeys { previews.removeObject(forKey: key as NSString) }
    cardKeys = []
  }

  private static func key(_ id: UUID, _ maxPixel: Int) -> String {
    "\(id.uuidString)-\(maxPixel)"
  }
}
