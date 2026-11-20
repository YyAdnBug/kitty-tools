// 框选遮罩的鼠标（第五轮体检 H1 从 SelectionView.swift 拆出）：悬停、拖框、拖边、吸附、画标注、右键、光标形状，和每帧补读光标位置的跟手。

import AppKit

extension SelectionView {
  // MARK: 鼠标

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    // 本 App 从不激活：.activeAlways 才收得到移动事件（.cursorUpdate 不支持 .activeAlways，光标只能手动设）
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
        owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    // 别的屏上有选区时这块屏不悬停、不出放大镜（单击不会抢走那边的选区，拖动才开新选区）；
    // 否则鼠标到哪块屏，哪块屏收按键（C 复制的是眼前放大镜的色值、Esc 取消）。不激活本 App
    if session.hasSelection(besides: self) {
      mouse = nil
    } else {
      if window?.isKeyWindow == false { window?.makeKey() }
      modifiers = event.modifierFlags
      mouse = point(event)
    }
    if adjusts { refreshCursor() } else { NSCursor.crosshair.set() }
  }

  override func mouseExited(with event: NSEvent) {
    mouse = nil
  }

  override func mouseDown(with event: NSEvent) {
    // 等着新的快捷键时点了一下：不改了（刚改完的那句提示也收掉）
    if rebinding != nil || !rebindTip.layer.isHidden { stopRebind() }
    let point = point(event)
    modifiers = event.modifierFlags
    isSpaceDown = false  // 按下前就按着的空格不算平移（见 isSpaceDown）
    guard adjusts else {
      window?.makeKey()  // 按键跟着最后操作的那块屏幕走
      session.activate(self)
      mouse = point
      selection = nil
      drag = .draw(anchor: point, last: point)
      return
    }
    // 单击选中后紧跟的第二下（双击）：直接拷贝 / 开始录（见 clickSelected）
    let armed = clickSelected
    clickSelected = nil
    let pressedBend = bendPressed
    bendPressed = nil
    if let armed, event.clickCount == 2, event.timestamp - armed.time < NSEvent.doubleClickInterval,
      isAdjusting, tool == nil, selection?.contains(point) == true
    {
      return confirm()
    }
    // 开着 HUD 菜单时点外面：只收菜单；输入着尺寸时点别处：按输入的改选区，这一下不做别的
    if let hudMenu { return hudMenu.dismiss() }
    if sizeField.isEditing { return finishSizeEditing(commit: true) }
    // 取色：菜单、尺寸输入先收（上面两行），再取
    if pickingColor, !isOverControls(point) { return pickColor() }
    // 别的屏上有选区：先记下按下的点，拖开了才算在这块屏开始（见 mouseDragged）
    if !session.hasSelection(besides: self) {
      window?.makeKey()
      session.activate(self)
      mouse = point
    }
    // 两条栏的按钮间隙、边距、分隔线不接事件，会顺着响应链落到这里：当作点在栏上，什么也不做
    if isOverBars(point) { return }
    // 在输入文字时点了输入框外面：先把文字收下，这一下不做别的
    if editor != nil { return endEditing() }
    if isAdjusting, let selection {
      // 双击箭头 / 直线的弯曲手柄：拉直（记一步撤销，本来就直的不记）。第一下也得按在它上面（见 bendPressed）
      let grip = annotationHandle(at: point)
      if event.clickCount == 2, let grip, grip.handle == .bend, grip.annotation.id == pressedBend {
        let straight = grip.annotation.straightened
        return commit(annotations.map { $0.id == straight.id ? straight : $0 })
      }
      let hit = annotation(at: point)
      if event.clickCount == 2, let hit, case .text(_, let origin) = hit.shape {
        return beginEditing(at: origin, existing: hit)
      }
      if event.clickCount == 2, tool == nil, hit == nil, selection.contains(point) {
        return confirm()
      }
      // 优先级：选中标注的手柄 → 选区边 → 标注本体 → 工具作画 / 平移选区 → 选区外
      if let grip {
        if grip.handle == .bend { bendPressed = grip.annotation.id }
        // 线类两端、弯曲手柄记住按下时离手柄多远（直箭头的弯曲手柄压在杆上，按偏几点一拖就弯出几点）；矩形类的角照旧对到光标上
        let segment = [Annotation.Handle.start, .end, .bend].contains(grip.handle)
        drag = .resizeAnnotation(
          grip.annotation, grip.handle, before: annotations,
          offset: segment
            ? CGVector(dx: grip.point.x - point.x, dy: grip.point.y - point.y) : .zero)
        return
      }
      if let handle = Self.handle(at: point, in: selection) {
        drag = .resize(handle, original: selection)
        return
      }
      if let hit {
        // ⌥：先复制一份（序号换下一个号）放在最上面，拖的是副本，光标带 +
        let before = annotations
        let target = modifiers.contains(.option) ? duplicate(hit, offset: .zero) : hit
        if target.id != hit.id { annotations.append(target) }
        selectedAnnotation = target.id
        (target.id == hit.id ? NSCursor.closedHand : .dragCopy).set()
        drag = .moveAnnotation(
          target, start: point, before: before, copyOf: target.id == hit.id ? nil : hit.id)
        return
      }
      selectedAnnotation = nil
      if let tool, selection.contains(point) {
        switch tool {
        case .text:
          beginEditing(at: point)
        case .counter:
          // 单击放一个序号（编号自动 +1）并选中；按着拖就是挪它，松手一共记一步撤销
          let before = annotations
          let counter = Annotation(
            shape: .counter(Annotation.nextCounter(in: annotations), center: point), style: style)
          annotations.append(counter)
          selectedAnnotation = counter.id
          drag = .moveAnnotation(counter, start: point, before: before, copyOf: nil)
        default:
          drag = .annotate(start: point)
        }
        return
      }
      if selection.contains(point) {
        NSCursor.closedHand.set()
        drag = .move(start: point, original: selection)
        return
      }
    }
    drag = .pending(point)
    pressedHover = isAdjusting ? nil : hoverRect(at: point)
  }

  override func mouseDragged(with event: NSEvent) {
    let point = point(event)
    modifiers = event.modifierFlags
    dragPoint = point
    if !session.hasSelection(besides: self) { mouse = point }
    switch drag {
    case .pending(let start)?:
      guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
      // 别的屏上画了标注：不在这块屏重新框（框出来就会清掉那边），同右键
      if session.hasAnnotations(besides: self) {
        drag = nil
        return refuseWipe(String(localized: "有标注时不能换屏重新框选"))
      }
      window?.makeKey()
      let restore = isAdjusting ? selection : nil
      isAdjusting = false
      drag = .draw(anchor: start, last: start, restore: restore)
      extend(to: point, pans: false)  // 这时的选区还是旧的：先框出新框，之后按空格才平移它
    case .draw?:
      extend(to: point)
    case .move(let start, let original)?:
      NSCursor.closedHand.set()
      selection = RegionSelector.moved(
        original, by: CGSize(width: point.x - start.x, height: point.y - start.y), within: bounds)
    case .resize(let handle, let original)?:
      resize(handle, from: original, to: point)
    case .annotate?, .moveAnnotation?, .resizeAnnotation?:
      dragAnnotation(to: point)
    case nil:
      break
    }
  }

  /// 画标注、拖标注、拖标注的手柄跟到 point。⇧（取自 modifiers，拖动中按下 / 松开时 flagsChanged 也走这里重算）：
  /// 正方形 / 正圆 / 45° 线，拖矩形类的角时保持原比例，拖本体时锁在移动多的那个方向上；⌥：矩形类从中心画 / 改大小
  func dragAnnotation(to point: CGPoint) {
    let constrained = modifiers.contains(.shift)
    switch drag {
    case .annotate(let start)?:
      guard let tool else { return }
      guard tool == .pen else {
        guard
          let shape = Annotation.shape(
            for: tool, from: start, to: point, constrained: constrained,
            fromCenter: modifiers.contains(.option))
        else { return }
        draft = Annotation(id: draft?.id ?? UUID(), shape: shape, style: style)
        return
      }
      // 画笔：一路累点，离上一个点不到 1.5 点的不要（笔迹由 penPath 平滑，点太密只是白算）
      var points = [start]
      if case .pen(let drawn)? = draft?.shape { points = drawn }
      if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
      draft = Annotation(id: draft?.id ?? UUID(), shape: .pen(points + [point]), style: style)
    case .moveAnnotation(let original, let start, _, let copyOf)?:
      (copyOf == nil ? NSCursor.closedHand : .dragCopy).set()
      var delta = CGSize(width: point.x - start.x, height: point.y - start.y)
      if constrained {
        if abs(delta.width) > abs(delta.height) { delta.height = 0 } else { delta.width = 0 }
      }
      replace(original.offset(by: delta))
    case .resizeAnnotation(let original, let handle, _, let offset)?:
      let target = CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
      replace(
        original.resized(
          handle, to: target, constrained: constrained, fromCenter: modifiers.contains(.option)))
    default:
      break
    }
  }

  /// 拖动框选：从锚点拉到当前点（锁着比例时按它，否则 ⇧ 正方形；⌥ 从中心、吸附）；按住空格整块平移，锚点跟着走
  func extend(to point: CGPoint, pans: Bool? = nil) {
    guard case .draw(var anchor, let last, let restore)? = drag else { return }
    NSCursor.crosshair.set()
    if pans ?? isSpaceDown, let current = selection {
      let moved = RegionSelector.moved(
        current, by: CGSize(width: point.x - last.x, height: point.y - last.y), within: bounds)
      anchor.x += moved.minX - current.minX
      anchor.y += moved.minY - current.minY
      guides = (nil, nil)
      selection = moved
    } else {
      let target = snap(point, x: true, y: true)
      let rect = RegionSelector.drawn(
        from: anchor, to: target.point,
        ratio: session.lockedRatio ?? (modifiers.contains(.shift) ? 1 : nil),
        fromCenter: modifiers.contains(.option), within: bounds)
      showGuides(target, on: rect)
      selection = rect
    }
    drag = .draw(anchor: anchor, last: point, restore: restore)
    // 新框够大了才算在这块屏开始、清掉别的屏：别的屏上的选区不能被这里一点误拖（短边 < 8，松手就作废）弄丢
    if let selection, min(selection.width, selection.height) >= RegionSelector.minimumSide,
      session.hasSelection(besides: self)
    {
      session.activate(self)
    }
  }

  /// 拖边 / 角：锁着比例时按它，否则 ⇧ 保持原选区的比例；⌥ 从中心、吸附在动的那条边
  func resize(_ handle: RegionSelector.Handle, from original: CGRect, to point: CGPoint) {
    let target = snap(
      point, x: handle.movesMinX || handle.movesMaxX, y: handle.movesMinY || handle.movesMaxY)
    let rect = RegionSelector.resized(
      original, handle, to: target.point, within: bounds,
      ratio: session.lockedRatio
        ?? (modifiers.contains(.shift) ? original.width / original.height : nil),
      fromCenter: modifiers.contains(.option))
    showGuides(target, on: rect)
    selection = rect
  }

  /// 吸附（⌃ 暂停）：在动的轴上 6 pt 内吸到冻结时本屏窗口的边和屏幕边
  private func snap(_ point: CGPoint, x: Bool, y: Bool) -> (
    point: CGPoint, x: CGFloat?, y: CGFloat?
  ) {
    guard !modifiers.contains(.control) else { return (point, nil, nil) }
    let (snappedX, edgeX) =
      x
      ? RegionSelector.snapped(
        point.x, to: windows.flatMap { [$0.minX, $0.maxX] } + [bounds.minX, bounds.maxX])
      : (point.x, nil)
    let (snappedY, edgeY) =
      y
      ? RegionSelector.snapped(
        point.y, to: windows.flatMap { [$0.minY, $0.maxY] } + [bounds.minY, bounds.maxY])
      : (point.y, nil)
    return (CGPoint(x: snappedX, y: snappedY), edgeX, edgeY)
  }

  /// 参考线只画真落在选区边上的（锁比例时由另一边定大小的那条边不算）；先设它再设选区，refresh 一次画对
  private func showGuides(_ target: (point: CGPoint, x: CGFloat?, y: CGFloat?), on rect: CGRect) {
    func lands(_ edge: CGFloat?, _ low: CGFloat, _ high: CGFloat) -> CGFloat? {
      guard let edge, abs(edge - low) < 0.01 || abs(edge - high) < 0.01 else { return nil }
      return edge
    }
    guides = (lands(target.x, rect.minX, rect.maxX), lands(target.y, rect.minY, rect.maxY))
  }

  override func mouseUp(with event: NSEvent) {
    let finished = drag
    guides = (nil, nil)
    dragPoint = nil
    drag = nil
    switch finished {
    case .pending(let point)?:
      // 单击：截鼠标下最前面的窗口，没有窗口就截整屏；已有选区（本屏或别的屏）时点选区外什么也不做，
      // 免得误点丢掉选区
      if !isAdjusting, !session.hasSelection(besides: self) {
        let picked = pressedHover ?? hoverRect(at: point) ?? bounds
        // 选中的正好是一整扇窗口（全在这块屏里、不是窗口里的元素）：记下它，出图时能单独截（N1）。先记再选中：
        // 选中时那一下重画就按它的圆角画（selectionRadius）
        if let index = windows.firstIndex(of: picked),
          let id = windowIDs.indices.contains(index) ? windowIDs[index] : nil
        {
          clickedWindow = (id, picked, index)
        }
        select(picked)
        if isOverBars(point) { clickSelected = (event.timestamp, point) }
        // ⌥S：单击选中的那一块（元素、窗口、整屏）同框完松手，直接翻
        if autoTranslates { translateInPlace() }
      }
    case .draw(_, _, let restore)?:
      guard let selection, min(selection.width, selection.height) >= RegionSelector.minimumSide
      else {
        // 太小算误触：调整时恢复原来的选区（想拖边差了几点不该把选区弄丢），否则回到待选
        if let restore { select(restore) } else { self.selection = nil }
        return
      }
      if mode == .quick {
        output(.copy)
      } else {
        isAdjusting = true
        // ⌥S：框完自动翻，省掉再点一下工具栏
        if autoTranslates { translateInPlace() }
      }
    case .annotate?:
      let drawn = draft
      draft = nil
      // 画完自动选中（工具保持）：接着就能改样式、拖手柄
      if let drawn, drawn.isMeaningful {
        commit(annotations + [drawn])
        selectedAnnotation = drawn.id
      }
    case .moveAnnotation(let moved, _, let before, let source)?:
      // ⌥ 单击没拖开：不留一份叠在原处、看不出来的副本
      if let source, annotations.contains(moved) {
        annotations = before
        selectedAnnotation = source
      } else {
        recordUndo(from: before)
      }
    case .resizeAnnotation(let original, _, let before, _)?:
      // 对角 / 两端拖到叠在一起、看不出来了：算误操作，恢复原样（不然留下一条看不见却点得中的标注）
      if annotations.first(where: { $0.id == original.id })?.isMeaningful == false {
        replace(original)
      }
      recordUndo(from: before)
    case .move?, .resize?, nil:
      break
    }
    if adjusts { refreshCursor() }
  }

  override func rightMouseDown(with event: NSEvent) {
    // 截图、录屏：有选区时（不管在哪块屏）右键回到待选、重新框，没有才取消；截图翻译 / 识字直接取消
    guard adjusts, selection != nil || session.hasSelection(besides: self) else {
      return session.finish(nil)
    }
    // 画了标注（含正在输入、还没收下的文字，不管在哪块屏）就不清空（一下丢掉太亏）
    if hasAnnotations || session.hasAnnotations(besides: self) {
      return refuseWipe(String(localized: "有标注时右键不清空"))
    }
    session.activate(self)
    reset()
    window?.makeKey()
    mouse = point(event)
    refreshCursor()
  }

  /// 光标只能手动设（见 updateTrackingAreas）：状态一变就按鼠标当前位置重设
  func refreshCursor() {
    guard adjusts else { return }
    guard isAdjusting, let selection, let point = mouse else { return NSCursor.crosshair.set() }
    if let translationCard, translationCard.hasText(at: point, in: self) {
      return NSCursor.iBeam.set()
    }
    if isOverControls(point) { return NSCursor.arrow.set() }
    if pickingColor { return NSCursor.crosshair.set() }
    if let editor {  // 输入框里是文字光标；外面点一下只是收下文字
      return (editor.field.frame.contains(point) ? NSCursor.iBeam : NSCursor.arrow).set()
    }
    // 顺序同按下的优先级（mouseDown）
    if let grip = annotationHandle(at: point) { return Self.cursor(for: grip.handle).set() }
    if let handle = Self.handle(at: point, in: selection) {
      return NSCursor.frameResize(position: Self.position(of: handle), directions: .all).set()
    }
    if annotation(at: point) != nil { return NSCursor.openHand.set() }
    if let tool, selection.contains(point) {
      return (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
    }
    (selection.contains(point) ? NSCursor.openHand : NSCursor.crosshair).set()
  }

  /// 标注手柄上的光标：矩形类的角、边中点同选区的缩放光标，线类两端和箭头的弯曲手柄是手指（往哪儿拖都行）。
  /// 长图 / 历史的标注遮罩（ScrollCanvas）也用它
  static func cursor(for handle: Annotation.Handle) -> NSCursor {
    handle.box.map { .frameResize(position: position(of: $0), directions: .all) } ?? .pointingHand
  }

  private static func position(of handle: RegionSelector.Handle) -> NSCursor.FrameResizePosition {
    switch handle {
    case .bottomLeft: .bottomLeft
    case .bottom: .bottom
    case .bottomRight: .bottomRight
    case .right: .right
    case .topRight: .topRight
    case .top: .top
    case .topLeft: .topLeft
    case .left: .left
    }
  }

  // MARK: 跟手

  func startFollowing() {
    stopFollowing()
    let link = displayLink(target: self, selector: #selector(followPointer))
    link.add(to: .main, forMode: .common)
    follow = link
  }

  func stopFollowing() {
    follow?.invalidate()
    follow = nil
  }

  @objc private func followPointer() {
    // 会话结束是 orderOut（视图还在窗口里，viewDidMoveToWindow 不会再来），在这儿收摊
    guard let window, window.isVisible else { return stopFollowing() }
    // 拖动时让拖动事件自己带着走：放大镜跑到选区前面更难看
    guard case nil = drag, !session.hasSelection(besides: self) else { return }
    let global = NSEvent.mouseLocation
    guard window.frame.contains(global) else { return }  // 不在这块屏上：交给 mouseExited 清
    let now = clamped(convert(window.convertPoint(fromScreen: global), from: nil))
    if let mouse, abs(mouse.x - now.x) < 0.01, abs(mouse.y - now.y) < 0.01 { return }
    mouse = now
  }

  /// 事件位置（视图坐标），夹在本屏范围内
  private func point(_ event: NSEvent) -> CGPoint {
    clamped(convert(event.locationInWindow, from: nil))
  }

  func clamped(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY)
    )
  }
}
