// 钉图：把截图钉在原位置当参考。不激活本 App、出现时不抢键盘（修旧版钉图抢焦点，§11 #48）；
// 拖动移动，滚轮 / 双指捏合以鼠标为锚点缩放，双击或 Esc 关闭（Esc、按键要先点一下钉图）。
// 按键和截图出图一致（体检 C9 D17）：⌘C 拷贝、O 识字并拷贝、⌘S 存储到快速保存的文件夹、⇧⌘S 另存为…、⌘0 原始大小、⌘W 关闭；
// 右键菜单：拷贝 / 识字并拷贝 / 翻译 / 存储到「桌面」/ 另存为… ｜ 透明度 / 原始大小 ｜ 关闭，VoiceOver 的自定义动作同一份（B45）。
// 长截图时和选区相交的钉图让开（B40：不接鼠标、淡到 0.3，滚轮和自动滚动落到下面的窗口）。菜单栏可隐藏 / 显示、关闭全部。
// Whisker（mac-whisker §6 钉图）：圆角 10 + 系统阴影；钉上时窗口 1.04 → 1 弹簧回弹（超过半屏的只淡入）；悬停 0.3 s 后右上角淡入透明度 / 关闭两个
// 22 pt HUD 圆钮；缩放时中央 HUD 显示百分比、停手 0.7 s 淡出；关闭时缩到 0.92 并淡出 0.16 s。
// 不做点击穿透（穿透要全局抢一个热键才能再点回来）、不做钉图历史；钉图会出现在之后的截图里。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@Observable final class PinBoard {
  private(set) var panels: [PinPanel] = []
  private(set) var isHidden = false
  /// 拷贝 / 快速保存 / 另存为 / 识字并拷贝 / 翻译（动作、图、像素 / 点；.pin 不会来），由 AppDelegate 接到截图的输出上
  @ObservationIgnored var output: @MainActor (RegionSelector.Action, CGImage, CGFloat) -> Void = {
    _, _, _ in
  }

  /// frame：截图时选区的位置（点，全局坐标）。钉图不抢键盘、VoiceOver 的焦点不在它上面：主动播报
  func pin(_ image: CGImage, frame: CGRect) {
    if isHidden { toggleHidden() }
    let panel = PinPanel(image: image, frame: frame, board: self)
    panels.append(panel)
    panel.popIn()
    Island.announce("已钉到屏幕")
  }

  /// 长截图开始（体检 B40）：和选区相交的钉图让开——不接鼠标（滚轮、自动滚动的合成滚轮落到下面的窗口，不再缩放钉图）、
  /// 淡到 0.3（还看得见）。长截图滤掉了本 App，长图里本来就没有钉图
  func suspend(covering region: CGRect) {
    for panel in panels where panel.frame.intersects(region) { panel.suspend() }
  }

  /// 长截图结束（拷贝、存储、取消、出错都走这里）：放回原来的透明度、重新接鼠标
  func resume() {
    for panel in panels { panel.resume() }
  }

  func close(_ panel: PinPanel) {
    panels.removeAll { $0 === panel }
    if panels.isEmpty { isHidden = false }
    panel.fadeOut()
  }

  func closeAll() {
    for panel in panels { panel.fadeOut() }
    panels = []
    isHidden = false
  }

  func toggleHidden() {
    isHidden.toggle()
    for panel in panels {
      if isHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
  }
}

/// 一张钉图。无边框窗口默认当不了 key（收不到 Esc / ⌘C），所以要子类化
final class PinPanel: NSPanel {
  init(image: CGImage, frame: CGRect, board: PinBoard) {
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    // 透明窗口 + 圆角内容：系统阴影按内容形状算（改尺寸后 invalidateShadow）
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .none
    let view = PinView(image: image, size: frame.size, board: board)
    contentView = view
    initialFirstResponder = view
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// 用户选的透明度（右键菜单 / 圆钮）：长截图让开时窗口临时淡到 0.3，结束后回到它
  var opacity: CGFloat = 1 {
    didSet { if !isSuspended { alphaValue = opacity } }
  }
  /// 长截图期间让开着（B40）
  private(set) var isSuspended = false

  func suspend() {
    guard !isSuspended else { return }
    finishPopIn()
    isSuspended = true
    ignoresMouseEvents = true
    alphaValue = min(opacity, 0.3)
  }

  func resume() {
    guard isSuspended else { return }
    isSuspended = false
    ignoresMouseEvents = false
    alphaValue = opacity
  }

  /// 钉上的回弹：终点（原位）、开始时间、逐帧驱动
  private var popping: (target: NSRect, began: CFTimeInterval)?
  private var popLink: CADisplayLink?
  /// 规则写的是 spring(0.35, 0.3)，§4 规定 bounce ≤ 0.25，按 pop 的上限取 0.25
  private static let popSpring = Spring(duration: 0.35, bounce: 0.25)

  /// 钉上：窗口从 1.04 倍（以中心为准）弹簧回到原位，同时 0.12 s 淡入。窗口帧动画只支持贝塞尔、实测冲不过头
  /// 也不认时长（同 OverlayPanel.squeezeIn），所以跟着显示器刷新逐帧按 SwiftUI Spring 算帧；不给内容图层放大
  /// （会被窗口边裁掉圆角）。减弱动态效果时只淡入；超过半屏的钉图也只淡入：几乎整屏的透明窗口逐帧改尺寸，窗口服务器
  /// 每帧都要重新分配几十 MB 的缓冲、按透明度重算阴影（ponytail: 大钉图没有回弹，要的话改成窗口定在 1.04 倍、只缩内容图层）
  func popIn() {
    let target = frame
    alphaValue = 0
    orderFrontRegardless()
    let reduced = Style.reduceMotion
    NSAnimationContext.runAnimationGroup { context in
      // 减弱动态效果时 pop 退成 0.2 s easeInOut 淡入（§7）
      context.duration = reduced ? 0.2 : Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: reduced ? .easeInEaseOut : .easeOut)
      animator().alphaValue = opacity
    }
    let area = (self.screen ?? NSScreen.main)?.frame.size ?? .zero
    guard !reduced, target.width * target.height <= area.width * area.height / 2,
      let link = contentView?.displayLink(target: self, selector: #selector(stepPop))
    else { return }
    popping = (target, CACurrentMediaTime())
    setFrame(Self.scaled(target, by: 1.04), display: true)
    link.add(to: .main, forMode: .common)
    popLink = link
  }

  @objc private func stepPop(_ link: CADisplayLink) {
    guard let popping else { return finishPopIn() }
    let time = CACurrentMediaTime() - popping.began
    guard time < Self.popSpring.settlingDuration(target: 1.0, epsilon: 0.002) else {
      return finishPopIn()
    }
    let progress = Self.popSpring.value(target: 1.0, time: time)
    setFrame(Self.scaled(popping.target, by: 1.04 - 0.04 * progress), display: true)
  }

  /// 回弹停在原位：放完、用户开始拖动 / 缩放、关闭时都走这里（不然下一帧又把窗口按回去）
  func finishPopIn() {
    popLink?.invalidate()
    popLink = nil
    guard let target = popping?.target else { return }
    popping = nil
    setFrame(target, display: true)
    invalidateShadow()
  }

  /// 以中心为准缩放
  private static func scaled(_ rect: NSRect, by scale: CGFloat) -> NSRect {
    rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
  }

  /// 关闭：内容缩到 0.92（以中心为准）并淡出 0.16 s，完了再收窗口
  func fadeOut() {
    finishPopIn()
    if !Style.reduceMotion, let layer = contentView?.layer {
      let size = layer.bounds.size
      let shrink = CABasicAnimation(keyPath: "transform")
      shrink.fromValue = CATransform3DIdentity
      shrink.toValue = CATransform3DConcat(
        CATransform3DConcat(
          CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
          CATransform3DMakeScale(0.92, 0.92, 1)),
        CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
      shrink.duration = 0.16
      shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
      shrink.fillMode = .forwards
      shrink.isRemovedOnCompletion = false
      layer.add(shrink, forKey: "close")
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated { self?.orderOut(nil) }
    }
  }

  /// 截图可能盖到菜单栏：原位置出现，别被挪下来
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

private final class PinView: NSView {
  let image: CGImage
  /// 钉上时的大小（点）：缩放的基准
  private let originalSize: CGSize
  private unowned let board: PinBoard

  /// 悬停后右上角的两个圆钮（透明度、关闭）
  private let controls = NSStackView()
  /// 缩放时中央的百分比
  private let zoomHUD = HUDBar(radius: Style.Radius.control, height: 26)
  private let zoomLabel = NSTextField(labelWithString: "")
  private var hovering = false
  /// 每次缩放加一；停手 0.7 s 后只有最后一次负责收起百分比
  private var zoomGeneration = 0

  init(image: CGImage, size: CGSize, board: PinBoard) {
    self.image = image
    originalSize = size
    self.board = board
    super.init(frame: CGRect(origin: .zero, size: size))
    wantsLayer = true
    let opacity = circle(
      barButton(
        NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "透明度")!,
        tip: "透明度", action: #selector(cycleOpacity), size: CGSize(width: 21, height: 21)))
    let close = circle(
      barButton(
        NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")!, tip: "关闭",
        action: #selector(close), size: CGSize(width: 21, height: 21)))
    controls.spacing = 6
    controls.setViews([opacity, close], in: .trailing)
    controls.frame.size = controls.fittingSize
    controls.autoresizingMask = [.minXMargin, .minYMargin]
    controls.alphaValue = 0
    controls.isHidden = true  // 看不见时也不能点到（点击不看透明度）
    addSubview(controls)
    zoomLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    zoomLabel.textColor = Style.HUD.text
    zoomHUD.stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    zoomHUD.install([zoomLabel])
    zoomHUD.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    zoomHUD.isHidden = true
    addSubview(zoomHUD)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  /// 22 pt HUD 圆钮（按钮 21：HUDBar 的材质内缩 0.5）
  private func circle(_ button: NSButton) -> HUDBar {
    button.symbolConfiguration = .init(pointSize: 10, weight: .bold)
    button.contentTintColor = Style.HUD.text
    let bar = HUDBar(radius: 11, height: 22)
    bar.stack.edgeInsets = NSEdgeInsets()
    bar.install([button])
    bar.widthAnchor.constraint(equalToConstant: 22).isActive = true
    bar.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return bar
  }

  override func layout() {
    super.layout()
    controls.frame.origin = CGPoint(
      x: bounds.maxX - controls.frame.width - 6, y: bounds.maxY - controls.frame.height - 6)
    zoomHUD.frame.origin = CGPoint(
      x: (bounds.width - zoomHUD.frame.width) / 2, y: (bounds.height - zoomHUD.frame.height) / 2)
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(0.3))
      guard let self, self.hovering else { return }
      // 钉图太小时不放按钮（会盖住图）
      guard self.bounds.width >= 64, self.bounds.height >= 34 else { return }
      self.controls.isHidden = false
      self.fade(self.controls, in: true)
    }
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    fade(controls, in: false)
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Style.fadeOut))
      guard let self, !self.hovering else { return }
      self.controls.isHidden = true
    }
  }

  private func fade(_ view: NSView, in show: Bool) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = show ? Style.fadeIn : Style.fadeOut
      view.animator().alphaValue = show ? 1 : 0
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.contents = image
    layer?.cornerRadius = Style.Radius.card
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor.separatorColor.cgColor
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var panel: PinPanel? { window as? PinPanel }
  private var scale: CGFloat { CGFloat(image.width) / originalSize.width }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { return close() }
    panel?.finishPopIn()
    window?.makeKey()  // 点过之后 Esc、⌘C 才归它
    window?.performDrag(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    // 触控板给的是像素级增量，滚轮给的是行
    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
    zoom(by: exp(delta * 0.01))
  }

  override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification) }

  /// 以鼠标为锚点缩放，保持宽高比：最小到原大的 10%、且宽高都不小于 24 点（原图本来更小就是原大），最大 5 倍
  private func zoom(by factor: CGFloat) {
    guard let window, factor.isFinite, factor > 0 else { return }
    panel?.finishPopIn()
    let frame = window.frame
    let minimum = max(min(1, max(0.1, 24 / originalSize.width)), min(1, 24 / originalSize.height))
    let scale = min(max(frame.width / originalSize.width * factor, minimum), 5)
    let ratio = originalSize.width * scale / frame.width
    let anchor = NSEvent.mouseLocation
    window.setFrame(
      CGRect(
        x: anchor.x - (anchor.x - frame.minX) * ratio,
        y: anchor.y - (anchor.y - frame.minY) * ratio,
        width: originalSize.width * scale, height: originalSize.height * scale), display: true)
    window.invalidateShadow()
    showZoom(scale)
  }

  /// 中央 HUD 显示当前倍数，停手 0.7 s 后淡出
  private func showZoom(_ scale: CGFloat) {
    zoomLabel.stringValue = "\(Int((scale * 100).rounded()))%"
    zoomHUD.fit()
    needsLayout = true
    zoomHUD.isHidden = false
    zoomHUD.alphaValue = 1
    zoomGeneration += 1
    let generation = zoomGeneration
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(0.7))
      guard let self, self.zoomGeneration == generation else { return }
      self.fade(self.zoomHUD, in: false)
    }
  }

  override func keyDown(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Escape { return close() }
    if !perform(event) { super.keyDown(with: event) }
  }

  /// 钉图是 key 时 ⌘ 组合键先到这里（体检 C9：⌘S 快速保存、⇧⌘S 另存为，同截图出图）
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.isKeyWindow == true, perform(event) else {
      return super.performKeyEquivalent(with: event)
    }
    return true
  }

  /// 按键和右键菜单、VoiceOver 动作查同一张 commands 表（单测经 keyDown 锁住）：修饰键只比 ⌘⌃⌥⇧、不看大写锁定；
  /// 按住不放不反复执行（O 不反复识别、⌘S 不连存几张）
  private func perform(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard
      let command = commands.first(where: {
        $0.keyCode == Int(event.keyCode) && $0.modifiers == flags
      })
    else { return false }
    if !event.isARepeat { NSApp.sendAction(command.action, to: self, from: nil) }
    return true
  }

  /// 一条命令：按键、右键菜单和 VoiceOver 自定义动作共用（透明度只在菜单里）
  private struct Command {
    let title: String
    /// 菜单上显示的键；keyCode 是实际认的物理键（nil = 没有按键）
    let key: String
    let keyCode: Int?
    let modifiers: NSEvent.ModifierFlags
    let action: Selector
  }

  /// 拷贝 / 识字并拷贝 / 翻译 / 存储到「桌面」/ 另存为… / 原始大小 / 关闭（体检 B41 C9 D17：截图家族同名同键）
  private var commands: [Command] {
    [
      Command(
        title: "拷贝", key: "c", keyCode: kVK_ANSI_C, modifiers: .command,
        action: #selector(copyImage)),
      Command(
        title: "识字并拷贝", key: "o", keyCode: kVK_ANSI_O, modifiers: [],
        action: #selector(recognizeText)),
      Command(
        title: "翻译", key: "", keyCode: nil, modifiers: [], action: #selector(translateImage)),
      Command(
        title: ScreenshotOutput.saveTitle, key: "s", keyCode: kVK_ANSI_S, modifiers: .command,
        action: #selector(saveImage)),
      Command(
        title: "另存为…", key: "s", keyCode: kVK_ANSI_S, modifiers: [.command, .shift],
        action: #selector(saveImageAs)),
      Command(
        title: "原始大小", key: "0", keyCode: kVK_ANSI_0, modifiers: .command,
        action: #selector(actualSize)),
      Command(
        title: "关闭", key: "w", keyCode: kVK_ANSI_W, modifiers: .command, action: #selector(close)),
    ]
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    let items = commands.map { command in
      let item = NSMenuItem(
        title: command.title, action: command.action, keyEquivalent: command.key)
      item.keyEquivalentModifierMask = command.modifiers
      item.target = self
      return item
    }
    items[0..<5].forEach(menu.addItem)
    menu.addItem(.separator())
    let opacity = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
    let levels = NSMenu()
    for percent in [100, 80, 60, 40] {
      let level = NSMenuItem(
        title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
      level.target = self
      level.tag = percent
      level.state = Int(((panel?.opacity ?? 1) * 100).rounded()) == percent ? .on : .off
      levels.addItem(level)
    }
    opacity.submenu = levels
    menu.addItem(opacity)
    menu.addItem(items[5])
    menu.addItem(.separator())
    menu.addItem(items[6])
    return menu
  }

  // MARK: 无障碍（mac-whisker §7，体检 B45）：钉图平时没有看得见的按钮，整张图是一个元素，操作都在自定义动作里

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .image }
  override func accessibilityLabel() -> String? { "钉图" }

  override func accessibilityValue() -> Any? {
    let size = window?.frame.size ?? bounds.size
    let percent = Int(((panel?.opacity ?? 1) * 100).rounded())
    return "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) 点，透明度 \(percent)%"
  }

  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    commands.map { command in
      let action = command.action
      return NSAccessibilityCustomAction(name: command.title) { [weak self] in
        MainActor.assumeIsolated { NSApp.sendAction(action, to: self, from: nil) }
      }
    }
  }

  @objc private func copyImage() { board.output(.copy, image, scale) }
  @objc private func saveImage() { board.output(.save, image, scale) }
  @objc private func saveImageAs() { board.output(.saveAs, image, scale) }
  @objc private func recognizeText() { board.output(.recognize, image, scale) }
  @objc private func translateImage() { board.output(.translate, image, scale) }
  @objc private func setOpacity(_ sender: NSMenuItem) {
    panel?.opacity = CGFloat(sender.tag) / 100
  }

  /// 圆钮：100 → 80 → 60 → 40 → 100%
  @objc private func cycleOpacity() {
    guard let panel else { return }
    let current = Int((panel.opacity * 100).rounded())
    panel.opacity = CGFloat(current <= 40 ? 100 : current - 20) / 100
  }

  /// 回到钉上时的大小，左上角不动
  @objc private func actualSize() {
    guard let window else { return }
    panel?.finishPopIn()
    let frame = window.frame
    window.setFrame(
      CGRect(
        x: frame.minX, y: frame.maxY - originalSize.height, width: originalSize.width,
        height: originalSize.height), display: true)
    window.invalidateShadow()
    showZoom(1)
  }

  @objc private func close() {
    if let panel { board.close(panel) }
  }
}
