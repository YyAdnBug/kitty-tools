// 不激活前台的浮层（NSPanel）：剪贴板面板、翻译浮窗、启动器共用这一个类，各建一个实例（PLAN §4）。
// 显示只 orderFrontRegardless + makeKey，永远不调 NSApp.activate：前台 App 保持不变，
// 粘贴时发的 ⌘V、划词时发的 ⌘C 才会落到它身上。
// 外观是 Whisker 的 Panel 皮肤（mac-whisker §2）：无边框、16 pt 连续圆角（maskImage 裁，系统阴影跟着走）+ 描边；
// 出现时淡入 + 内容下落 6 pt，用户关掉时系统淡出（窗口逻辑上立刻移走，键盘马上回到原 App），高度可带动画伸缩。
// ⌘Y 放大预览用 zoom / unzoom：从检查器卡片的位置长出来、缩回去。启动器可选「挤压入场」（实验，squeezesIn）。
// 翻译浮窗（frameName）：present 带 anchor 时出现在光标右下 12 pt（放不下翻到另一侧，体检 A13），不带时回到用户上次拖到的
// 位置（userFrame；所在屏不是鼠标所在屏时换算到鼠标所在屏同一相对位置）；只有用户拖过、拖宽过才记下新位置。

import AppKit
import Carbon.HIToolbox
import SwiftUI

final class OverlayPanel: NSPanel {
  /// 自动收起的时机。固定（isPinned）只管这一条「点别处不收起」；Esc、⌘W、再按热键一律收起（mac-overlay-panel §2）
  enum AutoHide {
    /// 点本 App 浮层以外的地方就关（剪贴板面板、启动器）
    case clickOutside
    /// 失去 key 就关（翻译浮窗）
    case resignKey
  }

  var onHide: (() -> Void)?
  /// 这次显示前处于 key 的自家浮层：收起时把 key 还给它（翻译浮窗用）
  private(set) weak var previousKeyPanel: OverlayPanel?
  /// ⌘ 组合键先给它处理，返回 true 表示已处理
  var keyEquivalentHandler: ((NSEvent) -> Bool)?
  private let autoHide: AutoHide
  private let isPinned: () -> Bool
  /// 记位置用的名字（翻译浮窗）：nil 时每次都居中到鼠标所在屏
  private let frameName: String?
  /// 这次显示时摆好的左上角和宽度：收起时和它不同 = 用户拖过 / 拖宽过，才记下来（跟随鼠标摆的位置不算「上次位置」）
  private var placed: (topLeft: NSPoint, width: CGFloat)?
  /// 用户上次拖到的左上角和宽度（启动时从 frameName 读回）：不带锚点出现时回到这里，不用内存里上次弹出的位置
  private var userFrame: (topLeft: NSPoint, width: CGFloat)?
  /// 下一次出现时的锚点（present 传进来的鼠标位置）
  private var anchor: NSPoint?
  /// 启动器：每次都放在鼠标所在屏、顶边在可见区 20% 处，高度随内容往下伸缩
  private let topAnchored: Bool
  private var mouseMonitors: [Any] = []
  /// SwiftUI 内容：入场时它下落，材质本身不动
  private let host: NSView
  /// 上次系统淡出的时刻：淡出的快照窗口还在时又被呼出，就不再淡入（不然旧内容叠在新内容上）
  private var lastDismiss: CFTimeInterval = 0
  /// 用户正在拖左右边改宽度：这期间改高度不做动画（动画结束会盖掉拖动设的帧）
  fileprivate var isUserResizing = false
  /// 每次出现 / 收起加一：缩回动画的收尾发现期间又被打开（或已被别处收起）就什么都不做
  private var showGeneration = 0
  /// 出现时用挤压入场（启动器的实验开关）；false 用标准的淡入 + 下落
  var squeezesIn: () -> Bool = { false }
  /// 正在挤压入场：起止帧、开始时刻、逐帧驱动的显示器刷新
  private var squeeze: (start: NSRect, end: NSRect, began: CFTimeInterval)?
  private var squeezeLink: CADisplayLink?

  /// - Parameters:
  ///   - minSize: 传了就允许拖左右边改宽度（无边框窗口没有系统的拖边，用两条 ResizeEdge）
  ///   - frameName: 传了就记住用户拖到的位置和宽度（首次居中），present 可带锚点跟随鼠标；不传则每次显示都居中到鼠标所在屏幕
  ///   - topAnchored: 放在屏幕上部（启动器），配合 setContentHeight 伸缩
  init<Content: View>(
    size: NSSize, minSize: NSSize? = nil, frameName: String? = nil, topAnchored: Bool = false,
    autoHide: AutoHide, isPinned: @escaping () -> Bool, content: Content
  ) {
    self.autoHide = autoHide
    self.isPinned = isPinned
    self.frameName = frameName
    self.topAnchored = topAnchored
    let hosting = NSHostingView(rootView: PanelRoot(content: content))
    hosting.sizingOptions = []  // 窗口大小由这里定，不让 SwiftUI 的理想尺寸反推窗口
    hosting.wantsLayer = true
    host = hosting
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isMovableByWindowBackground = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .none
    if let minSize { contentMinSize = minSize }
    // 系统毛玻璃底：state 必须 .active，本 App 从不激活，跟随窗口状态会一直是灰的非激活外观
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.maskImage = Self.cornerMask(radius: Style.Radius.panel)
    hosting.frame = background.bounds
    hosting.autoresizingMask = [.width, .height]
    background.addSubview(hosting)
    if minSize != nil {
      for edge in [ResizeEdge.Side.left, .right] { background.addSubview(ResizeEdge(side: edge)) }
    }
    contentView = background
    // 不用 setFrameAutosaveName：它连跟随鼠标摆的位置也记，「上次位置」就成了上次弹出的地方
    if let frameName {
      if setFrameUsingName(frameName) {
        userFrame = (NSPoint(x: frame.minX, y: frame.maxY), frame.width)
      } else {
        center()
      }
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// makingKey = false：只露出来、不抢键盘（复制即译），此时靠点外关闭。
  /// anchor：新出现时放在这一点（鼠标位置）的右下 12 pt（翻译浮窗「跟随鼠标」）；已经开着就不挪。
  /// keepsPlace：原地重新露出来（划词翻译并替换期间临时 orderOut 的固定浮窗），不重新摆
  func present(makingKey: Bool = true, anchor: NSPoint? = nil, keepsPlace: Bool = false) {
    let appearing = !isVisible
    // 系统淡出约 0.13 s，期间快照窗口还在：直接不透明盖住它
    let fades = appearing && CACurrentMediaTime() - lastDismiss > 0.15
    if appearing {
      // 直接 orderOut 收起的（划词时浮窗是 key）没经过 hide / dismiss：这里补记用户拖过的位置
      saveFrameIfMoved()
      self.anchor = anchor
      if !keepsPlace { placeForShow() }
      animationBehavior = .none
      alphaValue = fades ? 0 : 1
    }
    orderFrontRegardless()
    if makingKey {
      // 每次都重新记：key 不是别的自家浮层时清掉旧值，免得收起时把 key 还给早就不相干的面板
      let current = NSApp.keyWindow as? OverlayPanel
      if current !== self { previousKeyPanel = current }
      makeKey()
      // 首次显示时 SwiftUI 还没建出输入框，先把布局跑完再聚焦
      contentView?.layoutSubtreeIfNeeded()
      if let field = initialFirstResponder { makeFirstResponder(field) }
    }
    if autoHide == .clickOutside || !makingKey, mouseMonitors.isEmpty { installMouseMonitors() }
    if fades {
      if squeezesIn() && !Style.reduceMotion { squeezeIn() } else { animateIn() }
    }
  }

  /// 挤压入场（实验，像 macOS 26 的 Spotlight）：窗口从窄一成、矮四分之一（顶边不动、左右居中）弹开到原尺寸，
  /// 冲过头一点再回来（island 曲线 0.42 s / bounce 0.22）。动的是窗口本身（毛玻璃、阴影由窗口服务器按真实大小画）；
  /// 窗口帧动画只支持贝塞尔，实测冲不过头（还会忽略时长），所以跟着显示器刷新逐帧按 SwiftUI 的 Spring 算帧
  private func squeezeIn() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
    let end = frame
    let size = NSSize(width: end.width * 0.9, height: end.height * 0.75)
    let start = NSRect(
      x: end.midX - size.width / 2, y: end.maxY - size.height, width: size.width,
      height: size.height)
    squeeze = (start, end, CACurrentMediaTime())
    setFrame(start, display: false)
    guard let link = contentView?.displayLink(target: self, selector: #selector(stepSqueeze))
    else { return endSqueeze() }
    link.add(to: .main, forMode: .common)
    squeezeLink = link
  }

  @objc private func stepSqueeze(_ link: CADisplayLink) {
    guard let squeeze else { return endSqueeze() }
    let spring = Spring(duration: 0.42, bounce: 0.22)
    let time = CACurrentMediaTime() - squeeze.began
    guard time < spring.settlingDuration(target: 1.0, epsilon: 0.002) else { return endSqueeze() }
    let progress = spring.value(target: 1.0, time: time)
    let (a, b) = (squeeze.start, squeeze.end)
    setFrame(
      NSRect(
        x: a.minX + (b.minX - a.minX) * progress, y: a.minY + (b.minY - a.minY) * progress,
        width: a.width + (b.width - a.width) * progress,
        height: a.height + (b.height - a.height) * progress), display: true)
  }

  /// 停下挤压，落到终点（收起、放完、中途被打断都走这里）
  private func endSqueeze() {
    squeezeLink?.invalidate()
    squeezeLink = nil
    guard let end = squeeze?.end else { return }
    squeeze = nil
    setFrame(end, display: true)
    invalidateShadow()
  }

  /// 入场：窗口淡入（fadeIn），内容从上方 6 pt 落下（弹簧）；减弱动态效果时只淡入
  private func animateIn() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
    guard !Style.reduceMotion, let layer = host.layer else { return }
    let drop = CASpringAnimation(perceptualDuration: 0.24, bounce: 0.12)
    drop.keyPath = "transform.translation.y"
    drop.fromValue = 6  // AppKit 图层 y 向上：正值 = 在上方
    drop.toValue = 0
    drop.duration = drop.settlingDuration
    layer.add(drop, forKey: "enter")
  }

  /// 立刻收起（粘贴前、打开设置、程序切换）：没有退场动画，⌘V 发出时面板已经不在
  func hide() {
    endSqueeze()
    guard isVisible else { return }
    saveFrameIfMoved()
    showGeneration += 1
    animationBehavior = .none
    orderOut(nil)
    alphaValue = 1
    removeMouseMonitors()
    onHide?()
  }

  /// 用户关掉（Esc、⌘W、点外面、再按热键、失焦）：系统淡出。窗口逻辑上立刻移走，键盘马上回到原 App
  func dismiss() {
    endSqueeze()
    guard isVisible else { return }
    saveFrameIfMoved()
    showGeneration += 1
    animationBehavior = Style.reduceMotion ? .none : .utilityWindow
    lastDismiss = CACurrentMediaTime()
    orderOut(nil)
    animationBehavior = .none
    alphaValue = 1
    removeMouseMonitors()
    onHide?()
  }

  /// ⌘Y 放大预览：从 source（屏幕坐标，检查器卡片）长到 target。不抢键盘、点外关闭；已经开着就直接挪到 target。
  /// 窗口本身在长（毛玻璃由窗口服务器按真实大小画），不缩放内容图层；减弱动态效果时在 target 淡入
  func zoom(from source: NSRect, to target: NSRect) {
    showGeneration += 1
    let grows = (!isVisible || alphaValue < 1) && !Style.reduceMotion
    animationBehavior = .none
    if !isVisible {
      move(to: grows ? source : target, animated: false)
      alphaValue = 0
    }
    orderFrontRegardless()
    if mouseMonitors.isEmpty { installMouseMonitors() }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
    NSAnimationContext.runAnimationGroup { context in
      // island 曲线（0.42 s）的近似：窗口帧动画只能用贝塞尔
      context.duration = grows ? 0.36 : 0
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.95, 0.3, 1)
      animator().setFrame(target, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { self.invalidateShadow() }
    }
  }

  /// 缩回 source 并淡出（⌘Y / Esc 关掉放大预览）；减弱动态效果时原地淡出，没有 source（剪贴板面板已经不在）时系统淡出。
  /// onHide 在动画放完、窗口收走后才调（调用方先把 key 还回去）
  func unzoom(to source: NSRect?) {
    guard isVisible else { return }
    // 减弱动态效果：原地淡出（只改透明度）
    guard let source = Style.reduceMotion ? frame : source else { return dismiss() }
    showGeneration += 1
    let generation = showGeneration
    removeMouseMonitors()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.reduceMotion ? 0.2 : 0.24
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animator().setFrame(source, display: true)
      animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        guard self.showGeneration == generation else { return }
        self.orderOut(nil)
        self.alphaValue = 1
        self.onHide?()
      }
    }
  }

  /// 换位置和大小（放大预览换了条目）；animated 走 0.24 s（settle 的近似），连按方向键时调用方传 false。
  /// 不动画也走零时长的 animator，理由同 setContentHeight
  func move(to target: NSRect, animated: Bool) {
    guard target != frame else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animated && isVisible && !Style.reduceMotion ? 0.24 : 0
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
      animator().setFrame(target, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { self.invalidateShadow() }
    }
  }

  func toggle() {
    if isVisible && isKeyWindow { dismiss() } else { present() }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event) {
      return true
    }
    // 不看 Caps Lock（deviceIndependentFlagsMask 含 .capsLock，大写锁定开着 ⌘W 会失灵）
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else {
      return false
    }
    // ⌘W 关闭（各浮层都认，固定着也关：固定只管点别处不收起）。本 App 不激活，主菜单的「关闭」收不到
    if Int(event.keyCode) == kVK_ANSI_W {
      dismiss()
      return true
    }
    // 浮层不激活本 App，主菜单的 ⌘C / ⌘V 等不一定收得到：直接发给当前输入框
    guard let action = Self.editActions[event.charactersIgnoringModifiers?.lowercased() ?? ""]
    else { return false }
    return Self.sendEditAction(action, from: self)
  }

  /// 截图里输入文字时也用它（同样不激活本 App）
  static let editActions: [String: Selector] = [
    "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
    "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
    "z": Selector(("undo:")),
  ]

  /// 把编辑动作发给当前输入框；拷贝 / 剪切改了剪贴板就记下这次是在自家浮层里复制的（Paster.panelCopyChangeCount）。
  /// ponytail: 右键菜单里的「拷贝」不经这里，照外部复制算；真碰上再给浮层里的文本视图接 copy:
  static func sendEditAction(_ action: Selector, from sender: Any?) -> Bool {
    let before = NSPasteboard.general.changeCount
    let handled = NSApp.sendAction(action, to: nil, from: sender)
    let after = NSPasteboard.general.changeCount
    if after != before { Paster.panelCopyChangeCount = after }
    return handled
  }

  /// Esc（面板里有展开的层时各自先逐级退，退到头才转到这里）：固定着也关
  override func cancelOperation(_ sender: Any?) {
    dismiss()
  }

  override func resignKey() {
    super.resignKey()
    // key 让给自己的 sheet（确认框等）、让给截图遮罩时不算失焦
    if autoHide == .resignKey, isVisible, attachedSheet == nil, !isPinned(),
      !Self.isSelectingRegion(in: NSApp.windows)
    {
      dismiss()
    }
  }

  /// 截图框选中（有看得见的遮罩）：遮罩当 key、点遮罩都不算失焦 / 点外。用户 2026-09-26：截图时本 App 开着的窗口
  /// 留在冻结帧里、能悬停和单击选中，截完还开着（mac-overlay-panel §2）
  static func isSelectingRegion(in windows: [NSWindow]) -> Bool {
    windows.contains { $0 is SelectionOverlay && $0.isVisible }
  }

  /// 改高度时顶边不动，只往下伸缩（启动器随结果条数、翻译浮窗随内容变化）；往下出了屏幕可见区就整体往上挪。
  /// animated：变高 0.18 s、变矮 0.14 s（首次显示、拖边改宽和减弱动态效果时不动画）。
  /// 不动画时也走零时长的 animator：直接 setFrame 盖不掉正在跑的帧动画，动画结束会把旧目标写回来
  func setContentHeight(_ height: CGFloat, animated: Bool = false) {
    // 挤压入场还在弹：改它的终点（顶边不动），别另起一段帧动画和它抢
    if var running = squeeze {
      running.end.origin.y = running.end.maxY - height
      running.end.size.height = height
      squeeze = running
      return
    }
    guard abs(frame.height - height) > 0.5 else { return }
    var target = frame
    target.origin.y = target.maxY - height
    target.size.height = height
    if let visible = screen?.visibleFrame, target.minY < visible.minY {
      target.origin.y = min(visible.minY, visible.maxY - height)
    }
    // 程序挪的（变高出了屏幕往上挪）不算用户拖过：摆好的位置跟着改
    if let placed, placed.topLeft == NSPoint(x: frame.minX, y: frame.maxY) {
      self.placed = (NSPoint(x: target.minX, y: target.maxY), placed.width)
    }
    let animates =
      animated && isVisible && alphaValue == 1 && !isUserResizing && !Style.reduceMotion
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animates ? (height > frame.height ? 0.18 : 0.14) : 0
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
      animator().setFrame(target, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { self.invalidateShadow() }
    }
  }

  private func placeForShow() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    defer { placed = (NSPoint(x: frame.minX, y: frame.maxY), frame.width) }
    if topAnchored {
      let top = visible.maxY - visible.height * 0.2
      setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: top - frame.height))
      return
    }
    if let anchor {
      return setFrameOrigin(Self.frame(near: anchor, size: frame.size, in: visible).origin)
    }
    if frameName != nil {
      return setFrame(
        Self.lastFrame(
          user: userFrame, size: frame.size, screens: NSScreen.screens.map(\.visibleFrame),
          in: visible), display: false)
    }
    setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
  }

  /// 收起时：用户拖过、拖宽过（和这次摆好的左上角 / 宽度不同）才记下来。比左上角：高度随内容变、顶边不动。
  /// 只拖宽没挪（右边的拖边）时位置沿用 userFrame，没有才用当前位置
  private func saveFrameIfMoved() {
    let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
    guard let frameName, let placed, placed.topLeft != topLeft || placed.width != frame.width
    else { return }
    let moved = placed.topLeft != topLeft
    userFrame = (moved ? topLeft : userFrame?.topLeft ?? topLeft, frame.width)
    self.placed = (topLeft, frame.width)
    // ponytail: saveFrame 只能存当前帧，只拖宽而 userFrame 在别处时磁盘上不更新（宽度这次运行内有效）；要存再自己写偏好
    if userFrame?.topLeft == topLeft { saveFrame(usingName: frameName) }
  }

  /// 不带锚点出现的位置（纯函数配单测，体检 A13）：用户拖到的左上角和宽度，高度沿用当前内容高；所在屏不是鼠标所在屏时
  /// 换算到鼠标所在屏同一相对位置。没拖过、或哪块屏都不在（拔了外接屏）就居中到鼠标所在屏
  static func lastFrame(
    user: (topLeft: NSPoint, width: CGFloat)?, size: NSSize, screens: [NSRect], in visible: NSRect
  ) -> NSRect {
    let width = user?.width ?? size.width
    let centered = NSRect(
      x: visible.midX - width / 2, y: visible.midY - size.height / 2, width: width,
      height: size.height)
    guard let user else { return centered }
    let frame = NSRect(
      x: user.topLeft.x, y: user.topLeft.y - size.height, width: width, height: size.height)
    guard let home = screens.max(by: { overlap($0, frame) < overlap($1, frame) }),
      overlap(home, frame) > 0
    else { return centered }
    return relocated(frame, from: home, to: visible)
  }

  private static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
    let common = a.intersection(b)
    return common.isNull ? 0 : common.width * common.height
  }

  /// 跟随鼠标（体检 A13，纯函数配单测）：左上角放在光标右下 12 pt；右边放不下翻到光标左边、下边放不下翻到光标上面，
  /// 最后夹进屏幕可见区（四周内缩 8；比可见区还大时左上角露在里面）
  static func frame(near mouse: NSPoint, size: NSSize, in visible: NSRect) -> NSRect {
    let gap: CGFloat = 12
    let area = visible.insetBy(dx: 8, dy: 8)
    var x = mouse.x + gap
    if x + size.width > area.maxX { x = mouse.x - gap - size.width }
    var top = mouse.y - gap
    if top - size.height < area.minY { top = mouse.y + gap + size.height }
    x = max(min(x, area.maxX - size.width), area.minX)
    top = min(max(top, area.minY + size.height), area.maxY)
    return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
  }

  /// 上次的位置换算到另一块屏（纯函数配单测）：左上角在可见区里的相对位置不变，再夹进新屏的可见区
  static func relocated(_ frame: NSRect, from old: NSRect, to new: NSRect) -> NSRect {
    guard old != new, old.width > 0, old.height > 0 else { return frame }
    let rx = (frame.minX - old.minX) / old.width
    let ry = (old.maxY - frame.maxY) / old.height
    var x = new.minX + rx * new.width
    var top = new.maxY - ry * new.height
    x = max(min(x, new.maxX - frame.width), new.minX)
    top = min(max(top, new.minY + frame.height), new.maxY)
    return NSRect(x: x, y: top - frame.height, width: frame.width, height: frame.height)
  }

  /// 点外即关：global 监听管别的 App，local 监听管自家窗口。点中任一自家浮层、截图框选中点遮罩都不关
  /// （兄弟窗口豁免），点击时实时判断；显示时装、隐藏时卸，成对出现
  private func installMouseMonitors() {
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.clickedOutside() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        if !(event.window is OverlayPanel || Self.isSelectingRegion(in: NSApp.windows)) {
          self?.clickedOutside()
        }
      }
      return event
    }
    mouseMonitors = [global, local].compactMap { $0 }
  }

  private func removeMouseMonitors() {
    mouseMonitors.forEach(NSEvent.removeMonitor)
    mouseMonitors = []
  }

  private func clickedOutside() {
    if !isPinned() { dismiss() }
  }

  /// 可拉伸的圆角蒙版：连续曲线的过渡比圆角半径长，拉伸区留 1.6 倍
  private static func cornerMask(radius: CGFloat) -> NSImage {
    let cap = ceil(radius * 1.6)
    let side = cap * 2 + 1
    let scale: CGFloat = 2
    let pixels = Int(side * scale)
    let path = RoundedRectangle(cornerRadius: radius * scale, style: .continuous)
      .path(in: CGRect(x: 0, y: 0, width: pixels, height: pixels)).cgPath
    let context = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
    context?.addPath(path)
    context?.fillPath()
    let image =
      context?.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }
      ?? NSImage(size: NSSize(width: side, height: side))
    image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    image.resizingMode = .stretch
    return image
  }
}

/// 浮层内容的根：描边 + 减弱动态效果时去掉全部 SF Symbol 动效（mac-whisker §7，一处管三个面板）
private struct PanelRoot<Content: View>: View {
  let content: Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    content.ignoresSafeArea().overlay(PanelRim()).symbolEffectsRemoved(reduceMotion).appAccent()
  }
}

/// 无边框窗口的左右拖边（改宽度，夹在 minSize / maxSize 之间，另一边不动）。
/// 本 App 不激活，光标矩形不生效：用 activeAlways 的追踪区手动设光标
private final class ResizeEdge: NSView {
  enum Side { case left, right }

  private let side: Side
  private var start: (mouse: CGFloat, frame: NSRect)?
  private static let width: CGFloat = 6

  init(side: Side) {
    self.side = side
    super.init(frame: .zero)
    autoresizingMask = side == .left ? [.height, .maxXMargin] : [.height, .minXMargin]
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard let bounds = superview?.bounds else { return }
    frame = NSRect(
      x: side == .left ? 0 : bounds.maxX - Self.width, y: 0, width: Self.width,
      height: bounds.height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
  override func mouseExited(with event: NSEvent) { if start == nil { NSCursor.arrow.set() } }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    start = (NSEvent.mouseLocation.x, window.frame)
    (window as? OverlayPanel)?.isUserResizing = true
  }

  /// 只改 x 和宽度；高度和 y 取当前的（宽度一变内容重排，高度会跟着 setContentHeight 变）
  override func mouseDragged(with event: NSEvent) {
    guard let window, let start else { return }
    let delta = NSEvent.mouseLocation.x - start.mouse
    let minWidth = max(window.minSize.width, window.contentMinSize.width)
    let maxWidth = min(
      window.maxSize.width, window.screen?.visibleFrame.width ?? .greatestFiniteMagnitude)
    var frame = window.frame
    frame.size.width = min(
      max(start.frame.width + (side == .left ? -delta : delta), minWidth), maxWidth)
    frame.origin.x = side == .left ? start.frame.maxX - frame.width : start.frame.minX
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.animator().setFrame(frame, display: true)
    }
  }

  override func mouseUp(with event: NSEvent) {
    start = nil
    (window as? OverlayPanel)?.isUserResizing = false
    NSCursor.arrow.set()
  }

  /// 拖边盖在内容的最左 / 最右 6 pt 上：滚轮转给下面的内容（结果列表的滚动条在这里）
  override func scrollWheel(with event: NSEvent) {
    guard let superview,
      let content = superview.subviews.first(where: { !($0 is ResizeEdge) }),
      let target = content.hitTest(superview.convert(event.locationInWindow, from: nil))
    else { return super.scrollWheel(with: event) }
    target.scrollWheel(with: event)
  }
}
