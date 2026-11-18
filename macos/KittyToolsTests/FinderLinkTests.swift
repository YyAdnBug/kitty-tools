// 访达右键：扩展交过来的网址怎么认（FinderLink.parse）、拷贝的字、交给 App 打开哪些、凭证只生成一次；
// 还锁着扩展里抄的几个键名（KittyToolsFinder/FinderMenu 读 App 的偏好，名字对不上菜单就一直不出来）；「拷贝图中文字」读图时转正。
// 偏好用临时域，不碰 Dev 版的。

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

@MainActor struct FinderLinkTests {
  /// 「拷贝图中文字」读图（OCR.image）：照片里记的方向转正（竖着拍的照片原始像素是横的），超大的按长边缩，读不了是 nil
  @Test func imageFilesAreReadUpright() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ImageText-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let context = try #require(
      CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let pixels = try #require(context.makeImage())
    let url = folder.appending(path: "竖拍.jpg")
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let image = try #require(await OCR.image(at: url))
    #expect(image.width == 20 && image.height == 40)
    let small = try #require(await OCR.image(at: url, maxSide: 10))
    #expect(max(small.width, small.height) == 10)
    #expect(await OCR.image(at: folder.appending(path: "没有.png")) == nil)
  }

  let scheme = "com.yy.kitty-tools.native.dev"
  let key = "K-123"
  let apps = ["com.apple.Terminal", "com.microsoft.VSCode"]

  private func link(_ query: String, scheme: String? = nil, host: String = "finder") -> URL {
    URL(string: "\(scheme ?? self.scheme)://\(host)?\(query)")!
  }

  private func parse(_ url: URL) -> FinderLink? {
    FinderLink.parse(url, scheme: scheme, key: key, apps: apps)
  }

  /// 工具栏按钮在访达不告诉扩展的位置交过来的（2026-11-17 拍板 A1）：凭证对上、不带文件、只有一个认得的 finder 才去问访达；
  /// 问到的换成 file 照常认；osascript 的输出拆成文件夹和选中的
  @Test func toolbarAsksFinder() throws {
    let scope = { (query: String) in
      FinderLink.finderScope(self.link(query), scheme: self.scheme, key: self.key)
    }
    #expect(scope("do=copy&key=K-123&finder=auto") == .auto)
    #expect(scope("do=zip&key=K-123&finder=items") == .items)
    #expect(scope("do=new&key=K-123&template=txt&finder=folder") == .folder)
    // 凭证不对、带了文件、两个 finder、不认得的范围、没有 finder：不去读访达
    #expect(scope("do=copy&key=wrong&finder=auto") == nil)
    #expect(scope("do=copy&finder=auto") == nil)
    #expect(scope("do=copy&key=K-123&finder=auto&file=/a") == nil)
    #expect(scope("do=copy&key=K-123&finder=auto&finder=items") == nil)
    #expect(scope("do=copy&key=K-123&finder=all") == nil)
    #expect(scope("do=copy&key=K-123") == nil)
    #expect(
      FinderLink.finderScope(
        try #require(URL(string: "https://finder?do=copy&key=K-123&finder=auto")), scheme: scheme,
        key: key) == nil)

    let asked = link("do=zip&key=K-123&finder=items")
    let rebuilt = try #require(FinderLink.withFiles(asked, ["/a/b c.txt", "/a/中文/"]))
    #expect(FinderLink.finderScope(rebuilt, scheme: scheme, key: key) == nil)
    let parsed = try #require(parse(rebuilt))
    #expect(parsed.action == .compress(.zip))
    #expect(parsed.files.map { $0.path(percentEncoded: false) } == ["/a/b c.txt", "/a/中文/"])

    // 文件夹在前，选中的跟在后面，每个后面一个 NUL，osascript 再加一个换行；名字里的换行照留
    let answer = FinderLink.finderAnswer("/Users/x/云盘/\0/Users/x/云盘/a.txt\0/Users/x/b\nc.txt\0\n")
    #expect(answer.folder == "/Users/x/云盘")
    #expect(answer.selection == ["/Users/x/云盘/a.txt", "/Users/x/b\nc.txt"])
    let none = FinderLink.finderAnswer("\0\n")
    #expect(none.folder == nil && none.selection.isEmpty)
    #expect(FinderLink.finderAnswer("").folder == nil)
    // 选中的文件夹也去掉结尾的「/」（同右键）；根目录留着
    let folders = FinderLink.finderAnswer("/\0/Users/x/项目/\0\n")
    #expect(folders.folder == "/" && folders.selection == ["/Users/x/项目"])
    // 脚本里写着上限和「太多」那一句
    #expect(
      FinderLink.finderScript.contains(
        "> \(FinderLink.maxFiles) then return \"\(FinderLink.tooManyMark)\""))
  }

  @Test func copyAndOpenParse() {
    let copy = parse(
      link("do=copy&key=K-123&file=/Users/a/My%20Folder&file=/Users/a/%E4%B8%AD%E6%96%87.txt"))
    #expect(copy?.action == .copyPaths(shell: false))
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

  /// 新建文件的三种：模板名只能是一个文件名、自带的要在名单里（id）；文件夹只能一个；打开模板文件夹不带文件
  @Test func newFileLinks() {
    let home = [URL(filePath: "/Users/a")]
    #expect(
      parse(link("do=new&key=K-123&template=docx&file=/Users/a"))
        == FinderLink(action: .newFile(template: "docx", mine: false), files: home))
    // 0.9.0 的扩展交的是中文文件名（App 更新后旧扩展的进程还在跑）：照认成 id
    #expect(
      parse(link("do=new&key=K-123&template=Word%20%E6%96%87%E6%A1%A3.docx&file=/Users/a"))
        == FinderLink(action: .newFile(template: "docx", mine: false), files: home))
    // 模板文件夹里的照原名，不换成 id
    #expect(
      parse(link("do=new&key=K-123&template=Markdown.md&mine=1&file=/Users/a"))?.action
        == .newFile(template: "Markdown.md", mine: true))
    #expect(
      parse(link("do=new&key=K-123&template=report.key&mine=1&file=/Users/a"))?.action
        == .newFile(template: "report.key", mine: true))
    #expect(parse(link("do=new&key=K-123&template=evil.sh&file=/Users/a")) == nil)  // 不是自带的
    #expect(parse(link("do=new&key=K-123&template=../x&mine=1&file=/Users/a")) == nil)
    #expect(parse(link("do=new&key=K-123&template=a/b&mine=1&file=/Users/a")) == nil)
    #expect(parse(link("do=new&key=K-123&template=.hidden&mine=1&file=/Users/a")) == nil)
    #expect(parse(link("do=new&key=K-123&template=Markdown.md&file=/a&file=/b")) == nil)
    #expect(parse(link("do=new&key=K-123&template=Markdown.md")) == nil)
    #expect(parse(link("do=suffix&key=K-123&file=/Users/a"))?.action == .customSuffix)
    #expect(parse(link("do=suffix&key=K-123")) == nil)
    #expect(parse(link("do=templates&key=K-123"))?.action == .showTemplates)
    #expect(parse(link("do=templates&key=K-123&file=/a")) == nil)
    #expect(parse(link("do=templates")) == nil)  // 没凭证
  }

  /// 整理文件的几种：常用文件夹只认设置里的；选择文件夹；剪切；粘贴只能一个文件夹；替身
  @Test func fileMoveLinks() {
    let downloads = URL(filePath: "/Users/a/Downloads", directoryHint: .isDirectory)
    let parse = { (query: String) in
      FinderLink.parse(
        self.link(query), scheme: self.scheme, key: self.key, apps: self.apps, folders: [downloads])
    }
    #expect(parse("do=name&key=K-123&file=/a/b.txt")?.action == .copyNames(stem: false))
    #expect(
      parse("do=name&key=K-123&style=stem&file=/a/b.txt")?.action == .copyNames(stem: true))
    #expect(
      parse("do=copy&key=K-123&style=shell&file=/a/b.txt")?.action == .copyPaths(shell: true))
    #expect(parse("do=toomany&key=K-123")?.action == .tooMany)
    #expect(parse("do=toomany&key=K-123&file=/a") == nil)
    #expect(parse("do=stale&key=K-123") == nil)
    #expect(
      parse("do=move&key=K-123&to=/Users/a/Downloads&file=/a/b.txt")?.action
        == .transfer(move: true, to: downloads))
    #expect(
      parse("do=copyto&key=K-123&to=/Users/a/Downloads/&file=/a/b.txt")?.action
        == .transfer(move: false, to: downloads))
    #expect(parse("do=move&key=K-123&to=/etc&file=/a/b.txt") == nil)  // 不是常用文件夹
    #expect(parse("do=move&key=K-123&file=/a/b.txt") == nil)
    #expect(
      parse("do=move&key=K-123&to=choose&file=/a/b.txt")?.action == .transfer(move: true, to: nil))
    #expect(parse("do=cut&key=K-123&file=/a/b.txt")?.action == .cut)
    #expect(parse("do=paste&key=K-123&file=/x")?.action == .paste)
    #expect(parse("do=paste&key=K-123&file=/x&file=/y") == nil)
    #expect(parse("do=alias&key=K-123&file=/a/b.txt")?.action == .aliasToDesktop)
    #expect(parse("do=zip&key=K-123&file=/a/b.txt")?.action == .compress(.zip))
    #expect(parse("do=7z&key=K-123&file=/a/b.txt&file=/a/c")?.action == .compress(.sevenZip))
    #expect(parse("do=tgz&key=K-123&file=/a/b.txt&file=/a/c")?.action == .compress(.tarGz))
    #expect(parse("do=ocr&key=K-123&file=/a/b.png")?.action == .copyImageText)
    #expect(parse("do=ocr&key=K-123") == nil)
    #expect(parse("do=tgz&key=K-123") == nil)
    #expect(parse("do=zip&key=K-123") == nil)
    #expect(parse("do=extract&key=K-123&file=/a/b.zip")?.action == .extract(choose: false))
    // 按住 ⌥ 的「解压到…」：先选放在哪；别的 to 不认（解到哪只能是用户在面板里选的）
    #expect(
      parse("do=extract&key=K-123&to=choose&file=/a/b.zip")?.action == .extract(choose: true))
    #expect(parse("do=extract&key=K-123&to=/tmp&file=/a/b.zip") == nil)
    #expect(parse("do=fixnames&key=K-123&file=/a/b")?.action == .fixNames)
    #expect(parse("do=hiddenfiles&key=K-123&file=/a")?.action == .toggleHiddenFiles)
    #expect(parse("do=hide&key=K-123&on=1&file=/a/b")?.action == .setHidden(true))
    #expect(parse("do=ext&key=K-123&on=0&file=/a/b.txt")?.action == .setExtensionHidden(false))
    #expect(parse("do=hide&key=K-123&on=yes&file=/a/b") == nil)
    #expect(parse("do=hash&key=K-123&algo=md5&file=/a/b")?.action == .copyHash(.md5))
    #expect(parse("do=hash&key=K-123&algo=crc32&file=/a/b") == nil)
    #expect(parse("do=erase&key=K-123&file=/a/b")?.action == .erase)
    #expect(parse("do=clip&key=K-123&file=/a")?.action == .newFromClipboard)
    #expect(parse("do=clip&key=K-123&file=/a&file=/b") == nil)
    #expect(parse("do=erase&key=K-123&file=/a/b/..") == nil)
    #expect(parse("do=erase&key=K-123&file=/a/./b") == nil)
    #expect(parse("do=copy&key=K-123&file=/a/b..c")?.action == .copyPaths(shell: false))
    #expect(FinderLink.nameText([URL(filePath: "/a/b.txt"), URL(filePath: "/c/d")]) == "b.txt\nd")
    // 不带扩展名：文件夹照原名
    #expect(
      FinderLink.nameText(
        [URL(filePath: "/a/报告.final.pdf"), URL(filePath: "/a/项目 v1.2")], stem: true,
        isDirectory: { $0.lastPathComponent.hasPrefix("项目") }) == "报告.final\n项目 v1.2")
    // 系统不认得的「扩展名」不去掉；App 去掉 .app
    #expect(
      FinderLink.nameText(
        [
          URL(filePath: "/a/报告 v2.0 最终版"), URL(filePath: "/a/Release v1.2"),
          URL(filePath: "/a/Safari.app"),
        ], stem: true) == "报告 v2.0 最终版\nRelease v1.2\nSafari")
    // 终端写法：安全的原样，别的加单引号，里面的单引号转开，几个用空格连
    #expect(
      FinderLink.shellText([
        URL(filePath: "/a/b-c_1.txt"), URL(filePath: "/a/b c"), URL(filePath: "/a/it's"),
        URL(filePath: "/a/中文"),
      ]) == "/a/b-c_1.txt '/a/b c' '/a/it'\\''s' '/a/中文'")
  }

  /// 发送方核对：拿本进程（测试宿主就是 App，本团队签名）的审计令牌，按 App 自己的 id 认得出、按扩展的 id 不认
  @Test func senderSignatureIsChecked() throws {
    var token = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &token) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }
    #expect(status == KERN_SUCCESS)
    let data = withUnsafeBytes(of: &token) { Data($0) }
    let id = try #require(Bundle.main.bundleIdentifier)
    #expect(FinderLink.signed(auditToken: data, as: id))
    #expect(!FinderLink.signed(auditToken: data, as: id + ".finder"))
    #expect(!FinderLink.signed(auditToken: Data(repeating: 0, count: 32), as: id))
    #expect(!FinderLink.fromOwnExtension(nil))
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
      opens: { $0 == text }, runs: { _ in false }, appEdits: true)
    // 选中的文件夹和别的文件「所在的文件夹」是同一个时也只给一次
    #expect(targets == [folder, text, parent, URL(filePath: "/q")])
    // 不是编辑器的（终端）只给第一个：选了几十个不弹出一串窗口
    let toTerminal = FinderLink.targets(
      [script, other, folder], isDirectory: { $0 == folder }, opens: { _ in false },
      runs: { _ in false }, appEdits: false)
    #expect(toTerminal == [parent])
  }

  /// 拷贝路径后刘海岛上的小字
  @Test func copiedDetailIsShort() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(
      FinderLink.copiedDetail([home.appending(path: "Desktop/a b.txt")]) == "~/Desktop/a b.txt")
    #expect(FinderLink.copiedDetail([URL(filePath: "/a"), URL(filePath: "/b")]) == "2 个路径")
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

  /// 扩展的菜单图标：icons/finder/ 的源和扩展资源目录里生成的对得上，扩展里用到的名字都有
  @Test func extensionIconsAreGenerated() throws {
    let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let names = { (folder: URL, suffix: String) in
      Set(
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
          .filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
    }
    let sources = try names(
      macos.deletingLastPathComponent().appending(path: "icons/finder"), ".svg")
    let assets = try names(
      macos.appending(path: "KittyToolsFinder/Assets.xcassets/FinderIcons"), ".symbolset")
    #expect(sources == ["kitty.finder.copy.path", "kitty.finder.new.file"])
    #expect(sources == assets)
    let source = try String(
      contentsOf: macos.appending(path: "KittyToolsFinder/FinderMenu.swift"), encoding: .utf8)
    for name in sources { #expect(source.contains("\"\(name)\""), "\(name)") }
  }

  /// 扩展那边抄的字面量（键名、默认 App、网址的写法）真的在它的源码里：扩展没有单测，读源文件比对
  @Test func extensionSourceUsesTheSameNames() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appending(path: "KittyToolsFinder/FinderMenu.swift"), encoding: .utf8)
    let names = [
      Feature.finderMenu.prefsKey, Prefs.finderMenuKey, Prefs.finderOpenWithApps,
      Prefs.finderTransferFolders, Prefs.finderCutCount, Prefs.finderCutChange,
      Prefs.finderRecentFolders,
    ]
    let words = [
      "do", "key", "app", "file", "copy", "open", "new", "template", "mine", "suffix", "name",
      "move",
      "copyto", "to", "choose", "cut", "paste", "alias", "zip", "7z", "tgz", "ocr", "extract",
      "finder", "auto", "items", "folder",
      "fixnames",
      "hiddenfiles", "hide", "ext", "on", "hash", "algo", "erase", "style", "shell", "stem",
      "toomany", "stale", "clip",
    ]
    let literals =
      names + Prefs.finderOpenWithDefault + Prefs.finderTransferDefault + NewFile.builtIn
      + [FinderLink.host, "templates"] + words
    #expect(source.contains("/\(NewFile.folderName)\""))
    for literal in literals {
      #expect(source.contains("\"\(literal)\""), "\(literal)")
    }
    // 每一项的键和默认值（扩展读不到注册的默认值，自己抄了一份）
    for item in FinderMenuItem.allCases {
      #expect(source.contains("\"\(item.prefsKey)\", default: \(item.defaultOn)"), "\(item)")
    }
    #expect(source.contains("maxFiles = \(FinderLink.maxFiles)"))
    // 收进子菜单：键名和默认值（扩展读不到注册的默认值）
    #expect(Prefs.defaults[Prefs.finderMenuGrouped] as? Bool == false)
    #expect(source.contains("\"\(Prefs.finderMenuGrouped)\", default: false"))
    // 哈希的几种（扩展里按序号对应）
    let hashes = FileHash.Kind.allCases.map { "(\"\($0.rawValue)\", \"\($0.title)\")" }
    #expect(source.contains("[" + hashes.joined(separator: ", ") + "]"))
    // 解压认的扩展名
    let start = try #require(source.range(of: "archiveSuffixes = ["))
    let end = try #require(source[start.upperBound...].range(of: "]"))
    let listed = source[start.upperBound..<end.lowerBound].matches(of: /"([^"]+)"/).map {
      String($0.output.1)
    }
    #expect(listed == Archives.suffixes)
    // 乱码判断两份逐字一样
    let app = try String(
      contentsOf: root.appending(path: "KittyTools/FinderMenu/NameRepair.swift"), encoding: .utf8)
    let block = { (text: String) -> Substring? in
      guard let start = text.range(of: "// BEGIN NameRepair"),
        let end = text.range(of: "// END NameRepair")
      else { return nil }
      return text[start.lowerBound..<end.upperBound]
    }
    #expect(block(app) != nil)
    #expect(block(app) == block(source))
  }
}
