import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

// 截图遮罩调整选区的交互复现：合成 mouseDown / mouseDragged / mouseUp（带修饰键）、按键、flagsChanged，看 view.selection。
// 不弹遮罩、不抢键盘：视图放进屏外 (-20000, -20000)、从不 orderFront 的无边框窗口——无边框窗口
// canBecomeKey 为 false，SelectionView.mouseDown 里的 window?.makeKey() 是空操作；isKeyWindow 假装是 true
// （⌘ + 键只在 key 窗口里处理），并不真的成为 key。也不走 window.sendEvent（避免 AppKit 的激活 / 按钮跟踪循环），
// 而是按 AppKit 的规则自己路由：按下时对 contentView 做 hitTest，命中 SelectionView（或尺寸胶囊）才发 mouseDown，
// 之后的拖动 / 松手都发给按下时的那个视图。
// 会话没有遮罩（没调 start）：hasSelection(besides:) 恒为 false、activate 空操作，和单屏时一样；要看交回的结果就直接
// 接上 session.continuation。
// 期望值按 CleanShot X / 系统 ⌘⇧5 的习惯写：整条边都能拖。
@MainActor @Suite(.serialized)
struct SelectionInteractionTests {
  /// 假装是 key 窗口，但从不 orderFront、不真的抢键盘
  final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
  }

  /// 一块 1200 × 800 的「屏幕」
  final class Harness {
    let window: NSWindow
    let view: SelectionView
    let session: SelectionSession
    /// 按下时接住事件的视图（不是 SelectionView / 尺寸胶囊就不发 mouseDown，免得进 NSButton 的跟踪循环）
    private var target: NSView?
    private(set) var intercepted: NSView?

    init(mode: SelectionView.Mode = .capture, windows: [CGRect] = []) {
      let size = CGSize(width: 1200, height: 800)
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
      context.fill(CGRect(origin: .zero, size: size))
      session = SelectionSession(mode: mode)
      view = SelectionView(image: context.makeImage()!, windows: windows, session: session)
      window = KeyWindow(
        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      view.frame = CGRect(origin: .zero, size: size)
    }

    deinit { MainActor.assumeIsolated { NSCursor.arrow.set() } }

    func event(
      _ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func down(_ point: CGPoint, flags: NSEvent.ModifierFlags = []) {
      let content = window.contentView!
      let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
      if let hit, hit === view || hit is SizeField {
        target = hit
        intercepted = nil
        hit.mouseDown(with: event(.leftMouseDown, point, flags))
      } else {
        target = nil
        intercepted = hit
      }
    }

    /// 按下 → 分 4 步拖到 end → 松手
    func drag(_ start: CGPoint, _ end: CGPoint, flags: NSEvent.ModifierFlags = []) {
      begin(start, to: end, flags: flags)
      release(end, flags: flags)
    }

    /// 按下 → 分 4 步拖到 end，不松手（看拖动中的状态）
    func begin(_ start: CGPoint, to end: CGPoint, flags: NSEvent.ModifierFlags = []) {
      down(start, flags: flags)
      for step in 1...4 {
        let t = CGFloat(step) / 4
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        target?.mouseDragged(with: event(.leftMouseDragged, point, flags))
      }
    }

    func release(_ end: CGPoint, flags: NSEvent.ModifierFlags = []) {
      target?.mouseUp(with: event(.leftMouseUp, end, flags))
      target = nil
    }

    /// 鼠标移到 point（不按下）
    func move(_ point: CGPoint) {
      view.mouseMoved(with: event(.mouseMoved, point))
    }

    private func keyEvent(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags)
      -> NSEvent
    {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
    }

    /// 按一下键（keyDown，⌥ 等修饰键可选）
    func key(_ code: Int, _ characters: String, flags: NSEvent.ModifierFlags = []) {
      view.keyDown(with: keyEvent(code, characters, flags))
    }

    /// 带 ⌘ 的键：AppKit 先走 performKeyEquivalent
    @discardableResult
    func keyEquivalent(_ code: Int, _ characters: String, flags: NSEvent.ModifierFlags) -> Bool {
      view.performKeyEquivalent(with: keyEvent(code, characters, flags))
    }

    /// 方向键：真实事件带 numericPad + function，字符是功能键私用区码位
    func arrow(_ code: Int, flags: NSEvent.ModifierFlags = []) {
      let scalar = [
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
      ][code]!
      let characters = String(Character(UnicodeScalar(UInt32(scalar))!))
      let flags = flags.union([.numericPad, .function])
      if flags.contains(.command) {
        keyEquivalent(code, characters, flags: flags)
      } else {
        key(code, characters, flags: flags)
      }
    }

    /// 按下 / 松开修饰键（拖动中也行）
    func modifiers(_ flags: NSEvent.ModifierFlags) {
      view.flagsChanged(
        with: NSEvent.keyEvent(
          with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: "",
          charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
    }

    func rightClick(_ point: CGPoint) {
      view.rightMouseDown(with: event(.rightMouseDown, point))
    }

    func click(_ point: CGPoint) {
      down(point)
      target?.mouseUp(with: event(.leftMouseUp, point))
      target = nil
    }

    /// 接上会话的结果，跑 actions；actions 里没交回结果时交一个占位，别把测试挂住
    func outcome(of actions: () -> Void) async -> RegionSelector.Outcome? {
      await withCheckedContinuation { continuation in
        session.continuation = continuation
        actions()
        session.continuation?.resume(returning: .color("没交回结果"))
        session.continuation = nil
      }
    }

    /// 窗口里的输入框编辑器（尺寸胶囊输入时是它在收键）
    var fieldEditor: NSTextView? { window.firstResponder as? NSTextView }

    /// 拖出选区 (300, 200, 400 × 300) 并进入调整
    func makeSelection() {
      drag(CGPoint(x: 300, y: 200), CGPoint(x: 700, y: 500))
    }

    var toolbar: EditorToolbar? { view.subviews.lazy.compactMap { $0 as? EditorToolbar }.first }
    var menu: HUDMenu? { view.subviews.lazy.compactMap { $0 as? HUDMenu }.first }
    var sizeField: SizeField? { view.subviews.lazy.compactMap { $0 as? SizeField }.first }

    /// 点尺寸胶囊：宽的数字 / 高的数字 / 比例按钮
    func clickSize(_ part: SizeField.Dimension?) {
      guard let field = sizeField else { return }
      let frame = field.frame
      let point =
        switch part {
        case .width?: CGPoint(x: frame.minX + 12, y: frame.midY)
        case .height?:
          CGPoint(x: field.convert(field.ratioFrame, to: view).minX - 14, y: frame.midY)
        case nil: CGPoint(x: field.convert(field.ratioFrame, to: view).midX, y: frame.midY)
        }
      click(point)
    }

    /// 点 HUD 菜单里的一项
    func pick(_ title: String) {
      let rows = menu?.effect.subviews ?? []
      _ = rows.first { $0.accessibilityLabel() == title }?.accessibilityPerformPress()
    }
  }

  static let initial = CGRect(x: 300, y: 200, width: 400, height: 300)

  // (a) 拖出选区，再拖右上角手柄
  @Test func a_cornerHandle() {
    let h = Harness()
    h.makeSelection()
    #expect(h.view.selection == Self.initial)
    #expect(h.view.isAdjusting)
    h.drag(CGPoint(x: 700, y: 500), CGPoint(x: 800, y: 600))
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 500, height: 400))
  }

  // (b) 正好按在上边中点手柄
  @Test func b_midEdgeHandle() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 500, y: 500), CGPoint(x: 500, y: 560))
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 400, height: 360))
  }

  // (c) 按在边上、离手柄远（1/4 处）：四条边各试一次
  @Test func c_edgeAwayFromHandle_top() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 400, y: 500), CGPoint(x: 400, y: 560))
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 400, height: 360))
    #expect(h.view.isAdjusting)
  }

  @Test func c_edgeAwayFromHandle_right() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 700, y: 275), CGPoint(x: 760, y: 275))
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 460, height: 300))
  }

  @Test func c_edgeAwayFromHandle_bottom() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 400, y: 200), CGPoint(x: 400, y: 150))
    #expect(h.view.selection == CGRect(x: 300, y: 150, width: 400, height: 350))
  }

  @Test func c_edgeAwayFromHandle_left() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 300, y: 275), CGPoint(x: 250, y: 275))
    #expect(h.view.selection == CGRect(x: 250, y: 200, width: 450, height: 300))
  }

  // (d) 从边外 4 pt 按下（上边 1/4 处）；以及边外 4 pt、正对中点手柄
  @Test func d_fourPointsOutsideEdge() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 400, y: 504), CGPoint(x: 400, y: 564))
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 400, height: 364))
  }

  @Test func d_fourPointsOutsideMidHandle() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 500, y: 504), CGPoint(x: 500, y: 564))
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 400, height: 364))
  }

  // (e) 选了标注工具（矩形）：拖角手柄；再拖下边 1/4 处
  @Test func e_cornerHandleWithTool() {
    let h = Harness()
    h.makeSelection()
    h.view.tool = .rectangle
    h.drag(CGPoint(x: 700, y: 500), CGPoint(x: 800, y: 600))
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 500, height: 400))
    #expect(h.view.annotations.isEmpty)
  }

  @Test func e_edgeWithTool() {
    let h = Harness()
    h.makeSelection()
    h.view.tool = .rectangle
    // 手拖边很少是正竖直的：横向偏 6 pt
    h.drag(CGPoint(x: 400, y: 200), CGPoint(x: 406, y: 150))
    #expect(h.view.selection == CGRect(x: 300, y: 150, width: 400, height: 350))
    #expect(h.view.annotations.isEmpty)
  }

  // 已有标注时拖上边：选区不该丢，标注也不该留在没有选区的屏上
  @Test func e_edgeDragKeepsSelectionWithAnnotations() {
    let h = Harness()
    h.makeSelection()
    h.view.tool = .rectangle
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    #expect(h.view.annotations.count == 1)
    h.drag(CGPoint(x: 400, y: 500), CGPoint(x: 400, y: 560))
    #expect(h.view.selection != nil)
    #expect(h.view.isAdjusting)
    #expect(h.view.selection != nil || h.view.annotations.isEmpty, "选区丢了但标注还留着")
  }

  // (f) 单击窗口得到选区后拖角；单击桌面截整屏后拖左上角
  @Test func f_windowClickThenCorner() {
    let h = Harness(windows: [CGRect(x: 100, y: 100, width: 600, height: 400)])
    h.click(CGPoint(x: 400, y: 300))
    #expect(h.view.selection == CGRect(x: 100, y: 100, width: 600, height: 400))
    #expect(h.view.isAdjusting)
    h.drag(CGPoint(x: 700, y: 100), CGPoint(x: 760, y: 60))
    #expect(h.view.selection == CGRect(x: 100, y: 60, width: 660, height: 440))
  }

  @Test func f_fullScreenClickThenCorner() {
    let h = Harness()
    h.click(CGPoint(x: 600, y: 400))
    #expect(h.view.selection == CGRect(x: 0, y: 0, width: 1200, height: 800))
    h.drag(CGPoint(x: 0, y: 800), CGPoint(x: 100, y: 700))
    #expect(h.view.selection == CGRect(x: 100, y: 0, width: 1100, height: 700))
  }

  // 整屏选区：屏幕边上（上边 1/4 处）往里拖
  @Test func f_fullScreenEdge() {
    let h = Harness()
    h.click(CGPoint(x: 600, y: 400))
    h.drag(CGPoint(x: 300, y: 800), CGPoint(x: 300, y: 700))
    #expect(h.view.selection == CGRect(x: 0, y: 0, width: 1200, height: 700))
  }

  // 调整时在选区外差几点按下、竖直拖出一个太小的框：算误触，恢复原来的选区
  @Test func tinyDragOutsideRestoresSelection() {
    let h = Harness()
    h.makeSelection()
    h.drag(CGPoint(x: 400, y: 540), CGPoint(x: 400, y: 600))
    #expect(h.view.selection == Self.initial)
    #expect(h.view.isAdjusting)
  }

  // 选着工具时 Esc 先收起工具，不直接结束截图
  @Test func escapeDropsToolFirst() {
    let h = Harness()
    h.makeSelection()
    h.view.tool = .rectangle
    let esc = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: h.window.windowNumber, context: nil, characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    h.view.keyDown(with: esc)
    #expect(h.view.tool == nil)
    #expect(h.view.selection == Self.initial)
  }

  // (g) 工具栏浮现后按右下角手柄（及手柄下方 7 pt，仍在容差内）
  @Test func g_cornerAfterToolbarAppears() throws {
    let h = Harness()
    h.makeSelection()
    RunLoop.main.run(until: Date.now.addingTimeInterval(0.2))
    let toolbar = try #require(h.toolbar)
    #expect(!toolbar.isHidden)
    h.drag(CGPoint(x: 700, y: 193), CGPoint(x: 760, y: 150))
    #expect(h.intercepted == nil, "被 \(String(describing: h.intercepted)) 截走，工具栏 \(toolbar.frame)")
    #expect(h.view.selection == CGRect(x: 300, y: 150, width: 460, height: 350))
  }

  // 工具栏：在选区下方 10 pt、水平居中；选区贴着屏幕底时翻到上方（D4）
  @Test func toolbarCenteredUnderSelectionFlipsAboveNearBottom() throws {
    let h = Harness()
    h.makeSelection()
    let toolbar = try #require(h.toolbar)
    #expect(toolbar.isShown)
    #expect(abs(toolbar.frame.midX - Self.initial.midX) <= 0.5)
    #expect(toolbar.frame.maxY == Self.initial.minY - 10)
    h.view.select(CGRect(x: 300, y: 20, width: 400, height: 300))
    #expect(abs(toolbar.frame.midX - 500) <= 0.5)
    #expect(toolbar.frame.minY == 330)
  }

  // 画标注时栏不动；只有拖动 / 缩放 / 平移选区时才淡出让位
  @Test func toolbarStaysVisibleWhileAnnotating() throws {
    let h = Harness()
    h.makeSelection()
    let toolbar = try #require(h.toolbar)
    h.view.tool = .rectangle
    h.begin(CGPoint(x: 350, y: 250), to: CGPoint(x: 450, y: 350))
    #expect(toolbar.isShown)
    h.release(CGPoint(x: 450, y: 350))
    #expect(toolbar.isShown)
    #expect(h.view.annotations.count == 1)
    h.view.tool = nil
    h.begin(CGPoint(x: 600, y: 450), to: CGPoint(x: 620, y: 460))
    #expect(!toolbar.isShown)
    h.release(CGPoint(x: 620, y: 460))
    #expect(toolbar.isShown)
    #expect(h.view.selection == Self.initial.offsetBy(dx: 20, dy: 10))
  }

  // 数字键 1–9、0 按栏里的顺序选工具，再按一次收起
  @Test func digitKeysChooseAndToggleTools() {
    let h = Harness()
    h.makeSelection()
    h.key(kVK_ANSI_5, "5")
    #expect(h.view.tool == .pen)
    h.key(kVK_ANSI_5, "5")
    #expect(h.view.tool == nil)
    h.key(kVK_ANSI_0, "0")
    #expect(h.view.tool == .spotlight)
  }

  // 保存 ▾ 弹 HUD 菜单（在栏下方）；Esc 先收菜单（工具还在），点外面也只收菜单
  @Test func saveCaretOpensHUDMenu() throws {
    let h = Harness()
    h.makeSelection()
    h.view.tool = .rectangle
    let toolbar = try #require(h.toolbar)
    try #require(toolbar.button(for: .saveMenu)).performClick(nil)
    let menu = try #require(h.menu)
    #expect(menu.frame.maxY <= toolbar.frame.minY)
    h.key(kVK_Escape, "\u{1b}")
    #expect(h.menu == nil)
    #expect(h.view.tool == .rectangle)
    try #require(toolbar.button(for: .saveMenu)).performClick(nil)
    #expect(h.menu != nil)
    h.click(CGPoint(x: 900, y: 700))
    #expect(h.menu == nil)
    #expect(h.view.selection == Self.initial)
    #expect(h.view.isAdjusting)
  }

  // 在选区里 / 边上按下还没拖开（比如点一下取消选中标注）：栏不闪；拖开了才淡出
  @Test func pressWithoutDragKeepsToolbar() throws {
    let h = Harness()
    h.makeSelection()
    let toolbar = try #require(h.toolbar)
    for point in [CGPoint(x: 500, y: 350), CGPoint(x: 700, y: 350)] {
      h.down(point)
      #expect(toolbar.isShown, "\(point)")
      h.release(point)
      #expect(toolbar.isShown)
    }
    #expect(h.view.selection == Self.initial)
  }

  // 进场时光标就在窗口上：洞和粉框从光标处的零尺寸占位长出来，不从屏幕左下角 (0, 0) 飞过来
  @Test func hoverMorphStartsAtCursor() {
    let h = Harness(windows: [CGRect(x: 100, y: 100, width: 400, height: 300)])
    let cursor = CGPoint(x: 300, y: 250)
    h.view.mouse = cursor
    let starts = h.view.subviews.compactMap(\.layer).flatMap { $0.sublayers ?? [] }
      .compactMap { $0.animation(forKey: "morph") as? CABasicAnimation }
      .map { ($0.fromValue as! CGPath).boundingBoxOfPath }
    if Style.reduceMotion { return #expect(starts.isEmpty) }
    #expect(starts.count == 2)
    #expect(starts.contains(CGRect(origin: cursor, size: .zero)), "\(starts)")
    #expect(!starts.contains(.zero), "\(starts)")
  }

  // 悬停在边上：那条边（角）是「热」的，对应手柄放大、边加粗
  @Test func hoveringEdgeMarksHandleHot() {
    let h = Harness()
    h.makeSelection()
    h.move(CGPoint(x: 400, y: 502))
    #expect(h.view.hotHandle == .top)
    h.move(CGPoint(x: 703, y: 198))
    #expect(h.view.hotHandle == .bottomRight)
    h.move(CGPoint(x: 500, y: 350))
    #expect(h.view.hotHandle == nil)
  }

  // ⇧ 框选：正方形；拖动中按下 / 松开 ⇧ 立刻重算
  @Test func shiftDrawsSquareAndReactsMidDrag() {
    let h = Harness()
    h.drag(CGPoint(x: 300, y: 200), CGPoint(x: 500, y: 260), flags: .shift)
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 200, height: 200))
    let other = Harness()
    other.begin(CGPoint(x: 300, y: 200), to: CGPoint(x: 500, y: 260))
    #expect(other.view.selection == CGRect(x: 300, y: 200, width: 200, height: 60))
    other.modifiers(.shift)
    #expect(other.view.selection == CGRect(x: 300, y: 200, width: 200, height: 200))
    other.modifiers([])
    #expect(other.view.selection == CGRect(x: 300, y: 200, width: 200, height: 60))
    other.release(CGPoint(x: 500, y: 260))
    #expect(other.view.isAdjusting)
  }

  // ⌥ 框选：按下的点是中心
  @Test func optionDrawsFromCenter() {
    let h = Harness()
    h.drag(CGPoint(x: 500, y: 400), CGPoint(x: 600, y: 450), flags: .option)
    #expect(h.view.selection == CGRect(x: 400, y: 350, width: 200, height: 100))
  }

  // 6 pt 内吸到冻结时的窗口边（拖动时画参考线、松手清掉）；⌃ 暂停吸附；拖边也吸屏幕边
  @Test func snapsToWindowEdgesUnlessControl() {
    let windows = [CGRect(x: 100, y: 100, width: 600, height: 400)]
    let h = Harness(windows: windows)
    h.begin(CGPoint(x: 150, y: 150), to: CGPoint(x: 704, y: 450))
    #expect(h.view.selection == CGRect(x: 150, y: 150, width: 550, height: 300))
    #expect(h.view.guides.x == 700)
    #expect(h.view.guides.y == nil)
    h.release(CGPoint(x: 704, y: 450))
    #expect(h.view.guides.x == nil)
    #expect(h.view.selection == CGRect(x: 150, y: 150, width: 550, height: 300))
    // 上边拖到离屏幕顶 4 pt：吸到顶
    h.begin(CGPoint(x: 400, y: 450), to: CGPoint(x: 400, y: 796))
    #expect(h.view.guides.y == 800)
    h.release(CGPoint(x: 400, y: 796))
    #expect(h.view.selection == CGRect(x: 150, y: 150, width: 550, height: 650))

    let free = Harness(windows: windows)
    free.begin(CGPoint(x: 150, y: 150), to: CGPoint(x: 704, y: 450), flags: .control)
    #expect(free.view.guides.x == nil)
    free.release(CGPoint(x: 704, y: 450), flags: .control)
    #expect(free.view.selection == CGRect(x: 150, y: 150, width: 554, height: 300))
  }

  // ⌘ + 方向键推外、⌥ + 方向键收里（↑ 是上边），⇧ 10 点；普通方向键仍是平移
  @Test func commandAndOptionArrowsPushAndPullEdges() {
    let h = Harness()
    h.makeSelection()
    h.arrow(kVK_RightArrow, flags: .command)
    #expect(h.view.selection == CGRect(x: 300, y: 200, width: 401, height: 300))
    h.arrow(kVK_LeftArrow, flags: .option)
    #expect(h.view.selection == CGRect(x: 301, y: 200, width: 400, height: 300))
    h.arrow(kVK_UpArrow, flags: .command)
    #expect(h.view.selection == CGRect(x: 301, y: 200, width: 400, height: 301))
    h.arrow(kVK_RightArrow, flags: [.command, .shift])
    #expect(h.view.selection == CGRect(x: 301, y: 200, width: 410, height: 301))
    h.arrow(kVK_DownArrow, flags: .option)
    #expect(h.view.selection == CGRect(x: 301, y: 201, width: 410, height: 300))
    h.arrow(kVK_RightArrow)
    #expect(h.view.selection == CGRect(x: 302, y: 201, width: 410, height: 300))
  }

  // 尺寸胶囊：点宽 → 输入像素、Tab 到高、↩ 生效；左上角不动，键盘还给遮罩
  @Test func sizeFieldAppliesTypedPixelsKeepingTopLeft() throws {
    let h = Harness()
    h.makeSelection()
    let field = try #require(h.sizeField)
    #expect(field.isInteractive)
    h.clickSize(.width)
    #expect(field.isEditing)
    let editor = try #require(h.fieldEditor)
    editor.selectAll(nil)
    editor.insertText("640", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
    let height = try #require(h.fieldEditor)
    height.selectAll(nil)
    height.insertText("480", replacementRange: NSRange(location: NSNotFound, length: 0))
    height.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(!field.isEditing)
    #expect(h.window.firstResponder === h.view)
    #expect(h.view.selection == CGRect(x: 300, y: 20, width: 640, height: 480))
    // 再点高、改完点别处：也提交
    h.clickSize(.height)
    let again = try #require(h.fieldEditor)
    again.selectAll(nil)
    again.insertText("400", replacementRange: NSRange(location: NSNotFound, length: 0))
    h.click(CGPoint(x: 1100, y: 700))
    #expect(!field.isEditing)
    #expect(h.window.firstResponder === h.view)
    #expect(h.view.selection == CGRect(x: 300, y: 100, width: 640, height: 400))
  }

  // 比例菜单选 16:9：立刻套用（顶边、水平中心不动）并锁住，之后拖角保持 16:9；选区一动开着的菜单就收起
  @Test func lockedRatioAppliesAndConstrainsResize() throws {
    let h = Harness()
    h.makeSelection()
    h.clickSize(nil)
    #expect(h.menu != nil)
    h.arrow(kVK_RightArrow)
    #expect(h.menu == nil, "方向键挪了选区，菜单该收起")
    h.arrow(kVK_LeftArrow)
    h.clickSize(nil)
    h.pick("16:9")
    #expect(h.menu == nil)
    #expect(h.session.lockedRatio == 16.0 / 9)
    #expect(h.view.selection == CGRect(x: 300, y: 275, width: 400, height: 225))
    h.drag(CGPoint(x: 700, y: 500), CGPoint(x: 800, y: 600))
    let selection = try #require(h.view.selection)
    #expect(selection.origin == CGPoint(x: 300, y: 275))
    #expect(abs(selection.width / selection.height - 16.0 / 9) < 1e-6)
    #expect(selection.height == 325)
    // 自由：解锁
    h.clickSize(nil)
    h.pick("自由")
    #expect(h.session.lockedRatio == nil)
  }

  // 右键：有标注时不清空（选区、标注都在）；没有标注时回到待选
  @Test func rightClickKeepsAnnotations() {
    let h = Harness()
    h.makeSelection()
    h.view.tool = .rectangle
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    #expect(h.view.annotations.count == 1)
    h.rightClick(CGPoint(x: 500, y: 350))
    #expect(h.view.annotations.count == 1)
    #expect(h.view.selection == Self.initial)
    #expect(h.view.isAdjusting)
    let empty = Harness()
    empty.makeSelection()
    empty.rightClick(CGPoint(x: 500, y: 350))
    #expect(empty.view.selection == nil)
    #expect(!empty.view.isAdjusting)
  }

  // Esc 依次：HUD 菜单 → 尺寸输入（放弃输入的数）→ 选中的标注 → 工具 → 取消截图
  @Test func escapeOrder() async throws {
    let h = Harness()
    h.makeSelection()
    h.view.tool = .rectangle
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    let annotation = try #require(h.view.annotations.first)
    h.view.selectedAnnotation = annotation.id
    h.clickSize(nil)
    #expect(h.menu != nil)
    h.key(kVK_Escape, "\u{1b}")
    #expect(h.menu == nil)
    #expect(h.view.selectedAnnotation == annotation.id)
    h.clickSize(.width)
    let editor = try #require(h.fieldEditor)
    editor.selectAll(nil)
    editor.insertText("999", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(h.sizeField?.isEditing == false)
    #expect(h.window.firstResponder === h.view)
    #expect(h.view.selection == Self.initial)
    #expect(h.view.selectedAnnotation == annotation.id)
    h.key(kVK_Escape, "\u{1b}")
    #expect(h.view.selectedAnnotation == nil)
    #expect(h.view.tool == .rectangle)
    h.key(kVK_Escape, "\u{1b}")
    #expect(h.view.tool == nil)
    #expect(h.view.annotations.count == 1)
    let outcome = await h.outcome { h.key(kVK_Escape, "\u{1b}") }
    #expect(outcome == nil)
  }

  // 截图翻译 / 识字：待选和框选时有放大镜、尺寸只读，⇧ 照样正方形，松手即确认（交回裁好的图）
  @Test func quickModeMagnifierAndReleaseConfirms() async throws {
    let h = Harness(mode: .quick)
    h.move(CGPoint(x: 300, y: 300))
    #expect(h.view.showsMagnifier)
    let outcome = await h.outcome {
      h.begin(CGPoint(x: 300, y: 200), to: CGPoint(x: 500, y: 260), flags: .shift)
      #expect(h.view.showsMagnifier)
      #expect(h.view.selection == CGRect(x: 300, y: 200, width: 200, height: 200))
      #expect(h.sizeField?.isHidden == false)
      #expect(h.sizeField?.isInteractive == false)
      h.release(CGPoint(x: 500, y: 260), flags: .shift)
    }
    guard case .capture(let capture)? = outcome else {
      Issue.record("松手没有交回截图：\(String(describing: outcome))")
      return
    }
    #expect(capture.image.width == 200)
    #expect(capture.image.height == 200)
    #expect(!h.view.isAdjusting)
  }

  // 锁着比例时 ⇧ 也按锁着的比例：框选不变正方形，拖角不按原选区的比例
  @Test func lockedRatioWinsOverShift() throws {
    let h = Harness()
    h.session.lockedRatio = 16.0 / 9
    h.drag(CGPoint(x: 100, y: 100), CGPoint(x: 420, y: 150), flags: .shift)
    #expect(h.view.selection == CGRect(x: 100, y: 100, width: 320, height: 180))
    let free = Harness()
    free.makeSelection()
    free.session.lockedRatio = 16.0 / 9
    free.drag(CGPoint(x: 700, y: 500), CGPoint(x: 800, y: 520), flags: .shift)
    let resized = try #require(free.view.selection)
    #expect(abs(resized.width / resized.height - 16.0 / 9) < 1e-6, "\(resized)")
  }

  // 正在输入、还没收下的文字也算标注：右键不清空，输入框还在
  @Test func rightClickKeepsTypedText() throws {
    let h = Harness()
    h.makeSelection()
    h.view.beginEditing(at: CGPoint(x: 400, y: 400))
    let field = try #require(h.fieldEditor)
    field.insertText("hi", replacementRange: NSRange(location: NSNotFound, length: 0))
    h.rightClick(CGPoint(x: 500, y: 350))
    #expect(h.view.selection == Self.initial)
    #expect(h.window.firstResponder === field)
  }

  // 尺寸输入框里右键不弹文本菜单（菜单层级比遮罩低，会压在下面）
  @Test func sizeFieldEditorHasNoContextMenu() throws {
    let h = Harness()
    h.makeSelection()
    h.clickSize(.width)
    let editor = try #require(h.fieldEditor)
    let point = editor.convert(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: nil)
    #expect(editor.menu(for: h.event(.rightMouseDown, point)) == nil)
  }
}
