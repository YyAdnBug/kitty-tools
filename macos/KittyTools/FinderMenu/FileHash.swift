// 访达右键「拷贝哈希 ▸ SHA-256、MD5、SHA-1」（2026-11-08 右键扩充第 3 批，拍板 E3，默认关）：只给文件算（扩展里选中的有文件夹
// 就不出这一项）。一块一块读（1 MB），大文件不占内存；算在主线程外（mac-native §3 允许的第 1 类：hash），和移动、压缩排在同一条队
// （FileMoves.enqueue）：超过 1 秒刘海岛挂「正在算…」带「停止」。算完拷进剪贴板并记进剪贴板历史（mac-native §5：本 App 生成的
// 新文字）：一个文件只有哈希值，几个文件按 shasum 的格式一行一个「哈希值␣␣文件名」。读不到的那几个跳过、说一声。

import AppKit
import CryptoKit

nonisolated enum FileHash {
  enum Kind: String, CaseIterable {
    case sha256, md5, sha1

    var title: String {
      switch self {
      case .sha256: "SHA-256"
      case .md5: "MD5"
      case .sha1: "SHA-1"
      }
    }
  }

  /// 一个文件的哈希值（小写十六进制）；读不到、被停了是 nil
  @concurrent static func digest(of url: URL, kind: Kind) async -> String? {
    switch kind {
    case .sha256: hex(of: url, SHA256())
    case .md5: hex(of: url, Insecure.MD5())
    case .sha1: hex(of: url, Insecure.SHA1())
    }
  }

  private static func hex<H: HashFunction>(of url: URL, _ hasher: H) -> String? {
    var hasher = hasher
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    // 读到头时 read 给 nil 或空的；读错了才抛
    do {
      while !Task.isCancelled {
        let more = try autoreleasepool {
          guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
            return false
          }
          hasher.update(data: chunk)
          return true
        }
        if !more { return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
      }
    } catch {}
    return nil
  }

  /// 拷进剪贴板的字：一个文件只有哈希值，几个一行一个「哈希值␣␣文件名」（同 shasum）
  static func text(_ results: [(file: URL, hex: String)]) -> String {
    results.count == 1
      ? results[0].hex
      : results.map { "\($0.hex)  \($0.file.lastPathComponent)" }.joined(separator: "\n")
  }

  @MainActor static func copy(_ files: [URL], kind: Kind, island: Island?) {
    // 符号链接按它指向的看（扩展那边链接不算文件夹、会出这一项；读的时候本来就顺着链接读）
    let regular = files.filter {
      (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?
        .isRegularFile == true
    }
    guard !regular.isEmpty else {
      island?.show("没有算 \(kind.title)", detail: "只给文件算（文件夹不算），或者选中的不在了", tone: .warning)
      return
    }
    FileMoves.enqueue(
      "正在算 \(kind.title)…",
      detail: regular.count == 1 ? regular[0].lastPathComponent : "\(regular.count) 个文件",
      island: island
    ) {
      var results: [(file: URL, hex: String)] = []
      for file in regular {
        if Task.isCancelled { return (results, stopped: true) }
        if let hex = await digest(of: file, kind: kind) { results.append((file, hex)) }
      }
      return (results, stopped: Task.isCancelled)
    } finish: { outcome in
      let (results, stopped) = outcome
      if stopped {
        island?.show("已停止算 \(kind.title)", tone: .info)
        return
      }
      guard !results.isEmpty else {
        island?.show("没能算 \(kind.title)", detail: "文件读不到（被移走了，或者没有权限）", tone: .error)
        return
      }
      Paster.write(string: text(results), record: true)
      let missed = regular.count - results.count
      island?.show(
        "已拷贝 \(kind.title)",
        detail: missed > 0
          ? "\(missed) 个文件读不到，没算"
          : results.count == 1 ? String(results[0].hex.prefix(16)) + "…" : "\(results.count) 个文件",
        tone: missed > 0 ? .warning : .success)
    }
  }
}
