// 结果卡片的正文（生成中有字、或完成后不按 Markdown 渲染的译文，mac-whisker §5 S3）：普通的 Text（系统字体 15 × 字号、
// 行距 3.5），新字直接出现；生成中末尾一根强调色胶囊光标（2 pt × 0.82 行高，0.55 s 一程往返闪）。光标是叠在最后一个字
// 后面的单独一层（位置取自 Text.LayoutKey），闪的是这一层透明度上的隐式循环动画（mac-whisker §8），不用重画文字；
// 减弱动态效果时常亮。
// 这里原来是「显影」（RevealText：TextRenderer + TimelineView，新字淡入、去模糊、上浮 0.26 s）。结果卡片的正文要能选中，
// 而可选中的文字系统不调 TextRenderer（macOS 15.7 实测，draw 一次都不进）：显影在真 App 里从没显示出来，挂着它却让
// 出字时的 CPU 高出一倍多。第二轮体检第 1c 批按用户的决定拿掉；要恢复得单独立项、先出原型给用户看
// （生成中不让选中它才显示得出来）。

import SwiftUI

struct ResultText: View {
  let text: String
  /// 还在生成：显示光标
  let isStreaming: Bool
  var fontSize: CGFloat = 15

  /// 光标的位置：贴着最后一段字（run 的排版框）右边 1.5 pt，宽 2、高 0.82 行高、上面留 0.1 行高
  static func cursorRect(after run: CGRect) -> CGRect {
    CGRect(x: run.maxX + 1.5, y: run.minY + run.height * 0.1, width: 2, height: run.height * 0.82)
  }

  var body: some View {
    Text(text)
      .font(.system(size: fontSize))
      .lineSpacing(3.5)
      .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
        if isStreaming {
          GeometryReader { geometry in
            if let anchored = layouts.last, let run = anchored.layout.last?.last {
              let origin = geometry[anchored.origin]
              StreamCursor(
                rect: Self.cursorRect(after: run.typographicBounds.rect)
                  .offsetBy(dx: origin.x, dy: origin.y))
            }
          }
          .allowsHitTesting(false)
        }
      }
  }
}

/// 生成中文字末尾的光标：单独一层，不用重画文字就能闪——透明度 1 ↔ 0.35、0.55 s 一程的隐式循环动画
/// （正弦缓入缓出）；减弱动态效果时常亮。rect 是它在 ResultText 里的位置，来字时直接换
/// （动画只挂在透明度上，位置不带动画）
private struct StreamCursor: View {
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
