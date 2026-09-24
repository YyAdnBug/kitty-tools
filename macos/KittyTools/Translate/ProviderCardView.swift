// 一个翻译服务的结果卡片：标题行（图标、名称、进行中指示、朗读 / 复制 / 重试 / 折叠），正文四种状态
// （等待、流式输出中、完成、失败）。大模型输出按行内 Markdown 渲染（加粗、链接等），译文可选中。

import SwiftUI

struct ProviderCardView: View {
  let card: TranslateCoordinator.Card
  let language: Lang?
  let speaker: Speaker
  let onRetry: () -> Void
  @State private var collapsed = false
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: card.service.symbol).foregroundStyle(.tint)
        Text(card.service.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .lineLimit(1)
        if case .running = card.state { ProgressView().controlSize(.mini) }
        if case .waiting = card.state { ProgressView().controlSize(.mini) }
        Spacer()
        if let text = card.state.text, !text.isEmpty {
          Button(
            "朗读", systemImage: speaker.speaking == text ? "stop.fill" : "speaker.wave.2"
          ) { speaker.toggle(text, language: language) }
          Button("复制", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(text) }
        }
        Button("重新翻译", systemImage: "arrow.clockwise", action: onRetry)
        Button(collapsed ? "展开" : "收起", systemImage: collapsed ? "chevron.down" : "chevron.up") {
          collapsed.toggle()
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .controlSize(.small)
      if !collapsed { content }
    }
    .padding(10)
    .background(.background.opacity(0.55), in: .rect(cornerRadius: 10))
    .onChange(of: card.state) { if card.state.text != nil { collapsed = false } }
  }

  @ViewBuilder private var content: some View {
    switch card.state {
    case .waiting:
      Text("翻译中…").foregroundStyle(.secondary)
    case .running(let text), .done(let text):
      Text(Self.markdown(text))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .failed(let message):
      HStack(alignment: .firstTextBaseline) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.callout)
        Spacer()
        Button("重试", action: onRetry).controlSize(.small)
      }
    }
  }

  private func copy(_ text: String) {
    Paster.write(string: text)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }

  /// 行内 Markdown（块级标记原样显示）；解析失败按纯文本
  private static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
