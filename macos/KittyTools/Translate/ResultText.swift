// 结果卡片的正文（生成中有字、或完成后不按 Markdown 渲染的译文，mac-whisker §5 S3）：普通的 Text（系统字体 15 × 字号、
// 行距 3.5），新字直接出现；生成中末尾一根强调色胶囊光标（2 pt × 0.82 行高，0.55 s 一程往返闪）。光标是叠在文字上的
// 单独一层（位置取自 Text.LayoutKey）：铺满正文的 LoopLayer（ProviderCardView.swift）里一层子图层，来字时只挪这层的位置，
// 闪是它上面的 CABasicAnimation、整个交给渲染服务（美化与提速 P5：原来是 SwiftUI 的隐式循环动画，光标一项约 3.6%）；
// 减弱动态效果时常亮。
// ponytail: 生成中每来一批字 SwiftUI 都把整段正文重排、重画一遍（尺寸、Text.LayoutKey、可选中文字的排版各一遍，跟着字数涨；
// 三张卡一起出字时主线程 42–46%，P5 量过，不在动效上）；要再省得生成中换成只往后追加的 TextKit 文字视图、完成再换回 Text，单独立项。
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

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text(text)
      .font(.system(size: fontSize))
      .lineSpacing(3.5)
      .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
        if isStreaming {
          GeometryReader { geometry in
            // 铺满正文的一层，来字时视图不挪，只改里面那根光标子图层的位置
            LoopLayer(
              kind: .blink, color: Style.brand, animates: !reduceMotion,
              mark: layouts.last.flatMap { anchored in
                anchored.layout.last?.last.map { run in
                  let origin = geometry[anchored.origin]
                  return Self.cursorRect(after: run.typographicBounds.rect)
                    .offsetBy(dx: origin.x, dy: origin.y)
                }
              })
          }
          .allowsHitTesting(false)
        }
      }
  }
}
