// 框选遮罩的画面（第五轮体检 H1 从 SelectionView.swift 拆出）：顶部提示、蒙层和选区边框、手柄、尺寸胶囊、标注的选中框、吸附参考线、十字准线、放大镜和取色。

import AppKit

extension SelectionView {
  // MARK: 画面

  /// 图层的像素密度跟着屏幕走，不然 Retina 上线条和文字是糊的
  func updateScale() {
    let scale = window?.backingScaleFactor ?? 2
    for layer in [
      shade, spotlightDim, outline, outlineOuter, edgeHighlight, crossLight, crossDark, highlight,
      guideLayer,
      annotationOutline, annotationHandles, loupeGrid, loupeBands, loupeCenter, infoText, infoKey,
    ] + Array(handleLayers.values) as [CALayer] {
      layer.contentsScale = scale
    }
    hint.scale = scale
    rebindTip.scale = scale
  }

  /// 出场：蒙层 0.15 s 淡入；提示浮上来，3 s 后淡出。同时挂上跟手的显示链（见 followPointer）
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return stopFollowing() }
    startFollowing()
    updateScale()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.15
    shade.add(fade, forKey: "enter")
    if showsHint { showHint(for: 3) }
  }

  /// 提示从下方 8 pt 浮上来（settle）+ fadeIn 淡入，seconds 秒后 fadeOut 淡出（再显示一次时旧的计时作废）。
  /// 减弱动态效果时 settle 退成 0.2 s easeInOut 只改透明度
  func showHint(for seconds: Double) {
    hintGeneration += 1
    let generation = hintGeneration
    hint.layer.removeAnimation(forKey: "leave")
    hint.layer.opacity = 1
    let reduced = Style.reduceMotion
    let fade =
      (reduced
        ? Style.Motion.settle.caAnimation(keyPath: "opacity", reduced: true) as? CABasicAnimation
        : nil) ?? CABasicAnimation(keyPath: "opacity")
    if !reduced {
      fade.duration = Style.fadeIn
      fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    }
    fade.fromValue = 0
    fade.toValue = 1
    var animations: [CAAnimation] = [fade]
    if !reduced,
      let rise = Style.Motion.settle.caAnimation(keyPath: "transform.translation.y", reduced: false)
        as? CABasicAnimation
    {
      rise.fromValue = -8
      rise.toValue = 0
      animations.append(rise)
    }
    let group = CAAnimationGroup()
    group.animations = animations
    group.duration = animations.map(\.duration).max() ?? Style.fadeIn
    hint.layer.add(group, forKey: "enter")
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, self.hintGeneration == generation else { return }
      self.dismissHint()
    }
  }

  /// 淡出后停在透明（不设 isHidden：下一次 refresh 会把淡出截断）
  private func dismissHint() {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = hint.layer.presentation()?.opacity ?? 1
    fade.toValue = 0
    fade.duration = Style.fadeOut
    fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
    hint.layer.opacity = 0
    hint.layer.add(fade, forKey: "leave")
  }

  /// 顶部提示临时换一句（右键不清空）：有选区时也显示，1.5 s 后淡出
  func flashHint(_ parts: [String]) {
    // 换字时胶囊的宽、圆角、阴影不做隐式动画（它挂在 layer-hosting 的图层树上，默认会补 0.25 s）
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hint.setParts(parts)
    CATransaction.commit()
    hintFlashing = true
    refresh()
    showHint(for: 1.5)
  }

  /// 按状态摆好全部图层（关掉隐式动画，拖动时跟手；只有换悬停窗口、单击选中窗口、蒙层深浅切换、手柄出现 / 悬停放大、
  /// 放大镜出现 / 翻边、两条栏长出 / 淡出时才加动画）
  /// 鼠标动一下：只碰跟着它走的那几样。别的（选区描边、工具栏、参考线、标注的选中框）都由改它们的地方自己刷
  func refreshPointer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    // 悬停窗口只有待选时有；占位跟着光标走的规矩同 refresh
    let hovered = selection == nil ? mouse.flatMap(hoverRect(at:)) : nil
    if let mouse, hovered != nil || shownHover != nil || shade.animation(forKey: "morph") != nil {
      placeholder = mouse
    }
    if selection == nil || hovered != shownHover {
      updateHole(hovered: hovered, shown: selection.map(pixelAligned))
      updateSizeField(for: selection ?? hovered)
    }
    // 调整时手柄有悬停态（指着的那条边加粗、手柄放大）
    if adjusts && isAdjusting { updateHandles(selection.map(pixelAligned)) }
    updateMagnifier()
    updateCrosshair()
  }

  func refresh() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let hovered = selection == nil ? mouse.flatMap(hoverRect(at:)) : nil
    // 零尺寸的占位看不见，只在要用它时跟着光标：悬停着窗口（离开时从这里变形）、刚离开窗口或正在变形回桌面（终点追着光标）。
    // 桌面上闲晃（截图翻译 / 识字时一直是）不动它：整屏蒙层的路径没变就不重设
    if let mouse, hovered != nil || shownHover != nil || shade.animation(forKey: "morph") != nil {
      placeholder = mouse
    }
    let shown = selection.map(pixelAligned)
    updateHole(hovered: hovered, shown: shown)
    // 选区双描边：内 1.5 pt 粉 + 外 1 pt black 0.28（亮底暗底都看得清）。贴着屏幕边的边（整屏、吸到屏幕边）画在边里面：
    // 画在外面整条都落到屏幕外（见 insideScreen）。单击选中的整扇窗口按它的圆角画（同心，selectionRadius）
    let radius = selectionRadius
    outline.path = shown.map {
      Self.framePath(
        insideScreen($0.insetBy(dx: -0.75, dy: -0.75), by: 0.75), radius: radius, grow: 0.75)
    }
    outlineOuter.path = shown.map {
      Self.framePath(insideScreen($0.insetBy(dx: -2, dy: -2), by: 2), radius: radius, grow: 2)
    }
    translatingPulse.cornerRadius = radius
    // 就地翻译中：选区上一条浅白渐变从左扫到右（1.1 秒一轮），衬着浅色底也看得出来；
    // 减弱动态效果时不扫，光带停在选区外，只留压暗那一层
    translatingPulse.frame = shown ?? .zero
    translatingPulse.isHidden = !translating || shown == nil
    if translating, let shown, !Style.reduceMotion {
      let band = max(60, shown.width * 0.5)
      let distance = shown.width + band
      translatingBand.frame = CGRect(x: -band, y: 0, width: band, height: shown.height)
      // 翻译期间还能拖选区边：宽度一变，扫动的距离跟着变，不然拉宽之后右边那段永远扫不到
      if abs(translatingSweep - distance) > 0.5 {
        translatingBand.removeAnimation(forKey: "sweep")
        translatingSweep = distance
      }
      if translatingBand.animation(forKey: "sweep") == nil {
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0
        sweep.toValue = distance
        sweep.duration = 1.1
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        translatingBand.add(sweep, forKey: "sweep")
      }
    } else {
      translatingBand.removeAnimation(forKey: "sweep")
      translatingSweep = 0
    }
    hint.layer.isHidden = selection != nil && !hintFlashing
    if !hint.layer.isHidden {
      // 遮罩铺满整块屏（bounds 就是屏幕）；单测、截图自检的窗口不在屏上，只按 bounds
      hint.maxWidth = Self.hintWidthLimit(
        screen: bounds.width, visible: window?.screen?.visibleFrame.width)
      hint.place(
        at: CGPoint(x: bounds.midX - hint.size.width / 2, y: bounds.maxY - 64 - hint.size.height))
    }
    updateGuides()

    let adjusting = adjusts && isAdjusting
    updateHandles(adjusting ? shown : nil)
    updateAnnotationChrome()
    placeBars(showing: adjusting && !movesSelection)
    updateSizeField(for: selection ?? hovered)
    updateMagnifier()
    updateCrosshair()
  }

  /// 尺寸：选区（或悬停的窗口）旁边，见 sizeFieldOrigin；哪儿都放不下时放进里面、只读（不挡拖边和平移）。调整时可输入
  private func updateSizeField(for measured: CGRect?) {
    sizeField.isHidden = measured == nil
    guard let measured else { return }
    let adjusting = adjusts && isAdjusting
    let pixels = pixelSize(of: measured)
    let show = { (interactive: Bool) in
      self.sizeField.show(
        width: pixels.width, height: pixels.height, interactive: interactive,
        ratio: RegionSelector.ratioTitle(self.session.lockedRatio),
        locked: self.session.lockedRatio != nil)
    }
    show(adjusting)
    var origin = sizeFieldOrigin(for: measured, size: sizeField.frame.size)
    if origin == nil {
      show(false)
      let size = sizeField.frame.size
      origin = CGPoint(
        x: max(bounds.minX, min(measured.minX + 8, bounds.maxX - size.width)).rounded(),
        y: (measured.maxY - 8 - size.height).rounded())
    }
    if let origin, sizeField.frame.origin != origin { sizeField.setFrameOrigin(origin) }
  }

  /// 尺寸胶囊放哪（左下角，取整到整点：选区给的是小数点，文字落在半像素上会糊）：先放选区外面——左上角外 8 pt →
  /// 选区右侧、左侧外 8 pt（和上边对齐；比胶囊矮的选区竖直居中，免得碰到上下的栏）→ 左下角外 8 pt；外面都放不下才进选区，
  /// 离左边、上边各 8 pt（选区四周都留得出 8 pt 才放：不盖角手柄和能拖的边）。2026-11-09 用户：上面被译文栏占着时它进了
  /// 选区、挡住要截的字（原来选区里排在左右两侧前面）。出屏、挡到栏或顶部提示的不要；都不行时 nil
  private func sizeFieldOrigin(for measured: CGRect, size: CGSize) -> CGPoint? {
    let left = max(bounds.minX, min(measured.minX, bounds.maxX - size.width))
    let side = min(measured.maxY - size.height, measured.midY - size.height / 2)
    var candidates = [
      CGPoint(x: left, y: measured.maxY + 8),
      CGPoint(x: measured.maxX + 8, y: side), CGPoint(x: measured.minX - 8 - size.width, y: side),
      CGPoint(x: left, y: measured.minY - 8 - size.height),
    ]
    if measured.width >= size.width + 16, measured.height >= size.height + 16 {
      candidates.append(CGPoint(x: measured.minX + 8, y: measured.maxY - 8 - size.height))
    }
    let hintShowing = hintShowing
    return candidates.lazy.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }.first {
      let frame = CGRect(origin: $0, size: size)
      return bounds.contains(frame) && !self.isOverBars(frame)
        && !(hintShowing && self.hint.frame.intersects(frame))
    }
  }

  /// S5 窗口磁吸：洞（蒙层里的圆角矩形）和粉色高亮框。路径元素数恒定（外框 + 一个圆角矩形，没悬停窗口时是光标处的
  /// 零尺寸占位），窗口之间、桌面 ↔ 窗口、窗口的圆角量出来时用 glide 从当前（可能还在动的）形状变形过去；圆角按出图的
  /// 形状（cornerRadius(of:)），单击选中时不变，pop 只补上按像素取整的那一点（和还没变形完的那一截）；拖动、微调一律跟手。
  /// shown 是按像素取整后的选区（见 pixelAligned）
  private func updateHole(hovered: CGRect?, shown: CGRect?) {
    let spot = CGRect(origin: placeholder, size: .zero)
    let hole = shown ?? hovered ?? spot
    let hoverRadius = hovered.map(cornerRadius(of:)) ?? 0
    let path = CGMutablePath()
    path.addRect(bounds)
    path.addPath(Self.roundedPath(hole, radius: shown == nil ? hoverRadius : selectionRadius))
    let frame: CGPath? =
      selection == nil
      ? Self.roundedPath(hovered?.insetBy(dx: 1, dy: 1) ?? spot, radius: hoverRadius - 1)
      : nil
    var oldShade = shade.presentation()?.path ?? shade.path
    var oldHighlight = highlight.presentation()?.path ?? highlight.path
    var morph: CABasicAnimation?
    if selection == nil {
      // 同一状态下占位跟着光标走，只改模型值：正在跑的变形会追着新终点
      let reshaped = hovered != shownHover || (hovered != nil && shade.path != path)
      if reshaped, shade.path != nil, !holeIsSelection {
        morph = Style.Motion.glide.caAnimation(keyPath: "path") as? CABasicAnimation
      }
    } else if !holeIsSelection, shownHover != nil, selection == shownHover, !Style.reduceMotion {
      morph = Style.Motion.pop.caAnimation(keyPath: "path", reduced: false) as? CABasicAnimation
    } else if shade.path != path {
      shade.removeAnimation(forKey: "morph")
    }
    // 没变就不设：整屏的蒙层重新光栅化一次不便宜（调整时鼠标每动一下都会走到这里）
    if shade.path != path { shade.path = path }
    if highlight.path != frame { highlight.path = frame }
    if let morph {
      // 从桌面占位出发（没在变形）时从光标现在的位置长出来：图层里的占位可能还停在进场前的 (0, 0)
      // 或上次移出本屏的地方，直接用会从屏幕角落飞过来
      if shownHover == nil, shade.animation(forKey: "morph") == nil {
        let start = CGMutablePath()
        start.addRect(bounds)
        start.addPath(Self.roundedPath(spot, radius: Style.Radius.card))
        oldShade = start
        oldHighlight = Self.roundedPath(spot, radius: Style.Radius.card - 1)
      }
      morph.fromValue = oldShade
      shade.add(morph, forKey: "morph")
      if frame != nil, let copy = morph.copy() as? CABasicAnimation {
        copy.fromValue = oldHighlight
        highlight.add(copy, forKey: "morph")
      }
    }
    if frame == nil { highlight.removeAnimation(forKey: "morph") }
    shownHover = hovered
    holeIsSelection = selection != nil
    // 待选时整屏轻暗 0.18；有选区（或悬停的窗口）时洞外 0.45，切换时过渡 0.12 s（保持原色时都不压）
    let hasHole = selection != nil || hovered != nil
    let fill = NSColor.black.withAlphaComponent(
      Self.shadeAlpha(hasHole: hasHole, keepsColors: keepsColors)
    ).cgColor
    if hasHole != hadHole {
      let fade = CABasicAnimation(keyPath: "fillColor")
      fade.fromValue = shade.presentation()?.fillColor ?? shade.fillColor
      fade.toValue = fill
      fade.duration = 0.12
      shade.add(fade, forKey: "fill")
    }
    shade.fillColor = fill
    hadHole = hasHole
  }

  /// 手柄：角 10 pt 白圆 + 1.5 pt 粉环，边中点 16 × 5 白胶囊 + 粉环（短边 < 40 不画边中点）；进入调整时从左上角顺时针
  /// 依次弹出（错开 15 ms）；悬停 / 正在拖的边加 2.5 pt 粉线、对应手柄放大 1.3（pop）
  private func updateHandles(_ rect: CGRect?) {
    let appearing = rect != nil && !handlesShown
    handlesShown = rect != nil
    let reduced = Style.reduceMotion
    // 圆角的选区（单击选中的整扇窗口）：角上的手柄落在圆弧正中，不悬在角外的空处
    let radius = rect == nil ? 0 : selectionRadius
    let cornerInset = radius * (1 - 1 / 2.squareRoot())
    for (index, handle) in Self.handleOrder.enumerated() {
      guard let layer = handleLayers[handle] else { continue }
      guard let rect else {
        layer.isHidden = true
        continue
      }
      let isEdge = [.top, .bottom, .left, .right].contains(handle)
      layer.isHidden = isEdge && min(rect.width, rect.height) < 40
      // 对齐到屏幕像素（边中点落在半像素上时胶囊发糊）；贴着屏幕边的往里挪到整个露出来（半个手柄 + 描边）
      let shape = layer.path?.boundingBox.size ?? .zero
      let halfWidth: CGFloat = shape.width / 2 + 1
      let halfHeight: CGFloat = shape.height / 2 + 1
      var point = handle.point(in: rect)
      if !isEdge {
        point.x += handle.movesMinX ? cornerInset : -cornerInset
        point.y += handle.movesMinY ? cornerInset : -cornerInset
      }
      point.x = min(max(point.x, bounds.minX + halfWidth), bounds.maxX - halfWidth)
      point.y = min(max(point.y, bounds.minY + halfHeight), bounds.maxY - halfHeight)
      let pixel = window?.backingScaleFactor ?? 2
      layer.position = CGPoint(
        x: (point.x * pixel).rounded() / pixel, y: (point.y * pixel).rounded() / pixel)
      guard appearing else { continue }
      if reduced,
        let fade = Style.Motion.pop.caAnimation(keyPath: "opacity", reduced: true)
          as? CABasicAnimation
      {
        fade.fromValue = 0
        fade.toValue = 1
        layer.add(fade, forKey: "appear")
      } else if let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
        as? CABasicAnimation
      {
        pop.fromValue = 0
        pop.beginTime = CACurrentMediaTime() + Double(index) * 0.015
        pop.fillMode = .backwards
        layer.add(pop, forKey: "appear")
      }
    }
    let hot = rect.flatMap(hotHandle(in:))
    if hot != hotHandle {
      for (handle, scale) in [(hotHandle, 1), (hot, 1.3)] as [(RegionSelector.Handle?, CGFloat)] {
        guard let handle, let layer = handleLayers[handle] else { continue }
        let from = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        guard !reduced,
          let pop = Style.Motion.pop.caAnimation(keyPath: "transform.scale", reduced: false)
            as? CABasicAnimation
        else { continue }
        pop.fromValue = from
        layer.add(pop, forKey: "hot")
      }
      hotHandle = hot
    }
    if let hot, let rect {
      let edge = insideScreen(rect.insetBy(dx: -0.75, dy: -0.75), by: 1.25)
      edgeHighlight.path = Self.edgePath(hot, of: edge, radius: radius > 0 ? radius + 0.75 : 0)
    } else {
      edgeHighlight.path = nil
    }
  }

  /// 悬停（或正在拖）的边 / 角：拖手柄时是在动的那侧（拖过对边就换到另一侧）；其余拖动、输入文字 / 尺寸、开着菜单、
  /// 鼠标在栏上或选中标注的手柄上时没有
  private func hotHandle(in rect: CGRect) -> RegionSelector.Handle? {
    if case .resize(let handle, _)? = drag {
      return (dragPoint ?? mouse).map { handle.facing($0, in: rect) } ?? handle
    }
    guard drag == nil, editor == nil, !sizeField.isEditing, hudMenu == nil, let mouse,
      !isOverControls(mouse), annotationHandle(at: mouse) == nil
    else { return nil }
    return Self.handle(at: mouse, in: rect)
  }

  /// 选中的标注：1 pt 粉色虚线框 [4, 3]（箭头、直线、荧光笔不画）+ 手柄（白 9 pt 圆 + 1.5 pt 粉环；矩形类四角和边中点、线类两端，
  /// 箭头、直线的弧线中点是小一号的 7 pt 弯曲手柄；序号是外切正方形的四角；文字、画笔没有）。输入文字时不画（输入框自己有边框，大小跟着输入变）
  private func updateAnnotationChrome() {
    guard editor == nil, let selected else {
      annotationOutline.path = nil
      annotationHandles.path = nil
      return
    }
    let isSegment = [.arrow, .line, .highlighter].contains(selected.tool)
    // 取整到整点：1 pt 虚线落在半像素上会糊
    let frame = selected.bounds.insetBy(dx: -3, dy: -3).integral
    annotationOutline.path = isSegment ? nil : CGPath(rect: frame, transform: nil)
    let dots = CGMutablePath()
    for (handle, point) in selected.handles {
      let radius: CGFloat = handle == .bend ? 3.5 : 4.5
      dots.addEllipse(
        in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
    annotationHandles.path = dots.isEmpty ? nil : dots
  }

  /// 吸附参考线：吸上的边各一条 1 pt 粉色虚线横穿整屏
  private func updateGuides() {
    let path = CGMutablePath()
    if let x = guides.x {
      path.move(to: CGPoint(x: x, y: bounds.minY))
      path.addLine(to: CGPoint(x: x, y: bounds.maxY))
    }
    if let y = guides.y {
      path.move(to: CGPoint(x: bounds.minX, y: y))
      path.addLine(to: CGPoint(x: bounds.maxX, y: y))
    }
    guideLayer.path = path.isEmpty ? nil : path
  }

  /// 正在拖动 / 缩放 / 平移选区：两条栏只在这时让位淡出（画标注、拖标注时不动）。按在选区里 / 边上还没拖开不算，
  /// 不然单击一下（取消选中标注）栏就闪一下
  private var movesSelection: Bool {
    switch drag {
    case .move(_, let original)?, .resize(_, let original)?: selection != original
    case .draw?: true
    default: false
    }
  }

  /// 十字准线跟放大镜同时出现（待选、拖动框选、拖手柄），只在按住 ⌘ 时；对齐到整点，白线盖住光标所在的那一点
  private func updateCrosshair() {
    guard let mouse, modifiers.contains(.command), magnifierMoment else {
      crossLight.path = nil
      crossDark.path = nil
      return
    }
    let x = mouse.x.rounded(.down)
    let y = mouse.y.rounded(.down)
    for (layer, dx, dy) in [(crossLight, 0.5, 0.5), (crossDark, 1.5, -0.5)]
      as [(CAShapeLayer, CGFloat, CGFloat)]
    {
      let path = CGMutablePath()
      path.move(to: CGPoint(x: x + dx, y: bounds.minY))
      path.addLine(to: CGPoint(x: x + dx, y: bounds.maxY))
      path.move(to: CGPoint(x: bounds.minX, y: y + dy))
      path.addLine(to: CGPoint(x: bounds.maxX, y: y + dy))
      layer.path = path
    }
  }

  /// 点中哪条边 / 哪个角：边外 8 pt、边内也是 8 pt；选区很小时边内按比例缩（不然整块都是边，没法拖着平移）
  static func handle(at point: CGPoint, in selection: CGRect) -> RegionSelector.Handle? {
    RegionSelector.handle(
      at: point, in: selection, tolerance: 8,
      inner: min(8, max(3, min(selection.width, selection.height) / 4)))
  }

  /// 描边中线 rect 夹进屏内 inset（线宽的一半）：贴着屏幕边的那几条边整条画在屏里，其余不动
  private func insideScreen(_ rect: CGRect, by inset: CGFloat) -> CGRect {
    rect.intersection(bounds.insetBy(dx: inset, dy: inset))
  }

  /// 这一块按多大的圆角画（点；洞、悬停的粉框、选区边框同一个）：框的形状就是出图的形状（截出来的图按 selectionRadius
  /// 裁圆角，output）。出图会换成透明圆角那张（N1）的整扇窗口按它真实的圆角（windowRadius），别的按设置 › 截图「截图圆角」
  /// （shotRadius，默认和系统窗口一样：15 上 10、26 起 16）；录屏录的是矩形，一律直角。2026-11-20 用户：悬停是圆角、单击选中后变直角，要圆角、图也要圆角、
  /// 设置里能调（原来悬停一律圆角 10、选中时 10 → 0、出图是矩形）
  func cornerRadius(of rect: CGRect) -> CGFloat {
    mode == .record ? 0 : windowRadius(of: rect) ?? shotRadius
  }

  /// 选区的圆角：单击选中的整扇窗口、选区没再动过、没贴就地翻译的译文（同 windowShot 的前几条）按窗口的；
  /// 拖出来的、拖边 / 挪动 / 微调过的按「截图圆角」；录屏直角
  var selectionRadius: CGFloat {
    guard let selection, mode != .record else { return 0 }
    if clickedWindow?.frame == selection, untranslated == nil,
      let radius = windowRadius(of: selection)
    {
      return radius
    }
    return shotRadius
  }

  /// 设置 › 截图「截图圆角」（点，0 = 直角）
  var shotRadius: CGFloat {
    let radius = styleDefaults.double(forKey: Prefs.screenshotCornerRadius)
    return CGFloat(min(max(radius, 0), Prefs.screenshotCornerRadii.upperBound))
  }

  /// 整扇窗口自己的圆角（截图模式、开着「窗口截图带阴影」、整个在这块屏里、有窗口号：出图换成单独截的那张时）；别的 nil
  private func windowRadius(of rect: CGRect) -> CGFloat? {
    guard mode == .capture, styleDefaults.bool(forKey: Prefs.screenshotWindowShadow),
      let index = windows.firstIndex(of: rect), windowIDs.indices.contains(index),
      let id = windowIDs[index]
    else { return nil }
    return session.windowRadius(id)
  }

  /// 选区边框：直角时照旧是矩形（描边的角是尖的）；圆角时按 radius + grow 画（边框在选区外 grow 点，和洞同心）
  static func framePath(_ rect: CGRect, radius: CGFloat, grow: CGFloat) -> CGPath {
    radius > 0 ? roundedPath(rect, radius: radius + grow) : CGPath(rect: rect, transform: nil)
  }

  /// 圆角矩形，元素恒为 move + 4 ×（line + curve）+ close：半径 0、零尺寸时也一样，洞和高亮框才能在窗口、
  /// 桌面占位、选区之间做路径插值（S5）。半径夹在短边一半以内
  static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = max(0, min(radius, rect.width / 2, rect.height / 2))
    let k = r * 0.4477  // 四分之一圆的三次贝塞尔：控制点离角 r × (1 − 0.5523)
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addLine(to: CGPoint(x: maxX - r, y: minY))
    path.addCurve(
      to: CGPoint(x: maxX, y: minY + r), control1: CGPoint(x: maxX - k, y: minY),
      control2: CGPoint(x: maxX, y: minY + k))
    path.addLine(to: CGPoint(x: maxX, y: maxY - r))
    path.addCurve(
      to: CGPoint(x: maxX - r, y: maxY), control1: CGPoint(x: maxX, y: maxY - k),
      control2: CGPoint(x: maxX - k, y: maxY))
    path.addLine(to: CGPoint(x: minX + r, y: maxY))
    path.addCurve(
      to: CGPoint(x: minX, y: maxY - r), control1: CGPoint(x: minX + k, y: maxY),
      control2: CGPoint(x: minX, y: maxY - k))
    path.addLine(to: CGPoint(x: minX, y: minY + r))
    path.addCurve(
      to: CGPoint(x: minX + r, y: minY), control1: CGPoint(x: minX, y: minY + k),
      control2: CGPoint(x: minX + k, y: minY))
    path.closeSubpath()
    return path
  }

  private func updateMagnifier() {
    guard let mouse, showsMagnifier else {
      magnifier.isHidden = true
      magnifierSide = nil
      return
    }
    let scaleX = CGFloat(image.width) / max(bounds.width, 1)
    let scaleY = CGFloat(image.height) / max(bounds.height, 1)
    let x = min(max(Int(mouse.x * scaleX), 0), image.width - 1)
    let y = min(max(Int((bounds.height - mouse.y) * scaleY), 0), image.height - 1)
    if sampled?.x != x || sampled?.y != y,
      let sample = Self.sample(image, x: x, y: y, size: Self.loupePixels)
    {
      loupe.contents = sample.image
      sampled = (x, y, sample.hex)
      let color = Self.color(hex: sample.hex)
      infoSwatch.backgroundColor = color.cgColor
      // 中心格描边按亮度选黑或白
      let luminance =
        0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
      loupeCenter.strokeColor = (luminance > 0.6 ? NSColor.black : NSColor.white).cgColor
      // 翻译 / 识字、设置里不显示色值时没有那张信息卡
      if showsColorCard { writeInfo((x, y, sample.hex)) }
    }
    placeMagnifier()
  }

  /// 信息卡上的 HEX 和坐标
  func writeInfo(_ sample: (x: Int, y: Int, hex: String)) {
    let info = NSMutableAttributedString(
      string: sample.hex,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: Style.HUD.text,
      ])
    info.append(
      NSAttributedString(
        string: "\n\(sample.x), \(sample.y)",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
          .foregroundColor: Style.HUD.secondaryText,
        ]))
    infoText.string = info
  }

  /// 放在光标右下，靠边时翻到另一侧；平时死贴光标，只有翻边那一下滑过去（glide）
  private func placeMagnifier() {
    guard let mouse else { return }
    let size = magnifier.bounds.size
    let left = mouse.x + 20 + size.width > bounds.maxX
    let above = mouse.y - 20 - size.height < bounds.minY
    // 对齐到屏幕像素：光标是小数点时整块放大镜（网格、色值文字）落在半像素上会糊
    let pixel = window?.backingScaleFactor ?? 2
    let origin = CGPoint(
      x: ((left ? mouse.x - 20 - size.width : mouse.x + 20) * pixel).rounded() / pixel,
      y: ((above ? mouse.y + 20 : mouse.y - 20 - size.height) * pixel).rounded() / pixel)
    let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    let appearing = magnifier.isHidden
    let flipped = magnifierSide.map { $0.left != left || $0.above != above } ?? false
    let previous = magnifier.presentation()?.position ?? magnifier.position
    magnifier.position = center
    magnifier.isHidden = false
    magnifierSide = (left, above)
    // 减弱动态效果时退成的基本动画只许改透明度
    let reduced = Style.reduceMotion
    if appearing,
      let pop = Style.Motion.pop.caAnimation(
        keyPath: reduced ? "opacity" : "transform.scale", reduced: reduced) as? CABasicAnimation
    {
      pop.fromValue = reduced ? 0 : 0.7
      pop.toValue = 1
      magnifier.add(pop, forKey: "pop")
    } else if flipped,
      let slide = Style.Motion.glide.caAnimation(keyPath: "position") as? CABasicAnimation
    {
      // 叠加动画：位移差从 previous − center 回到 0，期间光标继续动也不拖尾
      slide.isAdditive = true
      slide.fromValue = NSValue(point: CGPoint(x: previous.x - center.x, y: previous.y - center.y))
      slide.toValue = NSValue(point: .zero)
      magnifier.add(slide, forKey: "flip")
    }
  }

  /// "#RRGGBB" → sRGB 颜色
  private static func color(hex: String) -> NSColor {
    let value = Int(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(
      srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  /// 待选、拖动框选、拖手柄时显示放大镜（截图翻译 / 识字也是）；平移、标注、鼠标在工具栏上时不显示；设置里选了
  /// 「不显示」时只有吸管取色时显示。交互测试读它
  var showsMagnifier: Bool { magnifierMoment && (loupeStyle != .off || pickingColor) }

  /// 这一刻该不该有放大镜（不看设置）：按住 ⌘ 的十字准线跟它走，放大镜关了照样有
  private var magnifierMoment: Bool {
    guard let mouse, !isOverBars(mouse) else { return false }
    switch drag {
    case .move?, .annotate?, .moveAnnotation?, .resizeAnnotation?: return false
    case .pending?, .draw?, .resize?: return true
    case nil: return !isAdjusting || pickingColor
    }
  }

  /// 以原点为中心的手柄形状：角 10 pt 圆，边中点 16 × 5 胶囊（左右边竖着）
  static func handleShape(_ handle: RegionSelector.Handle) -> CGPath {
    switch handle {
    case .bottomLeft, .bottomRight, .topRight, .topLeft:
      CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
    case .top, .bottom:
      CGPath(
        roundedRect: CGRect(x: -8, y: -2.5, width: 16, height: 5), cornerWidth: 2.5,
        cornerHeight: 2.5, transform: nil)
    case .left, .right:
      CGPath(
        roundedRect: CGRect(x: -2.5, y: -8, width: 5, height: 16), cornerWidth: 2.5,
        cornerHeight: 2.5, transform: nil)
    }
  }

  /// 手柄依次弹出的顺序：从左上角顺时针
  static let handleOrder: [RegionSelector.Handle] = [
    .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left,
  ]

  /// 悬停的边（角 = 两条边），edge 是内描边的中线（贴着屏幕边时已挪进来）
  private static func edgePath(_ handle: RegionSelector.Handle, of edge: CGRect, radius: CGFloat)
    -> CGPath
  {
    // 圆角的选区：边的两头让出圆角，角上再接那一段圆弧（画法同 roundedPath）
    let r = max(0, min(radius, edge.width / 2, edge.height / 2))
    let path = CGMutablePath()
    let vertical = handle.movesMinX || handle.movesMaxX
    let horizontal = handle.movesMinY || handle.movesMaxY
    let x = handle.movesMinX ? edge.minX : edge.maxX
    let y = handle.movesMinY ? edge.minY : edge.maxY
    if vertical {
      path.move(to: CGPoint(x: x, y: edge.minY + r))
      path.addLine(to: CGPoint(x: x, y: edge.maxY - r))
    }
    if horizontal {
      path.move(to: CGPoint(x: edge.minX + r, y: y))
      path.addLine(to: CGPoint(x: edge.maxX - r, y: y))
    }
    if r > 0, vertical, horizontal {
      let dx: CGFloat = handle.movesMinX ? 1 : -1
      let dy: CGFloat = handle.movesMinY ? 1 : -1
      let k = r * 0.4477
      path.move(to: CGPoint(x: x, y: y + dy * r))
      path.addCurve(
        to: CGPoint(x: x + dx * r, y: y), control1: CGPoint(x: x, y: y + dy * k),
        control2: CGPoint(x: x + dx * k, y: y))
    }
    return path
  }

  /// 以像素 (x, y)（原点左上）为中心取 size×size 像素，转成 sRGB（放大镜显示用），中心像素的色值写成 #RRGGBB。
  /// 超出图的部分是黑色。纯函数，配单测
  static func sample(_ image: CGImage, x: Int, y: Int, size: Int) -> (image: CGImage, hex: String)?
  {
    let half = size / 2
    let region = CGRect(x: x - half, y: y - half, width: size, height: size)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let visible = region.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    if !visible.isNull, let crop = image.cropping(to: visible) {
      // 上下文原点在左下，图的行从上往下：按 y 翻转放到对应位置
      context.draw(
        crop,
        in: CGRect(
          x: visible.minX - region.minX, y: region.maxY - visible.maxY, width: visible.width,
          height: visible.height))
    }
    guard let data = context.data, let zoomed = context.makeImage() else { return nil }
    // 内存里第 0 行是图的顶行
    let pixel = data.assumingMemoryBound(to: UInt8.self) + half * size * 4 + half * 4
    return (zoomed, String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2]))
  }
}
