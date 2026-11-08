// 截图翻译盖回截图上时，到字号下限也放不下的段（2026-11-08 拍板 B1–B4）：挂在选区外、工具栏另一侧的一张 HUD 卡片。
// 每段一行原文（次要色、一行、末尾省略）+ 译文全文（13 pt，能选中）；右上「拷贝译文」和 ✕；最高到屏幕高度的四成，
// 再多在卡片里滚动。只在截图页上，不进出图（拷贝、保存、钉图出的还是选区那张图，放不下的那段是原文）。
// 什么时候出、放哪（SelectionView.cardPlacement）、什么时候收（选区一变、✕、Esc）都归 SelectionView 管。
// HUD 皮肤同工具栏、HUD 菜单（HUDBar：15 是深色材质 + 描边 + 阴影，26 起是深色玻璃）

import AppKit

final class TranslationCard: HUDBar {
  /// 翻的是哪个选区：选区一变卡片就收（和「换回原文」同时）
  let selection: CGRect
  let leftovers: [ScreenshotOverlay.Leftover]
  var onCopy: () -> Void = {}
  var onClose: () -> Void = {}
  /// 卡片里的字拿着焦点时按下的键（方向键除外）：交还给截图页（Esc 收卡片、↩ 拷贝截图、工具键照常）
  var onKey: (NSEvent) -> Void = { _ in }
  /// 点进卡片的字之前：截图页先收下输入中的文字标注、尺寸（不然接着打的字会被当成截图的快捷键）
  var onFocus: () -> Void = {}
  private var texts: [CardText] = []

  /// 宽同选区、夹在这两个数之间
  static let minWidth: CGFloat = 240
  static let maxWidth: CGFloat = 420
  private static let padding: CGFloat = 12
  private static let headerHeight: CGFloat = 24
  private static let sourceFont = NSFont.systemFont(ofSize: 11)
  private static let textFont = NSFont.systemFont(ofSize: 13)

  /// 两段的旁白名、标题
  static func title(count: Int) -> String { count > 1 ? "放不下的 \(count) 段译文" : "放不下的译文" }

  init(
    _ leftovers: [ScreenshotOverlay.Leftover], selection: CGRect, width: CGFloat,
    maxHeight: CGFloat
  ) {
    self.selection = selection
    self.leftovers = leftovers
    super.init(radius: Style.Radius.card, height: 0)
    let pad = Self.padding
    let inner = width - 2 * pad
    // 正文：每段一行原文 + 译文，排在一个从上往下的文档视图里
    let document = FlippedView()
    var y: CGFloat = 0
    for (index, item) in leftovers.enumerated() {
      if index > 0 { y += 10 }
      let source = NSTextField(labelWithString: Self.oneLine(item.source))
      source.font = Self.sourceFont
      source.textColor = Style.HUD.secondaryText
      source.lineBreakMode = .byTruncatingTail
      source.maximumNumberOfLines = 1
      source.cell?.truncatesLastVisibleLine = true
      source.frame = CGRect(x: 0, y: y, width: inner, height: ceil(source.fittingSize.height))
      source.setAccessibilityLabel("原文：\(item.source)")
      document.addSubview(source)
      y = source.frame.maxY + 2
      let text = CardText.make(item.translation, width: inner, font: Self.textFont)
      text.onKey = { [weak self] in self?.onKey($0) }
      text.onFocus = { [weak self] in self?.onFocus() }
      text.frame.origin = CGPoint(x: 0, y: y)
      document.addSubview(text)
      texts.append(text)
      y = text.frame.maxY
    }
    document.frame = CGRect(x: 0, y: 0, width: inner, height: ceil(y))
    let bodyHeight = min(document.frame.height, max(40, maxHeight - Self.headerHeight - 3 * pad))
    let height = ceil(pad + Self.headerHeight + 6 + bodyHeight + pad)
    frame.size = CGSize(width: width, height: height)
    applyGeometry()

    // 按材质的大小排（26 的 effect 是玻璃的 contentView，要等 Auto Layout 跑过才有尺寸；材质就是卡片内缩 materialInset），
    // 四边离卡片边 pad：15 的材质已内缩 0.5（同 HUDMenu）
    let edge = pad - Self.materialInset
    let area = bounds.insetBy(dx: Self.materialInset, dy: Self.materialInset).size
    let top = area.height - edge
    let caption = NSTextField(labelWithString: Self.title(count: leftovers.count))
    caption.font = .systemFont(ofSize: 11, weight: .semibold)
    caption.textColor = Style.HUD.secondaryText
    caption.sizeToFit()
    caption.frame.origin = CGPoint(
      x: edge, y: top - Self.headerHeight / 2 - caption.frame.height / 2)
    effect.addSubview(caption)
    let button = CGSize(width: 24, height: 24)
    let close = barButton(
      NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(),
      tip: "关闭", action: #selector(closeTapped), size: button)
    let copy = barButton(
      NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(),
      tip: "拷贝译文", action: #selector(copyTapped), size: button)
    // 右上角从右往左：关闭、拷贝，间隔 2
    let buttonY = top - Self.headerHeight / 2 - button.height / 2
    for (index, control) in [close, copy].enumerated() {
      let x = area.width - edge - CGFloat(index + 1) * button.width - CGFloat(index) * 2
      control.translatesAutoresizingMaskIntoConstraints = true
      control.frame = CGRect(origin: CGPoint(x: x, y: buttonY), size: button)
      control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
      effect.addSubview(control)
    }
    let scroll = NSScrollView(
      frame: CGRect(x: edge, y: edge, width: inner, height: bodyHeight))
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = document.frame.height > bodyHeight
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = document
    effect.addSubview(scroll)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(Self.title(count: leftovers.count))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// 边距、标题上的点击不往下漏给遮罩（否则会当成点在选区外、重新框选）
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}

  /// 焦点在不在卡片的字上（截图页据此把 ⌘C ⌘A、方向键交给它，收卡片时把焦点要回去）
  func owns(_ responder: NSResponder?) -> Bool {
    texts.contains { $0 === responder }
  }

  /// 这一点（view 的坐标）在不在看得见的字上：截图页在这里给文字光标
  func hasText(at point: CGPoint, in view: NSView) -> Bool {
    texts.contains { $0.visibleRect.contains($0.convert(point, from: view)) }
  }

  @objc private func copyTapped() { onCopy() }
  @objc private func closeTapped() { onClose() }

  /// 原文那行：换行、连续空白并成一个空格（一行显示）
  private static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

/// 卡片里的一段译文：能选中、不能改；方向键自己挪选中的字，别的键交还给截图页（Esc、↩、工具键）；
/// 只写纯文本（拷出去不带 HUD 的白字和字体）；右键不出菜单（系统菜单的层级比遮罩低，会被压在下面）
private final class CardText: NSTextView {
  var onKey: (NSEvent) -> Void = { _ in }
  var onFocus: () -> Void = {}

  /// 宽度定死、高度按排出来的字：TextKit 1（量高度用布局管理器；TextKit 2 的文本视图一碰 layoutManager 就退回 1 还打日志）
  static func make(_ string: String, width: CGFloat, font: NSFont) -> CardText {
    let text = CardText(usingTextLayoutManager: false)
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.drawsBackground = false
    text.textContainerInset = .zero
    text.isVerticallyResizable = false
    text.isHorizontallyResizable = false
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    text.textStorage?.setAttributedString(
      NSAttributedString(
        string: string, attributes: [.font: font, .foregroundColor: Style.HUD.text]))
    var height = ceil(font.ascender - font.descender)
    if let layout = text.layoutManager, let container = text.textContainer {
      layout.ensureLayout(for: container)
      height = max(height, ceil(layout.usedRect(for: container).height))
    }
    text.frame = CGRect(x: 0, y: 0, width: width, height: height)
    text.setAccessibilityLabel("译文")
    return text
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func keyDown(with event: NSEvent) {
    if Self.movesSelection(event) { super.keyDown(with: event) } else { onKey(event) }
  }

  override func mouseDown(with event: NSEvent) {
    // 先让截图页收下输入中的标注、尺寸（收尺寸时它会把焦点要回遮罩），再把焦点拿回来
    onFocus()
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  /// 方向键、Home / End、翻页（带不带修饰键）：在字里挪选中范围，不交给截图页（那边会挪选区、卡片跟着收掉）
  static func movesSelection(_ event: NSEvent) -> Bool {
    switch event.specialKey {
    case .leftArrow?, .rightArrow?, .upArrow?, .downArrow?, .home?, .end?, .pageUp?, .pageDown?:
      true
    default: false
    }
  }
  override func menu(for event: NSEvent) -> NSMenu? { nil }
  override func rightMouseDown(with event: NSEvent) {}
}

/// 从上往下排的文档视图（滚动视图默认从下往上）
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
