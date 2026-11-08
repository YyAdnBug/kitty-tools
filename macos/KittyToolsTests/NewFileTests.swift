// 访达右键「新建文件」：重名让开、后缀收拾、自定义后缀的名字、已有模板的判断、自带模板真打进了包里。
// 不碰 Dev 版的数据目录（模板文件夹）：只测纯函数和包里的资源。

import AppKit
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
    #expect(NewFile.hasTemplate(suffix: "md", among: NewFile.builtIn))
    #expect(NewFile.hasTemplate(suffix: "DOCX", among: NewFile.builtIn))
    #expect(!NewFile.hasTemplate(suffix: "json", among: NewFile.builtIn))
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
  }

  /// 自带的五个真在包里（测试宿主就是 App），Office 那三个是 zip 包（PK 开头）
  @Test func builtInTemplatesAreBundled() throws {
    for name in NewFile.builtIn {
      let url = try #require(
        Bundle.main.url(forResource: NewFile.resourcePrefix + name, withExtension: nil), "\(name)")
      if ["docx", "xlsx", "pptx"].contains((name as NSString).pathExtension) {
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 2)
        #expect(head == Data("PK".utf8), "\(name)")
      }
    }
    #expect(
      NewFile.templatesFolder(in: URL(filePath: "/d")).path(percentEncoded: false) == "/d/新建文件模板/")
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
}
