// 访达右键的压缩和解压：名字、tar 的参数、出错原因；在临时文件夹里用系统 tar 真压、真解一遍（zip 标 UTF-8、不带杂文件，
// 7z 往返，GBK 名字的 zip（先用 ASCII 名字打、再把名字的字节换成 GBK），带密码的 zip 密码不对 / 对），解出来只有一样东西时
// 放在包旁边、重名加「 2」。只动临时文件夹。

import Foundation
import Testing

@testable import KittyTools

@MainActor struct ArchivesTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "ArchivesTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
  }

  @Test func namesAndSuffixes() {
    #expect(Archives.isArchive(URL(filePath: "/a/资料.ZIP")))
    #expect(Archives.isArchive(URL(filePath: "/a/b.tar.gz")))
    #expect(Archives.isArchive(URL(filePath: "/a/b.gz")))  // 单文件的 .gz 也认
    #expect(!Archives.isArchive(URL(filePath: "/a/b.xz")))
    #expect(!Archives.isArchive(URL(filePath: "/a/.zip")))
    #expect(!Archives.isArchive(URL(filePath: "/a/b.zipx")))
    #expect(Archives.stem(of: URL(filePath: "/a/项目 v1.2.tar.gz")) == "项目 v1.2")
    #expect(Archives.stem(of: URL(filePath: "/a/A.TGZ")) == "A")
    #expect(Archives.archiveName(for: [URL(filePath: "/a/b.txt")], format: .zip) == "b.txt.zip")
    #expect(
      Archives.archiveName(for: [URL(filePath: "/a/b"), URL(filePath: "/a/c")], format: .sevenZip)
        == "归档.7z")
    // 名字太长：截到加上「 99.zip」还在 255 个字符以内（按 UTF-16 数，同 FAT / HFS+；APFS 按字符）
    let long = String(repeating: "长", count: 300)
    let name = Archives.archiveName(for: [URL(filePath: "/a/\(long)")], format: .zip)
    #expect(name.hasSuffix(".zip") && (name.utf16.count + 3) <= 255 && name.hasPrefix("长长"))
    #expect(Archives.clash(in: [URL(filePath: "/a/x"), URL(filePath: "/b/y")]) == nil)
    #expect(
      Archives.clash(in: [URL(filePath: "/a/Readme"), URL(filePath: "/b/README")]) == "README")
  }

  /// 按所在的文件夹分组、名字带 ./（「-」开头的不会被当成选项）
  @Test func compressArgumentsGroupByFolder() {
    let arguments = Archives.compressArguments(
      [URL(filePath: "/p/a/"), URL(filePath: "/p/-b"), URL(filePath: "/q/c")], format: .zip,
      to: URL(filePath: "/p/.tmp"))
    let tail = Array(arguments.suffix(7))
    #expect(tail == ["-C", "/p", "./a", "./-b", "-C", "/q", "./c"])
    #expect(arguments.contains("zip:hdrcharset=UTF-8"))
    #expect(
      Archives.extractArguments(
        URL(filePath: "/p/x.zip"), into: URL(filePath: "/p/.t"), gbk: true, password: nil
      ).contains("hdrcharset=GB18030"))
  }

  @Test func failureReasons() {
    #expect(
      Archives.outcome(ofFailure: "x: Incorrect passphrase", password: false) == .needsPassword)
    #expect(
      Archives.outcome(ofFailure: "x: Incorrect passphrase", password: true) == .wrongPassword)
    #expect(Archives.outcome(ofFailure: "x: ZIP bad CRC", password: true) == .wrongPassword)
    // 给过密码、坏的是包本身：照实说，不当成密码不对
    #expect(
      Archives.outcome(ofFailure: "Truncated input file", password: true)
        == .failed("压缩包不完整，可能没下载完"))
    #expect(
      Archives.outcome(ofFailure: "x: No space left on device", password: true)
        == .failed("磁盘空间不够了"))
    #expect(
      Archives.outcome(ofFailure: "Truncated input file", password: false)
        == .failed("压缩包不完整，可能没下载完"))
  }

  /// zip：名字标 UTF-8、不带 .DS_Store / ._*；解回来只有一个文件夹，旁边已有同名的就叫「 2」
  @Test func zipRoundTrip() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "资料")
    try write("中", to: folder.appending(path: "子/说明.txt"))
    try write("x", to: folder.appending(path: ".DS_Store"))
    try write("x", to: folder.appending(path: "._说明.txt"))
    let packed = await Archives.pack(
      [folder], format: .zip, to: root.appending(path: "资料.zip"))
    let archive = try #require(packed.url)
    #expect(archive.lastPathComponent == "资料.zip")
    let entries = try #require(ZipNames.entries(of: archive))
    #expect(entries.allSatisfy { $0.utf8Flag })
    let inside = entries.map { String(decoding: $0.name, as: UTF8.self) }
    #expect(inside.contains("资料/子/说明.txt"))
    #expect(!inside.contains { $0.contains(".DS_Store") || $0.contains("._") })

    let unpacked = await Archives.unpack(archive, password: nil, gbk: false)
    let placed = try #require(unpacked.url)
    #expect(placed.lastPathComponent == "资料 2")
    #expect(try String(contentsOf: placed.appending(path: "子/说明.txt"), encoding: .utf8) == "中")
    #expect(try names(in: root) == ["资料", "资料 2", "资料.zip"])
  }

  /// 压缩时跳过（2026-11-13 拍板 Z1 Z2）：逗号（全角半角）隔开、去空白去重、带「/」的不收；* ? 通配；选中的那一样自己不跳过
  @Test func skipNames() {
    #expect(
      Archives.skipNames(" node_modules, .git，*.log ,, .git") == ["node_modules", ".git", "*.log"])
    #expect(Archives.skipNames("build/out, a") == ["a"])
    #expect(Archives.rejectedSkipNames("build/out, a, /tmp") == ["build/out", "/tmp"])
    #expect(
      Archives.skipNames(
        String(repeating: "a,", count: 80).enumerated().map { "\($0.offset)" }.joined(
          separator: ",")
      ).count == 50)
    #expect(Archives.matches("*.log", "a.log") && !Archives.matches("*.log", "a.logs"))
    #expect(
      Archives.matches("node_modules", "node_modules") && !Archives.matches("node", "node_modules"))
    #expect(Archives.matches("?.txt", "a.txt") && !Archives.matches("?.txt", "ab.txt"))
    #expect(Archives.matches("a*b*c", "aXXbYc") && !Archives.matches("a*b*c", "aXXbY"))
    #expect(Archives.matches("*", "") && !Archives.matches("Log", "log"))
    let picked = [URL(filePath: "/x/node_modules"), URL(filePath: "/x/app")]
    #expect(Archives.effectiveSkip(["node_modules", "*.log"], items: picked) == ["*.log"])
    let arguments = Archives.compressArguments(
      picked, format: .zip, to: URL(filePath: "/x/归档.zip"), skip: ["*.log"])
    #expect(
      arguments.contains("*.log")
        && arguments[arguments.firstIndex(of: "*.log")! - 1] == "--exclude")
  }

  /// 真压一遍：任意一层叫这个名字的都不进包，进度的总大小也不算它们；选中的那一样叫这个名字时照压
  @Test func skipWhileCompressing() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: "项目")
    try write("main", to: project.appending(path: "src/main.js"))
    try write(
      String(repeating: "x", count: 1000), to: project.appending(path: "node_modules/a/b.js"))
    try write("log", to: project.appending(path: "src/run.log"))
    let skip = Archives.effectiveSkip(["node_modules", "*.log"], items: [project])
    for format in [Archives.Format.zip, .sevenZip] {
      let packed = await Archives.pack(
        [project], format: format, to: root.appending(path: "项目.\(format.rawValue)"), skip: skip)
      let archive = try #require(packed.url)
      let listing = try await Subprocess.run(
        "/usr/bin/tar", ["-tf", archive.path(percentEncoded: false)], captures: true,
        environment: ByteMeter.utf8Environment)
      #expect(listing.output.contains("项目/src/main.js"), "\(format)")
      #expect(
        !listing.output.contains("node_modules") && !listing.output.contains("run.log"), "\(format)"
      )
    }
    #expect(await ByteMeter.sizes(of: [project], skip: skip) == [4])
    // 选中的就是 node_modules：这一次不跳它，整个压进去
    let modules = project.appending(path: "node_modules")
    let own = Archives.effectiveSkip(["node_modules"], items: [modules])
    let packed = await Archives.pack(
      [modules], format: .zip, to: root.appending(path: "node_modules.zip"), skip: own)
    let whole = try #require(packed.url)
    let entries = try #require(ZipNames.entries(of: whole))
    #expect(
      entries.map { String(decoding: $0.name, as: UTF8.self) }.contains("node_modules/a/b.js"))
  }

  /// 7z：两样东西打成「归档」，解回来放进和包同名的文件夹
  @Test func sevenZipRoundTrip() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appending(path: "甲.txt")
    let b = root.appending(path: "乙")
    try write("一", to: a)
    try write("二", to: b.appending(path: "里面.txt"))
    let archive = try #require(
      await Archives.pack([a, b], format: .sevenZip, to: root.appending(path: "归档.7z")).url)
    let unpacked = try #require(await Archives.unpack(archive, password: nil, gbk: false).url)
    #expect(unpacked.lastPathComponent == "归档")
    #expect(try names(in: unpacked) == ["乙", "甲.txt"])
    #expect(
      try String(contentsOf: unpacked.appending(path: "乙/里面.txt"), encoding: .utf8) == "二")
  }

  /// GBK 名字、不标 UTF-8 的 zip（中文 Windows 打的那种）：认出来按 GB18030 解
  @Test func gbkZipIsRead() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "源")
    try write("hello", to: source.appending(path: "ABCD/EFGH.txt"))
    let archive = root.appending(path: "gbk.zip")
    let made = try await Subprocess.run(
      "/usr/bin/tar",
      [
        "-c", "--format", "zip", "-f", archive.path(percentEncoded: false), "-C",
        source.path(percentEncoded: false), "ABCD",
      ])
    try #require(made.status == 0)
    let gbk = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    var bytes = try Data(contentsOf: archive)
    for (from, to) in [("ABCD", "中文"), ("EFGH", "报告")] {
      let old = Data(from.utf8)
      let new = try #require(to.data(using: gbk))
      while let range = bytes.range(of: old) { bytes.replaceSubrange(range, with: new) }
    }
    try bytes.write(to: archive)
    let entries = try #require(ZipNames.entries(of: archive))
    #expect(ZipNames.charset(for: entries) == .gb18030)

    let unpacked = try #require(await Archives.unpack(archive, password: nil, gbk: true).url)
    #expect(unpacked.lastPathComponent == "中文")
    #expect(try names(in: unpacked) == ["报告.txt"])
  }

  /// 带密码的 zip：看得出加了密；密码不对是 wrongPassword、不留临时文件夹；对了解得开
  @Test func encryptedZip() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("秘密", to: root.appending(path: "源/机密.txt"))
    let archive = root.appending(path: "机密.zip")
    let made = try await Subprocess.run(
      "/usr/bin/tar",
      [
        "-c", "--format", "zip", "--options", "zip:encryption=aes256", "--passphrase", "pässwörd",
        "-f", archive.path(percentEncoded: false), "-C",
        root.appending(path: "源").path(percentEncoded: false), "机密.txt",
      ])
    try #require(made.status == 0)
    #expect(ZipNames.entries(of: archive)?.contains(where: \.encrypted) == true)

    #expect(await Archives.unpack(archive, password: "wrong", gbk: false) == .wrongPassword)
    #expect(try names(in: root) == ["机密.zip", "源"])
    let unpacked = try #require(
      await Archives.unpack(archive, password: "pässwörd", gbk: false).url)
    #expect(unpacked.lastPathComponent == "机密.txt")
    #expect(try String(contentsOf: unpacked, encoding: .utf8) == "秘密")
  }

  /// 只选了一个包（App 这类）：zip 走 ditto，包里带着上一层的名字，解回来还是那个包
  @Test func packageZipUsesDitto() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appending(path: "演示.app")
    try write("<plist/>", to: app.appending(path: "Contents/Info.plist"))
    try FileManager.default.createSymbolicLink(
      atPath: app.appending(path: "Contents/链接").path(percentEncoded: false),
      withDestinationPath: "Info.plist")
    #expect((try? app.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true)
    let archive = try #require(
      await Archives.pack([app], format: .zip, to: root.appending(path: "演示.app.zip")).url)
    try FileManager.default.removeItem(at: app)
    let unpacked = try #require(await Archives.unpack(archive, password: nil, gbk: false).url)
    #expect(unpacked.lastPathComponent == "演示.app")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: unpacked.appending(path: "Contents/链接").path(percentEncoded: false)) == "Info.plist"
    )
  }

  /// 认不出是 zip（前面多了一截）、里面加了密：没给密码时是 needsPassword（由它去问），不会当成别的一直重排
  @Test func unrecognizedEncryptedZipAsksForPassword() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("秘密", to: root.appending(path: "源/a.txt"))
    let plain = root.appending(path: "源.zip")
    let made = try await Subprocess.run(
      "/usr/bin/tar",
      [
        "-c", "--format", "zip", "--options", "zip:encryption=zipcrypt", "--passphrase", "pw", "-f",
        plain.path(percentEncoded: false), "-C",
        root.appending(path: "源").path(percentEncoded: false), "a.txt",
      ])
    try #require(made.status == 0)
    let archive = root.appending(path: "前面多一截.zip")
    try (Data("MZjunk-junk-junk".utf8) + Data(contentsOf: plain)).write(to: archive)
    #expect(!ZipNames.isZip(archive))
    #expect(await Archives.unpack(archive, password: nil, gbk: false) == .needsPassword)
    #expect(try names(in: root) == ["前面多一截.zip", "源", "源.zip"])
  }

  /// 临时名记账：用着的记进偏好、用完去掉；启动时把上次留下的删掉（权限是 000 的文件夹也删得掉），名字不是 .kitty-<UUID> 的不碰
  @Test func leftoverTemporariesAreCleaned() async throws {
    let root = try makeRoot()
    let suite = "ArchivesTests-\(UUID())"
    let ledger = try #require(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults().removePersistentDomain(forName: suite)
      FileMoves.ledger = nil
    }
    FileMoves.ledger = ledger
    let left = FileMoves.temporary(in: root)
    try write("x", to: left.appending(path: "锁住/里面.txt"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0], ofItemAtPath: left.appending(path: "锁住").path(percentEncoded: false))
    let used = FileMoves.temporary(in: root)
    FileMoves.release(used)
    let mine = root.appending(path: "用户的")
    try write("y", to: mine.appending(path: "留着.txt"))
    var list = ledger.stringArray(forKey: Prefs.finderTemporaries) ?? []
    #expect(list == [FileMoves.plainPath(left)])
    ledger.set(list + [FileMoves.plainPath(mine)], forKey: Prefs.finderTemporaries)
    FileMoves.cleanLeftovers(after: .zero)
    for _ in 0..<200 where ledger.stringArray(forKey: Prefs.finderTemporaries) != nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    list = ledger.stringArray(forKey: Prefs.finderTemporaries) ?? []
    #expect(list.isEmpty)
    #expect(!FileMoves.occupied(left))
    #expect(FileMoves.occupied(mine.appending(path: "留着.txt")))
  }

  /// 只压了一个文件的 .gz / .bz2：解出来叫包名去掉扩展名，放在旁边；.tar.gz 照旧是 tar 包；坏的说原因、不留东西
  @Test func singleFileCompressed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(Archives.decompressor(for: URL(filePath: "/a/b.txt.gz")) == "/usr/bin/gunzip")
    #expect(Archives.decompressor(for: URL(filePath: "/a/b.tar.gz")) == nil)
    #expect(Archives.isArchive(URL(filePath: "/a/b.bz2")))
    let source = root.appending(path: "源")
    try write("你好 $HOME `x`", to: source.appending(path: "说明 '1'.txt"))
    for tool in ["/usr/bin/gzip", "/usr/bin/bzip2"] {
      let made = try await Subprocess.run(
        tool, ["-k", source.appending(path: "说明 '1'.txt").path(percentEncoded: false)])
      try #require(made.status == 0)
    }
    for ext in ["gz", "bz2"] {
      let archive = source.appending(path: "说明 '1'.txt.\(ext)")
      let placed = try #require(await Archives.unpack(archive, password: nil, gbk: false).url)
      #expect(
        placed.lastPathComponent == "说明 '1' 2.txt" || placed.lastPathComponent == "说明 '1' 3.txt")
      #expect(try String(contentsOf: placed, encoding: .utf8) == "你好 $HOME `x`")
    }
    // 末尾补了零的 .gz：gunzip 解完整了、退出码 2，算成了
    let padded = source.appending(path: "补零.txt")
    try write("内容", to: padded)
    _ = try await Subprocess.run("/usr/bin/gzip", [padded.path(percentEncoded: false)])
    let paddedArchive = source.appending(path: "补零.txt.gz")
    let handle = try FileHandle(forWritingTo: paddedArchive)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(count: 512))
    try handle.close()
    let unpadded = try #require(await Archives.unpack(paddedArchive, password: nil, gbk: false).url)
    #expect(try String(contentsOf: unpadded, encoding: .utf8) == "内容")
    #expect(
      Archives.outcome(ofFailure: "gunzip: x.gz: not in gzip format", password: false)
        == .failed("不是压缩包，或者是不支持的格式"))
    let bad = root.appending(path: "坏.gz")
    try Data("not gzip".utf8).write(to: bad)
    #expect(await Archives.unpack(bad, password: nil, gbk: false).url == nil)
    #expect(!FileMoves.occupied(root.appending(path: "坏")))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        .allSatisfy { !$0.hasPrefix(".kitty-") })
  }

  /// 坏的包：说原因，不留临时文件夹
  @Test func brokenArchiveLeavesNothing() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appending(path: "坏.zip")
    try Data("not a zip".utf8).write(to: archive)
    let outcome = await Archives.unpack(archive, password: nil, gbk: false)
    #expect(outcome.url == nil)
    #expect(outcome != .wrongPassword)
    #expect(try names(in: root) == ["坏.zip"])
  }

  /// RAR：系统 tar 解得开（手搓的最小 RAR4，不压缩，里面一个 hello.txt）；主头标着分卷的认出来（RAR4 / RAR5 的头，
  /// RAR5 的取自本机一个真包、只改了分卷那一位）；认不出来的失败原因带上「有密码」
  @Test func rar() async throws {
    let hello: [UInt8] = [
      0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0xCF, 0x90, 0x73, 0x00, 0x00, 0x0D, 0x00, 0x00,
      0x00,
      0x00, 0x00, 0x00, 0x00, 0x08, 0x29, 0x74, 0x00, 0x80, 0x29, 0x00, 0x0A, 0x00, 0x00, 0x00,
      0x0A,
      0x00, 0x00, 0x00, 0x03, 0x9D, 0xD2, 0x80, 0xB1, 0x00, 0x00, 0x6E, 0x5B, 0x14, 0x30, 0x09,
      0x00,
      0xA4, 0x81, 0x00, 0x00, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x2E, 0x74, 0x78, 0x74, 0x68, 0x65,
      0x6C,
      0x6C, 0x6F, 0x20, 0x72, 0x61, 0x72, 0x0A, 0xC4, 0x3D, 0x7B, 0x00, 0x40, 0x07, 0x00,
    ]
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appending(path: "问候.RAR")
    try Data(hello).write(to: archive)
    #expect(Archives.isArchive(archive))
    let outcome = await Archives.unpack(archive, password: nil, gbk: false)
    #expect(outcome.url?.lastPathComponent == "hello.txt")
    #expect(
      try String(contentsOf: root.appending(path: "hello.txt"), encoding: .utf8) == "hello rar\n")

    #expect(!Archives.isRARVolume(Data(hello)))
    var volume4 = hello
    volume4[10] |= 0x01
    #expect(Archives.isRARVolume(Data(volume4)))
    let rar5: [UInt8] = [
      0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, 0x36, 0x17, 0x44, 0xD8, 0x0C, 0x01, 0x05,
      0x08,
      0x00, 0x07, 0x01, 0x01, 0xD8, 0xB2, 0x84, 0x80,
    ]
    #expect(!Archives.isRARVolume(Data(rar5)))
    var volume5 = rar5
    volume5[16] = 0x01
    #expect(Archives.isRARVolume(Data(volume5)))
    #expect(!Archives.isRARVolume(Data(rar5.prefix(14))))  // 截短的不算
    #expect(!Archives.isRARVolume(Data("PK\u{3}\u{4}".utf8)))

    #expect(
      Archives.outcome(ofFailure: "x: Bad RAR file data", password: false, rar: true)
        == .failed("压缩包可能坏了，或者加了密码（RAR 的密码这里解不开）"))
    #expect(
      Archives.outcome(ofFailure: "Encryption is not supported", password: false, rar: true)
        == .failed("这个包加了密码，这里只解得开 zip 的密码"))
  }
}

extension Archives.Outcome {
  fileprivate var url: URL? {
    if case .done(let url) = self { url } else { nil }
  }
}
