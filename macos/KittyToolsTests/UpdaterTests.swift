// 应用内更新：GitHub release 列表的 JSON 解析（混着 Windows 版）、版本比较（纯逻辑）；整条安装链路按需启用——拿 build-dmg.sh 打出来的
// 真 zip 走「下载（file://）→ 解包 → 校验 → 替换」，替换的是临时目录里的假 App，不碰「应用程序」：
//   TEST_RUNNER_KITTY_UPDATE_ZIP="$PWD/macos/build/Kitty Tools_0.1.0_arm64.zip" xcodebuild -project \
//     macos/KittyTools.xcodeproj -scheme KittyTools test -only-testing:KittyToolsTests/UpdaterTests
import Foundation
import Testing
import os

@testable import KittyTools

struct UpdaterTests {
  nonisolated private static let zipPath =
    ProcessInfo.processInfo.environment["KITTY_UPDATE_ZIP"]

  /// 一个 release 的 JSON（GitHub release 列表里的一项）
  private static func entry(
    tag: String, assets: [(String, String)], draft: Bool = false, prerelease: Bool = false
  ) -> String {
    let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }
    return
      #"{"tag_name":"\#(tag)","html_url":"https://github.com/YyAdnBug/kitty-tools/releases/tag/\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(list.joined(separator: ","))]}"#
  }

  /// 只有这一个 release 的列表
  private static func payload(tag: String, assets: [(String, String)]) -> Data {
    Data("[\(entry(tag: tag, assets: assets))]".utf8)
  }

  @Test func parsesLatestRelease() throws {
    let data = Self.payload(
      tag: "macos-v0.2.0",
      assets: [
        ("Kitty.Tools_0.2.0_arm64.dmg", "https://github.com/x/y/releases/download/a/b.dmg"),
        ("Kitty.Tools_0.2.0_arm64.zip", "https://github.com/x/y/releases/download/a/b.zip"),
      ])
    let release = try #require(try Updater.release(from: data))
    #expect(release.version == "0.2.0")
    #expect(release.archive.absoluteString.hasSuffix("b.zip"))
    #expect(release.page.absoluteString.hasSuffix("macos-v0.2.0"))
  }

  @Test func ignoresOtherTagsMissingZipAndPlainHTTP() throws {
    let zip = [("K_0.2.0_arm64.zip", "https://github.com/x/y/b.zip")]
    #expect(try Updater.release(from: Self.payload(tag: "v0.2.0", assets: zip)) == nil)
    #expect(
      try Updater.release(
        from: Self.payload(tag: "macos-v0.2.0", assets: [("K.dmg", "https://github.com/x/y/b.dmg")])
      )
        == nil)
    #expect(
      try Updater.release(
        from: Self.payload(
          tag: "macos-v0.2.0", assets: [("K_arm64.zip", "http://example.com/b.zip")]))
        == nil)
  }

  /// 读的是 release 列表（E13）：Windows 版和 mac 版发在同一个仓库，windows-v* 排在最前（GitHub 的 latest 也是它）时
  /// 照样挑出版本号最大的 macos-v*；草稿、预发布、没有 zip 的跳过；列表里没有 mac 版是 nil
  @Test func picksNewestMacReleaseFromMixedList() throws {
    let zip = { (version: String) in
      [
        (
          "Kitty.Tools_\(version)_arm64.zip",
          "https://github.com/x/y/releases/download/\(version)/b.zip"
        )
      ]
    }
    let windows = [("Kitty.Tools_0.1.1_x64-setup.exe", "https://github.com/x/y/w.exe")]
    let list = [
      Self.entry(tag: "windows-v0.1.1", assets: windows),
      Self.entry(tag: "macos-v0.8.0", assets: zip("0.8.0"), draft: true),
      Self.entry(tag: "macos-v0.7.2", assets: zip("0.7.2"), prerelease: true),
      Self.entry(tag: "macos-v0.7.0", assets: zip("0.7.0")),
      Self.entry(tag: "windows-v0.1.0", assets: windows),
      Self.entry(tag: "macos-v0.7.10", assets: [("K.dmg", "https://github.com/x/y/b.dmg")]),
      Self.entry(tag: "macos-v0.7.1", assets: zip("0.7.1")),
      Self.entry(tag: "macos-v0.6.0", assets: zip("0.6.0")),
    ]
    let release = try #require(
      try Updater.release(from: Data("[\(list.joined(separator: ","))]".utf8)))
    #expect(release.version == "0.7.1")
    #expect(release.archive.absoluteString.contains("/0.7.1/"))
    #expect(release.page.absoluteString.hasSuffix("macos-v0.7.1"))
    // 只有 Windows 版、空列表：没有
    #expect(try Updater.release(from: Data("[\(list[0]),\(list[4])]".utf8)) == nil)
    #expect(try Updater.release(from: Data("[]".utf8)) == nil)
    // 不是列表（读到的还是单个 release 的格式）：解析失败，当成没查成
    #expect(throws: (any Error).self) {
      try Updater.release(from: Data(list[3].utf8))
    }
  }

  /// 更新清单（#12，build-dmg.sh 写的那个形状）：认得出就是那一版、校验值收成小写；网址不是 https、校验值不是 64 位
  /// 十六进制、版本号带别的字、缺键、不是 JSON 都是 nil（退回 API），多出来的键不管
  @Test func parsesManifest() throws {
    func manifest(
      version: String = "0.8.1",
      url: String =
        "https://github.com/YyAdnBug/kitty-tools/releases/download/macos-v0.8.1/Kitty.Tools_0.8.1_arm64.zip",
      sha256: String = String(repeating: "AB", count: 32), extra: String = #","size":123"#
    ) -> Data {
      Data(
        #"{"version":"\#(version)","url":"\#(url)","sha256":"\#(sha256)","page":"https://github.com/YyAdnBug/kitty-tools/releases/tag/macos-v\#(version)"\#(extra)}"#
          .utf8)
    }
    let release = try #require(Updater.release(fromManifest: manifest()))
    #expect(release.version == "0.8.1")
    #expect(release.archive.absoluteString.hasSuffix("/macos-v0.8.1/Kitty.Tools_0.8.1_arm64.zip"))
    #expect(release.page.absoluteString.hasSuffix("/tag/macos-v0.8.1"))
    #expect(release.sha256 == String(repeating: "ab", count: 32))
    #expect(Updater.release(fromManifest: manifest(extra: #","notes":"新的键","size":1"#)) != nil)
    #expect(Updater.release(fromManifest: manifest(url: "http://example.com/K_arm64.zip")) == nil)
    #expect(Updater.release(fromManifest: manifest(sha256: "abc")) == nil)
    #expect(
      Updater.release(fromManifest: manifest(sha256: String(repeating: "g", count: 64))) == nil)
    #expect(Updater.release(fromManifest: manifest(version: "0.8.1-beta")) == nil)
    #expect(Updater.release(fromManifest: manifest(version: "")) == nil)
    #expect(Updater.release(fromManifest: Data(#"{"version":"0.8.1"}"#.utf8)) == nil)
    #expect(Updater.release(fromManifest: Data("<html>404</html>".utf8)) == nil)
  }

  /// 先读清单、读到就不碰 API；清单 404（老 release 没有它）、连不上、解不出来时读 API 的列表；API 限流（403 / 429）时
  /// 报的是「限流了」、指到发布页，不是笼统的「返回 403」（#12）。全是假的网络，不联网
  @MainActor @Test func latestReadsManifestThenFallsBackToAPI() async throws {
    let sha = String(repeating: "0", count: 64)
    let manifest = Data(
      #"{"version":"0.9.0","url":"https://github.com/x/y/K_0.9.0_arm64.zip","sha256":"\#(sha)","page":"https://github.com/x/y"}"#
        .utf8)
    let list = Data(
      "[\(Self.entry(tag: "macos-v0.8.5", assets: [("K_0.8.5_arm64.zip", "https://github.com/x/y/b.zip")]))]"
        .utf8)
    struct Offline: Error {}
    /// 清单那一头怎么答（nil = 连不上），API 那一头怎么答；记下问了哪几个
    func latest(manifest: (Data, Int)?, api: (Data, Int)) async throws -> (
      Updater.Release?, [String]
    ) {
      var asked: [String] = []
      let release = try await Updater.latest { url in
        asked.append(url.host() ?? "")
        if url.host() == "api.github.com" { return api }
        guard let manifest else { throw Offline() }
        return manifest
      }
      return (release, asked)
    }
    let (fromManifest, asked) = try await latest(manifest: (manifest, 200), api: (list, 200))
    #expect(fromManifest?.version == "0.9.0" && fromManifest?.sha256 == sha)
    #expect(asked == ["github.com"], "读到清单就不再问 API")
    for reply in [(Data("Not Found".utf8), 404), (Data("{}".utf8), 200), nil] as [(Data, Int)?] {
      let (fromAPI, asked) = try await latest(manifest: reply, api: (list, 200))
      #expect(fromAPI?.version == "0.8.5" && fromAPI?.sha256 == nil)
      #expect(asked == ["github.com", "api.github.com"])
    }
    #expect(try await latest(manifest: nil, api: (Data(), 404)).0 == nil, "还没有 release")
    for status in [403, 429] {
      await #expect(throws: UpdateError.self) {
        try await latest(manifest: nil, api: (Data(), status))
      }
      let words = Updater.apiFailure(status)
      #expect(words.contains("限流") && words.contains("发布页"), "\(words)")
    }
    #expect(Updater.apiFailure(500) == "GitHub 返回 500")
  }

  /// 清单给了校验值：下好的包对不上就在解包之前拒绝（包随后删掉）；对得上才往下走（这里是个假包，走到 ditto 解不开）
  @Test func checksArchiveDigestBeforeUnpacking() async throws {
    let work = FileManager.default.temporaryDirectory.appending(path: "UpdaterTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: work) }
    let target = work.appending(path: "Apps/Kitty Tools.app")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let archive = try #require(URL(string: "https://github.com/x/y/K_arm64.zip"))
    let ok = try #require(
      HTTPURLResponse(url: archive, statusCode: 200, httpVersion: nil, headerFields: nil))
    func attempt(sha256: String) async throws -> String? {
      let zip = work.appending(path: "\(UUID()).zip")
      try Data("not a zip".utf8).write(to: zip)
      do {
        try await Updater.replace(
          target,
          with: .init(
            version: "0.9.0", archive: archive, page: Updater.releasesPage, sha256: sha256),
          zip: zip, response: ok)
      } catch let error as UpdateError {
        #expect(!FileManager.default.fileExists(atPath: zip.path), "下好的包用完就删")
        return error.errorDescription
      }
      return nil
    }
    #expect(try await attempt(sha256: String(repeating: "0", count: 64))?.contains("校验值") == true)
    // printf 'not a zip' | shasum -a 256
    let real = "a3989126344744ef800dbc88bf7e744853f3f2eac75c9ab3301f4e845ef22078"
    #expect(try await attempt(sha256: real) == "更新包解不开")
  }

  /// build-dmg.sh 写的清单和 App 读的是同一个文件名、同几个键（发版后才会发现对不上，单测先比对）
  @Test func buildScriptWritesTheManifestTheAppReads() throws {
    let script = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "build-dmg.sh"),
      encoding: .utf8)
    #expect(script.contains("/\(Updater.manifestName)\""))
    #expect(
      script.contains("{version: $version, url: $url, sha256: $sha256, size: $size, page: $page}"))
  }

  @Test func comparesVersionsNumerically() {
    #expect(Updater.isNewer("0.1.10", than: "0.1.9"))
    #expect(Updater.isNewer("0.2.0", than: "0.1.0"))
    #expect(Updater.isNewer("1.0.0", than: "0.9.9"))
    #expect(!Updater.isNewer("0.1.0", than: "0.1.0"))
    #expect(!Updater.isNewer("0.1.0", than: "0.2.0"))
  }

  /// 已经发现的新版本在复查期间、没查成时留着（菜单栏角标、面板底栏的「更新到 x」不跟着闪），
  /// 查到更新的换成新的，查到已是最新、开始安装才清
  @Test func installingWordsFollowProgress() {
    // 岛上的后半句和关于页那句话：不知道下了多少 → 下载中的百分比 → 下完了在装
    #expect(Updater.installingDetail(nil) == "装好会自动重新打开")
    #expect(Updater.installingDetail(0) == "已下载 0%")
    #expect(Updater.installingDetail(0.42) == "已下载 42%")
    #expect(Updater.installingDetail(1) == "正在安装，装好会自动重新打开")
    #expect(Updater.installingLine("0.5.0", progress: nil) == "正在更新到 0.5.0…")
    #expect(Updater.installingLine("0.5.0", progress: 0.42) == "正在下载 0.5.0 · 42%")
    #expect(Updater.installingLine("0.5.0", progress: 1) == "正在安装 0.5.0…")
  }

  @Test func downloadReportsProgress() async throws {
    // 系统的 async download 不回调写了多少（2026-10-13 实测），进度是从任务的字节数上读的：下一个本地文件，
    // 报出来的都在 0…1、最后到 1，文件完整
    let source = FileManager.default.temporaryDirectory.appending(
      path: "kitty-update-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: source) }
    try Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0) }).write(to: source)
    let reported = OSAllocatedUnfairLock(initialState: [Double]())
    let (file, _) = try await Updater.download(source) { fraction in
      reported.withLock { $0.append(fraction) }
    }
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try Data(contentsOf: file).count == 3_000_000)
    let fractions = reported.withLock { $0 }
    #expect(fractions.last == 1)
    #expect(fractions.allSatisfy { (0...1).contains($0) })
  }

  @Test func knownUpdateSurvivesRecheck() throws {
    let archive = try #require(URL(string: "https://example.com/Kitty.zip"))
    let release = Updater.Release(version: "0.9.0", archive: archive, page: Updater.releasesPage)
    let newer = Updater.Release(version: "0.9.1", archive: archive, page: Updater.releasesPage)
    #expect(Updater(state: .available(release)).available == release)
    #expect(Updater().available == nil)
    for state in [Updater.State.checking, .idle, .failed("检查更新失败")] {
      #expect(Updater.available(release, after: state) == release)
      #expect(Updater.available(nil, after: state) == nil)
    }
    #expect(Updater.available(release, after: .available(newer)) == newer)
    #expect(Updater.available(release, after: .upToDate) == nil)
    #expect(Updater.available(release, after: .installing(release)) == nil)
    #expect(Updater.available(release, after: .installed(release)) == nil)
  }

  /// 新版本换上了、退出却被取消（B5）：不再显示「正在安装」，进度清掉、没有「更新到 x」；之后再查更新不去 GitHub、
  /// 状态不变（测试宿主是开发版，真去查的话会变成「开发版不自动更新」）
  @MainActor @Test func cancelledQuitAfterInstallSaysInstalled() async throws {
    let archive = try #require(URL(string: "https://example.com/Kitty.zip"))
    let release = Updater.Release(version: "0.9.0", archive: archive, page: Updater.releasesPage)
    let updater = Updater(state: .installing(release), progress: 1)
    updater.quitCancelled(release, trigger: .page)
    #expect(updater.state == .installed(release))
    #expect(updater.progress == nil && updater.available == nil)
    #expect(await updater.check(.page))
    #expect(updater.state == .installed(release))
    await updater.install(.page)
    #expect(updater.state == .installed(release), "没有可装的了：不会再装一遍")
  }

  /// 整条链路：好包能换上；版本号对不上、包被改过（签名失效）都拒绝、原 App 不动；
  /// 签名有效但文件所有人可写的包装上后权限收紧（权限不在签名里）
  @Test(.enabled(if: zipPath != nil)) func installsSignedArchiveAndRejectsTampered() async throws {
    let zip = URL(filePath: try #require(Self.zipPath))
    let work = FileManager.default.temporaryDirectory.appending(path: "UpdaterTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: work) }
    let target = work.appending(path: "Apps/Kitty Tools.app")
    func makeOldApp() throws {
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.createDirectory(
        at: target.appending(path: "Contents"), withIntermediateDirectories: true)
      try Data("old".utf8).write(to: target.appending(path: "Contents/marker"))
    }
    // 包里 App 的版本号
    let peek = work.appending(path: "peek")
    try await Self.shell("/usr/bin/ditto", ["-x", "-k", zip.path, peek.path])
    let info = try #require(
      NSDictionary(contentsOf: peek.appending(path: "Kitty Tools.app/Contents/Info.plist")))
    let version = try #require(info["CFBundleShortVersionString"] as? String)

    // 版本号对不上：拒绝，原 App 还在
    try makeOldApp()
    await #expect(throws: UpdateError.self) {
      try await Updater.replace(
        target,
        with: .init(version: version + ".1", archive: zip, page: Updater.releasesPage))
    }
    #expect(FileManager.default.fileExists(atPath: target.appending(path: "Contents/marker").path))

    // 包被改过（签名失效）：拒绝
    let tamperedApp = peek.appending(path: "Kitty Tools.app")
    try Data("x".utf8).write(to: tamperedApp.appending(path: "Contents/Resources/changelog.json"))
    let tampered = work.appending(path: "tampered.zip")
    try await Self.shell(
      "/usr/bin/ditto", ["-c", "-k", "--keepParent", tamperedApp.path, tampered.path])
    await #expect(throws: UpdateError.self) {
      try await Updater.replace(
        target, with: .init(version: version, archive: tampered, page: Updater.releasesPage))
    }
    #expect(FileManager.default.fileExists(atPath: target.appending(path: "Contents/marker").path))

    // 所有人可写的包：签名照样有效，装上后组 / 其他人的写权限都去掉
    let loose = work.appending(path: "loose")
    try await Self.shell("/usr/bin/ditto", ["-x", "-k", zip.path, loose.path])
    try await Self.shell("/bin/chmod", ["-R", "go+w", loose.path])
    let looseZip = work.appending(path: "loose.zip")
    try await Self.shell(
      "/usr/bin/ditto",
      ["-c", "-k", "--keepParent", loose.appending(path: "Kitty Tools.app").path, looseZip.path])
    try await Updater.replace(
      target, with: .init(version: version, archive: looseZip, page: Updater.releasesPage))
    let items = try #require(FileManager.default.enumerator(atPath: target.path)).allObjects
    for case let item as String in items + [""] {
      let mode = try #require(
        FileManager.default.attributesOfItem(atPath: target.appending(path: item).path)[
          .posixPermissions] as? Int)
      #expect(mode & 0o022 == 0, "\(item) \(String(mode, radix: 8))")
    }

    // 好包：换上，签名完好
    try makeOldApp()
    try await Updater.replace(
      target, with: .init(version: version, archive: zip, page: Updater.releasesPage))
    #expect(!FileManager.default.fileExists(atPath: target.appending(path: "Contents/marker").path))
    let installed = try #require(
      NSDictionary(contentsOf: target.appending(path: "Contents/Info.plist")))
    #expect(installed["CFBundleShortVersionString"] as? String == version)
    try await Self.shell(
      "/usr/bin/codesign",
      ["--verify", "--deep", "--strict", "-R", Updater.requirement, target.path])
  }

  private static func shell(_ tool: String, _ arguments: [String]) async throws {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
  }
}
