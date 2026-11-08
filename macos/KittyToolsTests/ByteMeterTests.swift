// 访达右键压缩、解压、复制的进度：ditto -V / tar -v 报的行怎么算、进度条和小字；再真压、真解一个 100 MB 的文件，看进度条
// 真的一点点往前走。只动临时文件夹。

import Foundation
import Testing

@testable import KittyTools

@MainActor struct ByteMeterTests {
  @Test func linesAndFraction() {
    let meter = ByteMeter(total: 1000)
    // ditto：做完一个报一行字节数；同一个卷上是克隆，只报名字
    meter.feed("copying file ./a ... \n300 bytes for ./a\nhardlinked ./b\n") {
      $0 == "b" ? 50 : nil
    }
    #expect(meter.done == 350)
    // tar：做完一个才补换行，凑成整行的就是做完的（文件夹多大算 0）
    let tar = ByteMeter(total: 1000)
    tar.feed("a ./x\na ./x/y\n") { $0 == "x" ? nil : 200 }
    #expect(tar.done == 200)
    // 正读着的那个读到的位置加上去；只往前走、最多 99%
    #expect(tar.value(current: 300) == 500)
    #expect(tar.value(current: 0) == 500)
    #expect(tar.fraction(2000) == 0.99)
    #expect(tar.detail(500).hasPrefix("50% · "))
    #expect(tar.detail(0) == "准备中")
    #expect(ByteMeter(total: 0).fraction(10) == nil)
    #expect(ByteMeter(total: 0).detail(2048).hasPrefix("已处理"))
    // 一批里一样一样来
    let batch = ByteMeter(total: 1000)
    batch.finishItem(400)
    #expect(batch.value(current: 100) == 500)
    // 解压：一上来读到包尾（zip 的目录）不算，读到前面之后照常
    let archive = ByteMeter(total: 1000)
    #expect(archive.archiveValue(990) == 0)
    #expect(archive.archiveValue(120) == 120)
    #expect(archive.archiveValue(950) == 950)
    // 出错原因只看工具自己报的行
    #expect(
      ByteMeter.errors("a ./Permission denied.txt\ntar: x: Cannot stat\n") == "tar: x: Cannot stat")
  }

  /// 一共多大：普通文件的大小加起来（小文件不往上取整、文件夹不算），一样一样分开；中文名、不在的
  @Test func sizesAreExact() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ByteMeterTests-\(UUID())")
    let folder = root.appending(path: "很多 小文件")
    try FileManager.default.createDirectory(
      at: folder.appending(path: "子"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<200 {
      try Data("hello world!".utf8).write(to: folder.appending(path: "子/\(index).txt"))
    }
    try Data(count: 7).write(to: folder.appending(path: "._杂"))
    let single = root.appending(path: "单个.bin")
    try Data(count: 1000).write(to: single)
    let sizes = await ByteMeter.sizes(of: [folder, single, root.appending(path: "没有")])
    #expect(sizes == [200 * 12, 1000, 0])
    #expect(ByteMeter.fileSize(single.path(percentEncoded: false)) == 1000)
    #expect(ByteMeter.fileSize(folder.path(percentEncoded: false)) == nil)
  }

  /// 真压、真解 100 MB 的随机数据：进度报的在 0 到 1 之间、只往前走（单独跑时压缩约报 8 次、0.1 → 0.92）
  @Test func reportsWhileWorking() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ByteMeterTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let big = root.appending(path: "大 文件.bin")
    let made = try await Subprocess.run(
      "/bin/dd", ["if=/dev/urandom", "of=" + big.path(percentEncoded: false), "bs=1m", "count=100"])
    try #require(made.status == 0)
    #expect(await ByteMeter.sizes(of: [big, root.appending(path: "没有")]) == [100 << 20, 0])
    var packed: [Double] = []
    let archive = try #require(
      await Archives.pack(
        [big], format: .zip, to: root.appending(path: "大.zip"),
        report: { fraction, _ in fraction.map { packed.append($0) } }
      ).url)
    // 报几次看机器忙不忙（跑全量时主线程被别的测试占着，可能一次都来不及）：报了的在范围里、只往前走
    #expect(packed.allSatisfy { $0 >= 0 && $0 < 1 })
    #expect(packed == packed.sorted())
    try FileManager.default.removeItem(at: big)
    var unpacked: [Double] = []
    _ = try #require(
      await Archives.unpack(
        archive, password: nil, gbk: false,
        report: { fraction, _ in fraction.map { unpacked.append($0) } }
      ).url)
    // 解 100 MB 用不了 0.25 秒，多半一次都来不及报；报了的话在范围里
    #expect(unpacked.allSatisfy { $0 >= 0 && $0 < 1 })
    #expect(unpacked == unpacked.sorted())
  }

  /// 子进程开着的只读文件读到第几个字节：tail -f 把文件读到头、一直开着，读到的位置就是文件多大
  @Test func readsChildOffsets() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ByteMeterTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "读 着.txt")
    try Data(count: 12345).write(to: file)
    let tail = Process()
    tail.executableURL = URL(filePath: "/usr/bin/tail")
    tail.arguments = ["-f", file.path(percentEncoded: false)]
    tail.standardOutput = FileHandle.nullDevice
    try tail.run()
    defer { tail.terminate() }
    var offset: Int64 = 0
    for _ in 0..<100 where offset == 0 {
      try await Task.sleep(for: .milliseconds(20))
      offset = ByteMeter.reading(pid: tail.processIdentifier, named: "读 着.txt")
    }
    #expect(offset == 12345)
    #expect(ByteMeter.reading(pid: tail.processIdentifier, named: "别的.txt") == 0)
  }
}

extension Archives.Outcome {
  fileprivate var url: URL? {
    if case .done(let url) = self { url } else { nil }
  }
}
