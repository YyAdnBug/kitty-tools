// 截图调整选区时贴在选区旁的两条栏（AppKit 按钮；SelectionView 推状态、收回调）：
// - 主栏 EditorToolbar：标注工具 1–4、撤销、识字、翻译、钉图、另存为、保存、取消、复制；
// - 样式栏 StyleBar：颜色、粗细，选了工具或标注时出现（马赛克只有粗细）。
// 按钮都 acceptsFirstMouse（遮罩不是 key 的那块屏上也一点就响应）、不抢第一响应者（输入文字时点按钮不打断输入）。

import AppKit

final class EditorToolbar: NSVisualEffectView {
  enum Item: Equatable {
    case tool(Annotation.Tool)
    case undo
    case output(RegionSelector.Action)
    case cancel
  }

  var onClick: (Item) -> Void = { _ in }
  private var buttons: [(item: Item, button: NSButton)] = []

  init() {
    super.init(frame: .zero)
    let groups: [[(Item, String, String)]] = [
      Annotation.Tool.allCases.map { (.tool($0), $0.symbol, "\($0.title)（\($0.rawValue)）") },
      [(.undo, "arrow.uturn.backward", "撤销（⌘Z）")],
      [
        (.output(.recognize), "text.viewfinder", "识字并复制"),
        (.output(.translate), "character.bubble", "翻译"),
      ],
      [
        (.output(.pin), "pin", "钉图（T）"),
        (.output(.saveAs), "square.and.arrow.down.on.square", "另存为…（⇧⌘S）"),
        (
          .output(.save), "square.and.arrow.down",
          "保存到「\(ScreenshotOutput.saveDirectory.lastPathComponent)」（⌘S）"
        ),
      ],
      [(.cancel, "xmark", "取消（Esc）"), (.output(.copy), "checkmark", "复制（↩）")],
    ]
    var views: [NSView] = []
    for (index, group) in groups.enumerated() {
      if index > 0 { views.append(barSeparator()) }
      for (item, symbol, tip) in group {
        let button = barButton(
          NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, tip: tip,
          action: #selector(clicked(_:)))
        button.tag = buttons.count
        buttons.append((item, button))
        views.append(button)
      }
    }
    install(views)
    update(tool: nil, canUndo: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 当前工具亮起（强调色），没有可撤销的时撤销按钮变灰
  func update(tool: Annotation.Tool?, canUndo: Bool) {
    for (item, button) in buttons {
      switch item {
      case .tool(let each):
        button.contentTintColor = each == tool ? .controlAccentColor : .labelColor
      case .undo: button.isEnabled = canUndo
      case .output(.copy): button.contentTintColor = .controlAccentColor
      default: button.contentTintColor = .labelColor
      }
    }
  }

  @objc private func clicked(_ sender: NSButton) { onClick(buttons[sender.tag].item) }
}

final class StyleBar: NSVisualEffectView {
  var onColor: (Annotation.Palette) -> Void = { _ in }
  var onWeight: (Annotation.Weight) -> Void = { _ in }
  private var colorButtons: [NSButton] = []
  private var weightButtons: [NSButton] = []
  private var separator = NSView()
  /// 上次显示的样式：没变就不重画色块（refresh 跟着鼠标移动一直在调）
  private var shown: (style: Annotation.Style, showsColors: Bool)?

  init() {
    super.init(frame: .zero)
    colorButtons = Annotation.Palette.allCases.map { color in
      let button = barButton(
        Self.swatch(color, selected: false), tip: color.title, action: #selector(pickColor(_:)))
      button.tag = color.rawValue
      return button
    }
    weightButtons = Annotation.Weight.allCases.map { weight in
      let button = barButton(
        Self.dot(weight, selected: false), tip: weight.title, action: #selector(pickWeight(_:)))
      button.tag = weight.rawValue
      return button
    }
    separator = barSeparator()
    install(colorButtons + [separator] + weightButtons)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 选中的颜色和粗细套个圈；马赛克没有颜色，只留粗细（格子大小）
  func update(_ style: Annotation.Style, showsColors: Bool) {
    guard shown?.style != style || shown?.showsColors != showsColors else { return }
    shown = (style, showsColors)
    for button in colorButtons {
      let color = Annotation.Palette(rawValue: button.tag)!
      button.image = Self.swatch(color, selected: color == style.color)
      button.isHidden = !showsColors
    }
    separator.isHidden = !showsColors
    for button in weightButtons {
      let weight = Annotation.Weight(rawValue: button.tag)!
      button.image = Self.dot(weight, selected: weight == style.weight)
    }
    frame.size = fittingSize
  }

  @objc private func pickColor(_ sender: NSButton) {
    onColor(Annotation.Palette(rawValue: sender.tag)!)
  }

  @objc private func pickWeight(_ sender: NSButton) {
    onWeight(Annotation.Weight(rawValue: sender.tag)!)
  }

  // 画图闭包在绘制时才跑（不保证在主 actor 上）：用到的值先取出来
  private static func swatch(_ color: Annotation.Palette, selected: Bool) -> NSImage {
    let fill = color.color
    return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
      let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
      fill.setFill()
      circle.fill()
      NSColor.secondaryLabelColor.setStroke()  // 白色在浅色底上也看得见
      circle.lineWidth = 0.5
      circle.stroke()
      if selected { ring(in: rect) }
      return true
    }
  }

  private static func dot(_ weight: Annotation.Weight, selected: Bool) -> NSImage {
    let diameter: CGFloat = [4, 7, 10][weight.rawValue]
    return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
      NSColor.labelColor.setFill()
      NSBezierPath(
        ovalIn: NSRect(
          x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter,
          height: diameter)
      ).fill()
      if selected { ring(in: rect) }
      return true
    }
  }

  nonisolated private static func ring(in rect: NSRect) {
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
    ring.lineWidth = 1.5
    NSColor.controlAccentColor.setStroke()
    ring.stroke()
  }
}

extension NSVisualEffectView {
  /// 两条栏共用的外观：模糊窗口里的冻结帧（withinWindow，不是背后真实的桌面）、圆角、一行按钮
  fileprivate func install(_ views: [NSView]) {
    material = .popover
    blendingMode = .withinWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 8
    let stack = NSStackView(views: views)
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    frame.size = fittingSize
  }

  fileprivate func barButton(_ image: NSImage, tip: String, action: Selector) -> NSButton {
    let button = BarButton(image: image, target: self, action: action)
    button.toolTip = tip
    button.isBordered = false
    button.refusesFirstResponder = true
    button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
  }

  fileprivate func barSeparator() -> NSView {
    let separator = NSBox()
    separator.boxType = .separator
    separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
    return separator
  }
}

/// 遮罩不是 key 的那块屏上也要一点就响应
private final class BarButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
