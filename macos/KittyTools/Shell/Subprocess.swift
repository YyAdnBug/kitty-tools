// 跑系统自带的命令行工具：在进程外、不占主线程，等它结束拿退出码（和输出）。应用内更新的 ditto / codesign、
// 启动器系统命令的 pmset / osascript、kill 列进程的 ps / lsof、读浏览器浏览历史（和 Firefox 书签）的 sqlite3 都走这里
// （mac-native §3：进程外 + continuation）。

import Foundation

enum Subprocess {
  struct Result {
    var status: Int32
    var output = ""
    var error = ""
  }

  /// captures = false 时输出直接丢掉。要的输出写进临时文件、结束后一次读完：管道缓冲只有 64 KB，
  /// 写满了子进程就卡住、等不到它结束（sqlite3 导出的浏览历史约 460 KB，ps 列几百个进程也可能超）
  static func run(_ tool: String, _ arguments: [String], captures: Bool = false) async throws
    -> Result
  {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    let files = captures ? [temporaryFile(), temporaryFile()] : []
    defer {
      for file in files { try? FileManager.default.removeItem(at: file) }
    }
    if captures {
      for file in files { FileManager.default.createFile(atPath: file.path, contents: nil) }
      process.standardOutput = try FileHandle(forWritingTo: files[0])
      process.standardError = try FileHandle(forWritingTo: files[1])
    } else {
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
    }
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    // 只关自己开的（nullDevice 是共用的，关了别处就写不进去了）
    if captures {
      for handle in [process.standardOutput, process.standardError] {
        try? (handle as? FileHandle)?.close()
      }
    }
    func read(_ index: Int) -> String {
      guard files.indices.contains(index), let data = try? Data(contentsOf: files[index]) else {
        return ""
      }
      return String(decoding: data, as: UTF8.self)
    }
    return Result(status: status, output: read(0), error: read(1))
  }

  private static func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "kitty-\(UUID().uuidString)")
  }
}
