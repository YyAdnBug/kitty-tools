// 访达右键：扩展交过来的网址怎么认（FinderLink.parse）、拷贝的字、交给 App 打开哪些、凭证只生成一次；
// 还锁着扩展里抄的几个键名（KittyToolsFinder/FinderMenu 读 App 的偏好，名字对不上菜单就一直不出来）。
// 偏好用临时域，不碰 Dev 版的。

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

@MainActor struct FinderLinkTests {
  let scheme = "com.yy.kitty-tools.native.dev"
  let key = "K-123"
  let apps = ["com.apple.Terminal", "com.microsoft.VSCode"]

  private func link(_ query: String, scheme: String? = nil, host: String = "finder") -> URL {
    URL(string: "\(scheme ?? self.scheme)://\(host)?\(query)")!
  }

  private func parse(_ url: URL) -> FinderLink? {
    FinderLink.parse(url, scheme: scheme, key: key, apps: apps)
  }

  @Test func copyAndOpenParse() {
    let copy = parse(
      link("do=copy&key=K-123&file=/Users/a/My%20Folder&file=/Users/a/%E4%B8%AD%E6%96%87.txt"))
    #expect(copy?.action == .copyPaths)
    #expect(
      copy?.files.map { $0.path(percentEncoded: false) } == [
        "/Users/a/My Folder", "/Users/a/中文.txt",
      ])
    let open = parse(link("do=open&key=K-123&app=com.microsoft.VSCode&file=/tmp/a"))
    #expect(
      open
        == FinderLink(action: .open(app: "com.microsoft.VSCode"), files: [URL(filePath: "/tmp/a")]))
    // scheme 不分大小写（系统可能把网址的 scheme 改成小写）
    #expect(parse(link("do=copy&key=K-123&file=/a", scheme: scheme.uppercased())) != nil)
    // 带 & + # % ? 的名字照样还原
    var components = URLComponents()
    components.scheme = scheme
    components.host = "finder"
    let odd = "/Users/a/R&D + 50% #1?.txt"
    components.queryItems = [
      URLQueryItem(name: "do", value: "copy"), URLQueryItem(name: "key", value: key),
      URLQueryItem(name: "file", value: odd),
    ]
    #expect(parse(components.url!)?.files.first?.path(percentEncoded: false) == odd)
  }

  /// 网页、别的 App 也能打开这个网址：对不上的一律不认
  @Test func rejectsWhatIsNotOurs() {
    #expect(parse(link("do=copy&file=/a")) == nil)  // 没凭证
    #expect(parse(link("do=copy&key=wrong&file=/a")) == nil)
    #expect(parse(link("do=copy&key=K-123&key=K-123&file=/a")) == nil)  // 凭证给了两次
    #expect(
      FinderLink.parse(link("do=copy&key=&file=/a"), scheme: scheme, key: "", apps: apps) == nil)
    #expect(
      FinderLink.parse(link("do=copy&key=K-123&file=/a"), scheme: scheme, key: nil, apps: apps)
        == nil)
    #expect(parse(link("do=copy&key=K-123&file=/a", scheme: "com.other.app")) == nil)
    #expect(parse(link("do=copy&key=K-123&file=/a", host: "open")) == nil)
    #expect(parse(link("do=copy&key=K-123")) == nil)  // 没文件
    #expect(parse(link("do=copy&key=K-123&file=relative/path")) == nil)
    #expect(parse(link("do=copy&key=K-123&file=/a%00b")) == nil)
    #expect(parse(link("do=delete&key=K-123&file=/a")) == nil)  // 不认的动作
    #expect(parse(link("do=open&key=K-123&app=com.evil.app&file=/a")) == nil)  // 不在设置的列表里
    #expect(parse(link("do=open&key=K-123&file=/a")) == nil)  // 没说用哪个 App
    let many = (0...FinderLink.maxFiles).map { "file=/f\($0)" }.joined(separator: "&")
    #expect(parse(link("do=copy&key=K-123&" + many)) == nil)
  }

  @Test func pathTextIsOnePerLine() {
    #expect(FinderLink.pathText([URL(filePath: "/a b/c"), URL(filePath: "/d")]) == "/a b/c\n/d")
  }

  /// 文件夹原样给；App 认得的文件原样给，认不得的给所在文件夹，同一个文件夹只给一次
  @Test func openTargets() {
    let folder = URL(filePath: "/p/folder")
    let text = URL(filePath: "/p/notes.txt")
    let script = URL(filePath: "/p/run.sh")
    let other = URL(filePath: "/q/x.sh")
    let parent = URL(filePath: "/p")
    let targets = FinderLink.targets(
      [folder, text, script, other, parent], isDirectory: { $0 == folder || $0 == parent },
      opens: { $0 == text }, runs: { _ in false }, appEdits: false)
    // 选中的文件夹和别的文件「所在的文件夹」是同一个时也只给一次
    #expect(targets == [folder, text, parent, URL(filePath: "/q")])
  }

  /// 交过去就会被运行的（终端认得 .command、可执行文件）：给终端的是所在文件夹，给编辑器的才是文件本身
  @Test func runnableFilesOnlyGoToEditors() {
    let command = URL(filePath: "/p/build.command")
    let binary = URL(filePath: "/p/tool")
    let text = URL(filePath: "/p/a.txt")
    let runnable: Set<URL> = [command, binary]
    let toTerminal = FinderLink.targets(
      [command, binary], isDirectory: { _ in false }, opens: { _ in true },
      runs: { runnable.contains($0) }, appEdits: false)
    #expect(toTerminal == [URL(filePath: "/p")])
    let toEditor = FinderLink.targets(
      [command, text], isDirectory: { _ in false }, opens: { _ in true },
      runs: { runnable.contains($0) }, appEdits: true)
    #expect(toEditor == [command, text])
    // 哪些算「会被运行」：脚本（.command / .sh 都是）、可执行文件、终端的配置；文本、图片不算
    #expect(FinderLink.runs(UTType(filenameExtension: "command")))
    #expect(FinderLink.runs(UTType(filenameExtension: "sh")))
    #expect(FinderLink.runs(UTType(filenameExtension: "terminal")))
    #expect(FinderLink.runs(.unixExecutable))
    #expect(!FinderLink.runs(.plainText) && !FinderLink.runs(.png) && !FinderLink.runs(nil))
  }

  /// 凭证只在没有时生成，生成后不再变
  @Test func keyIsMadeOnce() throws {
    let suite = "FinderLinkTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    FinderLink.ensureKey(defaults)
    let first = try #require(defaults.string(forKey: Prefs.finderMenuKey))
    #expect(!first.isEmpty)
    FinderLink.ensureKey(defaults)
    #expect(defaults.string(forKey: Prefs.finderMenuKey) == first)
  }

  /// 扩展里抄的键名和默认值（FinderMenu 读 App 的偏好）：这边改了那边要跟着改。凭证不注册默认值（这台电脑自己的，不导出）
  @Test func extensionKeysStayInStep() {
    #expect(Feature.finderMenu.prefsKey == "feature.finderMenu")
    #expect(!Feature.finderMenu.defaultOn)
    #expect(Prefs.finderMenuKey == "finderMenuKey")
    #expect(Prefs.finderOpenWithApps == "finderOpenWithApps")
    #expect(Prefs.finderOpenWithDefault == ["com.apple.Terminal"])
    #expect(Prefs.defaults[Prefs.finderMenuKey] == nil)
    #expect(Prefs.defaults[Prefs.finderOpenWithApps] as? [String] == ["com.apple.Terminal"])
    #expect(SettingsSync.localKeys.contains(Feature.finderMenu.prefsKey))
  }

  /// 扩展那边抄的字面量（键名、默认 App、网址的写法）真的在它的源码里：扩展没有单测，读源文件比对
  @Test func extensionSourceUsesTheSameNames() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appending(path: "KittyToolsFinder/FinderMenu.swift"), encoding: .utf8)
    let literals =
      [
        Feature.finderMenu.prefsKey, Prefs.finderMenuKey, Prefs.finderOpenWithApps,
      ] + Prefs.finderOpenWithDefault + [
        FinderLink.host, "do", "key", "app", "file", "copy", "open",
      ]
    for literal in literals {
      #expect(source.contains("\"\(literal)\""), "\(literal)")
    }
    #expect(source.contains("maxFiles = \(FinderLink.maxFiles)"))
  }
}
