// 启动器路径模式（PathBrowser，2026-11-18）：拆输入、⇧Tab 回上一级、筛选和隐藏规则、哪些位置不读、真读一个临时目录，
// 以及启动器里整条路：列出里面的东西、第一行是文件夹本身、按开头筛、Tab 进 ⇧Tab 退、⌘K 的几样、废纸篓只在主文件夹里给

import AppKit
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

struct PathBrowserTests {
  @Test func parsesInput() throws {
    let home = NSHomeDirectory()
    let tilde = try #require(PathBrowser.request(for: "~"))
    #expect(tilde.directory == home && tilde.name.isEmpty && tilde.typedDirectory == "~/")
    let partial = try #require(PathBrowser.request(for: "~/.loc"))
    #expect(partial.directory == home && partial.name == ".loc" && partial.typedDirectory == "~/")
    let root = try #require(PathBrowser.request(for: "/"))
    #expect(root.directory == "/" && root.name.isEmpty)
    let lib = try #require(PathBrowser.request(for: "/usr/lib"))
    #expect(lib.directory == "/usr" && lib.name == "lib" && lib.typedDirectory == "/usr/")
    let inside = try #require(PathBrowser.request(for: "~/.local/"))
    #expect(inside.directory == home + "/.local" && inside.name.isEmpty)
    // 别的用户的主目录、相对路径、空格开头（文件搜索）都不算
    for query in ["~foo", "./x", " /tmp", "tmp/", ""] {
      #expect(PathBrowser.request(for: query) == nil, "\(query)")
    }
  }

  @Test func goesUpOneLevel() {
    #expect(PathBrowser.parentQuery(of: "~/.local/share/") == "~/.local/")
    #expect(PathBrowser.parentQuery(of: "~/.local/sh") == "~/.local/")
    #expect(PathBrowser.parentQuery(of: "/usr/") == "/")
    #expect(PathBrowser.parentQuery(of: "/usr") == "/")
    let up = (NSHomeDirectory() as NSString).deletingLastPathComponent
    #expect(PathBrowser.parentQuery(of: "~/") == (up == "/" ? "/" : up + "/"))
    #expect(PathBrowser.parentQuery(of: "/") == nil)
    #expect(PathBrowser.parentQuery(of: "open x") == nil)
  }

  private func entry(_ name: String, folder: Bool = false, hidden: Bool? = nil) -> PathBrowser.Entry
  {
    PathBrowser.Entry(
      name: name, key: LauncherMatch.fold(name), isFolder: folder, isPackage: false,
      isHidden: hidden ?? name.hasPrefix("."))
  }

  @Test func picksVisibleAndMatching() {
    let entries = PathBrowser.sorted([
      entry("usr", folder: true, hidden: true), entry("Users", folder: true),
      entry(".zshrc"), entry("bin", folder: true, hidden: true),
      entry("Applications", folder: true),
      entry("my-users.txt"),
    ])
    // 没打字：只列看得见的，文件夹在前、名字顺序
    #expect(
      PathBrowser.pick(entries, filter: "", in: "/").entries.map(\.name) == [
        "Applications", "Users", "my-users.txt",
      ])
    // 打了字在全部里找：开头对上的在前（不分大小写），名字中间对上的在后（至少两个字、不带隐藏项）
    #expect(
      PathBrowser.pick(entries, filter: "u", in: "/").entries.map(\.name) == ["Users", "usr"])
    #expect(
      PathBrowser.pick(entries, filter: "us", in: "/").entries.map(\.name) == [
        "Users", "usr", "my-users.txt",
      ])
    #expect(PathBrowser.pick(entries, filter: "sr", in: "/").entries.isEmpty)
    #expect(PathBrowser.pick(entries, filter: ".", in: "/").entries.map(\.name) == [".zshrc"])
    // 进到隐藏文件夹里：全列
    #expect(PathBrowser.pick(entries, filter: "", in: "/Users/x/.local").total == entries.count)
    // 最多 limit 行，total 是一共多少
    let many = (0..<120).map { entry("f\($0)") }
    let picked = PathBrowser.pick(many, filter: "", in: "/tmp")
    #expect(picked.entries.count == PathBrowser.limit && picked.total == 120)
    // 正好是一个文件夹的名字：先比大小写一样的，再不分大小写；文件、空名字不算
    #expect(PathBrowser.folder(named: "users", in: entries)?.name == "Users")
    #expect(PathBrowser.folder(named: ".zshrc", in: entries) == nil)
    #expect(PathBrowser.folder(named: "", in: entries) == nil)
  }

  @Test func skipsProtectedPlaces() {
    let home = "/Users/t"
    let check = { (path: String, access: Bool, volumes: Bool) in
      PathBrowser.problem(at: path, home: home, folderAccess: access, volumes: volumes)
    }
    #expect(check("/Users/t/Documents", false, false) == .needsFolderAccess("文稿"))
    #expect(check("/Users/t/Desktop/a/b", false, false) == .needsFolderAccess("桌面"))
    #expect(check("/Users/t/Documents", true, false) == nil)
    #expect(check("/Users/t/DocumentsX", false, false) == nil)
    #expect(check("/Users/t", false, false) == nil)
    // 容器文件夹本身只是名字；进到某个 App 的容器里不读
    #expect(check("/Users/t/Library/Containers", true, false) == nil)
    #expect(check("/Users/t/Library/Containers/com.x", true, false) == .otherAppsData)
    #expect(check("/Users/t/Library/Group Containers/g.y/z", true, false) == .otherAppsData)
    #expect(check("/Users/t/Library/CloudStorage/Dropbox", true, false) == .otherAppsData)
    // 外接盘、网络盘：点过「允许读取」才读；/Volumes 本身照读
    #expect(check("/Volumes/USB/a", true, false) == .needsVolumeConsent("USB"))
    #expect(check("/Volumes/USB", true, true) == nil)
    #expect(check("/Volumes", true, false) == nil)
    // 盘不分大小写；数据卷的另一个入口；会弹日历、通讯录、照片框的
    #expect(check("/Users/t/documents/x", false, false) == .needsFolderAccess("文稿"))
    #expect(check("/volumes/USB", true, false) == .needsVolumeConsent("USB"))
    #expect(
      check("/System/Volumes/Data/Users/t/Downloads", false, false) == .needsFolderAccess("下载"))
    #expect(check("/Users/t/Library/Calendars", true, true) == .otherAppsData)
    #expect(check("/Users/t/Pictures/Photos Library.photoslibrary/x", true, true) == .otherAppsData)
    #expect(check("/Users/t/Pictures", true, true) == nil)
  }

  /// 真读一个临时目录：文件夹在前（数字按大小）、跟着符号链接认文件夹、包当文件、隐藏标记
  @Test func readsRealDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kitty-path-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FileManager.default
    for folder in ["b", "a10", "a2", "Tool.app"] {
      try manager.createDirectory(
        at: root.appending(path: folder), withIntermediateDirectories: true)
    }
    for file in ["z.txt", ".hidden"] { try Data().write(to: root.appending(path: file)) }
    try manager.createSymbolicLink(
      at: root.appending(path: "link"), withDestinationURL: root.appending(path: "b"))
    let listing = await PathBrowser.read(root.path, folderAccess: true, volumes: true)
    #expect(listing.problem == nil)
    #expect(
      listing.entries.map(\.name) == ["a2", "a10", "b", "link", ".hidden", "Tool.app", "z.txt"])
    #expect(
      PathBrowser.pick(listing.entries, filter: ".", in: root.path).entries.map(\.name) == [
        ".hidden"
      ])
    let tool = try #require(listing.entries.first { $0.name == "Tool.app" })
    #expect(tool.isPackage && !tool.isFolder)
    #expect(listing.entries.first { $0.name == ".hidden" }?.isHidden == true)
    #expect(PathBrowser.contentType(of: tool).conforms(to: .application))
    let missing = await PathBrowser.read(root.path + "/nope", folderAccess: true, volumes: true)
    #expect(missing.problem == .missing)
    #expect(await PathBrowser.missing([root.path, root.path + "/nope"]) == [root.path + "/nope"])
  }

  @Test func trashOnlyInsideHome() {
    let home = "/Users/t"
    #expect(LauncherModel.canTrash("/Users/t/Downloads/a.zip", home: home))
    #expect(LauncherModel.canTrash("/Users/t/.codex", home: home))
    #expect(LauncherModel.canTrash("/Users/t/Library/Caches/x", home: home))
    for path in [
      "/Users/t", "/Users/t/Documents", "/Users/t/Library", "/Users/t/Library/Preferences",
      "/Users/t/library/preferences", "/Users/t/DOCUMENTS",
      "/Applications/X.app", "/Users/other/a", "/Users/t/../other/a",
    ] {
      #expect(!LauncherModel.canTrash(path, home: home), "\(path)")
    }
  }

  /// 启动器里的整条路
  @MainActor @Test func launcherPathMode() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kitty-path-\(UUID())")
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    for folder in ["alpha", "beta/inner"] {
      try FileManager.default.createDirectory(
        at: root.appending(path: folder), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appending(path: "alpine.txt"))
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    let base = root.path

    // 正好是一个文件夹（末尾没有 /）：第一行是它本身，下面是里面的东西
    model.query = base
    await model.pathLookup()
    #expect(model.pathRequest != nil)
    #expect(model.results.map(\.title) == [root.lastPathComponent, "alpha", "beta", "alpine.txt"])
    #expect(model.results[0].completion == base + "/")
    #expect(model.results[1].completion == base + "/alpha/")
    #expect(model.results[3].completion == base + "/alpine.txt")
    #expect(model.results.allSatisfy { $0.kind == .path && $0.contentType != nil })

    // 最后一段没打完：在上一级里按开头筛，没有「这个文件夹」那一行
    model.query = base + "/al"
    await model.pathLookup()
    #expect(model.results.map(\.title) == ["alpha", "alpine.txt"])
    model.query = base + "/zz"
    await model.pathLookup()
    #expect(model.results.isEmpty)
    model.query = base + "/nope/"
    await model.pathLookup()
    #expect(model.results.isEmpty && model.emptyText.contains("找不到"))

    // Tab 进文件夹（补成「…/beta/」，列出 inner），⇧Tab 回上一级
    model.query = base + "/be"
    await model.pathLookup()
    model.complete()
    await model.pathLookup()
    #expect(model.query == base + "/beta/")
    #expect(model.results.map(\.title) == ["beta", "inner"])
    #expect(model.handleCommand(#selector(NSResponder.insertBacktab(_:))))
    #expect(model.query == base + "/")

    // ⌘K：在终端中打开、拷贝文件、复制终端写法的路径；临时目录不在主文件夹里，没有移到废纸篓
    model.query = base + "/alpine"
    await model.pathLookup()
    let titles = model.actions(for: try #require(model.selectedItem)).map(\.title)
    for title in ["快速查看", "在终端中打开", "拷贝文件", "复制终端写法的路径"] {
      #expect(titles.contains(title), "\(title)")
    }
    #expect(!titles.contains("移到废纸篓"))

    // 不在路径模式
    model.query = "alpine"
    #expect(model.pathRequest == nil)
  }

  /// 真机实测（按需：TEST_RUNNER_KITTY_LIVE_PATH=<报告目录>）：用本机真实的文件夹走一遍启动器的路径模式，记下每个输入列出了什么、
  /// 读了多久，写进 <目录>/report.md。只读：不改偏好（读 Dev 版的「问过授权没有」），桌面 / 文稿这类按开关挡住、不会去读
  @MainActor
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_PATH"] != nil))
  func liveRealFolders() async throws {
    let out = try #require(ProcessInfo.processInfo.environment["KITTY_LIVE_PATH"])
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    let containers =
      (try? FileManager.default.contentsOfDirectory(
        atPath: NSHomeDirectory() + "/Library/Containers"))?.sorted().first
    var queries = [
      "~", "~/", "~/.", "~/.loc", "~/.local", "~/L", "/", "/u", "/Applications/", "/usr/bin/",
      "/usr/bin/sw", "~/Documents/", "~/Desktop/", "~/Downloads/", "~/Library/Containers/",
      "~/Library/Calendars/", "/Volumes/", "/tmp", "/nope/",
    ]
    if let containers { queries.append("~/Library/Containers/\(containers)/") }
    var report = "# 路径模式真机实测\n\n本机 \(ProcessInfo.processInfo.operatingSystemVersionString)；"
    report += "问过文件夹授权：\(UserDefaults.standard.bool(forKey: Prefs.folderAccessRequested))\n\n"
    for query in queries {
      let start = ContinuousClock.now
      model.query = query
      await model.pathLookup()
      let elapsed = ContinuousClock.now - start
      let rows = model.results.prefix(8).map { row in
        row.kind == .prompt ? "〔\(row.title)〕" : row.title
      }
      report +=
        "- `\(query)`（\(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))，"
      report += "\(model.results.count) 行）：\(rows.joined(separator: " · "))"
      report += model.results.isEmpty ? "〔空：\(model.emptyText)〕" : ""
      report += "\n"
    }
    try report.write(toFile: out + "/report.md", atomically: true, encoding: .utf8)
  }
}
