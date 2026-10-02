// 截图调整选区时贴在选区旁的 HUD 控件（Whisker HUD 皮肤，mac-whisker §6 截图；AppKit，SelectionView 推状态、收回调）：
// - 主栏 EditorToolbar：两段 HUD 胶囊并排（间距 6，高 40、圆角 16，按钮 32）：左段 10 个工具 ｜ 撤销、重做；右段识字、翻译、
//   长截图、录屏（录屏第 2 批：原地换成录制条）、钉图 ｜ 存储（本体快速保存，右侧 ▾ 弹菜单）｜ 取消、拷贝（28 pt 品牌粉圆钮）。当前工具的粉色底块在工具间滑动（glide）；
//   松手 40 ms 后从靠选区的那条边长出来（pop，bounce 0.18），拖动 / 缩放 / 平移选区时淡出让位；
// - 样式托盘 StyleBar：高 34、圆角 10，按工具出 8 色点 ｜ 三档 ｜ 选项分段，锚在当前工具按钮下方 6 pt，换工具时位置和宽度 settle；
// - HUDMenu：遮罩里的 HUD 弹出菜单（保存 ▾，之后尺寸胶囊的比例菜单也用它），不用 NSMenu（菜单层级低于遮罩，会被压在下面）；
// - 录制条 RecordBar（录屏框选的调整阶段，放在主栏的位置）：一段 HUD 胶囊 [系统声音][麦克风][显示点按][显示按键] ｜
//   [取消][● 开始录制]，长出 / 淡出同主栏；四个开关记在偏好里（录屏第 4 批；显示按键是手测反馈第 2 批加的）。
// 永远深色（和系统 ⌘⇧5 一致）：模糊的是窗口里的冻结帧（withinWindow）；macOS 26 起材质是深色液态玻璃（HUDBar，
// 主栏两段放进一个 NSGlassEffectContainerView，mac-whisker §2）。按钮都 acceptsFirstMouse（遮罩不是 key 的
// 那块屏上也一点就响应）、不抢第一响应者（输入文字时点按钮不打断输入）。

import AVFoundation
import AppKit

/// 遮罩里会「长出来 / 淡出」的控件：显示只走 setShown，不要直接改 isHidden。
/// 图层支持的 NSView 的图层 anchorPoint 是 (0, 0)，缩放围绕的点要自己拼进变换
class PopView: NSView {
  enum Edge { case top, bottom }

  private(set) var isShown = false

  /// 截图主栏、录制条：靠选区的那条边的中点长出来（栏在选区下方从顶边 .top，在上方或选区里时从底边），两条栏同一套参数
  func grow(_ show: Bool, from edge: Edge = .top) {
    setShown(
      show, anchor: CGPoint(x: bounds.midX, y: edge == .top ? bounds.height : 0),
      rise: edge == .top ? 8 : -8, scale: 0.94, delay: 0.04, bounce: 0.18)
  }

  /// 出现：delay 后从 anchor（自身坐标）处 scale → 1、竖直偏 rise → 0（curve 弹簧）+ 淡入；收起：0.10 s 淡出后隐藏。
  /// 减弱动态效果时按 §7 只改透明度：pop / settle 退成 0.2 s easeInOut 淡入，snap / glide 直接出现
  func setShown(
    _ show: Bool, anchor: CGPoint, rise: CGFloat, scale: CGFloat, delay: Double = 0,
    curve: Style.Motion = .pop, bounce: Double? = nil
  ) {
    // 只看目标状态：淡出途中重复调 setShown(false) 不能把淡出截断
    guard show != isShown else { return }
    isShown = show
    guard let layer else {
      isHidden = !show
      return
    }
    layer.removeAnimation(forKey: "appear")
    if show {
      isHidden = false
      layer.opacity = 1
      let reduced = Style.reduceMotion
      let fade: CABasicAnimation
      if reduced {
        guard let basic = curve.caAnimation(keyPath: "opacity", reduced: true) as? CABasicAnimation
        else { return }
        fade = basic
      } else {
        fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = Style.fadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
      }
      fade.fromValue = 0
      fade.toValue = 1
      var animations: [CAAnimation] = [fade]
      if !reduced,
        let grow = curve.caAnimation(keyPath: "transform", reduced: false, bounce: bounce)
          as? CABasicAnimation
      {
        // 先把 anchor 挪到原点、缩放、再挪回去并偏 rise
        var from = CATransform3DMakeTranslation(-anchor.x, -anchor.y, 0)
        from = CATransform3DConcat(from, CATransform3DMakeScale(scale, scale, 1))
        from = CATransform3DConcat(from, CATransform3DMakeTranslation(anchor.x, anchor.y + rise, 0))
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animations.append(grow)
      }
      let group = CAAnimationGroup()
      group.animations = animations
      group.duration = animations.map(\.duration).max() ?? Style.fadeIn
      group.beginTime = CACurrentMediaTime() + delay
      group.fillMode = .backwards
      layer.add(group, forKey: "appear")
    } else {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = layer.presentation()?.opacity ?? 1
      fade.toValue = 0
      fade.duration = Style.fadeOut
      fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
      layer.opacity = 0
      CATransaction.begin()
      CATransaction.setCompletionBlock { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !self.isShown else { return }
          self.isHidden = true
          self.layer?.opacity = 1
        }
      }
      layer.add(fade, forKey: "appear")
      CATransaction.commit()
    }
  }
}

/// HUD 皮肤的栏（Style.HUD）：深色材质 + 内圈 / 外圈描边 + 阴影（设 shadowPath，材质视图自己会裁掉阴影）。
/// macOS 26 起材质换成液态玻璃（mac-whisker §2）：铺满、圆角交给玻璃，不画描边和阴影
class HUDBar: PopView {
  /// 材质：15 是 NSVisualEffectView（内缩 0.5，外圈描边在外面），26 是 NSGlassEffectView（铺满）
  fileprivate let material: NSView
  /// 内容的父视图（按钮栈、当前工具底块、菜单行）：15 就是材质本身，26 是玻璃的 contentView
  let effect: NSView
  let stack = NSStackView()
  private let radius: CGFloat
  private let height: CGFloat

  /// blending：遮罩里的栏模糊窗口里的冻结帧（withinWindow）；自己一个窗口的（录制 HUD）模糊背后的桌面（behindWindow）
  init(
    radius: CGFloat, height: CGFloat,
    blending: NSVisualEffectView.BlendingMode = .withinWindow
  ) {
    self.radius = radius
    self.height = height
    if #available(macOS 26, *) {
      // HUD 永远深色；两个无障碍开关交给玻璃
      let glass = NSGlassEffectView()
      glass.cornerRadius = radius
      glass.appearance = NSAppearance(named: .darkAqua)
      effect = NSView()
      effect.wantsLayer = true  // 当前工具的底块是加在它图层上的子图层
      effect.autoresizingMask = [.width, .height]  // 玻璃按 Auto Layout 撑满它，掩码和那组约束一致
      glass.contentView = effect
      material = glass
    } else {
      let effect = NSVisualEffectView()
      effect.material = .hudWindow
      effect.blendingMode = blending
      effect.state = .active
      effect.appearance = NSAppearance(named: .vibrantDark)
      effect.wantsLayer = true
      effect.layer?.cornerRadius = radius - 0.5
      effect.layer?.cornerCurve = .continuous
      effect.layer?.masksToBounds = true
      effect.layer?.borderWidth = Style.HUD.strokeWidth
      effect.layer?.borderColor = Style.HUD.innerStroke.cgColor
      self.effect = effect
      material = effect
    }
    super.init(frame: .zero)
    wantsLayer = true
    if #unavailable(macOS 26) {
      layer?.cornerRadius = radius
      layer?.cornerCurve = .continuous
      layer?.borderWidth = 0.5
      layer?.borderColor = Style.HUD.outerStroke.cgColor
    }
    material.autoresizingMask = [.width, .height]
    addSubview(material)
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.wantsLayer = true
    effect.addSubview(stack)
    // 右边不设成必需：换内容后、栏还没改宽的那一下（样式托盘换工具）内容比栏宽，溢出被材质裁掉，不报约束冲突
    let trailing = stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
    trailing.priority = .init(999)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), trailing,
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
    frame.size = CGSize(
      width: ceil(stack.fittingSize.width + 2 * Self.materialInset), height: height)
    applyGeometry()
  }

  /// 材质内缩 0.5（外圈描边在外面）；阴影按圆角矩形设 shadowPath。26 的玻璃铺满、阴影系统画
  func applyGeometry() {
    guard bounds.width > 1, bounds.height > 1 else { return }  // 零尺寸内缩出来是 null 矩形（原点无穷大）
    let inner = bounds.insetBy(dx: Self.materialInset, dy: Self.materialInset)
    if material.frame != inner {
      material.frame = inner
      material.needsLayout = true  // 直接改 frame 不会让里面按约束居中的 stack 重排
    }
    guard #unavailable(macOS 26), let layer else { return }
    Style.HUD.applyShadow(
      to: layer,
      path: CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
  }

  /// 材质离栏边的距离：15 给外圈 0.5 pt 描边让位，26 的玻璃没有这圈描边。栏宽、菜单行、钉图圆钮的按钮都从它算
  static var materialInset: CGFloat {
    if #available(macOS 26, *) { return 0 }
    return 0.5
  }

  override func layout() {
    super.layout()
    applyGeometry()
  }
}

// MARK: - 主栏

final class EditorToolbar: PopView {
  enum Item: Equatable {
    case tool(Annotation.Tool)
    case undo
    case redo
    /// .output(.save) 是保存本体（单击快速保存）
    case output(RegionSelector.Action)
    case scroll
    /// 录屏：会话切到录屏、工具栏原地换成录制条（有标注时不切）
    case record
    /// 保存右侧的 ▾：弹出「存储到 / 另存为」菜单
    case saveMenu
    case cancel
  }

  var onClick: (Item) -> Void = { _ in }
  private let tools = HUDBar(radius: Style.Radius.panel, height: 40)
  private let outputs = HUDBar(radius: Style.Radius.panel, height: 40)
  private var buttons: [(item: Item, button: BarButton)] = []
  /// 当前工具的粉色底块（全 App 唯一一处强调色填满的块），在工具间滑动
  private let toolHighlight = CALayer()
  private var state: (tool: Annotation.Tool?, canUndo: Bool, canRedo: Bool)?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // (item, 符号, 旁白名字, 悬停提示)
    typealias Spec = (Item, String, String, String)
    let left: [[Spec]] = [
      Annotation.Tool.allCases.map { (.tool($0), $0.symbol, $0.title, "\($0.title)（\($0.key)）") },
      [
        (.undo, "arrow.uturn.backward", "撤销", "撤销（⌘Z）"),
        (.redo, "arrow.uturn.forward", "重做", "重做（⇧⌘Z）"),
      ],
    ]
    let right: [[Spec]] = [
      [
        (.output(.recognize), "text.viewfinder", "识字并拷贝", "识字并拷贝（O）"),
        (.output(.translate), "translate", "翻译", "翻译"),
        (.scroll, "rectangle.expand.vertical", "长截图", "长截图（S，不带标注）"),
        (.record, "record.circle", "录屏", "录屏（R）"),
        (.output(.pin), "pin", "钉到屏幕", "钉到屏幕（T）"),
      ],
      [
        (.output(.save), "square.and.arrow.down", "存储", ScreenshotOutput.saveTitle + "（⌘S）"),
        (.saveMenu, "chevron.down", "更多存储选项", "存储到… / 另存为…"),
      ],
      [(.cancel, "xmark", "取消", "取消（Esc）"), (.output(.copy), "checkmark", "拷贝", "拷贝（↩）")],
    ]
    tools.install(makeButtons(left))
    outputs.install(makeButtons(right))
    if let save = button(for: .output(.save)) { outputs.stack.setCustomSpacing(0, after: save) }
    if let cancel = button(for: .cancel) { outputs.stack.setCustomSpacing(4, after: cancel) }
    outputs.stack.edgeInsets.right = 6
    outputs.fit()
    if #available(macOS 26, *) {
      // 两段相邻的玻璃放进同一个容器：共用取样、一次渲染；spacing 0 = 不融合成一块
      let group = NSView()
      group.autoresizingMask = [.width, .height]  // 同 HUDBar 的 effect：容器按 Auto Layout 撑满它
      group.addSubview(tools)
      group.addSubview(outputs)
      let container = NSGlassEffectContainerView()
      container.contentView = group
      container.autoresizingMask = [.width, .height]
      addSubview(container)
    } else {
      addSubview(tools)
      addSubview(outputs)
    }
    outputs.frame.origin.x = tools.frame.maxX + 6
    frame.size = CGSize(width: outputs.frame.maxX, height: 40)
    layoutSubtreeIfNeeded()
    toolHighlight.backgroundColor = Style.Shot.accent.cgColor
    toolHighlight.cornerRadius = Style.Shot.toolRadius
    toolHighlight.cornerCurve = .continuous
    toolHighlight.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
    toolHighlight.opacity = 0
    tools.effect.layer?.insertSublayer(toolHighlight, below: tools.stack.layer)
    update(tool: nil, canUndo: false, canRedo: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func makeButtons(_ groups: [[(Item, String, String, String)]]) -> [NSView] {
    var views: [NSView] = []
    for (index, group) in groups.enumerated() {
      if index > 0 { views.append(barSeparator()) }
      for (item, symbol, label, tip) in group {
        let size: CGSize =
          switch item {
          case .output(.copy): CGSize(width: 28, height: 28)
          case .output(.save): CGSize(width: 30, height: 32)
          case .saveMenu: CGSize(width: 14, height: 32)
          default: CGSize(width: 32, height: 32)
          }
        let button = barButton(
          NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, tip: tip,
          label: label, action: #selector(clicked(_:)), size: size)
        button.tag = buttons.count
        switch item {
        case .output(.copy):
          // 拷贝：28 pt 强调色实心圆 + 对勾（主按钮），不出悬停底
          button.showsHover = false
          button.layer?.backgroundColor = Style.Shot.accent.cgColor
          button.layer?.cornerRadius = 14
          button.contentTintColor = Style.Shot.onAccent
          button.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        case .saveMenu:
          button.contentTintColor = Style.HUD.secondaryText
          button.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        default:
          break
        }
        buttons.append((item, button))
        views.append(button)
      }
    }
    return views
  }

  func button(for item: Item) -> NSButton? { buttons.first { $0.item == item }?.button }

  /// 工具按钮在本视图里的位置（样式托盘锚在它下面）
  func toolButtonFrame(_ tool: Annotation.Tool) -> CGRect {
    guard let button = button(for: .tool(tool)) else { return .zero }
    return button.convert(button.bounds, to: self)
  }

  /// 当前工具的底块滑过去、图标换成强调色上的符号色（白，黄色这类亮色上是深色）；撤销 / 重做没得做时变灰。跟着鼠标移动一直在调，状态没变就不动
  func update(tool: Annotation.Tool?, canUndo: Bool, canRedo: Bool) {
    if let state, state.tool == tool, state.canUndo == canUndo, state.canRedo == canRedo { return }
    let previous = state?.tool
    state = (tool, canUndo, canRedo)
    for (item, button) in buttons {
      switch item {
      case .tool(let each):
        button.contentTintColor = each == tool ? Style.Shot.onAccent : Style.HUD.text
        button.showsHover = each != tool  // 强调色底块上不叠悬停底
      case .undo: button.isEnabled = canUndo
      case .redo: button.isEnabled = canRedo
      case .output(.copy), .saveMenu: break
      default: button.contentTintColor = Style.HUD.text
      }
    }
    if tool != previous { moveHighlight(from: previous) }
  }

  /// 有 → 有：glide 滑过去；无 → 有：原地 pop；有 → 无：缩小淡出（0.12 s）
  private func moveHighlight(from previous: Annotation.Tool?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let reduced = Style.reduceMotion
    let fromOpacity = toolHighlight.presentation()?.opacity ?? toolHighlight.opacity
    let fromScale = toolHighlight.presentation()?.value(forKeyPath: "transform.scale") ?? 1
    guard let tool = state?.tool, let button = button(for: .tool(tool)) else {
      guard previous != nil else { return }
      toolHighlight.opacity = 0
      toolHighlight.transform = CATransform3DMakeScale(0.6, 0.6, 1)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = fromOpacity
      let shrink = CABasicAnimation(keyPath: "transform.scale")
      shrink.fromValue = reduced ? 0.6 : fromScale
      for animation in [fade, shrink] {
        animation.duration = 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
      }
      toolHighlight.add(fade, forKey: "fade")
      toolHighlight.add(shrink, forKey: "scale")
      return
    }
    let frame = button.convert(button.bounds, to: tools.effect)
    let from = toolHighlight.presentation()?.position ?? toolHighlight.position
    toolHighlight.position = CGPoint(x: frame.midX, y: frame.midY)
    toolHighlight.opacity = 1
    toolHighlight.transform = CATransform3DIdentity
    if previous == nil {
      toolHighlight.removeAnimation(forKey: "slide")
      // 减弱动态效果时 pop 退成 0.2 s easeInOut 淡入（§7）
      let fade =
        (reduced
          ? Style.Motion.pop.caAnimation(keyPath: "opacity", reduced: true) as? CABasicAnimation
          : nil) ?? CABasicAnimation(keyPath: "opacity")
      if !reduced {
        fade.duration = Style.fadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
      }
      fade.fromValue = fromOpacity
      toolHighlight.add(fade, forKey: "fade")
      if !reduced,
        let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
          as? CABasicAnimation
      {
        pop.fromValue = 0.6
        toolHighlight.add(pop, forKey: "scale")
      } else {
        toolHighlight.removeAnimation(forKey: "scale")
      }
    } else if let slide = Style.Motion.glide.caAnimation(keyPath: "position") as? CABasicAnimation {
      slide.fromValue = NSValue(point: from)
      toolHighlight.add(slide, forKey: "slide")
    }
  }

  @objc private func clicked(_ sender: NSButton) { onClick(buttons[sender.tag].item) }
}

// MARK: - 录制条

/// 录屏框选调整时贴在选区旁的栏（截图主栏的位置，mac-whisker §6 截图「录屏」）：[系统声音][麦克风][显示点按][显示按键] ｜
/// [取消][● 开始录制]，按钮同主栏（32 × 32、悬停底、按下 0.90），开始是 28 pt 强调色实心圆 + 实心圆点（画法同主栏的
/// 拷贝钮；强调色选红时靠 ● / ■ 形状和停止分开）。四个开关（录屏第 4 批；显示按键是手测反馈第 2 批）开 = 图标染强调色
/// （同长截图自动滚动钮的开启态），关 = 换一个形状（斜杠 / 不带点击波纹 / 空心的键盘），不只靠颜色（石墨强调色比主文字色
/// 还暗）；换图走 .replace；点了就写偏好（记住上次，设置页不重复）并播报新状态，开录时 ScreenRecorder 读；每次长出来都按
/// 偏好重画（多屏时每块屏各一根，别的屏上点过的这根要跟上）。
/// 麦克风没问过授权时打开只记偏好：遮罩开着时系统授权框会被压在下面，按开始、遮罩收起后才问；显示按键要辅助功能授权，
/// 同样只记偏好，开录时没授权就这次不显示、开关弹回
final class RecordBar: HUDBar {
  enum Item: CaseIterable {
    case systemAudio, microphone, clicks, keys, cancel, start

    /// 前面那几个开关
    static let toggles: [Item] = [.systemAudio, .microphone, .clicks, .keys]
  }

  var onClick: (Item) -> Void = { _ in }
  /// 开关记在哪（SelectionView.styleDefaults：交互测试换成临时偏好域）；换了就按它重画开关
  var defaults: UserDefaults {
    didSet { applyToggles(animated: false) }
  }
  private let items = Item.allCases
  /// 系统当前的输入设备（名字、是不是蓝牙）：第一次查要几十毫秒（实测约 70 ms），不在建栏、悬停、点击时查，提示要弹出 / 读屏时
  /// 才查，这一次框选里记住
  private lazy var input = Self.currentInput()

  /// 系统当前的输入设备（录制条、录音控制条待录时的麦克风开关共用；慢，见上）
  static func currentInput() -> (name: String, bluetooth: Bool)? {
    AVCaptureDevice.default(for: .audio).map {
      ($0.localizedName, isBluetooth($0.transportType))
    }
  }

  init(defaults: UserDefaults) {
    self.defaults = defaults
    super.init(radius: Style.Radius.panel, height: 40)
    let toggles = Item.toggles.map { item in
      let button = ToggleButton()
      button.target = self
      button.action = #selector(clicked(_:))
      button.describe = { [unowned self] in tip(for: item, device: true) }
      return button as BarButton
    }
    let cancel = barButton(
      NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消")!, tip: "取消（Esc）",
      label: "取消", action: #selector(clicked(_:)), size: CGSize(width: 32, height: 32))
    let start = barButton(
      NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "开始录制")!,
      tip: "开始录制（↩）", label: "开始录制", action: #selector(clicked(_:)),
      size: CGSize(width: 28, height: 28))
    start.showsHover = false
    start.layer?.backgroundColor = Style.Shot.accent.cgColor
    start.layer?.cornerRadius = 14
    start.contentTintColor = Style.Shot.onAccent
    start.symbolConfiguration = .init(pointSize: 10, weight: .bold)
    let buttons = toggles + [cancel, start]
    for (index, button) in buttons.enumerated() { button.tag = index }
    stack.edgeInsets.right = 6
    install(toggles as [NSView] + [barSeparator(), cancel, start])
    stack.setCustomSpacing(4, after: cancel)
    applyToggles(animated: false)
    fit()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func button(for item: Item) -> NSButton? {
    items.firstIndex(of: item).flatMap { index in
      stack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.tag == index }
    }
  }

  /// 长出来时按偏好重画开关：多屏时每块屏的遮罩各有一根录制条，在别的屏上点过的开关这根还不知道
  override func grow(_ show: Bool, from edge: Edge = .top) {
    if show, !isShown { applyToggles(animated: false) }
    super.grow(show, from: edge)
  }

  /// 开关：写偏好、换图、播报新状态（不带设备名，不在点击路径上查设备）；也交给 onClick（点栏上的钮算点在 HUD 菜单外面、
  /// 先提交尺寸输入，同截图主栏）
  @objc private func clicked(_ sender: NSButton) {
    let item = items[sender.tag]
    if let key = Self.key(for: item) {
      defaults.set(!isOn(item), forKey: key)
      applyToggles(animated: true, only: item)
      Island.announce(tip(for: item, device: false))
    }
    onClick(item)
  }

  private func isOn(_ item: Item) -> Bool {
    let options = ScreenRecorder.Options(defaults)
    return switch item {
    case .systemAudio: options.systemAudio
    case .microphone: options.microphone
    case .clicks: options.showsClicks
    case .keys: options.showsKeys
    case .cancel, .start: false
    }
  }

  private static func key(for item: Item) -> String? {
    switch item {
    case .systemAudio: Prefs.screenRecordSystemAudio
    case .microphone: Prefs.screenRecordMicrophone
    case .clicks: Prefs.screenRecordShowsClicks
    case .keys: Prefs.screenRecordShowsKeys
    case .cancel, .start: nil
    }
  }

  /// 开关的样子：符号（开 / 关形状不同）、强调色 / 主文字色。提示和旁白名字由 ToggleButton 要显示时现算（describe）
  private func applyToggles(animated: Bool, only: Item? = nil) {
    for item in Item.toggles where only == nil || only == item {
      guard let button = button(for: item) as? ToggleButton else { continue }
      let on = isOn(item)
      let symbol =
        switch item {
        case .systemAudio: on ? "speaker.wave.2.fill" : "speaker.slash.fill"
        case .microphone: on ? "mic.fill" : "mic.slash.fill"
        case .keys: on ? "keyboard.fill" : "keyboard"
        default: on ? "cursorarrow.click.2" : "cursorarrow"
        }
      button.show(symbol, on: on, animated: animated)
    }
  }

  /// 「系统声音：开」「麦克风：开（MacBook Air 麦克风）」「显示点按：关」「显示按键：开」+ 提醒。device：查系统当前输入设备
  /// （写设备名、蓝牙提示）
  private func tip(for item: Item, device: Bool) -> String {
    let on = isOn(item)
    switch item {
    case .systemAudio: return "系统声音：\(on ? "开" : "关")"
    case .microphone:
      let input = device ? input : nil
      return Self.microphoneTip(on: on, device: input?.name, bluetooth: input?.bluetooth ?? false)
    case .keys:
      return Self.keysTip(
        on: on, shortcutsOnly: defaults.bool(forKey: Prefs.screenRecordKeysShortcutsOnly))
    default: return "显示点按：\(on ? "开" : "关")"
    }
  }

  /// 显示按键开关的提示（纯函数，配单测）：开着时提醒一句——按下的键都会进画面（不承诺密码不会显示：终端里输的密码
  /// 这类不一定走系统的安全输入）；设置里选了只显示快捷键时打字本来就不进画面，不用提密码，说明显示的是什么
  nonisolated static func keysTip(on: Bool, shortcutsOnly: Bool = false) -> String {
    guard on else { return "显示按键：关" }
    return shortcutsOnly
      ? "显示按键：开\n只显示快捷键，打字不进画面" : "显示按键：开\n按下的键会录进画面，要输密码先关掉"
  }

  /// 麦克风开关的提示（纯函数，配单测）：开时带设备名；当前输入是蓝牙时（开关两态都）再加一句，免得打开了才发现音质变差
  nonisolated static func microphoneTip(on: Bool, device: String?, bluetooth: Bool) -> String {
    let state = on ? "开" + (device.map { "（\($0)）" } ?? "") : "关"
    return "麦克风：\(state)" + (bluetooth ? "\n蓝牙耳机麦克风会变成通话音质" : "")
  }

  /// AVCaptureDevice.transportType 是不是蓝牙（CoreAudio 的 kAudioDeviceTransportTypeBluetooth 'blue'、
  /// kAudioDeviceTransportTypeBluetoothLE 'blea'；不为两个常量引入 CoreAudio）
  nonisolated static func isBluetooth(_ transportType: Int32) -> Bool {
    [0x626C_7565, 0x626C_6561].contains(UInt32(bitPattern: transportType))
  }
}

/// 录制条的开关钮：符号放在按钮里的图像视图上（NSButton 换图没有符号过渡），换图走 .replace（减弱动态效果时直接换）；
/// 开 = 强调色、关 = 主文字色。提示和旁白名字每次现算（麦克风要查当前输入设备）：提示走系统的懒提示（addToolTip +
/// NSViewToolTipOwner），真要弹出时才问 describe，悬停出底的路径上不查设备
final class ToggleButton: BarButton, NSViewToolTipOwner {
  var describe: () -> String = { "" }
  private let symbol = PassiveImageView()

  init() {
    // 一开始就是最终尺寸：图像视图按自动缩放掩码跟着按钮，从 0 × 0 长到 32 × 32 会被多撑出 32（图歪到右上角）
    super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    title = ""
    imagePosition = .noImage
    isBordered = false
    refusesFirstResponder = true
    symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
      .applying(.preferringHierarchical())
    symbol.imageScaling = .scaleNone
    symbol.frame = bounds
    symbol.autoresizingMask = [.width, .height]
    addSubview(symbol)
    widthAnchor.constraint(equalToConstant: 32).isActive = true
    heightAnchor.constraint(equalToConstant: 32).isActive = true
    addToolTip(bounds, owner: self, userData: nil)  // 视图对 owner 是弱引用
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ name: String, on: Bool, animated: Bool) {
    guard let next = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    if animated, !Style.reduceMotion, symbol.image != nil {
      symbol.setSymbolImage(next, contentTransition: .replace)
    } else {
      symbol.image = next
    }
    symbol.contentTintColor = on ? Style.Shot.accent : Style.HUD.text
  }

  func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String { describe() }

  override func accessibilityLabel() -> String? { describe() }
}

/// 只显示、不接鼠标的图像视图：点击落到外面的按钮上
private final class PassiveImageView: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 样式托盘

final class StyleBar: HUDBar {
  var onColor: (Annotation.Palette) -> Void = { _ in }
  var onWeight: (Annotation.Weight) -> Void = { _ in }
  var onOption: (Int) -> Void = { _ in }
  /// 按当前工具排好内容后的尺寸；位置由 SelectionView 定（move）
  private(set) var preferredSize = CGSize.zero
  private var tool: Annotation.Tool?
  private var style: Annotation.Style?
  private var colors: [Swatch] = []
  private var weights: [Swatch] = []
  private var options: [BarButton] = []

  /// 托盘高（工具栏放哪时要给它留地方）
  static let height: CGFloat = 34

  init() {
    super.init(radius: Style.Radius.card, height: Self.height)
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    // 先给个尺寸：零宽的材质和 stack 的最小宽度约束冲突（第一次 move 前就会排一次版）
    frame.size = CGSize(width: 100, height: Self.height)
    applyGeometry()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 换了工具就重排内容（色点只给有颜色的工具、三档的名字、选项分段），样式变了只改选中状态（色点 pop）
  func update(tool: Annotation.Tool, style: Annotation.Style) {
    if tool != self.tool {
      rebuild(for: tool)
      self.tool = tool
      self.style = nil
    }
    guard style != self.style else { return }
    let animated = self.style != nil
    self.style = style
    for swatch in colors {
      swatch.setChosen(swatch.tag == style.color.rawValue, animated: animated)
    }
    for swatch in weights {
      swatch.setChosen(swatch.tag == style.weight.rawValue, animated: animated)
    }
    for button in options { Self.mark(button, on: button.tag == style.option) }
  }

  private func rebuild(for tool: Annotation.Tool) {
    for view in stack.arrangedSubviews { view.removeFromSuperview() }
    colors =
      tool.hasColor
      ? Annotation.Palette.allCases.map { color in
        let swatch = Swatch(
          fill: color.color, diameter: 14, outlined: true, label: "\(color.title)色")
        swatch.tag = color.rawValue
        swatch.target = self
        swatch.action = #selector(pickColor(_:))
        return swatch
      } : []
    weights = tool.weightTitles.enumerated().map { index, title in
      let swatch = Swatch(
        fill: Style.HUD.text, diameter: [4, 7, 10][index], outlined: false,
        label: title)
      swatch.tag = index
      swatch.target = self
      swatch.action = #selector(pickWeight(_:))
      return swatch
    }
    var views: [NSView] = colors
    if !colors.isEmpty { views.append(barSeparator()) }
    views += weights
    options = tool.optionTitles.enumerated().map { index, title in
      let button = BarButton(title: title, target: self, action: #selector(pickOption(_:)))
      button.isBordered = false
      button.refusesFirstResponder = true
      button.showsHover = false
      button.tag = index
      button.setAccessibilityLabel(title)
      button.layer?.cornerRadius = 5
      Self.mark(button, on: false)
      let width = ceil(button.attributedTitle.size().width) + 16
      button.widthAnchor.constraint(equalToConstant: width).isActive = true
      button.heightAnchor.constraint(equalToConstant: 23).isActive = true
      return button
    }
    if !options.isEmpty {
      let segment = NSStackView(views: options)
      segment.spacing = 0
      segment.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
      segment.wantsLayer = true
      segment.layer?.backgroundColor = Style.HUD.chipFill.cgColor
      segment.layer?.cornerRadius = 7
      segment.layer?.cornerCurve = .continuous
      views += [barSeparator(), segment]
    }
    views.forEach(stack.addArrangedSubview)
    preferredSize = CGSize(
      width: ceil(stack.fittingSize.width + 2 * Self.materialInset), height: Self.height)
  }

  /// 选项分段：选中 HUD 选中底 + 主文字色，其余次文字色
  private static func mark(_ button: NSButton, on: Bool) {
    button.attributedTitle = NSAttributedString(
      string: button.title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
        .foregroundColor: on ? Style.HUD.text : Style.HUD.secondaryText,
      ])
    button.layer?.backgroundColor = on ? Style.HUD.selectedFill.cgColor : nil
  }

  /// 从 anchorX（自身坐标，工具按钮的中线）靠栏那一侧长出来
  func setShown(_ show: Bool, anchorX: CGFloat = 0, growingFrom edge: Edge = .top) {
    setShown(
      show, anchor: CGPoint(x: anchorX, y: edge == .top ? bounds.height : 0),
      rise: edge == .top ? 6 : -6, scale: 0.9, delay: 0.04, bounce: 0.18)
  }

  /// 换工具时位置和宽度 settle 滑过去：模型值直接设成终点，图层从屏幕上现在的样子出发（材质跟着裁，内容已经是新的）。
  /// 取 presentation：同一轮里连改两次（选中标注的工具 → 当前工具）、上一段还没滑完又换工具，都不会先跳到旧终点
  func move(to target: CGRect, animated: Bool) {
    guard target != frame else { return }
    let shown = layer?.presentation()
    let old = CGRect(
      origin: shown?.position ?? frame.origin, size: shown?.bounds.size ?? frame.size)
    let oldShadow = shown?.shadowPath ?? layer?.shadowPath
    frame = target
    applyGeometry()
    layoutSubtreeIfNeeded()
    guard animated, !Style.reduceMotion, let layer, let inner = material.layer else { return }
    let inset = Self.materialInset * 2
    let changes: [(CALayer, String, Any?)] = [
      (layer, "position", NSValue(point: old.origin)),
      (layer, "bounds", NSValue(rect: CGRect(origin: .zero, size: old.size))),
      (layer, "shadowPath", oldShadow),
      (
        inner, "bounds",
        NSValue(rect: CGRect(x: 0, y: 0, width: old.width - inset, height: old.height - inset))
      ),
    ]
    for (owner, key, from) in changes {
      guard let slide = Style.Motion.settle.caAnimation(keyPath: key) as? CABasicAnimation else {
        continue
      }
      slide.fromValue = from
      owner.add(slide, forKey: "settle.\(key)")
    }
  }

  @objc private func pickColor(_ sender: NSButton) {
    onColor(Annotation.Palette(rawValue: sender.tag)!)
  }

  @objc private func pickWeight(_ sender: NSButton) {
    onWeight(Annotation.Weight(rawValue: sender.tag)!)
  }

  @objc private func pickOption(_ sender: NSButton) { onOption(sender.tag) }
}

/// 托盘里的色点 / 粗细点：选中时外圈 2 pt 品牌粉环（离点 2 pt）、整体放大 1.1（pop）。
/// 环用圆角 + 描边的普通图层：自己加的 CAShapeLayer 不继承屏幕的 contentsScale，Retina 上发糊
private final class Swatch: BarButton {
  private let body = CALayer()
  private let ring = CALayer()
  private var chosen = false

  init(fill: NSColor, diameter: CGFloat, outlined: Bool, label: String) {
    super.init(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
    title = ""
    imagePosition = .noImage
    isBordered = false
    refusesFirstResponder = true
    showsHover = false
    toolTip = label
    setAccessibilityLabel(label)
    widthAnchor.constraint(equalToConstant: 26).isActive = true
    heightAnchor.constraint(equalToConstant: 26).isActive = true
    let dot = CALayer()
    dot.frame = CGRect(
      x: 13 - diameter / 2, y: 13 - diameter / 2, width: diameter, height: diameter)
    dot.cornerRadius = diameter / 2
    dot.backgroundColor = fill.cgColor
    if outlined {  // 黑色在深色栏上也看得见
      dot.borderWidth = 0.5
      dot.borderColor = Style.HUD.swatchStroke.cgColor
    }
    let ringSide = diameter + 8
    ring.frame = CGRect(
      x: 13 - ringSide / 2, y: 13 - ringSide / 2, width: ringSide, height: ringSide)
    ring.cornerRadius = ringSide / 2
    ring.borderColor = Style.Shot.accent.cgColor
    ring.borderWidth = 2
    ring.opacity = 0
    body.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
    body.addSublayer(dot)
    body.addSublayer(ring)
    layer?.addSublayer(body)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setChosen(_ on: Bool, animated: Bool) {
    guard on != chosen else { return }
    chosen = on
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let fromScale = body.presentation()?.value(forKeyPath: "transform.scale") ?? 1
    body.transform = on ? CATransform3DMakeScale(1.1, 1.1, 1) : CATransform3DIdentity
    ring.opacity = on ? 1 : 0
    guard animated, !Style.reduceMotion,
      let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
        as? CABasicAnimation
    else { return }
    pop.fromValue = fromScale
    body.add(pop, forKey: "pop")
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = on ? 0 : 1
    fade.duration = Style.fadeIn
    ring.add(fade, forKey: "fade")
  }
}

// MARK: - HUD 菜单

/// 遮罩里的 HUD 弹出菜单：锚点下方 6 pt（放不下放上方），snap 从锚点那侧放大出来；点了一项先收起再执行。
/// 调用方（SelectionView）同时最多开一个，Esc、点外面都先收它。旁白里是一组按钮（label 是组名），勾着的那项值是「已选中」
final class HUDMenu: HUDBar {
  struct Entry {
    let title: String
    var key: String? = nil
    var checked = false
    let action: () -> Void
  }

  var onDismiss: () -> Void = {}
  private static let rowHeight: CGFloat = 28

  init(_ entries: [Entry], label: String) {
    let checks = entries.contains { $0.checked }
    let rows = entries.map { HUDMenuRow($0, checkColumn: checks) }
    let width = max(130, rows.map(\.fittingWidth).max() ?? 0)
    let height = CGFloat(rows.count) * Self.rowHeight + 8
    super.init(radius: Style.Radius.card, height: height)
    frame.size = CGSize(width: width + 8, height: height)
    applyGeometry()
    // 按材质的高排（26 的 effect 是玻璃的 contentView，要等 Auto Layout 跑过才有尺寸；材质的 frame 刚设好）；
    // 四边离栏边 4：15 的材质已内缩 0.5
    let pad = 4 - Self.materialInset
    for (index, row) in rows.enumerated() {
      row.frame = CGRect(
        x: pad, y: material.frame.height - pad - CGFloat(index + 1) * Self.rowHeight,
        width: width, height: Self.rowHeight)
      let action = entries[index].action
      row.onPick = { [weak self] in
        self?.dismiss()
        action()
      }
      effect.addSubview(row)
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(label)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// 行之间的边距不往下漏给遮罩（否则会当成点在外面）
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}

  /// anchor：view 坐标里的锚点矩形（按钮）
  func present(in view: NSView, anchor: CGRect) {
    let size = frame.size
    let area = view.bounds
    let below = anchor.minY - 6 - size.height >= area.minY + 6
    frame.origin = CGPoint(
      x: max(area.minX + 6, min(anchor.minX, area.maxX - size.width - 6)),
      y: below ? anchor.minY - 6 - size.height : anchor.maxY + 6)
    view.addSubview(self)
    setShown(
      true,
      anchor: CGPoint(
        x: min(max(anchor.midX - frame.minX, 0), size.width), y: below ? size.height : 0),
      rise: 0, scale: 0.94, curve: .snap)
  }

  func dismiss() {
    guard superview != nil else { return }
    removeFromSuperview()
    onDismiss()
  }
}

/// 菜单的一行：高 28、圆角 6 的悬停底；左边可选的粉色 ✓，右边键帽
private final class HUDMenuRow: NSView {
  var onPick: () -> Void = {}
  let fittingWidth: CGFloat
  private let entry: HUDMenu.Entry
  private let checkColumn: Bool
  private let title: NSAttributedString
  private let key: NSAttributedString?
  private var hovering = false {
    didSet { if hovering != oldValue { needsDisplay = true } }
  }

  init(_ entry: HUDMenu.Entry, checkColumn: Bool) {
    self.entry = entry
    self.checkColumn = checkColumn
    title = NSAttributedString(
      string: entry.title,
      attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Style.HUD.text])
    key = entry.key.map {
      NSAttributedString(
        string: $0,
        attributes: [
          .font: NSFont.systemFont(ofSize: 11, weight: .medium),
          .foregroundColor: Style.HUD.secondaryText,
        ])
    }
    fittingWidth =
      ceil(
        9 + (checkColumn ? 14 : 0) + title.size().width
          + (key.map { 18 + $0.size().width + 10 } ?? 0) + 9)
    super.init(frame: .zero)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(entry.title)
    setAccessibilityHelp(entry.key)
    setAccessibilityValue(entry.checked ? "已选中" : nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPick()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    if hovering {
      Style.HUD.hoverFill.setFill()
      NSBezierPath(
        roundedRect: bounds, xRadius: Style.Radius.control, yRadius: Style.Radius.control
      ).fill()
    }
    var x: CGFloat = 9
    if checkColumn {
      if entry.checked {
        let check = NSAttributedString(
          string: "✓",
          attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Style.Shot.accent,
          ])
        check.draw(at: CGPoint(x: x, y: (bounds.height - check.size().height) / 2))
      }
      x += 14
    }
    title.draw(at: CGPoint(x: x, y: (bounds.height - title.size().height) / 2))
    guard let key else { return }
    let size = key.size()
    let cap = CGRect(
      x: bounds.maxX - 9 - size.width - 10, y: (bounds.height - 18) / 2, width: size.width + 10,
      height: 18)
    Style.HUD.chipFill.setFill()
    NSBezierPath(roundedRect: cap, xRadius: Style.Radius.mini, yRadius: Style.Radius.mini).fill()
    key.draw(at: CGPoint(x: cap.minX + 5, y: cap.midY - size.height / 2))
  }
}

// MARK: - 按钮

extension NSView {
  /// 栏里的图标按钮（截图工具栏、长截图面板、钉图圆钮共用）：SF Symbols 分层 15 pt medium、HUD 主文字色
  func barButton(
    _ image: NSImage, tip: String, label: String? = nil, action: Selector,
    size: CGSize = CGSize(width: 30, height: 28)
  ) -> BarButton {
    let button = BarButton(image: image, target: self, action: action)
    button.toolTip = tip
    button.setAccessibilityLabel(label ?? tip)
    button.isBordered = false
    button.refusesFirstResponder = true
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
      .applying(.preferringHierarchical())
    button.contentTintColor = Style.HUD.text
    button.widthAnchor.constraint(equalToConstant: size.width).isActive = true
    button.heightAnchor.constraint(equalToConstant: size.height).isActive = true
    return button
  }

  /// 分组分隔线 1 × 18 white 0.14，两边各留 4 pt（HUD 永远深色）
  func barSeparator() -> NSView {
    let separator = NSView()
    separator.wantsLayer = true
    let line = CALayer()
    line.backgroundColor = Style.HUD.separator.cgColor
    line.frame = CGRect(x: 4, y: 0, width: 1, height: 18)
    separator.layer?.addSublayer(line)
    separator.widthAnchor.constraint(equalToConstant: 9).isActive = true
    separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
    return separator
  }
}

/// 栏里的按钮：遮罩不是 key 的那块屏上也一点就响应；悬停出 control 圆角的 white 0.10 底（0.10 s 淡入），
/// 按下缩到 0.90，禁用 0.35
class BarButton: NSButton {
  /// 主按钮、当前工具、色点不出悬停底
  var showsHover = true {
    didSet { if !showsHover { setHover(false) } }
  }
  private var hovering = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Style.Radius.control
    layer?.cornerCurve = .continuous
    (cell as? NSButtonCell)?.imageDimsWhenDisabled = false  // 禁用时整体 0.35，不再叠系统的变灰
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isEnabled: Bool {
    didSet {
      alphaValue = isEnabled ? 1 : 0.35
      if !isEnabled { setHover(false) }
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// 符号图自带的对齐内缩会把按钮的 frame 撑得比 32 × 32 大（悬停底、粉色底块跟着歪）：frame 就是布局尺寸，图照样居中
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
  override func mouseEntered(with event: NSEvent) { setHover(true) }
  override func mouseExited(with event: NSEvent) { setHover(false) }

  override func viewDidHide() {
    super.viewDidHide()
    setHover(false)
  }

  override func mouseDown(with event: NSEvent) {
    if isEnabled { press(true) }  // 禁用的不缩；松手照样复位（点完撤销可能刚好变成禁用）
    super.mouseDown(with: event)  // 按钮自己的跟踪循环，松手才返回
    press(false)
  }

  private func setHover(_ on: Bool) {
    let on = on && showsHover && isEnabled
    guard on != hovering, let layer else { return }
    hovering = on
    let fade = CABasicAnimation(keyPath: "backgroundColor")
    fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
    fade.duration = 0.10
    layer.backgroundColor = (on ? Style.HUD.hoverFill : .clear).cgColor
    layer.add(fade, forKey: "hover")
  }

  /// 围绕中心缩放：只加动画不改模型值（按钮的几何归 AppKit 管）
  private func press(_ down: Bool) {
    guard let layer, !Style.reduceMotion else { return }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    var target = CATransform3DIdentity
    if down {
      target = CATransform3DMakeTranslation(-center.x, -center.y, 0)
      target = CATransform3DConcat(target, CATransform3DMakeScale(0.9, 0.9, 1))
      target = CATransform3DConcat(target, CATransform3DMakeTranslation(center.x, center.y, 0))
    }
    let animation = CABasicAnimation(keyPath: "transform")
    animation.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
    animation.toValue = NSValue(caTransform3D: target)
    animation.duration = 0.12
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    animation.fillMode = .forwards
    animation.isRemovedOnCompletion = false
    layer.add(animation, forKey: "press")
  }
}
