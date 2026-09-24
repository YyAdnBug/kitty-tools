// 剪贴板面板根视图。M2 过渡版：搜索框 + 真实历史列表（点击或 Enter 粘贴回原 App）+ 图钉 + 打开翻译浮窗。
// M3 换成完整界面（筛选、分组、预览、多选、右键菜单等）。

import SwiftUI

struct ClipboardPanelView: View {
  var onPaste: (ClipItem) -> Void
  var onOpenTranslate: () -> Void

  @Environment(ClipboardStore.self) private var store
  @AppStorage(Prefs.clipboardHideOnUnfocus) private var hideOnUnfocus = true
  @State private var query = ""
  @State private var selection = 0
  @State private var trusted = Permissions.isAccessibilityTrusted

  private var results: [ClipItem] { store.search(query) }

  var body: some View {
    let results = results
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        CommandTextField(text: $query, placeholder: "搜索剪贴板历史") { handleCommand($0, results) }
        Text("\(results.count) 条").font(.caption).foregroundStyle(.secondary)
        Button("翻译浮窗", systemImage: "character.bubble", action: onOpenTranslate)
          .labelStyle(.iconOnly)
          .help("打开翻译浮窗")
        Toggle(isOn: pinned) { Image(systemName: hideOnUnfocus ? "pin" : "pin.fill") }
          .toggleStyle(.button)
          .help("固定：点外面不关闭")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 10)
      Divider()
      if !trusted {
        HStack {
          Text("粘贴需要辅助功能授权，未授权时内容只写进剪贴板").font(.callout)
          Spacer()
          Button("去授权") {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
          }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
      }
      if results.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "还没有剪贴板历史" : "没有匹配的条目", systemImage: "doc.on.clipboard")
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                row(item, selected: index == selection)
                  .id(index)
                  .onTapGesture { onPaste(item) }
              }
            }
            .padding(8)
          }
          .onChange(of: selection) { proxy.scrollTo(selection) }
        }
      }
    }
    .onChange(of: query) { selection = 0 }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
    }
  }

  private func row(_ item: ClipItem, selected: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon(item.kind)).foregroundStyle(.secondary).frame(width: 16)
      Text(summary(item))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if item.richType != nil { Image(systemName: "textformat").foregroundStyle(.tertiary) }
      if item.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 6))
    .contentShape(.rect)
  }

  private func icon(_ kind: ClipItem.Kind) -> String {
    switch kind {
    case .text: "doc.plaintext"
    case .image: "photo"
    case .file: "folder"
    }
  }

  private func summary(_ item: ClipItem) -> String {
    switch item.kind {
    case .text:
      return (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ⏎ ")
    case .image:
      guard let image = item.image else { return "图片" }
      return "图片 \(image.width)×\(image.height)"
    case .file:
      let names = (item.filePaths ?? []).map { URL(filePath: $0).lastPathComponent }
      return names.count == 1 ? names[0] : "\(names.count) 个文件：\(names.joined(separator: "、"))"
    }
  }

  private var pinned: Binding<Bool> {
    Binding(get: { !hideOnUnfocus }, set: { hideOnUnfocus = !$0 })
  }

  private func handleCommand(_ selector: Selector, _ results: [ClipItem]) -> Bool {
    guard !results.isEmpty else { return false }
    switch selector {
    case #selector(NSResponder.moveUp(_:)):
      selection = (selection + results.count - 1) % results.count
    case #selector(NSResponder.moveDown(_:)):
      selection = (selection + 1) % results.count
    case #selector(NSResponder.insertNewline(_:)):
      onPaste(results[min(selection, results.count - 1)])
    default:
      return false
    }
    return true
  }
}
