// 剪贴板列表的一行（Lens Bar，mac-whisker §6 剪贴板）：40 pt，24 pt 图标块（色块 > 缩略图 > 来源 App 图标 + 代码角标
// > 网站图标 / 种类图标），标题 13 regular 单行（代码 / JSON 用 SF Mono 12；有搜索词时从第一个命中处摘录、命中词黄底），
// 右侧 11 pt「来源 · 多久前」（有备注时换成备注），再右是收藏夹 / 带格式 / 片段 / 收藏标记；
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

  var body: some View {
    HStack(spacing: 10) {
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
        .frame(maxWidth: 220, alignment: .trailing)
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
    .padding(.horizontal, 10)
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
      let text = String((item.text ?? "").prefix(20_000))
      shown = Search.excerpt(of: text, query: query, before: 12, after: 160) ?? full
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
        ThumbnailView(id: item.id, images: images, maxPixel: 72)
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
/// 滚动时 LazyVStack 新建的行不算插入，都不播；减弱动态效果时行只淡入，不带它
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

/// 图片条目的缩略图：后台按需生成，NSCache 复用。缓存里有的在建视图时就直接用（滚回来、透镜展开不闪一下占位）
struct ThumbnailView: View {
  let id: UUID
  let images: ImageStore
  let maxPixel: Int
  var contentMode = ContentMode.fill
  @State private var image: NSImage?

  private static let cache = NSCache<NSString, NSImage>()

  init(id: UUID, images: ImageStore, maxPixel: Int, contentMode: ContentMode = .fill) {
    self.id = id
    self.images = images
    self.maxPixel = maxPixel
    self.contentMode = contentMode
    _image = State(initialValue: Self.cache.object(forKey: Self.key(id, maxPixel)))
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
    if let cached = cache.object(forKey: key) { return cached }
    guard let cgImage = await images.thumbnail(for: id, maxPixel: maxPixel) else { return nil }
    let loaded = NSImage(cgImage: cgImage, size: .zero)
    cache.setObject(loaded, forKey: key)
    return loaded
  }

  private static func key(_ id: UUID, _ maxPixel: Int) -> NSString {
    "\(id.uuidString)-\(maxPixel)" as NSString
  }
}
