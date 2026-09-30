// 长截图会话：截图框选后按 S（或工具栏按钮）进入。遮罩收起、露出实时画面，选区外画一圈边框，旁边一个面板
// （拼接预览、状态、按钮）。用户在选区里滚动（滚轮、触控板都行），或按空格自动滚动；一直用 ScreenCaptureKit
// 截选区（滤掉本 App 的所有窗口），交给 ScrollStitcher 拼。↩ 拷贝、⌘S 存储、⇧⌘S 另存为…，Esc 取消。
// 边框和面板是不激活前台的 NSPanel（面板要当 key 收按键），会话结束立即释放；前台 App 一直不变。
// Whisker（mac-whisker §6 长截图）：面板是永远深色的 HUD（216 宽、圆角 16）；预览像纸带一样滚动、上下 18 pt 渐隐，
// 每拼上一段接缝处闪一下品牌粉；高度数字 22 pt 圆体滚动变化；选区边框 2 pt 品牌粉 + 外发光呼吸，自动滚动时只走蚂蚁线
// （同一表面只留一个循环动画，呼吸暂停），对不上时变橙、状态文字抖一下；拷贝钮和截图工具栏一样是 28 pt 品牌粉实心圆。
// 滚到底 / 到顶 / 最长是正常结束，不变色不抖；缺授权、截屏失败橙色不抖（体检 B42）。状态提示变了主动播报。
// 减弱动态效果时发光和蚂蚁线静止、不抖、不滚。

import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

final class ScrollCapture {
  enum Action { case copy, save, saveAs }

  struct Result {
    let image: CGImage
    /// 像素 / 点
    let scale: CGFloat
    let action: Action
  }

  /// 选区至少这么高（点）：太矮时两帧之间没几行可比
  static let minimumHeight: CGFloat = 60
  /// 长图最多多少像素高、多少像素（像素数和剪贴板历史收图的上限一致，复制后能进历史；约 160 MB 内存）
  private static let maxHeight = 30_000
  private static let maxPixels = ImageStore.maxPixels

  /// region：选区（点，AppKit 全局坐标）。取消返回 nil；开头截屏失败抛错
  static func run(region: CGRect) async throws -> Result? {
    guard
      let screen = NSScreen.screens.max(by: {
        area($0.frame.intersection(region)) < area($1.frame.intersection(region))
      }), area(screen.frame.intersection(region)) > 0
    else { return nil }
    let capture = try await ScrollCapture(region: region, screen: screen)
    return await withCheckedContinuation { capture.start(continuation: $0) }
  }

  private static func area(_ rect: CGRect) -> CGFloat {
    rect.isNull ? 0 : rect.width * rect.height
  }

  /// 选区（点，全局坐标，对齐到像素）
  private let region: CGRect
  private let scale: CGFloat
  private let filter: SCContentFilter
  private let configuration: SCStreamConfiguration
  private var stitcher: ScrollStitcher
  private let border: NSPanel
  private let borderView: ScrollBorderView
  private let panel: ScrollCapturePanel
  private var continuation: CheckedContinuation<Result?, Never>?
  private var loop: Task<Void, Never>?

  // 自动滚动
  private var isAutoScrolling = false
  /// 每步滚多少点；按实际滚出的像素调，让相邻两帧重叠一半多
  private var step: CGFloat
  /// 往哪个方向滚（1 往下、-1 往上）：跟着用户手动滚的方向
  private var direction: CGFloat = 1
  /// 滚轮事件的正负号：实测位移和发出去的方向相反就翻过来（不依赖系统对合成事件怎么处理「自然滚动」）
  private var wheelSign: CGFloat = 1
  /// 上一次发出去的滚动（点，沿 direction 为正、往回退为负）
  private var lastPosted: CGFloat = 0
  /// 连续几步画面都没动（到头了）、连续几帧对不上
  private var stalls = 0
  private var lostStreak = 0
  /// 截屏出错，抓帧循环已经停了（只剩拷贝、存储和取消）
  private var captureStopped = false

  private init(region: CGRect, screen: NSScreen) async throws {
    scale = screen.backingScaleFactor
    // 对齐到像素，夹进这块屏；sourceRect：屏内坐标，点，原点在左上
    let (snapped, source) = RegionSelector.captureRect(region, in: screen.frame, scale: scale)
    self.region = snapped
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
      throw CaptureError.noDisplay
    }
    // 滤掉本 App 的全部窗口（含之后才建的边框和面板）
    filter = SCContentFilter(
      display: display,
      excludingApplications: content.applications.filter { $0.processID == getpid() },
      exceptingWindows: [])
    configuration = SCStreamConfiguration()
    configuration.sourceRect = source
    configuration.width = Int((source.width * scale).rounded())
    configuration.height = Int((source.height * scale).rounded())
    configuration.showsCursor = false
    let first = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    guard
      let stitcher = ScrollStitcher(
        first: first, scrollbarWidth: Int(16 * scale),
        maxHeight: min(Self.maxHeight, Self.maxPixels / max(first.width, 1)))
    else { throw CaptureError.tooSmall }
    self.stitcher = stitcher
    step = self.region.height * 0.4
    borderView = ScrollBorderView()
    border = Self.makeBorder(around: self.region, view: borderView)
    panel = ScrollCapturePanel(region: self.region, screen: screen)
  }

  private enum CaptureError: LocalizedError {
    case noDisplay, tooSmall

    var errorDescription: String? {
      switch self {
      case .noDisplay: "找不到选区所在的屏幕"
      case .tooSmall: "选区太小"
      }
    }
  }

  private func start(continuation: CheckedContinuation<Result?, Never>) {
    self.continuation = continuation
    panel.hudView.onAction = { [unowned self] action in
      switch action {
      case .toggleAuto: toggleAutoScroll()
      case .cancel: finish(nil)
      case .output(let output): finish(output)
      }
    }
    border.orderFrontRegardless()
    panel.orderFrontRegardless()
    panel.makeKey()
    updateStatus()
    // 任务持有会话，直到结束（finish 清掉 continuation）循环才退出
    loop = Task { await run() }
  }

  /// 一直截选区：手动滚时尽量密（两帧之间滚得越少越容易对上），自动滚时每截一帧滚一步、等画面画完
  private func run() async {
    while continuation != nil {
      do {
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: configuration)
        guard continuation != nil else { return }
        handle(stitcher.add(image))
      } catch {
        guard continuation != nil else { return }
        captureStopped = true
        stopAutoScroll()
        notice = Status(text: "截屏失败，已停止：\(error.localizedDescription)", tone: .warning)
        updateStatus()
        return refreshPreview(force: true)
      }
      try? await Task.sleep(for: .milliseconds(isAutoScrolling ? 160 : 40))
    }
  }

  // MARK: 状态

  /// 对不上：拼上新内容之前一直提示
  private var isLost = false
  private var isFull = false
  /// 要停留的提示（授权、到头了、截屏失败）：拼上新内容时清掉
  private var notice: Status?
  /// 上一次主动播报的话：同一句不反复念
  private var announced: String?
  private var previewIsStale = false
  private var lastPreview = ContinuousClock.now - .seconds(1)

  private func handle(_ outcome: ScrollStitcher.Outcome) {
    switch outcome {
    case .moved(let grown):
      isLost = false
      if grown != 0 {
        notice = nil
        previewIsStale = true
      }
    case .lost: isLost = true
    case .full:
      isFull = true
      stopAutoScroll()
    case .unchanged: break
    }
    if isAutoScrolling { autoScroll(after: outcome) }
    updateStatus()
    refreshPreview(force: false)
  }

  /// 预览最多每 0.2 秒重画一次（要缩放一大块像素）；没赶上的下一帧补上
  private func refreshPreview(force: Bool) {
    guard previewIsStale, force || ContinuousClock.now - lastPreview > .milliseconds(200) else {
      return
    }
    previewIsStale = false
    lastPreview = .now
    panel.hudView.updatePreview(stitcher: stitcher, scale: panel.backingScaleFactor)
  }

  /// 状态行的一句话
  struct Status: Equatable {
    var text: String
    var tone = ScrollCaptureHUD.Tone.normal
    /// 主动播报（VoiceOver 的焦点多半不在面板上）：提示、到头、最长、对不上；平常的操作说明不播
    var announces = true
  }

  /// 要停留的提示 > 最长 > 对不上 > 操作说明。滚到底 / 到顶 / 最长是正常结束，用平常的颜色（体检 B42）；
  /// 但对不上（没到最长，同边框变橙的条件）盖过平常色的提示：停在「已经滚到底了」后手动滚得太快，要看到橙字、听到播报。纯函数，配单测
  static func status(notice: Status?, isFull: Bool, isLost: Bool, isAutoScrolling: Bool) -> Status {
    if let notice, !(isLost && !isFull && notice.tone == .normal) { return notice }
    if isFull { return Status(text: "已经最长了，按 ↩ 拷贝") }
    if isLost { return Status(text: "对不上了：往回滚一点，再慢慢滚", tone: .lost) }
    return Status(
      text: isAutoScrolling ? "自动滚动中：按空格或把鼠标移出选区停止" : "在选区里滚动，或按空格自动滚动",
      announces: false)
  }

  private func updateStatus() {
    let status = Self.status(
      notice: notice, isFull: isFull, isLost: isLost, isAutoScrolling: isAutoScrolling)
    panel.hudView.show(
      status.text, tone: status.tone, width: stitcher.width, height: stitcher.outputHeight)
    borderView.update(lost: isLost && !isFull, marching: isAutoScrolling)
    if status.announces, status.text != announced {
      NSAccessibility.post(
        element: panel, notification: .announcementRequested,
        userInfo: [
          .announcement: status.text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
    announced = status.announces ? status.text : nil
  }

  // MARK: 自动滚动

  private func toggleAutoScroll() {
    if isAutoScrolling { return stopAutoScroll() }
    guard !captureStopped else { return NSSound.beep() }
    guard Permissions.isAccessibilityTrusted else {
      Permissions.requestAccessibility()
      notice = Status(text: "自动滚动需要「辅助功能」授权，授权后点 ▶ 开始", tone: .warning)
      return updateStatus()
    }
    // 滚轮事件交给光标下的窗口：光标不在选区里、或停在自家面板上，就挪到选区中间
    let mouse = NSEvent.mouseLocation
    if !NSMouseInRect(mouse, region, false) || NSMouseInRect(mouse, panel.frame, false) {
      let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
      CGWarpMouseCursorPosition(CGPoint(x: region.midX, y: primaryHeight - region.midY))
    }
    direction = stitcher.isGrowingUp ? -1 : 1
    stalls = 0
    lostStreak = 0
    notice = nil
    isAutoScrolling = true
    panel.hudView.isAutoScrolling = true
    updateStatus()
    postScroll(step)  // 先滚一步，下一帧就看得出动没动
  }

  private func stopAutoScroll() {
    guard isAutoScrolling else { return }
    isAutoScrolling = false
    panel.hudView.isAutoScrolling = false
    updateStatus()
  }

  /// 拿到上一步的结果再滚下一步：滚过头（对不上）就退回、步子减半，连续对不上就停；连着几步不动就是到头了
  private func autoScroll(after outcome: ScrollStitcher.Outcome) {
    let mouse = NSEvent.mouseLocation
    // 光标在面板附近（去点 ⏸、看预览）：先不滚（滚轮会落到面板上），也不算停
    if NSMouseInRect(mouse, panel.frame.insetBy(dx: -16, dy: -16), false) { return }
    // 光标移出选区 = 想停下（也免得滚到别的窗口）
    guard NSMouseInRect(mouse, region, false) else { return stopAutoScroll() }
    switch outcome {
    case .moved:
      stalls = 0
      lostStreak = 0
      let shift = CGFloat(stitcher.lastShift)
      if lastPosted != 0, (shift > 0) != (lastPosted * direction > 0) { wheelSign = -wheelSign }
      // 目标：每步滚出选区高度的 40%（像素），按这一步实际滚了多少调步长
      step = min(max(step * region.height * scale * 0.4 / abs(shift), 20), region.height * 0.8)
    case .lost:
      lostStreak += 1
      if lostStreak >= 4 {
        notice = Status(text: "对不上，已停止自动滚动", tone: .lost)
        return stopAutoScroll()
      }
      step = max(step / 2, 20)
      return postScroll(-step)
    case .full:
      return stopAutoScroll()
    case .unchanged:
      stalls += 1
      if stalls >= 3 {
        notice = Status(text: direction > 0 ? "已经滚到底了" : "已经滚到顶了")
        return stopAutoScroll()
      }
    }
    postScroll(step)
  }

  /// 按方向滚 points 点（负数往回滚）。像素级滚动事件，发到 HID 层：和真滚轮一样交给光标下的窗口
  private func postScroll(_ points: CGFloat) {
    lastPosted = points
    // wheel1 为负是内容往上走（往下滚）
    let delta = Int32((-points * direction * wheelSign).rounded())
    CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0,
      wheel3: 0)?
      .post(tap: .cghidEventTap)
  }

  // MARK: 结束

  private func finish(_ action: Action?) {
    guard let continuation else { return }
    self.continuation = nil
    loop?.cancel()
    isAutoScrolling = false
    border.orderOut(nil)
    panel.orderOut(nil)
    let result = action.flatMap { action in
      stitcher.makeImage().map { Result(image: $0, scale: scale, action: action) }
    }
    continuation.resume(returning: result)
  }

  /// 选区外一圈 2 点的边框（窗口外扩 ScrollBorderView.margin 给外发光）：不接鼠标（滚轮直接落到下面的窗口）。
  /// 录屏的边框也用它（ScreenRecorder，另加 .canJoinAllSpaces）：状态栏层级、普通 NSPanel，截图冻结帧和录制都自动排除
  static func makeBorder(around region: CGRect, view: ScrollBorderView) -> NSPanel {
    let margin = ScrollBorderView.margin
    let panel = NSPanel(
      contentRect: region.insetBy(dx: -margin, dy: -margin),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // 状态栏层级：低于它的无边框窗口会被 AppKit 挪到菜单栏下面，选区贴着屏幕顶时边框就画进内容里了
    panel.level = .statusBar
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.contentView = view
    return panel
  }
}

/// 选区边框：2 pt 品牌粉线画在选区外 1 pt（不压内容），外发光 1.2 s 呼吸；自动滚动时换成虚线 [8, 6] 0.5 s 走一轮
/// （呼吸停在中间值：同一表面同时只有一个循环动画）；对不上时变橙。录屏用静止的一份（animates: false，发光停在中间值，
/// 同减弱动态效果）：录制表面的 ambient 留给第 2 批 HUD 的红点
final class ScrollBorderView: NSView {
  /// 窗口比选区每边大这么多：线 2 pt + 发光
  static let margin: CGFloat = 14
  private let line = CAShapeLayer()
  private let animates: Bool
  private var lost = false
  private var marching = false

  init(animates: Bool = true) {
    self.animates = animates
    super.init(frame: .zero)
    wantsLayer = true
    line.fillColor = nil
    line.lineWidth = 2
    line.shadowOffset = .zero
    line.shadowRadius = 6
    layer?.addSublayer(line)
    applyColor()
    applyAmbient()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    line.frame = bounds
    line.contentsScale = window?.backingScaleFactor ?? 2
    let inset = Self.margin - 1
    let path = CGPath(rect: bounds.insetBy(dx: inset, dy: inset), transform: nil)
    line.path = path
    // 发光按实线描边的轮廓给 shadowPath（Whisker §3）：不然呼吸的每一帧都要按图层内容离屏算一遍整框的阴影。
    // 蚂蚁线时发光也是整圈实线（静止在中间值）
    line.shadowPath = path.copy(
      strokingWithWidth: line.lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    CATransaction.commit()
  }

  func update(lost: Bool, marching: Bool) {
    if lost != self.lost {
      self.lost = lost
      applyColor()
    }
    guard marching != self.marching else { return }
    self.marching = marching
    applyAmbient()
  }

  /// 唯一的循环动画：自动滚动时蚂蚁线（发光停在呼吸的中间值），平时发光呼吸；减弱动态效果时都静止
  private func applyAmbient() {
    line.removeAnimation(forKey: "breathe")
    line.removeAnimation(forKey: "march")
    let reduced = Style.reduceMotion || !animates
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    line.lineDashPattern = marching ? [8, 6] : nil
    line.shadowOpacity = reduced || marching ? 0.4 : 0.25
    CATransaction.commit()
    guard !reduced else { return }
    if marching {
      let march = CABasicAnimation(keyPath: "lineDashPhase")
      march.fromValue = 0
      march.toValue = -14
      march.duration = 0.5
      march.repeatCount = .infinity
      line.add(march, forKey: "march")
    } else {
      let breathe = CABasicAnimation(keyPath: "shadowOpacity")
      breathe.fromValue = 0.25
      breathe.toValue = 0.6
      breathe.duration = 1.2
      breathe.autoreverses = true
      breathe.repeatCount = .infinity
      breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      line.add(breathe, forKey: "breathe")
    }
  }

  private func applyColor() {
    let color = (lost ? NSColor.systemOrange : Style.Shot.accent).cgColor
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.2)
    line.strokeColor = color
    line.shadowColor = color
    CATransaction.commit()
  }
}

/// 长截图的面板窗口。无边框窗口默认当不了 key（收不到 Esc、↩、空格），所以要子类化
final class ScrollCapturePanel: NSPanel {
  let hudView: ScrollCaptureHUD

  /// 贴在选区右边、和选区一样高（放不下放左边；两边都放不下就以固定高度放进选区右上角，别盖住一整列内容），
  /// 和选区顶边对齐
  init(region: CGRect, screen: NSScreen) {
    hudView = ScrollCaptureHUD()
    let visible = screen.visibleFrame
    let gap: CGFloat = 10
    let width = ScrollCaptureHUD.width
    var x = region.maxX + gap
    if x + width > visible.maxX - gap { x = region.minX - gap - width }
    let inside = x < visible.minX + gap
    if inside { x = min(region.maxX, visible.maxX) - gap - width }
    let size = CGSize(
      width: width,
      height: min(inside ? 320 : max(region.height, 260), visible.height - 2 * gap))
    let y = max(
      min(region.maxY - (inside ? gap : 0), visible.maxY - gap) - size.height, visible.minY + gap)
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    level = .floating
    collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    isMovableByWindowBackground = true
    // 本 App 从不激活：不设的话按钮的提示（快捷键）永远不出来
    allowsToolTipsWhenApplicationIsInactive = true
    contentView = hudView
    initialFirstResponder = hudView
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// 面板内容：预览（最近拼上的那头）、状态、高度、按钮（自动滚动、取消、另存为…、存储、拷贝）。按键也在这里收。
/// 永远深色的 HUD 皮肤（和截图工具栏一致）：普通 NSView 包一层材质。15 是 `.hudWindow` 的毛玻璃，圆角裁切、描边、
/// 内圈 rim 都在毛玻璃自己的图层上（和它以前自己就是 NSVisualEffectView 时一样，外层只是透明的壳）；
/// macOS 26 起是液态玻璃（mac-whisker §2「26 分支」）
final class ScrollCaptureHUD: NSView {
  enum Item {
    case toggleAuto, cancel
    case output(ScrollCapture.Action)
  }

  /// 状态文字的样子（体检 B42）：平常（含正常结束）次要文字色；缺授权、截屏失败橙色；对不上橙色，刚变成对不上时抖一下
  enum Tone { case normal, warning, lost }

  static let width: CGFloat = 216
  /// 预览上下渐隐的高度
  private static let fade: CGFloat = 18

  var onAction: (Item) -> Void = { _ in }
  var isAutoScrolling = false {
    didSet {
      autoButton.image = Self.symbol(isAutoScrolling ? "pause.fill" : "play.fill")
      autoButton.contentTintColor = isAutoScrolling ? Style.Shot.accent : Style.HUD.text
    }
  }
  private let preview = NSImageView()
  private let fadeMask = CAGradientLayer()
  /// 接缝处的品牌粉闪光（每拼上一段）
  private let seam = CAGradientLayer()
  /// HUD 内圈描边（外圈是毛玻璃图层的边；26 不画）
  private let rim = CALayer()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let reading = HeightReading()
  private var autoButton = NSButton()
  private var buttons: [(item: Item, button: NSButton)] = []
  /// 上次预览时长图的高度（像素）：算这次往前推了多少
  private var previewedHeight = 0
  private var lastTone = Tone.normal

  init() {
    // 材质：15 是毛玻璃，26 是液态玻璃；内容放进 surface：15 就是材质本身（vibrancy 和原来一样），26 是玻璃的 contentView
    let material: NSView
    let surface: NSView
    if #available(macOS 26, *) {
      // 液态玻璃：圆角交给玻璃，不画描边（两个无障碍开关交给它）；HUD 永远深色
      let glass = NSGlassEffectView()
      glass.cornerRadius = Style.Radius.panel
      glass.appearance = NSAppearance(named: .darkAqua)
      surface = NSView()
      surface.autoresizingMask = [.width, .height]  // 玻璃按 Auto Layout 撑满它；掩码和那组约束一致
      glass.contentView = surface
      material = glass
    } else {
      let effect = NSVisualEffectView()
      effect.material = .hudWindow
      effect.blendingMode = .behindWindow
      effect.state = .active  // 本 App 从不激活，跟随窗口状态会一直是灰的
      effect.appearance = NSAppearance(named: .vibrantDark)
      effect.wantsLayer = true
      effect.layer?.cornerRadius = Style.Radius.panel
      effect.layer?.cornerCurve = .continuous
      effect.layer?.masksToBounds = true
      // HUD 描边：外 0.5 pt black 0.5（图层边）+ 内 0.5 pt white 0.14（往里 0.5，增强对比度时 1 pt white 0.35）
      effect.layer?.borderWidth = 0.5
      effect.layer?.borderColor = Style.HUD.outerStroke.cgColor
      surface = effect
      material = effect
    }
    super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 260))
    wantsLayer = true
    material.frame = bounds
    material.autoresizingMask = [.width, .height]
    addSubview(material)
    rim.cornerRadius = Style.Radius.panel - 0.5
    rim.cornerCurve = .continuous
    rim.borderWidth = Style.HUD.strokeWidth
    rim.borderColor = Style.HUD.innerStroke.cgColor

    preview.imageScaling = .scaleProportionallyDown
    preview.imageAlignment = .alignTop
    preview.wantsLayer = true
    preview.layer?.cornerRadius = Style.Radius.control
    preview.layer?.cornerCurve = .continuous
    preview.layer?.masksToBounds = true
    preview.layer?.backgroundColor = Style.HUD.chipFill.cgColor
    fadeMask.colors = [
      NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor,
    ]
    preview.layer?.mask = fadeMask
    seam.colors = [Style.Shot.accent.cgColor, Style.Shot.accent.withAlphaComponent(0).cgColor]
    seam.opacity = 0
    preview.layer?.addSublayer(seam)
    preview.setContentCompressionResistancePriority(.init(1), for: .vertical)
    preview.setContentHuggingPriority(.init(1), for: .vertical)

    status.font = .systemFont(ofSize: 11)
    status.textColor = Style.HUD.secondaryText
    status.alignment = .center
    status.maximumNumberOfLines = 2
    status.isSelectable = false  // 可选中的话点一下就被字段编辑器抢走第一响应者，Esc / ↩ / 空格全失灵
    status.wantsLayer = true
    status.setContentCompressionResistancePriority(.required, for: .vertical)
    let readingView = NSHostingView(rootView: HeightReadingView(reading: reading))
    readingView.sizingOptions = [.intrinsicContentSize]

    // 截图家族同一套叫法（体检 B41）：拷贝 / 存储到「桌面」（访达里的名字，不写 Desktop）/ 另存为…
    let items: [(Item, String, String)] = [
      (.toggleAuto, "play.fill", "自动滚动（空格）"),
      (.cancel, "xmark", "取消（Esc）"),
      (.output(.saveAs), "square.and.arrow.down.on.square", "另存为…（⇧⌘S）"),
      (.output(.save), "square.and.arrow.down", ScreenshotOutput.saveTitle + "（⌘S）"),
      (.output(.copy), "checkmark", "拷贝（↩）"),
    ]
    var row: [NSView] = []
    for (index, (item, symbol, tip)) in items.enumerated() {
      if index == 1 { row.append(barSeparator()) }
      // 拷贝是主按钮：和截图工具栏的拷贝钮一样，28 pt 品牌粉实心圆 + 白对勾
      let primary = index == items.count - 1
      let button = barButton(
        primary ? Self.primaryImage() : Self.symbol(symbol), tip: tip,
        action: #selector(clicked(_:)),
        size: primary ? CGSize(width: 28, height: 28) : CGSize(width: 30, height: 28))
      button.tag = buttons.count
      button.contentTintColor = Style.HUD.text
      button.showsHover = !primary  // 粉圆是图，悬停底会在圆后面露出一块方角
      buttons.append((item, button))
      row.append(button)
    }
    autoButton = buttons[0].button
    let bar = NSStackView(views: row)
    bar.spacing = 2
    for view in [status, readingView, bar] as [NSView] {
      view.setContentHuggingPriority(.required, for: .vertical)
    }

    let stack = NSStackView(views: [preview, readingView, status, bar])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.distribution = .fill  // 预览（抗拉伸优先级最低）吃掉剩下的高度
    stack.spacing = 6
    stack.setCustomSpacing(2, after: readingView)
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
      stack.topAnchor.constraint(equalTo: surface.topAnchor),
      stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
      preview.widthAnchor.constraint(equalToConstant: Self.width - 20),
      status.widthAnchor.constraint(equalToConstant: Self.width - 20),
    ])
    // 盖在内容上面（只是一圈 0.5 pt，挨着边，碰不到内容）
    if #unavailable(macOS 26) { surface.layer?.addSublayer(rim) }
  }

  override func layout() {
    super.layout()
    layoutFade()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rim.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    CATransaction.commit()
  }

  /// 渐隐蒙版跟着预览的大小走（布局时和每次更新预览时都设，免得蒙版是 0 大小把预览整个遮掉）
  private func layoutFade() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let bounds = preview.bounds
    fadeMask.frame = bounds
    let edge = NSNumber(value: Double(min(Self.fade / max(bounds.height, 1), 0.3)))
    fadeMask.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
    CATransaction.commit()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if trackingAreas.isEmpty {
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
          owner: self))
    }
  }

  /// 点过目标 App 后面板就不是 key 了：鼠标移回面板就拿回键盘（不激活本 App，前台 App 不变）
  override func mouseEntered(with event: NSEvent) {
    if window?.isKeyWindow == false { window?.makeKey() }
  }

  /// tone：平常 / 要注意（缺授权、截屏失败，橙色）/ 对不上（橙色，刚变成对不上时抖一下 0.35 s）
  func show(_ text: String, tone: Tone = .normal, width: Int, height: Int) {
    status.stringValue = text
    status.textColor = tone == .normal ? Style.HUD.secondaryText : .systemOrange
    if tone == .lost, lastTone != .lost, !Style.reduceMotion, let layer = status.layer {
      let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
      shake.values = [0, -6, 6, -4, 4, 0]
      shake.duration = 0.35
      layer.add(shake, forKey: "shake")
    }
    lastTone = tone
    reading.width = width
    reading.height = height
  }

  func updatePreview(stitcher: ScrollStitcher, scale: CGFloat) {
    let box = preview.bounds.size
    guard box.width > 0, box.height > 0,
      let image = stitcher.preview(
        width: Int(box.width * scale), maxHeight: Int(box.height * scale))
    else { return }
    layoutFade()
    let growingUp = stitcher.isGrowingUp
    preview.imageAlignment = growingUp ? .alignBottom : .alignTop
    preview.image = NSImage(
      cgImage: image,
      size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    let grown = stitcher.outputHeight - previewedHeight
    previewedHeight = stitcher.outputHeight
    guard grown > 0, !Style.reduceMotion, let layer = preview.layer else { return }
    // 纸带：预览已经撑满时，新内容从长的那头推进来（旧内容先停在原位，再滑过去）
    let shift = CGFloat(grown) * box.width / CGFloat(max(stitcher.width, 1))
    if CGFloat(image.height) / scale >= box.height - 1 {
      let slide = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
      slide.fromValue = growingUp ? min(shift, box.height) : -min(shift, box.height)
      slide.toValue = 0
      slide.duration = 0.2
      slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
      layer.add(slide, forKey: "tape")
    }
    // 接缝闪一下：强调色 0.25 → 0，从长的那头往里渐隐 24 pt
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let height: CGFloat = 24
    seam.frame = CGRect(
      x: 0, y: growingUp ? box.height - height : 0, width: box.width, height: height)
    seam.startPoint = CGPoint(x: 0.5, y: growingUp ? 1 : 0)
    seam.endPoint = CGPoint(x: 0.5, y: growingUp ? 0 : 1)
    CATransaction.commit()
    let flash = CABasicAnimation(keyPath: "opacity")
    flash.fromValue = 0.25
    flash.toValue = 0
    flash.duration = 0.4
    seam.add(flash, forKey: "flash")
  }

  @objc private func clicked(_ sender: NSButton) { onAction(buttons[sender.tag].item) }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection([.command, .control, .option])
    switch Int(event.keyCode) {
    case kVK_Escape: onAction(.cancel)
    case kVK_Return where flags.isEmpty, kVK_ANSI_KeypadEnter where flags.isEmpty:
      onAction(.output(.copy))
    case kVK_Space where flags.isEmpty:
      if !event.isARepeat { onAction(.toggleAuto) }  // 按住不放不反复开关
    default: super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    switch (Int(event.keyCode), flags) {
    case (kVK_ANSI_C, .command): onAction(.output(.copy))
    case (kVK_ANSI_S, .command): onAction(.output(.save))
    case (kVK_ANSI_S, [.command, .shift]): onAction(.output(.saveAs))
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  private static func symbol(_ name: String) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)!
  }

  /// 粉圆 + 白对勾画成一张图：按钮的图层比 28 pt 的对齐矩形高，直接给图层上底色会变成竖胶囊（实测）。
  /// 画图闭包在绘制时才跑（不保证在主 actor 上）：用到的值先取出来
  private static func primaryImage() -> NSImage {
    let fill = Style.Shot.accent
    let check = symbol("checkmark").withSymbolConfiguration(
      .init(pointSize: 13, weight: .bold).applying(.init(paletteColors: [Style.Shot.onAccent])))!
    return NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
      fill.setFill()
      NSBezierPath(ovalIn: rect).fill()
      let size = check.size
      check.draw(
        in: NSRect(
          x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
          height: size.height))
      return true
    }
  }
}

/// 长图的高度读数（SwiftUI：数字滚动变化）
@Observable final class HeightReading {
  var width = 0
  var height = 0
}

private struct HeightReadingView: View {
  let reading: HeightReading
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      Text(reading.height, format: .number.grouping(.never))
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .contentTransition(.numericText(value: Double(reading.height)))
        .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: reading.height)
      Text("像素高 · 宽 \(String(reading.width))")
        .font(.system(size: 10))
        .foregroundStyle(Color(nsColor: Style.HUD.tertiaryText))
    }
    .foregroundStyle(Color(nsColor: Style.HUD.text))
    .accessibilityElement(children: .combine)
  }
}
