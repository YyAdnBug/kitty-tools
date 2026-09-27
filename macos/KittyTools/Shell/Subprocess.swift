// 跑系统自带的命令行工具：在进程外、不占主线程，等它结束拿退出码（和输出）。应用内更新的 ditto / codesign、
// 启动器系统命令的 pmset / osascript 都走这里（mac-native §3：进程外 + continuation）。

import Foundation

enum Subprocess {
  struct Result {
    var status: Int32
    var output = ""
    var error = ""
  }

  /// captures = false 时输出直接丢掉。
  /// ponytail: 输出在进程结束后才一次读完，超过管道缓冲（64 KB）子进程会卡住写不完；只给输出很短的命令用，
  /// 要长输出再改成边跑边读
  static func run(_ tool: String, _ arguments: [String], captures: Bool = false) async throws
    -> Result
  {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.standardOutput = captures ? Pipe() : FileHandle.nullDevice
    process.standardError = captures ? Pipe() : FileHandle.nullDevice
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { process in
        func read(_ handle: Any?) -> String {
          guard let pipe = handle as? Pipe else { return "" }
          return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        continuation.resume(
          returning: Result(
            status: process.terminationStatus, output: read(process.standardOutput),
            error: read(process.standardError)))
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
