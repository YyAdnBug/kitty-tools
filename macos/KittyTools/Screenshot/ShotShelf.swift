// CleanShot 式常驻缩略图（Whisker D8）：截图飞到右下角、角标弹完以后由这里接手，留在原地（同一个位置、同样的圆角阴影）。
// 悬停时出 HUD 操作：中间「拷贝」「存储」两个胶囊，左上关闭、右下钉图（右上角是品牌粉角标），存过的左下「在访达中显示」；
// 拖出去是一个 PNG 文件（拖进访达、邮件、聊天窗口），双击用默认 App 打开；触控板往右扫跟手，松手时扫得够远或够快就滑走、否则弹回；
// 鼠标不在上面时 6 s 后自己滑走（移开后 2.5 s）。同一块屏上连截几张时往上叠，最多 3 张，更早的滑走。
// 窗口是普通 NSPanel 实例（不当 key、不激活本 App；层级状态栏，之后的截图冻结帧会排除它），用完放回复用池
// （挂过 NSHostingView 的窗口 close 后 AppKit 不释放，同 FlyCard）。减弱动态效果时不飞，直接在角落淡入、淡出。
// 卡片只留缩到卡片大小的图和复制 / 保存时编码好的 PNG（不再编码一遍，也不留整张解码的图：5K 一张 59 MB、长截图上百 MB），
// 钉图时才解码；拖出用的临时 PNG 在主线程外写。
// 录屏（第 3 批，拍板 R11-a）的视频卡是同一种卡片的另一种内容（ShelfCard.Kind.video）：图是最后一帧（取不到就是 HUD 底色）、
// 多了播放符号和时长；文件已经存好了，悬停只有「拷贝」（拷的是文件，进剪贴板历史）和关闭 / 在访达中显示，双击用默认 App 打开，
// 拖出去就是那个文件，右键多「打开」「移到废纸篓」（能放回，不二次确认）。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ShotShelf {
  /// 再拷贝一次 / 快速保存（都用编码好的 PNG）/ 钉到原来的位置 / 拷贝录屏文件（AppDelegate 给）
  var copy: (Data) async -> Bool = { _ in false }
  var save: (Data) async -> URL? = { _ in nil }
  var pin: (CGImage, CGRect) -> Void = { _, _ in }
  var copyFile: (URL) -> Void = { _ in }
  /// 刘海岛（AppDelegate 给）：缩略图看起来没变的结果（再拷贝、存到同一个文件夹）、文件已不在时用它说
  var island: Island?

  private(set) var cards: [ShelfCard] = []
  private var idle: [NSPanel] = []
  /// 卡片四周给阴影留的边（窗口比卡片大这么多）
  static let margin: CGFloat = 24
  private static let gap: CGFloat = 10
  private static let maxPerScreen = 3
  /// 拖出去用的 PNG 放在这里；启动时清空（拖进邮件、聊天的附件可能还在读，用的时候不删）
  static let dragDirectory = FileManager.default.temporaryDirectory.appending(
    path: "Kitty Tools 截图")

  /// 接手一张截图：png 是复制 / 保存时编码好的，rect 是落地位置（屏幕坐标），source 是选区（钉图钉回那里）
  func add(
    _ image: CGImage, png: Data, scale: CGFloat, source: CGRect, at rect: CGRect,
    badge: FlyCard.Badge
  ) {
    insert(at: rect) { screen, panel in
      ShelfCard(
        image: image, png: png, scale: scale, source: source, rect: rect, badge: badge,
        screen: screen, panel: panel, shelf: self)
    }
  }

  /// 接手一段录屏（已存进快速保存目录的文件、时长、最后一帧）。fadesIn：没飞过来（减弱动态效果、没取到最后一帧）时在角落淡入
  func add(
    video url: URL, seconds: Int, poster: CGImage?, source: CGRect, at rect: CGRect,
    fadesIn: Bool
  ) {
    insert(at: rect, fadesIn: fadesIn) { screen, panel in
      ShelfCard(
        video: url, seconds: seconds, poster: poster, source: source, rect: rect, screen: screen,
        panel: panel, shelf: self)
    }
  }

  /// 同一块屏上已有的往上挪给新的让位；超过 3 张的最早那张滑走（截图、录屏混着叠）
  private func insert(
    at rect: CGRect, fadesIn: Bool = Style.reduceMotion,
    _ make: (NSScreen?, NSPanel) -> ShelfCard
  ) {
    let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
    let neighbours = cards.filter { !$0.isLeaving && $0.screen == screen }
    for card in neighbours { card.shift(by: rect.height + Self.gap) }
    if neighbours.count >= Self.maxPerScreen, let oldest = neighbours.first { dismiss(oldest) }
    let card = make(screen, idle.popLast() ?? Self.makePanel())
    cards.append(card)
    card.show(fadingIn: fadesIn)
  }

  func dismiss(_ card: ShelfCard) {
    guard !card.isLeaving else { return }
    card.isLeaving = true
    // 在它上面的往下落回来
    for other in cards
    where !other.isLeaving && other.screen == card.screen
      && other.rect.minY > card.rect.minY
    {
      other.shift(by: -(card.rect.height + Self.gap))
    }
    card.slideOut { [weak self, weak card] in
      guard let self, let card else { return }
      cards.removeAll { $0 === card }
      let panel = card.panel
      panel.close()
      // 下一轮再拆视图：别在它自己的 SwiftUI 任务里把它释放
      Task {
        panel.contentView = nil
        self.idle.append(panel)
      }
    }
  }

  /// 长截图开始（体检 B40）：压在选区上的缩略图直接收走（层级在状态栏，会挡住滚轮和自动滚动）
  func dismiss(covering region: CGRect) {
    // 一张张收：收走一张时上面的会落到它的位置，落下来的也可能压在选区上，收到没有相交的为止
    // （dismiss 每次都把 isLeaving 置真，循环一定会结束）
    while let card = cards.first(where: { !$0.isLeaving && $0.rect.intersects(region) }) {
      dismiss(card)
    }
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    return panel
  }
}

/// 一张常驻缩略图：窗口、界面状态、自动滑走的计时
@Observable final class ShelfCard {
  /// 卡片装的是什么（第 5 批录音再加一种）
  enum Kind: Equatable {
    /// 截图：PNG / 原图在下面的 png、image 里
    case image
    /// 录屏：快速保存目录里的文件和时长（秒）
    case video(URL, seconds: Int)
  }

  /// 右键菜单和 VoiceOver 自定义动作（同一份 menu）
  enum Command {
    case copy, save, pin, open, reveal, trash, close

    var title: String {
      switch self {
      case .copy: "拷贝"
      case .save: "存储"
      case .pin: "钉图"
      case .open: "打开"
      case .reveal: "在访达中显示"
      case .trash: "移到废纸篓"
      case .close: "关闭"
      }
    }
  }

  let kind: Kind
  /// 显示的部分（长截图只露开头一屏；缩到卡片尺寸）；录屏没取到最后一帧时 nil（HUD 底色 + 播放符号占位）
  let shown: CGImage?
  let scale: CGFloat
  /// 原图的像素尺寸（钉图按它的宽高比）
  @ObservationIgnored private let pixels: CGSize
  /// 编码好的 PNG（拷贝、存储、拖出、钉图都从它来）；没给时先留着原图，第一次用到时在主线程外编码、编完就放掉原图
  @ObservationIgnored private var png: Data?
  @ObservationIgnored private var image: CGImage?
  let source: CGRect
  @ObservationIgnored let screen: NSScreen?
  @ObservationIgnored let panel: NSPanel
  @ObservationIgnored private weak var shelf: ShotShelf?
  /// 卡片的屏幕位置（不含阴影边）
  @ObservationIgnored private(set) var rect: CGRect
  @ObservationIgnored var isLeaving = false
  var badge: FlyCard.Badge
  var isHovered = false { didSet { isHovered ? timer?.cancel() : scheduleDismiss(after: 2.5) } }
  /// 正在拷贝 / 保存（按钮转圈）
  var isBusy = false
  /// 拖出去用的文件：存过就是存的那个，否则是临时目录里编码好的 PNG
  @ObservationIgnored private(set) var fileURL: URL?
  @ObservationIgnored private var timer: Task<Void, Never>?
  /// 触控板横扫时跟手的偏移，和最近一次非零位移与它的时间（松手前还在快速往右 = 甩出去；停住再松手不算）
  @ObservationIgnored private var swipe: CGFloat = 0
  @ObservationIgnored private var lastSwipe: (delta: CGFloat, time: CFTimeInterval) = (0, 0)

  init(
    image: CGImage, png: Data? = nil, scale: CGFloat, source: CGRect, rect: CGRect,
    badge: FlyCard.Badge, screen: NSScreen?, panel: NSPanel, shelf: ShotShelf
  ) {
    kind = .image
    self.png = png
    self.image = png == nil ? image : nil
    pixels = CGSize(width: image.width, height: image.height)
    shown = FlyCard.cardImage(
      of: image, frame: source, size: rect.size, backingScale: screen?.backingScaleFactor ?? 2)
    self.scale = scale
    self.source = source
    self.rect = rect
    self.badge = badge
    self.screen = screen
    self.panel = panel
    self.shelf = shelf
    if case .saved(let url) = badge { fileURL = url }
  }

  /// 录屏：文件已在快速保存目录（角标是它的文件夹），poster 是最后一帧（和飞行卡片同样缩到卡片尺寸，交接时像素一样）
  init(
    video url: URL, seconds: Int, poster: CGImage?, source: CGRect, rect: CGRect,
    screen: NSScreen?, panel: NSPanel, shelf: ShotShelf
  ) {
    let backing = screen?.backingScaleFactor ?? 2
    kind = .video(url, seconds: seconds)
    scale = backing
    shown = poster.map {
      FlyCard.cardImage(of: $0, frame: source, size: rect.size, backingScale: backing)
    }
    pixels = .zero
    self.source = source
    self.rect = rect
    badge = .saved(url)
    self.screen = screen
    self.panel = panel
    self.shelf = shelf
    fileURL = url
  }

  /// 旁白里卡片的名字
  var accessibilityName: String {
    switch kind {
    case .image: "截图缩略图"
    case .video(_, let seconds): "录屏，" + ScreenRecorder.spoken(seconds)
    }
  }

  /// 右键菜单（一节一组，节间分隔线）：截图「拷贝 / 存储 / 钉图 /（存过的）在访达中显示 ｜ 关闭」；
  /// 录屏「拷贝 / 打开 / 在访达中显示 ｜ 移到废纸篓 ｜ 关闭」（已经存了，没有存储；不是图，没有钉图）
  var menu: [[Command]] {
    switch kind {
    case .image:
      let saved = if case .saved = badge { true } else { false }
      return [[.copy, .save, .pin] + (saved ? [.reveal] : []), [.close]]
    case .video:
      return [[.copy, .open, .reveal], [.trash], [.close]]
    }
  }

  func perform(_ command: Command) {
    switch command {
    case .copy: copyAgain()
    case .save: save()
    case .pin: pin()
    case .open: open()
    case .reveal: revealInFinder()
    case .trash: moveToTrash()
    case .close: close()
    }
  }

  /// fadingIn：没有飞行卡片在同一个位置交接（减弱动态效果、录屏没取到最后一帧）时淡入
  func show(fadingIn: Bool = Style.reduceMotion) {
    let host = ShelfHostingView(rootView: ShelfCardView(card: self))
    host.sizingOptions = []
    host.onHover = { [weak self] in self?.isHovered = $0 }
    host.onSwipe = { [weak self] delta, ended in self?.swiped(delta, ended: ended) }
    panel.contentView = host
    panel.setFrame(rect.insetBy(dx: -ShotShelf.margin, dy: -ShotShelf.margin), display: false)
    // 飞行卡片刚在同一个位置关掉：直接出现就接上了；减弱动态效果时（没有飞）淡入
    panel.alphaValue = fadingIn ? 0 : 1
    panel.orderFrontRegardless()
    if fadingIn {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        panel.animator().alphaValue = 1
      }
    }
    scheduleDismiss(after: 6)
    if fileURL == nil { Task { await writeDragFile() } }
  }

  /// 往上 / 往下挪（叠放让位），glide 的近似
  func shift(by dy: CGFloat) {
    rect.origin.y += dy
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.reduceMotion ? 0 : 0.26
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
      panel.animator().setFrame(
        rect.insetBy(dx: -ShotShelf.margin, dy: -ShotShelf.margin), display: true)
    }
  }

  /// 向右滑出屏幕（0.28 s easeIn）；减弱动态效果时原地淡出
  func slideOut(completion: @escaping @MainActor @Sendable () -> Void) {
    timer?.cancel()
    let exit = (screen?.frame.maxX ?? rect.maxX) - rect.minX + ShotShelf.margin + 10
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.reduceMotion ? 0.2 : 0.28
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      if Style.reduceMotion {
        panel.animator().alphaValue = 0
      } else {
        // y 用逻辑位置：让位的上移动画可能还在半路
        panel.animator().setFrameOrigin(
          CGPoint(x: panel.frame.minX + exit, y: rect.minY - ShotShelf.margin))
      }
    } completionHandler: {
      MainActor.assumeIsolated(completion)
    }
  }

  // MARK: 操作

  func close() { shelf?.dismiss(self) }

  func copyAgain() {
    guard !isBusy, let shelf else { return }
    // 录屏拷的是文件（C8-a：点了才进剪贴板历史）
    if case .video(let url, _) = kind {
      guard exists(url) else { return }
      shelf.copyFile(url)
      shelf.island?.show("已复制录屏", leading: shown.map(Island.thumbnail(of:)) ?? .tone)
      return
    }
    isBusy = true
    Task {
      // 角标不换（存过的还要留着文件夹和「在访达中显示」），缩略图看不出拷没拷上：用刘海说（岛自己也播报）
      if let png = await encoded(), await shelf.copy(png) {
        shelf.island?.show("已复制截图", leading: shown.map(Island.thumbnail(of:)) ?? .tone)
      }
      isBusy = false
    }
  }

  func save() {
    guard !isBusy, let shelf else { return }
    isBusy = true
    Task {
      if let png = await encoded(), let url = await shelf.save(png) {
        // 已经存过同一个文件夹时角标不变，看不出又存了一份
        if case .saved(let old) = badge,
          old.deletingLastPathComponent() == url.deletingLastPathComponent()
        {
          shelf.island?.show(
            "已保存", detail: url.lastPathComponent,
            leading: shown.map(Island.thumbnail(of:)) ?? .tone)
        }
        badge = .saved(url)
        fileURL = url
      }
      isBusy = false
    }
  }

  /// 存过的文件还在不在；被移走 / 删掉了用刘海说（访达、打开都会什么也不做）
  private func exists(_ url: URL) -> Bool {
    guard !FileManager.default.fileExists(atPath: url.path) else { return true }
    shelf?.island?.show(
      "文件已不存在", detail: url.lastPathComponent, tone: .warning, symbol: "questionmark.folder")
    return false
  }

  /// 钉到选区的位置；长截图比选区高得多，按选区宽度钉整张，太高就等比缩到屏幕可见高度的 90%（顶边对齐选区）。
  /// 钉图要整张图：没留原图就从 PNG 解码
  func pin() {
    guard
      let full = image
        ?? png.flatMap({ CGImageSourceCreateWithData($0 as CFData, nil) }).flatMap({
          CGImageSourceCreateImageAtIndex($0, 0, nil)
        })
    else { return }
    let aspect = pixels.height / max(pixels.width, 1)
    var size = CGSize(width: source.width, height: source.width * aspect)
    let visible = screen?.visibleFrame ?? source
    if size.height > visible.height * 0.9 {
      size = CGSize(width: visible.height * 0.9 / aspect, height: visible.height * 0.9)
    }
    let frame = CGRect(
      x: source.minX, y: max(source.maxY - size.height, visible.minY), width: size.width,
      height: size.height)
    shelf?.pin(full, frame)
    close()
  }

  func revealInFinder() {
    if case .saved(let url) = badge, exists(url) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  /// 录屏移到废纸篓（能放回，13 条默认细节：不二次确认）：成功后卡片收起，岛说一声
  func moveToTrash() {
    guard case .video(let url, _) = kind, exists(url) else { return }
    Task {
      do {
        _ = try await NSWorkspace.shared.recycle([url])
      } catch {
        shelf?.island?.show("没能移到废纸篓", detail: error.localizedDescription, tone: .error)
        return
      }
      shelf?.island?.show("已移到废纸篓", detail: url.lastPathComponent, symbol: "trash")
      close()
    }
  }

  /// 双击用默认 App 打开（录屏：系统播放器自带修剪，R12-a）：没存过先快速保存（临时目录的文件下次启动会清掉，在预览里改了也会丢）
  func open() {
    if case .saved(let url) = badge {
      if exists(url) { NSWorkspace.shared.open(url) }
      return
    }
    guard !isBusy, let shelf else { return }
    isBusy = true
    Task {
      if let png = await encoded(), let url = await shelf.save(png) {
        badge = .saved(url)
        fileURL = url
        NSWorkspace.shared.open(url)
      }
      isBusy = false
    }
  }

  /// 拖出去的东西：文件（临时文件还没写好时给 PNG 数据）
  func dragItem() -> NSItemProvider {
    if let fileURL, let provider = NSItemProvider(contentsOf: fileURL) { return provider }
    if let png { return NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier) }
    return shown.map { NSItemProvider(object: NSImage(cgImage: $0, size: .zero)) }
      ?? NSItemProvider()
  }

  /// PNG：有就直接用；没有就在主线程外编码原图，编完放掉原图
  private func encoded() async -> Data? {
    if let png { return png }
    guard let image else { return nil }
    let data = await ScreenshotOutput.png(image, scale: scale)
    if let data, png == nil {
      png = data
      self.image = nil
    }
    return png
  }

  private func writeDragFile() async {
    guard let png = await encoded() else { return }
    let url = ScreenshotOutput.availableURL(in: ShotShelf.dragDirectory)
    guard await Self.write(png, to: url), fileURL == nil else { return }
    fileURL = url
  }

  /// 写临时文件（几 MB 到几十 MB，不在主线程写）
  @concurrent nonisolated private static func write(_ png: Data, to url: URL) async -> Bool {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? png.write(to: url)) != nil
  }

  private func scheduleDismiss(after seconds: Double) {
    timer?.cancel()
    guard !isLeaving else { return }
    timer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, let self, !self.isHovered else { return }
      self.close()
    }
  }

  /// 触控板横扫：卡片跟着手指往右走（往左不动），松手时过了 50 pt、或还在快速往右甩（过了 16 pt、80 ms 内最后一下
  /// ≥ 6 pt）就滑走，否则弹回原位
  private func swiped(_ delta: CGFloat, ended: Bool) {
    guard !isLeaving else { return }
    swipe = max(0, swipe + delta)
    let now = CACurrentMediaTime()
    if delta != 0 { lastSwipe = (delta, now) }
    let base = rect.minX - ShotShelf.margin
    if ended {
      let flung = lastSwipe.delta >= 6 && now - lastSwipe.time < 0.08
      if swipe > 50 || (swipe > 16 && flung) { return close() }
      swipe = 0
      lastSwipe = (0, 0)
    }
    // 都走 animator：跟手的 0 秒动画会顶掉还没播完的弹回 / 让位动画（直接 setFrameOrigin 打断不了，两边抢位置）
    NSAnimationContext.runAnimationGroup { context in
      context.duration = ended && !Style.reduceMotion ? 0.26 : 0
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
      panel.animator().setFrameOrigin(
        CGPoint(x: base + swipe, y: rect.minY - ShotShelf.margin))
    }
  }
}

/// 缩略图的宿主：本 App 不激活，SwiftUI 的悬停和光标跟踪不可靠，用 activeAlways 追踪区自己报悬停；
/// 第一下点击就给按钮；触控板横扫转给卡片
private final class ShelfHostingView: NSHostingView<ShelfCardView> {
  var onHover: (Bool) -> Void = { _ in }
  var onSwipe: (CGFloat, Bool) -> Void = { _, _ in }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds.insetBy(dx: ShotShelf.margin, dy: ShotShelf.margin),
        options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self))
  }

  /// 卡片出现在静止的光标下时没有 mouseEntered：动一下鼠标（mouseMoved）也算进来
  private var isInside = false

  override func mouseEntered(with event: NSEvent) { setInside(true) }
  override func mouseExited(with event: NSEvent) { setInside(false) }
  override func mouseMoved(with event: NSEvent) { if !isInside { setInside(true) } }

  private func setInside(_ inside: Bool) {
    isInside = inside
    onHover(inside)
  }

  /// 正在跟的这一次横扫的事件监听。卡片跟着手指一挪开，光标底下就不是它了，后面的滚动事件（包括松手那一下）
  /// 会发给光标下的别的窗口、别的 App，卡片就卡在半路。所以横扫一开始就装 local（自家窗口，吞掉）+ global（别的 App，
  /// 只旁听；滚动事件不需要辅助功能授权）监听，把这次手势接到松手，松手就卸
  private var swipeMonitors: [Any] = []

  override func scrollWheel(with event: NSEvent) {
    // 只跟触控板的手势阶段（惯性阶段、鼠标滚轮的 phase 都是空的，不跟），横向为主才开始跟
    guard swipeMonitors.isEmpty, event.phase == .began || event.phase == .changed,
      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    else { return }
    let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      let ours = MainActor.assumeIsolated { self?.follow(event) ?? false }
      return ours ? nil : event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      MainActor.assumeIsolated { _ = self?.follow(event) }
    }
    swipeMonitors = [local, global].compactMap { $0 }
    follow(event)
  }

  /// 跟一个滚动事件，返回是不是这次横扫的（是的话 local 监听把它吞掉）。又来一个 began 说明上一次的松手没收到
  /// （不该发生，兜底）：当作松手结束，这个事件照常分发
  @discardableResult private func follow(_ event: NSEvent) -> Bool {
    guard event.phase != [] else { return false }
    if event.phase == .began, !swipeMonitors.isEmpty, event.window != window {
      finishSwipe(0)
      return false
    }
    // 手指往右的距离：「自然滚动」开着时 scrollingDeltaX 和手指同向，关着时相反
    let fingers =
      event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    if event.phase == .ended || event.phase == .cancelled {
      finishSwipe(fingers)
    } else {
      onSwipe(fingers, false)
    }
    return true
  }

  private func finishSwipe(_ delta: CGFloat) {
    removeSwipeMonitors()
    onSwipe(delta, true)
  }

  private func removeSwipeMonitors() {
    swipeMonitors.forEach(NSEvent.removeMonitor)
    swipeMonitors = []
  }

  /// 扫到一半卡片就被收走（到点自己滑走、放回复用池时拆掉视图）：监听跟着卸，别留下一个吞滚动事件的
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { removeSwipeMonitors() }
  }
}

struct ShelfCardView: View {
  let card: ShelfCard
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    // 图放在 overlay 里铺满：fill 的图不参与布局，比例和卡片不一样时也不会把卡片撑大
    Color.clear
      .overlay {
        if let shown = card.shown {
          Image(decorative: shown, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
          Color(nsColor: Style.HUD.fill)  // 录屏没取到最后一帧：只剩播放符号和时长
        }
      }
      // 录屏：播放符号和时长（和飞行卡片落地时同一个）；悬停时让给操作按钮（左下角是「在访达中显示」）
      .overlay {
        if case .video(_, let seconds) = card.kind, !card.isHovered {
          VideoMarks(seconds: seconds, compact: VideoMarks.isCompact(card.rect.size))
            .transition(.opacity)
        }
      }
      .overlay {
        if card.isHovered {
          ZStack {
            Color.black.opacity(0.35)
            actions
          }
          .transition(.opacity)
        }
      }
      .clipShape(shape)
      .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
      // 和飞行卡片同一个位置（FlyCardBadge.offset），交接时对齐
      .overlay(alignment: .topTrailing) {
        FlyCardBadge(badge: card.badge)
          .offset(FlyCardBadge.offset)
          .id(card.badge.folder ?? "copied")
          .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
      }
      .animation(Style.Motion.pop.animation(reduced: reduceMotion), value: card.badge.folder)
      .animation(.easeOut(duration: 0.12), value: card.isHovered)
      .onDrag { card.dragItem() }
      .onTapGesture(count: 2) { card.open() }
      // 右键菜单：小卡片上放不下按钮时也能操作；VoiceOver 的自定义动作是同一份
      .contextMenu {
        ForEach(Array(card.menu.enumerated()), id: \.offset) { index, section in
          if index > 0 { Divider() }
          ForEach(section, id: \.self) { command in
            Button(command.title) { card.perform(command) }
          }
        }
      }
      .padding(ShotShelf.margin)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(card.accessibilityName)
      .accessibilityActions {
        ForEach(card.menu.flatMap { $0 }, id: \.self) { command in
          Button(command.title) { card.perform(command) }
        }
      }
  }

  /// 中间拷贝 / 存储（录屏已经存了，只有拷贝）；三个角关闭、钉图（录屏没有）、在访达中显示（右上角留给角标）。卡片矮的时候胶囊只留图标；
  /// 再小就不画角上的圆钮（会和胶囊叠在一起，点拷贝变成点钉图），更小的只剩右键菜单
  @ViewBuilder private var actions: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let compact = size.height < 90 || size.width < 150
      let corners = size.width >= 120 && size.height >= 84
      if size.width >= 76 && size.height >= 34 {
        actionButtons(compact: compact, corners: corners)
      }
    }
  }

  /// macOS 26：胶囊和圆钮都是玻璃，放进同一个容器共用取样（相邻的玻璃互相取样不到，分开放颜色会不一致）；
  /// spacing 0 = 隔 6 pt 的两个胶囊不融合成一块
  @ViewBuilder private func actionButtons(compact: Bool, corners: Bool) -> some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 0) { buttons(compact: compact, corners: corners) }
        .environment(\.colorScheme, .dark)
    } else {
      buttons(compact: compact, corners: corners)
    }
  }

  private func buttons(compact: Bool, corners: Bool) -> some View {
    ZStack {
      HStack(spacing: 6) {
        pill("拷贝", "doc.on.doc", compact: compact, action: card.copyAgain)
        if card.kind == .image {
          pill("存储", "square.and.arrow.down", compact: compact, action: card.save)
        }
      }
      .opacity(card.isBusy ? 0.5 : 1)
      .overlay { if card.isBusy { ProgressView().controlSize(.small).tint(.white) } }
      if corners {
        round("xmark", "关闭", action: card.close).frame(
          maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if card.kind == .image {
          round("pin.fill", "钉图", action: card.pin).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        if case .saved = card.badge {
          round("folder", "在访达中显示", action: card.revealInFinder).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
      }
    }
    .padding(6)
    // 撑满：没有四角圆钮时胶囊也要居中（GeometryReader 默认把内容放左上角）
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func pill(
    _ title: String, _ symbol: String, compact: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: symbol)
        if !compact { Text(title) }
      }
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, compact ? 7 : 10)
      .frame(height: 26)
      .hudSkin(Capsule())
    }
    .buttonStyle(PressScale())
    .disabled(card.isBusy)
    .help(title)
    .accessibilityLabel(title)  // 矮卡只剩图标：不然 VoiceOver 读符号自带的名字（体检 B46）
  }

  private func round(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .frame(width: 22, height: 22)
        .hudSkin(Circle())
    }
    .buttonStyle(PressScale())
    .help(title)
    .accessibilityLabel(title)
  }
}

extension View {
  /// HUD 皮肤（`Style.HUD`）：底色、内描边、外 0.5 pt 描边、主文字色。降低透明度（底色 0.97）、增强对比度（内描边
  /// 1 pt white 0.35）在取值时判断：悬停才建这些按钮，每次悬停都重新取。
  /// macOS 26 起是深色液态玻璃（mac-whisker §2「26 分支」），不画底色和描边，两个无障碍开关交给玻璃
  @ViewBuilder fileprivate func hudSkin<S: InsettableShape>(_ shape: S) -> some View {
    if #available(macOS 26, *) {
      foregroundStyle(Color(nsColor: Style.HUD.text))
        .glassEffect(.regular, in: shape)
        .environment(\.colorScheme, .dark)
        .contentShape(shape)
    } else {
      foregroundStyle(Color(nsColor: Style.HUD.text))
        .background(Color(nsColor: Style.HUD.fill), in: shape)
        .overlay(
          shape.strokeBorder(
            Color(nsColor: Style.HUD.innerStroke), lineWidth: Style.HUD.strokeWidth)
        )
        .overlay(
          shape.inset(by: -0.5).strokeBorder(Color(nsColor: Style.HUD.outerStroke), lineWidth: 0.5)
        )
        .contentShape(shape)
    }
  }
}
