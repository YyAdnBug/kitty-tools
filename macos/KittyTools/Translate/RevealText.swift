// 流式译文「显影」（Whisker 招牌时刻 S3，mac-whisker §5）：每段新到的文字从模糊、透明、下沉 2.5 pt 过渡到清晰
// （0.26 s），末尾一根强调色胶囊光标（2 pt × 0.82 行高，0.55 s 往返闪）。用 macOS 15 的 TextRenderer 按段画：
// 新段带 RevealBirth 属性，显影完就并进前面的定型文字（Text 拼接不会越来越长）。只在生成中和刚到字的 0.3 s 内
// 逐帧刷新；减弱动态效果时直接显示、光标不闪。

import SwiftUI

struct RevealText: View {
  let text: String
  /// 还在生成：显示光标、时间线一直跑
  let isStreaming: Bool
  var fontSize: CGFloat = 15
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 已定型的前缀长度（字符数）与之后每段的出生时间
  @State private var settled = 0
  @State private var chunks: [Chunk] = []
  @State private var shownCount = 0

  private struct Chunk: Equatable {
    var end: Int
    var birth: Date
  }

  /// 一段显影多久
  nonisolated static let duration: TimeInterval = 0.26

  var body: some View {
    TimelineView(.animation(paused: !isStreaming && chunks.isEmpty || reduceMotion)) { context in
      compose(now: context.date)
        .font(.system(size: fontSize))
        .lineSpacing(3.5)
        .textRenderer(
          RevealRenderer(
            now: context.date, showsCursor: isStreaming, blinks: !reduceMotion,
            cursorColor: Style.brand))
    }
    .onChange(of: text, initial: true) { old, new in
      absorb(new, replacing: old != new && !new.hasPrefix(old))
    }
  }

  /// 文字变长：多出来的一段记出生时间；不是接着长（重新翻译、改了开头）就整体定型
  private func absorb(_ new: String, replacing: Bool) {
    let count = new.count
    let now = Date.now
    if replacing || count < shownCount || reduceMotion {
      settled = count
      chunks = []
    } else if count > shownCount {
      chunks.append(Chunk(end: count, birth: now))
    }
    shownCount = count
    // 显影完的段并进定型前缀
    chunks.removeAll { chunk in
      guard now.timeIntervalSince(chunk.birth) > Self.duration + 0.05 else { return false }
      settled = max(settled, chunk.end)
      return true
    }
    if !chunks.isEmpty {
      Task {
        try? await Task.sleep(for: .seconds(Self.duration + 0.1))
        let cutoff = Date.now
        chunks.removeAll { chunk in
          guard cutoff.timeIntervalSince(chunk.birth) > Self.duration else { return false }
          settled = max(settled, chunk.end)
          return true
        }
      }
    }
  }

  private func compose(now: Date) -> Text {
    let characters = Array(text)
    let prefixEnd = min(settled, characters.count)
    var result = Text(String(characters[0..<prefixEnd]))
    var start = prefixEnd
    for chunk in chunks where chunk.end > start {
      let end = min(chunk.end, characters.count)
      guard end > start else { continue }
      result =
        result
        + Text(String(characters[start..<end])).customAttribute(RevealBirth(date: chunk.birth))
      start = end
    }
    if start < characters.count { result = result + Text(String(characters[start...])) }
    return result
  }
}

/// 新段的出生时间（TextRenderer 按它算显影进度）
nonisolated struct RevealBirth: TextAttribute {
  let date: Date
}

/// nonisolated：SwiftUI 异步渲染时会在显示链接线程上调 draw，不能绑定主线程（同 Style.dynamic）
nonisolated struct RevealRenderer: TextRenderer {
  var now: Date
  var showsCursor: Bool
  var blinks: Bool
  var cursorColor: Color

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    for line in layout {
      for run in line {
        guard let birth = run[RevealBirth.self] else {
          context.draw(run)
          continue
        }
        let progress = min(max(now.timeIntervalSince(birth.date) / RevealText.duration, 0), 1)
        let eased = 1 - pow(1 - progress, 3)
        var copy = context
        copy.opacity = eased
        if eased < 1 { copy.addFilter(.blur(radius: (1 - eased) * 3)) }
        copy.translateBy(x: 0, y: (1 - eased) * 2.5)
        copy.draw(run)
      }
    }
    guard showsCursor, let line = layout.last, let run = line.last else { return }
    let rect = run.typographicBounds.rect
    let phase = blinks ? 0.5 + 0.5 * cos(now.timeIntervalSinceReferenceDate * .pi / 0.55) : 1
    let cursor = CGRect(
      x: rect.maxX + 1.5, y: rect.minY + rect.height * 0.1, width: 2, height: rect.height * 0.82)
    context.fill(
      Path(roundedRect: cursor, cornerRadius: 1),
      with: .color(cursorColor.opacity(0.35 + 0.65 * phase)))
  }
}
