// 长截图会话：截图框选后按 S（或工具栏按钮）进入。遮罩收起、露出实时画面，选区外画一圈边框，旁边一个面板
// （拼接预览、状态、按钮）。用户在选区里滚动（滚轮、触控板都行），或按空格自动滚动；一直用 ScreenCaptureKit
// 截选区（滤掉本 App 的所有窗口），交给 ScrollStitcher 拼。↩ 复制、⌘S 保存、⇧⌘S 另存为，Esc 取消。
// 边框和面板是不激活前台的 NSPanel（面板要当 key 收按键），会话结束立即释放；前台 App 一直不变。

import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

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
  /// 截屏出错，抓帧循环已经停了（只剩复制、保存和取消）
  private var captureStopped = false

  private init(region: CGRect, screen: NSScreen) async throws {
    scale = screen.backingScaleFactor
    // 对齐到像素，夹进这块屏
    let frame = screen.frame
    let local = region.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
    let snapped = CGRect(
      x: (local.minX * scale).rounded() / scale, y: (local.minY * scale).rounded() / scale,
      width: (local.width * scale).rounded() / scale,
      height: (local.height * scale).rounded() / scale)
    self.region = snapped.offsetBy(dx: frame.minX, dy: frame.minY)
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let displayID =
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
      .uint32Value
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw CaptureError.noDisplay
    }
    // 滤掉本 App 的全部窗口（含之后才建的边框和面板）
    filter = SCContentFilter(
      display: display,
      excludingApplications: content.applications.filter { $0.processID == getpid() },
      exceptingWindows: [])
    configuration = SCStreamConfiguration()
    // sourceRect：屏内坐标，点，原点在左上
    configuration.sourceRect = CGRect(
      x: snapped.minX, y: frame.height - snapped.maxY, width: snapped.width,
      height: snapped.height)
    configuration.width = Int((snapped.width * scale).rounded())
    configuration.height = Int((snapped.height * scale).rounded())
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
    border = Self.makeBorder(around: self.region)
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
        notice = "截屏失败，已停止：\(error.localizedDescription)"
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
  private var notice: String?
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

  private func updateStatus() {
    var text = isAutoScrolling ? "自动滚动中：按空格或把鼠标移出选区停止" : "在选区里滚动，或按空格自动滚动"
    var warning = true
    if let notice {
      text = notice
    } else if isFull {
      text = "已经最长了，按 ↩ 复制"
    } else if isLost {
      text = "对不上了：往回滚一点，再慢慢滚"
    } else {
      warning = false
    }
    panel.hudView.show(
      text, warning: warning, size: "\(stitcher.width) × \(stitcher.outputHeight) 像素")
  }

  // MARK: 自动滚动

  private func toggleAutoScroll() {
    if isAutoScrolling { return stopAutoScroll() }
    guard !captureStopped else { return NSSound.beep() }
    guard Permissions.isAccessibilityTrusted else {
      Permissions.requestAccessibility()
      notice = "自动滚动需要「辅助功能」授权，授权后点 ▶ 开始"
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
        notice = "对不上，已停止自动滚动"
        return stopAutoScroll()
      }
      step = max(step / 2, 20)
      return postScroll(-step)
    case .full:
      return stopAutoScroll()
    case .unchanged:
      stalls += 1
      if stalls >= 3 {
        notice = direction > 0 ? "已经滚到底了" : "已经滚到顶了"
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

  /// 选区外一圈 2 点的边框：不接鼠标（滚轮直接落到下面的窗口）
  private static func makeBorder(around region: CGRect) -> NSPanel {
    let panel = NSPanel(
      contentRect: region.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    // 状态栏层级：低于它的无边框窗口会被 AppKit 挪到菜单栏下面，选区贴着屏幕顶时边框就画进内容里了
    panel.level = .statusBar
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let view = NSView()
    view.wantsLayer = true
    view.layer?.borderWidth = 2
    view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    panel.contentView = view
    return panel
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

/// 面板内容：预览（最近拼上的那头）、状态、按钮（自动滚动、取消、另存为、保存、复制）。按键也在这里收
final class ScrollCaptureHUD: NSVisualEffectView {
  enum Item {
    case toggleAuto, cancel
    case output(ScrollCapture.Action)
  }

  static let width: CGFloat = 200

  var onAction: (Item) -> Void = { _ in }
  var isAutoScrolling = false {
    didSet {
      autoButton.image = Self.symbol(isAutoScrolling ? "pause.fill" : "play.fill")
      autoButton.contentTintColor = isAutoScrolling ? .controlAccentColor : .labelColor
    }
  }
  private let preview = NSImageView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let sizeLabel = NSTextField(labelWithString: "")
  private var autoButton = NSButton()
  private var buttons: [(item: Item, button: NSButton)] = []

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 260))
    material = .popover
    blendingMode = .behindWindow
    state = .active  // 本 App 从不激活，跟随窗口状态会一直是灰的
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.masksToBounds = true

    preview.imageScaling = .scaleProportionallyDown
    preview.imageAlignment = .alignTop
    preview.wantsLayer = true
    preview.layer?.borderWidth = 1
    preview.layer?.borderColor = NSColor.separatorColor.cgColor
    preview.layer?.cornerRadius = 4
    preview.setContentCompressionResistancePriority(.init(1), for: .vertical)
    preview.setContentHuggingPriority(.init(1), for: .vertical)

    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.alignment = .center
    status.maximumNumberOfLines = 2
    status.isSelectable = false  // 可选中的话点一下就被字段编辑器抢走第一响应者，Esc / ↩ / 空格全失灵
    status.setContentCompressionResistancePriority(.required, for: .vertical)
    sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    sizeLabel.textColor = .tertiaryLabelColor

    let items: [(Item, String, String)] = [
      (.toggleAuto, "play.fill", "自动滚动（空格）"),
      (.cancel, "xmark", "取消（Esc）"),
      (.output(.saveAs), "square.and.arrow.down.on.square", "另存为…（⇧⌘S）"),
      (
        .output(.save), "square.and.arrow.down",
        "保存到「\(ScreenshotOutput.saveDirectory.lastPathComponent)」（⌘S）"
      ),
      (.output(.copy), "checkmark", "复制（↩）"),
    ]
    var row: [NSView] = []
    for (index, (item, symbol, tip)) in items.enumerated() {
      if index == 1 { row.append(barSeparator()) }
      let button = barButton(Self.symbol(symbol), tip: tip, action: #selector(clicked(_:)))
      button.tag = buttons.count
      buttons.append((item, button))
      row.append(button)
    }
    autoButton = buttons[0].button
    buttons.last?.button.contentTintColor = .controlAccentColor
    let bar = NSStackView(views: row)
    bar.spacing = 2
    for view in [status, sizeLabel, bar] as [NSView] {
      view.setContentHuggingPriority(.required, for: .vertical)
    }

    let stack = NSStackView(views: [preview, status, sizeLabel, bar])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.distribution = .fill  // 预览（抗拉伸优先级最低）吃掉剩下的高度
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      preview.widthAnchor.constraint(equalToConstant: Self.width - 16),
      status.widthAnchor.constraint(equalToConstant: Self.width - 16),
    ])
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

  func show(_ text: String, warning: Bool, size: String) {
    status.stringValue = text
    status.textColor = warning ? .systemOrange : .secondaryLabelColor
    sizeLabel.stringValue = size
  }

  func updatePreview(stitcher: ScrollStitcher, scale: CGFloat) {
    let box = preview.bounds.size
    guard box.width > 0, box.height > 0,
      let image = stitcher.preview(
        width: Int(box.width * scale), maxHeight: Int(box.height * scale))
    else { return }
    preview.imageAlignment = stitcher.isGrowingUp ? .alignBottom : .alignTop
    preview.image = NSImage(
      cgImage: image,
      size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
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
}
