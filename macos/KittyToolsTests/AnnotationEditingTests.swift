// 截图标注编辑的交互（Whisker §6「标注编辑」）：单击放序号、画笔累点、画完自动选中、拖手柄改大小（⇧ 约束，拖到看不出来就恢复）、
// ⌥ 拖动复制、⇧ 锁轴、⌘D、撤销 / 重做、⌫ 删除、标注手柄比选区边优先、双击文字重新编辑 / 双击空白拷贝、文字三种样式在输入框里所见即所得、
// 箭头、直线的弯曲手柄（两种走同一套：拖弯、⇧ 对称、吸回直的、双击拉直，双击没选中的弯的不拉直）、按在手柄边上拖不跳、
// 短的拖到头弯曲手柄还在，弯度跟着改两端 / 方向键 / ⌘D / ⌥ 拖动走。
// 用 SelectionInteractionTests 的屏外窗口 + 合成事件（不弹遮罩、不抢键盘）；选区都是 (300, 200, 400 × 300)。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor @Suite(.serialized)
struct AnnotationEditingTests {
  typealias Harness = SelectionInteractionTests.Harness

  /// 拖出选区、选上工具（直接设，不读写记住的样式）
  private func harness(tool: Annotation.Tool?) -> Harness {
    let h = Harness()
    h.makeSelection()
    h.view.tool = tool
    return h
  }

  private func annotation(_ h: Harness, _ id: UUID?) -> Annotation? {
    h.view.annotations.first { $0.id == id }
  }

  @Test func counterClicksPlaceNumbersAndSelectTheNewOne() {
    let h = harness(tool: .counter)
    h.click(CGPoint(x: 400, y: 300))
    h.click(CGPoint(x: 500, y: 300))
    #expect(
      h.view.annotations.map(\.shape) == [
        .counter(1, center: CGPoint(x: 400, y: 300)), .counter(2, center: CGPoint(x: 500, y: 300)),
      ])
    #expect(h.view.selectedAnnotation == h.view.annotations.last?.id)
    #expect(h.view.tool == .counter)
    // 点在已有的序号上是选中它，不再放一个
    h.click(CGPoint(x: 400, y: 300))
    #expect(h.view.annotations.count == 2)
    #expect(h.view.selectedAnnotation == h.view.annotations.first?.id)
    // 放一个算一步撤销
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.count == 1)
  }

  @Test func penDragAccumulatesPointsAndSelects() throws {
    let h = harness(tool: .pen)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 330))
    let pen = try #require(h.view.annotations.first)
    guard case .pen(let points) = pen.shape else {
      Issue.record("\(pen.shape)")
      return
    }
    #expect(points.count > 2)
    #expect(points.first == CGPoint(x: 350, y: 250) && points.last == CGPoint(x: 450, y: 330))
    #expect(h.view.selectedAnnotation == pen.id)
    #expect(h.view.tool == .pen)
  }

  @Test func drawingSelectsTheNewAnnotationAndKeepsTheTool() {
    let h = harness(tool: .ellipse)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    #expect(
      h.view.annotations.map(\.shape) == [.ellipse(CGRect(x: 350, y: 250, width: 100, height: 100))]
    )
    #expect(h.view.selectedAnnotation == h.view.annotations.first?.id)
    #expect(h.view.tool == .ellipse)
    // 接着在空白处画第二个：前一个取消选中、选中新的
    h.drag(CGPoint(x: 500, y: 250), CGPoint(x: 560, y: 300))
    #expect(h.view.annotations.count == 2)
    #expect(h.view.selectedAnnotation == h.view.annotations.last?.id)
  }

  @Test func rectangleCornerHandleResizesThenUndoRedo() {
    let h = harness(tool: .rectangle)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    let id = h.view.selectedAnnotation
    // 右上角手柄（差 5 点也算按上）拖到 (480, 380)：左下角不动
    h.drag(CGPoint(x: 454, y: 347), CGPoint(x: 480, y: 380))
    let resized = CGRect(x: 350, y: 250, width: 130, height: 130)
    #expect(annotation(h, id)?.shape == .rectangle(resized))
    #expect(h.view.annotations.count == 1)
    #expect(h.view.selection == SelectionInteractionTests.initial)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(annotation(h, id)?.shape == .rectangle(CGRect(x: 350, y: 250, width: 100, height: 100)))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: [.command, .shift])
    #expect(annotation(h, id)?.shape == .rectangle(resized))
    // 按在手柄上没拖开：不记撤销
    h.click(CGPoint(x: 480, y: 380))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(annotation(h, id)?.shape == .rectangle(CGRect(x: 350, y: 250, width: 100, height: 100)))
  }

  // 边中点的手柄只动那条边；⌥ 画 / 拖手柄以中心为准（2026-11-12 拍板 B1 B3）
  @Test func edgeHandleAndOptionFromCenter() {
    let h = harness(tool: .rectangle)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    let id = h.view.selectedAnnotation
    // 右边中点 (450, 300) 拖到 (500, 330)：只变宽
    h.drag(CGPoint(x: 451, y: 302), CGPoint(x: 500, y: 330))
    #expect(annotation(h, id)?.shape == .rectangle(CGRect(x: 350, y: 250, width: 150, height: 100)))
    // ⌥ 拖上边中点 (425, 350) 到 (425, 370)：上下各长 20
    h.begin(CGPoint(x: 425, y: 350), to: CGPoint(x: 425, y: 370), flags: .option)
    h.release(CGPoint(x: 425, y: 370), flags: .option)
    #expect(annotation(h, id)?.shape == .rectangle(CGRect(x: 350, y: 230, width: 150, height: 140)))
    // ⌥ 画椭圆：按下的点是中心
    h.view.tool = .ellipse
    h.begin(CGPoint(x: 600, y: 300), to: CGPoint(x: 640, y: 320), flags: .option)
    h.release(CGPoint(x: 640, y: 320), flags: .option)
    #expect(
      h.view.annotations.last?.shape == .ellipse(CGRect(x: 560, y: 280, width: 80, height: 40)))
  }

  @Test func collapsingByAHandleRestoresTheAnnotation() {
    let h = harness(tool: .rectangle)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    let id = h.view.selectedAnnotation
    // 右上角拖到左下角上：看不出来了，恢复原样、不记撤销
    h.drag(CGPoint(x: 450, y: 350), CGPoint(x: 350, y: 250))
    #expect(annotation(h, id)?.shape == .rectangle(CGRect(x: 350, y: 250, width: 100, height: 100)))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.isEmpty)
  }

  @Test func lineEndpointResizeSnapsTo45WithShift() throws {
    let h = harness(tool: .line)
    h.drag(CGPoint(x: 350, y: 300), CGPoint(x: 450, y: 300))
    let id = h.view.selectedAnnotation
    h.drag(CGPoint(x: 450, y: 300), CGPoint(x: 480, y: 400), flags: .shift)
    guard case .line(let from, let to, _)? = annotation(h, id)?.shape else {
      Issue.record("\(String(describing: annotation(h, id)))")
      return
    }
    #expect(from == CGPoint(x: 350, y: 300))
    #expect(abs((to.x - from.x) - (to.y - from.y)) < 0.001)
    #expect(abs(hypot(to.x - from.x, to.y - from.y) - hypot(130, 100)) < 0.001)
  }

  /// 箭头 / 直线的弧线中点（弯曲手柄的位置）
  private func midpoint(_ h: Harness, _ id: UUID?) -> CGPoint? {
    guard let (from, to, bend) = annotation(h, id)?.shape.curve else { return nil }
    return Annotation.curveMidpoint(from: from, to: to, bend: bend)
  }

  private func near(_ a: CGPoint?, _ b: CGPoint) -> Bool {
    a.map { hypot($0.x - b.x, $0.y - b.y) < 1e-9 } ?? false
  }

  @Test(arguments: [Annotation.Tool.arrow, .line])
  func midpointHandleBendsSnapsAndDoubleClickStraightens(_ tool: Annotation.Tool) {
    let h = harness(tool: tool)
    h.drag(CGPoint(x: 350, y: 300), CGPoint(x: 450, y: 300))
    let id = h.view.selectedAnnotation
    let straight = Annotation.Shape.bendable(
      tool, from: CGPoint(x: 350, y: 300), to: CGPoint(x: 450, y: 300))
    #expect(annotation(h, id)?.shape == straight)
    // 按在弦中点（直的弯曲手柄，压在线上）往上拖：两端不动、弧线中点跟手（拖动中就是弯的），不是挪整条
    h.begin(CGPoint(x: 400, y: 300), to: CGPoint(x: 410, y: 340))
    #expect(near(midpoint(h, id), CGPoint(x: 410, y: 340)))
    h.release(CGPoint(x: 410, y: 340))
    guard let (from, to, bend) = annotation(h, id)?.shape.curve else { return #expect(Bool(false)) }
    #expect(from == CGPoint(x: 350, y: 300) && to == CGPoint(x: 450, y: 300) && bend != .zero)
    #expect(h.view.annotations.count == 1)
    // 一次拖动一步撤销
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(annotation(h, id)?.shape == straight)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: [.command, .shift])
    #expect(near(midpoint(h, id), CGPoint(x: 410, y: 340)))
    // ⇧：对称的弧（中点落在弦的垂直平分线上）
    h.drag(CGPoint(x: 410, y: 340), CGPoint(x: 430, y: 280), flags: .shift)
    #expect(near(midpoint(h, id), CGPoint(x: 400, y: 280)))
    // 拖回离弦不到 4 点：吸回直的
    h.drag(CGPoint(x: 400, y: 280), CGPoint(x: 380, y: 297))
    #expect(annotation(h, id)?.shape == straight)
    // 双击弯曲手柄拉直，记一步撤销
    h.drag(CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 360))
    for clicks in 1...2 {
      h.down(CGPoint(x: 401, y: 359), clicks: clicks)
      h.release(CGPoint(x: 401, y: 359))
    }
    #expect(annotation(h, id)?.shape == straight)
    #expect(h.view.selectedAnnotation == id)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(near(midpoint(h, id), CGPoint(x: 400, y: 360)))
  }

  @Test(arguments: [Annotation.Tool.arrow, .line])
  func doubleClickOnAnUnselectedCurveOnlySelectsIt(_ tool: Annotation.Tool) {
    // 双击没选中的弯箭头 / 弯直线的弧线中点：第一下选中它（弯曲手柄这才出现在按下的地方），第二下不算双击弯曲手柄，不拉直
    let h = harness(tool: nil)
    let arrow = Annotation(
      shape: .bendable(
        tool, from: CGPoint(x: 350, y: 300), to: CGPoint(x: 450, y: 300),
        bend: CGVector(dx: 0, dy: 0.5)))
    h.view.annotations = [arrow]
    h.click(CGPoint(x: 400, y: 350))
    h.click(CGPoint(x: 400, y: 350), clicks: 2)
    #expect(h.view.selectedAnnotation == arrow.id)
    #expect(annotation(h, arrow.id) == arrow)
    // 选中后两下都按在弯曲手柄上才拉直
    h.click(CGPoint(x: 400, y: 350))
    h.click(CGPoint(x: 400, y: 350), clicks: 2)
    #expect(
      annotation(h, arrow.id)?.shape
        == .bendable(tool, from: CGPoint(x: 350, y: 300), to: CGPoint(x: 450, y: 300)))
  }

  @Test(arguments: [Annotation.Tool.arrow, .line])
  func handlesDoNotJumpToThePointerAndTheBendHandleStaysNearAnEnd(_ tool: Annotation.Tool) {
    let h = harness(tool: tool)
    h.drag(CGPoint(x: 350, y: 300), CGPoint(x: 450, y: 300))
    let id = h.view.selectedAnnotation
    let straight = Annotation.Shape.bendable(
      tool, from: CGPoint(x: 350, y: 300), to: CGPoint(x: 450, y: 300))
    // 按在弯曲手柄（弦中点）上方 5 点、拖 1 点：弧线中点只跟着挪 1 点（还在吸直的 4 点内），不先跳到光标上弯 6 点
    h.begin(CGPoint(x: 400, y: 305), to: CGPoint(x: 400, y: 306))
    #expect(annotation(h, id)?.shape == straight)
    h.release(CGPoint(x: 400, y: 306))
    // 接着往上拖 40：中点落在 (400, 340)，和按下的点一直差 5
    h.drag(CGPoint(x: 400, y: 305), CGPoint(x: 400, y: 345))
    #expect(near(midpoint(h, id), CGPoint(x: 400, y: 340)))
    // 端点手柄也一样：按在尖端左下 3 点处往右拖 50，尖端到 (500, 300)
    h.drag(CGPoint(x: 447, y: 297), CGPoint(x: 497, y: 297))
    guard let (from, to, _) = annotation(h, id)?.shape.curve else { return #expect(Bool(false)) }
    #expect(from == CGPoint(x: 350, y: 300) && to == CGPoint(x: 500, y: 300))
    // 弦 48 的短的：弯曲手柄往尖端拖过头，弧线中点停在 ¾ 处、离尖端不到 16 点，拖着和松手后手柄都还在，能接着拖
    let short = Annotation(
      shape: .bendable(tool, from: CGPoint(x: 350, y: 400), to: CGPoint(x: 398, y: 400)))
    h.view.annotations = [short]
    h.view.selectedAnnotation = short.id
    let bendHandle = {
      h.view.annotations.first { $0.id == short.id }?.handles.first { $0.0 == .bend }?.1
    }
    h.begin(CGPoint(x: 374, y: 400), to: CGPoint(x: 420, y: 406))
    let dragged = bendHandle()
    #expect(dragged.map { near($0, CGPoint(x: 386, y: 406)) } == true)
    #expect(dragged.map { hypot(398 - $0.x, 400 - $0.y) < 16 } == true)
    h.release(CGPoint(x: 420, y: 406))
    #expect(bendHandle() == dragged)
    h.drag(CGPoint(x: 386, y: 406), CGPoint(x: 380, y: 420))
    #expect(near(bendHandle(), CGPoint(x: 380, y: 420)))
  }

  @Test(arguments: [Annotation.Tool.arrow, .line])
  func curveKeepsItsBendWhenEditedMovedAndCopied(_ tool: Annotation.Tool) throws {
    let h = harness(tool: nil)
    let bend = CGVector(dx: 0, dy: 0.5)
    let arrow = Annotation(
      shape: .bendable(tool, from: CGPoint(x: 350, y: 300), to: CGPoint(x: 450, y: 300), bend: bend)
    )
    h.view.annotations = [arrow]
    // 点弧线（顶点 (400, 350)）选中它；弦中点离弧线 50 点，点不中
    h.click(CGPoint(x: 400, y: 300))
    #expect(h.view.selectedAnnotation == nil)
    h.click(CGPoint(x: 420, y: 347))
    #expect(h.view.selectedAnnotation == arrow.id)
    // 拖终点：弯度跟着弦等比变，弯曲手柄还在弧线中点
    h.drag(CGPoint(x: 450, y: 300), CGPoint(x: 550, y: 300))
    #expect(
      annotation(h, arrow.id)?.shape
        == .bendable(tool, from: CGPoint(x: 350, y: 300), to: CGPoint(x: 550, y: 300), bend: bend))
    #expect(near(midpoint(h, arrow.id), CGPoint(x: 450, y: 400)))
    // 方向键挪、⌘D 复制（右下 12）、⌥ 拖动复制都带着弯度；撤销回到挪之前
    h.arrow(kVK_RightArrow)
    #expect(
      annotation(h, arrow.id)?.shape
        == .bendable(tool, from: CGPoint(x: 351, y: 300), to: CGPoint(x: 551, y: 300), bend: bend))
    #expect(h.keyEquivalent(kVK_ANSI_D, "d", flags: .command))
    let copy = try #require(h.view.annotations.last)
    #expect(copy.id != arrow.id && h.view.selectedAnnotation == copy.id)
    #expect(
      copy.shape
        == .bendable(tool, from: CGPoint(x: 363, y: 288), to: CGPoint(x: 563, y: 288), bend: bend))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.count == 1)
    #expect(near(midpoint(h, arrow.id), CGPoint(x: 450, y: 400)))
    h.drag(CGPoint(x: 450, y: 399), CGPoint(x: 450, y: 379), flags: .option)
    let dragged = try #require(h.view.annotations.last)
    #expect(h.view.annotations.count == 2 && dragged.id != arrow.id)
    #expect(
      dragged.shape
        == .bendable(tool, from: CGPoint(x: 350, y: 280), to: CGPoint(x: 550, y: 280), bend: bend))
  }

  @Test func optionDragDuplicatesAndMovesTheCopy() throws {
    let h = harness(tool: nil)
    let original = Annotation(shape: .rectangle(CGRect(x: 350, y: 250, width: 100, height: 100)))
    h.view.annotations = [original]
    // 按在左边线上（原件没选中，没有手柄），⌥ 往右拖 30
    h.drag(CGPoint(x: 350, y: 300), CGPoint(x: 380, y: 300), flags: .option)
    #expect(h.view.annotations.count == 2)
    #expect(h.view.annotations.first == original)
    let copy = try #require(h.view.annotations.last)
    #expect(copy.id != original.id)
    #expect(copy.shape == .rectangle(CGRect(x: 380, y: 250, width: 100, height: 100)))
    #expect(h.view.selectedAnnotation == copy.id)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations == [original])
    // ⌥ 单击没拖开：不留叠在原处的副本，选中原件（选中后边中点是手柄，按在避开它的边线上）
    h.click(CGPoint(x: 350, y: 280))
    h.down(CGPoint(x: 350, y: 280), flags: .option)
    #expect(h.view.annotations.count == 2)
    h.release(CGPoint(x: 350, y: 280), flags: .option)
    #expect(h.view.annotations == [original])
    #expect(h.view.selectedAnnotation == original.id)
  }

  // ⌥ 拖动复制时光标带 +（拖原件是抓手）
  @Test func optionDragShowsCopyCursor() {
    let h = harness(tool: nil)
    h.view.annotations = [
      Annotation(shape: .rectangle(CGRect(x: 350, y: 250, width: 100, height: 100)))
    ]
    h.begin(CGPoint(x: 350, y: 300), to: CGPoint(x: 380, y: 300), flags: .option)
    #expect(NSCursor.current.image.tiffRepresentation == NSCursor.dragCopy.image.tiffRepresentation)
    h.release(CGPoint(x: 380, y: 300), flags: .option)
    // 按在边线上、避开边中点的手柄（那里是改大小）
    h.begin(CGPoint(x: 380, y: 280), to: CGPoint(x: 400, y: 280))
    #expect(
      NSCursor.current.image.tiffRepresentation == NSCursor.closedHand.image.tiffRepresentation)
    h.release(CGPoint(x: 400, y: 280))
  }

  // 拖着标注（画、挪、改大小）时 ⌘Z / ⇧⌘Z / ⌫ / ⌘D 不响应：不然松手时记的那一步撤销和标注列表对不上
  @Test func undoDeleteDuplicateIgnoredWhileDragging() {
    let h = harness(tool: .rectangle)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 400, y: 300))
    // 画第二个的途中按 ⌘Z：不撤销第一个；松手后两个都在，撤销一步只去掉第二个
    h.begin(CGPoint(x: 500, y: 250), to: CGPoint(x: 560, y: 300))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    h.release(CGPoint(x: 560, y: 300))
    #expect(h.view.annotations.count == 2)
    let first = h.view.annotations.first
    // 按住第二个（空心矩形认边线，避开边中点的手柄）挪的途中按 ⌫ / ⌘D / ⇧⌘Z：都不动
    h.begin(CGPoint(x: 515, y: 250), to: CGPoint(x: 525, y: 260))
    h.key(kVK_Delete, "\u{7f}")
    h.keyEquivalent(kVK_ANSI_D, "d", flags: .command)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: [.command, .shift])
    #expect(h.view.annotations.count == 2)
    #expect(
      h.view.annotations.last?.shape == .rectangle(CGRect(x: 510, y: 260, width: 60, height: 50)))
    h.release(CGPoint(x: 525, y: 260))
    // 撤销依次是：挪 → 画第二个 → 画第一个
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(
      h.view.annotations.last?.shape == .rectangle(CGRect(x: 500, y: 250, width: 60, height: 50)))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations == [first].compactMap { $0 })
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.isEmpty)
  }

  @Test func optionDragCounterGetsNextNumber() throws {
    let h = harness(tool: nil)
    h.view.annotations = [Annotation(shape: .counter(1, center: CGPoint(x: 400, y: 300)))]
    h.drag(CGPoint(x: 400, y: 300), CGPoint(x: 440, y: 300), flags: .option)
    #expect(
      h.view.annotations.map(\.shape) == [
        .counter(1, center: CGPoint(x: 400, y: 300)), .counter(2, center: CGPoint(x: 440, y: 300)),
      ])
  }

  @Test func shiftLocksMoveToTheDominantAxis() {
    let h = harness(tool: nil)
    let arrow = Annotation(
      shape: .arrow(from: CGPoint(x: 350, y: 300), to: CGPoint(x: 450, y: 300)))
    h.view.annotations = [arrow]
    h.drag(CGPoint(x: 400, y: 300), CGPoint(x: 430, y: 310), flags: .shift)
    #expect(annotation(h, arrow.id)?.shape == arrow.offset(by: CGSize(width: 30, height: 0)).shape)
    // 拖动中松开 ⇧：立刻跟手（现在选中了：按在弦中点是弯曲手柄，挪要按在杆的别处）
    h.begin(CGPoint(x: 410, y: 300), to: CGPoint(x: 415, y: 340), flags: .shift)
    #expect(annotation(h, arrow.id)?.shape == arrow.offset(by: CGSize(width: 30, height: 40)).shape)
    h.modifiers([])
    #expect(annotation(h, arrow.id)?.shape == arrow.offset(by: CGSize(width: 35, height: 40)).shape)
    h.release(CGPoint(x: 415, y: 340))
  }

  @Test func commandDDuplicatesDownRightAndDeleteRemoves() throws {
    let h = harness(tool: .counter)
    h.click(CGPoint(x: 400, y: 300))
    #expect(h.keyEquivalent(kVK_ANSI_D, "d", flags: .command))
    #expect(
      h.view.annotations.map(\.shape) == [
        .counter(1, center: CGPoint(x: 400, y: 300)), .counter(2, center: CGPoint(x: 412, y: 288)),
      ])
    #expect(h.view.selectedAnnotation == h.view.annotations.last?.id)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.count == 1)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: [.command, .shift])
    #expect(h.view.annotations.count == 2)
    // ⌫ 删掉选中的（副本）
    h.view.selectedAnnotation = h.view.annotations.last?.id
    h.key(kVK_Delete, "\u{7f}")
    #expect(h.view.annotations.map(\.shape) == [.counter(1, center: CGPoint(x: 400, y: 300))])
    #expect(h.view.selectedAnnotation == nil)
    // 没选中时 ⌘D 不接
    #expect(!h.keyEquivalent(kVK_ANSI_D, "d", flags: .command))
  }

  @Test func annotationHandleWinsOverSelectionEdge() {
    let h = harness(tool: nil)
    // 左上角手柄 (303, 350) 落在选区左边的拖动带里（边外 8、边内 8）
    let box = Annotation(shape: .rectangle(CGRect(x: 303, y: 250, width: 97, height: 100)))
    h.view.annotations = [box]
    h.view.selectedAnnotation = box.id
    h.move(CGPoint(x: 303, y: 350))
    #expect(h.view.hotHandle == nil, "标注手柄上选区边不该变热")
    h.drag(CGPoint(x: 303, y: 350), CGPoint(x: 320, y: 380))
    #expect(
      annotation(h, box.id)?.shape == .rectangle(CGRect(x: 320, y: 250, width: 80, height: 130)))
    #expect(h.view.selection == SelectionInteractionTests.initial)
    // 没选中它时同一点拖的是选区边
    h.view.selectedAnnotation = nil
    h.drag(CGPoint(x: 303, y: 400), CGPoint(x: 280, y: 400))
    #expect(h.view.selection?.minX == 280)
  }

  @Test func doubleClickReeditsTextOrCopiesTheSelection() async throws {
    let h = harness(tool: nil)
    // 底色白字标注：重新编辑时输入框一打开就是白色色块 + 黑字
    let text = Annotation(
      shape: .text("hi", origin: CGPoint(x: 400, y: 400)), style: .init(color: .white, option: 2))
    h.view.annotations = [text]
    func doubleClick(_ point: CGPoint) {
      for count in 1...2 {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
            pressure: type == .leftMouseUp ? 0 : 1)!
          if type == .leftMouseDown {
            h.view.mouseDown(with: event)
          } else {
            h.view.mouseUp(with: event)
          }
        }
      }
    }
    doubleClick(CGPoint(x: 405, y: 390))
    let field = try #require(h.fieldEditor)
    #expect(field.string == "hi")
    #expect(field.layer?.backgroundColor == Annotation.Palette.white.color.cgColor)
    #expect(field.textColor == Annotation.Palette.white.ink)
    h.key(kVK_Escape, "\u{1b}")
    #expect(h.view.annotations == [text])
    #expect(h.view.selectedAnnotation == text.id)
    // 选区里的空白处双击：拷贝（第一下取消选中标注）
    let outcome = await h.outcome { doubleClick(CGPoint(x: 600, y: 250)) }
    guard case .capture(let capture)? = outcome else {
      Issue.record("双击没有拷贝：\(String(describing: outcome))")
      return
    }
    #expect(capture.action == .copy)
  }

  // 字号：输入时 ⌘+ / 托盘 A− A+ / 选中后 ⌘− / 滚轮，都记撤销、记住给下一条（拍板 A1 A2 O1）
  @Test func fontSizeByKeysTrayAndWheel() throws {
    let h = harness(tool: .text)
    let origin = CGPoint(x: 400, y: 400)
    h.view.beginEditing(at: origin)
    let field = try #require(h.fieldEditor)
    field.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
    let styleBar = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    #expect(h.keyEquivalent(kVK_ANSI_Equal, "=", flags: .command))
    #expect(field.font?.pointSize == 24)
    styleBar.onFontStep(-1)
    styleBar.onFontStep(-1)
    #expect(field.font?.pointSize == 16)
    h.key(kVK_Escape, "\u{1b}")
    let text = try #require(h.view.annotations.first)
    #expect(text.style.fontSize == 16 && h.view.selectedAnnotation == text.id)
    // 选中文字时 ⌘−；下一条文字用记住的字号
    #expect(h.keyEquivalent(kVK_ANSI_Minus, "-", flags: .command))
    #expect(h.view.annotations.first?.style.fontSize == 14)
    #expect(h.view.style.fontSize == 14)
    // 鼠标在选中的文字上滚轮往上：大一档；不在它上面不动
    let inside = CGPoint(x: text.bounds.midX, y: text.bounds.midY)
    h.move(inside)
    h.scroll(up: true)
    #expect(h.view.annotations.first?.style.fontSize == 16)
    h.move(CGPoint(x: 600, y: 250))
    h.scroll(up: true)
    #expect(h.view.annotations.first?.style.fontSize == 16)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.first?.style.fontSize == 14)
    // 输入时那几次改字号不单独记步：再撤两步是「选中后 ⌘−」之前、再之前是没有这条文字
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.first?.style.fontSize == 16)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.isEmpty)
    // ⇧⌘- 不是字号键（留给改键）
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: [.command, .shift])
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: [.command, .shift])
    #expect(!h.keyEquivalent(kVK_ANSI_Minus, "-", flags: [.command, .shift]))
    #expect(h.view.annotations.first?.style.fontSize == 14)
  }

  // 拖着文字时按 ⌘+：吞掉不改，松手只记挪动那一步（不然撤销栈里多一个拖到一半的样子）
  @Test func fontKeysIgnoredWhileDragging() throws {
    let h = harness(tool: nil)
    let text = Annotation(shape: .text("字", origin: CGPoint(x: 400, y: 400)))
    h.view.annotations = [text]
    let inside = CGPoint(x: text.bounds.midX, y: text.bounds.midY)
    h.begin(inside, to: CGPoint(x: inside.x + 30, y: inside.y))
    #expect(h.keyEquivalent(kVK_ANSI_Equal, "=", flags: .command))
    h.release(CGPoint(x: inside.x + 30, y: inside.y))
    let moved = try #require(h.view.annotations.first)
    #expect(
      moved.style.fontSize == nil && moved.shape == .text("字", origin: CGPoint(x: 430, y: 400)))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations == [text])
  }

  // 滚轮在选中的矩形上换粗细；选中序号时托盘改编号，之后新放的照旧是最大 + 1（拍板 O1 O2）
  @Test func wheelChangesWeightAndTrayRenumbersCounter() throws {
    let h = harness(tool: .rectangle)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    h.move(CGPoint(x: 350, y: 280))  // 空心矩形认边线
    h.scroll(up: true)
    #expect(h.view.annotations.first?.style.weight == .large)
    h.scroll(up: false)
    h.scroll(up: false)
    #expect(h.view.annotations.first?.style.weight == .small)
    h.view.tool = .counter
    h.click(CGPoint(x: 550, y: 300))
    let styleBar = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    styleBar.onNumber(1)
    styleBar.onNumber(1)
    #expect(h.view.annotations.last?.shape == .counter(3, center: CGPoint(x: 550, y: 300)))
    h.click(CGPoint(x: 600, y: 300))
    #expect(h.view.annotations.last?.shape == .counter(4, center: CGPoint(x: 600, y: 300)))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.last?.shape == .counter(2, center: CGPoint(x: 550, y: 300)))
  }

  // 序号拖右上角放大（用户反馈：序号要能像矩形一样改大小），⌘Z 回去；点托盘的三档回到三档
  @Test func counterCornerResizesThenUndo() throws {
    let h = harness(tool: .counter)
    h.click(CGPoint(x: 500, y: 300))
    let id = try #require(h.view.selectedAnnotation)
    h.drag(CGPoint(x: 513, y: 313), CGPoint(x: 540, y: 320))  // 中号 26 的右上角
    #expect(annotation(h, id)?.style.diameter == 80)
    #expect(annotation(h, id)?.shape == .counter(1, center: CGPoint(x: 500, y: 300)))
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(annotation(h, id)?.style.diameter == nil)
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: [.command, .shift])
    let styleBar = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    styleBar.onWeight(.large)
    #expect(annotation(h, id)?.style.diameter == nil && annotation(h, id)?.style.weight == .large)
  }

  // 一键打码（拍板 C5）：选区里的电话号码加一块打码（第一次用是模糊），一起记一步撤销；选区外的不管
  @Test func autoRedactCoversNumbersInTheSelection() async throws {
    let context = try #require(
      CGContext(
        data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28)]
    NSAttributedString(string: "电话 138 0013 8000", attributes: font).draw(
      at: CGPoint(x: 330, y: 400))
    NSAttributedString(string: "选区外 139 1234 5678", attributes: font).draw(
      at: CGPoint(x: 760, y: 400))
    NSGraphicsContext.restoreGraphicsState()
    let h = Harness(image: try #require(context.makeImage()))
    h.makeSelection()  // (300, 200)–(700, 500)
    h.key(kVK_ANSI_9, "9")  // 选打码工具（照记住的样式：第一次是模糊）
    #expect(h.view.tool == .mosaic)
    let box = Annotation(shape: .rectangle(CGRect(x: 320, y: 220, width: 60, height: 60)))
    h.view.annotations = [box]
    let styleBar = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    styleBar.onAutoRedact()
    // 识字还没回来时按 ⌘C：不出图（不然号码跟着图出去了）
    let early = await h.outcome { _ = h.keyEquivalent(kVK_ANSI_C, "c", flags: .command) }
    if case .color(let note)? = early { #expect(note == "没交回结果") } else { Issue.record("出图了") }
    // 拖着矩形时识字回来：等松手再落，撤销一步只撤打码、矩形留在挪过的地方
    h.begin(CGPoint(x: 335, y: 220), to: CGPoint(x: 345, y: 220))
    try await Task.sleep(for: .seconds(1.5))
    #expect(h.view.annotations.count == 1)
    h.release(CGPoint(x: 345, y: 220))
    for _ in 0..<500 where h.view.annotations.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(h.view.annotations.count == 2)
    let added = try #require(h.view.annotations.last)
    #expect(added.style.option == 1)
    guard case .mosaic(let rect) = added.shape else {
      Issue.record("不是打码")
      return
    }
    #expect(rect.minX > 380 && rect.maxX < 700 && rect.minY < 410 && rect.maxY > 420, "\(rect)")
    h.keyEquivalent(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations.map(\.shape) == [box.offset(by: CGSize(width: 10, height: 0)).shape])
  }

  // 吸管（拍板 O10）：点了之后放大镜出来，单击取中心像素的颜色给当前工具；点预设色作废；Esc 取消
  @Test func eyedropperPicksColorFromTheShot() async throws {
    // 上半红、下半蓝（上下翻了就取错）
    let context = try #require(
      CGContext(
        data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 400, width: 1200, height: 400))
    let h = Harness(image: try #require(context.makeImage()))
    h.makeSelection()
    h.view.tool = .rectangle
    let styleBar = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    styleBar.onEyedropper()
    h.move(CGPoint(x: 500, y: 450))  // 上半
    #expect(h.view.showsMagnifier)
    h.click(CGPoint(x: 500, y: 450))
    #expect(h.view.annotations.isEmpty)  // 这一下只取色，不画
    let custom = try #require(h.view.style.custom)
    #expect(custom == 0xFF0000)
    // 取色时按 C 也是取色，不结束截图
    styleBar.onEyedropper()
    h.move(CGPoint(x: 500, y: 300))  // 下半
    let viaKey = await h.outcome { h.key(kVK_ANSI_C, "c") }
    if case .color(let note)? = viaKey { #expect(note == "没交回结果") } else { Issue.record("截图结束了") }
    #expect(h.view.style.custom == 0x0000FF)
    h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 450, y: 350))
    #expect(h.view.annotations.first?.style.custom == 0x0000FF)
    styleBar.onColor(.red)
    #expect(h.view.annotations.first?.style.custom == nil && h.view.style.custom == nil)
    // Esc 取消：再单击不取色
    styleBar.onEyedropper()
    h.key(kVK_Escape, "\u{1b}")
    h.move(CGPoint(x: 600, y: 300))
    h.click(CGPoint(x: 600, y: 300))
    #expect(h.view.style.custom == nil)
  }

  @Test func textEditorShowsStylesLive() throws {
    // 托盘改样式会写记住的样式：Harness 记在临时偏好域里，不碰真实偏好
    let h = harness(tool: .text)
    h.view.style = Annotation.Style(color: .yellow)
    let origin = CGPoint(x: 400, y: 400)
    h.view.beginEditing(at: origin)
    let field = try #require(h.fieldEditor)
    field.insertText("hi", replacementRange: NSRange(location: NSNotFound, length: 0))
    let styleBar = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    /// 字从哪儿排起（视图坐标，左上角）：换样式时不能动
    func textOrigin() -> CGPoint {
      CGPoint(
        x: field.frame.minX + field.textContainerOrigin.x,
        y: field.frame.maxY - field.textContainerOrigin.y)
    }
    #expect(textOrigin() == origin)
    #expect(field.textColor == Annotation.Palette.yellow.color)
    // 底色：输入框的底就是色块，黄底黑字，左右留 6
    styleBar.onOption(2)
    #expect(field.layer?.backgroundColor == Annotation.Palette.yellow.color.cgColor)
    #expect(field.textColor == Annotation.Palette.yellow.ink)
    #expect(field.textContainerInset == Annotation.platePadding)
    #expect(textOrigin() == origin)
    // 描边：没有底，字是原色；输入中换颜色也立刻变
    styleBar.onOption(1)
    #expect(field.layer?.backgroundColor == nil)
    styleBar.onColor(.blue)
    #expect(field.textColor == Annotation.Palette.blue.color)
    #expect(textOrigin() == origin)
    // 收下：样式跟着存进标注，并选中它
    h.key(kVK_Escape, "\u{1b}")
    let text = try #require(h.view.annotations.first)
    #expect(text.shape == .text("hi", origin: origin))
    #expect(text.style == Annotation.Style(color: .blue, weight: .medium, option: 1))
    #expect(h.view.selectedAnnotation == text.id)
  }
}
