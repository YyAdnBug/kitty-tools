// 启动器里的「快捷指令」（第四轮体检 X10，2026-11-17）：系统自带的 /usr/bin/shortcuts 在进程外列出（shortcuts list）和运行
// （shortcuts run 名字），不要新的授权、不打开「快捷指令」App。
// - 列表缓存着：启动器呼出时过期（staleAfter）就在后台重列，搜索只读缓存、不等它（第一次呼出时还没有，下次就有）。
// - 一条是 .system 种类的结果（目标「shortcut:名字」，SystemShortcuts.target），和系统命令一样记使用、能收藏；名字、拼音、
//   「快捷指令」「shortcut」都进搜索名。↩ 运行（不带输入）：岛上「正在运行」，跑完说一声，失败带系统给的原因。
// - 设置 › 启动器「搜索快捷指令」能关（Prefs.launcherShortcuts，默认开）；启动器这个功能关着就都没有。
// ponytail: 不带输入、不收输出（要的人自己在快捷指令里写「拷贝到剪贴板」）；跑得久的（等用户点对话框）最多等 10 分钟。

import Foundation

enum SystemShortcuts {
  static let prefix = "shortcut:"
  static let tool = "/usr/bin/shortcuts"
  /// 列表多久重列一次
  static let staleAfter: TimeInterval = 60

  static func target(_ name: String) -> String { prefix + name }

  static func name(fromTarget target: String) -> String? {
    target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : nil
  }

  /// shortcuts list 的输出：一行一个名字（去掉首尾空白、空行和重复的；纯函数）
  static func parse(_ output: String) -> [String] {
    var seen = Set<String>()
    return output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// 一条快捷指令在启动器里那一行
  static func item(_ name: String) -> LauncherItem {
    let pinyin = AppCatalog.pinyin(name)
    let names = [name, pinyin?.full, String(localized: "快捷指令"), "快捷指令", "shortcut", "shortcuts"]
      .compactMap { $0 }.map(LauncherMatch.fold)
    return LauncherItem(
      kind: .system, target: target(name), title: name, subtitle: String(localized: "快捷指令"),
      names: names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
      initials: [LauncherMatch.initials(name), pinyin?.initials].compactMap { $0 })
  }

  /// 列出这台 Mac 上的快捷指令（进程外，最多 5 秒）；列不出来是 nil
  static func list() async -> [String]? {
    guard
      let result = try? await Subprocess.run(
        tool, ["list"], captures: true, timeout: .seconds(5), quality: .utility),
      result.status == 0, !result.signaled
    else { return nil }
    return parse(result.output)
  }

  /// 运行一条（不带输入）：岛上先说「正在运行」，跑完说成没成。名字前加 `--`：「-」开头的名字不被当成参数
  static func run(_ name: String, island: Island?) {
    island?.show("正在运行「\(name)」", tone: .progress, symbol: "square.stack.3d.up.fill")
    Task {
      let result = try? await Subprocess.run(
        tool, ["run", "--", name], captures: true, timeout: .seconds(600))
      if let result, result.status == 0, !result.signaled {
        island?.show("已运行「\(name)」", symbol: "square.stack.3d.up.fill")
      } else {
        let reason = result?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        island?.show(
          "快捷指令「\(name)」没运行成", detail: "\(Island.excerpt(reason))", tone: .error)
      }
    }
  }
}
