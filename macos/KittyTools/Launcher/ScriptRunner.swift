// 跑一条脚本命令（2026-11-07 拍板 B3 B4 B5，PLAN §10「脚本命令」）：按 #! 调解释器（脚本路径接在 #! 的参数后面，再接用户给的参数），
// 在进程外跑（Subprocess：工作目录是脚本所在的文件夹、标准输入是空的、默认 60 秒超时、任务取消时停掉、输出只读前 1 MB）。
// 环境只给几样（ScriptCommand.environment），PATH 用用户终端里的：第一次用到时用登录 shell（$SHELL -l -i）读一遍，记在偏好里
// （这台电脑自己的，不注册默认值、不导出；设置页能「重新读取」），3 秒没读到就用固定目录（同 Alfred 5），这次运行里不再试。
// 从网上下载的（带隔离标记）在主线程外看、确认过之后去掉标记（B5）。结果怎么交出去（岛 / 粘贴 / 复制）在 LauncherModel。
// ponytail: 超时、停止只给脚本本身发 SIGTERM，它起的子进程（sleep、curl）可能留着跑完；真碰上了再按进程组结束。

import Foundation

enum ScriptRunner {
  struct Outcome: Equatable, Sendable {
    enum End: Equatable, Sendable {
      /// 跑完了，退出码
      case finished(Int32)
      /// 到了超时被停掉
      case timedOut
      /// 用户点了「停止」、或者列表打字撤掉了
      case stopped
      /// 起不来（解释器不在）：原因
      case failedToStart(String)
      /// 输出写得太多（上限的 4 倍）被停掉
      case tooMuchOutput
    }

    var end: End
    var output = ""
    var error = ""

    var succeeded: Bool { end == .finished(0) }
  }

  /// 输出最多读这么多（B4）
  static let outputLimit = 1 << 20

  /// path：给脚本的 PATH（单测传固定的，不读写偏好）；不给就用 searchPath()
  static func run(_ script: ScriptCommand, arguments: [String], path: String? = nil) async
    -> Outcome
  {
    // 扫描之后才换成了下载来的（用下载的新版本盖掉了同名的、还没重读）：不跑，重读之后先给人看全文（第三轮评审）
    if !script.isDownloaded, !script.isBundled, await isDownloadedNow(script.path) {
      return Outcome(end: .failedToStart("这个脚本刚换成了从网上下载的：重新打开启动器，先看一眼全文再运行"))
    }
    let path = if let path { path } else { await searchPath() }
    // 等读 PATH（第一次用时最多 3 秒）那会儿被撤掉的（列表打字）：不再起进程
    if Task.isCancelled { return Outcome(end: .stopped) }
    let environment = ScriptCommand.environment(
      inherited: ProcessInfo.processInfo.environment, path: path, script: script,
      dataDirectory: AppDelegate.supportDirectory.path, version: version,
      language: ScriptCommand.language(.current))
    let tool = script.interpreter[0]
    let limit = script.limit
    let started = ContinuousClock.now
    do {
      let result = try await Subprocess.run(
        tool, Array(script.interpreter.dropFirst()) + [script.path] + script.passed(arguments),
        captures: true,
        environment: environment, timeout: limit > 0 ? .seconds(limit) : nil,
        quality: .userInitiated, directory: URL(filePath: script.folder), stopsOnCancel: true,
        outputLimit: outputLimit)
      if Task.isCancelled {
        return Outcome(end: .stopped, output: result.output, error: result.error)
      }
      if result.overflowed {
        return Outcome(end: .tooMuchOutput, output: result.output, error: result.error)
      }
      // 被信号结束、而且已经到点：是超时停掉的（脚本自己被别人杀了的算出错）
      if result.signaled, limit > 0,
        ContinuousClock.now - started >= .seconds(limit) - .milliseconds(200)
      {
        return Outcome(end: .timedOut, output: result.output, error: result.error)
      }
      return Outcome(end: .finished(result.status), output: result.output, error: result.error)
    } catch {
      let reason =
        FileManager.default.fileExists(atPath: tool)
        ? error.localizedDescription : "找不到 \(tool)（第一行 #! 写的）"
      return Outcome(end: .failedToStart(reason))
    }
  }

  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  // MARK: PATH

  /// 这次运行里读过、没读到：不再每跑一个脚本都等 3 秒
  private static var loginReadFailed = false
  /// 正在读的那一次：几个脚本一起等它，不各起一个 shell；不跟着哪个脚本被撤掉（列表打字时一直在撤）
  private static var loginRead: Task<String?, Never>?

  /// 给脚本的 PATH：终端里的（偏好里记着的，没有就读一遍）+ 固定目录
  static func searchPath() async -> String {
    if let saved = UserDefaults.standard.string(forKey: Prefs.scriptShellPath) {
      return ScriptCommand.searchPath(login: saved)
    }
    guard !loginReadFailed else { return ScriptCommand.searchPath(login: nil) }
    let read = loginRead ?? Task { await readLoginPath() }
    loginRead = read
    let login = await read.value
    loginRead = nil
    if let login {
      UserDefaults.standard.set(login, forKey: Prefs.scriptShellPath)
    } else {
      loginReadFailed = true
    }
    return ScriptCommand.searchPath(login: login)
  }

  /// 设置页「重新读取」：忘掉记着的，下次跑脚本时重读
  static func forgetSearchPath() {
    UserDefaults.standard.removeObject(forKey: Prefs.scriptShellPath)
    loginReadFailed = false
  }

  /// 用户的登录 shell 打印一遍 PATH（-l 读 .zprofile、-i 读 .zshrc：nvm、pyenv 都在这两处）；3 秒没回就算了
  static func readLoginPath() async -> String? {
    let inherited = ProcessInfo.processInfo.environment
    let shell = inherited["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
    var environment = inherited.filter { ScriptCommand.inheritedKeys.contains($0.key) }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["TERM"] = "dumb"
    let command = "printf '\\n%s%s\\n' \(ScriptCommand.pathMarker) \"$PATH\""
    let result = try? await Subprocess.run(
      shell, ["-l", "-i", "-c", command], captures: true, environment: environment,
      timeout: .seconds(3), quality: .userInitiated, stopsOnCancel: true)
    return result.flatMap { ScriptCommand.shellPath(fromOutput: $0.output) }
  }

  /// 给用户看一眼的那一页最多显示这么多（再多 SwiftUI 的 Text 排不动；比这还大的脚本写明没显示全、别运行）
  nonisolated static let reviewLimit = 256 * 1024

  /// 脚本全文（给用户看一眼的那一页、导入前的表单）：最多读 reviewLimit + 1 字节；在主线程外读（文件夹可能在网络盘上）
  @concurrent static func read(_ path: String) async -> ScriptReading {
    guard let handle = FileHandle(forReadingAtPath: path) else { return ScriptReading(nil) }
    defer { try? handle.close() }
    do {
      return ScriptReading(try handle.read(upToCount: reviewLimit + 1) ?? Data())
    } catch {
      return ScriptReading(nil)
    }
  }

  // MARK: 从网上下载的

  /// 带隔离标记（浏览器、聊天软件下载的文件系统都会打上）：第一次跑之前先给用户看一眼。符号链接本身和它指向的文件都看
  /// （第三轮评审：读标记不跟着链接走，`ln -s ~/Downloads/x.sh` 放进来的会被当成自己写的）
  nonisolated static func isDownloaded(_ url: URL) -> Bool {
    [url, url.resolvingSymlinksInPath()].contains {
      (try? $0.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
    }
  }

  /// 同上，在主线程外问（跑之前再看一眼：文件夹可能在网络盘上）
  @concurrent static func isDownloadedNow(_ path: String) async -> Bool {
    isDownloaded(URL(filePath: path))
  }

  /// 确认过：去掉隔离标记，链接本身和它指向的都去（文件夹只读、去不掉的，由调用方这次运行里记着）
  @concurrent static func clearDownloaded(_ path: String) async -> Bool {
    let link = URL(filePath: path)
    for var url in Set([link, link.resolvingSymlinksInPath()]) {
      var values = URLResourceValues()
      values.quarantineProperties = nil
      try? url.setResourceValues(values)
    }
    return !isDownloaded(link)
  }
}

/// 读出来给人看一眼的脚本（看全文那一页、导入前的表单；第三轮评审）：存的字节、显示的文字，和不能放行的原因
nonisolated struct ScriptReading: Equatable, Sendable {
  /// 原样的字节（最多 reviewLimit）：导入、从剪贴板新建存的就是这一份，不再回头去复制源文件——看的和存的是同一份
  let data: Data
  /// 显示用：会打乱显示顺序的隐藏字符换成看得见的（ScriptCommand.revealed）
  let text: String
  /// 比能显示的长：没看全
  let isTruncated: Bool
  /// 藏着会打乱显示顺序的字符
  let hasHidden: Bool
  /// 读不出来
  let isUnreadable: Bool

  /// data 是 nil：读不出来
  init(_ data: Data?, limit: Int = ScriptRunner.reviewLimit) {
    let bytes = data ?? Data()
    isUnreadable = data == nil
    isTruncated = bytes.count > limit
    self.data = bytes.prefix(limit)
    (text, hasHidden) = ScriptCommand.revealed(String(decoding: self.data, as: UTF8.self))
  }

  /// 看完了也不能运行 / 导入的原因（后面由调用方接「不能在这里运行」「不能导入」）；nil = 可以
  var problem: String? {
    if isUnreadable { return "读不出这个文件。" }
    if hasHidden {
      return "这个文件里藏着会打乱显示顺序的字符（下面标成了 ⟦U+202E⟧ 这样），看到的和真正会跑的可能不一样。"
    }
    if isTruncated { return "这个文件超过 \(ScriptRunner.reviewLimit / 1024) KB，下面只显示了开头。" }
    return nil
  }
}
