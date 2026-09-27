// 应用内更新：GitHub release JSON 解析、版本比较（纯逻辑）；整条安装链路按需启用——拿 build-dmg.sh 打出来的
// 真 zip 走「下载（file://）→ 解包 → 校验 → 替换」，替换的是临时目录里的假 App，不碰「应用程序」：
//   TEST_RUNNER_KITTY_UPDATE_ZIP="$PWD/macos/build/Kitty Tools_0.1.0_arm64.zip" xcodebuild -project \
//     macos/KittyTools.xcodeproj -scheme KittyTools test -only-testing:KittyToolsTests/UpdaterTests
import Foundation
import Testing

@testable import KittyTools

struct UpdaterTests {
  nonisolated private static let zipPath =
    ProcessInfo.processInfo.environment["KITTY_UPDATE_ZIP"]

  private static func payload(tag: String, assets: [(String, String)]) -> Data {
    let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }
    return Data(
      #"{"tag_name":"\#(tag)","html_url":"https://github.com/YyAdnBug/kitty-tools/releases/tag/\#(tag)","draft":false,"prerelease":false,"assets":[\#(list.joined(separator: ","))]}"#
        .utf8)
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

  @Test func comparesVersionsNumerically() {
    #expect(Updater.isNewer("0.1.10", than: "0.1.9"))
    #expect(Updater.isNewer("0.2.0", than: "0.1.0"))
    #expect(Updater.isNewer("1.0.0", than: "0.9.9"))
    #expect(!Updater.isNewer("0.1.0", than: "0.1.0"))
    #expect(!Updater.isNewer("0.1.0", than: "0.2.0"))
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
