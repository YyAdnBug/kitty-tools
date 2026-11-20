// 框选遮罩的出图（第五轮体检 H1 从 SelectionView.swift 拆出）：交回 RegionSelector 的各种动作、截图翻译盖回选区和译文卡片、转长截图 / 录屏，悬停认窗口 / 元素的那几层（滚轮换层）。

import AppKit

extension SelectionView {
  // MARK: 输出

  func output(_ action: RegionSelector.Action) {
    // 开着「把译文盖回截图上」（设置 › 翻译，有 translateHandler）时留在截图页里翻：选区上扫光、翻完把译文贴回选区，
    // 不像其它出图键那样收起遮罩；关着时照旧交出去、走翻译浮窗
    // 一键打码还在识字：等它落下再出图，不然号码跟着图出去了
    if redacting {
      NSSound.beep()
      return flashHint([String(localized: "正在打码，稍等再出图")])
    }
    if case .translate = action, translateHandler != nil { return translateInPlace() }
    endEditing()
    guard let selection, let window else { return }
    let pixels = RegionSelector.pixelRect(
      selection, viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height))
    let rendered =
      annotates
      ? Annotation.render(annotations, over: image, pixelRect: pixels, viewSize: bounds.size)
      : image.cropping(to: pixels)
    guard let rendered else { return session.finish(nil) }
    // 截图圆角：拷贝 / 存储 / 钉图出去的图按框的圆角把四角裁透明（识字、翻译要的是字，不裁）；历史里的原图同样裁
    let corner = selectionRadius * CGFloat(pixels.width) / max(1, selection.width)
    let rounds = corner > 0 && [.copy, .save, .saveAs, .pin].contains(action)
    let round = { (image: CGImage) in
      rounds ? WindowShot.rounded(image, radius: corner) ?? image : image
    }
    let result = round(rendered)
    // 截图历史要没画标注的那一张 + 挪到这张图里的标注坐标（拍板 A1）；没画标注时成品就是原图，不白渲一遍
    let original =
      annotations.isEmpty
      ? result
      : Annotation.render([], over: image, pixelRect: pixels, viewSize: bounds.size).map(round)
    let moved = annotations.map {
      $0.offset(by: CGSize(width: -selection.minX, height: -selection.minY))
    }
    session.finish(
      .capture(
        .init(
          image: result, frame: selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY),
          action: action, original: original, annotations: moved,
          window: windowShot(for: action))))
  }

  /// 这次出图要不要换成单独截的那扇窗口（N1）：设置开着、单击选中的整扇窗口、选区没再动过、没贴着就地翻译的译文
  /// （译文贴在冻结帧上，窗口里没有）、出的是图（拷贝 / 存储 / 另存为 / 钉图；识字、翻译要的是字）。
  /// 是的话现在（遮罩还在）就开始单独截，连同冻结时别的 App 的窗口盖住它的那几块一起交出去（WindowShot 文件头）
  func windowShot(for action: RegionSelector.Action) -> WindowShot.Pending? {
    guard let clickedWindow, clickedWindow.frame == selection, untranslated == nil,
      [.copy, .save, .saveAs, .pin].contains(action),
      styleDefaults.bool(forKey: Prefs.screenshotWindowShadow)
    else { return nil }
    let id = clickedWindow.id
    let snapshot = session.snapshotWindow
    return WindowShot.Pending(
      shot: Task { await snapshot(id) },
      covered: WindowShot.covered(clickedWindow.index, windows: windows, owners: owners))
  }

  /// 就地翻译（工具栏「翻译」）：不收起遮罩——选区上扫光，翻完把译文图贴回冻结帧的选区位置，
  /// 已经画的标注留着（它们一直浮在图上面），人还留在截图页，可以接着标注 / 复制 / 保存
  func translateInPlace() {
    guard !translating, let handler = translateHandler, let selection else { return }
    endEditing()
    // 同一个选区再翻：从没贴过译文的那张原图截、贴回那张上（不然识字读的是盖了译文的图，等于把译文再翻一遍）。
    // 选区一变 untranslated 就清掉了，有它时它的选区就是这一个
    let base = untranslated?.image ?? image
    let pixels = RegionSelector.pixelRect(
      selection, viewSize: bounds.size, imageSize: CGSize(width: base.width, height: base.height))
    guard let cropped = base.cropping(to: pixels) else { return }
    let translatedSelection = selection
    // 字号下限按点算：冻结帧每点几个像素（Retina 屏 2）
    let pixelsPerPoint = CGFloat(base.width) / max(1, bounds.width)
    // 原来的卡片等结果回来再换：这次失败的话它和图上的译文都照旧，看原文、拷贝还能用
    translating = true
    refresh()
    translateTask?.cancel()
    translateTask = Task { @MainActor [weak self] in
      let result = await handler(cropped, pixelsPerPoint)
      var replaced: CGImage?
      if let patch = result.image {
        // 整屏冻结帧（5K 屏约 60 MB）在主线程外合成
        replaced = await ScreenshotOverlay.paste(patch, into: base, at: pixels)
      }
      guard let self, !Task.isCancelled else { return }
      translating = false
      translateTask = nil
      guard result.image != nil || !result.leftovers.isEmpty else {
        refresh()
        return flashHint([result.message ?? String(localized: "翻译失败")])
      }
      if result.image != nil, replaced == nil {
        refresh()
        return flashHint([String(localized: "合成失败")])
      }
      // 翻的时候选区被换掉了（框选和工具栏这时不动，防万一）：这份译文贴不回去
      guard selection == translatedSelection else { return refresh() }
      showingOriginal = false
      if let replaced {
        untranslated = (base, translatedSelection)
        translated = replaced
        image = replaced
      } else {
        // 这次一段都没画（全进了卡片）：图回到原图，没有可换的
        untranslated = nil
        translated = nil
        image = base
      }
      // 标注不动：它们一直画在冻结帧上面，出图时照旧叠上去；马赛克读的是标注层手里那张图，换成新的
      annotationCanvas?.image = image
      needsDisplay = true
      refresh()
      showTranslationCard(
        result.leftovers, translation: result.translation, toggles: translated != nil)
      let hint = Self.translatedHint(leftovers: result.leftovers.count, drewAny: replaced != nil)
      flashHint([hint])
      // 出了卡片读屏要知道（顶部提示只是看的）
      announce(hint)
    }
  }

  /// 就地翻译完的顶部提示：到字号下限也放不下的段图上留着原文，译文在卡片里
  static func translatedHint(leftovers: Int, drewAny: Bool) -> String {
    guard leftovers > 0 else { return String(localized: "已替换为译文") }
    return drewAny
      ? String(localized: "有 \(leftovers) 段放不下，译文放在卡片里") : String(localized: "选区太小，译文放在卡片里")
  }

  /// 翻完挂的译文卡片（截图自检也直接调；第二轮 E1 起总挂）：宽同选区、夹在 240–420 pt，高最多到屏幕的四成；
  /// 放在工具栏的另一侧（cardPlacement），从靠选区的那条边长出来。没有放不下的段时只是一条窄栏（看原文、拷贝、✕）；
  /// 译文和放不下的段都没有就什么都不做。toggles：图上画了译文、能换回原文看
  func showTranslationCard(
    _ leftovers: [ScreenshotOverlay.Leftover], translation: String, toggles: Bool
  ) {
    closeTranslationCard()
    let text =
      translation.isEmpty ? leftovers.map(\.translation).joined(separator: "\n\n") : translation
    guard let selection, !text.isEmpty else { return }
    let width = min(
      max(selection.width, TranslationCard.minWidth), TranslationCard.maxWidth, bounds.width - 20)
    let card = TranslationCard(
      leftovers, translation: text, toggles: toggles, selection: selection, width: width,
      maxHeight: bounds.height * 0.4)
    card.onCopy = { [unowned self] in copyTranslation() }
    card.onClose = { [unowned self] in closeTranslationCard() }
    if toggles { card.onToggle = { [unowned self] in toggleOriginal() } }
    // 卡片里的字拿着焦点时按的键交还给遮罩：Esc 收卡片、↩ 拷贝截图、工具键照常
    card.onKey = { [unowned self] event in
      window?.makeFirstResponder(self)
      keyDown(with: event)
    }
    card.onFocus = { [unowned self] in
      finishSizeEditing(commit: true)
      endEditing()
    }
    let toolbarFrame = toolbar.flatMap { $0.isShown ? $0.frame : nil }
    let (origin, edge) = Self.cardPlacement(
      size: card.frame.size, selection: selection, toolbar: toolbarFrame, in: bounds)
    card.setFrameOrigin(origin)
    addSubview(card)
    translationCard = card
    card.grow(true, from: edge, anchorX: min(max(selection.midX - origin.x, 0), card.frame.width))
    refresh()
  }

  /// 收起译文卡片：焦点在卡片的字上就还给遮罩（不然按键没人接）；正换回原文在看时图换回译文（开关跟着卡片走了）
  func closeTranslationCard() {
    guard let card = translationCard else { return }
    translationCard = nil
    if showingOriginal { toggleOriginal() }
    if card.owns(window?.firstResponder) { window?.makeFirstResponder(self) }
    card.removeFromSuperview()
    refresh()
  }

  /// 卡片上的「拷贝译文」：全部段的译文（段间空一行），本 App 生成的新文字，记进剪贴板历史
  private func copyTranslation() {
    guard let card = translationCard else { return }
    Paster.write(string: card.translation, record: true)
    flashHint([String(localized: "已拷贝译文")])
  }

  /// 卡片上的「看原文」：图上换回原文 / 再换回译文，不重新请求；出图按当时看到的那张
  private func toggleOriginal() {
    guard let untranslated, let translated else { return }
    showingOriginal.toggle()
    image = showingOriginal ? untranslated.image : translated
    annotationCanvas?.image = image
    needsDisplay = true
    translationCard?.showOriginal(showingOriginal)
    if translationCard != nil {
      flashHint([showingOriginal ? String(localized: "正在看原文") : String(localized: "已换回译文")])
    }
  }

  /// 译文卡片放哪（拍板 B3，纯函数，配单测）：选区外、工具栏的另一侧（栏在下面挂上面、栏在上面挂下面），离选区 10，
  /// 左边和选区对齐、夹在屏内 10；那一侧放不下挂到工具栏外面（让出样式托盘）；都放不下（选区差不多整屏）放进选区左下角
  /// 离边 8，压到栏（连托盘）就挪到它上面。edge 是靠选区的那条边（从那里长出来）
  static func cardPlacement(
    size: CGSize, selection: CGRect, toolbar: CGRect?, in bounds: CGRect
  ) -> (origin: CGPoint, edge: PopView.Edge) {
    let margin: CGFloat = 10
    let tray = 6 + StyleBar.height
    let x = max(bounds.minX + margin, min(selection.minX, bounds.maxX - margin - size.width))
      .rounded()
    func fits(_ y: CGFloat) -> Bool {
      y >= bounds.minY + margin && y + size.height <= bounds.maxY - margin
    }
    let barAbove = toolbar.map { $0.minY >= selection.maxY - 0.5 } ?? false
    let barBelow = toolbar.map { $0.maxY <= selection.minY + 0.5 } ?? false
    var candidates: [(y: CGFloat, edge: PopView.Edge)] =
      barAbove
      ? [(selection.minY - margin - size.height, .top)] : [(selection.maxY + margin, .bottom)]
    if let toolbar, barBelow { candidates.append((toolbar.minY - tray - 6 - size.height, .top)) }
    if let toolbar, barAbove { candidates.append((toolbar.maxY + tray + 6, .bottom)) }
    if !barAbove, !barBelow, toolbar == nil {
      candidates.append((selection.minY - margin - size.height, .top))
    }
    if let pick = candidates.first(where: { fits($0.y.rounded()) }) {
      return (CGPoint(x: x, y: pick.y.rounded()), pick.edge)
    }
    // 选区里左下角；压到栏（连托盘：栏在选区下面时托盘在栏下面，在上面 / 选区里时在栏上面）就挪到它上面；
    // 最后夹在屏内 10（贴着屏幕边的窄选区，卡片比选区宽，✕ 和拷贝不能跑到屏幕外）
    var inside = CGRect(
      origin: CGPoint(x: selection.minX + 8, y: selection.minY + 8), size: size)
    if let toolbar {
      let taken = CGRect(
        x: toolbar.minX, y: barBelow ? toolbar.minY - tray : toolbar.minY, width: toolbar.width,
        height: toolbar.height + tray)
      if inside.intersects(taken) { inside.origin.y = taken.maxY + 6 }
    }
    let clampedX = max(bounds.minX + margin, min(inside.minX, bounds.maxX - margin - size.width))
    let clampedY = max(bounds.minY + margin, min(inside.minY, bounds.maxY - margin - size.height))
    return (CGPoint(x: clampedX.rounded(), y: clampedY.rounded()), .bottom)
  }

  /// 选区变了：把就地翻译贴上去的译文撤掉，冻结帧换回原图（标注不动，马赛克读的那张一起换），说一声
  func restoreUntranslated() {
    guard let untranslated else { return }
    self.untranslated = nil
    translated = nil
    showingOriginal = false
    image = untranslated.image
    annotationCanvas?.image = untranslated.image
    needsDisplay = true
    flashHint([String(localized: "选区变了，已换回原文")])
  }

  /// 停掉就地翻译：Esc 收起截图、这块屏被清掉时都要调，不然还在排队的那几段会继续往翻译服务发请求。
  /// 任务的取消点在 TranslateSegments 的每段开头，取消后不会再发新请求
  func cancelTranslation() {
    translateTask?.cancel()
    translateTask = nil
    guard translating else { return }
    translating = false
    refresh()
  }

  /// 长截图：只交出选区位置，边滚边截的是实时画面（标注不带过去，长图是重截的、坐标对不上；
  /// 拍板 D1：照旧丢掉，但说一声拼完能在长图上标）；太矮的选区两帧之间没几行可比
  func startScroll() {
    endEditing()
    guard let selection, let window else { return }
    guard selection.height >= ScrollCapture.minimumHeight else {
      // 不写点数：尺寸胶囊显示的是像素，写「60 点」和看到的数字对不上（体检 B43）
      NSSound.beep()
      flashHint([String(localized: "选区太矮，拉高一点再长截图")])
      return announce(String(localized: "选区太矮，拉高一点再长截图"))
    }
    if hasAnnotations || session.hasAnnotations(besides: self) {
      flashHint([String(localized: "长截图不带这些标注，拼完可以在长图上标")])
      announce(String(localized: "长截图不带这些标注，拼完可以在长图上标"))
    }
    session.finish(.scroll(selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY)))
  }

  /// 录屏：交出选区（点，全局坐标，同长截图）。短边不到 64 pt 录出来看不清：提示音 + 顶部提示 + 播报，不开始
  /// （同长截图的 B43，不写点数）
  func startRecording() {
    guard let selection, let window else { return }
    guard min(selection.width, selection.height) >= ScreenRecorder.minimumSide else {
      NSSound.beep()
      flashHint([String(localized: "选区太小，拉大一点再录")])
      return announce(String(localized: "选区太小，拉大一点再录"))
    }
    session.finish(.record(selection.offsetBy(dx: window.frame.minX, dy: window.frame.minY)))
  }

  /// 截图调整时按 R / 点工具栏「录屏」（拍板 R2-a）：会话切成录屏，工具栏原地换成录制条、选区不变（尺寸胶囊、比例、手柄照旧），
  /// 之后 ↩ / 双击 / ● 开始。录屏不带标注：画了标注（含输入中的文字，不管在哪块屏）就不切，提示音 + 顶部提示 + 播报
  /// （同「有标注时右键不清空」）
  func switchToRecording() {
    guard !hasAnnotations, !session.hasAnnotations(besides: self) else {
      NSSound.beep()
      flashHint([String(localized: "录屏不带标注，先撤销或 Esc 退出")])
      return announce(String(localized: "录屏不带标注，先撤销或 Esc 退出"))
    }
    if let blocker = session.recordingBlocker() {
      NSSound.beep()
      flashHint([blocker.title, blocker.detail])
      return announce([blocker.title, blocker.detail].joined(separator: Island.comma))
    }
    finishSizeEditing(commit: true)
    session.mode = .record
    for view in session.views where view !== self { view.becomeRecorder() }
    becomeRecorder()
    announce(String(localized: "已切到录屏，↩ 开始录制"))
  }

  /// 会话切成录屏之后：收起 HUD 菜单、输入框和工具，工具栏、样式托盘换成录制条（从选区那条边长出来），顶部提示换成录屏的
  private func becomeRecorder() {
    hudMenu?.dismiss()
    closeTranslationCard()
    endEditing()
    tool = nil
    selectedAnnotation = nil
    toolbar?.removeFromSuperview()
    styleBar?.removeFromSuperview()
    toolbar = nil
    styleBar = nil
    pickingColor = false  // 托盘没了，吸管也不取了
    layOutMagnifier()  // 录屏没有色值卡
    hintParts = Self.hintParts(for: session)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hint.setParts(hintParts)
    CATransaction.commit()
    makeRecordBar()
    refresh()
    refreshCursor()
  }

  /// ↩、双击选区：截图拷贝，录屏开始录
  func confirm() {
    if mode == .record { startRecording() } else { output(.copy) }
  }

  /// 指针下这一点上能选的几层（从小到大，最后一层是那扇窗口，都夹在本屏内）和停在第几层
  struct HoverStack {
    /// 哪扇窗口（windows 的下标）
    let window: Int
    let layers: [ElementFinder.Layer]
    var index = 0
  }

  /// 本屏在 point 下悬停的那一块（夹在本屏内）：最前面的窗口；认元素时是那扇窗口里停着的那一层
  func hoverRect(at point: CGPoint) -> CGRect? {
    guard adjusts, let index = windows.firstIndex(where: { $0.contains(point) }) else {
      stack = nil  // 移到桌面上再回来：回到最小那层
      return nil
    }
    guard let stack = hoverStack(at: point, window: index) else {
      return windows[index].intersection(bounds)
    }
    return stack.layers[stack.index].frame
  }

  /// 悬停的那一层的种类名（旁白）：窗口那层、只认窗口时 nil
  var hoverName: String? {
    stack.flatMap { $0.layers[$0.index].name }
  }

  /// 指针下的几层。换到大的那层之后，指针还在那一层里就停在那层、不重问；否则每动一下都问（指针还在同一个元素上时
  /// ElementFinder 的缓存只做一次命中测试，约 0.1 ms），问出来的一串没变就留着原来的。移出去了回到最小那层。不认元素时 nil
  private func hoverStack(at point: CGPoint, window index: Int) -> HoverStack? {
    if let stack, stack.window == index, stack.index > 0,
      stack.layers[stack.index].frame.contains(point)
    {
      return stack
    }
    let fresh = findLayers(at: point, window: index)
    if let fresh, let stack, stack.window == index, stack.index == 0, stack.layers == fresh.layers {
      return stack
    }
    stack = fresh
    return stack
  }

  /// 问那扇窗口的主人 point 上的几层。设置关着 / 没授权（findsElements）、Tab 切成只认窗口、本 App 自己的窗口
  /// （主线程问自己要等到超时，拍板 B5）时 nil；问超时的 App 记下、这次不再问，只给窗口那一层
  private func findLayers(at point: CGPoint, window index: Int) -> HoverStack? {
    guard session.findsElements, !session.windowOnly, index < owners.count else { return nil }
    let pids = owners[index].filter { $0 != getpid() }
    guard !pids.isEmpty else { return nil }
    let window = windows[index].intersection(bounds)
    var layers: [ElementFinder.Layer] = []
    // 遮罩铺满整块屏：视图坐标 + 屏幕原点 = AppKit 全局坐标
    let origin = self.window?.frame.origin ?? .zero
    for pid in pids where layers.isEmpty && !session.silentApps.contains(pid) {
      switch session.findElements(pid, CGPoint(x: point.x + origin.x, y: point.y + origin.y)) {
      case .unresponsive:
        // 刚叫醒的 App 正在建网页那棵树，可能一时答得慢：这次只给窗口，不记成卡住
        if !session.spares(pid) { session.silentApps.insert(pid) }
      case .chain(let chain):
        let local = chain.map {
          ElementFinder.Layer(frame: $0.frame.offsetBy(dx: -origin.x, dy: -origin.y), name: $0.name)
        }
        layers = ElementFinder.layers(local, at: point, in: window)
      }
      // 刚叫醒、这次还只认到很粗的一块（最小那层占了窗口一半以上，或者只有窗口）：指针停着不动时到点再问一次
      let coarse =
        layers.first.map { $0.frame.width * $0.frame.height * 2 >= window.width * window.height }
        ?? true
      if coarse, let delay = session.recheckDelay(for: pid) { recheck(pid, after: delay) }
    }
    return HoverStack(
      window: index, layers: layers + [ElementFinder.Layer(frame: window, name: nil)])
  }

  /// 刚叫醒的 App（也认网页里的元素，ElementFinder.settles）过一会儿才交出网页里的元素：指针停着不动时到点再问一次——
  /// 这次框选还开着、指针还停在这个 App 的窗口上的最小那层、没在拖、没有选区，就丢掉它上次的结果重问（不然要动一下
  /// 鼠标才变细）。重问还粗的话，findLayers 会排下一个时刻
  private func recheck(_ pid: pid_t, after delay: Duration) {
    guard rechecking.insert(pid).inserted else { return }
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self else { return }
      rechecking.remove(pid)
      guard session.views.contains(where: { $0 === self }), adjusts, mouse != nil, selection == nil,
        drag == nil, let stack, stack.index == 0, owners[stack.window].contains(pid)
      else { return }
      session.forget(pid)
      self.stack = nil
      refresh()
    }
  }

  /// 滚轮 / 触控板双指：待选、悬停着元素时换层，往上（按手指 / 滚轮的方向，不跟着「自然滚动」反过来）大一层、往下小一层，
  /// 最大到那扇窗口；到头了不动。惯性那一段不算
  override func scrollWheel(with event: NSEvent) {
    if wheelRestyle(event) { return }
    guard selection == nil, drag == nil, event.momentumPhase.isEmpty, let mouse,
      hoverRect(at: mouse) != nil, var current = stack, current.layers.count > 1
    else { return super.scrollWheel(with: event) }
    if event.phase == .began { scrollPending = 0 }
    let (step, pending) = ElementFinder.step(
      deltaY: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice,
      precise: event.hasPreciseScrollingDeltas, pending: scrollPending)
    scrollPending = pending
    guard step != 0 else { return }
    // 换到大的那层之后指针挪过（没重问）：小的那几层是在原来那一点上问的，往小换之前按现在的位置重问，停回同一块。
    // 重问没问出元素（超时了）就还用原来那一串：不然想换小一层却一下跳到整扇窗口
    if step < 0, !current.layers[0].frame.contains(mouse),
      let fresh = findLayers(at: mouse, window: current.window), fresh.layers.count > 1
    {
      let shown = current.layers[current.index].frame
      current = fresh
      current.index = ElementFinder.position(of: shown, in: fresh.layers.map(\.frame))
    }
    let index = min(max(current.index + step, 0), current.layers.count - 1)
    current.index = index
    stack = current
    refresh()
    let layer = current.layers[index]
    announce("\(layer.name ?? String(localized: "窗口")) \(sizeText(layer.frame))")
  }

  /// Tab：在「认窗口里的元素 / 只认窗口」之间切（只管这一次框选，几块屏一起换），顶部提示跟着换一下
  func toggleWindowOnly() {
    session.windowOnly.toggle()
    for view in session.views.isEmpty ? [self] : session.views { view.elementModeChanged() }
    announce(
      session.windowOnly ? String(localized: "只认窗口") : String(localized: "认窗口里的元素"))
  }

  private func elementModeChanged() {
    stack = nil
    hintParts = Self.hintParts(for: session)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hint.setParts(hintParts)
    CATransaction.commit()
    refresh()
    if mouse != nil { showHint(for: 1.5) }
  }
}
