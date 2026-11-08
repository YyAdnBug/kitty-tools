// 跑系统自带的命令行工具：在进程外、不占主线程，等它结束拿退出码（和输出）。应用内更新的 ditto / codesign、
// 启动器系统命令的 pmset / osascript、kill 列进程的 ps / lsof、读浏览器浏览历史（和 Firefox 书签）的 sqlite3 都走这里
// （mac-native §3：进程外 + continuation）。剪贴板后台识字起的子进程（本 App 自己带 --ocr，OCR.recognizeTextInHelper）也走这里。
// 启动器的脚本命令（ScriptRunner）也走这里：多了工作目录、任务取消时停掉子进程、只读输出的前一截（写得比上限的 4 倍还多就停掉，
// 不让 `yes` 这种把临时目录写满）。停掉是先 SIGTERM、1 秒后还在就 SIGKILL（交互模式的 zsh 不理 SIGTERM，评审实测）。
// 全文输出的脚本边跑边看（脚本命令第三轮 A1）：给了 live 就把错误输出并进标准输出（同终端），每 0.25 秒交一次写到现在的。
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
  /// 照旧跑完（应用内更新解包、验签那一两秒不能停）；outputLimit：输出只读前这么多字节；
  /// live：边跑边拿输出（要和 captures、outputLimit 一起给）：错误输出并进标准输出，结果的 error 是空的
  static func run(
    _ tool: String, _ arguments: [String], captures: Bool = false,
    environment: [String: String]? = nil, timeout: Duration? = nil,
    quality: QualityOfService = .default, directory: URL? = nil, stopsOnCancel: Bool = false,
    outputLimit: Int? = nil, live: ((String) -> Void)? = nil
  ) async throws -> Result {
    let running = Running()
    return try await withTaskCancellationHandler {
      try await run(
        tool, arguments, captures: captures, environment: environment, timeout: timeout,
        quality: quality, directory: directory, outputLimit: outputLimit, live: live,
        running: running, stopsOnCancel: stopsOnCancel)
    } onCancel: {
      if stopsOnCancel { Task { @MainActor in running.process.map(stop) } }
    }
  }

  private static func run(
    _ tool: String, _ arguments: [String], captures: Bool, environment: [String: String]?,
    timeout: Duration?, quality: QualityOfService, directory: URL?, outputLimit: Int?,
    live: ((String) -> Void)?, running: Running, stopsOnCancel: Bool
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
    // 边跑边看的只有一个文件：两路写进同一个句柄（共用写到哪儿），先后和终端里一样
    let files =
      captures ? (live == nil ? [temporaryFile(), temporaryFile()] : [temporaryFile()]) : []
    defer {
      for file in files { try? FileManager.default.removeItem(at: file) }
    }
    // 输出有上限的（脚本）：每 0.25 秒看一眼临时文件，写到上限的 4 倍就停掉；边跑边看的顺手把写到现在的交出去
    let sizeWatch = (captures ? outputLimit : nil).map { limit in
      Task {
        var shown = 0
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          // 进程结束了（这个任务被撤掉）：临时文件可能已经删了，别再交一个空的出去（第 1 批评审）
          guard !Task.isCancelled else { return }
          let sizes = files.map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0
          }
          if sizes.contains(where: { $0 > limit * 4 }) {
            running.overflowed = true
            return stop(process)
          }
          // ponytail: 每次从头读（最多 outputLimit），1 MB 一秒读 4 遍（几毫秒）；真碰上慢了再只读新增的那段。错误输出并进来后
          // 和标准输出共用这 1 MB（写在错误输出里的进度条也算），真把结果挤出去了再分开读
          if let live, let size = sizes.first, size != shown, shown <= limit {
            shown = size
            live(decodedPrefix(of: files[0], limit: limit))
          }
        }
      }
    }
    defer { sizeWatch?.cancel() }
    if captures {
      for file in files { FileManager.default.createFile(atPath: file.path, contents: nil) }
      process.standardOutput = try FileHandle(forWritingTo: files[0])
      process.standardError =
        live == nil ? try FileHandle(forWritingTo: files[1]) : process.standardOutput
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
    // 只关自己开的（nullDevice 是共用的，关了别处就写不进去了；边跑边看的两路是同一个，关一次）
    if captures {
      for handle in Set(
        [process.standardOutput, process.standardError].compactMap { $0 as? FileHandle })
      {
        try? handle.close()
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

  /// 边跑边看：读前 limit 字节，末尾写到一半的那个字先不要（下一次读到完整的再显示，不闪一个「�」）
  private static func decodedPrefix(of file: URL, limit: Int) -> String {
    let handle = try? FileHandle(forReadingFrom: file)
    defer { try? handle?.close() }
    var data = (try? handle?.read(upToCount: limit)) ?? Data()
    // 从后往前找最后一个字的开头（不是 10xxxxxx 的字节），它要的字节数比剩下的多就是还没写完
    if let lead = data.indices.reversed().prefix(4).first(where: { data[$0] & 0xC0 != 0x80 }) {
      let byte = data[lead]
      let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
      if data.endIndex - lead < needed { data = data[..<lead] }
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "kitty-\(UUID().uuidString)")
  }
}
