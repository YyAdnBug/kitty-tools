// 状态屏告示上那行小字「14:02 开始 · 已 1 分 05 秒」在做动画的会话里的画法（2026-10-11 用户要求：精确到秒、数字过渡要有动画）。
// 每个字一小块图层（CoreText 画好的位图，共用一条基线），每秒只换变了的那几位数字：旧的滑出去淡掉、新的从另一边
// 滑进来——Core Animation 的图层动画，渲染服务做，本进程不逐帧算。
// **不用 SwiftUI 的 `.contentTransition(.numericText)`**：它每换一次要逐帧重画带模糊的字，独立小程序实测（19 pt 的这一行，
// 每秒换一次，只算本进程）占 9–15% CPU，13 pt 也有 7%；这块屏一挂就是几小时。同样条件下：只换字不做动画 0.2–0.3%，
// 逐字 `.transition(.push)` 1.6–2.4%，这里的写法 0.5%（PLAN §10「状态屏」第三轮）。
// 不做动画的地方（动画关着、减弱动态效果、设置里的预览、选状态的卡片、截图自检的大多数图）还是普通的 SwiftUI Text，
// 不走这里（StatusScreenView.swift 的 StatusFooter）。
// ponytail: 字一个个单独排，没有字距调整、放不下不截断（这行最多三十来个字，屏宽放得下）；要截断就在 measure 里按给的宽度丢字。

import AppKit
import SwiftUI

struct StatusTicker: NSViewRepresentable {
  let text: String
  let font: NSFont
  let color: NSColor
  /// 变了的数字往哪边滚：1 = 数在变大（新的从下面上来），-1 = 在变小（倒数，新的从上面下来）
  let direction: Int

  func makeNSView(context: Context) -> StatusTickerView { StatusTickerView() }

  func updateNSView(_ view: StatusTickerView, context: Context) {
    view.show(text, font: font, color: color, direction: direction)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: StatusTickerView, context: Context)
    -> CGSize?
  {
    StatusTickerView.measure(text, font: font).size
  }
}

final class StatusTickerView: NSView {
  /// 现在显示的字和各自的图层（一一对应）
  private(set) var characters: [Character] = []
  private(set) var cells: [CALayer] = []
  private var shown: (text: String, font: NSFont, color: NSColor, scale: CGFloat)?

  /// 滑多远：行高的这么多倍
  static let travel: CGFloat = 0.6
  static let slideKey = "slide"

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  /// 换了屏幕（倍率变了）：位图按新的倍率重画
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let shown, shown.scale != scale else { return }
    show(shown.text, font: shown.font, color: shown.color, direction: 0)
  }

  private var scale: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  /// 一行字怎么排（纯函数）：每个字的排版宽度、整行的大小（宽 = 各字宽度之和，高 = 字体的行高）、基线离行底多高
  static func measure(_ text: String, font: NSFont) -> (
    widths: [CGFloat], size: CGSize, baseline: CGFloat
  ) {
    let widths = text.map {
      CGFloat(CTLineGetTypographicBounds(line($0, font: font), nil, nil, nil))
    }
    return (
      widths,
      CGSize(
        width: widths.reduce(0, +).rounded(.up),
        height: (font.ascender - font.descender + font.leading).rounded(.up)),
      -font.descender
    )
  }

  private static func line(_ character: Character, font: NSFont, color: NSColor = .white) -> CTLine
  {
    CTLineCreateWithAttributedString(
      NSAttributedString(
        string: String(character),
        attributes: [
          .font: font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]))
  }

  /// 显示这一行。字数没变、变的都是数字换数字，而且给了方向：只换那几位，滚过去；否则整行重排，不做动画
  func show(_ text: String, font: NSFont, color: NSColor, direction: Int) {
    guard let layer else { return }
    let scale = scale
    let restyled =
      shown.map { $0.font != font || $0.color != color || $0.scale != scale } ?? true
    let next = Array(text)
    shown = (text, font, color, scale)
    let (widths, size, baseline) = Self.measure(text, font: font)
    // 中文走的是替换字体，上下可能比系统字体的行框高出一点：位图上下各多留一截，图层不裁
    let pad = (font.pointSize * 0.25).rounded(.up)
    func makeCell(_ index: Int, x: CGFloat) -> CALayer {
      let cell = CALayer()
      // 位图比排版宽度宽 1 pt：有的字形会探出一点
      let frame = CGRect(
        x: (x * scale).rounded() / scale, y: -pad, width: widths[index].rounded(.up) + 1,
        height: size.height + pad * 2)
      cell.frame = frame
      cell.contentsScale = scale
      cell.contents = Self.image(
        next[index], font: font, color: color, size: frame.size, baseline: baseline + pad,
        scale: scale)
      return cell
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let changed = next.indices.filter {
      !characters.indices.contains($0) || characters[$0] != next[$0]
    }
    let rolls =
      !restyled && direction != 0 && next.count == characters.count
      && changed.allSatisfy { next[$0].isNumber && characters[$0].isNumber }
    guard rolls else {
      for cell in layer.sublayers ?? [] { cell.removeFromSuperlayer() }
      var x: CGFloat = 0
      cells = next.indices.map { index in
        defer { x += widths[index] }
        let cell = makeCell(index, x: x)
        layer.addSublayer(cell)
        return cell
      }
      characters = next
      return
    }
    let distance = size.height * Self.travel * CGFloat(direction)
    for index in changed {
      let (old, new) = (cells[index], makeCell(index, x: cells[index].frame.minX))
      layer.addSublayer(new)
      cells[index] = new
      // 新的从另一边滑进来、淡入（图层坐标 y 向上：从下面上来 = 从负的位移回到 0）
      Self.animate(new, from: -distance, to: 0, opacity: (0, 1))
      // 旧的滑出去、淡掉，放完拿走
      old.opacity = 0
      CATransaction.begin()
      CATransaction.setCompletionBlock { [weak old] in
        MainActor.assumeIsolated { old?.removeFromSuperlayer() }
      }
      Self.animate(old, from: 0, to: distance, opacity: (1, 0))
      CATransaction.commit()
    }
    characters = next
  }

  /// 滑动用 snap 那条弹簧（键盘、计时这类一下一下的变化），透明度 0.12 s
  private static func animate(
    _ layer: CALayer, from: CGFloat, to: CGFloat, opacity: (from: Float, to: Float)
  ) {
    if let slide = Style.Motion.snap.caAnimation(
      keyPath: "transform.translation.y", reduced: false) as? CABasicAnimation
    {
      slide.fromValue = from
      slide.toValue = to
      layer.add(slide, forKey: slideKey)
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = opacity.from
    fade.toValue = opacity.to
    fade.duration = Style.fadeIn
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(fade, forKey: "fade")
  }

  /// 一个字画成位图：基线离位图底边 baseline（点），各字共用，排在一起才齐
  private static func image(
    _ character: Character, font: NSFont, color: NSColor, size: CGSize, baseline: CGFloat,
    scale: CGFloat
  ) -> CGImage? {
    guard !character.isWhitespace,
      let context = CGContext(
        data: nil, width: Int((size.width * scale).rounded(.up)),
        height: Int((size.height * scale).rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 0, y: baseline)
    CTLineDraw(line(character, font: font, color: color), context)
    return context.makeImage()
  }
}
