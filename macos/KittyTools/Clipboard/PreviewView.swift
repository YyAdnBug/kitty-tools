// ⌘Y 放大卡 = 剪贴板的完整检查器（Whisker，mac-whisker §6 剪贴板；主界面只有透镜 LensView，这张卡只在 QuickLookView 里）：
// 内缩 6、圆角 10 的一张卡（Style.CardSurface，不加阴影）。页眉 40 pt 取来源 App 图标的颜色（对比度不够时改黑字，**只在这里**，主界面保持中性），
// 写 App 名和「类型 · 大小 · 精确时间」（同透镜）；主体按类型出大预览（字号 ×1.2、文字可选中）：颜色 = 大色块 + HEX / RGB / HSL /
// SwiftUI 四行点击复制；代码 / JSON = SF Mono + 语法着色；链接 = 300 pt 头图 + 标题 + 网站名（LinkPreview 联网取）；
// 图片 = 棋盘格上的原尺寸图（比图片区小时居中）+ 右上角的宽×高胶囊（大小只在页眉）+ 识别文字；单个文件 Quick Look、多个文件缩略图网格
// （超过 120 个时末尾写「还有 N 个」）；文本高亮搜索词。
// 页脚最多 4 个无边框胶囊按钮：粘贴、复制、按类型的第 3 个（链接「打开」、文件「在访达中显示」、图片「钉到屏幕」、
// JSON「美化 / 原文」、其余「收藏」）、操作 ⌘K，其余操作在 ⌘K 面板。选中文字 ⌘C 只拷纯文本（CopyPlainTextView）。
// 换条目时内容淡入上浮、页眉颜色渐变过去。
// 链接卡（compact 版给透镜）、文件缩略图、语法着色也放在这里。

import AppKit
import QuickLookThumbnailing
import SwiftUI

struct PreviewView: View {
  let item: ClipItem
  @Bindable var model: ClipboardPanelModel
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
    .clipShape(shape)
    .cardSurface()
    .padding(6)
  }

  // MARK: 页眉

  private var header: some View {
    let (tint, darkText) = Self.headerStyle(for: AppIcons.accentColor(for: item.sourceBundleID))
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

  /// 「JSON · 57 字 · 14:02」（时间写法同透镜的元信息行）
  private var meta: String {
    let time = LensView.exactTime(item.copiedAt)
    let detail: String =
      switch item.kind {
      case .text: "\(form?.title ?? "文本") · \((item.text ?? "").count) 字"
      case .image:
        item.image.map { "图片 · \($0.byteCount.formatted(.byteCount(style: .file)))" } ?? "图片"
      case .file: "\(item.filePaths?.count ?? 0) 个文件"
      }
    return "\(detail) · \(time)"
  }

  /// 页眉底色和字色（WCAG AA 4.5 : 1）：白字够就用白字；差得不多（相对亮度 < 0.3）就把底色压暗到够，
  /// 保住「彩色页眉 + 白字」；再亮的（黄、浅灰、亮绿）用黑字
  static func headerStyle(for tint: NSColor) -> (background: NSColor, darkText: Bool) {
    guard var color = tint.usingColorSpace(.sRGB) else { return (tint, false) }
    func luminance(_ c: NSColor) -> CGFloat {
      func linear(_ v: CGFloat) -> CGFloat {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722
        * linear(c.blueComponent)
    }
    if luminance(color) >= 0.3 { return (color, true) }
    for _ in 0..<12 where 1.05 / (luminance(color) + 0.05) < 4.5 {
      color = color.blended(withFraction: 0.08, of: .black)?.usingColorSpace(.sRGB) ?? color
    }
    return (color, false)
  }

  // MARK: 主体

  @ViewBuilder private var content: some View {
    switch item.kind {
    case .text:
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        ColorCard(color: color)
      } else if form == .link, let url = ContentForm.firstLink(in: item.text ?? "") {
        LinkCard(url: url, text: item.text ?? "")
      } else {
        ReadOnlyTextView(
          text: model.displayText(of: item),
          style: form == .json ? .json : form == .code ? .code : .plain,
          highlights: Search.tokens(model.query), fontScale: 1.2, onCopy: model.copySelectedText)
      }
    case .image:
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .topTrailing) {
          Checkerboard()
          ThumbnailView(id: item.id, images: model.store.images, maxPixel: 2400, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Style.Radius.control, style: .continuous))
            .padding(8)
            // 图片比这块区域窄 / 矮时居中：不撑满的话它会跟着 ZStack 的对齐（给下面的胶囊用的）贴到右上角
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          // 大小已在页眉，这里只写宽×高
          if let image = item.image {
            Text(verbatim: "\(image.width)×\(image.height)")
              .font(.system(size: 11, weight: .medium))
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(.ultraThinMaterial, in: .capsule)
              .padding(8)
          }
        }
        .clipShape(.rect(cornerRadius: Style.Radius.card - 2, style: .continuous))
        .frame(maxHeight: .infinity)
        // 完整检查器：大图下面也给识别到的文字（可选中，⌘C 同正文只拷纯文本）
        if let ocr = item.ocrText, !ocr.isEmpty {
          Text("识别到的文字").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
          ReadOnlyTextView(
            text: ocr, style: .plain, highlights: Search.tokens(model.query), inset: .zero,
            onCopy: model.copySelectedText
          )
          .frame(maxHeight: QuickLookView.ocrHeight)
        }
      }
      .padding(10)
    case .file:
      if let paths = item.filePaths, paths.count == 1 {
        QuickLookFile(url: URL(filePath: paths[0]))
      } else {
        FileGrid(paths: item.filePaths ?? [])
      }
    }
  }

  // MARK: 页脚

  private var footer: some View {
    HStack(spacing: 6) {
      Pill(title: "粘贴", symbol: "arrow.turn.down.left") { model.paste([item]) }
      // 复制的是这张卡上的这一条，不管列表里勾选了什么（体检 B9）
      Pill(title: "复制", symbol: "doc.on.doc") { model.copy([item]) }
      typePill

      Spacer(minLength: 0)
      Pill(title: "操作", symbol: "ellipsis", shortcut: "⌘K") { model.showsActions.toggle() }
    }
    .padding(8)
    .overlay(alignment: .top) { Hairline() }
  }

  /// 第 3 个胶囊按类型（体检 D2）：链接「打开」、文件「在访达中显示」、图片「钉到屏幕」、JSON「美化 / 原文」、其余「收藏」
  @ViewBuilder private var typePill: some View {
    if form == .link, let url = ContentForm.firstLink(in: item.text ?? "") {
      Pill(title: "打开", symbol: "safari") { model.openLink(url) }
    } else if item.kind == .file {
      Pill(title: "在访达中显示", symbol: "folder") { model.revealInFinder(item) }
    } else if item.kind == .image {
      Pill(title: "钉到屏幕", symbol: "pin") { model.pin([item]) }
    } else if form == .json {
      Pill(title: model.prettyJSON ? "原文" : "美化", symbol: "curlybraces") {
        model.prettyJSON.toggle()
      }
    } else {
      Pill(title: item.favorite ? "取消收藏" : "收藏", symbol: item.favorite ? "star.fill" : "star") {
        model.toggleFavorite([item.id])
      }
      .symbolEffect(.bounce, value: item.favorite)
    }
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
struct ColorCard: View {
  let color: ContentForm.RGBA
  @State private var copied: Int?

  var body: some View {
    let values = Self.values(color)
    // 大卡内缩 10 > 8：色块圆角用 card（Whisker §3 同心规则）
    let swatch = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: 8) {
      swatch
        .fill(Color(color))
        .background(Checkerboard().clipShape(swatch))
        .overlay(swatch.strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .overlay {
          Text(values[0])
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(Self.isLight(color) ? .black.opacity(0.8) : .white)
        }
        .frame(minHeight: 72, maxHeight: .infinity)
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        Button {
          // 面板开着时复制的色值块不记进历史（记新条目会把选中跳走，mac-native §5）；焦点在搜索框，主动播报
          Paster.write(string: value)
          Island.announce("已复制 \(value)")
          copied = index
          Task {
            try? await Task.sleep(for: Style.copiedHold)
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

  /// 半透明时 HEX 带 AA、HSL 用 hsla、SwiftUI 带 opacity
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
    let translucent = c.alpha < 1
    let alpha = String(format: "%.2f", c.alpha)
    let hsl =
      "\(Int((hue * 360).rounded())), \(Int((hslSaturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
    return [
      String(format: "#%02X%02X%02X", r, g, b)
        + (translucent ? String(format: "%02X", Int((c.alpha * 255).rounded())) : ""),
      translucent ? "rgba(\(r), \(g), \(b), \(alpha))" : "rgb(\(r), \(g), \(b))",
      translucent ? "hsla(\(hsl), \(alpha))" : "hsl(\(hsl))",
      String(format: "Color(red: %.2f, green: %.2f, blue: %.2f", c.red, c.green, c.blue)
        + (translucent ? ", opacity: \(alpha))" : ")"),
    ]
  }

  /// 色块上的字用黑还是白：很透明时底下是浅色棋盘格，按浅色算
  static func isLight(_ c: ContentForm.RGBA) -> Bool {
    c.alpha < 0.5 || 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.62
  }
}

/// 链接：头图 + 标题 + 网站图标和名字 + 完整网址。设置里开着链接预览时，选中停留 0.25 s 后联网取（LinkPreview）：
/// 取的时候头图区扫光，标题、头图到了就淡入；网页没给头图时是取网站图标颜色的渐变 + 大图标。
/// compact：透镜里的横排版（左 160×90 头图，右标题 ≤ 2 行 + 网站 + 网址，不可选中）；否则 ⌘Y 大卡的竖排版（头图 300）
struct LinkCard: View {
  let url: URL
  let text: String
  var compact = false
  @AppStorage(Prefs.clipboardLinkPreview) private var fetches = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // 开关关着时连取过的也不显示（设置说的是「显示」）
    let entry = fetches ? LinkPreview.shared.entry(for: url) : nil
    let heroShape = RoundedRectangle(
      cornerRadius: compact ? Style.Radius.control : Style.Radius.card - 2, style: .continuous)
    let hero = LinkHero(entry: entry)
      .accessibilityHidden(true)  // 标题、网站名已经在旁边说清楚了
      .clipShape(heroShape)
      .overlay(heroShape.hairlineBorder())
    Group {
      if compact {
        HStack(alignment: .top, spacing: 12) {
          hero.frame(width: 160, height: 90)
          details(entry, selectableURL: false).padding(.top, 2)
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          hero.frame(height: 300)
          details(entry, selectableURL: true)
        }
        .padding(10)
      }
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: entry?.metadata)
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: entry?.isLoading)
    .task(id: url) {
      guard fetches, LinkPreview.isFetchable(url), !ClipboardFilter.looksSensitive(text) else {
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await LinkPreview.shared.load(url)
    }
  }

  /// 标题 + 网站 + 网址；大卡的网址可选中、两行，透镜里一行
  private func details(_ entry: LinkPreview.Entry?, selectableURL selectable: Bool) -> some View {
    let host = url.host() ?? url.absoluteString
    return VStack(alignment: .leading, spacing: compact ? 5 : 8) {
      Text(entry?.metadata.title ?? host)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(2)
        .contentTransition(.opacity)
        .padding(.top, compact ? 0 : 2)
      HStack(spacing: 6) {
        if let icon = entry?.icon {
          Image(nsImage: icon).resizable().interpolation(.high)
            .frame(width: 14, height: 14)
            .clipShape(.rect(cornerRadius: Style.Radius.tile(14), style: .continuous))
            .accessibilityHidden(true)
        } else {
          Image(systemName: "globe").font(.system(size: 11, weight: .medium))
            .accessibilityHidden(true)
        }
        Text(entry?.metadata.siteName.map { "\($0) · \(host)" } ?? host)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      Group {
        if selectable {
          Text(url.absoluteString).lineLimit(2).textSelection(.enabled)
        } else {
          Text(url.absoluteString).lineLimit(1)
        }
      }
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(.tertiary)
      .truncationMode(.middle)
    }
  }
}

/// 链接卡的头图区：头图铺满裁切；没有时渐变（网站图标的主色，没有就网址家族色）+ 44 pt 图标
private struct LinkHero: View {
  let entry: LinkPreview.Entry?

  var body: some View {
    let tint = entry?.tint.map { Color(nsColor: $0) }
    ZStack {
      LinearGradient(
        colors: [
          (tint ?? Style.Family.url).opacity(0.45), (tint ?? Style.Family.search).opacity(0.25),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      if let icon = entry?.icon {
        Image(nsImage: icon).resizable().interpolation(.high)
          .frame(width: 44, height: 44)
          .clipShape(.rect(cornerRadius: Style.Radius.tile(44), style: .continuous))
          .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
      } else {
        KindTile(symbol: "globe", color: Style.Family.url, size: 44)
      }
      if let image = entry?.image {
        // 放在 overlay 里铺满：scaledToFill 的图不参与布局，不会把卡片撑宽；裁掉的部分也不接点击
        Color.clear
          .overlay { Image(nsImage: image).resizable().scaledToFill().allowsHitTesting(false) }
          .clipped()
          .transition(.opacity)
      }
      if entry?.isLoading == true {
        SweepHighlight().transition(.opacity)
      }
    }
  }
}

/// 取预览时头图区的扫光（ambient：1.3 s 一趟，只在取的时候挂着）；减弱动态效果时是一层静止的淡白
private struct SweepHighlight: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      Color.white.opacity(0.14).allowsHitTesting(false).accessibilityLabel("正在读取网页")
    } else {
      sweep
    }
  }

  private var sweep: some View {
    TimelineView(.animation) { context in
      let phase =
        context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
      LinearGradient(
        stops: [
          .init(color: .white.opacity(0), location: 0),
          .init(color: .white.opacity(0.28), location: 0.5),
          .init(color: .white.opacity(0), location: 1),
        ],
        startPoint: UnitPoint(x: phase * 3 - 2, y: 0.3),
        endPoint: UnitPoint(x: phase * 3 - 1, y: 0.7))
    }
    .allowsHitTesting(false)
    .accessibilityLabel("正在读取网页")
  }
}

/// 文件：6 个以内排 64 pt 的 Quick Look 缩略图网格加文件名，更多时用列表
private struct FileGrid: View {
  let paths: [String]
  static let listLimit = 120

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
      // ponytail: 最多列 120 个（每行都要取系统图标），多的在末尾说一声；真有人复制上千个文件再改成懒加载
      List {
        ForEach(paths.prefix(Self.listLimit), id: \.self) { path in
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
        if paths.count > Self.listLimit {
          Text("还有 \(paths.count - Self.listLimit) 个")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
    }
  }
}

/// Quick Look 缩略图（PDF 首页、图片、视频帧）；生成前先显示系统图标
struct FileThumbnail: View {
  let path: String
  var side: CGFloat = 64
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
        fileAt: URL(filePath: path), size: CGSize(width: side, height: side), scale: scale,
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
    if style == .json {
      paint(#""(?:\\.|[^"\\\n])*""#, [.foregroundColor: NSColor.systemRed])
      paint(#"("(?:\\.|[^"\\\n])*")\s*:"#, [.foregroundColor: NSColor.systemBlue], group: 1)
      return result
    }
    // 字符串和注释一趟从左往右扫：先开始的赢（字符串里的 // 不是注释，注释里的引号也不是字符串）
    let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    let tokens = try? NSRegularExpression(
      pattern: #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|//[^\n]*|/\*[\s\S]*?\*/"#)
    for match in tokens?.matches(in: text, range: range) ?? [] {
      let isComment = (text as NSString).substring(with: match.range).hasPrefix("/")
      result.addAttributes(
        isComment
          ? [.foregroundColor: NSColor.secondaryLabelColor, .font: italic]
          : [.foregroundColor: NSColor.systemRed, .font: font], range: match.range)
    }
    return result
  }
}

/// 只读长文本（NSTextView）：可选中、可滚动，高亮搜索词；代码 / JSON 着色（只给 ⌘Y 大卡：
/// 透镜里不用它，免得滚轮被它吃掉、点一下抢走搜索框的焦点）。⌘C 交给 onCopy 只拷纯文本（体检 B11）
private struct ReadOnlyTextView: NSViewRepresentable {
  let text: String
  let style: SyntaxHighlight.Language
  let highlights: [String]
  var fontScale: CGFloat = 1
  var inset = NSSize(width: 10, height: 12)
  let onCopy: (String) -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let textView = CopyPlainTextView(frame: .zero)
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = inset
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = textView
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? CopyPlainTextView else { return }
    textView.onCopy = onCopy
    let font: NSFont =
      style == .plain
      ? .systemFont(ofSize: 13 * fontScale)
      : .monospacedSystemFont(ofSize: 12 * fontScale, weight: .regular)
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

/// ⌘C（和右键「拷贝」）只拷选中的纯文本，交给 onCopy 经 Paster.write 写：系统的复制会把语法着色、搜索词黄底、放大的字号
/// 一起写成 RTF（这条历史再粘贴会带黄底），watcher 还会把来源记成前台的别的 App、触发复制即译（体检 B11）
final class CopyPlainTextView: NSTextView {
  var onCopy: ((String) -> Void)?

  override func copy(_ sender: Any?) {
    let whole = string as NSString
    let parts = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map {
      whole.substring(with: $0)
    }
    guard let onCopy, !parts.isEmpty else { return super.copy(sender) }
    onCopy(parts.joined(separator: "\n"))
  }
}
