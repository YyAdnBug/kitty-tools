// 剪贴板检查器卡片（Whisker，mac-whisker §6 剪贴板）：内缩 6、圆角 10 的一张卡。
// 页眉 40 pt 取来源 App 图标的颜色（对比度不够时改黑字），写 App 名和「类型 · 大小 · 时间」；
// 主体按类型出大预览：颜色 = 满宽色块 + HEX / RGB / HSL / SwiftUI 四行点击复制；代码 / JSON = SF Mono + 语法着色；
// 链接 = 大号网站卡；图片 = 棋盘格 + 尺寸胶囊 + 识别文字；文件 = Quick Look 缩略图网格；文本高亮搜索词。
// 页脚最多 4 个无边框胶囊按钮，其余操作在 ⌘K 面板。换条目时内容淡入上浮、页眉颜色渐变过去。

import AppKit
import QuickLookThumbnailing
import SwiftUI

struct PreviewView: View {
  let item: ClipItem
  @Bindable var model: ClipboardPanelModel
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var form: ContentForm? { model.contentForm(of: item) }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(spacing: 0) {
      header
      // minHeight 0 + clipped：内容再高也只在卡片里裁掉，不把面板顶出窗口
      content
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .id(item.id)
        .transition(.opacity.combined(with: .offset(y: 4)))
      footer
    }
    .animation(
      model.selectionMotion == .instant || reduceMotion ? nil : .easeOut(duration: 0.12),
      value: item.id
    )
    .background(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55), in: shape)
    .clipShape(shape)
    .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 3, y: 1)
    .padding(6)
  }

  // MARK: 页眉

  private var header: some View {
    let tint = AppIcons.accentColor(for: item.sourceBundleID)
    let darkText = Self.needsDarkText(on: tint)
    let ink: Color = darkText ? .black.opacity(0.85) : .white
    return HStack(spacing: 8) {
      if let icon = AppIcons.icon(for: item.sourceBundleID) {
        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
      }
      Text(item.sourceName ?? "未知来源")
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(meta)
        .font(.system(size: 11))
        .opacity(0.78)
        .lineLimit(1)
    }
    .foregroundStyle(ink)
    .padding(.horizontal, 12)
    .frame(height: 40)
    .background(
      LinearGradient(
        colors: [Color(nsColor: tint), Color(nsColor: tint).mix(with: .black, by: 0.08)],
        startPoint: .top, endPoint: .bottom)
    )
    .animation(.smooth(duration: 0.25), value: item.sourceBundleID)
  }

  /// 「JSON · 57 字 · 2 分钟前」
  private var meta: String {
    let ago = item.copiedAt.formatted(
      .relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))
    let detail: String =
      switch item.kind {
      case .text: "\(form?.title ?? "文本") · \((item.text ?? "").count) 字"
      case .image:
        item.image.map { "图片 · \($0.byteCount.formatted(.byteCount(style: .file)))" } ?? "图片"
      case .file: "\(item.filePaths?.count ?? 0) 个文件"
      }
    return "\(detail) · \(ago)"
  }

  /// 白字对比度不到 3 : 1 就用黑字（WCAG 相对亮度；页眉是 13 pt semibold，按大字号的标准）
  static func needsDarkText(on color: NSColor) -> Bool {
    guard let rgb = color.usingColorSpace(.sRGB) else { return false }
    func linear(_ c: CGFloat) -> CGFloat {
      c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let luminance =
      0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722
      * linear(rgb.blueComponent)
    return 1.05 / (luminance + 0.05) < 3
  }

  // MARK: 主体

  @ViewBuilder private var content: some View {
    switch item.kind {
    case .text:
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        ColorCard(color: color)
      } else if form == .link, let url = ContentForm.firstLink(in: item.text ?? ""),
        (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 2048
      {
        LinkCard(url: url)
      } else {
        ReadOnlyTextView(
          text: displayText, style: form == .json ? .json : form == .code ? .code : .plain,
          highlights: highlightTokens)
      }
    case .image:
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .topTrailing) {
          Checkerboard()
          ThumbnailView(id: item.id, images: model.store.images, maxPixel: 1024, contentMode: .fit)
            .padding(8)
          if let image = item.image {
            Text(
              "\(image.width)×\(image.height) · \(image.byteCount.formatted(.byteCount(style: .file)))"
            )
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(8)
          }
        }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .frame(maxHeight: 220)
        if let ocr = item.ocrText, !ocr.isEmpty {
          Text("识别到的文字").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
          ScrollView { Text(ocr).font(.system(size: 12)).textSelection(.enabled) }
        }
      }
      .padding(10)
    case .file:
      FileGrid(paths: item.filePaths ?? [])
    }
  }

  /// ponytail: 超长文本只预览前 10 万字，粘贴仍是全文
  private var displayText: String {
    let text = String((item.text ?? "").prefix(100_000))
    guard model.prettyJSON, form == .json,
      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return text }
    return String(decoding: data, as: UTF8.self)
  }

  private var highlightTokens: [String] {
    model.query.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  // MARK: 页脚

  private var footer: some View {
    HStack(spacing: 6) {
      Pill(title: "粘贴", symbol: "arrow.turn.down.left") { model.paste([item]) }
      Pill(title: "复制", symbol: "doc.on.doc") {
        model.select(item)
        model.copySelection()
      }
      if form == .json {
        Pill(title: model.prettyJSON ? "原文" : "美化", symbol: "curlybraces") {
          model.prettyJSON.toggle()
        }
      } else {
        Pill(title: item.favorite ? "取消收藏" : "收藏", symbol: item.favorite ? "star.fill" : "star") {
          model.store.toggleFavorite([item.id])
        }
        .symbolEffect(.bounce, value: item.favorite)
      }
      Spacer(minLength: 0)
      Pill(title: "操作", symbol: "ellipsis", shortcut: "⌘K") { model.showsActions.toggle() }
    }
    .padding(8)
    .overlay(alignment: .top) { Style.hairline.frame(height: 0.5) }
  }
}

/// 无边框胶囊按钮：高 26，12 medium，图标加文字，按下缩到 0.97
private struct Pill: View {
  let title: String
  let symbol: String
  var shortcut: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        Text(title).lineLimit(1)
        if let shortcut {
          Text(shortcut).font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(Style.controlFill, in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(PressScale())
  }
}

/// 按下 scale 0.97（Whisker §3 状态）
struct PressScale: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// 颜色：满宽色块（中央写 HEX，按亮度选黑白字）+ HEX / RGB / HSL / SwiftUI 四行，点一下复制
private struct ColorCard: View {
  let color: ContentForm.RGBA
  @State private var copied: Int?

  var body: some View {
    let values = Self.values(color)
    VStack(alignment: .leading, spacing: 8) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(color))
        .background(Checkerboard().clipShape(.rect(cornerRadius: 8, style: .continuous)))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
            .white.opacity(0.2), lineWidth: 1)
        )
        .overlay {
          Text(values[0])
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(Self.isLight(color) ? .black.opacity(0.8) : .white)
        }
        // 高度自适应：卡片矮时色块让出空间给四行色值
        .frame(minHeight: 72, maxHeight: 150)
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        Button {
          Paster.write(string: value)
          copied = index
          Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copied == index { copied = nil }
          }
        } label: {
          HStack {
            Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            Spacer()
            Image(systemName: copied == index ? "checkmark" : "doc.on.doc")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(copied == index ? Color(nsColor: .systemGreen) : .secondary)
              .contentTransition(.symbolEffect(.replace))
          }
          .padding(.horizontal, 6)
          .frame(height: 26)
          .contentShape(.rect)
        }
        .buttonStyle(PressScale())
      }
    }
    .padding(10)
  }

  static func values(_ c: ContentForm.RGBA) -> [String] {
    let r = Int((c.red * 255).rounded())
    let g = Int((c.green * 255).rounded())
    let b = Int((c.blue * 255).rounded())
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
      .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    // HSV → HSL
    let lightness = brightness * (1 - saturation / 2)
    let hslSaturation =
      lightness == 0 || lightness == 1
      ? 0 : (brightness - lightness) / min(lightness, 1 - lightness)
    return [
      String(format: "#%02X%02X%02X", r, g, b),
      c.alpha < 1
        ? "rgba(\(r), \(g), \(b), \(String(format: "%.2f", c.alpha)))" : "rgb(\(r), \(g), \(b))",
      "hsl(\(Int((hue * 360).rounded())), \(Int((hslSaturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)",
      String(format: "Color(red: %.2f, green: %.2f, blue: %.2f)", c.red, c.green, c.blue),
    ]
  }

  static func isLight(_ c: ContentForm.RGBA) -> Bool {
    0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.62
  }
}

/// 链接：大号网站卡（域名 + 完整网址）。ponytail: 头图和标题要联网取（LinkPresentation），D 阶段再加
private struct LinkCard: View {
  let url: URL

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        LinearGradient(
          colors: [Style.Family.url.opacity(0.35), Style.Family.search.opacity(0.35)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
        KindTile(symbol: "globe", color: Style.Family.url, size: 48)
      }
      .frame(height: 120)
      .clipShape(.rect(cornerRadius: 8, style: .continuous))
      Text(url.host() ?? url.absoluteString)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(2)
      Text(url.absoluteString)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .padding(10)
  }
}

/// 文件：6 个以内排 64 pt 的 Quick Look 缩略图网格加文件名，更多时用列表
private struct FileGrid: View {
  let paths: [String]

  var body: some View {
    if paths.count <= 6 {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 12) {
          ForEach(paths, id: \.self) { path in
            VStack(spacing: 6) {
              FileThumbnail(path: path).frame(width: 64, height: 64)
              Text(URL(filePath: path).lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            }
            .help(path)
          }
        }
        .padding(12)
      }
    } else {
      List(paths.prefix(120), id: \.self) { path in
        HStack(spacing: 8) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(
            width: 18, height: 18)
          VStack(alignment: .leading, spacing: 0) {
            Text(URL(filePath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
    }
  }
}

/// Quick Look 缩略图（PDF 首页、图片、视频帧）；生成前先显示系统图标
private struct FileThumbnail: View {
  let path: String
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
      }
    }
    .task(id: path) {
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      let request = QLThumbnailGenerator.Request(
        fileAt: URL(filePath: path), size: CGSize(width: 64, height: 64), scale: scale,
        representationTypes: .thumbnail)
      let cgImage: CGImage? = await withCheckedContinuation { continuation in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
          continuation.resume(returning: representation?.cgImage)
        }
      }
      if let cgImage { image = NSImage(cgImage: cgImage, size: .zero) }
    }
  }
}

/// 代码 / JSON 语法着色（纯函数，配单测）：字符串红、数字紫、关键字粉（semibold）、注释灰斜体、JSON 键蓝。
/// ponytail: 通用的类 C 分词，只着这五类；只着前 2 万字
enum SyntaxHighlight {
  enum Language { case plain, json, code }

  static let keywords = [
    "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class",
    "enum",
    "case", "switch", "true", "false", "nil", "null", "const", "function", "def", "public",
    "private",
    "static", "new", "this", "self", "in", "try", "catch", "async", "await", "guard", "break",
    "continue", "type", "interface", "extends", "package", "fn", "pub", "use", "mut", "impl",
    "match",
  ]

  static func attributed(_ text: String, language style: Language, font: NSFont)
    -> NSAttributedString
  {
    let result = NSMutableAttributedString(
      string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    guard style != .plain else { return result }
    let limit = min((text as NSString).length, 20_000)
    let range = NSRange(location: 0, length: limit)
    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    func paint(_ pattern: String, _ attributes: [NSAttributedString.Key: Any], group: Int = 0) {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
      for match in regex.matches(in: text, range: range) {
        result.addAttributes(attributes, range: match.range(at: group))
      }
    }
    paint(#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, [.foregroundColor: NSColor.systemPurple])
    let words = style == .json ? ["true", "false", "null"] : keywords
    paint(
      #"\b("# + words.joined(separator: "|") + #")\b"#,
      [.foregroundColor: NSColor.systemPink, .font: bold])
    paint(#""(?:\\.|[^"\\\n])*""#, [.foregroundColor: NSColor.systemRed])
    if style == .json {
      paint(#"("(?:\\.|[^"\\\n])*")\s*:"#, [.foregroundColor: NSColor.systemBlue], group: 1)
    } else {
      paint(#"'(?:\\.|[^'\\\n])*'"#, [.foregroundColor: NSColor.systemRed])
      let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      paint(
        #"//[^\n]*|/\*[\s\S]*?\*/"#, [.foregroundColor: NSColor.secondaryLabelColor, .font: italic])
    }
    return result
  }
}

/// 只读长文本（NSTextView，TextKit 2）：可选中、可滚动，高亮搜索词；代码 / JSON 着色
private struct ReadOnlyTextView: NSViewRepresentable {
  let text: String
  let style: SyntaxHighlight.Language
  let highlights: [String]

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    let textView = scroll.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 10, height: 12)
    scroll.drawsBackground = false
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView else { return }
    let font: NSFont =
      style == .plain
      ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 12, weight: .regular)
    let attributed = NSMutableAttributedString(
      attributedString: SyntaxHighlight.attributed(text, language: style, font: font))
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = style == .plain ? 3 : 2
    attributed.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
    let nsText = text as NSString
    for token in highlights where !token.isEmpty {
      var range = NSRange(location: 0, length: nsText.length)
      while true {
        let found = nsText.range(of: token, options: Search.options, range: range)
        guard found.location != NSNotFound else { break }
        attributed.addAttribute(
          .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: found)
        range = NSRange(location: NSMaxRange(found), length: nsText.length - NSMaxRange(found))
      }
    }
    textView.textStorage?.setAttributedString(attributed)
    textView.scrollToBeginningOfDocument(nil)
  }
}
