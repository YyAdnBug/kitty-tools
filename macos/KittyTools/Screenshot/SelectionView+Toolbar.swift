// 框选遮罩的工具栏和样式托盘（第五轮体检 H1 从 SelectionView.swift 拆出）：建条、摆在哪、改键和提示、字号 / 存储 / 比例菜单、吸管、一键打码、尺寸输入、Esc 的先后。

import AppKit
import Carbon.HIToolbox

extension SelectionView {
  // MARK: 工具栏

  func makeBars() {
    let toolbar = EditorToolbar()
    toolbar.onRightClick = { [unowned self] item in offerRebind(item) }
    toolbar.onClick = { [unowned self] item in
      finishSizeEditing(commit: true)  // 输入着尺寸点了栏：先按输入的改选区再出图
      if item != .saveMenu { hudMenu?.dismiss() }
      switch item {
      case .tool(let tool): choose(tool)
      case .undo: undo()
      case .redo: redo()
      case .output(let action): output(action)
      case .scroll: startScroll()
      case .record: switchToRecording()
      case .saveMenu: toggleSaveMenu()
      case .cancel: cancel()
      // 截图框选的工具栏里没有裁剪（调选区就是裁剪）、没有「完成」（那是从截图历史改标注时的）
      case .crop, .done: break
      }
    }
    let styleBar = StyleBar()
    styleBar.onColor = { [unowned self] color in
      restyle {
        $0.color = color
        $0.custom = nil
      }
    }
    styleBar.onEyedropper = { [unowned self] in beginPickingColor() }
    styleBar.onWeight = { [unowned self] weight in
      restyle {
        $0.weight = weight
        $0.diameter = nil  // 序号拖角改过的大小：点了三档就回到三档
      }
    }
    styleBar.onOption = { [unowned self] option in restyle { $0.option = option } }
    styleBar.onFontStep = { [unowned self] step in restyle { $0 = $0.stepped(step, for: .text) } }
    styleBar.onFontMenu = { [unowned self] button in toggleFontMenu(from: button) }
    styleBar.onNumber = { [unowned self] delta in renumberSelected(by: delta) }
    styleBar.onAutoRedact = { [unowned self] in autoRedact() }
    // ponytail: macOS 26 上工具栏（两段已在同一个玻璃容器里）、样式托盘、HUD 菜单、尺寸胶囊是各自独立的玻璃兄弟视图，
    // 违反「相邻的玻璃放进同一个 NSGlassEffectContainerView」（玻璃互相取样不到，托盘离工具栏只有 6 pt，颜色会不一致）。
    // 升级路径：SelectionView 里建一个铺满的容器，四者都挂进它的 contentView（改挂载层级和 z 序，要 26 实机验证）
    for bar in [toolbar, styleBar] as [NSView] {
      bar.isHidden = true
      addSubview(bar)
    }
    self.toolbar = toolbar
    self.styleBar = styleBar
  }

  /// 录屏：录制条放在截图工具栏的位置（toolbarPlacement），同样从选区那条边长出来、拖动选区时淡出
  func makeRecordBar() {
    let bar = RecordBar(defaults: styleDefaults)
    bar.onClick = { [unowned self] item in
      finishSizeEditing(commit: true)  // 输入着尺寸点了 ●：先按输入的改选区再开录
      hudMenu?.dismiss()
      switch item {
      case .cancel: session.finish(nil)
      case .start: startRecording()
      case .systemAudio, .microphone, .clicks, .keys: break  // 开关录制条自己记偏好
      }
    }
    bar.isHidden = true
    addSubview(bar)
    recordBar = bar
  }

  /// 工具栏在选区下方 10 pt，水平按设置 › 截图「工具栏位置」靠右（右边线对齐选区右边线）或居中；样式托盘锚在当前工具
  /// （或选中标注的工具、输入中的文字）按钮外侧 6 pt，水平以按钮为中心（夹在屏内 10 pt），换工具时 settle 滑过去。
  /// 出现 / 收起都带动画（PopView.setShown）。录屏只有录制条，位置同工具栏
  func placeBars(showing: Bool) {
    let alignRight = Prefs.toolbarAlignsRight(styleDefaults)
    if let recordBar {
      guard showing, let selection else {
        recordBar.grow(false)
        hudMenu?.dismiss()
        return
      }
      // 录制条外侧没有样式托盘，不用给它留地方
      let (origin, edge, anchorX) = Self.toolbarPlacement(
        size: recordBar.frame.size, selection: selection, in: bounds, tray: 0,
        alignRight: alignRight)
      if recordBar.frame.origin != origin { recordBar.setFrameOrigin(origin) }
      return recordBar.grow(true, from: edge, anchorX: anchorX)
    }
    guard let toolbar, let styleBar else { return }
    guard showing, let selection else {
      toolbar.grow(false)
      styleBar.setShown(false)
      hudMenu?.dismiss()
      return
    }
    // 输入文字时重做钮灰掉：点它会先收下文字（记一步、清空重做），什么也重做不了（⇧⌘Z 归输入框自己）
    toolbar.update(
      tool: tool, canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty && editor == nil)
    let (origin, edge, anchorX) = Self.toolbarPlacement(
      size: toolbar.frame.size, selection: selection, in: bounds, alignRight: alignRight)
    let moved = toolbar.frame.origin != origin
    if moved { toolbar.setFrameOrigin(origin) }
    toolbar.grow(true, from: edge, anchorX: anchorX)
    let owner: Annotation.Tool? = editor != nil ? .text : selected?.tool ?? tool
    guard let owner else { return styleBar.setShown(false) }
    styleBar.update(tool: owner, style: shownStyle, number: selectedCounterNumber)
    let button = toolbar.toolButtonFrame(owner).offsetBy(dx: origin.x, dy: origin.y)
    let size = styleBar.preferredSize
    // 栏放进了选区里（上下都放不下）：托盘也夹在选区里、离四边 8 pt，不压能拖的边；否则夹在屏内 10 pt
    let inner = selection.insetBy(dx: 8, dy: 8)
    let lane =
      origin.y >= selection.minY && origin.y < selection.maxY && size.width <= inner.width
      ? inner : bounds.insetBy(dx: 10, dy: 0)
    let x = max(lane.minX, min(button.midX - size.width / 2, lane.maxX - size.width)).rounded()
    // 栏在选区下方就往下叠，在上方 / 选区里就往上叠；叠不下换另一边
    let below = origin.y - 6 - size.height
    let above = origin.y + toolbar.frame.height + 6
    var y = edge == .top ? below : above
    if y < bounds.minY || y + size.height > bounds.maxY { y = edge == .top ? above : below }
    styleBar.move(
      to: CGRect(x: x, y: y, width: size.width, height: size.height),
      animated: styleBar.isShown && !moved)
    styleBar.setShown(true, anchorX: button.midX - x, growingFrom: y < origin.y ? .top : .bottom)
  }

  /// 工具栏放哪、从哪条边长出来：选区下方 10 pt（从顶边长出），放不下放上方，都放不下放进选区底部（这两种从底边长出）；
  /// 「放得下」连栏外侧的样式托盘（tray，6 + 34；录制条没有托盘传 0）一起算：托盘在栏外放不下只能翻到栏里侧，压住选区的边、
  /// 那段边就拖不动了。
  /// 水平（夹在屏内 10 pt）：alignRight 时栏的右边线对齐选区右边线（2026-11-05 拍板：从左上往右下拖完，✓ 就在鼠标旁边），
  /// 放进选区时往里收 10 pt（不压右边那条能拖的边和角手柄）；否则以选区为中心。选区是鼠标给的小数点，取整到整点，
  /// 栏里的图标和描边才不发糊。
  /// anchorX：长出来的那一点（栏自身坐标）。居中是中点；靠右对着选区右边的角，栏被屏幕顶住够不着时取栏上离角最近的点
  static func toolbarPlacement(
    size: CGSize, selection: CGRect, in bounds: CGRect, tray: CGFloat = 6 + StyleBar.height,
    alignRight: Bool = false
  ) -> (origin: CGPoint, edge: PopView.Edge, anchorX: CGFloat) {
    let margin: CGFloat = 10
    func left(_ x: CGFloat) -> CGFloat {
      max(bounds.minX + margin, min(x, bounds.maxX - size.width - margin)).rounded()
    }
    func placed(_ x: CGFloat, _ y: CGFloat, _ edge: PopView.Edge) -> (
      CGPoint, PopView.Edge, CGFloat
    ) {
      let anchorX = alignRight ? min(max(selection.maxX - x, 0), size.width) : size.width / 2
      return (CGPoint(x: x, y: y), edge, anchorX)
    }
    let x = left(alignRight ? selection.maxX - size.width : selection.midX - size.width / 2)
    let below = (selection.minY - margin - size.height).rounded()
    if below - tray >= bounds.minY { return placed(x, below, .top) }
    let above = (selection.maxY + margin).rounded()
    if above + size.height + tray <= bounds.maxY { return placed(x, above, .bottom) }
    let inside = alignRight ? left(selection.maxX - margin - size.width) : x
    return placed(inside, (selection.minY + margin).rounded(), .bottom)
  }

  /// 两个 HUD 菜单的名字（旁白读它，也用来认开着的是哪个）
  private static var saveMenuLabel: String { String(localized: "存储选项") }
  private static var rebindMenuLabel: String { String(localized: "快捷键") }
  /// 等新的键最多等多久（秒）：提示一直在，过了就当取消
  private static let rebindWait = 60.0

  /// 工具栏按钮上右键（2026-11-06 用户：截图时改快捷键更友好）：HUD 菜单「改「钉到屏幕」的快捷键…」（右边写现在的键），
  /// 不是默认的再加「恢复默认」。开着时再右键一下收起
  private func offerRebind(_ item: EditorToolbar.Item) {
    if closesMenu(Self.rebindMenuLabel) { return }
    guard let key = EditorToolbar.shotKey(for: item), let toolbar,
      let button = toolbar.button(for: item)
    else { return }
    rebindItem = item
    var entries: [HUDMenu.Entry] = [
      .init(title: String(localized: "改「\(key.title)」的快捷键…"), key: key.label) { [weak self] in
        self?.startRebind(key)
      }
    ]
    if key.key() != key.defaultKey {
      entries.append(
        .init(title: String(localized: "恢复默认"), key: key.defaultKey.display) { [weak self] in
          self?.setShotKey(key, to: key.defaultKey)
        })
    }
    present(
      HUDMenu(entries, label: Self.rebindMenuLabel),
      anchor: button.convert(button.bounds, to: self))
  }

  /// 开始等新的键：那颗钮带粉圈、旁边的提示一直在（最多 rebindWait 秒），输入着的文字、尺寸先收下（不然按键归它们）
  private func startRebind(_ key: ShotKey) {
    finishSizeEditing(commit: true)
    endEditing()
    rebinding = key
    toolbar?.setWaiting(rebindItem)
    let text = String(localized: "按下新的键给「\(key.title)」")
    announce(text)
    showRebindTip([text, String(localized: "Esc 取消")])
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.rebindWait))
      if let self, self.rebinding == key { self.stopRebind() }
    }
  }

  /// 不等了：粉圈、提示都收掉
  func stopRebind() {
    rebinding = nil
    toolbar?.setWaiting(nil)
    hideRebindTip()
  }

  /// 提示挂在 rebindItem 那颗钮旁边：工具栏在选区下面就挂在工具栏下面，在上面就挂在上面，那一侧放不下换另一侧；
  /// 横向对着钮、夹在屏幕里。seconds 为 nil 一直在（等着的时候）
  private func showRebindTip(_ parts: [String], seconds: Double? = nil) {
    guard let toolbar, let item = rebindItem, let button = toolbar.button(for: item) else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rebindTip.setParts(parts)
    let size = rebindTip.size
    let anchor = button.convert(button.bounds, to: self)
    let bar = toolbar.frame
    let below = bar.minY - 8 - size.height
    let above = bar.maxY + 8
    let prefersBelow = bar.midY < (selection?.midY ?? bounds.midY)
    let y =
      prefersBelow
      ? (below >= bounds.minY + 8 ? below : above)
      : (above + size.height <= bounds.maxY - 8 ? above : below)
    let x = min(
      max(anchor.midX - size.width / 2, bounds.minX + 8), bounds.maxX - 8 - size.width)
    rebindTip.place(at: CGPoint(x: x, y: y))
    let appearing = rebindTip.layer.isHidden
    rebindTip.layer.isHidden = false
    CATransaction.commit()
    if appearing, !Style.reduceMotion {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = Style.fadeIn
      rebindTip.layer.add(fade, forKey: "enter")
    }
    rebindTipGeneration += 1
    let generation = rebindTipGeneration
    guard let seconds else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, self.rebindTipGeneration == generation else { return }
      self.hideRebindTip()
    }
  }

  private func hideRebindTip() {
    rebindTipGeneration += 1
    rebindTip.layer.isHidden = true
  }

  /// 等着新的键时按了一下：Esc 取消；规矩同设置页（ShotKey.problem：固定的键、截图里重复、和全局快捷键一样的不收，
  /// 不收时接着等）
  func rebind(_ key: ShotKey, with event: NSEvent) {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if Int(event.keyCode) == kVK_Escape, flags.isEmpty {
      rebinding = nil
      toolbar?.setWaiting(nil)
      let label = key.label ?? String(localized: "未设置")
      return showRebindTip([String(localized: "没改，还是 \(label)")], seconds: 1.5)
    }
    setShotKey(key, to: HotKey(keyCode: event.keyCode, flags: event.modifierFlags))
  }

  private func setShotKey(_ key: ShotKey, to hotKey: HotKey) {
    if let problem = ShotKey.problem(with: hotKey, for: key) {
      NSSound.beep()
      announce(problem)
      // 从右键菜单「恢复默认」来的（没在等）不接着等
      if rebinding == key {
        showRebindTip([problem, String(localized: "换一个键"), String(localized: "Esc 取消")])
      } else {
        showRebindTip([problem], seconds: 2.5)
      }
      return
    }
    rebinding = nil
    toolbar?.setWaiting(nil)
    key.set(hotKey)
    toolbar?.refreshTips()
    let done = String(localized: "「\(key.title)」的快捷键改成了 \(hotKey.display)")
    announce(done)
    showRebindTip([done], seconds: 1.8)
  }
  private static var ratioMenuLabel: String { String(localized: "比例") }

  /// 托盘上字号的数字：HUD 菜单列字号档位（勾着现在的），锚在数字下方；开着时再点一下收起
  private func toggleFontMenu(from button: NSView) {
    if closesMenu(HUDMenu.fontMenuLabel) { return }
    present(
      .fontSizes(current: shownStyle.textSize) { [weak self] size in
        self?.restyle { $0.fontSize = size }
      }, anchor: button.convert(button.bounds, to: self))
  }

  /// 吸管：放大镜跟着鼠标出来（中心像素的色值在信息卡上），单击取色
  private func beginPickingColor() {
    hudMenu?.dismiss()
    guard annotates, isAdjusting, !isDraggingAnnotation else { return }
    endEditing()
    pickingColor = true
    flashHint([String(localized: "单击取色"), String(localized: "Esc 取消")])
    announce(String(localized: "单击取色"))
    refresh()
    refreshCursor()
  }

  /// 取放大镜中心那一点的颜色，作用于选中的标注 / 当前工具（同点色点）
  func pickColor() {
    pickingColor = false
    if let sampled, let rgb = Int(sampled.hex.dropFirst(), radix: 16) {
      restyle { $0.custom = rgb }
      announce(String(localized: "已取色 \(sampled.hex)"))
    }
    refresh()
    refreshCursor()
  }

  /// 选中的序号的编号（托盘出「编号 − n +」）；选中的不是序号、正在输入文字时 nil
  private var selectedCounterNumber: Int? {
    guard editor == nil, case .counter(let number, _)? = selected?.shape else { return nil }
    return number
  }

  /// 一键打码（拍板 C5）：选区里识字，手机号、邮箱、银行卡号、身份证号各加一块打码（托盘上打码现在的样式），
  /// 一起记一步撤销。识字在主线程外（0.2–0.6 s），回来时选区变了就作废
  private func autoRedact() {
    hudMenu?.dismiss()
    guard annotates, isAdjusting, !redacting, !translating, !isDraggingAnnotation, let selection
    else { return }
    let source = image
    let pixels = RegionSelector.pixelRect(
      selection, viewSize: bounds.size,
      imageSize: CGSize(width: source.width, height: source.height))
    guard let crop = source.cropping(to: pixels) else { return }
    let style = shownStyle
    redacting = true
    announce(String(localized: "正在找要打码的内容"))
    Task { [weak self] in
      let boxes = await OCR.redactionBoxes(in: crop)
      // 正拖着标注就等松手再落：中途改了列表，松手记的那一步撤销会把打码一起撤掉（⌥ 单击没拖开还会整个丢掉）
      while self?.isDraggingAnnotation == true { try? await Task.sleep(for: .milliseconds(50)) }
      guard let self else { return }
      redacting = false
      // 选区挪了、会话结束了、图换成了译文图：位置对不上，作废
      guard isAdjusting, self.selection == selection, image === source else { return }
      let areas = Redaction.areas(boxes ?? [], in: selection, existing: annotations)
      guard !areas.isEmpty else {
        let reason = boxes == nil ? String(localized: "识字失败，没有打码") : String(localized: "没找到要打码的内容")
        flashHint([reason])
        announce(reason)
        return
      }
      commit(annotations + areas.map { Annotation(shape: .mosaic($0), style: style) })
      selectedAnnotation = nil
      refresh()
      announce(String(localized: "已打码 \(areas.count) 处"))
    }
  }

  /// 选中的序号编号加减 delta（记一步撤销；之后新放的照旧是现有最大 + 1）
  private func renumberSelected(by delta: Int) {
    hudMenu?.dismiss()
    guard !isDraggingAnnotation, let number = selectedCounterNumber, let selected,
      let index = annotations.firstIndex(where: { $0.id == selected.id })
    else { return }
    var next = annotations
    next[index] = selected.renumbered(number + delta)
    commit(next)
    refresh()
    if let shown = selectedCounterNumber { announce(String(localized: "编号 \(shown)")) }
  }

  /// 滚轮换档（拍板 O1）：调整阶段鼠标在选中的标注上（或正在输入的文字上）滚，往上大一档、往下小一档——文字是字号，
  /// 别的是三档（粗细、打码强度、聚光灯深浅）。触控板的细碎滚动攒够一格才换（同悬停认元素的 ElementFinder.step）。
  /// ponytail: 每换一档记一步撤销，触控板一甩换几档就要按几下 ⌘Z；要合成一步就在滚动停下（phase .ended）时再记
  func wheelRestyle(_ event: NSEvent) -> Bool {
    guard annotates, isAdjusting, drag == nil, !sizeField.isEditing, let mouse,
      !isOverControls(mouse)
    else { return false }
    let owner: Annotation.Tool
    if let editor, editor.field.frame.contains(mouse) {
      owner = .text
    } else if editor == nil, let selected, selected.contains(mouse) {
      owner = selected.tool
    } else {
      return false
    }
    guard event.momentumPhase.isEmpty else { return true }
    if event.phase == .began { scrollPending = 0 }
    let (step, pending) = ElementFinder.step(
      deltaY: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice,
      precise: event.hasPreciseScrollingDeltas, pending: scrollPending)
    scrollPending = pending
    if step != 0 { restyle { $0 = $0.stepped(step, for: owner) } }
    return true
  }

  /// 开着的正是这个菜单就收起（再点一下同一个按钮）；开着的是另一个时不收，由 present 换成新的（一下就开，不用点两次）
  private func closesMenu(_ label: String) -> Bool {
    guard let hudMenu, hudMenu.accessibilityLabel() == label else { return false }
    hudMenu.dismiss()
    return true
  }

  /// 保存 ▾：HUD 菜单锚在保存按钮下方；开着时再点一下收起
  private func toggleSaveMenu() {
    if closesMenu(Self.saveMenuLabel) { return }
    guard let toolbar, let body = toolbar.button(for: .output(.save)),
      let caret = toolbar.button(for: .saveMenu)
    else { return }
    present(
      HUDMenu(
        [
          .init(title: ScreenshotOutput.saveTitle, key: ShotKey.save.label ?? "") { [weak self] in
            self?.output(.save)
          },
          .init(title: String(localized: "另存为…"), key: ShotKey.saveAs.label ?? "") { [weak self] in
            self?.output(.saveAs)
          },
        ], label: Self.saveMenuLabel),
      anchor: body.convert(body.bounds, to: self).union(caret.convert(caret.bounds, to: self)))
  }

  /// 尺寸胶囊的比例按钮：HUD 菜单（自由 / 1:1 / 4:3 / 3:2 / 16:9 / 9:16，勾着锁住的那个）；开着时再点一下收起
  func toggleRatioMenu() {
    if closesMenu(Self.ratioMenuLabel) { return }
    endEditing()
    let locked = session.lockedRatio
    present(
      HUDMenu(
        RegionSelector.ratios.map { preset in
          HUDMenu.Entry(title: preset.title, checked: preset.value == locked) { [weak self] in
            self?.lockRatio(preset.value)
          }
        }, label: Self.ratioMenuLabel),
      anchor: sizeField.convert(sizeField.ratioFrame, to: self))
  }

  /// 选了比例：立刻套到选区上（顶边和水平中心不动）并锁住，之后框选、拖边都按它；nil（自由）解锁
  private func lockRatio(_ ratio: CGFloat?) {
    session.lockedRatio = ratio
    if let ratio, let selection {
      self.selection = RegionSelector.applying(ratio, to: selection, within: bounds)
    }
    refresh()
    refreshCursor()
    announce(
      ratio.map { String(localized: "已锁定比例 \(RegionSelector.ratioTitle($0))") }
        ?? String(localized: "已解锁比例"))
  }

  /// 点了尺寸胶囊的数字：收掉菜单和输入中的文字，两个数变成输入框
  func beginSizeEditing(_ which: SizeField.Dimension) {
    hudMenu?.dismiss()
    endEditing()
    sizeField.beginEditing(which)
    refresh()
  }

  /// 收下尺寸输入：先把键盘要回来再把输入框变回数字（反过来第一响应者落到窗口上，单键快捷键全失灵）；
  /// commit 时按输入的像素改选区（左上角不动）
  func finishSizeEditing(commit: Bool) {
    guard sizeField.isEditing else { return }
    window?.makeFirstResponder(self)
    let pixels = sizeField.typedPixels
    sizeField.endEditing()
    if commit, let pixels, let selection {
      self.selection = RegionSelector.sized(
        selection, pixels: pixels,
        scale: CGSize(
          width: CGFloat(image.width) / bounds.width, height: CGFloat(image.height) / bounds.height),
        within: bounds)
    }
    refresh()
  }

  /// Esc 依次：HUD 菜单 → 译文卡片 → 尺寸输入 → 输入中的文字 → 选中的标注 → 工具 → 取消截图（免得一下把画好的标注全丢了；
  /// 画过标注时最后这一下也要按两次，cancel）
  func escape() {
    if let hudMenu {
      hudMenu.dismiss()
    } else if pickingColor {
      pickingColor = false
      refresh()
      refreshCursor()
    } else if let translationCard, !translationCard.leftovers.isEmpty {
      // 列着放不下的段的卡片先收；只有一条窄栏时不拦 Esc，照常往下走（退出截图）
      closeTranslationCard()
    } else if sizeField.isEditing {
      finishSizeEditing(commit: false)
    } else if editor != nil {
      endEditing()
    } else if selectedAnnotation != nil {
      selectedAnnotation = nil
    } else if tool != nil {
      tool = nil
      refreshCursor()
      announce(String(localized: "已收起工具"))
    } else {
      cancel()
    }
  }

  /// 退出截图（Esc 退到头、工具栏 ✕）。画过标注（不管在哪块屏，含输入着还没收下的字）时第一下只上膛（第五轮体检 E8，同长截图、
  /// 标注遮罩的两下 Esc；截图历史只记出过的图，这里丢了就找不回来）：提示音 + 顶上提示「再按一次放弃这些标注」+ 播报，
  /// 约 2 秒内再按一次（Esc、✕ 都算，哪块屏上按的都算：上膛记在几块屏共用的会话上）才放弃
  private func cancel() {
    if hasAnnotations || session.hasAnnotations(besides: self), !session.discardArm.press(at: .now)
    {
      NSSound.beep()
      flashHint([String(localized: "再按一次放弃这些标注")])
      return announce(String(localized: "再按一次放弃这些标注"))
    }
    cancelTranslation()
    session.finish(nil)
  }

  /// 同时最多开一个 HUD 菜单
  private func present(_ next: HUDMenu, anchor: CGRect) {
    hudMenu?.dismiss()
    hudMenu = next
    next.onDismiss = { [weak self, weak next] in
      guard let self, self.hudMenu === next else { return }
      self.hudMenu = nil
      self.refreshCursor()
    }
    next.present(in: self, anchor: anchor)
    refresh()
  }

  /// 两条栏（录屏是录制条）和开着的菜单（按钮间隙、边距会顺着响应链落到遮罩上）
  private var bars: [NSView] {
    [toolbar as NSView?, styleBar, recordBar, hudMenu, translationCard].compactMap { $0 }
  }

  func isOverBars(_ point: CGPoint) -> Bool {
    bars.contains { !$0.isHidden && $0.frame.contains(point) }
  }

  /// 栏、菜单或能点的尺寸胶囊上：光标是箭头、边不热
  func isOverControls(_ point: CGPoint) -> Bool {
    isOverBars(point)
      || (sizeField.isInteractive && !sizeField.isHidden && sizeField.frame.contains(point))
  }

  func isOverBars(_ rect: CGRect) -> Bool {
    bars.contains { !$0.isHidden && $0.frame.intersects(rect) }
  }
}
