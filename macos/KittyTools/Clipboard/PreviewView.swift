// 剪贴板预览（检查器式）：上部按类型展示内容（颜色色块 / JSON 可美化 / 代码等宽 / 图片 + 识别文字 /
// 文件列表），高亮搜索词；下部是信息区（来源、时间、内容、分组）和两列操作按钮。

import AppKit
import SwiftUI

struct PreviewView: View {
  let item: ClipItem
  @Bindable var model: ClipboardPanelModel

  private var form: ContentForm? { model.contentForm(of: item) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        info
        actionGrid
      }
      .padding(12)
    }
    .background(.primary.opacity(0.03))
  }

  @ViewBuilder private var content: some View {
    switch item.kind {
    case .text:
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        VStack(alignment: .leading, spacing: 10) {
          RoundedRectangle(cornerRadius: 10)
            .fill(Color(color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .frame(height: 110)
          Text(item.text ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
        .padding(12)
      } else {
        ReadOnlyTextView(
          text: displayText, monospaced: form == .json || form == .code, highlights: highlightTokens
        )
      }
    case .image:
      VStack(alignment: .leading, spacing: 8) {
        ThumbnailView(id: item.id, images: model.store.images, maxPixel: 1024, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: 220)
        if let ocr = item.ocrText, !ocr.isEmpty {
          Text("识别到的文字").font(.caption).foregroundStyle(.secondary)
          ScrollView { Text(ocr).font(.callout).textSelection(.enabled) }
        }
      }
      .padding(12)
    case .file:
      FileListView(paths: item.filePaths ?? [])
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

  /// 信息区：来源、时间、类型与大小、分组
  private var info: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
      if let source = item.sourceName {
        GridRow {
          label("来源")
          HStack(spacing: 4) {
            if let icon = AppIcons.icon(for: item.sourceBundleID) {
              Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(source).lineLimit(1)
          }
        }
      }
      GridRow {
        label("时间")
        Text(Self.timeText(item.copiedAt))
      }
      GridRow {
        label("内容")
        Text(kindDetail).lineLimit(1)
      }
      if let groupID = item.groupID,
        let group = model.store.groups.first(where: { $0.id == groupID })
      {
        GridRow {
          label("分组")
          Text(group.name).lineLimit(1)
        }
      }
    }
    .font(.system(size: 11))
  }

  private func label(_ text: String) -> some View {
    Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
  }

  private var kindDetail: String {
    switch item.kind {
    case .text:
      let base = "\(form?.title ?? "文本") · \((item.text ?? "").count) 字"
      return item.richType == nil ? base : base + " · 带格式"
    case .image:
      guard let image = item.image else { return "图片" }
      return
        "图片 · \(image.width)×\(image.height) · \(image.byteCount.formatted(.byteCount(style: .file)))"
    case .file:
      return "\(item.filePaths?.count ?? 0) 个文件"
    }
  }

  /// 操作按钮两列排开；超过 4 个的放进最后一格的「更多」菜单
  private var actionGrid: some View {
    let actions = self.actions
    let visible = actions.count > 4 ? Array(actions.prefix(3)) : actions
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
      ForEach(visible, id: \.title) { action in
        Button(action: action.run) {
          Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity)
        }
      }
      if actions.count > 4 {
        Menu {
          ForEach(actions.dropFirst(3), id: \.title) { action in
            Button(action.title, systemImage: action.symbol, action: action.run)
          }
        } label: {
          Label("更多", systemImage: "ellipsis.circle").frame(maxWidth: .infinity)
        }
        .menuIndicator(.hidden)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .lineLimit(1)
  }

  private struct Action {
    let title: String
    let symbol: String
    let run: () -> Void
  }

  private var actions: [Action] {
    var actions = [Action(title: "粘贴", symbol: "arrow.turn.down.left") { model.paste([item]) }]
    if item.kind == .text || !(item.ocrText ?? "").isEmpty {
      actions.append(Action(title: "翻译", symbol: "character.bubble") { model.translate(item) })
    }
    if form == .json {
      actions.append(
        Action(title: model.prettyJSON ? "原文" : "美化", symbol: "curlybraces") {
          model.prettyJSON.toggle()
        })
    }
    if let link = ContentForm.firstLink(in: item.text ?? "") {
      actions.append(Action(title: "打开链接", symbol: "safari") { NSWorkspace.shared.open(link) })
    }
    if item.richType != nil {
      actions.append(
        Action(title: "复制纯文本", symbol: "doc.plaintext") { model.copySelection(plainText: true) })
    }
    if item.kind == .file {
      actions.append(
        Action(title: "访达中显示", symbol: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting(
            (item.filePaths ?? []).map { URL(filePath: $0) })
        })
    }
    if item.kind == .text {
      actions.append(Action(title: "编辑", symbol: "pencil") { model.dialog = .edit(item.id) })
    }
    return actions
  }

  /// 今年内 MM/dd HH:mm，跨年 yyyy/MM/dd HH:mm
  static func timeText(_ date: Date) -> String {
    let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
    return date.formatted(
      Date.VerbatimFormatStyle(
        format: sameYear
          ? "\(month: .twoDigits)/\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
          : "\(year: .defaultDigits)/\(month: .twoDigits)/\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current, calendar: .current))
  }
}

/// 只读长文本（NSTextView，TextKit 2）：可选中、可滚动，高亮搜索词
private struct ReadOnlyTextView: NSViewRepresentable {
  let text: String
  let monospaced: Bool
  let highlights: [String]

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    let textView = scroll.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 8, height: 10)
    scroll.drawsBackground = false
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView else { return }
    let font: NSFont =
      monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
    let attributed = NSMutableAttributedString(
      string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
    let nsText = text as NSString
    for token in highlights where !token.isEmpty {
      var range = NSRange(location: 0, length: nsText.length)
      while true {
        let found = nsText.range(of: token, options: Search.options, range: range)
        guard found.location != NSNotFound else { break }
        attributed.addAttribute(
          .backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.6), range: found)
        range = NSRange(location: NSMaxRange(found), length: nsText.length - NSMaxRange(found))
      }
    }
    textView.textStorage?.setAttributedString(attributed)
    textView.scrollToBeginningOfDocument(nil)
  }
}

/// 文件列表（最多 120 个）；只有一个图片文件时直接预览图片
private struct FileListView: View {
  let paths: [String]

  var body: some View {
    if paths.count == 1, let image = NSImage(contentsOfFile: paths[0]) {
      Image(nsImage: image).resizable().scaledToFit().padding(12)
    } else {
      List(paths.prefix(120), id: \.self) { path in
        HStack(spacing: 8) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(
            width: 18, height: 18)
          VStack(alignment: .leading, spacing: 0) {
            Text(URL(filePath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text(Self.detail(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
    }
  }

  /// 显示时再查大小：文件可能已被改动或删除
  private static func detail(_ path: String) -> String {
    // 先解析符号链接（macOS 15 的 /Applications/Safari.app 就是链接），否则量到的是链接本身
    let resolved = URL(filePath: path).resolvingSymlinksInPath().path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved) else {
      return "文件已不存在 · \(path)"
    }
    if NSWorkspace.shared.isFilePackage(atPath: resolved) { return "应用 / 文件包 · \(path)" }
    if attributes[.type] as? FileAttributeType == .typeDirectory { return "文件夹 · \(path)" }
    let size = (attributes[.size] as? Int ?? 0).formatted(.byteCount(style: .file))
    return "\(size) · \(path)"
  }
}
