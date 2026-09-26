// 截图调整选区时贴在选区旁的两条栏（Whisker HUD 皮肤，mac-whisker §6 截图；AppKit 按钮，SelectionView 推状态、收回调）：
// - 主栏 EditorToolbar：高 40、圆角 16，标注工具 1–0、撤销、识字、翻译、长截图、钉图、另存为、保存、取消、复制（强调色圆钮）；
//   当前工具的强调色底块在工具间滑动（glide）；松手 40 ms 后浮现（下落 6 pt + 放大到 1，弹簧），拖动 / 缩放选区时淡出让位；
// - 样式托盘 StyleBar：高 34、圆角 10，颜色、粗细，选了工具或标注时出现（马赛克、聚光灯只有粗细），选中的色点加环并放大。
// 永远深色（和系统 ⌘⇧5 一致）：模糊的是窗口里的冻结帧（withinWindow）。按钮都 acceptsFirstMouse（遮罩不是 key 的
// 那块屏上也一点就响应）、不抢第一响应者（输入文字时点按钮不打断输入）。

import AppKit

/// HUD 皮肤的栏：深色材质 + 内 0.5 pt white 0.14 / 外 0.5 pt black 0.5 描边 + 阴影（设 shadowPath，材质视图自己会裁掉阴影）
class HUDBar: NSView {
  let effect = NSVisualEffectView()
  let stack = NSStackView()
  private let radius: CGFloat
  private let height: CGFloat
  private var shown = false

  init(radius: CGFloat, height: CGFloat) {
    self.radius = radius
    self.height = height
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.35
    layer?.shadowRadius = 9
    layer?.shadowOffset = CGSize(width: 0, height: -6)
    effect.material = .hudWindow
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.appearance = NSAppearance(named: .vibrantDark)
    effect.wantsLayer = true
    effect.layer?.cornerRadius = radius - 0.5
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    effect.layer?.borderWidth = 0.5
    effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    effect.autoresizingMask = [.width, .height]
    addSubview(effect)
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.wantsLayer = true
    effect.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func install(_ views: [NSView]) {
    views.forEach(stack.addArrangedSubview)
    fit()
  }

  func fit() {
    stack.layoutSubtreeIfNeeded()
    frame.size = CGSize(width: ceil(stack.fittingSize.width + 1), height: height)
    effect.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
  }

  override func layout() {
    super.layout()
    effect.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    layer?.shadowPath = CGPath(
      roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
  }

  /// 出现：40 ms 后从下方 6 pt、0.96 倍弹到位（spring 0.32 / 0.18）；收起：0.10 s 淡出。减弱动态效果时只改透明度
  func setShown(_ show: Bool) {
    // 只看目标状态：淡出途中重复调 setShown(false) 不能把淡出截断
    guard show != shown else { return }
    shown = show
    guard let layer else {
      isHidden = !show
      return
    }
    layer.removeAnimation(forKey: "appear")
    if show {
      isHidden = false
      layer.opacity = 1
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = 0.12
      let group = CAAnimationGroup()
      var animations: [CAAnimation] = [fade]
      if !Style.reduceMotion {
        let pop = CASpringAnimation(perceptualDuration: 0.32, bounce: 0.18)
        pop.keyPath = "transform"
        pop.fromValue = CATransform3DConcat(
          CATransform3DMakeScale(0.96, 0.96, 1), CATransform3DMakeTranslation(0, -6, 0))
        pop.toValue = CATransform3DIdentity
        pop.duration = pop.settlingDuration
        animations.append(pop)
      }
      group.animations = animations
      group.duration = animations.map(\.duration).max() ?? 0.12
      group.beginTime = CACurrentMediaTime() + 0.04
      group.fillMode = .backwards
      layer.add(group, forKey: "appear")
    } else {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = layer.presentation()?.opacity ?? 1
      fade.toValue = 0
      fade.duration = Style.fadeOut
      layer.opacity = 0
      CATransaction.begin()
      CATransaction.setCompletionBlock { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !self.shown else { return }
          self.isHidden = true
          self.layer?.opacity = 1
        }
      }
      layer.add(fade, forKey: "appear")
      CATransaction.commit()
    }
  }
}

final class EditorToolbar: HUDBar {
  enum Item: Equatable {
    case tool(Annotation.Tool)
    case undo
    case output(RegionSelector.Action)
    case scroll
    case cancel
  }

  var onClick: (Item) -> Void = { _ in }
  private var buttons: [(item: Item, button: NSButton)] = []
  /// 当前工具的强调色底块（全 App 唯一一处强调色填满的块），在工具间滑动
  private let toolHighlight = CALayer()
  private var currentTool: Annotation.Tool?

  init() {
    super.init(radius: Style.Radius.panel, height: 40)
    let groups: [[(Item, String, String)]] = [
      Annotation.Tool.allCases.map { (.tool($0), $0.symbol, "\($0.title)（\($0.key)）") },
      [(.undo, "arrow.uturn.backward", "撤销（⌘Z）")],
      [
        (.output(.recognize), "text.viewfinder", "识字并复制"),
        (.output(.translate), "character.bubble", "翻译"),
      ],
      [
        (.scroll, "rectangle.expand.vertical", "长截图（S，不带标注）"),
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
          action: #selector(clicked(_:)), size: CGSize(width: 32, height: 32))
        button.tag = buttons.count
        buttons.append((item, button))
        views.append(button)
      }
    }
    // 复制：28 pt 强调色圆钮 + 白色对勾
    if let copy = buttons.last?.button {
      copy.wantsLayer = true
      copy.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
      copy.layer?.cornerRadius = 14
      copy.contentTintColor = .white
      copy.symbolConfiguration = .init(pointSize: 13, weight: .bold)
      for constraint in copy.constraints { constraint.constant = 28 }
    }
    install(views)
    toolHighlight.backgroundColor = NSColor.controlAccentColor.cgColor
    toolHighlight.cornerRadius = 12
    toolHighlight.cornerCurve = .continuous
    toolHighlight.opacity = 0
    effect.layer?.insertSublayer(toolHighlight, below: stack.layer)
    update(tool: nil, canUndo: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 当前工具的底块滑过去、图标变白；没有可撤销的时撤销按钮变灰
  func update(tool: Annotation.Tool?, canUndo: Bool) {
    for (item, button) in buttons {
      switch item {
      case .tool(let each): button.contentTintColor = each == tool ? .white : .labelColor
      case .undo: button.isEnabled = canUndo
      case .output(.copy): button.contentTintColor = .white
      default: button.contentTintColor = .labelColor
      }
    }
    guard tool != currentTool else { return }
    let previous = currentTool
    currentTool = tool
    placeHighlight(animated: previous != nil && tool != nil)
  }

  override func layout() {
    super.layout()
    placeHighlight(animated: false)
  }

  private func placeHighlight(animated: Bool) {
    guard
      let tool = currentTool,
      let button = buttons.first(where: { $0.item == .tool(tool) })?.button
    else {
      toolHighlight.opacity = 0
      return
    }
    stack.layoutSubtreeIfNeeded()
    let frame = button.convert(button.bounds, to: effect)
    let target = CGPoint(x: frame.midX, y: frame.midY)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let from = toolHighlight.presentation()?.position ?? toolHighlight.position
    toolHighlight.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
    toolHighlight.position = target
    toolHighlight.opacity = 1
    if animated,
      let slide = Style.Motion.glide.caAnimation(keyPath: "position") as? CABasicAnimation
    {
      slide.fromValue = NSValue(point: from)
      slide.toValue = NSValue(point: target)
      toolHighlight.add(slide, forKey: "slide")
    }
    CATransaction.commit()
  }

  @objc private func clicked(_ sender: NSButton) { onClick(buttons[sender.tag].item) }
}

final class StyleBar: HUDBar {
  var onColor: (Annotation.Palette) -> Void = { _ in }
  var onWeight: (Annotation.Weight) -> Void = { _ in }
  private var colorButtons: [NSButton] = []
  private var weightButtons: [NSButton] = []
  private var separator = NSView()
  /// 上次显示的样式：没变就不重画色块（refresh 跟着鼠标移动一直在调）
  private var shown: (style: Annotation.Style, showsColors: Bool)?

  init() {
    super.init(radius: Style.Radius.card, height: 34)
    colorButtons = Annotation.Palette.allCases.map { color in
      let button = barButton(
        Self.swatch(color, selected: false), tip: color.title, action: #selector(pickColor(_:)),
        size: CGSize(width: 28, height: 28))
      button.tag = color.rawValue
      return button
    }
    weightButtons = Annotation.Weight.allCases.map { weight in
      let button = barButton(
        Self.dot(weight, selected: false), tip: weight.title, action: #selector(pickWeight(_:)),
        size: CGSize(width: 28, height: 28))
      button.tag = weight.rawValue
      return button
    }
    separator = barSeparator()
    install(colorButtons + [separator] + weightButtons)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 选中的颜色和粗细套个圈（色点放大到 1.1）；马赛克、聚光灯没有颜色，只留粗细（格子大小 / 压暗程度）
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
    fit()
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
    return NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
      let inset: CGFloat = selected ? 4 : 5.2
      let circle = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
      fill.setFill()
      circle.fill()
      NSColor.white.withAlphaComponent(0.3).setStroke()  // 黑色在深色栏上也看得见
      circle.lineWidth = 0.5
      circle.stroke()
      if selected { ring(in: rect) }
      return true
    }
  }

  private static func dot(_ weight: Annotation.Weight, selected: Bool) -> NSImage {
    let diameter: CGFloat = [4, 7, 10][weight.rawValue]
    return NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
      NSColor.white.withAlphaComponent(0.92).setFill()
      NSBezierPath(
        ovalIn: NSRect(
          x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter,
          height: diameter)
      ).fill()
      if selected { ring(in: rect) }
      return true
    }
  }

  /// 2 pt 强调色环
  nonisolated private static func ring(in rect: NSRect) {
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
    ring.lineWidth = 2
    NSColor.controlAccentColor.setStroke()
    ring.stroke()
  }
}

extension NSView {
  /// 栏里的图标按钮（截图工具栏、样式托盘、长截图面板共用）
  func barButton(
    _ image: NSImage, tip: String, action: Selector, size: CGSize = CGSize(width: 30, height: 28)
  ) -> NSButton {
    let button = BarButton(image: image, target: self, action: action)
    button.toolTip = tip
    button.isBordered = false
    button.refusesFirstResponder = true
    button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
    button.widthAnchor.constraint(equalToConstant: size.width).isActive = true
    button.heightAnchor.constraint(equalToConstant: size.height).isActive = true
    return button
  }

  /// 分组分隔线 1 × 18（跟随外观：HUD 的深色外观下是浅色细线）
  func barSeparator() -> NSView {
    let separator = NSBox()
    separator.boxType = .custom
    separator.borderWidth = 0
    separator.fillColor = .separatorColor
    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
    separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
    return separator
  }
}

/// 遮罩不是 key 的那块屏上也要一点就响应
private final class BarButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
