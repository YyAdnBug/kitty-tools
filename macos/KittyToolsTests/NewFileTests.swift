// 访达右键「新建文件」：重名让开、后缀收拾、自定义后缀的名字、已有模板的判断、自带模板真打进了包里、建出来的名字跟界面语言。
// 不碰 Dev 版的数据目录（模板文件夹）：只测纯函数和包里的资源。
// 另有一个按需的实机自检 liveRenameLandsOnNewFile（TEST_RUNNER_KITTY_LIVE_FINDER_RENAME=1，要测试宿主有「辅助功能」授权；
// issue #34）：**会把访达叫到前台、在临时文件夹里切四种视图、按回车 / Esc，约 20 秒，跑之前先跟用户说、手离开键鼠**。
// 只动临时目录；最后按 Esc 退出改名、只关这次新开的窗口（开始前就开着的不关）。旧做法（到前台等 0.1 秒就按回车）跑它：
// 分栏视图里进入改名的是父文件夹。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct NewFileTests {
  @Test func freeNameAddsNumberBeforeExtension() {
    let taken: Set<String> = ["Word 文档.docx", "Word 文档 2.docx", "Makefile", "a.tar.gz"]
    #expect(NewFile.freeName("Word 文档.docx", taken: taken.contains) == "Word 文档 3.docx")
    #expect(NewFile.freeName("Makefile", taken: taken.contains) == "Makefile 2")
    #expect(NewFile.freeName("新的.txt", taken: taken.contains) == "新的.txt")
    // 只认最后一段扩展名：「a.tar.gz」让成「a.tar 2.gz」（同访达自己拷贝重名时的做法）
    #expect(NewFile.freeName("a.tar.gz", taken: taken.contains) == "a.tar 2.gz")
  }

  @Test func suffixIsCleaned() {
    #expect(NewFile.cleanSuffix(" .json ") == "json")
    #expect(NewFile.cleanSuffix("..yaml.") == "yaml")
    #expect(NewFile.cleanSuffix("tar.gz") == "tar.gz")
    #expect(NewFile.cleanSuffix("") == nil)
    #expect(NewFile.cleanSuffix(" . ") == nil)
    #expect(NewFile.cleanSuffix("a/b") == nil)
    #expect(NewFile.cleanSuffix("a:b") == nil)
    #expect(NewFile.customName(suffix: "json") == "JSON 文件.json")
    #expect(NewFile.customName(suffix: "tar.gz") == "TAR.GZ 文件.tar.gz")
  }

  @Test func existingTemplateIsFoundBySuffix() {
    let builtIn = NewFile.builtIn.map(NewFile.fileName(of:))
    #expect(NewFile.hasTemplate(suffix: "md", among: builtIn))
    #expect(NewFile.hasTemplate(suffix: "DOCX", among: builtIn))
    #expect(!NewFile.hasTemplate(suffix: "json", among: builtIn))
    // 「tar.gz」整个比：只有 .gz 的不算
    #expect(!NewFile.hasTemplate(suffix: "tar.gz", among: ["a.gz"]))
    #expect(NewFile.hasTemplate(suffix: "gz", among: ["TAR.GZ 文件.tar.gz"]))
  }

  @Test func plainNamesOnly() {
    #expect(NewFile.isPlainName("周报模板.docx"))
    #expect(!NewFile.isPlainName(""))
    #expect(!NewFile.isPlainName("../x"))
    #expect(!NewFile.isPlainName("a/b"))
    #expect(!NewFile.isPlainName(".DS_Store"))
  }

  /// 替身（符号链接）一层都不认：把模板文件夹换成指向 ~/Documents 的替身就能借本 App 的授权拷走受保护的文件
  @Test func aliasesAreRefused() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "NewFileTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "新建文件模板")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "a.txt")
    try Data().write(to: file)
    let alias = folder.appending(path: "b.txt")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    let aliasedFolder = root.appending(path: "别名")
    try FileManager.default.createSymbolicLink(at: aliasedFolder, withDestinationURL: folder)
    #expect(NewFile.noAliases([root, folder, file]))
    #expect(!NewFile.noAliases([root, folder, alias]))
    #expect(!NewFile.noAliases([root, aliasedFolder, aliasedFolder.appending(path: "a.txt")]))
    #expect(!NewFile.noAliases([folder.appending(path: "没有这个")]))
  }

  /// 不往 ~/Library 里建（别的 App 的数据、容器都在那里）
  @Test func noNewFilesInLibrary() {
    let home = URL(filePath: "/Users/nobody-here")
    #expect(NewFile.allowsNewFiles(in: home.appending(path: "Desktop"), home: home))
    #expect(NewFile.allowsNewFiles(in: home.appending(path: "LibraryNotes"), home: home))
    #expect(!NewFile.allowsNewFiles(in: home.appending(path: "Library"), home: home))
    #expect(!NewFile.allowsNewFiles(in: home.appending(path: "Library/Containers/x"), home: home))
    // iCloud 云盘、网盘在资源库里，照建；它们的根、LaunchAgents 这类照旧不建
    #expect(
      NewFile.allowsNewFiles(
        in: home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/项目"), home: home))
    #expect(
      NewFile.allowsNewFiles(
        in: home.appending(path: "Library/CloudStorage/OneDrive-个人/文档"), home: home))
    #expect(!NewFile.allowsNewFiles(in: home.appending(path: "Library/CloudStorage"), home: home))
    #expect(
      !NewFile.allowsNewFiles(in: home.appending(path: "Library/Mobile Documents/"), home: home))
    #expect(!NewFile.allowsNewFiles(in: home.appending(path: "Library/LaunchAgents"), home: home))
  }

  /// 自带的五个真在包里（测试宿主就是 App），Office 那三个是 zip 包（PK 开头）
  @Test func builtInTemplatesAreBundled() throws {
    for id in NewFile.builtIn {
      let url = try #require(
        Bundle.main.url(forResource: NewFile.resourceName, withExtension: id), "\(id)")
      if ["docx", "xlsx", "pptx"].contains(id) {
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 2)
        #expect(head == Data("PK".utf8), "\(id)")
      }
    }
    #expect(
      NewFile.templatesFolder(in: URL(filePath: "/d")).path(percentEncoded: false) == "/d/新建文件模板/")
  }

  /// 自带模板内部认 id（多语言第 8b 批），建出来的文件名跟界面语言：单测宿主是中文，和 0.9.0 建出来的一样；
  /// 0.9.0 的扩展交的中文文件名照认成 id
  @Test func builtInNamesFollowInterfaceLanguage() {
    #expect(
      NewFile.builtIn.map(NewFile.fileName(of:)) == [
        "文本文件.txt", "Markdown.md", "Word 文档.docx", "Excel 表格.xlsx", "PPT 演示文稿.pptx",
      ])
    #expect(Set(NewFile.legacyNames.values) == Set(NewFile.builtIn))
    for (name, id) in NewFile.legacyNames { #expect(NewFile.fileName(of: id) == name) }
    #expect(NewFile.builtIn.allSatisfy { $0.allSatisfy(\.isASCII) })
  }

  /// 「从剪贴板新建」：剪贴板里的 TIFF 转成 PNG
  @Test func clipboardImageBecomesPNG() async throws {
    let image = NSImage(size: NSSize(width: 4, height: 3))
    image.lockFocus()
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 3).fill()
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(await NewFile.pngData(from: tiff))
    #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    #expect(await NewFile.pngData(from: Data("not an image".utf8)) == nil)
  }

  /// issue #34：访达里有焦点的那个视图选中的正好是新文件才按回车。分栏视图里选中还没落下时是左边一栏的父文件夹
  @Test func renamesOnlyWhenNewFileIsTheSelection() {
    let new = URL(filePath: "/tmp/a/Markdown.md")
    #expect(NewFile.selectsOnly(new, [URL(filePath: "/tmp/a/Markdown.md")]))
    #expect(NewFile.selectsOnly(URL(filePath: "/tmp/a/b/"), [URL(filePath: "/tmp/a/b")]))
    #expect(!NewFile.selectsOnly(new, []))
    #expect(!NewFile.selectsOnly(new, [nil]))
    #expect(!NewFile.selectsOnly(new, [URL(filePath: "/tmp/a")]))
    #expect(!NewFile.selectsOnly(new, [URL(filePath: "/tmp/a/Markdown 2.md")]))
    #expect(!NewFile.selectsOnly(new, [new, URL(filePath: "/tmp/a/old.md")]))
    #expect(!NewFile.selectsOnly(new, [new, nil]))
  }

  // MARK: 实机自检（按需，见文件头）

  @MainActor
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_FINDER_RENAME"] == "1"))
  func liveRenameLandsOnNewFile() async throws {
    try #require(Permissions.isAccessibilityTrusted, "测试宿主没有「辅助功能」授权")
    let manager = FileManager.default
    let tag = UUID().uuidString.prefix(6)
    let root = manager.temporaryDirectory.appending(path: "kitty-rename-\(tag)")
    let parent = root.appending(path: "parent-\(tag)")
    let existing = parent.appending(path: "existing.txt")
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    try manager.createDirectory(
      at: root.appending(path: "sibling-\(tag)"), withIntermediateDirectories: true)
    try Data().write(to: existing)
    // 开始前就开着的窗口（用户的）收尾时不关
    let opened = Self.finderWindows()
    defer {
      Self.closeFinderWindows(except: opened)
      try? manager.removeItem(at: root)
    }
    // 测试宿主在后台，activateFileViewerSelecting 叫不到前台（协作式激活）：先把访达叫到前台
    let finder = URL(filePath: "/System/Library/CoreServices/Finder.app")
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    _ = try await NSWorkspace.shared.openApplication(at: finder, configuration: configuration)
    let finderIsFront = {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
    /// 路径 → 名字的快照（访达改视图时写的 .DS_Store 不算）
    let snapshot = {
      Set(
        (manager.subpaths(atPath: root.path(percentEncoded: false)) ?? []).filter {
          !$0.hasSuffix(".DS_Store")
        })
    }
    // （视图键，事先选中的，新文件建在哪）：分栏里选着左边一栏的文件夹、在它右边那一栏空白处右键（issue 里的样子），
    // 分栏里在左边那一栏空白处右键；列表、图标、画廊里选着一个旧文件
    let cases: [(view: Int, selected: URL, folder: URL)] = [
      (kVK_ANSI_3, parent, parent), (kVK_ANSI_3, parent, root), (kVK_ANSI_2, existing, parent),
      (kVK_ANSI_1, existing, parent), (kVK_ANSI_4, existing, parent),
    ]
    for (view, selected, folder) in cases {
      NSWorkspace.shared.activateFileViewerSelecting([selected])
      try await Task.sleep(for: .seconds(1))
      try #require(finderIsFront(), "访达不在前台：别动键鼠再跑")
      Paster.press(view, flags: .maskCommand)
      try await Task.sleep(for: .seconds(1))
      NSWorkspace.shared.activateFileViewerSelecting([selected])
      try await Task.sleep(for: .seconds(1))
      let before = snapshot()
      let made = try #require(NewFile.create(template: "md", mine: false, in: folder))
      var editing: String?
      // 最多等 5 秒（revealForRename 最多等 4 秒）
      for _ in 0..<50 where editing == nil {
        try await Task.sleep(for: .milliseconds(100))
        editing = Self.finderRenameField()
      }
      if editing != nil, finderIsFront() { Paster.press(kVK_Escape) }
      // 没进入改名时记下当时谁在前台、访达里选中的对不对得上（分清是我们没认出来，还是访达没在前台）
      let front = NSWorkspace.shared.frontmostApplication
      let matches = await NewFile.finderSelects(only: made, pid: front?.processIdentifier ?? 0)
      #expect(
        editing == made.lastPathComponent,
        """
        视图键 \(view)、建在 \(folder.lastPathComponent)：进入改名的是 \(editing ?? "（没进入改名）")，\
        前台 \(front?.bundleIdentifier ?? "-")，选中的对得上：\(matches)
        """)
      try await Task.sleep(for: .milliseconds(500))
      let added = String(
        made.path(percentEncoded: false).dropFirst((FileMoves.plainPath(root) + "/").count))
      #expect(snapshot() == before.union([added]), "有东西被改了名")
    }
  }

  /// 访达里正在改名的那个输入框里的字（焦点不在输入框里是 nil）
  @MainActor private static func finderRenameField() -> String? {
    guard
      let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        .first?.processIdentifier
    else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var focused: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    // 上面认过类型
    let element = focused as! AXUIElement
    var role: CFTypeRef?
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    guard role as? String == kAXTextFieldRole else { return nil }
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    return value as? String ?? ""
  }

  /// 访达现在开着的窗口
  @MainActor private static func finderWindows() -> [AXUIElement] {
    guard
      let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        .first?.processIdentifier
    else { return [] }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
    return windows as? [AXUIElement] ?? []
  }

  /// 关掉这次新开的访达窗口（except 是开始前就开着的，不关）：显示临时文件夹的，和访达没有窗口时被叫到前台自己开的那扇
  /// 「桌面」。文件夹删掉时访达不关窗口、退到上一层，所以先关
  @MainActor private static func closeFinderWindows(except opened: [AXUIElement]) {
    for window in finderWindows() where !opened.contains(where: { CFEqual($0, window) }) {
      var button: CFTypeRef?
      AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
      // 关闭钮是元素（AXUIElement 的 CFTypeRef 转不了别的）
      if let button { AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) }
    }
  }
}
