// 剪贴板列表的一行（Whisker，mac-whisker §6 剪贴板）：44 pt，30 pt 图标块（色块 > 缩略图 > 来源 App 图标 + 代码角标
// > 种类图标），标题 13 + 副标题 11（有备注显示备注，否则「来源 · 多久前 · 大小」），右侧分组 / 片段 / 收藏标记；
// ⌘1–9 键帽只在按住 ⌘ 时出现。选中是列表背后一块滑动的中性高亮，行本身不填色、文字不反白；多选勾选行 accent 0.14 底。
// 行内用到的摘要文字、图标与取色缓存、缩略图也放在这里。

import AppKit
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem
  let form: ContentForm?
  /// 0...8：显示 ⌘1…⌘9
  let shortcutIndex: Int?
  /// 按住 ⌘：把 ⌘数字键帽亮出来
  let showsShortcut: Bool
  let isSelected: Bool
  /// nil = 不在多选状态
  let isChecked: Bool?
  /// 只在分组筛选为「全部」时传
  let groupName: String?
  let images: ImageStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let height: CGFloat = 44

  var body: some View {
    HStack(spacing: 10) {
      if let isChecked {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(isChecked ? Color.accentColor : .secondary)
          .contentTransition(.symbolEffect(.replace))
      }
      IconTile(item: item, form: form, images: images)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 6)
      if let groupName {
        Text(groupName)
          .font(.system(size: 10, weight: .medium))
          .lineLimit(1)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.primary.opacity(0.07), in: .capsule)
      }
      if item.richType != nil {
        Image(systemName: "textformat").imageScale(.small).foregroundStyle(.tertiary)
      }
      if item.isSnippet {
        Image(systemName: "text.badge.star").imageScale(.small).foregroundStyle(.secondary)
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
      isChecked == true ? Color.accentColor.opacity(0.14) : .clear,
      in: .rect(cornerRadius: Style.Radius.card, style: .continuous)
    )
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var subtitle: String {
    if item.favorite || item.isSnippet, let note = item.note, !note.isEmpty { return note }
    let detail: String? =
      switch item.kind {
      case .text: "\((item.text ?? "").count) 字"
      case .image: item.image.map { "\($0.width)×\($0.height)" }
      case .file: (item.filePaths?.count ?? 0) > 1 ? "\(item.filePaths?.count ?? 0) 个文件" : "文件"
      }
    let ago = item.copiedAt.formatted(
      .relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))
    return [item.sourceName, ago, detail].compactMap { $0 }.joined(separator: " · ")
  }
}

/// 行首 30 pt 图标块（圆角 7）：颜色 = 色块（透明时垫棋盘格）；图片 = 缩略图；文本 = 来源 App 图标，
/// JSON / 代码 / 链接在右下角加角标（链接取过预览后是网站图标）；都没有时是网站图标或种类图标
private struct IconTile: View {
  let item: ClipItem
  let form: ContentForm?
  let images: ImageStore
  @AppStorage(Prefs.clipboardLinkPreview) private var showsLinkPreview = true

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(30), style: .continuous)
    Group {
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        shape.fill(Color(color))
          .background(Checkerboard(cell: 5).clipShape(shape))
          .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
      } else if item.kind == .image {
        ThumbnailView(id: item.id, images: images, maxPixel: 96)
          .clipShape(shape)
          .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
      } else if let icon = AppIcons.icon(for: item.sourceBundleID) {
        Image(nsImage: icon).resizable().scaledToFit()
          .overlay(alignment: .bottomTrailing) {
            if let form, form != .color {
              Group {
                // 链接取过预览后，角标换成网站图标
                if let favicon {
                  Image(nsImage: favicon).resizable().interpolation(.high).padding(1)
                } else {
                  Image(systemName: form.symbol).font(.system(size: 7, weight: .bold))
                }
              }
              .frame(width: 13, height: 13)
              .background(.regularMaterial, in: .rect(cornerRadius: 4, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(
                  Style.hairline, lineWidth: 0.5)
              )
              .offset(x: 2, y: 2)
            }
          }
      } else if let favicon {
        Image(nsImage: favicon).resizable().interpolation(.high)
          .clipShape(shape)
          .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
      } else {
        Image(systemName: form?.symbol ?? item.kind.symbol)
          .font(.system(size: 13, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Style.controlFill, in: shape)
      }
    }
    .frame(width: 30, height: 30)
    .accessibilityHidden(true)
  }

  private var favicon: NSImage? {
    form == .link && showsLinkPreview ? LinkPreview.shared.favicon(forLink: item.text ?? "") : nil
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

/// 键帽样式的快捷键提示
extension ClipItem.Kind {
  var symbol: String {
    switch self {
    case .text: "text.alignleft"
    case .image: "photo"
    case .file: "doc"
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

  /// 检查器页眉色：图标 12×12 采样，跳过透明和过亮 / 过暗的像素求平均，饱和度 ×1.25 + 0.08、亮度 ×0.85
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
}

/// 图片条目的缩略图：后台按需生成，NSCache 复用
struct ThumbnailView: View {
  let id: UUID
  let images: ImageStore
  let maxPixel: Int
  var contentMode = ContentMode.fill
  @State private var image: NSImage?

  private static let cache = NSCache<NSString, NSImage>()

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
      } else {
        Color.primary.opacity(0.06)
      }
    }
    .clipShape(.rect(cornerRadius: 6))
    .task(id: id) {
      let key = "\(id.uuidString)-\(maxPixel)" as NSString
      if let cached = Self.cache.object(forKey: key) {
        image = cached
      } else if let cgImage = await images.thumbnail(for: id, maxPixel: maxPixel) {
        let loaded = NSImage(cgImage: cgImage, size: .zero)
        Self.cache.setObject(loaded, forKey: key)
        image = loaded
      }
    }
  }
}
