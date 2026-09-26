import AppKit
import Testing

@testable import KittyTools

// 截图遮罩（.capture）调整选区的交互复现：合成 mouseDown / mouseDragged / mouseUp，看 view.selection。
// 不弹遮罩、不抢键盘：视图放进屏外 (-20000, -20000)、从不 orderFront 的无边框 NSWindow——无边框窗口
// canBecomeKey 为 false，SelectionView.mouseDown 里的 window?.makeKey() 是空操作；也不走 window.sendEvent
// （避免 AppKit 的激活 / 按钮跟踪循环），而是按 AppKit 的规则自己路由：按下时对 contentView 做 hitTest，
// 命中 SelectionView 才发 mouseDown，之后的拖动 / 松手都发给按下时的那个视图。
// 会话没有遮罩（没调 start）：hasSelection(besides:) 恒为 false、activate 空操作，和单屏时一样。
// 期望值按 CleanShot X / 系统 ⌘⇧5 的习惯写：整条边都能拖。
@MainActor @Suite(.serialized)
struct SelectionInteractionTests {
  /// 一块 1200 × 800 的「屏幕」
  final class Harness {
    let window: NSWindow
    let view: SelectionView
    /// 按下时接住事件的视图（不是 SelectionView 就不发 mouseDown，免得进 NSButton 的跟踪循环）
    private var target: NSView?
    private(set) var intercepted: NSView?

    init(windows: [CGRect] = []) {
      let size = CGSize(width: 1200, height: 800)
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
      context.fill(CGRect(origin: .zero, size: size))
      view = SelectionView(
        image: context.makeImage()!, windows: windows,
        session: SelectionSession(mode: .capture))
      window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      view.frame = CGRect(origin: .zero, size: size)
    }

    deinit { MainActor.assumeIsolated { NSCursor.arrow.set() } }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func down(_ point: CGPoint) {
      let content = window.contentView!
      let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
      if hit === view {
        target = view
        intercepted = nil
        view.mouseDown(with: event(.leftMouseDown, point))
      } else {
        target = nil
        intercepted = hit
      }
    }

    /// 按下 → 分 4 步拖到 end → 松手
    func drag(_ start: CGPoint, _ end: CGPoint) {
      down(start)
      for step in 1...4 {
        let t = CGFloat(step) / 4
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        target?.mouseDragged(with: event(.leftMouseDragged, point))
      }
      target?.mouseUp(with: event(.leftMouseUp, end))
      target = nil
    }

    func click(_ point: CGPoint) {
      down(point)
      target?.mouseUp(with: event(.leftMouseUp, point))
      target = nil
    }

    /// 拖出选区 (300, 200, 400 × 300) 并进入调整
    func makeSelection() {
      drag(CGPoint(x: 300, y: 200), CGPoint(x: 700, y: 500))
    }

    var toolbar: NSView? { view.subviews.first { $0 is EditorToolbar } }
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
}
