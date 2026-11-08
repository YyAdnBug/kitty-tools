// 访达右键「新建文件 ▸」（第十一族第 2 批，2026-11-08 拍板 B1，PLAN §10「访达右键」）：文件夹空白处右键，扩展列出菜单、
// 点了交给 App（FinderLink 的 do=new / suffix / templates），App 在这里建：
// - 自带五种：文本文件、Markdown、Word 文档、Excel 表格、PPT 演示文稿（Resources/new-file/，包里平铺、new-file- 开头；
//   Word 是系统 textutil 转的、Excel / PPT 是手写的最小 Office Open XML，元数据都是空的）。
// - 数据目录「新建文件模板」文件夹里用户放的任何文件（放什么就能建什么；扩展有这个文件夹的只读例外，列菜单用）。
// - 「自定义后缀…」：App 弹框问后缀（扩展是后台进程，弹不出窗口），建一个空的「JSON 文件.json」；框里「以后列在「新建文件」里」
//   默认勾着：模板文件夹里也放一个同名的空文件，已经有这个后缀的模板（含自带的）就不放。
// 拷一份到右键的那个文件夹，名字同模板，重名加「 2」；新文件的日期是现在（拷贝会带着模板的旧日期）；建不成响一声、记错误码。
// 名字、后缀的收拾是纯函数（NewFileTests）。
// 安全（2026-11-08 评审）：凭证在偏好里，本机别的程序读得到、也能投网址过来，但它没有本 App 的文件夹授权（桌面 / 文稿 / 下载，
// 用户给过的话还有完全磁盘访问）。所以：模板只认真放在模板文件夹里的——数据目录、模板文件夹、模板本身都不能是替身（符号链接），
// 不然把模板文件夹换成指向 ~/Documents 的替身，就能借本 App 的授权把受保护的文件拷到别处；新文件不往 ~/Library 里建（别的 App
// 的数据、容器都在那里，用户也不会在那里右键新建）；只新建、不覆盖。

import AppKit
import OSLog

nonisolated enum NewFile {
  /// 随 App 的五个（显示的文件名；扩展那边抄了一份，FinderLinkTests 读源码比对）
  static let builtIn = [
    "文本文件.txt", "Markdown.md", "Word 文档.docx", "Excel 表格.xlsx", "PPT 演示文稿.pptx",
  ]
  /// 包里的文件名前缀（资源平铺，别和别的撞名）
  static let resourcePrefix = "new-file-"
  /// 数据目录里用户的模板文件夹（扩展的只读例外写的就是这个名字）
  static let folderName = "新建文件模板"

  static func templatesFolder(in data: URL = AppDelegate.supportDirectory) -> URL {
    data.appending(path: folderName, directoryHint: .isDirectory)
  }

  /// 网址里交过来的模板名只能是一个文件名：不带路径、不是隐藏文件、没有 NUL
  static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\0") && !name.hasPrefix(".")
  }

  /// 没人用的名字：重名加「 2」「 3」（扩展名前面加）
  static func freeName(_ name: String, taken: (String) -> Bool) -> String {
    guard taken(name) else { return name }
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 2
    while true {
      let candidate = "\(stem) \(number)" + (ext.isEmpty ? "" : "." + ext)
      if !taken(candidate) { return candidate }
      number += 1
    }
  }

  /// 自定义后缀：去掉两头的空白和点（「.json」「 yaml 」都行）；空的、带 / 或 : 的不要。「tar.gz」这种整个留着
  static func cleanSuffix(_ raw: String) -> String? {
    let suffix = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["."]))
    guard !suffix.isEmpty, !suffix.contains("/"), !suffix.contains(":"), !suffix.contains("\0")
    else { return nil }
    return suffix
  }

  /// 自定义后缀建出来的名字：「JSON 文件.json」「TAR.GZ 文件.tar.gz」
  static func customName(suffix: String) -> String {
    "\(suffix.uppercased()) 文件.\(suffix)"
  }

  /// 已经有这个后缀的模板了（不分大小写；「tar.gz」整个比，不当成「gz」）
  static func hasTemplate(suffix: String, among names: [String]) -> Bool {
    names.contains { $0.lowercased().hasSuffix("." + suffix.lowercased()) }
  }

  // MARK: 建

  /// 用模板建一个（mine：模板文件夹里的；否则随 App 的）。返回建好的位置
  @discardableResult @MainActor static func create(
    template name: String, mine: Bool, in folder: URL
  )
    -> URL?
  {
    let source =
      mine
      ? templatesFolder().appending(path: name)
      : Bundle.main.url(forResource: resourcePrefix + name, withExtension: nil)
    guard let source, FileManager.default.fileExists(atPath: source.path(percentEncoded: false)),
      !mine || noAliases([AppDelegate.supportDirectory, templatesFolder(), source])
    else {
      NSSound.beep()
      return nil
    }
    // ponytail: 查替身和拷贝之间有一小段空当（查完再换成替身还拷得过去），文件夹模板在主线程上一次拷完、不限大小——
    // 真碰上再改成 O_NOFOLLOW_ANY 打开再写、文件夹放到主线程外
    return place(name, in: folder) { try FileManager.default.copyItem(at: source, to: $0) }
  }

  /// 这几层没有一层是替身（符号链接），拷文件夹模板时里面的替身照原样拷成替身、不跟过去
  static func noAliases(_ urls: [URL]) -> Bool {
    urls.allSatisfy {
      (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false
    }
  }

  /// 能不能往这个文件夹里建：不在 ~/Library 里（解开替身后比）
  static func allowsNewFiles(
    in folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
  )
    -> Bool
  {
    let library = home.resolvingSymlinksInPath().appending(path: "Library").path(
      percentEncoded: false)
    let path = folder.resolvingSymlinksInPath().path(percentEncoded: false)
    return path != library && !path.hasPrefix(library + "/")
  }

  /// 拷进 / 写进 folder，名字让开已有的，日期改成现在；建不成响一声
  @MainActor private static func place(
    _ name: String, in folder: URL, write: (URL) throws -> Void
  ) -> URL? {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue, allowsNewFiles(in: folder)
    else {
      NSSound.beep()
      return nil
    }
    // 按替身本身看占没占（fileExists 会跟过去：断了的替身被当成空位，写的时候才撞上、只能响一声）
    let free = freeName(name) {
      (try? manager.attributesOfItem(atPath: folder.appending(path: $0).path(percentEncoded: false)))
        != nil
    }
    let target = folder.appending(path: free)
    do {
      try write(target)
      try? manager.setAttributes(
        [.creationDate: Date.now, .modificationDate: Date.now],
        ofItemAtPath: target.path(percentEncoded: false))
      return target
    } catch {
      Log.finder.error("新建文件失败：\((error as NSError).code)")
      NSSound.beep()
      return nil
    }
  }

  /// 打开模板文件夹（没有就建）
  @MainActor static func showTemplates() {
    let folder = templatesFolder()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(folder)
  }

  // MARK: 自定义后缀

  /// 正在问：再来一次（框落在后面时用户又点了一回）不再弹第二个
  @MainActor private static var asking = false

  /// 弹框问后缀，在 folder 里建一个空文件。框在 App 里弹（扩展是后台进程）。照 FilePanel：macOS 27 上激活常被系统驳回，
  /// 框会开在访达后面，所以框弹出来后提到 .modalPanel 这一层、拿到最前；关了把前台还给原来的 App
  @MainActor static func askSuffix(in folder: URL) {
    guard !asking else { return }
    asking = true
    defer { asking = false }
    let field = NSTextField(
      string: UserDefaults.standard.string(forKey: Prefs.finderLastSuffix) ?? "")
    field.placeholderString = "比如 json、yaml、tar.gz"
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
    let remember = NSButton(checkboxWithTitle: "以后列在「新建文件」里", target: nil, action: nil)
    remember.state = .on
    let stack = NSStackView(views: [field, remember])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)

    let alert = NSAlert()
    alert.messageText = "新建文件的后缀"
    alert.informativeText = "在「\(folder.lastPathComponent)」里建一个这种后缀的空文件。"
    alert.addButton(withTitle: "新建")
    // Esc = 取消
    alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
    alert.accessoryView = stack
    alert.window.initialFirstResponder = field
    let me = NSRunningApplication.current.processIdentifier
    let front = NSWorkspace.shared.frontmostApplication
    let previous = front?.processIdentifier == me ? nil : front
    NSApp.activate()
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    // runModal 开始之后再提层级（之前设的会被它改回去）；模态循环里排队的块在主线程上跑
    let window = alert.window
    RunLoop.main.perform(inModes: [.modalPanel]) {
      MainActor.assumeIsolated {
        window.level = .modalPanel
        window.orderFrontRegardless()
        window.makeKey()
      }
    }
    let response = alert.runModal()
    defer { previous?.activate() }
    guard response == .alertFirstButtonReturn else { return }
    guard let suffix = cleanSuffix(field.stringValue) else {
      NSSound.beep()
      return
    }
    UserDefaults.standard.set(suffix, forKey: Prefs.finderLastSuffix)
    let name = customName(suffix: suffix)
    guard
      place(name, in: folder, write: { try Data().write(to: $0, options: .withoutOverwriting) })
        != nil
    else { return }
    if remember.state == .on { addTemplate(name, suffix: suffix) }
  }

  /// 模板文件夹里放一个同名的空文件（已经有这个后缀的、含自带的，就不放）
  @MainActor private static func addTemplate(_ name: String, suffix: String) {
    let folder = templatesFolder()
    let mine =
      (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
      ?? []
    guard !hasTemplate(suffix: suffix, among: builtIn + mine) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? Data().write(to: folder.appending(path: name), options: .withoutOverwriting)
  }
}
