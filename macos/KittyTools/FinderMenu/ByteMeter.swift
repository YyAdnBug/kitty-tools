// 访达右键压缩、解压、移动 / 复制的进度（2026-11-08 用户：「打包和解压时没有进度条，太不友好了」）：系统的 tar / ditto / gunzip
// 不报百分比，这里自己算做到第几个字节——
// - 做完的文件：ditto -V 每拷完一个报「N bytes for 名字」（同一个卷上是克隆，报「hardlinked 名字」、不报字节）；
//   tar -v 开始一个时先写「a 名字」、做完才补换行（评审实测），所以凑成整行的就是做完了的。只报名字的，多大由调用方去看。
// - 正做着的那个：子进程开着的、只读的普通文件读到的位置（libproc 的 proc_pidinfo / proc_pidfdinfo，同 progress 这类工具的做法；
//   一个几 GB 的大文件也能看着一点点走）。解压只看这一样：压缩包读到第几个字节 ÷ 包有多大。
// - 一共多大：find 加 stat 把普通文件的大小加起来（du 每个文件往上取整到 512 字节、还算上文件夹，小文件多时多算几十倍，评审实测）。
// 刘海岛上显示「42% · 1.2 GB / 2.9 GB」，进度条只往前走、跑着的时候最多到 99%。纯计算（feed / fraction / detail）有单测。
// ponytail: feed 和 sizes 在主线程上一行行拆（每行几微秒，十万个文件的那一遍几十毫秒）；更大的再挪出去。

import Darwin
import Foundation

@MainActor final class ByteMeter {
  /// 一共多少字节（算不出来是 0：只显示做了多少）
  let total: Int64
  /// 一批里前面几样已经做完的（移动 / 复制一样一样来）
  var base: Int64 = 0
  /// 这一样里做完的文件加起来
  private(set) var done: Int64 = 0
  /// 解压：读到过前九成里的位置了（见 archiveValue）
  private var started = false
  /// 显示过的最大值（只往前走）
  private var shown: Int64 = 0

  init(total: Int64) { self.total = max(total, 0) }

  /// 子进程新写完的几行（每一行都是做完了的一个）。size：只报名字的（tar 的「a 名字」、ditto 克隆的「hardlinked 名字」），
  /// 名字（去掉开头的「./」）对应的文件多大；文件夹、读不到的是 nil
  func feed(_ lines: String, size: (String) -> Int64?) {
    for line in lines.split(whereSeparator: \.isNewline) {
      if line.first?.isNumber == true, let range = line.range(of: " bytes for "),
        let bytes = Int64(line[..<range.lowerBound])
      {
        done += bytes
        continue
      }
      let prefix = line.hasPrefix("a ") ? "a " : line.hasPrefix("hardlinked ") ? "hardlinked " : nil
      guard let prefix else { continue }
      var name = String(line.dropFirst(prefix.count))
      if name.hasPrefix("./") { name.removeFirst(2) }
      done += size(name) ?? 0
    }
  }

  /// 这一样做完了：并进 base，下一样从头数
  func finishItem(_ bytes: Int64) {
    base += bytes
    done = 0
  }

  /// 现在做到第几个字节（current：子进程正读着的那个文件读到的位置）
  func value(current: Int64) -> Int64 {
    shown = max(shown, base + done + current)
    return shown
  }

  /// 解压：压缩包读到的位置。zip、7z 一开始先去包尾读目录（评审实测），读到过前九成里的位置之前，比九成还大的不算
  /// （不然第一次看到的就是 99%、之后一直不动）
  func archiveValue(_ offset: Int64) -> Int64 {
    if !started {
      guard total == 0 || offset < total / 10 * 9 else { return value(current: 0) }
      started = offset > 0
    }
    return value(current: offset)
  }

  /// 进度条（0…0.99；不知道一共多少是 nil）
  func fraction(_ value: Int64) -> Double? {
    total > 0 ? min(Double(value) / Double(total), 0.99) : nil
  }

  /// 刘海岛上的小字：「42% · 1.2 GB / 2.9 GB」，不知道一共多少时「已处理 1.2 GB」
  func detail(_ value: Int64) -> String {
    guard value > 0 else { return "准备中" }
    let bytes = { (count: Int64) in count.formatted(.byteCount(style: .file)) }
    guard let fraction = fraction(value) else { return "已处理 \(bytes(value))" }
    return "\(Int(fraction * 100))% · \(bytes(min(value, total))) / \(bytes(total))"
  }

  // MARK: 子进程读到哪了（libproc）

  /// 进程 pid 开着的、只读的普通文件，和读到的位置。named：只要文件名是这个的（解压时认压缩包）
  nonisolated static func reading(pid: pid_t, named name: String? = nil) -> Int64 {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return 0 }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
    guard got > 0 else { return 0 }
    var best: Int64 = 0
    for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
      var info = vnode_fdinfowithpath()
      let length = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, length) == length,
        // 内核的打开方式（FREAD = 1、FWRITE = 2，不是 open 的 O_RDONLY）：只读的才算（写的是输出）
        info.pfi.fi_openflags & 3 == 1,
        info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT == S_IFREG
      else { continue }
      if let name {
        let path = withUnsafeBytes(of: info.pvip.vip_path) {
          String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        guard (path as NSString).lastPathComponent == name else { continue }
      }
      best = max(best, info.pfi.fi_offset)
    }
    return best
  }

  /// 这几样各多少字节（里面普通文件的大小加起来，「._」开头的不算——拷的时候它们并进扩展属性），和 urls 一一对应；
  /// 算不出来的是 0。find 加 stat 一遍走完（另起进程），每一行按它的上一层一级级找是哪一样的。
  /// skip：压缩时另外跳过的名字（Archives.effectiveSkip），叫这些名字的文件、文件夹整个不算（find 的 -prune，同 tar 的 --exclude）
  static func sizes(of urls: [URL], skip: [String] = []) async -> [Int64] {
    let paths = urls.map { FileMoves.plainPath($0) }
    let prune =
      skip.isEmpty
      ? []
      : ["("] + skip.enumerated().flatMap { ($0 == 0 ? [] : ["-o"]) + ["-name", $1] } + [
        ")", "-prune", "-o",
      ]
    guard !paths.isEmpty,
      let result = try? await Subprocess.run(
        "/usr/bin/find",
        paths + prune + [
          "-type", "f", "!", "-name", "._*", "-exec", "/usr/bin/stat", "-f", "%z %N", "{}", "+",
        ],
        captures: true, environment: utf8Environment, quality: .userInitiated, stopsOnCancel: true)
    else { return paths.map { _ in 0 } }
    let index = Dictionary(paths.enumerated().map { ($1, $0) }) { first, _ in first }
    var sizes = paths.map { _ in Int64(0) }
    for line in result.output.split(whereSeparator: \.isNewline) {
      guard let space = line.firstIndex(of: " "), let bytes = Int64(line[..<space]) else {
        continue
      }
      var path = line[line.index(after: space)...]
      while true {
        if let item = index[String(path)] {
          sizes[item] += bytes
          break
        }
        guard let slash = path.lastIndex(of: "/"), slash > path.startIndex else { break }
        path = path[..<slash]
      }
    }
    return sizes
  }

  /// 文件多大（lstat：普通文件才算，文件夹、链接是 nil）
  nonisolated static func fileSize(_ path: String) -> Int64? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    return Int64(info.st_size)
  }

  /// 出错原因只看工具自己报的那几行（「tar: …」「ditto: …」）：-v / -V 的成千上万行里有文件名，名字里带「Permission denied」
  /// 这类字样会被认错（评审）
  nonisolated static func errors(_ stderr: String) -> String {
    stderr.split(whereSeparator: \.isNewline)
      .filter { $0.hasPrefix("tar:") || $0.hasPrefix("ditto:") || $0.hasPrefix("gunzip:") }
      .joined(separator: "\n")
  }

  /// 系统命令报的名字要是 UTF-8（从访达打开的 App 没有 UTF-8 的 locale：du 把中文名打成「?」、tar -v 打成「\345…」）
  static var utf8Environment: [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "en_US.UTF-8"
    return environment
  }

}
