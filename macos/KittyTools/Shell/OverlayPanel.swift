// 不激活前台的浮层（NSPanel）：剪贴板面板、翻译浮窗、启动器共用这一个类，各建一个实例（PLAN §4）。
// 显示只 orderFrontRegardless + makeKey，永远不调 NSApp.activate：前台 App 保持不变，
// 粘贴时发的 ⌘V、划词时发的 ⌘C 才会落到它身上。
// 外观是 Whisker 的 Panel 皮肤（mac-whisker §2）：无边框、16 pt 连续圆角（maskImage 裁，系统阴影跟着走）+ 描边
// （macOS 26 起换成液态玻璃 NSGlassEffectView，不画描边）；
// 出现时淡入 + 内容下落 6 pt，用户关掉时一块替身在原位淡出（真窗口立刻收走，键盘马上回到原 App；不用系统的窗口淡出，
// 它会泛白，见 fadeOutStandIn），高度可带动画伸缩。
// ⌘Y 放大预览用 zoom / unzoom：从检查器卡片的位置长出来、缩回去。剪贴板、启动器、翻译浮窗可选「挤压入场」（设置 › 通用「动效」，squeezesIn）。
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
  /// 第 8 批：面板被叫出来当 key 时，之前 key 的自家哪个窗口（便签那叠 / 浮动便签 / 全部便签窗口 / 设置窗）。
  /// 面板开着时用户点回了自家别的窗口就改记它；别的 App 被激活了就清掉。粘贴时直接落进它里面（R12）
  private(set) weak var pasteTargetWindow: NSWindow?
  private var isWatchingPasteTarget = false
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
  /// 上次淡出的时刻：淡出的替身还在时又被呼出，就不再淡入（不然旧内容叠在新内容上）
  private var lastDismiss: CFTimeInterval = 0
  /// 用户正在拖左右边改宽度：这期间改高度不做动画（动画结束会盖掉拖动设的帧）
  fileprivate var isUserResizing = false
  /// 每次出现 / 收起加一：缩回动画的收尾发现期间又被打开（或已被别处收起）就什么都不做
  private var showGeneration = 0
  /// 出现时用挤压入场（设置 › 通用「动效」的开关，剪贴板 / 启动器 / 翻译浮窗共用）；false 用标准的淡入 + 下落
  var squeezesIn: () -> Bool = { false }
  /// 正在挤压入场：起止帧、开始时刻、逐帧驱动的显示器刷新
  private var squeeze: (start: NSRect, end: NSRect, began: CFTimeInterval)?
  private var squeezeLink: CADisplayLink?
  /// 窗口自己的排版（layoutIfNeeded）嵌套了几层；排版中要改的帧排完再改（见 layoutIfNeeded）
  private var layoutDepth = 0
  private var frameChangeAfterLayout: (() -> Void)?

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
    // 材质（mac-whisker §2）：root 是窗口的 contentView，内容和左右拖边放进 background
    let (root, background) = Self.makeBackground()
    hosting.frame = background.bounds
    hosting.autoresizingMask = [.width, .height]
    background.addSubview(hosting)
    if minSize != nil {
      for edge in [ResizeEdge.Side.left, .right] { background.addSubview(ResizeEdge(side: edge)) }
    }
    contentView = root
    // 不用 setFrameAutosaveName：它连跟随鼠标摆的位置也记，「上次位置」就成了上次弹出的地方
    if let frameName {
      if setFrameUsingName(frameName) {
        userFrame = (NSPoint(x: frame.minX, y: frame.maxY), frame.width)
      } else {
        center()
      }
    }
  }

  /// 材质底：返回窗口的 contentView 和放内容的那一层（面板和退场淡出的替身用同一份）
  private static func makeBackground() -> (root: NSView, background: NSView) {
    if #available(macOS 26, *) {
      // 液态玻璃：圆角交给玻璃（不用 maskImage、PanelRim 不画），内容进它的 contentView（玻璃用 Auto Layout 撑满）
      let glass = NSGlassEffectView()
      glass.cornerRadius = Style.Radius.panel
      // 图层再按同一个圆角裁一遍：macOS 27 上面板当 key 时，玻璃会在圆角外面（到窗口的方角）画一层很淡的黑，
      // 系统阴影按它算成方的，四个角露出方形的黑边（2026-10-19 真机，剪贴板、启动器、翻译浮窗都有；不当 key 时没有）。
      // 独立小程序比过：裁了之后圆角外面全透明、阴影跟着圆角走（build/research/launchpad/probe/border/）
      glass.wantsLayer = true
      glass.layer?.cornerRadius = Style.Radius.panel
      glass.layer?.cornerCurve = .continuous
      glass.layer?.masksToBounds = true
      let background = NSView()
      background.autoresizingMask = [.width, .height]  // 自动缩放掩码和玻璃撑满它的约束一致、不打架
      glass.contentView = background
      return (glass, background)
    }
    // 系统毛玻璃底：state 必须 .active，本 App 从不激活，跟随窗口状态会一直是灰的非激活外观
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.maskImage = Self.cornerMask(radius: Style.Radius.panel)
    return (effect, effect)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// macOS 27：**窗口自己排版的半路不能改它的帧**。orderFront、displayIfNeeded 都会让窗口排版，SwiftUI 在这一趟里当场
  /// 出内容，内容要的高度一变就会调 setContentHeight（⌘Y 大卡是 move）；这时改帧，排完系统又按排版前的尺寸把
  /// contentView 挪一遍（contentView 比窗口多出 / 少了一次改动量：内容上下被裁），玻璃底的约束还会把窗口改成一个
  /// 过时的高度，都要等下一次改帧才对回来（用户 2026-10-16 报启动器、翻译浮窗「高度不对」）。所以排版中的改帧记下来，
  /// 排完当场再做（还在同一次 order / 显示里，画出来之前）。2026-10-17 本机 macOS 27.0.1 实测：正常的显示周期、拖宽度
  /// 时的连锁改高、带标题栏的窗口、先改帧再 order 都没这个问题
  override func layoutIfNeeded() {
    layoutDepth += 1
    super.layoutIfNeeded()
    layoutDepth -= 1
    guard layoutDepth == 0, let change = frameChangeAfterLayout else { return }
    frameChangeAfterLayout = nil
    change()
  }

  /// 正在排版：把这次改帧记下（只留最后一次），返回 true，调用方直接返回
  private func deferredUntilLaidOut(_ change: @escaping () -> Void) -> Bool {
    guard layoutDepth > 0 else { return false }
    frameChangeAfterLayout = change
    return true
  }

  /// 面板开着期间盯着「自家哪个窗口是 key」「别的 App 被激活」：前者改记，后者清掉（点进文本编辑再回来粘贴要粘进
  /// 文本编辑，不是在别处刚点过的便签）
  private func watchPasteTargetWindow() {
    guard !isWatchingPasteTarget else { return }
    isWatchingPasteTarget = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(ownWindowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification,
      object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(anotherAppActivated(_:)),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
  }

  /// 面板开着时自家别的窗口当上了 key（用户点回了便签）：改记它
  @objc private func ownWindowBecameKey(_ note: Notification) {
    guard isVisible, let window = note.object as? NSWindow, window !== self else { return }
    pasteTargetWindow = window
  }

  /// 别的 App 被激活（用户点了别的 App）：清掉——固定着的剪贴板面板开着、点进文本编辑再回来粘贴，要粘进文本编辑
  @objc private func anotherAppActivated(_ note: Notification) {
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    if app?.bundleIdentifier != Bundle.main.bundleIdentifier { pasteTargetWindow = nil }
  }

  /// 面板收起：不再盯，记着的窗口也作废（下次呼出重新记）
  private func stopWatchingPasteTarget() {
    guard isWatchingPasteTarget else { return }
    isWatchingPasteTarget = false
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didBecomeKeyNotification, object: nil)
    NSWorkspace.shared.notificationCenter.removeObserver(
      self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
    pasteTargetWindow = nil
  }

  /// 现在粘得进哪个文本视图（记着的窗口在屏上、第一响应者是能编辑的 NSTextView）；nil = 照旧发给前台 App
  func pasteTarget() -> NSTextView? { Paster.pasteTarget(in: pasteTargetWindow) }

  /// makingKey = false：只露出来、不抢键盘（复制即译），此时靠点外关闭。
  /// anchor：新出现时放在这一点（鼠标位置）的右下 12 pt（翻译浮窗「跟随鼠标」）；已经开着就不挪。
  /// keepsPlace：原地重新露出来（划词翻译并替换期间临时 orderOut 的固定浮窗），不重新摆
  func present(makingKey: Bool = true, anchor: NSPoint? = nil, keepsPlace: Bool = false) {
    let appearing = !isVisible
    // 淡出的替身 0.10 s 内还在：直接不透明盖住它
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
      // 呼出前焦点在自家哪个窗口里（便签正文、标题框…）：粘贴时落回它，不发给前台那个 App
      if let key = NSApp.keyWindow, key !== self { pasteTargetWindow = key }
      watchPasteTargetWindow()
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

  /// 挤压入场（像 macOS 26 的 Spotlight）：窗口从窄一成、矮四分之一（顶边不动、左右居中）弹开到原尺寸，
  /// 冲过头一点再回来（island 曲线 0.42 s / bounce 0.22）。动的是窗口本身（毛玻璃、阴影由窗口服务器按真实大小画）；
  /// 窗口帧动画只支持贝塞尔，实测冲不过头（还会忽略时长），所以跟着显示器刷新逐帧按 SwiftUI 的 Spring 算帧。
  /// 逐帧改窗口尺寸本身就贵（2026-10-03 屏外实测主线程每帧中位 4–6 ms、慢的 15–30 ms，大头是窗口服务器重分配缓冲、
  /// 重算形状和阴影，SwiftUI 重排只占 1–2 ms），所以最高 60 Hz：120 Hz 屏上每帧只有 8.3 ms，跟不上就掉帧。
  /// ponytail: 要更顺得把窗口定在终点、只动图层，可阴影是窗口服务器按窗口内容算的、跟不上图层动画，没有公开接口
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
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
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
    stopWatchingPasteTarget()
    onHide?()
  }

  /// 固定着的不动，没固定的立刻收起（截图翻译 / 识字 / 长截图前让开）。固定只看构造时给的 isPinned
  func hideUnlessPinned() {
    if !isPinned() { hide() }
  }

  /// 用户关掉（Esc、⌘W、点外面、再按热键、失焦）：淡出（替身在原位淡，减弱动态效果时没有）。窗口立刻移走，
  /// 键盘马上回到原 App——呼出前焦点在自家便签里（同粘贴落到哪，pasteTarget）、又是用键盘关的，就回到那条便签：
  /// 那叠里打开的、浮动的便签是不激活本 App 的面板，系统不一定把 key 还给它们，原来要再点一下才能接着打字。
  /// byKeyboard = false：点别处、失焦关掉的（用户正要去别处，不抢）
  func dismiss(byKeyboard: Bool = true) {
    endSqueeze()
    guard isVisible else { return }
    let returnTo = byKeyboard ? pasteTarget()?.window : nil
    saveFrameIfMoved()
    showGeneration += 1
    lastDismiss = CACurrentMediaTime()
    if !Style.reduceMotion { fadeOutStandIn() }
    animationBehavior = .none
    orderOut(nil)
    alphaValue = 1
    removeMouseMonitors()
    stopWatchingPasteTarget()
    onHide?()
    // onHide 可能已经把 key 还给了别的浮层（翻译浮窗 → 剪贴板面板：记着的就是它），系统也可能已经还了，不重复
    if let returnTo, NSApp.keyWindow !== returnTo { returnTo.makeKey() }
  }

  /// 退场淡出的替身：一块同样材质、同样位置的窗口，里面是这一刻内容的图，盖在面板上面按 fadeOut 淡掉；面板自己同时
  /// 立刻收走（onHide 把内容复位、键盘还给原 App 都不等它）。
  /// 不用系统的窗口淡出（orderOut 前临时设 animationBehavior = .utilityWindow，2026-10-03 之前的做法）：系统淡的是
  /// 窗口自己那层画面，不带毛玻璃对背后的压暗，淡出第一帧整块面板变成浅灰——屏上逐帧实测，深色背景上面板亮度
  /// 42 → 87，再用约 130 ms 淡掉，看着就是关闭时泛白闪一下（用户 2026-10-03 报，三块面板都是）。
  /// 替身的毛玻璃是活的，窗口透明度动画不丢压暗（实测亮度单调降到背景）
  private func fadeOutStandIn() {
    let images = Self.snapshots(of: host)
    guard !images.isEmpty else { return }
    let standIn = PanelStandIn(
      frame: frame, level: level, behavior: collectionBehavior, hasShadow: true)
    standIn.appearance = appearance
    standIn.alphaValue = alphaValue  // 淡入到一半就被关掉的，从当前的透明度接着淡
    let (root, background) = Self.makeBackground()
    standIn.contentView = root
    root.layoutSubtreeIfNeeded()
    let content = NSView(frame: background.bounds)
    content.autoresizingMask = [.width, .height]
    content.wantsLayer = true
    for (image, filter) in images {
      let layer = CALayer()
      layer.frame = content.bounds
      layer.contents = image
      layer.compositingFilter = filter
      content.layer?.addSublayer(layer)
    }
    background.addSubview(content)
    standIn.order(.above, relativeTo: windowNumber)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeOut
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      standIn.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated { standIn.orderOut(nil) }
    }
  }

  /// 把内容画成图给替身用：普通内容一张；挂着合成滤镜的图层按滤镜各一张、带上那个滤镜。
  /// 毛玻璃上「鲜亮」的次要文字、图标、分隔线，SwiftUI 是给图层挂合成滤镜（深色外观 plusL、浅色 plusD）实时和底下的
  /// 材质混出来的；直接画成一张图会丢掉这层混合（深色面板在浅色背景上，副标题、键帽几乎看不见，替身一出来内容就闪一下），
  /// 所以这些图层单独画、在替身里挂回同一个滤镜——屏上实测替身和真面板逐像素一样（深 / 浅外观 × 深 / 浅背景）。
  /// 画的时候临时把另一半图层藏起来，画完原样放回（不提交，屏上看不出）。启动器一次约 18 ms
  static func snapshots(of view: NSView) -> [(image: CGImage, filter: Any?)] {
    guard let root = view.layer else { return [] }
    var vibrant: [CALayer] = []
    // 不带滤镜、子树里也没有带滤镜的图层：画带滤镜的那张时藏起来（它们的上级只是容器，留着才有位置和裁剪）
    var plain: [CALayer] = []
    @discardableResult func sort(_ layer: CALayer) -> Bool {
      if layer.compositingFilter != nil {
        vibrant.append(layer)
        return true
      }
      let children = layer.sublayers ?? []
      let mixed = children.map { sort($0) }
      guard mixed.contains(true) else { return false }
      for (child, has) in zip(children, mixed) where !has { plain.append(child) }
      return true
    }
    sort(root)
    func render(hiding layers: [CALayer]) -> CGImage? {
      let shown = layers.filter { !$0.isHidden }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for layer in shown { layer.isHidden = true }
      defer {
        for layer in shown { layer.isHidden = false }
        CATransaction.commit()
      }
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      return bitmap.cgImage
    }
    var images: [(image: CGImage, filter: Any?)] = []
    if let image = render(hiding: vibrant) { images.append((image, nil)) }
    var done: Set<String> = []
    for layer in vibrant {
      let name = String(describing: layer.compositingFilter)
      guard done.insert(name).inserted else { continue }
      let others = vibrant.filter { String(describing: $0.compositingFilter) != name }
      if let image = render(hiding: plain + others) {
        images.append((image, layer.compositingFilter))
      }
    }
    return images
  }

  /// 面板里的一块（SwiftUI 坐标，原点左上）换成屏幕坐标：⌘Y 大卡从选中行长出来、缩回去用（剪贴板透镜、启动器选中行）
  func screenRect(of rect: CGRect) -> NSRect {
    NSRect(
      x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  /// ⌘Y 大卡最大能多大：所在屏可见区的 90%
  var cardLimit: NSSize {
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
    return NSSize(width: visible.width * 0.9, height: visible.height * 0.9)
  }

  /// 以这块面板为中心摆 size 大的卡片（⌘Y 大卡）：最大到 cardLimit，再整个挪进可见区
  func centeredFrame(_ size: NSSize) -> NSRect {
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
    let width = min(size.width, cardLimit.width)
    let height = min(size.height, cardLimit.height)
    return NSRect(
      x: min(max(frame.midX - width / 2, visible.minX), visible.maxX - width),
      y: min(max(frame.midY - height / 2, visible.minY), visible.maxY - height), width: width,
      height: height)
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
    if deferredUntilLaidOut({ [weak self] in self?.move(to: target, animated: animated) }) {
      return
    }
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
    // ⌘Z / ⇧⌘Z：焦点在输入框里时撤销 / 重做它里面打的字（原来没有任何地方接重做）
    if let done = Self.undoRedo(event, in: self) { return done }
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

  /// ⌘Z 撤销 / ⇧⌘Z 重做**焦点所在的输入框**里打的字（NSWindow.undoFocusedText：直接动它登记撤销的那个栈，
  /// 不发 undo: / redo: 动作）。不是这两个键、焦点不在输入框里给 nil（调用方照原来的路走）；没有可撤销 / 重做的给
  /// false（不算处理了，系统响一声）。浮层（OverlayPanel）和便签那叠的面板（NoteDeckPanel）共用
  static func undoRedo(_ event: NSEvent, in window: NSWindow) -> Bool? {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard flags == .command || flags == [.command, .shift],
      event.charactersIgnoringModifiers?.lowercased() == "z", window.firstResponder is NSTextView
    else { return nil }
    return window.undoFocusedText(redo: flags != .command)
  }

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
      dismiss(byKeyboard: false)
    }
  }

  /// 截图框选中（有看得见的遮罩）：遮罩当 key、点遮罩都不算失焦 / 点外。用户 2026-09-26：截图时本 App 开着的窗口
  /// 留在冻结帧里、能悬停和单击选中，截完还开着（mac-overlay-panel §2）
  static func isSelectingRegion(in windows: [NSWindow]) -> Bool {
    windows.contains { $0 is SelectionOverlay && $0.isVisible }
  }

  /// global 监听收到的这一下点在输入法的窗口上：系统的「表情与符号」、候选窗、长按出来的重音字母都是别的进程的窗口，
  /// 点它们是在给输入框挑字，不算点别处（便签那叠、各浮层的点外共用）
  static func isInputMethodClick() -> Bool {
    let owner = ScreenCapture.ownerPID(at: NSEvent.mouseLocation)
    return isInputMethod(owner.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL })
  }

  /// 这个 App 是不是输入法（纯函数，单测）：系统的（「表情与符号」是 /System/Library/Input Methods/CharacterPalette.app）
  /// 和第三方的（/Library/Input Methods、~/Library/Input Methods）都装在叫「Input Methods」的目录里
  static func isInputMethod(_ bundle: URL?) -> Bool {
    bundle?.deletingLastPathComponent().lastPathComponent == "Input Methods"
  }

  /// 改高度时顶边不动，只往下伸缩（启动器随结果条数、翻译浮窗随内容变化）；往下出了屏幕可见区就整体往上挪。
  /// animated：变高 0.18 s、变矮 0.14 s（首次显示、拖边改宽和减弱动态效果时不动画）。
  /// 不动画时也走零时长的 animator：直接 setFrame 盖不掉正在跑的帧动画，动画结束会把旧目标写回来
  func setContentHeight(_ height: CGFloat, animated: Bool = false) {
    if deferredUntilLaidOut({ [weak self] in self?.setContentHeight(height, animated: animated) }) {
      return
    }
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
      MainActor.assumeIsolated {
        if !Self.isInputMethodClick() { self?.clickedOutside() }
      }
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
    if !isPinned() { dismiss(byKeyboard: false) }
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

/// 退场淡出的替身窗口（OverlayPanel.fadeOutStandIn；浮动便签收回时的替身也用它，NoteFloat.leave）。不是另一种浮层，
/// 子类化只为有个类名：截图的留用名单（ScreenCapture.keptOwnWindows）按类名把它排除，淡出中的面板不进冻结帧和悬停列表
final class PanelStandIn: NSPanel {
  /// 两处替身共同的样子：无边框、不激活、透明、不接鼠标、不进旁白、没有系统的窗口动画、关了不释放；层级和在哪些桌面
  /// 出现跟着被替下来的那块（level / behavior）。系统阴影看替的是什么：浮层要（材质底是窗口自己的），浮动便签的阴影
  /// 画在动着的图层上（窗口的阴影跟不上它）
  convenience init(
    frame: NSRect, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior, hasShadow: Bool
  ) {
    self.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    isReleasedWhenClosed = false
    self.level = level
    collectionBehavior = behavior
    isOpaque = false
    backgroundColor = .clear
    self.hasShadow = hasShadow
    ignoresMouseEvents = true
    animationBehavior = .none
    setAccessibilityElement(false)
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

extension NSWindow {
  /// 焦点所在的输入框自己的撤销栈：多行的文本视图问到的那个（便签正文是这条便签的，NoteTextView.noteUndo；别的顺着
  /// 响应链问到窗口的），单行输入框是它的字段编辑器的（系统给每个输入框单独一个，结束编辑就丢）。焦点不在输入框里是 nil
  var focusedTextUndo: UndoManager? { (firstResponder as? NSTextView)?.undoManager }

  /// 撤销（redo：重做）焦点所在输入框里打的字，返回做没做（焦点不在输入框里、没有可撤销 / 重做的是 false）。
  /// ⌘Z / ⇧⌘Z 的入口都到这里（浮层和便签那叠的面板：OverlayPanel.undoRedo；全部便签窗口：NotesWindowModel.undo / redo）。
  /// 两件事都是 2026-10-13 实测（macOS 15.7）定的：
  /// - **直接动那个栈，不发 undo: / redo: 动作**：动作顺着响应链到头是窗口接（文本视图自己不响应它），而 NSWindow 的
  ///   undo: 动的是窗口内部的撤销栈——窗口子类重写了 undoManager 它也不看（重写了的窗口里 undo:「处理了」但字不变）。
  ///   便签那叠的面板原来正是重写的，正文里的 ⌘Z 因此一直不灵（用户报「便签输入区域不支持撤销和回退」）。
  /// - **撤完补发一次「文字变了」**：TextKit 2 的文本视图（SourceTextView、单行输入框的字段编辑器）撤销 / 重做之后
  ///   自己不发 textDidChange，不补的话界面上的字回去了、绑定里那份（搜索词、翻译的原文、便签的标题）却没变。
  ///   TextKit 1 的（便签正文 NoteTextView）自己会发，不重复
  @discardableResult
  func undoFocusedText(redo: Bool = false) -> Bool {
    guard let view = firstResponder as? NSTextView, let stack = view.undoManager,
      redo ? stack.canRedo : stack.canUndo
    else { return false }
    if redo { stack.redo() } else { stack.undo() }
    if view.textLayoutManager != nil { view.didChangeText() }
    return true
  }
}
