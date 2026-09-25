// 剪贴板列表的一行（两行式）：左侧图标块（色块 > 缩略图 > 来源 App 图标 > 类型图标），
// 标题 + 副标题（有备注显示备注，否则「来源 · 多久前 · 大小」），右侧分组 / 片段 / 收藏标记与 ⌘数字键帽。
// 选中行用强调色填充、文字反白（与系统菜单一致）。行内用到的摘要文字、图标缓存、键帽也放在这里。

import AppKit
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem
  let form: ContentForm?
  /// 0...8：显示 ⌘1…⌘9
  let shortcutIndex: Int?
  let isSelected: Bool
  /// nil = 不在多选状态
  let isChecked: Bool?
  /// 只在分组筛选为「全部」时传
  let groupName: String?
  let images: ImageStore

  var body: some View {
    HStack(spacing: 10) {
      if let isChecked {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(isSelected ? .white : isChecked ? Color.accentColor : .secondary)
      }
      IconTile(item: item, form: form, images: images)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(
            isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
          )
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
          .background(isSelected ? .white.opacity(0.2) : .primary.opacity(0.07), in: .capsule)
      }
      if item.richType != nil { Image(systemName: "textformat").imageScale(.small).opacity(0.6) }
      if item.isSnippet { Image(systemName: "text.badge.star").imageScale(.small) }
      if item.favorite {
        Image(systemName: "star.fill").imageScale(.small)
          .foregroundStyle(isSelected ? .white : .yellow)
      }
      if isChecked == nil, let shortcutIndex {
        KeyCap("⌘\(shortcutIndex + 1)")
      }
    }
    .foregroundStyle(isSelected ? .white : .primary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 7))
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

/// 行首 28pt 图标块
private struct IconTile: View {
  let item: ClipItem
  let form: ContentForm?
  let images: ImageStore

  var body: some View {
    Group {
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        RoundedRectangle(cornerRadius: 6).fill(Color(color))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25)))
      } else if item.kind == .image {
        ThumbnailView(id: item.id, images: images, maxPixel: 96)
      } else if let icon = AppIcons.icon(for: item.sourceBundleID) {
        Image(nsImage: icon).resizable().scaledToFit()
      } else {
        Image(systemName: form?.symbol ?? item.kind.symbol)
          .font(.system(size: 13))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.primary.opacity(0.08), in: .rect(cornerRadius: 6))
      }
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
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

/// 来源 App 图标（按 bundle ID 缓存；App 被卸载时为 nil）
enum AppIcons {
  private static var cache: [String: NSImage?] = [:]

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
