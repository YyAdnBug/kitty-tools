// 晾衣绳（第十族，2026-10-26 拍板；SPEC 和拍板页在 macos/build/research/clothesline-2026-10-26/，规矩在
// mac-overlay-panel §14、长相在 mac-whisker-capture.mdc「晾衣绳」）：截完图挂到屏幕顶上一根绳子上，
// 手边常备一排——它和右下角的常驻缩略图二选一（设置 › 截图「截完图放哪」，拍板 B1）。
// 挂的就是截图历史里的那几条（拍板 B2：挂着的在这里记一笔，取下只是把这一笔去掉，历史不动；历史里删掉的跟着没），
// 不另存一份数据，也不跨重启（B3：退出即清）。最多 8 张、屏幕窄时按宽度减，超了最旧的自动取下（还在历史里）。
// 什么时候出来（C1 D3）：鼠标停在菜单栏那一条上 0.3 秒滑下来，离开 0.4 秒收起；只在鼠标所在的那块屏上，换屏跟过去；
// 另有一个可设的全局快捷键（HotKeyAction.clothesline，默认不占键）。收不收按鼠标位置算，不用追踪区的进出
// （面板改尺寸会重建追踪区、淡出时进来的事件会丢，同程序坞预览 mac-dock-preview §5）。
// 面板是普通 NSPanel 实例（不子类化，mac-overlay-panel §1）：无边框、不激活本 App、永不当 key、状态栏层级
// （截图的冻结帧和录屏的白名单按层级都不收它）、所有桌面上都在；**不加 fullScreenAuxiliary**，所以别的 App
// 全屏占着那块屏时它不出来（拍板 D3，同便签屏幕边缘的药丸）。整块透明、没有毛玻璃底：透明的地方系统自己点穿，
// 只有卡片接鼠标。永不当 key，所以收起直接淡掉窗口自己的透明度（OverlayPanel 要替身是因为淡出时它还当着 key）。
// 内容在 ClotheslineView.swift，几何和时机在 ClotheslineLayout.swift（纯函数）。

import AppKit
import SwiftUI

/// 绳子上要画的东西（Clothesline 填，视图只读）
@Observable final class ClotheslineModel {
  /// 挂着的历史编号，挂上的先后（先挂上的靠外）。**它就是「挂着」那个标记**（拍板 B2）：不进库、不跨重启
  private(set) var pegged: [UUID] = []
  /// 这块屏上排好的样子（面板内坐标）
  var plan = ClotheslineLayout.Plan()
  /// 鼠标停在哪一张上（压一层蒙层、右上角出 ✕）；截图自检直接摆它
  var hovered: UUID?
  /// 这一帧每张卡挂在哪、歪多少（物理在跑时每帧换一份；减弱动态效果时就是 plan 里静止的样子）
  var hangs: [Hang] = []
  /// 两段绳子这一帧的质点（画线用）
  var ropes: [[CGPoint]] = []

  /// 挂着的一张：面板内的框 + 绕挂点转的角度（弧度）
  struct Hang: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect
    var angle: Double
  }
  /// 拖出去的那个文件（挂上去时在主线程外备好）：存过的就是存的那个，录制的是那段视频 / 音频
  var dragFiles: [UUID: URL] = [:]
  /// 改完标注、缩略图重做好了要重画（ShotThumbnails 不是 @Observable，视图读它来建立依赖）
  private(set) var redraws = 0
  /// 卡片上的动作（Clothesline 接）
  @ObservationIgnored var onCommand: (ShelfCard.Command, ShotHistory.Item) -> Void = { _, _ in }
  /// 截图历史：绳子只是它的一个视图（B2）。这次用不了（功能关着、历史关着）时是 nil，什么都挂不上
  @ObservationIgnored let history: ShotHistory?

  init(history: ShotHistory?) { self.history = history }

  func touch() { redraws += 1 }

  /// 这一条的缩略图（和历史窗口共用一份缓存）
  func thumbnail(for item: ShotHistory.Item) -> NSImage? {
    history.flatMap { ShotThumbnails.shared.image(for: item, in: $0) }
  }

  /// 右键菜单和旁白动作（一节一组，节间分隔线）：截图「改标注 / 拷贝 / 存储 / 钉图 /（存过的）在访达中显示 /
  /// 在历史里看 ｜ 取下 ｜ 从历史里删掉」——同常驻缩略图那一整套（拍板 C3），多了「改标注」和末尾两条；
  /// 录制的那几条没有图，只有「拷贝 / 打开 / 在访达中显示 / 在历史里看」。纯函数，配单测
  static func menu(for item: ShotHistory.Item, screenshotOn: Bool = Feature.screenshot.isOn)
    -> [[ShelfCard.Command]]
  {
    guard item.filePath == nil else {
      return [[.copy, .open, .reveal, .history], [.unpeg], [.forget]]
    }
    let saved: [ShelfCard.Command] = item.savedPath == nil ? [] : [.reveal]
    // 截图这个功能关掉时绳子整个就没了，这里仍按开关给（同常驻缩略图）
    let pin: [ShelfCard.Command] = screenshotOn ? [.pin] : []
    return [[.edit, .copy, .save] + pin + saved + [.history], [.unpeg], [.forget]]
  }

  /// 挂着、而且历史里还在的那几条（历史里删掉的跟着没，B2）。
  /// ponytail: 8 张各在历史里线性找一遍（历史几千条时也就几万次比较，都在一次重画里）；慢了再给历史加一张按编号的表
  var items: [ShotHistory.Item] {
    guard let history else { return [] }
    return pegged.compactMap { id in history.items.first { $0.id == id } }
  }

  var isEmpty: Bool { items.isEmpty }

  func item(_ id: UUID) -> ShotHistory.Item? { items.first { $0.id == id } }

  /// 换一批（Clothesline 算好容量之后给）
  func setPegged(_ ids: [UUID]) { pegged = ids }
}

/// NSObject：display link 要一个 @objc 的靶子（同钉图的 popIn、OverlayPanel 的挤压入场）
@MainActor final class Clothesline: NSObject {
  let model: ClotheslineModel
  /// 别的功能占着屏幕时不出来（AppDelegate 给：截图框选 / 长截图中、状态屏、启动台开着）
  var isSuppressed: () -> Bool = { false }
  /// 收起了（AppDelegate 拿它排空闲回收）
  var onHide: () -> Void = {}
  /// 这块屏上刘海那一块（中间给刘海岛让位，拍板 C2）；单测和截图自检注入
  var notch: (NSScreen) -> CGRect? = { Island.notchRect(of: $0) }
  /// 一条历史的那几样操作（AppDelegate 给，和截图历史窗口共用一份）
  var actions = ShotActions()
  /// 减弱动态效果（不跑物理：卡片直接在静止位置上，绳子画成静止的）；截图自检注入
  var reducesMotion: () -> Bool = { Style.reduceMotion }

  private var panel: NSPanel?
  private var host: ClotheslineHost?
  /// 挂在哪块屏上（nil = 收着）
  private var shown: NSScreen?
  /// 等着滑下来的那一下（鼠标离开那一条就作废）
  private var pendingShow: Task<Void, Never>?
  /// 刚挂上去：先亮着不收（看得见它落在哪）
  private var holdUntil: ContinuousClock.Instant?
  /// 出来之后看鼠标在哪的定时器（收着时不跑）
  private var watch: Timer?
  private var linger = ClotheslineLayout.Linger()
  /// 挂着东西时才装的鼠标监听（绳子上空着时一点开销都不要）
  private var monitors: [Any] = []
  /// 有一张正在飞过来（截图刚出图、飞行卡片在路上）：绳子先摆出来等着它，别等卡片到了才滑下来
  private var awaitingCard = false
  private var started = false
  /// 两段绳子的物理（左、右）；挂着的卡片各挂在哪一段的哪个质点上
  private var ropes: [ClotheslineRope] = []
  private var nodes: [UUID: (rope: Int, index: Int)] = [:]
  /// 还在往下落的那几张（挂上去那一下，拍板的物理）
  private var falling: [UUID: Falling] = [:]
  /// 每帧走一步的表；全停了就停表（Whisker §8：不能有常驻的循环动画）
  private var link: CADisplayLink?

  /// 一张正在落下来的卡片：离挂点还有多远（负数 = 在上面）、这一帧多快
  private struct Falling {
    var drop: CGFloat
    var speed: CGFloat = 0
  }

  init(history: ShotHistory?) {
    model = ClotheslineModel(history: history)
    super.init()
    model.onCommand = { [unowned self] command, item in perform(command, on: item) }
  }

  var isEmpty: Bool { model.isEmpty }

  /// 卡片上的一个动作（单击、双击、✕、拖到废纸篓、右键菜单、旁白动作都走它）
  func perform(_ command: ShelfCard.Command, on item: ShotHistory.Item) {
    switch command {
    case .copy: actions.copy(item)
    case .save: actions.save(item)
    case .pin: actions.pin(item)
    case .edit: actions.edit(item)
    case .forget: actions.forget(item)
    case .history: actions.openHistory()
    case .reveal: ShotHistory.reveal(item)
    case .open: ShotHistory.open(item)
    case .unpeg: unpeg(item.id)
    // 绳子上没有这几样（menu 里不给）
    case .gif, .compress, .trash, .close: break
    }
  }

  /// 改完标注、缩略图重做好了（AppDelegate 转过来）：重画那张卡、拖出去的那份也要重做
  func thumbnailChanged(_ id: UUID) {
    guard model.pegged.contains(id) else { return }
    model.touch()
    model.dragFiles[id] = nil
    guard let item = model.items.first(where: { $0.id == id }) else { return }
    Task { await prepareDragFile(item) }
  }

  // MARK: 起停

  /// 起（截图这个功能开着时）：挂着东西才真去听鼠标
  func start() {
    started = true
    updateWatching()
  }

  /// 停（关掉截图功能、退出）：收起、取下全部（挂着的标记本来就不跨重启）
  func stop() {
    started = false
    awaitingCard = false
    model.setPegged([])
    model.dragFiles = [:]
    model.hovered = nil
    falling = [:]
    hide(animated: false)
    updateWatching()
  }

  /// 空闲回收：收着时把整块面板放掉（下次再建）
  func reclaim() {
    guard shown == nil, let old = panel else { return }
    panel = nil
    host = nil
    old.orderOut(nil)
    old.contentView = nil
    old.close()
  }

  // MARK: 挂上、取下

  /// 挂一张上去（截图 / 长截图 / 录制刚进历史的那一条）：挂满了最旧的自动取下（还在历史里，拍板 B3），
  /// 出来摇一下、先亮 2.5 秒
  func peg(_ id: UUID) {
    guard started, model.history != nil else { return }
    var ids = model.pegged.filter { $0 != id }
    ids.append(id)
    ids = trimmed(ids, on: screenForMouse())
    for dropped in Set(model.pegged).subtracting(ids) {
      model.dragFiles[dropped] = nil
      falling[dropped] = nil
    }
    model.setPegged(ids)
    awaitingCard = false
    // 从挂点上方落下来（减弱动态效果时直接到位）；飞行卡片刚把它送到的就是这个高度（slot 已经抬高了）
    falling[id] = reducesMotion() ? nil : Falling(drop: -ClotheslineLayout.dropHeight)
    holdUntil = .now.advanced(by: ClotheslineLayout.pegHold)
    updateWatching()
    if let screen = screenForMouse() { present(on: screen) }
    if let item = model.items.first(where: { $0.id == id }) {
      Task { await prepareDragFile(item) }
    }
  }

  /// 取下（只去掉「挂着」这一笔，历史不动，拍板 B2 D2）：给那个质点一个向上的释放脉冲，绳子回弹；
  /// 卡片往下坠一截、淡出（SwiftUI 的离场过渡，不进物理）
  func unpeg(_ id: UUID) {
    guard model.pegged.contains(id) else { return }
    if model.hovered == id { model.hovered = nil }
    model.dragFiles[id] = nil
    falling[id] = nil
    if let node = nodes[id], ropes.indices.contains(node.rope) {
      ropes[node.rope].setLoaded(node.index, false)
      ropes[node.rope].push(
        node.index, dx: ClotheslineLayout.releaseImpulse.dx,
        dy: ClotheslineLayout.releaseImpulse.dy)
    }
    nodes[id] = nil
    model.setPegged(model.pegged.filter { $0 != id })
    replan()
    withAnimation(.easeIn(duration: ClotheslineLayout.leaveDuration)) { publish() }
    if model.isEmpty { hide(animated: true) }
    updateWatching()
  }

  /// 拖出去的那个文件：存过的就是存的那个、录制的就是那段文件（名字是用户自己的），别的在临时目录里写一份成品
  /// PNG（原图 + 标注），名字同快速保存。常驻缩略图也往这个目录写、启动时清空（ShotShelf.dragDirectory）
  private func prepareDragFile(_ item: ShotHistory.Item) async {
    if let path = item.savedPath ?? item.filePath, FileManager.default.fileExists(atPath: path) {
      model.dragFiles[item.id] = URL(filePath: path)
      return
    }
    guard let history = model.history, let image = history.composed(item),
      let png = await ScreenshotOutput.png(image, scale: item.scale)
    else { return }
    let url = ScreenshotOutput.availableURL(in: ShotShelf.dragDirectory)
    guard await Self.write(png, to: url), model.pegged.contains(item.id) else { return }
    model.dragFiles[item.id] = url
  }

  /// 写临时文件（几 MB 到几十 MB，不在主线程写；同常驻缩略图）
  @concurrent nonisolated private static func write(_ png: Data, to url: URL) async -> Bool {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? png.write(to: url)) != nil
  }

  /// 下一张挂在哪（屏幕坐标）：截图的飞行卡片照它落地（拍板 B1）。pixels 是原图的像素尺寸；
  /// 挂不上（历史关着、绳子一张都放不下）时 nil
  func slot(for pixels: CGSize, on screen: NSScreen) -> CGRect? {
    guard started, model.history != nil else { return nil }
    var sizes = model.items.map(\.pixelSize)
    sizes.append(pixels)
    let width = screen.frame.width
    let gap = ClotheslineLayout.gap(notch: notch(screen))
    while sizes.count > 1, ClotheslineLayout.fits(sizes, width: width, gap: gap) < sizes.count {
      sizes.removeFirst()
    }
    let plan = ClotheslineLayout.plan(sizes, width: width, gap: gap)
    // 新的那一张排在最后（挂上的先后）
    guard let card = plan.cards.last, plan.cards.count == sizes.count else { return nil }
    // 往上抬一个落差：飞行卡片把它送到这儿，交接之后它从这儿落到绳子上（减弱动态效果时不落、直接到位）
    let raised =
      reducesMotion() ? card : card.offsetBy(dx: 0, dy: -ClotheslineLayout.dropHeight)
    return Self.screenRect(raised, in: Self.panelFrame(for: screen))
  }

  /// 挂不下的先从最旧的取下来（还在历史里）
  private func trimmed(_ ids: [UUID], on screen: NSScreen?) -> [UUID] {
    guard let screen, let history = model.history else { return ids }
    var ids = ids
    let gap = ClotheslineLayout.gap(notch: notch(screen))
    while ids.count > 1 {
      let sizes = ids.compactMap { id in history.items.first { $0.id == id }?.pixelSize }
      guard
        ClotheslineLayout.fits(sizes, width: screen.frame.width, gap: gap) < sizes.count
      else { break }
      ids.removeFirst()
    }
    return ids
  }

  // MARK: 出来、收起

  /// 有一张正在飞过来：绳子先滑下来等着（2026-10-26 用户手测反馈——原来空绳时卡片先停在那儿、
  /// 过一会儿绳子才滑下来，看着像「飞到一半又回来」）。等不来（截图取消了、没拷成）就按 pegHold 自己收
  func prepare(on screen: NSScreen) {
    guard started, model.history != nil else { return }
    awaitingCard = true
    holdUntil = .now.advanced(by: ClotheslineLayout.pegHold)
    present(on: screen)
  }

  /// 全局快捷键（C1）：出来 / 收起
  func toggle() {
    guard started, !model.isEmpty else { return }
    if shown != nil { return hide(animated: true) }
    guard let screen = screenForMouse() else { return }
    holdUntil = .now.advanced(by: ClotheslineLayout.pegHold)
    present(on: screen)
  }

  private func present(on screen: NSScreen) {
    pendingShow?.cancel()
    pendingShow = nil
    guard started, !model.isEmpty || awaitingCard, !isSuppressed() else { return }
    let panel = self.panel ?? makePanel()
    let frame = Self.panelFrame(for: screen)
    let moving = shown != nil && panel.isVisible
    // 先记下挂在哪块屏：replan 要起表，起表得先认准面板是露着的
    shown = screen
    replan(for: screen)
    linger = ClotheslineLayout.Linger()
    if moving {
      // 换屏跟过去（D3）：直接挪，不再滑一次
      panel.setFrame(frame, display: true)
    } else {
      panel.setFrame(frame, display: false)
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Style.fadeIn
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
      }
      slide(down: true)
    }
    startWatching()
  }

  /// 滑下来 / 收回去：窗口淡入淡出，内容在菜单栏下面上下滑（glide 弹簧）。
  /// 减弱动态效果时 caAnimation 给 nil，只剩淡入淡出（拍板 D1）
  private func slide(down: Bool) {
    guard let layer = host?.layer, let height = panel?.frame.height else { return }
    layer.transform = CATransform3DIdentity
    guard
      let slide = Style.Motion.glide.caAnimation(keyPath: "transform.translation.y")
        as? CASpringAnimation
    else { return }
    // AppKit 图层 y 向上：收着时内容在面板上面（菜单栏底下，看不见）
    slide.fromValue = down ? height : 0
    slide.toValue = down ? 0 : height
    layer.add(slide, forKey: "slide")
  }

  func hide(animated: Bool) {
    pendingShow?.cancel()
    pendingShow = nil
    holdUntil = nil
    awaitingCard = false
    stopWatching()
    stopTicking()  // 收起了一定停表（看不见的东西不许还在跑物理）
    guard shown != nil else { return }
    shown = nil
    guard let panel, panel.isVisible else { return }
    onHide()
    guard animated, !Style.reduceMotion else {
      panel.orderOut(nil)
      return
    }
    slide(down: false)
    NSAnimationContext.runAnimationGroup { context in
      // 和滑回去的位移同时跑（0.18 s：淡得太快就看不见它滑上去了）
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // 淡的时候又出来了就别收
        guard let self, self.shown == nil else { return }
        panel.orderOut(nil)
      }
    }
  }

  // MARK: 排版和物理

  /// 重排：算静止时的样子（plan），再按它搭两段绳子、把每张卡挂到最近的那个质点上。
  /// 绳子只在这块屏的宽度变了时重搭（换屏、插拔显示器）：不然每挂一张就把正在晃的绳子清零了
  private func replan(for screen: NSScreen? = nil) {
    guard let screen = screen ?? shown else { return }
    layout(width: screen.frame.width, gap: ClotheslineLayout.gap(notch: notch(screen)))
    startTicking()
  }

  /// 按这块宽度重排、搭绳子、把这一帧交给视图（截图自检和单测直接调它，不用真屏幕）
  func layout(width: CGFloat, gap: CGFloat) {
    model.plan = ClotheslineLayout.plan(model.items.map(\.pixelSize), width: width, gap: gap)
    if ropes.count != model.plan.ropes.count
      || zip(ropes, model.plan.ropes).contains(where: { rope, planned in
        rope.point(0) != planned.from || rope.point(rope.nodes.count - 1) != planned.to
      })
    {
      ropes = model.plan.ropes.map { ClotheslineRope(from: $0.from, to: $0.to) }
      // 第一帧就是挂着东西时的静止样子（刚搭起来的绳子还没被重力拉开）
      for index in ropes.indices { ropes[index].settle() }
      nodes = [:]
    }
    // 每张卡挂在哪个质点上：按它静止时的中线找最近的
    var taken: [UUID: (rope: Int, index: Int)] = [:]
    for (item, card) in zip(model.items, model.plan.cards) {
      let side = card.midX < CGFloat(model.plan.ropes[0].to.x) ? 0 : 1
      guard ropes.indices.contains(side) else { continue }
      taken[item.id] = (side, ropes[side].nearest(x: card.midX))
    }
    // 挂上 / 取下的重量跟着变
    for index in ropes.indices {
      for node in ropes[index].nodes.indices { ropes[index].setLoaded(node, false) }
    }
    for (id, node) in taken where falling[id] == nil {
      ropes[node.rope].setLoaded(node.index, true)
    }
    nodes = taken
    publish()
  }

  /// 跑到静止再出图（截图自检；真用的时候是 display link 一帧帧跑）
  func settleNow() {
    for index in ropes.indices { ropes[index].settle() }
    falling = [:]
    publish()
  }

  /// 把这一帧的样子交给视图：卡片挂在质点下面、跟着两侧质点的连线转；减弱动态效果时就是 plan 里静止的样子
  private func publish() {
    guard !reducesMotion(), !ropes.isEmpty else {
      model.ropes = model.plan.ropes.map { Self.staticPoints($0) }
      model.hangs = zip(model.items, model.plan.cards).map {
        Hang(id: $0.id, rect: $1, angle: 0)
      }
      return
    }
    model.ropes = ropes.map(\.points)
    model.hangs = zip(model.items, model.plan.cards).compactMap { item, card in
      guard let node = nodes[item.id], ropes.indices.contains(node.rope) else { return nil }
      let point = ropes[node.rope].point(node.index)
      let drop = falling[item.id]?.drop ?? 0
      let rect = CGRect(
        x: point.x - card.width / 2, y: point.y + ClotheslineLayout.hangDrop + drop,
        width: card.width, height: card.height)
      let tilted =
        Double(ropes[node.rope].angle(at: node.index)) + ClotheslineLayout.tilt(for: item.id)
      return Hang(
        id: item.id, rect: rect,
        angle: min(max(tilted, -ClotheslineLayout.maxTilt), ClotheslineLayout.maxTilt))
    }
  }

  private typealias Hang = ClotheslineModel.Hang

  /// 静止的绳子（减弱动态效果时画它）：plan 里那条二次贝塞尔采几个点
  private static func staticPoints(_ rope: ClotheslineLayout.Rope) -> [CGPoint] {
    (0..<ClotheslineRope.count).map { index in
      let t = CGFloat(index) / CGFloat(ClotheslineRope.count - 1)
      let inverse = 1 - t
      return CGPoint(
        x: inverse * inverse * rope.from.x + 2 * inverse * t * rope.control.x + t * t * rope.to.x,
        y: inverse * inverse * rope.from.y + 2 * inverse * t * rope.control.y + t * t * rope.to.y)
    }
  }

  // MARK: 表

  /// 起表（减弱动态效果时不跑物理）。挂上、取下、换屏之后都调一次；全停了自己停表
  private func startTicking() {
    guard !reducesMotion(), link == nil, shown != nil, let view = panel?.contentView
    else { return }
    let link = view.displayLink(target: self, selector: #selector(stepPhysics))
    // 逐帧算物理，同钉图的 popIn、面板的挤压入场：最高 60 Hz
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopTicking() {
    link?.invalidate()
    link = nil
  }

  @objc private func stepPhysics(_ link: CADisplayLink) {
    var moving = false
    // 还在落的：自由落体，碰到绳子那一刻「咬住」——把挂点压低一下，波自然沿绳子传开
    for (id, var fall) in falling {
      fall.speed += ClotheslineLayout.dropGravity
      fall.drop += fall.speed
      if fall.drop >= 0 {
        falling[id] = nil
        if let node = nodes[id], ropes.indices.contains(node.rope) {
          ropes[node.rope].setLoaded(node.index, true)
          ropes[node.rope].push(node.index, dy: ClotheslineLayout.catchDip)
        }
      } else {
        falling[id] = fall
      }
      moving = true
    }
    for index in ropes.indices {
      ropes[index].step()
      if !ropes[index].isAtRest { moving = true }
    }
    publish()
    if !moving { stopTicking() }
  }

  /// 面板：贴在菜单栏下沿、铺满这块屏的宽度
  static func panelFrame(for screen: NSScreen) -> CGRect {
    let top = ClotheslineLayout.top(
      screen: screen.frame, visible: screen.visibleFrame, menuBar: NSStatusBar.system.thickness)
    let height = ClotheslineLayout.panelHeight(width: screen.frame.width)
    return CGRect(
      x: screen.frame.minX, y: top - height, width: screen.frame.width, height: height)
  }

  /// 这块屏上菜单栏那一条（停上去就滑下来、停在上面不收）
  static func strip(for screen: NSScreen) -> CGRect {
    ClotheslineLayout.strip(
      screen: screen.frame, visible: screen.visibleFrame, menuBar: NSStatusBar.system.thickness)
  }

  /// 面板内坐标（原点左上）→ 屏幕坐标
  static func screenRect(_ rect: CGRect, in panel: CGRect) -> CGRect {
    CGRect(
      x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  // MARK: 鼠标

  /// 挂着东西、而且起着，才去听鼠标
  private func updateWatching() {
    guard started, !model.isEmpty else { return unwatchMouse() }
    watchMouse()
  }

  /// 只看位置、不吞事件；鼠标移动不要辅助功能授权（同刘海岛、程序坞预览）
  private func watchMouse() {
    guard monitors.isEmpty else { return }
    let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      MainActor.assumeIsolated { self?.moved() }
      return event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      MainActor.assumeIsolated { self?.moved() }
    }
    monitors = [local, global].compactMap { $0 }
  }

  private func unwatchMouse() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    pendingShow?.cancel()
    pendingShow = nil
    if shown != nil { hide(animated: false) }
  }

  /// 收着时：鼠标停到菜单栏那一条上 0.3 秒就滑下来（出来之后交给定时器）
  private func moved() {
    guard shown == nil, !isSuppressed() else { return }
    guard let screen = screenForMouse(), wantsShow(on: screen) else {
      pendingShow?.cancel()
      pendingShow = nil
      return
    }
    guard pendingShow == nil else { return }
    pendingShow = Task { [weak self] in
      try? await Task.sleep(for: ClotheslineLayout.showDelay)
      guard !Task.isCancelled, let self else { return }
      self.pendingShow = nil
      // 这 0.3 秒里可能挪到别的屏上去了：现取
      guard let screen = self.screenForMouse(), self.wantsShow(on: screen) else { return }
      self.present(on: screen)
    }
  }

  private func wantsShow(on screen: NSScreen) -> Bool {
    ClotheslineLayout.wantsShow(
      mouse: NSEvent.mouseLocation, strip: Self.strip(for: screen), notch: notch(screen))
  }

  private func screenForMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  }

  private func startWatching() {
    guard watch == nil else { return }
    let timer = Timer(timeInterval: ClotheslineLayout.watchInterval, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    RunLoop.main.add(timer, forMode: .common)
    watch = timer
  }

  private func stopWatching() {
    watch?.invalidate()
    watch = nil
    linger = ClotheslineLayout.Linger()
  }

  /// 出来之后每 0.1 秒：别的功能来了、挂着的没了就收；换屏跟过去；鼠标离开满 0.4 秒收起
  private func check() {
    guard let screen = shown, let panel else { return stopWatching() }
    if isSuppressed() { return hide(animated: false) }
    // 亮够了：等不来的那张就不等了（截图取消了、没拷成）
    if let deadline = holdUntil, .now >= deadline {
      holdUntil = nil
      awaitingCard = false
    }
    if model.isEmpty, !awaitingCard { return hide(animated: false) }
    guard let under = screenForMouse() else { return }
    if under !== screen, wantsShow(on: under) { return present(on: under) }
    // 还亮着：离开的倒计时等亮完再算
    guard holdUntil == nil else {
      linger = ClotheslineLayout.Linger()
      return
    }
    let inside = ClotheslineLayout.keepsOpen(
      mouse: NSEvent.mouseLocation, panel: panel.frame, strip: Self.strip(for: screen))
    if linger.update(inside: inside, now: CACurrentMediaTime()) { hide(animated: true) }
  }

  // MARK: 窗口

  private func makePanel() -> NSPanel {
    // styleMask 在 init 里一次写全（.nonactivatingPanel 之后再加不生效）
    let panel = NSPanel(
      contentRect: CGRect(origin: .zero, size: CGSize(width: 100, height: 100)),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    // 本 App 失活时不收（NSPanel 默认收）
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // 卡片自己带阴影（Style.shotCard），窗口不要系统阴影：整块透明的窗口会画出一圈方的影子
    panel.hasShadow = false
    panel.level = .statusBar
    // 所有桌面上都在；**不加 fullScreenAuxiliary**：别的 App 全屏占着那块屏时不出来（拍板 D3）
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    let host = ClotheslineHost(rootView: ClotheslineView(model: model))
    host.sizingOptions = []
    host.wantsLayer = true  // 滑下来的位移动在它的图层上
    panel.contentView = host
    self.panel = panel
    self.host = host
    return panel
  }
}

/// 面板的宿主：第一下点击就给卡片（本 App 不激活、面板永不当 key）
private final class ClotheslineHost: NSHostingView<ClotheslineView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
