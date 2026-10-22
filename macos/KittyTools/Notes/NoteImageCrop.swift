// 便签正文里图片的裁切层（便签未来计划 D1 / D2，2026-10-22；规矩在 mac-overlay-panel §3「行内图片：裁切」）。
// 右键图片「裁切…」→ 正文的滚动区上盖这一层（同一扇窗口里的视图，不另开窗口、不碰激活；那叠、浮动便签、全部便签
// 窗口、墙的编辑卡是同一个正文框，一处做完四处都有）：整张图按这块地方放下、框外压暗，四角四边的把手（整条边都能拖）
// + 框里按住拖 = 挪；底下一排：比例（自由 / 原比例 / 1:1 / 4:3 / 3:4 / 16:9 / 9:16——竖的两档就是「横竖互换」）、
// 取消、完成。↩ 完成、Esc 取消、方向键挪（⇧ 一次 10 点）。它当第一响应者：Esc / ↩ 在它这里就接住了，到不了面板
// （那叠的「关这条便签」）；滚轮也吞掉（不然后面的正文跟着滚）。**键盘离开它（点了标题框、⌘T / ⌘F 把焦点交回正文）
// 就当取消、收起**：不然层还盖着、字却打进藏着的正文，↩ 也会被「完成」的默认按钮接走。
// 滚动区（NSScrollView）自己变大小只走 tile()、不按 autoresizingMask 带它的子视图：这一层自己听滚动区的
// frameDidChange、铺满它（评审时独立脚本实测）。
// 几何借截图框选那一套（RegionSelector.handle / resized：拖边拖角、锁比例、越过对边翻过去），坐标是**转正之后的像素、
// 原点在左下**（同 CG，方向和光标的朝向对得上），交出去时换成左上角原点（NoteImageStore.crop 的口径）。
// 这一层只交一个结果（onDone / onCancel），换图、撤销、认目标在 NoteTextView+Images。
// ponytail: 键盘只能挪框、选比例，不能拉大小（锁比例时推一条边会破比例）；要的话照截图的 ⌘ / ⌥ 方向键做。

import AppKit
import SwiftUI

enum NoteImageCrop {
  /// 框至少这么多像素（图本身更小就按图）
  static let minPixels: CGFloat = 16

  /// 比例（宽 / 高；nil = 自由）。「原比例」按这张图算
  static func ratios(for size: CGSize) -> [(title: String, value: CGFloat?)] {
    [
      ("自由", nil), ("原比例", size.width / max(size.height, 1)), ("1:1", 1), ("4:3", 4.0 / 3),
      ("3:4", 3.0 / 4), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]
  }

  /// 选了一个比例：这个比例下整张图里放得下的最大的框，中心尽量对着现在的框（夹进整张图）。反复换比例不会越换越小
  static func fitted(_ ratio: CGFloat, around rect: CGRect, in bounds: CGRect) -> CGRect {
    var width = bounds.width
    var height = width / ratio
    if height > bounds.height {
      height = bounds.height
      width = height * ratio
    }
    return CGRect(
      x: min(max(rect.midX - width / 2, bounds.minX), bounds.maxX - width),
      y: min(max(rect.midY - height / 2, bounds.minY), bounds.maxY - height),
      width: width, height: height)
  }

  /// 拖把手：从按下时的框 start 出发，把手管的边移到 point（RegionSelector.resized）；小过最小边就停在上一个（current）
  static func resized(
    _ start: CGRect, current: CGRect, handle: RegionSelector.Handle, to point: CGPoint,
    in bounds: CGRect, ratio: CGFloat?
  ) -> CGRect {
    let next = RegionSelector.resized(start, handle, to: point, within: bounds, ratio: ratio)
    let least = CGSize(
      width: min(minPixels, bounds.width), height: min(minPixels, bounds.height))
    return next.width >= least.width - 0.01 && next.height >= least.height - 0.01 ? next : current
  }

  /// 交出去的像素框：四条边各自取整、夹进整张图，原点换到左上角（NoteImageStore.crop 的口径）。
  /// 就是整张图（没裁）或者取整后没了 → nil
  static func pixelRect(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
    let minX = min(max(rect.minX.rounded(), 0), imageSize.width)
    let maxX = min(max(rect.maxX.rounded(), 0), imageSize.width)
    let minY = min(max(rect.minY.rounded(), 0), imageSize.height)
    let maxY = min(max(rect.maxY.rounded(), 0), imageSize.height)
    guard maxX - minX >= 1, maxY - minY >= 1 else { return nil }
    let full = CGRect(origin: .zero, size: imageSize)
    let flipped = CGRect(
      x: minX, y: imageSize.height - maxY, width: maxX - minX, height: maxY - minY)
    return flipped == full ? nil : flipped
  }
}

/// 盖在正文滚动区上的那一层
final class NoteImageCropView: NSView {
  /// 裁的是哪张图（令牌里那张）、在第几个字（回来时认目标用）
  let picture: NoteImages.Image
  let index: Int
  /// 转正之后的像素宽高
  let pixelSize: CGSize
  /// 现在的框（像素，原点左下）
  private(set) var crop: CGRect
  /// 锁着的比例（宽 / 高；nil = 自由）
  private(set) var ratio: CGFloat?
  /// 完成：左上角原点的像素框；没裁（整张图）给 nil
  var onDone: (CGRect?) -> Void = { _ in }
  var onCancel: () -> Void = {}
  /// 打开那一刻编辑器交出去的正文（回来时认目标：没变就看原来那个字）
  var reportedAtStart = ""

  /// 图的文件（缩略图走正文里的同一份缓存 NoteImageThumbnails：正文里那一档先拿来缩放着画，不闪空白）
  private let url: URL?
  private let ratioButton = NSPopUpButton()
  private let bar = NSStackView()
  private var drag: (handle: RegionSelector.Handle?, start: CGRect, down: CGPoint)?

  /// 图四周留多少、底下那一排多高
  static let margin: CGFloat = 14
  static let barHeight: CGFloat = 40
  /// 把手多大、边上多宽算拖得到
  static let handleSide: CGFloat = 8
  static let grabTolerance: CGFloat = 8

  init(picture: NoteImages.Image, index: Int, pixelSize: CGSize, url: URL?) {
    self.picture = picture
    self.index = index
    self.pixelSize = pixelSize
    crop = CGRect(origin: .zero, size: pixelSize)
    self.url = url
    super.init(frame: .zero)
    // 深底上的控件按深色画（浅色外观也一样：裁切是看图的地方）
    appearance = NSAppearance(named: .darkAqua)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("裁切图片")
    buildBar()
    changed()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func buildBar() {
    for (offset, item) in NoteImageCrop.ratios(for: pixelSize).enumerated() {
      ratioButton.addItem(withTitle: item.title)
      ratioButton.lastItem?.tag = offset
    }
    ratioButton.controlSize = .small
    ratioButton.target = self
    ratioButton.action = #selector(ratioChosen(_:))
    ratioButton.setAccessibilityLabel("比例")
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
    let done = NSButton(title: "完成", target: self, action: #selector(done(_:)))
    done.keyEquivalent = "\r"
    for button in [cancel, done] { button.controlSize = .small }
    // 全键盘操作时 Tab 在这几样之间转（keyDown 不认的键交给父类，窗口按 nextKeyView 走）
    nextKeyView = ratioButton
    ratioButton.nextKeyView = cancel
    cancel.nextKeyView = done
    done.nextKeyView = self
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    bar.orientation = .horizontal
    bar.spacing = 8
    bar.setViews([ratioButton, spacer, cancel, done], in: .leading)
    bar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
      bar.bottomAnchor.constraint(equalTo: bottomAnchor),
      bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
    ])
  }

  // MARK: 几何（视图坐标 ↔ 像素）

  /// 放图的地方：四周留白、底下让出那一排
  private var imageArea: CGRect {
    CGRect(
      x: Self.margin, y: Self.barHeight, width: max(bounds.width - Self.margin * 2, 1),
      height: max(bounds.height - Self.barHeight - Self.margin, 1))
  }

  /// 整张图在视图里的那一块（按比例放进 imageArea、居中）
  var imageRect: CGRect {
    let area = imageArea
    let scale = min(area.width / pixelSize.width, area.height / pixelSize.height)
    let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    return CGRect(
      x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width,
      height: size.height)
  }

  /// 一个像素多少点
  private var scale: CGFloat { imageRect.width / pixelSize.width }

  private func pixels(_ point: CGPoint) -> CGPoint {
    let rect = imageRect
    return CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
  }

  /// 框在视图里的那一块
  var cropRect: CGRect {
    let rect = imageRect
    return CGRect(
      x: rect.minX + crop.minX * scale, y: rect.minY + crop.minY * scale,
      width: crop.width * scale, height: crop.height * scale)
  }

  /// 整张图（像素）
  private var whole: CGRect { CGRect(origin: .zero, size: pixelSize) }

  /// 这一点（像素）上是哪个把手：边上的带在框很小时收窄，中间还能拖着挪
  private func handle(at point: CGPoint) -> RegionSelector.Handle? {
    let tolerance = Self.grabTolerance / scale
    return RegionSelector.handle(
      at: point, in: crop, tolerance: tolerance,
      inner: min(tolerance, min(crop.width, crop.height) / 3))
  }

  // MARK: 改框（单测直接调）

  /// 选了第 offset 个比例：换成这个比例下最大的框（自由不动框）
  func choose(ratioAt offset: Int) {
    let ratios = NoteImageCrop.ratios(for: pixelSize)
    guard ratios.indices.contains(offset) else { return }
    ratio = ratios[offset].value
    ratioButton.selectItem(withTag: offset)
    if let ratio { crop = NoteImageCrop.fitted(ratio, around: crop, in: whole) }
    changed()
  }

  /// 换一个框（像素，原点左下；夹进整张图）
  func setCrop(_ rect: CGRect) {
    crop = rect.intersection(whole)
    changed()
  }

  private func changed() {
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
    let rect = NoteImageCrop.pixelRect(crop, imageSize: pixelSize)
    let size = rect?.size ?? pixelSize
    setAccessibilityValue("\(Int(size.width)) × \(Int(size.height)) 像素")
  }

  @objc private func ratioChosen(_ sender: NSPopUpButton) {
    choose(ratioAt: sender.selectedTag())
    window?.makeFirstResponder(self)
  }

  @objc func done(_ sender: Any?) {
    onDone(NoteImageCrop.pixelRect(crop, imageSize: pixelSize))
  }

  @objc func cancel(_ sender: Any?) { onCancel() }

  // MARK: 鼠标、键盘

  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    let point = pixels(convert(event.locationInWindow, from: nil))
    if let handle = handle(at: point) {
      drag = (handle, crop, point)
    } else if crop.contains(point) {
      drag = (nil, crop, point)
      NSCursor.closedHand.set()
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let drag else { return }
    let point = pixels(convert(event.locationInWindow, from: nil))
    if let handle = drag.handle {
      // 按下的地方离边差一点：边跟着鼠标走同样多，不往鼠标底下跳
      let edge = handle.point(in: drag.start)
      let target = CGPoint(
        x: point.x + edge.x - drag.down.x, y: point.y + edge.y - drag.down.y)
      crop = NoteImageCrop.resized(
        drag.start, current: crop, handle: handle, to: target, in: whole, ratio: ratio)
    } else {
      crop = RegionSelector.moved(
        drag.start, by: CGSize(width: point.x - drag.down.x, height: point.y - drag.down.y),
        within: whole)
    }
    changed()
  }

  override func mouseUp(with event: NSEvent) {
    drag = nil
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    let rect = cropRect
    addCursorRect(rect.insetBy(dx: Self.grabTolerance, dy: Self.grabTolerance), cursor: .openHand)
    for handle in RegionSelector.Handle.allCases {
      let center = handle.point(in: rect)
      let band = Self.grabTolerance
      let width = handle.movesMinX || handle.movesMaxX ? band * 2 : max(rect.width - band * 2, 0)
      let height = handle.movesMinY || handle.movesMaxY ? band * 2 : max(rect.height - band * 2, 0)
      addCursorRect(
        CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
        cursor: .frameResize(position: Self.position(of: handle), directions: .all))
    }
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

  override func keyDown(with event: NSEvent) {
    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
    switch Int(event.keyCode) {
    case 36, 76: done(nil)  // ↩、小键盘的 enter
    case 53: cancel(nil)
    case 123: nudge(dx: -step, dy: 0)
    case 124: nudge(dx: step, dy: 0)
    case 125: nudge(dx: 0, dy: -step)
    case 126: nudge(dx: 0, dy: step)
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { cancel(sender) }

  /// 键盘去了别处：下一轮看一眼（这一下 firstResponder 还没换好），不是自己、也不是自己的控件（全键盘操作时的
  /// 比例菜单、按钮）就当取消。已经被收起（不在视图树里）的不管
  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { perform(#selector(focusMoved), with: nil, afterDelay: 0) }
    return resigned
  }

  @objc private func focusMoved() {
    guard superview != nil, let window, !Self.holdsKeyboard(in: window) else { return }
    onCancel()
  }

  /// 这扇窗口的键盘在不在某个裁切层里（它自己或它的控件）：全部便签窗口的 ⌘Z / ⇧⌘Z / ⌘⌫ 这时什么都不动
  static func holdsKeyboard(in window: NSWindow) -> Bool {
    guard let view = window.firstResponder as? NSView else { return false }
    return sequence(first: view, next: \.superview).contains { $0 is NoteImageCropView }
  }

  // MARK: 跟着滚动区变大小

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    NotificationCenter.default.removeObserver(
      self, name: NSView.frameDidChangeNotification, object: nil)
    guard let superview else { return }
    frame = superview.bounds
    NotificationCenter.default.addObserver(
      self, selector: #selector(fitSuperview), name: NSView.frameDidChangeNotification,
      object: superview)
  }

  @objc private func fitSuperview() {
    if let superview { frame = superview.bounds }
  }

  /// 方向键：按点挪（不是按像素：大图上一下挪一个像素看不出来）
  private func nudge(dx: CGFloat, dy: CGFloat) {
    crop = RegionSelector.moved(
      crop, by: CGSize(width: dx / scale, height: dy / scale), within: whole)
    changed()
  }

  /// 滚轮吞掉（不然后面的正文跟着滚）
  override func scrollWheel(with event: NSEvent) {}

  // MARK: 画

  override func draw(_ dirtyRect: NSRect) {
    // 不透明：后面的正文、图一点都不透出来
    NSColor(white: 0.1, alpha: 1).setFill()
    bounds.fill()
    let image = imageRect
    let cropped = cropRect
    if let url,
      let thumbnail = NoteImageThumbnails.image(
        for: url, id: picture.id,
        maxPixel: NoteImageThumbnails.pixel(
          for: image.size, scale: window?.backingScaleFactor ?? 2),
        ready: { [weak self] in self?.needsDisplay = true })
    {
      NSImage(cgImage: thumbnail, size: image.size).draw(in: image)
    }
    // 框外压暗
    let outside = NSBezierPath(rect: image)
    outside.append(NSBezierPath(rect: cropped))
    outside.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.55).setFill()
    outside.fill()
    // 框：强调色 2 pt（同选中图片的描边），三分线细白
    let brand = NSColor(Style.brand)
    let thirds = NSBezierPath()
    for step in 1...2 {
      let x = cropped.minX + cropped.width * CGFloat(step) / 3
      let y = cropped.minY + cropped.height * CGFloat(step) / 3
      thirds.move(to: CGPoint(x: x, y: cropped.minY))
      thirds.line(to: CGPoint(x: x, y: cropped.maxY))
      thirds.move(to: CGPoint(x: cropped.minX, y: y))
      thirds.line(to: CGPoint(x: cropped.maxX, y: y))
    }
    thirds.lineWidth = 0.5
    NSColor.white.withAlphaComponent(0.35).setStroke()
    thirds.stroke()
    let border = NSBezierPath(rect: cropped.insetBy(dx: -1, dy: -1))
    border.lineWidth = 2
    brand.setStroke()
    border.stroke()
    // 把手：强调色的小方块、白边
    for handle in RegionSelector.Handle.allCases {
      let center = handle.point(in: cropped)
      let side = Self.handleSide
      let knob = NSBezierPath(
        roundedRect: CGRect(
          x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
        xRadius: 2, yRadius: 2)
      brand.setFill()
      knob.fill()
      knob.lineWidth = 1
      NSColor.white.setStroke()
      knob.stroke()
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    window?.invalidateCursorRects(for: self)
  }
}
