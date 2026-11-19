// AppDelegate 里的截图（第五轮体检 H1 从 AppDelegate.swift 拆出）：截图 / 截图翻译 / 识字的框选入口、长截图、出图（拷贝 / 存储 / 另存为 / 钉图，框选和长截图共用 output）、
// 截图历史和标注遮罩、截图类动作共用的冻结与框选（beginCapture、frozenSelection）、取色。

import AppKit
import SwiftUI

extension AppDelegate {
  /// 截图翻译（⌥S）。默认：冻结各屏 → 框选 → 本机识别文字 → 原文记进剪贴板历史 → 翻译浮窗走现有的多服务翻译。
  /// 设置 › 翻译 开着「把译文直接盖回截图上」（PR #5）时：和截图同一个编辑页，框完松手（或单击选中悬停的窗口 / 元素）
  /// 自动翻译——译文贴在选区里，人可以接着标注、复制、保存
  func screenshotTranslate() {
    guard UserDefaults.standard.bool(forKey: Prefs.translateScreenshotOverlay) else {
      return beginCapture(hidingPanels: true) { [self] in
        guard
          let region = await frozenSelection(
            "截图翻译",
            { await RegionSelector.select($0, hint: String(localized: "拖动框选要翻译的文字 · Esc 取消")) })
        else { return nil }
        return { [self] in await translateInPanel(region) }
      }
    }
    captureShots(feature: "截图翻译", hidingPanels: true, autoTranslate: true)
  }

  /// 识字：框选后静默复制识别出的文字（有二维码 / 条码时复制它的内容），轻提示结果，不弹窗
  func recognizeText() {
    beginCapture(hidingPanels: true) { [self] in
      guard
        let region = await frozenSelection(
          "识字",
          {
            await RegionSelector.select(
              $0, hint: String(localized: "拖动框选要识别的文字或二维码 · Esc 取消"))
          })
      else { return nil }
      return { [self] in await copyRecognizedText(in: region) }
    }
  }

  /// 截图：框选后可标注；↩ 复制（同时记进剪贴板历史）、⌘S 快速保存、另存为、T 钉图、S 长截图、识字、翻译，C 复制色值。
  /// repeatingLastRegion：一开始就选中上次的区域（「截取上次区域」热键，可以连按）
  func screenshot(repeatingLastRegion: Bool = false) {
    captureShots(
      feature: "截图", hidingPanels: false, repeatingLastRegion: repeatingLastRegion)
  }

  /// 延时截图（第五轮体检 N2）：倒数 5 / 10 秒（ShotCountdown，录屏倒数的那一套）再走截图；倒数中再按一次 = 取消。
  /// 授权先查（不然数完才说没授权）。临时 Esc 全 App 只有一个：录屏倒数、录音待录条正挂着它时不开始（响一声），
  /// 不然倒数一结束把它们的 Esc 也注销了。倒数中开始了别的框选（beginCapture）、截图功能被关掉都会取消倒数
  func delayedScreenshot() {
    if let shotCountdown { return shotCountdown.cancel() }
    guard !isCapturing, !hotKeys.holdsEscape else { return NSSound.beep() }
    guard screenRecordingAllowed(for: "截图") else { return }
    let countdown = ShotCountdown(
      seconds: Prefs.screenshotDelaySeconds(), hotKeys: hotKeys)
    shotCountdown = countdown
    Task {
      let shoots = await countdown.run()
      shotCountdown = nil
      if shoots, !isCapturing, Feature.screenshot.isOn { screenshot() }
    }
  }

  /// 截图家族共用的后半段（截图、截图翻译）：冻结各屏 → 框选 → 按交回的动作出图。
  /// autoTranslate = 框完松手、单击选中就自动翻译（⌥S）
  private func captureShots(
    feature: LocalizedStringResource, hidingPanels: Bool, repeatingLastRegion: Bool = false,
    autoTranslate: Bool = false
  ) {
    // 工具栏「翻译」就地盖回截图上，还是交出去走翻译浮窗：看设置 › 翻译「把译文直接盖回截图上」
    let overlays = UserDefaults.standard.bool(forKey: Prefs.translateScreenshotOverlay)
    let translate: ((CGImage, CGFloat) async -> ScreenshotOverlay.Outcome)?
    if overlays {
      translate = {
        [weak self] (image: CGImage, pixelsPerPoint: CGFloat) async -> ScreenshotOverlay.Outcome in
        guard let self else { return .init(message: String(localized: "翻译不可用")) }
        return await self.overlayTranslate(image, pixelsPerPoint: pixelsPerPoint)
      }
    } else {
      translate = nil
    }
    beginCapture(hidingPanels: hidingPanels) { [self] in
      let lastRegion = UserDefaults.standard.string(forKey: Prefs.screenshotLastRegion).map(
        NSRectFromString)
      // 带上鼠标指针（X8）只给截图：截图翻译盖回的那一路要识字，指针会挡字
      let cursor = !autoTranslate && UserDefaults.standard.bool(forKey: Prefs.screenshotCursor)
      guard
        let outcome = await frozenSelection(
          feature, cursor: cursor,
          {
            await RegionSelector.capture(
              $0, lastRegion: lastRegion, preselect: repeatingLastRegion,
              autoTranslate: autoTranslate,
              recordingBlocker: { [weak self] in self?.recordingBlocker(.screen) },
              translate: translate)
          })
      else { return nil }
      return await handleCapture(outcome)
    }
  }

  /// 框选交回的结果 → 出图那一步（复制 / 保存 / 钉图 / 识字 / 长截图 / 录屏 / 色值），交给 beginCapture 在「正在截图」的
  /// 标记外面做（E3）。按 S 转的长截图面板还算框选：在这里跑完，交回的是长图的出图
  private func handleCapture(_ outcome: RegionSelector.Outcome) async -> (() async -> Void)? {
    switch outcome {
    case .color(let hex):
      copyColor(hex)
      return nil
    // 截图调整时按 R / 点「录屏」切过去的（录屏第 2 批）：和 ⌥R 框完一样开录
    case .record(let region):
      beginRecording(region)
      return nil
    case .scroll(let region):
      UserDefaults.standard.set(NSStringFromRect(region), forKey: Prefs.screenshotLastRegion)
      // 长截图在实时画面上截、滤掉本 App：没固定的浮层留着只会盖住选区，挡住滚轮和自动滚动
      // （钉图、常驻缩略图同理，体检 B40，在 scrollCapture 里让开）
      hideUnpinnedPanels()
      return await scrollCapture(region)
    case .capture(let capture):
      UserDefaults.standard.set(
        NSStringFromRect(capture.frame), forKey: Prefs.screenshotLastRegion)
      return { [self] in await deliver(capture) }
    }
  }

  /// 截图框选交回的图出成什么（E3：在「正在截图」的标记外面做）
  private func deliver(_ capture: RegionSelector.Capture) async {
    // 拷成 PNG 文件时按下 ⌘C 的那一刻就得占好剪贴板（mac-native §5）：单窗口截图还要等它截完、合成，先取号、承诺文件
    // （有人赶在合成完之前来读，就当场用矩形裁切那张写给它），合成完再用带阴影的那张写盘
    let early: (ticket: Int, offer: ScreenshotOutput.FileOffer?)? =
      capture.window != nil && capture.action == .copy
      ? (nextCopy(), offerShotFile(.image(capture.image, scale: capture.scale))) : nil
    // 单击选中的整扇窗口：换成透明圆角带阴影的那一张（N1，截不到就照旧是矩形裁切）
    let capture = capture.window == nil ? capture : await WindowShot.dress(capture)
    // 先出图、历史在后面并行记（第三轮体检 R6：原来先等历史写完盘才拷贝 / 存储 / 钉图）；
    // 拷贝 / 存储编好的那份 PNG 历史直接拿去当原图，不再编一遍
    let record = { [self] (png: Data) in remember(capture, png: png) }
    switch capture.action {
    case .copy:
      await output(
        .copy, capture.image, scale: capture.scale, frame: capture.frame, window: capture.isWindow,
        early: early, record: record)
    case .pin:
      FlyCard.playShutter()
      pins.pin(capture.image, frame: capture.frame, window: capture.isWindow)
      remember(capture, pinned: true)
    case .save:
      await output(
        .save, capture.image, scale: capture.scale, frame: capture.frame, window: capture.isWindow,
        record: record)
    case .saveAs:
      await output(
        .saveAs, capture.image, scale: capture.scale, frame: capture.frame,
        window: capture.isWindow, record: record)
    case .recognize: await copyRecognizedText(in: capture.image)
    // 「把译文直接盖回截图上」关着时：工具栏的翻译交出来，走翻译浮窗（开着时在截图页里就地翻，不交回这个动作）
    case .translate: await translateInPanel(capture.image)
    }
  }

  /// 出图的三种（框选、长截图共用 output）
  private enum ShotOutput { case copy, save, saveAs }

  /// 拷贝 / 存储 / 另存为：框选和长截图共用（第五轮体检 H1，原来两边各写一遍）。先出图、历史在后面并行记（R6）：
  /// record 拿编好的那份 PNG 记进历史（框选是 remember、长截图是 rememberScroll），交回历史那一条的任务。
  /// window：透明圆角带阴影的窗口截图（N1，角落的缩略图钉图时不套框）；early：拷贝时已经取好的号和承诺的文件（N1 deliver）
  private func output(
    _ kind: ShotOutput, _ image: CGImage, scale: CGFloat, frame: CGRect, window: Bool = false,
    early: (ticket: Int, offer: ScreenshotOutput.FileOffer?)? = nil,
    record: (Data) -> Task<UUID?, Never>
  ) async {
    switch kind {
    case .copy:
      // 拷成文件时先占好剪贴板，再飞卡片、编码（按 ⌘C 的那一刻就得写好，见 offerShotFile）
      let ticket = early?.ticket ?? nextCopy()
      let offer = early.map { $0.offer } ?? offerShotFile(.image(image, scale: scale))
      let land = captured(image, scale: scale, frame: frame, window: window)
      guard let png = await encodePNG(image, scale: scale) else { return }
      let remembered = record(png)
      await copyPNG(png, offer: offer, ticket: ticket)
      land(.copied, png, remembered)
    case .save:
      let land = captured(image, scale: scale, frame: frame, window: window)
      guard let png = await encodePNG(image, scale: scale) else { return }
      let remembered = record(png)
      if let saved = await savePNG(png, asking: false) {
        land(.saved(saved), png, remembered)
        markSaved(remembered, at: saved)
      }
    case .saveAs:
      FlyCard.playShutter()
      guard let png = await encodePNG(image, scale: scale) else { return }
      let remembered = record(png)
      if let saved = await saveImageAs(image, png: png) {
        markSaved(remembered, at: saved)
      }
    }
  }

  /// 框选时按 C：复制放大镜中心的色值（截图、录屏的框选）
  func copyColor(_ hex: String) {
    Paster.write(string: hex, record: true)
    island.show(
      "已复制色值", detail: "\(hex)", leading: Self.color(hex).map(Island.Leading.color) ?? .tone)
  }

  /// 长截图（截图框选后按 S）：遮罩已收起，在实时画面上边滚边拼。面板开着的这段算在这次截图里（isCapturing，期间别的
  /// 截图热键只响一声）；交回的是结束后按选的方式输出那一步，在标记外面做（E3）
  private func scrollCapture(_ region: CGRect) async -> (() async -> Void)? {
    // 压在选区上的钉图会吞掉滚轮、把自动滚动的合成滚轮当缩放（体检 B40）：让开到长截图结束（拷贝、存储、取消、出错），
    // 另存为的存储面板弹出来之前就放回；常驻缩略图直接收走
    pins.suspend(covering: region)
    noteEdge?.floats.suspend(covering: region)  // 浮动便签同钉图：压在选区上的先收走，结束放回
    shelf.dismiss(covering: region)
    // 固定着的剪贴板面板留在屏幕上，它的 ⌘Y 大卡也还开着：压在选区上同样会吞掉滚轮，收走
    if clipboardModel.isQuickLooking, let card = quickLookPanel.panel,
      card.frame.intersects(region)
    {
      card.hide()
    }
    let finished: ScrollCapture.Result?
    do {
      finished = try await ScrollCapture.run(region: region)
    } catch {
      pins.resume()
      if Feature.notes.isOn { noteEdge?.floats.resume() }  // 便签关着时它们是藏着的，别放出来
      island.show("长截图失败", detail: "\(error.localizedDescription)", tone: .error)
      return nil
    }
    pins.resume()
    if Feature.notes.isOn { noteEdge?.floats.resume() }  // 便签关着时它们是藏着的，别放出来
    guard let result = finished else { return nil }
    return { [self] in await deliver(result, region: region) }
  }

  /// 拼好的长图出成什么（E3：在「正在截图」的标记外面做）。同截图：先出图、历史在后面并行记，拷贝 / 存储编好的那份
  /// 历史直接用（R6，长图编一遍要好几百毫秒）
  private func deliver(_ result: ScrollCapture.Result, region: CGRect) async {
    let record = { [self] (png: Data) in rememberScroll(result, png: png, region: region) }
    switch result.action {
    case .copy:
      await output(.copy, result.image, scale: result.scale, frame: region, record: record)
    case .save:
      await output(.save, result.image, scale: result.scale, frame: region, record: record)
    case .saveAs:
      await output(.saveAs, result.image, scale: result.scale, frame: region, record: record)
    case .annotate:
      // 遮罩先开（历史的任务这时还没跑）；遮罩里出图时要的编号那时早记好了
      let remembered = rememberScroll(result, region: region)
      openAnnotate(result.image, scale: result.scale, history: { await remembered.value })
    }
  }

  /// 长截图进历史（拼好的那张没有标注；标注窗口里改完了再回写）。同 remember：并行记、png 现成的就直接用
  private func rememberScroll(
    _ result: ScrollCapture.Result, png: Data? = nil, region: CGRect
  ) -> Task<UUID?, Never> {
    let source = frontmostAppName()
    return Task {
      await shotHistory.record(
        result.image, png: png, composed: result.image, scale: result.scale, kind: .scroll,
        source: source, frame: region)
    }
  }

  /// 记进截图历史（2026-10-26 拍板）：存没画标注的那张 + 标注，成品用时再合成；识字、翻译不记（不产出图）。
  /// **不挡出图**（第三轮体检 R6）：调用方先出图，这里在后面并行记；返回的任务给要编号的那几样（挂晾衣绳、记存到哪），
  /// 编号是 nil = 没记（历史关着、写盘失败）。png 是拷贝 / 存储已经编好的那份：没画标注时原图就是它，直接共用
  /// （历史也按 72 × 倍率的 DPI 编，两份一模一样）；缩略图照成品图（capture.image）缩，不再合成一遍
  @discardableResult private func remember(
    _ capture: RegionSelector.Capture, png: Data? = nil, pinned: Bool = false
  ) -> Task<UUID?, Never> {
    let original = capture.original ?? capture.image
    let shared = original === capture.image ? png : nil
    let source = frontmostAppName()
    return Task {
      await shotHistory.record(
        original, png: shared, composed: capture.image, scale: capture.scale, kind: .shot,
        annotations: capture.annotations, source: source, pinned: pinned, frame: capture.frame,
        window: capture.isWindow)
    }
  }

  /// 历史那一条记好了再记上存到哪（要等编号，R6）：不挡这次截图收尾
  private func markSaved(_ remembered: Task<UUID?, Never>, at url: URL) {
    Task { if let id = await remembered.value { shotHistory.markSaved(id, to: url) } }
  }

  /// 落到晾衣绳上：历史那一条记好了、缩略图读进缓存了才挂（Clothesline.pegWhenRecorded：交接那一帧卡片上就有图），
  /// 挂在飞行卡片落的那块屏上
  func pegger(_ remembered: Task<UUID?, Never>, on screen: NSScreen?) -> () -> Void {
    Clothesline.pegWhenRecorded(
      remembered, warm: { [weak self] id in await self?.clothesline.warm(id) },
      peg: { [weak self] id in self?.clothesline.peg(id, on: screen) })
  }

  /// 截的时候前台是哪个 App（历史里显示来源用；本 App 从不激活，所以这就是用户正在用的那个）
  func frontmostAppName() -> String? {
    NSWorkspace.shared.frontmostApplication?.localizedName
  }

  /// 截图历史窗口（2026-10-26 拍板 C1）：用时才建，关掉放掉（连缩略图缓存一起）。
  /// 每条的操作都接到截图那条路上：拷贝 / 存储 / 另存为走同一套出图，钉图走钉图，改标注开标注窗口。
  /// 晾衣绳（第十族）上的卡片和这里共用同一份 ShotActions，不各接一遍。
  /// deleting：从晾衣绳的「从历史里删掉」进来的（拍板 D2：照历史的规矩问一次，就在这扇窗口里问）
  func showShotHistory(deleting: ShotHistory.Item? = nil) {
    let model =
      shotHistoryWindow?.model ?? ShotHistoryModel(history: shotHistory, actions: shotActions)
    model.openSettings = { [unowned self] in showSettings(.screenshotHistory) }
    if let deleting {
      model.selection = deleting.id
      model.deleting = [deleting.id]
    }
    if let window = shotHistoryWindow { return window.show() }
    let window = ShotHistoryWindow(model: model)
    window.onClose = { [weak self] in
      guard let self else { return }
      shotHistoryWindow = nil
      // 缩略图缓存只留晾衣绳挂着的那几张（P2：原来绳子上挂着一张就整个不清）
      ShotThumbnails.shared.keep(only: clothesline.model.pegged)
    }
    shotHistoryWindow = window
    window.show()
  }

  /// 晾衣绳的全局快捷键（第十族拍板 C1）：绳子出来 / 收起。上面空着时说一声——不然按了没反应
  func toggleClothesline() {
    guard !clothesline.isEmpty else {
      return island.show(
        "晾衣绳上没有东西", detail: "截完图挂上去（设置 › 截图「截完图放哪」）", tone: .info,
        symbol: "info.circle.fill")
    }
    clothesline.toggle()
  }

  /// 录制的那一条的文件被移走 / 删掉了
  func missingShotFile() {
    island.show("文件已经不在了", tone: .warning, symbol: "questionmark.folder")
  }

  /// 历史里那条的原图读不出来（盘上被清了 / 坏了）
  func missingShot() {
    island.show("这张图已经不在了", detail: "历史里的原图被清掉了", tone: .warning)
  }

  /// 长图标注（2026-10-26 拍板）：拼好的长图在自己的窗口里标注，出图走截图那条路、用刘海说结果（同钉图，不飞卡片：
  /// 这时选区多半已经不在眼前了）。一次只开一扇，再开一次就把前一扇换掉。
  /// history：它在历史里是哪一条（刚拼好的长截图是并行记的，出图时等它记完拿编号，R6）。
  /// fromHistory：从截图历史里改标注（历史窗口、晾衣绳、常驻缩略图的「改标注」）——工具栏多一颗「完成」，只存回历史、不出图
  /// （第五轮体检 U7：原来只有出了图才存回，想放回历史只能顺手 ⌘C 一次、把剪贴板冲掉）
  func openAnnotate(
    _ image: CGImage, scale: CGFloat, history: (() async -> UUID?)? = nil,
    annotations: [Annotation] = [], fromHistory: Bool = false
  ) {
    annotateOverlay?.close()
    let original = image
    // 改完的标注回写到历史那一条（拍板 C4：更新同一条，不新建），缩略图照这张成品缩、不再读原图重合成（R6）。
    // 新画的马赛克打进存下的原图（E6）：用遮罩里这张没画标注的，不再读盘。
    // 编号要等历史记完（刚拼好的长截图是并行记的）：另起任务等，不挡出图（同截图那条路）。交回等编号的那个任务
    let writeBack: (CGImage, [Annotation]) -> Task<UUID?, Never> = {
      [unowned self] image, annotations in
      let remembered = Task { await history?() }
      // 裁过（X17）：历史里换成裁好的原图（重写原图、尺寸），标注已经平移到它的坐标里
      let cropped = annotateOverlay?.isCropped == true
      let original = cropped ? annotateOverlay?.historyOriginal ?? original : original
      Task {
        if let id = await remembered.value {
          shotHistory.update(
            id, annotations: annotations, composed: image, original: original, cropped: cropped)
        }
      }
      return remembered
    }
    let done: ((CGImage, [Annotation]) -> Void)? =
      fromHistory
      ? { image, annotations in
        _ = writeBack(image, annotations)
        Island.announce("已存回截图历史")
      } : nil
    let editor = AnnotateOverlay(
      image: image, scale: scale, annotations: annotations, done: done
    ) { [unowned self] action, image, scale, annotations in
      let remembered = writeBack(image, annotations)
      Task {
        switch action {
        case .copy:
          guard let copied = await copyImage(image, scale: scale) else { return }
          island.show(
            "\(FlyCard.Badge.copied.title)",
            detail: copied.detail.map { "\($0)" as LocalizedStringResource },
            leading: Island.thumbnail(of: image))
        case .save:
          guard let saved = await saveImage(image, scale: scale, asking: false) else { return }
          markSaved(remembered, at: saved.url)
          island.show(
            "\(FlyCard.Badge.saved(saved.url).title)", detail: "\(saved.url.lastPathComponent)",
            leading: Island.thumbnail(of: image), actions: .file(saved.url))
        case .saveAs:
          if let saved = await saveImageAs(image, scale: scale) {
            markSaved(remembered, at: saved)
          }
        case .recognize: await copyRecognizedText(in: image)
        case .translate, .pin: break  // 长图的工具栏里没有这两样
        }
      }
    }
    editor.onClose = { [weak self] in self?.annotateOverlay = nil }
    annotateOverlay = editor
    editor.show()
  }

  /// 截图和截图翻译共用的开头：互斥。select 是框选（和长截图）那一段，「正在截图」的标记只占它——遮罩、长截图面板一收起
  /// 就放开（第五轮体检 E3：原来等出图那一步全做完才放，另存为面板开着、第一次识字在准备模型、快速保存写到卡住的网络盘时，
  /// 截图、录屏、划词翻译这些快捷键全被静默吞掉）。select 交回的是出图那一步，在标记外面做：这时下一次截图已经可以开始，
  /// 要拿键盘的出图（另存为面板、翻译浮窗）先等它收起（untilCaptureEnds）。被标记拦下的快捷键响一声。
  /// 截图（热键、⌥X、启动器、菜单栏）不收自家窗口：用户 2026-09-26 要能截到本 App，开着的浮层、设置窗、钉图留在
  /// 冻结帧里、能悬停和单击选中，截完还开着（遮罩当 key、被点时浮层不自动收起，OverlayPanel.isSelectingRegion）；
  /// 按 S 转长截图时才收起没固定的。截图翻译 / 识字（hidingPanels）照旧收起没固定的浮层；固定着的不收，照样截进去
  func beginCapture(
    hidingPanels: Bool, _ select: @escaping () async -> (() async -> Void)?
  ) {
    guard !isCapturing, !isReadingSelection else {
      if isCapturing { NSSound.beep() }
      return
    }
    isCapturing = true
    // 延时截图还在倒数（N2）：手动开始了截图 / 录屏框选，那一次不要了
    shotCountdown?.cancel()
    // 启动台是全屏面板，截图 / 录屏的冻结帧里不能有它：先收掉（不留动画，别让它出现在冻结帧里）
    launchpad.close(animated: false)
    // 便签屏幕边缘扇着的那一列当场收起（先落盘），冻结帧里不留半截；打开着的便签是内容，照样截进去
    noteEdge?.suspend(.keepsOpen)
    if hidingPanels { hideUnpinnedPanels() }
    Task {
      let output = await select()
      isCapturing = false
      await output?()
    }
  }

  /// 等这一次框选 / 长截图收起（E3：出图在标记外面做，这时下一次截图可能已经开始了）。要拿键盘的出图——另存为的面板、
  /// 翻译浮窗——先等它：遮罩开着时 key 被抢走，遮罩就收不到 Esc。
  /// ponytail: 每 0.1 s 看一眼，只在两次截图叠在一起时才转；要省就换成放开标记时 resume 的 continuation
  func untilCaptureEnds() async {
    while isCapturing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
  }

  /// 收起没固定的浮层。先收剪贴板面板再收翻译浮窗：反过来浮窗的 onHide 会把 key 还给剪贴板面板
  private func hideUnpinnedPanels() {
    builtClipboardPanel?.hideUnlessPinned()
    builtLauncherPanel?.hide()  // 启动器没有固定
    statusPicker.panel?.hide()  // 选状态的面板也没有
    noteCapture?.panel.hide()  // 快速记一条也没有（草稿留着）
    builtTranslatePanel?.hideUnlessPinned()
    noteEdge?.suspend(.unlessPinned)  // 屏幕边缘打开着的便签同理：没固定的收（先落盘）
  }

  /// 有「屏幕录制」授权（截图家族、录系统声音开始前查）；没有就同设置 › 通用、引导里的授权按钮（Permissions.grant：没问过
  /// 只弹系统框，问过了才打开系统设置的「屏幕录制」；第五轮体检 U11，原来两样一起来，第一次截图就是两个窗叠着）+ 警告岛说
  /// feature 要用，返回 false
  func screenRecordingAllowed(for feature: LocalizedStringResource) -> Bool {
    guard !Permissions.isScreenRecordingAllowed else { return true }
    Permissions.grant(.screenRecording)
    island.show(
      "需要「屏幕录制」授权", detail: "\(String(localized: feature))要用，授权后可能要重新打开本 App",
      tone: .warning,
      actions: [.settings(for: .screenRecording)])
    return false
  }

  /// 查屏幕录制授权 → 冻结各屏（本 App 开着的窗口留在画面里）→ 暂停全局热键框选 → 遮罩收起后把 key 还给截图前的
  /// key 窗口（还开着的话；只 makeKey，不激活本 App）。没授权 / 截屏失败时用刘海提示，返回 nil。
  /// 框选期间别的热键会弹出浮层抢走 key（遮罩就收不到 Esc）；设置里正在录快捷键时热键本来就停着，结束后不能替它恢复
  func frozenSelection<T>(
    _ feature: LocalizedStringResource, cursor: Bool = false,
    _ select: ([ScreenCapture.Shot]) async -> T?
  ) async -> T? {
    guard screenRecordingAllowed(for: feature) else { return nil }
    let shots: [ScreenCapture.Shot]
    do {
      // 截屏的系统服务不返回时最多等 5 秒（E22）：不然 isCapturing 一直为真，截图家族的热键全被静默忽略
      guard
        let frozen = try await ScreenCapture.within(
          ScreenCapture.freezeTimeout, { try await ScreenCapture.freeze(cursor: cursor) })
      else {
        island.show("截屏没有响应", detail: "请再试一次", tone: .warning)
        return nil
      }
      shots = frozen
    } catch {
      island.show("截屏失败", detail: "\(error.localizedDescription)", tone: .error)
      return nil
    }
    let hotKeysWereActive = hotKeys.isActive
    hotKeys.suspend()
    defer { if hotKeysWereActive { hotKeys.reload() } }
    let previousKey = NSApp.keyWindow
    let result = await select(shots)
    // 本 App 在前台时（设置窗是 key），遮罩 orderOut 后 AppKit 可能把 key 交给别的自家窗口（比如浮层），所以不只看 nil
    if let previousKey, previousKey.isVisible, NSApp.keyWindow !== previousKey {
      previousKey.makeKey()
    }
    return result
  }

  /// 编成 PNG（截图那条路上拷贝 / 存储 / 常驻缩略图 / 历史共用这一份，R6）；失败时岛说一声
  private func encodePNG(_ image: CGImage, scale: CGFloat) async -> Data? {
    guard let png = await ScreenshotOutput.png(image, scale: scale) else {
      island.show("截图编码失败", detail: "请重试", tone: .error)
      return nil
    }
    return png
  }

  /// 截图复制：先占好剪贴板（拷成文件时），再编成 PNG、copyPNG。返回放进剪贴板的是图像还是文件，编码失败 nil
  func copyImage(_ image: CGImage, scale: CGFloat, name: String? = nil) async
    -> ScreenshotOutput.Copied?
  {
    let ticket = nextCopy()
    let offer = offerShotFile(.image(image, scale: scale), name: name)
    guard let png = await encodePNG(image, scale: scale) else { return nil }
    return await copyPNG(png, name: name, offer: offer, ticket: ticket)
  }

  private func nextCopy() -> Int {
    copies += 1
    return copies
  }

  /// 设置 › 截图「截图拷贝为」选了 PNG 文件：**按下拷贝的那一刻**就把剪贴板写好（承诺一个文件，谁来读才给，
  /// ScreenshotOutput.FileOffer），编码、写盘在后面；不是这个设置给 nil。一次拷贝只调一次——跨电脑的剪贴板工具按 ⌘C
  /// 那一刻就读、剪贴板短时间里连着变几次它就乱（2026-11-06 用户用 USB 对拷线实测）
  private func offerShotFile(_ source: ScreenshotOutput.FileOffer.Source, name: String? = nil)
    -> ScreenshotOutput.FileOffer?
  {
    guard Prefs.copiesShotAsFile() else { return nil }
    let offer = ScreenshotOutput.FileOffer(
      url: ScreenshotOutput.copyFileURL(name: name), source: source)
    Paster.write(promising: offer)
    return offer
  }

  /// 截图的每一种「拷贝」都走这里（截图、长截图、钉图、常驻缩略图、晾衣绳 / 历史、存储失败的兜底）：经 Paster 写进剪贴板
  /// （watcher 会跳过），所以自己记进剪贴板历史。设置 › 截图「截图拷贝为」选了 PNG 文件时剪贴板里只有一个文件
  /// （同在访达里拷贝一个文件，2026-11-06 拍板 Q3）：offer 是按下时已经占好的（offerShotFile），没给就在这里占；
  /// 写不成文件就改放图像。剪贴板历史两种都记成图片（Q5：临时文件清掉以后这条照样能用）
  /// ticket：按下拷贝那一刻取的号（nextCopy；没给 = 现在取）——写图像时已经有更新的一次拷贝就不写剪贴板
  @discardableResult
  func copyPNG(
    _ png: Data, name: String? = nil, offer: ScreenshotOutput.FileOffer? = nil,
    ticket: Int? = nil
  ) async -> ScreenshotOutput.Copied {
    let ticket = ticket ?? nextCopy()
    var copied = ScreenshotOutput.Copied.image
    if let offer = offer ?? offerShotFile(.png(png), name: name), await offer.fulfill(png) {
      copied = .file(offer.url)
    } else if ticket == copies {
      Paster.write([.png: png])
    }
    guard recordsClipboard else { return copied }  // 菜单栏暂停了记录、剪贴板关着
    var item = ClipItem(kind: .image)
    guard let info = await clipboardStore.images.save(png, isPNG: true, id: item.id) else {
      return copied
    }
    item.image = info
    clipboardStore.record(item)
    return copied
  }

  /// ⌘S 快速保存 / 另存为（asking）；返回存到的文件和编码好的 PNG（取消、失败为 nil）
  @discardableResult
  func saveImage(_ image: CGImage, scale: CGFloat, asking: Bool) async -> (
    url: URL, png: Data
  )? {
    guard let png = await encodePNG(image, scale: scale) else { return nil }
    return await savePNG(png, asking: asking).map { ($0, png) }
  }

  /// 另存为（截图、长截图、钉图）：不飞卡片、不进常驻缩略图，存好了用刘海说。返回存到哪（取消、失败是 nil）
  @discardableResult func saveImageAs(_ image: CGImage, scale: CGFloat) async -> URL? {
    guard let png = await encodePNG(image, scale: scale) else { return nil }
    return await saveImageAs(image, png: png)
  }

  /// 另存为编好的那份（截图那条路上和历史共用一份 PNG，R6）；image 只给岛上的缩略图
  private func saveImageAs(_ image: CGImage, png: Data) async -> URL? {
    guard let url = await savePNG(png, asking: true) else { return nil }
    island.show(
      "已保存", detail: "\(url.lastPathComponent)", leading: Island.thumbnail(of: image),
      actions: .file(url))
    return url
  }

  /// 存编码好的 PNG；返回存到的文件（取消、失败为 nil）。失败时截图改放进剪贴板，别让这张图就这么丢了；
  /// 没有写权限时岛上给出路（U7）
  func savePNG(_ png: Data, asking: Bool) async -> URL? {
    // 另存为的面板要拿键盘：下一次截图的遮罩这时开着就等它收起（E3）
    if asking { await untilCaptureEnds() }
    do {
      return asking
        ? try await ScreenshotOutput.saveAs(png) : try await ScreenshotOutput.quickSave(png)
    } catch {
      await copyPNG(png)
      // 另存为是自己选的位置：只给授权，不给「更改保存位置」（那是快速保存的设置）
      let actions =
        !ScreenshotOutput.isPermissionDenied(error)
        ? [] : asking ? [.settings(for: .filesAndFolders)] : saveFolderActions
      island.show(
        "保存失败，截图已复制到剪贴板", detail: "\(error.localizedDescription)", tone: .warning,
        actions: actions)
      return nil
    }
  }

  /// 存不进保存目录（没有写权限：文件夹授权被拒、只读的文件夹）时岛上的出路（第四轮体检 U7）：「打开系统设置」到
  /// 「文件和文件夹」授权（全 App 同一个按钮，Island.Action.settings），或者「更改保存位置」到 设置 › 截图。
  /// 录制挪不进保存目录时同一份
  var saveFolderActions: [Island.Action] {
    [
      .settings(for: .filesAndFolders),
      .init("更改保存位置", opens: true) { [unowned self] in showSettings(.screenshotSaveFolder) },
    ]
  }

  /// 截图落地：快门声 + 飞行卡片（遮罩刚收起就飞，不等编码）。返回的 land 在复制 / 保存成功后调，给卡片角标、编码好的
  /// PNG 和记历史的那个任务，角标弹完后交给常驻缩略图（ShotShelf：拷贝、存储、拖出都用这份 PNG，不留整张解码的图）
  /// 或者挂到晾衣绳上（要历史的编号，记好了才挂，pegger）；减弱动态效果时不飞，land 时缩略图直接在角落淡入。
  /// 失败不调（另有提示）
  private func captured(_ image: CGImage, scale: CGFloat, frame: CGRect, window: Bool = false)
    -> (
      FlyCard.Badge, Data, Task<UUID?, Never>
    ) -> Void
  {
    FlyCard.playShutter()
    var png = Data()
    // 挂到晾衣绳上的那一下（land 时才有记历史的任务，闭包按引用拿着它）
    var peg: () -> Void = {}
    // 记历史的那个任务（角落缩略图的「改标注」等它的编号，X7）
    var history: Task<UUID?, Never>?
    let pixels = CGSize(width: image.width, height: image.height)
    let landing = shotLanding(pixels: pixels, frame: frame)
    let linger: (CGRect, FlyCard.Badge) -> Void = { [weak self] rect, badge in
      guard let self else { return }
      switch landing.placement {
      case .corner:
        shelf.add(
          image, png: png, scale: scale, source: frame, at: rect, badge: badge, history: history,
          window: window)
      case .clothesline: peg()
      case .none: break
      }
    }
    // 设置 › 截图「截完图放哪」选了「都不要」（体检 D18 原来那个开关，晾衣绳拍板 B1 升成三选一）：
    // 卡片落地弹完角标停 0.9 s 自己滑走（不给 linger）；减弱动态效果时只有岛
    let keeps = landing.placement != .none
    guard Style.reduceMotion else {
      let flight = FlyCard.fly(image, from: frame, to: landing.slot, linger: keeps ? linger : nil)
      flight.onShow = { [weak self] in self?.statusItem?.pop() }
      return { [weak self] badge, data, remembered in
        png = data
        history = remembered
        if let self { peg = pegger(remembered, on: landing.screen) }
        flight.land(badge)
      }
    }
    return { [weak self] badge, data, remembered in
      guard let self else { return }
      png = data
      history = remembered
      peg = pegger(remembered, on: landing.screen)
      // 不飞就没有落地的角标：结果用刘海说（Whisker：减弱动态效果时飞行卡片改成轻提示；岛自己会播报）
      let actions: [Island.Action] = if case .saved(let url) = badge { .file(url) } else { [] }
      island.show("\(badge.title)", leading: Island.thumbnail(of: image), actions: actions)
      guard keeps, let rect = landing.slot ?? FlyCard.landingRect(for: frame) else { return }
      linger(rect, badge)
    }
  }

  /// 截完图放哪（晾衣绳拍板 B1）和落点：挂晾衣绳时落在绳子上那个位置（挂不上——历史关着、绳子一张都放不下——
  /// 就当「都不要」）；角落的缩略图和「都不要」按原来的右下角落点（nil = FlyCard 自己算）。
  /// screen 是落在哪块屏上：挂的时候照它排（B9：原来挂的时候按鼠标所在的屏取下，和落点不是一块屏就对不上）
  func shotLanding(pixels: CGSize, frame: CGRect) -> (
    placement: Prefs.ShotPlacement, slot: CGRect?, screen: NSScreen?
  ) {
    let placement = Prefs.ShotPlacement.current()
    guard placement == .clothesline, Feature.screenshot.isOn,
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
      }) ?? NSScreen.main,
      let slot = clothesline.slot(for: pixels, on: screen)
    else { return (placement == .clothesline ? .none : placement, nil, nil) }
    // 绳子先滑下来等着（这会儿卡片才刚起飞）：空绳时原来是卡片先停在那儿、绳子过一会儿才来
    clothesline.prepare(on: screen)
    return (.clothesline, slot, screen)
  }

  /// "#RRGGBB" → 色块（取色的轻提示用）
  private static func color(_ hex: String) -> NSColor? {
    guard hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(
      srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }
}
