// 访达右键整理文件：能不能搬、叫什么，在临时文件夹里真移动 / 复制一遍（不覆盖、不合并、符号链接拷成链接、停下不留半截），
// 替身真能找回原件。只动临时文件夹，不碰用户的文件和偏好。

import Foundation
import Testing

@testable import KittyTools

@MainActor struct FileMovesTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "FileMovesTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// 挪进自己里面不行（不分大小写）；移动时本来就在那里的不搬，复制可以
  @Test func movableRules() {
    let folder = URL(filePath: "/tmp/kitty-x/项目", directoryHint: .isDirectory)
    #expect(!FileMoves.movable(folder, into: folder, move: false))
    #expect(!FileMoves.movable(folder, into: URL(filePath: "/tmp/kitty-x/项目/子"), move: false))
    #expect(!FileMoves.movable(folder, into: URL(filePath: "/TMP/kitty-X/项目/子"), move: true))
    let file = URL(filePath: "/tmp/kitty-x/a.txt")
    #expect(!FileMoves.movable(file, into: URL(filePath: "/tmp/kitty-x/"), move: true))
    #expect(FileMoves.movable(file, into: URL(filePath: "/tmp/kitty-x/"), move: false))
    #expect(FileMoves.movable(file, into: folder, move: true))
  }

  /// 重名让开：这一批前面占了的也算、不分大小写；~ 只认「~」「~/…」
  @Test func freeNamesAndTilde() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appending(path: "a.txt"))
    #expect(FileMoves.freeName("a.txt", in: root, used: []) == "a 2.txt")
    #expect(FileMoves.freeName("A.TXT", in: root, used: ["a 2.txt"]) == "A 3.TXT")
    #expect(FileMoves.freeName("b.txt", in: root, used: ["b.txt"]) == "b 2.txt")
    #expect(FileMoves.expand("~/Desktop", home: "/Users/x") == "/Users/x/Desktop")
    #expect(FileMoves.expand("~", home: "/Users/x") == "/Users/x")
    #expect(FileMoves.expand("~other/Desktop", home: "/Users/x") == "~other/Desktop")
    #expect(
      FileMoves.plainPath(URL(filePath: "/a/b/", directoryHint: .isDirectory))
        == FileMoves.plainPath(URL(filePath: "/a/b")))
  }

  /// 做不了时说原因：文件夹不在了（不替它建回来）、已经在那里、放进自己里面、主目录只能复制
  @Test func refusalReasons() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "a.txt")
    try Data().write(to: file)
    let folder = root.appending(path: "文件夹")
    try FileManager.default.createDirectory(
      at: folder.appending(path: "子"), withIntermediateDirectories: true)
    let gone = root.appending(path: "没了")
    #expect(
      FileMoves.refusal([file], into: gone, move: true, place: "没了")?.hasPrefix("「没了」不在了") == true)
    #expect(!FileMoves.occupied(gone))
    #expect(FileMoves.refusal([file], into: root, move: true, place: "根") == "已经在「根」里了")
    #expect(FileMoves.refusal([file], into: root, move: false, place: "根") == nil)
    #expect(
      FileMoves.refusal([folder], into: folder.appending(path: "子"), move: false, place: "子")
        == "不能放进它自己里面")
    let home = URL(filePath: NSHomeDirectory())
    #expect(
      FileMoves.refusal([home], into: root, move: true, place: "根")?.contains("可以复制") == true)
    #expect(FileMoves.refusal([file], into: folder, move: true, place: "文件夹") == nil)
  }

  /// 复制：重名加「 2」、不覆盖、拷进已有的同名文件夹不合并；原件还在
  @Test func copyNeverOverwritesOrMerges() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let from = root.appending(path: "来源")
    let to = root.appending(path: "目标 & 文件夹")
    try FileManager.default.createDirectory(
      at: from.appending(path: "资料"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: to.appending(path: "资料"), withIntermediateDirectories: true)
    try Data("新".utf8).write(to: from.appending(path: "资料/说明.txt"))
    try Data("旧".utf8).write(to: to.appending(path: "资料/说明.txt"))
    try Data("一".utf8).write(to: from.appending(path: "报告.txt"))
    try Data("旧".utf8).write(to: to.appending(path: "报告.txt"))

    let outcome = await FileMoves.execute(
      [from.appending(path: "报告.txt"), from.appending(path: "资料")], into: to, move: false)
    #expect(outcome.failed == 0)
    #expect(outcome.done.map(\.lastPathComponent) == ["报告 2.txt", "资料 2"])
    #expect(try String(contentsOf: to.appending(path: "报告.txt"), encoding: .utf8) == "旧")
    #expect(try String(contentsOf: to.appending(path: "资料/说明.txt"), encoding: .utf8) == "旧")
    #expect(try String(contentsOf: to.appending(path: "资料 2/说明.txt"), encoding: .utf8) == "新")
    #expect(FileMoves.occupied(from.appending(path: "报告.txt")))
    // 没留下隐藏的临时名
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: to.path(percentEncoded: false))
        .allSatisfy { !$0.hasPrefix(".kitty-") })
  }

  /// 移动：同一个卷上是改名，原件没了；本来就在那里的不动
  @Test func moveRenamesOnSameVolume() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let from = root.appending(path: "来源")
    let to = root.appending(path: "目标")
    try FileManager.default.createDirectory(
      at: from.appending(path: "子 文件夹"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
    try Data("二".utf8).write(to: from.appending(path: "子 文件夹/里面.txt"))
    try Data().write(to: to.appending(path: "已在.txt"))
    let outcome = await FileMoves.execute(
      [from.appending(path: "子 文件夹"), to.appending(path: "已在.txt")], into: to, move: true)
    #expect(outcome.failed == 0)
    #expect(outcome.done.map(\.lastPathComponent) == ["子 文件夹"])
    #expect(!FileMoves.occupied(from.appending(path: "子 文件夹")))
    #expect(FileMoves.occupied(to.appending(path: "子 文件夹/里面.txt")))
    #expect(FileMoves.occupied(to.appending(path: "已在.txt")))
  }

  /// 复制符号链接拷的是链接本身（ditto 会顺着链接整棵拷过去）
  @Test func copyKeepsSymlinks() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let big = root.appending(path: "大文件夹")
    try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: big.appending(path: "里面.txt"))
    let link = root.appending(path: "链接")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
    let to = root.appending(path: "目标")
    try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
    let outcome = await FileMoves.execute([link], into: to, move: false)
    #expect(outcome.done.count == 1)
    let copied = to.appending(path: "链接")
    #expect((try? copied.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true)
  }

  /// 跨卷移动：先拷到临时名、落下正式名字、再删原件（按需跑：TEST_RUNNER_KITTY_LIVE_VOLUME=1，会挂一个 20 MB 的磁盘映像，
  /// 不在访达里露面，跑完推出）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_VOLUME"] == "1"))
  func moveAcrossVolumes() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appending(path: "卷.dmg")
    let mount = root.appending(path: "挂载点")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let create = try await Subprocess.run(
      "/usr/bin/hdiutil",
      [
        "create", "-size", "20m", "-fs", "APFS", "-volname", "KittyMoves",
        image.path(percentEncoded: false),
      ])
    try #require(create.status == 0)
    let attach = try await Subprocess.run(
      "/usr/bin/hdiutil",
      [
        "attach", "-nobrowse", "-mountpoint", mount.path(percentEncoded: false),
        image.path(percentEncoded: false),
      ])
    try #require(attach.status == 0)
    defer {
      _ = Task {
        _ = try? await Subprocess.run(
          "/usr/bin/hdiutil", ["detach", "-force", mount.path(percentEncoded: false)])
      }
    }
    let folder = root.appending(path: "资料")
    try FileManager.default.createDirectory(
      at: folder.appending(path: "子"), withIntermediateDirectories: true)
    try Data("内容".utf8).write(to: folder.appending(path: "子/说明.txt"))
    try FileManager.default.createDirectory(
      at: mount.appending(path: "资料"), withIntermediateDirectories: true)
    #expect(!FileMoves.sameVolume(folder, mount))
    let outcome = await FileMoves.execute([folder], into: mount, move: true)
    #expect(outcome.failed == 0)
    #expect(outcome.done.map(\.lastPathComponent) == ["资料 2"])
    #expect(!FileMoves.occupied(folder))
    #expect(
      try String(contentsOf: mount.appending(path: "资料 2/子/说明.txt"), encoding: .utf8) == "内容")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: mount.path(percentEncoded: false))
        .allSatisfy { !$0.hasPrefix(".kitty-") })
    _ = try await Subprocess.run(
      "/usr/bin/hdiutil", ["detach", "-force", mount.path(percentEncoded: false)])
  }

  /// 落到正式名字：已有同名的（文件、文件夹）不盖掉，换一个名字
  @Test func landNeverReplaces() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let item = root.appending(path: "新")
    try Data("新".utf8).write(to: item)
    try Data("旧".utf8).write(to: root.appending(path: "目标"))
    let placed = try #require(FileMoves.land(item, at: root.appending(path: "目标")))
    #expect(placed.lastPathComponent == "目标 2")
    #expect(try String(contentsOf: root.appending(path: "目标"), encoding: .utf8) == "旧")
    let folder = root.appending(path: "空文件夹")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let other = root.appending(path: "另一个")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    #expect(FileMoves.land(other, at: folder)?.lastPathComponent == "空文件夹 2")
  }

  /// 只差大小写（和 NFC / NFD）的同名
  @Test func caseClashes() {
    #expect(FileMoves.caseClash(["/a/README", "/a/src", "/a/readme"])! == ("README", "readme"))
    #expect(FileMoves.caseClash(["/a/e\u{301}", "/a/\u{e9}"]) != nil)
    #expect(FileMoves.caseClash(["/a/x", "/b/x", "/a/y"]) == nil)
  }

  /// 拷之前看一遍：里面有命名管道的不拷（ditto 会一直卡着）；普通文件夹给出一共几样
  @Test func preflightRefusesPipes() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "有管道")
    try FileManager.default.createDirectory(
      at: folder.appending(path: "子"), withIntermediateDirectories: true)
    try Data().write(to: folder.appending(path: "子/a.txt"))
    let check = await FileMoves.preflight(folder, into: root)
    #expect(check.problem == nil && check.count == 3)
    #expect(mkfifo(folder.appending(path: "子/管道").path(percentEncoded: false), 0o644) == 0)
    #expect(await FileMoves.preflight(folder, into: root).problem?.contains("管道") == true)
  }

  /// 上了锁的文件复制过去照样锁着，名字也落得下；带「不许删」ACL 的文件夹复制过去不带它；扔临时名时锁和 ACL 都删得掉
  @Test func lockedFilesAndACLs() async throws {
    let root = try makeRoot()
    defer {
      for (tool, arguments) in [
        ("/usr/bin/chflags", ["-R", "nouchg", root.path]), ("/bin/chmod", ["-R", "-N", root.path]),
      ] {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
      }
      try? FileManager.default.removeItem(at: root)
    }
    let from = root.appending(path: "来源")
    let to = root.appending(path: "目标")
    try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
    let locked = from.appending(path: "锁着.txt")
    try Data("x".utf8).write(to: locked)
    FileMoves.setImmutable(locked, true)
    let guarded = from.appending(path: "不许删")
    try FileManager.default.createDirectory(at: guarded, withIntermediateDirectories: true)
    let acl = try await Subprocess.run(
      "/bin/chmod", ["+a", "everyone deny delete", guarded.path(percentEncoded: false)])
    try #require(acl.status == 0)
    let outcome = await FileMoves.execute([locked, guarded], into: to, move: false)
    #expect(outcome.failed == 0)
    #expect(FileMoves.immutable(to.appending(path: "锁着.txt")))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: to.path(percentEncoded: false))
        .allSatisfy { !$0.hasPrefix(".kitty-") })
    // 扔临时名：锁着的、带 ACL 的都删得掉
    let junk = root.appending(path: ".kitty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
    try Data().write(to: junk.appending(path: "锁"))
    FileMoves.setImmutable(junk.appending(path: "锁"), true)
    _ = try await Subprocess.run(
      "/bin/chmod", ["+a", "everyone deny delete", junk.path(percentEncoded: false)])
    await FileMoves.discard(junk)
    #expect(!FileMoves.occupied(junk))
  }

  /// 从分大小写的盘移到不分的：里面有只差大小写的两个时不搬，原件不动（按需跑：TEST_RUNNER_KITTY_LIVE_VOLUME=1，挂一个
  /// 20 MB 的分大小写的磁盘映像，不在访达里露面，跑完推出）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_VOLUME"] == "1"))
  func caseClashAcrossVolumes() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appending(path: "分大小写.dmg")
    let mount = root.appending(path: "挂载点")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let create = try await Subprocess.run(
      "/usr/bin/hdiutil",
      [
        "create", "-size", "20m", "-fs", "Case-sensitive APFS", "-volname", "KittyCase",
        image.path(percentEncoded: false),
      ])
    try #require(create.status == 0)
    let attach = try await Subprocess.run(
      "/usr/bin/hdiutil",
      [
        "attach", "-nobrowse", "-mountpoint", mount.path(percentEncoded: false),
        image.path(percentEncoded: false),
      ])
    try #require(attach.status == 0)
    let folder = mount.appending(path: "项目")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("UPPER".utf8).write(to: folder.appending(path: "README"))
    try Data("lower".utf8).write(to: folder.appending(path: "readme"))
    let to = root.appending(path: "目标")
    try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
    let outcome = await FileMoves.execute([folder], into: to, move: true)
    #expect(outcome.done.isEmpty && outcome.failed == 1)
    #expect(outcome.problem?.contains("只差大小写") == true)
    #expect(FileMoves.occupied(folder.appending(path: "README")))
    #expect(FileMoves.occupied(folder.appending(path: "readme")))
    _ = try await Subprocess.run(
      "/usr/bin/hdiutil", ["detach", "-force", mount.path(percentEncoded: false)])
  }

  /// exFAT 的 U 盘（不支持 RENAME_EXCL）：复制进去、盘里移动、改乱码名都照常；从盘上把带「._」的文件夹拷回来不误报
  /// 「少了」。按需跑：TEST_RUNNER_KITTY_LIVE_VOLUME=1，挂一个 20 MB 的 exFAT 映像，不在访达里露面，跑完推出
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_VOLUME"] == "1"))
  func exFATVolume() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appending(path: "U盘.dmg")
    let mount = root.appending(path: "挂载点")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let create = try await Subprocess.run(
      "/usr/bin/hdiutil",
      [
        "create", "-size", "20m", "-fs", "ExFAT", "-volname", "KITTYU",
        image.path(percentEncoded: false),
      ])
    try #require(create.status == 0)
    let attach = try await Subprocess.run(
      "/usr/bin/hdiutil",
      [
        "attach", "-nobrowse", "-mountpoint", mount.path(percentEncoded: false),
        image.path(percentEncoded: false),
      ])
    try #require(attach.status == 0)
    defer {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/hdiutil")
      process.arguments = ["detach", "-force", mount.path(percentEncoded: false)]
      try? process.run()
      process.waitUntilExit()
    }
    // 复制进 U 盘
    let folder = root.appending(path: "资料")
    try FileManager.default.createDirectory(
      at: folder.appending(path: "子"), withIntermediateDirectories: true)
    try Data("内容".utf8).write(to: folder.appending(path: "子/说明.txt"))
    let copied = await FileMoves.execute([folder], into: mount, move: false)
    #expect(copied.failed == 0 && copied.done.map(\.lastPathComponent) == ["资料"])
    // 盘里移动
    let inner = mount.appending(path: "里面")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let moved = await FileMoves.execute([mount.appending(path: "资料")], into: inner, move: true)
    #expect(moved.failed == 0 && FileMoves.occupied(inner.appending(path: "资料/子/说明.txt")))
    // 盘上改乱码名
    let garbled = mount.appending(path: "ÖÐÎÄ.txt")
    try Data().write(to: garbled)
    #expect(NameRepair.rename([garbled]).map(\.to.lastPathComponent) == ["中文.txt"])
    // 盘上的文件带扩展属性（盘上存成「._」文件），拷回来不误报
    let xattr = try await Subprocess.run(
      "/usr/bin/xattr",
      [
        "-w", "com.kitty.test", "1",
        inner.appending(path: "资料/子/说明.txt").path(percentEncoded: false),
      ])
    try #require(xattr.status == 0)
    let back = root.appending(path: "拷回来")
    try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
    let returned = await FileMoves.execute([inner.appending(path: "资料")], into: back, move: false)
    #expect(returned.failed == 0 && returned.problem == nil)
    #expect(FileMoves.occupied(back.appending(path: "资料/子/说明.txt")))
  }

  /// 替身放在指定的「桌面」上，重名加「 2」，解得回原件
  @Test func aliasesResolveToOriginal() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let desktop = root.appending(path: "桌面")
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    let original = root.appending(path: "原件.txt")
    try Data("x".utf8).write(to: original)
    try Data().write(to: desktop.appending(path: "原件.txt"))
    let made = FileMoves.makeAliases([original], in: desktop)
    #expect(made.map(\.lastPathComponent) == ["原件 2.txt"])
    let resolved = try URL(resolvingAliasFileAt: made[0])
    #expect(
      FileMoves.plainPath(resolved.resolvingSymlinksInPath())
        == FileMoves.plainPath(original.resolvingSymlinksInPath()))
  }
}
