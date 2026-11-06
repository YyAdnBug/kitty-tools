// CleanShot 式常驻缩略图（Whisker D8）：截图飞到右下角、角标弹完以后由这里接手，留在原地（同一个位置、同样的圆角阴影）。
// 悬停时出 HUD 操作：中间「拷贝」「存储」两个胶囊，左上关闭、右下钉图（右上角是品牌粉角标），存过的左下「在访达中显示」；
// 拖出去是一个 PNG 文件（拖进访达、邮件、聊天窗口），双击用默认 App 打开；触控板往右扫跟手，松手时扫得够远或够快就滑走、否则弹回；
// 鼠标不在上面时 6 s 后自己滑走（移开后 2.5 s）。同一块屏上连截几张时往上叠，最多 3 张，更早的滑走。
// 窗口是普通 NSPanel 实例（不当 key、不激活本 App；层级状态栏，之后的截图冻结帧会排除它），用完放回复用池
// （挂过 NSHostingView 的窗口 close 后 AppKit 不释放，同 FlyCard）。减弱动态效果时不飞，直接在角落淡入、淡出。
// 卡片只留缩到卡片大小的图和复制 / 保存时编码好的 PNG（不再编码一遍，也不留整张解码的图：5K 一张 59 MB、长截图上百 MB），
// 钉图时才解码；拖出用的临时 PNG 在主线程外写，卡片走的时候没拖过的就删掉（拖过的留到下次启动，第四轮体检 F2）。
// 录屏（第 3 批，拍板 R11-a）的视频卡是同一种卡片的另一种内容（ShelfCard.Kind.video）：图是最后一帧（取不到就是 HUD 底色）、
// 多了播放符号和时长；文件已经存好了，悬停只有「拷贝」（拷的是文件，进剪贴板历史）和关闭 / 在访达中显示，双击用默认 App 打开，
// 拖出去就是那个文件，右键多「打开」「移到废纸篓」（能放回，不二次确认）。
// 录音（第 5 批，拍板 A5-a）的录音卡同样是这种卡片（ShelfCard.Kind.audio）：图是电平包络画的波形，左上角 waveform 标记
// （没有播放符号）+ 时长，操作和视频卡一样。
// 转成 GIF（录屏录音第 7 批，拍板 R12-a）：视频卡悬停多一个「转成 GIF」胶囊（右键 / 旁白动作同名），在主线程外转（VideoExport），
// 转的时候刘海岛挂进度、卡片不自己滑走，卡片被关掉就取消；转好了在角落叠一张 GIF 卡（ShelfCard.Kind.gif：图是第一帧、左下「GIF」
// 胶囊，没有播放符号），pop 出来、旧卡让位，操作同视频卡（没有「转成 GIF」）。进度岛的详情里写百分比（第二轮体检 R3）。
// 压缩（第二轮体检 R1）：视频卡悬停时右下角多一个圆钮「压缩」（右键 / 旁白动作同名；矮卡没有圆钮，走右键），把录好的文件压小
// 另存一份（VideoExport.compress，原文件不动），进度、取消、不自己滑走都同转 GIF；压好了在角落叠一张压缩版的视频卡
// （它没有「压缩」：已经压过了）。这两件的进度岛、取消、结果岛在 VideoJob（第四轮体检 U1，截图历史、晾衣绳也从那里开始）。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ShotShelf {
  /// 再拷贝一次 / 快速保存（都用编码好的 PNG）/ 钉到原来的位置 / 拷贝录屏文件（AppDelegate 给）。
  /// copy 回答放进剪贴板的是图像还是文件（nil = 没接上）
  var copy: (Data) async -> ScreenshotOutput.Copied? = { _ in nil }
  var save: (Data) async -> URL? = { _ in nil }
  var pin: (CGImage, CGRect) -> Void = { _, _ in }
  var copyFile: (URL) -> Void = { _ in }
  /// 刘海岛（AppDelegate 给）：缩略图看起来没变的结果（再拷贝、存到同一个文件夹）、文件已不在时用它说
  var island: Island?
  /// 转出来的 GIF、压缩版也记进截图历史（AppDelegate 给，2026-10-26 拍板 B1）
  var remember: (URL, CGImage?, ShotHistory.Kind) -> Void = { _, _, _ in }
  /// 右键「在历史里看」：打开截图历史窗口（AppDelegate 给）。
  /// ponytail: 只打开窗口、不定位到这一条——最新的本来就排在最前面
  var openHistory: () -> Void = {}
  /// 截图历史开着没有（ShotHistory.isOn，AppDelegate 给）：关着时右键没有「在历史里看」（第四轮体检 U13）
  var historyIsOn: () -> Bool = { true }

  private(set) var cards: [ShelfCard] = []
  private var idle: [NSPanel] = []
  /// 卡片四周给阴影留的边（窗口比卡片大这么多）
  static let margin: CGFloat = 24
  private static let gap: CGFloat = 10
  private static let maxPerScreen = 3
  /// 拖出去用的 PNG 放在这里（截图拷贝成文件的那份也是，ScreenshotOutput.copyFile）；启动时清空、换日时删一天以前的
  /// （拖进邮件、聊天的附件可能还在读，用的时候不删）
  nonisolated static let dragDirectory = FileManager.default.temporaryDirectory.appending(
    path: "Kitty Tools 截图")

  /// 换日时清拖出目录（2026-11-06 拍板 Q4：菜单栏 App 一开几周，只靠启动时清空会越攒越多）：第一层里改于一天以前的删掉
  /// （每次拷贝、拖出是一个子文件夹，常驻缩略图那份是一个文件）。临时目录在本机，几十上百项，主线程上删
  static func purgeStaleDragFiles(now: Date = .now) {
    let files = FileManager.default
    let entries =
      (try? files.contentsOfDirectory(
        at: dragDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let dated = entries.compactMap { url in
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        .map { (url: url, modified: $0) }
    }
    for url in stale(dated, now: now) { try? files.removeItem(at: url) }
  }

  /// 哪些算一天以前的（纯函数，配单测）：改于比现在早 24 小时以上的；时间比现在还晚的（钟往回调过）不算，留给启动时清
  nonisolated static func stale(_ entries: [(url: URL, modified: Date)], now: Date) -> [URL] {
    entries.filter { now.timeIntervalSince($0.modified) > 24 * 60 * 60 }.map(\.url)
  }

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

  /// 接手一段录屏 / 录音（已存进快速保存目录的文件、时长、最后一帧 / 波形）。fadesIn：没飞过来（减弱动态效果、没取到最后一帧）
  /// 时在角落淡入
  func add(
    recording url: URL, seconds: Int, audio: Bool = false, poster: CGImage?, source: CGRect,
    at rect: CGRect, fadesIn: Bool
  ) {
    insert(at: rect, fadesIn: fadesIn) { screen, panel in
      ShelfCard(
        recording: url, seconds: seconds, audio: audio, poster: poster, source: source, rect: rect,
        screen: screen, panel: panel, shelf: self)
    }
  }

  /// 录屏转成的 GIF（第 7 批）：没有飞行卡片交接，在角落 pop 出来（减弱动态效果时淡入），旧卡让位；first 是第一帧
  func add(gif url: URL, first: CGImage, source: CGRect, at rect: CGRect) {
    insert(at: rect, fadesIn: Style.reduceMotion, popsIn: !Style.reduceMotion) { screen, panel in
      ShelfCard(
        file: .gif(url), poster: first, source: source, rect: rect, screen: screen, panel: panel,
        shelf: self)
    }
  }

  /// 压缩出来的录屏（第二轮体检 R1）：同 GIF 卡在角落 pop 出来、旧卡让位；是一张不能再压的视频卡，图用原卡那张
  /// （同一段画面的最后一帧）
  func add(compressed url: URL, seconds: Int, poster: CGImage?, source: CGRect, at rect: CGRect) {
    insert(at: rect, fadesIn: Style.reduceMotion, popsIn: !Style.reduceMotion) { screen, panel in
      ShelfCard(
        file: .video(url, seconds: seconds), poster: poster, source: source, rect: rect,
        screen: screen, panel: panel, shelf: self, isCompressed: true)
    }
  }

  /// 同一块屏上已有的往上挪给新的让位；超过 3 张的最早那张滑走（截图、录屏混着叠）
  private func insert(
    at rect: CGRect, fadesIn: Bool = Style.reduceMotion, popsIn: Bool = false,
    _ make: (NSScreen?, NSPanel) -> ShelfCard
  ) {
    let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
    let neighbours = cards.filter { !$0.isLeaving && $0.screen == screen }
    for card in neighbours { card.shift(by: rect.height + Self.gap) }
    if neighbours.count >= Self.maxPerScreen, let oldest = neighbours.first { dismiss(oldest) }
    let card = make(screen, idle.popLast() ?? Self.makePanel())
    card.popsIn = popsIn
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
    // 本 App 失活时不收（NSPanel 默认收；收回浮动便签后 NoteFloats.returnKeyboard 会 deactivate 一次）
    panel.hidesOnDeactivate = false
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
  /// 卡片装的是什么
  enum Kind: Equatable {
    /// 截图：PNG / 原图在下面的 png、image 里
    case image
    /// 录屏：快速保存目录里的文件和时长（秒）
    case video(URL, seconds: Int)
    /// 录音（第 5 批）：同录屏，图是波形
    case audio(URL, seconds: Int)
    /// 录屏转成的 GIF（第 7 批）：快速保存目录里的 .gif，图是第一帧
    case gif(URL)

    /// 录屏 / 录音的文件、时长和哪一种（截图、GIF nil）：两种卡的操作一样，只有叫法和标记不同
    var recording: (url: URL, seconds: Int, medium: ScreenRecorder.Medium)? {
      switch self {
      case .image, .gif: nil
      case .video(let url, let seconds): (url, seconds, .screen)
      case .audio(let url, let seconds): (url, seconds, .audio)
      }
    }

    /// 卡片装的文件（录屏、录音、GIF；截图 nil）：拷贝、打开、移到废纸篓、拖出都对它
    var file: URL? {
      switch self {
      case .image: nil
      case .video(let url, _), .audio(let url, _), .gif(let url): url
      }
    }
  }

  /// 右键菜单和 VoiceOver 自定义动作（同一份 menu）。
  /// edit / unpeg / forget 是晾衣绳（第十族，2026-10-26）用的：同一个动作全 App 一个名字，不各写一份
  enum Command {
    case copy, gif, compress, save, pin, open, reveal, history, trash, close, edit, unpeg, forget

    var title: String {
      switch self {
      case .copy: "拷贝"
      case .gif: "转成 GIF"
      case .compress: "压缩"
      case .save: "存储"
      case .pin: "钉图"
      case .edit: "改标注"
      case .unpeg: "取下"
      case .forget: "从历史里删掉"
      case .open: "打开"
      case .reveal: "在访达中显示"
      case .history: "在历史里看"
      case .trash: "移到废纸篓"
      case .close: "关闭"
      }
    }
  }

  /// 「转成 GIF」的符号（悬停胶囊）；刘海岛里同其它结果用圆底的 photo.circle.fill（gifIslandSymbol）
  static let gifSymbol = "photo.stack"
  static let gifIslandSymbol = "photo.circle.fill"
  /// 「压缩」的符号（悬停的圆钮）和刘海岛里圆底的那个
  static let compressSymbol = "arrow.down.right.and.arrow.up.left"
  static let compressIslandSymbol = "arrow.down.right.and.arrow.up.left.circle.fill"

  let kind: Kind
  /// 显示的部分（长截图只露开头一屏；缩到卡片尺寸）；录屏没取到最后一帧、录音没有波形时 nil（HUD 底色 + 标记占位）
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
  /// 临时目录里那份 PNG 和它拖出去过没有（第四轮体检 F2）：卡片走的时候没拖过的就删掉；拖过的可能还在被邮件、聊天的
  /// 附件读，留给下次启动时清空整个目录（ShotShelf.dragDirectory 的老规矩）
  @ObservationIgnored private var dragFile: URL?
  @ObservationIgnored private var dragged = false
  @ObservationIgnored private var timer: Task<Void, Never>?
  /// 这张卡开始的转 GIF（第 7 批）/ 压缩（VideoJob）：做的时候不自己滑走，卡片被关掉就取消
  @ObservationIgnored private var export: Task<Void, Never>?
  /// 压缩出来的那张（视频卡）：不再给「压缩」
  @ObservationIgnored let isCompressed: Bool
  /// 没有飞行卡片交接、在角落弹出来（GIF 卡，第 7 批）：出现时 pop
  @ObservationIgnored var popsIn = false
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
    isCompressed = false
    if case .saved(let url) = badge { fileURL = url }
  }

  /// 录屏 / 录音 / GIF（kind 带着文件）：文件已在快速保存目录（角标是它的文件夹），poster 是最后一帧 / 波形 / GIF 第一帧
  /// （和飞行卡片同样缩到卡片尺寸，交接时像素一样）
  init(
    file kind: Kind, poster: CGImage?, source: CGRect, rect: CGRect, screen: NSScreen?,
    panel: NSPanel, shelf: ShotShelf, isCompressed: Bool = false
  ) {
    let backing = screen?.backingScaleFactor ?? 2
    self.kind = kind
    self.isCompressed = isCompressed
    scale = backing
    shown = poster.map {
      FlyCard.cardImage(of: $0, frame: source, size: rect.size, backingScale: backing)
    }
    pixels = .zero
    self.source = source
    self.rect = rect
    badge = kind.file.map(FlyCard.Badge.saved) ?? .copied
    self.screen = screen
    self.panel = panel
    self.shelf = shelf
    fileURL = kind.file
  }

  /// 录屏 / 录音（audio）
  convenience init(
    recording url: URL, seconds: Int, audio: Bool = false, poster: CGImage?, source: CGRect,
    rect: CGRect, screen: NSScreen?, panel: NSPanel, shelf: ShotShelf
  ) {
    self.init(
      file: audio ? .audio(url, seconds: seconds) : .video(url, seconds: seconds), poster: poster,
      source: source, rect: rect, screen: screen, panel: panel, shelf: shelf)
  }

  /// 旁白里卡片的名字
  var accessibilityName: String {
    if case .gif = kind { return "GIF 动图" }
    guard let recording = kind.recording else { return "截图缩略图" }
    return recording.medium.noun + "，" + ScreenRecorder.spoken(recording.seconds)
  }

  /// 右键菜单（一节一组，节间分隔线）：截图「拷贝 / 存储 / 钉图 /（存过的）在访达中显示 / 在历史里看 ｜ 关闭」；
  /// 录屏「拷贝 / 转成 GIF / 压缩 / 打开 / 在访达中显示 / 在历史里看 ｜ 移到废纸篓 ｜ 关闭」（压缩出来的那张没有「压缩」），
  /// 录音、GIF 同录屏但没有「转成 GIF」「压缩」（已经存了，没有存储；不是图，没有钉图）。截图历史关着时没有「在历史里看」
  var menu: [[Command]] {
    let history: [Command] = shelf?.historyIsOn() == false ? [] : [.history]
    guard kind.file == nil else {
      var convert: [Command] = []
      if case .video = kind { convert = canCompress ? [.gif, .compress] : [.gif] }
      return [[.copy] + convert + [.open, .reveal] + history, [.trash], [.close]]
    }
    let saved = if case .saved = badge { true } else { false }
    // 截图这个功能关掉之后还留在角落的：没有钉图（Feature）
    let pin: [Command] = Feature.screenshot.isOn ? [.pin] : []
    return [[.copy, .save] + pin + (saved ? [.reveal] : []) + history, [.close]]
  }

  func perform(_ command: Command) {
    switch command {
    case .copy: copyAgain()
    case .gif: convertToGIF()
    case .compress: compress()
    case .save: save()
    case .pin: pin()
    case .open: open()
    case .reveal: revealInFinder()
    case .history: shelf?.openHistory()
    case .trash: moveToTrash()
    case .close: close()
    // 晾衣绳那边的三个（menu 里不给，常驻缩略图没有这几样）
    case .edit, .unpeg, .forget: break
    }
  }

  /// fadingIn：没有飞行卡片在同一个位置交接（减弱动态效果、录屏没取到最后一帧）时淡入
  func show(fadingIn: Bool = Style.reduceMotion) {
    let host = ShelfHostingView(rootView: ShelfCardView(card: self))
    host.sizingOptions = []
    host.onHover = { [weak self] in self?.isHovered = $0 }
    host.onSwipe = { [weak self] delta, ended in self?.swiped(delta, ended: ended) }
    panel.setFrame(rect.insetBy(dx: -ShotShelf.margin, dy: -ShotShelf.margin), display: false)
    panel.setHostedContent(host)
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
    export?.cancel()  // 卡片被关掉（关闭、横扫、被挤走）：GIF 不转了、不压了
    if let dragFile, !dragged { try? FileManager.default.removeItem(at: dragFile) }
    dragFile = nil
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
    // 录屏 / 录音 / GIF 拷的是文件（C8-a：点了才进剪贴板历史）
    if let file = kind.file {
      guard exists(file) else { return }
      shelf.copyFile(file)
      shelf.island?.show(
        kind.recording.map { "已复制\($0.medium.noun)" } ?? "已复制 GIF",
        leading: shown.map(Island.thumbnail(of:)) ?? .tone)
      return
    }
    isBusy = true
    Task {
      // 角标不换（存过的还要留着文件夹和「在访达中显示」），缩略图看不出拷没拷上：用刘海说（岛自己也播报）
      if let png = await encoded(), let copied = await shelf.copy(png) {
        shelf.island?.show(
          "已复制截图", detail: copied.detail, leading: shown.map(Island.thumbnail(of:)) ?? .tone)
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
            leading: shown.map(Island.thumbnail(of:)) ?? .tone, actions: .file(url))
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
    let frame = PinBoard.restoredFrame(
      pixels: pixels, source: source, visible: screen?.visibleFrame ?? source)
    shelf?.pin(full, frame)
    close()
  }

  func revealInFinder() {
    if case .saved(let url) = badge, exists(url) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  /// 录屏 / 录音 / GIF 移到废纸篓（能放回，13 条默认细节：不二次确认）：成功后卡片收起，岛说一声
  func moveToTrash() {
    guard let url = kind.file, exists(url) else { return }
    Task {
      do {
        _ = try await NSWorkspace.shared.recycle([url])
      } catch {
        shelf?.island?.show("没能移到废纸篓", detail: error.localizedDescription, tone: .error)
        return
      }
      shelf?.island?.show("已移到废纸篓", detail: url.lastPathComponent, symbol: "trash.circle.fill")
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
    if fileURL != nil, fileURL == dragFile { dragged = true }
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
    guard await Self.write(png, to: url) else { return }
    // 写的这一会儿存过了（拖存的那个文件）、或者卡片已经走了：这份没人用，删掉
    guard fileURL == nil, !isLeaving else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    fileURL = url
    dragFile = url
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
      // 正在转 GIF / 压缩的不走（走了就取消了），做完再等 2.5 s
      guard !Task.isCancelled, let self, !self.isHovered, self.export == nil else { return }
      self.close()
    }
  }

  /// 录屏转成 GIF（第 7 批，R12-a）/ 压缩（第二轮体检 R1）：进度岛、取消、结果岛都在 VideoJob（第四轮体检 U1：截图历史、
  /// 晾衣绳共用一份）。这张卡开始的那件做的时候卡片不自己滑走、卡片被关掉就取消；做好了在角落叠一张 GIF 卡 / 压缩版的视频卡
  /// （最新的在最下面，这张往上让位）、记进截图历史。这一段已经在做了（这张卡或者历史里开始的）只让岛再说一次
  func convertToGIF() { run(.gif) }

  func compress() {
    guard canCompress else { return }
    run(.compress)
  }

  private func run(_ job: VideoJob) {
    guard case .video(let url, let seconds) = kind, exists(url) else { return }
    // 这一段正在做（start 给 nil，岛已经把那件再说了一次）：这张卡手上的那件不动
    guard
      let task = job.start(
        url, seconds: seconds, poster: shown, island: shelf?.island,
        finished: { [weak self] in self?.finishExport() },
        done: { [weak self] in self?.made($0, by: job) })
    else { return }
    export = task
  }

  /// 做好了：记进截图历史，在角落叠一张 GIF 卡 / 压缩版的视频卡
  private func made(_ output: VideoJob.Output, by job: VideoJob) {
    guard case .video(_, let seconds) = kind, let shelf else { return }
    shelf.remember(output.file, output.poster, job.kind)
    guard let corner = FlyCard.landingRect(for: rect, size: rect.size) else { return }
    switch job {
    case .gif:
      if let first = output.poster {
        shelf.add(gif: output.file, first: first, source: source, at: corner)
      }
    case .compress:
      shelf.add(
        compressed: output.file, seconds: seconds, poster: shown, source: source, at: corner)
    }
  }

  /// 能不能压缩：录屏，而且不是压缩出来的那张
  var canCompress: Bool {
    if case .video = kind { !isCompressed } else { false }
  }

  private func finishExport() {
    export = nil
    if !isHovered { scheduleDismiss(after: 2.5) }
  }

  /// 进度岛的详情（纯函数，配单测）：「37%」；有附注的（转 GIF 只转前 60 秒）写在前面
  nonisolated static func progressDetail(_ percent: Int, note: String? = nil) -> String {
    [note, "\(min(max(percent, 0), 100))%"].compactMap { $0 }.joined(separator: " · ")
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
  /// GIF 卡弹出来（popsIn）：出现后置真
  @State private var popped = false

  var body: some View {
    let hidden = card.popsIn && !popped
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    // 图放在 overlay 里铺满：fill 的图不参与布局，比例和卡片不一样时也不会把卡片撑大
    Color.clear
      .overlay {
        if let shown = card.shown {
          Image(decorative: shown, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
          Color(nsColor: Style.HUD.solidFill)  // 录屏没取到最后一帧：只剩播放符号和时长
        }
      }
      // 录屏：播放符号和时长（录音是左上角的 waveform 标记和时长；和飞行卡片落地时同一个）；悬停时让给操作按钮
      // （左上角是关闭，左下角是「在访达中显示」）
      .overlay {
        if let recording = card.kind.recording, !card.isHovered {
          VideoMarks(
            seconds: recording.seconds, compact: VideoMarks.isCompact(card.rect.size),
            audio: recording.medium == .audio
          )
          .transition(.opacity)
        } else if case .gif = card.kind, !card.isHovered {
          // GIF 卡：左下角「GIF」胶囊（同时长胶囊），没有播放符号
          VideoMarks.capsule("GIF")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
      }
      .overlay {
        if card.isHovered {
          ZStack {
            Style.Shot.cardScrim
            actions
          }
          .transition(.opacity)
        }
      }
      .shotCard(shape)
      // 和飞行卡片同一个位置（FlyCardBadge.offset），交接时对齐
      .overlay(alignment: .topTrailing) {
        FlyCardBadge(badge: card.badge)
          .offset(FlyCardBadge.offset)
          .id(card.badge.folder ?? "copied")
          .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
      }
      .animation(Style.Motion.pop.animation(reduced: reduceMotion), value: card.badge.folder)
      .animation(.easeOut(duration: 0.12), value: card.isHovered)
      // GIF 卡在角落弹出来（pop 0.85 → 1 + 淡入；减弱动态效果时 popsIn 为假，窗口淡入）
      .scaleEffect(hidden ? 0.85 : 1)
      .opacity(hidden ? 0 : 1)
      .onAppear {
        guard card.popsIn else { return }
        withAnimation(Style.Motion.pop.animation(reduced: reduceMotion)) { popped = true }
      }
      .onDrag { card.dragItem() }
      .onTapGesture(count: 2) { card.open() }
      // 右键菜单：小卡片上放不下按钮时也能操作；VoiceOver 的自定义动作是同一份
      .contextMenu {
        ForEach(Array(card.menu.enumerated()), id: \.offset) { index, section in
          if index > 0 { Divider() }
          ForEach(section, id: \.self) { command in
            Button(command.title, role: command == .trash ? .destructive : nil) {
              card.perform(command)
            }
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

  /// 中间拷贝 / 存储（录屏已经存了，拷贝旁边是「转成 GIF」；录音、GIF 只有拷贝）；三个角关闭、钉图（录屏在这个位置是「压缩」）、在访达中显示
  /// （右上角留给角标）。卡片矮的时候胶囊只留图标；
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
        } else if case .video = card.kind {
          pill(
            ShelfCard.Command.gif.title, ShelfCard.gifSymbol, compact: compact,
            action: card.convertToGIF)
        }
      }
      .opacity(card.isBusy ? 0.5 : 1)
      .overlay {
        if card.isBusy {
          ProgressView().controlSize(.small).tint(Color(nsColor: Style.HUD.text))
        }
      }
      if corners {
        round("xmark", "关闭", action: card.close).frame(
          maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if card.kind == .image, Feature.screenshot.isOn {
          round("pin.fill", "钉图", action: card.pin).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        } else if card.canCompress {
          // 录屏：右下角（截图放钉图的位置）是「压缩」
          round(ShelfCard.compressSymbol, ShelfCard.Command.compress.title, action: card.compress)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
      let label = HStack(spacing: 6) {
        Image(systemName: symbol)
        if !compact { Text(title) }
      }
      .font(.system(size: 12, weight: .medium))
      if compact {
        // 矮卡只剩图标：固定 26 × 26 的圆（按图标的宽留边的话各个符号宽窄不一：27–29.5）
        label.frame(width: 26, height: 26).hudSkin(Circle(), glass: false)
      } else {
        label.padding(.horizontal, 10).frame(height: 26).hudSkin(Capsule())
      }
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
        // 同晾衣绳的 ✕：小圆钮不换玻璃
        .hudSkin(Circle(), glass: false)
    }
    .buttonStyle(PressScale())
    .help(title)
    .accessibilityLabel(title)
  }
}
