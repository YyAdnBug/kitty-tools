// 钉图：把截图钉在原位置当参考。不激活本 App、出现时不抢键盘（修旧版钉图抢焦点，§11 #48）；
// 拖动移动，滚轮 / 双指捏合以鼠标为锚点缩放，双击或 Esc 关闭（Esc、⌘C 要先点一下钉图），
// 右键菜单：复制、存储为…、透明度、原始大小、关闭。菜单栏可隐藏 / 显示、关闭全部。
// 不做点击穿透（旧版穿透时全局抢 ⇧⌘P）、不做钉图历史；钉图会出现在之后的截图里。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class PinBoard {
  private(set) var panels: [PinPanel] = []
  private(set) var isHidden = false
  /// 复制 / 另存为（图、像素 / 点），由 AppDelegate 接到截图的输出上
  @ObservationIgnored var copy: @MainActor (CGImage, CGFloat) -> Void = { _, _ in }
  @ObservationIgnored var saveAs: @MainActor (CGImage, CGFloat) -> Void = { _, _ in }

  /// 冻结帧里要留下的钉图窗口
  var windowNumbers: Set<CGWindowID> { Set(panels.map { CGWindowID($0.windowNumber) }) }

  /// frame：截图时选区的位置（点，全局坐标）
  func pin(_ image: CGImage, frame: CGRect) {
    if isHidden { toggleHidden() }
    let panel = PinPanel(image: image, frame: frame, board: self)
    panels.append(panel)
    panel.orderFrontRegardless()
  }

  func close(_ panel: PinPanel) {
    panel.orderOut(nil)
    panels.removeAll { $0 === panel }
    if panels.isEmpty { isHidden = false }
  }

  func closeAll() {
    for panel in panels { panel.orderOut(nil) }
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
    hasShadow = true
    animationBehavior = .none
    let view = PinView(image: image, size: frame.size, board: board)
    contentView = view
    initialFirstResponder = view
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

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

  init(image: CGImage, size: CGSize, board: PinBoard) {
    self.image = image
    originalSize = size
    self.board = board
    super.init(frame: CGRect(origin: .zero, size: size))
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.contents = image
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var panel: PinPanel? { window as? PinPanel }
  private var scale: CGFloat { CGFloat(image.width) / originalSize.width }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { return close() }
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
  }

  override func keyDown(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Escape { close() } else { super.keyDown(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.isKeyWindow == true,
      event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    else { return super.performKeyEquivalent(with: event) }
    switch Int(event.keyCode) {
    case kVK_ANSI_C: copyImage()
    case kVK_ANSI_S: saveImage()
    case kVK_ANSI_W: close()
    case kVK_ANSI_0: actualSize()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.addItem(item("复制", #selector(copyImage), "c"))
    menu.addItem(item("存储为…", #selector(saveImage), "s"))
    menu.addItem(.separator())
    let opacity = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
    let levels = NSMenu()
    for percent in [100, 80, 60, 40] {
      let level = item("\(percent)%", #selector(setOpacity(_:)))
      level.tag = percent
      level.state = Int(((window?.alphaValue ?? 1) * 100).rounded()) == percent ? .on : .off
      levels.addItem(level)
    }
    opacity.submenu = levels
    menu.addItem(opacity)
    menu.addItem(item("原始大小", #selector(actualSize), "0"))
    menu.addItem(.separator())
    menu.addItem(item("关闭", #selector(close)))
    return menu
  }

  private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  @objc private func copyImage() { board.copy(image, scale) }
  @objc private func saveImage() { board.saveAs(image, scale) }
  @objc private func setOpacity(_ sender: NSMenuItem) {
    window?.alphaValue = CGFloat(sender.tag) / 100
  }

  /// 回到钉上时的大小，左上角不动
  @objc private func actualSize() {
    guard let window else { return }
    let frame = window.frame
    window.setFrame(
      CGRect(
        x: frame.minX, y: frame.maxY - originalSize.height, width: originalSize.width,
        height: originalSize.height), display: true)
  }

  @objc private func close() {
    if let panel { board.close(panel) }
  }
}
