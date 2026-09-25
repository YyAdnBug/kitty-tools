// 一个翻译服务的结果卡片：标题行（图标、名称、⌘数字、进行中指示、朗读 / 复制 / 重试 / 折叠），正文四种状态
// （等待、流式输出中、完成、失败）。大模型输出按行内 Markdown 渲染（加粗、链接等），译文可选中。
// 折叠状态由浮窗按服务记住（跨重启），不再因为出结果自动展开；复制的对勾状态在会话里（⌘1–9 也亮）。

import SwiftUI

struct ProviderCardView: View {
  let card: TranslateCoordinator.Card
  /// 第几张（⌘1–9 复制）
  let index: Int
  let language: Lang?
  let speaker: Speaker
  var fontScale = 1.0
  var isCollapsed = false
  var isCopied = false
  let onRetry: () -> Void
  var onCopy: () -> Void = {}
  var onToggleCollapse: () -> Void = {}

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
          Button("复制", systemImage: isCopied ? "checkmark" : "doc.on.doc", action: onCopy)
            .help(index < 9 ? "复制（⌘\(index + 1)）" : "复制")
        }
        Button("重新翻译", systemImage: "arrow.clockwise", action: onRetry)
        Button(
          isCollapsed ? "展开" : "收起", systemImage: isCollapsed ? "chevron.down" : "chevron.up",
          action: onToggleCollapse
        )
        .help(isCollapsed ? "展开（会一直记住）" : "收起（会一直记住）")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .controlSize(.small)
      if !isCollapsed { content }
    }
    .padding(10)
    .background(.background.opacity(0.55), in: .rect(cornerRadius: 10))
  }

  @ViewBuilder private var content: some View {
    switch card.state {
    case .waiting:
      Text("翻译中…").foregroundStyle(.secondary)
    case .running(let text), .done(let text):
      // 只有大模型按行内 Markdown 渲染；传统接口原样显示，免得吞掉 * # 之类的字符
      Text(card.service.isStreaming ? Self.markdown(text) : AttributedString(text))
        .font(.system(size: 13 * fontScale))
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

  /// 行内 Markdown（块级标记原样显示）；解析失败按纯文本
  private static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
