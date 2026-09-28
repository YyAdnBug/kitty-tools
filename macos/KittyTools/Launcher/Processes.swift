// 启动器「kill 空格」列的后台进程（体检 D12，PLAN §10 M13；对标 Raycast Kill Process）：当前用户的非 GUI 进程——
// 程序坞里的普通 App 走 quit / forcequit，本 App 不列；菜单栏 App、node、python 这类都在。/bin/ps 取 PID、内存、
// 可执行文件，/usr/sbin/lsof 取在监听的 TCP 端口，都用 Subprocess 在进程外跑（ps 约 10 ms、lsof 约 25 ms）。
// 行：进程名 /「PID 4321 · 312 MB · 监听 :3000」/ 右侧「进程」；names 里放 PID 和「:端口」，「kill 4321」直接按匹配走，
// 「kill :3000」「kill :」只按端口筛（listens：进程名里也可能有冒号）。监听端口的排前面，再是不在系统目录里的，再按内存从大到小。
// 不列：本 App 起的子进程（这次跑的 ps、lsof）、loginwindow（结束它 = 立刻退出登录）。
// 这里只解析（纯函数配单测）和列举；结束在 SystemControl（kill(2)）。

import AppKit

enum Processes {
  nonisolated struct Entry: Equatable {
    let pid: Int32
    /// 常驻内存（字节）
    let memory: Int64
    /// 可执行文件的完整路径（ps 的 comm）
    let path: String
    var ports: [Int] = []
    var ppid: Int32 = 0

    var name: String { (path as NSString).lastPathComponent }

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

  /// `lsof -nP -iTCP -sTCP:LISTEN -Fpn` 的输出：p 行是 PID，n 行是「地址:端口」（IPv4、IPv6 各一行时端口相同）
  nonisolated static func parse(lsof output: String) -> [Int32: [Int]] {
    var ports: [Int32: Set<Int>] = [:]
    var pid: Int32?
    for line in output.split(whereSeparator: \.isNewline) {
      switch line.first {
      case "p": pid = Int32(line.dropFirst())
      case "n":
        guard let pid, let colon = line.lastIndex(of: ":"),
          let port = Int(line[line.index(after: colon)...])
        else { continue }
        ports[pid, default: []].insert(port)
      default: continue
      }
    }
    return ports.mapValues { $0.sorted() }
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
      completion: "kill " + entry.name)
  }

  /// 「kill :30」：监听的端口里有以它开头的（「:」= 在监听任意端口）
  static func listens(_ item: LauncherItem, on term: String) -> Bool {
    item.names.dropFirst(2).contains { $0.hasPrefix(term) }
  }

  /// 进 kill 模式时列一次：ps、lsof 同时在进程外跑；程序坞里的普通 App 和本 App 不列
  static func targets() async -> [LauncherItem] {
    async let ps = try? Subprocess.run(
      "/bin/ps", ["-U", NSUserName(), "-o", "pid=,ppid=,rss=,comm="], captures: true)
    async let lsof = try? Subprocess.run(
      "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], captures: true)
    let (processes, listening) = await (ps, lsof)
    var excluded = Set(
      NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .map(\.processIdentifier))
    excluded.insert(ProcessInfo.processInfo.processIdentifier)
    return items(
      parse(ps: processes?.output ?? ""), ports: parse(lsof: listening?.output ?? ""),
      excluding: excluded)
  }
}
