// 访达右键的拷贝哈希、隐藏、彻底删除的保护：哈希值和 shasum 一样（空文件、跨 1 MB 一块的大文件），拷进剪贴板的写法，
// 隐藏 / 扩展名真设得上，根目录、主目录、卷的根不让删。只动临时文件夹。

import Foundation
import Testing

@testable import KittyTools

@MainActor struct FileHashTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "FileHashTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func digestsMatchShasum() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appending(path: "空.txt")
    try Data().write(to: empty)
    #expect(
      await FileHash.digest(of: empty, kind: .sha256)
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(await FileHash.digest(of: empty, kind: .md5) == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(
      await FileHash.digest(of: empty, kind: .sha1) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    // 比 1 MB 一块多一点：拿系统的 shasum 对
    let big = root.appending(path: "大 文件.bin")
    try Data((0..<(1 << 20) + 4097).map { UInt8($0 % 251) }).write(to: big)
    let shasum = try await Subprocess.run(
      "/usr/bin/shasum", ["-a", "256", big.path(percentEncoded: false)], captures: true)
    let expected = String(shasum.output.prefix(64))
    #expect(await FileHash.digest(of: big, kind: .sha256) == expected)
    #expect(await FileHash.digest(of: root.appending(path: "没有"), kind: .sha256) == nil)
  }

  @Test func clipboardText() {
    let a = URL(filePath: "/x/a.dmg")
    let b = URL(filePath: "/y/b c.zip")
    #expect(FileHash.text([(a, "11")]) == "11")
    #expect(FileHash.text([(a, "11"), (b, "22")]) == "11  a.dmg\n22  b c.zip")
  }

  @Test func hideAndExtensionFlags() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "报告.txt")
    try Data().write(to: file)
    let dot = root.appending(path: ".env")
    try Data().write(to: dot)
    FileFlags.setHidden([file, dot], true, island: nil)
    var values = try file.resourceValues(forKeys: [.isHiddenKey])
    #expect(values.isHidden == true)
    FileFlags.setHidden([file], false, island: nil)
    values = try URL(filePath: file.path(percentEncoded: false))
      .resourceValues(forKeys: [.isHiddenKey])
    #expect(values.isHidden == false)
    FileFlags.setExtensionHidden([file], true, island: nil)
    values = try URL(filePath: file.path(percentEncoded: false))
      .resourceValues(forKeys: [.hasHiddenExtensionKey])
    #expect(values.hasHiddenExtension == true)
  }

  @Test func protectedFromErase() {
    let home = "/Users/someone"
    #expect(FileMoves.protected(URL(filePath: "/"), home: home))
    #expect(
      FileMoves.protected(URL(filePath: "/Applications/", directoryHint: .isDirectory), home: home))
    #expect(FileMoves.protected(URL(filePath: "/Users/someone/"), home: home))
    #expect(!FileMoves.protected(URL(filePath: "/Users/someone/Downloads/a.zip"), home: home))
    // 同一个主目录的别的写法：大小写、数据卷的路径（按身份比）
    let real = NSHomeDirectory()
    #expect(FileMoves.protected(URL(filePath: real.lowercased()), home: real))
    #expect(FileMoves.protected(URL(filePath: "/System/Volumes/Data" + real), home: real))
    #expect(FileMoves.protected(URL(filePath: "/System/Volumes/Data/Applications"), home: real))
    #expect(!FileMoves.protected(URL(filePath: real + "/Downloads"), home: real))
  }
}
