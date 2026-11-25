// 访达右键的压缩和解压：名字、tar 的参数、出错原因；在临时文件夹里用系统 tar 真压、真解一遍（zip 标 UTF-8、不带杂文件，
// 7z 往返，tar.gz 往返（不带扩展属性、文件标志，重名加在「.tar.gz」前面），GBK 名字的 zip（先用 ASCII 名字打、再把名字的字节换成 GBK），带密码的 zip 密码不对 / 对），解出来只有一样东西时
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
    // 格式扩充第 1 批：单文件的 .xz / .Z / .lz / .lzma、.aar
    #expect(Archives.isArchive(URL(filePath: "/a/b.xz")))
    #expect(Archives.isArchive(URL(filePath: "/a/b.Z")))
    #expect(Archives.isArchive(URL(filePath: "/a/b.aar")))
    #expect(!Archives.isArchive(URL(filePath: "/a/b.zst")))  // 系统解不了的不认
    #expect(!Archives.isArchive(URL(filePath: "/a/b.tar.lz4")))
    #expect(Archives.stem(of: URL(filePath: "/a/旧.tar.Z")) == "旧")
    #expect(Archives.stem(of: URL(filePath: "/a/c.tar.lzma")) == "c")
    #expect(Archives.tool(for: URL(filePath: "/a/c.tar.lz")) == .tar)
    #expect(Archives.tool(for: URL(filePath: "/a/c.lz")) == .stream("/usr/bin/gunzip"))
    #expect(Archives.tool(for: URL(filePath: "/a/c.cpgz")) == .tar)
    #expect(!Archives.isArchive(URL(filePath: "/a/.zip")))
    #expect(!Archives.isArchive(URL(filePath: "/a/b.zipx")))
    #expect(Archives.stem(of: URL(filePath: "/a/项目 v1.2.tar.gz")) == "项目 v1.2")
    #expect(Archives.stem(of: URL(filePath: "/a/A.TGZ")) == "A")
    #expect(Archives.archiveName(for: [URL(filePath: "/a/b.txt")], format: .zip) == "b.txt.zip")
    #expect(
      Archives.archiveName(for: [URL(filePath: "/a/b"), URL(filePath: "/a/c")], format: .sevenZip)
        == "归档.7z")
    #expect(
      Archives.archiveName(for: [URL(filePath: "/a/b"), URL(filePath: "/a/c")], format: .tarGz)
        == "归档.tar.gz")
    let tarName = Archives.archiveName(
      for: [URL(filePath: "/a/\(String(repeating: "长", count: 300))")], format: .tarGz)
    #expect(tarName.hasSuffix("长.tar.gz") && (tarName.utf16.count + 3) <= 255)
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
    // tar.gz：tar 默认的格式 + gzip；扩展属性、ACL、文件标志都不写进头里（Linux 的 tar 不认、每个文件报一句）
    let tar = Archives.compressArguments(
      [URL(filePath: "/p/a")], format: .tarGz, to: URL(filePath: "/p/.tmp"))
    #expect(Array(tar.prefix(4)) == ["-c", "-v", "-f", "/p/.tmp"])
    let flags = ["-z", "--no-xattrs", "--no-acls", "--no-fflags", "--no-mac-metadata", ".DS_Store"]
    for flag in flags {
      #expect(tar.contains(flag), "\(flag)")
    }
    #expect(!tar.contains("--format") && !tar.contains("--options"))
    #expect(Array(tar.suffix(3)) == ["-C", "/p", "./a"])
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

  /// 设置 › 访达右键 › 压缩时跳过（2026-11-15 改成开关 + 列表）：拆出来的每一条（写错的留着给人看）、哪条不算、
  /// 拼回去旧版本照认、添加框认逗号和结尾的「/」、那一行的小字
  @Test func skipEditing() {
    let text = " node_modules, .git，build/out ,, .git, *.log"
    #expect(Archives.skipEntries(text) == ["node_modules", ".git", "build/out", "*.log"])
    #expect(Archives.skipProblem("build/out") != nil)
    #expect(Archives.skipProblem(String(repeating: "a", count: 101)) != nil)
    #expect(Archives.skipProblem("*.log") == nil)
    // 拼回去的那一行，skipNames 读出来的和原来一样
    let joined = CompressSkipPage.joined(Archives.skipEntries(text))
    #expect(joined == "node_modules, .git, build/out, *.log")
    #expect(Archives.skipNames(joined) == Archives.skipNames(text))
    // 第 51 条起照存、不算
    let many = (0..<52).map(String.init).joined(separator: ",")
    #expect(
      CompressSkipPage.problem("50", applied: Set(Archives.skipNames(many))) != nil)
    #expect(CompressSkipPage.problem("49", applied: Set(Archives.skipNames(many))) == nil)
    // 添加框
    #expect(CompressSkipPage.additions("", to: text).names.isEmpty)
    #expect(CompressSkipPage.additions("", to: text).problem == nil)
    let added = CompressSkipPage.additions(" dist/ ，*.tmp, dist", to: text)
    #expect(added.names == ["dist", "*.tmp"] && added.problem == nil)
    #expect(CompressSkipPage.additions("src/build", to: text).problem != nil)
    #expect(
      CompressSkipPage.additions("ok, src/build", to: text).problem?.hasPrefix("「src/build」")
        == true)
    #expect(CompressSkipPage.problem("build/out", applied: []) == "只认名字、不认路径，这条不算")
    #expect(CompressSkipPage.additions("*", to: text).problem != nil)
    #expect(CompressSkipPage.additions(".git", to: text).problem != nil)
    #expect(CompressSkipPage.additions(".git, dist", to: text).names == ["dist"])
    #expect(CompressSkipPage.additions("x", to: many).problem != nil)
    // 那一行的小字
    #expect(CompressSkipPage.summary("") == "只跳过 Mac 自己的隐藏文件")
    #expect(CompressSkipPage.summary(text) == "node_modules、.git、*.log；1 条写错了、不算")
    #expect(
      CompressSkipPage.summary("a, b, c, d, e") == "a、b、c、d 等 5 个")
    // 常见的几项本身都照跳（不带「/」、不重名）
    let presets = CompressSkipPage.presets.flatMap { $0.items.map(\.name) }
    #expect(presets.allSatisfy { Archives.skipProblem($0) == nil })
    #expect(Set(presets).count == presets.count)
    #expect(presets.allSatisfy { !Archives.junk.contains($0) })
  }

  /// 压缩时跳过（2026-11-13 拍板 Z1 Z2）：逗号（全角半角）隔开、去空白去重、带「/」的不收；交给 find 时 [ ] \ 转义、
  /// 交给 tar -X 的确切路径 * ? [ ] \ 都转义（评审：bsdtar 的 --exclude 跨「/」匹配，不能直接交名单）
  @Test func skipNames() {
    #expect(
      Archives.skipNames(" node_modules, .git，*.log ,, .git") == ["node_modules", ".git", "*.log"])
    #expect(Archives.skipNames("build/out, a") == ["a"])
    #expect(
      Archives.skipNames((0..<80).map(String.init).joined(separator: ",")).count == 50)
    let find = Archives.skipFindArguments(["[old]", "*.log"], roots: ["./a"])
    #expect(find.prefix(4) == ["./a", "(", "-depth", "+0"])
    #expect(find.contains("\\[old\\]") && find.contains("*.log") && find.contains("*.app"))
    #expect(Archives.escapedForTar("./a/[x]*?.log") == "./a/\\[x\\]\\*\\?.log")
    let arguments = Archives.compressArguments(
      [URL(filePath: "/x/a")], format: .zip, to: URL(filePath: "/x/a.zip"),
      excludes: URL(filePath: "/tmp/list"))
    #expect(arguments[arguments.firstIndex(of: "-X")! + 1] == "/tmp/list")
  }

  /// 真压一遍（zip、7z）：任意一层叫这个名字的都不进包；通配不跨文件夹（Screenshot*.png 不扔 Screenshots/ 里的）；
  /// [old] 只认字面；.app 里面不跳；选中的那一样自己叫这个名字时照压、它里面同名的照跳；跳掉的确切路径和大小
  @Test func skipWhileCompressing() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: "项目")
    try write("main", to: project.appending(path: "src/main.js"))
    try write(
      String(repeating: "x", count: 1000), to: project.appending(path: "node_modules/a/b.js"))
    try write("log", to: project.appending(path: "src/run.log"))
    try write("png", to: project.appending(path: "Screenshot1.png"))
    try write("keep", to: project.appending(path: "Screenshots/2024/a.png"))
    try write("old", to: project.appending(path: "[old]/e.txt"))
    try write("o", to: project.appending(path: "o"))
    try write("js", to: project.appending(path: "X.app/Contents/node_modules/d.js"))
    let names = ["node_modules", "*.log", "Screenshot*.png", "[old]"]
    let skipped = await Archives.skipped([project], names: names)
    #expect(
      Set(skipped.map(\.relative)) == [
        "./项目/node_modules", "./项目/src/run.log", "./项目/Screenshot1.png", "./项目/[old]",
      ])
    #expect(await ByteMeter.sizes(of: skipped.map(\.url)).reduce(0, +) == 1000 + 3 + 3 + 3)
    for format in [Archives.Format.zip, .sevenZip] {
      let packed = await Archives.pack(
        [project], format: format, to: root.appending(path: "项目.\(format.rawValue)"), skip: names)
      let archive = try #require(packed.url)
      let listing = try await Subprocess.run(
        "/usr/bin/tar", ["-tf", archive.path(percentEncoded: false)], captures: true,
        environment: ByteMeter.utf8Environment)
      let lines = Set(listing.output.split(whereSeparator: \.isNewline).map(String.init))
      for kept in [
        "项目/src/main.js", "项目/Screenshots/2024/a.png", "项目/o",
        "项目/X.app/Contents/node_modules/d.js",
      ] {
        #expect(lines.contains(kept), "\(format) \(kept)")
      }
      for gone in [
        "项目/node_modules/a/b.js", "项目/src/run.log", "项目/Screenshot1.png", "项目/[old]/e.txt",
      ] {
        #expect(!lines.contains(gone), "\(format) \(gone)")
      }
    }
    // 选中的就是 node_modules：它自己照压，里面再套的 node_modules 照跳
    let modules = project.appending(path: "node_modules")
    try write("nested", to: modules.appending(path: "a/node_modules/n.js"))
    let packed = await Archives.pack(
      [modules], format: .zip, to: root.appending(path: "node_modules.zip"), skip: ["node_modules"])
    let whole = try #require(packed.url)
    let entries = try #require(ZipNames.entries(of: whole))
    let inside = entries.map { String(decoding: $0.name, as: UTF8.self) }
    #expect(inside.contains("node_modules/a/b.js"))
    #expect(!inside.contains { $0.contains("a/node_modules") })
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

  /// tar.gz：真是 gzip、名字是中文、不带杂文件和扩展属性 / 文件标志；再压一次叫「资料 2.tar.gz」（不是「资料.tar 2.gz」），
  /// 解回来是一个文件夹
  @Test func tarGzRoundTrip() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "资料")
    var file = folder.appending(path: "子/说明 文档.txt")
    try write("中", to: file)
    try write("x", to: folder.appending(path: ".DS_Store"))
    try write("x", to: folder.appending(path: "._说明 文档.txt"))
    #expect(setxattr(file.path(percentEncoded: false), "user.kitty", "1", 1, 0, 0) == 0)
    var hidden = URLResourceValues()
    hidden.isHidden = true
    try file.setResourceValues(hidden)

    let name = Archives.archiveName(for: [folder], format: .tarGz)
    #expect(Archives.freeName(name, format: .tarGz, in: root) == "资料.tar.gz")
    let archive = try #require(
      await Archives.pack([folder], format: .tarGz, to: root.appending(path: name)).url)
    #expect(try Data(contentsOf: archive).prefix(2) == Data([0x1F, 0x8B]))
    let listing = try await Subprocess.run(
      "/usr/bin/tar", ["-tf", archive.path(percentEncoded: false)], captures: true,
      environment: ByteMeter.utf8Environment)
    let lines = Set(listing.output.split(whereSeparator: \.isNewline).map(String.init))
    #expect(lines == ["资料/", "资料/子/", "资料/子/说明 文档.txt"])
    let raw = try await Subprocess.run(
      "/usr/bin/gunzip", ["-c", archive.path(percentEncoded: false)], captures: true)
    // pax 头里扩展属性（LIBARCHIVE.xattr.*、SCHILY.xattr.*）、文件标志（SCHILY.fflags）、ACL（SCHILY.acl.*）都没有
    #expect(raw.status == 0 && raw.output.contains("说明 文档.txt"))
    #expect(!raw.output.contains("LIBARCHIVE.") && !raw.output.contains("SCHILY."))
    // 旁边已经有「资料.tar.gz」：「 2」加在整个扩展名前面，解压时还认得出是 tar.gz
    let second = Archives.freeName(name, format: .tarGz, in: root)
    #expect(second == "资料 2.tar.gz")
    #expect(Archives.suffix(of: root.appending(path: second)) == ".tar.gz")

    let placed = try #require(await Archives.unpack(archive, password: nil, gbk: false).url)
    #expect(placed.lastPathComponent == "资料 2")
    file = placed.appending(path: "子/说明 文档.txt")
    #expect(try String(contentsOf: file, encoding: .utf8) == "中")
    #expect(getxattr(file.path(percentEncoded: false), "user.kitty", nil, 0, 0, 0) == -1)
    #expect(try file.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
  }

  /// 只差大小写（2026-11-17 A2）、出错原因里去掉 -v 报的名字、压缩时读不到的那一样（A3）、写不了的位置（B1）：纯函数
  @Test func clashesAndReasons() throws {
    // 按「\n」拆：名字里的 U+2028 不拆开
    let listing = "x src/\nx src/Readme.md\nx src/README.md\nx a\u{2028}b\ntar: 警告\n"
    #expect(
      Archives.extractedEntries(listing) == [
        "src/", "src/Readme.md", "src/README.md", "a\u{2028}b",
      ])
    // 后解的留在盘上；写法一模一样的重复不算
    #expect(
      Archives.caseClashes(["src/", "src/Readme.md", "src/README.md", "a.txt", "a.txt"]) == [
        "src/Readme.md"
      ])
    // 同一个写法后面又来一次：盘上是它最后那一份，不算丢
    #expect(Archives.caseClashes(["A", "a", "A"]) == ["a"])
    #expect(Archives.caseClashes(["a/b", "A/B", "c"]) == ["a/b"])
    // 文件被只差大小写的文件夹顶掉；文件夹之间合在一起不算
    #expect(Archives.caseClashes(["BUILD", "build/", "build/x"]) == ["BUILD"])
    #expect(Archives.caseClashes(["Docs/", "Docs/a", "docs/", "docs/b"]).isEmpty)
    // 同一组丢了不止一个：分两轮，免得在临时文件夹里又撞上
    #expect(
      Archives.rounds(["README", "x", "Readme", "y"]) == [["README", "x", "y"], ["Readme"]])
    // 丢的文件 a 和丢的 A/b 不能一起解（a 是文件，A/ 建不了）
    #expect(Archives.rounds(["a", "A/b", "c"]) == [["a", "c"], ["A/b"]])
    #expect(Archives.escapedForTar("^a$b") == "\\^a\\$b")
    #expect(
      Archives.extractErrors("x encrypted.txt\nx a.txt: Incorrect passphrase\ntar: Error exit")
        == "Incorrect passphrase\ntar: Error exit")
    // 文件名里的字不当成原因：叫 decrypt-notes.txt 的文件、包不完整
    #expect(
      Archives.outcome(
        ofFailure: Archives.extractErrors("x decrypt-notes.txt\ntar: Truncated input file"),
        password: false) == .failed("压缩包不完整，可能没下载完"))

    let visit = """
      tar: Couldn't list extended attributes: Permission denied
      tar: ./项目/锁住的夹: Couldn't visit directory: Permission denied
      """
    let folder = try #require(Archives.unreadable(visit))
    #expect(folder.name == "锁住的夹" && folder.denied && !folder.missing)
    #expect(
      Archives.packFailure("tar: Can't open `a/锁着.txt': Permission denied", format: .zip)
        == "「锁着.txt」读不到（没有权限）")
    #expect(
      Archives.packFailure("tar: ./不存在: Cannot stat: No such file or directory", format: .zip)
        == "「不存在」不见了（压缩时被移走或改了名）")
    #expect(
      Archives.packFailure("tar: Failed to open '/x/.kitty-1'", format: .tarGz) == "没有权限读写这个位置")
    #expect(
      Archives.packFailure("tar: No space left on device", format: .sevenZip)
        == "磁盘空间不够了（7z、ISO 还要先在启动盘上暂存一份）")
    #expect(Archives.packFailure("tar: 别的", format: .zip) == "有文件读不到（被移走、改名了，或者没有权限）")
  }

  /// 包里有只差大小写的两个文件：两个都留，被盖掉的那个名字加「 2」；压缩时有文件读不到，说出是哪个；写不了的文件夹先认出来
  @Test func clashKeepsBothAndUnreadableIsNamed() async throws {
    let root = try makeRoot()
    defer {
      _ = chmod(root.appending(path: "只读").path(percentEncoded: false), 0o755)
      _ = chmod(root.appending(path: "项目/锁着.txt").path(percentEncoded: false), 0o644)
      try? FileManager.default.removeItem(at: root)
    }
    // 先用两个不一样的名字打，打的时候让 tar 把其中一个改成只差大小写的写法（Mac 的盘上造不出这两个文件）
    try write("一", to: root.appending(path: "src/Readme.md"))
    try write("二", to: root.appending(path: "src/READMEX.md"))
    let archive = root.appending(path: "撞名.zip")
    let made = try await Subprocess.run(
      "/usr/bin/tar",
      [
        "-c", "-f", archive.path(percentEncoded: false), "--format", "zip", "-s",
        "|READMEX|README|",
        "-C", root.path(percentEncoded: false), "src",
      ], captures: true)
    #expect(made.status == 0)
    let unpacked = await Archives.unpack(archive, password: nil, gbk: false)
    guard case .done(let placed, let renamed, let unsaved) = unpacked else {
      Issue.record("没解开：\(unpacked)")
      return
    }
    #expect(renamed.count == 1 && renamed[0].hasSuffix(" 2.md") && unsaved == 0)
    let names = try names(in: placed)
    #expect(names.count == 2 && names.contains(renamed[0]))
    let texts = try Set(
      names.map { try String(contentsOf: placed.appending(path: $0), encoding: .utf8) })
    #expect(texts == ["一", "二"])

    // 文件 BUILD 被后面的文件夹 build/ 顶掉：另存成「BUILD 2」
    let tree = root.appending(path: "树")
    try write("文件", to: tree.appending(path: "BUILDX"))
    try write("里面", to: tree.appending(path: "build/x"))
    let mixed = root.appending(path: "顶掉.tar")
    let packedTree = try await Subprocess.run(
      "/usr/bin/tar",
      [
        "-c", "-f", mixed.path(percentEncoded: false), "-s", "|BUILDX|BUILD|", "-C",
        tree.path(percentEncoded: false), "BUILDX", "build",
      ], captures: true)
    #expect(packedTree.status == 0)
    guard
      case .done(let out, let saved, 0) = await Archives.unpack(mixed, password: nil, gbk: false)
    else {
      Issue.record("文件被文件夹顶掉的包没解好")
      return
    }
    #expect(saved == ["BUILD 2"])
    #expect(try String(contentsOf: out.appending(path: "BUILD 2"), encoding: .utf8) == "文件")
    #expect(try String(contentsOf: out.appending(path: "build/x"), encoding: .utf8) == "里面")

    // 压缩时有文件读不到：说出是哪个
    try write("ok", to: root.appending(path: "项目/好.txt"))
    try write("secret", to: root.appending(path: "项目/锁着.txt"))
    #expect(chmod(root.appending(path: "项目/锁着.txt").path(percentEncoded: false), 0) == 0)
    let packed = await Archives.pack(
      [root.appending(path: "项目")], format: .zip, to: root.appending(path: "项目.zip"))
    #expect(packed == .failed("「锁着.txt」读不到（没有权限）"))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "项目.zip").path))

    // 写不了的文件夹：动手前就认出来
    let locked = root.appending(path: "只读")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    #expect(Archives.unwritable(root) == nil)
    #expect(chmod(locked.path(percentEncoded: false), 0o555) == 0)
    #expect(Archives.unwritable(locked) == "没有权限写这个位置")
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
    // 只看这两条：同时在跑的别的测试（做 DMG 要几秒）会往换上来的这本账里记它们自己的临时名
    let gone = {
      let now = ledger.stringArray(forKey: Prefs.finderTemporaries) ?? []
      return !now.contains(FileMoves.plainPath(left)) && !now.contains(FileMoves.plainPath(mine))
    }
    for _ in 0..<200 where !gone() {
      try await Task.sleep(for: .milliseconds(20))
    }
    list = ledger.stringArray(forKey: Prefs.finderTemporaries) ?? []
    #expect(gone(), "\(list)")
    #expect(!FileMoves.occupied(left))
    #expect(FileMoves.occupied(mine.appending(path: "留着.txt")))
  }

  /// 只压了一个文件的 .gz / .bz2：解出来叫包名去掉扩展名，放在旁边；.tar.gz 照旧是 tar 包；坏的说原因、不留东西
  @Test func singleFileCompressed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(Archives.tool(for: URL(filePath: "/a/b.txt.gz")) == .stream("/usr/bin/gunzip"))
    #expect(Archives.tool(for: URL(filePath: "/a/b.tar.gz")) == .tar)
    #expect(
      Archives.singleFileCommand(URL(filePath: "/a/b.tar.gz"), to: URL(filePath: "/o")) == nil)
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

  /// 格式扩充第 1 批：只压了一个文件的 .xz、.Z、.lz（系统 gunzip）、.lzma（compression_tool）；样本用系统 tar 的 raw 格式、
  /// compress 造
  @Test func moreSingleFileStreams() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = String(repeating: "第一行 hello\n", count: 200)
    try write(text, to: root.appending(path: "说明.txt"))
    let folder = root.path(percentEncoded: false)
    let path = { (name: String) in root.appending(path: name).path(percentEncoded: false) }
    for (ext, option) in [("xz", "-J"), ("lz", "--lzip"), ("lzma", "--lzma")] {
      let made = try await Subprocess.run(
        "/usr/bin/tar",
        ["--format", "raw", option, "-cf", path("说明.txt." + ext), "-C", folder, "说明.txt"])
      try #require(made.status == 0)
    }
    let compressed = try await Subprocess.run(
      "/bin/sh",
      [
        "-c", "exec /usr/bin/compress -c -- \"$0\" > \"$1\"", path("说明.txt"), path("说明.txt.Z"),
      ])
    try #require(compressed.status == 0)
    for ext in ["xz", "lz", "lzma", "Z"] {
      let outcome = await Archives.unpack(
        root.appending(path: "说明.txt." + ext), password: nil, gbk: false)
      let placed = try #require(outcome.url, "\(ext)：\(outcome)")
      #expect(try String(contentsOf: placed, encoding: .utf8) == text, "\(ext)")
      try FileManager.default.removeItem(at: placed)
    }
    // 坏的 .lzma：说原因、不留东西
    let bad = root.appending(path: "坏.lzma")
    try Data("not lzma".utf8).write(to: bad)
    #expect(await Archives.unpack(bad, password: nil, gbk: false).url == nil)
    #expect(try names(in: root).allSatisfy { !$0.hasPrefix(".kitty-") })
  }

  /// .aar（aa extract）：往返、不要 .DS_Store；坏的说原因
  @Test func appleArchive() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "源")
    try write("一", to: source.appending(path: "资料/一.txt"))
    try write("二", to: source.appending(path: "资料/子/二.txt"))
    try write("杂", to: source.appending(path: "资料/.DS_Store"))
    let archive = root.appending(path: "资料.aar")
    let made = try await Subprocess.run(
      "/usr/bin/aa",
      [
        "archive", "-d", source.path(percentEncoded: false), "-subdir", "资料", "-o",
        archive.path(percentEncoded: false),
      ])
    try #require(made.status == 0)
    #expect(Archives.tool(for: archive) == .appleArchive)
    let placed = try #require(await Archives.unpack(archive, password: nil, gbk: false).url)
    #expect(placed.lastPathComponent == "资料")
    #expect(try names(in: placed) == ["一.txt", "子"])
    #expect(
      try String(contentsOf: placed.appending(path: "子/二.txt"), encoding: .utf8) == "二")
    let bad = root.appending(path: "坏.aar")
    try Data("not aar".utf8).write(to: bad)
    #expect(await Archives.unpack(bad, password: nil, gbk: false).url == nil)
    #expect(try names(in: root).allSatisfy { !$0.hasPrefix(".kitty-") })
    #expect(
      Archives.outcome(ofFailure: "Failed to create decryption stream", password: false)
        == .failed("这个包加了密码，这里只解得开 zip 的密码"))
  }

  /// Deflate64 的 zip：系统 tar 不支持，换系统 unzip（手搓的最小包：方法 9，数据是一个不压缩的 deflate 块，Deflate64 里同样合法）；
  /// unzip 说密码不对时报成密码不对
  @Test func deflate64FallsBackToUnzip() async throws {
    let zip: [UInt8] = [
      0x50, 0x4B, 0x03, 0x04, 0x15, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBC,
      0x52, 0x1A, 0x15, 0x15, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
      0x64, 0x36, 0x34, 0x2E, 0x74, 0x78, 0x74, 0x01, 0x10, 0x00, 0xEF, 0xFF, 0x68, 0x65, 0x6C,
      0x6C, 0x6F, 0x20, 0x64, 0x65, 0x66, 0x6C, 0x61, 0x74, 0x65, 0x36, 0x34, 0x0A, 0x50, 0x4B,
      0x01, 0x02, 0x15, 0x03, 0x15, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBC,
      0x52, 0x1A, 0x15, 0x15, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA4, 0x81, 0x00, 0x00, 0x00, 0x00, 0x64,
      0x36, 0x34, 0x2E, 0x74, 0x78, 0x74, 0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x01, 0x00, 0x35, 0x00, 0x00, 0x00, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appending(path: "大文件.zip")
    try Data(zip).write(to: archive)
    let placed = try #require(await Archives.unpack(archive, password: nil, gbk: false).url)
    #expect(placed.lastPathComponent == "d64.txt")
    #expect(try String(contentsOf: placed, encoding: .utf8) == "hello deflate64\n")
    #expect(try names(in: root) == ["d64.txt", "大文件.zip"])
    #expect(
      Archives.needsUnzip(
        "d64.txt: Unsupported ZIP compression method (9: deflation-64-bit): Inappropriate file type"
      ))
    #expect(!Archives.needsUnzip("x: Unsupported ZIP compression method (99: aes)"))
    #expect(
      Archives.outcome(ofFailure: "\nincorrect password", password: true) == .wrongPassword)
    let arguments = Archives.unzipArguments(
      archive, into: URL(filePath: "/w"), password: "-d")
    // 密码和 -P 连写（「-」开头的不被当成选项）；没有也给一个（不然 unzip 说 unable to get password）
    #expect(arguments.prefix(2) == ["-o", "-P-d"] && arguments.suffix(2) == ["-d", "/w"])
    #expect(
      Archives.unzipArguments(archive, into: URL(filePath: "/w"), password: nil)[1]
        == "-Pkitty-no-password")
    #expect(
      Archives.outcome(
        ofFailure: "skipping: incorrect password.txt  bad zipfile offset", password: true)
        != .wrongPassword)
    // 名字带通配符、同一个文件夹里还有能匹配上的包：解的还是右键的那个（unzip 拿到的是名字干净的符号链接）
    let tricky = root.appending(path: "a[12].zip")
    try Data(zip).write(to: tricky)
    try write("别的包", to: root.appending(path: "别的/b.txt"))
    let sibling = try await Subprocess.run(
      "/usr/bin/tar",
      [
        "--format", "zip", "-cf", root.appending(path: "a1.zip").path(percentEncoded: false), "-C",
        root.path(percentEncoded: false), "别的",
      ])
    try #require(sibling.status == 0)
    try FileManager.default.removeItem(at: placed)
    let again = try #require(await Archives.unpack(tricky, password: nil, gbk: false).url)
    #expect(again.lastPathComponent == "d64.txt")
    #expect(try String(contentsOf: again, encoding: .utf8) == "hello deflate64\n")
    #expect(try names(in: root).allSatisfy { !$0.hasPrefix("别的 ") })  // 没解成 a1.zip
  }

  /// cpio、xar 在 tar -v 里列文件夹不带「/」：下面还有条目的算文件夹，只差大小写的两个文件夹不算撞名（评审）
  @Test func clashFoldersWithoutSlash() {
    #expect(Archives.caseClashes(["Src", "Src/a.txt", "src", "src/b.txt"]).isEmpty)
    #expect(Archives.caseClashes(["Read", "read"]) == ["Read"])
    #expect(Archives.caseClashes(["BUILD", "build", "build/x"]) == ["BUILD"])
  }

  /// 格式扩充第 2 批：各格式、各级别交给 tar / hdiutil 的参数，ISO 的卷名，两段扩展名的重名
  @Test func formatsAndLevels() {
    let items = [URL(filePath: "/p/资料")]
    let out = URL(filePath: "/p/.tmp")
    let options = { (format: Archives.Format, level: Archives.Level) -> String? in
      let arguments = Archives.compressArguments(
        items, format: format, to: out, level: level, volume: "资料")
      return arguments.firstIndex(of: "--options").map { arguments[$0 + 1] }
    }
    // 标准 = 和原来一样（不写级别）
    #expect(options(.zip, .normal) == "zip:hdrcharset=UTF-8")
    #expect(options(.zip, .fast) == "zip:hdrcharset=UTF-8,zip:compression-level=1")
    #expect(options(.sevenZip, .small) == "7zip:compression=lzma2,7zip:compression-level=9")
    #expect(options(.tarGz, .normal) == nil)
    #expect(options(.tarBz2, .fast) == "bzip2:compression-level=1")
    // 这种格式没有的级别照标准：bzip2 默认就是 9，「更小」不给
    #expect(options(.tarBz2, .small) == nil)
    #expect(Archives.Format.tarBz2.levels == [.fast, .normal])
    #expect(Archives.Format.dmg.levels == [.normal, .small])
    #expect(options(.tarXz, .small) == "xz:compression-level=9")
    // iso-level 3：单个文件可以超过 4 GB（2 级时 tar 跳过大文件还退出 0，评审实测）
    #expect(options(.iso, .small) == "iso9660:volume-id=资料,iso9660:iso-level=3")
    for (format, flag) in [(Archives.Format.tarGz, "-z"), (.tarBz2, "-j"), (.tarXz, "-J")] {
      let arguments = Archives.compressArguments(items, format: format, to: out)
      #expect(arguments.contains(flag) && arguments.contains("--no-xattrs"), "\(format)")
    }
    let tar = Archives.compressArguments(items, format: .tar, to: out)
    #expect(
      !tar.contains("-z") && !tar.contains("-j") && !tar.contains("-J") && !tar.contains("--format")
    )
    #expect(tar.contains("--no-xattrs"))
    #expect(!Archives.Format.tar.hasLevels && !Archives.Format.iso.hasLevels)
    #expect(Archives.Format.dmg.hasLevels && Archives.Format.tarXz.title == "TAR.XZ")
    // 面板里列全了，每种都有一句说明
    #expect(Set(CompressOptions.formats) == Set(Archives.Format.allCases))
    #expect(Archives.Format.allCases.allSatisfy { !CompressOptions.hint(for: $0).isEmpty })

    // ISO 的卷名：32 个字节以内、不带逗号（tar 的限制）；DMG 原样
    let long = String(repeating: "长", count: 40) + ".iso"
    let volume = Archives.volumeName(of: long, format: .iso)
    #expect(volume.utf8.count <= 32 && volume.hasPrefix("长长"))
    #expect(Archives.volumeName(of: "a,b.iso", format: .iso) == "ab")
    #expect(Archives.volumeName(of: ",.iso", format: .iso) == "ISO")
    #expect(Archives.volumeName(of: "归档 2.dmg", format: .dmg) == "归档 2")

    // DMG：级别对应映像格式，每一样一个 -srcfolder
    let image = Archives.imageArguments(
      [URL(filePath: "/p/a"), URL(filePath: "/q/b.txt")], to: URL(filePath: "/p/.t/x.dmg"),
      volume: "x", level: .small)
    #expect(image.prefix(5) == ["create", "-fs", "APFS", "-volname", "x"])
    #expect(image.contains("ULMO") && image.suffix(2) == ["-o", "/p/.t/x.dmg"])
    #expect(image.filter { $0 == "-srcfolder" }.count == 2)
    let fast = Archives.imageArguments(
      [URL(filePath: "/p/a")], to: URL(filePath: "/x.dmg"), volume: "x", level: .fast)
    #expect(fast.contains("ULFO") && !fast.contains("UDZO"))  // DMG 没有「更快」，照标准
  }

  /// TAR.BZ2、TAR.XZ、TAR、ISO 真压、真解（ISO 用 tar 列出来看）；两段扩展名的重名加在整个扩展名前面
  @Test func moreFormatsRoundTrip() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "资料")
    try write("中文内容", to: folder.appending(path: "子/说明.txt"))
    try write("x", to: folder.appending(path: ".DS_Store"))
    for format in [Archives.Format.tarBz2, .tarXz, .tar] {
      for level in Archives.Level.allCases where format.hasLevels || level == .normal {
        let name = Archives.archiveName(for: [folder], format: format)
        let target = root.appending(path: Archives.freeName(name, format: format, in: root))
        let archive = try #require(
          await Archives.pack([folder], format: format, to: target, level: level).url,
          "\(format) \(level)")
        let placed = try #require(await Archives.unpack(archive, password: nil, gbk: false).url)
        #expect(
          try String(contentsOf: placed.appending(path: "子/说明.txt"), encoding: .utf8) == "中文内容")
        #expect(!FileManager.default.fileExists(atPath: placed.appending(path: ".DS_Store").path))
        try FileManager.default.removeItem(at: placed)
      }
    }
    // 三种级别各打了一个：「资料.tar.xz」「资料 2.tar.xz」「资料 3.tar.xz」（「 2」在整个扩展名前面），再解压时还认得出是 tar 包
    #expect(try Set(["资料.tar.xz", "资料 2.tar.xz", "资料 3.tar.xz"]).isSubset(of: names(in: root)))
    let next = Archives.freeName("资料.tar.xz", format: .tarXz, in: root)
    #expect(next == "资料 4.tar.xz")
    #expect(Archives.tool(for: root.appending(path: next)) == .tar)

    let iso = try #require(
      await Archives.pack(
        [folder], format: .iso, to: root.appending(path: "资料.iso")
      ).url)
    let listing = try await Subprocess.run(
      "/usr/bin/tar", ["-tf", iso.path(percentEncoded: false)], captures: true,
      environment: ByteMeter.utf8Environment)
    #expect(listing.status == 0 && listing.output.contains("资料/子/说明.txt"))
    #expect(!listing.output.contains(".DS_Store"))
  }

  /// 分别压缩每一项：一样一个包、各放在旁边，排成一批（等它们出现）
  @Test func compressEachMakesOnePerItem() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("甲", to: root.appending(path: "甲/a.txt"))
    try write("乙", to: root.appending(path: "乙.txt"))
    Archives.compressEach(
      [root.appending(path: "甲"), root.appending(path: "乙.txt")], format: .tarXz, level: .fast,
      island: nil)
    let wanted = ["甲.tar.xz", "乙.txt.tar.xz"]
    for _ in 0..<500 where !(try Set(wanted).isSubset(of: names(in: root))) {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try names(in: root) == ["乙.txt", "乙.txt.tar.xz", "甲", "甲.tar.xz"])
  }

  /// DMG：hdiutil 做映像、校验得过；临时文件夹不留
  @Test func diskImage() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let one = root.appending(path: "甲")
    try write("一", to: one.appending(path: "一.txt"))
    try write("二", to: root.appending(path: "二.txt"))
    let archive = try #require(
      await Archives.pack(
        [one, root.appending(path: "二.txt")], format: .dmg, to: root.appending(path: "归档.dmg"),
        level: .fast
      ).url)
    #expect(archive.lastPathComponent == "归档.dmg")
    let verify = try await Subprocess.run(
      "/usr/bin/hdiutil", ["verify", "-quiet", archive.path(percentEncoded: false)])
    #expect(verify.status == 0)
    #expect(try names(in: root) == ["二.txt", "归档.dmg", "甲"])
    // 没做完时找自己挂着的临时映像：只认路径里带着这次临时文件夹名字的，给整块的那个设备
    let info: [String: Any] = [
      "images": [
        [
          "image-path": "/Users/a/.kitty-ABC/归档.dmg",
          "system-entities": [["dev-entry": "/dev/disk4s1"], ["dev-entry": "/dev/disk4"]],
        ],
        ["image-path": "/Users/a/别的.dmg", "system-entities": [["dev-entry": "/dev/disk6"]]],
      ]
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    #expect(Archives.attachedDevices(data, containing: "/.kitty-ABC/") == ["/dev/disk4"])
    #expect(Archives.attachedDevices(Data("不是 plist".utf8), containing: "/.kitty-ABC/").isEmpty)
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
    if case .done(let url, _, _) = self { url } else { nil }
  }
}
