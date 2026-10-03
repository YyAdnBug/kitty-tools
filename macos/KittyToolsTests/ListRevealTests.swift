// 列表选中跟随滚动（第 10 批，Shell/ListReveal.swift）单测：纯函数各分支（看得见不滚、在上方、在下方、贴顶归零、
// 被吸顶标题挡住）；启动器 40 行结果连按 ↓ / ↑ / 首尾循环时每一步选中行都完整可见（模型 + 前缀和，不弹面板）、
// 回到一组第一行连分组标题一起露出；翻译历史同样按前缀和走完两组。用内存库，不读写用户偏好。

import AppKit
import Testing

@testable import KittyTools

struct ListRevealTests {
  private let visible = CGRect(x: 0, y: 200, width: 700, height: 300)

  @Test func targetBranches() {
    let target = { (top: CGFloat, bottom: CGFloat, covered: CGFloat) in
      ListReveal.target(top: top, bottom: bottom, visible: visible, coveredTop: covered, inset: 6)
    }
    // 完整在可见区里：不滚（贴着上下边也算看得见）
    #expect(target(260, 300, 0) == nil)
    #expect(target(200, 240, 0) == nil && target(460, 500, 0) == nil)
    // 在上方：顶对齐到可见区顶（减去要让出来的高度）
    #expect(target(150, 190, 0) == 150)
    #expect(target(150, 190, 6) == 144)
    // 在下方（或露出一半）：底对齐到可见区底、再留一格内缩
    #expect(target(480, 520, 0) == 226)  // 520 + 6 − 300
    #expect(target(600, 640, 0) == 346)
    // 离顶不到两倍内缩：直接回到 0，第一行上面不留一条缝
    #expect(target(10, 50, 0) == 0)
    #expect(target(6, 46, 6) == 0)
    // 被吸顶的分组标题（24）挡住：行顶在可见区里，但在标题下面不到 24 pt 时也往上滚，让出标题的位置
    #expect(target(210, 250, 24) == 186)
    #expect(target(224, 264, 24) == nil)
    // 可见区还没量到（高 0）：不滚
    #expect(
      ListReveal.target(top: 600, bottom: 640, visible: .zero, coveredTop: 0, inset: 6) == nil)
  }

  private func app(_ title: String) -> LauncherItem {
    LauncherItem(
      kind: .app, target: "/Applications/\(title).app", title: title, subtitle: "",
      names: [LauncherMatch.fold(title)])
  }

  /// 按启动器面板同一套算法走一步：选中行被挡住时把可见区挪到 ListReveal 给的位置，再确认它完整可见
  private func follow(_ model: LauncherModel, in visible: inout CGRect) throws {
    let span = try #require(LauncherPanelView.span(ofRow: model.selection, in: model))
    if let y = ListReveal.target(
      top: span.lowerBound, bottom: span.upperBound, visible: visible,
      coveredTop: LauncherPanelView.inset, inset: LauncherPanelView.inset)
    {
      visible.origin.y = y
    }
    #expect(
      visible.minY <= span.lowerBound && span.upperBound <= visible.maxY, "\(model.selection)")
  }

  /// 用户真机报告：启动器结果多时连按 ↓ 越过可见区，列表不跟着滚（以前 ScrollViewReader.scrollTo(id)，
  /// LazyVStack 里没实例化的行滚不准）。现在按前缀和算目标 y：连按到第 30 行、按 ↑ 回到顶、首尾循环都跟得上
  @Test func launcherFollowsLongList() throws {
    let apps = (0..<40).map { app(String(format: "Kitty%02d", $0)) }
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: apps)
    model.query = "kitty"
    #expect(model.results.count >= 40 && model.groups.isEmpty)
    // 列表区高度和面板同一个算法：高度 − 搜索栏 − 发丝线 − 底栏（8.5 行 + 上下内缩）
    let height =
      LauncherPanelView.height(for: model) - LauncherPanelView.searchHeight - 0.5
      - LauncherPanelView.barHeight
    #expect(height == 12 + 8.5 * 40)
    var visible = CGRect(x: 0, y: 0, width: 680, height: height)
    for _ in 0..<30 {
      #expect(model.handleCommand(#selector(NSResponder.moveDown(_:))))
      try follow(model, in: &visible)
    }
    #expect(model.selection == 30)
    // 第 30 行：顶 6 + 30 × 40 = 1206，底 1246；往下滚时底下留一格内缩
    #expect(visible.maxY == 1252)
    for _ in 0..<30 {
      #expect(model.handleCommand(#selector(NSResponder.moveUp(_:))))
      try follow(model, in: &visible)
    }
    #expect(model.selection == 0 && visible.minY == 0)
    // 第 0 行按 ↑ 循环到最后一行：滚到底（最后一行下面正好是内缩）；再按 ↓ 回到第 0 行：回到顶
    #expect(model.handleCommand(#selector(NSResponder.moveUp(_:))))
    try follow(model, in: &visible)
    let content =
      LauncherPanelView.inset * 2 + model.results.map(LauncherPanelView.rowHeight).reduce(0, +)
    #expect(model.selection == model.results.count - 1 && visible.maxY == content)
    #expect(model.handleCommand(#selector(NSResponder.moveDown(_:))))
    try follow(model, in: &visible)
    #expect(model.selection == 0 && visible.minY == 0)
  }

  /// 回到一组的第一行时连分组标题一起露出来：空查询「收藏」「常用」两组，第 1 行是「常用」的第一行
  @Test func launcherSpanIncludesGroupHeader() throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let apps = (1...3).map { app("App\($0)") }
    let model = LauncherModel(usage: usage, apps: apps)
    usage.record(apps[0], query: "")
    usage.record(apps[1], query: "")
    model.query = ""
    model.toggleFavorite(apps[1])
    #expect(model.groups == [.init(row: 0, title: "收藏"), .init(row: 1, title: "常用")])
    // 第 0 行：「收藏」标题从内缩 6 开始；第 1 行顶 = 6 + 两个标题 56 + 一行 40 = 102，连「常用」标题从 74 开始
    #expect(LauncherPanelView.span(ofRow: 0, in: model) == 6...74)
    #expect(LauncherPanelView.span(ofRow: 1, in: model) == 74...142)
    #expect(LauncherPanelView.span(ofRow: 9, in: model) == nil)
  }

  /// 翻译历史：两组（30 + 20 条），↓ 走到底、↑ 走回来，每一步选中行都完整可见；回到「昨天」第一条时标题也露出来
  @Test func historyFollowsLongList() throws {
    let entries = (0..<50).map { _ in
      HistoryStore.Entry(
        id: UUID(), source: "s", target: .zhHans, result: "r", service: "", createdAt: .now,
        favorite: false)
    }
    let sections = [
      HistoryView.DayGroup(title: "今天", entries: Array(entries[..<30])),
      HistoryView.DayGroup(title: "昨天", entries: Array(entries[30...])),
    ]
    let margin = HistoryView.scrollMargin
    var visible = CGRect(x: 0, y: 0, width: 400, height: 300)
    func follow(_ entry: HistoryStore.Entry) throws -> ClosedRange<CGFloat> {
      let span = try #require(HistoryView.span(of: entry.id, in: sections))
      if let y = ListReveal.target(
        top: span.lowerBound, bottom: span.upperBound, visible: visible, coveredTop: margin,
        inset: margin)
      {
        visible.origin.y = y
      }
      #expect(visible.minY <= span.lowerBound && span.upperBound <= visible.maxY)
      return span
    }
    for entry in entries { _ = try follow(entry) }
    // 最后一条：两个标题 + 49 行，底下正好是列表的内缩
    #expect(visible.maxY == 24 * 2 + 44 * 50 + margin)
    for entry in entries[30...].reversed() { _ = try follow(entry) }
    // 「昨天」第一条：区间从标题顶开始，标题上面再让出一格
    let header = try follow(entries[30])
    #expect(header.lowerBound == 24 + 44 * 30 && visible.minY == header.lowerBound - margin)
    for entry in entries[..<30].reversed() { _ = try follow(entry) }
    #expect(visible.minY == 0)
  }

  /// 只画可见区附近（ListWindow，2026-10-03）：按段取要画的项，上下各多 overscan；段号超出内容（列表刚变短）时
  /// 按最后一段画；空列表什么都不画
  @Test func windowRange() {
    let tops = (0...1000).map { CGFloat($0) * 40 }  // 1000 行，每行 40
    let viewport: CGFloat = 427.5
    // 第 0 段：顶上内缩 6，画到 −6 + 240 + 427.5 + 320 = 981.5 为止
    #expect(ListWindow.range(tops, band: 0, inset: 6, viewport: viewport) == 0..<25)
    // 第 10 段：顶在 2394，从 2074 画到 3381.5
    #expect(ListWindow.range(tops, band: 10, inset: 6, viewport: viewport) == 51..<85)
    // 段号超出内容：按最后一段（39834）画，一直到最后一行
    #expect(ListWindow.range(tops, band: 1000, inset: 6, viewport: viewport) == 987..<1000)
    #expect(ListWindow.range([0], band: 3, inset: 6, viewport: viewport).isEmpty)
  }

  /// 翻译历史的列表几何：标题 24、行 44 一次算好；每一组第一条的区间连着标题；身份标题按标题字、行按条目
  @Test func historyLayout() {
    let entries = (0..<5).map { _ in
      HistoryStore.Entry(
        id: UUID(), source: "s", target: .zhHans, result: "r", service: "", createdAt: .now,
        favorite: false)
    }
    let layout = HistoryView.Layout(sections: [
      HistoryView.DayGroup(title: "今天", entries: Array(entries[..<3])),
      HistoryView.DayGroup(title: "昨天", entries: Array(entries[3...])),
    ])
    // 先定类型再算（字面量混着算类型推断会超时）
    let (header, row): (CGFloat, CGFloat) = (24, 44)
    let yesterday = header + row * 3
    #expect(layout.entries.count == 7 && layout.totalHeight == header * 2 + row * 5)
    #expect(layout.offset(of: entries[3].id) == yesterday + header)
    #expect(layout.span(of: entries[3].id) == yesterday...yesterday + header + row)
    #expect(
      layout.span(of: entries[4].id) == yesterday + header + row...yesterday + header + row * 2)
    #expect(layout.offset(of: UUID()) == nil)
    #expect(Set(layout.entries.indices.map(layout.id(of:))).count == 7)
  }
}
