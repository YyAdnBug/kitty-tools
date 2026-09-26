// 截图的旁白（mac-whisker §7「不许省」）：遮罩是一个分组、标签读状态（待选 / 选区像素尺寸、当前工具、比例），进入调整、
// 换工具、锁比例时主动播报；工具栏、样式托盘、尺寸胶囊、HUD 菜单的控件都有名字，菜单项是按钮；长截图面板的粉色拷贝钮不出悬停底。
// 用 SelectionInteractionTests 的屏外窗口 + 合成事件（不弹遮罩、不抢键盘）。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor @Suite(.serialized)
struct ShotAccessibilityTests {
  typealias Harness = SelectionInteractionTests.Harness

  /// view 里的全部按钮（按钮里面不再往下找）
  private func buttons(in view: NSView) -> [NSButton] {
    view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
  }

  @Test func overlayReadsStateAndAnnouncesChanges() throws {
    let h = Harness(windows: [CGRect(x: 100, y: 100, width: 400, height: 300)])
    #expect(h.view.isAccessibilityElement())
    #expect(h.view.accessibilityRole() == .group)
    #expect(h.view.accessibilityLabel() == "待选")
    #expect(h.view.accessibilityHelp()?.hasPrefix("拖动框选") == true)
    h.move(CGPoint(x: 200, y: 200))
    #expect(h.view.accessibilityLabel() == "待选，窗口 400 × 300 像素")
    h.drag(CGPoint(x: 600, y: 450), CGPoint(x: 1000, y: 750))
    #expect(h.view.announcement == "已选中 400 × 300")
    #expect(h.view.accessibilityLabel() == "选区 400 × 300 像素")
    h.key(kVK_ANSI_1, "1")
    #expect(h.view.announcement == "矩形工具")
    #expect(h.view.accessibilityLabel() == "选区 400 × 300 像素，当前工具：矩形")
    h.key(kVK_ANSI_1, "1")
    #expect(h.view.announcement == "已收起工具")
    h.key(kVK_ANSI_2, "2")
    h.key(kVK_Escape, "\u{1b}")
    #expect(h.view.tool == nil)
    #expect(h.view.announcement == "已收起工具")
  }

  // 比例菜单是一组按钮，勾着的那项值是「已选中」；锁上播报、标签带比例，选「自由」播报解锁
  @Test func ratioMenuIsButtonsAndLockIsAnnounced() throws {
    let h = Harness()
    h.makeSelection()
    h.clickSize(nil)
    let menu = try #require(h.menu)
    #expect(menu.accessibilityRole() == .group)
    #expect(menu.accessibilityLabel() == "比例")
    let rows = menu.effect.subviews.filter { $0.accessibilityLabel() != nil }  // 材质自己也有子视图
    #expect(rows.map { $0.accessibilityLabel() } == RegionSelector.ratios.map(\.title))
    #expect(rows.allSatisfy { $0.accessibilityRole() == .button })
    #expect(rows.first?.accessibilityValue() as? String == "已选中")
    h.pick("1:1")
    #expect(h.view.announcement == "已锁定比例 1:1")
    #expect(h.view.accessibilityLabel()?.hasSuffix("，比例 1:1") == true)
    h.clickSize(nil)
    h.pick("自由")
    #expect(h.view.announcement == "已解锁比例")
  }

  // 工具栏、样式托盘（色点是颜色名、粗细点是档名、选项分段是选项名）、尺寸胶囊都有名字；旁白按下尺寸数字开始输入、按下比例钮弹菜单
  @Test func controlsHaveNames() throws {
    let h = Harness()
    h.makeSelection()
    let toolbar = try #require(h.toolbar)
    #expect(toolbar.button(for: .saveMenu)?.accessibilityLabel() == "更多存储选项")
    #expect(toolbar.button(for: .tool(.rectangle))?.accessibilityLabel() == "矩形")
    #expect(buttons(in: toolbar).allSatisfy { $0.accessibilityLabel()?.isEmpty == false })
    h.view.tool = .rectangle
    let tray = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    #expect(
      buttons(in: tray).map { $0.accessibilityLabel() ?? "" } == [
        "粉色", "红色", "橙色", "黄色", "绿色", "蓝色", "黑色", "白色", "细", "中", "粗", "空心", "实心",
      ])
    let size = try #require(h.sizeField)
    let chip = try #require(size.subviews.first { $0.accessibilityRole() == .button })
    #expect(chip.accessibilityLabel() == "比例：自由")
    #expect(chip.accessibilityPerformPress())
    #expect(h.menu != nil)
    h.key(kVK_Escape, "\u{1b}")
    #expect(h.menu == nil)
    let width = try #require(size.subviews.first { $0.accessibilityLabel() == "宽（像素）" })
    #expect(size.subviews.contains { $0.accessibilityLabel() == "高（像素）" })
    #expect(width.accessibilityPerformPress())
    #expect(size.isEditing)
    h.key(kVK_Escape, "\u{1b}")
  }

  // 长截图面板：粉色拷贝钮是整张圆图，不出悬停底（不然圆后面露出一块方角）；其余按钮照常
  @Test func scrollCopyButtonHasNoHoverSquare() throws {
    let all = buttons(in: ScrollCaptureHUD()).compactMap { $0 as? BarButton }
    let copy = try #require(all.first { $0.accessibilityLabel() == "复制（↩）" })
    #expect(!copy.showsHover)
    #expect(all.filter(\.showsHover).count == all.count - 1)
  }
}
