// 一行每秒在变的读数的图层画法，两处共用：状态屏告示上那行小字「14:02 开始 · 已 1 分 05 秒」（做着动画的会话里；2026-10-11
// 用户要求：精确到秒、数字过渡要有动画）和录制 HUD 的计时「0:12」（同一天从 numericText 换过来）。
// 每个字一小块图层（共用一条基线），每秒只换变了的那几位数字：旧的滑出去淡掉、新的从另一边滑进来——Core Animation 的
// 图层动画，渲染服务做，本进程不逐帧算。
// 整行交给 CoreText 排一次，画的时候按字切开：每块是整行里这个字占的那一段（按像素对齐、互不重叠，拼起来和整行一次画出来
// 一样）。一个字一个字单独排的话，夹在数字中间的冒号拿不到抬高的那个字形（「0:12」的冒号会比普通的 Text 低 1.4 pt）。
// **不用 SwiftUI 的 `.contentTransition(.numericText)`**：它每换一次要逐帧重画带模糊的字，独立小程序实测（屏幕角落一小块
// 窗口、每秒换一次，只算本进程）19 pt 的一行占 9–15% CPU，13 pt 的计时 8–11%——状态屏一挂就是几小时，录制 HUD 录多久
// 挂多久。同样条件下：只换字不做动画 0.2–0.4%，逐字 `.transition(.push)` 1.6–2.4%，这里的写法 0.2–0.5%
// （PLAN §10「状态屏」第三轮、「录制 HUD 的计时」）。
// 不滚的时候 direction 给 0（直接换）：录制 HUD 在减弱动态效果时；状态屏不做动画的地方（动画关着、减弱动态效果、设置里的
// 预览、选状态的卡片、截图自检的大多数图）干脆是普通的 SwiftUI Text，不走这里（StatusScreenView.swift 的 StatusFooter）。
// ponytail: 字从左往右排、放不下不截断（状态屏那行最多三十来个字，屏宽放得下）；要截断就在 layout 里按给的宽度丢字。
// 没变的字不重画：数字变了会连带改旁边字形的写法（连字、分数）这两处都没有，有了就改成整行重排。

import AppKit
import SwiftUI

struct Ticker: NSViewRepresentable {
  let text: String
  let font: NSFont
  let color: NSColor
  /// 变了的数字往哪边滚：1 = 数在变大（新的从下面上来），-1 = 在变小（倒数，新的从上面下来）
  let direction: Int

  func makeNSView(context: Context) -> TickerView { TickerView() }

  func updateNSView(_ view: TickerView, context: Context) {
    view.show(text, font: font, color: color, direction: direction)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TickerView, context: Context)
    -> CGSize?
  {
    TickerView.measure(text, font: font).size
  }
}

final class TickerView: NSView {
  /// 现在显示的字和各自的图层（一一对应）
  private(set) var characters: [Character] = []
  private(set) var cells: [CALayer] = []
  /// edges：各字的左边在哪，末尾多一个行尾（滚之前拿它比：位置都没动才只换那几位）
  private var shown: (text: String, font: NSFont, color: NSColor, scale: CGFloat, edges: [CGFloat])?

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

  /// 一行字怎么排（纯函数）：每个字的排版宽度、整行的大小（宽 = 各字宽度之和，高 = 字体的行高，都往上取整点）、
  /// 基线离行底多高
  static func measure(_ text: String, font: NSFont) -> (
    widths: [CGFloat], size: CGSize, baseline: CGFloat
  ) {
    let (_, edges, size, baseline) = layout(text, font: font)
    return (zip(edges.dropFirst(), edges).map(-), size, baseline)
  }

  /// 整行排一次：排好的行（留着画）、各字的左边在哪（末尾多一个行尾）、整行的大小、基线离行底多高。
  /// 基线离顶 = 字体的上行高度四舍五入到整点——SwiftUI 的 Text 就是这么摆的（系统字体 10–30 pt 逐个量过都对得上），
  /// 这样换成图层的那一行和原来的 Text 落在同一行像素上；直接用下行高度的话 13 pt、16 pt 的字都低 1 个像素
  private static func layout(_ text: String, font: NSFont, color: NSColor = .white) -> (
    line: CTLine, edges: [CGFloat], size: CGSize, baseline: CGFloat
  ) {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]))
    var (edges, index) = ([CGFloat](), 0)
    for character in text {
      edges.append(CTLineGetOffsetForStringIndex(line, index, nil))
      index += character.utf16.count
    }
    edges.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    let height = (font.ascender - font.descender + font.leading).rounded(.up)
    return (
      line, edges, CGSize(width: (edges.last ?? 0).rounded(.up), height: height),
      height - font.ascender.rounded()
    )
  }

  /// 显示这一行。各字的位置没变、变的都是数字换数字，而且给了方向：只换那几位，滚过去；否则整行重排，不做动画
  func show(_ text: String, font: NSFont, color: NSColor, direction: Int) {
    guard let layer else { return }
    let scale = scale
    let (line, edges, size, baseline) = Self.layout(text, font: font, color: color)
    // 字体、颜色、倍率变了，或者有字挪了地方（字数变了、数字不等宽）：整行重排
    let moved =
      shown.map {
        $0.font != font || $0.color != color || $0.scale != scale || $0.edges != edges
      } ?? true
    let next = Array(text)
    shown = (text, font, color, scale, edges)
    // 中文走的是替换字体，上下可能比系统字体的行框高出一点：位图上下各多留一截，图层不裁
    let pad = (font.pointSize * 0.25).rounded(.up)
    func makeCell(_ index: Int) -> CALayer {
      let cell = CALayer()
      // 整行里这个字占的那一段，两头按像素取整（块和块正好接上）；最后一块往右多 1 pt：有的字形会探出一点
      // （中间的字探出去的那点落在后一块里）
      let left = (edges[index] * scale).rounded()
      let right = (edges[index + 1] * scale).rounded() + (index == next.count - 1 ? scale : 0)
      cell.frame = CGRect(
        x: left / scale, y: -pad, width: (right - left) / scale, height: size.height + pad * 2)
      cell.contentsScale = scale
      if !next[index].isWhitespace {
        cell.contents = Self.image(
          line, from: left / scale, width: Int(right - left),
          height: Int((cell.frame.height * scale).rounded(.up)), baseline: baseline + pad,
          scale: scale)
      }
      return cell
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let changed = next.indices.filter {
      !characters.indices.contains($0) || characters[$0] != next[$0]
    }
    let rolls =
      !moved && direction != 0
      && changed.allSatisfy { next[$0].isNumber && characters[$0].isNumber }
    guard rolls else {
      for cell in layer.sublayers ?? [] { cell.removeFromSuperlayer() }
      cells = next.indices.map { index in
        let cell = makeCell(index)
        layer.addSublayer(cell)
        return cell
      }
      characters = next
      return
    }
    let distance = size.height * Self.travel * CGFloat(direction)
    for index in changed {
      let (old, new) = (cells[index], makeCell(index))
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

  /// 整行里从 left（点）起、width × height（像素）的一块画成位图：基线离位图底边 baseline（点），各块共用，排在一起才齐
  private static func image(
    _ line: CTLine, from left: CGFloat, width: Int, height: Int, baseline: CGFloat, scale: CGFloat
  ) -> CGImage? {
    guard width > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: -left, y: baseline)
    CTLineDraw(line, context)
    return context.makeImage()
  }
}
