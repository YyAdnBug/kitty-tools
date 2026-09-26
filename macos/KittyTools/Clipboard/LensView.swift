// 剪贴板透镜（Lens Bar，mac-whisker §6 剪贴板）：选中行在原地展开的预览。第一行就是普通行（ClipRowView，40），
// 下面是按类型定高的正文区（左边对齐标题列 x = 44、右内边距 12）+ 22 pt 元信息行 + 底 8。
// 正文区高度只查表（Lens.bodyHeight），不量内在尺寸、不按行数估：高亮块的前缀和、滚动、窗口的透镜预留都靠它算得准；
// 正文放进固定高度的 frame 裁切、底部 12 pt 渐隐。文本 90（短文本 36）、代码 / JSON 128（行号 + 语法着色）、
// 颜色 72（色块 + 四枚值胶囊，点一下复制）、链接 90（头图 + 标题 + 网址，LinkPreview 停留 0.25 s 才取）、
// 图片 108（缩略图 + 尺寸 + 识别文字）、文件 76（Quick Look 缩略图条）。
// 正文不可选中（焦点一直在搜索框，⌘ 快捷键都有效），要选文字按 ⌘Y。有搜索词时从第一个命中处摘录并高亮。

import AppKit
import SwiftUI

enum Lens {
  /// 行头（= ClipRowView.height）、元信息行、底
  static let head: CGFloat = 40
  static let meta: CGFloat = 22
  static let bottom: CGFloat = 8
  /// 最高的透镜（代码 / JSON）比普通行多出来的：窗口一直按它预留，↑↓ 永远不改窗口高度
  static let reserve: CGFloat = 128 + meta + bottom

  /// 正文区高度（查表，mac-whisker §6）
  static func bodyHeight(for item: ClipItem, form: ContentForm?) -> CGFloat {
    switch item.kind {
    case .image: 108
    case .file: 76
    case .text:
      switch form {
      case .color: 72
      case .code, .json: 128
      case .link: 90
      case nil: isShort(item.text ?? "") ? 36 : 90
      }
    }
  }

  /// 透镜总高 = 行头 + 正文 + 元信息 + 底（最高 198）
  static func height(for item: ClipItem, form: ContentForm?) -> CGFloat {
    head + bodyHeight(for: item, form: form) + meta + bottom
  }

  /// 没有换行且不超过 60 字：两行高就够，免得一行字下面空一大块
  static func isShort(_ text: String) -> Bool {
    let trimmed = text.prefix(400).trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count <= 60 && !trimmed.contains(where: \.isNewline)
  }

  /// 搜索词命中的底色（systemYellow 0.35，和 ⌘Y 大卡的 NSTextView 高亮同色）
  static let hitColor = Color(nsColor: .systemYellow).opacity(0.35)

  /// VoiceOver 的透镜值：「类型 · 前 200 字」
  static func accessibilityValue(for item: ClipItem, form: ContentForm?) -> String {
    let body =
      switch item.kind {
      case .text: String((item.text ?? "").prefix(200))
      case .image: item.ocrText.map { String($0.prefix(200)) } ?? ""
      case .file: item.title
      }
    return "\(typeTitle(item, form: form)) · \(body)"
  }

  static func typeTitle(_ item: ClipItem, form: ContentForm?) -> String {
    switch item.kind {
    case .text: form?.title ?? (item.richType != nil ? "富文本" : "文本")
    case .image: "图片"
    case .file: "文件"
    }
  }

  /// NSAttributedString（语法着色）→ SwiftUI Text 认的 AttributedString：只搬字色和字体
  static func swiftUI(_ source: NSAttributedString) -> AttributedString {
    var result = AttributedString()
    source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) {
      attributes, range, _ in
      var run = AttributedString((source.string as NSString).substring(with: range))
      if let color = attributes[.foregroundColor] as? NSColor {
        run.swiftUI.foregroundColor = Color(nsColor: color)
      }
      if let font = attributes[.font] as? NSFont { run.swiftUI.font = Font(font as CTFont) }
      result += run
    }
    return result
  }
}

extension AttributedString {
  /// 给搜索词的每个命中加黄底（比较口径同搜索：不分大小写、全半角、变音符号）
  mutating func highlight(_ query: String) {
    for token in Search.tokens(query) {
      var start = startIndex
      while start < endIndex, let range = self[start...].range(of: token, options: Search.options) {
        self[range].swiftUI.backgroundColor = Lens.hitColor
        start = range.upperBound
      }
    }
  }
}

/// 透镜的正文区 + 元信息行（行头由列表画）
struct LensView: View {
  let item: ClipItem
  let form: ContentForm?
  let model: ClipboardPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Lens.bodyHeight(for: item, form: form), alignment: .topLeading)
        .clipped()
        .fading(when: fades)
      meta.frame(height: Lens.meta)
    }
    .padding(.leading, 44)
    .padding(.trailing, 12)
    .padding(.bottom, Lens.bottom)
  }

  @ViewBuilder private var content: some View {
    switch item.kind {
    case .text:
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        ColorLens(color: color)
      } else if form == .link, let url = ContentForm.firstLink(in: item.text ?? "") {
        LinkCard(url: url, text: item.text ?? "", compact: true)
      } else if form == .code || form == .json {
        CodeLens(text: model.displayText(of: item), json: form == .json, query: model.query)
      } else if Lens.isShort(item.text ?? "") {
        Text(highlighted(item.text ?? ""))
          .font(.system(size: 13))
          .lineSpacing(3)
          .lineLimit(2)
      } else {
        let text = String((item.text ?? "").prefix(20_000))
        let shown =
          Search.excerpt(of: text, query: model.query, before: 40, after: 600)
          ?? String(text.prefix(640))
        Text(highlighted(shown))
          .font(.system(size: 13))
          .lineSpacing(3)
          .foregroundStyle(Color(nsColor: .labelColor))  // 渐隐遮罩里不能用层级色，见 fading
          .fixedSize(horizontal: false, vertical: true)
      }
    case .image:
      ImageLens(item: item, images: model.store.images)
    case .file:
      FileStrip(paths: item.filePaths ?? [])
    }
  }

  /// 会超出正文区的（长文本、代码 / JSON）底部渐隐；短文本、颜色、链接、图片、文件本来就放得下
  private var fades: Bool {
    item.kind == .text && form != .color && form != .link && !Lens.isShort(item.text ?? "")
  }

  private func highlighted(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    attributed.highlight(model.query)
    return attributed
  }

  /// 「代码 · 70 字 · 14:02 · [图标] Xcode」，JSON 右边多一个「美化 / 原文」
  private var meta: some View {
    HStack(spacing: 6) {
      Text(metaText).lineLimit(1)
      if let icon = AppIcons.icon(for: item.sourceBundleID) {
        Text("·")
        Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
      }
      if let name = item.sourceName {
        Text(name).lineLimit(1)
      }
      Spacer(minLength: 8)
      if form == .json {
        Button(model.prettyJSON ? "原文" : "美化") { model.prettyJSON.toggle() }
          .buttonStyle(.plain)
          .foregroundStyle(Style.brandInk)
          .pointerStyle(.link)
          .help("⌘K 里也有「美化 JSON」")
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }

  private var metaText: String {
    let detail: String? =
      switch item.kind {
      case .text: "\((item.text ?? "").count) 字"
      case .image:
        item.image.map {
          "\($0.width)×\($0.height) · \($0.byteCount.formatted(.byteCount(style: .file)))"
        }
      case .file: "\(item.filePaths?.count ?? 0) 个"
      }
    return [Lens.typeTitle(item, form: form), detail, Self.exactTime(item.copiedAt)]
      .compactMap { $0 }.joined(separator: " · ")
  }

  /// 今天写 14:02，更早写 9月25日 14:02（跨年带年份）
  static func exactTime(_ date: Date) -> String {
    let chinese = Locale(identifier: "zh-Hans")
    let time = date.formatted(
      .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(chinese))
    if Calendar.current.isDateInToday(date) { return time }
    let day =
      Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
      ? date.formatted(.dateTime.month().day().locale(chinese))
      : date.formatted(.dateTime.year().month().day().locale(chinese))
    return "\(day) \(time)"
  }
}

extension View {
  /// 正文区底部 12 pt 渐隐（裁切后的长正文）。只在要渐隐时挂遮罩：遮罩让正文离屏合成，材质上的层级前景色
  /// （.primary / .tertiary 的混合）在里面画出来发白、发虚（截图自检实测），所以渐隐的正文一律用具体的系统颜色
  @ViewBuilder fileprivate func fading(when fades: Bool) -> some View {
    if fades {
      mask {
        VStack(spacing: 0) {
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 12)
        }
      }
    } else {
      self
    }
  }
}

/// 代码 / JSON：SF Mono 12 行距 2、语法着色、tertiary 行号；有搜索词时从命中那一行的上一行开始
private struct CodeLens: View {
  let text: String
  let json: Bool
  let query: String

  var body: some View {
    let (first, lines) = shownLines()
    let digits = CGFloat(String(first + lines.count).count)
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("\(first + index + 1)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))  // 在渐隐遮罩里，见 fading
            .frame(width: digits * 7 + 2, alignment: .trailing)
          Text(line).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// 第一行的下标 + 要显示的几行（已着色、已高亮）。
  /// ponytail: 只取前 2 万字、显示 10 行、每行前 300 字（透镜 128 pt 放 7 行半，多的本来就裁掉）
  private func shownLines() -> (first: Int, lines: [AttributedString]) {
    let source = String(text.prefix(20_000))
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let first =
      Search.firstHit(in: source, query: query).map {
        max(0, source[..<$0.lowerBound].count(where: { $0 == "\n" }) - 1)
      } ?? 0
    let shown = lines[first..<min(first + 10, lines.count)].map { String($0.prefix(300)) }
    let colored = SyntaxHighlight.attributed(
      shown.joined(separator: "\n"), language: json ? .json : .code,
      font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    var location = 0
    return (
      first,
      shown.map { line in
        let length = (line as NSString).length
        defer { location += length + 1 }
        var run = Lens.swiftUI(
          colored.attributedSubstring(from: NSRange(location: location, length: length)))
        run.highlight(query)
        return run
      }
    )
  }
}

/// 颜色：左 120×72 色块（棋盘格底、HEX 22 Rounded，黑白字按亮度），右边两列四枚值胶囊，点一下复制、图标换对勾
private struct ColorLens: View {
  let color: ContentForm.RGBA
  @State private var copied: Int?

  var body: some View {
    let values = ColorCard.values(color)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    HStack(alignment: .top, spacing: 12) {
      shape.fill(Color(color))
        .background(Checkerboard().clipShape(shape))
        .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .overlay {
          Text(values[0])
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .foregroundStyle(ColorCard.isLight(color) ? .black.opacity(0.8) : .white)
        }
        .frame(width: 120, height: 72)
      Grid(horizontalSpacing: 8, verticalSpacing: 8) {
        GridRow {
          chip(values, 0)
          chip(values, 1)
        }
        GridRow {
          chip(values, 2)
          chip(values, 3)
        }
      }
      .frame(maxWidth: 440)
    }
  }

  private func chip(_ values: [String], _ index: Int) -> some View {
    Button {
      Paster.write(string: values[index])
      copied = index
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        if copied == index { copied = nil }
      }
    } label: {
      HStack(spacing: 6) {
        Text(values[index])
          .font(.system(size: 11, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        Image(systemName: copied == index ? "checkmark" : "doc.on.doc")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(copied == index ? Color(nsColor: .systemGreen) : .secondary)
          .contentTransition(.symbolEffect(.replace))
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 32)
      .background(Style.controlFill, in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(PressScale())
    .help("复制 \(values[index])")
  }
}

/// 图片：8 pt 棋盘格上的缩略图（高 108、保持比例、左对齐），右边「宽×高 · 大小」胶囊 + 识别文字前 3 行
private struct ImageLens: View {
  let item: ClipItem
  let images: ImageStore

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    let ratio = item.image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Checkerboard(cell: 8)
        ThumbnailView(id: item.id, images: images, maxPixel: 720, contentMode: .fit)
      }
      .frame(width: min(max(108 * ratio, 60), 360), height: 108)
      .clipShape(shape)
      .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
      VStack(alignment: .leading, spacing: 6) {
        if let image = item.image {
          Text(
            verbatim:
              "\(image.width)×\(image.height) · \(image.byteCount.formatted(.byteCount(style: .file)))"
          )
          .font(.system(size: 11, weight: .medium))
          .padding(.horizontal, 8)
          .frame(height: 20)
          .background(Style.controlFill, in: .capsule)
        }
        if let ocr = item.ocrText, !ocr.isEmpty {
          Text(ocr)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }
    }
  }
}

/// 文件：一排最多 6 个 48 pt Quick Look 缩略图 + 11 pt 文件名，多的写「+N」
private struct FileStrip: View {
  let paths: [String]

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ForEach(paths.prefix(6), id: \.self) { path in
        VStack(spacing: 4) {
          FileThumbnail(path: path, side: 48).frame(width: 48, height: 48)
          Text(URL(filePath: path).lastPathComponent)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 72)
        }
        .help(path)
      }
      if paths.count > 6 {
        Text("+\(paths.count - 6)")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(height: 48)
      }
    }
  }
}
