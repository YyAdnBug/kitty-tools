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
    let path = if let path { path } else { await searchPath() }
    let environment = ScriptCommand.environment(
      inherited: ProcessInfo.processInfo.environment, path: path, script: script,
      dataDirectory: AppDelegate.supportDirectory.path, version: version,
      language: ScriptCommand.language(.current))
    let tool = script.interpreter[0]
    let limit = script.limit
    let started = ContinuousClock.now
    do {
      let result = try await Subprocess.run(
        tool, Array(script.interpreter.dropFirst()) + [script.path] + arguments, captures: true,
        environment: environment, timeout: limit > 0 ? .seconds(limit) : nil,
        quality: .userInitiated, directory: URL(filePath: script.folder), stopsOnCancel: true,
        outputLimit: outputLimit)
      if Task.isCancelled {
        return Outcome(end: .stopped, output: result.output, error: result.error)
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

  /// 给脚本的 PATH：终端里的（偏好里记着的，没有就读一遍）+ 固定目录
  static func searchPath() async -> String {
    if let saved = UserDefaults.standard.string(forKey: Prefs.scriptShellPath) {
      return ScriptCommand.searchPath(login: saved)
    }
    guard !loginReadFailed else { return ScriptCommand.searchPath(login: nil) }
    let login = await readLoginPath()
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

  /// 脚本全文（给用户看一眼的那一页）：最多读 64 KB，在主线程外读（文件夹可能在网络盘上）
  @concurrent static func text(of path: String) async -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 64 * 1024)) ?? nil
    return String(decoding: data ?? Data(), as: UTF8.self)
  }

  // MARK: 从网上下载的

  /// 带隔离标记（浏览器、聊天软件下载的文件系统都会打上）：第一次跑之前先给用户看一眼
  nonisolated static func isDownloaded(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
  }

  /// 确认过：去掉隔离标记（文件夹只读、去不掉的，由调用方这次运行里记着）
  @concurrent static func clearDownloaded(_ path: String) async -> Bool {
    var url = URL(filePath: path)
    var values = URLResourceValues()
    values.quarantineProperties = nil
    do {
      try url.setResourceValues(values)
      return !isDownloaded(url)
    } catch {
      return false
    }
  }
}
