import AppKit
import Testing

@testable import KittyTools

// 第五轮体检 N3：启动器里搜前台 App 的菜单项（MenuSearch）。不读真的菜单：MenuReading 是手写的，
// 启动器的 readMenu / menuApp 换成假的（menuApp 给本进程自己，只拿它的 pid 和名字，不会去读它的菜单）。
@MainActor struct MenuSearchTests {
  static func item(_ menu: String, _ path: [String], _ title: String, keys: String = "", at: [Int])
    -> MenuShortcut
  {
    MenuShortcut(menu: menu, path: path, title: title, keys: keys, location: at)
  }

  static let reading = MenuReading(shortcuts: [
    item("文件", [], "新建窗口", keys: "⌘N", at: [1, 0]),
    item("文件", [], "导出为 PDF", at: [1, 5]),
    item("文件", ["共享"], "邮件", at: [1, 7, 0]),
    item("显示", [], "显示标尺", keys: "⌘R", at: [3, 2]),
    item("Edit", [], "Paste and Match Style", keys: "⌥⇧⌘V", at: [2, 4]),
  ])

  static var rows: [LauncherItem] {
    MenuSearch.rows(reading, pid: 123, appName: "预览", appPath: nil)
  }

  // 一项一行：标题、副标题（App › 菜单 › 子菜单，有快捷键的接在后面）、目标带 pid 和位置
  @Test func rowsCarryPathAndKeys() throws {
    let rows = Self.rows
    #expect(rows.count == 5)
    let mail = try #require(rows.first { $0.title == "邮件" })
    #expect(mail.kind == .menuItem)
    #expect(mail.subtitle == "预览 › 文件 › 共享")
    #expect(mail.target == "123\n1.7.0")
    #expect(mail.menuItem?.item.location == [1, 7, 0])
    #expect(rows.first { $0.title == "显示标尺" }?.subtitle == "预览 › 显示 · ⌘R")
    #expect(!mail.kind.isRecorded)
  }

  // 认标题（中文认拼音全拼和首字母）；路径里的词要和标题里的词一起打，只打路径不列（不把整个文件菜单列出来）
  @Test func matchesTitleAndPath() {
    let rows = Self.rows
    #expect(MenuSearch.matched(rows, query: "导出").map(\.title) == ["导出为 PDF"])
    #expect(MenuSearch.matched(rows, query: "pdf").map(\.title) == ["导出为 PDF"])
    #expect(MenuSearch.matched(rows, query: "biaochi").map(\.title) == ["显示标尺"])
    #expect(MenuSearch.matched(rows, query: "xsbc").map(\.title) == ["显示标尺"])
    #expect(MenuSearch.matched(rows, query: "pams").map(\.title) == ["Paste and Match Style"])
    #expect(MenuSearch.matched(rows, query: "文件").isEmpty)
    #expect(MenuSearch.matched(rows, query: "共享 邮件").map(\.title) == ["邮件"])
    #expect(MenuSearch.matched(rows, query: "wenjian 邮件").map(\.title) == ["邮件"])
    #expect(MenuSearch.matched(rows, query: "显示 邮件").isEmpty)
    #expect(MenuSearch.matched(rows, query: "").isEmpty)
  }

  // 最多 limit 行，分高的、标题短的在前
  @Test func limitsAndOrders() {
    let many = MenuReading(
      shortcuts: (0..<8).map { Self.item("窗口", [], "窗口 \($0)", at: [4, $0]) }
        + [Self.item("窗口", [], "窗口", at: [4, 9])])
    let rows = MenuSearch.rows(many, pid: 1, appName: "访达", appPath: nil)
    let matched = MenuSearch.matched(rows, query: "窗口")
    #expect(matched.count == MenuSearch.limit)
    #expect(matched.first?.title == "窗口")
  }

  // 启动器：插件添加着（menuApp 给了 App）时打字在后台读一次菜单，读完列在本地结果后面；同一次呼出里再打字不重读
  @Test func launcherListsMenuItems() async throws {
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    var reads = 0
    model.menuApp = { NSRunningApplication.current }
    model.readMenu = { pid, name, path in
      reads += 1
      return MenuSearch.rows(Self.reading, pid: pid, appName: name, appPath: path)
    }
    model.prepareForShow()
    model.query = "导出"
    await model.menuLookup()
    #expect(model.results.contains { $0.kind == .menuItem && $0.title == "导出为 PDF" })
    // 没有本地结果：菜单项排在兜底搜索后面，读完重搜选中还在第一行（↩ 不会按下菜单里的命令）
    #expect(model.results.first?.kind == .search && model.selection == 0)
    // 全量跑时主线程很忙，两步之间可能隔了不止 staleAfter：把读的时刻拨回现在，只看「没过期就不重读」
    model.menuRows?.readAt = .now
    model.query = "标尺"
    await model.menuLookup()
    #expect(model.results.contains { $0.title == "显示标尺" })
    #expect(reads == 1)
    // 插件没添加 / 没授权（menuApp 给 nil）：没有这一组
    model.didHide()
    model.menuApp = { nil }
    model.prepareForShow()
    model.query = "导出"
    #expect(!model.results.contains { $0.kind == .menuItem })
  }
}
