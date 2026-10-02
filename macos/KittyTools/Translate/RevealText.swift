// 流式译文「显影」（Whisker 招牌时刻 S3，mac-whisker §5）：每段新到的文字从模糊、透明、下沉 2.5 pt 过渡到清晰
// （0.26 s），末尾一根强调色胶囊光标（2 pt × 0.82 行高，0.55 s 一程往返闪）。用 macOS 15 的 TextRenderer 按段画：
// 新段带 RevealBirth 属性，显影完就并进前面的定型文字（Text 拼接不会越来越长）。
// 省电（第二轮体检第 1b 批）：时间线只在有段落正在显影时逐帧跑（来字后约 0.36 s），没有新字就停——生成中卡住、
// 出完之后都不逐帧重画文字。光标不在文字里画，是叠在最后一个字后面的单独一层（位置取自 Text.LayoutKey），
// 闪的是这一层透明度上的隐式循环动画（mac-whisker §8）。减弱动态效果时文字直接显示、光标常亮不闪。
// 注意（macOS 15.7 实测）：外面套了 .textSelection(.enabled) 时，系统换一条路画可选中的文字，不调 TextRenderer
// （draw 一次都不进）——显影不显示，字是直接出现的。结果卡片从 a040fe48（2026-09-25）起就是这么用的；
// 光标是单独一层，不受影响。恢复显影（生成中先不让选中）还是把它拿掉省电，等用户定：PLAN §10「第二轮体检」第 1b 批。

import SwiftUI

struct RevealText: View {
  let text: String
  /// 还在生成：显示光标
  let isStreaming: Bool
  var fontSize: CGFloat = 15
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var chunks = Chunks()

  /// 一段显影多久
  nonisolated static let duration: TimeInterval = 0.26

  /// 显影的记账（纯状态，时刻由调用方给）：已定型的前缀长度（字符数）和之后每段新字的出生时间
  struct Chunks: Equatable {
    struct Chunk: Equatable {
      var end: Int
      var birth: Date
    }

    private(set) var settled = 0
    private(set) var revealing: [Chunk] = []
    private var shownCount = 0

    /// 还有段落在显影：时间线只在这时跑（减弱动态效果时从不记段落，所以从不跑）
    var isRevealing: Bool { !revealing.isEmpty }

    /// 文字变了：变长就给多出来的那段记下出生时间；不是接着长（重新翻译、改了开头、变短）或不做动画时整体定型。
    /// 顺手把已经显影完的段并进定型前缀（多留 0.05 s 余量）：连着来字时合并就发生在这里，不另外触发一次重排
    mutating func absorb(count: Int, replacing: Bool, animated: Bool, now: Date) {
      if replacing || count < shownCount || !animated {
        settled = count
        revealing = []
      } else if count > shownCount {
        revealing.append(Chunk(end: count, birth: now))
      }
      shownCount = count
      settle(now: now, slack: 0.05)
    }

    /// 显影完的段并进定型前缀；全并完时间线就停
    mutating func settle(now: Date, slack: TimeInterval = 0) {
      revealing.removeAll { chunk in
        guard now.timeIntervalSince(chunk.birth) > RevealText.duration + slack else { return false }
        settled = max(settled, chunk.end)
        return true
      }
    }
  }

  /// 光标的位置：贴着最后一段字（run 的排版框）右边 1.5 pt，宽 2、高 0.82 行高、上面留 0.1 行高
  static func cursorRect(after run: CGRect) -> CGRect {
    CGRect(x: run.maxX + 1.5, y: run.minY + run.height * 0.1, width: 2, height: run.height * 0.82)
  }

  var body: some View {
    // 拼文字只和状态有关（来字、定型时才变），放在时间线闭包外面：闭包里每帧只换渲染器手里的时刻
    let composed = compose().font(.system(size: fontSize)).lineSpacing(3.5)
    TimelineView(.animation(paused: !chunks.isRevealing)) { context in
      composed.textRenderer(RevealRenderer(now: context.date))
    }
    .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
      if isStreaming {
        GeometryReader { geometry in
          if let anchored = layouts.last, let run = anchored.layout.last?.last {
            let origin = geometry[anchored.origin]
            RevealCursor(
              rect: Self.cursorRect(after: run.typographicBounds.rect)
                .offsetBy(dx: origin.x, dy: origin.y))
          }
        }
        .allowsHitTesting(false)
      }
    }
    .onChange(of: text, initial: true) { old, new in
      chunks.absorb(
        count: new.count, replacing: old != new && !new.hasPrefix(old), animated: !reduceMotion,
        now: .now)
    }
    // 最后一段显影完（0.26 s，再留 0.1 s 余量）并进定型文字，时间线跟着停。中途又来字：这个任务被取消，
    // 从新的那段重新计时（更早的段在 absorb 里已经并掉），所以连着出字时不会为了合并多重排一次
    .task(id: chunks.revealing.last?.birth) {
      guard chunks.isRevealing else { return }
      try? await Task.sleep(for: .seconds(Self.duration + 0.1))
      guard !Task.isCancelled else { return }
      chunks.settle(now: .now)
    }
  }

  private func compose() -> Text {
    let characters = Array(text)
    let prefixEnd = min(chunks.settled, characters.count)
    var result = Text(String(characters[0..<prefixEnd]))
    var start = prefixEnd
    for chunk in chunks.revealing where chunk.end > start {
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

/// 生成中文字末尾的光标：单独一层，不用重画文字就能闪——透明度 1 ↔ 0.35、0.55 s 一程的隐式循环动画
/// （曲线是正弦缓入缓出，和原来按余弦算的闪法对得上）；减弱动态效果时常亮。
/// rect 是它在 RevealText 里的位置，来字时直接换（动画只挂在透明度上，位置不带动画）
private struct RevealCursor: View {
  let rect: CGRect
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dims = false

  var body: some View {
    Path(roundedRect: rect, cornerRadius: 1)
      .fill(Style.brand)
      .opacity(dims ? 0.35 : 1)
      .animation(
        .timingCurve(0.37, 0, 0.63, 1, duration: 0.55).repeatForever(autoreverses: true),
        value: dims
      )
      .onAppear { dims = !reduceMotion }
  }
}

/// 新段的出生时间（TextRenderer 按它算显影进度）
nonisolated struct RevealBirth: TextAttribute {
  let date: Date
}

/// nonisolated：SwiftUI 异步渲染时会在显示链接线程上调 draw，不能绑定主线程（同 Style.dynamic）
nonisolated struct RevealRenderer: TextRenderer {
  var now: Date

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
  }
}
