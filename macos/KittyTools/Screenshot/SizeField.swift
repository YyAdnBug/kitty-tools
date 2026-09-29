// 截图遮罩里的尺寸胶囊 SizeField（mac-whisker §6 截图「尺寸胶囊」）：HUD 皮肤（圆角 control 6 + 阴影），SF Mono 12 semibold
// 的像素宽高，中间「×」次文字色。悬停窗口、框选时只读、不接事件；调整选区时点数字就地变成两个输入框（Tab / ⇧Tab 切宽高、
// ↩ 生效、Esc 放弃、点别处提交；焦点环 1 pt 粉 0.75 + 粉 0.22 r3 外发光），右边比例按钮「自由 ▾」（锁住时粉底）弹 HUD 菜单。
// 状态和几何归 SelectionView：这里只显示、收点击、把 ↩ / Esc / Tab 交出去。输入框当第一响应者时按键归它；收下时
// SelectionView 先把第一响应者要回去、再调 endEditing（同文字标注的 EditorField，反过来单键快捷键全失灵）。
// 旁白：宽、高两个数字各有名字（按下 = 点数字开始输入），比例按钮是按钮（按下弹菜单），「×」不读。
// macOS 26 起底是深色液态玻璃（mac-whisker §2「26 分支」）：零件都放进玻璃的 contentView，不画 HUD 皮肤和阴影。

import AppKit

final class SizeField: NSView, NSTextFieldDelegate {
  enum Dimension { case width, height }

  /// 点了宽 / 高的数字（调整时）：SelectionView 收掉别的输入再调 beginEditing
  var onEdit: (Dimension) -> Void = { _ in }
  /// ↩：按输入的像素改选区
  var onCommit: () -> Void = {}
  /// Esc：交给 SelectionView 按 Esc 的顺序处理（先收 HUD 菜单）
  var onCancel: () -> Void = {}
  /// 点了比例按钮
  var onRatio: () -> Void = {}

  /// 调整选区时：数字能点、有比例按钮
  private(set) var isInteractive = false
  private(set) var isEditing = false
  private let widthField = NumberField()
  private let heightField = NumberField()
  private let times = NSTextField(labelWithString: "×")
  private let chip = RatioChip()
  private let chipLabel = NSTextField(labelWithString: "")
  private let ring = CALayer()
  /// macOS 26：深色液态玻璃的 contentView，零件和焦点环都在它里面（和自己一样大，坐标相同）；15 是 nil，零件直接放在
  /// 自己上、HUD 皮肤画在自己的图层上
  private let glassContent: NSView?
  private var surface: NSView { glassContent ?? self }
  /// 上次显示的：像素宽高、比例按钮文字、是否锁住（没变就不重排，遮罩每次鼠标移动都会调 show）
  private var shown: (width: Int, height: Int, ratio: String, locked: Bool)?

  private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
  private static let height: CGFloat = 26

  init() {
    var glass: NSView?
    if #available(macOS 26, *) {
      // 圆角交给玻璃；两个无障碍开关交给玻璃（mac-whisker §7）
      let effect = NSGlassEffectView()
      effect.cornerRadius = Style.Radius.control
      effect.autoresizingMask = [.width, .height]
      let content = NSView()
      content.wantsLayer = true  // 焦点环是加在它图层上的子图层
      content.autoresizingMask = [.width, .height]  // 玻璃按 Auto Layout 撑满它；掩码和那组约束一致
      effect.contentView = content
      glassContent = content
      glass = effect
    } else {
      glassContent = nil
    }
    super.init(frame: .zero)
    wantsLayer = true
    // 输入框的光标、选中底色按深色取（HUD 永远深色）；26 的玻璃也跟着它是深色
    appearance = NSAppearance(named: .darkAqua)
    if let glass {
      addSubview(glass)
    } else if let layer {
      Style.HUD.applySkin(to: layer, radius: Style.Radius.control)
    }
    for field in [widthField, heightField] {
      field.font = Self.font
      field.textColor = Style.HUD.text
      field.alignment = .center
      field.delegate = self
      field.onFocus = { [unowned self, unowned field] in placeRing(on: field) }
      field.onPress = { [unowned self, unowned field] in
        if isInteractive, !isEditing { onEdit(field === widthField ? .width : .height) }
      }
      surface.addSubview(field)
    }
    widthField.setAccessibilityLabel("宽（像素）")
    heightField.setAccessibilityLabel("高（像素）")
    times.font = Self.font
    times.textColor = Style.HUD.secondaryText
    times.setAccessibilityElement(false)
    surface.addSubview(times)
    chip.onPress = { [unowned self] in onRatio() }
    chipLabel.setAccessibilityElement(false)
    chip.wantsLayer = true
    chip.layer?.cornerRadius = Style.Radius.mini
    chip.layer?.cornerCurve = .continuous
    chipLabel.font = .systemFont(ofSize: 11, weight: .medium)
    chip.addSubview(chipLabel)
    surface.addSubview(chip)
    let pink = Style.Shot.accent
    ring.borderWidth = 1
    ring.borderColor = pink.withAlphaComponent(0.75).cgColor
    ring.cornerRadius = 3
    ring.shadowColor = pink.cgColor
    ring.shadowOpacity = 0.22
    ring.shadowRadius = 3
    ring.shadowOffset = .zero
    ring.isHidden = true
    ring.zPosition = 1
    surface.layer?.addSublayer(ring)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 显示像素宽高；interactive = 调整选区时（数字能点、出比例按钮）。输入中不跟着变
  func show(width: Int, height: Int, interactive: Bool, ratio: String, locked: Bool) {
    guard !isEditing else { return }
    let next = (width, height, interactive ? ratio : "", interactive && locked)
    if let shown, shown == next, isInteractive == interactive { return }
    shown = next
    isInteractive = interactive
    widthField.stringValue = "\(width)"
    heightField.stringValue = "\(height)"
    chip.isHidden = !interactive
    chip.layer?.backgroundColor =
      (next.3 ? Style.Shot.accent.withAlphaComponent(0.9) : Style.HUD.chipFill).cgColor
    chipLabel.stringValue = "\(ratio) ▾"
    chipLabel.textColor = next.3 ? Style.Shot.onAccent : Style.HUD.text
    chip.setAccessibilityLabel("比例：\(ratio)")
    layoutParts()
  }

  /// 比例按钮（自身坐标）：HUD 菜单锚在它下面
  var ratioFrame: CGRect { chip.frame }

  /// 两个数都变成输入框，which 那个拿到键盘（全选）
  func beginEditing(_ which: Dimension) {
    if !isEditing {
      guard isInteractive else { return }
      isEditing = true
      for field in [widthField, heightField] {
        field.isEditable = true
        field.isSelectable = true
      }
      chip.isHidden = true
      layoutParts()
    }
    window?.makeFirstResponder(which == .width ? widthField : heightField)
  }

  /// 输入的像素宽高；和原来一样就是 nil。解析不了（空、非数字、≤ 0）的那个用原值
  var typedPixels: CGSize? {
    guard let shown else { return nil }
    func parse(_ field: NSTextField, _ fallback: Int) -> Int {
      Int(field.stringValue.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        ?? fallback
    }
    let width = parse(widthField, shown.width)
    let height = parse(heightField, shown.height)
    guard width != shown.width || height != shown.height else { return nil }
    return CGSize(width: width, height: height)
  }

  /// 变回只读的数字。调用方先把第一响应者要回去（见文件头）
  func endEditing() {
    guard isEditing else { return }
    isEditing = false
    for field in [widthField, heightField] {
      field.isEditable = false
      field.isSelectable = false
    }
    ring.isHidden = true
    shown = nil  // 下一次 show 换回真实的数、重排
  }

  // MARK: 布局

  /// 左右内边距 8（比例按钮四周 4）；输入时每个框至少放得下 5 位数
  private func layoutParts() {
    var x: CGFloat = 8
    let digits = ceil(
      NSAttributedString(string: "00000", attributes: [.font: Self.font]).size().width)
    for part in [widthField, times, heightField] {
      var size = part.fittingSize
      if isEditing, part !== times { size.width = max(size.width, digits + 4) + 6 }
      part.frame = CGRect(
        x: x, y: ((Self.height - size.height) / 2).rounded(), width: ceil(size.width),
        height: ceil(size.height))
      x = part.frame.maxX + 2
    }
    var width = heightField.frame.maxX + 8
    if !chip.isHidden {
      let label = chipLabel.fittingSize
      chip.frame = CGRect(
        x: heightField.frame.maxX + 6, y: 4, width: ceil(label.width) + 10, height: Self.height - 8)
      chipLabel.frame = CGRect(
        x: 5, y: ((chip.frame.height - label.height) / 2).rounded(), width: ceil(label.width),
        height: ceil(label.height))
      width = chip.frame.maxX + 4
    }
    setFrameSize(CGSize(width: width, height: Self.height))
    if glassContent == nil, let layer {
      Style.HUD.applySkin(to: layer, radius: Style.Radius.control)  // 外圈描边跟着新宽度
      Style.HUD.applyShadow(
        to: layer,
        path: CGPath(
          roundedRect: bounds, cornerWidth: Style.Radius.control,
          cornerHeight: Style.Radius.control, transform: nil))
    }
    if isEditing, let focused = window?.firstResponder as? NSText,
      let field = focused.delegate as? NSTextField
    {
      placeRing(on: field)
    }
  }

  /// 焦点环跟着拿到键盘的那个框（Tab 切换、鼠标点另一个都会走 becomeFirstResponder）
  private func placeRing(on field: NSTextField) {
    guard isEditing else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let frame = field.frame.insetBy(dx: -1, dy: -2)
    ring.frame = frame
    ring.shadowPath = CGPath(
      roundedRect: CGRect(origin: .zero, size: frame.size), cornerWidth: 3, cornerHeight: 3,
      transform: nil
    ).copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .round, miterLimit: 1)
    ring.isHidden = false
    CATransaction.commit()
  }

  // MARK: 事件

  /// 只读时不接事件（点下去的是遮罩：悬停窗口的单击、框选）；调整时整块接住，输入中交给输入框
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isInteractive, !isHidden else { return nil }
    if isEditing { return super.hitTest(point) }
    return frame.contains(point) ? self : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// 左半边改宽、右半边改高，比例按钮（外扩 3 pt）弹菜单
  override func mouseDown(with event: NSEvent) {
    guard !isEditing else { return }
    let point = convert(event.locationInWindow, from: nil)
    if !chip.isHidden, point.x >= chip.frame.minX - 3 { return onRatio() }
    onEdit(point.x < times.frame.midX ? .width : .height)
  }

  /// 拖动、松手不顺着响应链漏给遮罩
  override func mouseDragged(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)): onCommit()
    case #selector(NSResponder.cancelOperation(_:)): onCancel()
    case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
      beginEditing(control === widthField ? .height : .width)
    default: return false
    }
    return true
  }
}

/// 比例按钮（画面是圆角底 + 文字标签，点击由胶囊的 mouseDown 按位置分）：旁白里是个按钮，按下弹比例菜单
private final class RatioChip: NSView {
  var onPress: () -> Void = {}

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityPerformPress() -> Bool {
    onPress()
    return true
  }
}

/// 数字框：平时是只读的标签，输入时可编辑；拿到键盘时通知胶囊挪焦点环。不画系统焦点环。
/// 旁白按下（只读时）= 点了这个数字
private final class NumberField: NSTextField {
  var onFocus: () -> Void = {}
  var onPress: () -> Void = {}

  override init(frame: NSRect) {
    super.init(frame: frame)
    isBezeled = false
    isBordered = false
    drawsBackground = false
    isEditable = false
    isSelectable = false
    focusRingType = .none
    usesSingleLineMode = true
    lineBreakMode = .byClipping
    cell?.isScrollable = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    guard became else { return false }
    // 选中底色、光标用品牌粉（截图家族不用系统强调色，14 起光标默认跟随它）；字段编辑器是窗口共用的，每次拿到键盘都设一遍
    let editor = currentEditor() as? NSTextView
    editor?.selectedTextAttributes = [.backgroundColor: Style.Shot.accent.withAlphaComponent(0.4)]
    editor?.insertionPointColor = Style.Shot.accent
    onFocus()
    return true
  }

  override func accessibilityPerformPress() -> Bool {
    onPress()
    return true
  }

  /// 输入时右键不弹文本菜单：菜单层级比遮罩低，会压在下面看不见、还占着下一次点击（同文字标注的 EditorField）。
  /// 字段编辑器的代理是正在编辑的这个框，它问代理要菜单时给 nil
  @objc(textView:menu:forEvent:atIndex:)
  func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu?
  {
    nil
  }
}
