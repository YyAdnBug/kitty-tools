// 启动器里搜前台 App 的菜单项（第五轮体检 N3，2026-11-19；归 App 快捷键插件，插件没添加、没辅助功能授权时没有这一组）。
// 对标别家启动器的「搜索菜单栏项」：藏得深的菜单命令（导出为 PDF、显示标尺）打几个字就找到、↩ 执行。
// - 读：呼出启动器那一刻的前台 App（启动器不激活本 App，前台还是底下那个；前台是本 App 时不读），打字够长时才在主线程外读一次
//   它的菜单（read：MenuShortcuts.read 的 includesPlain，没有快捷键的项也收，整次 1 秒封顶；行和拼音在同一次读里算好）；
//   读到的按 App + 时刻留着（staleAfter 以内、同一个 App 不重读，再打字只是重新过滤），读的时候先用上一回的；启动器收起
//   staleAfter 之后丢掉（LauncherModel.didHide）。
// - 配：标题（中文认拼音全拼和首字母）和菜单路径（「文件 › 导出」）：每个词都要对上标题或路径里的一段，至少一个词对上
//   标题（只打「文件」不把文件菜单整个列出来），按标题的匹配分排；排在本地结果后面、浏览历史前面，最多 limit 行；
//   本地结果一条都没有时排到兜底的网页搜索后面——**菜单项不当默认选中的第一行**（↩ 不会误按下菜单里的命令）。
// - 灰着的项照列（AXEnabled 是上次打开菜单时的样子，不可信，同 App 快捷键面板）：↩ 时 App 自己定能不能用，用不了刘海岛说。
// - 执行：收起启动器、那个 App 不在前台就先切回去，按读时记下的位置一级级找回去 AXPress（AppShortcuts.press，同面板里点一行）。

import AppKit

enum MenuSearch {
  /// 一个菜单项在启动器里那一行带着的：哪个 App（pid，包路径给图标）、菜单里的哪一项、路径各段的搜索名（折叠过，含拼音）
  nonisolated struct Entry: Hashable, Sendable {
    let pid: pid_t
    let appPath: String?
    let item: MenuShortcut
    let pathNames: [String]
  }

  /// 读到的菜单多久内不重读（同一个 App）；启动器收起这么久之后丢掉
  static let staleAfter: TimeInterval = 30

  /// 在主线程外读 pid 那个 App 的菜单，顺手把行（拼音）算好（mac-native §3 第 3 类：读前台 App 的菜单）
  @concurrent nonisolated static func read(pid: pid_t, appName: String, appPath: String?) async
    -> [LauncherItem]
  {
    let reading = await MenuShortcuts.read(pid: pid, checksFocus: false, includesPlain: true)
    return rows(reading, pid: pid, appName: appName, appPath: appPath)
  }
  /// 最多列几行：排在本地结果后面，别把浏览历史、兜底搜索挤出可见区
  static let limit = 5

  /// 读到的菜单 → 一项一行。标题是菜单里的样子（去掉了「…」），副标题「App › 菜单 › 子菜单」，有快捷键的接在后面
  nonisolated static func rows(
    _ reading: MenuReading, pid: pid_t, appName: String, appPath: String?
  ) -> [LauncherItem] {
    var pinyin: [String: [String]] = [:]
    func names(_ segment: String) -> [String] {
      if let cached = pinyin[segment] { return cached }
      let folded = [LauncherMatch.fold(segment), AppCatalog.pinyin(segment).map(\.full)]
        .compactMap { $0 }.filter { !$0.isEmpty }
      pinyin[segment] = folded
      return folded
    }
    return reading.shortcuts.map { item in
      let terms = LauncherItem.searchTerms(
        item.title, chinese: nil, english: nil, aliases: [item.title])
      let path = ([appName, item.menu] + item.path).joined(separator: " › ")
      return LauncherItem(
        kind: .menuItem,
        target: String(pid) + "\n" + item.location.map(String.init).joined(separator: "."),
        title: item.title,
        // 副标题是一段字、放不进系统符号：🌐 写成 fn（同系统的键盘快捷键帮助）
        subtitle: item.keys.isEmpty
          ? path : path + " · " + item.keys.replacingOccurrences(of: "🌐", with: "fn"),
        names: terms.names, initials: terms.initials,
        menuItem: Entry(
          pid: pid, appPath: appPath, item: item,
          pathNames: ([item.menu] + item.path).flatMap(names)))
    }
  }

  /// 按查询挑出来、排好（文件头「配」）。纯函数，配单测
  static func matched(_ rows: [LauncherItem], query: String, limit: Int = limit) -> [LauncherItem] {
    let pieces = LauncherMatch.tokens(query)
    let tokens = pieces.map(String.init)
    guard !tokens.isEmpty else { return [] }
    let scored = rows.enumerated().compactMap { index, row -> (LauncherItem, Double, Int)? in
      guard let entry = row.menuItem else { return nil }
      // 先粗筛（只看包含，几百项每打一个字都完整打分太慢）：每个词都在标题的名字、缩写或路径里出现过
      guard
        pieces.allSatisfy({ piece in
          LauncherMatch.mayMatch([piece], row) || entry.pathNames.contains { $0.contains(piece) }
        })
      else { return nil }
      var titled: [String] = []
      for token in tokens {
        if LauncherMatch.score(token, item: row) > 0 {
          titled.append(token)
        } else if !entry.pathNames.contains(where: { $0.contains(token) }) {
          return nil
        }
      }
      guard !titled.isEmpty else { return nil }
      return (row, LauncherMatch.score(titled.joined(separator: " "), item: row), index)
    }
    return scored.sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      if $0.0.title.count != $1.0.title.count { return $0.0.title.count < $1.0.title.count }
      return $0.2 < $1.2
    }
    .prefix(limit).map(\.0)
  }
}
