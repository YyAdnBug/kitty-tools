// 启动器的系统命令（对标 Alfred System；PLAN §10 D2 2026-09-27 改为做，mac-whisker §6 启动器「系统命令」）：
// 固定命令（锁定屏幕、睡眠、清倒废纸篓…）各是一行 `.system`，中文名、拼音、Alfred 关键词、英文名都搜得到；
// 带对象的 quit / hide / forcequit / eject / kill 是「关键词 空格」模式，列正在运行的 App / 可推出的宗卷 / 后台进程
// （同 open / find；kill 的进程见 Processes，异步列）。
// 这里只有目录、解析和只读的列举；真正执行在 SystemControl（启动器收起之后）。

import AppKit
import UniformTypeIdentifiers

/// 固定的系统命令。rawValue 是 Alfred 的关键词，也是使用记录里的 id（改名会丢记录）
enum SystemCommand: String, CaseIterable {
  case lock, sleep, sleepdisplays, screensaver, trash, emptytrash, logout, restart, shutdown
  case quitall, ejectall, volup, voldown, mute

  /// 标题用 macOS 自己的叫法（苹果菜单、访达、系统设置里的中文）；弹系统确认框的带「…」
  var title: String {
    switch self {
    case .lock: "锁定屏幕"
    case .sleep: "睡眠"
    case .sleepdisplays: "关闭显示器"
    case .screensaver: "屏幕保护程序"
    case .trash: "打开废纸篓"
    case .emptytrash: "清倒废纸篓"
    case .logout: "退出登录…"
    case .restart: "重新启动…"
    case .shutdown: "关机…"
    case .quitall: "全部退出"
    case .ejectall: "推出全部磁盘"
    case .volup: "调高音量"
    case .voldown: "调低音量"
    case .mute: "切换静音"
    }
  }

  /// Alfred 的英文名：只进 names 参与匹配（「screen」能搜到屏幕保护程序、锁定屏幕）
  var english: String {
    switch self {
    case .lock: "Lock Screen"
    case .sleep: "Sleep"
    case .sleepdisplays: "Sleep Displays"
    case .screensaver: "Screen Saver"
    case .trash: "Show Trash"
    case .emptytrash: "Empty Trash"
    case .logout: "Log Out"
    case .restart: "Restart"
    case .shutdown: "Shut Down"
    case .quitall: "Quit All Applications"
    case .ejectall: "Eject All"
    case .volup: "Volume Up"
    case .voldown: "Volume Down"
    case .mute: "Toggle Mute"
    }
  }

  /// 口语里的叫法（「锁屏」「重启」「屏保」「注销」…）：连拼音、首字母一起只进 names / initials，不显示
  var synonyms: [String] {
    switch self {
    case .lock: ["锁屏"]
    case .sleep: ["休眠"]
    case .sleepdisplays: ["息屏", "关屏", "显示器睡眠"]
    case .screensaver: ["屏保"]
    case .trash: ["废纸篓", "回收站"]
    case .emptytrash: ["清空废纸篓", "清空回收站"]
    case .logout: ["注销"]
    case .restart: ["重启"]
    case .shutdown: ["关闭电脑"]
    case .quitall: ["退出全部", "关闭所有应用"]
    case .ejectall: ["推出所有", "弹出全部"]
    case .volup: ["音量加", "大声"]
    case .voldown: ["音量减", "小声"]
    case .mute: ["静音", "取消静音"]
    }
  }

  var symbol: String {
    switch self {
    case .lock: "lock.fill"
    case .sleep: "moon.fill"
    case .sleepdisplays: "display"
    case .screensaver: "sparkles.tv"
    case .trash: "trash"
    case .emptytrash: "trash.slash"
    case .logout: "rectangle.portrait.and.arrow.right"
    case .restart: "arrow.clockwise"
    case .shutdown: "power"
    case .quitall: "xmark.circle"
    case .ejectall: "eject.fill"
    case .volup: "speaker.wave.3.fill"
    case .voldown: "speaker.wave.1.fill"
    case .mute: "speaker.slash.fill"
    }
  }

  /// 不可撤销、要再按一次 ↩ 的：上膛后选中行的副标题（退出登录 / 重新启动 / 关机由 macOS 自己弹确认框）
  var confirmation: String? {
    switch self {
    case .emptytrash: "再按 ↩ 清倒废纸篓，不能撤销"
    case .quitall: "再按 ↩ 退出所有打开的 App"
    default: nil
    }
  }
}

enum SystemCommands {
  /// 带对象的命令：关键词 = Alfred 的（kill 是 Raycast 的 Kill Process，体检 D12）
  enum Verb: String, CaseIterable {
    case quit, hide, forcequit, eject, kill

    /// ↩ 的动作名（底栏主动作、⌘K 第一行）
    var title: String {
      switch self {
      case .quit: "退出"
      case .hide: "隐藏"
      case .forcequit: "强制退出"
      case .eject: "推出"
      case .kill: "结束"
      }
    }

    var symbol: String {
      switch self {
      case .quit: "xmark.circle"
      case .hide: "eye.slash"
      case .forcequit: "xmark.octagon"
      case .eject: "eject"
      case .kill: "stop.circle"
      }
    }

    /// 只输关键词时那一行补全提示
    var prompt: String {
      switch self {
      case .quit: "退出正在运行的 App…"
      case .hide: "隐藏 App…"
      case .forcequit: "强制退出 App…"
      case .eject: "推出磁盘…"
      case .kill: "结束进程…"
      }
    }

    /// 补全提示里「关键词 空格 X」的 X
    var noun: String {
      switch self {
      case .eject: "磁盘名"
      case .kill: "进程名或 :端口"
      default: "App 名"
      }
    }

    /// 只输了关键词时的分组标题
    var groupTitle: String {
      switch self {
      case .eject: "可推出的磁盘"
      case .kill: "后台进程"
      default: "正在运行的 App"
      }
    }
  }

  struct Request: Equatable {
    var verb: Verb
    /// 空 = 只输了关键词加空格，列全部
    var terms: [String]
  }

  static let finderPath = "/System/Library/CoreServices/Finder.app"

  /// 强制退出上膛后的副标题（↩ 上膛写 ↩，quit / hide 里 ⌘↩ 上膛写 ⌘↩）
  static func forceQuitConfirmation(key: String) -> String {
    "再按 \(key) 强制退出，没存的内容会丢失"
  }

  /// kill 里 ⌘↩（SIGKILL）上膛后的副标题
  static let killConfirmation = "再按 ⌘↩ 强制结束，没存的内容会丢失"

  static let items: [LauncherItem] = SystemCommand.allCases.map { command in
    let chinese = [command.title] + command.synonyms
    let pinyin = chinese.compactMap { AppCatalog.pinyin($0) }
    return LauncherItem(
      kind: .system, target: command.rawValue, title: command.title, subtitle: command.rawValue,
      names: (chinese + [command.rawValue, command.english] + pinyin.map(\.full))
        .map(LauncherMatch.fold),
      initials: [LauncherMatch.initials(command.english)] + pinyin.map(\.initials))
  }

  // MARK: 纯函数（配单测）

  /// 「quit 词」「hide 词」「forcequit 词」「eject 词」「kill 词」；只输关键词不算（出补全提示，不抢同名 App），同 open / find。
  /// quitall / ejectall 是固定命令，不在这里
  static func request(for query: String) -> Request? {
    let lower = query.lowercased()
    for verb in Verb.allCases where lower.hasPrefix(verb.rawValue) {
      let rest = query.dropFirst(verb.rawValue.count)
      guard rest.first?.isWhitespace == true else { continue }
      return Request(verb: verb, terms: rest.split(whereSeparator: \.isWhitespace).map(String.init))
    }
    return nil
  }

  /// 单输（或拼到一半）quit / hide / forcequit / eject / kill 时的补全提示：正好是关键词的放最前，
  /// ≥ 2 个字的开头放本地结果后面（同文件搜索的 open / find）
  static func promptItems(for query: String) -> (exact: [LauncherItem], partial: [LauncherItem]) {
    let text = LauncherMatch.fold(query.trimmingCharacters(in: .whitespaces))
    var exact: [LauncherItem] = []
    var partial: [LauncherItem] = []
    for verb in Verb.allCases {
      let item = LauncherItem(
        kind: .prompt, target: "system-" + verb.rawValue, title: verb.prompt,
        subtitle: "输入「\(verb.rawValue) 空格 \(verb.noun)」，↩ 或 Tab 补全关键词",
        completion: verb.rawValue + " ")
      if text == verb.rawValue {
        exact.append(item)
      } else if text.count >= 2, verb.rawValue.hasPrefix(text) {
        partial.append(item)
      }
    }
    return (exact, partial)
  }

  /// quit / hide / forcequit / quitall 列哪些 App：程序坞里的普通 App（菜单栏 App、后台进程不列，同 Alfred），
  /// 不含本 App；访达没有「退出」，只能隐藏
  static func lists(
    bundleID: String?, policy: NSApplication.ActivationPolicy, isCurrent: Bool, for verb: Verb
  ) -> Bool {
    policy == .regular && !isCurrent && (verb == .hide || bundleID != "com.apple.finder")
  }

  /// 正在运行的 App 那一行：名字（LaunchServices 给的，已是中文名）、图标都从 NSRunningApplication 来，
  /// 不读 App 包里的文件——桌面 / 文稿 / 下载里跑着的 App（本地编译、解压出来的）读一下就会弹文件夹授权框
  static func appItem(name: String, path: String) -> LauncherItem {
    let fileName = URL(filePath: path).deletingPathExtension().lastPathComponent
    let pinyin = AppCatalog.pinyin(name)
    let names = [name, fileName, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) }
    return LauncherItem(
      kind: .app, target: path, title: name,
      subtitle: fileName != name ? fileName : AppCatalog.location(of: path),
      names: names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
      initials: [LauncherMatch.initials(fileName), pinyin?.initials].compactMap { $0 })
  }

  /// 能推出的宗卷：不是启动宗卷、访达里看得见，并且可推出、可移除或不在本机（网络宗卷）
  static func isEjectable(
    root: Bool?, browsable: Bool?, ejectable: Bool?, removable: Bool?, local: Bool?
  ) -> Bool {
    root != true && browsable != false
      && (ejectable == true || removable == true || local == false)
  }

  // MARK: 列举（只读）

  static func runningApps(for verb: Verb) -> [NSRunningApplication] {
    let current = ProcessInfo.processInfo.processIdentifier
    return NSWorkspace.shared.runningApplications.filter {
      lists(
        bundleID: $0.bundleIdentifier, policy: $0.activationPolicy,
        isCurrent: $0.processIdentifier == current, for: verb)
    }
  }

  /// 隐藏宗卷列举时就跳过（Xcode 模拟器运行时这类磁盘映像也报「可推出」，不跳过「推出全部」会把它卸掉）
  static func volumes() -> [URL] {
    let keys: [URLResourceKey] = [
      .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsEjectableKey,
      .volumeIsRemovableKey, .volumeIsLocalKey, .volumeLocalizedNameKey,
    ]
    let mounted = FileManager.default.mountedVolumeURLs(
      includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
    return (mounted ?? []).filter { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
      return isEjectable(
        root: values.volumeIsRootFileSystem, browsable: values.volumeIsBrowsable,
        ejectable: values.volumeIsEjectable, removable: values.volumeIsRemovable,
        local: values.volumeIsLocal)
    }
  }

  static func volumeName(_ url: URL) -> String {
    (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
      ?? url.lastPathComponent
  }

  /// 带对象模式的行：App 行（图标先放进 LauncherIcons 的缓存，行里不按路径读；中文名 / 拼音能搜；前台 App 排第一，
  /// 其余按名字）、宗卷行（按类型取通用宗卷图标，不碰宗卷本身）；Tab 补成「关键词 名字」
  static func targets(for verb: Verb) -> [LauncherItem] {
    guard verb != .kill else { return [] }  // 进程在进程外异步列（Processes.targets）
    let items: [LauncherItem]
    if verb == .eject {
      items = volumes().map { url in
        let name = volumeName(url)
        return LauncherItem(
          kind: .path, target: url.path, title: name, subtitle: url.path,
          names: [LauncherMatch.fold(name)], contentType: .volume)
      }
    } else {
      let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
      items = runningApps(for: verb)
        .sorted { a, b in
          let (aFront, bFront) = (a.processIdentifier == front, b.processIdentifier == front)
          if aFront != bFront { return aFront }
          return (a.localizedName ?? "").localizedStandardCompare(b.localizedName ?? "")
            == .orderedAscending
        }
        .compactMap { app -> LauncherItem? in
          guard let url = app.bundleURL else { return nil }
          if let icon = app.icon { LauncherIcons.remember(icon, for: url.path) }
          return appItem(
            name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, path: url.path
          )
        }
    }
    var seen = Set<String>()
    return items.filter { seen.insert($0.id).inserted }.map {
      var item = $0
      item.completion = verb.rawValue + " " + item.title
      return item
    }
  }
}
