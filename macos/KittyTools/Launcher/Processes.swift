// 启动器「kill 空格」列的后台进程（体检 D12，PLAN §10 M13；对标 Raycast Kill Process）：当前用户的非 GUI 进程——
// 程序坞里的普通 App 走 quit / forcequit，本 App 不列；菜单栏 App、node、python 这类都在。/bin/ps 取 PID、内存、
// 可执行文件，/usr/sbin/lsof 取在监听的 TCP 端口，都用 Subprocess 在进程外跑（ps 约 10 ms、lsof 约 25 ms）。
// 行：进程名 /「PID 4321 · 312 MB · 监听 :3000」/ 右侧「进程」；names 里放 PID 和「:端口」，「kill 4321」直接按匹配走，
// 「kill :3000」「kill :」只按端口筛（listens：进程名里也可能有冒号）。监听端口的排前面，再是不在系统目录里的，再按内存从大到小。
// 不列：本 App 起的子进程（这次跑的 ps、lsof）、loginwindow（结束它 = 立刻退出登录）。
// 「port 空格」（2026-10-08，对标 Raycast Port Manager）是同一份数据的端口视图：一个在监听的端口一行、按端口号排，
// 行：「:3000」/「node · PID 4321 · ~/项目目录」。和 kill 不一样的三处：程序坞里的普通 App 也列（问「谁占着这个端口」
// 得答得出来；记下包路径，↩ 走正常退出）；多跑一次 lsof 取这些进程的工作目录（同名的几个 node 靠它分清是哪个项目）；
// 同一个端口父子进程都在监听时（nginx 的 master / worker）只列父进程——结束子进程，父进程会再拉一个，端口还占着。
// 这里只解析（纯函数配单测）和列举；结束在 SystemControl（kill(2)，App 是 terminate）。

import AppKit

enum Processes {
  nonisolated struct Entry: Hashable {
    let pid: Int32
    /// 常驻内存（字节）
    let memory: Int64
    /// 可执行文件的完整路径（ps 的 comm）
    let path: String
    var ports: [Int] = []
    var ppid: Int32 = 0
    /// 程序坞里的普通 App（只有 port 列它们）：↩ 走正常退出，不发信号
    var app: App?

    /// 包路径（按它找正在运行的 App）和显示名
    nonisolated struct App: Hashable {
      let path: String
      let name: String
    }

    var name: String { (path as NSString).lastPathComponent }

    /// 行里、确认提示里怎么叫它：App 用显示名（「微信」，不是 WeChat）
    var label: String { app?.name ?? name }

    /// 系统自带的（排在后面，免得几百个系统服务把 node、python 挤到下面）
    var isSystem: Bool {
      [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
        "/Library/Apple/",
      ]
      .contains { path.hasPrefix($0) }
    }
  }

  /// `ps -U <用户名> -o pid=,ppid=,rss=,comm=` 的输出：每行「PID 父 PID 内存(KB) 路径」，路径里可能有空格
  nonisolated static func parse(ps output: String) -> [Entry] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
      guard fields.count == 4, let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
        let rss = Int64(fields[2])
      else { return nil }
      return Entry(pid: pid, memory: rss * 1024, path: String(fields[3]), ppid: ppid)
    }
  }

  /// lsof `-F pn` 的输出：p 行是 PID，f 行是文件描述符，n 行是它的名字。在监听的（`-iTCP -sTCP:LISTEN`）名字是
  /// 「地址:端口」（IPv4、IPv6 各一行时端口相同）；工作目录（`-d cwd`，f 行是 cwd）名字是路径——路径里也可能有冒号，
  /// 所以按 f 行分，不按长相猜
  nonisolated static func parse(lsof output: String) -> (
    ports: [Int32: [Int]], directories: [Int32: String]
  ) {
    var ports: [Int32: Set<Int>] = [:]
    var directories: [Int32: String] = [:]
    var pid: Int32?
    var isDirectory = false
    for line in output.split(whereSeparator: \.isNewline) {
      switch line.first {
      case "p":
        pid = Int32(line.dropFirst())
        isDirectory = false
      case "f": isDirectory = line.dropFirst() == "cwd"
      case "n":
        guard let pid else { continue }
        if isDirectory {
          directories[pid] = String(line.dropFirst())
        } else if let colon = line.lastIndex(of: ":"),
          let port = Int(line[line.index(after: colon)...])
        {
          ports[pid, default: []].insert(port)
        }
      default: continue
      }
    }
    return (ports.mapValues { $0.sorted() }, directories)
  }

  /// 不列的：结束 loginwindow 等于立刻退出登录、没存的全丢。ps -U 按真实用户列，它的真实用户是 root，平时列不到；
  /// 按路径再挡一道
  static let unlisted: Set<String> = [
    "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
  ]

  /// 行：去掉普通 App 和本 App（excluded）、本 App 起的子进程（这次的 ps、lsof）、unlisted，
  /// 按「监听端口的 → 不是系统的 → 内存大的」排
  static func items(_ entries: [Entry], ports: [Int32: [Int]], excluding excluded: Set<Int32>)
    -> [LauncherItem]
  {
    let own = ProcessInfo.processInfo.processIdentifier
    return entries.filter {
      !excluded.contains($0.pid) && $0.ppid != own && !unlisted.contains($0.path)
    }
    .map { entry in
      var entry = entry
      entry.ports = ports[entry.pid] ?? []
      return entry
    }
    .sorted { a, b in
      if a.ports.isEmpty != b.ports.isEmpty { return !a.ports.isEmpty }
      if a.isSystem != b.isSystem { return !a.isSystem }
      return a.memory > b.memory
    }
    .map(item)
  }

  static func item(_ entry: Entry) -> LauncherItem {
    let memory = entry.memory.formatted(
      .byteCount(style: .memory).locale(Locale(identifier: "zh-Hans")))
    var parts = ["PID \(entry.pid)", memory]
    if !entry.ports.isEmpty {
      parts.append("监听 " + entry.ports.map { ":\($0)" }.joined(separator: "、"))
    }
    return LauncherItem(
      kind: .process, target: String(entry.pid), title: entry.name,
      subtitle: parts.joined(separator: " · "),
      // 端口排在第 3 个起（listens 按这个位置取）
      names: [LauncherMatch.fold(entry.name), String(entry.pid)] + entry.ports.map { ":\($0)" },
      completion: "kill " + entry.name, process: entry)
  }

  /// 「kill :30」：监听的端口里有以它开头的（「:」= 在监听任意端口）
  static func listens(_ item: LauncherItem, on term: String) -> Bool {
    item.names.dropFirst(2).contains { $0.hasPrefix(term) }
  }

  /// port 的行：一个在监听的端口一行（一个进程监听几个就有几行，目标「PID:端口」各不相同），按端口号排。
  /// 不列本 App 和它起的子进程、unlisted；父进程也在监听同一个端口的不列（见文件头）。
  /// apps：程序坞里的普通 App（按 PID），行里写显示名、不写工作目录（是它的沙盒容器，没用）；
  /// 别的进程写工作目录（根目录不写：守护进程都在那）。names：端口号、名字、工作目录都能搜
  static func portItems(
    _ entries: [Entry], ports: [Int32: [Int]], directories: [Int32: String],
    apps: [Int32: Entry.App]
  ) -> [LauncherItem] {
    let own = ProcessInfo.processInfo.processIdentifier
    return entries.filter { $0.pid != own && $0.ppid != own && !unlisted.contains($0.path) }
      .flatMap { entry in
        (ports[entry.pid] ?? []).filter { ports[entry.ppid]?.contains($0) != true }
          .map { (port: $0, entry: entry) }
      }
      .sorted { ($0.port, $0.entry.pid) < ($1.port, $1.entry.pid) }
      .map { port, entry in
        var entry = entry
        entry.app = apps[entry.pid]
        let directory =
          entry.app == nil
          ? directories[entry.pid].flatMap {
            $0 == "/" ? nil : ($0 as NSString).abbreviatingWithTildeInPath
          } : nil
        return LauncherItem(
          kind: .process, target: "\(entry.pid):\(port)", title: ":\(port)",
          subtitle: ([entry.label, "PID \(entry.pid)"] + [directory].compactMap { $0 })
            .joined(separator: " · "),
          names: ([String(port), entry.label, entry.name] + [directory].compactMap { $0 })
            .map(LauncherMatch.fold),
          completion: "port \(port)", process: entry)
      }
  }

  /// ps、lsof（在监听的端口）同时在进程外跑
  private static func snapshot() async -> (entries: [Entry], ports: [Int32: [Int]]) {
    async let ps = try? Subprocess.run(
      "/bin/ps", ["-U", NSUserName(), "-o", "pid=,ppid=,rss=,comm="], captures: true)
    async let lsof = try? Subprocess.run(
      "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], captures: true)
    let (processes, listening) = await (ps, lsof)
    return (parse(ps: processes?.output ?? ""), parse(lsof: listening?.output ?? "").ports)
  }

  /// 进 kill 模式时列一次；程序坞里的普通 App 和本 App 不列
  static func targets() async -> [LauncherItem] {
    let (entries, ports) = await snapshot()
    var excluded = Set(
      NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .map(\.processIdentifier))
    excluded.insert(ProcessInfo.processInfo.processIdentifier)
    return items(entries, ports: ports, excluding: excluded)
  }

  /// 进 port 模式时列一次：比 kill 多一次 lsof，取在监听的那几个进程的工作目录（本机 459 个进程、20 个在监听实测：
  /// 只取这几个约 30 ms，连监听一起一次全取约 100 ms）。取工作目录只读元数据，不触发文件夹授权（实测：工作目录在
  /// 受保护目录里、本进程列不了那个目录时照样取得到）。lsof 会碰各个挂载点，卡住的网络盘上可能回不来：2 秒没回就不带目录。
  /// 在监听的程序坞 App 的图标先放进缓存，行里不按路径读 App 包（同 quit 的行）
  static func portTargets() async -> [LauncherItem] {
    let (entries, ports) = await snapshot()
    var directories: [Int32: String] = [:]
    if !ports.isEmpty {
      let pids = ports.keys.map(String.init).joined(separator: ",")
      let result = try? await Subprocess.run(
        "/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids, "-Fpn"], captures: true,
        timeout: .seconds(2))
      directories = parse(lsof: result?.output ?? "").directories
    }
    var apps: [Int32: Entry.App] = [:]
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && ports[app.processIdentifier] != nil {
      guard let url = app.bundleURL else { continue }
      if let icon = app.icon { LauncherIcons.remember(icon, for: url.path) }
      apps[app.processIdentifier] = Entry.App(
        path: url.path, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent)
    }
    return portItems(entries, ports: ports, directories: directories, apps: apps)
  }
}
