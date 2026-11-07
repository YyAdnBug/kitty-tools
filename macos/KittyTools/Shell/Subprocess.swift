// 跑系统自带的命令行工具：在进程外、不占主线程，等它结束拿退出码（和输出）。应用内更新的 ditto / codesign、
// 启动器系统命令的 pmset / osascript、kill 列进程的 ps / lsof、读浏览器浏览历史（和 Firefox 书签）的 sqlite3 都走这里
// （mac-native §3：进程外 + continuation）。剪贴板后台识字起的子进程（本 App 自己带 --ocr，OCR.recognizeTextInHelper）也走这里。
// 启动器的脚本命令（ScriptRunner）也走这里：多了工作目录、任务取消时停掉子进程、只读输出的前一截（写得比上限的 4 倍还多就停掉，
// 不让 `yes` 这种把临时目录写满）。停掉是先 SIGTERM、1 秒后还在就 SIGKILL（交互模式的 zsh 不理 SIGTERM，评审实测）。
// 标准输入一律接空设备：等输入的脚本读到的是文件结尾，不会一直挂着。

import Foundation

enum Subprocess {
  struct Result {
    var status: Int32
    var output = ""
    var error = ""
    /// 被信号结束的（超时、取消时的 SIGTERM，或者脚本自己被杀）：status 是信号编号
    var signaled = false
    /// 输出写超了（outputLimit 的 4 倍）被停掉的
    var overflowed = false
  }

  /// 正在跑的那个进程：取消处理在别的线程上调，只能经主线程拿它（主线程隔离的类是 Sendable）
  private final class Running {
    var process: Process?
    var overflowed = false
  }

  /// 停掉：先 SIGTERM，1 秒后还在就 SIGKILL
  private static func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let pid = process.processIdentifier
    Task {
      try? await Task.sleep(for: .seconds(1))
      if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) }
    }
  }

  /// captures = false 时输出直接丢掉。要的输出写进临时文件、结束后一次读完：管道缓冲只有 64 KB，
  /// 写满了子进程就卡住、等不到它结束（sqlite3 导出的浏览历史约 460 KB，ps 列几百个进程也可能超）。
  /// environment：不给就继承本进程的；timeout：到点还没结束就杀掉（SIGTERM，拿到的是非零状态；杀它的任务在主线程上，
  /// 主线程卡着时会晚到，只当兜底用）；
  /// quality：子进程的优先级（不急的活给 .utility）；directory：工作目录（不给就继承）；
  /// stopsOnCancel：调用它的任务被取消时停掉子进程（SIGTERM；脚本的「停止」、列表打字时撤掉上一次）——别的调用方
  /// 照旧跑完（应用内更新解包、验签那一两秒不能停）；outputLimit：输出只读前这么多字节
  static func run(
    _ tool: String, _ arguments: [String], captures: Bool = false,
    environment: [String: String]? = nil, timeout: Duration? = nil,
    quality: QualityOfService = .default, directory: URL? = nil, stopsOnCancel: Bool = false,
    outputLimit: Int? = nil
  ) async throws -> Result {
    let running = Running()
    return try await withTaskCancellationHandler {
      try await run(
        tool, arguments, captures: captures, environment: environment, timeout: timeout,
        quality: quality, directory: directory, outputLimit: outputLimit, running: running,
        stopsOnCancel: stopsOnCancel)
    } onCancel: {
      if stopsOnCancel { Task { @MainActor in running.process.map(stop) } }
    }
  }

  private static func run(
    _ tool: String, _ arguments: [String], captures: Bool, environment: [String: String]?,
    timeout: Duration?, quality: QualityOfService, directory: URL?, outputLimit: Int?,
    running: Running, stopsOnCancel: Bool
  ) async throws -> Result {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.qualityOfService = quality
    process.standardInput = FileHandle.nullDevice
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = directory }
    let watchdog = timeout.map { limit in
      Task {
        try? await Task.sleep(for: limit)
        if !Task.isCancelled { stop(process) }
      }
    }
    defer { watchdog?.cancel() }
    let files = captures ? [temporaryFile(), temporaryFile()] : []
    defer {
      for file in files { try? FileManager.default.removeItem(at: file) }
    }
    // 输出有上限的（脚本）：每 0.25 秒看一眼临时文件，写到上限的 4 倍就停掉
    let sizeWatch = (captures ? outputLimit : nil).map { limit in
      Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          let sizes = files.map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0
          }
          if sizes.contains(where: { $0 > limit * 4 }) {
            running.overflowed = true
            return stop(process)
          }
        }
      }
    }
    defer { sizeWatch?.cancel() }
    if captures {
      for file in files { FileManager.default.createFile(atPath: file.path, contents: nil) }
      process.standardOutput = try FileHandle(forWritingTo: files[0])
      process.standardError = try FileHandle(forWritingTo: files[1])
    } else {
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
    }
    let (status, signaled): (Int32, Bool) = try await withCheckedThrowingContinuation {
      continuation in
      process.terminationHandler = {
        continuation.resume(
          returning: ($0.terminationStatus, $0.terminationReason == .uncaughtSignal))
      }
      do {
        try process.run()
        running.process = process
        // 起之前就取消了：取消处理那时还拿不到进程
        if stopsOnCancel, Task.isCancelled { stop(process) }
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    running.process = nil
    // 只关自己开的（nullDevice 是共用的，关了别处就写不进去了）
    if captures {
      for handle in [process.standardOutput, process.standardError] {
        try? (handle as? FileHandle)?.close()
      }
    }
    func read(_ index: Int) -> String {
      guard files.indices.contains(index) else { return "" }
      let data: Data?
      if let outputLimit {
        let handle = try? FileHandle(forReadingFrom: files[index])
        data = try? handle?.read(upToCount: outputLimit)
        try? handle?.close()
      } else {
        data = try? Data(contentsOf: files[index])
      }
      return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    return Result(
      status: status, output: read(0), error: read(1), signaled: signaled,
      overflowed: running.overflowed)
  }

  private static func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "kitty-\(UUID().uuidString)")
  }
}
