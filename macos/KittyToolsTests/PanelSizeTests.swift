// 面板拖边改大小（2026-11-05 W1 W2）：拖到多高换成最多几行（按半行吸附、夹在范围里），翻译浮窗的最高多高
import AppKit
import Testing

@testable import KittyTools

struct PanelSizeTests {
  @Test func clipboardRowsFollowTheDraggedHeight() {
    // 默认 8.5 行就是原来的 427.5，0 = 默认
    #expect(ClipboardPanelView.maxListHeight(rows: 0) == ClipboardPanelView.maxListHeight)
    #expect(ClipboardPanelView.maxListHeight(rows: 8.5) == ClipboardPanelView.maxListHeight)
    let chrome = ClipboardPanelView.chrome(banner: false)
    for rows in stride(from: 6.5, through: 14.5, by: 1) {
      let height = chrome + ClipboardPanelView.maxListHeight(rows: rows)
      #expect(ClipboardPanelView.rows(forHeight: height, banner: false) == rows)
      // 拖到两行之间：吸到最近的半行
      #expect(
        ClipboardPanelView.rows(forHeight: height + ClipRowView.height * 0.3, banner: false) == rows
      )
    }
    // 夹在 6.5–14.5 里；拖的范围和它对得上
    #expect(ClipboardPanelView.rows(forHeight: 0, banner: false) == 6.5)
    #expect(ClipboardPanelView.rows(forHeight: 5000, banner: true) == 14.5)
    let range = ClipboardPanelView.heightRange(banner: true)
    #expect(ClipboardPanelView.rows(forHeight: range.lowerBound, banner: true) == 6.5)
    #expect(ClipboardPanelView.rows(forHeight: range.upperBound, banner: true) == 14.5)
  }

  @Test func launcherRowsFollowTheDraggedHeight() throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    let range = LauncherPanelView.heightRange(for: model)
    #expect(LauncherPanelView.rows(forHeight: range.lowerBound, model: model) == 6.5)
    #expect(LauncherPanelView.rows(forHeight: range.upperBound, model: model) == 14.5)
    #expect(
      LauncherPanelView.rows(
        forHeight: range.lowerBound + 2.2 * LauncherPanelView.rowHeight, model: model) == 8.5)
    #expect(LauncherPanelView.rows(forHeight: 10_000, model: model) == 14.5)
  }

  @Test func translateCapWins() {
    let visible: CGFloat = 1000
    // 没拖过：照旧（85%、放得下前三张卡）
    #expect(TranslatePanelView.panelHeight(2000, mustFit: 0, visible: visible) == 850)
    #expect(TranslatePanelView.panelHeight(2000, mustFit: 920, visible: visible) == 920)
    // 拖过：照它（前三张卡也不例外，卡片区里滚）；内容少时照样变矮；夹在最矮和可见区减 24 之间
    #expect(TranslatePanelView.panelHeight(2000, mustFit: 920, visible: visible, cap: 400) == 400)
    #expect(TranslatePanelView.panelHeight(300, mustFit: 0, visible: visible, cap: 400) == 300)
    #expect(TranslatePanelView.panelHeight(2000, mustFit: 0, visible: visible, cap: 100) == 220)
    #expect(TranslatePanelView.panelHeight(2000, mustFit: 0, visible: visible, cap: 5000) == 976)
  }
}
